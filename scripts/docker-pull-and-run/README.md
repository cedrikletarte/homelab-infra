# docker_pull_and_run.sh — Auto-update Docker images

Scans every stack under `homelab-infra/stacks`, pulls the latest images, and restarts any stack whose images changed:

1. Iterates over each subdirectory of `stacks/` containing a `docker-compose.yml` (directories starting with `_` are skipped — archived stacks)
2. Runs `docker compose pull` for each stack
3. If the pull reports a newer image, runs `docker compose up -d` to restart the stack with the new image
4. Prunes dangling images older than 168h (`docker image prune -f --filter "until=168h"`) if any stack was updated
5. Reports the result via an n8n webhook (Discord + PostgreSQL log)

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

`.env` is gitignored — only `.env.exemple` is committed.

## Running the script

```bash
sudo bash docker_pull_and_run.sh
```

## Notification behavior

- `status: "ok"` — no updates found, or updates applied cleanly
- `status: "error"` — a pull or restart failed for one or more stacks (details listed per stack)
- Lists updated stacks with their image tags, and a cleanup summary if images were pruned
