<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API for the Gleam Bazel rules.

<a id="gleam_binary"></a>

## gleam_binary

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_binary")

gleam_binary(<a href="#gleam_binary-name">name</a>, <a href="#gleam_binary-dep">dep</a>, <a href="#gleam_binary-entry_function">entry_function</a>, <a href="#gleam_binary-entry_module">entry_module</a>)
</pre>

Packages a `gleam_library` and its transitive deps into a single-file, self-contained escript
executable.

The resulting executable still requires an Erlang/OTP runtime to be present on the machine
that runs it (it is not a standalone native binary) -- it bundles compiled BEAM files, not an
Erlang runtime.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_binary-dep"></a>dep |  The gleam_library target containing the entry point module.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="gleam_binary-entry_function"></a>entry_function |  The function to call in the entry module.   | String | optional |  `"main"`  |
| <a id="gleam_binary-entry_module"></a>entry_module |  The Erlang module name to call at startup (e.g. 'main').   | String | required |  |


<a id="gleam_format_test"></a>

## gleam_format_test

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_format_test")

gleam_format_test(<a href="#gleam_format_test-name">name</a>, <a href="#gleam_format_test-srcs">srcs</a>)
</pre>

Checks that a set of Gleam source files are already formatted per `gleam format`, failing
the build with a diff if not. Does not modify any files (that would require a separate,
non-hermetic "fix" target akin to Buildifier's write-back mode; not provided here).

Unlike `gleam_library`/`gleam_test`, this rule doesn't compile anything and doesn't need a
`gleam.toml`, `deps`, or a `package_name` -- `gleam format` operates directly on files.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_format_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_format_test-srcs"></a>srcs |  Gleam source files to check formatting for, e.g. glob(["src/**/*.gleam", "test/**/*.gleam"]).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |


<a id="gleam_library"></a>

## gleam_library

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_library")

gleam_library(<a href="#gleam_library-name">name</a>, <a href="#gleam_library-deps">deps</a>, <a href="#gleam_library-srcs">srcs</a>, <a href="#gleam_library-data">data</a>, <a href="#gleam_library-otp_app">otp_app</a>, <a href="#gleam_library-package_name">package_name</a>)
</pre>

Compiles a single Gleam package with `gleam compile-package`.

Each `gleam_library` corresponds to one Gleam package (one `gleam.toml`). Dependencies are
other `gleam_library` targets, consumed as pre-compiled BEAM artifacts via `--lib` -- this
package's own sources are not recompiled when a dependent package changes, matching Bazel's
per-target caching model.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_library-deps"></a>deps |  Gleam package dependencies (other gleam_library targets).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="gleam_library-srcs"></a>srcs |  Source files (typically glob(["src/**/*.gleam", "src/**/*.erl", "src/**/*.mjs"])).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="gleam_library-data"></a>data |  Data dependencies.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="gleam_library-otp_app"></a>otp_app |  OTP application name for the compiled directory; defaults to package_name. A matching `src/<otp_app>.app.src` in data is copied to `ebin/<otp_app>.app` without interpreting Rebar3 configuration.   | String | optional |  `""`  |
| <a id="gleam_library-package_name"></a>package_name |  The name of the Gleam package.   | String | required |  |


<a id="gleam_release"></a>

## gleam_release

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_release")

gleam_release(<a href="#gleam_release-name">name</a>, <a href="#gleam_release-dep">dep</a>, <a href="#gleam_release-entry_function">entry_function</a>, <a href="#gleam_release-entry_module">entry_module</a>)
</pre>

Packages a `gleam_library` and its transitive deps as a runfiles-tree binary: a small
launcher script plus the compiled BEAM directories and any declared runtime `data`
(config files, templates, certs, etc.), reachable at runtime under the launcher's own
runfiles directory.

Under the hermetic Erlang toolchain (the default), this bundles the toolchain's own OTP tree
into the release's runfiles. No host Erlang is needed, but the runtime still requires a
compatible OS/CPU, ABI and system shared libraries (Linux builds are glibc/distro-specific;
macOS builds require a compatible macOS version). Under
`gleam.local_erlang_toolchain()`'s PATH-based discovery, there is no such tree to bundle, so
the launcher falls back to a plain PATH lookup for `erl` at run time (the same portability
model as `gleam_binary`'s escript): whatever Erlang built this must also be reasonably
compatible with whatever's on PATH wherever it actually runs. If you want a hard guarantee
that this rule never silently falls back to that PATH-lookup behavior, use
`gleam_standalone_release` instead, which fails outright unless the hermetic toolchain is active.

Unlike `gleam_binary`, this does not produce a single self-contained escript -- the
result is a launcher script that must be run alongside its `.runfiles` directory (as
`bazel run` does automatically, and as a `bazel build`-produced binary does when invoked
directly). This is the tradeoff for being able to ship `data` at all: escript archives
don't compose with Bazel's runfiles model.

Application arguments are forwarded after `-extra` with their boundaries preserved. Read
these strings with `init:get_plain_arguments/0` (the entry function remains zero-arity).
Configure the VM with Erlang's `ERL_AFLAGS`/`ERL_FLAGS` or an `-args_file`, not application argv.
`GLEAM_RUNFILES_DIR` names the absolute main-workspace data root; prefer `code:priv_dir/1`
for package-owned `priv/` assets. The launcher preserves the caller's working directory.

These launchers are not full OTP releases: no boot-script generation, release_handler hot
upgrades, or service supervision is provided. The VM receives signals directly; SIGTERM
initiates OTP shutdown, and application cleanup must be implemented by the application.

Does not attempt to start the package as an OTP application (no `application:ensure_all_started`
call) -- call it yourself from `entry_module` if your package needs it.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_release-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_release-dep"></a>dep |  The gleam_library target containing the entry point module.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="gleam_release-entry_function"></a>entry_function |  The function to call in the entry module.   | String | optional |  `"main"`  |
| <a id="gleam_release-entry_module"></a>entry_module |  The Erlang module name to call at startup (e.g. 'main').   | String | required |  |


<a id="gleam_standalone_release"></a>

## gleam_standalone_release

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_standalone_release")

gleam_standalone_release(<a href="#gleam_standalone_release-name">name</a>, <a href="#gleam_standalone_release-dep">dep</a>, <a href="#gleam_standalone_release-entry_function">entry_function</a>, <a href="#gleam_standalone_release-entry_module">entry_module</a>)
</pre>

Packages a `gleam_library` and its transitive deps as a fully self-contained binary that
bundles the Erlang/OTP runtime itself: the machine that *runs* the result does not need any
Erlang installed at all, unlike `gleam_binary` (escript), which always shells out to a system
Erlang via a PATH lookup.

`gleam_release` also bundles the runtime under the hermetic toolchain, but silently falls
back to a PATH lookup under `gleam.local_erlang_toolchain()`. This rule instead requires the
hermetic Erlang toolchain (on by default) and fails with an actionable error if
`gleam.local_erlang_toolchain()` has opted back out to PATH-based discovery -- use this when
you want that guarantee enforced. The bundled runtime still needs a compatible OS/CPU, ABI
and system shared libraries. Linux builds are glibc/distro-specific, not musl/static binaries;
macOS builds require a compatible macOS version. Validate the actual deployment image.

Arguments, VM configuration, runtime data and shutdown follow the `gleam_release` contract.
This is a launcher with a bundled runtime, not full OTP release management or hot upgrades.

Like `gleam_release`, this does not attempt to start the package as an OTP application (no
`application:ensure_all_started` call) -- call it yourself from `entry_module` if needed.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_standalone_release-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_standalone_release-dep"></a>dep |  The gleam_library target containing the entry point module.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="gleam_standalone_release-entry_function"></a>entry_function |  The function to call in the entry module.   | String | optional |  `"main"`  |
| <a id="gleam_standalone_release-entry_module"></a>entry_module |  The Erlang module name to call at startup (e.g. 'main').   | String | required |  |


<a id="gleam_test"></a>

## gleam_test

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_test")

gleam_test(<a href="#gleam_test-name">name</a>, <a href="#gleam_test-deps">deps</a>, <a href="#gleam_test-srcs">srcs</a>, <a href="#gleam_test-data">data</a>, <a href="#gleam_test-package_name">package_name</a>, <a href="#gleam_test-test_srcs">test_srcs</a>)
</pre>

Compiles `srcs + test_srcs` together with `gleam compile-package --test`, then runs the
resulting tests via a small EUnit-based runner shim that reuses gleeunit's own test-module
discovery.

- `bazel test --test_output=errors` and JUnit/XML test result output (read by many CI
  systems) both work: a `TEST-XXX.xml` report is written per test module and merged into
  the single file Bazel's `$XML_OUTPUT_FILE` expects.
- `bazel test --test_filter=SUBSTRING` filters at test-*module* (i.e. test file) granularity,
  not individual `_test` function granularity.
- `args` (the attribute) and `--test_arg` are exposed to test code via the `GLEAM_TEST_ARGS`
  environment variable (space-joined), not via argv, since Erlang's `-s Mod Func Arg...`
  mechanism converts each word to an atom, which is lossy for arbitrary strings.
- `shard_count > 1` is rejected at analysis time rather than silently running the whole
  suite redundantly in every shard: sharding support is not implemented yet.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="gleam_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="gleam_test-deps"></a>deps |  Gleam package dependencies (including test deps like gleeunit).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="gleam_test-srcs"></a>srcs |  Source files (typically glob(["src/**/*.gleam", "src/**/*.erl", "src/**/*.mjs"])).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="gleam_test-data"></a>data |  Runtime data dependencies.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="gleam_test-package_name"></a>package_name |  The name of the Gleam package under test.   | String | required |  |
| <a id="gleam_test-test_srcs"></a>test_srcs |  Test files (typically glob(["test/**/*.gleam", "test/**/*.erl", "test/**/*.mjs"])).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |


<a id="GleamPackageInfo"></a>

## GleamPackageInfo

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "GleamPackageInfo")

GleamPackageInfo(<a href="#GleamPackageInfo-compiled_dir">compiled_dir</a>, <a href="#GleamPackageInfo-package_name">package_name</a>, <a href="#GleamPackageInfo-transitive_compiled_dirs">transitive_compiled_dirs</a>, <a href="#GleamPackageInfo-transitive_data">transitive_data</a>)
</pre>

Provider for compiled Gleam package information.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="GleamPackageInfo-compiled_dir"></a>compiled_dir |  TreeArtifact named after the OTP application, containing ebin/ with compiled BEAM files.    |
| <a id="GleamPackageInfo-package_name"></a>package_name |  Name of the Gleam package.    |
| <a id="GleamPackageInfo-transitive_compiled_dirs"></a>transitive_compiled_dirs |  Depset of all transitive compiled TreeArtifacts (including this package's own).    |
| <a id="GleamPackageInfo-transitive_data"></a>transitive_data |  Depset of all transitive runtime data Files (this package's own `data` plus all deps', transitively).    |


<a id="gleam_package"></a>

## gleam_package

<pre>
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_package")

gleam_package(<a href="#gleam_package-name">name</a>, <a href="#gleam_package-srcs">srcs</a>, <a href="#gleam_package-deps">deps</a>, <a href="#gleam_package-data">data</a>, <a href="#gleam_package-package_name">package_name</a>, <a href="#gleam_package-gleam_toml">gleam_toml</a>, <a href="#gleam_package-test_srcs">test_srcs</a>, <a href="#gleam_package-test_deps">test_deps</a>, <a href="#gleam_package-test_data">test_data</a>,
              <a href="#gleam_package-entry_module">entry_module</a>, <a href="#gleam_package-entry_function">entry_function</a>, <a href="#gleam_package-visibility">visibility</a>)
</pre>

Declares a single Gleam package: its library, and optionally its tests and a binary.

This is a convenience macro over `gleam_library`, `gleam_test`, and `gleam_binary` for the
common case of one Bazel package mapping to one Gleam package (one `gleam.toml`). It removes
the need to repeat `package_name`, `srcs`, and `deps` across multiple targets, and (when
`gleam_toml` is passed) validates that the Bazel `package_name` agrees with the `name` field
declared in `gleam.toml`, catching a common source of confusing "unknown module" errors.

If `entry_module` is set, the library target is named `name + "_lib"` and a `gleam_binary`
named `name` is created on top of it, so `bazel run //:name` builds and runs the package's
entry point. Otherwise the library itself is named `name` (there is no binary).

If `test_srcs` is set (non-empty), a `gleam_test` named `name + "_test"` is created,
compiling `srcs + test_srcs` together with `deps + test_deps`, per Gleam's own compilation
model (Gleam always recompiles a package's tests together with its sources; there is no way
to reuse a separately-compiled library artifact for tests).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="gleam_package-name"></a>name |  name of the package; also the name of the binary, if `entry_module` is set.   |  none |
| <a id="gleam_package-srcs"></a>srcs |  Gleam/Erlang/JS source files for the package (typically `glob(["src/**/*.gleam"])`).   |  none |
| <a id="gleam_package-deps"></a>deps |  `gleam_library`/hex_package dependencies of the package.   |  `[]` |
| <a id="gleam_package-data"></a>data |  runtime data dependencies of the package. Do not list `gleam.toml` here if you also pass `gleam_toml` below -- it is added automatically.   |  `[]` |
| <a id="gleam_package-package_name"></a>package_name |  the Gleam package name, as declared in `gleam.toml`. Defaults to `name`.   |  `None` |
| <a id="gleam_package-gleam_toml"></a>gleam_toml |  optional label of the package's `gleam.toml`. It is added to the generated targets' `data` (`gleam compile-package` reads it from the package directory) and used to validate that its `name` field matches `package_name`.   |  `None` |
| <a id="gleam_package-test_srcs"></a>test_srcs |  test source files (typically `glob(["test/**/*.gleam"])`). If omitted or empty, no test target is created.   |  `None` |
| <a id="gleam_package-test_deps"></a>test_deps |  additional dependencies used only by the tests (e.g. `gleeunit`), combined with `deps`.   |  `[]` |
| <a id="gleam_package-test_data"></a>test_data |  additional runtime data used only by the tests, combined with `data`.   |  `[]` |
| <a id="gleam_package-entry_module"></a>entry_module |  the Erlang module name to call at startup (e.g. `"main"`). If set, a `gleam_binary` named `name` is created.   |  `None` |
| <a id="gleam_package-entry_function"></a>entry_function |  the function to call in `entry_module`. Defaults to `"main"`.   |  `"main"` |
| <a id="gleam_package-visibility"></a>visibility |  visibility applied to the generated library/binary/test targets.   |  `None` |


