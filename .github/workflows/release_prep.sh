#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

TAG=${1:?Usage: release_prep.sh vVERSION}
ARCHIVE="rules_gleam-${TAG}.tar.gz"
PREFIX="rules_gleam-${TAG#v}"

# The reusable workflow uploads only after this script succeeds. Validate the exact
# version-stamped bytes, including the shipped BCR module and a fresh README consumer.
python3 .github/workflows/release_archive.py "$TAG" >&2
python3 .github/workflows/release_validate.py "$ARCHIVE" "$TAG" >&2
SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
BAZEL_VERSION=$(head -n 1 .bazelversion)

cat <<EOF_NOTES
## Installation (Bazel ${BAZEL_VERSION}, Bzlmod)

Add to \`MODULE.bazel\`. The alias matches the README's \`@rules_gleam\` loads.
The archive override works before this version is available in BCR; remove it once
BCR publishes the version. WORKSPACE setup is not supported.

\`\`\`starlark
bazel_dep(name = "muchq_rules_gleam", version = "${TAG#v}", repo_name = "rules_gleam")
archive_override(
    module_name = "muchq_rules_gleam",
    urls = ["https://github.com/muchq/rules_gleam/releases/download/${TAG}/${ARCHIVE}"],
    sha256 = "${SHA}",
    strip_prefix = "${PREFIX}",
)
\`\`\`

The source archive, shipped smoke module, and README quick start passed release validation.
See the README for compiler/runtime toolchain registration and supported platforms.
EOF_NOTES
