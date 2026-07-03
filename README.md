# Bazel rules for Gleam

Bazel rules for building, testing, and packaging [Gleam](https://gleam.run) projects on the
Erlang/OTP target.

## Status

These rules are early-stage. In particular:

- **Erlang is not hermetic by default.** The Erlang/OTP toolchain is discovered on the host (via
  `PATH`), not downloaded by Bazel, so builds depend on whatever Erlang/OTP version is installed
  where Bazel runs. An opt-in hermetic toolchain is available via
  `gleam.erlang_toolchain(otp_version = "27.1.2")` in `MODULE.bazel`, which downloads a prebuilt
  OTP release instead (see [examples/hermetic_erlang](examples/hermetic_erlang)); it currently
  supports Linux (glibc-linked, tied to a specific distro/version tag) and macOS, but not Windows.
- **Test coverage is currently limited to basic end-to-end examples** (see `examples/`) rather
  than a full unit test suite for the rule implementations themselves.
- `gleam_binary` produces a self-contained `escript`, which still requires an Erlang runtime to
  be present on the machine that _runs_ the resulting executable (it is not a standalone native
  binary).

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
end-to-end test, see [examples/web_service](examples/web_service).

Hex dependencies can be declared one-by-one with `gleam.hex_package(...)`, or in bulk by
pointing `gleam.hex_manifest(manifest = "//path/to:manifest.toml")` at a Gleam project's own
`manifest.toml` lockfile (see [examples/web_service/MODULE.bazel](examples/web_service/MODULE.bazel)),
which avoids hand-maintaining a package's full transitive dependency graph and checksums.

BUILD files themselves can be generated instead of hand-written: a [Gazelle](gazelle/gleam)
extension turns any `gleam.toml` + `src/**/*.gleam` directory into a `gleam_package(...)` target.
Wire it into your own `gazelle_binary`'s `languages` list alongside `@rules_gleam//gazelle/gleam`
(see this repo's own root [BUILD.bazel](BUILD.bazel) for a working example) and run
`bazel run //:gazelle`.
