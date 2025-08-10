"""Improved implementation of the gleam_library rule with proper caching."""

GleamLibraryInfo = provider(
    doc = "Information about a compiled Gleam library",
    fields = {
        "package_name": "Name of the Gleam package",
        "build_dir": "Directory containing all build outputs",
        "transitive_build_dirs": "Depset of all transitive build directories",
    },
)

def _gleam_library_impl(ctx):
    """Compile Gleam sources into a reusable library."""
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain
    
    package_name = ctx.attr.package_name
    
    # Declare output directory for this library's build artifacts
    build_output_dir = ctx.actions.declare_directory("{}_gleam_build".format(ctx.label.name))
    
    # Collect transitive build directories from dependencies
    transitive_build_dirs = []
    dep_build_dirs = []
    for dep in ctx.attr.deps:
        if GleamLibraryInfo in dep:
            dep_build_dirs.append(dep[GleamLibraryInfo].build_dir)
            transitive_build_dirs.append(dep[GleamLibraryInfo].build_dir)
            transitive_build_dirs.extend(dep[GleamLibraryInfo].transitive_build_dirs.to_list())
    
    # Prepare inputs
    inputs = []
    inputs.extend(ctx.files.srcs)
    inputs.extend(dep_build_dirs)
    if ctx.file.gleam_toml:
        inputs.append(ctx.file.gleam_toml)
    
    # Build the shell command
    cmd_parts = []
    
    # Create temporary workspace
    cmd_parts.append("set -euo pipefail")
    cmd_parts.append("EXECROOT=$(pwd)")
    cmd_parts.append("TEMP_DIR=$(mktemp -d)")
    cmd_parts.append('trap "rm -rf $TEMP_DIR" EXIT')
    
    # Set up source structure
    cmd_parts.append("mkdir -p $TEMP_DIR/src")
    
    # Copy source files maintaining structure
    for src in ctx.files.srcs:
        src_path = src.path
        # Handle different source layouts
        if "/src/" in src_path:
            # Extract everything after /src/
            idx = src_path.rfind("/src/")
            rel_path = src_path[idx+1:]
        else:
            # Just use the basename in src/
            rel_path = "src/" + src.basename
        cmd_parts.append('mkdir -p "$TEMP_DIR/$(dirname "{}")"'.format(rel_path))
        cmd_parts.append('cp "{}" "$TEMP_DIR/{}"'.format(src_path, rel_path))
    
    # Copy gleam.toml if present
    if ctx.file.gleam_toml:
        cmd_parts.append('cp "{}" "$TEMP_DIR/gleam.toml"'.format(ctx.file.gleam_toml.path))
    
    # Set up dependency packages by copying their entire build output
    if dep_build_dirs:
        cmd_parts.append("mkdir -p $TEMP_DIR/build/packages")
        for dep_dir in dep_build_dirs:
            # Each dependency's build dir contains the full build output
            # We need to extract the package content from it
            dep_info = None
            for dep in ctx.attr.deps:
                if GleamLibraryInfo in dep and dep[GleamLibraryInfo].build_dir == dep_dir:
                    dep_info = dep[GleamLibraryInfo]
                    break
            
            if dep_info:
                dep_pkg_name = dep_info.package_name
                # Copy the dependency's compiled package - try all possible locations
                cmd_parts.append('# Copy dependency package: {}'.format(dep_pkg_name))
                # Gleam may use different names, so copy all packages from the dep
                loop_cmd = 'for pkg_path in {dep}/dev/erlang/* {dep}/prod/erlang/*; do if [ -d "$pkg_path" ]; then pkg_name=$(basename "$pkg_path"); echo "Copying package $pkg_name from dependency"; cp -r "$pkg_path" "$TEMP_DIR/build/packages/$pkg_name"; fi; done 2>/dev/null || true'.format(dep = dep_dir.path)
                cmd_parts.append(loop_cmd)
    
    # Set up environment for Gleam
    if hasattr(erlang_toolchain, "erl_libs_path_str") and erlang_toolchain.erl_libs_path_str:
        cmd_parts.append('export ERL_LIBS="{}"'.format(erlang_toolchain.erl_libs_path_str))
    
    # Run gleam build  
    cmd_parts.append("cd $TEMP_DIR")
    cmd_parts.append('"$EXECROOT/{}" "$EXECROOT/{}" build --target erlang'.format(
        gleam_exe_wrapper.path,
        underlying_gleam_tool.path,
    ))
    
    # Copy outputs to declared directory  
    copy_cmd = """
if [ -d "build" ]; then
  mkdir -p "{output}"
  cp -r build/* "{output}"
else
  echo "ERROR: Gleam build did not produce build directory" >&2
  exit 1
fi
""".format(output = build_output_dir.path)
    cmd_parts.append(copy_cmd)
    
    # Join all command parts
    cmd = " && ".join(cmd_parts)
    
    # Run the build
    ctx.actions.run_shell(
        command = cmd,
        inputs = depset(inputs),
        outputs = [build_output_dir],
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        mnemonic = "GleamCompile",
        progress_message = "Compiling Gleam library {}".format(package_name),
    )
    
    # Provide information for downstream rules
    return [
        DefaultInfo(files = depset([build_output_dir])),
        GleamLibraryInfo(
            package_name = package_name,
            build_dir = build_output_dir,
            transitive_build_dirs = depset(transitive_build_dirs + [build_output_dir]),
        ),
    ]

gleam_library_v2 = rule(
    implementation = _gleam_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Gleam source files",
            allow_files = [".gleam"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other gleam_library dependencies",
            providers = [GleamLibraryInfo],
            default = [],
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
    provides = [GleamLibraryInfo],
)