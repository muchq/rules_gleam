# gazelle_smoke

Demonstrates wiring `gleam_gazelle` (this repo's Gazelle language extension, see
[gleam_gazelle](../../gleam_gazelle)) into a _downstream_ project's own `gazelle_binary`, as
opposed to `examples/smoke` etc., which hand-write their `gleam_package(...)` targets directly.

`BUILD.bazel` here is checked in exactly as `bazel run //:gazelle` would generate it from
`gleam.toml` + `src/**/*.gleam` + `test/**/*.gleam` -- if you add a new `.gleam` file, re-run
`bazel run //:gazelle` to keep it in sync (it won't happen automatically).
