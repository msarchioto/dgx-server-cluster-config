#!/usr/bin/env bash
# Install/upgrade GPU Operator with MIG manager (split on request).
# Usage: ./install-gpu-operator-mig.sh [dgx-os|vanilla]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILE="${1:-dgx-os}"

echo "==> Optional custom MIG strategies (safe if operator also auto-generates)"
kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace gpu-operator \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
kubectl apply -f "${ROOT}/manifests/mig-config.yaml"

echo "==> GPU Operator + MIG overlay"
bash "${SCRIPT_DIR}/install-gpu-operator.sh" "${PROFILE}" \
  --values "${ROOT}/values-mig.yaml"

echo "==> MIG-ready. Nodes stay full-GPU until:"
echo "    ${SCRIPT_DIR}/enable-mig.sh --list"
echo "    ${SCRIPT_DIR}/enable-mig.sh all-1g.10gb <node>   # drains by default"
