import gazelle_smoke
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn greeting_test() {
  gazelle_smoke.greeting()
  |> should.equal("Hello from a gazelle-generated BUILD file!")
}
