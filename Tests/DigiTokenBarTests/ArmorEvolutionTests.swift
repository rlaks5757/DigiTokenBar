import XCTest
@testable import DigiTokenBar

/// 아머 진화(자유 전환) — 디지멘탈로 아머체가 되고, 아무 때나 사다리로 되돌아온다.
///
/// 라인 스텁은 **실제 데이터의 id** 를 써야 한다: 게이트가 `DigimonData.armorResult` 조회이고
/// 그건 번들 JSON 을 읽으므로, 합성 id(1→2→3)로는 아머 매핑이 아예 존재하지 않는다.
/// V-mon 라인(349 → 358)이 요구사항 시나리오(브이몬 → 화염드라몬 → 브이몬 → 엑스브이몬)와 같다.
private struct ArmorStubProvider: DigimonLineProviding {
    let value: EvoLine
    func line(baseSpeciesID: Int) async throws -> EvoLine { value }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
}

private func armorNode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode {
    EvoNode(speciesID: id, children: children)
}

private func armorLine(base: Int, tree: EvoNode, rarity: Rarity = .uncommon) -> EvoLine {
    var names: [Int: [String: String]] = [:]
    func walk(_ n: EvoNode) {
        // 실제 provider(`DigimonLineProvider`)와 같은 로케일 맵을 싣는다 — `["en": apiName]` 로
        // 스텁하면 프로덕션 경로가 한국어로 바뀌어도 테스트만 영어로 통과해 배선을 못 본다.
        names[n.speciesID] = DigimonData.name(for: n.speciesID)?.localizedNames ?? [:]
        n.children.forEach(walk)
    }
    walk(tree)
    return EvoLine(baseID: base, tree: tree, rarity: rarity, names: names)
}

/// V-mon(349) → XV-mon(358). 아머 결과: courage=305(Fladramon), miracles=315, friendship=312.
private let vmonLine = armorLine(base: 349, tree: armorNode(349, [armorNode(358)]))
/// Tailmon(83) — 데이터상 Child 지만 작중 Adult 급. 레벨 축 판정이면 여기서 깨진다.
private let tailmonLine = armorLine(base: 83, tree: armorNode(83, [armorNode(38)]), rarity: .rare)
/// 아머 매핑이 없는 라인(Agumon 1 → 2 는 데이터에 없는 조합) — 게이트가 막아야 한다.
private let agumonLine = armorLine(base: 1, tree: armorNode(1, [armorNode(2)]), rarity: .common)

private let armorFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
final class ArmorEvolutionTests: XCTestCase {

    /// state 는 `private(set)` 이라 테스트는 **파일 시드**로 초기 상태를 준다(기존 픽스처 패턴).
    ///
    /// 언어는 **시드에 명시 고정**한다. `CompanionState.language` 기본값은 `.systemDefault` 라
    /// `Locale.preferredLanguages` 를 읽으므로, 고정하지 않으면 개발자 맥(ko)에서는 통과하고
    /// 영어 CI 러너에서는 영문 표기가 나와 이름 단언이 깨진다(테스트가 주변 환경에 기댄 것).
    /// `setLanguage` 가 아니라 시드로 주는 이유: 그건 `save()` 를 불러 세이브를 덮어써서
    /// `testNamesSurviveRestartBeforeLineLoads` 의 "재시작 직후 복원" 전제를 흐린다.
    private func store(_ line: EvoLine, seed state: CompanionState = CompanionState(),
                       language: AppLanguage = .ko, rngSeed: UInt64 = 7) throws -> CompanionStore {
        var state = state
        state.language = language
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("armor-\(UUID().uuidString).json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: ArmorStubProvider(value: line),
                              clock: { armorFixedNow }, fileURL: url, rng: SeededRNG(seed: rngSeed))
    }

    /// 아머 진화가 가능한 상태 — 부화 + 디지멘탈 전량 지급(비소모라 개수는 1개면 충분하다).
    private func hatched(_ line: EvoLine) async throws -> CompanionStore {
        var seed = CompanionState()
        for kind in ItemKind.allCases where kind.digimental != nil {
            seed.inventory[kind.rawValue] = 1
        }
        seed.usedSinceInstall = 20_000_000_000   // 알 구매 테스트용 잔액
        let s = try store(line, seed: seed)
        await s.hatch(baseID: line.baseID)
        return s
    }

    // MARK: 데이터 전제

    /// 스텁이 아니라 실제 데이터가 이 시나리오를 지지하는지 먼저 고정한다 —
    /// 데이터가 바뀌면 아래 테스트들이 "왜" 실패하는지 여기서 바로 드러난다.
    func testArmorDataForVmonAndTailmon() {
        XCTAssertEqual(DigimonData.armorResult(childID: 349, digimental: .courage), 305)
        XCTAssertEqual(DigimonData.armorResult(childID: 349, digimental: .miracles), 315)
        XCTAssertEqual(DigimonData.armorResult(childID: 83, digimental: .light), 326)
        XCTAssertNil(DigimonData.armorResult(childID: 349, digimental: .light))
        XCTAssertNil(DigimonData.armorResult(childID: 358, digimental: .courage),
                     "아머체·성숙기는 armorResults 의 childID 가 아니다")
    }

    // MARK: ① 요구사항 시나리오 전체

    /// V-mon → 용기 → Fladramon(305) → 해제 → V-mon → XP → XV-mon(358).
    /// 자유 전환의 핵심: 아머를 거쳤어도 정규 진화 경로가 그대로 남아 있어야 한다.
    func testRoundTripThenRegularEvolution() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertEqual(s.currentSpeciesID, 349)

        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.displaySpeciesID, 305, "표시 축은 아머체")
        XCTAssertEqual(s.currentSpeciesID, 349, "성장 축은 계속 사다리 종")

        XCTAssertTrue(s.removeArmor())
        XCTAssertEqual(s.displaySpeciesID, 349)
        XCTAssertNil(s.armorSpeciesID)

        s.applyUsage(s.threshold)
        XCTAssertEqual(s.currentSpeciesID, 358, "아머를 거쳐도 정규 진화가 그대로 성립한다")
        XCTAssertEqual(s.displaySpeciesID, 358)
    }

    // MARK: ② 왕복 불변성 (악용 가드)

    /// 착용 → 해제 후 사다리 7개 필드가 전부 동일. 이 하나가 무한 왕복 파밍을 닫는다 —
    /// XP·임계값·성장 프로필 어느 축으로도 이득이 생기지 않는다.
    func testArmorToggleLeavesEveryLadderFieldUntouched() async throws {
        let s = try await hatched(vmonLine)
        s.applyUsage(1_000_000)   // 진행 중간에서 왕복해야 usedAtStage 이월/리셋이 드러난다

        func snapshot() -> [String] {
            guard let a = s.state.active else { return [] }
            return ["\(a.pathIDs)", "\(a.plannedPathIDs)", "\(a.stageIndex)", "\(a.usedAtStage)",
                    "\(a.totalForms)", "\(a.hasGrowthBoost)", a.profile?.instanceID ?? "nil"]
        }
        let before = snapshot()
        let thresholdBefore = s.threshold

        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(snapshot(), before, "착용이 사다리 필드를 바꿨다")
        XCTAssertEqual(s.threshold, thresholdBefore, "착용이 임계값을 바꿨다")

        XCTAssertTrue(s.useDigimental(.digimentalMiracles))   // 교체
        XCTAssertEqual(s.displaySpeciesID, 315)
        XCTAssertEqual(snapshot(), before, "교체가 사다리 필드를 바꿨다")

        XCTAssertTrue(s.removeArmor())
        XCTAssertEqual(snapshot(), before, "해제가 사다리 필드를 바꿨다")
        XCTAssertEqual(s.threshold, thresholdBefore, "해제가 임계값을 바꿨다")
    }

    /// 왕복 10회를 해도 진행도가 1 도 늘지 않는다 — 위 필드 단언의 반복 버전.
    func testRepeatedTogglingGrantsNoProgress() async throws {
        let s = try await hatched(vmonLine)
        s.applyUsage(500_000)
        let progressBefore = s.state.active?.usedAtStage
        for _ in 0..<10 {
            XCTAssertTrue(s.useDigimental(.digimentalCourage))
            XCTAssertTrue(s.removeArmor())
        }
        XCTAssertEqual(s.state.active?.usedAtStage, progressBefore)
        XCTAssertEqual(s.currentSpeciesID, 349, "왕복만으로 진화하지 않는다")
    }

    // MARK: ③ 디지멘탈 비소모

    func testDigimentalIsNotConsumed() async throws {
        let s = try await hatched(vmonLine)
        for _ in 0..<3 {
            XCTAssertTrue(s.useDigimental(.digimentalCourage))
            XCTAssertTrue(s.removeArmor())
        }
        XCTAssertEqual(s.itemCount(.digimentalCourage), 1, "디지멘탈은 열쇠형 — 소모되지 않는다")
    }

    // MARK: ④ 아머 착용 중 성장이 멈추지 않는다 (currentID 오버라이드 회귀 가드)

    /// 가장 빠지기 쉬운 버그: `currentID` 가 아머체를 반환하면 `line.tree.node(withID:)` 가 nil 이라
    /// `applyUsage` 가 조용히 `break` 하고 성장이 영구 정지한다. 로그도 에러도 없이.
    func testGrowthContinuesWhileArmored() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))

        s.applyUsage(1_000_000)
        XCTAssertEqual(s.state.active?.usedAtStage, 1_000_000, "아머 착용 중 XP 적립이 멈췄다")
        XCTAssertGreaterThan(s.progress, 0)
    }

    /// 아머 착용 중 정규 진화 조건을 채우면 **자동 해제 후 진화**한다(사용자 확정 ③).
    func testRegularEvolutionWhileArmoredAutoRemovesArmor() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.displaySpeciesID, 305)

        s.applyUsage(s.threshold)

        XCTAssertNil(s.armorSpeciesID, "정규 진화가 아머를 자동 해제해야 한다")
        XCTAssertEqual(s.currentSpeciesID, 358)
        XCTAssertEqual(s.displaySpeciesID, 358, "진화 후에도 아머체가 남아 있으면 안 된다")
    }

    // MARK: ⑤ 게이트 — 레벨이 아니라 매핑 부재로 판정

    /// Tailmon(83)은 데이터상 Child 지만 작중 Adult 급이다. `DigiLevel == .child` 로 게이트를
    /// 구현했다면 여기가 통과하고, 매핑 조회로 구현했다면 실패한다 — 즉 이 단언이 두 구현을 가른다.
    func testTailmonCanArmorEvolveDespiteAmbiguousLevel() async throws {
        let s = try await hatched(tailmonLine)
        XCTAssertTrue(s.canArmorEvolve(.digimentalLight))
        XCTAssertTrue(s.useDigimental(.digimentalLight))
        XCTAssertEqual(s.displaySpeciesID, 326)
    }

    /// 매핑 없는 종(Agumon) + 디지멘탈 → 사용 불가. 성숙기 이상도 같은 경로로 막힌다.
    func testNoMappingBlocksUse() async throws {
        let s = try await hatched(agumonLine)
        XCTAssertFalse(s.canArmorEvolve(.digimentalCourage))
        XCTAssertFalse(s.useDigimental(.digimentalCourage))
        XCTAssertNil(s.armorSpeciesID)
    }

    /// 성숙기(XV-mon, 358)로 진화한 뒤에는 아머 진화 대상이 아니다.
    func testAdultStageBlocksArmorEvolution() async throws {
        let s = try await hatched(vmonLine)
        s.applyUsage(s.threshold)
        XCTAssertEqual(s.currentSpeciesID, 358)
        XCTAssertFalse(s.canArmorEvolve(.digimentalCourage))
        XCTAssertFalse(s.useDigimental(.digimentalCourage))
    }

    /// 재고 0 이면 못 쓴다 — 비소모라도 "산 적 없는" 디지멘탈은 쓸 수 없다.
    /// `hatched` 는 디지멘탈을 전량 지급하므로 여기서만 빈 인벤토리로 직접 띄운다.
    func testZeroInventoryBlocksUse() async throws {
        let s = try store(vmonLine)
        await s.hatch(baseID: vmonLine.baseID)
        XCTAssertFalse(s.canArmorEvolve(.digimentalCourage))
        XCTAssertFalse(s.useDigimental(.digimentalCourage))
    }

    // MARK: ⑥ 교체 (swap)

    /// 아머 A → 아머 B 직접 전환. 기준은 **사다리 종**이므로 해제 없이도 성립해야 한다
    /// (아머체 기준으로 조회하면 armorResults 에 childID 가 없어 항상 nil 이 된다).
    func testSwapBetweenArmorsWithoutRemoving() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.displaySpeciesID, 305)
        XCTAssertTrue(s.useDigimental(.digimentalFriendship))
        XCTAssertEqual(s.displaySpeciesID, 312)
        XCTAssertEqual(s.currentSpeciesID, 349)
    }

    // MARK: ⑦ 도감

    /// 아머 진화 → 해제해도 도감에 남는다(도감은 쌓이기만 한다).
    func testArmorDexEntrySurvivesRemoval() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertTrue(s.removeArmor())

        XCTAssertTrue(s.state.ownsSpecies(305), "해제 후에도 보유 종이어야 한다")
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 305 }, "도감 격자에 아머체가 없다")
        let armorEntries = s.state.dex.filter(\.isArmored)
        XCTAssertEqual(armorEntries.count, 1)
        XCTAssertEqual(armorEntries.first?.rarity, .uncommon, "희귀도는 개체에서 싣는다")
        XCTAssertNotNil(armorEntries.first?.caughtAt, "정렬 키가 없으면 동행 기록 맨 뒤로 가라앉는다")
    }

    /// 도감 칸이 `#305` 로 남지 않는다 — 이름을 항목 생성 시점에 심어야 한다.
    /// 안 심으면 표시도 깨지고 `needsNamesRefresh` 가 영영 true 라 백필이 매번 라인을 조회한다
    /// (사다리 라인엔 아머체가 없어 절대 채워지지 않는다).
    func testArmorDexEntryCarriesName() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        guard let entry = s.state.dex.first(where: \.isArmored) else {
            return XCTFail("아머 도감 항목 없음")
        }
        // 시드가 ko 로 고정돼 있다(호스트 로케일 무관) — 영문이 나오면 로케일 해석이 끊긴 것이다.
        XCTAssertEqual(s.dexStoredChainNames(entry)?[305], "화염드라몬")
        XCTAssertFalse(entry.needsNamesRefresh, "백필이 영구히 재조회하게 두면 안 된다")
        XCTAssertEqual(s.dexSpecies.first { $0.id == 305 }?.name, "화염드라몬")
        s.setLanguage(.en)
        XCTAssertEqual(s.dexSpecies.first { $0.id == 305 }?.name, "Fladramon", "영어는 영문 표기")
    }

    /// 같은 아머체를 다시 착용해도 동행 기록에 같은 줄이 반복되지 않는다.
    func testReEquippingDoesNotDuplicateDexRows() async throws {
        let s = try await hatched(vmonLine)
        for _ in 0..<4 {
            XCTAssertTrue(s.useDigimental(.digimentalCourage))
            XCTAssertTrue(s.removeArmor())
        }
        XCTAssertEqual(s.state.dex.filter(\.isArmored).count, 1)
    }

    /// 아머 도감 항목의 id 는 졸업 항목과 충돌하지 않는다 — 둘 다 profile.instanceID 를 쓰면
    /// `isActiveDexEntry`/`dexResolveChainNames` 의 id 조회가 엉뚱한 항목을 집는다.
    func testArmorEntryIDDoesNotCollideWithGraduationEntry() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        s.applyUsage(Int(1e12))   // 끝까지 밀어 졸업
        XCTAssertNil(s.state.active, "졸업하지 않았다")
        let ids = s.state.dex.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "도감 항목 id 가 중복됐다")
    }

    /// 아머 진화는 `collectedFinals` 를 건드리지 않는다 — 끝까지 키운 게 아니고,
    /// 부화 가중치(미수집 부스트)에 영향을 주면 안 된다.
    func testArmorDoesNotTouchCollectedFinals() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertTrue(s.state.collectedFinals.isEmpty)
    }

    // MARK: ⑧ 졸업 — 아머체가 최종체로 기록되면 안 된다

    func testGraduationRecordsLadderFinalNotArmor() async throws {
        let s = try await hatched(vmonLine)
        s.applyUsage(s.threshold)                 // → XV-mon(358)
        XCTAssertEqual(s.currentSpeciesID, 358)
        s.applyUsage(Int(1e12))                   // 졸업

        guard let graduated = s.state.dex.first(where: { !$0.isArmored }) else {
            return XCTFail("졸업 항목 없음")
        }
        XCTAssertEqual(graduated.finalID, 358, "아머체가 졸업 최종체로 기록됐다")
        // chainOrder 도 같이 고정한다 — `dexSpecies`/`ownsSpecies` 는 finalID 가 아니라 이걸 읽으므로,
        // finalID 만 단언하면 아머체가 졸업 체인에 새어 들어가도 초록으로 통과한다.
        XCTAssertEqual(graduated.chainOrder, [349, 358], "아머체가 졸업 체인에 섞였다")
        XCTAssertNil(s.state.active)
    }

    /// 졸업하면 아머 상태도 함께 사라진다(`state.active = nil` 로 수명주기가 자동으로 맞는다).
    func testGraduationClearsArmorState() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        s.applyUsage(Int(1e12))
        XCTAssertNil(s.armorSpeciesID)
        XCTAssertNil(s.displaySpeciesID)
    }

    /// 알 구매(놓아주기)도 아머를 이월시키지 않는다.
    func testBuyingEggClearsArmorState() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.armorSpeciesID)
        XCTAssertNil(s.displaySpeciesID)
    }

    // MARK: ⑨ 표시 이름

    /// 아머체는 `EvoLine.names` 에 없다 — 라인 이름 경로만 쓰면 `"#305"` 가 나온다.
    func testArmorDisplayNameIsNotSpeciesNumber() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.displayName, "화염드라몬")
        XCTAssertEqual(s.ladderName, "브이몬", "되돌아갈 대상은 사다리 종이다")
        // 본래 의도(#305 로 떨어지지 않는다)는 언어와 무관하다 — 어느 언어에서도 성립해야 한다.
        for lang in AppLanguage.allCases {
            s.setLanguage(lang)
            XCTAssertNotEqual(s.displayName, "#305", "\(lang) 에서 아머체 이름이 종 번호로 떨어졌다")
            XCTAssertNotEqual(s.ladderName, "#349", "\(lang) 에서 사다리 이름이 종 번호로 떨어졌다")
        }
    }

    // MARK: ⑩ 진행 표시는 사다리를 따른다 (의도된 동작)

    /// 스프라이트는 아머체인데 진행 표시는 사다리 기준 — 버그가 아니라 오버레이 모델의 귀결이다.
    /// 여기를 표시 축으로 "고치면" `node(withID:)` 가 nil 이 되어 성장 정지가 재발한다.
    func testProgressIndicatorsStayOnTheLadder() async throws {
        let s = try await hatched(vmonLine)
        let stageTextBefore = s.stageText
        let isFinalBefore = s.isFinalStage
        let lineNodesBefore = s.lineNodes.count

        XCTAssertTrue(s.useDigimental(.digimentalCourage))

        XCTAssertEqual(s.stageText, stageTextBefore)
        XCTAssertEqual(s.isFinalStage, isFinalBefore)
        XCTAssertEqual(s.lineNodes.count, lineNodesBefore)
    }

    // MARK: ⑪ 세이브 호환성

    /// 구버전 세이브(armorID 키 없음)가 그대로 로드된다 — 엄격 `decode` 로 구현했다면
    /// MonState 디코딩이 실패하고 `active` 가 nil 로 흡수돼 **모든 사용자의 디지몬이 알이 된다.**
    func testLegacySaveWithoutArmorIDDecodes() throws {
        let json = """
        {"saveVersion":2,"installBaselineSet":true,"usedSinceInstall":1000,"spentTokens":0,
         "eggUsage":0,"lastDate":"2026-09-24","dex":[],"collectedFinals":[],"language":"ko",
         "inventory":{},"candyGrantTier":{},"candyFeatureSeeded":false,
         "active":{"baseID":349,"pathIDs":[349],"stageIndex":0,"usedAtStage":5,
                   "rarity":"uncommon","totalForms":2}}
        """
        let decoded = try JSONDecoder().decode(CompanionState.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded.active, "구버전 세이브의 디지몬이 알로 되돌아갔다")
        XCTAssertNil(decoded.active?.armorID)
        XCTAssertEqual(decoded.active?.currentID, 349)
        XCTAssertEqual(decoded.active?.displayID, 349)
    }

    /// 구버전 도감 항목(armoredAt 키 없음)은 아머 기록이 아니다.
    func testLegacyDexEntryIsNotArmored() throws {
        let json = """
        {"id":"x","baseID":349,"finalID":358,"chainOrder":[349,358],"rarity":"uncommon"}
        """
        let entry = try JSONDecoder().decode(DexEntry.self, from: Data(json.utf8))
        XCTAssertFalse(entry.isArmored)
        XCTAssertNil(entry.armoredAt)
    }

    /// 아머 상태가 저장·복원 왕복을 견딘다.
    func testArmorIDSurvivesEncodeDecodeRoundTrip() throws {
        var mon = MonState(baseID: 349, pathIDs: [349], stageIndex: 0, usedAtStage: 7,
                           rarity: .uncommon, totalForms: 2)
        mon.armorID = 305
        let data = try JSONEncoder().encode(mon)
        let restored = try JSONDecoder().decode(MonState.self, from: data)
        XCTAssertEqual(restored.armorID, 305)
        XCTAssertEqual(restored.displayID, 305)
        XCTAssertEqual(restored.currentID, 349)
    }

    // MARK: ⑫ sanitize — 로드·수입 양쪽

    func testValidArmorIDKeepsReachableAndDropsUnreachable() {
        XCTAssertEqual(SaveTransfer.validArmorID(305, forLadderSpecies: 349), 305)
        XCTAssertNil(SaveTransfer.validArmorID(326, forLadderSpecies: 349), "다른 라인의 아머체")
        XCTAssertNil(SaveTransfer.validArmorID(305, forLadderSpecies: 358), "성숙기엔 아머 매핑이 없다")
        XCTAssertNil(SaveTransfer.validArmorID(99999, forLadderSpecies: 349), "존재하지 않는 종")
        XCTAssertNil(SaveTransfer.validArmorID(nil, forLadderSpecies: 349))
    }

    /// 손편집·데이터 개정으로 근거를 잃은 아머는 로드 시 지운다.
    func testSanitizeDropsInvalidArmorID() {
        var state = CompanionState()
        var mon = MonState(baseID: 349, pathIDs: [349, 358], stageIndex: 1, usedAtStage: 0,
                           rarity: .uncommon, totalForms: 2)
        mon.armorID = 305       // 사다리 종이 이미 358(성숙기)이라 근거가 없다
        state.active = mon
        XCTAssertNil(SaveTransfer.sanitized(state).active?.armorID)
    }

    func testSanitizeKeepsValidArmorID() {
        var state = CompanionState()
        var mon = MonState(baseID: 349, pathIDs: [349], stageIndex: 0, usedAtStage: 0,
                           rarity: .uncommon, totalForms: 2)
        mon.armorID = 305
        state.active = mon
        XCTAssertEqual(SaveTransfer.sanitized(state).active?.armorID, 305)
    }

    /// 세이브 **수입** 경로도 같은 정리를 받는다 — 로드에만 넣으면 수입이 게이트를 우회한다
    /// (이 프로젝트에 전례가 있는 함정: applySave 가 상태를 직접 대입한다).
    func testImportPathSanitizesArmorID() throws {
        var state = CompanionState()
        var mon = MonState(baseID: 349, pathIDs: [349, 358], stageIndex: 1, usedAtStage: 0,
                           rarity: .uncommon, totalForms: 2)
        mon.armorID = 305
        state.active = mon
        let data = try SaveTransfer.encode(state: state, appVersion: "1.0",
                                           deviceName: "Mac", now: armorFixedNow)
        let envelope = try SaveTransfer.decode(data)
        XCTAssertNil(envelope.state.active?.armorID, "수입 경로가 무효 아머를 그대로 통과시켰다")
    }

    /// `longestValidPath` 는 절단만 하는 게 아니라 **루트를 갈아끼운다** —
    /// 저장된 `pathIDs` 의 머리가 라인 루트와 다르면 경로를 `[루트]` 로 통째 교체한다.
    /// 그래서 로드 경계(`sanitized`)에서 유효했던 아머가 정규화 후 근거를 잃을 수 있다:
    /// 손편집·기기 간 세이브로 `baseID` 와 `pathIDs` 가 어긋난 경우가 그 입구다.
    func testRootReplacementOnLoadClearsNowInvalidArmor() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        var mon = MonState(baseID: 349, pathIDs: [83], stageIndex: 0, usedAtStage: 0,
                           rarity: .uncommon, totalForms: 2)
        // 83(Tailmon) + light = 326 이라 로드 경계는 이 값을 유효로 보고 남긴다.
        // 그런데 라인은 baseID 349 로 조회되므로 정규화가 경로를 [349] 로 갈아끼운다 → 326 은 무효.
        mon.armorID = 326
        seed.active = mon
        let s = try store(vmonLine, seed: seed)
        XCTAssertEqual(s.state.active?.armorID, 326, "로드 경계에서는 아직 유효해야 성립하는 테스트다")

        // 라인 로드(→ 정규화)는 `update` 틱이 건다 — 재시작 직후와 같은 경로
        // (testReloadWrongRootNormalizesPathWithoutChangingIdentity 와 동일한 패턴).
        s.update(todayTokensByProvider: ["test": 0], todayDate: "d1", monthTotal: 0,
                 burnTier: .idle, limitWarning: false, hasUsageData: true)
        for _ in 0..<500 {
            if s.currentLine != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(s.currentLine, "라인이 로드되지 않아 정규화가 돌지 않았다")
        XCTAssertEqual(s.currentSpeciesID, 349, "루트 교체가 일어나지 않았다")
        XCTAssertNil(s.armorSpeciesID, "정규화 후 근거를 잃은 아머가 남았다")
    }

    // MARK: ⑫ 대표 종(메뉴바·플로팅 펫)은 표시 축을 따른다

    /// `refreshRepresentativeSubject` 가 읽는 축을 고정한다. 이 단언이 없으면 그 한 줄을
    /// `currentSpeciesID` 로 되돌려도 전 테스트가 초록이라(리뷰 M5 실증), "메뉴바 펫이 아머를
    /// 안 따라간다" 는 회귀가 조용히 들어온다. `useDigimental`/`removeArmor` 가 둘 다 `save()` 를
    /// 부르고 그 안에서 갱신이 돌므로 별도 배선 없이 관측된다.
    func testRepresentativeSubjectFollowsArmorWhenAutoTracking() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertNil(s.representativeSpeciesID, "전제: 자동 추적(수동 선택 없음)")
        XCTAssertEqual(s.representativeSubject.speciesID, 349, "착용 전엔 사다리 종이 곧 표시 종")

        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.representativeSubject.speciesID, 305,
                       "메뉴바·플로팅 펫이 아머체를 그려야 한다")

        XCTAssertTrue(s.removeArmor())
        XCTAssertEqual(s.representativeSubject.speciesID, 349, "해제하면 사다리 종으로 돌아온다")
    }

    /// 수동 선택은 아머와 무관하게 유지된다 — 표시 축 전환이 사용자의 선택을 덮어쓰면 안 된다.
    func testManuallySelectedRepresentativeIsUnaffectedByArmor() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.setRepresentativeSpeciesID(349), "도감이 소유한 종만 선택할 수 있다")
        XCTAssertEqual(s.representativeSubject.speciesID, 349)

        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.representativeSubject.speciesID, 349, "수동 선택은 아머를 따라가지 않는다")

        XCTAssertTrue(s.removeArmor())
        XCTAssertEqual(s.representativeSubject.speciesID, 349)
    }

    // MARK: ⑬ 라인 비동기 로드 전 (재시작 직후)

    /// `armorID` 는 세이브에서 즉시 복원되지만 라인은 비동기라 재시작 직후 `currentLine == nil` 이다.
    /// 그 창에 아머 해제 컨트롤이 이미 떠 있는데 `ladderName` 이 라인만 보면 확인 문구가
    /// "Token Egg 으로 돌아갈까요?" 가 된다(최대 한 update 틱 = 기본 120초).
    func testNamesSurviveRestartBeforeLineLoads() async throws {
        var seed = CompanionState()
        seed.installBaselineSet = true
        var mon = MonState(baseID: 349, pathIDs: [349], stageIndex: 0, usedAtStage: 0,
                           rarity: .uncommon, totalForms: 2)
        mon.armorID = 305
        seed.active = mon
        let s = try store(vmonLine, seed: seed)

        // 전제: 라인 로드는 `update` 틱이 걸므로 아직 돌지 않았다.
        XCTAssertNil(s.currentLine, "전제: 라인 미로딩 창을 재현해야 하는 테스트다")
        XCTAssertTrue(s.isArmored, "아머 해제 컨트롤이 이 시점에 이미 렌더된다")

        XCTAssertEqual(s.displayName, "화염드라몬")
        XCTAssertEqual(s.ladderName, "브이몬", "라인 미로딩이라고 알 표기로 떨어지면 안 된다")
        // 이 테스트의 축(라인 미로딩 폴백이 살아 있나)은 언어와 무관하다. "Token Egg" 는 로케일
        // 무관 리터럴이고(`CompanionStore.ladderName`), `#id` 는 이름 해석이 끊겼다는 신호다.
        XCTAssertNotEqual(s.ladderName, "Token Egg")
        XCTAssertNotEqual(s.ladderName, "#349", "라인 미로딩 폴백이 종 번호로 떨어졌다")
        XCTAssertNotEqual(s.displayName, "#305", "아머 이름이 종 번호로 떨어졌다")
    }

    /// "Token Egg" 폴백은 개체 자체가 없을 때만 맞다 — 그 경로는 그대로 남아야 한다.
    func testLadderNameIsEggLabelOnlyWithoutActiveCompanion() throws {
        let s = try store(vmonLine)
        XCTAssertNil(s.currentSpeciesID, "전제: 알 상태")
        XCTAssertEqual(s.ladderName, "Token Egg")
    }

    // MARK: ⑨ 알림·연출 중복 제거 (아머체 첫 획득 시에만)

    /// 디지멘탈은 비소모라 착용/해제가 무료다 — 그대로 두면 왕복 10회가 "진화했어요!" 알림 10개다.
    /// 도감 줄은 종 단위로 접히는데(`recordArmorDexEntry`) 알림은 안 접히던 비대칭을 닫는다.
    ///
    /// `celebrationSeq` 가 판정 축이다: `removeArmor` 가 `justEvolvedTo` 를 nil 로 미는 탓에
    /// 이름만 보면 "발화 후 지워짐"과 "애초에 발화 안 함"이 구분되지 않는다. 단조 증가 카운터만
    /// 그 둘을 가른다. `hatch` 가 이미 `.hatch` 를 쏘므로 절대값이 아니라 **증분**으로 본다.
    /// 알림(`notifyCompanionEvent`)은 테스트에서 관측할 수 없고, 프로덕션이 네 효과를 조건 하나로
    /// 묶어 두었기에 여기 연출 단언이 알림까지 대신 지킨다.
    func testArmorCelebrationFiresOnlyOnFirstAcquisitionOfEachArmorForm() async throws {
        let s = try await hatched(vmonLine)
        let seq0 = s.celebrationSeq

        // ① 첫 착용 → 발화된다.
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.celebrationSeq, seq0 + 1, "아머체 첫 획득은 축하 연출이 떠야 한다")
        XCTAssertEqual(s.justEvolvedTo, "화염드라몬")

        // ② 해제 후 같은 아머 재착용 → 조용히 전환된다.
        XCTAssertTrue(s.removeArmor())
        XCTAssertTrue(s.useDigimental(.digimentalCourage), "조용해져도 착용 자체는 성공한다")
        XCTAssertEqual(s.displaySpeciesID, 305, "조용하되 전환은 실제로 일어난다")
        XCTAssertEqual(s.celebrationSeq, seq0 + 1, "재착용이 축하 연출을 또 띄웠다")
        XCTAssertNil(s.justEvolvedTo, "재착용이 진화 토스트를 또 띄웠다")

        // ③ 다른 아머체 첫 착용 → 발화된다(교체 경로, removeArmor 없이).
        XCTAssertTrue(s.useDigimental(.digimentalMiracles))
        XCTAssertEqual(s.displaySpeciesID, 315)
        XCTAssertEqual(s.celebrationSeq, seq0 + 2, "다른 아머체는 처음이므로 발화해야 한다")
        XCTAssertEqual(s.justEvolvedTo, "매그너몬")

        // ④ 이전 아머로 복귀 → 조용히 전환된다(해제를 끼지 않는 별도 경로).
        // 여기서 `justEvolvedTo` 는 ③ 이 남긴 "매그너몬" 그대로다 — 조용한 경로는 그 값도
        // `eventUntil` 도 건드리지 않으므로 ③ 이 연 4초 창이 끝날 때 함께 만료된다(창을 못 늘린다).
        // 그래서 이 경로의 판정은 이름이 아니라 **연출이 다시 쏘였나**다.
        let toastBeforeReturn = s.justEvolvedTo
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertEqual(s.displaySpeciesID, 305, "복귀도 전환은 실제로 일어난다")
        XCTAssertEqual(s.celebrationSeq, seq0 + 2, "이전 아머로 복귀가 축하 연출을 또 띄웠다")
        XCTAssertEqual(s.justEvolvedTo, toastBeforeReturn,
                       "복귀가 토스트 문구를 Fladramon 으로 새로 갈아끼웠다")
    }

    /// 왕복 10회 = 연출 1회. `testRepeatedTogglingGrantsNoProgress` 는 `usedAtStage` 만 봐서
    /// 이 축에 침묵한다 — 알림 스팸은 진행도 0 인 채로도 성립한다.
    func testTenTogglesFireCelebrationOnce() async throws {
        let s = try await hatched(vmonLine)
        let seq0 = s.celebrationSeq
        for _ in 0..<10 {
            XCTAssertTrue(s.useDigimental(.digimentalCourage))
            XCTAssertTrue(s.removeArmor())
        }
        XCTAssertEqual(s.celebrationSeq, seq0 + 1, "왕복 10회가 연출 10회가 됐다")
    }

    /// 새 개체(새 부화)는 같은 아머체라도 다시 처음이다 — 도감 키가 instanceID 로 갈라지므로
    /// 접힘이 개체를 넘어 새지 않는다.
    func testCelebrationFiresAgainForANewCompanionWithTheSameArmorForm() async throws {
        let s = try await hatched(vmonLine)
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        let seqAfterFirst = s.celebrationSeq

        await s.hatch(baseID: 349)   // 새 개체
        XCTAssertTrue(s.useDigimental(.digimentalCourage))
        XCTAssertGreaterThan(s.celebrationSeq, seqAfterFirst + 1,
                             "새 개체의 첫 아머는 다시 발화해야 한다(hatch 연출 + 아머 연출)")
        XCTAssertEqual(s.justEvolvedTo, "화염드라몬")
    }
}
