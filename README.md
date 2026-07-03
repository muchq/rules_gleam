# Bazel rules for Gleam

Bazel rules for building, testing, and packaging [Gleam](https://gleam.run) projects on the
Erlang/OTP target.

## Status

These rules are early-stage. In particular:

- **Erlang is hermetic by default.** Bazel downloads a prebuilt OTP release and uses it
  directly, rather than discovering Erlang/OTP on the host's `PATH`; it currently supports
  Linux (glibc-linked, tied to a specific distro/version tag) and macOS, but not Windows. Pin a
  specific `otp_version`/checksum with `gleam.erlang_toolchain(otp_version = "29.0.2")` in your
  `MODULE.bazel` (see [examples/hermetic_erlang](examples/hermetic_erlang)), or opt back out to
  PATH-based host discovery entirely with `gleam.local_erlang_toolchain()` (see
  [examples/nested_smoke](examples/nested_smoke)) if hermetic downloads aren't practical in
  your build environment.
- **Test coverage is primarily end-to-end examples** (see `examples/`), plus a growing
  `test/unit/` suite of Starlark `analysistest`/`unittest` tests (bazel-skylib) for private
  rule/module-extension logic that's awkward to exercise through a full build --
  [examples/expect_fail](examples/expect_fail) additionally proves `gleam_test` and
  `gleam_format_test` actually detect real failures, not just happy-path input.
- `gleam_binary` (escript) always requires a compatible Erlang runtime to be present on the
  machine that _runs_ the resulting executable: its `#!/usr/bin/env escript` shebang finds
  `escript` via `PATH` at _run_ time, separately from whichever Erlang/OTP built it (the
  hermetic version by default), so running it on a machine whose Erlang/OTP is meaningfully
  older can fail with a BEAM-compatibility error. `gleam_release` and `gleam_standalone_release`
  don't have this problem under the hermetic toolchain (the default): both bundle the
  toolchain's own OTP tree into their runfiles, so the result is genuinely portable to any
  machine with the same OS/CPU architecture, no Erlang installed there required.
  `gleam_standalone_release` requires the hermetic toolchain outright (fails otherwise);
  `gleam_release` falls back to a PATH lookup (same caveat as `gleam_binary`) if
  `gleam.local_erlang_toolchain()` opts out of it. See
  [examples/standalone_cli](examples/standalone_cli).

Contributions and bug reports are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Installation

Add the following to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "muchq_rules_gleam", version = "0.0.1")
git_override(
    module_name = "muchq_rules_gleam",
    remote = "https://github.com/muchq/rules_gleam.git",
    tag = "v0.1.0",
)
```

## Usage

See a basic example [here](examples/smoke). For a runnable HTTP service with a real
end-to-end test, see [examples/web_service](examples/web_service). For a fully self-contained
CLI binary needing no host Erlang, see [examples/standalone_cli](examples/standalone_cli).

Hex dependencies can be declared one-by-one with `gleam.hex_package(...)`, or in bulk by
pointing `gleam.hex_manifest(manifest = "//path/to:manifest.toml")` at a Gleam project's own
`manifest.toml` lockfile (see [examples/web_service/MODULE.bazel](examples/web_service/MODULE.bazel)),
which avoids hand-maintaining a package's full transitive dependency graph and checksums.

BUILD files themselves can be generated instead of hand-written: a [Gazelle](gleam_gazelle)
extension turns any `gleam.toml` + `src/**/*.gleam` directory into a `gleam_package(...)` target.
Wire it into your own `gazelle_binary`'s `languages` list alongside `@rules_gleam//gleam_gazelle`
and run `bazel run //:gazelle` -- see [examples/gazelle_smoke](examples/gazelle_smoke) for a
worked example of wiring this into a downstream project's own `MODULE.bazel`/`BUILD.bazel`.
