# OpenObserve vs OpenSearch Benchmark Suite

Benchmark framework for comparing OpenObserve and OpenSearch on AWS EKS under high-ingestion log workloads.

This repository provisions infrastructure, deploys both stacks, drives ingestion using LogStorm, and generates a query latency report.

## What This Project Does

- Creates or reuses an EKS benchmark cluster
- Deploys OpenObserve and OpenSearch with benchmark-oriented settings
- Deploys Fluent Bit and LogStorm for high-volume log ingestion
- Waits for a target document count
- Executes query benchmarks on both systems
- Produces a Markdown benchmark report and raw query JSON

## Architecture

- Log generator: app/logstorm
- Benchmark automation: benchmark/auto_benchmark.sh
- Query benchmark runner: benchmark/query_benchmark.py
- Kubernetes manifests: deploy/
- EKS orchestration scripts: root-level launchers + scripts/

## Prerequisites

- AWS account with permissions for EKS, EC2, IAM, ECR
- AWS CLI configured (aws configure)
- eksctl
- kubectl
- Docker (with buildx)
- python3

## Quick Start

Run a 100M document benchmark:

```bash
./run-100m-eks-benchmark.sh
```

This command calls setup-eks-benchmark.sh with TARGET_DOCS=100000000.

## Main Entry Points

- run-100m-eks-benchmark.sh
	- One-command 100M run
- setup-eks-benchmark.sh
	- Full setup and benchmark automation (default target is from TARGET_DOCS, default 300000000)
- scripts/setup-eks-benchmark.sh
	- Wrapper to root setup script (single source of truth)
- scripts/run-500m-benchmark.sh
	- Long-run monitor/query flow (script name is historical)

## Common Commands

Run setup directly with a custom target:

```bash
TARGET_DOCS=300000000 bash ./setup-eks-benchmark.sh
```

Manual query benchmark only (cluster already running):

```bash
kubectl --kubeconfig ~/.kube/o2-benchmark.yaml port-forward -n openobserve svc/openobserve 5080:5080
kubectl --kubeconfig ~/.kube/o2-benchmark.yaml port-forward -n opensearch svc/opensearch 9200:9200
python3 benchmark/query_benchmark.py
```

Watch progress logs:

```bash
tail -f /tmp/o2-setup.log
tail -f /tmp/auto-benchmark.log
```

## Outputs

- results/BENCHMARK_REPORT.md
- results/query_results.json
- /tmp/o2-setup.log
- /tmp/auto-benchmark.log

## Important Configuration

Environment variables used by setup-eks-benchmark.sh:

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

## Retry Behavior

For clean reruns on an existing cluster, use:

```bash
RESET_WORKLOADS=true TARGET_DOCS=100000000 bash ./setup-eks-benchmark.sh
```

This removes benchmark workloads and PV/PVC bindings before re-applying manifests.

## Repository Layout

```text
.
├── app/logstorm/                 # Log generator
├── benchmark/
│   ├── auto_benchmark.sh         # Poll + trigger report flow
│   └── query_benchmark.py        # Query benchmark and report generator
├── deploy/                       # Kubernetes manifests
├── scripts/                      # Additional runners/variants
├── run-100m-eks-benchmark.sh     # Root launcher (100M)
├── setup-eks-benchmark.sh        # Root launcher (full setup)
└── results/                      # Generated results
```

## Cleanup

Delete benchmark cluster:

```bash
eksctl delete cluster --name o2-benchmark --region ap-south-1
```

## Notes

- This benchmark creates billable AWS resources.
- Expect long runtime for high document targets.
