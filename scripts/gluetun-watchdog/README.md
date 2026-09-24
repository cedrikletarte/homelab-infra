# gluetun_watchdog.sh — Dead PIA WireGuard config auto-repair

Detects a gluetun container whose PIA WireGuard config no longer works (server retired by PIA, or key dropped) and repairs it: new config, updated `SERVER_NAMES`, containers recreated. Meant to run frequently via cron and stays silent when everything is fine.

For each `container:region` pair in `GLUETUN_INSTANCES`:

1. Skips it unless it has been `unhealthy` for at least `UNHEALTHY_MINUTES` (failing streak × healthcheck interval) — gluetun already restarts its own tunnel on short outages
2. Skips it if the host itself is offline (ping 1.1.1.1 / 8.8.8.8)
3. Skips it if it was regenerated less than `COOLDOWN_MINUTES` ago — avoids registering keys in a loop when PIA refuses (expired subscription, wrong password)
4. Probes the current server to report the cause: unreachable (retired) or reachable (key dropped)
5. Runs `pia_wireguard.sh generate <region>` on the `wg0.conf` bind-mounted at `/gluetun/wireguard/wg0.conf`
6. Sets `SERVER_NAMES` in the stack's `.env` — required by gluetun's PIA port forwarding (only flagged as missing when the compose file uses it)
7. `docker compose up -d --force-recreate` on gluetun **and** every service with `network_mode: service:gluetun` (a plain restart leaves them without network)
8. Waits up to `HEALTHY_TIMEOUT` seconds for gluetun to become healthy and notifies the result

The stack directory, compose files and `wg0.conf` path are read from the container's compose labels and mounts — nothing to configure per stack.

## Prerequisites

- `docker` (with the `compose` plugin), `jq`, `curl`, `flock`
- [`pia-wireguard`](../pia-wireguard/README.md) with `PIA_USER` / `PIA_PASS` set in its `.env` (no terminal under cron)
- Run as root (reads `wg0.conf`, mode `600`)

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `GLUETUN_INSTANCES` | Space-separated `container:pia_region` pairs, e.g. `"gluetun:ca_toronto"` |
| `UNHEALTHY_MINUTES` | Minutes unhealthy before regenerating (default `15`) |
| `COOLDOWN_MINUTES` | Minimum minutes between two regenerations of a container (default `60`) |
| `HEALTHY_TIMEOUT` | Seconds to wait for gluetun to become healthy (default `180`) |
| `STATE_DIR` | Lock and last-regeneration timestamps (default `/var/tmp/gluetun-watchdog`) |
| `PIA_WIREGUARD` | Path to `pia_wireguard.sh` (default `../pia-wireguard/pia_wireguard.sh`) |

`.env` is gitignored — only `.env.exemple` is committed.

## Running the script

```bash
sudo ./gluetun_watchdog.sh              # real run
sudo DRY_RUN=1 ./gluetun_watchdog.sh    # log what it would do, change nothing
```

Intended to run on a schedule via cron, e.g. every 5 minutes:

```cron
*/5 * * * * /home/cedrik/homelab-infra/scripts/gluetun-watchdog/gluetun_watchdog.sh >> /home/cedrik/logfile.log 2>&1
```

## Notification behavior

- Healthy, not yet past the threshold, host offline or in cooldown → no webhook call (logged only)
- Regenerated and healthy again → `status: "repaired"` with the cause, new server and recreated containers
- Regeneration failed, or still unhealthy afterwards → `status: "error"`, retried after the cooldown

## Limitations

- Only handles PIA WireGuard configs in gluetun `custom` mode
- Each regeneration backs up the previous `wg0.conf` to `wg0.conf.bak-<date>`; prune them now and then
- `docker_unhealthy_monitor.sh` must ignore the gluetun containers (`IGNORE_CONTAINERS`), otherwise it restarts them without fixing the config
