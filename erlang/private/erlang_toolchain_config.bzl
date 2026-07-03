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
        "otp_tree": """\
A filegroup covering the entire OTP installation tree, for rules that need to bundle a
self-contained Erlang runtime (e.g. gleam_standalone_release). Only set by the hermetic
toolchain (gleam.erlang_toolchain(...)), since a copied host Erlang install
(local_erlang_repository) is not reliably relocatable. None otherwise.
""",
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
        otp_tree = ctx.attr.otp_tree,
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
        "otp_tree": attr.label(
            doc = "Filegroup covering the entire OTP tree (hermetic toolchain only).",
            allow_files = True,
        ),
    },
    provides = [ErlangToolchainConfigInfo],
)
