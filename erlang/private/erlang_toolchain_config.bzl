"""Rule for configuring the Erlang toolchain."""

ErlangToolchainConfigInfo = provider(
    doc = "Information about the configured Erlang toolchain paths and settings.",
    fields = {
        "escript_path": "Path to the escript executable.",
        "erl_path": "Path to the erl executable.",
        "erlc_path": "Path to the erlc executable.",
        "erts_include_path": "Path to the ERTS include directory.",
        "erl_libs_path": "Path to the main Erlang libraries directory (containing OTP apps).",
        "erlang_version": "Detected Erlang/OTP version string.",
    },
)

def _erlang_toolchain_config_impl(ctx):
    return ErlangToolchainConfigInfo(
        escript_path = ctx.attr.escript_path,
        erl_path = ctx.attr.erl_path,
        erlc_path = ctx.attr.erlc_path,
        erts_include_path = ctx.attr.erts_include_path,
        erl_libs_path = ctx.attr.erl_libs_path,
        erlang_version = ctx.attr.erlang_version,
    )

erlang_toolchain_config = rule(
    implementation = _erlang_toolchain_config_impl,
    attrs = {
        "escript_path": attr.string(mandatory = True),
        "erl_path": attr.string(mandatory = True),
        "erlc_path": attr.string(mandatory = True),
        "erts_include_path": attr.string(mandatory = True),
        "erl_libs_path": attr.string(mandatory = True),
        "erlang_version": attr.string(mandatory = True),
    },
    provides = [ErlangToolchainConfigInfo],
)
