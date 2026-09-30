# 보관함 ↔ 활성 전환 설계 감사

작성: 2026-09-30 · 수정: 2026-09-30 · 상태: **축 A 구현 완료** / 축 B·C 미해결 · 근거: 코드 직접 확인 (추정 아님)

---

## 0. 요약

**보관 개체 회수 경로가 2026-09-30 열렸다** (축 A1 "교체" 구현).

**이전 상태 (2026-09-30 이전):**

회수 경로가 닫혀 있었다. 보관 개체를 꺼내려면 **졸업(고급 1.875B)** 또는 **알 구매(1B)** 중 하나를 치러야 했다.
코드가 이를 자백했었다 — `CompanionStore.swift:1418` 이전 주석:

> "보증을 지키는 유일한 방법은 알을 먼저 부화/소비시키는 것이므로,
> **지금은 거절만 하고 제품 결정을 미룬다.**"

즉 `#1a(보관함)` 기능은 **넣는 쪽만 완성되고 꺼내는 쪽은 미결인 채** 출시됐다.
사용자가 겪은 증상 3개는 전부 이 하나의 미결에서 파생했다.

**현재 상태 (2026-09-30 이후):**

보관 개체는 **언제든 무료로** 꺼낼 수 있다. 막는 조건은 `isHatching` 하나뿐이다.
- 활성 개체가 있으면 **교체** — 꺼낸 개체가 활성이 되고 기존 활성이 보관함으로 들어간다. 아무것도 잃지 않는다.
- 알을 품고 있으면 **보증 파킹** — 확정 알의 등급과 미리 뽑아둔 종을 맡겨 두고 다음 알에 복원한다.
  보증이 겹치면 `sortRank` 로 **높은 쪽만** 남는다(충돌 시 pre-roll 은 양방향 폐기).
- 꺼낸 개체는 보관될 때의 `stageIndex` 에서 이어 자란다.

세이브 버전은 올리지 않았다 — 순수 추가 필드 + lenient 디코딩이라 구세대 파일이 그대로 열린다.

---

## 1. 사용자가 실제로 겪은 것 (2026-09-30)

| # | 증상 | 사용자 말 |
|---|---|---|
| 1 | 고르기에 이미 가진 아르마몬만 뜸 | "이미 아르마몬이 있는데 왜 고르기가 있는거 밖에 없으며" |
| 2 | 방생 안 했는데 후보로 뜸 | "방생한것도 아닌데 왜?" |
| 3 | 부화 후 보관 개체로 전환 불가 | "다시 아르마몬으로 전환이 안되네?" |

---

## 2. 사실 확인 — 세 화면이 쓰는 기준이 다르다

### 2.1 도감 (`dexSpecies`, CompanionStore.swift:388)

`state.dex` + `state.active` + **`state.stored`** (`:409` 루프) 를 합친다.

→ **보관 개체도 도감에 뜬다.** 사용자 화면의 "도감 4종"에 아르마몬이 있는 게 맞다.
   (초기 진단에서 필자가 `state.dex` 배열만 보고 "도감에 없다"고 한 것은 **오류**였다.
    사용자가 스크린샷으로 정정했다.)

### 2.2 동행 기록 (`dexEntries`, :334)

`state.dex` + 합성된 `activeDexEntry` 만. **`stored` 를 의도적으로 제외**한다 (`:313` 주석).

> "이 목록은 종 로그가 아니라 '지금 키우는 개체 + 이미 졸업한 개체'의 개체 단위 동행 기록이다"

→ 아르마몬은 졸업한 적이 없고 지금 키우는 중도 아니므로 **안 뜨는 게 맞다.**

### 2.3 고르기 (`babyPicks`, :1614)

`state.ownsSpecies(baseID)` 로 거른다. `ownsSpecies` (CompanionModel.swift:750) 는
`dex` + `stored` + `active` 를 전부 본다 — **도감과 같은 넓은 기준.**

→ 보관 중인 아르마몬이 후보가 된다. **이게 증상 1·2의 직접 원인.**

### 정리

| 화면 | 소스 | 묻는 질문 | 아르마몬 |
|---|---|---|---|
| 도감 4종 | dex + active + **stored** | 거쳐본 종인가 | ✅ 뜸 (맞음) |
| 동행 기록 1마리 | dex + active | **끝까지 키웠나** | ❌ 안 뜸 (맞음) |
| 고르기 | `ownsSpecies` (= 도감과 동일) | 지금 보유 중인가 | ⚠️ **뜸 (틀림)** |

**세 화면 다 내부적으로는 일관되다. 문제는 고르기가 "보유"를 물었어야 할 자리에
"보유"를 물은 게 아니라, 애초에 "자격"을 물었어야 했다는 것.**

---

## 3. 결함 진단 — 보관 개체 회수 경로가 닫혀 있었다 (2026-09-30 이전)

### 3.1 옛 게이트 (`canRetrieveStored`, 변경 전)

```
guard state.active == nil, !isHatching, state.eggTier == nil
```

세 조건을 **동시에** 만족해야 꺼낼 수 있었다.

### 3.1+ 현재 게이트 (`canRetrieveStored`, CompanionStore.swift:1432)

```swift
func canRetrieveStored(_ id: String) -> Bool {
    guard !isHatching else { return false }
    return state.stored.contains { $0.id == id }
}
```

**이제 `isHatching` 조건만 막는다.** 활성 개체가 있어도, 보증 알을 품고 있어도 꺼낼 수 있다 —
두 경우는 "거절"이 아니라 **분기**다 (§3.3 참고).

### 3.2 활성 슬롯 제어 경로 (변경 후)

`state.active = nil` 쓰기 지점:

| 위치 | 함수 | 용도 |
|---|---|---|
| CompanionStore.swift:791 | `graduate()` | 졸업 — 새 알 받음 |
| CompanionStore.swift:1381 | `buyEgg()` | 알 구매 — 새 알 생김 |
| CompanionStore.swift:1468 | `retrieveStored()` | 보관 개체 꺼내기 — 교체/파킹 처리 |

**`retrieveStored`의 두 분기:**
- **교체** (`active != nil` 로 들어올 때): 현재 활성을 보관함에 넣고(`state.stored.append`) 꺼낸 개체를 새운다. 기존 활성의 육성 상태는 그대로 보존.
- **빈 슬롯** (`active == nil` 이고 알이 있을 때): 품고 있던 알의 보증과 미리뽑아둔 종을 `parkEggGuarantee()`로 맡기고(`parkedEggTier`), 알 관련 필드는 비운다.

**`active = nil` 쓰기를 늘릴 때 주의:**
`parkEggGuarantee()`(CompanionStore.swift:1500)의 docstring(1490-1499)에 따르면,
파킹 자리가 항상 비어 있다는 전제가 있어야 파킹값이 조용히 덮어쓰기되지 않는다.
`active = nil` 경로가 하나라도 더 생기면 `restoreParkedEggGuarantee()`처럼 `sortRank` 병합을 넣어야 한다.

### 3.3 구현 후 흐름 — 교체와 파킹

꺼내기 게이트가 `isHatching` 하나뿐이므로:

```
┌─ 활성 있음 ─ 꺼내기 ──→ 교체(현재 활성 → 보관함, 꺼낸 개체 → 활성)
│             (무료)
│
├─ 활성 없고 알 보증 있음 ─ 꺼내기 ──→ 파킹(보증 → parkedEggTier, 
│                            (무료)     pre-roll → parkedPendingHatchID)
│                                      ↓ 다음 알로 돌아올 때 restoreParkedEggGuarantee()
│
└─ 활성 없고 보증 없음 ─ 꺼내기 ──→ 정상 회수(알 비우기)
                         (무료)
```

**전제: 부화 중(`isHatching`)에만 거절.** 정상 회수라 확인 UI 없다 (제품 결정: 즉시 교체).

**교체 시 동작:**
- 꺼낸 개체는 보관될 때의 `stageIndex`에서 이어 자란다(CompanionStore.swift:1452에서 보관 시점 저장).
- 보증·인큐베이션(`eggUsage`) 같은 알 필드는 꺼낸 개체와 무관 (교체 분기에는 알이 없으므로).

**파킹 분기 (`active == nil && eggTier != nil`):**
- 보증과 pre-roll을 맡김 (CompanionStore.swift:1463 호출).
- 알은 비워짐 (CompanionStore.swift:1464).
- 다음 알이 생기면(부화, 새 구매) `CompanionState.restoreParkedEggGuarantee()`로 복원 (CompanionModel.swift:778).
- 충돌 시(파킹 보증 + 새로 산 보증) `sortRank` 비교로 **높은 쪽만** 남음. pre-roll은 양쪽 버림 (CompanionModel.swift:789).

### 3.3+ 과거 문제 해석 (§3.3 "순환한다" 이전 상태)

**과거 추적 (진단 시점 코드):**

```
활성 있음 ──────────────→ 보관함 잠김 (active 게이트)
   │
   ├─ 졸업(1.875B) ──→ 슬롯 빔 ──→ 꺼낼 수 있음 ✅ (유일한 정상 경로)
   │
   └─ 알 구매(1B) ──→ 활성이 보관함으로 (또 쌓임)
                       └→ 알 상태 + eggTier
                            ├─ 보증 알이면 → 잠김 (eggTier 게이트)
                            └─ 보증없음 알이면 → **꺼낼 수 있다** ✅
                                 (대가 = 알 값 1B + 그 알 자체)
                       └→ 부화 → 또 활성 있음 → 잠김 (원점)
```

> **정정 (advisor 지적, 코드 재확인함)**: 필자는 처음 이 경로를 "1B 태우고 **인큐베이션
> 진행분도 버린다**"고 적었으나 **틀렸다.** `buyEgg` 가 구매 시점에 이미 `eggUsage = 0`
> 으로 리셋한다(CompanionStore.swift:1389 이전). 그래서 직후 `retrieveStored` 의 
> `eggUsage = 0`은 **no-op** 이다. 실제 대가는 **알 값 1B + 그 알** 이며, 
> 버려지는 진행분은 없다.

**고정됨** (2026-09-30): 순환이 아니라 유료 탈출구였고, 지금은 그것도 필요 없어졌다.

**보관함은 여전히 용량 제한이 없다** (`maxStored` 없음). 무제한 누적 압력이 있어서, 
교체 기능이 있어도 대량 `buyEgg` 로 쌓이는 걸 막지 못한다 
(세이브 필드 추가 문제 아니므로 이번에 안 건드림).

### 3.4 증상 3의 상태 변화

**이전 상태** (부화 완료 후, active 게이트로 차단):
- `active = 399` (호크몬) → **거절함**
- `eggTier = nil` (보증은 부화로 소진됨)
- `stored = [271 아르마몬]`
- 사용자 화면에 `storageBlockedActive` 같은 문구 보임.
- 회수 유일 경로: **호크몬 졸업(1.875B)**

**현재 상태** (부화 완료 후, 교체 분기 실행):
- 호크몬을 꺼내기 버튼이 "자리 바꾸기"로 표시됨 (CompanionStore.swift:1534 `storageRetrieveLabel`).
- 누르면: 호크몬이 활성, 아르마몬이 보관함으로 교체.
- 호크몬 진화·졸업 계속 가능.
- 아르마몬 육성 상태는 보관될 당시 그대로 보존 (CompanionStore.swift:1458 `buyEgg`와 같은 방식).

---

## 4. 증상 1·2 의 진짜 뿌리

고르기는 **"다시 소환할 자격"** 을 물어야 한다. 그런데 `ownsSpecies` 는
**"지금 보유 중인가"** 를 답한다. 보관 중인 개체는:

- 이미 가지고 있다 → 복제할 이유가 없다
- 꺼내면 된다 → **그런데 꺼낼 수가 없다 (§3)**

**고르기가 막힌 회수 경로의 우회로 역할을 하게 됐다.** 다만 우회가 아니라 **복제**다 —
고르기로 아르마몬을 부화시키면 보관함에 하나, 활성에 하나로 **두 마리**가 된다.

비교: `hasJogressPartnerRecord` (`:1092`) 는 같은 종류의 자격 질문에
**`state.dex` 만** 본다 (`!isReleased && !isArmored && chainOrder.contains`).
즉 프로젝트 안에 **좁은 자격 기준의 선례가 이미 있다.**

메모리 `ownership-and-partner-eligibility-diverge` 가 경고한 함정이
다른 축에서 재발한 것이다.

---

## 5. 해결책 (축별 구현 상태)

### 축 A — 보관 개체 회수 (§3) — **구현 완료** ✅

**선택 안:**

| 안 | 내용 | 비용 | 위험 |
|---|---|---|---|
| **A1** | **활성 ↔ 보관 교체(swap) 허용** | 중 | `activeGeneration`·`isHatching` 경합 주의. 세이브 스키마 무변경 |
| A2 | 활성 방생 경로 추가 | 중 | 영구 손실이라 확인 UI 필요 |
| A3 | 그대로 두고 명시 | 소 | 보관함이 계속 단방향 |

**선택: A1** (2026-09-30 구현됨).

**세이브 스키마 영향:**
- **버전 상수는 올리지 않았다** — `currentSaveVersion`(=2, 디스크)도 `schemaVersion`(=4, 전송)도 diff 에 없다.
  디스크 쪽 로드 게이트는 **하드 동등 비교 + `.legacy` 백업 + 새 출발**이고 마이그레이션 계층이 없어서,
  올리면 살아 있는 세이브가 버려진다.
- 파킹 필드(`parkedEggTier`, `parkedPendingHatchID`, `parkedPendingHatchIsUserPick`)를
  **이번에 새로 추가**했다(CompanionModel.swift:657-659). 순수 추가 필드이고 lenient 디코딩이
  흡수하므로 버전 없이 안전하다 — 구세대 파일은 세 필드가 없는 상태로 정상 해석된다
  (`testSaveWithoutParkedFieldsDecodesAsNothingParked` 가 `.legacy` 백업 미생성까지 단언).
- `SaveTransfer.sanitized`(CompanionStore.swift 라인 번호가 아니라 SaveTransfer.swift:215)에서
  보증 불변식 처리:
  - 현재 알: `active != nil` 이면 `eggTier` 버림 (SaveTransfer.swift:228)
  - 파킹한 알: `parkedEggTier` 는 `active != nil` 과 공존 가능 (정상, SaveTransfer.swift:234-237)
  - 무만족 보증(전설·capture_rate_ceiling nil) 단계 필터 (SaveTransfer.swift:250-253)

**구현 상세:**
- `canRetrieveStored()` (CompanionStore.swift:1432): `isHatching` 만 체크
- `retrieveStored()` (CompanionStore.swift:1447): 두 분기 구현
  - **교체 분기** (line 1454): 현재 활성을 보관함에 추가 (`state.stored.append`)
  - **파킹 분기** (line 1459): `parkEggGuarantee()` 호출 (CompanionStore.swift:1500)
- `parkEggGuarantee()` (CompanionStore.swift:1500): 보증·pre-roll을 `parkedEggTier` 계열로 이전
- `restoreParkedEggGuarantee()` (CompanionModel.swift:778): 다음 알이 생길 때 복원, 충돌 시 `sortRank` 병합
- `storageRetrieveLabel` (CompanionStore.swift:1534): 교체 시 "자리 바꾸기" 표시
- `storedRetrieveBlockReason()` (CompanionStore.swift:1520): `isHatching` 만 반환, active/eggTier 메시지 제거

### 축 B — 고르기 후보 기준 (§4) — **미해결**

| 안 | 내용 | 비용 | 결과 |
|---|---|---|---|
| **B1** | 후보를 **졸업 이력**(`state.dex`, `hasJogressPartnerRecord` 선례) 기준으로 | 소 | 보관·활성 종 제외 → 복제 불가 |
| B2 | 진입점만 숨김 (`eggTier != nil` 일 때) | 소 | 증상만 가림, 뿌리 남음 |
| B3 | 고르기 기능 제거 | 대 | 테스트 848줄 + 세이브 필드 제거 = v3 영역 |

**현재:** `babyPicks` (CompanionStore.swift:1675)는 여전히 `state.ownsSpecies`를 쓴다 (line 1680).
A1을 구현해도 복제 유인이 없어지진 않으므로 B1과 함께 진행할 것을 권장.

**B1 구현 시 결정 포인트:**

`state.dex` 는 **세 종류**의 항목을 담는다(졸업 / 방생 `isReleased` / 아머 `isArmored`).

| 항목 종류 | 후보에 넣나 | 근거 |
|---|---|---|
| 졸업 | ✅ 넣는다 | 이론의 여지 없음 |
| 아머 기록 | ❌ 뺀다 | 아머는 표시 오버레이지 키운 라인이 아니다 |
| **방생** | **❓ 사용자 결정** | 아래 |
| 지금 보관·활성 중 | ❌ 뺀다 | 복제 방지 — B1 의 핵심. `storedSpecies`/`activeID` 필터 추가 필요 |

**"방생 축"이 미결정이다.** `hasJogressPartnerRecord`(CompanionStore.swift:1092)는 
`!entry.isReleased` 로 방생을 **뺀다**. 그러나 고르기 관점에서 방생한 종은 
**다시 뽑고 싶은 가장 강한 사례**다(놓아줬는데 되찾고 싶은 경우). 
죠그레스 술어를 그대로 베끼면 **기능의 존재 이유인 사례를 막는다.**

메모리 `ownership-and-partner-eligibility-diverge` 가 경고하는 바로 그 지점이다.

**B1 형태:** `state.dex` 기반 필터 + 보관/활성 제외 + 방생 포함 여부 선택.

> ⚠️ `ownsSpecies` **자체는 건드리지 않는다.** `representativeSpeciesID`(CompanionStore.swift:202, CompanionModel.swift:806)
> 가 쓰고 있어 바꾸면 대표 선택이 깨진다. `babyPicks` 안에서만 기준을 바꾼다.

### 축 C — 도감 라벨 (§2)

보관 개체가 "도감"에 뜨는 건 수집 화면으로서 자연스럽다. **변경 불필요.**
단 A1·B1 을 하면 이 축은 저절로 무해해진다.

---

## 6. 적용 상태

### 축 A (회수 경로) — 완료 ✅

2026-09-30 구현. 사용자는 지금 당장 보관 개체를 꺼낼 수 있다.

### 축 B (고르기 후보) — 대기 중

A1과 함께 진행할 것을 권장하되, 방생 축 제품 결정이 필요.

### 축 C (도감 라벨) — 필요 없음

보관 개체가 도감에 뜨는 건 수집 화면으로서 자연스럽다. 변경 불필요.

---

## 7. 미결 항목

1. **축 B: 방생 포함 여부** — 사용자가 결정해야 함.
2. **보관함 용량 제한** — 현재 무제한. `maxStored` 필드를 추가하면 세이브 v3 진입. 
   (단, `buyEgg` 로 이미 무제한 누적 가능하므로 이번 변경(교체)이 만든 새 문제는 아님.
   다만 교체가 누적을 더 쉽게 만드는 건 사실.)
3. **`active = nil` 쓰기 지점 증가 시** — `parkEggGuarantee()`에 `sortRank` 병합 추가 필요
   (현재 전제: 파킹 자리는 항상 비어 있음).

---

## 8. 지금 당장 사용자가 할 수 있는 것

**보관함 버튼에서 꺼내고 싶은 개체를 선택하면 된다.**
- 활성이 비어 있으면 "꺼내기" → 꺼낸 개체를 세운다.
- 활성에 개체가 있으면 "자리 바꾸기" → 호크몬은 보관함으로, 꺼낸 개체는 활성으로.

아르마몬의 육성 상태는 보관될 때 그대로 보존되어 있다.

---

## 부록 — 확인한 코드 위치

### 구현 후 현재 위치 (2026-09-30)

| 대상 | 파일 | 라인 | 용도 |
|---|---|---|---|
| `dexSpecies` | CompanionStore.swift | 388 | 도감(종 단위, stored 포함) |
| `dexEntries` | CompanionStore.swift | 334 | 동행 기록(개체 단위, stored 제외) |
| `ownsSpecies` | CompanionModel.swift | 750 | 보유 여부 판정(dex+stored+active) |
| `babyPicks` | CompanionStore.swift | 1675 | 고르기 후보(여전히 ownsSpecies 사용) |
| `canRetrieveStored` | CompanionStore.swift | 1432 | 꺼내기 게이트(`isHatching` 만) |
| `retrieveStored` | CompanionStore.swift | 1447 | 보관 개체 꺼내기(교체/파킹 분기) |
| `parkEggGuarantee` | CompanionStore.swift | 1500 | 보증 파킹(빈 슬롯 분기에서만) |
| `storedRetrieveBlockReason` | CompanionStore.swift | 1520 | 차단 메시지(`isHatching` 만) |
| `storageRetrieveLabel` | CompanionStore.swift | 1534 | 버튼 라벨("꺼내기" vs "자리 바꾸기") |
| `buyEgg` | CompanionStore.swift | 1381 | 알 구매(활성 → 보관) |
| `graduate` | CompanionStore.swift | 791 | 졸업(활성 = nil) |
| `releaseStored` | CompanionStore.swift | 1563 | 보관 전용 방생 |
| `restoreParkedEggGuarantee` | CompanionModel.swift | 778 | 보증 복원(알 상태 전환 시) |
| `hasJogressPartnerRecord` | CompanionStore.swift | 1092 | 죠그레스 자격(narrow 기준의 선례) |
| `sanitized` | SaveTransfer.swift | 215 | 세이브 정규화(보증 불변식 처리) |

### 구버전 상태 (삭제됨)

| 내용 | 이전 위치 | 상태 |
|---|---|---|
| 제품 결정 미룸 자백 | CompanionStore.swift:1418 | 코드에서 제거, 이 문서에 과거 기록으로 보존(§0/§3.3+) |
| 3중 게이트 (active/isHatching/eggTier) | - | 이제 단일 게이트(`isHatching`) + 분기(교체/파킹) |
| `storageBlockedActive` 메시지 | - | 제거(교체 분기이므로 거절이 아님) |
