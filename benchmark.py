#!/usr/bin/env python3
"""Build, validate, and benchmark the three equivalent HTTP servers."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
EXPECTED_BODY = b"hello, world!\n"


@dataclass(frozen=True)
class Server:
    name: str
    executable: Path


def run(command: list[str], *, cwd: Path = ROOT, capture: bool = False) -> str:
    print("+", " ".join(str(part) for part in command), flush=True)
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    return completed.stdout.strip() if completed.stdout else ""


def compiler_path() -> Path:
    configured = os.environ.get("ABLAC")
    if configured:
        return Path(configured).expanduser().absolute()
    # Do not resolve this symlink: the guarded launcher deliberately finds its
    # sibling payload from argv[0] (build/ablac.bin).
    return (ROOT.parent / "ablac" / "build" / "ablac").absolute()


def build_servers() -> list[Server]:
    BUILD.mkdir(exist_ok=True)
    compiler = compiler_path()
    if not compiler.exists():
        raise SystemExit(f"Abla compiler not found at {compiler}; set ABLAC to override")

    run([
        str(compiler),
        "build",
        "--project",
        str(ROOT),
        "--offline",
        "--no-cache",
        "-o",
        str(BUILD / "abla-server"),
    ])
    run([
        "go",
        "build",
        "-trimpath",
        "-ldflags=-s -w",
        "-o",
        str(BUILD / "go-server"),
        ".",
    ], cwd=ROOT / "servers" / "go")
    run(["cargo", "build", "--release", "--locked"], cwd=ROOT / "servers" / "rust")
    shutil.copy2(
        ROOT / "servers" / "rust" / "target" / "release" / "abla-compare-rust",
        BUILD / "rust-server",
    )
    return [
        Server("abla", BUILD / "abla-server"),
        Server("go", BUILD / "go-server"),
        Server("rust", BUILD / "rust-server"),
    ]


def parse_cpu_list(value: str) -> set[int]:
    cpus: set[int] = set()
    for part in value.split(","):
        bounds = part.strip().split("-", 1)
        if len(bounds) == 1:
            cpus.add(int(bounds[0]))
        else:
            cpus.update(range(int(bounds[0]), int(bounds[1]) + 1))
    return cpus


def affinity(cpus: set[int]) -> Callable[[], None] | None:
    if not cpus or not hasattr(os, "sched_setaffinity"):
        return None

    def apply() -> None:
        os.sched_setaffinity(0, cpus)

    return apply


def default_cpu_sets() -> tuple[set[int], set[int]]:
    if not hasattr(os, "sched_getaffinity"):
        return set(), set()
    available = set(os.sched_getaffinity(0))
    if len(available) < 2:
        return set(), set()
    server_cpu = min(available)
    siblings = {server_cpu}
    sibling_list = Path(
        f"/sys/devices/system/cpu/cpu{server_cpu}/topology/thread_siblings_list"
    )
    if sibling_list.exists():
        siblings = parse_cpu_list(sibling_list.read_text().strip()) & available
    client_cpus = available - siblings
    if not client_cpus:
        client_cpus = available - {server_cpu}
    return {server_cpu}, client_cpus


def find_oha() -> str:
    configured = os.environ.get("OHA")
    executable = configured or shutil.which("oha")
    if not executable:
        raise SystemExit(
            "oha was not found; run with: nix-shell -p oha --run 'python3 benchmark.py'"
        )
    return executable


def wait_until_ready(port: int, process: subprocess.Popen[bytes]) -> None:
    endpoint = f"http://127.0.0.1:{port}/plaintext"
    deadline = time.monotonic() + 10
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited during startup with status {process.returncode}")
        try:
            with urllib.request.urlopen(endpoint, timeout=0.5) as response:
                body = response.read()
                content_type = response.headers.get_content_type()
                if response.status != 200 or body != EXPECTED_BODY:
                    raise RuntimeError(
                        f"unexpected response: status={response.status}, body={body!r}"
                    )
                if content_type != "text/plain":
                    raise RuntimeError(f"unexpected content type: {content_type}")
                return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(0.05)
    raise RuntimeError(f"server did not become ready: {last_error}")


def stop_server(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def oha_run(
    executable: str,
    port: int,
    duration: int,
    connections: int,
    client_cpus: set[int],
) -> dict[str, Any]:
    command = [
        executable,
        "--no-tui",
        "--output-format",
        "json",
        "--http-version",
        "1.1",
        "--wait-ongoing-requests-after-deadline",
        "-z",
        f"{duration}s",
        "-c",
        str(connections),
        f"http://127.0.0.1:{port}/plaintext",
    ]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=affinity(client_cpus),
    )
    return json.loads(completed.stdout)


def version(command: list[str]) -> str:
    try:
        return run(command, capture=True).splitlines()[0]
    except (OSError, subprocess.CalledProcessError):
        return "unavailable"


def machine_metadata() -> dict[str, Any]:
    cpu_model = "unknown"
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        for line in cpuinfo.read_text().splitlines():
            if line.startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip()
                break
    return {
        "platform": platform.platform(),
        "cpu": cpu_model,
        "logical_cpus": os.cpu_count(),
        "python": platform.python_version(),
        "go": version(["go", "version"]),
        "rust": version(["rustc", "--version"]),
        "cargo": version(["cargo", "--version"]),
        "oha": version([find_oha(), "--version"]),
        "abla_compiler": str(compiler_path()),
    }


def benchmark(args: argparse.Namespace, servers: list[Server]) -> dict[str, Any]:
    executable = find_oha()
    port = args.port
    default_server_cpus, default_client_cpus = default_cpu_sets()
    server_cpus = (
        parse_cpu_list(args.server_cpus)
        if args.server_cpus
        else default_server_cpus
    )
    client_cpus = (
        parse_cpu_list(args.client_cpus)
        if args.client_cpus
        else default_client_cpus
    )
    if server_cpus & client_cpus:
        raise SystemExit("server and client CPU sets must not overlap")

    result: dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "configuration": {
            "endpoint": "/plaintext",
            "protocol": "HTTP/1.1 with keep-alive",
            "response_body_bytes": len(EXPECTED_BODY),
            "warmup_seconds": args.warmup,
            "measurement_seconds": args.duration,
            "connections": args.connections,
            "repetitions": args.repetitions,
            "server_cpus": sorted(server_cpus),
            "client_cpus": sorted(client_cpus),
        },
        "machine": machine_metadata(),
        "servers": {},
    }

    for server in servers:
        print(f"\n== {server.name}: validation and warm-up ==", flush=True)
        process = subprocess.Popen(
            [str(server.executable), str(port)],
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=affinity(server_cpus),
        )
        try:
            wait_until_ready(port, process)
            warmup = oha_run(executable, port, args.warmup, args.connections, client_cpus)
            if warmup["summary"]["successRate"] != 1.0:
                raise RuntimeError(f"{server.name} warm-up had request failures")
            samples: list[dict[str, Any]] = []
            for repetition in range(1, args.repetitions + 1):
                sample = oha_run(
                    executable, port, args.duration, args.connections, client_cpus
                )
                if sample["summary"]["successRate"] != 1.0:
                    raise RuntimeError(f"{server.name} repetition {repetition} had failures")
                samples.append(sample)
                print(
                    f"{server.name} {repetition}/{args.repetitions}: "
                    f"{sample['summary']['requestsPerSec']:.0f} req/s, "
                    f"p50 {sample['latencyPercentiles']['p50'] * 1000:.3f} ms, "
                    f"p99 {sample['latencyPercentiles']['p99'] * 1000:.3f} ms",
                    flush=True,
                )
        finally:
            stop_server(process)

        rates = [sample["summary"]["requestsPerSec"] for sample in samples]
        p50s = [sample["latencyPercentiles"]["p50"] for sample in samples]
        p99s = [sample["latencyPercentiles"]["p99"] for sample in samples]
        result["servers"][server.name] = {
            "median_requests_per_second": statistics.median(rates),
            "median_p50_seconds": statistics.median(p50s),
            "median_p99_seconds": statistics.median(p99s),
            "samples": samples,
        }
    return result


def write_results(result: dict[str, Any], destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + "\n")
    print(f"\nWrote raw results to {destination}")
    print("\nserver   median req/s   median p50   median p99")
    print("------   ------------   ----------   ----------")
    for name, server in result["servers"].items():
        print(
            f"{name:<8} {server['median_requests_per_second']:>12.0f}   "
            f"{server['median_p50_seconds'] * 1000:>8.3f} ms   "
            f"{server['median_p99_seconds'] * 1000:>8.3f} ms"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--connections", type=int, default=64)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--duration", type=int, default=10)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument(
        "--server-cpus",
        help="Linux CPU list for the server (default: one available physical CPU)",
    )
    parser.add_argument(
        "--client-cpus",
        help="Linux CPU list for oha (default: available CPUs excluding that core)",
    )
    parser.add_argument("--output", type=Path, default=ROOT / "results" / "latest.json")
    args = parser.parse_args()

    if args.build_only and args.skip_build:
        parser.error("--build-only and --skip-build cannot be combined")
    if min(args.connections, args.warmup, args.duration, args.repetitions) <= 0:
        parser.error("connections, durations, and repetitions must be positive")

    servers = build_servers() if not args.skip_build else [
        Server("abla", BUILD / "abla-server"),
        Server("go", BUILD / "go-server"),
        Server("rust", BUILD / "rust-server"),
    ]
    if args.build_only:
        return 0
    for server in servers:
        if not server.executable.exists():
            raise SystemExit(f"missing {server.executable}; run without --skip-build")
    write_results(benchmark(args, servers), args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
