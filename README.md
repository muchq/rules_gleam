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
  Linux (glibc-linked, tied to a specific distro/version tag) and macOS, but not Windows. Every
  download is checksum-verified. Pin a different release with
  `gleam.erlang_toolchain(otp_version = ..., sha256 = {...})` in your `MODULE.bazel`, giving a
  checksum per platform (see [docs/otp_checksums.md](docs/otp_checksums.md) and
  [examples/hermetic_erlang](examples/hermetic_erlang)), or opt back out to
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
  toolchain's own OTP tree into their runfiles. No host Erlang is needed, but the deployment
  still needs compatible OS/CPU, ABI and system libraries. Linux builds are tied to the
  selected glibc distribution; macOS builds require a compatible macOS version.
  `gleam_standalone_release` requires the hermetic toolchain outright (fails otherwise);
  `gleam_release` falls back to a PATH lookup (same caveat as `gleam_binary`) if
  `gleam.local_erlang_toolchain()` opts out of it. See
  [examples/standalone_cli](examples/standalone_cli).

The downloaded OTP installation is declared as an input to compilation and packaging actions,
and is included in test runfiles. CI replays the smoke build's actions from copied declared
inputs and runs its test from relocated runfiles. This checks relocation locally; it does not
certify a particular remote execution service. The built-in OTP repository currently provides
the host OS/CPU only, and toolchain resolution rejects incompatible execution platforms.
Remote workers still need a compatible OS/ABI and standard Unix shell utilities. The explicit
`gleam.local_erlang_toolchain()` opt-out remains non-hermetic.

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

All Bazel modules using the same extension share one `gleam_packages` repository. Identical
declarations are deduplicated, including across manifests and explicit tags. Checksums are
case-insensitive; dependency/build-tool ordering and an omitted `otp_app` do not matter.
The version, checksum, dependencies, build tools and plain-Erlang opt-in must otherwise agree.
For an explicit tag matching a manifest, include the manifest's `build_tools` as well.
Conflicts identify the modules and tags that disagree; no version is silently selected.

The root module can deliberately replace a package's declarations with
`gleam.hex_package(..., override = True)`. Supply its complete version, checksum, dependency
list and build policy, and check that all consumers support that version. Dependency modules
cannot override packages; a root declaration without `override = True` has no special priority.
Even an override cannot resolve different checksums for the same package version: verify and
correct those declarations. Overrides replace rather than merge dependency lists, and the
selected graph must have every dependency declared and contain no cycles.

Git/path entries in `hex_manifest` are rejected with an error. To use them, define local
`gleam_library` targets and wire their dependencies explicitly in `BUILD.bazel`, declaring
Hex dependencies individually instead of importing the mixed-source manifest. If a Hex
package itself needs a local dependency, define that package as a local target too; generated
Hex targets refer only to other packages in `gleam_packages`.

BUILD files themselves can be generated instead of hand-written: a [Gazelle](gleam_gazelle)
extension turns any `gleam.toml` + `src/**/*.gleam` directory into a `gleam_package(...)` target.
Wire it into your own `gazelle_binary`'s `languages` list alongside `@rules_gleam//gleam_gazelle`
and run `bazel run //:gazelle` -- see [examples/gazelle_smoke](examples/gazelle_smoke) for a
worked example of wiring this into a downstream project's own `MODULE.bazel`/`BUILD.bazel`.

To run the `gleam` CLI itself (e.g. `gleam format`) without knowing your machine's OS/arch
string, add `"gleam_host"` to the extension's `use_repo(...)` call and run
`bazel run @gleam_host//:gleam -- format`.

### Hex package build support

Hex imports support Gleam packages, including Erlang FFI sources, declared headers under
`src/` and `include/`, and runtime files under `priv/`. The generated targets declare these
inputs. `include/` is passed to the Erlang compiler (as Rebar3's `-I include` would be), and
library/test compilation copies `include/` and `priv/` into the compiled OTP package, so
dependents can use `-include_lib("app/include/...")` and `code:priv_dir/1` works in releases. For local targets, include headers and `priv/**` in
`data`; Gazelle now generates these declarations and includes `.erl`/`.mjs` sources.

Rebar3, Mix, native compilation and custom build hooks are not implemented. Lockfile
`build_tools` and `otp_app` are retained and checked, and common native/custom build entry
points (`c_src`, `Makefile`, `mix.exs`, `rebar.config.script`) are rejected. A differing OTP
application name is also rejected rather than generating an incorrectly named application.

An audited Erlang-only package can explicitly bypass Rebar3 with
`gleam.hex_manifest(..., plain_erlang_packages = ["hpack_erl"])`, or
`gleam.hex_package(..., allow_plain_erlang = True)`. This asserts that the package needs no
Rebar3 options, plugins, hooks, code generation or native compilation; its Rebar3 configuration
is not interpreted. Other packages need a dedicated Bazel build. For manual declarations,
`build_tools` and `otp_app` may be supplied explicitly; otherwise the archive layout is checked.
This is a bounded build contract, not general Hex/Rebar3 compatibility. Escript binaries still
do not bundle runtime assets; use a release for packages that need `priv/`.

### Release arguments and runtime data

`gleam_release` and `gleam_standalone_release` call the entry function with zero arguments.
Launcher arguments are forwarded after Erlang's `-extra`, preserving spaces, empty strings,
quotes and leading `-`/`+` characters. Read them with `init:get_plain_arguments/0` (through
Erlang FFI or an argv library). For example, `bazel run //:web_service_bin -- "two words"`
passes one application argument. VM options belong in `ERL_AFLAGS`/`ERL_FLAGS`, such as
`ERL_FLAGS='+S 2:2'`, or a file referenced by `ERL_FLAGS='-args_file /etc/service/vm.args'`.
The VM parses these using [Erlang's argument syntax](https://www.erlang.org/doc/apps/erts/erl_cmd.html);
the launcher does not evaluate them as shell code. Keep service VMs in the foreground.

The launcher preserves the caller's working directory and exports `RUNFILES_DIR` as the
absolute runfiles root and `GLEAM_RUNFILES_DIR` as its main-workspace directory. Read ordinary
workspace `data` at `$GLEAM_RUNFILES_DIR/<workspace-relative-path>`. External repositories use
Bazel's canonical repository directories alongside that workspace directory; those names
are build-specific. Prefer package-owned `priv/` assets and `code:priv_dir/1` when a package
must work across repositories. Both releases and `gleam_test` include transitive dependency
data; tests also export `GLEAM_RUNFILES_DIR`.

These are launchers, not full OTP release-management tools: they do not generate boot
scripts, start applications automatically, implement hot upgrades, or supervise processes.
Start needed OTP applications in your entry function. Returning from it stops the VM;
services must keep it alive. The launcher uses `exec`, so exit status reaches the caller and
SIGTERM reaches the VM, initiating OTP shutdown. Implement cleanup in your application's
stop callbacks and configure a sufficient shutdown timeout in your service manager.

### Deployment archives and containers

Build `//:web_service_tar` in `examples/web_service`, or `//:standalone_cli_tar` in
`examples/standalone_cli`, to produce a `.tar.gz`. These use
[`rules_pkg`'s `pkg_tar`](https://bazelbuild.github.io/rules_pkg/latest.html#pkg_tar) with
`include_runfiles = True` and `preserve_mode = True`. The archive contains the executable
beside `<executable>.runfiles/`, including compiled code, transitive data and the bundled OTP
runtime. Extract the whole archive into one directory and keep that relative layout. No
Bazel installation, build-cache symlinks, or checkout is needed at runtime. Package files
should be treated as read-only; put writable state outside the extracted tree.

The bundled OTP is not statically linked. Match the build's OS/CPU and its runtime ABI and
shared libraries; changing the container image does not cross-compile an archive. The default
Linux OTP build targets Ubuntu 22.04/glibc. The example
[Dockerfile](examples/web_service/Dockerfile) uses Ubuntu 22.04 and installs its runtime
libraries (OpenSSL, ncurses/tinfo, libstdc++, zlib and CA certificates), with no Erlang package.
Alpine/musl, distroless images and other distro versions are not implicitly supported.
macOS artifacts require compatible macOS system libraries and any dependencies of the
selected OTP build; they cannot be deployed in a Linux container.

On a Linux build host matching the deployment CPU:

```sh
cd examples/web_service
bazel build //:web_service_tar
cp bazel-bin/web_service.tar.gz web_service.tar.gz
docker build -t gleam-web-service .
docker run --rm -p 34817:34817 gleam-web-service
```

The example runs as an unprivileged user with an exec-form entry point and SIGTERM shutdown.
CI exercises both launcher archives after relocation on macOS and Linux, and in the
Dockerfile's Linux runtime image, including SSL startup, config/assets, argument boundaries,
startup failure and a real OTP application shutdown callback. Validate any different OTP
version or deployment image against your application's requirements.
