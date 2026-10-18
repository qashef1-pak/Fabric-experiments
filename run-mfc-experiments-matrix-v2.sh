#!/usr/bin/env bash
#
# run-mfc-experiments-matrix.sh
#
# Runs the experiment matrix shown in the research design:
#
# EXPERIMENT 1
#   BatchSize: 10, 50, 100
#   Transaction workload: 1000, 5000, 8000
#
# EXPERIMENT 2
#   BatchSize: 10, 50, 100
#   Transaction workload: 1000, 5000, 8000
#
# EXPERIMENT 3
#   BatchSize: 10, 50, 100
#   Transaction workload: 1000, 5000, 8000
#
# Total runs = 3 experiments x 3 batch sizes x 3 transaction workloads = 27 runs.
#
# IMPORTANT:
# The transaction workload values are the Caliper txNumber values.
# Caliper workers are fixed separately at 5.
#
# Workers and target TPS are configurable through environment variables:
#   WORKERS=5 TX_LOAD=100 ./run-mfc-experiments-matrix.sh
#
# The script is based on the existing single-experiment runner, but
# automatically performs the complete matrix and preserves every report.

set -Eeuo pipefail

ROOT="${HOME}/fabric-samples/test-network"
CALIPER_DIR="${ROOT}/mfc-caliper/caliper-workspace"
CONFIGTX="${ROOT}/configtx/configtx.yaml"
BENCH="${CALIPER_DIR}/benchmarks/config.yaml"
NETWORK="${CALIPER_DIR}/networks/test-network.yaml"
CHAINCODE="${ROOT}/mfc-caliper/chaincode/mfc-contract"

CHANNEL="channel1"
CHAINCODE_NAME="mfc"

# Fixed experiment matrix from the research design.
EXPERIMENTS=(1 2 3)
BATCH_SIZES=(10 50 100)
PARALLEL_TXS=(1000 5000 8000)

# These are NOT changed by the matrix.
# Override them when required:
#   WORKERS=5 TX_LOAD=100 ./run-mfc-experiments-matrix.sh
WORKERS="${WORKERS:-5}"
TX_LOAD="${TX_LOAD:-100}"

REPORT="${CALIPER_DIR}/report.html"
REPORT_DIR="${CALIPER_DIR}/reports/matrix"

mkdir -p "$REPORT_DIR"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    echo
    echo "[$(timestamp)] $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

cleanup_on_error() {
    rc=$?
    echo
    echo "============================================================"
    echo " EXPERIMENT MATRIX STOPPED (exit code $rc)"
    echo "============================================================"
    echo "The last run may have left the Fabric network running."
    echo "Check the output above for the failed run."
    exit "$rc"
}

trap cleanup_on_error ERR

[[ -d "$ROOT" ]] || die "Fabric test-network not found: $ROOT"
[[ -d "$CALIPER_DIR" ]] || die "Caliper workspace not found: $CALIPER_DIR"
[[ -f "$CONFIGTX" ]] || die "configtx.yaml not found: $CONFIGTX"
[[ -f "$BENCH" ]] || die "Caliper benchmark config not found: $BENCH"
[[ -f "$NETWORK" ]] || die "Caliper network config not found: $NETWORK"
[[ -d "$CHAINCODE" ]] || die "JavaScript chaincode not found: $CHAINCODE"

[[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] || die "WORKERS must be a positive integer."
[[ "$TX_LOAD" =~ ^[1-9][0-9]*([.][0-9]+)?$ ]] || die "TX_LOAD must be a positive number."

cd "$ROOT"

echo "============================================================"
echo " MFC HYPERLEDGER FABRIC + CALIPER EXPERIMENT MATRIX"
echo "============================================================"
echo "Fabric root       : $ROOT"
echo "Caliper directory : $CALIPER_DIR"
echo "Chaincode         : $CHAINCODE"
echo
echo "Experiments       : 1 2 3"
echo "Batch sizes       : 10 50 100"
echo "Transactions      : 1000 5000 8000"
echo "Caliper workers   : $WORKERS"
echo "Target TPS        : $TX_LOAD"
echo "Total runs        : 27"
echo "============================================================"
echo

# Save original config files so the script can restore them at the end.
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
CONFIGTX_BACKUP="${REPORT_DIR}/configtx.yaml.${RUN_ID}.original"
BENCH_BACKUP="${REPORT_DIR}/config.yaml.${RUN_ID}.original"

cp "$CONFIGTX" "$CONFIGTX_BACKUP"
cp "$BENCH" "$BENCH_BACKUP"

restore_configs() {
    if [[ -f "$CONFIGTX_BACKUP" ]]; then
        cp "$CONFIGTX_BACKUP" "$CONFIGTX"
    fi
    if [[ -f "$BENCH_BACKUP" ]]; then
        cp "$BENCH_BACKUP" "$BENCH"
    fi
}

trap 'restore_configs' EXIT

run_one() {
    local EXPERIMENT="$1"
    local BATCH_SIZE="$2"
    local PARALLEL_TX="$3"

    local LABEL="exp${EXPERIMENT}_batch_${BATCH_SIZE}_parallel_${PARALLEL_TX}"
    local RUN_TS
    RUN_TS="$(date '+%Y%m%d_%H%M%S')"

    local FINAL_REPORT="${REPORT_DIR}/${LABEL}_${RUN_TS}.html"
    local METADATA="${REPORT_DIR}/${LABEL}_${RUN_TS}.txt"

    echo
    echo "============================================================"
    echo " EXPERIMENT ${EXPERIMENT} / BATCH ${BATCH_SIZE} / TX ${PARALLEL_TX}"
    echo "============================================================"
    echo "BatchSize             : $BATCH_SIZE"
    echo "Transaction workload  : $PARALLEL_TX"
    echo "Caliper txNumber      : $PARALLEL_TX"
    echo "Caliper workers       : $WORKERS"
    echo "Target send rate      : $TX_LOAD TPS"
    echo "Label                 : $LABEL"
    echo "============================================================"

    log "Updating Fabric BatchSize to $BATCH_SIZE..."
    python3 - "$CONFIGTX" "$BATCH_SIZE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
new_value = sys.argv[2]
text = path.read_text()

pattern = r'(?m)^(\s*MaxMessageCount:\s*)\d+\s*$'
new_text, count = re.subn(pattern, rf'\g<1>{new_value}', text, count=1)

if count != 1:
    raise SystemExit("Could not find exactly one MaxMessageCount entry in configtx.yaml")

path.write_text(new_text)
PY

    log "Updating Caliper benchmark..."
    python3 - "$BENCH" "$LABEL" "$PARALLEL_TX" "$WORKERS" "$TX_LOAD" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
label = sys.argv[2]
tx_number = sys.argv[3]
workers = sys.argv[4]
tx_load = sys.argv[5]

text = path.read_text()

text, n = re.subn(
    r'(?m)^(\s*-\s*label:\s*).*$',
    rf'\g<1>{label}',
    text,
    count=1
)
if n != 1:
    raise SystemExit("Could not find Caliper round label.")

text, n = re.subn(
    r'(?m)^(\s*txNumber:\s*)\d+\s*$',
    rf'\g<1>{tx_number}',
    text,
    count=1
)
if n != 1:
    raise SystemExit("Could not find txNumber.")

text, n = re.subn(
    r'(?m)^(\s*number:\s*)\d+\s*$',
    rf'\g<1>{workers}',
    text,
    count=1
)
if n != 1:
    raise SystemExit("Could not find workers.number.")

text, n = re.subn(
    r'(?m)^(\s*transactionLoad:\s*)[0-9.]+\s*$',
    rf'\g<1>{tx_load}',
    text,
    count=1
)
if n != 1:
    raise SystemExit("Could not find transactionLoad.")

path.write_text(text)
PY

    log "Stopping existing Fabric network..."
    "$ROOT/network.sh" down

    log "Starting fresh Fabric network and creating channel..."
    "$ROOT/network.sh" up createChannel -c "$CHANNEL" -s couchdb

    log "Deploying JavaScript MFC chaincode..."
    "$ROOT/network.sh" deployCC \
        -c "$CHANNEL" \
        -ccn "$CHAINCODE_NAME" \
        -ccp "$CHAINCODE" \
        -ccl javascript

    log "Verifying committed chaincode..."
    peer lifecycle chaincode querycommitted \
        -C "$CHANNEL" \
        -n "$CHAINCODE_NAME"

    log "Removing previous Caliper report..."
    rm -f "$REPORT"

    log "Running Caliper..."
    (
        cd "$CALIPER_DIR"
        npx caliper launch manager \
            --caliper-workspace . \
            --caliper-networkconfig networks/test-network.yaml \
            --caliper-benchconfig benchmarks/config.yaml \
            --caliper-flow-only-test
    )

    [[ -f "$REPORT" ]] || die "Caliper completed but report.html was not found."

    cp "$REPORT" "$FINAL_REPORT"

    cat > "$METADATA" <<EOF
MFC Caliper Experiment
======================

Experiment: $EXPERIMENT
Run ID: $RUN_TS
Date: $(date '+%Y-%m-%d %H:%M:%S %Z')

Experiment Matrix
-----------------
BatchSize: $BATCH_SIZE
Transaction workload: $PARALLEL_TX
Caliper txNumber: $PARALLEL_TX

Caliper Runtime
---------------
Workers: $WORKERS
Target send rate (TPS): $TX_LOAD

Fabric
------
Channel: $CHANNEL
Chaincode: $CHAINCODE_NAME
Chaincode language: javascript
BatchTimeout: $(grep -E '^[[:space:]]*BatchTimeout:' "$CONFIGTX" | head -1 | awk '{print $2}')

Files
-----
Benchmark config: $BENCH
Network config: $NETWORK
Chaincode: $CHAINCODE
Report: $FINAL_REPORT
EOF

    echo
    echo "SUCCESS: $LABEL"
    echo "Report:   $FINAL_REPORT"
    echo "Metadata: $METADATA"
}

RUN_COUNT=0

for EXPERIMENT in "${EXPERIMENTS[@]}"; do
    for BATCH_SIZE in "${BATCH_SIZES[@]}"; do
        for PARALLEL_TX in "${PARALLEL_TXS[@]}"; do
            RUN_COUNT=$((RUN_COUNT + 1))

            echo
            echo "############################################################"
            echo " RUN $RUN_COUNT / 27"
            echo "############################################################"

            run_one "$EXPERIMENT" "$BATCH_SIZE" "$PARALLEL_TX"
        done
    done
done

echo
echo "============================================================"
echo " ALL 27 EXPERIMENT RUNS COMPLETED"
echo "============================================================"
echo
echo "Reports:"
find "$REPORT_DIR" -maxdepth 1 -type f -name '*.html' -print | sort
echo
echo "Metadata:"
find "$REPORT_DIR" -maxdepth 1 -type f -name '*.txt' -print | sort
echo
echo "Original configuration backups:"
echo "  $CONFIGTX_BACKUP"
echo "  $BENCH_BACKUP"
echo
echo "Note: original configtx.yaml and Caliper config.yaml"
echo "have been restored automatically."
echo "============================================================"
