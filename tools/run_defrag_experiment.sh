#!/usr/bin/env bash
# run_defrag_experiment.sh — run a full defrag experiment end-to-end
#
# Usage: ./tools/run_defrag_experiment.sh <true|false> [--help]
#   true  = phased algorithm  (CENSUS -> SELECT_TARGETS -> EVACUATE -> VERIFY)
#   false = legacy algorithm  (single-pass)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRAGONFLY="${REPO_ROOT}/build-opt/dragonfly"
TOOLS_DIR="${REPO_ROOT}/tools"
RUNS_DIR="${REPO_ROOT}/runs"

# ── Hardcoded parameters ──────────────────────────────────────────────────────
PORT=6379
WORKLOAD="wide"        # uniform | wide
MUL=20                 # scale key count by this multiplier
CYCLES=100             # max MEMORY DEFRAGMENT calls
TARGET_WASTE=5         # stop when arena waste_pct <= this percent
SLEEP_MS=200           # ms between defrag calls
LOG_PATH="/tmp/dragonfly.INFO"
# Dragonfly runs on a single core so defrag logs are easy to parse (one shard).
# Client gets 1 core — it's mostly idle anyway.
DF_CORES=1
CLIENT_CORES=1
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 <true|false> [--help]

Run a complete defrag experiment in three steps:
  1. Start Dragonfly (${DRAGONFLY})
  2. Create fragmentation baseline (defrag_baseline.py)
  3. Drive and record defrag (defrag_drive.py)

Arguments:
  true    Phased algorithm  --experimental_defrag=true
  false   Legacy algorithm  --experimental_defrag=false

Hardcoded settings:
  Dragonfly binary : ${DRAGONFLY}
  Port             : ${PORT}
  Workload         : ${WORKLOAD}
  Key multiplier   : ${MUL}x
  Max cycles       : ${CYCLES}
  Target waste     : ${TARGET_WASTE}%
  Sleep between    : ${SLEEP_MS}ms
  Log path         : ${LOG_PATH}
  Client cores     : last ${CLIENT_CORES} cores (rest go to Dragonfly)
  Output dir       : ${RUNS_DIR}/

Output JSONL is written to:
  phased -> ${RUNS_DIR}/phased_${WORKLOAD}.jsonl
  legacy -> ${RUNS_DIR}/legacy_${WORKLOAD}.jsonl
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

EXPERIMENTAL="$1"
if [[ "${EXPERIMENTAL}" != "true" && "${EXPERIMENTAL}" != "false" ]]; then
    echo "error: first argument must be 'true' or 'false', got '${EXPERIMENTAL}'"
    exit 1
fi

MODE=$( [[ "${EXPERIMENTAL}" == "true" ]] && echo "phased" || echo "legacy" )
OUTPUT="${RUNS_DIR}/${MODE}_${WORKLOAD}.jsonl"

# ── CPU pinning ───────────────────────────────────────────────────────────────
# Dragonfly on core 0, client on core 1. Single-shard makes logs trivial to read.
DF_CORE_LIST="0"
CLIENT_CORE_LIST="1"
echo "cpu_pinning: dragonfly=${DF_CORE_LIST} (${DF_CORES} cores)  client=${CLIENT_CORE_LIST} (${CLIENT_CORES} cores)"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [[ ! -x "${DRAGONFLY}" ]]; then
    echo "error: dragonfly binary not found or not executable: ${DRAGONFLY}"
    echo "       build it with: ninja -C build-opt dragonfly"
    exit 1
fi

if ! command -v redis-cli &>/dev/null; then
    echo "error: redis-cli not found in PATH (needed for readiness check)"
    exit 1
fi

# Check nothing is already accepting connections on the port
if redis-cli -p "${PORT}" ping 2>/dev/null | grep -q PONG; then
    echo "error: port ${PORT} is already in use — is dragonfly or another server running?"
    echo "       stop it first, or change PORT in this script"
    exit 1
fi

mkdir -p "${RUNS_DIR}"

# aioredis 2.x has a duplicate-base-class bug on Python 3.12+ where
# asyncio.TimeoutError became an alias for builtins.TimeoutError.
# Patch the installed exceptions.py in-place without touching the script.
python3 - <<'PYEOF'
import sys, importlib.util, pathlib

spec = importlib.util.find_spec("aioredis")
if spec is None:
    print("error: aioredis not installed", file=sys.stderr)
    sys.exit(1)

exc_file = pathlib.Path(spec.origin).parent / "exceptions.py"
original = exc_file.read_text()
old = "class TimeoutError(asyncio.TimeoutError, builtins.TimeoutError, RedisError):"
new = "class TimeoutError(*dict.fromkeys([asyncio.TimeoutError, builtins.TimeoutError]), RedisError):"
if old in original:
    exc_file.write_text(original.replace(old, new))
    print("patched aioredis/exceptions.py for Python 3.12 compatibility")

# Verify it actually imports now.
try:
    import aioredis  # noqa: F401
except Exception as e:
    print(f"error: aioredis still broken after patch: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

echo "=== defrag experiment: mode=${MODE}  workload=${WORKLOAD}  mul=${MUL}x ==="

# ── Step 1: Start Dragonfly ───────────────────────────────────────────────────
echo ""
echo "[1/3] starting dragonfly (mode=${MODE}) on port ${PORT} ..."

EXTRA_FLAGS=(
    # Disable the per-shard minimum-reclaimable guard so EVACUATE runs even
    # when per-shard fragmentation is small (e.g. 433MiB / 14 shards ≈ 30MiB,
    # which would be blocked by the default 64MiB threshold).
    --defrag_min_plan_reclaimable_bytes=0
    # Disable RDB snapshot on shutdown to avoid "direct I/O not supported"
    # warnings on encrypted filesystems.
    --dbfilename ""
)

taskset -c "${DF_CORE_LIST}" \
"${DRAGONFLY}" \
    --alsologtostderr \
    --experimental_defrag="${EXPERIMENTAL}" \
    --enable_bg_defrag=false \
    --proactor_threads="${DF_CORES}" \
    --port="${PORT}" \
    "${EXTRA_FLAGS[@]}" &
DF_PID=$!

cleanup() {
    echo ""
    echo "stopping dragonfly (pid=${DF_PID}) ..."
    kill "${DF_PID}" 2>/dev/null || true
    # Give it up to 5s to exit cleanly, then SIGKILL
    for _i in $(seq 1 10); do
        sleep 0.5
        if ! kill -0 "${DF_PID}" 2>/dev/null; then
            break
        fi
        if [[ ${_i} -eq 10 ]]; then
            echo "dragonfly did not exit cleanly, sending SIGKILL ..."
            kill -9 "${DF_PID}" 2>/dev/null || true
        fi
    done
    wait "${DF_PID}" 2>/dev/null || true
    # Verify the port is free before returning
    for _i in $(seq 1 10); do
        if ! redis-cli -p "${PORT}" ping 2>/dev/null | grep -q PONG; then
            echo "port ${PORT} is free"
            return
        fi
        sleep 0.5
    done
    echo "warning: port ${PORT} may still be in use after shutdown"
}
trap cleanup EXIT

echo "waiting for dragonfly to be ready ..."
for i in $(seq 1 30); do
    if redis-cli -p "${PORT}" ping 2>/dev/null | grep -q PONG; then
        echo "dragonfly ready (${i} probes)"
        break
    fi
    if [[ ${i} -eq 30 ]]; then
        echo "error: dragonfly did not respond within 15s"
        exit 1
    fi
    sleep 0.5
done

# ── Step 2: Create fragmentation baseline ────────────────────────────────────
echo ""
echo "[2/3] creating fragmentation baseline (workload=${WORKLOAD} mul=${MUL}x) ..."
taskset -c "${CLIENT_CORE_LIST}" \
python3 "${TOOLS_DIR}/defrag_baseline.py" \
    --workload "${WORKLOAD}" \
    --mul      "${MUL}"      \
    --port     "${PORT}"     \
    --arena

# ── Step 3: Drive defrag ─────────────────────────────────────────────────────
echo ""
echo "[3/3] driving defrag (cycles=${CYCLES} target-waste=${TARGET_WASTE}% output=${OUTPUT}) ..."
taskset -c "${CLIENT_CORE_LIST}" \
python3 "${TOOLS_DIR}/defrag_drive.py" \
    --cycles       "${CYCLES}"       \
    --target-waste "${TARGET_WASTE}" \
    --sleep-ms     "${SLEEP_MS}"     \
    --log-path     "${LOG_PATH}"     \
    --port         "${PORT}"         \
    --output       "${OUTPUT}"

echo ""
echo "=== done: results written to ${OUTPUT} ==="
