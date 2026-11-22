"""Replay smoke actions using only copied declared inputs, then relocate its test.

Run after `bazel test //...` in examples/smoke:
    python3 ../../test/integration/hermetic_actions.py

This is a local relocation check, not a substitute for testing a real remote
executor. Only the standard system shell/utilities are inherited by subprocesses.
"""

import functools
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def bazel(*args):
    return subprocess.check_output(
        ["bazel", *args, "--lockfile_mode=off"], text=True
    ).strip()


def copy_input(source, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, dest, symlinks=False)
    else:
        shutil.copy2(source, dest, follow_symlinks=True)


def clean_env(root):
    return {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root)}


def main():
    graph = json.loads(bazel(
        "aquery",
        'mnemonic("GleamCompile.*|CompileGleam.*|BuildGleamEscript", '
        '//:my_app + //:my_app_lib + //:my_app_test)',
        "--output=jsonproto",
    ))
    execroot = Path(bazel("info", "execution_root"))
    bin_dir = Path(bazel("info", "bazel-bin"))
    fragments = {f["id"]: f for f in graph["pathFragments"]}
    dep_sets = {d["id"]: d for d in graph["depSetOfFiles"]}

    @functools.lru_cache(None)
    def fragment_path(fragment_id):
        fragment = fragments[fragment_id]
        if "parentId" not in fragment:
            return Path(fragment["label"])
        return fragment_path(fragment["parentId"]) / fragment["label"]

    artifacts = {
        a["id"]: fragment_path(a["pathFragmentId"]) for a in graph["artifacts"]
    }

    @functools.lru_cache(None)
    def inputs(dep_set_id):
        dep_set = dep_sets[dep_set_id]
        result = set(dep_set.get("directArtifactIds", []))
        for child in dep_set.get("transitiveDepSetIds", []):
            result.update(inputs(child))
        return result

    expected = {
        "GleamCompilePackage", "GleamCompileTest", "CompileGleamShim",
        "CompileGleamEunitRunner", "BuildGleamEscript",
    }
    assert {a["mnemonic"] for a in graph["actions"]} == expected
    for action in graph["actions"]:
        with tempfile.TemporaryDirectory(prefix="gleam-action-") as temp:
            root = Path(temp).resolve()
            input_ids = set()
            for dep_set_id in action.get("inputDepSetIds", []):
                input_ids.update(inputs(dep_set_id))
            for artifact_id in input_ids:
                path = artifacts[artifact_id]
                assert not path.is_absolute() and ".." not in path.parts, path
                copy_input(execroot / path, root / path)
                if path.name.endswith("_gleam_wrapper.sh"):
                    assert str(execroot.parent.parent) not in (root / path).read_text()
            for artifact_id in action["outputIds"]:
                path = artifacts[artifact_id]
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                # Bazel creates TreeArtifact output directories before execution.
                artifact = next(a for a in graph["artifacts"] if a["id"] == artifact_id)
                if artifact.get("isTreeArtifact"):
                    (root / path).mkdir()
            env = clean_env(root)
            env.update({v["key"]: v["value"] for v in action.get("environmentVariables", [])})
            assert str(execroot.parent.parent) not in json.dumps(action["arguments"])
            subprocess.run(action["arguments"], cwd=root, env=env, check=True)
            for artifact_id in action["outputIds"]:
                assert (root / artifacts[artifact_id]).exists()
            # Prove OTP itself resolves its installation within the copied inputs.
            erl = next(root / artifacts[i] for i in input_ids
                       if artifacts[i].as_posix().endswith("/otp/bin/erl"))
            actual_root = subprocess.check_output(
                [str(erl), "-noshell", "-eval",
                 'io:format("~s", [code:root_dir()]), halt().'],
                cwd=root, env=env, text=True,
            )
            assert Path(actual_root).is_relative_to(root), actual_root
            print("PASS:", action["mnemonic"], "with copied declared inputs", flush=True)

    with tempfile.TemporaryDirectory(prefix="gleam-test-") as temp:
        root = Path(temp).resolve()
        runfiles = root / "runfiles"
        copy_input(bin_dir / "my_app_test_test_runner.sh.runfiles", runfiles)
        launcher = root / "runner.sh"
        copy_input(bin_dir / "my_app_test_test_runner.sh", launcher)
        assert str(execroot.parent.parent) not in launcher.read_text()
        env = clean_env(root)
        env.update(TEST_SRCDIR=str(runfiles), TEST_WORKSPACE="_main",
                   TEST_TMPDIR=str(root), XML_OUTPUT_FILE=str(root / "results.xml"))
        subprocess.run([str(launcher)], cwd=runfiles / "_main", env=env, check=True)
        assert "greeting_test" in (root / "results.xml").read_text()
        print("PASS: relocated test runfiles without host Erlang", flush=True)


if __name__ == "__main__":
    main()
