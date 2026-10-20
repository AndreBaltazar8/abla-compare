#!/usr/bin/env python3
"""Alternate baseline Abla, candidate Abla and Zig over validated stress cases."""
import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmark as b


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=b.BUILD / "abla-server")
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--zig", type=Path, default=b.BUILD / "zig-server")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cases", default=",".join([
        "json-nested", *b.JSON_STRESS_BODIES, *b.BODY_STRESS_BODIES]))
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--server-cpus", default="0,2,4,6,8,10,12,14")
    parser.add_argument("--client-cpus", default="16-31")
    parser.add_argument("--connections", type=int, default=256)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--duration", type=int, default=5)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--allow-baseline-validation-failures", action="store_true")
    args = parser.parse_args()
    if min(args.workers, args.connections, args.warmup, args.duration, args.repetitions) < 1:
        parser.error("counts and durations must be positive")
    cpus, client_cpus = b.parse_cpu_list(args.server_cpus), b.parse_cpu_list(args.client_cpus)
    if cpus & client_cpus:
        parser.error("server and client CPUs must not overlap")
    cases = args.cases.split(",")
    if not set(cases) <= b.SCENARIOS.keys():
        parser.error("unknown scenario")
    servers = {"baseline": args.baseline.resolve()}
    if args.candidate:
        servers["candidate"] = args.candidate.resolve()
    servers["zig"] = args.zig.resolve()
    zig_workers, zig_handlers = (1, 1) if args.workers == 1 else b.default_zig_worker_split(args.workers)
    b.prepare_payloads()
    result = dict(generated_at=datetime.now(timezone.utc).isoformat(),
                  configuration={key: str(value) if isinstance(value, Path) else value
                                 for key, value in vars(args).items()},
                  machine=b.machine_metadata(),
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest()
                                 for name, path in servers.items()},
                  server_order="forward on odd rounds, reverse on even rounds",
                  harness_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in (Path(__file__), b.ROOT / "benchmark.py")},
                  oha_worker_threads=len(client_cpus), zig_event_workers=zig_workers,
                  zig_handlers_per_event_worker=zig_handlers,
                  validation_failures=[], results=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    failed = set()
    for case in cases:
        scenario = b.SCENARIOS[case]
        for iteration in range(args.repetitions):
            # Reverse each round so every pair is measured in both orders.
            labels = list(servers)
            if iteration % 2:
                labels.reverse()
            for label in labels:
                if (case, label) in failed:
                    continue
                server = b.Server("zig" if label == "zig" else "abla", servers[label])
                processes = b.start_servers(server, scenario, args.port, args.workers,
                                            cpus, True, zig_workers, zig_handlers)
                try:
                    try:
                        b.wait_until_ready(args.port, processes, scenario)
                    except RuntimeError as error:
                        if label != "baseline" or not args.allow_baseline_validation_failures:
                            raise
                        result["validation_failures"].append(dict(scenario=case, server=label,
                                                                  error=str(error)))
                        failed.add((case, label))
                        print(f"VALIDATION FAILED {case}/{label}: {error}", flush=True)
                        save()
                        continue
                    for phase, duration in (("warmup", args.warmup), ("sample", args.duration)):
                        sample = b.oha_run(b.find_oha(), args.port, duration, args.connections,
                                           client_cpus, scenario)
                        if (sample["summary"]["successRate"] != 1 or sample["errorDistribution"]
                                or set(sample["statusCodeDistribution"]) != {"200"}):
                            raise RuntimeError(f"{case}/{label}/{phase} had failures")
                    result["results"].append(dict(scenario=case, iteration=iteration + 1,
                                                  server=label, sample=sample))
                    print(f"{case} {iteration + 1} {label}: "
                          f"{sample['summary']['requestsPerSec']:.0f} req/s, "
                          f"p99 {sample['latencyPercentiles']['p99'] * 1000:.3f} ms", flush=True)
                    save()
                finally:
                    b.stop_servers(processes)
    save()


if __name__ == "__main__":
    main()
