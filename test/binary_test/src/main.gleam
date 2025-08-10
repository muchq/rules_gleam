import gleam/io
import greet

pub fn main() {
  // For now, just use a fixed greeting
  io.println(greet.hello("World"))
  io.println(greet.shout("Bazel rules for Gleam are working!"))
}