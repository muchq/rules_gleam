# hermetic_erlang

This example opts into the hermetic Erlang/OTP toolchain via
`gleam.erlang_toolchain(otp_version = "...")` in `MODULE.bazel`, instead of the default
PATH-based discovery of a host-installed Erlang. Bazel downloads a prebuilt OTP release and
uses it directly, so this example builds and tests correctly even on a machine with no Erlang
installed at all (CI installs one anyway, for the other examples that still use the default
local discovery -- this example ignores it entirely).
