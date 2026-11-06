#!/usr/bin/env python3
"""Exact body echo on persistent HTTP/1.1 connections, through the harness preflight."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).absolute().parents[2]
sys.path.insert(0, str(ROOT))
import benchmark as b


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--server", choices=["abla", "go", "rust", "zig"], default="go")
    parser.add_argument("--server-cpu", type=int, default=8)
    parser.add_argument("--port", type=int, default=18152)
    args = parser.parse_args()
    b.prepare_payloads()
    for name in ["body-128", "body-1k", "body-16k", "body-64k"]:
        scenario = b.SCENARIOS[name]
        processes = b.start_servers(
            b.Server(args.server, args.binary.absolute()), scenario, args.port,
            1, {args.server_cpu}, True, 1, 2,
        )
        try:
            b.wait_until_ready(args.port, processes, scenario)
            print(f"{args.server}/{name}: two exact keep-alive echoes", flush=True)
        finally:
            b.stop_servers(processes)


if __name__ == "__main__":
    main()
