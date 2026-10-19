///|
/// Minimal HTTPS server.
///
/// Generate a self-signed pair for local testing:
///
/// ```sh
/// openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
///   -keyout key.pem -out cert.pem -subj "/CN=localhost"
/// ```
///
/// then run this example from the directory containing `cert.pem`/`key.pem`.
fn main {
  let app = @lib.express()
  app.use(@lib.express_json())

  app.get("/", fn(req, res, _next) {
    res.json_string(
      "{\"secure\":" +
      req.secure().to_string() +
      ",\"protocol\":\"" +
      req.protocol() +
      "\"}",
    )
  })

  // Exercises the request-body path over TLS.
  app.post("/echo", fn(req, res, _next) { res.send("body=" + req.body()) })

  // Blocks in the µWebSockets event loop.
  app.listen_tls("cert.pem", "key.pem", 8443, fn(ok) {
    println("TLS listening on :8443 -> " + ok.to_string())
  })
}
