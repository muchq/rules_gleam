"""This module implements the Gleam-specific toolchain rule."""

# This provider is now part of platform_common.ToolchainInfo in the implementation.
# GleamToolchainInfo = provider(
#     doc = "Information about how to invoke the Gleam tool executable and its Erlang runtime.",
#     fields = {
#         "gleam_executable": "The Gleam compiler executable (could be a wrapper script).",
#         "underlying_gleam_tool": "The actual Gleam binary from the downloaded toolchain.",
#         "erlang_toolchain": "The ErlangToolchainInfo provider for the Erlang runtime.",
#     },
# )

def _gleam_toolchain_impl(ctx):
    erlang_toolchain_info = ctx.attr.erlang_toolchain[platform_common.ToolchainInfo]

    # This is the File object for the raw gleam binary from the @gleam_toolchain_os_arch//:gleam_tool target
    actual_gleam_binary_tool = ctx.file.target_tool

    # Name for the wrapper script we are about to create.
    # It's good practice to make it unique to this toolchain instance.
    toolchain_wrapper_name = ctx.label.name + "_gleam_wrapper.sh"
    toolchain_wrapper_script = ctx.actions.declare_file(toolchain_wrapper_name)

    # Determine the directory of the Erlang 'erl' executable to add to PATH.
    # This comes from the ErlangToolchainInfo provider (now platform_common.ToolchainInfo)
    erlang_exe_path_for_dirname = ""
    if hasattr(erlang_toolchain_info, "erl_path_str") and erlang_toolchain_info.erl_path_str:
        erlang_exe_path_for_dirname = erlang_toolchain_info.erl_path_str
    elif hasattr(erlang_toolchain_info, "escript_path_str") and erlang_toolchain_info.escript_path_str:  # Fallback
        erlang_exe_path_for_dirname = erlang_toolchain_info.escript_path_str

    # The script content will set up PATH for Erlang, then exec the actual Gleam binary.
    # $1 to this wrapper will be the path to the *actual* gleam binary.
    # Subsequent arguments ($@) are passed through to the gleam binary.
    script_content = """#!/bin/bash
set -e

# Path to the Erlang executable, used to find the Erlang bin directory.
ERL_EXE_PATH_FOR_DIRNAME_INTERNAL=\"{erlang_path_placeholder}\"

# The actual Gleam binary to execute (passed as $1 to this script).
# This script is primarily to set up the PATH for Erlang.
ACTUAL_GLEAM_TOOL_PATH=\"$1\"
shift # Consume $1, so $@ are the remaining args for gleam itself.

# Add Erlang's bin directory to PATH if found.
if [ -n \"$ERL_EXE_PATH_FOR_DIRNAME_INTERNAL\" ]; then
  ERLANG_BIN_DIR=\"$(dirname \"$ERL_EXE_PATH_FOR_DIRNAME_INTERNAL\")\"
  export PATH=\"$ERLANG_BIN_DIR:$PATH\"
else
  echo \"Warning: Erlang path not found in toolchain; PATH not modified for Erlang.\" >&2
fi

# Execute the actual Gleam tool with the remaining arguments.
exec \"$ACTUAL_GLEAM_TOOL_PATH\" \"$@\"
""".format(
        erlang_path_placeholder = erlang_exe_path_for_dirname,
    )

    ctx.actions.write(
        output = toolchain_wrapper_script,
        content = script_content,
        is_executable = True,
    )

    # This ToolchainInfo will be what rules request from the toolchain type.
    return [platform_common.ToolchainInfo(
        # This is the executable rules should use (our wrapper script).
        gleam_executable = toolchain_wrapper_script,
        # This is the *actual* Gleam binary that the wrapper script calls.
        # Rules might need this if they bypass the wrapper for some reason (not typical).
        underlying_gleam_tool = actual_gleam_binary_tool,
        # Pass through the Erlang toolchain info, as Gleam rules will need it.
        erlang_toolchain = erlang_toolchain_info,
        # Provide template variables for genrule, etc.
        # For example, $(GLEAM_BIN) could point to the wrapper script.
        template_variables = platform_common.TemplateVariableInfo({
            "GLEAM_BIN": toolchain_wrapper_script.short_path,
            "GLEAM_TOOL_PATH": actual_gleam_binary_tool.short_path,
        }),
    )]

gleam_toolchain = rule(
    implementation = _gleam_toolchain_impl,
    attrs = {
        "target_tool": attr.label(
            doc = "The label of the downloaded Gleam compiler tool from its repository (e.g., @gleam_toolchain_darwin_aarch64//:gleam_tool).",
            allow_single_file = True,
            executable = True,
            cfg = "exec",  # This tool is used during action execution.
            mandatory = True,
        ),
        "erlang_toolchain": attr.label(
            doc = "The Erlang toolchain to be used with Gleam (e.g., @local_config_erlang//:local_toolchain).",
            providers = [platform_common.ToolchainInfo],  # Expects the standard ToolchainInfo provider.
            mandatory = True,
        ),
    },
    doc = "Defines a Gleam compiler toolchain, including its Erlang runtime.",
)
