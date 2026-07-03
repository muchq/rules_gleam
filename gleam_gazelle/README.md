# Gazelle extension for Gleam

A [Gazelle](https://github.com/bazelbuild/bazel-gazelle) language extension that generates
`gleam_package(...)` targets from Gleam source directories.

## What it does

For any directory containing a `gleam.toml` and at least one `src/**/*.gleam` file, running
`bazel run //:gazelle` generates:

```starlark
gleam_package(
    name = "<name from gleam.toml>",
    srcs = glob(["src/**/*.gleam"]),
    entry_module = "main",  # only if src/main.gleam exists
    gleam_toml = "gleam.toml",
    test_deps = [...],  # only if test/**/*.gleam files exist
    test_srcs = glob(["test/**/*.gleam"]),
    deps = [...],
)
```

`deps`/`test_deps` are derived from `gleam.toml`'s `[dependencies]`/`[dev-dependencies]` keys,
mapped to `@gleam_packages//:<name>` -- the label convention
`gleam.hex_package(...)`/`gleam.hex_manifest(...)` (see `//gleam:extensions.bzl`) register
their generated `gleam_library` targets under.

## What it doesn't do

This extension only generates BUILD files from Gleam source directories. It does not manage
`MODULE.bazel`'s `gleam.hex_package`/`gleam.hex_manifest` declarations -- use
`gleam.hex_manifest(manifest = "//path/to:manifest.toml")` for that (see the root README).

Nested Gleam packages (multiple `gleam.toml` files in one directory tree, as in
`examples/nested_smoke`) and non-`src`/`test` source layouts aren't handled; hand-write the
raw `gleam_library`/`gleam_binary`/`gleam_test` rules for those instead.

## Usage in a downstream project

See [examples/gazelle_smoke](../examples/gazelle_smoke) for a worked example of wiring this
extension into a project's own `gazelle_binary`/`gazelle` targets (as opposed to this repo's
own root [BUILD.bazel](../BUILD.bazel), which wires it in for `rules_gleam`'s own use).

## Testing

The core logic (`gleam.toml` parsing, rule generation) is covered by ordinary Go tests, runnable
without Bazel: `go test ./gleam_gazelle/...`.
