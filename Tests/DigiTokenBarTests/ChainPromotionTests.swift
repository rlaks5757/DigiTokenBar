import XCTest
@testable import DigiTokenBar

/// 체인 승급(EVOLUTION.md §3 — Imperialdramon 체인) — 토큰을 지불해 단일 부모 전이를 진행한다.
/// 331 → 900(드래곤 모드) → 405(파이터 모드). 두 부모가 필요한 죠그레스와 달리 부모가 하나뿐이라
/// `jogress` 가 아니라 `chain` 테이블에 있고, 게이트는 **도감 기록 + 지갑**이다.
///
/// 라인 스텁은 `JogressEvolutionTests` 와 같은 이유로 **실제 데이터의 id** 를 쓴다.
private struct ChainStubProvider: DigimonLineProviding {
    let value: EvoLine
    func line(baseSpeciesID: Int) async throws -> EvoLine { value }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
}

private func chainNode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode {
    EvoNode(speciesID: id, children: children)
}

private func chainLine(base: Int, tree: EvoNode, rarity: Rarity = .uncommon) -> EvoLine {
    var names: [Int: [String: String]] = [:]
    func walk(_ n: EvoNode) {
        names[n.speciesID] = DigimonData.name(for: n.speciesID)?.localizedNames ?? [:]
        n.children.forEach(walk)
    }
    walk(tree)
    return EvoLine(baseID: base, tree: tree, rarity: rarity, names: names)
}

private let cVmonLine = chainLine(base: 349, tree: chainNode(349, [chainNode(358)]))
private let cWormmonLine = chainLine(base: 356, tree: chainNode(356, [chainNode(336)]))
private let cAgumonLine = chainLine(base: 1, tree: chainNode(1, [chainNode(31, [chainNode(202)])]),
                                    rarity: .legendary)
private let cGabumonLine = chainLine(base: 16, tree: chainNode(16, [chainNode(33, [chainNode(168)])]),
                                     rarity: .legendary)

private let chainFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// 파트너/출발 종 역할을 할 **졸업** 도감 항목(`releasedAt`/`armoredAt` 둘 다 nil).
private func chainGraduatedEntry(base: Int, chain: [Int], rarity: Rarity = .uncommon) -> DexEntry {
    DexEntry(id: "grad-\(chain.last ?? base)", baseID: base, finalID: chain.last ?? base,
             chainOrder: chain, rarity: rarity, caughtAt: chainFixedNow)
}

@MainActor
final class ChainPromotionTests: XCTestCase {

    /// 언어는 **시드에 명시 고정**한다 — 기본값 `.systemDefault` 는 `Locale.preferredLanguages` 를
    /// 읽으므로, 고정하지 않으면 개발자 맥(ko)에서만 통과하고 영어 CI 러너에서 이름 단언이 깨진다.
    /// `defaults` 도 **테스트마다 격리**한다 — 생략하면 `.standard` 라 `setShopDifficulty` 가
    /// 개발자 맥의 실제 앱 설정에 쓰이고, 그 값이 다음 테스트의 가격까지 바꾼다(실제로 겪었다).
    private func store(_ line: EvoLine, seed state: CompanionState = CompanionState(),
                       language: AppLanguage = .ko, rngSeed: UInt64 = 7) throws -> CompanionStore {
        var state = state
        state.language = language
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-\(UUID().uuidString).json")
        try JSONEncoder().encode(state).write(to: url)
        // 정리는 `defer` 가 아니라 `addTeardownBlock` 이다 — 반환하는 store 가 이 defaults 를
        // 계속 쓰므로, 헬퍼 스코프에서 도메인을 지우면 아직 살아 있는 store 밑을 빼는 셈이 된다.
        // 등록을 store 생성보다 **먼저** 해서 도중에 throw 해도 suite 가 남지 않게 한다.
        let suite = "chain-promotion-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.removeTestSuite(suite) }
        return CompanionStore(provider: ChainStubProvider(value: line),
                              clock: { chainFixedNow }, fileURL: url, rng: SeededRNG(seed: rngSeed),
                              defaults: defaults)
    }

    /// 부화 + 도감/지갑 시드. 승급가가 3.00B 라 두 단계(6.00B)를 감당할 잔액을 기본으로 준다.
    private func hatched(_ line: EvoLine, dex: [DexEntry] = [],
                         tokens: Int = 20_000_000_000,
                         language: AppLanguage = .ko) async throws -> CompanionStore {
        var seed = CompanionState()
        seed.dex = dex
        seed.usedSinceInstall = tokens
        let s = try store(line, seed: seed, language: language)
        await s.hatch(baseID: line.baseID)
        return s
    }

    private func grow(_ s: CompanionStore, to speciesID: Int) {
        while s.currentSpeciesID != speciesID, s.state.active != nil {
            s.applyUsage(s.threshold)
        }
        XCTAssertEqual(s.currentSpeciesID, speciesID, "사다리를 \(speciesID) 까지 못 올렸다")
    }

    /// 파일드라몬(331) 기록만 가진 스토어 — 승급 시작점.
    private func withPaildramonRecord(tokens: Int = 20_000_000_000) async throws -> CompanionStore {
        let s = try await hatched(cVmonLine, dex: [chainGraduatedEntry(base: 356, chain: [356, 336])],
                                  tokens: tokens)
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)), "331 기록을 못 만들었다")
        return s
    }

    // MARK: 데이터 전제

    /// 체인 간선은 정확히 2개다 — 정규 진화가 섞이면(판별식이 틀리면) 여기서 드러난다.
    func testChainEdgesAreExactlyTheImperialdramonChain() {
        let edges = DigimonData.chainEdges.map { [$0.from, $0.to] }
        XCTAssertEqual(edges, [[900, 405], [331, 900]], "체인 간선이 331→900, 900→405 가 아니다")
    }

    /// 체인 종은 사다리 밖이다 — 이 전제가 깨지면 승급이 성장을 멈추게 만든다.
    func testChainSpeciesAreNotLadderSpecies() {
        for id in [331, 900, 405, 481, 183] {
            XCTAssertFalse(DigimonData.isLadderSpecies(id), "\(id) 가 사다리 종으로 판정됐다")
        }
        for id in [358, 336, 202, 168, 1, 349] {
            XCTAssertTrue(DigimonData.isLadderSpecies(id), "\(id) 가 사다리 밖으로 판정됐다")
        }
    }

    // MARK: ① 한 단계씩 — 건너뛰기 불가

    /// 331 기록만 있으면 후보는 331→900 하나뿐이다. **405 로 바로 가는 후보는 없다.**
    func testOnlyOneStepIsOfferedAtATime() async throws {
        let s = try await withPaildramonRecord()
        let candidates = s.chainCandidates
        XCTAssertEqual(candidates.map(\.toID), [900], "331 에서 405 로 건너뛰는 후보가 나왔다")
        XCTAssertEqual(candidates.first?.fromID, 331)
    }

    /// 900 을 건너뛰고 405 를 만들려는 **참칭 후보**는 막힌다 — 그런 간선이 데이터에 없다.
    func testCannotSkipDirectlyFromPaildramonToFighterMode() async throws {
        let s = try await withPaildramonRecord()
        let lying = CompanionStore.ChainCandidate(fromID: 331, toID: 405,
                                                 price: 0, affordable: true)
        XCTAssertFalse(s.performChainPromotion(lying), "없는 간선으로 승급이 통과했다")
        XCTAssertFalse(s.hasJogressPartnerRecord(405))
        XCTAssertEqual(s.state.spentTokens, 0, "막힌 승급이 토큰을 가져갔다")
    }

    /// 두 간선이 **동시에 열리는 일은 없다** — 900 기록은 승급으로만 생기고, 그 승급이 곧
    /// `chain-900` 을 만들어 331→900 후보를 닫기 때문이다. (이 불변조건이 깨져도 승급 순서 자체는
    /// `chainCandidates` 의 출발 종 오름차순이 지킨다 — 아래 `testHandEditedSaveCannotSkipDragonMode`.)
    func testBothEdgesAreNeverOpenSimultaneously() async throws {
        let s = try await withPaildramonRecord()
        XCTAssertEqual(s.chainCandidates.map(\.toID), [900])
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        // 331·900 기록을 둘 다 가진 지금도 열린 후보는 405 하나뿐이다(331→900 은 기록이 있어 닫혔다).
        XCTAssertTrue(s.hasJogressPartnerRecord(331))
        XCTAssertTrue(s.hasJogressPartnerRecord(900))
        XCTAssertEqual(s.chainCandidates.map(\.toID), [405], "두 간선이 동시에 열렸다")
    }

    /// 손편집 세이브로 두 간선이 동시에 열려도 **900 을 건너뛸 수 없다** — 후보 정렬이 출발 종
    /// 오름차순이라 `availableChainPromotion` 이 앞 단계(331→900)를 먼저 준다.
    ///
    /// 재현: `chain-900` 이 **아닌** id 로 `chainOrder: [900]` 을 심는다. 그러면
    /// `hasJogressPartnerRecord(900)` 은 true 인데 `chain-900` 제외 필터가 걸리지 않아
    /// 331→900 과 900→405 가 함께 열린다. 도착 종 순서로 정렬하면 405(<900)가 먼저 나와
    /// 1회 지불로 파이터 모드에 도달한다(3.00B 할인).
    func testHandEditedSaveCannotSkipDragonMode() async throws {
        var forged331 = chainGraduatedEntry(base: 349, chain: [331])
        forged331.id = "grad-forged-331"
        var forged900 = chainGraduatedEntry(base: 349, chain: [900])
        forged900.id = "grad-forged-900"      // `chain-900` 이 아니라서 331→900 이 닫히지 않는다
        let s = try await hatched(cVmonLine, dex: [forged331, forged900])

        // 전제: 정말로 두 간선이 동시에 열렸다(안 열리면 아래 단언이 공허해진다).
        XCTAssertEqual(Set(s.chainCandidates.map(\.toID)), [900, 405],
                       "전제 실패: 두 간선이 동시에 열리지 않았다")
        XCTAssertEqual(s.availableChainPromotion?.toID, 900,
                       "동시에 열렸을 때 뒷 단계(405)를 먼저 골랐다 — 900 을 건너뛴 승급이 가능해진다")

        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertFalse(s.state.dex.contains { $0.id == "chain-405" },
                       "1회 지불로 파이터 모드에 도달했다")
        XCTAssertEqual(s.state.spentTokens, s.chainPromotionPrice, "1단계분만 지불해야 한다")
    }

    /// 알(육성 개체 없음) 상태에서는 승급 후보가 **비어야 한다**.
    ///
    /// `chainPromotionControl` 은 `armorControl` 과 달리 body 에 무조건 있고 `CompanionHeader` 도
    /// `hasActive` 와 무관하게 렌더된다. 가드가 없으면 331 기록 + 잔액만으로 승급 버튼이 **활성**으로
    /// 뜨는데 눌러도 `recordJogressDexEntry` 의 `state.active` 언랩에서 false 로 떨어져 아무 일도
    /// 안 난다(`JogressEvolutionTests.testNoCandidatesWhileEgg` 와 같은 축).
    ///
    /// **같은 도감·같은 잔액**을 부화한 스토어에도 넣어 후보가 나오는 것을 확인한다 — 안 그러면
    /// 시드 항목 모양이 잘못돼서 비었을 때도 이 테스트가 통과한다.
    func testNoChainCandidatesWhileEgg() async throws {
        var record331 = chainGraduatedEntry(base: 349, chain: [331])
        record331.id = "jogress-331"
        var seed = CompanionState()
        seed.dex = [record331]
        seed.usedSinceInstall = 20_000_000_000

        let egg = try store(cVmonLine, seed: seed)
        XCTAssertNil(egg.state.active, "전제: 알 상태여야 한다")
        XCTAssertTrue(egg.hasJogressPartnerRecord(331), "전제: 331 기록은 유효하다")
        XCTAssertTrue(egg.availableTokens >= egg.chainPromotionPrice, "전제: 잔액은 충분하다")
        XCTAssertTrue(egg.chainCandidates.isEmpty,
                      "알 상태인데 승급 후보가 떴다 — 눌러도 무반응인 버튼이 된다")
        XCTAssertNil(egg.availableChainPromotion)

        // 양성 대조: 같은 도감·잔액으로 부화하면 331→900 후보가 나온다.
        let hatchedStore = try await hatched(cVmonLine, dex: [record331])
        XCTAssertEqual(hatchedStore.chainCandidates.map(\.toID), [900],
                       "시드 도감 항목이 애초에 후보를 만들지 못한다 — 위 단언이 공허하다")
    }

    /// 두 단계를 차례로 밟으면 405 에 도달한다.
    func testTwoStepPromotionReachesFighterMode() async throws {
        let s = try await withPaildramonRecord()
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.hasJogressPartnerRecord(900), "900 기록이 없다")

        XCTAssertEqual(s.chainCandidates.map(\.toID), [405], "900 기록 후 다음 단계가 안 열렸다")
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.hasJogressPartnerRecord(405), "405 기록이 없다")
    }

    /// 승급을 다 마치면 후보가 비워진다 — 같은 종을 두 번 사게 두지 않는다.
    func testCompletedChainOffersNoFurtherCandidates() async throws {
        let s = try await withPaildramonRecord()
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.chainCandidates.isEmpty, "이미 끝난 체인이 다시 후보로 나왔다")
    }

    /// 이미 있는 기록을 다시 사도 **토큰이 빠져나가지 않는다**.
    func testRepeatPromotionDoesNotChargeAgain() async throws {
        let s = try await withPaildramonRecord()
        let candidate = try XCTUnwrap(s.availableChainPromotion)
        XCTAssertTrue(s.performChainPromotion(candidate))
        let spentAfterFirst = s.state.spentTokens
        XCTAssertEqual(spentAfterFirst, s.chainPromotionPrice)

        XCTAssertFalse(s.performChainPromotion(candidate), "같은 승급이 두 번 성공했다")
        XCTAssertEqual(s.state.spentTokens, spentAfterFirst, "두 번째 호출이 토큰을 또 가져갔다")
    }

    // MARK: ② 게이트 — 기록·잔액

    /// 출발 종 기록이 없으면 승급 불가.
    func testCannotPromoteWithoutSourceRecord() async throws {
        let s = try await hatched(cVmonLine)   // 331 기록 없음
        XCTAssertTrue(s.chainCandidates.isEmpty, "331 기록이 없는데 후보가 나왔다")

        let lying = CompanionStore.ChainCandidate(fromID: 331, toID: 900, price: 0, affordable: true)
        XCTAssertFalse(s.performChainPromotion(lying), "기록 없이 승급이 통과했다")
        XCTAssertFalse(s.hasJogressPartnerRecord(900))
    }

    /// 잔액 부족이면 불가 — 후보로는 보이되 `affordable` 이 false 다(안내를 위해 남긴다).
    func testCannotPromoteWithoutEnoughTokens() async throws {
        let s = try await withPaildramonRecord(tokens: 4_000_000_000)
        // 331 도달까지 쓴 토큰은 없다(죠그레스는 무료) — 잔액은 4.00B, 가격은 3.00B 라 한 번은 된다.
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))

        let next = try XCTUnwrap(s.chainCandidates.first)
        XCTAssertEqual(next.toID, 405)
        XCTAssertFalse(next.affordable, "잔액 1.00B 로 3.00B 승급이 가능하다고 표시됐다")
        XCTAssertNil(s.availableChainPromotion, "잔액 부족인데 실행 가능 후보가 나왔다")
        XCTAssertFalse(s.performChainPromotion(next), "잔액 부족인데 승급이 통과했다")
        XCTAssertFalse(s.hasJogressPartnerRecord(405))
    }

    /// 가격을 참칭한 후보(0원)로도 통과하지 못한다 — 게이트는 후보가 아니라 store 가 재조회한다.
    func testFabricatedPriceCannotBypassWalletGate() async throws {
        let s = try await withPaildramonRecord(tokens: 1_000_000_000)   // 3.00B 에 못 미친다
        let lying = CompanionStore.ChainCandidate(fromID: 331, toID: 900,
                                                 price: 0, affordable: true)
        XCTAssertFalse(s.performChainPromotion(lying), "호출자가 가격을 참칭해 게이트를 통과했다")
        XCTAssertFalse(s.hasJogressPartnerRecord(900))
        XCTAssertEqual(s.state.spentTokens, 0)
    }

    /// 출발 종이 **놓아준/아머** 기록뿐이면 승급 불가 — 졸업 기록만 인정한다.
    func testReleasedSourceRecordDoesNotQualify() async throws {
        var released = chainGraduatedEntry(base: 349, chain: [331])
        released.id = "jogress-331"
        released.releasedAt = chainFixedNow
        let s = try await hatched(cVmonLine, dex: [released])
        XCTAssertTrue(s.chainCandidates.isEmpty, "놓아준 기록이 승급 출발점으로 인정됐다")

        var armored = chainGraduatedEntry(base: 349, chain: [331])
        armored.id = "armor-forged-331"
        armored.armoredAt = chainFixedNow
        let a = try await hatched(cVmonLine, dex: [armored])
        XCTAssertTrue(a.chainCandidates.isEmpty, "아머 기록이 승급 출발점으로 인정됐다")
    }

    // MARK: ③ 비소모·불변조건

    /// 출발 종 기록은 **소모되지 않는다** — 승급 후에도 331 이 도감에 남는다.
    func testSourceRecordSurvivesPromotion() async throws {
        let s = try await withPaildramonRecord()
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.hasJogressPartnerRecord(331), "출발 종 기록이 소모됐다")
        XCTAssertTrue(s.hasJogressPartnerRecord(900), "결과 종 기록이 없다")
    }

    /// 승급은 **성장 미터·통계·최종체 집합**을 건드리지 않는다(아머 §7 과 같은 원칙).
    /// 지갑은 `spentTokens` 만 오른다 — 이게 깨지면 승급이 진화 진행을 밀거나 되돌린다.
    func testPromotionTouchesOnlySpentTokens() async throws {
        let s = try await withPaildramonRecord()
        let usedBefore = s.state.usedSinceInstall
        let finalsBefore = s.state.collectedFinals
        let usedAtStageBefore = s.state.active?.usedAtStage
        let tokensBefore = s.availableTokens

        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))

        XCTAssertEqual(s.state.usedSinceInstall, usedBefore, "승급이 성장 미터를 움직였다")
        XCTAssertEqual(s.state.collectedFinals, finalsBefore, "승급이 collectedFinals 를 바꿨다")
        XCTAssertEqual(s.state.active?.usedAtStage, usedAtStageBefore, "승급이 단계 성장치를 바꿨다")
        XCTAssertEqual(s.availableTokens, tokensBefore - s.chainPromotionPrice, "차감액이 가격과 다르다")
        XCTAssertEqual(s.state.spentTokens, s.chainPromotionPrice)
    }

    /// 승급은 **사다리 필드를 건드리지 않는다** — 결과 종(900/405)은 라인 stages 에 없어서
    /// 사다리에 얹는 순간 `node(withID:)` 가 nil 을 주고 성장이 영구 정지한다.
    func testPromotionDoesNotTouchLadderFields() async throws {
        let s = try await withPaildramonRecord()
        func snapshot() -> [String] {
            guard let a = s.state.active else { return [] }
            return ["\(a.pathIDs)", "\(a.currentID)", "\(a.stageIndex)", "\(a.plannedPathIDs)"]
        }
        let before = snapshot()
        let thresholdBefore = s.threshold

        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))

        XCTAssertEqual(snapshot(), before, "승급이 사다리 필드를 바꿨다")
        XCTAssertEqual(s.threshold, thresholdBefore, "승급이 임계값을 바꿨다")
        XCTAssertEqual(s.currentSpeciesID, 358, "성장 축이 승급 결과로 옮겨갔다")
        XCTAssertNil(s.armorSpeciesID, "승급이 표시 축(아머)을 건드렸다")
        XCTAssertEqual(s.displaySpeciesID, 358)
    }

    /// 승급 이후에도 성장이 계속된다 — 필드가 같아도 배선이 끊길 수 있으므로 동작으로 확인한다.
    func testGrowthContinuesAfterPromotion() async throws {
        let s = try await hatched(cVmonLine, dex: [chainGraduatedEntry(base: 356, chain: [356, 336])])
        XCTAssertEqual(s.currentSpeciesID, 349)
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))

        s.applyUsage(Int(1e12))
        XCTAssertNil(s.state.active, "승급 후 졸업이 멈췄다")
        XCTAssertTrue(s.state.collectedFinals.contains("349:358"), "졸업이 최종체로 기록되지 않았다")
    }

    // MARK: ④ 결과의 자격 — 죠그레스 파트너가 된다

    /// 승급 결과는 죠그레스 파트너 자격을 갖는다(405 가 481 의 부모이므로 이게 필수다).
    func testPromotionResultQualifiesAsJogressPartner() async throws {
        let s = try await withPaildramonRecord()
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))
        XCTAssertTrue(s.hasJogressPartnerRecord(405), "승급 결과가 파트너 자격을 갖지 못했다")

        let entry = try XCTUnwrap(s.state.dex.first { $0.id == "chain-405" })
        XCTAssertNil(entry.releasedAt, "승급 기록이 놓아준 형태로 남았다")
        XCTAssertNil(entry.armoredAt, "승급 기록이 아머 형태로 남았다")
        XCTAssertEqual(entry.chainOrder, [405], "승급 기록에 다른 종이 섞였다")
    }

    // MARK: ⑤ 영속

    func testPromotionSurvivesRestart() async throws {
        var seed = CompanionState()
        seed.dex = [chainGraduatedEntry(base: 349, chain: [331])]
        seed.dex[0].id = "jogress-331"
        seed.usedSinceInstall = 20_000_000_000
        seed.language = .ko
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-\(UUID().uuidString).json")
        try JSONEncoder().encode(seed).write(to: url)

        let suite = "chain-promotion-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.removeTestSuite(suite) }
        let s = CompanionStore(provider: ChainStubProvider(value: cVmonLine),
                               clock: { chainFixedNow }, fileURL: url, rng: SeededRNG(seed: 7),
                               defaults: defaults)
        await s.hatch(baseID: cVmonLine.baseID)
        XCTAssertTrue(s.performChainPromotion(try XCTUnwrap(s.availableChainPromotion)))

        let reloaded = CompanionStore(provider: ChainStubProvider(value: cVmonLine),
                                      clock: { chainFixedNow }, fileURL: url, rng: SeededRNG(seed: 7),
                                      defaults: defaults)
        XCTAssertTrue(reloaded.hasJogressPartnerRecord(900), "재시작 후 승급 기록이 사라졌다")
        XCTAssertEqual(reloaded.state.spentTokens, s.chainPromotionPrice, "재시작 후 지출이 사라졌다")
    }

    // MARK: ⑥ 다국어

    /// 7개 언어 전부에 문구가 있고, 언어마다 다르게 해석된다(빈 문자열·미번역 누락 방지).
    func testChainStringsExistForAllLanguages() {
        for lang in AppLanguage.allCases {
            let l = L(lang)
            XCTAssertFalse(l.chainPromotion.isEmpty, "\(lang): 제목이 비어 있다")
            let button = l.chainPromoteInto("황제드라몬: 드래곤 모드", "3.00B")
            XCTAssertTrue(button.contains("황제드라몬: 드래곤 모드"), "\(lang): 버튼에 결과 이름이 없다")
            XCTAssertTrue(button.contains("3.00B"), "\(lang): 버튼에 가격이 없다")
            XCTAssertTrue(l.chainNeedsTokens("3.00B").contains("3.00B"), "\(lang): 안내에 금액이 없다")
        }
    }

    /// 한국어 조사는 `(으)로` 로 헤지한다 — 결과 종이 `모드` 로 끝나 받침이 없다.
    func testKoreanParticleIsHedged() {
        let button = L(.ko).chainPromoteInto("황제드라몬: 파이터 모드", "3.00B")
        XCTAssertTrue(button.contains("(으)로"), "ko 조사가 헤지되지 않았다: \(button)")
    }

    // MARK: ⑦ 가격

    /// 가격은 상점과 **같은 난이도 배율**로 움직인다.
    func testPriceScalesWithShopDifficulty() async throws {
        let s = try await withPaildramonRecord()
        // 구현을 되읽지 않고 **구체값**을 박는다 — 스케일링이 통째로 사라지는 회귀를 잡는다.
        XCTAssertEqual(s.shopDifficulty, 1.0, "전제: 기본 난이도다")
        XCTAssertEqual(s.chainPromotionPrice, 3_000_000_000)

        s.setShopDifficulty(2.0)
        XCTAssertEqual(s.chainPromotionPrice, DigimonBalance.scaled(ChainPromotion.price, by: 2.0))
        XCTAssertEqual(s.chainCandidates.first?.price, s.chainPromotionPrice,
                       "후보가 든 가격이 난이도를 반영하지 않았다")
    }

    /// 최종 보상 경로라 기존 상점 최고가보다 비싸다 — 통과 의례로 전락하지 않게.
    func testPriceExceedsExistingShopItems() {
        XCTAssertGreaterThan(ChainPromotion.price, DigimentalItem.price)
        XCTAssertGreaterThan(ChainPromotion.price, FreshEgg.price)
        XCTAssertGreaterThan(ChainPromotion.price, RareCandy.price)
    }

    // MARK: ⑧ ★ 팔라딘 모드 도달 — 전체 경로 통합

    /// **GAME-DESIGN §3 이 규정한 최종 보상 경로 전체를 한 번에 밟는다.**
    ///
    /// 워그레이몬(202)·메탈가루몬(168) 졸업 → 죠그레스 → 오메가몬(183)
    /// → 엑스브이몬(358)·스팅몬(336) → 죠그레스 → 파일드라몬(331)
    /// → 지불 승급 → 드래곤 모드(900) → 지불 승급 → 파이터 모드(405)
    /// → 405 + 183 죠그레스 → **팔라딘 모드(481)**
    ///
    /// 중간 단계마다 단언을 넣어 어디서 끊기는지 드러나게 한다. 이게 통과해야 "팔라딘 영구 도달 불가"
    /// 가 닫혔다고 말할 수 있다. 라인 스텁은 한 종만 돌려주므로 단계마다 **도감을 물려주며** 새
    /// 스토어를 만든다(파트너는 다른 라인이라 한 스토어에서 키울 수 없다).
    func testFullPaladinModeReachPath() async throws {
        // ── 1) 아구몬 라인을 워그레이몬(202)까지 졸업시킨다.
        let agumon = try await hatched(cAgumonLine)
        grow(agumon, to: 202)
        agumon.applyUsage(Int(1e12))
        XCTAssertNil(agumon.state.active, "아구몬 라인이 졸업하지 않았다")
        var dex = agumon.state.dex
        XCTAssertTrue(dex.contains { $0.chainOrder.contains(202) }, "① 워그레이몬 졸업 기록이 없다")

        // ── 2) 가부몬 라인을 메탈가루몬(168)까지 졸업시킨다.
        let gabumon = try await hatched(cGabumonLine, dex: dex)
        grow(gabumon, to: 168)
        gabumon.applyUsage(Int(1e12))
        dex = gabumon.state.dex
        XCTAssertTrue(dex.contains { $0.chainOrder.contains(168) }, "② 메탈가루몬 졸업 기록이 없다")

        // ── 3) 202 + 168 → 오메가몬(183). 육성 개체를 168 까지 올려 죠그레스한다.
        let omega = try await hatched(cGabumonLine, dex: dex)
        grow(omega, to: 168)
        let omegaCandidate = try XCTUnwrap(omega.jogressCandidates.first { $0.resultID == 183 },
                                          "③ 오메가몬 조합이 후보로 안 나왔다")
        XCTAssertTrue(omegaCandidate.hasPartner, "③ 워그레이몬 기록이 파트너로 인정되지 않았다")
        XCTAssertTrue(omega.performJogress(omegaCandidate), "③ 오메가몬 죠그레스 실패")
        dex = omega.state.dex
        XCTAssertTrue(omega.hasJogressPartnerRecord(183), "③ 오메가몬이 도감에 등록되지 않았다")

        // ── 4) 웜몬 라인을 스팅몬(336)까지 졸업시킨다.
        let wormmon = try await hatched(cWormmonLine, dex: dex)
        grow(wormmon, to: 336)
        wormmon.applyUsage(Int(1e12))
        dex = wormmon.state.dex
        XCTAssertTrue(dex.contains { $0.chainOrder.contains(336) }, "④ 스팅몬 졸업 기록이 없다")

        // ── 5) 엑스브이몬(358) + 스팅몬(336) → 파일드라몬(331).
        let paildramon = try await hatched(cVmonLine, dex: dex)
        grow(paildramon, to: 358)
        let paildraCandidate = try XCTUnwrap(paildramon.jogressCandidates.first { $0.resultID == 331 },
                                            "⑤ 파일드라몬 조합이 후보로 안 나왔다")
        XCTAssertTrue(paildramon.performJogress(paildraCandidate), "⑤ 파일드라몬 죠그레스 실패")
        XCTAssertTrue(paildramon.hasJogressPartnerRecord(331), "⑤ 파일드라몬이 도감에 등록되지 않았다")

        // ── 6) 토큰 지불 승급: 331 → 900(드래곤 모드).
        let dragonStep = try XCTUnwrap(paildramon.availableChainPromotion, "⑥ 승급 후보가 없다")
        XCTAssertEqual(dragonStep.fromID, 331)
        XCTAssertEqual(dragonStep.toID, 900, "⑥ 첫 승급이 900 을 건너뛰었다")
        XCTAssertTrue(paildramon.performChainPromotion(dragonStep), "⑥ 드래곤 모드 승급 실패")
        XCTAssertTrue(paildramon.hasJogressPartnerRecord(900), "⑥ 드래곤 모드가 도감에 없다")

        // ── 7) 토큰 지불 승급: 900 → 405(파이터 모드).
        let fighterStep = try XCTUnwrap(paildramon.availableChainPromotion, "⑦ 두 번째 승급 후보가 없다")
        XCTAssertEqual(fighterStep.toID, 405)
        XCTAssertTrue(paildramon.performChainPromotion(fighterStep), "⑦ 파이터 모드 승급 실패")
        XCTAssertTrue(paildramon.hasJogressPartnerRecord(405), "⑦ 파이터 모드가 도감에 없다")
        dex = paildramon.state.dex

        // ── 8) 405 + 183 → 팔라딘 모드(481). 양쪽 부모가 모두 도감 기록이다(사다리 밖 종).
        let paladinStore = try await hatched(cVmonLine, dex: dex)
        XCTAssertTrue(paladinStore.hasJogressPartnerRecord(405), "⑧ 405 기록이 전달되지 않았다")
        XCTAssertTrue(paladinStore.hasJogressPartnerRecord(183), "⑧ 183 기록이 전달되지 않았다")
        let paladin = try XCTUnwrap(paladinStore.jogressCandidates.first { $0.resultID == 481 },
                                    "⑧ 팔라딘 조합이 후보로 안 나왔다 — 여기서 막히면 영구 도달 불가다")
        XCTAssertTrue(paladin.hasPartner, "⑧ 팔라딘 부모 기록이 인정되지 않았다")
        XCTAssertTrue(paladinStore.performJogress(paladin), "⑧ 팔라딘 죠그레스 실패")

        XCTAssertTrue(paladinStore.hasJogressPartnerRecord(481), "★ 팔라딘 모드가 도감에 등록되지 않았다")
        XCTAssertEqual(paladinStore.state.dex.first { $0.id == "jogress-481" }?.chainOrder, [481])
    }

    // MARK: ⑨ 도감 전용 죠그레스 완화의 경계

    /// 완화는 **양쪽 부모가 모두 사다리 밖**인 조합에만 적용된다. 202+168→183 은 부모가 둘 다
    /// 사다리 종이므로 육성 개체 없이는 성립하지 않는다 — "2마리가 필요하다"(§3)는 전제 유지.
    func testDexOnlyRelaxationDoesNotLeakToLadderCombos() async throws {
        // 202·168 기록을 둘 다 가진 채 **관계없는 종**(349)을 키운다.
        let dex = [chainGraduatedEntry(base: 1, chain: [1, 31, 202], rarity: .legendary),
                   chainGraduatedEntry(base: 16, chain: [16, 33, 168], rarity: .legendary)]
        let s = try await hatched(cVmonLine, dex: dex)
        XCTAssertEqual(s.currentSpeciesID, 349, "전제: 육성 개체는 오메가몬 부모가 아니다")

        XCTAssertTrue(s.jogressCandidates.allSatisfy { $0.resultID != 183 },
                      "사다리 조합이 육성 개체 없이 후보로 나왔다")
        let lying = CompanionStore.JogressCandidate(partnerID: 202, resultID: 183, hasPartner: true)
        XCTAssertFalse(s.performJogress(lying), "사다리 조합이 도감 전용 경로로 새어나갔다")
        XCTAssertFalse(s.hasJogressPartnerRecord(183))
    }

    /// 도감 전용 조합은 **진행이 시작된 뒤에만** 후보로 나온다. 갓 부화한 플레이어에게 영구 비활성
    /// 팔라딘 행이 상시 떠 있으면 안 된다 — 죠그레스 컨트롤은 후보가 있으면 무조건 그리기 때문이다.
    /// (`JogressEvolutionTests.testNoCandidatesForSpeciesWithoutCombo` 가 이 회귀를 잡았다.)
    func testDexOnlyComboIsHiddenUntilProgressStarts() async throws {
        let fresh = try await hatched(cVmonLine)
        XCTAssertTrue(fresh.jogressCandidates.isEmpty,
                      "기록이 하나도 없는데 팔라딘 행이 떴다: \(fresh.jogressCandidates.map(\.resultID))")

        // 한쪽(183) 기록이 생기면 "다음 목표" 로 보이기 시작한다 — 안내는 아직 없는 쪽을 가리킨다.
        var omegaRecord = chainGraduatedEntry(base: 1, chain: [183], rarity: .legendary)
        omegaRecord.id = "jogress-183"
        let started = try await hatched(cVmonLine, dex: [omegaRecord])
        let paladin = try XCTUnwrap(started.jogressCandidates.first { $0.resultID == 481 },
                                    "기록이 생겼는데도 팔라딘이 안 보인다")
        XCTAssertFalse(paladin.hasPartner)
        XCTAssertEqual(paladin.partnerID, 405, "안내가 이미 가진 쪽(183)을 요구했다")
        XCTAssertTrue(started.jogressPartnerHint(paladin).contains(
            CompanionStore.dataName(405, .ko)), "안내가 아직 없는 405 를 가리키지 않는다")
    }

    /// 팔라딘 조합도 **한쪽 부모 기록만으로는** 성립하지 않는다 — 게이트가 양쪽을 본다.
    func testPaladinNeedsBothParentRecords() async throws {
        var only405 = chainGraduatedEntry(base: 349, chain: [405])
        only405.id = "chain-405"
        let s = try await hatched(cVmonLine, dex: [only405])
        XCTAssertTrue(s.hasJogressPartnerRecord(405), "전제: 405 기록은 있다")
        XCTAssertFalse(s.hasJogressPartnerRecord(183), "전제: 183 기록은 없다")

        XCTAssertTrue(s.jogressCandidates.first { $0.resultID == 481 }?.hasPartner == false,
                      "한쪽 기록만으로 팔라딘이 실행 가능으로 표시됐다")
        let lying = CompanionStore.JogressCandidate(partnerID: 183, resultID: 481, hasPartner: true)
        XCTAssertFalse(s.performJogress(lying), "한쪽 기록만으로 팔라딘이 성립했다")
        XCTAssertFalse(s.hasJogressPartnerRecord(481))
    }
}
