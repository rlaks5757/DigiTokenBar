import XCTest
@testable import DigiTokenBar

// MARK: 랜덤 풀에서 졸업한 라인 제외 (docs/GAME-DESIGN.md §2 "랜덤 풀 규칙")
//
// 12라인에서 `CollectionWeight.adjusted` 의 가중치 ½ 는 1/12 → 1/11.5 라 사실상 무의미하다.
// 그래서 도감 미완성 동안에는 졸업한 라인을 **풀에서 뺀다**. 검증 축이 넷이다:
//   ① 제외가 실제로 일어난다 — 전수 스윕에서 졸업 id 가 부재하고, 미졸업 id 는 전원 출현
//      (부분집합만 보면 미졸업 라인이 조용히 사라지는 구성원 교체를 못 잡는다)
//   ② 도감 완성 → 완화 분기로 전체 풀 복귀(중복 부화 가능)
//   ③ 티어 소진 + 도감 미완성 → 티어 안에서 완화(중복 발생) + **알이 유지되지 않음**
//      (②와 ③은 완화의 사유가 다르다 — 합쳐 단언하면 한쪽이 무단언으로 남는다)
//   ④ REST 폴백도 같은 기준 — 가중 경로만 고치면 주입 provider 경로가 수정 전 동작을 보인다

/// 등급이 capture_rate 로 갈리는 4종 인덱스(밴드별 1종). 희귀 티어는 {3, 4} 만 통과한다
/// — 전설(id 4)이 희귀 필터를 통과하는 것은 의도된 동작이다(`PremiumEggTests` 참고).
private struct BandedProvider: DigimonLineProviding {
    static let entries = [
        BaseSpecies(id: 1, captureRate: 255),   // common
        BaseSpecies(id: 2, captureRate: 100),   // uncommon
        BaseSpecies(id: 3, captureRate: 30),    // rare
        BaseSpecies(id: 4, captureRate: 3),     // legendary
    ]
    func baseSpeciesIndex() async throws -> [BaseSpecies] { Self.entries }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { Self.entries.first { $0.id == id } }
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        guard let e = Self.entries.first(where: { $0.id == baseSpeciesID }) else { throw URLError(.badURL) }
        return EvoLine(baseID: e.id, tree: EvoNode(speciesID: e.id, children: []),
                       rarity: Rarity.from(captureRate: e.captureRate,
                                           isLegendary: e.id == 4, isMythical: false),
                       names: [e.id: ["en": "M\(e.id)"]])
    }
}

/// GraphQL 인덱스는 죽고 REST 만 사는 상황 — rejection sampling 이 졸업 필터를 실제로 밟는다.
/// 모든 id 가 base 이고 전부 common 이라 티어 필터는 개입하지 않는다(졸업 축만 분리).
private struct RestOnlyProvider: DigimonLineProviding {
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw URLError(.badServerResponse) }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { BaseSpecies(id: id, captureRate: 255) }
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["en": "M\(baseSpeciesID)"]])
    }
}

/// REST 폴백 + **등급 밴드**. capture_rate 를 id 에서 유도해(3의 배수 = rare 30, 그 외 = common 255)
/// 티어 필터와 졸업 필터가 **같은 루프에서 동시에** 걸리는 상황을 만든다.
private struct RestOnlyBandedProvider: DigimonLineProviding {
    static func captureRate(_ id: Int) -> Int { id % 3 == 0 ? 30 : 255 }
    static func isRareBand(_ id: Int) -> Bool { Rarity.rare.includes(captureRate: captureRate(id)) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { throw URLError(.badServerResponse) }
    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        BaseSpecies(id: id, captureRate: Self.captureRate(id))
    }
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: Rarity.from(captureRate: Self.captureRate(baseSpeciesID),
                                    isLegendary: false, isMythical: false),
                names: [baseSpeciesID: ["en": "M\(baseSpeciesID)"]])
    }
}

@MainActor
final class GraduatedPoolExclusionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 부화 직전 알 + 졸업 기록(`collectedFinals`) 시드. 졸업 기록은 `"baseID:finalID"` 형식이고
    /// `hasCollectedFinal(forBaseID:)` 가 접두로 판정하므로 finalID 는 아무 값이어도 된다.
    private func eggStore(graduated: [Int], tier: Rarity? = nil, seed: UInt64,
                          provider: any DigimonLineProviding, dexBaseIDs: [Int] = []) -> CompanionStore {
        let f = FileManager.default.temporaryDirectory
            .appendingPathComponent("grad-pool-\(UUID().uuidString).json")
        let finals = graduated.map { "\"\($0):900\"" }.joined(separator: ",")
        let tierJSON = tier.map { "\"\($0.rawValue)\"" } ?? "null"
        let dex = dexBaseIDs.map { id in
            "{\"id\":\"d\(id)\",\"baseID\":\(id),\"finalID\":900,\"chainOrder\":[\(id),900],"
                + "\"rarity\":\"common\",\"caughtAt\":0}"
        }.joined(separator: ",")
        let json = "{\"saveVersion\":\(CompanionState.currentSaveVersion),\"installBaselineSet\":true,"
            + "\"usedSinceInstall\":10000000,\"spentTokens\":0,\"lastDate\":\"d\",\"active\":null,"
            + "\"dex\":[\(dex)],\"collectedFinals\":[\(finals)],"
            + "\"eggUsage\":\(DigimonBalance.eggHatchThreshold),\"eggTier\":\(tierJSON)}"
        try? json.data(using: .utf8)!.write(to: f)
        return CompanionStore(provider: provider, clock: { self.now }, fileURL: f, rng: SeededRNG(seed: seed))
    }

    /// seed 스윕으로 실제 부화한 baseID 집합을 모은다 — 표본 몇 번이 아니라 전수 관측.
    private func hatchedIDs(seeds: ClosedRange<UInt64>, graduated: [Int], tier: Rarity? = nil,
                            provider: any DigimonLineProviding) async -> (observed: Set<Int>, hatches: Int) {
        var observed: Set<Int> = []
        var hatches = 0
        for seed in seeds {
            let s = eggStore(graduated: graduated, tier: tier, seed: seed, provider: provider)
            await s.hatchIfNeeded()
            if let id = s.state.active?.baseID { observed.insert(id); hatches += 1 }
        }
        return (observed, hatches)
    }

    // MARK: ① 제외 — 졸업분 부재 + 미졸업분 전원 출현

    /// 번들 provider(실제 12라인)에서 졸업분이 가중 스윕에 **한 번도** 나오지 않고, 미졸업분은
    /// **전원** 나온다. 전체 라인 집합은 `baseSpeciesIndex()` 에서 유도한다 — 리터럴 12 금지.
    ///
    /// 양방향으로 단언하는 이유: 부분집합만 보면 "졸업분이 안 나온다"는 통과시키면서 미졸업 라인이
    /// 조용히 풀에서 사라지는 **구성원 교체**를 놓친다(필터 술어가 반대로 뒤집혀도 부분집합일 수 있다).
    func testGraduatedLinesAreAbsentAndEveryUngraduatedLineStillAppears() async {
        let provider = DigimonLineProvider()
        guard let all = try? await provider.baseSpeciesIndex(), all.count > 2 else {
            return XCTFail("번들 인덱스를 못 읽었다")
        }
        // 졸업 집합은 데이터에서 유도한다(정렬된 앞 2종) — 특정 id 를 적으면 데이터 변경에 깨진다.
        let allIDs = Set(all.map(\.id))
        let graduated = Array(allIDs.sorted().prefix(2))
        let expected = allIDs.subtracting(graduated)
        XCTAssertFalse(expected.isEmpty, "미졸업 풀이 진부분집합이어야 축이 성립한다")

        let (observed, hatches) = await hatchedIDs(seeds: 1...400, graduated: graduated, provider: provider)
        XCTAssertEqual(hatches, 400, "400회 모두 부화해야 스윕이 풀 전체를 밟는다")
        for id in graduated {
            XCTAssertFalse(observed.contains(id), "졸업한 라인 \(id) 이 랜덤 풀에 남아 있다")
        }
        XCTAssertEqual(observed, expected,
                       "관측 집합이 미졸업 집합과 정확히 일치해야 한다(누락 \(expected.subtracting(observed)) / "
                       + "초과 \(observed.subtracting(expected)))")
    }

    // MARK: ② 완화 사유 A — 도감 완성 → 전체 풀 복귀

    /// 전원 졸업(도감 완성)하면 완화 분기가 전체 풀을 돌려준다 — 알이 유지되지 않고, 중복이 가능해진다.
    ///
    /// 이 구간이 `CollectionWeight.adjusted(isCollected: true)` 가 **실행되는** 유일한 경로다.
    /// 다만 이 테스트가 그 ½ 가중을 **지키지는 않는다** — 분포가 아니라 "알이 깨진다 + 복수 라인이
    /// 관측된다"만 본다(½ 를 1배로 바꾸는 뮤테이션은 전체 스위트에서 생존한다. 기존 상태이고 이번
    /// 변경 범위 밖이다). 여기서 지키는 것은 **완화가 전체 풀을 돌려준다**는 것뿐이다.
    func testDexCompleteFallsBackToTheFullPoolSoDuplicatesBecomePossible() async {
        let all = BandedProvider.entries.map(\.id)
        let (observed, hatches) = await hatchedIDs(seeds: 1...60, graduated: all, provider: BandedProvider())
        XCTAssertEqual(hatches, 60, "도감 완성 후에도 알은 정상적으로 깨져야 한다(영구 대기 금지)")
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { all.contains($0) })
        // 전원 졸업이므로 관측된 모든 것이 중복 부화다 — 가중치가 ½ 로 깎여도 선택 가능해야 한다.
        for id in observed {
            XCTAssertTrue(BandedProvider.entries.contains { $0.id == id })
        }
        XCTAssertGreaterThan(observed.count, 1, "완화가 전체 풀을 돌려주면 여러 라인이 관측된다")
    }

    // MARK: ③ 완화 사유 B — 티어 소진 + 도감 미완성

    /// 희귀 보증 알인데 그 티어의 종({3, 4})이 전부 졸업했고 도감은 미완성({1, 2} 미졸업)인 경우.
    /// 졸업 제외를 티어 필터처럼 **하드**로 두면 알이 영구히 못 깨진다 — 그래서 티어 안에서 완화한다.
    ///
    /// 세 가지를 **각각** 단언한다: (i) 티어 보증은 지켜진다 (ii) 완화가 실제로 발동했다(= 졸업분
    /// 부화) (iii) 알이 유지되지 않는다. 합쳐 단언하면 완화 사유가 무단언으로 남는다.
    func testTierExhaustedByGraduationRelaxesWithinTierInsteadOfKeepingTheEggForever() async {
        let graduated = [3, 4]   // 희귀 티어 전원 졸업
        let ungraduatedOutsideTier = [1, 2]   // 도감 미완성 — 완화 판정이 "도감 완성"이 아님을 보장
        let (observed, hatches) = await hatchedIDs(seeds: 1...40, graduated: graduated,
                                                   tier: .rare, provider: BandedProvider())
        // (iii) 알이 유지되지 않는다 — 이게 하드 필터와 갈리는 지점이다.
        XCTAssertEqual(hatches, 40, "티어가 졸업으로 소진되면 알이 영구히 안 깨진다(하드 필터 회귀)")
        // (i) 티어 보증은 그대로 — 완화는 티어 **안에서만** 넓힌다.
        XCTAssertTrue(observed.isSubset(of: Set(graduated)),
                      "완화가 티어 밖(\(observed.subtracting(Set(graduated)))) 으로 새어 나갔다")
        for id in ungraduatedOutsideTier {
            XCTAssertFalse(observed.contains(id), "미졸업이어도 티어 밖 \(id) 은 보증을 깨므로 안 된다")
        }
        // (ii) 완화가 실제로 발동했다 — 졸업한 종이 부화했다는 것이 그 증거.
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { graduated.contains($0) },
                      "완화 분기가 졸업분을 돌려줘야 한다")
    }

    // MARK: ④ REST 폴백 단독 — 가중 경로를 고쳐도 이 경로는 안 고쳐진다

    /// REST 폴백도 졸업분을 건너뛴다. 모든 id 가 base 라 16회 시도가 전부 유효 후보를 만나므로,
    /// 졸업 id 가 결과에 나오면 필터가 없는 것이다.
    func testRestFallbackSkipsGraduatedLines() async {
        let graduated = Array(DigimonAssets.queryableSpeciesIDs.prefix(40))
        let (observed, hatches) = await hatchedIDs(seeds: 1...40, graduated: graduated,
                                                   provider: RestOnlyProvider())
        XCTAssertEqual(hatches, 40, "졸업 제외가 16회를 소진시켜 알을 유지하게 만들면 안 된다")
        XCTAssertTrue(observed.isDisjoint(with: Set(graduated)),
                      "REST 폴백이 졸업한 라인 \(observed.intersection(Set(graduated))) 을 뽑았다")
    }

    /// REST 폴백의 **완화** — 조회 가능한 모든 종이 졸업한 상태(도감 완성)에서도 알이 깨져야 한다.
    /// 졸업분을 `continue` 로만 건너뛰면 16회를 소진해 `nil`(알 유지)로 떨어지고, 다음 틱도 같은
    /// 결과라 알이 영구히 안 깨진다 — 가중 경로의 완화와 같은 함정이다.
    func testRestFallbackRelaxesWhenEveryCandidateIsGraduated() async {
        let graduated = Array(DigimonAssets.queryableSpeciesIDs)
        let (observed, hatches) = await hatchedIDs(seeds: 1...20, graduated: graduated,
                                                   provider: RestOnlyProvider())
        XCTAssertEqual(hatches, 20, "전원 졸업이면 REST 폴백도 완화해서 부화시켜야 한다(영구 대기 금지)")
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(observed.allSatisfy { DigimonAssets.queryableSpeciesIDs.contains($0) })
    }

    /// REST 폴백의 완화가 **티어 보증을 깨지 않는다.** 희귀 밴드가 전부 졸업했고 common 밴드는
    /// 미졸업인 상태 — 완화가 발동하면서 동시에 티어가 걸려 있는 유일한 조합이다.
    ///
    /// 이 축이 빠지면 두 필터의 **순서 의존**이 무단언으로 남는다: 기억형 폴백
    /// (`graduatedFallback`)이 안전한 것은 티어 검사가 **먼저** 돌기 때문이고, 두 블록 순서가
    /// 뒤바뀌면 폴백이 티어 미달 id 를 들고 있다가 반환해 프리미엄 보증이 조용히 깨진다.
    /// 가중 경로는 테스트 ③ 이 이 축을 덮지만(`observed ⊆ 티어 집합`), REST 경로는 전부
    /// common 인 provider 로만 검증해서 티어가 걸린 완화를 한 번도 밟지 않았다.
    func testRestFallbackRelaxationStaysWithinTheGuaranteedTier() async {
        // **졸업 집합을 희귀 밴드와 일치시키면 안 된다.** 그러면 졸업한 id 는 전부 티어도 통과해서
        // 두 필터가 한 번도 어긋나지 않고, 순서를 뒤바꿔도 폴백에 담기는 값이 같아진다(판별력 0).
        // 티어 **미달**(common)인 졸업 id 를 섞어야 "먼저 걸리는 쪽"이 결과를 가른다.
        let graduated = Array(DigimonAssets.queryableSpeciesIDs)   // 희귀 밴드 + common 밴드 전부 졸업
        XCTAssertTrue(graduated.contains { !RestOnlyBandedProvider.isRareBand($0) },
                      "티어 미달인 졸업 id 가 있어야 순서 의존을 판별한다")
        XCTAssertTrue(graduated.contains { RestOnlyBandedProvider.isRareBand($0) },
                      "티어를 통과하는 졸업 id 도 있어야 완화가 성공한다")
        var hatches = 0
        for seed in UInt64(1)...20 {
            let s = eggStore(graduated: Array(graduated), tier: .rare, seed: seed,
                             provider: RestOnlyBandedProvider())
            await s.hatchIfNeeded()
            guard let a = s.state.active else { continue }
            hatches += 1
            // 완화가 티어 밖으로 새면 여기서 common 이 잡힌다 — 산 보증이 깨진 것.
            XCTAssertEqual(a.rarity, .rare, "REST 완화가 티어 밖(\(a.rarity)) 으로 새어 나갔다")
            XCTAssertTrue(graduated.contains(a.baseID), "완화 분기로 졸업분이 나온 것이 맞는지")
            XCTAssertTrue(RestOnlyBandedProvider.isRareBand(a.baseID),
                          "폴백이 티어 미달 id 를 들고 있었다 — 졸업 검사가 티어 검사보다 먼저 돈 것")
        }
        // 이 전수 부화는 테스트 ③ 과 달리 **구조적 보장이 아니다** — 티어가 걸려 있어 폴백이 세워지려면
        // 샘플된 id 가 희귀 밴드(3의 배수, ≈1/3)여야 하므로 원리상 16회 소진이 가능하다(seed 당 ≈0.15%).
        // `SeededRNG` 로 결정적이고 현재 seed 집합에서 20/20 확인했다. 무관한 RNG 변경으로 이 줄이
        // 흔들리면 **완화 결함이 아니라 소진**이므로 기대값을 재튜닝하지 말고 seed 범위를 넓혀라
        // (형제 테스트 `PremiumEggTests.testRestFallbackRespectsGuarantee` 는 소진을 정상으로 허용한다).
        XCTAssertEqual(hatches, 20, "희귀 밴드 전원 졸업이어도 알은 깨져야 한다(영구 대기 금지)")
    }

    // MARK: 경계 — 고르기 UI 는 졸업으로 좁히지 않는다

    /// 졸업 제외는 **랜덤 풀** 규칙이다. 고르기 후보(`babyPicks`)는 `ownsSpecies` 로 거르는데,
    /// 졸업 기록(`dex`)이 곧 `ownsSpecies` 를 참으로 만드는 주 경로라서 — 졸업한 라인은 고르기
    /// 후보의 **전형**이다. 여기에 졸업 제외를 끼우면 후보가 통째로 비고 고르기 UI 가 죽는다
    /// (고르기는 "제거"가 아니라 "기준 좁히기"). 졸업한 라인이 후보에 남아 있는지로 못박는다.
    func testGraduationDoesNotNarrowThePickCandidates() async {
        guard let line = DigimonData.lines.first else { return XCTFail("번들 라인을 못 읽었다") }
        let graduatedID = line.baseID
        let s = eggStore(graduated: [graduatedID], seed: 1, provider: DigimonLineProvider(),
                         dexBaseIDs: [graduatedID])
        XCTAssertTrue(s.state.hasCollectedFinal(forBaseID: graduatedID), "졸업 기록이 있다")
        XCTAssertTrue(s.state.ownsSpecies(graduatedID), "졸업 기록이 보유 판정의 근거다")
        XCTAssertTrue(s.babyPicks.contains { $0.baseID == graduatedID },
                      "졸업한 라인 \(graduatedID) 이 고르기 후보에서 사라졌다 — 랜덤 풀 규칙이 번진 것")
    }
}
