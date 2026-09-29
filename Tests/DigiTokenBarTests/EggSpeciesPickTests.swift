import XCTest
@testable import DigiTokenBar

/// 배치할 디지몬 직접 선택 — 알 상태에서 **도감에 등록된 유아기(base) 종** 하나를 지정해 부화시킨다.
///
/// 라인 스텁은 `JogressEvolutionTests` 와 같은 이유로 **실제 번들 데이터의 id·구성**을 쓴다:
/// 게이트가 `DigimonData.lines` 조회라서 합성 id 로는 후보가 아예 나오지 않고, `pathIDs` 가
/// 사다리 종만 담는지도 합성 트리로는 공허하게 통과한다.
private struct PickStubProvider: DigimonLineProviding {
    let lines: [Int: EvoLine]
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        guard let line = lines[baseSpeciesID] else {
            throw NSError(domain: "PickStubProvider", code: 404)
        }
        return line
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        lines.keys.sorted().map { BaseSpecies(id: $0, captureRate: 255) }
    }
}

/// 라인 fetch 를 테스트가 붙잡아 두는 스텁 — `isHatching` 락이 실제로 걸린 창을 관측하려면
/// 부화가 await 에서 멈춰 있어야 한다. 동기 테스트는 이 케이스를 공허하게 통과한다.
///
/// **세마포어로 만들지 않는다.** 테스트 본문이 `@MainActor` 라, MainActor 스레드를 블로킹하면
/// 같은 actor 에서 도는 부화 Task 가 fetch 에 진입조차 못 해 영구 교착한다(실측: 600초 타임아웃).
/// 모든 대기는 `await` 로만 한다.
@MainActor
private final class GatedPickProvider: DigimonLineProviding {
    let value: EvoLine
    /// fetch 가 이 값이 true 가 될 때까지 양보하며 기다린다.
    private var released = false
    private(set) var isFetching = false

    /// `lines` 는 `line()` 이 인자로 조회할 사전이다. 기본은 `value` 한 종이고, 경합 테스트처럼
    /// 롤 후보가 여럿이면 그 종들의 라인도 함께 넣어야 fetch 가 throw 하지 않는다.
    private let lines: [Int: EvoLine]

    init(value: EvoLine, indexIDs: [Int]? = nil, lines extra: [EvoLine] = []) {
        self.value = value
        self.indexIDs = indexIDs ?? [value.baseID]
        var table = [value.baseID: value]
        for l in extra { table[l.baseID] = l }
        self.lines = table
    }

    /// **인자를 키로 조회한다.** 무엇을 요청하든 `value` 를 돌려주면 부화 종 단언이 동어반복이 된다
    /// — `hatchCore` 는 `MonState` 를 인자가 아니라 **fetch 해 온 `line.baseID`** 로 만들기 때문에
    /// (`CompanionStore.hatchCore`), 스텁이 인자를 무시하면 어떤 종을 부화시켜도
    /// `active?.baseID == value.baseID` 가 되어 경합 회귀를 놓친다(실측: 가드를 지워도 그 단언만 통과).
    /// 모르는 종은 throw 해서 "엉뚱한 종을 요청했다"가 조용히 성공으로 넘어가지 않게 한다.
    nonisolated func line(baseSpeciesID: Int) async throws -> EvoLine {
        await MainActor.run { self.isFetching = true }
        while await MainActor.run(body: { !self.released }) {
            await Task.yield()
        }
        let known = await MainActor.run { self.lines }
        guard let line = known[baseSpeciesID] else { throw NSError(domain: "GatedPickProvider", code: 404) }
        return line
    }
    /// 종 롤(`baseSpeciesIndex`)은 **별도 게이트**를 쓴다 — `chooseBase()` 의 await 창(종 롤 중)과
    /// `line()` 의 await 창(부화가 라인 받는 중)은 서로 다른 경합이다. 두 게이트가 같은 플래그를
    /// 공유하면 한쪽 대기가 다른 쪽을 풀어 창이 안 열린다.
    ///
    /// 기본값은 **열린 상태**다(`indexReleased = true`) — 기존 테스트가 여기서 멈추면 안 된다.
    /// 경합을 재현하는 테스트만 `gateIndex()` 로 닫는다.
    ///
    /// `indexIDs` 는 롤 후보다. 경합 재현 시 **2개 이상**이어야 한다: 1개면 롤 결과가 선택 종과
    /// 같아져 대입이 무해한 no-op 이 되고, 가드를 없애도 통과하는 거짓 green 이 된다.
    var indexIDs: [Int]
    private var indexReleased = true
    private(set) var isIndexing = false

    nonisolated func baseSpeciesIndex() async throws -> [BaseSpecies] {
        // 배열 리터럴 인자 안에 `MainActor.run` 을 중첩하고 `await` 를 바깥에 두면 Swift 버전에
        // 따라 암묵적 async 위치 해석이 갈린다(CI 6.1.2 / 로컬 6.3.3). 평문 두 줄로 고정한다.
        await MainActor.run { self.isIndexing = true }
        while await MainActor.run(body: { !self.indexReleased }) {
            await Task.yield()
        }
        let ids = await MainActor.run { self.indexIDs }
        return ids.map { BaseSpecies(id: $0, captureRate: 255) }
    }

    /// fetch 진입까지 양보하며 기다린다(= `isHatching` 이 확실히 true 인 창에 들어섰다).
    func waitUntilFetching() async {
        var spins = 0
        while !isFetching, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(isFetching, "부화가 라인 fetch 에 진입하지 않았다")
    }
    func release() { released = true }

    /// 종 롤을 await 에 붙잡아 둘 준비 — 스토어 생성 **전에** 부른다.
    func gateIndex() { indexReleased = false }

    /// 종 롤이 await 에 걸린 창까지 기다린다.
    func waitUntilIndexing() async {
        var spins = 0
        while !isIndexing, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        XCTAssertTrue(isIndexing, "프리패치가 종 롤에 진입하지 않았다 — 경합 창이 안 열렸다")
    }
    func releaseIndex() { indexReleased = true }

    /// 붙잡아 둔 Task 가 대입까지 끝낼 시간을 준다 — 단언 전에 경합이 해소돼야 한다.
    func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }
}
/// 번들 데이터의 라인 그대로를 `EvoLine` 으로 만든다 — 사다리 종·이름이 모두 실제 값이다.
private func pickLine(_ line: DigiLine) -> EvoLine {
    // stages 는 선형이므로 뒤에서부터 감싸 단일 경로 트리를 만든다.
    var node = EvoNode(speciesID: line.stages.last!.id, children: [])
    for stage in line.stages.dropLast().reversed() {
        node = EvoNode(speciesID: stage.id, children: [node])
    }
    var names: [Int: [String: String]] = [:]
    for stage in line.stages {
        names[stage.id] = DigimonData.name(for: stage.id)?.localizedNames ?? [:]
    }
    return EvoLine(baseID: line.baseID, tree: node, rarity: line.rarity, names: names)
}

private let pickFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// 유아기 종을 후보로 만드는 **졸업** 도감 항목 — `graduate()` 가 만드는 것과 같은 형태
/// (`releasedAt`/`armoredAt` 둘 다 nil). `chainOrder` 에 base 가 있으면 `ownsSpecies` 가 true 다.
private func pickGraduated(_ line: DigiLine) -> DexEntry {
    let chain = line.stages.map(\.id)
    return DexEntry(id: "grad-\(line.baseID)", baseID: line.baseID, finalID: chain.last!,
                    chainOrder: chain, rarity: line.rarity, caughtAt: pickFixedNow)
}

@MainActor
final class EggSpeciesPickTests: XCTestCase {

    /// 언어는 **시드에 명시 고정**한다 — `CompanionState.language` 기본값 `.systemDefault` 는
    /// `Locale.preferredLanguages` 를 읽으므로, 고정하지 않으면 개발자 맥(ko)에서만 통과하고
    /// 영어 CI 러너에서 이름 단언이 깨진다(`JogressEvolutionTests` 와 같은 이유).
    /// `fileURL` 을 넘기면 그 경로의 세이브를 그대로 연다(시드 쓰기 생략) — 재시작 재현용.
    private func store(_ provider: any DigimonLineProviding,
                       seed state: CompanionState = CompanionState(),
                       language: AppLanguage = .ko, rngSeed: UInt64 = 7,
                       fileURL: URL? = nil) throws -> CompanionStore {
        let url = try fileURL ?? {
            var state = state
            state.language = language
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("eggpick-\(UUID().uuidString).json")
            try JSONEncoder().encode(state).write(to: url)
            return url
        }()
        // defaults 를 격리한다 — 러너 도메인의 난이도 잔여물이 임계를 바꾸면 시드가 무의미해진다.
        let defaults = UserDefaults(suiteName: "eggpick-\(UUID().uuidString)")!
        return CompanionStore(provider: provider, clock: { pickFixedNow }, fileURL: url,
                              rng: SeededRNG(seed: rngSeed), defaults: defaults)
    }

    /// 테스트가 재시작을 재현할 수 있게 세이브 경로를 함께 돌려준다.
    private func eggStoreAtURL(owning owned: [DigiLine], language: AppLanguage = .ko)
        throws -> (store: CompanionStore, url: URL, provider: any DigimonLineProviding) {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = owned.map(pickGraduated)
        seed.usedSinceInstall = 20_000_000_000
        seed.language = language
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eggpick-restart-\(UUID().uuidString).json")
        try JSONEncoder().encode(seed).write(to: url)
        let provider = PickStubProvider(
            lines: Dictionary(uniqueKeysWithValues: DigimonData.lines.map { ($0.baseID, pickLine($0)) }))
        let defaults = UserDefaults(suiteName: "eggpick-\(UUID().uuidString)")!
        let s = CompanionStore(provider: provider, clock: { pickFixedNow }, fileURL: url,
                               rng: SeededRNG(seed: 7), defaults: defaults)
        return (s, url, provider)
    }

    /// 알 상태 + 주어진 라인들이 도감에 졸업 등록된 스토어.
    private func eggStore(owning owned: [DigiLine],
                          allLines: [DigiLine]? = nil,
                          eggTier: Rarity? = nil,
                          eggUsage: Int = 0,
                          language: AppLanguage = .ko) throws -> CompanionStore {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = owned.map(pickGraduated)
        seed.eggTier = eggTier
        seed.eggUsage = eggUsage
        seed.usedSinceInstall = 20_000_000_000
        let provided = allLines ?? DigimonData.lines
        let provider = PickStubProvider(
            lines: Dictionary(uniqueKeysWithValues: provided.map { ($0.baseID, pickLine($0)) }))
        return try store(provider, seed: seed, language: language)
    }

    private var agumon: DigiLine { DigimonData.agumonLine }      // legendary
    private var vmon: DigiLine { DigimonData.vmonLine }          // uncommon
    private var piyomon: DigiLine { DigimonData.piyomonLine }    // common
    private var patamon: DigiLine { DigimonData.patamonLine }    // rare

    // MARK: 데이터 전제 — 후보 집합이 데이터에서 유도된다

    /// 후보 id 는 전부 `DigiLine.baseID`(= `stages[0].id`) 다. 하드코딩 배열이었다면 데이터가
    /// 바뀔 때 조용히 어긋난다.
    func testCandidateIDsAreLineBaseIDs() throws {
        let s = try eggStore(owning: DigimonData.lines)
        let expected = Set(DigimonData.lines.map(\.baseID))
        XCTAssertEqual(Set(s.babyPicks.map(\.baseID)), expected,
                       "후보 집합이 라인 stages[0] 에서 유도되지 않았다")
        XCTAssertEqual(expected.count, 12, "라인 수가 바뀌면 이 테스트의 전제를 다시 확인해야 한다")
    }

    /// 모든 후보 id 가 이름 데이터에 있다 — 52종 밖 id 는 에러 없이 🥚 로 떨어지므로 여기서 잡는다.
    func testEveryCandidateResolvesAName() throws {
        let s = try eggStore(owning: DigimonData.lines)
        for pick in s.babyPicks {
            XCTAssertNotNil(DigimonData.name(for: pick.baseID),
                            "#\(pick.baseID) 는 이름 데이터에 없다 — 화면에서 알 이모지로 떨어진다")
            XCTAssertFalse(pick.name.hasPrefix("#"), "#\(pick.baseID) 이름이 해석되지 않았다")
        }
    }

    /// 후보 등급은 라인 등급과 같다 — 보증 필터가 이 값으로 걸리므로 어긋나면 보증이 깨진다.
    func testCandidateRarityMatchesLineRarity() throws {
        let s = try eggStore(owning: DigimonData.lines)
        let byID = Dictionary(uniqueKeysWithValues: DigimonData.lines.map { ($0.baseID, $0.rarity) })
        for pick in s.babyPicks {
            XCTAssertEqual(pick.rarity, byID[pick.baseID], "#\(pick.baseID) 등급이 라인과 다르다")
        }
    }

    // MARK: ① 도감 등록 종을 고르면 그 종으로 부화한다

    func testPickingOwnedBabyHatchesThatSpecies() async throws {
        let s = try eggStore(owning: [vmon], eggUsage: DigimonBalance.eggHatchThreshold)
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.baseID, vmon.baseID, "고른 종으로 부화하지 않았다")
        XCTAssertEqual(s.currentSpeciesID, vmon.baseID)
    }

    /// 임계 전 선택은 기억되고, 임계 도달 시 그 종으로 깨어난다 — 5M 인큐베이션 게이트 유지.
    func testPickBeforeThresholdIsRememberedAndHatchesLater() async throws {
        let s = try eggStore(owning: [vmon], eggUsage: 0)
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        await s.hatchIfNeeded()
        XCTAssertNil(s.state.active, "임계 미달인데 부화했다 — 인큐베이션 게이트가 무너졌다")
        XCTAssertEqual(s.state.pendingHatchID, vmon.baseID, "선택이 기억되지 않았다")

        // 첫 관측은 프로바이더 장부의 **기준점**만 잡는다(과거 사용량 소급 금지) — 적립은 두 번째
        // 관측의 증분부터다. 한 번만 부르면 eggUsage 가 0 이라 이 테스트가 인큐베이션 게이트가 아닌
        // 장부 시드 때문에 통과/실패한다.
        func observe(_ tokens: Int) {
            s.update(todayTokensByProvider: ["claude_code": tokens], todayDate: "2026-09-29",
                     monthTotal: tokens, burnTier: .normal, limitWarning: false, hasUsageData: true)
        }
        observe(0)
        observe(DigimonBalance.eggHatchThreshold)
        XCTAssertGreaterThanOrEqual(s.state.eggUsage, DigimonBalance.eggHatchThreshold,
                                    "사용량이 적립되지 않았다 — 아래 단언이 공허해진다")

        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.baseID, vmon.baseID)
    }

    /// 선택이 세이브에 영속된다 — **재시작(같은 파일을 여는 두 번째 스토어)** 을 건너서도 살아남는다.
    ///
    /// `CompanionState` 의 Codable 왕복만 보면 안 된다: `pickHatchSpecies` 가 `save()` 를 아예
    /// 부르지 않아도, `SaveTransfer.sanitized` 가 이 필드를 떨궈도 그런 테스트는 통과한다.
    /// `sanitized` 는 실제로 한 분기(`active != nil`)에서 `pendingHatchID` 를 지우므로,
    /// **알 상태 분기가 이 값을 보존한다**는 것이 여기서 확인할 유일한 내용이다.
    func testPickSurvivesRestart() async throws {
        let (s1, url, provider) = try eggStoreAtURL(owning: [vmon])
        XCTAssertTrue(s1.pickHatchSpecies(baseID: vmon.baseID))

        let s2 = try store(provider, rngSeed: 7, fileURL: url)   // 재시작
        XCTAssertEqual(s2.state.pendingHatchID, vmon.baseID,
                       "선택이 디스크를 건너 살아남지 못했다(save 누락 또는 sanitize 가 떨궜다)")
        XCTAssertNil(s2.state.active, "재시작이 알 상태를 잃었다 — 아래 단언이 공허해진다")
        XCTAssertEqual(s2.pickedHatchBaseID, vmon.baseID, "재시작 후 예고가 사라졌다")
        XCTAssertTrue(s2.babyPicks.contains { $0.baseID == vmon.baseID },
                      "재시작 후 그 종이 후보에서 빠졌다")

        // 재시작한 스토어가 임계 도달 시 **고른 종으로** 깨어난다 — 사용자가 실제로 겪는 경로다.
        s2.applyUsage(0)
        s2.update(todayTokensByProvider: ["claude_code": 0], todayDate: "2026-09-29",
                  monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        s2.update(todayTokensByProvider: ["claude_code": DigimonBalance.eggHatchThreshold],
                  todayDate: "2026-09-29", monthTotal: 0, burnTier: .normal,
                  limitWarning: false, hasUsageData: true)
        await s2.hatchIfNeeded()
        XCTAssertEqual(s2.state.active?.baseID, vmon.baseID)
    }

    // MARK: ② 결과 pathIDs 가 사다리 종만 담는다

    /// 죠그레스/체인 결과 종(331/900/405/183/390/387/481)이 경로에 섞이면 `line.tree.node(withID:)`
    /// 가 nil 을 주어 성장이 영구 정지한다. id 목록이 아니라 `isLadderSpecies` 로 판정한다.
    func testHatchedPathContainsOnlyLadderSpecies() async throws {
        for line in DigimonData.lines {
            let s = try eggStore(owning: [line], eggUsage: DigimonBalance.eggHatchThreshold)
            XCTAssertTrue(s.pickHatchSpecies(baseID: line.baseID))
            await s.hatchIfNeeded()
            let active = try XCTUnwrap(s.state.active, "#\(line.baseID) 부화 실패")
            XCTAssertEqual(active.baseID, line.baseID)
            let ladderIDs = Set(line.stages.map(\.id))
            for id in active.pathIDs + active.plannedPathIDs {
                XCTAssertTrue(DigimonData.isLadderSpecies(id),
                              "#\(id) 는 사다리 밖 종이다 — 성장이 멈춘다(base \(line.baseID))")
                XCTAssertTrue(ladderIDs.contains(id),
                              "#\(id) 는 base \(line.baseID) 라인 밖 종이다")
            }
        }
    }

    /// 끝까지 성장시켜도 사다리 밖 종이 섞이지 않는다 — 부화 직후만 보면 pathIDs 가 1칸이라 공허하다.
    func testGrownPathStaysOnTheLadder() async throws {
        let s = try eggStore(owning: [patamon], eggUsage: DigimonBalance.eggHatchThreshold)
        XCTAssertTrue(s.pickHatchSpecies(baseID: patamon.baseID))
        await s.hatchIfNeeded()
        let ladderIDs = Set(patamon.stages.map(\.id))
        var guardCount = 0
        while s.state.active != nil, guardCount < 20 {
            guardCount += 1
            s.applyUsage(s.threshold)
            guard let active = s.state.active else { break }
            XCTAssertEqual(Set(active.pathIDs).subtracting(ladderIDs), [],
                           "성장 중 사다리 밖 종이 경로에 들어왔다")
        }
        XCTAssertGreaterThan(guardCount, 1, "성장이 전혀 진행되지 않았다 — 단언이 공허하다")
    }

    // MARK: ③ 도감에 없는 종은 고를 수 없다

    func testUnownedSpeciesIsNotACandidate() throws {
        let s = try eggStore(owning: [vmon])
        XCTAssertEqual(s.babyPicks.map(\.baseID), [vmon.baseID],
                       "도감에 없는 라인이 후보에 들어왔다")
        XCTAssertFalse(s.babyPicks.contains { $0.baseID == agumon.baseID })
    }

    /// 게이트가 후보 목록을 **재조회**한다 — 참칭 호출자가 도감에 없는 종을 통과시키지 못한다.
    func testPickingUnownedSpeciesIsRejected() throws {
        let s = try eggStore(owning: [vmon])
        XCTAssertFalse(s.pickHatchSpecies(baseID: agumon.baseID),
                       "도감에 없는 종이 선택을 통과했다")
        XCTAssertNil(s.state.pendingHatchID, "거절됐는데 선택이 기록됐다")
    }

    /// 유아기가 아닌 종(사다리 중간·최종 단계)도 후보가 아니다 — base 축으로 유도했는지 확인.
    func testNonBabyLadderSpeciesIsRejected() throws {
        let s = try eggStore(owning: [agumon])
        let nonBase = agumon.stages.dropFirst().map(\.id)
        XCTAssertFalse(nonBase.isEmpty, "라인에 base 밖 단계가 없으면 단언이 공허하다")
        for id in nonBase {
            XCTAssertFalse(s.babyPicks.contains { $0.baseID == id }, "#\(id) 가 후보에 들어왔다")
            XCTAssertFalse(s.pickHatchSpecies(baseID: id), "#\(id) 가 선택을 통과했다")
        }
    }

    /// 방생 기록(`isReleased`)도 `ownsSpecies` 가 인정하는 보유다 — 놓아준 종을 다시 고를 수 있어야
    /// "도감은 쌓이기만 한다" 는 약속과 어긋나지 않는다.
    func testReleasedRecordStillQualifiesAsOwned() throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        var released = pickGraduated(vmon)
        released.releasedAt = pickFixedNow
        seed.dex = [released]
        let provider = PickStubProvider(
            lines: Dictionary(uniqueKeysWithValues: DigimonData.lines.map { ($0.baseID, pickLine($0)) }))
        let s = try store(provider, seed: seed)
        XCTAssertEqual(s.babyPicks.map(\.baseID), [vmon.baseID])
    }

    /// 후보가 0개면 진입점을 숨긴다 — 신규 플레이어에게 빈 화면으로 가는 버튼을 두지 않는다.
    func testFreshPlayerHasNoCandidatesAndNoEntryPoint() throws {
        let s = try eggStore(owning: [])
        XCTAssertEqual(s.babyPicks, [])
        XCTAssertFalse(s.canPickHatchSpecies)
    }

    // MARK: ④ 세대 가드 / isHatching 락

    /// 부화가 라인 fetch 에서 대기 중(`isHatching == true`)이면 선택을 **거절**한다.
    /// 진행 중인 부화는 `baseID` 를 인자로 들고 있어 `pendingHatchID` 를 고쳐도 되돌려지지 않으므로,
    /// 조용히 무시하면 사용자는 선택이 먹힌 줄 알고 다른 종을 받는다.
    func testPickIsRejectedWhileHatchInFlight() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon), pickGraduated(piyomon)]
        seed.eggUsage = DigimonBalance.eggHatchThreshold
        seed.usedSinceInstall = 20_000_000_000
        let gated = GatedPickProvider(value: pickLine(piyomon))
        let s = try store(gated, seed: seed)

        let hatching = Task { await s.hatch(baseID: piyomon.baseID) }
        await gated.waitUntilFetching()
        // fetch 에 진입했으므로 `isHatching` 이 잠긴 창 안이다.
        XCTAssertTrue(s.isHatching, "부화 락이 걸리지 않았다 — 아래 단언이 공허해진다")
        XCTAssertFalse(s.pickHatchSpecies(baseID: vmon.baseID), "부화 중 선택이 통과했다")
        XCTAssertNil(s.state.pendingHatchID, "거절됐는데 선택이 기록됐다")

        gated.release()
        await hatching.value
        XCTAssertEqual(s.state.active?.baseID, piyomon.baseID,
                       "진행 중이던 부화가 선택 시도에 흔들렸다")
    }
    /// 활성 개체가 있으면 고를 알이 없다 — 여기서 활성 개체를 치우면 그게 방생이다.
    func testPickIsRejectedWhileActiveExists() async throws {
        let s = try eggStore(owning: [vmon, piyomon], eggUsage: DigimonBalance.eggHatchThreshold)
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        await s.hatchIfNeeded()
        XCTAssertNotNil(s.state.active)
        XCTAssertEqual(s.babyPicks, [], "활성 개체가 있는데 후보가 나왔다")
        XCTAssertFalse(s.canPickHatchSpecies)
        XCTAssertFalse(s.pickHatchSpecies(baseID: piyomon.baseID), "활성 개체가 있는데 선택이 통과했다")
        XCTAssertEqual(s.state.active?.baseID, vmon.baseID, "선택 시도가 활성 개체를 바꿨다")
    }

    /// 프리패치가 미리 롤해 둔 종을 선택이 덮어쓴다(그 반대가 아니다). `ensureEggPrefetch` 의
    /// await 뒤 재확인이 없으면 이 순서가 뒤집혀 랜덤 종이 선택을 덮는다.
    func testPickOverridesPrefetchedRoll() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon)]
        seed.pendingHatchID = piyomon.baseID   // 프리패치가 미리 롤해 둔 종
        seed.eggUsage = DigimonBalance.eggHatchThreshold
        seed.usedSinceInstall = 20_000_000_000
        let provider = PickStubProvider(
            lines: Dictionary(uniqueKeysWithValues: DigimonData.lines.map { ($0.baseID, pickLine($0)) }))
        let s = try store(provider, seed: seed)

        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        XCTAssertEqual(s.state.pendingHatchID, vmon.baseID, "선택이 프리패치 롤을 덮지 못했다")
        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.baseID, vmon.baseID)
    }

    /// **경합 창을 실제로 밟는다** — 종 롤이 `baseSpeciesIndex()` 의 await 에 멈춰 있는 동안
    /// 선택이 들어오면, 롤이 복귀해도 선택을 덮지 않아야 한다.
    ///
    /// `testPickOverridesPrefetchedRoll` 은 `pendingHatchID` 를 **스토어 생성 전에** 시드하므로
    /// `ensureEggPrefetch` 의 `if state.pendingHatchID == nil` 분기에 아예 들어가지 않는다 — 롤이
    /// 돌지 않으니 경합 창을 밟지 않고, 가드를 지워도 통과한다(팀 리드가 뮤테이션으로 확인). 이
    /// 테스트가 그 구멍을 메운다.
    ///
    /// 임계 **미달**로 시드한다 — `update` 는 그때만 `ensureEggPrefetch` 를 띄운다(임계 이상이면
    /// `hatchIfNeeded` 로 간다). 인덱스 후보를 2개 넣고 **롤 결과가 선택 종과 다른지 단언**한다:
    /// 같으면 대입이 무해한 no-op 이라 가드 유무를 구분하지 못한다.
    func testPickDuringSpeciesRollIsNotOverwritten() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon), pickGraduated(piyomon)]
        seed.eggUsage = 0                       // 임계 미달 → update 가 프리패치를 띄운다
        seed.usedSinceInstall = 20_000_000_000
        // 롤은 이 시드에서 vmon 을 고른다(`testSpeciesRollPicksSomethingOtherThanThePick` 가 고정).
        // 그래서 **선택은 piyomon** 으로 한다 — 같은 종을 고르면 대입이 no-op 이라 가드를 구분 못 한다.
        let gated = GatedPickProvider(value: pickLine(piyomon),
                                      indexIDs: [vmon.baseID, piyomon.baseID].sorted())
        gated.gateIndex()                       // 롤을 await 에 붙잡아 둔다
        let s = try store(gated, seed: seed)

        // 프리패치가 종 롤에 진입해 멈춘 창을 만든다.
        s.update(todayTokensByProvider: ["claude_code": 0], todayDate: "2026-09-29",
                 monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        await gated.waitUntilIndexing()
        XCTAssertNil(s.state.pendingHatchID, "롤이 이미 끝났다 — 경합 창이 아니다")

        // 창 안에서 사용자가 종을 고른다.
        XCTAssertTrue(s.pickHatchSpecies(baseID: piyomon.baseID), "경합 창에서 선택이 거절됐다")
        XCTAssertEqual(s.state.pendingHatchID, piyomon.baseID)

        // 롤을 풀어준다 — 여기서 가드가 없으면 롤 결과가 선택을 덮는다.
        gated.releaseIndex()
        gated.release()
        await gated.settle()

        XCTAssertEqual(s.state.pendingHatchID, piyomon.baseID,
                       "종 롤이 복귀해 사용자 선택을 덮었다 — ensureEggPrefetch 의 재확인 가드가 없다")

        // 선택 종이 그대로 부화하는지까지 본다(필드만 맞고 부화가 다르면 의미가 없다).
        func observe(_ tokens: Int) {
            s.update(todayTokensByProvider: ["claude_code": tokens], todayDate: "2026-09-29",
                     monthTotal: tokens, burnTier: .normal, limitWarning: false, hasUsageData: true)
        }
        observe(0)
        observe(DigimonBalance.eggHatchThreshold)
        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.baseID, piyomon.baseID, "선택하지 않은 종이 부화했다")
    }

    /// 위 경합 테스트가 **가드 유무를 구분할 수 있는 조건**인지 고정한다 — 같은 시드에서 롤이
    /// 실제로 무엇을 고르는지 본다. 롤 결과가 위에서 고르는 종과 같아지면 대입이 no-op 이 되어
    /// 그쪽 단언이 조용히 공허해지므로, 이 대조가 먼저 깨져서 알려주게 둔다.
    /// (실측으로 발견한 함정이다: 처음엔 둘 다 vmon 이라 경합 테스트가 거짓 green 이었다.)
    func testSpeciesRollPicksSomethingOtherThanThePick() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon), pickGraduated(piyomon)]
        seed.eggUsage = 0
        seed.usedSinceInstall = 20_000_000_000
        let gated = GatedPickProvider(value: pickLine(vmon),
                                      indexIDs: [vmon.baseID, piyomon.baseID].sorted())
        let s = try store(gated, seed: seed)   // 게이트 없음 = 롤이 그대로 완주

        s.update(todayTokensByProvider: ["claude_code": 0], todayDate: "2026-09-29",
                 monthTotal: 0, burnTier: .normal, limitWarning: false, hasUsageData: true)
        await gated.settle()

        let rolled = try XCTUnwrap(s.state.pendingHatchID, "롤이 종을 정하지 않았다")
        XCTAssertEqual(rolled, vmon.baseID,
                       "롤 결과가 바뀌었다 — 위 경합 테스트가 고르는 종(piyomon)과 같아지면 대입이 "
                       + "no-op 이 되어 그쪽 단언이 공허해진다. 시드나 후보를 조정해 서로 다르게 유지할 것")
    }

    // MARK: ⑤ 선택 부화는 방생이 아니다

    /// `isReleased`/`isArmored` 가 서면 그 종이 죠그레스 파트너 자격을 잃어 팔라딘 모드 경로가 끊긴다.
    /// 개수가 아니라 **구성원**으로 단언한다 — 개수는 항목이 교체돼도 통과한다.
    func testPickedHatchNeverMarksReleasedOrArmored() async throws {
        let s = try eggStore(owning: [vmon], eggUsage: DigimonBalance.eggHatchThreshold)
        let before = Set(s.state.dex.map(\.id))

        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        await s.hatchIfNeeded()
        XCTAssertNotNil(s.state.active)

        XCTAssertEqual(Set(s.state.dex.map(\.id)), before,
                       "선택 부화가 도감 항목을 추가/제거했다 — 방생 기록이 섞였다")
        XCTAssertEqual(s.state.dex.filter(\.isReleased).map(\.id), [],
                       "선택 부화가 방생 플래그를 세웠다")
        XCTAssertEqual(s.state.dex.filter(\.isArmored).map(\.id), [],
                       "선택 부화가 아머 플래그를 세웠다")
        XCTAssertNil(s.state.active?.armorID, "선택 부화가 아머를 입혔다")
        // 파트너 자격이 살아 있어야 죠그레스 경로가 끊기지 않는다.
        XCTAssertTrue(s.hasJogressPartnerRecord(vmon.stages.last!.id),
                      "선택 부화 후 기존 졸업 기록이 파트너 자격을 잃었다")
    }

    // MARK: ⑥ 보증 등급(eggTier) — 선택이 보증을 깨지 않는다

    /// 보증 미달 라인은 **후보에서 빠진다**. `hatchCore` 의 마지막 관문과 같은 비교를 쓰므로,
    /// 고른 종이 그 관문에 걸려 버려지는 일이 구조적으로 불가능하다(토큰 낭비 없음).
    func testGuaranteeFiltersCandidatesBelowTier() throws {
        let s = try eggStore(owning: DigimonData.lines, eggTier: .rare)
        let rarities = Set(s.babyPicks.map(\.rarity))
        XCTAssertEqual(rarities, [.rare, .legendary],
                       "희귀 이상 보증인데 하위 등급 라인이 후보에 남았다")
        // 구성원으로 확인 — common/uncommon base 가 하나라도 남으면 보증이 깨진다.
        let belowTier = DigimonData.lines.filter { $0.rarity.sortRank < Rarity.rare.sortRank }
            .map(\.baseID)
        XCTAssertFalse(belowTier.isEmpty, "하위 등급 라인이 없으면 단언이 공허하다")
        for id in belowTier {
            XCTAssertFalse(s.babyPicks.contains { $0.baseID == id }, "#\(id) 가 보증을 통과했다")
        }
    }

    /// 게이트도 보증을 재조회한다 — 후보 목록만 좁히면 참칭 호출자가 보증을 깬다.
    func testPickingBelowTierSpeciesIsRejected() throws {
        let s = try eggStore(owning: DigimonData.lines, eggTier: .rare)
        XCTAssertFalse(s.pickHatchSpecies(baseID: piyomon.baseID),   // common
                       "희귀 보증 알에서 common 라인 선택이 통과했다")
        XCTAssertNil(s.state.pendingHatchID)
        // 보증을 만족하는 라인은 통과한다(위 거절이 "전부 거절"이 아님을 고정).
        XCTAssertTrue(s.pickHatchSpecies(baseID: patamon.baseID))    // rare
        XCTAssertEqual(s.state.pendingHatchID, patamon.baseID)
    }

    /// 보증 알에서 선택해 부화해도 보증은 지켜지고 소비된다 — `hatchCore` 의 관문을 그대로 탄다.
    func testPickedHatchHonoursAndConsumesGuarantee() async throws {
        let s = try eggStore(owning: DigimonData.lines, eggTier: .rare,
                             eggUsage: DigimonBalance.eggHatchThreshold)
        XCTAssertTrue(s.pickHatchSpecies(baseID: agumon.baseID))   // legendary ≥ rare
        await s.hatchIfNeeded()
        XCTAssertEqual(s.state.active?.baseID, agumon.baseID)
        XCTAssertEqual(s.state.active?.rarity, .legendary)
        XCTAssertNil(s.state.eggTier, "부화가 보증을 소비하지 않았다")
    }

    /// 보증이 후보를 전부 걸러내면 진입점을 숨긴다(빈 화면 방지).
    ///
    /// 티어는 `.rare` 를 쓴다 — `.legendary` 는 `SaveTransfer.sanitized` 가 떨궈낸다
    /// (`captureRateCeiling == nil`, "전설 전용 알은 팔지 않는다"). 실측으로 확인한 제약이라
    /// 여기서 전설을 시드하면 보증이 없는 알이 되어 단언이 무의미해진다.
    func testGuaranteeThatClearsAllCandidatesHidesEntryPoint() throws {
        let s = try eggStore(owning: [piyomon], eggTier: .rare)   // piyomon = common < rare
        XCTAssertEqual(s.state.eggTier, .rare, "보증이 정규화 단계에서 떨어졌다 — 단언이 공허하다")
        XCTAssertEqual(s.babyPicks, [])
        XCTAssertFalse(s.canPickHatchSpecies)
    }

    // MARK: ⑦ 표시 접근자

    /// 선택 예고는 **후보 안의 종**일 때만 노출한다 — 프리패치 롤까지 보여주면 랜덤 부화의 정답을
    /// 알이 스스로 알려준다.
    func testPickedNameOnlyRevealsCandidates() throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon)]
        seed.pendingHatchID = agumon.baseID   // 도감에 없는 종 = 프리패치 롤
        let provider = PickStubProvider(
            lines: Dictionary(uniqueKeysWithValues: DigimonData.lines.map { ($0.baseID, pickLine($0)) }))
        let s = try store(provider, seed: seed)
        XCTAssertNil(s.pickedHatchBaseID, "프리패치 롤이 예고로 노출됐다")
        XCTAssertNil(s.pickedHatchName)

        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        XCTAssertEqual(s.pickedHatchBaseID, vmon.baseID)
        XCTAssertEqual(s.pickedHatchName, CompanionStore.dataName(vmon.baseID, .ko))
    }

    /// 활성 개체가 있으면 예고도 없다(알이 없으므로).
    func testPickedNameIsNilWithActive() async throws {
        let s = try eggStore(owning: [vmon], eggUsage: DigimonBalance.eggHatchThreshold)
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        await s.hatchIfNeeded()
        XCTAssertNil(s.pendingHatchSpeciesID)
        XCTAssertNil(s.pickedHatchBaseID)
    }

    /// 같은 종을 두 번 고르면 상태는 그대로 — 뷰가 재선택을 막지 않아도 흔들리지 않는다.
    func testRepeatingTheSamePickKeepsState() throws {
        let s = try eggStore(owning: [vmon])
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID))
        XCTAssertEqual(s.state.pendingHatchID, vmon.baseID)
    }

    /// 재선택은 **부화 재시도까지** 건다 — 직전 시도가 실패해 지연 상태로 남아 있으면 버튼이
    /// 성공을 보고하고 화면을 닫은 뒤 아무 일도 안 일어나는 죽은 버튼이 된다.
    ///
    /// 지연 상태는 프로덕션 경로로 만든다(테스트 전용 세터를 추가하지 않는다): 라인을 하나도 모르는
    /// provider 로 한 번 부화를 시도하면 `hatchCore` 의 fetch 실패 분기가 `isHatchRetryDelayed` 를
    /// 세우고 `pendingHatchID` 는 그대로 남긴다 — 사용자가 실제로 겪는 그 상태다.
    func testRepeatingThePickRetriesAfterAFailedHatch() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        seed.dex = [pickGraduated(vmon)]
        seed.pendingHatchID = vmon.baseID
        seed.eggUsage = DigimonBalance.eggHatchThreshold
        seed.usedSinceInstall = 20_000_000_000
        // 라인을 하나도 모르는 provider → 모든 fetch 가 throw 한다.
        let failing = PickStubProvider(lines: [:])
        let s = try store(failing, seed: seed)

        await s.hatchIfNeeded()
        XCTAssertNil(s.state.active, "실패해야 할 부화가 성공했다 — 아래 단언이 공허해진다")
        XCTAssertTrue(s.isHatchRetryDelayed, "지연 상태를 만들지 못했다 — 단언이 공허하다")
        XCTAssertEqual(s.state.pendingHatchID, vmon.baseID, "실패가 선택을 버렸다")

        // 같은 종 재선택 — 상태는 그대로지만 지연 문구는 걷히고 부화가 다시 걸려야 한다.
        XCTAssertTrue(s.pickHatchSpecies(baseID: vmon.baseID), "같은 종 재선택이 거절됐다")
        XCTAssertFalse(s.isHatchRetryDelayed, "재선택이 지연 문구를 걷어내지 않았다")
        XCTAssertEqual(s.state.pendingHatchID, vmon.baseID)
    }

    // MARK: ⑧ 문구 — 7개 언어 전부

    func testPickStringsExistInEverySupportedLanguage() {
        for lang in AppLanguage.allCases {
            let l = L(lang)
            XCTAssertFalse(l.eggPickEntry.isEmpty, "\(lang) eggPickEntry")
            XCTAssertFalse(l.eggPickTitle.isEmpty, "\(lang) eggPickTitle")
            XCTAssertFalse(l.eggPickHint.isEmpty, "\(lang) eggPickHint")
            XCTAssertFalse(l.eggPickConfirm.isEmpty, "\(lang) eggPickConfirm")
            XCTAssertFalse(l.eggPickEmpty.isEmpty, "\(lang) eggPickEmpty")
            XCTAssertTrue(l.eggPickChosen("아구몬").contains("아구몬"), "\(lang) eggPickChosen")
            XCTAssertTrue(l.eggPickGuaranteeNote(l.rarityLabel(.rare))
                .contains(l.rarityLabel(.rare)), "\(lang) eggPickGuaranteeNote")
        }
        // 언어별로 실제 다른 문구인지 — `t(...)` 인자를 잘못 복사하면 전부 같은 문자열이 된다.
        XCTAssertNotEqual(L(.ko).eggPickTitle, L(.en).eggPickTitle)
        XCTAssertNotEqual(L(.ja).eggPickTitle, L(.de).eggPickTitle)
    }

    /// 팝오버 재오픈은 항상 Home — 선택 화면이 남아 있으면 탭 피커가 안 보이는 화면에 갇힌다.
    func testNavigationResetLeavesEggPicker() {
        let nav = PopoverNavigation()
        nav.showEggPicker = true
        nav.reset()
        XCTAssertFalse(nav.showEggPicker)
    }

    // MARK: ⑨ 배선 — 게이트가 화면에서 도달 가능한가

    /// `CompanionHeader.onPickSpecies` 는 기본값이 nil("진입점을 그리지 않는다")이고 프로덕션
    /// 호출부가 **단 한 줄**이다. 그 인자를 지우면 기능 전체가 무음으로 사라지는데 store 단위
    /// 테스트는 전부 green 으로 남는다(게이트는 잘 덮여 있지만 게이트의 **도달 가능성**은 아니다).
    /// 같은 파일의 `PopoverNavigationTests.testPopoverFooterTogglesFloatingPet…` 과 같은 방식으로
    /// 소스를 텍스트로 읽어 배선을 고정한다.
    func testPopoverWiresTheEggPickerEntryPoint() throws {
        let source = try String(contentsOf: Self.popoverSource, encoding: .utf8)
        XCTAssertTrue(source.contains("onPickSpecies:"),
                      "CompanionHeader 에 onPickSpecies 를 넘기지 않으면 진입점이 사라진다")
        XCTAssertTrue(source.contains("nav.showEggPicker = true"),
                      "진입점이 선택 화면을 열지 않는다")
        XCTAssertTrue(source.contains("EggPickerView("),
                      "선택 화면이 팝오버 body 에 연결되지 않았다")
        // 시트로 되돌아가면 transient 팝오버가 닫힐 때 고아 시트가 이후 클릭을 먹는다.
        XCTAssertFalse(source.contains(".sheet("), "팝오버에 .sheet 가 들어왔다")
    }

    /// 선택 화면 자체도 시트/얼럿을 쓰지 않는다.
    func testEggPickerUsesNoSheetOrAlert() throws {
        let source = try String(contentsOf: Self.pickerSource, encoding: .utf8)
        XCTAssertFalse(source.contains(".sheet("), "선택 화면에 .sheet 가 들어왔다")
        XCTAssertFalse(source.contains(".alert("), "선택 화면에 .alert 가 들어왔다")
        XCTAssertTrue(source.contains("PopoverMetrics.contentWidth"),
                      "콘텐츠 폭을 고정하지 않으면 팝오버에서 좌우로 잘린다")
    }

    private static let uiDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // DigiTokenBarTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // repo root
        .appendingPathComponent("Sources/DigiTokenBar/UI")
    private static let popoverSource = uiDirectory.appendingPathComponent("PopoverView.swift")
    private static let pickerSource = uiDirectory.appendingPathComponent("EggPickerView.swift")
}
