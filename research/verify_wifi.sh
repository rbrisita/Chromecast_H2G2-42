#!/usr/bin/env bash

# $1 IP:PORT
# 192.168.xxx.xxx:8008


curl -k --tlsv1.2 --tls-max 1.2 \
curl \
"$1/setup/configured_networks"
