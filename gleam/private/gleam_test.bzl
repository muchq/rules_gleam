"""Implementation of the gleam_test rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    dep_output_dirs = []
    dep_srcs = []  # Collect direct sources from deps for input depset
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_info = dep[GleamLibraryProviderInfo]
            dep_output_dirs.append(dep_info.output_pkg_build_dir)
            dep_srcs.extend(dep_info.srcs)

    all_input_items = list(ctx.files.srcs) + list(ctx.files.test_support_srcs) + dep_srcs
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)

    # Add any explicit data dependencies for the test
    if ctx.files.data:
        all_input_items.extend(ctx.files.data)

    inputs_depset = depset(all_input_items)

    env_vars = {}
    all_erl_libs_paths = []
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        all_erl_libs_paths.append(erlang_toolchain.erl_libs_path_str)
    for dep_dir in dep_output_dirs:
        all_erl_libs_paths.append(dep_dir.path)

    if all_erl_libs_paths:
        env_vars["ERL_LIBS"] = ":".join(all_erl_libs_paths)

    test_runner_script_name = ctx.label.name
    test_runner_script = ctx.actions.declare_file(test_runner_script_name)

    # Base command parts, paths are relative to $TEST_SRCDIR initially
    base_tool_paths = [
        gleam_exe_wrapper.short_path,
        underlying_gleam_tool.short_path,
    ]

    script_content_parts = [
        "#!/bin/sh",
        # --- BEGIN DEBUG ---
        "echo '--- GLEAM TEST RUNNER DEBUG (FULL LOGIC) ---' >&2",
        "echo \\\"Executing script: $0\\\" >&2",
        "echo \\\"PWD: $(pwd)\\\" >&2",
        "echo \\\"TEST_SRCDIR: $TEST_SRCDIR\\\" >&2",
        "echo \\\"TEST_WORKSPACE: $TEST_WORKSPACE\\\" >&2",
        "echo \\\"Listing $TEST_SRCDIR/$TEST_WORKSPACE (target script dir expected location for root package):\\\" >&2",
        "ls -la \\\"$TEST_SRCDIR/$TEST_WORKSPACE/\\\" || echo \\\"Failed to list $TEST_SRCDIR/$TEST_WORKSPACE/ (root package test)\\\" >&2",
        "echo \\\"Listing directory of $0: $(dirname \\\"$0\\\")\\\" >&2",
        "ls -la \\\"$(dirname \\\"$0\\\")\\\" || echo \\\"Failed to list directory of $0\\\" >&2",
        "echo \\\"Target script ($0) details:\\\" >&2",
        "ls -la \\\"$0\\\" || echo \\\"Cannot list $0 itself\\\" >&2",
        "echo \\\"Readlink of $0: $(readlink -f \\\"$0\\\")\\\" >&2",
        "echo \\\"Permissions of readlink target:\\\" >&2",
        "ls -la \\\"$(readlink -f \\\"$0\\\")\\\" || echo \\\"Cannot list readlink target of $0\\\" >&2",
        "echo \\\"--- END GLEAM TEST RUNNER DEBUG ---\' >&2",
        # --- END DEBUG ---
        "set -euo pipefail",
    ]
    path_prefix_from_new_cwd = ""
    actual_cd_path_relative_to_test_srcdir = ""

    if ctx.file.gleam_toml:
        toml_short_path = ctx.file.gleam_toml.short_path
        if "/" in toml_short_path:
            cd_dir = toml_short_path.rsplit("/", 1)[0]
            if cd_dir and cd_dir != ".":
                actual_cd_path_relative_to_test_srcdir = cd_dir
        if actual_cd_path_relative_to_test_srcdir:
            num_segments_in_cd = actual_cd_path_relative_to_test_srcdir.count("/")
            path_prefix_from_new_cwd = "/".join([".."] * (num_segments_in_cd + 1)) + "/"

    adjusted_tool_paths = []
    if actual_cd_path_relative_to_test_srcdir:
        for p in base_tool_paths:
            adjusted_tool_paths.append(path_prefix_from_new_cwd + p)
    else:
        adjusted_tool_paths = base_tool_paths

    command_to_run_in_script_list = [
        adjusted_tool_paths[0],
        adjusted_tool_paths[1],
        "test",
    ]
    command_to_run_in_script_list.extend(ctx.attr.args)

    if "ERL_LIBS" in env_vars:
        erl_libs_for_script = []
        for lib_path in env_vars["ERL_LIBS"].split(":"):
            if lib_path.startswith(ctx.workspace_name + "/") or lib_path.startswith("external/") or not lib_path.startswith("/"):
                erl_libs_for_script.append("$TEST_SRCDIR/" + lib_path)
            else:
                erl_libs_for_script.append(lib_path)
        script_content_parts.append("export ERL_LIBS=\\\"{}\\\";".format(":".join(erl_libs_for_script).replace("\\\"", "\\\\\\\"")))

    inner_command_execution = " ".join(["\\\\\\\"{}\\\\\\\"".format(arg) for arg in command_to_run_in_script_list])

    if actual_cd_path_relative_to_test_srcdir:
        gleam_toml_dir_in_runfiles = "$TEST_SRCDIR/{}".format(actual_cd_path_relative_to_test_srcdir)
        script_content_parts.append("(cd \\\\\\\"{}\\\\\\\" && exec {}) || exit 1".format(gleam_toml_dir_in_runfiles, inner_command_execution))
    else:
        script_content_parts.append("exec {}".format(inner_command_execution))

    script_content = "\\n".join(script_content_parts)

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = script_content,
    )

    runfiles_files = inputs_depset.to_list() + [gleam_exe_wrapper, underlying_gleam_tool, test_runner_script]

    return [
        DefaultInfo(
            executable = test_runner_script,
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

def _gleam_test_attrs():
    return {
        "srcs": attr.label_list(
            doc = "Source .gleam files for the test (typically in 'test' directory).",
            allow_files = [".gleam"],
            mandatory = True,
        ),
        "test_support_srcs": attr.label_list(
            doc = "Supporting source files for the test (e.g. main project sources needed for test compilation, usually from 'src').",
            allow_files = [".gleam"],
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Gleam library dependencies.",
            providers = [GleamLibraryProviderInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package (used by `gleam test` if no gleam.toml).",
        ),
        "gleam_toml": attr.label(
            doc = "The gleam.toml file for this test package. If provided, its directory is used as CWD.",
            allow_single_file = True,
            default = None,
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime data dependencies for the test execution.",
            default = [],
        ),
    }

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = _gleam_test_attrs(),
    toolchains = ["//gleam:toolchain_type"],
    test = True,
)
