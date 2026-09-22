import XCTest
@testable import DigiTokenBar

// MARK: 상점 (재화 = usedSinceInstall − spentTokens, 이상한 사탕 구매)

/// 라인 로딩이 필요 없는 상점 테스트용 provider(항상 throw — 지갑/구매는 라인과 무관).
private struct ShopNoProvider: DigimonLineProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class ShopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// usedSinceInstall/spentTokens 를 직접 지정한 상태 파일을 만들어 로드 — 지갑 잔액을 결정적으로
    /// 세팅(update() 의 delta 적립 경로를 우회). testCannotUseWhileLineUnloaded 와 동일한 JSON 시드 패턴.
    private func store(used: Int, spent: Int = 0, rareCandy: Int = 0,
                       file: String = #filePath) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shop-\(UUID().uuidString).json")
        let inv = rareCandy > 0 ? ",\"inventory\":{\"rareCandy\":\(rareCandy)}" : ""
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,\"usedSinceInstall\":\(used),\"spentTokens\":\(spent),"
            + "\"lastDate\":\"d\",\"dex\":[],\"collectedFinals\":[]\(inv)}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: ShopNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 1))
    }

    // MARK: 잔액 계산

    func testAvailableEqualsUsedWhenNothingSpent() {
        XCTAssertEqual(store(used: 1_000_000_000).availableTokens, 1_000_000_000)
    }

    func testAvailableSubtractsSpent() {
        XCTAssertEqual(store(used: 1_000_000_000, spent: 300_000_000).availableTokens, 700_000_000)
    }

    /// spent > used(비정상 상태 파일)이어도 음수로 새지 않는다(max 가드).
    func testAvailableNeverNegative() {
        XCTAssertEqual(store(used: 100_000_000, spent: 500_000_000).availableTokens, 0)
    }

    /// 하위호환: spentTokens 키 없는 구버전 저장 → 0 으로 로드(잔액 = used).
    func testDecodesWithoutSpentTokens() throws {
        let json = #"{"installBaselineSet":true,"usedSinceInstall":900,"lastDate":"d","dex":[]}"#
        let s = try JSONDecoder().decode(CompanionState.self, from: Data(json.utf8))
        XCTAssertEqual(s.spentTokens, 0)
        XCTAssertEqual(s.usedSinceInstall, 900)
    }

    func testSpentTokensRoundTrip() throws {
        var st = CompanionState()
        st.usedSinceInstall = 1000
        st.spentTokens = 400
        let round = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(round.spentTokens, 400)
    }

    // MARK: 구매 가능 판정 (경계)

    func testCanBuyAtExactPrice() {
        XCTAssertTrue(store(used: RareCandy.price).canBuyRareCandy)
    }

    func testCannotBuyOneBelowPrice() {
        XCTAssertFalse(store(used: RareCandy.price - 1).canBuyRareCandy)
    }

    // MARK: 구매 (차감 + 적립 + 영속)

    func testBuyDebitsWalletAndCreditsInventory() {
        let s = store(used: 1_000_000_000)
        XCTAssertTrue(s.buyRareCandy())
        XCTAssertEqual(s.rareCandyCount, 1)
        XCTAssertEqual(s.state.spentTokens, RareCandy.price)
        XCTAssertEqual(s.availableTokens, 1_000_000_000 - RareCandy.price)
        XCTAssertEqual(s.state.usedSinceInstall, 1_000_000_000, "성장 미터(usedSinceInstall)는 불변")
    }

    /// 잔액 부족이면 no-op — 인벤토리·지출 원장 불변, false 반환.
    func testBuyInsufficientIsNoOp() {
        let s = store(used: 400_000_000)
        XCTAssertFalse(s.buyRareCandy())
        XCTAssertEqual(s.rareCandyCount, 0)
        XCTAssertEqual(s.state.spentTokens, 0)
    }

    /// 여러 번 구매하면 잔액이 바닥날 때까지만 성공(가드가 매번 재평가).
    func testMultipleBuysUntilBroke() {
        let s = store(used: 1_200_000_000)          // 2개까지 가능(1B), 3번째 실패(잔액 200M)
        XCTAssertTrue(s.buyRareCandy())
        XCTAssertTrue(s.buyRareCandy())
        XCTAssertFalse(s.buyRareCandy())
        XCTAssertEqual(s.rareCandyCount, 2)
        XCTAssertEqual(s.state.spentTokens, 2 * RareCandy.price)
        XCTAssertEqual(s.availableTokens, 200_000_000)
    }

    /// 구매는 이미 가진 사탕에 합산된다(무료 지급분과 같은 인벤토리).
    func testBuyAddsToExistingStock() {
        let s = store(used: 1_000_000_000, rareCandy: 3)
        XCTAssertTrue(s.buyRareCandy())
        XCTAssertEqual(s.rareCandyCount, 4)
        XCTAssertEqual(s.ownedItems.first?.kind, .rareCandy)
        XCTAssertEqual(s.ownedItems.first?.count, 4)
    }

    /// [영속] 재시작(같은 파일 재로드) 후 지출·재고가 유지된다.
    func testBuyPersistsAcrossRestart() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shop-persist-\(UUID().uuidString).json")
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,\"usedSinceInstall\":1000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s1 = CompanionStore(provider: ShopNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 1))
        XCTAssertTrue(s1.buyRareCandy())

        let s2 = CompanionStore(provider: ShopNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 1))
        XCTAssertEqual(s2.rareCandyCount, 1, "재고 영속")
        XCTAssertEqual(s2.state.spentTokens, RareCandy.price, "지출 영속")
        XCTAssertEqual(s2.availableTokens, 1_000_000_000 - RareCandy.price)
    }

    // MARK: 정렬 (가격 저렴한 순 + 구매 완료 보유형 맨 아래)

    /// 상점 목록은 가격 오름차순(사탕 500M < 디지멘탈 9종 각 1B).
    func testItemsSortedByPriceAscending() {
        let items = store(used: 0).purchasableItems
        XCTAssertEqual(items.first, .rareCandy)
        let prices = items.compactMap(\.shopPrice)
        XCTAssertEqual(prices, prices.sorted(), "shopPrice 오름차순 — 가격 상수가 바뀌어도 정렬 불변식 유지")
        // 현재는 10종 전부 판매 중이라 이 단언이 항상 참이다 — 이 자체가 실패할 수 없다는 뜻은 아니다.
        // filter { $0.shopPrice != nil } 은 미판매 아이템이 섞이는 걸 막는 살아있는 가드(shopPrice
        // 를 nil 로 두는 종을 추가하면 목록에서 빠지고 이 count 가 실제로 어긋난다). 그 가드가 걸러낸
        // 결과가 새지 않는지는 바로 아래에서 별도로 확인한다.
        XCTAssertEqual(items.count, ItemKind.allCases.count, "모든 판매 아이템이 목록에 있어야 한다(현재 10종 전부 판매 중)")
        XCTAssertTrue(items.allSatisfy { $0.shopPrice != nil },
                       "미판매 아이템이 섞이면 ShopEntry.price 의 ?? 0 폴백으로 0원 표시된다")
    }

    /// [회귀] 디지멘탈 9종 × 7언어 = 63개 신규 지역화 문자열 — 이름은 언어 내에서 유일하고 비어있지
    /// 않아야 한다(설명은 W3 로 exhaustive 해졌어도 9종이 여전히 같은 문구를 공유하므로 유일성은
    /// 검증하지 않는다 — 비어있지 않음만 확인). `CaseIterable` 이라 케이스가 늘어도 자동으로 걸린다.
    func testItemNamesCompleteAndUniquePerLanguage() {
        for lang in AppLanguage.allCases {
            let l = L(lang)
            let names = ItemKind.allCases.map { l.itemName($0) }
            XCTAssertFalse(names.contains(where: \.isEmpty), "\(lang) itemName 에 빈 문자열")
            XCTAssertEqual(Set(names).count, ItemKind.allCases.count, "\(lang) itemName 중복")
            XCTAssertTrue(ItemKind.allCases.allSatisfy { !l.itemDescription($0).isEmpty },
                          "\(lang) itemDescription 에 빈 문자열")
        }
    }

    /// [회귀] `spriteName` 이 nil(이모지 폴백만)인 아이템이 화면에서 서로 구별되려면 폴백 이모지가
    /// 전부 달라야 한다. `CaseIterable` 을 쓰므로 ItemKind 에 케이스가 늘어도 자동으로 걸린다.
    func testFallbackEmojisAreAllUnique() {
        let emojis = ItemKind.allCases.map(\.fallbackEmoji)
        XCTAssertEqual(Set(emojis).count, ItemKind.allCases.count, "폴백 이모지 중복 — 화면에서 구별 불가")
    }

    /// [회귀] `Digimental`(아머 진화 데이터 키, EVOLUTION.md §4)과 `ItemKind`(인벤토리/상점 키)의
    /// 디지멘탈 집합이 서로 대조되지 않아서 우정 디지멘탈(friendship)이 세 곳(EVOLUTION.md ·
    /// Digimental · ItemKind)에서 동시에 빠진 채 조용히 일관됐던 적이 있다 — 1000+ 테스트가
    /// 전부 green 이었다. 손으로 유지하는 매핑 목록을 세 번째 장소로 또 만들지 않기 위해,
    /// 케이스명 규칙(`Digimental.foo` → `ItemKind.digimentalFoo`)만으로 두 집합을 기계적으로
    /// 대조한다 — 규칙 자체는 기존 9종 전부가 이미 따르고 있는 실제 컨벤션이다(우연 아님).
    /// 양방향 검증: 한쪽에만 있어도 실패해야 하므로 개수 일치 + 상호 포함을 모두 확인한다.
    func testDigimentalAndItemKindSetsMatch() {
        func expectedItemKindRawValue(for digimental: Digimental) -> String {
            "digimental" + digimental.rawValue.prefix(1).uppercased() + digimental.rawValue.dropFirst()
        }
        let digimentalItemKinds = ItemKind.allCases.filter { $0.rawValue.hasPrefix("digimental") }

        // 정방향: Digimental 각 케이스가 대응하는 ItemKind 케이스를 갖는지.
        for d in Digimental.allCases {
            let expected = expectedItemKindRawValue(for: d)
            XCTAssertNotNil(ItemKind(rawValue: expected),
                             "Digimental.\(d.rawValue) 에 대응하는 ItemKind.\(expected) 가 없음")
        }
        // 역방향: ItemKind 의 digimental* 케이스가 전부 Digimental 로 되짚어지는지
        // (ItemKind 쪽에만 늘어난 케이스를 잡는다 — 정방향만으로는 못 잡음).
        for kind in digimentalItemKinds {
            let suffix = kind.rawValue.dropFirst("digimental".count)
            let expectedDigimentalRawValue = suffix.prefix(1).lowercased() + suffix.dropFirst()
            XCTAssertNotNil(Digimental(rawValue: expectedDigimentalRawValue),
                             "ItemKind.\(kind.rawValue) 에 대응하는 Digimental.\(expectedDigimentalRawValue) 가 없음")
        }
        // 개수 일치까지 확인해 "양쪽 다 있지만 서로 다른 새 케이스가 하나씩 늘어 우연히 개수만
        // 맞는" 경우가 아니라 진짜 1:1 대응인지 확정한다.
        XCTAssertEqual(Digimental.allCases.count, digimentalItemKinds.count,
                        "Digimental 과 ItemKind 의 디지멘탈 케이스 개수가 다름")
    }

    /// [회귀] `ItemKind.digimental` 브리지 자체를 호출하는 단언. 이 프로퍼티는 케이스명 관례
    /// (`digimental` + 대문자 trait)로 기계 변환하는데, 관례에서 벗어난 케이스가 생기면 조용히
    /// nil 이 되어 `spriteName` 도 nil → 아이템이 전부 이모지로 떨어진다. 그런데
    /// `testDigimentalAndItemKindSetsMatch` 는 변환 규칙을 테스트 안에서 **재구현**하므로
    /// 프로덕션 프로퍼티가 망가져도 green 을 유지한다 — 그 공백을 여기서 닫는다.
    func testItemKindDigimentalBridgeResolvesEveryCase() {
        XCTAssertEqual(Set(ItemKind.allCases.compactMap(\.digimental)), Set(Digimental.allCases),
                       "ItemKind → Digimental 브리지가 9종 전부를 해석하지 못한다")
        for kind in ItemKind.allCases where kind.digimental != nil {
            XCTAssertNotNil(kind.spriteName, "\(kind.rawValue) 의 스프라이트 파일명이 nil 이다")
        }
        XCTAssertNil(ItemKind.rareCandy.digimental, "디지멘탈이 아닌 아이템은 nil 이어야 한다")
    }

    /// [회귀] `Digimental.wikimonFilename` 은 케이스마다 손으로 적은 exhaustive switch(일반화된
    /// 문자열 생성이 아님, DigimonData.swift 주석 참고)라 케이스 추가 시 매핑 누락은 컴파일 에러로
    /// 막히지만, **문자열 오타/오귀속은 컴파일이 통과한 채 조용히 404 난다** — 이 테스트가 그 값
    /// 자체를 9종 전부 고정한다. sincerity → reliability 처럼 케이스명과 파일명이 다른 예외가
    /// 실수로 "정정"(되돌려짐)되면 여기서 잡힌다.
    func testDigimentalWikimonFilenamesArePinned() {
        XCTAssertEqual(Digimental.courage.wikimonFilename, "Digimental_courage.jpg")
        // Wikimon 표기가 "reliability" — 케이스명(sincerity)과 다른 게 정상(더빙판 명칭 분기).
        XCTAssertEqual(Digimental.sincerity.wikimonFilename, "Digimental_reliability.jpg")
        XCTAssertEqual(Digimental.miracles.wikimonFilename, "Digimental_miracles.jpg")
        XCTAssertEqual(Digimental.love.wikimonFilename, "Digimental_love.jpg")
        XCTAssertEqual(Digimental.purity.wikimonFilename, "Digimental_purity.jpg")
        XCTAssertEqual(Digimental.knowledge.wikimonFilename, "Digimental_knowledge.jpg")
        XCTAssertEqual(Digimental.hope.wikimonFilename, "Digimental_hope.jpg")
        XCTAssertEqual(Digimental.light.wikimonFilename, "Digimental_light.jpg")
        XCTAssertEqual(Digimental.friendship.wikimonFilename, "Digimental_friendship.jpg")

        // 복붙 실수로 두 케이스가 같은 파일명을 가리키면(예외 처리를 다른 케이스에 잘못 옮김) 위
        // 개별 단언은 통과할 수 없지만, 혹시 기대값 자체를 잘못 옮겨 적어도 이 unique 체크가 별도로 잡는다.
        let filenames = Digimental.allCases.map(\.wikimonFilename)
        XCTAssertEqual(Set(filenames).count, Digimental.allCases.count,
                        "디지멘탈 파일명 중복 — 서로 다른 아이템이 같은 아트를 가리킴")
    }

    // MARK: shopEntries (판매 아이템 + 알 3종을 하나의 가격 오름차순 목록으로 병합)

    /// 활성 디지몬이 있으면 알 3종이 각자의 가격 위치에 끼워져 전체가 가격 오름차순.
    /// (회귀: 알이 ForEach 밖에서 무조건 맨 아래로 append 돼 3B 부적보다 아래에 놓이던 표시.)
    /// 등급 알을 인접 그룹으로 묶지 **않는** 것이 의도다 — 그러면 4B 희귀 알이 3B 부적 위로 올라가
    /// 위 회귀를 부분적으로 되살린다. 티어 관계는 카드의 등급 배지로 읽힌다.
    func testShopEntriesInterleavesFreshEggByPrice() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shop-entries-\(UUID().uuidString).json")
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"common\",\"totalForms\":3}"
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,\"usedSinceInstall\":5000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon),\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        let s = CompanionStore(provider: ShopNoProvider(), clock: { self.now }, fileURL: url, rng: SeededRNG(seed: 1))
        XCTAssertTrue(s.hasActive)
        // 사탕 500M < 디지멘탈 8종(각 1B, ShopEntry.sortRank=ItemKind.allCases 순서로 동률 정렬)
        // < 알(nil, 동률 1B, sortRank 로 디지멘탈 다음) < 알(uncommon) 2.5B < 알(rare) 4B.
        XCTAssertEqual(s.shopEntries,
                       [.item(.rareCandy),               // 500M
                        .item(.digimentalCourage),        // 1B
                        .item(.digimentalSincerity),      // 1B
                        .item(.digimentalMiracles),        // 1B
                        .item(.digimentalLove),            // 1B
                        .item(.digimentalPurity),          // 1B
                        .item(.digimentalKnowledge),        // 1B
                        .item(.digimentalHope),             // 1B
                        .item(.digimentalLight),            // 1B
                        .item(.digimentalFriendship),        // 1B
                        .egg(nil),                          // 1B
                        .egg(.uncommon),                     // 2.5B
                        .egg(.rare)])                        // 4B
        let prices = s.shopEntries.map(\.price)
        XCTAssertEqual(prices, prices.sorted(), "가격 상수가 바뀌어도 오름차순 불변식 유지")
    }

    /// 활성 디지몬이 없어도(알 상태) 알 3종은 목록에 **남는다** — 숨기면 "상점에 알이 원래 없다"로
    /// 읽힌다. 대신 구매는 `canBuyEgg` 의 `hasActive` 게이트가 전부 막는다(EggCard 는 비활성 버튼 +
    /// 사유 한 줄). 잔액이 충분한 상태로 검증해 게이트가 잔액이 아니라 hasActive 에서 걸림을 확인한다.
    func testShopEntriesKeepsEggsVisibleButUnbuyableWhenNoActive() {
        let s = store(used: 5_000_000_000)   // active 없음, 잔액은 전 티어 가격 이상
        XCTAssertFalse(s.hasActive)
        XCTAssertEqual(s.shopEntries,
                       [.item(.rareCandy),               // 500M
                        .item(.digimentalCourage),        // 1B
                        .item(.digimentalSincerity),      // 1B
                        .item(.digimentalMiracles),        // 1B
                        .item(.digimentalLove),            // 1B
                        .item(.digimentalPurity),          // 1B
                        .item(.digimentalKnowledge),        // 1B
                        .item(.digimentalHope),             // 1B
                        .item(.digimentalLight),            // 1B
                        .item(.digimentalFriendship),        // 1B
                        .egg(nil),                          // 1B
                        .egg(.uncommon),                     // 2.5B
                        .egg(.rare)])                        // 4B
        for tier in FreshEgg.shopTiers {
            XCTAssertTrue(s.shopEntries.contains(.egg(tier)), "알 상태에서도 \(tier?.rawValue ?? "기본") 알은 노출 유지")
            XCTAssertFalse(s.canBuyEgg(tier), "노출은 되지만 \(tier?.rawValue ?? "기본") 알 구매는 hasActive 게이트로 차단")
            XCTAssertFalse(s.buyEgg(tier), "buyEgg 도 no-op — 토큰이 빠져나가면 안 된다")
        }
        XCTAssertEqual(s.availableTokens, 5_000_000_000, "차단된 구매 시도로 잔액이 줄지 않는다")
    }
}
