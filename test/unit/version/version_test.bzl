"""Unit tests for gleam/private/version.bzl's parse_version."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//gleam/private:version.bzl", "parse_version")

def _parses_simple_version_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 14, 0], parse_version("1.14.0"))
    return unittest.end(env)

parses_simple_version_test = unittest.make(_parses_simple_version_test_impl)

def _parses_single_component_version_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [2], parse_version("2"))
    return unittest.end(env)

parses_single_component_version_test = unittest.make(_parses_single_component_version_test_impl)

def _strips_prerelease_suffix_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [2, 0, 0], parse_version("2.0.0-rc1"))
    return unittest.end(env)

strips_prerelease_suffix_test = unittest.make(_strips_prerelease_suffix_test_impl)

def _sorts_numerically_not_lexically_test_impl(ctx):
    env = unittest.begin(ctx)
    versions = ["1.9.0", "1.14.0", "1.2.0"]

    # A lexical sort would put "1.9.0" first ("9" > "1" as characters); this is exactly the
    # class of bug that would make gleam.toolchain's "highest version wins" selection pick the
    # wrong one whenever a two-digit component is involved.
    highest = sorted(versions, key = parse_version, reverse = True)[0]
    asserts.equals(env, "1.14.0", highest)
    return unittest.end(env)

sorts_numerically_not_lexically_test = unittest.make(_sorts_numerically_not_lexically_test_impl)

def version_test_suite(name):
    unittest.suite(
        name,
        parses_simple_version_test,
        parses_single_component_version_test,
        strips_prerelease_suffix_test,
        sorts_numerically_not_lexically_test,
    )
