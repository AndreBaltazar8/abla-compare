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
route-fanout-1024  GET a literal target registered after 1,024 literal decoys
query-32-named     GET 32 shuffled query fields and retrieve eight by name
json-nested        POST a compact nested schema and serialize a derived JSON object
json-empty         JSON with empty item and role arrays
json-items-128     JSON with 128 item objects
json-roles-64      JSON with 64 role strings
json-whitespace    The nested schema with pretty-printed whitespace
json-escaped       Repeated quotes, backslashes, newlines and tabs
json-unicode       Unicode escapes, including surrogate pairs, decoded to UTF-8
json-strings-4k    A 4 KiB output string and a 4 KiB ignored string
json-int64         Signed 64-bit boundaries and a negative total
body-128          Echo a 128-byte binary body
body-1k           Echo a 1 KiB binary body
body-64k          Echo a 64 KiB binary body
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
nix-shell -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/6510408d147d8c5e6d76043e899e9251756f6a75.tar.gz -p oha zig --run 'python3 benchmark.py'
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

For candidate work, keep separate baseline and candidate Abla binaries. The
stress diagnostic reverses server order each round, validates exact responses, records
binary hashes and retains every sample:

```sh
python3 diagnostics/compare_stress.py \
  --baseline build/abla-stress-baseline --candidate build/abla-stress-candidate \
  --output results/stress.json
python3 diagnostics/test_http_streaming.py build/abla-stress-candidate
```

Run the comparison inside the pinned shell above. The diagnostic defaults to
eight server cores and 16 client CPUs on the development machine; override
`--server-cpus`, `--client-cpus`, `--workers` and `--connections` on other hosts.
Abla v0.2.19 rejects the valid `json-whitespace` request. When comparing that
baseline, `--allow-baseline-validation-failures` records its rejection without
assigning it a throughput result; candidate and Zig failures still abort.

## Fairness notes

- All servers expose byte-for-byte equivalent responses for every scenario;
  the harness validates them before load generation.
- All measurements use HTTP/1.1 keep-alive and 64 concurrent connections by default.
- The load generator's worker-thread count matches its assigned CPU count and
  is recorded as `oha_worker_threads`. `oha` otherwise defaults to the physical
  core count of the entire machine, ignoring the narrower client affinity.
  That oversubscription can inflate measured tail latency for fast servers.
  Earlier results without this field do not record that setting and may
  include client-scheduling delay; do not compare their tail-latency numbers
  directly with corrected runs.
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
- `query-32-named` uses named lookup in every implementation. The compact
  `json-nested` payload also uses JSON field names everywhere: Abla selects its
  canonical-order streaming reader, while Go, Rust, and Zig use typed schema
  decoders. The fixed field order is part of that benchmark contract; this is
  not a claim that the Abla handler accepts arbitrarily reordered JSON.
- JSON stress cases retain that schema and field order, varying only payload
  characteristics. They reuse the existing handler rather than adding
  benchmark-specific parsing shortcuts. JSON and binary echo routes accept
  bodies up to 64 KiB in the Abla benchmark server.

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
The new
[weird routing, named-query, and nested-JSON pass](results/2026-08-18-weird-schema.md)
adds strict access parity and stops after exactly ten optimization rounds. Abla
leads the 1,024-route fanout at 1,440,150 requests/second and the 32-field named
query at 1,325,039. Nested JSON improves 2.34x to 866,864 requests/second, but
honestly remains 18.8% behind Rust and 25.7% behind Zig.
The follow-up
[nested-JSON instruction profile](results/2026-08-18-json-instruction-profile.md)
inspects the exact Zig, Rust, Go, and Abla libraries and stops after a second
set of exactly ten measured rounds. General checked raw field, integer, and
whitespace paths plus a smaller common string decoder cut Abla's measured
user-space instructions per request by 24%. The final eight-core result reaches
1,062,449 requests/second: 1.7% behind Rust and 15.5% behind Zig, with a lower
p99 latency than either in that run.
Two subsequently authorized
[follow-up rounds](results/2026-08-18-json-two-more-rounds.md) tested forced
buffer-append inlining and preallocated JSON fragment storage. Both were
rejected and fully removed. A fresh same-condition run of the retained code
reached 1,120,912 requests/second, 2.7% behind Rust and 13.0% behind Zig; the
remaining Zig throughput target was not reached.
The bounded
[fifteen-round continuation](results/2026-08-18-json-fifteen-more-rounds.md)
tests reader, runtime-bridge, error-state, and serializer candidates through
round 27. It retains only behavior-preserving general changes and records the
final same-condition comparison after full compiler and JSON validation. Abla
reaches 1,199,986 requests/second, 97.18% of Zig and 5.44% ahead of Rust, while
keeping a substantially lower p99 than Zig in that run.


### Expanded JSON and body stress matrix (2026-10-20)

The [21-case results](results/2026-10-20-expanded-final.csv) compare the
v0.2.19 library with compiler commit `135feca` on branch
`perf/json-comparison`, and Zig 0.16.0/httpz. The Abla application body limit
is 64 KiB in both builds, matching Zig. This is a local candidate, not a release.
The general library changes improve escaped JSON from 357K to 1.025M req/s,
Unicode JSON from 475K to 808K, and 64 KiB echo from 65K to 306K. Zig reaches
1.089M, 804K and 165K respectively. The 64 KiB p99 drops from 8.41 to 1.47 ms
(Zig: 5.02 ms). Compact nested JSON and whitespace-heavy JSON remain behind Zig;
this does not establish language-wide superiority. The old library rejects
the valid whitespace fixture, so that baseline has no timing result.

Conditions: i9-13900K, eight physical P-cores for each server, 16 E-core client
threads, 256 connections, one-second warmup and two three-second samples.
Numbers are medians of per-run throughput and p99, not a pooled percentile.
The initial matrix always ran baseline first, then alternated candidate/Zig;
small differences can reflect order and desktop noise. The
[longer confirmation](results/2026-10-20-noinline-confirmation.csv) uses
five-second samples and fully reversed server order. In its raw JSON,
`baseline` is the retained patch and `candidate` is an out-of-line escaped-reader
experiment that was discarded because it did not close the compact-JSON gap.

[Raw measurements](results/2026-10-20-expanded-final.json),
[confirmation measurements](results/2026-10-20-noinline-confirmation.json) and
[validation/provenance](results/2026-10-20-expanded-validation.json) record
binary hashes, configuration and checks. Validation includes all 89 suite tests
(after correcting one launcher setup failure), JSON/UTF-8 Wasm checks, 84
exact-response checks across Abla/Go/Rust/Zig, a byte-identical compiler
self-rebuild, and fragmented/pipelined HTTP with a slow reader.


### Follow-up JSON gap reduction (2026-10-20)

[Final nine-case table](results/2026-10-20-gap-final.csv) compares the prior
retained patch (`135feca`) with `83b13ac`, plus Zig/httpz. The candidate removes
duplicate escaped-prefix scans, reserves short quoted strings once, avoids
intermediate cursor writes, simplifies byte-scanning loops, and inlines
the expected-field reader wrapper while keeping diagnostics out of line.

Nested JSON improves another 3.11%, to 1.461M req/s versus Zig's 1.501M
(2.64% behind). Whitespace-heavy JSON improves 4.26%, to 1.348M versus 1.445M
(6.73% behind). Escaped JSON remains 3.88% behind; int64 JSON remains 3.65%
behind. Empty and Unicode JSON are within 1% of Zig. The 128-item array
improves 10.88% over the prior patch and leads Zig by 41.88%; 4 KiB strings
improve 14.33% and lead Zig by 14.90%. All nine candidate p99 medians are
lower than Zig's in this run, though escaped JSON's p99 rose slightly versus
the prior Abla patch. These are workload results, not a language-wide claim.

Conditions: the same eight-core server budget, 16 client workers and 256
connections; two five-second samples after one-second warmup, reversing the
complete server order between rounds. Medians are computed separately for
per-run throughput and p99. Differences near 1% should be treated as parity
given the small sample count and desktop noise.

[Raw samples](results/2026-10-20-gap-final.json) include hashes and configuration.
[Validation and initial profiles](results/2026-10-20-gap-validation.json) record
89 passing suite tests, native and Wasm boundary checks, compile-time/runtime
JSON agreement, the fresh compiler fixed point, and HTTP response checks.
The compiler changes remain local on `perf/json-comparison`; no release was
published as part of this benchmark work.


### Instruction-guided JSON improvements (2026-10-20)

The next local candidate is compiler commit `8ad4a17` on
`perf/json-comparison`, measured against `83b13ac` and the same Zig binary.
Linux `perf` and symbol-resolved disassembly identified three avoidable costs:

- Successful JSON reads and writes inherited large GC-root stack frames from
  inlined diagnostic and portable fallback code. Outlining that code reduces
  the integer-reader stack allocation from 584 to 280 bytes, the string reader
  from 2,088 to 376, and the string writer from 1,016 to 360.
- Outlining region page acquisition lets LLVM inline the smaller bump-allocation
  path. Allocation semantics and collection rules are unchanged.
- HTTP response framing built temporary immutable strings and ropes. The native
  path now calculates the response size and copies headers and body into one
  allocation. The compile-time path keeps the portable formatter.

Forced field-matcher inlining and four-byte field matching did not produce a
reliable throughput gain and were discarded. Zig's whitespace scanner is scalar;
these measurements do not support attributing its advantage to SIMD. Abla still
has more object/field bookkeeping and executes more instructions per request.

The four-round confirmation puts nested JSON 1.93% ahead of Zig, escaped JSON
1.02% ahead, and int64 JSON effectively tied (+0.13%). Whitespace remains 1.45%
behind. Relative to the previous Abla patch, these cases improve 4.21–5.87%.
All four p99 medians are lower than Zig's; escaped JSON p99 rises slightly
versus the prior Abla patch (0.527 to 0.537 ms). This closes most of the observed
gap, but does not establish a statistically significant win on every case.

The regression matrix retains the array, roles, Unicode, and long-string
throughput leads over Zig. Plaintext (-0.24%) and 64 KiB body (-0.87%) throughput
are within 1% of the previous Abla build. The 128-item array improves throughput
5.70%, but its p99 rises 6% (1.265 to 1.341 ms); Zig's p99 is 2.925 ms. All eleven
candidate p99 medians are below Zig's in this run. The two-sample regression
results, especially large-body Zig throughput, should not be overgeneralized.

The [full table](results/2026-10-20-asm-final.csv) reports requests per second and
p99 for baseline Abla, candidate Abla, and Zig. The four previously trailing
cases use four eight-second samples per server; the regression cases use two
five-second samples. Both use one-second warmup, eight physical P-cores for the
server, 16 E-core load-generator workers and 256 connections, reversing server
order between rounds. Values are medians of per-run measurements; p99 is not a
pooled percentile. Small differences remain sensitive to desktop noise.

[Final samples](results/2026-10-20-asm-final.json),
[regression samples](results/2026-10-20-asm-regression.json), and
[validation and profiling evidence](results/2026-10-20-asm-validation.json)
include binary hashes and the exact configuration. `diagnostics/profile_json.py`
collects server-only user-space counters on one P-core with 64 connections,
attaching to every existing server thread. Counters and cycle samples use
separate five-second loads; start/stop windows are approximate. They exclude
kernel work and must not be treated as the eight-core throughput measurements.

Measured user-space instructions per successful request:

| Case | Previous Abla | Candidate Abla | Zig |
| --- | ---: | ---: | ---: |
| Nested | 43,062 | 38,310 | 25,718 |
| Whitespace | 51,103 | 45,722 | 27,841 |
| Escaped | 85,016 | 79,011 | 56,523 |
| Int64 | 41,781 | 37,289 | 25,133 |

These are whole HTTP-request counts, not isolated parser counts. The reduction
is 7–11%; the remaining instruction gap includes object/field and GC bookkeeping.
Branch misses were low in both implementations. Similar saturated HTTP
throughput does not mean that CPU cost per request is identical.

Validation passed: 89 suite tests, native and Wasm JSON/UTF-8 checks, GC stress
(including the JSON fixture), scoped-region and runtime-memory checks, a fresh
release-style compiler self-rebuild with byte-identical IR, all 21 exact-response
checks, and fragmented/pipelined HTTP with a slow reader. New framing assertions
cover HEAD, supplied Content-Length, case-insensitive Connection filtering, and
101 responses. The patch is committed locally; master and the installed release
remain unchanged.
