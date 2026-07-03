# standalone_cli

Demonstrates `gleam_standalone_release`: a Gleam binary that bundles the Erlang/OTP runtime
itself, so the machine that _runs_ it needs no Erlang installed at all -- unlike `gleam_binary`
(escript, see [examples/smoke](../smoke)) and `gleam_release` (runfiles-tree, see
[examples/web_service](../web_service)), both of which still shell out to a system Erlang.

This requires the hermetic Erlang toolchain (`gleam.erlang_toolchain(...)` in `MODULE.bazel`,
see [examples/hermetic_erlang](../hermetic_erlang)): only that toolchain's downloaded OTP tree
is Bazel-visible and reliably relocatable. CI proves this actually works by running the built
binary with `PATH` cleared entirely (`env -i`), so no `erl` could possibly be found via PATH
lookup -- the binary's launcher script only ever execs an absolute path into its own bundled
runfiles tree.
