"""Implementation of the gleam_binary rule.

The binary rule assembles pre-compiled BEAM files from its library dependency
(and all transitive deps) into a single-file executable (escript).
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

    # Compile the shim to a .beam file
    shim_src = ctx.file._gleescript_shim
    shim_beam = ctx.actions.declare_file("gleescript_main_shim.beam")

    erlc_path = erlang_toolchain.erlc_path_str
    if not erlc_path:
        erlc_path = "erlc"

    ctx.actions.run(
        executable = erlc_path,
        arguments = ["-o", shim_beam.dirname, shim_src.path],
        inputs = [shim_src],
        outputs = [shim_beam],
        mnemonic = "CompileGleamShim",
        progress_message = "Compiling Gleam binary shim",
        use_default_shell_env = True,
    )

    # Run the builder to create the escript
    builder_src = ctx.file._escript_builder
    executable = ctx.actions.declare_file(ctx.label.name)

    escript_path = erlang_toolchain.escript_path_str
    if not escript_path:
        escript_path = "escript"

    # Arguments for the builder: OutFile, PackageName, EntryModule, EntryFunction, ShimBeam, Files...
    args = ctx.actions.args()
    args.add(executable)
    args.add(dep_info.package_name)
    args.add(entry_module)
    args.add(entry_function)
    args.add(shim_beam) # Add shim beam to inputs
    args.add_all(all_compiled_dirs) # Add all compiled dirs

    ctx.actions.run(
        executable = escript_path,
        arguments = [builder_src.path, args],
        inputs = [builder_src, shim_beam] + all_compiled_dirs,
        outputs = [executable],
        mnemonic = "BuildGleamEscript",
        progress_message = "Building Gleam escript: " + ctx.label.name,
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = ctx.runfiles(files = [executable]),
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
        "_gleescript_shim": attr.label(
            default = Label("//gleam/private:gleescript_main_shim.erl"),
            allow_single_file = True,
        ),
        "_escript_builder": attr.label(
            default = Label("//gleam/private:escript_builder.erl"),
            allow_single_file = True,
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    executable = True,
)
