#!/usr/bin/env bash
set -Eeuo pipefail

# ================================================================
# MFC VERIFICATION BENCHMARK - V3
#
# Benchmarks the READ / VERIFICATION path of the deployed MFC
# chaincode using Hyperledger Caliper.
#
# Existing network from the supplied experiment script:
#   Fabric root : ~/fabric-samples/test-network
#   Channel     : channel1
#   Chaincode   : mfc
#   Caliper     : ~/fabric-samples/test-network/mfc-caliper/caliper-workspace
#
# Verification function:
#   QueryMFC(reportId)
#
# Loads:
#   1,000 / 5,000 / 8,000 verification requests
#
# Repetitions:
#   3 repetitions for each load = 9 runs total
#
# IMPORTANT:
#   QueryMFC is READ-ONLY. It does not go to the ordering service
#   and does not create a new Fabric block.
#
# This benchmark therefore measures:
#   - verification/read throughput
#   - verification/read latency
#   - successful/failed verification requests
#
# It does NOT measure block generation.
#
# No scripts/envVar.sh is used.
# ================================================================

ROOT="${ROOT:-$HOME/fabric-samples/test-network}"
CALIPER_DIR="${CALIPER_DIR:-$ROOT/mfc-caliper/caliper-workspace}"
CHANNEL="${CHANNEL:-channel1}"
CC_NAME="${CC_NAME:-mfc}"
NETWORK="${NETWORK:-$CALIPER_DIR/networks/test-network.yaml}"

# Existing MFC record that will be repeatedly verified.
REPORT_ID="${REPORT_ID:-MFC-2026-000146}"

# Keep this consistent with your earlier Caliper experiments by default.
WORKERS="${WORKERS:-10}"
# Stress/saturation target send rates (TPS).
# Each rate is tested independently against the same read-only verification path.
STRESS_RATES=(100 500 1000 2000 3000 5000)

# Transactions per stress point. Override with TX_LOAD if required.
TX_LOAD="${TX_LOAD:-50000}"

# Optional repetitions for each rate. Default 1 to limit total benchmark time.
EXPERIMENTS=(1)

REPORT="${CALIPER_DIR}/report.html"
OUT_ROOT="${OUT_ROOT:-$ROOT/mfc-caliper/reports/verification-v3}"

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

for c in node npm npx jq peer find awk grep python3; do
    need_cmd "$c"
done

[[ -d "$ROOT" ]] ||
    die "Fabric test-network not found: $ROOT"

[[ -d "$CALIPER_DIR" ]] ||
    die "Caliper workspace not found: $CALIPER_DIR"

[[ -f "$NETWORK" ]] ||
    die "Caliper network configuration not found: $NETWORK"

[[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] ||
    die "WORKERS must be a positive integer."

[[ "$TX_LOAD" =~ ^[1-9][0-9]*$ ]] ||
    die "TX_LOAD must be a positive integer."

mkdir -p "$OUT_ROOT"

# ----------------------------------------------------------------
# Automatically discover the existing Org1 Admin identity.
# This follows the successful discovery approach used by your
# previous MFC payload scripts and does not assume cert.pem.
# ----------------------------------------------------------------
ORG1_DOMAIN="${ORG1_DOMAIN:-org1.example.com}"
ORG1_MSP="${ORG1_MSP:-Org1MSP}"
ORG1_PEER="${ORG1_PEER:-peer0.org1.example.com}"
ORG1_ADDRESS="${ORG1_ADDRESS:-localhost:7051}"

ORG1_DIR="$ROOT/organizations/peerOrganizations/$ORG1_DOMAIN"
ADMIN_MSP="$ORG1_DIR/users/Admin@$ORG1_DOMAIN/msp"

[[ -d "$ADMIN_MSP" ]] ||
    die "Org1 Admin MSP not found: $ADMIN_MSP"

ADMIN_CERT="$(
    find "$ADMIN_MSP/signcerts" \
        -maxdepth 1 \
        -type f \
        -name '*.pem' \
        -print -quit
)"

PRIVATE_KEY="$(
    find "$ADMIN_MSP/keystore" \
        -maxdepth 1 \
        -type f \
        \( -name '*_sk' -o -name '*.pem' -o -name '*.key' \) \
        -print -quit
)"

TLS_CA="$ORG1_DIR/peers/$ORG1_PEER/tls/ca.crt"

[[ -n "$ADMIN_CERT" ]] ||
    die "Org1 Admin certificate could not be discovered."

[[ -n "$PRIVATE_KEY" ]] ||
    die "Org1 Admin private key could not be discovered."

[[ -f "$TLS_CA" ]] ||
    die "Org1 peer TLS CA not found: $TLS_CA"

# ----------------------------------------------------------------
# Caliper Fabric SDK binding repair
#
# Caliper's FabricConnectorFactory refuses to run when BOTH
#   @hyperledger/fabric-gateway
# and
#   fabric-network
# are visible to the same Caliper process.
#
# Your Fabric 2.2 environment uses fabric-network@2.2.x, so this
# benchmark deliberately keeps ONLY the Fabric 2.2 binding.
#
# Caliper officially supports bind/unbind for switching SDK bindings.
# We first remove both possible Fabric bindings, then bind only
# fabric:2.2.
# ----------------------------------------------------------------
log "Checking Caliper Fabric SDK bindings..."

FABRIC_NETWORK_PRESENT=0
FABRIC_GATEWAY_PRESENT=0

if node -e "require.resolve('fabric-network/package.json')" >/dev/null 2>&1; then
    FABRIC_NETWORK_PRESENT=1
fi

if node -e "require.resolve('@hyperledger/fabric-gateway/package.json')" >/dev/null 2>&1; then
    FABRIC_GATEWAY_PRESENT=1
fi

echo "Detected fabric-network     : $FABRIC_NETWORK_PRESENT"
echo "Detected fabric-gateway     : $FABRIC_GATEWAY_PRESENT"

if [[ "$FABRIC_NETWORK_PRESENT" -eq 1 && "$FABRIC_GATEWAY_PRESENT" -eq 1 ]]; then
    log "Multiple Fabric SDK bindings detected."
    log "Cleaning Fabric bindings and installing ONLY fabric:2.2..."

    cd "$CALIPER_DIR"

    # Remove any previous Caliper binding from the workspace.
    # --ignore-scripts is intentionally NOT used because npm must
    # perform normal dependency cleanup.
    set +e
    npx caliper unbind \
        --caliper-bind-sut fabric:2.2 \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save" >/dev/null 2>&1

    npx caliper unbind \
        --caliper-bind-sut fabric:fabric-gateway \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save" >/dev/null 2>&1

    # Explicitly remove the gateway package if it remains visible.
    npm uninstall @hyperledger/fabric-gateway --save >/dev/null 2>&1

    # Explicitly remove fabric-network too so the following bind
    # recreates a single clean, known version.
    npm uninstall fabric-network --save >/dev/null 2>&1
    set -e

    log "Binding Caliper to Fabric 2.2..."
    npx caliper bind \
        --caliper-bind-sut fabric:2.2 \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save"

elif [[ "$FABRIC_NETWORK_PRESENT" -eq 0 && "$FABRIC_GATEWAY_PRESENT" -eq 1 ]]; then
    log "Only fabric-gateway binding detected."
    log "Switching to the Fabric 2.2 fabric-network binding..."

    cd "$CALIPER_DIR"

    set +e
    npx caliper unbind \
        --caliper-bind-sut fabric:fabric-gateway \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save" >/dev/null 2>&1
    npm uninstall @hyperledger/fabric-gateway --save >/dev/null 2>&1
    set -e

    npx caliper bind \
        --caliper-bind-sut fabric:2.2 \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save"

elif [[ "$FABRIC_NETWORK_PRESENT" -eq 0 && "$FABRIC_GATEWAY_PRESENT" -eq 0 ]]; then
    log "No Fabric SDK binding detected."
    log "Binding Caliper to Fabric 2.2..."

    cd "$CALIPER_DIR"

    npx caliper bind \
        --caliper-bind-sut fabric:2.2 \
        --caliper-bind-cwd "$CALIPER_DIR" \
        --caliper-bind-args="--save"
fi

# Verify the final binding state.
FABRIC_NETWORK_PRESENT=0
FABRIC_GATEWAY_PRESENT=0

if node -e "require.resolve('fabric-network/package.json')" >/dev/null 2>&1; then
    FABRIC_NETWORK_PRESENT=1
fi

if node -e "require.resolve('@hyperledger/fabric-gateway/package.json')" >/dev/null 2>&1; then
    FABRIC_GATEWAY_PRESENT=1
fi

echo
echo "Final Caliper Fabric SDK state:"
echo "  fabric-network : $FABRIC_NETWORK_PRESENT"
echo "  fabric-gateway : $FABRIC_GATEWAY_PRESENT"

[[ "$FABRIC_NETWORK_PRESENT" -eq 1 ]] ||
    die "fabric-network is not installed after Caliper Fabric 2.2 binding."

[[ "$FABRIC_GATEWAY_PRESENT" -eq 0 ]] ||
    die "Both Fabric SDK bindings are still visible. Refusing to run benchmark."

FABRIC_NETWORK_VERSION="$(
    node -e "console.log(require('fabric-network/package.json').version)"
)"

echo "  fabric-network version: $FABRIC_NETWORK_VERSION"

[[ "$FABRIC_NETWORK_VERSION" == 2.* ]] ||
    die "Expected fabric-network 2.x for Fabric 2.2 benchmark, found $FABRIC_NETWORK_VERSION."

# ----------------------------------------------------------------
# Fabric CLI environment
# ----------------------------------------------------------------
export FABRIC_CFG_PATH="$ROOT/../config"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="$ORG1_MSP"
export CORE_PEER_MSPCONFIGPATH="$ADMIN_MSP"
export CORE_PEER_ADDRESS="$ORG1_ADDRESS"
export CORE_PEER_TLS_ROOTCERT_FILE="$TLS_CA"

log "Checking Fabric peer connectivity..."
peer channel list >/dev/null ||
    die "Cannot communicate with Org1 peer."

log "Checking channel membership..."
peer channel list | grep -qx "$CHANNEL" ||
    die "Org1 peer has not joined channel '$CHANNEL'."

log "Checking committed chaincode..."
peer lifecycle chaincode querycommitted \
    -C "$CHANNEL" \
    -n "$CC_NAME" >/dev/null ||
    die "Chaincode '$CC_NAME' is not committed on '$CHANNEL'."

# ----------------------------------------------------------------
# Verify that the MFC record exists BEFORE starting Caliper.
# The benchmark deliberately does not recreate/reset the network.
# ----------------------------------------------------------------
FIXTURE_DIR="$OUT_ROOT/fixture"
mkdir -p "$FIXTURE_DIR"

QUERY_RAW="$FIXTURE_DIR/query-before-benchmark.txt"

log "Checking MFC record: $REPORT_ID"

set +e
peer chaincode query \
    -C "$CHANNEL" \
    -n "$CC_NAME" \
    -c "{\"function\":\"QueryMFC\",\"Args\":[\"$REPORT_ID\"]}" \
    > "$QUERY_RAW" 2>&1
QUERY_RC=$?
set -e

cat "$QUERY_RAW"

if [[ "$QUERY_RC" -ne 0 ]]; then
    die "MFC record '$REPORT_ID' does not exist. Create and commit an MFC record first, then rerun this benchmark."
fi

# Save the actual committed MFC record used by the benchmark.
python3 - "$QUERY_RAW" "$FIXTURE_DIR/mfc-record.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text().strip()
output = Path(sys.argv[2])

start = source.find("{")
end = source.rfind("}")

if start < 0 or end <= start:
    raise SystemExit("QueryMFC did not return a JSON object.")

record = json.loads(source[start:end + 1])
output.write_text(json.dumps(record, indent=2))
PY

jq -e '.reportId and .hash and .digitalSignature and .timestamp' \
    "$FIXTURE_DIR/mfc-record.json" >/dev/null ||
    die "The committed MFC record is missing expected verification fields."

# ----------------------------------------------------------------
# Create a dedicated Caliper workload module.
#
# Caliper's Fabric connector supports:
#   readOnly: true
#
# This causes QueryMFC to be evaluated as a query rather than
# submitted as a transaction. Therefore it does not create blocks.
# ----------------------------------------------------------------
WORKLOAD_DIR="$CALIPER_DIR/workload-verification-v3"
mkdir -p "$WORKLOAD_DIR"

cat > "$WORKLOAD_DIR/mfc-verification.js" <<'NODE'
'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class MFCVerificationWorkload extends WorkloadModuleBase {

    constructor() {
        super();
        this.txIndex = 0;
    }

    async initializeWorkloadModule(
        workerIndex,
        totalWorkers,
        roundIndex,
        roundArguments,
        sutAdapter,
        sutContext
    ) {
        await super.initializeWorkloadModule(
            workerIndex,
            totalWorkers,
            roundIndex,
            roundArguments,
            sutAdapter,
            sutContext
        );

        this.workerIndex = workerIndex;
        this.reportId =
            roundArguments.reportId ||
            process.env.MFC_REPORT_ID ||
            'MFC-2026-000146';
    }

    async submitTransaction() {

        const request = {
            contractId: 'mfc',
            contractFunction: 'QueryMFC',
            invokerIdentity: 'User1',
            contractArguments: [this.reportId],

            // CRITICAL:
            // QueryMFC is read-only and therefore does not create
            // an ordering transaction or a new Fabric block.
            readOnly: true
        };

        this.txIndex++;

        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        // No cleanup is required because QueryMFC does not modify
        // the ledger.
    }
}

function createWorkloadModule() {
    return new MFCVerificationWorkload();
}

module.exports.createWorkloadModule = createWorkloadModule;
NODE

# ----------------------------------------------------------------
# Dedicated benchmark directory. Existing benchmark files are not
# modified.
# ----------------------------------------------------------------
BENCH_DIR="$CALIPER_DIR/benchmarks/verification-v3"
mkdir -p "$BENCH_DIR"

BENCH="$BENCH_DIR/config.yaml"

# ----------------------------------------------------------------
# Run one verification experiment.
# ----------------------------------------------------------------
run_one() {

    local EXPERIMENT="$1"
    local RATE="$2"
    local LOAD="$TX_LOAD"

    local RUN_TS
    RUN_TS="$(date '+%Y%m%d_%H%M%S')"

    local LABEL
    LABEL="verification_stress_exp${EXPERIMENT}_rate${RATE}_load${LOAD}"

    local FINAL_DIR
    FINAL_DIR="$OUT_ROOT/$LABEL"

    mkdir -p "$FINAL_DIR"

    log "============================================================"
    log "MFC VERIFICATION BENCHMARK"
    log "Run                : $LABEL"
    log "Experiment         : $EXPERIMENT"
    log "Verification load : $LOAD"
    log "Workers            : $WORKERS"
    log "Target TPS         : $RATE"
    log "Report ID          : $REPORT_ID"
    log "============================================================"

    # Generate a dedicated benchmark configuration for this run.
    cat > "$BENCH" <<YAML
test:
  name: mfc-verification-v3
  description: MFC QueryMFC read-only verification benchmark

  workers:
    number: ${WORKERS}

  rounds:
    - label: ${LABEL}
      description: QueryMFC read-only verification workload
      txNumber: ${LOAD}

      rateControl:
        type: fixed-rate
        opts:
          tps: ${RATE}

      workload:
        module: ${WORKLOAD_DIR}/mfc-verification.js
        arguments:
          reportId: "${REPORT_ID}"
          contractId: "${CC_NAME}"

YAML

    rm -f "$REPORT"

    log "Starting Caliper..."

    (
        cd "$CALIPER_DIR"

        export MFC_REPORT_ID="$REPORT_ID"

        npx caliper launch manager \
            --caliper-workspace "$CALIPER_DIR" \
            --caliper-networkconfig "$NETWORK" \
            --caliper-benchconfig "$BENCH" \
            --caliper-flow-only-test
    )

    [[ -f "$REPORT" ]] ||
        die "Caliper completed but report.html was not generated for $LABEL."

    # Preserve the report independently for research analysis.
    cp "$REPORT" "$FINAL_DIR/report.html"

    # Preserve exact benchmark settings.
    cp "$BENCH" "$FINAL_DIR/benchmark-config.yaml"

    # Preserve the actual MFC state used for the verification run.
    cp "$FIXTURE_DIR/mfc-record.json" \
        "$FINAL_DIR/mfc-record-used-for-verification.json"

    # Capture channel information after the read-only benchmark.
    # The height should normally be unchanged by QueryMFC itself.
    peer channel getinfo \
        -c "$CHANNEL" \
        > "$FINAL_DIR/blockchain-info-after-run.txt" 2>&1 || true

    cat > "$FINAL_DIR/metadata.txt" <<EOF
MFC Verification Benchmark
==========================

Experiment:
$EXPERIMENT

Run:
$LABEL

Run timestamp:
$RUN_TS

Operation:
QueryMFC(reportId)

Report ID:
$REPORT_ID

Verification requests:
$LOAD

Workers:
$WORKERS

Target TPS:
$RATE

Fabric channel:
$CHANNEL

Chaincode:
$CC_NAME

Peer:
$ORG1_PEER

Peer address:
$ORG1_ADDRESS

Important:
QueryMFC is read-only. These verification requests do not go
through the ordering service and do not create new Fabric blocks.

The MFC record was confirmed to exist before the benchmark.
EOF

    log "Completed: $LABEL"
    log "Report saved to: $FINAL_DIR/report.html"
}

# ----------------------------------------------------------------
# Execute stress/saturation experiments.
# Target rates: 100, 500, 1000, 2000, 3000, 5000 TPS.
# ----------------------------------------------------------------
RUN_COUNT=0

for EXPERIMENT in "${EXPERIMENTS[@]}"; do
    for RATE in "${STRESS_RATES[@]}"; do
        RUN_COUNT=$((RUN_COUNT + 1))
        run_one "$EXPERIMENT" "$RATE"
    done
done

# ----------------------------------------------------------------
# Final benchmark summary.
# ----------------------------------------------------------------
cat > "$OUT_ROOT/README.txt" <<EOF
MFC VERIFICATION BENCHMARK V3 - STRESS/SATURATION
=============================

Total runs:
$RUN_COUNT

Experiments / repetitions per rate:
${#EXPERIMENTS[@]}

Verification transactions per rate:
$TX_LOAD

Workers:
$WORKERS

Target TPS:
$RATE

Operation:
QueryMFC(reportId)

Channel:
$CHANNEL

Chaincode:
$CC_NAME

Report ID:
$REPORT_ID

The benchmark measures the read-only MFC verification/query path.

QueryMFC is evaluated with readOnly=true. It does not submit a
transaction to the ordering service and therefore does not create
a new Fabric block.

Output directories:
  verification_exp1_load1000/
  verification_exp1_load5000/
  verification_exp1_load8000/
  verification_exp2_load1000/
  verification_exp2_load5000/
  verification_exp2_load8000/
  verification_exp3_load1000/
  verification_exp3_load5000/
  verification_exp3_load8000/
EOF

echo
echo "=============================================================="
echo " MFC VERIFICATION BENCHMARK COMPLETED"
echo "=============================================================="
echo
echo "Total runs : $RUN_COUNT"
echo "Rates      : 100, 500, 1000, 2000, 3000, 5000 TPS"
echo "Workers    : $WORKERS"
echo "TX Load    : $TX_LOAD per stress point"
echo "Report ID  : $REPORT_ID"
echo
echo "Output:"
echo "  $OUT_ROOT"
echo
echo "QueryMFC is READ-ONLY and does not create new Fabric blocks."
echo "=============================================================="
