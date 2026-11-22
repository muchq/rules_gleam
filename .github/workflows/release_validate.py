"""Validate the shipped source tree and the README quick start in fresh workspaces."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

from release_archive import release_names


QUICKSTART_FILES = {
    "MODULE.bazel", "BUILD.bazel", "gleam.toml",
    "src/main.gleam", "src/my_app.gleam", "test/my_app_test.gleam",
}


def quickstart_files(readme):
    section = readme.split("## Installation\n", 1)[1].split("## Usage\n", 1)[0]
    files = {}
    for body in re.findall(r"```(?:starlark|toml|gleam)\n(.*?)\n```", section, re.S):
        header = body.splitlines()[0].split()
        if len(header) < 2 or header[1] not in QUICKSTART_FILES:
            raise ValueError("Quick-start code block must start with its file name")
        path = header[1]
        files[path] = files.get(path, "") + body + "\n"
    if set(files) != QUICKSTART_FILES:
        raise ValueError(f"Missing quick-start files: {QUICKSTART_FILES - set(files)}")
    return files


def bazel(workspace, output_base, *args):
    command = ["bazel", "--ignore_all_rc_files", f"--output_base={output_base}", *args]
    if args[0] != "shutdown":
        command.append("--lockfile_mode=off")
    result = subprocess.run(command, cwd=workspace, text=True, stdout=subprocess.PIPE)
    if result.returncode:
        sys.stderr.write(result.stdout)
        result.check_returncode()
    return result


def test_workspace(workspace, output_base, targets, run_target=None):
    try:
        bazel(workspace, output_base, "test", "--test_output=errors", *targets)
        if run_target:
            result = bazel(workspace, output_base, "run", run_target)
            if result.stdout != "Hello from my_app!\n":
                raise AssertionError(f"Quick-start output: {result.stdout!r}")
    finally:
        bazel(workspace, output_base, "shutdown")


def validate_quickstart(source, work, archive=None, tag=None):
    consumer = work / "consumer"
    consumer.mkdir()
    files = quickstart_files((source / "README.md").read_text())
    if archive:
        version, prefix, _ = release_names(tag)
        digest = base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
        install = (
            'archive_override(\n    module_name = "muchq_rules_gleam",\n'
            f'    urls = [{json.dumps(archive.as_uri())}],\n'
            f'    integrity = "sha256-{digest}",\n    strip_prefix = "{prefix}",\n)'
        )
        module, count = re.subn(r"git_override\(.*?\n\)", lambda _: install, files["MODULE.bazel"], count=1, flags=re.S)
        if count != 1:
            raise ValueError("Expected one pinned installation override in the README")
        files["MODULE.bazel"] = module.replace('version = "0.0.0"', f'version = "{version}"', 1)
    for name, contents in files.items():
        path = consumer / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    shutil.copy2(source / ".bazelversion", consumer / ".bazelversion")
    test_workspace(consumer, work / "consumer-output", ["//:my_app_test", "//:my_app_format_test"], "//:my_app_release")


def validate_archive(archive, tag, work):
    version, prefix, filename = release_names(tag)
    if archive.name != filename:
        raise ValueError(f"Expected archive filename {filename}, got {archive.name}")
    with tarfile.open(archive) as contents:
        if any(not member.name.startswith(prefix + "/") for member in contents.getmembers()):
            raise ValueError("Archive strip_prefix does not match the tag")
        contents.extractall(work, filter="data")
    source = work / prefix
    module = (source / "MODULE.bazel").read_text()
    if f'    version = "{version}",' not in module:
        raise ValueError("Archive MODULE.bazel version does not match the tag")
    template = json.loads((source / ".bcr/source.template.json").read_text())
    substitutions = {"OWNER": "muchq", "REPO": "rules_gleam", "TAG": tag, "VERSION": version}
    expected_url = f"https://github.com/muchq/rules_gleam/releases/download/{tag}/{filename}"
    if template["url"].format(**substitutions) != expected_url or template["strip_prefix"].format(**substitutions) != prefix:
        raise ValueError("BCR source template does not describe the release archive")
    test_workspace(source, work / "source-output", ["//..."])
    test_workspace(source / "examples/smoke", work / "smoke-output", ["//..."])
    validate_quickstart(source, work, archive, tag)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, nargs="?")
    parser.add_argument("tag", nargs="?")
    parser.add_argument("--documented-install", action="store_true", help="Run the README's exact pinned Git installation")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rules-gleam-release-") as temp:
        work = Path(temp)
        if args.documented_install:
            validate_quickstart(Path(__file__).resolve().parents[2], work)
        elif args.archive and args.tag:
            validate_archive(args.archive.resolve(), args.tag, work)
        else:
            parser.error("provide ARCHIVE TAG or --documented-install")
    print("PASS: release source and documented consumer validation")


if __name__ == "__main__":
    main()
