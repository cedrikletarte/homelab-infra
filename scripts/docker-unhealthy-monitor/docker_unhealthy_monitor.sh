#!/bin/bash
# =============================================================================
# docker_unhealthy_monitor.sh — Monitor containers and auto-restart unhealthy ones
# Replaces n8n workflow "docker unhealthy monitoring" (SSH-based)
# Run every 5 minutes by cron (ansible/roles/maintenance), output in the journal
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

# Optional settings (defaults apply when absent from .env)
COOLDOWN_MINUTES="${COOLDOWN_MINUTES:-60}"                      # a container still failing is reported again after this delay
STATE_DIR="${STATE_DIR:-/var/tmp/docker-unhealthy-monitor}"    # one timestamp per reported container

HOSTNAME=$(hostname)

ALERTS=""
LOGS=""
FLAGGED=()
TO_RESTART=()
RESTARTED=""
RESTART_ERRORS=""

mkdir -p "$STATE_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────────────
# Only the containers compose started from a stack of this clone are restarted (infrastructure/<stack>
# or stacks/<stack>, archived `_` directories excluded). The others, such as the containers Nextcloud AIO
# creates itself or the portfolio deployed by CI, are reported only.
in_repo() {
    local dir=$1
    case "$dir" in
        "$REPO_DIR"/infrastructure/*|"$REPO_DIR"/stacks/*) [[ "$(basename "$dir")" != _* ]] ;;
        *) return 1 ;;
    esac
}

# True when the container was already reported less than COOLDOWN_MINUTES ago
recently_reported() {
    local stamp="$STATE_DIR/$1.last"
    [[ -f "$stamp" ]] && (( $(date +%s) - $(cat "$stamp") < COOLDOWN_MINUTES * 60 ))
}

# ─── Inspect all containers ───────────────────────────────────────────────────
# `docker ps` lists the running, restarting and paused containers: a stopped one was stopped on purpose,
# since every service runs with a restart policy
while IFS='|' read -r name status state workdir; do
    # Handled elsewhere (e.g. gluetun by gluetun_watchdog.sh)
    [[ " $IGNORE_CONTAINERS " == *" $name "* ]] && continue

    LOGS+="=== $name ===\nState: $state | Status: $status\n\n"

    case "$state" in
        running)
            [[ "$status" == *"(unhealthy)"* ]] || continue
            problem="⚠️ **$name** — UNHEALTHY | $status"
            ;;
        restarting)
            # A restart loop needs investigation: restarting it once more would not help
            problem="🔄 **$name** — RESTARTING LOOP | $status"
            ;;
        *)
            problem="❌ **$name** — State: \`$state\` | $status"
            ;;
    esac

    FLAGGED+=("$name")
    if recently_reported "$name"; then
        echo "$name still failing, already reported less than ${COOLDOWN_MINUTES}min ago"
        continue
    fi
    date +%s >"$STATE_DIR/$name.last"
    ALERTS+="$problem\n"
    [[ "$state" != "restarting" ]] && in_repo "$workdir" && TO_RESTART+=("$name")
done < <(docker ps --format '{{.Names}}|{{.Status}}|{{.State}}|{{.Label "com.docker.compose.project.working_dir"}}')

# A container that recovered is reported again as soon as it fails again
for stamp in "$STATE_DIR"/*.last; do
    [[ -e "$stamp" ]] || continue
    name=$(basename "$stamp" .last)
    [[ " ${FLAGGED[*]} " == *" $name "* ]] || rm -f "$stamp"
done

# ─── No new alert: exit silently ──────────────────────────────────────────────
[[ -z "$ALERTS" ]] && exit 0

# ─── Send alert notification ──────────────────────────────────────────────────
RESTART_PREVIEW=""
[[ ${#TO_RESTART[@]} -gt 0 ]] && RESTART_PREVIEW="\n\n🔁 Auto-restart triggered for: $(IFS=', '; echo "${TO_RESTART[*]}")"

notify docker_unhealthy_monitor "alert" "🚨 **Container Alert — $HOSTNAME**\n${ALERTS}${RESTART_PREVIEW}\n\n🕐 $(date '+%Y-%m-%d %H:%M:%S')" "$LOGS"

# ─── Auto-restart unhealthy containers ───────────────────────────────────────
for name in "${TO_RESTART[@]}"; do
    if OUTPUT=$(docker restart "$name" 2>&1); then
        RESTARTED+="✅ **$name** restarted\n"
        LOGS+="=== restart $name ===\n$OUTPUT\n\n"
    else
        RESTART_ERRORS+="❌ **$name** — restart failed\n"
        LOGS+="=== restart $name ===\nERROR: $OUTPUT\n\n"
    fi
done

# ─── Send restart result notification ────────────────────────────────────────
if [[ -n "$RESTARTED" || -n "$RESTART_ERRORS" ]]; then
    STATUS="repaired"
    [[ -n "$RESTART_ERRORS" ]] && STATUS="error"
    notify docker_unhealthy_monitor "$STATUS" "🔁 **Auto-Restart — $HOSTNAME**\n${RESTARTED}${RESTART_ERRORS}\n🕐 $(date '+%Y-%m-%d %H:%M:%S')" "$LOGS"
fi
