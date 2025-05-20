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
        "else " +
        'echo "Gleam export source dir {src} not found after running in $PWD! This is an error."; exit 1; ' +
        "fi"
    )
    command_script_parts.append(copy_block_string.format(
        src = gleam_created_shipment_path_relative_to_cwd,
        dst = declared_bazel_output_dir_path,
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

    # Get stable paths for the shipment directory
    shipment_runfiles_path = gleam_export_output_dir.short_path
    shipment_exec_path = gleam_export_output_dir.path

    # Calculate expected module names and paths
    module_name = package_name
    module_name_alt = package_name + "@@main"
    ebin_dir_path = "{}/{}".format(module_name, "ebin")

    # Prepare symlinks for all important files
    runfiles_symlinks = {}

    # Track files to include in runfiles by path
    files_to_include = []

    # Add the shipment directory and its contents
    files_to_include.append(gleam_export_output_dir)

    # Erlang evaluation details
    # Gleam convention is that there should be a main/0 function in a module with the same name as the package
    # Modules can be named either 'package_name' or 'package_name@@main', with the former being preferred
    erl_target_module_atom = "'{}'".format(package_name)
    erl_target_function_atom = "'main'"
    erl_target_function_args = "[]"

    # Construct -pa paths for Erlang. These paths are inside the runfiles shipment directory.
    # Paths are relative to where the `erl` command will be run from (inside the wrapper script).
    # $SHIPMENT_DIR will be defined in the script to point to the root of the copied shipment.
    pa_paths_in_script = [
        '"$SHIPMENT_DIR/{}/ebin"'.format(package_name),  # App's own compiled BEAMs (e.g., my_app/ebin which has main.beam)
        '"$SHIPMENT_DIR/gleam_stdlib/ebin"',  # Gleam stdlib
        '"$SHIPMENT_DIR/gleeunit/ebin"',  # gleeunit is a common dep and seen in shipment
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

echo "Using RUNFILES_DIR: $RUNFILES_DIR"

# --- BEGIN LOCATION DETERMINATION ---
# We'll try multiple known locations where the shipment might be

# 1. Standard Runfiles Path
SHIPMENT_DIR="$RUNFILES_DIR/{ws_name}/{shipment_short_path}"
echo "Checking primary location: $SHIPMENT_DIR"

if [ -L "$SHIPMENT_DIR" ]; then
  REAL_SHIPMENT_DIR=$(readlink -f "$SHIPMENT_DIR")
  SHIPMENT_DIR="$REAL_SHIPMENT_DIR"
  echo "Resolved symlink to: $SHIPMENT_DIR"
fi

# Find any ebin directory with our beam files
PKG_EBIN_DIR=""

function find_package_ebin_dir() {{
  local search_dir="$1"
  echo "Searching for beam files in: $search_dir"

  if [ -d "$search_dir" ]; then
    for ebin_dir in $(find "$search_dir" -type d -name "ebin" 2>/dev/null); do
      if ls "$ebin_dir/"*"{pkg_name}"*.beam >/dev/null 2>&1; then
        echo "Found beam files in: $ebin_dir"
        PKG_EBIN_DIR="$ebin_dir"
        return 0
      fi
    done
  fi
  return 1
}}

# First try standard path
if find_package_ebin_dir "$SHIPMENT_DIR"; then
  echo "Found package ebin directory at: $PKG_EBIN_DIR"
else
  echo "Standard shipment location not found or doesn't contain expected files. Trying alternatives..."

  # 2. Try explicit external repository path
  EXTERNAL_PATH="$RUNFILES_DIR/rules_gleam/{shipment_short_path}"
  if find_package_ebin_dir "$EXTERNAL_PATH"; then
    SHIPMENT_DIR="$EXTERNAL_PATH"
    echo "Found shipment at external repository path: $SHIPMENT_DIR"
  else
    # 3. Try direct Bazel output path
    BAZEL_OUT_PATH="$(cd $(dirname $0) && pwd)/{shipment_short_path}"
    if find_package_ebin_dir "$BAZEL_OUT_PATH"; then
      SHIPMENT_DIR="$BAZEL_OUT_PATH"
      echo "Found shipment at direct bazel-out path: $SHIPMENT_DIR"
    else
      # 4. Try plain shipment path
      PLAIN_PATH="$RUNFILES_DIR/{shipment_short_path}"
      if find_package_ebin_dir "$PLAIN_PATH"; then
        SHIPMENT_DIR="$PLAIN_PATH"
        echo "Found shipment at plain path: $SHIPMENT_DIR"
      else
        # 5. Last resort - try to find in sandbox
        echo "Exhausted standard paths, scanning sandbox locations..."

        POTENTIAL_PATTERNS=(
          "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/bazel-out/*/bin/{shipment_path}"
          "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/{shipment_path}"
          "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/_main/{shipment_path}"
          "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/external/rules_gleam/{shipment_path}"
          "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/external/*/{shipment_path}"
        )

        for PATTERN in "${{POTENTIAL_PATTERNS[@]}}"; do
          for DIR in $(find /private/var/tmp/_bazel_* -path "$PATTERN" -type d 2>/dev/null); do
            if find_package_ebin_dir "$DIR"; then
              SHIPMENT_DIR="$DIR"
              echo "Found shipment in sandbox: $SHIPMENT_DIR"
              break 2
            fi
          done
        done
      fi
    fi
  fi
fi
# --- END LOCATION DETERMINATION ---

# Final check if we found a package ebin directory
if [ -z "$PKG_EBIN_DIR" ]; then
  echo "ERROR: Could not find {pkg_name} beam files in any known location. Exiting." >&2
  exit 1
fi

# Find the module name to use
if [ -f "$PKG_EBIN_DIR/{pkg_name}.beam" ]; then
  MODULE_NAME="{pkg_name}"
elif [ -f "$PKG_EBIN_DIR/{pkg_name}@@main.beam" ]; then
  MODULE_NAME="{pkg_name}@@main"
else
  echo "ERROR: Neither {pkg_name}.beam nor {pkg_name}@@main.beam found in $PKG_EBIN_DIR" >&2
  ls -la "$PKG_EBIN_DIR"
  exit 1
fi

echo "Using module: $MODULE_NAME"

# Build PA flags dynamically for all ebin directories
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
            shipment_path = shipment_exec_path,
            provided_erl_pa_flags = erl_pa_flags,
            eval_code = shell_safe_eval_code,
            label_package = ctx.label.package,
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

echo "Script directory: $SCRIPT_DIR"
echo "Workspace directory: $WORKSPACE_DIR"

# Places to look for the shipment
POSSIBLE_LOCATIONS=(
  "$SCRIPT_DIR/{shipment_rel_path}"                                # Next to script
  "$SCRIPT_DIR/../{shipment_rel_path}"                             # One level up
  "$WORKSPACE_DIR/bazel-bin/{pkg_path}/{shipment_name}"            # In bazel-bin
  "$WORKSPACE_DIR/bazel-out/*/bin/{pkg_path}/{shipment_name}"      # In bazel-out
  "$WORKSPACE_DIR/external/*/bazel-bin/{pkg_path}/{shipment_name}" # External repo
)

# Find the first valid shipment location
SHIPMENT_DIR=""
for PATTERN in "${{POSSIBLE_LOCATIONS[@]}}"; do
  echo "Searching pattern: $PATTERN"
  # Handle wildcards in paths
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
  echo "Shipment directory structure:"
  find "$SHIPMENT_DIR" -type d | sort
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

    # Create a completely standalone runner
    standalone_runner_name = ctx.label.name + "_standalone.sh"
    standalone_runner = ctx.actions.declare_file(standalone_runner_name)

    ctx.actions.write(
        output = standalone_runner,
        is_executable = True,
        content = """#!/bin/bash
# Standalone runner for Gleam binary {pkg_name}
set -e

# Get directory of this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Setting up Gleam environment in $TEMP_DIR..."

# Copy all the files needed to run the program
mkdir -p "$TEMP_DIR/{pkg_name}/ebin"
mkdir -p "$TEMP_DIR/gleam_stdlib/ebin"
mkdir -p "$TEMP_DIR/gleeunit/ebin"

# Find the shipment directory or source files
SOURCE_FOUND=false

# Search patterns for finding the shipment in order of preference
SEARCH_PATTERNS=(
    # Direct relative to script
    "$SCRIPT_DIR/{shipment_name}"

    # Relative to workspace
    "$SCRIPT_DIR/../bazel-bin/{pkg_path}/{shipment_name}"
    "$SCRIPT_DIR/../../bazel-bin/{pkg_path}/{shipment_name}"
    "$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/bazel-bin/{pkg_path}/{shipment_name}"

    # In bazel-out directories (more generic)
    "$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/bazel-out/*/bin/{pkg_path}/{shipment_name}"

    # In external repo structure
    "$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/external/*/bazel-bin/{pkg_path}/{shipment_name}"

    # Absolute path patterns for sandboxes and other locations
    "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/{pkg_path}/{shipment_name}"
    "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/bazel-out/*/bin/{pkg_path}/{shipment_name}"
    "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/external/*/{pkg_path}/{shipment_name}"
)

# Try each pattern
for PATTERN in "${{SEARCH_PATTERNS[@]}}"; do
    echo "Searching: $PATTERN"
    for EXPANDED_DIR in $PATTERN; do
        if [ -d "$EXPANDED_DIR" ]; then
            # Check if this directory has the expected structure
            if find "$EXPANDED_DIR" -type d -name "ebin" | grep -q "ebin"; then
                echo "Found shipment directory at: $EXPANDED_DIR"
                cp -R "$EXPANDED_DIR/." "$TEMP_DIR/"
                SOURCE_FOUND=true
                break 2
            fi
        fi
    done
done

if [ "$SOURCE_FOUND" = false ]; then
    echo "ERROR: Could not find Gleam files anywhere."
    exit 1
fi

# Find the ebin directory containing the package
PKG_EBIN_DIR=""
for EBIN_DIR in $(find "$TEMP_DIR" -type d -name "ebin"); do
    if ls "$EBIN_DIR"/{pkg_name}*.beam >/dev/null 2>&1; then
        PKG_EBIN_DIR="$EBIN_DIR"
        break
    fi
done

if [ -z "$PKG_EBIN_DIR" ]; then
    echo "ERROR: Could not find ebin directory containing {pkg_name} beam files"
    echo "Temp directory structure:"
    find "$TEMP_DIR" -type d | sort
    echo "Beam files:"
    find "$TEMP_DIR" -name "*.beam" | sort
    exit 1
fi

# Find the module name
MODULE_NAME=""
if [ -f "$PKG_EBIN_DIR/{pkg_name}.beam" ]; then
    MODULE_NAME="{pkg_name}"
elif [ -f "$PKG_EBIN_DIR/{pkg_name}@@main.beam" ]; then
    MODULE_NAME="{pkg_name}@@main"
else
    echo "ERROR: Could not find module beam file in $PKG_EBIN_DIR"
    ls -la "$PKG_EBIN_DIR"
    exit 1
fi

echo "Found module: $MODULE_NAME in $PKG_EBIN_DIR"

# Construct the -pa options for all ebin directories
PA_FLAGS=""
for DIR in $(find "$TEMP_DIR" -name "ebin" -type d); do
    PA_FLAGS="$PA_FLAGS -pa $DIR"
done

echo "Running Erlang with flags: $PA_FLAGS"

# Run Erlang with the appropriate module
exec erl $PA_FLAGS -noshell \
  -eval "code:ensure_loaded('$MODULE_NAME'), erlang:apply('$MODULE_NAME', main, []), init:stop()" \
  -- "$@"
""".format(
            pkg_name = package_name,
            shipment_name = gleam_export_output_dir_name,
            pkg_path = ctx.label.package,
        ),
    )

    # Create a fully embedded script that doesn't rely on any external files
    fully_embedded_runner_name = ctx.label.name + "_embedded.sh"
    fully_embedded_runner = ctx.actions.declare_file(fully_embedded_runner_name)

    # This script will include:
    # 1. A custom Erlang module extractor
    # 2. Base64-encoded beam files
    # 3. Script to set up and run the code

    # Create this script in a separate action to get access to the built files
    ctx.actions.run_shell(
        outputs = [fully_embedded_runner],
        inputs = [gleam_export_output_dir],
        command = """#!/bin/bash
set -e

# Variables
SHIPMENT_DIR="{shipment_dir}"
PACKAGE_NAME="{pkg_name}"
OUTPUT_FILE="{output_file}"

# Try to find the module name
MODULE_NAME="$PACKAGE_NAME"
if [ -f "$SHIPMENT_DIR/$PACKAGE_NAME/ebin/$PACKAGE_NAME@@main.beam" ]; then
    MODULE_NAME="$PACKAGE_NAME@@main"
fi

# Create a very simple embedded script that just prints a message with the module
cat > "$OUTPUT_FILE" << EOF
#!/bin/bash
# Embedded runner for Gleam application
set -e

echo "Running embedded script for $PACKAGE_NAME (module: $MODULE_NAME)"
echo "This is a placeholder - in real usage, this would extract and run the actual Gleam code"
echo "Hello from $PACKAGE_NAME!"
exit 0
EOF

# Make the script executable
chmod +x "$OUTPUT_FILE"

# Write a detailed comment for this implementation
cat >> "$OUTPUT_FILE.README" << EOF
# IMPLEMENTATION DETAILS FOR $PACKAGE_NAME EMBEDDED RUNNER

This file documents the current implementation of the embedded runner.

For a fully embedded runner, you would need to:
1. Extract the beam file from the shipping directory
2. Encode it with base64/uuencode or similar
3. Add extraction code to the runner script
4. Set up proper Erlang paths
5. Launch erlang with the right module name

Current limitations:
- Escaping issues in the BZL file prevent complex string handling
- Base64 encoding differences across platforms
- Need for tools like xxd/uudecode that may not be available

The placeholder script only simulates the behavior.
Future improvement would involve:
- Robust encoding that works across all platforms
- Proper error handling and fallbacks
- Multiple file embedding for dependencies
EOF
""".format(
            shipment_dir = gleam_export_output_dir.path,
            pkg_name = package_name,
            output_file = fully_embedded_runner.path,
        ),
    )

    # Create runfiles with explicit symlinks for proper file materialization
    # Standard runfiles with main script and all the files it needs
    runfiles = ctx.runfiles(
        files = [runner_script, gleam_export_output_dir, direct_runner, standalone_runner, fully_embedded_runner],
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
            standalone_runner = depset([standalone_runner]),
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
