#!/usr/bin/env bash
# The RSA server-key fixtures, beside generate.sh's RSA-2048 key and
# certificate (server-rsa-key.pem, server-rsa.pem), which they reuse:
# - server-rsa-key-pkcs1.pem: that key as PKCS#1 (BEGIN RSA PRIVATE KEY);
# - rsa3072-key.pem, rsa4096-key.pem: keys of the other served sizes;
# - rsa2049-key.pem, rsa2050-key.pem: sizes whose encoded message is a byte
#   shorter than the modulus, or has seven top bits cleared;
# - rsa1024-key.pem: a key below the served range;
# - the known answers and the crafted keys: see rsa-pss-kat.py.
#
# Usage: tests/fixtures/tls/rsa-fixtures.sh   (OpenSSL 3.x, Python 3)
set -euo pipefail
cd "$(dirname "$0")"
OPENSSL="${OPENSSL:-openssl}"

"$OPENSSL" pkey -in server-rsa-key.pem -traditional -out server-rsa-key-pkcs1.pem
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out rsa3072-key.pem
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out rsa4096-key.pem
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2049 -out rsa2049-key.pem
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2050 -out rsa2050-key.pem
"$OPENSSL" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out rsa1024-key.pem
OPENSSL="$OPENSSL" python3 rsa-pss-kat.py
