"""Stage declared OTP include/ and priv/ files beside compiled ebin outputs."""

load("@bazel_skylib//lib:shell.bzl", "shell")

_OTP_DIRS = ["include", "priv"]

def _prefix(package_root, subdir):
    return (package_root + "/" if package_root else "") + subdir + "/"

def erl_compiler_options_command(files, package_root):
    """Returns a shell command exporting ERL_COMPILER_OPTIONS for `gleam compile-package`.

    `gleam compile-package` compiles Erlang sources without any include path, so headers under
    include/ (which Rebar3 would pass as `-I include`) are added explicitly. `deterministic`
    keeps the sandbox path out of the compiled BEAM files.

    Args:
        files: Declared data input Files.
        package_root: Execroot-relative package directory.

    Returns:
        A shell command string.
    """
    options = "deterministic"
    include_prefix = _prefix(package_root, "include")
    if [f for f in files if f.path.startswith(include_prefix)]:
        options += ',{i,\\"$(pwd)/' + include_prefix + '\\"}'
    return 'export ERL_COMPILER_OPTIONS="[' + options + ']"'

def otp_package_commands(files, package_root, output):
    """Returns shell commands that copy declared OTP assets and a static application resource.

    Gleam links `<out>/priv` to the source priv directory with an absolute path, which would
    leave a dangling sandbox symlink in the tree artifact, so it is replaced with real copies.
    include/ is staged so dependents can use `-include_lib("<app>/include/...")`.

    Args:
        files: Declared data input Files.
        package_root: Execroot-relative package directory.
        output: Compiled package tree artifact.

    Returns:
        Shell command strings.
    """
    commands = ["rm -rf {}".format(shell.quote(output.path + "/priv"))]
    for subdir in _OTP_DIRS:
        prefix = _prefix(package_root, subdir)
        for f in files:
            if f.path.startswith(prefix):
                destination = output.path + "/" + subdir + "/" + f.path[len(prefix):]
                parent = destination.rsplit("/", 1)[0]
                commands.append("mkdir -p {} && cp -L {} {}".format(
                    shell.quote(parent),
                    shell.quote(f.path),
                    shell.quote(destination),
                ))
    app_src = _prefix(package_root, "src") + output.basename + ".app.src"
    for f in files:
        if f.path == app_src:
            commands.append("mkdir -p {} && cp -L {} {}".format(
                shell.quote(output.path + "/ebin"),
                shell.quote(f.path),
                shell.quote(output.path + "/ebin/" + output.basename + ".app"),
            ))
    return commands

def quiet_on_success(command):
    """Returns command, printing its output only if it fails.

    Braced so that it is a single command inside an `&&` chain: a bare `||` would bind to the
    whole chain before it.

    Args:
        command: A shell command.

    Returns:
        A shell command string.
    """
    return "{ _out=$(" + command + ' 2>&1) || { _rc=$?; printf "%s\\n" "$_out" >&2; exit "$_rc"; }; }'
