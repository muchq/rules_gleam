"""Implementation of the gleam_test rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    dep_output_dirs = []
    dep_srcs = []
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_info = dep[GleamLibraryProviderInfo]
            dep_output_dirs.append(dep_info.output_pkg_build_dir)
            dep_srcs.extend(dep_info.srcs)

    all_input_items = list(ctx.files.srcs) + list(ctx.files.test_support_srcs) + dep_srcs
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)
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

    test_runner_script_name = ctx.label.name + "_test_runner.sh"
    test_runner_script = ctx.actions.declare_file(test_runner_script_name)

    script_content_parts = [
        "#!/bin/sh",
        "set -eu", # For POSIX sh compatibility, was -euo pipefail
        "echo '--- GLEAM TEST RUNNER (CI Passing Baseline Logic) ---' >&2",
        'echo "Script path: $0" >&2',
        'echo "Initial PWD: $(pwd)" >&2',
        'echo "TEST_SRCDIR: $TEST_SRCDIR" >&2',
        'echo "TEST_WORKSPACE: $TEST_WORKSPACE" >&2',
    ]

    if "ERL_LIBS" in env_vars:
        erl_libs_value_for_script = []
        for lib_path in env_vars["ERL_LIBS"].split(":"):
            # Make paths runfile-relative if they are not absolute system paths
            if not lib_path.startswith("/"):
                erl_libs_value_for_script.append("$TEST_SRCDIR/" + lib_path)
            else:
                erl_libs_value_for_script.append(lib_path)
        script_content_parts.append('export ERL_LIBS="{}"'.format(":".join(erl_libs_value_for_script)))

    command_to_run_in_script_list = [
        gleam_exe_wrapper.short_path, # These are relative to $TEST_SRCDIR
        underlying_gleam_tool.short_path,
        "test",
    ]
    command_to_run_in_script_list.extend(ctx.attr.args)

    safe_args_for_exec = []
    for arg in command_to_run_in_script_list:
        safe_args_for_exec.append("'{}'".format(arg.replace("'", "'\\''"))) # Shell-escape arguments
    inner_command_execution = " ".join(safe_args_for_exec)

    script_content_parts.append('echo "Executing (from PWD: $(pwd)): {}" >&2'.format(inner_command_execution))
    script_content_parts.append("exec {}".format(inner_command_execution))

    script_content = "\n".join(script_content_parts)

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
