///|
/// Reads the optional `BENCH_PORT` override; 0 means "use the default".
extern "C" fn bench_env_port() -> Int32 = "bench_env_port"

///|
/// Minimal benchmark server: two cheap routes, no middleware, so autocannon
/// measures the framework's routing + response path with as little extra work
/// as possible.
///
///   GET /text -> "Hello, World!"
///   GET /json -> {"message":"Hello, World!","ok":true}
///
/// The port can be overridden with `BENCH_PORT`, which also allows two builds
/// (for example a before/after pair) to be loaded at once.
fn main {
  let app = @lib.express()

  app.get("/text", fn(_req, res, _next) { res.send("Hello, World!") })

  app.get("/json", fn(_req, res, _next) {
    res.json_string("{\"message\":\"Hello, World!\",\"ok\":true}")
  })

  let from_env = bench_env_port()
  let port : Int32 = if from_env > 0 { from_env } else { 30000 }

  app.listen(port, fn(ok) {
    if ok {
      println("express bench listening on http://127.0.0.1:" + port.to_string())
    } else {
      println("express bench failed to start on port " + port.to_string())
    }
  })
}
