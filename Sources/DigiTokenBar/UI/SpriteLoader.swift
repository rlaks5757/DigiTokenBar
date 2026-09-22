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
            if let d = try? Data(contentsOf: f), let img = NSImage(data: d) {
                imageCache.setObject(img, forKey: imageKey)
                return img
            }
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
            guard let img = NSImage(data: d) else { continue }   // 디코드 실패 시 다음 후보로 폴백
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
    /// ⚠️ `Digitama.jpg`(550×550, 실측)는 JPEG 라 알파 채널이 없다 — `cropToContent` 가 `hasAlpha`
    /// 로 조기 반환해 캔버스 전체(흰 배경 포함)가 그대로 반환된다(실측: 코너 픽셀 RGB(255,255,255),
    /// hasAlpha=no). 이전 96×96 PNG(콘텐츠 29%, 투명 여백)를 전제로 한 크롭 로직이라 이 자산에는
    /// 적용되지 않음 — 흰 배경 제거는 제품 결정이 필요한 지점(보고서 참고).
    private static var croppedEgg: NSImage?

    /// 크롭 완료분만 동기 반환(미준비면 nil — 동기 크롭 안 함, 히치 방지). 첫 표시 때만 🥚 폴백 후 eggImage 로 교체.
    static func cachedEggImage() -> NSImage? { croppedEgg }

    /// 알 스프라이트 — 로드 + 콘텐츠 크롭(최초 1회 메모이즈). 첫 표시에는 동기 캐시(`cachedEggImage()`)가
    /// 비어 🥚 이모지로 폴백하고, 이 async 경로의 네트워크 왕복이 끝나면 일러스트로 교체된다.
    static func eggImage(store: SpriteStore = .shared) async -> NSImage? {
        if let c = croppedEgg { return c }
        guard let d = await store.eggData(), let img = NSImage(data: d) else { return nil }
        croppedEgg = cropToContent(img)
        return croppedEgg
    }

    /// 비투명(alpha>0) 콘텐츠 경계로 크롭 — 큰 투명 여백 제거. 1회만 수행(메모이즈). 알파 채널이 없는
    /// 이미지(JPEG 등)는 전 픽셀이 불투명으로 읽혀 크롭이 수학적으로 불가능하므로, 픽셀 스캔을 시작하기
    /// 전에 원본을 그대로 조기 반환한다(`croppedEgg` 주석 참고) — 550×550 전수 스캔 낭비 방지.
    /// 주의: 이 조기 반환은 아래 정사각 정규화(210번 줄 근처)까지 함께 건너뛴다. 현재 자산(`Digitama.jpg`)이
    /// 550×550 정사각이라 정사각 정규화가 항등이라 오늘은 무해하지만, 알파 없는 비정사각 자산이 추가되면
    /// (예전 같으면 중앙 정사각 크롭을 받았을 것이) 레터박스로 떨어지므로 이 가드를 재검토해야 한다.
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
/// Gen-V 움직이는 스프라이트(GIF)는 캔버스가 종마다 다르고 정사각이 아니다 — 잭키(#325) 36×66,
/// 피카츄(#25) 50×46, 팬텀(#143) 74×75. 반면 정적 스프라이트는 96×96, 아이템은 30×30 으로 전부
/// 정사각이라 "size×size 로 늘려 채우기"가 정적 경로에서는 아무 증상이 없다가 GIF 경로에서만
/// 왜곡으로 드러났다(잭키 = 가로 1.83배). 두 호출부가 같은 식을 쓰게 여기로 모은다.
enum SpriteFit {
    /// `box`×`box` 정사각 안에 원본 비율을 유지해 맞춘 크기(contentMode .fit — 긴 변이 box 에 닿는다).
    /// 원본 크기가 비었으면(디코드 실패 등) 정사각 폴백 — 0 나눗셈 방지.
    static func size(for pixelSize: CGSize, box: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: box, height: box) }
        let scale = min(box / pixelSize.width, box / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }
}
