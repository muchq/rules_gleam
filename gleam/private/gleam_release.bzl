"""Implementation of the gleam_release rule.

Packages a gleam_library and its transitive deps as a runfiles-tree binary (a small launcher
script plus the compiled BEAM directories and any declared runtime `data`), rather than a
single self-contained escript.

This is the right shape for services that need config files, templates, certs, or other
runtime data available alongside the compiled code (see gleam_binary for the single-file
escript alternative, better suited to portable CLI tools that don't need bundled data).
"""

load("//gleam/private:gleam_library.bzl", "GleamPackageInfo")

def _gleam_release_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    erlang_toolchain = gleam_toolchain_info.erlang_toolchain

    dep_info = ctx.attr.dep[GleamPackageInfo]
    entry_module = ctx.attr.entry_module
    entry_function = ctx.attr.entry_function

    all_compiled_dirs = dep_info.transitive_compiled_dirs.to_list()
    all_data = dep_info.transitive_data.to_list()

    erl_path = "erl"
    if hasattr(erlang_toolchain, "erl_path_str") and erlang_toolchain.erl_path_str:
        erl_path = erlang_toolchain.erl_path_str

    launcher = ctx.actions.declare_file(ctx.label.name)

    # At runtime, paths are relative to this launcher's own runfiles root, joined with the
    # workspace name (matching how gleam_test locates -pa paths under $TEST_SRCDIR/$WORKSPACE).
    ws_name = ctx.workspace_name
    pa_parts = []
    for compiled_dir in all_compiled_dirs:
        pa_parts.append('-pa "$RF/{ws}/{path}/ebin"'.format(ws = ws_name, path = compiled_dir.short_path))
    pa_flags = " ".join(pa_parts)

    ctx.actions.write(
        output = launcher,
        is_executable = True,
        content = """#!/bin/bash
# Launcher for Gleam release: {label}
set -euo pipefail

# Resolve this binary's own runfiles root, whether invoked via `bazel run`, run directly
# after `bazel build` (Bazel places a "<binary>.runfiles" directory next to the output),
# or as a dependency of another runfiles-aware binary. This only covers the Unix layout
# (symlinked runfiles tree); Windows is not supported here.
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

exec "{erl_path}" {pa_flags} -noshell -s {entry_module} {entry_function} -s init stop
""".format(
            label = ctx.label.name,
            erl_path = erl_path,
            pa_flags = pa_flags,
            entry_module = entry_module,
            entry_function = entry_function,
        ),
    )

    # Runfiles: all transitive compiled dirs (for -pa) plus all transitive runtime data, so
    # code can read data files at paths relative to its own package -- see the "data" attr
    # on gleam_library for how those paths are laid out.
    runfiles_files = all_compiled_dirs + all_data

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

Unlike `gleam_binary`, this does not produce a single self-contained escript -- the
result is a launcher script that must be run alongside its `.runfiles` directory (as
`bazel run` does automatically, and as a `bazel build`-produced binary does when invoked
directly). This is the tradeoff for being able to ship `data` at all: escript archives
don't compose with Bazel's runfiles model.

Does not attempt to start the package as an OTP application (no `application:ensure_all_started`
call) -- call it yourself from `entry_module` if your package needs it.
""",
)
