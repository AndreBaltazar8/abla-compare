# Nested JSON instruction profile and ten-round optimization

This pass investigated the remaining `json-nested` gap at the parser,
serializer, compiler, and HTTP-runtime levels. It stopped after exactly ten
measured optimization rounds. Four general JSON/runtime changes were retained,
five experiments were rejected and removed, and the final round retained one
general checked string-access inline annotation.

On the final eight-core comparison, Abla reaches **1,062,449 requests/second**:
1.7% behind Rust and 15.5% behind Zig. This is up 22.6% from Abla's previous
866,864 result. The target is not fully reached, but the previous large gap to
Rust is now effective parity at normal run variance.

## What each implementation actually uses

This is not a comparison against a hosted JSON service. JSON parsing and
serialization happen inside each benchmark server:

- Abla uses its standard `abla/json` canonical-order streaming object/array
  readers and its streaming `JsonEncoder`.
- Zig uses `httpz` at pinned commit
  `dce2cb07f1cd9beca6146869e1eec48025cf9f6f`. Its `Request.json(T)` calls Zig
  0.16's `std.json.parseFromSliceLeaky(T, request_arena, body, .{})`, and its
  response method formats the typed value with `std.json.fmt` directly into the
  response buffer.
- Rust Axum extracts `Json<NestedRequest>` and returns
  `Json<NestedResponse>`. The lockfile resolves `serde_json` 1.0.151 and
  `serde` 1.0.229.
- Go uses the standard library's `json.Decoder` into a typed struct and
  `json.Marshal` for the typed response.

The important Zig advantage is not a secret third-party parser. Its typed
standard-library parser specializes the struct traversal at compile time and
allocates borrowed/decoded values from httpz's request arena. Abla remains a
named streaming API with runtime field-name arguments, but the compact
canonical path is now reduced to bounded raw operations while retaining the
general parser as its fallback.

Every implementation parses the same 248-byte body by schema field name,
performs the same calculation, and emits the same 104-byte response. The
harness validates byte-for-byte output before every measured server run.

## Instruction and profile diagnosis

Single-P-core `perf stat` samples used 64 connections, a one-second warm-up,
and about five measured seconds. Counters were attached to all server threads.
Linux permits user-space hardware events on this machine, so these figures do
**not** include kernel instructions or cycles.

| Server/path | Instructions/request | User cycles/request | Branches/request |
| --- | ---: | ---: | ---: |
| Abla plaintext | 16.6k | 6.4k | 2.7k |
| Abla JSON before this pass | about 85.9k | about 32.0k | about 14.2k |
| **Abla JSON after round 10** | **65.3k** | **23.7k** | **10.8k** |
| Zig plaintext | 14.0k | 7.0k | 2.8k |
| Zig JSON | 112.0k | 38.1k | 24.1k |
| Rust plaintext | 27.1k | 10.9k | 4.5k |
| Rust JSON | 92.1k | 31.0k | 17.3k |

The retained Abla result cuts retired user-space instructions per JSON request
by about 24.0%. It also demonstrates why instruction count is not a throughput
ranking by itself: final Abla retires fewer measured user instructions than
Zig, yet Zig still has higher end-to-end throughput. Kernel HTTP work, syscall
shape, stalled cycles, queueing, and the different event-loop designs are not
captured by a simple `instructions:u` ratio.

The initial `perf record` profile identified concrete Abla costs rather than a
generic "JSON is slow" answer:

| Initial user-cycle share | Mapped operation |
| ---: | --- |
| 16.24% | checked generic string byte/index access |
| 6.92% | string equality |
| 6.64% | benchmark JSON handler |
| 5.97% | string slicing |
| 4.00% | `JsonObjectReader.nextExpectedRaw` |
| 3.68% | JSON number grammar validation |
| 3.41% | `JsonObjectReader.readInteger` |
| 3.16% | JSON string parser |
| 3.16% | whitespace scanning |
| 2.30% | JSON number scanner |

The dominant pattern was repeated traversal through the general string ABI,
plus duplicated scan/grammar/value passes for small integers. The ordinary
unescaped string path also inherited the large escaped Unicode decoder's stack
and code footprint.

## Exactly ten measured rounds

Short single-core runs selected candidates. Retained rounds had focused JSON
tests before the next round; rejected candidates were removed before continuing.

| Round | Experiment | Decision and measured signal |
| ---: | --- | --- |
| 1 | Bounded raw compact object-field matcher | Retained. Median 117,496 req/s; counters fell to 82.1k instructions and 13.3k branches/request. Whitespace retains the existing fallback; as before, this explicitly raw API rejects escaped spellings of field names. |
| 2 | Checked signed-64-bit integer scan and decode intrinsics | Retained. 131,564 req/s, +12.0%. Handles both signed limits and sends fractions, exponents, malformed grammar, leading zeroes, and overflow to the exact old diagnostic path. |
| 3 | Split escaped/Unicode JSON string decoder out of the common path | Retained. 134,801 req/s, +2.5%. The common function shrank from roughly 15.5 KiB to 2.5 KiB of generated code. |
| 4 | Bounded raw JSON-whitespace scanner | Retained. 139,101 req/s, +3.2%. |
| 5 | Separate object-field fallback function | Rejected. LLVM reinlined it; 139,741 req/s was within noise and generated code grew. |
| 6 | Fuse whitespace and closing-token checks | Rejected. 137,328 req/s, -1.3%. |
| 7 | General fused static encoder-field methods | Rejected. 139,430 req/s, +0.24% within noise, with duplicated encoder-state code. |
| 8 | Canonical `readExpectedInteger` API | Rejected. 139,762 req/s, +0.47% within noise. |
| 9 | Add compiler `@noinline` and isolate field fallback | Rejected. It shrank that function but regressed to 137,014 req/s (-1.5%); the feature and annotations were removed. |
| 10 | Inline the existing checked runtime string-index helper | Retained. Median 143,359 req/s, +3.1% over round 4 and +23.2% over the initial 116,377 diagnostic baseline. |

No performance change was made after round ten. A post-round correctness repair
only made `+` and `-` suffixes take the old malformed-number fallback; it does
not affect valid benchmark input.

## Final eight-core result

Conditions match the preceding weird-schema comparison:

- Intel Core i9-13900K
- server CPUs `0,2,4,6,8,10,12,14`; `oha` on CPUs `16-31`
- eight active server workers for every implementation
- HTTP/1.1 keep-alive, 256 connections
- five-second warm-up, then five 5-second samples
- release builds: Abla production optimization, stripped Go, Rust thin LTO,
  and Zig `ReleaseFast`
- Go 1.25.1, Rust 1.95.0, Zig 0.16.0, and oha 1.10.0

The eight Abla workers are pinned one per P-core. Go uses `GOMAXPROCS=8`, Rust
uses eight Tokio workers, and Zig/httpz uses two event workers plus three
handler threads per event worker, for eight active threads total.

| Server | Median req/s | Samples (req/s) | Median p50 | Median p99 |
| --- | ---: | --- | ---: | ---: |
| Zig | **1,257,276** | 1,254,353; 1,234,476; 1,257,276; 1,259,132; 1,271,070 | **0.122 ms** | 4.119 ms |
| Rust | 1,080,618 | 1,098,920; 1,040,411; 1,076,158; 1,119,236; 1,080,618 | 0.210 ms | 0.637 ms |
| **Abla** | **1,062,449** | 1,115,617; 1,105,062; 1,062,449; 990,995; 1,043,636 | 0.216 ms | **0.549 ms** |
| Go | 489,261 | 506,823; 497,990; 478,839; 489,261; 471,153 | 0.316 ms | 3.081 ms |

Abla is 1.68% behind Rust and 15.49% behind Zig. Compared with the previous
same-topology Abla result, throughput rises from 866,864 to 1,062,449 req/s,
or 22.6%. Zig retains a real throughput lead, while Abla's 0.549 ms p99 is much
lower than Zig/httpz's approximately 4.12 ms p99 in this worker configuration.

Server order is fixed by the harness, and the Abla samples show more spread
than the Zig samples, so differences of only a few percent should not be read
as permanent rankings. The Zig gap is larger than that noise; the Rust gap is
not.

## Retained general changes and safety boundaries

- The compact named-field matcher is length- and bounds-checked and accepts any
  requested raw field name. It is not tied to benchmark keys. Its surrounding
  `nextExpectedRaw` API deliberately rejects escaped spellings, while the
  ordinary `nextExpected` API continues to decode them.
- Signed integer parsing validates JSON grammar and all 64-bit bounds in one
  raw pass. Non-integer and malformed inputs still use the existing scanner,
  grammar validator, and error reporting.
- Whitespace handling remains the full JSON set: space, tab, line feed, and
  carriage return.
- The common string path remains bounded and limited by parser limits. Escapes,
  Unicode surrogate handling, controls, and precise errors remain in the old
  decoder.
- The checked string-index helper is inlined; its bounds check was not removed.
- Compile-time evaluator and self-hosted LLVM symbol mappings mirror all four
  runtime intrinsics. There is no benchmark-only compiler behavior.

No benchmark application logic changed during this pass. The improvements are
in the general Abla compiler/runtime JSON path and therefore remain available
to ordinary language users.

## Validation

- All four release servers built successfully from the final corrected source.
- The native JSON subparser test covers compact first/subsequent fields,
  whitespace fallback, escaped strings, signed 64-bit minimum and maximum, and
  malformed signed suffix diagnostics.
- The pure Abla O2 self-rebuild produced byte-identical LLVM IR.
- The first eight-job full-suite run passed 72 of 73 tests;
  `native-concurrency` encountered an illegal instruction. The isolated
  identical case immediately passed, and the complete lower-contention rerun
  passed all 73 tests with zero failures or skips.
- Both repositories pass `git diff --check`.
- Every final HTTP sample had a 100% success rate and a pre-run exact-response
  validation.
- A final Abla sweep built from the corrected compiler validated exact
  responses for all ten HTTP scenarios; its one-second timings were used only
  as a regression check, not as performance results.

Raw final HTTP measurements are in the ignored build artifact
`build/2026-08-18-json-final-ten-rounds.json`.
