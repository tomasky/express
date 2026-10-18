test "parse_param_names extracts single param" {
  let names = @express.parse_param_names("/users/:id")
  assert_true(names.length() == 1)
  assert_true(names[0] == "id")
}

test "parse_param_names extracts multiple params" {
  let names = @express.parse_param_names("/users/:id/posts/:post_id")
  assert_true(names.length() == 2)
  assert_true(names[0] == "id")
  assert_true(names[1] == "post_id")
}

test "parse_param_names no params" {
  let names = @express.parse_param_names("/users/list")
  assert_true(names.length() == 0)
}

test "map set and get" {
  let m : Map[String, String] = Map([])
  m.set("key", "value")
  match m.get("key") {
    Some(v) => assert_true(v == "value")
    None => assert_true(false)
  }
}
