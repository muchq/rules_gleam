"""Rule definition for the Erlang toolchain."""

load(":erlang_toolchain_config.bzl", "ErlangToolchainConfigInfo")

def _erlang_toolchain_impl(ctx):
    config = ctx.attr.toolchain_config[ErlangToolchainConfigInfo]

    # Hermetic tools must be Files, not absolute repository-cache paths: Bazel
    # hashes and stages these inputs on sandboxed/remote execution workers.
    files = config.otp_tree[DefaultInfo].files if config.otp_tree else depset()
    executables = {}
    if config.otp_tree:
        for f in files.to_list():
            for name in ["erl", "erlc", "escript"]:
                if f.short_path.endswith("/otp/bin/" + name):
                    executables[name] = f
        for name in ["erl", "erlc", "escript"]:
            if name not in executables:
                fail("Hermetic OTP tree is missing otp/bin/{}".format(name))

    return [
        platform_common.ToolchainInfo(
            erl = executables.get("erl"),
            erlc = executables.get("erlc"),
            escript = executables.get("escript"),
            tool_files = files,
            # String paths remain for the explicit, non-hermetic local opt-out.
            escript_path_str = executables["escript"].path if executables else config.escript_path,
            erl_path_str = executables["erl"].path if executables else config.erl_path,
            erlc_path_str = executables["erlc"].path if executables else config.erlc_path,

            # Store directory paths as strings
            erts_include_path_str = config.erts_include_path,
            erl_libs_path_str = config.erl_libs_path,
            version = config.erlang_version,

            # A filegroup Target covering the whole OTP tree, or None (see ErlangToolchainConfigInfo.otp_tree).
            otp_tree = config.otp_tree,
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
