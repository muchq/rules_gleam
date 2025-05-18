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
        "echo '--- GLEAM TEST RUNNER (FULL LOGIC - V3) ---' >&2",
        'echo "Script path: $0" >&2',
        'echo "Initial PWD: $(pwd)" >&2',
        'echo "TEST_SRCDIR: $TEST_SRCDIR" >&2',
        'echo "TEST_WORKSPACE: $TEST_WORKSPACE" >&2',
    ]

    path_prefix_from_new_cwd = ""
    full_cd_path_for_script = ""
    path_in_runfiles_to_cd_to = ""

    if ctx.file.gleam_toml:
        gleam_toml_target = ctx.attr.gleam_toml
        if gleam_toml_target and hasattr(gleam_toml_target, "label") and hasattr(gleam_toml_target.label, "package"):
            toml_package_dir = gleam_toml_target.label.package
        else:
            toml_package_dir = ""

        path_parts_for_cd = [ctx.workspace_name]
        if toml_package_dir:
            path_parts_for_cd.append(toml_package_dir)

        path_in_runfiles_to_cd_to = "/".join(path_parts_for_cd)
        full_cd_path_for_script = "$TEST_SRCDIR/{}".format(path_in_runfiles_to_cd_to)

        num_segments = path_in_runfiles_to_cd_to.count("/")
        path_prefix_from_new_cwd = "/".join([".."] * (num_segments + 1)) + "/"

    adjusted_tool_paths = []
    if full_cd_path_for_script:  # If we are going to cd
        for p_base in base_tool_paths:
            # If path_prefix_from_new_cwd is "../" (i.e., cd to $TEST_SRCDIR/WORKSPACE_NAME)
            # AND p_base (the short_path) also starts with "../" (meaning it's already relative to $TEST_SRCDIR/WORKSPACE_NAME)
            # then use p_base as is. This handles the smoke test case where short_path is unusual.
            if path_prefix_from_new_cwd == "../" and p_base.startswith("../"):
                adjusted_tool_paths.append(p_base)
            else:
                # Default behavior: prepend the calculated prefix to the base short_path.
                # This should work for deeper cd and for base_paths that don't start with ../.
                adjusted_tool_paths.append(path_prefix_from_new_cwd + p_base)
    else:  # No cd planned (e.g., no gleam.toml provided)
        adjusted_tool_paths = base_tool_paths

    # --- MORE DEBUG ---
    script_content_parts.append('echo "Base tool path 0: {}" >&2'.format(base_tool_paths[0] if len(base_tool_paths) > 0 else "N/A"))
    script_content_parts.append('echo "Path prefix from new CWD: {}" >&2'.format(path_prefix_from_new_cwd))
    script_content_parts.append('echo "Adjusted tool path 0: {}" >&2'.format(adjusted_tool_paths[0] if len(adjusted_tool_paths) > 0 else "N/A"))
    # --- END MORE DEBUG ---

    command_to_run_in_script_list = [
        adjusted_tool_paths[0],
        adjusted_tool_paths[1],
        "test",
    ]
    command_to_run_in_script_list.extend(ctx.attr.args)

    if "ERL_LIBS" in env_vars:
        erl_libs_value = ":".join(env_vars["ERL_LIBS"].split(":"))
        script_content_parts.append('export ERL_LIBS="{}"'.format(erl_libs_value))

    # For the echo, print what will actually be executed
    # The actual command uses adjusted_tool_paths which are already prefixed
    echo_command_list = list(command_to_run_in_script_list) # Create a copy for echoing
    # For echoing, we want to show the paths as they would be if CWD was TEST_SRCDIR
    # This means we need to show the non-prefixed tool paths if a cd is happening.
    # However, the existing echo prints inner_command_execution which IS the prefixed one.

    safe_args_for_exec = []
    for arg in command_to_run_in_script_list: # command_to_run_in_script_list uses adjusted_tool_paths
        safe_args_for_exec.append("'{}'".format(arg.replace("'", "'\\''")))
    inner_command_execution = " ".join(safe_args_for_exec)

    if full_cd_path_for_script:
        script_content_parts.append('echo "Executing (from PWD: $(pwd)): {}" >&2'.format(inner_command_execution))
        script_content_parts.append("(cd \"{}\" && echo \"Successfully cd-ed. New PWD: $(pwd)\" >&2 && exec {}) || exit 1".format(full_cd_path_for_script, inner_command_execution))
    else:
        script_content_parts.append('echo "No cd needed. Executing (from PWD: $(pwd)): {}" >&2'.format(inner_command_execution))
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
