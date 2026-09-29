import XCTest
@testable import DigiTokenBar

// MARK: 새 알 (리롤 — 현재 디지몬 폐기, 도감·확률 무영향)

private struct FreshEggNoProvider: DigimonLineProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class FreshEggTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 활성 디지몬(baseID 10, common 3형태, 성장 200M) + 도감 1개 + 수집기록 1개(1:3) + 지갑.
    /// active=false 면 알(활성 없음) 상태.
    private func store(active: Bool = true, used: Int = 5_000_000_000,
                       spent: Int = 0) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("egg-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let dex = "{\"baseID\":1,\"finalID\":3,\"chainOrder\":[1,2,3],\"rarity\":\"common\"}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":\(spent),"
            + "\"lastDate\":\"d\",\"active\":\(active ? mon : "null"),\"dex\":[\(dex)],\"collectedFinals\":[\"1:3\"]}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: FreshEggNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 7))
    }

    func testPriceIsOneBillion() { XCTAssertEqual(FreshEgg.price, 1_000_000_000) }

    /// [핵심] 리롤 = 보관: active 가 사라지고 새 알(eggUsage 0)이 되지만, 육성 상태는 방생되지 않고
    /// `state.stored` 로 옮겨진다. 확률 가중(collectedFinals)은 여전히 불변이다 —
    /// 끝까지 키운 게 아니므로 최종체 완성으로 세지 않는다.
    func testBuyFreshEggStoresActiveWithoutProbabilityImpact() {
        let s = store(used: 5_000_000_000, spent: 0)
        let persistedDexBefore = s.state.dex
        let collectedBefore = s.state.collectedFinals
        XCTAssertEqual(s.dexEntries.count, persistedDexBefore.count + 1,
                       "현재 디지몬은 졸업 전에도 도감 화면에 표시")
        XCTAssertTrue(s.hasActive)
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertNil(s.state.active, "현재 디지몬은 더 이상 활성이 아니다")
        XCTAssertTrue(s.isEgg)
        XCTAssertEqual(s.state.eggUsage, 0, "새 알은 처음부터 인큐베이션")
        XCTAssertNil(s.state.pendingHatchID)

        XCTAssertEqual(s.state.dex.count, persistedDexBefore.count, "방생이 아니므로 도감은 늘지 않는다")
        XCTAssertEqual(s.state.stored.count, 1, "폐기 대신 보관함에 육성 상태 그대로 옮겨진다")
        let stored = try? XCTUnwrap(s.state.stored.last)
        XCTAssertEqual(stored?.mon.baseID, 10)
        XCTAssertEqual(stored?.mon.stageIndex, 0)
        XCTAssertEqual(stored?.mon.usedAtStage, 200_000_000, "육성 상태(성장분)가 그대로 보존된다")

        XCTAssertEqual(s.state.collectedFinals, collectedBefore, "확률 가중(collectedFinals) 불변")
        XCTAssertEqual(s.state.spentTokens, FreshEgg.price, "지갑에서 1B 차감")
        XCTAssertEqual(s.availableTokens, 5_000_000_000 - FreshEgg.price)
    }

    /// [회귀] 보관한 종은 도감에서 사라지지 않는다(ownsSpecies 가 보관함도 본다).
    ///
    /// 이게 이 기능의 존재 이유다. 도감은 "쌓이기만 한다"는 약속을 주는데, 알 구매가 유일하게
    /// 그 약속을 깨는 경로였다 — 현재 개체에서만 오던 종이 통째로 빠져 종 수가 줄었다.
    func testStoredSpeciesStaysInTheDex() {
        let s = store()
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 10 }, "육성 중엔 도감에 보인다")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 10 },
                      "보관한 뒤에도 남는다 — 도감 종 수는 줄지 않는다")
        XCTAssertFalse(s.dexSpecies.first { $0.id == 10 }?.isRaising ?? true,
                       "더 이상 키우는 중이 아니므로 Raising 뱃지는 없다")
    }

    /// [함정 1] 보관은 방생이 아니다 — `isReleased`/`isArmored` 가 서면 그 종이 죠그레스 파트너
    /// 자격(`hasJogressPartnerRecord`)을 잃어 팔라딘 모드(481) 경로가 영구 도달 불가가 된다.
    /// 죠그레스 부모가 되는 종(baseID 10)을 보관한 뒤에도 파트너 자격이 살아 있어야 한다.
    func testBuyFreshEggDoesNotStripJogressPartnerEligibility() {
        let s = store()
        XCTAssertTrue(s.hasJogressPartnerRecord(1), "사전 조건 — 도감 항목(1:3)이 이미 파트너 자격을 갖는다")
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertTrue(s.hasJogressPartnerRecord(1),
                      "기존 자격이 유지된다(회귀 감시용 — dex 는 existential 판정이라 append 로는 단독으로 레드가 안 된다. 판별은 아래 dex 불변 단언이 한다)")
        XCTAssertTrue(s.state.dex.allSatisfy { !$0.isReleased && !$0.isArmored },
                      "보관은 도감에 방생/아머 기록을 남기지 않는다")
    }

    /// 폐기한 개체(baseID 10)의 종은 collectedFinals 에 들어가지 않는다(이후 부화 확률에 영향 없음).
    func testDiscardedSpeciesNotCollected() {
        let s = store()
        XCTAssertTrue(s.buyFreshEgg())
        XCTAssertFalse(s.state.collectedFinals.contains { $0.hasPrefix("10:") },
                       "폐기 개체 종은 수집 기록에 없어야 함")
    }

    /// 알 상태(활성 없음)에선 리롤할 게 없어 불가.
    func testCannotRerollWhenEgg() {
        let s = store(active: false, used: 5_000_000_000)
        XCTAssertFalse(s.hasActive)
        XCTAssertFalse(s.canBuyFreshEgg)
        XCTAssertFalse(s.buyFreshEgg())
        XCTAssertEqual(s.state.spentTokens, 0, "no-op")
    }

    /// 잔액이 가격 미만이면 불가 — 활성 유지.
    func testCannotRerollWithoutFunds() {
        let s = store(used: 500_000_000)   // 1B 미만
        XCTAssertFalse(s.canBuyFreshEgg)
        XCTAssertFalse(s.buyFreshEgg())
        XCTAssertNotNil(s.state.active, "활성 유지")
        XCTAssertEqual(s.state.spentTokens, 0)
    }

}
