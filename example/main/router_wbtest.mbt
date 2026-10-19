///|
test "root pattern matches every path when used as middleware" {
  let pattern = @lib.make_pattern("/")
  assert_true(pattern.is_any())
  assert_true(pattern.match_path("/", true) is Some(_))
  assert_true(pattern.match_path("/anything/here", true) is Some(_))
}

///|
test "static routes are case insensitive and ignore trailing slashes" {
  let pattern = @lib.make_pattern("/users/list")
  assert_true(pattern.match_path("/users/list", false) is Some(_))
  assert_true(pattern.match_path("/Users/List/", false) is Some(_))
  assert_true(pattern.match_path("/users", false) is None)
  assert_true(pattern.match_path("/users/list/extra", false) is None)
}

///|
test "named parameters capture decoded values" {
  let pattern = @lib.make_pattern("/users/:id/posts/:post_id")
  match pattern.match_path("/users/42/posts/hello%20world", false) {
    Some(params) => {
      assert_eq(params.length(), 2)
      assert_eq(params[0].0, "id")
      assert_eq(params[0].1, "42")
      assert_eq(params[1].0, "post_id")
      assert_eq(params[1].1, "hello world")
    }
    None => assert_true(false)
  }
}

///|
test "wildcard captures the rest of the path" {
  let pattern = @lib.make_pattern("/files/*path")
  match pattern.match_path("/files/a/b/c.txt", false) {
    Some(params) => {
      assert_eq(params.length(), 1)
      assert_eq(params[0].0, "path")
      assert_eq(params[0].1, "a/b/c.txt")
    }
    None => assert_true(false)
  }
  match @lib.make_pattern("/files/*").match_path("/files/", false) {
    Some(params) => assert_eq(params[0].1, "")
    None => assert_true(false)
  }
}

///|
test "middleware prefix matching respects segment boundaries" {
  let pattern = @lib.make_pattern("/api")
  assert_true(pattern.match_path("/api", true) is Some(_))
  assert_true(pattern.match_path("/api/users", true) is Some(_))
  assert_true(pattern.match_path("/apix", true) is None)
}

///|
test "query parsing handles encoding and blank values" {
  let query = @lib.parse_query("a=1&b=hello+world&c=%E4%BD%A0%E5%A5%BD&flag")
  assert_eq(query.get("a").unwrap_or(""), "1")
  assert_eq(query.get("b").unwrap_or(""), "hello world")
  assert_eq(query.get("c").unwrap_or(""), "你好")
  assert_eq(query.get("flag").unwrap_or(""), "")
}

///|
test "path decoding keeps literal plus signs" {
  assert_eq(@lib.percent_decode_path("a+b"), "a+b")
  assert_eq(@lib.percent_decode("a+b"), "a b")
  assert_eq(@lib.percent_decode_path("a%2Fb"), "a/b")
}

///|
test "param names are reported in order" {
  let names = @lib.parse_param_names("/users/:id/posts/:post_id/*rest")
  assert_eq(names.length(), 3)
  assert_eq(names[0], "id")
  assert_eq(names[1], "post_id")
  assert_eq(names[2], "rest")
}

///|
test "cookie header parsing and encoding round trip" {
  let cookies = @lib.parse_cookies("theme=dark%20blue; session=abc123; empty=")
  assert_eq(cookies.get("theme").unwrap_or(""), "dark blue")
  assert_eq(cookies.get("session").unwrap_or(""), "abc123")
  assert_eq(cookies.get("empty").unwrap_or(""), "")
  assert_eq(@lib.percent_encode("dark blue"), "dark%20blue")
  assert_eq(@lib.percent_decode(@lib.percent_encode("a;b=c")), "a;b=c")
}

///|
test "status text covers the framework status codes" {
  assert_eq(@lib.status_text(200), "OK")
  assert_eq(@lib.status_text(204), "No Content")
  assert_eq(@lib.status_text(304), "Not Modified")
  assert_eq(@lib.status_text(404), "Not Found")
  assert_eq(@lib.status_text(416), "Range Not Satisfiable")
  assert_eq(@lib.status_text(418), "I'm a Teapot")
  assert_eq(@lib.status_text(500), "Internal Server Error")
}

///|
test "sha256 and hmac match published vectors" {
  assert_eq(
    @lib.sha256_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @lib.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_eq(
    @lib.sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
  assert_eq(
    @lib.bytes_to_hex(
      @lib.hmac_sha256(Bytes::make(20, (0x0b : Int32).to_byte()), b"Hi There"),
    ),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
  assert_eq(
    @lib.bytes_to_hex(
      @lib.hmac_sha256(b"Jefe", b"what do ya want for nothing?"),
    ),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
test "cookie signing round trips and rejects tampering" {
  let signed = @lib.sign_cookie("keyboard cat", "hello world")
  assert_true(!signed.contains("="))
  assert_eq(
    @lib.unsign_cookie("keyboard cat", signed).unwrap_or("<none>"),
    "hello world",
  )
  assert_true(@lib.unsign_cookie("another secret", signed) is None)
  assert_true(
    @lib.unsign_cookie(
      "keyboard cat",
      signed[:10].to_owned() + "D" + signed[11:].to_owned(),
    )
    is None,
  )
  assert_eq(
    @lib.unsign_cookie("keyboard cat", "hello world").unwrap_or("<none>"),
    "<none>",
  )
}

///|
test "media negotiation follows quality values, specificity and order" {
  assert_eq(
    @lib.negotiate_media("application/json, text/html", [
      "text/html", "application/json",
    ]),
    "application/json",
  )
  assert_eq(
    @lib.negotiate_media("text/html;q=0.5, application/json;q=0.9", [
      "text/html", "application/json",
    ]),
    "application/json",
  )
  assert_eq(
    @lib.negotiate_media("text/*", ["application/json", "text/html"]),
    "text/html",
  )
  assert_eq(
    @lib.negotiate_media("", ["text/html", "application/json"]),
    "text/html",
  )
  assert_eq(
    @lib.negotiate_media("*/*", ["text/html", "application/json"]),
    "text/html",
  )
  assert_eq(@lib.negotiate_media("text/html;q=0", ["text/html"]), "")
  assert_eq(@lib.negotiate_media("text/*", ["image/png"]), "")
  assert_eq(@lib.negotiate_media("application/json", ["html", "json"]), "json")
}

///|
test "charset, encoding and language negotiation follow the header" {
  assert_eq(
    @lib.negotiate_charsets("utf-8, iso-8859-5", ["iso-8859-5", "utf-8"]),
    "utf-8",
  )
  assert_eq(@lib.negotiate_charsets("", ["utf-8", "iso-8859-5"]), "utf-8")
  assert_eq(@lib.negotiate_charsets("utf-8;q=0", ["utf-8"]), "")
  assert_eq(
    @lib.negotiate_encodings("gzip, deflate", ["deflate", "gzip"]),
    "gzip",
  )
  assert_eq(@lib.negotiate_encodings("", ["gzip", "identity"]), "identity")
  assert_eq(@lib.negotiate_encodings("br;q=0", ["br"]), "")
  assert_eq(@lib.negotiate_encodings("gzip;q=0.4, br", ["gzip", "br"]), "br")
  assert_eq(@lib.negotiate_languages("en-US, fr", ["fr", "en-US"]), "en-US")
  assert_eq(@lib.negotiate_languages("", ["en", "fr"]), "en")
}

///|
test "http dates format and parse round trip" {
  assert_eq(@lib.format_http_date(784111777L), "Sun, 06 Nov 1994 08:49:37 GMT")
  assert_eq(
    @lib.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT").unwrap_or(-1L),
    784111777L,
  )
  assert_eq(
    @lib.parse_http_date(@lib.format_http_date(1700000000L)).unwrap_or(-1L),
    1700000000L,
  )
  assert_true(@lib.parse_http_date("yesterday") is None)
}

///|
test "range headers parse like range-parser" {
  match @lib.parse_range_header("bytes=0-4", 10) {
    @lib.Ranges(ranges) => {
      assert_eq(ranges.length(), 1)
      assert_eq(ranges[0], (0, 4))
    }
    _ => assert_true(false)
  }
  match @lib.parse_range_header("bytes=-3", 10) {
    @lib.Ranges(ranges) => assert_eq(ranges[0], (7, 9))
    _ => assert_true(false)
  }
  match @lib.parse_range_header("bytes=5-", 10) {
    @lib.Ranges(ranges) => assert_eq(ranges[0], (5, 9))
    _ => assert_true(false)
  }
  match @lib.parse_range_header("bytes=0-1, 5-6", 10) {
    @lib.Ranges(ranges) => assert_eq(ranges.length(), 2)
    _ => assert_true(false)
  }
  match @lib.parse_range_header("bytes=8-20", 10) {
    @lib.Ranges(ranges) => assert_eq(ranges[0], (8, 9))
    _ => assert_true(false)
  }
  assert_true(@lib.parse_range_header("bytes=50-60", 10) is @lib.Unsatisfiable)
  assert_true(@lib.parse_range_header("items=0-1", 10) is @lib.Unsatisfiable)
  assert_true(@lib.parse_range_header("bytes", 10) is @lib.Malformed)
  assert_true(@lib.parse_range_header("", 10) is @lib.NoRange)
}

///|
test "nested urlencoded parsing builds objects and arrays" {
  assert_eq(
    @lib.parse_urlencoded_nested("a[b]=1&a[c]=2").stringify(),
    Json::object({
      "a": Json::object({ "b": Json::string("1"), "c": Json::string("2") }),
    }).stringify(),
  )
  assert_eq(
    @lib.parse_urlencoded_nested("a[]=1&a[]=2").stringify(),
    Json::object({ "a": Json::array([Json::string("1"), Json::string("2")]) }).stringify(),
  )
  assert_eq(
    @lib.parse_urlencoded_nested("a[0]=x&a[1]=y").stringify(),
    Json::object({ "a": Json::array([Json::string("x"), Json::string("y")]) }).stringify(),
  )
  assert_eq(
    @lib.parse_urlencoded_nested("a[b][c]=hello+world").stringify(),
    Json::object({
      "a": Json::object({
        "b": Json::object({ "c": Json::string("hello world") }),
      }),
    }).stringify(),
  )
  assert_eq(
    @lib.parse_urlencoded_nested("a=1&a=2").stringify(),
    Json::object({ "a": Json::string("2") }).stringify(),
  )
}

///|
test "mime types resolve extensions and charsets" {
  assert_eq(@lib.mime_by_extension("png"), "image/png")
  assert_eq(@lib.mime_by_extension("bin"), "application/octet-stream")
  assert_eq(@lib.mime_by_extension("nope"), "")
  assert_eq(@lib.mime_type("/srv/app/style.css"), "text/css; charset=utf-8")
  assert_eq(
    @lib.mime_type("bundle.mjs"),
    "application/javascript; charset=utf-8",
  )
  assert_eq(@lib.mime_type("archive.zip"), "application/zip")
  assert_eq(@lib.mime_type("README"), "application/octet-stream")
}
