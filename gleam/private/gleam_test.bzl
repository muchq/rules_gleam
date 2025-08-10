"""Implementation of the gleam_test rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    package_name = ctx.attr.package_name

    # Collect all compiled dependencies and their transitive deps
    dep_output_dirs = []
    dep_srcs = []
    all_dep_dirs = []  # All transitive dependency directories
    
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_info = dep[GleamLibraryProviderInfo]
            dep_output_dirs.append(dep_info.output_pkg_build_dir)
            dep_srcs.extend(dep_info.srcs)
            all_dep_dirs.append(dep_info.output_pkg_build_dir)
            if hasattr(dep_info, "transitive_deps"):
                all_dep_dirs.extend(dep_info.transitive_deps.to_list())

    # Build test directory with compiled test code
    test_output_dir = ctx.actions.declare_directory("test_build_" + package_name)
    
    all_input_items = list(ctx.files.srcs) + list(ctx.files.test_support_srcs) + dep_srcs
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)
    if ctx.files.data:
        all_input_items.extend(ctx.files.data)
    inputs_depset = depset(all_input_items)

    # Build environment with all dependency paths
    env_vars = {}
    all_erl_libs_paths = []
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        all_erl_libs_paths.append(erlang_toolchain.erl_libs_path_str)
    for dep_dir in all_dep_dirs:
        all_erl_libs_paths.append(dep_dir.path)
    if all_erl_libs_paths:
        env_vars["ERL_LIBS"] = ":".join(all_erl_libs_paths)

    # Build and run the tests
    command_script_parts = []
    working_dir_for_gleam = "."
    if ctx.file.gleam_toml:
        toml_dir = ctx.file.gleam_toml.dirname
        if toml_dir and toml_dir != ".":
            working_dir_for_gleam = toml_dir
            command_script_parts.append('cd "{}"'.format(working_dir_for_gleam))

    # First build the test code
    command_script_parts.append(
        '"{}" "{}" build'.format(gleam_exe_wrapper.path, underlying_gleam_tool.path),
    )
    
    # Copy the built test artifacts to our output directory
    gleam_test_output = "build/dev/erlang/" + package_name
    command_script_parts.append(
        'if [ -d "{src}" ]; then mkdir -p "{dst}" && cp -pR "{src}/." "{dst}/"; fi'.format(
            src = gleam_test_output,
            dst = test_output_dir.path,
        ),
    )

    command_str = " && ".join(command_script_parts)

    ctx.actions.run_shell(
        command = command_str,
        inputs = inputs_depset,
        outputs = [test_output_dir],
        env = env_vars,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        progress_message = "Building Gleam tests for {}".format(package_name),
        mnemonic = "GleamBuildTest",
    )

    # Create test runner script
    test_runner_script = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    
    # Build -pa paths for test and all dependencies
    pa_paths = []
    pa_paths.append('"${{TEST_BUILD_DIR}}/ebin"')
    for dep_dir in all_dep_dirs:
        dep_name = dep_dir.basename if hasattr(dep_dir, "basename") else dep_dir.path.split("/")[-1]
        pa_paths.append('"${{TEST_SRCDIR}}/${{WORKSPACE}}/{}/ebin"'.format(dep_dir.short_path))
    
    # Add standard library paths
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        for stdlib in ["gleam_stdlib", "gleam_erlang", "gleeunit"]:
            pa_paths.append('"{}/${}"'.format(erlang_toolchain.erl_libs_path_str, stdlib))
    
    erl_pa_flags = " ".join(["-pa {}".format(p) for p in pa_paths])

    # Determine test runner module (typically package_name_test or gleeunit)
    test_module = ctx.attr.test_module if ctx.attr.test_module else package_name + "_test"
    test_function = ctx.attr.test_function if ctx.attr.test_function else "main"

    script_content = """#!/bin/bash
set -euo pipefail

# Set up test environment
WORKSPACE="{workspace}"
TEST_BUILD_DIR="${{TEST_SRCDIR}}/${{WORKSPACE}}/{test_dir}"

# Ensure test directory exists
if [ ! -d "$TEST_BUILD_DIR" ]; then
  echo "ERROR: Test build directory not found at $TEST_BUILD_DIR" >&2
  exit 1
fi

# Find Erlang runtime
if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang runtime (erl) not found in PATH" >&2
  exit 1
fi

# Set ERL_LIBS if needed
{erl_libs_export}

# Run the tests
exec "$ERL" \
  {pa_flags} \
  -noshell \
  -s {test_module} {test_function} \
  -s init stop \
  -- "$@"
""".format(
        workspace = ctx.workspace_name,
        test_dir = test_output_dir.short_path,
        pa_flags = erl_pa_flags,
        test_module = test_module,
        test_function = test_function,
        erl_libs_export = 'export ERL_LIBS="{}"'.format(env_vars["ERL_LIBS"]) if "ERL_LIBS" in env_vars else "",
    )

    ctx.actions.write(
        output = test_runner_script,
        content = script_content,
        is_executable = True,
    )

    # Collect all files needed for test execution
    runfiles_files = [test_runner_script, test_output_dir]
    runfiles_files.extend(all_dep_dirs)
    if ctx.files.data:
        runfiles_files.extend(ctx.files.data)

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
            doc = "Supporting source files for the test (e.g. main project sources needed for test compilation).",
            allow_files = [".gleam"],
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Gleam library dependencies.",
            providers = [GleamLibraryProviderInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package.",
            mandatory = True,
        ),
        "gleam_toml": attr.label(
            doc = "The gleam.toml file for this test package.",
            allow_single_file = True,
            default = None,
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime data dependencies for the test execution.",
            default = [],
        ),
        "test_module": attr.string(
            doc = "The Erlang module containing the test entry point (default: package_name + '_test').",
            default = "",
        ),
        "test_function": attr.string(
            doc = "The function to call in the test module (default: 'main').",
            default = "",
        ),
    }

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = _gleam_test_attrs(),
    toolchains = ["//gleam:toolchain_type"],
    test = True,
)