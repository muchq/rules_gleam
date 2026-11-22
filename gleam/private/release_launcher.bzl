"""Shared Unix launcher and runtime-data contract for release rules."""

load("@bazel_skylib//lib:shell.bzl", "shell")

def write_release_launcher(ctx, erl_invocation, compiled_dirs):
    """Write a relocatable launcher that forwards application arguments verbatim.

    Args:
        ctx: Release rule context.
        erl_invocation: Quoted runfiles-relative erl command, or a PATH lookup.
        compiled_dirs: Transitive compiled package directories.

    Returns:
        The executable launcher File.
    """
    launcher = ctx.actions.declare_file(ctx.label.name)
    pa_flags = " ".join([
        '-pa "$RF"/' + shell.quote(ctx.workspace_name + "/" + directory.short_path + "/ebin")
        for directory in compiled_dirs
    ])
    ctx.actions.write(
        output = launcher,
        is_executable = True,
        content = """#!/bin/bash
set -euo pipefail

# Prefer this artifact's adjacent tree over a caller's inherited runfiles.
if [[ -d "$0.runfiles" ]]; then
  RF="$0.runfiles"
elif [[ -n "${{RUNFILES_DIR:-}}" && -d "$RUNFILES_DIR" ]]; then
  RF="$RUNFILES_DIR"
else
  echo "ERROR: could not locate the release runfiles directory." >&2
  exit 1
fi
RF="$(cd "$RF" && pwd -P)"
export RUNFILES_DIR="$RF"
export GLEAM_RUNFILES_DIR="$RF/{workspace}"

# VM configuration uses Erlang's ERL_AFLAGS/ERL_FLAGS or -args_file mechanism.
# Everything after -extra is application data, including empty strings and flags.
# exec keeps the VM's exit status and delivers service-manager signals directly.
exec {erl} {pa} -noshell -s {module} {function} -s init stop -extra "$@"
""".format(
            workspace = ctx.workspace_name,
            erl = erl_invocation,
            pa = pa_flags,
            module = shell.quote(ctx.attr.entry_module),
            function = shell.quote(ctx.attr.entry_function),
        ),
    )
    return launcher
