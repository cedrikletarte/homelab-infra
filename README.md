# Homelab Infrastructure

Personal Docker-based homelab managed with `docker compose`, using Traefik as a reverse proxy and CrowdSec for security.

---

## Stacks

| Stack | Services |
|---|---|
| `infrastructure/network` | Traefik, CrowdSec, Cloudflare DDNS, Cloudflared, WireGuard |
| `stacks/management` | Portainer, Homarr, n8n, Nginx Proxy Manager, Vaultwarden |
| `stacks/database` | PostgreSQL, Redis |
| `stacks/multimedia` | Plex, Sonarr, Radarr, Lidarr, Prowlarr, qBittorrent, Gluetun, FlareSolverr, Seerr |
| `stacks/immich` | Immich |
| `stacks/gitlab` | GitLab EE, GitLab Runner |

---

## Structure

```
.
├── stacks/           # Active application stacks
├── stacks-unused/    # Disabled stacks
├── infrastructure/   # Core network infrastructure
│   └── network/      # Traefik, CrowdSec, Cloudflare
├── dockerfiles/      # Custom Docker images
└── deployments/      # CI/CD deployment configs
```

---

## Usage

```bash
# Start a stack
docker compose -f stacks/<stack-name>/docker-compose.yml up -d

# Stop a stack
docker compose -f stacks/<stack-name>/docker-compose.yml down
```

Each stack has a `.env.example` or `.env` file that lists the required environment variables.
