# Standalone Gleam App Example

This example demonstrates how to use `rules_gleam` in a standalone Bazel project.

## Structure

- `MODULE.bazel` - Declares this as a Bazel module and imports rules_gleam
- `BUILD.bazel` - Defines the build targets using Gleam rules
- `src/` - Gleam source code
- `test/` - Gleam tests

## Commands

```bash
# Build the application
bazel build //:app

# Run the application
bazel run //:app

# Run tests
bazel test //:app_test

# Build deployable archive
bazel build //:app
# The archive will be at bazel-bin/app.tar.gz

# Deploy the app
tar -xzf bazel-bin/app.tar.gz
./run.sh
```

## Using rules_gleam in your project

To use rules_gleam in your own project, add this to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_gleam", version = "x.y.z")

# Configure toolchains
gleam = use_extension("@rules_gleam//gleam:extensions.bzl", "gleam")
use_repo(gleam, "gleam")

erlang = use_extension("@rules_gleam//gleam:extensions.bzl", "erlang")
use_repo(erlang, "erlang")

register_toolchains(
    "@erlang//:all",
    "@gleam//:all",
)
```

Then in your BUILD.bazel:

```python
load("@rules_gleam//gleam:defs.bzl", "gleam_binary", "gleam_library", "gleam_test")
```