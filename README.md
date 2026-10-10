# Homelab Infrastructure

Personal Docker-based homelab managed with `docker compose`, using Traefik as a reverse proxy and CrowdSec for security.

---

## Stacks

| Stack | Services |
|---|---|
| `infrastructure/network` | Cloudflare DDNS, Cloudflared, CrowdSec, Traefik, WireGuard |
| `stacks/management` | Homarr, n8n, Portainer, Vaultwarden |
| `stacks/database` | PostgreSQL |
| `stacks/multimedia` | FlareSolverr, Gluetun, Lidarr, Plex, Prowlarr, qBittorrent, Radarr, Recyclarr, Seerr, Sonarr, vo-approval |
| `stacks/immich` | Immich |
| `stacks/gitlab` | GitLab EE, GitLab Runner |
| `stacks/searxng` | Gluetun, SearXNG, Valkey |

---

## Structure

```
.
├── stacks/           # Active application stacks
├── stacks-unused/    # Disabled stacks
├── infrastructure/   # Core network infrastructure
│   └── network/      # Traefik, CrowdSec, Cloudflare
├── dockerfiles/      # Custom Docker images
├── deployments/      # CI/CD deployment configs
└── scripts/          # Maintenance & monitoring scripts
```

---

## Scripts

Maintenance and monitoring scripts, each with its own README (setup, config, cron usage):

| Script | Purpose |
|---|---|
| [`scripts/docker-backup`](scripts/docker-backup/README.md) | Encrypted backup of the homelab (config + Docker volumes) to OneDrive |
| [`scripts/docker-pull-and-run`](scripts/docker-pull-and-run/README.md) | Nightly deploy: fast-forward the clone to `main`, then `docker compose up -d` every running stack |
| [`scripts/docker-unhealthy-monitor`](scripts/docker-unhealthy-monitor/README.md) | Detect unhealthy/stopped containers and auto-restart them |
| [`scripts/disk-health-check`](scripts/disk-health-check/README.md) | SMART health check on all physical disks |
| [`scripts/gluetun-watchdog`](scripts/gluetun-watchdog/README.md) | Regenerate a dead PIA WireGuard config and recreate gluetun + its dependents |
| [`scripts/pia-wireguard`](scripts/pia-wireguard/README.md) | Browse PIA regions/servers and generate WireGuard configs for gluetun |

All scripts report status via an n8n webhook: every message is logged to PostgreSQL (`homelab_alerts`), and only non-`ok` statuses (`alert`, `error`, `repaired`, …) are sent to Discord.

---

## Updates and CI

Every image is pinned to an exact version in its `docker-compose.yml` (`traefik:v3.6.25`, not `traefik:v3.6` or `latest`), so the repo always says what runs. [Renovate](https://docs.renovatebot.com/) looks for newer versions and opens one merge request per update, with the release notes. Its rules are in `renovate.json`:

- **Merged automatically** once the pipeline passes: patch releases and digest refreshes, except for Postgres, Valkey, GitLab, Immich, Vaultwarden, Traefik, CrowdSec, cloudflared, WireGuard and Gluetun, which always wait for a manual merge
- **Grouped**: Immich server and machine learning (same version required), GitLab and its runner, the media apps of `stacks/multimedia`
- **Never proposed**: Nextcloud AIO (updates itself), `portfolio-app` (built by CI), Immich's database and Redis (chosen by Immich's releases), Postgres and Valkey major versions (need a data migration)
- **Gluetun** publishes no versioned tag matching the development build in use, so it is pinned as `latest@sha256:…` and each new build comes as a digest update
- **SearXNG** releases almost daily, so its merge request is opened on Saturdays only

A merged update is deployed by `docker_pull_and_run.sh`: it fast-forwards the server's clone to `main` and runs `docker compose up -d` in every running stack, behind the backup check. The `deploy` job starts it over SSH as soon as a push to `main` (a merged merge request) passed the checks, and the nightly cron run catches anything a failed deploy left behind. The clone is also the working copy: with local commits not pushed, the script does not merge and reports it instead, so push your commits.

The pipeline (`.gitlab-ci.yml`) runs on every merge request and every push to `main`:

| Job | Checks |
|---|---|
| `compose-config` | `docker compose config` on every stack, against its `.env.exemple` |
| `shellcheck` | Every shell script, at `warning` severity |
| `gitleaks` | The whole git history for secrets |
| `renovate-config` | `renovate.json`, only when it changes |
| `deploy` | Nothing: starts the deploy on the server, only on a push to `main` and once the jobs above passed |

The `renovate` job runs only from a pipeline schedule.

### One-time setup in GitLab

1. In *Settings > Access tokens*, create a project access token named `renovate-bot`, role **Maintainer** (a Developer cannot merge into the protected `main`, which automerge needs), scopes `api` and `write_repository`. GitLab creates the matching bot user itself
2. Create a GitHub personal access token (fine-grained, public repositories read-only, no permission needed): Renovate uses it to read release notes without hitting GitHub's anonymous rate limit
3. In *Settings > CI/CD > Variables*, add `RENOVATE_TOKEN` (the bot token) and `GITHUB_COM_TOKEN`, both **Masked** and **Protected**
4. In *Build > Pipeline schedules*, add a schedule on `main`, for example `0 1 * * *` (01:00, before `docker_pull_and_run.sh`)
5. Check that the runner picks untagged jobs (*Settings > CI/CD > Runners*, edit the runner, *Run untagged jobs*)
6. Optional, for automerge: *Settings > Merge requests*, enable *Pipelines must succeed*

### One-time setup of the deploy on merge

The `deploy` job only runs once `DEPLOY_SSH_KEY` and `DEPLOY_TARGET` exist. Its key can run nothing but the deploy script, as root, detached from the SSH session. Below, `<clone>` is the absolute path of this repo on the server and `<user>` the account that owns it.

1. On the server, as `<user>`: `ssh-keygen -t ed25519 -N '' -C gitlab-deploy -f ~/.ssh/homelab_deploy`
2. Append to `~/.ssh/authorized_keys`, followed by the content of `~/.ssh/homelab_deploy.pub`:
   ```
   restrict,command="sudo -n /usr/bin/systemd-run --unit=homelab-deploy --collect /usr/bin/bash <clone>/scripts/docker-pull-and-run/docker_pull_and_run.sh"
   ```
3. `sudo visudo -f /etc/sudoers.d/homelab-deploy`, with the same command, character for character:
   ```
   <user> ALL=(root) NOPASSWD: /usr/bin/systemd-run --unit=homelab-deploy --collect /usr/bin/bash <clone>/scripts/docker-pull-and-run/docker_pull_and_run.sh
   ```
4. Test from the server: `ssh -i ~/.ssh/homelab_deploy <user>@<server LAN address>` starts a deploy, `journalctl -u homelab-deploy -f` follows it
5. In *Settings > CI/CD > Variables*, all **Protected**:
   - `DEPLOY_SSH_KEY`, type **File**: the content of `~/.ssh/homelab_deploy` (the private key)
   - `DEPLOY_KNOWN_HOSTS`, type **File**: the output of `ssh-keyscan -t ed25519 <server LAN address>`
   - `DEPLOY_TARGET`, type Variable: `<user>@<server LAN address>`

A second deploy started while one runs is refused by `systemd-run` (the unit exists), so deploys never overlap. Anyone who can push or merge to `main` can run code as root on the server through this job (the script itself is in the repo), as the nightly cron already allowed: keep `main` protected.

---

## Usage

```bash
# Start a stack
docker compose -f stacks/<stack-name>/docker-compose.yml up -d

# Stop a stack
docker compose -f stacks/<stack-name>/docker-compose.yml down
```

Each stack has a `.env.example` or `.env` file that lists the required environment variables.
