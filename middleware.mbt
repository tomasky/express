///|
/// Default maximum body size: 1 MiB.
const DEFAULT_BODY_LIMIT : Int32 = 1024 * 1024

///|
/// Parses `application/json` request bodies into `req.json_body()` and also
/// keeps the raw text in `req.body()`.
pub fn express_json(limit? : Int32) -> Middleware {
  let max_size = match limit {
    Some(value) => value
    None => DEFAULT_BODY_LIMIT
  }
  fn(req, res, next) {
    if res.is_aborted() {
      return
    }
    let content_type = req.header("content-type").to_lower()
    let is_json = content_type.has_prefix("application/json") ||
      content_type.contains("+json")
    if !is_json || !has_request_body(req) {
      next.proceed()
      return
    }
    if parse_content_length(req.header("content-length")) > max_size {
      res.status(413).send("Payload Too Large")
      return
    }
    read_body(req, res, max_size, fn(body, ok) {
      if res.is_aborted() {
        return
      }
      if !ok {
        res.status(413).send("Payload Too Large")
        return
      }
      req.set_body(body)
      if body == "" {
        next.proceed()
        return
      }
      let parsed : Json? = Some(@json.parse(body)) catch { _ => None }
      match parsed {
        Some(value) => {
          req.set_json_body(Some(value))
          next.proceed()
        }
        None => res.status(400).send("Invalid JSON")
      }
    })
  }
}

///|
/// Parses `application/x-www-form-urlencoded` bodies into `req.form_map()`.
pub fn express_urlencoded(limit? : Int32) -> Middleware {
  let max_size = match limit {
    Some(value) => value
    None => DEFAULT_BODY_LIMIT
  }
  fn(req, res, next) {
    if res.is_aborted() {
      return
    }
    let content_type = req.header("content-type").to_lower()
    if !content_type.has_prefix("application/x-www-form-urlencoded") ||
      !has_request_body(req) {
      next.proceed()
      return
    }
    if parse_content_length(req.header("content-length")) > max_size {
      res.status(413).send("Payload Too Large")
      return
    }
    read_body(req, res, max_size, fn(body, ok) {
      if res.is_aborted() {
        return
      }
      if !ok {
        res.status(413).send("Payload Too Large")
        return
      }
      req.set_body(body)
      req.set_form(parse_urlencoded(body))
      next.proceed()
    })
  }
}

///|
/// Reads a `text/*` body into `req.body()`.
pub fn express_text(limit? : Int32) -> Middleware {
  let max_size = match limit {
    Some(value) => value
    None => DEFAULT_BODY_LIMIT
  }
  fn(req, res, next) {
    if res.is_aborted() {
      return
    }
    let content_type = req.header("content-type").to_lower()
    if !content_type.has_prefix("text/") || !has_request_body(req) {
      next.proceed()
      return
    }
    if parse_content_length(req.header("content-length")) > max_size {
      res.status(413).send("Payload Too Large")
      return
    }
    read_body(req, res, max_size, fn(body, ok) {
      if res.is_aborted() {
        return
      }
      if !ok {
        res.status(413).send("Payload Too Large")
        return
      }
      req.set_body(body)
      next.proceed()
    })
  }
}

///|
/// Alias for `express_text`.
pub fn express_raw(limit? : Int32) -> Middleware {
  match limit {
    Some(value) => express_text(limit=value)
    None => express_text()
  }
}

///|
/// Serves files below `root`. Directories are resolved to `index.html`.
/// Missing files fall through to the next middleware.
pub fn express_static(root : String) -> Middleware {
  fn(req, res, next) {
    let http_method = req.http_method()
    if http_method != "GET" && http_method != "HEAD" {
      next.proceed()
      return
    }
    let decoded = percent_decode_path(req.path())
    if is_unsafe_path(decoded) {
      res.status(403).send("Forbidden")
      return
    }
    let mut full_path = join_path(root, decoded)
    let kind = fs_kind(full_path)
    if kind == 2 {
      full_path = join_path(full_path, "index.html")
    } else if kind == 0 {
      next.proceed()
      return
    }
    if fs_kind(full_path) != 1 {
      next.proceed()
      return
    }
    let data = fs_read_file(full_path)
    ignore(res.set("Content-Type", mime_type(full_path)))
    res.send_bytes(data)
  }
}

///|
/// Permissive CORS middleware, including preflight responses.
pub fn cors() -> Middleware {
  fn(req, res, next) {
    ignore(res.set("Access-Control-Allow-Origin", "*"))
    if req.http_method() == "OPTIONS" {
      ignore(
        res.set(
          "Access-Control-Allow-Methods", "GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS",
        ),
      )
      let requested = req.header("access-control-request-headers")
      let headers = if requested == "" { "Content-Type" } else { requested }
      ignore(res.set("Access-Control-Allow-Headers", headers))
      res.status(204).send_empty()
    } else {
      next.proceed()
    }
  }
}

///|
/// Minimal request logger.
pub fn logger() -> Middleware {
  fn(req, _res, next) {
    println(req.http_method() + " " + req.path())
    next.proceed()
  }
}

// ---------- helpers ----------

///|
fn has_request_body(req : Req) -> Bool {
  let http_method = req.http_method()
  if http_method == "GET" || http_method == "HEAD" {
    return false
  }
  if parse_content_length(req.header("content-length")) > 0 {
    return true
  }
  req.header("transfer-encoding") != ""
}

///|
fn parse_content_length(value : String) -> Int32 {
  if value == "" {
    return 0
  }
  let mut size = 0
  for ch in value {
    let digit = ch.to_int() - 48
    if digit < 0 || digit > 9 {
      return 0
    }
    size = size * 10 + digit
  }
  size
}

///|
fn is_unsafe_path(path : String) -> Bool {
  for segment in split_path(path) {
    if segment == ".." {
      return true
    }
  }
  false
}

///|
fn mime_type(path : String) -> String {
  let extension = match path.rev_split_once(".") {
    Some((_, ext)) => ext.to_owned().to_lower()
    None => ""
  }
  match extension {
    "html" | "htm" => "text/html; charset=utf-8"
    "css" => "text/css; charset=utf-8"
    "js" | "mjs" => "application/javascript; charset=utf-8"
    "json" | "map" => "application/json; charset=utf-8"
    "txt" | "md" => "text/plain; charset=utf-8"
    "xml" => "application/xml; charset=utf-8"
    "svg" => "image/svg+xml"
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "ico" => "image/x-icon"
    "woff" => "font/woff"
    "woff2" => "font/woff2"
    "ttf" => "font/ttf"
    "wasm" => "application/wasm"
    "pdf" => "application/pdf"
    "zip" => "application/zip"
    _ => "application/octet-stream"
  }
}
