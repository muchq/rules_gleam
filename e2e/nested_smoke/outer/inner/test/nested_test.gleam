import gleeunit
import gleeunit/should
import lib

pub fn main() {
  gleeunit.main()
}

pub fn greeting_is_correct_test() {
  lib.greeting()
  |> should.equal("Hello from nested_smoke_test!")
}
