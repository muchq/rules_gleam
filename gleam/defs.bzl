"""Public API for the Gleam Bazel rules."""

load("//gleam/private:gleam_binary.bzl", _gleam_binary_rule = "gleam_binary")
load("//gleam/private:gleam_library.bzl", _GleamPackageInfo = "GleamPackageInfo", _gleam_library_rule = "gleam_library")
load("//gleam/private:gleam_test.bzl", _gleam_test_rule = "gleam_test")
load("//gleam/private:package_name_check.bzl", "gleam_package_name_check")

gleam_library = _gleam_library_rule
gleam_binary = _gleam_binary_rule
gleam_test = _gleam_test_rule
GleamPackageInfo = _GleamPackageInfo

def gleam_package(
        name,
        srcs,
        deps = [],
        data = [],
        package_name = None,
        gleam_toml = None,
        test_srcs = None,
        test_deps = [],
        test_data = [],
        entry_module = None,
        entry_function = "main",
        visibility = None):
    """Declares a single Gleam package: its library, and optionally its tests and a binary.

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

    Args:
        name: name of the package; also the name of the binary, if `entry_module` is set.
        srcs: Gleam/Erlang/JS source files for the package (typically
            `glob(["src/**/*.gleam"])`).
        deps: `gleam_library`/hex_package dependencies of the package.
        data: runtime data dependencies of the package. Do not list `gleam.toml` here if you
            also pass `gleam_toml` below -- it is added automatically.
        package_name: the Gleam package name, as declared in `gleam.toml`. Defaults to `name`.
        gleam_toml: optional label of the package's `gleam.toml`. It is added to the library's
            `data` and used to validate that its `name` field matches `package_name`.
        test_srcs: test source files (typically `glob(["test/**/*.gleam"])`). If omitted or
            empty, no test target is created.
        test_deps: additional dependencies used only by the tests (e.g. `gleeunit`), combined
            with `deps`.
        test_data: additional runtime data used only by the tests, combined with `data`.
        entry_module: the Erlang module name to call at startup (e.g. `"main"`). If set, a
            `gleam_binary` named `name` is created.
        entry_function: the function to call in `entry_module`. Defaults to `"main"`.
        visibility: visibility applied to the generated library/binary/test targets.
    """
    resolved_package_name = package_name if package_name != None else name
    lib_name = name + "_lib" if entry_module else name

    lib_data = list(data)
    if gleam_toml:
        # Keep gleam.toml itself available as a data input (matching the historical
        # convention of declaring it directly), plus the validation marker below.
        lib_data.append(gleam_toml)
        check_name = name + "_gleam_toml_check"
        gleam_package_name_check(
            name = check_name,
            gleam_toml = gleam_toml,
            package_name = resolved_package_name,
        )
        lib_data.append(":" + check_name)

    gleam_library(
        name = lib_name,
        package_name = resolved_package_name,
        srcs = srcs,
        deps = deps,
        data = lib_data,
        visibility = visibility,
    )

    if entry_module:
        gleam_binary(
            name = name,
            dep = ":" + lib_name,
            entry_module = entry_module,
            entry_function = entry_function,
            visibility = visibility,
        )

    if test_srcs:
        gleam_test(
            name = name + "_test",
            package_name = resolved_package_name,
            srcs = srcs,
            test_srcs = test_srcs,
            deps = deps + test_deps,
            data = data + test_data,
            visibility = visibility,
        )
