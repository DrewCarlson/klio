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
