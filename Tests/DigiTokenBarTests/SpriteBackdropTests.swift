import AppKit
import XCTest
@testable import DigiTokenBar

/// 흰 배경 일러스트 누끼(`fillingWhiteBackdrop`) — **합성 비트맵만** 쓴다.
/// 실제 자산이나 네트워크에 의존하면 캐시가 비어 있을 때만 실패하는 테스트가 된다.
@MainActor
final class SpriteBackdropTests: XCTestCase {
    /// `SpriteLoader.imageCache` 는 전역이고 countLimit 이 64 다. 아래 `===` 단언은 캐시가 엔트리를
    /// 유지해야 성립하고, 반대로 이 클래스가 캐시를 임의 시점에 비우면 **다른 스프라이트 테스트**가
    /// 깨진다(실측: 인라인 defer 로 비웠더니 SpriteImageCacheTests 14건 실패). 퇴출을 끄고 되돌리는
    /// 범위를 setUp/tearDown 으로 맞춰 둔다 — SpriteImageCacheTests 와 동일 패턴.
    // nonisolated(unsafe): @MainActor 클래스의 sync setUp/tearDown 은 릴리스 Swift 에서 nonisolated 로
    // 취급돼 main-actor 프로퍼티 접근이 컴파일 에러가 된다.
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

    /// 흰 배경 + 닫힌 어두운 사각 윤곽선 + **윤곽선 안쪽의 흰색 영역**을 가진 JPEG 를 만든다.
    /// 안쪽 흰색이 이 픽스처의 핵심이다 — 전역 흰색 키잉 구현과 flood-fill 구현을 갈라내는 유일한 지점.
    private func borderedFixture(
        size: Int = 20, inset: Int = 5, openGapAtTop: Bool = false
    ) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.bitmapData)
        let row = rep.bytesPerRow
        for y in 0..<size {
            for x in 0..<size {
                // 윤곽선 = inset 위치의 한 줄짜리 사각 테두리. 그 안쪽은 흰색(=피사체의 흰 몸통).
                let onBorder = (x == inset || x == size - 1 - inset) && (inset...(size - 1 - inset)).contains(y)
                    || (y == inset || y == size - 1 - inset) && (inset...(size - 1 - inset)).contains(x)
                // 누수 픽스처: 윗변 가운데를 뚫어 배경이 안쪽으로 새게 한다.
                let gap = openGapAtTop && y == inset && x == size / 2
                let v: UInt8 = (onBorder && !gap) ? 0 : 255
                let p = data + y * row + x * 3
                p[0] = v; p[1] = v; p[2] = v
            }
        }
        // JPEG 이 아니라 PNG 로 직렬화한다 — samplesPerPixel==3/hasAlpha==false 는 동일하게 유지하면서
        // JPEG 손실 압축이 윤곽선을 흐려 테스트가 임계값에 민감해지는 것을 피한다.
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func rep(_ data: Data) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    func testCornersBecomeTransparentWhileEnclosedWhiteStaysOpaque() throws {
        let size = 20, inset = 5
        let filled = try XCTUnwrap(SpriteLoader.fillingWhiteBackdrop(borderedFixture()),
                                   "닫힌 윤곽선을 가진 흰 배경 이미지는 변환돼야 한다")
        let out = try rep(filled)
        XCTAssertTrue(out.hasAlpha, "출력 rep 에는 알파 채널이 있어야 한다")
        XCTAssertEqual(out.samplesPerPixel, 4, "알파를 쓰려면 4 샘플 rep 여야 한다(3 샘플에 쓰면 옆 픽셀 red 를 덮는다)")

        for (x, y) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)] {
            XCTAssertEqual(out.colorAt(x: x, y: y)?.alphaComponent, 0,
                           "모서리 (\(x),\(y)) 는 배경이라 투명해야 한다")
        }
        // ← 이 단언이 없으면 전역 흰색 키잉 구현도 통과한다.
        let inner = size / 2
        XCTAssertEqual(out.colorAt(x: inner, y: inner)?.alphaComponent, 1,
                       "윤곽선 안쪽의 흰색은 피사체이므로 불투명하게 남아야 한다")
        XCTAssertEqual(out.colorAt(x: inset, y: inset)?.alphaComponent, 1, "윤곽선 자체도 불투명해야 한다")
    }

    func testAlreadyTransparentImageIsLeftAlone() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.bitmapData?.initialize(repeating: 255, count: rep.bytesPerRow * rep.pixelsHigh)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertNil(SpriteLoader.fillingWhiteBackdrop(png),
                     "알파가 이미 있는 자산(디지몬 vpet PNG 52종)은 건드리지 않고 nil 이어야 한다")
    }

    func testLeakyOutlineFallsBackToTheOriginal() throws {
        // 윤곽선이 뚫려 있으면 배경이 안쪽까지 새서 캔버스 대부분이 채워진다 → 아이콘이 통째로
        // 사라지는 대신 오늘과 같은 동작(흰 배경)으로 degrade 해야 한다.
        let leaky = try borderedFixture(openGapAtTop: true)
        XCTAssertNil(SpriteLoader.fillingWhiteBackdrop(leaky),
                     "누수가 나면 원본을 쓰도록 nil 을 반환해야 한다")
    }

    /// 열마다 다른 **진한 유채색** 내부 + 흰 배경 + 닫힌 어두운 윤곽선. 단색/회색조 픽스처는 stride 가
    /// 한 바이트 밀려도 티가 안 나서(밀린 자리도 같은 값이다) 이 버그를 못 잡는다 — 열마다 색이 달라야
    /// 어긋난 offset 이 "이 픽셀의 blue + 패딩 + 다음 픽셀의 red" 를 조립한 게 값으로 드러난다.
    private func colorColumnFixture(size: Int, inset: Int) throws -> (data: Data, expected: [(UInt8, UInt8, UInt8)]) {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.bitmapData)
        let row = rep.bytesPerRow, stride = rep.bitsPerPixel / 8
        // 열 x 의 색. 세 채널 모두 임계값(240) 아래로 유지해 배경으로 오인되지 않게 한다.
        func color(_ x: Int) -> (UInt8, UInt8, UInt8) {
            (UInt8(11 + (x * 37) % 200), UInt8(200 - (x * 53) % 190), UInt8(23 + (x * 71) % 200))
        }
        var expected: [(UInt8, UInt8, UInt8)] = []
        for y in 0..<size {
            for x in 0..<size {
                let onBorder = (x == inset || x == size - 1 - inset) && (inset...(size - 1 - inset)).contains(y)
                    || (y == inset || y == size - 1 - inset) && (inset...(size - 1 - inset)).contains(x)
                let inside = (inset + 1)...(size - 2 - inset)
                let p = data + y * row + x * stride
                if onBorder {
                    p[0] = 0; p[1] = 0; p[2] = 0
                } else if inside.contains(x) && inside.contains(y) {
                    let c = color(x); p[0] = c.0; p[1] = c.1; p[2] = c.2
                } else {
                    p[0] = 255; p[1] = 255; p[2] = 255   // 바깥 = 흰 배경
                }
            }
        }
        for x in 0..<size { expected.append(color(x)) }
        // PNG(무손실)로 직렬화 — JPEG 이면 색이 뭉개져 정확한 기대값 단언이 불가능하다.
        return (try XCTUnwrap(rep.representation(using: .png, properties: [:])), expected)
    }

    /// 회귀 가드: **픽셀 stride 를 `samplesPerPixel` 로 계산하면 안 된다.**
    ///
    /// 대상 JPEG 10종은 전부 `samplesPerPixel == 3` 인데 디코더가 픽셀당 4바이트로 패딩해
    /// `bitsPerPixel == 32` 다. `x * spp` 로 인덱싱하면 x 가 커질수록 offset 이 1바이트씩 밀려
    /// 어떤 픽셀의 blue + 패딩 + 다음 픽셀의 red 를 한 픽셀로 조립한다(세로 줄무늬 + 색 소실).
    ///
    /// flood-fill 마스크는 이 버그에 **둔감하다** — 밝기 판정이 세 채널 모두를 보는데 흰색은 채널이
    /// 밀려도 흰색이라 누끼 경계는 멀쩡해 보인다. 그래서 RGB 값을 직접 단언해야만 잡힌다.
    func testPixelStrideFollowsBitsPerPixelNotSamplesPerPixel() throws {
        let size = 20, inset = 5
        let (fixture, expected) = try colorColumnFixture(size: size, inset: inset)

        // 전제 확인 — 디코드 결과가 실제로 spp/stride 불일치여야 이 테스트가 버그를 덮는다.
        // 툴체인이 다르게 디코드하면 조용히 green 이 되는 대신 여기서 크게 실패해야 한다.
        let decoded = try rep(fixture)
        XCTAssertEqual(decoded.samplesPerPixel, 3, "픽스처가 3 샘플로 디코드돼야 불일치가 재현된다")
        XCTAssertEqual(decoded.bitsPerPixel, 32,
                       "디코더가 픽셀당 4바이트로 패딩해야 spp(3) != stride(4) 불일치가 성립한다")

        let filled = try XCTUnwrap(SpriteLoader.fillingWhiteBackdrop(fixture))
        let out = try rep(filled)
        XCTAssertEqual(out.samplesPerPixel, 4)

        // `colorAt(x:y:)` 가 아니라 raw bitmapData 로 읽는다 — colorAt 은 색 관리를 타서
        // (소스 NSCalibratedRGB → 출력 deviceRGB) 정확한 기대값 단언을 흐린다.
        let dst = try XCTUnwrap(out.bitmapData)
        let dstRow = out.bytesPerRow, dstStride = out.bitsPerPixel / 8
        for y in (inset + 1)...(size - 2 - inset) {
            for x in (inset + 1)...(size - 2 - inset) {
                let p = dst + y * dstRow + x * dstStride
                let c = expected[x]
                XCTAssertEqual(p[0], c.0, "(\(x),\(y)) red — stride 가 밀리면 여기서 어긋난다")
                XCTAssertEqual(p[1], c.1, "(\(x),\(y)) green")
                XCTAssertEqual(p[2], c.2, "(\(x),\(y)) blue")
                XCTAssertEqual(p[3], 255, "(\(x),\(y)) 는 윤곽선 안쪽이라 불투명이어야 한다")
            }
        }
    }

    /// 동기 캐시 경로가 흰 배경 **원본**을 캐싱하면 이후 모든 조회가 그것을 돌려받아 누끼가 영영
    /// 적용되지 않는다. "가방 화면을 두 번 연다"를 단위 테스트로 고정한다.
    func testSynchronousPathDefersToAsyncSoTheFilledImageIsWhatGetsCached() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-\(UUID().uuidString)")
        let store = SpriteStore(directory: dir, fetchWikimon: { _ in
            XCTFail("디스크 캐시가 있으므로 네트워크를 타면 안 된다"); return nil
        })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "Digimental_courage.jpg"
        try borderedFixture().write(to: dir.appendingPathComponent(name))

        // 1) 동기 경로(= ItemIconView.init)는 알파 없는 자산을 캐싱하지 않고 넘긴다.
        XCTAssertNil(SpriteLoader.cachedItemImage(name: name, directory: dir),
                     "흰 배경 원본이 동기 경로에서 캐시에 들어가면 누끼가 영영 적용되지 않는다")

        // 2) async 경로가 누끼를 따서 캐시에 넣는다.
        let asyncResult = await SpriteLoader.itemImage(name: name, store: store)
        let loaded = try XCTUnwrap(asyncResult)
        let loadedRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(loaded.tiffRepresentation)))
        XCTAssertTrue(loadedRep.hasAlpha, "async 경로가 반환한 이미지에는 알파가 있어야 한다")

        // 3) 두 번째 조회(= 가방을 다시 연다)는 **누끼 딴 그 객체**를 돌려받아야 한다.
        XCTAssertTrue(SpriteLoader.cachedItemImage(name: name, directory: dir) === loaded,
                      "두 번째 표시도 원본이 아니라 누끼 딴 이미지여야 한다")
    }
}
