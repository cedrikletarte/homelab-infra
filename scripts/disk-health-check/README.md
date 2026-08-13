# disk_health_check.sh — SMART disk health monitor

Checks the SMART status of every physical disk on the host and reports the result via an n8n webhook (Discord + PostgreSQL log).

For each disk found by `lsblk`, the script:

1. Reads the overall SMART health assessment (`smartctl -H`)
2. Reads the reallocated sector count (`smartctl -A`, `Reallocated_Sector_Ct`)
3. Reads the result of the last self-test (`smartctl -l selftest`)
4. Raises an alert if health isn't `PASSED`, if reallocated sectors > 0, or if the last test didn't complete without error

## Prerequisites

- `smartutils` (`smartctl` at `/usr/sbin/smartctl`) — SMART must be enabled on the disks (`smartctl -s on /dev/sdX`)
- `lsblk`, `jq`, `curl`
- Run as a user with permission to query disks (typically root)

## Configuration (variables at the top of the script)

| Variable | Purpose |
|---|---|
| `WEBHOOK_URL` | n8n endpoint for notifications |
| `SMARTCTL` | Path to the `smartctl` binary |

## Running the script

```bash
sudo bash disk_health_check.sh
```

Recommended as a cron job, e.g. daily:

```cron
0 6 * * * /usr/bin/sudo /home/cedrik/homelab-infra/scripts/disk-health-check/disk_health_check.sh
```

## Notification behavior

- Always sends a notification (unlike the unhealthy-container monitor, which stays silent when nothing is wrong)
- `status: "ok"` with "All disks are in good health" when every disk passes
- `status: "alert"` listing each failing disk when any check fails:
  - ❌ overall health not `PASSED`
  - ⚠️ reallocated sectors present
  - ⚠️ last self-test did not complete without error
