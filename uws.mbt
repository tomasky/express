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
extern "C" fn uwb_set_callbacks(
  on_request : FuncRef[(UInt64, UwsRes, UwsReq) -> Unit],
  on_body : FuncRef[(UInt64, Bytes, Int32, Int32) -> Unit],
  on_abort : FuncRef[(UInt64) -> Unit],
) -> Unit = "uwb_set_callbacks"

// ---------- application ----------

///|
extern "C" fn uwb_app_new() -> UwsApp = "uwb_app_new"

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
  status : Bytes,
  len : Int32,
) -> Unit = "uwb_res_write_status"

///|
#borrow(name, value)
extern "C" fn uwb_res_write_header(
  res : UwsRes,
  name : Bytes,
  name_len : Int32,
  value : Bytes,
  value_len : Int32,
) -> Unit = "uwb_res_write_header"

///|
#borrow(body)
extern "C" fn uwb_res_end(res : UwsRes, body : Bytes, len : Int32) -> Unit = "uwb_res_end"

///|
extern "C" fn uwb_res_end_empty(res : UwsRes) -> Unit = "uwb_res_end_empty"

///|
extern "C" fn uwb_res_on_aborted(res : UwsRes, request_id : UInt64) -> Unit = "uwb_res_on_aborted"

///|
extern "C" fn uwb_res_on_data(
  res : UwsRes,
  request_id : UInt64,
  limit : Int32,
) -> Unit = "uwb_res_on_data"

///|
extern "C" fn uwb_res_remote_address(res : UwsRes) -> Bytes = "uwb_res_remote_address"

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
