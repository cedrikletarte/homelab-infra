#!/bin/bash
# =============================================================================
# docker_unhealthy_monitor.sh — Monitor containers and auto-restart unhealthy ones
# Replaces n8n workflow "docker unhealthy monitoring" (SSH-based)
# Run via cron every 5 minutes:
#   */5 * * * * /home/cedrik/homelab-infra/scripts/docker-unhealthy-monitor/docker_unhealthy_monitor.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

HOSTNAME=$(hostname)

ALERTS=""
LOGS=""
TO_RESTART=()
TO_RESTART_DIRS=()
RESTARTED=""
RESTART_ERRORS=""

# ─── Build container → compose dir mapping ───────────────────────────────────
declare -A CONTAINER_DIR

for dir in "$HOMELAB_STACKS"/*/; do
    basename_dir=$(basename "$dir")
    [[ "$basename_dir" == _* ]] && continue

    compose_file="${dir}docker-compose.yml"
    [[ ! -f "$compose_file" ]] && continue

    while IFS='|' read -r container_name container_dir; do
        container_name=$(echo "$container_name" | xargs)
        [[ -n "$container_name" ]] && CONTAINER_DIR["$container_name"]="$dir"
    done < <(docker compose -f "$compose_file" ps --format "{{.Name}}|${dir}" 2>/dev/null)
done

# ─── Inspect all containers ───────────────────────────────────────────────────
while IFS='|' read -r name status state; do
    name=$(echo "$name" | xargs)
    status=$(echo "$status" | xargs)
    state=$(echo "$state" | xargs)

    # Handled elsewhere (e.g. gluetun by gluetun_watchdog.sh)
    [[ " $IGNORE_CONTAINERS " == *" $name "* ]] && continue

    LOGS+="=== $name ===\nState: $state | Status: $status\n\n"

    dir="${CONTAINER_DIR[$name]}"

    if [[ "$state" != "running" ]]; then
        ALERTS+="❌ **$name** — State: \`$state\` | $status\n"
        if [[ -n "$dir" ]]; then
            TO_RESTART+=("$name")
            TO_RESTART_DIRS+=("$dir")
        fi
    elif echo "$status" | grep -qi "unhealthy"; then
        ALERTS+="⚠️ **$name** — UNHEALTHY | $status\n"
        if [[ -n "$dir" ]]; then
            TO_RESTART+=("$name")
            TO_RESTART_DIRS+=("$dir")
        fi
    elif echo "$status" | grep -qi "restarting"; then
        ALERTS+="🔄 **$name** — RESTARTING LOOP | $status\n"
    fi
done < <(docker ps --format "{{.Names}}|{{.Status}}|{{.State}}")

# ─── No alerts: exit silently ─────────────────────────────────────────────────
[[ -z "$ALERTS" ]] && exit 0

# ─── Send alert notification ──────────────────────────────────────────────────
NOW=$(date '+%Y-%m-%d %H:%M:%S')
RESTART_PREVIEW=""
[[ ${#TO_RESTART[@]} -gt 0 ]] && RESTART_PREVIEW="\n\n🔁 Auto-restart triggered for: $(IFS=', '; echo "${TO_RESTART[*]}")"

ALERT_MESSAGE="🚨 **Container Alert — $HOSTNAME**\n${ALERTS}${RESTART_PREVIEW}\n\n🕐 $NOW"

JSON=$(jq -n \
    --arg content "$(echo -e "$ALERT_MESSAGE")" \
    --arg source "docker_unhealthy_monitor" \
    --arg status "alert" \
    --rawfile logs <(echo -e "$LOGS" | tail -c 100000) \
    '{content: $content, source: $source, status: $status, logs: $logs}')

curl -s -o /dev/null -H "Content-Type: application/json" -X POST --data-binary @- "$WEBHOOK_URL" <<<"$JSON"

# ─── Auto-restart unhealthy containers ───────────────────────────────────────
for i in "${!TO_RESTART[@]}"; do
    name="${TO_RESTART[$i]}"
    dir="${TO_RESTART_DIRS[$i]}"

    OUTPUT=$(cd "$dir" && docker compose restart "$name" 2>&1)
    EXIT=$?

    if [[ $EXIT -ne 0 ]]; then
        RESTART_ERRORS+="❌ **$name** — restart failed\n"
        LOGS+="=== restart $name ===\nERROR: $OUTPUT\n\n"
    else
        RESTARTED+="✅ **$name** restarted\n"
        LOGS+="=== restart $name ===\n$OUTPUT\n\n"
    fi
done

# ─── Send restart result notification ────────────────────────────────────────
NOW=$(date '+%Y-%m-%d %H:%M:%S')

if [[ -n "$RESTARTED" || -n "$RESTART_ERRORS" ]]; then
    RESTART_MESSAGE="🔁 **Auto-Restart — $HOSTNAME**\n"
    [[ -n "$RESTARTED" ]] && RESTART_MESSAGE+="$RESTARTED"
    [[ -n "$RESTART_ERRORS" ]] && RESTART_MESSAGE+="$RESTART_ERRORS"
    RESTART_MESSAGE+="\n🕐 $NOW"

    STATUS="repaired"
    [[ -n "$RESTART_ERRORS" ]] && STATUS="error"

    JSON=$(jq -n \
        --arg content "$(echo -e "$RESTART_MESSAGE")" \
        --arg source "docker_unhealthy_monitor" \
        --arg status "$STATUS" \
        --rawfile logs <(echo -e "$LOGS" | tail -c 100000) \
        '{content: $content, source: $source, status: $status, logs: $logs}')

    curl -s -o /dev/null -H "Content-Type: application/json" -X POST --data-binary @- "$WEBHOOK_URL" <<<"$JSON"
fi
