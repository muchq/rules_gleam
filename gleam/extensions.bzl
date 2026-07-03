"""Bazel module extension for Gleam.

This extension handles:
1. Gleam compiler toolchain registration (downloads gleam binary per platform).
2. Erlang toolchain configuration: hermetic by default (Bazel downloads a prebuilt OTP release
   for you, see erlang/private/hermetic_erlang_repository.bzl), pinned to a specific version via
   gleam.erlang_toolchain(...); or, if you explicitly opt out with
   gleam.local_erlang_toolchain(), the previous PATH-based host discovery
   (erlang/private/local_erlang_repository.bzl).
3. Hex package management (downloads and exposes 3p Gleam packages from hex.pm), either
   declared package-by-package with gleam.hex_package(...), or in bulk by parsing a Gleam
   project's own manifest.toml lockfile with gleam.hex_manifest(...) -- see below.

Usage in MODULE.bazel:
```starlark
gleam = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
gleam.toolchain(version = "1.17.0")
gleam.hex_package(name = "gleam_stdlib", version = "0.60.0", sha256 = "...", deps = [])
gleam.hex_package(name = "gleeunit", version = "1.0.2", sha256 = "...", deps = ["gleam_stdlib"])
use_repo(gleam, "gleam_toolchains", "local_config_erlang", "gleam_packages")
```

This already gets you a hermetic Erlang/OTP toolchain (see `_DEFAULT_HERMETIC_OTP_VERSION`
below for the exact pinned version) with no further configuration. To pin a specific OTP
release instead of the built-in default:
```starlark
gleam.erlang_toolchain(otp_version = "29.0.2")
```

To opt out of the hermetic toolchain entirely and go back to discovering Erlang/OTP on the
host's `PATH` (e.g. if hermetic downloads aren't practical in your build environment, or you
need a platform the hermetic toolchain doesn't support):
```starlark
gleam.local_erlang_toolchain()
```

Instead of declaring every package (and its full transitive graph) by hand, parse them from a
project's manifest.toml lockfile:
```starlark
gleam.hex_manifest(manifest = "//path/to:manifest.toml")
```
"""

load("//erlang/private:hermetic_erlang_repository.bzl", "hermetic_erlang_repository")  # buildifier: disable=bzl-visibility
load("//erlang/private:local_erlang_repository.bzl", "local_erlang_repository")  # buildifier: disable=bzl-visibility
load("//gleam/private:manifest_toml.bzl", "parse_manifest_toml")
load("//gleam/private:version.bzl", "parse_version")
load(":repositories.bzl", "gleam_register_toolchains")

_DEFAULT_NAME = "gleam"

# Used when Erlang is hermetic by default (no gleam.erlang_toolchain(...) call) -- see
# erlang/private/hermetic_erlang_repository.bzl. No checksum is pinned yet for this version --
# the first CI run downloads unverified and prints the observed checksum, same as an explicit
# gleam.erlang_toolchain(...) call with no matching sha256 entry.
_DEFAULT_HERMETIC_OTP_VERSION = "28.1"
_DEFAULT_HERMETIC_OS_VERSION = "ubuntu-22.04"
_DEFAULT_HERMETIC_SHA256 = {}

gleam_toolchain = tag_class(attrs = {
    "name": attr.string(doc = """\
Base name for generated repositories, allowing more than one gleam toolchain to be registered.
Overriding the default is only permitted in the root module.
""", default = _DEFAULT_NAME),
    "version": attr.string(doc = "Explicit version of gleam.", mandatory = True),
    "erlang_version": attr.string(doc = """\
Optional exact Erlang/OTP release to require (e.g. "26"), checked against
erlang:system_info(otp_release) on the host Erlang found on PATH. Only applies when
gleam.local_erlang_toolchain() has also been used to opt out of the (now default) hermetic
toolchain -- PATH-based discovery does not pin the actual bytes used to build, so this only
turns a silent cross-machine reproducibility gap into a loud, actionable failure when the
host's Erlang/OTP does not match what you expect. Leave unset to accept whatever Erlang/OTP
release is found.
""", default = ""),
})

erlang_toolchain = tag_class(attrs = {
    "otp_version": attr.string(doc = """\
Exact Erlang/OTP release to fetch hermetically (e.g. "27.1.2"), overriding the version Erlang
is already hermetic with by default even without this tag. Downloads a prebuilt OTP release
from the same origins used by erlef/setup-beam (builds.hex.pm for Linux, erlef/otp_builds on
GitHub for macOS). Mutually exclusive with gleam.local_erlang_toolchain() and
gleam.toolchain(erlang_version=...).
""", mandatory = True),
    "os_version": attr.string(doc = """\
Linux distro/version tag used to select the prebuilt OTP archive (e.g. "ubuntu-22.04").
Ignored on macOS. The Linux archives are glibc-linked and tied to a specific distro version --
there is no portable musl-static build available from this origin.
""", default = "ubuntu-22.04"),
    "sha256": attr.string_dict(doc = """\
Optional map from "<os>_<arch>" (e.g. "linux_amd64", "linux_arm64", "macos_amd64",
"macos_arm64") to the expected sha256 of that platform's OTP tarball. Platforms without an
entry are downloaded unverified; the actual checksum is printed so it can be pinned.
""", default = {}),
})

local_erlang_toolchain = tag_class(attrs = {}, doc = """\
Opts out of the (now default) hermetic Erlang/OTP toolchain, reverting to discovering
Erlang/OTP on the host's PATH instead (see erlang/private/local_erlang_repository.bzl). Use
this if hermetic downloads aren't practical in your build environment, or you need a platform
the hermetic toolchain doesn't support. Mutually exclusive with gleam.erlang_toolchain(...).
""")

hex_package = tag_class(attrs = {
    "name": attr.string(doc = "Hex package name (e.g. 'gleam_stdlib').", mandatory = True),
    "version": attr.string(doc = "Exact package version (e.g. '0.60.0').", mandatory = True),
    "sha256": attr.string(doc = "SHA-256 checksum of the Hex tarball (outer_checksum from manifest.toml, found after running `gleam deps download`). Required: an empty checksum means Bazel cannot verify the downloaded tarball hasn't been tampered with or changed upstream.", mandatory = True),
    "deps": attr.string_list(doc = "List of package names this package depends on.", default = []),
})

hex_manifest = tag_class(attrs = {
    "manifest": attr.label(doc = """\
Label of a Gleam manifest.toml lockfile (generated by `gleam deps download` / `gleam build`,
found next to gleam.toml). Its resolved packages -- name, version, transitive requirements,
and outer_checksum -- are parsed and registered exactly as if each had been declared with its
own gleam.hex_package(...) call, eliminating the need to hand-maintain the transitive
dependency graph and checksums. Only entries with source = "hex" are included; git- or
path-sourced packages are skipped with a printed warning, since only Hex-hosted tarballs are
supported.
""", allow_single_file = True, mandatory = True),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    packages = []
    package_sources = {}  # package name -> "gleam.hex_package(...)" or the manifest label, for conflict errors
    erlang_versions = []
    hermetic_erlang_toolchains = []
    local_erlang_requested = False

    def _add_package(name, version, sha256, deps, source_desc):
        if name in package_sources:
            fail((
                "Hex package '{name}' is declared twice: once via {first}, and again via " +
                "{second}. Remove one of the declarations."
            ).format(name = name, first = package_sources[name], second = source_desc))
        package_sources[name] = source_desc
        packages.append(struct(name = name, version = version, sha256 = sha256, deps = deps))

    # Collect toolchain registrations and hex packages from all modules.
    for mod in module_ctx.modules:
        for hermetic in mod.tags.erlang_toolchain:
            hermetic_erlang_toolchains.append(struct(
                otp_version = hermetic.otp_version,
                os_version = hermetic.os_version,
                sha256 = hermetic.sha256,
            ))

        if mod.tags.local_erlang_toolchain:
            local_erlang_requested = True

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

            _add_package(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
                source_desc = "gleam.hex_package(name = \"{}\")".format(pkg.name),
            )

        for manifest_tag in mod.tags.hex_manifest:
            manifest_label = str(manifest_tag.manifest)
            manifest_path = module_ctx.path(manifest_tag.manifest)
            content = module_ctx.read(manifest_path)
            for pkg in parse_manifest_toml(content):
                if pkg.source != "hex":
                    # buildifier: disable=print
                    print((
                        "NOTE: skipping manifest.toml package '{name}' from {manifest} " +
                        "(source = \"{source}\"): only source = \"hex\" packages are supported."
                    ).format(name = pkg.name, manifest = manifest_label, source = pkg.source))
                    continue
                if not pkg.sha256:
                    fail((
                        "manifest.toml package '{name}' in {manifest} has source = \"hex\" but " +
                        "no outer_checksum. Regenerate manifest.toml with `gleam deps download`."
                    ).format(name = pkg.name, manifest = manifest_label))

                _add_package(
                    name = pkg.name,
                    version = pkg.version,
                    sha256 = pkg.sha256,
                    deps = pkg.deps,
                    source_desc = "gleam.hex_manifest(manifest = \"{}\")".format(manifest_label),
                )

    # Register Gleam toolchains.
    for name, versions in registrations.items():
        if len(versions) > 1:
            selected = sorted(versions, key = parse_version, reverse = True)[0]

            # buildifier: disable=print
            print("NOTE: gleam toolchain {} has multiple versions {}, selected {}".format(name, versions, selected))
        else:
            selected = versions[0]

        gleam_register_toolchains(
            name = name,
            gleam_version = selected,
        )

    # Register the Erlang toolchain repository. Hermetic by default (either the built-in
    # version, or whatever gleam.erlang_toolchain(...) pins); gleam.local_erlang_toolchain()
    # opts back out to PATH-based host discovery.
    if len(hermetic_erlang_toolchains) > 1:
        fail(
            "Only one gleam.erlang_toolchain(...) call is allowed across all modules, since " +
            "all modules share a single Erlang toolchain repository. Found: {}".format(
                [h.otp_version for h in hermetic_erlang_toolchains],
            ),
        )

    if hermetic_erlang_toolchains and local_erlang_requested:
        fail(
            "gleam.erlang_toolchain(...) and gleam.local_erlang_toolchain() are mutually " +
            "exclusive: the former pins a hermetic OTP release, the latter opts out of the " +
            "hermetic toolchain entirely.",
        )

    if hermetic_erlang_toolchains or not local_erlang_requested:
        if erlang_versions:
            fail(
                "gleam.toolchain(erlang_version = ...) only applies when opting out of the " +
                "hermetic toolchain -- add gleam.local_erlang_toolchain() to your MODULE.bazel " +
                "if you need PATH-based Erlang/OTP version validation, or remove erlang_version " +
                "since the hermetic toolchain (the default) already pins an exact release.",
            )
        if hermetic_erlang_toolchains:
            hermetic = hermetic_erlang_toolchains[0]
            otp_version = hermetic.otp_version
            os_version = hermetic.os_version
            sha256 = hermetic.sha256
        else:
            otp_version = _DEFAULT_HERMETIC_OTP_VERSION
            os_version = _DEFAULT_HERMETIC_OS_VERSION
            sha256 = _DEFAULT_HERMETIC_SHA256
        hermetic_erlang_repository(
            name = "local_config_erlang",
            otp_version = otp_version,
            os_version = os_version,
            sha256 = sha256,
        )
    else:
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

        # Some Hex packages consumed transitively (e.g. plain Erlang/rebar3 packages like
        # hpack_erl, pulled in by Gleam packages that wrap them) ship no gleam.toml at all.
        # `gleam compile-package` requires one present in the package directory regardless
        # of the package's own build tooling, so synthesize a minimal one if the extracted
        # package didn't ship its own.
        if not repository_ctx.path("{}/gleam.toml".format(name)).exists:
            repository_ctx.file(
                "{}/gleam.toml".format(name),
                'name = "{}"\nversion = "{}"\n'.format(name, version),
            )

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
        "erlang_toolchain": erlang_toolchain,
        "local_erlang_toolchain": local_erlang_toolchain,
        "hex_package": hex_package,
        "hex_manifest": hex_manifest,
    },
)
