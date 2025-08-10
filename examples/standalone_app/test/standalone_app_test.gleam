import gleeunit
import gleeunit/should
import app

pub fn main() {
  gleeunit.main()
}

pub fn calculate_sum_test() {
  app.calculate_sum([1, 2, 3, 4, 5])
  |> should.equal(15)
  
  app.calculate_sum([])
  |> should.equal(0)
  
  app.calculate_sum([10])
  |> should.equal(10)
}

pub fn double_all_test() {
  app.double_all([1, 2, 3])
  |> should.equal([2, 4, 6])
  
  app.double_all([])
  |> should.equal([])
  
  app.double_all([5])
  |> should.equal([10])
}