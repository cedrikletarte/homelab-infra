# docker_backup.sh — Encrypted homelab backup to OneDrive

Automated backup script for the homelab infrastructure (`homelab-infra/`):

1. Stops active Docker stacks (recursive scan of `homelab-infra/stacks` and `homelab-infra/infrastructure`)
2. Compresses each backup directory (`/var/lib/docker/volumes`, `/mnt/sdb1/immich`, `/mnt/sdb1/nextcloud`) into its own `.tar.gz`
3. Copies `homelab-infra/` + the archives to OneDrive, **encrypted**, via an `rclone crypt` remote
4. Restarts the stacks
5. Rotates OneDrive backups (keeps the last 7)
6. Reports the result via an n8n webhook (Discord + PostgreSQL log)

## Prerequisites

- `rclone`, `docker` (with the `compose` plugin), `jq`, `curl`, `tar`
- An existing OneDrive rclone remote (`onedrive:`)
- A `crypt` rclone remote (`cryptdrive:`) wrapping `onedrive:Server Backup Encrypted` — see setup below

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `HOMELAB_DIR` | Root of the homelab-infra repo |
| `BACKUP_TMP` | Local temp folder for the archive before upload |
| `ONEDRIVE_BASE` | Target rclone remote (`cryptdrive:`) |
| `DOCKER_VOLUMES_DIR` | Docker volumes folder to archive |
| `IMMICH_DIR` | Immich data folder to archive |
| `NEXTCLOUD_DIR` | Nextcloud data folder to archive |
| `RCLONE_CONFIG` | Path to the `rclone.conf` used |

`.env` is gitignored — only `.env.exemple` is committed.

The full list of directories archived (one `.tar.gz` per directory) is `BACKUP_DIRS` in `docker_backup.sh`: `$DOCKER_VOLUMES_DIR`, `$IMMICH_DIR`, `$NEXTCLOUD_DIR`. Add more by adding a variable to `.env`/`.env.exemple` and referencing it in that array.

## Encryption — how it works

The script never uploads plaintext data to OneDrive. `ONEDRIVE_BASE="cryptdrive:"` points to an rclone remote of type **`crypt`**, which wraps the existing `onedrive:` remote:

- **File content** is encrypted in chunks (NaCl secretbox / XSalsa20-Poly1305)
- **File and folder names** are encrypted too (`filename_encryption = standard`)
- The key is derived from two secrets stored (obscured, not plaintext) in `rclone.conf`: `password` + `password2` (salt)
- `crypt` doesn't store anything itself: it encrypts on the fly and delegates actual storage to `onedrive:Server Backup Encrypted`

Old plaintext backups (`onedrive:Server Backup`) and new encrypted backups (`onedrive:Server Backup Encrypted`) live in separate folders — rotation (step 5) only lists and deletes folders seen through `cryptdrive:`, so there's no risk of touching the old backups.

### Initial setup of the `crypt` remote (one-time)

```bash
rclone config
```

- `n` → new remote
- name: `cryptdrive`
- Storage: `16` (crypt)
- remote: `onedrive:Server Backup Encrypted`
- filename_encryption: `standard`
- directory_name_encryption: `true`
- password / password2: type it (`y`) or generate it (`g`) — **write both down immediately in a separate password manager**

⚠️ **Without `password` + `password2`, the backups are unrecoverable — there is no way to reset or recover them.** Keep both values off the server (password manager), and lock down `rclone.conf`:

```bash
chmod 600 /home/cedrik/.config/rclone/rclone.conf
```

## Testing the encryption

```bash
mkdir -p /tmp/crypt-test
echo "test $(date)" > /tmp/crypt-test/hello.txt

rclone copy /tmp/crypt-test cryptdrive:test-check --progress

# Raw (encrypted) view on OneDrive:
rclone lsf onedrive:"Server Backup Encrypted"/test-check   # unreadable name

# Decrypted view through crypt:
rclone lsf cryptdrive:test-check                           # hello.txt in plaintext

# Restore + integrity check:
mkdir -p /tmp/crypt-restore
rclone copy cryptdrive:test-check /tmp/crypt-restore --progress
diff /tmp/crypt-test/hello.txt /tmp/crypt-restore/hello.txt && echo OK

# Cleanup:
rclone purge cryptdrive:test-check
rm -rf /tmp/crypt-test /tmp/crypt-restore
```

## Running the script

```bash
sudo bash docker_backup.sh
```

Then check:
- The console prints all 5 steps up to `===== Script docker backup END`
- The Discord notification shows `☁️ OneDrive (encrypted)` and `✅ Backup completed without errors`
- `rclone lsf cryptdrive: --dirs-only` shows today's folder (`2026-08-13/`)

## Restoring a backup

### From the same server

```bash
rclone copy cryptdrive:2026-08-13/homelab-infra /path/to/restore --progress
```

### From another computer (Linux/macOS/Windows)

Two methods:

**A. Copy `rclone.conf`** (simplest) — copy the `[onedrive]` and `[cryptdrive]` sections from `/home/cedrik/.config/rclone/rclone.conf` to the new machine's `rclone.conf`, then:

```bash
rclone copy cryptdrive:2026-08-13/homelab-infra /path/to/restore --progress
```

**B. Reconfigure manually** (if no config file is available):
1. Reconnect the OneDrive account: `rclone config` → new remote `onedrive` → OAuth browser login
2. Recreate the `crypt` remote with **exactly** the same `remote`, `filename_encryption`, `directory_name_encryption`, and — critically — the same `password`/`password2`

### On Windows

```powershell
winget install Rclone.Rclone
rclone config file    # locates the expected rclone.conf (%APPDATA%\rclone\rclone.conf)
rclone lsd cryptdrive: # list all folders
rclone copy cryptdrive:2026-08-23 ~/Desktop/homelab --progress # decrypt and copy folder to local machine
```

## Success marker

After a backup with no error, the script writes the current timestamp to `BACKUP_MARKER` (`/var/lib/docker-backup/last_success` by default). `docker_pull_and_run.sh` reads it and refuses to update images unless a backup succeeded recently, so an update never runs without a fresh backup behind it.

## Error handling

The script keeps going as much as possible even on partial failure (e.g. a stack that fails to restart), accumulates errors in `$ERRORS`, and the final status (`ok` / `error`) is reflected in the Discord notification — always check the message after each scheduled run.
