# Homelab Infrastructure

Personal Docker-based homelab managed with `docker compose`, using Traefik as a reverse proxy and CrowdSec for security.

---

## Stacks

| Stack | Services |
|---|---|
| `infrastructure/network` | Cloudflare DDNS, Cloudflared, CrowdSec, Traefik, WireGuard |
| `stacks/management` | Homarr, n8n, Portainer, Vaultwarden |
| `stacks/database` | PostgreSQL |
| `stacks/multimedia` | FlareSolverr, Gluetun, Lidarr, Plex, Prowlarr, qBittorrent, Radarr, Seerr, Sonarr |
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

A merged update is deployed by `docker_pull_and_run.sh` at its next nightly run: it fast-forwards the server's clone to `main` and runs `docker compose up -d` in every running stack, behind the backup check. To deploy right away, run it by hand. The clone is also the working copy: with local commits not pushed, the script does not merge and reports it instead, so push before the night.

The pipeline (`.gitlab-ci.yml`) runs on every merge request and every push to `main`:

| Job | Checks |
|---|---|
| `compose-config` | `docker compose config` on every stack, against its `.env.exemple` |
| `shellcheck` | Every shell script, at `warning` severity |
| `gitleaks` | The whole git history for secrets |
| `renovate-config` | `renovate.json`, only when it changes |

The `renovate` job runs only from a pipeline schedule.

### One-time setup in GitLab

1. In *Settings > Access tokens*, create a project access token named `renovate-bot`, role **Maintainer** (a Developer cannot merge into the protected `main`, which automerge needs), scopes `api` and `write_repository`. GitLab creates the matching bot user itself
2. Create a GitHub personal access token (fine-grained, public repositories read-only, no permission needed): Renovate uses it to read release notes without hitting GitHub's anonymous rate limit
3. In *Settings > CI/CD > Variables*, add `RENOVATE_TOKEN` (the bot token) and `GITHUB_COM_TOKEN`, both **Masked** and **Protected**
4. In *Build > Pipeline schedules*, add a schedule on `main`, for example `0 1 * * *` (01:00, before `docker_pull_and_run.sh`)
5. Check that the runner picks untagged jobs (*Settings > CI/CD > Runners*, edit the runner, *Run untagged jobs*)
6. Optional, for automerge: *Settings > Merge requests*, enable *Pipelines must succeed*

---

## Usage

```bash
# Start a stack
docker compose -f stacks/<stack-name>/docker-compose.yml up -d

# Stop a stack
docker compose -f stacks/<stack-name>/docker-compose.yml down
```

Each stack has a `.env.example` or `.env` file that lists the required environment variables.
