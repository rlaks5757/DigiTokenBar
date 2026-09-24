import XCTest
@testable import DigiTokenBar

private actor MigratingNameProvider: DigimonLineProviding {
    var value: EvoLine
    var offline = false
    private(set) var calls = 0
    init(_ names: [Int: [String: String]]) {
        value = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [])]),
                        rarity: .common, names: names)
    }
    func configure(names: [Int: [String: String]], offline: Bool = false) {
        value = EvoLine(baseID: 1, tree: value.tree, rarity: .common, names: names)
        self.offline = offline
    }
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        calls += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        if offline { throw URLError(.notConnectedToInternet) }
        return value
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
}

@MainActor
final class DexNameMigrationTests: XCTestCase {
    let allNames = [1: ["ko": "이상해씨", "en": "Bulbasaur", "it": "Bulbasaur"],
                    2: ["ko": "이상해풀", "en": "Ivysaur", "it": "Ivysaur"]]

    private func entry(_ id: String = "old-catch") -> DexEntry {
        DexEntry(id: id, baseID: 1, finalID: 2, chainOrder: [1, 2], rarity: .common,
                 caughtAt: Date(timeIntervalSince1970: 123),
                 names: [1: ["en": "Bulbasaur"], 2: ["en": "Ivysaur"]])
    }

    private func fixture(_ entries: [DexEntry], legacy: Bool = true) throws -> URL {
        var state = CompanionState()
        state.dex = entries
        state.language = .ko
        state.usedSinceInstall = 1234567
        state.inventory = ["rareCandy": 3]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        if legacy {
            json["dex"] = try XCTUnwrap(json["dex"] as? [[String: Any]]).map { row in
                var row = row
                row.removeValue(forKey: "namesVersion")
                return row
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dex-language-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testLegacyNamedEntriesRefreshAllLanguagesOnceAndPreserveProgress() async throws {
        let url = try fixture([entry(), entry("second-catch")])
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = MigratingNameProvider(allNames)
        let store = CompanionStore(provider: provider, fileURL: url)
        let old = try XCTUnwrap(store.state.dex.first)
        XCTAssertNil(old.namesVersion, "Old JSON did not encode a name version")
        XCTAssertEqual(store.dexStoredChainNames(old)?[1], "Bulbasaur")
        await store.backfillMissingDexNames()
        XCTAssertEqual(store.state.dex.count, 2)
        XCTAssertEqual(store.state.dex[0].id, old.id)
        XCTAssertEqual(store.state.dex[0].caughtAt, old.caughtAt)
        XCTAssertEqual(store.state.usedSinceInstall, 1234567)
        XCTAssertEqual(store.state.inventory["rareCandy"], 3)
        XCTAssertTrue(store.state.dex.allSatisfy { !$0.needsNamesRefresh })
        XCTAssertEqual(store.dexStoredChainNames(store.state.dex[0])?[1], "이상해씨")
        XCTAssertEqual(DigimonNameLocalization.resolve(store.state.dex[0].names![2]!, preferredCodes: ["it"]), "Ivysaur")
        _ = await store.dexResolveChainNames(old) // A mounted row can still hold its old value.
        await store.backfillMissingDexNames()
        let calls = await provider.calls
        XCTAssertEqual(calls, 1, "Duplicate catches and stale row values must reuse the refreshed names")

        let restored = CompanionStore(provider: provider, fileURL: url)
        restored.setLanguage(.pt) // No Portuguese names in the API response: English is complete fallback.
        await restored.backfillMissingDexNames()
        XCTAssertEqual(restored.dexStoredChainNames(restored.state.dex[0])?[1], "Bulbasaur")
        let restoredCalls = await provider.calls
        XCTAssertEqual(restoredCalls, 1, "Absent translation is not an expired cache")
    }

    func testOfflineLegacyCacheRemainsVisibleAndRetriesAfterRecovery() async throws {
        let url = try fixture([entry()])
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = MigratingNameProvider(allNames)
        await provider.configure(names: allNames, offline: true)
        let store = CompanionStore(provider: provider, fileURL: url)
        let old = store.state.dex[0]
        let fallback = await store.dexResolveChainNames(old)
        XCTAssertEqual(fallback, [1: "Bulbasaur", 2: "Ivysaur"])
        XCTAssertNil(store.state.dex[0].namesVersion)
        await provider.configure(names: allNames)
        await store.backfillMissingDexNames()
        XCTAssertEqual(store.dexStoredChainNames(store.state.dex[0])?[2], "이상해풀")
        XCTAssertFalse(store.state.dex[0].needsNamesRefresh)
    }

    func testSimultaneouslyMountedCatchRowsShareOneRequest() async throws {
        let url = try fixture([entry(), entry("second-catch")])
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = MigratingNameProvider(allNames)
        let store = CompanionStore(provider: provider, fileURL: url)
        let first = store.state.dex[0]
        let second = store.state.dex[1]
        async let a = store.dexResolveChainNames(first)
        async let b = store.dexResolveChainNames(second)
        let names = await (a, b)
        XCTAssertEqual(names.0, names.1)
        XCTAssertEqual(names.0[1], "이상해씨")
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.state.dex.allSatisfy { !$0.needsNamesRefresh })
    }

    func testPartialResponsePreservesOldNamesWithoutMarkingMigrationComplete() async throws {
        let url = try fixture([entry()])
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = MigratingNameProvider([1: allNames[1]!])
        let store = CompanionStore(provider: provider, fileURL: url)
        await store.backfillMissingDexNames()
        XCTAssertEqual(store.dexStoredChainNames(store.state.dex[0]), [1: "이상해씨", 2: "Ivysaur"])
        XCTAssertTrue(store.state.dex[0].needsNamesRefresh)
        await provider.configure(names: allNames)
        await store.backfillMissingDexNames()
        XCTAssertFalse(store.state.dex[0].needsNamesRefresh)
        XCTAssertEqual(store.state.dex[0].names?[2]?["it"], "Ivysaur")
    }

    func testNewNamesSkipMigrationButEmptyAndMissingSpeciesRetry() throws {
        var fresh = entry()
        XCTAssertFalse(fresh.needsNamesRefresh)
        let roundTrip = try JSONDecoder().decode(DexEntry.self, from: JSONEncoder().encode(fresh))
        XCTAssertFalse(roundTrip.needsNamesRefresh)
        fresh.names = [:]
        XCTAssertTrue(fresh.needsNamesRefresh)
        fresh.names = [1: ["en": "Bulbasaur"]]
        XCTAssertTrue(fresh.needsNamesRefresh)
        fresh.namesVersion = nil
        XCTAssertTrue(fresh.needsNamesRefresh)
    }

    // MARK: 표시 경로 (동행 기록 행)

    /// 번들 종만 담은 항목 — 저장 이름이 통째로 없는(구버전 + 오프라인 저장) 상태를 만든다.
    private func bundleEntry(names: [Int: [String: String]]? = nil) -> DexEntry {
        var e = DexEntry(id: "bundle-row", baseID: 1, finalID: 34, chainOrder: [1, 34], rarity: .common,
                         caughtAt: Date(timeIntervalSince1970: 123), names: names)
        e.names = names   // init 이 nil 을 그대로 두는지와 무관하게 명시적으로 고정한다.
        return e
    }

    private func offlineStore() -> (CompanionStore, MigratingNameProvider) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dex-row-\(UUID().uuidString).json")
        // 오프라인(라인 조회 실패) provider — 이 경로가 네트워크에 기대지 않는다는 조건을 만든다.
        let provider = MigratingNameProvider([:])
        let store = CompanionStore(provider: provider, fileURL: url)
        store.setLanguage(.ko)
        return (store, provider)
    }

    /// **[회귀] `names == nil` 인 행도 번들 이름으로 뜬다 — `#1` 이 아니다.**
    ///
    /// 예전엔 `dexDisplayChainNames` 가 `entry.names` 가 nil 이면 곧바로 빠져나가서, 표시 경로가
    /// 구버전 행에 **아예 적용되지 않았다**. 폴백인 `dexResolveChainNames` 는 오프라인에서 번들을
    /// 전혀 보지 않으므로 같은 화면에서 격자는 `아구몬`, 동행 기록 행은 `#1` 이 됐다.
    /// `names == nil` 은 과거 세이브만이 아니라 졸업·방생·활성 저장이 `currentLine` 없이 일어나면
    /// 지금도 생긴다 — 오프라인이면 영구히 `#id` 다.
    func testDisplayChainNamesResolveFromBundleWhenNothingIsStored() async {
        let (store, provider) = offlineStore()
        let names = store.dexDisplayChainNames(bundleEntry())
        XCTAssertEqual(names, [1: "아구몬", 34: "그레이몬"], "저장값이 없어도 번들 데이터로 해석돼야 한다")
        XCTAssertNotEqual(names?[1], "#1")
        // "오프라인" 을 이름이 아니라 실측으로 고정한다 — 이 경로가 라인 조회를 타기 시작하면
        // 오프라인에서 다시 `#id` 로 무너지므로, 네트워크 0회를 조건으로 못박는다.
        let calls = await provider.calls
        XCTAssertEqual(calls, 0, "번들 해석은 라인 조회(네트워크)가 필요 없다")
    }

    /// 번들이 저장값을 이긴다 — 표기가 추가되기 전에 굳은 영문 이름이 화면에 남으면 안 된다.
    func testDisplayChainNamesPreferBundleOverStaleStoredNames() {
        let (store, _) = offlineStore()
        let stale = bundleEntry(names: [1: ["ko": "옛이름", "en": "Agumon"], 34: ["en": "Greymon"]])
        XCTAssertEqual(store.dexDisplayChainNames(stale), [1: "아구몬", 34: "그레이몬"])
    }

    /// **저장값을 버리지 않는다.** 번들이 우선이라 저장값은 52종 **밖** id(데이터셋에서 빠진
    /// 구종)에서만 쓰이는데, `dexDisplayName(_:stored:)` 에 nil 을 넘기면 그 이름이 사라져
    /// `#9999` 가 된다. 이 항목만이 그 인자를 지킨다.
    func testDisplayChainNamesKeepStoredNamesForSpeciesOutsideTheDataset() {
        let (store, _) = offlineStore()
        var e = bundleEntry(names: [9999: ["ko": "사라진종", "en": "GoneMon"]])
        e.chainOrder = [1, 9999]
        let names = store.dexDisplayChainNames(e)
        XCTAssertEqual(names?[1], "아구몬", "번들 종은 번들에서")
        XCTAssertEqual(names?[9999], "사라진종", "데이터셋 밖 종은 저장값에서 — nil 을 넘기면 여기가 #9999 가 된다")
    }

    /// 동행 기록 행이 실제로 쓰는 합류 지점. 뷰(`DexEntryRow`)는 이 메서드를 호출만 하므로,
    /// 우선순위가 저장값 접근자로 되돌아가면 여기서 잡힌다.
    func testRowChainNamesUseTheDisplayPathNotTheStoredAccessor() {
        let (store, _) = offlineStore()
        // 저장값만 보는 접근자(`dexStoredChainNames`)로 되돌리면 이 항목은 nil 을 내고
        // async 폴백(resolved)으로 떨어진다 — 오프라인에서 `#1` 이 되는 바로 그 경로.
        XCTAssertNil(store.dexStoredChainNames(bundleEntry()), "전제: 이 항목엔 저장 이름이 없다")
        XCTAssertEqual(store.dexRowChainNames(bundleEntry(), resolved: [:]), [1: "아구몬", 34: "그레이몬"],
                       "표시 경로가 아니라 저장값 접근자로 되돌아갔다")
        // 저장값 접근자로 되돌리면 resolved 가 이겨 버린다 — 그 차이도 못박는다.
        XCTAssertEqual(store.dexRowChainNames(bundleEntry(), resolved: [1: "#1", 34: "#34"]),
                       [1: "아구몬", 34: "그레이몬"], "resolved 가 번들 해석을 덮으면 안 된다")
    }

    /// **`chainOrder` 기준 전환의 동작 델타.** 번들에도 저장값에도 없는 id 는 이제 맵에 `#id` 로
    /// 들어간다(이전엔 맵에서 아예 빠져 `EvoLineView` 가 `"…"` 를 그렸다). 실제 `chainOrder` id 는
    /// 전부 실존 라인에서 오고 구세대 세이브는 세이브 버전 게이트가 지우므로 도달하지 않지만,
    /// 도달하면 무엇이 보이는지를 고정해 둔다.
    func testUnknownSpeciesInChainOrderRendersSpeciesNumberNotAGap() {
        let (store, _) = offlineStore()
        var e = bundleEntry()
        e.chainOrder = [1, 7777]
        XCTAssertEqual(store.dexDisplayChainNames(e), [1: "아구몬", 7777: "#7777"],
                       "번들·저장값 어디에도 없는 id 는 종 번호로 떨어진다")
    }

    /// `chainOrder` 가 비면 표시할 게 없으므로 async 폴백으로 넘긴다 — 뷰의 `?? resolved` 가
    /// 도달 가능한 유일한 경우다.
    func testRowChainNamesFallBackToResolvedOnlyWhenChainOrderIsEmpty() {
        let (store, _) = offlineStore()
        var empty = bundleEntry()
        empty.chainOrder = []
        XCTAssertNil(store.dexDisplayChainNames(empty))
        XCTAssertEqual(store.dexRowChainNames(empty, resolved: [1: "포1"]), [1: "포1"])
        XCTAssertNil(store.dexRowChainNames(empty, resolved: [:]))
    }
}
