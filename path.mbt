///|
/// Decodes percent-encoded bytes in a URL query component. `+` is treated as
/// a space, matching `application/x-www-form-urlencoded`.
pub fn percent_decode(input : String) -> String {
  percent_decode_with(input, true)
}

///|
/// Same as `percent_decode`, but leaves `+` untouched. Use this for path
/// segments, where `+` is a literal plus sign.
pub fn percent_decode_path(input : String) -> String {
  percent_decode_with(input, false)
}

///|
fn percent_decode_with(input : String, plus_as_space : Bool) -> String {
  let needs_work = input.contains("%") || (plus_as_space && input.contains("+"))
  if !needs_work {
    return input
  }
  let src = @utf8.encode(input)
  let out : Array[Byte] = []
  let mut i = 0
  let mut changed = false
  while i < src.length() {
    let b = src[i].to_int()
    if b == 37 && i + 2 < src.length() {
      let hi = hex_digit(src[i + 1].to_int())
      let lo = hex_digit(src[i + 2].to_int())
      if hi >= 0 && lo >= 0 {
        out.push((hi * 16 + lo).to_byte())
        i = i + 3
        changed = true
        continue
      }
    }
    if b == 43 && plus_as_space {
      out.push((32 : Int32).to_byte())
      changed = true
    } else {
      out.push(b.to_byte())
    }
    i = i + 1
  }
  if !changed {
    return input
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
fn hex_digit(v : Int32) -> Int32 {
  if v >= 48 && v <= 57 {
    v - 48
  } else if v >= 65 && v <= 70 {
    v - 55
  } else if v >= 97 && v <= 102 {
    v - 87
  } else {
    -1
  }
}

///|
/// Percent-encodes a value for use in a query string or cookie, keeping the
/// unreserved characters from RFC 3986 untouched.
pub fn percent_encode(input : String) -> String {
  let bytes = @utf8.encode(input)
  let sb = StringBuilder()
  let mut i = 0
  while i < bytes.length() {
    let b = bytes[i].to_int()
    let safe = (b >= 48 && b <= 57) ||
      (b >= 65 && b <= 90) ||
      (b >= 97 && b <= 122) ||
      b == 45 ||
      b == 95 ||
      b == 46 ||
      b == 126
    if safe {
      sb.write_char(b.unsafe_to_char())
    } else {
      sb.write_string("%")
      sb.write_char(hex_char(b / 16))
      sb.write_char(hex_char(b % 16))
    }
    i = i + 1
  }
  sb.to_string()
}

///|
fn hex_char(value : Int32) -> Char {
  if value < 10 {
    (48 + value).unsafe_to_char()
  } else {
    (55 + value).unsafe_to_char()
  }
}

///|
/// Parses a `Cookie` request header (`a=1; b=hello%20world`) into a map.
pub fn parse_cookies(raw : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for part in raw.split(";") {
    let pair = part.to_owned().trim().to_owned()
    if pair == "" {
      continue
    }
    match pair.split_once("=") {
      Some((name, value)) =>
        out.set(name.to_owned(), percent_decode(value.to_owned()))
      None => out.set(pair, "")
    }
  }
  out
}

///|
/// Parses a raw query string (`a=1&b=hello+world`) into a map.
pub fn parse_query(raw : String) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for part in raw.split("&") {
    let pair = part.to_owned()
    if pair == "" {
      continue
    }
    match pair.split_once("=") {
      Some((key, value)) =>
        out.set(
          percent_decode(key.to_owned()),
          percent_decode(value.to_owned()),
        )
      None => out.set(percent_decode(pair), "")
    }
  }
  out
}

///|
/// Parses an `application/x-www-form-urlencoded` body. This is the same
/// grammar as a query string.
pub fn parse_urlencoded(raw : String) -> Map[String, String] {
  parse_query(raw)
}

///|
/// Node of the nested form tree built by `parse_urlencoded_nested`.
priv enum FormNode {
  FormLeaf(String)
  FormList(Array[FormNode])
  FormMap(Map[String, FormNode])
}

///|
/// Parses an `application/x-www-form-urlencoded` body with bracketed names
/// (`a[b]=1&a[]=2&a[0]=3`) into nested JSON, mirroring the `extended` mode of
/// `express.urlencoded`.
pub fn parse_urlencoded_nested(raw : String) -> Json {
  let root : Map[String, FormNode] = Map([])
  for part in raw.split("&") {
    let pair = part.to_owned()
    if pair == "" {
      continue
    }
    let (raw_key, raw_value) = match pair.split_once("=") {
      Some((key, value)) => (key.to_owned(), value.to_owned())
      None => (pair, "")
    }
    let segments = form_key_segments(percent_decode(raw_key))
    if segments.length() == 0 || segments[0] == "" {
      continue
    }
    let head = segments[0]
    if segments.length() == 1 {
      root.set(head, FormLeaf(percent_decode(raw_value)))
    } else {
      root.set(
        head,
        form_insert(root.get(head), segments, 1, percent_decode(raw_value)),
      )
    }
  }
  form_node_to_json(FormMap(root))
}

///|
/// Splits a bracketed form key: `a[b][c]` becomes `["a", "b", "c"]` and
/// `a[]` becomes `["a", ""]`.
fn form_key_segments(key : String) -> Array[String] {
  let segments : Array[String] = []
  let first = match key.find("[") {
    Some(index) => index
    None => key.length()
  }
  segments.push(key[:first].to_owned())
  let mut rest = key[first:].to_owned()
  while rest.has_prefix("[") {
    match rest.find("]") {
      Some(end) => {
        segments.push(rest[1:end].to_owned())
        rest = rest[end + 1:].to_owned()
      }
      None => break
    }
  }
  segments
}

///|
/// Inserts one value into the tree below `at`, creating lists for `[]` and
/// numeric keys and maps for named keys.
fn form_insert(
  current : FormNode?,
  segments : Array[String],
  at : Int32,
  value : String,
) -> FormNode {
  let key = segments[at]
  let last = at == segments.length() - 1
  if key == "" || is_numeric_key(key) {
    let items = match current {
      Some(FormList(items)) => items
      _ => []
    }
    if last {
      items.push(FormLeaf(value))
    } else {
      items.push(form_insert(None, segments, at + 1, value))
    }
    FormList(items)
  } else {
    let entries = match current {
      Some(FormMap(entries)) => entries
      _ => Map([])
    }
    if last {
      entries.set(key, FormLeaf(value))
    } else {
      entries.set(key, form_insert(entries.get(key), segments, at + 1, value))
    }
    FormMap(entries)
  }
}

///|
fn is_numeric_key(key : String) -> Bool {
  if key == "" {
    return false
  }
  for ch in key {
    let digit = ch.to_int() - 48
    if digit < 0 || digit > 9 {
      return false
    }
  }
  true
}

///|
fn form_node_to_json(node : FormNode) -> Json {
  match node {
    FormLeaf(value) => Json::string(value)
    FormList(items) => {
      let out : Array[Json] = []
      for item in items {
        out.push(form_node_to_json(item))
      }
      Json::array(out)
    }
    FormMap(entries) => {
      let out : Map[String, Json] = Map([])
      for pair in entries.iter() {
        out.set(pair.0, form_node_to_json(pair.1))
      }
      Json::object(out)
    }
  }
}

///|
/// A route pattern. Patterns are compiled once at registration time and
/// matched in MoonBit, while the actual HTTP transport stays in µWebSockets.
pub struct PathPattern {
  priv segments : Array[Segment]
  priv source : String
}

///|
priv enum Segment {
  Fixed(String)
  Slot(String)
  Splat(String)
}

///|
pub fn make_pattern(path : String) -> PathPattern {
  let segments : Array[Segment] = []
  for raw in path.split("/") {
    let segment = raw.to_owned()
    if segment == "" {
      continue
    }
    if segment.has_prefix(":") {
      segments.push(Slot(segment[1:].to_owned()))
    } else if segment.has_prefix("*") {
      let name = if segment.length() > 1 { segment[1:].to_owned() } else { "0" }
      segments.push(Splat(name))
    } else {
      segments.push(Fixed(segment))
    }
  }
  { segments, source: path, }
}

///|
/// The original pattern string, as used by `req.route.path`.
pub fn PathPattern::source(self : PathPattern) -> String {
  self.source
}

///|
pub fn PathPattern::is_any(self : PathPattern) -> Bool {
  self.segments.length() == 0
}

///|
/// Matches `path` against this pattern and returns captured parameters.
/// When `prefix` is true the pattern only has to match the beginning of the
/// path, which is how `app.use("/api", ...)` behaves.
pub fn PathPattern::match_path(
  self : PathPattern,
  path : String,
  prefix : Bool,
) -> Array[(String, String)]? {
  let parts = split_path(path)
  let params : Array[(String, String)] = []
  let mut pi = 0
  let mut si = 0
  while pi < self.segments.length() {
    match self.segments[pi] {
      Fixed(expected) => {
        if si >= parts.length() || !eq_segment_ci(parts[si], expected) {
          return None
        }
        si = si + 1
        pi = pi + 1
      }
      Slot(name) => {
        if si >= parts.length() {
          return None
        }
        params.push((name, percent_decode_path(parts[si])))
        si = si + 1
        pi = pi + 1
      }
      Splat(name) => {
        params.push((name, percent_decode_path(join_parts(parts, si))))
        si = parts.length()
        pi = pi + 1
      }
    }
  }
  if !prefix && si < parts.length() {
    return None
  }
  Some(params)
}

///|
/// ASCII case-insensitive segment equality without allocating the lowercased
/// copies that `to_lower` would make on every path match.
fn eq_segment_ci(a : String, b : String) -> Bool {
  let len = a.length()
  if len != b.length() {
    return false
  }
  let mut index = 0
  while index < len {
    let mut left = a.unsafe_get(index).to_int()
    let mut right = b.unsafe_get(index).to_int()
    if left != right {
      if left >= 65 && left <= 90 {
        left = left + 32
      }
      if right >= 65 && right <= 90 {
        right = right + 32
      }
      if left != right {
        return false
      }
    }
    index = index + 1
  }
  true
}

///|
/// Splits a URL path into non-empty segments. Repeated slashes and a trailing
/// slash are ignored, so `/users/` and `/users` match the same route.
pub fn split_path(path : String) -> Array[String] {
  let parts : Array[String] = []
  for raw in path.split("/") {
    let segment = raw.to_owned()
    if segment != "" {
      parts.push(segment)
    }
  }
  parts
}

///|
fn join_parts(parts : Array[String], from : Int32) -> String {
  let sb = StringBuilder()
  let mut i = from
  while i < parts.length() {
    if i > from {
      sb.write_string("/")
    }
    sb.write_string(parts[i])
    i = i + 1
  }
  sb.to_string()
}

///|
/// Returns the parameter names of a route pattern, in order.
pub fn parse_param_names(path : String) -> Array[String] {
  let pattern = make_pattern(path)
  let names : Array[String] = []
  for segment in pattern.segments {
    match segment {
      Slot(name) | Splat(name) => names.push(name)
      Fixed(_) => ()
    }
  }
  names
}

///|
/// HTTP reason phrase for the status codes used by the framework.
pub fn status_text(code : Int32) -> String {
  match code {
    100 => "Continue"
    101 => "Switching Protocols"
    102 => "Processing"
    103 => "Early Hints"
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    203 => "Non-Authoritative Information"
    204 => "No Content"
    205 => "Reset Content"
    206 => "Partial Content"
    207 => "Multi-Status"
    208 => "Already Reported"
    226 => "IM Used"
    300 => "Multiple Choices"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    305 => "Use Proxy"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    402 => "Payment Required"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    406 => "Not Acceptable"
    407 => "Proxy Authentication Required"
    408 => "Request Timeout"
    409 => "Conflict"
    410 => "Gone"
    411 => "Length Required"
    412 => "Precondition Failed"
    413 => "Payload Too Large"
    414 => "URI Too Long"
    415 => "Unsupported Media Type"
    416 => "Range Not Satisfiable"
    417 => "Expectation Failed"
    418 => "I'm a Teapot"
    421 => "Misdirected Request"
    422 => "Unprocessable Entity"
    423 => "Locked"
    424 => "Failed Dependency"
    425 => "Too Early"
    426 => "Upgrade Required"
    428 => "Precondition Required"
    429 => "Too Many Requests"
    431 => "Request Header Fields Too Large"
    451 => "Unavailable For Legal Reasons"
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    504 => "Gateway Timeout"
    505 => "HTTP Version Not Supported"
    506 => "Variant Also Negotiates"
    507 => "Insufficient Storage"
    508 => "Loop Detected"
    510 => "Not Extended"
    511 => "Network Authentication Required"
    _ => "Unknown"
  }
}
