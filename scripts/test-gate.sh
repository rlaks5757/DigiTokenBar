#!/usr/bin/env bash
#
# test-gate.sh — 안정성 가드레일. 커밋/머지 전 수동 실행 (1인 로컬, CI 없음).
#
#   1) scripts/tests python 테스트 전체 통과
#   2) swift test 전체 통과
#   3) "로직 코어" 파일 집합의 라인 커버리지 >= THRESHOLD
#
# 로직 코어 = 결정적으로 단위 테스트 가능한 파일만 포함. ProcessRunner / PokeAPIClient /
# CcusageProvider / CodexRateLimitsProvider / OAuthLimitsProvider / UpdateChecker /
# BinaryLocator 는 실제 서브프로세스·네트워크·Keychain 의존이라 단위 커버리지 대상에서 제외
# (해당 부분은 파서/순수 헬퍼만 별도로 테스트됨).
#
# 사용:  ./scripts/test-gate.sh          # 게이트 실행
#        THRESHOLD=75 ./scripts/test-gate.sh   # 임계값 임시 상향
#
set -euo pipefail
cd "$(dirname "$0")/.."

THRESHOLD="${THRESHOLD:-75}"

LOGIC_CORE=(
  "Sources/DigiTokenBar/Core/CompanionModel.swift"
  "Sources/DigiTokenBar/Core/UnownForm.swift"
  "Sources/DigiTokenBar/Core/CollectionWeight.swift"
  "Sources/DigiTokenBar/Core/CompanionStore.swift"
  "Sources/DigiTokenBar/Core/PokemonProfile.swift"
  "Sources/DigiTokenBar/Core/PokemonNameLocalization.swift"
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
REPORT=$("$LLVM_COV" report "$BIN" -instr-profile="$PROF" "${LOGIC_CORE[@]}" 2>/dev/null)
echo "$REPORT"

# TOTAL 행의 라인 커버리지(%) 추출 — 컬럼: ... Lines MissedLines Cover(=$10)
COVER=$(echo "$REPORT" | awk '/^TOTAL/ { gsub("%","",$10); print $10 }')
if [[ -z "$COVER" ]]; then
  echo "✗ 커버리지 수치 파싱 실패." >&2
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
