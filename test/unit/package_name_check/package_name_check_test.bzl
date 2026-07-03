"""Unit test for gleam/private/package_name_check.bzl's gleam_package_name_check rule.

gleam_package_name_check has no toolchain dependency, so its registered action can be
inspected directly via analysistest without needing a real Gleam/Erlang toolchain build.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//gleam/private:package_name_check.bzl", "gleam_package_name_check")

def _registers_validation_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(env, 1, len(actions))

    action = actions[0]
    asserts.equals(env, "GleamPackageNameCheck", action.mnemonic)

    input_short_paths = [f.short_path for f in action.inputs.to_list()]
    asserts.true(
        env,
        any([p.endswith("fixture_gleam.toml") for p in input_short_paths]),
        "expected fixture_gleam.toml among the action's inputs, got: {}".format(input_short_paths),
    )

    output_short_paths = [f.short_path for f in action.outputs.to_list()]
    asserts.true(
        env,
        any([p.endswith(".ok") for p in output_short_paths]),
        "expected a '*.ok' marker among the action's outputs, got: {}".format(output_short_paths),
    )

    return analysistest.end(env)

registers_validation_action_test = analysistest.make(_registers_validation_action_test_impl)

def _test_registers_validation_action():
    gleam_package_name_check(
        name = "check_under_test",
        gleam_toml = "fixture_gleam.toml",
        package_name = "my_pkg",
        tags = ["manual"],
    )
    registers_validation_action_test(
        name = "registers_validation_action_test",
        target_under_test = ":check_under_test",
    )

def package_name_check_test_suite(name):
    _test_registers_validation_action()
    native.test_suite(
        name = name,
        tests = [":registers_validation_action_test"],
    )
