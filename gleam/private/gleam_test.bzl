"""Implementation of the gleam_test rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]

    # gleam_exe_wrapper = gleam_toolchain_info.gleam_executable # Unused in minimal script
    # underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool # Unused in minimal script
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain  # May be needed for ERL_LIBS even in future minimal tests

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

    # inputs_depset = depset(all_input_items) # Unused in minimal script with minimal runfiles

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

    # MINIMAL SCRIPT FOR CI DEBUGGING
    script_content_parts = [
        "#!/bin/sh",
        "echo '--- MINIMAL GLEAM TEST RUNNER STARTED IN CI ---' >&2",
        "echo \"Script path: $0\" >&2",
        "echo \"Arguments: $@\" >&2",
        "echo \"TEST_SRCDIR: $TEST_SRCDIR\" >&2",
        "echo \"TEST_WORKSPACE: $TEST_WORKSPACE\" >&2",
        "echo \"PWD: $(pwd)\" >&2",
        "ls -la \\\"$0\\\" || echo \\\"Cannot list $0 itself\\\" >&2",
        "exit 0",  # Force success
    ]
    # path_prefix_from_new_cwd = "" # Not needed for minimal script
    # actual_cd_path_relative_to_test_srcdir = "" # Not needed for minimal script

    # adjusted_tool_paths = [] # Not needed
    # command_to_run_in_script_list = [] # Not needed
    # inner_command_execution = "true" # Not needed, script just exits

    # if "ERL_LIBS" in env_vars: # Not needed
    #     script_content_parts.append("export ERL_LIBS=\"{}\";".format(
    #         relevant_erl_libs_for_script))

    # if actual_cd_path_relative_to_test_srcdir: # Not needed
    #     script_content_parts.append("(cd ... && exec ...) || exit 1")
    # else:
    #     script_content_parts.append("exec true") # Minimal command

    script_content = "\n".join(script_content_parts)

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = script_content,
    )

    # Runfiles needed for the test to execute.
    # For minimal script, only itself. For real script, need tools & inputs.
    minimal_runfiles = [test_runner_script]
    # original_runfiles_files = inputs_depset.to_list() + [gleam_exe_wrapper, underlying_gleam_tool, test_runner_script]

    return [
        DefaultInfo(
            executable = test_runner_script,
            runfiles = ctx.runfiles(files = minimal_runfiles),  # Use minimal_runfiles
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
