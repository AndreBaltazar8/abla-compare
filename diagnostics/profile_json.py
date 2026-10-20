#!/usr/bin/env python3
"""Measure server-only user-space counters and resolve Abla profile symbols."""
import argparse
import hashlib
import json
import re
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmark as b


def measured_load(perf, command, scenario):
    process = subprocess.Popen([str(perf), *command], stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE)
    try:
        sample = b.oha_run(b.find_oha(), 18080, 5, 64, set(range(16, 32)), scenario)
    finally:
        process.send_signal(signal.SIGINT)
        _, error = process.communicate(timeout=10)
    if process.returncode not in (0, 130, -signal.SIGINT):
        raise RuntimeError(error.decode())
    if (sample['summary']['successRate'] != 1 or sample['errorDistribution']
            or set(sample['statusCodeDistribution']) != {'200'}):
        raise RuntimeError('Profile load had unsuccessful responses')
    return sample


def resolve_symbols(report, binary):
    llvm = Path(str(binary) + '.ll').read_text()
    attributes = dict(re.findall(
        r'attributes #(\d+) = \{[^\n]*?"abla.source"="([^"]+)"', llvm))
    names = {}
    for name, attribute in re.findall(
            r'^define [^\n]*?@(\w+)\([^\n]*#(\d+) \{', llvm, re.M):
        if attribute in attributes:
            names[name] = attributes[attribute]
            names[name.removesuffix('_direct')] = attributes[attribute]
    for symbol in sorted(names, key=len, reverse=True):
        report = report.replace(symbol, names[symbol])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--abla', type=Path, required=True)
    parser.add_argument('--zig', type=Path, default=b.BUILD / 'zig-server')
    parser.add_argument('--perf', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cases', default='json-nested,json-whitespace,json-escaped,json-int64')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    b.prepare_payloads()
    results = []
    for case in args.cases.split(','):
        for label, binary in [('abla', args.abla.resolve()), ('zig', args.zig.resolve())]:
            scenario = b.SCENARIOS[case]
            processes = b.start_servers(b.Server(label, binary), scenario, 18080,
                                        1, {2}, True, 1, 1)
            stem = args.output / (case + '-' + label)
            try:
                b.wait_until_ready(18080, processes, scenario)
                b.oha_run(b.find_oha(), 18080, 1, 64, set(range(16, 32)), scenario)
                # Attach to every already-existing server thread, not only the leader.
                tids = ','.join(t.name for process in processes
                                for t in Path('/proc', str(process.pid), 'task').iterdir())
                sample = measured_load(args.perf, [
                    'stat', '-x', ';', '-e',
                    'cycles:u,instructions:u,branches:u,branch-misses:u',
                    '-t', tids, '-o', str(stem) + '.stat'], scenario)
                count = sum(sample['statusCodeDistribution'].values())
                counters = {}
                for line in Path(str(stem) + '.stat').read_text().splitlines():
                    fields = line.split(';')
                    if len(fields) > 2 and fields[0].strip().isdigit():
                        counters[fields[2].strip()] = int(fields[0]) / count
                if len(counters) != 4:
                    raise RuntimeError(f'Missing perf counters: {counters}')
                measured_load(args.perf, ['record', '-e', 'cycles:u', '-F', '999',
                                         '-t', tids, '-o', str(stem) + '.perf'], scenario)
                report = subprocess.check_output([
                    str(args.perf), 'report', '-i', str(stem) + '.perf', '--stdio',
                    '--no-children', '--percent-limit', '1'], text=True)
                if label == 'abla':
                    report = resolve_symbols(report, binary)
                Path(str(stem) + '.txt').write_text(report)
                results.append(dict(
                    case=case, server=label,
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    threads=tids, sample=sample, user_counters_per_request=counters))
                (args.output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
                print(case, label, counters, flush=True)
            finally:
                b.stop_servers(processes)


if __name__ == '__main__':
    main()
