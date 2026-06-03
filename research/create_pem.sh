#!/usr/bin/env bash

# $1 RSA public key

openssl rsa \
-RSAPublicKey_in \
-in "$1" \
-pubout \
-out public_key.pem

echo "Verified:"
openssl pkey \
-pubin \
-in public_key.pem \
-text -noout
