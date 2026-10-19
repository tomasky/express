/*
 * uWebSockets native shim.
 *
 * µWebSockets is a C++ header-only library, so this file is the C++/C
 * boundary: it exposes a flat C ABI (`src/uws_shim.h`) that the MoonBit
 * binding calls with `extern "C"`.
 *
 * Two cross-language details matter:
 *   - The µWebSockets request object dies when the route handler returns, so
 *     the shim snapshots method/url/query/headers before calling MoonBit.
 *   - MoonBit strings are UTF-16; every string crossing the boundary is
 *     carried as a MoonBit `Bytes` holding UTF-8, so no conversion happens
 *     in C++.
 */
#include "../third_party/uwebsockets/src/App.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <string_view>
#include <utility>
#include <vector>

#include "uws_shim.h"

namespace {

/* Per-connection user data µWebSockets hands back on every websocket call. */
struct WsUserData {
  uint64_t conn_id;
};

using WebSocketPlain = uWS::WebSocket<false, true, WsUserData>;
using WebSocketSSL = uWS::WebSocket<true, true, WsUserData>;

struct ShimApp {
  uWS::App *plain = nullptr;
  uWS::SSLApp *ssl = nullptr;
};

uwb_req_cb g_req_cb = nullptr;
uwb_body_cb g_body_cb = nullptr;
uwb_abort_cb g_abort_cb = nullptr;
uwb_ws_open_cb g_ws_open_cb = nullptr;
uwb_ws_message_cb g_ws_message_cb = nullptr;
uwb_ws_close_cb g_ws_close_cb = nullptr;
uint64_t g_next_conn_id = 1;

/* Snapshot of the request currently being dispatched. µWebSockets runs one
 * handler at a time, so a single staging area is enough. */
std::string g_method;
std::string g_url;
std::string g_query;
std::vector<std::pair<std::string, std::string>> g_headers;

moonbit_bytes_t make_bytes(const char *data, size_t len) {
  auto *out = moonbit_make_bytes_raw(static_cast<int32_t>(len));
  if (len > 0) {
    std::memcpy(out, data, len);
  }
  return out;
}

moonbit_bytes_t make_bytes(std::string_view view) {
  return make_bytes(view.data(), view.size());
}

std::string_view view_of(moonbit_bytes_t bytes, int32_t len) {
  return std::string_view(reinterpret_cast<const char *>(bytes),
                          static_cast<size_t>(len < 0 ? 0 : len));
}

/* Handlers for plain (non-SSL) app */
void handle_request_plain(uWS::HttpResponse<false> *res, uWS::HttpRequest *req, uint64_t app_id) {
  g_method.assign(req->getMethod());
  g_url.assign(req->getUrl());
  g_query.assign(req->getQuery());
  g_headers.clear();
  for (auto [key, value] : *req) {
    g_headers.emplace_back(std::string(key), std::string(value));
  }
  if (g_req_cb != nullptr) {
    g_req_cb(app_id, res, req);
  }
}

void handle_ws_open_plain(WebSocketPlain *ws, int32_t route_id) {
  uint64_t conn_id = g_next_conn_id++;
  ws->getUserData()->conn_id = conn_id;
  if (g_ws_open_cb != nullptr) {
    g_ws_open_cb(conn_id, route_id, ws);
  }
}

void handle_ws_message_plain(WebSocketPlain *ws, std::string_view message, uWS::OpCode opCode) {
  if (g_ws_message_cb != nullptr) {
    g_ws_message_cb(ws->getUserData()->conn_id, make_bytes(message),
                    static_cast<int32_t>(message.size()),
                    static_cast<int32_t>(opCode));
  }
}

void handle_ws_close_plain(WebSocketPlain *ws, int code, std::string_view message) {
  if (g_ws_close_cb != nullptr) {
    g_ws_close_cb(ws->getUserData()->conn_id, static_cast<int32_t>(code),
                  make_bytes(message), static_cast<int32_t>(message.size()));
  }
}

/* Handlers for SSL app */
void handle_request_ssl(uWS::HttpResponse<true> *res, uWS::HttpRequest *req, uint64_t app_id) {
  g_method.assign(req->getMethod());
  g_url.assign(req->getUrl());
  g_query.assign(req->getQuery());
  g_headers.clear();
  for (auto [key, value] : *req) {
    g_headers.emplace_back(std::string(key), std::string(value));
  }
  if (g_req_cb != nullptr) {
    g_req_cb(app_id, res, req);
  }
}

void handle_ws_open_ssl(WebSocketSSL *ws, int32_t route_id) {
  uint64_t conn_id = g_next_conn_id++;
  ws->getUserData()->conn_id = conn_id;
  if (g_ws_open_cb != nullptr) {
    g_ws_open_cb(conn_id, route_id, ws);
  }
}

void handle_ws_message_ssl(WebSocketSSL *ws, std::string_view message, uWS::OpCode opCode) {
  if (g_ws_message_cb != nullptr) {
    g_ws_message_cb(ws->getUserData()->conn_id, make_bytes(message),
                    static_cast<int32_t>(message.size()),
                    static_cast<int32_t>(opCode));
  }
}

void handle_ws_close_ssl(WebSocketSSL *ws, int code, std::string_view message) {
  if (g_ws_close_cb != nullptr) {
    g_ws_close_cb(ws->getUserData()->conn_id, static_cast<int32_t>(code),
                  make_bytes(message), static_cast<int32_t>(message.size()));
  }
}

} // namespace

extern "C" {

void uwb_set_callbacks(uwb_req_cb req_cb, uwb_body_cb body_cb,
                       uwb_abort_cb abort_cb) {
  g_req_cb = req_cb;
  g_body_cb = body_cb;
  g_abort_cb = abort_cb;
}

void *uwb_app_new(void) {
  auto *shim = new ShimApp();
  shim->plain = new uWS::App();
  return shim;
}

void uwb_app_enable_ssl(void *app,
                        moonbit_bytes_t cert_file, int32_t cert_len,
                        moonbit_bytes_t key_file, int32_t key_len,
                        moonbit_bytes_t passphrase, int32_t passphrase_len,
                        moonbit_bytes_t dh_params_file, int32_t dh_params_len,
                        moonbit_bytes_t ca_file, int32_t ca_len,
                        moonbit_bytes_t ssl_ciphers, int32_t ciphers_len) {
  auto *shim = static_cast<ShimApp *>(app);
  if (shim->ssl != nullptr) {
    return; /* already TLS */
  }
  /* Nothing has been registered on the plain app yet: routes go on in
   * uwb_app_any(), which runs after this call. */
  delete shim->plain;
  shim->plain = nullptr;
  /* µWebSockets copies these strings into the SSL context while it creates
   * it, so stack-local storage is fine. */
  std::string cert(view_of(cert_file, cert_len));
  std::string key(view_of(key_file, key_len));
  std::string pass(view_of(passphrase, passphrase_len));
  std::string dh(view_of(dh_params_file, dh_params_len));
  std::string ca(view_of(ca_file, ca_len));
  std::string ciphers(view_of(ssl_ciphers, ciphers_len));
  uWS::SocketContextOptions opts;
  if (!cert.empty()) opts.cert_file_name = cert.c_str();
  if (!key.empty()) opts.key_file_name = key.c_str();
  if (!pass.empty()) opts.passphrase = pass.c_str();
  if (!dh.empty()) opts.dh_params_file_name = dh.c_str();
  if (!ca.empty()) opts.ca_file_name = ca.c_str();
  if (!ciphers.empty()) opts.ssl_ciphers = ciphers.c_str();
  shim->ssl = new uWS::SSLApp(opts);
}

void uwb_app_any(void *app, uint64_t app_id, moonbit_bytes_t path,
                 int32_t path_len) {
  auto *shim = static_cast<ShimApp *>(app);
  std::string pattern(view_of(path, path_len));
  if (shim->plain) {
    shim->plain->any(pattern, [app_id](uWS::HttpResponse<false> *res, uWS::HttpRequest *req) {
      handle_request_plain(res, req, app_id);
    });
  } else if (shim->ssl) {
    shim->ssl->any(pattern, [app_id](uWS::HttpResponse<true> *res, uWS::HttpRequest *req) {
      handle_request_ssl(res, req, app_id);
    });
  }
}

int32_t uwb_app_listen(void *app, uint64_t app_id, moonbit_bytes_t host,
                       int32_t host_len, int32_t port) {
  auto *shim = static_cast<ShimApp *>(app);
  (void)app_id;
  std::string host_str(view_of(host, host_len));
  bool ok = false;
  auto handler = [&ok](us_listen_socket_t *token) { ok = token != nullptr; };
  if (shim->ssl) {
    shim->ssl->listen(host_str, port, std::move(handler));
  } else if (shim->plain) {
    shim->plain->listen(host_str, port, std::move(handler));
  }
  return ok ? 1 : 0;
}

void uwb_set_ws_callbacks(uwb_ws_open_cb open_cb, uwb_ws_message_cb message_cb,
                          uwb_ws_close_cb close_cb) {
  g_ws_open_cb = open_cb;
  g_ws_message_cb = message_cb;
  g_ws_close_cb = close_cb;
}

void uwb_app_ws(void *app, int32_t route_id, moonbit_bytes_t path,
                int32_t path_len) {
  auto *shim = static_cast<ShimApp *>(app);
  std::string pattern(view_of(path, path_len));
  if (shim->plain) {
    uWS::App::WebSocketBehavior<WsUserData> behavior;
    behavior.maxPayloadLength = 16 * 1024 * 1024;
    behavior.open = [route_id](WebSocketPlain *ws) { handle_ws_open_plain(ws, route_id); };
    behavior.message = [](WebSocketPlain *ws, std::string_view message, uWS::OpCode opCode) {
      handle_ws_message_plain(ws, message, opCode);
    };
    behavior.close = [](WebSocketPlain *ws, int code, std::string_view message) {
      handle_ws_close_plain(ws, code, message);
    };
    shim->plain->ws<WsUserData>(pattern, std::move(behavior));
  } else if (shim->ssl) {
    uWS::SSLApp::WebSocketBehavior<WsUserData> behavior;
    behavior.maxPayloadLength = 16 * 1024 * 1024;
    behavior.open = [route_id](WebSocketSSL *ws) { handle_ws_open_ssl(ws, route_id); };
    behavior.message = [](WebSocketSSL *ws, std::string_view message, uWS::OpCode opCode) {
      handle_ws_message_ssl(ws, message, opCode);
    };
    behavior.close = [](WebSocketSSL *ws, int code, std::string_view message) {
      handle_ws_close_ssl(ws, code, message);
    };
    shim->ssl->ws<WsUserData>(pattern, std::move(behavior));
  }
}

void uwb_ws_send(void *ws, moonbit_bytes_t data, int32_t len, int32_t opcode,
                 int32_t compress) {
  static_cast<WebSocketPlain *>(ws)->send(view_of(data, len),
                                          static_cast<uWS::OpCode>(opcode),
                                          compress != 0);
}

void uwb_ws_close(void *ws, int32_t code, moonbit_bytes_t message,
                  int32_t msg_len) {
  static_cast<WebSocketPlain *>(ws)->end(static_cast<int>(code),
                                         view_of(message, msg_len));
}

void uwb_ws_send_ssl(void *ws, moonbit_bytes_t data, int32_t len, int32_t opcode,
                     int32_t compress) {
  static_cast<WebSocketSSL *>(ws)->send(view_of(data, len),
                                        static_cast<uWS::OpCode>(opcode),
                                        compress != 0);
}

void uwb_ws_close_ssl(void *ws, int32_t code, moonbit_bytes_t message,
                      int32_t msg_len) {
  static_cast<WebSocketSSL *>(ws)->end(static_cast<int>(code),
                                       view_of(message, msg_len));
}

void uwb_app_run(void *app) {
  auto *shim = static_cast<ShimApp *>(app);
  if (shim->plain) {
    shim->plain->run();
  } else if (shim->ssl) {
    shim->ssl->run();
  }
}

void uwb_app_close(void *app) {
  auto *shim = static_cast<ShimApp *>(app);
  if (shim->plain) {
    shim->plain->close();
  } else if (shim->ssl) {
    shim->ssl->close();
  }
}

moonbit_bytes_t uwb_req_method(void) { return make_bytes(g_method); }

moonbit_bytes_t uwb_req_url(void) { return make_bytes(g_url); }

moonbit_bytes_t uwb_req_query(void) { return make_bytes(g_query); }

int32_t uwb_req_header_count(void) {
  return static_cast<int32_t>(g_headers.size());
}

moonbit_bytes_t uwb_req_header_name(int32_t index) {
  return make_bytes(g_headers[static_cast<size_t>(index)].first);
}

moonbit_bytes_t uwb_req_header_value(int32_t index) {
  return make_bytes(g_headers[static_cast<size_t>(index)].second);
}

/* Every response call must dispatch on the app's TLS mode: µWebSockets
 * compiles HttpResponse<true>/<false> separately and the socket write path
 * differs, so a plain cast to the wrong instantiation would bypass TLS. */
void uwb_res_write_status(void *res, int32_t ssl, moonbit_bytes_t status, int32_t len) {
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->writeStatus(view_of(status, len));
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->writeStatus(view_of(status, len));
  }
}

void uwb_res_write_header(void *res, int32_t ssl, moonbit_bytes_t name, int32_t name_len,
                          moonbit_bytes_t value, int32_t value_len) {
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->writeHeader(view_of(name, name_len),
                                                             view_of(value, value_len));
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->writeHeader(view_of(name, name_len),
                                                              view_of(value, value_len));
  }
}

void uwb_res_end(void *res, int32_t ssl, moonbit_bytes_t body, int32_t len) {
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->end(view_of(body, len));
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->end(view_of(body, len));
  }
}

void uwb_res_end_empty(void *res, int32_t ssl) {
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->end();
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->end();
  }
}

int32_t uwb_res_write(void *res, int32_t ssl, moonbit_bytes_t data, int32_t len) {
  bool ok;
  if (ssl != 0) {
    ok = static_cast<uWS::HttpResponse<true> *>(res)->write(view_of(data, len));
  } else {
    ok = static_cast<uWS::HttpResponse<false> *>(res)->write(view_of(data, len));
  }
  return ok ? 1 : 0;
}

void uwb_res_on_aborted(void *res, int32_t ssl, uint64_t request_id) {
  auto handler = [request_id]() {
    if (g_abort_cb != nullptr) {
      g_abort_cb(request_id);
    }
  };
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->onAborted(std::move(handler));
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->onAborted(std::move(handler));
  }
}

void uwb_res_on_data(void *res, int32_t ssl, uint64_t request_id, int32_t limit) {
  auto body = std::make_shared<std::string>();
  auto done = std::make_shared<bool>(false);
  auto handler = [request_id, limit, body, done](std::string_view chunk, bool is_last) {
    if (*done) {
      return;
    }
    if (body->size() + chunk.size() > static_cast<size_t>(limit)) {
      *done = true;
      if (g_body_cb != nullptr) {
        g_body_cb(request_id, moonbit_make_bytes_raw(0), 0, UWB_BODY_TOO_LARGE);
      }
      return;
    }
    body->append(chunk.data(), chunk.size());
    if (is_last) {
      *done = true;
      if (g_body_cb != nullptr) {
        g_body_cb(request_id, make_bytes(*body), static_cast<int32_t>(body->size()),
                  UWB_BODY_OK);
      }
    }
  };
  if (ssl != 0) {
    static_cast<uWS::HttpResponse<true> *>(res)->onData(std::move(handler));
  } else {
    static_cast<uWS::HttpResponse<false> *>(res)->onData(std::move(handler));
  }
}

moonbit_bytes_t uwb_res_remote_address(void *res, int32_t ssl) {
  if (ssl != 0) {
    return make_bytes(static_cast<uWS::HttpResponse<true> *>(res)->getRemoteAddressAsText());
  }
  return make_bytes(static_cast<uWS::HttpResponse<false> *>(res)->getRemoteAddressAsText());
}

int32_t uwb_res_remote_port(void *res, int32_t ssl) {
  if (ssl != 0) {
    auto *socket = static_cast<uWS::HttpResponse<true> *>(res)->getNativeHandle();
    return static_cast<int32_t>(us_socket_remote_port(1, static_cast<struct us_socket_t *>(socket)));
  }
  auto *socket = static_cast<uWS::HttpResponse<false> *>(res)->getNativeHandle();
  return static_cast<int32_t>(us_socket_remote_port(0, static_cast<struct us_socket_t *>(socket)));
}

int32_t uwb_fs_kind(moonbit_bytes_t path, int32_t path_len) {
  std::string file(view_of(path, path_len));
  struct stat info;
  if (::stat(file.c_str(), &info) != 0) {
    return 0;
  }
  if (S_ISREG(info.st_mode)) {
    return 1;
  }
  if (S_ISDIR(info.st_mode)) {
    return 2;
  }
  return 0;
}

moonbit_bytes_t uwb_fs_read_file(moonbit_bytes_t path, int32_t path_len) {
  std::string file(view_of(path, path_len));
  FILE *handle = std::fopen(file.c_str(), "rb");
  if (handle == nullptr) {
    return moonbit_make_bytes_raw(0);
  }
  std::string data;
  char buffer[64 * 1024];
  size_t read;
  while ((read = std::fread(buffer, 1, sizeof(buffer), handle)) > 0) {
    data.append(buffer, read);
  }
  std::fclose(handle);
  return make_bytes(data);
}

int64_t uwb_fs_mtime(moonbit_bytes_t path, int32_t path_len) {
  std::string file(view_of(path, path_len));
  struct stat info;
  if (::stat(file.c_str(), &info) != 0) {
    return -1;
  }
  return static_cast<int64_t>(info.st_mtime);
}

} // extern "C"