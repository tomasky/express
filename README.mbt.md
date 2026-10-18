# kupas/express

An Express-style web framework for **native** MoonBit, served by
[µWebSockets](https://github.com/uNetworking/uWebSockets) (the same C++ engine
behind uWebSockets.js). Routing, middleware, params and error handling are
written in MoonBit; the HTTP parser, router entry point and event loop come
from µWebSockets through a small C ABI shim.

Inspired by [fulmine.js](https://github.com/nigrosimone/fulmine.js), which puts
an Express-compatible API on µWebSockets for Node.js.

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

## Requirements

- MoonBit toolchain with the `native` backend (`preferred_target = "native"`).
- A C++17 compiler (`g++`/`clang++`) because µWebSockets is header-only C++.
- `zlib` development headers, linked as `-lz`.

TLS is off by default: the vendored uSockets is compiled with `LIBUS_NO_SSL`.
Define `MOONBIT_UWS_WITH_TLS` and link OpenSSL to re-enable it.

## Building an application

This package is a **library**, so the executable package that depends on it
must provide the C++ runtime and zlib at link time:

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
moon run example/main        # the demo server, listens on :8080
moon test                    # router/query unit tests
```

## API

Application:

| MoonBit | Express |
| --- | --- |
| `express()` | `express()` |
| `app.get/post/put/patch/delete/options/head/all(path, handler)` | `app.METHOD(path, handler)` |
| `app.route(method, path, handler)` | - |
| `app.use(mw)` / `app.use_at(path, mw)` | `app.use(mw)` / `app.use(path, mw)` |
| `app.use_error(mw)` / `app.use_error_at(path, mw)` | `app.use((err, req, res, next) => ...)` |
| `app.listen(port, cb)` / `app.listen_host(host, port, cb)` | `app.listen(...)` |
| `app.listen_async(host, port, cb)` + `app.run()` | - |
| `app.set(key, value)` / `app.get_setting(key)` | `app.set/get` |

`app.listen` blocks in the µWebSockets event loop, the way a native server
normally does; `listen_async` plus `run()` gives you back the thread.

Request (`Req`): `method()`, `path()`, `param(name)`, `params()`,
`query_param(name)`, `query_map()`, `raw_query()`, `header(name)` / `get(name)`,
`body()`, `json_body()`, `form(name)`, `form_map()`, `ip()`, `is_aborted()`.

Response (`Res`): `status(code)`, `set(name, value)`, `header(name)`,
`type_(content_type)`, `send(text)`, `send_bytes(bytes)`, `send_empty()`,
`json(Json)`, `json_string(raw)`, `redirect(url)`, `is_ended()`,
`is_aborted()`.

Middleware: a middleware is `(Req, Res, Next) -> Unit`; call `next.proceed()`
to continue or `next.fail(message)` to jump to error middleware. A route
handler is `(Req, Res, Next) -> Unit` as well, so `next.proceed()` falls
through to later routes like Express.

Built-ins: `express_json()`, `express_urlencoded()`, `express_text()`,
`express_raw()`, `express_static(dir)`, `cors()`, `logger()`.

Helpers exported for tests and custom routers: `make_pattern`,
`PathPattern::match_path`, `split_path`, `parse_query`, `parse_urlencoded`,
`percent_decode`, `percent_decode_path`, `parse_param_names`, `status_text`.

### Differences from Express

- Handlers and middleware must name the extra parameter (`fn(req, res, _next)`)
  because MoonBit has no arity-based overloading.
- `next` is a struct: `next.proceed()` / `next.fail(msg)` / `next.resume_with(err?)`.
- Errors are strings, not `Error` objects.
- Route patterns support `:name`, `*` and `*name`; there is no regexp route.
- Body parsing is opt-in per middleware, exactly like `body-parser`.

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

## Tests

`moon test` covers route matching (static, params, wildcard, prefixes, trailing
slashes, case-insensitivity), query parsing/percent decoding and the status-code
table. The demo in `example/main` is also a manual integration test:

```bash
moon run example/main
curl 'http://localhost:8080/users/42?tab=info'
curl -X POST -H 'Content-Type: application/json' -d '{"a":1}' http://localhost:8080/echo
```

## License

Apache-2.0. Vendored µWebSockets and µSockets sources keep their own Apache-2.0
licenses in `third_party/*/LICENSE`.
