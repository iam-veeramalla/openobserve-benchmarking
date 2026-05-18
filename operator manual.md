# Operator Manual

## Purpose

This manual explains exactly how to run the benchmark as an operator, from prerequisites to result validation.

## What You Need Before Running

1. AWS account with permissions for:
- EKS
- EC2
- IAM
- ECR

2. Local tools installed:
- aws CLI
- eksctl
- kubectl
- docker (with buildx support)
- python3

3. AWS CLI configured:

```bash
aws configure
aws sts get-caller-identity
```

4. Optional but recommended checks:

```bash
eksctl version
kubectl version --client
docker --version
python3 --version
```

## Operator Flow

### Step 1: Choose a Run Mode

Option A: Standard 100M run (recommended first run)

```bash
./run-100m-eks-benchmark.sh
```

Option B: Custom target run

```bash
TARGET_DOCS=300000000 bash ./setup-eks-benchmark.sh
```

Option C: Phase-2 monitor/query flow (advanced)

```bash
bash ./scripts/run-500m-benchmark.sh
```

## Step 2: Monitor Execution

Primary logs:

```bash
tail -f /tmp/o2-setup.log
tail -f /tmp/auto-benchmark.log
```

What setup does:
- Creates/reuses EBS volumes
- Creates/reuses EKS cluster and node group
- Installs EBS CSI addon
- Builds and pushes LogStorm image to ECR
- Creates required namespaces including logging
- Deploys OpenObserve and OpenSearch
- Deploys Fluent Bit DaemonSet and LogStorm deployment
- Pre-configures OpenSearch index
- Starts benchmark/auto_benchmark.sh in background

What auto benchmark does:
- Creates and keeps port-forwards alive
- Polls OpenObserve doc count until target is reached
- Restores OpenSearch refresh settings
- Runs benchmark/query_benchmark.py
- Appends storage appendix to final report

## Step 3: Validate Success

Expected artifacts:
- results/BENCHMARK_REPORT.md
- results/query_results.json

Optional quick checks:

```bash
ls -lh results/
```

```bash
grep -n "BENCHMARK COMPLETE\|Report:" /tmp/auto-benchmark.log
```

## Step 4: Review Results

Main report:
- results/BENCHMARK_REPORT.md

Raw query benchmark data:
- results/query_results.json

## Manual Query Benchmark Only (When Cluster Is Already Running)

If ingestion is already complete and you only want query comparison:

```bash
kubectl --kubeconfig ~/.kube/o2-benchmark.yaml port-forward -n openobserve svc/openobserve 5080:5080
```

```bash
kubectl --kubeconfig ~/.kube/o2-benchmark.yaml port-forward -n opensearch svc/opensearch 9200:9200
```

```bash
python3 benchmark/query_benchmark.py
```

## Key Runtime Variables

Used by setup-eks-benchmark.sh:
- REGION (default: ap-south-1)
- AZ (default: ap-south-1a)
- CLUSTER (default: o2-benchmark)
- NODEGROUP (default: benchmark-ng)
- NODE_TYPE (default: m7i-flex.large)
- K8S_VERSION (default: 1.31)
- KUBECONFIG_FILE (default: ~/.kube/o2-benchmark.yaml)
- TARGET_DOCS (default: 300000000)
- NODES (default: 3)
- LOGSTORM_REPLICAS (default: 10)
- LOGSTORM_RATE (default: 2000)
- LOGSTORM_DURATION (default: 3000)
- RESET_WORKLOADS (default: false)

## Troubleshooting

1. Setup fails at tool checks
- Install missing tool shown in log
- Re-run command

2. AWS auth/permission failures
- Run aws sts get-caller-identity
- Verify IAM permissions for EKS, EC2, IAM, ECR

3. Benchmark appears stuck
- Watch /tmp/auto-benchmark.log for current O2 count
- Ensure cluster pods are healthy:

```bash
kubectl --kubeconfig ~/.kube/o2-benchmark.yaml get pods -A
```

4. Query benchmark cannot connect
- Re-establish port-forwards
- Re-run python3 benchmark/query_benchmark.py

## Cleanup

```bash
eksctl delete cluster --name o2-benchmark --region ap-south-1
```

Note: This project provisions billable AWS resources. Always clean up when done.

## Clean Rerun On Existing Cluster

```bash
RESET_WORKLOADS=true TARGET_DOCS=100000000 bash ./setup-eks-benchmark.sh
```

This clears benchmark workloads and persistent volume bindings before redeploying.
