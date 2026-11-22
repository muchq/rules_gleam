"""Unit tests for gleam/private/version.bzl's parse_version."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//gleam/private:version.bzl", "parse_version", "select_version")  # buildifier: disable=bzl-visibility

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

# select_version: gleam.toolchain registrations from several modules.

def _same_version_from_two_modules_is_not_a_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_version(["1.17.0", "1.17.0"])
    asserts.equals(env, struct(selected = "1.17.0", distinct = ["1.17.0"]), selection, "select_version([1.17.0, 1.17.0])")
    return unittest.end(env)

same_version_from_two_modules_is_not_a_conflict_test = unittest.make(_same_version_from_two_modules_is_not_a_conflict_test_impl)

def _different_versions_pick_highest_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_version(["1.9.0", "1.17.0", "1.9.0"])
    asserts.equals(env, struct(selected = "1.17.0", distinct = ["1.17.0", "1.9.0"]), selection, "select_version([1.9.0, 1.17.0, 1.9.0])")
    return unittest.end(env)

different_versions_pick_highest_test = unittest.make(_different_versions_pick_highest_test_impl)

def _single_version_is_selected_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_version(["1.17.0"])
    asserts.equals(env, struct(selected = "1.17.0", distinct = ["1.17.0"]), selection, "select_version([1.17.0])")
    return unittest.end(env)

single_version_is_selected_test = unittest.make(_single_version_is_selected_test_impl)

def version_test_suite(name):
    unittest.suite(
        name,
        parses_simple_version_test,
        parses_single_component_version_test,
        strips_prerelease_suffix_test,
        sorts_numerically_not_lexically_test,
        single_version_is_selected_test,
        same_version_from_two_modules_is_not_a_conflict_test,
        different_versions_pick_highest_test,
    )
