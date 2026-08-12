#!/usr/bin/env bash
# Restore full GPUs (strategy all-disabled). Drains by default.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--no-drain] [--skip-uncordon] <node> [node...]" >&2
  exit 1
fi
EXTRA=()
NODES=()
for a in "$@"; do
  case "$a" in
    --no-drain|--skip-uncordon) EXTRA+=("$a") ;;
    *) NODES+=("$a") ;;
  esac
done
if [[ ${#NODES[@]} -lt 1 ]]; then
  echo "ERROR: provide at least one node" >&2
  exit 1
fi
exec "${SCRIPT_DIR}/enable-mig.sh" "${EXTRA[@]}" all-disabled "${NODES[@]}"
