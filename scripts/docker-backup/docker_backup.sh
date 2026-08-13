#!/bin/bash
# =============================================================================
# docker_backup.sh — Backup homelab to OneDrive
# - Stop active containers (recursive scan of homelab-infra/)
# - Compress Docker volumes
# - Copy homelab-infra + archive to OneDrive
# - Restart containers
# - Notify via n8n webhook (Discord + PostgreSQL log)
# =============================================================================

echo "===== Script docker backup START : $(date '+%Y-%m-%d %H:%M:%S') ====="

# ─── Config ──────────────────────────────────────────────────────────────────
WEBHOOK_URL="http://localhost:5678/webhook/homelab-alerts"
HOSTNAME=$(hostname)
HOMELAB_DIR="/home/cedrik/homelab-infra"
BACKUP_TMP="/mnt/sdb1/backup/tmp"
DATE_FOLDER=$(date '+%Y-%m-%d')                        # day folder: 2026-05-22
DATE_TAG=$(date '+%Y-%m-%d_%H-%M')                     # precise timestamp for archive
ARCHIVE_NAME="volumes_backup_${DATE_TAG}.tar.gz"
ARCHIVE_PATH="$BACKUP_TMP/$ARCHIVE_NAME"
# cryptdrive: is an rclone "crypt" remote wrapping onedrive:Server Backup Encrypted
# it encrypts content + file/folder names before upload (see setup in rclone.conf)
ONEDRIVE_BASE="cryptdrive:"
ONEDRIVE_DEST="$ONEDRIVE_BASE/$DATE_FOLDER"            # onedrive:Server Backup/2026-05-22
DOCKER_VOLUMES_DIR="/var/lib/docker/volumes"
RCLONE_CONFIG="/home/cedrik/.config/rclone/rclone.conf"

ERRORS=""
LOGS=""
STOPPED_STACK_NAMES=()
STARTED_STACK_NAMES=()

# Directories to scan (deployments excluded — managed by GitLab CI)
COMPOSE_SCAN_DIRS=(
    "$HOMELAB_DIR/stacks"
    "$HOMELAB_DIR/infrastructure"
)

# ─── Prepare temporary directory ─────────────────────────────────────────────
mkdir -p "$BACKUP_TMP"

# ─── Function: send notification to n8n ──────────────────────────────────────
send_notification() {
    local msg="$1"
    local status="$2"
    local logs="$3"
    local json
    json=$(jq -n \
        --arg content "$(echo -e "$msg")" \
        --arg source "docker_backup" \
        --arg status "$status" \
        --arg logs "$(echo -e "$logs")" \
        '{content: $content, source: $source, status: $status, logs: $logs}')
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$json" \
        "$WEBHOOK_URL")
    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: n8n webhook HTTP $http_code"
    fi
}

# ─── Function: relative path from HOMELAB_DIR ────────────────────────────────
rel_name() {
    echo "${1#$HOMELAB_DIR/}"
}

# ─── Function: scan and run action on all docker-compose.yml files ────────────
# Usage: run_compose_action <action> <label>
#   action = "down" or "up -d"
run_compose_action() {
    local action="$1"
    local label="$2"

    while IFS= read -r COMPOSE_FILE; do
        local dir
        dir=$(dirname "$COMPOSE_FILE")
        local stack
        stack=$(rel_name "$dir")
        local basename
        basename=$(basename "$dir")

        # Skip archived directories (starting with _)
        if [[ "$basename" == _* ]]; then
            echo "    Skipping archived: $stack"
            continue
        fi

        cd "$dir" || continue

        if [[ "$action" == "down" ]]; then
            RUNNING=$(docker compose ps --status running -q 2>/dev/null)
            [[ -z "$RUNNING" ]] && echo "    $stack already stopped, skipping" && continue
        fi

        echo "    ${label} $stack..."
        OUTPUT=$(docker compose $action 2>&1)
        EXIT=$?
        LOGS+="=== docker compose $action : $stack ===\n$OUTPUT\n\n"
        if [[ $EXIT -ne 0 ]]; then
            ERRORS+="• **$stack** — docker compose $action failed\n"
            echo "    ERROR: $stack"
            echo "    $OUTPUT"
        else
            [[ "$action" == "down" ]] && STOPPED_STACK_NAMES+=("$stack")
            [[ "$action" == "up -d" ]] && STARTED_STACK_NAMES+=("$stack")
            echo "    ✓ $stack"
        fi
    done < <(find "${COMPOSE_SCAN_DIRS[@]}" -name "docker-compose.yml" 2>/dev/null | sort)
}

# ─── Step 1: Stop all active stacks ──────────────────────────────────────────
echo ""
echo ">>> Step 1/5 — Stopping containers..."
run_compose_action "down" "Stopping"
echo "  Stacks stopped: ${#STOPPED_STACK_NAMES[@]}"

# ─── Step 2: Compress Docker volumes ─────────────────────────────────────────
echo ""
echo ">>> Step 2/5 — Compressing Docker volumes..."

if [[ ! -d "$DOCKER_VOLUMES_DIR" ]]; then
    ERRORS+="• **volumes** — directory $DOCKER_VOLUMES_DIR not found\n"
    LOGS+="=== tar ===\nERROR: $DOCKER_VOLUMES_DIR not found\n\n"
    echo "ERROR: $DOCKER_VOLUMES_DIR not found"
else
    echo "  Compressing $DOCKER_VOLUMES_DIR → $ARCHIVE_PATH"
    TAR_OUTPUT=$(tar -czf "$ARCHIVE_PATH" \
        -C "$(dirname "$DOCKER_VOLUMES_DIR")" \
        "$(basename "$DOCKER_VOLUMES_DIR")" 2>&1)
    TAR_EXIT=$?
    LOGS+="=== tar ===\n$TAR_OUTPUT\n\n"
    if [[ $TAR_EXIT -ne 0 ]]; then
        ERRORS+="• **volumes** — compression failed: \`$TAR_OUTPUT\`\n"
        echo "ERROR: tar failed — $TAR_OUTPUT"
    else
        ARCHIVE_SIZE=$(du -sh "$ARCHIVE_PATH" 2>/dev/null | cut -f1)
        echo "  ✓ Archive created: $ARCHIVE_NAME ($ARCHIVE_SIZE)"
    fi
fi

# ─── Step 3: Restart all stacks ──────────────────────────────────────────────
echo ""
echo ">>> Step 3/5 — Restarting containers..."
run_compose_action "up -d" "Starting"
echo "  Stacks restarted: ${#STARTED_STACK_NAMES[@]}"

# ─── Step 4: Upload to OneDrive via rclone ───────────────────────────────────
echo ""
echo ">>> Step 4/5 — Uploading to OneDrive..."

RCLONE_ERRORS=""

# 4a. Copy full homelab-infra directory
echo "  Copying homelab-infra → $ONEDRIVE_DEST/homelab-infra"
RCLONE_OUT=$(rclone --config "$RCLONE_CONFIG" copy "$HOMELAB_DIR" "$ONEDRIVE_DEST/homelab-infra" \
    --progress \
    --log-level INFO \
    2>&1)
RCLONE_EXIT=$?
LOGS+="=== rclone homelab-infra ===\n$RCLONE_OUT\n\n"
if [[ $RCLONE_EXIT -ne 0 ]]; then
    RCLONE_ERRORS+="• **homelab-infra** — rclone copy failed (exit $RCLONE_EXIT)\n"
    echo "  ERROR: rclone copy homelab-infra failed"
else
    echo "  ✓ homelab-infra uploaded"
fi

# 4b. Copy volumes archive
if [[ -f "$ARCHIVE_PATH" ]]; then
    echo "  Copying $ARCHIVE_NAME → $ONEDRIVE_DEST/"
    RCLONE_OUT=$(rclone --config "$RCLONE_CONFIG" copy "$ARCHIVE_PATH" "$ONEDRIVE_DEST" \
        --progress \
        --log-level INFO \
        2>&1)
    RCLONE_EXIT=$?
    LOGS+="=== rclone archive ===\n$RCLONE_OUT\n\n"
    if [[ $RCLONE_EXIT -ne 0 ]]; then
        RCLONE_ERRORS+="• **$ARCHIVE_NAME** — rclone copy failed (exit $RCLONE_EXIT)\n"
        echo "  ERROR: rclone copy archive failed"
    else
        echo "  ✓ Volumes archive uploaded"
    fi
else
    RCLONE_ERRORS+="• **archive** — file not found, upload skipped\n"
    LOGS+="=== rclone archive ===\nWARNING: archive not found, skipping upload\n\n"
    echo "  WARNING: archive not found, skipping upload"
fi

ERRORS+="$RCLONE_ERRORS"

# 4c. Clean up local temporary archive
echo "  Cleaning up local archive..."
rm -f "$ARCHIVE_PATH"
echo "  ✓ Local archive deleted"

# ─── Step 5: Rotate old backups on OneDrive (keep last 7) ────────────────────
echo ""
echo ">>> Step 5/5 — Rotating old backups on OneDrive..."

REMOTE_DIRS=$(rclone --config "$RCLONE_CONFIG" lsf "$ONEDRIVE_BASE" --dirs-only 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}/$' \
    | sort)
DIR_COUNT=$(echo "$REMOTE_DIRS" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}/$' 2>/dev/null)
DIR_COUNT=${DIR_COUNT:-0}
KEEP=7

echo "  Backup folders found: $DIR_COUNT (limit: $KEEP)"
LOGS+="=== rotation ===\nBackup folders: $DIR_COUNT / limit: $KEEP\n"

if [[ $DIR_COUNT -gt $KEEP ]]; then
    DELETE_COUNT=$((DIR_COUNT - KEEP))
    TO_DELETE=$(echo "$REMOTE_DIRS" | head -n "$DELETE_COUNT")
    echo "  Deleting $DELETE_COUNT old folder(s)..."
    while IFS= read -r dname; do
        dname="${dname%/}"  # remove trailing slash
        if [[ -n "$dname" ]]; then
            rclone --config "$RCLONE_CONFIG" purge "$ONEDRIVE_BASE/$dname" 2>/dev/null
            LOGS+="Deleted: $dname/\n"
            echo "  ✓ Deleted: $dname/"
        fi
    done <<< "$TO_DELETE"
else
    echo "  No rotation needed"
    LOGS+="No rotation needed\n"
fi

# ─── Build notification message ───────────────────────────────────────────────
STOPPED_LIST=""
for s in "${STOPPED_STACK_NAMES[@]}"; do STOPPED_LIST+="  ↳ \`$s\`\n"; done
STARTED_LIST=""
for s in "${STARTED_STACK_NAMES[@]}"; do STARTED_LIST+="  ↳ \`$s\`\n"; done

MESSAGE="💾 **Docker Backup — $HOSTNAME**\n"
MESSAGE+="📅 \`$DATE_FOLDER\`\n\n"

if [[ -n "$ARCHIVE_SIZE" ]]; then
    MESSAGE+="📦 **Volumes archive** : \`$ARCHIVE_NAME\` ($ARCHIVE_SIZE)\n"
fi

MESSAGE+="☁️ **OneDrive (encrypted)** : \`$ONEDRIVE_DEST/\`\n"
MESSAGE+="  ↳ \`homelab-infra/\` (full config)\n"
MESSAGE+="  ↳ \`$ARCHIVE_NAME\`\n\n"

if [[ ${#STOPPED_STACK_NAMES[@]} -gt 0 ]]; then
    MESSAGE+="⏹ **Stacks stopped** (${#STOPPED_STACK_NAMES[@]}) :\n$STOPPED_LIST\n"
fi
if [[ ${#STARTED_STACK_NAMES[@]} -gt 0 ]]; then
    MESSAGE+="▶️ **Stacks restarted** (${#STARTED_STACK_NAMES[@]}) :\n$STARTED_LIST\n"
fi

if [[ -n "$ERRORS" ]]; then
    MESSAGE+="❌ **Errors — $HOSTNAME**\n$ERRORS\n"
    STATUS="error"
else
    MESSAGE+="✅ Backup completed without errors\n"
    STATUS="ok"
fi

MESSAGE+="🕐 $(date '+%Y-%m-%d %H:%M:%S')"

send_notification "$MESSAGE" "$STATUS" "$LOGS"

echo ""
echo "===== Script docker backup END : $(date '+%Y-%m-%d %H:%M:%S') ====="
