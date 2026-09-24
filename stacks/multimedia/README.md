# WireGuard + Private Internet Access (PIA) with Gluetun

## Goal

Set up a WireGuard VPN using Private Internet Access (PIA) with Gluetun, including port forwarding support. qBittorrent shares Gluetun's network (`network_mode: service:gluetun`), so all its traffic goes through the VPN.

---

## Prerequisites

* Active PIA account
* Docker + Docker Compose
* Tools:

  * [`scripts/pia-wireguard`](../../scripts/pia-wireguard/README.md) — generates the WireGuard config from PIA's API
  * [`scripts/gluetun-watchdog`](../../scripts/gluetun-watchdog/README.md) — regenerates it automatically when it dies
  * https://github.com/qdm12/gluetun-wiki

> `pia-wg-config` is no longer used: it fails on PIA's newer servers (`Server-XXXXX-Xa`) with `x509: certificate is not valid for any names`. See the `pia-wireguard` README.

---

## 1. Pick a region and server

```bash
cd ../../scripts/pia-wireguard
./pia_wireguard.sh regions toronto      # filter on id, name or country; PF must be "yes"
./pia_wireguard.sh servers ca_toronto   # reachable servers in the region
```

---

## 2. Generate the WireGuard config

```bash
./pia_wireguard.sh generate ca_toronto -o ../../stacks/multimedia/gluetun/wg0.conf
```

Credentials come from `scripts/pia-wireguard/.env` (`PIA_USER` / `PIA_PASS`), or are prompted. The script picks the first reachable server, backs up the previous `wg0.conf` and prints the server name to use:

```text
Set in the gluetun .env:
  SERVER_NAMES=Server-12911-0a
```

---

## 3. Set SERVER_NAMES

In `.env`:

```bash
SERVER_NAMES=Server-12911-0a
```

It must match the server in `wg0.conf`: gluetun uses it to validate the TLS certificate of PIA's port forwarding API.

---

## 4. Configure Gluetun (docker-compose)

Key settings:

* `VPN_SERVICE_PROVIDER=custom`
* `VPN_TYPE=wireguard`
* `WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf`
* `SERVER_NAMES=${SERVER_NAMES}` (required for port forwarding)
* `VPN_PORT_FORWARDING_PROVIDER=private internet access`

Example:

```yaml
devices:
  - /dev/net/tun

volumes:
  - ./gluetun/wg0.conf:/gluetun/wireguard/wg0.conf
```

---

## 5. Start (or restart) Gluetun

```bash
docker compose up -d --force-recreate gluetun qbittorrent
```

Always recreate qBittorrent with Gluetun: it shares Gluetun's network and is left offline when Gluetun alone is restarted.

---

## 6. Check logs

```bash
docker logs -f gluetun
```

---

## 7. Verify the VPN and port forwarding

```bash
docker ps --filter name=gluetun              # (healthy)
docker exec qbittorrent wget -qO- https://ipinfo.io/ip   # a PIA IP, not yours
```

Gluetun logs should show:

```text
[port forwarding] port forwarded is XXXXX
[port forwarding] up command: [PF] SUCCESS: Port XXXXX applied
```

---

## 8. When `wg0.conf` must be regenerated

PIA retires servers and drops keys without notice. The config is dead when Gluetun stays `unhealthy` and loops on:

```text
restarting VPN because it failed to pass the healthcheck: ... lookup cloudflare.com: i/o timeout
```

This is handled automatically by [`gluetun-watchdog`](../../scripts/gluetun-watchdog/README.md) (root cron, every 5 minutes): after 15 minutes unhealthy, it regenerates `wg0.conf`, updates `SERVER_NAMES`, recreates Gluetun + qBittorrent and notifies Discord.

To do it by hand: steps 2, 3 and 5.

---

## Important notes

* Do NOT mix OpenVPN and WireGuard configs
* `SERVER_NAMES` is required for PIA port forwarding and must match the `wg0.conf` server
* `wg0.conf` contains the private key (mode `600`, gitignored) — regenerate it rather than editing it
* PIA returns a different subset of servers on each request, so server names change from one run to the next

---

## TL;DR

1. `pia_wireguard.sh generate <region> -o gluetun/wg0.conf`
2. Set the printed `SERVER_NAMES` in `.env`
3. `docker compose up -d --force-recreate gluetun qbittorrent`
4. Check logs
5. Done: the watchdog takes care of future breakages

---

## Quick troubleshooting

| Issue                                          | Cause                                                        |
| ---------------------------------------------- | ------------------------------------------------------------ |
| `lookup ... i/o timeout` loop, `unhealthy`     | server retired or key dropped by PIA → regenerate            |
| endpoint IP is not set                         | invalid `wg0.conf`                                           |
| `certificate is valid for X, not Y`            | `SERVER_NAMES` doesn't match the `wg0.conf` server           |
| `API IP address not found`                     | port forwarding API unreachable → check `SERVER_NAMES`, regenerate |
| qBittorrent stuck on "Downloading metadata"    | no network: Gluetun down, or qBittorrent not recreated with it |

---

## Final result

* WireGuard VPN working
* Public IP routed through PIA
* Port forwarding enabled
* Automatic recovery when PIA retires the server
