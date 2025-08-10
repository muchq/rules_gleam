import gleam/string

pub fn hello() -> String {
  "Hello from Gleam!"
}

pub fn shout(message: String) -> String {
  string.uppercase(message)
}