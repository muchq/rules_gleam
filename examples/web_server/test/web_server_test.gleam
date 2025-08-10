import gleeunit
import gleeunit/should
import web_server

pub fn main() {
  gleeunit.main()
}

pub fn max_connections_test() {
  web_server.get_max_connections()
  |> should.equal(100)
}

pub fn handle_request_home_test() {
  web_server.handle_request("/", "GET")
  |> should.equal("200 OK - Welcome to the home page!")
}

pub fn handle_request_users_get_test() {
  web_server.handle_request("/api/users", "GET")
  |> should.equal("200 OK - User list: [Alice, Bob, Charlie]")
}

pub fn handle_request_users_post_test() {
  web_server.handle_request("/api/users", "POST")
  |> should.equal("201 Created - New user created")
}

pub fn handle_request_not_found_test() {
  web_server.handle_request("/nonexistent", "GET")
  |> should.equal("404 Not Found - Path /nonexistent not found")
}

pub fn handle_request_method_not_allowed_test() {
  web_server.handle_request("/", "DELETE")
  |> should.equal("405 Method Not Allowed - DELETE not supported")
}

pub fn format_response_test() {
  web_server.format_response(200, "OK")
  |> should.equal("HTTP/1.1 200\n\nOK")
}