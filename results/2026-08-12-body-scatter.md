# Segmented 16 KiB body result, 2026-08-12

This follow-up isolates the remaining copy cost in the 16 KiB binary echo
scenario. The server receives 16 KiB and echoes 16 KiB, so every request moves
at least 32 KiB before protocol overhead. A CPU profile of the previous Abla
binary attributed about 39% of samples to `memmove` and `memset`.

The candidate receives directly into an uninitialized managed byte buffer and
uses a bounded scatter write for large rope-backed responses. It retains the
contiguous writer below 4 KiB, the existing flattening writer for exceptionally
deep ropes, `MSG_NOSIGNAL`, partial-write promotion, and raw Linux support.

## Isolated A/B

Both sides used one pinned Abla worker, 64 HTTP/1.1 keep-alive connections, a
three-second warm-up, and five ten-second samples on the same machine.

| Version | Samples (requests/second) | Median | Change |
| --- | --- | ---: | ---: |
| Previous binary | 120,061; 120,689; 120,508; 117,170; 120,876 | 120,508 | baseline |
| Segmented body path | 126,907; 127,049; 126,240; 125,864; 126,160 | 126,240 | +4.76% |

## Final holistic control

The final three-sample matrix rebuilt every server and validated every response
before measuring it.

| Scenario | Abla req/s | Go req/s | Rust req/s |
| --- | ---: | ---: | ---: |
| Plaintext | 230,209 | 166,086 | 279,956 |
| Path + query parameters | 177,272 | 155,262 | 243,526 |
| Bearer middleware + request locals | 187,226 | 159,130 | 249,861 |
| 16 KiB binary echo | 124,580 | 102,936 | 155,144 |

The lower body number in the longer matrix reflects run-order and thermal
variance; its controls moved down similarly. It still serves 21.0% more body
requests than Go and reaches 80.3% of Rust on the same run. All 75 Abla tests,
the byte-identical self-rebuild, hosted networking, advanced networking, and a
dedicated raw Linux scatter-write test pass.
