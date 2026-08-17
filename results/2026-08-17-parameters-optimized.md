# Routed-parameters optimization

This follow-up targets the only eight-worker workload where Abla had trailed
Zig: `GET /accounts/:account/items/:item?filter=active`. The retained changes
are general HTTP routing and query-lookup improvements in `ablac`; there is no
benchmark-specific route parser and no compiler ABI change.

## Final idle comparison

The final run started with no competing compiler or benchmark process and a
46 °C CPU package temperature. Each implementation used the same eight physical
P-cores (`0,2,4,6,8,10,12,14`), while `oha` used CPUs `16-31`.

- Protocol: HTTP/1.1 keep-alive
- Client concurrency: 256
- Warm-up: 5 seconds per server
- Samples: 5 x 5 seconds per server
- Abla: 8 `SO_REUSEPORT` event-loop processes, one pinned to each P-core
- Go: `GOMAXPROCS=8`
- Rust: 8 Tokio workers
- Zig: 2 `httpz` event-loop workers and 3 handler threads per event loop,
  for 8 active workers

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,431,005** | 1,425,373; 1,435,917; 1,431,005; 1,433,403; 1,403,072 | 0.110 ms | 4.107 ms |
| Zig | 1,404,742 | 1,404,742; 1,402,210; 1,428,029; 1,425,494; 1,369,287 | **0.108 ms** | 4.110 ms |
| Rust | 1,298,386 | 1,296,611; 1,298,386; 1,250,446; 1,335,727; 1,352,102 | 0.129 ms | **2.484 ms** |
| Go | 769,911 | 766,064; 769,911; 752,824; 776,438; 770,166 | 0.226 ms | 1.704 ms |

Abla is 1.87% ahead of Zig and 10.21% ahead of Rust in this run. Relative to
the previous Abla median of 1,352,675 req/s, the retained implementation is
5.79% faster. The Zig gap is real in this controlled run but still small enough
that it should be verified again on other machines rather than treated as a
universal language ranking.

The complete `oha` summaries and histograms are in the ignored local raw file
`build/2026-08-17-parameters-final-idle.json`.

## What changed

The old path matcher split both the route pattern and request path into arrays,
allocated a string slice for every segment, and then compared the two arrays.
The new matcher walks the pattern and path together:

- `textFindByte` locates the next slash in each string;
- static segments are compared directly by byte range, without slicing;
- only actual parameter names and values become strings;
- segment-count and trailing-slash behavior is checked during the same pass.

`HttpRequest.parameter` now searches route parameters from the end and stops on
a match, which preserves the established last-route-value behavior. Empty route
values correctly retain precedence over query values. Query parsing uses the
same optimized delimiter search and compares the key as a byte range, avoiding
a temporary key slice. Its prior first-non-empty duplicate-query behavior is
covered and preserved.

The benchmark harness also gained `--pin-abla-workers`. With eight independent
Abla processes, this binds one event loop to each selected CPU and avoids
process migration while keeping the same eight-core resource limit. The option
is recorded in raw-result metadata and is not applied to single-worker runs.

## Other workloads

A five-sample full matrix was run before the final idle parameters pass. It used
the same optimized hot path and core sets, but shared Abla's CPU affinity rather
than pinning each process separately.

| Scenario | Previous Abla | Optimized Abla | Change |
| --- | ---: | ---: | ---: |
| Plaintext | 1,441,660 | 1,449,715 | +0.56% |
| Parameters | 1,352,675 | 1,431,587 | +5.83% |
| Authenticated context | 1,394,653 | 1,375,778 | -1.35% |
| 16 KiB body | 910,667 | 913,891 | +0.35% |

Plaintext and body improved slightly even though neither executes the changed
parameter lookup. Context's 1.35% decrease is within the run-to-run variance
seen across all four servers; no context code was changed. Raw data is retained
in `build/2026-08-17-route-optimized-all.json`.

## Validation and rejected experiments

- The focused native HTTP router test covers middle query fields, empty route
  values, duplicate route names, duplicate query names, and trailing slashes.
- The complete compiler conformance suite passes serially, including the native
  HTTP router and concurrency tests.
- The self-hosted compiler rebuild produces byte-identical LLVM IR.
- All three `abla-web` framework/build/integration programs return their
  expected status.
- Every benchmark response passed byte-for-byte validation, and every measured
  sample completed with a 100% success rate.

A compiler-wide scalar string-slice ABI and forced inlining were benchmarked but
not retained. Their gains were small, they affected much more code than the HTTP
hot path, and the route/query changes achieved the target without broadening the
language ABI.
