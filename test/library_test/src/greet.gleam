import hello

pub fn greet(name: String) -> String {
  hello.hello() <> " Nice to meet you, " <> name
}

pub fn greet_loudly(name: String) -> String {
  hello.shout(greet(name))
}