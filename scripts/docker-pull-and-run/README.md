# docker_pull_and_run.sh — Auto-update Docker images

Scans every stack under `homelab-infra/stacks`, pulls the latest images, and restarts any stack whose images changed:

1. Checks that `docker_backup.sh` succeeded within the last `BACKUP_MAX_AGE_HOURS` (180 by default); otherwise no image is pulled and the run is reported as an error. `--force` bypasses the check
2. Iterates over each subdirectory of `stacks/` containing a `docker-compose.yml` (directories starting with `_` are skipped — archived stacks, and so are the stacks listed in `SKIP_STACKS`, `nextcloud` by default)
3. Records the current digest of each image, then runs `docker compose pull`
4. If the pull reports a newer image, runs `docker compose up -d` to restart the stack with the new image
5. Prunes dangling images older than 168h (`docker image prune -f --filter "until=168h"`) if any stack was updated
6. Reports the result via an n8n webhook (Discord + PostgreSQL log)

## Prerequisites

- `docker` (with the `compose` plugin), `jq`, `curl`

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `BASE_DIR` | Root folder containing the stack subdirectories (`homelab-infra/stacks`) |
| `BACKUP_MAX_AGE_HOURS` | Optional, default `180`. Maximum age of the last successful backup for updates to run |
| `BACKUP_MARKER` | Optional, default `/var/lib/docker-backup/last_success`. File written by `docker_backup.sh` on success, must match its setting |
| `SKIP_STACKS` | Optional, default `nextcloud`. Space-separated stacks never updated automatically (Nextcloud AIO updates itself from its own interface) |

Set `BACKUP_MAX_AGE_HOURS` to a bit more than the interval between two backups. The default (`180` = 7.5 days) fits a weekly backup (Sunday 03:00) with a daily update (02:00): on Sunday at 02:00 the previous backup is 167 h old, still accepted. With a daily backup, use `30`.

The guarantee is that a backup no older than a week exists, not that one was taken right before the update: rolling back data (not just the image) can lose up to a week of changes.

`.env` is gitignored — only `.env.exemple` is committed.

## Running the script

```bash
sudo bash docker_pull_and_run.sh
```

## Notification behavior

- `status: "ok"` — no updates found, or updates applied cleanly
- `status: "error"` — a pull or restart failed for one or more stacks (details listed per stack)
- Lists updated stacks with only the images that actually changed, each with its previous digest (`↩ rollback`), and a cleanup summary if images were pruned
- `status: "error"` also covers updates skipped because there was no recent successful backup

## Rolling back an image

Take the digest from the notification and pin it in the stack's `docker-compose.yml`:

```yaml
image: vaultwarden/server@sha256:<digest from the notification>
```

then `docker compose up -d`. The previous image also stays on disk for 7 days (see the prune above). Put the normal tag back once the problem is fixed.
