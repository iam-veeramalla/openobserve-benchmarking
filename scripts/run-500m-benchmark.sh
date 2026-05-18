#!/usr/bin/env bash
# Phase 2: monitor ingestion and run query benchmark when 500M is reached.
# Data already cleared and logstorm already restarted before this script runs.
# Safe to run fully unattended - no interactive prompts.

KUBECONFIG_FILE="$HOME/.kube/eks-benchmark.yaml"
export KUBECONFIG="$KUBECONFIG_FILE"
LOGFILE="/tmp/benchmark-500m.log"
TARGET=300000000
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

cd "$WORKDIR"
log "===== 500M Monitor + Benchmark Starting ====="

restart_portforwards() {
    pkill -f "port-forward.*5080:5080" 2>/dev/null || true
    pkill -f "port-forward.*9200:9200" 2>/dev/null || true
    sleep 2
    kubectl --kubeconfig "$KUBECONFIG_FILE" port-forward \
        -n openobserve svc/openobserve 5080:5080 >>/tmp/pf-o2.log 2>&1 &
    kubectl --kubeconfig "$KUBECONFIG_FILE" port-forward \
        -n opensearch svc/opensearch 9200:9200 >>/tmp/pf-os.log 2>&1 &
    sleep 5
}

# Ensure port-forwards are alive at start
restart_portforwards
log "Port-forwards started"

# ── Poll until OpenObserve reaches 300M ─────────────────────────────────────
log "Polling until OpenObserve hits 300M (check every 60s)..."
O2_DONE=false

while [[ "$O2_DONE" == "false" ]]; do
    sleep 60

    # Restart port-forwards if dead
    if ! curl -s --max-time 3 http://localhost:9200/ >/dev/null 2>&1 || \
       ! curl -s --max-time 3 -u root@benchmark.local:BenchmarkPass123! \
            http://localhost:5080/api/default/streams >/dev/null 2>&1; then
        log "Port-forward(s) dead, restarting..."
        restart_portforwards
    fi

    NOW=$(python3 -c 'import time; print(int(time.time()*1000000))')
    START=$(python3 -c 'import time; print(int((time.time()-7200)*1000000))')

    O2_COUNT=$(curl -s --max-time 10 \
        -u 'root@benchmark.local:BenchmarkPass123!' \
        -H 'Content-Type: application/json' \
        -d "{\"query\":{\"sql\":\"SELECT COUNT(*) as c FROM default\",\"start_time\":$START,\"end_time\":$NOW}}" \
        'http://localhost:5080/api/default/_search' \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['hits'][0]['c'])" 2>/dev/null || echo 0)

    OS_COUNT=$(curl -s --max-time 10 \
        'http://localhost:9200/logstorm/_stats/docs' \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['_all']['total']['docs']['count'])" 2>/dev/null || echo 0)

    O2_PCT=$(python3 -c "print(f'{int(\"$O2_COUNT\")/$TARGET*100:.1f}')" 2>/dev/null || echo "?")

    log "Progress -> OpenObserve: $O2_COUNT ($O2_PCT%)  |  OpenSearch: $OS_COUNT (informational)"

    [[ "${O2_COUNT:-0}" -ge "$TARGET" ]] && O2_DONE=true
done

log "OpenObserve reached 300M!"

# ── Restore OpenSearch refresh before benchmarking ──────────────────────────
log "Restoring OpenSearch refresh_interval to 5s..."
curl -s -X PUT http://localhost:9200/logstorm/_settings \
    -H 'Content-Type: application/json' \
    -d '{"index":{"refresh_interval":"5s"}}' >> "$LOGFILE"
echo "" >> "$LOGFILE"
curl -s -X POST http://localhost:9200/logstorm/_refresh >> "$LOGFILE"
echo "" >> "$LOGFILE"
sleep 15

# ── Run query benchmark ──────────────────────────────────────────────────────
log "Running query benchmark..."
RESULTS_FILE="$WORKDIR/results/query_benchmark_300m_$(date '+%Y%m%d_%H%M%S').txt"
python3 "$WORKDIR/benchmark/query_benchmark.py" 2>&1 | tee -a "$LOGFILE" > "$RESULTS_FILE"
log "Query benchmark done. Results: $RESULTS_FILE"

log "===== 500M Benchmark Complete ====="
