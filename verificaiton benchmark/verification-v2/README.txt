MFC VERIFICATION BENCHMARK V2
=============================

Total runs:
16

Worker levels:
5, 10, 50, 100

Verification loads:
10000, 25000, 50000, 100000

Workers tested:
5, 10, 50, 100

Target TPS:
100

Operation:
QueryMFC(reportId)

Channel:
channel1

Chaincode:
mfc

Report ID:
MFC-2026-000146

The benchmark measures the read-only MFC verification/query path.

QueryMFC is evaluated with readOnly=true. It does not submit a
transaction to the ordering service and therefore does not create
a new Fabric block.

Output directories:
  verification_v2_workers<workers>_load<load>_run<run>/
