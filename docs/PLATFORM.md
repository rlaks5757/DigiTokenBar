# 플랫폼 전략

**현재: macOS 전용. 윈도우 포팅은 나중에 하되, 지금부터 경로 로직만 분리해둔다.**

---

## 1. 현황 — 왜 지금은 macOS 전용인가

upstream(PokeTokenBar)이 macOS 전용이고, 그 제약을 그대로 물려받았다.
`Package.swift`: `platforms: [.macOS(.v14)]`

### Apple 전용 프레임워크 의존 (실측)

| 프레임워크 | 파일 수 | 용도 |
|---|---|---|
| `AppKit` | 9 | 메뉴바(`NSStatusItem`), 팝오버, 이미지 |
| `SwiftUI` | 10 | UI 전반 |
| `Security` | 3 | Keychain |
| `UserNotifications` | 2 | 알림 |
| `ServiceManagement` | 1 | 로그인 항목 |
| `LocalAuthentication` | 1 | 인증 |
| 그 외 | — | `QuartzCore`, `ImageIO`, `CryptoKit`, `UniformTypeIdentifiers` |

> ⚠️ **"SwiftUI 니까 크로스플랫폼"이 아니다.** 앱 진입점이 `NSApplicationDelegateAdaptor` 이고
> 메뉴바를 `NSStatusItem` 으로 직접 다룬다. 표준 `MenuBarExtra` 는 **성능 문제로 의도적으로
> 버렸다**(`DigiTokenBarApp.swift:11-12` 주석). 애초에 윈도우에는 "메뉴바" 개념이 없다.

---

## 2. 실제로 이식이 어려운 지점

**UI 가 아니라 사용량 엔진의 경로 탐색이 핵심이다.**

ANALYSIS.md 는 "8,500줄 사용량 엔진이 공짜로 따라온다"고 봤는데,
그건 **디지몬 전환 기준이지 OS 전환 기준이 아니다.**

### 경로 하드코딩 실측 — 8개 파일 22곳

| 파일 | 건수 |
|---|---|
| `Localization.swift` | 7 |
| `LocalAdditionalUsageProvider.swift` | 6 |
| `BinaryLocator.swift` | 2 |
| `CodexRateLimitsProvider.swift` | 2 |
| `AppLog.swift` / `CrashReporter.swift` / `LocalUsageReader.swift` / `UpdateChecker.swift` | 각 1 |

### ✅ 다행인 점: 패턴이 일관된다

전부 `home` 기준 상대 경로이고, 문자열이 흩어진 게 아니라 몇 개 함수에 모여 있다.

```swift
home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
home.appendingPathComponent("Library/Application Support/Claude")
```

### ✅ 도트 디렉터리는 OS 무관하게 동일하다

`.claude` · `.codex` · `.copilot` · `.kiro` · `.hermes` — 윈도우에서도 같은 이름이다
(`%USERPROFILE%\.claude`). **실제로 갈라지는 건 2종류뿐이다:**

| 갈라지는 것 | macOS | Windows |
|---|---|---|
| 앱 데이터 | `~/Library/Application Support/X` | `%APPDATA%\X` |
| 바이너리 탐색 | `/opt/homebrew/bin`, `/usr/local/bin` | `PATH` 탐색 |

---

## 3. 결정: 지금 할 것 / 하지 않을 것

### ✅ 지금 한다 — 경로 로직 분리 (Phase 1에 포함)

경로를 한 곳(`PlatformPaths` 등)으로 모은다. **macOS 구현만 넣고 윈도우 분기는 비워둔다.**

```
PlatformPaths.appSupport(for: "Cursor")   // mac: ~/Library/Application Support/Cursor
                                          // win: %APPDATA%\Cursor   (미구현)
PlatformPaths.homeDot(".claude")          // 양쪽 동일
```

**근거:** 지금 하면 리팩터링 1회다. Phase 1~4 를 다 쌓은 뒤에 하면 그때 늘어난 코드까지
같이 건드려야 한다. 비용이 가장 싼 시점이 지금이다.

### 🚫 지금 하지 않는다 — UI/시스템 추상화

UI(`AppKit`/`NSStatusItem`), Keychain, 알림, 로그인 항목은 **미리 추상화하지 않는다.**

**근거:** 윈도우 UI 를 뭘로 구현할지(Electron/Tauri/WinUI…) 정하지 않은 상태에서
인터페이스부터 만들면 추측성 설계가 된다. 실제 포팅 시점에 정하는 게 맞다.
→ CLAUDE.md 코딩 원칙 2번("요청되지 않은 유연성을 추가하지 않는다")과 같은 판단.

---

## 4. 나중에 포팅할 때

**재사용 가능성 정리:**

| 계층 | 재사용 |
|---|---|
| 진화/죠그레스/아머 데이터·규칙 | ✅ 그대로 ([`EVOLUTION.md`](./EVOLUTION.md), [`GAME-DESIGN.md`](./GAME-DESIGN.md)) |
| 토큰 집계·비용 계산 (순수 Swift) | ✅ 대부분 |
| 경로 탐색 | 🔄 `PlatformPaths` 에 윈도우 분기 추가 |
| UI 전체 | ❌ 재작성 |
| Keychain·알림·로그인 항목 | ❌ 재작성 |

> **현실적으로 "포팅"보다 "같은 게임 규칙으로 새 앱"에 가깝다.**
> 그래서 게임 규칙과 데이터를 문서로 확정해두는 것 자체가 포팅 준비다.
> Swift 는 윈도우를 지원하지만 `AppKit`/`SwiftUI` 가 없다.
