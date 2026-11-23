"""Supported-package and fail-closed policy tests."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//gleam/private:hex_package_policy.bzl", "unsupported_package_reason")  # buildifier: disable=bzl-visibility

_OPT_IN_HINT = "Only audited plain Erlang packages may opt in with allow_plain_erlang / plain_erlang_packages."

def _check(env, case, expected, build_tools, otp_app = "app", has_gleam_toml = True, allow_plain_erlang = False, native_markers = []):
    actual = unsupported_package_reason("app", build_tools, otp_app, has_gleam_toml, allow_plain_erlang, native_markers)
    asserts.equals(env, expected, actual, "case '{}'".format(case))

# Supported packages.

def _accepts_supported_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, "gleam package", None, ["gleam"])
    _check(env, "opted-in rebar3 package", None, ["rebar3"], has_gleam_toml = False, allow_plain_erlang = True)
    return unittest.end(env)

_accepts_supported_packages_test = unittest.make(_accepts_supported_packages_test_impl)

# Unsupported build tooling.

def _rejects_unsupported_build_tools_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(
        env,
        "rebar3 without opt-in",
        'build_tools = ["rebar3"] requires unsupported build tooling. ' + _OPT_IN_HINT,
        ["rebar3"],
        has_gleam_toml = False,
    )
    _check(
        env,
        "mix with opt-in",
        'build_tools = ["mix"] requires unsupported build tooling. ' + _OPT_IN_HINT,
        ["mix"],
        has_gleam_toml = False,
        allow_plain_erlang = True,
    )
    return unittest.end(env)

_rejects_unsupported_build_tools_test = unittest.make(_rejects_unsupported_build_tools_test_impl)

# Missing gleam.toml.

def _rejects_missing_gleam_toml_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(
        env,
        "no build tools, no opt-in",
        "archive has no gleam.toml; explicitly audit and opt in with allow_plain_erlang / plain_erlang_packages to compile plain Erlang sources.",
        [],
        has_gleam_toml = False,
    )
    _check(
        env,
        "gleam build tool, opted in",
        "declares the Gleam build tool but contains no gleam.toml.",
        ["gleam"],
        has_gleam_toml = False,
        allow_plain_erlang = True,
    )
    return unittest.end(env)

_rejects_missing_gleam_toml_test = unittest.make(_rejects_missing_gleam_toml_test_impl)

# Native or custom build entry points.

def _rejects_native_markers_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(
        env,
        "c_src in gleam package",
        'native/custom build inputs ["c_src"] are unsupported; NIFs, Mix and build scripts are not executed.',
        ["gleam"],
        native_markers = ["c_src"],
    )
    _check(
        env,
        "rebar.config.script despite opt-in",
        'native/custom build inputs ["rebar.config.script"] are unsupported; NIFs, Mix and build scripts are not executed.',
        ["rebar3"],
        has_gleam_toml = False,
        allow_plain_erlang = True,
        native_markers = ["rebar.config.script"],
    )
    return unittest.end(env)

_rejects_native_markers_test = unittest.make(_rejects_native_markers_test_impl)

# OTP application name.

def _accepts_differing_otp_app_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(
        env,
        "otp_app differs from Hex name",
        None,
        ["gleam"],
        otp_app = "different_app",
    )
    _check(env, "renamed plain Erlang application", None, ["rebar3"], otp_app = "hpack", has_gleam_toml = False, allow_plain_erlang = True)
    return unittest.end(env)

_accepts_differing_otp_app_test = unittest.make(_accepts_differing_otp_app_test_impl)

def _rejects_invalid_otp_app_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["", "../hpack", "hpack/app", 'hpack"', "hpack\\app"]:
        reason = unsupported_package_reason("app", ["gleam"], name, True, False, [])
        asserts.true(env, reason != None and reason.startswith("Invalid OTP application name"))
    return unittest.end(env)

_rejects_invalid_otp_app_test = unittest.make(_rejects_invalid_otp_app_test_impl)

def hex_package_policy_test_suite(name):
    """Declares the policy test suite.

    Args:
        name: Test suite name.
    """
    unittest.suite(
        name,
        _accepts_supported_packages_test,
        _rejects_unsupported_build_tools_test,
        _rejects_missing_gleam_toml_test,
        _rejects_native_markers_test,
        _accepts_differing_otp_app_test,
        _rejects_invalid_otp_app_test,
    )
