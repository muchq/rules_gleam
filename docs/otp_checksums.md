# Erlang/OTP checksums

Every hermetic Erlang/OTP download is checked against a SHA-256. A fetch with no known
checksum fails; it never falls back to an unverified download unless you set
`allow_unverified_download = True`.

## Checksum keys

| Platform | Key | Archive |
|---|---|---|
| Linux | `<os_version>_<arch>`, e.g. `ubuntu-22.04_amd64` | `https://builds.hex.pm/builds/otp/<arch>/<os_version>/OTP-<version>.tar.gz` |
| macOS | `macos_<arch>`, e.g. `macos_arm64` | `https://github.com/erlef/otp_builds/releases/download/OTP-<version>/OTP-<version>-macos-<arch>.tar.gz` |

`<arch>` is `amd64` or `arm64`. Linux archives are built per distro, so the distro is part of the
key. A key like `linux_amd64` is rejected.

The built-in default release (`DEFAULT_OTP_VERSION` in
[erlang/private/otp_checksums.bzl](../erlang/private/otp_checksums.bzl)) has checksums for all
four platforms. For any other release or `os_version`, pass `sha256` to
`gleam.erlang_toolchain(...)` for each platform you build on; entries override the built-in ones.

## Finding and verifying a checksum

Take the checksum from the publisher, then confirm it against the bytes you download.

1. Publisher's checksum:
   - Linux: the fourth column of the `OTP-<version>` line in
     `https://builds.hex.pm/builds/otp/<arch>/<os_version>/builds.txt`.
   - macOS: the asset's `digest`, e.g.
     `gh api repos/erlef/otp_builds/releases/tags/OTP-<version> -q '.assets[] | "\(.name) \(.digest)"'`.
2. Local hash: `curl -fsSL <archive URL> | shasum -a 256`.
3. Use the value only if both match.

`allow_unverified_download = True` prints the observed digest, which is useful when bootstrapping a
release the publisher hasn't listed yet. That digest is only what one download returned; verify
it as above before pinning it, and remove the flag.

## Adding a built-in release

Add an entry to `KNOWN_OTP_SHA256` in `erlang/private/otp_checksums.bzl` with all four keys for
`DEFAULT_OS_VERSION`, each verified as above. When changing the default, update
`DEFAULT_OTP_VERSION`; `//test/unit/hermetic_erlang_repository` fails if any supported platform
is missing.
