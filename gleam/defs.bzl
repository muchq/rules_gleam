"""Public API for the Gleam Bazel rules."""

# Load rule implementations from their private .bzl files.
load("//gleam/private:gleam_library.bzl", _gleam_library_rule = "gleam_library")
load("//gleam/private:gleam_binary.bzl", _gleam_binary_rule = "gleam_binary")
load("//gleam/private:gleam_test.bzl", _gleam_test_rule = "gleam_test")

# Re-export the rules and the module extension for users of this .bzl file.
gleam_library = _gleam_library_rule
gleam_binary = _gleam_binary_rule
gleam_test = _gleam_test_rule
