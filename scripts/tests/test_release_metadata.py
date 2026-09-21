import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_metadata", ROOT / "scripts/release-metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

NOTES = """## New

**New feature** (#123, @Alice) — works offline.

## Fixed

- A bug is fixed (#124, @Bob).

## Other

None.

## Contributors

@Alice · @Bob

Thank you all.

---

**Install:** `brew install --cask rlaks5757/tap/digi-token-bar` — or download `DigiTokenBar.zip` below.

**Upgrade:** `brew upgrade --cask digi-token-bar`
"""


# 미기입 릴리스 노트 템플릿 — 모든 섹션이 주석 placeholder 뿐이라 내용이 비어 있다.
# 파일(docs/reference/release-notes-template.md)이 아니라 여기에 두는 이유: 그 문서는
# 아직 존재하지 않는 tap/cask 를 안내하게 되고, release.sh 는 현재 실행 자체를 거부한다.
UNFILLED_TEMPLATE = """<!-- Write in English. Replace every instruction with actual release content.
Keep all sections; use 'None.' if a change category is empty. -->
## New

<!-- **Feature title** (#PR, @author) — explain the user-visible behavior. -->

## Fixed

<!-- - Describe the resolved symptom (#PR, @author). -->

## Other

<!-- - Documentation, maintenance, or other changes. -->

## Contributors

<!-- Deduplicated GitHub handles: @alice · @bob. -->
"""

class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.notes = self.root / "notes.md"
        self.notes.write_text(NOTES)
        self.roster = self.root / "contributors.txt"
        self.roster.write_text("alice\n@bob\n")

    def check(self):
        metadata.check_notes(str(self.notes), str(self.roster))

    def test_valid_notes_are_not_rewritten(self):
        self.check()
        self.assertEqual(self.notes.read_text(), NOTES)

    def test_missing_or_empty_notes_fail(self):
        for value in ("", str(self.root / "missing")):
            with self.assertRaises(ValueError):
                metadata.check_notes(value, str(self.roster))
        self.notes.write_text("")
        with self.assertRaises(ValueError):
            self.check()

    def test_all_sections_and_install_instructions_are_required(self):
        for value in ("## New", "## Fixed", "## Other", "## Contributors", "brew upgrade --cask digi-token-bar"):
            with self.subTest(value=value):
                self.notes.write_text(NOTES.replace(value, "removed"))
                with self.assertRaises(ValueError):
                    self.check()

    def test_unfilled_template_fails(self):
        self.notes.write_text(UNFILLED_TEMPLATE)
        with self.assertRaises(ValueError):
            self.check()

    def test_roster_member_missing_from_both_summary_and_contributors_fails(self):
        self.roster.write_text("alice\nbob\ncarol\n")
        with self.assertRaisesRegex(ValueError, "@carol"):
            self.check()

    def test_summary_credit_cannot_be_omitted_from_contributors(self):
        self.roster.write_text("alice\n")
        self.notes.write_text(NOTES.replace("@Alice · @Bob", "@Alice"))
        with self.assertRaisesRegex(ValueError, "@bob"):
            self.check()

    def test_no_external_contributors_must_be_explicit(self):
        self.roster.write_text("")
        self.notes.write_text(NOTES.replace(", @Alice", "").replace(", @Bob", "").replace(
            "@Alice · @Bob\n\nThank you all.", "No external contributors in this release."))
        self.check()

    def test_roster_is_required(self):
        with self.assertRaises(ValueError):
            metadata.check_notes(str(self.notes), "")

    def test_bot_credit_does_not_require_a_human_contributor(self):
        self.roster.write_text("")
        self.notes.write_text(NOTES.replace("@Alice", "@dependabot[bot]").replace(", @Bob", "").replace(
            "@dependabot[bot] · @Bob\n\nThank you all.", "No external contributors in this release."))
        self.check()

    def test_default_commit_has_no_fixed_coauthor(self):
        self.assertEqual(metadata.commit_message("2.5.4"), "release: bump version to 2.5.4")

    def test_only_explicit_coauthors_are_preserved(self):
        authors = self.root / "coauthors.txt"
        authors.write_text("Alice <alice@example.com>\nBob <bob@example.com>\nAlice <alice@example.com>\n")
        self.assertEqual(metadata.commit_message("2.5.4", str(authors)),
                         "release: bump version to 2.5.4\n\nCo-Authored-By: Alice <alice@example.com>\nCo-Authored-By: Bob <bob@example.com>")

    def test_invalid_coauthor_fails(self):
        authors = self.root / "coauthors.txt"
        authors.write_text("Co-Authored-By: guessed model")
        with self.assertRaises(ValueError):
            metadata.commit_message("2.5.4", str(authors))

    @unittest.skip("release.sh 가 미구성 가드로 즉시 종료 — 가드 제거 시 함께 해제")
    def test_release_stops_before_side_effects_when_notes_are_missing(self):
        # Run the real shell entry point inside a disposable fixture. No git writes,
        # network, app build, signing, or installation commands are reachable.
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("release.sh", "release-metadata.py"):
            (scripts / name).write_text((ROOT / "scripts" / name).read_text())
        (scripts / "build-app.sh").write_text('VERSION="2.5.3"\n')
        marker = self.root / "test-gate-reached"
        gate = scripts / "test-gate.sh"
        gate.write_text('#!/bin/sh\ntouch test-gate-reached\nexit 1\n')
        gate.chmod(0o755)
        commands = self.root / "bin"
        commands.mkdir()
        git = commands / "git"
        git.write_text('#!/bin/sh\nif [ "$1" = rev-parse ]; then echo main; else exit 99; fi\n')
        git.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("PTB_")}
        env["PATH"] = str(commands) + os.pathsep + env["PATH"]
        command = ["bash", str(scripts / "release.sh"), "2.5.4"]
        missing = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("PTB_NOTES_FILE", missing.stderr)
        self.assertFalse(marker.exists())
        env.update(PTB_NOTES_FILE=str(self.notes), PTB_CONTRIBUTORS_FILE=str(self.roster))
        valid = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(valid.returncode, 0, "Fixture intentionally stops at test-gate")
        self.assertTrue(marker.exists())
        self.assertEqual((scripts / "build-app.sh").read_text(), 'VERSION="2.5.3"\n')


if __name__ == "__main__":
    unittest.main()
