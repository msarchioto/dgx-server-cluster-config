#!/usr/bin/env bash
# Install or upgrade NVIDIA GPU Operator with pinned chart version + PSA.
#
# Usage:
#   ./install-gpu-operator.sh [dgx-os|vanilla] [extra helm -f files...]
# Env:
#   GPU_OPERATOR_VERSION  chart version (default v26.3.3)
#   NAMESPACE             default gpu-operator
#   RELEASE               default gpu-operator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-gpu-operator}"
RELEASE="${RELEASE:-gpu-operator}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.3.3}"
PROFILE="${1:-dgx-os}"
shift || true

case "${PROFILE}" in
  dgx-os|dgx) PROFILE_FILE="${ROOT}/profiles/values-dgx-os.yaml" ;;
  vanilla|ubuntu|vanilla-ubuntu) PROFILE_FILE="${ROOT}/profiles/values-vanilla-ubuntu.yaml" ;;
  *)
    echo "Usage: $0 [dgx-os|vanilla] [extra -f values...]" >&2
    exit 1
    ;;
esac

command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }

echo "==> Ensuring namespace ${NAMESPACE} with privileged PSA"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

echo "==> Helm repo nvidia"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update

echo "==> Installing ${RELEASE} chart ${GPU_OPERATOR_VERSION} profile=${PROFILE}"
helm upgrade --install "${RELEASE}" nvidia/gpu-operator \
  --namespace "${NAMESPACE}" \
  --version "${GPU_OPERATOR_VERSION}" \
  --values "${ROOT}/values.yaml" \
  --values "${PROFILE_FILE}" \
  "$@" \
  --wait \
  --timeout 20m

echo "==> ClusterPolicy / pods"
kubectl get clusterpolicy 2>/dev/null || true
kubectl get pods -n "${NAMESPACE}" -o wide

echo "==> GPU allocatable"
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
GPU:.status.allocatable.nvidia\\.com/gpu,\
READY:.status.conditions[-1].type 2>/dev/null || true

echo "==> Done. Profile: ${PROFILE}. Chart: ${GPU_OPERATOR_VERSION}"
echo "    Smoke: kubectl apply -f ../02-node-pools/examples/gpu-pod-smoke-test.yaml"
