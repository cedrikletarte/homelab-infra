# 🛡️ WireGuard + Private Internet Access (PIA) with Gluetun

## 🎯 Goal

Set up a WireGuard VPN using Private Internet Access (PIA) with Gluetun, including port forwarding support.

---

## 📦 Prerequisites

* Active PIA account
* Docker + Docker Compose
* Tools:

  * https://github.com/kylegrantlucas/pia-wg-config
  * https://github.com/qdm12/gluetun-wiki

---

## ⚙️ 1. Generate the WireGuard config

Run:

```bash
pia-wg-config -o wg0.conf -r ca_toronto USERNAME PASSWORD
```

Replace:

* `USERNAME` → your PIA username
* `PASSWORD` → your PIA password

---

## 📁 2. Place the config file

Move the file to:

```
./gluetun/wg0.conf
```

---

## 🐳 3. Configure Gluetun (docker-compose)

Key settings:

* `VPN_SERVICE_PROVIDER=custom`
* `VPN_TYPE=wireguard`
* `WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf`
* `SERVER_NAMES=xxx` (required for port forwarding)

Example:

```yaml
devices:
  - /dev/net/tun:/dev/net/tun

volumes:
  - ./gluetun/wg0.conf:/gluetun/wireguard/wg0.conf
```

---

## 🚀 4. Start Gluetun

```bash
docker compose up -d
```

---

## 🔍 5. Check logs

```bash
docker logs -f gluetun
```

---

## 🧠 6. Find the correct SERVER_NAMES

Look for:

```text
Public IP address is XXX (Canada, Ontario, Toronto)
```

Or TLS error:

```text
certificate is valid for toronto405, not toronto
```

👉 Correct server name in this example:

```
toronto405
```

---

## 🔁 7. Update SERVER_NAMES

In `docker-compose.yml`:

```yaml
- SERVER_NAMES=toronto405
```

Restart:

```bash
docker compose down
docker compose up -d
```

---

## 🔓 8. Verify port forwarding

Logs should show:

```text
port forwarding assigned port XXXXX
```

---

## 🔄 9. When to regenerate `wg0.conf`

Regenerate only if you see:

* `i/o timeout`
* `endpoint IP is not set`
* `tls: failed to verify certificate`
* VPN no longer connects

---

## ⚠️ Important notes

* Do NOT mix OpenVPN and WireGuard configs
* `SERVER_NAMES` is required for PIA port forwarding
* `wg0.conf` contains the real endpoint (do not edit manually)
* PIA port forwarding can be unstable

---

## 🧠 TL;DR

1. Generate `wg0.conf`
2. Mount it in Gluetun
3. Start container
4. Check logs
5. Adjust `SERVER_NAMES`
6. Done ✅

---

## 💬 Quick troubleshooting

| Issue                  | Cause                     |
| ---------------------- | ------------------------- |
| endpoint IP is not set | invalid wg0.conf          |
| i/o timeout            | server down / UDP blocked |
| TLS error              | wrong SERVER_NAMES        |
| no port assigned       | PIA port forwarding issue |

---

## 🚀 Final result

* WireGuard VPN working
* Public IP routed through PIA
* Port forwarding enabled
* Reproducible setup

---
