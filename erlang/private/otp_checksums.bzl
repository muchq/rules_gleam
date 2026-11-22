"""Verified checksums for the built-in hermetic Erlang/OTP release.

Keys are "<distro>_<arch>" for Linux (builds.hex.pm archives differ per distro/version) and
"macos_<arch>" for macOS. See docs/otp_checksums.md for how to add or verify a release.
"""

DEFAULT_OTP_VERSION = "28.1"
DEFAULT_OS_VERSION = "ubuntu-22.04"

# OTP version -> checksum key -> sha256. Each value matches both the publisher's own metadata
# (builds.hex.pm builds.txt, GitHub release asset digest) and a local hash of the download.
KNOWN_OTP_SHA256 = {
    "28.1": {
        "ubuntu-22.04_amd64": "60c1083df707642f20831c762a68db191984314fef1d4d80b05bb8caf70b70bf",
        "ubuntu-22.04_arm64": "75e38f5f04ee98edd8834a5cd084c214ba34705f709d157007f7656a5793b472",
        "macos_amd64": "821d8f2e039548b4343eadc7d25741e4d5b2280f429d14ded378f4de2067b83c",
        "macos_arm64": "831fcfb46929c752abf0a921409a46b306e7019061653323fab7f0958ad4db25",
    },
}
