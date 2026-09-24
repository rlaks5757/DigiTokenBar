import Foundation

// 디지몬 진화 데이터 (01 + 02 범위). 근거·검증 결과는 docs/EVOLUTION.md 전체,
// 희귀도 수기 배정 근거는 docs/GAME-DESIGN.md §2 참고. ID 는 digi-api.com 기준.
//
// 값 리터럴은 EVOLUTION.md §6 결정에 따라 Resources/digimon.json 으로 옮겨졌다.
// 이 파일은 그 값을 표현하는 타입 + JSON 을 감싸는 조회 파사드만 담는다
// (UI·네트워크 로직 금지 — 로드·검증 자체는 DigimonDataLoader.swift 책임).

/// 디지몬 성장 단계(레벨). EVOLUTION.md §1 표 그대로.
/// **순환 그래프 주의**: 원본 진화 데이터는 양방향 간선을 갖는다(Agumon↔Greymon).
/// 아래 라인 테이블은 이미 "레벨 단조 증가" 필터를 적용해 수기로 확정한 결과이므로
/// 여기서 다시 그래프를 순회하지 않는다.
/// `String` raw value는 JSON 디코딩 키용(케이스명 그대로: "child" 등) — ladderRank 의 정수 축과는
/// 무관하다(아래 설명 참고).
enum DigiLevel: String, Sendable, CaseIterable, Codable {
    case babyI, babyII, child, adult, perfect, ultimate
    case armor   // 정규 사다리 밖 분기 — 아래 ladderRank 참고

    /// 정규 사다리 위의 순위. armor 는 사다리 밖이라 **정수로 비교 불가능해야 한다** —
    /// 여기서 Int rawValue 를 안 쓰고 nil 을 반환하는 이유. (Rarity.captureRateCeiling 과 같은 패턴:
    /// "이 축으로 표현 불가능한 값은 nil".) 단조 증가 검증은 이 값으로만 한다.
    var ladderRank: Int? {
        switch self {
        case .babyI:   return 0
        case .babyII:  return 1
        case .child:   return 2
        case .adult:   return 3
        case .perfect: return 4
        case .ultimate: return 5
        case .armor:   return nil
        }
    }
}

/// 아머 진화용 디지멘탈(Digimental) 아이템. EVOLUTION.md §4.
/// `String` raw value는 JSON 디코딩 키용(케이스명 그대로).
enum Digimental: String, Sendable, CaseIterable, Codable {
    case courage, sincerity, miracles, love, purity, knowledge, hope, light, friendship

    /// Wikimon 아이템 아트 파일명(`Digimental_<trait>.jpg`, MD5 해시 경로는 SpriteStore 가 처리).
    /// 케이스마다 명시 — `"Digimental_\(rawValue).jpg"` 로 일반화하면 새 케이스가 추가돼도 항상
    /// 문자열을 만들어내 컴파일은 통과하지만 실제로는 404 날 수 있다(아래 sincerity 가 그 실례).
    /// `default:` 없는 exhaustive switch라 케이스 추가 시 매핑을 안 채우면 컴파일 에러로 막힌다.
    var wikimonFilename: String {
        switch self {
        case .courage: return "Digimental_courage.jpg"
        // Wikimon 은 이 디지멘탈을 "reliability"로 표기한다(더빙/번역판 명칭 분기 — 국내외 매체마다
        // sincerity/reliability 로 갈렸다). 우리 쪽 케이스명(sincerity)과 다르므로 실수로
        // "Digimental_sincerity.jpg" 로 되돌리면 404 난다 — 자산이 없는 게 아니라 이름이 다른 것.
        case .sincerity: return "Digimental_reliability.jpg"
        case .miracles: return "Digimental_miracles.jpg"
        case .love: return "Digimental_love.jpg"
        case .purity: return "Digimental_purity.jpg"
        case .knowledge: return "Digimental_knowledge.jpg"
        case .hope: return "Digimental_hope.jpg"
        case .light: return "Digimental_light.jpg"
        case .friendship: return "Digimental_friendship.jpg"
        }
    }
}

/// 진화 라인의 한 단계. 레벨은 인덱스에서 유추하지 않고 라인마다 직접 지정한다 —
/// 라인마다 보유 레벨 집합이 다르다(예: Tailmon 라인은 Adult 가 없고 아래 Child 열의
/// Tailmon 자체가 Child 취급이다. 02 파트너 라인은 Adult 에서 정규 사다리가 끝난다).
struct DigiStage: Sendable {
    let id: Int
    let level: DigiLevel
}

/// 정규 진화 라인 1개. 죠그레스/아머로만 도달하는 개체는 여기 포함하지 않는다(§3, §4 별도 테이블).
struct DigiLine: Sendable {
    let stages: [DigiStage]
    let rarity: Rarity

    /// 배열 길이(k)를 라인마다 다르게 가정 — 4로 고정하는 코드를 쓰지 않는다.
    var totalForms: Int { stages.count }
    var baseID: Int { stages[0].id }
}

/// 죠그레스 입력 키 — **순서 무관**. init 에서 정렬해 정규화하므로
/// 비정규화된 키 자체를 만들 수 없다(뒤집힌 키로 조회해도 항상 같은 버킷을 찾는다).
struct JogressKey: Hashable, Sendable {
    private let low: Int
    private let high: Int

    init(_ a: Int, _ b: Int) {
        low = min(a, b)
        high = max(a, b)
    }

    /// 입력 두 종의 ID — 참조 무결성 검사(예: 이름 매핑 완전성 테스트)가 순회할 수 있게 노출.
    var speciesIDs: [Int] { [low, high] }
}

/// 아머 진화 조회 키 — `(Child, 디지멘탈)` 복합키. 성실 디지멘탈처럼 여러 Child 에서
/// 공유되는 디지멘탈이 있어 디지멘탈 단독으로는 결과가 결정되지 않는다.
struct ArmorKey: Hashable, Sendable {
    let childID: Int
    let digimental: Digimental
}

/// 종 이름 표기 — digi-api 표시 이름과 Wikimon 스프라이트 파일명(vpet 접두, 시리즈 접미사 제외)을
/// 각각 따로 담는다. 문서 제목에서 파일명을 파생시키면 깨지는 사례가 실제로 있다(XV-mon → Xvmon).
/// → 런타임 이름 추론 금지, 매핑 테이블이 유일한 소스.
struct DigimonName: Sendable {
    let apiName: String
    /// Wikimon 파일명 어간(`<어간>_vpet_<series>.png` 의 `<어간>`). 시리즈 접미사는 여기 포함하지 않는다.
    let spriteStem: String
    /// EVOLUTION.md §6 "스프라이트 파일명 전수 검증" 에서 52종 전부 실측 확인됨 — 항상 true.
    /// 필드는 회귀 가드로 남겨둔다(향후 새 종 추가 시 미검증 상태를 표시할 수 있게).
    let spriteStemVerified: Bool
    /// 시리즈 자리가 `vb > ws > xloader` 폴백 체인으로 해결되지 않는 예외용. nil 이면 폴백 체인을 탄다.
    /// 값이 있으면 그 시리즈 하나로 확정된 파일명만 쓴다(폴백 없음).
    /// EVOLUTION.md §6 실측: Depthmon 은 시리즈 자리에 `dark_color` 라는 비표준 값이 오고,
    /// Imperialdramon Fighter/Paladin Mode 는 `<stem>` 자체가 `Imperialdramon_fighter`/`_paladin`
    /// (소문자 약칭, `Mode` 없음) 이면서 시리즈는 `vb` 로 고정이며, Dragon Mode(900, 내부 ID)는
    /// `<stem>` 이 `Imperialdramon_DM` 이면서 시리즈는 `xloader` 로 고정이다 — 셋 다 추정 규칙으로 못 만든다.
    let spriteSeriesPin: String?
    /// **digi-api 에 없는 내부 전용 id 인지.** 기본값 false — digi-api 실측 ID 를 쓰는 기존 종은
    /// 전부 이 값을 명시하지 않아도 false 로 흡수된다(하위호환). true 인 종(예: Imperialdramon
    /// Dragon Mode, id 900)은 실제 digi-api 조회를 시도하면 실패하므로, 런타임 fetch 호출부가
    /// 이 값으로 걸러야 한다 — EVOLUTION.md §3 Imperialdramon 체인 참고.
    let isInternalID: Bool
    /// 로케일별 표시 이름(langCode → 이름). **`en` 은 여기 담지 않는다** — `apiName` 이 곧 영어
    /// 표기이고, 같은 문자열을 두 벌 들면 한쪽만 고쳐져 갈라진다. 영어는 `localizedNames` 가
    /// `apiName` 으로 합성한다. 공식 표기 출처가 없는 언어(ja/es/fr/pt/de)는 **비워 둔다** —
    /// 지어낸 표기를 넣으면 틀린 정보가 뜨지만, 비워 두면 `resolve` 의 `en` 폴백이 올바르게 걸린다.
    let localeNames: [String: String]

    init(apiName: String, spriteStem: String, spriteStemVerified: Bool, spriteSeriesPin: String? = nil,
         isInternalID: Bool = false, localeNames: [String: String] = [:]) {
        self.apiName = apiName
        self.spriteStem = spriteStem
        self.spriteStemVerified = spriteStemVerified
        self.spriteSeriesPin = spriteSeriesPin
        self.isInternalID = isInternalID
        self.localeNames = localeNames
    }

    /// `AppLanguage.resolveName` / `DigimonNameLocalization.resolve` 에 그대로 넘기는 langCode→이름 맵.
    /// `en` 은 `apiName` 에서 합성하므로 ko 데이터가 없는 언어도 `#<id>` 가 아니라 영어로 폴백한다.
    /// 이름을 표시하는 모든 경로는 `apiName` 을 직접 읽지 말고 이 프로퍼티를 거쳐야 한다.
    ///
    /// `en` 은 **데이터에 들어 있어도 `apiName` 이 이긴다.** `localeNames` 문서가 "en 은 여기
    /// 담지 않는다" 를 계약으로 두는데, JSON 에 흘러든 `en` 이 이기게 두면 그 계약을 어긴 데이터가
    /// 조용히 표시까지 도달해 두 출처가 갈라진다(주석이 금지한 바로 그 상황). 합성값을 우선해
    /// 계약을 코드로 강제한다.
    var localizedNames: [String: String] {
        localeNames.merging(["en": apiName]) { _, synthesized in synthesized }
    }

    /// 시도할 스프라이트 파일명 후보 목록(우선순위 순). `spriteSeriesPin` 이 있으면 그 파일명
    /// 하나만, 없으면 EVOLUTION.md §6 폴백 체인(vb > ws > xloader) 순서로 3개를 반환한다.
    /// **파일명까지만** 다룬다 — 실제 URL 의 `<h1>/<h2>` MediaWiki 해시 경로는 파일명의
    /// MD5 로 fetch 시점에 유도되므로(`SpriteStore.wikimonRequest`), 네트워크 로직을 금지하는
    /// 이 파일(6번째 줄 참고)의 책임 밖이다.
    var spriteFilenames: [String] {
        let series = spriteSeriesPin.map { [$0] } ?? ["vb", "ws", "xloader"]
        return series.map { "\(spriteStem)_vpet_\($0).png" }
    }
}

enum DigimonData {

    /// 빈 상태(도감/가방) 안내 마스코트. 데이터에 실재하는 종이어야 한다 — 없는 id 를 쓰면
    /// 파일명 후보가 안 나와 스프라이트가 조용히 🥚 폴백으로 떨어진다(에러도 로그도 없다).
    /// 어드벤처 01/02 각 주인공 파트너를 쓴다. 가드: `testEmptyStateMascotsExistInTheDataset`.
    static let dexEmptyMascotID = 1     // Agumon (어드벤처 01)
    static let bagEmptyMascotID = 349   // V-mon (어드벤처 02)

    /// JSON 로드 + 검증 결과를 한 번만 계산해 캐시한다. `Result` 로 감싸 두어(캐시 자체는
    /// `static let` 이라 Swift 6 전역 가변 상태 진단을 안 만든다) 검증은 반드시 수행되고,
    /// 실패는 이름 붙은 에러(`DigimonDataError`)로 관측 가능하게 남는다.
    ///
    /// 리소스 탐색은 `Bundle.main` 만 쓴다 — 릴리스 `.app` 은 build-app.sh 가 복사한
    /// `Contents/Resources/digimon.json` 을 여기서 찾는다. `swift test`/`swift run` 처럼
    /// `Bundle.main` 에 리소스가 없는 개발 환경을 위해 DEBUG 빌드에서만 `#filePath` 로
    /// 저장소 루트의 `Resources/digimon.json` 을 보조로 찾는다(Bundle 의미론 우회, 릴리스엔 없음).
    static let loadResult: Result<DigimonDataset, any Error> = Result {
        if let url = Bundle.main.url(forResource: "digimon", withExtension: "json") {
            return try DigimonDataLoader.load(from: url)
        }
        #if DEBUG
        // #filePath: .../Sources/DigiTokenBar/Core/DigimonData.swift → 저장소 루트까지 3단계 위.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // Core/
            .deletingLastPathComponent()  // DigiTokenBar/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // 저장소 루트
        let devURL = repoRoot.appendingPathComponent("Resources/digimon.json")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return try DigimonDataLoader.load(from: devURL)
        }
        #endif
        throw DigimonDataError.resourceNotFound
    }

    /// 검증 실패를 명시적으로 다루고 싶은 호출부(예: 앱 시작 시퀀스)용 진입점.
    static func loaded() throws -> DigimonDataset {
        try loadResult.get()
    }

    /// 진화 다이어그램(라인별 12장, archify workflow) 정적 HTML 위치 — 파일명은
    /// `digivolution.<라인 키>.html`(라인 키는 `Resources/digimon.json` 의 `lines[].key`).
    /// `speciesID` 가 속한 라인을 `DigimonLineChapter.lineKey(for:dataset:)` 로 구해 해당 장만 연다
    /// (52종 전체를 보여주던 단일 페이지 대신 — "피요몬 진화트리를 누르면 피요몬만 보인다").
    /// `loadResult` 와 같은 이유로 `Bundle.main` 을 먼저 찾고, DEBUG 빌드에서만 `#filePath` 로
    /// 저장소 루트를 보조 탐색한다. 필수 데이터가 아니라 optional 기능이라 throw 하지 않고
    /// nil 로 "버튼 비활성화"를 표현한다(라인 키를 못 구해도 동일하게 nil).
    static func evolutionDiagramURL(speciesID: Int) -> URL? {
        guard let dataset = try? loadResult.get(),
              let lineKey = DigimonLineChapter.lineKey(for: speciesID, dataset: dataset)
        else { return nil }
        let filename = "digivolution.\(lineKey)"
        if let url = Bundle.main.url(forResource: filename, withExtension: "html") {
            return url
        }
        #if DEBUG
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // Core/
            .deletingLastPathComponent()  // DigiTokenBar/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // 저장소 루트
        let devURL = repoRoot.appendingPathComponent("Resources/\(filename).html")
        if FileManager.default.fileExists(atPath: devURL.path) {
            return devURL
        }
        #endif
        return nil
    }

    /// 아래 정적 프로퍼티들의 내부 캐시. 로드는 항상 성공해야 정상 상태다(리소스 누락·스키마
    /// 오류는 개발/빌드 단계에서 잡아야 할 문제) — 실패 시 `try!` 로 즉시 트랩하되, 트랩 메시지에
    /// `DigimonDataError.description` 이 실려 원인을 바로 알 수 있다(무조건 `fatalError` 인
    /// `Bundle.module` trap 과 달리, 검증은 이미 끝난 뒤의 실패라는 점이 다르다).
    private static var ds: DigimonDataset {
        do {
            return try loadResult.get()
        } catch {
            fatalError("DigimonData 로드 실패: \(error)")
        }
    }

    // MARK: - 정규 진화 라인 (EVOLUTION.md §2) — 이름 있는 라인 접근자는 JSON 의 "key" 로 조회한다.

    static var agumonLine: DigiLine { ds.linesByKey["agumon"]! }
    static var gabumonLine: DigiLine { ds.linesByKey["gabumon"]! }
    static var piyomonLine: DigiLine { ds.linesByKey["piyomon"]! }
    static var tentomonLine: DigiLine { ds.linesByKey["tentomon"]! }
    static var palmonLine: DigiLine { ds.linesByKey["palmon"]! }
    static var gomamonLine: DigiLine { ds.linesByKey["gomamon"]! }
    static var patamonLine: DigiLine { ds.linesByKey["patamon"]! }
    /// Tailmon 자체는 작중 Adult 급으로 언급되지만(§2 비고), 데이터상 Child 열에 있고
    /// 이 라인엔 Adult 단계가 없다 — **표기된 레벨을 그대로 쓴다(작중 설정으로 임의 승격 금지)**.
    static var tailmonLine: DigiLine { ds.linesByKey["tailmon"]! }
    static var vmonLine: DigiLine { ds.linesByKey["vmon"]! }
    static var wormmonLine: DigiLine { ds.linesByKey["wormmon"]! }
    static var hawkmonLine: DigiLine { ds.linesByKey["hawkmon"]! }
    static var armadimonLine: DigiLine { ds.linesByKey["armadimon"]! }

    /// 정규 진화 라인 12개 전체.
    static var lines: [DigiLine] { ds.lines }

    // MARK: - 죠그레스 (EVOLUTION.md §3)

    /// `(A, B) → 결과 ID`. 키는 `JogressKey` 로 정규화되어 순서 무관 조회가 보장된다.
    /// Paildramon(331) → Imperialdramon Dragon Mode(900, 내부 ID) → Fighter Mode(405) 는
    /// 두 부모가 필요한 죠그레스가 아니라 단일 부모 전이라 여기 없다 — `DigimonDataset.forwardEdges`
    /// (chain 배치)로 표현된다. §3 참고.
    static var jogressResults: [JogressKey: Int] { ds.jogressResults }

    static func jogressResult(_ a: Int, _ b: Int) -> Int? {
        ds.jogressResults[JogressKey(a, b)]
    }

    // MARK: - 아머 진화 (EVOLUTION.md §4)

    /// `(Child, 디지멘탈) → 아머형 ID`. 성실 디지멘탈은 V-mon·Armadimon 양쪽에 쓰이므로
    /// 디지멘탈 단독 조회는 불가능하다 — 반드시 복합키로 조회한다.
    static var armorResults: [ArmorKey: Int] { ds.armorResults }

    static func armorResult(childID: Int, digimental: Digimental) -> Int? {
        ds.armorResults[ArmorKey(childID: childID, digimental: digimental)]
    }

    // MARK: - 이름 매핑 (EVOLUTION.md §5, §3 하위 실검증)

    /// speciesID → 이름 표기. §6 "스프라이트 파일명 전수 검증" 에서 52종 전부 Wikimon API 로
    /// 실측 확인되어 전 항목 `spriteStemVerified: true` 다(이후 추가된 Dragon Mode(900)도 팀 리드가
    /// 별도 실측). 그중 4건(Depthmon, Imperialdramon Fighter/Paladin/Dragon Mode)은
    /// `vb > ws > xloader` 폴백 규칙으로 못 만드는 파일명이라 `spriteSeriesPin` 으로 확정 파일명을
    /// 고정한다 — 위 DigimonName 문서 참고.
    static var names: [Int: DigimonName] { ds.names }

    static func name(for speciesID: Int) -> DigimonName? {
        ds.names[speciesID]
    }
}
