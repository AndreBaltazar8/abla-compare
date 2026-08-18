# Nested JSON: two authorized follow-up rounds

This follow-up used the two additional optimization rounds authorized after the
ten-round instruction-profile pass. Neither candidate produced a repeatable
gain, so both were removed. The final source is therefore exactly the retained
round-10 implementation, with no new language or library behavior.

## Post-round-10 profile

A fresh single-P-core `perf record` run confirmed that Abla's remaining JSON
cost is spread across the handler, canonical field reads, string equality and
slicing, integer reads, array iteration, and the fragment-based JSON encoder.
The encoder's `ByteBuffer.appendText` boundary accounted for 5.7% of sampled
user cycles, but that symbol includes underlying chunk-array work rather than
only call overhead.

The same run reached 142,438 req/s while profiling. An unprofiled three-sample
baseline immediately before round 11 was 142,734 req/s.

## Rounds 11 and 12

| Round | Experiment | Result |
| ---: | --- | --- |
| 11 | Force-inline the general `ByteBuffer.appendText` method | **Rejected and removed.** Median 143,008 versus 142,734 req/s, only +0.19% and inside run noise. The array append and fragment bookkeeping remained. |
| 12 | Add a checked string-array capacity intrinsic and start `JsonEncoder` with room for 32 fragments | **Rejected and removed.** Median 141,254 req/s, -1.04%. Avoiding array growth did not repay the up-front 768-byte allocation. The intrinsic, evaluator support, runtime bridge, API, and encoder use were all removed. |

No performance change was retained after round 10. Round 12 required an
ordinary two-stage self-host bootstrap while testing the new intrinsic; after
rejection, the compiler and all four servers were rebuilt from the restored
source.

## Final identical-condition rerun

- Intel Core i9-13900K
- server CPUs `0,2,4,6,8,10,12,14`; `oha` on CPUs `16-31`
- eight active workers for each server
- HTTP/1.1 keep-alive, 256 connections
- five-second warm-up and five 5-second samples
- byte-for-byte response validation and 100% sample success

| Server | Median req/s | Samples (req/s) | Median p50 | Median p99 |
| --- | ---: | --- | ---: | ---: |
| Zig | **1,288,797** | 1,270,200; 1,288,797; 1,291,806; 1,302,777; 1,277,030 | **0.123 ms** | 4.119 ms |
| Rust | 1,151,941 | 1,156,124; 1,147,332; 1,153,853; 1,151,941; 1,143,325 | 0.179 ms | 0.820 ms |
| **Abla** | **1,120,912** | 1,121,469; 1,119,665; 1,120,912; 1,113,153; 1,122,502 | 0.203 ms | **0.521 ms** |
| Go | 516,089 | 511,658; 516,089; 523,766; 515,400; 518,511 | 0.319 ms | 2.640 ms |

Abla remains 2.69% behind Rust and 13.02% behind Zig in throughput. It retains
the lowest p99 latency in this run. The higher absolute rates than the prior
final run occurred with the same retained code and must be treated as run
conditions, not as an optimization gain.

The two-round target of Zig throughput was not reached. The evidence now points
away from small annotations and capacity guesses: closing the remaining gap
likely needs an architectural contiguous JSON output buffer or HTTP scheduling
work, each deserving its own regression and memory investigation rather than a
third unmeasured tweak.

Raw results are in the ignored build artifact
`build/2026-08-18-json-final-twelve-rounds.json`.
