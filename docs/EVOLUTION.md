# 디지몬 진화 데이터 (01 + 02 범위)

DigiTokenBar 가 사용하는 **확정 진화 테이블**. 범위는 디지몬 어드벤처 01 + 02(파워디지몬).

> **ID 는 [digi-api.com](https://digi-api.com) 기준이다.** 아래 모든 ID 는 실측 확인했다.
> **이름이 아니라 ID 로 고정한다** — 통용 이름과 API 이름이 다른 경우가 있다(§이름 함정).

---

## 1. 레벨 체계

디지몬의 성장 단계. 포켓몬의 "진화 단계"와 달리 **이름이 붙은 고정 등급**이다.

| # | 레벨 | 한국 표기 | 비고 |
|---|---|---|---|
| 0 | Baby I | 유아기 | 앱에서는 알 부화 직후 |
| 1 | Baby II | 유년기 | |
| 2 | Child | 성장기 | **파트너 기본형** |
| 3 | Adult | 성숙기 | |
| 4 | Perfect | 완전체 | |
| 5 | Ultimate | 궁극체 | 최종 |
| — | Armor | 아머체 | **정규 사다리 밖 분기** |

**중요: 디지몬 진화는 트리가 아니라 순환 그래프다.** 원본 데이터에는
Agumon → Greymon 과 Greymon → Agumon 이 **둘 다** 존재한다.
따라서 데이터를 그대로 쓰면 무한 루프가 된다.

→ **해결: 레벨 단조 증가 필터.** 진화는 레벨 번호가 **증가하는 방향만** 유효하다.
아래 테이블은 이미 이 필터를 적용해 수기로 확정한 결과다.

---

## 2. 정규 진화 라인 (12라인)

### 01 파트너 8라인

| # | Child | Adult | Perfect | Ultimate |
|---|---|---|---|---|
| 1 | Agumon (1) | Greymon (34) | Metal Greymon (169) | War Greymon (202) |
| 2 | Gabumon (16) | Garurumon (33) | Were Garurumon (205) | Metal Garurumon (168) |
| 3 | Piyomon (101) | Birdramon (5) | Garudamon (165) | — |
| 4 | Tentomon (85) | Kabuterimon (35) | Atlur Kabuterimon (Blue) (40) | — |
| 5 | Palmon (81) | Togemon (195) | Lilimon (166) | — |
| 6 | Gomamon (117) | Ikkakumon (124) | Zudomon (96) | — |
| 7 | Patamon (98) | Angemon (3) | Holy Angemon (121) | Seraphimon (384) |
| 8 | Tailmon (83) | — | Angewomon (38) | Holydramon (123) |

> **8번 Tailmon 라인은 Adult 가 없다.** Tailmon 자체가 Adult 급이지만 작중 Child 처럼 다뤄진다.
> 코드에서 **단계 수(k)가 라인마다 다르다**는 전제를 반드시 유지할 것.

### 02 파트너 4라인

| # | Child | Adult | 죠그레스 결과 |
|---|---|---|---|
| 9 | V-mon (349) | XV-mon (358) | → Paildramon |
| 10 | Wormmon (356) | Stingmon (336) | → Paildramon |
| 11 | Hawkmon (399) | Aquilamon (267) | → Silphymon |
| 12 | Armadimon (271) | Ankylomon (266) | → Shakkoumon |

> 02 파트너는 정규 사다리가 Adult 에서 끝난다. Perfect 이상은 **죠그레스로만** 도달한다.

---

## 3. 죠그레스 (Jogress / DNA Digivolution)

**두 개체가 합쳐져 하나가 된다.** 단일 부모 트리로는 표현 불가능한 구조다.

### 테이블 `(A, B) → C`

| A | B | → 결과 | ID | 결과 레벨 |
|---|---|---|---|---|
| XV-mon (358) | Stingmon (336) | Paildramon | 331 | Perfect |
| Tailmon (83) | Aquilamon (267) | Silphymon | 390 | Perfect |
| Ankylomon (266) | Angemon (3) | Shakkoumon | 387 | Perfect |
| War Greymon (202) | Metal Garurumon (168) | Omegamon | 183 | Ultimate |
| Imperialdramon FM (405) | Omegamon (183) | Imperialdramon Paladin Mode | 481 | Ultimate |

**`(A, B)` 는 순서 무관이다.** 조회 시 정렬된 키로 정규화할 것.

### Imperialdramon 체인

```
Paildramon (331) → Imperialdramon Dragon Mode (900, 내부 ID) → Imperialdramon Fighter Mode (405)
                                                                       + Omegamon (183)
                                                                       → Paladin Mode (481)
```

> Paladin Mode 는 **양쪽 부모가 모두 죠그레스 결과물**이다.
> 따라서 "죠그레스 결과가 도감에 졸업 기록으로 남는가"가 도달 가능성을 결정한다.
> → `docs/GAME-DESIGN.md` 참고. **남지 않으면 Paladin Mode 는 영구 도달 불가.**

> **Dragon Mode 는 digi-api ID 가 없다.** 대신 내부 전용 id **900**(900번대는 비어 있어 충돌 없음)을
> 부여해 정식 종으로 추가했다(2026-09-22). 900 은 두 개체가 합쳐지는 죠그레스가 아니라
> **단일 부모 전이**라서 `jogress` 테이블이 아니라 별도 `chain` 테이블(`(from, to)` 두 간선:
> 331→900, 900→405)에 담는다. `DigimonName.isInternalID` 로 digi-api 조회 불가능한 종임을
> 표시한다 — 900 으로 digi-api 를 조회하면 실패하니 런타임 fetch 호출부는 이 플래그로 걸러야 한다.
> 레벨은 Dragon Mode·Fighter Mode 모두 **Ultimate**(원작 설정) — Paildramon(Perfect)에서
> 한 단계 올라가고 Fighter Mode 와 동급이다.

---

## 4. 아머 진화 (Armor)

**디지멘탈(Digimental) 아이템으로 Child 에서 분기한다.** 정규 사다리 밖이다.

| Child | 디지멘탈 | → 아머형 | ID |
|---|---|---|---|
| V-mon (349) | 용기 | Fladramon | 305 |
| V-mon (349) | 성실 | Depthmon | 298 |
| V-mon (349) | 기적 | Magnamon | 315 |
| V-mon (349) | 우정 | Lighdramon | 312 |
| Hawkmon (399) | 사랑 | Holsmon | 401 |
| Hawkmon (399) | 순수 | Shurimon | 389 |
| Armadimon (271) | 지식 | Digmon | 299 |
| Armadimon (271) | 성실 | Submarimon | 337 |
| Patamon (98) | 희망 | Pegasmon | 363 |
| Tailmon (83) | 빛 | Nefertimon | 326 |

> **성실 디지멘탈은 V-mon·Armadimon 양쪽에서 쓰인다** — `(Child, 디지멘탈)` **복합키**로 조회할 것.
> 디지멘탈 단독으로는 결과가 결정되지 않는다.

> ⚠️ **아머 진화를 구현할 사람에게.** `Digimental` case 를 추가하고 `ItemKind` 에 대응 상점
> 아이템만 넣은 채 위 표(및 `Resources/digimon.json` 의 `armor[]` 행)에 결과를 빠뜨려도,
> 현재 가드들은 이를 잡지 못한다 — 로더는 JSON→enum 방향(모르는 문자열)만 막고, enum→JSON
> 방향(존재하는 case 에 대응하는 JSON 행이 없는 경우)은 아무도 보지 않는다. 그 상태에서
> 상점은 여전히 그 디지멘탈을 판매하지만 `DigimonData.armorResult(childID:digimental:)` 는
> 영원히 nil 을 반환한다 — 유저가 재화를 쓰고 아무 효과도 못 받는다. 새 디지멘탈을 추가할
> 때는 case 추가와 JSON 행 추가를 같은 커밋에서 끝내라.

---

## 5. ⚠️ 이름 함정 (실측 발견)

**반드시 ID 로 조회할 것.** 이름 조회가 실패하는 사례:

| 통용 이름 | digi-api 실제 | 증상 |
|---|---|---|
| Halsemon | `Holsmon` (401) | 이름 조회 실패 |
| Atlur Kabuterimon | `Atlur Kabuterimon (Blue)` (40) | 정확 일치 없음 |
| Imperialdramon | `Imperialdramon(Dragon Mode)` | 단독 조회 HTTP 400, **괄호 앞 공백 없음** |
| Imperialdramon FM (405) | `Imperialdramon(Fighter Mode)` | 같은 표기 — 괄호 앞 공백 없음 (2026-09-21 실측) |
| Imperialdramon PM (481) | `Imperialdramon(Paladin Mode)` | 같은 표기 (2026-09-21 실측) |

### 스프라이트 쪽 이름은 또 다르다

도트 스프라이트는 [Wikimon](https://wikimon.net) vpet 이미지를 쓴다.
**digi-api 이름과 Wikimon 파일명이 일치하지 않는다.**

| digi-api | Wikimon 파일명 |
|---|---|
| XV-mon | `Xvmon vpet` |
| War Greymon | `WarGreymon vpet` (공백 없음) |

→ **종별 이름 매핑 테이블을 앱이 직접 갖는다.** 런타임 이름 추론 금지.

---

## 6. 데이터 취급 원칙

| 데이터 | 앱 번들 | 런타임 fetch |
|---|---|---|
| 진화/죠그레스/아머 테이블 (ID·조합 규칙) | ✅ | — |
| 이름 매핑 테이블 | ✅ | — |
| **스프라이트 이미지** | ❌ | ✅ |
| 종 설명·기술·타입 등 | ❌ | ✅ |

**스프라이트는 앱 바이너리·레포에 포함하지 않는다.** 런타임에 받아서 디스크 캐시한다.
이미지 가공(크롭·스케일)도 런타임에 한다.

### 스프라이트 소스 폴백 체인

Wikimon vpet 도트를 **기기 시리즈 우선순위**로 시도한다:

```
vb > ws > xloader   (컬러)
```

- 로스터 **52종 중 48종이 이 3개(vb>ws>xloader) 폴백 체인 안에서 해결**된다.
  나머지 4종(Depthmon·Imperialdramon FM/PM/DM)은 파일명·시리즈가 불규칙해 **고정 파일명**을 쓴다(아래 전수 검증 참고).
- 🚫 **`pen` / `dm` / `dmc` 는 1비트 흑백이다.** 컬러와 섞으면 화풍이 깨진다.
- 도트는 **이미 투명 배경**이다 — 크로마키 처리 불필요.
- 용량 ~1.5KB/종 (47종 전체 68KB).

> **정정 (2026-09-21, 구현 시 실측)** — 스프라이트가 필요한 종은 **48종**이다.
> 47 = 라인 소속 33 + 죠그레스 결과 5 + 아머 결과 9 인데, 여기에
> **Imperialdramon Fighter Mode (405)** 가 빠져 있다. 405 는 정규 라인에 없고
> Paladin Mode 죠그레스의 **입력으로만** 등장해서 위 세 집합 어디에도 안 잡힌다.
> 하지만 화면에 그려지므로 이름 매핑·스프라이트가 필요하다. → 용량도 ~72KB 로 정정.
>
> **재정정 (2026-09-22)** — **49종**으로 늘었다. Imperialdramon Dragon Mode 에
> 내부 전용 id **900**을 부여해 §3 체인의 끊어진 고리(331→405)를 이었다 — 아래 "덤" 항목 참고.
>
> **재정정 (2026-09-22, 아머 결과 3종 추가)** — **52종**으로 늘었다. 52 = 49 +
> Lighdramon(312) + Seraphimon(384) + Holydramon(123) — §4 아머 진화 표에 성실/용기/희망
> 계열 3행이 추가되며 딸려온 결과 종이다. 폴백 체인 안에서 해결되는 종 수도 45 → 48 로
> 함께 갱신한다(신규 3종 전부 기본 vb>ws>xloader 체인으로 해결, 아래 전수 검증 참고).

#### 실검증 결과 (2026-09-21)

실제 요청으로 확인한 사항. 구현 전 반드시 반영할 것.

**1. 시리즈는 별도 경로가 아니라 파일명의 일부다.**

```
https://wikimon.net/images/<h1>/<h2>/<Name>_vpet_<series>.png
예: images/b/b9/Agumon_vpet_vb.png
    images/e/ec/Agumon_vpet_xloader.png
```

`<h1>/<h2>` 는 파일명 MD5 앞 1·2자리에서 나오는 MediaWiki 해시 경로다. 추측 불가 —
파일 페이지나 API 로 해석해야 한다. 썸네일은 `images/thumb/<h1>/<h2>/<파일명>/80px-<파일명>` 형태.

**2. User-Agent 가 없으면 404 가 온다.** 기본 curl/URLSession UA 로는 실패한다.
브라우저 UA 를 명시해야 한다. (이것 때문에 처음 검증이 전부 404 로 나왔다.)

**3. 🚨 문서 제목과 파일명이 다르다 — 매핑 테이블이 필수인 실제 이유.**

| 종 | Wikimon 문서 제목 | 스프라이트 파일명 |
|---|---|---|
| XV-mon | `XV-mon` (하이픈) | `Xvmon_vpet_*` (하이픈 없음) |
| Holsmon | `Holsmon` | `Holsmon_vpet_*` |

`Xvmon` 으로 문서를 열면 **404**, `XV-mon` 으로 파일명을 만들면 **파일 없음**이다.
→ 문서 제목에서 파일명을 파생시키면 깨진다. 위 §5 의 "런타임 이름 추론 금지" 가
이 경우를 가리킨다. **매핑 테이블은 문서 제목과 파일명을 각각 따로 담아야 한다.**

**4. 🚨 스프라이트 파일명 전수 검증 (2026-09-21, 48종 전부 조회)**

`DigimonData.swift` 의 `spriteStem` 48개를 Wikimon API 로 전수 확인했다. **45개는 "공백 제거"
추정이 맞았고, 3개가 틀렸다.** 틀린 3개의 실제 파일명은 추정 규칙으로는 절대 만들 수 없다:

| 종 | 추정(틀림) | 실제 파일명 | 크기 |
|---|---|---|---|
| Depthmon | `Depthmon_vpet_<series>` | `Depthmon_vpet_dark_color.png` | 192×192 |
| Imperialdramon FM (405) | `ImperialdramonFighterMode_vpet_*` | `Imperialdramon_fighter_vpet_vb.png` | 192×192 |
| Imperialdramon PM (481) | `ImperialdramonPaladinMode_vpet_*` | `Imperialdramon_paladin_vpet_vb.png` | 192×192 |

→ `fighter`/`paladin` 은 **소문자 약칭**이고 `Mode` 가 아예 없다. Depthmon 은 시리즈 자리에
`dark_color` 라는 비표준 값이 온다. §5 의 "런타임 이름 추론 금지"를 뒷받침하는 실제 사례다.

> **덤 (2026-09-22 갱신):** `Imperialdramon_DM_vpet_xloader.png` (192×192, 10,360 bytes) 실측 확인.
> digi-api 에 쓸 수 있는 Dragon Mode ID 가 없어서 **내부 전용 id 900**을 부여해 데이터 테이블에
> 정식 추가했다(§3 Imperialdramon 체인). `vb` 폴백은 404 라 `spriteSeriesPin`으로 `xloader`
> 하나만 고정한다(Depthmon·Imperialdramon FM/PM 과 동일 처리).

> **덤 (2026-09-22, 아머 결과 3종 추가 전수 조회)** — §4 아머 진화 표에 추가된 Lighdramon(312)·
> Seraphimon(384)·Holydramon(123) 을 포함해 로스터 52종 전체를 MD5 유도 URL 로 전수
> 재조회했다: **52/52 성공, 실패 0.** 신규 3종은 전부 `vb` 시리즈에서 바로 해결되어
> `spriteSeriesPin` 이 불필요하다(기본 폴백 체인 그대로):
>
> | 종 | 파일명 | 포맷/크기 |
> |---|---|---|
> | Lighdramon | `Lighdramon_vpet_vb.png` | PNG 192×192 RGBA |
> | Seraphimon | `Seraphimon_vpet_vb.png` | PNG 180×168 RGBA |
> | Holydramon | `Holydramon_vpet_vb.png` | PNG 186×168 RGBA |
>
> 전부 매직바이트로 실제 PNG 파일임을 확인했고 육안으로 종이 맞는지도 확인했다.
>
> **🚨 이름 함정 — 어느 표기가 등록돼 있는지는 종마다 다르다.** `Raidramon`(일본명)으로
> 조회하면 digi-api 0건·Wikimon vpet 404 인데, `Lighdramon`(영문명)으로는 digi-api 312·
> vpet 200 이 뜬다. 반대로 `Magnadramon` 은 404, `Holydramon` 이 200 이다. → §5 "이름 함정"과
> 같은 부류의 함정이 종 이름 자체에도 있다 — **"없음"으로 판정하기 전에 일본명·영문명 양쪽을
> 모두 조회해야 한다.** 이번 조사에서 실제로 두 번 이 함정에 걸렸다.

**5. 확인된 시리즈 가용성 (표본)**

| 종 | vb | xloader |
|---|---|---|
| Agumon | ✅ | ✅ |
| Tailmon | ✅ | ✅ |
| XV-mon | ✅ | ✅ |
| Holsmon | ✅ | ❌ |
| Gabumon | ❌ | ✅ |
| WarGreymon | ❌ | ✅ |

→ 폴백 체인이 실제로 필요하다. 단일 시리즈로는 로스터가 채워지지 않는다.
