# Typed collection operations result: 2026-08-11

Machine: Intel Core i9-13900K, Linux 6.17.3. Every server was pinned to the
previously selected quiet P-core CPU 14, its SMT sibling CPU 15 was excluded,
and `oha` was pinned to E-cores 16-31. The load used HTTP/1.1 keep-alive, 64
connections, a 3-second warm-up, and three 10-second measurements. Every
response passed status, content type, and exact-body validation.

| Server | Requests/second | p50 latency | p99 latency |
| --- | ---: | ---: | ---: |
| Abla Web + event HTTP | 175,820 | 0.315 ms | 0.635 ms |
| Go `net/http` | 164,072 | 0.388 ms | 0.809 ms |
| Rust Axum/Tokio | 279,271 | 0.233 ms | 0.244 ms |

Abla reaches **107.2% of Go throughput** and **63.0% of Rust throughput** in
this routed-HTTP comparison. Against the preceding 162,515 req/s compact-value
baseline, typed collection operations improve the canonical median by **8.19%**.

## Compiler change

The IR now distinguishes statically proven `string.length`, `string.get`,
`array.length`, and `array.get` operations from dynamic `length` and
`index.get`. Source-level indexing, `.size`, loops, place projections, affine
moves, and generated array drops select typed operations when lowering already
knows the receiver type. Unknown or dynamic receivers retain the generic
runtime dispatch and its existing semantics.

Both the LLVM and generated-C backends implement the typed opcodes. The server
IR contains 888 direct typed calls and no generic length/index calls. Dynamic
calls, reflection, borrowing, ownership, raw targets, and runtime type checks
at unproven boundaries remain available.

## Hardware counters

A separate warmed run on the same CPU split measured 40,938 retired
instructions/request and 16,387 cycles/request. Relative to the compact-value
baseline, that removes **7.92% of instructions** and **12.54% of cycles**. The
HTTP executable also shrank from 446,488 to 410,648 bytes (8.0%).

## Verification

The compiler passed all 75 tests, including the generated-C differential
driver, networking, WebSockets, ownership, regions, raw/libc-free output,
compiler reflection, parser, and semantic analysis. A new regression verifies
the four direct runtime calls in LLVM IR, absence of generic dispatch for the
typed fixture, module validity, and executable behavior. The pure-Abla O2
self-rebuild produced byte-identical IR and a working native child.
