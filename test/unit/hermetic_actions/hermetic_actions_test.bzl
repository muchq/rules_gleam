"""Regression tests for OTP action inputs and test runfiles (#133)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//gleam:defs.bzl", "gleam_binary", "gleam_library", "gleam_test")

def _hermetic_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    expected = {f.path: True for f in ctx.files._otp_tree}
    asserts.true(env, bool(expected), "expected a nonempty OTP installation")
    checked = []
    for action in actions:
        if action.mnemonic not in ctx.attr.mnemonics:
            continue
        checked.append(action.mnemonic)
        inputs = {f.path: True for f in action.inputs.to_list()}
        missing = [p for p in expected if p not in inputs]
        asserts.equals(env, [], missing, "{} must hash/stage the entire OTP installation".format(action.mnemonic))
        if action.mnemonic in ["CompileGleamShim", "CompileGleamEunitRunner", "BuildGleamEscript"]:
            asserts.false(env, action.argv[0].startswith("/"), "OTP executable must be an execroot-relative artifact")
    asserts.equals(env, sorted(ctx.attr.mnemonics), sorted(checked))

    if ctx.attr.check_runfiles:
        runfiles = analysistest.target_under_test(env)[DefaultInfo].default_runfiles.files.to_list()
        paths = {f.path: True for f in runfiles}
        asserts.equals(env, [], [p for p in expected if p not in paths], "test runfiles must include OTP")
        runner = [a for a in actions if a.mnemonic == "FileWrite"][0]
        asserts.true(env, "$TEST_SRCDIR/" in runner.content)
        asserts.false(env, ctx.bin_dir.path in runner.content, "test launcher must use runfiles paths")
    return analysistest.end(env)

_hermetic_actions_test = analysistest.make(
    _hermetic_actions_test_impl,
    attrs = {
        "mnemonics": attr.string_list(),
        "check_runfiles": attr.bool(),
        "_otp_tree": attr.label(default = "@local_config_erlang//:otp_tree", allow_files = True),
    },
)

def hermetic_actions_test_suite(name):
    """Checks every action that invokes OTP, plus the test runtime closure.

    Args:
        name: Name of the generated test suite.
    """
    gleam_library(
        name = "library",
        package_name = "example",
        srcs = ["src/example.gleam"],
        data = ["fixture_gleam.toml"],
        tags = ["manual"],
    )
    gleam_binary(
        name = "binary",
        dep = ":library",
        entry_module = "example",
        tags = ["manual"],
    )
    gleam_test(
        name = "test_subject",
        package_name = "example",
        srcs = ["src/example.gleam"],
        test_srcs = ["test/example_test.gleam"],
        data = ["fixture_gleam.toml"],
        tags = ["manual"],
    )
    _hermetic_actions_test(
        name = "library_inputs_test",
        target_under_test = ":library",
        mnemonics = ["GleamCompilePackage"],
    )
    _hermetic_actions_test(
        name = "binary_inputs_test",
        target_under_test = ":binary",
        mnemonics = ["CompileGleamShim", "BuildGleamEscript"],
    )
    _hermetic_actions_test(
        name = "test_inputs_and_runfiles_test",
        target_under_test = ":test_subject",
        mnemonics = ["GleamCompileTest", "CompileGleamEunitRunner"],
        check_runfiles = True,
    )
    native.test_suite(
        name = name,
        tests = [":library_inputs_test", ":binary_inputs_test", ":test_inputs_and_runfiles_test"],
    )
