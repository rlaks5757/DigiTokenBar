#!/usr/bin/env bash
#
# test-gate.sh — 안정성 가드레일. 커밋/머지 전 수동 실행 (1인 로컬, CI 없음).
#
#   1) scripts/tests python 테스트 전체 통과
#   2) swift test 전체 통과
#   3) "로직 코어" 파일 집합의 라인 커버리지 >= THRESHOLD
#
# 로직 코어 = 결정적으로 단위 테스트 가능한 파일만 포함. ProcessRunner / CcusageProvider /
# CodexRateLimitsProvider / OAuthLimitsProvider / UpdateChecker / BinaryLocator 는 실제
# 서브프로세스·네트워크·Keychain 의존이라 단위 커버리지 대상에서 제외
# (해당 부분은 파서/순수 헬퍼만 별도로 테스트됨).
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
# `|| true` 가 필요하다: `set -e` 아래에서는 python 이 non-zero 로 끝나면 이 대입에서
# 즉시 중단돼 아래 진단이 영구히 출력되지 않는다(사유 없는 exit 1 만 남는다).
# 스크립트가 사유를 stderr 로 이미 찍었으므로 여기서는 종료만 책임진다.
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
