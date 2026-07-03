import gleeunit
import gleeunit/should
import hermetic_erlang

pub fn main() {
  gleeunit.main()
}

pub fn greeting_test() {
  hermetic_erlang.greeting()
  |> should.equal("Hello from a hermetically-fetched Erlang/OTP!")
}
