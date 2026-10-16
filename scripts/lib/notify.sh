#!/bin/bash
# =============================================================================
# notify.sh — Report to the n8n "notifications" webhook (Discord + PostgreSQL log)
# Sourced by the maintenance scripts, after their .env (which sets WEBHOOK_URL):
#   source "$SCRIPT_DIR/../lib/notify.sh"
#   notify <source> <status> <content> [logs]
# content and logs may hold escapes such as \n (interpreted like `printf %b`).
# n8n journals every message in homelab_alerts and only posts the non-ok ones to Discord.
# Returns non-zero when the webhook does not answer HTTP 200.
# =============================================================================

notify() {
    local source=$1 status=$2 content=$3 logs=${4:-} json http_code
    # Everything goes through files (--rawfile), never through arguments: a single argument is limited to
    # 128 KiB by the kernel. The content is capped below Discord's 2000 characters limit.
    json=$(jq -n \
        --rawfile content <(printf '%b' "$content" | head -c 1900) \
        --arg source "$source" \
        --arg status "$status" \
        --rawfile logs <(printf '%b' "$logs" | tail -c 100000) \
        '{content: $content, source: $source, status: $status, logs: $logs}')
    if [[ -z "$json" ]]; then
        echo "WARNING: could not build the notification (content: ${#content} bytes, logs: ${#logs} bytes); sending a minimal one"
        json=$(jq -n --arg source "$source" --arg status "$status" \
            '{source: $source, status: $status, logs: "",
              content: "\($source) finished with status \($status), but the full report could not be built. See the journal on the server."}')
    fi
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        --data-binary @- \
        "$WEBHOOK_URL" <<<"$json")
    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: n8n webhook answered HTTP $http_code"
        return 1
    fi
}
