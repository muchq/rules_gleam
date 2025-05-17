"""Bazel module extension for Gleam.

This extension registers toolchains for Gleam and its required Erlang runtime.
- It downloads a Gleam compiler binary based on host OS and architecture.
- It attempts to find and configure a system-installed Erlang/OTP.

Users can specify the Gleam version in their MODULE.bazel file:
```starlark
 gleam = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
 gleam.toolchain(version = "1.x.y") # Optional, defaults to a recent stable version
 use_repo(gleam, "gleam_toolchain_linux_x86_64", "local_config_erlang") # etc.
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
})

def _toolchain_extension(module_ctx):
    registrations = {}

    # Determine Gleam version: user-specified or default
    for mod in module_ctx.modules:
        for toolchain in mod.tags.toolchain:
            if toolchain.name != _DEFAULT_NAME and not mod.is_root:
                fail("""\
                Only the root module may override the default name for the mylang toolchain.
                This prevents conflicting registrations in the global namespace of external repos.
                """)
            if toolchain.name not in registrations.keys():
                registrations[toolchain.name] = []
            registrations[toolchain.name].append(toolchain.version)
    for name, versions in registrations.items():
        if len(versions) > 1:
            # TODO: should be semver-aware, using MVS
            selected = sorted(versions, reverse = True)[0]

            # buildifier: disable=print
            print("NOTE: gleam toolchain {} has multiple versions {}, selected {}".format(name, versions, selected))
        else:
            selected = versions[0]

        gleam_register_toolchains(
            name = name,
            gleam_version = selected,
            register = False,
        )

    # Register local Erlang toolchain repository
    # This rule will try to find Erlang on the system.
    local_erlang_repository(name = "local_config_erlang")

gleam = module_extension(
    implementation = _toolchain_extension,
    tag_classes = {"toolchain": gleam_toolchain},
)
