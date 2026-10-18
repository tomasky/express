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
/// A route pattern. Patterns are compiled once at registration time and
/// matched in MoonBit, while the actual HTTP transport stays in µWebSockets.
pub struct PathPattern {
  priv segments : Array[Segment]
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
  { segments, }
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
        if si >= parts.length() || parts[si].to_lower() != expected.to_lower() {
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
    200 => "OK"
    201 => "Created"
    202 => "Accepted"
    204 => "No Content"
    206 => "Partial Content"
    301 => "Moved Permanently"
    302 => "Found"
    303 => "See Other"
    304 => "Not Modified"
    307 => "Temporary Redirect"
    308 => "Permanent Redirect"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    408 => "Request Timeout"
    409 => "Conflict"
    413 => "Payload Too Large"
    415 => "Unsupported Media Type"
    422 => "Unprocessable Entity"
    429 => "Too Many Requests"
    500 => "Internal Server Error"
    501 => "Not Implemented"
    502 => "Bad Gateway"
    503 => "Service Unavailable"
    _ => "Unknown"
  }
}
