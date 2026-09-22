# DigiTokenBar

AI 코딩 도구의 토큰 사용량을 macOS 메뉴바에서 확인하고, 그 사용량으로 파트너 디지몬을 키우는 앱.

[chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) 의 포크입니다.

---

## ⚠️ 현재 상태 — 디지몬 전환 진행 중

**디지몬 전환이 진행 중입니다.** 현재 상태를 솔직하게 적어둡니다.

| 영역 | 상태 |
|---|---|
| 토큰 집계 · 메뉴바 · 설정 | 동작함 (upstream 기능 그대로) |
| 수집 · 육성 · 진화 시스템 | 동작함 — **디지몬 52종** (번들 JSON) |
| UI 문자열 · 도감 | 디지몬화 완료 (7개 언어) |
| 죠그레스 · 아머 진화 | **설계 완료, 미구현** |
| 상세 패널 | 미동작 (PokéAPI 스키마 잔존) |

지금 빌드해서 실행하면 디지몬이 부화합니다. 죠그레스 · 아머 진화와 상세 패널은 아직입니다.

설계 문서는 먼저 작성해 뒀습니다:

- [`docs/EVOLUTION.md`](docs/EVOLUTION.md) — 진화 트리, 죠그레스 · 아머 진화 대응표
- [`docs/GAME-DESIGN.md`](docs/GAME-DESIGN.md) — 수집 · 육성 규칙, 토큰 경제
- [`docs/PLATFORM.md`](docs/PLATFORM.md) — 플랫폼 전략 (윈도우 포팅 검토)

---

## 기능

메뉴바에 오늘 사용한 토큰량과 파트너 스프라이트를 표시합니다. 클릭하면 팝오버가 열리고
**홈 · 상점 · 가방 · 도감** 네 탭에서 도구별 사용량 · 한도 · 월간 추세와 파트너 상태를 볼 수 있습니다.

토큰을 쓰면 알이 부화하고, 계속 쓰면 성장하고 진화합니다. 졸업하면 도감에 등록되고 새 알이 시작됩니다.

설정에서 난이도(토큰 요구량 배율) · 플로팅 펫 · 알림 등을 조정할 수 있습니다.

### 읽어오는 도구

Claude Code · Codex · Cursor · Copilot · Gemini · Grok · Antigravity · Kiro ·
OpenCode · Hermes Agent · Aside · omp · Pi

대부분 각 도구의 로컬 로그(JSONL) · SQLite DB 를 직접 읽습니다. 별도 설정 없이 설치된 도구를
자동 인식합니다. Cursor 만 예외로, 로그인돼 있으면 대시보드 API 를 우선 쓰고 로컬 DB 를 폴백으로 씁니다.

---

## 빌드

배포판(Homebrew · 릴리스 다운로드)은 **아직 없습니다.** 소스에서 직접 빌드해야 합니다.

**요구사항**: macOS 14+, Swift 6.0+ (Xcode 16+)

```bash
git clone https://github.com/rlaks5757/DigiTokenBar.git
cd DigiTokenBar
swift build
```

### 앱으로 설치

```bash
./scripts/build-app.sh
```

이 스크립트는 `.app` 번들을 조립한 뒤 **실행 중인 인스턴스를 종료하고 `/Applications` 에 설치**합니다.

서명 인증서가 없으면 ad-hoc 서명이라 빌드할 때마다 Keychain 허용 프롬프트가 뜰 수 있습니다.
줄이려면 먼저 자체 서명 인증서를 만드세요:

```bash
./scripts/create-signing-cert.sh
```

### 테스트

```bash
./scripts/test-gate.sh
```

python 테스트 → swift 테스트(1164개) → 로직 코어 커버리지(≥75%) 순으로 검사합니다.

---

## 라이선스

MIT. 원저작권은 [chattymin](https://github.com/chattymin) 에게 있으며 `LICENSE` 에 그대로 유지했습니다.

디지몬(Digimon)은 반다이(Bandai) · 토에이 애니메이션(Toei Animation)의 상표입니다.
이 프로젝트는 비공식 · 비영리 팬 프로젝트이며 권리자와 제휴 관계가 없습니다.
