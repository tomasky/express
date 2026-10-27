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

- **Express-compatible routing** — `app.get/post/put/patch/delete/options/head/all(path, handler)`, `app.add_route(method, path, handler)`, `app.route(path).get(...).post(...)` chainable builder, `app.use(mw)` / `app.use_at(path, mw)`
- **Route parameters** — `:name` params, `*` and `*name` wildcards, `req.param(name)` / `req.params()`
- **Middleware chain** — `(Req, Res, Next) -> Unit` with `next.proceed()` / `next.fail(msg)` / `next.resume_with(err?)`
- **Error middleware** — `app.use_error(mw)` / `app.use_error_at(path, mw)` with `(String, Req, Res, Next) -> Unit` signature
- **Query & body parsing** — `req.query_param(name)` / `req.query_map()` / `req.raw_query()`, JSON / URL-encoded (flat or extended) / text / raw body middleware
- **Cookies** — `req.cookie(name)` / `req.cookies()`, signed cookies (`req.signed_cookie`, `req.signed_cookies`, `res.cookie_with(..., signed=true)`), `res.cookie(name, value)` / `res.cookie_with(...)` / `res.clear_cookie(name)`
- **Static files** — `express_static(root, options?)` with ETag, Last-Modified, 304, Range (206/416), directory index, dotfiles and fallthrough control
- **Content negotiation** — `req.accepts/accepts_charsets/accepts_encodings/accepts_languages`, `res.format`, `res.type_`
- **Conditional responses** — `req.fresh` / `req.stale`, weak ETags, `If-None-Match` / `If-Modified-Since` → 304
- **Mounted routers** — `app.use_router(path, router)` / `router.use_router(path, router)` with prefix stripping, `base_url` accumulation and `merge_params`
- **View rendering** — `app.engine(ext, fn)` / `app.set("view engine", ext)` / `res.render(view, locals?)` / `app.render(view, locals?)`
- **Streaming** — `res.write` / `res.write_bytes` / `res.end_stream` / `res.flush_headers`
- **Trust proxy** — `app.set("trust proxy", ...)` drives `req.ip` / `req.ips` / `req.protocol` / `req.secure` / `req.host` / `req.subdomains`
- **Native WebSockets** — direct µWebSockets upgrade, no Node.js `http` workaround
- **TLS / HTTPS** — `app.listen_tls(cert, key, port, cb)` and `listen_tls_host` / `listen_tls_async`, with full `UwsSslOptions` support
- **CORS** — built-in permissive CORS middleware with preflight handling
- **No `X-Powered-By`** — the framework never sends that header

## Requirements

- MoonBit toolchain with the `native` backend (`preferred_target = "native"`)
- A C++17 compiler (`g++` / `clang++`) — µWebSockets is header-only C++
- `zlib` development headers, linked as `-lz`
- OpenSSL development headers (`libssl-dev`), linked as `-lssl -lcrypto`

TLS support is compiled into the library unconditionally, so every executable
that depends on this package must link OpenSSL. A local build can drop TLS by
removing `MOONBIT_UWS_WITH_TLS` from `stub-cc-flags` in `moon.pkg`; the
vendored `libusockets.h` then falls back to `LIBUS_NO_SSL` and the link flags
can omit `-lssl -lcrypto`.

## Building an application

This package is a **library**. The executable package that depends on it must
provide the C++ runtime, zlib and OpenSSL at link time:

```moon.pkg
import {
  "kupas/express" @lib,
}

supported_targets = "native"

pkgtype(kind: "executable")

options(
  "link": {
    "native": {
      "cc-link-flags": "-lstdc++ -lz -lssl -lcrypto",
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
| `app.add_route(method, path, handler)` | `app.METHOD(path, handler)` | Programmatic route registration (renamed from `route`) |
| `app.route(path)` | `app.route(path)` | Chainable builder returning a `RouteBuilder` |
| `app.use(mw)` | `app.use(mw)` | Global middleware |
| `app.use_at(path, mw)` | `app.use(path, mw)` | Path-scoped middleware |
| `app.use_error(mw)` | `app.use((err, req, res, next) => ...)` | Error middleware |
| `app.use_error_at(path, mw)` | `app.use(path, (err, req, res, next) => ...)` | Path-scoped error middleware |
| `app.use_router(path, router)` | `app.use(path, router)` | Mount a sub-router |
| `app.listen(port, cb)` | `app.listen(port, cb)` | Blocks in event loop |
| `app.listen_host(host, port, cb)` | `app.listen(port, host, cb)` | Specific host, blocks |
| `app.listen_async(host, port, cb)` | — | Non-blocking; call `app.run()` after |
| `app.enable_tls(cert, key)` / `enable_tls_with(options)` | — | Switch the app to HTTPS |
| `app.listen_tls(cert, key, port, cb)` | `https.createServer(...).listen(...)` | TLS, blocks |
| `app.listen_tls_host(cert, key, host, port, cb)` | — | TLS on a specific host, blocks |
| `app.listen_tls_async(cert, key, host, port, cb)` | — | TLS, non-blocking |
| `app.run()` | — | Runs the event loop (after `listen_async`) |
| `app.close()` | — | Closes all sockets, stops event loop |
| `app.set(key, value)` / `app.get_setting(key)` | `app.set(key, value)` / `app.get(key)` | App settings |
| `app.enable(name)` / `app.disable(name)` | `app.enable(name)` / `app.disable(name)` | Toggle boolean settings |
| `app.enabled(name)` / `app.disabled(name)` | `app.enabled(name)` / `app.disabled(name)` | Read boolean settings |
| `app.engine(ext, render)` | `app.engine(ext, callback)` | Register a view engine |
| `app.render(view, locals?)` | `app.render(view, locals?, cb)` | Render a view through an engine |
| `app.ws(path, behavior)` | `app.ws(path, { open, message, close })` | WebSocket route |
| `app.param(name, callback)` | `app.param(name, callback)` | Param middleware |
| `app.locals` | `app.locals` | App-scoped local variables |

### Request (`Req`)

| MoonBit | Express.js | Notes |
| --- | --- | --- |
| `req.method()` / `req.http_method()` | `req.method` | HTTP method (uppercase) |
| `req.path()` | `req.path` | URL path |
| `req.original_url()` | `req.originalUrl` | URL before router mounting |
| `req.base_url()` | `req.baseUrl` | Accumulated mount prefix |
| `req.url()` | `req.url` | URL relative to the current mount |
| `req.param(name)` | `req.params[name]` | Route parameter |
| `req.params()` | `req.params` | All route parameters |
| `req.has_param(name)` | — | Whether a param exists |
| `req.query_param(name)` | `req.query[name]` | Parsed query parameter |
| `req.query_map()` | `req.query` | All query parameters |
| `req.raw_query()` / `req.query()` | `req.query` (raw) | Raw query string |
| `req.header(name)` / `req.get(name)` | `req.get(name)` | Request header (case-insensitive) |
| `req.xhr()` | `req.xhr` | Whether `X-Requested-With` is `XMLHttpRequest` |
| `req.body()` | `req.body` | Raw body text |
| `req.body_bytes()` | `req.body` (Buffer) | Raw body bytes |
| `req.json_body()` | `req.body` (parsed) | Parsed JSON body |
| `req.form(name)` | `req.body[name]` | Form field value |
| `req.form_map()` | `req.body` | All form fields |
| `req.form_json()` | `req.body` | Nested form body (`extended` mode) |
| `req.cookie(name)` | `req.cookies[name]` | Cookie value |
| `req.cookies()` | `req.cookies` | All cookies |
| `req.signed_cookie(name)` | `req.signedCookies[name]` | Verified signed cookie |
| `req.signed_cookies()` | `req.signedCookies` | All verified signed cookies |
| `req.ip()` | `req.ip` | Remote IP (trust-proxy aware) |
| `req.ips()` | `req.ips` | IP chain from `X-Forwarded-For` |
| `req.protocol()` | `req.protocol` | Protocol (trust-proxy aware) |
| `req.secure()` | `req.secure` | Whether the request is TLS |
| `req.host()` | `req.get('host')` | Host header (trust-proxy aware) |
| `req.hostname()` | `req.hostname` | Host without port |
| `req.subdomains()` | `req.subdomains` | Subdomain list |
| `req.remote_port()` | — | Remote TCP port |
| `req.route()` | `req.route` | The matched `RouteInfo` |
| `req.app()` | `req.app` | The owning application |
| `req.accepts(types)` | `req.accepts(types)` | Content negotiation (media) |
| `req.accepts_charsets(types)` | `req.acceptsCharsets(types)` | Charset negotiation |
| `req.accepts_encodings(types)` | `req.acceptsEncodings(types)` | Encoding negotiation |
| `req.accepts_languages(types)` | `req.acceptsLanguages(types)` | Language negotiation |
| `req.range(size)` | `req.range(size)` | Parse a `Range` header |
| `req.fresh()` | `req.fresh` | Conditional request matches |
| `req.stale()` | `req.stale` | Inverse of `fresh` |
| `req.is(type)` | `req.is(type)` | Content-Type check |
| `req.is_aborted()` | — | Whether the request was aborted |
| `req.locals` | `req.locals` | Request-scoped local variables |
| `req.setting(key)` | `req.app.get(key)` | Read an app setting |

### Response (`Res`)

| MoonBit | Express.js | Notes |
| --- | --- | --- |
| `res.status(code)` | `res.status(code)` | Set status code |
| `res.status_code()` | `res.statusCode` | Get status code |
| `res.send_status(code)` | `res.sendStatus(code)` | Send status with its reason phrase |
| `res.set(name, value)` | `res.set(field, value)` | Set response header |
| `res.set_header(name, value)` | `res.setHeader(name, value)` | Alias for `set` |
| `res.get(name)` | `res.get(name)` | Get response header |
| `res.headers_sent()` | `res.headersSent` | Whether headers were flushed |
| `res.type_(content_type)` | `res.type(type)` | Set Content-Type (normalised) |
| `res.send(text)` | `res.send(text)` | Send text response |
| `res.send_bytes(bytes)` | `res.send(Buffer)` | Send binary response |
| `res.send_empty()` | `res.send()` | Send empty response |
| `res.json(value)` | `res.json(value)` | Send JSON response |
| `res.json_string(raw)` | — | Send pre-serialized JSON |
| `res.jsonp(value)` | `res.jsonp(value)` | JSONP response |
| `res.redirect(url, status?)` | `res.redirect(url, status?)` | Redirect (302 by default) |
| `res.render(view, locals?)` | `res.render(view, locals?, cb)` | Render a view through an engine |
| `res.format(handlers)` | `res.format(obj)` | Content-negotiated response |
| `res.cookie(name, value)` | `res.cookie(name, value)` | Set cookie |
| `res.cookie_with(name, value, path?, max_age?, http_only?, domain?, expires?, secure?, same_site?, signed?)` | `res.cookie(name, value, options)` | Cookie with options |
| `res.clear_cookie(name, path?)` | `res.clearCookie(name, options?)` | Expire cookie |
| `res.write(chunk)` | `res.write(chunk)` | Stream a text chunk |
| `res.write_bytes(chunk)` | `res.write(chunk)` | Stream a binary chunk |
| `res.end_stream()` | `res.end()` | End a streamed response |
| `res.flush_headers()` | `res.flushHeaders()` | Flush headers without ending |
| `res.is_ended()` | — | Whether response was sent |
| `res.is_aborted()` | — | Whether response was aborted |
| `res.send_file(path, options?)` | `res.sendFile(path, options?)` | Send file (ETag, Range, 304) |
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
| `express_urlencoded(limit?, extended?)` | `express.urlencoded({ extended })` | Parse form bodies (flat or nested) |
| `express_text(limit?)` | `express.text(limit?)` | Parse `text/*` bodies |
| `express_raw(limit?)` | `express.raw(limit?)` | Parse raw bodies into bytes |
| `express_static(root, options?)` | `express.static(root, options)` | Serve static files (ETag, Range, ...) |
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

Call `app.enable_tls` (or one of the `listen_tls*` helpers) with PEM-encoded
certificate and key files. Routes are registered exactly as for plain HTTP,
and `req.secure()` / `req.protocol()` report the TLS state.

```moonbit nocheck
///|
fn main {
  let app = @express.express()

  app.get("/", fn(req, res, _next) { res.send("hello over " + req.protocol()) })

  // Switches the app to TLS, then blocks in the µWebSockets event loop.
  app.listen_tls("cert.pem", "key.pem", 8443, fn(ok) {
    println("TLS listen: " + ok.to_string())
  })
}
```

Non-blocking TLS (call `app.run()` yourself):

```moonbit nocheck
///|
fn main {
  let app = @express.express()
  app.get("/", fn(_req, res, _next) { res.send("hello over TLS") })

  app.listen_tls_async("cert.pem", "key.pem", "0.0.0.0", 8443, fn(ok) {
    println("TLS listen: " + ok.to_string())
  })
  app.run() // blocks
}
```

Advanced options use `enable_tls_with`, then start the app with the regular
`listen*` calls:

```moonbit nocheck
///|
fn main {
  let app = @express.express()
  app.enable_tls_with(@express.UwsSslOptions::{
    cert_file: "cert.pem",
    key_file: "key.pem",
    passphrase: Some("secret"),
    dh_params_file: None,
    ca_file: None,
    ssl_ciphers: Some("ECDHE+AESGCM"),
  })
  app.get("/", fn(_req, res, _next) { res.send("hello over TLS") })
  app.listen(8443, fn(ok) { println("TLS listen: " + ok.to_string()) })
}
```

For local testing, generate a self-signed pair:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout key.pem -out cert.pem -subj "/CN=localhost"
moon run example/tls   # HTTPS demo on :8443
```

### Helpers exported for tests and custom routers

`make_pattern`, `PathPattern::match_path`, `split_path`, `parse_query`,
`parse_urlencoded`, `parse_urlencoded_nested`, `parse_range_header`,
`percent_decode`, `percent_decode_path`, `percent_encode`, `parse_param_names`,
`status_text`, `mime_by_extension`, `mime_type`, `format_http_date`,
`parse_http_date`, `sha256_hex`, `sign_cookie`, `unsign_cookie`,
`negotiate_media`, `negotiate_charsets`, `negotiate_encodings`,
`negotiate_languages`.

## How it works

µWebSockets matches a single catch-all route (`/*`); everything Express-shaped
happens in MoonBit (`express.mbt`, `path.mbt`, `middleware.mbt`). µWebSockets
invalidates the request object when the handler returns, so the shim snapshots
method/url/query/headers up front, and request bodies are delivered asynchronously
by request id (`uwb_res_on_data`).

`src/uws_shim.cpp` is the C++/C boundary; `uws.mbt` declares the `extern "C"`
calls with `FuncRef` callbacks. Strings cross the boundary as UTF-8 `Bytes`.

`third_party/` vendors µWebSockets (`App.h` and friends, header-only) and the
parts of µSockets needed for the epoll/kqueue event loop, including the OpenSSL
TLS backend (`crypto/openssl.c`, `crypto/sni_tree.cpp`). Local patches, each
marked with a comment:

1. `libusockets.h` defines `LIBUS_NO_SSL` unless `MOONBIT_UWS_WITH_TLS` is set.
2. `internal/` and `eventing/` includes use paths relative to their own files,
   so the stubs compile without `-I` flags.
3. `crypto/openssl.c` includes `../internal/internal.h` for the same reason.
4. µWebSockets headers include the vendored `libusockets.h` by relative path.

The shim dispatches every response write on the app's TLS mode, because
µWebSockets compiles `HttpResponse<true>` and `HttpResponse<false>` separately
and their socket-write paths differ.

## Differences from Express

- Handlers and middleware must name the extra parameter (`fn(req, res, _next)`)
  because MoonBit has no arity-based overloading.
- `next` is a struct: `next.proceed()` / `next.fail(msg)` / `next.resume_with(err?)`.
- Errors are strings, not `Error` objects.
- Route patterns support `:name`, `*` and `*name`; there is no regexp route.
- Body parsing is opt-in per middleware, exactly like `body-parser`.
- `res.set()` replaces a header; use `res.append()` to add multi-value headers.
- `req.params` is a `Map[String, String]`; use `req.has_param(name)` to check existence.
- `X-Powered-By` is **never** sent.
- `compression`, `session` and `multipart` handling are out of scope (they are
  separate packages in the Express ecosystem); bring your own middleware.
- `trust proxy` accepts `"true"`, a hop count, a comma-separated IP list or the
  `loopback` / `linklocal` / `uniquelocal` presets. CIDR ranges are not parsed.
- `express.static` does not support the `setHeaders` callback.
- `Router` does not host WebSocket routes (`app.ws` is application-level only).
- `RouteInfo.method` is exposed as `http_method()` (MoonBit reserves `method`).

## Benchmark

`bench/` holds a self-contained, reproducible benchmark of this framework
against MoonBit's own HTTP server (`moonbitlang/async`) and a bare C++
µWebSockets handler. It is serial (one server under load at a time) and rotates
the target order so host drift hits all three equally.

```bash
moon build example/bench --release            # express target
cd bench/http_server_async && moon build --release && cd ../..
bash bench/run_bench.sh 50 5                  # autocannon latency numbers
ROUNDS=3 bash bench/run_bench.sh 50 5         # with the C load generator
python3 bench/render_results.py               # regenerate bench/benchmark.md
```

`autocannon` at pipelining 1 is capped by the loop-back round trip, not by the
servers, so `run_bench.sh` also drives `bench/loadgen.c`, a ~150-line C client
(epoll, N requests in flight) pinned to the second core, and writes
`bench/results/loadgen.csv`. Headline results (server CPU per request on a
pinned core, 64 connections):

| Server | 1 in flight | 16 in flight |
| --- | ---: | ---: |
| **express** | ~12 µs | **~2.5 µs** |
| moonbitlang/async | ~16 µs | ~13 µs |
| raw C++ µWebSockets | ~3 µs | ~0.9 µs |

Throughput follows the same ordering (express ~54k req/s at one in flight and
~155k at 16, vs async ~43k/~56k and raw ~74k/~825k). The gap to native C++ is
a factor of a few, never an order of magnitude, and express is faster than
MoonBit's own HTTP server in every column.

Every optimization in the code is measured and wire-format identical: one
`Bytes` blob for request headers, a slot table for requests, lazy `remote_ip`,
an ETag memo that skips the per-response SHA-256 when the body repeats, an
allocation-free path match, a `Next` that avoids closures, and `params` /
`form` / `locals` that are only allocated when read. Together with a fixed
per-request memory leak (RSS was growing 1.6 KB/request; now flat at 7.2 MB),
per-request CPU dropped from ~40 µs to **~2.5 µs** pipelined.

Full methodology, per-request cost breakdown and what is still on the table:
[`bench/benchmark.md`](bench/benchmark.md).

## Tests

`moon test` covers route matching (static, params, wildcard, prefixes, trailing
slashes, case-insensitivity), query parsing/percent decoding, status codes, SHA-256
and HMAC known-answer vectors, cookie signing, content negotiation, HTTP dates,
Range parsing, nested URL-encoded bodies and MIME resolution. The demo in
`example/main` is also a manual integration test:

```bash
moon run example/main
curl 'http://localhost:8080/users/42?tab=info'
curl -X POST -H 'Content-Type: application/json' -d '{"a":1}' http://localhost:8080/echo
```

## License

Apache-2.0. Vendored µWebSockets and µSockets sources keep their own Apache-2.0
licenses in `third_party/*/LICENSE`.
