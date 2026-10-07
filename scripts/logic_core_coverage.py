#!/usr/bin/env python3
"""LOGIC_CORE 파일들의 라인 커버리지를 합산한다.

`llvm-cov export -summary-only` JSON 을 stdin 으로 받고, 인자로 받은 소스 경로만 골라
합산한다. `llvm-cov report <BIN> ... <소스경로>` 를 쓰지 않는 이유는 test-gate.sh 헤더 참조.

stdout: 합계 퍼센트 1줄 (게이트가 임계값과 비교한다)
stderr: 파일별 내역 + 진단 (사람이 읽는다)

리포트에 없는 항목은 **실패로 처리한다**(exit 3). 분모에서 조용히 빠지면 커버리지가
오히려 *올라가* 게이트가 통과하기 때문이다 — 커버리지 낮은 파일의 경로를 잘못 적는
것이 게이트를 통과시키는 방향으로 작동한다. 계측 라인이 0인 선언 전용 파일(프로토콜·
DTO 등)만 아래 allowlist 로 면제한다.
"""
import json
import os
import sys

# 계측 라인이 0이라 커버리지 리포트에 아예 등장하지 않는 것이 정상인 파일.
# 프로토콜 요구사항 선언과 본문 없는 struct 는 실행 코드를 생성하지 않는다.
# 여기 추가하기 전에 `llvm-cov export` 결과에 정말 없는지 직접 확인해라 —
# 이 목록은 게이트의 배열 검증을 면제하는 구멍이다.
#
# 면제는 **파일이 실제로 존재할 때만** 적용한다. 리포트 부재는 "계측 라인 0" 과
# "파일이 삭제·이름변경됨" 이 구분되지 않는 상태이고, allowlist 가 전자를 면제하면
# 후자도 같이 통과시킨다 — 즉 allowlist 항목에 대해서만 원래 결함(오타·삭제가
# 게이트를 통과시킴)이 되살아난다. 존재 확인이 그 둘을 갈라 준다.
NO_INSTRUMENTED_LINES = {
    "Sources/DigiTokenBar/Core/DigimonLineProviding.swift",
}


def main() -> int:
    want = sys.argv[1:]
    if not want:
        print("사용법: logic_core_coverage.py <소스경로>...", file=sys.stderr)
        return 2

    # `endswith` 매칭은 배열 항목이 디렉토리 접두사를 포함한다는 전제에 의존한다
    # (`.../Core/UsageProvider.swift` 는 `.../Core/LocalUsageProvider.swift` 에 안 걸린다).
    # 베이스네임만 적으면 형제 파일을 잘못 집는다 — 항목을 줄이지 마라.
    # 2건 이상 매칭되면(예: `.build/checkouts` 안의 같은 경로) 조용히 마지막이
    # 이기지 않도록 경고한다.
    found = {}
    hits = {}
    for block in json.load(sys.stdin).get("data", []):
        for entry in block.get("files", []):
            for path in want:
                if entry["filename"].endswith(path):
                    found[path] = entry["summary"]["lines"]
                    hits.setdefault(path, []).append(entry["filename"])

    for path, filenames in hits.items():
        if len(filenames) > 1:
            print(f"  ⚠ {path} 가 리포트 항목 {len(filenames)}개에 매칭됐다:", file=sys.stderr)
            for filename in filenames:
                print(f"      {filename}", file=sys.stderr)
            print("    마지막 항목의 수치만 반영된다 — 배열 경로를 더 구체적으로 적어라.", file=sys.stderr)

    covered = total = 0
    rows = []
    for path in want:
        lines = found.get(path)
        name = path.rsplit("/", 1)[-1]
        if lines is None:
            rows.append((name, None))
            continue
        covered += lines["covered"]
        total += lines["count"]
        rows.append((name, lines))

    # 누락 항목을 맨 위로(가장 먼저 눈에 띄게), 그 다음 낮은 커버리지 순.
    rows.sort(key=lambda row: (row[1] is not None, row[1]["percent"] if row[1] else 0))

    for name, lines in rows:
        if lines is None:
            print(f"  {name:36s}      —  리포트에 없음", file=sys.stderr)
        else:
            print(
                f"  {name:36s} {lines['covered']:5d}/{lines['count']:5d}  {lines['percent']:6.2f}%",
                file=sys.stderr,
            )

    print(f"  LOGIC_CORE 합계: {covered}/{total}", file=sys.stderr)

    # 면제 목록 밖의 누락은 실패다. 분모에서 빠지면 커버리지가 올라가므로
    # 경고만 내면 "오타가 게이트를 통과시킨다".
    unexpected = [
        path
        for path in want
        if path not in found
        and not (path in NO_INSTRUMENTED_LINES and os.path.exists(path))
    ]
    if unexpected:
        print(
            f"  ✗ LOGIC_CORE 배열 항목 {len(unexpected)}개가 커버리지 리포트에 없다:",
            file=sys.stderr,
        )
        for path in unexpected:
            print(f"      {path}", file=sys.stderr)
        print(
            "    파일이 이름 변경·삭제됐거나 경로 오타다. 배열을 고쳐라."
            " 계측 라인이 0인 선언 전용 파일이면 이 스크립트의 NO_INSTRUMENTED_LINES 에 추가해라.",
            file=sys.stderr,
        )
        return 3

    if not total:
        print("  ✗ 집계된 라인이 0이다 — profdata 가 stale 이거나 배열이 비었다.", file=sys.stderr)
        return 1
    print(f"{100.0 * covered / total:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
