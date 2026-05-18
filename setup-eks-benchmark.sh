#!/usr/bin/env bash
# setup-eks-benchmark.sh
#
# Full automated EKS benchmark setup for OpenObserve vs OpenSearch.
# Creates everything from scratch and starts log ingestion in the background.
# No interaction required after running this script.
#
# What it does:
#   1. Creates two 300 GiB gp3 EBS volumes
#   2. Creates EKS cluster  o2-benchmark  (ap-south-1)
#   3. Creates nodegroup    benchmark-ng  (3x m7i-flex.xlarge, pinned to ap-south-1a)
#   4. Attaches IAM policies for EBS CSI driver to the node role
#   5. Installs aws-ebs-csi-driver addon, waits for ACTIVE
#   6. Builds + pushes logstorm to ECR
#   7. Deploys OpenObserve and OpenSearch with optimised settings
#   8. Pre-creates the OS index with bulk-write settings
#   9. Starts benchmark/auto_benchmark.sh in the background
#
# Usage:
#   bash setup-eks-benchmark.sh
#
# Monitor progress after:
#   tail -f /tmp/o2-setup.log
#   tail -f /tmp/auto-benchmark.log

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="${REGION:-ap-south-1}"
AZ="${AZ:-ap-south-1a}"
CLUSTER="${CLUSTER:-o2-benchmark}"
NODEGROUP="${NODEGROUP:-benchmark-ng}"
NODE_TYPE="${NODE_TYPE:-m7i-flex.large}"
NODES="${NODES:-3}"
K8S_VERSION="${K8S_VERSION:-1.31}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/${CLUSTER}.yaml}"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
LOGFILE="/tmp/o2-setup.log"

TARGET_DOCS="${TARGET_DOCS:-300000000}"
LOGSTORM_REPLICAS="${LOGSTORM_REPLICAS:-10}"
LOGSTORM_RATE="${LOGSTORM_RATE:-2000}"
LOGSTORM_DURATION="${LOGSTORM_DURATION:-3000}"
RESET_WORKLOADS="${RESET_WORKLOADS:-false}"

export KUBECONFIG="$KUBECONFIG_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

attach_policy_if_missing() {
    local role="$1"
    local policy_arn="$2"
    if aws iam list-attached-role-policies --role-name "$role" \
        --query "AttachedPolicies[?PolicyArn=='${policy_arn}'] | length(@)" \
        --output text | grep -q "^1$"; then
        log "Policy already attached: $policy_arn"
        return
    fi
    aws iam attach-role-policy --role-name "$role" --policy-arn "$policy_arn"
    log "Attached policy: $policy_arn"
}

reset_cluster_workloads() {
    log "RESET_WORKLOADS=true, deleting benchmark workloads for a clean rerun..."
    kubectl delete deployment logstorm -n benchmark --ignore-not-found=true || true
    kubectl delete daemonset fluentbit -n logging --ignore-not-found=true || true
    kubectl delete pvc openobserve-data-pvc -n openobserve --ignore-not-found=true || true
    kubectl delete pvc opensearch-data-pvc -n opensearch --ignore-not-found=true || true
    kubectl delete pv openobserve-data-pv opensearch-data-pv --ignore-not-found=true || true
    kubectl delete statefulset openobserve -n openobserve --ignore-not-found=true || true
    kubectl delete statefulset opensearch -n opensearch --ignore-not-found=true || true
}

mkdir -p "$WORKDIR/results"
: > "$LOGFILE"   # truncate

log "=== OpenObserve vs OpenSearch EKS Benchmark Setup ==="
log "Cluster=$CLUSTER  Region=$REGION  AZ=$AZ  Log=$LOGFILE"
log "Target docs=$TARGET_DOCS"
log "Node type=$NODE_TYPE nodes=$NODES"

# ── 1. Preflight checks ───────────────────────────────────────────────────────
log "Checking required tools..."
for tool in aws eksctl kubectl docker python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not found. Install it and re-run."
done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || fail "AWS credentials not configured. Run: aws configure"
log "AWS account: $ACCOUNT  Region: $REGION"

# ── 2. Create EBS volumes ─────────────────────────────────────────────────────
# Allow pre-supplying volume IDs to skip creation (e.g. on retry runs)
if [[ -n "${O2_VOL:-}" && -n "${OS_VOL:-}" ]]; then
    log "Reusing provided EBS volumes: O2=$O2_VOL  OS=$OS_VOL"
else
    log "Creating two 300 GiB gp3 EBS volumes in $AZ..."

    O2_VOL=$(aws ec2 create-volume \
        --region "$REGION" --availability-zone "$AZ" \
        --size 300 --volume-type gp3 \
        --tag-specifications \
                "ResourceType=volume,Tags=[{Key=Name,Value=openobserve-benchmark},{Key=Project,Value=${CLUSTER}}]" \
        --query VolumeId --output text)

    OS_VOL=$(aws ec2 create-volume \
        --region "$REGION" --availability-zone "$AZ" \
        --size 300 --volume-type gp3 \
        --tag-specifications \
                "ResourceType=volume,Tags=[{Key=Name,Value=opensearch-benchmark},{Key=Project,Value=${CLUSTER}}]" \
        --query VolumeId --output text)

    log "OpenObserve volume : $O2_VOL"
    log "OpenSearch  volume : $OS_VOL"

    aws ec2 wait volume-available --region "$REGION" --volume-ids "$O2_VOL" "$OS_VOL"
    log "Volumes available"
fi

# ── 3. Create EKS control plane ───────────────────────────────────────────────
if eksctl get cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
    log "Cluster $CLUSTER already exists, skipping creation. Updating kubeconfig..."
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE"
    log "Kubeconfig updated"
else
    log "Creating EKS control plane (approx. 15 min)..."
    eksctl create cluster \
        --name        "$CLUSTER" \
        --region      "$REGION" \
        --version     "$K8S_VERSION" \
        --zones       "${AZ},ap-south-1b" \
        --without-nodegroup \
        --kubeconfig  "$KUBECONFIG_FILE" 2>&1 | tee -a "$LOGFILE"
    log "Control plane ready"
fi

# ── 4. Create managed nodegroup ───────────────────────────────────────────────
if eksctl get nodegroup --cluster "$CLUSTER" --region "$REGION" --name "$NODEGROUP" >/dev/null 2>&1; then
    log "Nodegroup $NODEGROUP already exists, skipping creation"
else
    log "Creating nodegroup: ${NODES}x $NODE_TYPE pinned to $AZ..."
    eksctl create nodegroup \
        --cluster   "$CLUSTER" \
        --region    "$REGION" \
        --name      "$NODEGROUP" \
        --managed \
        --node-type "$NODE_TYPE" \
        --nodes "$NODES" --nodes-min "$NODES" --nodes-max "$NODES" \
        --node-zones "$AZ" 2>&1 | tee -a "$LOGFILE"
    log "Nodegroup ready"
fi

# ── 5. Attach IAM policies for EBS CSI ───────────────────────────────────────
log "Attaching IAM policies to node role..."

NG_STACK="eksctl-${CLUSTER}-nodegroup-${NODEGROUP}"
NODE_ROLE=$(aws cloudformation describe-stack-resource \
    --region      "$REGION" \
    --stack-name  "$NG_STACK" \
    --logical-resource-id NodeInstanceRole \
    --query StackResourceDetail.PhysicalResourceId \
    --output text)
log "Node role: $NODE_ROLE"

attach_policy_if_missing "$NODE_ROLE" "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
attach_policy_if_missing "$NODE_ROLE" "arn:aws:iam::aws:policy/AmazonEC2FullAccess"

log "IAM policies attached"

# ── 6. Install EBS CSI driver addon ──────────────────────────────────────────
log "Installing aws-ebs-csi-driver addon..."
if eksctl get addon --cluster "$CLUSTER" --region "$REGION" --name aws-ebs-csi-driver >/dev/null 2>&1; then
    log "aws-ebs-csi-driver addon already present, refreshing state"
else
    eksctl create addon \
        --cluster "$CLUSTER" --region "$REGION" \
        --name aws-ebs-csi-driver --force 2>&1 | tee -a "$LOGFILE"
fi

# Poll until ACTIVE (up to 5 min)
for i in $(seq 1 20); do
    STATUS=$(eksctl get addon \
        --cluster "$CLUSTER" --region "$REGION" \
        --name aws-ebs-csi-driver 2>/dev/null \
        | awk 'NR==2{print $3}')
    [[ "$STATUS" == "ACTIVE" ]] && { log "EBS CSI driver: ACTIVE"; break; }
    log "EBS CSI status=$STATUS ($i/20)..."
    sleep 15
done

log "Running cluster health checks..."
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {c++} END {print c+0}')
if [[ "$READY_NODES" -lt "$NODES" ]]; then
    fail "Expected at least $NODES Ready nodes, found $READY_NODES"
fi
if ! kubectl get nodes -L topology.kubernetes.io/zone --no-headers | awk '{print $NF}' | grep -q "^${AZ}$"; then
    fail "No nodes found in expected AZ $AZ"
fi
log "Cluster health checks passed (Ready nodes: $READY_NODES)"

# ── 7. Build and push logstorm to ECR ─────────────────────────────────────────
log "Building and pushing logstorm Docker image..."

aws ecr describe-repositories \
    --region "$REGION" --repository-names logstorm >/dev/null 2>&1 \
    || aws ecr create-repository --region "$REGION" --repository-name logstorm \
       --query repository.repositoryUri --output text

ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"

cd "$WORKDIR/app/logstorm"
docker buildx build --platform linux/amd64 \
    -t "${ECR_REGISTRY}/logstorm:latest" --push . 2>&1 | tee -a "$LOGFILE"
cd "$WORKDIR"
log "logstorm image: ${ECR_REGISTRY}/logstorm:latest"

# ── 8. Create namespaces ──────────────────────────────────────────────────────
log "Creating namespaces..."
for ns in openobserve opensearch benchmark logging; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

if [[ "$RESET_WORKLOADS" == "true" ]]; then
    reset_cluster_workloads
fi

# ── 9. Generate fresh PV/PVC manifest with the new volume IDs ─────────────────
log "Patching deploy/aws/static-pv-pvc.yaml  (O2=$O2_VOL  OS=$OS_VOL)..."
python3 - "$O2_VOL" "$OS_VOL" "$WORKDIR" <<'PYEOF'
import os
import re
import sys

o2_vol, os_vol, workdir = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.join(workdir, "deploy/aws/static-pv-pvc.yaml")
with open(path) as f:
    text = f.read()

# Replace the two volumeHandle values in document order
new_vols = iter([o2_vol, os_vol])
def repl(m):
    return f"    volumeHandle: {next(new_vols)}"

text_new, count = re.subn(r"    volumeHandle: vol-[a-z0-9]+", repl, text)
if count != 2:
    print(f"Expected to replace 2 volumeHandle entries, replaced {count}", file=sys.stderr)
    sys.exit(1)

with open(path, "w") as f:
    f.write(text_new)

print(f"  Updated {path}: O2={o2_vol}  OS={os_vol}")
PYEOF

# ── 10. Patch logstorm deployment with current ECR account ───────────────────
sed -i.bak \
    "s|[0-9]*\.dkr\.ecr\.[a-z0-9-]*\.amazonaws\.com/logstorm|${ECR_REGISTRY}/logstorm|g" \
    deploy/logstorm/deployment.yaml

log "Configuring logstorm deployment scale and runtime env..."
if ! aws ecr describe-images --region "$REGION" --repository-name logstorm --image-ids imageTag=latest >/dev/null 2>&1; then
    fail "ECR image ${ECR_REGISTRY}/logstorm:latest not found"
fi

# ── 11. Deploy manifests ──────────────────────────────────────────────────────
log "Applying Kubernetes manifests..."

kubectl apply -f deploy/aws/static-pv-pvc.yaml

kubectl apply -f deploy/openobserve/configmap.yaml
kubectl apply -f deploy/openobserve/statefulset.yaml
kubectl apply -f deploy/openobserve/service.yaml

kubectl apply -f deploy/opensearch/configmap.yaml
kubectl apply -f deploy/opensearch/statefulset.yaml
kubectl apply -f deploy/opensearch/service.yaml

kubectl apply -f deploy/fluentbit/configmap.yaml
kubectl apply -f deploy/fluentbit/daemonset.yaml

kubectl apply -f deploy/logstorm/deployment.yaml

kubectl -n benchmark set env deployment/logstorm \
    LOG_RATE="$LOGSTORM_RATE" LOG_DURATION="$LOGSTORM_DURATION"

kubectl -n benchmark scale deployment/logstorm --replicas="$LOGSTORM_REPLICAS"

log "Manifests applied"

log "Checking PVC bindings..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/openobserve-data-pvc -n openobserve --timeout=180s
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/opensearch-data-pvc -n opensearch --timeout=180s

log "Ensuring metrics-server is available for benchmark memory metrics..."
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s || \
    log "WARNING: metrics-server not ready; memory metrics may be unavailable"

# ── 12. Wait for both backends to be ready ────────────────────────────────────
log "Waiting for OpenObserve to be Ready..."
kubectl wait --for=condition=ready pod/openobserve-0 \
    -n openobserve --timeout=300s

log "Waiting for OpenSearch to be Ready..."
kubectl wait --for=condition=ready pod/opensearch-0 \
    -n opensearch --timeout=480s

log "Waiting for Fluent Bit DaemonSet rollout..."
kubectl rollout status daemonset/fluentbit -n logging --timeout=300s

log "Waiting for LogStorm deployment rollout..."
kubectl rollout status deployment/logstorm -n benchmark --timeout=300s

log "Both backends are Ready"

# ── 13. Pre-configure OpenSearch index for bulk ingestion ─────────────────────
log "Configuring OpenSearch logstorm index (1 shard, no replicas, async translog)..."
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
kubectl logs os-index-setup -n opensearch >/dev/null 2>&1 || true
kubectl delete pod os-index-setup -n opensearch --ignore-not-found=true
log "OpenSearch index configured"

# Also tweak OS JVM settings via index-level API
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
    log "OpenSearch cluster setting applied"
else
    log "WARNING: OpenSearch cluster setting update failed or is not dynamically updateable; continuing"
    kubectl logs os-index-opt -n opensearch >/dev/null 2>&1 || true
fi
kubectl delete pod os-index-opt -n opensearch --ignore-not-found=true

# ── 14. Start auto_benchmark.sh in the background ────────────────────────────
log "Starting auto_benchmark.sh in background..."
TARGET="$TARGET_DOCS" NODE_TYPE="$NODE_TYPE" KUBECONFIG_FILE="$KUBECONFIG_FILE" nohup bash "$WORKDIR/benchmark/auto_benchmark.sh" \
    > /tmp/auto-benchmark.log 2>&1 &
AB_PID=$!
log "auto_benchmark.sh running as PID $AB_PID  (log: /tmp/auto-benchmark.log)"

# ── Done ──────────────────────────────────────────────────────────────────────
log ""
log "============================================================"
log "  Setup complete!"
log "============================================================"
log ""
log "  Cluster       : $CLUSTER"
log "  Kubeconfig    : $KUBECONFIG_FILE"
log "  O2 EBS volume : $O2_VOL"
log "  OS EBS volume : $OS_VOL"
log ""
log "  Watch auto-benchmark:"
log "    tail -f /tmp/auto-benchmark.log"
log ""
log "  The benchmark report will appear at:"
log "    $WORKDIR/results/BENCHMARK_REPORT.md"
log ""
log "  Full setup log:"
log "    $LOGFILE"
log "============================================================"
