import gleam/io
import gleam/string
import gleam/int

pub fn main() {
  io.println("Starting web server on port 8080...")
  io.println("Server configuration:")
  io.println("  - Host: localhost")
  io.println("  - Port: 8080")
  io.println("  - Max connections: " <> int.to_string(get_max_connections()))
  
  // Simulate server running
  io.println("\nServer is running! Press Ctrl+C to stop.")
  io.println("Handling requests...")
  
  // Process some example requests
  handle_request("/", "GET")
  handle_request("/api/users", "GET")
  handle_request("/api/users/123", "GET")
  handle_request("/api/users", "POST")
}

pub fn get_max_connections() -> Int {
  100
}

pub fn handle_request(path: String, method: String) -> String {
  let response = case path, method {
    "/", "GET" -> "200 OK - Welcome to the home page!"
    "/api/users", "GET" -> "200 OK - User list: [Alice, Bob, Charlie]"
    "/api/users", "POST" -> "201 Created - New user created"
    _, "GET" -> "404 Not Found - Path " <> path <> " not found"
    _, _ -> "405 Method Not Allowed - " <> method <> " not supported"
  }
  
  io.println("[" <> method <> "] " <> path <> " -> " <> response)
  response
}

pub fn format_response(status: Int, body: String) -> String {
  "HTTP/1.1 " <> int.to_string(status) <> "\n\n" <> body
}