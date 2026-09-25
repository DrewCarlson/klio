#!/usr/bin/env bash
# Prints the pinned values src/ktor_tls/tls12_test.zig uses for its
# ECDHE_RSA handshakes: the server's X25519 public key for the fixed secret,
# and ServerKeyExchange signatures by server-rsa-key.pem over
# client_random || server_random || ECParameters || point, with the fixed
# randoms the test pins (0x11 and 0x22 repeated), as PKCS#1 v1.5 with SHA-256
# (rsa_pkcs1_sha256) and as PSS with SHA-256 (rsa_pss_rsae_sha256).
#
# Usage: tests/fixtures/tls/tls12-signatures.sh   (OpenSSL 3.x)
set -euo pipefail
cd "$(dirname "$0")"
OPENSSL="${OPENSSL:-openssl}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# PKCS#8 wrapping of the raw X25519 secret 0x33 * 32.
printf '302e020100300506032b656e04220420%s' "$(printf '33%.0s' $(seq 32))" | xxd -r -p > "$tmp/x25519.der"
"$OPENSSL" pkey -inform DER -in "$tmp/x25519.der" -pubout -outform DER | tail -c 32 > "$tmp/pub.bin"
echo "server x25519 public: $(xxd -p -c 64 "$tmp/pub.bin")"

{
    printf '11%.0s' $(seq 32) | xxd -r -p
    printf '22%.0s' $(seq 32) | xxd -r -p
    printf '03001d20' | xxd -r -p
    cat "$tmp/pub.bin"
} > "$tmp/signed.bin"

"$OPENSSL" dgst -sha256 -sign server-rsa-key.pem -out "$tmp/pkcs1.sig" "$tmp/signed.bin"
echo "rsa_pkcs1_sha256: $(xxd -p -c 1000 "$tmp/pkcs1.sig")"
"$OPENSSL" dgst -sha256 -sign server-rsa-key.pem -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -out "$tmp/pss.sig" "$tmp/signed.bin"
echo "rsa_pss_rsae_sha256: $(xxd -p -c 1000 "$tmp/pss.sig")"
