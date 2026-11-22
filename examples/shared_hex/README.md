# Shared Hex dependencies

`alpha` explicitly declares `gleam_stdlib`; `beta` imports the same version from a
manifest. Both modules resolve to one generated target in `gleam_packages`:

```sh
bazel build //:shared
```

From the repository root, run `python3 test/integration/shared_hex.py` to build
this fixture in a temporary workspace and exercise conflicting versions,
checksums, metadata, root authority, missing dependencies, cycles and non-Hex
manifest entries. CI runs this on Linux and macOS. The script changes only its
temporary copy of the fixture.
