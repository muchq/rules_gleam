"""Repository rule that downloads a prebuilt Erlang/OTP release instead of relying on PATH.

This is an opt-in alternative to `local_erlang_repository`: instead of discovering whatever
Erlang/OTP happens to be installed on the host, it fetches a specific prebuilt OTP release
from the same origins used by the widely-trusted `erlef/setup-beam` GitHub Action:

  - Linux: https://builds.hex.pm/builds/otp/<arch>/<os_version>/OTP-<otp_version>.tar.gz
    (glibc-linked, tied to a specific distro/version tag such as "ubuntu-22.04" -- there is
    no portable musl-static build available from this origin).
  - macOS: https://github.com/erlef/otp_builds/releases/download/OTP-<otp_version>/OTP-<otp_version>-macos-<arch>.tar.gz

Windows is not supported (matching this project's existing lack of Windows support).

Every download is verified. Checksums come from the built-in table in otp_checksums.bzl,
overridden or extended by the `sha256` dict; a missing checksum fails unless
`allow_unverified_download` is set. See docs/otp_checksums.md.
"""

load(":otp_checksums.bzl", "KNOWN_OTP_SHA256")

# erlef's build origins (builds.hex.pm for Linux, erlef/otp_builds releases for macOS) both
# name their assets/paths using this same "arm64"/"amd64" convention, regardless of which raw
# arch string repository_ctx.os.arch happens to report (e.g. "aarch64" on real macOS runners).
_ARCH = {
    "aarch64": "arm64",
    "arm64": "arm64",
    "x86_64": "amd64",
    "amd64": "amd64",
}

def checksum_key(host, os_version):
    """Returns the sha256 dict key identifying one downloadable OTP archive.

    Linux archives from builds.hex.pm are distinct per distro/version, so the distro is part
    of the key ("ubuntu-22.04_amd64"); macOS archives are not ("macos_arm64").

    Args:
        host: a struct from resolve_host.
        os_version: the Linux distro/version tag, e.g. "ubuntu-22.04". Ignored on macOS.

    Returns:
        The key string.
    """
    if host.os_key == "linux":
        return "{}_{}".format(os_version, host.arch)
    return "{}_{}".format(host.os_key, host.arch)

def expected_sha256(sha256_map, key, otp_version, os_version, allow_unverified_download):
    """Looks up the checksum an OTP download must match, failing closed when there is none.

    Args:
        sha256_map: built-in checksums merged with the user's sha256 dict.
        key: the archive's key from checksum_key.
        otp_version: the OTP release, for error messages.
        os_version: the Linux distro/version tag, for error messages.
        allow_unverified_download: explicit opt-in to download without a checksum.

    Returns:
        The expected sha256, or "" when unverified downloads were explicitly allowed.
    """
    for legacy in sorted(sha256_map.keys()):
        if legacy.startswith("linux_"):
            fail((
                "sha256 key \"{legacy}\" does not identify a Linux distribution; Linux " +
                "archives differ per distro, so use \"{os_version}_{arch}\" instead."
            ).format(legacy = legacy, os_version = os_version, arch = legacy[len("linux_"):]))

    expected = sha256_map.get(key, "")
    if not expected and not allow_unverified_download:
        fail((
            "No sha256 is known for Erlang/OTP {version} on \"{key}\". Add " +
            "sha256 = {{\"{key}\": \"<sha256>\"}} to gleam.erlang_toolchain(...); " +
            "docs/otp_checksums.md lists where upstream publishes it. Set " +
            "allow_unverified_download = True only to bootstrap a new release."
        ).format(version = otp_version, key = key))
    return expected

def resolve_host(repository_ctx):
    """Determine the OS/arch/platform-constraint quadruple for a repository_ctx's host.

    Pulled out of _hermetic_erlang_repository_impl so it can be unit-tested (test/unit/
    hermetic_erlang_repository) against plain fake structs, without needing a real
    repository_ctx or a network download -- the same trick host_repo.bzl's host_platform uses.

    Args:
        repository_ctx: a repository_ctx, or any struct exposing the same `.os.name`/`.os.arch`
            fields (e.g. a fake used by tests).

    Returns:
        A struct with fields:
          os_key: "linux" or "macos" (used to key the sha256 dict and pick a download URL shape)
          arch: "arm64" or "amd64" (erlef's origin-naming convention, not necessarily
              repository_ctx.os.arch's raw spelling)
          os_constraint: a "@platforms//os:..." label for the toolchain() definition
          cpu_constraint: a "@platforms//cpu:..." label for the toolchain() definition
    """
    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch

    if "linux" in os_name:
        os_key = "linux"
        os_label = "Linux"
        os_constraint = "@platforms//os:linux"
    elif "mac os" in os_name:
        os_key = "macos"
        os_label = "macOS"
        os_constraint = "@platforms//os:osx"
    else:
        fail("Hermetic Erlang/OTP toolchain does not support OS: {}".format(repository_ctx.os.name))

    normalized_arch = _ARCH.get(arch)
    if not normalized_arch:
        fail("Unsupported CPU architecture for hermetic Erlang/OTP on {}: {}".format(os_label, arch))

    cpu_constraint = "@platforms//cpu:arm64" if normalized_arch == "arm64" else "@platforms//cpu:x86_64"

    return struct(
        os_key = os_key,
        arch = normalized_arch,
        os_constraint = os_constraint,
        cpu_constraint = cpu_constraint,
    )

def _find_executable(repository_ctx, root, name):
    result = repository_ctx.execute(["find", str(root), "-type", "f", "-name", name, "-path", "*/bin/" + name])
    lines = [line for line in result.stdout.strip().split("\n") if line]
    if result.return_code != 0 or not lines:
        fail((
            "Could not locate '{name}' inside the extracted Erlang/OTP archive under {root}. " +
            "The archive layout may not match what this rule expects -- please file an issue " +
            "with the otp_version/os you used."
        ).format(name = name, root = root))
    return lines[0]

def _hermetic_erlang_repository_impl(repository_ctx):
    otp_version = repository_ctx.attr.otp_version
    otp_tag = "OTP-" + otp_version
    sha256_map = dict(KNOWN_OTP_SHA256.get(otp_version, {}))
    sha256_map.update(repository_ctx.attr.sha256)

    host = resolve_host(repository_ctx)
    os_key = host.os_key
    arch = host.arch
    os_constraint = host.os_constraint
    cpu_constraint = host.cpu_constraint

    os_version = repository_ctx.attr.os_version
    key = checksum_key(host, os_version)
    sha256 = expected_sha256(sha256_map, key, otp_version, os_version, repository_ctx.attr.allow_unverified_download)

    if os_key == "linux":
        url = "https://builds.hex.pm/builds/otp/{arch}/{os_version}/{tag}.tar.gz".format(
            arch = arch,
            os_version = os_version,
            tag = otp_tag,
        )
    else:  # os_key == "macos"
        url = "https://github.com/erlef/otp_builds/releases/download/{tag}/{tag}-macos-{arch}.tar.gz".format(
            tag = otp_tag,
            arch = arch,
        )

    download = repository_ctx.download(url = url, output = "otp.tar.gz", sha256 = sha256)
    if not sha256:
        # buildifier: disable=print
        print((
            "WARNING: downloaded Erlang/OTP {tag} for \"{key}\" WITHOUT verification " +
            "(allow_unverified_download = True). Observed sha256 {digest}; confirm it against " +
            "the publisher's checksum before pinning it (docs/otp_checksums.md)."
        ).format(tag = otp_tag, key = key, digest = download.sha256))

    if os_key == "linux":
        repository_ctx.execute(["mkdir", "-p", "otp"])
        extract_result = repository_ctx.execute([
            "tar",
            "-xzf",
            "otp.tar.gz",
            "-C",
            "otp",
            "--strip-components=1",
        ])
        if extract_result.return_code != 0:
            fail("Failed to extract Erlang/OTP archive: " + extract_result.stderr)
        repository_ctx.delete("otp.tar.gz")

        otp_root = repository_ctx.path("otp")
        install_script = str(otp_root) + "/Install"
        install_result = repository_ctx.execute([install_script, "-minimal", str(otp_root)])
        if install_result.return_code != 0:
            fail("Erlang/OTP 'Install -minimal' script failed: " + install_result.stderr)

    else:
        repository_ctx.execute(["mkdir", "-p", "otp"])
        extract_result = repository_ctx.execute(["tar", "-xzf", "otp.tar.gz", "-C", "otp"])
        if extract_result.return_code != 0:
            fail("Failed to extract Erlang/OTP archive: " + extract_result.stderr)
        repository_ctx.delete("otp.tar.gz")

        otp_root = repository_ctx.path("otp")

    erl_path = _find_executable(repository_ctx, otp_root, "erl")
    erlc_path = _find_executable(repository_ctx, otp_root, "erlc")
    escript_path = _find_executable(repository_ctx, otp_root, "escript")
    erl_bin_dir = "/".join(erl_path.split("/")[:-1])
    erlang_root = "/".join(erl_bin_dir.split("/")[:-1])

    erts_include_path = "{}/usr/include".format(erlang_root)
    if not repository_ctx.path(erts_include_path).exists:
        erts_include_path = "{}/lib/erlang/usr/include".format(erlang_root)

    erl_libs_path = "{}/lib".format(erlang_root)
    if not repository_ctx.path(erl_libs_path).exists:
        erl_libs_path = erlang_root

    version_result = repository_ctx.execute([erl_path, "-eval", 'io:format("~s", [erlang:system_info(otp_release)]), halt().', "-noshell"])
    erlang_version = version_result.stdout.strip() if version_result.return_code == 0 else otp_version

    build_content = """\
load("@muchq_rules_gleam//erlang/private:erlang_toolchain_config.bzl", "erlang_toolchain_config")
load("@muchq_rules_gleam//erlang/private:erlang_toolchain.bzl", "erlang_toolchain")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "otp_tree",
    srcs = glob(["otp/**"]),
)

erlang_toolchain_config(
    name = "local_config",
    escript_path = "{escript_path}",
    erl_path = "{erl_path}",
    erlc_path = "{erlc_path}",
    erts_include_path = "{erts_include_path}",
    erl_libs_path = "{erl_libs_path}",
    erlang_version = "{erlang_version}",
    otp_tree = ":otp_tree",
)

erlang_toolchain(
    name = "local_toolchain",
    toolchain_config = ":local_config",
)

toolchain(
    name = "erlang_toolchain_definition",
    toolchain_type = "@muchq_rules_gleam//erlang:erlang_toolchain_type",
    exec_compatible_with = [
        "{os_constraint}",
        "{cpu_constraint}",
    ],
    target_compatible_with = [
        "{os_constraint}",
        "{cpu_constraint}",
    ],
    toolchain = ":local_toolchain",
)
""".format(
        escript_path = escript_path,
        erl_path = erl_path,
        erlc_path = erlc_path,
        erts_include_path = erts_include_path,
        erl_libs_path = erl_libs_path,
        erlang_version = erlang_version,
        os_constraint = os_constraint,
        cpu_constraint = cpu_constraint,
    )

    repository_ctx.file("BUILD.bazel", build_content)

hermetic_erlang_repository = repository_rule(
    implementation = _hermetic_erlang_repository_impl,
    attrs = {
        "otp_version": attr.string(
            doc = "Exact Erlang/OTP release to fetch (e.g. \"27.1.2\"), matching an upstream OTP-<version> release tag.",
            mandatory = True,
        ),
        "os_version": attr.string(
            doc = "Linux distro/version tag used to select the prebuilt OTP archive from builds.hex.pm (e.g. \"ubuntu-22.04\"). Ignored on macOS.",
            default = "ubuntu-22.04",
        ),
        "sha256": attr.string_dict(
            doc = "Map from \"<distro>_<arch>\" (Linux, e.g. \"ubuntu-22.04_amd64\") or \"macos_<arch>\" to the expected sha256 of that OTP tarball. Entries override the built-in checksums in otp_checksums.bzl.",
            default = {},
        ),
        "allow_unverified_download": attr.bool(
            doc = "Insecure: download without a checksum when none is known, printing the observed digest. Only for bootstrapping a new release.",
            default = False,
        ),
    },
    doc = "Downloads a prebuilt Erlang/OTP release and configures a hermetic toolchain from it.",
)
