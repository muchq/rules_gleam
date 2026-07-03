# expect_fail

Every other example in this repo demonstrates the happy path: tests passing, files already
formatted. This one is deliberately broken, on purpose:

- `expect_fail_test` (a `gleam_test`) asserts a value `greeting()` never returns.
- `expect_fail_format_test` (a `gleam_format_test`) checks `bad_format.gleam`, which is
  deliberately misformatted.

Both targets are expected to make `bazel test` fail. CI runs them explicitly and asserts that
failure actually happens (see the `.github/workflows/ci.yaml` step for this directory), proving
`gleam_test`/`gleam_format_test` correctly detect real failures rather than only ever being
exercised against inputs that already pass.
