"""Release byte layout and the fail-closed publication preparation entry point."""

import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / ".github/workflows"))
from release_archive import build_archive, release_names
from release_validate import quickstart_files, validate_archive


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        for name in ["MODULE.bazel", "README.md", ".bazelversion", ".bcr/source.template.json",
                     "examples/smoke/MODULE.bazel", ".github/workflows/release_prep.sh",
                     ".github/workflows/release_archive.py", ".github/workflows/release_validate.py"]:
            destination = self.repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, destination)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Release test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "fixture")
        self.git("tag", "v1.2.3-rc1")
        self.old_cwd = Path.cwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, self.old_cwd)

    def git(self, *args):
        result = subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                                 "-c", "core.hooksPath=/dev/null", *args],
                                cwd=self.repo, text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result

    # Artifact identity and reproducibility.
    def test_archive_stamps_version_preserves_sources_and_includes_bcr_module(self):
        archive = build_archive("v1.2.3-rc1", "refs/tags/v1.2.3-rc1", self.root / "out")
        self.assertEqual(archive.name, "rules_gleam-v1.2.3-rc1.tar.gz")
        before = archive.read_bytes()
        with tarfile.open(archive) as contents:
            files = {m.name: contents.extractfile(m).read() for m in contents.getmembers() if m.isfile()}
        expected = {
            "rules_gleam-1.2.3-rc1/" + str(p.relative_to(self.repo)): p.read_bytes()
            for p in self.repo.rglob("*") if p.is_file() and ".git" not in p.parts
        }
        expected["rules_gleam-1.2.3-rc1/MODULE.bazel"] = expected[
            "rules_gleam-1.2.3-rc1/MODULE.bazel"].replace(b'version = "0.0.0"', b'version = "1.2.3-rc1"', 1)
        self.assertEqual(files, expected)
        build_archive("v1.2.3-rc1", "refs/tags/v1.2.3-rc1", self.root / "out")
        self.assertEqual(archive.read_bytes(), before)
        self.assertEqual((self.repo / "MODULE.bazel").read_bytes(), (REPO / "MODULE.bazel").read_bytes())

    def test_invalid_tags_are_rejected(self):
        for tag in ["main", "1.2.3", "v1.2", "v1.2.3/../../bad"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_names(tag)

    def test_archive_excluding_bcr_smoke_module_is_rejected(self):
        (self.repo / ".gitattributes").write_text("examples export-ignore\n")
        self.git("add", ".gitattributes")
        self.git("-c", "user.name=Release test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", "exclude required test module")
        with self.assertRaisesRegex(ValueError, "must include the BCR smoke test module"):
            build_archive("v1.2.3", "HEAD", self.root / "out")

    def test_mismatched_archive_metadata_is_rejected_before_bazel_runs(self):
        archive = build_archive("v1.2.3-rc1", "refs/tags/v1.2.3-rc1", self.root / "out")
        with tarfile.open(archive) as source:
            files = {m.name: source.extractfile(m).read() for m in source.getmembers() if m.isfile()}
        prefix = "rules_gleam-1.2.3-rc1/"
        cases = [
            ("filename", "wrong.tar.gz", files,
             "Expected archive filename rules_gleam-v1.2.3-rc1.tar.gz, got wrong.tar.gz"),
            ("prefix", archive.name, {"wrong/" + name: data for name, data in files.items()},
             "Archive strip_prefix does not match the tag"),
            ("version", archive.name, {**files, prefix + "MODULE.bazel": (REPO / "MODULE.bazel").read_bytes()},
             "Archive MODULE.bazel version does not match the tag"),
            ("bcr", archive.name, {**files, prefix + ".bcr/source.template.json": b'{"url":"wrong","strip_prefix":"wrong"}'},
             "BCR source template does not describe the release archive"),
        ]
        for name, filename, contents, message in cases:
            with self.subTest(case=name):
                directory = self.root / name
                directory.mkdir()
                broken = directory / filename
                with tarfile.open(broken, "w:gz") as output:
                    for path, data in contents.items():
                        member = tarfile.TarInfo(path)
                        member.size = len(data)
                        output.addfile(member, io.BytesIO(data))
                with self.assertRaises(ValueError) as raised:
                    validate_archive(broken, "v1.2.3-rc1", directory / "extracted")
                self.assertEqual(str(raised.exception), message)

    # The real prep script must not emit publishable notes after a failed test.
    def prepare(self, fail_tests):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        bazel = bin_dir / "bazel"
        bazel.write_text('''#!/usr/bin/env python3
import os, sys
command = next(arg for arg in sys.argv if arg in ["test", "run", "shutdown"])
with open(os.environ["BAZEL_TEST_LOG"], "a") as log:
    log.write(command + "\\n")
if command == "test" and os.environ["FAIL_TESTS"] == "1":
    sys.exit(17)
if command == "run":
    print("Hello from my_app!")
''')
        bazel.chmod(0o755)
        log = self.root / "bazel.log"
        env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
               "FAIL_TESTS": "1" if fail_tests else "0", "BAZEL_TEST_LOG": str(log)}
        result = subprocess.run(["bash", ".github/workflows/release_prep.sh", "v1.2.3-rc1"],
                                cwd=self.repo, env=env, text=True, capture_output=True)
        return result, log.read_text() if log.exists() else ""

    def test_failed_archive_validation_blocks_release_notes(self):
        result, calls = self.prepare(fail_tests=True)
        self.assertEqual((result.returncode, result.stdout, calls), (1, "", "test\nshutdown\n"), result.stderr)

    def test_successful_validation_checks_all_workspaces_before_release_notes(self):
        result, calls = self.prepare(fail_tests=False)
        self.assertEqual((result.returncode, calls), (0, "test\nshutdown\ntest\nshutdown\ntest\nrun\nshutdown\n"), result.stderr)
        sha = hashlib.sha256((self.repo / "rules_gleam-v1.2.3-rc1.tar.gz").read_bytes()).hexdigest()
        # Verify the complete installation block, including its checksum and alias.
        block = result.stdout.split("```starlark\n")[1].split("\n```", 1)[0]
        self.assertEqual(block, f'''bazel_dep(name = "muchq_rules_gleam", version = "1.2.3-rc1", repo_name = "rules_gleam")
archive_override(
    module_name = "muchq_rules_gleam",
    urls = ["https://github.com/muchq/rules_gleam/releases/download/v1.2.3-rc1/rules_gleam-v1.2.3-rc1.tar.gz"],
    sha256 = "{sha}",
    strip_prefix = "rules_gleam-1.2.3-rc1",
)''')

    # Documentation extraction must fail instead of silently skipping a source file.
    def test_readme_with_unlabelled_source_block_is_rejected(self):
        readme = (REPO / "README.md").read_text().replace("// src/main.gleam", "// Missing filename")
        with self.assertRaises(ValueError) as raised:
            quickstart_files(readme)
        self.assertEqual(str(raised.exception), "Quick-start code block must start with its file name")


if __name__ == "__main__":
    unittest.main()
