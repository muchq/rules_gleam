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
