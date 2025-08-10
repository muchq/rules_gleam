"""Repository rule for detecting and configuring the local Erlang installation."""

def _find_executable(repository_ctx, name):
    """Find an executable using 'which', handling various installation methods."""
    # First try 'which' command to find in PATH
    which_result = repository_ctx.execute(["which", name])
    if which_result.return_code == 0:
        path = which_result.stdout.strip()
        if path:
            # For asdf shims, resolve to the actual binary
            if "/.asdf/shims/" in path:
                # Get the actual version path from asdf
                real_path_result = repository_ctx.execute([
                    "sh", "-c", 
                    "asdf which {} 2>/dev/null || echo {}".format(name, path)
                ])
                if real_path_result.return_code == 0:
                    real_path = real_path_result.stdout.strip()
                    if real_path and repository_ctx.path(real_path).exists:
                        return real_path
            return path
    
    # Fall back to checking common paths
    common_paths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",  # For Apple Silicon Homebrew
        "/usr/bin",
        "/bin",
    ]
    for p in common_paths:
        path_str = p + "/" + name
        if repository_ctx.path(path_str).exists:
            return path_str
    
    return None

def _get_erlang_root(repository_ctx, erl_path):
    """Get the Erlang root directory by asking erl itself."""
    result = repository_ctx.execute([
        erl_path,
        "-eval",
        'io:format("~s", [code:root_dir()]), halt().',
        "-noshell"
    ])
    if result.return_code == 0:
        return result.stdout.strip()
    
    # Fallback: try to determine from the path structure
    # This handles cases where erl might not execute properly
    erl_dirname_result = repository_ctx.execute(["dirname", erl_path])
    if erl_dirname_result.return_code != 0:
        return None
    erl_bin_dir = erl_dirname_result.stdout.strip()
    
    # Check if this looks like an Erlang installation
    # Real Erlang installations have ../lib/erlang or are directly in an erlang root
    parent_result = repository_ctx.execute(["dirname", erl_bin_dir])
    if parent_result.return_code != 0:
        return None
    parent_dir = parent_result.stdout.strip()
    
    # Check for common Erlang installation patterns
    if repository_ctx.path(parent_dir + "/lib/erlang").exists:
        return parent_dir + "/lib/erlang"
    elif repository_ctx.path(parent_dir + "/lib").exists:
        # Might be the root itself
        return parent_dir
    
    return None

def _find_erts_include(repository_ctx, erlang_root):
    """Find the ERTS include directory."""
    possible_paths = [
        erlang_root + "/usr/include",
        erlang_root + "/erts-*/include",  # Versioned ERTS
    ]
    
    for path_pattern in possible_paths:
        if "*" in path_pattern:
            # Handle glob patterns
            glob_result = repository_ctx.execute([
                "sh", "-c", 
                "ls -d {} 2>/dev/null | head -1".format(path_pattern)
            ])
            if glob_result.return_code == 0:
                path = glob_result.stdout.strip()
                if path and repository_ctx.path(path).exists:
                    return path
        else:
            if repository_ctx.path(path_pattern).exists:
                return path_pattern
    
    return None

def _find_erl_libs(repository_ctx, erlang_root):
    """Find the Erlang libraries directory."""
    possible_paths = [
        erlang_root + "/lib",
    ]
    
    for path in possible_paths:
        if repository_ctx.path(path).exists:
            # Verify it contains Erlang libraries
            test_result = repository_ctx.execute([
                "sh", "-c",
                "ls {}/*/ebin 2>/dev/null | head -1".format(path)
            ])
            if test_result.return_code == 0 and test_result.stdout.strip():
                return path
    
    return None

def _get_erlang_version(repository_ctx, erl_path):
    """Get the Erlang/OTP version."""
    result = repository_ctx.execute([
        erl_path, 
        "-eval", 
        'io:format("~s", [erlang:system_info(otp_release)]), halt().', 
        "-noshell"
    ])
    if result.return_code == 0:
        return result.stdout.strip()
    return "unknown"

def _local_erlang_repository_impl(repository_ctx):
    """Detects local Erlang and generates BUILD file."""
    # Find Erlang executables
    escript_path = _find_executable(repository_ctx, "escript")
    erl_path = _find_executable(repository_ctx, "erl")
    erlc_path = _find_executable(repository_ctx, "erlc")
    
    if not erl_path:
        fail("""
Could not find Erlang installation. Please ensure Erlang is installed and available in PATH.

Installation instructions:
- macOS: brew install erlang
- Ubuntu/Debian: apt-get install erlang
- asdf: asdf install erlang latest

After installation, ensure 'erl' is in your PATH.
""")
    
    if not escript_path:
        escript_path = erl_path  # Some installations might not have escript
    if not erlc_path:
        erlc_path = erl_path + "c"  # Try erl with 'c' suffix
    
    # Get Erlang root directory
    erlang_root = _get_erlang_root(repository_ctx, erl_path)
    if not erlang_root:
        fail("Could not determine Erlang root directory from: " + erl_path)
    
    # Find ERTS include directory
    erts_include_path = _find_erts_include(repository_ctx, erlang_root)
    if not erts_include_path:
        # Not fatal - only needed for NIFs
        erts_include_path = erlang_root + "/usr/include"  # Use a reasonable default
    
    # Find Erlang libraries directory
    erl_libs_path = _find_erl_libs(repository_ctx, erlang_root)
    if not erl_libs_path:
        fail("Could not find Erlang libraries directory in: " + erlang_root)
    
    # Get version
    erlang_version = _get_erlang_version(repository_ctx, erl_path)
    
    # Determine platform constraints
    os_name = repository_ctx.os.name.lower()
    if "mac os" in os_name or "darwin" in os_name:
        os_constraint = "@platforms//os:osx"
    elif "linux" in os_name:
        os_constraint = "@platforms//os:linux"
    elif "windows" in os_name:
        os_constraint = "@platforms//os:windows"
    else:
        fail("Unsupported OS: " + repository_ctx.os.name)
    
    arch = repository_ctx.os.arch
    if arch == "aarch64" or arch == "arm64":
        cpu_constraint = "@platforms//cpu:arm64"
    elif arch == "x86_64" or arch == "amd64":
        cpu_constraint = "@platforms//cpu:x86_64"
    else:
        fail("Unsupported CPU architecture: " + arch)
    
    # Generate BUILD file
    build_content = """\
load("@muchq_rules_gleam//erlang/private:erlang_toolchain_config.bzl", "erlang_toolchain_config")
load("@muchq_rules_gleam//erlang/private:erlang_toolchain.bzl", "erlang_toolchain")

package(default_visibility = ["//visibility:public"])

erlang_toolchain_config(
    name = "local_config",
    escript_path = "{escript_path}",
    erl_path = "{erl_path}",
    erlc_path = "{erlc_path}",
    erts_include_path = "{erts_include_path}",
    erl_libs_path = "{erl_libs_path}",
    erlang_version = "{erlang_version}",
)

erlang_toolchain(
    name = "local_toolchain",
    toolchain_config = ":local_config",
)

toolchain(
    name = "erlang_toolchain_definition",
    toolchain_type = "@muchq_rules_gleam//erlang:erlang_toolchain_type",
    exec_compatible_with = [
        "{os_constraint}",
        "{cpu_constraint}",
    ],
    target_compatible_with = [
        "{os_constraint}",
        "{cpu_constraint}",
    ],
    toolchain = ":local_toolchain",
)

# Export info for testing
filegroup(
    name = "test_info",
    srcs = [],
    visibility = ["//visibility:public"],
)
""".format(
        escript_path = escript_path,
        erl_path = erl_path,
        erlc_path = erlc_path,
        erts_include_path = erts_include_path,
        erl_libs_path = erl_libs_path,
        erlang_version = erlang_version,
        os_constraint = os_constraint,
        cpu_constraint = cpu_constraint,
    )
    
    repository_ctx.file("BUILD.bazel", build_content)
    
    # Also create a test info file for verification
    repository_ctx.file("erlang_info.txt", """\
Erlang Detection Results:
=========================
Erlang Root: {root}
Erlang Version: {version}
Erl Path: {erl}
Erlc Path: {erlc}
Escript Path: {escript}
ERTS Include: {erts}
Lib Path: {libs}
Platform: {os} / {arch}
""".format(
        root = erlang_root,
        version = erlang_version,
        erl = erl_path,
        erlc = erlc_path,
        escript = escript_path,
        erts = erts_include_path,
        libs = erl_libs_path,
        os = os_constraint,
        arch = cpu_constraint,
    ))

local_erlang_repository = repository_rule(
    implementation = _local_erlang_repository_impl,
    local = True,
    doc = "Detects local Erlang installation and configures a toolchain.",
)