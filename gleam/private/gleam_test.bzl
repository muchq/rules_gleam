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

    test_runner_script_name = ctx.label.name + "_test_runner.sh"
    test_runner_script = ctx.actions.declare_file(test_runner_script_name)

    # Command to be executed by the test runner script.
    # Calls the gleam_exe_wrapper, which expects the underlying_gleam_tool path as its first argument.
    command_to_run_in_script_list = [
        gleam_exe_wrapper.short_path,  # The wrapper script path (relative to runfiles root)
        underlying_gleam_tool.short_path,  # Arg $1 to wrapper: actual gleam binary (relative to runfiles root)
        "test",  # Arg $2 to wrapper (becomes $1 to gleam): the gleam command
    ]

    # Add any user-provided arguments for `gleam test`
    command_to_run_in_script_list.extend(ctx.attr.args)

    script_content_parts = ["#!/bin/bash", "set -euo pipefail"]

    # Export ERL_LIBS if it's populated
    if "ERL_LIBS" in env_vars:
        # Ensure ERL_LIBS paths are quoted if they contain spaces (though unlikely for execpaths)
        # And ensure $TEST_SRCDIR is prepended to make them absolute within the test sandbox.
        erl_libs_for_script = []
        for lib_path in env_vars["ERL_LIBS"].split(":"):
            # Paths from dep_dir.path are execpaths, should be relative to TEST_SRCDIR
            # Paths from erlang_toolchain.erl_libs_path_str are absolute system paths, leave as is.
            if lib_path.startswith(ctx.workspace_name + "/") or lib_path.startswith("external/") or not lib_path.startswith("/"):
                erl_libs_for_script.append("$TEST_SRCDIR/" + lib_path)
            else:
                erl_libs_for_script.append(lib_path)
        script_content_parts.append("export ERL_LIBS=\"{}\";".format(":".join(erl_libs_for_script).replace("\"", "\\\"")))

    inner_command_execution = " ".join(["\"{}\"".format(arg) for arg in command_to_run_in_script_list])

    # Change directory if gleam.toml is provided
    if ctx.file.gleam_toml:
        # The path to gleam.toml's directory within the test runfiles.
        gleam_toml_dir_in_runfiles = "$TEST_SRCDIR/{}/{}".format(ctx.workspace_name, ctx.file.gleam_toml.dirname)
        script_content_parts.append("(cd \"{}\" && exec {}) || exit 1".format(gleam_toml_dir_in_runfiles, inner_command_execution))
    else:
        script_content_parts.append("exec {}".format(inner_command_execution))

    script_content = "\n".join(script_content_parts)

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = script_content,
    )

    # Runfiles needed for the test to execute.
    # This includes all inputs to the gleam compilation (srcs, deps) and the gleam toolchain itself.
    runfiles_files = inputs_depset.to_list() + [gleam_exe_wrapper, underlying_gleam_tool]
    # If gleam.toml is used for CWD, ensure its directory contents are available if not already srcs.

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
            # Not strictly mandatory for `gleam test` if gleam.toml is present, but good for consistency.
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
        # Standard test attributes (size, timeout, etc.) are implicitly added by `test = True`.
    }

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = _gleam_test_attrs(),
    toolchains = ["//gleam:toolchain_type"],
    test = True,  # This marks the rule as a test rule.
)
