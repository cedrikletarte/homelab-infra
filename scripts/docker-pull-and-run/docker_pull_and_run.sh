#!/bin/bash
# =============================================================================
# docker_pull_and_run.sh — Auto-update Docker images
# Pulls latest images for every stack under homelab-infra/stacks and
# restarts stacks whose images changed
# =============================================================================

echo "===== Script docker auto-update START : $(date '+%Y-%m-%d %H:%M:%S') ====="

# ─── Config ──────────────────────────────────────────────────────────────────
WEBHOOK_URL="http://localhost:5678/webhook/homelab-alerts"
HOSTNAME=$(hostname)
BASE_DIR="/home/cedrik/homelab-infra/stacks"
UPDATED=""
ERRORS=""
PRUNED=""
LOGS=""

# ─── Scan all stacks ──────────────────────────────────────────────────────────
for dir in "$BASE_DIR"/*/; do
    STACK=$(basename "$dir")

    # Skip archived directories (starting with _)
    if [[ "$STACK" == _* ]]; then
        echo "Skipping archived stack: $STACK"
        continue
    fi

    COMPOSE_FILE="$dir/docker-compose.yml"
    if [[ -f "$COMPOSE_FILE" ]]; then
        echo "Checking $STACK"
        cd "$dir" || continue

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
                IMAGES=$(docker compose config | awk '/image:/ {print $2}')
                UPDATED+="• **$STACK**\n"
                for img in $IMAGES; do
                    UPDATED+="  ↳ \`$img\`\n"
                done
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
