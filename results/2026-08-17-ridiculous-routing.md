# Adversarial HTTP workloads and indexed routing

This pass deliberately adds workloads that are unreasonable for a minimal
microbenchmark but plausible as stress cases for a framework. The purpose is
to expose nonlinear behavior rather than average it into the existing matrix.

## New scenarios

- `route-tail-128` registers 128 literal decoy routes before the useful dynamic
  route, then requests `/ridiculous/acct-42/orders/order-7?expand=lines`.
- `parameters-16` resolves eight path parameters and eight query parameters in
  one request.
- `headers-32` sends 32 custom headers and reads five spread across the list.

All four implementations return byte-for-byte identical bodies. The harness
checks that response before warming or measuring a server.

## Baseline: where Abla failed

The baseline used eight physical P-cores (`0,2,4,6,8,10,12,14`) for each
server and CPUs `16-31` for `oha`. Client concurrency was 256; each result is
the median of three 5-second samples after a 3-second warm-up. Abla used eight
separately pinned `SO_REUSEPORT` event loops. Go used `GOMAXPROCS=8`, Rust used
eight Tokio workers, and Zig/httpz used two event workers plus three handler
threads per event worker, for the same eight-active-worker cap.

| Scenario | Abla | Go | Rust | Zig | Abla vs Zig |
| --- | ---: | ---: | ---: | ---: | ---: |
| `route-tail-128` | **343,978** | 789,151 | 1,336,095 | 1,417,649 | **-75.7%** |
| `parameters-16` | 1,233,479 | 661,333 | 848,277 | 1,397,570 | -11.7% |
| `headers-32` | 1,048,998 | 476,215 | 826,889 | 1,084,099 | -3.2% |

The route-tail case made Abla the slowest implementation by a large margin.
Its router tested every pattern linearly, building and rejecting path-match
state 128 times before reaching the useful route. The other two scenarios are
retained as useful controls: they create pressure, but they did not reveal a
comparable structural failure.

Raw baselines are in the ignored local files
`build/2026-08-17-route-tail-128-baseline.json`,
`build/2026-08-17-parameters-16-baseline.json`, and
`build/2026-08-17-headers-32-baseline.json`.

## General router change

`httpRouter()` now builds a compact registration-time index:

- literal routes go into one of 64 fingerprint buckets;
- parameterized routes keep a separate ordered index list;
- dispatch merges the two candidate streams in original registration order;
- method filtering happens before the full path matcher;
- a fingerprint collision still runs the full matcher and therefore cannot
  select an incorrect route;
- version selection and `HEAD`-to-`GET` fallback semantics remain unchanged.

Routers with eight or fewer routes retain the old linear path, avoiding hash
overhead for the common small-router case. The old two-argument `HttpRouter`
constructor also remains valid and uses the linear compatibility path. A
route-array size change that bypasses the registration methods invalidates the
index and falls back to the same linear behavior.

## Final idle comparison

The indexed implementation was rebuilt before this run. The machine had no competing
compiler or benchmark process and a 47 °C package temperature at the start.
Conditions otherwise matched the baseline, with a 5-second warm-up and five
5-second samples.

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,424,665** | 1,424,665; 1,432,108; 1,423,047; 1,424,556; 1,436,694 | 0.116 ms | 4.107 ms |
| Zig | 1,419,150 | 1,419,671; 1,415,956; 1,430,689; 1,395,007; 1,419,150 | **0.108 ms** | 4.110 ms |
| Rust | 1,334,084 | 1,327,249; 1,325,123; 1,342,254; 1,334,084; 1,337,340 | 0.124 ms | 3.789 ms |
| Go | 791,944 | 793,920; 781,375; 792,337; 777,949; 791,944 | 0.224 ms | **1.596 ms** |

Abla improved from 343,978 to 1,424,665 requests/second, a **4.14x** result
(`+314.2%`). It is 0.39% ahead of Zig and 6.79% ahead of Rust in this run. The
Abla/Zig difference is a tie at this level of variance; the meaningful result
is that the 4.1x routing deficit is gone.

The complete final histograms and summaries are in
`build/2026-08-17-route-tail-128-final-idle.json`.

## Regression controls and rejected work

After the indexed-router change, the original Abla scenarios were rerun
with the same pinned eight P-cores, 256 connections, and three 5-second samples:

| Scenario | Abla median req/s |
| --- | ---: |
| Plaintext | 1,434,631 |
| Parameters | 1,435,878 |
| Authenticated context | 1,421,399 |
| 16 KiB body | 921,666 |

These remain within the established run bands; indexing is not used for their
small direct routes. Raw files end in `-index-regression.json` under `build/`.

Several multi-query lookup prototypes were measured and rejected with the exact
project build path. A managed batch return reached 1,168,719 requests/second, a
no-escape batch callback reached 1,116,984, and a managed parsed-query index
reached 1,177,646. Earlier 105,506 and 142,033 readings came from an invalid
direct-file build and are discarded. None of those prototypes remains in the
source. The later
[adversarial parity pass](2026-08-17-adversarial-parity.md) uses equivalent
positional access in Abla and Zig and closes the dense-parameter deficit.

## Validation

- The focused native HTTP router case covers the indexed path, versioned
  routes, method precedence, trailing slashes, duplicate parameters, and the
  old manual router constructor.
- The later validation found an unrelated nondeterministic concurrency trap:
  two serial runs each passed 71 of 72 cases, with the failure alternating
  between the two concurrency entries; both also passed isolated reruns.
- A pure self-hosted compiler rebuild produces byte-identical LLVM IR.
- All three `abla-web` checks pass.
- Abla, Go, Rust, and Zig release builds succeed, all validation responses
  match exactly, and every retained benchmark sample has a 100% success rate.
- A final exact-source smoke run still measured 1,418,969 requests/second for
  Abla versus 1,402,893 for Zig on the route-tail workload.
