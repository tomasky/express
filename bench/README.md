# Benchmark

`autocannon` comparison of this package against MoonBit's own native HTTP
server, plus a raw uWebSockets baseline. The rendered results are in
[`benchmark.md`](./benchmark.md); the raw autocannon JSON for every run is in
[`results/`](./results).

## Layout

| Path | What it is |
| --- | --- |
| `run_bench.sh` | serial driver: builds the raw baseline, starts one server at a time, runs autocannon, stops it |
| `render_results.py` | turns `results/*.json` into `benchmark.md` |
| `http_server_async/` | the moonbitlang/async bench server (separate MoonBit module) |
| `raw_uws_baseline.cpp` | plain C++ µWebSockets handler, no MoonBit layer (diagnostic) |
| `loadgen.c` | C load generator for real throughput (autocannon is client-bound here) |
| `results/` | one autocannon JSON per run, kept as evidence |

## Servers under test

| Server | Source | Port |
| --- | --- | --- |
| express | `../example/bench/main.mbt` | 30000 |
| moonbitlang/async | `http_server_async/main/main.mbt` | 30001 |
| raw uWebSockets | `raw_uws_baseline.cpp` | 30002 |

All three answer `GET /text` with `Hello, World!` and `GET /json` with
`{"message":"Hello, World!","ok":true}`.

## Reproduce

```bash
# 1. build the two MoonBit servers (release)
moon build example/bench --release
(cd bench/http_server_async && moon build --release)   # first run fetches moonbitlang/async

# 2. run every target serially, then render the report
bash bench/run_bench.sh 50 10        # 50 connections, 10 s per run
python3 bench/render_results.py
```

`run_bench.sh` accepts `ONLY="express-text"` to run a single API, and honours
`ROUNDS`, `WARMUP` and `PAUSE` environment variables. It builds
`raw_uws_baseline.cpp` on first use with the same TLS flags the express package
uses.

The bench server reads `BENCH_PORT`, so two builds (for example a before/after
pair) can be loaded at once:

```bash
BENCH_PORT=30999 ./bench_new.exe &        # second instance on another port
```

> The client and the servers share the same machine, so absolute numbers depend
> on the box. Runs are serial (one server, one API at a time) on purpose; the
> report shows the median and the min-max range of every measurement.

## Why the req/s column is not a server ranking

`run_bench.sh` uses `autocannon`, a single-threaded JavaScript client that
shares these two vCPUs with the server, at pipelining 1. Both effects cap it:
the bare C++ handler reports ~17k req/s while burning only **6-9% of one
core**, which is only possible if the client, not the server, is the limit.
The same binaries read 10k-37k req/s across sessions.

`bench/loadgen.c` is a ~150-line C client (one thread, epoll, 16 requests in
flight per connection) that can actually push the server. Server pinned to one
core, client to the other, 64 connections, 5 s, two rounds:

| Server | Response | req/s | server CPU | CPU/req |
| --- | ---: | ---: | ---: | ---: |
| express | 188 B | **168,870-195,786** | 72-79% | 3.8-4.3 us |
| moonbitlang/async | 188 B | 60,492-66,412 | 77-81% | 12.2-12.7 us |
| raw uWebSockets | 188 B | 876,341-901,701 | 72-74% | 0.82 us |
| raw uWebSockets | 106 B | 808,403-848,717 | 23% | 0.29 us (client-capped) |

So: express serves **2.8x** the throughput of moonbitlang/async, and the bare
C++ handler serves **4.9x** express with the same response size -- a factor of
five, not an order of magnitude. Rarely, per-request CPU tells the same story
(3.8-4.3 us vs 0.82 us). The pipelining-1 numbers only look different because
each request then pays a full round trip.

```bash
gcc -O2 -o bench/loadgen bench/loadgen.c
taskset -c 0 ./bench.exe &
taskset -c 1 ./bench/loadgen 30000 64 5 16 /text   # port conns secs inflight path
```

## Findings

- The µWebSockets engine is not the problem, and neither is the response size:
  with the same two syscalls per request (`strace -c`: `recvfrom` + `sendto`)
  and the same 188-byte response, express now costs **the same total CPU per
  request as a bare C++ handler** on the same engine (~20 us each, three paired
  rounds). That is not the 2.7x you get by comparing a 106-byte response
  against a 188-byte one.
- The split shows how the two get there: express's **userspace** cost (MoonBit
  framework code) is ~5.5 us/request *above* the C++ handler's (~8.3 vs
  ~2.8 us), while its **kernel** time is ~5 us/request *below* it (~11.7 vs
  ~16.8 us), so the totals cancel. Both halves have measured 6-50 us across
  sessions on this shared VM, so only same-session, order-alternated pairs are
  comparable.
- Negative results worth keeping: turning express's `ETag` off (44 fewer
  response bytes) changed nothing measurable (29.6 vs 30.4 us, 4 paired
  rounds), and a body-length sweep from 106 B to 213 B in one binary was flat.
  So header/response size is *not* where the remaining CPU goes.
- Ablated per-request costs, measured **at 16 requests in flight** (pipelining 1
  hides them behind the client): a SHA-256 ETag on every response ~1.5-1.8 us
  (the single most expensive piece of framework work), the middleware chain
  (`steps` array + `Step` closure + `Next` record) ~1.1 us, request decode +
  `Req`/`Res` construction + finalize ~1.8 us, and header writes ~0.5 us,
  against a floor of ~0.9 us for a plain C++ handler on the same engine. The
  earlier pipelining-1 ablations (header copy ~5 us, query/cookie parsing
  ~3 us, `getpeername` ~3.5-4.5 us, `ETag` ~1.4 us) overstated the big pieces
  relative to each other and missed that the ETag is the top cost.
- `moon` compiles `native-stub` C/C++ with **no `-O` flag**, so the header-only
  uWebSockets engine used to build at `-O0` even in `--release` (1.7 MB
  executable). `moon.pkg` now passes `-O3`: half the binary, ~5% more
  throughput. It is a cheap win, not the main cause of the gap.

## Optimizing the framework (done)

Two passes of changes in `express.mbt` / `crypto.mbt` removed the per-request
work listed above:

- request headers arrive as a single `Bytes` blob (`name\0value\0`) instead of
  `Array[(String, String)]`, so there is no per-header FFI crossing, allocation
  or lowercased copy; `Req::header` scans the blob case-insensitively.
- `Req.query_params` / `Req.cookies` / `Req.remote_ip` are resolved on first
  use, so a handler that does not read them pays nothing — the last one also
  removes a `getpeername` syscall per request (3 -> 2 syscalls, same as the
  bare handler).
- `Res::set` overwrites in place and `remove_header` compacts in place instead
  of rebuilding a scratch array; `run_param_callbacks` returns early when no
  `param` callbacks are registered; `sha256_bytes` sizes its buffers up front;
  `weak_etag` dropped an unused `replace_all`.
- **`weak_etag` memoizes the last body -> tag pair** (bodies <= 8 KB). The
  pipelining-16 ablations showed the SHA-256 is ~1.5 us of every response, so
  a body that repeats (a page, a JSON payload, a static asset) reuses its tag
  after a byte-for-byte compare instead of rehashing. Output is unchanged --
  the tag for a given body is still the SHA-256 one -- and RSS stays flat
  (the memo retains at most one body). Measured in 7 paired rounds at 16 in
  flight: **4.70 -> 3.69 us/req (1.27x), faster in 7 of 7 rounds**.

The wire output is byte-for-byte identical (status lines, headers, `ETag`
values and bodies for `/text`, `/json`, a query string, a 404, `HEAD` and a
`304 If-None-Match` were dumped from a socket and diffed), and `moon test`
stays at 18/18.

Measured by running the pre-optimization and current binaries alternately on a
pinned core with `taskset` (20k requests per run, CPU read from
`/proc/<pid>/stat`, never from req/s -- only same-session, order-alternated
pairs are comparable on this VM):

| | before | after |
| --- | ---: | ---: |
| median CPU per request (11 paired rounds) | 40.0 us | 27.0 us |

That is ~1.58x less CPU per request; the current build won 8 of the 11 rounds.
Under an identical 5 s `strace -c` load the server served 21k requests before
these changes and 32.5k after (+55%). Throughput measured *across* sessions
still swings more than that on this shared 2-vCPU box, which is why
`benchmark.md` reports ranges rather than single numbers.

## Memory: a per-request reference cycle (fixed)

A separate leak turned up while profiling: RSS grew ~1.6 KB per request
linearly (582 MB after 360k requests) while the raw handler stayed flat. The
MoonBit native runtime is reference counted and cannot reclaim cycles, and the
middleware chain had one: `dispatch_layers` writes its `step` closure into
`steps[0]` while `step` captures `steps`, and `Req.next` points at a `Next`
whose closures capture the same request/response/layer objects. Each finished
request therefore kept its whole object graph alive.

`release_request` now publishes the chain cell into the request slot and breaks
both links when the response ends (cell overwritten with a process-wide no-op,
`Req.next` dropped), so the graph is freed with the request. After the fix RSS
is **flat at 7.2 MB over 180,000+ requests** (320k also flat), wire output is
still byte-identical, and `moon test` stays 18/18. Measured alone in a paired
A/B (7 rounds, 40k requests/run, pinned core): **2.0x less CPU per request**,
10,001 -> 13,335 req/s, and the kernel-time share fell from ~26 to ~11 us/req —
most of it was page-fault work from the growing heap, not the HTTP path.

See [`benchmark.md`](./benchmark.md) for the full numbers and what is still
left on the table.
