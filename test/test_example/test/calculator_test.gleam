import gleeunit
import gleeunit/should
import calculator

pub fn main() {
  gleeunit.main()
}

pub fn add_test() {
  calculator.add(1, 2)
  |> should.equal(3)
}

pub fn subtract_test() {
  calculator.subtract(5, 3)
  |> should.equal(2)
}

pub fn multiply_test() {
  calculator.multiply(4, 5)
  |> should.equal(20)
}

pub fn divide_test() {
  calculator.divide(10, 2)
  |> should.equal(Ok(5))
  
  calculator.divide(10, 0)
  |> should.equal(Error("Division by zero"))
}