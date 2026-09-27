#!/bin/bash
# =============================================================================
# docker_pull_and_run.sh — Deploy what was merged on main
# Images are pinned in the compose files and bumped by Renovate merge requests,
# so deploying means: bring the clone up to date, then apply the compose files.
# - Refuses to run unless docker_backup.sh succeeded recently (--force bypasses)
# - Fast-forwards the clone to origin/main, never touching local work: with
#   unpushed commits or conflicting changes it reports and deploys the clone as is
# - Runs `docker compose up -d` on every running stack: it pulls the images that
#   are missing and recreates only the containers whose definition changed
# - Removes the images that recreated containers no longer use
# - --dry-run shows what would happen without changing anything
# =============================================================================

echo "===== Script docker deploy START : $(date '+%Y-%m-%d %H:%M:%S') ====="

# ─── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

# Optional settings (defaults apply when absent from .env)
BACKUP_MARKER="${BACKUP_MARKER:-/var/lib/docker-backup/last_success}"   # written by docker_backup.sh
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-180}"                     # weekly backup (Sun 03:00) vs daily deploy (02:00): 7 days + margin
SKIP_STACKS="${SKIP_STACKS:-nextcloud}"                                 # space-separated stack names
PULL_ATTEMPTS="${PULL_ATTEMPTS:-3}"                                     # a pull can fail for a passing reason (registry rate limit)
PULL_RETRY_WAIT="${PULL_RETRY_WAIT:-60}"                                # seconds between two attempts
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE=1
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done
COMPOSE_FLAGS=()
[[ $DRY_RUN -eq 1 ]] && COMPOSE_FLAGS=(--dry-run)

HOSTNAME=$(hostname)
SYNCED=""
DEPLOYED=""
REMOVED=""
WARNINGS=""
ERRORS=""
LOGS=""

# The clone belongs to a user and the script runs as root: git runs as the owner, so that root never
# leaves files in .git that the owner can no longer write, and the owner's SSH key is used for the fetch
REPO_OWNER=$(stat -c %U "$REPO_DIR")
repo_git() {
    if [[ "$(id -un)" == "$REPO_OWNER" ]]; then
        git -C "$REPO_DIR" "$@"
    else
        sudo -H -u "$REPO_OWNER" git -C "$REPO_DIR" "$@"
    fi
}

send_notification() {
    local msg="$1"
    local status="$2"
    local logs="$3"
    local json
    # Everything goes through files (--rawfile), never through arguments: a single argument is limited to
    # 128 KiB by the kernel. The content is capped below Discord's 2000 characters limit.
    json=$(jq -n \
        --rawfile content <(printf '%b' "$msg" | head -c 1900) \
        --arg source "docker_pull_and_run" \
        --arg status "$status" \
        --rawfile logs <(printf '%b' "$logs" | tail -c 100000) \
        '{content: $content, source: $source, status: $status, logs: $logs}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        --data-binary @- \
        "$WEBHOOK_URL" <<<"$json")
    [[ "$http_code" != "200" ]] && echo "ERROR: n8n webhook failed with HTTP $http_code"
}

# ─── Bring the clone up to date ──────────────────────────────────────────────
sync_repo() {
    local upstream="$GIT_REMOTE/$GIT_BRANCH" branch out ahead behind old
    branch=$(repo_git symbolic-ref --quiet --short HEAD)
    if [[ "$branch" != "$GIT_BRANCH" ]]; then
        WARNINGS+="• **git** — the clone is on \`${branch:-a detached HEAD}\`, not \`$GIT_BRANCH\`: deployed as it is\n"
        return
    fi
    if ! out=$(repo_git fetch --quiet "$GIT_REMOTE" "$GIT_BRANCH" 2>&1); then
        ERRORS+="• **git** — fetch failed, the clone is deployed as it is\n"
        LOGS+="=== git fetch ===\n$out\n\n"
        return
    fi
    ahead=$(repo_git rev-list --count "$upstream..HEAD")
    behind=$(repo_git rev-list --count "HEAD..$upstream")
    LOGS+="=== git ===\n$ahead local commit(s) not on $upstream, $behind new commit(s) on it\n\n"
    [[ $behind -eq 0 ]] && return
    if [[ $ahead -gt 0 ]]; then
        WARNINGS+="• **git** — $ahead local commit(s) not pushed and $behind new on \`$upstream\`: run \`git pull --rebase\` and push. Deployed the clone as it is\n"
        return
    fi
    old=$(repo_git rev-parse --short HEAD)
    if [[ $DRY_RUN -eq 1 ]]; then
        SYNCED="would fast-forward \`$old\` → \`$(repo_git rev-parse --short "$upstream")\` ($behind commit(s)); the stacks below are checked against the clone before it"
        return
    fi
    if out=$(repo_git merge --ff-only --quiet "$upstream" 2>&1); then
        SYNCED="\`$old\` → \`$(repo_git rev-parse --short HEAD)\` ($behind commit(s))"
    else
        WARNINGS+="• **git** — fast-forward refused (uncommitted changes in the way?): deployed the clone as it is\n"
        LOGS+="=== git merge ===\n$out\n\n"
    fi
}

# ─── Apply one stack ──────────────────────────────────────────────────────────
deploy_stack() {
    local dir="$1" stack="$2" old_images out code attempt changed img
    cd "$dir" || return

    # A stack with nothing running was stopped on purpose: do not start it
    if [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
        LOGS+="=== $stack : no running container, skipped ===\n\n"
        return
    fi
    old_images=$(docker compose ps -q | xargs -r docker inspect -f '{{.Image}}' | sort -u)

    for attempt in $(seq 1 "$PULL_ATTEMPTS"); do
        out=$(docker compose "${COMPOSE_FLAGS[@]}" up -d 2>&1)
        code=$?
        [[ $code -eq 0 ]] && break
        if [[ $attempt -lt $PULL_ATTEMPTS ]]; then
            echo "up -d failed for $stack (attempt $attempt/$PULL_ATTEMPTS), retrying in ${PULL_RETRY_WAIT}s"
            sleep "$PULL_RETRY_WAIT"
        fi
    done
    LOGS+="=== up -d : $stack ===\n$out\n\n"
    if [[ $code -ne 0 ]]; then
        ERRORS+="• **$stack** — \`docker compose up -d\` failed: \`$(echo "$out" | grep -iE 'error|failed' | tail -1)\`\n"
        return
    fi

    changed=$(echo "$out" | awk '$NF == "Recreated" || $NF == "Created" { print $(NF - 1) }' | grep -v '^[0-9a-f]\{12\}_' | sort -u | tr '\n' ' ')
    [[ -z "$changed" ]] && return
    DEPLOYED+="• **$stack** — ${changed% }\n"
    [[ $DRY_RUN -eq 1 ]] && return

    # Images the stack used before and that no container uses anymore (the previous version of an image)
    for img in $old_images; do
        [[ -n "$(docker ps -aq --filter "ancestor=$img")" ]] && continue
        if docker image rm -f "$img" >/dev/null 2>&1; then
            REMOVED+="${img:7:12} "
        fi
    done
}

# ─── Require a recent successful backup ──────────────────────────────────────
BLOCKED=0
if [[ $FORCE -ne 1 && $DRY_RUN -ne 1 ]]; then
    LAST_BACKUP=$(cat "$BACKUP_MARKER" 2>/dev/null)
    if [[ ! "$LAST_BACKUP" =~ ^[0-9]+$ ]] || (( $(date +%s) - LAST_BACKUP > BACKUP_MAX_AGE_HOURS * 3600 )); then
        BLOCKED=1
        ERRORS+="• **Deploy skipped** — no successful backup in the last ${BACKUP_MAX_AGE_HOURS}h (\`--force\` to bypass)\n"
        echo "ERROR: no successful backup in the last ${BACKUP_MAX_AGE_HOURS}h, deploy skipped"
    fi
fi

# ─── Sync, then apply every stack ─────────────────────────────────────────────
if [[ $BLOCKED -eq 0 ]]; then
    sync_repo
    for dir in "$REPO_DIR"/infrastructure/*/ "$REPO_DIR"/stacks/*/; do
        stack=$(basename "$dir")
        [[ "$stack" == _* || ! -f "$dir/docker-compose.yml" ]] && continue
        if [[ " $SKIP_STACKS " == *" $stack "* ]]; then
            LOGS+="=== $stack : skipped (SKIP_STACKS) ===\n\n"
            continue
        fi
        echo "Applying $stack"
        deploy_stack "$dir" "$stack"
    done
fi

# ─── Build notification message ───────────────────────────────────────────────
MESSAGE=""
STATUS="ok"
[[ $DRY_RUN -eq 1 ]] && MESSAGE+="🧪 **Dry run — nothing was changed**\n"
if [[ -n "$SYNCED" || -n "$DEPLOYED" ]]; then
    MESSAGE+="🔼 **Docker Deploy — $HOSTNAME**\n"
    [[ -n "$SYNCED" ]] && MESSAGE+="Git: $SYNCED\n"
    [[ -n "$DEPLOYED" ]] && MESSAGE+="Recreated containers:\n$DEPLOYED"
    [[ -n "$REMOVED" ]] && MESSAGE+="🧹 Previous images removed: \`${REMOVED% }\`\n"
    MESSAGE+="\n"
fi
if [[ -n "$WARNINGS" ]]; then
    MESSAGE+="⚠️ **Needs attention — $HOSTNAME**\n$WARNINGS\n"
    STATUS="alert"
fi
if [[ -n "$ERRORS" ]]; then
    MESSAGE+="❌ **Errors — $HOSTNAME**\n$ERRORS\n"
    STATUS="error"
fi
if [[ -z "$MESSAGE" ]]; then
    MESSAGE="✅ **Docker Deploy — $HOSTNAME**\nNothing to deploy, the clone is at \`$(repo_git rev-parse --short HEAD)\`.\n"
fi
MESSAGE+="🕐 $(date '+%Y-%m-%d %H:%M:%S')"

if [[ $DRY_RUN -eq 1 ]]; then
    printf '%b\n' "$MESSAGE"
else
    send_notification "$MESSAGE" "$STATUS" "$LOGS"
fi

echo "===== Script docker deploy END : $(date '+%Y-%m-%d %H:%M:%S') ====="
