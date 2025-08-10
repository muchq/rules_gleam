"""Improved implementation of gleam_test rule for running Gleam tests."""

def _gleam_test_impl(ctx):
    """Run Gleam tests."""
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    
    package_name = ctx.attr.package_name
    
    # Collect all inputs - source files and test files
    inputs = []
    inputs.extend(ctx.files.srcs)
    inputs.extend(ctx.files.test_srcs)
    if ctx.file.gleam_toml:
        inputs.append(ctx.file.gleam_toml)
    
    # Create test runner script
    test_runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    
    test_script = """#!/bin/bash
set -euo pipefail

EXECROOT=$(pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Create project structure
mkdir -p $TEMP_DIR/src
mkdir -p $TEMP_DIR/test

# Copy source files
"""
    
    # Copy source files
    for src in ctx.files.srcs:
        src_path = src.path
        if "/src/" in src_path:
            idx = src_path.rfind("/src/")
            rel_path = src_path[idx+1:]
        else:
            rel_path = "src/" + src.basename
        test_script += 'cp "{}" "$TEMP_DIR/{}"\n'.format(src_path, rel_path)
    
    # Copy test files
    for test_src in ctx.files.test_srcs:
        test_path = test_src.path
        if "/test/" in test_path:
            idx = test_path.rfind("/test/")
            rel_path = test_path[idx+1:]
        else:
            rel_path = "test/" + test_src.basename
        test_script += 'cp "{}" "$TEMP_DIR/{}"\n'.format(test_path, rel_path)
    
    if ctx.file.gleam_toml:
        test_script += 'cp "{}" "$TEMP_DIR/gleam.toml"\n'.format(ctx.file.gleam_toml.path)
    
    # Run tests
    test_script += """
cd $TEMP_DIR

# Find the gleam wrapper in runfiles
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
if [ ! -d "$RUNFILES_DIR" ]; then
  RUNFILES_DIR="$(dirname "$0")"
fi

GLEAM_WRAPPER="$RUNFILES_DIR/_main/{gleam_wrapper}"
GLEAM_TOOL="$RUNFILES_DIR/_main/{gleam_tool}"

if [ ! -f "$GLEAM_WRAPPER" ]; then
  echo "ERROR: Cannot find gleam wrapper at $GLEAM_WRAPPER" >&2
  exit 1
fi

# Run Gleam tests
echo "Running tests for {package_name}..."
"$GLEAM_WRAPPER" "$GLEAM_TOOL" test --target erlang

echo "Tests completed successfully!"
""".format(
        package_name=package_name,
        gleam_wrapper=gleam_exe_wrapper.short_path,
        gleam_tool=underlying_gleam_tool.short_path,
    )
    
    ctx.actions.write(
        output = test_runner,
        content = test_script,
        is_executable = True,
    )
    
    # Return test info with proper runfiles including the gleam tools
    return [
        DefaultInfo(
            files = depset([test_runner]),
            runfiles = ctx.runfiles(
                files = inputs + [test_runner, gleam_exe_wrapper, underlying_gleam_tool],
            ),
            executable = test_runner,
        ),
    ]

gleam_test = rule(
    implementation = _gleam_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Gleam source files",
            allow_files = [".gleam"],
            mandatory = True,
        ),
        "test_srcs": attr.label_list(
            doc = "Gleam test files",
            allow_files = [".gleam"],
            mandatory = True,
        ),
        "package_name": attr.string(
            doc = "Name of the Gleam package",
            mandatory = True,
        ),
        "gleam_toml": attr.label(
            doc = "gleam.toml configuration file",
            allow_single_file = ["gleam.toml"],
            default = None,
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    test = True,
)