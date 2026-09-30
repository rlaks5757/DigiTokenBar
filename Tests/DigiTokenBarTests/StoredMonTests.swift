import XCTest
@testable import DigiTokenBar

/// 보관함(#1a) — 알을 새로 사면서 방생하지 않고 육성 상태를 유지한 채 보관, 나중에 꺼내 이어서
/// 키운다. `CompanionState.stored: [StoredMon]` 스키마 + 헤드리스 store 메서드만 다룬다(UI 없음).
///
/// 함정 1~4(요청 문서)를 각각 전담 테스트로 고정한다:
///  ① 보관은 방생이 아니다 — `hasJogressPartnerRecord`/`isReleased` 축.
///  ② `ownsSpecies` 가 보관 개체를 본다 — `babyPicks` 회귀.
///  ③ `SaveTransfer` 가 보관함을 round-trip 한다(내보내기/불러오기 유실 방지).
///  ④ 경합 보호 — 활성 개체가 있거나 부화 중이면 꺼내기를 거절한다.
@MainActor
final class StoredMonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private struct StubProvider: DigimonLineProviding {
        let value: EvoLine
        func line(baseSpeciesID: Int) async throws -> EvoLine { value }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
    }

    /// 아구몬 라인(1→31→202→…) — 실제 데이터의 id 를 써서 죠그레스 조회가 성립하게 한다
    /// (`JogressEvolutionTests` 와 같은 이유).
    private let agumonLine = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: [
        EvoNode(speciesID: 31, children: [EvoNode(speciesID: 202, children: [])])
    ]), rarity: .legendary, names: [1: ["ko": "아구몬"], 31: ["ko": "그레이몬"], 202: ["ko": "워그레이몬"]])

    /// vmon 라인(349→358, uncommon) — 실제 데이터셋 id. `babyPicks`/`ownsSpecies` 는
    /// `DigimonData.lines` 를 직접 순회하므로 합성 id(예: 10)는 애초에 후보에 뜰 수 없다
    /// (`EggSpeciesPickTests` 와 같은 이유). baseID 1(Agumon, 죠그레스 파트너 테스트용)과는 별개 종.
    private let vmonLine = EvoLine(baseID: 349, tree: EvoNode(speciesID: 349, children: [
        EvoNode(speciesID: 358, children: [])
    ]), rarity: .uncommon, names: [349: ["ko": "브이몬"], 358: ["ko": "엑스브이몬"]])

    @discardableResult
    private func store(_ line: EvoLine? = nil,
                       json: String, at url: URL? = nil, seed: UInt64 = 7) -> CompanionStore {
        let url = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString).json")
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: StubProvider(value: line ?? vmonLine), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: seed))
    }

    /// 활성 디지몬(baseID 349/브이몬, uncommon, stageIndex 0, 성장 200M) + 도감 항목(1:3, 파트너 자격
    /// 있음) + 지갑. `DigimonData.lines` 의 실제 id 를 써야 `babyPicks` 회귀를 검증할 수 있다.
    private func activeStoreJSON(used: Int = 5_000_000_000) -> String {
        let mon = "{\"baseID\":349,\"pathIDs\":[349],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"uncommon\",\"totalForms\":2}"
        let dex = "{\"baseID\":1,\"finalID\":3,\"chainOrder\":[1,2,3],\"rarity\":\"common\"}"
        return "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":\(used),\"spentTokens\":0,\"lastDate\":\"d\","
            + "\"active\":\(mon),\"dex\":[\(dex)],\"collectedFinals\":[]}"
    }

    // MARK: 스키마 round-trip (보관 필드 없는 v2 JSON도 정상 디코드)

    /// [핵심] 보관 필드가 **없는** v2 JSON 이 `.legacy` 백업 없이 정상 디코드되고 round-trip 된다.
    /// `CompanionTests.testMatchingSaveVersionLoadsNormallyAndPreservesBaseID` 와 같은 취지.
    func testStoredFieldAbsentInV2JSONDecodesNormallyWithoutLegacyBackup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-legacy-\(UUID().uuidString).json")
        // saveVersion=2 이지만 "stored" 키 자체가 없다 — 이 기능 이전에 저장된 실제 세이브 형태.
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":{\"baseID\":271,"
            + "\"pathIDs\":[271],\"stageIndex\":0,\"usedAtStage\":0,\"rarity\":\"common\",\"totalForms\":1},"
            + "\"dex\":[{\"baseID\":101,\"finalID\":165,\"chainOrder\":[101,165],\"rarity\":\"common\"}],"
            + "\"usedSinceInstall\":5000}"
        try Data(json.utf8).write(to: url)

        let s = CompanionStore(provider: StubProvider(value: agumonLine), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 7))

        XCTAssertEqual(s.state.saveVersion, CompanionState.currentSaveVersion)
        XCTAssertEqual(s.state.active?.baseID, 271, "보관 필드가 없다고 기존 활성 개체가 날아가면 안 된다")
        XCTAssertEqual(s.state.dex.count, 1)
        XCTAssertTrue(s.state.stored.isEmpty, "없는 필드는 빈 배열 기본값으로 흡수")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("legacy").path),
                       "순수 추가 필드는 세대 불일치가 아니다 — .legacy 백업이 생기면 안 된다")
    }

    /// 위 상태를 실제로 저장(`save()`) 후 재시작해도 라운드트립되고 보관 배열도 유지된다.
    func testSaveThenReloadRoundTripsStoredArray() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-rt-\(UUID().uuidString).json")
        try? activeStoreJSON().data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: StubProvider(value: agumonLine), clock: { self.now },
                               fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertEqual(s.state.stored.count, 1)

        let reloaded = CompanionStore(provider: StubProvider(value: agumonLine), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.stored.count, 1, "디스크 재로드에서 보관 개체가 사라졌다")
        XCTAssertEqual(reloaded.state.stored.first?.mon.baseID, 349)
        XCTAssertEqual(reloaded.state.stored.first?.mon.usedAtStage, 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("legacy").path))
    }

    // MARK: 함정 1 — 보관은 방생이 아니다(죠그레스 파트너 자격, 양방향 고정)
    //
    // [팀 리드 정정] `hasJogressPartnerRecord` 는 `state.dex` 만 본다(의도적 — doc-comment
    // :1088 근방 "ownsSpecies 를 쓰지 않는다: 육성 중인 개체 하나로 양쪽 부모를 동시에 만족시켜
    // 버린다" 참고). 지켜야 할 불변조건은 두 방향이다:
    //   (a) 보관이 **기존** 파트너 자격 기록을 훼손하지 않는다.
    //   (b) 보관 **자체가 새 파트너 자격을 만들지 않는다** — 보관 개체의 종은 도감에 없으므로
    //       `hasJogressPartnerRecord` 가 false 여야 한다. `ownsSpecies` 가 보관을 소유로 보는 것과
    //       무관하게(그건 babyPicks 용, 별개 축) 여기선 항상 false — 육성 중(보관도 포함)인 개체
    //       하나로 죠그레스 양쪽 부모를 동시에 만족시키는 이중 계수를 막기 위해서다.

    /// (a) 죠그레스 부모가 되는 종(baseID 1, 도감 기록 있음)의 파트너 자격이 **다른 개체를 보관**한
    /// 뒤에도 유지되는가. `releasedDexEntry` 를 재사용하는 나이브한 구현이면 보관 시점에 기존 도감
    /// 기록까지 `isReleased` 로 오염시킬 위험이 있다(`releasedDexEntry`는 `caughtAt`/`id` 를 새로
    /// 만들 뿐 기존 항목을 직접 건드리지 않지만, "방생 경로를 재사용한다"는 실수 자체가 dex append
    /// 형태로 나타난다).
    ///
    /// 판별 축은 `hasJogressPartnerRecord`(도감 전용, monotone이라 이 축 단독으론 레드가 안 뜬다)가
    /// 아니라 **도감 배열 자체가 늘지 않는다** — 그게 방생 경로 재사용 여부를 실제로 가르는 단언이다.
    func testStoringActiveDoesNotAppendReleasedDexEntry() {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.hasJogressPartnerRecord(1), "사전 조건 — baseID 1 도감 기록이 이미 파트너 자격을 갖는다")
        let dexIDsBefore = Set(s.state.dex.map(\.id))
        XCTAssertTrue(s.buyFreshEgg())

        XCTAssertEqual(Set(s.state.dex.map(\.id)), dexIDsBefore,
                       "보관은 도감을 전혀 건드리지 않는다 — 방생 경로 재사용 시 실패")
        XCTAssertTrue(s.state.dex.allSatisfy { !$0.isReleased && !$0.isArmored })
        XCTAssertTrue(s.hasJogressPartnerRecord(1), "기존 파트너 자격이 보관 후에도 유지된다")
    }

    /// (b) 보관한 종(baseID 349) 자체는 도감 기록이 없으므로 `hasJogressPartnerRecord` 가 여전히
    /// false 여야 한다 — 보관이 새 파트너 자격을 만들면 육성 중인 개체 하나로 죠그레스 양쪽 부모를
    /// 동시에 만족시키는 이중 계수 버그가 된다(`ownsSpecies` 를 안 쓰는 이유와 같음). `ownsSpecies`
    /// 가 보관을 소유로 보는 것(함정 2)과는 반대 방향 결정이며, 그게 의도다 — 두 함수는 서로 다른
    /// 질문에 답한다.
    func testStoredEntryItselfIsNotAddedAsGraduationRecord() {
        let s = store(json: activeStoreJSON())
        XCTAssertFalse(s.hasJogressPartnerRecord(349),
                       "사전 조건 — 보관 전에도 349 는 도감 기록이 없어 파트너 자격이 없다")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertFalse(s.state.dex.contains { $0.baseID == 349 },
                       "보관은 졸업이 아니다 — baseID 349 의 도감 기록이 생기면 안 된다")
        XCTAssertFalse(s.hasJogressPartnerRecord(349),
                       "보관 자체가 새 파트너 자격을 만들면 안 된다 — 이중 계수 방지")
    }

    // MARK: 함정 2 — ownsSpecies / babyPicks 가 보관 개체를 본다

    /// 도감 1건(baseID 1) + 활성 개체(baseID 349/브이몬)뿐인 세이브에서 349 를 보관하면, 보관 전엔
    /// `ownsSpecies(349)` 가 active 경로로 true 였다가 보관 후에도 여전히 true 여야 한다(stored 경로).
    /// 아니면 `babyPicks` 가 349 를 후보에서 빠뜨려 사용자가 방금 보관한 종을 다시 고를 수 없게 된다.
    /// `DigimonData.lines` 에 실재하는 id 를 써야 `babyPicks`(실 데이터셋만 순회)가 실제로 검증된다.
    func testOwnsSpeciesRecognizesStoredMonAfterActiveIsCleared() {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.state.ownsSpecies(349), "보관 전 — active 경로로 소유")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.state.active)
        XCTAssertTrue(s.state.ownsSpecies(349), "보관 후 — stored 경로로도 소유가 유지돼야 한다")
        XCTAssertTrue(s.babyPicks.contains { $0.baseID == 349 },
                      "보관한 종을 직접 선택 후보에서 다시 고를 수 있어야 한다")
    }

    /// 도달하지 못한 미래 단계는 여전히 소유가 아니다 — 보관도 `pathIDs.prefix(stageIndex+1)` 규칙을
    /// 따라야 한다(전체 `pathIDs`/`plannedPathIDs` 를 쓰면 안 됨).
    func testOwnsSpeciesForStoredMonUsesReachedPrefixOnly() {
        let mon = "{\"baseID\":1,\"pathIDs\":[1,31,202],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"legendary\",\"totalForms\":3}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":5000000000,\"active\":\(mon),\"dex\":[],\"collectedFinals\":[]}"
        let s = store(agumonLine, json: json)
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertTrue(s.state.ownsSpecies(1), "도달한 형태(base)는 소유")
        XCTAssertFalse(s.state.ownsSpecies(31), "도달 못한 다음 형태까지 소유로 잡히면 안 된다")
        XCTAssertFalse(s.state.ownsSpecies(202), "도달 못한 최종형까지 소유로 잡히면 안 된다")
    }

    /// [결정 고정] `dexEntries`(개체 단위 동행 기록)는 `dexSpecies`(종 단위 로그)와 다른 축이다 —
    /// "지금 키우는 개체 + 졸업한 개체" 만 담고, 보관 개체는 합성하지 않는다. 보관은 "지금 키우는
    /// 중" 이 아니므로 포함시키면 활성/보관 상태가 로그에서 구분이 안 된다. 종 로그(`dexSpecies`)가
    /// 보관을 보유로 치는 것과 반대 방향 결정이라, 나중에 실수로 같은 취급을 하지 않도록 고정한다.
    func testDexEntriesDoesNotSynthesizeStoredMons() {
        let s = store(json: activeStoreJSON())
        XCTAssertEqual(s.dexEntries.count, 2, "사전 조건 — 도감 기록(1:3) + 현재 개체(349) 합성분")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.state.active)
        XCTAssertEqual(s.state.stored.count, 1)
        XCTAssertEqual(s.dexEntries.count, 1,
                       "보관 개체가 동행 기록에 합성되면 안 된다 — 도감 기록(1:3) 하나만 남아야 한다")
        XCTAssertFalse(s.dexEntries.contains { $0.baseID == 349 },
                       "보관 개체(349)의 합성 항목이 동행 기록에 있으면 안 된다")
    }

    // MARK: 함정 3 — SaveTransfer round-trip

    /// 내보내기(encode) → 불러오기(decode) 를 거쳐도 보관함이 유실되지 않는다.
    func testSaveTransferRoundTripsStoredArray() throws {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertEqual(s.state.stored.count, 1)

        let data = try s.exportedSaveData(appVersion: "1.0", deviceName: "MacTest")
        let envelope = try SaveTransfer.decode(data)
        XCTAssertEqual(envelope.state.stored.count, 1, "내보내기→불러오기에서 보관 개체가 유실됐다")
        XCTAssertEqual(envelope.state.stored.first?.mon.baseID, 349)
        XCTAssertEqual(envelope.state.stored.first?.mon.usedAtStage, 200_000_000)
    }

    /// `applySave()` 뒤의 `save()` 가 결과를 현재 세대로 재인코딩하므로, 여기서 유실되면 디스크에도
    /// 영구 유실된다 — 그 전체 경로(적용 → 재로드, 같은 파일 URL 로 새 스토어를 만들어 확인)를 검증한다.
    func testApplySaveThenReloadPreservesStoredArray() throws {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyFreshEgg())
        let data = try s.exportedSaveData(appVersion: "1.0", deviceName: "MacTest")
        let envelope = try SaveTransfer.decode(data)

        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("stored-apply-\(UUID().uuidString).json")
        let target = store(json: "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,\"dex\":[]}",
                           at: targetURL)
        try target.applySave(envelope, todayTokensByProvider: [:], todayDate: "2026-09-29", hasUsageData: false)
        XCTAssertEqual(target.state.stored.count, 1, "applySave 직후 보관함 유실")

        let reloaded = CompanionStore(provider: StubProvider(value: agumonLine), clock: { self.now },
                                      fileURL: targetURL, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.stored.count, 1,
                       "applySave 뒤 save() 가 현재 세대로 재인코딩하며 보관함이 사라졌다")
    }

    /// [리뷰 W3] `SaveEnvelope.schemaVersion` 을 리터럴로 고정한다 — 아래
    /// `testSchemaVersionRejectsOlderAppReceivingNewerFile` 은 기대값을 파일에서 읽어와
    /// `currentSchema + 1` 로 유도하므로 값이 3 이든 4 든 99 든 항상 통과한다(동어반복). `stored`
    /// 필드 도입으로 3→4 로 올린 것 자체를 지키는 단언은 이 테스트뿐이다 — 누군가 3 으로 되돌리면
    /// 구버전 앱이 `stored` 를 조용히 드롭한다(SaveTransfer.swift:17-22 참고).
    ///
    /// 바로 아래 `currentSaveVersion` 단언과 **의도적으로 반대 방향**이다 — 두 상수는 인접해
    /// 보이지만 다른 축을 지킨다. `schemaVersion` 은 "올려야" 조용한 유실을 막고(위),
    /// `currentSaveVersion` 은 "올리면 안" 된다(아래, `stored` 는 가산 필드라 종 식별자 세대가
    /// 안 바뀌었으므로). 하나만 고정하면 다음 사람이 "버전 상수는 다 올리면 안전하다"는 식으로
    /// 패턴을 혼동하기 쉽다(팀 리드가 이 세션에서 실제로 이 혼동을 겪었다) — 나란히 적어 방향
    /// 차이를 명시한다.
    func testSchemaVersionIsBumpedForStoredField() {
        XCTAssertEqual(SaveEnvelope.schemaVersion, 4,
                       "stored 필드 도입으로 3→4 로 올렸다 — 내리면 구버전 앱이 보관 개체를 조용히 드롭한다")
    }

    /// [리뷰 W3 확장] `CompanionState.currentSaveVersion` 은 **2 로 유지돼야 한다** — 이 상수는
    /// `CompanionModel.swift:626` 근방 doc 대로 종 식별자 체계(포켓몬→디지몬 등)가 바뀔 때만
    /// 올린다. `stored` 는 순수 가산 필드라 이 세대를 바꾸지 않는다. `CompanionStore.load()`
    /// 의 게이트(`s.saveVersion == currentSaveVersion`)는 하드 동등 비교 + 불일치 시 `.legacy`
    /// 백업 후 fresh 시작이고 **마이그레이션 레이어가 없으므로**, 이 상수를 실수로 3으로 올리면
    /// 살아있는 세이브가 전부 날아간다(schemaVersion 을 내렸을 때의 "조용한 필드 드롭"보다
    /// 훨씬 복구가 어렵다 — 백업은 남지만 사용자가 수동으로 복구해야 한다).
    ///
    /// 스위트 전체의 `saveVersion` JSON 픽스처가 리터럴이 아니라 `\(CompanionState.currentSaveVersion)`
    /// 보간이라(이 파일의 `activeStoreJSON()` 포함), 상수를 올려도 픽스처가 따라 올라가 v2-형태
    /// 디코드 테스트들은 전부 green 으로 남는다 — 그 테스트들은 "stored 키 부재" 축은 검증하지만
    /// **버전 번호 축에서는 동어반복**이다. 이 리터럴 고정만이 버전 번호 축을 지킨다.
    ///
    /// 영구 금지가 아니다 — 종 식별자 세대가 실제로 바뀌는 **정당한** 전환이라면 상수를 올리고
    /// **이 테스트의 기대값도 함께 갱신한다**(`CompanionTests` 의 리터럴 `1` doc 이 "미래에 3, 4 로
    /// 또 오르더라도"로 같은 전제를 둔다). 막으려는 건 가산 필드를 추가하면서 습관적으로 올리는 것.
    func testCurrentSaveVersionStaysAtTwoForAdditiveFields() {
        XCTAssertEqual(CompanionState.currentSaveVersion, 2,
                       "stored 는 가산 필드라 세대를 올리면 안 된다 — 올리면 로드 게이트가 하드 동등 비교로 기존 세이브 전부를 .legacy 로 밀어내고 fresh 시작한다(마이그레이션 없음)")
    }

    /// `SaveEnvelope.schemaVersion` 이 이 기능으로 올랐는지 — 구버전 앱이 새 파일을 받으면
    /// `newerSchema` 로 명시 거부돼야 한다(조용한 유실 대신).
    func testSchemaVersionRejectsOlderAppReceivingNewerFile() throws {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyFreshEgg())
        let data = try s.exportedSaveData(appVersion: "1.0", deviceName: "MacTest")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let currentSchema = try XCTUnwrap(json["schema"] as? Int)
        json["schema"] = currentSchema + 1
        let bumped = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try SaveTransfer.decode(bumped)) { error in
            XCTAssertEqual(error as? SaveTransferError,
                           .newerSchema(found: currentSchema + 1, supported: currentSchema))
        }
    }

    // MARK: 함정 4 — 경합 보호(활성 개체 존재 / isHatching 락)

    /// 활성 개체가 있으면 **교체**한다(제품 결정 2026-09-30) — 예전엔 거절이었다.
    /// 보관 1건 + 활성 개체(다른 종, baseID 99)가 함께 있는 상태를 JSON 으로 직접 시드해
    /// `pickHatchSpecies`/`hatchIfNeeded` 의 비동기 경합 없이 동기 경로만 검증한다.
    ///
    /// **양쪽 육성 상태가 보존되는지**가 핵심이다 — 나가는 개체를 새로 만들거나 알 취급하면
    /// (`MonState()` 로 재구성·`stageIndex` 리셋) 교체 한 번으로 성장분이 사라진다. 나가는 쪽은
    /// `usedAtStage`, 들어오는 쪽은 `usedAtStage`+`stageIndex` 로 각각 고정한다.
    func testRetrieveStoredSwapsWithActiveAndPreservesBothGrowthStates() {
        let storedMonJSON = "{\"id\":\"stored-1\",\"mon\":{\"baseID\":10,\"pathIDs\":[10,11],"
            + "\"stageIndex\":1,\"usedAtStage\":200000000,\"rarity\":\"common\",\"totalForms\":3},"
            + "\"storedAt\":\(now.timeIntervalSince1970)}"
        let activeMonJSON = "{\"baseID\":99,\"pathIDs\":[99],\"stageIndex\":0,\"usedAtStage\":777000000,"
            + "\"rarity\":\"common\",\"totalForms\":1}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":\(activeMonJSON),"
            + "\"dex\":[],\"stored\":[\(storedMonJSON)],\"eggUsage\":12345}"
        let s = store(json: json)
        XCTAssertEqual(s.state.stored.count, 1, "사전 조건 — 보관 1건이 시드돼야 한다")

        XCTAssertTrue(s.canRetrieveStored("stored-1"), "활성이 있어도 꺼내기(교체)는 열려 있어야 한다")
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))

        // 들어온 개체 — 중단한 단계와 성장분 그대로.
        XCTAssertEqual(s.state.active?.baseID, 10, "꺼낸 개체가 활성이 되지 않았다")
        XCTAssertEqual(s.state.active?.stageIndex, 1, "꺼낸 개체의 단계가 리셋됐다")
        XCTAssertEqual(s.state.active?.usedAtStage, 200_000_000, "꺼낸 개체의 성장분이 사라졌다")
        // 나간 개체 — 방생이 아니라 보관함으로, 성장분 그대로.
        XCTAssertEqual(s.state.stored.count, 1, "교체인데 보관 칸 수가 바뀌었다(넣고 빼서 1건 유지)")
        let parked = try! XCTUnwrap(s.state.stored.first)
        XCTAssertEqual(parked.mon.baseID, 99, "나간 활성 개체가 보관함에 없다 — 조용히 사라졌다")
        XCTAssertEqual(parked.mon.usedAtStage, 777_000_000, "나간 개체의 성장분이 사라졌다")
        XCTAssertEqual(parked.storedAt, now, "보관 시각은 교체 시점이어야 한다(목록 정렬 기준)")
        XCTAssertTrue(s.state.dex.isEmpty, "교체는 방생이 아니다 — 도감 기록을 만들면 안 된다")
        // 교체 경로엔 알이 없다 — 알 관련 값을 태우면 존재하지 않는 알의 진행분을 "버리는" 헛일이 된다.
        XCTAssertEqual(s.state.eggUsage, 12_345, "교체가 다음 알의 인큐베이션 진행분을 지웠다")
    }

    /// 라인 fetch 를 붙잡아 `isHatching` 이 실제로 잠긴 창을 만드는 스텁 — `EggSpeciesPickTests`
    /// 의 `GatedPickProvider` 와 같은 이유(동기 테스트는 이 축을 공허하게 통과한다).
    /// 세마포어 금지 — `@MainActor` 테스트에서 블로킹하면 같은 actor 의 부화 Task 가 fetch 에
    /// 진입도 못 해 영구 교착한다. 대기는 전부 `await`(Task.yield) 로만 한다.
    @MainActor
    private final class GatedLineProvider: DigimonLineProviding {
        let value: EvoLine
        private var released = false
        private(set) var isFetching = false

        init(value: EvoLine) { self.value = value }

        nonisolated func line(baseSpeciesID: Int) async throws -> EvoLine {
            await MainActor.run { self.isFetching = true }
            while await MainActor.run(body: { !self.released }) {
                await Task.yield()
            }
            return await MainActor.run { self.value }
        }
        nonisolated func baseSpeciesIndex() async throws -> [BaseSpecies] {
            [BaseSpecies(id: await MainActor.run { self.value.baseID }, captureRate: 255)]
        }

        func waitUntilFetching() async {
            var spins = 0
            while !isFetching, spins < 10_000 {
                spins += 1
                await Task.yield()
            }
            XCTAssertTrue(isFetching, "부화가 라인 fetch 에 진입하지 않았다")
        }
        func release() { released = true }
    }

    /// **부화가 라인 fetch 에서 대기 중**이면 꺼내기를 거절한다 — 이제 `canRetrieveStored` 의
    /// **유일한** 조건이다(활성·보증은 교체·파킹으로 처리된다). 그래서 이 테스트가 게이트 전체를
    /// 지키는 단 하나의 축이 됐다: 빠지면 `!isHatching` 삭제가 초록으로 통과해 부화 락 창에서 활성이
    /// 뒤바뀌는 경합(함정 4)이 열린다. 이 창은 비동기라야 열린다(동기 테스트로는 공허하게 통과).
    func testRetrieveStoredRejectedWhileHatchInFlight() async throws {
        let storedMonJSON = "{\"id\":\"stored-1\",\"mon\":{\"baseID\":349,\"pathIDs\":[349],"
            + "\"stageIndex\":0,\"usedAtStage\":200000000,\"rarity\":\"uncommon\",\"totalForms\":2},"
            + "\"storedAt\":\(now.timeIntervalSince1970)}"
        // 알 상태(활성 없음) + 보관 1건 + 부화 임계 이상 사용량 → hatch(baseID:) 로 직접 fetch 창을 연다.
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,"
            + "\"dex\":[],\"stored\":[\(storedMonJSON)],\"eggUsage\":\(DigimonBalance.eggHatchThreshold)}"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-hatch-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let gated = GatedLineProvider(value: vmonLine)
        let s = CompanionStore(provider: gated, clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))

        let hatching = Task { await s.hatch(baseID: 349) }
        await gated.waitUntilFetching()
        XCTAssertTrue(s.isHatching, "부화 락이 걸리지 않았다 — 아래 단언이 공허해진다")
        XCTAssertNil(s.state.active, "사전 조건 — 아직 알 상태(active == nil)")
        XCTAssertNil(s.state.eggTier, "사전 조건 — 보증 없음(다른 두 조건과 겹치지 않게)")

        XCTAssertFalse(s.canRetrieveStored("stored-1"), "부화 중인데 꺼내기가 허용됐다")
        XCTAssertFalse(s.retrieveStored(id: "stored-1"))
        XCTAssertEqual(s.state.stored.count, 1, "거절됐는데 보관함이 줄었다")
        // [리뷰 W1] 게이트가 닫히면 **사유도 나와야 한다.** 사유가 nil 이면 `StorageView` 의
        // `if let reason` 이 안 걸려 비활성 버튼만 남고, 사용자는 기다리면 열린다는 걸 알 수 없다 —
        // `storedRetrieveBlockReason` 의 doc 이 드는 존재 이유가 바로 이 상태다.
        // 이 축(활성 없음·보증 없음·부화 중)은 여기서만 도달하므로 단언도 여기 있어야 한다.
        XCTAssertEqual(s.storedRetrieveBlockReason("stored-1"), s.l.storageBlockedHatching,
                       "부화 중 사유 문구가 비었다 — 사유 없는 비활성 버튼이 된다")

        gated.release()
        await hatching.value
    }

    /// 꺼내기 버튼 문구가 **교체임을 예고**한다 — 확인 단계가 없으므로(제품 결정: 즉시 교체) 이
    /// 라벨이 사용자가 누르기 전에 받는 유일한 경고다. 두 상태에 같은 문구를 쓰면 지금 키우던
    /// 디지몬이 보관함으로 들어가는 걸 **누른 뒤에** 알게 된다.
    ///
    /// 두 축을 같이 고정한다: (1) 상태별로 맞는 문구를 고르는가, (2) 두 문구가 애초에 **다른가**.
    /// (2)가 없으면 두 `Localization` 값이 같은 문구로 수렴해도 (1)이 green 으로 통과한다.
    func testRetrieveButtonLabelWarnsAboutSwapWhenActiveExists() {
        let withActive = store(json: activeStoreJSON())
        XCTAssertTrue(withActive.hasActive, "사전 조건 — 활성 개체가 있어야 교체 축이다")
        XCTAssertEqual(withActive.storageRetrieveLabel, withActive.l.storageSwap,
                       "활성이 있는데 꺼내기 문구가 교체를 예고하지 않는다")

        // 알 상태(활성 없음) — 치울 개체가 없으니 그냥 꺼내기다.
        let eggJSON = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,"
            + "\"dex\":[],\"stored\":[],\"eggUsage\":0}"
        let empty = store(json: eggJSON)
        XCTAssertFalse(empty.hasActive, "사전 조건 — 빈 자리 축")
        XCTAssertEqual(empty.storageRetrieveLabel, empty.l.storageRetrieve,
                       "활성이 없는데 교체 문구가 떴다")

        XCTAssertNotEqual(empty.l.storageRetrieve, empty.l.storageSwap,
                          "두 문구가 같으면 라벨이 교체를 구분해 주지 못한다(위 두 단언이 공허해진다)")
    }

    /// 알 보증(`eggTier`)이 걸려 있어도 꺼낼 수 있다 — 보증은 거절 사유가 아니라 **파킹 대상**이다
    /// (제품 결정 2026-09-30). 예전엔 거절했다: 그대로 허용하면 다음 디스크 로드에서
    /// `SaveTransfer.sanitized` 가 `active != nil` 을 보고 보증을 지웠기 때문(산 보증 증발).
    ///
    /// 이제 보증은 `parkedEggTier` 로 옮겨 가고 `eggTier` 는 비어야 한다 — 둘 다 세워 두면 정확히
    /// 그 sanitize 경로에 걸려 증발한다(파킹이 무의미해진다).
    func testRetrieveStoredParksEggGuaranteeInsteadOfRejecting() {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyEgg(.rare))
        XCTAssertEqual(s.state.eggTier, .rare)
        let id = try! XCTUnwrap(s.state.stored.first?.id)

        XCTAssertTrue(s.canRetrieveStored(id), "보증이 걸렸다고 꺼내기가 막히면 안 된다")
        XCTAssertTrue(s.retrieveStored(id: id))

        XCTAssertNotNil(s.state.active, "꺼낸 개체가 활성이 되지 않았다")
        XCTAssertEqual(s.state.parkedEggTier, .rare, "산 보증이 파킹되지 않고 증발했다")
        XCTAssertNil(s.state.eggTier, "활성과 공존하는 eggTier 는 sanitize 에서 지워진다 — 비워야 한다")
        XCTAssertNil(s.eggGuarantee, "활성 개체가 있는 동안 알 보증 표시가 뜨면 안 된다")
    }

    /// 정상 경로 — 알 상태(활성 없음, 보증 없음)에서 꺼내면 중단한 형태(usedAtStage 포함)부터 복원된다.
    func testRetrieveStoredRestoresMidGrowthState() {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyFreshEgg())
        let id = try! XCTUnwrap(s.state.stored.first?.id)

        XCTAssertTrue(s.canRetrieveStored(id))
        XCTAssertTrue(s.retrieveStored(id: id))

        XCTAssertNotNil(s.state.active)
        XCTAssertEqual(s.state.active?.baseID, 349)
        XCTAssertEqual(s.state.active?.stageIndex, 0)
        XCTAssertEqual(s.state.active?.usedAtStage, 200_000_000, "육성 상태(성장분)가 그대로 복원돼야 한다")
        XCTAssertTrue(s.state.active?.pickedByUser ?? false, "직접 꺼낸 개체는 pickedByUser 가 서야 한다")
        XCTAssertTrue(s.state.stored.isEmpty, "꺼낸 뒤 보관함에서 제거된다")
    }

    /// 존재하지 않는 id 로 꺼내기를 시도하면 실패한다(참칭 호출자 방어).
    func testRetrieveStoredRejectsUnknownID() {
        let s = store(json: activeStoreJSON())
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertFalse(s.retrieveStored(id: "does-not-exist"))
        XCTAssertEqual(s.state.stored.count, 1, "실패한 호출이 보관함을 바꾸면 안 된다")
    }

    // MARK: D — pickedByUser 필드 round-trip (필드 모양만, 동작은 다음 단계)

    /// 새 필드가 없는 구버전 JSON 은 false 로 흡수되고, 있으면 그대로 round-trip 된다.
    func testPickedByUserFieldDefaultsFalseAndRoundTrips() throws {
        let legacyMonJSON = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"common\",\"totalForms\":1}"
        let legacyMon = try JSONDecoder().decode(MonState.self, from: Data(legacyMonJSON.utf8))
        XCTAssertFalse(legacyMon.pickedByUser, "필드 없는 구버전 세이브는 false 로 흡수")

        var picked = legacyMon
        picked.pickedByUser = true
        let data = try JSONEncoder().encode(picked)
        let decoded = try JSONDecoder().decode(MonState.self, from: data)
        XCTAssertTrue(decoded.pickedByUser, "true 값이 round-trip 에서 유실됐다")
    }

    // MARK: [리뷰 W1] retrieveStored 가 남의 개체 졸업 배너를 정리하는가

    /// `graduate()` 직후 6초 창(`justGraduated`/`eventUntil` 이 살아있는 동안)에도 꺼내기 게이트는
    /// 열려 있다(`!isHatching`) — 특수 조건 없이 정상 플레이 경로로 도달한다. `buyEgg`/`applySave` 는 이 1회성 배너 필드를
    /// 정리하지만 `retrieveStored` 는 원래 정리하지 않았다 — 방치하면 방금 졸업시킨 개체의
    /// 이름으로 "졸업했어요" 배너가 꺼낸 개체 위에 최대 6초간 뜬다(CompanionView.swift 의
    /// `justGraduated`/`computeState` 소비 지점). 리뷰 지적으로 `buyEgg` 와 동일한 세 줄
    /// (`justGraduated`/`justEvolvedTo`/`eventUntil` = nil)을 `retrieveStored` 에도 추가했다.
    func testRetrieveStoredClearsGraduationBannerFromPreviousMon() async {
        // 보관 1건(vmonLine, baseID 349) 선 시드 + 무진화 1단계 종(noEvoLine, baseID 20)을
        // 부화시켜 곧장 졸업까지 밀어붙인다 — graduate() 가 남기는 배너가 실제로 뜬 상태를 만든다.
        let noEvoLine = EvoLine(baseID: 20, tree: EvoNode(speciesID: 20, children: []),
                                rarity: .common, names: [20: ["ko": "패트몬"]])
        let storedMonJSON = "{\"id\":\"stored-1\",\"mon\":{\"baseID\":349,\"pathIDs\":[349],"
            + "\"stageIndex\":0,\"usedAtStage\":200000000,\"rarity\":\"uncommon\",\"totalForms\":2},"
            + "\"storedAt\":\(now.timeIntervalSince1970)}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,"
            + "\"dex\":[],\"stored\":[\(storedMonJSON)],\"collectedFinals\":[]}"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-banner-\(UUID().uuidString).json")
        try! json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: StubProvider(value: noEvoLine), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))

        await s.hatch(baseID: 20)
        s.applyUsage(DigimonBalance.graduationTotal(.common))   // 무진화 졸업 → graduate()
        XCTAssertNil(s.state.active, "사전 조건 — 졸업으로 active 가 비었다")
        XCTAssertNotNil(s.justGraduated, "사전 조건 — 배너가 실제로 떠 있어야 아래 단언이 의미 있다")
        XCTAssertEqual(s.displayState, .levelUp, "사전 조건 — 6초 창이 열려 있어야 한다(eventUntil 은 private, computeState 경유로 관찰)")

        XCTAssertTrue(s.canRetrieveStored("stored-1"), "졸업 직후 6초 창에서도 꺼내기는 열려 있다")
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))

        XCTAssertNil(s.justGraduated, "남의 개체(패트몬) 졸업 배너가 꺼낸 개체(브이몬) 위에 남아있다")
        XCTAssertNil(s.justEvolvedTo, "남의 개체 기준의 진화 배너가 남아있다")

        // [재리뷰 S1 — 미해결, 의도적 보류] `eventUntil` **단독** 축은 여기서 단언하지 않는다.
        // 리뷰가 "`eventUntil = nil` 만 지우는 뮤테이션은 green 일 것"이라 예측했고, 뮤테이션으로
        // 실제 확인한 결과 **예측이 맞았다**. 다만 닫으려고 시도한 방법(`update()` 를 태워
        // `displayState != .levelUp` 단언)도 **똑같이 green 이라 판별력이 없다** — 뮤테이션 트리에서
        // 측정값이 `.levelUp` 이 아니라 `.idle` 이었다. 원인은 `graduate()`/`retrieveStored` 가
        // 둘 다 `Task { }` 로 비동기 작업을 띄우고(`ensureEggPrefetch`/`loadCurrentLine`), async
        // 테스트에서 그 틈에 끼어든 틱이 창을 정리하기 때문이다. 즉 이 축은 `displayState` 경유로
        // **안정적으로 관측되지 않는다.**
        //
        // 판별력 없는 단언을 넣으면 "이 축이 닫혀 있다"는 거짓 신호만 남으므로 넣지 않는다.
        // 제대로 닫으려면 `eventUntil` 을 테스트에서 읽을 수 있게 하거나(private 해제 대신
        // `internal` + 주석), 비동기 틱이 끼지 않는 동기 경로로 재구성해야 한다 — 별도 작업.
        // 프로덕션 세 줄 자체는 위 두 단언이 묶음으로 고정한다(세 줄 제거 뮤테이션 → 레드 확인).
    }

    // MARK: [리뷰 S3] storedMons 정렬 방향

    /// `storedMons` 는 최신 보관순(내림차순)이어야 한다 — 다음 단계 보관함 UI 가 소비할 유일한
    /// 정렬 표면인데 방향을 고정하는 단언이 없었다(리뷰 지적). JSON 시드 순서를 오래된→최신으로
    /// 넣어, `state.stored` 원본 순서를 그대로 반환하면 이 단언이 레드가 되도록 구성했다.
    func testStoredMonsSortsNewestFirst() {
        let older = "{\"id\":\"stored-old\",\"mon\":{\"baseID\":349,\"pathIDs\":[349],"
            + "\"stageIndex\":0,\"usedAtStage\":0,\"rarity\":\"uncommon\",\"totalForms\":2},"
            + "\"storedAt\":\(now.timeIntervalSince1970)}"
        let newer = "{\"id\":\"stored-new\",\"mon\":{\"baseID\":349,\"pathIDs\":[349],"
            + "\"stageIndex\":0,\"usedAtStage\":0,\"rarity\":\"uncommon\",\"totalForms\":2},"
            + "\"storedAt\":\(now.addingTimeInterval(60).timeIntervalSince1970)}"
        // 시드 순서는 일부러 오래된 것 먼저 — state.stored 원본 순서를 그대로 반환하면 통과하지
        // 않도록(정렬이 실제로 일어나는지 검증).
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,"
            + "\"dex\":[],\"stored\":[\(older),\(newer)],\"collectedFinals\":[]}"
        let s = store(json: json)
        XCTAssertEqual(s.storedMons.map(\.id), ["stored-new", "stored-old"],
                       "storedMons 는 최신 보관순이어야 한다")
    }

    // MARK: 방생 (releaseStored — 도감에 기록을 남기고 보관함에서 제거)
    //
    // 보관과 방생은 **도감 축이 반대다**: 보관은 도감을 전혀 건드리지 않고(함정 1), 방생은
    // `releasedAt` 이 선 기록을 남긴다. 그런데 죠그레스 파트너 자격은 **둘 다 주지 않는다** —
    // `hasJogressPartnerRecord` 가 `!entry.isReleased` 를 보기 때문이다. 같은 결론에 서로 다른
    // 이유로 도달하므로 두 경로를 각각 고정한다.

    /// 도감 항목 1건 + **보관 개체 1건**만 있는 세이브. 활성은 비운다(방생은 활성과 무관하지만,
    /// 꺼내기와 달리 활성이 있어도 되는 축은 별도 테스트로 고정한다).
    /// 보관 개체는 브이몬 라인의 349→358 중 **stageIndex 1 까지 도달**했고 계획 경로는
    /// 미도달 종(999)을 하나 더 들고 있다 — `chainOrder` 가 도달분인지 계획분인지 갈라진다.
    private func storedOnlyJSON(id: String = "stored-1") -> String {
        let mon = "{\"baseID\":349,\"pathIDs\":[349,358],\"plannedPathIDs\":[349,358,999],"
            + "\"stageIndex\":1,\"usedAtStage\":300000000,\"rarity\":\"uncommon\",\"totalForms\":3}"
        let dex = "{\"baseID\":1,\"finalID\":3,\"chainOrder\":[1,2,3],\"rarity\":\"common\"}"
        return "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":5000,\"spentTokens\":0,\"lastDate\":\"d\",\"active\":null,"
            + "\"dex\":[\(dex)],\"stored\":[{\"id\":\"\(id)\",\"mon\":\(mon),"
            + "\"storedAt\":\(now.timeIntervalSince1970)}],\"collectedFinals\":[]}"
    }

    /// 활성 개체(349, stageIndex 0) + 보관 1건(같은 형태)을 함께 시드한다 — 방생이 활성과 무관하다는
    /// 축과 꺼내기 불가 사유 ①(활성 존재)을 동기적으로 본다.
    private func activeAndStoredJSON() -> String {
        let active = "{\"baseID\":349,\"pathIDs\":[349],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"uncommon\",\"totalForms\":2}"
        return storedOnlyJSON().replacingOccurrences(of: "\"active\":null", with: "\"active\":\(active)")
    }

    /// [핵심] 방생은 도감 기록을 만들고 보관함에서 제거한다. 기록은 **방생분**(`isReleased`)이고
    /// `chainOrder` 는 **도달분**이다.
    func testReleaseStoredAppendsReleasedDexEntryAndRemovesFromStorage() {
        let s = store(json: storedOnlyJSON())
        XCTAssertEqual(s.state.dex.count, 1)

        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        XCTAssertTrue(s.state.stored.isEmpty, "방생한 개체는 보관함에서 사라진다")
        XCTAssertEqual(s.state.dex.count, 2, "방생은 도감에 기록을 남긴다")
        let entry = s.state.dex.last!
        XCTAssertEqual(entry.baseID, 349)
        XCTAssertTrue(entry.isReleased, "방생 기록은 releasedAt 이 서야 한다 — 졸업분과 같은 형태면 안 된다")
        XCTAssertFalse(entry.isArmored)
        XCTAssertEqual(entry.caughtAt, now)
        XCTAssertEqual(entry.releasedAt, now)
        XCTAssertEqual(entry.rarity, .uncommon)
        XCTAssertEqual(entry.finalID, 358, "사다리 끝(currentID)이어야 한다")
    }

    /// `chainOrder` 는 도달분 `prefix(stageIndex + 1)` — `plannedPathIDs`(미도달 999 포함)를 쓰면
    /// 진화하지 않은 종이 도감에 생긴다. 직전 커밋에서 `dexSpecies` 가 stored/active 를 접을 때
    /// 확립한 규칙과 같아야 한다. 리터럴로 고정한다(보간하면 구현을 바꿔도 초록으로 남는다).
    func testReleaseStoredChainOrderUsesReachedPrefixNotPlannedPath() {
        let s = store(json: storedOnlyJSON())
        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        XCTAssertEqual(s.state.dex.last?.chainOrder, [349, 358],
                       "도달분만 — plannedPathIDs(349,358,999)를 쓰면 미도달 999 가 도감에 생긴다")
        XCTAssertFalse(s.dexSpecies.contains { $0.id == 999 },
                       "미도달 종이 도감 목록에 나타나면 안 된다")
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 358 },
                      "도달한 종은 방생 후에도 도감에 남는다(도감은 쌓이기만 한다)")
    }

    /// `collectedFinals` **미오염** — `graduate()` 는 `insert("base:final")` 를 하지만 방생은
    /// 졸업이 아니다. 여기 들어가면 최종체 완성 기록·분기 가중이 오염된다.
    func testReleaseStoredDoesNotTouchCollectedFinals() {
        let s = store(json: storedOnlyJSON())
        XCTAssertTrue(s.state.collectedFinals.isEmpty)

        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        XCTAssertTrue(s.state.collectedFinals.isEmpty,
                      "방생은 졸업이 아니다 — collectedFinals 가 늘면 graduate() 를 베낀 것이다")
        XCTAssertFalse(s.state.hasCollectedFinal(forBaseID: 349))
    }

    /// 방생이 **새 죠그레스 파트너 자격을 만들지 않는다.** 보관(함정 1b)과 같은 결론이지만 이유가
    /// 다르다: 보관은 도감을 안 건드려서, 방생은 남는 기록이 `isReleased` 라서
    /// (`hasJogressPartnerRecord` 의 `!entry.isReleased` 게이트).
    ///
    /// 두 축이 갈라진다는 것이 요점이다 — **도감 보유(`dexSpecies`)에는 나타나고**, 파트너
    /// 자격에는 나타나지 않는다. 그래서 두 단언을 반대 방향으로 함께 세운다(한쪽만 보면
    /// `releasedAt` 을 안 세우는 구현도, 기록을 아예 안 만드는 구현도 초록으로 지나간다).
    func testReleaseStoredGrantsDexOwnershipButNotJogressPartnerEligibility() {
        let s = store(json: storedOnlyJSON())
        XCTAssertFalse(s.hasJogressPartnerRecord(358), "사전 조건 — 358 은 아직 파트너 자격이 없다")

        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        XCTAssertTrue(s.dexSpecies.contains { $0.id == 358 }, "도감 보유에는 나타난다")
        XCTAssertFalse(s.hasJogressPartnerRecord(358),
                       "방생 기록은 파트너 자격을 주지 않는다 — releasedAt 을 세우지 않으면 레드")
        XCTAssertFalse(s.hasJogressPartnerRecord(349),
                       "체인 중간 종도 같다 — 자격은 졸업·죠그레스 기록만 준다")
        XCTAssertTrue(s.hasJogressPartnerRecord(1), "기존 졸업 기록의 자격은 그대로")
    }

    /// 종 **보유**는 방생 전후로 바뀌지 않는다 — 같은 도달분이 `stored` 경로에서 `dex` 경로로
    /// 옮겨 가고 `ownsSpecies` 는 `isReleased` 를 보지 않는다. 그래서 대표 디지몬 선택도 유지된다
    /// (`reconcileRepresentativeSelection()` 을 부르지 않는 근거).
    func testReleaseStoredPreservesSpeciesOwnershipAndRepresentative() {
        // 대표 선택은 JSON 으로 시드한다(`state` 는 테스트에서 읽기 전용).
        let json = storedOnlyJSON().replacingOccurrences(
            of: "\"collectedFinals\":[]", with: "\"collectedFinals\":[],\"representativeSpeciesID\":358")
        let s = store(json: json)
        XCTAssertEqual(s.representativeSpeciesID, 358, "사전 조건 — 대표가 시드돼야 한다")
        XCTAssertTrue(s.state.ownsSpecies(358), "사전 조건 — 보관 경로로 보유")

        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        XCTAssertTrue(s.state.ownsSpecies(358), "방생 후에도 도감 경로로 계속 보유")
        XCTAssertEqual(s.representativeSpeciesID, 358,
                       "보유가 끊기지 않으므로 대표 선택이 날아가면 안 된다")
    }

    /// 실패 조건 — 존재하지 않는 id 는 상태를 전혀 바꾸지 않는다(`retrieveStored` 와 같은 방어).
    func testReleaseStoredRejectsUnknownID() {
        let s = store(json: storedOnlyJSON())
        let dexIDsBefore = Set(s.state.dex.map(\.id))

        XCTAssertFalse(s.releaseStored(id: "does-not-exist"))

        XCTAssertEqual(s.state.stored.count, 1, "실패한 호출이 보관함을 바꾸면 안 된다")
        XCTAssertEqual(Set(s.state.dex.map(\.id)), dexIDsBefore, "실패한 호출이 도감을 늘리면 안 된다")
    }

    /// 방생은 **활성 개체가 있어도** 된다 — 다른 디지몬을 키우는 중에 보관함을 정리하는 정상 케이스다.
    /// (`isHatching` 으로 게이트하는 `canRetrieveStored` 를 방생에도 재사용하면 이 경로가 막힌다.)
    func testReleaseStoredWorksWhileAnotherDigimonIsActive() {
        // "활성 + 보관 1건" 을 JSON 으로 직접 시드한다(`testRetrieveStoredRejectedWhileActiveExists`
        // 와 같은 방식 — 비동기 경합 없이 동기 경로만 본다).
        let s = store(json: activeAndStoredJSON())
        XCTAssertNotNil(s.state.active)
        XCTAssertEqual(s.state.stored.count, 1, "사전 조건 — 보관 1건이 시드돼야 한다")

        XCTAssertTrue(s.releaseStored(id: "stored-1"), "활성이 있어도 방생은 돼야 한다")
        XCTAssertTrue(s.state.stored.isEmpty)
        XCTAssertEqual(s.state.active?.baseID, 349, "방생이 활성 개체를 건드리면 안 된다")
    }

    /// 방생 기록에 **이름이 심긴다** — 보관 개체엔 `currentLine` 이 없어 `graduate()` 처럼 라인에서
    /// 뜰 수 없다. 비워 두면 `needsNamesRefresh` 가 영영 true 라 `backfillMissingDexNames` 가 매번
    /// 라인을 조회하는데, 그 조회는 이 항목을 절대 채우지 못한다(`recordArmorDexEntry` 와 같은 이유).
    func testReleaseStoredSeedsChainNamesFromBundledData() {
        let s = store(json: storedOnlyJSON())
        XCTAssertTrue(s.releaseStored(id: "stored-1"))
        let entry = try! XCTUnwrap(s.state.dex.last)

        XCTAssertFalse(entry.needsNamesRefresh,
                       "이름이 비면 백필이 영원히 재시도한다 — 번들 데이터에서 심어야 한다")
        for id in [349, 358] {
            XCTAssertFalse(entry.names?[id]?.isEmpty ?? true, "체인 종 \(id) 의 이름이 비어 있다")
        }
    }

    /// [아머 축] 아머 착용 중이던 개체를 방생하면 기록은 **사다리 종**으로 남고, 그 개체가 입었던
    /// 아머 기록(`isArmored`)은 **따로 살아 있다.** 두 기록은 섞이지 않는다.
    ///
    /// 왜 방생 기록에 `armoredAt` 을 세우지 않는가:
    ///  - 아머 기록은 **착용 시점에 이미 만들어진다** — `useDigimental`(:939)이 `recordArmorDexEntry`
    ///    를 부르고, 그 항목은 되돌려도 남는 영구 기록이다(:963 주석). 방생 시점에 또 만들면 같은
    ///    사실이 두 줄이 되고, `armor-<instanceID>-<armorID>` 로 접는 규칙도 무의미해진다.
    ///  - 방생분의 `chainOrder`/`finalID` 는 **사다리**여야 한다(`ShopView.swift:197` 주석의 근거와
    ///    같다 — 보관/꺼내기가 사다리 기준이므로 표시 이름을 쓰면 실제 보관 대상과 다른 종을 가리킨다).
    ///    아머체는 `pathIDs` 에 없는 표시 오버레이라 `prefix(stageIndex + 1)` 에 애초에 안 들어온다.
    ///  - 한 줄에 `releasedAt` 과 `armoredAt` 을 같이 세우면 `isReleased`·`isArmored` 가 동시에 참이
    ///    되어 두 축을 가르는 도감 뱃지 분기(`CompanionView` 의 else-if 사슬)가 아머로만 읽힌다.
    func testReleasingArmoredStoredMonRecordsLadderSpeciesAndKeepsArmorRecordSeparate() {
        // V-mon(349, stageIndex 0) + 용기 디지멘탈 → Fladramon(305). 아머를 씌운 뒤 알을 사서 보관하고,
        // 그 보관 개체를 방생한다. 아머 기록은 착용 시점(useDigimental)에 이미 생긴다.
        let mon = "{\"baseID\":349,\"pathIDs\":[349],\"stageIndex\":0,\"usedAtStage\":0,"
            + "\"rarity\":\"uncommon\",\"totalForms\":2}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":5000000000,\"spentTokens\":0,\"lastDate\":\"d\","
            + "\"active\":\(mon),\"dex\":[],\"stored\":[],\"collectedFinals\":[],"
            + "\"inventory\":{\"\(ItemKind.digimentalCourage.rawValue)\":1}}"
        let s = store(json: json)
        XCTAssertTrue(s.useDigimental(.digimentalCourage), "사전 조건 — 아머 착용")
        XCTAssertEqual(s.state.active?.armorID, 305)
        let armorEntries = s.state.dex.filter(\.isArmored)
        XCTAssertEqual(armorEntries.count, 1, "사전 조건 — 착용 시점에 아머 기록이 생긴다")
        XCTAssertEqual(armorEntries.first?.finalID, 305)

        XCTAssertTrue(s.buyFreshEgg(), "아머 착용 개체를 보관")
        let storedID = try! XCTUnwrap(s.state.stored.first?.id)
        XCTAssertEqual(s.state.stored.first?.mon.armorID, 305, "보관 개체가 아머를 들고 있다")

        XCTAssertTrue(s.releaseStored(id: storedID))

        // 방생분은 사다리 종(349)이다 — 아머체(305)가 chainOrder/finalID 에 들어가면 안 된다.
        let releasedEntries = s.state.dex.filter(\.isReleased)
        XCTAssertEqual(releasedEntries.count, 1)
        let released = try! XCTUnwrap(releasedEntries.first)
        XCTAssertEqual(released.chainOrder, [349], "방생 기록은 사다리 도달분이어야 한다")
        XCTAssertEqual(released.finalID, 349, "표시 축(displayID=305)이 아니라 사다리(currentID)")
        XCTAssertFalse(released.isArmored,
                       "한 줄에 두 축을 세우면 도감 뱃지 분기가 아머로만 읽힌다")

        // 아머 기록은 따로 살아 있다 — 방생이 지우거나 흡수하면 안 된다(되돌려도 남는 영구 기록).
        XCTAssertEqual(s.state.dex.filter(\.isArmored).count, 1, "아머 기록이 방생에 흡수됐다")
        XCTAssertEqual(s.state.dex.count, 2, "아머 1줄 + 방생 1줄 — 접히거나 중복되면 안 된다")

        // 둘 다 죠그레스 자격은 주지 않는다(`!isReleased && !isArmored`).
        XCTAssertFalse(s.hasJogressPartnerRecord(349), "방생분은 자격을 주지 않는다")
        XCTAssertFalse(s.hasJogressPartnerRecord(305), "아머분도 자격을 주지 않는다")
        // 그래도 도감 보유에는 둘 다 나타난다(도감은 쌓이기만 한다).
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 349 })
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 305 })
    }

    /// [수입 경계] 방생 기록이 `SaveTransfer` 내보내기→불러오기를 통과해도 **방생분으로 남는다.**
    ///
    /// 이 축이 위 in-memory 테스트와 별개인 이유: `releasedAt` 이 round-trip 에서 떨어지면 항목이
    /// **졸업 형태**(`releasedAt`/`armoredAt` 둘 다 nil)로 돌아오고, 그 순간
    /// `hasJogressPartnerRecord` 가 349/358 에 true 를 주기 시작한다 — 직전 커밋이 두 테스트로 닫은
    /// 이중 계수가 수입 경계를 통해 되살아난다. `applySave` 뒤의 `save()` 가 결과를 현재 세대로
    /// 재인코딩하므로 여기서 세탁되면 디스크에도 영구히 남는다.
    ///
    /// 판별력 있는 단언은 두 번째다 — `isReleased` 만 보면 필드는 살았지만 sanitize 가 항목을
    /// 재구성하는 구현이 통과한다. 날짜 **값**은 단언하지 않는다: 디스크와 전송의 날짜 전략이 달라
    /// (1970 vs 2001) 31년 어긋나는 게 정상이고, 계약은 `!= nil` 하나다.
    func testReleasedDexEntrySurvivesSaveTransferWithoutRegainingPartnerEligibility() throws {
        let s = store(json: storedOnlyJSON())
        XCTAssertTrue(s.releaseStored(id: "stored-1"))
        XCTAssertFalse(s.hasJogressPartnerRecord(358), "사전 조건 — 방생 직후엔 자격이 없다")

        let data = try s.exportedSaveData(appVersion: "1.0", deviceName: "MacTest")
        let envelope = try SaveTransfer.decode(data)

        let released = envelope.state.dex.filter(\.isReleased)
        XCTAssertEqual(released.count, 1, "방생 기록이 수입에서 졸업 형태로 세탁됐다")
        XCTAssertEqual(released.first?.chainOrder, [349, 358])

        // 실제로 적용까지 해서 `applySave` → `save()` 경로가 자격을 만들지 않는지 본다.
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-release-transfer-\(UUID().uuidString).json")
        let target = store(json: "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"active\":null,\"dex\":[]}",
                           at: targetURL)
        try target.applySave(envelope, todayTokensByProvider: [:], todayDate: "2026-09-29", hasUsageData: false)

        XCTAssertFalse(target.hasJogressPartnerRecord(358),
                       "수입된 방생 기록이 파트너 자격을 만들면 이중 계수가 되살아난다")
        XCTAssertFalse(target.hasJogressPartnerRecord(349))
        XCTAssertTrue(target.dexSpecies.contains { $0.id == 358 }, "도감 보유는 수입 후에도 유지된다")
    }

    /// 방생이 디스크에 영속된다 — 재시작 후에도 보관함은 비어 있고 도감 기록은 남는다.
    func testReleaseStoredPersistsAcrossReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-release-\(UUID().uuidString).json")
        let s = store(json: storedOnlyJSON(), at: url)
        XCTAssertTrue(s.releaseStored(id: "stored-1"))

        let reloaded = CompanionStore(provider: StubProvider(value: vmonLine), clock: { self.now },
                                     fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertTrue(reloaded.state.stored.isEmpty, "방생이 저장되지 않았다 — save() 누락")
        XCTAssertEqual(reloaded.state.dex.count, 2)
        XCTAssertTrue(reloaded.state.dex.contains { $0.isReleased && $0.baseID == 349 })
    }

    // MARK: 꺼내기 불가 사유 / 진입점 게이트 (뷰가 읽는 표면 — 판정은 store 에 있다)

    /// 사유 문구는 `canRetrieveStored` 를 그대로 뒤집는다 — 꺼낼 수 있으면 nil.
    ///
    /// 조건이 하나(부화 중)뿐인 건 설계가 바뀐 결과다: 활성 개체가 있는 상태와 보증 알을 품은 상태는
    /// 이제 열린 게이트이므로 **사유가 없어야 한다.** 옛 문구가 남아 있으면 바로 꺼낼 수 있는 행에
    /// "졸업시키거나 알을 새로 사라"는 차단 안내가 붙는다(부화 중 축은
    /// `testRetrieveStoredRejectedWhileHatchInFlight` 가 전담한다 — 그 창은 비동기라야 열린다).
    func testStoredRetrieveBlockReasonIsNilWheneverGateIsOpen() {
        // ① 알 상태(활성 없음·보증 없음) — 꺼낼 수 있으니 사유가 없다.
        let open = store(json: storedOnlyJSON())
        XCTAssertTrue(open.canRetrieveStored("stored-1"))
        XCTAssertNil(open.storedRetrieveBlockReason("stored-1"), "꺼낼 수 있는데 사유 문구가 뜨면 안 된다")

        // ② 활성 개체가 있으면 교체다 — 차단이 아니므로 사유도 없다.
        let busy = store(json: activeAndStoredJSON())
        XCTAssertTrue(busy.canRetrieveStored("stored-1"), "활성이 있어도 교체로 열려 있다")
        XCTAssertNil(busy.storedRetrieveBlockReason("stored-1"), "교체 가능한데 차단 사유가 떴다")

        // ③ 등급 보증 알 — 보증은 파킹되므로 차단이 아니다(`buyEgg` 가 만드는 실제 상태와 같은 모양).
        let guaranteed = store(json: storedOnlyJSON().replacingOccurrences(
            of: "\"active\":null", with: "\"active\":null,\"eggTier\":\"rare\""))
        XCTAssertEqual(guaranteed.state.eggTier, .rare, "사전 조건 — 보증이 시드돼야 한다")
        XCTAssertTrue(guaranteed.canRetrieveStored("stored-1"), "보증은 파킹 대상이지 차단 사유가 아니다")
        XCTAssertNil(guaranteed.storedRetrieveBlockReason("stored-1"))
    }

    /// 존재하지 않는 id 는 사유가 없다 — 목록에 뜬 행은 항상 실 id 라 도달하지 않고, 안내할
    /// 사용자 행동도 없다(문구를 만들면 유령 행에 대한 설명이 생긴다).
    func testStoredRetrieveBlockReasonIsNilForUnknownID() {
        let s = store(json: activeStoreJSON())
        XCTAssertNil(s.storedRetrieveBlockReason("does-not-exist"))
    }

    /// 진입점 게이트 — 보관 개체가 0건이면 보관함 버튼을 숨긴다(`canPickHatchSpecies` 선례).
    func testCanOpenStorageFollowsStoredCount() {
        let s = store(json: activeStoreJSON())
        XCTAssertFalse(s.canOpenStorage, "보관 개체가 없으면 진입점을 숨긴다")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertTrue(s.canOpenStorage)
        let id = try! XCTUnwrap(s.state.stored.first?.id)
        XCTAssertTrue(s.releaseStored(id: id))
        XCTAssertFalse(s.canOpenStorage, "마지막 개체를 방생하면 진입점이 다시 닫힌다")
    }

    // MARK: 보증 파킹 — 꺼내기가 산 보증을 삼키지 않는가 (제품 결정 2026-09-30)

    /// 보증 알 + 보관 1건. 활성은 없다(= 알 상태) — `buyEgg` 를 거치지 않고 파킹 대상 상태만 직접
    /// 시드해 동기 경로만 본다(`storedOnlyJSON` 은 이미 활성 없음 + 보관 1건이다).
    private func guaranteedEggWithStoredJSON(tier: String = "rare", preRoll: Int? = 331,
                                             userPick: Bool = false,
                                             wallet: Int = 50_000_000_000) -> String {
        var extra = ",\"eggTier\":\"\(tier)\""
        if let preRoll { extra += ",\"pendingHatchID\":\(preRoll),\"pendingHatchIsUserPick\":\(userPick)" }
        // 지갑은 JSON 으로 시드한다(`state` 는 테스트에서 읽기 전용) — 알 구매 축에 필요하다.
        return storedOnlyJSON()
            .replacingOccurrences(of: "\"usedSinceInstall\":5000", with: "\"usedSinceInstall\":\(wallet)")
            .replacingOccurrences(of: "\"active\":null", with: "\"active\":null" + extra)
    }

    /// [핵심] 보증 알을 품은 채 꺼냈다가 **다시 알 상태가 되면 보증이 복원된다.**
    ///
    /// 이 테스트가 없으면 파킹은 반쪽이다 — `retrieveStored` 가 값을 옮기기만 하고 아무도 되돌리지
    /// 않으면 사용자 입장에선 증발과 구분되지 않는다(게이트를 열어 준 것이 오히려 손실이 된다).
    /// 복원 지점은 "알이 생기는 순간" 두 곳뿐이다(`graduate`/`buyEgg`) — 여기선 졸업 경로를 본다.
    ///
    /// 파킹 상태를 필드에 직접 심지 않고 `retrieveStored` 로 만든다 — 쓰기 지점을 건너뛰면 그
    /// 지점이 망가져도 초록이다. 졸업도 `applyUsage` 실경로로 도달한다.
    func testParkedGuaranteeIsRestoredWhenEggStateReturnsViaGraduation() async {
        // 보관 개체(349)가 곧장 졸업 가능한 라인 — 꺼낸 그 개체를 키워 졸업까지 민다(활성 교체 없음).
        // stageIndex 1(=358)이 트리의 말단이라 임계 도달 시 `graduate()` 로 떨어진다.
        let finalLine = EvoLine(baseID: 349, tree: EvoNode(speciesID: 349, children: [
            EvoNode(speciesID: 358, children: [])
        ]), rarity: .uncommon, names: [349: ["ko": "브이몬"], 358: ["ko": "엑스브이몬"]])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-park-grad-\(UUID().uuidString).json")
        let s = store(finalLine, json: guaranteedEggWithStoredJSON(preRoll: 331, userPick: true), at: url)
        XCTAssertEqual(s.state.eggTier, .rare, "사전 조건 — 보증 알을 품고 있어야 한다")

        // ① 꺼낸다 → 보증은 파킹되고 현재 알 보증은 비워진다.
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertEqual(s.state.parkedEggTier, .rare)
        XCTAssertNil(s.state.eggTier)
        XCTAssertNil(s.eggGuarantee, "활성이 있는 동안 보증 표시가 뜨면 안 된다")

        // ② 꺼낸 개체를 졸업시킨다 → 새 알이 생기므로 보증이 돌아온다.
        // `retrieveStored` 가 띄운 `loadCurrentLine()` Task 가 끝나야 진화/졸업 판정이 돈다
        // (`applyUsage` 는 `currentLine == nil` 이면 적립만 하고 반환한다).
        for _ in 0..<200 where s.currentLine == nil { await Task.yield() }
        XCTAssertNotNil(s.currentLine, "사전 조건 — 라인이 로드돼야 졸업 판정이 돈다")
        s.applyUsage(DigimonBalance.graduationTotal(.uncommon))

        XCTAssertNil(s.state.active, "사전 조건 — 졸업해서 알 상태가 돼야 한다")
        XCTAssertEqual(s.state.eggTier, .rare, "맡긴 보증이 새 알에 복원되지 않았다 — 산 보증 증발")
        XCTAssertNil(s.state.parkedEggTier, "복원됐으면 파킹 자리는 비워야 한다(두 번 복원되면 영구 프리미엄)")
        XCTAssertEqual(s.eggGuarantee, .rare, "알 상태인데 보증 표시가 뜨지 않는다")
        XCTAssertEqual(s.state.pendingHatchID, 331, "보증과 함께 맡긴 pre-roll 도 돌아와야 한다")

        // ③ 복원이 **디스크에도** 반영됐는가 — 인메모리로만 복원되면 졸업 직후 종료 시 산 보증이
        // 사라진다(`applyUsage` 말미의 `save()` 가 이 경로를 덮는지가 실제 계약이다).
        let reloaded = CompanionStore(provider: StubProvider(value: finalLine), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.eggTier, .rare, "복원된 보증이 저장되지 않았다 — 재시작에서 유실")
        XCTAssertNil(reloaded.state.parkedEggTier)
    }

    /// 보증과 pre-roll 은 **한 묶음**으로 움직인다 — 맡길 때도, 복원할 때도.
    ///
    /// 한쪽만 다루면 두 방향 모두 버그다: pre-roll 만 남기면 졸업으로 받는 **무료** 알이 프리미엄
    /// 롤 결과로 부화하고(`SaveTransfer.sanitized` 의 같은 누수), 보증만 복원하면 사용자가 직접 고른
    /// 종 예고가 꺼내기 한 번으로 사라진다. `pendingHatchIsUserPick` 까지 따라가야 후자가 닫힌다.
    func testParkedGuaranteeMovesAsOneBundleWithItsPreRoll() {
        let s = store(json: guaranteedEggWithStoredJSON(preRoll: 331, userPick: true))
        XCTAssertEqual(s.state.pendingHatchID, 331, "사전 조건 — pre-roll 이 시드돼야 한다")
        XCTAssertTrue(s.state.pendingHatchIsUserPick, "사전 조건 — 사용자 선택 표시가 서야 한다")

        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        // 맡긴 쪽: 세 값이 함께 이동.
        XCTAssertEqual(s.state.parkedEggTier, .rare)
        XCTAssertEqual(s.state.parkedPendingHatchID, 331, "보증만 맡기고 pre-roll 을 버렸다")
        XCTAssertTrue(s.state.parkedPendingHatchIsUserPick, "사용자 선택 표시가 파킹에서 강등됐다")
        // 현재 알 쪽: 알이 없어졌으니 세 값이 비어야 한다.
        XCTAssertNil(s.state.eggTier)
        XCTAssertNil(s.state.pendingHatchID)
        XCTAssertFalse(s.state.pendingHatchIsUserPick)

        // 복원 쪽 묶음은 `CompanionState` 단독으로 본다 — 상태 변환만 보는 축이라 store 를 거칠
        // 필요가 없다(복원 지점이 실제로 이걸 부르는지는 위 졸업 테스트가 지킨다).
        var parked = CompanionState()
        parked.parkedEggTier = .rare
        parked.parkedPendingHatchID = 331
        parked.parkedPendingHatchIsUserPick = true
        parked.restoreParkedEggGuarantee()
        XCTAssertEqual(parked.eggTier, .rare)
        XCTAssertEqual(parked.pendingHatchID, 331, "보증만 복원되고 pre-roll 이 사라졌다")
        XCTAssertTrue(parked.pendingHatchIsUserPick, "사용자 선택 예고가 프리패치 롤로 강등됐다")
        XCTAssertNil(parked.parkedPendingHatchID)
        XCTAssertFalse(parked.parkedPendingHatchIsUserPick)
    }

    /// 파킹 보증은 활성 개체가 있는 동안 **복원되지 않는다** — 보증과 활성은 공존할 수 없어서
    /// (`SaveTransfer.sanitized`) 여기서 복원하면 바로 지워진다(= 파킹이 무의미해진다).
    func testParkedGuaranteeIsNotRestoredWhileActiveExists() {
        let s = store(json: guaranteedEggWithStoredJSON())
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertNotNil(s.state.active, "사전 조건 — 꺼낸 개체가 활성이어야 한다")

        var copy = s.state
        copy.restoreParkedEggGuarantee()   // 활성이 있는 동안 몇 번 불러도 no-op 이어야 한다
        XCTAssertNil(copy.eggTier, "활성이 있는데 보증이 복원됐다 — 다음 sanitize 에서 증발한다")
        XCTAssertEqual(copy.parkedEggTier, .rare, "복원도 안 됐는데 파킹 값이 사라졌다")
        // 실제 경계(디스크 로드·수입)에서도 같아야 한다 — 여기서 복원되면 바로 증발한다.
        XCTAssertNil(SaveTransfer.sanitized(s.state).eggTier)
        XCTAssertEqual(SaveTransfer.sanitized(s.state).parkedEggTier, .rare)
    }

    /// 새로 산 보증과 파킹 보증이 **동시에 유효한 유일한 창** — `canBuyEgg` 가 `hasActive` 를 요구하므로
    /// 파킹 상태(활성 있음)에서도 알을 살 수 있다. 더 높은 쪽만 남고 pre-roll 은 양방향 모두 버려진다.
    ///
    /// pre-roll 을 남기면 두 방향 다 사고다: 낮은 보증의 pre-roll 이 높은 보증 아래 남으면 등급 미달로
    /// 버려지는 낭비고, 높은 보증의 pre-roll 이 낮은 보증 아래 남으면 **사지 않은 프리미엄 결과**가 나온다.
    func testBuyEggWithParkedGuaranteeKeepsHigherTierAndDropsBothPreRolls() {
        // ① 파킹(.rare) > 새로 산 것(무보증 기본 알) — 파킹이 이긴다.
        let a = store(json: guaranteedEggWithStoredJSON(tier: "rare", preRoll: 331, userPick: true))
        XCTAssertTrue(a.retrieveStored(id: "stored-1"))
        XCTAssertEqual(a.state.parkedEggTier, .rare, "사전 조건 — 보증이 파킹돼야 한다")
        XCTAssertTrue(a.buyFreshEgg(), "사전 조건 — 파킹 상태에서도 알을 살 수 있다")
        XCTAssertEqual(a.state.eggTier, .rare, "무보증 알이 파킹된 보증을 덮어 산 것이 사라졌다")
        // 무보증 알은 **충돌이 아니다**(유효한 보증이 파킹된 쪽 하나뿐) — 묶음 전체가 그대로 복원된다.
        // 여기서 pre-roll 을 버리면 사용자가 직접 고른 종 예고만 아무 이유 없이 사라진다.
        XCTAssertEqual(a.state.pendingHatchID, 331, "충돌이 아닌데 pre-roll 이 버려졌다")
        XCTAssertTrue(a.state.pendingHatchIsUserPick, "사용자 선택 표시까지 버려졌다")
        XCTAssertNil(a.state.parkedEggTier, "파킹 자리는 비워야 한다(재복원 = 영구 프리미엄)")

        // ② 파킹(.uncommon) < 새로 산 것(.rare) — 산 쪽이 이긴다(파킹이 강등시키면 안 된다).
        let b = store(json: guaranteedEggWithStoredJSON(tier: "uncommon", preRoll: 331, userPick: true))
        XCTAssertTrue(b.retrieveStored(id: "stored-1"))
        XCTAssertEqual(b.state.parkedEggTier, .uncommon)
        XCTAssertTrue(b.buyEgg(.rare))
        XCTAssertEqual(b.state.eggTier, .rare, "파킹된 낮은 보증이 방금 산 높은 보증을 강등시켰다")
        // 여긴 **진짜 충돌**이다(두 보증이 동시에 유효) — 승자와 무관하게 pre-roll 을 버리고
        // 프리패치가 승자 기준으로 다시 롤한다. 남기면 등급 미달 낭비(낮은→높은) 또는
        // 사지 않은 프리미엄(높은→낮은)이 된다.
        XCTAssertNil(b.state.pendingHatchID, "충돌 창에서 pre-roll 이 살아남았다")
        XCTAssertFalse(b.state.pendingHatchIsUserPick)
        XCTAssertNil(b.state.parkedEggTier)
    }

    /// 파킹이 **재시작을 건너 살아남는다** — 영속 필드가 아니면 앱을 닫는 순간 산 보증이 사라진다
    /// (`pendingHatchIsUserPick` 이 저장 필드여야 하는 것과 같은 이유).
    func testParkedGuaranteeSurvivesRestart() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-park-rt-\(UUID().uuidString).json")
        let s = store(json: guaranteedEggWithStoredJSON(preRoll: 331, userPick: true), at: url)
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertEqual(s.state.parkedEggTier, .rare, "사전 조건 — 파킹돼야 한다")

        let reloaded = CompanionStore(provider: StubProvider(value: vmonLine), clock: { self.now },
                                      fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.state.parkedEggTier, .rare, "파킹 보증이 재시작에서 유실됐다")
        XCTAssertEqual(reloaded.state.parkedPendingHatchID, 331)
        XCTAssertTrue(reloaded.state.parkedPendingHatchIsUserPick)
        XCTAssertNil(reloaded.state.eggTier, "활성이 있으므로 현재 알 보증은 여전히 비어 있어야 한다")
    }

    /// 파킹이 `SaveTransfer` 내보내기→불러오기를 통과한다 — 다른 기기로 옮기는 중에 파킹 상태였다면
    /// 그 보증도 따라가야 한다(분류를 빼먹으면 이전 직후 알이 생기는 순간에만 드러난다).
    ///
    /// `applySave` 는 `load()` 를 타지 않으므로 `sanitized` 가 이 경로의 유일한 경계다.
    func testParkedGuaranteeSurvivesSaveTransferRoundTrip() throws {
        let s = store(json: guaranteedEggWithStoredJSON(preRoll: 331, userPick: true))
        XCTAssertTrue(s.retrieveStored(id: "stored-1"))
        XCTAssertEqual(s.state.parkedEggTier, .rare, "사전 조건 — 파킹돼야 한다")

        let data = try s.exportedSaveData(appVersion: "1.0", deviceName: "MacTest")
        let envelope = try SaveTransfer.decode(data)
        XCTAssertEqual(envelope.state.parkedEggTier, .rare, "파킹 보증이 수입 경계에서 사라졌다")
        XCTAssertEqual(envelope.state.parkedPendingHatchID, 331)
        XCTAssertTrue(envelope.state.parkedPendingHatchIsUserPick)
    }

    /// 파킹 필드가 **없는** 세이브(이 기능 이전 형태)는 관대 디코딩이 "맡긴 것 없음"으로 흡수한다 —
    /// `saveVersion` 을 올리지 않았으므로(순수 추가 필드) `.legacy` 백업도 생기지 않아야 한다.
    func testSaveWithoutParkedFieldsDecodesAsNothingParked() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stored-park-legacy-\(UUID().uuidString).json")
        try Data(storedOnlyJSON().utf8).write(to: url)
        let s = store(json: storedOnlyJSON(), at: url)

        XCTAssertNil(s.state.parkedEggTier)
        XCTAssertNil(s.state.parkedPendingHatchID)
        XCTAssertFalse(s.state.parkedPendingHatchIsUserPick)
        XCTAssertEqual(s.state.stored.count, 1, "파킹 필드가 없다고 보관함이 날아가면 안 된다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("legacy").path),
                       "순수 추가 필드는 세대 불일치가 아니다 — .legacy 백업이 생기면 안 된다")
    }
}
