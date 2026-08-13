# docker_unhealty_monitor.sh — Unhealthy container monitor & auto-restart

Replaces the (SSH-based) n8n workflow "docker unhealthy monitoring". Meant to run frequently via cron and stays silent when everything is fine.

1. Builds a map of container name → compose stack directory by scanning `homelab-infra/stacks` (directories starting with `_` are skipped — archived stacks)
2. Inspects every running/stopped container on the host (`docker ps`)
3. Flags a container when:
   - ❌ its state isn't `running`
   - ⚠️ its status reports `unhealthy`
   - 🔄 its status reports `restarting` (loop — reported but not auto-restarted)
4. If nothing is flagged, exits silently (no notification, no webhook call)
5. If something is flagged, sends an alert via n8n, then attempts `docker compose restart <container>` for every container that has a known stack directory, and sends a second notification with the restart results

## Prerequisites

- `docker` (with the `compose` plugin), `jq`, `curl`

## Configuration (variables at the top of the script)

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `HOMELAB_STACKS` | Root folder containing the stack subdirectories (`homelab-infra/stacks`) |

## Running the script

Intended to run on a schedule via cron, e.g. every 5 minutes:

```cron
*/5 * * * * /home/cedrik/homelab-infra/scripts/docker-unhealty-monitor/docker_unhealty_monitor.sh
```

## Notification behavior

- No alerts → script exits with no webhook call
- Alerts found → 🚨 alert notification listing affected containers, plus which ones will be auto-restarted
- After restart attempts → a second notification (`status: "ok"` or `"error"`) confirming which containers were restarted successfully vs. failed

## Limitations

- Containers in a `restarting` loop are reported but **not** auto-restarted (restarting them wouldn't help — the loop needs manual investigation)
- Only containers whose compose stack was found under `HOMELAB_STACKS` can be auto-restarted; others are reported only
