import XCTest
@testable import DigiTokenBar

// MARK: 파킹된 pre-roll 의 졸업 재검사 (`CompanionState.restoreParkedEggGuarantee`)
//
// 보증 알의 pre-roll 이 파킹된 동안 그 라인을 보관함에서 꺼내 졸업시키면, 방금 졸업한 라인이
// 그대로 부화했다 — `CompanionStore.chooseBase` 의 졸업 제외(docs/GAME-DESIGN.md §2)를 우회하는
// 유일한 **정상 UI** 경로다(손편집·수입 세이브가 아니다). `graduate()` 가 한 함수 안에서
// `collectedFinals.insert` → `restoreParkedEggGuarantee()` 순서로 돌고, 복원의 "보증 없는 알"
// 분기가 `parkedPendingHatchID` 를 졸업 여부로 재검사하지 않았다.
//
// 폐기 조건은 **둘의 AND** 라서 네 칸을 전부 본다 — 세 칸만 보면 어느 한쪽 조건을 빼는 뮤테이션이
// 살아남는다:
//   ① 프리패치 롤 + 졸업   → 폐기 (핵심 결함)
//   ② 사용자 선택 + 졸업   → 복원 (면제가 실제로 동작)
//   ③ 프리패치 롤 + 미졸업 → 복원 (가드가 과하게 잡지 않는다)
//   ④ 사용자 선택 + 미졸업 → 복원 (둘 다 거짓인 대조군)
// 여기에 pre-roll 부재 축과, `graduate()` 실경로를 타는 통합 축을 더한다.

@MainActor
final class ParkedPreRollGraduationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct StubProvider: DigimonLineProviding {
        let value: EvoLine
        func line(baseSpeciesID: Int) async throws -> EvoLine { value }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
    }

    /// 브이몬 라인(349→358) — `DigimonData.lines` 의 실제 id. 보관 개체가 stageIndex 1(말단)이라
    /// 임계 도달 시 진화 없이 곧장 `graduate()` 로 떨어진다(`StoredMonTests` 와 같은 구성).
    private let vmonFinalLine = EvoLine(baseID: 349, tree: EvoNode(speciesID: 349, children: [
        EvoNode(speciesID: 358, children: [])
    ]), rarity: .uncommon, names: [349: ["ko": "브이몬"], 358: ["ko": "엑스브이몬"]])

    // MARK: 상태 단위 축 — 복원 분기 네 칸

    /// 파킹 묶음(보증 + pre-roll + 선택 표시)을 심은 알 상태. 졸업 기록은 `"baseID:finalID"` 형식이고
    /// `hasCollectedFinal(forBaseID:)` 가 접두로 판정하므로 finalID 는 아무 값이어도 된다.
    private func parkedState(preRoll: Int?, userPick: Bool, graduatedBaseIDs: [Int]) -> CompanionState {
        var s = CompanionState()
        s.parkedEggTier = .rare
        s.parkedPendingHatchID = preRoll
        s.parkedPendingHatchIsUserPick = userPick
        s.collectedFinals = Set(graduatedBaseIDs.map { "\($0):358" })
        return s
    }

    /// ① [핵심] 졸업한 라인의 **프리패치** pre-roll 은 복원에서 폐기된다 — 보증만 돌아온다.
    ///
    /// 폐기 후 비는 것은 pre-roll 뿐이다. 보증까지 같이 날리면 산 물건이 꺼내기 한 번으로 증발하므로
    /// 두 값을 **함께** 단언한다(nil 만 보면 복원 전체를 죽이는 뮤테이션도 통과한다).
    func testGraduatedPrefetchPreRollIsDiscardedOnRestore() {
        var s = parkedState(preRoll: 349, userPick: false, graduatedBaseIDs: [349])
        s.restoreParkedEggGuarantee()

        XCTAssertNil(s.pendingHatchID, "졸업한 라인의 프리패치 pre-roll 이 그대로 복원됐다 — 졸업 제외 우회")
        XCTAssertFalse(s.pendingHatchIsUserPick)
        XCTAssertEqual(s.eggTier, .rare, "pre-roll 만 버려야 하는데 산 보증까지 날아갔다")
        // 파킹 자리는 어느 분기로 가도 비워진다(재복원 = 영구 프리미엄).
        XCTAssertNil(s.parkedEggTier)
        XCTAssertNil(s.parkedPendingHatchID)
        XCTAssertFalse(s.parkedPendingHatchIsUserPick)
    }

    /// ② 졸업한 라인이라도 **사용자가 직접 고른** pre-roll 은 복원된다 — 면제가 실제로 동작한다.
    ///
    /// 졸업한 라인을 직접 고르는 것은 의도된 동작이다(`ownsSpecies` 가 `dex.chainOrder` 를 보므로
    /// 졸업분은 소유 → `babyPicks` 후보에 뜬다). 여기서 버리면 사용자가 방금 고른 종이 설명 없이
    /// 갈아치워진다. 이 축이 없으면 `!pendingHatchIsUserPick` 를 지우는 뮤테이션이 살아남는다.
    func testGraduatedUserPickedPreRollSurvivesRestore() {
        var s = parkedState(preRoll: 349, userPick: true, graduatedBaseIDs: [349])
        s.restoreParkedEggGuarantee()

        XCTAssertEqual(s.pendingHatchID, 349, "사용자가 직접 고른 종이 졸업했다는 이유로 버려졌다")
        XCTAssertTrue(s.pendingHatchIsUserPick, "선택 표시가 프리패치 롤로 강등됐다")
        XCTAssertEqual(s.eggTier, .rare)
    }

    /// ③ 미졸업 라인의 프리패치 pre-roll 은 복원된다 — 가드가 졸업 여부를 **실제로** 본다.
    /// (졸업 기록은 다른 라인에만 둔다 — 비워 두면 "기록이 비었을 때만 복원"으로도 통과한다.)
    func testUngraduatedPrefetchPreRollSurvivesRestore() {
        var s = parkedState(preRoll: 349, userPick: false, graduatedBaseIDs: [1])
        s.restoreParkedEggGuarantee()

        XCTAssertEqual(s.pendingHatchID, 349, "미졸업 pre-roll 이 버려졌다 — 가드가 과하게 잡는다")
        XCTAssertFalse(s.pendingHatchIsUserPick)
        XCTAssertEqual(s.eggTier, .rare)
    }

    /// ④ 두 조건이 모두 거짓인 대조군(미졸업 + 사용자 선택) — 묶음이 그대로 복원된다.
    func testUngraduatedUserPickedPreRollSurvivesRestore() {
        var s = parkedState(preRoll: 349, userPick: true, graduatedBaseIDs: [1])
        s.restoreParkedEggGuarantee()

        XCTAssertEqual(s.pendingHatchID, 349)
        XCTAssertTrue(s.pendingHatchIsUserPick)
        XCTAssertEqual(s.eggTier, .rare)
    }

    /// pre-roll 이 없는 파킹(보증만 맡긴 경우)은 가드와 무관하다 — 보증만 복원되고 끝.
    /// 졸업 기록이 있어도 새 pre-roll 을 만들어내지 않는다.
    func testParkedRestoreWithoutPreRollIsUnaffected() {
        var s = parkedState(preRoll: nil, userPick: false, graduatedBaseIDs: [349])
        s.restoreParkedEggGuarantee()

        XCTAssertEqual(s.eggTier, .rare, "pre-roll 이 없다고 보증 복원까지 건너뛰었다")
        XCTAssertNil(s.pendingHatchID)
        XCTAssertFalse(s.pendingHatchIsUserPick)
        XCTAssertNil(s.parkedEggTier)
    }

    /// 졸업 재검사는 **충돌 분기까지 번지지 않는다** — 그쪽은 이미 양방향 pre-roll 을 무조건 버리고
    /// 사유가 다른 축(등급 누수)이다. 미졸업 + 사용자 선택이어도 충돌이면 버려지는 것이 기존 계약이다.
    func testTierConflictBranchStillDropsPreRollRegardlessOfGraduation() {
        var s = parkedState(preRoll: 349, userPick: true, graduatedBaseIDs: [1])
        s.eggTier = .uncommon   // 현재 알에도 보증이 있다 → 충돌 분기
        s.pendingHatchID = 349
        s.pendingHatchIsUserPick = true
        s.restoreParkedEggGuarantee()

        XCTAssertEqual(s.eggTier, .rare, "더 높은 보증이 남아야 한다")
        XCTAssertNil(s.pendingHatchID, "충돌 분기는 양방향 pre-roll 을 무조건 버린다")
        XCTAssertFalse(s.pendingHatchIsUserPick)
    }

    // MARK: 수입 경계 축 — `SaveTransfer.sanitized`

    /// 복원 호출부는 **셋**이다(`graduate():820` · `buyEgg():1401` · `SaveTransfer.sanitized:257`).
    /// 가드가 복원 함수 안에 있으므로 수입 경계에서도 함께 발화하는데, 그건 **수용한 설계**다 —
    /// 다른 기기에서 온 세이브의 졸업분 pre-roll 도 같은 결함이라 거기서만 통과시킬 이유가 없다.
    /// 그 수용을 주석으로만 적어 두면 무단언이라, 세 번째 호출부도 여기서 고정한다
    /// (`applySave` 는 `load()` 를 타지 않으므로 이 경계가 유일한 관문이다).
    func testImportBoundaryAlsoDiscardsGraduatedPrefetchPreRoll() {
        var s = parkedState(preRoll: 349, userPick: false, graduatedBaseIDs: [349])
        let out = SaveTransfer.sanitized(s)

        XCTAssertEqual(out.eggTier, .rare, "수입 세이브의 맡긴 보증이 증발했다")
        XCTAssertNil(out.pendingHatchID,
                     "수입 경계에서 졸업분 pre-roll 이 살아 들어왔다 — 같은 우회가 수입으로 열린다")
        XCTAssertFalse(out.pendingHatchIsUserPick)
        XCTAssertNil(out.parkedEggTier)

        // 같은 경계에서 사용자 선택 면제도 유지된다 — 가드가 경계마다 다르게 굴면 안 된다.
        s = parkedState(preRoll: 349, userPick: true, graduatedBaseIDs: [349])
        let picked = SaveTransfer.sanitized(s)
        XCTAssertEqual(picked.pendingHatchID, 349, "수입 경계에서만 사용자 선택이 버려졌다")
        XCTAssertTrue(picked.pendingHatchIsUserPick)
    }

    // MARK: 통합 축 — `graduate()` 실경로

    /// 보증 알 + 보관 개체 1건(349, stageIndex 1 = 말단). pre-roll 은 **보관 개체와 같은 라인**이어야
    /// 결함이 발화한다 — 다른 라인을 쓰면 졸업 기록과 pre-roll 이 어긋나 테스트가 공허해진다.
    private func guaranteedEggWithStoredJSON(preRoll: Int, userPick: Bool) -> String {
        let mon = "{\"baseID\":349,\"pathIDs\":[349,358],\"plannedPathIDs\":[349,358],"
            + "\"stageIndex\":1,\"usedAtStage\":300000000,\"rarity\":\"uncommon\",\"totalForms\":2}"
        return "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":5000,\"spentTokens\":0,\"lastDate\":\"d\",\"active\":null,"
            + "\"eggTier\":\"rare\",\"pendingHatchID\":\(preRoll),"
            + "\"pendingHatchIsUserPick\":\(userPick),"
            + "\"dex\":[],\"stored\":[{\"id\":\"stored-1\",\"mon\":\(mon),"
            + "\"storedAt\":\(now.timeIntervalSince1970)}],\"collectedFinals\":[]}"
    }

    private func store(json: String) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parked-preroll-\(UUID().uuidString).json")
        try? Data(json.utf8).write(to: url)
        return CompanionStore(provider: StubProvider(value: vmonFinalLine), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: 7))
    }

    /// [핵심 통합] `graduate()` 의 실제 호출 순서를 탄다 — 꺼내기로 파킹을 만들고, 꺼낸 그 개체를
    /// 졸업시켜 복원을 유발한다. 파킹 필드를 직접 시드하면 `retrieveStored` 의 쓰기 지점과
    /// `graduate()` 의 `collectedFinals.insert` → 복원 **순서**를 둘 다 건너뛰어, 프로덕션에서
    /// 순서가 뒤바뀌어도(복원이 먼저 돌면 졸업 기록이 아직 없어 가드가 안 걸린다) 초록이 된다.
    func testGraduatingTheParkedPreRollsOwnLineDiscardsItViaGraduatePath() async {
        let s = store(json: guaranteedEggWithStoredJSON(preRoll: 349, userPick: false))
        XCTAssertEqual(s.state.eggTier, .rare, "사전 조건 — 보증 알을 품고 있어야 한다")
        XCTAssertEqual(s.state.pendingHatchID, 349, "사전 조건 — pre-roll 이 보관 개체와 같은 라인이어야 한다")

        // ① 꺼낸다 → 보증과 pre-roll 이 한 묶음으로 파킹된다.
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertEqual(s.state.parkedEggTier, .rare)
        XCTAssertEqual(s.state.parkedPendingHatchID, 349, "사전 조건 — pre-roll 이 파킹돼야 한다")
        XCTAssertFalse(s.state.hasCollectedFinal(forBaseID: 349), "사전 조건 — 아직 졸업 전이어야 한다")

        // ② 꺼낸 개체를 졸업시킨다. `retrieveStored` 가 띄운 `loadCurrentLine()` Task 가 끝나야
        // 졸업 판정이 돈다(`applyUsage` 는 `currentLine == nil` 이면 적립만 하고 반환한다).
        for _ in 0..<200 where s.currentLine == nil { await Task.yield() }
        XCTAssertNotNil(s.currentLine, "사전 조건 — 라인이 로드돼야 졸업 판정이 돈다")
        s.applyUsage(DigimonBalance.graduationTotal(.uncommon))

        // ③ 여기서 **await 하지 않는다** — `graduate()` 말미의 `ensureEggPrefetch` Task 가 돌면
        // 새 롤이 `pendingHatchID` 를 다시 채워(스텁 provider 는 라인이 하나라 졸업 제외의 완화
        // 폴백이 349 를 되돌려 준다) 복원 시점의 관측 창이 사라진다.
        XCTAssertNil(s.state.active, "사전 조건 — 졸업해서 알 상태가 돼야 한다")
        XCTAssertTrue(s.state.hasCollectedFinal(forBaseID: 349), "사전 조건 — 졸업이 기록돼야 한다")
        XCTAssertEqual(s.state.eggTier, .rare, "맡긴 보증이 복원되지 않았다 — 산 보증 증발")
        XCTAssertNil(s.state.pendingHatchID,
                     "방금 졸업한 라인의 pre-roll 이 복원됐다 — 졸업 제외를 우회해 그대로 부화한다")
        XCTAssertFalse(s.state.pendingHatchIsUserPick)
    }

    /// 같은 통합 경로에서 **사용자가 직접 고른** pre-roll 은 졸업 후에도 살아 돌아온다 —
    /// 면제가 상태 단위뿐 아니라 프로덕션 경로에서도 성립한다.
    func testGraduatingAUserPickedParkedPreRollsLineKeepsThePick() async {
        let s = store(json: guaranteedEggWithStoredJSON(preRoll: 349, userPick: true))
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertTrue(s.state.parkedPendingHatchIsUserPick, "사전 조건 — 선택 표시가 파킹돼야 한다")

        for _ in 0..<200 where s.currentLine == nil { await Task.yield() }
        XCTAssertNotNil(s.currentLine, "사전 조건 — 라인이 로드돼야 졸업 판정이 돈다")
        s.applyUsage(DigimonBalance.graduationTotal(.uncommon))

        XCTAssertNil(s.state.active, "사전 조건 — 졸업해서 알 상태가 돼야 한다")
        XCTAssertEqual(s.state.pendingHatchID, 349, "사용자가 직접 고른 종이 졸업으로 버려졌다")
        XCTAssertTrue(s.state.pendingHatchIsUserPick)
        XCTAssertEqual(s.state.eggTier, .rare)
    }
}
