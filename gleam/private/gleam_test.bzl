"""Implementation of the gleam_test rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool

    # erlang_toolchain is used for ERL_LIBS if populated by toolchain.
    # If ERL_LIBS logic is removed, this might become unused.
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

    base_tool_paths = [
        gleam_exe_wrapper.short_path,
        underlying_gleam_tool.short_path,
    ]

    script_content_parts = [
        "#!/bin/sh",
        "set -eu",
        "echo '--- GLEAM TEST RUNNER ---' >&2",
        'echo "Script path: $0" >&2',
        'echo "TEST_SRCDIR: $TEST_SRCDIR" >&2',
        'echo "TEST_WORKSPACE: $TEST_WORKSPACE" >&2',
    ]

    path_prefix_from_new_cwd = ""

    # This will be the full path used in the cd command, e.g., $TEST_SRCDIR/$TEST_WORKSPACE/path/to/toml_dir
    full_cd_path_for_script = ""

    # This is the path relative to TEST_SRCDIR that we determined to cd into.
    # Used for calculating the .. prefix for tools.
    path_in_runfiles_to_cd_to = ""

    # Initialize num_segments to 0 as default
    num_segments = 0

    if ctx.file.gleam_toml:
        # ctx.attr.gleam_toml is a Target object (or provides an interface like one here)
        # Access its .label field, then the .package of that Label.
        gleam_toml_target = ctx.attr.gleam_toml
        if gleam_toml_target and hasattr(gleam_toml_target, "label") and hasattr(gleam_toml_target.label, "package"):
            toml_package_dir = gleam_toml_target.label.package
        else:
            # Fallback or error if structure is not as expected
            # This case should ideally not be hit if gleam_toml is a valid label attr.
            # Setting to empty might lead to no cd, which could be default/fallback behavior.
            toml_package_dir = ""
            # Consider fail() if gleam_toml is mandatory for this logic path and structure is unexpected.

        path_parts_for_cd = [ctx.workspace_name]  # Start with TEST_WORKSPACE
        if toml_package_dir:  # Add package path if it exists
            path_parts_for_cd.append(toml_package_dir)

        path_in_runfiles_to_cd_to = "/".join(path_parts_for_cd)
        full_cd_path_for_script = "$TEST_SRCDIR/{}".format(path_in_runfiles_to_cd_to)

        num_segments = path_in_runfiles_to_cd_to.count("/")
        path_prefix_from_new_cwd = "/".join([".."] * (num_segments + 1)) + "/"

    path_prefix_for_tools = "/".join([".."] * (num_segments + 1)) + "/"

    # --- Adjust tool paths ---
    adjusted_tool_paths = []
    for p_base in base_tool_paths:
        true_short_path_relative_to_srcdir = p_base
        if p_base.startswith("../"):
            # If short_path from toolchain gives e.g. "../mangled_repo/tool",
            # assume "mangled_repo/tool" is the path from $TEST_SRCDIR.
            true_short_path_relative_to_srcdir = p_base[3:]

        # path_prefix_for_tools is the prefix needed to go from the CWD (after cd)
        # back to $TEST_SRCDIR. Then append the true_short_path.
        adjusted_tool_paths.append(path_prefix_for_tools + true_short_path_relative_to_srcdir)

    script_content_parts.append('echo "Base tool0: {}" >&2'.format(base_tool_paths[0] if base_tool_paths else "N/A"))

    command_to_run_in_script_list = [
        adjusted_tool_paths[0],
        adjusted_tool_paths[1],
        "test",
    ]

    # Add test_args if specified
    if ctx.attr.test_args:
        command_to_run_in_script_list.extend(ctx.attr.test_args)
        # Otherwise, try to infer the module from the source file

    elif ctx.attr.package_name and len(ctx.files.srcs) == 1:
        test_file = ctx.files.srcs[0]
        module_name = test_file.basename.split(".")[0]  # Remove .gleam extension
        command_to_run_in_script_list.append(module_name)

    command_to_run_in_script_list.extend(ctx.attr.args)

    if "ERL_LIBS" in env_vars:
        erl_libs_value = ":".join(env_vars["ERL_LIBS"].split(":"))
        script_content_parts.append('export ERL_LIBS="{}"'.format(erl_libs_value))

    safe_args_for_exec = []
    for arg in command_to_run_in_script_list:
        safe_args_for_exec.append("'{}'".format(arg.replace("'", "'\\''")))
    inner_command_execution = " ".join(safe_args_for_exec)

    # Add debug output to show the command being executed
    script_content_parts.append('echo "Command to execute: {}" >&2'.format(inner_command_execution))

    if full_cd_path_for_script:
        script_content_parts.append('echo "Attempting to cd to: {}" >&2'.format(full_cd_path_for_script))
        script_content_parts.append('(cd "{}" && echo "Successfully cd-ed. New PWD: $(pwd)" >&2 && exec {}) || exit 1'.format(full_cd_path_for_script, inner_command_execution))
    else:
        script_content_parts.append('echo "No cd needed (or gleam.toml not provided). Executing from PWD: $(pwd)\" >&2')
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
        "test_args": attr.string_list(
            doc = "Additional arguments to pass to the gleam test command.",
            default = [],
        ),
    }

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = _gleam_test_attrs(),
    toolchains = ["//gleam:toolchain_type"],
    test = True,
    doc = """
    A rule to run Gleam tests.

    When using this rule, you need to follow Gleam's naming conventions:
    - For a package named "my_package" (as defined in gleam.toml), the test file should be named "my_package_test.gleam"
    - Alternatively, you can use the test_args parameter to explicitly specify the test module to run

    Example:
    ```
    gleam_test(
        name = "my_package_test",
        package_name = "my_package",
        srcs = ["test/my_package_test.gleam"],
        gleam_toml = ":gleam.toml",
        deps = [":my_package_lib"],
    )
    ```
    """,
)
