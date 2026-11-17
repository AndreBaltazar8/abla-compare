#!/usr/bin/env bash
# Exact body echo on persistent HTTP/1.1 connections, through the harness
# preflight: two byte-exact responses, status 200 and the right content type on
# one keep-alive connection. Fails (exit 1) when a server truncates or closes.
#   servers/go/test_keepalive_echo.sh BINARY [--server abla|go|rust|zig] [--server-cpu N] [--port N]
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../tools/harness.sh"

binary="" server=go server_cpu=8 port=18152
while (($# > 0)); do
    case $1 in
    --server) server=${2:?--server needs a value}; shift ;;
    --server-cpu) server_cpu=${2:?--server-cpu needs a value}; shift ;;
    --port) port=${2:?--port needs a value}; shift ;;
    -h | --help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) binary=$1 ;;
    esac
    shift
done
[[ -n $binary ]] || { echo "usage: $0 BINARY [--server NAME] [--server-cpu N] [--port N]" >&2; exit 2; }
in_array "$server" abla go rust zig || { echo "--server must be abla, go, rust or zig" >&2; exit 2; }
binary=$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")

prepare_payloads
trap 'stop_servers' EXIT
for name in body-128 body-1k body-16k body-64k; do
    start_server "$server" "$binary" "$name" "$port" 1 "$server_cpu" 1 1 2
    wait_until_ready "$port" "$name" || die "$server/$name failed the keep-alive echo check"
    echo "$server/$name: two exact keep-alive echoes"
    stop_servers
done
