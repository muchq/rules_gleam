# Bazel rules for Gleam

Bazel rules for building, testing, and packaging [Gleam](https://gleam.run) projects on the
Erlang/OTP target.

## Status

These rules are early-stage. In particular:

- **Erlang is not hermetic yet.** The Erlang/OTP toolchain is discovered on the host (via
  `PATH`), not downloaded by Bazel, so builds depend on whatever Erlang/OTP version is installed
  where Bazel runs. Fetching a hermetic, versioned Erlang/OTP toolchain is tracked as future work.
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

See a basic example [here](examples/smoke)
