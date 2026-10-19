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
/// With `extended` the nested form (`a[b]=1`) is also parsed into
/// `req.form_json()`, like `express.urlencoded({ extended: true })`.
pub fn express_urlencoded(limit? : Int32, extended? : Bool) -> Middleware {
  let max_size = match limit {
    Some(value) => value
    None => DEFAULT_BODY_LIMIT
  }
  let extended = match extended {
    Some(value) => value
    None => false
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
      if extended {
        req.set_form_json(Some(parse_urlencoded_nested(body)))
      }
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
/// Reads a binary body into `req.body_bytes()`, and its lossy text form into
/// `req.body()`, like `express.raw()`. The raw bytes are always binary safe.
pub fn express_raw(limit? : Int32) -> Middleware {
  let max_size = match limit {
    Some(value) => value
    None => DEFAULT_BODY_LIMIT
  }
  fn(req, res, next) {
    if res.is_aborted() {
      return
    }
    let content_type = req.header("content-type").to_lower()
    if !content_type.has_prefix("application/octet-stream") ||
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
      next.proceed()
    })
  }
}

///|
/// Serves files below `root`, like `express.static`: `Content-Type`, `ETag`,
/// `Last-Modified`, byte ranges and `Cache-Control` come from `res.send_file`.
/// Missing files fall through to the next middleware unless `fallthrough` is
/// disabled.
pub fn express_static(root : String, options? : FileOptions) -> Middleware {
  let options = match options {
    Some(value) => value
    None => FileOptions::default()
  }
  fn(req, res, next) {
    if res.is_aborted() {
      return
    }
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
    let mut kind = fs_kind(full_path)
    if kind == 2 {
      if options.redirect && !req.path().has_suffix("/") {
        let original = req.original_url()
        let path_only = match original.find("?") {
          Some(index) => original[:index].to_owned()
          None => original
        }
        let query = original[path_only.length():].to_owned()
        let url = encode_url(path_only + "/") + query
        let body = "<p>Redirecting to <a href=\"" +
          escape_html(url) +
          "\">" +
          escape_html(url) +
          "</a></p>"
        ignore(res.status(301).set("Location", url))
        ignore(res.set("Content-Type", "text/html; charset=UTF-8"))
        ignore(res.set("Content-Length", body.length().to_string()))
        res.send(body)
        return
      }
      if options.index != "" {
        let index_file = join_path(full_path, options.index)
        if fs_kind(index_file) == 1 {
          full_path = index_file
          kind = 1
        }
      }
    }
    if kind != 1 {
      for extension in options.extensions {
        let candidate = full_path + "." + extension
        if fs_kind(candidate) == 1 {
          full_path = candidate
          kind = 1
          break
        }
      }
    }
    if kind != 1 {
      if options.fallthrough {
        next.proceed()
      } else {
        res.status(404).send("Not Found")
      }
      return
    }
    if has_dotfile_segment(full_path) && options.dotfiles != "allow" {
      if options.dotfiles == "deny" {
        res.status(403).send("Forbidden")
      } else if options.fallthrough {
        next.proceed()
      } else {
        res.status(404).send("Not Found")
      }
      return
    }
    res.send_file(full_path, options~)
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
/// MIME type for a file extension, without parameters. `""` when unknown.
pub fn mime_by_extension(extension : String) -> String {
  match extension {
    "html" | "htm" => "text/html"
    "css" => "text/css"
    "js" | "mjs" => "application/javascript"
    "json" | "map" => "application/json"
    "txt" | "md" => "text/plain"
    "xml" => "application/xml"
    "svg" => "image/svg+xml"
    "png" => "image/png"
    "jpg" | "jpeg" => "image/jpeg"
    "gif" => "image/gif"
    "webp" => "image/webp"
    "ico" => "image/x-icon"
    "woff" => "font/woff"
    "woff2" => "font/woff2"
    "ttf" => "font/ttf"
    "bin" => "application/octet-stream"
    "text" => "text/plain"
    "wasm" => "application/wasm"
    "pdf" => "application/pdf"
    "zip" => "application/zip"
    _ => ""
  }
}

///|
/// The charset `mime-types` appends for a type: UTF-8 for `text/*` and for
/// the JSON/JavaScript types, nothing otherwise.
fn mime_default_charset(mime : String) -> String {
  if mime.has_prefix("text/") {
    "utf-8"
  } else if mime == "application/json" ||
    mime == "application/javascript" ||
    mime == "application/xml" {
    "utf-8"
  } else {
    ""
  }
}

///|
/// Resolves an extension or media type to a full `Content-Type` value the way
/// `mime-types.contentType()` does. Unknown input is returned unchanged.
fn mime_content_type(value : String) -> String {
  let mime = if value.contains("/") {
    value
  } else {
    mime_by_extension(value.to_lower())
  }
  if mime == "" {
    return value
  }
  if mime.contains("charset") {
    return mime
  }
  let charset = mime_default_charset(mime)
  if charset == "" {
    mime
  } else {
    mime + "; charset=" + charset
  }
}

///|
/// Maps a negotiation token (`html`, `text/html`) to a media type. `""` when
/// the token is neither a known extension nor a media type.
fn mime_for_type_name(name : String) -> String {
  if name.contains("/") {
    name
  } else {
    mime_by_extension(name.to_lower())
  }
}

///|
/// MIME type for a file path, with the charset used by `express.static`.
pub fn mime_type(path : String) -> String {
  let extension = match path.rev_split_once(".") {
    Some((_, ext)) => ext.to_owned().to_lower()
    None => ""
  }
  let mime = mime_by_extension(extension)
  if mime == "" {
    return "application/octet-stream"
  }
  let charset = mime_default_charset(mime)
  if charset == "" {
    mime
  } else {
    mime + "; charset=" + charset
  }
}
