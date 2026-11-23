"""Verify real escripts start their OTP application before calling the entry point."""

def _escript_startup_test_impl(ctx):
    erlang = ctx.toolchains["//erlang:erlang_toolchain_type"]
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        """#!/bin/bash
set -euo pipefail
if ! output=$("$TEST_SRCDIR/{ws}/{escript}" "$TEST_SRCDIR/{ws}/{binary}" 2>&1); then
  echo "{name}: escript failed: $output" >&2
  exit 1
fi
if [[ "$output" != "application started" ]]; then
  echo "{name}: expected 'application started', got: $output" >&2
  exit 1
fi
""".format(
            ws = ctx.workspace_name,
            escript = erlang.escript.short_path,
            binary = ctx.executable.binary.short_path,
            name = ctx.label.name,
        ),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(
            files = [ctx.executable.binary],
            transitive_files = erlang.tool_files,
        ).merge(ctx.attr.binary[DefaultInfo].default_runfiles),
    )]

escript_startup_test = rule(
    implementation = _escript_startup_test_impl,
    attrs = {"binary": attr.label(executable = True, cfg = "target", mandatory = True)},
    toolchains = ["//erlang:erlang_toolchain_type"],
    test = True,
)
