import XCTest
@testable import DigiTokenBar

// 팝오버 내비게이션 리셋 계약 — 닫혔다 열릴 때 AppDelegate.togglePopover 가 reset()을 불러
// 항상 Home 으로 돌아가게 한다(설정 화면 잔류 방지).
@MainActor
final class PopoverNavigationTests: XCTestCase {
    func testDefaultsToHome() {
        let nav = PopoverNavigation()
        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .home)
        XCTAssertFalse(nav.showingCollectionLog)
    }

    func testResetReturnsToHomeFromSettings() {
        let nav = PopoverNavigation()
        nav.showSettings = true
        nav.tab = .collection
        nav.showingCollectionLog = true
        nav.reset()
        XCTAssertFalse(nav.showSettings)   // 설정 화면 닫힘
        XCTAssertEqual(nav.tab, .home)     // 탭도 Home 으로
        XCTAssertTrue(nav.showingCollectionLog, "일반 재진입은 사용자가 보던 컬렉션 세그먼트를 유지")
    }

    func testOpenRepresentativeDexLeavesSettingsForCollection() {
        let nav = PopoverNavigation()
        nav.showSettings = true
        nav.showingCollectionLog = true

        nav.openRepresentativeDex()

        XCTAssertFalse(nav.showSettings)
        XCTAssertEqual(nav.tab, .collection)
        XCTAssertFalse(nav.showingCollectionLog, "동행 기록에서 설정을 열었어도 대표 선택은 도감으로 이동")
    }

    /// #301: Hide is a right-click. Show has to live on the popover footer, bound to the same
    /// `floatingPetEnabled` the Settings checkbox already uses. Removing the button must fail this.
    func testPopoverFooterTogglesFloatingPetWithoutOpeningSettings() throws {
        let source = try String(contentsOf: Self.popoverSource, encoding: .utf8)
        let footer = try XCTUnwrap(source.range(of: "private var footer"))
        let body = String(source[footer.lowerBound...])
        XCTAssertTrue(
            body.contains("store.floatingPetEnabled.toggle()"),
            "footer must flip floatingPetEnabled — Hide already does; Show had only Settings")
        XCTAssertTrue(body.contains("l.floatingPetHideLabel"))
        XCTAssertTrue(body.contains("l.floatingPetEnableLabel"))
        XCTAssertFalse(
            body.contains("nav.showSettings = true\n            }\n            .buttonStyle(.borderless)\n            .help(l.floatingPet"),
            "the pet control must not be a second door into Settings")
    }

    private static let popoverSource: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DigiTokenBar/UI/PopoverView.swift")
    }()
}

final class RepresentativeLocalizationTests: XCTestCase {
    func testGermanSettingsLabelsIncludeLatestMainStrings() {
        let l = L(.de)

        XCTAssertEqual(l.todayTokensShort, "Heutige Tokens")
        XCTAssertEqual(l.todayCost, "Heutige Kosten ($)")
        XCTAssertEqual(l.limitPercent, "Limit %")
    }

    /// 대표 디지몬은 메뉴바와 플로팅 펫에 함께 쓰이는 독립 개념이다. 모든 언어가 pet 전용 표현으로
    /// 되돌아가거나 스페인어 추가 뒤 한 언어만 빠지지 않도록 사용자가 보는 핵심 액션을 고정한다.
    func testRepresentativeActionsAreLocalizedInEverySupportedLanguage() {
        let expected: [(AppLanguage, label: String, follow: String, choose: String, set: String)] = [
            (.ko, "대표 디지몬", "현재 디지몬 따라가기", "도감에서 선택…", "대표로 설정"),
            (.en, "Representative Digimon", "Follow current companion", "Choose in Digidex…",
             "Set as representative"),
            (.ja, "代表デジモン", "現在のデジモンに合わせる", "図鑑で選ぶ…", "代表デジモンに設定"),
            (.es, "Digimon representativo", "Seguir al compañero actual", "Elegir en la Digidex…",
             "Establecer como representante"),
            (.fr, "Digimon représentatif", "Suivre le compagnon actuel", "Choisir dans le Digidex…",
             "Définir comme représentatif"),
            (.pt, "Digimon representativo", "Seguir o companheiro atual", "Escolher na Digidex…",
             "Definir como representante"),
            (.de, "Repräsentatives Digimon", "Aktuellem Begleiter folgen", "Im Digidex auswählen…",
             "Als repräsentativ festlegen"),
        ]

        XCTAssertEqual(expected.map(\.0), AppLanguage.allCases)
        for item in expected {
            let l = L(item.0)
            XCTAssertEqual(l.representativeDigimonLabel, item.label)
            XCTAssertEqual(l.representativeFollowCurrent, item.follow)
            XCTAssertEqual(l.representativeChooseFromDex, item.choose)
            XCTAssertEqual(l.representativeSet, item.set)
            XCTAssertFalse(l.representativeBadge.isEmpty)
        }
    }
}
