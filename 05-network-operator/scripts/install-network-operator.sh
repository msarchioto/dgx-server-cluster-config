#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-network-operator}"
RELEASE="${RELEASE:-network-operator}"
NETWORK_OPERATOR_VERSION="${NETWORK_OPERATOR_VERSION:-v25.1.0}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update

helm upgrade --install "${RELEASE}" nvidia/network-operator \
  --namespace "${NAMESPACE}" \
  --version "${NETWORK_OPERATOR_VERSION}" \
  --values "${ROOT}/values/values.yaml" \
  --wait --timeout 15m

echo "Installed ${RELEASE} ${NETWORK_OPERATOR_VERSION}"
echo "Next: edit and apply manifests/nic-cluster-policy-example.yaml"
echo "Then: 04-pytorch/validation NCCL tests"
