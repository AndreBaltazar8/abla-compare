# Inferred non-retention workload matrix: 2026-08-12

This run validates compiler-inferred callback non-retention through a real Abla
Web application. Its route handlers, authentication callback, and HTTP handler
lambda are ordinary Abla functions: the application contains no explicit
`noescape` declarations.

## Configuration

- Intel Core i9-13900K, Linux
- server pinned to P-core CPU 2; its SMT sibling CPU 3 excluded
- `oha` pinned to CPUs 0-1 and 4-31
- HTTP/1.1 keep-alive, 64 connections
- 3-second warm-up followed by three 10-second samples per server and scenario
- release builds; exact status, headers, and bodies validated before timing
- raw samples: `2026-08-12-inferred-noescape.json`

## Results

| Scenario | Abla | Go | Rust | Abla vs Go |
| --- | ---: | ---: | ---: | ---: |
| Plaintext | **218,886** | 167,866 | 262,023 | **130.4%** |
| Path and query parameters | **179,657** | 156,592 | 244,677 | **114.7%** |
| Bearer middleware and typed request locals | **191,089** | 159,695 | 252,167 | **119.7%** |
| 16 KiB binary echo | **117,544** | 103,443 | 155,908 | **113.6%** |

Values are median requests/second. Abla exceeded the paired Go implementation
in all four workloads without weakening route semantics, response validation,
or callback-retention checks.

The context gain comes from request-scoped middleware and an immutable typed
local chain, plus native strict UTF-8 validation. The body gain comes from a
bounded 32 KiB compact receive path that normally consumes headers and a 16 KiB
body in one receive, and from avoiding a redundant string promotion when no
allocation region is active.

A separate 45-second authenticated-context load sustained 190,846 requests per
second with a 100% success rate. Sampled RSS stayed within 141,824-141,872 KiB
between 20 and 73 seconds of server lifetime, showing no sustained-growth trend.

## Integrity

The corresponding compiler/runtime passed all 75 conformance suites, including
both compiler backends, network/WebSocket coverage, focused UTF-8 and inferred
non-retention tests, and byte-identical optimized self-rebuild. Negative tests
confirm that callbacks which call opaque retaining externs or store parameters
directly or through local aliases cannot satisfy a scoped callback boundary.
