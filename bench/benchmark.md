# HTTP benchmark: express (MoonBit) vs moonbitlang/async

`autocannon` load test of three servers that answer the same two routes
with no application logic, so the numbers reflect the HTTP stack only:

| Server | What it is |
| --- | --- |
| **express** | this repo: MoonBit router/middleware on µWebSockets (`example/bench`) |
| **moonbitlang/async** | MoonBit's own native async HTTP server, no third-party engine |
| raw uWebSockets *(diagnostic)* | plain C++ µWebSockets handler, no MoonBit layer |

Routes served by every server:

| Route | Body | Content-Type |
| --- | --- | --- |
| `/text` | `Hello, World!` (13 B) | `text/plain; charset=utf-8` |
| `/json` | `{"message":"Hello, World!","ok":true}` (37 B) | `application/json; charset=utf-8` |

## Headline

> Read the req/s numbers with the caveat in *Throughput* below: at
> pipelining 1 they are capped by the load generator and the loop-back round
> trip, not by the servers. The stable comparison is CPU per request.

- At pipelining 1 all three servers land in a **17,735-28,358 req/s**
  band, because that column is capped by the load generator and the
  loop-back round trip (the bare C++ handler reports its req/s while
  burning only 6-9% of one core). It does **not** rank the servers; see
  *Throughput* below.
- Throughput, measured with `bench/loadgen.c` (C client, server on one
  core, client on the other, 64 connections): with one request in
  flight express serves **54,196 req/s**, moonbitlang/async
  **42,960** and bare C++ uWebSockets **74,295** (1.3x and 1.4x express). With 16 in
  flight: express **155,026**, async **55,664**, bare C++
  **825,144** (2.8x and 5.3x
  express). In throughput the gap to native is a factor of a few; per
  request of server CPU it is larger, because batching removes the
  engine's syscall cost but not the framework's. Express beats
  MoonBit's own HTTP server in both cases.
- Framework work has come down in steps: **40.0 -> 27.0 µs CPU per
  request** in the first pass (median of 11 paired rounds on a pinned
  core), then to **~12 µs with one request in flight and ~4.7 µs
  pipelined** once the memory leak below was fixed, then **4.7 -> 3.7 µs
  pipelined** by memoizing the default ETag, then **3.7 -> 2.69 µs** by
  removing the path-match `to_lower` copies, the `Next` closures and the
  per-request `Map`s (same 188-byte response, server CPU per request,
  pinned core).
  A reference cycle in the middleware chain was also found to leak
  ~1.6 KB per request (582 MB after 360k requests); fixing it alone is
  another **2.0x** in CPU per request, with RSS now flat at 7.2 MB.
  Details under *Optimization passes* and *Memory* below.

## Results

| Server | Route | Req/s (median) | Range | Latency mean | p50 | p99 | Throughput |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| express (uWebSockets + MoonBit framework) | `/text` | 20,478 | 18,510-21,413 | 1.93 ms | 1.00 ms | 12.00 ms | 3.8 MB/s |
| express (uWebSockets + MoonBit framework) | `/json` | 21,512 | 20,290-23,960 | 1.82 ms | 1.00 ms | 12.00 ms | 4.7 MB/s |
| moonbitlang/async (pure MoonBit HTTP server) | `/text` | 28,358 | 15,818-35,973 | 1.24 ms | 1.00 ms | 11.00 ms | 2.6 MB/s |
| moonbitlang/async (pure MoonBit HTTP server) | `/json` | 24,234 | 16,388-25,260 | 1.54 ms | 1.00 ms | 15.00 ms | 3.0 MB/s |
| raw uWebSockets (C++ handler, no framework) _(diagnostic)_ | `/text` | 17,735 | 17,722-18,014 | 2.34 ms | 2.00 ms | 13.00 ms | 1.9 MB/s |
| raw uWebSockets (C++ handler, no framework) _(diagnostic)_ | `/json` | 17,534 | 16,957-17,614 | 2.37 ms | 2.00 ms | 15.00 ms | 3.1 MB/s |

### Ratios

| Route | express | moonbitlang/async | async / express | raw uWS | raw / express |
| --- | ---: | ---: | ---: | ---: | ---: |
| `/text` | 20,478 | 28,358 | 1.38x | 17,735 | 0.87x |
| `/json` | 21,512 | 24,234 | 1.13x | 17,534 | 0.82x |

## Throughput: what the req/s column can and cannot tell you

**The req/s column above is limited by the load generator, not by the
servers.** `autocannon` is a single-threaded JavaScript client sharing these
two vCPUs with the server, and every run above uses pipelining 1, so it is
also waiting for a full loop-back round trip between requests. The giveaway
is in that same table: the bare C++ handler reports ~17k req/s while burning
only **6-9% of one core**. A server that idle cannot be the limit, and the
same binaries read 10k to 37k req/s between sessions.

`bench/loadgen.c` is a ~150-line C client (one thread, epoll, keeps N
requests in flight per connection) that can push the server instead.
`run_bench.sh` now runs it for every `/text` measurement: server pinned to
one core, client to the other, 64 connections, 4 s per config. Medians over
the rounds of this run:

| Server | 1 in flight | CPU/req | 16 in flight | CPU/req |
| --- | ---: | ---: | ---: | ---: |
| express | 54,196 req/s | 11.8 us | 155,026 req/s | 4.66 us |
| moonbitlang/async | 42,960 req/s | 16.2 us | 55,664 req/s | 13.38 us |
| raw uWebSockets | 74,295 req/s | 2.8 us | 825,144 req/s | 0.25 us |

Read the two columns separately, because they answer different questions:

- **One request at a time** (a browser, or a proxy without pipelining):
  express 54,196 req/s vs async 42,960 (**1.3x**)
  and raw 74,295 (**1.4x** express). At this
  concurrency the client itself is partly round-trip bound: raw reports
  its req/s while using only ~20% of a core, so read **CPU/req** here,
  not req/s (11.8 us express, 16.2 us async, 2.81 us raw).
- **16 requests in flight**: express 155,026 req/s, async
  55,664 (**2.8x**), raw 825,144
  (**5.3x** express). µWebSockets coalesces the write-back
  of pipelined responses, so express drops from ~11.8 us to ~4.7 us
  per request while the async server barely improves (16.2 -> 13.4 us):
  it answers pipelined requests one at a time. That is an engine property,
  not something the framework layer can change. raw is still client-capped
  here (~24% of a core at 825,144 req/s), so its true ceiling is higher.

So *how much faster is native* has two honest answers. **In throughput**:
about 1.4x with one request in flight and 5.3x with 16, both
limited by the client. **In server CPU per request**: 4.2x and 18.6x --
the second is larger because batching makes the engine's syscall cost
vanish while the framework's ~4.7 us of MoonBit work per request does
not. That per-request MoonBit work is what the next round targets.

Express is faster than MoonBit's own HTTP server in both columns, in
throughput as well as in CPU per request.

Reproduce:

```bash
gcc -O2 -o bench/loadgen bench/loadgen.c
# server on core 0, client on core 1: 64 conns, 16 in flight, 5 s
taskset -c 0 ./bench.exe &
taskset -c 1 ./bench/loadgen 30000 64 5 16 /text
```

`PIPELINING=10 bash bench/run_bench.sh` also beats the round-trip ceiling with
autocannon (express reached 76,740 req/s at 48% of a core that way), but the
C client is what actually reaches the servers' limits.

## Where the per-request CPU goes

The µWebSockets engine is not the problem, and neither is the response size.
Measured with `/proc/<pid>/stat` on a pinned core, alternating the binaries
so host drift hits both:

| Variant | Response | user µs/req | kernel µs/req | total µs/req |
| --- | ---: | ---: | ---: | ---: |
| express, default headers | 188 B | 8.3 | 11.7 | 20.0 |
| plain C++ handler, same 188 B response | 188 B | 2.8 | 16.8 | 19.6 |
| plain C++ handler, 3 fewer headers | 106 B | 1.1 | 5.3 | 6.4 |

- At the **same response size** express and the plain C++ handler now cost
  **the same total CPU per request** (~20 µs). The framework adds ~5.5 µs of
  userspace work (routing, middleware, header parsing, response building) and
  gives back ~5 µs of kernel time, so the totals land on top of each other.
- `strace -c` shows the syscall count is already at parity: exactly 2 per
  request (`recvfrom` + `sendto`) for express and for the plain handler, with
  one 188-byte `sendto` per response in both.
- Response bytes are *not* the cost, contrary to what the 106 B vs 188 B row
  above suggests: turning express's `ETag` off (44 fewer bytes, 4 paired
  rounds, order alternated) changed nothing measurable (29.6 vs 30.4 µs),
  and a body-length sweep from 106 B to 213 B in one binary was flat.
  The 106 B row is cheap because that handler writes no headers at all and
  takes uWS's minimal path, not because it is 82 bytes shorter.
- Most of the original per-request CPU was removable framework work: the
  optimization passes cut userspace, and fixing the memory leak cut the
  kernel time that a growing heap was adding.

Ablations on a pinned core found these costs in the original build:

| Per-request work | Measured cost |
| --- | ---: |
| building `Array[(String, String)]` of headers: 2 FFI calls + 2 allocations per header, names lowercased into a `Map` | ~5 µs |
| `parse_query` + `parse_cookies` building two `Map`s on every request, even when unused | ~3 µs |
| `remote_ip`: one `getpeername` syscall per request (`strace`: 21,067 calls for 21,068 requests) | 3.5-4.5 µs |
| ETag: SHA-256 + base64 over the body, on by default | ~1.4 µs |
| `Res::set`/`remove_header` rebuilding a scratch array per call | ~1 µs each |
| dispatch chain: `steps` array, closures and a `Next` record per request | ~1-2 µs |

`moon` also compiles `native-stub` C/C++ **with no `-O` flag**, so the
header-only µWebSockets engine was built at `-O0` even in `--release` (the
executable was 1.7 MB). `moon.pkg` now passes `-O3`, which halves the binary
and buys ~5% throughput -- cheap, but not the explanation for the gap.

> Caveat: kernel-time attribution on this shared 2-vCPU VM is not stable
> across sessions -- the same binary has measured anywhere from 6 to 25 µs of
> kernel time per request. Only same-session, order-alternated pairs are
> comparable, which is how every number above was taken.

## Optimization passes (measured, not just proposed)

Every change below removes per-request allocation or a syscall in the
framework layer. The wire output is byte-for-byte unchanged: status lines,
headers, `ETag` values and bodies for `/text`, `/json`, a query string, a
404, `HEAD` and a `304 If-None-Match` were dumped from a socket and diffed
before and after (identical), and `moon test` stays at 18/18.

| Change | What it removes per request |
| --- | --- |
| all request headers arrive as one `Bytes` blob (`name\0value\0`) instead of `Array[(String, String)]` | 2 FFI calls + 2 allocations **per header**, and the lowercased name copy |
| `Req::header` scans the blob case-insensitively | a hash-map build for headers, 2-3 short string copies per lookup (`Content-Type` and `ETag` have capitals) |
| query and cookies parsed on first use | two `Map` builds on requests that never read a query param or a cookie |
| `remote_ip` resolved on first use | one `getpeername` syscall per request |
| `run_param_callbacks` returns early when no `param` callbacks exist | a cursor array, a `steps` array and a closure |
| `Res::set` overwrites in place; `remove_header` compacts in place | a scratch array built by every `res.set`/`remove_header` |
| `sha256_bytes` sizes its buffers up front | ~6 array reallocations per ETag |
| `weak_etag` drops a `replace_all` whose result is never used | one 44-character copy per response |
| `weak_etag` memoizes the last body -> tag pair (bodies <= 8 KB) | a full SHA-256 + base64 per response when the body repeats |
| `match_path` compares fixed segments with `eq_segment_ci` | two lowercased string copies per segment per request |
| `Next` stores the dispatch state + step instead of three closures | two closure allocations per `Next`, built per request |
| `req.params` / `req.body_form` / `req`+`res.locals` are `Map?` until read | three `Map` builds per request on routes that never read them |

### Measured effect

Paired A/B on a pinned core (`taskset`): the pre-optimization binary and the
current one alternate, 20,000 requests per run, so drift in host load hits
both. CPU per request is read from `/proc/<pid>/stat`, not from req/s, which
swings ±50% between sessions on this shared box:

| Round | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before (µs/req) | 88.5 | 44.5 | 62.0 | 42.0 | 21.5 | 77.5 | 27.0 | 38.0 | 26.5 | 28.5 | 40.0 |
| after (µs/req) | 30.0 | 27.0 | 31.0 | 26.5 | 24.0 | 23.5 | 27.5 | 24.0 | 27.0 | 26.0 | 30.5 |

- Median: **40.0 -> 27.0 µs CPU per request**, a **1.58x** reduction; the
  optimized build wins 8 of the 11 paired rounds (the loser rounds are the
  ones where the host stalled the `before` run).
- Split at 50 connections, `/text`: userspace ~8.3 µs vs ~11.7 µs kernel
  (before the leak fix the kernel share was ~25 µs and the split was the
  other way round). The framework's userspace is **cheaper than
  moonbitlang/async's** (~8 vs ~11 µs); the raw C++ handler is lower still in
  userspace (~3 µs) but spends *more* kernel time, so totals match.
- Syscalls per request went from 3 to 2 (`strace -c`: `getpeername` 21,067
  calls for 21,068 requests before, 0 after), now equal to the bare handler.
- Under an identical 5 s `strace -c` load the server served 21k requests
  before these changes and 32.5k after (+55%).

### Where the cost goes at pipelining 16

At pipelining 1 the client is the bottleneck and hides most of the framework
work, so the ablations were repeated at **16 requests in flight** on 64
connections (server pinned to core 0, C load generator on core 1). Each row
is a build with exactly one part removed, measured back to back in rotated
order; server CPU per request comes from `/proc/<pid>/stat`.

| Build | rps | CPU/req | What it removes |
| --- | ---: | ---: | --- |
| full framework | ~160k | **4.70 µs** | -- |
| no header writes (status line only) | ~188k | 4.23 µs | `write_head`'s per-header FFI calls |
| no middleware chain (respond in `start_request`) | ~208k | 3.62 µs | `dispatch_layers`, `Next`, closures |
| no ETag hash (freshness check kept) | ~255k | **2.92 µs** | `weak_etag` + `set("ETag", ...)` |
| ETag kept, freshness check removed | ~162k | 4.44 µs | `req.fresh()` only |
| empty request-header blob | ~186k | ~4.2 µs | the `name\0value\0` blob copy |
| no MoonBit at all (plain C++ handler) | ~760k | **0.91 µs** | Req/Res, dispatch, finalize, FFI |

Reading the deltas against the full framework:

- **Engine and syscalls: ~0.9 µs** -- what a plain C++ handler costs; the floor.
- **Request decode, `Req`/`Res` construction, finalize, FFI: ~1.8 µs** --
  mostly allocations (four `Map`s and several `String`s per request) and the
  response-building path.
- **Middleware chain: ~1.1 µs** -- routing plus the `steps` array, `Step`
  closure and `Next` record. This looked like ~2% at pipelining 1 purely
  because the client was the bottleneck there; at 16 in flight it is ~25% of
  the framework's cost.
- **Header writes: ~0.5 µs** -- one `utf8_bytes` copy and one FFI crossing
  per header.
- **ETag: ~1.5-1.8 µs** -- one SHA-256 over the body plus base64 and a header
  set, on by default. **The single most expensive piece of framework work
  per response.** The freshness check next to it (`req.fresh()`) costs
  nothing measurable.

That last number is why the ETag memo below exists: the tag is a pure
function of the body, and real traffic repeats bodies far more than it
changes them.

### Measured effect of the ETag memo

The pipelining-16 ablations put ~1.5 µs of every response into the default
ETag. The memo keeps the last body it hashed and its tag, compares an
incoming body byte for byte (13 bytes for `/text`, so a few nanoseconds) and
reuses the tag when they match; when they differ it hashes and stores the
new pair. Bodies larger than 8 KB are never retained. Output is unchanged:
the memo only skips recomputing a value that is already correct for that
body.

Seven paired rounds, order alternated, server pinned to core 0, C load
generator on core 1, 64 connections, 16 in flight:

| Round | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before (µs/req) | 4.65 | 4.69 | 4.68 | 6.68 | 5.49 | 5.56 | 4.70 |
| after (µs/req) | 4.28 | 3.69 | 3.70 | 3.51 | 3.63 | 3.80 | 3.40 |

- Median **4.70 -> 3.69 µs CPU per request**, a **1.27x** reduction; the
  after build is faster in **7 of 7** paired rounds.
- rps moves from ~161k to ~195k in the same runs (the host is noisy, so the
  CPU figure is the reliable one).
- RSS stays flat: 7232 kB after warmup, 7248 kB after 140k requests across
  `/text`, `/json` and a 404. The memo retains at most one body plus its tag.
- Wire output byte-for-byte identical (the tag for a given body is still the
  SHA-256 one); `moon test` 18/18.

What the memo does not help: a handler whose response body changes on every
request still pays the full hash. That is inherent to SHA-256 in pure
MoonBit; the honest options for that case are setting `ETag` yourself in the
handler (which skips the automatic one) or turning the `etag` setting off.

### Second round: where the remaining microseconds went

The memo changed the ranking, so the next three changes were each measured
the same way (pinned cores, 16 in flight, order alternated) and each was
kept only because the paired rounds showed it:

| Change | Paired result | Kept? |
| --- | --- | --- |
| `match_path` no longer calls `to_lower()` twice per fixed segment | 3.19 -> 3.02 µs (-5%) | yes |
| `Next` holds `{state, step}` instead of three closures | 2.96 -> 2.78 µs (-6%) | yes |
| `set("ETag", ...)` replaced by a direct `headers.push` | no measurable change | **no**, reverted |
| `req.params` / `form` / `locals` become `Map?` | 3.04 -> 2.69 µs (-11.5%, 7 of 8 pairs) | yes |

The third row is worth recording: `has_header` has already proved the header
is absent, so skipping `Res::set`'s MIME check, linear scan and dedupe looks
obvious, but two independent 4-5 round sessions put the medians within
noise of each other, so it was reverted rather than kept on faith.

Cumulative, this build versus the one before the pipelining-16 work:
**4.70 -> 2.69 µs CPU per request** (~1.75x) for the same 188-byte response,
with the wire format unchanged throughout.

## Memory: a per-request reference cycle

While profiling the kernel-time share, RSS turned out to grow by about
**1.6 KB per request**, perfectly linearly: 7.2 MB at start, 107 MB after
60k requests, 582 MB after 360k. The bare C++ handler stays flat at 6.7 MB
and moonbitlang/async at 2.9 MB, so it was in the framework layer, and it
was not free: the allocator/page-fault work it caused landed in *kernel*
time and inflated exactly the number being compared.

Bisecting it took four steps, each one a measurement rather than a guess:

1. Disabling the `onAborted` registration: **no change** (~1.6 KB/req).
2. `mi_stats_print()` (mimalloc) reported ~245 pages, so the retained
   memory was not mimalloc's: MoonBit objects come from the runtime's own
   reference-counted heap.
3. Slot-table counters balanced exactly (`new=1 reuse=20002 clear_ok=20002`)
   so the request table was not retaining state.
4. Bypass builds: responding without constructing `Req`/`Res` leaked 0 B per
   request; constructing them but skipping `dispatch` also leaked 0 B;
   running `dispatch` leaked 1.6 KB.

The cause is a **reference cycle in the middleware chain**. `dispatch_layers`
ends with `steps[0] = step`, while `step` itself captures `steps` (it reads
`steps[0]` to build each `Next`), so `steps <-> step`; and `step` also
captures the request, the response, the layer list and the completion
callback. `Req.next` points at a `Next` whose closures capture the same
objects. MoonBit's native backend is reference counted (Perceus), which by
design cannot reclaim cycles, so every request kept its whole object graph
alive for the life of the process.

Fix: the chain's `steps` cell is published to the request slot in
`dispatch_layers`, and `release_request` breaks both links once the response
is finished, by overwriting the cell with a process-wide no-op and dropping
`Req.next`. A finished response can no longer legitimately continue the
chain, so `next()` after the end is now a no-op instead of resuming a chain
whose response has already been sent.

Verified:

- RSS: **7228 kB -> 7256 kB over 180,000 requests** across `/text`, `/json`
  and a 404 (previously 582 MB at 360k). A 320k-request run stays flat too,
  and a later re-check with the ETag memo in place measured **7232 kB ->
  7248 kB over 140,000 requests**.
- Wire output still byte-identical (status line, headers, `ETag`, bodies for
  `/text`, `/json`, query string, 404, `HEAD`, 304); `moon test` 18/18.

Measured effect of the fix alone (paired A/B, pinned core, 40,000 requests
per run, 7 rounds, order alternated):

| Round | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| before (µs/req) | 45.00 | 46.50 | 26.50 | 50.25 | 27.00 | 41.50 | 27.25 |
| after (µs/req) | 22.25 | 21.25 | 23.50 | 24.25 | 22.75 | 20.75 | 23.25 |

- Median **2.00x less CPU per request**, faster in 7 of 7 rounds.
- Client req/s (median) **10,001 -> 13,335**.
- Kernel time per request on `/text` fell from ~26 µs to ~11 µs: most of that
  was the page-fault work of an ever-growing heap, not the HTTP path.

## Remaining gap

Against a plain C++ handler sending the same 188-byte response, express now
costs the **same total CPU per request** (~20 µs each, three paired rounds,
order alternated). The split is not the same, though:

- **Framework userspace: ~5.5 µs/request more than raw.** ~8.3 µs for express
  vs ~2.8 µs for the C++ handler. That is the price of routing, middleware,
  the request accessors and the response builder. It is reproducible in every
  round; the optimization passes below already cut it by 1.58x, and the ETag
  memo shaves a further ~1 µs on repeating bodies.
- **Kernel time: ~5 µs/request less than raw.** Express measured ~11.7 µs
  against ~16.8 µs for the C++ handler in the same runs. Both do exactly 2
  syscalls per request (`recvfrom` + `sendto`) and one 188-byte `sendto` per
  response, so there is no structural difference to point at, and on this
  shared VM the same binaries have measured 6-50 µs across sessions. The two
  effects cancel, which is why the totals match while userspace does not.

What is left to try, ordered by what the pipelining-16 ablations say it is
worth (they were the only measurements that separated the parts, because at
pipelining 1 the client hid most of the framework's work):

1. **ETag for non-repeating bodies: ~1.5 µs.** The memo handles repeated
   bodies; a handler that generates a unique body per request still pays the
   full SHA-256. Inherent to pure-MoonBit SHA-256 -- the options are a faster
   hash (changes the tag value) or handlers supplying their own `ETag`.
2. **Middleware chain: ~1.1 µs, ~0.7 µs left.** The `to_lower` copies and
   the three `Next` closures are gone; `dispatch_layers` still allocates the
   `steps` array and the `Step` closure itself, and `Req.next` still holds a
   fresh `Next` record per request -- pooling those is the next step.
3. **Request decode / `Req`/`Res` construction / finalize: was ~1.8 µs.**
   The three unused `Map`s are gone; what remains is the `Req`/`Res` records
   themselves (a dozen `String`s and a `Bytes` each) plus `original_url`
   concatenation. Pooling records across requests would remove the rest.
4. **Header writes: ~0.5 µs.** `Res::write_head` copies each header into
   `Bytes` and crosses the FFI once per header; batching the headers into one
   `name\0value\0` blob and crossing once removes 5-6 crossings.
5. Benchmark with the load generator on a *separate* host. On this shared
   2-vCPU box the same binary varies 2-4x between sessions, which is larger
   than the effects being chased.

## Method

- Tool: [autocannon](https://github.com/mcollina/autocannon) `autocannon v8.0.0`
- Connections: `50`, pipelining: `1`, duration: `5s` per run
- Each target is warmed up for 3 s, then measured 3x; the table reports the **median**, with the min-max range of the runs.
- Runs are **serial**: one server process and one API under load at a time, so no two benchmarks overlap. Targets are rotated every round so slow drift in host load hits all three equally.
- express and moonbitlang/async binaries are built with `moon build --release`; the raw baseline is built with `g++ -O3` and the same TLS flags as the express stub.
- All runs had 0 errors and 0 non-2xx responses.
- Date: 2026-10-27 10:55 UTC

## Machine

- CPU: AMD EPYC 9655P 96-Core Processor
- vCPUs visible: 2
- Memory: 2.2 GiB
- OS: Linux-6.18.46-railway-x86_64-with-glibc2.43

> The load generator runs on the same VM as the servers, so on this 2-vCPU
> box the client and server share two cores. Absolute numbers are noisy; the
> min-max range is given for every row, and the relative ordering was stable
> across all runs.

