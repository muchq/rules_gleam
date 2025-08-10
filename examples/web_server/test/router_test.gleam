import gleeunit
import gleeunit/should
import router
import gleam/option.{None, Some}

pub fn main() {
  gleeunit.main()
}

pub fn new_router_test() {
  let r = router.new()
  router.find_handler(r, "/")
  |> should.equal(None)
}

pub fn add_route_test() {
  let r = 
    router.new()
    |> router.add_route("/", fn() { "Home" })
    |> router.add_route("/about", fn() { "About" })
  
  case router.find_handler(r, "/") {
    Some(handler) -> handler() |> should.equal("Home")
    None -> panic as "Handler not found"
  }
  
  case router.find_handler(r, "/about") {
    Some(handler) -> handler() |> should.equal("About")
    None -> panic as "Handler not found"
  }
}

pub fn handle_found_test() {
  let r = 
    router.new()
    |> router.add_route("/test", fn() { "Test page" })
  
  router.handle(r, "/test")
  |> should.equal("Test page")
}

pub fn handle_not_found_test() {
  let r = router.new()
  
  router.handle(r, "/missing")
  |> should.equal("404 Not Found")
}