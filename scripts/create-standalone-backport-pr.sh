#!/bin/bash
#
# create-standalone-backport-pr.sh
#
# Extracts component diffs from a monorepo commit or commit range,
# pushes topic branches to a dedicated bot fork, and opens cross-repository
# Pull Requests against the standalone repositories for legacy ART builds.
#
# Zero write permissions are required on the upstream standalone repositories.
#
# Usage:
#   create-standalone-backport-pr.sh [options]
#
# Options:
#   --branch NAME          Target base release branch (e.g. main, release-4.22, release-4.21) [required]
#   --commit SHA           Single monorepo commit SHA to mirror (default: HEAD)
#   --range FROM..TO       Commit range to mirror (e.g. HEAD~1..HEAD or origin/release-4.22..HEAD)
#   --components LIST      Comma-separated list of components: ptpop,lptpd,cep (default: auto-detect)
#   --fork-owner OWNER     Bot or user fork owner on GitHub (default: $SYNC_BOT_FORK_OWNER or ptp-monorepo-sync-bot)
#   --monorepo-repo REPO   Monorepo GitHub repository (default: redhat-cne/downstream-ptp-operator-monorepo)
#   --dry-run              Generate patches and format PR without pushing or opening PRs
#   -h, --help             Show this help message
#
# Examples:
#   ./scripts/create-standalone-backport-pr.sh --branch release-4.22 --commit HEAD
#   ./scripts/create-standalone-backport-pr.sh --branch release-4.21 --range origin/release-4.21..HEAD
#   ./scripts/create-standalone-backport-pr.sh --branch release-4.22 --components lptpd,cep --dry-run
#

set -euo pipefail

export GH_PAGER=cat
export GIT_PAGER=cat

TARGET_BRANCH=""
COMMIT_SHA=""
COMMIT_RANGE=""
COMPONENTS_RAW=""
FORK_OWNER="${SYNC_BOT_FORK_OWNER:-ptp-monorepo-sync-bot}"
MONOREPO_REPO="${MONOREPO_REPO:-redhat-cne/downstream-ptp-operator-monorepo}"
DRY_RUN=false

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
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
        --branch)
            [ $# -ge 2 ] || die "--branch requires an argument"
            TARGET_BRANCH="$2"
            shift 2
            ;;
        --commit)
            [ $# -ge 2 ] || die "--commit requires an argument"
            COMMIT_SHA="$2"
            shift 2
            ;;
        --range)
            [ $# -ge 2 ] || die "--range requires an argument"
            COMMIT_RANGE="$2"
            shift 2
            ;;
        --components)
            [ $# -ge 2 ] || die "--components requires an argument"
            COMPONENTS_RAW="$2"
            shift 2
            ;;
        --fork-owner)
            [ $# -ge 2 ] || die "--fork-owner requires an argument"
            FORK_OWNER="$2"
            shift 2
            ;;
        --monorepo-repo)
            [ $# -ge 2 ] || die "--monorepo-repo requires an argument"
            MONOREPO_REPO="$2"
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
            die "Unknown option: $1"
            ;;
    esac
done

[ -n "$TARGET_BRANCH" ] || die "--branch <NAME> is required (e.g. --branch release-4.22)"

need_cmd git
if [ "$DRY_RUN" = false ]; then
    need_cmd gh
fi

# Determine commit range
if [ -n "$COMMIT_RANGE" ]; then
    RANGE="$COMMIT_RANGE"
    FULL_SHA="$(git rev-parse "${RANGE#*..}")"
    BASE_SHA="$(git rev-parse "${RANGE%..*}")"
elif [ -n "$COMMIT_SHA" ]; then
    FULL_SHA="$(git rev-parse "$COMMIT_SHA")"
    RANGE="${FULL_SHA}~1..${FULL_SHA}"
    BASE_SHA="$(git rev-parse "${FULL_SHA}~1")"
else
    FULL_SHA="$(git rev-parse HEAD)"
    RANGE="${FULL_SHA}~1..${FULL_SHA}"
    BASE_SHA="$(git rev-parse "${FULL_SHA}~1")"
fi

SHORT_SHA="$(git rev-parse --short=8 "$FULL_SHA")"
COMMIT_TITLE="$(git log -1 --format='%s' "$FULL_SHA")"
AUTHOR_NAME="$(git log -1 --format='%an' "$FULL_SHA")"
AUTHOR_EMAIL="$(git log -1 --format='%ae' "$FULL_SHA")"

echo "=== Outbound Monorepo to Standalone PR Bridge ==="
echo "Monorepo Repo : ${MONOREPO_REPO}"
echo "Base Branch   : ${TARGET_BRANCH}"
echo "Commit Range  : ${RANGE}"
echo "Head SHA      : ${FULL_SHA} (${SHORT_SHA})"
echo "Commit Title  : ${COMMIT_TITLE}"
echo "Author        : ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"
echo "Fork Owner    : ${FORK_OWNER}"
echo "Dry Run       : ${DRY_RUN}"
echo "================================================"

# Get modified files in the range
CHANGED_FILES="$(git diff --name-only "$RANGE")"
if [ -z "$CHANGED_FILES" ]; then
    echo "No files modified in range ${RANGE}. Nothing to bridge."
    exit 0
fi

# Auto-detect components if not explicitly provided
DETECTED_COMPONENTS=""
if [ -n "$COMPONENTS_RAW" ]; then
    DETECTED_COMPONENTS="$COMPONENTS_RAW"
else
    COMP_ARRAY=()
    # Check linuxptp-daemon
    if echo "$CHANGED_FILES" | grep -q '^pkg/linuxptp-daemon/'; then
        COMP_ARRAY+=("lptpd")
    fi
    # Check cloud-event-proxy
    if echo "$CHANGED_FILES" | grep -q '^pkg/cloud-event-proxy/'; then
        COMP_ARRAY+=("cep")
    fi
    # Check operator root files
    if echo "$CHANGED_FILES" | grep -v '^pkg/' | grep -v '^\.tekton/' | grep -v '^\.konflux/' | grep -v '^\.github/' | grep -q .; then
        COMP_ARRAY+=("ptpop")
    fi
    DETECTED_COMPONENTS="$(IFS=,; echo "${COMP_ARRAY[*]}")"
fi

echo "Target Components: ${DETECTED_COMPONENTS:-none}"
if [ -z "$DETECTED_COMPONENTS" ]; then
    echo "No relevant component files touched in this commit range. Exiting."
    exit 0
fi

# Component configuration mapping function
get_component_info() {
    local code="$1"
    case "$code" in
        ptpop)
            UPSTREAM_REPO="openshift/ptp-operator"
            REPO_NAME="ptp-operator"
            COMPONENT_NAME="PTP Operator"
            SUBPATH=""
            ;;
        lptpd)
            UPSTREAM_REPO="openshift/linuxptp-daemon"
            REPO_NAME="linuxptp-daemon"
            COMPONENT_NAME="LinuxPTP Daemon"
            SUBPATH="pkg/linuxptp-daemon"
            ;;
        cep)
            UPSTREAM_REPO="redhat-cne/cloud-event-proxy"
            REPO_NAME="cloud-event-proxy"
            COMPONENT_NAME="Cloud Event Proxy"
            SUBPATH="pkg/cloud-event-proxy"
            ;;
        *)
            die "Unknown component code: $code"
            ;;
    esac
}

TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/ptp-sync-XXXXXX")"
cleanup() {
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

IFS=',' read -ra COMPS <<< "$DETECTED_COMPONENTS"

for COMP in "${COMPS[@]}"; do
    [ -n "$COMP" ] || continue
    get_component_info "$COMP"

    echo ""
    echo "--------------------------------------------------"
    echo "Processing Component: ${COMPONENT_NAME} (${COMP})"
    echo "Upstream Repo       : ${UPSTREAM_REPO}"
    echo "Target Fork         : ${FORK_OWNER}/${REPO_NAME}"
    echo "Target Branch       : ${TARGET_BRANCH}"
    echo "--------------------------------------------------"

    PATCH_DIR="${TMP_BASE}/patches_${COMP}"
    mkdir -p "$PATCH_DIR"

    # Extract component-specific patches (-o must precede pathspecs '--')
    if [ "$COMP" = "ptpop" ]; then
        git format-patch -o "$PATCH_DIR" "$RANGE" \
            -- . ":(exclude)pkg" ":(exclude).tekton" ":(exclude).konflux" ":(exclude).github" >/dev/null || true
    else
        git format-patch -o "$PATCH_DIR" --relative="$SUBPATH" "$RANGE" >/dev/null || true
    fi

    PATCH_COUNT="$(find "$PATCH_DIR" -type f -name '*.patch' | wc -l | tr -d ' ')"
    if [ "$PATCH_COUNT" -eq 0 ]; then
        echo "No patch generated for ${COMPONENT_NAME}. Skipping."
        continue
    fi
    echo "Extracted ${PATCH_COUNT} patch file(s) for ${COMPONENT_NAME}."

    TOPIC_BRANCH="sync/monorepo-${TARGET_BRANCH}-${SHORT_SHA}"
    PR_TITLE="[Monorepo Sync] ${COMMIT_TITLE}"

    PR_BODY=$(cat <<EOF
## Automated Sync from Downstream Monorepo
- **Monorepo Commit:** [\`${FULL_SHA}\`](https://github.com/${MONOREPO_REPO}/commit/${FULL_SHA})
- **Monorepo Commit Short SHA:** \`${SHORT_SHA}\`
- **Original Monorepo Repository:** [${MONOREPO_REPO}](https://github.com/${MONOREPO_REPO})
- **Original Author:** ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
- **Target Component:** ${COMPONENT_NAME}
- **Release Branch:** ${TARGET_BRANCH}
- **Source Fork Branch:** \`${FORK_OWNER}:${TOPIC_BRANCH}\`

This PR was automatically generated to mirror changes from the downstream PTP monorepo for ART build consumption.
EOF
)

    PR_COMMENT=$(cat <<EOF
### Monorepo Provenance Traceability
- Source Monorepo: \`${MONOREPO_REPO}\`
- Commit SHA: [\`${FULL_SHA}\`](https://github.com/${MONOREPO_REPO}/commit/${FULL_SHA})
- Monorepo Branch: \`${TARGET_BRANCH}\`
- Author: ${AUTHOR_NAME} <${AUTHOR_EMAIL}>
EOF
)

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would clone https://github.com/${UPSTREAM_REPO}.git (branch: ${TARGET_BRANCH})"
        echo "[DRY-RUN] Would create topic branch: ${TOPIC_BRANCH}"
        echo "[DRY-RUN] Would apply ${PATCH_COUNT} patch(es) with git am -3"
        echo "[DRY-RUN] Would push to https://github.com/${FORK_OWNER}/${REPO_NAME}.git"
        echo "[DRY-RUN] Would open PR against ${UPSTREAM_REPO} (base: ${TARGET_BRANCH}, head: ${FORK_OWNER}:${TOPIC_BRANCH})"
        echo "[DRY-RUN] PR Title: ${PR_TITLE}"
        echo "[DRY-RUN] PR Body:"
        echo "${PR_BODY}"
        echo "[DRY-RUN] Provenance PR Comment:"
        echo "${PR_COMMENT}"
        continue
    fi

    # Clone standalone repo
    STANDALONE_DIR="${TMP_BASE}/repo_${COMP}"
    echo "Cloning ${UPSTREAM_REPO} (branch: ${TARGET_BRANCH})..."
    TARGET_BASE="${TARGET_BRANCH}"
    if ! git clone --depth 50 --branch "${TARGET_BRANCH}" "https://github.com/${UPSTREAM_REPO}.git" "$STANDALONE_DIR" 2>/dev/null; then
        if [ "$TARGET_BRANCH" = "main" ] && git clone --depth 50 --branch "master" "https://github.com/${UPSTREAM_REPO}.git" "$STANDALONE_DIR" 2>/dev/null; then
            echo "Note: ${UPSTREAM_REPO} uses 'master' as its default development branch; using 'master' as base."
            TARGET_BASE="master"
        else
            echo "Error: Failed to clone ${UPSTREAM_REPO} at branch ${TARGET_BRANCH}" >&2
            continue
        fi
    fi

    (
        cd "$STANDALONE_DIR"
        git checkout -b "$TOPIC_BRANCH"

        echo "Applying patches with git am -3..."
        for patch in "$PATCH_DIR"/*.patch; do
            [ -f "$patch" ] || continue
            # Append Monorepo-Commit trailer to patch before applying if not present
            if ! grep -q "Monorepo-Commit:" "$patch"; then
                sed -i.bak "/^---$/i\\
Monorepo-Commit: ${FULL_SHA}\\
" "$patch" && rm -f "${patch}.bak"
            fi
        done

        if ! git am -3 "$PATCH_DIR"/*.patch; then
            echo "Error: git am failed to apply patches cleanly for ${COMPONENT_NAME}." >&2
            echo "Aborting git am and skipping PR creation for this component." >&2
            git am --abort 2>/dev/null || true
            exit 1
        fi

        echo "Configuring fork remote: https://github.com/${FORK_OWNER}/${REPO_NAME}.git"
        git remote add fork "https://github.com/${FORK_OWNER}/${REPO_NAME}.git"

        echo "Pushing topic branch ${TOPIC_BRANCH} to fork..."
        git push -u fork "${TOPIC_BRANCH}" --force
    )

    # Check for existing PR
    echo "Checking for existing PR on ${UPSTREAM_REPO}..."
    EXISTING_PR="$(gh pr list --repo "${UPSTREAM_REPO}" --head "${FORK_OWNER}:${TOPIC_BRANCH}" --state all --json number,url,state -q '.[0] | "\(.state): \(.url)"' || true)"

    if [ -n "$EXISTING_PR" ] && [ "$EXISTING_PR" != "null" ]; then
        echo "A Pull Request already exists for this topic branch: ${EXISTING_PR}"
    else
        echo "Creating cross-repository Pull Request on ${UPSTREAM_REPO}..."
        CREATED_PR_URL="$(gh pr create \
            --repo "${UPSTREAM_REPO}" \
            --base "${TARGET_BASE}" \
            --head "${FORK_OWNER}:${TOPIC_BRANCH}" \
            --title "${PR_TITLE}" \
            --body "${PR_BODY}")"

        echo "Pull Request created successfully: ${CREATED_PR_URL}"

        echo "Posting provenance traceability comment..."
        gh pr comment "${CREATED_PR_URL}" --body "${PR_COMMENT}" || echo "Warning: failed to post comment on ${CREATED_PR_URL}"
    fi

done

echo ""
echo "=== Monorepo to Standalone PR Bridge Finished Successfully ==="
