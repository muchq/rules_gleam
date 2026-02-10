"""Public API for the Gleam Bazel rules."""

load("//gleam/private:gleam_binary.bzl", _gleam_binary_rule = "gleam_binary")
load("//gleam/private:gleam_library.bzl", _GleamPackageInfo = "GleamPackageInfo", _gleam_library_rule = "gleam_library")
load("//gleam/private:gleam_test.bzl", _gleam_test_rule = "gleam_test")

gleam_library = _gleam_library_rule
gleam_binary = _gleam_binary_rule
gleam_test = _gleam_test_rule
GleamPackageInfo = _GleamPackageInfo
