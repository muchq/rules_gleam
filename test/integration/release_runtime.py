"""Test deployed archives locally, or in the documented Linux runtime image.

Run from the repository root: python3 test/integration/release_runtime.py [--docker]
"""

import argparse
from pathlib import Path
import queue
import subprocess
import tarfile
import tempfile
import threading
import uuid


REPO = Path(__file__).resolve().parents[2]
TARGET = "//test/integration/release_runtime:"
IMAGE = "rules-gleam-runtime-test"
FLAGS = "+S 2:2 -kernel logger_level error"
APPLICATION_ARGS = ["check", "two words", "", "quote'\"", "*", "--flag", "+S", "line\nbreak"]


def run(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, timeout=90, **kwargs)


def expect(result, code, stdout, stderr, case):
    actual = (result.returncode, result.stdout, result.stderr)
    expected = (code, stdout, stderr)
    if actual != expected:
        raise AssertionError(f"{case}: expected {expected!r}, got {actual!r}")
    print(f"PASS: {case}", flush=True)


def test_archive(archive_path, binary, docker):
    with tempfile.TemporaryDirectory(prefix="gleam deployed archive ") as temp:
        root = Path(temp).resolve()
        artifact = root / "relocated artifact"
        artifact.mkdir()
        with tarfile.open(archive_path) as archive:
            # Deployed artifacts must not contain links back into the build cache.
            for member in archive.getmembers():
                if member.issym() or member.islnk():
                    raise AssertionError(f"archive contains a link: {member.name}")
            archive.extractall(artifact, filter="data")

        # Inherited runfiles must not take precedence over the deployed tree.
        unrelated = root / "unrelated runfiles"
        unrelated.mkdir()
        env = {
            "PATH": "/usr/bin:/bin", "HOME": temp,
            "ERL_FLAGS": FLAGS,
            "ERL_CRASH_DUMP_SECONDS": "0",
            "EXPECTED_CWD": str(root),
        }
        container = "gleam-runtime-" + uuid.uuid4().hex
        if docker:
            command = [
                "docker", "run", "--rm", "--name", container,
                "--user", "65532:65532", "--workdir", "/tmp",
                "-v", f"{artifact}:/artifact:ro",
                "-e", f"ERL_FLAGS={FLAGS}",
                "-e", "ERL_CRASH_DUMP_SECONDS=0",
                "-e", "EXPECTED_CWD=/tmp",
                "--entrypoint", f"/artifact/{binary}", IMAGE,
            ]
            options = {}
        else:
            command = [str(artifact / binary)]
            options = {"cwd": root, "env": env}

        # Unchanged zero-argument startup; argv boundaries and runtime closure.
        expect(run(command, **options), 0, "no arguments\n", "", f"{binary}: no arguments")
        expect(run(command + APPLICATION_ARGS, **options), 0,
               "arguments, VM flags, config and assets OK\n", "",
               f"{binary}: arguments, config, assets and SSL after relocation")
        if docker:
            inherited_command = command[:-1] + ["-e", "RUNFILES_DIR=/tmp", IMAGE]
            inherited_options = options
        else:
            inherited_command = command
            inherited_options = {**options, "env": {**env, "RUNFILES_DIR": str(unrelated)}}
        expect(run(inherited_command, **inherited_options), 0, "no arguments\n", "",
               f"{binary}: adjacent tree overrides inherited runfiles")

        # Startup failures must reach the invoking shell/container unchanged.
        expect(run(command + ["fail"], **options), 23, "", "deliberate startup failure\n",
               f"{binary}: startup failure status")

        # Exercise a real OTP application stop callback, not just process death.
        process = subprocess.Popen(command + ["serve"], text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
        ready = queue.Queue()
        reader = threading.Thread(target=lambda: ready.put(process.stdout.readline()), daemon=True)
        reader.start()
        try:
            line = ready.get(timeout=30)
            if line != "ready\n":
                raise AssertionError(f"{binary}: expected ready, got {line!r}")
            reader.join()
            if docker:
                stopped = run(["docker", "stop", "--time", "15", container])
                if stopped.returncode:
                    raise AssertionError(stopped.stderr)
            else:
                process.terminate()
            stdout, stderr = process.communicate(timeout=20)
            expect(subprocess.CompletedProcess(command, process.returncode, stdout, stderr),
                   0, "graceful shutdown\n", "", f"{binary}: graceful SIGTERM shutdown")
        finally:
            if process.poll() is None:
                if docker:
                    run(["docker", "rm", "-f", container])
                process.kill()
                process.communicate()

        # Failure to locate runfiles is distinct from a successful empty app run.
        if not docker:
            (artifact / (binary + ".runfiles")).rename(artifact / "hidden.runfiles")
            env["RUNFILES_DIR"] = str(artifact / "hidden.runfiles")
            expect(run(command, **options), 0, "no arguments\n", "",
                   f"{binary}: inherited runfiles works without adjacent tree")
            env.pop("RUNFILES_DIR")
            expect(run(command, **options), 1, "",
                   "ERROR: could not locate the release runfiles directory.\n",
                   f"{binary}: missing runfiles fails")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker", action="store_true")
    args = parser.parse_args()
    subprocess.run(["bazel", "build", TARGET + "release_tar", TARGET + "standalone_tar"],
                   cwd=REPO, check=True)
    output = subprocess.check_output(["bazel", "info", "bazel-bin"], cwd=REPO, text=True).strip()
    if args.docker:
        subprocess.run(["docker", "build", "--target", "runtime", "-t", IMAGE,
                        "-f", "examples/web_service/Dockerfile", "examples/web_service"],
                       cwd=REPO, check=True)
    for binary in ["release", "standalone"]:
        archive = Path(output) / "test/integration/release_runtime" / (binary + "_tar.tar.gz")
        test_archive(archive, binary, args.docker)


if __name__ == "__main__":
    main()
