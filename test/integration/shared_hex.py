"""Exercise the real module extension using two independent consumer modules."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[2]
DIGEST = "621d600bb134bc239cb2537630899817b1a42e60a1d46c5e9f3fae39f88c800b"


def main():
    with tempfile.TemporaryDirectory(prefix="gleam-shared-hex-") as temp:
        workspace = Path(temp) / "workspace"
        shutil.copytree(REPO / "examples/shared_hex", workspace,
                        ignore=shutil.ignore_patterns("bazel-*", "MODULE.bazel.lock"))
        shutil.copy2(REPO / ".bazelversion", workspace / ".bazelversion")
        root = workspace / "MODULE.bazel"
        root.write_text(root.read_text().replace('path = "../.."',
                                                "path = " + json.dumps(str(REPO))))
        alpha = workspace / "alpha/MODULE.bazel"
        beta = workspace / "beta/MODULE.bazel"
        manifest = workspace / "beta/manifest.toml"
        originals = {path: path.read_text() for path in [root, alpha, beta, manifest]}

        def bazel(*args):
            result = subprocess.run(
                ["bazel", *args, "--lockfile_mode=off"], cwd=workspace,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            return result.returncode, result.stdout

        def check(name, changes, errors=()):
            for path, content in originals.items():
                path.write_text(changes.get(path, content))
            code, output = bazel("mod", "show_repo", "@gleam_packages")
            if errors:
                if code == 0 or any(message not in output for message in errors):
                    raise AssertionError(f"{name}: expected {errors}, got:\n{output}")
            elif code:
                raise AssertionError(f"{name}:\n{output}")
            print(f"PASS: {name}", flush=True)
            return output

        override = (
            '\ngleam.hex_package(name = "gleam_stdlib", version = "0.60.0", '
            f'sha256 = "{DIGEST}", build_tools = ["gleam"], override = True)\n'
        )
        try:
            output = check("shared explicit and manifest declarations", {})
            # Inspect repository-rule inputs to prove only one package was emitted.
            if output.count(DIGEST) != 1:
                raise AssertionError(f"Expected one normalized package:\n{output}")
            code, output = bazel("build", "//:shared")
            if code:
                raise AssertionError(output)
            code, output = bazel(
                "query", "labels(actual, @alpha//:stdlib) union labels(actual, @beta//:stdlib)",
            )
            labels = [line for line in output.splitlines() if line.startswith("@")]
            if code or len(labels) != 1 or not labels[0].endswith("//:gleam_stdlib"):
                raise AssertionError(f"Expected a shared canonical target:\n{output}")
            print("PASS: both consumer modules build the same Hex target", flush=True)

            conflict = originals[manifest].replace('version = "0.60.0"', 'version = "0.61.0"')
            check("version conflict", {manifest: conflict},
                  ("Conflicting declarations", "dependency module alpha@1.0.0",
                   "dependency module beta@1.0.0", "manifest.toml", "override = True"))
            output = check("explicit root override", {manifest: conflict, root: originals[root] + override})
            if "0.61.0" in output or output.count(DIGEST) != 1:
                raise AssertionError(f"Override did not replace the selected package:\n{output}")
            check("root declaration has no implicit priority",
                  {manifest: conflict, root: originals[root] + override.replace(", override = True", "")},
                  ("Conflicting declarations", "root module shared_hex"))
            check("dependency cannot override", {alpha: originals[alpha] + override},
                  ("Only the root module", "dependency module alpha@1.0.0"))
            check("checksum conflict even with root override",
                  {root: originals[root] + override,
                   manifest: originals[manifest].replace(DIGEST.upper(), "0" * 64)},
                  ("Conflicting checksums", "cannot change immutable package bytes"))
            check("metadata conflict", {manifest: originals[manifest].replace(
                'build_tools = ["gleam"]', 'build_tools = ["rebar3"]')},
                  ("differ in build_tools",))

            for dep, error in [("missing", "requires undeclared package 'missing'"),
                               ("gleam_stdlib", "Dependency cycle")]:
                check(dep, {alpha: originals[alpha].replace(
                    'build_tools = ["gleam"],', f'build_tools = ["gleam"], deps = ["{dep}"],'),
                    manifest: originals[manifest].replace('requirements = []', f'requirements = ["{dep}"]')},
                      (error,))
            for source in ["git", "local", "path"]:
                check(f"reject {source} manifest", {manifest: originals[manifest].replace(
                    'source = "hex"', f'source = "{source}"')},
                      ("Unsupported manifest package", "local gleam_library targets", "BUILD.bazel"))
            check("two manifests deduplicate", {
                alpha: originals[alpha].split("gleam.hex_package(")[0]
                + 'gleam.hex_manifest(manifest = "@beta//:manifest.toml")\n'
                + 'use_repo(gleam, "gleam_packages")\n'
                + 'bazel_dep(name = "beta", version = "1.0.0")\n',
            })
        finally:
            subprocess.run(["bazel", "shutdown"], cwd=workspace, check=False)


if __name__ == "__main__":
    main()
