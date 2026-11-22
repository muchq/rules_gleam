"""Unit tests for erlang/private/hermetic_erlang_repository.bzl's host and checksum helpers.

resolve_host only ever reads `.os.name`/`.os.arch` off whatever it's given, so a plain struct
stands in for a real repository_ctx without needing any Bazel machinery or a network download --
same trick test/unit/host_repo/host_repo_test.bzl uses for gleam_host's own, separate
os/arch-mapping table.

This table is exactly where the original macOS hermetic-Erlang arch-naming bug lived (a real
production bug found via a real CI failure, not caught by any test, since none existed for this
file) -- these tests exist so a repeat of that class of mistake fails fast and locally instead.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//erlang/private:hermetic_erlang_repository.bzl", "checksum_key", "expected_sha256", "resolve_host")  # buildifier: disable=bzl-visibility
load("//erlang/private:otp_checksums.bzl", "DEFAULT_OS_VERSION", "DEFAULT_OTP_VERSION", "KNOWN_OTP_SHA256")  # buildifier: disable=bzl-visibility

def _fake_repository_ctx(os_name, os_arch):
    return struct(os = struct(name = os_name, arch = os_arch))

def _resolves_linux_x86_64_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("linux", "x86_64"))
    asserts.equals(env, "linux", host.os_key)
    asserts.equals(env, "amd64", host.arch)
    asserts.equals(env, "@platforms//os:linux", host.os_constraint)
    asserts.equals(env, "@platforms//cpu:x86_64", host.cpu_constraint)
    return unittest.end(env)

resolves_linux_x86_64_test = unittest.make(_resolves_linux_x86_64_test_impl)

def _resolves_linux_amd64_spelling_test_impl(ctx):
    env = unittest.begin(ctx)

    # "amd64" is the same value os.arch reports as "x86_64" is normalized to -- confirm the
    # already-normalized spelling is also accepted (idempotent), not just the raw one.
    host = resolve_host(_fake_repository_ctx("linux", "amd64"))
    asserts.equals(env, "amd64", host.arch)
    asserts.equals(env, "@platforms//cpu:x86_64", host.cpu_constraint)
    return unittest.end(env)

resolves_linux_amd64_spelling_test = unittest.make(_resolves_linux_amd64_spelling_test_impl)

def _resolves_linux_aarch64_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("linux", "aarch64"))
    asserts.equals(env, "linux", host.os_key)
    asserts.equals(env, "arm64", host.arch)
    asserts.equals(env, "@platforms//cpu:arm64", host.cpu_constraint)
    return unittest.end(env)

resolves_linux_aarch64_test = unittest.make(_resolves_linux_aarch64_test_impl)

def _resolves_linux_arm64_spelling_test_impl(ctx):
    env = unittest.begin(ctx)

    # Real Bazel/OS combinations have been observed reporting "arm64" (not "aarch64") for
    # repository_ctx.os.arch on Linux too -- confirm both spellings normalize the same way.
    host = resolve_host(_fake_repository_ctx("linux", "arm64"))
    asserts.equals(env, "arm64", host.arch)
    asserts.equals(env, "@platforms//cpu:arm64", host.cpu_constraint)
    return unittest.end(env)

resolves_linux_arm64_spelling_test = unittest.make(_resolves_linux_arm64_spelling_test_impl)

def _resolves_macos_x86_64_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("mac os x", "x86_64"))
    asserts.equals(env, "macos", host.os_key)
    asserts.equals(env, "amd64", host.arch)
    asserts.equals(env, "@platforms//os:osx", host.os_constraint)
    asserts.equals(env, "@platforms//cpu:x86_64", host.cpu_constraint)
    return unittest.end(env)

resolves_macos_x86_64_test = unittest.make(_resolves_macos_x86_64_test_impl)

def _resolves_macos_amd64_spelling_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("mac os x", "amd64"))
    asserts.equals(env, "amd64", host.arch)
    asserts.equals(env, "@platforms//cpu:x86_64", host.cpu_constraint)
    return unittest.end(env)

resolves_macos_amd64_spelling_test = unittest.make(_resolves_macos_amd64_spelling_test_impl)

def _resolves_macos_aarch64_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("mac os x", "aarch64"))
    asserts.equals(env, "macos", host.os_key)
    asserts.equals(env, "arm64", host.arch)
    asserts.equals(env, "@platforms//cpu:arm64", host.cpu_constraint)
    return unittest.end(env)

resolves_macos_aarch64_test = unittest.make(_resolves_macos_aarch64_test_impl)

def _resolves_macos_arm64_spelling_test_impl(ctx):
    env = unittest.begin(ctx)

    # This is the exact spelling real macOS (Apple Silicon) Bazel runners report for
    # repository_ctx.os.arch -- the original production bug this whole test file exists to
    # prevent a repeat of was this normalization being missing/wrong for exactly this case.
    host = resolve_host(_fake_repository_ctx("mac os x", "arm64"))
    asserts.equals(env, "arm64", host.arch)
    asserts.equals(env, "@platforms//cpu:arm64", host.cpu_constraint)
    return unittest.end(env)

resolves_macos_arm64_spelling_test = unittest.make(_resolves_macos_arm64_spelling_test_impl)

def _fails_on_unsupported_arch_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Unsupported CPU architecture")
    return analysistest.end(env)

def _unsupported_arch_lookup_impl(_ctx):
    resolve_host(_fake_repository_ctx("linux", "riscv64"))
    return [DefaultInfo()]

_unsupported_arch_lookup_rule = rule(implementation = _unsupported_arch_lookup_impl)

_fails_on_unsupported_arch_test = analysistest.make(_fails_on_unsupported_arch_test_impl, expect_failure = True)

def _fails_on_unsupported_os_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "does not support OS")
    return analysistest.end(env)

def _unsupported_os_lookup_impl(_ctx):
    resolve_host(_fake_repository_ctx("plan9", "x86_64"))
    return [DefaultInfo()]

_unsupported_os_lookup_rule = rule(implementation = _unsupported_os_lookup_impl)

_fails_on_unsupported_os_test = analysistest.make(_fails_on_unsupported_os_test_impl, expect_failure = True)

# Checksum identity and lookup.

_SUPPORTED_HOSTS = [
    ("linux", "x86_64"),
    ("linux", "aarch64"),
    ("mac os x", "x86_64"),
    ("mac os x", "arm64"),
]

_DIGEST = "a" * 64

def _linux_checksum_key_includes_distro_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("linux", "x86_64"))
    asserts.equals(env, "ubuntu-22.04_amd64", checksum_key(host, "ubuntu-22.04"))
    asserts.equals(env, "ubuntu-24.04_amd64", checksum_key(host, "ubuntu-24.04"))
    return unittest.end(env)

linux_checksum_key_includes_distro_test = unittest.make(_linux_checksum_key_includes_distro_test_impl)

def _macos_checksum_key_ignores_os_version_test_impl(ctx):
    env = unittest.begin(ctx)
    host = resolve_host(_fake_repository_ctx("mac os x", "arm64"))
    asserts.equals(env, "macos_arm64", checksum_key(host, "ubuntu-22.04"))
    asserts.equals(env, "macos_arm64", checksum_key(host, "ubuntu-24.04"))
    return unittest.end(env)

macos_checksum_key_ignores_os_version_test = unittest.make(_macos_checksum_key_ignores_os_version_test_impl)

def _returns_pinned_checksum_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = {"ubuntu-22.04_amd64": _DIGEST}
    asserts.equals(env, _DIGEST, expected_sha256(pins, "ubuntu-22.04_amd64", "28.1", "ubuntu-22.04", False))
    asserts.equals(env, _DIGEST, expected_sha256(pins, "ubuntu-22.04_amd64", "28.1", "ubuntu-22.04", True))
    return unittest.end(env)

returns_pinned_checksum_test = unittest.make(_returns_pinned_checksum_test_impl)

def _unverified_download_requires_opt_in_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", expected_sha256({}, "ubuntu-22.04_amd64", "99.0", "ubuntu-22.04", True))
    return unittest.end(env)

unverified_download_requires_opt_in_test = unittest.make(_unverified_download_requires_opt_in_test_impl)

def _default_release_pins_every_supported_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = KNOWN_OTP_SHA256[DEFAULT_OTP_VERSION]
    expected_keys = []
    for os_name, arch in _SUPPORTED_HOSTS:
        key = checksum_key(resolve_host(_fake_repository_ctx(os_name, arch)), DEFAULT_OS_VERSION)
        expected_keys.append(key)
        digest = pins.get(key, "")
        asserts.equals(env, 64, len(digest), "length of sha256 for '{}'".format(key))
        asserts.equals(env, digest.lower(), digest, "sha256 for '{}' is lowercase".format(key))
    asserts.equals(env, sorted(expected_keys), sorted(pins.keys()))
    return unittest.end(env)

default_release_pins_every_supported_platform_test = unittest.make(_default_release_pins_every_supported_platform_test_impl)

def _fails_on_missing_checksum_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "No sha256 is known for Erlang/OTP 99.0 on \"ubuntu-22.04_arm64\"")
    return analysistest.end(env)

def _missing_checksum_lookup_impl(_ctx):
    expected_sha256({"ubuntu-22.04_amd64": _DIGEST}, "ubuntu-22.04_arm64", "99.0", "ubuntu-22.04", False)
    return [DefaultInfo()]

_missing_checksum_lookup_rule = rule(implementation = _missing_checksum_lookup_impl)

_fails_on_missing_checksum_test = analysistest.make(_fails_on_missing_checksum_test_impl, expect_failure = True)

def _fails_on_legacy_linux_key_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "sha256 key \"linux_amd64\" does not identify a Linux distribution; Linux archives differ per distro, so use \"ubuntu-24.04_amd64\" instead.")
    return analysistest.end(env)

def _legacy_linux_key_lookup_impl(_ctx):
    expected_sha256({"linux_amd64": _DIGEST}, "ubuntu-24.04_amd64", "28.1", "ubuntu-24.04", True)
    return [DefaultInfo()]

_legacy_linux_key_lookup_rule = rule(implementation = _legacy_linux_key_lookup_impl)

_fails_on_legacy_linux_key_test = analysistest.make(_fails_on_legacy_linux_key_test_impl, expect_failure = True)

def hermetic_erlang_repository_test_suite(name):
    """Registers all hermetic_erlang_repository unit tests as a single test_suite target.

    Args:
        name: name of the generated test_suite.
    """
    _unsupported_arch_lookup_rule(name = "unsupported_arch_lookup", tags = ["manual"])
    _fails_on_unsupported_arch_test(
        name = "fails_on_unsupported_arch_test",
        target_under_test = ":unsupported_arch_lookup",
    )
    _unsupported_os_lookup_rule(name = "unsupported_os_lookup", tags = ["manual"])
    _fails_on_unsupported_os_test(
        name = "fails_on_unsupported_os_test",
        target_under_test = ":unsupported_os_lookup",
    )
    _missing_checksum_lookup_rule(name = "missing_checksum_lookup", tags = ["manual"])
    _fails_on_missing_checksum_test(
        name = "fails_on_missing_checksum_test",
        target_under_test = ":missing_checksum_lookup",
    )
    _legacy_linux_key_lookup_rule(name = "legacy_linux_key_lookup", tags = ["manual"])
    _fails_on_legacy_linux_key_test(
        name = "fails_on_legacy_linux_key_test",
        target_under_test = ":legacy_linux_key_lookup",
    )
    unittest.suite(
        "hermetic_erlang_repository_pure_tests",
        resolves_linux_x86_64_test,
        resolves_linux_amd64_spelling_test,
        resolves_linux_aarch64_test,
        resolves_linux_arm64_spelling_test,
        resolves_macos_x86_64_test,
        resolves_macos_amd64_spelling_test,
        resolves_macos_aarch64_test,
        resolves_macos_arm64_spelling_test,
        linux_checksum_key_includes_distro_test,
        macos_checksum_key_ignores_os_version_test,
        returns_pinned_checksum_test,
        unverified_download_requires_opt_in_test,
        default_release_pins_every_supported_platform_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":hermetic_erlang_repository_pure_tests",
            ":fails_on_unsupported_arch_test",
            ":fails_on_unsupported_os_test",
            ":fails_on_missing_checksum_test",
            ":fails_on_legacy_linux_key_test",
        ],
    )
