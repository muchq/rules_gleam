"""Repository rule that downloads a prebuilt Erlang/OTP release instead of relying on PATH.

This is an opt-in alternative to `local_erlang_repository`: instead of discovering whatever
Erlang/OTP happens to be installed on the host, it fetches a specific prebuilt OTP release
from the same origins used by the widely-trusted `erlef/setup-beam` GitHub Action:

  - Linux: https://builds.hex.pm/builds/otp/<arch>/<os_version>/OTP-<otp_version>.tar.gz
    (glibc-linked, tied to a specific distro/version tag such as "ubuntu-22.04" -- there is
    no portable musl-static build available from this origin).
  - macOS: https://github.com/erlef/otp_builds/releases/download/OTP-<otp_version>/OTP-<otp_version>-macos-<arch>.tar.gz

Windows is not supported (matching this project's existing lack of Windows support).

Checksums are opt-in per platform via the `sha256` dict. When a platform's checksum is
missing, the download proceeds unverified and the actual computed checksum is printed so it
can be pinned in a follow-up change -- mirroring how `bazel_dep`/`http_archive` checksums are
normally discovered on first use.
"""

_LINUX_ARCH = {
    "aarch64": "arm64",
    "arm64": "arm64",
    "x86_64": "amd64",
    "amd64": "amd64",
}

_MACOS_ARCH = {
    "aarch64": "aarch64",
    "arm64": "aarch64",
    "x86_64": "x86_64",
    "amd64": "x86_64",
}

def _sha256_key(os_key, arch):
    return "{}_{}".format(os_key, arch)

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
    sha256_map = repository_ctx.attr.sha256

    os_name = repository_ctx.os.name.lower()
    arch = repository_ctx.os.arch

    if "linux" in os_name:
        os_key = "linux"
        linux_arch = _LINUX_ARCH.get(arch)
        if not linux_arch:
            fail("Unsupported CPU architecture for hermetic Erlang/OTP on Linux: {}".format(arch))
        os_constraint = "@platforms//os:linux"
        cpu_constraint = "@platforms//cpu:arm64" if linux_arch == "arm64" else "@platforms//cpu:x86_64"

        url = "https://builds.hex.pm/builds/otp/{arch}/{os_version}/{tag}.tar.gz".format(
            arch = linux_arch,
            os_version = repository_ctx.attr.os_version,
            tag = otp_tag,
        )
        checksum_key = _sha256_key(os_key, linux_arch)
        expected_sha256 = sha256_map.get(checksum_key, "")

        download = repository_ctx.download(
            url = url,
            output = "otp.tar.gz",
            sha256 = expected_sha256,
        )
        if not expected_sha256:
            # buildifier: disable=print
            print((
                "NOTE: no sha256 pinned for hermetic Erlang/OTP {tag} on {key}. Downloaded " +
                "unverified. Pin it by adding sha256 = {{\"{key}\": \"{digest}\"}} to the " +
                "gleam.erlang_toolchain(...) call."
            ).format(tag = otp_tag, key = checksum_key, digest = download.sha256))

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

    elif "mac os" in os_name:
        os_key = "macos"
        macos_arch = _MACOS_ARCH.get(arch)
        if not macos_arch:
            fail("Unsupported CPU architecture for hermetic Erlang/OTP on macOS: {}".format(arch))
        os_constraint = "@platforms//os:osx"
        cpu_constraint = "@platforms//cpu:arm64" if macos_arch == "aarch64" else "@platforms//cpu:x86_64"

        url = "https://github.com/erlef/otp_builds/releases/download/{tag}/{tag}-macos-{arch}.tar.gz".format(
            tag = otp_tag,
            arch = macos_arch,
        )
        checksum_key = _sha256_key(os_key, macos_arch)
        expected_sha256 = sha256_map.get(checksum_key, "")

        download = repository_ctx.download(
            url = url,
            output = "otp.tar.gz",
            sha256 = expected_sha256,
        )
        if not expected_sha256:
            # buildifier: disable=print
            print((
                "NOTE: no sha256 pinned for hermetic Erlang/OTP {tag} on {key}. Downloaded " +
                "unverified. Pin it by adding sha256 = {{\"{key}\": \"{digest}\"}} to the " +
                "gleam.erlang_toolchain(...) call."
            ).format(tag = otp_tag, key = checksum_key, digest = download.sha256))

        repository_ctx.execute(["mkdir", "-p", "otp"])
        extract_result = repository_ctx.execute(["tar", "-xzf", "otp.tar.gz", "-C", "otp"])
        if extract_result.return_code != 0:
            fail("Failed to extract Erlang/OTP archive: " + extract_result.stderr)
        repository_ctx.delete("otp.tar.gz")

        otp_root = repository_ctx.path("otp")

    else:
        fail("Hermetic Erlang/OTP toolchain does not support OS: {}".format(repository_ctx.os.name))

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

erlang_toolchain_config(
    name = "local_config",
    escript_path = "{escript_path}",
    erl_path = "{erl_path}",
    erlc_path = "{erlc_path}",
    erts_include_path = "{erts_include_path}",
    erl_libs_path = "{erl_libs_path}",
    erlang_version = "{erlang_version}",
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
            doc = "Optional map from \"<os>_<arch>\" (e.g. \"linux_amd64\", \"linux_arm64\", \"macos_x86_64\", \"macos_aarch64\") to the expected sha256 of that platform's OTP tarball. Platforms without an entry are downloaded unverified, printing the observed checksum so it can be pinned.",
            default = {},
        ),
    },
    doc = "Downloads a prebuilt Erlang/OTP release and configures a hermetic toolchain from it.",
)
