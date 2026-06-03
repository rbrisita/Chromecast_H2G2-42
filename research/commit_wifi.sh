#!/usr/bin/env bash

# $1 IP:PORT
# 192.168.255.249:8008

# curl -k --tlsv1.2 --tls-max 1.2 \
curl \
-H "content-type: application/json" \
-d '{"keep_hotspot_until_connected": true}' "$1/setup/save_wifi"
