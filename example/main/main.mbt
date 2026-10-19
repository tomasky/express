///|
fn main {
  let app = @lib.express()

  // Built-in middleware, mirroring Express. The nested form syntax
  // (`name[first]=Ada`) needs `extended: true`.
  app.use(@lib.logger())
  app.use(@lib.cors())
  app.use(@lib.express_json())
  app.use(@lib.express_urlencoded(extended=true))

  // Routes.
  app.get("/", fn(_req, res, _next) { res.send("Hello from MoonBit express!") })

  app.get("/users/:id", fn(req, res, _next) {
    let id = req.param("id")
    let tab = req.query_param("tab")
    let from_param = match req.locals().get("id_from_param") {
      Some(value) => value
      None => ""
    }
    res.json_string(
      "{\"id\":\"" +
      id +
      "\",\"tab\":\"" +
      tab +
      "\",\"param_seen\":\"" +
      from_param +
      "\",\"method\":\"" +
      req.http_method() +
      "\"}",
    )
  })

  app.get("/files/*path", fn(req, res, _next) {
    res.send("file=" + req.param("path"))
  })

  app.post("/echo", fn(req, res, _next) {
    match req.json_body() {
      Some(value) => res.json(value)
      None => res.send("body=" + req.body())
    }
  })

  app.post("/login", fn(req, res, _next) {
    let name = req.form("name")
    res.send("welcome " + name)
  })

  app.put("/update/:id", fn(req, res, _next) {
    res.send("updated " + req.param("id") + " with body=" + req.body())
  })

  app.patch("/update/:id", fn(req, res, _next) {
    res.send("patched " + req.param("id") + " with body=" + req.body())
  })

  app.delete("/delete/:id", fn(req, res, _next) {
    res.send("deleted " + req.param("id"))
  })

  app.get("/redirect", fn(_req, res, _next) { res.redirect("/") })

  // app.param runs for every route that captures `:id`, before its handler.
  app.param("id", fn(req, next) {
    req.locals().set("id_from_param", req.param("id"))
    next.proceed()
  })

  app.get("/cookie", fn(_req, res, _next) {
    res.cookie("theme", "dark blue").send("cookie set")
  })

  app.get("/whoami", fn(req, res, _next) {
    res.send("theme=" + req.cookie("theme"))
  })

  app.get("/headers", fn(req, res, _next) {
    let ua = req.header("user-agent")
    res.json_string("{\"user-agent\":\"" + ua + "\"}")
  })

  // Settings used by the routes below.
  app.set("trust proxy", "true")
  app.set("jsonp callback name", "callback")
  app.set("cookie secret", "keyboard cat")
  app.set("views", "./views")
  app.set("view engine", "tpl")
  app.engine("tpl", tpl_engine)

  // Chainable route builder: `app.route("/book").get(...).post(...)`.
  ignore(
    app
    .route("/book")
    .get(fn(_req, res, _next) { res.send("book list") })
    .post(fn(_req, res, _next) { res.send("book created") }),
  )

  // Mounted routers strip their mount prefix, like `app.use("/api", router)`.
  let v2 = @lib.express_router()
  v2.get("/hello", fn(req, res, _next) {
    res.send("hello from v2 base=" + req.base_url() + " url=" + req.url())
  })

  let api = @lib.express_router()
  api.get("/health", fn(_req, res, _next) { res.json_string("{\"ok\":true}") })
  api.get("/users/:id", fn(req, res, _next) {
    res.json_string(
      "{\"id\":\"" + req.param("id") + "\",\"base\":\"" + req.base_url() + "\"}",
    )
  })
  api.use_router("/v2", v2)
  app.use_router("/api", api)

  // Nested form bodies from `express_urlencoded(extended=true)`.
  app.post("/form", fn(req, res, _next) {
    match req.form_json() {
      Some(value) => res.json(value)
      None => res.send_status(400)
    }
  })

  // Content negotiation, like `res.format`.
  app.get("/report", fn(_req, res, _next) {
    res.format([
      (
        "application/json",
        fn(_req, res, _next) { res.json_string("{\"report\":true}") },
      ),
      ("text/plain", fn(_req, res, _next) { res.send("report (plain text)") }),
      ("default", fn(_req, res, _next) { res.send_status(406) }),
    ])
  })

  // JSONP answers `GET /jsonp?callback=cb` with `cb({...});`.
  app.get("/jsonp", fn(_req, res, _next) {
    res.jsonp(Json::object({ "ok": Json::boolean(true) }))
  })

  // Signed cookies round trip through the `cookie secret` setting.
  app.get("/sign-in", fn(_req, res, _next) {
    res.cookie_with("session", "user-42", signed=true).send("signed cookie set")
  })

  app.get("/sign-read", fn(req, res, _next) {
    res.send("session=" + req.signed_cookie("session"))
  })

  // With `trust proxy` the X-Forwarded-* headers fill in ip/protocol/host.
  app.get("/ip", fn(req, res, _next) {
    res.json_string(
      "{\"ip\":\"" +
      req.ip() +
      "\",\"protocol\":\"" +
      req.protocol() +
      "\",\"host\":\"" +
      req.host() +
      "\",\"subdomain_count\":" +
      req.subdomains().length().to_string() +
      "}",
    )
  })

  // Streaming with `res.write` and `res.end_stream`.
  app.get("/stream", fn(_req, res, _next) {
    ignore(res.write("chunk one; "))
    ignore(res.write("chunk two; "))
    ignore(res.write("chunk three"))
    res.end_stream()
  })

  // `res.download` sets `Content-Disposition`; `res.send_file` serves a file
  // with ETag, Last-Modified and Range support.
  app.get("/download", fn(_req, res, _next) {
    res.download("./public/hello.txt")
  })

  // View rendering through the engine registered above.
  app.get("/hello/:name", fn(req, res, _next) {
    let locals : Map[String, Json] = { "name": Json::string(req.param("name")) }
    res.render("hello", locals=Json::object(locals))
  })

  // Native websockets, straight from µWebSockets.
  app.ws(
    "/ws",
    @lib.ws_behavior(
      open=fn(conn) { conn.send("welcome") },
      message=fn(conn, message) {
        match message {
          @lib.WsMessage::Text(text) => conn.send("echo:" + text)
          @lib.WsMessage::Binary(data) => conn.send_bytes(data)
        }
      },
      close=fn(_conn, _code, _reason) { () },
    ),
  )

  // Static files fall through when no route matched above.
  app.use(@lib.express_static("./public"))

  // Errors flow to error middleware.
  app.get("/boom", fn(_req, _res, next) { next.fail("boom!") })

  app.use_error(fn(message, _req, res, _next) {
    res.status(500).send("caught: " + message)
  })

  app.listen(8080, fn(ok) {
    if ok {
      println("Server listening on http://localhost:8080")
    } else {
      println("Failed to start server")
    }
  })
}

///|
/// Minimal `{{name}}` view engine used by the example's `/hello/:name` route.
fn tpl_engine(_path : String, source : String, options : Json) -> String {
  let mut out = source
  if options is Object(values) {
    for pair in values.iter() {
      out = out.replace_all(old="{{" + pair.0 + "}}", new=json_text(pair.1))
    }
  }
  out
}

///|
/// Renders the scalar JSON values a template can interpolate.
fn json_text(value : Json) -> String {
  match value {
    Json::String(text) => text
    Json::Number(number, ..) => number.to_string()
    Json::True => "true"
    Json::False => "false"
    _ => ""
  }
}
