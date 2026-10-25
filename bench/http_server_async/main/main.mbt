///|
/// Minimal MoonBit-native HTTP server (moonbitlang/async), the baseline the
/// express package is measured against.
///
///   GET /text -> "Hello, World!"  (text/plain)
///   GET /json -> {"message":"Hello, World!","ok":true}  (application/json)
///
/// Listens on 0.0.0.0:30001.
async fn main {
  let port : Int32 = 30001
  let server = @http.Server(@socket.Addr::parse("0.0.0.0:\{port}"))
  println("async bench listening on http://127.0.0.1:\{port}")
  server.run_forever() <| ((request, _body, conn) => {
    match (request.meth, request.path) {
      (Get, "/text") =>
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
          "Content-Length": "13",
        })
        ..write(b"Hello, World!")
        .end_response()
      (Get, "/json") =>
        conn
        ..send_response(200, "OK", extra_headers={
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": "37",
        })
        ..write(b"{\"message\":\"Hello, World!\",\"ok\":true}")
        .end_response()
      _ =>
        conn
        ..send_response(404, "NotFound", extra_headers={
          "Content-Type": "text/plain; charset=utf-8",
        })
        ..write(b"Not Found")
        .end_response()
    }
  })
}
