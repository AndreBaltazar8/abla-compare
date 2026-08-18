# Nested JSON: fifteen additional bounded rounds

This pass used the fifteen additional rounds authorized after the original ten
instruction-profile rounds and two rejected follow-ups. The objective remained
the same: approach Zig without changing JSON behavior, weakening validation, or
special-casing the benchmark payload in the compiler.

## Measurement discipline

Candidate measurements used one quiet P-core (`2`), `oha` on CPUs `16-31`, 64
connections, a two-second warm-up, and three three-second samples. The retained
round-15 baseline was 144,626 req/s; after later retained rounds the local median
reached 153,344 req/s. Small annotation-only movements were treated as noise and
removed.

The final comparison uses the same production conditions as the preceding
report: eight physical P-cores (`0,2,4,6,8,10,12,14`), one active server worker
per logical core, `oha` on CPUs `16-31`, 256 connections, a five-second warm-up,
and five five-second samples. Response bodies, status, content type, and sample
success are validated by the harness.

## Rounds 13-27

| Round | Experiment | Local median | Decision |
| ---: | --- | ---: | --- |
| 13 | Replace three plain quote/value/quote appends with one rope interpolation | 142,131 | Rejected; -0.42% versus the then-current baseline. |
| 14 | Force-inline `JsonEncoder.prepareValue` | 142,020 | Rejected; -0.50%. |
| 15 | Inline the checked runtime string-slice bridge | 144,626 | **Retained**; +1.33%. The same bounds and slice semantics remain. |
| 16 | Inline the general runtime array-append bridge | 144,253 | Rejected; no repeatable gain. |
| 17 | Inline the runtime string-length bridge | 141,429 | Rejected; -2.21%. |
| 18 | Inline the JSON whitespace wrapper | 142,726 | Rejected. |
| 19 | Inline the complete JSON string parser | 141,013 | Rejected. |
| 20 | Inline the complete JSON string writer | 140,033 | Rejected. |
| 21 | Inline `JsonArrayReader.next` | 144,507 | Rejected as neutral. |
| 22 | Skip the signed-overflow accumulation pass for integers shorter than 19 digits | 145,312, then 141,747 | **Retained as a code-path reduction, not a claimed timing win.** Nineteen-digit boundary values still execute the exact overflow check; tests cover both signed limits. |
| 23 | Inline checked runtime string equality | 147,785 | **Retained**; +2.18% over the round-15 retained baseline. |
| 24 | Test empty JSON error codes through their size instead of general string equality | 149,991 | **Retained**; +1.49%. This is semantically identical for the internal string field. |
| 25 | Fuse compact-array comma/closing/value state transitions into one raw checked intrinsic | 151,285 | **Retained**; +0.86% with tightly clustered samples. Whitespace, malformed input, and diagnostic cases fall back unchanged. |
| 26 | Fuse compact boolean literal reads | 151,353 | Rejected and fully removed; +0.04% was noise. |
| 27 | Add a pre-encoded escaped object-key token API so static schemas append `"name":` once | 153,344 | **Retained**; +1.32%. Dynamic keys and the existing encoder API remain unchanged. |

The cumulative local movement from the pre-round-13 142,734 req/s baseline to
153,344 req/s is +7.43%. It must not be interpreted as the sum of the individual
percentages because the machine baseline drifted and candidates interacted.

## Safety and language coverage

- The compact-array intrinsic returns a sentinel for every whitespace-aware or
  invalid case, preserving the old checked reader as the precise fallback.
- Static object-key tokens call the normal JSON string encoder, including UTF-8
  validation and escaping, before adding the colon.
- The regression adds compact, empty, whitespace-bearing, trailing-comma,
  integer-limit, malformed-integer, and escaped-key coverage.
- The self-hosted compiler suite passes 73/73 tests.
- A pure Abla O2 self-rebuild produces byte-identical IR and a working native
  child compiler.

## Final identical-condition result

| Server | Median req/s | Samples (req/s) | Median p50 | Median p99 |
| --- | ---: | --- | ---: | ---: |
| Zig | **1,234,811** | 1,228,861; 1,234,811; 1,228,976; 1,235,345; 1,251,086 | **0.118 ms** | 4.112 ms |
| **Abla** | **1,199,986** | 1,203,317; 1,195,682; 1,199,697; 1,201,332; 1,199,986 | 0.164 ms | 0.910 ms |
| Rust | 1,138,053 | 1,105,008; 1,138,053; 1,144,809; 1,143,478; 1,136,990 | 0.187 ms | **0.742 ms** |
| Go | 510,291 | 510,291; 517,231; 513,595; 499,481; 495,744 | 0.311 ms | 2.838 ms |

Abla reaches **97.18% of Zig throughput**, 2.82% short of parity, while
finishing 5.44% ahead of Rust. Its final median is 7.05% above the preceding
same-condition Abla result of 1,120,912 req/s. Zig retains the best median p50;
Rust has the best p99 in this run, while Abla's 0.910 ms p99 remains far below
Zig's 4.112 ms. All samples completed with 100% success and validated output.

The Zig target was therefore approached closely but not reached within the
authorized rounds. The retained gains are library/compiler improvements with
fallbacks, not relaxed parsing or a payload-specific generated response.

The ignored raw harness output is
`build/2026-08-18-json-final-twenty-seven-rounds.json`.
