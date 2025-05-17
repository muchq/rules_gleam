"""Gleam tool versions and download information."""

# Default Gleam version to use if not specified by the user module.
# The SHA256 hashes are for this specific version.
# If this version is updated, the SHA256 hashes below MUST also be updated.
GLEAM_VERSION = "1.10.0"

TOOL_VERSIONS = {
    "1.10.0": {
        "x86_64-apple-darwin": "sha256-4xu7KCDd/i5+N4KdfCGKs1fg9u+0tD8sCtXCd/0O94c=",
        "aarch64-apple-darwin": "sha256-kNhxdQXxS5JYeUMuF3cIVQpd0pyaYg4IXyHwrXU8wZo=",
        "x86_64-unknown-linux-gnu": "sha256-bqlTCeOeOr9W/po2HdB51QK1qUT4YS2QnX9Wwv3BCnE=",
        "aarch64-unknown-linux-gnu": "sha256-FbUoV08x8CG/9yMsL7hRxobDacZ+lq7awEY2sECUrJQ=",
    },
}
