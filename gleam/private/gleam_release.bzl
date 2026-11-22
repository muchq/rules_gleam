"""Implementation of the gleam_release rule.

Packages a gleam_library and its transitive deps as a runfiles-tree binary (a small launcher
script plus the compiled BEAM directories and any declared runtime `data`), rather than a
single self-contained escript.

This is the right shape for services that need config files, templates, certs, or other
runtime data available alongside the compiled code (see gleam_binary for the single-file
escript alternative, better suited to portable CLI tools that don't need bundled data).
"""

load(":erlang_otp_tree.bzl", "resolve_erl_invocation")
load(":gleam_library.bzl", "GleamPackageInfo")
load(":release_launcher.bzl", "write_release_launcher")

def _gleam_release_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    dep_info = ctx.attr.dep[GleamPackageInfo]

    all_compiled_dirs = dep_info.transitive_compiled_dirs.to_list()
    all_data = dep_info.transitive_data.to_list()

    ws_name = ctx.workspace_name
    otp_tree = getattr(erlang_toolchain, "otp_tree", None)
    otp_tree_files = otp_tree[DefaultInfo].files.to_list() if otp_tree else []

    # See resolve_erl_invocation's docstring for why the hermetic toolchain's own erl_path_str
    # can't be used directly here: it's an absolute path into Bazel's own cache, not valid on
    # any machine but the one that built this release. This branch (and its counterpart, the
    # PATH-based fallback when the toolchain has no bundleable otp_tree) is covered directly by
    # test/unit/erlang_otp_tree, without needing a full toolchain-dependent build to exercise.
    erl_invocation, extra_runfiles = resolve_erl_invocation(otp_tree_files, ws_name, ctx.label)

    launcher = write_release_launcher(ctx, erl_invocation, all_compiled_dirs)

    # Runfiles: all transitive compiled dirs (for -pa) plus all transitive runtime data, so
    # code can read data files at paths relative to its own package (see the "data" attr on
    # gleam_library), plus the bundled OTP tree when the hermetic toolchain provided one.
    runfiles_files = all_compiled_dirs + all_data + extra_runfiles

    return [
        DefaultInfo(
            executable = launcher,
            files = depset([launcher]),
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

gleam_release = rule(
    implementation = _gleam_release_impl,
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
Packages a `gleam_library` and its transitive deps as a runfiles-tree binary: a small
launcher script plus the compiled BEAM directories and any declared runtime `data`
(config files, templates, certs, etc.), reachable at runtime under the launcher's own
runfiles directory.

Under the hermetic Erlang toolchain (the default), this bundles the toolchain's own OTP tree
into the release's runfiles. No host Erlang is needed, but the runtime still requires a
compatible OS/CPU, ABI and system shared libraries (Linux builds are glibc/distro-specific;
macOS builds require a compatible macOS version). Under
`gleam.local_erlang_toolchain()`'s PATH-based discovery, there is no such tree to bundle, so
the launcher falls back to a plain PATH lookup for `erl` at run time (the same portability
model as `gleam_binary`'s escript): whatever Erlang built this must also be reasonably
compatible with whatever's on PATH wherever it actually runs. If you want a hard guarantee
that this rule never silently falls back to that PATH-lookup behavior, use
`gleam_standalone_release` instead, which fails outright unless the hermetic toolchain is active.

Unlike `gleam_binary`, this does not produce a single self-contained escript -- the
result is a launcher script that must be run alongside its `.runfiles` directory (as
`bazel run` does automatically, and as a `bazel build`-produced binary does when invoked
directly). This is the tradeoff for being able to ship `data` at all: escript archives
don't compose with Bazel's runfiles model.

Application arguments are forwarded after `-extra` with their boundaries preserved. Read
these strings with `init:get_plain_arguments/0` (the entry function remains zero-arity).
Configure the VM with Erlang's `ERL_AFLAGS`/`ERL_FLAGS` or an `-args_file`, not application argv.
`GLEAM_RUNFILES_DIR` names the absolute main-workspace data root; prefer `code:priv_dir/1`
for package-owned `priv/` assets. The launcher preserves the caller's working directory.

These launchers are not full OTP releases: no boot-script generation, release_handler hot
upgrades, or service supervision is provided. The VM receives signals directly; SIGTERM
initiates OTP shutdown, and application cleanup must be implemented by the application.

Does not attempt to start the package as an OTP application (no `application:ensure_all_started`
call) -- call it yourself from `entry_module` if your package needs it.
""",
)
