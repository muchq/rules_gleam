"""gleam_library wraps its compile in quiet_on_success only when quiet_warnings is set."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//gleam:defs.bzl", "gleam_library")

def _impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == "GleamCompilePackage"]
    asserts.equals(env, 1, len(compiles))
    command = compiles[0].argv[-1]
    asserts.equals(env, 1, command.count("compile-package"), command)
    start = command.find("{ _out=$(")
    asserts.equals(env, ctx.attr.quiet, start >= 0, command)
    if ctx.attr.quiet:
        wrapped = command[start:command.find(" 2>&1) || {", start)]
        asserts.true(env, "compile-package" in wrapped, "the wrapper must hold the compile: " + command)
    return analysistest.end(env)

_quiet_warnings_test = analysistest.make(_impl, attrs = {"quiet": attr.bool()})

def quiet_warnings_test_suite(name):
    """Declares a quiet and a default library and checks each one's compile command.

    Args:
        name: Test suite name.
    """
    for quiet in [True, False]:
        lib = "{}_lib_{}".format(name, quiet).lower()
        gleam_library(
            name = lib,
            package_name = lib,
            srcs = ["src/quiet.gleam"],
            quiet_warnings = quiet,
            tags = ["manual"],
        )
        _quiet_warnings_test(
            name = "{}_{}".format(name, quiet),
            target_under_test = ":" + lib,
            quiet = quiet,
        )
    native.test_suite(name = name, tests = [":{}_{}".format(name, q) for q in [True, False]])
