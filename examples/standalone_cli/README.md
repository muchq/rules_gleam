# standalone_cli

Demonstrates `gleam_standalone_release`: a Gleam binary that bundles the Erlang/OTP runtime
itself, so the machine that _runs_ it needs no Erlang installed at all -- unlike `gleam_binary`
(escript, see [examples/smoke](../smoke)). `gleam_release` also bundles OTP with the hermetic
toolchain, but permits a host-runtime fallback when the local toolchain is selected.

This requires the hermetic Erlang toolchain, which is on by default -- no `MODULE.bazel`
configuration needed (see [examples/hermetic_erlang](../hermetic_erlang) if you need to pin a
specific OTP version/checksum instead of the built-in default). Only the hermetic toolchain's
downloaded OTP tree is Bazel-visible and reliably relocatable; `gleam_standalone_release`
fails loudly if `gleam.local_erlang_toolchain()` opts back out to PATH-based discovery.

`bazel build //:standalone_cli_tar` produces `bazel-bin/standalone_cli.tar.gz` with the
launcher beside its materialized runfiles tree. Extract both together. The runtime still
requires a compatible OS/CPU, ABI and shared libraries; this is not a static binary. See the
repository README's deployment contract. CI runs this example in a Linux container without
host Erlang and checks both release rules' archives with config, arguments and shutdown tests.
