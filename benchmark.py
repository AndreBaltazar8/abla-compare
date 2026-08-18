#!/usr/bin/env python3
"""Build, validate, and benchmark the equivalent HTTP servers."""

from __future__ import annotations

import argparse
import json
import math
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
BODY_16K_PATH = BUILD / "body-16k.bin"
JSON_NESTED_PATH = BUILD / "json-nested.json"


@dataclass(frozen=True)
class Scenario:
    name: str
    method: str
    target: str
    expected_body: bytes
    headers: tuple[str, ...] = ()
    body_path: Path | None = None
    expected_content_type: str = "text/plain"


BODY_16K = bytes(range(256)) * 64
JSON_NESTED = (
    b'{"request_id":"req-123","user":{"id":42,"name":"Andre","roles":'
    b'["admin","writer","reviewer"]},"items":[{"sku":"A-1","qty":2,'
    b'"price":125},{"sku":"B-2","qty":3,"price":250},{"sku":"C-3",'
    b'"qty":1,"price":500}],"active":true,"note":"weird json payload"}'
)
QUERY_32_TARGET = "/query-32?" + "&".join(
    f"field-{index:02d}=value-{index:02d}"
    for index in (19, 3, 27, 11, 31, 0, 22, 7, 14, 29, 5, 25, 9, 17, 1, 30,
                  12, 24, 6, 20, 2, 28, 15, 10, 23, 4, 18, 26, 8, 21, 13, 16)
)
RIDICULOUS_HEADERS = tuple(
    f"X-Bench-{index:02d}: v{index:02d}" for index in range(32)
)
SCENARIOS = {
    scenario.name: scenario
    for scenario in (
        Scenario("plaintext", "GET", "/plaintext", b"hello, world!\n"),
        Scenario(
            "parameters",
            "GET",
            "/accounts/acct-42/items/item-7?filter=active",
            b"acct-42:item-7:active\n",
        ),
        Scenario(
            "context",
            "GET",
            "/context",
            b"user-7:Andre:gold\n",
            ("Authorization: Bearer benchmark-token",),
        ),
        Scenario(
            "body-16k",
            "POST",
            "/body",
            BODY_16K,
            ("Content-Type: application/octet-stream",),
            BODY_16K_PATH,
            "application/octet-stream",
        ),
        Scenario(
            "route-tail-128",
            "GET",
            "/ridiculous/acct-42/orders/order-7?expand=lines",
            b"acct-42:order-7:lines\n",
        ),
        Scenario(
            "parameters-16",
            "GET",
            "/p/v0/s1/v1/s2/v2/s3/v3/s4/v4/s5/v5/s6/v6/s7/v7"
            "?q0=qv0&q1=qv1&q2=qv2&q3=qv3&q4=qv4&q5=qv5&q6=qv6&q7=qv7",
            b"v0:v1:v2:v3:v4:v5:v6:v7:qv0:qv1:qv2:qv3:qv4:qv5:qv6:qv7\n",
        ),
        Scenario(
            "headers-32",
            "GET",
            "/headers-32",
            b"v00:v07:v15:v23:v31\n",
            RIDICULOUS_HEADERS,
        ),
        Scenario(
            "route-fanout-1024",
            "GET",
            "/fanout/target",
            b"fanout-target\n",
        ),
        Scenario(
            "query-32-named",
            "GET",
            QUERY_32_TARGET,
            b"value-00:value-07:value-13:value-19:value-25:value-27:value-29:value-31\n",
        ),
        Scenario(
            "json-nested",
            "POST",
            "/json-nested",
            b'{"active":true,"item_count":3,"primary_role":"admin",'
            b'"request_id":"req-123","total":1500,"user":"Andre"}',
            ("Content-Type: application/json",),
            JSON_NESTED_PATH,
            "application/json",
        ),
    )
}


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


def find_zig() -> str:
    configured = os.environ.get("ZIG")
    executable = configured or shutil.which("zig")
    if not executable:
        raise SystemExit("zig was not found; set ZIG to a Zig 0.16.0 executable")
    return executable


def build_servers() -> list[Server]:
    BUILD.mkdir(exist_ok=True)
    BODY_16K_PATH.write_bytes(BODY_16K)
    JSON_NESTED_PATH.write_bytes(JSON_NESTED)
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
    run(
        [find_zig(), "build", "-Doptimize=ReleaseFast"],
        cwd=ROOT / "servers" / "zig",
    )
    shutil.copy2(
        ROOT / "servers" / "zig" / "zig-out" / "bin" / "abla-compare-zig",
        BUILD / "zig-server",
    )
    return [
        Server("abla", BUILD / "abla-server"),
        Server("go", BUILD / "go-server"),
        Server("rust", BUILD / "rust-server"),
        Server("zig", BUILD / "zig-server"),
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


def cpu_siblings(cpu: int, available: set[int]) -> set[int]:
    sibling_list = Path(
        f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"
    )
    if sibling_list.exists():
        return parse_cpu_list(sibling_list.read_text().strip()) & available
    return {cpu}


def default_cpu_sets(server_cpu_count: int) -> tuple[set[int], set[int]]:
    if not hasattr(os, "sched_getaffinity"):
        return set(), set()
    available = set(os.sched_getaffinity(0))
    if len(available) < 2:
        return set(), set()
    server_cpus: set[int] = set()
    reserved_siblings: set[int] = set()
    for cpu in sorted(available):
        if len(server_cpus) >= server_cpu_count:
            break
        if cpu not in reserved_siblings:
            server_cpus.add(cpu)
            reserved_siblings |= cpu_siblings(cpu, available)
    if len(server_cpus) < server_cpu_count:
        for cpu in sorted(available - server_cpus):
            if len(server_cpus) >= server_cpu_count:
                break
            server_cpus.add(cpu)
            reserved_siblings |= cpu_siblings(cpu, available)
    client_cpus = available - reserved_siblings
    if not client_cpus:
        client_cpus = available - server_cpus
    return server_cpus, client_cpus


def default_zig_worker_split(worker_limit: int) -> tuple[int, int]:
    if worker_limit == 1:
        # One event loop and two handlers was the best single-CPU configuration.
        return 1, 2
    event_workers = math.isqrt(worker_limit)
    while worker_limit % event_workers != 0:
        event_workers -= 1
    return event_workers, worker_limit // event_workers - 1


def find_oha() -> str:
    configured = os.environ.get("OHA")
    executable = configured or shutil.which("oha")
    if not executable:
        raise SystemExit(
            "oha was not found; run with: nix-shell -p oha --run 'python3 benchmark.py'"
        )
    return executable


def request_for_scenario(port: int, scenario: Scenario) -> urllib.request.Request:
    data = scenario.body_path.read_bytes() if scenario.body_path is not None else None
    headers = dict(header.split(": ", 1) for header in scenario.headers)
    if data is not None:
        headers["Content-Length"] = str(len(data))
    return urllib.request.Request(
        f"http://127.0.0.1:{port}{scenario.target}",
        data=data,
        headers=headers,
        method=scenario.method,
    )


def wait_until_ready(
    port: int,
    processes: list[subprocess.Popen[bytes]],
    scenario: Scenario,
) -> None:
    deadline = time.monotonic() + 10
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(
                    "server worker exited during startup with status "
                    f"{process.returncode}"
                )
        try:
            with urllib.request.urlopen(
                request_for_scenario(port, scenario), timeout=0.5
            ) as response:
                body = response.read()
                content_type = response.headers.get_content_type()
                if response.status != 200 or body != scenario.expected_body:
                    raise RuntimeError(
                        f"unexpected response: status={response.status}, body={body!r}"
                    )
                if content_type != scenario.expected_content_type:
                    raise RuntimeError(f"unexpected content type: {content_type}")
                return
        except (OSError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(0.05)
    raise RuntimeError(f"server did not become ready: {last_error}")


def stop_servers(processes: list[subprocess.Popen[bytes]]) -> None:
    for process in processes:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
    deadline = time.monotonic() + 3
    for process in processes:
        if process.poll() is not None:
            continue
        try:
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
    for process in processes:
        if process.poll() is None:
            process.wait(timeout=3)


def start_servers(
    server: Server,
    scenario: Scenario,
    port: int,
    workers: int,
    server_cpus: set[int],
    pin_abla_workers: bool,
    zig_event_workers: int,
    zig_handler_threads: int,
) -> list[subprocess.Popen[bytes]]:
    count = workers if server.name == "abla" else 1
    command = [str(server.executable), str(port)]
    environment = os.environ.copy()
    environment["ABLA_COMPARE_SCENARIO"] = scenario.name
    if server.name == "abla":
        command.append(scenario.name)
    elif server.name == "go":
        environment["GOMAXPROCS"] = str(workers)
    elif server.name == "rust":
        environment["TOKIO_WORKER_THREADS"] = str(workers)
    elif server.name == "zig":
        command.extend([str(zig_event_workers), str(zig_handler_threads)])
    if server.name == "abla" and count > 1:
        command.append("--reuse-port")
    ordered_server_cpus = sorted(server_cpus)
    return [
        subprocess.Popen(
            command,
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=affinity(
                {ordered_server_cpus[index % len(ordered_server_cpus)]}
                if server.name == "abla" and pin_abla_workers
                else server_cpus
            ),
            env=environment,
        )
        for index in range(count)
    ]


def oha_run(
    executable: str,
    port: int,
    duration: int,
    connections: int,
    client_cpus: set[int],
    scenario: Scenario,
) -> dict[str, Any]:
    command = [
        executable,
        "--no-tui",
        "--output-format",
        "json",
        "--http-version",
        "1.1",
        "--disable-compression",
        "--wait-ongoing-requests-after-deadline",
        "--stats-success-breakdown",
        "-z",
        f"{duration}s",
        "-c",
        str(connections),
    ]
    if scenario.method != "GET":
        command.extend(["--method", scenario.method])
    for header_value in scenario.headers:
        command.extend(["-H", header_value])
    if scenario.body_path is not None:
        command.extend(["-D", str(scenario.body_path)])
    command.append(f"http://127.0.0.1:{port}{scenario.target}")
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
        "zig": version([find_zig(), "version"]),
        "oha": version([find_oha(), "--version"]),
        "abla_compiler": str(compiler_path()),
    }


def benchmark(args: argparse.Namespace, servers: list[Server]) -> dict[str, Any]:
    executable = find_oha()
    port = args.port
    default_server_cpus, default_client_cpus = default_cpu_sets(args.workers)
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

    selected_scenarios = (
        list(SCENARIOS.values())
        if args.scenario == "all"
        else [SCENARIOS[args.scenario]]
    )
    default_zig_event_workers, default_zig_handler_threads = (
        default_zig_worker_split(args.workers)
    )
    zig_event_workers = args.zig_event_workers or default_zig_event_workers
    zig_handler_threads = args.zig_handler_threads or default_zig_handler_threads
    result: dict[str, Any] = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "configuration": {
            "scenarios": [scenario.name for scenario in selected_scenarios],
            "protocol": "HTTP/1.1 with keep-alive",
            "warmup_seconds": args.warmup,
            "measurement_seconds": args.duration,
            "connections": args.connections,
            "repetitions": args.repetitions,
            "abla_process_workers": args.workers,
            "abla_worker_affinity": (
                "one process per CPU" if args.pin_abla_workers else "shared CPU set"
            ),
            "go_gomaxprocs": args.workers,
            "rust_tokio_worker_threads": args.workers,
            "go_rust_zig_worker_model": "one process; threads inherit server affinity",
            "zig_http_server": "httpz dce2cb07f1cd9beca6146869e1eec48025cf9f6f",
            "zig_event_workers": zig_event_workers,
            "zig_handler_threads_per_event_worker": zig_handler_threads,
            "zig_active_worker_threads": zig_event_workers
            * (1 + zig_handler_threads),
            "parameters_16_access_model": (
                "Abla and Zig use positional path/query values; Go uses named "
                "path/query access; Rust uses positional path and named query access"
            ),
            "headers_32_access_model": "all implementations use header names",
            "route_fanout_1024_access_model": (
                "1,024 literal decoys followed by one literal target in every router"
            ),
            "query_32_named_access_model": (
                "all implementations parse 32 query fields and retrieve eight by name"
            ),
            "json_nested_access_model": (
                "all implementations match schema fields by name; Abla uses its "
                "canonical-order streaming reader and encoder, while Go, Rust, and "
                "Zig use typed schema decoders and serializers; the fixed compact "
                "payload order is part of this benchmark scenario"
            ),
            "server_cpus": sorted(server_cpus),
            "client_cpus": sorted(client_cpus),
        },
        "machine": machine_metadata(),
        "scenarios": {},
    }

    for scenario in selected_scenarios:
        scenario_result: dict[str, Any] = {
            "method": scenario.method,
            "target": scenario.target,
            "request_body_bytes": (
                scenario.body_path.stat().st_size
                if scenario.body_path is not None
                else 0
            ),
            "response_body_bytes": len(scenario.expected_body),
            "servers": {},
        }
        result["scenarios"][scenario.name] = scenario_result
        for server in servers:
            print(
                f"\n== {scenario.name} / {server.name}: validation and warm-up ==",
                flush=True,
            )
            processes = start_servers(
                server,
                scenario,
                port,
                args.workers,
                server_cpus,
                args.pin_abla_workers,
                zig_event_workers,
                zig_handler_threads,
            )
            try:
                wait_until_ready(port, processes, scenario)
                warmup = oha_run(
                    executable,
                    port,
                    args.warmup,
                    args.connections,
                    client_cpus,
                    scenario,
                )
                if warmup["summary"]["successRate"] != 1.0:
                    raise RuntimeError(
                        f"{scenario.name}/{server.name} warm-up had request failures"
                    )
                samples: list[dict[str, Any]] = []
                for repetition in range(1, args.repetitions + 1):
                    sample = oha_run(
                        executable,
                        port,
                        args.duration,
                        args.connections,
                        client_cpus,
                        scenario,
                    )
                    if sample["summary"]["successRate"] != 1.0:
                        raise RuntimeError(
                            f"{scenario.name}/{server.name} repetition "
                            f"{repetition} had failures"
                        )
                    samples.append(sample)
                    print(
                        f"{scenario.name}/{server.name} "
                        f"{repetition}/{args.repetitions}: "
                        f"{sample['summary']['requestsPerSec']:.0f} req/s, "
                        f"p50 {sample['latencyPercentiles']['p50'] * 1000:.3f} ms, "
                        f"p99 {sample['latencyPercentiles']['p99'] * 1000:.3f} ms",
                        flush=True,
                    )
            finally:
                stop_servers(processes)

            rates = [sample["summary"]["requestsPerSec"] for sample in samples]
            p50s = [sample["latencyPercentiles"]["p50"] for sample in samples]
            p99s = [sample["latencyPercentiles"]["p99"] for sample in samples]
            scenario_result["servers"][server.name] = {
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
    print("\nscenario     server   median req/s   median p50   median p99")
    print("------------ -------- ------------   ----------   ----------")
    for scenario_name, scenario in result["scenarios"].items():
        for server_name, server in scenario["servers"].items():
            print(
                f"{scenario_name:<12} {server_name:<8} "
                f"{server['median_requests_per_second']:>12.0f}   "
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
        "--server",
        choices=["all", "abla", "go", "rust", "zig"],
        default="all",
        help="benchmark one server or every server",
    )
    parser.add_argument(
        "--scenario",
        choices=["all", *SCENARIOS],
        default="all",
        help="benchmark one workload or the complete scenario matrix",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=1,
        help="server execution-worker limit and default server CPU count",
    )
    parser.add_argument(
        "--pin-abla-workers",
        action="store_true",
        help="pin each Abla process to one server CPU instead of sharing the set",
    )
    parser.add_argument(
        "--zig-event-workers",
        type=int,
        help="override the auto-tuned Zig httpz event-loop worker count",
    )
    parser.add_argument(
        "--zig-handler-threads",
        type=int,
        help="override Zig handler threads per event worker",
    )
    parser.add_argument(
        "--server-cpus",
        help="Linux CPU list for the server (default: --workers physical CPUs)",
    )
    parser.add_argument(
        "--client-cpus",
        help="Linux CPU list for oha (default: available CPUs excluding that core)",
    )
    parser.add_argument("--output", type=Path, default=ROOT / "results" / "latest.json")
    args = parser.parse_args()

    if args.build_only and args.skip_build:
        parser.error("--build-only and --skip-build cannot be combined")
    if min(
        args.connections,
        args.warmup,
        args.duration,
        args.repetitions,
        args.workers,
    ) <= 0:
        parser.error("connections, durations, and repetitions must be positive")
    if args.zig_event_workers is not None and args.zig_event_workers <= 0:
        parser.error("--zig-event-workers must be positive")
    if args.zig_handler_threads is not None and args.zig_handler_threads <= 0:
        parser.error("--zig-handler-threads must be positive")

    servers = build_servers() if not args.skip_build else [
        Server("abla", BUILD / "abla-server"),
        Server("go", BUILD / "go-server"),
        Server("rust", BUILD / "rust-server"),
        Server("zig", BUILD / "zig-server"),
    ]
    if args.server != "all":
        servers = [server for server in servers if server.name == args.server]
    if args.build_only:
        return 0
    for server in servers:
        if not server.executable.exists():
            raise SystemExit(f"missing {server.executable}; run without --skip-build")
    write_results(benchmark(args, servers), args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
