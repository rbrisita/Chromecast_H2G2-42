#!/usr/bin/env bash

# $1 is the key in bytes

{ echo "-----BEGIN RSA PUBLIC KEY-----"; cat "$1"; echo "-----END RSA PUBLIC KEY-----"; } > public_key_rsa.pem

echo "Converted:"; cat public_key_rsa.pem;
