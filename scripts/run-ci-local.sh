#!/bin/bash
# Run CI tests locally on a VM using the latest upstream test infrastructure.
#
# On release branches, this fetches test/, scripts/, and hack/ from the
# upstream monorepo main branch. On the upstream main branch, the test
# infrastructure is already present and the fetch is skipped.
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

# Detect whether upstream test infrastructure needs to be fetched.
# On the upstream main branch, test/go.mod already matches the root module;
# on release/downstream branches it either doesn't exist or belongs to a
# different module, so we fetch from upstream.
NEEDS_FETCH=true
if [ -f test/go.mod ] && [ -f go.mod ]; then
    TEST_MODULE=$(grep "^module " test/go.mod | awk '{print $2}')
    ROOT_MODULE=$(grep "^module " go.mod | awk '{print $2}')
    if [ "$TEST_MODULE" = "${ROOT_MODULE}/test" ]; then
        NEEDS_FETCH=false
    fi
fi

if [ "$NEEDS_FETCH" = true ]; then
    echo ""
    echo ">>> Fetching upstream test infrastructure..."
    if [ ! -f scripts/fetch-upstream-ci.sh ]; then
        echo "Error: scripts/fetch-upstream-ci.sh not found."
        echo "This script needs fetch-upstream-ci.sh to pull test code from upstream."
        exit 1
    fi
    ./scripts/fetch-upstream-ci.sh "$UPSTREAM_URL"
else
    echo ""
    echo ">>> Test infrastructure already present, skipping fetch."
fi

echo ""
echo ">>> Running CI on VM ($VM_IP)..."
sudo ./scripts/run-on-vm.sh "$VM_IP"
