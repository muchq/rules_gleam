"""Rule definition for the Erlang toolchain."""

load(":erlang_toolchain_config.bzl", "ErlangToolchainConfigInfo")

def _erlang_toolchain_impl(ctx):
    config = ctx.attr.toolchain_config[ErlangToolchainConfigInfo]

    # All information comes directly from the config provider as strings
    return [
        platform_common.ToolchainInfo(
            # Store executable paths as strings
            escript_path_str = config.escript_path,
            erl_path_str = config.erl_path,
            erlc_path_str = config.erlc_path,

            # Store directory paths as strings
            erts_include_path_str = config.erts_include_path,
            erl_libs_path_str = config.erl_libs_path,
            version = config.erlang_version,
        ),
    ]

erlang_toolchain = rule(
    implementation = _erlang_toolchain_impl,
    attrs = {
        "toolchain_config": attr.label(
            mandatory = True,
            providers = [ErlangToolchainConfigInfo],
            doc = "Label of the erlang_toolchain_config target.",
        ),
    },
)
