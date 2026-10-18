///|
fn main {
  let app = @lib.express()

  // Built-in middleware, mirroring Express.
  app.use(@lib.logger())
  app.use(@lib.cors())
  app.use(@lib.express_json())
  app.use(@lib.express_urlencoded())

  // Routes.
  app.get("/", fn(_req, res, _next) { res.send("Hello from MoonBit express!") })

  app.get("/users/:id", fn(req, res, _next) {
    let id = req.param("id")
    let tab = req.query_param("tab")
    res.json_string(
      "{\"id\":\"" +
      id +
      "\",\"tab\":\"" +
      tab +
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
