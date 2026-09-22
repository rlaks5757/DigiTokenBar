import XCTest
import AppKit
@testable import DigiTokenBar

// SpriteView 가 그리는 주체의 전이 규칙.
//
// 두 가지를 잠근다:
//  1) 주체가 알로 바뀌면 이전 개체의 픽셀을 버린다 (#135 — 졸업·Fresh Egg 후에도 옛 디지몬이 떠 있던 회귀).
//  2) **취소된 로드는 어떤 상태도 건드리지 않는다.** Swift 의 취소는 협조적이라 `.task(id:)` 가 취소돼도
//     await 뒤 코드는 계속 실행된다 — 후속 task 가 이미 새 주체로 잡아 둔 상태를 뒤늦게 덮어쓸 수 있다.
//
// SwiftUI `.task` 자체는 호스트 없이 돌릴 수 없어 규칙을 순수 전이로 빼서 검증한다.
// 아래 동시성 테스트는 그 "뒤늦게 도착하는 continuation" 순서를 게이트로 **강제**해 재현한다.

/// 테스트가 재개 시점을 쥐는 게이트 — 로드가 await 에서 멈춰 있는 구간을 결정적으로 만든다.
/// (UsageStoreTests 의 GatedUsageProvider 와 같은 방식.)
private actor LoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if released { c.resume() } else { continuation = c }
        }
    }

    func release() {
        released = true
        let c = continuation
        continuation = nil
        c?.resume()
    }
}

/// @State 대신 전이 결과를 담아 두는 상자 — Task 클로저에서 안전하게 갱신하기 위해.
@MainActor
private final class SubjectBox {
    var subject: SpriteSubject
    var sawCancellation = false
    init(_ subject: SpriteSubject) { self.subject = subject }
}

@MainActor
final class SpriteSubjectTests: XCTestCase {

    private func image(_ side: CGFloat) -> NSImage { NSImage(size: NSSize(width: side, height: side)) }

    // MARK: 주체가 알로 바뀔 때 (#135)

    /// 졸업·Fresh Egg — 이전 개체의 픽셀은 다른 주체의 것이라 버리고 알로 교체한다.
    func testBecomingEggDropsPreviousSpeciesPixels() {
        let species = image(4), egg = image(2)
        let next = SpriteSubject(image: species, loadedID: 25).becomingEgg(cachedEgg: egg)
        XCTAssertTrue(next.image === egg, "옛 개체 이미지가 남으면 플로팅 펫이 졸업 후에도 그 디지몬을 그린다")
        XCTAssertNil(next.loadedID)
    }

    /// 알 이미지가 아직 캐시에 없으면(콜드) 옛 개체를 남기는 대신 글리프로 떨어뜨린다.
    func testBecomingEggWithColdCacheClearsToGlyph() {
        let next = SpriteSubject(image: image(4), loadedID: 25).becomingEgg(cachedEgg: nil)
        XCTAssertNil(next.image, "캐시가 없다고 옛 개체를 남기면 안 된다 — 🥚 글리프가 옳다")
        XCTAssertNil(next.loadedID)
    }

    /// 이미 알이던 주체는 건드리지 않는다 — 시드된 알 이미지를 지우면 글리프로 한 번 깜빡인다.
    func testBecomingEggLeavesAnExistingEggAlone() {
        let egg = image(2)
        let next = SpriteSubject(image: egg, loadedID: nil).becomingEgg(cachedEgg: nil)
        XCTAssertTrue(next.image === egg)
        XCTAssertNil(next.loadedID)
    }

    // MARK: 취소된 로드 (이 PR)

    /// [트리거] 취소된 정적 로드는 이미지도 loadedID 도 건드리지 않는다.
    /// 반영하면 (a) 알 위에 옛 개체가 되살아나고 (b) loadedID 가 오염돼 다음에 그 종이 활성일 때
    /// "이미 로드됨"으로 판단해 살아있는 디지몬 자리에 🥚 글리프가 고정된다.
    func testCancelledLoadLeavesSubjectUntouched() {
        let species = image(4)
        XCTAssertNil(SpriteSubject(image: image(2), loadedID: nil).applyingLoad(species, for: 26, cancelled: true),
                     "취소된 로드는 상태를 아예 건드리면 안 된다 — 이미지 복원과 loadedID 오염이 여기서 갈린다")
    }

    /// 취소되지 않은 로드는 그대로 반영한다(가드가 과잉 차단하지 않는지).
    func testAcceptedLoadUpdatesImageAndID() throws {
        let species = image(4)
        let next = try XCTUnwrap(SpriteSubject(image: nil, loadedID: nil)
            .applyingLoad(species, for: 26, cancelled: false))
        XCTAssertTrue(next.image === species)
        XCTAssertEqual(next.loadedID, 26)
    }

    /// 로드 실패(오프라인)는 기존 동작대로 "시도했음"을 남긴다 — 같은 id 재요청 폭주 방지.
    func testFailedButNotCancelledLoadStillMarksTheAttempt() throws {
        let next = try XCTUnwrap(SpriteSubject(image: image(4), loadedID: 25)
            .applyingLoad(nil, for: 26, cancelled: false))
        XCTAssertNil(next.image)
        XCTAssertEqual(next.loadedID, 26)
    }

    /// 알 이미지 로드도 같은 규칙 — 취소면 무시, 아니면 반영하되 loadedID 는 알(nil) 그대로.
    func testEggImageAppliesOnlyWhenNotCancelled() throws {
        let egg = image(2)
        XCTAssertNil(SpriteSubject(image: nil, loadedID: nil).applyingEgg(egg, cancelled: true))

        let applied = try XCTUnwrap(SpriteSubject(image: nil, loadedID: nil).applyingEgg(egg, cancelled: false))
        XCTAssertTrue(applied.image === egg)
        XCTAssertNil(applied.loadedID)
    }

    // MARK: 실제 취소 순서 재현 (회귀 트리거)

    /// [회귀] 취소된 task 의 continuation 이 **후속 task 뒤에** 도착하는 순서를 게이트로 강제한다.
    /// 이 순서가 실재하지 않으면 위 가드는 무의미하므로, 취소가 관측됐다는 사실까지 함께 확인한다.
    func testCancelledLoadArrivingLateCannotRestorePreviousSubject() async {
        let gate = LoadGate()
        let species = image(4), egg = image(2)
        let box = SubjectBox(SpriteSubject(image: species, loadedID: 25))   // 25 를 띄우던 펫

        // 26 으로 바뀌어 스프라이트를 받는 중(await 에서 정지).
        let load = Task { @MainActor in
            await gate.wait()
            box.sawCancellation = Task.isCancelled
            if let next = box.subject.applyingLoad(species, for: 26, cancelled: Task.isCancelled) {
                box.subject = next
            }
        }

        // 그 사이 졸업 → .task 취소 + 후속 task 가 알 상태를 확정.
        load.cancel()
        box.subject = box.subject.becomingEgg(cachedEgg: egg)
        XCTAssertTrue(box.subject.image === egg, "사전 조건: 알 전환은 이미 반영돼 있어야 한다")

        // 이제 멈춰 있던 로드가 재개된다.
        await gate.release()
        _ = await load.value

        XCTAssertTrue(box.sawCancellation,
                      "취소된 task 의 await 뒤 코드는 계속 실행된다 — 이 전제가 깨지면 이 가드는 불필요하다")
        XCTAssertTrue(box.subject.image === egg, "뒤늦은 로드가 알을 덮어썼다 — #135 가 그대로 재발한다")
        XCTAssertNil(box.subject.loadedID, "뒤늦은 로드가 loadedID 를 오염시켰다")

        // 대조군: 가드가 없으면(=취소를 안 보면) 옛 개체가 되살아난다 — 가드가 실제로 일하는지.
        let unguarded = SpriteSubject(image: egg, loadedID: nil).applyingLoad(species, for: 26, cancelled: false)
        XCTAssertTrue(unguarded?.image === species)
        XCTAssertEqual(unguarded?.loadedID, 26)
    }
}
