"""Implementation of the gleam_test rule.

Uses `gleam compile-package --test` to compile both source and test files,
then runs the tests via `erl` with gleeunit as the entry point.
"""

load("//gleam/private:gleam_library.bzl", "GleamPackageInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    package_name = ctx.attr.package_name

    # Declare compiled output directory.
    compiled_dir = ctx.actions.declare_directory("_gleam_test_pkg/" + package_name)

    # Collect dependency info.
    dep_infos = []
    transitive_dep_sets = []
    for dep in ctx.attr.deps:
        if GleamPackageInfo in dep:
            dep_info = dep[GleamPackageInfo]
            dep_infos.append(dep_info)
            transitive_dep_sets.append(dep_info.transitive_compiled_dirs)

    # All transitive dep dirs (flattened for inputs and -pa flags).
    all_dep_dirs = depset(transitive = transitive_dep_sets)

    # Prepare inputs.
    input_files = list(ctx.files.srcs) + list(ctx.files.test_srcs)
    if ctx.files.data:
        input_files.extend(ctx.files.data)
    inputs_depset = depset(
        direct = input_files,
        transitive = [all_dep_dirs],
    )

    # Determine src and test directories from file paths.
    src_dir = _get_dir(ctx.files.srcs, "src")

    # Build the compile command.
    cmd_parts = []

    # Sandbox-safe XDG dirs.
    cmd_parts.append("export XDG_CACHE_HOME=$(pwd)/.cache")
    cmd_parts.append("export XDG_DATA_HOME=$(pwd)/.local/share")

    # Set up --lib directory with symlinks to dep outputs.
    cmd_parts.append("mkdir -p _gleam_lib")
    for dep_info in dep_infos:
        cmd_parts.append('ln -s "$(pwd)/{compiled}" "_gleam_lib/{name}"'.format(
            compiled = dep_info.compiled_dir.path,
            name = dep_info.package_name,
        ))

    # Compile with --test flag to include test sources.
    compile_cmd = '"{wrapper}" "{tool}" compile-package --target=erlang --package="$(pwd)/{src}" --out="$(pwd)/{out}" --lib="$(pwd)/_gleam_lib"'.format(
        wrapper = gleam_exe_wrapper.path,
        tool = underlying_gleam_tool.path,
        src = src_dir,
        out = compiled_dir.path,
    )
    cmd_parts.append(compile_cmd)

    compile_command = " && ".join(cmd_parts)

    ctx.actions.run_shell(
        command = compile_command,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        inputs = inputs_depset,
        outputs = [compiled_dir],
        progress_message = "Compiling Gleam tests: " + package_name,
        mnemonic = "GleamCompileTest",
    )

    # Create the test runner script that invokes erl.
    test_runner_script = ctx.actions.declare_file(ctx.label.name + "_test_runner.sh")

    erl_path = "erl"
    if hasattr(erlang_toolchain, "erl_path_str") and erlang_toolchain.erl_path_str:
        erl_path = erlang_toolchain.erl_path_str

    # Build -pa flags for compiled test output + all dep ebin dirs.
    # At test runtime, paths are relative to $TEST_SRCDIR/$WORKSPACE.
    ws_name = ctx.workspace_name
    compiled_runtime_path = "$TEST_SRCDIR/{ws}/{path}".format(
        ws = ws_name,
        path = compiled_dir.short_path,
    )

    pa_parts = ['-pa "{}/ebin"'.format(compiled_runtime_path)]
    for dep_dir in all_dep_dirs.to_list():
        dep_runtime_path = "$TEST_SRCDIR/{ws}/{path}".format(
            ws = ws_name,
            path = dep_dir.short_path,
        )
        pa_parts.append('-pa "{}/ebin"'.format(dep_runtime_path))

    pa_flags = " ".join(pa_parts)

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = """#!/bin/bash
# Test runner for Gleam tests: {label}
set -e

exec "{erl_path}" {pa_flags} -noshell -s gleeunit main -s init stop
""".format(
            label = ctx.label.name,
            erl_path = erl_path,
            pa_flags = pa_flags,
        ),
    )

    # Runfiles: test runner needs the compiled test dir + all dep dirs.
    runfiles_files = [compiled_dir] + all_dep_dirs.to_list()

    return [
        DefaultInfo(
            executable = test_runner_script,
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

def _get_dir(files, expected_component):
    """Derive a directory path from files by looking for an expected path component."""
    if not files:
        fail("No files provided for '{}' directory.".format(expected_component))

    first_file = files[0]
    path = first_file.path
    parts = path.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == expected_component:
            if expected_component == "src":
                return "/".join(parts[:i])
            return "/".join(parts[:i + 1])

    # Fallback: directory of the first file.
    return first_file.dirname

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files (typically glob([\"src/**/*.gleam\", \"src/**/*.erl\", \"src/**/*.mjs\"])).",
            allow_files = [".gleam", ".erl", ".mjs"],
            mandatory = True,
        ),
        "test_srcs": attr.label_list(
            doc = "Test files (typically glob([\"test/**/*.gleam\", \"test/**/*.erl\", \"test/**/*.mjs\"])).",
            allow_files = [".gleam", ".erl", ".mjs"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Gleam package dependencies (including test deps like gleeunit).",
            providers = [GleamPackageInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package under test.",
            mandatory = True,
        ),
        "data": attr.label_list(
            doc = "Runtime data dependencies.",
            allow_files = True,
            default = [],
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    test = True,
)
