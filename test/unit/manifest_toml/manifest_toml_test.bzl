"""Unit tests for gleam/private/manifest_toml.bzl's parse_manifest_toml."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//gleam/private:manifest_toml.bzl", "parse_manifest_toml")  # buildifier: disable=bzl-visibility

_SAMPLE = """
packages = [
  { name = "gleam_stdlib", version = "0.60.0", build_tools = ["gleam"], requirements = [], otp_app = "gleam_stdlib", source = "hex", outer_checksum = "621D600BB134BC239CB2537630899817B1A42E60A1D46C5E9F3FAE39F88C800B" },
  { name = "gleeunit", version = "1.9.0", build_tools = ["gleam"], requirements = ["gleam_stdlib"], otp_app = "gleeunit", source = "hex", outer_checksum = "DA9553CE58B67924B3C631F96FE3370C49EB6D6DC6B384EC4862CC4AAA718F3C" },
  { name = "local_thing", version = "0.1.0", build_tools = ["gleam"], requirements = [], otp_app = "local_thing", source = "local" },
]
"""

def _parses_hex_package_test_impl(ctx):
    env = unittest.begin(ctx)
    packages = parse_manifest_toml(_SAMPLE)
    asserts.equals(env, 3, len(packages))

    stdlib = packages[0]
    asserts.equals(env, "gleam_stdlib", stdlib.name)
    asserts.equals(env, "0.60.0", stdlib.version)
    asserts.equals(env, "hex", stdlib.source)
    asserts.equals(env, "621d600bb134bc239cb2537630899817b1a42e60a1d46c5e9f3fae39f88c800b", stdlib.sha256)
    asserts.equals(env, [], stdlib.deps)
    return unittest.end(env)

parses_hex_package_test = unittest.make(_parses_hex_package_test_impl)

def _parses_requirements_as_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    packages = parse_manifest_toml(_SAMPLE)
    gleeunit = packages[1]
    asserts.equals(env, "gleeunit", gleeunit.name)
    asserts.equals(env, ["gleam_stdlib"], gleeunit.deps)
    return unittest.end(env)

parses_requirements_as_deps_test = unittest.make(_parses_requirements_as_deps_test_impl)

def _non_hex_source_has_empty_checksum_test_impl(ctx):
    env = unittest.begin(ctx)
    packages = parse_manifest_toml(_SAMPLE)
    local_pkg = packages[2]

    # extensions.bzl's caller is responsible for skipping non-"hex" packages; this function
    # just needs to parse whatever source is declared and not require a checksum for it.
    asserts.equals(env, "local", local_pkg.source)
    asserts.equals(env, "", local_pkg.sha256)
    return unittest.end(env)

non_hex_source_has_empty_checksum_test = unittest.make(_non_hex_source_has_empty_checksum_test_impl)

def _empty_manifest_parses_to_no_packages_test_impl(ctx):
    env = unittest.begin(ctx)
    packages = parse_manifest_toml("packages = [\n]\n")
    asserts.equals(env, 0, len(packages))
    return unittest.end(env)

empty_manifest_parses_to_no_packages_test = unittest.make(_empty_manifest_parses_to_no_packages_test_impl)

def manifest_toml_test_suite(name):
    unittest.suite(
        name,
        parses_hex_package_test,
        parses_requirements_as_deps_test,
        non_hex_source_has_empty_checksum_test,
        empty_manifest_parses_to_no_packages_test,
    )
