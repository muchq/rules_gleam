"""Improved implementation of gleam_binary rule that creates deployable applications."""

load("//gleam/private:gleam_library_v2.bzl", "GleamLibraryInfo")

def _gleam_binary_impl(ctx):
    """Package a Gleam application into a deployable binary."""
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    
    package_name = ctx.attr.package_name
    entry_module = ctx.attr.entry_module if ctx.attr.entry_module else package_name
    
    # Build everything in a single action to avoid sandboxing issues
    # This includes compilation and release assembly
    release_dir = ctx.actions.declare_directory("{}_release".format(ctx.label.name))
    
    # Collect all inputs
    inputs = []
    inputs.extend(ctx.files.srcs)
    if ctx.file.gleam_toml:
        inputs.append(ctx.file.gleam_toml)
    
    # Add source files from library dependencies
    for target in ctx.attr.srcs_deps:
        inputs.extend(target.files.to_list())
    
    # Build script that compiles and creates release
    build_script = """#!/bin/bash
set -euo pipefail

EXECROOT=$(pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create project structure
mkdir -p $TEMP_DIR/src

# Copy source files
"""
    
    # Copy sources from library
    for target in ctx.attr.srcs_deps:
        for f in target.files.to_list():
            if f.extension == "gleam":
                src_path = f.path
                if "/src/" in src_path:
                    idx = src_path.rfind("/src/")
                    rel_path = src_path[idx+1:]
                else:
                    rel_path = "src/" + f.basename
                build_script += 'cp "{}" "$TEMP_DIR/{}"\n'.format(src_path, rel_path)
            elif f.basename == "gleam.toml":
                build_script += 'cp "{}" "$TEMP_DIR/gleam.toml"\n'.format(f.path)
    
    # Copy binary's own sources if any
    for src in ctx.files.srcs:
        src_path = src.path
        if "/src/" in src_path:
            idx = src_path.rfind("/src/")
            rel_path = src_path[idx+1:]
        else:
            rel_path = "src/" + src.basename
        build_script += 'cp "{}" "$TEMP_DIR/{}"\n'.format(src_path, rel_path)
    
    if ctx.file.gleam_toml:
        build_script += 'cp "{}" "$TEMP_DIR/gleam.toml"\n'.format(ctx.file.gleam_toml.path)
    
    # Build the project
    build_script += """
cd $TEMP_DIR

# Build with Gleam
"$EXECROOT/{gleam_wrapper}" "$EXECROOT/{gleam_tool}" build --target erlang

# Create release directory structure
mkdir -p "{release}/lib"

# Copy all built packages
for pkg in build/dev/erlang/* build/prod/erlang/*; do
  if [ -d "$pkg" ]; then
    pkg_name=$(basename "$pkg")
    echo "Adding package $pkg_name to release"
    cp -r "$pkg" "{release}/lib/$pkg_name"
  fi
done

# Copy gleam_stdlib if available
if [ -d "{erl_libs}/gleam_stdlib" ]; then
  echo "Adding gleam_stdlib to release"
  cp -r "{erl_libs}/gleam_stdlib" "{release}/lib/"
fi

# Create runner script
cat > "{release}/run.sh" << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SCRIPT_DIR/lib" ]; then
  echo "ERROR: This script must be run from the extracted archive directory" >&2
  echo "       Expected lib/ directory in $SCRIPT_DIR" >&2
  exit 1
fi

if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang (erl) not found in PATH" >&2
  exit 1
fi

# Build -pa paths
PA_PATHS=""
for pkg_dir in "$SCRIPT_DIR"/lib/*/ebin; do
  if [ -d "$pkg_dir" ]; then
    PA_PATHS="$PA_PATHS -pa '$pkg_dir'"
  fi
done

eval exec "$ERL" \\
  $PA_PATHS \\
  -noshell \\
  -s {entry_module} main \\
  -s init stop \\
  -- "$@"
EOFSCRIPT

chmod +x "{release}/run.sh"

echo "Release assembled successfully"
ls -la "{release}/"

# Create archive right here in the same action
cd "{release}"
tar czf "$EXECROOT/{archive_path}" lib/ run.sh
echo "Archive created: {archive_path}"
"""
    
    # Create deployable archive
    archive = ctx.actions.declare_file("{}.tar.gz".format(ctx.label.name))
    
    # Complete the build script with format
    build_script = build_script.format(
        gleam_wrapper=gleam_exe_wrapper.path,
        gleam_tool=underlying_gleam_tool.path,
        release=release_dir.path,
        erl_libs=erlang_toolchain.erl_libs_path_str if hasattr(erlang_toolchain, "erl_libs_path_str") else "/nonexistent",
        entry_module=entry_module,
        archive_path=archive.path,
    )
    
    ctx.actions.run_shell(
        command = build_script,
        inputs = depset(inputs),
        outputs = [release_dir, archive],
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        mnemonic = "GleamBuildRelease",
        progress_message = "Building and packaging {}".format(package_name),
    )
    
    # Create runner script
    runner_script = ctx.actions.declare_file(ctx.label.name)
    
    runner_content = """#!/bin/bash
set -euo pipefail

# Find the runfiles directory
if [ -z "${{RUNFILES_DIR:-}}" ]; then
  if [ -f "$0.runfiles/MANIFEST" ]; then
    RUNFILES_DIR="$0.runfiles"
  elif [ -f "$0.runfiles_manifest" ]; then
    RUNFILES_DIR=$(grep -m1 "^[^ ]* " "$0.runfiles_manifest" | cut -d' ' -f2 | sed 's|/[^/]*$||')
  else
    RUNFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
  fi
fi

# Find release directory
RELEASE_DIR="${{RUNFILES_DIR}}/{workspace}/{release_path}"
if [ ! -d "$RELEASE_DIR" ]; then
  # Try relative to script
  RELEASE_DIR="$(dirname "$0")/{release_path}"
fi

if [ ! -d "$RELEASE_DIR/lib" ]; then
  echo "ERROR: Cannot find release directory" >&2
  exit 1
fi

# Find Erlang
if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang (erl) not found in PATH" >&2
  exit 1
fi

# Build -pa paths for all packages
PA_PATHS=""
for pkg_dir in "$RELEASE_DIR"/lib/*/ebin; do
  if [ -d "$pkg_dir" ]; then
    PA_PATHS="$PA_PATHS -pa '$pkg_dir'"
  fi
done

# Run the application
eval exec "$ERL" \\
  $PA_PATHS \\
  -noshell \\
  -s {entry_module} main \\
  -s init stop \\
  -- "$@"
""".format(
        workspace = ctx.workspace_name,
        release_path = release_dir.short_path,
        entry_module = entry_module,
    )
    
    ctx.actions.write(
        output = runner_script,
        content = runner_content,
        is_executable = True,
    )
    
    return [
        DefaultInfo(
            files = depset([archive, runner_script]),
            runfiles = ctx.runfiles(files = [runner_script, release_dir]),
            executable = runner_script,
        ),
    ]

gleam_binary_v2 = rule(
    implementation = _gleam_binary_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files for the binary (e.g., main.gleam)",
            allow_files = [".gleam"],
            default = [],
        ),
        "srcs_deps": attr.label_list(
            doc = "Targets providing source files (for library sources)",
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Library dependencies",
            providers = [GleamLibraryInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "Package name",
            mandatory = True,
        ),
        "gleam_toml": attr.label(
            doc = "gleam.toml file",
            allow_single_file = ["gleam.toml"],
            default = None,
        ),
        "entry_module": attr.string(
            doc = "Entry module name (default: package_name)",
            default = "",
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    executable = True,
)