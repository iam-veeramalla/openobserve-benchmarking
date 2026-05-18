#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/o2-benchmark.yaml}"
TARGET_DOCS="${TARGET_DOCS:-100000000}"
NODE_TYPE="${NODE_TYPE:-m7i-flex.large}"

export KUBECONFIG="$KUBECONFIG_FILE"

kubectl delete pod os-index-setup -n opensearch --ignore-not-found=true >/dev/null 2>&1 || true
kubectl run os-index-setup \
  --namespace opensearch \
  --image=curlimages/curl:8.11.0 \
  --restart=Never \
  --command -- \
  sh -c '
    body="$(mktemp)"
    code="$(curl -sS -o "$body" -w "%{http_code}" -X PUT \
      "http://opensearch.opensearch.svc.cluster.local:9200/logstorm" \
      -H "Content-Type: application/json" \
      -d "{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0,\"refresh_interval\":\"-1\",\"translog.durability\":\"async\",\"translog.sync_interval\":\"60s\",\"index.write.wait_for_active_shards\":\"1\",\"index.merge.scheduler.max_thread_count\":2}}")"

    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
      echo "index create/update OK (HTTP $code)"
      exit 0
    fi

    if [ "$code" = "400" ] && grep -q "resource_already_exists_exception" "$body"; then
      echo "index already exists; continuing"
      exit 0
    fi

    echo "index setup failed (HTTP $code):"
    cat "$body"
    exit 1
  '

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/os-index-setup -n opensearch --timeout=180s
kubectl logs os-index-setup -n opensearch --tail=80 || true

kubectl delete pod os-index-opt -n opensearch --ignore-not-found=true >/dev/null 2>&1 || true
kubectl run os-index-opt \
  --namespace opensearch \
  --image=curlimages/curl:8.11.0 \
  --restart=Never \
  --command -- \
  curl -s -X PUT \
    "http://opensearch.opensearch.svc.cluster.local:9200/_cluster/settings" \
    -H "Content-Type: application/json" \
    -d '{"persistent": {"indices.memory.index_buffer_size": "40%"}}'
if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/os-index-opt -n opensearch --timeout=180s; then
  echo "cluster setting applied"
else
  echo "warning: cluster setting update failed or is not dynamically updateable; continuing"
  kubectl logs os-index-opt -n opensearch || true
fi

kubectl delete pod os-index-setup os-index-opt -n opensearch --ignore-not-found=true >/dev/null 2>&1 || true

if ! pgrep -f 'benchmark/auto_benchmark.sh' >/dev/null 2>&1; then
  TARGET="$TARGET_DOCS" NODE_TYPE="$NODE_TYPE" KUBECONFIG_FILE="$KUBECONFIG_FILE" nohup bash benchmark/auto_benchmark.sh >/tmp/auto-benchmark.log 2>&1 &
fi

pgrep -af 'benchmark/auto_benchmark.sh' || true

echo "--- auto benchmark log tail ---"
tail -40 /tmp/auto-benchmark.log || true
