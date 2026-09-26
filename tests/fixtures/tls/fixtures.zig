//! The TLS test certificates as a module, for the TLS engine's unit tests.
//! See generate.sh for what each one is.

pub const ca = @embedFile("ca.pem");
pub const server_p256 = @embedFile("server-p256.pem");
pub const server_p256_key = @embedFile("server-p256-key.pem");
pub const server_ed25519 = @embedFile("server-ed25519.pem");
pub const server_ed25519_key = @embedFile("server-ed25519-key.pem");
pub const untrusted = @embedFile("untrusted.pem");
pub const untrusted_key = @embedFile("untrusted-key.pem");
pub const expired = @embedFile("expired.pem");
pub const expired_key = @embedFile("expired-key.pem");
pub const p521_ca = @embedFile("p521-ca.pem");
/// server-p256-key.pem's key, certified by the P-521 CA.
pub const server_p521ca = @embedFile("server-p521ca.pem");
/// An RSA-2048 server certificate the CA issued; its key signs the pinned
/// TLS 1.2 ServerKeyExchange values (tls12-signatures.sh).
pub const server_rsa = @embedFile("server-rsa.pem");
pub const server_rsa_key = @embedFile("server-rsa-key.pem");
/// The same key as PKCS#1. This and the RSA keys below come from
/// rsa-fixtures.sh.
pub const server_rsa_key_pkcs1 = @embedFile("server-rsa-key-pkcs1.pem");
pub const rsa3072_key = @embedFile("rsa3072-key.pem");
pub const rsa4096_key = @embedFile("rsa4096-key.pem");
/// A 2049-bit key: its encoded message is a byte shorter than the modulus.
pub const rsa2049_key = @embedFile("rsa2049-key.pem");
/// A 2050-bit key: seven top bits of its encoded message are cleared.
pub const rsa2050_key = @embedFile("rsa2050-key.pem");
/// server-rsa-key.pem with a private exponent that is not the key's.
pub const rsa_wrong_d_key = @embedFile("rsa-wrong-d-key.pem");
/// Below the served range.
pub const rsa1024_key = @embedFile("rsa1024-key.pem");
/// server-rsa-key.pem with an even public exponent.
pub const rsa_even_e_key = @embedFile("rsa-even-e-key.pem");
/// An RSASSA-PSS SHA-256 signature by server-rsa-key.pem computed outside
/// klio (rsa-pss-kat.py), as hex.
pub const rsa_pss_kat_sha256 = @embedFile("rsa-pss-kat-sha256.hex");
pub const rsa2049_pss_kat_sha256 = @embedFile("rsa2049-pss-kat-sha256.hex");
pub const rsa2050_pss_kat_sha256 = @embedFile("rsa2050-pss-kat-sha256.hex");
