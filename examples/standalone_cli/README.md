# standalone_cli

Demonstrates `gleam_standalone_release`: a Gleam binary that bundles the Erlang/OTP runtime
itself, so the machine that _runs_ it needs no Erlang installed at all -- unlike `gleam_binary`
(escript, see [examples/smoke](../smoke)) and `gleam_release` (runfiles-tree, see
[examples/web_service](../web_service)), both of which still shell out to a system Erlang.

This requires the hermetic Erlang toolchain, which is on by default -- no `MODULE.bazel`
configuration needed (see [examples/hermetic_erlang](../hermetic_erlang) if you need to pin a
specific OTP version/checksum instead of the built-in default). Only the hermetic toolchain's
downloaded OTP tree is Bazel-visible and reliably relocatable; `gleam_standalone_release`
fails loudly if `gleam.local_erlang_toolchain()` opts back out to PATH-based discovery.

CI proves this actually works by running the built binary with a PATH that has basic
coreutils but excludes any system Erlang entirely (`env -i` plus a curated `PATH`), so no
`erl` could possibly be found via lookup -- the binary's launcher script only ever execs an
absolute path into its own bundled runfiles tree.
