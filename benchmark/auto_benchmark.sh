#!/usr/bin/env bash
# benchmark/auto_benchmark.sh
#
# Runs on your local machine.
# Started automatically by scripts/setup-eks-benchmark.sh.
#
# What it does:
#   1. Opens port-forwards to both OpenObserve and OpenSearch
#   2. Polls O2 doc count every 60 seconds
#   3. When O2 reaches 300M docs, runs query_benchmark.py
#   4. Saves the final report to results/BENCHMARK_REPORT.md
#
# Log: /tmp/auto-benchmark.log  (tail -f to watch progress)

set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/o2-benchmark.yaml}"
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=${TARGET:-300000000}
POLL_INTERVAL=60   # seconds between O2 count checks
LOG="/tmp/auto-benchmark.log"

O2_USER="root@benchmark.local"
O2_PASS="BenchmarkPass123!"

export KUBECONFIG="$KUBECONFIG_FILE"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "auto_benchmark.sh started  target=$TARGET"

# ── Port-forward manager ──────────────────────────────────────────────────────
O2_PF_PID=""
OS_PF_PID=""

start_port_forwards() {
    log "Starting port-forwards..."

    cleanup
    sleep 1

    kubectl --kubeconfig "$KUBECONFIG_FILE" \
        port-forward -n openobserve svc/openobserve 5080:5080 \
        >> /tmp/pf-o2.log 2>&1 &
    O2_PF_PID=$!

    kubectl --kubeconfig "$KUBECONFIG_FILE" \
        port-forward -n opensearch svc/opensearch 9200:9200 \
        >> /tmp/pf-os.log 2>&1 &
    OS_PF_PID=$!

    # Wait for ports to open
    for i in $(seq 1 20); do
        if curl -s --max-time 3 -u "$O2_USER:$O2_PASS" http://localhost:5080/healthz >/dev/null 2>&1 \
        && curl -s --max-time 3 http://localhost:9200/_cluster/health  >/dev/null 2>&1; then
            log "Port-forwards established (O2:5080  OS:9200)"
            return 0
        fi
        sleep 3
    done
    log "ERROR: failed to establish port-forwards"
    return 1
}

ensure_port_forwards() {
    # Restart if either process has died
    if ! kill -0 "$O2_PF_PID" 2>/dev/null || ! kill -0 "$OS_PF_PID" 2>/dev/null; then
        log "Port-forward died, restarting..."
        start_port_forwards
        return
    fi

    if ! curl -s --max-time 3 -u "$O2_USER:$O2_PASS" http://localhost:5080/healthz >/dev/null 2>&1 \
        || ! curl -s --max-time 3 http://localhost:9200/_cluster/health >/dev/null 2>&1; then
        log "Port-forward connectivity check failed, restarting..."
        start_port_forwards
    fi
}

cleanup() {
    log "Shutting down port-forwards..."
    if [[ -n "$O2_PF_PID" ]] && kill -0 "$O2_PF_PID" 2>/dev/null; then
        kill "$O2_PF_PID" 2>/dev/null || true
    fi
    if [[ -n "$OS_PF_PID" ]] && kill -0 "$OS_PF_PID" 2>/dev/null; then
        kill "$OS_PF_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ── O2 doc count ─────────────────────────────────────────────────────────────
get_o2_count() {
    local now_us start_us body count
    now_us=$(python3 -c "import time; print(int(time.time() * 1e6))")
    start_us=$(python3 -c "import time; print(int((time.time() - 86400) * 1e6))")
    body="{\"query\":{\"sql\":\"SELECT COUNT(*) AS c FROM default\",\"start_time\":${start_us},\"end_time\":${now_us}}}"
    count=$(curl -s --max-time 15 \
        -u "$O2_USER:$O2_PASS" \
        http://localhost:5080/api/default/_search \
        -H "Content-Type: application/json" \
        -d "$body" \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    h = d.get('hits', [])
    if isinstance(h, list) and h:
        print(int(h[0].get('c', h[0].get('_source', {}).get('c', 0))))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null)
    echo "${count:-0}"
}

get_os_count() {
    curl -s --max-time 10 http://localhost:9200/logstorm/_count \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null \
        || echo 0
}

# ── Main polling loop ─────────────────────────────────────────────────────────
start_port_forwards
START=$(date +%s)

log "Polling O2 every ${POLL_INTERVAL}s until it hits ${TARGET} docs..."

while true; do
    sleep "$POLL_INTERVAL"
    ensure_port_forwards

    O2_COUNT=$(get_o2_count)
    OS_COUNT=$(get_os_count)
    ELAPSED=$(( $(date +%s) - START ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    PCT=$(python3 -c "print(f'{$O2_COUNT/$TARGET*100:.1f}')" 2>/dev/null || echo "?")

    log "O2: ${O2_COUNT} (${PCT}%) | OS: ${OS_COUNT} | elapsed: ${ELAPSED_MIN}m"

    if [[ "$O2_COUNT" -ge "$TARGET" ]]; then
        log "O2 reached target! Running query benchmark..."
        break
    fi
done

# ── Re-enable OS refresh before benchmarking ─────────────────────────────────
log "Restoring OS refresh_interval for consistent query performance..."
curl -s -X PUT http://localhost:9200/logstorm/_settings \
    -H "Content-Type: application/json" \
    -d '{"index":{"refresh_interval":"1s"}}' >/dev/null 2>&1 || true

# Also force a final O2 flush / compaction
curl -s -u "$O2_USER:$O2_PASS" \
    -X POST "http://localhost:5080/api/default/default/_flush" >/dev/null 2>&1 || true

sleep 10  # let refresh complete

# ── Run query benchmark ───────────────────────────────────────────────────────
log "Running query_benchmark.py..."
cd "$WORKDIR"
DATASET_DOCS="$TARGET" CLUSTER_NODE_TYPE="${NODE_TYPE:-m7i-flex.large}" \
python3 benchmark/query_benchmark.py 2>&1 | tee -a "$LOG"

# ── Storage check ─────────────────────────────────────────────────────────────
log "Checking storage usage on the PVCs..."

O2_DISK=$(kubectl --kubeconfig "$KUBECONFIG_FILE" run -n openobserve \
    --restart=Never --rm -i --image=busybox:1.36 \
    --overrides='{
      "spec": {
        "volumes": [{"name":"d","persistentVolumeClaim":{"claimName":"openobserve-data-pvc"}}],
        "containers": [{"name":"c","image":"busybox:1.36",
          "command":["df","-h","/mnt"],
          "volumeMounts":[{"name":"d","mountPath":"/mnt"}]}]
      }
    }' storage-check-o2 -- df -h /mnt 2>/dev/null \
    | grep "/mnt" | awk '{print $3}' || echo "N/A")

OS_DISK=$(kubectl --kubeconfig "$KUBECONFIG_FILE" run -n opensearch \
    --restart=Never --rm -i --image=busybox:1.36 \
    --overrides='{
      "spec": {
        "volumes": [{"name":"d","persistentVolumeClaim":{"claimName":"opensearch-data-pvc"}}],
        "containers": [{"name":"c","image":"busybox:1.36",
          "command":["df","-h","/mnt"],
          "volumeMounts":[{"name":"d","mountPath":"/mnt"}]}]
      }
    }' storage-check-os -- df -h /mnt 2>/dev/null \
    | grep "/mnt" | awk '{print $3}' || echo "N/A")

log "Storage used - O2: $O2_DISK  |  OS: $OS_DISK"

# Append storage info to the report
cat >> "$WORKDIR/results/BENCHMARK_REPORT.md" <<STORAGE_NOTE

---

## Appendix: Actual Disk Usage (from PVC)

| System | PVC Used |
|--------|----------|
| OpenObserve | $O2_DISK |
| OpenSearch  | $OS_DISK |

> Storage measured after target log records were ingested.
> OpenObserve uses Parquet + Zstandard; OpenSearch uses Lucene segments.
STORAGE_NOTE

log ""
log "============================================================"
log "  BENCHMARK COMPLETE"
log "  Report: $WORKDIR/results/BENCHMARK_REPORT.md"
log "============================================================"
