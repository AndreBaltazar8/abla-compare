# Compact dynamic-value result: 2026-08-11

Machine: Intel Core i9-13900K, Linux 6.17.3. Before the canonical run, a
10-second `/proc/stat` sample measured background utilization for every CPU.
CPU 14/15 was the quietest P-core pair at 1.2% combined utilization, while the
busy CPU 6/7 pair measured 74.8%. Every server was pinned to CPU 14, its SMT
sibling CPU 15 was excluded, and `oha` was pinned to E-cores 16-31.

The load was HTTP/1.1 keep-alive with 64 connections, a 3-second warm-up, and
three 10-second measurements. Every response passed status, content type, and
exact-body validation.

| Server | Requests/second | p50 latency | p99 latency |
| --- | ---: | ---: | ---: |
| Abla Web + event HTTP | 162,515 | 0.347 ms | 0.698 ms |
| Go `net/http` | 163,699 | 0.390 ms | 0.807 ms |
| Rust Axum/Tokio | 278,310 | 0.234 ms | 0.245 ms |

Abla reaches **99.3% of Go throughput** and **58.4% of Rust throughput** in
this routed-HTTP comparison. An isolated same-core A/B with the retained
40-byte binary measured 153,504 requests/second, so the compact ABI improves
the Abla median by **5.87%** without changing the Web implementation.

## Representation change

`AblaValue` was 40 bytes because its largest inline payload was a 32-byte
string view: data, length, allocation owner, and rope. Direct strings use data
plus an optional owner; ropes use a null data pointer plus a rope pointer. The
owner and rope are therefore mutually exclusive and now share one union slot.
`AblaString` is 24 bytes and `AblaValue` is 32 bytes on native and Wasm targets.

No payload was heap-boxed and no language feature was removed. Dynamic calls,
closures, arrays, objects, cells, ownership, reflection, regions, native
exports, C output, raw Linux output, Wasm layout, and the collector retain the
same semantics. Collector scanning now derives field, rope, and string-stride
sizes from C layouts instead of stale numeric offsets.

## Hardware counters

Separate warmed ten-second runs used the same CPU 14 / clients 16-31 split.

| Counter per request | 40-byte value | 32-byte value | Reduction |
| --- | ---: | ---: | ---: |
| Retired instructions | 46,329 | 44,460 | 4.04% |
| CPU cycles | 20,851 | 18,737 | 10.14% |

The HTTP executable shrank from 482,032 bytes to 446,488 bytes (7.4%). Arrays,
object fields, closure captures, coroutine state, roots, and compiler data also
benefit because they store dynamic values inline.

## Verification and rejected pressure experiments

The compiler passed all 75 tests, including C differential output, raw and
libc-free networking, strings and ropes, memory regions, ownership,
concurrency, WebSockets, compiler reflection, parser, and semantic analysis.
The pure-Abla O2 self-rebuild produced byte-identical LLVM IR and a working
native child.

Moving collector pressure into the allocator was rejected because collection
could occur while a runtime helper was constructing an unrooted intermediate.
Moving the existing pressure call to every allocating IR instruction preserved
correctness but regressed the isolated median to 159,909 requests/second
(-1.60%). Splitting reserve and collection work into a cold helper also failed
to overcome the weak-linked wrapper call, measuring 160,471 requests/second.
All three experiments were fully removed. A future pressure optimization needs
a backend-emitted threshold or budget fast path rather than relocating or
wrapping the current call.
