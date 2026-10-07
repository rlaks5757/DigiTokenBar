import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/logic_core_coverage.py"

ALLOWLISTED_PATH = "Sources/DigiTokenBar/Core/DigimonLineProviding.swift"


def lines(covered, count):
    # llvm-cov export 의 summary.lines 셰이프. sort key(73행)와 출력(80행)이
    # percent 를 무조건 읽으므로 세 키 모두 채워야 한다.
    percent = 100.0 * covered / count if count else 0.0
    return {"covered": covered, "count": count, "percent": percent}


def report(entries):
    # entries: [(filename, covered, count), ...] — 단일 block 의 files 배열로 포장한다.
    return {
        "data": [
            {
                "files": [
                    {"filename": filename, "summary": {"lines": lines(covered, count)}}
                    for filename, covered, count in entries
                ]
            }
        ]
    }


class LogicCoreCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)

    def run_script(self, want, payload, cwd=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *want],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            cwd=str(cwd if cwd is not None else self.cwd),
        )

    # 1. 배열 항목이 리포트에 없으면 실패해야 한다 — 분모에서 조용히 빠지면
    # 커버리지가 오히려 올라가 게이트를 통과시킨다.
    def test_missing_entry_fails_with_full_path_in_diagnostics(self):
        want = ["Sources/DigiTokenBar/Core/CompanionModel.swift"]
        result = self.run_script(want, report([]))
        self.assertEqual(result.returncode, 3)
        # 행 출력기는 basename 만 찍는다(name). 전체 경로는 94-106행 진단 블록에만
        # 등장하므로, 이 단언은 그 블록이 살아있어야만 만족된다.
        self.assertIn(want[0], result.stderr)

    # 2. 여러 파일의 covered/count 합산 + 퍼센트 포맷(소수 2자리) 확인.
    def test_normal_paths_sum_and_format_percent(self):
        want = ["Core/A.swift", "Core/B.swift"]
        payload = report(
            [
                (f"/abs/Core/A.swift", 10, 20),
                (f"/abs/Core/B.swift", 45, 80),
            ]
        )
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "55.00")
        self.assertEqual(len(result.stdout.strip().splitlines()), 1)

    # 3. allowlist 항목 + 파일이 실제로 존재 → 면제되어 exit 0.
    # allowlist 항목만 want 에 넣으면 found 가 비어 total==0 이 되어 버려서
    # "면제됨"과 "집계 라인 0 (exit 1)"이 뒤섞인다. 정상 항목을 하나 같이 넣어
    # total != 0 을 만들어야 면제 경로(exit 0)만 분리해서 확인할 수 있다.
    def test_allowlist_entry_exempted_when_file_exists(self):
        target = self.cwd / ALLOWLISTED_PATH
        target.parent.mkdir(parents=True)
        target.write_text("// stub\n")
        want = [ALLOWLISTED_PATH, "Core/Normal.swift"]
        payload = report([("/abs/Core/Normal.swift", 1, 2)])
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "50.00")

    # 4. 같은 경로·같은 want·같은 JSON인데 파일만 없으면 실패해야 한다.
    # 3번과 유일한 차이는 파일시스템 상태 — AND 가드의 두 칸(allowlist 멤버십 /
    # 존재 확인)을 각각 떼어내 죽이는 대조쌍이다. (여기서는 target 을 만들지 않는다.)
    def test_allowlist_entry_fails_when_file_missing(self):
        want = [ALLOWLISTED_PATH, "Core/Normal.swift"]
        payload = report([("/abs/Core/Normal.swift", 1, 2)])
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 3)
        self.assertIn(ALLOWLISTED_PATH, result.stderr)

    # 5. allowlist 에 "없는" 경로인데 디스크에는 실제로 존재 → 면제되면 안 된다.
    # 3/4번은 두 칸이 같은 값(T,T / T,F)이라 멤버십 칸만 떼어낸 뮤턴트(존재 확인만
    # 남김)는 죽이지 못한다 — 멤버십이 False 라서 원본도 뮤턴트도 둘 다 면제되지
    # 않는다(결과가 같다). 이 케이스는 멤버십=False, 존재=True 로 비대칭을 만들어서
    # "멤버십 검사가 없으면 존재만으로 면제된다"는 뮤턴트를 잡는다.
    def test_non_allowlisted_path_not_exempted_even_if_file_exists(self):
        non_allowlisted = "Sources/DigiTokenBar/Core/CompanionModel.swift"
        target = self.cwd / non_allowlisted
        target.parent.mkdir(parents=True)
        target.write_text("// stub\n")
        want = [non_allowlisted, "Core/Normal.swift"]
        payload = report([("/abs/Core/Normal.swift", 1, 2)])
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 3)
        self.assertIn(non_allowlisted, result.stderr)

    # allowlist 항목이 리포트에 "있으면" 정상적으로 분모에 합산돼야 한다 —
    # 면제가 커버리지 집계까지 면제하면 안 된다.
    def test_allowlist_entry_present_in_report_is_counted(self):
        payload = report([(f"/abs/{ALLOWLISTED_PATH}", 3, 4)])
        result = self.run_script([ALLOWLISTED_PATH], payload)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "75.00")

    # total == 0 → exit 1. 경로 자체가 found 에 있어야 도달한다 — 없으면 3이
    # 먼저 나간다.
    def test_total_zero_fails_distinctly(self):
        want = ["Core/Empty.swift"]
        payload = report([("/abs/Core/Empty.swift", 0, 0)])
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 1)

    # 인자 없이 호출 → exit 2. json.load 전에 반환하므로 stdin 은 비어 있어도 된다.
    def test_no_arguments_fails_before_reading_stdin(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="",
            capture_output=True,
            text=True,
            cwd=str(self.cwd),
        )
        self.assertEqual(result.returncode, 2)

    # endswith 매칭은 디렉토리 접두사를 포함한다는 전제에 의존한다. 형제 파일
    # (LocalUsageProvider.swift) 은 UsageProvider.swift 경로에 걸리면 안 된다.
    def test_endswith_does_not_match_sibling_file(self):
        want = ["Sources/DigiTokenBar/Core/UsageProvider.swift"]
        payload = report(
            [("/abs/Sources/DigiTokenBar/Core/LocalUsageProvider.swift", 5, 5)]
        )
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 3)

    # 2건 이상 매칭 시 경고 + 마지막 항목이 반영됨을 확인한다 (found[path] 덮어쓰기).
    def test_duplicate_match_warns_and_last_entry_wins(self):
        want = ["Core/Dup.swift"]
        payload = report(
            [
                ("/abs/Core/Dup.swift", 1, 10),
                ("/abs/.build/checkouts/Core/Dup.swift", 9, 10),
            ]
        )
        result = self.run_script(want, payload)
        self.assertEqual(result.returncode, 0)
        self.assertIn("매칭됐다", result.stderr)
        self.assertIn("/abs/Core/Dup.swift", result.stderr)
        self.assertIn("/abs/.build/checkouts/Core/Dup.swift", result.stderr)
        self.assertEqual(result.stdout.strip(), "90.00")


if __name__ == "__main__":
    unittest.main()
