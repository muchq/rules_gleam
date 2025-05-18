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

    base_tool_paths = [
        gleam_exe_wrapper.short_path,
        underlying_gleam_tool.short_path,
    ]

    script_content_parts = [
        "#!/bin/sh",
        "set -eu",
        "echo '--- GLEAM TEST RUNNER (REVISED CD/PATH LOGIC V2) ---' >&2",
        'echo "Script path: $0" >&2',
        'echo "Initial PWD: $(pwd)" >&2',
        'echo "TEST_SRCDIR: $TEST_SRCDIR" >&2',
        'echo "TEST_WORKSPACE: $TEST_WORKSPACE" >&2',
    ]

    # --- Determine CD behavior and tool path prefix ---
    path_prefix_for_tools = ""
    # Path for the 'cd' command in the shell script, constructed using shell variables
    shell_cd_command_path_construction = []
    # Starlark-side calculation of the path (relative to $TEST_SRCDIR) that the script will cd into.
    # This is used to calculate path_prefix_for_tools.
    starlark_path_to_cd_target_rel_to_srcdir = ""

    if ctx.file.gleam_toml:
        toml_pkg_dir_starlark = ""
        gleam_toml_label_attr = ctx.attr.gleam_toml
        if gleam_toml_label_attr and hasattr(gleam_toml_label_attr, "label") and hasattr(gleam_toml_label_attr.label, "package"):
            toml_pkg_dir_starlark = gleam_toml_label_attr.label.package

        # Calculate path that will be cd'd into (for Starlark prefix calculation)
        path_to_cd_into_list_starlark = [ctx.workspace_name]
        if toml_pkg_dir_starlark:
            path_to_cd_into_list_starlark.append(toml_pkg_dir_starlark)
        starlark_path_to_cd_target_rel_to_srcdir = "/".join(path_to_cd_into_list_starlark)

        # Add commands to the script to define the actual CD path using shell variables
        script_content_parts.append('TOML_PKG_DIR_SLARK="{}"'.format(toml_pkg_dir_starlark))
        script_content_parts.append('CD_TARGET_DIR_REL_RUNFILES="$TEST_WORKSPACE"')
        script_content_parts.append('if [ -n "$TOML_PKG_DIR_SLARK" ]; then CD_TARGET_DIR_REL_RUNFILES="$TEST_WORKSPACE/$TOML_PKG_DIR_SLARK"; fi')
        script_content_parts.append('ACTUAL_CD_TARGET_PATH="$TEST_SRCDIR/$CD_TARGET_DIR_REL_RUNFILES"')

        num_segments = starlark_path_to_cd_target_rel_to_srcdir.count("/")
        path_prefix_for_tools = "/".join([".."] * (num_segments + 1)) + "/"
    else:
        # No gleam.toml: script runs from Initial PWD.
        # Calculate prefix from Initial PWD back to $TEST_SRCDIR for tools.
        # Initial PWD for //:foo is $TEST_SRCDIR/$TEST_WORKSPACE
        # Initial PWD for //pkg:foo is $TEST_SRCDIR/$TEST_WORKSPACE/pkg
        initial_pwd_rel_to_srcdir_list = [ctx.workspace_name]
        if ctx.label.package:
             initial_pwd_rel_to_srcdir_list.append(ctx.label.package)
        starlark_path_to_cd_target_rel_to_srcdir = "/".join(initial_pwd_rel_to_srcdir_list) # Effective CWD

        num_segments = starlark_path_to_cd_target_rel_to_srcdir.count("/")
        path_prefix_for_tools = "/".join([".."] * (num_segments + 1)) + "/"
        script_content_parts.append('echo "No gleam.toml found, will run from Initial PWD." >&2')

    # --- ERL_LIBS Setup (before potential cd, paths relative to $TEST_SRCDIR) ---
    if "ERL_LIBS" in env_vars:
        erl_libs_value_parts = []
        for lib_path in env_vars["ERL_LIBS"].split(":"):
            if not lib_path.startswith("/"):
                 erl_libs_value_parts.append("$TEST_SRCDIR/" + lib_path)
            else:
                 erl_libs_value_parts.append(lib_path)
        script_content_parts.append('export ERL_LIBS="{}"'.format(":".join(erl_libs_value_parts)))

    # --- Adjust tool paths ---
    adjusted_tool_paths = []
    for p_base in base_tool_paths:
        true_short_path = p_base
        if p_base.startswith("../"): # If short_path starts with ../, assume it implies relative to $TEST_SRCDIR/TEST_WORKSPACE or similar.
                                      # Strip it to get path truly relative to $TEST_SRCDIR root for prefixing.
            true_short_path = p_base[3:]

        # path_prefix_for_tools is the prefix from the CWD (initial or after cd) back to $TEST_SRCDIR.
        # true_short_path is now relative to $TEST_SRCDIR.
        adjusted_tool_paths.append(path_prefix_for_tools + true_short_path)

    script_content_parts.append('echo "Base tool0: {}" >&2'.format(base_tool_paths[0] if base_tool_paths else "N/A"))
    script_content_parts.append('echo "Starlark tool prefix: {}" >&2'.format(path_prefix_for_tools))
    script_content_parts.append('echo "Adjusted tool0 for exec: {}" >&2'.format(adjusted_tool_paths[0] if adjusted_tool_paths else "N/A"))

    # --- Command Execution ---
    command_to_run_in_script_list = [
        adjusted_tool_paths[0],
        adjusted_tool_paths[1],
        "test",
    ]
    command_to_run_in_script_list.extend(ctx.attr.args)

    safe_args_for_exec = []
    for arg in command_to_run_in_script_list:
        safe_args_for_exec.append("'{}'".format(arg.replace("'", "'\\''")))
    inner_command_execution = " ".join(safe_args_for_exec)

    if ctx.file.gleam_toml: # A cd is planned
        script_content_parts.append('echo "Executing (after potential cd to $ACTUAL_CD_TARGET_PATH): {}" >&2'.format(inner_command_execution))
        script_content_parts.append("(cd \"$ACTUAL_CD_TARGET_PATH\" && echo \"Successfully cd-ed. New PWD: $(pwd)\" >&2 && exec {}) || {{ echo \"cd or exec failed\"; exit 1; }}".format(inner_command_execution))
    else: # No gleam.toml, exec from Initial PWD
        script_content_parts.append('echo "Executing (from Initial PWD): {}" >&2'.format(inner_command_execution))
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
