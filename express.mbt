///|
/// A MoonBit web framework with an Express-like API, served natively by
/// µWebSockets through `src/uws_shim.cpp`.
///
/// µWebSockets matches one catch-all route (`/*`). Everything Express-shaped -
/// middleware order, route patterns, params, errors, 404 - is resolved here in
/// MoonBit, while the HTTP engine, parser and event loop stay in µWebSockets.

// ---------- global registry ----------

///|
/// Registered applications, keyed by the id handed to the shim.
let g_apps : Map[UInt64, App] = Map([])

///|
/// Per-request state, keyed by the id handed to the shim.
let g_requests : Map[UInt64, RequestState] = Map([])

///|
/// Monotonic id source for apps and requests.
let g_next_id : Array[UInt64] = [1]

///|
fn next_id() -> UInt64 {
  let id = g_next_id[0]
  g_next_id[0] = id + 1
  id
}

///|
priv struct RequestState {
  req : Req
  res : Res
  mut body_reader : ((String, Bool) -> Unit)?
}

// ---------- Request ----------

///|
pub struct Req {
  priv uws_res : UwsRes
  priv headers : Map[String, String]
  priv http_method : String
  priv url_path : String
  priv mut params : Map[String, String]
  priv query_params : Map[String, String]
  priv query_raw : String
  priv mut body_text : String
  priv mut body_json : Json?
  priv mut body_form : Map[String, String]
  priv cookies : Map[String, String]
  priv remote_ip : String
  priv mut aborted : Bool
  priv locals : Map[String, String]
  priv protocol : String
  priv secure : Bool
}

///|
pub fn Req::method(self : Req) -> String {
  self.http_method
}

///|
pub fn Req::http_method(self : Req) -> String {
  self.http_method
}

///|
pub fn Req::path(self : Req) -> String {
  self.url_path
}

///|
/// Returns a route parameter, or `""` when it is not present.
pub fn Req::param(self : Req, name : String) -> String {
  match self.params.get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::has_param(self : Req, name : String) -> Bool {
  self.params.contains(name)
}

///|
pub fn Req::params(self : Req) -> Map[String, String] {
  self.params
}

///|
/// Returns a parsed query parameter, or `""` when it is not present.
pub fn Req::query_param(self : Req, name : String) -> String {
  match self.query_params.get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::query_map(self : Req) -> Map[String, String] {
  self.query_params
}

///|
/// The raw query string, without the leading `?`.
pub fn Req::query(self : Req) -> String {
  self.query_raw
}

///|
pub fn Req::raw_query(self : Req) -> String {
  self.query_raw
}

///|
pub fn Req::header(self : Req, name : String) -> String {
  match self.headers.get(name.to_lower()) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::get(self : Req, name : String) -> String {
  self.header(name)
}

///|
pub fn Req::body(self : Req) -> String {
  self.body_text
}

///|
pub fn Req::json_body(self : Req) -> Json? {
  self.body_json
}

///|
pub fn Req::form(self : Req, name : String) -> String {
  match self.body_form.get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::form_map(self : Req) -> Map[String, String] {
  self.body_form
}

///|
/// Returns a request cookie value, or `""` when it is not present.
pub fn Req::cookie(self : Req, name : String) -> String {
  match self.cookies.get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::cookies(self : Req) -> Map[String, String] {
  self.cookies
}

///|
pub fn Req::ip(self : Req) -> String {
  self.remote_ip
}

///|
pub fn Req::is_aborted(self : Req) -> Bool {
  self.aborted
}

///|
pub fn Req::set_body(self : Req, body : String) -> Unit {
  self.body_text = body
}

///|
pub fn Req::set_json_body(self : Req, value : Json?) -> Unit {
  self.body_json = value
}

///|
pub fn Req::set_form(self : Req, value : Map[String, String]) -> Unit {
  self.body_form = value
}

///|
fn Req::set_params(self : Req, value : Array[(String, String)]) -> Unit {
  let map : Map[String, String] = Map([])
  for pair in value {
    map.set(pair.0, pair.1)
  }
  self.params = map
}

///|
fn Req::mark_aborted(self : Req) -> Unit {
  self.aborted = true
}

///|
/// Returns the request-scoped local variables map.
pub fn Req::locals(self : Req) -> Map[String, String] {
  self.locals
}

///|
/// Returns the request protocol: `"http"` or `"https"`.
pub fn Req::protocol(self : Req) -> String {
  self.protocol
}

///|
/// Returns `true` when the request was made over TLS.
pub fn Req::secure(self : Req) -> Bool {
  self.secure
}

///|
/// Content negotiation: returns the best match from `types` based on the
/// `Accept` header, or `""` when no type is acceptable.
pub fn Req::accepts(self : Req, types : Array[String]) -> String {
  let accept = self.header("accept")
  if accept == "" || accept == "*/*" {
    return if types.length() > 0 { types[0] } else { "" }
  }
  // Simple negotiation: find the first type in the Accept header that matches
  let mut best = ""
  for part in accept.split(",") {
    let part = part.trim()
    let media_range = match part.split_once(";") {
      Some((mr, _)) => mr
      None => part
    }
    for t in types {
      let t_str = t
      if media_range == t_str ||
        (media_range.has_prefix("*/") && t_str.has_suffix(media_range[1:])) ||
        (
          media_range.has_suffix("/*") &&
          t_str.has_prefix(media_range[:media_range.length() - 1])
        ) {
        return t_str
      }
      if media_range == "*/*" {
        best = if best == "" { t_str } else { best }
      }
    }
  }
  best
}

///|
/// Checks whether the request Content-Type matches `content_type`.
/// Returns the matched type or `""`.
pub fn Req::content_type_is(self : Req, content_type : String) -> String {
  let ct = self.header("content-type").to_lower()
  if ct == content_type.to_lower() {
    content_type
  } else if ct.has_prefix(content_type.to_lower() + ";") {
    content_type
  } else {
    ""
  }
}

// ---------- Response ----------

///|
pub struct Res {
  priv uws_res : UwsRes
  priv request_id : UInt64
  priv mut status_code : Int32
  priv headers : Array[(String, String)]
  priv mut ended : Bool
  priv mut aborted : Bool
  priv locals : Map[String, String]
  priv vary_headers : Array[String]
  priv is_ssl : Bool
}

///|
pub fn Res::status(self : Res, code : Int32) -> Res {
  self.status_code = code
  self
}

///|
pub fn Res::set(self : Res, name : String, value : String) -> Res {
  self.remove_header(name)
  self.headers.push((name, value))
  self
}

///|
pub fn Res::set_header(self : Res, name : String, value : String) -> Unit {
  ignore(self.set(name, value))
}

///|
/// Sets `Content-Type`.
pub fn Res::type_(self : Res, content_type : String) -> Res {
  self.set("Content-Type", content_type)
}

///|
pub fn Res::header(self : Res, name : String) -> String {
  let wanted = name.to_lower()
  let mut found = ""
  for pair in self.headers {
    if pair.0.to_lower() == wanted {
      found = pair.1
    }
  }
  found
}

///|
fn Res::has_header(self : Res, name : String) -> Bool {
  self.header(name) != ""
}

///|
fn Res::remove_header(self : Res, name : String) -> Unit {
  let wanted = name.to_lower()
  let kept : Array[(String, String)] = []
  for pair in self.headers {
    if pair.0.to_lower() != wanted {
      kept.push(pair)
    }
  }
  self.headers.clear()
  for pair in kept {
    self.headers.push(pair)
  }
}

///|
fn Res::ssl_flag(self : Res) -> Int32 {
  if self.is_ssl {
    1
  } else {
    0
  }
}

///|
pub fn Res::is_ended(self : Res) -> Bool {
  self.ended
}

///|
pub fn Res::is_aborted(self : Res) -> Bool {
  self.aborted
}

///|
pub fn Res::status_code(self : Res) -> Int32 {
  self.status_code
}

///|
/// Sends a text response. Defaults `Content-Type` to `text/html`, like
/// Express. HEAD requests are answered by µWebSockets with headers only.
pub fn Res::send(self : Res, body : String) -> Unit {
  if self.ended || self.aborted {
    return
  }
  self.ended = true
  if !self.has_header("Content-Type") {
    ignore(self.set("Content-Type", "text/html; charset=utf-8"))
  }
  self.write_head()
  let bytes = utf8_bytes(body)
  uwb_res_end(self.uws_res, self.ssl_flag(), bytes, bytes.length())
  release_request(self.request_id)
}

///|
/// Sends raw bytes, useful for static files and binary payloads.
pub fn Res::send_bytes(self : Res, body : Bytes) -> Unit {
  if self.ended || self.aborted {
    return
  }
  self.ended = true
  self.write_head()
  uwb_res_end(self.uws_res, self.ssl_flag(), body, body.length())
  release_request(self.request_id)
}

///|
pub fn Res::send_empty(self : Res) -> Unit {
  if self.ended || self.aborted {
    return
  }
  self.ended = true
  self.write_head()
  uwb_res_end_empty(self.uws_res, self.ssl_flag())
  release_request(self.request_id)
}

///|
/// Serializes `value` as JSON and sends it.
pub fn Res::json(self : Res, value : Json) -> Unit {
  ignore(self.set("Content-Type", "application/json; charset=utf-8"))
  self.send(value.stringify())
}

///|
/// Sends an already serialized JSON string.
pub fn Res::json_string(self : Res, raw : String) -> Unit {
  ignore(self.set("Content-Type", "application/json; charset=utf-8"))
  self.send(raw)
}

///|
/// Appends a `Set-Cookie` header with `Path=/`.
pub fn Res::cookie(self : Res, name : String, value : String) -> Res {
  self.set_cookie(name, value, "/", -1, false)
}

///|
/// Appends a `Set-Cookie` header. A negative `max_age` omits `Max-Age`.
pub fn Res::cookie_with(
  self : Res,
  name : String,
  value : String,
  path? : String,
  max_age? : Int32,
  http_only? : Bool,
) -> Res {
  let path = match path {
    Some(value) => value
    None => "/"
  }
  let max_age = match max_age {
    Some(value) => value
    None => -1
  }
  let http_only = match http_only {
    Some(value) => value
    None => false
  }
  self.set_cookie(name, value, path, max_age, http_only)
}

///|
/// Expires a cookie, mirroring Express `res.clearCookie`.
pub fn Res::clear_cookie(self : Res, name : String) -> Res {
  self.set_cookie(name, "", "/", 0, false)
}

///|
fn Res::set_cookie(
  self : Res,
  name : String,
  value : String,
  path : String,
  max_age : Int32,
  http_only : Bool,
) -> Res {
  let sb = StringBuilder()
  sb.write_string(name)
  sb.write_string("=")
  sb.write_string(percent_encode(value))
  if path != "" {
    sb.write_string("; Path=")
    sb.write_string(path)
  }
  if max_age >= 0 {
    sb.write_string("; Max-Age=")
    sb.write_string(max_age.to_string())
  }
  if http_only {
    sb.write_string("; HttpOnly")
  }
  self.headers.push(("Set-Cookie", sb.to_string()))
  self
}

///|
pub fn Res::redirect(self : Res, url : String) -> Unit {
  self
  .status(302)
  .set("Location", url)
  .set("Content-Type", "text/plain; charset=utf-8")
  .send("Found. Redirecting to " + url)
}

///|
fn Res::write_head(self : Res) -> Unit {
  let line = self.status_code.to_string() + " " + status_text(self.status_code)
  let status_bytes = utf8_bytes(line)
  uwb_res_write_status(
    self.uws_res,
    self.ssl_flag(),
    status_bytes,
    status_bytes.length(),
  )
  for pair in self.headers {
    let name = utf8_bytes(pair.0)
    let value = utf8_bytes(pair.1)
    uwb_res_write_header(
      self.uws_res,
      self.ssl_flag(),
      name,
      name.length(),
      value,
      value.length(),
    )
  }
}

///|
fn Res::mark_aborted(self : Res) -> Unit {
  self.aborted = true
}

///|
/// Returns the response-scoped local variables map.
pub fn Res::locals(self : Res) -> Map[String, String] {
  self.locals
}

///|
/// Appends a response header (allows multiple values for the same header).
pub fn Res::append(self : Res, name : String, value : String) -> Res {
  self.headers.push((name, value))
  self
}

///|
/// Sets the `Location` header.
pub fn Res::location(self : Res, url : String) -> Res {
  self.set("Location", url)
}

///|
/// Sets the `Link` header from an array of link objects.
/// Each link is a string like `</path>; rel="stylesheet"`.
pub fn Res::links(self : Res, links : Array[String]) -> Res {
  let joined = links.join(", ")
  self.set("Link", joined)
}

///|
/// Sets `Content-Disposition: attachment` to trigger a download.
/// If `filename` is provided, includes it in the header.
pub fn Res::attachment(self : Res, filename? : String) -> Res {
  let value = match filename {
    Some(name) => "attachment; filename=\"" + name + "\""
    None => "attachment"
  }
  self.set("Content-Disposition", value)
}

///|
/// Adds a field to the `Vary` header.
pub fn Res::vary(self : Res, field : String) -> Res {
  self.vary_headers.push(field)
  let joined = self.vary_headers.join(", ")
  self.set("Vary", joined)
}

///|
/// Transfers the file at `path` as the response.
/// Sets `Content-Type` based on file extension, `Content-Length` from file size.
pub fn Res::send_file(self : Res, path : String) -> Unit {
  if self.ended || self.aborted {
    return
  }
  let kind = fs_kind(path)
  if kind != 1 {
    self.status(404).send("Not Found: " + path)
    return
  }
  self.ended = true
  let data = fs_read_file(path)
  ignore(self.set("Content-Type", mime_type(path)))
  ignore(self.set("Content-Length", data.length().to_string()))
  self.write_head()
  uwb_res_end(self.uws_res, self.ssl_flag(), data, data.length())
  release_request(self.request_id)
}

///|
/// Transfers the file at `path` as an attachment.
/// Calls `send_file` after setting `Content-Disposition`.
pub fn Res::download(self : Res, path : String, filename? : String) -> Unit {
  ignore(self.attachment(filename?))
  self.send_file(path)
}

///|
fn release_request(request_id : UInt64) -> Unit {
  g_requests.remove(request_id)
}

// ---------- Middleware ----------

///|
pub type Handler = (Req, Res, Next) -> Unit

///|
/// Continues the middleware chain. Call `proceed()` to keep going or
/// `fail(message)` to hand control to the error middleware.
pub struct Next {
  priv run : (String?) -> Unit
  priv proceed_fn : () -> Unit
}

///|
pub fn Next::proceed(self : Next) -> Unit {
  (self.proceed_fn)()
}

///|
pub fn Next::fail(self : Next, message : String) -> Unit {
  (self.run)(Some(message))
}

///|
pub fn Next::resume_with(self : Next, error : String?) -> Unit {
  (self.run)(error)
}

///|
pub type Middleware = (Req, Res, Next) -> Unit

///|
pub type ErrorMiddleware = (String, Req, Res, Next) -> Unit

// ---------- Application ----------

///|
priv enum Layer {
  Mw(PathPattern, Middleware)
  Err(PathPattern, ErrorMiddleware)
  Route(String, PathPattern, Handler)
}

///|
pub struct App {
  priv id : UInt64
  priv uws : UwsApp
  priv mut is_ssl : Bool
  priv layers : Array[Layer]
  priv ws_routes : Array[(Int32, String)]
  priv settings : Map[String, String]
  priv locals : Map[String, String]
  priv param_callbacks : Array[(String, (Req, Next) -> Unit)]
  priv mut prepared : Bool
}

///|
/// Creates a new application.
pub fn express() -> App {
  init_shim()
  {
    id: next_id(),
    uws: uwb_app_new(),
    is_ssl: false,
    layers: [],
    ws_routes: [],
    settings: Map([]),
    locals: Map([]),
    param_callbacks: [],
    prepared: false,
  }
}

///|
/// Registers middleware for every request.
pub fn App::use(self : App, middleware : Middleware) -> Unit {
  self.layers.push(Mw(make_pattern("/"), middleware))
}

///|
/// Registers middleware that only runs for paths starting with `path`, for
/// example `app.use_at("/api", auth)`.
pub fn App::use_at(self : App, path : String, middleware : Middleware) -> Unit {
  self.layers.push(Mw(make_pattern(path), middleware))
}

///|
/// Registers error-handling middleware. It runs when a previous middleware
/// called `next.fail(...)`.
pub fn App::use_error(self : App, middleware : ErrorMiddleware) -> Unit {
  self.layers.push(Err(make_pattern("/"), middleware))
}

///|
pub fn App::use_error_at(
  self : App,
  path : String,
  middleware : ErrorMiddleware,
) -> Unit {
  self.layers.push(Err(make_pattern(path), middleware))
}

///|
/// Registers a handler for one HTTP method.
pub fn App::route(
  self : App,
  http_method : String,
  path : String,
  handler : Handler,
) -> Unit {
  self.layers.push(Route(http_method.to_upper(), make_pattern(path), handler))
}

///|
pub fn App::get(self : App, path : String, handler : Handler) -> Unit {
  self.route("GET", path, handler)
}

///|
pub fn App::post(self : App, path : String, handler : Handler) -> Unit {
  self.route("POST", path, handler)
}

///|
pub fn App::put(self : App, path : String, handler : Handler) -> Unit {
  self.route("PUT", path, handler)
}

///|
pub fn App::patch(self : App, path : String, handler : Handler) -> Unit {
  self.route("PATCH", path, handler)
}

///|
pub fn App::delete(self : App, path : String, handler : Handler) -> Unit {
  self.route("DELETE", path, handler)
}

///|
pub fn App::options(self : App, path : String, handler : Handler) -> Unit {
  self.route("OPTIONS", path, handler)
}

///|
pub fn App::head(self : App, path : String, handler : Handler) -> Unit {
  self.route("HEAD", path, handler)
}

///|
pub fn App::all(self : App, path : String, handler : Handler) -> Unit {
  self.route("ALL", path, handler)
}

///|
pub fn App::set(self : App, key : String, value : String) -> Unit {
  self.settings.set(key, value)
}

///|
pub fn App::get_setting(self : App, key : String) -> String {
  match self.settings.get(key) {
    Some(value) => value
    None => ""
  }
}

///|
/// Returns the app-scoped local variables map.
pub fn App::locals(self : App) -> Map[String, String] {
  self.locals
}

///|
/// Adds a param callback. Called when a route param with `name` is matched.
/// The callback receives `(req, next)` and should call `next.proceed()` to continue.
pub fn App::param(
  self : App,
  name : String,
  callback : (Req, Next) -> Unit,
) -> Unit {
  self.param_callbacks.push((name, callback))
}

///|
/// Registers the catch-all route and publishes the app to the shim. Must run
/// before `listen_async`.
pub fn App::prepare(self : App) -> Unit {
  if self.prepared {
    return
  }
  self.prepared = true
  g_apps.set(self.id, self)
  let pattern = utf8_bytes("/*")
  uwb_app_any(self.uws, self.id, pattern, pattern.length())
  for route in self.ws_routes {
    let route_id = route.0
    let path = utf8_bytes(route.1)
    uwb_app_ws(self.uws, route_id, path, path.length())
  }
}

///|
/// Starts listening on all interfaces and runs the event loop. This call
/// blocks until the server is closed.
pub fn App::listen(self : App, port : Int32, cb : (Bool) -> Unit) -> Unit {
  self.prepare()
  let ok = uwb_app_listen(self.uws, self.id, utf8_bytes(""), 0, port) != 0
  cb(ok)
  if ok {
    uwb_app_run(self.uws)
  }
}

///|
/// Starts listening on a specific host and runs the event loop. This call
/// blocks until the server is closed.
pub fn App::listen_host(
  self : App,
  host : String,
  port : Int32,
  cb : (Bool) -> Unit,
) -> Unit {
  self.prepare()
  let host_bytes = utf8_bytes(host)
  let ok = uwb_app_listen(
      self.uws,
      self.id,
      host_bytes,
      host_bytes.length(),
      port,
    ) !=
    0
  cb(ok)
  if ok {
    uwb_app_run(self.uws)
  }
}

///|
/// Starts listening without blocking. Call `run()` yourself afterwards, for
/// example when the process has other work to do.
pub fn App::listen_async(
  self : App,
  host : String,
  port : Int32,
  cb : (Bool) -> Unit,
) -> Unit {
  self.prepare()
  let host_bytes = utf8_bytes(host)
  let ok = uwb_app_listen(
      self.uws,
      self.id,
      host_bytes,
      host_bytes.length(),
      port,
    ) !=
    0
  cb(ok)
}

///|
/// Switches the app to TLS before it starts listening. `cert_file` and
/// `key_file` must point to PEM-encoded certificate and key. For extra
/// options (CA bundle, ciphers, ...) use `enable_tls_with`.
pub fn App::enable_tls(
  self : App,
  cert_file : String,
  key_file : String,
) -> Unit {
  self.enable_tls_with(UwsSslOptions::{
    cert_file,
    key_file,
    passphrase: None,
    dh_params_file: None,
    ca_file: None,
    ssl_ciphers: None,
  })
}

///|
/// Switches the app to TLS with full `UwsSslOptions`. Must run before
/// `listen*` (or before `prepare()`); a TLS app is started with the same
/// `listen` calls as a plain one.
pub fn App::enable_tls_with(self : App, options : UwsSslOptions) -> Unit {
  if self.prepared {
    abort("enable_tls must be called before prepare()/listen()")
  }
  enable_ssl(self.uws, options)
  self.is_ssl = true
}

///|
/// Switches to TLS and starts listening on all interfaces, blocking in the
/// µWebSockets event loop until `close()` is called.
pub fn App::listen_tls(
  self : App,
  cert_file : String,
  key_file : String,
  port : Int32,
  cb : (Bool) -> Unit,
) -> Unit {
  self.enable_tls(cert_file, key_file)
  self.listen(port, cb)
}

///|
/// Switches to TLS and starts listening on a specific host. This call blocks.
pub fn App::listen_tls_host(
  self : App,
  cert_file : String,
  key_file : String,
  host : String,
  port : Int32,
  cb : (Bool) -> Unit,
) -> Unit {
  self.enable_tls(cert_file, key_file)
  self.listen_host(host, port, cb)
}

///|
/// Switches to TLS and starts listening without blocking. Call `run()`
/// yourself afterwards.
pub fn App::listen_tls_async(
  self : App,
  cert_file : String,
  key_file : String,
  host : String,
  port : Int32,
  cb : (Bool) -> Unit,
) -> Unit {
  self.enable_tls(cert_file, key_file)
  self.listen_async(host, port, cb)
}

///|
/// Runs the µWebSockets event loop. Blocks until `close()` is called.
pub fn App::run(self : App) -> Unit {
  uwb_app_run(self.uws)
}

///|
/// Closes all sockets, which also stops the event loop.
pub fn App::close(self : App) -> Unit {
  uwb_app_close(self.uws)
}

// ---------- dispatch ----------

///|
priv struct DispatchState {
  mut idx : Int32
  mut error : String?
}

///|
/// Registers the three C callbacks. Runs once.
///
/// The lambdas must not capture anything: a non-capturing MoonBit `FuncRef`
/// is passed to C as a plain function pointer, which the shim calls directly.
fn init_shim() -> Unit {
  if g_shim_ready[0] {
    return
  }
  g_shim_ready[0] = true
  let on_request : FuncRef[(UInt64, UwsRes, UwsReq) -> Unit] = (
    app_id,
    uws_res,
    req,
  ) => dispatch_request(app_id, uws_res, req)
  let on_body : FuncRef[(UInt64, Bytes, Int32, Int32) -> Unit] = (
    request_id,
    body,
    len,
    status,
  ) => dispatch_body(request_id, body, len, status)
  let on_abort : FuncRef[(UInt64) -> Unit] = request_id => {
    dispatch_abort(request_id)
  }
  uwb_set_callbacks(on_request, on_body, on_abort)
  init_websockets()
}

///|
/// Dispatches an incoming HTTP request to the registered app.
pub fn dispatch_request(
  app_id : UInt64,
  uws_res : UwsRes,
  _uws_req : UwsReq,
) -> Unit {
  match g_apps.get(app_id) {
    Some(app) => start_request(app, uws_res)
    None => ()
  }
}

///|
/// Dispatches request body data to the pending request.
pub fn dispatch_body(
  request_id : UInt64,
  body : Bytes,
  _len : Int32,
  status : Int32,
) -> Unit {
  match g_requests.get(request_id) {
    Some(state) =>
      match state.body_reader {
        Some(reader) => {
          state.body_reader = None
          reader(utf8_string(body), status == 0)
        }
        None => ()
      }
    None => ()
  }
}

///|
/// Dispatches an abort notification to the pending request.
pub fn dispatch_abort(request_id : UInt64) -> Unit {
  match g_requests.get(request_id) {
    Some(state) => {
      state.req.mark_aborted()
      state.res.mark_aborted()
      release_request(request_id)
    }
    None => ()
  }
}

///|
let g_shim_ready : Array[Bool] = [false]

///|
fn start_request(app : App, uws_res : UwsRes) -> Unit {
  let request_id = next_id()
  let http_method = utf8_string(uwb_req_method()).to_upper()
  let url_path = utf8_string(uwb_req_url())
  let query_raw = utf8_string(uwb_req_query())
  let headers : Map[String, String] = Map([])
  let header_count = uwb_req_header_count()
  let mut index = 0
  while index < header_count {
    headers.set(
      utf8_string(uwb_req_header_name(index)).to_lower(),
      utf8_string(uwb_req_header_value(index)),
    )
    index = index + 1
  }
  let cookie_header = match headers.get("cookie") {
    Some(value) => value
    None => ""
  }
  let ssl_flag : Int32 = if app.is_ssl { 1 } else { 0 }
  let req = Req::{
    uws_res,
    headers,
    http_method,
    url_path,
    params: Map([]),
    query_params: parse_query(query_raw),
    query_raw,
    body_text: "",
    body_json: None,
    body_form: Map([]),
    cookies: parse_cookies(cookie_header),
    remote_ip: utf8_string(uwb_res_remote_address(uws_res, ssl_flag)),
    aborted: false,
    locals: Map([]),
    protocol: if app.is_ssl {
      "https"
    } else {
      "http"
    },
    secure: app.is_ssl,
  }
  let res = Res::{
    uws_res,
    request_id,
    status_code: 200,
    headers: [],
    ended: false,
    aborted: false,
    locals: Map([]),
    vary_headers: [],
    is_ssl: app.is_ssl,
  }
  let state : RequestState = { req, res, body_reader: None, }
  g_requests.set(request_id, state)
  uwb_res_on_aborted(uws_res, ssl_flag, request_id)
  dispatch(app, req, res)
}

///|
/// Starts reading the request body. `reader` receives `(body, ok)`.
fn read_body(
  req : Req,
  res : Res,
  limit : Int32,
  reader : (String, Bool) -> Unit,
) -> Unit {
  match g_requests.get(res.request_id) {
    Some(state) => {
      state.body_reader = Some(reader)
      let ssl_flag : Int32 = if res.is_ssl { 1 } else { 0 }
      uwb_res_on_data(req.uws_res, ssl_flag, res.request_id, limit)
    }
    None => reader("", false)
  }
}

///|
fn dispatch(app : App, req : Req, res : Res) -> Unit {
  let state = DispatchState::{ idx: 0, error: None, }
  let steps : Array[() -> Unit] = [fn() { () }]
  let step = fn() {
    let mut running = true
    while running && state.idx < app.layers.length() {
      let layer = app.layers[state.idx]
      state.idx = state.idx + 1
      match layer {
        Mw(pattern, middleware) =>
          if state.error is None {
            if pattern.is_any() {
              running = false
              middleware(req, res, make_next(state, steps[0]))
            } else {
              match pattern.match_path(req.path(), true) {
                Some(params) => {
                  req.set_params(params)
                  running = false
                  run_param_callbacks(app, req, state, steps[0], fn() {
                    middleware(req, res, make_next(state, steps[0]))
                  })
                }
                None => ()
              }
            }
          }
        Err(pattern, middleware) =>
          match state.error {
            Some(message) =>
              match pattern.match_path(req.path(), true) {
                Some(params) => {
                  req.set_params(params)
                  state.error = None
                  running = false
                  run_param_callbacks(app, req, state, steps[0], fn() {
                    middleware(message, req, res, make_next(state, steps[0]))
                  })
                }
                None => ()
              }
            None => ()
          }
        Route(route_method, pattern, handler) =>
          if state.error is None &&
            method_matches(route_method, req.http_method()) {
            match pattern.match_path(req.path(), false) {
              Some(params) => {
                req.set_params(params)
                running = false
                run_param_callbacks(app, req, state, steps[0], fn() {
                  handler(req, res, make_next(state, steps[0]))
                })
              }
              None => ()
            }
          }
      }
    }
    if running {
      finalize(state, req, res)
    }
  }
  steps[0] = step
  step()
}

///|
fn make_next(state : DispatchState, step : () -> Unit) -> Next {
  {
    run: fn(error) {
      state.error = error
      step()
    },
    proceed_fn: step,
  }
}

///|
/// Runs the `app.param` callbacks that apply to the params captured by the
/// layer currently being dispatched, in registration order, then invokes
/// `then_fn` (normally the layer handler). Each callback receives a `Next`:
/// calling `proceed()` moves on to the remaining callbacks and finally
/// `then_fn`; calling `fail(message)` hands control to the error middleware.
fn run_param_callbacks(
  app : App,
  req : Req,
  state : DispatchState,
  dispatch_step : () -> Unit,
  then_fn : () -> Unit,
) -> Unit {
  let cursor : Array[Int32] = [0]
  let steps : Array[() -> Unit] = [fn() { () }]
  let step_params = fn() {
    let mut i = cursor[0]
    while i < app.param_callbacks.length() {
      let (name, callback) = app.param_callbacks[i]
      cursor[0] = i + 1
      if req.has_param(name) {
        let next : Next = {
          run: fn(error) {
            state.error = error
            dispatch_step()
          },
          proceed_fn: steps[0],
        }
        callback(req, next)
        return
      }
      i = i + 1
    }
    then_fn()
  }
  steps[0] = step_params
  step_params()
}

///|
fn method_matches(route_method : String, actual : String) -> Bool {
  route_method == "ALL" ||
  route_method == actual ||
  (actual == "HEAD" && route_method == "GET")
}

///|
fn finalize(state : DispatchState, req : Req, res : Res) -> Unit {
  if res.is_ended() || res.is_aborted() {
    return
  }
  match state.error {
    Some(message) => {
      println("express: unhandled error: " + message)
      res.status(500).send("Internal Server Error")
    }
    None =>
      // Auto-handle OPTIONS preflight on 404
      if req.http_method() == "OPTIONS" {
        res
        .status(200)
        .set("Allow", "GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD")
        .set("Content-Type", "text/plain; charset=utf-8")
        .send("")
      } else {
        res.status(404).send("Cannot " + req.http_method() + " " + req.path())
      }
  }
}
