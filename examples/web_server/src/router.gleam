import gleam/list
import gleam/string
import gleam/option.{type Option, None, Some}

pub type Route {
  Route(path: String, handler: fn() -> String)
}

pub type Router {
  Router(routes: List(Route))
}

pub fn new() -> Router {
  Router(routes: [])
}

pub fn add_route(router: Router, path: String, handler: fn() -> String) -> Router {
  Router(routes: [Route(path, handler), ..router.routes])
}

pub fn find_handler(router: Router, path: String) -> Option(fn() -> String) {
  case list.find(router.routes, fn(route) { route.path == path }) {
    Ok(route) -> Some(route.handler)
    Error(_) -> None
  }
}

pub fn handle(router: Router, path: String) -> String {
  case find_handler(router, path) {
    Some(handler) -> handler()
    None -> "404 Not Found"
  }
}