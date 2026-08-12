#!/usr/bin/env bash
# Install/upgrade GPU Operator with MIG support enabled (split on request).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES="${ROOT}/values.yaml"
VALUES_MIG="${ROOT}/values-mig.yaml"
MIG_CM="${ROOT}/manifests/mig-config.yaml"
NAMESPACE="${NAMESPACE:-gpu-operator}"
RELEASE="${RELEASE:-gpu-operator}"
CHART_VERSION="${CHART_VERSION:-}"

command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }

echo "==> Ensuring namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying MIG strategies ConfigMap"
kubectl apply -f "${MIG_CM}"

echo "==> Adding NVIDIA Helm repo"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

EXTRA=()
if [[ -n "${CHART_VERSION}" ]]; then
  EXTRA+=(--version "${CHART_VERSION}")
fi

echo "==> helm upgrade --install ${RELEASE} (values + values-mig)"
helm upgrade --install "${RELEASE}" nvidia/gpu-operator \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --values "${VALUES_MIG}" \
  --wait \
  --timeout 15m \
  "${EXTRA[@]}"

echo "==> GPU Operator (MIG-ready) installed"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
echo "Nodes keep full GPUs until you request a split:"
echo "  ${SCRIPT_DIR}/enable-mig.sh --list"
echo "  ${SCRIPT_DIR}/enable-mig.sh <strategy> <node>"
echo "  ${SCRIPT_DIR}/enable-mig.sh --status"
