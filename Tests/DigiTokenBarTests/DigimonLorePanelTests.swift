import XCTest
@testable import DigiTokenBar

/// 도감 상세 패널의 설정 정보 조회. **뷰가 아니라 store 함수를 단언한다** — 패널이 무한 스피너에
/// 갇혔던 원인은 렌더링이 아니라 "조회가 아무 결과도 내놓지 않는" 것이었고, 결과가 항상 두 케이스
/// 중 하나로 끝난다는 성질은 뷰 없이 검증 가능해야 한다.
///
/// 데이터는 전부 주입 스텁이다 — 번들 파일을 읽지 않는다. 번들을 읽으면 데이터 계층이 아직 연결되지
/// 않은 동안 모든 종이 `.missing` 이라 루프가 아무것도 단언하지 않는 채 green 이 된다(공허한 테스트).
final class DigimonLorePanelTests: XCTestCase {

    // MARK: 조회 결과는 항상 found 아니면 missing — 미해결 상태가 없다

    /// 이번 버그의 회귀 가드. 데이터에 없는 종은 **로딩도 실패도 아닌** `.missing` 으로 즉시 끝나야
    /// 한다. 조회가 조용히 아무것도 안 하면 패널이 영원히 스피너에 남는다.
    @MainActor
    func testUnknownSpeciesResolvesToMissingRatherThanStayingUnresolved() throws {
        let store = try makeStore(lore: EmptyDigimonLoreSource())
        XCTAssertEqual(store.digimonLore(speciesID: 1), .missing)
        // 같은 id 를 다시 물어도 상태가 쌓이지 않는다 — 재시도 대기열도, 로딩 집합도 없다.
        XCTAssertEqual(store.digimonLore(speciesID: 1), .missing)
        XCTAssertTrue(store.loadingDigimonDetailIDs.isEmpty)
    }

    /// 빈 출처를 주입해도 미해결 상태(스피너)에 머물지 않고 `.missing` 으로 즉시 끝나야 한다.
    /// `CompanionStore` 의 기본값은 이제 `DigimonDetailsBundleSource()` 라(프로덕션과 동일),
    /// speciesID 1(아구몬)은 번들에 실제로 있어 기본값으로는 이 케이스를 만들 수 없다 — 그래서
    /// `EmptyDigimonLoreSource()` 를 여기서 명시적으로 주입해 "빈 출처" 조건을 재현한다.
    @MainActor
    func testStoreWithNoInjectedSourceStillResolvesInsteadOfHanging() throws {
        let store = try makeStore(lore: EmptyDigimonLoreSource())
        XCTAssertEqual(store.digimonLore(speciesID: 1), .missing)
    }

    /// `loreSource` 를 아예 주입하지 않았을 때(= `DigiTokenBarApp` 과 같은 조건) 기본값이 실제
    /// 번들 출처인지. **이 테스트가 `CompanionStore.loreSource` 기본값을 지키는 유일한 지점이다** —
    /// 기본값이 다시 `EmptyDigimonLoreSource()` 로 되돌아가면 여기서 실패한다. 위 테스트들은 전부
    /// 출처를 명시적으로 주입하므로 기본값 자체는 어느 것도 검증하지 못한다.
    @MainActor
    func testDefaultLoreSourceResolvesBundledSpecies() throws {
        let store = try makeStore(lore: nil)
        guard case .found(let lore) = store.digimonLore(speciesID: 1) else {
            return XCTFail("기본값이 번들 출처가 아니다 — 프로덕션에서 전 종이 '정보 없음' 이 된다")
        }
        XCTAssertEqual(lore.speciesID, 1)
    }

    @MainActor
    func testKnownSpeciesResolvesToFoundWithItsLore() throws {
        let store = try makeStore(lore: StubLoreSource(entries: [Self.sample]))
        guard case .found(let lore) = store.digimonLore(speciesID: 1) else {
            return XCTFail("등록된 종은 .found 여야 한다")
        }
        XCTAssertEqual(lore.level, .child)
        XCTAssertEqual(lore.attribute, .vaccine)
        XCTAssertEqual(lore.type, "Reptile")
        XCTAssertEqual(lore.attacks.count, 2)
        XCTAssertEqual(lore.attacks.first?.romaji, "Bebī Fureimu")
    }

    /// 데이터가 일부 종에만 있는 현실적인 구성. 있는 종은 `.found`, 없는 종은 `.missing` —
    /// 한 종의 부재가 다른 종의 조회를 막지 않는다.
    @MainActor
    func testPartialDataResolvesEachSpeciesIndependently() throws {
        let store = try makeStore(lore: StubLoreSource(entries: [Self.sample]))
        XCTAssertEqual(store.digimonLore(speciesID: 999), .missing)
        guard case .found = store.digimonLore(speciesID: 1) else {
            return XCTFail("999 가 없다고 1 까지 못 찾으면 안 된다")
        }
    }

    // MARK: 표시 문자열은 7개 언어가 전부 채워져 있다

    /// 세대 이름은 `DigiLevel` 전 케이스 × 전 언어가 비어 있으면 안 된다. `stageName(_:)` 이
    /// exhaustive switch 라 **케이스 누락**은 컴파일이 막지만, **번역 누락**은 막지 못한다.
    func testEveryDigiLevelHasANonEmptyNameInEveryLanguage() {
        for language in AppLanguage.allCases {
            let l = L(language)
            for level in DigiLevel.allCases {
                XCTAssertFalse(l.stageName(level).trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language) 의 \(level) 세대 이름이 비어 있음")
            }
        }
    }

    func testEveryAttributeHasANonEmptyNameInEveryLanguage() {
        for language in AppLanguage.allCases {
            let l = L(language)
            for attribute in DigimonLore.Attribute.allCases {
                XCTAssertFalse(l.attributeName(attribute).trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language) 의 \(attribute) 속성 이름이 비어 있음")
            }
        }
    }

    /// 데이터의 속성 표기는 대소문자가 일정하지 않다(`"Vaccine"` vs `"vaccine"`). 4종에 해당하면
    /// 번역하고, 아니면 **원문을 그대로** 돌려줘야 한다 — 빈 문자열을 내면 값이 화면에서 조용히 사라진다.
    func testAttributeLookupIsCaseInsensitiveAndFallsBackToTheRawString() {
        let l = L(.ko)
        XCTAssertEqual(l.attributeName(dataValue: "Vaccine"), l.attributeName(.vaccine))
        XCTAssertEqual(l.attributeName(dataValue: "vaccine"), l.attributeName(.vaccine))
        XCTAssertEqual(l.attributeName(dataValue: " Data "), l.attributeName(.data))
        XCTAssertEqual(l.attributeName(dataValue: "Unknown"), "Unknown")
        XCTAssertNil(DigimonLore.Attribute(dataValue: "Variable"))
    }

    /// 세대 이름이 케이스마다 서로 달라야 한다 — 전부 같은 문자열을 돌려줘도 위 "비어 있지 않음"
    /// 단언은 통과하므로, 매핑이 한 값으로 붕괴하는 회귀를 따로 막는다.
    func testStageNamesAreDistinctPerLevel() {
        let names = DigiLevel.allCases.map { L(.ko).stageName($0) }
        XCTAssertEqual(Set(names).count, DigiLevel.allCases.count)
    }

    // MARK: 번들 데이터 → 화면 경로 (위 단위 테스트가 전부 스텁이라 이 경로는 따로 지켜야 한다)

    /// 번들 출처를 실제로 주입했을 때 번들 데이터가 store 조회까지 도달하는지, 도감의 모든 라인에
    /// 걸쳐 확인한다. 위 테스트들은 전부 스텁을 주입하므로 이 경로(디코딩 → 조회)는 따로 확인해야
    /// 한다. 기본값 자체를 지키는 것은 `testDefaultLoreSourceResolvesBundledSpecies` 몫이다 —
    /// 이 테스트는 명시적으로 주입해 전 라인을 훑는 폭에 집중한다.
    @MainActor
    func testBundledSourceReachesTheStoreForEveryLineSpecies() throws {
        let store = try makeStore(lore: DigimonDetailsBundleSource())
        var found = 0
        for line in DigimonData.lines {
            for stage in line.stages {
                switch store.digimonLore(speciesID: stage.id) {
                case .found(let lore):
                    found += 1
                    XCTAssertEqual(lore.speciesID, stage.id)
                    XCTAssertFalse(lore.type.trimmingCharacters(in: .whitespaces).isEmpty)
                case .missing:
                    // 데이터 갭 자체는 허용(화면이 "정보 없음" 을 명시적으로 보여준다). 단 아래
                    // 총계 단언이 0 을 막으므로 다리가 통째로 끊기면 실패한다.
                    break
                }
            }
        }
        XCTAssertGreaterThan(found, 0, "번들 데이터가 store 까지 도달하지 못했다 — 주입 경로가 끊겼다")
    }

    /// 번들 출처가 실 데이터의 실제 필드까지 채워 돌려주는지(빈 배열/nil 로 뭉개지지 않는지).
    /// 기본값 자체를 지키는 것은 `testDefaultLoreSourceResolvesBundledSpecies` 몫이다 — 이
    /// 테스트는 명시적으로 주입해 필드 내용에 집중한다.
    @MainActor
    func testBundledSourceResolvesTheFirstLineBaseWithRealFields() throws {
        let store = try makeStore(lore: DigimonDetailsBundleSource())
        let baseID = try XCTUnwrap(DigimonData.lines.first?.baseID)
        guard case .found(let lore) = store.digimonLore(speciesID: baseID) else {
            return XCTFail("번들 데이터에 있는 종이 .missing 으로 떨어졌다")
        }
        XCTAssertFalse(lore.attacks.isEmpty)
        XCTAssertNotNil(lore.summaryKo)
    }

    // MARK: 테스트 보조

    private static let sample = DigimonLore(
        speciesID: 1, level: .child, attribute: .vaccine, type: "Reptile", nameKo: "아구몬",
        attacks: [DigimonLore.Attack(nameJa: "ベビーフレイム", romaji: "Bebī Fureimu"),
                  DigimonLore.Attack(nameJa: "スピットファイア", romaji: "Supittofaia")],
        summaryKo: "작은 공룡 모습의 파충류형 디지몬.")

    @MainActor
    private func makeStore(lore: (any DigimonLoreProviding)?) throws -> CompanionStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lore-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return CompanionStore(provider: LoreTestLineProvider(),
                              loreSource: lore,
                              fileURL: dir.appendingPathComponent("companion-state.json"),
                              defaults: UserDefaults(suiteName: dir.lastPathComponent)!)
    }
}

private struct StubLoreSource: DigimonLoreProviding {
    let entries: [DigimonLore]
    func lore(speciesID: Int) -> DigimonLore? { entries.first { $0.speciesID == speciesID } }
}

/// 상세 정보만 보는 테스트라 진화 라인은 최소 구현으로 둔다.
private struct LoreTestLineProvider: DigimonLineProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID, tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common, names: [baseSpeciesID: ["en": "Test"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}
