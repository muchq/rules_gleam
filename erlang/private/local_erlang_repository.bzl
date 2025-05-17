"""Repository rule for detecting and configuring the local Erlang installation."""

# Helper function to find an executable in common paths
def _find_executable(repository_ctx, name):
    common_paths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",  # For Apple Silicon Homebrew
        "/usr/bin",
        "/bin",
    ]
    for p in common_paths:
        path_str = p + "/" + name
        test_result = repository_ctx.execute(["test", "-f", path_str, "-a", "-x", path_str])
        if repository_ctx.path(path_str).exists and test_result.return_code == 0:
            result = repository_ctx.execute(["readlink", "-f", path_str])
            if result.return_code == 0:
                return result.stdout.strip()
            else:
                return path_str
    return None

def _get_erlang_version(repository_ctx, erl_path):
    result = repository_ctx.execute([erl_path, "-eval", 'io:format("~s", [erlang:system_info(otp_release)]), halt().', "-noshell"])
    if result.return_code == 0:
        return result.stdout.strip()
    return "unknown"

def _local_erlang_repository_impl(repository_ctx):
    """Detects local Erlang and generates BUILD file."""
    escript_path = _find_executable(repository_ctx, "escript")
    erl_path = _find_executable(repository_ctx, "erl")
    erlc_path = _find_executable(repository_ctx, "erlc")

    if not escript_path or not erl_path or not erlc_path:
        fail("Could not find required Erlang executables (escript, erl, erlc) in common system paths. Please ensure Erlang is installed and available in PATH.")

    erlang_version = _get_erlang_version(repository_ctx, erl_path)

    erl_dirname_result = repository_ctx.execute(["dirname", erl_path])
    if erl_dirname_result.return_code != 0:
        fail("Failed to get dirname of erl: " + erl_dirname_result.stderr)
    erl_bin_dir = erl_dirname_result.stdout.strip()

    erlang_root_result = repository_ctx.execute(["dirname", erl_bin_dir])
    if erlang_root_result.return_code != 0:
        fail("Failed to get dirname of erl bin dir: " + erlang_root_result.stderr)
    erlang_root = erlang_root_result.stdout.strip()

    erts_include_path = "{}/usr/include".format(erlang_root)
    erl_libs_path = "{}/lib".format(erlang_root)

    if not repository_ctx.path(erts_include_path).exists:
        erts_include_path = "{}/lib/erlang/usr/include".format(erlang_root)
        if not repository_ctx.path(erts_include_path).exists:
            fail("Could not determine ERTS include directory relative to Erlang root: {}".format(erlang_root))

    if not repository_ctx.path(erl_libs_path).exists:
        fail("Could not determine Erlang libraries directory relative to Erlang root: {}".format(erlang_root))

    os_name = repository_ctx.os.name.lower()
    if "mac os" in os_name:
        os_constraint = "@platforms//os:osx"
    elif "linux" in os_name:
        os_constraint = "@platforms//os:linux"
    else:
        fail("Unsupported OS name: {}".format(repository_ctx.os.name))

    arch = repository_ctx.os.arch
    if arch == "aarch64" or arch == "arm64":
        cpu_constraint = "@platforms//cpu:arm64"
    elif arch == "x86_64" or arch == "amd64":
        cpu_constraint = "@platforms//cpu:x86_64"
    else:
        fail("Unsupported CPU architecture: {}".format(arch))

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

local_erlang_repository = repository_rule(
    implementation = _local_erlang_repository_impl,
    local = True,
    doc = "Detects local Erlang installation and configures a toolchain.",
)
