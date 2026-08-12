#!/usr/bin/env bash
# Install or upgrade NVIDIA GPU Operator with repo values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES="${SCRIPT_DIR}/../values.yaml"
NAMESPACE="${NAMESPACE:-gpu-operator}"
RELEASE="${RELEASE:-gpu-operator}"
CHART_VERSION="${CHART_VERSION:-}"  # empty = latest from repo

command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }

echo "==> Adding NVIDIA Helm repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

echo "==> Ensuring namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

EXTRA=()
if [[ -n "${CHART_VERSION}" ]]; then
  EXTRA+=(--version "${CHART_VERSION}")
fi

echo "==> helm upgrade --install ${RELEASE}"
helm upgrade --install "${RELEASE}" nvidia/gpu-operator \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --wait \
  --timeout 15m \
  "${EXTRA[@]}"

echo "==> Operator pods"
kubectl get pods -n "${NAMESPACE}" -o wide

echo "==> GPU allocatable (may take a few minutes after install)"
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
GPU:.status.allocatable.nvidia\\.com/gpu,\
READY:.status.conditions[-1].type || true

echo "==> Done. Run the smoke test under 02-node-pools/examples/"
