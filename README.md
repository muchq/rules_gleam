# Template for Bazel rules

Copy this template to create a Bazel ruleset.

Features:

- follows the official style guide at https://bazel.build/rules/deploying
- allows for both WORKSPACE.bazel and bzlmod (MODULE.bazel) usage
- includes Bazel formatting as a pre-commit hook (using [buildifier])
- includes stardoc API documentation generator
- includes typical toolchain setup
- CI configured with GitHub Actions
- release using GitHub Actions just by pushing a tag
- the release artifact doesn't need to be built by Bazel, but can still exclude files and stamp the version

Ready to get started? Copy this repo, then

1. search for "rules_gleam" and replace with the name you'll use for your workspace (if different, though `rules_gleam` is conventional)
2. search for "myorg" and replace with GitHub org (e.g., your GitHub username or organization)
3. rename directory "gleam" similarly if you changed the language name.
4. run `pre-commit install` to get lints (see CONTRIBUTING.md)
5. (optional) install the [Renovate app](https://github.com/apps/renovate) to get auto-PRs to keep the dependencies up-to-date.
6. delete this section of the README (everything up to the SNIP).

Optional: if you write tools for your rules to call, you should avoid toolchain dependencies for those tools leaking to all users.
For example, https://github.com/aspect-build/rules_py actions rely on a couple of binaries written in Rust, but we don't want users to be forced to
fetch a working Rust toolchain. Instead we want to ship pre-built binaries on our GH releases, and the ruleset fetches these as toolchains.
See https://blog.aspect.build/releasing-bazel-rulesets-rust for information on how to do this.
Note that users who _do_ want to build tools from source should still be able to do so, they just need to register a different toolchain earlier.

---- SNIP ----

# Bazel rules for Gleam

Bazel rules for building Gleam projects.

## Installation

### Bzlmod (Recommended)

Add the following to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_gleam", version = "0.0.0") # Replace 0.0.0 with the desired release version

gleam_ext = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
# Optional: Specify a Gleam version. Defaults to the version in rules_gleam.
# gleam_ext.toolchain(version = "1.10.0")
use_repo(
    gleam_ext,
    "local_config_erlang",
    "gleam_toolchain_linux_x86_64", # Or other platforms your project needs
    "gleam_toolchain_darwin_aarch64",
    # etc.
)

# The Erlang toolchain (from local system) and Gleam toolchains are registered automatically
# by rules_gleam. You may need to ensure an Erlang/OTP version compatible with your
# Gleam version is installed and discoverable on your system.
```

### WORKSPACE

Add the following to your `WORKSPACE.bazel` file:

```starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_gleam",
    sha256 = "<SHA256_OF_RELEASE_TARBALL>", # Obtain from the release page
    strip_prefix = "rules_gleam-<VERSION>", # e.g., rules_gleam-0.1.0
    url = "https://github.com/myorg/rules_gleam/releases/download/v<VERSION>/rules_gleam-v<VERSION>.tar.gz", # Replace myorg and VERSION
)

load("@rules_gleam//gleam:repositories.bzl", "rules_gleam_dependencies", "gleam_register_toolchains")

# Fetch transitive dependencies
rules_gleam_dependencies()

# Setup Gleam and Erlang toolchains
gleam_register_toolchains()

# Additional manual registration might be needed for WORKSPACE setup to ensure toolchains are active.
# Consult gleam/BUILD.bazel and erlang/private/local_erlang_repository.bzl for toolchain targets.
# Example (ensure these targets exist and are appropriate for your platforms):
# native.register_toolchains(
#     "@local_config_erlang//:erlang_toolchain_definition",
#     "//gleam:registration_linux_x86_64", # Or your host/target platform
#     # Add other platform registrations as needed
# )

```

To use a commit rather than a release, you can point at any SHA of the repo.

For example to use commit `abc123`:

1. Replace `url` with a GitHub-provided source archive like `url = "https://github.com/myorg/rules_gleam/archive/abc123.tar.gz"`
2. Replace `strip_prefix` with `strip_prefix = "rules_gleam-abc123"`
3. Update the `sha256`. The easiest way to do this is to comment out the line, then Bazel will
   print a message with the correct value. Note that GitHub source archives don't have a strong
   guarantee on the sha256 stability, see
   <https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes/>

## Usage

Load the rules in your `BUILD.bazel` files:

```starlark
load("@rules_gleam//gleam:defs.bzl", "gleam_library", "gleam_binary", "gleam_test")

gleam_library(
    name = "my_lib",
    srcs = glob(["src/**/*.gleam"]),
    package_name = "my_package_name", # Should match your gleam.toml
    gleam_toml = ":gleam.toml",
)

gleam_binary(
    name = "my_app",
    srcs = ["src/my_app.gleam"], # Assuming this contains your main function
    package_name = "my_package_name",
    deps = [":my_lib"],
    gleam_toml = ":gleam.toml",
)

gleam_test(
    name = "my_test",
    srcs = glob(["test/**/*.gleam"]),
    package_name = "my_package_name",
    deps = [":my_lib"], # Dependencies needed for the test
    gleam_toml = ":gleam.toml",
)
```

Replace `myorg` with the actual GitHub organization or username where this repository will live.
You'll also need to update the URLs and `strip_prefix` in the WORKSPACE installation instructions once you make a release.
