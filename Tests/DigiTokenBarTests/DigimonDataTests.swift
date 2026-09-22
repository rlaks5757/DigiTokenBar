import XCTest
@testable import DigiTokenBar

// MARK: - 진화 라인

final class DigimonLineTests: XCTestCase {
    /// 12라인 전부 레벨이 단조 증가하는지 — 원본 데이터가 순환 그래프라(§1) 라인 테이블을
    /// 잘못 옮기면 역행하는 단계가 생길 수 있다. ladderRank 는 armor 에서 nil 이라 여기 섞이지 않는다.
    func testAllLinesHaveMonotonicallyIncreasingLevels() {
        for line in DigimonData.lines {
            let ranks = line.stages.map(\.level.ladderRank)
            XCTAssertTrue(ranks.allSatisfy { $0 != nil }, "정규 라인에 armor 단계가 섞임: \(line.stages.map(\.id))")
            let values = ranks.compactMap { $0 }
            for i in 1..<values.count {
                XCTAssertLessThan(values[i - 1], values[i],
                    "라인 \(line.stages.map(\.id)) 의 단계 \(i-1)→\(i) 가 레벨 역행")
            }
        }
    }

    /// 라인마다 단계 수(k)가 다르다는 전제 — 4로 고정되어 있지 않은지 확인.
    /// 집합 자체를 고정해, contains 단언만으로는 안 걸리는 k=3 라인(가장 많은 5개)의 오변경도 잡는다.
    func testLineLengthsAreNotUniform() {
        let lengths = DigimonData.lines.map(\.totalForms)
        XCTAssertEqual(Set(lengths), [2, 3, 4], "라인 단계 수 분포가 바뀌었다 — k 값 자체를 재확인하라")
        // k=3(가장 많은 5라인: Piyomon·Tentomon·Palmon·Gomamon·Patamon, 전부 Perfect 종료)이 실수로
        // k=2/k=4 로 바뀌어도 위 Set 단언만으로는 안 걸린다 — 개수를 별도로 고정한다.
        XCTAssertEqual(lengths.filter { $0 == 3 }.count, 5, "k=3 라인 개수가 바뀌었다")
    }

    /// Tailmon 라인은 Adult 가 없다 — 작중 설정(Adult 급)으로 임의 승격되지 않았는지 확인.
    func testTailmonLineHasNoAdultStage() {
        XCTAssertFalse(DigimonData.tailmonLine.stages.contains { $0.level == .adult })
        XCTAssertEqual(DigimonData.tailmonLine.stages.first?.level, .child)
    }

    /// 02 파트너 4라인은 정규 사다리가 Adult 에서 끝난다.
    func testPartner02LinesEndAtAdult() {
        for line in [DigimonData.vmonLine, DigimonData.wormmonLine, DigimonData.hawkmonLine, DigimonData.armadimonLine] {
            XCTAssertEqual(line.stages.last?.level, .adult)
        }
    }

    /// GAME-DESIGN.md §2 의 4/4/2/2 수기 배정 — 가격 사다리가 이 분포에 의존한다.
    func testRarityDistributionIs4422() {
        let counts = Dictionary(grouping: DigimonData.lines, by: \.rarity).mapValues(\.count)
        XCTAssertEqual(counts[.common], 4)
        XCTAssertEqual(counts[.uncommon], 4)
        XCTAssertEqual(counts[.rare], 2)
        XCTAssertEqual(counts[.legendary], 2)
        XCTAssertEqual(DigimonData.lines.count, 12)
    }
}

// MARK: - 죠그레스

final class DigimonJogressTests: XCTestCase {
    /// (A,B) 와 (B,A) 가 같은 결과를 주는지 — JogressKey 정규화가 실제로 동작하는지 검증.
    func testJogressLookupIsOrderIndependent() {
        XCTAssertEqual(DigimonData.jogressResult(358, 336), DigimonData.jogressResult(336, 358))
        XCTAssertEqual(DigimonData.jogressResult(358, 336), 331)

        XCTAssertEqual(DigimonData.jogressResult(202, 168), DigimonData.jogressResult(168, 202))
        XCTAssertEqual(DigimonData.jogressResult(202, 168), 183)
    }

    func testAllFiveJogressCombinationsResolve() {
        XCTAssertEqual(DigimonData.jogressResult(83, 267), 390)
        XCTAssertEqual(DigimonData.jogressResult(266, 3), 387)
        XCTAssertEqual(DigimonData.jogressResult(405, 183), 481)
    }

    func testUnknownJogressPairReturnsNil() {
        XCTAssertNil(DigimonData.jogressResult(1, 16))
    }
}

// MARK: - 아머 진화

final class DigimonArmorTests: XCTestCase {
    /// 같은 디지멘탈(성실)이 Child 에 따라 다른 결과를 주는지 — 복합키가 실제로 동작하는지 검증.
    /// 디지멘탈 단독으로는 결과가 결정되지 않는다는 문서 경고를 그대로 테스트한다.
    func testSincerityDigimentalDependsOnChild() {
        let vmonResult = DigimonData.armorResult(childID: 349, digimental: .sincerity)
        let armadimonResult = DigimonData.armorResult(childID: 271, digimental: .sincerity)
        XCTAssertEqual(vmonResult, 298)
        XCTAssertEqual(armadimonResult, 337)
        XCTAssertNotEqual(vmonResult, armadimonResult)
    }

    func testAllNineArmorCombinationsResolve() {
        XCTAssertEqual(DigimonData.armorResult(childID: 349, digimental: .courage), 305)
        XCTAssertEqual(DigimonData.armorResult(childID: 349, digimental: .miracles), 315)
        XCTAssertEqual(DigimonData.armorResult(childID: 399, digimental: .love), 401)
        XCTAssertEqual(DigimonData.armorResult(childID: 399, digimental: .purity), 389)
        XCTAssertEqual(DigimonData.armorResult(childID: 271, digimental: .knowledge), 299)
        XCTAssertEqual(DigimonData.armorResult(childID: 98, digimental: .hope), 363)
        XCTAssertEqual(DigimonData.armorResult(childID: 83, digimental: .light), 326)
    }

    /// 존재하지 않는 (Child, 디지멘탈) 조합은 nil.
    func testUnknownArmorComboReturnsNil() {
        XCTAssertNil(DigimonData.armorResult(childID: 1, digimental: .courage))
    }
}

// MARK: - 이름 매핑

final class DigimonNameTests: XCTestCase {
    /// digi-api 이름과 파일명이 다른 케이스(XV-mon → Xvmon)가 보존되는지.
    func testXVmonNameDivergesFromSpriteStem() {
        let name = DigimonData.name(for: 358)
        XCTAssertEqual(name?.apiName, "XV-mon")
        XCTAssertEqual(name?.spriteStem, "Xvmon")
        XCTAssertNotEqual(name?.apiName.replacingOccurrences(of: "-", with: ""), name?.spriteStem)
        XCTAssertTrue(name?.spriteStemVerified ?? false, "XV-mon 은 §3-3 에서 실측 확인된 케이스")
    }

    /// War Greymon 도 공백 유무로 apiName ≠ spriteStem 인 실측 케이스.
    func testWarGreymonSpriteStemHasNoSpace() {
        let name = DigimonData.name(for: 202)
        XCTAssertEqual(name?.apiName, "War Greymon")
        XCTAssertEqual(name?.spriteStem, "WarGreymon")
        XCTAssertTrue(name?.spriteStemVerified ?? false)
    }

    /// digi-api 에 없는 내부 전용 id 는 Imperialdramon Dragon Mode(900) 하나뿐이어야 한다.
    /// 새 내부 ID 가 추가/누락되면 이 집합이 바뀌므로, 런타임 fetch 호출부가 걸러야 할 대상을
    /// 여기서 고정한다 — 기본값(false)에 조용히 흡수되는 기존 48종은 이 집합에 없어야 한다.
    func testInternalIDsAreExactlyDragonMode() {
        let internalIDs = Set(DigimonData.names.filter(\.value.isInternalID).map(\.key))
        XCTAssertEqual(internalIDs, [900])
    }

    /// 라인·죠그레스(입력+결과)·아머 결과에 등장하는 모든 ID 가 이름 테이블에 있는지 — 참조 누락 방지.
    /// 죠그레스 입력은 `JogressKey.speciesIDs` 로 기계적으로 모은다(수기 보정 없음) — 새 죠그레스 행이
    /// 라인에 없는 입력 ID 를 들고 와도(예: 미래의 Dragon Mode) 이 테스트가 자동으로 잡아낸다.
    func testEveryReferencedSpeciesHasAName() {
        var ids = Set<Int>()
        for line in DigimonData.lines { ids.formUnion(line.stages.map(\.id)) }
        for (key, result) in DigimonData.jogressResults {
            ids.formUnion(key.speciesIDs)
            ids.insert(result)
        }
        for result in DigimonData.armorResults.values { ids.insert(result) }

        for id in ids {
            XCTAssertNotNil(DigimonData.name(for: id), "id \(id) 에 이름 매핑이 없음")
        }
    }
}

// MARK: - 스프라이트 파일명

/// EVOLUTION.md §6 "스프라이트 파일명 전수 검증"(2026-09-21, 48종 전부 Wikimon API 조회) 결과를
/// 데이터 계층에서 검증. 조립 로직(폴백 체인 vs 고정 시리즈)은 `DigimonName.spriteFilenames` 에 있다.
final class DigimonSpriteTests: XCTestCase {
    /// 48종 전부 실측 확인되어 spriteStemVerified 가 항상 true 여야 한다 — 아직 미검증인 항목이
    /// 섞여 있으면 스프라이트 로딩 실패 원인 후보 1순위로 취급해야 하므로 회귀 가드로 남긴다.
    func testAllFortyEightSpeciesAreSpriteStemVerified() {
        // 48종 + Imperialdramon Dragon Mode(900, 내부 ID) = 49.
        XCTAssertEqual(DigimonData.names.count, 49)
        for (id, name) in DigimonData.names {
            XCTAssertTrue(name.spriteStemVerified, "id \(id) 가 아직 spriteStemVerified: false")
        }
    }

    /// 예외 4건은 폴백 없이 실측된 파일명 하나만 정확히 만들어내야 한다.
    func testPinnedSpeciesProduceExactVerifiedFilename() {
        XCTAssertEqual(DigimonData.name(for: 298)?.spriteFilenames, ["Depthmon_vpet_dark_color.png"])
        XCTAssertEqual(DigimonData.name(for: 405)?.spriteFilenames, ["Imperialdramon_fighter_vpet_vb.png"])
        XCTAssertEqual(DigimonData.name(for: 481)?.spriteFilenames, ["Imperialdramon_paladin_vpet_vb.png"])
        XCTAssertEqual(DigimonData.name(for: 900)?.spriteFilenames, ["Imperialdramon_DM_vpet_xloader.png"])
    }

    /// 나머지 45종은 예외 없이 vb > ws > xloader 폴백 체인을 그대로 타야 한다(회귀 방지) —
    /// 전수(45건)로 확인해 표본 누락으로 통과하는 일이 없게 한다.
    func testRemainingFortyFiveSpeciesUseFallbackChain() {
        let pinnedIDs: Set<Int> = [298, 405, 481, 900]
        var checkedCount = 0
        for (id, name) in DigimonData.names where !pinnedIDs.contains(id) {
            XCTAssertNil(name.spriteSeriesPin, "id \(id) 는 폴백 체인을 타야 하는데 spriteSeriesPin 이 있음")
            XCTAssertEqual(name.spriteFilenames, [
                "\(name.spriteStem)_vpet_vb.png",
                "\(name.spriteStem)_vpet_ws.png",
                "\(name.spriteStem)_vpet_xloader.png",
            ], "id \(id) 의 폴백 체인 순서가 vb > ws > xloader 가 아님")
            checkedCount += 1
        }
        XCTAssertEqual(checkedCount, 45)
    }
}
