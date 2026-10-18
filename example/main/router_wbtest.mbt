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
test "status text covers the framework status codes" {
  assert_eq(@lib.status_text(200), "OK")
  assert_eq(@lib.status_text(404), "Not Found")
  assert_eq(@lib.status_text(500), "Internal Server Error")
}
