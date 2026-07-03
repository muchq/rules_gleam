# hermetic_erlang

The Erlang/OTP toolchain is hermetic by default (Bazel downloads a prebuilt OTP release and
uses it directly, rather than discovering one on the host's `PATH`) -- this example just
demonstrates explicitly pinning a specific `otp_version`/checksum via
`gleam.erlang_toolchain(...)` in `MODULE.bazel`, instead of accepting the built-in default
version. It builds and tests correctly even on a machine with no Erlang installed at all (CI
installs one anyway, for `examples/nested_smoke`, the one example that opts back out to
PATH-based discovery via `gleam.local_erlang_toolchain()` -- this example ignores it
entirely).
