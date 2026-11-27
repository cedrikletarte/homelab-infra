# Research: monitoring, alerting and a status page for the new server

- **Date:** 2026-11-26
- **Ticket:** "Monitoring, alerting et page de statut"
- **Status:** Research only. Nothing here is a decision; it feeds a later ADR.

## Question

Which dedicated tools can replace the home-made maintenance scripts (detect and restart unhealthy containers, SMART health, Gluetun watchdog), and how should the new server cover:

- alerting to Discord and email without going through n8n;
- a public status page that tells family and friends about planned outages;
- ZFS, the CyberPower UPS (NUT or pwrstat, clean shutdown on battery) and the NVIDIA GPU (dcgm-exporter or nvidia_gpu_exporter);
- how heavy each option is.

Candidates: Prometheus + Alertmanager + Grafana (current), Grafana Alerting, Beszel, Netdata, Uptime Kuma, Gatus, healthchecks.io, autoheal.

Method: versions were taken from each project's GitHub "latest release" API on 2026-11-26. Claims are cited to official docs, source code, changelogs or project issues. The few claims that could not be checked against a primary source are marked **(unverified)**.

## TL;DR

- **The current stack already does more than the ticket says.** Grafana Alerting is provisioned from files and posts straight to a Discord webhook, without n8n. cAdvisor already exports a `container_health_state` metric. Detecting unhealthy containers is one more alert rule, not a new tool.
- **Restarting unhealthy containers needs a helper.** Docker restart policies only react to a container exiting, and nothing native acts on `unhealthy`. `autoheal` is the maintained option. It has no cooldown or backoff, so restart loops have to be handled some other way.
- **No generic tool replaces the Gluetun watchdog.** Gluetun already restarts the tunnel on its own when it drops. What the script fixes is a dead PIA WireGuard config, and Gluetun cannot regenerate one because it has no native PIA WireGuard support. To retire the script, the owner would have to change the VPN setup (PIA over OpenVPN, which Gluetun supports natively, or another provider), not the monitoring.
- **SMART needs only alert rules.** smartctl-exporter already exposes the self-test and error counters the script checks. But nothing runs the self-tests: that is `smartd`'s job.
- **Status page:** Gatus has config-file **announcements** made for "planned maintenance on Saturday". Uptime Kuma shows a maintenance banner only while the window is active (the request for upcoming maintenance is still open). Either one is useless if it runs on the server that is down, so where it is hosted matters more than which one is picked.
- **Hardware:** NUT is the open, multi-host choice for the UPS, with known CyberPower quirks. nvidia_gpu_exporter fits a GeForce card better than DCGM. For ZFS, node-exporter gives pool state, ZED gives event alerts, and zfs_exporter or Beszel add scrub and capacity details.
- **Biggest hidden coupling:** the backup-staleness alert and the "Homelab overview" dashboard read the `homelab_alerts` table, and n8n fills that table. Removing n8n from the notification path means replacing that journal too.

## 1. What exists today

Read from the production clone, `stacks/monitoring/` and `scripts/` (read only).

| Piece | What it does today |
|---|---|
| Prometheus v3.16.0 | Scrapes node-exporter, cAdvisor, smartctl-exporter, Traefik and CrowdSec every 30 s. Keeps 30 days, 5 GB at most |
| Grafana OSS 13.0.2 | Dashboards, plus **file-provisioned alerting** (`grafana/provisioning/alerting/alerting.yml`): a `discord` contact point fed by `DISCORD_WEBHOOK_URL`, and six rules (backup stale, disk > 85 %, memory < 10 %, SMART failed, disk > 55 °C, scrape target down). Its own state is kept in SQLite on purpose, so alerts still work when Postgres is down |
| cAdvisor v0.61.1 | Per-container CPU, memory and network, tuned down |
| smartctl-exporter v0.15.0 | SMART every 300 s, with `--smartctl.powermode-check=standby` |
| `docker_unhealthy_monitor.sh` | Cron every 5 min. Flags unhealthy, restarting or paused containers, notifies, then `docker restart`s only the ones compose started from a stack of this clone. 60 min cooldown. Skips gluetun |
| `gluetun_watchdog.sh` | Cron every 5 min. When gluetun has been unhealthy for 15 min and the host is online, regenerates the PIA WireGuard config, updates `SERVER_NAMES`, force-recreates gluetun and every `network_mode: service:gluetun` service, then checks health |
| `disk_health_check.sh` | Daily. `smartctl -H`, `Reallocated_Sector_Ct`, last self-test result. **Always** notifies, even when everything is OK |
| `lib/notify.sh` | POSTs to an n8n webhook. n8n journals **every** message in `homelab_alerts` (Postgres) and posts only the non-OK ones to Discord |

So the ticket's "Prometheus + Grafana (without alerting)" is out of date. Alerting exists and already skips n8n. The scripts are what still use n8n.

## 2. Replacing each script

### 2.1 Unhealthy containers: detection and restart

**Docker does not do it natively.** In the Compose spec, `restart` is "the policy that the platform applies on container termination" ([compose-spec 05-services.md, `restart`](https://github.com/compose-spec/compose-spec/blob/main/05-services.md#restart)). The upstream proposal for `--exit-on-unhealthy` ([moby/moby#22719](https://github.com/moby/moby/pull/22719)) never landed, and autoheal's README still calls itself "a stand-in till there is native support" ([docker-autoheal README](https://github.com/willfarrell/docker-autoheal)).

**Detection options:**

| Tool | How | Notes |
|---|---|---|
| cAdvisor (already running) | `container_health_state` gauge: `1` healthy, `-1` no healthcheck, `0` "starting or unhealthy" ([cAdvisor `lib/metrics/prometheus.go`, `getContainerHealthState`](https://github.com/google/cadvisor/blob/master/lib/metrics/prometheus.go)). Present in tag v0.61.1, which the stack runs. Not behind a `--disable_metrics` group ([cAdvisor Prometheus metrics doc](https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md)) | A Grafana rule `container_health_state == 0` held for a few minutes covers it. Because `0` also means `starting`, the `for:` duration has to be longer than the slowest start period (GitLab) |
| Beszel ≥ 0.19.0 | "Container Health" alert type, added in PR #2225 and shipped in v0.19.0 (Sept 2026), with a log excerpt in the notification ([beszel#716](https://github.com/henrygd/beszel/issues/716), [PR #2225](https://github.com/henrygd/beszel/pull/2225)) | One alert per **system**, not per container |
| Netdata | Stock `docker_container_unhealthy` and `docker_container_down` alert templates ([health.d/docker.conf](https://github.com/netdata/netdata/blob/master/src/health/health.d/docker.conf)) | Works out of the box |
| Uptime Kuma | "Docker Containers" monitor type ([README](https://github.com/louislam/uptime-kuma)) | One monitor per container, created in the UI |

**Restart options:**

| Tool | Status (2026-11-26) | Behaviour | Pitfalls |
|---|---|---|---|
| `willfarrell/autoheal` | No GitHub releases. The `latest` image is "built daily" (Docker Hub `latest` updated 2026-11-26). Last commit 2025-09-09 ([repo](https://github.com/willfarrell/docker-autoheal)) | A shell loop that polls `containers/json?filters={"health":["unhealthy"]}` every `AUTOHEAL_INTERVAL` (5 s) and restarts matches. Opt in per container with the `autoheal=true` label, or watch all. Skips containers in `restarting`. Notifies through `WEBHOOK_URL` + `WEBHOOK_JSON_KEY`, or `APPRISE_URL` ([docker-entrypoint](https://github.com/willfarrell/docker-autoheal/blob/main/docker-entrypoint)) | **No cooldown or backoff**: a container that comes back unhealthy is restarted again and again, unlike the script's 60-minute cooldown. Only tag you can pin: `1.2.0` (2021) or a digest of `latest`. Needs the Docker socket with write access (POST restart) |
| `qmcgaw/deunhealth` | Last release v0.3.0 (2021-10-17) ([repo](https://github.com/qdm12/deunhealth)) | Go, listens to the Docker event stream, opt-in label `deunhealth.restart.on.unhealthy=true`, `network: none` ([README](https://github.com/qdm12/deunhealth)) | No notifications at all. Practically unmaintained |

Setting `WEBHOOK_JSON_KEY=content` should make autoheal's payload a valid Discord webhook body (`{"content": "..."}`), so it can post to Discord directly **(unverified end to end)**.

What the script does that autoheal does not: report `paused` or restart-looping containers (Prometheus or Beszel can alert on those), the cooldown, and "restart only what this clone deployed". The opt-in label takes over that last rule. A Docker restart loop, on the other hand, shows up as a rising `container_start_time_seconds` or as `restarting`, and can be alerted on.

### 2.2 SMART health

smartctl-exporter already exports what the script checks: `smartctl_device_smart_status`, `smartctl_device_attribute` (including `Reallocated_Sector_Ct`), `smartctl_device_self_test_log_error_count`, `smartctl_device_error_log_count`, and for NVMe `smartctl_device_critical_warning`, `smartctl_device_media_errors` and `smartctl_device_percentage_used` ([smartctl_exporter metrics.go](https://github.com/prometheus-community/smartctl_exporter/blob/master/metrics.go)). Today only `smart_status` and temperature have Grafana rules, so retiring the script takes three or four more rules.

The gap that remains: **nobody schedules self-tests.** The exporter reads the self-test log; it does not run tests. `smartd` from smartmontools does both: `-s REGEXP` schedules short and long tests (for example `-s S/../.././02`), and `-m` / `-M exec` mail or run a script on a problem ([smartd.conf(5)](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/smartd.conf.5.in)). Two points to watch: smartd and the exporter both talk to the disks, and the exporter's standby check exists so it does not keep the IronWolfs spinning.

Beszel (smartctl ≥ 7.0, needs `SYS_RAWIO` and, for NVMe, `SYS_ADMIN`, plus a "notification on drive failure") and Netdata (a `smartctl` go.d collector, [source](https://github.com/netdata/netdata/tree/master/src/go/plugin/go.d/collector/smartctl)) are alternatives ([Beszel S.M.A.R.T.](https://beszel.dev/guide/smart-data)).

### 2.3 Gluetun watchdog

What Gluetun does on its own: it checks the tunnel every minute (ICMP or DNS) and every 5 minutes (TCP+TLS), and with `HEALTH_RESTART_VPN=on` (the default) it **restarts the VPN inside the container**. It was built that way because "containers connected to Gluetun lose connection once Gluetun is restarted" ([gluetun-wiki faq/healthcheck.md](https://github.com/qdm12/gluetun-wiki/blob/main/faq/healthcheck.md), [setup/options/healthcheck.md](https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/healthcheck.md)). The wiki says that when the startup check keeps failing, the usual causes are expired credentials or keys and server IPs that no longer exist.

Why no generic tool replaces the script: for PIA, Gluetun natively supports **OpenVPN only**. "For now, native support [of WireGuard] cannot be added". PIA over WireGuard goes through the `custom` provider with an externally generated config ([gluetun-wiki PIA page](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md)). When PIA retires the server or drops the key, only regenerating the config fixes it, and that is exactly what the script does. autoheal restarting gluetun would not fix the config, and it would also leave the dependent containers without network.

Options for the owner:

1. **Keep the script** as the one justified piece of custom code, but report through the new path (a healthchecks.io ping, a Gatus external endpoint, or Discord directly) instead of n8n.
2. **Switch PIA to OpenVPN** (`VPN_SERVICE_PROVIDER=private internet access`). Gluetun then picks servers from its own server list, which it can update, and needs only a username and password. The script goes away. The cost is OpenVPN throughput and CPU compared with WireGuard. That is not measured here, and the 3900X has plenty of headroom.
3. **Another VPN provider** with native Gluetun WireGuard support (out of scope here, but it is the cleanest way to delete the code).

Note also that the gluetun project now redirects on GitHub: `qdm12/gluetun` resolves to `passteque/gluetun`, latest release v3.41.3, 2026-07-30 (GitHub API redirect). Renovate's package source should be checked.

## 3. Metrics and alerting platform

### 3.1 Options

| | Prometheus + Grafana (current) | + Alertmanager | Beszel | Netdata |
|---|---|---|---|---|
| Latest version | Prometheus 3.16.0 in use. Grafana 13.3.2 (2026-11-24) | 0.35.1 (2026-11-24) | 0.21.2 (2026-11-12) | 2.13.0 (2026-11-19) |
| License | Apache-2.0 / AGPL-3.0 | Apache-2.0 | MIT | Agent GPL-3.0+. **Dashboard UI under the proprietary NCUL1** ([Netdata blog, 2026-10-13](https://www.netdata.cloud/blog/important-changes-to-the-netdata-agent-dashboard/)) |
| Model | Pull, PromQL, any exporter | Routing, grouping, silences for Prometheus rules | Hub (PocketBase) + agent per host ([what is Beszel](https://beszel.dev/guide/what-is-beszel)) | One agent per host, per-second collection, built-in ML |
| Container health alert | Yes, via cAdvisor `container_health_state` (§2.1) | Same | Yes, ≥ 0.19.0, one alert per system | Yes, stock template |
| SMART | smartctl-exporter | – | Built in | go.d `smartctl` |
| ZFS | node-exporter `zfs` collector + optional zfs_exporter (§5) | – | Pools, health, scrub status, datasets ([storage pools](https://beszel.dev/guide/storage-pools)) | go.d `zfspool` with health and space alerts ([health.d/zfs.conf](https://github.com/netdata/netdata/blob/master/src/health/health.d/zfs.conf)) |
| UPS (NUT) | nut_exporter (§6) | – | No NUT collector found ("Battery charge" means host or peripheral batteries) ([README](https://github.com/henrygd/beszel)) | go.d `upsd` with battery, load and stale-data alerts ([health.d/upsd.conf](https://github.com/netdata/netdata/blob/master/src/health/health.d/upsd.conf)) |
| NVIDIA GPU | nvidia_gpu_exporter or dcgm-exporter (§7) | – | `nvidia-smi` or NVML collector, `beszel-agent-nvidia` image ([GPU](https://beszel.dev/guide/gpu)) | go.d `nvidia_smi` |
| Config as code | Yes: dashboards, data sources, contact points and rules are already provisioned from files | Yes (YAML) | Alerts and notification URLs are set in the hub UI (Settings > Notifications, systems table) ([notifications](https://beszel.dev/guide/notifications)). Agent config through environment variables | Yes for alerts (`health.d/*.conf`) and collectors |
| Discord / email | Discord already. Email needs the `[smtp]` section ([Grafana email](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/integrations/configure-email/)) | `discord_configs`, `email_configs` ([configuration.md](https://github.com/prometheus/alertmanager/blob/main/docs/configuration.md)) | Shoutrrr `discord://`; email through the PocketBase mailer ([alerts.go](https://github.com/henrygd/beszel/blob/main/internal/alerts/alerts.go)) | Agent-dispatched Discord and Email, no Cloud needed ([agent notifications](https://learn.netdata.cloud/docs/alerts-&-notifications/notifications/agent-dispatched-notifications/discord)) |

### 3.2 Grafana Alerting or Alertmanager

Grafana Alerting is already in place, provisioned and independent of Postgres. Running a separate Alertmanager would mean moving rules into Prometheus rule files. It brings mature grouping, inhibition and silences, and its Discord integration is still being worked on: 429 retry, failure reasons ([Alertmanager CHANGELOG](https://github.com/prometheus/alertmanager/blob/main/CHANGELOG.md)). For a single server the gain is small, and it adds one more component to maintain. Grafana is upgraded through Renovate anyway (13.0.2 → 13.3.2 is pending).

### 3.3 Beszel and Netdata

- **Beszel** is a simpler, all-in-one option: host, containers, container health, SMART, ZFS, GPU and alerts in one UI. On top of that, network probes from the agents ([network monitors](https://beszel.dev/guide/network-monitors)) and an outbound **heartbeat** to healthchecks.io or Uptime Kuma ([heartbeat](https://beszel.dev/guide/heartbeat)). Weak points: alerting is UI-configured rather than in Git, there is no UPS and no Traefik or CrowdSec metrics, and the history is less flexible than PromQL. It would replace the current stack, or overlap with it.
- **Netdata** covers the most hardware out of the box (NUT, ZFS, SMART, NVIDIA, Docker health), with stock alerts and agent-side Discord and email. Weak points: the dashboard is not open source (NCUL1), some views need a Netdata Cloud sign-in (logs, processes, network connections), and multi-node views are limited to 5 nodes on the free plan ([Netdata blog](https://www.netdata.cloud/blog/important-changes-to-the-netdata-agent-dashboard/)). It is also the heaviest agent (see §8).

## 4. Uptime checks, status page and dead man's switch

### 4.1 Tools

| | Uptime Kuma | Gatus | healthchecks.io | UptimeRobot (hosted, for comparison) |
|---|---|---|---|---|
| Version / license | 2.5.12 (2026-11-17), MIT. 2.0.0 was a breaking major ([2.0.0 notes](https://github.com/louislam/uptime-kuma/releases/tag/2.0.0)) | 5.38.0 (2026-10-28), Apache-2.0 | 5.0.3 (2026-10-27), BSD-3. Also hosted | SaaS |
| Kind | Active checks (HTTP, TCP, DNS, ping, Docker, push) | Active checks from YAML, plus push "external endpoints" with heartbeat ([README §External Endpoints](https://github.com/TwiN/gatus#external-endpoints)) | Passive: cron and heartbeat ("dead man's switch") | Active checks |
| Config | Web UI, state in its database (SQLite or MariaDB; SQLite → MariaDB migration is not supported, [v1→v2 wiki](https://github.com/louislam/uptime-kuma/wiki/Migration-From-v1-To-v2)) | One YAML file, **reloaded on the fly** ([README §Reloading configuration](https://github.com/TwiN/gatus#reloading-configuration-on-the-fly)). Storage memory, SQLite or Postgres | Web UI. Postgres or MySQL, SMTP **required** ([self-hosted docs](https://healthchecks.io/docs/self_hosted/)) | Web UI |
| Status page | Several status pages, custom domains | Built-in dashboard used as the status page | No public status page | 1 basic status page on the free plan ([pricing](https://uptimerobot.com/pricing/)) |
| Planned outage notice | "Maintenance": manual, single window, cron or recurring; mutes notifications and shows a banner **during** the window ([wiki](https://github.com/louislam/uptime-kuma/wiki/Maintenance)). Showing **upcoming** maintenance is an open request ([#2389](https://github.com/louislam/uptime-kuma/issues/2389), duplicate filed again 2026-07-17) | **Announcements** (`outage`, `warning`, `information`, `operational`), markdown, archived into "Past Announcements" ([README §Announcements](https://github.com/TwiN/gatus#announcements)). Separate `maintenance` windows mute alerts ([§Maintenance](https://github.com/TwiN/gatus#maintenance)) | – | Not checked |
| Discord / email | Both, plus 90+ providers | Both ([§Discord](https://github.com/TwiN/gatus#configuring-discord-alerts), [§Email](https://github.com/TwiN/gatus#configuring-email-alerts)) | Email built in. Self-hosted Discord needs your own Discord application (`DISCORD_CLIENT_ID/SECRET`) ([README](https://github.com/healthchecks/healthchecks#discord)) | Email; Discord among the 5 integrations on the free plan |
| Free hosted tier | – | – | 20 checks, 100 log entries per check ([pricing](https://healthchecks.io/pricing/)) | 50 monitors, 5-minute interval |

### 4.2 Planned outages for the family

- Gatus announcements fit the flow the owner already uses: an announcement is a few lines in the config file, committed and deployed like any change, and Gatus reloads the file without a restart. The catch: posting an announcement means a commit and a deploy. That may be good (traceable) or annoying (from a phone).
- In Uptime Kuma it is clicks in the UI. But the banner only appears once the window has started, so "Saturday 9:00–12:00" cannot be announced in advance with the maintenance feature. A pinned status-page incident or the page description is the workaround **(unverified as a UX)**.

### 4.3 Where the status page runs (the real decision)

A status page served by the main server, or through its Cloudflare Tunnel, goes down with it. That covers every unplanned outage and many planned ones (a reboot, a disk swap). The choices:

| Placement | Survives server down | Survives power or internet outage at home | Cost |
|---|---|---|---|
| On the main server | No | No | 0 |
| On the old i5-2400 | Yes | No (same power and ISP) | Power use of a second machine |
| Hosted (UptimeRobot, healthchecks.io, a small VPS running Gatus) | Yes | Yes | Free tier, or a VPS |

The old server would also be a natural "watcher of the watcher" (it alerts when the main server stops answering). It cannot see outages that hit the whole house.

### 4.4 Dead man's switch and script reporting

Every alerting path on the server dies with the server. A passive external check closes that gap:

- healthchecks.io pings: `/start`, success, `/fail`, `/<exit-status>`, `/log`, with **up to 100 kB of request body** stored per ping and `rid` to pair start and end ([HTTP API](https://healthchecks.io/docs/http_api/)). This maps directly onto what `notify.sh` sends today (status + logs) for the backup and deploy scripts.
- Beszel's `HEARTBEAT_URL` and Gatus external endpoints with `heartbeat.interval` do the same thing for their own process.
- With Grafana, an always-firing rule with a short repeat interval, sent to a webhook contact point that pings healthchecks.io, is the usual "Watchdog" pattern **(pattern not checked against a Grafana doc page)**.

**Coupling to resolve:** the `No successful backup for 8 days` rule and the "Homelab overview" dashboard read `homelab_alerts`, which n8n fills. If the scripts report to healthchecks.io instead, either that alert moves to healthchecks.io (a missed weekly ping is exactly its job), or something else has to keep writing `homelab_alerts`.

## 5. ZFS

| Source | What it gives | Notes |
|---|---|---|
| node-exporter `zfs` collector (on by default on Linux) | ARC and kstat statistics, plus `node_zfs_zpool_state{zpool,state}` read from `/proc/spl/kstat/zfs/*/state` ([zfs_linux.go](https://github.com/prometheus/node_exporter/blob/master/collector/zfs_linux.go), [README collectors table](https://github.com/prometheus/node_exporter#enabled-by-default)) | Already deployed. No scrub results and no per-vdev error counts |
| `pdf/zfs_exporter` v2.5.2 (2026-11-15) | Pool `health`, `size`, `free`, `fragmentation`, `readonly`, plus dataset and volume properties. Collection deadline with a cache so slow `zfs` calls do not time out ([README](https://github.com/pdf/zfs_exporter)) | Binary, needs the ZFS tools. In a container it needs `/dev/zfs` and the tools |
| ZED (OpenZFS 2.4.4, 2026-08-21) | **Event-driven**: device faults, checksum errors, scrub and resilver finished. Notifies by `ZED_EMAIL_ADDR`, Slack webhook, Pushover, Pushbullet, ntfy, Gotify ([zed.rc](https://github.com/openzfs/zfs/blob/zfs-2.4.4/cmd/zed/zed.d/zed.rc)) | No native Discord. Discord does accept Slack-format payloads at `POST /webhooks/{id}/{token}/slack` ([Discord webhook docs](https://docs.discord.com/developers/resources/webhook)), so `ZED_SLACK_WEBHOOK_URL=<discord webhook>/slack` should work **(unverified end to end)** |
| Beszel agent (`:alpine` image + `/dev/zfs`) | Pool health, capacity, I/O, **scrub status**, datasets, ARC in memory ([storage pools](https://beszel.dev/guide/storage-pools)) | |
| Netdata `zfspool` | Pool and vdev health, space alerts | |

Facts that matter for the setup:

- Debian/Ubuntu's `zfsutils-linux` ships a cron job that **scrubs on the second Sunday** and TRIMs on the first Sunday of every month ([Debian zfsutils-linux.cron.d](https://salsa.debian.org/zfsonlinux-team/zfs/-/blob/master/debian/zfsutils-linux.cron.d)). The scrub needs no new tool. Its result does: ZED, or Beszel's scrub status.
- The current `Disk almost full` rule filters on `fstype="ext4"`. ZFS datasets show up with `fstype="zfs"`, and their size and free space are pool-wide and shared between datasets, so the rule has to change, ideally to pool capacity from zfs_exporter or Beszel.

## 6. UPS: NUT or pwrstat

| | NUT (Network UPS Tools) | CyberPower PowerPanel for Linux (`pwrstatd` / `pwrstat`) |
|---|---|---|
| Version | 2.8.5 (2026-04-03), 2.8.6 in development ([NEWS](https://github.com/networkupstools/nut/blob/master/NEWS.adoc)). Packaged in Ubuntu (the packaged version lags upstream) | 1.4.2 announced 2026-05-18, adding Ubuntu 24.04 and Debian 13 and fixing shutdown problems (CyberPower notice, [link](https://www.cyberpowersystems.com/?p=213519), **page not loadable for verification**) |
| License | Open source (GPL) | Proprietary binary |
| Driver for CyberPower | `usbhid-ups` supports "some Cyber Power Systems models"; check the model against the HCL ([usbhid-ups(8)](https://github.com/networkupstools/nut/blob/master/docs/man/usbhid-ups.txt)) | Vendor software for its own UPSes |
| Shutdown logic | `upsmon` shuts down when the UPS is on battery **and** low battery, or on FSD. `upssched` timers through `NOTIFYCMD` allow "shut down after N minutes on battery" ([upsmon(8)](https://github.com/networkupstools/nut/blob/master/docs/man/upsmon.txt), [upssched(8)](https://github.com/networkupstools/nut/blob/master/docs/man/upssched.txt)) | `/etc/pwrstatd.conf` thresholds, and hook scripts `pwrstatd-powerfail.sh` / `pwrstatd-lowbatt.sh` ([ArchWiki mirror](https://cdn.jsdelivr.net/npm/arch-wiki-md-repo@0.10.84/wiki/_content/english/CyberPower%20UPS.md), secondary) |
| Several hosts on one UPS | Yes: one `primary`, the rest `secondary` over the network (the old server could be a secondary) ([upsmon(8)](https://github.com/networkupstools/nut/blob/master/docs/man/upsmon.txt)) | Not in the Personal edition **(unverified)**. PowerPanel Business targets that |
| Metrics | `DRuggeri/nut_exporter` v3.3.0 (2026-05-15) reads `upsd`. Netdata `upsd` collector with stock alerts | `pwrstat -status` text only |
| Notifications | `NOTIFYCMD` script (curl to Discord, or healthchecks `/fail`) | Hook scripts plus an email script |

CyberPower-specific pitfalls in the NUT driver docs ([usbhid-ups(8)](https://github.com/networkupstools/nut/blob/master/docs/man/usbhid-ups.txt)):

- Many CPS models divide `offdelay` / `ondelay` by 60 and round down. The driver defaults to 60 s and 120 s for CPS, and lower values can cut power immediately.
- CPS controllers "fall asleep" when not polled. The fix is `pollonly` and/or short `pollfreq` / `pollinterval`.
- Some CyberPower UT units report `OL+DISCHRG` on a power cut and need `onlinedischarge_onbattery`.

Do not run NUT and pwrstatd at the same time: "they might interfere with one another" ([ArchWiki mirror](https://cdn.jsdelivr.net/npm/arch-wiki-md-repo@0.10.84/wiki/_content/english/CyberPower%20UPS.md)).

A clean shutdown on battery also means stopping containers cleanly. Docker sends SIGTERM and then SIGKILL after **10 s by default** on Linux ([docker stop](https://docs.docker.com/reference/cli/docker/container/stop/)). Postgres, GitLab and Immich may need a longer `stop_grace_period`, and the UPS runtime budget has to cover the sum. NUT and the shutdown logic belong on the host (USB access, host shutdown), so they fit the Ansible host role rather than a Compose stack.

## 7. NVIDIA GPU (RTX 2080 Ti)

| | `utkuozdemir/nvidia_gpu_exporter` | `NVIDIA/dcgm-exporter` |
|---|---|---|
| Version | v2.0.0 (2026-11-19), MIT. "Side project", maintainer warns of slow responses ([README](https://github.com/utkuozdemir/nvidia_gpu_exporter)) | 4.9.0 (2026-11-06), Apache-2.0 |
| Backend | **NVML in-process by default** on Linux, or `nvidia-smi` (`exec`). Optional per-process attribution to Docker containers or systemd units with `--pid=host` | DCGM host engine (must match the exporter version, [README](https://github.com/NVIDIA/dcgm-exporter)) |
| GeForce support | Stated use case: "Consumer and prosumer GPUs (GeForce/RTX)…" | "Limited DCGM functionality is available on non-datacenter GPUs". Policy notifications are Tesla-only and diagnostics are Level 1 only on GeForce ([getting started](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/getting-started.html), [feature overview](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/feature-overview.html)) |
| Requirements | NVIDIA driver + Container Toolkit, `NVIDIA_DRIVER_CAPABILITIES=utility` | Docs ask for at least **16 GB** host RAM and the datacenter driver ([getting started](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/getting-started.html)) |
| Fit | Utilization, memory, power, thermals, throttling, encoder/decoder (Plex), per-container memory (Plex vs the LLM) | Built for fleets on Kubernetes. The exporter's own README points datacenter users to DCGM and homelabs elsewhere |

Pitfall: Beszel's docs note that polling with `nvidia-smi` can keep the GPU out of its RTD3 power-saving state, and recommend NVML ([Beszel GPU](https://beszel.dev/guide/gpu)). nvidia_gpu_exporter v2 uses NVML by default. For an idle 2080 Ti in a 24/7 box this affects power use. Whether a desktop Turing card gets RTD3 at all is **unverified**.

## 8. Resource weight

Only figures documented by the projects. Nothing was measured on the server (not allowed for this research).

| Component | Documented footprint |
|---|---|
| Netdata | "under 5 % of one CPU core and about 200 MB of RAM on a typical server", per-second, about 3,000 metrics, ML on ([resource utilization](https://learn.netdata.cloud/docs/netdata-agent/resource-utilization)) |
| Grafana | 512 MB RAM and 1 core minimum, "a floor for evaluation" ([installation](https://grafana.com/docs/grafana/latest/setup-grafana/installation/)) |
| Prometheus | 1–2 bytes per sample on disk. `disk = retention_seconds × samples/s × bytes/sample` ([storage](https://prometheus.io/docs/prometheus/latest/storage/)). Already capped at 5 GB |
| Beszel | "Smaller and less resource-intensive than leading solutions" (no figure published) ([README](https://github.com/henrygd/beszel)) |
| Gatus, deunhealth, exporters | Single Go binaries; no published figure |
| autoheal | Shell loop, one curl to the Docker API every 5 s |
| Uptime Kuma, healthchecks (self-hosted) | Node.js app / Django app + Postgres + SMTP; no published figure |
| DCGM | Host engine. Docs ask for at least 16 GB host RAM |

On a 12-core, 32 GB host, any of these combinations is small next to GitLab, Immich and a local LLM. The real budget is the 32 GB of RAM shared with the LLM and the ZFS ARC, not the CPU.

## 9. Notifications without n8n: summary

| Source of the event | Direct Discord | Email |
|---|---|---|
| Grafana Alerting | Yes (already) | `[smtp]` / `GF_SMTP_*` |
| Alertmanager | `discord_configs` | `email_configs` |
| Beszel | Shoutrrr `discord://` | PocketBase SMTP |
| Netdata agent | Yes | Yes |
| Uptime Kuma, Gatus | Yes | Yes |
| healthchecks.io | Hosted: yes. Self-hosted: own Discord app | Yes (SMTP required self-hosted) |
| autoheal | `WEBHOOK_URL` + `WEBHOOK_JSON_KEY` | Through Apprise |
| ZED | Slack-compatible `/slack` endpoint | `ZED_EMAIL_ADDR` |
| NUT, smartd | `NOTIFYCMD` / `-M exec` script | `-m` with a local mailer |

Email from any of them needs an SMTP relay or account. None was found in the current setup.

## Implications for the decision

Combinations that stand out, not ranked:

1. **Keep and complete the current stack.** Prometheus + Grafana Alerting (already file-provisioned, already on Discord) plus: rules on `container_health_state`, SMART self-test and error counters, and ZFS pool state; autoheal with opt-in labels for restarts; `smartd` for self-tests; zfs_exporter or ZED for ZFS details; NUT + nut_exporter; nvidia_gpu_exporter. Then Gatus for the status page and healthchecks.io as the external dead man's switch and the script-run journal. **For:** everything lives in Git, matches "dedicated tool, declarative host", reuses what works. **Against:** the most pieces; ZED and NUT live on the host, not in Compose.
2. **Replace metrics with Beszel.** It covers host, containers (with health alerts), SMART, ZFS (with scrub) and GPU in one agent, with Discord and email built in. Add NUT separately, Gatus or Uptime Kuma for the status page, and Beszel's heartbeat to healthchecks.io. **For:** least effort to run day to day. **Against:** alerts configured in a UI, not in Git; no UPS, Traefik or CrowdSec metrics; existing dashboards are lost.
3. **Netdata.** The widest hardware coverage out of the box (NUT, ZFS, SMART, GPU, Docker health) with stock alerts. **For:** close to zero configuration. **Against:** proprietary dashboard licence, some features need a Cloud sign-in, the heaviest agent.

Hardware choices that look the same whatever platform is picked: **NUT** over pwrstat (open, network secondaries, exporters exist, its CyberPower quirks are documented), **nvidia_gpu_exporter** over dcgm-exporter for a GeForce card, **ZED** for ZFS events, and **smartd** for self-tests.

Questions the owner has to settle:

1. **Gluetun:** keep the custom WireGuard repair script (the one script no tool replaces), or move PIA to OpenVPN or to a provider Gluetun supports natively so it can be deleted?
2. **Status page hosting:** on the server (cheap, useless during outages), on the old i5 (survives a server crash, not a power or ISP outage), or hosted/VPS (survives everything)? Should announcements be posted by a Git commit (Gatus) or by clicks (Uptime Kuma, no advance notice)?
3. **`homelab_alerts` journal:** keep it (and the backup-stale alert and the overview dashboard that read it), or move script reporting and the "no backup for 8 days" alert to healthchecks.io?
4. **Config in Git vs UI:** is a UI-configured alerting tool (Beszel, Uptime Kuma) acceptable, or must alerts stay provisioned from the repo like today?
5. **Automatic restarts:** is autoheal's restart without backoff acceptable, or should restarts stay rarer (alert only, restart by hand) for stateful services like Postgres and GitLab?
6. **Email:** which SMTP relay or account should alerts use, if email is wanted next to Discord?
7. **UPS:** the exact CyberPower model (check the NUT HCL), the runtime budget against the stop time of all stacks, and whether the old server should shut down as a NUT secondary.
8. **Old server role:** should it host the "watcher of the watcher" (Gatus or Uptime Kuma) and the status page?
