import XCTest
@testable import DigiTokenBar

// 성능(measure) + 스케일/비퇴화 검증. baseline 은 머신 의존이라 느슨하게(게이트는 정확성에).
// SeededRNG / StubProvider 는 CompanionTests.swift 의 내부 헬퍼 재사용.

private func pnode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private func pline(base: Int, rarity: Rarity) -> EvoLine {
    EvoLine(baseID: base, tree: pnode(base, [pnode(base + 1, [pnode(base + 2)])]), rarity: rarity, names: [:])
}
private let pNow = Date(timeIntervalSince1970: 1_700_000_000)
private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("poke-perf-\(UUID().uuidString).json")
}

// MARK: 순수 계산 핫패스

final class PureComputePerformanceTests: XCTestCase {
    func testPhaseThresholdThroughput() {
        measure {
            var acc = 0
            for i in 0..<100_000 {
                acc &+= DigimonBalance.phaseThreshold(rarity: .rare, totalForms: 3, stageIndex: i % 3)
            }
            XCTAssertGreaterThan(acc, 0)
        }
    }

    func testLargeDailyReportDecode() {
        let rows = (0..<1000).map {
            "{\"date\":\"2026-06-\(($0 % 28) + 1)\",\"inputTokens\":\($0),\"outputTokens\":1," +
            "\"cacheCreationTokens\":2,\"cacheReadTokens\":3,\"totalTokens\":\($0),\"totalCost\":0.1}"
        }.joined(separator: ",")
        let json = Data("{\"daily\":[\(rows)]}".utf8)
        measure {
            let report = try! JSONDecoder().decode(DailyReport.self, from: json)
            XCTAssertEqual(report.daily.count, 1000)
        }
    }
}

// MARK: 스토어 핫패스 / 스케일

@MainActor
final class StorePerformanceTests: XCTestCase {
    func testUpdateHotPath() async {
        // legendary(임계 6e9)를 부화시켜 진화 없이 작은 델타를 반복 — refresh 당 update 비용 측정.
        let s = CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .legendary)),
                               clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 1))
        await s.hatch(baseID: 1)
        var token = 0
        measure {
            for _ in 0..<500 {
                token += 100
                s.update(todayTokensByProvider: ["test": token], todayDate: "d", monthTotal: 0,
                         burnTier: .normal, limitWarning: false, hasUsageData: true)
            }
        }
        XCTAssertNotNil(s.state.active)   // 진화 없이 동일 단계 유지
    }

    /// 큰 도감을 파일 로드로 주입하고 정렬 비용/정확성을 함께 본다.
    private func storeWithLargeDex(_ count: Int) throws -> CompanionStore {
        let entries = (0..<count).map { i -> DexEntry in
            let r: Rarity = [.common, .uncommon, .rare, .legendary][i % 4]
            return DexEntry(baseID: i, finalID: i, chainOrder: [i], rarity: r,
                            caughtAt: pNow.addingTimeInterval(Double(i)))
        }
        let dexJSON = String(data: try JSONEncoder().encode(entries), encoding: .utf8)!
        let url = tmpURL()
        try Data("{\"saveVersion\":\(CompanionState.currentSaveVersion),\"dex\":\(dexJSON),\"language\":\"ko\"}".utf8).write(to: url)
        return CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .common)),
                              clock: { pNow }, fileURL: url, rng: SeededRNG(seed: 1))
    }

    func testLargeDexSortPerformanceAndCorrectness() throws {
        let s = try storeWithLargeDex(1000)
        XCTAssertEqual(s.dexEntries.count, 1000)
        measure {
            let sorted = s.dexEntriesSorted
            XCTAssertEqual(sorted.count, 1000)
        }
        // 정렬 정확성: 동행 기록는 기록 시각 최신순 — 희귀도는 순서에 관여하지 않는다.
        let sorted = s.dexEntriesSorted
        for i in 1..<sorted.count {
            XCTAssertGreaterThanOrEqual(
                sorted[i - 1].caughtAt ?? .distantPast,
                sorted[i].caughtAt ?? .distantPast)
        }
        XCTAssertEqual(sorted.first?.caughtAt, pNow.addingTimeInterval(999), "가장 최신 항목이 맨 앞")
        XCTAssertEqual(s.dexCount(.legendary), 250)
    }
}

// MARK: 비퇴화(터미네이션) 가드

@MainActor
final class StoreTerminationTests: XCTestCase {
    func testHugeDeltaGraduatesOnceAndTerminates() async {
        // 거대한 단일 델타가 무한 루프 없이 라인을 통과해 정확히 1회 졸업하는지 (guardCount 캡 보호).
        let s = CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .common)),
                               clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 1))
        await s.hatch(baseID: 1)
        s.applyUsage(Int(DigimonBalance.graduationTotal(.common)) * 10)   // 졸업 총량의 10배
        XCTAssertNil(s.state.active)            // 졸업 완료
        XCTAssertEqual(s.dexEntries.count, 1)   // 정확히 1회
        XCTAssertEqual(s.dexEntries[0].chainOrder, [1, 2, 3])
        XCTAssertEqual(s.state.eggUsage, 0)     // 새 알 인큐베이션 리셋
    }

    func testRepeatedGraduationGrowsDexLinearly() async {
        // 무진화 라인을 반복 졸업 — dex 가 선형으로 증가하고 상태가 매번 정합한지.
        let provider = StubProvider(value: pline(base: 1, rarity: .common))
        let s = CompanionStore(provider: provider, clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 9))
        for n in 1...20 {
            await s.hatch(baseID: 1)
            s.applyUsage(Int(DigimonBalance.graduationTotal(.common)) * 10)
            XCTAssertEqual(s.dexEntries.count, n)
            XCTAssertNil(s.state.active)
        }
    }
}

// MARK: 플로팅 펫 배터리 규율

@MainActor
final class FloatingPetEnergyTests: XCTestCase {
    /// 저전력 모드면 펫 애니메이션을 정지(정적)해 배터리를 아낀다. 정상 모드면 애니메이션.
    func testPetFreezesUnderLowPower() {
        XCTAssertFalse(FloatingPetController.shouldAnimate(lowPower: true))
        XCTAssertTrue(FloatingPetController.shouldAnimate(lowPower: false))
    }

    /// [회귀] 코얼레싱 tolerance 는 **늦게만** 발화시키므로 곧 재생 지연의 상한이다. 0.5 였을 때
    /// 2.75s 루프가 최대 4.13s 로 늘어 팝오버(tolerance 0)와 나란히 보면 메뉴바만 느렸다.
    /// 코얼레싱을 없애지 않으면서(>0) 늘어짐은 눈에 안 띄는 범위(≤15%)로 묶는다.
    func testToleranceDoesNotVisiblyStretchPlayback() {
        XCTAssertGreaterThan(AppDelegate.menuFrameTolerance, 0, "코얼레싱이 사라지면 wakeup 회귀")
        let loop = 2.75                       // 41-a.gif 실측 루프 길이
        let worstCase = loop * (1 + AppDelegate.menuFrameTolerance)
        XCTAssertLessThanOrEqual(worstCase, loop * 1.15,
                                 "최악의 경우 재생이 15% 이상 늘어지면 팝오버와 속도가 어긋나 보인다")
    }

    /// [복원: 커밋 4222180 에서 shiny 축과 함께 소실] 정적 스프라이트 재로딩 판정 — 종이 바뀔 때만
    /// 다시 불러야 한다(같은 종 재호출은 no-op).
    func testNeedsReloadOnlyWhenSpeciesChanges() {
        XCTAssertTrue(SpriteView.needsReload(loadedID: nil, id: 1), "최초 로드 전에는 항상 재로딩 필요")
        XCTAssertFalse(SpriteView.needsReload(loadedID: 1, id: 1), "같은 종이면 재로딩 불필요")
        XCTAssertTrue(SpriteView.needsReload(loadedID: 1, id: 2), "종이 바뀌면 재로딩 필요")
    }

    /// Bubble needs headroom + width beyond the square pet size — otherwise content is clipped.
    func testPanelGrowsForBubbleWithoutChangingPetOrigin() {
        let pet: CGFloat = 96
        let idle = FloatingPetController.panelSize(petSize: pet, showingBubble: false)
        XCTAssertEqual(idle, NSSize(width: pet, height: pet))

        let shown = FloatingPetController.panelSize(petSize: pet, showingBubble: true)
        XCTAssertGreaterThan(shown.height, pet, "must reserve vertical headroom for the bubble")
        XCTAssertGreaterThanOrEqual(shown.width, pet)

        // The other branch of `max(petSize, bubbleMinWidth)`: past 180pt the pet drives the
        // panel width, not the bubble column. Only 184/192 reached it before the slider max
        // went to 384, so it was an untested 2-step edge; now it is most of the range.
        let large: CGFloat = 384
        let largeShown = FloatingPetController.panelSize(petSize: large, showingBubble: true)
        XCTAssertEqual(largeShown.width, large, "panel must widen with the pet past bubbleMinWidth")
        XCTAssertEqual(largeShown.height, large + FloatingPetController.bubbleHeadroom)

        let petOrigin = NSPoint(x: 400, y: 200)
        let panelOrigin = FloatingPetController.panelOrigin(
            petOrigin: petOrigin, petSize: pet, panelSize: shown)
        XCTAssertEqual(panelOrigin.y, petOrigin.y, accuracy: 0.5)
        let roundTrip = FloatingPetController.petOrigin(
            panelOrigin: panelOrigin, petSize: pet, panelSize: shown)
        XCTAssertEqual(roundTrip.x, petOrigin.x, accuracy: 0.5)
        XCTAssertEqual(roundTrip.y, petOrigin.y, accuracy: 0.5)
    }

    /// Click opens the popover only when the pointer barely moved; larger movement is a drag.
    func testClickThresholdDistinguishesClickFromDrag() {
        let a = NSPoint(x: 10, y: 10)
        XCTAssertTrue(FloatingPetController.isClick(from: a, to: NSPoint(x: 11, y: 12)))
        XCTAssertTrue(FloatingPetController.isClick(from: a, to: a))
        XCTAssertFalse(FloatingPetController.isClick(from: a, to: NSPoint(x: 20, y: 10)))
    }

    /// Hover tooltip is localized and pure — tokens always; limit % only when provided.
    /// Remaining mode inverts the % and adds the self-describing suffix.
    func testHoverTooltipBuilder() {
        let l = L(.en)
        XCTAssertEqual(
            FloatingPetView.hoverTooltip(todayTokens: 12_345, limitUtilization: nil, mode: .used, l: l),
            l.floatingPetHoverTokensOnly(TokenFormatter.grouped(12_345)))
        XCTAssertEqual(
            FloatingPetView.hoverTooltip(todayTokens: 12_345, limitUtilization: 42, mode: .used, l: l),
            l.floatingPetHoverWithLimit(TokenFormatter.grouped(12_345), TokenFormatter.percent(42)))
        XCTAssertEqual(
            FloatingPetView.hoverTooltip(todayTokens: 12_345, limitUtilization: 42, mode: .remaining, l: l),
            l.floatingPetHoverWithLimit(TokenFormatter.grouped(12_345),
                                        l.percentRemaining(TokenFormatter.percent(58))))
    }

    /// [회귀] 호버 콜아웃의 글자와 외곽선은 같은 appearance에서 해석되어야 한다.
    /// 기존 경로는 텍스트 필드에 동적 `.labelColor`를 지정하면서 뷰를 만드는 동안
    /// `windowBackgroundColor.cgColor`를 굳혔다. 그 결과 다크 모드에서 밝은 말풍선에
    /// 흰 글자가 놓일 수 있었다.
    func testHoverCalloutColorsFollowLightAndDarkAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColors = FloatingPetController.hoverCalloutColors(for: light)
        let darkColors = FloatingPetController.hoverCalloutColors(for: dark)

        XCTAssertTrue(lightColors.text.isEqual(Self.snapshot(NSColor.labelColor, for: light)))
        XCTAssertTrue(lightColors.background.isEqual(Self.snapshot(NSColor.windowBackgroundColor, for: light)))
        XCTAssertTrue(lightColors.border.isEqual(Self.snapshot(NSColor.separatorColor, for: light)))
        XCTAssertTrue(darkColors.text.isEqual(Self.snapshot(NSColor.labelColor, for: dark)))
        XCTAssertTrue(darkColors.background.isEqual(Self.snapshot(NSColor.windowBackgroundColor, for: dark)))
        XCTAssertTrue(darkColors.border.isEqual(Self.snapshot(NSColor.separatorColor, for: dark)))

        XCTAssertFalse(lightColors.text.isEqual(darkColors.text), "text color must change with appearance")
        XCTAssertFalse(lightColors.background.isEqual(darkColors.background),
                      "bubble background must change with appearance")
        XCTAssertFalse(lightColors.text.isEqual(lightColors.background),
                       "라이트 모드 콜아웃 글자는 배경과 달라야 함")
        XCTAssertFalse(darkColors.text.isEqual(darkColors.background),
                       "다크 모드 콜아웃 글자는 배경과 달라야 함")
    }

    /// Alert copy in *every* language must fit the default bubble panel — width-capped wrap,
    /// not intrinsic `.fixedSize` that clipped ja by ~9pt (owner review on #124).
    /// Iterate `allCases`, never a literal list: a hardcoded `[.ko, .en, .ja]` silently stopped
    /// covering Spanish the moment #159 landed, which is exactly when a layout guard matters.
    ///
    /// The view draws body with `.lineLimit(2)` (#167). An unconstrained height check
    /// against `bubbleHeadroom` stays green for 3-line copy that still measures ≤70pt
    /// while the view truncates — so this guard fails on `wouldTruncate`, not only overflow.
    /// The tautological `measured.width ≤ panel.width` is gone: `measureSpeechBubble`
    /// clamps width to the column by construction, so that assert could never fail.
    func testLocalizedAlertBubbleFitsDefaultPanel() {
        let pet: CGFloat = 96
        let panel = FloatingPetController.panelSize(petSize: pet, showingBubble: true)
        XCTAssertEqual(panel.width, FloatingPetController.bubbleMinWidth)
        XCTAssertEqual(panel.height, pet + FloatingPetController.bubbleHeadroom)
        XCTAssertEqual(
            FloatingPetController.bubbleContentWidth
                + FloatingPetController.bubbleHorizontalPadding * 2,
            FloatingPetController.bubbleMinWidth,
            "content column + horizontal padding must equal panel width")
        XCTAssertEqual(
            FloatingPetController.bubbleBodyLineLimit, 2,
            "must stay in lockstep with SpeechBubbleView.lineLimit")

        for lang in AppLanguage.allCases {
            let l = L(lang)
            for title in [l.notifCritical, l.notifWarning] {
                for window in Self.alertWindows(l) {
                    let body = l.notifBody(window, TokenFormatter.percent(85))
                    let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
                    XCTAssertFalse(
                        layout.wouldTruncate,
                        "\(lang.rawValue) '\(title)' / '\(body)' wraps to \(layout.bodyLineCount) lines and would truncate at lineLimit(\(FloatingPetController.bubbleBodyLineLimit))")
                    XCTAssertLessThanOrEqual(
                        layout.size.height, FloatingPetController.bubbleHeadroom - 2,
                        "\(lang.rawValue) bubble height \(layout.size.height) must fit headroom \(FloatingPetController.bubbleHeadroom)")
                }
            }
        }
    }

    /// #167: 3-line copy that still fits the 70pt headroom must fail the guard.
    /// Height-only would stay green (owner's table: 3-line ≈69pt). Injected independently
    /// of Localization.swift so a green localized run can't hide a broken truncate check.
    func testThreeLineBodyThatFitsHeadroomWouldTruncate() {
        let title = "Límite inminente"
        let body = Self.bodyWrappingExtraLines(2, title: title)
        let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        XCTAssertEqual(layout.bodyLineCount, 3)
        XCTAssertLessThanOrEqual(
            layout.size.height, FloatingPetController.bubbleHeadroom - 2,
            "precondition: 3-line copy still fits the panel — the defect is truncation, not overflow")
        XCTAssertTrue(
            layout.wouldTruncate,
            "view lineLimit(2) truncates this copy; a headroom-only guard would miss it")
    }

    /// Two-line wrap is the view's designed capacity — must not trip truncation.
    func testTwoLineBodyDoesNotTruncate() {
        let title = "Límite inminente"
        let body = Self.bodyWrappingExtraLines(1, title: title)
        let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        XCTAssertEqual(layout.bodyLineCount, 2)
        XCTAssertFalse(layout.wouldTruncate)
        XCTAssertLessThanOrEqual(layout.size.height, FloatingPetController.bubbleHeadroom - 2)
    }

    /// 4-line copy overflows the panel *and* truncates — the other threshold in the owner's table.
    func testFourLineBodyExceedsHeadroomAndWouldTruncate() {
        let title = "Límite inminente"
        let body = Self.bodyWrappingExtraLines(3, title: title)
        let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        XCTAssertEqual(layout.bodyLineCount, 4)
        XCTAssertTrue(layout.wouldTruncate)
        XCTAssertGreaterThan(
            layout.size.height, FloatingPetController.bubbleHeadroom - 2,
            "4-line unconstrained height must miss the panel so the overflow assert can still fail")
    }

    /// Unclamped single-line width must be able to exceed the content column.
    /// `measureSpeechBubble` returns `min(contentWidth, …) + padding` (= panel width),
    /// so comparing that to `panel.width` can never fail (#167).
    func testUnclampedBubbleTextWidthCanExceedContentColumn() {
        let title = "Límite inminente"
        let body = String(repeating: "M", count: 80)
        let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        XCTAssertGreaterThan(
            layout.unclampedBodyWidth, layout.size.width,
            "unclamped width must exceed the clamped chrome, not echo min(contentWidth, …) + padding")
        XCTAssertGreaterThan(
            layout.unclampedBodyWidth, FloatingPetController.bubbleContentWidth)

        let short = FloatingPetController.measureSpeechBubbleLayout(title: "Hi", body: "Hi")
        XCTAssertEqual(short.bodyLineCount, 1)
        XCTAssertFalse(short.wouldTruncate)
        XCTAssertLessThanOrEqual(short.unclampedBodyWidth, FloatingPetController.bubbleContentWidth)
        XCTAssertLessThanOrEqual(short.unclampedTitleWidth, FloatingPetController.bubbleContentWidth)
    }

    /// Window names that `buildLimitWindows` can put in a bubble body.
    private static func alertWindows(_ l: L) -> [String] {
        [
            l.claudeFiveHour,
            l.claudeWeekly,
            "Claude \(l.weeklyOpus)",
            "Claude \(l.weeklySonnet)",
            l.codexPersonalLimit,
            "Codex \(l.codexWindow(300))",
            "Codex \(l.codexWindow(10_080))",
            "Claude \(l.claudeLimitEntry(kind: "weekly_scoped", model: "Opus"))",
            "\(l.antigravityGeminiGroup) \(l.fiveHourSession)",
            "\(l.antigravityThirdPartyGroup) \(l.weekly)",
        ]
    }

    private static func snapshot(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        return resolved
    }

    /// Grow a wrapping body until unconstrained `measureSpeechBubble` height has jumped
    /// `extraLines` times past a single line. Independent of `bodyLineCount` so the
    /// fixture still works if that field is the thing under test.
    private static func bodyWrappingExtraLines(_ extraLines: Int, title: String) -> String {
        var text = "word"
        var lastHeight = FloatingPetController.measureSpeechBubble(title: title, body: text).height
        var jumps = 0
        for _ in 0..<400 {
            text += " word"
            let height = FloatingPetController.measureSpeechBubble(title: title, body: text).height
            if height > lastHeight + 2 {
                jumps += 1
                lastHeight = height
                if jumps == extraLines { return text }
            }
        }
        return text
    }
}
