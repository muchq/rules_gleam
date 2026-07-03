import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

/// Fixed for simplicity in this example. A real service should prefer binding to
/// port 0 (letting the OS pick a free port) and using `mist.after_start` to learn
/// the actual bound port, to avoid collisions when running many instances or tests
/// in parallel on the same machine.
const port = 34817

pub fn main() {
  let assert Ok(_) =
    handle_request
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

pub fn handle_request(_req: Request(Connection)) -> Response(ResponseData) {
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(greeting())))
}

pub fn greeting() -> String {
  "Hello from web_service!"
}
