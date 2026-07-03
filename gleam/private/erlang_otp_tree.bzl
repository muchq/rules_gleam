"""Shared helper for rules that bundle the hermetic Erlang toolchain's OTP tree.

Used by gleam_release (when the hermetic toolchain is active) and gleam_standalone_release
(which requires it) to locate the bundled `erl` executable within the toolchain's `otp_tree`
filegroup -- see erlang/private/hermetic_erlang_repository.bzl.
"""

def find_erl_file(otp_tree_files, label):
    """Returns the `otp/bin/erl` File within a hermetic toolchain's otp_tree filegroup files.

    Fails with an actionable error if not found -- this would indicate an internal error in
    the hermetic toolchain itself (a mismatch in the extracted OTP archive's layout), not a
    user error.

    Args:
      otp_tree_files: list of File, the hermetic toolchain's otp_tree filegroup files.
      label: Label of the rule doing the lookup, used only for the error message.

    Returns:
      The `otp/bin/erl` File.
    """
    for f in otp_tree_files:
        if f.short_path.endswith("otp/bin/erl"):
            return f
    fail((
        "'{label}': could not find 'otp/bin/erl' in the hermetic Erlang toolchain's otp_tree " +
        "filegroup. This is an internal error in the hermetic toolchain " +
        "(erlang/private/hermetic_erlang_repository.bzl) -- please file an issue."
    ).format(label = label))

def resolve_erl_invocation(otp_tree_files, ws_name, label):
    """Returns (erl_invocation, extra_runfiles) for a gleam_release-style launcher script.

    If `otp_tree_files` is non-empty (the hermetic Erlang toolchain provided a bundleable OTP
    tree), returns a runfiles-relative path to its "otp/bin/erl", quoted and ready to splice
    into a shell command, so the launcher never depends on anything outside its own runfiles --
    the toolchain's own absolute path is a build-machine-only location (e.g. under Bazel's
    cache) and would silently break on any other machine. Otherwise falls back to a plain "erl"
    PATH lookup, and no extra runfiles are needed.

    Args:
      otp_tree_files: list of File, the hermetic toolchain's otp_tree filegroup files, or an
        empty list if the toolchain has no bundleable tree.
      ws_name: str, the workspace name the launcher's runfiles are rooted under.
      label: Label of the rule doing the lookup, used only for find_erl_file's error message.

    Returns:
      A (erl_invocation, extra_runfiles) tuple: erl_invocation is a shell-ready string (already
      quoted if it's a runfiles path); extra_runfiles is the list of File to add to the
      launcher's runfiles (empty if falling back to PATH).
    """
    if not otp_tree_files:
        return "erl", []
    erl_file = find_erl_file(otp_tree_files, label)
    erl_invocation = '"$RF/{ws}/{path}"'.format(ws = ws_name, path = erl_file.short_path)
    return erl_invocation, otp_tree_files
