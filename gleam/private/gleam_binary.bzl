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

# --- BEGIN LOCATION DETERMINATION ---
# We'll try multiple known locations where the shipment might be

# 1. Standard Runfiles Path
SHIPMENT_DIR="$RUNFILES_DIR/{ws_name}/{shipment_short_path}"
if [ -L "$SHIPMENT_DIR" ]; then
  REAL_SHIPMENT_DIR=$(readlink -f "$SHIPMENT_DIR")
  SHIPMENT_DIR="$REAL_SHIPMENT_DIR"
fi

# Test if package directory exists and has content
if [ ! -d "$SHIPMENT_DIR/{pkg_name}" ] || [ -z "$(ls -A "$SHIPMENT_DIR/{pkg_name}" 2>/dev/null)" ]; then
  echo "Standard shipment location not found or empty. Trying alternatives..."

  # 2. Try explicit external repository path
  EXTERNAL_PATH="$RUNFILES_DIR/rules_gleam/{shipment_short_path}"
  if [ -d "$EXTERNAL_PATH/{pkg_name}" ] && [ -n "$(ls -A "$EXTERNAL_PATH/{pkg_name}" 2>/dev/null)" ]; then
    SHIPMENT_DIR="$EXTERNAL_PATH"
    echo "Found shipment at external repository path: $SHIPMENT_DIR"
  else
    # 3. Try direct Bazel output path
    BAZEL_OUT_PATH="$(cd $(dirname $0) && pwd)/{shipment_short_path}"
    if [ -d "$BAZEL_OUT_PATH/{pkg_name}" ] && [ -n "$(ls -A "$BAZEL_OUT_PATH/{pkg_name}" 2>/dev/null)" ]; then
      SHIPMENT_DIR="$BAZEL_OUT_PATH"
      echo "Found shipment at direct bazel-out path: $SHIPMENT_DIR"
    else
      # 4. Last resort - try to find in sandbox
      POTENTIAL_PATHS=(
        "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/bazel-out/*/bin/{shipment_path}"
        "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/{shipment_path}"
        "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/_main/{shipment_path}"
        "/private/var/tmp/_bazel_*/*/sandbox/*/execroot/*/external/rules_gleam/{shipment_path}"
      )

      for PATTERN in "${{POTENTIAL_PATHS[@]}}"; do
        for DIR in $(find /private/var/tmp/_bazel_* -path "$PATTERN" -type d 2>/dev/null); do
          if [ -d "$DIR/{pkg_name}" ] && [ -n "$(ls -A "$DIR/{pkg_name}" 2>/dev/null)" ]; then
            SHIPMENT_DIR="$DIR"
            echo "Found shipment in sandbox: $SHIPMENT_DIR"
            break 2
          fi
        done
      done
    fi
  fi
fi
# --- END LOCATION DETERMINATION ---

# Final check if shipment directory exists and has the package
if [ ! -d "$SHIPMENT_DIR/{pkg_name}" ]; then
  echo "ERROR: Could not find {pkg_name} directory in any known location. Exiting." >&2
  exit 1
fi

# Determine if we have a module with or without @@main suffix
PKG_DIR="$SHIPMENT_DIR/{pkg_name}"
EBIN_DIR="$PKG_DIR/ebin"

# Choose which module to use
if [ -f "$EBIN_DIR/{pkg_name}.beam" ]; then
  MODULE_NAME="{pkg_name}"
elif [ -f "$EBIN_DIR/{pkg_name}@@main.beam" ]; then
  MODULE_NAME="{pkg_name}@@main"
else
  echo "ERROR: Neither {pkg_name}.beam nor {pkg_name}@@main.beam found in $EBIN_DIR" >&2
  ls -la "$EBIN_DIR"
  exit 1
fi

# Build PA flags dynamically
PA_FLAGS="-pa $EBIN_DIR"
for LIB_DIR in "$SHIPMENT_DIR"/*; do
  if [ -d "$LIB_DIR/ebin" ] && [ "$LIB_DIR" != "$PKG_DIR" ]; then
    PA_FLAGS="$PA_FLAGS -pa $LIB_DIR/ebin"
  fi
done

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
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/{workspace_path_back}" && pwd)"

# Places to look for the shipment
POSSIBLE_LOCATIONS=(
  "$SCRIPT_DIR/{shipment_rel_path}"                                # Next to script
  "$WORKSPACE_DIR/bazel-bin/{pkg_path}/{shipment_name}"            # In bazel-bin
  "$WORKSPACE_DIR/bazel-out/*/bin/{pkg_path}/{shipment_name}"      # In bazel-out
)

# Find the first valid shipment location
SHIPMENT_DIR=""
for DIR in "${{POSSIBLE_LOCATIONS[@]}}"; do
  # Handle wildcards in paths
  for EXPANDED_DIR in $DIR; do
    if [ -d "$EXPANDED_DIR/{pkg_name}" ] && [ -d "$EXPANDED_DIR/{pkg_name}/ebin" ]; then
      SHIPMENT_DIR="$EXPANDED_DIR"
      break 2
    fi
  done
done

if [ -z "$SHIPMENT_DIR" ]; then
  echo "ERROR: Could not find shipment directory in any expected location"
  exit 1
fi

echo "Using shipment at: $SHIPMENT_DIR"

# Determine module name (with or without suffix)
PKG_DIR="$SHIPMENT_DIR/{pkg_name}"
EBIN_DIR="$PKG_DIR/ebin"

if [ -f "$EBIN_DIR/{pkg_name}.beam" ]; then
  MODULE_NAME="{pkg_name}"
elif [ -f "$EBIN_DIR/{pkg_name}@@main.beam" ]; then
  MODULE_NAME="{pkg_name}@@main"
else
  echo "ERROR: Could not find module beam file"
  exit 1
fi

# Build Erlang PA flags
PA_FLAGS="-pa $EBIN_DIR"
for LIB_DIR in "$SHIPMENT_DIR"/*; do
  if [ -d "$LIB_DIR/ebin" ] && [ "$LIB_DIR" != "$PKG_DIR" ]; then
    PA_FLAGS="$PA_FLAGS -pa $LIB_DIR/ebin"
  fi
done

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

# Option 1: Check build output directory
BUILD_OUTPUT="$SCRIPT_DIR/{shipment_name}"
if [ -d "$BUILD_OUTPUT" ] && [ -d "$BUILD_OUTPUT/{pkg_name}" ]; then
    echo "Found built files at $BUILD_OUTPUT"
    cp -R "$BUILD_OUTPUT/." "$TEMP_DIR/"
    SOURCE_FOUND=true
fi

# Option 2: Check bazel-bin directory
if [ "$SOURCE_FOUND" = false ]; then
    BAZEL_BIN="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)/bazel-bin/{pkg_path}/{shipment_name}"
    if [ -d "$BAZEL_BIN" ] && [ -d "$BAZEL_BIN/{pkg_name}" ]; then
        echo "Found built files in bazel-bin: $BAZEL_BIN"
        cp -R "$BAZEL_BIN/." "$TEMP_DIR/"
        SOURCE_FOUND=true
    fi
fi

# Option 3: Check bazel-out directory
if [ "$SOURCE_FOUND" = false ]; then
    for BAZEL_OUT_DIR in $(find /private/var/tmp/_bazel_* -path "*/bazel-out/*/bin/{pkg_path}/{shipment_name}" -type d 2>/dev/null); do
        if [ -d "$BAZEL_OUT_DIR" ] && [ -d "$BAZEL_OUT_DIR/{pkg_name}" ]; then
            echo "Found built files in bazel-out: $BAZEL_OUT_DIR"
            cp -R "$BAZEL_OUT_DIR/." "$TEMP_DIR/"
            SOURCE_FOUND=true
            break
        fi
    done
fi

# Option 4: Check for sandbox stash
if [ "$SOURCE_FOUND" = false ]; then
    for SANDBOX_DIR in $(find /private/var/tmp/_bazel_* -path "*/sandbox/sandbox_stash/GleamExportRelease/*/execroot/*/{pkg_path}/{shipment_name}" -type d 2>/dev/null); do
        if [ -d "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR/{pkg_name}" ]; then
            echo "Found built files in sandbox stash: $SANDBOX_DIR"
            cp -R "$SANDBOX_DIR/." "$TEMP_DIR/"
            SOURCE_FOUND=true
            break
        fi
    done

    # Check other sandbox patterns
    if [ "$SOURCE_FOUND" = false ]; then
        for SANDBOX_DIR in $(find /private/var/tmp/_bazel_* -path "*/sandbox/*/execroot/*/{pkg_path}/{shipment_name}" -type d 2>/dev/null); do
            if [ -d "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR/{pkg_name}" ]; then
                echo "Found built files in sandbox directory: $SANDBOX_DIR"
                cp -R "$SANDBOX_DIR/." "$TEMP_DIR/"
                SOURCE_FOUND=true
                break
            fi
        done
    fi

    # Check parent repo sandbox
    if [ "$SOURCE_FOUND" = false ]; then
        for SANDBOX_DIR in $(find /private/var/tmp/_bazel_* -path "*/sandbox/*/execroot/*/external/*/{pkg_path}/{shipment_name}" -type d 2>/dev/null); do
            if [ -d "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR/{pkg_name}" ]; then
                echo "Found built files in external sandbox: $SANDBOX_DIR"
                cp -R "$SANDBOX_DIR/." "$TEMP_DIR/"
                SOURCE_FOUND=true
                break
            fi
        done
    fi
fi

if [ "$SOURCE_FOUND" = false ]; then
    echo "ERROR: Could not find Gleam files anywhere."
    exit 1
fi

# Verify the temp directory structure
if [ ! -d "$TEMP_DIR/{pkg_name}/ebin" ]; then
    echo "ERROR: Expected directory structure not found in $TEMP_DIR"
    find "$TEMP_DIR" -type d
    exit 1
fi

# Find the module file
MODULE_NAME=""
if [ -f "$TEMP_DIR/{pkg_name}/ebin/{pkg_name}.beam" ]; then
    MODULE_NAME="{pkg_name}"
elif [ -f "$TEMP_DIR/{pkg_name}/ebin/{pkg_name}@@main.beam" ]; then
    MODULE_NAME="{pkg_name}@@main"
else
    echo "ERROR: Could not find module beam file in $TEMP_DIR/{pkg_name}/ebin"
    ls -la "$TEMP_DIR/{pkg_name}/ebin"
    exit 1
fi

echo "Found module: $MODULE_NAME"

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

# Find the main beam file
MAIN_BEAM_FILE=$(find "{shipment_dir}/{pkg_name}/ebin" -name "*.beam" | grep -E "({pkg_name}.beam|{pkg_name}@@main.beam)" | head -1)
if [ -z "$MAIN_BEAM_FILE" ]; then
    echo "ERROR: Could not find main beam file"
    exit 1
fi

# Determine module name from filename
MODULE_NAME=$(basename "$MAIN_BEAM_FILE" .beam)

# Create the embedded script with header
cat > "{output_file}" << 'EOL'
#!/bin/bash
# Fully embedded runner for Gleam application - doesn't need any external files
set -e

# Create a temp directory for our extracted files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Create directory structure for beam files
mkdir -p "$TEMP_DIR/{pkg_name}/ebin"

# Function to decode and extract a base64-encoded file
extract_file() {{
    local dest="$1"
    local base64data="$2"
    echo "$base64data" | base64 -d > "$dest"
}}

echo "Extracting embedded beam files..."
EOL

# Encode and embed the main beam file
echo "Embedding main beam file: $MAIN_BEAM_FILE"
MAIN_BEAM_FILENAME=$(basename "$MAIN_BEAM_FILE")
MAIN_BEAM_BASE64=$(cat "$MAIN_BEAM_FILE" | base64)
echo "extract_file \\"$TEMP_DIR/{pkg_name}/ebin/$MAIN_BEAM_FILENAME\\" \\"$MAIN_BEAM_BASE64\\"" >> "{output_file}"

# Add the module execution code
cat >> "{output_file}" << 'EOL'

# Find the module filename
MODULE_FILENAME=$(ls "$TEMP_DIR/{pkg_name}/ebin/"*.beam | head -1)
MODULE_NAME=$(basename "$MODULE_FILENAME" .beam)

echo "Extracted module: $MODULE_NAME"
echo "Running Erlang with extracted module..."

# Run the Erlang VM with our extracted module
exec erl -pa "$TEMP_DIR/{pkg_name}/ebin" -noshell \
  -eval "code:ensure_loaded('$MODULE_NAME'), erlang:apply('$MODULE_NAME', main, []), init:stop()" \
  -- "$@"
EOL

# Make the script executable
chmod +x "{output_file}"
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
