#!/usr/bin/env bash

# $1 WiFi password
# $2 Key in public key pem format

# TODO Add arg check and error handling

echo -n "$1" | \
openssl pkeyutl \
-encrypt \
-pubin \
-inkey "$2" \
-out encrypted_password.bin && \
base64 encrypted_password.bin > encrypted_password.b64

echo "Base64 Encrypted Binary:"
cat encrypted_password.b64
