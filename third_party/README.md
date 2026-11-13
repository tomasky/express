# Vendored µWebSockets / µSockets

This directory contains the µWebSockets and µSockets sources the native
binding compiles against. Both are Apache-2.0, see `*/LICENSE`.

| Directory | Upstream | Revision |
| --- | --- | --- |
| `uwebsockets/` | https://github.com/uNetworking/uWebSockets (`src/`) | `838754e` |
| `usockets/` | https://github.com/uNetworking/uSockets (`src/`) | `166a048` |

Re-vendor with `bash third_party/sync_upstream.sh [UWS_REF] [USOCKETS_REF]`;
the script copies the trees and re-applies the patches below.

## Local patches

Only the following changes were made on top of upstream:

1. `usockets/src/libusockets.h`: defines `LIBUS_NO_SSL` unless
   `MOONBIT_UWS_WITH_TLS` is defined. The binding serves plain HTTP unless
   TLS is compiled in.
2. `usockets/src/**`: quoted includes use paths relative to the including file
   instead of `internal/...` paths, so the stubs compile without `-I` flags.
3. `uwebsockets/src/{AsyncSocket,Loop,WebSocketProtocol}.h`: include the
   vendored `libusockets.h` by relative path instead of relying on `-I`.

Only the files listed in `moon.pkg`'s `native-stub` array are needed from
`usockets`; `asio.cpp`, `gcd.c`, `libuv.c` and `io_uring/` are not vendored.

Because the binding points at these copies, `moon build` needs no extra
compiler flags for the stubs. Executable packages only add `-lstdc++ -lz`.
