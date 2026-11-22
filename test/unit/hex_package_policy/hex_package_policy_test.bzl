"""Supported-package and fail-closed policy tests."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//gleam/private:hex_package_policy.bzl", "unsupported_package_reason")

def _policy_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, unsupported_package_reason("app", ["gleam"], "app", True, False, []))
    asserts.equals(env, None, unsupported_package_reason("app", ["rebar3"], "app", False, True, []))
    for tools, has_toml, opt_in, markers, app, diagnostic in [
        (["rebar3"], False, False, [], "app", "unsupported build tooling"),
        (["mix"], False, True, [], "app", "unsupported build tooling"),
        ([], False, False, [], "app", "no gleam.toml"),
        (["gleam"], False, True, [], "app", "contains no gleam.toml"),
        (["gleam"], True, False, ["c_src"], "app", "NIFs"),
        (["rebar3"], False, True, ["rebar.config.script"], "app", "build scripts"),
        (["gleam"], True, False, [], "different_app", "differs from Hex name"),
    ]:
        reason = unsupported_package_reason("app", tools, app, has_toml, opt_in, markers)
        asserts.true(env, reason != None and diagnostic in reason, str(reason))
    return unittest.end(env)

_policy_test = unittest.make(_policy_test_impl)

def hex_package_policy_test_suite(name):
    """Declares the policy test suite.

    Args:
        name: Test suite name.
    """
    unittest.suite(name, _policy_test)
