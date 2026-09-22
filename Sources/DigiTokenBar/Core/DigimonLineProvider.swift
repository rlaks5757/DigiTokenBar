import Foundation

/// `DigimonData`(번들 JSON) 기반 `PokeProviding` 구현체. `CompanionStore` 가 이걸 기본 provider 로 써서
/// PokéAPI 네트워크 호출 없이 진화 라인·부화 후보를 제공한다.
///
/// **트리는 죠그레스·아머·체인을 담지 않는다(선형 사슬만).** 이유: `EvoLine.totalForms` 는
/// `tree.depth` 로 계산되고, 이 값이 `PokemonBalance.phaseThreshold` 를 거쳐 모든 단계 임계값과
/// 세이브 스키마(`MonState.totalForms`)에 그대로 들어간다. 죠그레스는 부모가 둘이고 아머는 아이템
/// 키가 있어야 도달하므로, "부모 1개 → 자식 1개"인 선형 depth 로 표현할 수 없다 — 트리에 넣으려면
/// 도달 방식이 다른 분기를 depth 계산에 어떻게 반영할지부터 정해야 한다(다음 단계: UI 분기 렌더링).
/// 그때까지 이 provider 는 `DigiLine.stages` 를 그대로 선형 사슬로만 변환한다.
struct DigimonLineProvider: PokeProviding {

    /// speciesID 가 라인의 base(정규 진화 시작점)일 때 그 라인, 아니면 nil.
    private func line(forBaseID id: Int) -> DigiLine? {
        DigimonData.lines.first { $0.baseID == id }
    }

    func line(baseSpeciesID: Int) async throws -> EvoLine {
        guard let digiLine = line(forBaseID: baseSpeciesID) else {
            throw DigimonLineProviderError.unknownBase(id: baseSpeciesID)
        }
        let tree = Self.chain(digiLine.stages.map(\.id))
        var names: [Int: [String: String]] = [:]
        for stage in digiLine.stages {
            // DigimonDataLoader 가 라인 구성 시점에 stages 의 모든 id 를 names 존재 여부로 이미
            // 검증한다(`guard names[rawStage.id] != nil else { throw .unknownSpeciesInLine }`) —
            // `digiLine.stages` 에 들어온 id 는 정의상 전부 이름이 있다. 여기서 nil 이면 로더 불변조건이
            // 깨진 것이므로 조용히 건너뛰지 않고 즉시 trap 한다.
            guard let name = DigimonData.name(for: stage.id) else {
                preconditionFailure("DigimonDataLoader already guarantees a name for every line stage id")
            }
            // "en" 은 PokéAPI 언어코드 관례(AppLanguage.en.apiCodes)와 동일한 키이자
            // PokemonNameLocalization.resolve 의 최종 폴백 코드이므로, 언어 무관하게 항상 이 이름이 뜬다.
            names[stage.id] = ["en": name.apiName]
        }
        return EvoLine(baseID: digiLine.baseID, tree: tree, rarity: digiLine.rarity, names: names)
    }

    /// 평면 배열 [base, ..., final] → 각 노드가 자식 1개(마지막만 0개)인 선형 사슬.
    private static func chain(_ ids: [Int]) -> EvoNode {
        guard let first = ids.first else {
            // 실무에서 도달하지 않는다 — 단, DigimonDataLoader 에 `stages.isEmpty` 전용 가드는 없다
            // (이건 별건으로 기록해둘 결함이다). 실제로 막히는 지점은 forwardEdges 구성
            // (`for i in 1..<line.stages.count`, DigimonDataLoader.swift) 이다 — stages 가 비면
            // `1..<0` 이 유효하지 않은 Range 라 로더가 여기 도달하기 전에 먼저 trap 한다.
            preconditionFailure("DigiLine.stages must not be empty")
        }
        let rest = Array(ids.dropFirst())
        return EvoNode(speciesID: first, children: rest.isEmpty ? [] : [chain(rest)])
    }

    // MARK: base 인덱스 (부화 후보)

    /// `DigiLine.rarity` → captureRate 유도. 값 자체는 임의가 아니라 `Rarity.from(captureRate:...)`
    /// 의 등급 경계(`Rarity.captureRateCeiling`: rare ≤45, uncommon ≤120, common ≤255)를 통과했을 때
    /// **원래 등급으로 되돌아오는** 값을 등급별로 하나씩 고른 것이다. `CollectionWeight.adjusted` 가
    /// captureRate 를 가중치로 그대로 쓰고 값이 클수록 흔하게 뽑히므로, 등급 간 상대 희귀도가
    /// 뒤집히지 않도록 legendary < rare < uncommon < common 순으로 값도 커지게 배치했다.
    ///
    /// 등급→captureRate 를 라인별 테이블이 아니라 이 함수 하나로 유도하는 이유: 과거엔 baseID 를
    /// 키로 하는 별도 테이블이 있어 `DigimonData.lines` 와 서로 독립이었다 — 라인을 추가하고 테이블에
    /// 안 넣으면 `?? 255` 폴백으로 조용히 common 최흔값이 되는 함정이 있었다(전설 라인이 common 으로
    /// 뽑힘). rarity 에서 직접 유도하면 매핑이 어긋날 수 없다.
    ///
    /// legendary(agumon, gabumon)는 `captureRateCeiling` 이 nil 이라 애초에 captureRate 로 표현
    /// 불가능하다 — `from()` 에 넣으면 항상 rare 이하로 판정된다. 대신 "전설은 전부 capture_rate ≤45"
    /// 라는 PokéAPI 성질(Rarity.captureRateCeiling 문서 참고)을 따르되, **이 20 이라는 구체값은
    /// PokéAPI 관례에서 유도된 게 아니라 "라인 12개짜리 풀에서의 체감 희소성"으로 사용자가 정한
    /// 값이다** — rare 상한(45) 안쪽이라 희귀 이상 등급 보증 알(`CompanionStore.chooseBase` 의
    /// captureRate 필터)에는 여전히 포함되면서, rare 라인(45)보다 낮아 가중치상 여전히 가장 희귀하다.
    /// 라인 수가 늘어나면(현재 12개 기준) 재조정 대상이다.
    ///
    /// **현재 12종 구성(legendary 2 / rare 2 / uncommon 4 / common 4)에서의 실제 추첨 확률**
    /// (미수집 기준 — `CollectionWeight.adjusted` 는 이미 수집한 base 가중치를 절반으로 깎으므로
    /// 도감이 채워질수록 이 수치에서 멀어진다). captureRate 합 = 20×2 + 45×2 + 90×4 + 190×4 = 1250:
    /// - 무보증 알: legendary 3.2%(종당 1.6%) / rare 7.2% / uncommon 28.8% / common 60.8%
    /// - 희귀 이상 보증 알(captureRate ≤45 후보만, legendary+rare): legendary 31% / rare 69%
    /// - 고급 이상 보증 알(captureRate ≤120 후보, legendary+rare+uncommon): legendary 8.2%
    ///
    /// 이 분포는 부작용이 아니라 사용자가 위 수치를 보고 승인한 값이다 — legendary 20 을 포함해
    /// 라인 수·등급 구성이 이번 12종 기준으로 의도적으로 맞춰졌다. 라인이 추가/변경되면 이 표는
    /// 갱신 대상이다.
    private static func captureRate(for rarity: Rarity) -> Int {
        switch rarity {
        case .legendary: return 20    // rare 상한 안쪽, rare 라인보다 낮음 — § 위 주석 참고
        case .rare:      return 45    // 상한값
        case .uncommon:  return 90    // 중간값
        case .common:    return 190   // 중간값
        }
    }

    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        DigimonData.lines.map { BaseSpecies(id: $0.baseID, captureRate: Self.captureRate(for: $0.rarity)) }
    }

    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        guard let digiLine = line(forBaseID: id) else { return nil }
        return BaseSpecies(id: id, captureRate: Self.captureRate(for: digiLine.rarity))
    }
}

enum DigimonLineProviderError: Error, CustomStringConvertible {
    case unknownBase(id: Int)

    var description: String {
        switch self {
        case .unknownBase(let id): return "species id \(id) 는 정규 진화 라인의 base 가 아님"
        }
    }
}
