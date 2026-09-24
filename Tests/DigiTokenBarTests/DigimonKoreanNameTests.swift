import XCTest
@testable import DigiTokenBar

/// 종 이름 한국어 표기 — 번들 데이터(`digimon.json` 의 `species[].names`)와 그걸 읽는
/// 표시 경로를 함께 고정한다.
///
/// 이 스위트가 지키는 것은 "ko 키가 있다" 가 아니라 **어떤 id 가 어떤 표기를 갖는가** 다.
/// 개수 단언(`count >= 1`)이나 키 존재 단언은 영문을 복붙해도, 표기를 통째로 뒤바꿔도 통과한다.
@MainActor
final class DigimonKoreanNameTests: XCTestCase {

    /// ko 표기를 갖는 52종 전체 분포. 한 줄이라도 바뀌면 여기서 드러난다.
    /// 영문 폴백으로 남은 종은 없다 — 52종 전부 여기 있어야 한다.
    private static let expected: [Int: String] = [
        1: "아구몬",
        3: "엔젤몬",
        5: "버드라몬",
        16: "파피몬",
        33: "가루몬",
        34: "그레이몬",
        35: "캅테리몬",
        38: "엔젤우몬",
        40: "아트라캅테리몬(청)",
        81: "팔몬",
        83: "가트몬",
        85: "텐토몬",
        96: "쥬드몬",
        98: "파닥몬",
        101: "피요몬",
        117: "쉬라몬",
        121: "홀리엔젤몬",
        123: "홀리드라몬",
        124: "원뿔몬",
        165: "가루다몬",
        166: "릴리몬",
        168: "메탈가루몬",
        169: "메탈그레이몬",
        183: "오메가몬",
        195: "니드몬",
        202: "워그레이몬",
        205: "워가루몬",
        266: "안킬로몬",
        267: "아큐라몬",
        271: "아르마몬",
        298: "마린몬",   // 아머체
        299: "디그몬",   // 아머체
        305: "화염드라몬",   // 아머체
        312: "라이드라몬",   // 아머체
        315: "매그너몬",   // 아머체
        326: "네페르티몬",   // 아머체
        331: "파일드라몬",
        336: "스팅몬",
        337: "잠수몬",   // 아머체
        349: "브이몬",
        356: "추추몬",
        358: "엑스브이몬",
        363: "페가수스몬",   // 아머체
        384: "세라피몬",
        387: "토우몬",
        389: "수리몬",   // 아머체
        390: "실피드몬",
        399: "호크몬",
        401: "호루스몬",   // 아머체
        405: "황제드라몬: 파이터 모드",
        481: "황제드라몬: 팔라딘 모드",
        900: "황제드라몬: 드래곤 모드",
    ]

    /// 아머 10종 — 이번 요청의 직접 대상이라 별도로 다시 고정한다(사다리 라인 밖이라
    /// 라인 경유 경로가 절대 채워주지 않는 종들이다).
    private static let armorIDs = [298, 299, 305, 312, 315, 326, 337, 363, 389, 401]

    // MARK: 데이터

    /// 분포 전체 일치 — 구성원 교체·표기 변경 양쪽을 잡는다.
    func testEverySpeciesHasTheExpectedKoreanName() {
        XCTAssertEqual(DigimonData.names.count, Self.expected.count, "종 수가 기대 분포와 다르다")
        for (id, name) in Self.expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(DigimonData.name(for: id)?.localeNames["ko"], name, "id \(id) 의 ko 표기")
        }
    }

    /// 영문 복붙 방지 — ko 는 apiName 과 달라야 한다. 이게 없으면 `["ko": apiName]` 로도
    /// 위 분포 테스트를 통과시킬 수 있다(기대값만 같이 고치면 되므로).
    func testKoreanNamesAreNotTheEnglishName() {
        for (id, name) in DigimonData.names {
            let ko = name.localeNames["ko"]
            XCTAssertNotNil(ko, "id \(id) 에 ko 표기가 없다")
            XCTAssertNotEqual(ko, name.apiName, "id \(id) 의 ko 가 영문 그대로다")
        }
    }

    /// 아머 10종도 빠짐없이 — 사다리 밖 종이라 다른 경로로는 커버되지 않는다.
    func testArmorSpeciesAreLocalized() {
        for id in Self.armorIDs {
            guard let name = DigimonData.name(for: id) else { return XCTFail("아머체 \(id) 가 데이터에 없다") }
            XCTAssertEqual(name.localeNames["ko"], Self.expected[id], "아머체 \(id)")
            XCTAssertNotEqual(name.localeNames["ko"], name.apiName)
        }
    }

    /// `digimon.json` 과 `digimon_details.json` 이 같은 이름을 말해야 한다 — 두 군데로 갈라지면
    /// 상세 패널과 도감 칸이 같은 종을 다르게 부른다.
    func testKoreanNamesMatchTheDetailsSource() throws {
        let details = try DigimonData.loadedDetails()
        for (id, name) in DigimonData.names {
            // 한쪽 출처에서만 표기가 바뀌거나 행이 사라지면 여기서 갈라진다.
            XCTAssertEqual(details.byID[id]?.nameKo, name.localeNames["ko"], "id \(id) 의 두 출처가 갈라졌다")
        }
    }

    // MARK: 로케일 해석

    /// ko 화면은 한국어. 영문 폴백이 이기면 안 된다.
    func testKoreanLocaleResolvesKoreanNames() {
        for (id, expected) in Self.expected {
            let names = DigimonData.name(for: id)!.localizedNames
            XCTAssertEqual(AppLanguage.ko.resolveName(names), expected, "id \(id)")
        }
    }

    /// 영문 화면은 apiName. ko 를 넣었다고 영어가 한국어로 오염되면 안 된다.
    func testEnglishLocaleStillResolvesTheApiName() {
        for (id, name) in DigimonData.names {
            XCTAssertEqual(AppLanguage.en.resolveName(name.localizedNames), name.apiName, "id \(id)")
        }
    }

    /// **ko 데이터가 없는 언어는 영어로 폴백한다 — `#305` 가 아니다.**
    /// 조용히 회귀하는 자리라 언어별로 전수 단언한다. `en` 을 JSON 이 아니라 `apiName` 에서
    /// 합성하는 설계가 지켜지는지를 재는 것이기도 하다.
    func testLocalesWithoutDataFallBackToEnglishNotSpeciesNumber() {
        for language in [AppLanguage.ja, .es, .fr, .pt, .de] {
            for (id, name) in DigimonData.names {
                let resolved = language.resolveName(name.localizedNames)
                XCTAssertEqual(resolved, name.apiName, "\(language.rawValue) / id \(id) 가 영어로 폴백하지 않았다")
                XCTAssertNotEqual(resolved, "#\(id)")
            }
        }
    }

    /// **데이터에 `en` 이 흘러들어도 `apiName` 이 이긴다.** `localeNames` 문서는 "en 은 여기
    /// 담지 않는다" 를 계약으로 두는데, 그걸 어긴 데이터가 표시까지 도달하면 같은 영어 표기가
    /// 두 벌이 되어 한쪽만 고쳐질 때 갈라진다 — 주석이 금지하는 바로 그 상황이다. 현재 52종엔
    /// `en` 이 없어서 다른 테스트로는 이 우선순위가 전혀 지켜지지 않는다.
    func testStrayEnglishInDataLosesToTheApiName() {
        let name = DigimonName(apiName: "Agumon", spriteStem: "Agumon", spriteStemVerified: true,
                               localeNames: ["ko": "아구몬", "en": "WRONG"])
        XCTAssertEqual(name.localizedNames["en"], "Agumon", "데이터의 en 이 apiName 을 이겼다")
        XCTAssertEqual(AppLanguage.en.resolveName(name.localizedNames), "Agumon")
        XCTAssertEqual(AppLanguage.ko.resolveName(name.localizedNames), "아구몬", "ko 는 그대로")
    }

    /// 로케일 필드가 통째로 없는 구버전 JSON 도 디코딩되고 영어로 뜬다(하위호환).
    func testSpeciesWithoutLocaleNamesDecodeAndFallBackToEnglish() throws {
        let json: [String: Any] = [
            "dataVersion": 1,
            "series": ["adventure01"],
            "species": [["id": 1, "apiName": "Agumon", "spriteStem": "Agumon", "spriteStemVerified": true]],
            "lines": [["key": "agumon", "stages": [["id": 1, "level": "child"]], "rarity": "common"]],
            "jogress": [] as [[String: Any]],
            "armor": [] as [[String: Any]],
        ]
        let ds = try DigimonDataLoader.load(from: try JSONSerialization.data(withJSONObject: json))
        let name = try XCTUnwrap(ds.names[1])
        XCTAssertTrue(name.localeNames.isEmpty)
        XCTAssertEqual(AppLanguage.ko.resolveName(name.localizedNames), "Agumon", "표기 없으면 영어")
    }
}
