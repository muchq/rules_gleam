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

    # Determine the working directory for the gleam export command
    working_dir_for_gleam = "."  # Default to execroot
    if ctx.file.gleam_toml:
        toml_dir = ctx.file.gleam_toml.dirname
        if toml_dir and toml_dir != ".":
            working_dir_for_gleam = toml_dir

    # Always use the absolute path for the output directory
    output_dir_path = gleam_export_output_dir.path

    # Create a unified script that works for all cases by always referring to paths relative to execroot
    ctx.actions.run_shell(
        command = """
set -ex
# Store the execroot directory
EXECROOT=$(pwd)

# Make sure output directory exists
mkdir -p "$EXECROOT/{output_dir}"

# If we need to work in a different directory, cd to it
if [ "{working_dir}" != "." ]; then
  cd "$EXECROOT/{working_dir}"

  # Run gleam export using absolute paths
  "$EXECROOT/{wrapper}" "$EXECROOT/{tool}" export erlang-shipment

  # Copy the output to our declared output directory (using absolute path)
  cp -R "build/erlang-shipment/." "$EXECROOT/{output_dir}"
else
  # We're in the execroot, use regular paths
  "{wrapper}" "{tool}" export erlang-shipment

  # Copy the output to our declared output directory
  cp -R "build/erlang-shipment/." "{output_dir}"
fi
""".format(
            output_dir = output_dir_path,
            working_dir = working_dir_for_gleam,
            wrapper = gleam_exe_wrapper.path,
            tool = underlying_gleam_tool.path,
        ),
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

    # Get stable paths for the shipment directory
    shipment_runfiles_path = gleam_export_output_dir.short_path
    shipment_exec_path = gleam_export_output_dir.path

    # Calculate expected module names and paths
    module_name = package_name

    # Construct -pa paths for Erlang. These paths are inside the runfiles shipment directory.
    # Paths are relative to where the `erl` command will be run from (inside the wrapper script).
    # $SHIPMENT_DIR will be defined in the script to point to the root of the copied shipment.
    pa_paths_in_script = [
        '"$SHIPMENT_DIR/{}/ebin"'.format(package_name),  # App's own compiled BEAMs
        '"$SHIPMENT_DIR/gleam_stdlib/ebin"',  # Gleam stdlib
        '"$SHIPMENT_DIR/gleeunit/ebin"',  # gleeunit is a common dep
    ]
    erl_pa_flags = " ".join(["-pa {}".format(p) for p in pa_paths_in_script])

    # Erlang command to execute the main function.
    erl_target_module_atom = "'{}'".format(package_name)
    erl_target_function_atom = "'main'"
    erl_target_function_args = "[]"

    # Build the Erlang evaluation command
    eval_part1 = "code:ensure_loaded({})".format(erl_target_module_atom)
    eval_part2 = "erlang:apply({}, {}, {})".format(erl_target_module_atom, erl_target_function_atom, erl_target_function_args)
    eval_part3 = "init:stop()"
    erl_eval_cmd = eval_part1 + ", " + eval_part2 + ", " + eval_part3

    # Ensure the eval string is properly escaped for the shell script
    shell_safe_eval_code = erl_eval_cmd.replace('"', '\\"')

    # Create the runner script
    ctx.actions.write(
        output = runner_script,
        is_executable = True,
        content = """#!/bin/bash
# Runner script for Gleam binary: {pkg_name}
set -e

# Determine RUNFILES_DIR
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

echo "Using RUNFILES_DIR: $RUNFILES_DIR"

# Look for the shipment directory
SHIPMENT_DIR="$RUNFILES_DIR/{ws_name}/{shipment_short_path}"
echo "Looking for shipment at: $SHIPMENT_DIR"

if [ -L "$SHIPMENT_DIR" ]; then
  REAL_SHIPMENT_DIR=$(readlink -f "$SHIPMENT_DIR" 2>/dev/null || realpath "$SHIPMENT_DIR" 2>/dev/null || echo "$SHIPMENT_DIR")
  SHIPMENT_DIR="$REAL_SHIPMENT_DIR"
  echo "Resolved symlink to: $SHIPMENT_DIR"
fi

# Find package ebin directory
PKG_EBIN_DIR=""
for beam_dir in "$SHIPMENT_DIR"/**/ebin; do
  if [ -f "$beam_dir/{pkg_name}.beam" ] || [ -f "$beam_dir/{pkg_name}@@main.beam" ]; then
    PKG_EBIN_DIR="$beam_dir"
    break
  fi
done

# If not found, try alternative locations
if [ -z "$PKG_EBIN_DIR" ]; then
  # Try external path
  EXTERNAL_PATH="$RUNFILES_DIR/rules_gleam/{shipment_short_path}"
  for beam_dir in "$EXTERNAL_PATH"/**/ebin; do
    if [ -f "$beam_dir/{pkg_name}.beam" ] || [ -f "$beam_dir/{pkg_name}@@main.beam" ]; then
      PKG_EBIN_DIR="$beam_dir"
      SHIPMENT_DIR="$EXTERNAL_PATH"
      break
    fi
  done
fi

# If still not found, report error
if [ -z "$PKG_EBIN_DIR" ]; then
  echo "ERROR: Could not find {pkg_name} beam files in any known location. Exiting." >&2
  exit 1
fi

# Determine which module name to use
if [ -f "$PKG_EBIN_DIR/{pkg_name}.beam" ]; then
  MODULE_NAME="{pkg_name}"
elif [ -f "$PKG_EBIN_DIR/{pkg_name}@@main.beam" ]; then
  MODULE_NAME="{pkg_name}@@main"
else
  echo "ERROR: Neither {pkg_name}.beam nor {pkg_name}@@main.beam found in $PKG_EBIN_DIR" >&2
  exit 1
fi

echo "Using module: $MODULE_NAME"

# Build PA flags for all ebin directories
PA_FLAGS=""
for DIR in $(find "$(dirname "$PKG_EBIN_DIR")/.." -name "ebin" -type d 2>/dev/null); do
  PA_FLAGS="$PA_FLAGS -pa $DIR"
done

echo "Running with Erlang flags: $PA_FLAGS"

# Run Erlang with the appropriate module
exec erl $PA_FLAGS -noshell \
  -eval "code:ensure_loaded('$MODULE_NAME'), erlang:apply('$MODULE_NAME', main, []), init:stop()" \
  -- "$@"
""".format(
            pkg_name = package_name,
            ws_name = ctx.workspace_name,
            shipment_short_path = shipment_runfiles_path,
            provided_erl_pa_flags = erl_pa_flags,
            eval_code = shell_safe_eval_code,
        ),
    )

    # Create a direct-access script for external repos
    direct_runner_name = ctx.label.name + "_direct.sh"
    direct_runner = ctx.actions.declare_file(direct_runner_name)

    ctx.actions.write(
        output = direct_runner,
        is_executable = True,
        content = """#!/bin/bash
# Direct runner for Gleam binary {pkg_name} that doesn't rely on runfiles
set -e

# Get the absolute path of this script's directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/{workspace_path_back}" 2>/dev/null && pwd || echo "$SCRIPT_DIR/..")"

# Places to look for the shipment
POSSIBLE_LOCATIONS=(
  "$SCRIPT_DIR/{shipment_rel_path}"                           # Next to script
  "$WORKSPACE_DIR/bazel-bin/{pkg_path}/{shipment_name}"       # In bazel-bin
  "$WORKSPACE_DIR/bazel-out/*/bin/{pkg_path}/{shipment_name}" # In bazel-out
)

# Find the first valid shipment location
SHIPMENT_DIR=""
for PATTERN in "${{POSSIBLE_LOCATIONS[@]}}"; do
  for EXPANDED_DIR in $PATTERN; do
    if [ -d "$EXPANDED_DIR" ]; then
      # Look for any ebin directory
      if find "$EXPANDED_DIR" -type d -name "ebin" | grep -q "ebin"; then
        SHIPMENT_DIR="$EXPANDED_DIR"
        echo "Found shipment at: $SHIPMENT_DIR"
        break 2
      fi
    fi
  done
done

if [ -z "$SHIPMENT_DIR" ]; then
  echo "ERROR: Could not find shipment directory in any expected location"
  exit 1
fi

# Find the ebin directory containing our package's beam files
PKG_EBIN_DIR=""
for EBIN_DIR in $(find "$SHIPMENT_DIR" -type d -name "ebin"); do
  if ls "$EBIN_DIR"/{pkg_name}*.beam >/dev/null 2>&1; then
    PKG_EBIN_DIR="$EBIN_DIR"
    echo "Found package beam files in: $PKG_EBIN_DIR"
    break
  fi
done

if [ -z "$PKG_EBIN_DIR" ]; then
  echo "ERROR: Could not find ebin directory containing {pkg_name} beam files"
  exit 1
fi

# Find the module name (with or without suffix)
if [ -f "$PKG_EBIN_DIR/{pkg_name}.beam" ]; then
  MODULE_NAME="{pkg_name}"
elif [ -f "$PKG_EBIN_DIR/{pkg_name}@@main.beam" ]; then
  MODULE_NAME="{pkg_name}@@main"
else
  echo "ERROR: Could not find module beam file"
  ls -la "$PKG_EBIN_DIR"
  exit 1
fi

echo "Using module: $MODULE_NAME"

# Build Erlang PA flags for all ebin directories
PA_FLAGS=""
for DIR in $(find "$SHIPMENT_DIR" -name "ebin" -type d); do
  PA_FLAGS="$PA_FLAGS -pa $DIR"
done

echo "Running with Erlang flags: $PA_FLAGS"

# Run Erlang with the appropriate module
exec erl $PA_FLAGS -noshell \
  -eval "code:ensure_loaded('$MODULE_NAME'), erlang:apply('$MODULE_NAME', main, []), init:stop()" \
  -- "$@"
""".format(
            pkg_name = package_name,
            shipment_name = gleam_export_output_dir_name,
            shipment_rel_path = gleam_export_output_dir_name,
            pkg_path = ctx.label.package,
            workspace_path_back = "/".join([".."] * (len(ctx.label.package.split("/")) + 1)) if ctx.label.package else ".",
        ),
    )

    # Create runfiles with explicit symlinks for proper file materialization
    runfiles = ctx.runfiles(
        files = [runner_script, gleam_export_output_dir, direct_runner],
    )

    # Create explicit symlinks for important paths
    # This helps with external repository references
    symlinks = {
        # Add path with workspace name
        "{}/{}".format(ctx.workspace_name, gleam_export_output_dir.short_path): gleam_export_output_dir,
        # Add direct path without workspace prefix
        gleam_export_output_dir.short_path: gleam_export_output_dir,
    }

    # Add the symlinks to runfiles
    symlink_runfiles = ctx.runfiles(symlinks = symlinks)
    runfiles = runfiles.merge(symlink_runfiles)

    return [
        DefaultInfo(
            runfiles = runfiles,
            executable = runner_script,
        ),
        OutputGroupInfo(
            direct_runner = depset([direct_runner]),
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
    It supports both flat and nested directory structures.

    Features:
    - Works with both flat and nested directory structures
    - Handles Gleam's module name conventions (with or without @@main suffix)
    - Resolves dependencies between Gleam packages
    - Provides a fallback direct runner for external repository usage

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
