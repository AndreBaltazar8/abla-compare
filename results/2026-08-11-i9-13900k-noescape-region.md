# Checked whole-request region result: 2026-08-11

Machine: Intel Core i9-13900K, Linux 6.17.3, one pinned server CPU, separate
client CPUs. The load was HTTP/1.1 keep-alive with 64 connections, a 3-second
warm-up, and three 10-second measurements. Values below are medians. The
harness validated HTTP 200, the content type, and the exact response body
before load, and every measured request succeeded.

| Server | Requests/second | p50 latency | p99 latency |
| --- | ---: | ---: | ---: |
| Abla Web + event HTTP | 144,573 | 0.407 ms | 0.800 ms |
| Go `net/http` | 162,081 | 0.394 ms | 0.831 ms |
| Rust Axum/Tokio | 276,214 | 0.233 ms | 0.249 ms |

Toolchains: Abla compiler commit `91d50b7`, Abla Web commit `3d836b9`, Go
1.25.1, Rust 1.95.0, Axum 0.8.9, Tokio 1.53.1, and oha 1.10.0.

Abla reaches **89.2% of Go throughput** and **52.3% of Rust throughput** in
this practical routed-HTTP comparison. Against the preceding canonical
111,030 req/s result, the checked whole-request region improves throughput by
**30.2%**.

## Retained design

The language now has a checked `FnNoEscape(A) -> R` callable type and
`noescape fun` declarations. The type checker prevents an ordinary callback
from being upgraded to this contract, while allowing a noescape callable to be
used where an ordinary callable is expected. Region analysis permits indirect
calls only through the checked noescape type.

The event HTTP server uses that contract to place request parsing, handler
execution, routing, and response framing in one region.
At the request boundary it promotes only the final response frame and any
unread input tail needed by the connection. Abla Web provides a static
noescape route for exact paths, parameters, GET-to-HEAD fallback, 404, and 405
handling. This deliberately narrow route omits the general router's dynamic
mutation and middleware chain. The existing general router and event-server
APIs remain available and unchanged for those features and for handlers whose
values may escape.

The host heap lock is also skipped while no runtime worker threads exist. The
lock remains active from before the first worker starts until after the last
worker's final heap operation, preserving the multithreaded path.

The combined change reduced the profiled request cost from about 66,800 to
about 53,000 retired instructions. Allocator and collector functions stopped
dominating the request profile; the remaining `abla_runtime_memory_pressure`
checks and boxed value operations are now clearer compiler targets.

## Rejected experiments

Several candidates were measured and then removed because they did not improve
the benchmark or made the binary materially larger:

- reusable collector traversal buffers retained too much capacity and reduced
  throughput;
- skipping region memory-pressure checks was neutral to slightly negative;
- forcing pressure helpers inline gained roughly 1% but added about 336 KiB;
- a hidden region-active call ABI was sound but slightly slower;
- eagerly synchronized boxed/native scalar locals regressed by about 2%.

The scalar-local experiment confirms that useful SSA promotion must be lazy:
keep proven scalar locals and temporaries only in registers, and materialize an
`AblaValue` solely at dynamic, stored, captured, returned, or otherwise
escaping boundaries. Eagerly maintaining both representations defeats the
optimization.

## Verification

The compiler passed all 74 manifest tests and its pure-Abla O2 self-rebuild
produced byte-identical IR and a working native child. The new suite covers
valid noescape callbacks, rejection of ordinary callbacks, standard HTTP
handlers, and the threaded heap-lock path. Abla Web passed its framework,
source-build, and integration tests, including the noescape static route's
parameter, HEAD, 404, and 405 behavior.

All three benchmark servers were rebuilt from their pinned dependencies before
this run. The raw oha output and complete harness metadata are stored beside
this report.
