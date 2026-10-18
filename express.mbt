///|
/// MoonBit express-like web framework, binding to uWebSockets.js.

// ---------- FFI to uWebSockets.js ----------

///|
#external
pub type UwsApp

///|
#external
pub type UwsRes

///|
#external
pub type UwsReq

///|
extern "js" fn uws_app() -> UwsApp =
  #| () => require('uWebSockets.js').App()

///|
extern "js" fn uws_app_get(app : UwsApp, path : String, cb : (UwsRes, UwsReq) -> Unit) -> Unit =
  #| (app, path, cb) => app.get(path, (res, req) => cb(res, req))

///|
extern "js" fn uws_app_post(app : UwsApp, path : String, cb : (UwsRes, UwsReq) -> Unit) -> Unit =
  #| (app, path, cb) => app.post(path, (res, req) => cb(res, req))

///|
extern "js" fn uws_app_put(app : UwsApp, path : String, cb : (UwsRes, UwsReq) -> Unit) -> Unit =
  #| (app, path, cb) => app.put(path, (res, req) => cb(res, req))

///|
extern "js" fn uws_app_del(app : UwsApp, path : String, cb : (UwsRes, UwsReq) -> Unit) -> Unit =
  #| (app, path, cb) => app.del(path, (res, req) => cb(res, req))

///|
extern "js" fn uws_app_all(app : UwsApp, path : String, cb : (UwsRes, UwsReq) -> Unit) -> Unit =
  #| (app, path, cb) => app.any(path, (res, req) => cb(res, req))

///|
extern "js" fn uws_listen(app : UwsApp, port : Int, cb : (Bool) -> Unit) -> Unit =
  #| (app, port, cb) => app.listen(port, (token) => cb(!!token))

///|
extern "js" fn uws_res_write_status(res : UwsRes, status : String) -> Unit =
  #| (res, s) => res.writeStatus(s)

///|
extern "js" fn uws_res_write_header(res : UwsRes, name : String, value : String) -> Unit =
  #| (res, n, v) => res.writeHeader(n, v)

///|
extern "js" fn uws_res_end(res : UwsRes, body : String) -> Unit =
  #| (res, b) => res.end(b)

///|
extern "js" fn uws_res_end_empty(res : UwsRes) -> Unit =
  #| (res) => res.end()

///|
extern "js" fn uws_req_get_method(req : UwsReq) -> String =
  #| (req) => req.getMethod()

///|
extern "js" fn uws_req_get_url(req : UwsReq) -> String =
  #| (req) => req.getUrl()

///|
extern "js" fn uws_req_get_header(req : UwsReq, name : String) -> String =
  #| (req, n) => { const v = req.getHeader(n); return v == null ? '' : v; }

///|
extern "js" fn uws_req_get_parameter(req : UwsReq, index : Int) -> String =
  #| (req, i) => { const v = req.getParameter(i); return v == null ? '' : v; }

///|
extern "js" fn uws_req_get_query(req : UwsReq) -> String =
  #| (req) => { const v = req.getQuery(); return v == null ? '' : v; }

///|
pub extern "js" fn uws_res_on_aborted(res : UwsRes, cb : () -> Unit) -> Unit =
  #| (res, cb) => res.onAborted(cb)

pub extern "js" fn uws_read_body(res : UwsRes, cb : (String) -> Unit) -> Unit =
  #| (res, cb) => {
  #|   let buf = Buffer.alloc(0);
  #|   res.onData((chunk, isLast) => {
  #|     buf = Buffer.concat([buf, Buffer.from(chunk)]);
  #|     if (isLast) { cb(buf.toString('utf8')); }
  #|   });
  #|   res.onAborted(() => { cb(''); });
  #| }

// ---------- Express-like types ----------

///|
pub struct Req {
  uws_req : UwsReq
  uws_res : UwsRes
  http_method : String
  path : String
  params : Map[String, String]
  mut body : String
  query_raw : String
}

///|
pub fn Req::get_method(self : Req) -> String {
  self.http_method
}

///|
pub fn Req::path(self : Req) -> String {
  self.path
}

///|
pub fn Req::param(self : Req, name : String) -> String {
  match self.params.get(name) {
    Some(v) => v
    None => ""
  }
}

///|
pub fn Req::params(self : Req) -> Map[String, String] {
  self.params
}

///|
pub fn Req::query(self : Req) -> String {
  self.query_raw
}

///|
pub fn Req::header(self : Req, name : String) -> String {
  uws_req_get_header(self.uws_req, name)
}

///|
pub fn Req::body(self : Req) -> String {
  self.body
}

///|
pub fn Req::set_body(self : Req, v : String) -> Unit {
  self.body = v
}

///|
pub struct Res {
  uws_res : UwsRes
  mut status_code : Int
  headers : Array[(String, String)]
  mut ended : Bool
}

///|
pub fn Res::status(self : Res, code : Int) -> Res {
  self.status_code = code
  self
}

///|
pub fn Res::set_header(self : Res, name : String, value : String) -> Unit {
  self.headers.push((name, value))
}

///|
pub fn Res::send(self : Res, body : String) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  uws_res_write_status(self.uws_res, self.status_code.to_string() + " ")
  for h in self.headers {
    uws_res_write_header(self.uws_res, h.0, h.1)
  }
  uws_res_end(self.uws_res, body)
}

///|
pub fn Res::send_empty(self : Res) -> Unit {
  if self.ended {
    return
  }
  self.ended = true
  uws_res_write_status(self.uws_res, self.status_code.to_string() + " ")
  for h in self.headers {
    uws_res_write_header(self.uws_res, h.0, h.1)
  }
  uws_res_end_empty(self.uws_res)
}

///|
pub fn Res::json(self : Res, body : String) -> Unit {
  // set content-type if not present
  let mut has_ct = false
  for h in self.headers {
    if h.0.to_lower() == "content-type" {
      has_ct = true
    }
  }
  if !has_ct {
    self.headers.push(("Content-Type", "application/json"))
  }
  self.send(body)
}

///|
pub fn Res::redirect(self : Res, url : String) -> Unit {
  ignore(self.status(302))
  self.set_header("Location", url)
  self.send_empty()
}

// ---------- App ----------

///|
pub type Handler = (Req, Res) -> Unit

///|
pub type Middleware = (Req, Res, () -> Unit) -> Unit

///|
pub struct App {
  uws : UwsApp
  middlewares : Array[Middleware]
}

///|
pub fn express() -> App {
  App::{ uws: uws_app(), middlewares: [] }
}

///|
pub fn App::use_middleware(self : App, mw : Middleware) -> Unit {
  self.middlewares.push(mw)
}

///|
pub fn parse_param_names(path : String) -> Array[String] {
  let names : Array[String] = []
  for seg in path.split("/") {
    let s = seg.to_owned()
    if s.has_prefix(":") {
      let name = s[1:].to_owned()
      names.push(name)
    }
  }
  names
}

///|
fn wrap_handler(h : Handler) -> Middleware {
  fn(req, res, _next) { h(req, res) }
}

///|
fn run_chain(chain : Array[Middleware], req : Req, res : Res) -> Unit {
  let idx : Array[Int] = [0]
  let holder : Array[() -> Unit] = [fn() { () }]
  let step : () -> Unit = fn() {
    if idx[0] < chain.length() {
      let mw = chain[idx[0]]
      idx[0] = idx[0] + 1
      mw(req, res, fn() { holder[0]() })
    }
  }
  holder[0] = step
  step()
}

///|
fn make_req(uws_req : UwsReq, uws_res : UwsRes, param_names : Array[String]) -> Req {
  let params : Map[String, String] = Map([])
  let mut idx = 0
  for name in param_names {
    params.set(name, uws_req_get_parameter(uws_req, idx))
    idx = idx + 1
  }
  let r = Req::{
    uws_req,
    uws_res,
    http_method: uws_req_get_method(uws_req),
    path: uws_req_get_url(uws_req),
    params,
    body: "",
    query_raw: uws_req_get_query(uws_req),
  }
  r
}

///|
fn make_res(uws_res : UwsRes) -> Res {
  Res::{ uws_res, status_code: 200, headers: [], ended: false }
}

///|
fn register(app : App, http_method : String, path : String, handler : Handler) -> Unit {
  let param_names = parse_param_names(path)
  let chain_builder = fn(uws_res : UwsRes, uws_req : UwsReq) {
    let req = make_req(uws_req, uws_res, param_names)
    let res = make_res(uws_res)
    let chain : Array[Middleware] = []
    for m in app.middlewares {
      chain.push(m)
    }
    chain.push(wrap_handler(handler))
    run_chain(chain, req, res)
  }
  if http_method == "GET" {
    uws_app_get(app.uws, path, chain_builder)
  } else if http_method == "POST" {
    uws_app_post(app.uws, path, chain_builder)
  } else if http_method == "PUT" {
    uws_app_put(app.uws, path, chain_builder)
  } else if http_method == "DELETE" {
    uws_app_del(app.uws, path, chain_builder)
  } else {
    uws_app_all(app.uws, path, chain_builder)
  }
}

///|
pub fn App::get(self : App, path : String, handler : Handler) -> Unit {
  register(self, "GET", path, handler)
}

///|
pub fn App::post(self : App, path : String, handler : Handler) -> Unit {
  register(self, "POST", path, handler)
}

///|
pub fn App::put(self : App, path : String, handler : Handler) -> Unit {
  register(self, "PUT", path, handler)
}

///|
pub fn App::delete(self : App, path : String, handler : Handler) -> Unit {
  register(self, "DELETE", path, handler)
}

///|
pub fn App::all(self : App, path : String, handler : Handler) -> Unit {
  register(self, "ALL", path, handler)
}

///|
pub fn App::listen(self : App, port : Int, cb : (Bool) -> Unit) -> Unit {
  uws_listen(self.uws, port, cb)
}

// ---------- Built-in middleware helpers ----------

///|
pub fn express_json() -> Middleware {
  fn(req, res, next) {
    let m = req.get_method().to_upper()
    if m == "POST" || m == "PUT" || m == "PATCH" {
      let cl = req.header("content-length").to_lower()
      let te = req.header("transfer-encoding").to_lower()
      let has_body = (cl != "" && cl != "0") || te.has_prefix("chunked")
      if has_body {
        uws_read_body(res.uws_res, fn(body) {
          req.set_body(body)
          next()
        })
      } else {
        next()
      }
    } else {
      next()
    }
  }
}

///|
pub fn express_text() -> Middleware {
  express_json()
}

///|
pub fn express_urlencoded() -> Middleware {
  fn(_req, _res, next) { next() }
}
