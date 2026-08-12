#!/usr/bin/env bash
# Install Calico via Tigera operator + local Installation CR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"

echo "==> Installing Tigera operator (${CALICO_VERSION})"
kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

echo "==> Waiting for operator"
kubectl wait --for=condition=available --timeout=180s \
  deployment/tigera-operator -n tigera-operator || true

echo "==> Applying Installation CR"
kubectl apply -f "${SCRIPT_DIR}/calico.yaml"

echo "==> Waiting for calico-system pods"
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s || \
  kubectl get pods -n calico-system

echo "==> Calico install submitted. Check: kubectl get pods -n calico-system"
