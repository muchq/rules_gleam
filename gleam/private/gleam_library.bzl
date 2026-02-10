"""Implementation of the gleam_library rule.

Uses `gleam compile-package` to compile a single Gleam package at a time,
taking pre-compiled dependencies via --lib. This aligns with Bazel's
per-target caching model: each package compiles once and downstream
targets consume compiled BEAM artifacts.
"""

GleamPackageInfo = provider(
    doc = "Provider for compiled Gleam package information.",
    fields = {
        "compiled_dir": "TreeArtifact (named after the package) containing ebin/ with compiled BEAM files.",
        "package_name": "Name of the Gleam package.",
        "transitive_compiled_dirs": "Depset of all transitive compiled TreeArtifacts (including this package's own).",
    },
)

def _gleam_library_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool

    package_name = ctx.attr.package_name

    # Declare a TreeArtifact named after the package so downstream rules
    # can derive the package name from the directory basename.
    compiled_dir = ctx.actions.declare_directory("_gleam_pkg/" + package_name)

    # Collect dependency info.
    dep_infos = []
    transitive_dep_sets = []
    for dep in ctx.attr.deps:
        if GleamPackageInfo in dep:
            dep_info = dep[GleamPackageInfo]
            dep_infos.append(dep_info)
            transitive_dep_sets.append(dep_info.transitive_compiled_dirs)

    # Build the transitive depset (includes this package's own output).
    transitive_compiled_dirs = depset(
        direct = [compiled_dir],
        transitive = transitive_dep_sets,
    )

    # Prepare inputs: source files + all transitive compiled dirs.
    input_files = list(ctx.files.srcs)
    if ctx.files.data:
        input_files.extend(ctx.files.data)
    inputs_depset = depset(
        direct = input_files,
        transitive = transitive_dep_sets,
    )

    # Determine the source directory from source file paths.
    src_dir = _get_src_dir(ctx)

    # Build the shell command for gleam compile-package.
    cmd_parts = []

    # Sandbox-safe XDG dirs.
    cmd_parts.append("export XDG_CACHE_HOME=$(pwd)/.cache")
    cmd_parts.append("export XDG_DATA_HOME=$(pwd)/.local/share")

    # Set up the --lib directory with symlinks to each dep's compiled output.
    cmd_parts.append("mkdir -p _gleam_lib")
    for dep_info in dep_infos:
        cmd_parts.append('ln -s "$(pwd)/{compiled}" "_gleam_lib/{name}"'.format(
            compiled = dep_info.compiled_dir.path,
            name = dep_info.package_name,
        ))

    # Run gleam compile-package.
    compile_cmd = '"{wrapper}" "{tool}" compile-package --target=erlang --package="$(pwd)/{src}" --out="$(pwd)/{out}" --lib="$(pwd)/_gleam_lib"'.format(
        wrapper = gleam_exe_wrapper.path,
        tool = underlying_gleam_tool.path,
        src = src_dir,
        out = compiled_dir.path,
    )
    cmd_parts.append(compile_cmd)

    final_command = " && ".join(cmd_parts)

    ctx.actions.run_shell(
        command = final_command,
        tools = depset([gleam_exe_wrapper, underlying_gleam_tool]),
        inputs = inputs_depset,
        outputs = [compiled_dir],
        progress_message = "Compiling Gleam package: " + package_name,
        mnemonic = "GleamCompilePackage",
    )

    return [
        DefaultInfo(files = depset([compiled_dir])),
        GleamPackageInfo(
            compiled_dir = compiled_dir,
            package_name = package_name,
            transitive_compiled_dirs = transitive_compiled_dirs,
        ),
    ]

def _get_src_dir(ctx):
    """Derive the source directory from the source files.

    Looks for the 'src/' directory component in source file paths.
    Falls back to the directory of the first source file.
    """
    if not ctx.files.srcs:
        fail("No source files provided for gleam_library '{}'.".format(ctx.label.name))

    first_src = ctx.files.srcs[0]
    path = first_src.path

    # Look for /src/ in the path and use everything up to it (the package root).
    parts = path.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] == "src":
            return "/".join(parts[:i])

    # Fallback: directory of the first source file.
    return first_src.dirname

gleam_library = rule(
    implementation = _gleam_library_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files (typically glob([\"src/**/*.gleam\", \"src/**/*.erl\", \"src/**/*.mjs\"])).",
            allow_files = [".gleam", ".erl", ".mjs"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Gleam package dependencies (other gleam_library targets).",
            providers = [GleamPackageInfo],
            default = [],
        ),
        "package_name": attr.string(
            doc = "The name of the Gleam package.",
            mandatory = True,
        ),
        "data": attr.label_list(
            doc = "Data dependencies.",
            allow_files = True,
            default = [],
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
)
