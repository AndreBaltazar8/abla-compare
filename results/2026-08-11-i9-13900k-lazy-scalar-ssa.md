# Lazy scalar SSA result: 2026-08-11

Machine: Intel Core i9-13900K, Linux 6.17.3, one pinned server CPU, separate
client CPUs. The load was HTTP/1.1 keep-alive with 64 connections, a 3-second
warm-up, and three 10-second measurements. Values below are medians. The
harness validated HTTP 200, the content type, and the exact response body
before load, and every measured request succeeded.

| Server | Requests/second | p50 latency | p99 latency |
| --- | ---: | ---: | ---: |
| Abla Web + event HTTP | 152,868 | 0.379 ms | 0.734 ms |
| Go `net/http` | 160,139 | 0.399 ms | 0.839 ms |
| Rust Axum/Tokio | 276,784 | 0.233 ms | 0.249 ms |

Toolchains: Abla compiler commit `6dafa2a`, Abla Web commit `3d836b9`, Go
1.25.1, Rust 1.95.0, Axum 0.8.9, Tokio 1.53.1, and oha 1.10.0.

Abla reaches **95.5% of Go throughput** and **55.2% of Rust throughput** in
this practical routed-HTTP comparison. Against the preceding canonical
144,573 req/s checked-region result, lazy scalar SSA improves throughput by
**5.74%**. The cumulative gain over the 111,030 req/s native direct-call
baseline is **37.7%**.

## Compiler change

The LLVM backend now performs a conservative scalar analysis before allocating
function storage. It proves `i64` and `bool` values produced by constants,
typed parameter loads, direct scalar calls, compatible native calls,
arithmetic, boolean operations, and homogeneous comparisons. A local qualifies
only when every declaration, assignment, and control-flow store proves the
same scalar type.

Proven values are represented directly by LLVM integers. Scalar locals use
entry-block native allocas, which LLVM promotes into registers and PHI nodes.
No `AblaValue` slot is created unless an actual use crosses a dynamic,
aggregate, capture, indirect-call, or other boxed boundary. On that boundary
the value is boxed once; the generic callable, export, reflection, and runtime
ABIs remain unchanged.

The pass intentionally leaves division, shifts, heterogeneous equality,
aggregate access, and unproven locals on the established boxed runtime paths.
Those operations need additional semantic guards or richer typed IR before
native lowering is safe.

## Isolated evidence

A five-sample baseline/candidate comparison measured 143,955 req/s for the
checked-region binary and 152,141 req/s for the lazy-SSA binary, a **5.69%**
gain. A separate ten-second hardware-counter run measured:

| Counter per request | Region baseline | Lazy scalar SSA | Reduction |
| --- | ---: | ---: | ---: |
| Retired instructions | 49,678 | 46,376 | 6.65% |
| CPU cycles | 23,114 | 20,597 | 10.9% |

The HTTP executable also shrank from 552,552 bytes to 482,032 bytes, a 12.8%
reduction. These counters and size changes confirm that the throughput gain
comes from removing generated value work rather than benchmark variance.

Native scalar parameter storage was tested separately. It reduced the binary
by another 9 KiB, but the missing/default-argument control flow lowered the
three-run median from 153,807 to 152,681 req/s and slightly increased latency.
That experiment was removed.

## Verification

The compiler passed all 75 tests, including the new LLVM-shape regression,
the generated-C differential driver, concurrency, networking, WebSockets,
regions, native ABI, ownership, and parser/sema coverage. The regression
verifies native `add i64`, scalar local storage, LLVM module validity, preserved
boxed indirect dispatch, and executable behavior.

The pure-Abla O2 self-rebuild produced byte-identical compiler IR and a working
native child. All nine canonical cross-language benchmark samples completed
with a 100% success rate. The complete raw oha output and machine metadata are
stored beside this report.
