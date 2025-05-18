"""Implementation of the gleam_library rule."""

GleamLibraryProviderInfo = provider(
    doc = "Provider for Gleam library information",
    fields = {
        "output_pkg_build_dir": "TreeArtifact for the package's output directory (build/erlang/lib/<package_name>).",
        "package_name": "Name of the Gleam package.",
        "srcs": "List of source files.",
        # TODO: Consider adding transitive sources or other necessary info for consumers.
    },
)

def _gleam_library_impl(ctx):
    # Retrieve the resolved Gleam toolchain (which includes Erlang info).
    # The toolchain type is defined in //gleam/BUILD.bazel.
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]

    # This is the wrapper script that sets up PATH and calls the actual gleam binary.
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable

    # This is the underlying actual gleam binary (e.g., from @gleam_toolchain_os_arch//:gleam_tool).
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool

    # This is the ErlangToolchainInfo (actually platform_common.ToolchainInfo with Erlang fields).
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    package_name = ctx.attr.package_name

    # Declare the output directory for this library's compiled artifacts.
    # This path structure is conventional for Gleam builds.
    output_pkg_build_dir_path = "build/erlang/lib/" + package_name
    output_pkg_build_dir = ctx.actions.declare_directory(output_pkg_build_dir_path)

    # Collect output directories from direct Gleam library dependencies.
    dep_output_dirs = []
    for dep in ctx.attr.deps:
        if GleamLibraryProviderInfo in dep:
            dep_output_dirs.append(dep[GleamLibraryProviderInfo].output_pkg_build_dir)

    # Prepare inputs for the build action.
    all_input_items = list(ctx.files.srcs)
    all_input_items.extend(dep_output_dirs)
    if ctx.file.gleam_toml:
        all_input_items.append(ctx.file.gleam_toml)
    if ctx.files.data:
        all_input_items.extend(ctx.files.data)
    inputs_depset = depset(all_input_items)

    # Prepare environment variables, particularly ERL_LIBS.
    env_vars = {}
    all_erl_libs_paths = []

    # Add Erlang's own library paths if available from the toolchain.
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        all_erl_libs_paths.append(erlang_toolchain.erl_libs_path_str)

    # Add output paths of dependency libraries to ERL_LIBS.
    # These are relative to the execroot, so they should work directly.
    for dep_dir in dep_output_dirs:
        all_erl_libs_paths.append(dep_dir.path)  # Use .path for TreeArtifacts in ERL_LIBS

    if all_erl_libs_paths:
        env_vars["ERL_LIBS"] = ":".join(all_erl_libs_paths)

    # Determine working directory for the `gleam build` command.
    # If gleam.toml is provided, use its directory.
    command_parts = []
    working_dir_for_gleam_build = "."  # Default to execroot
    path_prefix_to_execroot = ""

    if ctx.file.gleam_toml:
        # Ensure dirname is not empty, which can happen if gleam.toml is at root.
        toml_dir = ctx.file.gleam_toml.dirname
        if toml_dir and toml_dir != ".":
            working_dir_for_gleam_build = toml_dir
            command_parts.append('cd "{}"'.format(working_dir_for_gleam_build))

            # Calculate prefix to get from toml_dir back to execroot
            num_segments = toml_dir.count("/")
            path_prefix_to_execroot = "/".join([".."] * (num_segments + 1)) + "/"

    # Construct the `gleam build` command using the wrapper and underlying tool.
    # The wrapper script (gleam_exe_wrapper) expects the actual gleam binary path as its first argument.
    # Prepend path_prefix_to_execroot if we changed directory.
    wrapper_exec_path = path_prefix_to_execroot + gleam_exe_wrapper.path
    underlying_tool_exec_path = path_prefix_to_execroot + underlying_gleam_tool.path
    gleam_build_cmd = '"{}" "{}" build'.format(wrapper_exec_path, underlying_tool_exec_path)
    command_parts.append(gleam_build_cmd)

    # --- BEGIN DEBUG ---
    command_parts.append("echo '--- DEBUG: After gleam build, before cp in gleam_library ---'")
    command_parts.append("actual_pwd=$(pwd); echo \"PWD after gleam build: $actual_pwd\"")
    command_parts.append("echo \'Listing current directory contents (where gleam build ran):\'")
    command_parts.append("ls -laR")  # List CWD recursively
    command_parts.append("echo \'Expected source for cp (relative to PWD of gleam build): build/dev/erlang/{}\'".format(package_name))
    command_parts.append("echo \'Checking existence of build/dev/erlang/{}:\'".format(package_name))
    command_parts.append("ls -lad \"build/dev/erlang/{}\" || echo \'Source sub-directory build/dev/erlang/{} NOT FOUND\'".format(package_name, package_name))
    command_parts.append("echo \'Checking existence of DESTINATION dir before cp: {}\'.format(output_pkg_build_dir.path))
    command_parts.append("ls -lad \"{}\" || echo \'DESTINATION directory {} NOT FOUND before cp\'".format(output_pkg_build_dir.path, output_pkg_build_dir.path))
    command_parts.append("echo \'Full path to declared Bazel output dir for cp dest: {}\'".format(output_pkg_build_dir.path))
    command_parts.append("echo '--- END DEBUG ---'")
    # --- END DEBUG ---

    # Define where `gleam build` places its output relative to its working directory.
    # This is typically `build/dev/erlang/<package_name>` for the default 'dev' profile.
    # If working_dir_for_gleam_build is ".", this path is relative to execroot.
    # If cd'd into toml_dir, this path is relative to toml_dir.
    gleam_internal_output_subdir = "build/dev/erlang/" + package_name

    # Command to copy the build artifacts from Gleam's internal output location
    # to the Bazel-declared output directory (output_pkg_build_dir).
    # The `/.` after source dir ensures contents are copied, not the directory itself.
    # output_pkg_build_dir.path is the absolute path in the sandbox for Bazel's declared output.
    # The source path for cp needs to be relative to where the shell command is executing *after* any cd.
    copy_source_path = gleam_internal_output_subdir
    copy_dest_path = output_pkg_build_dir.path

    copy_command = 'cp -pR "{}/." "{}/"'.format(copy_source_path, copy_dest_path)
    command_parts.append(copy_command)

    final_shell_command = " && ".join(command_parts)

    # Execute the shell command.
    ctx.actions.run_shell(
        command = final_shell_command,
        # Tools needed: the wrapper script and the actual gleam binary it calls.
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        inputs = inputs_depset,
        outputs = [output_pkg_build_dir],
        env = env_vars,
        progress_message = "Building Gleam library: " + package_name,
        mnemonic = "GleamBuildLib",
    )

    return [
        DefaultInfo(files = depset([output_pkg_build_dir])),
        GleamLibraryProviderInfo(
            output_pkg_build_dir = output_pkg_build_dir,
            package_name = package_name,
            srcs = ctx.files.srcs,  # Pass along the original sources
        ),
    ]

gleam_library = rule(
    implementation = _gleam_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source .gleam files.",
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
            doc = "The gleam.toml file for this library package. If provided, its directory is used as CWD for gleam build.",
            allow_single_file = True,
            default = None,
        ),
        "data": attr.label_list(
            doc = "Data dependencies.",
            allow_files = True,
            default = [],
        ),
    },
    toolchains = ["//gleam:toolchain_type"],  # Updated toolchain label
)
