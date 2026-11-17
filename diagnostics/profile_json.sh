#!/usr/bin/env bash
# Measure server-only user-space counters (perf stat) and resolve Abla profile
# symbols (perf record + the compiler's .ll sidecar) for the JSON stress cases.
# This script only measures: there is no pass/fail judgement, but it exits
# non-zero when a server cannot be validated, the load has any unsuccessful
# response, perf fails, or a counter is missing.
#   diagnostics/profile_json.sh --abla BIN --perf PERF --output DIR [--zig BIN] [--cases a,b,...]
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../tools/harness.sh"

usage() { sed -n '2,9p' "$0"; }

abla="" perf="" output="" zig=$BUILD/zig-server cases=json-nested,json-whitespace,json-escaped,json-int64
while (($# > 0)); do
    case $1 in
    --abla) abla=${2:?}; shift ;;
    --perf) perf=${2:?}; shift ;;
    --output) output=${2:?}; shift ;;
    --zig) zig=${2:?}; shift ;;
    --cases) cases=${2:?}; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
[[ -n $abla && -n $perf && -n $output ]] || { usage >&2; exit 2; }
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
abla=$(abs "$abla") zig=$(abs "$zig") perf=$(abs "$perf")
mkdir -p "$output"
output=$(cd "$output" && pwd)

# resolve_symbols REPORT LLVM_IR: replace each generated function name in a
# perf report by the Abla source name recorded in the IR attributes.
resolve_symbols() {
    awk '
        FNR == NR {
            if ($0 ~ /^attributes #[0-9]+ = \{/ && match($0, /"abla\.source"="[^"]+"/)) {
                id = $2; sub(/^#/, "", id)
                source[id] = substr($0, RSTART + 15, RLENGTH - 16)
            }
            if ($0 ~ /^define / && match($0, /@[A-Za-z0-9_]+\(/)) {
                name = substr($0, RSTART + 1, RLENGTH - 2)
                if (match($0, /#[0-9]+ \{[ \t]*$/)) {
                    id = substr($0, RSTART + 1, RLENGTH - 3); sub(/ .*/, "", id)
                    definition_name[++definitions] = name
                    definition_id[definitions] = id
                }
            }
            next
        }
        { lines[++count] = $0 }
        END {
            # attributes come after the definitions in the IR, so join them now
            for (i = 1; i <= definitions; i++) {
                name = definition_name[i]; id = definition_id[i]
                if (id in source) {
                    names[name] = source[id]
                    base = name; sub(/_direct$/, "", base)
                    names[base] = source[id]
                }
            }
            # longest symbol first, so a prefix never eats a longer name
            total = 0
            for (n in names) order[++total] = n
            for (i = 2; i <= total; i++) {
                key = order[i]; j = i - 1
                while (j > 0 && length(order[j]) < length(key)) { order[j + 1] = order[j]; j-- }
                order[j + 1] = key
            }
            for (line = 1; line <= count; line++) {
                text = lines[line]
                for (i = 1; i <= total; i++) {
                    symbol = order[i]; out = ""
                    while ((pos = index(text, symbol)) > 0) {
                        out = out substr(text, 1, pos - 1) names[symbol]
                        text = substr(text, pos + length(symbol))
                    }
                    text = out text
                }
                print text
            }
        }' "$2" "$1"
}

# measured_load PERF_ARGS...: perf runs beside a five-second load, stopped by
# SIGINT; the load must have only successful 200 responses.
measured_load() {
    local scenario=$1 sample=$2
    shift 2
    env --default-signal=INT "$perf" "$@" >/dev/null 2>"$BUILD/perf.err" &
    local perf_pid=$!
    oha_run 18080 5 64 16-31 "$scenario" "$sample" || { kill -INT "$perf_pid" 2>/dev/null; die "load failed"; }
    kill -INT "$perf_pid" 2>/dev/null || true
    local status=0
    wait "$perf_pid" || status=$?
    ((status == 0 || status == 130)) || die "perf failed ($status): $(<"$BUILD/perf.err")"
    sample_ok "$sample" || die "Profile load had unsuccessful responses"
}

prepare_payloads
trap 'stop_servers' EXIT
summary=$output/summary.json
echo '[]' >"$summary"
IFS=, read -ra case_list <<<"$cases"
for case in "${case_list[@]}"; do
    in_array "$case" "${SCENARIO_ORDER[@]}" || die "unknown scenario: $case"
    for label in abla zig; do
        binary=$abla
        [[ $label == zig ]] && binary=$zig
        start_server "$label" "$binary" "$case" 18080 1 2 1 1 1
        stem=$output/$case-$label
        wait_until_ready 18080 "$case" || die "$case/$label failed validation"
        oha_run 18080 1 64 16-31 "$case" "$stem.warmup.json"
        # Attach to every already-existing server thread, not only the leader.
        tids=$(for pid in "${PIDS[@]}"; do ls "/proc/$pid/task"; done | paste -sd,)
        measured_load "$case" "$stem.sample.json" stat -x ';' -e cycles:u,instructions:u,branches:u,branch-misses:u \
            -t "$tids" -o "$stem.stat"
        count=$(jq '[.statusCodeDistribution[]] | add' "$stem.sample.json")
        counters=$(awk -F';' -v count="$count" '
            NF > 2 && $1 ~ /^[ \t]*[0-9]+[ \t]*$/ {
                name = $3; gsub(/^[ \t]+|[ \t]+$/, "", name)
                printf "%s%s\t%.17g", (n++ ? "\n" : ""), name, $1 / count
            }' "$stem.stat" | jq -R -s -c 'split("\n") | map(split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}')
        [[ $(jq 'length' <<<"$counters") == 4 ]] || die "Missing perf counters: $counters"
        measured_load "$case" "$stem.record-sample.json" record -e cycles:u -F 999 -t "$tids" -o "$stem.perf"
        "$perf" report -i "$stem.perf" --stdio --no-children --percent-limit 1 >"$stem.report"
        if [[ $label == abla ]]; then
            [[ -r $binary.ll ]] || die "missing $binary.ll (the compiler's LLVM sidecar)"
            resolve_symbols "$stem.report" "$binary.ll" >"$stem.txt"
        else
            cp "$stem.report" "$stem.txt"
        fi
        rm -f "$stem.report" "$stem.warmup.json" "$stem.record-sample.json"
        jq --arg c "$case" --arg l "$label" --arg sha "$(sha256sum "$binary" | cut -d' ' -f1)" \
            --arg tids "$tids" --slurpfile sample "$stem.sample.json" --argjson counters "$counters" \
            '. += [{case: $c, server: $l, binary_sha256: $sha, threads: $tids, sample: $sample[0],
                user_counters_per_request: $counters}]' "$summary" >"$summary.new"
        mv "$summary.new" "$summary"
        rm -f "$stem.sample.json"
        echo "$case $label $counters"
        stop_servers
    done
done
