import XCTest
@testable import DigiTokenBar

/// 죠그레스 진화(GAME-DESIGN.md §3) — 두 개체가 합쳐지지만 앱은 1마리만 키운다.
/// 한쪽 부모는 육성 중인 개체, 다른 쪽은 **도감 졸업 기록**이 대신한다(소모되지 않는다).
///
/// 라인 스텁은 `ArmorEvolutionTests` 와 같은 이유로 **실제 데이터의 id** 를 쓴다: 게이트가
/// `DigimonData.jogressResult` 조회라서 합성 id 로는 조합이 아예 없다.
private struct JogressStubProvider: DigimonLineProviding {
    let value: EvoLine
    func line(baseSpeciesID: Int) async throws -> EvoLine { value }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
}

private func jogressNode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode {
    EvoNode(speciesID: id, children: children)
}

private func jogressLine(base: Int, tree: EvoNode, rarity: Rarity = .uncommon) -> EvoLine {
    var names: [Int: [String: String]] = [:]
    func walk(_ n: EvoNode) {
        names[n.speciesID] = DigimonData.name(for: n.speciesID)?.localizedNames ?? [:]
        n.children.forEach(walk)
    }
    walk(tree)
    return EvoLine(baseID: base, tree: tree, rarity: rarity, names: names)
}

/// 죠그레스 부모 4쌍이 속한 라인들. 부모가 Child 가 아닌 조합이 있어(War Greymon 202 는 Ultimate)
/// 라인 stages 를 부모까지 이어 둔다.
private let vmonLine = jogressLine(base: 349, tree: jogressNode(349, [jogressNode(358)]))
private let wormmonLine = jogressLine(base: 356, tree: jogressNode(356, [jogressNode(336)]))
/// Tailmon(83) — 데이터상 Child 지만 죠그레스 부모다. `DigiLevel` 로 게이트하면 여기서 깨진다.
private let tailmonLine = jogressLine(base: 83, tree: jogressNode(83, [jogressNode(38)]), rarity: .rare)
private let hawkmonLine = jogressLine(base: 399, tree: jogressNode(399, [jogressNode(267)]))
private let armadimonLine = jogressLine(base: 271, tree: jogressNode(271, [jogressNode(266)]))
private let patamonLine = jogressLine(base: 98, tree: jogressNode(98, [jogressNode(3)]), rarity: .rare)
private let agumonLine = jogressLine(base: 1, tree: jogressNode(1, [jogressNode(31, [jogressNode(202)])]),
                                     rarity: .legendary)
private let gabumonLine = jogressLine(base: 16, tree: jogressNode(16, [jogressNode(33, [jogressNode(168)])]),
                                      rarity: .legendary)

private let jogressFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// 파트너 역할을 할 **졸업** 도감 항목. 실제 `graduate()` 가 만드는 것과 같은 형태
/// (`releasedAt`/`armoredAt` 둘 다 nil)다.
private func graduatedEntry(base: Int, chain: [Int], rarity: Rarity = .uncommon) -> DexEntry {
    DexEntry(id: "grad-\(chain.last ?? base)", baseID: base, finalID: chain.last ?? base,
             chainOrder: chain, rarity: rarity, caughtAt: jogressFixedNow)
}

@MainActor
final class JogressEvolutionTests: XCTestCase {

    /// 언어는 **시드에 명시 고정**한다 — `CompanionState.language` 기본값 `.systemDefault` 는
    /// `Locale.preferredLanguages` 를 읽으므로, 고정하지 않으면 개발자 맥(ko)에서만 통과하고
    /// 영어 CI 러너에서 이름 단언이 깨진다(`ArmorEvolutionTests` 와 같은 이유).
    private func store(_ line: EvoLine, seed state: CompanionState = CompanionState(),
                       language: AppLanguage = .ko, rngSeed: UInt64 = 7) throws -> CompanionStore {
        var state = state
        state.language = language
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jogress-\(UUID().uuidString).json")
        try JSONEncoder().encode(state).write(to: url)
        return CompanionStore(provider: JogressStubProvider(value: line),
                              clock: { jogressFixedNow }, fileURL: url, rng: SeededRNG(seed: rngSeed))
    }

    /// 부화 + 도감 시드. `dex` 로 파트너 기록을 심는다(파트너는 다른 라인이라 한 스토어에서 키울 수 없다).
    private func hatched(_ line: EvoLine, dex: [DexEntry] = [],
                         language: AppLanguage = .ko) async throws -> CompanionStore {
        var seed = CompanionState()
        seed.dex = dex
        seed.usedSinceInstall = 20_000_000_000
        let s = try store(line, seed: seed, language: language)
        await s.hatch(baseID: line.baseID)
        return s
    }

    /// 사다리 종이 부모가 될 때까지 성장시킨다 — 죠그레스 부모는 Child 가 아닌 경우가 많다.
    private func grow(_ s: CompanionStore, to speciesID: Int) {
        while s.currentSpeciesID != speciesID, s.state.active != nil {
            s.applyUsage(s.threshold)
        }
        XCTAssertEqual(s.currentSpeciesID, speciesID, "사다리를 \(speciesID) 까지 못 올렸다")
    }

    // MARK: 데이터 전제

    /// 스텁이 아니라 실제 번들 데이터가 아래 시나리오를 지지하는지 먼저 고정한다.
    func testJogressDataForAllFourCombos() {
        XCTAssertEqual(DigimonData.jogressResult(358, 336), 331)
        XCTAssertEqual(DigimonData.jogressResult(83, 267), 390)
        XCTAssertEqual(DigimonData.jogressResult(266, 3), 387)
        XCTAssertEqual(DigimonData.jogressResult(202, 168), 183)
        XCTAssertNil(DigimonData.jogressResult(358, 267), "없는 조합이 조회되면 게이트가 무의미해진다")
    }

    /// 순서 무관 — `JogressKey` 가 정규화하므로 뒤집어 조회해도 같은 결과여야 한다.
    func testLookupIsOrderIndependent() {
        for (a, b) in [(358, 336), (83, 267), (266, 3), (202, 168)] {
            XCTAssertEqual(DigimonData.jogressResult(a, b), DigimonData.jogressResult(b, a),
                           "(\(a), \(b)) 조회가 순서에 따라 달라졌다")
        }
    }

    // MARK: ① 조합 4개가 각각 성립한다

    func testPaildramonFromXVmonAndStingmon() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertEqual(candidate.partnerID, 336)
        XCTAssertEqual(candidate.resultID, 331)
        XCTAssertTrue(s.performJogress(candidate))
        XCTAssertTrue(s.hasJogressPartnerRecord(331), "결과가 도감에 등록되지 않았다")
    }

    func testSilphymonFromTailmonAndAquilamon() async throws {
        // Tailmon(83)은 Child 단계 그대로가 부모다 — 레벨 축 게이트였다면 여기서 막힌다.
        let s = try await hatched(tailmonLine, dex: [graduatedEntry(base: 399, chain: [399, 267])])
        XCTAssertEqual(s.currentSpeciesID, 83)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertEqual(candidate.resultID, 390)
        XCTAssertTrue(s.performJogress(candidate))
        XCTAssertTrue(s.hasJogressPartnerRecord(390))
    }

    func testShakkoumonFromAnkylomonAndAngemon() async throws {
        let s = try await hatched(armadimonLine, dex: [graduatedEntry(base: 98, chain: [98, 3], rarity: .rare)])
        grow(s, to: 266)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertEqual(candidate.partnerID, 3)
        XCTAssertEqual(candidate.resultID, 387)
        XCTAssertTrue(s.performJogress(candidate))
        XCTAssertTrue(s.hasJogressPartnerRecord(387))
    }

    func testOmegamonFromWarGreymonAndMetalGarurumon() async throws {
        let s = try await hatched(agumonLine,
                                  dex: [graduatedEntry(base: 16, chain: [16, 33, 168], rarity: .legendary)])
        grow(s, to: 202)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertEqual(candidate.partnerID, 168)
        XCTAssertEqual(candidate.resultID, 183)
        XCTAssertTrue(s.performJogress(candidate))
        XCTAssertTrue(s.hasJogressPartnerRecord(183))
    }

    /// 파트너를 어느 쪽에서 키웠든 성립한다 — 위 4개의 거울상(Wormmon 쪽에서 본 Paildramon).
    func testCombosWorkFromEitherSideOfThePair() async throws {
        let s = try await hatched(wormmonLine, dex: [graduatedEntry(base: 349, chain: [349, 358])])
        grow(s, to: 336)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertEqual(candidate.partnerID, 358)
        XCTAssertEqual(candidate.resultID, 331)
        XCTAssertTrue(s.performJogress(candidate))
    }

    // MARK: ② 파트너 기록이 없으면 불가 + 안내

    /// 조합은 있는데 파트너 기록이 없다 → 후보로는 보이되 실행 불가 + 안내 문구.
    /// 안내는 **전 언어**에서 파트너 이름을 담아야 한다(`AppLanguage.allCases` 는 7개다).
    func testMissingPartnerBlocksJogressAndNamesThePartnerInEveryLanguage() async throws {
        for language in AppLanguage.allCases {
            let s = try await hatched(vmonLine, language: language)
            grow(s, to: 358)
            XCTAssertNil(s.availableJogress, "[\(language)] 파트너 기록 없이 실행 가능해졌다")
            guard let candidate = s.jogressCandidates.first else {
                return XCTFail("[\(language)] 조합 자체는 후보로 보여야 안내할 수 있다")
            }
            XCTAssertFalse(candidate.hasPartner)
            XCTAssertFalse(s.performJogress(candidate), "[\(language)] 게이트가 뚫렸다")
            XCTAssertFalse(s.hasJogressPartnerRecord(331), "[\(language)] 실패했는데 기록이 남았다")

            // 이름은 테스트에 굳히지 않고 store 와 같은 경로로 해석한다 — ko 외 언어는 폴백을 타므로
            // 기대값을 박으면 ja/es/fr/pt/de 행이 표기 폴백만으로 깨진다.
            let partnerName = CompanionStore.dataName(336, language)
            let hint = s.jogressPartnerHint(candidate)
            XCTAssertTrue(hint.contains(partnerName),
                          "[\(language)] 안내에 파트너 이름이 없다: \(hint)")
            XCTAssertFalse(hint.isEmpty)
        }
    }

    /// ko 문구가 사양서(§3 `"Stingmon을 먼저 졸업시켜야 합니다"`)를 따르는지 고정 —
    /// 다국어화 과정에서 한국어가 영문으로 바뀌지 않았는지 본다.
    /// 조사는 `을(를)` 로 헤지한다: 파트너 대부분은 `몬` 으로 끝나지만 405("…파이터 모드")는 아니다.
    func testKoreanHintMatchesSpecWording() {
        XCTAssertEqual(L(.ko).jogressNeedsPartner("스팅몬"), "스팅몬을(를) 먼저 졸업시켜야 합니다")
        XCTAssertNotEqual(L(.en).jogressNeedsPartner("Stingmon"), L(.ko).jogressNeedsPartner("Stingmon"),
                          "영어 문구가 한국어와 같으면 다국어 계층을 타지 않은 것이다")
    }

    // MARK: ③ 파트너는 소모되지 않는다

    /// 도감은 재고가 아니라 기록이다 — 죠그레스를 몇 번 해도 파트너 기록이 그대로 남는다.
    func testPartnerRecordIsNotConsumed() async throws {
        let partner = graduatedEntry(base: 356, chain: [356, 336])
        let s = try await hatched(vmonLine, dex: [partner])
        grow(s, to: 358)
        guard let candidate = s.availableJogress else { return XCTFail("죠그레스 후보 없음") }
        XCTAssertTrue(s.performJogress(candidate))

        XCTAssertTrue(s.hasJogressPartnerRecord(336), "파트너 기록이 소모됐다")
        XCTAssertEqual(s.state.dex.filter { $0.id == partner.id }.count, 1)
        // 항목이 남은 것만으로는 부족하다 — 자격까지 그대로여야 한다(놓아줌·아머 플래그가 붙으면
        // 항목은 남은 채로 `hasJogressPartnerRecord` 만 false 가 된다).
        let after = try XCTUnwrap(s.state.dex.first { $0.id == partner.id })
        XCTAssertFalse(after.isReleased, "파트너 기록에 놓아줌 플래그가 붙었다")
        XCTAssertFalse(after.isArmored, "파트너 기록에 아머 플래그가 붙었다")
        XCTAssertEqual(after.chainOrder, partner.chainOrder, "파트너 기록의 체인이 바뀌었다")
        // 후보 목록으로는 확인하지 않는다 — 331 은 이미 얻었으므로 그 행이 후보에서 빠지는 게 맞다
        // (같은 파일 `testResultRecordIsFoldedPerSpeciesNotPerInstance` 가 그 축을 고정한다).
        // 파트너 비소모는 기록의 자격이 남았는가로 판정한다.
    }

    // MARK: ④ 결과가 도감에 등록된다

    func testResultIsRecordedInDexAsGraduation() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        guard let entry = s.state.dex.first(where: { $0.finalID == 331 }) else {
            return XCTFail("죠그레스 도감 항목 없음")
        }
        XCTAssertFalse(entry.isReleased, "죠그레스 결과는 졸업 등록이다(§3)")
        XCTAssertFalse(entry.isArmored)
        XCTAssertEqual(entry.chainOrder, [331], "두 부모가 합쳐진 결과는 체인이 아니다")
        XCTAssertNotNil(entry.caughtAt, "정렬 키가 없으면 동행 기록 맨 뒤로 가라앉는다")
        XCTAssertTrue(s.dexSpecies.contains { $0.id == 331 }, "도감 격자에 결과가 없다")
    }

    /// 도감 칸이 `#331` 로 남지 않는다 — 사다리 라인엔 죠그레스 결과가 없어 백필이 절대 못 채운다.
    func testResultDexEntryCarriesName() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        guard let entry = s.state.dex.first(where: { $0.finalID == 331 }) else {
            return XCTFail("죠그레스 도감 항목 없음")
        }
        XCTAssertEqual(s.dexStoredChainNames(entry)?[331], "파일드라몬")
        XCTAssertFalse(entry.needsNamesRefresh, "백필이 영구히 재조회하게 두면 안 된다")
        s.setLanguage(.en)
        XCTAssertEqual(s.dexSpecies.first { $0.id == 331 }?.name, "Paildramon")
    }

    /// 같은 결과를 두 번 만들어도 도감에 한 줄만 남는다 — 기록은 **결과 종 단위**로 접힌다.
    ///
    /// 두 축을 함께 본다: ① 성공한 조합은 **후보에서 사라진다**(안 빼면 영구 활성인데 눌러도
    /// 무반응인 버튼이 남는다), ② store 는 그래도 중복 호출을 접는다 — 후보 목록은 표시값이라
    /// 참칭 호출자가 우회할 수 있으므로 붙잡아 둔 후보로 다시 불러 false 를 확인한다.
    /// 단언은 `isEmpty` 가 아니라 331 **구성원**으로 한다 — 358 에 다른 조합이 추가되면 목록
    /// 자체는 비지 않으므로, 목록 공백에 기대면 무관한 데이터 변경에 깨진다.
    func testResultRecordIsFoldedPerSpeciesNotPerInstance() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        XCTAssertTrue(s.jogressCandidates.contains { $0.resultID == 331 }, "331 조합이 후보에 없다")
        // 성공 전에 붙잡아 둔다 — 성공 후엔 후보에서 빠지므로 여기서 뽑지 않으면 재호출을 못 한다.
        let candidate = try XCTUnwrap(s.availableJogress)
        XCTAssertTrue(s.performJogress(candidate))

        XCTAssertFalse(s.jogressCandidates.contains { $0.resultID == 331 },
                       "이미 얻은 결과가 후보로 남았다 — 눌러도 무반응인 버튼이 된다")
        XCTAssertFalse(s.performJogress(candidate),
                       "두 번째 호출은 상태를 바꾸지 않으므로 false 다")
        XCTAssertEqual(s.state.dex.filter { $0.finalID == 331 }.count, 1)

        // 새 개체로 같은 조합을 다시 해도 줄이 늘지 않는다(개체별로 접었다면 여기서 2가 된다).
        s.applyUsage(Int(1e12))               // 졸업 → active 비움
        await s.hatch(baseID: vmonLine.baseID)
        grow(s, to: 358)
        XCTAssertFalse(s.jogressCandidates.contains { $0.resultID == 331 },
                       "새 개체에게도 이미 얻은 결과가 후보로 나왔다")
        XCTAssertFalse(s.performJogress(candidate))
        XCTAssertEqual(s.state.dex.filter { $0.finalID == 331 }.count, 1)

        let ids = s.state.dex.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "도감 항목 id 가 중복됐다")
    }

    // MARK: ⑤ 결과가 다른 죠그레스의 파트너가 된다 (팔라딘 모드 도달성)

    /// 183(오메가몬)을 죠그레스로 만든 뒤, 그 기록이 파트너 자격을 갖는가.
    /// 이게 깨지면 팔라딘 모드(481)가 **영구 도달 불가**다 — 양쪽 부모가 모두 죠그레스 결과물이다.
    func testJogressResultQualifiesAsPartnerForAnotherJogress() async throws {
        let s = try await hatched(agumonLine,
                                  dex: [graduatedEntry(base: 16, chain: [16, 33, 168], rarity: .legendary)])
        grow(s, to: 202)
        XCTAssertFalse(s.hasJogressPartnerRecord(183), "아직 만들지 않았다")
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        XCTAssertTrue(s.hasJogressPartnerRecord(183),
                      "죠그레스 결과가 파트너 자격을 잃으면 팔라딘 모드가 영구 도달 불가다")
        // 데이터에 이미 있는 5번째 조합(405 + 183 → 481)이 이 기록을 실제로 집는지 확인한다 —
        // 405 도달 규칙이 정해지면 코드 수정 없이 붙어야 한다.
        XCTAssertEqual(DigimonData.jogressResult(405, 183), 481)
    }

    // MARK: ⑥ 사다리 불변 (성장 정지 회귀 가드)

    /// 🚨 가장 위험한 버그: 죠그레스 결과를 사다리 필드에 쓰면 `line.tree.node(withID:)` 가 nil 이라
    /// 성장이 영구 정지한다(결과 종은 12라인 stages 어디에도 없다). 아머의 왕복 불변 단언과 같은 축.
    func testJogressLeavesEveryLadderFieldUntouched() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        s.applyUsage(1_000_000)   // 진행 중간에서 실행해야 usedAtStage 이월/리셋이 드러난다

        func snapshot() -> [String] {
            guard let a = s.state.active else { return [] }
            return ["\(a.pathIDs)", "\(a.plannedPathIDs)", "\(a.stageIndex)", "\(a.usedAtStage)",
                    "\(a.totalForms)", "\(a.hasGrowthBoost)", a.profile?.instanceID ?? "nil"]
        }
        let before = snapshot()
        let thresholdBefore = s.threshold

        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        XCTAssertEqual(snapshot(), before, "죠그레스가 사다리 필드를 바꿨다")
        XCTAssertEqual(s.threshold, thresholdBefore, "죠그레스가 임계값을 바꿨다")
        XCTAssertEqual(s.currentSpeciesID, 358, "성장 축이 죠그레스 결과로 옮겨갔다")
        XCTAssertNil(s.armorSpeciesID, "죠그레스는 표시 축(아머)도 건드리지 않는다")
        XCTAssertEqual(s.displaySpeciesID, 358)
    }

    /// 죠그레스 이후에도 성장이 계속된다 — 위 단언의 동작 버전(필드가 같아도 배선이 끊길 수 있다).
    func testGrowthContinuesAfterJogress() async throws {
        let s = try await hatched(tailmonLine, dex: [graduatedEntry(base: 399, chain: [399, 267])])
        XCTAssertEqual(s.currentSpeciesID, 83)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        s.applyUsage(s.threshold)
        XCTAssertEqual(s.currentSpeciesID, 38, "죠그레스 후 정규 진화가 멈췄다")
    }

    /// 졸업 기록의 최종체는 사다리 종이지 죠그레스 결과가 아니다.
    func testGraduationAfterJogressRecordsLadderFinal() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))
        s.applyUsage(Int(1e12))

        XCTAssertNil(s.state.active, "졸업하지 않았다")
        guard let graduated = s.state.dex.first(where: { $0.baseID == 349 && $0.finalID != 331 }) else {
            return XCTFail("졸업 항목 없음")
        }
        XCTAssertEqual(graduated.finalID, 358)
        XCTAssertEqual(graduated.chainOrder, [349, 358], "죠그레스 결과가 졸업 체인에 섞였다")
    }

    /// 죠그레스는 `collectedFinals` 를 건드리지 않는다 — 결과는 알에서 나오지 않으므로
    /// 랜덤 풀 제외에 영향을 주면 안 된다(GAME-DESIGN §2).
    func testJogressDoesNotTouchCollectedFinals() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))
        XCTAssertTrue(s.state.collectedFinals.isEmpty)
    }

    // MARK: ⑦ 파트너 자격 — 어떤 도감 항목이 인정되는가

    /// 놓아준(released) 기록은 파트너가 아니다 — 졸업시키지 않고 포기한 개체다.
    func testReleasedRecordDoesNotQualifyAsPartner() async throws {
        var released = graduatedEntry(base: 356, chain: [356, 336])
        released.releasedAt = jogressFixedNow
        let s = try await hatched(vmonLine, dex: [released])
        grow(s, to: 358)

        XCTAssertFalse(s.hasJogressPartnerRecord(336), "놓아준 기록이 파트너로 인정됐다")
        XCTAssertNil(s.availableJogress)
        XCTAssertFalse(s.performJogress(try XCTUnwrap(s.jogressCandidates.first)))
    }

    /// 아머 기록도 파트너가 아니다 — 사다리 밖 표시 오버레이일 뿐 졸업이 아니다.
    /// (Angemon 3 은 Shakkoumon 부모이고 아머 결과 id 이기도 하지 않지만, 축 자체를 고정한다.)
    func testArmorRecordDoesNotQualifyAsPartner() async throws {
        var armor = graduatedEntry(base: 356, chain: [336])
        armor.id = "armor-x-336"
        armor.armoredAt = jogressFixedNow
        let s = try await hatched(vmonLine, dex: [armor])
        grow(s, to: 358)

        XCTAssertFalse(s.hasJogressPartnerRecord(336), "아머 기록이 파트너로 인정됐다")
        XCTAssertNil(s.availableJogress)
    }

    /// 게이트는 **호출자의 말이 아니라 도감**을 본다. `hasPartner` 는 뷰의 `.disabled` 용 표시값이라
    /// 손으로 만든 후보가 true 를 들고 오면 기록이 그대로 만들어진다 — 판정 권한은 store 에 있어야 한다.
    /// (후보를 전부 `availableJogress` 에서 뽑는 테스트만으로는 이 구멍이 안 보인다.)
    func testFabricatedCandidateCannotBypassPartnerGate() async throws {
        let s = try await hatched(vmonLine)   // 파트너(336) 기록 없음
        grow(s, to: 358)
        let dexBefore = s.state.dex.count

        let lying = CompanionStore.JogressCandidate(partnerID: 336, resultID: 331, hasPartner: true)
        XCTAssertFalse(s.performJogress(lying), "호출자가 hasPartner 를 참칭해 게이트를 통과했다")
        XCTAssertEqual(s.state.dex.count, dexBefore, "게이트를 막았는데 도감 기록이 남았다")
        XCTAssertFalse(s.hasJogressPartnerRecord(331))
    }

    /// 현재 육성 중인 개체가 도달한 단계는 파트너가 아니다 — `state.ownsSpecies` 를 그대로 쓰면
    /// 한 마리로 양쪽 부모를 동시에 만족시켜 "2마리가 필요하다"는 §3 전제가 무너진다.
    func testActiveMonReachedStagesDoNotQualifyAsPartner() async throws {
        let s = try await hatched(vmonLine)
        grow(s, to: 358)
        XCTAssertTrue(s.state.ownsSpecies(358), "현재 개체는 358 에 도달해 있다(전제)")
        XCTAssertFalse(s.hasJogressPartnerRecord(358), "현재 개체의 도달 단계가 파트너로 인정됐다")
    }

    /// 졸업 체인의 **중간 단계**도 파트너가 된다 — Angemon(3)은 Patamon 라인의 Adult 라
    /// `finalID` 만 보면 Shakkoumon 조합이 영영 막힌다.
    func testMidChainSpeciesQualifiesAsPartner() async throws {
        let s = try await hatched(armadimonLine,
                                  dex: [graduatedEntry(base: 98, chain: [98, 3, 121], rarity: .rare)])
        grow(s, to: 266)
        XCTAssertTrue(s.hasJogressPartnerRecord(3), "졸업 체인 중간 단계가 파트너로 인정되지 않았다")
        XCTAssertEqual(s.availableJogress?.resultID, 387)
    }

    // MARK: ⑧ 후보 목록

    /// 조합이 없는 종에는 후보가 아예 없다 — 뷰가 죽은 컨트롤을 그리지 않게 하는 근거.
    func testNoCandidatesForSpeciesWithoutCombo() async throws {
        let s = try await hatched(vmonLine, dex: [graduatedEntry(base: 356, chain: [356, 336])])
        XCTAssertEqual(s.currentSpeciesID, 349, "V-mon(349)은 죠그레스 부모가 아니다")
        XCTAssertTrue(s.jogressCandidates.isEmpty)
        XCTAssertNil(s.availableJogress)
    }

    /// 알(육성 개체 없음) 상태에서도 후보는 비어 있다.
    func testNoCandidatesWhileEgg() throws {
        let s = try store(vmonLine)
        XCTAssertTrue(s.jogressCandidates.isEmpty)
        XCTAssertNil(s.availableJogress)
    }

    /// 후보 순서는 실행마다 같아야 한다 — `jogressResults` 는 Dictionary 라 순회 순서가 흔들린다.
    func testCandidateOrderIsDeterministic() async throws {
        let s = try await hatched(gabumonLine,
                                  dex: [graduatedEntry(base: 1, chain: [1, 31, 202], rarity: .legendary)])
        grow(s, to: 168)
        let first = s.jogressCandidates.map(\.resultID)
        XCTAssertFalse(first.isEmpty)
        for _ in 0..<20 {
            XCTAssertEqual(s.jogressCandidates.map(\.resultID), first, "후보 순서가 실행마다 달라진다")
        }
    }

    // MARK: ⑨ 영속

    /// 죠그레스 기록은 재시작 후에도 남는다(`save()` 를 불렀는가).
    func testRecordSurvivesRestart() async throws {
        var seed = CompanionState()
        seed.dex = [graduatedEntry(base: 356, chain: [356, 336])]
        seed.language = .ko
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jogress-\(UUID().uuidString).json")
        try JSONEncoder().encode(seed).write(to: url)

        let s = CompanionStore(provider: JogressStubProvider(value: vmonLine),
                               clock: { jogressFixedNow }, fileURL: url, rng: SeededRNG(seed: 7))
        await s.hatch(baseID: vmonLine.baseID)
        grow(s, to: 358)
        XCTAssertTrue(s.performJogress(try XCTUnwrap(s.availableJogress)))

        let reloaded = CompanionStore(provider: JogressStubProvider(value: vmonLine),
                                      clock: { jogressFixedNow }, fileURL: url, rng: SeededRNG(seed: 7))
        XCTAssertTrue(reloaded.hasJogressPartnerRecord(331), "재시작 후 죠그레스 기록이 사라졌다")
    }
}
