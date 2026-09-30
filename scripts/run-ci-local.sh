#!/bin/bash
# Run CI tests locally on a VM using shared netdevsim infrastructure.
#
# Always overlays Kind/netdevsim scripts and ptp-tools from
# redhat-cne/ptp-netdevsim-ci. On release/downstream checkouts, also fetches
# test/ from the operator upstream. On upstream main, local test/ is kept.
#
# Usage:
#   ./scripts/run-ci-local.sh <VM_IP> [UPSTREAM_REPO_URL]
#
# Examples:
#   ./scripts/run-ci-local.sh 10.70.0.128
#   ./scripts/run-ci-local.sh 10.70.0.128 https://github.com/my-org/upstream-monorepo.git
#   MAIN_BRANCH=feature-x ./scripts/run-ci-local.sh 10.70.0.128
#
set -euo pipefail

VM_IP="${1:?Usage: $0 <VM_IP> [UPSTREAM_REPO_URL]}"
UPSTREAM_URL="${2:-https://github.com/redhat-cne/upstream-ptp-operator-monorepo.git}"

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

echo "============================================"
echo "  Local CI Test Runner"
echo "============================================"
echo "  VM:       $VM_IP"
echo "  Branch:   $(git branch --show-current 2>/dev/null || echo 'detached')"
echo "  Dir:      $(pwd)"
echo "============================================"

if [ ! -f scripts/fetch-upstream-ci.sh ]; then
    echo "Error: scripts/fetch-upstream-ci.sh not found."
    echo "This script needs fetch-upstream-ci.sh to pull netdevsim scripts from ptp-netdevsim-ci."
    exit 1
fi

echo ""
echo ">>> Fetching CI artifacts (netdevsim scripts; test/ when needed)..."
./scripts/fetch-upstream-ci.sh "$UPSTREAM_URL"

echo ""
echo ">>> Running CI on VM ($VM_IP)..."
sudo ./scripts/run-on-vm.sh "$VM_IP"
