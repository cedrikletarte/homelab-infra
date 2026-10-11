# monitoring — Grafana, Prometheus and exporters

Dashboards and alerts for the server, the containers, the web traffic and the reports of the maintenance scripts. Grafana is an admin tool: Private Access only (ADR 0002), on `http://<LAN_IP>:3000`.

| Service | Role |
|---|---|
| `grafana` | Dashboards and alert rules. Its own settings stay in SQLite in the `grafana-data` volume, so that the alerts keep working when the Shared Database is down |
| `prometheus` | Scrapes the sources below every 30 s, keeps 30 days (5 GB at most) |
| `node-exporter` | Host CPU, memory, disks and network. Host network, listening on the monitoring network's gateway only |
| `cadvisor` | CPU, memory and network per container |
| `smartctl-exporter` | SMART health and temperature of the disks, every 5 minutes, without waking a disk in standby |

Prometheus also reads Traefik (`metrics` section of `traefik.yml`, on its internal API entry point) and CrowdSec (port 6060), both on the `proxy` network.

## Dashboards

Provisioned from `grafana/dashboards/<folder>/*.json`, one Grafana folder per directory. They cannot be saved from the UI: change the JSON file instead.

| Folder | Dashboard | Source |
|---|---|---|
| Homelab | Homelab overview | `homelab_alerts`: last backup and deploy, problems per day and per source, deploy runs, CrowdSec alerts, merge requests, pipelines, latest reports |
| Server | Node Exporter Full | grafana.com 1860 |
| Server | Cadvisor exporter | grafana.com 14282 |
| Server | SMARTctl Exporter Dashboard | grafana.com 22604 |
| Web | Traefik Official Standalone Dashboard | grafana.com 17346 |
| Web | Crowdsec Overview, Crowdsec Insight | github.com/crowdsecurity/grafana-dashboards (v5) |

The downloaded dashboards were edited only to point at the provisioned Prometheus data source (uid `prometheus`) instead of asking for one at import.

`homelab_alerts` (database `homelab` of the Shared Database) is read with `grafana_reader`, an account that can only `SELECT` that table.

## Alerts

`grafana/provisioning/alerting/alerting.yml`, sent to the Discord channel of the n8n notifications:

| Alert | Fires when |
|---|---|
| No successful backup for 8 days | The last `docker_backup` report with status `ok` is more than 8 days old (or there is none) |
| Disk almost full | An ext4 filesystem is more than 85% full for 30 minutes |
| Memory almost exhausted | Less than 10% of the memory is available for 15 minutes |
| Disk SMART health check failed | A disk reports a failed SMART health check |
| Disk too hot | A disk is above 55 °C for 15 minutes |
| Metrics source down | Prometheus cannot scrape one of its sources for 10 minutes |

## Setup

```bash
cp .env.exemple .env          # fill in the passwords and the Discord webhook
docker volume create grafana-data
docker volume create prometheus-data
```

In the Shared Database, as its superuser, the read-only account of the `homelab_alerts` data source:

```sql
CREATE ROLE grafana_reader LOGIN PASSWORD '<HOMELAB_ALERTS_READER_PASSWORD>';
GRANT CONNECT ON DATABASE homelab TO grafana_reader;
-- then, connected to the homelab database:
GRANT USAGE ON SCHEMA public TO grafana_reader;
GRANT SELECT ON public.homelab_alerts TO grafana_reader;
```

The ufw rule that lets Prometheus reach node-exporter is in the Ansible `security` role (`--tags firewall`). Start the stack once with `docker compose up -d`: the deploy script only applies stacks that already have running containers.

The `monitoring` network has a pinned subnet (`172.31.0.0/24`): node-exporter listens on its gateway, Prometheus scrapes that address and the ufw rule allows that subnet (ADR 0007).
