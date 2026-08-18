# Weird routing, named-query, and nested-JSON comparison

This pass adds three deliberately awkward HTTP workloads, measures all four
servers under the same eight-logical-core ceiling, and limits optimization to
exactly ten measured rounds. It produced two Abla wins and one remaining gap:
Abla leads Zig and Rust on the 1,024-route fanout and 32-field named-query
workloads, while nested JSON is substantially faster than its starting point
but still behind both compiled-schema implementations.

## Workloads and access parity

- `route-fanout-1024`: 1,024 literal decoys are registered before the literal
  target in every router. The response is `fanout-target\n`.
- `query-32-named`: 32 shuffled query fields are parsed and eight spread-out
  values are retrieved by name in every implementation.
- `json-nested`: a fixed compact nested request is decoded and a derived JSON
  response is serialized. Abla uses a canonical-order named streaming reader;
  Go, Rust, and Zig use typed schema decoders. The compact field order is part
  of this benchmark contract, so this result does not claim that the Abla
  handler accepts arbitrary field order.

The harness validates the exact response before every timed run. All retained
samples had a 100% success rate.

## Conditions

- Intel Core i9-13900K
- server CPUs `0,2,4,6,8,10,12,14`; `oha` on CPUs `16-31`
- HTTP/1.1 keep-alive, 256 connections
- 5-second warm-up and five 5-second samples per server
- Abla: eight pinned `SO_REUSEPORT` event-loop processes
- Go: `GOMAXPROCS=8`
- Rust: eight Tokio workers
- Zig/httpz: two event-loop workers and three handler threads per loop, for
  eight active workers total
- release builds: Abla production optimization, stripped Go, Rust thin LTO,
  and Zig `ReleaseFast`

Tool versions were Abla from the adjacent compiler checkout, Go 1.25.1, Rust
1.95.0, Zig 0.16.0, and oha 1.10.0.

## Final results

### 1,024-route literal fanout

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,440,150** | 1,440,150; 1,441,552; 1,444,912; 1,411,635; 1,422,528 | **0.108 ms** | **4.107 ms** |
| Zig | 1,373,208 | 1,381,686; 1,353,431; 1,374,810; 1,373,208; 1,340,561 | 0.112 ms | 4.111 ms |
| Rust | 1,353,250 | 1,353,250; 1,388,215; 1,353,491; 1,314,221; 1,140,420 | 0.120 ms | 4.109 ms |
| Go | 865,405 | 868,920; 818,882; 865,405; 863,016; 871,961 | 0.205 ms | 1.365 ms |

Abla is 4.9% ahead of Zig and 6.4% ahead of Rust. The retained bounded route
fingerprint reduced the target's candidate bucket from 53 routes to four while
preserving the final exact route comparison for collision safety.

### 32 query fields, eight named reads

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,325,039** | 1,314,152; 1,325,341; 1,325,039; 1,318,348; 1,325,266 | 0.125 ms | 4.122 ms |
| Zig | 1,310,782 | 1,310,180; 1,319,557; 1,313,712; 1,310,782; 1,310,555 | **0.116 ms** | 4.118 ms |
| Rust | 716,828 | 715,927; 719,736; 716,828; 714,072; 719,071 | 0.345 ms | **0.725 ms** |
| Go | 400,511 | 410,276; 398,312; 400,511; 405,268; 398,675 | 0.357 ms | 4.057 ms |

Abla is 1.1% ahead of Zig, which is effective parity at normal run variance,
and 84.9% ahead of Rust. Every handler uses field names; this is not a
positional-access shortcut.

### Nested JSON decode, calculation, and encode

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| Zig | **1,167,059** | 1,184,907; 1,122,835; 1,167,059; 1,151,679; 1,232,163 | **0.121 ms** | 4.100 ms |
| Rust | 1,067,915 | 1,067,915; 1,085,455; 1,042,539; 1,047,446; 1,080,668 | 0.215 ms | **0.633 ms** |
| **Abla** | **866,864** | 867,263; 855,184; 854,527; 866,984; 866,864 | 0.265 ms | 0.685 ms |
| Go | 465,345 | 483,573; 458,208; 395,600; 468,607; 465,345 | 0.308 ms | 3.313 ms |

Abla improved from the initial 371,178 req/s to 866,864 req/s: a 2.34x, or
133.5%, increase. It is still 18.8% behind Rust and 25.7% behind Zig, while
remaining 86.3% ahead of Go. The ten-round cap stopped further tuning here;
this workload did not reach the parity goal and is the next honest target.

## Ten optimization rounds

| Round | Experiment | Decision and measured signal |
| ---: | --- | --- |
| 1 | Bounded DJB-style route fingerprint | Retained. One-core fanout rose from about 202,155 to 235,529 req/s (+16.5%). |
| 2 | Backward `Json.get` with length and first-byte filters | Retained. Dynamic nested JSON rose from about 46,476 to 47,851 req/s (+3.0%) on one core, preserving last-duplicate-wins. |
| 3 | Forward root scan plus reparsing nested raw values | Rejected and removed: 356,426 versus the 371,178 baseline (-4.0%). |
| 4 | Dynamic input with streaming JSON output | Retained: 375,620 req/s. |
| 5 | Shared-cursor nested object and array readers | Retained: 670,474 req/s, about +78.5% over round 4. |
| 6 | Canonical named `nextExpectedRaw` schema reader | Retained: 796,372 req/s (+18.8%). |
| 7 | Fused integer reader | Rejected and removed: 791,725 versus 796,372. |
| 8 | Compile-time validated encoded response keys | Retained: 814,607 req/s. |
| 9 | Encoded input-key wrapper | Rejected and removed: 798,071 req/s. |
| 10 | Compact fused fast path inside `nextExpectedRaw` | Retained. The short diagnostic reached 895,362 req/s; the longer final median was 866,864 req/s. |

No additional performance change was made after round ten. Short diagnostic
runs selected or rejected candidates; the final tables use the longer five by
five-second measurements and therefore remain the conservative result.

## Retained language and library changes

- HTTP literal routes use a better bounded registration/lookup fingerprint;
  exact matching remains the collision-safe authority.
- Dynamic JSON lookup searches from the end with cheap prefilters, retaining
  documented last-duplicate-wins behavior.
- Nested streaming object and array readers share parser state, validate their
  boundaries, retain whitespace-aware fallback diagnostics, and expose both
  named schema reads and ordinary traversal.
- `JsonEncoder.encodedKey(JsonEncoded)` accepts only compile-time validated
  encoded keys for static schema output.
- The compact canonical reader has a fused punctuation-and-name path but falls
  back to the general whitespace-aware parser when needed.

The rejected parser designs and fused scalar/key wrappers were removed. No
benchmark-only behavior was added to the compiler, and the general JSON and
HTTP APIs remain available.

## Regression controls and validation

- The complete self-hosted compiler suite passed: 72 passed, zero failed, zero
  skipped, including both concurrency cases and the native JSON, router, and
  networking cases.
- The pure Abla O2 self-rebuild produced byte-identical LLVM IR.
- Focused HTTP-router, JSON-subparser, runtime-JSON, and Unicode tests passed.
- New tests cover a route fingerprint collision, nested arbitrary-order
  traversal, malformed trailing arrays, whitespace fallback, and static
  encoded keys.
- All four final release servers built successfully. Python compilation and
  Go, Rust, and Zig format checks passed; both worktrees pass `git diff --check`.
- A final one-second correctness sweep validated all ten benchmark scenarios
  across all four servers without an error. It is a regression check, not a
  replacement for the longer three-scenario performance runs above.

Raw final measurements were written to
`/tmp/2026-08-18-final-{route-fanout-1024,query-32-named,json-nested}.json`.
