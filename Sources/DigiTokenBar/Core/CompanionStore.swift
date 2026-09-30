import Foundation
import Observation
import UserNotifications

/// 게임 상태의 출처. 설치 이후 토큰 사용량으로 디지몬을 진화시키고, 최종체 + 추가 임계 도달 시
/// 도감(라인 전체)에 보존 + 새 알. 진화 트리/희귀도/이름은 DigimonLineProviding 으로 런타임 주입.
@MainActor
@Observable
final class CompanionStore {
    private(set) var state = CompanionState()
    private(set) var displayState: CompanionStateKind = .egg
    private(set) var currentLine: EvoLine?
    private(set) var representativeSubject = RepresentativeSubject(speciesID: nil)
    private(set) var isHatching = false
    private(set) var justEvolvedTo: String?     // 이름(연출/문구)
    private(set) var justGraduated: String?
    private var eventUntil: Date?

    /// 부화/진화 연출 트리거 — seq 증가로 UI 가 감지, 팝오버가 닫혀 있었어도 다음 오픈에 1회 재생.
    enum Celebration: Equatable { case hatch, evolve }
    private(set) var celebration: Celebration?
    private(set) var celebrationSeq = 0
    private func fireCelebration(_ c: Celebration) { celebration = c; celebrationSeq += 1 }
    /// 연출 재생 후 UI 가 호출(1회성 보장).
    func consumeCelebration() { celebration = nil }

    /// 사탕 사용 시 "+XP" 순간 표시 — 진화 없이 부분 진행일 때도 피드백. seq 증가로 CompanionHeader 감지.
    private(set) var candyFeedbackSeq = 0
    private(set) var candyFeedbackAmount = 0
    /// "+XP" 표시 1회성 보장 — CompanionHeader 가 재생 후 호출한다. 소비하지 않으면 다른 탭에 갔다
    /// 홈으로 재진입할 때(CompanionHeader 재마운트) @State 가 초기화돼 같은 값이 다시 떠오른다(회귀).
    func consumeCandyFeedback() { candyFeedbackAmount = 0 }

    private let provider: any DigimonLineProviding
    private var dexNameRequests: [Int: Task<EvoLine, Error>] = [:]
    private let detailProvider: (any DigimonDetailProviding)?
    /// 도감 상세 패널의 설정 정보 출처. 번들 JSON 이라 동기 조회이며, 테스트는 스텁을 주입한다.
    private let loreSource: any DigimonLoreProviding
    private let clock: () -> Date
    private let fileURL: URL
    private var rng: any RandomNumberGenerator
    private(set) var digimonDetailsByID: [Int: DigimonDetails] = [:]
    private(set) var loadingDigimonDetailIDs: Set<Int> = []
    private(set) var failedDigimonDetailIDs: Set<Int> = []
    /// `loadCurrentLine` 이 provider.line 실패를 로그로 남기되, update 틱마다 같은 baseID 로 재시도해도
    /// 로그가 범람하지 않게 baseID 당 1회만 기록한다(UI 는 이 값을 읽지 않으므로 failedDigimonDetailIDs
    /// 와 달리 private(set) 아님).
    private var failedLineBaseIDs: Set<Int> = []
    private let defaults: UserDefaults
    /// 세션 내 활성 개체 교체 감지용. await 뒤 이전 개체의 결과가 새 개체를 덮지 않게 한다.
    private var activeGeneration = 0

    // MARK: 난이도 배율 (설정 — UserDefaults)
    //
    // 세이브(CompanionState)가 아니라 UserDefaults 에 둔다. 이건 진행 상황이 아니라 취향 설정이고
    // (설정창의 다른 슬라이더와 같은 자리), 세이브에 넣으면 남의 세이브를 불러올 때 내 난이도가 조용히
    // 바뀌며 SaveTransfer 의 관대 디코딩·검증까지 새 수치 필드를 떠안는다.

    /// 성장 배율 — 알 부화 임계 + 진화/졸업 임계에 곱한다. 낮을수록 빨리 자란다.
    /// 사탕 XP(RareCandy.xp)는 스케일하지 않는다 — 함께 곱하면 서로 상쇄돼 사탕만 난이도를 안 탄다.
    private(set) var growthDifficulty: Double
    /// 상점 배율 — 아이템·알 가격에 곱한다. 낮을수록 싸다.
    private(set) var shopDifficulty: Double

    init(provider: any DigimonLineProviding = DigimonLineProvider(),
         detailProvider: (any DigimonDetailProviding)? = nil,
         loreSource: (any DigimonLoreProviding)? = nil,
         clock: @escaping () -> Date = Date.init,
         fileURL: URL? = nil,
         rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
         defaults: UserDefaults = .standard) {
        self.provider = provider
        self.detailProvider = detailProvider ?? (provider as? any DigimonDetailProviding)
        self.loreSource = loreSource ?? DigimonDetailsBundleSource()
        self.clock = clock
        self.fileURL = fileURL ?? Self.defaultURL()
        self.rng = rng
        self.defaults = defaults
        let storedGrowth = defaults.object(forKey: "growthDifficulty") as? Double ?? DigimonBalance.defaultDifficulty
        // Previous releases accepted 0.01%–2000%. Reprice their banked progress before
        // persisting the narrower range, otherwise an upgrade silently changes completion.
        let previousGrowth = storedGrowth.isFinite ? min(20, max(0.0001, storedGrowth)) : 1
        growthDifficulty = DigimonBalance.clampDifficulty(storedGrowth)
        shopDifficulty = DigimonBalance.clampDifficulty(
            defaults.object(forKey: "shopDifficulty") as? Double ?? DigimonBalance.defaultDifficulty)
        load()
        if previousGrowth != growthDifficulty {
            rescaleBankedGrowth(from: previousGrowth, to: growthDifficulty)
            save()
        }
        defaults.set(growthDifficulty, forKey: "growthDifficulty")
        defaults.set(shopDifficulty, forKey: "shopDifficulty")
        migrateDigimonProfilesIfNeeded()
        refreshRepresentativeSubject()
        if state.active != nil { displayState = .idle }
    }

    static func defaultURL() -> URL {
        // 상태 파일 위치. 기본은 Application Support/DigiTokenBar. `DTB_STATE_DIR` 환경변수가 있으면
        // 그 디렉토리를 쓴다 — 개발/QA 격리용(실제 companion 상태를 건드리지 않고 데모 상태로 실행).
        // 프로덕션은 이 변수가 없어 무영향.
        AppStatePaths.directory().appendingPathComponent("companion-state.json")
    }

    // MARK: 파생값 (UI)

    var language: AppLanguage { state.language }
    func setLanguage(_ lang: AppLanguage) { state.language = lang; save() }

    // MARK: 난이도 — 저장할 때만 적용

    /// Keep the earned fraction of this egg/stage. These are progression credits,
    /// not actual usage: lifetime tokens, provider ledgers and wallet never change here.
    func setGrowthDifficulty(_ value: Double) {
        let clamped = DigimonBalance.clampDifficulty(value)
        guard clamped != growthDifficulty else { return }
        rescaleBankedGrowth(from: growthDifficulty, to: clamped)
        growthDifficulty = clamped
        defaults.set(clamped, forKey: "growthDifficulty")
        // Do not evolve, graduate or hatch just because Settings changed.
        save()
    }

    private func rescaleBankedGrowth(from old: Double, to new: Double) {
        func rescaled(_ credits: Int, base: Int) -> Int {
            // Calculate the old threshold without the new range clamp during migration.
            let oldThreshold = max(1, Int((Double(base) * old).rounded()))
            let newThreshold = max(1, Int((Double(base) * new).rounded()))
            let value = Double(credits) / Double(oldThreshold) * Double(newThreshold)
            let rounded = Int(min(Double(SaveTransfer.maxTokenValue), max(0, value.rounded(.down))))
            // Rounding must never turn an incomplete stage into a completed one.
            return credits < oldThreshold ? min(newThreshold - 1, rounded) : rounded
        }
        if var active = state.active {
            active.usedAtStage = rescaled(active.usedAtStage, base: active.phaseThreshold)
            state.active = active
        } else {
            state.eggUsage = rescaled(state.eggUsage, base: DigimonBalance.eggHatchThreshold)
        }
    }

    /// 상점 배율 변경 — 가격은 순수 읽기(파생값)라 재평가할 상태가 없다.
    func setShopDifficulty(_ value: Double) {
        let clamped = DigimonBalance.clampDifficulty(value)
        guard clamped != shopDifficulty else { return }
        shopDifficulty = clamped
        defaults.set(clamped, forKey: "shopDifficulty")
    }

    /// 난이도를 반영한 알 부화 임계.
    private var eggHatchThreshold: Int {
        DigimonBalance.scaled(DigimonBalance.eggHatchThreshold, by: growthDifficulty)
    }

    /// 난이도를 반영한 단계 임계. **`DigimonBalance.phaseThreshold` 를 직접 부르지 않는다** —
    /// 배율을 빠뜨린 호출부가 생기면 그 경로만 조용히 기본 난이도로 돌아간다.
    private func stageThreshold(for mon: MonState) -> Int {
        DigimonBalance.scaled(mon.phaseThreshold, by: growthDifficulty)
    }

    /// 상점 표시·결제에 쓰는 실제 가격 — 기본가 × 상점 난이도. 미판매면 nil.
    func price(of kind: ItemKind) -> Int? {
        kind.shopPrice.map { DigimonBalance.scaled($0, by: shopDifficulty) }
    }

    /// 알을 포함한 상점 한 줄의 실제 가격.
    func price(of entry: ShopEntry) -> Int {
        DigimonBalance.scaled(entry.price, by: shopDifficulty)
    }
    /// 앱 전체 UI 문자열 — language 변경 시 자동 재렌더.
    var l: L { L(language) }

    var hasActive: Bool { state.active != nil }
    var rarity: Rarity? { state.active?.rarity }
    var growthMultiplier: Int? {
        state.active?.hasGrowthBoost == true ? DigimonBalance.repeatGrowthMultiplier : nil
    }

    /// 메뉴바와 플로팅 펫이 그릴 대표 종. nil 선택은 기존 동작(현재 개체/알)을 보존한다.
    /// 저장된 값이라 상시 렌더링 경로가 도감 전체를 다시 접거나 불필요한 상태를 관찰하지 않는다.
    struct RepresentativeSubject: Equatable, Sendable {
        let speciesID: Int?
    }

    var representativeSpeciesID: Int? { state.representativeSpeciesID }

    /// 관련 상태가 바뀌어 저장되는 경계에서만 갱신한다.
    private func refreshRepresentativeSubject() {
        let next: RepresentativeSubject
        if let selected = state.representativeSpeciesID {
            next = RepresentativeSubject(speciesID: selected)
        } else {
            next = RepresentativeSubject(speciesID: displaySpeciesID)
        }
        if representativeSubject != next { representativeSubject = next }
    }

    /// nil 은 자동 추적. 도감에 없는 id 는 저장하지 않는다 — UI 밖 호출이나 손상된 입력도 같은
    /// 불변식을 지키며, 실패한 요청이 기존 선택을 조용히 해제하지 않도록 false 만 반환한다.
    @discardableResult
    func setRepresentativeSpeciesID(_ id: Int?) -> Bool {
        if let id, !state.ownsSpecies(id) { return false }
        state.representativeSpeciesID = id
        save()
        return true
    }

    func isRepresentative(_ species: DexSpecies) -> Bool {
        state.representativeSpeciesID == species.id
    }

    /// Settings describe the selected form, even though the main Digidex aggregates the species.
    var representativeDexSpecies: DexSpecies? {
        dexSpecies.first { isRepresentative($0) }
    }

    // 알 인큐베이션 (active 없을 때)
    var isEgg: Bool { state.active == nil }
    var eggStarted: Bool { state.eggUsage > 0 }
    var eggProgress: Double { min(1, max(0, Double(state.eggUsage) / Double(eggHatchThreshold))) }
    var eggTokensToHatch: Int { max(0, eggHatchThreshold - state.eggUsage) }
    /// 알이 부화 준비(100%)가 되었으나 PokéAPI 요청/후보 선택 실패로 다음 갱신을 기다리는 상태.
    private(set) var isHatchRetryDelayed = false

    /// 화면에 그릴 이름 — 아머 착용 중이면 아머체 이름.
    ///
    /// 아머체는 `EvoLine.names`(라인 stages 만 채운다)에 없어서 `line.localizedName` 이 `"#305"` 를
    /// 반환한다. 라인 밖 종은 `DigimonData.name(for:)` 의 로케일 맵으로 해결한다 — 폴백 순서는
    /// 라인 이름과 같은 `AppLanguage.resolveName` 단일 소스를 탄다.
    var displayName: String {
        guard let a = state.active else { return "Token Egg" }
        if let armorID = a.armorID { return Self.dataName(armorID, state.language) }
        return ladderName
    }

    /// 라인 밖 종(아머체 등)의 현재 언어 이름. 세 호출부(표시 이름·사다리 이름·가방 힌트)가
    /// 같은 해석을 쓰도록 한 곳에 모은다.
    static func dataName(_ id: Int, _ lang: AppLanguage) -> String {
        DigimonData.name(for: id).flatMap { lang.resolveName($0.localizedNames) } ?? "#\(id)"
    }
    /// 사다리 종의 이름 — 아머 착용 중에도 **아머를 벗으면 무엇이 되는가**를 가리킨다.
    /// 아머 해제 확인 문구가 이걸 쓴다(표시 이름을 쓰면 "화염드라몬으로 돌아갈까요?" 가 된다).
    ///
    /// 라인은 **비동기 로드**라 재시작 직후엔 nil 인데 `armorID` 는 세이브에서 즉시 복원되므로
    /// 아머 해제 컨트롤이 그 창에 이미 떠 있다. 라인만 보고 "Token Egg" 를 반환하면 확인 문구가
    /// "Token Egg 으로 돌아갈까요?" 가 되므로, 라인 미로딩 시엔 위 아머 분기와 같은 경로로 폴백한다.
    /// "Token Egg" 는 개체 자체가 없을 때만 맞다.
    var ladderName: String {
        guard let a = state.active else { return "Token Egg" }
        if let line = currentLine { return line.localizedName(a.currentID, state.language) }
        return Self.dataName(a.currentID, state.language)
    }
    /// 성장 기계의 축 — **항상 사다리 종**. 스프라이트/이름 표시는 `displaySpeciesID` 를 쓴다.
    var currentSpeciesID: Int? { state.active?.currentID }
    /// 표시 축 — 아머 착용 중이면 아머체. 스프라이트·대표 종(메뉴바/플로팅 펫)이 읽는 값.
    var displaySpeciesID: Int? { state.active?.displayID }
    var isFinalStage: Bool {
        guard let a = state.active, let line = currentLine else { return false }
        return line.tree.node(withID: a.currentID)?.children.isEmpty ?? true
    }
    /// 🚨 아래 진행 표시들(`isFinalStage`/`stageText`/`progress`/`tokensToNext`/`lineNodes`)은
    /// 아머 착용 중에도 **계속 `currentID`(사다리 종)를 읽는다. 표시 접근자로 바꾸지 말 것.**
    /// 성장은 실제로 사다리에서 일어나므로("화염드라몬 스프라이트 + 1/4 진행" 은 버그가 아니라
    /// 오버레이 모델의 정확한 귀결이다), 여기를 `displayID` 로 "고치면" `line.tree.node(withID:)` 가
    /// 아머체를 못 찾아 nil 을 반환하고 성장 정지·졸업 오염이 재발한다.
    var stageText: String {
        guard let a = state.active else { return "" }
        return isFinalStage ? l.finalForm : l.stage(a.stageIndex + 1, a.totalForms)
    }
    var threshold: Int {
        guard let a = state.active else { return 1 }
        return stageThreshold(for: a)
    }
    var progress: Double {
        guard let a = state.active, threshold > 0 else { return 0 }
        return min(1, max(0, Double(a.usedAtStage) / Double(threshold)))
    }
    var tokensToNext: Int { guard let a = state.active else { return 0 }; return max(0, threshold - a.usedAtStage) }

    /// 진화 라인 표시용: 실현된 경로 + 다음 단계 미리보기.
    /// 유일하게 이어지는 단계 뒤에 분기가 있으면, 그 확정 접두어와 하나의 미지 항목을 함께 보여 준다.
    /// 분기 후보는 부화 시 계획됐더라도 실제 진화 전까지 하나의 미지 항목으로 숨긴다.
    var lineNodes: [EvoLineItem] {
        guard let a = state.active, let line = currentLine else { return [] }
        var out = Self.realizedLineItems(pathIDs: a.pathIDs, stageIndex: a.stageIndex)
        if let current = line.tree.node(withID: a.currentID) {
            var node = current
            var guaranteedPrefix: [EvoNode] = []
            while node.children.count == 1, let child = node.children.first {
                guaranteedPrefix.append(child)
                node = child
            }

            if node.children.count > 1 {
                out += guaranteedPrefix.map { EvoLineItem(.species($0.speciesID), .future) }
                out.append(EvoLineItem(.mystery, .future))
            } else {
                out += guaranteedPrefix.map { EvoLineItem(.species($0.speciesID), .future) }
            }
        }
        return out
    }

    static func realizedLineItems(pathIDs: [Int], stageIndex: Int) -> [EvoLineItem] {
        pathIDs.enumerated().map { i, id in
            EvoLineItem(.species(id), i == stageIndex ? .current : .done)
        }
    }
    /// 도감에는 영구 보존된 졸업 개체와 현재 키우는 디지몬을 함께 표시한다.
    /// 현재 개체는 영속 dex 에 중복 저장하지 않고 화면용 항목으로 합성한다. 졸업 시 active 가 사라지고
    /// 같은 개체의 영구 DexEntry 가 추가되므로 목록 개수는 그대로 유지된다.
    ///
    /// **의도적으로 `state.stored` 는 합성하지 않는다.** 이 목록은 종 로그가 아니라 "지금 키우는
    /// 개체 + 이미 졸업한 개체" 의 **개체 단위 동행 기록**이다(종 단위 보유 여부는 `dexSpecies` 의
    /// 몫이라 보관 개체를 포함한다 — 서로 다른 축). 보관은 "지금 키우는 중" 이 아니므로 여기 안
    /// 뜨는 게 맞다 — 뜨면 활성/보관 두 상태가 로그에서 구분이 안 된다.
    private var activeDexEntry: DexEntry? {
        guard let active = state.active else { return nil }
        return DexEntry(
            id: "active-\(active.baseID)-\(active.currentID)",
            baseID: active.baseID,
            finalID: active.currentID,
            chainOrder: active.pathIDs,
            rarity: active.rarity,
            caughtAt: nil,
            profile: active.profile,
            names: currentLine.map { line in
                Dictionary(uniqueKeysWithValues:
                    active.pathIDs.compactMap { id in line.names[id].map { (id, $0) } })
            }
        )
    }

    var dexEntries: [DexEntry] {
        guard let activeDexEntry else { return state.dex }
        return state.dex + [activeDexEntry]
    }

    /// 합성된 현재 디지몬 항목인지 판별한다. caughtAt 이 없는 구버전 졸업 항목과 혼동하지 않는다.
    func isActiveDexEntry(_ entry: DexEntry) -> Bool {
        entry.id == activeDexEntry?.id
    }

    /// 동행 기록 표시 순서 — 현재 키우는 디지몬을 맨 앞에 고정하고, 졸업 항목은 **기록 시각 최신순**.
    ///
    /// 과거에는 희귀도 내림차순이 먼저였다(종 단위 도감의 규칙). 로그는 시간순 기록이라 희귀도로
    /// 먼저 묶으면 방금 졸업한 개체가 며칠 전에 잡은 상위 희귀도 밑에 묻힌다. 희귀도로 좁히는 일은
    /// 이제 필터 캡슐과 도감이 담당한다.
    ///
    /// caughtAt 이 없는 구버전 항목은 .distantPast 로 묶여 맨 뒤에 온다(그들끼리의 순서는 미정).
    var dexEntriesSorted: [DexEntry] {
        let graduated = state.dex.sorted {
            ($0.caughtAt ?? .distantPast) > ($1.caughtAt ?? .distantPast)
        }
        guard let activeDexEntry else { return graduated }
        return [activeDexEntry] + graduated
    }

    /// 희귀도별 동행 기록 개수(요약 헤더용) — 개체 수 기준. 도감(종 단위)은 dexSpecies 를 쓴다.
    func dexCount(_ rarity: Rarity) -> Int { dexEntries.lazy.filter { $0.rarity == rarity }.count }

    /// 도감 한 칸 — 메인 목록은 종별, 안농 상세 목록은 폼별로 중복 기록을 합친다.
    /// **종 정보만 담는다** — 성격·획득 횟수처럼 개체에 딸린 것은 동행 기록이 개체 단위로 보여준다.
    struct DexSpecies: Sendable {
        let id: Int                     // speciesID = 도감 번호(정렬 키)
        let name: String
        let rarity: Rarity
        /// 이 종이 현재 키우는 개체의 **현재 형태**인가. 지나온 진화 단계에는 서지 않는다.
        let isRaising: Bool

        var collectionID: String { String(id) }
    }

    /// 종 하나가 모으는 것 — 누적 전용. 병렬 딕셔너리를 여러 개 두면 키 집합이 서로 어긋날 수 있고
    /// (한쪽에만 써서 그 종이 조용히 사라지거나), 읽는 쪽에 도달 불가한 기본값이 생긴다. 하나로 묶어
    /// 두 여지를 함께 없앤다.
    private struct DexAccumulator {
        /// 첫 발견 때 확정 — 같은 종은 항상 같은 base 라인에서 오므로 갱신할 값이 없다.
        let rarity: Rarity
        var names: [String: String]?
    }

    /// 도감 목록 — 보유 종만, 도감 번호 오름차순.
    ///
    /// 포함 종 = 졸업분 `chainOrder` ∪ 현재 개체의 **도달분** `pathIDs[0...stageIndex]`
    /// ∪ 보관 개체 각각의 **도달분**. `plannedPathIDs`(사전 선택된 전체 경로)는 미도달 단계를
    /// 포함하므로 절대 쓰지 않는다 — 쓰면 아직 진화하지 않은 종이 보유로 잡힌다.
    var dexSpecies: [DexSpecies] {
        // 종별 누적을 한 번에 훑는다(뷰가 body 에서 1회 소비 — 메모이즈 없이 충분).
        var acc: [Int: DexAccumulator] = [:]
        for entry in state.dex {
            for id in entry.chainOrder {
                var a = acc[id] ?? DexAccumulator(rarity: entry.rarity)
                if let n = entry.names?[id] { a.names = n }   // 이름 없는 구버전 항목이 덮어쓰지 않게
                acc[id] = a
            }
        }
        if let active = state.active {
            // 도달분만 — stageIndex 가 pathIDs 범위 안임은 두 입구가 보장한다:
            // MonState.init(from:) 의 clamp, 그리고 SaveTransfer 의 가져오기 정규화.
            for id in active.pathIDs.prefix(active.stageIndex + 1) {
                var a = acc[id] ?? DexAccumulator(rarity: active.rarity)
                if let n = currentLine?.names[id] { a.names = n }
                acc[id] = a
            }
        }
        // 보관 개체 — active 와 같은 도달분 규칙. 이름 캐시가 없으므로 dexDisplayName 이
        // 번들 데이터(DigimonData.name(for:))로 우선 해석한다(stored:nil 이어도 실 종 id면 문제없음).
        for entry in state.stored {
            for id in entry.mon.pathIDs.prefix(entry.mon.stageIndex + 1) {
                let a = acc[id] ?? DexAccumulator(rarity: entry.mon.rarity)
                acc[id] = a
            }
        }
        return acc.sorted { $0.key < $1.key }.map { id, a in
            return DexSpecies(id: id, name: dexDisplayName(id, stored: a.names), rarity: a.rarity,
                              isRaising: id == state.active?.currentID)
        }
    }

    /// Refresh legacy names once, including saves that retained only app-supported languages.
    ///
    /// 격자는 저장된 이름만 읽으므로 백필이 없으면 칸이 종 번호(`#41`)로 남는다. 동행 기록는 행이
    /// 뜰 때 행 단위로 같은 일을 해 왔지만, 로그를 한 번도 안 열면 격자는 계속 번호다.
    /// 라인 조회는 `PokeAPIClient` 가 base 단위로 캐시하므로 같은 라인이 여러 항목이어도 네트워크는 1회.
    /// 오프라인이면 `dexResolveChainNames` 가 저장 없이 폴백만 돌려주므로 다음 진입에서 다시 시도한다.
    func backfillMissingDexNames() async {
        for entry in state.dex where entry.needsNamesRefresh {
            _ = await dexResolveChainNames(entry)   // 성공분만 내부에서 state.dex 에 저장
        }
    }

    /// 도감 한 칸의 표시 이름 — **번들 데이터를 항목에 굳은 이름보다 우선한다.**
    ///
    /// 이름은 항목 생성 시점에 세이브에 굳는다(`recordArmorDexEntry`, 졸업 시 라인 이름). 그래서
    /// 저장된 값만 읽으면 표기가 추가되기 **전에** 만들어진 기존 행은 영원히 옛 표기(영문)로 남는다.
    /// 세이브 스키마를 건드리는 마이그레이션 대신 읽기 시점에 다시 해석해서, 구버전 행도 데이터가
    /// 아는 종이면 곧바로 현재 언어로 뜨게 한다. 저장값은 데이터셋에 없는 종(예: 데이터에서 빠진
    /// 구종)을 위한 폴백으로 남는다.
    private func dexDisplayName(_ id: Int, stored: [String: String]?) -> String {
        if let name = DigimonData.name(for: id).flatMap({ state.language.resolveName($0.localizedNames) }) {
            return name
        }
        return stored.flatMap { state.language.resolveName($0) } ?? "#\(id)"
    }

    /// 도감 항목 진화 체인 각 종의 이름(speciesID → 현재 언어 이름). 저장돼 있으면 즉시(네트워크 0),
    /// 없으면 nil(뷰가 async 조회로 폴백).
    ///
    /// ⚠️ **저장된 값만 본다 — 번들 데이터로 덮어쓰지 말 것.** 이건 표시 경로가 아니라 백필 기계
    /// (`needsNamesRefresh`/`dexResolveChainNames`)의 관측창이라, 번들 이름을 우선하면 "무엇이
    /// 저장돼 있는가" 를 물을 방법이 없어져 백필 회귀가 조용히 통과한다. 표시용 해석이 필요하면
    /// `dexDisplayChainNames` 를 쓴다.
    func dexStoredChainNames(_ entry: DexEntry) -> [Int: String]? {
        guard let names = entry.names, !names.isEmpty else { return nil }
        return names.compactMapValues { state.language.resolveName($0) }
    }

    /// 동행 기록 등 **표시**용 체인 이름 — 저장값 대신 번들 데이터를 우선한다(`dexDisplayName`).
    /// 표기가 추가되기 전에 저장된 행도 현재 언어로 뜨게 하면서, 위 저장값 접근자의 계약은
    /// 건드리지 않는다.
    ///
    /// ⚠️ **`entry.names` 가 아니라 `chainOrder` 를 기준으로 돈다.** 저장값 유무로 막으면 이
    /// 표시 경로가 `names == nil` 인 행에 **아예 적용되지 않고** 폴백(`dexResolveChainNames`)으로
    /// 넘어가는데, 그건 오프라인에서 번들을 전혀 보지 않고 `#id` 를 돌려준다 — 같은 화면에서
    /// 격자는 `아구몬`, 동행 기록 행은 `#1` 이 된다. `names == nil` 은 과거 세이브만이 아니라
    /// 졸업·방생·활성 저장이 `currentLine` 없이 일어나면 **지금도** 생긴다.
    ///
    /// `stored:` 에는 그 id 의 저장값을 넘긴다(nil 금지) — 번들이 이미 우선이라 저장값은 52종
    /// **밖** id 에서만 쓰이는데, nil 을 넘기면 데이터셋에서 빠진 구종의 저장 이름을 버리게 된다.
    func dexDisplayChainNames(_ entry: DexEntry) -> [Int: String]? {
        guard !entry.chainOrder.isEmpty else { return nil }
        return entry.chainOrder.reduce(into: [Int: String]()) { out, id in
            out[id] = dexDisplayName(id, stored: entry.names?[id])
        }
    }

    /// 동행 기록 행이 실제로 쓰는 이름 맵 — 표시 해석과 async 폴백의 합류 지점.
    ///
    /// 뷰(`DexEntryRow`)가 아니라 여기서 합치는 이유: SwiftUI `body` 안의 식은 XCTest 가 닿지
    /// 못해서, 뷰에 두면 `dexStoredChainNames`(저장값만 보는 백필 관측창)로 되돌려도 테스트가
    /// 0건 실패한다 — 배선이 조용히 끊긴다. 뷰는 이 메서드를 호출만 하고, 우선순위 규칙은
    /// 테스트가 직접 잡을 수 있는 이 자리에 둔다.
    func dexRowChainNames(_ entry: DexEntry, resolved: [Int: String]) -> [Int: String]? {
        dexDisplayChainNames(entry) ?? (resolved.isEmpty ? nil : resolved)
    }

    /// Refresh missing/legacy multilingual names; current versions require no lookup.
    /// Offline, keep saved names and use species numbers only where no name is available.
    /// 반환은 chainOrder 전 종을 채운 [speciesID: 현재 언어 이름].
    private func dexNameLine(baseID: Int) async throws -> EvoLine {
        if let request = dexNameRequests[baseID] { return try await request.value }
        let provider = self.provider
        let request = Task { try await provider.line(baseSpeciesID: baseID) }
        dexNameRequests[baseID] = request
        defer { dexNameRequests[baseID] = nil }
        return try await request.value
    }

    func dexResolveChainNames(_ entry: DexEntry) async -> [Int: String] {
        // Another row of this evolution line may already have refreshed the stored entry.
        let entry = state.dex.first { $0.id == entry.id } ?? entry
        if !entry.needsNamesRefresh, let stored = dexStoredChainNames(entry) { return stored }
        let oldNames = dexStoredChainNames(entry) ?? [:]
        guard let line = try? await dexNameLine(baseID: entry.baseID) else {
            return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { ($0, oldNames[$0] ?? "#\($0)") })
        }
        // Preserve usable older names if a response is partial. Only a complete chain gets
        // the new version, so partial/offline responses remain eligible for retry.
        func refreshed(_ original: DexEntry) -> DexEntry {
            var result = original
            var merged = original.names ?? [:]
            for id in original.chainOrder {
                if let incoming = line.names[id], !incoming.isEmpty {
                    merged[id] = (merged[id] ?? [:]).merging(incoming) { _, new in new }
                }
            }
            result.names = merged.isEmpty ? nil : merged
            // `currentNamesVersion` 은 한국어 표기를 넣으면서도 **올리지 않았다.** 올리면 기존
            // 항목이 전부 `needsNamesRefresh` 가 되는데, 아머 폼은 어느 ladder line 에도 없어서
            // 라인 조회가 그 종의 이름을 영원히 못 채운다 — 매 진입마다 재조회만 하는 영구
            // 루프가 된다(`ArmorEvolutionTests` 의 아머 항목 재조회 가드가 이걸 지킨다).
            // 대가: 표기가 추가되기 전에 저장된 행의 **저장값**은 영문인 채로 남는다. 표시
            // 경로가 번들을 저장값보다 우선하므로(`dexDisplayName`) 화면에는 드러나지 않지만,
            // 저장값 자체를 읽는 경로가 새로 생기면 그쪽은 옛 표기를 보게 된다.
            if original.chainOrder.allSatisfy({ line.names[$0]?.isEmpty == false }) {
                result.namesVersion = DexEntry.currentNamesVersion
            }
            return result
        }
        // One successful lookup also refreshes duplicate catches of the same evolution line.
        for index in state.dex.indices where state.dex[index].baseID == entry.baseID
            && state.dex[index].needsNamesRefresh {
            state.dex[index] = refreshed(state.dex[index])
        }
        save()
        let chainNames = refreshed(entry).names ?? [:]
        return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { id in
            (id, chainNames[id].flatMap { state.language.resolveName($0) } ?? "#\(id)")
        })
    }

    // MARK: 갱신 (AppDelegate 가 UsageStore 값으로 호출)

    func update(todayTokensByProvider: [String: Int], todayDate: String, monthTotal: Int,
                burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool) {
        let todayTokens = todayTokensByProvider.values.reduce(0, +)
        // `hasUsageData`는 표시용 snapshot 존재 여부이고, 이 map은 오늘 날짜가 확인된
        // provider 데이터만 담는다. stale snapshot이나 today == nil carrier만 있는 refresh는
        // ledger의 기준점을 움직일 수 있는 관측으로 취급하지 않는다.
        let hasCurrentProviderData = hasUsageData && !todayTokensByProvider.isEmpty
        if !state.installBaselineSet {
            // 설치 기준선 — 실제 데이터가 도착한 시점의 today 를 baseline 으로(이전 사용량 미카운트).
            // 데이터 도착 전(기동 직후 빈 새로고침)에는 잡지 않는다.
            guard hasCurrentProviderData else {
                // 세이브 불러오기가 baseline 판정을 이 경로에 넘겼을 수 있다(SaveTransfer.rebasedForThisDevice).
                // 그 경우 개체는 이미 들어와 있으므로 알로 표시하면 안 되고, 진화 라인 로드도 계속 재시도해야
                // 한다 — 새 Mac 은 AI CLI 를 처음 쓸 때까지 hasUsageData 가 false 라 여기서 막히면 그날 내내
                // 알로 보인다(재시작해도 동일).
                displayState = state.active == nil ? .egg : .idle
                kickLineLoadIfNeeded()
                return
            }
            state.installBaselineSet = true
            state.claimedTodayTokensByProvider = todayTokensByProvider
            state.lastDate = todayDate
            save()
        } else {
            // `today == nil` carrier만 남거나 파싱이 실패한 refresh는 현재 map이 비어 있을 수
            // 있다. 그런 관측으로 날짜·ledger를 움직이면 다음 정상 snapshot을 당일 전체 신규
            // 사용량으로 오인할 수 있으므로, 유효한 사용량이 있는 refresh만 ledger를 갱신한다.
            if hasCurrentProviderData {
                let dateChanged = todayDate != state.lastDate
                if state.claimedTodayTokensByProvider == nil {
                    // 구버전 세이브에는 aggregate high-water mark만 있어 프로바이더별로 분해할 수 없다.
                    // 첫 유효 관측을 새 장부의 기준점으로만 저장해 과거 사용량을 소급 지급하지 않는다.
                    state.claimedTodayTokensByProvider = todayTokensByProvider
                    state.lastDate = todayDate
                    AppLog.write("companion provider ledger seeded date=\(todayDate) providers=\(todayTokensByProvider.keys.sorted().joined(separator: ","))")
                } else if dateChanged {
                    // 일자별 snapshot은 서로 비교할 수 없다. 새 날짜에는 이전 날짜의 ledger를
                    // 기준으로 삼지 않고, 현재 날짜의 누적값 전체를 새 날짜 사용량으로 적립한다.
                    // 단, 위의 nil migration 경로는 구버전 aggregate를 분해할 수 없으므로 seed만 한다.
                    //
                    // 이전 날짜에 이미 알려진 provider가 첫 새로고침에서 빠질 수 있다(오늘 데이터
                    // 없음, stale 응답, 일시 실패). 그 provider를 아예 ledger에서 제거하면 같은
                    // 날짜에 복구될 때 현재 누적값을 "이미 적립한 값"으로 seed해 사용량이 누락된다.
                    // 이전 날짜의 숫자는 비교에 사용할 수 없으므로, 알려진 provider의 새 날짜 기준을
                    // 0으로 열어 둔다. 이후 복구된 현재 날짜 값은 그 날짜의 실제 사용량으로 적립되고,
                    // 같은 날짜의 부분 응답에서는 이 기준을 그대로 보존한다.
                    state.lastDate = todayDate
                    var newLedger = Dictionary(uniqueKeysWithValues:
                        state.claimedTodayTokensByProvider!.keys.map { ($0, 0) })
                    for (providerID, current) in todayTokensByProvider {
                        newLedger[providerID] = current
                    }
                    state.claimedTodayTokensByProvider = newLedger
                    let delta = todayTokensByProvider.values.reduce(0, +)
                    if delta > 0 {
                        state.usedSinceInstall += delta
                        if state.active == nil {
                            state.eggUsage += delta
                        } else {
                            applyUsage(delta)
                        }
                    }
                } else {
                    var ledger = state.claimedTodayTokensByProvider ?? [:]
                    var delta = 0
                    for (providerID, current) in todayTokensByProvider {
                        guard let previous = ledger[providerID] else {
                            // 새로 관측된 프로바이더의 과거 로그를 소급하지 않는다. 이후 refresh부터
                            // 해당 프로바이더의 증가분을 추적할 수 있도록 현재 값을 seed한다.
                            ledger[providerID] = current
                            continue
                        }
                        if current < previous {
                            // 전체 합계가 아니라 해당 프로바이더의 line만 rebase한다. 다른 프로바이더가
                            // 이번 refresh에서 보고하지 않았거나 carrier snapshot만 남은 경우에는 map에
                            // line 자체가 없으므로 기존 기준값을 건드리지 않는다.
                            ledger[providerID] = current
                            AppLog.write("companion usage regression provider=\(providerID) date=\(todayDate) previous=\(previous) current=\(current) drop=\(previous - current) — rebased provider ledger")
                            continue
                        }
                        delta += current - previous
                        ledger[providerID] = current
                    }
                    state.claimedTodayTokensByProvider = ledger
                    if delta > 0 {
                        state.usedSinceInstall += delta
                        if state.active == nil {
                            state.eggUsage += delta   // 알 인큐베이션 누적
                        } else {
                            applyUsage(delta)
                        }
                    }
                }
            }
        }
        // 이벤트(진화/졸업/부화) 창 만료 — .levelUp 창이 끝날 때 문구 플래그를 함께 정리한다.
        // justEvolvedTo 는 여기(창 만료)에서만 지운다: 과거엔 매 update() 초입에 무조건 nil 로 밀어,
        // 진화 후 4초 창 도중 update 틱이 끼면 "…(으)로 진화했어요"→"성장했어요"로 되돌아갔다(회귀 #4).
        if let until = eventUntil, clock() > until {
            justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        }
        if state.active == nil, state.installBaselineSet, !isHatching {
            if state.eggUsage >= eggHatchThreshold {
                // ready egg 는 부화를 우선한다. 같은 틱에 프리패치와 별도 Task 로 경쟁시키면
                // 프리패치 락을 본 부화가 반환하고 실패 상태도 놓칠 수 있다.
                Task { await hatchIfNeeded() }
            } else {
                // 임계 전에는 종 pre-roll + 라인/스프라이트 예열(부화 순간 딜레이 제거).
                Task { await ensureEggPrefetch() }
            }
        }
        // active 인데 라인 미로딩(앱 재시작) → 로드
        if state.active != nil, currentLine == nil, !isHatching {
            Task { await loadCurrentLine() }
        }
        displayState = computeState(burnTier: burnTier, limitWarning: limitWarning,
                                    hasUsageData: hasUsageData, today: todayTokens)
        save()
    }

    /// 토큰 증분을 현재 디지몬에 적용 — 임계 도달 시 진화/졸업.
    /// 라인 미로딩(재시작 직후·오프라인)이어도 사용량은 항상 적립한다 — 여기서 드롭하면
    /// 프로바이더별 ledger 는 이미 전진해 델타가 영구 유실된다. 진화 판정만 라인 로드 후로 미룬다.
    func applyUsage(_ delta: Int) {
        guard state.active != nil else { return }
        state.active!.usedAtStage += delta
        reconcileActiveProfileGrowth()
        guard let line = currentLine else { save(); return }
        var guardCount = 0
        while state.active != nil, guardCount < 50 {
            guardCount += 1
            let a = state.active!
            let thr = stageThreshold(for: a)
            guard a.usedAtStage >= thr else { break }
            guard let node = line.tree.node(withID: a.currentID) else { break }
            if node.children.isEmpty {
                graduate(); break
            } else {
                // 정규 진화가 아머보다 우선한다 — 자동 해제 후 진화(사용자 확정).
                // **명시적으로** 지운다: `currentID` 가 사다리 종을 유지하도록 설계했기 때문에
                // 아머 착용 중에도 `node(withID:)` 는 정상적으로 노드를 찾는다. 즉 위의 nil-node
                // `break` 로는 이 상황이 걸리지 않으며, 그래야 아머 착용 중에도 성장이 멈추지 않는다.
                // 여기서 안 지우면 진화 후 사다리 종과 무관한 아머가 남는다(다음 sanitize 까지 표시 오염).
                state.active!.armorID = nil
                let nextIndex = a.stageIndex + 1
                let next: EvoNode
                if a.plannedPathIDs.indices.contains(nextIndex),
                   let planned = node.children.first(where: { $0.speciesID == a.plannedPathIDs[nextIndex] }) {
                    next = planned
                } else {
                    next = pickPlannedChild(node, baseID: a.baseID)
                    let fallbackRoute = [node.speciesID] + makeEvolutionPlan(from: next, baseID: a.baseID)
                    let repaired = Self.repairedPlan(realizedPath: a.pathIDs, stageIndex: a.stageIndex,
                                                     fallbackRoute: fallbackRoute)
                    state.active!.plannedPathIDs = repaired
                    state.active!.totalForms = repaired.count
                    AppLog.write("evolve: repaired invalid planned path for base \(a.baseID)")
                }
                state.active!.pathIDs = Array(a.pathIDs.prefix(a.stageIndex + 1)) + [next.speciesID]
                state.active!.stageIndex += 1
                state.active!.usedAtStage = a.usedAtStage - thr   // 초과분 이월
                if let details = digimonDetailsByID[next.speciesID] {
                    state.active!.profile?.enrich(with: details)
                } else if detailProvider != nil {
                    Task { await self.loadDigimonDetails(speciesID: next.speciesID) }
                }
                let newName = line.localizedName(next.speciesID, state.language)
                justEvolvedTo = newName
                fireCelebration(.evolve)
                // 짧은 levelUp 창 — 진화 순간 "…(으)로 진화했어요" 문구 노출(hatch/graduate 와 동일 패턴).
                // 이게 없으면 computeState 가 .levelUp 을 안 내 statusEvolved 가 도달 불가(dead code)였다.
                eventUntil = clock().addingTimeInterval(4)
                notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(newName))
            }
        }
        reconcileActiveProfileGrowth()
        save()
    }

    private func pickPlannedChild(_ node: EvoNode, baseID: Int) -> EvoNode {
        let fresh = node.children.filter { ch in
            ch.finalIDs.contains { !state.collectedFinals.contains("\(baseID):\($0)") }
        }
        let pool = fresh.isEmpty ? node.children : fresh
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    private func makeEvolutionPlan(from root: EvoNode, baseID: Int) -> [Int] {
        var plan = [root.speciesID]
        var node = root
        while !node.children.isEmpty {
            let next = pickPlannedChild(node, baseID: baseID)
            plan.append(next.speciesID)
            node = next
        }
        return plan
    }

    static func repairedPlan(realizedPath: [Int], stageIndex: Int, fallbackRoute: [Int]) -> [Int] {
        guard !realizedPath.isEmpty else { return fallbackRoute }
        let currentIndex = min(stageIndex, realizedPath.count - 1)
        let prefix = Array(realizedPath.prefix(currentIndex + 1))
        guard fallbackRoute.first == prefix.last else { return prefix }
        return prefix + fallbackRoute.dropFirst()
    }

    /// 루트부터 실제로 이어지는 가장 긴 ID 경로와 마지막 유효 노드. 첫 ID가 루트와 다르면 루트로 복구한다.
    private func longestValidPath(_ ids: [Int], from root: EvoNode) -> (path: [Int], lastNode: EvoNode) {
        var path = [root.speciesID]
        var node = root
        guard ids.first == root.speciesID else { return (path, node) }
        for id in ids.dropFirst() {
            guard let child = node.children.first(where: { $0.speciesID == id }) else { break }
            path.append(id)
            node = child
        }
        return (path, node)
    }

    /// 저장된 실제 경로와 계획을 현재 에셋 트리에 맞춘다. 완전한 계획만 재사용해 재시작 시 RNG를 소비하지 않는다.
    private func normalizedEvolutionState(_ saved: MonState, from root: EvoNode) -> MonState {
        var normalized = saved
        let realized = longestValidPath(saved.pathIDs, from: root)
        let candidate = longestValidPath(saved.plannedPathIDs, from: root)
        let canReusePlan = candidate.path == saved.plannedPathIDs
            && candidate.path.starts(with: realized.path)
            && candidate.lastNode.children.isEmpty
        let plan: [Int]
        if canReusePlan {
            plan = candidate.path
        } else {
            let suffix = makeEvolutionPlan(from: realized.lastNode, baseID: saved.baseID)
            plan = realized.path + suffix.dropFirst()
        }
        normalized.pathIDs = realized.path
        normalized.plannedPathIDs = plan
        normalized.stageIndex = realized.path.count - 1
        normalized.totalForms = plan.count
        // `longestValidPath` 는 절단만 하는 게 아니라 **루트를 갈아끼운다**(저장된 머리가 라인 루트와
        // 다르면 `[루트]` 로 통째 교체). 그래서 로드 경계(`SaveTransfer.sanitized`)에서 유효했던
        // 아머가 여기서 근거를 잃을 수 있다 — 같은 판정을 정규화 후에 한 번 더 건다.
        normalized.armorID = SaveTransfer.validArmorID(normalized.armorID,
                                                       forLadderSpecies: normalized.currentID)
        return normalized
    }

    private func graduate() {
        guard var a = state.active else { return }
        a.profile?.advanceGrowth(to: DigimonBalance.graduationTotal(a.rarity), rarity: a.rarity)
        if let details = digimonDetailsByID[a.currentID] { a.profile?.enrich(with: details) }
        let finalID = a.currentID
        state.collectedFinals.insert("\(a.baseID):\(finalID)")
        state.dex.append(DexEntry(id: a.profile?.instanceID ?? UUID().uuidString,
                                  baseID: a.baseID, finalID: finalID,
                                  chainOrder: a.pathIDs, rarity: a.rarity, caughtAt: clock(),
                                  profile: a.profile,
                                  names: currentLine.map { line in   // 체인 각 종의 다국어 이름 저장(표시 즉시)
                                      Dictionary(uniqueKeysWithValues:
                                          a.pathIDs.compactMap { id in line.names[id].map { (id, $0) } })
                                  }))
        let name = currentLine?.localizedName(finalID, state.language) ?? ""
        justGraduated = name
        notifyCompanionEvent(l.notifGraduateTitle, l.notifGraduateBody(name))
        eventUntil = clock().addingTimeInterval(6)
        state.active = nil
        state.reconcileRepresentativeSelection()   // 졸업 체인이 dex 로 옮겨져 선택은 정상적으로 유지된다
        activeGeneration += 1
        currentLine = nil
        state.eggUsage = 0   // 새 알은 처음부터 인큐베이션
        isHatchRetryDelayed = false
        // eggTier 는 손대지 않는다 — 여기 도달했다는 건 활성 디지몬이 있었다는 뜻이라 보증은 이미 nil 이다
        // (부화가 소비, 디스크/불러오기는 sanitized 가 정규화). 소비 지점은 hatchCore 한 곳으로 유지한다.
        // 다만 **맡겨 둔 보증**은 여기서 되찾는다 — 방금 알이 생겼으니 보증이 붙을 자리가 열렸다
        // (보관 개체를 꺼낼 때 파킹한 값. `retrieveStored`/`parkEggGuarantee`).
        // 프리패치 **전에** 복원해야 한다 — 순서가 뒤바뀌면 보증 없는 롤이 먼저 돌아 산 등급이 무시된다.
        state.restoreParkedEggGuarantee()
        // "알을 받는 순간" 즉시 프리패칭 시작 — 다음 부화의 종·라인·스프라이트 예열.
        Task { await self.ensureEggPrefetch() }
    }

    // MARK: 인벤토리 / 이상한 사탕

    var rareCandyCount: Int { itemCount(.rareCandy) }
    func itemCount(_ kind: ItemKind) -> Int { state.inventory[kind.rawValue] ?? 0 }

    /// 소유 아이템(개수>0) — 가방 목록. 정렬은 ItemKind.allCases 순서.
    var ownedItems: [(kind: ItemKind, count: Int)] {
        ItemKind.allCases.compactMap { k in
            let c = itemCount(k)
            return c > 0 ? (k, c) : nil
        }
    }

    /// 이상한 사탕 사용 가능 — 활성 디지몬 + 라인 로딩 완료 + 재고>0.
    /// 라인 미로딩(재시작 직후·오프라인)이면 비활성 — 사탕이 진화 없이 적립만 되는 것 방지.
    var canUseRareCandy: Bool { maxRareCandyUseCount > 0 }

    /// Use the same rounded, difficulty-adjusted thresholds as actual growth.
    /// Preview the apparent evolution path so hidden identities cannot change the picker.
    private var rareCandyStageCosts: [Int] {
        guard var mon = state.active, currentLine != nil else { return [] }
        return (mon.stageIndex..<mon.totalForms).map { stage in
            mon.stageIndex = stage
            return stageThreshold(for: mon)
        }
    }

    var maxRareCandyUseCount: Int {
        let remaining = max(0, rareCandyStageCosts.reduce(0, +) - (state.active?.usedAtStage ?? 0))
        let needed = remaining / RareCandy.xp + (remaining % RareCandy.xp == 0 ? 0 : 1)
        return min(rareCandyCount, needed)
    }

    struct RareCandyUsePlan {
        let count: Int
        var xp: Int { count * RareCandy.xp }
        let evolves: Bool
        let graduates: Bool
        let carryoverXP: Int
        let discardedXP: Int
    }

    func planRareCandyUse(count requested: Int) -> RareCandyUsePlan? {
        let count = min(max(0, requested), maxRareCandyUseCount)
        guard count > 0, let mon = state.active else { return nil }
        let costs = rareCandyStageCosts
        var remaining = mon.usedAtStage + count * RareCandy.xp
        var evolves = false
        for (index, cost) in costs.enumerated() {
            guard remaining >= cost else { break }
            remaining -= cost
            if index == costs.count - 1 {
                return RareCandyUsePlan(count: count, evolves: evolves, graduates: true,
                                       carryoverXP: 0, discardedXP: remaining)
            }
            evolves = true
        }
        return RareCandyUsePlan(count: count, evolves: evolves, graduates: false,
                               carryoverXP: evolves ? remaining : 0, discardedXP: 0)
    }

    /// 사탕 사용 결과 — UI 피드백 분기용.
    enum CandyUseResult: Equatable { case evolved, graduated, progressed, unavailable }

    /// Spend only the candies needed by the current growth plan, preserving unused inventory.
    /// 사탕 XP 는 usedAtStage(진화 진행)에만 반영 — usedSinceInstall/오늘 토큰(실사용 통계)엔 안 잡힌다.
    @discardableResult
    func useRareCandy(count: Int = 1) -> CandyUseResult {
        guard let preview = planRareCandyUse(count: count) else { return .unavailable }
        let consumed = preview.count
        let xp = consumed * RareCandy.xp
        state.inventory[ItemKind.rareCandy.rawValue] = rareCandyCount - consumed
        let beforeStage = state.active?.stageIndex ?? 0
        // 진화 안 될 때(부분 진행)도 즉시 "+XP" 피드백 — CompanionHeader 가 연출과 별개로 표시.
        candyFeedbackAmount = xp
        candyFeedbackSeq += 1
        applyUsage(xp)   // Saves inventory and growth together, with existing evolution effects.
        if state.active == nil { return .graduated }
        if state.active!.stageIndex > beforeStage { return .evolved }
        return .progressed
    }

    // MARK: 아머 진화 (디지멘탈)

    /// 현재 아머 착용 중인 종 id. nil = 미착용.
    var armorSpeciesID: Int? { state.active?.armorID }
    var isArmored: Bool { state.active?.armorID != nil }

    /// 이 디지멘탈로 지금 아머 진화할 수 있나 — **데이터 조회가 곧 게이트다.**
    ///
    /// `DigiLevel == .child` 로 판정하지 않는다: Tailmon(83)은 데이터상 Child 지만 작중 Adult 급이라
    /// 레벨 축 판정은 경계 사례에서 어긋난다(`DigimonData` tailmonLine 주석). 매핑이 있으면 가능,
    /// 없으면(성숙기 이상·대상 아닌 종) 불가 — 조회 하나가 두 판정을 동시에 한다.
    ///
    /// 기준은 항상 **사다리 종**(`currentID`)이다. 아머체는 `armorResults` 의 childID 가 아니라
    /// 아머체 기준으로 조회하면 항상 nil 이 되어 교체(A→B)가 막힌다.
    func armorResult(for kind: ItemKind) -> Int? {
        guard let a = state.active, let digimental = kind.digimental else { return nil }
        return DigimonData.armorResult(childID: a.currentID, digimental: digimental)
    }

    func canArmorEvolve(_ kind: ItemKind) -> Bool {
        itemCount(kind) > 0 && armorResult(for: kind) != nil
    }

    /// 디지멘탈 사용 — 아머 오버레이를 씌운다. 이미 착용 중이면 **교체**(해제 후 재사용과 같은 결과).
    ///
    /// **디지멘탈은 소모되지 않는다**(열쇠형, 사용자 확정). 자유 전환과 맞물려 재고 0 때문에
    /// 되돌리지 못하는 상태가 생기지 않는다. 악용 여지는 §7 불변조건이 닫는다 — 아래에서
    /// `armorID` 외에는 어떤 사다리 필드도 건드리지 않으므로 왕복해도 XP·임계값 이득이 0 이다.
    @discardableResult
    func useDigimental(_ kind: ItemKind) -> Bool {
        guard canArmorEvolve(kind), let armorID = armorResult(for: kind) else { return false }
        state.active!.armorID = armorID
        // 연출·알림은 **그 아머체를 처음 얻었을 때만** — 디지멘탈은 비소모라 착용/해제가 무료고,
        // 그대로 두면 10회 토글이 "진화했어요!" 알림 10개가 된다. 도감이 종 단위로 접히는 것과
        // 같은 기준(=도감에 이미 있나)으로 접어 비대칭을 없앤다. 재착용·이전 아머 복귀는 조용히 전환.
        // 네 효과를 조건 하나로 묶는다: 테스트가 볼 수 없는 알림을 볼 수 있는 연출이 대신 지킨다.
        if recordArmorDexEntry(armorID) {
            justEvolvedTo = displayName
            fireCelebration(.evolve)
            eventUntil = clock().addingTimeInterval(4)
            notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(displayName))
        }
        AppLog.write("armor: equipped \(armorID) via \(kind.rawValue) on \(state.active!.currentID)")
        save()
        return true
    }

    /// 아머 해제 — 사다리 종으로 되돌아간다. 도감 기록은 **지우지 않는다**(쌓이기만 한다).
    @discardableResult
    func removeArmor() -> Bool {
        guard state.active?.armorID != nil else { return false }
        state.active!.armorID = nil
        justEvolvedTo = nil   // 아머 착용 토스트가 해제 후에도 남아 있지 않게
        eventUntil = nil
        save()
        return true
    }

    /// 아머체의 영구 도감 기록 — 되돌려도 남는다.
    ///
    /// 아머체는 `pathIDs` 에 없어서 `dexSpecies`/`ownsSpecies` 가 저절로 잡지 못하고,
    /// `MonState.armorID` 에서 유도하면 해제하는 순간 기록이 증발한다(도감의 "쌓이기만 한다" 위반).
    /// 졸업 기록과 같은 형태의 `DexEntry` 를 쓰면 희귀도·항목별 격리 디코딩·정렬·
    /// `ownsSpecies` 커버리지가 전부 기존 배선 그대로 딸려온다.
    /// - Returns: 새 항목을 추가했으면 true(= 이 아머체를 처음 얻음), 이미 있었으면 false.
    @discardableResult
    private func recordArmorDexEntry(_ armorID: Int) -> Bool {
        // 재착용이 같은 줄을 반복해서 쌓지 않게 종 단위로 접는다. id 는 개체 instanceID 를 그대로 쓰면
        // 나중에 같은 개체가 졸업할 때 만드는 항목과 충돌하므로(둘 다 instanceID 를 id 로 쓴다)
        // 아머 접두어 + 아머체 id 로 갈라 둔다.
        //
        // ⚠️ 이 키는 도감 외관만 좌우하는 게 아니라 **알림·연출을 쏠지**를 결정한다(`useDigimental`).
        // `profile` 은 hatch(무조건 generate)·구버전 마이그레이션·sanitize(빈 문자열 복구) 3중으로
        // 항상 채워져 아래 폴백은 도달 불가다. 만약 타면 키가 개체가 아니라 **종** 단위가 되어,
        // 같은 종을 새로 키운 개체의 첫 아머 진화가 조용해진다. 그래서 여기만 `:339`/`:754` 와 달리
        // `?? UUID()`(충돌 회피)가 아니라 `?? baseID`(충돌 유도)를 쓴다 — 접는 것이 목적이라서다.
        let entryID = "armor-\(state.active?.profile?.instanceID ?? "\(state.active?.baseID ?? 0)")-\(armorID)"
        guard !state.dex.contains(where: { $0.id == entryID }) else { return false }
        guard let a = state.active else { return false }
        let now = clock()
        state.dex.append(DexEntry(
            id: entryID,
            baseID: a.baseID,
            finalID: armorID,
            chainOrder: [armorID],
            rarity: a.rarity,
            // caughtAt 은 동행 기록 정렬 키다 — 비우면 이 줄이 구버전 항목들과 함께 맨 뒤로 가라앉는다.
            caughtAt: now,
            profile: a.profile,
            // 이름을 여기서 심는다. 비워 두면 도감 칸이 `#305` 로 남는 데 더해 `needsNamesRefresh` 가
            // 영영 true 라 backfillMissingDexNames 가 매번 라인을 조회하는데, 사다리 라인엔 아머체가
            // 없어 절대 채워지지 않는다. 표시는 읽기 시점에 번들 데이터로 다시 해석하므로
            // (`dexDisplayName`) 여기 굳은 값이 언어를 고정하지는 않는다.
            names: DigimonData.name(for: armorID).map { [armorID: $0.localizedNames] },
            armoredAt: now))
        return true
    }

    // MARK: 죠그레스 (GAME-DESIGN.md §3)

    /// 죠그레스 후보 — `(현재 사다리 종 + 파트너) → 결과`. 파트너 기록이 없어도(=불가) 후보로 나온다:
    /// 뷰가 "무엇을 졸업시켜야 하는가" 를 안내하려면 미충족 조합도 보여야 한다.
    struct JogressCandidate: Sendable, Identifiable {
        let partnerID: Int
        let resultID: Int
        /// 파트너 졸업 기록이 도감에 있나 — 뷰의 `.disabled` 가 읽는 **표시값**이다.
        /// 실행 게이트는 이걸 믿지 않고 `performJogress` 에서 도감을 다시 본다(참칭 방지).
        let hasPartner: Bool
        /// 아래 정렬 키와 **같은 조합**이다. `resultID` 만으로는 부족하다 — 정렬이 partner 를 2차 키로
        /// 두는 이유(한 종이 여러 조합의 부모가 될 수 있다)가 그대로 id 에도 적용되기 때문이다.
        /// 데이터에 그런 조합이 추가되면 `resultID` 단독 id 는 SwiftUI 에서 중복이 되어 행이 사라진다.
        var id: String { "\(resultID)-\(partnerID)" }
    }

    /// 지금 육성 중인 개체로 성립할 수 있는 죠그레스 조합 전부.
    ///
    /// **데이터 조회가 곧 게이트다** — 아머(`armorResult`)와 같은 태도로, `DigiLevel` 로 판정하지 않는다.
    /// Tailmon(83)은 데이터상 Child 지만 죠그레스 부모라, 레벨 축으로 거르면 실피드몬 경로가 사라진다.
    ///
    /// 기준은 항상 **사다리 종**(`currentID`)이다. 아머체(`displayID`)로 조회하면 항상 빈 배열이 된다.
    /// 조합 테이블은 전부 `DigimonData.jogressResults` 에서 오므로, 데이터에 조합이 추가되면
    /// 여기 손대지 않아도 그대로 동작한다(팔라딘 모드 481 은 405 도달 규칙만 정해지면 저절로 붙는다).
    ///
    /// 정렬: `jogressResults` 는 Dictionary 라 순회 순서가 실행마다 다르다. 뷰와 테스트가 보는 순서가
    /// 흔들리지 않게 결과 id 로 전순서를 만든다(한 종이 여러 조합의 부모인 경우에 대비해 partner 도 함께).
    var jogressCandidates: [JogressCandidate] {
        guard let a = state.active else { return [] }
        let me = a.currentID
        return DigimonData.jogressResults.compactMap { key, resultID -> JogressCandidate? in
            let ids = key.speciesIDs
            // 이미 얻은 결과는 후보에서 뺀다 — `chainCandidates` 의 `chain-` 필터와 같은 이유다.
            // 파트너는 비소모라 `hasPartner` 가 계속 true 이므로, 빼지 않으면 성공 후에도 그 행이
            // **영구 활성 버튼**으로 남고 누르면 `recordJogressDexEntry` 가 false 를 주고 끝난다.
            // 두 경로(사다리/도감 전용) 공통이라 분기 앞에 둔다.
            guard !state.dex.contains(where: { $0.id == "jogress-\(resultID)" }) else { return nil }
            // 사다리 종이 부모인 조합은 **육성 중인 개체가 그 종이어야** 한다(§3 "2마리가 필요하다").
            // 그 축을 만족하지 못하면 아래 도감 전용 경로로 떨어진다.
            if let partnerID = ids.first(where: { $0 != me }), ids.contains(me) {
                // 같은 종끼리의 조합은 데이터에 없다. 있더라도 `first(where:)` 가 자기 자신을 파트너로
                // 골라 "스스로를 졸업시켜라" 는 안내가 되므로, 그 경우는 후보에서 빠지는 게 맞다.
                return JogressCandidate(partnerID: partnerID, resultID: resultID,
                                        hasPartner: hasJogressPartnerRecord(partnerID))
            }
            // **도감 전용 조합** — 양쪽 부모가 모두 사다리 밖 종일 때만. 팔라딘 모드(481)가 유일한
            // 사례다: 부모 405·183 은 둘 다 죠그레스/체인 결과물이라 12개 라인 stages 어디에도 없고,
            // 따라서 `currentID` 가 그 종이 되는 일이 **영원히 없다**. 위 축만 두면 481 은 데이터에
            // 조합이 있어도 후보로 나올 수 없어 영구 도달 불가다(§3 이 경고하는 바로 그 상태).
            //
            // 완화는 `isLadderSpecies` 로 **데이터에서** 좁힌다 — id 를 박지 않으므로 라인 구성이
            // 바뀌면 판정도 따라 움직인다. 사다리 부모가 하나라도 있는 조합(예: 202+168→183)은
            // 여기 걸리지 않아 "육성 중인 개체가 부모여야 한다" 는 전제를 그대로 유지한다.
            guard ids.allSatisfy({ !DigimonData.isLadderSpecies($0) }) else { return nil }
            // **한쪽이라도 기록이 있을 때만** 후보로 낸다. 이 조합은 육성 개체와 무관하게 성립하므로
            // 조건 없이 내보내면 갓 부화한 플레이어에게도 "오메가몬을 먼저 졸업시켜야 합니다" 라는
            // 영구 비활성 행이 상시 떠 있는다(죠그레스 컨트롤은 후보가 있으면 무조건 그려진다).
            // 진행이 시작된 뒤에만 보여서 "다음 목표" 로 읽히게 한다.
            guard ids.contains(where: hasJogressPartnerRecord) else { return nil }
            // 부모가 둘 다 도감 기록이라 어느 쪽을 "파트너" 로 부를지는 임의다 — 아직 없는 쪽을
            // 파트너로 지목해야 안내가 "무엇을 더 구해야 하는가" 를 가리킨다.
            guard let partnerID = ids.first(where: { !hasJogressPartnerRecord($0) }) ?? ids.min()
            else { return nil }
            return JogressCandidate(partnerID: partnerID, resultID: resultID,
                                    hasPartner: ids.allSatisfy(hasJogressPartnerRecord))
        }
        .sorted { ($0.resultID, $0.partnerID) < ($1.resultID, $1.partnerID) }
    }

    /// 지금 바로 실행할 수 있는 죠그레스(파트너 기록 충족).
    var availableJogress: JogressCandidate? { jogressCandidates.first { $0.hasPartner } }

    /// 이 종이 죠그레스 **파트너 자격**을 갖는 도감 기록을 갖고 있나.
    ///
    /// `state.ownsSpecies` 를 쓰지 않는다 — 그건 도감 기록 외에 **현재 개체가 도달한 단계**까지
    /// true 를 주므로, 육성 중인 개체 하나로 양쪽 부모를 동시에 만족시켜 버린다("2마리가 필요하다"는
    /// §3 의 전제가 무너진다). 인정 여부는 도감 항목의 종류로 갈린다:
    ///
    ///  - ✅ **졸업 기록** — §3 이 파트너로 인정하는 바로 그 기록.
    ///  - ✅ **죠그레스 결과 기록** — 아래 `recordJogressDexEntry` 가 만드는 항목도 졸업분과 같은
    ///        형태(`releasedAt`/`armoredAt` 둘 다 nil)라 자동으로 자격을 갖는다. 팔라딘 모드(481)의
    ///        부모가 둘 다 죠그레스 결과물이므로, 이게 아니면 그 경로가 영구 도달 불가다(§3).
    ///  - ❌ **놓아준 기록**(`isReleased`) — 졸업시키지 않고 포기한 개체다.
    ///  - ❌ **아머 기록**(`isArmored`) — 사다리 밖 표시 오버레이일 뿐 졸업이 아니다.
    ///
    /// `chainOrder` 로 대조하는 이유: 졸업 항목은 체인 전체를 담으므로 최종체가 아닌 중간 단계
    /// (예: Angemon 3 — Patamon 라인의 Adult)도 파트너가 된다. `finalID` 만 보면 그 조합이 막힌다.
    func hasJogressPartnerRecord(_ speciesID: Int) -> Bool {
        state.dex.contains { entry in
            !entry.isReleased && !entry.isArmored && entry.chainOrder.contains(speciesID)
        }
    }

    /// 파트너 기록이 없을 때의 안내 — "<파트너>을 먼저 졸업시켜야 합니다".
    /// 이름은 현재 언어로 해석한다. 라인(`currentLine`)이 아니라 `dataName` 을 쓰는 이유는
    /// `ladderName` 주석과 같다 — 파트너는 다른 라인의 종이라 애초에 현재 라인에 없다.
    func jogressPartnerHint(_ candidate: JogressCandidate) -> String {
        l.jogressNeedsPartner(Self.dataName(candidate.partnerID, state.language))
    }

    /// 죠그레스 결과의 현재 언어 이름 — 버튼 문구가 "무엇이 되는가" 를 가리킨다.
    func jogressResultName(_ candidate: JogressCandidate) -> String {
        Self.dataName(candidate.resultID, state.language)
    }

    /// 죠그레스 실행 — **도감 기록만 만든다.**
    ///
    /// ⚠️ 사다리 필드(`pathIDs`/`currentID`/`stageIndex`/`plannedPathIDs`)는 절대 건드리지 않는다.
    /// 죠그레스 결과 종은 12개 라인의 stages 어디에도 없어서 `line.tree.node(withID:)` 가 nil 을
    /// 반환하고, 그러면 `applyUsage` 의 진화 판정이 멈춰 성장이 영구 정지한다. 아머가 `currentID`
    /// (사다리)와 `displayID`(표시)를 갈라 둔 것과 같은 이유다 — 여기선 표시 축조차 안 건드린다.
    ///
    /// 파트너는 **소모되지 않는다**(§3: 도감은 재고가 아니라 기록이다).
    /// - Returns: 새 기록을 만들었으면 true. 불가(파트너 미충족·조합 없음)이거나 **이미 있는 기록**이면
    ///   false — 아머와 달리 두 번째 호출은 상태를 전혀 바꾸지 않으므로 "아무 일도 없었다"가 맞다.
    @discardableResult
    func performJogress(_ candidate: JogressCandidate) -> Bool {
        // 파트너 판정을 **여기서 다시 한다** — `candidate.hasPartner` 는 뷰의 `.disabled` 용 표시값이라
        // 그걸 믿으면 손으로 만든 후보가 게이트를 통과한다. 조합도 같은 이유로 데이터에 재조회한다.
        // 판정 권한은 후보 구조체가 아니라 store 에 있다.
        guard let a = state.active, hasJogressPartnerRecord(candidate.partnerID) else { return false }
        // 조합 성립 판정도 **데이터에 재조회**한다. 두 경로 중 하나를 만족해야 한다:
        //  ① 사다리 경로 — 육성 중인 개체가 한쪽 부모다.
        //  ② 도감 전용 경로 — 양쪽 부모가 모두 사다리 밖 종이고, 둘 다 도감 기록이 있다(481).
        //     `jogressCandidates` 와 같은 조건을 여기서 **다시** 세운다. 후보 구조체가 스스로
        //     "나는 도감 전용이다" 라고 말하게 두면 참칭 호출자가 사다리 조합(202+168)을 개체 없이
        //     통과시킨다 — 판정 권한은 후보가 아니라 store 에 있다.
        // `partnerID != a.currentID` 가드는 두지 않는다 — 데이터에 같은 종끼리의 조합이 없어
        // (jogress 5쌍 전부 `a != b`) 한 마리로 양쪽 부모를 만족시키는 경로가 열리지 않는다.
        // 생기더라도 `viaLadder` 는 `jogressResult(me, me)` 가 nil, `viaDex` 는 `isLadderSpecies(me)`
        // 가 true 라 둘 다 막힌다. 후보 산출부가 그 경우를 빼는 건 안내 문구가 "스스로를 졸업시켜라"
        // 가 되지 않게 하려는 표시 목적이고, 게이트 목적이 아니다.
        let viaLadder = DigimonData.jogressResult(a.currentID, candidate.partnerID) == candidate.resultID
        let viaDex = !viaLadder && DigimonData.jogressResults.contains { key, result in
            let ids = key.speciesIDs
            return result == candidate.resultID && ids.contains(candidate.partnerID)
                && ids.allSatisfy { !DigimonData.isLadderSpecies($0) && hasJogressPartnerRecord($0) }
        }
        guard viaLadder || viaDex,
              recordJogressDexEntry(candidate.resultID) else { return false }
        // 연출·알림은 아머와 같은 기준(=도감에 처음 들어갔을 때만)으로 접는다. 위 guard 가 이미
        // `recordJogressDexEntry` 의 반환으로 그 조건을 먹었으므로 여기 도달 = 처음 얻은 것이다.
        let name = Self.dataName(candidate.resultID, state.language)
        justEvolvedTo = name
        fireCelebration(.evolve)
        eventUntil = clock().addingTimeInterval(4)
        notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(name))
        AppLog.write("jogress: \(a.currentID) + \(candidate.partnerID) -> \(candidate.resultID)")
        save()
        return true
    }

    /// 죠그레스 결과의 영구 도감 기록 — 졸업분과 같은 형태(`releasedAt`/`armoredAt` 둘 다 nil)다.
    /// §3 "죠그레스 결과는 도감에 **졸업** 등록된다" 를 그대로 옮긴 것이라 새 필드가 필요 없고,
    /// 그 덕에 `hasJogressPartnerRecord` 가 별도 분기 없이 이 기록을 파트너로 인정한다.
    ///
    /// 기록은 **결과 종 하나당 한 줄**로 접는다(아머는 `armor-<instanceID>-<id>` 로 개체별이었다).
    /// 아머는 개체마다 되돌아오는 오버레이라 "이 개체가 처음 입었나" 가 연출 단위였지만, 죠그레스
    /// 결과는 개체에 붙는 상태가 아니라 도달했다는 사실 자체다 — 오메가몬 기록이 워그레이몬을 키울
    /// 때마다 한 줄씩 늘어나면 도감이 같은 종으로 도배된다.
    /// 체인 승급도 같은 형태의 기록을 만든다(`prefix` 로만 갈린다) — §3 이 둘을 같은 "졸업 등록"
    /// 으로 규정하므로 기록 형태가 갈리면 `hasJogressPartnerRecord` 가 한쪽만 파트너로 인정한다.
    /// 접두어를 나누는 건 id 충돌 방지용이다(같은 종이 두 경로로 들어올 일은 없지만, 기록의 출처가
    /// 로그·도감 디버깅에서 드러나는 편이 낫다).
    /// - Returns: 새 항목을 추가했으면 true, 이미 있었으면 false.
    @discardableResult
    private func recordJogressDexEntry(_ resultID: Int, prefix: String = "jogress") -> Bool {
        let entryID = "\(prefix)-\(resultID)"
        guard !state.dex.contains(where: { $0.id == entryID }), let a = state.active else { return false }
        state.dex.append(DexEntry(
            id: entryID,
            baseID: a.baseID,
            finalID: resultID,
            // 두 부모가 합쳐진 결과라 "체인" 이 아니다 — 결과 종 하나만 담는다. 부모를 여기 넣으면
            // 파트너 라인의 종이 이 기록만으로 보유 판정을 받아(`dexSpecies`/`hasJogressPartnerRecord`)
            // 졸업하지 않은 종이 도감에 생긴다.
            chainOrder: [resultID],
            rarity: a.rarity,
            caughtAt: clock(),
            profile: a.profile,
            // 아머 기록과 같은 이유로 이름을 심는다 — 비우면 `needsNamesRefresh` 가 영영 true 인데
            // 사다리 라인엔 죠그레스 결과가 없어 백필이 절대 채우지 못한다.
            names: DigimonData.name(for: resultID).map { [resultID: $0.localizedNames] }))
        return true
    }

    // MARK: 체인 승급 (EVOLUTION.md §3 — Imperialdramon 체인)

    /// 토큰을 지불해 진행하는 **단일 부모 전이** 후보. 331→900→405 두 간선이 전부다.
    struct ChainCandidate: Sendable, Identifiable {
        /// 출발 종 — 도감에 기록이 있어야 한다. 승급해도 **소모되지 않는다**.
        let fromID: Int
        let toID: Int
        /// 난이도까지 적용된 실제 지불액.
        let price: Int
        /// 잔액이 충분한가 — 뷰의 `.disabled` 가 읽는 **표시값**이다.
        /// 실행 게이트는 이걸 믿지 않고 `performChainPromotion` 에서 지갑을 다시 본다(참칭 방지).
        let affordable: Bool
        /// 출발·도착 종을 **함께** 쓴다 — 한 종에 들어오는 간선이 여럿이면 `toID` 단독 id 는
        /// SwiftUI 에서 중복이 되어 행이 사라진다(`JogressCandidate.id` 와 같은 이유).
        /// 두 필드를 다 담으므로 아래 정렬 키(`(fromID, toID)`)와 필드 순서가 달라도 유일하다.
        var id: String { "\(toID)-\(fromID)" }
    }

    /// 지금 승급할 수 있는 체인 간선 전부 — 도감에 출발 종 기록이 있는 것만.
    ///
    /// **한 단계씩**이라는 규칙은 별도 코드가 아니라 이 조회 자체가 강제한다: 900 기록이 없으면
    /// 900→405 간선의 출발 종 기록이 없어 후보가 아니다. 331 에서 405 로 건너뛰는 간선은
    /// 데이터에 아예 없으므로 "건너뛰기 금지" 를 판정하는 분기도 필요 없다.
    ///
    /// 간선은 `forwardEdges` 에서 온다(중복 진실 원천 금지 — 로더가 chain 테이블로 만든 그것).
    /// 사다리 간선과 타입상 구별되지 않는 `.normal` 이지만, **출발 종이 사다리 밖**일 때만 보므로
    /// 정규 진화가 여기 섞이지 않는다 — 정규 진화의 출발 종은 정의상 전부 사다리 종이다.
    /// 그래서 `EvolutionEdge` 에 새 case 를 만들지 않았다.
    var chainCandidates: [ChainCandidate] {
        // `jogressCandidates` 와 같은 형태의 알(육성 개체 없음) 가드다. 없으면 331 기록을 들고 알
        // 상태인 플레이어에게 승급 행이 **활성 버튼**으로 뜨는데, 눌러도 `recordJogressDexEntry` 가
        // `state.active` 언랩에서 false 로 떨어져 아무 일도 안 난다(토큰은 안 빠진다).
        // `chainPromotionControl` 은 `armorControl` 과 달리 body 에 무조건 있고 `CompanionHeader` 도
        // `hasActive` 와 무관하게 렌더되므로, 이 가드가 그 죽은 컨트롤을 막는 유일한 지점이다.
        guard state.active != nil else { return [] }
        let price = chainPromotionPrice
        let affordable = availableTokens >= price
        return DigimonData.chainEdges
            .filter { edge in
                // 이미 기록이 있으면 후보에서 뺀다 — 두 번째 지불이 아무것도 안 만들고 끝나지 않게.
                hasJogressPartnerRecord(edge.from)
                    && !state.dex.contains { $0.id == "chain-\(edge.to)" }
            }
            .map { ChainCandidate(fromID: $0.from, toID: $0.to, price: price, affordable: affordable) }
            // **출발 종** 오름차순이다. `DigimonData.chainEdges` 의 `(to, from)` 정렬을 여기서
            // 덮어쓴다 — 아래 `availableChainPromotion` 의 `first {}` 가 고르는 항목이 이 정렬로
            // 결정되므로, 도착 종 순서로 두면 두 간선이 동시에 열렸을 때 뒷 단계(900→405)가 앞에
            // 온다(405 < 900). 출발 종 순으로 두면 앞 단계(331→900)가 먼저 나와 한 단계씩 진행한다.
            // 이 체인에서 출발 종 오름차순 = 진행 순서인 건 331 < 900 이라서다(구조적 보장은 아니다 —
            // 간선이 늘어나면 `chainDepth` 같은 명시적 진행 순서 키가 필요하다).
            .sorted { ($0.fromID, $0.toID) < ($1.fromID, $1.toID) }
    }

    /// 지금 바로 실행할 수 있는 승급(잔액 충족).
    ///
    /// 앱 정상 경로로는 두 간선이 동시에 열리지 않지만(900 기록이 곧 331→900 을 닫는다), 손편집
    /// 세이브로 `chain-900` 이 아닌 id 의 항목에 `chainOrder: [900]` 을 심으면 열릴 수 있다.
    /// 그때도 위 정렬이 **앞 단계**를 먼저 주므로 900 을 건너뛴 1회 지불 승급은 성립하지 않는다.
    var availableChainPromotion: ChainCandidate? { chainCandidates.first { $0.affordable } }

    /// 승급 1회 가격 — 상점과 **같은 난이도 배율**을 적용한다(아이템·알과 한 축으로 움직인다).
    var chainPromotionPrice: Int {
        DigimonBalance.scaled(ChainPromotion.price, by: shopDifficulty)
    }

    /// 승급 결과의 현재 언어 이름 — 버튼 문구가 "무엇이 되는가" 를 가리킨다.
    func chainResultName(_ candidate: ChainCandidate) -> String {
        Self.dataName(candidate.toID, state.language)
    }

    /// 잔액 부족 시의 안내 — 필요한 금액을 보여준다.
    func chainPriceHint(_ candidate: ChainCandidate) -> String {
        l.chainNeedsTokens(TokenFormatter.compact(candidate.price))
    }

    /// 체인 승급 실행 — **토큰을 지불하고 도감 기록만 만든다.**
    ///
    /// ⚠️ 죠그레스와 같은 이유로 사다리 필드(`pathIDs`/`currentID`/`stageIndex`/`plannedPathIDs`)를
    /// 절대 건드리지 않는다. 결과 종(900/405)은 12개 라인 stages 어디에도 없어서 사다리에 얹으면
    /// `line.tree.node(withID:)` 가 nil 을 반환해 성장이 영구 정지한다.
    ///
    /// 지갑은 `spentTokens` 만 올린다 — `usedSinceInstall`(성장 미터·통계)은 읽기만 한다. 아머 §7
    /// 불변조건과 같은 원칙이라, 승급을 반복해도 진화 진행·오늘/주/월 통계가 전혀 움직이지 않는다.
    ///
    /// 출발 종 기록은 **소모되지 않는다**(§3: 도감은 재고가 아니라 기록이다).
    /// - Returns: 지불하고 새 기록을 만들었으면 true. 불가(기록 없음·잔액 부족·간선 없음)이거나
    ///   **이미 있는 기록**이면 false — 그 경우 토큰도 빠져나가지 않는다.
    @discardableResult
    func performChainPromotion(_ candidate: ChainCandidate) -> Bool {
        // 전부 **여기서 다시 판정한다** — `price`/`affordable` 은 뷰의 표시값이라 그걸 믿으면
        // 손으로 만든 후보가 0원 승급을 통과시킨다. 간선·기록·잔액 모두 원천에 재조회한다.
        let price = chainPromotionPrice
        guard DigimonData.chainEdges.contains(where: { $0.from == candidate.fromID && $0.to == candidate.toID }),
              hasJogressPartnerRecord(candidate.fromID),
              availableTokens >= price,
              recordJogressDexEntry(candidate.toID, prefix: "chain") else { return false }
        state.spentTokens += price      // 지출 원장만 — 성장 미터(usedSinceInstall)는 불변
        let name = Self.dataName(candidate.toID, state.language)
        justEvolvedTo = name
        fireCelebration(.evolve)
        eventUntil = clock().addingTimeInterval(4)
        notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(name))
        AppLog.write("chain promotion: \(candidate.fromID) -> \(candidate.toID) for \(price)")
        save()
        return true
    }

    // MARK: 상점 (재화 = 사용한 토큰)

    /// 상점에서 쓸 수 있는 토큰(재화) = 실사용 누적 − 상점 지출 누적. 성장 미터(usedSinceInstall)는
    /// 여기선 읽기만 — 구매는 spentTokens 만 올려 잔액을 깎는다(진화 진행·오늘/주/월 통계 무영향).
    var availableTokens: Int { max(0, state.usedSinceInstall - state.spentTokens) }

    /// 상점 판매 아이템 — shopPrice 있는 것만, 가격 저렴한 순. 동률(디지멘탈 8종)은
    /// `ShopEntry.sortRank`(=`ItemKind.allCases` 순서)로 전순서를 만들어 `sorted(by:)` 의
    /// stable 정렬 미보장에 기대지 않는다.
    var purchasableItems: [ItemKind] {
        ItemKind.allCases
            .filter { $0.shopPrice != nil }
            .sorted { (($0.shopPrice ?? 0), ShopEntry.item($0).sortRank)
                    < (($1.shopPrice ?? 0), ShopEntry.item($1).sortRank) }
    }

    /// 상점 표시 순서 — 판매 아이템 + 알 3종을 하나의 가격 오름차순 목록으로 병합.
    ///
    /// 알은 활성 디지몬이 없어도(알 상태) 목록에 남는다 — 구매는 `canBuyEgg` 의 `hasActive` 게이트가
    /// 막고, EggCard 가 비활성 버튼 + 사유 한 줄로 보여준다. 목록에서 통째로 빼면 "상점에 알이 원래
    /// 없다"로 읽혀서, 게이트는 유지하되 존재는 계속 보이게 한다.
    var shopEntries: [ShopEntry] {
        var entries: [ShopEntry] = purchasableItems.map { ShopEntry.item($0) }
        entries += FreshEgg.shopTiers.map { ShopEntry.egg($0) }
        // 가격 동률(디지멘탈 8종 + 기본 알)은 sortRank 로 전순서를 만든다 — stable 정렬 미보장 대응.
        // 규칙: 가격이 같으면 item 이 egg 보다 먼저, 그다음 각 kind 내부는 선언 순서(ShopEntry.sortRank 참고).
        return entries.sorted { (price(of: $0), $0.sortRank) < (price(of: $1), $1.sortRank) }
    }

    /// 구매 가능 — 잔액이 그 아이템 가격 이상(상점 미판매면 false). 활성/알 무관(재고는 미리 쌓아둘 수 있음).
    func canBuy(_ kind: ItemKind) -> Bool {
        guard let price = price(of: kind) else { return false }
        return availableTokens >= price
    }

    /// 아이템 1개 구매 — 지갑에서 price 차감, 인벤토리 +1. usedSinceInstall(성장·통계)·진화 진행엔
    /// 무영향(지출 원장만 증가). 잔액 부족/미판매면 no-op(false).
    @discardableResult
    func buy(_ kind: ItemKind) -> Bool {
        guard let price = price(of: kind), availableTokens >= price else { return false }
        state.spentTokens += price
        state.inventory[kind.rawValue, default: 0] += 1
        save()
        return true
    }

    // 사탕 전용 래퍼 — 기존 호출부/테스트 호환.
    var canBuyRareCandy: Bool { canBuy(.rareCandy) }
    @discardableResult
    func buyRareCandy() -> Bool { buy(.rareCandy) }

    // MARK: 알 (리롤 — 현재 디지몬 폐기, 도감·확률 무영향)

    /// 현재 알이 보증하는 등급 하한(UI 표시용). 활성 디지몬이 있으면 알이 없으므로 nil.
    var eggGuarantee: Rarity? { state.active == nil ? state.eggTier : nil }

    /// 알 구매 가능 — 폐기할 활성 디지몬이 있고 지갑이 그 티어 가격 이상일 때만.
    /// 알 상태에서도 살 수 있게 하는 안은 채택하지 않았다(기존 새 알과 게이트 통일) — 알끼리 교체하는
    /// 동작을 새로 만들지 않고, 상점의 알은 언제나 "지금 개체를 놓아주고 다시 뽑는다"는 한 가지 의미만 갖는다.
    /// 항목 자체는 알 상태에서도 상점에 남는다(shopEntries) — 이 게이트는 구매만 막는다.
    func canBuyEgg(_ tier: Rarity?) -> Bool {
        // 파는 티어인지 먼저 확인한다 — 만족 불가능한 보증(전설: capture_rate 로 표현 불가)을 사면
        // 두 롤 경로 모두 후보가 0개라 알이 영영 안 깨지고, 부화가 없으니 보증도 안 풀리며,
        // 새 알 구매는 `hasActive` 에 막혀 되돌릴 수단이 없다. 가격만 계산되면 값이 빠져나가므로
        // 판매 목록을 여기서 강제한다(호출부 하나가 실수하면 토큰이 통째로 사라진다).
        guard FreshEgg.shopTiers.contains(tier) else { return false }
        return hasActive && availableTokens >= price(of: .egg(tier))
    }

    /// 알 구매 — 현재 디지몬을 **방생하지 않고 보관함에 넣은 채** 처음부터 인큐베이션하는 새 알로.
    /// 지갑에서 가격 차감. graduate() 의 알-리셋을 미러링하되, 보관된 개체는 육성 상태
    /// (`pathIDs`/`stageIndex`/`usedAtStage`/`profile`/`armorID` 전부) 그대로 `state.stored` 로
    /// 옮겨진다 — 나중에 꺼내면 중단한 형태부터 이어서 키울 수 있다.
    ///
    /// **방생이 아니다.** (과거엔 `active` 를 `releasedDexEntry` 로 도감에 눕혔지만 이제 이 경로가
    /// 없다.) 방생은 `isReleased` 가 서서 그 종이 죠그레스 파트너
    /// 자격(`hasJogressPartnerRecord`)을 잃지만, 보관은 도감을 전혀 건드리지 않으므로 기존 졸업·
    /// 죠그레스 기록이 있던 종이면 그 자격이 그대로 유지된다. `collectedFinals`(최종체 완성·분기
    /// 가중)도 손대지 않는다 — 끝까지 키운 것도, 포기한 것도 아니다.
    ///
    /// 여기서 종을 롤하지 않는다 — 롤에는 네트워크가 필요해서 오프라인이면 토큰만 사라진다. 보증만
    /// 상태(`eggTier`)에 적고, 실제 롤은 프리패치/부화 경로가 그 보증을 읽어 수행한다.
    @discardableResult
    func buyEgg(_ tier: Rarity?) -> Bool {
        guard canBuyEgg(tier) else { return false }
        state.spentTokens += price(of: .egg(tier))
        if let a = state.active {
            state.stored.append(StoredMon(mon: a, storedAt: clock()))   // 보관 — 육성 상태 그대로 유지
        }
        state.active = nil            // 보관함으로 옮김(방생도 졸업도 아님 — collectedFinals 는 미변경)
        // 보관한 종의 도달분은 ownsSpecies 로 계속 소유 취급되므로 대표 선택은 유지된다. 손상 상태
        // 파일 등으로 정말 보유가 끊긴 경우만 자동 추적으로 복귀한다.
        state.reconcileRepresentativeSelection()
        activeGeneration += 1
        currentLine = nil
        state.eggUsage = 0            // 새 알은 처음부터 인큐베이션(재부화에 5M 필요)
        isHatchRetryDelayed = false
        state.eggTier = tier          // 등급 보증(nil = 보증 없음)
        setPendingHatch(nil, userPicked: false)    // 새 보증으로 처음부터 롤(활성 디지몬이 있는 동안엔 원래 비어 있다)
        // 맡겨 둔 보증도 여기서 되찾는다 — 방금 알이 생겼다. 새로 산 보증과 **동시에 유효할 수 있는
        // 유일한 창**이다(`canBuyEgg` 가 `hasActive` 를 요구하므로 파킹 상태에서도 알을 살 수 있다):
        // 더 높은 쪽만 남고 pre-roll 은 양방향 모두 버려진다(`restoreParkedEggGuarantee` doc).
        // 위 `setPendingHatch` **뒤에** 둔다 — 앞에 두면 되찾은 pre-roll 을 그 줄이 다시 지운다.
        state.restoreParkedEggGuarantee()
        prefetchedLineID = nil
        justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        AppLog.write("egg purchased: stored active, tier=\(tier?.rawValue ?? "none")")
        Task { await self.ensureEggPrefetch() }   // 다음 부화 예열
        save()
        return true
    }

    // 보증 없는 기본 알 래퍼 — 기존 호출부/테스트 호환.
    var canBuyFreshEgg: Bool { canBuyEgg(nil) }
    @discardableResult
    func buyFreshEgg() -> Bool { buyEgg(nil) }

    // MARK: 보관함 (알 구매로 보관한 개체를 꺼내 이어서 키운다)

    /// 보관함 목록 — 화면은 없지만(UI 는 다음 단계) store API 는 최신 보관순으로 노출한다.
    var storedMons: [StoredMon] { state.stored.sorted { $0.storedAt > $1.storedAt } }

    /// 지금 보관 개체를 꺼내 활성으로 되돌릴 수 있는가.
    ///
    /// **보관한 건 언제든 꺼낼 수 있다**(제품 결정, 2026-09-30). 남은 조건은 `isHatching` 하나다 —
    /// 부화 락 창에서 활성을 바꾸면 경합이 생긴다(함정 4). 부화는 기다리면 끝나므로 이 거절은
    /// 영구 차단이 아니다.
    ///
    /// 예전에 막았던 두 조건은 이제 **거절이 아니라 분기**다(`retrieveStored`):
    ///  - 활성 개체가 있으면 → 교체(현재 활성을 보관함에 넣고 꺼낸 개체를 세운다).
    ///  - 알 보증(`eggTier`)이 걸려 있으면 → 보증과 pre-roll 을 `parkedEggTier` 로 맡겨 둔다.
    ///    보증은 알에만 붙는 값이라 활성과 공존할 수 없어(`SaveTransfer.sanitized`) 그대로 두면
    ///    다음 로드에서 증발한다. 파킹해 두면 다시 알이 되는 순간 복원된다
    ///    (`CompanionState.restoreParkedEggGuarantee`).
    func canRetrieveStored(_ id: String) -> Bool {
        guard !isHatching else { return false }
        return state.stored.contains { $0.id == id }
    }

    /// 보관 개체를 꺼내 활성으로 되돌린다 — **중단한 형태부터** 이어서 키운다(사다리 필드 전부 보존).
    ///
    /// 후보 여부는 여기서 다시 판정한다(`canRetrieveStored`) — 참칭 호출자가 존재하지 않는 id 나
    /// 부적절한 시점에 꺼내기를 통과시키지 못하게 한다(`performJogress`/`pickHatchSpecies` 와 같은 태도).
    ///
    /// **두 분기다** — "빈 슬롯" 과 "교체" 는 치우는 대상이 다르다. 알을 버리는 처리
    /// (`eggUsage = 0`·pre-roll 폐기)는 **알이 있는 경로에서만** 의미가 있다. 교체 경로에는 알이
    /// 없으므로 그 줄을 같이 태우면 존재하지 않는 알의 진행분을 "버리는" 헛일이 된다.
    /// - Returns: 꺼냈으면 true. 부화 중이거나 id 가 없으면 false.
    @discardableResult
    func retrieveStored(id: String) -> Bool {
        guard canRetrieveStored(id) else { return false }
        guard let index = state.stored.firstIndex(where: { $0.id == id }) else { return false }
        let hadActive = state.active
        var mon = state.stored.remove(at: index).mon
        mon.pickedByUser = true   // 사용자가 직접 꺼낸 개체 — 프리패치 롤과 구분(다음 단계에서 소비).

        if let outgoing = hadActive {
            // ── 교체: 알이 아니라 활성 개체와 자리를 바꾼다. 보증·인큐베이션은 애초에 없다
            // (활성이 있으면 `eggTier` 는 `sanitized` 불변식으로 nil, `eggUsage` 는 이 개체 것이
            // 아니라 다음 알 것이라 손대지 않는다).
            state.stored.append(StoredMon(mon: outgoing, storedAt: clock()))   // 육성 상태 그대로(buyEgg 와 같은 방식)
        } else {
            // ── 빈 슬롯: 품고 있던 알을 포기하고 그 자리에 꺼낸 개체를 세운다.
            // 보증과 그 pre-roll 은 **버리지 않고 맡긴다** — 산 물건이라 꺼내기로 증발하면 안 된다.
            // 둘은 한 묶음으로 움직인다(pre-roll 만 남으면 무료 알이 프리미엄 결과를 받는다).
            parkEggGuarantee()
            setPendingHatch(nil, userPicked: false)   // 알이 사라졌으니 그 알의 pre-roll 은 더 이상 의미가 없다.
            state.eggUsage = 0   // 알을 포기했으니 그 알의 인큐베이션 진행분도 버린다(값은 buyEgg/graduate 와 같지만 이유는 반대 — 그쪽은 새 알을 주며 여는 0, 여기는 알을 버리며 잃는 0)
        }

        state.active = mon
        // 보관함 구성이 바뀌었다(교체는 넣고 빼므로) — 대표 종이 여전히 보유 범위 안인지 확인한다.
        state.reconcileRepresentativeSelection()
        activeGeneration += 1
        currentLine = nil
        prefetchedLineID = nil
        isHatchRetryDelayed = false
        justGraduated = nil; justEvolvedTo = nil; eventUntil = nil   // 이전 개체 기준 1회성 배너 — 꺼낸 개체 위에 뜨면 안 된다(buyEgg 와 동일)
        displayState = .idle
        AppLog.write("stored mon retrieved: base=\(mon.baseID) stage=\(mon.stageIndex) swapped=\(hadActive != nil) parked=\(state.parkedEggTier?.rawValue ?? "none")")
        save()
        Task { await self.loadCurrentLine() }
        if detailProvider != nil { Task { await self.loadDigimonDetails(speciesID: mon.currentID) } }
        return true
    }

    /// 품고 있던 알의 보증과 pre-roll 을 파킹 필드로 옮긴다 — 꺼내기가 알을 치우기 **전에** 부른다.
    ///
    /// 순서가 생명이다: `setPendingHatch(nil, ...)` 뒤에 부르면 맡길 pre-roll 이 이미 지워져 있다.
    /// 보증이 없으면 맡길 것도 없다(pre-roll 만 맡기면 무료 알이 그 결과를 받는다 —
    /// `CompanionState.restoreParkedEggGuarantee` 와 `SaveTransfer.sanitized` 의 같은 누수).
    ///
    /// **전제: 여기 도달할 때 파킹 자리는 항상 비어 있다.** 그래서 병합 없이 덮어쓴다(복원 쪽이
    /// `sortRank` 로 병합하는 것과 비대칭인 이유). 근거는 `active` 를 nil 로 만드는 지점이
    /// `graduate()`/`buyEgg()` 둘뿐이고 **둘 다 직후에 `restoreParkedEggGuarantee()` 로 파킹을
    /// 비운다**는 것이다(`sanitized` 도 `active == nil` 이면 비운다). 이 함수는
    /// `active == nil && eggTier != nil` 에서만 실행되므로 삼중 조합이 성립하지 않는다.
    ///
    /// ⚠️ **`active = nil` 쓰기 지점이 하나라도 늘어나면**(복원을 부르지 않는 경로로) 이 전제가
    /// 깨져 두 번째 파킹이 첫 번째를 조용히 덮어쓴다 — 산 보증 유실이다. 그때는 여기에도
    /// `restoreParkedEggGuarantee` 와 같은 `sortRank` 병합을 두어야 한다. 지금 그 병합을 미리
    /// 넣지 않는 이유는 도달 불가한 분기에는 테스트를 세울 수 없어 회귀를 못 지키기 때문이다.
    private func parkEggGuarantee() {
        guard let tier = state.eggTier else { return }
        state.parkedEggTier = tier
        state.parkedPendingHatchID = state.pendingHatchID
        state.parkedPendingHatchIsUserPick = state.pendingHatchIsUserPick
        state.eggTier = nil   // 활성과 공존할 수 없으므로 즉시 비운다(맡긴 값이 진짜 소유자다)
    }

    /// 보관 개체를 꺼낼 수 없는 **이유** — 꺼낼 수 있으면 nil. `canRetrieveStored` 를 그대로 뒤집어
    /// 화면에 말해 준다.
    ///
    /// 뷰가 `isHatching` 을 직접 읽어 문구를 고르면 게이트와 문구가 두 곳에 갈라져 한쪽만 고쳐진다
    /// (`jogressPartnerHint` 와 같은 태도 — 판정과 그 설명은 둘 다 store 에 있다).
    ///
    /// 조건이 하나뿐인 건 설계가 바뀐 결과다: 활성 개체가 있는 상태와 보증 알을 품은 상태는 이제
    /// **차단이 아니라 동작**이다(교체 / 보증 파킹 — `retrieveStored`). 그 두 문구를 여기 남겨 두면
    /// 열려 있는 게이트에 차단 안내가 뜬다.
    ///
    /// id 가 없는 경우는 문구가 없다(nil) — 목록에 뜬 행은 항상 존재하는 id 라 도달하지 않고,
    /// 안내할 사용자 행동도 없다.
    func storedRetrieveBlockReason(_ id: String) -> String? {
        guard state.stored.contains(where: { $0.id == id }) else { return nil }
        if isHatching { return l.storageBlockedHatching }
        return nil
    }

    /// 꺼내기 버튼에 쓸 문구 — 활성 개체가 있으면 "자리 바꾸기"다.
    ///
    /// 확인 단계가 없다(제품 결정: 즉시 교체). 그래서 이 라벨이 **지금 키우던 개체가 보관함으로
    /// 들어간다**는 사실을 누르기 전에 알려 주는 유일한 수단이다 — 두 동작에 같은 "꺼내기"를 쓰면
    /// 사용자는 누른 뒤에야 안다. 방생처럼 확인을 한 단계 두지 않는 대신 라벨로 구분한다.
    ///
    /// 뷰가 `hasActive` 를 직접 읽어 고르지 않는다(`storedRetrieveBlockReason` 과 같은 태도 —
    /// 판정과 그 문구는 둘 다 store 에 있다).
    var storageRetrieveLabel: String { hasActive ? l.storageSwap : l.storageRetrieve }

    /// 보관함 진입점을 그릴지 — 보관 개체가 하나도 없으면 숨긴다(`canPickHatchSpecies` 선례:
    /// 후보가 0개인 화면으로 보내는 죽은 버튼을 두지 않는다).
    var canOpenStorage: Bool { !state.stored.isEmpty }

    /// 보관 개체를 방생한다 — **도감에 기록을 남기고** 보관함에서 제거한다.
    ///
    /// `graduate()` 의 dex append 를 베끼지 않는다. 다른 점이 셋이다:
    ///  - `collectedFinals` 를 건드리지 않는다. 그건 "최종체를 완성했다"는 졸업 기록이고 분기
    ///    가중에 쓰인다 — 중간에 포기한 개체가 거기 들어가면 졸업 기록이 오염된다.
    ///  - `releasedAt` 을 세운다. 그래서 이 기록은 `hasJogressPartnerRecord` 의 `!isReleased`
    ///    게이트에 자동으로 걸린다 — 방생이 죠그레스 파트너 자격을 **새로 만들지 않는다**.
    ///    (보관도 자격을 만들지 않았다. 두 경로가 같은 결론에 서로 다른 이유로 도달한다:
    ///    보관은 도감을 안 건드려서, 방생은 도감 기록이 방생분이라서.)
    ///  - `chainOrder` 는 **도달분**(`prefix(stageIndex + 1)`)이다. `plannedPathIDs` 는 미도달
    ///    단계를 포함하므로 쓰면 진화하지 않은 종이 도감에 생긴다(`dexSpecies` 가 stored/active 를
    ///    접는 규칙과 같다).
    ///
    /// 종 **보유**는 방생 전후로 바뀌지 않는다: 같은 도달분이 `state.stored` 경로에서 `state.dex`
    /// 경로로 옮겨 갈 뿐이고 `ownsSpecies` 는 `isReleased` 를 보지 않는다. 그래서
    /// `reconcileRepresentativeSelection()` 을 부르지 않는다 — 부를 이유가 없는 호출은 "여기서
    /// 보유가 끊길 수 있다"는 잘못된 신호를 남긴다.
    ///
    /// 이름은 `DigimonData` 에서 심는다(`recordArmorDexEntry` 와 같은 이유). 보관 개체엔
    /// `currentLine` 이 없어서 `graduate()` 처럼 라인에서 뜰 수 없고, 비워 두면
    /// `needsNamesRefresh` 가 영영 true 라 `backfillMissingDexNames` 가 매번 라인을 조회한다.
    /// - Returns: 방생했으면 true. 그 id 의 보관 개체가 없으면 false(`retrieveStored` 와 같은 방어).
    @discardableResult
    func releaseStored(id: String) -> Bool {
        guard let index = state.stored.firstIndex(where: { $0.id == id }) else { return false }
        let mon = state.stored.remove(at: index).mon
        let reached = Array(mon.pathIDs.prefix(mon.stageIndex + 1))
        let now = clock()
        state.dex.append(DexEntry(
            id: mon.profile?.instanceID ?? UUID().uuidString,
            baseID: mon.baseID,
            // 사다리 끝 — 표시 축(`displayID`, 아머 오버레이)이 아니다. 방생 기록도 사다리 기준이다
            // (`EggCard` 의 확인 문구가 `ladderName` 을 쓰는 것과 같은 이유).
            finalID: mon.currentID,
            chainOrder: reached,
            rarity: mon.rarity,
            caughtAt: now,
            profile: mon.profile,
            names: Dictionary(uniqueKeysWithValues:
                reached.compactMap { id in DigimonData.name(for: id).map { (id, $0.localizedNames) } }),
            releasedAt: now))
        AppLog.write("stored mon released: base=\(mon.baseID) stage=\(mon.stageIndex)")
        save()
        return true
    }

    /// 지급 판정(순수·엣지 트리거) — 한도 창이 100% 를 새로 넘어선 순간에만 지급.
    /// - 100% 미만 → 맵에서 제거(재무장). resets_at 등 휘발 필드는 key 에 없다(안정 식별자만).
    /// - 이미 지급한 창(tier≥1)은 재지급 안 함. session=1개·weekly=weeklyGrant.
    /// - 부수효과(인벤토리·알림)와 분리해 xctest 가능. (evaluateLimitAlerts 자매)
    static func evaluateCandyGrants(
        windows: [CandyWindow], grantTier: inout [String: Int]
    ) -> [CandyGrant] {
        var grants: [CandyGrant] = []
        for w in windows {
            guard w.utilization >= 100 else { grantTier[w.key] = nil; continue }
            let previous = grantTier[w.key] ?? 0
            guard previous < 1 else { continue }
            grantTier[w.key] = 1
            let count = w.kind == .weekly ? RareCandy.weeklyGrant : 1
            grants.append(CandyGrant(windowKey: w.key, windowName: w.name, count: count))
        }
        return grants
    }

    /// 한도 창 상태로부터 사탕 지급(엣지·영속). AppDelegate 가 매 refresh 완료 시(한도 로드 후) 호출.
    /// - 첫 실행: 현재 100% 창을 지급 없이 tier 시드만 → 이후 "새로 넘어서는" 순간부터 지급(소급 차단).
    /// - limitsReady=false(한도 미로딩)면 시드/지급 모두 대기(다음 refresh 에 재시도).
    func grantCandies(from windows: [CandyWindow], limitsReady: Bool) {
        guard limitsReady else { return }
        if !state.candyFeatureSeeded {
            // 한계(수용): 첫 refresh 에 한 프로바이더 한도만 로드되면 그 프로바이더 창만 시드된다.
            // 이후 다른 프로바이더가 이미 100%인 채 로드되면 소급 지급될 수 있으나, 1회·소수 캔디라
            // 1인 로컬에서 무시(YAGNI). refresh() 는 전 프로바이더 fetch 를 await 후 onRefresh 하므로
            // 정상 경로(둘 다 성공)에선 원자적 시드다.
            for w in windows where w.utilization >= 100 { state.candyGrantTier[w.key] = 1 }
            state.candyFeatureSeeded = true
            save()
            return
        }
        let before = state.candyGrantTier
        let grants = Self.evaluateCandyGrants(windows: windows, grantTier: &state.candyGrantTier)
        for g in grants {
            state.inventory[ItemKind.rareCandy.rawValue, default: 0] += g.count
            // 지급 자체는 알림 여부와 무관(상태 변경). 알림은 "왜 받는지"(그 창 한도를 다 채운 수고) 명시.
            notifyCompanionEvent(l.notifCandyTitle(item: l.itemName(.rareCandy), count: g.count),
                                 l.notifCandyBody(window: g.windowName))
        }
        // 지급이 없어도 재무장(창이 100%→아래로 내려가며 grantTier 에서 제거)은 영속해야 한다 —
        // 안 하면 재시작 시 stale tier=1 로 다음 100% 도달이 "이미 지급"으로 오판돼 지급 누락(회귀).
        if !grants.isEmpty || state.candyGrantTier != before { save() }
    }

    /// companion 이벤트 시스템 알림(.app + 토글 ON 일 때만). 한도 알림과 독립.
    private var notifSeq = 0
    private func notifyCompanionEvent(_ title: String, _ body: String) {
        guard AppEnv.isBundledApp else { return }
        guard UserDefaults.standard.object(forKey: "companionNotifications") as? Bool ?? true else { return }
        notifSeq += 1
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "companion-event-\(notifSeq)", content: content, trigger: nil))
    }

    // MARK: 배치할 디지몬 직접 선택 (알 상태에서 유아기 종 지정)

    /// 선택 화면 한 줄 — **도감에 등록된 유아기(base) 종** 하나.
    /// 보증 등급·이름 해석까지 store 가 끝낸 값만 담는다. 뷰가 판정을 하면 XCTest 가 SwiftUI `body`
    /// 안을 볼 수 없어 게이트가 테스트 밖으로 새어나간다(`jogressCandidates` 주석과 같은 이유).
    struct BabyPick: Sendable, Identifiable, Equatable {
        /// 라인의 `stages[0].id` — 곧 `DigiLine.baseID` 다. 종 번호 리터럴은 어디에도 없다.
        let baseID: Int
        /// 이 라인이 부화했을 때의 등급(`DigiLine.rarity`). 보증 알 필터가 이 값으로 걸린다.
        let rarity: Rarity
        /// 현재 언어 이름 — 데이터셋에 없는 id 면 `#id`(🥚 로 떨어지는 조합을 화면에서 드러낸다).
        let name: String

        var id: Int { baseID }
    }

    /// 지금 직접 골라 부화시킬 수 있는 유아기 종 전부 — 없으면 빈 배열(UI 는 진입점을 아예 숨긴다).
    ///
    /// 유도 규칙:
    ///  ① 후보 집합은 **데이터에서** 온다 — `DigimonData.lines` 의 `baseID`(= `stages[0].id`).
    ///     하드코딩 배열을 두면 52종 데이터와 어긋나도 에러 없이 알 이모지로 떨어진다.
    ///  ② **도감에 등록된 종만**(`state.ownsSpecies`). 알 상태에서는 활성 개체가 없으므로 이 판정은
    ///     졸업·방생·죠그레스 기록의 `chainOrder` 로 환원된다 — "한 번 키워 본 유아기" 가 조건이다.
    ///  ③ **보증 등급(`state.eggTier`) 미달 라인은 후보에서 뺀다.** `hatchCore` 의 마지막 관문과
    ///     **같은 비교**(`rarity.sortRank >= tier.sortRank`)라, 선택된 종이 그 관문에 걸려 버려지는
    ///     일이 구조적으로 불가능하다 — 보증이 무시되지도, 토큰이 낭비되지도 않는다(제약 6).
    ///
    /// 정렬은 도감 번호 오름차순 — `DigimonData.lines` 는 JSON 순서라 화면 순서를 여기서 고정한다.
    var babyPicks: [BabyPick] {
        guard state.active == nil else { return [] }   // 알 상태에서만 의미가 있다(제약 7)
        let tier = state.eggTier
        return DigimonData.lines.compactMap { line -> BabyPick? in
            let baseID = line.baseID
            guard state.ownsSpecies(baseID) else { return nil }
            if let tier, line.rarity.sortRank < tier.sortRank { return nil }
            return BabyPick(baseID: baseID, rarity: line.rarity,
                            name: Self.dataName(baseID, state.language))
        }
        .sorted { $0.baseID < $1.baseID }
    }

    /// 직접 선택 진입점을 그릴 조건 — 알 상태 + 고를 수 있는 종이 하나라도 있을 때.
    /// 후보가 없는 신규 플레이어에게 빈 화면으로 가는 버튼을 보이지 않는다.
    var canPickHatchSpecies: Bool { !babyPicks.isEmpty }

    /// 지금 알이 품고 있는(= 다음에 깨어날) 종 — 프리패치 롤이든 사용자 선택이든 같은 필드다.
    /// 활성 개체가 있으면 알이 없으므로 nil(`eggGuarantee` 와 같은 태도).
    var pendingHatchSpeciesID: Int? { state.active == nil ? state.pendingHatchID : nil }

    /// 사용자가 **직접 고른 것으로 보이는** 종 — 화면에 예고해도 되는 유일한 `pendingHatchID` 다.
    ///
    /// `pendingHatchIsUserPick` 이 진짜 판정이다(`pickHatchSpecies` 만 true 로 세운다). 후보
    /// (`babyPicks`)에 있는지도 함께 본다 — 고른 뒤 그 종이 후보에서 빠지는 창(등급 기준이 바뀌는 등)을
    /// 막는 방어층으로, 플래그만으로는 못 잡는 경우다. 즉 "사용자가 골랐다 **그리고** 여전히 후보"일
    /// 때만 노출한다.
    var pickedHatchBaseID: Int? {
        guard state.pendingHatchIsUserPick,
              let id = pendingHatchSpeciesID,
              babyPicks.contains(where: { $0.baseID == id }) else { return nil }
        return id
    }

    /// 위 선택의 현재 언어 이름 — 알 카드의 "무엇이 깨어날지" 한 줄.
    var pickedHatchName: String? {
        pickedHatchBaseID.map { Self.dataName($0, state.language) }
    }

    /// `pendingHatchID` 를 세우거나 비우는 모든 곳이 반드시 거치는 단일 지점 — 한 write 사이트라도
    /// 이 함수를 건너뛰면 `pendingHatchIsUserPick` 이 stale true 로 남아 프리패치 롤을 "사용자가
    /// 골랐다"고 예고하게 된다(지금 고치는 버그보다 나쁘다). `save()` 는 호출자 책임으로 남긴다 —
    /// 기존 호출부가 이미 각자 적절한 시점에 저장한다.
    private func setPendingHatch(_ id: Int?, userPicked: Bool) {
        state.pendingHatchID = id
        state.pendingHatchIsUserPick = userPicked
    }

    /// 부화할 유아기 종을 직접 지정한다 — **랜덤 롤 대신 이 종으로 부화**한다.
    ///
    /// 별도 부화 경로를 만들지 않는다: 미리 롤해 둔 종을 담는 기존 필드(`pendingHatchID`)에 선택을
    /// 적고, 실제 부화는 그것을 읽는 `hatchIfNeeded()` → `hatchCore` 가 한다. 그래서
    ///  - `isHatching` 락과 `activeGeneration` 세대 가드를 그대로 통과하고(제약 3),
    ///  - 5M 인큐베이션 임계도 유지된다 — 알이 아직 안 찼으면 선택만 기억되고 임계 도달 시 그 종으로
    ///    깨어난다(`hatchIfNeeded` 의 자체 가드),
    ///  - 세이브 스키마가 그대로다(`pendingHatchID` 는 이미 영속 필드다).
    ///
    /// **방생이 아니다** — `releasedDexEntry`/`isReleased`/`isArmored` 는 어디에도 쓰지 않는다(제약 5).
    /// 활성 개체를 놓아주는 일도 없다: 활성 개체가 있으면 아래 가드가 거절한다.
    ///
    /// 후보 여부는 **여기서 다시 판정한다** — 넘어온 id 를 믿으면 참칭 호출자가 도감에 없는 종이나
    /// 보증 미달 라인을 통과시킨다(`performJogress` 와 같은 태도: 판정 권한은 store 에 있다).
    /// - Returns: 선택이 반영됐으면 true. 활성 개체가 있거나 부화가 진행 중이거나 후보가 아니면 false.
    @discardableResult
    func pickHatchSpecies(baseID: Int) -> Bool {
        // 활성 개체가 있으면 선택할 알이 없다. 여기서 `state.active` 를 비우면 그게 곧 방생이다.
        guard state.active == nil else { return false }
        // 진행 중인 부화는 `baseID` 를 **인자로** 들고 이미 await 에 들어가 있어 `pendingHatchID` 를
        // 고쳐도 되돌려지지 않는다 — 조용히 무시되는 대신 거절해서 UI 가 사실을 말할 수 있게 한다.
        guard !isHatching else { return false }
        guard babyPicks.contains(where: { $0.baseID == baseID }) else { return false }
        // 같은 종을 다시 고르면 상태는 그대로 두되 **부화·예열 재시도는 반드시 건다.** 직전 시도가
        // 실패했을 수 있고(`isHatchRetryDelayed`, `pendingHatchID` 는 남아 있다), 그 경우 여기서
        // 그냥 true 만 돌려주면 버튼이 성공을 보고하고 화면을 닫은 뒤 아무 일도 일어나지 않는다
        // (다음 update 틱까지). 상태 변경이 없는 것과 아무것도 안 하는 것은 다르다.
        //
        // `isRepeat` 은 id 만 비교한다 — 프리패치가 먼저 이 종을 롤해 뒀다가(플래그 false) 사용자가
        // 같은 종을 고르는 경우가 있어(도감에 이미 있는 유아기가 우연히 롤될 수 있다), id 가 같다고
        // 사용자 선택 표시를 건너뛰면 그 경로만 영구히 예고가 안 뜬다. 그래서 마커는 `isRepeat` 과
        // 무관하게 매번 세우고, 예열 무효화·로그만 "진짜로 값이 바뀐" 경우로 좁힌다.
        let isRepeat = state.pendingHatchID == baseID
        setPendingHatch(baseID, userPicked: true)
        if !isRepeat {
            prefetchedLineID = nil    // 예열해 둔 라인은 이전 종 것이다 — 다음 프리패치가 새로 데운다
            AppLog.write("egg pick: base=\(baseID) tier=\(state.eggTier?.rawValue ?? "none")")
        }
        isHatchRetryDelayed = false   // 이전 롤 실패 문구가 남아 선택이 먹히지 않은 것처럼 보이지 않게
        save()
        // 임계가 이미 찼으면 즉시 부화, 아니면 프리패치가 라인·스프라이트를 데운다. 두 경로 모두
        // 자체 가드를 가지고 있어 여기서 조건을 다시 세우지 않는다.
        //
        // **예열이 한 틱 비는 창이 있다**(정합성 결함은 아님): 구 롤의 `provider.line()` 이 아직
        // in-flight 면 이 Task 의 `ensureEggPrefetch` 는 `guard !prefetchInFlight` 에서 즉시 반환하고,
        // 복귀한 구 프리패치는 `pendingHatchID` 재확인에 걸려 반환한다 — 아무도 새 선택 종을 데우지
        // 않는다. 다음 `update` 틱에 채워진다. 부화 자체는 `hatchCore` 가 직접 fetch 하므로 안전하고,
        // 비용은 "부화 순간 네트워크 0" 목표를 그 창에서만 놓치는 것뿐이다.
        Task { await self.hatchIfNeeded(); await self.ensureEggPrefetch() }
        return true
    }

    // MARK: 부화

    func hatchIfNeeded() async {
        guard state.active == nil, !isHatching, state.eggUsage >= eggHatchThreshold else { return }
        // 프리패치가 "종 롤 중"(pending 미확정)일 때만 대기 — 이중 rng 소비 방지.
        // pending 확정 후의 예열(라인/스프라이트)과는 동시 진행해도 안전하다.
        guard state.pendingHatchID != nil || !prefetchInFlight else { return }
        // isHatching 을 롤~부화 전체에 defer 로 잠근다. 과거엔 chooseBase 후 isHatching 을 잠깐
        // 내렸다가(hatch 자체 가드 통과용) hatch 를 호출해, 그 await 창에서 다른 update 틱이
        // 두 번째 종을 롤하는 경합이 있었다. hatchCore 는 isHatching 을 재검사하지 않으므로
        // 여기서 소유한 락 하나로 롤·부화가 원자적으로 보호된다.
        let generation = activeGeneration
        isHatching = true
        defer { isHatching = false }
        // 프리패칭된 종이 있으면 그대로 사용(라인·스프라이트 예열됨 → 딜레이 ~0), 없으면 지금 롤.
        let base: Int?
        if let pending = state.pendingHatchID {
            base = pending
        } else {
            base = await chooseBase()
        }
        guard isCurrentReadyEgg(generation: generation) else {
            AppLog.write("hatch: discarded before result handling — subject replaced during species roll")
            kickLineLoadIfNeeded()
            return
        }
        guard let base else {
            isHatchRetryDelayed = true
            return
        }
        await hatchCore(baseID: base, generation: generation)
    }

    /// 부화가 폐기된 뒤 남은 개체(대개 방금 불러온 개체)의 진화 라인을 다시 로드한다.
    /// `loadCurrentLine` 은 `!isHatching` 을 요구하므로 부화 중에 걸린 로드는 조용히 실패한다 —
    /// 아무도 재시도하지 않으면 다음 update 틱(기본 120초)까지 이름이 "Token Egg" 로 남는다.
    /// Task 본문은 현재 동기 실행(= defer 로 isHatching 해제)이 끝난 뒤 돌므로 락이 이미 풀려 있다.
    private func kickLineLoadIfNeeded() {
        guard state.active != nil, currentLine == nil else { return }
        Task { await loadCurrentLine() }
    }

    // MARK: 알 프리패칭

    private var prefetchInFlight = false
    private var prefetchedLineID: Int?   // 라인·스프라이트 예열 완료한 종(세션 메모리)

    private func isCurrentEgg(generation: Int) -> Bool {
        activeGeneration == generation && state.active == nil
    }

    private func isCurrentReadyEgg(generation: Int) -> Bool {
        isCurrentEgg(generation: generation) && state.eggUsage >= eggHatchThreshold
    }

    private func markHatchRetryDelayedIfReady(generation: Int) {
        guard isCurrentReadyEgg(generation: generation) else { return }
        isHatchRetryDelayed = true
    }

    private func finishEggPrefetch(generation: Int, shouldHatch: Bool) {
        prefetchInFlight = false
        guard shouldHatch, isCurrentReadyEgg(generation: generation) else { return }
        Task { await self.hatchIfNeeded() }
    }

    /// 알 상태에서 부화를 미리 준비 — ① 종 pre-roll(pendingHatchID, 영속) ② 진화 라인
    /// fetch(provider 캐시 적재) ③ 스프라이트 예열(정적+애니메이션).
    /// 전부 성공하면 부화 순간 네트워크 0. 실패 지점부터 다음 update 틱에 이어서 재시도.
    private func ensureEggPrefetch() async {
        guard state.active == nil, !isHatching, !prefetchInFlight else { return }
        let generation = activeGeneration
        var shouldHatch = false
        prefetchInFlight = true
        defer { finishEggPrefetch(generation: generation, shouldHatch: shouldHatch) }

        if state.pendingHatchID == nil {
            let selected = await chooseBase()
            // await 사이에 부화가 끝났거나(active != nil) 상태가 통째로 교체됐으면(세이브 불러오기)
            // 이 롤을 버린다 — 안 그러면 불러온 알의 pre-roll 을 남의 롤로 덮어쓴다.
            guard isCurrentEgg(generation: generation) else { return }
            // 롤이 nil 로 끝났을 때(인덱스 비었거나 보증으로 후보가 다 걸림): 이 롤이 도는 동안
            // 사용자가 종을 골랐으면 **실패가 아니다** — 선택은 `pendingHatchID` 에 정상적으로
            // 남아 있다. 그때 지연 플래그를 세우면 `pickHatchSpecies` 가 방금 내린 것을 되세워
            // UI 에 "부화 지연" 문구가 뜨고, 사용자에겐 선택이 안 먹힌 것으로 보인다. 게다가
            // 여기서 return 하면 선택 종의 라인·스프라이트 예열까지 건너뛴다.
            // 그래서 선택이 들어와 있으면 플래그를 세우지 않고 아래 예열로 흘려보낸다.
            if selected == nil, state.pendingHatchID == nil {
                markHatchRetryDelayedIfReady(generation: generation)
                return
            }
            // `isCurrentEgg` 로는 **선택 부화**를 못 잡는다 — `pickHatchSpecies` 는 알을 알로 두고
            // `activeGeneration` 도 올리지 않으므로 세대·알 판정이 둘 다 그대로 통과한다. 이 롤이
            // 도는 동안 사용자가 종을 골랐으면 그 선택이 여기서 조용히 랜덤 종으로 덮인다.
            // 아래 await 들이 이미 쓰는 것과 같은 재확인 방식으로 막고, 예열은 계속 진행한다
            // (선택된 종의 라인·스프라이트를 데우는 게 맞다).
            //
            // 이 재확인이 "이미 값이 있으면 다시 롤하지 않는다"로도 읽히지만 낡은 롤을 고정하지는
            // 않는다: 보증을 **올리는** 유일한 경로(`buyEgg`)가 `eggTier` 를 적는 바로 다음 줄에서
            // 이 필드를 nil 로 비우고(`testPurchaseStartsFromCleanRollState`), 애초에 활성 개체와
            // pre-roll 은 공존하지 않는다(프리패치는 알 상태 전용, `hatchIfNeeded` 가 부화 직전 비움)
            // — `canBuyEgg` 는 `hasActive` 를 요구하므로 구매는 항상 빈 롤에서 출발한다. 즉
            // "미달 종이 미리 롤된 뒤 보증이 붙는" 순서가 없어서 보증이 헛도는 경우가 없다.
            if let id = selected, state.pendingHatchID == nil {
                setPendingHatch(id, userPicked: false)
                save()
            }
        }
        guard let id = state.pendingHatchID else { return }
        if prefetchedLineID == id {
            isHatchRetryDelayed = false
            shouldHatch = true
            return
        }
        let line: EvoLine
        do {
            line = try await provider.line(baseSpeciesID: id)
        } catch {
            markHatchRetryDelayedIfReady(generation: generation)
            return
        }
        guard isCurrentEgg(generation: generation), state.pendingHatchID == id else { return }
        // 스프라이트 예열 — 부화 직후 보일 base 정적 스프라이트.
        // .app 번들에서만(단위 테스트가 실네트워크에 닿지 않도록 — 알림과 동일한 게이트).
        if AppEnv.isBundledApp {
            _ = await SpriteStore.shared.data(filenames: SpriteStore.filenames(for: line.baseID))
        }
        guard isCurrentEgg(generation: generation), state.pendingHatchID == id else { return }
        prefetchedLineID = id
        isHatchRetryDelayed = false
        shouldHatch = true
    }

    func hatch(baseID: Int) async {
        guard !isHatching else { return }
        let generation = activeGeneration
        isHatching = true
        defer { isHatching = false }
        await hatchCore(baseID: baseID, generation: generation)
    }

    /// 실제 부화 로직 — isHatching 락은 호출자(hatch / hatchIfNeeded)가 소유·해제한다.
    private func hatchCore(baseID: Int, generation: Int) async {
        let line: EvoLine
        do {
            line = try await provider.line(baseSpeciesID: baseID)
        } catch {
            markHatchRetryDelayedIfReady(generation: generation)
            AppLog.write("hatch: line fetch failed for base \(baseID) — egg kept, retry next tick")
            return
        }
        // 라인 fetch 창(네트워크) 동안 활성 개체가 교체됐으면 이 부화 결과를 폐기한다. 세이브 불러오기가
        // 그 창에 들어오면, 여기서 멈추지 않는 한 갓 부화한 개체가 방금 불러온 개체를 덮어쓴다.
        // (loadCurrentLine 과 같은 세대 가드 — isHatching 락은 같은 앱 내 중복 부화만 막는다.)
        guard activeGeneration == generation else {
            AppLog.write("hatch: discarded — active subject replaced during line fetch")
            kickLineLoadIfNeeded()
            return
        }
        // 산 보증을 지키는 마지막 관문 — `line.rarity` 를 직접 보는 건 여기뿐이다. 앞단의 두 경로는
        // 등급을 **간접적으로** 판정한다: `chooseBase` 는 `captureRate`(등급에서 유도된 값)로 후보를
        // 좁히고, `pickHatchSpecies` 는 `babyPicks` 가 이미 걸러낸 목록에 의존한다. 유도값 경계나
        // 목록이 어긋나면 낮은 등급이 여기까지 올 수 있으므로, 그냥 내주지 말고 알을 유지한 채
        // pre-roll 만 버려 다음 틱에 다시 뽑는다 — 사용자는 산 보증을 계속 들고 있는다.
        // `babyPicks` ③ 은 같은 비교를 쓰지만 등급의 **출처**가 다르다 — 거기선 `DigimonData.lines`,
        // 여기선 provider 가 돌려준 `line.rarity` 다. 기본 provider(`DigimonLineProvider`)가 둘을
        // 그대로 이어주므로(같은 파일 :37) 현재는 선택 부화가 여기 걸릴 수 없지만, 등급을 다르게
        // 돌려주는 provider 를 주입하면 이 관문이 선택 부화도 걸러낸다 — 그게 의도된 동작이다.
        if let tier = state.eggTier, line.rarity.sortRank < tier.sortRank {
            AppLog.write("hatch: rolled \(line.rarity) below guaranteed \(tier) — discarded, re-roll next tick")
            setPendingHatch(nil, userPicked: false)
            prefetchedLineID = nil
            markHatchRetryDelayedIfReady(generation: generation)
            save()
            return
        }
        // `baseID` 가 pending 과 일치할 때만 그 선택을 "소비"한다 — `hatch(baseID:)` 는 인자를 직접
        // 받을 수 있어(경합 등으로) pending 과 다른 종을 부화시킬 수 있다. 그 경우 갓 태어난 개체에
        // 엉뚱한 종의 사용자 선택 표시를 붙이면 안 되므로 false 로 둔다.
        // 비교는 **fetch 해 온 `line.baseID`** 로 한다 — 인자 `baseID` 가 아니다. 소비되는 개체가
        // `MonState(baseID: line.baseID, ...)` 로 만들어지므로, provider 가 요청과 다른 종의 라인을
        // 돌려주면 "고른 종"과 "태어난 종"이 갈라지고 사용자가 고르지 않은 종에 선택 표시가 찍힌다.
        // 바로 위 등급 관문(:1882)이 `line.rarity` 를 보는 것과 같은 이유다(유도값이 어긋날 수 있다).
        let wasUserPicked = state.pendingHatchID == line.baseID && state.pendingHatchIsUserPick
        setPendingHatch(nil, userPicked: false)
        prefetchedLineID = nil
        currentLine = line
        isHatchRetryDelayed = false
        // 부화 임계 초과분은 부화체 성장에 이월(낭비 없음).
        let overflow = max(0, state.eggUsage - eggHatchThreshold)
        state.eggUsage = 0
        state.eggTier = nil   // 보증은 이 부화로 소비된다(다음 알은 다시 무보증)
        let evolutionPlan = makeEvolutionPlan(from: line.tree, baseID: line.baseID)
        var profile = DigimonProfile.generate(seed: rng.next())
        if let details = digimonDetailsByID[line.baseID] { profile.enrich(with: details) }
        let hasGrowthBoost = state.hasCollectedFinal(forBaseID: line.baseID)
        activeGeneration += 1
        state.active = MonState(baseID: line.baseID, pathIDs: [line.baseID], plannedPathIDs: evolutionPlan,
                                stageIndex: 0, usedAtStage: 0, rarity: line.rarity, totalForms: evolutionPlan.count,
                                profile: profile, hasGrowthBoost: hasGrowthBoost,
                                pickedByUser: wasUserPicked)
        AppLog.write("hatch: base=\(line.baseID) rarity=\(line.rarity) forms=\(evolutionPlan.count) boost=\(hasGrowthBoost)")
        let name = line.localizedName(line.baseID, state.language)
        notifyCompanionEvent(l.notifHatchTitle, l.notifHatchBody(name))
        justEvolvedTo = nil        // 새 부화는 "성장" 문구(진화 아님) — 직전 진화명이 남아 표시되지 않게
        displayState = .levelUp
        eventUntil = clock().addingTimeInterval(4)
        if overflow > 0 { applyUsage(overflow) }   // 이월분 즉시 반영(필요 시 진화까지)
        if state.active != nil { fireCelebration(.hatch) }
        save()
        if detailProvider != nil { Task { await self.loadDigimonDetails(speciesID: line.baseID) } }
    }

    private func loadCurrentLine() async {
        guard let a = state.active, currentLine == nil, !isHatching else { return }
        let generation = activeGeneration
        isHatching = true
        defer { isHatching = false }
        let line: EvoLine
        do {
            line = try await provider.line(baseSpeciesID: a.baseID)
        } catch {
            // 조용히 삼키지 않는다 — 실패하면 currentLine 이 계속 nil 로 남아 다음 update 틱마다
            // 이 함수가 재호출되는 영구 루프가 된다. 매 틱 로그를 쏟으면 로그가 범람하니 baseID 당 1회만.
            if failedLineBaseIDs.insert(a.baseID).inserted {
                AppLog.write("loadCurrentLine: line fetch failed for base \(a.baseID): \(error)")
            }
            return
        }
        failedLineBaseIDs.remove(a.baseID)   // 이후 재시도가 성공하면 다시 로그 대상이 되게 한다
        // await 중 사용량·민트 등 활성 상태는 계속 바뀔 수 있다. 요청 당시 스냅샷을 다시 쓰지 말고
        // 같은 개체가 아직 활성인 경우에만 최신 상태를 정규화한다.
        guard activeGeneration == generation,
              let latest = state.active, latest.baseID == a.baseID, currentLine == nil else { return }
        state.active = normalizedEvolutionState(latest, from: line.tree)
        state.reconcileRepresentativeSelection()   // 손상 경로 정규화로 사라진 단계가 대표로 남지 않게
        currentLine = line
        save()   // 마이그레이션 선택을 사용량 재평가 전에 영속화해 재시작마다 다시 롤리지 않는다.
        applyUsage(0)   // 라인 미로딩 동안 적립된 사용량이 임계를 넘었으면 지금 진화 판정
        // Path normalization can change currentID without entering the regular evolution branch.
        isHatching = false   // Do not hold the line-load lock across detail HTTP requests.
        if let speciesID = state.active?.currentID, detailProvider != nil {
            await loadDigimonDetails(speciesID: speciesID)
        }
    }

    /// 부화 종 선정 — 하드코딩 풀 없이 provider 의 base 인덱스 전체에서 가중 선택.
    ///   ① base 인덱스(id + captureRate)를 취득
    ///   ② 가중치 = captureRate 그대로(값이 클수록 흔함 — 등급별 유도값은
    ///      `DigimonLineProvider.captureRate(for:)` 주석의 실제 확률표 참고)
    ///      단, 이미 수집한 base 는 가중치 ½(미수집 부스트 — 재부화로 다른 종을 노리는 파밍은 열어둠)
    ///   ③ 누적 가중치에서 정확히 1롤 — 루프/재롤 없음, 시간 상한 확정적
    /// 인덱스 취득 실패 시 nil → 알 유지, 다음 갱신 틱 재시도.
    ///
    /// **기본 provider(`DigimonLineProvider`) 기준으로는 위 설명 중 "PokéAPI 1~5세대 base 전체
    /// (329종)"·"공식 capture_rate"·"GraphQL/30일 캐시"는 더 이상 사실이 아니다** — 인덱스는 번들
    /// JSON 12라인 고정이고 captureRate 는 등급에서 유도한 값이다(네트워크 호출 없음). 이 문단은
    /// `PokeAPIClient` 처럼 실제 PokéAPI 에 붙는 provider 를 주입했을 때만 유효하다.
    private func chooseBase() async -> Int? {
        let tier = state.eggTier
        if let full = try? await provider.baseSpeciesIndex(), !full.isEmpty {
            // 등급 보증 알은 후보를 먼저 좁힌다 — capture_rate 상한이 곧 등급 하한이므로
            // (Rarity.captureRateCeiling) 전설도 자연히 포함된다("희귀 이상"에 전설이 들어가는 게 정상).
            // 좁힌 결과가 비면 보증을 못 지키므로 전체 풀로 폴백하지 말고 알을 유지한다(다음 틱 재시도).
            let index = tier.map { t in full.filter { t.includes(captureRate: $0.captureRate) } } ?? full
            guard !index.isEmpty else {
                AppLog.write("hatch: no candidate for guaranteed \(tier?.rawValue ?? "none") — egg kept, retry next tick")
                return nil
            }
            let weights = index.map { e in
                CollectionWeight.adjusted(e.captureRate, isCollected: state.hasCollectedFinal(forBaseID: e.id))
            }
            let total = weights.reduce(0, +)
            var r = Int(rng.next() % UInt64(total))
            for (i, w) in weights.enumerated() {
                r -= w
                if r < 0 { return index[i].id }
            }
            return index.last?.id   // 도달 불가(방어)
        }
        // base 인덱스 취득 실패(예: GraphQL 엔드포인트 장애) → REST 폴백. 부화가 한 엔드포인트에 묶이지 않게.
        //
        // **기본 provider(`DigimonLineProvider`) 에서는 이 분기가 도달 불가다** —
        // `baseSpeciesIndex()` 가 throw 하지 않고 번들 JSON 에 라인이 있는 한 항상 비어있지 않은
        // 배열을 반환하므로 위 `if` 가 항상 성립한다. `chooseBaseViaREST()` 도 함께 죽은 코드가
        // 됐지만, `PokeAPIClient` 처럼 실제로 throw 할 수 있는 provider 를 주입하면 여전히 유효한
        // 폴백이므로 코드는 남겨둔다.
        AppLog.write("hatch: base index unavailable — REST fallback")
        return await chooseBaseViaREST()
    }

    /// REST 폴백(§ 위 주석 — 기본 provider 에서는 도달 불가) — PokéAPI 조회 가능 종 ID 범위에서
    /// 무작위 id 를 뽑아 base 인지 확인(rejection sampling). GraphQL 인덱스가 죽어도 부화가 되게 한다.
    /// 가중치(capture_rate)는 생략 — 희귀도는 부화 후 line() 이 실제 capture_rate 로 계산하므로
    /// 결과 개체의 등급은 정확하다. 인덱스 복구 시 가중 선택 재개.
    /// `DigimonAssets.queryableSpeciesIDs`(1...649)도 PokéAPI 전용 범위라 기본 provider 경로에서는
    /// 마찬가지로 의미가 없다.
    private func chooseBaseViaREST() async -> Int? {
        let tier = state.eggTier
        for attempt in 1...16 {
            let ids = DigimonAssets.queryableSpeciesIDs
            let id = Int(rng.next() % UInt64(ids.count)) + ids.lowerBound
            do {
                if let bs = try await provider.baseSpecies(id: id) {
                    // 등급 보증은 가중 경로와 **같은 기준**으로 여기서도 걸러야 한다 — 이 폴백만 빠지면
                    // GraphQL 인덱스 장애 때 보증이 조용히 깨진다. 못 찾으면 알 유지(구매 소멸 금지).
                    if let tier, !tier.includes(captureRate: bs.captureRate) { continue }
                    AppLog.write("hatch: REST fallback picked base \(id) (cap \(bs.captureRate), \(attempt) tries)")
                    return id
                }
                // nil = base 아님(진화 중간체) → 다음 시도
            } catch {
                AppLog.write("hatch: REST fallback network error — retry next tick: \(error)")
                return nil   // REST 도 불가 → 알 유지, 다음 update 틱 재시도
            }
        }
        AppLog.write("hatch: REST fallback exhausted 16 tries")
        return nil
    }

    private func computeState(burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool, today: Int) -> CompanionStateKind {
        if state.active == nil { return .egg }
        if justGraduated != nil || (eventUntil != nil && clock() < eventUntil!) { return .levelUp }
        if limitWarning { return .tired }
        if !hasUsageData || today == 0 { return .sleep }
        switch burnTier {
        case .idle: return .idle
        case .normal: return .working
        case .fast, .blazing: return .focus
        }
    }

    // MARK: 세이브 이전 (기기 교체)

    /// 덮어쓰기 확인에 쓸 "이 기기의 현재 진행" 요약.
    var transferSummary: SaveSummary { SaveSummary(state: state) }

    /// 저장 패널에 채울 기본 파일명. 봉투의 `exportedAt` 과 **같은 시계**에서 뽑는다 — 뷰가 따로
    /// `Date()` 를 부르면 파일명 날짜와 내용의 날짜가 갈릴 수 있다(자정 경계).
    var suggestedExportFileName: String { SaveTransfer.suggestedFileName(date: clock()) }

    /// 내보내기 페이로드. 파일 쓰기는 호출자(UI)가 사용자가 고른 위치에 수행한다.
    func exportedSaveData(appVersion: String, deviceName: String) throws -> Data {
        try SaveTransfer.encode(state: state, appVersion: appVersion, deviceName: deviceName, now: clock())
    }

    /// 검증된 세이브를 이 기기에 적용 — 기존 상태 백업 → 기기 기준 재정렬 → 저장 → 라인 재로딩.
    /// 백업을 못 남기면 **적용하지 않고** throw 한다 — 확인창이 "직전 상태가 남는다"고 약속하므로,
    /// 그 약속을 못 지키는 채로 덮어쓰면 사용자는 되돌릴 수단 없이 진행을 잃는다.
    func applySave(_ envelope: SaveEnvelope, todayTokensByProvider: [String: Int], todayDate: String,
                   hasUsageData: Bool) throws {
        try backupStateBeforeImport()
        state = SaveTransfer.rebasedForThisDevice(envelope.state,
                                                  current: state,
                                                  todayTokensByProvider: todayTokensByProvider,
                                                  todayDate: todayDate,
                                                  hasUsageData: hasUsageData)
        // 이전 개체 기준으로 진행 중이던 비동기·연출을 전부 무효화한다. activeGeneration 을 올리지
        // 않으면 먼저 떠 있던 라인 로드가 완료되며 새로 불러온 개체를 덮어쓴다.
        activeGeneration += 1
        currentLine = nil
        prefetchedLineID = nil
        justEvolvedTo = nil
        justGraduated = nil
        eventUntil = nil
        celebration = nil
        isHatchRetryDelayed = false
        // 이전 개체 기준의 1회성 피드백(사탕 +XP)도 비운다 — 안 비우면 불러온 직후 남의
        // 개체에 대한 "+XP" 가 새 개체 위에 떠오른다.
        candyFeedbackAmount = 0
        displayState = state.active != nil ? .idle : .egg
        migrateDigimonProfilesIfNeeded()
        save()
        if state.active != nil { Task { await loadCurrentLine() } }
        if detailProvider != nil { Task { await prepareDigimonProfiles() } }
        AppLog.write("save imported from \(envelope.sourceDevice): dex=\(state.dex.count) lifetime=\(state.usedSinceInstall)")
    }

    /// 덮어쓰기 직전 현재 상태를 옆에 남긴다 — 잘못 불러왔을 때 되돌릴 수단.
    /// 슬롯을 하나만 쓰면 두 번째 불러오기가 **원본**을 덮어써, "잘못 불러왔으니 되돌린다"는 바로 그
    /// 상황에서 되돌릴 대상이 사라진다. 불러올 때마다 새 슬롯을 쓰고 오래된 것부터 정리한다.
    @discardableResult
    private func backupStateBeforeImport() throws -> URL {
        guard let data = try? JSONEncoder().encode(state) else { throw SaveTransferError.backupFailed }
        let dir = fileURL.deletingLastPathComponent()
        let backup = dir.appendingPathComponent(SaveTransfer.backupFileName(date: clock()))
        do {
            try data.write(to: backup, options: .atomic)
        } catch {
            AppLog.write("save import aborted — backup write failed: \(error)")
            throw SaveTransferError.backupFailed
        }
        pruneImportBackups(in: dir)
        return backup
    }

    /// 최근 N 개만 남기고 오래된 백업을 지운다. 파일명이 `yyyy-MM-dd-HHmmss` 라 사전순 = 시간순이다.
    private func pruneImportBackups(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = names.filter { $0.hasPrefix(SaveTransfer.backupFilePrefix) }.sorted()
        guard backups.count > SaveTransfer.backupsToKeep else { return }
        for stale in backups.dropLast(SaveTransfer.backupsToKeep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale))
        }
    }

    // MARK: 디지몬 combat profiles / details

    /// Exact current/final individuals for a Digidex species. Earlier evolution stages remain
    /// species reference pages; the same evolved individual is not duplicated as a second creature.
    func digimonIndividuals(speciesID: Int) -> [DexEntry] {
        dexEntriesSorted.filter { $0.finalID == speciesID && $0.profile != nil }
    }

    // MARK: 디지몬 설정 정보(도감 상세 패널)

    /// 도감 상세 패널이 쓰는 설정 정보 조회. **동기 + 결과 2종(found/missing)** 이다 — 출처가 번들
    /// JSON 이라 네트워크 대기가 없고, 따라서 "로딩 중" 이라는 제3의 상태가 존재할 수 없다.
    /// 아래 `loadDigimonDetails`(능력치 경로)와 달리 async/loading/failed 집합을 쓰지 않는 이유가
    /// 이것이다. 데이터가 없는 종은 `.missing` 으로 **즉시** 끝나야 한다 — 조용히 아무것도 안 하면
    /// 뷰가 영원히 스피너에 갇힌다(이번 버그).
    func digimonLore(speciesID: Int) -> DigimonLoreLookup {
        guard let lore = loreSource.lore(speciesID: speciesID) else { return .missing }
        return .found(lore)
    }

    /// Loads immutable PokéAPI metadata and persists any deferred profile fields exactly once.
    func loadDigimonDetails(speciesID: Int) async {
        if let details = digimonDetailsByID[speciesID] {
            enrichProfiles(for: speciesID, with: details)
            return
        }
        // detailProvider 가 nil 이면 이 종의 능력치 메타데이터는 **영원히** 오지 않는다. 아무 흔적도
        // 없이 return 하면 "아직 안 왔다" 와 "앞으로도 안 온다" 가 구분되지 않으므로 로그는 남긴다.
        // failedDigimonDetailIDs 에 넣지는 않는다 — 이 집합을 읽던 재시도 UI 가 없어져 지금은 아무도
        // 읽지 않고, 넣으면 매 실행마다 읽는 이 없는 집합만 커진다. 상세 패널의 "정보 없음" 은 이
        // 경로가 아니라 digimonLore(speciesID:) 의 .missing 이 담당한다.
        guard let detailProvider else {
            AppLog.write("digimon details skipped id=\(speciesID): no detail provider configured")
            return
        }
        guard !loadingDigimonDetailIDs.contains(speciesID) else { return }
        loadingDigimonDetailIDs.insert(speciesID)
        failedDigimonDetailIDs.remove(speciesID)
        defer { loadingDigimonDetailIDs.remove(speciesID) }
        do {
            let details = try await detailProvider.digimonDetails(speciesID: speciesID)
            digimonDetailsByID[speciesID] = details
            enrichProfiles(for: speciesID, with: details)
        } catch {
            failedDigimonDetailIDs.insert(speciesID)
            AppLog.write("digimon details fetch failed id=\(speciesID): \(error)")
        }
    }

    /// Startup/background warmup for the only profile needed before a detail page is opened.
    func prepareDigimonProfiles() async {
        guard let speciesID = state.active?.currentID else { return }
        await loadDigimonDetails(speciesID: speciesID)
    }

    private func enrichProfiles(for speciesID: Int, with details: DigimonDetails) {
        var changed = false
        if var active = state.active, active.currentID == speciesID, var profile = active.profile {
            let before = profile
            profile.enrich(with: details)
            if profile != before {
                active.profile = profile
                state.active = active
                changed = true
            }
        }
        for index in state.dex.indices where state.dex[index].finalID == speciesID {
            guard var profile = state.dex[index].profile else { continue }
            let before = profile
            profile.enrich(with: details)
            if profile != before {
                state.dex[index].profile = profile
                changed = true
            }
        }
        if changed { save() }
    }

    /// Additive migration for pre-profile saves. It never needs network and therefore cannot block launch.
    /// Deferred fields (gender/ability/moves) are filled after the cached/detail fetch succeeds.
    private func migrateDigimonProfilesIfNeeded() {
        var changed = false
        if var active = state.active, active.profile == nil {
            let key = "active:\(active.baseID):\(active.pathIDs.map(String.init).joined(separator: ",")):\(state.lastDate)"
            active.profile = DigimonProfile.generate(seed: DigimonProfileMigration.seed(key))
            state.active = active
            changed = true
        }
        for index in state.dex.indices {
            let entry = state.dex[index]
            if entry.profile == nil {
                let graduated = !entry.isReleased
                // Released entries only persisted their reached `chainOrder`, not the originally
                // planned form count. Treating that count as `totalForms` is the best recoverable
                // estimate, but it is an upper bound when release happened before the planned final.
                let growth = graduated
                    ? DigimonBalance.graduationTotal(entry.rarity)
                    : Self.reconstructedGrowthTokens(
                        rarity: entry.rarity, totalForms: max(1, entry.chainOrder.count),
                        completedStages: max(0, entry.chainOrder.count - 1), currentStageUsage: 0)
                var profile = DigimonProfile.generate(
                    seed: DigimonProfileMigration.seed("dex:\(entry.id):\(entry.finalID)"),
                    growthTokens: growth,
                    instanceID: entry.id)
                profile.applyGrowth(0, rarity: entry.rarity)
                state.dex[index].profile = profile
                changed = true
            }
        }
        let before = state.active?.profile
        reconcileActiveProfileGrowth()
        if !changed {
            if before != state.active?.profile { save() }
            return
        }

        // One recoverable snapshot before the first format expansion. Never overwrite it.
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("companion-state.pre-profiles-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
        save()
        AppLog.write("digimon profile migration complete — previous state kept as \(backup.lastPathComponent)")
    }

    /// Completed phases retain their earned credit. Only the current raw phase is repriced
    /// by difficulty/repeat boost; its profile high-water mark prevents level loss.
    private func reconcileActiveProfileGrowth() {
        guard var active = state.active, var profile = active.profile else { return }
        let completed = Self.reconstructedGrowthTokens(
            rarity: active.rarity, totalForms: active.totalForms,
            completedStages: active.stageIndex, currentStageUsage: 0)
        let standardPhase = DigimonBalance.phaseThreshold(
            rarity: active.rarity, totalForms: active.totalForms, stageIndex: active.stageIndex)
        let fraction = min(1, max(0, Double(active.usedAtStage) / Double(max(1, stageThreshold(for: active)))))
        let candidate = min(DigimonBalance.graduationTotal(active.rarity),
                            completed + Int((Double(standardPhase) * fraction).rounded(.down)))
        profile.advanceGrowth(to: candidate, rarity: active.rarity)
        if let details = digimonDetailsByID[active.currentID] { profile.enrich(with: details) }
        active.profile = profile
        state.active = active
    }

    static func reconstructedGrowthTokens(rarity: Rarity, totalForms: Int,
                                          completedStages: Int, currentStageUsage: Int) -> Int {
        let forms = max(1, totalForms)
        let completed = min(max(0, completedStages), forms)
        let completedGrowth = (0..<completed).reduce(0) { total, stage in
            total + DigimonBalance.phaseThreshold(rarity: rarity, totalForms: forms, stageIndex: stage)
        }
        return min(SaveTransfer.maxTokenValue,
                   completedGrowth + min(SaveTransfer.maxTokenValue, max(0, currentStageUsage)))
    }

    // MARK: 영속
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }   // 파일 없음 = 신규 설치
        guard let s = try? JSONDecoder().decode(CompanionState.self, from: data) else {
            // 디코드 실패(전면 손상/미래 스키마) → fresh 로 시작하되, 다음 save() 가 원본을 덮어써 영구
            // 유실되기 전에 .corrupt 로 보존해 수동 복구 여지를 남긴다(도감 per-entry 격리로 못 살린 경우 대비).
            let backup = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            AppLog.write("companion state decode failed — original backed up to \(backup.lastPathComponent), starting fresh")
            return
        }
        guard s.saveVersion == CompanionState.currentSaveVersion else {
            // 디코드는 성공했지만 세대가 다른 세이브(예: 종 id 체계 전환 이전) — namespace 없는 생 Int
            // (baseID/finalID/chainOrder/pathIDs) 를 새 세대 종으로 잘못 해석하지 않도록 fresh 로 시작한다.
            // 손상이 아니라 세대 불일치이므로 .corrupt 와 다른 확장자로 보존해 수동 복구 여지를 남긴다.
            let backup = fileURL.appendingPathExtension("legacy")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            AppLog.write("companion state save version mismatch (found \(s.saveVersion), expected \(CompanionState.currentSaveVersion)) — original backed up to \(backup.lastPathComponent), starting fresh")
            return
        }
        // 불러오기 경계와 같은 정규화를 디스크에서 읽을 때도 건다. 불러오기만 막으면 **이미 저장된**
        // 극단값은 그대로 남아, 앱이 매 기동마다 같은 값을 읽어 산술 트랩으로 죽는 상태를 못 벗어난다
        // (디코드는 *성공*하므로 위의 .corrupt 복구도 발동하지 않는다). 여기서 걸면 자가 복구된다.
        state = SaveTransfer.sanitized(s)
    }
    private func save() {
        refreshRepresentativeSubject()
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)   // 부분 쓰기 손상 방지(펫 상태)
    }
}
