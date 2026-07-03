"""Bazel module extension for Gleam.

This extension handles:
1. Gleam compiler toolchain registration (downloads gleam binary per platform).
2. Local Erlang detection (finds system-installed Erlang/OTP).
3. Hex package management (downloads and exposes 3p Gleam packages from hex.pm).

Usage in MODULE.bazel:
```starlark
gleam = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
gleam.toolchain(version = "1.14.0")
gleam.hex_package(name = "gleam_stdlib", version = "0.60.0", sha256 = "...", deps = [])
gleam.hex_package(name = "gleeunit", version = "1.0.2", sha256 = "...", deps = ["gleam_stdlib"])
use_repo(gleam, "gleam_toolchains", "local_config_erlang", "gleam_packages")
```
"""

load("//erlang/private:local_erlang_repository.bzl", "local_erlang_repository")  # buildifier: disable=bzl-visibility
load(":repositories.bzl", "gleam_register_toolchains")

_DEFAULT_NAME = "gleam"

gleam_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one gleam toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "version": attr.string(doc = "Explicit version of gleam.", mandatory = True),
    "erlang_version": attr.string(doc = """\
Optional exact Erlang/OTP release to require (e.g. "26"), checked against
erlang:system_info(otp_release) on the host Erlang found on PATH. The Erlang toolchain is not
yet hermetic (see erlang/private/local_erlang_repository.bzl), so this does not pin the actual
bytes used to build -- it only turns a silent cross-machine reproducibility gap into a loud,
actionable failure when the host's Erlang/OTP does not match what you expect. Leave unset to
accept whatever Erlang/OTP release is found.
""", default = ""),
})

hex_package = tag_class(attrs = {
    "name": attr.string(doc = "Hex package name (e.g. 'gleam_stdlib').", mandatory = True),
    "version": attr.string(doc = "Exact package version (e.g. '0.60.0').", mandatory = True),
    "sha256": attr.string(doc = "SHA-256 checksum of the Hex tarball (outer_checksum from manifest.toml, found after running `gleam deps download`). Required: an empty checksum means Bazel cannot verify the downloaded tarball hasn't been tampered with or changed upstream.", mandatory = True),
    "deps": attr.string_list(doc = "List of package names this package depends on.", default = []),
})

def _parse_version(version):
    """Parses a version string into a list of integers for comparison."""
    parts = []
    for part in version.split("."):
        num = ""

        # iterate directly over characters
        for i in range(len(part)):
            char = part[i]
            if char.isdigit():
                num += char
            else:
                break
        if num:
            parts.append(int(num))
        else:
            parts.append(0)
    return parts

def _toolchain_extension(module_ctx):
    registrations = {}
    packages = []
    erlang_versions = []

    # Collect toolchain registrations and hex packages from all modules.
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the gleam toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(toolchain.version)

            if toolchain.erlang_version and toolchain.erlang_version not in erlang_versions:
                erlang_versions.append(toolchain.erlang_version)

        for pkg in mod.tags.hex_package:
            if not pkg.sha256:
                msg = (
                    "gleam.hex_package(name = \"{name}\") must set a non-empty sha256. " +
                    "Find it as the \"checksum\" field at " +
                    "https://hex.pm/api/packages/{name}/releases/{version}."
                )
                fail(msg.format(name = pkg.name, version = pkg.version))

            packages.append(struct(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
            ))

    # Register Gleam toolchains.
    for name, versions in registrations.items():
        if len(versions) > 1:
            selected = sorted(versions, key = _parse_version, reverse = True)[0]

            # buildifier: disable=print
            print("NOTE: gleam toolchain {} has multiple versions {}, selected {}".format(name, versions, selected))
        else:
            selected = versions[0]

        gleam_register_toolchains(
            name = name,
            gleam_version = selected,
            register = False,
        )

    # Register local Erlang toolchain repository.
    if len(erlang_versions) > 1:
        msg = (
            "Conflicting erlang_version pins were declared across gleam.toolchain calls: {}. " +
            "Only one Erlang/OTP release can be required at a time since all modules share a " +
            "single detected Erlang toolchain."
        )
        fail(msg.format(erlang_versions))
    pinned_erlang_version = erlang_versions[0] if erlang_versions else ""
    local_erlang_repository(name = "local_config_erlang", erlang_version = pinned_erlang_version)

    # Register Hex packages repository if any packages were declared.
    if packages:
        _gleam_hex_packages(
            name = "gleam_packages",
            packages = packages,
        )

def _gleam_hex_packages_impl(repository_ctx):
    """Repository rule that downloads Hex packages and generates BUILD files."""
    packages_json = repository_ctx.attr.packages

    # Decode the JSON-encoded package list.
    pkg_list = json.decode(packages_json)

    # Top-level BUILD.bazel with aliases for convenient @gleam_packages//:pkg_name references.
    top_build_lines = [
        "# Generated by gleam/extensions.bzl — do not edit.",
        "",
    ]

    for pkg in pkg_list:
        name = pkg["name"]
        version = pkg["version"]
        sha256 = pkg["sha256"]
        deps = pkg["deps"]

        # Download the Hex tarball.
        # Hex tarballs are plain .tar files containing VERSION, metadata.config,
        # contents.tar.gz, and CHECKSUM.
        url = "https://repo.hex.pm/tarballs/{}-{}.tar".format(name, version)

        repository_ctx.download_and_extract(
            url = url,
            output = "_tmp_" + name,
            type = "tar",
            sha256 = sha256,
        )

        # Extract the inner contents.tar.gz which contains the actual source files.
        repository_ctx.extract(
            archive = "_tmp_{}/contents.tar.gz".format(name),
            output = name,
        )

        # Clean up the temp extraction.
        repository_ctx.delete("_tmp_" + name)

        # Generate BUILD.bazel for this package.
        deps_str = ", ".join(['"//{}"'.format(d) for d in deps])

        build_content = """\
# Generated by gleam/extensions.bzl — do not edit.
load("@muchq_rules_gleam//gleam:defs.bzl", "gleam_library")

gleam_library(
    name = "{name}",
    data = ["gleam.toml"],
    package_name = "{name}",
    srcs = glob(["src/**/*.gleam", "src/**/*.erl", "src/**/*.mjs"], allow_empty = True),
    deps = [{deps}],
    visibility = ["//visibility:public"],
)
""".format(name = name, deps = deps_str)

        repository_ctx.file("{}/BUILD.bazel".format(name), build_content)

        # Add alias to top-level BUILD.
        top_build_lines.append(
            'alias(name = "{name}", actual = "//{name}", visibility = ["//visibility:public"])'.format(name = name),
        )

    top_build_lines.append("")  # trailing newline
    repository_ctx.file("BUILD.bazel", "\n".join(top_build_lines))

def _gleam_hex_packages(name, packages):
    """Wrapper that serializes package structs to JSON for the repository rule."""
    pkg_dicts = []
    for pkg in packages:
        pkg_dicts.append({
            "name": pkg.name,
            "version": pkg.version,
            "sha256": pkg.sha256,
            "deps": pkg.deps,
        })

    _gleam_hex_packages_repo(
        name = name,
        packages = json.encode(pkg_dicts),
    )

_gleam_hex_packages_repo = repository_rule(
    implementation = _gleam_hex_packages_impl,
    attrs = {
        "packages": attr.string(
            doc = "JSON-encoded list of Hex packages to download.",
            mandatory = True,
        ),
    },
    doc = "Downloads Gleam packages from Hex and generates gleam_library BUILD targets.",
)

gleam = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {
        "toolchain": gleam_toolchain,
        "hex_package": hex_package,
    },
)
