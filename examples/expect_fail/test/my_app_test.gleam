import gleeunit
import gleeunit/should
import my_app

pub fn main() {
  gleeunit.main()
}

// Deliberately wrong: my_app.greeting() never returns this string. This assertion exists to
// prove gleam_test actually fails `bazel test` on a genuinely failing test, rather than only
// ever being exercised on happy-path examples elsewhere in this repo.
pub fn greeting_test() {
  my_app.greeting()
  |> should.equal("This assertion is deliberately wrong.")
}
