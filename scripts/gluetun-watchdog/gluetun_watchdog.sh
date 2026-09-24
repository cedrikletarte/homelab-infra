#!/bin/bash
# =============================================================================
# gluetun_watchdog.sh — Regenerate a dead PIA WireGuard config for gluetun
# When a gluetun container stays unhealthy while the host is online, its PIA
# server was retired or its key dropped: register a new key, update
# SERVER_NAMES and recreate gluetun + the containers sharing its network.
# Run via cron every 5 minutes (as root).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

PIA_WIREGUARD="${PIA_WIREGUARD:-$SCRIPT_DIR/../pia-wireguard/pia_wireguard.sh}"
UNHEALTHY_MINUTES="${UNHEALTHY_MINUTES:-15}"
COOLDOWN_MINUTES="${COOLDOWN_MINUTES:-60}"
HEALTHY_TIMEOUT="${HEALTHY_TIMEOUT:-180}"
STATE_DIR="${STATE_DIR:-/var/tmp/gluetun-watchdog}"
WG_MOUNT="/gluetun/wireguard/wg0.conf"

HOSTNAME=$(hostname)

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
    local status=$1 message=$2 logs=$3
    JSON=$(jq -n \
        --arg content "$(echo -e "$message\n\n🕐 $(date '+%Y-%m-%d %H:%M:%S')")" \
        --arg source "gluetun_watchdog" \
        --arg status "$status" \
        --arg logs "$logs" \
        '{content: $content, source: $source, status: $status, logs: $logs}')
    curl -s -o /dev/null -H "Content-Type: application/json" -X POST -d "$JSON" "$WEBHOOK_URL"
}

internet_up() {
    ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1
}

# Minutes the container has been failing its healthcheck (0 when not unhealthy)
unhealthy_minutes() {
    local status streak interval
    read -r status streak interval < <(docker inspect "$1" \
        --format '{{.State.Health.Status}} {{.State.Health.FailingStreak}} {{json .Config.Healthcheck.Interval}}' 2>/dev/null)
    [[ "$status" == "unhealthy" ]] || { echo 0; return; }
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=30000000000
    echo $(( streak * interval / 1000000000 / 60 ))
}

wait_healthy() {
    local waited=0
    while (( waited < HEALTHY_TIMEOUT )); do
        [[ $(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null) == "healthy" ]] && return 0
        sleep 5
        waited=$(( waited + 5 ))
    done
    return 1
}

handle() {
    local container=$1 region=$2
    local minutes
    minutes=$(unhealthy_minutes "$container")
    (( minutes > 0 )) || return 0
    if (( minutes < UNHEALTHY_MINUTES )); then
        log "$container unhealthy for ${minutes}min (< ${UNHEALTHY_MINUTES}min), waiting"
        return 0
    fi
    if ! internet_up; then
        log "$container unhealthy but the host is offline, skipping"
        return 0
    fi

    local stamp="$STATE_DIR/$container.last"
    if [[ -f "$stamp" ]] && (( $(date +%s) - $(cat "$stamp") < COOLDOWN_MINUTES * 60 )); then
        log "$container still unhealthy, last regeneration < ${COOLDOWN_MINUTES}min ago, skipping"
        return 0
    fi
    date +%s >"$stamp"

    local workdir compose_files service wg_conf env_file
    workdir=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
    compose_files=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
    service=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.service"}}')
    wg_conf=$(docker inspect "$container" --format "{{range .Mounts}}{{if eq .Destination \"$WG_MOUNT\"}}{{.Source}}{{end}}{{end}}")
    env_file="$workdir/.env"

    if [[ -z "$workdir" || -z "$service" || ! -f "$wg_conf" ]]; then
        notify "error" "❌ **Gluetun watchdog — $HOSTNAME**\n**$container** unhealthy for ${minutes}min but can't be regenerated: not a compose container or no $WG_MOUNT bind mount"
        return 1
    fi

    local compose=(docker compose --project-directory "$workdir")
    local f
    IFS=',' read -ra files <<<"$compose_files"
    for f in "${files[@]}"; do compose+=(-f "$f"); done

    # Why it died: retired server (unreachable) or dropped key (reachable)
    local old_cn old_ip cause
    old_cn=$(grep -E '^SERVER_NAMES=' "$env_file" | cut -d= -f2-)
    old_ip=$(awk -F' *= *' '/^Endpoint/ { split($2, a, ":"); print a[1] }' "$wg_conf")
    if [[ -z "$old_cn" ]]; then
        cause="server $old_ip not checked, no SERVER_NAMES in $env_file"
    elif [[ $("$PIA_WIREGUARD" probe "$old_ip" "$old_cn" 2>/dev/null) == OK* ]]; then
        cause="server $old_cn ($old_ip) still up, key likely dropped by PIA"
    else
        cause="server $old_cn ($old_ip) unreachable, likely retired by PIA"
    fi
    log "$container unhealthy for ${minutes}min: $cause"

    # Containers with network_mode service:<gluetun> lose their network when gluetun is recreated
    local dependents
    dependents=$("${compose[@]}" config --format json 2>/dev/null \
        | jq -r --arg m "service:$service" '.services | to_entries[] | select(.value.network_mode == $m) | .key')

    if [[ -n "${DRY_RUN:-}" ]]; then
        log "DRY_RUN: would regenerate $wg_conf in $region, update $env_file, recreate $service $(echo $dependents)"
        rm -f "$stamp"
        return 0
    fi

    local gen_log new_cn
    gen_log=$(mktemp)
    if ! new_cn=$("$PIA_WIREGUARD" generate "$region" -o "$wg_conf" 2>"$gen_log" </dev/null) || [[ -z "$new_cn" ]]; then
        notify "error" "❌ **Gluetun watchdog — $HOSTNAME**\n**$container** unhealthy for ${minutes}min ($cause)\nConfig regeneration in \`$region\` failed, next attempt in ${COOLDOWN_MINUTES}min" "$(cat "$gen_log")"
        log "regeneration failed: $(tail -1 "$gen_log")"
        rm -f "$gen_log"
        return 1
    fi

    local env_note=""
    if grep -qE '^SERVER_NAMES=' "$env_file"; then
        sed -i "s/^SERVER_NAMES=.*/SERVER_NAMES=$new_cn/" "$env_file"
    elif grep -q 'SERVER_NAMES' "${files[@]}"; then
        env_note="\n⚠️ SERVER_NAMES not found in \`$env_file\`, set it to \`$new_cn\`"
    fi

    local up_out
    # shellcheck disable=SC2086
    up_out=$("${compose[@]}" up -d --force-recreate "$service" $dependents 2>&1)
    local logs
    logs="$(cat "$gen_log")\n\n$up_out"
    rm -f "$gen_log"

    if wait_healthy "$container"; then
        notify "ok" "✅ **Gluetun watchdog — $HOSTNAME**\n**$container** was unhealthy for ${minutes}min ($cause)\nNew config: \`$new_cn\` ($region), recreated: $service $(echo $dependents)$env_note" "$(echo -e "$logs")"
        log "$container healthy again on $new_cn"
    else
        notify "error" "❌ **Gluetun watchdog — $HOSTNAME**\n**$container** regenerated on \`$new_cn\` ($region) but still not healthy after ${HEALTHY_TIMEOUT}s$env_note" "$(echo -e "$logs")"
        log "$container not healthy after regeneration on $new_cn"
    fi
}

# GLUETUN_INSTANCES: space-separated "container:region" pairs
for instance in $GLUETUN_INSTANCES; do
    handle "${instance%%:*}" "${instance#*:}"
done
