#!/usr/bin/env bash
# Regenerates the TLS test certificates the ktor TLS tests trust and serve.
# Every key is test-only. The trusted chain is a P-256 CA and two
# server certificates it signs (P-256 and Ed25519) for localhost, 127.0.0.1
# and ::1; untrusted.pem is a self-signed P-256 certificate for the same
# names, and expired.pem a CA-signed one whose validity ended in 2001.
# Validity runs to 2094 so the fixtures do not age out.
#
# Usage: tests/fixtures/tls/generate.sh   (OpenSSL 3.x)
set -euo pipefail
cd "$(dirname "$0")"
OPENSSL="${OPENSSL:-openssl}"
DAYS=25000
SAN="subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1"

"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out ca-key.pem
"$OPENSSL" req -x509 -new -key ca-key.pem -sha256 -days "$DAYS" -subj "/CN=klio test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.pem

issue() { # issue <name> <key-file>
    "$OPENSSL" req -new -key "$2" -subj "/CN=localhost" -out "$1.csr"
    "$OPENSSL" x509 -req -in "$1.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial -days "$DAYS" -sha256 \
        -extfile <(printf '%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$SAN") \
        -out "$1.pem"
    rm -f "$1.csr"
}

"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out server-p256-key-sec1.pem
"$OPENSSL" pkcs8 -topk8 -nocrypt -in server-p256-key-sec1.pem -out server-p256-key.pem
rm -f server-p256-key-sec1.pem
issue server-p256 server-p256-key.pem

"$OPENSSL" genpkey -algorithm ed25519 -out server-ed25519-key.pem
issue server-ed25519 server-ed25519-key.pem

"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out untrusted-key.pem
"$OPENSSL" req -x509 -new -key untrusted-key.pem -sha256 -days "$DAYS" -subj "/CN=localhost" \
    -addext "$SAN" -out untrusted.pem

# A P-521 CA (a curve std.crypto cannot verify with) and the P-256 server key
# certified by it, for the unsupported-algorithm path.
"$OPENSSL" ecparam -name secp521r1 -genkey -noout -out p521-ca-key.pem
"$OPENSSL" req -x509 -new -key p521-ca-key.pem -sha512 -days "$DAYS" -subj "/CN=klio test P-521 CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out p521-ca.pem
"$OPENSSL" req -new -key server-p256-key.pem -subj "/CN=localhost" -out server-p521ca.csr
"$OPENSSL" x509 -req -in server-p521ca.csr -CA p521-ca.pem -CAkey p521-ca-key.pem -CAcreateserial -days "$DAYS" -sha512 \
    -extfile <(printf '%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$SAN") \
    -out server-p521ca.pem
rm -f server-p521ca.csr p521-ca.srl

"$OPENSSL" ecparam -name prime256v1 -genkey -noout -out expired-key.pem
"$OPENSSL" req -new -key expired-key.pem -subj "/CN=localhost" -out expired.csr
"$OPENSSL" x509 -req -in expired.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -sha256 \
    -not_before 20000101000000Z -not_after 20010101000000Z \
    -extfile <(printf '%s\n' "$SAN") -out expired.pem
rm -f expired.csr ca.srl
