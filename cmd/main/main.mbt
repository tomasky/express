fn main {
  let app = @lib.express()

  // Built-in middleware
  app.use_middleware(@lib.express_json())

  // Routes
  app.get("/", fn(req, res) {
    let _ = req
    res.send("Hello from MoonBit express!")
  })

  app.get("/users/:id", fn(req, res) {
    let id = req.param("id")
    res.json("{\"id\":\"" + id + "\", \"method\":\"" + req.get_method().to_upper() + "\"}")
  })

  app.post("/echo", fn(req, res) {
    res.send("body=" + req.body())
  })

  app.put("/update/:id", fn(req, res) {
    let id = req.param("id")
    res.send("updated " + id + " with body=" + req.body())
  })

  app.delete("/delete/:id", fn(req, res) {
    let id = req.param("id")
    res.send("deleted " + id)
  })

  app.get("/redirect", fn(req, res) {
    let _ = req
    res.redirect("/")
  })

  app.get("/headers", fn(req, res) {
    let ua = req.header("user-agent")
    let ct = req.header("content-type")
    res.json("{\"user-agent\":\"" + ua + "\", \"content-type\":\"" + ct + "\"}")
  })

  app.listen(8080, fn(ok) {
    if ok {
      println("Server listening on http://localhost:8080")
    } else {
      println("Failed to start server")
    }
  })
}
