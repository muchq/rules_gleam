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

This already gets you a hermetic, checksum-verified Erlang/OTP toolchain (see
erlang/private/otp_checksums.bzl for the pinned version) with no further configuration. To pin
a different OTP release, give a checksum for each platform you build on (see
docs/otp_checksums.md):
```starlark
gleam.erlang_toolchain(
    otp_version = "29.0.2",
    sha256 = {
        "ubuntu-22.04_amd64": "2e9d154a52de72653a1a3c1269b10df3b4ff5e058753e167bc92602681038e9a",
        "macos_arm64": "ec6e09dee496adf646b0a22eef26b769e7f8032c83dd10292c58d50fb38e2210",
    },
)
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

A `@<name>_host` repository (e.g. `@gleam_host` for the default toolchain name) is always
created alongside the per-platform ones, exposing a directly `bazel run`-able `gleam` CLI for
whatever platform Bazel happens to be running on, without needing to know its OS/arch string:
```starlark
use_repo(gleam, "gleam_host", ...)
```
```shell
bazel run @gleam_host//:gleam -- format
```
"""

load("//erlang/private:hermetic_erlang_repository.bzl", "hermetic_erlang_repository")  # buildifier: disable=bzl-visibility
load("//erlang/private:local_erlang_repository.bzl", "local_erlang_repository")  # buildifier: disable=bzl-visibility
load("//erlang/private:otp_checksums.bzl", "DEFAULT_OS_VERSION", "DEFAULT_OTP_VERSION")  # buildifier: disable=bzl-visibility
load("//gleam/private:hex_package_policy.bzl", "hex_package_build_file", "unsupported_package_reason")
load("//gleam/private:hex_resolution.bzl", "hex_declaration", "resolve_hex_packages")
load("//gleam/private:manifest_toml.bzl", "parse_manifest_toml")
load("//gleam/private:version.bzl", "select_version")
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
Map from "<distro>_<arch>" for Linux (e.g. "ubuntu-22.04_amd64", matching os_version) or
"macos_<arch>" (e.g. "macos_arm64") to the expected sha256 of that OTP tarball. Required for
every platform you build on unless the release is in the built-in table
(erlang/private/otp_checksums.bzl); a missing checksum fails the fetch. See
docs/otp_checksums.md.
""", default = {}),
    "allow_unverified_download": attr.bool(doc = """\
Insecure: download platforms with no known checksum without verification, printing the
observed digest. Only for bootstrapping a new release; never leave it set.
""", default = False),
})

local_erlang_toolchain = tag_class(attrs = {}, doc = """\
Opts out of the (now default) hermetic Erlang/OTP toolchain, reverting to discovering
Erlang/OTP on the host's PATH instead (see erlang/private/local_erlang_repository.bzl). Use
this if hermetic downloads aren't practical in your build environment, or you need a platform
the hermetic toolchain doesn't support. Mutually exclusive with gleam.erlang_toolchain(...).
""")

hex_package = tag_class(attrs = {
    "override": attr.bool(doc = "Root-only explicit replacement of all declarations for this package. Supply the complete selected version, checksum, dependencies and build policy. Same-version checksum conflicts still fail."),
    "build_tools": attr.string_list(doc = "Declared Hex build tools; empty means infer from archive layout."),
    "otp_app": attr.string(doc = "OTP application name; defaults to the Hex package name."),
    "allow_plain_erlang": attr.bool(doc = "Explicitly compile an audited Erlang-only package without interpreting its Rebar3 configuration."),
    "name": attr.string(doc = "Hex package name (e.g. 'gleam_stdlib').", mandatory = True),
    "version": attr.string(doc = "Exact package version (e.g. '0.60.0').", mandatory = True),
    "sha256": attr.string(doc = "SHA-256 checksum of the Hex tarball (outer_checksum from manifest.toml, found after running `gleam deps download`). Required: an empty checksum means Bazel cannot verify the downloaded tarball hasn't been tampered with or changed upstream.", mandatory = True),
    "deps": attr.string_list(doc = "List of package names this package depends on.", default = []),
})

hex_manifest = tag_class(attrs = {
    "plain_erlang_packages": attr.string_list(doc = "Audited Erlang-only packages that can compile without Rebar3 options, hooks, plugins or native code."),
    "manifest": attr.label(doc = """\
Label of a Gleam manifest.toml lockfile (generated by `gleam deps download` / `gleam build`,
found next to gleam.toml). Its resolved packages -- name, version, transitive requirements,
and outer_checksum -- are parsed and registered exactly as if each had been declared with its
own gleam.hex_package(...) call, eliminating the need to hand-maintain the transitive
dependency graph and checksums. Only entries with source = "hex" are included; git- or
path-sourced packages are skipped. Supply those packages as local gleam_library targets
and wire their deps explicitly in BUILD.bazel. Imported Hex packages must depend only on
other declared Hex packages.
""", allow_single_file = True, mandatory = True),
})

def _toolchain_extension(module_ctx):
    registrations = {}
    declarations = []
    erlang_versions = []
    hermetic_erlang_toolchains = []
    local_erlang_requested = False

    # Collect toolchain registrations and hex packages from all modules.
    for mod in module_ctx.modules:
        module_desc = "{} module {}@{}".format("root" if mod.is_root else "dependency", mod.name or "<unnamed>", mod.version or "<unversioned>")
        for hermetic in mod.tags.erlang_toolchain:
            hermetic_erlang_toolchains.append(struct(
                otp_version = hermetic.otp_version,
                os_version = hermetic.os_version,
                sha256 = hermetic.sha256,
                allow_unverified_download = hermetic.allow_unverified_download,
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

            declarations.append(hex_declaration(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
                build_tools = pkg.build_tools,
                otp_app = pkg.otp_app,
                allow_plain_erlang = pkg.allow_plain_erlang,
                source = module_desc + " via " + "gleam.hex_package(name = \"{}\")".format(pkg.name),
                is_root = mod.is_root,
                override = pkg.override,
            ))

        for manifest_tag in mod.tags.hex_manifest:
            manifest_label = str(manifest_tag.manifest)
            manifest_path = module_ctx.path(manifest_tag.manifest)
            content = module_ctx.read(manifest_path)
            for pkg in parse_manifest_toml(content):
                if pkg.source in ["git", "local", "path"]:
                    continue
                if pkg.source != "hex":
                    fail((
                        "Unsupported manifest package '{name}' from {module} via {manifest} " +
                        "(source = \"{source}\"). Expected hex, git, local or path."
                    ).format(name = pkg.name, module = module_desc, manifest = manifest_label, source = pkg.source))
                if not pkg.sha256:
                    fail((
                        "manifest.toml package '{name}' in {manifest} has source = \"hex\" but " +
                        "no outer_checksum. Regenerate manifest.toml with `gleam deps download`."
                    ).format(name = pkg.name, manifest = manifest_label))

                declarations.append(hex_declaration(
                    name = pkg.name,
                    version = pkg.version,
                    sha256 = pkg.sha256,
                    deps = pkg.deps,
                    build_tools = pkg.build_tools,
                    otp_app = pkg.otp_app,
                    allow_plain_erlang = pkg.name in manifest_tag.plain_erlang_packages,
                    source = module_desc + " via " + "gleam.hex_manifest(manifest = \"{}\")".format(manifest_label),
                    is_root = mod.is_root,
                ))

    # Validate the complete selected graph before generating any repositories.
    packages = resolve_hex_packages(declarations)

    # Register Gleam toolchains.
    for name, versions in registrations.items():
        selection = select_version(versions)
        if len(selection.distinct) > 1:
            # buildifier: disable=print
            print("NOTE: gleam toolchain {} has multiple versions {}, selected {}".format(name, selection.distinct, selection.selected))

        gleam_register_toolchains(
            name = name,
            gleam_version = selection.selected,
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
            allow_unverified_download = hermetic.allow_unverified_download
        else:
            otp_version = DEFAULT_OTP_VERSION
            os_version = DEFAULT_OS_VERSION
            sha256 = {}
            allow_unverified_download = False
        hermetic_erlang_repository(
            name = "local_config_erlang",
            otp_version = otp_version,
            os_version = os_version,
            sha256 = sha256,
            allow_unverified_download = allow_unverified_download,
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

        has_gleam_toml = repository_ctx.path("{}/gleam.toml".format(name)).exists
        native_markers = [p for p in ["c_src", "Makefile", "makefile", "mix.exs", "rebar.config.script"] if repository_ctx.path(name + "/" + p).exists]
        reason = unsupported_package_reason(
            name,
            pkg["build_tools"],
            pkg["otp_app"],
            has_gleam_toml,
            pkg["allow_plain_erlang"],
            native_markers,
        )
        if reason:
            fail("Hex package '{}': {} Use a dedicated Bazel build for this dependency, or choose a supported package.".format(name, reason))

        # Only explicitly audited plain Erlang packages may bypass Rebar3.
        if not has_gleam_toml:
            repository_ctx.file(
                "{}/gleam.toml".format(name),
                'name = "{}"\nversion = "{}"\n'.format(name, version),
            )

        # Generate BUILD.bazel for this package.

        build_content = hex_package_build_file(name, pkg["otp_app"], deps)

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
            "build_tools": pkg.build_tools,
            "otp_app": pkg.otp_app,
            "allow_plain_erlang": pkg.allow_plain_erlang,
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
