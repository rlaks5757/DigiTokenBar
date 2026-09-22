import XCTest
@testable import DigiTokenBar

/// `DigimonLineProvider`(DigimonData 기반 PokeProviding 구현) 회귀 가드.
/// 개수만 세는 단언은 구성원 교체를 못 잡으므로(§ count-assertions-hide-membership),
/// 12개 라인 전체의 실제 baseID·rarity·captureRate 대응을 하나씩 고정한다.
final class DigimonLineProviderTests: XCTestCase {
    private let provider = DigimonLineProvider()

    /// 12개 라인 전부 line() 이 성공하고, totalForms(=tree.depth) 가 stages.count 와 일치한다.
    /// 라인마다 k(2~4)가 달라 4로 고정된 구현이면 짧은/긴 라인 중 하나가 여기서 깨진다.
    func testEveryLineTotalFormsMatchesStageCount() async throws {
        for digiLine in DigimonData.lines {
            let evoLine = try await provider.line(baseSpeciesID: digiLine.baseID)
            XCTAssertEqual(evoLine.totalForms, digiLine.totalForms,
                "base \(digiLine.baseID): totalForms \(evoLine.totalForms) != stages.count \(digiLine.totalForms)")
        }
    }

    /// **강등 방지 가드.** 추첨(부화 후보 선정)은 captureRate 로, 표시·등급 보증 검증은
    /// `EvoLine.rarity`(= `DigiLine.rarity` 그대로)로 완전히 분리된 두 경로다(`CompanionStore.chooseBase`
    /// 는 captureRate 만 쓰고 `Rarity.from` 을 호출하지 않으며, `hatchCore` 의 등급 보증 검증은
    /// `line.rarity.sortRank` 만 본다). legendary 라인이 captureRate 표현을 위해 rare 밴드 값을
    /// 받는다고 해서(아래 왕복 테스트 참고) `line()` 이 반환하는 표시 등급까지 rare 로 낮아지면 안 된다 —
    /// 이 테스트가 그 조용한 강등을 잡는다.
    func testLineRarityMatchesDigiLineRarityRegardlessOfCaptureRate() async throws {
        for digiLine in DigimonData.lines {
            let evoLine = try await provider.line(baseSpeciesID: digiLine.baseID)
            XCTAssertEqual(evoLine.rarity, digiLine.rarity,
                "base \(digiLine.baseID): line() 표시 등급이 \(evoLine.rarity) — captureRate 매핑으로 강등됨(원래 \(digiLine.rarity))")
        }
    }

    /// tree 가 선형 사슬이다 — 죠그레스/아머는 이번 단계에서 트리에 들어가지 않는다(§ 파일 상단 주석).
    func testTreeIsALinearChainForEveryLine() async throws {
        for digiLine in DigimonData.lines {
            let evoLine = try await provider.line(baseSpeciesID: digiLine.baseID)
            var node = evoLine.tree
            var visited = [node.speciesID]
            while let onlyChild = node.children.first {
                XCTAssertLessThanOrEqual(node.children.count, 1,
                    "base \(digiLine.baseID): 노드 \(node.speciesID) 가 자식 \(node.children.count)개 — 선형 사슬 아님")
                node = onlyChild
                visited.append(node.speciesID)
            }
            XCTAssertEqual(visited, digiLine.stages.map(\.id),
                "base \(digiLine.baseID): 사슬 순서가 stages 원본과 다름")
        }
    }

    /// 라인의 모든 stage id 는 DigimonDataLoader 가 보장하는 이름을 갖는다(§ 회귀 가드) — 이름
    /// 매핑이 깨지면 여기서 XCTUnwrap 이 실패해야 한다. `guard ... else { continue }` 로 건너뛰면
    /// 매핑이 깨져도 단언 자체가 실행되지 않아 테스트가 초록으로 통과하는 공허 통과가 된다.
    func testNamesAreFilledFromDigimonDataAndMatchApiName() async throws {
        for digiLine in DigimonData.lines {
            let evoLine = try await provider.line(baseSpeciesID: digiLine.baseID)
            for stage in digiLine.stages {
                let expected = try XCTUnwrap(DigimonData.name(for: stage.id),
                    "species \(stage.id): DigimonDataLoader 가 보장해야 할 이름이 없음")
                XCTAssertEqual(evoLine.names[stage.id]?["en"], expected.apiName,
                    "species \(stage.id): 이름 매핑 누락/불일치")
            }
        }
    }

    /// base 가 아닌 ID(중간체)는 line() 이 조용히 빈 라인이 아니라 throw 해야 한다.
    /// Greymon(34)은 agumon 라인의 중간체이자 유효한 종 ID라 base==false 판정의 판별력 있는 사례.
    func testLineThrowsForNonBaseID() async {
        do {
            _ = try await provider.line(baseSpeciesID: 34)
            XCTFail("Greymon(34) 은 base 가 아닌데 throw 하지 않음")
        } catch {
            // 기대된 경로 — 어떤 에러 타입이든 throw 만 되면 됨.
        }
    }

    // MARK: - baseSpeciesIndex / baseSpecies

    /// 12개 라인 전체가 인덱스에 나오고, 각 captureRate 를 Rarity.from(...) 에 넣으면
    /// **원래 라인의 rarity 밴드로 되돌아온다.** 이게 이 작업의 핵심 단언(왕복 검증)이다.
    ///
    /// legendary(agumon, gabumon)는 예외: captureRateCeiling 이 nil 이라 captureRate 로는
    /// "legendary" 자체를 표현할 수 없다(Rarity.from 은 isLegendary/isMythical 플래그로만 legendary를
    /// 반환하고 BaseSpecies 에는 그 플래그가 없다). 대신 "전설은 전부 capture_rate ≤45"라는 PokéAPI
    /// 성질을 따라 rare 밴드 안에 있는지만 확인한다 — 이래야 "희귀 이상" 등급 보증 알 필터에
    /// legendary 라인이 자연히 포함된다(CompanionStore.chooseBase 문서 참고).
    func testBaseSpeciesIndexCaptureRateRoundTripsToOriginalRarity() async throws {
        let index = try await provider.baseSpeciesIndex()
        XCTAssertEqual(index.count, 12)
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })

        for digiLine in DigimonData.lines {
            guard let entry = byID[digiLine.baseID] else {
                XCTFail("base \(digiLine.baseID) 가 인덱스에 없음")
                continue
            }
            if digiLine.rarity == .legendary {
                XCTAssertTrue(Rarity.rare.includes(captureRate: entry.captureRate),
                    "legendary base \(digiLine.baseID): captureRate \(entry.captureRate) 가 rare 밴드(≤45) 밖 — 등급 보증 알에서 누락됨")
            } else {
                let roundTripped = Rarity.from(captureRate: entry.captureRate, isLegendary: false, isMythical: false)
                XCTAssertEqual(roundTripped, digiLine.rarity,
                    "base \(digiLine.baseID): captureRate \(entry.captureRate) 가 \(roundTripped) 로 판정됨(원래 \(digiLine.rarity))")
            }
        }
    }

    /// 등급 간 상대 가중치(=captureRate)가 뒤집히지 않는다 — CollectionWeight.adjusted 가 값을
    /// 그대로 가중치로 쓰고 클수록 흔하므로, legendary < rare < uncommon < common 순으로 커져야 한다.
    func testCaptureRateOrderingMatchesRarityOrdering() async throws {
        let index = try await provider.baseSpeciesIndex()
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })
        func maxRate(_ rarity: Rarity) -> Int {
            DigimonData.lines.filter { $0.rarity == rarity }.compactMap { byID[$0.baseID]?.captureRate }.max()!
        }
        let legendary = maxRate(.legendary), rare = maxRate(.rare), uncommon = maxRate(.uncommon), common = maxRate(.common)
        XCTAssertLessThan(legendary, rare)
        XCTAssertLessThan(rare, uncommon)
        XCTAssertLessThan(uncommon, common)
    }

    /// baseSpecies(id:) 는 12개 base 각각에 대해 baseSpeciesIndex() 와 같은 captureRate 를 준다.
    func testBaseSpeciesMatchesIndexForEveryBase() async throws {
        let index = try await provider.baseSpeciesIndex()
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0.captureRate) })
        for digiLine in DigimonData.lines {
            let bs = try await provider.baseSpecies(id: digiLine.baseID)
            XCTAssertEqual(bs?.captureRate, byID[digiLine.baseID])
        }
    }

    /// base 가 아닌 ID(중간체) 는 nil.
    func testBaseSpeciesIsNilForNonBaseID() async throws {
        let result = try await provider.baseSpecies(id: 34)   // Greymon — agumon 라인 중간체
        XCTAssertNil(result)
    }

    /// **매핑 누락 방지 가드.** captureRate 는 `DigimonData.lines` 의 `rarity` 에서 함수로 유도되므로
    /// baseID 별 테이블이 존재하지 않는다 — 즉 라인을 추가해도 이 매핑 자체는 어긋날 수 없다. 이 테스트는
    /// 그 유도가 실제로 모든 라인에 적용되는지, 그리고 유도값이 다시 원래 rarity 로 왕복하는지를 고정한다.
    /// 과거엔 baseID 를 키로 하는 별도 테이블이 있어 `DigimonData.lines` 와 독립이었고, 라인을 추가하고
    /// 테이블에 안 넣으면 `?? 255` 폴백으로 조용히 common 최흔값이 됐다(§ dormant fallback trap).
    /// legendary 는 captureRate 로 표현 불가하므로 왕복 대신 `Rarity.rare.includes(_:)` 로 확인한다.
    func testEveryLineDerivesCaptureRateAndRoundTripsToRarity() async throws {
        let index = try await provider.baseSpeciesIndex()
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })

        for digiLine in DigimonData.lines {
            guard let entry = byID[digiLine.baseID] else {
                XCTFail("base \(digiLine.baseID) 가 captureRate 매핑을 못 받음 — 유도 누락")
                continue
            }
            if digiLine.rarity == .legendary {
                XCTAssertTrue(Rarity.rare.includes(captureRate: entry.captureRate),
                    "legendary base \(digiLine.baseID): captureRate \(entry.captureRate) 가 rare 밴드(≤45) 밖")
            } else {
                let roundTripped = Rarity.from(captureRate: entry.captureRate, isLegendary: false, isMythical: false)
                XCTAssertEqual(roundTripped, digiLine.rarity,
                    "base \(digiLine.baseID): captureRate \(entry.captureRate) 가 \(roundTripped) 로 판정됨(원래 \(digiLine.rarity))")
            }
        }
    }
}
