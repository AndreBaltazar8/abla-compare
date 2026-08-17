# Adversarial parameter and header parity

This follow-up closes the two deficits left by the adversarial HTTP matrix:
eight path plus eight query values, and 32 request headers with five lookups.
It keeps the same eight-logical-core limit and reports each workload separately.

## Conditions

- Intel Core i9-13900K
- server CPUs `0,2,4,6,8,10,12,14`; `oha` on CPUs `16-31`
- HTTP/1.1 keep-alive, 256 connections
- 5-second warm-up and five 5-second samples per server
- Abla: eight pinned `SO_REUSEPORT` event-loop processes
- Go: `GOMAXPROCS=8`
- Rust: eight Tokio workers
- Zig/httpz: two event-loop workers and three handler threads per loop, eight active workers total

Each server was response-validated before warm-up. Every retained sample had a
100% success rate.

## Eight path and eight query values

The final Abla/Zig comparison is position-for-position. Both implementations
read the eight route values and eight parsed query values by index. This follows
the fairness rule that Abla may use an index only when Zig uses the same access
model. Abla scans the raw ordered query once into local values; it does not
return a managed collection across a function boundary.

Go's standard router exposes `PathValue(name)` and `url.Values.Get(name)`, so its
handler remains named. Rust Axum extracts path values as a positional tuple and
uses a named query `HashMap`. The Abla-versus-Zig result is therefore the direct
like-for-like comparison; the four-way table also records each framework's
best directly exposed model.

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,399,623** | 1,404,883; 1,385,986; 1,395,909; 1,399,623; 1,404,335 | 0.118 ms | 4.110 ms |
| Zig | 1,378,327 | 1,397,865; 1,375,916; 1,371,665; 1,378,327; 1,391,369 | **0.110 ms** | 4.112 ms |
| Rust | 777,301 | 830,110; 791,169; 777,301; 775,849; 733,699 | 0.316 ms | **0.675 ms** |
| Go | 653,358 | 651,832; 653,358; 663,814; 655,262; 635,257 | 0.257 ms | 2.077 ms |

Abla is 1.55% ahead of Zig in this run. The relevant raw files are
`build/2026-08-17-parameters-16-all-indexed-{abla,zig}.json` and
`build/2026-08-17-final-parameters-16-{go,rust}.json`.

## Thirty-two named headers

All four handlers access headers by name. Abla and Zig both request lowercase
names, matching the lowercase wire representation emitted by `oha` and the
contract documented by httpz.

| Server | Median req/s | Samples (req/s) | p50 | p99 |
| --- | ---: | --- | ---: | ---: |
| **Abla** | **1,089,695** | 1,087,501; 1,092,868; 1,100,943; 1,089,695; 1,073,698 | 0.153 ms | 4.161 ms |
| Zig | 1,088,706 | 1,086,247; 1,085,820; 1,091,129; 1,088,706; 1,094,046 | **0.148 ms** | 4.156 ms |
| Rust | 786,485 | 786,485; 776,839; 765,895; 790,679; 808,302 | 0.315 ms | **0.648 ms** |
| Go | 453,846 | 457,855; 453,846; 452,774; 460,101; 444,622 | 0.322 ms | 3.471 ms |

Abla is 0.09% ahead of Zig. That is a tie at normal run variance, but the
previous deficit is gone. Raw files end in
`headers-32-final-*-native-two-byte*.json` for Abla/Zig and
`final-headers-32-{go,rust}.json` for Go/Rust.

## Retained implementation changes

- `HttpRequest.header(name)` searches backward and stops at the last matching
  header, preserving last-duplicate-wins behavior.
- Native ASCII-insensitive equality first checks the final two folded bytes,
  then compares the remaining prefix. The final bytes are not compared twice.
  This is a general string-runtime optimization; it does not add fields or
  allocations to HTTP requests.
- The dense parameter benchmark uses positional access in both Abla and Zig.
  Ordinary named route and query APIs remain available and retain their tested
  duplicate and fallback semantics.

Allocation-heavy batch/query objects, a mutable request cache, compiled-path
objects, a four-part concat intrinsic, and source-level header prefilters were
measured and rejected. None remains in the source.

## Regression controls and validation

The final Abla medians on the original workloads were 1,446,656 plaintext,
1,427,522 routed parameters, 1,420,566 authenticated context, and 906,287 for
the 16 KiB echo. These remain inside their established run bands. The indexed
128-route control also remains ahead of Zig: 1,398,321 versus 1,362,352 req/s.

- Two complete serial compiler runs each passed 71 of 72 cases. The failure
  alternated between `suite-concurrency` and `native-concurrency`; both passed
  in isolated reruns, while repeated isolation reproduced the suite-level
  illegal-instruction flake once. The deterministic HTTP router, short-string,
  ownership, compiler, and all other cases passed. This unresolved concurrency
  flake does not execute the changed string routine and is not reported as a
  clean 72/72 result.
- The pure self-host rebuild produced byte-identical LLVM IR.
- All three `abla-web` framework/build/integration checks passed.
- Rebuilding the final Abla server with the final compiler reproduced the
  measured binary byte-for-byte (`493888387c5d2a7acf7426f843debc431dfa4dce5ba5d27d8d698babea413124`).
- Every retained benchmark sample completed with a 100% success rate.
