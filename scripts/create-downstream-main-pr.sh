#!/bin/bash
#
# create-downstream-main-pr.sh
#
# After an upstream monorepo PR merges to main, apply those commits as-is onto
# downstream monorepo main and open a simple PR from the bot fork.
#
# Module paths are not rewritten. Upstream and downstream keep the same module
# names, so the patch must apply cleanly. Conflicts fail the run.
#
# Usage:
#   create-downstream-main-pr.sh [options]
#
# Options:
#   --range FROM..TO           Upstream commit range to apply (required unless --commit)
#   --commit SHA               Single upstream commit to apply
#   --upstream-pr N            Upstream PR number (topic branch sync/upstream-main-pr-N)
#   --pr-title TEXT            Downstream PR title (default: tip commit subject)
#   --upstream-repo OWNER/REPO Source repo for links (default: redhat-cne/upstream-ptp-operator-monorepo)
#   --downstream-repo OWNER/REPO Target repo (default: redhat-cne/downstream-ptp-operator-monorepo)
#   --fork-owner OWNER         Fork that receives the topic branch (default: ptp-monorepo-sync-bot)
#   --base BRANCH              Downstream base branch (default: main)
#   --dry-run                  Format the patch and print the PR without pushing
#   -h, --help                 Show this help message
#
# Examples:
#   ./scripts/create-downstream-main-pr.sh --range abc..def --upstream-pr 12 --pr-title "fix clock class"
#   ./scripts/create-downstream-main-pr.sh --commit HEAD --upstream-pr 12 --dry-run
#

set -euo pipefail

export GH_PAGER=cat
export GIT_PAGER=cat

COMMIT_RANGE=""
COMMIT_SHA=""
UPSTREAM_PR=""
PR_TITLE=""
UPSTREAM_REPO="${UPSTREAM_MONOREPO_REPO:-redhat-cne/upstream-ptp-operator-monorepo}"
DOWNSTREAM_REPO="${DOWNSTREAM_MONOREPO_REPO:-redhat-cne/downstream-ptp-operator-monorepo}"
FORK_OWNER="${SYNC_BOT_FORK_OWNER:-ptp-monorepo-sync-bot}"
BASE_BRANCH="main"
DRY_RUN=false

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --range)
            [ $# -ge 2 ] || die "--range requires an argument"
            COMMIT_RANGE="$2"
            shift 2
            ;;
        --commit)
            [ $# -ge 2 ] || die "--commit requires an argument"
            COMMIT_SHA="$2"
            shift 2
            ;;
        --upstream-pr)
            [ $# -ge 2 ] || die "--upstream-pr requires an argument"
            UPSTREAM_PR="$2"
            shift 2
            ;;
        --pr-title)
            [ $# -ge 2 ] || die "--pr-title requires an argument"
            PR_TITLE="$2"
            shift 2
            ;;
        --upstream-repo)
            [ $# -ge 2 ] || die "--upstream-repo requires an argument"
            UPSTREAM_REPO="$2"
            shift 2
            ;;
        --downstream-repo)
            [ $# -ge 2 ] || die "--downstream-repo requires an argument"
            DOWNSTREAM_REPO="$2"
            shift 2
            ;;
        --fork-owner)
            [ $# -ge 2 ] || die "--fork-owner requires an argument"
            FORK_OWNER="$2"
            shift 2
            ;;
        --base)
            [ $# -ge 2 ] || die "--base requires an argument"
            BASE_BRANCH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

need_cmd git
need_cmd gh

if [ -z "$COMMIT_RANGE" ] && [ -z "$COMMIT_SHA" ]; then
    die "Provide --range FROM..TO or --commit SHA"
fi
if [ -n "$COMMIT_RANGE" ] && [ -n "$COMMIT_SHA" ]; then
    die "Use only one of --range or --commit"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run from a git checkout that contains the upstream commits"

if [ -n "$COMMIT_SHA" ]; then
    FULL_SHA="$(git rev-parse "${COMMIT_SHA}^{commit}")" || die "Cannot resolve commit ${COMMIT_SHA}"
    RANGE_SPEC="${FULL_SHA}^..${FULL_SHA}"
else
    case "$COMMIT_RANGE" in
        *..*) ;;
        *) die "--range must look like FROM..TO" ;;
    esac
    TIP="${COMMIT_RANGE##*..}"
    FULL_SHA="$(git rev-parse "${TIP}^{commit}")" || die "Cannot resolve range tip ${TIP}"
    RANGE_SPEC="$COMMIT_RANGE"
fi

SHORT_SHA="$(git rev-parse --short "$FULL_SHA")"
if [ -z "$PR_TITLE" ]; then
    PR_TITLE="$(git log -1 --format='%s' "$FULL_SHA")"
fi

if [ -n "$UPSTREAM_PR" ]; then
    TOPIC_BRANCH="sync/upstream-main-pr-${UPSTREAM_PR}"
else
    TOPIC_BRANCH="sync/upstream-main-${SHORT_SHA}"
fi

UPSTREAM_PR_LINK=""
if [ -n "$UPSTREAM_PR" ]; then
    UPSTREAM_PR_LINK="https://github.com/${UPSTREAM_REPO}/pull/${UPSTREAM_PR}"
fi

PATCH_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$PATCH_DIR" "$WORK_DIR"' EXIT

echo "Formatting patches as-is (${RANGE_SPEC})..."
git format-patch --output-directory "$PATCH_DIR" "$RANGE_SPEC" >/dev/null
PATCH_COUNT="$(find "$PATCH_DIR" -name '*.patch' | wc -l | tr -d ' ')"
if [ "$PATCH_COUNT" = "0" ]; then
    die "No commits in ${RANGE_SPEC}; nothing to open downstream"
fi
echo "  ${PATCH_COUNT} patch(es); topic ${TOPIC_BRANCH}"

PR_BODY=$(cat <<EOF
## Upstream monorepo → downstream main

Commits applied **as-is** (no module-path rewrite). Upstream and downstream keep the same module names.

- **Upstream PR:** ${UPSTREAM_PR_LINK:-n/a}
- **Upstream commit:** [\`${FULL_SHA}\`](https://github.com/${UPSTREAM_REPO}/commit/${FULL_SHA})
- **Source:** [${UPSTREAM_REPO}](https://github.com/${UPSTREAM_REPO})
- **Topic branch:** \`${FORK_OWNER}:${TOPIC_BRANCH}\`

This PR has no OpenShift / Jira automation. Before merging downstream, retitle it with the downstream Jira key (for example \`OCPBUGS-123: ${PR_TITLE}\`). Saving that title runs \`standalone-pr-sync\` and opens the matching standalone PRs.
EOF
)

if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Would clone https://github.com/${DOWNSTREAM_REPO}.git (branch: ${BASE_BRANCH})"
    echo "[DRY-RUN] Would git am ${PATCH_COUNT} patch(es) onto ${BASE_BRANCH}"
    echo "[DRY-RUN] Would push ${TOPIC_BRANCH} to https://github.com/${FORK_OWNER}/${DOWNSTREAM_REPO##*/}.git"
    echo "[DRY-RUN] Would open PR on ${DOWNSTREAM_REPO} base ${BASE_BRANCH} head ${FORK_OWNER}:${TOPIC_BRANCH}"
    echo "[DRY-RUN] PR Title: ${PR_TITLE}"
    echo "[DRY-RUN] PR Body:"
    echo "${PR_BODY}"
    echo "=== Dry run finished ==="
    exit 0
fi

FORK_REPO="${FORK_OWNER}/$(basename "${DOWNSTREAM_REPO}")"
echo "Cloning ${DOWNSTREAM_REPO} (branch: ${BASE_BRANCH})..."
git clone --branch "$BASE_BRANCH" "https://github.com/${DOWNSTREAM_REPO}.git" "$WORK_DIR/downstream"

(
    cd "$WORK_DIR/downstream"
    git checkout -b "$TOPIC_BRANCH"
    echo "Applying patches with git am -3 (as-is)..."
    if ! git am -3 "$PATCH_DIR"/*.patch; then
        echo "Error: git am failed. Downstream main and this upstream range diverged." >&2
        echo "Resolve manually or retry with workflow_dispatch after the trees match." >&2
        git status --short >&2 || true
        git am --abort 2>/dev/null || true
        exit 1
    fi
    git remote add fork "https://github.com/${FORK_REPO}.git"
    echo "Pushing ${TOPIC_BRANCH} to ${FORK_REPO}..."
    git push -u fork "${TOPIC_BRANCH}" --force
)

need_cmd jq
echo "Checking for an existing PR on ${DOWNSTREAM_REPO}..."
EXISTING_JSON="$(gh api "repos/${DOWNSTREAM_REPO}/pulls?head=${FORK_OWNER}:${TOPIC_BRANCH}&state=open" 2>/dev/null || echo '[]')"
EXISTING_URL="$(echo "$EXISTING_JSON" | jq -r '.[0].html_url // empty')"
EXISTING_NUM="$(echo "$EXISTING_JSON" | jq -r '.[0].number // empty')"

if [ -z "$EXISTING_URL" ]; then
    MERGED_URL="$(gh api "repos/${DOWNSTREAM_REPO}/pulls?head=${FORK_OWNER}:${TOPIC_BRANCH}&state=closed" \
        --jq '[.[] | select(.merged_at != null)][0].html_url // empty' 2>/dev/null || true)"
    if [ -n "$MERGED_URL" ]; then
        die "Downstream PR already merged for ${TOPIC_BRANCH}: ${MERGED_URL}"
    fi
fi

refresh_pr() {
    local number="$1"
    echo "Updating existing PR #${number}..."
    gh api -X PATCH "repos/${DOWNSTREAM_REPO}/pulls/${number}" \
        -f title="${PR_TITLE}" \
        -f body="${PR_BODY}" >/dev/null
    echo "Updated https://github.com/${DOWNSTREAM_REPO}/pull/${number}"
}

if [ -n "$EXISTING_NUM" ]; then
    refresh_pr "$EXISTING_NUM"
    echo "=== Downstream PR bridge finished ==="
    exit 0
fi

echo "Creating PR on ${DOWNSTREAM_REPO}..."
set +e
CREATE_OUT="$(gh pr create \
    --repo "${DOWNSTREAM_REPO}" \
    --base "${BASE_BRANCH}" \
    --head "${FORK_OWNER}:${TOPIC_BRANCH}" \
    --title "${PR_TITLE}" \
    --body "${PR_BODY}" 2>&1)"
CREATE_RC=$?
set -e
if [ "$CREATE_RC" -eq 0 ]; then
    echo "Pull Request created: $(echo "$CREATE_OUT" | tail -n1)"
elif echo "$CREATE_OUT" | grep -q 'already exists'; then
    EXISTING_URL="$(echo "$CREATE_OUT" | grep -Eo 'https://github.com/[^[:space:]]+/pull/[0-9]+' | head -n1 || true)"
    EXISTING_NUM="$(echo "$EXISTING_URL" | grep -Eo '[0-9]+$' || true)"
    if [ -n "$EXISTING_NUM" ]; then
        refresh_pr "$EXISTING_NUM"
    else
        echo "$CREATE_OUT" >&2
        die "PR already exists but the URL could not be parsed"
    fi
else
    echo "$CREATE_OUT" >&2
    die "Failed to create PR on ${DOWNSTREAM_REPO}"
fi

echo "=== Downstream PR bridge finished ==="
