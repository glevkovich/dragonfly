#!/bin/bash
set -eo pipefail

usage() {
    cat <<EOF
Usage: ./bench_v2.sh [binary] [mode] [runs] [tag] [ver] [threads] [dfly_log_dir]
  binary:       path to dragonfly binary (default: ./build-opt/dragonfly)
  mode:         multi_conn | single_conn | pubsub | all (default: all)
  runs:         how many times to repeat the full benchmark (default: 3)
                If runs > 1, a final median report is printed at the end.
  tag:          optional label for the log file.
                If given, log file is: {tag}_{HHMMSS}.log
                If omitted:             bench_v2_{mode}_{sha}_{YYYYMMDD_HHMMSS}.log
  ver:          which version(s) to run: v1 | v2 | both (default: both)
  threads:      number of proactor threads for dragonfly (default: 2)
  dfly_log_dir: optional directory to save the Dragonfly server log.
                If given, the log is copied there on exit as dfly_{tag_or_sha}_{TIMESTAMP}.log.
                If omitted, the log is discarded.

Environment variables (for cross-machine benchmarking):
  CLIENT_HOST:  SSH host of the client machine that runs memtier/redis-benchmark.
                If unset, client tools run locally (single-machine mode).
  SERVER_HOST:  IP the client uses to reach this server (default: 127.0.0.1).
                Set to the server's private IP when CLIENT_HOST is set.
  SSH_USER:     SSH username for CLIENT_HOST (default: current user).
  CLIENT_DELAY_US: Artificial one-way delay in microseconds on loopback (local mode only).
                Simulates real-network RTT gaps. Requires 'sudo' and 'tc'.
                Example: CLIENT_DELAY_US=100 simulates 0.2ms RTT.
                Default: 0 (no delay). Set to 50-200 to mimic cross-machine.
  PIPELINE:     Comma-separated list of pipeline depths to run. Default: all (1,10,100,500).
                Example: PIPELINE=10 or PIPELINE=1,100
  CMD:          Command to benchmark: set | zadd (default: set).
                SET uses the async dispatch path; ZADD uses the synchronous path
                (the connection blocks until the shard completes each command).
                Both multi_conn and single_conn modes respect this variable.

Modes:
  multi_conn     - 50 clients, heavy saturation (command set by CMD env var).
  single_conn    - 1 client, isolates per-connection behavior (command set by CMD).
  pubsub         - 10 subscribers, PUBLISH fan-out.
  all            - Run all modes sequentially.

Examples:
  # Local (single machine):
  ./bench_v2.sh ./build-opt/dragonfly pubsub 5 my_tag v2

  # Cross-machine (run this ON THE SERVER):
  SERVER_HOST=172.31.30.209 CLIENT_HOST=172.31.20.3 ./bench_v2.sh ./build-opt/dragonfly all 3

  # Run only pipeline=10 cross-machine, V2 only:
  PIPELINE=10 SERVER_HOST=172.31.30.209 CLIENT_HOST=172.31.20.3 ./bench_v2.sh ./build-opt/dragonfly multi_conn 1 mytag v2

  # Benchmark ZADD (sync command path) with 50 connections:
  CMD=zadd ./bench_v2.sh ./build-opt/dragonfly multi_conn 1 mytag both

  # Run pipeline=10 and pipeline=100 only:
  PIPELINE=10,100 ./bench_v2.sh ./build-opt/dragonfly multi_conn 1 mytag both
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
    usage
    exit 0
fi

DFLY_BIN=${1:-"./build-opt/dragonfly"}
MODE=${2:-"all"}
RUNS=${3:-3}
TAG=${4:-""}
VER=${5:-"both"}
# Arg 6 can be either threads (a number) or dfly_log_dir (a path starting with / or .).
# If it looks like a path, treat it as DFLY_LOG_DIR and use default threads.
if [[ "${6:-}" =~ ^[0-9]+$ ]]; then
    PROACTOR_THREADS=${6}
    DFLY_LOG_DIR=${7:-""}
elif [[ "${6:-}" == /* || "${6:-}" == ./* || "${6:-}" == . ]]; then
    PROACTOR_THREADS=2
    DFLY_LOG_DIR=${6}
else
    PROACTOR_THREADS=${6:-2}
    DFLY_LOG_DIR=${7:-""}
fi
PORT=6379
ADMIN_PORT=8099
SERVER_HOST=${SERVER_HOST:-"127.0.0.1"}
CLIENT_HOST=${CLIENT_HOST:-""}
SSH_USER=${SSH_USER:-"$(whoami)"}
CLIENT_DELAY_US=${CLIENT_DELAY_US:-0}
PIPELINE_FILTER=${PIPELINE:-""}
CMD=${CMD:-"set"}
if [[ "$CMD" != "set" && "$CMD" != "zadd" ]]; then
    echo "[!] Error: CMD must be 'set' or 'zadd', got '$CMD'"
    exit 1
fi
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -n "$TAG" ]]; then
    LOG_FILE="${TAG}_$(date +%H%M%S).log"
else
    LOG_FILE="bench_v2_${MODE}_${GIT_SHA}_${TIMESTAMP}.log"
fi
ACCUM_FILE=$(mktemp)
DFLY_LOG=$(mktemp)

if [[ -n "$DFLY_LOG_DIR" && ! -d "$DFLY_LOG_DIR" ]]; then
    echo "[!] Error: dfly_log_dir '${DFLY_LOG_DIR}' does not exist. Create it first."
    exit 1
fi

# Cross-machine mode detection.
REMOTE_MODE=""
if [[ -n "$CLIENT_HOST" ]]; then
    REMOTE_MODE=1
    if [[ "$SERVER_HOST" == "127.0.0.1" ]]; then
        echo "[!] Error: CLIENT_HOST is set but SERVER_HOST is 127.0.0.1."
        echo "    The client can't reach the server. Set SERVER_HOST to this machine's IP."
        exit 1
    fi
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_USER}@${CLIENT_HOST}" true 2>/dev/null; then
        echo "[!] Error: Cannot SSH to ${SSH_USER}@${CLIENT_HOST} (BatchMode, no password prompt)."
        echo "    Fix: ssh-copy-id ${SSH_USER}@${CLIENT_HOST}"
        exit 1
    fi
    echo "[*] Cross-machine mode: server=$(hostname), client=${SSH_USER}@${CLIENT_HOST}"
    echo "    Client will target ${SERVER_HOST}:${PORT}"
fi

ulimit -n 4096 2>/dev/null || true

# Loopback delay simulation (local mode only).
NETEM_ACTIVE=""
setup_netem() {
    if [[ -z "$REMOTE_MODE" && "$CLIENT_DELAY_US" -gt 0 ]]; then
        echo "[*] Adding ${CLIENT_DELAY_US}us one-way delay on lo (RTT=${CLIENT_DELAY_US}x2 us)"
        sudo tc qdisc add dev lo root netem delay "${CLIENT_DELAY_US}us" 2>/dev/null || {
            echo "[!] WARNING: tc netem failed. Run with sudo or install iproute2."
            return
        }
        NETEM_ACTIVE=1
    fi
}
teardown_netem() {
    if [[ -n "$NETEM_ACTIVE" ]]; then
        sudo tc qdisc del dev lo root 2>/dev/null || true
        NETEM_ACTIVE=""
    fi
}
setup_netem

# ---------------------------------------------------------------------------
# filter_pipelines <p1> <p2> ...
# Returns the subset of given pipeline depths that match PIPELINE_FILTER.
# If PIPELINE_FILTER is empty, returns all of them unchanged.
# ---------------------------------------------------------------------------
filter_pipelines() {
    if [[ -z "$PIPELINE_FILTER" ]]; then
        echo "$@"
        return
    fi
    local result=()
    for p in "$@"; do
        if [[ ",$PIPELINE_FILTER," == *",$p,"* ]]; then
            result+=("$p")
        fi
    done
    if [[ ${#result[@]} -eq 0 ]]; then
        echo "[!] Warning: PIPELINE=$PIPELINE_FILTER matched no depths in ($*). Running all." >&2
        echo "$@"
    else
        echo "${result[@]}"
    fi
}

# Global PID tracking for cleanup.
DFLY_PID=""
SUB_PIDS=()

cleanup() {
    local exit_code=$?
    echo ""
    echo "[*] Cleaning up (exit_code=$exit_code)..."

    teardown_netem

    for pid in "${SUB_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    SUB_PIDS=()

    # Kill remote client tools if in cross-machine mode.
    if [[ -n "$REMOTE_MODE" ]]; then
        ssh -n -o ConnectTimeout=3 "${SSH_USER}@${CLIENT_HOST}" \
            "pkill -9 redis-cli; pkill -9 redis-benchmark; pkill -9 memtier_benchmark" 2>/dev/null || true
    fi

    if [[ -n "$DFLY_PID" ]]; then
        kill "$DFLY_PID" 2>/dev/null || true
        wait "$DFLY_PID" 2>/dev/null || true
        DFLY_PID=""
    fi

    # Crash fallback: save log if dragonfly was still running when we exited.
    if [[ -n "$DFLY_LOG_DIR" && -s "$DFLY_LOG" ]]; then
        local save_name="dfly_${TAG:-${GIT_SHA}}_$(date +%Y%m%d_%H%M%S)_crash.log"
        cp "$DFLY_LOG" "${DFLY_LOG_DIR}/${save_name}"
        echo "[*] Dragonfly crash log saved to ${DFLY_LOG_DIR}/${save_name}"
    fi
    rm -f "$ACCUM_FILE" "$DFLY_LOG"
    echo "[*] Done."
}
trap cleanup EXIT INT TERM

NUM_CPUS=$(nproc)
MIN_CPUS=2  # 1 for dragonfly + 1 for client (local mode).

if [[ $NUM_CPUS -lt $MIN_CPUS ]]; then
    echo "[!] Error: Need at least $MIN_CPUS CPUs, this machine has $NUM_CPUS."
    exit 1
fi

if [[ -z "$REMOTE_MODE" ]]; then
    if [[ $PROACTOR_THREADS -ge $NUM_CPUS ]]; then
        echo "[!] Error: threads=${PROACTOR_THREADS} >= available CPUs (${NUM_CPUS})."
        echo "    Leave at least 1 CPU for memtier. Max allowed: $((NUM_CPUS - 1))."
        exit 1
    fi

    DFLY_CPUS=$(seq -s ',' 0 $((PROACTOR_THREADS - 1)))
    CLIENT_CORES_START=${PROACTOR_THREADS}
    CLIENT_CORES_END=$((PROACTOR_THREADS + 1))
    [[ $CLIENT_CORES_END -ge $NUM_CPUS ]] && CLIENT_CORES_END=$((NUM_CPUS - 1))
    CLIENT_CPUS=$(seq -s ',' ${CLIENT_CORES_START} ${CLIENT_CORES_END})

    DFLY_TASKSET="taskset -c ${DFLY_CPUS}"
    CLIENT_TASKSET="taskset -c ${CLIENT_CPUS}"
else
    # Remote mode: dragonfly uses all local cores.
    DFLY_TASKSET=""
    CLIENT_TASKSET=""
    REMOTE_CPUS=$(ssh -o ConnectTimeout=5 "${SSH_USER}@${CLIENT_HOST}" nproc 2>/dev/null || echo 0)
    if [[ $REMOTE_CPUS -lt $MIN_CPUS ]]; then
        echo "[!] Error: Client machine $CLIENT_HOST has $REMOTE_CPUS CPUs, need at least $MIN_CPUS."
        exit 1
    fi
    echo "[*] Server CPUs: $NUM_CPUS, Client CPUs: $REMOTE_CPUS"
fi

# Preflight: verify required client tools exist on the machine that will run them.
check_client_tools() {
    local missing=()
    if [[ -n "$REMOTE_MODE" ]]; then
        ssh -n "${SSH_USER}@${CLIENT_HOST}" "command -v memtier_benchmark" > /dev/null 2>&1 || missing+=("memtier_benchmark")
        ssh -n "${SSH_USER}@${CLIENT_HOST}" "command -v redis-benchmark"   > /dev/null 2>&1 || missing+=("redis-benchmark")
        ssh -n "${SSH_USER}@${CLIENT_HOST}" "command -v redis-cli"         > /dev/null 2>&1 || missing+=("redis-cli")
    else
        command -v memtier_benchmark > /dev/null 2>&1 || missing+=("memtier_benchmark")
        command -v redis-benchmark   > /dev/null 2>&1 || missing+=("redis-benchmark")
        command -v redis-cli         > /dev/null 2>&1 || missing+=("redis-cli")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[!] Error: Missing tools on client: ${missing[*]}"
        echo "    redis-benchmark / redis-cli: sudo apt-get install -y redis-tools"
        echo "    memtier_benchmark: must be built from source:"
        echo "      sudo apt-get install -y build-essential autoconf automake libpcre3-dev libevent-dev libssl-dev zlib1g-dev git"
        echo "      git clone https://github.com/RedisLabs/memtier_benchmark.git && cd memtier_benchmark"
        echo "      autoreconf -ivf && ./configure && make && sudo make install"
        exit 1
    fi
}
check_client_tools

# ---------------------------------------------------------------------------
# run_on_client <cmd...>
# Executes a command on the client. Local mode: runs with CLIENT_TASKSET.
# Remote mode: runs via SSH on CLIENT_HOST targeting SERVER_HOST.
# ---------------------------------------------------------------------------
run_on_client() {
    if [[ -n "$REMOTE_MODE" ]]; then
        ssh -n "${SSH_USER}@${CLIENT_HOST}" "$(printf '%q ' "$@")"
    else
        $CLIENT_TASKSET "$@"
    fi
}

# Target host for client tools: SERVER_HOST in remote mode, 127.0.0.1 locally.
client_target() {
    if [[ -n "$REMOTE_MODE" ]]; then
        echo "$SERVER_HOST"
    else
        echo "127.0.0.1"
    fi
}

wait_for_server() {
    local timeout=${1:-10}
    local elapsed=0
    while ! redis-cli -p $PORT ping > /dev/null 2>&1; do
        if [[ -n "$DFLY_PID" ]] && ! kill -0 "$DFLY_PID" 2>/dev/null; then
            echo "[!] Dragonfly (PID $DFLY_PID) died during startup."
            DFLY_PID=""
            return 1
        fi
        sleep 0.2
        elapsed=$(( elapsed + 1 ))
        if [[ $elapsed -ge $(( timeout * 5 )) ]]; then
            echo "[!] Error: Dragonfly did not become ready within ${timeout}s."
            return 1
        fi
    done
}

get_send_count() {
    local raw val
    raw=$(curl -s --max-time 2 "http://127.0.0.1:${ADMIN_PORT}/metrics" 2>/dev/null) || true
    val=$(echo "$raw" | tr -d '\r' | grep '^dragonfly_reply_total' | awk '{sum += $NF} END {print (sum ? sum : 0)}') || true
    echo "${val:-0}"
}

get_replies_per_flush_raw() {
    # Returns "sum count" from the histogram for delta computation.
    local raw sum count
    raw=$(curl -s --max-time 2 "http://127.0.0.1:${ADMIN_PORT}/metrics" 2>/dev/null) || true
    sum=$(echo "$raw" | tr -d '\r' | grep '^dragonfly_replies_per_flush_sum' | awk '{print $NF}') || true
    count=$(echo "$raw" | tr -d '\r' | grep '^dragonfly_replies_per_flush_count' | awk '{print $NF}') || true
    echo "${sum:-0} ${count:-0}"
}

compute_batch_density() {
    # Given total replies and syscall delta, compute real batch density.
    local total_replies=$1 send_delta=$2
    if [[ "$send_delta" -gt 0 ]]; then
        awk "BEGIN {printf \"%.1f\", $total_replies / $send_delta}"
    else
        echo "0"
    fi
}

_metrics_verified=0
verify_metrics_endpoint() {
    [[ $_metrics_verified -eq 1 ]] && return
    _metrics_verified=1

    redis-cli -p $PORT SET __bench_probe__ 1 > /dev/null 2>&1 || true
    redis-cli -p $PORT GET __bench_probe__ > /dev/null 2>&1 || true

    local raw sample
    raw=$(curl -s --max-time 2 "http://127.0.0.1:${ADMIN_PORT}/metrics" 2>/dev/null) || true
    sample=$(echo "$raw" | tr -d '\r' | grep '^dragonfly_reply_total') || true

    if [[ -z "$raw" ]]; then
        echo "[!] WARNING: /metrics endpoint unreachable. SEND_SYSCALLS will show 0."
    elif [[ -z "$sample" ]]; then
        echo "[!] WARNING: /metrics reachable but 'dragonfly_reply_total' not found."
    fi
}

stop_dragonfly() {
    if [[ -n "$DFLY_PID" ]]; then
        kill "$DFLY_PID" 2>/dev/null || true
        local i=0
        while kill -0 "$DFLY_PID" 2>/dev/null && (( i < 40 )); do
            sleep 0.15; i=$(( i + 1 ))
        done
        if kill -0 "$DFLY_PID" 2>/dev/null; then
            echo "[!] Dragonfly didn't exit after SIGTERM, sending SIGKILL"
            kill -9 "$DFLY_PID" 2>/dev/null || true
            sleep 0.4
        fi
        wait "$DFLY_PID" 2>/dev/null || true
        DFLY_PID=""
    fi
    if [[ -n "$DFLY_LOG_DIR" && -s "$DFLY_LOG" ]]; then
        local save_name="dfly_${TAG:-${GIT_SHA}}_$(date +%Y%m%d_%H%M%S).log"
        cp "$DFLY_LOG" "${DFLY_LOG_DIR}/${save_name}"
        echo "[*] Dragonfly log saved to ${DFLY_LOG_DIR}/${save_name}"
        : > "$DFLY_LOG"  # Truncate so cleanup doesn't duplicate.
    fi
    sleep 0.6  # let OS release the TCP port
}

start_dragonfly() {
    local v2_flag=$1; shift
    local label=$1; shift
    local mode_name=$1; shift
    local extra_flags=("$@")
    # Append env-provided flags (e.g. EXTRA_DFLY_FLAGS="--pipeline_wait_batch_usec=50")
    if [[ -n "${EXTRA_DFLY_FLAGS:-}" ]]; then
        read -ra _env_flags <<< "$EXTRA_DFLY_FLAGS"
        extra_flags+=("${_env_flags[@]}")
    fi

    local log_flags=()
    if [[ -n "$DFLY_LOG_DIR" ]]; then
        log_flags=(--alsologtostderr --minloglevel=0)
    fi

    echo ""
    echo ">>> Starting Dragonfly [${label}] mode=${mode_name} (io_loop_v2=${v2_flag})"
    local dfly_cmd=($DFLY_TASKSET "$DFLY_BIN"
        --proactor_threads="${PROACTOR_THREADS}"
        --enable_resp_io_loop_v2="${v2_flag}"
        --bind=0.0.0.0
        --port=$PORT
        # --minloglevel=0 --vmodule=dragonfly_connection=1
        --admin_port=$ADMIN_PORT
        --dbfilename ""
        "${log_flags[@]}"
        "${extra_flags[@]}")
    echo "  [server cmd] ${dfly_cmd[*]}"
    "${dfly_cmd[@]}" > "$DFLY_LOG" 2>&1 &
    DFLY_PID=$!

    if ! wait_for_server 10; then
        echo "[!] Dragonfly log tail:"; tail -20 "$DFLY_LOG"
        exit 1
    fi
    # Flush any data loaded from a saved RDB (e.g. leftover keys from a previous run
    # with a different command type — SET keys would cause WRONGTYPE on ZADD).
    redis-cli -p $PORT FLUSHALL > /dev/null 2>&1 || true
    verify_metrics_endpoint
}

# ---------------------------------------------------------------------------
# run_bench <v2_flag> <label> <threads> <clients> <data_size> <mode_name>
#           <pipelines...> [-- <extra_dfly_flags...>]
# ---------------------------------------------------------------------------
run_bench() {
    local v2_flag=$1; shift
    local label=$1; shift
    local threads=$1; shift
    local clients=$1; shift
    local data_size=$1; shift
    local mode_name=$1; shift
    local pipelines=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        pipelines+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local extra_dfly_flags=("$@")

    start_dragonfly "$v2_flag" "$label" "$mode_name" "${extra_dfly_flags[@]}"

    local target
    target=$(client_target)

    RESULTS_TMP=$(mktemp)
    echo -e "PIPELINE\tRPS\tAVG_LAT(ms)\tSEND_SYSCALLS\tBATCH_DENSITY" > "$RESULTS_TMP"

    for PIPELINE in "${pipelines[@]}"; do
        echo "  [+] pipeline=$PIPELINE ..."

        SENDS_BEFORE=$(get_send_count)

        local memtier_cmd=(memtier_benchmark
            -s "$target"
            -p $PORT
            -t "$threads"
            -c "$clients"
            --pipeline="$PIPELINE"
            --ratio=1:0
            -d "$data_size"
            --key-pattern=R:R
            --key-prefix=bench
            -n 30000
            --hide-histogram)
        if [[ -n "$REMOTE_MODE" ]]; then
            echo "  [client cmd] ssh ${SSH_USER}@${CLIENT_HOST} ${memtier_cmd[*]}"
        else
            echo "  [client cmd] $CLIENT_TASKSET ${memtier_cmd[*]}"
        fi

        local OUTPUT
        OUTPUT=$(run_on_client "${memtier_cmd[@]}" 2>&1) || true
        echo "  --- raw memtier output ---"
        echo "$OUTPUT"
        echo "  --- end raw output ---"

        SENDS_AFTER=$(get_send_count)
        SEND_DELTA=$(( SENDS_AFTER - SENDS_BEFORE ))
        # Total replies = threads * clients * requests_per_client
        local TOTAL_REPLIES=$(( threads * clients * 30000 ))
        BATCH_DENSITY=$(compute_batch_density "$TOTAL_REPLIES" "$SEND_DELTA")

        RPS=$(echo "$OUTPUT" | grep "^Totals" | awk '{print $2}' || true)
        LATENCY=$(echo "$OUTPUT" | grep "^Totals" | awk '{print $5}' || true)
        if [[ -z "$RPS" ]]; then echo "[!] WARNING: could not parse RPS from memtier output"; fi
        RPS=${RPS:-"Error"}
        LATENCY=${LATENCY:-"Error"}

        echo -e "$PIPELINE\t$RPS\t$LATENCY\t$SEND_DELTA\t$BATCH_DENSITY" >> "$RESULTS_TMP"
        echo "${label}|${mode_name}|${PIPELINE}|${RPS}|${LATENCY}|${SEND_DELTA}|${BATCH_DENSITY}" >> "$ACCUM_FILE"
    done

    stop_dragonfly

    echo ""
    echo "====================================================="
    printf "  %-4s  %s  (commit: %s)\n" "$label" "$mode_name" "$GIT_SHA"
    echo "====================================================="
    column -t -s $'\t' "$RESULTS_TMP"
    echo "====================================================="
    rm "$RESULTS_TMP"
}

# ---------------------------------------------------------------------------
# run_bench_custom <v2_flag> <label> <threads> <clients> <mode_name>
#                  <pipelines...> [-- <memtier_extra_args...>] [-- <dfly_extra_args...>]
# For custom memtier commands (e.g., ZADD).
# ---------------------------------------------------------------------------
run_bench_custom() {
    local v2_flag=$1; shift
    local label=$1; shift
    local threads=$1; shift
    local clients=$1; shift
    local mode_name=$1; shift
    local pipelines=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        pipelines+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local memtier_extra=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        memtier_extra+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local extra_dfly_flags=("$@")

    start_dragonfly "$v2_flag" "$label" "$mode_name" "${extra_dfly_flags[@]}"

    local target
    target=$(client_target)

    RESULTS_TMP=$(mktemp)
    echo -e "PIPELINE\tRPS\tAVG_LAT(ms)\tSEND_SYSCALLS\tBATCH_DENSITY" > "$RESULTS_TMP"

    for PIPELINE in "${pipelines[@]}"; do
        echo "  [+] pipeline=$PIPELINE ..."

        SENDS_BEFORE=$(get_send_count)

        local memtier_cmd=(memtier_benchmark
            -s "$target"
            -p $PORT
            -t "$threads"
            -c "$clients"
            --pipeline="$PIPELINE"
            --key-prefix=bench
            -n 30000
            --hide-histogram
            "${memtier_extra[@]}")
        if [[ -n "$REMOTE_MODE" ]]; then
            echo "  [client cmd] ssh ${SSH_USER}@${CLIENT_HOST} ${memtier_cmd[*]}"
        else
            echo "  [client cmd] $CLIENT_TASKSET ${memtier_cmd[*]}"
        fi

        local OUTPUT
        OUTPUT=$(run_on_client "${memtier_cmd[@]}" 2>&1) || true
        echo "  --- raw memtier output ---"
        echo "$OUTPUT"
        echo "  --- end raw output ---"

        SENDS_AFTER=$(get_send_count)
        SEND_DELTA=$(( SENDS_AFTER - SENDS_BEFORE ))
        local TOTAL_REPLIES=$(( threads * clients * 30000 ))
        BATCH_DENSITY=$(compute_batch_density "$TOTAL_REPLIES" "$SEND_DELTA")

        RPS=$(echo "$OUTPUT" | grep "^Totals" | awk '{print $2}' || true)
        LATENCY=$(echo "$OUTPUT" | grep "^Totals" | awk '{print $5}' || true)
        if [[ -z "$RPS" ]]; then echo "[!] WARNING: could not parse RPS from memtier output"; fi
        RPS=${RPS:-"Error"}
        LATENCY=${LATENCY:-"Error"}

        echo -e "$PIPELINE\t$RPS\t$LATENCY\t$SEND_DELTA\t$BATCH_DENSITY" >> "$RESULTS_TMP"
        echo "${label}|${mode_name}|${PIPELINE}|${RPS}|${LATENCY}|${SEND_DELTA}|${BATCH_DENSITY}" >> "$ACCUM_FILE"
    done

    stop_dragonfly

    echo ""
    echo "====================================================="
    printf "  %-4s  %s  (commit: %s)\n" "$label" "$mode_name" "$GIT_SHA"
    echo "====================================================="
    column -t -s $'\t' "$RESULTS_TMP"
    echo "====================================================="
    rm "$RESULTS_TMP"
}

# ---------------------------------------------------------------------------
# run_pubsub_bench <v2_flag> <label> <num_subscribers> <num_messages> <pipelines...>
# ---------------------------------------------------------------------------
run_pubsub_bench() {
    local v2_flag=$1; shift
    local label=$1; shift
    local num_subs=$1; shift
    local num_msgs=$1; shift
    local pipelines=("$@")

    start_dragonfly "$v2_flag" "$label" "pubsub"

    local target
    target=$(client_target)

    RESULTS_TMP=$(mktemp)
    echo -e "PIPELINE\tPUB_RPS\tSEND_SYSCALLS\tSUBSCRIBERS" > "$RESULTS_TMP"

    local msg_payload
    msg_payload=$(printf '%128s' | tr ' ' 'X')

    for PIPELINE in "${pipelines[@]}"; do
        echo "  [+] pipeline=$PIPELINE, subscribers=$num_subs ..."

        # Launch subscribers (from client machine toward server).
        local sub_cmd_str
        if [[ -n "$REMOTE_MODE" ]]; then
            sub_cmd_str="redis-cli -h $SERVER_HOST -p $PORT SUBSCRIBE bench_chan"
            echo "  [client sub cmd x${num_subs}] ssh ${SSH_USER}@${CLIENT_HOST} ${sub_cmd_str}"
        else
            sub_cmd_str="$CLIENT_TASKSET redis-cli -p $PORT SUBSCRIBE bench_chan"
            echo "  [client sub cmd x${num_subs}] ${sub_cmd_str}"
        fi
        SUB_PIDS=()
        for ((s = 0; s < num_subs; s++)); do
            if [[ -n "$REMOTE_MODE" ]]; then
                ssh -n "${SSH_USER}@${CLIENT_HOST}" \
                    "redis-cli -h $SERVER_HOST -p $PORT SUBSCRIBE bench_chan > /dev/null 2>&1" &
            else
                $CLIENT_TASKSET redis-cli -p $PORT SUBSCRIBE bench_chan > /dev/null 2>&1 &
            fi
            SUB_PIDS+=($!)
        done
        sleep 1.2  # let all subscribers register

        SENDS_BEFORE=$(get_send_count)

        local OUTPUT
        if [[ -n "$REMOTE_MODE" ]]; then
            local pub_cmd="timeout 60 redis-benchmark -h $SERVER_HOST -p $PORT -n $num_msgs -P $PIPELINE -c 5 -q publish bench_chan '$msg_payload'"
            echo "  [client pub cmd] ssh ${SSH_USER}@${CLIENT_HOST} ${pub_cmd}"
            OUTPUT=$(ssh "${SSH_USER}@${CLIENT_HOST}" "$pub_cmd" 2>&1) || true
        else
            local pub_cmd="timeout 60 $CLIENT_TASKSET redis-benchmark -p $PORT -n $num_msgs -P $PIPELINE -c 5 -q publish bench_chan <payload>"
            echo "  [client pub cmd] ${pub_cmd}"
            OUTPUT=$(timeout 60 $CLIENT_TASKSET redis-benchmark -p "$PORT" -n "$num_msgs" -P "$PIPELINE" \
                -c 5 -q publish bench_chan "$msg_payload" 2>&1) || true
        fi

        echo "  --- raw redis-benchmark output ---"
        echo "$OUTPUT"
        echo "  --- end raw output ---"

        SENDS_AFTER=$(get_send_count)
        SEND_DELTA=$(( SENDS_AFTER - SENDS_BEFORE ))

        RPS=$(echo "$OUTPUT" | tr '\r' '\n' | grep -i 'requests per second' | tail -n 1 | grep -oP '[0-9]+\.[0-9]+' | head -n 1 || true)
        if [[ -z "$RPS" ]]; then echo "[!] WARNING: could not parse RPS from redis-benchmark output"; fi
        RPS=${RPS:-"Error"}

        # Tear down subscribers.
        for pid in "${SUB_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done

        if [[ -n "$REMOTE_MODE" ]]; then
            # Kill all redis-cli on client. -n prevents ssh from stealing stdin.
            ssh -n -o ConnectTimeout=3 "${SSH_USER}@${CLIENT_HOST}" "pkill -9 redis-cli" 2>/dev/null || true
        fi

        # Watchdog: if SSH proxy processes hang, force-kill after 2s.
        ( sleep 2; kill -9 "${SUB_PIDS[@]}" 2>/dev/null || true ) &
        local watchdog_pid=$!

        wait "${SUB_PIDS[@]}" 2>/dev/null || true
        kill "$watchdog_pid" 2>/dev/null || true
        SUB_PIDS=()

        echo -e "${PIPELINE}\t${RPS}\t${SEND_DELTA}\t${num_subs}" >> "$RESULTS_TMP"
        echo "${label}|pubsub|${PIPELINE}|${RPS}||${SEND_DELTA}" >> "$ACCUM_FILE"
    done

    stop_dragonfly

    echo ""
    echo "====================================================="
    printf "  %-4s  %s  (commit: %s)\n" "$label" "pubsub" "$GIT_SHA"
    echo "====================================================="
    column -t -s $'\t' "$RESULTS_TMP"
    echo "====================================================="
    rm "$RESULTS_TMP"
}

print_final_report() {
    [[ $RUNS -le 1 ]] && return
    echo ""
    echo "======================================================"
    echo "  MEDIAN RESULTS ($RUNS runs, commit: $GIT_SHA)"
    echo "======================================================"
    awk -F'|' '
    function get_median(bk, n,    i, j, tmp, arr) {
        if (n == 0) return 0
        for (i = 1; i <= n; i++) arr[i] = vals[bk, i]
        for (i = 1; i < n; i++)
            for (j = i + 1; j <= n; j++)
                if (arr[j] < arr[i]) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
        return arr[int((n + 1) / 2)]
    }
    {
        key = $1 SUBSEP $2 SUBSEP $3
        if (!(key in seen)) {
            seen[key] = 1
            order[++n] = key
            lbl[key] = $1; mod[key] = $2; pip[key] = $3
        }
        if ($4+0 > 0) { rps_n[key]++; vals["r" SUBSEP key, rps_n[key]] = $4 }
        if ($5+0 > 0) { lat_n[key]++; vals["l" SUBSEP key, lat_n[key]] = $5 }
        sys_sum[key] += $6; sys_cnt[key]++
        if ($7+0 > 0) { bd_n[key]++; vals["b" SUBSEP key, bd_n[key]] = $7 }
    }
    END {
        prev_group = ""
        for (i = 1; i <= n; i++) {
            k = order[i]
            g = lbl[k] SUBSEP mod[k]
            if (g != prev_group) {
                if (prev_group != "") print "====================================================="
                print ""
                printf "  %-4s  %s\n", lbl[k], mod[k]
                print "====================================================="
                print "PIPELINE\tRPS\tAVG_LAT(ms)\tSEND_SYSCALLS\tBATCH_DENSITY"
                prev_group = g
            }
            rps_med = get_median("r" SUBSEP k, rps_n[k])
            lat_med = get_median("l" SUBSEP k, lat_n[k])
            bd_med = get_median("b" SUBSEP k, bd_n[k])
            printf "%s\t%.2f\t%.5f\t%.0f\t%.1f\n", pip[k], rps_med, lat_med, sys_sum[k]/sys_cnt[k], bd_med
        }
        print "====================================================="
    }
    ' "$ACCUM_FILE" | column -t -s $'\t'
}

# ---------- MODE: multi_conn ----------
# 50 concurrent clients saturate the server. Regression-guard for peak RPS.
# Respects CMD env var: "set" (default, 2KB value) or "zadd" (sync command path).
run_multi_conn() {
    local pipelines
    read -ra pipelines <<< "$(filter_pipelines 1 10 100 500)"
    if [[ "$CMD" == "zadd" ]]; then
        if [[ "$VER" != "v2" ]]; then
            _metrics_verified=0
            run_bench_custom false "V1" 2 25 "multi_conn_zadd" "${pipelines[@]}" \
                -- --command="ZADD __key__ 1 __data__" --command-key-pattern=R -d 32
        fi
        if [[ "$VER" != "v1" ]]; then
            _metrics_verified=0
            run_bench_custom true  "V2" 2 25 "multi_conn_zadd" "${pipelines[@]}" \
                -- --command="ZADD __key__ 1 __data__" --command-key-pattern=R -d 32
        fi
    else
        if [[ "$VER" != "v2" ]]; then
            _metrics_verified=0
            run_bench false "V1" 2 25 2048 "multi_conn" "${pipelines[@]}"
        fi
        if [[ "$VER" != "v1" ]]; then
            _metrics_verified=0
            run_bench true  "V2" 2 25 2048 "multi_conn" "${pipelines[@]}"
        fi
    fi
}

# ---------- MODE: single_conn ----------
# 1 client. Isolates per-connection behavior (coalescing, latency).
# Respects CMD env var: "set" (default, 2KB value) or "zadd" (sync command path).
run_single_conn() {
    local pipelines
    read -ra pipelines <<< "$(filter_pipelines 1 10 100 500)"
    if [[ "$CMD" == "zadd" ]]; then
        if [[ "$VER" != "v2" ]]; then
            _metrics_verified=0
            run_bench_custom false "V1" 1 1 "single_conn_zadd" "${pipelines[@]}" \
                -- --command="ZADD __key__ 1 __data__" --command-key-pattern=R -d 32
        fi
        if [[ "$VER" != "v1" ]]; then
            _metrics_verified=0
            run_bench_custom true  "V2" 1 1 "single_conn_zadd" "${pipelines[@]}" \
                -- --command="ZADD __key__ 1 __data__" --command-key-pattern=R -d 32
        fi
    else
        if [[ "$VER" != "v2" ]]; then
            _metrics_verified=0
            run_bench false "V1" 1 1 2048 "single_conn" "${pipelines[@]}"
        fi
        if [[ "$VER" != "v1" ]]; then
            _metrics_verified=0
            run_bench true  "V2" 1 1 2048 "single_conn" "${pipelines[@]}"
        fi
    fi
}

# ---------- MODE: pubsub ----------
# 10 subscribers, 128-byte messages. Measures wakeup and reply batching.
run_pubsub() {
    local pipelines
    read -ra pipelines <<< "$(filter_pipelines 1 10 100 500)"
    if [[ "$VER" != "v2" ]]; then
        _metrics_verified=0
        run_pubsub_bench false "V1" 10 50000 "${pipelines[@]}"
    fi
    if [[ "$VER" != "v1" ]]; then
        _metrics_verified=0
        run_pubsub_bench true  "V2" 10 50000 "${pipelines[@]}"
    fi
}

# ---------- Main ----------
run_selected_modes() {
    case "$MODE" in
        multi_conn)    run_multi_conn ;;
        single_conn)   run_single_conn ;;
        pubsub)        run_pubsub ;;
        all)           run_multi_conn; run_single_conn; run_pubsub ;;
    esac
}

case "$MODE" in
    multi_conn|single_conn|pubsub|all)
        {
            for ((r=1; r<=RUNS; r++)); do
                [[ $RUNS -gt 1 ]] && echo "" && echo "############## Run $r / $RUNS ##############"
                run_selected_modes
            done
            print_final_report
        } 2>&1 | tee "$LOG_FILE"
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Valid: multi_conn | single_conn | pubsub | all"
        exit 1
        ;;
esac

echo ""
echo "[*] Benchmark results saved to: $LOG_FILE"
