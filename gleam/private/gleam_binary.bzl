"""Implementation of the gleam_binary rule.

The binary rule does NO compilation. It assembles pre-compiled BEAM files
from its library dependency (and all transitive deps) into a release
structure, then generates a runner script.
"""

load("//gleam/private:gleam_library.bzl", "GleamPackageInfo")

def _gleam_binary_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    entry_module = ctx.attr.entry_module
    entry_function = ctx.attr.entry_function

    dep_info = ctx.attr.dep[GleamPackageInfo]

    # Collect all transitive compiled directories.
    all_compiled_dirs = dep_info.transitive_compiled_dirs.to_list()

    # Declare the release directory as a TreeArtifact.
    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")

    # Build the assembly command: copy each package's ebin/ into release/lib/<pkg>/ebin/.
    cmd_parts = []
    for compiled_dir in all_compiled_dirs:
        # compiled_dir basename is the package name (by convention from gleam_library).
        pkg_name = compiled_dir.basename
        cmd_parts.append(
            'mkdir -p "{release}/lib/{pkg}" && cp -pR "{src}/." "{release}/lib/{pkg}/"'.format(
                release = release_dir.path,
                pkg = pkg_name,
                src = compiled_dir.path,
            ),
        )

    if not cmd_parts:
        fail("gleam_binary '{}' has no compiled packages to assemble.".format(ctx.label.name))

    assembly_command = " && ".join(cmd_parts)

    ctx.actions.run_shell(
        command = assembly_command,
        inputs = depset(all_compiled_dirs),
        outputs = [release_dir],
        progress_message = "Assembling Gleam binary: " + ctx.label.name,
        mnemonic = "GleamAssembleBinary",
    )

    # Create the runner script.
    runner_script = ctx.actions.declare_file(ctx.label.name + "_runner.sh")

    # Get the Erlang executable path from the toolchain.
    erl_path = "erl"  # Default: assume on PATH.
    if hasattr(erlang_toolchain, "erl_path_str") and erlang_toolchain.erl_path_str:
        erl_path = erlang_toolchain.erl_path_str

    ctx.actions.write(
        output = runner_script,
        is_executable = True,
        content = """#!/bin/bash
# Runner script for Gleam binary: {label}
set -e

# Determine RUNFILES_DIR.
if [ -z "$RUNFILES_DIR" ]; then
  RUNFILES_DIR_CANDIDATE="$0.runfiles"
  if [ -d "$RUNFILES_DIR_CANDIDATE" ]; then
    RUNFILES_DIR="$RUNFILES_DIR_CANDIDATE"
  else
    echo "ERROR: RUNFILES_DIR not set and $0.runfiles not found." >&2
    exit 1
  fi
fi

RELEASE_DIR="$RUNFILES_DIR/{ws_name}/{release_short_path}"

if [ ! -d "$RELEASE_DIR" ]; then
  echo "ERROR: Release directory not found at $RELEASE_DIR" >&2
  exit 1
fi

# Build -pa flags for all package ebin directories.
PA_FLAGS=""
for ebin_dir in "$RELEASE_DIR"/lib/*/ebin; do
  if [ -d "$ebin_dir" ]; then
    PA_FLAGS="$PA_FLAGS -pa $ebin_dir"
  fi
done

exec "{erl_path}" $PA_FLAGS -noshell -s {entry_module} {entry_function} -s init stop -- "$@"
""".format(
            label = ctx.label.name,
            ws_name = ctx.workspace_name,
            release_short_path = release_dir.short_path,
            erl_path = erl_path,
            entry_module = entry_module,
            entry_function = entry_function,
        ),
    )

    runfiles = ctx.runfiles(
        files = [runner_script],
        transitive_files = depset([release_dir]),
    )

    return [
        DefaultInfo(
            runfiles = runfiles,
            executable = runner_script,
        ),
    ]

gleam_binary = rule(
    implementation = _gleam_binary_impl,
    attrs = {
        "dep": attr.label(
            doc = "The gleam_library target containing the entry point module.",
            providers = [GleamPackageInfo],
            mandatory = True,
        ),
        "entry_module": attr.string(
            doc = "The Erlang module name to call at startup (e.g. 'main').",
            mandatory = True,
        ),
        "entry_function": attr.string(
            doc = "The function to call in the entry module.",
            default = "main",
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    executable = True,
)
