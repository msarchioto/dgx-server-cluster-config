#!/usr/bin/env bash
# Restore full (non-MIG) GPUs on nodes by requesting strategy all-disabled.
#
# Usage:
#   ./disable-mig.sh <node> [node...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <node> [node...]" >&2
  exit 1
fi

exec "${SCRIPT_DIR}/enable-mig.sh" all-disabled "$@"
