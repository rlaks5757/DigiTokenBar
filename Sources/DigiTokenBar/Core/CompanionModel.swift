import Foundation

/// 표시 상태 — 사용량/burn 으로 결정(스프라이트 모션 강도·상태 문구).
enum CompanionStateKind: String, Sendable {
    case egg, idle, working, focus, tired, sleep, levelUp
}

/// 앱 언어. 포켓몬 이름은 PokéAPI 다국어 names 에서 가져온다.
enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case ko, en, ja, es, fr, pt, de
    /// PokéAPI language.name 후보(첫 매칭 사용)
    var apiCodes: [String] {
        switch self {
        case .ko: return ["ko"]
        case .en: return ["en"]
        case .ja: return ["ja-hrkt", "ja"]
        case .es: return ["es"]
        case .fr: return ["fr"]
        case .pt: return ["pt-br", "pt"]
        case .de: return ["de"]
        }
    }
    var label: String {
        switch self { case .ko: return "한국어"; case .en: return "English"; case .ja: return "日本語"; case .es: return "Español"; case .fr: return "Français"; case .pt: return "Português"; case .de: return "Deutsch" }
    }

    var displayLocale: Locale { Locale(identifier: rawValue) }

    /// byLang(langCode→name) 에서 이 언어의 이름을 고른다(apiCodes 첫 매칭 → 영어 폴백).
    func resolveName(_ byLang: [String: String]) -> String? {
        PokemonNameLocalization.resolve(byLang, preferredCodes: apiCodes)
    }

    /// 신규 설치 기본 언어 — 시스템 선호 언어에서 유추(글로벌 출시: 한국어 강제 금지).
    /// ko/ja/es/fr/pt/de 만 매칭, 그 외 전부 영어(fallback-of-fallback). 기존 사용자는 저장된 언어를 그대로 쓴다.
    static var systemDefault: AppLanguage {
        systemDefault(for: Locale.preferredLanguages.first)
    }

    /// 시스템 언어 매핑의 순수 판정 — 실제 환경을 바꾸지 않고 locale 분기를 검증할 수 있게 분리한다.
    static func systemDefault(for preferredLanguage: String?) -> AppLanguage {
        switch preferredLanguage?.prefix(2).lowercased() {
        case "ko": return .ko
        case "ja": return .ja
        case "es": return .es
        case "fr": return .fr
        case "pt": return .pt
        case "de": return .de
        default:   return .en
        }
    }
}

/// 희귀도 — PokéAPI capture_rate / is_legendary 로 판정.
enum Rarity: String, Codable, Sendable {
    case common, uncommon, rare, legendary
    /// 등급 크기(높을수록 희귀) — 두 `Rarity` 를 비교하기 위한 순위.
    /// **목록 정렬용이 아니다**: 포획 로그는 기록 시각순, 도감은 도감 번호순이고 희귀도는 필터로만 좁힌다.
    /// 유일한 소비자는 프리미엄 알의 보증 관문(`hatch` 의 `line.rarity.sortRank < tier.sortRank`) —
    /// 뽑힌 등급이 산 보증보다 낮은지 판정한다. 순서가 뒤집히면 고급/희귀 알이 조용히 낮은 등급을
    /// 통과시키므로 `testSortRankOrdersRarityAscendingByValue` 가 순서를 고정한다.
    var sortRank: Int {
        switch self {
        case .common:    return 0
        case .uncommon:  return 1
        case .rare:      return 2
        case .legendary: return 3
        }
    }
    /// 이 등급의 capture_rate 상한 — 이 값 이하면 그 종은 이 등급 **이상**이다.
    /// `from(captureRate:…)` 의 분류 임계이자, 프리미엄 알이 부화 후보를 미리 거르는 기준이다.
    /// 두 곳에 임계를 따로 적으면 한쪽만 바뀌었을 때 등급 보증이 조용히 깨지므로 **여기가 단일 소스**다.
    ///
    /// nil = capture_rate 로 표현할 수 없는 등급. 전설은 `is_legendary`/`is_mythical` 로만 판정되는데
    /// 부화 후보 인덱스(`BaseSpecies`)에는 그 플래그가 없다 → 전설 **전용** 알은 만들 수 없다(팔지도 않는다).
    /// 반대로 전설은 전원 capture_rate ≤ 45 라 하한을 *위로만* 벗어나므로, 고급/희귀 알의 capture_rate
    /// 필터에는 자연스럽게 포함된다("고급 이상"·"희귀 이상" 규칙이 그대로 성립).
    var captureRateCeiling: Int? {
        switch self {
        case .rare:      return 45
        case .uncommon:  return 120
        case .common:    return 255
        case .legendary: return nil
        }
    }
    /// capture_rate 가 이 등급 이상을 뜻하는지 — 전설은 capture_rate 로 판정할 수 없어 항상 false.
    func includes(captureRate: Int) -> Bool {
        guard let ceiling = captureRateCeiling else { return false }
        return captureRate <= ceiling
    }
    static func from(captureRate: Int, isLegendary: Bool, isMythical: Bool) -> Rarity {
        if isLegendary || isMythical { return .legendary }
        if Rarity.rare.includes(captureRate: captureRate) { return .rare }
        if Rarity.uncommon.includes(captureRate: captureRate) { return .uncommon }
        return .common
    }
}

/// 토큰 경제 — 실측 평균(~253M/일) 기준.
/// 졸업 총량 T 는 같은 희귀도면 진화 단계 수와 무관하게 동일.
/// 형태 k개 라인에서 i번째 형태 성장 비용 = T·i / (k(k+1)/2) → 합 = T, 단계↑일수록 비용↑.
enum PokemonBalance {
    /// 알 부화 임계 — 이만큼 토큰을 써야 알이 깨진다(즉시 부화 대신 기대감). 초과분은 부화체 성장에 이월.
    static let eggHatchThreshold = 5_000_000
    static let repeatGrowthMultiplier = 2

    static func graduationTotal(_ rarity: Rarity) -> Int {
        switch rarity {
        case .common:    return    750_000_000
        case .uncommon:  return  1_875_000_000
        case .rare:      return  3_000_000_000
        case .legendary: return  6_000_000_000
        }
    }
    /// stageIndex(0-based)에서 다음 단계/졸업까지 필요한 토큰.
    static func phaseThreshold(rarity: Rarity, totalForms k: Int, stageIndex: Int,
                               growthMultiplier: Int = 1) -> Int {
        let kk = max(1, k)
        let i = stageIndex + 1                         // 1-based
        let total = Double(graduationTotal(rarity))
        let denom = Double(kk * (kk + 1)) / 2.0
        let standardThreshold = Int((total * Double(i) / denom).rounded())
        return max(1, Int((Double(standardThreshold) / Double(max(1, growthMultiplier))).rounded()))
    }

    // MARK: 난이도 배율 (설정 슬라이더)

    /// 사용자 조절 배율의 허용 범위. 1 미만이면 기본보다 빠르고·싸며, 1 초과면 느리고·비싸다.
    static let difficultyRange: ClosedRange<Double> = 0.1...2.0
    /// 기본값 — 이 값에서 모든 밸런스가 위 상수표 그대로다(기존 동작과 동일).
    static let defaultDifficulty: Double = 1.0

    /// 저장값을 허용 범위로 조인다. UserDefaults 는 `defaults write` 로 외부에서 쓸 수 있어
    /// 0·음수·NaN 이 실제로 들어올 수 있고, 배율 0 은 임계 0(진행률 0 나눗셈·퇴화한 진화 루프)이 된다.
    static func clampDifficulty(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDifficulty }
        return min(max(value, difficultyRange.lowerBound), difficultyRange.upperBound)
    }

    /// 기본값 × 난이도 — 임계·가격 공통. **상수표 자체는 스케일하지 않는다**: 등급 알 가격이
    /// `graduationTotal` 의 *비율*로 파생되므로(FreshEgg.price), 표를 건드리면 성장 배율이 상점
    /// 가격까지 끌고 간다. 소비 지점에서만 곱해 두 배율을 서로 독립으로 유지한다.
    static func scaled(_ base: Int, by difficulty: Double) -> Int {
        Int((Double(base) * clampDifficulty(difficulty)).rounded())
    }

    // MARK: 슬라이더 위치 ↔ 배율 (로그 매핑)
    // 같은 비율의 변화가 같은 거리를 차지한다. 기본값은 트랙의 ±1%에서 스냅한다.
    private static let defaultSnapWidth = 0.01

    /// 슬라이더 위치(0…1) → 배율.
    static func difficulty(atPosition position: Double) -> Double {
        let lo = difficultyRange.lowerBound, hi = difficultyRange.upperBound
        let p = min(max(position, 0), 1)
        if abs(p - difficultyPosition(defaultDifficulty)) < defaultSnapWidth { return defaultDifficulty }
        return snapDifficulty(lo * pow(hi / lo, p))
    }

    /// 배율 → 슬라이더 위치(0…1).
    static func difficultyPosition(_ value: Double) -> Double {
        let lo = difficultyRange.lowerBound, hi = difficultyRange.upperBound
        return log(clampDifficulty(value) / lo) / log(hi / lo)
    }

    /// 로그 슬라이더에서 나온 값을 유효숫자 2자리로 정리한다 — 없으면 1.0473 같은 값이 그대로 표시된다.
    /// 기본값 되돌리기는 여기가 아니라 `difficulty(atPosition:)` 의 위치 스냅이 담당한다.
    static func snapDifficulty(_ value: Double) -> Double {
        guard value > 0 else { return difficultyRange.lowerBound }
        let magnitude = pow(10, (log10(value)).rounded(.down) - 1)
        return ((value / magnitude).rounded() * magnitude)
    }
}

/// 인벤토리 아이템 종류 — rawValue 로 CompanionState.inventory 에 저장(세이브 호환을 위해
/// 케이스명을 rawValue 로 고정 변경하지 않는다). 디지멘탈 8종은 아머 진화용(EVOLUTION.md §4) —
/// 이 단계에서는 타입만 전환하고, 아머 진화 로직 자체는 구현하지 않는다(별도 단계).
enum ItemKind: String, Codable, Sendable, CaseIterable {
    case rareCandy
    case digimentalCourage
    case digimentalSincerity
    case digimentalMiracles
    case digimentalLove
    case digimentalPurity
    case digimentalKnowledge
    case digimentalHope
    case digimentalLight
    case digimentalFriendship

    /// 대응하는 `Digimental` 케이스(아머 진화 데이터 키). 케이스명 규칙(`digimental` + 대문자 시작
    /// trait, `testDigimentalAndItemKindSetsMatch` 로 양방향 고정됨)으로 기계적 변환 — 손으로
    /// 유지하는 매핑 목록을 또 만들지 않는다. `rareCandy` 는 nil.
    var digimental: Digimental? {
        guard rawValue.hasPrefix("digimental") else { return nil }
        let suffix = rawValue.dropFirst("digimental".count)
        return Digimental(rawValue: suffix.prefix(1).lowercased() + suffix.dropFirst())
    }

    /// Wikimon 아이템 아트 파일명(SpriteStore 의 파일명 기반 fetch 경로로 그대로 전달). nil = 스프라이트
    /// 없음(이모지 폴백만). `rareCandy` 는 Wikimon 에 대응 소스가 없어 nil — 파일명을 지어내지 않는다.
    var spriteName: String? {
        digimental?.wikimonFilename
    }
    /// 스프라이트 로딩 전/미제공/실패 시 폴백 이모지.
    var fallbackEmoji: String {
        switch self {
        case .rareCandy: return "🍬"
        case .digimentalCourage: return "🟠"
        case .digimentalSincerity: return "🟢"
        case .digimentalMiracles: return "🔴"
        case .digimentalLove: return "🩷"
        case .digimentalPurity: return "⚪️"
        case .digimentalKnowledge: return "🟣"
        case .digimentalHope: return "🟡"
        case .digimentalLight: return "✨"
        case .digimentalFriendship: return "🔵"
        }
    }
    /// 상점 판매가(재화 = 사용한 토큰). nil = 상점 미판매.
    var shopPrice: Int? {
        switch self {
        case .rareCandy: return RareCandy.price
        case .digimentalCourage, .digimentalSincerity, .digimentalMiracles, .digimentalLove,
             .digimentalPurity, .digimentalKnowledge, .digimentalHope, .digimentalLight,
             .digimentalFriendship:
            return DigimentalItem.price
        }
    }
}

/// 이상한 사탕 밸런스 상수.
enum RareCandy {
    /// 사용 시 현재 포켓몬에 주입하는 XP(토큰 환산). 2× 성장의 최소 임계는 62.5M 이지만,
    /// 기본 난이도·첫 부화에서는 초과 이월(<100M)이 다음 임계(125M)보다 작아 최대 1단계만 올린다.
    /// 낮은 난이도나 반복 부화 보너스에서는 여러 단계를 진행할 수 있다.
    static let xp = 100_000_000
    /// 주간 한도 100% 도달 시 지급 개수(세션급은 1개).
    static let weeklyGrant = 5
    /// 상점 구매가(재화 = 사용한 토큰: usedSinceInstall − spentTokens). XP 값어치(100M)의 5배.
    /// 토큰이 "성장 미터 + 상점 지갑"으로 이중 사용되는 구조라, 가격을 XP 와 같게 두면 구매가 사실상
    /// 공짜 추가성장(150M 써서 250M 성장)이 된다. 500M 로 두면 그 값 모으는 500M 패시브 성장 + 사탕
    /// 100M = 실질 보너스 +20% 로 억제된다. 무료 획득(한도 100% 보상)이 항상 이득이도록 값어치보다 비싸게.
    static let price = 500_000_000
}

/// 디지멘탈 밸런스 상수(GAME-DESIGN.md §5) — 아머 진화용 아이템 8종 공통 가격.
/// 아머는 토큰 이득이 0이라(§4) 저가여도 파밍 악용이 불가능 — 알 리롤(1.00B)과 동급.
enum DigimentalItem {
    static let price = 1_000_000_000
}

/// 새 알(리롤) 밸런스 상수 — 상점 구매 시 현재 포켓몬을 폐기하고 새 알로 되돌린다.
enum FreshEgg {
    /// 상점 구매가. 마음에 안 드는 부화를 리롤하는 프리미엄(쌓인 토큰의 활용처). 폐기 개체는 졸업이
    /// 아니라 그냥 사라지므로 도감·확률(collectedFinals)에 무영향 — "뽑은 적 없던 것처럼". 새 알은
    /// 처음부터 재인큐베이션(5M) 필요 + 성장(usedAtStage) 소멸이라 스팸/파밍이 자연 억제된다.
    static let price = 1_000_000_000

    /// 상점에서 파는 알 — 보증 없음(기본) → 고급 이상 → 희귀 이상. `nil` = 등급 보증 없는 기존 알.
    /// **전설 전용 알은 팔지 않는다**(등급 하한을 capture_rate 로 표현할 수 없고, 최고 등급을 확정
    /// 상품으로 만들지 않는다). 전설은 고급/희귀 알에서 자연 가중대로 섞여 나온다 — 희귀 알 기준 약 10%.
    static let shopTiers: [Rarity?] = [nil, .uncommon, .rare]

    /// 등급 보증 알의 가격 — 배율은 새 상수를 짓지 않고 **기존 졸업 총량 표**를 그대로 쓴다
    /// (common 750M : uncommon 1.875B : rare 3B = 1 : 2.5 : 4 → 1B / 2.5B / 4B).
    ///
    /// 확률 배율(고급 7.16% : 희귀 6.98% ≈ 1 : 2.03)로 매기면 안 된다 — 그러면 같은 값으로 고급 알
    /// 2개를 사는 쪽이 희귀+ 기대 1.039마리·전설 0.104마리로 희귀 알 1개(1.000·0.100)를 모든 축에서
    /// 앞질러 상위 티어가 완전 열등재가 된다. 졸업량 배율이라야 상위 티어가 희귀+ 1마리당 4.00B 로
    /// 하위 반복 구매(4.81B)보다 싸다.
    static func price(guaranteeing tier: Rarity?) -> Int {
        guard let tier else { return price }
        let multiplier = Double(PokemonBalance.graduationTotal(tier)) / Double(PokemonBalance.graduationTotal(.common))
        return Int((Double(price) * multiplier).rounded())
    }
}

/// 상점 표시 한 줄 — 판매 아이템(ItemKind) 또는 알 리롤(즉시 액션이라 ItemKind 가 아님).
/// `egg` 의 연관값은 **보증 등급 하한**(nil = 보증 없는 기존 알).
/// CompanionStore.shopEntries 가 이 둘을 가격 오름차순으로 병합해 뷰가 단일 목록으로 그린다.
enum ShopEntry: Hashable, Sendable {
    case item(ItemKind)
    case egg(Rarity?)

    var price: Int {
        switch self {
        case .item(let kind): return kind.shopPrice ?? 0
        case .egg(let tier): return FreshEgg.price(guaranteeing: tier)
        }
    }

    /// 가격 동률일 때의 2차 정렬키 — `ItemKind.allCases` 선언 순서 다음에 알 3종(`FreshEgg.shopTiers`
    /// 선언 순서)을 이어 붙인 전순서다. `sorted(by:)` 는 stable 정렬을 보장하지 않으므로, 동률(디지멘탈
    /// 8종 + 기본 알이 전부 1B)이 있는 한 이 키 없이는 목록 순서가 미정의 동작이 된다.
    /// **`rawValue`(영어 이름 알파벳순)로 가르지 않는다** — 그러면 상점 1B 블록이 문장 순서와 무관해지고,
    /// 케이스 추가 때마다 기존 행이 중간에 끼어들어 재배열된다. 선언 순서를 쓰면 새 케이스는 항상 뒤에
    /// 붙어 기존 행이 불변이다. 같은 가격에서 `.item` 이 `.egg` 보다 항상 앞(egg 오프셋은 allCases.count
    /// 만큼 밀려 있다) — 기본 알(`.egg(nil)`)이 디지멘탈 뒤에 오는 것은 우연이 아니라 이 규칙의 결과다.
    var sortRank: Int {
        switch self {
        case .item(let kind):
            return ItemKind.allCases.firstIndex(of: kind) ?? 0
        case .egg(let tier):
            let offset = FreshEgg.shopTiers.firstIndex(of: tier) ?? 0
            return ItemKind.allCases.count + offset
        }
    }
}

/// 사탕 지급 대상 한도 창의 분류 — session=1개·weekly=weeklyGrant.
enum WindowClass: Sendable { case session, weekly }

/// 사탕 지급 판정 입력 — 프로바이더 무관 한도 창 1개. (UsageStore.candyEligibleWindows 가 생성)
struct CandyWindow: Sendable {
    let key: String          // 안정 식별자(tier 추적) — resets_at 등 휘발 필드 금지
    let name: String         // 표시용(알림 "왜 받는지")
    let kind: WindowClass    // session=1개 · weekly=5개
    let utilization: Double  // 0~100+
}

/// 사탕 지급 1건(순수 판정 결과) — 부수효과(인벤토리·알림)와 분리해 테스트 가능하게.
struct CandyGrant: Equatable, Sendable {
    let windowKey: String
    let windowName: String   // 알림 "왜 받는지"
    let count: Int
}

/// PokéAPI 에서 조회 가능한 종 ID 범위(전국도감 #1...649) — 부화 rejection sampling 과
/// base-index REST/GraphQL 조회 상한 산정에 쓰인다.
enum PokemonAssets {
    static let queryableSpeciesIDs = 1...649
}

/// PokéAPI evolution-chain 을 파싱한 트리. 분기(evolves_to 다수)를 children 으로.
struct EvoNode: Codable, Sendable {
    let speciesID: Int
    let children: [EvoNode]

    /// 최장 경로 길이(형태 수). 분기는 보통 같은 깊이라 대표값으로 사용.
    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
    func node(withID id: Int) -> EvoNode? {
        if speciesID == id { return self }
        for c in children { if let f = c.node(withID: id) { return f } }
        return nil
    }
    /// 이 노드에서 도달 가능한 모든 최종체 id
    var finalIDs: [Int] {
        children.isEmpty ? [speciesID] : children.flatMap(\.finalIDs)
    }
}

enum EvoLineItemContent: Equatable, Sendable {
    case species(Int)
    case mystery
}

enum EvoLineItemState: Equatable, Sendable {
    case done
    case current
    case future
}

struct EvoLineItem: Equatable, Sendable {
    let content: EvoLineItemContent
    let state: EvoLineItemState

    init(_ content: EvoLineItemContent, _ state: EvoLineItemState) {
        self.content = content
        self.state = state
    }
}

/// 부화 시 확정되는 라인 정보(트리 + 희귀도 + 다국어 이름).
struct EvoLine: Sendable {
    let baseID: Int
    let tree: EvoNode
    let rarity: Rarity
    /// speciesID → (langCode → name)
    let names: [Int: [String: String]]
    var totalForms: Int { tree.depth }

    init(baseID: Int, tree: EvoNode, rarity: Rarity, names: [Int: [String: String]]) {
        self.baseID = baseID
        self.tree = tree
        self.rarity = rarity
        self.names = names
    }

    func localizedName(_ id: Int, _ lang: AppLanguage) -> String {
        lang.resolveName(names[id] ?? [:]) ?? "#\(id)"   // 폴백 순서는 AppLanguage.resolveName 단일 소스
    }
}

/// 현재 키우는 포켓몬.
struct MonState: Codable, Sendable {
    var baseID: Int
    var pathIDs: [Int]      // 실제 진화 경로(분기 선택 반영)
    var plannedPathIDs: [Int] // 사전에 선택한 전체 진화 경로
    var stageIndex: Int     // pathIDs 내 현재 위치
    var usedAtStage: Int    // 현재 형태에서 누적 사용량
    var rarity: Rarity
    var totalForms: Int
    /// 개체 고유 전투 프로필. 구버전 저장은 nil이며 `CompanionStore`가 한 번만 마이그레이션한다.
    var profile: PokemonProfile?
    var hasGrowthBoost = false
    // pathIDs 가 비면(손상된 상태 파일) baseID 로 폴백 — 렌더마다 읽히므로 out-of-bounds 크래시 방지.
    var currentID: Int { pathIDs.isEmpty ? baseID : pathIDs[min(stageIndex, pathIDs.count - 1)] }
    var phaseThreshold: Int {
        PokemonBalance.phaseThreshold(
            rarity: rarity,
            totalForms: totalForms,
            stageIndex: stageIndex,
            growthMultiplier: hasGrowthBoost ? PokemonBalance.repeatGrowthMultiplier : 1)
    }

    init(baseID: Int, pathIDs: [Int], plannedPathIDs: [Int]? = nil, stageIndex: Int, usedAtStage: Int,
         rarity: Rarity, totalForms: Int,
         profile: PokemonProfile? = nil, hasGrowthBoost: Bool = false) {
        self.baseID = baseID
        self.pathIDs = pathIDs
        if let plannedPathIDs, !plannedPathIDs.isEmpty {
            self.plannedPathIDs = plannedPathIDs
        } else {
            self.plannedPathIDs = pathIDs
        }
        self.stageIndex = stageIndex
        self.usedAtStage = usedAtStage
        self.rarity = rarity
        self.totalForms = totalForms
        self.profile = profile
        self.hasGrowthBoost = hasGrowthBoost
    }

    // 하위호환 디코딩: 구버전 저장에 없는 부화 속성은 기본값.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseID = try c.decode(Int.self, forKey: .baseID)
        pathIDs = try c.decode([Int].self, forKey: .pathIDs)
        // 빈 pathIDs 는 손상 상태 → 디코드 실패시켜 전체 CompanionState 가 기본(알)로 폴백되게 한다.
        guard !pathIDs.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .pathIDs, in: c, debugDescription: "empty pathIDs")
        }
        if let savedPlan = try c.decodeIfPresent([Int].self, forKey: .plannedPathIDs), !savedPlan.isEmpty {
            plannedPathIDs = savedPlan
        } else {
            plannedPathIDs = pathIDs
        }
        let decodedStageIndex = try c.decode(Int.self, forKey: .stageIndex)
        stageIndex = min(max(0, decodedStageIndex), pathIDs.count - 1)
        usedAtStage = try c.decode(Int.self, forKey: .usedAtStage)
        rarity = try c.decode(Rarity.self, forKey: .rarity)
        totalForms = try c.decode(Int.self, forKey: .totalForms)
        // 손상된 신규 프로필 하나 때문에 기존 성장 상태 전체를 잃지 않는다. nil이면 스토어가 재마이그레이션한다.
        profile = (try? c.decodeIfPresent(PokemonProfile.self, forKey: .profile)) ?? nil
        hasGrowthBoost = try c.decodeIfPresent(Bool.self, forKey: .hasGrowthBoost) ?? false
    }
}

/// 도감 항목 — 라인 전체(초기→최종) 순서 보존.
struct DexEntry: Codable, Sendable, Identifiable {
    /// Version 1 preserves every API language; earlier saves retained only app-supported names.
    static let currentNamesVersion = 1
    var id = UUID().uuidString
    var baseID: Int
    var finalID: Int
    var chainOrder: [Int]   // 초기→최종 종 id
    var rarity: Rarity
    var caughtAt: Date?
    /// The individual profile at graduation/release. Nil only for pre-profile saves until migration.
    var profile: PokemonProfile?
    /// 진화 체인 각 종의 다국어 이름(speciesID → langCode → name). 졸업 시 로드된 라인에서 저장 →
    /// 도감의 단계별 스프라이트 밑 이름 표시가 네트워크 없이 즉시 + 언어 전환 대응. 구버전 저장분엔
    /// 없어(nil) 뷰가 line fetch 로 조회 후 백필한다.
    var names: [Int: [String: String]]?
    var namesVersion: Int?
    var needsNamesRefresh: Bool {
        namesVersion != Self.currentNamesVersion
            || chainOrder.contains { names?[$0]?.isEmpty != false }
    }
    /// 놓아준 시각 — 알을 새로 사서 육성을 포기한 기록. nil = 졸업분(구버전 저장분 포함).
    ///
    /// 두 기록을 한 배열에 두는 이유: 도감(`dexSpecies`)은 종이 어떻게 확보됐는지와 무관하게
    /// **보유 종**을 접는다. 놓아준 개체를 여기 넣지 않으면 그 종이 도감에서 사라진다 —
    /// 수집 화면이 "쌓이기만 한다"는 약속을 깨는 유일한 경로였다.
    var releasedAt: Date?
    /// 졸업이 아니라 놓아준 기록인가 — 포획 로그가 뱃지를 가르는 판정.
    var isReleased: Bool { releasedAt != nil }

    init(id: String = UUID().uuidString,
         baseID: Int, finalID: Int, chainOrder: [Int], rarity: Rarity,
         caughtAt: Date?,
         profile: PokemonProfile? = nil, names: [Int: [String: String]]? = nil, releasedAt: Date? = nil) {
        self.id = id
        self.baseID = baseID
        self.finalID = finalID
        self.chainOrder = chainOrder
        self.rarity = rarity
        self.caughtAt = caughtAt
        self.profile = profile
        self.names = names
        self.namesVersion = chainOrder.allSatisfy { names?[$0]?.isEmpty == false }
            ? Self.currentNamesVersion : nil
        self.releasedAt = releasedAt
    }

    // 하위호환 디코딩 (MonState 와 동일 이유).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        baseID = try c.decode(Int.self, forKey: .baseID)
        finalID = try c.decode(Int.self, forKey: .finalID)
        chainOrder = try c.decode([Int].self, forKey: .chainOrder)
        rarity = try c.decode(Rarity.self, forKey: .rarity)
        caughtAt = try c.decodeIfPresent(Date.self, forKey: .caughtAt)
        // 프로필만 손상되면 개체 기록은 보존하고 프로필을 다시 생성한다.
        profile = (try? c.decodeIfPresent(PokemonProfile.self, forKey: .profile)) ?? nil
        // try? — 구버전(최종체 단일 [String:String]) 형식이 남아 있어도 종별 맵 디코딩 실패 시 nil 로
        // 강등(항목 전체 로드는 유지). 뷰가 line 조회로 백필한다.
        names = (try? c.decodeIfPresent([Int: [String: String]].self, forKey: .names)) ?? nil
        namesVersion = try? c.decodeIfPresent(Int.self, forKey: .namesVersion)
        // 이 필드 이전에 저장된 항목은 전부 졸업분이다 — nil 이 곧 "졸업"이라 마이그레이션이 필요 없다.
        releasedAt = try c.decodeIfPresent(Date.self, forKey: .releasedAt)
    }
}

/// 배열 항목별 격리 디코딩 래퍼 — 손상된 한 항목이 배열 전체(및 상위 상태) 디코드를 실패시키지 않게.
/// 각 항목을 `try?` 로 감싸므로 실패 항목은 `value == nil` 이 되고 배열 디코드 자체는 성공한다.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

private extension KeyedDecodingContainer {
    /// 관대 디코드 — 키 없음/null/타입 불일치를 모두 기본값으로 흡수한다. 한 필드 손상이 상태 전체
    /// (도감·인벤토리)를 날리지 않게(부분 복원 > 전면 리셋). 최상위가 JSON 객체가 아닌 전면 손상은 여전히 throw.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key, default def: T) -> T {
        (try? decode(type, forKey: key)) ?? def
    }
    func lenientOptional<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decode(type, forKey: key)
    }
}

/// 영속 상태(Application Support JSON). 포켓몬 전환 — 이전 커스텀 캐릭터 상태는 폐기(새로 시작).
struct CompanionState: Codable, Sendable {
    /// 최상위 스키마 세대 — 종 식별자 체계(포켓몬→디지몬 등)가 바뀌는 전환마다 올린다.
    /// `DexEntry.namesVersion` 과 달리 항목별이 아니라 상태 전체에 한 번 붙는다.
    /// `baseID`/`finalID`/`chainOrder`/`pathIDs` 가 namespace 없는 생 Int 라, 이 필드가 없으면
    /// 구세대 세이브가 디코드 자체는 "성공"해 옛 종 id 가 새 세대 종으로 조용히 뒤바뀐다.
    /// 누락(구버전 세이브) 시 0 으로 취급되어 항상 currentSaveVersion 과 달라진다 — CompanionStore.load()
    /// 가 이 불일치를 감지해 fresh 로 시작한다.
    ///
    /// 1 → 2 (2026-09-22): 기본 provider 가 PokéAPI → DigimonData(번들 JSON)로 바뀌어 speciesID 의
    /// 의미 자체가 달라졌다(예: ID 1 = 이상해씨 → 아구몬). provider 교체 커밋(31cd824)이 이 값을
    /// 같이 올리지 않아서, 그 시점 이후 ~ 이 수정 전 사이에 생성된 saveVersion=1 세이브는 포켓몬
    /// speciesID 를 담은 채로 게이트를 통과해(1==1) 이름 미해결 무한 루프·알 미부화로 영구 정지했다.
    /// 다음에 또 종 식별자 체계가 바뀌면(디지몬 내에서도 라인 baseID 재편 등) 여기를 다시 올려야 한다.
    static let currentSaveVersion = 2
    var saveVersion = Self.currentSaveVersion
    // 토큰: 설치 이후만 측정
    var installBaselineSet = false
    var usedSinceInstall = 0
    // 상점에서 쓴 토큰 누적(재화 지출 원장). 쓸 수 있는 재화 = usedSinceInstall − spentTokens.
    // 성장 미터(usedSinceInstall)는 불변 — 구매는 이 값만 올려 잔액을 깎는다(성장 되감김 없음).
    var spentTokens = 0
    // 현재 알이 생긴 뒤 쓴 토큰(부화 인큐베이션). 누적(usedSinceInstall)과 별개 — 졸업 후 새 알마다 0.
    var eggUsage = 0
    // 현재 알이 보증하는 등급 하한(프리미엄 알). nil = 보증 없음(무료 알·기본 알).
    // ★영속이어야 한다 — 구매 시점엔 종을 못 정한다(롤에 네트워크가 필요). 보증을 상태에 적어 두고
    // 롤이 그것을 읽어야 오프라인·재시작을 건너서도 산 것을 받는다. 부화·졸업 때 nil 로 소비된다.
    var eggTier: Rarity?
    // 알 상태에서 미리 롤해둔 부화 종(프리패칭) — 부화 순간 네트워크 딜레이 제거. 재시작에도 유지.
    var pendingHatchID: Int?
    /// 오늘 사용량 적립 기준값 — 프로바이더별로 독립 관리한다.
    ///
    /// `nil`은 aggregate `claimedTodayTokens`만 가지고 있던 구버전 세이브가 아직 첫 유효
    /// snapshot을 기준으로 seed되지 않았다는 뜻이다. 첫 update에서 현재 프로바이더 값을
    /// 기준값으로만 저장하고, 과거 사용량은 소급 지급하지 않는다. 빈 map은 이미 seed된 뒤
    /// 오늘 보고한 프로바이더가 없는 정상 상태와 구분되어야 하므로 `nil`과 별도로 유지한다.
    /// 키는 `UsageProvider.id`를 그대로 사용한다.
    var claimedTodayTokensByProvider: [String: Int]? = nil
    var lastDate = ""
    // 현재 포켓몬(없으면 알)
    var active: MonState?
    // 메뉴바와 플로팅 펫에 고정한 대표 종. nil = 현재 키우는 포켓몬(또는 알)을 그대로 따라간다.
    // 종 단위 선택이라 성격 같은 개체 정보는 들고 있지 않는다. 선택 가능한 범위는 도감과 동일하게
    // 졸업분 + 현재 개체의 도달 단계이며, 그 범위에서 빠지면 reconcileRepresentativeSelection 이 nil 로 복구한다.
    var representativeSpeciesID: Int? = nil
    // 도감
    var dex: [DexEntry] = []
    // 소유한 (base,final) 쌍 — 분기 다양성용
    var collectedFinals: Set<String> = []
    var language: AppLanguage = .systemDefault   // 신규 설치 = 시스템 로케일
    // 인벤토리 (ItemKind.rawValue → 개수)
    var inventory: [String: Int] = [:]
    // 사탕 지급 엣지 상태(창 key → 지급한 tier). ★영속 — notifiedTier(인메모리)와 달리 재시작 무한지급 방지.
    var candyGrantTier: [String: Int] = [:]
    // 사탕 지급 첫 실행 시드 완료 — 업데이트 직후 이미 100%였던 창의 소급 지급 차단.
    var candyFeatureSeeded = false

    init() {}

    // 하위호환 + 손상 복원 디코딩: 누락 키·타입 불일치·일부 손상 필드를 모두 기본값으로 흡수한다 —
    // 한 필드가 깨져도 상태 전체(도감·인벤토리)를 날리지 않는다(부분 복원). 최상위가 JSON 객체가 아닌
    // 전면 손상만 throw → load() 가 원본을 .corrupt 로 백업하고 fresh 로 시작.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 0 = 구버전(필드 자체가 없던 세이브). 관대 디코딩 기본값이 그대로 "불일치" 신호가 된다.
        saveVersion        = c.lenient(Int.self, forKey: .saveVersion, default: 0)
        installBaselineSet = c.lenient(Bool.self, forKey: .installBaselineSet, default: false)
        usedSinceInstall   = c.lenient(Int.self, forKey: .usedSinceInstall, default: 0)
        spentTokens        = c.lenient(Int.self, forKey: .spentTokens, default: 0)
        eggUsage           = c.lenient(Int.self, forKey: .eggUsage, default: 0)
        // 모르는 rawValue 는 nil(보증 없음)로 강등 — 관대 디코딩의 안전한 방향(있지도 않은 보증을 만들지 않는다).
        eggTier            = c.lenientOptional(Rarity.self, forKey: .eggTier)
        pendingHatchID     = c.lenientOptional(Int.self, forKey: .pendingHatchID)
        if c.contains(.claimedTodayTokensByProvider) {
            claimedTodayTokensByProvider = c.lenient([String: Int].self,
                                                      forKey: .claimedTodayTokensByProvider,
                                                      default: [:])
        } else {
            // 구버전의 aggregate claimedTodayTokens 키는 의도적으로 읽지 않는다. 프로바이더별
            // 분해가 불가능하므로 다음 CompanionStore.update에서 현재 snapshot을 기준점으로 seed한다.
            claimedTodayTokensByProvider = nil
        }
        lastDate           = c.lenient(String.self, forKey: .lastDate, default: "")
        // active 손상(빈 pathIDs 등) → 알로 폴백하되 도감·인벤토리는 보존.
        active             = c.lenientOptional(MonState.self, forKey: .active)
        representativeSpeciesID = c.lenientOptional(Int.self, forKey: .representativeSpeciesID)
        // 도감은 항목별 격리 — 손상 항목 하나가 도감 전체를 날리지 않게.
        dex                = c.lenient([Lossy<DexEntry>].self, forKey: .dex, default: []).compactMap(\.value)
        collectedFinals    = c.lenient(Set<String>.self, forKey: .collectedFinals, default: [])
        language           = c.lenient(AppLanguage.self, forKey: .language, default: .systemDefault)
        inventory          = c.lenient([String: Int].self, forKey: .inventory, default: [:])
        candyGrantTier     = c.lenient([String: Int].self, forKey: .candyGrantTier, default: [:])
        candyFeatureSeeded = c.lenient(Bool.self, forKey: .candyFeatureSeeded, default: false)
    }

    /// 졸업 기록 또는 현재 개체가 실제로 도달한 단계에 이 종이 포함되는가.
    /// 도감 전체 표시 모델을 만들지 않고 대표 종 하나만 확인하는 경량 경로다.
    func ownsSpecies(_ speciesID: Int) -> Bool {
        if dex.contains(where: { $0.chainOrder.contains(speciesID) }) { return true }
        guard let active else { return false }
        return active.pathIDs.prefix(active.stageIndex + 1).contains(speciesID)
    }

    func hasCollectedFinal(forBaseID baseID: Int) -> Bool {
        collectedFinals.contains { $0.hasPrefix("\(baseID):") }
    }

    /// 대표 포켓몬은 사용자가 현재 보유한 종만 가리킨다. Fresh Egg·손편집 세이브가
    /// 유령 종을 메뉴바와 플로팅 펫에 영구히 남기지 않게 한다.
    mutating func reconcileRepresentativeSelection() {
        guard let selected = representativeSpeciesID else { return }
        if !ownsSpecies(selected) {
            representativeSpeciesID = nil
        }
    }
}

// NOTE: 부화 후보는 더 이상 하드코딩하지 않는다 — CompanionStore.chooseBase() 가
// PokéAPI 전수(1~5세대)를 capture_rate 가중 rejection sampling 으로 선정한다.
