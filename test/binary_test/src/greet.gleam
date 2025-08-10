import gleam/string

pub fn hello(name: String) -> String {
  "Hello, " <> name <> "!"
}

pub fn shout(message: String) -> String {
  string.uppercase(message)
}