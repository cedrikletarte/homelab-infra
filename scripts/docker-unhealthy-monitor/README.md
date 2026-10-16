# docker_unhealthy_monitor.sh — Unhealthy container monitor & auto-restart

Replaces the (SSH-based) n8n workflow "docker unhealthy monitoring". Meant to run frequently via cron and stays silent when everything is fine.

1. Inspects every container `docker ps` lists: running, restarting and paused ones. A stopped container is not seen, and was stopped on purpose, since every service runs with a restart policy
2. Flags a container when:
   - its status reports `unhealthy`
   - its state is `restarting` (loop: reported but not auto-restarted)
   - its state is anything else but `running` (for example `paused`)
3. Skips a flagged container already reported less than `COOLDOWN_MINUTES` ago, so a container that stays broken is reported once an hour instead of every 5 minutes. A container that recovers is forgotten, and reported again as soon as it fails again
4. If nothing new is flagged, exits silently (no notification, no webhook call)
5. Otherwise, sends an alert via n8n, then runs `docker restart` on every flagged container that compose started from a stack of this clone (`infrastructure/<stack>` or `stacks/<stack>`, `_` directories excluded), and sends a second notification with the restart results

## Prerequisites

- `docker` (with the `compose` plugin), `jq`, `curl`

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `IGNORE_CONTAINERS` | Space-separated container names to skip — gluetun containers, handled by [`gluetun-watchdog`](../gluetun-watchdog/README.md) |
| `COOLDOWN_MINUTES` | Optional, default `60`: delay before a container still failing is reported and restarted again |
| `STATE_DIR` | Optional, default `/var/tmp/docker-unhealthy-monitor`: one timestamp per reported container |

`.env` is gitignored — only `.env.exemple` is committed.

## Running the script

Scheduled by the Ansible `maintenance` role (every 5 minutes, as root, in `/etc/cron.d/homelab-infra`). Its output goes to the journal:

```bash
journalctl -t docker_unhealthy_monitor --since today
```

## Notification behavior

- No alerts → script exits with no webhook call
- Alerts found → alert notification listing affected containers, plus which ones will be auto-restarted
- After restart attempts → a second notification (`status: "repaired"` or `"error"`) confirming which containers were restarted successfully vs. failed

## Limitations

- Containers in a `restarting` loop are reported but **not** auto-restarted (restarting them wouldn't help — the loop needs manual investigation)
- Only containers started by compose from a stack of this clone are auto-restarted; the others (the containers Nextcloud AIO creates itself, the portfolio deployed by CI) are reported only
- Stopped (`exited`/`created`) containers are not seen (`docker ps` without `-a`)
- gluetun must be in `IGNORE_CONTAINERS`: restarting it doesn't fix a dead VPN config and leaves the containers sharing its network offline
