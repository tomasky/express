# express

An Express-style web framework for **native** MoonBit, served by
[µWebSockets](https://github.com/uNetworking/uWebSockets) — the same C++ engine
behind uWebSockets.js. Routing, middleware, params and error handling are written
in MoonBit; the HTTP parser, router entry point and event loop come from
µWebSockets through a small C ABI shim.

Inspired by [fulmine.js](https://github.com/nigrosimone/fulmine.js), which puts
an Express-compatible API on µWebSockets for Node.js.

## Quick start

```moonbit nocheck
///|
fn main {
  let app = @express.express()

  app.use(@express.logger())
  app.use(@express.express_json())

  app.get("/users/:id", fn(req, res, _next) {
    res.json_string("{\"id\":\"" + req.param("id") + "\"}")
  })

  app.post("/echo", fn(req, res, _next) {
    match req.json_body() {
      Some(value) => res.json(value)
      None => res.send("body=" + req.body())
    }
  })

  app.get("/boom", fn(_req, _res, next) { next.fail("boom!") })

  app.use_error(fn(message, _req, res, _next) {
    res.status(500).send("caught: " + message)
  })

  app.listen(8080, fn(ok) { println(ok.to_string()) })
}
```

## Features

- **Express-compatible routing** — `app.get/post/put/patch/delete/options/head/all(path, handler)`, `app.route(method, path, handler)`, `app.use(mw)` / `app.use_at(path, mw)`
- **Route parameters** — `:name` params, `*` and `*name` wildcards, `req.param(name)` / `req.params()`
- **Middleware chain** — `(Req, Res, Next) -> Unit` with `next.proceed()` / `next.fail(msg)`
- **Error middleware** — `app.use_error(mw)` / `app.use_error_at(path, mw)` with `(String, Req, Res, Next) -> Unit` signature
- **Query & body parsing** — `req.query_param(name)` / `req.query_map()` / `req.raw_query()`, JSON / URL-encoded / text / raw body middleware
- **Cookies** — `req.cookie(name)` / `req.cookies()`, `res.cookie(name, value)` / `res.cookie_with(...)` / `res.clear_cookie(name)`
- **Static files** — `express_static(root)` with directory index resolution and path traversal protection
- **Native WebSockets** — direct µWebSockets upgrade, no Node.js `http` workaround
- **TLS / HTTPS** — `listen_tls(cert, key, port, cb)` with full `UwsSslOptions` support
- **CORS** — built-in permissive CORS middleware with preflight handling

## Requirements

- MoonBit toolchain with the `native` backend (`preferred_target = "native"`)
- A C++17 compiler (`g++` / `clang++`) — µWebSockets is header-only C++
- `zlib` development headers, linked as `-lz`

TLS is off by default: the vendored uSockets is compiled with `LIBUS_NO_SSL`.
Define `MOONBIT_UWS_WITH_TLS` and link OpenSSL to re-enable it.

## Building an application

This package is a **library**. The executable package that depends on it must
provide the C++ runtime and zlib at link time:

```moon.pkg
import {
  "kupas/express" @lib,
}

supported_targets = "native"

pkgtype(kind: "executable")

options(
  "link": {
    "native": {
      "cc-link-flags": "-lstdc++ -lz",
    },
  },
)
```

Then:

```bash
moon run example/main        # demo server on :8080
moon test                   # router/query unit tests
```

## API

### Application

| MoonBit | Express.js | Notes |
| --- | --- | --- |
| `express()` | `express()` | Creates a new app |
| `app.get/post/put/patch/delete/options/head/all(path, handler)` | `app.METHOD(path, handler)` | Route registration |
| `app.route(method, path, handler)` | `app.route(path).METHOD(handler)` | Programmatic route method |
| `app.use(mw)` | `app.use(mw)` | Global middleware |
| `app.use_at(path, mw)` | `app.use(path, mw)` | Path-scoped middleware |
| `app.use_error(mw)` | `app.use((err, req, res, next) => ...)` | Error middleware |
| `app.use_error_at(path, mw)` | `app.use(path, (err, req, res, next) => ...)` | Path-scoped error middleware |
| `app.listen(port, cb)` | `app.listen(port, cb)` | Blocks in event loop |
| `app.listen_host(host, port, cb)` | `app.listen(port, host, cb)` | Specific host, blocks |
| `app.listen_async(host, port, cb)` | — | Non-blocking; call `app.run()` after |
| `app.run()` | — | Runs the event loop (after `listen_async`) |
| `app.close()` | — | Closes all sockets, stops event loop |
| `app.set(key, value)` / `app.get_setting(key)` | `app.set(key, value)` / `app.get(key)` | App settings |
| `app.ws(path, behavior)` | `app.ws(path, { open, message, close })` | WebSocket route |
| `app.param(name, callback)` | `app.param(name, callback)` | Param middleware |
| `app.locals` | `app.locals` | App-scoped local variables |

### Request (`Req`)

| MoonBit | Express.js | Notes |
| --- | --- | --- |
| `req.method()` / `req.http_method()` | `req.method` | HTTP method (uppercase) |
| `req.path()` | `req.path` | URL path |
| `req.param(name)` | `req.params[name]` | Route parameter |
| `req.params()` | `req.params` | All route parameters |
| `req.query_param(name)` | `req.query[name]` | Parsed query parameter |
| `req.query_map()` | `req.query` | All query parameters |
| `req.raw_query()` / `req.query()` | `req.query` (raw) | Raw query string |
| `req.header(name)` / `req.get(name)` | `req.get(name)` | Request header (case-insensitive) |
| `req.body()` | `req.body` | Raw body text |
| `req.json_body()` | `req.body` (parsed) | Parsed JSON body |
| `req.form(name)` | `req.body[name]` | Form field value |
| `req.form_map()` | `req.body` | All form fields |
| `req.cookie(name)` | `req.cookies[name]` | Cookie value |
| `req.cookies()` | `req.cookies` | All cookies |
| `req.ip()` | `req.ip` | Remote IP address |
| `req.is_aborted()` | — | Whether the request was aborted |
| `req.protocol` | `req.protocol` | Protocol (with TLS) |
| `req.secure` | `req.secure` | Whether TLS is active |
| `req.accepts(types)` | `req.accepts(types)` | Content negotiation |
| `req.is(type)` | `req.is(type)` | Content-Type check |
| `req.locals` | `req.locals` | Request-scoped local variables |

### Response (`Res`)

| MoonBit | Express.js | Notes |
| --- | --- | --- |
| `res.status(code)` | `res.status(code)` | Set status code |
| `res.status_code()` | `res.statusCode` | Get status code |
| `res.set(name, value)` | `res.set(field, value)` | Set response header |
| `res.set_header(name, value)` | `res.setHeader(name, value)` | Alias for `set` |
| `res.header(name)` | `res.get(name)` | Get response header |
| `res.type_(content_type)` | `res.type(type)` | Set Content-Type |
| `res.send(text)` | `res.send(text)` | Send text response |
| `res.send_bytes(bytes)` | `res.send(Buffer)` | Send binary response |
| `res.send_empty()` | `res.send()` | Send empty response |
| `res.json(value)` | `res.json(value)` | Send JSON response |
| `res.json_string(raw)` | — | Send pre-serialized JSON |
| `res.redirect(url)` | `res.redirect(url)` | 302 redirect |
| `res.cookie(name, value)` | `res.cookie(name, value)` | Set cookie |
| `res.cookie_with(name, value, path?, max_age?, http_only?)` | `res.cookie(name, value, options)` | Cookie with options |
| `res.clear_cookie(name)` | `res.clearCookie(name)` | Expire cookie |
| `res.is_ended()` | — | Whether response was sent |
| `res.is_aborted()` | — | Whether response was aborted |
| `res.sendFile(path)` | `res.sendFile(path)` | Send file with correct MIME type |
| `res.download(path, filename?)` | `res.download(path, filename?)` | Download file as attachment |
| `res.attachment(filename?)` | `res.attachment(filename?)` | Set Content-Disposition |
| `res.append(field, value)` | `res.append(field, value)` | Append response header |
| `res.links(links)` | `res.links(links)` | Set Link header |
| `res.location(url)` | `res.location(url)` | Set Location header |
| `res.vary(field)` | `res.vary(field)` | Add Vary header |
| `res.locals` | `res.locals` | Response-scoped local variables |

### Middleware

A middleware is `(Req, Res, Next) -> Unit`:

- Call `next.proceed()` to continue to the next middleware/route
- Call `next.fail(message)` to jump to error middleware
- A route handler is also `(Req, Res, Next) -> Unit`; calling `next.proceed()` falls through to later routes

```moonbit nocheck
fn(req, res, next) {
  println("before: " + req.path())
  next.proceed()
  println("after: " + req.path())
}
```

### Built-in middleware

| MoonBit | Express.js | Description |
| --- | --- | --- |
| `express_json(limit?)` | `express.json(limit?)` | Parse `application/json` bodies |
| `express_urlencoded(limit?)` | `express.urlencoded({ extended: false })` | Parse form bodies |
| `express_text(limit?)` | `express.text(limit?)` | Parse `text/*` bodies |
| `express_raw(limit?)` | `express.raw(limit?)` | Alias for `express_text` |
| `express_static(root)` | `express.static(root)` | Serve static files |
| `cors()` | `cors()` | Permissive CORS with preflight |
| `logger()` | `morgan('dev')` | Minimal request logger |

### WebSockets

µWebSockets' websocket support is exposed directly — no `node:http` upgrade
workaround, the frames never leave the native engine:

```moonbit nocheck
app.ws("/chat/:room", @express.ws_behavior(
  open=fn(conn) { conn.send("welcome") },
  message=fn(conn, message) {
    match message {
      @express.WsMessage::Text(text) => conn.send("echo:" + text)
      @express.WsMessage::Binary(data) => conn.send_bytes(data)
    }
  },
  close=fn(_conn, _code, _reason) { () },
))
```

`WsConn` offers `id()`, `send(text)`, `send_bytes(bytes)`,
`send_frame(bytes, opcode, compress)`, and `close(code?, reason?)`.
All three behavior callbacks are optional.

### TLS / HTTPS

To serve over TLS, use `listen_tls` or `listen_tls_async` with PEM-encoded
certificate and key files. The vendored uSockets must be compiled with
`MOONBIT_UWS_WITH_TLS` defined and linked against OpenSSL (`-lssl -lcrypto`).

```moonbit nocheck
///|
fn main {
  // TLS app — blocks in the µWebSockets event loop
  let app = @express.listen_tls("cert.pem", "key.pem", 8443, fn(ok) {
    println("TLS listen: " + ok.to_string())
  })

  app.get("/", fn(req, res, _next) { res.send("hello over TLS") })
}
```

Non-blocking TLS (call `app.run()` yourself):

```moonbit nocheck
///|
fn main {
  let app = @express.listen_tls_async("cert.pem", "key.pem", "0.0.0.0", 8443, fn(
    ok,
  ) {
    println("TLS listen: " + ok.to_string())
  })
  app.get("/", fn(req, res, _next) { res.send("hello over TLS") })
  app.run() // blocks
}
```

`UwsSslOptions` also supports `passphrase`, `dh_params_file`, `ca_file`,
and `ssl_ciphers` for advanced TLS configuration.

### Helpers exported for tests and custom routers

`make_pattern`, `PathPattern::match_path`, `split_path`, `parse_query`,
`parse_urlencoded`, `percent_decode`, `percent_decode_path`,
`parse_param_names`, `status_text`.

## How it works

µWebSockets matches a single catch-all route (`/*`); everything Express-shaped
happens in MoonBit (`express.mbt`, `path.mbt`, `middleware.mbt`). µWebSockets
invalidates the request object when the handler returns, so the shim snapshots
method/url/query/headers up front, and request bodies are delivered asynchronously
by request id (`uwb_res_on_data`).

`src/uws_shim.cpp` is the C++/C boundary; `uws.mbt` declares the `extern "C"`
calls with `FuncRef` callbacks. Strings cross the boundary as UTF-8 `Bytes`.

`third_party/` vendors µWebSockets (`App.h` and friends, header-only) and the
parts of µSockets needed for the epoll/kqueue event loop and plain HTTP. Three
local patches were applied and are marked with comments:

1. `libusockets.h` defines `LIBUS_NO_SSL` unless `MOONBIT_UWS_WITH_TLS` is set.
2. `internal/` and `eventing/` includes use paths relative to their own files,
   so the stubs compile without `-I` flags.
3. µWebSockets headers include the vendored `libusockets.h` by relative path.

## Differences from Express

- Handlers and middleware must name the extra parameter (`fn(req, res, _next)`)
  because MoonBit has no arity-based overloading.
- `next` is a struct: `next.proceed()` / `next.fail(msg)` / `next.resume_with(err?)`.
- Errors are strings, not `Error` objects.
- Route patterns support `:name`, `*` and `*name`; there is no regexp route.
- Body parsing is opt-in per middleware, exactly like `body-parser`.
- `res.set()` replaces a header; use `res.append()` to add multi-value headers.
- `req.params` is a `Map[String, String]`; use `req.has_param(name)` to check existence.

## Tests

`moon test` covers route matching (static, params, wildcard, prefixes, trailing
slashes, case-insensitivity), query parsing/percent decoding, and the status-code
table. The demo in `example/main` is also a manual integration test:

```bash
moon run example/main
curl 'http://localhost:8080/users/42?tab=info'
curl -X POST -H 'Content-Type: application/json' -d '{"a":1}' http://localhost:8080/echo
```

## License

Apache-2.0. Vendored µWebSockets and µSockets sources keep their own Apache-2.0
licenses in `third_party/*/LICENSE`.
