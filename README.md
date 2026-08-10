# Abla, Go, and Rust HTTP comparison

This repository measures the same small routed HTTP/1.1 service implemented
with Abla Web, Go `net/http`, and Rust Axum. Each server exposes:

```text
GET /plaintext
Content-Type: text/plain; charset=utf-8

hello, world!
```

The goal is a repeatable engineering baseline, not a universal language
ranking. It measures a practical router and HTTP stack on one machine. Database
calls, TLS, JSON, logging, and application work require separate benchmarks.

## Run it

The harness builds release binaries, verifies every response, warms each server,
then runs three timed measurements with the same `oha` client settings. On Linux
it pins the server to one CPU and the load generator to separate CPUs.

```sh
nix-shell -p oha --run 'python3 benchmark.py'
```

Raw results are written to `results/latest.json` (ignored by Git). Useful knobs:

```sh
python3 benchmark.py --connections 64 --duration 10 --repetitions 3
python3 benchmark.py --skip-build --server-cpus 2 --client-cpus 8-31
```

The defaults assume this repository is beside `../ablac`. Set `ABLAC` to use a
different compiler and `OHA` to use a specific load-generator binary.

## Fairness notes

- All servers use one routed `GET` endpoint and an identical 14-byte body.
- All measurements use HTTP/1.1 keep-alive and 64 concurrent connections.
- Release builds are used: Abla's production optimization pipeline, stripped Go,
  and Rust `--release` with thin LTO.
- The Abla service calls `memorySetLimit(memoryLimit())`, which selects its
  managed collector and automatic memory-pressure safe points. Abla otherwise
  strips the collector for short-lived programs that do not use the memory API.
- The primary result is single-CPU throughput. Go and Rust can scale over more
  worker threads; Abla's current event server is single-threaded.
- Server order is fixed, so rerun the suite and inspect the individual samples
  before treating small differences as meaningful.

## Layout

- `servers/abla`: Abla Web and the Abla event HTTP server
- `servers/go`: Go standard-library HTTP server
- `servers/rust`: Axum on Tokio
- `benchmark.py`: build, validation, CPU isolation, measurements, and JSON output

## Current baseline

The first controlled run is recorded in
[`results/2026-08-10-i9-13900k.md`](results/2026-08-10-i9-13900k.md). It found
that the present Abla managed-memory HTTP path is not yet competitive or ready
for sustained high-throughput service work. The committed benchmark is meant to
turn that limitation into a measurable optimization target.
