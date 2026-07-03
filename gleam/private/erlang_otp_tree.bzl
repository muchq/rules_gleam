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
