"""Public API for the Gleam Bazel rules."""

# Original rules (kept for backward compatibility)
load("//gleam/private:gleam_binary.bzl", _gleam_binary_v1 = "gleam_binary")
load("//gleam/private:gleam_library.bzl", _gleam_library_v1 = "gleam_library")
load("//gleam/private:gleam_test.bzl", _gleam_test_v1 = "gleam_test")

# New improved v2 rules
load("//gleam/private:gleam_library_v2.bzl", _gleam_library_v2 = "gleam_library_v2")
load("//gleam/private:gleam_binary_v2.bzl", _gleam_binary_v2 = "gleam_binary_v2")
load("//gleam/private:gleam_test_v2.bzl", _gleam_test_v2 = "gleam_test")

# Export the v2 rules as the main API
gleam_library = _gleam_library_v2
gleam_binary = _gleam_binary_v2
gleam_test = _gleam_test_v2

# Keep v1 rules available for migration
gleam_library_v1 = _gleam_library_v1
gleam_binary_v1 = _gleam_binary_v1
gleam_test_v1 = _gleam_test_v1
