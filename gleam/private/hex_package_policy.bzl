"""Supported Hex build contract; never silently substitute for another build tool."""

visibility(["//gleam/...", "//test/..."])

def unsupported_package_reason(name, build_tools, otp_app, has_gleam_toml, allow_plain_erlang, native_markers):
    """Returns an actionable rejection reason, or None for a supported package.

    Args:
        name: Hex package name.
        build_tools: Build tools declared by the lockfile or extension tag.
        otp_app: OTP application name.
        has_gleam_toml: Whether the archive contains a Gleam project.
        allow_plain_erlang: Explicit opt-in to compiling audited raw Erlang sources.
        native_markers: Detected native or custom build entry points.

    Returns:
        An error string, or None when supported.
    """
    if otp_app != name:
        return "OTP application name '{}' differs from Hex name '{}'; this layout is not supported yet.".format(otp_app, name)
    if native_markers:
        return "native/custom build inputs {} are unsupported; NIFs, Mix and build scripts are not executed.".format(native_markers)
    if build_tools and "gleam" not in build_tools:
        if not (allow_plain_erlang and build_tools == ["rebar3"]):
            return "build_tools = {} requires unsupported build tooling. Only audited plain Erlang packages may opt in with allow_plain_erlang / plain_erlang_packages.".format(build_tools)
    if not has_gleam_toml and not allow_plain_erlang:
        return "archive has no gleam.toml; explicitly audit and opt in with allow_plain_erlang / plain_erlang_packages to compile plain Erlang sources."
    if not has_gleam_toml and "gleam" in build_tools:
        return "declares the Gleam build tool but contains no gleam.toml."
    return None
