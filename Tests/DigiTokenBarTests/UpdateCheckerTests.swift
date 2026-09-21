import XCTest
@testable import DigiTokenBar

final class UpdateCheckerTests: XCTestCase {
    func testNewerPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.2", than: "2.0.1"))
    }
    func testSameIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.1", than: "2.0.1"))
    }
    func testOlderIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: "2.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.9", than: "2.1.0"))
    }
    func testNumericNotLexical() {
        // "2.0.10" 은 "2.0.9" 보다 높다 (문자열 비교면 반대로 틀림)
        XCTAssertTrue(UpdateChecker.isNewer("2.0.10", than: "2.0.9"))
    }
    func testMinorAndMajor() {
        XCTAssertTrue(UpdateChecker.isNewer("2.1.0", than: "2.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("3.0.0", than: "2.9.9"))
    }
    func testDifferentComponentCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.1", than: "2.0"))   // 2.0.1 > 2.0.0
        XCTAssertFalse(UpdateChecker.isNewer("2.0", than: "2.0.0"))  // 동일
    }

    // MARK: - Detached upgrade script wait loop (#175)

    func testDetachedUpgradeScriptWaitsOnPidNotProcessName() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertFalse(
            script.contains("pgrep -x"),
            "pgrep -x matches any instance by name and always times out when a duplicate runs"
        )
        XCTAssertTrue(
            script.contains("kill -0 \"$3\""),
            "the wait loop must wait on the specific terminating PID via $3"
        )
    }

    /// "Skip this version" hides the banner, but a later check must still know
    /// the release exists. Settings must not treat that as "already latest".
    @MainActor
    func testSkippedReleaseStaysVisibleAndANewerOneReturnsToTheBanner() {
        let suite = "UpdateCheckerTests.skip.\(UUID().uuidString)"
        let box = UserDefaults(suiteName: suite)!
        defer { box.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: box)

        checker.consider(latest: "2.5.4", url: "https://github.com/rlaks5757/DigiTokenBar/releases/tag/v2.5.4")
        XCTAssertEqual(checker.available?.version, "2.5.4")
        XCTAssertNil(checker.skipped)
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.4"))

        checker.skipCurrent()
        XCTAssertNil(checker.available, "the popover banner stays hidden")
        XCTAssertEqual(checker.skipped?.version, "2.5.4")
        XCTAssertEqual(checker.settingsNotice, .skipped("2.5.4"))
        XCTAssertEqual(box.string(forKey: "skippedUpdateVersion"), "2.5.4")

        checker.consider(latest: "v2.5.4", url: "https://github.com/rlaks5757/DigiTokenBar/releases/tag/v2.5.4")
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.settingsNotice, .skipped("2.5.4"), "a skipped version is not the latest installed")

        checker.consider(latest: "2.5.5", url: "https://github.com/rlaks5757/DigiTokenBar/releases/tag/v2.5.5")
        XCTAssertEqual(checker.available?.version, "2.5.5")
        XCTAssertNil(checker.skipped)
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.5"))

        checker.consider(latest: "2.5.3", url: "https://github.com/rlaks5757/DigiTokenBar/releases/tag/v2.5.3")
        XCTAssertEqual(checker.settingsNotice, .current, "the installed release is the latest")
    }

    @MainActor
    func testShowAgainRestoresTheBannerAndUpdateUsesTheSkippedRelease() {
        let suite = "UpdateCheckerTests.restore.\(UUID().uuidString)"
        let box = UserDefaults(suiteName: suite)!
        defer { box.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(currentVersion: "2.5.3", defaults: box)
        let url = "https://github.com/rlaks5757/DigiTokenBar/releases/tag/v2.5.4"
        checker.consider(latest: "2.5.4", url: url)
        checker.skipCurrent()

        XCTAssertEqual(checker.updateTarget?.url, url, "Settings can still install a skipped release")

        checker.showSkippedAgain()
        XCTAssertEqual(checker.available?.version, "2.5.4")
        XCTAssertNil(checker.skipped)
        XCTAssertNil(box.string(forKey: "skippedUpdateVersion"))
        XCTAssertEqual(checker.settingsNotice, .offer("2.5.4"))
    }

    /// [회귀] brew 업그레이드 경로의 **봉인**을 고정한다.
    ///
    /// `detachedUpgradeScript` 는 upstream cask `poke-token-bar` 를 업그레이드한다. 포크에서
    /// 이게 실행되면 우리가 아니라 **사용자의 PokeTokenBar 설치본**이 업그레이드된다(제3자 앱에
    /// 대한 파괴적 동작). 그래서 유일한 진입점인 `brewCaskPath()` 가 무조건 `nil` 을 반환하도록
    /// 막아뒀다 — 스크립트 문자열은 "없는 cask 이름을 약속하지 않기 위해" 일부러 그대로 둔다.
    ///
    /// 봉인은 그 함수 본문 하나에만 의존한다. `launchDetachedUpgrade`/`detachedUpgradeScript` 는
    /// `private` 이 아니라, 우회해서 brew 경로만 넘기면 스크립트가 그대로 실행된다. 즉 "오늘
    /// 도달 불가"는 참이지만 구조적으로 강제되진 않는다. 여기서 그 본문을 고정한다.
    ///
    /// `brewCaskPath()` 는 `private` 이라 `@testable` 로도 호출할 수 없어 소스를 읽어 검사한다
    /// (같은 저장소의 `LanguageSurfaceRegressionTests` 가 쓰는 방식).
    func testBrewUpgradePathStaysSealedSoUpstreamInstallIsNeverTouched() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DigiTokenBar/Core/UpdateChecker.swift"),
                                encoding: .utf8)

        // 전제: 스크립트가 upstream cask 를 겨냥하고 있다. 이게 바뀌면(우리 cask 준비 등)
        // 이 테스트의 근거가 사라지므로 함께 재검토해야 한다.
        XCTAssertTrue(UpdateChecker.detachedUpgradeScript.contains("--cask poke-token-bar"),
                      "전제: 스크립트는 여전히 upstream cask 를 겨냥한다")

        let body = try XCTUnwrap(
            source.range(of: "private nonisolated static func brewCaskPath() -> String? {").map {
                String(source[$0.upperBound...].prefix(while: { $0 != "}" }))
            },
            "brewCaskPath() 선언을 찾지 못했다 — 이름이 바뀌었다면 이 테스트를 갱신할 것"
        )
        let statements = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }

        XCTAssertEqual(statements, ["nil"],
                       """
                       brewCaskPath() 는 무조건 nil 을 반환해야 한다. 조건부로 brew 경로를 반환하면
                       detachedUpgradeScript 가 실행되어 사용자의 upstream PokeTokenBar 설치본을
                       업그레이드한다. 자체 cask/tap 을 준비할 때 스크립트의 cask 이름과 **함께** 푼다.
                       """)
    }

    func testDetachedUpgradeScriptUsesPositionalParameters() {
        let script = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(script.contains("\"$1\" update"), "must execute brew via $1 positional arg")
        XCTAssertTrue(script.contains("\"$1\" upgrade"), "must execute brew upgrade via $1 positional arg")
        XCTAssertTrue(script.contains("open \"$2\""), "must open bundlePath via $2 positional arg")
    }
}
