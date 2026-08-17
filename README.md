# Abla, Go, Rust, and Zig HTTP comparison

This repository measures the same routed HTTP/1.1 workloads implemented with
Abla Web, Go `net/http`, Rust Axum, and Zig `httpz`. The scenario matrix includes:

```text
plaintext   GET  /plaintext
parameters  GET  /accounts/:account/items/:item?filter=active
context     GET  /context with bearer auth and a request-local user
body-16k    POST /body with a 16 KiB binary body echoed in the response
route-tail-128  GET after 128 decoy routes, with path and query parameters
parameters-16   GET with eight path and eight query parameters
headers-32      GET with 32 request headers and five spread-out lookups
```

The goal is a repeatable engineering baseline, not a universal language
ranking. Each workload is reported separately so an allocation-heavy middleware
path cannot be hidden by a fast plaintext average. Database calls, TLS, logging,
and other application work still require separate benchmarks.

## Run it

The harness builds release binaries, verifies every response, warms each server,
then runs three timed measurements with the same `oha` client settings. On Linux
it pins the server to isolated physical CPUs and the load generator to the
remaining CPUs.

```sh
nix-shell -p oha zig --run 'python3 benchmark.py'
```

Raw results are written to `results/latest.json` (ignored by Git). Useful knobs:

```sh
python3 benchmark.py --scenario all --connections 64 --duration 10 --repetitions 3
python3 benchmark.py --scenario context
python3 benchmark.py --skip-build --server-cpus 2 --client-cpus 8-31
python3 benchmark.py --workers 4 --connections 256
python3 benchmark.py --workers 8 --pin-abla-workers --connections 256
python3 benchmark.py --server zig --workers 8 --zig-event-workers 2 --zig-handler-threads 3
```

The defaults assume this repository is beside `../ablac`. Set `ABLAC` to use a
different compiler, `OHA` to use a specific load-generator binary, and `ZIG` to
use a specific Zig compiler.

## Fairness notes

- All servers expose byte-for-byte equivalent responses for every scenario;
  the harness validates them before load generation.
- All measurements use HTTP/1.1 keep-alive and 64 concurrent connections.
- Release builds are used: Abla's production optimization pipeline, stripped Go,
  Rust `--release` with thin LTO, and Zig `ReleaseFast`.
- The Zig server uses the pure-Zig, nonblocking
  [`httpz`](https://github.com/karlseguin/http.zig) HTTP/1.1 server, pinned by
  commit and package hash. It uses one event-loop worker and two request-handler
  threads in the default single-CPU run, plus its waiting coordinator thread;
  all inherit the same server affinity. This is a single-CPU comparison, not a
  claim that every implementation uses one OS thread.
- The Abla service calls `memorySetLimit(memoryLimit())`, which selects its
  managed collector and automatic memory-pressure safe points. Abla otherwise
  strips the collector for short-lived programs that do not use the memory API.
- Application handlers and middleware are ordinary functions and lambdas. The
  compiler proves non-retention when they cross the request-scoped API boundary;
  application code does not need `noescape` declarations. The authenticated
  context workload uses request-scoped middleware and typed request locals. The event
  server reclaims parsing, routing, and response-framing temporaries together at
  the end of each request. It writes completed small responses before resetting
  the request region, and promotes only an unwritten backpressured response tail
  and unread connection tail that must survive the request.
- The default result is single-CPU throughput. `--workers N` starts N independent
  Abla event loops on the same port with Linux `SO_REUSEPORT`, sets Go
  `GOMAXPROCS=N` and Tokio's worker count to N, and gives Zig at most N active
  event-plus-handler workers when N is at least two. Go, Rust, and Zig use one
  process and worker threads on the same N-CPU affinity set.
  `--pin-abla-workers` optionally binds each Abla process to one selected CPU;
  result metadata records whether the processes shared the set or were pinned.
  Separate Abla processes preserve independent collectors and
  failure boundaries; this harness does not pretend the current shared-heap
  `thread` collector is safe for permanent allocating server workers.
- Server order is fixed, so rerun the suite and inspect the individual samples
  before treating small differences as meaningful.

## Layout

- `servers/abla`: Abla Web and the Abla event HTTP server
- `servers/go`: Go standard-library HTTP server
- `servers/rust`: Axum on Tokio
- `servers/zig`: httpz with routed handlers and authentication middleware
- `diagnostics/http_pipeline_memory.ab`: allocation accounting for parse,
  dispatch, and response-framing stages
- `benchmark.py`: build, validation, CPU isolation, measurements, and JSON output

## Current baseline

The original broken baseline is recorded in
[`results/2026-08-10-i9-13900k.md`](results/2026-08-10-i9-13900k.md). The
optimized result and sustained-memory verification are in
[`results/2026-08-11-i9-13900k.md`](results/2026-08-11-i9-13900k.md). Abla moved
from 4.7 to 103,428 single-worker requests/second after the later response-arena
pass and remained bounded during sustained load. The subsequent
[gnet-informed event-loop and routing pass](results/2026-08-11-i9-13900k-gnet-review.md)
reached 109,657 requests/second, 67.2% of Go and 39.4% of Rust in the same
single-worker harness. The subsequent
[native scalar direct-call ABI](results/2026-08-11-i9-13900k-scalar-abi.md)
reached 111,030 requests/second, 68.1% of Go and 39.9% of Rust. The subsequent
[checked whole-request region](results/2026-08-11-i9-13900k-noescape-region.md)
reached 144,573 requests/second, 89.2% of Go and 52.3% of Rust. The subsequent
[lazy scalar SSA pass](results/2026-08-11-i9-13900k-lazy-scalar-ssa.md) reached
152,868 requests/second, 95.5% of Go and 55.2% of Rust. The subsequent
[compact dynamic-value ABI](results/2026-08-11-i9-13900k-compact-values.md)
reduced values from 40 to 32 bytes and reached 162,515 requests/second on an
explicitly selected quiet P-core: 99.3% of Go and 58.4% of Rust. Typed string
and array operations then reached
[175,820 requests/second](results/2026-08-11-i9-13900k-typed-collections.md),
107.2% of Go and 63.0% of Rust. Checked field indexing, direct region writes,
and further native scalar propagation then reached
[220,714 requests/second](results/2026-08-12-i9-13900k-220k.md), 134.6% of Go
and 78.3% of Rust in the same single-core harness. The four-worker result
(measured before the region and scalar SSA passes) is in
[`results/2026-08-11-i9-13900k-parallel.md`](results/2026-08-11-i9-13900k-parallel.md):
Abla reached 396,714 requests/second, about 80% of Go and 44% of Rust on the
same four server CPUs. This remains an engineering baseline rather than a claim
of parity.

The newer
[holistic workload matrix](results/2026-08-12-i9-13900k-holistic.md) keeps that
plaintext result while exposing the next bottlenecks: Abla reaches 175,919
requests/second for path plus query parameters, 65,355 for bearer middleware
plus request locals, and 41,331 for a 16 KiB binary echo. The scenarios are
deliberately reported separately rather than blended into one score.
The current
[inferred non-retention matrix](results/2026-08-12-inferred-noescape.md) removes
all explicit `noescape` declarations from the benchmark application and beats
Go in every measured workload: 218,886 plaintext, 179,657 parameters, 191,089
authenticated context, and 117,544 16 KiB body requests/second.
The follow-up
[segmented 16 KiB body result](results/2026-08-12-body-scatter.md) profiles that
body ceiling and records the validated direct-receive and scatter-write gain
without changing the small-response path.
The current
[Zig comparison](results/2026-08-17-i9-13900k-zig.md) reruns the complete matrix
on a quiet 5.8 GHz P-core and adds the best locally verified current pure-Zig
candidate. Zig/httpz leads the three small-response workloads at 316,537 to
331,717 requests/second and reaches 160,183 requests/second on the 16 KiB echo,
2.2% ahead of Rust and 2.5% ahead of Abla there.
The tuned
[eight-worker comparison](results/2026-08-17-i9-13900k-eight-worker.md) uses one
hardware thread from each P-core and caps every runtime at eight active workers.
At 256 connections, Abla and Zig are within 1% on plaintext and authenticated
context, Zig leads routed parameters by 4.9%, and Abla leads the 16 KiB echo by
6.6%.
The subsequent
[routed-parameters optimization](results/2026-08-17-parameters-optimized.md)
removes temporary path-segment arrays and query-key slices, then pins each Abla
event loop to one P-core. On an idle five-sample rerun, Abla reaches 1,431,005
requests/second: 5.79% above its earlier result, 1.87% above Zig, and 10.21%
above Rust under the same eight-core limit.
The new
[adversarial routing matrix](results/2026-08-17-ridiculous-routing.md) adds a
128-route tail match, 16 parameters, and 32 headers. It exposed a severe linear
router failure: Abla initially reached only 343,978 requests/second on the
route-tail case. A general registration-time route index raises that to
1,424,665 requests/second, a 4.14x improvement and effective parity with Zig's
1,419,150 under the same eight-core limit.
The final
[adversarial parity pass](results/2026-08-17-adversarial-parity.md) applies the
same positional access model to Abla and Zig for all eight route and eight query
values. Abla reaches 1,399,623 requests/second versus Zig's 1,378,327 (+1.55%).
The 32-header workload remains named in every implementation; Abla reaches
1,089,695 versus Zig's 1,088,706, an effective tie with Abla 0.09% ahead.
