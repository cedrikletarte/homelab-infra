#!/bin/bash
# =============================================================================
# docker_pull_and_run.sh — Auto-update Docker images
# Pulls latest images for every stack under homelab-infra/stacks and
# restarts stacks whose images changed.
# - Refuses to run unless docker_backup.sh succeeded recently (--force bypasses)
# - Skips stacks listed in SKIP_STACKS (e.g. Nextcloud AIO updates itself)
# - Reports the previous image digest of every updated image, to allow a rollback
#   with `image: name@sha256:...`
# =============================================================================

echo "===== Script docker auto-update START : $(date '+%Y-%m-%d %H:%M:%S') ====="

# ─── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

# Optional settings (defaults apply when absent from .env)
BACKUP_MARKER="${BACKUP_MARKER:-/var/lib/docker-backup/last_success}"   # written by docker_backup.sh
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-180}"                     # weekly backup (Sun 03:00) vs daily update (02:00): 7 days + margin
SKIP_STACKS="${SKIP_STACKS:-nextcloud}"                                 # space-separated stack names

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

HOSTNAME=$(hostname)
UPDATED=""
ERRORS=""
PRUNED=""
LOGS=""

# Local digest of an image (repo@sha256:...), empty if the image has none
image_digest() {
    docker image inspect "$1" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null
}

# ─── Require a recent successful backup ──────────────────────────────────────
BLOCKED=0
if [[ $FORCE -ne 1 ]]; then
    LAST_BACKUP=$(cat "$BACKUP_MARKER" 2>/dev/null)
    if [[ ! "$LAST_BACKUP" =~ ^[0-9]+$ ]] || (( $(date +%s) - LAST_BACKUP > BACKUP_MAX_AGE_HOURS * 3600 )); then
        BLOCKED=1
        ERRORS+="• **Updates skipped** — no successful backup in the last ${BACKUP_MAX_AGE_HOURS}h (\`--force\` to bypass)\n"
        echo "ERROR: no successful backup in the last ${BACKUP_MAX_AGE_HOURS}h, updates skipped"
    fi
fi

# ─── Scan all stacks ──────────────────────────────────────────────────────────
for dir in "$BASE_DIR"/*/; do
    [[ $BLOCKED -eq 1 ]] && break
    STACK=$(basename "$dir")

    # Skip archived directories (starting with _)
    if [[ "$STACK" == _* ]]; then
        echo "Skipping archived stack: $STACK"
        continue
    fi

    # Skip stacks that manage their own updates
    if [[ " $SKIP_STACKS " == *" $STACK "* ]]; then
        echo "Skipping excluded stack: $STACK"
        LOGS+="=== skipped : $STACK (SKIP_STACKS) ===\n\n"
        continue
    fi

    COMPOSE_FILE="$dir/docker-compose.yml"
    if [[ -f "$COMPOSE_FILE" ]]; then
        echo "Checking $STACK"
        cd "$dir" || continue

        # Remember the current digest of each image, to report it if it changes
        declare -A OLD_DIGEST=()
        for img in $(docker compose config --images 2>/dev/null); do
            OLD_DIGEST["$img"]=$(image_digest "$img")
        done

        # Pull images and capture output
        PULL_OUTPUT=$(docker compose pull 2>&1)
        PULL_EXIT=$?
        LOGS+="=== pull : $STACK ===\n$PULL_OUTPUT\n\n"

        # Check for pull errors
        if [[ $PULL_EXIT -ne 0 ]]; then
            ERROR_DETAIL=$(echo "$PULL_OUTPUT" | grep -i "error\|failed\|not found" | head -2 | tr '\n' ' ')
            ERRORS+="• **$STACK** — pull failed: \`$ERROR_DETAIL\`\n"
            echo "ERROR: pull failed for $STACK"
            echo "$PULL_OUTPUT"
            continue
        fi

        # Check if anything was updated
        if echo "$PULL_OUTPUT" | grep -Eqi "Downloaded newer image|Pull complete"; then
            echo "Update found for $STACK, restarting..."

            # Restart and capture output
            UP_OUTPUT=$(docker compose up -d 2>&1)
            UP_EXIT=$?
            LOGS+="=== up -d : $STACK ===\n$UP_OUTPUT\n\n"

            if [[ $UP_EXIT -ne 0 ]]; then
                ERRORS+="• **$STACK** — restart failed\n"
                echo "ERROR: restart failed for $STACK"
                echo "$UP_OUTPUT"
            else
                CHANGED=""
                for img in "${!OLD_DIGEST[@]}"; do
                    NEW_DIGEST=$(image_digest "$img")
                    [[ "$NEW_DIGEST" == "${OLD_DIGEST[$img]}" ]] && continue
                    CHANGED+="  ↳ \`$img\`\n"
                    if [[ -n "${OLD_DIGEST[$img]}" ]]; then
                        CHANGED+="     ↩ rollback : \`${OLD_DIGEST[$img]}\`\n"
                    else
                        CHANGED+="     ↩ no previous local image\n"
                    fi
                    LOGS+="digest $STACK $img : ${OLD_DIGEST[$img]:-none} -> ${NEW_DIGEST:-none}\n"
                done
                [[ -n "$CHANGED" ]] && UPDATED+="• **$STACK**\n$CHANGED"
            fi
        fi
    fi
done

# ─── Prune unused images if any update occurred ───────────────────────────────
if [[ -n "$UPDATED" ]]; then
    echo "Pruning unused Docker images..."
    PRUNE_OUTPUT=$(docker image prune -f --filter "until=168h" 2>&1)
    PRUNE_EXIT=$?
    LOGS+="=== image prune ===\n$PRUNE_OUTPUT\n\n"

    if [[ $PRUNE_EXIT -ne 0 ]]; then
        ERRORS+="• **image prune** — cleanup failed\n"
        echo "ERROR: image prune failed"
    else
        RECLAIMED=$(echo "$PRUNE_OUTPUT" | grep -i "reclaimed" | tail -1)
        if [[ -n "$RECLAIMED" ]]; then
            PRUNED="🧹 **Images cleaned** — $RECLAIMED\n"
        else
            PRUNED="🧹 **Images cleaned** — no orphaned images found\n"
        fi
        echo "Prune done: $RECLAIMED"
    fi
fi

# ─── Build notification message ───────────────────────────────────────────────
MESSAGE=""
STATUS="ok"

if [[ -n "$UPDATED" ]]; then
    MESSAGE+="🔼 **Docker Images Updated — $HOSTNAME**\n"
    MESSAGE+="$UPDATED\n"
fi
if [[ -n "$PRUNED" ]]; then
    MESSAGE+="$PRUNED\n"
fi
if [[ -n "$ERRORS" ]]; then
    MESSAGE+="❌ **Errors — $HOSTNAME**\n"
    MESSAGE+="$ERRORS\n"
    STATUS="error"
fi
if [[ -z "$UPDATED" && -z "$ERRORS" ]]; then
    MESSAGE="✅ **Docker Update Check — $HOSTNAME**\nNo Docker images were updated.\n"
fi

MESSAGE+="🕐 $(date '+%Y-%m-%d %H:%M:%S')"

# ─── Send to n8n ─────────────────────────────────────────────────────────────
JSON=$(jq -n \
    --arg content "$(echo -e "$MESSAGE")" \
    --arg source "docker_pull_and_run" \
    --arg status "$STATUS" \
    --arg logs "$(echo -e "$LOGS")" \
    '{content: $content, source: $source, status: $status, logs: $logs}')

CURL_EXIT=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$JSON" \
    "$WEBHOOK_URL")

if [[ "$CURL_EXIT" != "200" ]]; then
    echo "ERROR: n8n webhook failed with HTTP $CURL_EXIT"
fi

echo "===== Script docker auto-update END : $(date '+%Y-%m-%d %H:%M:%S') ====="
