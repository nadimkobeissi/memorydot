"""Exercise release ordering with real temporary Git repos and mocked Apple/GitHub tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
GIT = shutil.which("git")

MOCK_TOOL = r'''
import json
import os
from pathlib import Path
import subprocess
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RELEASE_TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, *args]) + "\n")

if tool == "git":
    if args[0] == "push":
        sys.exit(0)
    if args[0] == "ls-remote":
        if os.environ.get("RELEASE_TEST_REMOTE_FAILURE"):
            sys.exit(128)
        if os.environ.get("RELEASE_TEST_REMOTE_TAG"):
            print("0" * 40 + "\trefs/tags/" + os.environ["RELEASE_TEST_REMOTE_TAG"])
        sys.exit(0)
    sys.exit(subprocess.call([os.environ["RELEASE_TEST_GIT"], *args]))

if tool == "xcodebuild" and "archive" in args:
    if os.environ.get("RELEASE_TEST_BUILD_FAILURE"):
        sys.exit(1)
    if os.environ.get("RELEASE_TEST_EDIT_DURING_BUILD"):
        Path("changed-during-build.txt").write_text("User work\n")

if tool == "hdiutil":
    next(Path(arg) for arg in args if arg.endswith(".dmg")).write_bytes(b"test dmg\n")

if tool == "xcrun" and os.environ.get("RELEASE_TEST_NOTARY_FAILURE"):
    sys.exit(1)
'''


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="memorydot-release-")
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.repo = self.workspace / "repo with spaces"
        self.repo.mkdir()
        self.tap = self.workspace / "homebrew-memorydot"
        self.log = self.workspace / "commands.jsonl"
        self.env = dict(os.environ)
        self.env.update({
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "RELEASE_TEST_LOG": str(self.log),
            "RELEASE_TEST_GIT": GIT,
        })
        mock_bin = self.workspace / "bin"
        mock_bin.mkdir()
        for tool in ("git", "gh", "xcodegen", "xcodebuild", "hdiutil", "xcrun"):
            executable = mock_bin / tool
            executable.write_text(f"#!{sys.executable}\n" + MOCK_TOOL)
            executable.chmod(0o755)
        self.env["PATH"] = str(mock_bin) + os.pathsep + os.environ["PATH"]

        (self.repo / "scripts").mkdir()
        shutil.copy2(PROJECT / "scripts/release.sh", self.repo / "scripts/release.sh")
        shutil.copy2(PROJECT / "project.yml", self.repo / "project.yml")
        (self.repo / ".gitignore").write_text(".build/\nMemoryDot.xcodeproj/\n")
        self.init_repo(self.repo)
        self.original_project = (self.repo / "project.yml").read_text()
        self.original_head = self.git(self.repo, "rev-parse", "HEAD")

    def git(self, repo, *args):
        return subprocess.check_output(
            [GIT, "-C", str(repo), *args], env=self.env, text=True, stderr=subprocess.PIPE
        ).strip()

    def init_repo(self, repo):
        self.git(repo, "init", "-b", "main")
        self.git(repo, "config", "user.name", "Release Test")
        self.git(repo, "config", "user.email", "release-test@example.invalid")
        self.git(repo, "config", "commit.gpgsign", "false")
        self.git(repo, "config", "tag.gpgsign", "false")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", "Initial fixture")

    def make_tap(self):
        (self.tap / "Casks").mkdir(parents=True)
        (self.tap / "Casks/memorydot.rb").write_text("old cask\n")
        self.init_repo(self.tap)

    def run_release(self, *args, **scenario):
        return subprocess.run(
            ["/bin/bash", str(self.repo / "scripts/release.sh"), *args],
            cwd=self.workspace, env={**self.env, **scenario}, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
        )

    def commands(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_preflight_failure(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.repo / "project.yml").read_text(), self.original_project)
        self.assertFalse(any(c[0] == "xcodebuild" for c in self.commands()))

    def assert_not_published(self):
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.original_head)
        self.assertEqual(self.git(self.repo, "tag", "--list", "v9.8.7"), "")
        self.assertFalse(any(c[:2] == ["git", "push"] for c in self.commands()))
        self.assertFalse(any(c[:3] == ["gh", "release", "create"] for c in self.commands()))

    def test_invalid_arguments_fail_before_mutating_files(self):
        cases = ((), ("../bad",), ("1/2",), ("1.2&3",), ("1.2\n3",),
                 ("1.2.3.4",), ("v1.2",), ("1.2", "--skip-notarise"),
                 ("1.2", "--skip-notarize", "unexpected"))
        for args in cases:
            with self.subTest(args=args):
                self.assert_preflight_failure(self.run_release(*args))
        self.assertEqual(self.commands(), [])

    def test_dirty_project_fails_before_building(self):
        (self.repo / "user-work.txt").write_text("keep me\n")
        self.assert_preflight_failure(self.run_release("9.8.7"))

    def test_existing_local_tag_fails_before_building(self):
        self.git(self.repo, "tag", "v9.8.7")
        self.assert_preflight_failure(self.run_release("9.8.7"))

    def test_existing_remote_tag_fails_before_building(self):
        self.assert_preflight_failure(self.run_release(
            "9.8.7", RELEASE_TEST_REMOTE_TAG="v9.8.7"
        ))

    def test_remote_lookup_failure_does_not_continue(self):
        self.assert_preflight_failure(self.run_release(
            "9.8.7", RELEASE_TEST_REMOTE_FAILURE="1"
        ))

    def test_dirty_tap_is_not_overwritten_or_committed(self):
        self.make_tap()
        cask = self.tap / "Casks/memorydot.rb"
        cask.write_text("user cask edits\n")
        (self.tap / "unrelated.txt").write_text("user work\n")
        self.git(self.tap, "add", "unrelated.txt")
        head = self.git(self.tap, "rev-parse", "HEAD")
        self.assert_preflight_failure(self.run_release("9.8.7"))
        self.assertEqual(cask.read_text(), "user cask edits\n")
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD"), head)

    def test_non_repository_tap_fails_before_building(self):
        self.tap.mkdir()
        self.assert_preflight_failure(self.run_release("9.8.7"))

    def test_invalid_build_setting_fails_before_building(self):
        project = self.repo / "project.yml"
        project.write_text(self.original_project.replace("CURRENT_PROJECT_VERSION:", "MISSING_BUILD:"))
        self.git(self.repo, "add", "project.yml")
        self.git(self.repo, "commit", "-m", "Invalid fixture")
        self.original_project = project.read_text()
        self.assert_preflight_failure(self.run_release("9.8.7", "--skip-notarize"))

    def test_build_only_preserves_swiftpm_output_and_never_publishes(self):
        self.make_tap()
        (self.tap / "user-work.txt").write_text("keep me\n")
        release_output = self.repo / ".build/release"
        release_output.mkdir(parents=True)
        sentinel = release_output / "keep.txt"
        sentinel.write_text("SwiftPM output\n")
        result = self.run_release("9.8.7", "--skip-notarize")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sentinel.read_text(), "SwiftPM output\n")
        self.assertTrue((self.repo / ".build/distribution/MemoryDot-9.8.7.dmg").exists())
        self.assertIn('MARKETING_VERSION: "9.8.7"', (self.repo / "project.yml").read_text())
        self.assert_not_published()
        self.assertFalse(any(c[0] in ("gh", "xcrun") for c in self.commands()))
        self.assertEqual((self.tap / "Casks/memorydot.rb").read_text(), "old cask\n")

    def test_build_failure_never_publishes(self):
        result = self.run_release("9.8.7", RELEASE_TEST_BUILD_FAILURE="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_not_published()

    def test_notarization_failure_never_publishes(self):
        result = self.run_release("9.8.7", RELEASE_TEST_NOTARY_FAILURE="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_not_published()

    def test_changes_during_build_are_not_tagged_or_published(self):
        result = self.run_release("9.8.7", RELEASE_TEST_EDIT_DURING_BUILD="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Working tree changed during the release", result.stdout)
        self.assert_not_published()

    def test_draft_release_tags_bumped_sources_and_commits_only_the_cask(self):
        self.make_tap()
        result = self.run_release("9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout)
        tagged_project = self.git(self.repo, "show", "v9.8.7:project.yml")
        self.assertIn('MARKETING_VERSION: "9.8.7"', tagged_project)
        self.assertEqual(self.git(self.repo, "status", "--porcelain"), "")
        self.assertEqual(self.git(self.tap, "status", "--porcelain"), "")
        self.assertEqual(self.git(self.tap, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"),
                         "Casks/memorydot.rb")
        cask = (self.tap / "Casks/memorydot.rb").read_text()
        self.assertIn('version "9.8.7"', cask)
        self.assertIn('depends_on macos: ">= :sonoma"', cask)
        commands = self.commands()
        release = next(c for c in commands if c[:3] == ["gh", "release", "create"])
        self.assertIn("--draft", release)
        self.assertIn("--verify-tag", release)
        tag = commands.index(["git", "tag", "v9.8.7"])
        staple = next(i for i, c in enumerate(commands) if c[:3] == ["xcrun", "stapler", "staple"])
        self.assertLess(staple, tag)
        self.assertLess(tag, commands.index(release))
        self.assertEqual([c for c in commands if c[0] == "git" and "push" in c],
                         [["git", "push"], ["git", "push", "origin", "v9.8.7"]])


if __name__ == "__main__":
    unittest.main()
