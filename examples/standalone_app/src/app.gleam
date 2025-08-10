import gleam/io
import gleam/list
import gleam/int

pub fn main() {
  io.println("🚀 Standalone Gleam App with Bazel!")
  io.println("")
  
  let numbers = [1, 2, 3, 4, 5]
  io.println("Numbers: " <> list_to_string(numbers))
  
  let sum = calculate_sum(numbers)
  io.println("Sum: " <> int.to_string(sum))
  
  let doubled = double_all(numbers)
  io.println("Doubled: " <> list_to_string(doubled))
  
  io.println("")
  io.println("✅ App completed successfully!")
}

pub fn calculate_sum(numbers: List(Int)) -> Int {
  list.fold(numbers, 0, fn(acc, n) { acc + n })
}

pub fn double_all(numbers: List(Int)) -> List(Int) {
  list.map(numbers, fn(n) { n * 2 })
}

fn list_to_string(numbers: List(Int)) -> String {
  numbers
  |> list.map(int.to_string)
  |> list.intersperse(", ")
  |> list.fold("", fn(acc, s) { acc <> s })
  |> fn(s) { "[" <> s <> "]" }
}