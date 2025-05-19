"""Implementation of the gleam_binary rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_binary_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    package_name = ctx.attr.package_name

    # `gleam export erlang-shipment` creates output in `build/erlang-shipment` relative to CWD.
    # We declare a directory for Bazel to track this output.
    gleam_export_output_dir_name = "erlang_shipment_for_" + package_name
    gleam_export_output_dir = ctx.actions.declare_directory(gleam_export_output_dir_name)

    dep_output_dirs = []
    dep_srcs = []
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_info = dep[GleamLibraryProviderInfo]
            dep_output_dirs.append(dep_info.output_pkg_build_dir)
            dep_srcs.extend(dep_info.srcs)

    all_input_items = list(ctx.files.srcs) + dep_srcs
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)
    inputs_depset = depset(all_input_items)

    env_vars = {}
    all_erl_libs_paths = []
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        all_erl_libs_paths.append(erlang_toolchain.erl_libs_path_str)
    for dep_dir in dep_output_dirs:
        all_erl_libs_paths.append(dep_dir.path)
    if all_erl_libs_paths:
        env_vars["ERL_LIBS"] = ":".join(all_erl_libs_paths)

    command_script_parts = []
    working_dir_for_gleam = "."  # Default to execroot
    path_prefix_to_execroot = ""

    if ctx.file.gleam_toml:
        toml_dir = ctx.file.gleam_toml.dirname
        if toml_dir and toml_dir != ".":
            working_dir_for_gleam = toml_dir
            command_script_parts.append('cd "{}"'.format(working_dir_for_gleam))

            # Calculate prefix to get from toml_dir back to execroot
            num_segments = toml_dir.count("/")
            path_prefix_to_execroot = "/".join([".."] * (num_segments + 1)) + "/"

    # Gleam export command. It outputs to <CWD>/build/erlang-shipment.
    # The wrapper script expects the actual gleam binary path as its first argument.
    # Prepend path_prefix_to_execroot if we changed directory.
    wrapper_exec_path = path_prefix_to_execroot + gleam_exe_wrapper.path
    underlying_tool_exec_path = path_prefix_to_execroot + underlying_gleam_tool.path
    command_script_parts.append(
        '"{}" "{}" export erlang-shipment'.format(wrapper_exec_path, underlying_tool_exec_path),
    )

    # Define this before using it in debug block
    gleam_created_shipment_path_relative_to_cwd = "build/erlang-shipment"

    # --- BEGIN EXPORT DEBUG ---
    command_script_parts.append("echo '--- DEBUG: After gleam export, before cp in gleam_binary ---'")
    command_script_parts.append("echo \'PWD for export: $(pwd)\'")
    command_script_parts.append("echo \'Checking source dir for cp: \"{}\"\'".format(gleam_created_shipment_path_relative_to_cwd))
    # Attempt to list the source directory; provide a fallback message if ls fails (e.g. dir doesn't exist)
    command_script_parts.append("(ls -laR \"{}\" || echo \'Source dir {} not found or ls failed.\')".format(gleam_created_shipment_path_relative_to_cwd, gleam_created_shipment_path_relative_to_cwd))
    command_script_parts.append("echo \'--- END EXPORT DEBUG ---'")
    # --- END EXPORT DEBUG ---

    # Source of shipment, relative to `working_dir_for_gleam` (where gleam export was run)
    # gleam_created_shipment_path_relative_to_cwd = "build/erlang-shipment" # Defined before debug block

    # Destination: absolute path to the Bazel-declared TreeArtifact in the sandbox
    declared_bazel_output_dir_path = gleam_export_output_dir.path

    # Copy the generated shipment into the Bazel-declared output directory.
    copy_block_string = (
        'if [ -d "{src}" ]; then ' +
            'echo "Source dir {src} found. Preparing to copy to {dst}."; ' +
            'mkdir -p "{dst}" && ' +
            'echo "Destination dir {dst} ensured by mkdir -p."; ' +
            'cp -r "{src}/." "{dst}/" && ' +
            'echo "cp command completed. Listing destination {dst}:"; ' +
            'ls -laR "{dst}"; ' +
            'echo "Copy successful to {dst}."; ' +
        'else ' +
            'echo "Gleam export source dir {src} not found after running in $PWD! This is an error."; exit 1; ' +
        'fi'
    )
    command_script_parts.append(copy_block_string.format(
        src=gleam_created_shipment_path_relative_to_cwd,
        dst=declared_bazel_output_dir_path,
    ))

    command_str = " && ".join(command_script_parts)

    ctx.actions.run_shell(
        command = command_str,
        inputs = inputs_depset,
        outputs = [gleam_export_output_dir],
        env = env_vars,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        progress_message = "Exporting Gleam release for {}".format(package_name),
        mnemonic = "GleamExportRelease",
    )

    # Create a wrapper script to run the binary.
    # This script will be the executable for the gleam_binary rule.
    runner_script_name = ctx.label.name + "_runner.sh"
    runner_script = ctx.actions.declare_file(runner_script_name)

    # Erlang evaluation details
    # Gleam convention is that there should be a main/0 function in a module with the same name as the package
    # However, when Gleam compiles to Erlang, the main module is typically named package_name@@main
    erl_target_module_atom = "'{}'".format(package_name + "@@main")
    erl_target_function_atom = "'main'"
    erl_target_function_args = "[]"

    # Construct -pa paths for Erlang. These paths are inside the runfiles shipment directory.
    # Paths are relative to where the `erl` command will be run from (inside the wrapper script).
    # $SHIPMENT_DIR will be defined in the script to point to the root of the copied shipment.
    pa_paths_in_script = [
        '"$SHIPMENT_DIR/{}/ebin"'.format(package_name),  # App's own compiled BEAMs (e.g., my_app/ebin which has main.beam)
        '"$SHIPMENT_DIR/gleam_stdlib/ebin"',  # Gleam stdlib
        '"$SHIPMENT_DIR/gleeunit/ebin"', # gleeunit is a common dep and seen in shipment
    ]
    erl_pa_flags = " ".join(["-pa {}".format(p) for p in pa_paths_in_script])

    # Erlang command to execute the main function.
    # init:stop() is important for the Erlang VM to exit after main returns.
    eval_part1 = "code:ensure_loaded({})".format(erl_target_module_atom)
    eval_part2 = "erlang:apply({}, {}, {})".format(erl_target_module_atom, erl_target_function_atom, erl_target_function_args)
    eval_part3 = "init:stop()"
    erl_eval_cmd = eval_part1 + ", " + eval_part2 + ", " + eval_part3

    # Ensure the eval string is properly escaped for the shell script
    # by only escaping double quotes. Single quotes for atoms are fine.
    shell_safe_eval_code = erl_eval_cmd.replace('"', '\\"')

    ctx.actions.write(
        output = runner_script,
        is_executable = True,
        content = """#!/bin/bash
# Runner script for Gleam binary: {pkg_name}
set -e

# Determine RUNFILES_DIR. This is a common Bazel pattern.
RUNFILES_DIR_FROM_SCRIPT_PATH="$0.runfiles"
if [ -z "$RUNFILES_DIR" ]; then
  if [ -d "$RUNFILES_DIR_FROM_SCRIPT_PATH" ]; then
    RUNFILES_DIR="$RUNFILES_DIR_FROM_SCRIPT_PATH"
  elif [ -d "_main.runfiles" ]; then # Common fallback for 'bazel run' from workspace root
    RUNFILES_DIR="_main.runfiles"
  elif [ -d "../_main.runfiles" ]; then # Common fallback for 'bazel run' from bazel-bin/pkg
    RUNFILES_DIR="../_main.runfiles"
  else
    echo "ERROR: RUNFILES_DIR not set and could not be determined for {pkg_name}. Exiting." >&2
    exit 1
  fi
fi

# Path to the root of the Erlang shipment within runfiles.
SHIPMENT_DIR=\"$RUNFILES_DIR/{ws_name}/{shipment_short_path}\"

# Debug output
echo "Looking for shipment in: $SHIPMENT_DIR"

# Try to locate the real shipment directory by resolving symlinks
if [ -L "$SHIPMENT_DIR" ]; then
  REAL_SHIPMENT_DIR=$(readlink -f "$SHIPMENT_DIR")
  echo "Shipment directory is a symlink pointing to: $REAL_SHIPMENT_DIR"
  SHIPMENT_DIR="$REAL_SHIPMENT_DIR"
fi

# If the shipment directory doesn't exist or is empty, try a more direct approach
if [ ! -d "$SHIPMENT_DIR" ] || [ -z "$(ls -A "$SHIPMENT_DIR" 2>/dev/null)" ]; then
  echo "Shipment directory is empty or not found. Looking in bazel output directories..."

  # Try to find the sandbox stash directory that contains the shipment
  SANDBOX_STASH_PATTERN="/private/var/tmp/_bazel_*/*/sandbox/sandbox_stash/GleamExportRelease/*/execroot/_main/*/{shipment_short_path}"

  for dir in $(find /private/var/tmp/_bazel_* -path "*sandbox/sandbox_stash/GleamExportRelease*/*/{shipment_short_path}" -type d 2>/dev/null); do
    if [ -d "$dir" ] && [ -d "$dir/{pkg_name}" ] && [ -d "$dir/{pkg_name}/ebin" ]; then
      echo "Found sandbox stash directory with shipment: $dir"
      SHIPMENT_DIR="$dir"
      break
    fi
  done
fi

# Erlang executable from the toolchain (should be on PATH due to toolchain wrapper)
ERL_EXECUTABLE=\"erl\"

# Enable more verbose output for debugging
echo "Shipment directory: $SHIPMENT_DIR"
echo "Package name: {pkg_name}"
echo "Contents of shipment:"
ls -la "$SHIPMENT_DIR"

# Set up a variable for the package directory
PKG_DIR="$SHIPMENT_DIR/{pkg_name}"
if [ -d "$PKG_DIR" ]; then
  echo "Found package directory: $PKG_DIR"
else
  echo "ERROR: Package directory not found at $PKG_DIR"
  exit 1
fi

# Check for ebin directory
EBIN_DIR="$PKG_DIR/ebin"
if [ -d "$EBIN_DIR" ]; then
  echo "Found ebin directory: $EBIN_DIR"
  echo "Contents:"
  ls -la "$EBIN_DIR"
else
  echo "ERROR: ebin directory not found at $EBIN_DIR"
  exit 1
fi

# Look for the main module - try both formats
FOUND_MODULE=""
if [ -f "$EBIN_DIR/{pkg_name}@@main.beam" ]; then
  FOUND_MODULE="{pkg_name}@@main"
  echo "Found module: $FOUND_MODULE"
elif [ -f "$EBIN_DIR/{pkg_name}.beam" ]; then
  FOUND_MODULE="{pkg_name}"
  echo "Found module: $FOUND_MODULE"
else
  echo "ERROR: Could not find main module in $EBIN_DIR"
  echo "Expected either {pkg_name}@@main.beam or {pkg_name}.beam"
  exit 1
fi

# Build paths for the -pa flags
DYNAMIC_PA_FLAGS=""

# First add the package's ebin directory
DYNAMIC_PA_FLAGS="$DYNAMIC_PA_FLAGS -pa $EBIN_DIR"

# Then add standard library paths
for lib_dir in "$SHIPMENT_DIR"/*; do
  if [ -d "$lib_dir/ebin" ] && [ "$lib_dir" != "$PKG_DIR" ]; then
    DYNAMIC_PA_FLAGS="$DYNAMIC_PA_FLAGS -pa $lib_dir/ebin"
    echo "Adding path: $lib_dir/ebin"
  fi
done

# Execute the Erlang runtime with the specified module and function.
echo "Using module: $FOUND_MODULE"
echo "Using PA flags: $DYNAMIC_PA_FLAGS"

# Try a hardcoded approach for module name
if [ "$FOUND_MODULE" = "{pkg_name}@@main" ]; then
  # Try module with @@main
  echo "Using module: {pkg_name}@@main"
  $ERL_EXECUTABLE $DYNAMIC_PA_FLAGS -noshell \
    -eval "code:ensure_loaded('{pkg_name}@@main'), erlang:apply('{pkg_name}@@main', main, []), init:stop()" \
    2>/dev/null && exit 0

  # Fallback to module without @@main
  echo "First attempt failed, trying: {pkg_name}"
  exec $ERL_EXECUTABLE $DYNAMIC_PA_FLAGS -noshell \
    -eval "code:ensure_loaded('{pkg_name}'), erlang:apply('{pkg_name}', main, []), init:stop()" \
    -- "$@"
else
  # Try module without @@main
  echo "Using module: {pkg_name}"
  $ERL_EXECUTABLE $DYNAMIC_PA_FLAGS -noshell \
    -eval "code:ensure_loaded('{pkg_name}'), erlang:apply('{pkg_name}', main, []), init:stop()" \
    2>/dev/null && exit 0

  # Fallback to module with @@main
  echo "First attempt failed, trying: {pkg_name}@@main"
  exec $ERL_EXECUTABLE $DYNAMIC_PA_FLAGS -noshell \
    -eval "code:ensure_loaded('{pkg_name}@@main'), erlang:apply('{pkg_name}@@main', main, []), init:stop()" \
    -- "$@"
fi
""".format(
            pkg_name = package_name,
            ws_name = ctx.workspace_name,
            shipment_short_path = gleam_export_output_dir.short_path,  # e.g., erlang_shipment_for_my_app
            provided_erl_pa_flags = erl_pa_flags,
        ),
    )

    # The runfiles need to include the runner script itself and the entire Erlang shipment directory.
    runfiles = ctx.runfiles(
        files = [runner_script],
        transitive_files = depset([gleam_export_output_dir]),  # Includes all files in the shipment
    )

    # Also make the runner script directly depend on the output directory
    # This ensures the directory is properly included in the runfiles
    runfiles = runfiles.merge(
        ctx.runfiles(files = [gleam_export_output_dir])
    )

    return [
        DefaultInfo(
            runfiles = runfiles,
            executable = runner_script,
        ),
    ]

gleam_binary = rule(
    implementation = _gleam_binary_impl,
    toolchains = ["//gleam:toolchain_type"],
    executable = True,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source .gleam files for the binary.",
            allow_files = [".gleam"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Gleam library dependencies.",
            providers = [GleamLibraryProviderInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package (should match gleam.toml if provided).",
            mandatory = True,
        ),
        "gleam_toml": attr.label(
            doc = "The gleam.toml file for this binary package. If provided, its directory is used as CWD for gleam export.",
            allow_single_file = True,
            default = None,
        ),
    },
    doc = """
    A rule to build Gleam binaries.

    This rule compiles Gleam source files into an executable binary.

    Features:
    - Works with both flat and nested directory structures
    - Handles Gleam's module name conventions (with or without @@main suffix)
    - Properly resolves dependencies between Gleam packages

    Example (flat structure):
    ```
    gleam_binary(
        name = "my_app_bin",
        package_name = "my_app",
        srcs = ["src/main.gleam"],
        gleam_toml = ":gleam.toml",
        deps = [":my_app_lib"],
    )
    ```

    Example (nested structure):
    ```
    gleam_binary(
        name = "nested_bin",
        package_name = "nested",
        srcs = ["src/nested.gleam"],
        gleam_toml = ":gleam.toml",
        deps = [":nested_lib"],
    )
    ```
    """,
)
