#!/usr/bin/env bash
set -euo pipefail

# One-command runner for a fair 100M ingestion benchmark on AWS EKS.
# Uses equal worker pools for both backends.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DOCS=100000000 \
bash "$ROOT_DIR/setup-eks-benchmark.sh"
