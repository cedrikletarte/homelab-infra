#!/bin/bash
echo "===== Script SMART START : $(date '+%Y-%m-%d %H:%M:%S') ====="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/.env"
set +a

HOSTNAME=$(hostname)
ALERTS=""
LOGS=""

DISKS=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')

for DISK in $DISKS; do
    # SMART global state
    HEALTH=$($SMARTCTL -H "$DISK" | awk -F: '/SMART overall-health/ {print $2}')
    HEALTH=$(echo "$HEALTH" | xargs)

    # Last SMART test
    LAST_TEST=$($SMARTCTL -l selftest "$DISK" | awk '/^#/{print; exit}')

    # Reallocated sectors
    REALLOC=$($SMARTCTL -A "$DISK" | awk '/Reallocated_Sector_Ct/ {print $10}')

    # Accumulate logs
    LOGS+="=== $DISK ===\n"
    LOGS+="Health     : $HEALTH\n"
    LOGS+="Reallocated: $REALLOC\n"
    LOGS+="Last test  : $LAST_TEST\n\n"

    if ! echo "$HEALTH" | grep -qi "PASSED"; then
        ALERTS+="❌ $DISK : SMART HEALTH = $HEALTH\n"
    fi

    if [[ "$REALLOC" -gt 0 ]]; then
        ALERTS+="⚠️ $DISK : $REALLOC reallocated sectors\n"
    fi

    if ! echo "$LAST_TEST" | grep -qi "Completed without error"; then
        ALERTS+="⚠️ $DISK : Last SMART test → $LAST_TEST\n"
    fi
done

# Build Discord message
if [[ -n "$ALERTS" ]]; then
    MESSAGE="🖥️ **SMART ALERT – $HOSTNAME**
$ALERTS"
    STATUS="alert"
else
    MESSAGE="✅ **SMART STATUS – $HOSTNAME**
All disks are in good health.
$(date)"
    STATUS="ok"
fi

# Send to n8n
JSON=$(jq -n \
    --arg content "$MESSAGE" \
    --arg source "disk_health_check" \
    --arg status "$STATUS" \
    --arg logs "$(echo -e "$LOGS")" \
    '{content: $content, source: $source, status: $status, logs: $logs}')

curl -s -o /dev/null \
     -H "Content-Type: application/json" \
     -X POST \
     -d "$JSON" \
     "$WEBHOOK_URL"

echo "===== Script SMART END : $(date '+%Y-%m-%d %H:%M:%S') ====="
