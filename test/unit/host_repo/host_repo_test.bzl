"""Unit tests for gleam/private/host_repo.bzl's host_platform.

host_platform only ever reads `.os.name`/`.os.arch` off whatever it's given, so a plain struct
stands in for a real repository_ctx without needing any Bazel machinery -- same trick
erlang_otp_tree_test.bzl uses for File objects via `_fake_file`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//gleam/private:host_repo.bzl", "host_platform")  # buildifier: disable=bzl-visibility

def _fake_repository_ctx(os_name, os_arch):
    return struct(os = struct(name = os_name, arch = os_arch))

def _resolves_linux_x86_64_test_impl(ctx):
    env = unittest.begin(ctx)
    ctx_fake = _fake_repository_ctx("linux", "x86_64")
    asserts.equals(env, "x86_64-unknown-linux-gnu", host_platform(ctx_fake))
    return unittest.end(env)

resolves_linux_x86_64_test = unittest.make(_resolves_linux_x86_64_test_impl)

def _resolves_linux_aarch64_test_impl(ctx):
    env = unittest.begin(ctx)
    ctx_fake = _fake_repository_ctx("linux", "aarch64")
    asserts.equals(env, "aarch64-unknown-linux-gnu", host_platform(ctx_fake))
    return unittest.end(env)

resolves_linux_aarch64_test = unittest.make(_resolves_linux_aarch64_test_impl)

def _resolves_macos_arm64_alternate_spelling_test_impl(ctx):
    env = unittest.begin(ctx)

    # Real macOS Bazel releases have been observed reporting "arm64" (not "aarch64") for
    # repository_ctx.os.arch -- the same alternate spelling
    # erlang/private/hermetic_erlang_repository.bzl normalizes; make sure host_platform accepts
    # it too rather than failing on an unrecognized arch string.
    ctx_fake = _fake_repository_ctx("mac os x", "arm64")
    asserts.equals(env, "aarch64-apple-darwin", host_platform(ctx_fake))
    return unittest.end(env)

resolves_macos_arm64_alternate_spelling_test = unittest.make(_resolves_macos_arm64_alternate_spelling_test_impl)

def _resolves_macos_x86_64_test_impl(ctx):
    env = unittest.begin(ctx)
    ctx_fake = _fake_repository_ctx("mac os x", "x86_64")
    asserts.equals(env, "x86_64-apple-darwin", host_platform(ctx_fake))
    return unittest.end(env)

resolves_macos_x86_64_test = unittest.make(_resolves_macos_x86_64_test_impl)

def _resolves_linux_amd64_alternate_spelling_test_impl(ctx):
    env = unittest.begin(ctx)

    # Same alternate-spelling concern as the arm64 test above, for the other pair: some
    # Bazel/OS combinations report "amd64" instead of "x86_64".
    ctx_fake = _fake_repository_ctx("linux", "amd64")
    asserts.equals(env, "x86_64-unknown-linux-gnu", host_platform(ctx_fake))
    return unittest.end(env)

resolves_linux_amd64_alternate_spelling_test = unittest.make(_resolves_linux_amd64_alternate_spelling_test_impl)

def _resolves_macos_amd64_alternate_spelling_test_impl(ctx):
    env = unittest.begin(ctx)
    ctx_fake = _fake_repository_ctx("mac os x", "amd64")
    asserts.equals(env, "x86_64-apple-darwin", host_platform(ctx_fake))
    return unittest.end(env)

resolves_macos_amd64_alternate_spelling_test = unittest.make(_resolves_macos_amd64_alternate_spelling_test_impl)

def _resolves_windows_regardless_of_arch_test_impl(ctx):
    env = unittest.begin(ctx)

    # Only one Windows platform is published (x86_64-pc-windows-msvc); windows should resolve to
    # it without even consulting os.arch.
    ctx_fake = _fake_repository_ctx("windows 10", "x86_64")
    asserts.equals(env, "x86_64-pc-windows-msvc", host_platform(ctx_fake))
    return unittest.end(env)

resolves_windows_regardless_of_arch_test = unittest.make(_resolves_windows_regardless_of_arch_test_impl)

def _fails_on_unsupported_arch_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "unsupported CPU architecture")
    return analysistest.end(env)

def _unsupported_arch_lookup_impl(_ctx):
    host_platform(_fake_repository_ctx("linux", "riscv64"))
    return [DefaultInfo()]

_unsupported_arch_lookup_rule = rule(implementation = _unsupported_arch_lookup_impl)

_fails_on_unsupported_arch_test = analysistest.make(_fails_on_unsupported_arch_test_impl, expect_failure = True)

def _fails_on_unsupported_os_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "unsupported host OS")
    return analysistest.end(env)

def _unsupported_os_lookup_impl(_ctx):
    host_platform(_fake_repository_ctx("plan9", "x86_64"))
    return [DefaultInfo()]

_unsupported_os_lookup_rule = rule(implementation = _unsupported_os_lookup_impl)

_fails_on_unsupported_os_test = analysistest.make(_fails_on_unsupported_os_test_impl, expect_failure = True)

def host_repo_test_suite(name):
    """Registers all host_repo unit tests as a single test_suite target.

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
        "host_repo_pure_tests",
        resolves_linux_x86_64_test,
        resolves_linux_aarch64_test,
        resolves_macos_arm64_alternate_spelling_test,
        resolves_macos_x86_64_test,
        resolves_linux_amd64_alternate_spelling_test,
        resolves_macos_amd64_alternate_spelling_test,
        resolves_windows_regardless_of_arch_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":host_repo_pure_tests",
            ":fails_on_unsupported_arch_test",
            ":fails_on_unsupported_os_test",
        ],
    )
