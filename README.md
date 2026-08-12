# Abla, Go, and Rust HTTP comparison

This repository measures the same routed HTTP/1.1 workloads implemented with
Abla Web, Go `net/http`, and Rust Axum. The scenario matrix includes:

```text
plaintext   GET  /plaintext
parameters  GET  /accounts/:account/items/:item?filter=active
context     GET  /context with bearer auth and a request-local user
body-16k    POST /body with a 16 KiB binary body echoed in the response
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
nix-shell -p oha --run 'python3 benchmark.py'
```

Raw results are written to `results/latest.json` (ignored by Git). Useful knobs:

```sh
python3 benchmark.py --scenario all --connections 64 --duration 10 --repetitions 3
python3 benchmark.py --scenario context
python3 benchmark.py --skip-build --server-cpus 2 --client-cpus 8-31
python3 benchmark.py --workers 4 --connections 256
```

The defaults assume this repository is beside `../ablac`. Set `ABLAC` to use a
different compiler and `OHA` to use a specific load-generator binary.

## Fairness notes

- All servers expose byte-for-byte equivalent responses for every scenario;
  the harness validates them before load generation.
- All measurements use HTTP/1.1 keep-alive and 64 concurrent connections.
- Release builds are used: Abla's production optimization pipeline, stripped Go,
  and Rust `--release` with thin LTO.
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
  Abla event loops on the same port with Linux `SO_REUSEPORT`, while Go and Rust
  use one process and their runtime-managed worker threads on the same N-CPU
  affinity set. Separate Abla processes preserve independent collectors and
  failure boundaries; this harness does not pretend the current shared-heap
  `thread` collector is safe for permanent allocating server workers.
- Server order is fixed, so rerun the suite and inspect the individual samples
  before treating small differences as meaningful.

## Layout

- `servers/abla`: Abla Web and the Abla event HTTP server
- `servers/go`: Go standard-library HTTP server
- `servers/rust`: Axum on Tokio
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
