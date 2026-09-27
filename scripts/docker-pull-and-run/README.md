# docker_pull_and_run.sh — Deploy what was merged on main

Images are pinned to exact versions in the compose files and bumped by Renovate merge requests (see "Updates and CI" in the root README). Deploying therefore means two things: bring the server's clone up to date with `main`, then apply the compose files. This script does both, every night:

1. Checks that `docker_backup.sh` succeeded within the last `BACKUP_MAX_AGE_HOURS` (180 by default); otherwise nothing is done and the run is reported as an error. `--force` bypasses the check
2. Fast-forwards the clone to `origin/main` (see "The clone is also a working copy" below)
3. Runs `docker compose up -d` in every stack of `infrastructure/` and `stacks/` that has a running container. Compose pulls the images that are not on disk yet (a new pinned tag) and recreates only the containers whose definition changed; the others are left alone. Stacks with nothing running were stopped on purpose and are not started; stacks in `SKIP_STACKS` (`nextcloud` by default: Nextcloud AIO updates itself) and directories starting with `_` are skipped
4. Removes the previous images of the recreated containers, once no container uses them
5. Reports the result via an n8n webhook (Discord + PostgreSQL log)

## The clone is also a working copy

The clone the script deploys (`homelab-infra/`, found from the script's own location) is the one used to edit and commit, so the script never rewrites local work:

- **Behind `origin/main` only**: fast-forward (`git merge --ff-only`), then deploy
- **Local commits not pushed while `origin/main` moved on**: no merge. The run reports it (`alert`) and deploys the clone as it is; run `git pull --rebase` and push
- **Uncommitted changes that the fast-forward would overwrite**: git refuses, the run reports it and deploys the clone as it is
- **Another branch checked out**: no merge, reported, deployed as it is

Uncommitted changes to a compose file are deployed like the rest: the script applies the files as they are on disk.

Git runs as the owner of the clone (`sudo -u`), not as root, so that root never leaves files in `.git` the owner cannot write, and the owner's SSH key (without passphrase, cron has no agent) is used for the fetch.

## Prerequisites

- `docker` (with the `compose` plugin), `git`, `jq`, `curl`, `sudo`

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `BACKUP_MAX_AGE_HOURS` | Optional, default `180`. Maximum age of the last successful backup for a deploy to run |
| `BACKUP_MARKER` | Optional, default `/var/lib/docker-backup/last_success`. File written by `docker_backup.sh` on success, must match its setting |
| `PULL_ATTEMPTS` | Optional, default `3`. A failed `docker compose up -d` (for example a registry rate limit, `toomanyrequests`) is retried up to this many times |
| `PULL_RETRY_WAIT` | Optional, default `60`. Seconds to wait between two attempts |
| `SKIP_STACKS` | Optional, default `nextcloud`. Space-separated stack directory names never applied (`network` is the one of `infrastructure/network`) |
| `GIT_REMOTE`, `GIT_BRANCH` | Optional, default `origin` and `main`. What the clone is fast-forwarded to |

Set `BACKUP_MAX_AGE_HOURS` to a bit more than the interval between two backups. The default (`180` = 7.5 days) fits a weekly backup (Sunday 03:00) with a daily deploy (02:00): on Sunday at 02:00 the previous backup is 167 h old, still accepted. With a daily backup, use `30`.

The guarantee is that a backup no older than a week exists, not that one was taken right before the deploy: rolling back data (not just the image) can lose up to a week of changes.

`.env` is gitignored — only `.env.exemple` is committed.

## Running the script

```bash
sudo bash docker_pull_and_run.sh            # what cron runs
bash docker_pull_and_run.sh --dry-run       # show what would happen: no merge, no container change, no notification
```

`--dry-run` still fetches, to tell how far behind the clone is, but checks the stacks against the clone as it is, before the merge.

## Notification behavior

- `status: "ok"` — nothing to deploy, or the deploy went through: the message lists the git range applied, the recreated containers per stack and the removed images
- `status: "alert"` — the clone could not be fast-forwarded (see above): the stacks were still applied from the clone as it is
- `status: "error"` — a fetch or a `docker compose up -d` failed, or the deploy was skipped because there was no recent successful backup

## Rolling back

Revert the commit that changed the image (`git revert <commit>` on `main`, pushed, or a revert merge request in GitLab). The next run deploys the previous version, pulling it again since the old image was removed from disk. For an immediate rollback, run the script by hand after the revert.
