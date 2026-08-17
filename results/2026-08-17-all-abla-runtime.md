# All-Abla runtime workload matrix

This run validates the compiler and web stack after removing the production C
runtime and compiling the runtime from Abla source in the same LLVM module as
the application.

## Configuration

- Machine: Intel Core i9-13900K, Linux 6.17.3
- Server: one process pinned to CPU 0
- Client: `oha` 1.10.0 pinned to CPUs 2-31
- HTTP/1.1 keep-alive, 64 connections
- 3 second warm-up, 3 × 5 second measured samples
- Abla compiler: fixed-point candidate 73, all-Abla runtime

## Results

| Scenario | Abla req/s | Go req/s | Rust req/s | Abla vs Go | Abla vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| Plaintext | 266,832 | 167,409 | 279,124 | 159.4% | 95.6% |
| Parameters | 215,555 | 155,791 | 245,093 | 138.4% | 88.0% |
| Authenticated context | 211,343 | 159,473 | 250,792 | 132.5% | 84.3% |
| 16 KiB body | 154,198 | 103,023 | 156,152 | 149.7% | 98.7% |

All responses passed the harness's byte-for-byte validation before load. The
16 KiB result represents about 2.35 GiB/s of request payload and the same
amount of response payload on one server core. Raw samples and latency
histograms are retained locally in `build/final-all-abla-runtime.json`.
