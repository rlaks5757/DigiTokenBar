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
        let store = SpriteStore(directory: dir)
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
    }

    func testCorruptCacheFilesDecodeToNilWithoutNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprite-fallback-\(UUID().uuidString)")
        let store = SpriteStore(directory: dir)
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
    }
}
