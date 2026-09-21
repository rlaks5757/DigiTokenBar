import Foundation

/// OS 마다 갈리는 경로만 모아둔 단일 지점. **현재 macOS 구현만 있다.**
///
/// 윈도우 포팅 시 분기가 필요한 건 두 종류뿐이다(`docs/PLATFORM.md`):
/// - 다른 앱의 데이터 디렉토리 — mac `~/Library/Application Support/X` · win `%APPDATA%\X`
/// - 바이너리 탐색 디렉토리 — mac 고정 경로 목록 · win `PATH` 탐색
///
/// `.claude` `.codex` `.copilot` `.kiro` `.hermes` 같은 도트 디렉토리는 윈도우에서도 이름이
/// 같아 분기 대상이 아니다. 각 호출부가 `home.appendingPathComponent(".claude")` 형태로
/// 그대로 둔다.
///
/// ## `AppStatePaths` 와의 관계
/// 둘은 대상이 다르다. `AppStatePaths` 는 **우리 앱 자신의** 상태 디렉토리로,
/// `DTB_STATE_DIR` 오버라이드와 디렉토리 생성까지 책임지며 `FileManager` 의
/// `.applicationSupportDirectory` API 로 해석한다(샌드박스 컨테이너를 따라감).
/// 반면 `appSupport(home:for:)` 는 **다른 앱의** 데이터 위치를 호출부가 넘긴 `home` 기준으로
/// 계산만 한다(생성하지 않음). 테스트가 가짜 home 을 주입할 수 있어야 하므로 여기서
/// home 을 스스로 해석하지 않는다.
enum PlatformPaths {
    /// 다른 앱의 데이터 디렉토리. `home` 은 호출부가 넘긴다 — 테스트 주입 지점 보존.
    /// - Parameter component: 앱 이름 또는 그 아래 하위 경로 (예: `"Cursor/User/globalStorage"`)
    static func appSupport(home: URL, for component: String) -> URL {
        home.appendingPathComponent("Library/Application Support").appendingPathComponent(component)
    }

    /// 사용자 Library 하위 디렉토리(로그 등). 우리 앱 자신의 산출물 위치라
    /// `FileManager` API 로 해석한다 — 샌드박스 컨테이너를 따라가야 하기 때문.
    static func userLibrary(_ component: String) -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(component)
    }

    /// 패키지·버전 매니저의 bin/shim 디렉토리 — 바이너리 절대경로 탐색과 자식 프로세스
    /// PATH 보강이 공유하는 목록. `home` 은 문자열 경로(`NSHomeDirectory()` 등).
    /// 윈도우에서는 이 목록 대신 `PATH` 탐색으로 갈린다.
    static func toolSearchDirectories(home: String) -> [String] {
        [
            "/opt/homebrew/bin",                 // Homebrew (Apple Silicon)
            "/usr/local/bin",                    // Homebrew (Intel) / npm prefix
            "\(home)/.local/share/mise/shims",   // mise (shims 모드)
            "\(home)/.asdf/shims",               // asdf
            "\(home)/.volta/bin",                // Volta
            "\(home)/.bun/bin",                  // Bun
            "\(home)/.npm-global/bin",           // npm prefix=~/.npm-global
            "\(home)/.local/bin",
            "/usr/bin",
        ]
    }
}
