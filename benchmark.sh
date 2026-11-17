#!/usr/bin/env bash
# Build, validate, and benchmark the equivalent HTTP servers.
#
# Needs jq, curl, taskset and oha; see README.md. Run it from anywhere:
#   nix-shell -p oha zig jq curl --run './benchmark.sh --scenario plaintext'
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/tools/harness.sh"

usage() {
    cat <<'EOF'
usage: benchmark.sh [--build-only | --skip-build] [--port N] [--connections N]
       [--warmup SECONDS] [--duration SECONDS] [--repetitions N]
       [--server all|abla|go|rust|zig] [--scenario all|NAME] [--workers N]
       [--pin-abla-workers] [--zig-event-workers N] [--zig-handler-threads N]
       [--server-cpus LIST] [--client-cpus LIST] [--output FILE]
EOF
}

positive() {
    [[ $2 =~ ^[0-9]+$ ]] && (($2 > 0)) || { echo "$1 must be a positive integer" >&2; usage >&2; exit 2; }
}

run_logged() {
    echo "+ $*" >&2
    "$@"
}

build_servers() {
    prepare_payloads
    local compiler zig
    compiler=$(compiler_path)
    [[ -e $compiler ]] || die "Abla compiler not found at $compiler; set ABLAC to override"
    zig=$(find_zig)
    run_logged "$compiler" build --project "$ROOT" --offline --no-cache -o "$BUILD/abla-server"
    (cd "$ROOT/servers/go" && run_logged go build -trimpath '-ldflags=-s -w' -o "$BUILD/go-server" .)
    (cd "$ROOT/servers/rust" && run_logged cargo build --release --locked)
    cp "$ROOT/servers/rust/target/release/abla-compare-rust" "$BUILD/rust-server"
    (cd "$ROOT/servers/zig" && run_logged "$zig" build -Doptimize=ReleaseFast)
    cp "$ROOT/servers/zig/zig-out/bin/abla-compare-zig" "$BUILD/zig-server"
}

main() {
    local build_only=0 skip_build=0 port=18080 connections=64 warmup=3 duration=10
    local repetitions=3 server=all scenario=all workers=1 pin_abla=0
    local zig_event="" zig_handlers="" server_cpus="" client_cpus=""
    local output=$ROOT/results/latest.json
    while (($# > 0)); do
        case $1 in
        --build-only) build_only=1 ;;
        --skip-build) skip_build=1 ;;
        --pin-abla-workers) pin_abla=1 ;;
        --port | --connections | --warmup | --duration | --repetitions | --server | --scenario | \
            --workers | --zig-event-workers | --zig-handler-threads | --server-cpus | \
            --client-cpus | --output)
            (($# >= 2)) || { echo "$1 needs a value" >&2; exit 2; }
            case $1 in
            --port) port=$2 ;;
            --connections) connections=$2 ;;
            --warmup) warmup=$2 ;;
            --duration) duration=$2 ;;
            --repetitions) repetitions=$2 ;;
            --server) server=$2 ;;
            --scenario) scenario=$2 ;;
            --workers) workers=$2 ;;
            --zig-event-workers) zig_event=$2 ;;
            --zig-handler-threads) zig_handlers=$2 ;;
            --server-cpus) server_cpus=$2 ;;
            --client-cpus) client_cpus=$2 ;;
            --output) output=$2 ;;
            esac
            shift
            ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    ((build_only && skip_build)) && { echo "--build-only and --skip-build cannot be combined" >&2; exit 2; }
    local value name
    for name in connections warmup duration repetitions workers; do
        positive "--$name" "${!name}"
    done
    [[ -n $zig_event ]] && positive --zig-event-workers "$zig_event"
    [[ -n $zig_handlers ]] && positive --zig-handler-threads "$zig_handlers"
    in_array "$server" all abla go rust zig || { echo "--server must be all, abla, go, rust or zig" >&2; exit 2; }
    [[ $scenario == all ]] || in_array "$scenario" "${SCENARIO_ORDER[@]}" ||
        { echo "unknown scenario: $scenario" >&2; exit 2; }

    ((skip_build)) || build_servers
    ((build_only)) && return 0
    local servers=(abla go rust zig)
    [[ $server != all ]] && servers=("$server")
    for name in "${servers[@]}"; do
        [[ -e $BUILD/$name-server ]] || die "missing $BUILD/$name-server; run without --skip-build"
    done
    benchmark
}

benchmark() {
    local oha
    oha=$(find_oha)
    default_cpu_sets "$workers"
    [[ -z $server_cpus ]] && server_cpus=$DEFAULT_SERVER_CPUS
    [[ -z $client_cpus ]] && client_cpus=$DEFAULT_CLIENT_CPUS
    if [[ -n $server_cpus && -n $client_cpus ]] &&
        [[ -n $(comm -12 <(parse_cpu_list "$server_cpus") <(parse_cpu_list "$client_cpus")) ]]; then
        die "server and client CPU sets must not overlap"
    fi
    [[ -n $server_cpus ]] && server_cpus=$(parse_cpu_list "$server_cpus" | cpu_csv)
    [[ -n $client_cpus ]] && client_cpus=$(parse_cpu_list "$client_cpus" | cpu_csv)

    prepare_payloads
    local selected=("${SCENARIO_ORDER[@]}")
    [[ $scenario != all ]] && selected=("$scenario")
    default_zig_worker_split "$workers"
    local zig_event_workers=${zig_event:-$ZIG_EVENT_WORKERS}
    local zig_handler_threads=${zig_handlers:-$ZIG_HANDLER_THREADS}

    result=""
    work=$(mktemp -d)
    result=$work/result.json
    trap 'stop_servers; rm -rf "${work:-}"' EXIT
    local pin_text="shared CPU set"
    ((pin_abla)) && pin_text="one process per CPU"
    local server_json=null client_json=null client_count=null
    [[ -n $server_cpus ]] && server_json=$(parse_cpu_list "$server_cpus" | jq -sc .)
    if [[ -n $client_cpus ]]; then
        client_json=$(parse_cpu_list "$client_cpus" | jq -sc .)
        client_count=$(parse_cpu_list "$client_cpus" | wc -l)
    fi
    local scenario_json
    scenario_json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -sc .)
    jq -n --arg generated "$(date -u +%Y-%m-%dT%H:%M:%S.%6N+00:00)" \
        --argjson scenarios "$scenario_json" --argjson warmup "$warmup" \
        --argjson duration "$duration" --argjson connections "$connections" \
        --argjson repetitions "$repetitions" --argjson workers "$workers" \
        --arg pin "$pin_text" --argjson zev "$zig_event_workers" \
        --argjson zht "$zig_handler_threads" --argjson scpus "$server_json" \
        --argjson ccpus "$client_json" --argjson ccount "$client_count" \
        --argjson machine "$(machine_metadata)" '{
        generated_at: $generated,
        configuration: {
            scenarios: $scenarios,
            protocol: "HTTP/1.1 with keep-alive",
            warmup_seconds: $warmup,
            measurement_seconds: $duration,
            connections: $connections,
            repetitions: $repetitions,
            abla_process_workers: $workers,
            abla_worker_affinity: $pin,
            go_gomaxprocs: $workers,
            rust_tokio_worker_threads: $workers,
            go_rust_zig_worker_model: "one process; threads inherit server affinity",
            zig_http_server: "httpz dce2cb07f1cd9beca6146869e1eec48025cf9f6f",
            zig_event_workers: $zev,
            zig_handler_threads_per_event_worker: $zht,
            zig_active_worker_threads: ($zev * (1 + $zht)),
            parameters_16_access_model: "Abla and Zig use positional path/query values; Go uses named path/query access; Rust uses positional path and named query access",
            headers_32_access_model: "all implementations use header names",
            route_fanout_1024_access_model: "1,024 literal decoys followed by one literal target in every router",
            query_32_named_access_model: "all implementations parse 32 query fields and retrieve eight by name",
            json_nested_access_model: "all implementations match schema fields by name; Abla uses its canonical-order streaming reader and encoder, while Go, Rust, and Zig use typed schema decoders and serializers; the fixed compact payload order is part of this benchmark scenario",
            server_cpus: ($scpus // []),
            client_cpus: ($ccpus // []),
            oha_worker_threads: $ccount
        },
        machine: $machine,
        scenarios: {}
    }' >"$result"

    local sc srv rep body_bytes
    for sc in "${selected[@]}"; do
        body_bytes=0
        [[ ${S_BODY[$sc]} != - ]] && body_bytes=$(stat -c %s "${S_BODY[$sc]}")
        jq --arg sc "$sc" --arg method "${S_METHOD[$sc]}" --arg target "${S_TARGET[$sc]}" \
            --argjson req "$body_bytes" --argjson resp "$(stat -c %s "${S_EXPECT[$sc]}")" \
            '.scenarios[$sc] = {method: $method, target: $target, request_body_bytes: $req,
                response_body_bytes: $resp, servers: {}}' "$result" >"$result.new"
        mv "$result.new" "$result"
        for srv in "${servers[@]}"; do
            printf '\n== %s / %s: validation and warm-up ==\n' "$sc" "$srv"
            start_server "$srv" "$BUILD/$srv-server" "$sc" "$port" "$workers" "$server_cpus" \
                "$pin_abla" "$zig_event_workers" "$zig_handler_threads"
            wait_until_ready "$port" "$sc" || { stop_servers; die "$sc/$srv failed validation"; }
            oha_run "$port" "$warmup" "$connections" "$client_cpus" "$sc" "$work/warmup.json"
            jq -e '.summary.successRate == 1' "$work/warmup.json" >/dev/null ||
                { stop_servers; die "$sc/$srv warm-up had request failures"; }
            local files=()
            for ((rep = 1; rep <= repetitions; rep++)); do
                oha_run "$port" "$duration" "$connections" "$client_cpus" "$sc" "$work/sample-$rep.json"
                jq -e '.summary.successRate == 1' "$work/sample-$rep.json" >/dev/null ||
                    { stop_servers; die "$sc/$srv repetition $rep had failures"; }
                files+=("$work/sample-$rep.json")
                jq -r --arg label "$sc/$srv $rep/$repetitions" '"\($label): \(.summary.requestsPerSec | floor) req/s, p50 \(.latencyPercentiles.p50 * 1000 * 1000 | round / 1000) ms, p99 \(.latencyPercentiles.p99 * 1000 * 1000 | round / 1000) ms"' "$work/sample-$rep.json"
            done
            stop_servers
            jq -s "$JQ_MEDIAN"'{
                median_requests_per_second: (map(.summary.requestsPerSec) | median),
                median_p50_seconds: (map(.latencyPercentiles.p50) | median),
                median_p99_seconds: (map(.latencyPercentiles.p99) | median),
                samples: .}' "${files[@]}" >"$work/server.json"
            jq --arg sc "$sc" --arg srv "$srv" --slurpfile data "$work/server.json" \
                '.scenarios[$sc].servers[$srv] = $data[0]' "$result" >"$result.new"
            mv "$result.new" "$result"
            rm -f "$work"/sample-*.json
        done
    done

    mkdir -p "$(dirname "$output")"
    jq . "$result" >"$output"
    printf '\nWrote raw results to %s\n' "$output"
    printf '\nscenario     server   median req/s   median p50   median p99\n'
    printf '%s\n' '------------ -------- ------------   ----------   ----------'
    jq -r '.scenarios | to_entries[] | .key as $sc | .value.servers | to_entries[] |
        [$sc, .key, (.value.median_requests_per_second | round), .value.median_p50_seconds * 1000,
         .value.median_p99_seconds * 1000] | @tsv' "$output" |
        while IFS=$'\t' read -r sc srv rate p50 p99; do
            printf '%-12s %-8s %12.0f   %8.3f ms   %8.3f ms\n' "$sc" "$srv" "$rate" "$p50" "$p99"
        done
}

main "$@"
