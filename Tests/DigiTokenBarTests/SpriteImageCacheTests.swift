import AppKit
import XCTest
@testable import DigiTokenBar

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

    func testSynchronousLoadsReuseImagesAndKeepVariantsSeparate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        var loaded: [NSImage] = []

        for (filename, animated) in [("25-s.png", false), ("25-a.gif", true)] {
            let file = dir.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: animated ? .gif : .png, properties: [:])).write(to: file)
            let first = try XCTUnwrap(SpriteLoader.cachedImage(
                speciesID: 25, animated: animated, directory: dir))
            XCTAssertFalse(loaded.contains { $0 === first }, "PNG/GIF must have distinct entries")
            loaded.append(first)
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedImage(
                speciesID: 25, animated: animated, directory: dir) === first,
                "a warm lookup must reuse the image object without reopening its file")
        }

        let otherDir = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: otherDir.appendingPathComponent("25-s.png"))
        let other = try XCTUnwrap(SpriteLoader.cachedImage(speciesID: 25, directory: otherDir))
        XCTAssertFalse(other === loaded[0], "an injected directory must not reuse another directory's pixels")
    }

    func testMissingOrInvalidImageDoesNotPreventALaterLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("25-s.png")
        XCTAssertNil(SpriteLoader.cachedImage(speciesID: 25, directory: dir))
        try Data("invalid image".utf8).write(to: file)
        XCTAssertNil(SpriteLoader.cachedImage(speciesID: 25, directory: dir))

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        XCTAssertNotNil(SpriteLoader.cachedImage(speciesID: 25, directory: dir),
                        "an earlier cache miss or decode failure must not be memoized")
    }

    func testAsyncLoadsPopulateTheSynchronousCacheAndReuseEachOther() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-async-\(UUID().uuidString)")
        let store = SpriteStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)

        for (filename, animated) in [("25-s.png", false), ("25-a.gif", true)] {
            let file = dir.appendingPathComponent(filename)
            try XCTUnwrap(bitmap.representation(using: animated ? .gif : .png, properties: [:])).write(to: file)
            // Xcode 16's NSImage is not Sendable; keep results on MainActor and await only completion.
            var result: NSImage?
            var second: NSImage?
            let firstLoad = Task<Void, Never> { @MainActor in
                result = await SpriteLoader.image(speciesID: 25, animated: animated, store: store)
            }
            let secondLoad = Task<Void, Never> { @MainActor in
                second = await SpriteLoader.image(speciesID: 25, animated: animated, store: store)
            }
            await firstLoad.value
            await secondLoad.value
            let first = try XCTUnwrap(result)
            XCTAssertTrue(second === first, "concurrent loads must converge on one image object")
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedImage(
                speciesID: 25, animated: animated, directory: dir) === first)
            let again = await SpriteLoader.image(speciesID: 25, animated: animated, store: store)
            XCTAssertTrue(again === first, "the async path must also reuse the image, not just the byte cache")
        }
    }

    func testItemLoadsShareTheImageCacheInBothDirections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("item-cache-\(UUID().uuidString)")
        let store = SpriteStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        for asyncFirst in [false, true] {
            let name = asyncFirst ? "rare-candy" : "digimental-courage"
            let file = dir.appendingPathComponent("item-\(name).png")
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
            _ = await store.data(itemName: name)
            try FileManager.default.removeItem(at: file)
            XCTAssertTrue(SpriteLoader.cachedItemImage(name: name, directory: dir) === first)
            let again = await SpriteLoader.itemImage(name: name, store: store)
            XCTAssertTrue(again === first)
        }
    }

    func testAsyncFallbacksStillReachNormalStaticImages() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-fallback-\(UUID().uuidString)")
        let store = SpriteStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 6, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("25-s.png"))
        for filename in ["25-a.gif", "item-rare-candy.png"] {
            // Existing corrupt cache files exercise decode failures without making network requests.
            try Data("invalid image".utf8).write(to: dir.appendingPathComponent(filename))
        }
        let result = await SpriteLoader.image(speciesID: 25, animated: true, store: store)
        let normal = try XCTUnwrap(result)
        XCTAssertTrue(SpriteLoader.cachedImage(speciesID: 25, directory: dir) === normal)
        let item = await SpriteLoader.itemImage(name: "rare-candy", store: store)
        XCTAssertNil(item)

        // A species outside Gen V has no GIF; that nil path must still try its PNG.
        try png.write(to: dir.appendingPathComponent("1000-s.png"))
        let staticOnly = await SpriteLoader.image(speciesID: 1000, animated: true, store: store)
        XCTAssertNotNil(staticOnly)
        XCTAssertTrue(SpriteLoader.cachedImage(speciesID: 1000, directory: dir) === staticOnly)
    }
}
