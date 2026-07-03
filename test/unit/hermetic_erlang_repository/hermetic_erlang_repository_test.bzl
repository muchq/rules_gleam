"""Unit tests for erlang/private/hermetic_erlang_repository.bzl's resolve_host.

resolve_host only ever reads `.os.name`/`.os.arch` off whatever it's given, so a plain struct
stands in for a real repository_ctx without needing any Bazel machinery or a network download --
same trick test/unit/host_repo/host_repo_test.bzl uses for gleam_host's own, separate
os/arch-mapping table.

This table is exactly where the original macOS hermetic-Erlang arch-naming bug lived (a real
production bug found via a real CI failure, not caught by any test, since none existed for this
file) -- these tests exist so a repeat of that class of mistake fails fast and locally instead.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//erlang/private:hermetic_erlang_repository.bzl", "resolve_host")  # buildifier: disable=bzl-visibility

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
    )
    native.test_suite(
        name = name,
        tests = [
            ":hermetic_erlang_repository_pure_tests",
            ":fails_on_unsupported_arch_test",
            ":fails_on_unsupported_os_test",
        ],
    )
