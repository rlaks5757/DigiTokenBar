import XCTest
@testable import DigiTokenBar

// DigimonDetailsLoader 무결성 검증 + Resources/digimon_details.json 실데이터 가드.
// 실제 저장소 파일은 절대 수정하지 않는다 — 뮤테이션은 전부 메모리상 Data 를 조립해
// `DigimonDetailsLoader.load(from:)` 에 직접 넘긴다(DigimonDataLoaderTests 와 같은 방식).

final class DigimonDetailsLoaderTests: XCTestCase {

    /// `#filePath` 로 저장소 루트를 거슬러 올라가 실제 리소스를 찾는다 — Bundle 의미론을 우회한다.
    private func repoURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DigiTokenBarTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 저장소 루트
            .appendingPathComponent(relative)
    }

    private func loadReal() throws -> DigimonDetailsDataset {
        try DigimonDetailsLoader.load(from: repoURL("Resources/digimon_details.json"))
    }

    // MARK: - 실데이터 가드

    func testRealResourceFileLoadsAllSpecies() throws {
        let ds = try loadReal()
        XCTAssertEqual(ds.byID.count, 52)
    }

    /// **집합 비교**다 — 개수만 세면 한 종이 빠지고 다른 종이 들어와도 통과한다.
    func testIDSetMatchesDigimonJSONExactly() throws {
        let details = try loadReal()
        let species = try DigimonDataLoader.load(from: repoURL("Resources/digimon.json"))
        XCTAssertEqual(Set(details.byID.keys), Set(species.names.keys))
    }

    func testEveryEntryHasNonEmptyLevelAttributeAndSummary() throws {
        let ds = try loadReal()
        for (id, detail) in ds.byID {
            // attribute·level 은 enum 이라 값이 존재하는 것만으로 유효하다(미지의 표기는 디코딩 실패).
            XCTAssertTrue(DigimonLore.Attribute.allCases.contains(detail.attribute), "id \(id) attribute")
            XCTAssertTrue(DigiLevel.allCases.contains(detail.level), "id \(id) level")
            XCTAssertFalse(detail.type.trimmingCharacters(in: .whitespaces).isEmpty, "id \(id) type")
            let summary = detail.summaryKo ?? ""
            XCTAssertFalse(summary.trimmingCharacters(in: .whitespaces).isEmpty, "id \(id) summaryKo")
        }
    }

    /// 속성 분포를 실제 데이터로 고정. 개수만으로는 구성원 교체를 못 잡으므로 **id 집합까지** 고정한다.
    func testAttributeDistributionMatchesActualData() throws {
        let ds = try loadReal()
        var byAttribute: [DigimonLore.Attribute: Set<Int>] = [:]
        for (id, detail) in ds.byID {
            byAttribute[detail.attribute, default: []].insert(id)
        }
        XCTAssertEqual(Set(byAttribute.keys), [.free, .vaccine, .data],
                       "virus 종은 어드벤처 01/02 파트너 범위에 없다")
        XCTAssertEqual(byAttribute[.free]?.count, 23)
        XCTAssertEqual(byAttribute[.vaccine]?.count, 22)
        XCTAssertEqual(byAttribute[.data]?.count, 7)
        XCTAssertNil(byAttribute[.virus])

        // 구성원 고정 — 표본이 작고 변화가 드문 data 7종은 id 집합 자체를 박아둔다.
        XCTAssertEqual(byAttribute[.data], [16, 40, 81, 98, 166, 168, 195])
    }

    /// 레벨 분포도 실제 데이터로 고정 + armor 10종은 id 집합까지 고정한다.
    func testLevelDistributionMatchesActualData() throws {
        let ds = try loadReal()
        var byLevel: [DigiLevel: Set<Int>] = [:]
        for (id, detail) in ds.byID {
            byLevel[detail.level, default: []].insert(id)
        }
        XCTAssertEqual(byLevel[.adult]?.count, 12)
        XCTAssertEqual(byLevel[.child]?.count, 11)
        XCTAssertEqual(byLevel[.perfect]?.count, 11)
        XCTAssertEqual(byLevel[.armor]?.count, 10)
        XCTAssertEqual(byLevel[.ultimate]?.count, 8)
        // babyI/babyII 는 이 데이터 범위 밖이다.
        XCTAssertNil(byLevel[.babyI])
        XCTAssertNil(byLevel[.babyII])
    }

    /// 아머 진화로만 도달하는 10종이 실제로 armor 레벨을 갖는지 — id 집합으로 고정한다.
    /// `digimon.json` 의 armor 테이블 결과 id 와 교차 검증해 두 파일이 따로 놀지 않게 막는다.
    func testArmorSpeciesHaveArmorLevel() throws {
        let details = try loadReal()
        let species = try DigimonDataLoader.load(from: repoURL("Resources/digimon.json"))
        let armorResultIDs = Set(species.armorResults.values)
        XCTAssertEqual(armorResultIDs.count, 10)
        for id in armorResultIDs {
            XCTAssertEqual(details.byID[id]?.level, .armor, "armor 결과 id \(id) 가 armor 레벨이 아니다")
        }
        let armorLeveled = Set(details.byID.filter { $0.value.level == .armor }.keys)
        XCTAssertEqual(armorLeveled, armorResultIDs)
    }

    func testKoreanNameIsPresentOnlyForLocalizedSpecies() throws {
        let ds = try loadReal()
        let withKo = Set(ds.byID.filter { $0.value.nameKo != nil }.keys)
        XCTAssertEqual(withKo.count, 23)
        XCTAssertEqual(ds.byID[1]?.nameKo, "아구몬")
        // 정발명이 확인되지 않은 종은 키 자체가 없어야 한다(빈 문자열/null 금지).
        XCTAssertNil(ds.byID[3]?.nameKo)
        // 위키 원문에는 백신종/바이러스종 구분자가 붙어 있지만("메탈그레이몬(백신종)"), 이 52종에
        // 바이러스종이 없어 구분할 대상이 없다 — 한국어 화면에만 괄호가 붙는 것을 막는 가드.
        XCTAssertEqual(ds.byID[169]?.nameKo, "메탈그레이몬")
        // 반대로 황제드라몬 3형태는 실제로 별개 종 행이라 모드 접미사를 유지해야 한다.
        XCTAssertEqual(ds.byID[405]?.nameKo, "황제드라몬: 파이터 모드")
        XCTAssertEqual(ds.byID[481]?.nameKo, "황제드라몬: 팔라딘 모드")
        XCTAssertEqual(ds.byID[900]?.nameKo, "황제드라몬: 드래곤 모드")
        // 마크업 잔재(따옴표·대괄호·중괄호·구분선)가 이름에 새어 들어오지 않았는지.
        for (id, detail) in ds.byID {
            guard let ko = detail.nameKo else { continue }
            for marker in ["'", "\"", "[", "]", "{", "}", "|", "—"] {
                XCTAssertFalse(ko.contains(marker), "id \(id) nameKo '\(ko)' 에 마크업 잔재")
            }
        }
        for (id, detail) in ds.byID {
            if let ko = detail.nameKo {
                XCTAssertFalse(ko.isEmpty, "id \(id) nameKo 가 빈 문자열")
            }
        }
    }

    func testEverySpeciesHasTwoAttacksWithJapaneseAndRomaji() throws {
        let ds = try loadReal()
        for (id, detail) in ds.byID {
            XCTAssertEqual(detail.attacks.count, 2, "id \(id) 필살기 개수")
            for attack in detail.attacks {
                XCTAssertFalse(attack.nameJa.isEmpty, "id \(id) nameJa")
                XCTAssertFalse(attack.romaji.isEmpty, "id \(id) romaji")
                XCTAssertFalse(attack.nameKoTranslit?.isEmpty ?? true, "id \(id) nameKoTranslit")
            }
        }
    }

    /// 104개 필살기 전부 한국어 음차가 있고, 그 안에 가나·한자가 새어 들어오지 않았는지 —
    /// (일본어 원문을 그대로 복사해 넣는 실수는 이 검사가 잡는다). 부정 검사(가나·한자 없음)만으로는
    /// romaji 를 그대로 복사해도 통과하므로(둘 다 ASCII 라틴 문자), 한글이 최소 1자 있다는 긍정
    /// 검사를 더한다.
    func testEveryAttackHasKoreanTransliterationWithoutKanaLeakage() throws {
        let ds = try loadReal()
        let kanaOrCJK: ClosedRange<UInt32> = 0x3040...0x30FF
        let cjk: ClosedRange<UInt32> = 0x4E00...0x9FFF
        let hangul: ClosedRange<UInt32> = 0xAC00...0xD7A3   // 완성형 음절
        for (id, detail) in ds.byID {
            for (index, attack) in detail.attacks.enumerated() {
                guard let translit = attack.nameKoTranslit else {
                    XCTFail("id \(id) attacks[\(index)] nameKoTranslit 없음")
                    continue
                }
                XCTAssertFalse(translit.trimmingCharacters(in: .whitespaces).isEmpty,
                               "id \(id) attacks[\(index)] nameKoTranslit 비어 있음")
                for scalar in translit.unicodeScalars {
                    XCTAssertFalse(kanaOrCJK.contains(scalar.value) || cjk.contains(scalar.value),
                                   "id \(id) attacks[\(index)] nameKoTranslit '\(translit)' 에 가나/한자 잔존")
                }
                XCTAssertTrue(translit.unicodeScalars.contains { hangul.contains($0.value) },
                              "id \(id) attacks[\(index)] nameKoTranslit '\(translit)' 에 한글이 없다 — romaji 복사 의심")
            }
        }
    }

    /// 음차 내용을 실제 값으로 고정 — 가타카나(영어 외래어) 두 건, 히라가나/한자(의미 번역·고유명사)
    /// 네 건. 개수만 세면 전부 일본어를 그대로 복사해도 통과하므로 내용을 못 잡는다.
    func testKoreanTransliterationContentForKnownAttacks() throws {
        let ds = try loadReal()
        func translit(_ id: Int, _ nameJa: String) -> String? {
            ds.byID[id]?.attacks.first { $0.nameJa == nameJa }?.nameKoTranslit
        }
        XCTAssertEqual(translit(101, "マジカルファイアー"), "마지컬 파이어")
        XCTAssertEqual(translit(1, "ベビーフレイム"), "베이비 플레임")
        // 히라가나 — 의미 번역(고유명사 아님).
        XCTAssertEqual(translit(33, "たいあたり"), "몸통박치기")
        XCTAssertEqual(translit(98, "はねビンタ"), "날개 따귀")
        XCTAssertEqual(translit(117, "するどいツメ"), "날카로운 발톱")
        // id 389: 원본 데이터가 「紅葉」로 잘려 있던 것을 Wikimon 원문(紅葉おろし)으로 복원했다.
        XCTAssertEqual(ds.byID[389]?.attacks.first?.nameJa, "紅葉おろし")
        XCTAssertEqual(translit(389, "紅葉おろし"), "모미지 오로시")
        // 한자 고유명사 — 음차가 맞다(쿠사나기 = 일본 신화의 검).
        XCTAssertEqual(translit(389, "草薙"), "쿠사나기")
    }

    /// CC BY-SA 3.0 출처 표기는 라이선스 의무다 — 리팩터링이 조용히 떨어뜨리지 못하게 고정한다.
    func testSourceAndLicenseAreCarried() throws {
        let ds = try loadReal()
        XCTAssertEqual(ds.source, "wikimon.net")
        XCTAssertEqual(ds.license, "CC BY-SA 3.0")
    }

    /// 상세 패널이 실제로 쓰는 주입 경로(`DigimonDetailsBundleSource` → `DigimonData.lore(for:)`)가
    /// 이 데이터에 닿는지. 로더 단독 통과 + 조회 실패 조합을 막는 통합 가드다.
    func testLoreSourceResolvesRealSpecies() {
        let bundle = DigimonDetailsBundleSource()
        let lore = bundle.lore(speciesID: 1)
        XCTAssertNotNil(lore)
        XCTAssertEqual(lore?.level, .child)
        XCTAssertEqual(lore?.attribute, .vaccine)
        XCTAssertFalse(lore?.summaryKo?.isEmpty ?? true)
        // 데이터에 없는 id 는 즉시 nil — 상세 패널이 "정보 없음" 을 그릴 수 있어야 한다.
        XCTAssertNil(bundle.lore(speciesID: 999_999))
    }

    /// 데이터 표기가 대소문자 어느 쪽이어도 같은 속성으로 디코딩되는지 — `DigimonAttribute` 의
    /// 대소문자 무시 `init(from:)` 이 사라지면 여기서 잡힌다.
    func testAttributeDecodingIgnoresCase() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attribute"] = "Vaccine"
        json["details"] = details
        let ds = try DigimonDetailsLoader.load(from: try data(json))
        XCTAssertEqual(ds.byID[1]?.attribute, .vaccine)
    }

    func testUnknownAttributeThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attribute"] = "Unknown"
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .unknownAttribute(id: 1, value: "Unknown"))
        }
    }

    // MARK: - 최소 유효 데이터셋(뮤테이션 베이스)

    private func minimalValidJSON() -> [String: Any] {
        [
            "_source": "wikimon.net",
            "_license": "CC BY-SA 3.0",
            "details": [
                [
                    "id": 1,
                    "level": "child",
                    "attribute": "vaccine",
                    "type": "Reptile",
                    "nameKo": "아구몬",
                    "attacks": [["nameJa": "ベビーフレイム", "romaji": "Bebī Fureimu", "nameKoTranslit": "베이비 플레임"]],
                    "summaryKo": "작은 공룡 모습의 파충류형 디지몬.",
                ],
            ],
        ]
    }

    private func data(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    func testMinimalValidJSONLoads() throws {
        let ds = try DigimonDetailsLoader.load(from: try data(minimalValidJSON()))
        XCTAssertEqual(ds.byID.count, 1)
        XCTAssertEqual(ds.byID[1]?.type, "Reptile")
    }

    /// nameKo 키가 없으면 nil — null 이 아니라 키 생략이 이 스키마의 "없음" 표현이다.
    func testMissingKoreanNameDecodesAsNil() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0].removeValue(forKey: "nameKo")
        json["details"] = details
        let ds = try DigimonDetailsLoader.load(from: try data(json))
        XCTAssertNil(ds.byID[1]?.nameKo)
    }

    func testUnknownLevelThrowsInsteadOfDefaulting() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["level"] = "Child"   // 대문자 — DigiLevel rawValue 는 소문자다.
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            guard let error = error as? DigimonDetailsError,
                  case .decodingFailed = error else {
                return XCTFail("decodingFailed 가 아니라 \(error)")
            }
        }
    }

    func testMissingRequiredFieldThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0].removeValue(forKey: "summaryKo")
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json)))
    }

    func testEmptySummaryThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["summaryKo"] = "   "
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .emptyField(id: 1, field: "summaryKo"))
        }
    }

    /// attacks 가 빈 배열이면 통과해선 안 된다 — type/summaryKo 와 같은 필수 필드 계약.
    func testEmptyAttacksThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attacks"] = []
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .emptyField(id: 1, field: "attacks"))
        }
    }

    /// 필살기 하나라도 nameJa 가 빈 문자열이면 통과해선 안 된다.
    func testEmptyAttackNameJaThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attacks"] = [["nameJa": "  ", "romaji": "Bebī Fureimu", "nameKoTranslit": "베이비 플레임"]]
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .emptyField(id: 1, field: "attacks[0].nameJa"))
        }
    }

    /// 필살기 하나라도 romaji 가 빈 문자열이면 통과해선 안 된다.
    func testEmptyAttackRomajiThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attacks"] = [["nameJa": "ベビーフレイム", "romaji": "", "nameKoTranslit": "베이비 플레임"]]
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .emptyField(id: 1, field: "attacks[0].romaji"))
        }
    }

    /// 필살기 하나라도 nameKoTranslit 이 빈 문자열이면 통과해선 안 된다 — nameJa/romaji 와 같은 계약.
    func testEmptyAttackNameKoTranslitThrows() throws {
        var json = minimalValidJSON()
        var details = json["details"] as! [[String: Any]]
        details[0]["attacks"] = [["nameJa": "ベビーフレイム", "romaji": "Bebī Fureimu", "nameKoTranslit": "  "]]
        json["details"] = details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError,
                           .emptyField(id: 1, field: "attacks[0].nameKoTranslit"))
        }
    }

    /// 배열 스키마를 쓰는 이유의 회귀 가드 — 맵이었다면 중복이 조용히 덮여 검출 자체가 불가능하다.
    func testDuplicateSpeciesIDThrows() throws {
        var json = minimalValidJSON()
        let details = json["details"] as! [[String: Any]]
        json["details"] = details + details
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json))) { error in
            XCTAssertEqual(error as? DigimonDetailsError, .duplicateSpecies(id: 1))
        }
    }

    func testMissingLicenseFieldThrows() throws {
        var json = minimalValidJSON()
        json.removeValue(forKey: "_license")
        XCTAssertThrowsError(try DigimonDetailsLoader.load(from: try data(json)))
    }
}
