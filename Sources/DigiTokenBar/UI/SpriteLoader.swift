import AppKit
import CryptoKit

/// 디지몬 스프라이트를 런타임에 받아 로컬(Application Support)에 캐시. 레포/번들에 미포함.
actor SpriteStore {
    static let shared = SpriteStore()
    /// 종 비의존 범용 디지타마(알) 아트 — Wikimon 실측: HTTP 200, 550×550, image/jpeg, 111450 bytes.
    static let eggFilename = "Digitama.jpg"
    private var mem: [String: Data] = [:]
    private var memOrder: [String] = []   // LRU 순서(최근 접근이 뒤). 상한 초과 시 앞(오래된 것)부터 evict
    // 원본 바이트의 LRU 상한 — 도감 한 페이지(24칸)보다 넉넉히 유지하되,
    // 세션 중 종 변경으로 무한 누적되지 않게 한다. NSImage 캐시는 SpriteLoader 가 별도로 관리한다.
    //
    // ⚠️ 이건 **바이트 크기가 아니라 항목 수** 상한이다. 현재 구성은 항목마다 크기가 크게 다르다:
    // vpet 스프라이트 52종 × ~7KB, 디지멘탈 아이템 아트 9종 × ~680KB, 알 1종 × ~111KB
    // (디지멘탈·알 모두 Wikimon 일러스트/사진 원본, 실측). 합쳐 62개라 상한(64) 안에 들지만,
    // **여유는 슬롯 2칸**(62/64)이고 무게는 균등하지 않다. 사진 크기의 자산 부류를 하나 더 추가하려면
    // 이 숫자가 아니라 바이트 기준 상한을 먼저 검토할 것.
    private let memLimit = 64
    nonisolated let directory: URL
    /// Wikimon 요청 실행 — 기본은 실제 네트워크. 테스트가 주입해 오프라인 경계를 강제할 수 있다.
    /// `URLResponse` 를 반환 타입에 넣지 않는 이유: Swift 6.1.2(CI)에서 Sendable 진단이 갈릴 수 있어,
    /// 상태 코드 판정은 이 클로저 밖(fetchWikimon)에서 끝낸다.
    private let fetchWikimon: @Sendable (URLRequest) async -> Data?

    init(directory: URL? = nil, fetchWikimon: (@Sendable (URLRequest) async -> Data?)? = nil) {
        let d = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar/wikimon-sprites")
        self.directory = d
        self.fetchWikimon = fetchWikimon ?? Self.performWikimonRequest
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }

    /// 실제 네트워크 요청 — 200 + 비어있지 않은 응답만 성공으로 본다.
    private static func performWikimonRequest(_ request: URLRequest) async -> Data? {
        guard let (d, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { return nil }
        return d
    }

    /// Wikimon 은 MediaWiki 파일 해시 경로(`<h[0]>/<h[0:2]>/<파일명>`, h = md5(파일명))로 이미지를 서빙한다.
    /// User-Agent 없이 요청하면 404 를 준다(실측) — 헤더까지 포함해 네트워크 없이 요청 전체를 검증할 수 있게
    /// `URLRequest` 를 반환한다(기존 `spriteURL` 설계 의도를 이어받음).
    static func wikimonRequest(filename: String) -> URLRequest {
        let hash = Insecure.MD5.hash(data: Data(filename.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let h1 = String(hash.prefix(1))
        let h2 = String(hash.prefix(2))
        let url = URL(string: "https://wikimon.net/images/\(h1)/\(h2)/\(filename)")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 정적 디지몬 스프라이트 후보 1개 — mem → disk → Wikimon. 폴백 체인의 각 단계가 이 함수 하나를 거친다.
    /// 캐시 키가 파일명 자체라 폴백 체인이 캐시에서도 그대로 성립한다.
    func data(filename: String) async -> Data? {
        if let d = mem[filename] { touch(filename); return d }
        let file = directory.appendingPathComponent(filename)
        if let d = try? Data(contentsOf: file) { remember(filename, d); return d }
        guard let d = await fetchWikimon(Self.wikimonRequest(filename: filename)) else { return nil }
        try? d.write(to: file, options: .atomic)   // torn write 방지 — 크래시/강제종료 시 손상 캐시가 남지 않게
        remember(filename, d)
        return d
    }

    /// 후보 파일명을 순서대로 시도해 첫 성공을 채택(vb > ws > xloader 폴백 체인). 전부 실패하면
    /// nil(뷰가 이모지 폴백).
    func data(filenames: [String]) async -> Data? {
        for filename in filenames {
            if let d = await data(filename: filename) { return d }
        }
        return nil
    }

    /// 종 → Wikimon 스프라이트 후보 파일명. actor 의 static 은 기본이 nonisolated 라 별도 표시가
    /// 필요 없다 — `DigimonData` 도 nonisolated 라 호출부의 actor 격리와 무관하게 쓸 수 있다.
    static func filenames(for speciesID: Int) -> [String] {
        DigimonData.name(for: speciesID)?.spriteFilenames ?? []
    }

    /// 알 스프라이트(정적, 종 비의존) — mem → disk → Wikimon 폴백 체인은 `data(filename:)` 이 이미
    /// 처리하므로 여기서 다시 구현하지 않는다. 첫 표시에는 캐시가 비어 nil(뷰가 🥚 이모지로 폴백)이고,
    /// 네트워크 왕복이 끝나면 일러스트로 교체된다 — 정상 동작이며 조건부 실패가 아니다.
    func eggData() async -> Data? {
        await data(filename: Self.eggFilename)
    }

    /// in-memory 캐시에 넣고 LRU 상한 유지(#H1) — 세션 중 종이 여러 번 바뀌어도 무한 성장 방지.
    private func remember(_ key: String, _ data: Data) {
        mem[key] = data
        touch(key)
        while memOrder.count > memLimit {
            let old = memOrder.removeFirst()
            mem.removeValue(forKey: old)
        }
    }
    /// 접근/삽입 키를 최근(뒤)으로 이동 — 활성 종이 evict 되지 않게 하는 LRU.
    private func touch(_ key: String) {
        if let i = memOrder.firstIndex(of: key) { memOrder.remove(at: i) }
        memOrder.append(key)
    }
}

@MainActor
enum SpriteLoader {
    static let cacheDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar/wikimon-sprites")
    }()

    /// 동기 시드와 async 로드가 NSImage 를 공유해 파일 읽기와 이미지 객체 생성을 반복하지 않는다.
    /// 키는 디렉터리를 포함한 파일 경로다. countLimit 은 퇴출 기준이며 엄격한 메모리 상한은 아니다.
    static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// 종 → Wikimon 스프라이트 후보 파일명(vb > ws > xloader 폴백 체인). 이름 매핑이 없으면 빈 배열
    /// (호출부가 nil/이모지로 폴백). 실제 로직은 `SpriteStore` 에 있다(actor 격리와 무관하게 재사용).
    nonisolated static func filenames(for speciesID: Int) -> [String] {
        SpriteStore.filenames(for: speciesID)
    }

    /// 메모리·디스크 캐시에 이미 있으면 동기 반환(네트워크 없음). 후보 파일명을 순서대로 조회해
    /// 첫 히트를 채택 — 폴백 체인이 캐시 조회에서도 그대로 성립한다.
    static func cachedImage(filenames: [String], directory: URL = cacheDir) -> NSImage? {
        for filename in filenames {
            let f = directory.appendingPathComponent(filename)
            let imageKey = f.path as NSString
            if let img = imageCache.object(forKey: imageKey) { return img }
            guard let d = try? Data(contentsOf: f), let img = NSImage(data: d) else { continue }
            // 알파 없는 자산(흰 배경 JPEG)은 여기서 캐싱하지 않고 건너뛴다. 원본을 캐시에 넣으면 이후
            // 모든 조회가 그 흰 배경 원본을 돌려받아 **누끼가 영영 적용되지 않는다** — 이게 건너뛰는
            // 주된 이유다. 부차적으로, 이 경로는 **동기**이고 `ItemIconView.init` 의
            // `State(initialValue:)` 안에서 불려 flood-fill(900×900 기준 15~21ms) 만큼 뷰 init 이
            // 멈춘다. async 경로에 넘긴다.
            guard NSBitmapImageRep(data: d)?.hasAlpha ?? true else { continue }
            imageCache.setObject(img, forKey: imageKey)
            return img
        }
        return nil
    }

    /// Wikimon 정적 스프라이트 — 후보 파일명(폴백 체인)을 순서대로 시도해 첫 성공을 채택.
    static func image(filenames: [String], store: SpriteStore = .shared) async -> NSImage? {
        // 캐시 히트를 전체 후보에서 먼저 훑는다 — 뒤 후보(ws/xloader)로 이미 확정된 종은 앞 후보(vb)를
        // 매번 다시 요청해 헛된 404 를 반복하면 안 된다(같은 .task 가 재실행될 때마다 재현).
        if let img = cachedImage(filenames: filenames, directory: store.directory) { return img }
        for filename in filenames {
            let imageKey = store.directory.appendingPathComponent(filename).path as NSString
            guard let d = await store.data(filename: filename) else { continue }
            // await 중 같은 파일명의 다른 행이 로드를 끝냈으면 그 객체를 재사용한다.
            if let img = imageCache.object(forKey: imageKey) { return img }
            // 흰 배경 JPEG 이면 여기서 누끼를 딴다 — 동기 경로(`cachedImage`)가 이 자산을 캐싱하지 않고
            // 넘기므로, 처리된 픽셀을 캐시에 넣는 건 이 경로의 책임이다. `Task.detached` 인 이유:
            // `SpriteLoader` 는 @MainActor 라 `nonisolated` 만으로는 호출자(메인 액터)에서 그대로 돌아
            // 대상 10종 전부 합쳐 174ms(한 장 15~21ms, 800×800 이 28ms 로 최대)를 메인 스레드에서
            // 쓴다. NSImage 는 Sendable 이 아니라 경계를 `Data` 로 둔다.
            let filled = await Task.detached { fillingWhiteBackdrop(d) }.value
            guard let img = NSImage(data: filled ?? d) else { continue }   // 디코드 실패 시 다음 후보로 폴백
            imageCache.setObject(img, forKey: imageKey)
            return img
        }
        return nil
    }

    /// 아이템 스프라이트(디지멘탈 등, `ItemKind.spriteName` 이 이미 완전한 Wikimon 파일명이다) —
    /// 디지몬 정적 스프라이트와 같은 파일명 기반 캐시/fetch 경로(`data(filename:)`)를 그대로 탄다.
    /// 별도 네트워크 진입점을 두지 않는다 — `data(filename:)` 가 유일한 fetch 경로라는 구조를
    /// 유지해야 cold-miss 가드(`testColdCacheMissFallsThroughToTheInjectedFetcherOnly`)가 이
    /// 경로도 계속 덮는다.
    static func cachedItemImage(name: String, directory: URL = cacheDir) -> NSImage? {
        cachedImage(filenames: [name], directory: directory)
    }

    /// 아이템 스프라이트 — 런타임 로드(+캐시). 미제공/실패면 nil(뷰가 이모지로 폴백).
    static func itemImage(name: String, store: SpriteStore = .shared) async -> NSImage? {
        await image(filenames: [name], store: store)
    }

    /// 콘텐츠 경계로 1회 크롭해 캐시 → 상점·홈 등 모든 크기에서 재사용한다.
    ///
    /// `Digitama.jpg`(550×550, 실측)는 JPEG 라 알파 채널이 없어 예전에는 `cropToContent` 가 조기
    /// 반환하고 캔버스 전체(흰 배경 포함)가 그대로 나왔다. 이제 `eggImage` 가 크롭 전에
    /// `fillingWhiteBackdrop` 로 알파를 입히므로 크롭과 정사각 정규화가 정상 동작한다.
    private static var croppedEgg: NSImage?

    /// 크롭 완료분만 동기 반환(미준비면 nil — 동기 크롭 안 함, 히치 방지). 첫 표시 때만 🥚 폴백 후 eggImage 로 교체.
    static func cachedEggImage() -> NSImage? { croppedEgg }

    /// 알 스프라이트 — 로드 + 콘텐츠 크롭(최초 1회 메모이즈). 첫 표시에는 동기 캐시(`cachedEggImage()`)가
    /// 비어 🥚 이모지로 폴백하고, 이 async 경로의 네트워크 왕복이 끝나면 일러스트로 교체된다.
    static func eggImage(store: SpriteStore = .shared) async -> NSImage? {
        if let c = croppedEgg { return c }
        guard let d = await store.eggData() else { return nil }
        // 알 아트도 흰 배경 JPEG 이다. 여기서 알파를 입히면 `cropToContent` 의 `hasAlpha` 가드가 저절로
        // 통과해 콘텐츠 bbox 크롭 + 정사각 정규화가 **수정 없이** 그대로 돈다(그 가드는 누수 폴백으로
        // 원본이 돌아온 경우의 degrade 경로로 계속 살아 있다).
        let filled = await Task.detached { fillingWhiteBackdrop(d) }.value
        guard let img = NSImage(data: filled ?? d) else { return nil }
        croppedEgg = cropToContent(img)
        return croppedEgg
    }

    /// 흰 배경 일러스트(JPEG)에 알파를 입히는 순수 변환 — **모서리에서 시작하는 flood-fill** 이다.
    /// 전역 흰색 키잉이 아니다: 알 몸통이 흰색/크림색이고 `Digimental_light` 는 화면의 67.9% 가 흰색이라,
    /// 밝기만 보고 전부 지우면 피사체에 구멍이 뚫린다. 네 모서리에서만 번지고 어두운 윤곽선에서 멈추므로
    /// 윤곽선 **안쪽**의 흰색은 보존된다.
    ///
    /// 경계는 `Data -> Data?` 다(`NSImage` 가 아니다). 호출부가 `Task.detached` 로 메인 액터 밖에 내보내는데
    /// `NSImage` 는 Sendable 이 아니라 그 경계를 넘지 못한다 — `Data` 는 양방향 모두 Sendable 이라
    /// Swift 6.1.2(CI)/6.3.3(로컬) 어느 쪽에서도 같은 진단을 받는다.
    ///
    /// 이미 알파가 있는 입력(디지몬 vpet PNG 52종)은 `nil` 을 반환해 호출부가 원본 바이트를 그대로 쓰게 한다.
    nonisolated static func fillingWhiteBackdrop(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data), !rep.hasAlpha else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let src = rep.bitmapData else { return nil }
        // planar rep 는 `bitmapData` 레이아웃이 완전히 달라 아래 포인터 산술이 통하지 않는다.
        // 8비트 샘플도 전제 — 16비트 rep 이면 채널당 2바이트라 임계값 비교가 무의미해진다.
        guard !rep.isPlanar, rep.bitsPerSample == 8 else { return nil }
        // 아래 `p[0..2]` = R,G,B 는 **skip-last 8비트 정수** 레이아웃을 전제한다. alphaFirst 면 같은
        // 자리가 A,R,G 라 색이 통째로 밀리고, floatingPointSamples 면 바이트가 float 조각이라 임계값
        // 비교 자체가 무의미하다. 둘 다 flood-fill 마스크로는 드러나지 않는다(흰색은 채널이 밀려도
        // 밝게 읽혀 경계가 멀쩡해 보인다) — 여기서 막지 않으면 출력에서야 발견된다. 기존 폴백대로 nil.
        guard !rep.bitmapFormat.contains(.alphaFirst),
              !rep.bitmapFormat.contains(.floatingPointSamples) else { return nil }
        // ⚠️ 픽셀 stride 는 `samplesPerPixel`(샘플 **개수**)이 아니라 `bitsPerPixel / 8`(바이트 수)다.
        // ImageIO 는 3샘플 JPEG 을 워드 정렬해 돌려준다 — 실측: 대상 자산 10개 전부 spp=3 인데
        // bitsPerPixel=32(stride 4)다. spp 로 걸으면 픽셀마다 1바이트씩 오른쪽으로 밀려 엉뚱한
        // 바이트를 읽는다(윤곽선을 배경으로 오판해 피사체가 지워진다).
        let srcStride = rep.bitsPerPixel / 8, srcRow = rep.bytesPerRow
        guard srcStride >= 3 else { return nil }

        // 배경 후보 판정 — RGB 세 채널이 전부 임계값 이상. JPEG 링잉 때문에 `== 255` 로는 테두리 한 줄도
        // 걸러지지 않는다(실측). 250~210 구간에서 결과가 거의 같아 중앙값 240 을 쓴다.
        let threshold: UInt8 = 240
        func isBright(_ x: Int, _ y: Int) -> Bool {
            let p = src + y * srcRow + x * srcStride
            return p[0] >= threshold && p[1] >= threshold && p[2] >= threshold
        }

        // 네 모서리를 시드로 하는 BFS. 방문 배열은 Bool 한 장이면 충분하다 — 큐에 들어간 시점에
        // 방문 표시를 해 같은 픽셀이 중복으로 큐에 쌓이지 않게 한다.
        var background = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] where isBright(x, y) {
            let i = y * w + x
            if !background[i] { background[i] = true; queue.append(i) }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let ni = ny * w + nx
                if !background[ni], isBright(nx, ny) { background[ni] = true; queue.append(ni) }
            }
        }

        // 누수 폴백 — 채워진 픽셀이 캔버스의 85% 를 넘으면 테두리가 열려 있어 피사체까지 먹은 것이다.
        // 현재 자산 10개는 전부 닫혀 있지만(실측), 앞으로 열린 자산이 들어오면 아이콘이 통째로 사라지는 대신
        // 오늘과 같은 동작(흰 배경)으로 degrade 한다.
        guard queue.count <= (w * h) * 85 / 100 else { return nil }

        // ⚠️ 원본 rep 는 `samplesPerPixel == 3` 이라 알파를 쓸 자리가 없다 — `p[3] = 0` 은 **다음 픽셀의
        // red** 를 덮어쓴다(출력이 노이즈가 될 때까지 드러나지 않는다). 4 샘플 rep 를 새로 할당해 RGB 를
        // 복사하고 알파는 거기에만 쓴다.
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let dst = out.bitmapData else { return nil }
        let dstRow = out.bytesPerRow, dstStride = out.bitsPerPixel / 8
        for y in 0..<h {
            for x in 0..<w {
                let s = src + y * srcRow + x * srcStride
                let d = dst + y * dstRow + x * dstStride
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]
                d[3] = background[y * w + x] ? 0 : 255
            }
        }
        return out.representation(using: .png, properties: [:])
    }

    /// 비투명(alpha>0) 콘텐츠 경계로 크롭 — 큰 투명 여백 제거. 1회만 수행(메모이즈). 알파 채널이 없는
    /// 이미지(JPEG 등)는 전 픽셀이 불투명으로 읽혀 크롭이 수학적으로 불가능하므로, 픽셀 스캔을 시작하기
    /// 전에 원본을 그대로 조기 반환한다 — 전수 스캔 낭비 방지.
    /// 이 가드는 호출부가 `fillingWhiteBackdrop` 를 먼저 태우게 된 뒤로도 살아 있다: 누수 폴백(85% 초과)이나
    /// 디코드 실패로 **알파가 안 입혀진 원본이 그대로 넘어오는** 경우가 남아 있고, 그때는 오늘과 같은
    /// 동작(크롭 없이 원본)으로 degrade 해야 한다.
    private static func cropToContent(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return image }
        guard rep.hasAlpha else { return image }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // 콘텐츠 bbox 를 정사각(긴 변 기준)으로 확장해 중앙 정렬 — 알 콘텐츠는 28×30(세로가 김)이라 그대로
        // 크롭하면 SpriteView 의 size×size 정사각 프레임에서 가로로 늘어나 뚱뚱해진다. 정사각 크롭이면 비율 보존.
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let side = min(max(bw, bh), min(w, h))
        let sx = max(0, min(minX - (side - bw) / 2, w - side))
        let sy = max(0, min(minY - (side - bh) / 2, h - side))
        guard let cg = rep.cgImage?.cropping(to: CGRect(x: sx, y: sy, width: side, height: side))
        else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// 스프라이트를 정사각 프레임에 넣을 때의 **비율 유지** 기하 — 팝오버(SpriteView)와 메뉴바가 공유한다.
///
/// 구 PokéAPI 움직이는 스프라이트(GIF)는 캔버스 크기가 종마다 달랐고 정사각도 아니었다.
/// 반면 정적 스프라이트는 96×96, 아이템은 30×30 으로 전부 정사각이라 "size×size 로 늘려 채우기"가
/// 정적 경로에서는 아무 증상이 없다가 GIF 경로에서만 세로로 긴 종의 가로 왜곡으로 드러났다.
/// 두 호출부가 같은 식을 쓰게 여기로 모은다.
enum SpriteFit {
    /// `box`×`box` 정사각 안에 원본 비율을 유지해 맞춘 크기(contentMode .fit — 긴 변이 box 에 닿는다).
    /// 원본 크기가 비었으면(디코드 실패 등) 정사각 폴백 — 0 나눗셈 방지.
    static func size(for pixelSize: CGSize, box: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: box, height: box) }
        let scale = min(box / pixelSize.width, box / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }
}
