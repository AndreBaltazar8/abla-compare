#!/usr/bin/env bash
# Alternate baseline Abla, candidate Abla and Zig over validated stress cases.
# Every server is validated with exact responses before it is measured; the
# server order is reversed on even rounds. Needs the same tools as benchmark.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../tools/harness.sh"

usage() {
    cat <<'EOF'
usage: compare_stress.sh --output FILE [--baseline BIN] [--candidate BIN] [--zig BIN]
       [--cases a,b,...] [--workers N] [--server-cpus LIST] [--client-cpus LIST]
       [--connections N] [--warmup S] [--duration S] [--repetitions N] [--port N]
       [--allow-baseline-validation-failures]
EOF
}

abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

baseline=$BUILD/abla-server candidate="" zig=$BUILD/zig-server output=""
cases=$(IFS=,; echo "json-nested,${JSON_STRESS_NAMES[*]},${BODY_STRESS_NAMES[*]}" | tr ' ' ',')
workers=8 server_cpus=0,2,4,6,8,10,12,14 client_cpus=16-31 connections=256
warmup=2 duration=5 repetitions=3 port=18080 allow_failures=false
while (($# > 0)); do
    case $1 in
    --allow-baseline-validation-failures) allow_failures=true ;;
    -h | --help) usage; exit 0 ;;
    --baseline | --candidate | --zig | --output | --cases | --workers | --server-cpus | \
        --client-cpus | --connections | --warmup | --duration | --repetitions | --port)
        (($# >= 2)) || { echo "$1 needs a value" >&2; exit 2; }
        case $1 in
        --baseline) baseline=$2 ;;
        --candidate) candidate=$2 ;;
        --zig) zig=$2 ;;
        --output) output=$2 ;;
        --cases) cases=$2 ;;
        --workers) workers=$2 ;;
        --server-cpus) server_cpus=$2 ;;
        --client-cpus) client_cpus=$2 ;;
        --connections) connections=$2 ;;
        --warmup) warmup=$2 ;;
        --duration) duration=$2 ;;
        --repetitions) repetitions=$2 ;;
        --port) port=$2 ;;
        esac
        shift
        ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
[[ -n $output ]] || { echo "--output is required" >&2; usage >&2; exit 2; }
for name in workers connections warmup duration repetitions; do
    [[ ${!name} =~ ^[0-9]+$ ]] && ((${!name} >= 1)) || { echo "counts and durations must be positive" >&2; exit 2; }
done
[[ -z $(comm -12 <(parse_cpu_list "$server_cpus") <(parse_cpu_list "$client_cpus")) ]] ||
    { echo "server and client CPUs must not overlap" >&2; exit 2; }
IFS=, read -ra case_list <<<"$cases"
for name in "${case_list[@]}"; do
    in_array "$name" "${SCENARIO_ORDER[@]}" || { echo "unknown scenario: $name" >&2; exit 2; }
done

labels=(baseline)
declare -A binary=([baseline]=$(abs "$baseline") [zig]=$(abs "$zig"))
if [[ -n $candidate ]]; then
    labels+=(candidate)
    binary[candidate]=$(abs "$candidate")
fi
labels+=(zig)
if ((workers == 1)); then
    zig_workers=1 zig_handlers=1
else
    default_zig_worker_split "$workers"
    zig_workers=$ZIG_EVENT_WORKERS zig_handlers=$ZIG_HANDLER_THREADS
fi
oha_threads=$(parse_cpu_list "$client_cpus" | wc -l)
server_cpu_list=$(parse_cpu_list "$server_cpus" | cpu_csv)
client_cpu_list=$(parse_cpu_list "$client_cpus" | cpu_csv)

prepare_payloads
work=$(mktemp -d)
trap 'stop_servers; rm -rf "$work"' EXIT
mkdir -p "$(dirname "$output")"

hashes='{}'
for label in "${labels[@]}"; do
    hashes=$(jq -c --arg k "$label" --arg v "$(sha256sum "${binary[$label]}" | cut -d' ' -f1)" '.[$k] = $v' <<<"$hashes")
done
harness_hashes='{}'
for file in "${BASH_SOURCE[0]}" "$ROOT/benchmark.sh" "$ROOT/tools/harness.sh"; do
    harness_hashes=$(jq -c --arg k "$(basename "$file")" --arg v "$(sha256sum "$file" | cut -d' ' -f1)" '.[$k] = $v' <<<"$harness_hashes")
done
configuration=$(jq -nc --arg baseline "${binary[baseline]}" --arg candidate "$candidate" \
    --arg zig "${binary[zig]}" --arg output "$output" --arg cases "$cases" \
    --argjson workers "$workers" --arg scpus "$server_cpus" --arg ccpus "$client_cpus" \
    --argjson connections "$connections" --argjson warmup "$warmup" \
    --argjson duration "$duration" --argjson repetitions "$repetitions" \
    --argjson port "$port" --argjson allow "$allow_failures" \
    '{baseline: $baseline, candidate: (if $candidate == "" then null else $candidate end),
      zig: $zig, output: $output, cases: $cases, workers: $workers, server_cpus: $scpus,
      client_cpus: $ccpus, connections: $connections, warmup: $warmup, duration: $duration,
      repetitions: $repetitions, port: $port,
      allow_baseline_validation_failures: $allow}')
result=$work/result.json
jq -n --arg generated "$(date -u +%Y-%m-%dT%H:%M:%S.%6N+00:00)" --argjson configuration "$configuration" \
    --argjson machine "$(machine_metadata)" --argjson hashes "$hashes" \
    --argjson harness "$harness_hashes" --argjson threads "$oha_threads" \
    --argjson zw "$zig_workers" --argjson zh "$zig_handlers" '{
    generated_at: $generated, configuration: $configuration, machine: $machine,
    binary_sha256: $hashes, server_order: "forward on odd rounds, reverse on even rounds",
    harness_sha256: $harness, oha_worker_threads: $threads, zig_event_workers: $zw,
    zig_handlers_per_event_worker: $zh, validation_failures: [], results: []}' >"$result"
save() { jq . "$result" >"$output"; }

declare -A failed=()
for case in "${case_list[@]}"; do
    for ((iteration = 0; iteration < repetitions; iteration++)); do
        # Reverse each round so every pair is measured in both orders.
        order=("${labels[@]}")
        if ((iteration % 2)); then
            order=()
            for ((i = ${#labels[@]} - 1; i >= 0; i--)); do order+=("${labels[$i]}"); done
        fi
        for label in "${order[@]}"; do
            [[ -n ${failed["$case/$label"]:-} ]] && continue
            kind=abla
            [[ $label == zig ]] && kind=zig
            start_server "$kind" "${binary[$label]}" "$case" "$port" "$workers" "$server_cpu_list" \
                1 "$zig_workers" "$zig_handlers"
            if ! error=$(wait_until_ready "$port" "$case" 2>&1); then
                if [[ $label != baseline || $allow_failures != true ]]; then
                    stop_servers
                    die "$case/$label: $error"
                fi
                jq --arg sc "$case" --arg srv "$label" --arg err "$error" \
                    '.validation_failures += [{scenario: $sc, server: $srv, error: $err}]' "$result" >"$result.new"
                mv "$result.new" "$result"
                failed["$case/$label"]=1
                echo "VALIDATION FAILED $case/$label: $error"
                save
                stop_servers
                continue
            fi
            for phase in warmup sample; do
                seconds=$warmup
                [[ $phase == sample ]] && seconds=$duration
                oha_run "$port" "$seconds" "$connections" "$client_cpu_list" "$case" "$work/$phase.json"
                sample_ok "$work/$phase.json" || { stop_servers; die "$case/$label/$phase had failures"; }
            done
            stop_servers
            jq --arg sc "$case" --argjson it "$((iteration + 1))" --arg srv "$label" \
                --slurpfile sample "$work/sample.json" \
                '.results += [{scenario: $sc, iteration: $it, server: $srv, sample: $sample[0]}]' \
                "$result" >"$result.new"
            mv "$result.new" "$result"
            jq -r --arg l "$case $((iteration + 1)) $label" \
                '"\($l): \(.summary.requestsPerSec | floor) req/s, p99 \(.latencyPercentiles.p99 * 1000 * 1000 | round / 1000) ms"' \
                "$work/sample.json"
            save
        done
    done
done
save
