#!/usr/bin/env bash
# Re-vendor µWebSockets + µSockets from upstream and re-apply the local patches.
#
# The binding compiles the vendored tree with `moon build` and no `-I` flags,
# so every quoted include has to be relative to the including file. This
# script does the mechanical part: copy src/, rewrite the includes, and add the
# LIBUS_NO_SSL guard.
#
# Usage:  bash third_party/sync_upstream.sh [UWS_REF] [USOCKETS_REF]
# Defaults come from the pinned revisions below. Bump them together with
# third_party/README.md.
set -euo pipefail

UWS_REF="${1:-838754e}"
US_REF="${2:-166a048}"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> fetching uWebSockets @ $UWS_REF"
git clone --quiet https://github.com/uNetworking/uWebSockets.git "$work/uws"
git -C "$work/uws" checkout --quiet "$UWS_REF"

echo ">> fetching uSockets @ $US_REF"
git clone --quiet https://github.com/uNetworking/uSockets.git "$work/us"
git -C "$work/us" checkout --quiet "$US_REF"

# --- uWebSockets: the header-only source tree (no tests, no bonus, no examples)
rm -rf "$here/uwebsockets/src"
cp -r "$work/uws/src" "$here/uwebsockets/src"
cp "$work/uws/LICENSE" "$here/uwebsockets/LICENSE"

# --- uSockets: only the files the stubs compile (see moon.pkg native-stub list)
mkdir -p "$here/usockets/src"
for f in loop.c context.c socket.c udp.c bsd.c quic.c libusockets.h quic.h; do
  cp "$work/us/src/$f" "$here/usockets/src/$f"
done
cp -r "$work/us/src/eventing" "$here/usockets/src/"
rm -f "$here/usockets/src/eventing/asio.cpp" \
      "$here/usockets/src/eventing/gcd.c" \
      "$here/usockets/src/eventing/libuv.c"
# io_uring is not enabled by the stub build; keep the directory out of the tree
rm -rf "$here/usockets/src/io_uring"
mkdir -p "$here/usockets/src/crypto"
cp "$work/us/src/crypto/openssl.c" "$work/us/src/crypto/sni_tree.cpp" \
   "$here/usockets/src/crypto/"
cp -r "$work/us/src/internal" "$here/usockets/src/"
cp "$work/us/LICENSE" "$here/usockets/LICENSE"

# --- local patch 1: plain HTTP by default
python3 - "$here/usockets/src/libusockets.h" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
guard = """
/* Local patch for the MoonBit binding: plain HTTP only. Define
 * MOONBIT_UWS_WITH_TLS to restore the upstream OpenSSL path. */
#ifndef MOONBIT_UWS_WITH_TLS
#ifndef LIBUS_NO_SSL
#define LIBUS_NO_SSL
#endif
#endif
"""
anchor = "#define LIBUSOCKETS_H\n"
if "MOONBIT_UWS_WITH_TLS" not in s:
    s = s.replace(anchor, anchor + guard, 1)
    open(p, "w").write(s)
PY

# --- local patches 2 and 3: relative includes, no -I needed
python3 - "$here" <<'PY'
import os, re, sys

root = sys.argv[1]

# (file, old, new) — anchored on the literal upstream include lines.
uws = {
    "AsyncSocket.h": [('#include "libusockets.h"', '#include "../../usockets/src/libusockets.h"')],
    "Loop.h":        [('#include <libusockets.h>', '#include "../../usockets/src/libusockets.h"')],
    "WebSocketProtocol.h": [('#include <libusockets.h>', '#include "../../usockets/src/libusockets.h"')],
}
for name, subs in uws.items():
    p = os.path.join(root, "uwebsockets", "src", name)
    s = open(p).read()
    for old, new in subs:
        s = s.replace(old, new)
    open(p, "w").write(s)

# uSockets: rewrite every quoted include that points at a file inside src/ so it
# is resolved relative to the including file.
src = os.path.join(root, "usockets", "src")
for dirpath, _dirnames, filenames in os.walk(src):
    for fn in filenames:
        if not fn.endswith((".c", ".h", ".cpp")):
            continue
        p = os.path.join(dirpath, fn)
        rel_dir = os.path.relpath(dirpath, src)
        s = open(p).read()
        out = []
        for line in s.splitlines(keepends=True):
            m = re.match(r'#\s*include\s+"([^"]+)"', line)
            if m:
                inc = m.group(1)
                # internal/... and bare names that exist under src/
                cand = inc
                if cand.startswith("internal/") or not cand.startswith((".", "/")):
                    target = os.path.join(src, cand)
                    if os.path.exists(target):
                        newrel = os.path.relpath(target, dirpath)
                        line = line.replace(f'"{inc}"', f'"{newrel}"')
            out.append(line)
        new = "".join(out)
        if new != s:
            open(p, "w").write(new)
PY

echo ">> done: uWebSockets @ $(git -C "$work/uws" rev-parse --short HEAD), uSockets @ $(git -C "$work/us" rev-parse --short HEAD)"
