"""Runs quiet_on_success's command against a fake compiler that warns, then succeeds or fails."""

load("//gleam/private:package_files.bzl", "quiet_on_success")  # buildifier: disable=bzl-visibility

_SCRIPT = """\
#!/bin/bash
set -u
fake() {{ echo "warning: 100% Deprecated"; echo "error: on stderr" >&2; return "$1"; }}
run() {{ true && {quiet} && echo "after"; }}
fail() {{ echo "FAIL: $*" >&2; exit 1; }}

out=$( (run 0) 2>&1 ); rc=$?
[[ $rc == 0 ]] || fail "a succeeding compile exited $rc"
[[ $out == after ]] || fail "a succeeding compile printed: $out"

err=$(mktemp)
out=$( (run 3) 2>"$err" ); rc=$?
err=$(cat "$err")
[[ $rc == 3 ]] || fail "a failing compile exited $rc, not the compiler's 3"
[[ -z $out ]] || fail "a failing compile wrote to stdout: $out"
[[ $err == *"warning: 100% Deprecated"* ]] || fail "a failing compile lost its stdout: $err"
[[ $err == *"error: on stderr"* ]] || fail "a failing compile lost its stderr: $err"
"""

def _impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(quiet = quiet_on_success('fake "$1"')), is_executable = True)
    return [DefaultInfo(executable = script)]

quiet_on_success_test = rule(implementation = _impl, test = True)
