///|
/// Core-library checks: the routing primitive, the URL decoders and the static
/// file path guard. The express package had no tests of its own; these cover
/// the parts where a regression is silent (a path that matches too much) or
/// dangerous (a path that escapes the document root).
///
/// Raw-string tests use `#|` so backslashes survive.

///|
test "percent decoding keeps literal plus in a path" {
  assert_eq(percent_decode_path("a+b"), "a+b")
  assert_eq(percent_decode("a+b"), "a b")
}

///|
test "percent decoding round trips percent_encode" {
  let samples : Array[String] = [
    "hello world", "a+b", "100%", "/slash/", "ünïcødé", "", "~-._",
  ]
  for sample in samples {
    assert_eq(percent_decode(percent_encode(sample)), sample)
  }
}

///|
test "truncated and invalid escapes stay literal" {
  // A '%' with fewer than two following characters, or with non-hex digits,
  // must not be consumed and must not crash.
  assert_eq(percent_decode_path("%"), "%")
  assert_eq(percent_decode_path("%4"), "%4")
  assert_eq(percent_decode_path("ab%4"), "ab%4")
  assert_eq(percent_decode_path("%zz"), "%zz")
  assert_eq(percent_decode_path("%4z"), "%4z")
  // A valid escape at the very end of the string is still decoded.
  assert_eq(percent_decode_path("a%41"), "aA")
  assert_eq(percent_decode_path("%41"), "A")
}

///|
test "percent decoding accepts both hex cases" {
  assert_eq(percent_decode_path("%2f"), "/")
  assert_eq(percent_decode_path("%2F"), "/")
  assert_eq(percent_decode_path("%7e"), "~")
}

///|
test "query parsing decodes keys and values" {
  let query = parse_query("a=1&b=hello+world&c=%2F&flag&empty=")
  assert_eq(query.get("a"), Some("1"))
  assert_eq(query.get("b"), Some("hello world"))
  assert_eq(query.get("c"), Some("/"))
  assert_eq(query.get("flag"), Some(""))
  assert_eq(query.get("empty"), Some(""))
  assert_eq(query.get("missing"), None)
}

///|
test "cookie parsing trims and decodes" {
  let cookies = parse_cookies("a=1; b=hello%20world ; c")
  assert_eq(cookies.get("a"), Some("1"))
  assert_eq(cookies.get("b"), Some("hello world"))
  assert_eq(cookies.get("c"), Some(""))
}

///|
test "static pattern matching is case insensitive and slash tolerant" {
  let pattern = make_pattern("/Users/42")
  assert_eq(pattern.match_static_path("/users/42", false), Some(true))
  assert_eq(pattern.match_static_path("/USERS/42/", false), Some(true))
  // A slot makes the fast path decline so the caller falls back to
  // match_parts.
  let slotted = make_pattern("/users/:id")
  assert_eq(slotted.match_static_path("/users/42", false), None)
  // A splat declines too.
  let splatted = make_pattern("/files/*")
  assert_eq(splatted.match_static_path("/files/a", false), None)
}

///|
test "static fast path declines patterns with slots" {
  let pattern = make_pattern("/a/:b/c")
  assert_eq(pattern.match_static_path("/a/x/c", false), None)
}

///|
test "static fast path matches exact and prefix" {
  let pattern = make_pattern("/health")
  assert_eq(pattern.match_static_path("/health", false), Some(true))
  assert_eq(pattern.match_static_path("/health/", false), Some(true))
  assert_eq(pattern.match_static_path("/health/live", false), Some(false))
  assert_eq(pattern.match_static_path("/health/live", true), Some(true))
  assert_eq(pattern.match_static_path("/healthz", false), Some(false))
}

///|
test "split_path ignores empty segments" {
  assert_eq(split_path("/a//b/"), ["a", "b"])
  assert_eq(split_path(""), [])
  assert_eq(split_path("/"), [])
}

///|
test "wildcard captures the remaining segments" {
  let pattern = make_pattern("/files/*")
  let params = pattern.match_parts(["files", "a", "b"], false)
  assert_true(params is Some(_))
  // Express names a bare `*` wildcard `0`, and so does this pattern.
  match params {
    Some(pairs) => assert_eq(pairs, [("0", "a/b")])
    None => fail("expected a match")
  }
  // A named wildcard keeps its name.
  match make_pattern("/files/*rest").match_parts(["files", "a", "b"], false) {
    Some(pairs) => assert_eq(pairs, [("rest", "a/b")])
    None => fail("expected a match")
  }
}

///|
test "slot captures one segment and decodes it" {
  let pattern = make_pattern("/user/:name")
  match pattern.match_parts(["user", "a%20b"], false) {
    Some(pairs) => assert_eq(pairs, [("name", "a b")])
    None => fail("expected a match")
  }
}

///|
/// The decoded path reaches C as a NUL-terminated string, so a `%00` would
/// truncate it there. A backslash is not a separator on this side but is on
/// Windows. Both must be refused, not just a `..` segment.
test "static guard rejects NUL, backslash and dot-dot" {
  assert_true(is_unsafe_path(percent_decode_path("/a%00b")))
  assert_true(is_unsafe_path(percent_decode_path("/..%5c..%5cetc")))
  assert_true(is_unsafe_path(percent_decode_path("/..%2fetc%2fpasswd")))
  assert_true(is_unsafe_path(percent_decode_path("/a/.%2e/b")))
  assert_true(is_unsafe_path("/../etc"))
}

///|
test "static guard accepts ordinary paths" {
  assert_false(is_unsafe_path(percent_decode_path("/safe/file.txt")))
  assert_false(is_unsafe_path(percent_decode_path("/a%20b/c")))
  assert_false(is_unsafe_path(percent_decode_path("/.../x")))
  assert_false(is_unsafe_path("/"))
}

///|
/// uWS writes header bytes verbatim, so a CR/LF in a value would end the
/// header block early and let the caller forge the rest of the response.
test "header breakout detection catches CRLF and NUL" {
  assert_true(has_header_breakout("a\r\nX-Injected: 1"))
  assert_true(has_header_breakout("a\r"))
  assert_true(has_header_breakout("a\n"))
  assert_true(has_header_breakout("a\u{0}b"))
  assert_false(has_header_breakout("text/html; charset=utf-8"))
  assert_false(has_header_breakout("https://example.com/a?b=c"))
  assert_false(has_header_breakout(""))
}
