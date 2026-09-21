import Foundation

// 디지몬 진화 데이터 (01 + 02 범위). 근거·검증 결과는 docs/EVOLUTION.md 전체,
// 희귀도 수기 배정 근거는 docs/GAME-DESIGN.md §2 참고. ID 는 digi-api.com 기준.
//
// 이 파일은 순수 데이터 + 조회 헬퍼만 담는다(UI·네트워크·저장 로직 금지).

/// 디지몬 성장 단계(레벨). EVOLUTION.md §1 표 그대로.
/// **순환 그래프 주의**: 원본 진화 데이터는 양방향 간선을 갖는다(Agumon↔Greymon).
/// 아래 라인 테이블은 이미 "레벨 단조 증가" 필터를 적용해 수기로 확정한 결과이므로
/// 여기서 다시 그래프를 순회하지 않는다.
enum DigiLevel: Sendable, CaseIterable {
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
enum Digimental: Sendable, CaseIterable {
    case courage, sincerity, miracles, love, purity, knowledge, hope, light
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
    /// EVOLUTION.md §6 "스프라이트 파일명 전수 검증" 에서 48종 전부 실측 확인됨 — 항상 true.
    /// 필드는 회귀 가드로 남겨둔다(향후 새 종 추가 시 미검증 상태를 표시할 수 있게).
    let spriteStemVerified: Bool
    /// 시리즈 자리가 `vb > ws > xloader` 폴백 체인으로 해결되지 않는 예외용. nil 이면 폴백 체인을 탄다.
    /// 값이 있으면 그 시리즈 하나로 확정된 파일명만 쓴다(폴백 없음).
    /// EVOLUTION.md §6 실측: Depthmon 은 시리즈 자리에 `dark_color` 라는 비표준 값이 오고,
    /// Imperialdramon Fighter/Paladin Mode 는 `<stem>` 자체가 `Imperialdramon_fighter`/`_paladin`
    /// (소문자 약칭, `Mode` 없음) 이면서 시리즈는 `vb` 로 고정이다 — 둘 다 추정 규칙으로 못 만든다.
    let spriteSeriesPin: String?

    init(apiName: String, spriteStem: String, spriteStemVerified: Bool, spriteSeriesPin: String? = nil) {
        self.apiName = apiName
        self.spriteStem = spriteStem
        self.spriteStemVerified = spriteStemVerified
        self.spriteSeriesPin = spriteSeriesPin
    }

    /// 시도할 스프라이트 파일명 후보 목록(우선순위 순). `spriteSeriesPin` 이 있으면 그 파일명
    /// 하나만, 없으면 EVOLUTION.md §6 폴백 체인(vb > ws > xloader) 순서로 3개를 반환한다.
    /// **파일명까지만** 다룬다 — 실제 URL 의 `<h1>/<h2>` MediaWiki 해시 경로는 파일명에서
    /// 추측 불가능하고(§6 실측) 파일 페이지·API 조회로 fetch 시점에 풀어야 하므로,
    /// 네트워크 로직을 금지하는 이 파일(6번째 줄 참고)의 책임 밖이다.
    var spriteFilenames: [String] {
        let series = spriteSeriesPin.map { [$0] } ?? ["vb", "ws", "xloader"]
        return series.map { "\(spriteStem)_vpet_\($0).png" }
    }
}

enum DigimonData {

    // MARK: - 01 파트너 8라인 (EVOLUTION.md §2)

    static let agumonLine = DigiLine(
        stages: [
            DigiStage(id: 1, level: .child),
            DigiStage(id: 34, level: .adult),
            DigiStage(id: 169, level: .perfect),
            DigiStage(id: 202, level: .ultimate),
        ],
        rarity: .legendary)   // Ultimate 보유 + 오메가몬 부모 (GAME-DESIGN.md §2)

    static let gabumonLine = DigiLine(
        stages: [
            DigiStage(id: 16, level: .child),
            DigiStage(id: 33, level: .adult),
            DigiStage(id: 205, level: .perfect),
            DigiStage(id: 168, level: .ultimate),
        ],
        rarity: .legendary)

    static let piyomonLine = DigiLine(
        stages: [
            DigiStage(id: 101, level: .child),
            DigiStage(id: 5, level: .adult),
            DigiStage(id: 165, level: .perfect),
        ],
        rarity: .common)   // 01 조연 4라인

    static let tentomonLine = DigiLine(
        stages: [
            DigiStage(id: 85, level: .child),
            DigiStage(id: 35, level: .adult),
            DigiStage(id: 40, level: .perfect),
        ],
        rarity: .common)

    static let palmonLine = DigiLine(
        stages: [
            DigiStage(id: 81, level: .child),
            DigiStage(id: 195, level: .adult),
            DigiStage(id: 166, level: .perfect),
        ],
        rarity: .common)

    static let gomamonLine = DigiLine(
        stages: [
            DigiStage(id: 117, level: .child),
            DigiStage(id: 124, level: .adult),
            DigiStage(id: 96, level: .perfect),
        ],
        rarity: .common)

    static let patamonLine = DigiLine(
        stages: [
            DigiStage(id: 98, level: .child),
            DigiStage(id: 3, level: .adult),
            DigiStage(id: 121, level: .perfect),
        ],
        rarity: .rare)   // 작중 비중 높음

    /// Tailmon 자체는 작중 Adult 급으로 언급되지만(§2 비고), 데이터상 Child 열에 있고
    /// 이 라인엔 Adult 단계가 없다 — **표기된 레벨을 그대로 쓴다(작중 설정으로 임의 승격 금지)**.
    static let tailmonLine = DigiLine(
        stages: [
            DigiStage(id: 83, level: .child),
            DigiStage(id: 38, level: .perfect),
        ],
        rarity: .rare)

    // MARK: - 02 파트너 4라인 (EVOLUTION.md §2) — 정규 사다리는 Adult 에서 끝난다.

    static let vmonLine = DigiLine(
        stages: [
            DigiStage(id: 349, level: .child),
            DigiStage(id: 358, level: .adult),
        ],
        rarity: .uncommon)   // 02 파트너 4라인

    static let wormmonLine = DigiLine(
        stages: [
            DigiStage(id: 356, level: .child),
            DigiStage(id: 336, level: .adult),
        ],
        rarity: .uncommon)

    static let hawkmonLine = DigiLine(
        stages: [
            DigiStage(id: 399, level: .child),
            DigiStage(id: 267, level: .adult),
        ],
        rarity: .uncommon)

    static let armadimonLine = DigiLine(
        stages: [
            DigiStage(id: 271, level: .child),
            DigiStage(id: 266, level: .adult),
        ],
        rarity: .uncommon)

    /// 정규 진화 라인 12개 전체.
    static let lines: [DigiLine] = [
        agumonLine, gabumonLine, piyomonLine, tentomonLine, palmonLine, gomamonLine,
        patamonLine, tailmonLine,
        vmonLine, wormmonLine, hawkmonLine, armadimonLine,
    ]

    // MARK: - 죠그레스 (EVOLUTION.md §3)

    /// `(A, B) → 결과 ID`. 키는 `JogressKey` 로 정규화되어 순서 무관 조회가 보장된다.
    /// Imperialdramon Dragon Mode 는 §3 체인 서술에만 등장하고 ID·죠그레스 입력이 없다
    /// (§5: 단독 조회 HTTP 400) — 여기서 임의로 ID 를 만들지 않는다.
    static let jogressResults: [JogressKey: Int] = [
        JogressKey(358, 336): 331,   // XV-mon + Stingmon → Paildramon
        JogressKey(83, 267): 390,    // Tailmon + Aquilamon → Silphymon
        JogressKey(266, 3): 387,     // Ankylomon + Angemon → Shakkoumon
        JogressKey(202, 168): 183,   // War Greymon + Metal Garurumon → Omegamon
        JogressKey(405, 183): 481,   // Imperialdramon(Fighter Mode) + Omegamon → Imperialdramon(Paladin Mode)
    ]

    static func jogressResult(_ a: Int, _ b: Int) -> Int? {
        jogressResults[JogressKey(a, b)]
    }

    // MARK: - 아머 진화 (EVOLUTION.md §4)

    /// `(Child, 디지멘탈) → 아머형 ID`. 성실 디지멘탈은 V-mon·Armadimon 양쪽에 쓰이므로
    /// 디지멘탈 단독 조회는 불가능하다 — 반드시 복합키로 조회한다.
    static let armorResults: [ArmorKey: Int] = [
        ArmorKey(childID: 349, digimental: .courage): 305,     // V-mon + 용기 → Fladramon
        ArmorKey(childID: 349, digimental: .sincerity): 298,   // V-mon + 성실 → Depthmon
        ArmorKey(childID: 349, digimental: .miracles): 315,    // V-mon + 기적 → Magnamon
        ArmorKey(childID: 399, digimental: .love): 401,        // Hawkmon + 사랑 → Holsmon
        ArmorKey(childID: 399, digimental: .purity): 389,      // Hawkmon + 순수 → Shurimon
        ArmorKey(childID: 271, digimental: .knowledge): 299,   // Armadimon + 지식 → Digmon
        ArmorKey(childID: 271, digimental: .sincerity): 337,   // Armadimon + 성실 → Submarimon
        ArmorKey(childID: 98, digimental: .hope): 363,         // Patamon + 희망 → Pegasmon
        ArmorKey(childID: 83, digimental: .light): 326,        // Tailmon + 빛 → Nefertimon
    ]

    static func armorResult(childID: Int, digimental: Digimental) -> Int? {
        armorResults[ArmorKey(childID: childID, digimental: digimental)]
    }

    // MARK: - 이름 매핑 (EVOLUTION.md §5, §3 하위 실검증)

    /// speciesID → 이름 표기. §6 "스프라이트 파일명 전수 검증" 에서 48종 전부 Wikimon API 로
    /// 실측 확인되어 전 항목 `spriteStemVerified: true` 다. 그중 3건(Depthmon, Imperialdramon
    /// Fighter/Paladin Mode)은 `vb > ws > xloader` 폴백 규칙으로 못 만드는 파일명이라
    /// `spriteSeriesPin` 으로 확정 파일명을 고정한다 — 위 DigimonName 문서 참고.
    static let names: [Int: DigimonName] = [
        1:   DigimonName(apiName: "Agumon", spriteStem: "Agumon", spriteStemVerified: true),
        34:  DigimonName(apiName: "Greymon", spriteStem: "Greymon", spriteStemVerified: true),
        169: DigimonName(apiName: "Metal Greymon", spriteStem: "MetalGreymon", spriteStemVerified: true),
        202: DigimonName(apiName: "War Greymon", spriteStem: "WarGreymon", spriteStemVerified: true),

        16:  DigimonName(apiName: "Gabumon", spriteStem: "Gabumon", spriteStemVerified: true),
        33:  DigimonName(apiName: "Garurumon", spriteStem: "Garurumon", spriteStemVerified: true),
        205: DigimonName(apiName: "Were Garurumon", spriteStem: "WereGarurumon", spriteStemVerified: true),
        168: DigimonName(apiName: "Metal Garurumon", spriteStem: "MetalGarurumon", spriteStemVerified: true),

        101: DigimonName(apiName: "Piyomon", spriteStem: "Piyomon", spriteStemVerified: true),
        5:   DigimonName(apiName: "Birdramon", spriteStem: "Birdramon", spriteStemVerified: true),
        165: DigimonName(apiName: "Garudamon", spriteStem: "Garudamon", spriteStemVerified: true),

        85:  DigimonName(apiName: "Tentomon", spriteStem: "Tentomon", spriteStemVerified: true),
        35:  DigimonName(apiName: "Kabuterimon", spriteStem: "Kabuterimon", spriteStemVerified: true),
        40:  DigimonName(apiName: "Atlur Kabuterimon (Blue)", spriteStem: "AtlurKabuterimon", spriteStemVerified: true),

        81:  DigimonName(apiName: "Palmon", spriteStem: "Palmon", spriteStemVerified: true),
        195: DigimonName(apiName: "Togemon", spriteStem: "Togemon", spriteStemVerified: true),
        166: DigimonName(apiName: "Lilimon", spriteStem: "Lilimon", spriteStemVerified: true),

        117: DigimonName(apiName: "Gomamon", spriteStem: "Gomamon", spriteStemVerified: true),
        124: DigimonName(apiName: "Ikkakumon", spriteStem: "Ikkakumon", spriteStemVerified: true),
        96:  DigimonName(apiName: "Zudomon", spriteStem: "Zudomon", spriteStemVerified: true),

        98:  DigimonName(apiName: "Patamon", spriteStem: "Patamon", spriteStemVerified: true),
        3:   DigimonName(apiName: "Angemon", spriteStem: "Angemon", spriteStemVerified: true),
        121: DigimonName(apiName: "Holy Angemon", spriteStem: "HolyAngemon", spriteStemVerified: true),

        83:  DigimonName(apiName: "Tailmon", spriteStem: "Tailmon", spriteStemVerified: true),
        38:  DigimonName(apiName: "Angewomon", spriteStem: "Angewomon", spriteStemVerified: true),

        349: DigimonName(apiName: "V-mon", spriteStem: "Vmon", spriteStemVerified: true),
        358: DigimonName(apiName: "XV-mon", spriteStem: "Xvmon", spriteStemVerified: true),

        356: DigimonName(apiName: "Wormmon", spriteStem: "Wormmon", spriteStemVerified: true),
        336: DigimonName(apiName: "Stingmon", spriteStem: "Stingmon", spriteStemVerified: true),

        399: DigimonName(apiName: "Hawkmon", spriteStem: "Hawkmon", spriteStemVerified: true),
        267: DigimonName(apiName: "Aquilamon", spriteStem: "Aquilamon", spriteStemVerified: true),

        271: DigimonName(apiName: "Armadimon", spriteStem: "Armadimon", spriteStemVerified: true),
        266: DigimonName(apiName: "Ankylomon", spriteStem: "Ankylomon", spriteStemVerified: true),

        // 죠그레스 결과 (§3)
        331: DigimonName(apiName: "Paildramon", spriteStem: "Paildramon", spriteStemVerified: true),
        390: DigimonName(apiName: "Silphymon", spriteStem: "Silphymon", spriteStemVerified: true),
        387: DigimonName(apiName: "Shakkoumon", spriteStem: "Shakkoumon", spriteStemVerified: true),
        183: DigimonName(apiName: "Omegamon", spriteStem: "Omegamon", spriteStemVerified: true),
        // §5 의 "괄호 앞 공백 없음" 관례가 FM/PM 에도 동일 적용됨을 digi-api 직접 조회로 실측 확인(팀 리드).
        // spriteStem 은 실제 파일명(Imperialdramon_fighter_vpet_vb.png)의 "_vpet_" 앞부분을 그대로
        // 담는다 — 소문자 약칭이고 Mode 가 없다(§6 실측). 시리즈는 vb 로 고정, 폴백 없음.
        405: DigimonName(apiName: "Imperialdramon(Fighter Mode)", spriteStem: "Imperialdramon_fighter", spriteStemVerified: true, spriteSeriesPin: "vb"),
        481: DigimonName(apiName: "Imperialdramon(Paladin Mode)", spriteStem: "Imperialdramon_paladin", spriteStemVerified: true, spriteSeriesPin: "vb"),

        // 아머 진화 결과 (§4)
        305: DigimonName(apiName: "Fladramon", spriteStem: "Fladramon", spriteStemVerified: true),
        // 실제 파일명 Depthmon_vpet_dark_color.png — 시리즈 자리에 vb/ws/xloader 가 아니라
        // dark_color 라는 비표준 값이 온다(§6 실측). 폴백 없이 이 값으로 고정.
        298: DigimonName(apiName: "Depthmon", spriteStem: "Depthmon", spriteStemVerified: true, spriteSeriesPin: "dark_color"),
        315: DigimonName(apiName: "Magnamon", spriteStem: "Magnamon", spriteStemVerified: true),
        401: DigimonName(apiName: "Holsmon", spriteStem: "Holsmon", spriteStemVerified: true),
        389: DigimonName(apiName: "Shurimon", spriteStem: "Shurimon", spriteStemVerified: true),
        299: DigimonName(apiName: "Digmon", spriteStem: "Digmon", spriteStemVerified: true),
        337: DigimonName(apiName: "Submarimon", spriteStem: "Submarimon", spriteStemVerified: true),
        363: DigimonName(apiName: "Pegasmon", spriteStem: "Pegasmon", spriteStemVerified: true),
        326: DigimonName(apiName: "Nefertimon", spriteStem: "Nefertimon", spriteStemVerified: true),
    ]

    static func name(for speciesID: Int) -> DigimonName? {
        names[speciesID]
    }
}
