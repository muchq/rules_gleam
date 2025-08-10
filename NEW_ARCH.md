# Gleam Bazel Rules - Proper Architecture

## Overview

The Gleam Bazel rules should follow Bazel best practices for compilation and linking, similar to how cc_library/cc_binary or java_library/java_binary work. The rules should "Just Work™" for Gleam developers without requiring knowledge of Erlang/OTP internals.

## Core Principles

1. **Compile Once**: Each source file should be compiled exactly once
2. **Proper Caching**: Bazel should cache compiled artifacts and reuse them
3. **Clear Separation**: Compilation (gleam_library) should be separate from packaging (gleam_binary)
4. **Deployable Artifacts**: Binaries should produce self-contained, deployable archives
5. **Gleam-First API**: Users shouldn't need to know about BEAM, OTP, or Erlang details
6. **Test Continuously**: Each phase includes tests to verify correctness

## User Experience Goals

A Gleam developer should be able to:
- Write `gleam_library` and `gleam_binary` rules that look like any other Bazel rules
- Deploy their application with a simple `tar -xzf app.tar.gz && ./run.sh`
- Run tests with `bazel test` without configuring Erlang paths
- Use Gleam packages from Hex seamlessly
- Never see or think about BEAM files, ebin directories, or OTP releases

## Rule Architecture

### gleam_library

**Purpose**: Compile Gleam source files into reusable library

**User-Facing Attributes**:
```python
gleam_library(
    name = "my_lib",
    srcs = ["src/foo.gleam", "src/bar.gleam"],
    deps = [":other_lib"],
    gleam_toml = "gleam.toml",  # Optional
)
```

**Implementation Details** (hidden from users):
- Compiles to BEAM bytecode
- Caches compilation artifacts
- Provides transitive dependencies

### gleam_binary

**Purpose**: Create an executable from Gleam code

**User-Facing Attributes**:
```python
gleam_binary(
    name = "my_app",
    srcs = ["src/main.gleam"],  # Optional if using deps with main
    deps = [":my_lib"],
)
```

**What Users Get**:
- `bazel run //my_app` - runs the application
- `bazel build //my_app` - produces `my_app_deploy.tar.gz`
- Extract and run anywhere with Erlang installed

### gleam_test

**Purpose**: Run Gleam tests

**User-Facing Attributes**:
```python
gleam_test(
    name = "my_test",
    srcs = glob(["test/*.gleam"]),
    deps = [":my_lib"],
)
```

## Implementation Plan

### Phase 1: Fix Erlang Detection
**Goal**: Detect Erlang correctly on all systems

**Implementation**:
1. Rewrite `local_erlang_repository.bzl` to:
   - Use `erl -eval 'io:format("~s", [code:root_dir()]), halt().' -noshell`
   - Support asdf, homebrew, nix, and system installations
   - Gracefully handle different directory structures

**Tests**:
- Create test script that verifies detection works
- Test with mock Erlang installations
- Verify on CI with different Erlang setups

### Phase 2: Rewrite gleam_library
**Goal**: Compile libraries once, cache properly

**Implementation**:
1. Create new `gleam_library` implementation that:
   - Compiles only its own sources
   - Uses dependency artifacts via Gleam's build system
   - Outputs structured build directory
   - Provides proper provider for downstream rules

**Tests**:
- Simple library compilation test
- Library with dependencies test
- Verify no recompilation on second build
- Check that changing a dep triggers recompilation

### Phase 3: Rewrite gleam_binary  
**Goal**: Package applications for easy deployment

**Implementation**:
1. Create new `gleam_binary` that:
   - Reuses compiled library artifacts
   - Creates self-contained directory structure
   - Generates runner script that finds Erlang automatically
   - Produces tar.gz for deployment

**Tests**:
- Simple binary test (hello world)
- Binary with dependencies test
- Deploy and run archive on different machine
- Verify runner script works with various Erlang installations

### Phase 4: Rewrite gleam_test
**Goal**: Make testing seamless

**Implementation**:
1. Create new `gleam_test` that:
   - Compiles test sources against library artifacts
   - Runs tests with proper paths set up
   - Returns correct exit codes
   - Works with gleeunit out of the box

**Tests**:
- Simple test execution
- Test with library dependencies
- Test failure propagation
- Test with data files

### Phase 5: Polish and Examples
**Goal**: Ensure great developer experience

**Implementation**:
1. Add comprehensive examples:
   - Hello world console app
   - Web server with Mist
   - Library with multiple modules
   - Multi-package workspace
2. Add helpful error messages
3. Write user documentation

**Tests**:
- Build all examples
- Deploy and run example binaries
- Run all example tests

## Benefits of This Architecture

1. **Gleam-Native**: Developers work with Gleam concepts, not Erlang/OTP
2. **Performance**: Dependencies compiled once, cached by Bazel
3. **Deployability**: Simple tar.gz that works anywhere
4. **Maintainability**: Clear separation of concerns
5. **Familiarity**: Works like other Bazel rules (Java, Go, etc.)

## Implementation Notes

- Each phase builds on the previous one
- Tests are written and pass before moving to next phase
- Internal complexity is hidden from users
- Error messages guide users to solutions
- Documentation focuses on Gleam use cases, not Erlang details