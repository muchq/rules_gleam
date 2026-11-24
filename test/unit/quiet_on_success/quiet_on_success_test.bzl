"""Runs quiet_on_success's command against a fake compiler that warns, then succeeds or fails."""

load("//gleam/private:package_files.bzl", "quiet_on_success")  # buildifier: disable=bzl-visibility

_SCRIPT = """\
#!/usr/bin/env bash
set -u
fake() {{ echo "warning: Deprecated type used"; echo "error: on stderr" >&2; return "$1"; }}
run() {{ true && {quiet} && echo "after"; }}
fail() {{ echo "FAIL: $*" >&2; exit 1; }}

out=$( (run 0) 2>&1 ); rc=$?
[[ $rc == 0 ]] || fail "a succeeding compile exited $rc"
[[ $out == after ]] || fail "a succeeding compile printed: $out"

out=$( (run 3) 2>&1 ); rc=$?
[[ $rc == 3 ]] || fail "a failing compile exited $rc, not the compiler's 3"
[[ $out == *"warning: Deprecated"* ]] || fail "a failing compile hid its stdout: $out"
[[ $out == *"error: on stderr"* ]] || fail "a failing compile hid its stderr: $out"
[[ $out != *after* ]] || fail "the chain carried on past a failing compile"
"""

def _impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(quiet = quiet_on_success('fake "$1"')), is_executable = True)
    return [DefaultInfo(executable = script)]

quiet_on_success_test = rule(implementation = _impl, test = True)
