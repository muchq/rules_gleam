"""Implementation of the gleam_binary rule."""

load("//gleam/private:gleam_library.bzl", "GleamLibraryProviderInfo")

def _gleam_binary_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    package_name = ctx.attr.package_name

    # Collect all compiled dependencies
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

    # Build the main binary's code if it has its own sources
    main_output_dir = ctx.actions.declare_directory("build_" + package_name)
    
    all_input_items = list(ctx.files.srcs) + dep_srcs
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)
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

    # Build the main module
    command_script_parts = []
    working_dir_for_gleam = "."
    if ctx.file.gleam_toml:
        toml_dir = ctx.file.gleam_toml.dirname
        if toml_dir and toml_dir != ".":
            working_dir_for_gleam = toml_dir
            command_script_parts.append('cd "{}"'.format(working_dir_for_gleam))

    # Just build, don't export - we'll assemble our own release
    command_script_parts.append(
        '"{}" "{}" build'.format(gleam_exe_wrapper.path, underlying_gleam_tool.path),
    )
    
    # Copy the built artifacts to our output directory
    gleam_build_output = "build/dev/erlang/" + package_name
    command_script_parts.append(
        'if [ -d "{src}" ]; then mkdir -p "{dst}" && cp -pR "{src}/." "{dst}/"; fi'.format(
            src = gleam_build_output,
            dst = main_output_dir.path,
        ),
    )

    command_str = " && ".join(command_script_parts)

    ctx.actions.run_shell(
        command = command_str,
        inputs = inputs_depset,
        outputs = [main_output_dir],
        env = env_vars,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        progress_message = "Building Gleam binary for {}".format(package_name),
        mnemonic = "GleamBuildBinary",
    )

    # Create a release directory with all dependencies
    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")
    
    # Assemble all BEAM files and dependencies into the release directory
    assemble_commands = []
    assemble_commands.append('mkdir -p "{}/lib"'.format(release_dir.path))
    
    # Copy main application
    assemble_commands.append('cp -pR "{}" "{}/lib/{}"'.format(
        main_output_dir.path,
        release_dir.path,
        package_name,
    ))
    
    # Copy all dependencies
    for dep_dir in all_dep_dirs:
        # Extract package name from the path (last component)
        dep_name = dep_dir.basename if hasattr(dep_dir, "basename") else dep_dir.path.split("/")[-1]
        assemble_commands.append('cp -pR "{}" "{}/lib/{}"'.format(
            dep_dir.path,
            release_dir.path,
            dep_name,
        ))
    
    # Copy gleam_stdlib and gleam_erlang if available
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        for stdlib in ["gleam_stdlib", "gleam_erlang"]:
            stdlib_path = erlang_toolchain.erl_libs_path_str + "/" + stdlib
            assemble_commands.append(
                'if [ -d "{}" ]; then cp -pR "{}" "{}/lib/{}"; fi'.format(
                    stdlib_path,
                    stdlib_path,
                    release_dir.path,
                    stdlib,
                )
            )

    assemble_cmd = " && ".join(assemble_commands)
    
    all_inputs = [main_output_dir] + all_dep_dirs
    ctx.actions.run_shell(
        command = assemble_cmd,
        inputs = depset(all_inputs),
        outputs = [release_dir],
        progress_message = "Assembling Gleam release for {}".format(package_name),
        mnemonic = "GleamAssembleRelease",
    )

    # Create runner script that works with runfiles properly
    runner_script = ctx.actions.declare_file(ctx.label.name)
    
    # Determine the entry module and function
    entry_module = ctx.attr.entry_module if ctx.attr.entry_module else "main"
    entry_function = ctx.attr.entry_function if ctx.attr.entry_function else "main"
    
    # Build -pa paths for all libraries in the release
    pa_paths = []
    pa_paths.append('"${{RELEASE_DIR}}/lib/{}/ebin"'.format(package_name))
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_name = dep[GleamLibraryProviderInfo].package_name
            pa_paths.append('"${{RELEASE_DIR}}/lib/{}/ebin"'.format(dep_name))
    pa_paths.append('"${{RELEASE_DIR}}/lib/gleam_stdlib/ebin"')
    pa_paths.append('"${{RELEASE_DIR}}/lib/gleam_erlang/ebin"')
    
    erl_pa_flags = " ".join(["-pa {}".format(p) for p in pa_paths])

    runner_content = """#!/bin/bash
set -euo pipefail

# Find the runfiles directory
if [ -z "${RUNFILES_DIR:-}" ]; then
  if [ -f "$0.runfiles/MANIFEST" ]; then
    RUNFILES_DIR="$0.runfiles"
  elif [ -f "$0.runfiles_manifest" ]; then
    RUNFILES_DIR=$(grep -m1 "^[^ ]* " "$0.runfiles_manifest" | cut -d' ' -f2 | sed 's|/[^/]*$||')
  else
    echo "ERROR: Cannot find runfiles directory" >&2
    exit 1
  fi
fi

# Set up paths
RELEASE_DIR="${{RUNFILES_DIR}}/{workspace}/{release_path}"

if [ ! -d "$RELEASE_DIR" ]; then
  echo "ERROR: Release directory not found at $RELEASE_DIR" >&2
  exit 1
fi

# Find Erlang runtime
if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang runtime (erl) not found in PATH" >&2
  exit 1
fi

# Run the application
exec "$ERL" \
  {pa_flags} \
  -noshell \
  -s {entry_module} {entry_function} \
  -s init stop \
  -- "$@"
""".format(
        workspace = ctx.workspace_name,
        release_path = release_dir.short_path,
        pa_flags = erl_pa_flags,
        entry_module = entry_module,
        entry_function = entry_function,
    )

    ctx.actions.write(
        output = runner_script,
        content = runner_content,
        is_executable = True,
    )

    # Create deployable tar.gz archive
    archive = ctx.actions.declare_file(ctx.label.name + "_deploy.tar.gz")
    
    # Create a standalone runner script for the archive
    standalone_runner = ctx.actions.declare_file(ctx.label.name + "_standalone_runner.sh")
    standalone_content = """#!/bin/bash
set -euo pipefail

# This script should be run from the directory containing the extracted archive
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}"

if [ ! -d "$RELEASE_DIR/lib" ]; then
  echo "ERROR: This script must be run from the extracted archive directory" >&2
  echo "       Expected to find lib/ directory in $RELEASE_DIR" >&2
  exit 1
fi

# Find Erlang runtime
if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang runtime (erl) not found in PATH" >&2
  exit 1
fi

# Build -pa paths
PA_FLAGS=""
for dir in "$RELEASE_DIR"/lib/*/ebin; do
  if [ -d "$dir" ]; then
    PA_FLAGS="$PA_FLAGS -pa '$dir'"
  fi
done

# Run the application
eval exec "$ERL" \
  $PA_FLAGS \
  -noshell \
  -s {entry_module} {entry_function} \
  -s init stop \
  -- "$@"
""".format(
        entry_module = entry_module,
        entry_function = entry_function,
    )
    
    ctx.actions.write(
        output = standalone_runner,
        content = standalone_content,
        is_executable = True,
    )
    
    # Create the tar.gz archive
    tar_cmd = """
    cd {release_dir} && \
    cp {runner_script} ./run.sh && \
    tar czf {archive} lib/ run.sh
    """.format(
        release_dir = release_dir.path,
        runner_script = standalone_runner.path,
        archive = archive.path,
    )
    
    ctx.actions.run_shell(
        command = tar_cmd,
        inputs = depset([release_dir, standalone_runner]),
        outputs = [archive],
        progress_message = "Creating deployable archive for {}".format(package_name),
        mnemonic = "GleamCreateArchive",
    )

    # Provide runfiles for bazel run
    runfiles = ctx.runfiles(
        files = [runner_script, release_dir],
    )

    return [
        DefaultInfo(
            files = depset([archive, runner_script]),
            runfiles = runfiles,
            executable = runner_script,
        ),
    ]

gleam_binary = rule(
    implementation = _gleam_binary_impl,
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
            doc = "The gleam.toml file for this binary package.",
            allow_single_file = True,
            default = None,
        ),
        "entry_module": attr.string(
            doc = "The Erlang module name containing the entry point (default: 'main').",
            default = "",
        ),
        "entry_function": attr.string(
            doc = "The function name to call in the entry module (default: 'main').",
            default = "",
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    executable = True,
)