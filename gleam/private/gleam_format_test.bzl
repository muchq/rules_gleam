"""Implementation of the gleam_format_test rule.

Runs `gleam format --check` over a set of source files, failing if any of them aren't
already correctly formatted. Unlike gleam_library/gleam_test, `gleam format` operates
directly on a list of files or directories -- it doesn't need a gleam.toml, --lib, or any
other package context -- so this rule is much simpler than the compile-based ones.
"""

def _gleam_format_test_impl(ctx):
    gleam_toolchain_info = ctx.toolchains["//gleam:toolchain_type"]
    gleam_exe_wrapper = gleam_toolchain_info.gleam_executable
    underlying_gleam_tool = gleam_toolchain_info.underlying_gleam_tool

    test_runner_script = ctx.actions.declare_file(ctx.label.name + "_format_test.sh")

    ws_name = ctx.workspace_name

    def runtime_path(f):
        return "$TEST_SRCDIR/{ws}/{path}".format(ws = ws_name, path = f.short_path)

    file_args = " ".join(['"{}"'.format(runtime_path(f)) for f in ctx.files.srcs])

    ctx.actions.write(
        output = test_runner_script,
        is_executable = True,
        content = """#!/bin/bash
# Format check for Gleam sources: {label}
set -euo pipefail

exec "{wrapper}" "{tool}" format --check {files}
""".format(
            label = ctx.label.name,
            wrapper = runtime_path(gleam_exe_wrapper),
            tool = runtime_path(underlying_gleam_tool),
            files = file_args,
        ),
    )

    runfiles_files = [gleam_exe_wrapper, underlying_gleam_tool] + list(ctx.files.srcs)

    return [
        DefaultInfo(
            executable = test_runner_script,
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
    ]

gleam_format_test = rule(
    implementation = _gleam_format_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Gleam source files to check formatting for, e.g. " +
                  "glob([\"src/**/*.gleam\", \"test/**/*.gleam\"]).",
            allow_files = [".gleam"],
            mandatory = True,
        ),
    },
    toolchains = ["//gleam:toolchain_type"],
    test = True,
    doc = """\
Checks that a set of Gleam source files are already formatted per `gleam format`, failing
the build with a diff if not. Does not modify any files (that would require a separate,
non-hermetic "fix" target akin to Buildifier's write-back mode; not provided here).

Unlike `gleam_library`/`gleam_test`, this rule doesn't compile anything and doesn't need a
`gleam.toml`, `deps`, or a `package_name` -- `gleam format` operates directly on files.
""",
)
