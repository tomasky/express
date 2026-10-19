///|
/// Raw native binding to the C ABI exposed by `src/uws_shim.cpp`.
///
/// µWebSockets is driven from C++ (`third_party/uwebsockets`), so MoonBit only
/// ever holds opaque pointers plus UTF-8 `Bytes` copies. Nothing in this file
/// should be used directly by applications; `express.mbt` wraps it.

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
#external
pub type UwsSocket

///|
/// TLS options for creating an SSL-enabled app.
pub struct UwsSslOptions {
  cert_file : String
  key_file : String
  passphrase : String?
  dh_params_file : String?
  ca_file : String?
  ssl_ciphers : String?
}

///|
/// Converts a MoonBit string to the UTF-8 bytes used across the FFI.
fn utf8_bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// Converts UTF-8 bytes coming from C back into a MoonBit string.
fn utf8_string(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes)
}

// ---------- callbacks into MoonBit ----------

///|
/// Registers the three C callbacks. Runs once at startup.
/// Uses FuncRef so MoonBit passes fat pointers {env, fn}.
extern "C" fn uwb_set_callbacks(
  on_request : FuncRef[(UInt64, UwsRes, UwsReq) -> Unit],
  on_body : FuncRef[(UInt64, Bytes, Int32, Int32) -> Unit],
  on_abort : FuncRef[(UInt64) -> Unit],
) -> Unit = "uwb_set_callbacks"

// ---------- application ----------

///|
extern "C" fn uwb_app_new() -> UwsApp = "uwb_app_new"

///|
/// Upgrades the app to TLS with the given PEM options. Empty option strings
/// mean "not set", except `cert_file`/`key_file` which are required.
/// `options` fields are extracted here so the C ABI only ever sees byte slices.
#borrow(cert_file, key_file, passphrase, dh_params_file, ca_file, ssl_ciphers)
extern "C" fn uwb_app_enable_ssl(
  app : UwsApp,
  cert_file : Bytes,
  cert_len : Int32,
  key_file : Bytes,
  key_len : Int32,
  passphrase : Bytes,
  passphrase_len : Int32,
  dh_params_file : Bytes,
  dh_params_len : Int32,
  ca_file : Bytes,
  ca_len : Int32,
  ssl_ciphers : Bytes,
  ciphers_len : Int32,
) -> Unit = "uwb_app_enable_ssl"

///|
/// FFI helper: enables TLS from `UwsSslOptions`, flattening optional strings.
fn enable_ssl(app : UwsApp, options : UwsSslOptions) -> Unit {
  let cert = utf8_bytes(options.cert_file)
  let key = utf8_bytes(options.key_file)
  let passphrase = match options.passphrase {
    Some(value) => utf8_bytes(value)
    None => utf8_bytes("")
  }
  let dh_params = match options.dh_params_file {
    Some(value) => utf8_bytes(value)
    None => utf8_bytes("")
  }
  let ca = match options.ca_file {
    Some(value) => utf8_bytes(value)
    None => utf8_bytes("")
  }
  let ciphers = match options.ssl_ciphers {
    Some(value) => utf8_bytes(value)
    None => utf8_bytes("")
  }
  uwb_app_enable_ssl(
    app,
    cert,
    cert.length(),
    key,
    key.length(),
    passphrase,
    passphrase.length(),
    dh_params,
    dh_params.length(),
    ca,
    ca.length(),
    ciphers,
    ciphers.length(),
  )
}

///|
#borrow(path)
extern "C" fn uwb_app_any(
  app : UwsApp,
  app_id : UInt64,
  path : Bytes,
  path_len : Int32,
) -> Unit = "uwb_app_any"

///|
#borrow(host)
extern "C" fn uwb_app_listen(
  app : UwsApp,
  app_id : UInt64,
  host : Bytes,
  host_len : Int32,
  port : Int32,
) -> Int32 = "uwb_app_listen"

///|
extern "C" fn uwb_app_run(app : UwsApp) -> Unit = "uwb_app_run"

///|
extern "C" fn uwb_app_close(app : UwsApp) -> Unit = "uwb_app_close"

// ---------- request snapshot ----------

///|
extern "C" fn uwb_req_method() -> Bytes = "uwb_req_method"

///|
extern "C" fn uwb_req_url() -> Bytes = "uwb_req_url"

///|
extern "C" fn uwb_req_query() -> Bytes = "uwb_req_query"

///|
extern "C" fn uwb_req_header_count() -> Int32 = "uwb_req_header_count"

///|
extern "C" fn uwb_req_header_name(index : Int32) -> Bytes = "uwb_req_header_name"

///|
extern "C" fn uwb_req_header_value(index : Int32) -> Bytes = "uwb_req_header_value"

// ---------- response ----------

///|
#borrow(status)
extern "C" fn uwb_res_write_status(
  res : UwsRes,
  ssl : Int32,
  status : Bytes,
  len : Int32,
) -> Unit = "uwb_res_write_status"

///|
#borrow(name, value)
extern "C" fn uwb_res_write_header(
  res : UwsRes,
  ssl : Int32,
  name : Bytes,
  name_len : Int32,
  value : Bytes,
  value_len : Int32,
) -> Unit = "uwb_res_write_header"

///|
#borrow(body)
extern "C" fn uwb_res_end(
  res : UwsRes,
  ssl : Int32,
  body : Bytes,
  len : Int32,
) -> Unit = "uwb_res_end"

///|
extern "C" fn uwb_res_end_empty(res : UwsRes, ssl : Int32) -> Unit = "uwb_res_end_empty"

///|
extern "C" fn uwb_res_on_aborted(
  res : UwsRes,
  ssl : Int32,
  request_id : UInt64,
) -> Unit = "uwb_res_on_aborted"

///|
extern "C" fn uwb_res_on_data(
  res : UwsRes,
  ssl : Int32,
  request_id : UInt64,
  limit : Int32,
) -> Unit = "uwb_res_on_data"

///|
extern "C" fn uwb_res_remote_address(res : UwsRes, ssl : Int32) -> Bytes = "uwb_res_remote_address"

// ---------- websockets ----------

///|
extern "C" fn uwb_set_ws_callbacks(
  on_open : FuncRef[(UInt64, Int32, UwsSocket) -> Unit],
  on_message : FuncRef[(UInt64, Bytes, Int32, Int32) -> Unit],
  on_close : FuncRef[(UInt64, Int32, Bytes, Int32) -> Unit],
) -> Unit = "uwb_set_ws_callbacks"

///|
#borrow(path)
extern "C" fn uwb_app_ws(
  app : UwsApp,
  route_id : Int32,
  path : Bytes,
  path_len : Int32,
) -> Unit = "uwb_app_ws"

///|
#borrow(data)
extern "C" fn uwb_ws_send(
  ws : UwsSocket,
  data : Bytes,
  len : Int32,
  opcode : Int32,
  compress : Int32,
) -> Unit = "uwb_ws_send"

///|
#borrow(message)
extern "C" fn uwb_ws_close(
  ws : UwsSocket,
  code : Int32,
  message : Bytes,
  msg_len : Int32,
) -> Unit = "uwb_ws_close"

///|
#borrow(data)
extern "C" fn uwb_ws_send_ssl(
  ws : UwsSocket,
  data : Bytes,
  len : Int32,
  opcode : Int32,
  compress : Int32,
) -> Unit = "uwb_ws_send_ssl"

///|
#borrow(message)
extern "C" fn uwb_ws_close_ssl(
  ws : UwsSocket,
  code : Int32,
  message : Bytes,
  msg_len : Int32,
) -> Unit = "uwb_ws_close_ssl"

// ---------- filesystem helpers ----------

///|
#borrow(path)
extern "C" fn uwb_fs_kind(path : Bytes, path_len : Int32) -> Int32 = "uwb_fs_kind"

///|
#borrow(path)
extern "C" fn uwb_fs_read_file(path : Bytes, path_len : Int32) -> Bytes = "uwb_fs_read_file"

///|
/// `0` missing, `1` regular file, `2` directory.
fn fs_kind(path : String) -> Int32 {
  let bytes = utf8_bytes(path)
  uwb_fs_kind(bytes, bytes.length())
}

///|
fn fs_read_file(path : String) -> Bytes {
  let bytes = utf8_bytes(path)
  uwb_fs_read_file(bytes, bytes.length())
}

///|
/// Joins a directory and a URL path, collapsing the boundary slashes.
fn join_path(base : String, rel : String) -> String {
  let mut left = base
  while left.has_suffix("/") {
    left = left[:left.length() - 1].to_owned()
  }
  let mut right = rel
  if !right.has_prefix("/") {
    right = "/" + right
  }
  left + right
}
