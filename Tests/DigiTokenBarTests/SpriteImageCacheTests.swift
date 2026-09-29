import AppKit
import XCTest
@testable import DigiTokenBar

/// 이 파일의 `SpriteStore` 는 전부 이 recorder 를 주입받는다 — `fetchWikimon` 을 주입하지 않으면
/// 기본값이 실제 `URLSession.shared` 라, 캐시 퇴출이나 파일명 변경으로 조회가 미스되는 순간 조용히
/// 실제 Wikimon 요청이 나간다(디스크에 파일을 미리 써서 "우연히" 오프라인인 상태였다).
/// 단순 `nil` 스텁으로는 그 구멍이 그대로 남으므로, **도달 자체를 결함으로 기록**한다.
///
/// `fetchWikimon` 이 `@Sendable` 이라 단순 `var` 캡처는 Swift 6 strict concurrency 에서 컴파일
/// 에러다 — 도달 사실을 actor 뒤에 모은다(`WikimonSpriteRequestTests.FetchRecorder` 와 같은 패턴이되,
/// 그쪽은 file-private 이라 재사용할 수 없고 의도도 다르다: 저쪽은 호출을 관찰하고, 이쪽은 금지한다).
private actor NetworkReachRecorder {
    private(set) var reachedFilenames: [String] = []

    func record(_ filename: String) { reachedFilenames.append(filename) }
}

/// 네트워크에 도달하면 즉시 실패로 기록하고 `nil` 을 반환하는 fetcher.
/// `nil` 을 돌려주는 이유: 바이트를 돌려주면 `data(filename:)` 이 temp 디렉토리에 파일을 써서
/// 도달이 오히려 조용한 통과로 위장된다. 도달 **시점**에 실패를 심는 게 이 클로저의 몫이다 —
/// 이어지는 `XCTUnwrap` 이 테스트를 중단시켜도 이미 기록이 남는다(그 경우 말미의
/// `assertNoNetworkReach` 는 실행되지 않으므로, 귀속은 이쪽 `XCTFail` 이 담당한다).
private func failOnNetworkReach(_ recorder: NetworkReachRecorder) -> @Sendable (URLRequest) async -> Data? {
    { request in
        let filename = request.url?.lastPathComponent ?? request.url?.absoluteString ?? "<no url>"
        await recorder.record(filename)
        XCTFail("이 테스트는 오프라인이어야 한다 — 실제 Wikimon 요청이 나갔다: \(filename)")
        return nil
    }
}

/// 도달 0건 단정 — 테스트가 끝까지 갔을 때 총량을 고정한다(중단된 경우는 위 `XCTFail` 이 덮는다).
private func assertNoNetworkReach(_ recorder: NetworkReachRecorder,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    let reached = await recorder.reachedFilenames
    XCTAssertEqual(reached, [], "네트워크 도달 0건이어야 한다", file: file, line: line)
}

/// Exercise the production loaders with generated pixels and an isolated disk cache.
/// Reusing raw Data alone does not prevent View.init from reopening files and creating NSImages.
@MainActor
final class SpriteImageCacheTests: XCTestCase {
    /// 이 클래스의 단언은 전부 `===` (객체 동일성)이라 캐시가 엔트리를 유지해야 성립한다. 하지만
    /// `SpriteLoader.imageCache` 는 전역이고 countLimit 이 64 라, 같은 프로세스의 다른 스프라이트
    /// 테스트가 넣은 엔트리와 합쳐져 한계를 넘으면 방금 넣은 이미지도 임의로 퇴출된다(NSCache 계약).
    /// 격리 실행은 통과하고 전체 스위트에서만 실패하던 원인 — 테스트 동안만 퇴출을 끄고 되돌린다.
    // nonisolated(unsafe): @MainActor 클래스의 sync setUp/tearDown 은 릴리스 Swift 에서 nonisolated 로
    // 취급돼 main-actor 프로퍼티 접근이 컴파일 에러가 된다(UsageStoreTests 와 동일 패턴). imageCache 는
    // @MainActor 라 본문은 assumeIsolated 로 명시적으로 홉한다.
    private nonisolated(unsafe) var previousCountLimit = 0

    override func setUp() {
        super.setUp()
        previousCountLimit = MainActor.assumeIsolated {
            let countLimit = SpriteLoader.imageCache.countLimit
            SpriteLoader.imageCache.removeAllObjects()
            SpriteLoader.imageCache.countLimit = 0   // 0 = 무제한(퇴출 없음)
            return countLimit
        }
    }

    override func tearDown() {
        let countLimit = previousCountLimit
        MainActor.assumeIsolated {
            SpriteLoader.imageCache.removeAllObjects()
            SpriteLoader.imageCache.countLimit = countLimit
        }
        super.tearDown()
    }

    func testSynchronousLoadsReuseImagesAndKeepCandidatesSeparate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        var loaded: [NSImage] = []

        // 폴백 체인의 서로 다른 후보 파일명 — 후보마다 캐시 항목이 분리돼야 한다(키가 파일명 자체).
        let candidates = Array(SpriteLoader.filenames(for: 1).prefix(2))
        XCTAssertEqual(candidates.count, 2, "폴백 체인이 2개 미만이면 이 테스트가 분리를 검증하지 못한다")
        let isolationName = try XCTUnwrap(candidates.first)
        for filename in candidates {
            let file = dir.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            let first = try XCTUnwrap(SpriteLoader.cachedImage(filenames: [filename], directory: dir))
            XCTAssertFalse(loaded.contains { $0 === first }, "후보 파일명마다 별개 항목이어야 한다")
            loaded.append(first)
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedImage(filenames: [filename], directory: dir) === first,
                "a warm lookup must reuse the image object without reopening its file")
        }

        let otherDir = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: otherDir.appendingPathComponent(isolationName))
        let other = try XCTUnwrap(SpriteLoader.cachedImage(filenames: [isolationName], directory: otherDir))
        XCTAssertFalse(other === loaded[0], "an injected directory must not reuse another directory's pixels")
    }

    func testMissingOrInvalidImageDoesNotPreventALaterLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let filename = try XCTUnwrap(SpriteLoader.filenames(for: 1).first)
        let file = dir.appendingPathComponent(filename)
        XCTAssertNil(SpriteLoader.cachedImage(filenames: [filename], directory: dir))
        try Data("invalid image".utf8).write(to: file)
        XCTAssertNil(SpriteLoader.cachedImage(filenames: [filename], directory: dir))

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        XCTAssertNotNil(SpriteLoader.cachedImage(filenames: [filename], directory: dir),
                        "an earlier cache miss or decode failure must not be memoized")
    }

    func testAsyncLoadsPopulateTheSynchronousCacheAndReuseEachOther() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-async-\(UUID().uuidString)")
        let recorder = NetworkReachRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: failOnNetworkReach(recorder))
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)

        // 폴백 체인의 앞/뒤 후보 둘 다 — 어느 후보로 확정되든 객체 동일성은 같아야 한다.
        for filename in SpriteLoader.filenames(for: 1).prefix(2) {
            let file = dir.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            // Xcode 16's NSImage is not Sendable; keep results on MainActor and await only completion.
            var result: NSImage?
            var second: NSImage?
            let firstLoad = Task<Void, Never> { @MainActor in
                result = await SpriteLoader.image(filenames: [filename], store: store)
            }
            let secondLoad = Task<Void, Never> { @MainActor in
                second = await SpriteLoader.image(filenames: [filename], store: store)
            }
            await firstLoad.value
            await secondLoad.value
            let first = try XCTUnwrap(result)
            XCTAssertTrue(second === first, "concurrent loads must converge on one image object")
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedImage(filenames: [filename], directory: dir) === first)
            let again = await SpriteLoader.image(filenames: [filename], store: store)
            XCTAssertTrue(again === first, "the async path must also reuse the image, not just the byte cache")
        }
        await assertNoNetworkReach(recorder)
    }

    func testItemLoadsShareTheImageCacheInBothDirections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("item-cache-\(UUID().uuidString)")
        let recorder = NetworkReachRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: failOnNetworkReach(recorder))
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        for asyncFirst in [false, true] {
            // 아이템 스프라이트 이름은 이제 완전한 Wikimon 파일명이다 — 캐시 키가 파일명 그 자체라
            // 디스크 파일명도 접두사 없이 같은 이름을 쓴다(`data(filename:)` 단일 경로).
            let name = asyncFirst ? "Digimental_hope.jpg" : "Digimental_courage.jpg"
            let file = dir.appendingPathComponent(name)
            XCTAssertNil(SpriteLoader.cachedItemImage(name: name, directory: dir))
            try png.write(to: file)
            var result: NSImage?
            if asyncFirst {
                var second: NSImage?
                let firstLoad = Task<Void, Never> { @MainActor in
                    result = await SpriteLoader.itemImage(name: name, store: store)
                }
                let secondLoad = Task<Void, Never> { @MainActor in
                    second = await SpriteLoader.itemImage(name: name, store: store)
                }
                await firstLoad.value
                await secondLoad.value
                XCTAssertTrue(second === result, "concurrent item loads must also share their image object")
            } else {
                result = SpriteLoader.cachedItemImage(name: name, directory: dir)
            }
            let first = try XCTUnwrap(result)
            // Keep fault injection offline too: a broken image cache may still read the byte cache.
            _ = await store.data(filename: name)
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedItemImage(name: name, directory: dir) === first)
            let again = await SpriteLoader.itemImage(name: name, store: store)
            XCTAssertTrue(again === first)
        }
        await assertNoNetworkReach(recorder)
    }

    func testCorruptCacheFilesDecodeToNilWithoutNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-fallback-\(UUID().uuidString)")
        let recorder = NetworkReachRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: failOnNetworkReach(recorder))
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let primary = try XCTUnwrap(SpriteLoader.filenames(for: 1).first)
        try png.write(to: dir.appendingPathComponent(primary))
        // Existing corrupt cache files exercise decode failures without making network requests.
        try Data("invalid image".utf8).write(to: dir.appendingPathComponent("Digimental_courage.jpg"))
        let result = await SpriteLoader.image(filenames: [primary], store: store)
        let normal = try XCTUnwrap(result)
        XCTAssertTrue(SpriteLoader.cachedImage(filenames: [primary], directory: dir) === normal)
        // 디코딩 실패는 네트워크를 타지 않고 nil — 뷰가 이모지로 폴백한다.
        let item = await SpriteLoader.itemImage(name: "Digimental_courage.jpg", store: store)
        XCTAssertNil(item)
        await assertNoNetworkReach(recorder)
    }
}
