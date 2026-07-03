"""Unit tests for gleam/private/erlang_otp_tree.bzl.

Covers the exact branching logic that regressed in gleam_release before it was extracted here
(PR #85): whether the hermetic toolchain's otp_tree is present or absent decides between a
runfiles-relative erl path and a plain PATH lookup, and that decision needs to keep being
right without requiring a full toolchain-dependent build to check it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//gleam/private:erlang_otp_tree.bzl", "find_erl_file", "resolve_erl_invocation")  # buildifier: disable=bzl-visibility

def _fake_file(short_path):
    # find_erl_file and resolve_erl_invocation only ever read `.short_path` off these, so a
    # plain struct stands in for a real ctx.actions.File without needing any Bazel machinery.
    return struct(short_path = short_path)

# ---- Pure-function tests: no target-under-test or toolchain resolution needed. ----

def _finds_erl_in_otp_tree_test_impl(ctx):
    env = unittest.begin(ctx)
    files = [
        _fake_file("external/foo/otp/bin/erlc"),
        _fake_file("external/foo/otp/bin/erl"),
        _fake_file("external/foo/otp/lib/kernel.beam"),
    ]
    found = find_erl_file(files, Label("//test/unit/erlang_otp_tree:fake"))
    asserts.equals(env, "external/foo/otp/bin/erl", found.short_path)
    return unittest.end(env)

finds_erl_in_otp_tree_test = unittest.make(_finds_erl_in_otp_tree_test_impl)

def _falls_back_to_path_when_no_otp_tree_test_impl(ctx):
    env = unittest.begin(ctx)
    invocation, extra_runfiles = resolve_erl_invocation([], "my_ws", Label("//test/unit/erlang_otp_tree:fake"))
    asserts.equals(env, "erl", invocation)
    asserts.equals(env, [], extra_runfiles)
    return unittest.end(env)

falls_back_to_path_when_no_otp_tree_test = unittest.make(_falls_back_to_path_when_no_otp_tree_test_impl)

def _bundles_runfiles_relative_path_when_otp_tree_present_test_impl(ctx):
    env = unittest.begin(ctx)
    files = [_fake_file("external/foo/otp/bin/erl")]
    invocation, extra_runfiles = resolve_erl_invocation(files, "my_ws", Label("//test/unit/erlang_otp_tree:fake"))

    # This exact shape is what gleam_release got wrong before PR #85: it must be a
    # runfiles-relative path (quoted, joined with $RF and the workspace name), never the
    # toolchain's own absolute build-machine path.
    asserts.equals(env, '"$RF/my_ws/external/foo/otp/bin/erl"', invocation)
    asserts.equals(env, files, extra_runfiles)
    return unittest.end(env)

bundles_runfiles_relative_path_when_otp_tree_present_test = unittest.make(_bundles_runfiles_relative_path_when_otp_tree_present_test_impl)

# ---- asserts.expect_failure (via analysistest.make(expect_failure = True)): proves
# find_erl_file's fail() actually fires, through a real rule and real Bazel File objects
# (rather than the fakes above). ----

def _lookup_impl(ctx):
    find_erl_file(ctx.files.srcs, ctx.label)
    return [DefaultInfo()]

_lookup_rule = rule(
    implementation = _lookup_impl,
    attrs = {"srcs": attr.label_list(allow_files = True)},
)

def _fails_when_erl_absent_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "could not find 'otp/bin/erl'")
    return analysistest.end(env)

_fails_when_erl_absent_test = analysistest.make(_fails_when_erl_absent_test_impl, expect_failure = True)

def _test_fails_when_erl_absent():
    _lookup_rule(
        name = "otp_tree_missing_erl",
        srcs = ["dummy.txt"],
        tags = ["manual"],
    )
    _fails_when_erl_absent_test(
        name = "fails_when_erl_absent_test",
        target_under_test = ":otp_tree_missing_erl",
    )

def erlang_otp_tree_test_suite(name):
    _test_fails_when_erl_absent()
    unittest.suite(
        "erlang_otp_tree_pure_tests",
        finds_erl_in_otp_tree_test,
        falls_back_to_path_when_no_otp_tree_test,
        bundles_runfiles_relative_path_when_otp_tree_present_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":erlang_otp_tree_pure_tests",
            ":fails_when_erl_absent_test",
        ],
    )
