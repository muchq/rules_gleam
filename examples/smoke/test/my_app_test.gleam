import gleeunit
import gleeunit/should
import my_app

pub fn main() {
  gleeunit.main()
}

pub fn greeting_test() {
  my_app.greeting()
  |> should.equal("Hello from my_app!")
}
