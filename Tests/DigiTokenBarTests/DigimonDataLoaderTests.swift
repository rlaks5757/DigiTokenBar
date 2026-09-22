import XCTest
@testable import DigiTokenBar

// DigimonDataLoader 무결성 검증 + 진화 트리 조회(DigimonEvolutionTree) 테스트.
// 실제 저장소 파일(Resources/digimon.json)은 절대 수정하지 않는다 — 뮤테이션은 전부
// 메모리상 Data 를 조립해 `DigimonDataLoader.load(from:)` 에 직접 넘긴다.

final class DigimonDataLoaderTests: XCTestCase {

    /// `#filePath` 로 저장소 루트를 거슬러 올라가 실제 Resources/digimon.json 을 찾는다 —
    /// Bundle 의미론을 우회한다(팀 리드 지시 §2-a).
    private func repoDigimonJSONURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DigiTokenBarTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 저장소 루트
            .appendingPathComponent("Resources/digimon.json")
    }

    // MARK: - 실제 파일 로드(회귀 가드 — DigimonData 파사드와 별개로 로더 자체를 검증)

    func testRealResourceFileLoadsAndValidates() throws {
        let ds = try DigimonDataLoader.load(from: repoDigimonJSONURL())
        XCTAssertEqual(ds.names.count, 48)
        XCTAssertEqual(ds.lines.count, 12)
        XCTAssertEqual(ds.jogressResults.count, 5)
        XCTAssertEqual(ds.armorResults.count, 9)
    }

    // MARK: - 최소 유효 데이터셋(뮤테이션 베이스) — 필드 하나만 건드려 실패 모드를 격리한다.

    private func minimalValidJSON() -> [String: Any] {
        [
            "dataVersion": 1,
            "series": ["adventure01"],
            "species": [
                ["id": 1, "apiName": "Agumon", "spriteStem": "Agumon", "spriteStemVerified": true],
                ["id": 34, "apiName": "Greymon", "spriteStem": "Greymon", "spriteStemVerified": true],
            ],
            "lines": [
                ["key": "agumon", "stages": [["id": 1, "level": "child"], ["id": 34, "level": "adult"]], "rarity": "legendary"],
            ],
            "jogress": [] as [[String: Any]],
            "armor": [] as [[String: Any]],
        ]
    }

    private func data(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    func testMinimalValidJSONLoads() throws {
        let ds = try DigimonDataLoader.load(from: try data(minimalValidJSON()))
        XCTAssertEqual(ds.names.count, 2)
        XCTAssertEqual(ds.lines.count, 1)
    }

    // MARK: - 뮤테이션 1: 필수 필드 누락 → throw (trap 아님)

    func testMissingRequiredFieldThrowsDecodingFailed() throws {
        var json = minimalValidJSON()
        // species 원소에서 spriteStem(필수) 제거.
        json["species"] = [
            ["id": 1, "apiName": "Agumon", "spriteStemVerified": true],
            ["id": 34, "apiName": "Greymon", "spriteStem": "Greymon", "spriteStemVerified": true],
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.decodingFailed = error else {
                return XCTFail("decodingFailed 를 기대했지만 \(error) 를 받음")
            }
        }
    }

    // MARK: - 뮤테이션 2: 정규화하면 같아지는 죠그레스 키 중복 → throw

    func testDuplicateNormalizedJogressKeyThrows() throws {
        var json = minimalValidJSON()
        json["species"] = [
            ["id": 1, "apiName": "Agumon", "spriteStem": "Agumon", "spriteStemVerified": true],
            ["id": 34, "apiName": "Greymon", "spriteStem": "Greymon", "spriteStemVerified": true],
            ["id": 999, "apiName": "Result", "spriteStem": "Result", "spriteStemVerified": true],
        ]
        json["jogress"] = [
            ["a": 1, "b": 34, "result": 999],
            ["a": 34, "b": 1, "result": 999],   // 뒤집힌 순서 — 정규화하면 동일 키
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.duplicateJogressKey(let a, let b) = error else {
                return XCTFail("duplicateJogressKey 를 기대했지만 \(error) 를 받음")
            }
            XCTAssertEqual(Set([a, b]), Set([1, 34]))
        }
    }

    // MARK: - 뮤테이션 3: 종별 레벨 충돌 → throw

    func testSpeciesLevelConflictThrows() throws {
        var json = minimalValidJSON()
        // id 1 이 agumon 라인에서는 child, 두 번째 라인에서는 adult 로 등장 → 충돌.
        json["lines"] = [
            ["key": "agumon", "stages": [["id": 1, "level": "child"], ["id": 34, "level": "adult"]], "rarity": "legendary"],
            ["key": "conflict", "stages": [["id": 1, "level": "adult"]], "rarity": "common"],
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.speciesLevelConflict(let id) = error else {
                return XCTFail("speciesLevelConflict 를 기대했지만 \(error) 를 받음")
            }
            XCTAssertEqual(id, 1)
        }
    }

    // MARK: - 추가: 참조 무결성 (라인/죠그레스/아머가 없는 species 를 가리킴)

    func testLineReferencingUnknownSpeciesThrows() throws {
        var json = minimalValidJSON()
        json["lines"] = [
            ["key": "agumon", "stages": [["id": 1, "level": "child"], ["id": 9999, "level": "adult"]], "rarity": "legendary"],
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.unknownSpeciesInLine(let id) = error else {
                return XCTFail("unknownSpeciesInLine 를 기대했지만 \(error) 를 받음")
            }
            XCTAssertEqual(id, 9999)
        }
    }

    func testDuplicateArmorKeyThrows() throws {
        var json = minimalValidJSON()
        json["species"] = [
            ["id": 1, "apiName": "Agumon", "spriteStem": "Agumon", "spriteStemVerified": true],
            ["id": 34, "apiName": "Greymon", "spriteStem": "Greymon", "spriteStemVerified": true],
            ["id": 500, "apiName": "ArmorA", "spriteStem": "ArmorA", "spriteStemVerified": true],
        ]
        json["armor"] = [
            ["childID": 1, "digimental": "courage", "result": 500],
            ["childID": 1, "digimental": "courage", "result": 500],
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.duplicateArmorKey(let childID, let digimental) = error else {
                return XCTFail("duplicateArmorKey 를 기대했지만 \(error) 를 받음")
            }
            XCTAssertEqual(childID, 1)
            XCTAssertEqual(digimental, .courage)
        }
    }

    // MARK: - 순환 감지: 순진한 재귀라면 hang 할 자기참조 간선을 주입해 throw/종료를 확인.

    func testCycleInJogressGraphThrowsInsteadOfHanging() throws {
        var json = minimalValidJSON()
        json["species"] = [
            ["id": 1, "apiName": "A", "spriteStem": "A", "spriteStemVerified": true],
            ["id": 2, "apiName": "B", "spriteStem": "B", "spriteStemVerified": true],
        ]
        json["lines"] = [] as [[String: Any]]
        // 1+2 → 1 로 되돌아오는 자기참조 죠그레스 — 통합 그래프에 순환을 직접 주입.
        json["jogress"] = [
            ["a": 1, "b": 2, "result": 1],
        ]
        XCTAssertThrowsError(try DigimonDataLoader.load(from: try data(json))) { error in
            guard case DigimonDataError.cycleDetected = error else {
                return XCTFail("cycleDetected 를 기대했지만 \(error) 를 받음")
            }
        }
    }
}

// MARK: - 진화 트리 조회 (DigimonEvolutionTree)

final class DigimonEvolutionTreeTests: XCTestCase {

    private func loadedDataset() throws -> DigimonDataset {
        try DigimonData.loaded()
    }

    /// Agumon(1) → Greymon(34) 정규 간선.
    func testNextStagesIncludesNormalEdge() throws {
        let ds = try loadedDataset()
        let edges = ds.nextStages(from: 1)
        XCTAssertTrue(edges.contains { if case .normal(let to) = $0 { return to == 34 } else { return false } })
    }

    /// XV-mon(358) 은 Stingmon(336) 과의 죠그레스로 Paildramon(331) 에 이르는 간선을 갖는다.
    func testNextStagesIncludesJogressEdgeWithPartner() throws {
        let ds = try loadedDataset()
        let edges = ds.nextStages(from: 358)
        let jogress = edges.compactMap { edge -> (Int, Int)? in
            if case .jogress(let partnerID, let to) = edge { return (partnerID, to) }
            return nil
        }
        XCTAssertTrue(jogress.contains { $0 == (336, 331) })
    }

    /// V-mon(349) 은 성실 디지멘탈로 Depthmon(298) 에 이르는 아머 간선을 갖는다.
    func testNextStagesIncludesArmorEdgeWithDigimental() throws {
        let ds = try loadedDataset()
        let edges = ds.nextStages(from: 349)
        let armor = edges.compactMap { edge -> (Digimental, Int)? in
            if case .armor(let digimental, let to) = edge { return (digimental, to) }
            return nil
        }
        XCTAssertTrue(armor.contains { $0 == (.sincerity, 298) })
    }

    /// 405(Imperialdramon FM)는 죠그레스 입력으로만 등장하고 결과로 나오는 간선이 없다
    /// (EVOLUTION.md §3: Paildramon→Dragon Mode→FM 체인에 ID 가 없어 임의로 만들지 않음).
    /// 따라서 331(Paildramon)에서 나가는 간선이 없다 — 이 성질을 그대로 검증한다(데이터 갭 보고용).
    func testPaildramonHasNoOutgoingEdgeToFighterMode() throws {
        let ds = try loadedDataset()
        XCTAssertTrue(ds.nextStages(from: 331).isEmpty)
    }

    /// pathsTo 는 역방향으로 시작 id 까지 경로를 나열한다. Paildramon(331)의 역방향 경로 중 하나는
    /// XV-mon(358) 에서 시작해야 한다.
    func testPathsToIncludesReverseRouteFromXVmon() throws {
        let ds = try loadedDataset()
        let paths = ds.pathsTo(331)
        // 죠그레스는 두 부모 각각 별도 경로로 나온다(양쪽 다 필요하다는 건 [[Int]] 로 표현 못함) —
        // V-mon 라인 경로(349 → 358 → 331)에 358 이 포함되는지로 확인한다.
        XCTAssertTrue(paths.contains { $0.contains(358) && $0.last == 331 })
    }

    /// 도감에 Agumon 라인 전체(1,34,169,202) + Gabumon 라인 전체(16,33,205,168)가 있으면
    /// War Greymon + Metal Garurumon 죠그레스로 Omegamon(183)에 도달 가능해야 한다.
    func testIsReachableAllowsJogressWhenBothParentsInDex() throws {
        let ds = try loadedDataset()
        let dex: Set<Int> = [1, 34, 169, 202, 16, 33, 205, 168]
        XCTAssertTrue(ds.isReachable(183, dex: dex))
    }

    /// 파트너가 도감에 없으면 죠그레스 간선을 타지 못한다 — War Greymon 만 있고
    /// Metal Garurumon 이 없으면 Omegamon 은 도달 불가.
    func testIsReachableBlocksJogressWithoutPartner() throws {
        let ds = try loadedDataset()
        let dex: Set<Int> = [1, 34, 169, 202]
        XCTAssertFalse(ds.isReachable(183, dex: dex))
    }

    /// 481(Paladin Mode)은 다단 죠그레스 결과다: War Greymon+Metal Garurumon → Omegamon(183),
    /// 그리고 Omegamon 이 다시 405(Imperialdramon FM)와의 죠그레스 파트너가 되어야 도달한다.
    /// **데이터 갭**: 405 는 정규 라인·죠그레스·아머 어느 결과에도 없어(§3) dex 에 직접 넣는 것
    /// 외에는 405 를 얻을 방법이 없다 — 이 테스트는 그 갭을 있는 그대로 문서화한다.
    func testIsReachablePaladinModeRequiresFighterModeDirectlyInDex() throws {
        let ds = try loadedDataset()
        // 405 를 뺀 dex: Omegamon 체인만으로는 도달 불가(데이터 갭).
        let dexWithoutFighterMode: Set<Int> = [1, 34, 169, 202, 16, 33, 205, 168]
        XCTAssertFalse(ds.isReachable(481, dex: dexWithoutFighterMode))

        // 405 를 직접 넣으면(현재 데이터가 표현 가능한 유일한 방법) 다단 죠그레스가 고정점으로 뚫린다.
        let dexWithFighterMode = dexWithoutFighterMode.union([405])
        XCTAssertTrue(ds.isReachable(481, dex: dexWithFighterMode))
    }
}
