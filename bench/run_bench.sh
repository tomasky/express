#!/usr/bin/env bash
#
# Benchmark the express (uWebSockets) server against the MoonBit-native
# moonbitlang/async HTTP server with autocannon, plus a raw uWebSockets
# baseline (diagnostic).
#
# Methodology:
#   * strictly serial: one server process and one API under load at a time.
#   * a fresh server process for every measurement.
#   * the targets are rotated every round, so slow drift in host load affects
#     all three servers equally instead of penalising whoever runs last.
#
# Usage:
#   bench/run_bench.sh [connections] [duration_seconds]
#
# Env:
#   ROUNDS=3     measured rounds (each round touches every target once)
#   WARMUP=3     warmup seconds discarded before each measurement
#   PAUSE=1      seconds to wait after stopping a server
#   ONLY="express-text async-json"   run a subset of targets
#   PIPELINING=1 requests in flight per connection (raise it to measure
#                server capacity instead of loop-back round-trip latency)
#
# Writes one autocannon JSON file per measurement into bench/results/.

set -uo pipefail

CONNECTIONS="${1:-50}"
DURATION="${2:-10}"
PIPELINING="${PIPELINING:-1}"
# Throughput is measured separately with the C client in bench/loadgen.c:
# autocannon at pipelining 1 is capped by the loop-back round trip, not by the
# servers. Set LOADGEN=0 to skip this part.
LOADGEN="${LOADGEN:-1}"
LOADGEN_CONNS="${LOADGEN_CONNS:-64}"
LOADGEN_PIPES="${LOADGEN_PIPES:-1 16}"
LOADGEN_SECS="${LOADGEN_SECS:-4}"
ROUNDS="${ROUNDS:-3}"
WARMUP="${WARMUP:-3}"
PAUSE="${PAUSE:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$ROOT/bench/results"
EXPRESS_EXE="$ROOT/_build/native/release/build/example/bench/bench.exe"
ASYNC_EXE="$ROOT/bench/http_server_async/_build/native/release/build/main/main.exe"
RAW_SRC="$ROOT/bench/raw_uws_baseline.cpp"
RAW_EXE="$RESULTS/raw_uws_baseline"
LOADGEN_SRC="$ROOT/bench/loadgen.c"
LOADGEN_EXE="$RESULTS/loadgen"
LOADGEN_CSV="$RESULTS/loadgen.csv"

mkdir -p "$RESULTS"

if ! command -v autocannon >/dev/null 2>&1; then
  echo "autocannon not found in PATH" >&2
  exit 1
fi
[[ -x "$EXPRESS_EXE" ]] || { echo "missing $EXPRESS_EXE (run: moon build example/bench --release)" >&2; exit 1; }
[[ -x "$ASYNC_EXE" ]]   || { echo "missing $ASYNC_EXE (run: cd bench/http_server_async && moon build --release)" >&2; exit 1; }

wait_for_port() {
  local port="$1" i
  for i in $(seq 1 100); do
    curl -fsS -o /dev/null "http://127.0.0.1:$port/text" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# Build the raw uWebSockets baseline with the same flags the express stub uses,
# so the only difference left is the framework layer.
build_raw() {
  [[ -x "$RAW_EXE" ]] && return 0
  echo "building raw uWebSockets baseline..."
  local us="$ROOT/third_party/usockets/src"
  local tmp objs=() f
  tmp="$(mktemp -d)"
  local flags="-O3 -DMOONBIT_UWS_WITH_TLS -DLIBUS_USE_OPENSSL -Wno-deprecated-declarations"
  for f in loop context socket udp bsd quic eventing/epoll_kqueue crypto/openssl; do
    gcc $flags -I "$us" -c "$us/$f.c" -o "$tmp/$(basename "$f").o" || return 1
    objs+=("$tmp/$(basename "$f").o")
  done
  g++ -std=c++17 $flags -I "$ROOT/third_party/uwebsockets/src" -I "$us" \
    -c "$us/crypto/sni_tree.cpp" -o "$tmp/sni_tree.o" || return 1
  g++ -std=c++17 $flags -I "$ROOT/third_party/uwebsockets/src" -I "$us" \
    -c "$RAW_SRC" -o "$tmp/raw.o" || return 1
  g++ "${objs[@]}" "$tmp/sni_tree.o" "$tmp/raw.o" -lz -lssl -lcrypto -lpthread \
    -o "$RAW_EXE" || return 1
  rm -rf "$tmp"
}

# measure <name> <exe> <port> <endpoint> <round>
measure() {
  local name="$1" exe="$2" port="$3" endpoint="$4" round="$5"
  local url="http://127.0.0.1:$port/$endpoint"
  "$exe" >"$RESULTS/$name-$endpoint-server.log" 2>&1 &
  local pid=$!
  if ! wait_for_port "$port"; then
    echo "   $name /$endpoint: server did not come up" >&2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 1
  fi
  autocannon -c "$CONNECTIONS" -d "$WARMUP" -p "$PIPELINING" "$url" >/dev/null 2>&1
  autocannon -c "$CONNECTIONS" -d "$DURATION" -p "$PIPELINING" --json "$url" \
    > "$RESULTS/$name-$endpoint-r$round.json" 2>/dev/null
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep "$PAUSE"
}

# Build the C load generator used for the throughput numbers.
build_loadgen() {
  [[ -x "$LOADGEN_EXE" ]] && return 0
  echo "building C load generator..."
  gcc -O2 -o "$LOADGEN_EXE" "$LOADGEN_SRC" || return 1
}

# Throughput for one target: the server is pinned to core 0 and the client to
# core 1, so the two do not fight over the same core. Writes one CSV row per
# (target, requests-in-flight) config: round,target,pipe,conns,rps,cpu_pct,us_per_req
throughput() {
  local name="$1" exe="$2" port="$3" round="$4" pipe rps resp ticks
  taskset -c 0 "$exe" >"$RESULTS/$name-throughput-server.log" 2>&1 &
  local pid=$!
  if ! wait_for_port "$port"; then
    echo "   $name throughput: server did not come up" >&2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 1
  fi
  for pipe in $LOADGEN_PIPES; do
    taskset -c 1 "$LOADGEN_EXE" "$port" "$LOADGEN_CONNS" 1 "$pipe" /text >/dev/null 2>&1
    local t0 t1 out
    t0=$(awk '{s+=$14+$15} END{print s+0}' /proc/$pid/task/*/stat)
    out=$(taskset -c 1 "$LOADGEN_EXE" "$port" "$LOADGEN_CONNS" "$LOADGEN_SECS" "$pipe" /text)
    t1=$(awk '{s+=$14+$15} END{print s+0}' /proc/$pid/task/*/stat)
    rps=$(printf '%s' "$out" | sed -n 's/.*rps=\([0-9]*\).*/\1/p')
    resp=$(printf '%s' "$out" | sed -n 's/.*responses=\([0-9]*\).*/\1/p')
    [[ -z "$rps" || "$rps" == "0" ]] && { echo "   $name throughput p=$pipe: no responses" >&2; continue; }
    awk -v r="$round" -v t="$name" -v p="$pipe" -v c="$LOADGEN_CONNS" \
        -v rps="$rps" -v resp="$resp" -v ticks="$((t1-t0))" -v secs="$LOADGEN_SECS" \
        'BEGIN{ printf "%s,%s,%s,%s,%s,%.1f,%.2f\n", r,t,p,c,rps, 100*ticks/100/secs, ticks/100/resp*1e6 }' \
        >> "$LOADGEN_CSV"
    echo "    p=$pipe: $rps req/s"
    sleep "$PAUSE"
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep "$PAUSE"
}

ALL_TARGETS=(express-text express-json async-text async-json raw-text raw-json)
if [[ -n "${ONLY:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${ONLY})
else
  TARGETS=("${ALL_TARGETS[@]}")
fi

build_raw || { echo "failed to build raw baseline" >&2; exit 1; }
if [[ "$LOADGEN" != "0" ]]; then
  build_loadgen || { echo "failed to build the load generator" >&2; exit 1; }
  [[ -f "$LOADGEN_CSV" ]] && rm -f "$LOADGEN_CSV"
  printf 'round,target,pipe,conns,rps,cpu_pct,us_per_req\n' > "$LOADGEN_CSV"
fi

run_target() {
  local target="$1" round="$2" name="${1%%-*}" endpoint="${1##*-}"
  case "$name" in
    express) measure express "$EXPRESS_EXE" 30000 "$endpoint" "$round" ;;
    async)   measure async   "$ASYNC_EXE"   30001 "$endpoint" "$round" ;;
    raw)     measure raw     "$RAW_EXE"     30002 "$endpoint" "$round" ;;
    *) echo "unknown target: $target" >&2; exit 1 ;;
  esac
}

n=${#TARGETS[@]}
for round in $(seq 1 "$ROUNDS"); do
  echo "== round $round/$ROUNDS =="
  offset=$(( (round - 1) % n ))
  for i in $(seq 0 $((n - 1))); do
    target="${TARGETS[$(( (i + offset) % n ))]}"
    echo ">>> $target  (-c $CONNECTIONS -d $DURATION -p $PIPELINING)"
    run_target "$target" "$round"
    if [[ "$LOADGEN" != "0" && "$target" == *-text ]]; then
      case "$target" in
        express-text) throughput express "$EXPRESS_EXE" 30000 "$round" ;;
        async-text)   throughput async   "$ASYNC_EXE"   30001 "$round" ;;
        raw-text)     throughput raw     "$RAW_EXE"     30002 "$round" ;;
      esac
    fi
  done
done

echo
echo "done; raw results in $RESULTS"