import gleeunit
import gleeunit/should
import web_service

pub fn main() {
  gleeunit.main()
}

/// A unit test: pure-function-level, no network, no process spawning. See
/// e2e_test.sh for an integration/end-to-end test that actually starts the
/// server and makes a real HTTP request against it.
pub fn greeting_test() {
  web_service.greeting()
  |> should.equal("Hello from web_service!")
}

@external(erlang, "otp_name_test_ffi", "hpack_application_loads")
fn hpack_application_loads() -> Bool

pub fn hpack_otp_name_test() {
  hpack_application_loads()
  |> should.be_true()
}
