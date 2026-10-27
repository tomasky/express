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
/// Per-request state, in a flat slot table instead of a hash map. The id handed
/// to the shim packs `(generation << 32) | slot`, so a lookup is one array
/// index plus one comparison instead of three hash operations, and memory is
/// bounded by peak concurrency rather than by total requests served.
let g_request_slots : Array[RequestState?] = []

///|
/// Current generation per slot. Bumped every time the slot is handed out, so an
/// `onAborted`/`onData` callback that arrives after its request finished cannot
/// reach the newer request that reused the slot: the generations differ.
let g_request_gens : Array[UInt64] = []

///|
/// Slots of finished requests, ready to be reused.
let g_request_free : Array[Int32] = []

///|
/// Takes a free slot and returns the packed request id. The slot is filled by
/// `request_slot_fill` once the `Req`/`Res` exist; nothing can call back in
/// between, so no lookup ever observes the empty window.
fn request_slot_reserve() -> UInt64 {
  match g_request_free.pop() {
    Some(slot) => {
      let gen = g_request_gens[slot] + 1UL
      g_request_gens[slot] = gen
      (gen << 32) | slot.to_uint64()
    }
    None => {
      let slot = g_request_slots.length()
      g_request_slots.push(None)
      g_request_gens.push(1UL)
      (1UL << 32) | slot.to_uint64()
    }
  }
}

///|
/// Stores the state in the slot the id was reserved from.
fn request_slot_fill(id : UInt64, state : RequestState) -> Unit {
  let (gen, slot) = request_slot_split(id)
  if slot >= 0 && slot < g_request_slots.length() && g_request_gens[slot] == gen {
    g_request_slots[slot] = Some(state)
  }
}

///|
/// Unpacks an id into `(generation, slot)`.
fn request_slot_split(id : UInt64) -> (UInt64, Int32) {
  (id >> 32, (id & 0xFFFFFFFFUL).to_int())
}

///|
fn request_slot_get(id : UInt64) -> RequestState? {
  let (gen, slot) = request_slot_split(id)
  if slot < 0 || slot >= g_request_slots.length() {
    return None
  }
  if g_request_gens[slot] != gen {
    return None
  }
  g_request_slots[slot]
}

///|
/// Clears the slot. Idempotent: a second call for the same id finds the slot
/// already empty (or reused with a different generation) and does nothing, so a
/// slot is never pushed onto the free list twice.
fn request_slot_clear(id : UInt64) -> Unit {
  let (gen, slot) = request_slot_split(id)
  if slot < 0 || slot >= g_request_slots.length() {
    return
  }
  if g_request_gens[slot] != gen {
    return
  }
  if g_request_slots[slot] is Some(_) {
    g_request_slots[slot] = None
    g_request_free.push(slot)
  }
}

///|
/// ASCII case-insensitive string equality, for HTTP header names (which are
/// ASCII by spec).
///
/// Header names are compared this way instead of lowercasing both sides,
/// because `String::to_lower` has to allocate whenever the name contains an
/// uppercase letter -- and the common names (`Content-Type`, `ETag`,
/// `Set-Cookie`, ...) all do. That made every header lookup on the response
/// path allocate two or three short strings.
fn eq_header_name(a : String, b : String) -> Bool {
  let len = a.length()
  if len != b.length() {
    return false
  }
  let mut index = 0
  while index < len {
    let mut left = a.unsafe_get(index).to_int()
    let mut right = b.unsafe_get(index).to_int()
    if left != right {
      if left >= 65 && left <= 90 {
        left = left + 32
      }
      if right >= 65 && right <= 90 {
        right = right + 32
      }
      if left != right {
        return false
      }
    }
    index = index + 1
  }
  true
}

///|
/// Monotonic id source for applications. Request ids come from the slot table.
let g_next_id : Array[UInt64] = [1]

///|
/// Shared no-op used to break the middleware-chain cycle when a request ends.
let g_noop_step : Step = fn() { () }

///|
fn next_id() -> UInt64 {
  let id = g_next_id[0]
  g_next_id[0] = id + 1UL
  id
}

///|

///|
/// One link of the middleware chain.
type Step = () -> Unit

///|
priv struct RequestState {
  req : Req
  res : Res
  app : App
  mut body_reader : ((String, Bool) -> Unit)?
  // The middleware chain's `steps` cell, kept only so `release_request` can
  // break the reference cycle described there.
  mut chain : Array[Step]?
}

// ---------- Request ----------

///|
/// Identifies the route currently handling the request, mirroring
/// `req.route` in Express.
pub struct RouteInfo {
  http_method : String
  path : String
}

///|
/// The method of the matched route. `method` is a reserved word in MoonBit,
/// so the accessor is declared as `http_method` and exposed under the Express
/// name with `#alias`.
#alias(method)
pub fn RouteInfo::http_method(self : RouteInfo) -> String {
  self.http_method
}

///|
pub struct Req {
  priv uws_res : UwsRes
  priv request_id : UInt64
  priv app_ref : App
  priv settings : Map[String, String]
  // All request headers as one `Bytes` blob of `name\0value\0` pairs. A
  // per-header array of `String`s cost two allocations and two FFI calls per
  // header on every request, even for handlers that read none; the blob is a
  // single copy and values are decoded only when a handler asks for one.
  priv headers_raw : Bytes
  priv http_method : String
  priv mut url_path : String
  priv mut base_url : String
  priv original_url : String
  // Materialised on first write/read: a route with no params (every static
  // route) should not allocate an empty map it will never look at.
  priv mut params : Map[String, String]?
  priv mut base_params : Array[(String, String)]
  priv mut route_info : RouteInfo?
  priv mut next : Next?
  priv mut query_params : Map[String, String]?
  priv query_raw : String
  priv mut body_text : String
  priv mut body_bytes : Bytes
  priv mut body_json : Json?
  priv mut body_form : Map[String, String]?
  priv mut body_form_json : Json?
  priv mut cookies : Map[String, String]?
  // Resolved on first use: `getpeername` is a syscall, and a handler that
  // never asks for the address (the common case) should not pay for it.
  priv mut remote_ip_cache : String?
  // The dispatcher splits the path once per request and hands the same array
  // to every layer it tries; `mount_relative` rewrites `url_path`, so that is
  // the only place the cache has to be dropped.
  priv mut path_segments_cache : Array[String]?
  priv mut aborted : Bool
  priv mut locals : Map[String, String]?
  priv protocol : String
}

///|
/// The HTTP method of the request in uppercase (`"GET"`, `"POST"`, ...).
///
/// This is `req.method` in Express. `method` is a reserved word in MoonBit,
/// so the function is declared as `http_method` and exposed under the Express
/// name with `#alias`.
#alias(method)
pub fn Req::http_method(self : Req) -> String {
  self.http_method
}

///|
/// Matches a layer against this request: static patterns are compared straight
/// against the raw path, dynamic ones fall back to the split path, which is
/// itself split only once per request.
fn Req::match_pattern(
  self : Req,
  pattern : PathPattern,
  prefix : Bool,
) -> Array[(String, String)]? {
  match pattern.match_static_path(self.url_path, prefix) {
    Some(true) => Some([])
    Some(false) => None
    None => pattern.match_parts(self.path_segments(), prefix)
  }
}

///|
/// Splits the request path once and reuses the result across route layers.
fn Req::path_segments(self : Req) -> Array[String] {
  match self.path_segments_cache {
    Some(parts) => parts
    None => {
      let parts = split_path(self.url_path)
      self.path_segments_cache = Some(parts)
      parts
    }
  }
}

///|
pub fn Req::path(self : Req) -> String {
  self.url_path
}

///|
/// The URL of the request relative to the current mount point, path plus
/// query string, like `req.url` inside an Express router.
pub fn Req::url(self : Req) -> String {
  if self.query_raw == "" {
    self.url_path
  } else {
    self.url_path + "?" + self.query_raw
  }
}

///|
/// The full URL of the original request, `req.originalUrl`.
pub fn Req::original_url(self : Req) -> String {
  self.original_url
}

///|
/// The mount path of the current router, `""` at the app level.
pub fn Req::base_url(self : Req) -> String {
  self.base_url
}

///|
/// `req.xhr`: whether the request was issued by an XMLHttpRequest-style
/// client (`X-Requested-With: XMLHttpRequest`).
pub fn Req::xhr(self : Req) -> Bool {
  self.header("x-requested-with").to_lower() == "xmlhttprequest"
}

///|
/// The route currently handling the request, like `req.route`.
pub fn Req::route(self : Req) -> RouteInfo? {
  self.route_info
}

///|
/// The application that owns this request, like `req.app`.
pub fn Req::app(self : Req) -> App {
  self.app_ref
}

///|
/// The remote address of the request, like `req.socket.remoteAddress`. The
/// value is fetched from the socket the first time it is needed and cached for
/// the rest of the request.
fn Req::remote_ip(self : Req) -> String {
  match self.remote_ip_cache {
    Some(ip) => ip
    None => {
      let ip = utf8_string(
        uwb_res_remote_address(self.uws_res, self.ssl_flag()),
      )
      self.remote_ip_cache = Some(ip)
      ip
    }
  }
}

///|
/// The remote TCP port of the request, like `req.socket.remotePort`.
pub fn Req::remote_port(self : Req) -> Int32 {
  uwb_res_remote_port(self.uws_res, self.ssl_flag())
}

///|
fn Req::ssl_flag(self : Req) -> Int32 {
  if self.protocol == "https" {
    1
  } else {
    0
  }
}

///|
fn Req::setting(self : Req, key : String) -> String {
  match self.settings.get(key) {
    Some(value) => value
    None => ""
  }
}

///|
fn Req::set_next(self : Req, value : Next) -> Unit {
  self.next = Some(value)
}

///|
fn Req::set_route(self : Req, value : RouteInfo?) -> Unit {
  self.route_info = value
}

///|
/// Returns a route parameter, or `""` when it is not present.
pub fn Req::param(self : Req, name : String) -> String {
  match self.param_map_value().get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::has_param(self : Req, name : String) -> Bool {
  self.param_map_value().contains(name)
}

///|
pub fn Req::params(self : Req) -> Map[String, String] {
  self.param_map_value()
}

///|
/// The params map, allocating it only when a caller actually asks for it.
fn Req::param_map_value(self : Req) -> Map[String, String] {
  match self.params {
    Some(map) => map
    None => Map([])
  }
}

///|
/// Returns a parsed query parameter, or `""` when it is not present.
pub fn Req::query_param(self : Req, name : String) -> String {
  match self.query_map_value().get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::query_map(self : Req) -> Map[String, String] {
  self.query_map_value()
}

///|
/// The parsed query string, built on first use. Parsing every request up
/// front cost a `Map` allocation even when the handler never looked at the
/// query.
fn Req::query_map_value(self : Req) -> Map[String, String] {
  match self.query_params {
    Some(map) => map
    None => {
      let map = parse_query(self.query_raw)
      self.query_params = Some(map)
      map
    }
  }
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
  match find_header_value(self.headers_raw, name) {
    Some((start, len)) =>
      utf8_string(copy_byte_range(self.headers_raw, start, len))
    None => ""
  }
}

///|
/// Byte-wise search of the `name\0value\0` header blob. Names are compared
/// ASCII case-insensitively without materialising either side as a `String`.
fn find_header_value(blob : Bytes, name : String) -> (Int32, Int32)? {
  let total = blob.length()
  let name_len = name.length()
  let mut pos = 0
  let mut found : (Int32, Int32)? = None
  while pos < total {
    let name_start = pos
    while pos < total && blob.unsafe_get(pos).to_int() != 0 {
      pos = pos + 1
    }
    let this_name_len = pos - name_start
    pos = pos + 1
    let value_start = pos
    while pos < total && blob.unsafe_get(pos).to_int() != 0 {
      pos = pos + 1
    }
    let value_len = pos - value_start
    pos = pos + 1
    if this_name_len == name_len {
      let mut index = 0
      let mut same = true
      while index < name_len {
        let mut left = blob.unsafe_get(name_start + index).to_int()
        let mut right = name.unsafe_get(index).to_int()
        if left != right {
          if left >= 65 && left <= 90 {
            left = left + 32
          }
          if right >= 65 && right <= 90 {
            right = right + 32
          }
          if left != right {
            same = false
            break
          }
        }
        index = index + 1
      }
      if same {
        // Last match wins, matching the previous map-based behaviour.
        found = Some((value_start, value_len))
      }
    }
  }
  found
}

///|
/// Copies `len` bytes starting at `start` into a fresh `Bytes`.
fn copy_byte_range(source : Bytes, start : Int32, len : Int32) -> Bytes {
  let out : Array[Byte] = Array::make(len, b'\x00')
  let mut index = 0
  while index < len {
    out[index] = source.unsafe_get(start + index)
    index = index + 1
  }
  Bytes::from_array(out)
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
/// The raw request body bytes. Always binary safe; `express_raw` fills it.
pub fn Req::body_bytes(self : Req) -> Bytes {
  self.body_bytes
}

///|
/// Form data parsed by `express_urlencoded(extended=true)`, with nested
/// objects and arrays, or `None` for the flat parser.
pub fn Req::form_json(self : Req) -> Json? {
  self.body_form_json
}

///|
pub fn Req::form(self : Req, name : String) -> String {
  match self.form_map_value().get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::form_map(self : Req) -> Map[String, String] {
  self.form_map_value()
}

///|
fn Req::form_map_value(self : Req) -> Map[String, String] {
  match self.body_form {
    Some(map) => map
    None => Map([])
  }
}

///|
/// Returns a request cookie value, or `""` when it is not present.
pub fn Req::cookie(self : Req, name : String) -> String {
  match self.cookie_map_value().get(name) {
    Some(value) => value
    None => ""
  }
}

///|
pub fn Req::cookies(self : Req) -> Map[String, String] {
  self.cookie_map_value()
}

///|
/// The parsed `Cookie` header, built on first use.
fn Req::cookie_map_value(self : Req) -> Map[String, String] {
  match self.cookies {
    Some(map) => map
    None => {
      let map = parse_cookies(self.header("cookie"))
      self.cookies = Some(map)
      map
    }
  }
}

///|
/// The client address. Follows `X-Forwarded-For` when `trust proxy` is set,
/// mirroring `req.ip`.
pub fn Req::ip(self : Req) -> String {
  let addresses = self.forwarded_addresses()
  let limit = self.trusted_address_count(addresses)
  addresses[limit]
}

///|
/// The `X-Forwarded-For` chain, farthest first, like `req.ips`. Empty when no
/// proxy is trusted.
pub fn Req::ips(self : Req) -> Array[String] {
  let addresses = self.forwarded_addresses()
  let limit = self.trusted_address_count(addresses)
  let result : Array[String] = []
  let mut index = limit
  while index >= 1 {
    result.push(addresses[index])
    index = index - 1
  }
  result
}

///|
/// `[socket, ...X-Forwarded-For reversed]`, closest hop first.
fn Req::forwarded_addresses(self : Req) -> Array[String] {
  let result : Array[String] = [self.remote_ip()]
  let forwarded = self.header("x-forwarded-for")
  if forwarded != "" {
    let hops : Array[String] = []
    for raw in forwarded.split(",") {
      let hop = raw.to_owned().trim().to_owned()
      if hop != "" {
        hops.push(hop)
      }
    }
    let mut index = hops.length() - 1
    while index >= 0 {
      result.push(hops[index])
      index = index - 1
    }
  }
  result
}

///|
/// Index of the first untrusted address in the forwarded chain, which is the
/// closest one to the server that `req.ip` reports.
fn Req::trusted_address_count(self : Req, addresses : Array[String]) -> Int32 {
  let setting = self.setting("trust proxy")
  let mut index = 0
  while index < addresses.length() - 1 {
    if !trusted_proxy(setting, addresses[index], index) {
      return index
    }
    index = index + 1
  }
  addresses.length() - 1
}

///|
/// Evaluates the `trust proxy` setting against one hop. Accepts `true`,
/// `false`, a hop count, or a comma-separated list of IPs and the predefined
/// ranges `loopback`, `linklocal` and `uniquelocal`.
fn trusted_proxy(setting : String, address : String, index : Int32) -> Bool {
  let setting = setting.trim().to_owned()
  if setting == "" || setting.to_lower() == "false" {
    return false
  }
  if setting.to_lower() == "true" {
    return true
  }
  if is_all_digits(setting) {
    return index < parse_hop_count(setting)
  }
  for raw in setting.split(",") {
    let entry = raw.to_owned().trim().to_lower()
    let address = address.to_lower()
    if entry == address {
      return true
    }
    if entry == "loopback" && is_loopback(address) {
      return true
    }
    if entry == "linklocal" && is_linklocal(address) {
      return true
    }
    if entry == "uniquelocal" && is_uniquelocal(address) {
      return true
    }
  }
  false
}

///|
fn is_all_digits(value : String) -> Bool {
  if value == "" {
    return false
  }
  for ch in value {
    let digit = ch.to_int() - 48
    if digit < 0 || digit > 9 {
      return false
    }
  }
  true
}

///|
fn parse_hop_count(value : String) -> Int32 {
  let mut count = 0
  for ch in value {
    count = count * 10 + (ch.to_int() - 48)
  }
  count
}

///|
fn is_loopback(address : String) -> Bool {
  address == "::1" || address.has_prefix("127.")
}

///|
fn is_linklocal(address : String) -> Bool {
  address.has_prefix("169.254.") || address.has_prefix("fe80")
}

///|
fn is_uniquelocal(address : String) -> Bool {
  if address.has_prefix("10.") || address.has_prefix("192.168.") {
    return true
  }
  if address.has_prefix("fc") || address.has_prefix("fd") {
    return true
  }
  if address.has_prefix("172.") {
    let parts = address.split(".").to_array()
    if parts.length() == 4 {
      let octet = parse_hop_count(parts[1].to_owned())
      octet >= 16 && octet <= 31
    } else {
      false
    }
  } else {
    false
  }
}

///|
/// Returns the request protocol: `"http"` or `"https"`, honoring
/// `X-Forwarded-Proto` when the client is trusted.
pub fn Req::protocol(self : Req) -> String {
  if trusted_proxy(self.setting("trust proxy"), self.remote_ip(), 0) {
    let forwarded = self.header("x-forwarded-proto")
    if forwarded != "" {
      for raw in forwarded.split(",") {
        let value = raw.to_owned().trim().to_owned().to_lower()
        if value != "" {
          return value
        }
      }
    }
  }
  self.protocol
}

///|
/// Returns `true` when the request was made over TLS.
pub fn Req::secure(self : Req) -> Bool {
  self.protocol() == "https"
}

///|
/// The `Host` header (or `X-Forwarded-Host` for trusted clients), `req.host`.
pub fn Req::host(self : Req) -> String {
  if trusted_proxy(self.setting("trust proxy"), self.remote_ip(), 0) {
    let forwarded = self.header("x-forwarded-host")
    if forwarded != "" {
      for raw in forwarded.split(",") {
        let value = raw.to_owned().trim().to_owned()
        if value != "" {
          return value
        }
      }
    }
  }
  self.header("host")
}

///|
/// The host name without the port, like `req.hostname`.
pub fn Req::hostname(self : Req) -> String {
  let host = self.host()
  if host == "" {
    return ""
  }
  let offset = if host.has_prefix("[") {
    match host.find("]") {
      Some(index) => index + 1
      None => 0
    }
  } else {
    0
  }
  let rest = host[offset:].to_owned()
  match rest.find(":") {
    Some(_) => host[:offset].to_owned()
    None => host
  }
}

///|
/// The subdomain parts of `req.hostname`, most specific first, with the
/// `subdomain offset` setting (default `2`) segments removed. IP hosts yield
/// an empty array, like Express.
pub fn Req::subdomains(self : Req) -> Array[String] {
  self.subdomains_with(self.setting("subdomain offset"))
}

///|
/// Same as `subdomains`, with an explicit offset. A negative offset is
/// treated as `0`.
pub fn Req::subdomains_with(self : Req, offset : String) -> Array[String] {
  let hostname = self.hostname()
  if hostname == "" {
    return []
  }
  let parts : Array[String] = if is_ip_address(hostname) {
    [hostname]
  } else {
    let reversed : Array[String] = []
    let segments = hostname.split(".").to_array()
    let mut index = segments.length() - 1
    while index >= 0 {
      reversed.push(segments[index].to_owned())
      index = index - 1
    }
    reversed
  }
  let start = if offset == "" { 2 } else { parse_hop_count(offset) }
  let result : Array[String] = []
  let mut index = start
  while index < parts.length() {
    result.push(parts[index])
    index = index + 1
  }
  result
}

///|
fn is_ip_address(value : String) -> Bool {
  if value.contains(":") {
    return true
  }
  let segments = value.split(".").to_array()
  if segments.length() != 4 {
    return false
  }
  for raw in segments {
    let segment = raw.to_owned()
    if segment == "" || !is_all_digits(segment) {
      return false
    }
  }
  true
}

///|
/// Content negotiation: the best match from `types` for the `Accept` header,
/// or `""` when none is acceptable. Extensions such as `html` are supported.
pub fn Req::accepts(self : Req, types : Array[String]) -> String {
  negotiate_media(self.header("accept"), types)
}

///|
/// `req.acceptsCharsets`, returning the client's preferred charset out of
/// `charsets` or `""`.
pub fn Req::accepts_charsets(self : Req, charsets : Array[String]) -> String {
  negotiate_charsets(self.header("accept-charset"), charsets)
}

///|
/// `req.acceptsEncodings`, returning the client's preferred encoding out of
/// `encodings` or `""`.
pub fn Req::accepts_encodings(self : Req, encodings : Array[String]) -> String {
  negotiate_encodings(self.header("accept-encoding"), encodings)
}

///|
/// `req.acceptsLanguages`, returning the client's preferred language out of
/// `languages` or `""`.
pub fn Req::accepts_languages(self : Req, languages : Array[String]) -> String {
  negotiate_languages(self.header("accept-language"), languages)
}

///|
/// The outcome of parsing a `Range` header, mirroring `range-parser`.
pub enum RangeResult {
  /// No `Range` header.
  NoRange
  /// The header was malformed (`-2`).
  Malformed
  /// The header asked for bytes outside the entity (`-1`).
  Unsatisfiable
  /// Inclusive `(start, end)` byte ranges.
  Ranges(Array[(Int32, Int32)])
}

///|
/// Parses the `Range` header for an entity of `size` bytes, like
/// `req.range(size)`.
pub fn Req::range(self : Req, size : Int32) -> RangeResult {
  parse_range_header(self.header("range"), size)
}

///|
/// Parses a `Range` header for an entity of `size` bytes, the same grammar as
/// the `range-parser` package: `bytes=0-4`, `bytes=5-`, `bytes=-3` and
/// multiple comma separated ranges.
pub fn parse_range_header(header : String, size : Int32) -> RangeResult {
  if header == "" {
    return NoRange
  }
  let equals = match header.find("=") {
    Some(index) => index
    None => return Malformed
  }
  if header[:equals].to_owned().to_lower() != "bytes" {
    return Unsatisfiable
  }
  let ranges : Array[(Int32, Int32)] = []
  for raw in header[equals + 1:].split(",") {
    let part = raw.to_owned().trim().to_owned()
    if part == "" {
      continue
    }
    let dash = match part.find("-") {
      Some(index) => index
      None => return Malformed
    }
    let start_text = part[:dash].to_owned().trim().to_owned()
    let end_text = part[dash + 1:].to_owned().trim().to_owned()
    let mut start = if start_text == "" {
      -1
    } else {
      parse_hop_count(start_text)
    }
    let mut end = if end_text == "" { -1 } else { parse_hop_count(end_text) }
    if start_text == "" && end_text == "" {
      return Malformed
    }
    if start == -1 {
      start = size - end
      end = size - 1
      if start < 0 {
        continue
      }
    } else if end == -1 {
      end = size - 1
    }
    if start > end || start >= size {
      continue
    }
    if end >= size {
      end = size - 1
    }
    ranges.push((start, end))
  }
  if ranges.length() == 0 {
    return Unsatisfiable
  }
  Ranges(ranges)
}

///|
/// `req.fresh`: whether the conditional request headers match the current
/// response, so the response can be a `304 Not Modified`.
pub fn Req::fresh(self : Req) -> Bool {
  if self.http_method != "GET" && self.http_method != "HEAD" {
    return false
  }
  let modified_since = self.header("if-modified-since")
  let none_match = self.header("if-none-match")
  if modified_since == "" && none_match == "" {
    return false
  }
  let cache_control = self.header("cache-control")
  if cache_control != "" && cache_control.to_lower().contains("no-cache") {
    return false
  }
  let res = match request_slot_get(self.request_id) {
    Some(state) => state.res
    None => return false
  }
  match res.status_code() {
    200..<=299 | 304 => ()
    _ => return false
  }
  if none_match != "" && none_match != "*" {
    let etag = res.header("ETag")
    if etag == "" {
      return false
    }
    let mut etag_stale = true
    for raw in none_match.split(",") {
      let token = raw.to_owned().trim().to_owned()
      if token == etag || token == "W/" + etag || "W/" + token == etag {
        etag_stale = false
      }
    }
    if etag_stale {
      return false
    }
  }
  if modified_since != "" {
    let last_modified = res.header("Last-Modified")
    if last_modified == "" {
      return false
    }
    let lm = match parse_http_date(last_modified) {
      Some(value) => value
      None => return false
    }
    let ims = match parse_http_date(modified_since) {
      Some(value) => value
      None => return false
    }
    if lm > ims {
      return false
    }
  }
  true
}

///|
/// `req.stale`, the negation of `req.fresh`.
pub fn Req::stale(self : Req) -> Bool {
  !self.fresh()
}

///|
/// Returns a signed cookie, verified against the `cookie secret` setting.
/// `""` when the cookie is missing or its signature does not match.
pub fn Req::signed_cookie(self : Req, name : String) -> String {
  let raw = self.cookie(name)
  if !raw.has_prefix("s:") {
    return ""
  }
  match unsign_cookie(self.setting("cookie secret"), raw[2:].to_owned()) {
    Some(value) => value
    None => ""
  }
}

///|
/// All cookies with verified signatures, without the `s:` prefix.
pub fn Req::signed_cookies(self : Req) -> Map[String, String] {
  let secret = self.setting("cookie secret")
  let out : Map[String, String] = Map([])
  for pair in self.cookie_map_value().iter() {
    let value = pair.1
    if value.has_prefix("s:") {
      match unsign_cookie(secret, value[2:].to_owned()) {
        Some(unsigned) => out.set(pair.0, unsigned)
        None => ()
      }
    }
  }
  out
}

///|
pub fn Req::set_body(self : Req, body : String) -> Unit {
  self.body_text = body
}

///|
pub fn Req::set_body_bytes(self : Req, body : Bytes) -> Unit {
  self.body_bytes = body
}

///|
pub fn Req::set_form_json(self : Req, value : Json?) -> Unit {
  self.body_form_json = value
}

///|
pub fn Req::set_json_body(self : Req, value : Json?) -> Unit {
  self.body_json = value
}

///|
pub fn Req::set_form(self : Req, value : Map[String, String]) -> Unit {
  self.body_form = Some(value)
}

///|
/// Replaces the route params. Params captured by a parent router are merged
/// in first, so mounted routers keep `req.params` populated.
fn Req::set_params(self : Req, value : Array[(String, String)]) -> Unit {
  if self.base_params.length() == 0 && value.length() == 0 {
    // Static route: nothing to merge, so leave `params` unallocated.
    self.params = None
    return
  }
  let map : Map[String, String] = Map([])
  for pair in self.base_params {
    map.set(pair.0, pair.1)
  }
  for pair in value {
    map.set(pair.0, pair.1)
  }
  self.params = Some(map)
}

///|
fn Req::mark_aborted(self : Req) -> Unit {
  self.aborted = true
}

///|
/// Returns the request-scoped local variables map.
pub fn Req::locals(self : Req) -> Map[String, String] {
  match self.locals {
    Some(map) => map
    None => {
      let map : Map[String, String] = Map([])
      self.locals = Some(map)
      map
    }
  }
}

///|
pub fn Req::is_aborted(self : Req) -> Bool {
  self.aborted
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
  priv settings : Map[String, String]
  priv mut status_code : Int32
  priv headers : Array[(String, String)]
  priv mut ended : Bool
  priv mut aborted : Bool
  priv mut headers_sent : Bool
  priv mut locals : Map[String, String]?
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
  let value = if eq_header_name(name, "content-type") {
    mime_content_type(value)
  } else {
    value
  }
  // Overwrite the existing entry in place instead of removing and re-pushing
  // it, which allocated a scratch array on every `res.set`.
  let mut found = false
  let mut duplicate = false
  let mut index = 0
  let len = self.headers.length()
  while index < len {
    if eq_header_name(self.headers[index].0, name) {
      if found {
        duplicate = true
      } else {
        self.headers[index] = (name, value)
        found = true
      }
    }
    index = index + 1
  }
  if duplicate {
    self.remove_header(name)
    self.headers.push((name, value))
  } else if !found {
    self.headers.push((name, value))
  }
  self
}

///|
pub fn Res::set_header(self : Res, name : String, value : String) -> Unit {
  ignore(self.set(name, value))
}

///|
/// Alias of `header`, matching `res.get` in Express.
pub fn Res::get(self : Res, name : String) -> String {
  self.header(name)
}

///|
/// Sets `Content-Type`, accepting either a media type or an extension like
/// `html`, and adding the default charset like Express does.
pub fn Res::type_(self : Res, content_type : String) -> Res {
  self.set("Content-Type", content_type)
}

///|
pub fn Res::header(self : Res, name : String) -> String {
  let mut found = ""
  for pair in self.headers {
    if eq_header_name(pair.0, name) {
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
/// Drops every header matching `name`, compacting the array in place. The
/// previous version rebuilt a fresh array and copied the survivors into it.
fn Res::remove_header(self : Res, name : String) -> Unit {
  let mut write = 0
  let mut read = 0
  let len = self.headers.length()
  while read < len {
    let pair = self.headers[read]
    if !eq_header_name(pair.0, name) {
      self.headers[write] = pair
      write = write + 1
    }
    read = read + 1
  }
  while self.headers.length() > write {
    ignore(self.headers.pop())
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
/// Whether the status line and headers have been written to the socket
/// already (after `write`, `flush_headers` or a `send`).
pub fn Res::headers_sent(self : Res) -> Bool {
  self.headers_sent
}

///|
pub fn Res::status_code(self : Res) -> Int32 {
  self.status_code
}

///|
fn Res::setting(self : Res, key : String) -> String {
  match self.settings.get(key) {
    Some(value) => value
    None => ""
  }
}

///|
fn Res::request(self : Res) -> Req? {
  match request_slot_get(self.request_id) {
    Some(state) => Some(state.req)
    None => None
  }
}

///|
fn Res::application(self : Res) -> App? {
  match request_slot_get(self.request_id) {
    Some(state) => Some(state.app)
    None => None
  }
}

///|
fn Res::etag_enabled(self : Res) -> Bool {
  self.setting("etag") != "false"
}

///|
fn Res::request_fresh(self : Res) -> Bool {
  match self.request() {
    Some(req) => req.fresh()
    None => false
  }
}

///|
/// Byte-for-byte equality, used by the ETag memo below.
fn bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Largest body the ETag memo retains, so one big response cannot pin memory.
let g_etag_memo_limit : Int32 = 8192

///|
/// The last body hashed and the tag computed for it. Responses repeat far more
/// often than they differ (a page, a JSON payload, a static asset) and the ETag
/// is a pure function of the body, so an identical body can reuse the tag
/// without rehashing. The hash costs ~1.5 us per response on this box; this
/// removes it for repeated bodies and leaves every output byte identical.
///
/// One array element holds the pair so a single read sees both halves; the
/// value returned is always the one validated against the caller's body.
let g_etag_memo : Array[(Bytes, String)] = [(Bytes::make(0, b'\x00'), "")]

///|
/// A weak ETag for in-memory bodies: `W/"<length>-<hash>"`, the shape used by
/// the `etag` package that Express relies on.
fn weak_etag(data : Bytes) -> String {
  let small = data.length() <= g_etag_memo_limit
  if small {
    let entry = g_etag_memo[0]
    if entry.1 != "" && bytes_equal(entry.0, data) {
      return entry.1
    }
  }
  // `base64` of a 32-byte digest is 44 characters ending in `=`, and only the
  // first 27 are kept, so the `=` never reaches the output -- dropping the
  // `replace_all` pass removes a 44-character copy per response.
  let digest = base64_encode(sha256_bytes(data))
  let tag = "W/\"" +
    data.length().to_string() +
    "-" +
    digest[:27].to_owned() +
    "\""
  if small {
    g_etag_memo[0] = (data, tag)
  }
  tag
}

///|
/// A stats-based weak ETag for files, `W/"<size>-<mtime>"` in hex.
fn stats_etag(size : Int32, mtime : Int64) -> String {
  "W/\"" + size.to_string() + "-" + mtime.to_string() + "\""
}

///|
/// Writes the buffered headers and the body, applying Express' rules for
/// `ETag`, `Content-Length`, conditional requests and empty bodies.
fn Res::finish_bytes(self : Res, body : Bytes) -> Unit {
  if self.ended || self.aborted {
    return
  }
  if self.headers_sent || self.ended {
    self.ended = true
    ignore(uwb_res_write(self.uws_res, self.ssl_flag(), body, body.length()))
    uwb_res_end_empty(self.uws_res, self.ssl_flag())
    release_request(self.request_id)
    return
  }
  self.ended = true
  if !self.has_header("ETag") && self.etag_enabled() {
    ignore(self.set("ETag", weak_etag(body)))
  }
  if self.request_fresh() {
    self.status_code = 304
  }
  if self.status_code == 204 || self.status_code == 304 {
    self.remove_header("Content-Type")
    self.remove_header("Content-Length")
    self.remove_header("Transfer-Encoding")
    self.write_head()
    uwb_res_end_empty(self.uws_res, self.ssl_flag())
    release_request(self.request_id)
    return
  }
  let req = self.request()
  let is_head = match req {
    Some(req) => req.http_method() == "HEAD"
    None => false
  }
  if is_head && !self.has_header("Content-Length") {
    ignore(self.set("Content-Length", body.length().to_string()))
  }
  self.write_head()
  if is_head {
    uwb_res_end_empty(self.uws_res, self.ssl_flag())
  } else {
    uwb_res_end(self.uws_res, self.ssl_flag(), body, body.length())
  }
  release_request(self.request_id)
}

///|
/// Sends a text response. Defaults `Content-Type` to `text/html`, like
/// Express. HEAD requests are answered by µWebSockets with headers only.
pub fn Res::send(self : Res, body : String) -> Unit {
  if self.ended || self.aborted {
    return
  }
  if !self.has_header("Content-Type") {
    ignore(self.type_("html"))
  }
  self.finish_bytes(utf8_bytes(body))
}

///|
/// Sends raw bytes, useful for static files and binary payloads. Defaults
/// `Content-Type` to `application/octet-stream`, like `res.send(Buffer)`.
pub fn Res::send_bytes(self : Res, body : Bytes) -> Unit {
  if self.ended || self.aborted {
    return
  }
  if !self.has_header("Content-Type") {
    ignore(self.type_("bin"))
  }
  self.finish_bytes(body)
}

///|
/// Ends the response without a body.
pub fn Res::send_empty(self : Res) -> Unit {
  if self.ended || self.aborted {
    return
  }
  self.finish_bytes(Bytes::make(0, b'\x00'))
}

///|
/// Sets the status from `code` and sends the matching reason phrase (or the
/// number) as the body, like `res.sendStatus`.
pub fn Res::send_status(self : Res, code : Int32) -> Unit {
  ignore(self.status(code))
  let message = status_text(code)
  let body = if message == "Unknown" { code.to_string() } else { message }
  ignore(self.type_("txt"))
  self.send(body)
}

///|
/// Streams a chunk of the response body. Writes the status line and buffered
/// headers on first use. Returns `false` on socket backpressure.
pub fn Res::write(self : Res, chunk : String) -> Bool {
  self.write_bytes(utf8_bytes(chunk))
}

///|
/// Streams a binary chunk of the response body.
pub fn Res::write_bytes(self : Res, chunk : Bytes) -> Bool {
  if self.ended || self.aborted {
    return false
  }
  if !self.headers_sent {
    self.headers_sent = true
    self.write_head()
  }
  uwb_res_write(self.uws_res, self.ssl_flag(), chunk, chunk.length()) != 0
}

///|
/// Ends a streamed response.
pub fn Res::end_stream(self : Res) -> Unit {
  if self.ended || self.aborted {
    return
  }
  if !self.headers_sent {
    self.headers_sent = true
    self.write_head()
  }
  self.ended = true
  uwb_res_end_empty(self.uws_res, self.ssl_flag())
  release_request(self.request_id)
}

///|
/// Writes the status line and headers without ending the response, for
/// streaming responses (Server-Sent Events, chunked downloads).
pub fn Res::flush_headers(self : Res) -> Unit {
  if self.ended || self.aborted || self.headers_sent {
    return
  }
  self.headers_sent = true
  self.write_head()
}

///|
/// Serializes `value` as JSON and sends it.
pub fn Res::json(self : Res, value : Json) -> Unit {
  ignore(self.set("Content-Type", "application/json; charset=utf-8"))
  let raw = if self.setting("json escape") == "true" {
    escape_json_html(value.stringify())
  } else {
    value.stringify()
  }
  self.send(raw)
}

///|
/// Escapes `<`, `>`, `&`, `U+2028` and `U+2029` in a JSON string, mirroring
/// the `json escape` setting.
fn escape_json_html(raw : String) -> String {
  raw
  .replace_all(old="&", new="\\u0026")
  .replace_all(old="<", new="\\u003c")
  .replace_all(old=">", new="\\u003e")
  .replace_all(old="\u{2028}", new="\\u2028")
  .replace_all(old="\u{2029}", new="\\u2029")
}

///|
/// Sends an already serialized JSON string.
pub fn Res::json_string(self : Res, raw : String) -> Unit {
  ignore(self.set("Content-Type", "application/json; charset=utf-8"))
  self.send(raw)
}

///|
/// Sends JSONP. When the callback query parameter (named by the
/// `jsonp callback name` setting, `callback` by default) is present, the body
/// is a script invoking it; otherwise the response is plain JSON.
pub fn Res::jsonp(self : Res, value : Json) -> Unit {
  let callback_name = match self.setting("jsonp callback name") {
    "" => "callback"
    name => name
  }
  let raw = match self.request() {
    Some(req) => req.query_param(callback_name)
    None => ""
  }
  ignore(self.set("X-Content-Type-Options", "nosniff"))
  if raw == "" {
    ignore(self.set("Content-Type", "application/json; charset=utf-8"))
    self.send(value.stringify())
    return
  }
  let callback = sanitize_jsonp_callback(raw)
  if callback == "" {
    self
    .status(500)
    .send("Callback parameter must consist of characters in [\\[\\]\\w$.]")
    return
  }
  ignore(self.set("Content-Type", "text/javascript; charset=utf-8"))
  let payload = value
    .stringify()
    .replace_all(old="\u{2028}", new="\\u2028")
    .replace_all(old="\u{2029}", new="\\u2029")
  self.send(
    "/**/ typeof " +
    callback +
    " === 'function' && " +
    callback +
    "(" +
    payload +
    ");",
  )
}

///|
fn sanitize_jsonp_callback(raw : String) -> String {
  let sb = StringBuilder()
  for ch in raw {
    let code = ch.to_int()
    let alnum = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95
    if alnum || ch == '$' || ch == '.' || ch == '[' || ch == ']' || ch == '\\' {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// Content negotiation for responses, like `res.format`. `handlers` maps a
/// media type or extension (or `"default"`) to a handler; when nothing
/// matches and no default is given the request fails with `406`.
pub fn Res::format(self : Res, handlers : Array[(String, Handler)]) -> Unit {
  let keys : Array[String] = []
  let mut default_handler : Handler? = None
  for pair in handlers {
    if pair.0 == "default" {
      default_handler = Some(pair.1)
    } else {
      keys.push(pair.0)
    }
  }
  let req = self.request()
  let key = match req {
    Some(req) => if keys.length() > 0 { req.accepts(keys) } else { "" }
    None => ""
  }
  ignore(self.vary("Accept"))
  let mut handled = false
  if key != "" {
    ignore(self.type_(mime_for_type_name(key)))
    for pair in handlers {
      if pair.0 == key {
        match req {
          Some(req) =>
            match req.next {
              Some(next) => (pair.1)(req, self, next)
              None => ()
            }
          None => ()
        }
        handled = true
      }
    }
  }
  if handled {
    return
  }
  match default_handler {
    Some(handler) =>
      match req {
        Some(req) =>
          match req.next {
            Some(next) => handler(req, self, next)
            None => ()
          }
        None => ()
      }
    None =>
      match req {
        Some(req) =>
          match req.next {
            Some(next) => next.fail_status(406, "Not Acceptable")
            None => self.status(406).send("Not Acceptable")
          }
        None => self.status(406).send("Not Acceptable")
      }
  }
}

///|
/// Appends a `Set-Cookie` header with `Path=/`.
pub fn Res::cookie(self : Res, name : String, value : String) -> Res {
  self.set_cookie(name, value, "/", -1, false, "", "", false, "", false)
}

///|
/// Appends a `Set-Cookie` header. A negative `max_age` omits `Max-Age` and
/// `expires` is a full HTTP date string. With `signed` the value is prefixed
/// with `s:` and signed with the `cookie secret` setting, like
/// `res.cookie(name, value, { signed: true })`.
pub fn Res::cookie_with(
  self : Res,
  name : String,
  value : String,
  path? : String,
  max_age? : Int32,
  http_only? : Bool,
  domain? : String,
  expires? : String,
  secure? : Bool,
  same_site? : String,
  signed? : Bool,
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
  let domain = match domain {
    Some(value) => value
    None => ""
  }
  let expires = match expires {
    Some(value) => value
    None => ""
  }
  let secure = match secure {
    Some(value) => value
    None => false
  }
  let same_site = match same_site {
    Some(value) => value
    None => ""
  }
  let signed = match signed {
    Some(value) => value
    None => false
  }
  self.set_cookie(
    name, value, path, max_age, http_only, domain, expires, secure, same_site, signed,
  )
}

///|
/// Expires a cookie, mirroring Express `res.clearCookie`.
pub fn Res::clear_cookie(self : Res, name : String, path? : String) -> Res {
  let path = match path {
    Some(value) => value
    None => "/"
  }
  self.set_cookie(
    name, "", path, 0, false, "", "Thu, 01 Jan 1970 00:00:00 GMT", false, "", false,
  )
}

///|
fn Res::set_cookie(
  self : Res,
  name : String,
  value : String,
  path : String,
  max_age : Int32,
  http_only : Bool,
  domain : String,
  expires : String,
  secure : Bool,
  same_site : String,
  signed : Bool,
) -> Res {
  let stored = if signed {
    "s:" + sign_cookie(self.setting("cookie secret"), value)
  } else {
    value
  }
  let sb = StringBuilder()
  sb.write_string(name)
  sb.write_string("=")
  sb.write_string(percent_encode(stored))
  if max_age >= 0 {
    sb.write_string("; Max-Age=")
    sb.write_string(max_age.to_string())
  }
  if domain != "" {
    sb.write_string("; Domain=")
    sb.write_string(domain)
  }
  if path != "" {
    sb.write_string("; Path=")
    sb.write_string(path)
  }
  if expires != "" {
    sb.write_string("; Expires=")
    sb.write_string(expires)
  }
  if http_only {
    sb.write_string("; HttpOnly")
  }
  if secure {
    sb.write_string("; Secure")
  }
  if same_site != "" {
    sb.write_string("; SameSite=")
    sb.write_string(same_site)
  }
  self.headers.push(("Set-Cookie", sb.to_string()))
  self
}

///|
/// Redirects to `url` with `302 Found` (or the given status), negotiating a
/// text or HTML body from the `Accept` header like Express.
pub fn Res::redirect(self : Res, url : String, status? : Int32) -> Unit {
  let code = match status {
    Some(value) => value
    None => 302
  }
  let address = encode_url(url)
  ignore(self.set("Location", address))
  let accepted = match self.request() {
    Some(req) => req.accepts(["html", "text"])
    None => "text"
  }
  let message = status_text(code)
  let body = if accepted == "html" {
    ignore(self.type_("html"))
    "<p>" + escape_html(message + ". Redirecting to " + address) + "</p>"
  } else if accepted == "text" {
    ignore(self.type_("text"))
    message + ". Redirecting to " + address
  } else {
    ""
  }
  ignore(self.status(code))
  ignore(self.set("Content-Length", body.length().to_string()))
  if body == "" {
    self.ended = true
    self.write_head()
    uwb_res_end_empty(self.uws_res, self.ssl_flag())
  } else {
    self.ended = true
    self.write_head()
    let bytes = utf8_bytes(body)
    uwb_res_end(self.uws_res, self.ssl_flag(), bytes, bytes.length())
  }
  release_request(self.request_id)
}

///|
/// Percent-encodes a URL for a `Location` header, leaving reserved characters
/// and already-escaped `%XX` sequences untouched (a small `encodeurl`).
fn encode_url(url : String) -> String {
  let bytes = utf8_bytes(url)
  let sb = StringBuilder()
  let mut index = 0
  while index < bytes.length() {
    let byte = bytes[index].to_int()
    let printable = byte >= 0x21 && byte <= 0x7e
    let safe = printable &&
      byte != 0x22 &&
      byte != 0x23 &&
      byte != 0x24 &&
      byte != 0x27 &&
      byte != 0x28 &&
      byte != 0x29 &&
      byte != 0x2a &&
      byte != 0x2b &&
      byte != 0x2c &&
      byte != 0x3c &&
      byte != 0x3e &&
      byte != 0x5c &&
      byte != 0x5e &&
      byte != 0x60 &&
      byte != 0x7b &&
      byte != 0x7c &&
      byte != 0x7d
    if byte == 0x25 {
      if index + 2 < bytes.length() &&
        is_hex_digit(bytes[index + 1].to_int()) &&
        is_hex_digit(bytes[index + 2].to_int()) {
        sb.write_char('%')
        sb.write_char(bytes[index + 1].to_int().unsafe_to_char())
        sb.write_char(bytes[index + 2].to_int().unsafe_to_char())
        index = index + 3
        continue
      }
      sb.write_string("%25")
      index = index + 1
      continue
    }
    if safe {
      sb.write_char(byte.unsafe_to_char())
    } else {
      sb.write_string("%")
      sb.write_char(hex_char(byte / 16))
      sb.write_char(hex_char(byte % 16))
    }
    index = index + 1
  }
  sb.to_string()
}

///|
fn is_hex_digit(value : Int32) -> Bool {
  (value >= 48 && value <= 57) ||
  (value >= 65 && value <= 70) ||
  (value >= 97 && value <= 102)
}

///|
/// Escapes HTML special characters, like `escape-html`.
pub fn escape_html(value : String) -> String {
  value
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&#39;")
}

///|
fn Res::write_head(self : Res) -> Unit {
  let status_bytes = status_line_bytes(self.status_code)
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
  match self.locals {
    Some(map) => map
    None => {
      let map : Map[String, String] = Map([])
      self.locals = Some(map)
      map
    }
  }
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
/// Options shared by `res.send_file` and `express_static`, modeled on the
/// `send` package Express delegates to.
pub struct FileOptions {
  /// `"ignore"` (default), `"deny"` or `"allow"`.
  dotfiles : String
  /// File served for directory requests, `"index.html"` by default. `""`
  /// disables directory indexes.
  index : String
  etag : Bool
  last_modified : Bool
  /// `Cache-Control: public, max-age=N` in seconds; negative disables it.
  max_age : Int32
  immutable : Bool
  /// Whether a missing file falls through to the next middleware.
  fallthrough : Bool
  /// Extra extensions tried when the exact path is missing, like
  /// `["html"]`.
  extensions : Array[String]
  /// Whether directory requests without a trailing slash get a `301`.
  redirect : Bool
}

///|
pub fn FileOptions::default() -> FileOptions {
  {
    dotfiles: "ignore",
    index: "index.html",
    etag: true,
    last_modified: true,
    max_age: 0,
    immutable: false,
    fallthrough: true,
    extensions: [],
    redirect: true,
  }
}

///|
/// Transfers the file at `path` as the response, like `res.sendFile`: sets
/// `Content-Type`, `Content-Length`, `Last-Modified`, a weak `ETag`, and
/// handles conditional requests and byte ranges.
pub fn Res::send_file(
  self : Res,
  path : String,
  options? : FileOptions,
) -> Unit {
  if self.ended || self.aborted {
    return
  }
  let options = match options {
    Some(value) => value
    None => FileOptions::default()
  }
  if !(options.dotfiles == "allow") && has_dotfile_segment(path) {
    if options.dotfiles == "deny" {
      self.status(403).send("Forbidden")
    } else {
      self.status(404).send("Not Found")
    }
    return
  }
  let kind = fs_kind(path)
  if kind != 1 {
    self.status(404).send("Not Found")
    return
  }
  let mut data = fs_read_file(path)
  let size = data.length()
  let mut status : Int32 = 200
  ignore(self.set("Accept-Ranges", "bytes"))
  match self.request() {
    Some(req) =>
      match req.range(size) {
        Ranges(ranges) => {
          let (start, end) = combine_ranges(ranges)
          data = slice_bytes(data, start, end)
          status = 206
          ignore(
            self.set(
              "Content-Range",
              "bytes " +
              start.to_string() +
              "-" +
              end.to_string() +
              "/" +
              size.to_string(),
            ),
          )
        }
        Unsatisfiable => {
          ignore(self.set("Content-Range", "bytes */" + size.to_string()))
          self.status(416).send("Range Not Satisfiable")
          return
        }
        NoRange | Malformed => ()
      }
    None => ()
  }
  if !self.has_header("Content-Type") {
    ignore(self.set("Content-Type", mime_type(path)))
  }
  let mtime = fs_mtime(path)
  if options.last_modified && mtime >= 0 {
    ignore(self.set("Last-Modified", format_http_date(mtime)))
  }
  if options.etag && self.etag_enabled() && !self.has_header("ETag") {
    ignore(self.set("ETag", stats_etag(size, mtime)))
  }
  if options.max_age >= 0 && !self.has_header("Cache-Control") {
    ignore(
      self.set(
        "Cache-Control",
        "public, max-age=" +
        options.max_age.to_string() +
        (if options.immutable { ", immutable" } else { "" }),
      ),
    )
  }
  if status == 200 && self.request_fresh() {
    status = 304
  }
  if status == 304 {
    self.remove_header("Content-Type")
    self.remove_header("Content-Length")
    self.remove_header("Transfer-Encoding")
  }
  let is_head = match self.request() {
    Some(req) => req.http_method() == "HEAD"
    None => false
  }
  if is_head && status != 304 && !self.has_header("Content-Length") {
    ignore(self.set("Content-Length", data.length().to_string()))
  }
  ignore(self.status(status))
  self.ended = true
  self.write_head()
  if status == 304 || is_head {
    uwb_res_end_empty(self.uws_res, self.ssl_flag())
  } else {
    uwb_res_end(self.uws_res, self.ssl_flag(), data, data.length())
  }
  release_request(self.request_id)
}

///|
/// Transfers the file at `path` as an attachment.
/// Calls `send_file` after setting `Content-Disposition`.
pub fn Res::download(
  self : Res,
  path : String,
  filename? : String,
  options? : FileOptions,
) -> Unit {
  ignore(self.attachment(filename?))
  self.send_file(path, options?)
}

///|
/// Renders `view` through the app's view engine and sends the result, like
/// `res.render`. `locals` and `res.locals` are merged with `app.locals`.
pub fn Res::render(self : Res, view : String, locals? : Json) -> Unit {
  let app = match self.application() {
    Some(app) => app
    None => {
      self.status(500).send("res.render called outside of a request")
      return
    }
  }
  let options = merged_view_options(app, self.locals(), locals)
  let html = app.render(view, locals=options) catch {
    error => {
      self.status(500).send("View render failed: " + error.to_string())
      return
    }
  }
  if !self.has_header("Content-Type") {
    ignore(self.type_("html"))
  }
  self.send(html)
}

///|
fn merged_view_options(
  app : App,
  res_locals : Map[String, String],
  locals : Json?,
) -> Json {
  let map : Map[String, Json] = Map([])
  for pair in app.locals.iter() {
    map.set(pair.0, Json::string(pair.1))
  }
  for pair in res_locals.iter() {
    map.set(pair.0, Json::string(pair.1))
  }
  match locals {
    Some(Json::Object(entries)) =>
      for pair in entries.iter() {
        map.set(pair.0, pair.1)
      }
    _ => ()
  }
  Json::object(map)
}

///|
/// Merges byte ranges into one, the `combine: true` mode of `range-parser`
/// that `send` uses.
fn combine_ranges(ranges : Array[(Int32, Int32)]) -> (Int32, Int32) {
  let sorted = ranges.copy()
  sorted.sort_by(fn(a, b) {
    if a.0 == b.0 {
      if a.1 < b.1 {
        -1
      } else if a.1 > b.1 {
        1
      } else {
        0
      }
    } else if a.0 < b.0 {
      -1
    } else {
      1
    }
  })
  let start = sorted[0].0
  let mut end = sorted[0].1
  let mut index = 1
  while index < sorted.length() {
    let (next_start, next_end) = sorted[index]
    if next_start <= end + 1 {
      if next_end > end {
        end = next_end
      }
    } else {
      return (start, end)
    }
    index = index + 1
  }
  (start, end)
}

///|
fn slice_bytes(data : Bytes, start : Int32, end : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut index = start
  while index <= end && index < data.length() {
    out.push(data[index])
    index = index + 1
  }
  Bytes::from_array(out)
}

///|
/// Whether any path segment starts with a dot.
fn has_dotfile_segment(path : String) -> Bool {
  for segment in path.split("/") {
    let segment = segment.to_owned()
    if segment.length() > 1 && segment.has_prefix(".") {
      return true
    }
  }
  false
}

///|
fn release_request(request_id : UInt64) -> Unit {
  // The middleware chain is reference counted and contains cycles, which
  // reference counting cannot reclaim: `dispatch_layers` stores its `step`
  // closure into `steps[0]` while that closure captures `steps` (so
  // `steps <-> step`), and `step` itself captures the request, the response
  // and the layer list. `Req.next` similarly points at a `Next` whose closures
  // capture the same objects. Left alone every request keeps its whole object
  // graph alive for the life of the process (measured: ~1.6 KB per request, on
  // every route, 404s included). Once the response ends the chain can no
  // longer legitimately continue, so both links are dropped here.
  match request_slot_get(request_id) {
    Some(state) => {
      state.req.next = None
      match state.chain {
        Some(steps) => {
          steps[0] = g_noop_step
          state.chain = None
        }
        None => ()
      }
    }
    None => ()
  }
  request_slot_clear(request_id)
}

// ---------- Middleware ----------

///|
pub type Handler = (Req, Res, Next) -> Unit

///|
/// Continues the middleware chain. Call `proceed()` to keep going or
/// `fail(message)` to hand control to the error middleware.
pub struct Next {
  // The dispatch cursor and the master continuation, stored directly instead
  // of three closures per `Next` (one for each way the next link is used).
  // The methods below mutate `state` inline and call `step`, which is exactly
  // what the three closures did, with two fewer allocations per request.
  priv state : DispatchState
  priv step : () -> Unit
}

///|
pub fn Next::proceed(self : Next) -> Unit {
  (self.step)()
}

///|
pub fn Next::fail(self : Next, message : String) -> Unit {
  self.state.error = Some(message)
  (self.step)()
}

///|
/// Fails with an HTTP status, the equivalent of Express'
/// `next(createError(status, message))`.
pub fn Next::fail_status(self : Next, status : Int32, message : String) -> Unit {
  self.state.error = Some(message)
  self.state.error_status = Some(status)
  (self.step)()
}

///|
pub fn Next::resume_with(self : Next, error : String?) -> Unit {
  self.state.error = error
  (self.step)()
}

///|
fn Next::resume_with_status(
  self : Next,
  error : String?,
  status : Int32?,
) -> Unit {
  self.state.error = error
  self.state.error_status = status
  (self.step)()
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
  Mount(PathPattern, Router, String)
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
  priv engines : Map[String, ViewEngine]
  priv mut prepared : Bool
}

///|
/// A view engine: receives the resolved template path, the template source
/// and the locals, and returns the rendered string.
pub type ViewEngine = (String, String, Json) -> String

///|
/// A standalone router, like `express.Router()`. Mount it with
/// `app.use_router(path, router)`; `merge_params` controls whether the
/// parent router's params stay visible inside (Express' `mergeParams`).
pub struct Router {
  priv layers : Array[Layer]
  priv param_callbacks : Array[(String, (Req, Next) -> Unit)]
  priv merge_params : Bool
}

///|
/// Creates a new router, like `express.Router()`.
pub fn express_router() -> Router {
  Router::new()
}

///|
pub fn Router::new(merge_params? : Bool) -> Router {
  let merge_params = match merge_params {
    Some(value) => value
    None => false
  }
  { layers: [], param_callbacks: [], merge_params, }
}

///|
/// A route builder for chaining handlers on one path:
/// `app.route("/x").get(show).post(create)`.
pub struct RouteBuilder {
  priv path : String
  priv add : (String, String, Handler) -> Unit
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
    engines: Map([]),
    prepared: false,
  }
}

///|
/// Registers middleware for every request, `app.use(mw)` in Express.
///
/// `use` is a reserved word in MoonBit, so the function is declared as
/// `use_middleware` and exposed under the Express name with `#alias`.
#alias(use)
pub fn App::use_middleware(self : App, middleware : Middleware) -> Unit {
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
/// Registers a handler for one HTTP method (the low-level form of
/// `app.get/post/...`, which build routes on top of it).
pub fn App::add_route(
  self : App,
  http_method : String,
  path : String,
  handler : Handler,
) -> Unit {
  self.layers.push(Route(http_method.to_upper(), make_pattern(path), handler))
}

///|
/// Creates a route builder for chaining handlers on one path, like
/// `app.route("/x").get(show).post(create)`.
pub fn App::route(self : App, path : String) -> RouteBuilder {
  {
    path,
    add: fn(http_method, route_path, handler) {
      self.add_route(http_method, route_path, handler)
    },
  }
}

///|
/// Mounts a router under `path`, like `app.use("/api", router)`. Requests
/// see the mount prefix stripped in `req.url` and accumulated in
/// `req.base_url`.
pub fn App::use_router(self : App, path : String, router : Router) -> Unit {
  let prefix = normalize_mount(path)
  self.layers.push(Mount(make_pattern(path), router, prefix))
}

///|
pub fn App::get(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("GET", path, handler)
}

///|
pub fn App::post(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("POST", path, handler)
}

///|
pub fn App::put(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("PUT", path, handler)
}

///|
pub fn App::patch(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("PATCH", path, handler)
}

///|
pub fn App::delete(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("DELETE", path, handler)
}

///|
pub fn App::options(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("OPTIONS", path, handler)
}

///|
pub fn App::head(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("HEAD", path, handler)
}

///|
pub fn App::all(self : App, path : String, handler : Handler) -> Unit {
  self.add_route("ALL", path, handler)
}

///|
/// Registers a handler on a router for one HTTP method.
pub fn Router::add_route(
  self : Router,
  http_method : String,
  path : String,
  handler : Handler,
) -> Unit {
  self.layers.push(Route(http_method.to_upper(), make_pattern(path), handler))
}

///|
/// Creates a route builder on a router, like `router.route("/x")`.
pub fn Router::route(self : Router, path : String) -> RouteBuilder {
  {
    path,
    add: fn(http_method, route_path, handler) {
      self.add_route(http_method, route_path, handler)
    },
  }
}

///|
pub fn Router::get(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("GET", path, handler)
}

///|
pub fn Router::post(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("POST", path, handler)
}

///|
pub fn Router::put(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("PUT", path, handler)
}

///|
pub fn Router::patch(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("PATCH", path, handler)
}

///|
pub fn Router::delete(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("DELETE", path, handler)
}

///|
pub fn Router::options(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("OPTIONS", path, handler)
}

///|
pub fn Router::head(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("HEAD", path, handler)
}

///|
pub fn Router::all(self : Router, path : String, handler : Handler) -> Unit {
  self.add_route("ALL", path, handler)
}

///|
/// Registers middleware on a router for every request, `router.use(mw)` in
/// Express. Declared as `use_middleware` and exposed as `use` with `#alias`
/// because `use` is reserved in MoonBit.
#alias(use)
pub fn Router::use_middleware(self : Router, middleware : Middleware) -> Unit {
  self.layers.push(Mw(make_pattern("/"), middleware))
}

///|
/// Registers middleware on a router for paths starting with `path`.
pub fn Router::use_at(
  self : Router,
  path : String,
  middleware : Middleware,
) -> Unit {
  self.layers.push(Mw(make_pattern(path), middleware))
}

///|
pub fn Router::use_error(self : Router, middleware : ErrorMiddleware) -> Unit {
  self.layers.push(Err(make_pattern("/"), middleware))
}

///|
pub fn Router::use_error_at(
  self : Router,
  path : String,
  middleware : ErrorMiddleware,
) -> Unit {
  self.layers.push(Err(make_pattern(path), middleware))
}

///|
/// Adds a param callback to a router, like `router.param(name, fn)`.
pub fn Router::param(
  self : Router,
  name : String,
  callback : (Req, Next) -> Unit,
) -> Unit {
  self.param_callbacks.push((name, callback))
}

///|
/// Mounts a nested router, like `router.use("/sub", subRouter)`.
pub fn Router::use_router(
  self : Router,
  path : String,
  router : Router,
) -> Unit {
  let prefix = normalize_mount(path)
  self.layers.push(Mount(make_pattern(path), router, prefix))
}

///|
pub fn RouteBuilder::get(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("GET", self.path, handler)
  self
}

///|
pub fn RouteBuilder::post(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("POST", self.path, handler)
  self
}

///|
pub fn RouteBuilder::put(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("PUT", self.path, handler)
  self
}

///|
pub fn RouteBuilder::patch(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("PATCH", self.path, handler)
  self
}

///|
pub fn RouteBuilder::delete(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("DELETE", self.path, handler)
  self
}

///|
pub fn RouteBuilder::options(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("OPTIONS", self.path, handler)
  self
}

///|
pub fn RouteBuilder::head(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("HEAD", self.path, handler)
  self
}

///|
pub fn RouteBuilder::all(
  self : RouteBuilder,
  handler : Handler,
) -> RouteBuilder {
  (self.add)("ALL", self.path, handler)
  self
}

///|
/// Normalizes a mount path: `/api/` becomes `/api`, and `/` becomes `""`.
fn normalize_mount(path : String) -> String {
  let mut value = path
  while value.length() > 1 && value.has_suffix("/") {
    value = value[:value.length() - 1].to_owned()
  }
  if value == "/" {
    ""
  } else {
    value
  }
}

///|
/// Strips a mount prefix from a request path, keeping the leading slash.
fn mount_relative(prefix : String, path : String) -> String {
  if prefix == "" {
    return path
  }
  if path.length() <= prefix.length() {
    return "/"
  }
  let rest = path[prefix.length():].to_owned()
  if rest.has_prefix("/") {
    rest
  } else {
    "/" + rest
  }
}

///|
pub fn App::set(self : App, key : String, value : String) -> Unit {
  self.settings.set(key, value)
}

///|
/// Returns a setting, `""` when unset.
pub fn App::get_setting(self : App, key : String) -> String {
  match self.settings.get(key) {
    Some(value) => value
    None => ""
  }
}

///|
/// Turns a boolean setting on, like `app.enable(name)`.
pub fn App::enable(self : App, key : String) -> Unit {
  self.set(key, "true")
}

///|
/// Turns a boolean setting off, like `app.disable(name)`.
pub fn App::disable(self : App, key : String) -> Unit {
  self.set(key, "false")
}

///|
/// Whether a boolean setting is enabled, like `app.enabled(name)`.
pub fn App::enabled(self : App, key : String) -> Bool {
  self.get_setting(key) == "true"
}

///|
/// Whether a boolean setting is disabled, like `app.disabled(name)`.
pub fn App::disabled(self : App, key : String) -> Bool {
  self.get_setting(key) == "false"
}

///|
/// Registers a view engine for an extension, like `app.engine("html", fn)`.
pub fn App::engine(self : App, extension : String, render : ViewEngine) -> Unit {
  self.engines.set(normalize_extension(extension), render)
}

///|
/// Renders a view through the registered engine, resolving it below the
/// `views` setting (default `./views`). Uses the `view engine` setting when
/// the view has no engine extension.
pub fn App::render(self : App, view : String, locals? : Json) -> String raise {
  let views = match self.get_setting("views") {
    "" => "./views"
    value => value
  }
  let mut file = view
  let mut extension = extension_of(view)
  if extension == "" || !self.engines.contains(extension) {
    let default_extension = normalize_extension(self.get_setting("view engine"))
    if default_extension != "" {
      file = view + "." + default_extension
      extension = default_extension
    }
  }
  let engine = match self.engines.get(extension) {
    Some(engine) => engine
    None =>
      raise Failure(
        "no view engine registered for \"" +
        extension +
        "\" (use app.engine or set \"view engine\")",
      )
  }
  let path = if file.has_prefix("/") { file } else { join_path(views, file) }
  if fs_kind(path) != 1 {
    raise Failure("view not found: " + path)
  }
  let source = utf8_string(fs_read_file(path))
  let options = match locals {
    Some(value) => value
    None => Json::null()
  }
  engine(path, source, options)
}

///|
/// The extension of a path without the dot, lower-cased.
fn extension_of(path : String) -> String {
  match path.rev_split_once(".") {
    Some((_, ext)) => ext.to_owned().to_lower()
    None => ""
  }
}

///|
fn normalize_extension(value : String) -> String {
  let value = value.to_lower()
  if value.has_prefix(".") {
    value[1:].to_owned()
  } else {
    value
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
  mut error_status : Int32?
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
/// Dispatches request body data to the pending request. The raw bytes stay on
/// the `Req` so that binary-safe parsers can use them.
pub fn dispatch_body(
  request_id : UInt64,
  body : Bytes,
  _len : Int32,
  status : Int32,
) -> Unit {
  match request_slot_get(request_id) {
    Some(state) => {
      if status == 0 {
        state.req.set_body_bytes(body)
      }
      match state.body_reader {
        Some(reader) => {
          state.body_reader = None
          reader(utf8_string(body), status == 0)
        }
        None => ()
      }
    }
    None => ()
  }
}

///|
/// Dispatches an abort notification to the pending request.
pub fn dispatch_abort(request_id : UInt64) -> Unit {
  match request_slot_get(request_id) {
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
/// One array shared by every request that starts with no router params. It is
/// only ever read (`set_params` copies out of it), so sharing is safe and saves
/// an allocation per request.
let g_no_params : Array[(String, String)] = []

///|
/// Shared zero-length body for requests that never carry one. `body_bytes` is
/// only ever replaced, never written through, so one instance is enough.
let g_empty_bytes : Bytes = Bytes::make(0, b'\x00')

///|
/// Encoded status lines, keyed by status code. Building `"200 OK"` with
/// `to_string`, string concatenation and `utf8_bytes` allocated three times per
/// response to produce the same dozen bytes every time; a handful of codes
/// covers real traffic, and the table is capped so an exotic code cannot grow
/// it without bound.
let g_status_line_memo : Array[(Int32, Bytes)] = []

///|
/// The `"<code> <text>"` status line as UTF-8 bytes, cached per status code.
fn status_line_bytes(code : Int32) -> Bytes {
  let mut index = 0
  while index < g_status_line_memo.length() {
    let entry = g_status_line_memo[index]
    if entry.0 == code {
      return entry.1
    }
    index = index + 1
  }
  let line = code.to_string() + " " + status_text(code)
  let bytes = utf8_bytes(line)
  if g_status_line_memo.length() < 32 {
    g_status_line_memo.push((code, bytes))
  }
  bytes
}

///|
/// Whether every character is an ASCII uppercase letter, without allocating.
fn is_upper_ascii(text : String) -> Bool {
  let len = text.length()
  let mut index = 0
  while index < len {
    let code = text.unsafe_get(index).to_int()
    if code < 65 || code > 90 {
      return false
    }
    index = index + 1
  }
  true
}

///|
fn start_request(app : App, uws_res : UwsRes) -> Unit {
  let request_id = request_slot_reserve()
  // Methods arrive uppercase already; `to_upper` would copy the `String` again
  // for no change. A non-uppercase method is rare (and outside the HTTP spec),
  // so it is the only case that pays, and it is detected without allocating.
  let raw_method = utf8_string(uwb_req_method())
  let http_method = if is_upper_ascii(raw_method) {
    raw_method
  } else {
    raw_method.to_upper()
  }
  let url_path = utf8_string(uwb_req_url())
  // `utf8_string` allocates even for the empty query string, which is the
  // common case; only decode when there is something to decode.
  let query_blob = uwb_req_query()
  let query_raw = if query_blob.length() == 0 {
    ""
  } else {
    utf8_string(query_blob)
  }
  // One FFI call and one allocation for all headers, instead of two of each
  // per header. Values are decoded only if a handler actually reads one.
  let headers_raw = uwb_req_headers_blob()
  let ssl_flag : Int32 = if app.is_ssl { 1 } else { 0 }
  let original_url = if query_raw == "" {
    url_path
  } else {
    url_path + "?" + query_raw
  }
  let req = Req::{
    uws_res,
    request_id,
    app_ref: app,
    settings: app.settings,
    headers_raw,
    http_method,
    url_path,
    base_url: "",
    original_url,
    params: None,
    base_params: g_no_params,
    route_info: None,
    next: None,
    query_params: None,
    query_raw,
    body_text: "",
    body_bytes: g_empty_bytes,
    body_json: None,
    body_form: None,
    body_form_json: None,
    cookies: None,
    remote_ip_cache: None,
    path_segments_cache: None,
    aborted: false,
    locals: None,
    protocol: if app.is_ssl {
      "https"
    } else {
      "http"
    },
  }
  let res = Res::{
    uws_res,
    request_id,
    settings: app.settings,
    status_code: 200,
    headers: [],
    ended: false,
    aborted: false,
    headers_sent: false,
    locals: None,
    vary_headers: [],
    is_ssl: app.is_ssl,
  }
  let state : RequestState = { req, res, app, body_reader: None, chain: None, }
  request_slot_fill(request_id, state)
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
  match request_slot_get(res.request_id) {
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
  dispatch_layers(app.layers, app.param_callbacks, req, res, fn(state) {
    finalize(state, app, req, res)
  })
}

///|
/// Runs a layer list with Express' middleware semantics: layers run in order,
/// a layer that responds stops the chain, `next()` resumes it and errors skip
/// to the next error handler. `on_done` runs when the list is exhausted.
fn dispatch_layers(
  layers : Array[Layer],
  param_callbacks : Array[(String, (Req, Next) -> Unit)],
  req : Req,
  res : Res,
  on_done : (DispatchState) -> Unit,
) -> Unit {
  let state = DispatchState::{ idx: 0, error: None, error_status: None, }
  let steps : Array[Step] = [g_noop_step]
  match request_slot_get(req.request_id) {
    Some(state) => state.chain = Some(steps)
    None => ()
  }
  let step = fn() {
    let mut running = true
    while running && state.idx < layers.length() {
      let layer = layers[state.idx]
      state.idx = state.idx + 1
      match layer {
        Mw(pattern, middleware) =>
          if state.error is None {
            match req.match_pattern(pattern, true) {
              Some(params) => {
                req.set_params(params)
                running = false
                let next = make_next(state, steps[0])
                req.set_next(next)
                run_param_callbacks(param_callbacks, req, state, steps[0], fn() {
                  middleware(req, res, next)
                })
              }
              None => ()
            }
          }
        Mount(pattern, router, prefix) =>
          if state.error is None {
            match req.match_pattern(pattern, true) {
              Some(params) => {
                req.set_params(params)
                running = false
                let next = make_next(state, steps[0])
                req.set_next(next)
                run_param_callbacks(param_callbacks, req, state, steps[0], fn() {
                  mount_router(router, prefix, req, res, next)
                })
              }
              None => ()
            }
          }
        Err(pattern, middleware) =>
          match state.error {
            Some(message) =>
              match req.match_pattern(pattern, true) {
                Some(params) => {
                  req.set_params(params)
                  state.error = None
                  state.error_status = None
                  running = false
                  let next = make_next(state, steps[0])
                  req.set_next(next)
                  run_param_callbacks(param_callbacks, req, state, steps[0], fn() {
                    middleware(message, req, res, next)
                  })
                }
                None => ()
              }
            None => ()
          }
        Route(route_method, pattern, handler) =>
          if state.error is None &&
            method_matches(route_method, req.http_method()) {
            match req.match_pattern(pattern, false) {
              Some(params) => {
                req.set_params(params)
                req.set_route(
                  Some({ http_method: route_method, path: pattern.source(), }),
                )
                running = false
                let next = make_next(state, steps[0])
                req.set_next(next)
                run_param_callbacks(param_callbacks, req, state, steps[0], fn() {
                  handler(req, res, next)
                })
              }
              None => ()
            }
          }
      }
    }
    if running {
      on_done(state)
    }
  }
  steps[0] = step
  step()
}

///|
/// Runs a mounted router: `req.url` loses the mount prefix, `req.base_url`
/// accumulates it, and params captured by the mount stay visible when the
/// router asked for `mergeParams`. Finishing the router resumes the parent
/// chain; errors propagate to the parent's error middleware.
fn mount_router(
  router : Router,
  prefix : String,
  req : Req,
  res : Res,
  next : Next,
) -> Unit {
  let saved_path = req.url_path
  let saved_base = req.base_url
  let saved_params = req.params
  let saved_base_params = req.base_params
  let saved_route = req.route_info
  let saved_next = req.next
  req.path_segments_cache = None
  req.url_path = mount_relative(prefix, req.path())
  req.base_url = req.base_url + prefix
  req.base_params = if router.merge_params {
    match saved_params {
      Some(map) => map.to_array()
      None => []
    }
  } else {
    g_no_params
  }
  dispatch_layers(router.layers, router.param_callbacks, req, res, fn(state) {
    req.url_path = saved_path
    req.path_segments_cache = None
    req.base_url = saved_base
    req.params = saved_params
    req.base_params = saved_base_params
    req.route_info = saved_route
    req.next = saved_next
    next.resume_with_status(state.error, state.error_status)
  })
}

///|
fn make_next(state : DispatchState, step : () -> Unit) -> Next {
  { state, step, }
}

///|
/// Runs the `param` callbacks that apply to the params captured by the layer
/// currently being dispatched, in registration order, then invokes `then_fn`
/// (normally the layer handler). Each callback receives a `Next`: calling
/// `proceed()` moves on to the remaining callbacks and finally `then_fn`;
/// calling `fail(message)` hands control to the error middleware.
fn run_param_callbacks(
  param_callbacks : Array[(String, (Req, Next) -> Unit)],
  req : Req,
  state : DispatchState,
  dispatch_step : () -> Unit,
  then_fn : () -> Unit,
) -> Unit {
  // Fast path: no `param` callbacks are registered, so nothing can run before
  // the handler. Skipping the cursor/steps/Next scaffolding below avoids two
  // array allocations and a closure per request on the common route.
  if param_callbacks.length() == 0 {
    then_fn()
    return
  }
  let cursor : Array[Int32] = [0]
  let steps : Array[() -> Unit] = [fn() { () }]
  let step_params = fn() {
    let mut i = cursor[0]
    while i < param_callbacks.length() {
      let (name, callback) = param_callbacks[i]
      cursor[0] = i + 1
      if req.has_param(name) {
        let next : Next = { state, step: dispatch_step, }
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
fn finalize(state : DispatchState, app : App, req : Req, res : Res) -> Unit {
  if res.is_ended() || res.is_aborted() {
    return
  }
  match state.error {
    Some(message) => {
      let status = match state.error_status {
        Some(status) => status
        None => 500
      }
      println("express: unhandled error: " + message)
      if res.headers_sent() {
        res.end_stream()
        return
      }
      if status >= 500 {
        res.status(status).send(status_text(status))
      } else {
        res.status(status).send(message)
      }
    }
    None =>
      if req.http_method() == "OPTIONS" {
        let methods = collect_options_methods(app.layers, req.path())
        if methods.length() > 0 {
          let allow = methods.join(", ")
          res
          .status(200)
          .set("Allow", allow)
          .set("Content-Type", "text/plain")
          .set("X-Content-Type-Options", "nosniff")
          .send(allow)
        } else {
          res.status(404).send("Cannot " + req.http_method() + " " + req.path())
        }
      } else {
        res.status(404).send("Cannot " + req.http_method() + " " + req.path())
      }
  }
}

///|
/// The methods Express would advertise for an OPTIONS request: the methods of
/// every route matching the path, plus `HEAD` for a `GET`, sorted and
/// deduplicated. Mounted routers contribute their own routes.
fn collect_options_methods(
  layers : Array[Layer],
  path : String,
) -> Array[String] {
  let found : Array[String] = []
  for layer in layers {
    match layer {
      Route(route_method, pattern, _) =>
        if route_method != "OPTIONS" &&
          route_method != "ALL" &&
          pattern.match_path(path, false) is Some(_) &&
          !found.contains(route_method) {
          found.push(route_method)
        }
      Mount(pattern, router, prefix) =>
        if pattern.match_path(path, true) is Some(_) {
          for
            verb in collect_options_methods(
              router.layers,
              mount_relative(prefix, path),
            ) {
            if !found.contains(verb) {
              found.push(verb)
            }
          }
        }
      _ => ()
    }
  }
  if found.contains("GET") && !found.contains("HEAD") {
    found.push("HEAD")
  }
  found.sort()
  found
}
