//! klio's TLS engine for Ktor's network-tls actuals: a sans-IO session for
//! either side of a connection (TLS 1.3, and TLS 1.2 for a client), the
//! certificate checks around std.crypto.Certificate, and PEM loading for
//! server identities and trust anchors. Every cryptographic primitive is
//! std.crypto's.

const std = @import("std");

pub const wire = @import("wire.zig");
pub const suites = @import("suites.zig");
pub const tls12 = @import("tls12.zig");
pub const x509 = @import("x509.zig");
pub const pem = @import("pem.zig");
pub const session = @import("session.zig");

pub const Session = session.Session;
pub const ClientConfig = session.ClientConfig;
pub const ServerConfig = session.ServerConfig;
pub const Identity = session.Identity;
pub const Verification = session.Verification;
pub const AlertDescription = session.AlertDescription;
pub const Failure = session.Failure;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
    _ = @import("rfc8448_test.zig");
    _ = @import("alerts_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("interop_test.zig");
    _ = @import("tls12_test.zig");
}
