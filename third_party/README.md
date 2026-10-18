# Vendored µWebSockets / µSockets

This directory contains the µWebSockets and µSockets sources the native
binding compiles against. Both are Apache-2.0, see `*/LICENSE`.

| Directory | Upstream | Revision |
| --- | --- | --- |
| `uwebsockets/` | https://github.com/uNetworking/uWebSockets (`src/`) | uWebSockets.js tree @ `139419c`, submodule commit `589c282` |
| `usockets/` | https://github.com/uNetworking/uSockets (`src/`) | `86097c4` |

## Local patches

Only the following changes were made on top of upstream:

1. `usockets/src/libusockets.h`: defines `LIBUS_NO_SSL` unless
   `MOONBIT_UWS_WITH_TLS` is defined. The binding serves plain HTTP, so no
   OpenSSL link dependency is required by default.
2. `usockets/src/**`: quoted includes use paths relative to the including file
   instead of `internal/...` paths, so the stubs compile without `-I` flags.
3. `uwebsockets/src/{AsyncSocket,Loop,WebSocketProtocol}.h`: include the
   vendored `libusockets.h` by relative path instead of relying on `-I`.

Because the binding points at these copies, `moon build` needs no extra
compiler flags for the stubs. Executable packages only add `-lstdc++ -lz`.
