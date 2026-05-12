#!/bin/sh
PORT=$1
VPN_INTERFACE=$2

# Wait until qBittorrent Web UI is ready
echo "[PF] Waiting for qBittorrent..."
until wget -q --spider http://127.0.0.1:8080; do
  sleep 2
done
echo "[PF] qBittorrent is up"
echo "[PF] Setting port $PORT on interface $VPN_INTERFACE..."

# Set the port
for i in $(seq 1 10); do
  wget -O- -nv --retry-connrefused --waitretry=2 --tries=1 \
    --post-data "json={\"listen_port\":$PORT,\"current_network_interface\":\"$VPN_INTERFACE\",\"random_port\":false,\"upnp\":false}" \
    http://127.0.0.1:8080/api/v2/app/setPreferences
  if [ $? -eq 0 ]; then
    echo "[PF] SUCCESS: Port $PORT applied"
    exit 0
  fi
  echo "[PF] Attempt $i failed, retrying..."
  sleep 2
done
echo "[PF] ERROR: Failed to apply port after 10 attempts"
exit 1