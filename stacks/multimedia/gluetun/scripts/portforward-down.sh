#!/bin/sh

# Wait until qBittorrent Web UI is ready
echo "[PF] Resetting qBittorrent port..."
until wget -q --spider http://127.0.0.1:8080; do
  sleep 2
done

# Reset the port
wget -O- -nv --retry-connrefused --waitretry=2 --tries=5 \
  --post-data 'json={"listen_port":0,"current_network_interface":"lo"}' \
  http://127.0.0.1:8080/api/v2/app/setPreferences
if [ $? -eq 0 ]; then
  echo "[PF] SUCCESS: Port reset"
else
  echo "[PF] ERROR: Failed to reset port"
  exit 1
fi