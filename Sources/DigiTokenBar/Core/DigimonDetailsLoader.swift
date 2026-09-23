import Foundation

// Resources/digimon_details.json 로더. 파싱 + 무결성 검증만 담당한다
// (UI·네트워크 금지 — DigimonDataLoader.swift 와 동일한 제약).
//
// 로딩 구조는 DigimonDataLoader 와 같다 — 핵심 로더가 URL/Data 를 받고, 앱 전용 진입점만
// Bundle.main 을 쓴다. Bundle.module 은 실패 시 throw 가 아니라 fatalError trap 이라 쓰지 않는다.
//
// 모델 타입은 DigimonLore.swift 의 것(DigimonLore 와 그 중첩 타입)을 그대로 쓴다 —
// 같은 JSON 에 모델이 둘이면 상세 패널이 보는 타입과 로더가 내놓는 타입이 갈라진다.
// 이 파일은 JSON 스키마 전용 raw 타입만 private 으로 두고 매핑한다(RawDataset.Species →
// DigimonName 과 같은 구조). JSON 필드명이 `id` 인데 DigimonLore 는 `speciesID` 라, 남의 타입에
// CodingKeys 를 얹는 대신 여기서 옮겨 담는다.
//
// 에러 타입을 DigimonDataError 와 공유하지 않는 이유: 그쪽은 Equatable 이고
// `.resourceNotFound` 설명이 "digimon.json" 을 하드코딩하고 있어, 이 파일의 실패를
// 거기 얹으면 잘못된 파일명을 가리키는 메시지가 나온다.

/// 상세 데이터 디코딩·무결성 검증 실패 원인. 관대한 기본값 흡수 없이 전부 throw 한다 —
/// 조용히 삼키면 도감이 "설명이 비어 있는" 상태로 멀쩡히 돌아간다.
enum DigimonDetailsError: Error, CustomStringConvertible, Equatable {
    /// 리소스 파일을 찾지 못함(앱 번들 진입점 전용 — 핵심 로더는 URL 을 직접 받으므로 해당 없음).
    case resourceNotFound
    /// JSON 디코딩 자체 실패. 메시지는 근본 원인 설명용(Equatable 비교엔 안 씀).
    case decodingFailed(String)
    /// 같은 species id 가 두 번 등장.
    case duplicateSpecies(id: Int)
    /// 필수 문자열 필드가 비어 있음(공백만 있는 경우 포함).
    case emptyField(id: Int, field: String)
    /// 알려진 4종(백신/데이터/바이러스/프리) 밖의 속성 표기. 기본값으로 흡수하면 틀린 속성이 표시된다.
    case unknownAttribute(id: Int, value: String)

    var description: String {
        switch self {
        case .resourceNotFound:
            return "digimon_details.json 을 앱 번들에서 찾지 못함"
        case .decodingFailed(let reason):
            return "digimon_details.json 디코딩 실패: \(reason)"
        case .duplicateSpecies(let id):
            return "상세 데이터에 species id \(id) 가 중복 등장"
        case .emptyField(let id, let field):
            return "species id \(id) 의 \(field) 가 비어 있음"
        case .unknownAttribute(let id, let value):
            return "species id \(id) 의 속성 '\(value)' 가 알려진 4종이 아님"
        }
    }
}

// MARK: - JSON 원시 스키마

/// `Resources/digimon_details.json` 의 최상위 구조. `digimon.json` 과 같은 이유로 맵이 아니라
/// 배열을 쓴다 — 맵이었다면 중복 id 가 디코딩 단계에서 마지막 값으로 조용히 덮여
/// 중복 검증이 애초에 불가능해진다.
private struct RawDetailsDocument: Decodable {
    /// 필살기 하나. `|d=`(북미 더빙명)는 담지 않는다 — 한국 더빙명과 어긋나 한국어 표기 대용으로
    /// 쓰이면 틀린 이름이 노출된다. 그래서 `DigimonAttack.nameKo` 는 항상 nil 로 매핑된다.
    struct Attack: Decodable {
        let nameJa: String
        let romaji: String
    }
    struct Detail: Decodable {
        let id: Int
        let level: DigiLevel
        /// 문자열로 받는다 — `DigimonLore.Attribute` 는 Decodable 이 아니고, 대소문자 정규화가
        /// `init?(dataValue:)` 에 있다. 모르는 값은 아래에서 unknownAttribute 로 throw 한다.
        let attribute: String
        let type: String
        /// 한국 정발명. 52종 중 23종에만 존재하므로 JSON 에서 키 자체를 생략한다(null 금지).
        let nameKo: String?
        let attacks: [Attack]
        /// 데이터 파일에서는 필수다(`DigimonLore.summaryKo` 는 옵셔널이지만 빈 값은 로더가 막는다).
        let summaryKo: String
    }

    /// CC BY-SA 3.0 출처 표기 의무. 값을 버리지 않고 데이터셋까지 실어 나른다.
    let _source: String
    let _license: String
    let details: [Detail]
}

// MARK: - 로드 결과

/// 검증까지 마친 상세 데이터셋. `byID` 가 곧 상세 패널의 조회 테이블이다.
struct DigimonDetailsDataset: Sendable {
    /// 출처 표기 의무(CC BY-SA 3.0) — UI 크레딧 표기용으로 값을 보존한다.
    let source: String
    let license: String
    let byID: [Int: DigimonLore]
}

enum DigimonDetailsLoader {

    /// 핵심 로더. URL 을 받아 Data 를 읽고 디코딩 + 검증한다. 테스트는 이 함수에 직접
    /// `#filePath` 기반 저장소 경로를 넘겨 Bundle 의미론을 우회한다.
    static func load(from url: URL) throws -> DigimonDetailsDataset {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DigimonDetailsError.decodingFailed("파일 읽기 실패: \(error.localizedDescription)")
        }
        return try load(from: data)
    }

    /// Data 를 직접 받는 버전 — 뮤테이션 테스트가 파일 없이 조작된 JSON 을 바로 검증할 때 쓴다.
    static func load(from data: Data) throws -> DigimonDetailsDataset {
        let raw: RawDetailsDocument
        do {
            raw = try JSONDecoder().decode(RawDetailsDocument.self, from: data)
        } catch {
            throw DigimonDetailsError.decodingFailed("\(error)")
        }

        var byID: [Int: DigimonLore] = [:]
        for detail in raw.details {
            guard byID[detail.id] == nil else {
                throw DigimonDetailsError.duplicateSpecies(id: detail.id)
            }
            // 빈 문자열은 디코딩을 통과하므로 여기서 막는다 — "설명이 비었는데 로드는 성공"
            // 상태가 상세 패널까지 흘러가면 화면이 빈 칸으로 남는다.
            for (name, value) in [("type", detail.type), ("summaryKo", detail.summaryKo)] {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DigimonDetailsError.emptyField(id: detail.id, field: name)
                }
            }
            // attacks 도 같은 계약을 받는다 — 빈 배열이나 빈 이름이 통과하면 상세 패널의
            // 필살기 섹션이 아무 표시 없이 사라져 "데이터 없음" 과 구분이 안 된다.
            guard !detail.attacks.isEmpty else {
                throw DigimonDetailsError.emptyField(id: detail.id, field: "attacks")
            }
            for (index, attack) in detail.attacks.enumerated() {
                for (name, value) in [("nameJa", attack.nameJa), ("romaji", attack.romaji)] {
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw DigimonDetailsError.emptyField(id: detail.id, field: "attacks[\(index)].\(name)")
                    }
                }
            }
            guard let attribute = DigimonLore.Attribute(dataValue: detail.attribute) else {
                throw DigimonDetailsError.unknownAttribute(id: detail.id, value: detail.attribute)
            }
            byID[detail.id] = DigimonLore(
                speciesID: detail.id,
                level: detail.level,
                attribute: attribute,
                type: detail.type,
                nameKo: detail.nameKo,
                attacks: detail.attacks.map {
                    DigimonLore.Attack(nameJa: $0.nameJa, romaji: $0.romaji)
                },
                summaryKo: detail.summaryKo)
        }

        return DigimonDetailsDataset(source: raw._source, license: raw._license, byID: byID)
    }

    /// 앱 전용 진입점. `Bundle.main` 에서 못 찾으면 반드시 throw 한다(trap 금지).
    static func loadFromAppBundle() throws -> DigimonDetailsDataset {
        guard let url = Bundle.main.url(forResource: "digimon_details", withExtension: "json") else {
            throw DigimonDetailsError.resourceNotFound
        }
        return try load(from: url)
    }
}

extension DigimonData {

    /// 상세 데이터 로드 결과 캐시. `DigimonData.loadResult` 와 같은 패턴 —
    /// `Bundle.main` 우선, DEBUG 빌드에서만 `#filePath` 로 저장소 루트를 보조 탐색한다
    /// (`swift test`/`swift run` 은 Bundle.main 에 리소스가 없다).
    static let detailsLoadResult: Result<DigimonDetailsDataset, any Error> = Result {
        if let url = Bundle.main.url(forResource: "digimon_details", withExtension: "json") {
            return try DigimonDetailsLoader.load(from: url)
        }
        #if DEBUG
        // #filePath: .../Sources/DigiTokenBar/Core/DigimonDetailsLoader.swift → 저장소 루트까지 4단계 위.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Core/
            .deletingLastPathComponent()  // DigiTokenBar/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // 저장소 루트
        let devURL = repoRoot.appendingPathComponent("Resources/digimon_details.json")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return try DigimonDetailsLoader.load(from: devURL)
        }
        #endif
        throw DigimonDetailsError.resourceNotFound
    }

    /// 검증 실패를 명시적으로 다루고 싶은 호출부용 진입점.
    static func loadedDetails() throws -> DigimonDetailsDataset {
        try detailsLoadResult.get()
    }

    /// 로드 실패 원인을 딱 1회만 로그로 남기기 위한 부수효과 전용 캐시. `lore(for:)` 는 조회할
    /// 때마다(뷰 재렌더링마다) 불릴 수 있어, 로그를 그 함수 안에 그대로 두면 실패가 계속될 때
    /// 매번 다시 기록된다 — `detailsLoadResult` 자체가 `static let` 인 것과 별개로, 이 프로퍼티가
    /// 한 번만 평가되는 지점에 로그를 둬서 프로세스당 정확히 1회만 기록되게 한다.
    private static let loggedDetailsLoadFailure: Void = {
        if case .failure(let error) = detailsLoadResult {
            AppLog.write("digimon details load failed: \(error)")
        }
    }()

    /// 한 종의 설정 정보. 로드 실패나 미등록 id 면 nil — 상세 패널은 없어도 앱이 동작해야 하므로
    /// 진화 데이터(`ds`)와 달리 trap 하지 않는다.
    static func lore(for id: Int) -> DigimonLore? {
        _ = loggedDetailsLoadFailure
        return (try? detailsLoadResult.get())?.byID[id]
    }
}

/// 번들 `Resources/digimon_details.json` 을 읽는 설정 정보 출처. `CompanionStore(loreSource:)` 로
/// 주입한다 — 표시 계층은 이 타입 이름에도 로드 시점에도 의존하지 않는다(DigimonLore.swift 참고).
/// 로드 실패·미등록 id 는 nil 이고, 화면은 스피너가 아니라 "정보 없음" 을 명시적으로 보여준다.
struct DigimonDetailsBundleSource: DigimonLoreProviding {
    func lore(speciesID: Int) -> DigimonLore? { DigimonData.lore(for: speciesID) }
}
