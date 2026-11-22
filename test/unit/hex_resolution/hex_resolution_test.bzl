"""Shared Hex graph resolution and failure diagnostics."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//gleam/private:hex_resolution.bzl", "hex_declaration", "resolve_hex_packages")  # buildifier: disable=bzl-visibility

def _pkg(name = "app", version = "1.0.0", sha256 = "ab", source = "module alpha via hex_package", **kwargs):
    return hex_declaration(name = name, version = version, sha256 = sha256, source = source, deps = kwargs.pop("deps", []), **kwargs)

def _deduplicates_test_impl(ctx):
    env = unittest.begin(ctx)
    first = _pkg(sha256 = "AB", deps = ["two", "one", "two"], build_tools = ["gleam", "gleam"])
    second = _pkg(deps = ["one", "two"], build_tools = ["gleam"], otp_app = "app", source = "module beta via manifest")
    declarations = [first, second, _pkg(name = "two"), _pkg(name = "one")]
    result = resolve_hex_packages(declarations)
    asserts.equals(env, ["app", "one", "two"], [pkg.name for pkg in result])
    asserts.equals(env, ["one", "two"], result[0].deps)
    asserts.equals(env, result, resolve_hex_packages(list(reversed(declarations))))
    asserts.equals(env, [], resolve_hex_packages([]))
    return unittest.end(env)

_deduplicates_test = unittest.make(_deduplicates_test_impl)

def _root_override_test_impl(ctx):
    env = unittest.begin(ctx)
    root = _pkg(version = "2.0.0", deps = ["replacement"], is_root = True, override = True)

    # The overridden version's requirements need not be declared; only the
    # selected graph is used. Root selection is independent of traversal order.
    other = _pkg(deps = ["old_dependency"])
    replacement = _pkg(name = "replacement")
    for declarations in [[root, other, replacement], [other, replacement, root]]:
        result = resolve_hex_packages(declarations)
        asserts.equals(env, "2.0.0", result[0].version)
        asserts.equals(env, ["replacement"], result[0].deps)
    return unittest.end(env)

_root_override_test = unittest.make(_root_override_test_impl)

def _diamond_test_impl(ctx):
    env = unittest.begin(ctx)
    result = resolve_hex_packages([
        _pkg(name = "top", deps = ["left", "right"]),
        _pkg(name = "left", deps = ["leaf"]),
        _pkg(name = "right", deps = ["leaf"]),
        _pkg(name = "leaf"),
    ])
    asserts.equals(env, 4, len(result))
    return unittest.end(env)

_diamond_test = unittest.make(_diamond_test_impl)

def _failure_fixture_impl(ctx):
    case = ctx.attr.case
    if case == "version":
        declarations = [_pkg(is_root = True), _pkg(version = "2.0.0", source = "module beta via manifest")]
    elif case == "checksum":
        declarations = [_pkg(is_root = True, override = True), _pkg(sha256 = "cd")]
    elif case == "unselected_checksum":
        declarations = [_pkg(version = "2.0.0", is_root = True, override = True), _pkg(), _pkg(sha256 = "cd")]
    elif case == "non_root":
        declarations = [_pkg(override = True)]
    elif case == "two_overrides":
        declarations = [_pkg(is_root = True, override = True), _pkg(is_root = True, override = True)]
    elif case == "missing":
        declarations = [_pkg(deps = ["missing"])]
    elif case == "override_missing":
        declarations = [_pkg(), _pkg(is_root = True, override = True, deps = ["missing"])]
    elif case == "cycle":
        declarations = [_pkg(deps = ["other"]), _pkg(name = "other", deps = ["app"])]
    elif case == "self_cycle":
        declarations = [_pkg(deps = ["app"])]
    elif case == "deps":
        declarations = [_pkg(), _pkg(deps = ["other"])]
    elif case == "build_tools":
        declarations = [_pkg(), _pkg(build_tools = ["rebar3"])]
    elif case == "otp_app":
        declarations = [_pkg(), _pkg(otp_app = "other")]
    elif case == "allow_plain_erlang":
        declarations = [_pkg(), _pkg(allow_plain_erlang = True)]
    else:
        fail("Unknown test case: " + case)
    resolve_hex_packages(declarations)
    return []

_failure_fixture = rule(implementation = _failure_fixture_impl, attrs = {"case": attr.string()})

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for message in ctx.attr.messages:
        asserts.expect_failure(env, message)
    return analysistest.end(env)

_failure_test = analysistest.make(_failure_test_impl, expect_failure = True, attrs = {"messages": attr.string_list()})

def hex_resolution_test_suite(name):
    """Declare graph-resolution tests.

    Args:
        name: Test suite name.
    """
    unittest.suite(name + "_success", _deduplicates_test, _root_override_test, _diamond_test)
    cases = {
        "version": ["differ in version", "module alpha", "module beta", "override = True"],
        "checksum": ["Conflicting checksums", "override = True cannot change immutable package bytes"],
        "unselected_checksum": ["Conflicting checksums"],
        "non_root": ["Only the root module"],
        "two_overrides": ["Multiple root overrides"],
        "missing": ["requires undeclared package 'missing'", "module alpha"],
        "override_missing": ["requires undeclared package 'missing'"],
        "cycle": ["Dependency cycle", "app", "other"],
        "self_cycle": ["Dependency cycle"],
        "deps": ["differ in deps"],
        "build_tools": ["differ in build_tools"],
        "otp_app": ["differ in otp_app"],
        "allow_plain_erlang": ["differ in allow_plain_erlang"],
    }
    for case, messages in cases.items():
        _failure_fixture(name = case + "_fixture", case = case, tags = ["manual"])
        _failure_test(name = case + "_test", target_under_test = ":" + case + "_fixture", messages = messages)
    native.test_suite(name = name, tests = [name + "_success"] + [case + "_test" for case in cases])
