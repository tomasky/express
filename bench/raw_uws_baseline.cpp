// Raw uWebSockets baseline for the benchmark.
//
// It serves the exact same two responses as the express bench app and the
// moonbitlang/async bench server, but the handler is plain C++ with no MoonBit
// layer. Comparing it against the express package shows how much of the
// difference is the µWebSockets engine and how much is the framework layer on
// top of it.
//
// Built by bench/run_bench.sh with the same TLS flags the express package uses;
// it can also be built by hand:
//
//   g++ -O2 -std=c++17 -I third_party/uwebsockets/src -I third_party/usockets/src \
//       bench/raw_uws_baseline.cpp \
//       third_party/usockets/src/{loop,context,socket,udp,bsd,quic}.c \
//       third_party/usockets/src/eventing/epoll_kqueue.c \
//       -lz -lpthread -o /tmp/raw_uws_baseline
#include "App.h"
#include <cstdio>

int main() {
  uWS::App app;
  app.get("/text", [](auto *res, auto * /*req*/) {
    res->end("Hello, World!");
  });
  app.get("/json", [](auto *res, auto * /*req*/) {
    res->writeHeader("Content-Type", "application/json; charset=utf-8");
    res->end("{\"message\":\"Hello, World!\",\"ok\":true}");
  });
  app.listen(30002, [](auto *token) {
    if (token) {
      std::printf("raw uWebSockets listening on http://127.0.0.1:30002\n");
    } else {
      std::printf("raw uWebSockets failed to listen\n");
    }
  });
  app.run();
  return 0;
}
