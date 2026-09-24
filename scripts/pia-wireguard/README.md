# pia_wireguard.sh — PIA WireGuard config generator

Generates the `wg0.conf` used by gluetun (`VPN_SERVICE_PROVIDER=custom`, `VPN_TYPE=wireguard`) straight from PIA's API, and lets you browse PIA's regions and servers.

Replaces `pia-wg-config`, which fails on PIA's newer servers (`Server-XXXXX-Xa`): their TLS certificate only carries the name in the CN, which Go rejects (`x509: certificate is not valid for any names`). `curl` accepts it. Upstream fix is the unmerged [PR #13](https://github.com/kylegrantlucas/pia-wg-config/pull/13).

## Prerequisites

- `curl`, `jq`, `column`
- `wg` (`sudo apt install wireguard-tools`) — falls back to `python3` + `cryptography` for key generation

## Configuration

```bash
cp .env.exemple .env
```

| Variable | Purpose |
|---|---|
| `PIA_USER` | PIA username (`p1234567`) — prompted when empty |
| `PIA_PASS` | PIA password — prompted when empty |

`.env` is gitignored — only `.env.exemple` is committed.

## Usage

```bash
./pia_wireguard.sh regions                  # every region
./pia_wireguard.sh regions toronto          # filter on id, name or country (regex)
./pia_wireguard.sh servers ca_toronto       # a region's WireGuard servers + reachability
./pia_wireguard.sh generate ca_toronto -o ../../stacks/multimedia/gluetun/wg0.conf
./pia_wireguard.sh generate ca montreal424  # pin a server (name or IP)
```

`regions` columns:

- `PF` — port forwarding supported (required for the qBittorrent forwarded port)
- `GEO` — `virtual` means the server is not physically in that country
- `GENERATION` — `legacy` (`montreal424`) or `new` (`Server-12612-2a`) servers

PIA returns a different subset of servers on each request, so `servers` may show other names from one run to the next.

`generate` picks the first reachable server (or the one given), registers a fresh key, writes the config with mode `600` and backs up any existing file to `<file>.bak-<date>`. It then prints the `SERVER_NAMES` value and the port forwarding API address.

## Applying to gluetun

```bash
./pia_wireguard.sh generate ca_toronto -o ../../stacks/multimedia/gluetun/wg0.conf
# set SERVER_NAMES=<printed value> in stacks/multimedia/.env
cd ../../stacks/multimedia
docker compose up -d --force-recreate gluetun qbittorrent
docker logs -f gluetun   # wait for "healthy" and "[port forwarding]"
```

## Manual steps (what the script does)

```bash
# 1. Server list (JSON on line 1, signature after)
curl -s https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1 > servers.json
jq -r '.regions[] | select(.id=="ca_toronto") | .servers.wg[] | "\(.ip) \(.cn)"' servers.json
WG_IP=45.89.249.18; WG_CN=Server-12612-2a

# 2. PIA's CA, to validate the server certificate
curl -s -o ca.rsa.4096.crt https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt

# 3. Token (valid 24h)
read -rp 'User: ' PIA_USER; read -rsp 'Password: ' PIA_PASS; echo
TOKEN=$(curl -s -X POST https://www.privateinternetaccess.com/api/client/v2/token \
  --form "username=$PIA_USER" --form "password=$PIA_PASS" | jq -r .token)

# 4. Key pair
PRIV=$(wg genkey); PUB=$(echo "$PRIV" | wg pubkey)

# 5. Register the public key on the server
curl -s -G --connect-to "$WG_CN::$WG_IP:" --cacert ca.rsa.4096.crt \
  --data-urlencode "pt=$TOKEN" --data-urlencode "pubkey=$PUB" \
  "https://$WG_CN:1337/addKey" > addkey.json

# 6. Build wg0.conf
jq -r --arg priv "$PRIV" '"[Interface]
Address = \(.peer_ip)
PrivateKey = \($priv)
DNS = \(.dns_servers[0])

[Peer]
PersistentKeepalive = 25
PublicKey = \(.server_key)
AllowedIPs = 0.0.0.0/0
Endpoint = \(.server_ip):\(.server_port)"' addkey.json > wg0.conf
chmod 600 wg0.conf; rm addkey.json
```

## Notes

- A config breaks when PIA retires its server: gluetun then loops on `lookup cloudflare.com: i/o timeout`. Check with `./pia_wireguard.sh servers <region>` and regenerate.
- Each `generate` registers a new key; PIA drops unused keys on its own.
