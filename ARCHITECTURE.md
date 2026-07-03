# Architecture

An overview of how this repo is laid out and how its test suite is organized. See
[README.md](README.md) for usage and [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor
workflow.

## Layout

- **`gleam/`** — the public rules (`gleam_library`, `gleam_binary`, `gleam_test`,
  `gleam_format_test`, `gleam_release`, `gleam_standalone_release`, `gleam_package`, all
  re-exported from `gleam/defs.bzl`), the toolchain type and rule (`gleam/toolchain.bzl`), and
  the bzlmod module extension (`gleam/extensions.bzl`) that downstream `MODULE.bazel` files use
  to register a Gleam toolchain and Hex packages. `gleam/private/` holds implementation details
  not meant to be depended on directly: toolchain/Hex-package repository rules (including
  `gleam_host`, which re-exposes the host platform's toolchain repo under one unconditional
  name), version/manifest.toml parsers, and similar.
- **`erlang/`** — the Erlang/OTP toolchain type, split the same way: a hermetic repository rule
  that downloads a prebuilt OTP release (`erlang/private/hermetic_erlang_repository.bzl`,
  the default) and a `local_erlang_repository.bzl` alternative that discovers Erlang/OTP on the
  host's `PATH` instead (opt-in via `gleam.local_erlang_toolchain()`).
- **`gleam_gazelle/`** — a [Gazelle](https://github.com/bazelbuild/bazel-gazelle) language
  extension (Go) that generates `gleam_package(...)` targets from `gleam.toml` +
  `src/**/*.gleam` directories, so BUILD files don't need to be hand-written.
- **`examples/`** — runnable, CI-exercised projects, each demonstrating one thing end-to-end
  (see [Test taxonomy](#test-taxonomy) below, item 3).
- **`docs/`** — `rules.md`, generated from `gleam/defs.bzl`'s docstrings via
  [Stardoc](https://github.com/bazelbuild/stardoc) (`bazel run //docs:update` regenerates it;
  `bazel test //docs:rules_test` checks it's up to date).
- **`test/unit/`** — Starlark unit tests for private helpers (see below).

## Test taxonomy

Four layers, each catching a different class of regression:

1. **Starlark unit tests** (`test/unit/*`, bazel-skylib's `unittest`/`analysistest`) — test pure
   Starlark functions extracted from repository rules and macros (version parsing, manifest.toml
   parsing, the otp-tree/erl-invocation resolution `gleam_release` depends on, `gleam_host`'s
   host-platform detection) directly, without needing a full build or a real toolchain. Also
   used to prove a `fail()` actually fires for a bad input, via
   `analysistest.make(expect_failure = True)` plus `asserts.expect_failure(env, msg)`. These are
   the cheapest and fastest layer, and the first to write when adding logic to a repository rule
   or module extension — the majority of these functions were literally extracted from an
   existing rule implementation specifically to make them unit-testable in isolation.
2. **`gleam_gazelle`'s own Go unit tests + golden files** (`gleam_gazelle/*_test.go`,
   `gleam_gazelle/testdata/golden/*`) — since the Gazelle extension is Go, not Starlark, it's
   tested the same way `bazel-gazelle`'s own language extensions are: each fixture directory
   under `testdata/golden/` pairs a `gleam.toml` + sources with a checked-in `BUILD.want`, and
   `go test ./gleam_gazelle/... -run TestGolden -update` regenerates them after an intentional
   output change. This calls `GenerateRules` directly and does not include the `load(...)`
   statement Gazelle's own resolver inserts — that's covered separately by a real compiled
   `gazelle_binary` run against `gleam_gazelle/testdata/sample_package` in CI (see below).
3. **Example projects** (`examples/*`, exercised by `bazel test //...`/`bazel build //...` in
   CI on both Linux and macOS) — end-to-end proof that the public rules actually work together
   under real Bazel, real toolchains, and (for the Hex-dependent examples) real downloaded
   packages. Each example is scoped to demonstrate one thing:
   - **[smoke](examples/smoke)** — the minimal `gleam_package` example from the README's Quick
     start.
   - **[gazelle_smoke](examples/gazelle_smoke)** — wiring `gleam_gazelle` into a downstream
     project's own `gazelle_binary`.
   - **[nested_smoke](examples/nested_smoke)** — a package nested below the repo root, and the
     one example that opts out of the hermetic Erlang toolchain via
     `gleam.local_erlang_toolchain()` (so it needs a system Erlang on `PATH`; see the "Set up
     Erlang" CI steps).
   - **[web_service](examples/web_service)** — a runnable HTTP service, a `manifest.toml`-driven
     bulk Hex dependency declaration (`gleam.hex_manifest(...)`), and (Linux only) a Docker-based
     proof that `gleam_release`'s bundled OTP tree makes the result portable to a machine with no
     Erlang installed at all.
   - **[standalone_cli](examples/standalone_cli)** — same portability proof as `web_service`,
     for `gleam_standalone_release` (which requires the hermetic toolchain outright).
   - **[hermetic_erlang](examples/hermetic_erlang)** — pins a specific, non-default
     `otp_version` via `gleam.erlang_toolchain(...)`, proving a second OTP release works
     end-to-end (not just the built-in default).
   - **[expect_fail](examples/expect_fail)** — deliberately broken fixtures (a failing test, a
     misformatted file); CI asserts `bazel test` actually fails on them, proving `gleam_test`/
     `gleam_format_test` detect real failures rather than always passing.
   - **[hello_world](examples/hello_world)** — the smallest possible `gleam_binary` (escript),
     including a check that the built escript actually runs.
4. **CI-only verification steps** (`.github/workflows/ci.yaml`, no corresponding
   `bazel test` target) — checks that don't fit cleanly into a hermetic Bazel test, either
   because they need a genuinely fresh environment (the Docker-based portability checks above)
   or because they exercise a real compiled binary rather than in-process Go code (the
   `gazelle_binary` vs. `testdata/sample_package` diff, `bazel run @gleam_host//:gleam --
--version`).

When adding a rule or macro with any non-trivial branching logic, prefer extracting the logic
into a plain function and covering it with layer 1 first — it's the cheapest to write and the
fastest to run. The macOS hermetic Erlang arch-naming bug and `examples/hermetic_erlang`'s
never-actually-published OTP pin were both only caught after a real build broke, because the
logic at fault lived inside a repository rule's download/extract path rather than a
separately-testable function; `gleam_host`'s own `arm64`→`aarch64` arch-normalization mistake,
by contrast, was caught immediately by its layer-1 unit test the first time it ran under real
Bazel on a real macOS runner (`repository_ctx.os.arch` reports `"arm64"` there, not `"aarch64"`)
-- exactly the kind of bug this layer exists to catch cheaply.
