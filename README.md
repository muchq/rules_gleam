# Bazel rules for Gleam

Bazel rules for building, testing, and packaging [Gleam](https://gleam.run) projects on the
Erlang/OTP target. See [ARCHITECTURE.md](ARCHITECTURE.md) for how the repo is laid out and how
its test suite is organized.

## Status

**Early-stage and not yet validated in production.** This project has no known production users
and has not been battle-tested beyond its own CI (Linux and macOS, a handful of example
projects, one Bazel version, one Gleam version). Treat it as something to evaluate and
contribute to, not as a dependency to build critical infrastructure on yet. In particular:

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

Contributions and bug reports are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). If you try
this on a real project, hearing about what broke (or didn't) is especially useful right now.

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

This isn't published to the Bazel Central Registry yet, so `git_override` (pinning a specific
tag, commit, or branch) is currently the only supported way to depend on it.

## Quick start

A minimal library-and-binary package looks like this. First, declare the toolchain and your Hex
dependencies in `MODULE.bazel` (checksums come from `gleam deps download`'s output, or from each
package's page on [hex.pm](https://hex.pm)):

```starlark
gleam = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
gleam.toolchain(version = "1.17.0")
gleam.hex_package(
    name = "gleam_stdlib",
    sha256 = "621d600bb134bc239cb2537630899817b1a42e60a1d46c5e9f3fae39f88c800b",
    version = "0.60.0",
    deps = [],
)
gleam.hex_package(
    name = "gleeunit",
    sha256 = "da9553ce58b67924b3c631f96fe3370c49eb6d6dc6b384ec4862cc4aaa718f3c",
    version = "1.9.0",
    deps = ["gleam_stdlib"],
)
use_repo(gleam, "gleam_packages", "gleam_toolchains", "local_config_erlang")

register_toolchains("@gleam_toolchains//:all")
register_toolchains("@local_config_erlang//:erlang_toolchain_definition")
```

Then a `gleam.toml` (same as `gleam new` would generate) next to a `BUILD.bazel`:

```toml
# gleam.toml
name = "my_app"
version = "0.1.0"

[dependencies]
gleam_stdlib = "~> 0.60 or ~> 0.68 or ~> 0.69"

[dev-dependencies]
gleeunit = "~> 1.0"
```

```starlark
# BUILD.bazel
load("@rules_gleam//gleam:defs.bzl", "gleam_package")

# Expands to a gleam_library "my_app_lib", a gleam_binary "my_app" (since entry_module is set),
# and a gleam_test "my_app_test" recompiling srcs + test_srcs together with gleeunit.
gleam_package(
    name = "my_app",
    srcs = glob(["src/**/*.gleam"]),
    entry_module = "main",
    gleam_toml = "gleam.toml",
    test_deps = ["@gleam_packages//:gleeunit"],
    test_srcs = glob(["test/**/*.gleam"]),
    deps = ["@gleam_packages//:gleam_stdlib"],
)
```

With sources under `src/` and `test/`:

```gleam
// src/my_app.gleam
pub fn greeting() -> String {
  "Hello from my_app!"
}
```

```gleam
// src/main.gleam
import gleam/io
import my_app

pub fn main() {
  io.println(my_app.greeting())
}
```

```gleam
// test/my_app_test.gleam
import gleeunit
import gleeunit/should
import my_app

pub fn main() {
  gleeunit.main()
}

pub fn greeting_test() {
  my_app.greeting()
  |> should.equal("Hello from my_app!")
}
```

Then the usual Bazel commands work as expected:

```shell
bazel run //:my_app      # builds and runs the escript
bazel test //:my_app_test
bazel test //:my_app_format_test  # gleam_package also adds a `gleam format --check` test
```

See [examples/smoke](examples/smoke) for this exact example, checked in and exercised by CI.

## Usage

For a runnable HTTP service with a real end-to-end test, see
[examples/web_service](examples/web_service). For a fully self-contained CLI binary needing no
host Erlang, see [examples/standalone_cli](examples/standalone_cli).

Hex dependencies can be declared one-by-one with `gleam.hex_package(...)` (as above), or in bulk
by pointing `gleam.hex_manifest(manifest = "//path/to:manifest.toml")` at a Gleam project's own
`manifest.toml` lockfile (see [examples/web_service/MODULE.bazel](examples/web_service/MODULE.bazel)),
which avoids hand-maintaining a package's full transitive dependency graph and checksums.

BUILD files themselves can be generated instead of hand-written: a [Gazelle](gleam_gazelle)
extension turns any `gleam.toml` + `src/**/*.gleam` directory into a `gleam_package(...)` target.
Wire it into your own `gazelle_binary`'s `languages` list alongside `@rules_gleam//gleam_gazelle`
and run `bazel run //:gazelle` -- see [examples/gazelle_smoke](examples/gazelle_smoke) for a
worked example of wiring this into a downstream project's own `MODULE.bazel`/`BUILD.bazel`.

To run the `gleam` CLI itself (e.g. `gleam format`) without knowing your machine's OS/arch
string, add `"gleam_host"` to the extension's `use_repo(...)` call and run
`bazel run @gleam_host//:gleam -- format`.
