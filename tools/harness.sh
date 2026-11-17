#!/usr/bin/env bash
# Shared harness for the HTTP comparison: scenario matrix, payload generation,
# server start/stop with CPU pinning, response validation and the oha driver.
# Sourced by benchmark.sh and the scripts in diagnostics/. Needs bash 4+, jq,
# curl, taskset (util-linux) and oha.

export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=$ROOT/build

die() {
    echo "error: $*" >&2
    exit 1
}

# ---------------------------------------------------------------- scenarios

declare -A S_METHOD S_TARGET S_CTYPE S_BODY S_HEADERS S_EXPECT S_EXPECT_TEXT
SCENARIO_ORDER=()
JSON_STRESS_NAMES=(json-empty json-items-128 json-roles-64 json-whitespace
    json-escaped json-unicode json-strings-4k json-int64)
BODY_STRESS_NAMES=(body-128 body-1k body-64k)

# define_scenario NAME METHOD TARGET CONTENT_TYPE BODY_FILE EXPECTED_TEXT [HEADER...]
# BODY_FILE "-" means no request body; EXPECTED_TEXT "@" means "echo the body".
define_scenario() {
    local name=$1
    SCENARIO_ORDER+=("$name")
    S_METHOD[$name]=$2
    S_TARGET[$name]=$3
    S_CTYPE[$name]=$4
    S_BODY[$name]=$5
    S_EXPECT_TEXT[$name]=$6
    shift 6
    local header headers=""
    for header in "$@"; do headers+="$header"$'\n'; done
    S_HEADERS[$name]=$headers
    S_EXPECT[$name]=$BUILD/expected/$name
}

JSON_NESTED='{"request_id":"req-123","user":{"id":42,"name":"Andre","roles":["admin","writer","reviewer"]},"items":[{"sku":"A-1","qty":2,"price":125},{"sku":"B-2","qty":3,"price":250},{"sku":"C-3","qty":1,"price":500}],"active":true,"note":"weird json payload"}'

define_all_scenarios() {
    local index
    define_scenario plaintext GET /plaintext text/plain - $'hello, world!\n'
    define_scenario parameters GET "/accounts/acct-42/items/item-7?filter=active" \
        text/plain - $'acct-42:item-7:active\n'
    define_scenario context GET /context text/plain - $'user-7:Andre:gold\n' \
        "Authorization: Bearer benchmark-token"
    define_scenario body-16k POST /body application/octet-stream \
        "$BUILD/body-16k.bin" @ "Content-Type: application/octet-stream"
    define_scenario route-tail-128 GET "/ridiculous/acct-42/orders/order-7?expand=lines" \
        text/plain - $'acct-42:order-7:lines\n'
    define_scenario parameters-16 GET \
        "/p/v0/s1/v1/s2/v2/s3/v3/s4/v4/s5/v5/s6/v6/s7/v7?q0=qv0&q1=qv1&q2=qv2&q3=qv3&q4=qv4&q5=qv5&q6=qv6&q7=qv7" \
        text/plain - $'v0:v1:v2:v3:v4:v5:v6:v7:qv0:qv1:qv2:qv3:qv4:qv5:qv6:qv7\n'
    local headers=()
    for index in $(seq 0 31); do headers+=("$(printf 'X-Bench-%02d: v%02d' "$index" "$index")"); done
    define_scenario headers-32 GET /headers-32 text/plain - $'v00:v07:v15:v23:v31\n' "${headers[@]}"
    define_scenario route-fanout-1024 GET /fanout/target text/plain - $'fanout-target\n'
    local query="/query-32?"
    local order=(19 3 27 11 31 0 22 7 14 29 5 25 9 17 1 30 12 24 6 20 2 28 15 10 23 4 18 26 8 21 13 16)
    for index in "${order[@]}"; do
        query+=$(printf 'field-%02d=value-%02d&' "$index" "$index")
    done
    define_scenario query-32-named GET "${query%&}" text/plain - \
        $'value-00:value-07:value-13:value-19:value-25:value-27:value-29:value-31\n'
    define_scenario json-nested POST /json-nested application/json \
        "$BUILD/json-nested.json" \
        '{"active":true,"item_count":3,"primary_role":"admin","request_id":"req-123","total":1500,"user":"Andre"}' \
        "Content-Type: application/json"
    local name
    for name in "${JSON_STRESS_NAMES[@]}"; do
        # Expected body is generated with the payload (it depends on the case).
        define_scenario "$name" POST /json-nested application/json \
            "$BUILD/$name.json" "@generated" "Content-Type: application/json"
    done
    for name in "${BODY_STRESS_NAMES[@]}"; do
        define_scenario "$name" POST /body application/octet-stream \
            "$BUILD/$name.bin" @ "Content-Type: application/octet-stream"
    done
}
define_all_scenarios

in_array() {
    local needle=$1 item
    shift
    for item in "$@"; do [[ $item == "$needle" ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------- payloads

# repeat_ramp BYTES FILE: the byte sequence 0,1,...,255,0,1,... cut to BYTES.
repeat_ramp() {
    local size=$1 file=$2 repeats=$((($1 + 255) / 256))
    for ((i = 0; i < repeats; i++)); do cat "$BUILD/ramp.bin"; done | head -c "$size" >"$file"
}

# The JSON stress cases keep the nested schema and only change payload
# characteristics. Each filter edits the base document.
json_stress_filter() {
    case $1 in
    json-empty) echo '.items = [] | .user.roles = []' ;;
    json-items-128) echo '.items = [range(128) | {sku: "item-\(.)", qty: (. % 7 + 1), price: (125 + .)}]' ;;
    json-roles-64) echo '.user.roles = [range(64) | "role-\(.)"]' ;;
    json-whitespace) echo '.' ;;
    json-escaped) echo '.user.name = ("quote\" slash\\ newline\n tab\t" * 16) | .request_id = "request\"\\\n"' ;;
    json-unicode) echo '.user.name = ("André 日本語 🌍" * 32) | .user.roles[0] = "管理者"' ;;
    json-strings-4k) echo '.user.name = ("abcdefgh" * 512) | .note = ("payload-" * 512)' ;;
    json-int64) echo '.user.id = 9223372036854775807 | .items = [{sku: "large", qty: 1, price: 9223372036854775807}, {sku: "negative", qty: 1, price: -9223372036854775808}]' ;;
    *) die "no JSON stress filter for $1" ;;
    esac
}

prepare_payloads() {
    mkdir -p "$BUILD/expected"
    local ramp="$BUILD/ramp.bin" i
    : >"$ramp"
    for i in $(seq 0 255); do printf "\\$(printf '%03o' "$i")" >>"$ramp"; done
    repeat_ramp 16384 "$BUILD/body-16k.bin"
    printf '%s' "$JSON_NESTED" >"$BUILD/json-nested.json"
    local name filter body_args total qty price
    for name in "${JSON_STRESS_NAMES[@]}"; do
        filter=$(json_stress_filter "$name")
        body_args=(-c)
        [[ $name == json-whitespace ]] && body_args=(--indent 2)
        [[ $name == json-unicode ]] && body_args+=(-a)
        printf '%s' "$JSON_NESTED" | jq "${body_args[@]}" "$filter" | head -c -1 >"$BUILD/$name.json"
        # The sum is computed with 64-bit shell arithmetic, because jq numbers
        # are doubles and the int64 case must stay exact.
        total=0
        while read -r qty price; do
            total=$((total + qty * price))
        done < <(jq -r '.items[] | "\(.qty) \(.price)"' "$BUILD/$name.json")
        jq -c --argjson total "$total" '{active: .active, item_count: (.items | length),
            primary_role: (.user.roles[0] // ""), request_id: .request_id,
            total: $total, user: .user.name}' "$BUILD/$name.json" | head -c -1 >"$BUILD/expected/$name"
    done
    for name in "${BODY_STRESS_NAMES[@]}"; do
        case $name in
        body-128) i=128 ;;
        body-1k) i=1024 ;;
        body-64k) i=65536 ;;
        esac
        repeat_ramp "$i" "$BUILD/$name.bin"
    done
    for name in "${SCENARIO_ORDER[@]}"; do
        case ${S_EXPECT_TEXT[$name]} in
        @generated) ;;
        @) cp "${S_BODY[$name]}" "$BUILD/expected/$name" ;;
        *) printf '%s' "${S_EXPECT_TEXT[$name]}" >"$BUILD/expected/$name" ;;
        esac
    done
}

# ---------------------------------------------------------------- CPU sets

# parse_cpu_list "0-3,8" prints one CPU per line, sorted, unique.
parse_cpu_list() {
    local part low high
    local -a parts
    IFS=, read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        part=${part// /}
        if [[ $part == *-* ]]; then
            low=${part%%-*}
            high=${part#*-}
            [[ $low =~ ^[0-9]+$ && $high =~ ^[0-9]+$ ]] || die "bad CPU list: $1"
            seq "$low" "$high"
        else
            [[ $part =~ ^[0-9]+$ ]] || die "bad CPU list: $1"
            echo "$part"
        fi
    done | sort -nu
}

cpu_csv() { paste -sd, -; }

# default_cpu_sets SERVER_CPU_COUNT sets DEFAULT_SERVER_CPUS and
# DEFAULT_CLIENT_CPUS (comma lists; empty when the host cannot be split).
default_cpu_sets() {
    local wanted=$1 cpu sibling_file sibling
    DEFAULT_SERVER_CPUS=""
    DEFAULT_CLIENT_CPUS=""
    command -v taskset >/dev/null || return 0
    local list
    list=$(taskset -cp $$ | sed 's/.*: //')
    local available=()
    mapfile -t available < <(parse_cpu_list "$list")
    ((${#available[@]} >= 2)) || return 0
    declare -A is_available=() server=() reserved=()
    for cpu in "${available[@]}"; do is_available[$cpu]=1; done
    _reserve_siblings() {
        reserved[$1]=1
        sibling_file=/sys/devices/system/cpu/cpu$1/topology/thread_siblings_list
        if [[ -r $sibling_file ]]; then
            for sibling in $(parse_cpu_list "$(<"$sibling_file")"); do
                [[ -n ${is_available[$sibling]:-} ]] && reserved[$sibling]=1
            done
        fi
    }
    local count=0
    for cpu in "${available[@]}"; do
        ((count >= wanted)) && break
        if [[ -z ${reserved[$cpu]:-} ]]; then
            server[$cpu]=1
            count=$((count + 1))
            _reserve_siblings "$cpu"
        fi
    done
    if ((count < wanted)); then
        for cpu in "${available[@]}"; do
            ((count >= wanted)) && break
            if [[ -z ${server[$cpu]:-} ]]; then
                server[$cpu]=1
                count=$((count + 1))
                _reserve_siblings "$cpu"
            fi
        done
    fi
    local clients=()
    for cpu in "${available[@]}"; do
        [[ -z ${reserved[$cpu]:-} ]] && clients+=("$cpu")
    done
    if ((${#clients[@]} == 0)); then
        for cpu in "${available[@]}"; do
            [[ -z ${server[$cpu]:-} ]] && clients+=("$cpu")
        done
    fi
    DEFAULT_SERVER_CPUS=$(printf '%s\n' "${!server[@]}" | sort -n | cpu_csv)
    DEFAULT_CLIENT_CPUS=$(printf '%s\n' "${clients[@]}" | sort -n | cpu_csv)
}

# default_zig_worker_split WORKERS sets ZIG_EVENT_WORKERS and ZIG_HANDLER_THREADS.
default_zig_worker_split() {
    local limit=$1
    if ((limit == 1)); then
        # One event loop and two handlers was the best single-CPU configuration.
        ZIG_EVENT_WORKERS=1
        ZIG_HANDLER_THREADS=2
        return
    fi
    local event=1
    while (((event + 1) * (event + 1) <= limit)); do event=$((event + 1)); done
    while ((limit % event != 0)); do event=$((event - 1)); done
    ZIG_EVENT_WORKERS=$event
    ZIG_HANDLER_THREADS=$((limit / event - 1))
}

# ---------------------------------------------------------------- tools

find_oha() {
    local executable=${OHA:-$(command -v oha || true)}
    [[ -n $executable ]] || die "oha was not found; run with: nix-shell -p oha jq curl --run './benchmark.sh'"
    echo "$executable"
}

find_zig() {
    local executable=${ZIG:-$(command -v zig || true)}
    [[ -n $executable ]] || die "zig was not found; set ZIG to a Zig 0.16.0 executable"
    echo "$executable"
}

compiler_path() {
    if [[ -n ${ABLAC:-} ]]; then
        # shellcheck disable=SC2088
        local configured=${ABLAC/#\~/$HOME}
        [[ $configured == /* ]] || configured=$PWD/$configured
        echo "$configured"
    else
        # Do not resolve this symlink: the guarded launcher deliberately finds
        # its sibling payload from argv[0] (build/ablac.bin).
        echo "$(dirname "$ROOT")/ablac/build/ablac"
    fi
}

# ---------------------------------------------------------------- servers

PIDS=()

# start_server NAME EXECUTABLE SCENARIO PORT WORKERS SERVER_CPUS PIN_ABLA ZIG_EVENT ZIG_HANDLERS [INDEX_LOG_DIR]
# Fills PIDS. SERVER_CPUS is a comma list (empty: no pinning).
start_server() {
    local name=$1 executable=$2 scenario=$3 port=$4 workers=$5 server_cpus=$6
    local pin_abla=$7 zig_event=$8 zig_handlers=$9
    local count=1
    [[ $name == abla ]] && count=$workers
    local handler=$scenario
    in_array "$scenario" "${JSON_STRESS_NAMES[@]}" && handler=json-nested
    in_array "$scenario" "${BODY_STRESS_NAMES[@]}" && handler=body-16k
    local command=("$executable" "$port") environment=(ABLA_COMPARE_SCENARIO="$handler")
    case $name in
    abla) command+=("$handler") ;;
    go) environment+=(GOMAXPROCS="$workers") ;;
    rust) environment+=(TOKIO_WORKER_THREADS="$workers") ;;
    zig) command+=("$zig_event" "$zig_handlers") ;;
    esac
    [[ $name == abla ]] && ((count > 1)) && command+=(--reuse-port)
    local cpus=()
    [[ -n $server_cpus ]] && mapfile -t cpus < <(parse_cpu_list "$server_cpus")
    mkdir -p "$BUILD/logs"
    PIDS=()
    local index pin
    for ((index = 0; index < count; index++)); do
        local prefix=()
        if ((${#cpus[@]} > 0)); then
            pin=$server_cpus
            if [[ $name == abla && $pin_abla == 1 ]]; then
                pin=${cpus[$((index % ${#cpus[@]}))]}
            fi
            prefix=(taskset -c "$pin")
        fi
        (cd "$ROOT" && exec env "${environment[@]}" "${prefix[@]}" "${command[@]}") \
            >/dev/null 2>"$BUILD/logs/$name-$index.err" &
        PIDS+=($!)
    done
}

# 0 when the process is gone (or a zombie).
process_exited() {
    local state
    state=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null || true)
    [[ -z $state || $state == Z ]]
}

stop_servers() {
    local pid deadline
    for pid in "${PIDS[@]}"; do
        process_exited "$pid" || kill -TERM "$pid" 2>/dev/null || true
    done
    deadline=$((SECONDS + 3))
    for pid in "${PIDS[@]}"; do
        while ! process_exited "$pid" && ((SECONDS < deadline)); do sleep 0.05; done
        process_exited "$pid" || kill -KILL "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    PIDS=()
}

# wait_until_ready PORT SCENARIO: two exact responses (status, content type,
# body) on one persistent connection from every start. A connection that is
# refused or reset is retried for ten seconds; a wrong answer fails at once.
wait_until_ready() {
    local port=$1 scenario=$2 pid deadline attempt_output="" first second
    local out1=$BUILD/validate-1.out out2=$BUILD/validate-2.out
    local request=(--silent --show-error --http1.1 --max-time 5 --request "${S_METHOD[$scenario]}"
        -H 'Expect:' -H 'Connection: keep-alive')
    local header
    while IFS= read -r header; do
        [[ -n $header ]] && request+=(-H "$header")
    done <<<"${S_HEADERS[$scenario]}"
    [[ ${S_BODY[$scenario]} != - ]] && request+=(--data-binary "@${S_BODY[$scenario]}")
    request+=("http://127.0.0.1:$port${S_TARGET[$scenario]}")
    local format=$'%{http_code}\t%{num_connects}\t%{content_type}\n'
    deadline=$((SECONDS + 10))
    while ((SECONDS <= deadline)); do
        for pid in "${PIDS[@]}"; do
            if process_exited "$pid"; then
                echo "server worker exited during startup" >&2
                return 1
            fi
        done
        if attempt_output=$(curl "${request[@]}" -o "$out1" -w "$format" --next \
            "${request[@]}" -o "$out2" -w "$format" 2>"$BUILD/validate.err"); then
            local -a lines
            mapfile -t lines <<<"$attempt_output"
            local n status connects ctype
            for n in 0 1; do
                IFS=$'\t' read -r status connects ctype <<<"${lines[$n]}"
                ctype=${ctype%%;*}
                ctype=$(echo "$ctype" | tr 'A-Z' 'a-z' | tr -d ' ')
                local got=$BUILD/validate-$((n + 1)).out
                if [[ $status != 200 ]] || ! cmp -s "$got" "${S_EXPECT[$scenario]}"; then
                    echo "unexpected response: status=$status, expected $(stat -c %s "${S_EXPECT[$scenario]}") bytes, got $(stat -c %s "$got")" >&2
                    return 1
                fi
                if [[ $ctype != "${S_CTYPE[$scenario]}" ]]; then
                    echo "unexpected content type: $ctype" >&2
                    return 1
                fi
                if [[ $n == 1 && $connects != 0 ]]; then
                    echo "server closed the keep-alive connection" >&2
                    return 1
                fi
            done
            return 0
        fi
        sleep 0.05
    done
    echo "server did not become ready: $(<"$BUILD/validate.err")" >&2
    return 1
}

# ---------------------------------------------------------------- load

# oha_run PORT SECONDS CONNECTIONS CLIENT_CPUS SCENARIO OUTPUT_FILE
oha_run() {
    local port=$1 duration=$2 connections=$3 client_cpus=$4 scenario=$5 output=$6
    local command=("$(find_oha)" --no-tui --output-format json --http-version 1.1
        --disable-compression --wait-ongoing-requests-after-deadline
        --stats-success-breakdown -z "${duration}s" -c "$connections")
    # oha's default counts physical cores on the whole host, not the CPU
    # affinity applied below. Oversubscribing the client introduces scheduler
    # delays into its latency measurements, especially for the fastest servers.
    local prefix=()
    if [[ -n $client_cpus ]]; then
        command+=(--worker-threads "$(parse_cpu_list "$client_cpus" | wc -l)")
        prefix=(taskset -c "$client_cpus")
    fi
    [[ ${S_METHOD[$scenario]} != GET ]] && command+=(--method "${S_METHOD[$scenario]}")
    local header
    while IFS= read -r header; do
        [[ -n $header ]] && command+=(-H "$header")
    done <<<"${S_HEADERS[$scenario]}"
    [[ ${S_BODY[$scenario]} != - ]] && command+=(-D "${S_BODY[$scenario]}")
    command+=("http://127.0.0.1:$port${S_TARGET[$scenario]}")
    (cd "$ROOT" && "${prefix[@]}" "${command[@]}") >"$output" 2>"$output.err" ||
        die "oha failed: $(<"$output.err")"
    rm -f "$output.err"
}

# sample_ok FILE: every request succeeded, with 200 responses only.
sample_ok() {
    jq -e '.summary.successRate == 1 and (.errorDistribution | length) == 0
        and (.statusCodeDistribution | keys) == ["200"]' "$1" >/dev/null
}


tool_version() {
    local out
    out=$("$@" 2>/dev/null | head -n 1) && [[ -n $out ]] && echo "$out" || echo unavailable
}

# machine_metadata prints the "machine" JSON object.
machine_metadata() {
    local cpu_model=unknown logical
    [[ -r /proc/cpuinfo ]] && cpu_model=$(awk -F: '/^model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
    logical=$(nproc --all)
    local compiler zig oha
    compiler=$(compiler_path)
    zig=$(find_zig)
    oha=$(find_oha)
    jq -n --arg platform "$(uname -s)-$(uname -r)-$(uname -m)" --arg cpu "$cpu_model" \
        --argjson logical "$logical" --arg shell "bash ${BASH_VERSION}" \
        --arg go "$(tool_version go version)" --arg rust "$(tool_version rustc --version)" \
        --arg cargo "$(tool_version cargo --version)" --arg zig "$(tool_version "$zig" version)" \
        --arg oha "$(tool_version "$oha" --version)" --arg compiler "$compiler" \
        --arg abla "$(tool_version "$compiler" --version)" \
        '{platform: $platform, cpu: $cpu, logical_cpus: $logical, shell: $shell, go: $go,
          rust: $rust, cargo: $cargo, zig: $zig, oha: $oha, abla_compiler: $compiler,
          abla_version: $abla}'
}

JQ_MEDIAN='def median: sort | if length % 2 == 1 then .[(length / 2 | floor)]
    else (.[length / 2 - 1] + .[length / 2]) / 2 end;'
