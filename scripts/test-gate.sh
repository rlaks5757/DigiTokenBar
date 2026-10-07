#!/usr/bin/env bash
#
# test-gate.sh — 안정성 가드레일. 커밋/머지 전 수동 실행 (1인 로컬, CI 없음).
#
#   1) scripts/tests python 테스트 전체 통과
#   2) swift test 전체 통과
#   3) "로직 코어" 파일 집합의 라인 커버리지 >= THRESHOLD
#
# 로직 코어 = 결정적으로 단위 테스트 가능한 파일만 포함. ProcessRunner /
# CodexRateLimitsProvider / OAuthLimitsProvider / UpdateChecker / BinaryLocator 는 실제
# 서브프로세스·네트워크·Keychain 의존이라 단위 커버리지 대상에서 제외
# (해당 부분은 파서/순수 헬퍼만 별도로 테스트됨).
#
# ⚠ 알려진 공백 — 배열의 **완전성**은 검증되지 않는다(2026-10-07 실측).
# 아래 로직은 "배열 항목이 리포트에 있는가"(배열→디스크)만 검사한다. 역방향, 즉 "커버리지가
# 낮은 Core/ 파일이 배열에서 빠져 있는가"(디스크→배열)는 아무도 보지 않는다. 그래서 파일을
# 배열에 **넣지 않는 것**으로 임계값을 우회할 수 있다 — 항목을 지우는 건 exit 3 으로 막히지만
# 애초에 추가하지 않는 건 막히지 않는다.
#   Core/ 48개 중 배열 15개. 배열 밖에서 90% 미달이 16개인데, 그중 4개만 위 문단에
#   제외 사유가 적힌 파일이고(ProcessRunner/UpdateChecker/BinaryLocator/OAuthLimitsProvider)
#   나머지 12개는 사유가 문서화돼 있지 않다(CrashReporter 0%, LoginItem ~13%,
#   AppLog ~33%, SingleInstance ~57%, Localization ~70% 등). 배열 밖 라인 총량이 측정 대상(약 6.5천 라인)과 맞먹는데
#   합산 커버리지는 ~82% 로 임계값 90 을 한참 밑돈다.
#   (퍼센트는 타이밍 의존 테스트 때문에 실행마다 소폭 변동한다 — 위 수치는 근사값이다.
#    현재값은 `./scripts/test-gate.sh` 출력과 llvm-cov export 로 직접 재측정해라.)
# 필터 결함이 있던 시절에는 배열이 무력해서 이 축이 무의미했다. 필터를 고친 지금 배열이
# 처음으로 실제 분모가 됐으므로, 어디까지를 로직 코어로 볼지 결정하는 것이 후속 과제다.
# (어떤 파일을 넣고 뺄지는 테스트 정책 판단이라 이 커밋에서 임의로 바꾸지 않았다.)
#
# 커버리지 산출: `llvm-cov export --summary-only` 로 전체를 받아 LOGIC_CORE 파일만 합산한다.
# `llvm-cov report <BIN> ... <소스경로들>` 은 쓰지 않는다 — 바이너리가 플래그보다 앞에 오면
# llvm-cov 가 뒤따르는 소스 경로를 필터가 아니라 *추가 오브젝트 파일*로 해석해 조용히 무시하고
# (소스 필터는 `--sources` 플래그가 필요) 바이너리 전체를 집계한다. 2026-10-07 수정 전까지
# 그래서 테스트 파일까지 섞인 ~81.7% 가 출력됐고, LOGIC_CORE 배열을 고쳐도 숫자가 변하지
# 않았다(= 배열 오타·삭제된 파일을 게이트가 잡지 못했다. 실제로 3개가 오래 썩어 있었다).
# 지금은 배열 항목이 리포트에 없으면 "미검증 항목" 으로 보고하고, 계측 라인이 0인 선언 전용
# 파일(예: 프로토콜·DTO)은 그 사유를 함께 출력한다.
#
# 사용:  ./scripts/test-gate.sh          # 게이트 실행
#        THRESHOLD=90 ./scripts/test-gate.sh   # 임계값 임시 조정
#
set -euo pipefail
cd "$(dirname "$0")/.."

# 실측 93.50%(6127/6553, 2026-10-07) 기준 약 3.5%p 마진. 75 는 필터 결함 시절 바이너리
# 전체(~81.7%)에 맞춰진 값이라 실제 분모에서는 무의미했다.
THRESHOLD="${THRESHOLD:-90}"

LOGIC_CORE=(
  "Sources/DigiTokenBar/Core/CompanionModel.swift"
  "Sources/DigiTokenBar/Core/CollectionWeight.swift"
  "Sources/DigiTokenBar/Core/CompanionStore.swift"
  "Sources/DigiTokenBar/Core/DigimonLineProviding.swift"
  "Sources/DigiTokenBar/Core/LocalizationErrors.swift"
  "Sources/DigiTokenBar/Core/UsageStore.swift"
  "Sources/DigiTokenBar/Core/Models.swift"
  "Sources/DigiTokenBar/Core/UsageCost.swift"
  "Sources/DigiTokenBar/Core/TokenFormatter.swift"
  "Sources/DigiTokenBar/Core/UsageProvider.swift"
  "Sources/DigiTokenBar/Core/LocalUsageReader.swift"
  "Sources/DigiTokenBar/Core/LocalUsageCache.swift"
  "Sources/DigiTokenBar/Core/ModelPricing.swift"
  "Sources/DigiTokenBar/Core/CustomScanRoots.swift"
  "Sources/DigiTokenBar/Core/DigimonData.swift"
)

echo "▶ python 테스트 (scripts/tests)"
python3 -m unittest discover -s scripts/tests

echo
echo "▶ swift test (--enable-code-coverage)"
swift test --enable-code-coverage

PROF=$(find .build -name 'default.profdata' | head -1)
# dSYM 안에도 같은 이름의 DWARF 바이너리가 있어 head -1 이 그걸 집으면 llvm-cov 가 실패한다 → 제외.
BIN=$(find .build -name 'DigiTokenBarPackageTests' -type f ! -path '*.dSYM/*' | head -1)
if [[ -z "$PROF" || -z "$BIN" ]]; then
  echo "✗ 커버리지 산출물(profdata/binary)을 찾지 못했습니다." >&2
  exit 1
fi

# Coverage profile format is tied to the Swift/LLVM toolchain that produced it. Homebrew Swift 6.x
# profiles are newer than the llvm-cov bundled with older Xcode, so prefer the sibling llvm-cov.
SWIFT_TOOL_DIR=$(dirname "$(realpath "$(command -v swift)")")
if [[ -x "$SWIFT_TOOL_DIR/llvm-cov" ]]; then
  LLVM_COV="$SWIFT_TOOL_DIR/llvm-cov"
else
  LLVM_COV=$(xcrun --find llvm-cov)
fi

echo
echo "▶ 로직 코어 커버리지 (임계값 ${THRESHOLD}%)"
# `--sources` 없이 위치 인자로 필터가 안 되므로, 전체를 export 해서 파일별로 합산한다.
# `|| COVER=""` 가 필요하다: `set -e` 아래에서는 python 이 non-zero 로 끝나면 이 대입에서
# 즉시 중단돼 아래 `-z "$COVER"` 분기가 도달 불가해진다. 진단 자체는 python 이 stderr 로
# 직접 쓰므로 어느 쪽이든 출력되고, python 의 종료 코드(예: exit 3)는 여기서 삼켜진다 —
# 이 가드가 더하는 것은 **게이트 고유의 종료 경로**다. 산출 실패를 임계값 미달과 같은
# exit 1 로 정규화하고, 사용자에게 "위 진단을 보라" 는 안내를 붙인다.
COVER=$("$LLVM_COV" export -summary-only -instr-profile "$PROF" "$BIN" 2>/dev/null \
  | python3 scripts/logic_core_coverage.py "${LOGIC_CORE[@]}") || COVER=""
if [[ -z "$COVER" ]]; then
  echo "✗ 커버리지 산출 실패 — 위 진단을 보고 LOGIC_CORE 배열 또는 profdata 를 확인하세요." >&2
  exit 1
fi

echo
# 소수 비교는 awk 로 (bash 정수 비교 회피)
if awk "BEGIN { exit !($COVER >= $THRESHOLD) }"; then
  echo "✓ 게이트 통과 — 로직 코어 라인 커버리지 ${COVER}% >= ${THRESHOLD}%"
else
  echo "✗ 게이트 실패 — 로직 코어 라인 커버리지 ${COVER}% < ${THRESHOLD}%" >&2
  echo "  테스트를 보강하거나, 의도된 하락이면 THRESHOLD 를 조정하세요." >&2
  exit 1
fi
