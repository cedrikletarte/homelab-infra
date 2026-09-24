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
| [`scripts/docker-pull-and-run`](scripts/docker-pull-and-run/README.md) | Pull latest images for every stack and restart the ones that changed |
| [`scripts/docker-unhealthy-monitor`](scripts/docker-unhealthy-monitor/README.md) | Detect unhealthy/stopped containers and auto-restart them |
| [`scripts/disk-health-check`](scripts/disk-health-check/README.md) | SMART health check on all physical disks |
| [`scripts/gluetun-watchdog`](scripts/gluetun-watchdog/README.md) | Regenerate a dead PIA WireGuard config and recreate gluetun + its dependents |
| [`scripts/pia-wireguard`](scripts/pia-wireguard/README.md) | Browse PIA regions/servers and generate WireGuard configs for gluetun |

All scripts report status via an n8n webhook: every message is logged to PostgreSQL (`homelab_alerts`), and only non-`ok` statuses (`alert`, `error`, `repaired`, …) are sent to Discord.

---

## Usage

```bash
# Start a stack
docker compose -f stacks/<stack-name>/docker-compose.yml up -d

# Stop a stack
docker compose -f stacks/<stack-name>/docker-compose.yml down
```

Each stack has a `.env.example` or `.env` file that lists the required environment variables.
