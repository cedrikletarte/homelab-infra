#!/bin/bash
# Generate PIA WireGuard configs for gluetun (VPN_SERVICE_PROVIDER=custom) straight from PIA's API.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

SERVERLIST_URL="https://serverlist.piaservers.net/vpninfo/servers/v6"
TOKEN_URL="https://www.privateinternetaccess.com/api/client/v2/token"
CA_URL="https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pia-wireguard"
CA_CERT="$CACHE_DIR/ca.rsa.4096.crt"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  regions [filter]                   List regions (id, name, country, port forwarding, server generation)
  servers <region>                   List a region's WireGuard servers and test each one
  generate <region> [server] [-o f]  Register a new key and write a WireGuard config
                                     (default server: first reachable one, default file: ./wg0.conf)
                                     Prints the chosen server name (SERVER_NAMES) on stdout
  probe <ip> <server>                Test a server: "OK <ms>" or "DOWN"

Credentials: PIA_USER / PIA_PASS from .env next to the script, else prompted (terminal only).
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

# The list is JSON on the first line followed by a signature
serverlist() { curl -fsS -m 20 "$SERVERLIST_URL" | head -n1; }

ca_cert() {
    if [[ ! -s "$CA_CERT" ]]; then
        mkdir -p "$CACHE_DIR"
        curl -fsS -m 20 -o "$CA_CERT" "$CA_URL"
    fi
    echo "$CA_CERT"
}

# Prints "OK <ms>" if the server's API answers with a valid PIA certificate, else "DOWN"
probe() {
    local ip=$1 cn=$2 t
    if t=$(curl -s -m 5 --cacert "$(ca_cert)" --connect-to "$cn::$ip:" -o /dev/null -w '%{time_connect}' "https://$cn:1337/"); then
        awk -v t="$t" 'BEGIN { printf "OK %dms\n", t * 1000 }'
    else
        echo "DOWN"
    fi
}

cmd_regions() {
    local filter=${1:-}
    {
        echo -e "ID\tNAME\tCOUNTRY\tPF\tGEO\tWG\tGENERATION"
        serverlist | jq -r --arg f "$filter" '
            .regions[]
            | select(($f == "") or (.id | test($f; "i")) or (.name | test($f; "i")) or (.country | test($f; "i")))
            | (.servers.wg // []) as $wg
            | ([$wg[].cn | select(startswith("Server-"))] | length) as $new
            | [ .id, .name, .country,
                (if .port_forward then "yes" else "no" end),
                (if .geo then "virtual" else "physical" end),
                ($wg | length),
                (if ($wg | length) == 0 then "-" elif $new == 0 then "legacy" elif $new == ($wg | length) then "new" else "mixed" end)
              ] | @tsv' | sort
    } | column -t -s $'\t'
}

region_servers() {
    serverlist | jq -r --arg r "$1" '.regions[] | select(.id == $r) | .servers.wg[]? | "\(.ip) \(.cn)"'
}

cmd_servers() {
    local region=${1:?region required, see: $(basename "$0") regions}
    local servers
    servers=$(region_servers "$region")
    [[ -n "$servers" ]] || die "no WireGuard servers for region '$region'"
    {
        echo -e "IP\tSERVER_NAME\tSTATUS"
        while read -r ip cn; do
            echo -e "$ip\t$cn\t$(probe "$ip" "$cn")"
        done <<<"$servers"
    } | column -t -s $'\t'
}

genkeys() {
    if command -v wg >/dev/null; then
        local priv
        priv=$(wg genkey)
        echo "$priv $(wg pubkey <<<"$priv")"
    else
        python3 -c '
import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = X25519PrivateKey.generate()
print(base64.b64encode(k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())).decode(),
      base64.b64encode(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).decode())' \
            || die "install wireguard-tools (sudo apt install wireguard-tools) or python3-cryptography"
    fi
}

cmd_generate() {
    local region="" server="" out="wg0.conf"
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o) out=${2:?}; shift 2 ;;
            *) if [[ -z "$region" ]]; then region=$1; else server=$1; fi; shift ;;
        esac
    done
    [[ -n "$region" ]] || die "region required, see: $(basename "$0") regions"

    local servers ip="" cn=""
    servers=$(region_servers "$region")
    [[ -n "$servers" ]] || die "no WireGuard servers for region '$region'"
    while read -r s_ip s_cn; do
        if [[ -n "$server" && "$s_cn" != "$server" && "$s_ip" != "$server" ]]; then continue; fi
        if [[ $(probe "$s_ip" "$s_cn") == OK* ]]; then ip=$s_ip; cn=$s_cn; break; fi
        echo "$s_cn ($s_ip) not reachable, skipping" >&2
    done <<<"$servers"
    [[ -n "$ip" ]] || die "no reachable server${server:+ matching '$server'} in '$region'"
    echo "Server: $cn ($ip)" >&2

    local user=${PIA_USER:-} pass=${PIA_PASS:-}
    if [[ ( -z "$user" || -z "$pass" ) && ! -t 0 ]]; then
        die "PIA_USER / PIA_PASS missing from $SCRIPT_DIR/.env (no terminal to prompt)"
    fi
    [[ -n "$user" ]] || read -rp "PIA username: " user
    [[ -n "$pass" ]] || { read -rsp "PIA password: " pass; echo >&2; }

    # Password is fed through stdin so it never shows up in the process list
    local token
    token=$(printf '%s' "$pass" | curl -fsS -m 20 -X POST "$TOKEN_URL" \
        --form "username=$user" --form "password=<-" | jq -r '.token // empty') \
        || die "token request failed"
    [[ -n "$token" ]] || die "authentication failed (check PIA_USER / PIA_PASS)"

    local keys priv pub resp
    keys=$(genkeys)
    priv=${keys% *}
    pub=${keys#* }
    resp=$(curl -fsS -m 20 -G --connect-to "$cn::$ip:" --cacert "$(ca_cert)" \
        --data-urlencode "pt=$token" --data-urlencode "pubkey=$pub" "https://$cn:1337/addKey") \
        || die "addKey request failed"
    [[ $(jq -r .status <<<"$resp") == "OK" ]] || die "addKey refused: $resp"

    if [[ -e "$out" ]]; then
        cp -p "$out" "$out.bak-$(date +%Y%m%d-%H%M%S)"
        echo "Previous config saved to $out.bak-*" >&2
    fi
    (
        umask 077
        jq -r --arg priv "$priv" '
"[Interface]
Address = \(.peer_ip)
PrivateKey = \($priv)
DNS = \(.dns_servers[0])

[Peer]
PersistentKeepalive = 25
PublicKey = \(.server_key)
AllowedIPs = 0.0.0.0/0
Endpoint = \(.server_ip):\(.server_port)"' <<<"$resp" >"$out"
    )
    # umask only applies on creation, an overwritten file keeps its old mode
    chmod 600 "$out"

    cat >&2 <<EOF
Config written to $out
  Endpoint:            $(jq -r '"\(.server_ip):\(.server_port)"' <<<"$resp")
  Peer IP:             $(jq -r .peer_ip <<<"$resp")
  Port forwarding API: $(jq -r .server_vip <<<"$resp"):19999
Set in the gluetun .env:
  SERVER_NAMES=$cn
EOF
    echo "$cn"
}

case ${1:-} in
    regions) shift; cmd_regions "$@" ;;
    servers) shift; cmd_servers "$@" ;;
    generate) shift; cmd_generate "$@" ;;
    probe) shift; probe "${1:?ip required}" "${2:?server name required}" ;;
    *) usage; exit 1 ;;
esac
