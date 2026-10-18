///|
/// Websocket support on top of the native µWebSockets binding.

///|
/// A message delivered on a websocket.
pub enum WsMessage {
  Text(String)
  Binary(Bytes)
}

///|
/// One open websocket connection.
pub struct WsConn {
  priv id : UInt64
  priv socket : UwsSocket
  priv is_ssl : Bool
}

///|
/// Connection id, unique for the lifetime of the process.
pub fn WsConn::id(self : WsConn) -> UInt64 {
  self.id
}

///|
/// Sends a text frame.
pub fn WsConn::send(self : WsConn, text : String) -> Unit {
  let bytes = utf8_bytes(text)
  if self.is_ssl {
    uwb_ws_send_ssl(self.socket, bytes, bytes.length(), TEXT_OPCODE, 0)
  } else {
    uwb_ws_send(self.socket, bytes, bytes.length(), TEXT_OPCODE, 0)
  }
}

///|
/// Sends a binary frame.
pub fn WsConn::send_bytes(self : WsConn, data : Bytes) -> Unit {
  if self.is_ssl {
    uwb_ws_send_ssl(self.socket, data, data.length(), BINARY_OPCODE, 0)
  } else {
    uwb_ws_send(self.socket, data, data.length(), BINARY_OPCODE, 0)
  }
}

///|
/// Sends an arbitrary frame, e.g. a ping, optionally compressed.
pub fn WsConn::send_frame(
  self : WsConn,
  data : Bytes,
  opcode : Int32,
  compress : Bool,
) -> Unit {
  let compress = if compress { 1 } else { 0 }
  if self.is_ssl {
    uwb_ws_send_ssl(self.socket, data, data.length(), opcode, compress)
  } else {
    uwb_ws_send(self.socket, data, data.length(), opcode, compress)
  }
}

///|
/// Closes the connection. Defaults to a normal closure (`1000`).
pub fn WsConn::close(self : WsConn, code? : Int32, reason? : String) -> Unit {
  let code = match code {
    Some(value) => value
    None => 1000
  }
  let reason = match reason {
    Some(value) => value
    None => ""
  }
  let bytes = utf8_bytes(reason)
  if self.is_ssl {
    uwb_ws_close_ssl(self.socket, code, bytes, bytes.length())
  } else {
    uwb_ws_close(self.socket, code, bytes, bytes.length())
  }
}

///|
const TEXT_OPCODE : Int32 = 1

///|
const BINARY_OPCODE : Int32 = 2

///|
/// Callbacks for one websocket route. All of them are optional.
pub struct WsBehavior {
  open : ((WsConn) -> Unit)?
  message : ((WsConn, WsMessage) -> Unit)?
  close : ((WsConn, Int32, String) -> Unit)?
}

///|
/// Builds a websocket behavior, mirroring `app.ws("/path", { open, message, close })`.
pub fn ws_behavior(
  open? : (WsConn) -> Unit,
  message? : (WsConn, WsMessage) -> Unit,
  close? : (WsConn, Int32, String) -> Unit,
) -> WsBehavior {
  { open, message, close, }
}

///|
/// Registers a websocket route. Must be called before the app listens.
pub fn App::ws(self : App, path : String, behavior : WsBehavior) -> Unit {
  let route_id = g_next_ws_route[0]
  g_next_ws_route[0] = route_id + 1
  g_ws_behaviors.set(route_id, behavior)
  self.ws_routes.push((route_id, path))
  g_ws_route_is_ssl.set(route_id, self.is_ssl)
}

// ---------- registry ----------

///|
priv struct WsConnState {
  route_id : Int32
  conn : WsConn
}

///|
let g_ws_behaviors : Map[Int32, WsBehavior] = Map([])

///|
let g_ws_conns : Map[UInt64, WsConnState] = Map([])

///|
let g_next_ws_route : Array[Int32] = [1]

///|
/// Maps route_id to whether the app is SSL
let g_ws_route_is_ssl : Map[Int32, Bool] = Map([])

///|
fn init_websockets() -> Unit {
  let on_open : FuncRef[(UInt64, Int32, UwsSocket) -> Unit] = (
    conn_id,
    route_id,
    ws,
  ) => ws_dispatch_open(conn_id, route_id, ws)
  let on_message : FuncRef[(UInt64, Bytes, Int32, Int32) -> Unit] = (
    conn_id,
    data,
    len,
    opcode,
  ) => ws_dispatch_message(conn_id, data, len, opcode)
  let on_close : FuncRef[(UInt64, Int32, Bytes, Int32) -> Unit] = (
    conn_id,
    code,
    message,
    len,
  ) => ws_dispatch_close(conn_id, code, message, len)
  uwb_set_ws_callbacks(on_open, on_message, on_close)
}

///|
fn ws_dispatch_open(conn_id : UInt64, route_id : Int32, ws : UwsSocket) -> Unit {
  let is_ssl = match g_ws_route_is_ssl.get(route_id) {
    Some(v) => v
    None => false
  }
  let conn = WsConn::{ id: conn_id, socket: ws, is_ssl: is_ssl }
  g_ws_conns.set(conn_id, { route_id, conn, })
  match g_ws_behaviors.get(route_id) {
    Some(behavior) =>
      match behavior.open {
        Some(handler) => handler(conn)
        None => ()
      }
    None => ()
  }
}

///|
fn ws_dispatch_message(
  conn_id : UInt64,
  data : Bytes,
  _len : Int32,
  opcode : Int32,
) -> Unit {
  match g_ws_conns.get(conn_id) {
    Some(state) =>
      match g_ws_behaviors.get(state.route_id) {
        Some(behavior) =>
          match behavior.message {
            Some(handler) => {
              let payload = if opcode == TEXT_OPCODE {
                WsMessage::Text(utf8_string(data))
              } else {
                WsMessage::Binary(data)
              }
              handler(state.conn, payload)
            }
            None => ()
          }
        None => ()
      }
    None => ()
  }
}

///|
fn ws_dispatch_close(
  conn_id : UInt64,
  code : Int32,
  message : Bytes,
  _len : Int32,
) -> Unit {
  match g_ws_conns.get(conn_id) {
    Some(state) => {
      g_ws_conns.remove(conn_id)
      match g_ws_behaviors.get(state.route_id) {
        Some(behavior) =>
          match behavior.close {
            Some(handler) => handler(state.conn, code, utf8_string(message))
            None => ()
          }
        None => ()
      }
    }
    None => ()
  }
}
