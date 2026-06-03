#!/usr/bin/env bash

# $1 SSID
# $2 Encrypted password
# $3 IP:PORT
# 192.168.255.249:8008
# "wpa_auth": 7, // WPA2 Personal/Enterprise
# "wpa_cipher": 4 // AES

# curl -k --tlsv1.2 --tls-max 1.2 \
curl \
-H "content-type: application/json" \
-d "{\"ssid\":\"$1\",\"wpa_auth\":7,\"wpa_cipher\":4,\"enc_passwd\":\"$2\"}" \
"$3/setup/connect_wifi"
