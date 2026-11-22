"""Verify headers compile and OTP can locate the packaged priv directory."""

def _asset_test_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        """#!/bin/bash
set -euo pipefail
export RUNFILES_DIR="$TEST_SRCDIR"
output=$("$TEST_SRCDIR/{ws}/{binary}")
[[ "$output" == "header and asset" ]]
""".format(ws = ctx.workspace_name, binary = ctx.executable.binary.short_path),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [ctx.executable.binary]).merge(ctx.attr.binary[DefaultInfo].default_runfiles),
    )]

asset_test = rule(
    implementation = _asset_test_impl,
    attrs = {"binary": attr.label(executable = True, cfg = "target", mandatory = True)},
    test = True,
)
