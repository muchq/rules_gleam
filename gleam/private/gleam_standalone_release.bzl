"""Implementation of the gleam_standalone_release rule.

Packages a gleam_library and its transitive deps as a fully self-contained runfiles-tree
binary that bundles the Erlang/OTP runtime itself -- unlike gleam_binary (escript) and
gleam_release (both of which still shell out to a system Erlang), the machine that *runs*
the result does not need any Erlang installed at all.

Requires the hermetic Erlang toolchain, which is on by default: only that toolchain exposes a
Bazel-visible, bundleable OTP tree (see erlang/private/hermetic_erlang_repository.bzl's
otp_tree filegroup). If gleam.local_erlang_toolchain() opts back out to PATH-based host
discovery (erlang/private/local_erlang_repository.bzl), there is no such tree -- copying an
arbitrary host Erlang install's files is not reliably relocatable, since many system package
managers bake absolute paths into generated scripts.
"""

load(":gleam_library.bzl", "GleamPackageInfo")

def _find_erl_file(otp_tree_files, label):
    for f in otp_tree_files:
        if f.short_path.endswith("otp/bin/erl"):
            return f
    fail((
        "gleam_standalone_release '{label}': could not find 'otp/bin/erl' in the hermetic " +
        "Erlang toolchain's otp_tree filegroup. This is an internal error in the hermetic " +
        "toolchain (erlang/private/hermetic_erlang_repository.bzl) -- please file an issue."
    ).format(label = label))

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
    erl_file = _find_erl_file(otp_tree_files, ctx.label)

    dep_info = ctx.attr.dep[GleamPackageInfo]
    entry_module = ctx.attr.entry_module
    entry_function = ctx.attr.entry_function

    all_compiled_dirs = dep_info.transitive_compiled_dirs.to_list()
    all_data = dep_info.transitive_data.to_list()

    launcher = ctx.actions.declare_file(ctx.label.name)

    # At runtime, paths are relative to this launcher's own runfiles root (same convention as
    # gleam_release), including the bundled erl binary itself -- see gleam_release.bzl for why
    # "$RF/{ws}/{short_path}" is correct for both own-repo and external-repo (e.g. the hermetic
    # Erlang toolchain's) files alike.
    ws_name = ctx.workspace_name
    pa_parts = []
    for compiled_dir in all_compiled_dirs:
        pa_parts.append('-pa "$RF/{ws}/{path}/ebin"'.format(ws = ws_name, path = compiled_dir.short_path))
    pa_flags = " ".join(pa_parts)

    ctx.actions.write(
        output = launcher,
        is_executable = True,
        content = """#!/bin/bash
# Standalone launcher for Gleam release: {label} -- bundles its own Erlang/OTP runtime, so
# no Erlang needs to be installed on the machine that runs this.
set -euo pipefail

# Resolve this binary's own runfiles root -- see gleam_release.bzl for the same logic.
if [[ -n "${{RUNFILES_DIR:-}}" && -d "${{RUNFILES_DIR:-}}" ]]; then
  RF="$RUNFILES_DIR"
elif [[ -d "$0.runfiles" ]]; then
  RF="$0.runfiles"
elif [[ -d "${{BASH_SOURCE[0]}}.runfiles" ]]; then
  RF="${{BASH_SOURCE[0]}}.runfiles"
else
  echo "ERROR: could not locate the runfiles directory for {label}." >&2
  exit 1
fi

exec "$RF/{ws}/{erl_path}" {pa_flags} -noshell -s {entry_module} {entry_function} -s init stop
""".format(
            label = ctx.label.name,
            ws = ws_name,
            erl_path = erl_file.short_path,
            pa_flags = pa_flags,
            entry_module = entry_module,
            entry_function = entry_function,
        ),
    )

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
Erlang installed at all, unlike `gleam_binary` (escript) or `gleam_release`, both of which
still shell out to a system Erlang.

Requires the hermetic Erlang toolchain, which is on by default -- fails with an actionable
error if `gleam.local_erlang_toolchain()` has opted back out to PATH-based discovery. This is
the recommended, easiest-to-get-right way to ship a portable Gleam CLI tool: build once, copy
the resulting runfiles tree to any machine with the same OS/CPU architecture, and run it with
no setup required.

Like `gleam_release`, this does not attempt to start the package as an OTP application (no
`application:ensure_all_started` call) -- call it yourself from `entry_module` if needed.
""",
)
