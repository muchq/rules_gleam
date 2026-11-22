# expect_fail_otp_checksum

Pins the built-in OTP release with deliberately wrong checksums. Fetching `@local_config_erlang`
must fail with Bazel's checksum mismatch error; CI asserts that it does (see the
`.github/workflows/ci.yaml` step for this directory).
