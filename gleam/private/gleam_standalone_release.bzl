"""Implementation of the gleam_standalone_release rule.

Packages a gleam_library and its transitive deps as a fully self-contained runfiles-tree
binary that bundles the Erlang/OTP runtime itself -- the machine that *runs* the result does
not need any Erlang installed at all. gleam_release does this too under the hermetic
toolchain, but silently falls back to a PATH lookup under gleam.local_erlang_toolchain();
this rule instead fails outright unless the hermetic toolchain is active, for callers who
want that guaranteed rather than best-effort.

Requires the hermetic Erlang toolchain, which is on by default: only that toolchain exposes a
Bazel-visible, bundleable OTP tree (see erlang/private/hermetic_erlang_repository.bzl's
otp_tree filegroup). If gleam.local_erlang_toolchain() opts back out to PATH-based host
discovery (erlang/private/local_erlang_repository.bzl), there is no such tree -- copying an
arbitrary host Erlang install's files is not reliably relocatable, since many system package
managers bake absolute paths into generated scripts.
"""

load(":erlang_otp_tree.bzl", "find_erl_file")
load(":gleam_library.bzl", "GleamPackageInfo")
load(":release_launcher.bzl", "write_release_launcher")

def _gleam_standalone_release_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    otp_tree = getattr(erlang_toolchain, "otp_tree", None)
    if not otp_tree:
        fail((
            "gleam_standalone_release '{label}' requires the hermetic Erlang toolchain, which " +
            "is on by default -- but this build has no bundleable OTP tree, which means " +
            "gleam.local_erlang_toolchain() must be set in your MODULE.bazel, opting back out " +
            "to PATH-based discovery (erlang/private/local_erlang_repository.bzl). Remove that " +
            "call to use gleam_standalone_release."
        ).format(label = ctx.label))

    otp_tree_files = otp_tree[DefaultInfo].files.to_list()
    erl_file = find_erl_file(otp_tree_files, ctx.label)

    dep_info = ctx.attr.dep[GleamPackageInfo]

    all_compiled_dirs = dep_info.transitive_compiled_dirs.to_list()
    all_data = dep_info.transitive_data.to_list()

    erl_invocation = '"$RF/{ws}/{path}"'.format(ws = ctx.workspace_name, path = erl_file.short_path)
    launcher = write_release_launcher(ctx, erl_invocation, all_compiled_dirs)

    # Runfiles: all transitive compiled dirs + runtime data (same as gleam_release), plus the
    # entire bundled OTP tree -- this is what makes the result independent of any host Erlang.
    runfiles_files = all_compiled_dirs + all_data + otp_tree_files

    return [
        DefaultInfo(
            executable = launcher,
            files = depset([launcher]),
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

gleam_standalone_release = rule(
    implementation = _gleam_standalone_release_impl,
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
    doc = """\
Packages a `gleam_library` and its transitive deps as a fully self-contained binary that
bundles the Erlang/OTP runtime itself: the machine that *runs* the result does not need any
Erlang installed at all, unlike `gleam_binary` (escript), which always shells out to a system
Erlang via a PATH lookup.

`gleam_release` also bundles the runtime under the hermetic toolchain, but silently falls
back to a PATH lookup under `gleam.local_erlang_toolchain()`. This rule instead requires the
hermetic Erlang toolchain (on by default) and fails with an actionable error if
`gleam.local_erlang_toolchain()` has opted back out to PATH-based discovery -- use this when
you want that guarantee enforced. The bundled runtime still needs a compatible OS/CPU, ABI
and system shared libraries. Linux builds are glibc/distro-specific, not musl/static binaries;
macOS builds require a compatible macOS version. Validate the actual deployment image.

Arguments, VM configuration, runtime data and shutdown follow the `gleam_release` contract.
This is a launcher with a bundled runtime, not full OTP release management or hot upgrades.

Like `gleam_release`, this does not attempt to start the package as an OTP application (no
`application:ensure_all_started` call) -- call it yourself from `entry_module` if needed.
""",
)
