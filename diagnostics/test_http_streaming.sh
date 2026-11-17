#!/usr/bin/env bash
# Validate the echo server across fragmented input, pipelining and slow reads.
#   diagnostics/test_http_streaming.sh BINARY [--server-cpu N] [--port N]
# BINARY is an Abla benchmark server (for example build/abla-server). The
# server is started with the body-64k scenario on one pinned CPU; the checks
# themselves are in http_streaming_check.ab, built with the Abla compiler
# (ABLAC, default ../ablac/build/ablac).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../tools/harness.sh"

binary="" server_cpu=2 port=18080
while (($# > 0)); do
    case $1 in
    --server-cpu) server_cpu=${2:?--server-cpu needs a value}; shift ;;
    --port) port=${2:?--port needs a value}; shift ;;
    -h | --help) sed -n '2,7p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) binary=$1 ;;
    esac
    shift
done
[[ -n $binary ]] || { echo "usage: $0 BINARY [--server-cpu N] [--port N]" >&2; exit 2; }
binary=$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")

compiler=$(compiler_path)
[[ -e $compiler ]] || die "Abla compiler not found at $compiler; set ABLAC to override"
mkdir -p "$BUILD"
"$compiler" build "$ROOT/diagnostics/http_streaming_check.ab" -o "$BUILD/http-streaming-check" --offline >&2

prepare_payloads
trap 'stop_servers' EXIT
start_server abla "$binary" body-64k "$port" 1 "$server_cpu" 1 1 1
wait_until_ready "$port" body-64k || die "server failed validation"
"$BUILD/http-streaming-check" "$port"
