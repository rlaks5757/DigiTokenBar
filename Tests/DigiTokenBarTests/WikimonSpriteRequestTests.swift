import XCTest
@testable import DigiTokenBar

/// `fetchWikimon` 클로저는 `@Sendable` 이라 테스트 쪽 캡처도 격리 경계를 넘나든다 — 단순 `var`
/// 캡처는 Swift 6 strict concurrency 에서 컴파일 에러다. 호출 횟수·인자를 actor 뒤에 모아 안전하게 관찰한다.
private actor FetchRecorder {
    private(set) var requestedFilenames: [String] = []
    private(set) var callCount = 0
    private(set) var lastRequest: URLRequest?

    func record(_ filename: String, request: URLRequest? = nil) {
        requestedFilenames.append(filename)
        callCount += 1
        if let request { lastRequest = request }
    }
}

// Wikimon 스프라이트 요청 생성 + 폴백 체인을 오프라인으로 검증한다.
//
// Wikimon 은 MediaWiki 파일 해시 경로(`<h[0]>/<h[0:2]>/<파일명>`, h = md5(파일명))로 이미지를
// 서빙하고, User-Agent 없는 요청은 404 를 준다(팀 리드 실측) — 이 파일이 지키는 두 축이다.
// 새 파일로 분리한 이유: `SpriteImageCacheTests.swift` 는 PokeAPI 시절 키 포맷(`25-s.png`)을
// 전제로 하고, 다른 coder 가 그 파일에서 animated 축을 병행 제거 중이라 겹치지 않기 위함이다.
final class WikimonSpriteRequestTests: XCTestCase {

    // MARK: - MD5 유도 경로 (고정 벡터)

    /// [실측] `printf 'Agumon_vpet_vb.png' | md5` → b92b77ca... → 첫 글자 b, 첫 두 글자 b9.
    func testWikimonRequestDerivesAgumonHashPath() {
        let request = SpriteStore.wikimonRequest(filename: "Agumon_vpet_vb.png")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://wikimon.net/images/b/b9/Agumon_vpet_vb.png")
    }

    /// [실측] `printf 'Vmon_vpet_vb.png' | md5` → 4e2dd90f... → 첫 글자 4, 첫 두 글자 4e.
    /// 추측이 틀렸던 사례: 얼핏 그럴듯해 보이는 `/9/9c/` 는 **아니다** — 잘못된 유도 규칙(예: 파일명이
    /// 아닌 다른 문자열을 해싱)이 우연히 그럴듯한 경로를 내는 것도 잡기 위한 음성 단언.
    func testWikimonRequestDerivesVmonHashPathAndRejectsAPlausibleWrongGuess() {
        let request = SpriteStore.wikimonRequest(filename: "Vmon_vpet_vb.png")
        let path = request.url?.absoluteString
        XCTAssertEqual(path, "https://wikimon.net/images/4/4e/Vmon_vpet_vb.png")
        XCTAssertNotEqual(path, "https://wikimon.net/images/9/9c/Vmon_vpet_vb.png")
    }

    // MARK: - User-Agent 헤더 (이 작업의 핵심 가드)

    /// User-Agent 없이 요청하면 Wikimon 이 404 를 준다 — 오프라인 테스트로는 절대 못 잡는 실패 모드라
    /// 요청 생성 시점에 헤더가 실제로 붙는지 직접 단언한다.
    func testWikimonRequestCarriesABrowserUserAgent() {
        let request = SpriteStore.wikimonRequest(filename: "Agumon_vpet_vb.png")
        let ua = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertFalse(ua?.isEmpty ?? true)
        XCTAssertFalse(ua?.contains("CFNetwork") ?? true,
                       "기본 URLSession UA 그대로면 Wikimon 이 404 를 준다 — 브라우저 UA 로 덮어써야 한다")
    }

    // MARK: - 알(egg) 스프라이트 요청

    /// 알 스프라이트는 종 비의존 범용 파일(`Digitama.jpg`)을 요청한다 — 실제 네트워크로 왕복 검증한
    /// URL(https://wikimon.net/images/3/3d/Digitama.jpg)과 정확히 일치하는지, User-Agent 헤더가
    /// 붙는지를 고정한다. "결과가 nil 이 아니다" 만으로는 파일명이 틀려도 통과할 수 있어 부족하다.
    func testEggDataRequestsTheExactDigitamaURLWithUserAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-egg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            await recorder.record(request.url!.lastPathComponent, request: request)
            return Data([0x01])
        })
        let data = await store.eggData()
        XCTAssertEqual(data, Data([0x01]))
        let capturedRequest = await recorder.lastRequest
        XCTAssertEqual(capturedRequest?.url?.absoluteString,
                       "https://wikimon.net/images/3/3d/Digitama.jpg")
        let ua = capturedRequest?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertFalse(ua?.isEmpty ?? true)
    }

    // MARK: - 폴백 체인 순서

    /// 후보 파일명을 순서대로 시도해 첫 성공을 채택 — 앞선 후보가 전부 실패해야 다음으로 넘어간다.
    func testFallbackChainTriesCandidatesInOrderAndStopsAtFirstHit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            let filename = request.url!.lastPathComponent
            await recorder.record(filename)
            return filename == "Vmon_vpet_ws.png" ? Data([0x89]) : nil   // vb 실패, ws 성공
        })
        let filenames = ["Vmon_vpet_vb.png", "Vmon_vpet_ws.png", "Vmon_vpet_xloader.png"]
        let data = await store.data(filenames: filenames)
        XCTAssertEqual(data, Data([0x89]))
        let requested = await recorder.requestedFilenames
        XCTAssertEqual(requested, ["Vmon_vpet_vb.png", "Vmon_vpet_ws.png"],
                       "vb 성공했다면 ws/xloader 는 시도하면 안 되고, ws 에서 멈췄다면 xloader 는 시도하면 안 된다")
    }

    /// 모든 후보가 실패하면 nil — 뷰가 이모지로 폴백할 수 있게.
    func testFallbackChainReturnsNilWhenAllCandidatesFail() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-allfail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            await recorder.record(request.url!.lastPathComponent); return nil
        })
        let data = await store.data(filenames: ["A_vpet_vb.png", "A_vpet_ws.png", "A_vpet_xloader.png"])
        XCTAssertNil(data)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 3, "실제로 3개 후보 전부 네트워크까지 시도했는지 — 조기 종료로 위장 통과하면 안 된다")
    }

    /// 빈 후보 목록(이름 매핑 없음)은 네트워크를 아예 타지 않고 즉시 nil.
    func testEmptyFilenameListNeverCallsTheFetcher() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            await recorder.record(request.url!.lastPathComponent); return nil
        })
        let data = await store.data(filenames: [])
        XCTAssertNil(data)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - 실네트워크 폴백 차단 (구조적 가드)

    /// [핵심] mem·disk 캐시가 전부 미스면 주입된 fetcher 로만 떨어진다 — 실제 URLSession 요청으로
    /// 새는 우회로가 없다는 것을 "fetcher 가 실제로 호출됐다"로 직접 고정한다. 이 단언이 없으면
    /// 오프라인 유지가 "디스크에 파일이 우연히 있어서"가 될 수 있다(팀 리드가 지적한 미해결 부채).
    func testColdCacheMissFallsThroughToTheInjectedFetcherOnly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-structural-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            await recorder.record(request.url!.lastPathComponent); return Data([0x01])
        })
        let data = await store.data(filename: "Agumon_vpet_vb.png")
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1, "디스크·메모리 미스는 반드시 주입된 fetcher 를 거쳐야 한다 — 다른 네트워크 경로로 새면 안 된다")
        XCTAssertEqual(data, Data([0x01]))
    }

    /// 디스크에 이미 있으면 fetcher 를 아예 부르지 않는다(오프라인 캐시 히트가 네트워크를 안 타는지).
    func testWarmDiskCacheNeverCallsTheFetcher() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wikimon-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let filename = "Agumon_vpet_vb.png"
        try Data([0xAB]).write(to: dir.appendingPathComponent(filename))
        let recorder = FetchRecorder()
        let store = SpriteStore(directory: dir, fetchWikimon: { request in
            await recorder.record(request.url!.lastPathComponent); return nil
        })
        let data = await store.data(filename: filename)
        XCTAssertEqual(data, Data([0xAB]))
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - 캐시 디렉토리 분리

    /// 새 캐시 디렉토리가 PokeAPI 시절 경로와 겹치지 않는다 — 캐시가 찬 개발 머신에서 포켓몬
    /// 그림이 디지몬 ID 로 조용히 표시되는 사고를 막는다.
    @MainActor
    func testCacheDirectoryIsIsolatedFromThePokeAPIEra() {
        XCTAssertFalse(SpriteLoader.cacheDir.path.hasSuffix("DigiTokenBar/sprites"),
                       "PokeAPI 시절 캐시 디렉토리와 겹치면 안 된다")
        XCTAssertTrue(SpriteLoader.cacheDir.path.hasSuffix("DigiTokenBar/wikimon-sprites"))
    }

    // MARK: - DigimonName.spriteFilenames 연동

    /// 폴백 없는 종(spriteSeriesPin 지정)은 후보가 1개뿐이다 — Depthmon 등.
    func testPinnedSeriesYieldsExactlyOneCandidate() {
        let name = DigimonName(apiName: "Depthmon", spriteStem: "Depthmon", spriteStemVerified: true,
                                spriteSeriesPin: "dark_color")
        XCTAssertEqual(name.spriteFilenames, ["Depthmon_vpet_dark_color.png"])
    }

    /// 폴백 있는 일반 종은 vb > ws > xloader 순서로 3개.
    func testUnpinnedSeriesYieldsTheFullFallbackChainInOrder() {
        let name = DigimonName(apiName: "Agumon", spriteStem: "Agumon", spriteStemVerified: true)
        XCTAssertEqual(name.spriteFilenames,
                       ["Agumon_vpet_vb.png", "Agumon_vpet_ws.png", "Agumon_vpet_xloader.png"])
    }
}
