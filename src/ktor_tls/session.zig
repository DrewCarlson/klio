//! A sans-IO TLS 1.3 session (RFC 8446), client or server.
//!
//! The session never touches a socket. The caller feeds it the bytes read from
//! the peer (`feed`), sends whatever it queues (`output`/`consumeOutput`),
//! reads the application data it decrypts (`appData`/`consumeApp`) and hands
//! it application data to protect (`writeApp`). A protocol failure queues the
//! matching alert, moves the session to `.failed` and returns
//! `error.TlsFailure`; `failure` then says which alert and why.
//!
//! Scope: TLS 1.3 only; X25519, P-256 and P-384 key exchange; the three
//! standard AEAD suites; server keys P-256 ECDSA or Ed25519; peer certificates
//! verified against a trust bundle with ECDSA, Ed25519 or RSA (PSS for
//! CertificateVerify) signatures. No client certificates (a server's
//! CertificateRequest is answered with an empty Certificate), no session
//! resumption, no 0-RTT.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Certificate = crypto.Certificate;

const wire = @import("wire.zig");
const suites = @import("suites.zig");
const x509 = @import("x509.zig");
const pem = @import("pem.zig");

pub const Suite = suites.Suite;
const Cipher = suites.Cipher;
const Secret = suites.Secret;

pub const Role = enum { client, server };

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
    _,
};

pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    certificate_request = 13,
    certificate_verify = 15,
    finished = 20,
    key_update = 24,
    message_hash = 254,
    _,
};

pub const ExtensionType = struct {
    pub const server_name: u16 = 0;
    pub const max_fragment_length: u16 = 1;
    pub const status_request: u16 = 5;
    pub const supported_groups: u16 = 10;
    pub const signature_algorithms: u16 = 13;
    pub const use_srtp: u16 = 14;
    pub const heartbeat: u16 = 15;
    pub const alpn: u16 = 16;
    pub const signed_certificate_timestamp: u16 = 18;
    pub const client_certificate_type: u16 = 19;
    pub const server_certificate_type: u16 = 20;
    pub const padding: u16 = 21;
    pub const record_size_limit: u16 = 28;
    pub const pre_shared_key: u16 = 41;
    pub const early_data: u16 = 42;
    pub const supported_versions: u16 = 43;
    pub const cookie: u16 = 44;
    pub const psk_key_exchange_modes: u16 = 45;
    pub const certificate_authorities: u16 = 47;
    pub const oid_filters: u16 = 48;
    pub const post_handshake_auth: u16 = 49;
    pub const signature_algorithms_cert: u16 = 50;
    pub const key_share: u16 = 51;
};

pub const AlertDescription = enum(u8) {
    close_notify = 0,
    unexpected_message = 10,
    bad_record_mac = 20,
    record_overflow = 22,
    handshake_failure = 40,
    bad_certificate = 42,
    unsupported_certificate = 43,
    certificate_revoked = 44,
    certificate_expired = 45,
    certificate_unknown = 46,
    illegal_parameter = 47,
    unknown_ca = 48,
    access_denied = 49,
    decode_error = 50,
    decrypt_error = 51,
    protocol_version = 70,
    insufficient_security = 71,
    internal_error = 80,
    inappropriate_fallback = 86,
    user_canceled = 90,
    missing_extension = 109,
    unsupported_extension = 110,
    unrecognized_name = 112,
    bad_certificate_status_response = 113,
    unknown_psk_identity = 115,
    certificate_required = 116,
    no_application_protocol = 120,
    _,
};

pub const Group = enum(u16) {
    secp256r1 = 0x0017,
    secp384r1 = 0x0018,
    x25519 = 0x001d,
    _,
};

pub const SignatureScheme = struct {
    pub const rsa_pkcs1_sha256: u16 = 0x0401;
    pub const rsa_pkcs1_sha384: u16 = 0x0501;
    pub const rsa_pkcs1_sha512: u16 = 0x0601;
    pub const ecdsa_secp256r1_sha256: u16 = 0x0403;
    pub const ecdsa_secp384r1_sha384: u16 = 0x0503;
    pub const rsa_pss_rsae_sha256: u16 = 0x0804;
    pub const rsa_pss_rsae_sha384: u16 = 0x0805;
    pub const rsa_pss_rsae_sha512: u16 = 0x0806;
    pub const ed25519: u16 = 0x0807;
    pub const rsa_pss_pss_sha256: u16 = 0x0809;
    pub const rsa_pss_pss_sha384: u16 = 0x080a;
    pub const rsa_pss_pss_sha512: u16 = 0x080b;
};

pub const tls13: u16 = 0x0304;
pub const max_plaintext = 1 << 14;
const max_ciphertext = max_plaintext + 256;
const max_handshake_message = 1 << 17;
const record_header_len = 5;

pub const hello_retry_random = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

pub const default_suites = [_]Suite{ .aes_128_gcm_sha256, .chacha20_poly1305_sha256, .aes_256_gcm_sha384 };
pub const default_groups = [_]Group{ .x25519, .secp256r1, .secp384r1 };
pub const default_key_share_groups = [_]Group{.x25519};

/// The signature schemes a client offers. The PKCS#1 ones cover certificate
/// signatures only; a CertificateVerify signed with one is refused.
pub const default_signature_schemes = [_]u16{
    SignatureScheme.ecdsa_secp256r1_sha256,
    SignatureScheme.ed25519,
    SignatureScheme.ecdsa_secp384r1_sha384,
    SignatureScheme.rsa_pss_rsae_sha256,
    SignatureScheme.rsa_pss_rsae_sha384,
    SignatureScheme.rsa_pss_rsae_sha512,
    SignatureScheme.rsa_pss_pss_sha256,
    SignatureScheme.rsa_pss_pss_sha384,
    SignatureScheme.rsa_pss_pss_sha512,
    SignatureScheme.rsa_pkcs1_sha256,
    SignatureScheme.rsa_pkcs1_sha384,
    SignatureScheme.rsa_pkcs1_sha512,
};

/// Inputs that pin a handshake's choices for known-answer tests (the RFC 8448
/// traces). Production configurations leave every field null.
pub const TestHooks = struct {
    /// The hello random.
    random: ?[32]u8 = null,
    /// Ephemeral private keys, per group.
    x25519_secret: ?[32]u8 = null,
    p256_secret: ?[32]u8 = null,
    /// A client's first ClientHello extension block, used verbatim. It must
    /// carry the key shares the pinned secrets produce.
    client_hello_extensions: ?[]const u8 = null,
    /// A client's ClientHello extension block after a HelloRetryRequest.
    retry_hello_extensions: ?[]const u8 = null,
    /// A server's EncryptedExtensions extension block.
    encrypted_extensions: ?[]const u8 = null,
    /// A server's HelloRetryRequest extension block.
    hello_retry_extensions: ?[]const u8 = null,
    /// A server's CertificateVerify signature, for a trace whose key type the
    /// server does not sign with.
    signature: ?struct { scheme: u16, bytes: []const u8 } = null,
};

/// How a client checks the server's certificate.
pub const Verification = union(enum) {
    /// Chain to an anchor in `anchors` or `system_anchors`, valid at
    /// `now_sec`, issued for the configured server name.
    trust: struct {
        anchors: ?*const Certificate.Bundle = null,
        system_anchors: ?*const Certificate.Bundle = null,
        now_sec: i64,
    },
    /// Accept any certificate. The handshake still checks the peer's
    /// signature over the transcript with the leaf's key, but not who the
    /// leaf belongs to. For tests against an untrusted peer only.
    insecure_accept_any,
};

pub const ClientConfig = struct {
    /// Sent as SNI (unless an IP literal) and matched against the leaf.
    server_name: ?[]const u8 = null,
    verification: Verification,
    cipher_suites: []const Suite = &default_suites,
    groups: []const Group = &default_groups,
    key_share_groups: []const Group = &default_key_share_groups,
    signature_schemes: []const u16 = &default_signature_schemes,
    /// Middlebox compatibility mode (RFC 8446 D.4): a legacy session id and a
    /// dummy ChangeCipherSpec before the second flight.
    compat_mode: bool = true,
    hooks: TestHooks = .{},
};

pub const Identity = struct {
    /// DER certificates, leaf first.
    chain: []const []const u8,
    key: pem.PrivateKey,
};

pub const ServerConfig = struct {
    identity: *const Identity,
    cipher_suites: []const Suite = &default_suites,
    groups: []const Group = &default_groups,
    /// Choose the first of `groups` the client supports even when that costs
    /// a HelloRetryRequest; otherwise prefer a group the client already sent
    /// a key share for.
    strict_group_preference: bool = false,
    hooks: TestHooks = .{},
};

pub const Failure = struct {
    alert: AlertDescription,
    /// Whether this side detected the failure (and sent the alert) or the peer
    /// sent it.
    local: bool,
    reason: []const u8,
};

const State = enum {
    // client
    wait_server_hello,
    wait_encrypted_extensions,
    wait_certificate_or_request,
    wait_certificate,
    wait_certificate_verify,
    wait_server_finished,
    // server
    wait_client_hello,
    wait_retry_client_hello,
    wait_client_finished,
    // both
    connected,
    failed,
};

const Fail = error{Alert};
pub const Error = error{TlsFailure} || Allocator.Error;

const KeyShare = union(enum) {
    x25519: crypto.dh.X25519.KeyPair,
    p256: crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair,
    p384: crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,

    fn group(k: *const KeyShare) Group {
        return switch (k.*) {
            .x25519 => .x25519,
            .p256 => .secp256r1,
            .p384 => .secp384r1,
        };
    }

    fn publicBytes(k: *const KeyShare, buf: *[97]u8) []const u8 {
        switch (k.*) {
            .x25519 => |kp| {
                buf[0..32].* = kp.public_key;
                return buf[0..32];
            },
            .p256 => |kp| {
                buf[0..65].* = kp.public_key.toUncompressedSec1();
                return buf[0..65];
            },
            .p384 => |kp| {
                buf[0..97].* = kp.public_key.toUncompressedSec1();
                return buf[0..97];
            },
        }
    }

    /// The shared secret with the peer's public share, or null when the
    /// share is malformed or yields the identity.
    fn exchange(k: *const KeyShare, peer: []const u8, out: *[48]u8) ?[]const u8 {
        switch (k.*) {
            .x25519 => |kp| {
                if (peer.len != 32) return null;
                const s = crypto.dh.X25519.scalarmult(kp.secret_key, peer[0..32].*) catch return null;
                out[0..32].* = s;
                return out[0..32];
            },
            .p256 => |kp| {
                if (peer.len != 65 or peer[0] != 4) return null;
                const pk = crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey.fromSec1(peer) catch return null;
                const p = pk.p.mul(kp.secret_key.bytes, .big) catch return null;
                out[0..32].* = p.affineCoordinates().x.toBytes(.big);
                return out[0..32];
            },
            .p384 => |kp| {
                if (peer.len != 97 or peer[0] != 4) return null;
                const pk = crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey.fromSec1(peer) catch return null;
                const p = pk.p.mul(kp.secret_key.bytes, .big) catch return null;
                out[0..48].* = p.affineCoordinates().x.toBytes(.big);
                return out[0..48];
            },
        }
    }
};

/// A byte queue consumed from the front.
const Queue = struct {
    list: std.ArrayList(u8) = .empty,
    start: usize = 0,

    fn items(q: *const Queue) []const u8 {
        return q.list.items[q.start..];
    }

    fn append(q: *Queue, a: Allocator, b: []const u8) Allocator.Error!void {
        if (q.start > 0 and q.start == q.list.items.len) {
            q.list.clearRetainingCapacity();
            q.start = 0;
        }
        try q.list.appendSlice(a, b);
    }

    fn consume(q: *Queue, n: usize) void {
        q.start += n;
        if (q.start == q.list.items.len) {
            q.list.clearRetainingCapacity();
            q.start = 0;
        } else if (q.start > 1 << 16 and q.start * 2 > q.list.items.len) {
            const rest = q.list.items.len - q.start;
            std.mem.copyForwards(u8, q.list.items[0..rest], q.list.items[q.start..]);
            q.list.shrinkRetainingCapacity(rest);
            q.start = 0;
        }
    }

    fn deinit(q: *Queue, a: Allocator) void {
        q.list.deinit(a);
    }
};

/// The peer's leaf key, kept to check its CertificateVerify.
const PeerKey = struct {
    algo: Certificate.Parsed.PubKeyAlgo,
    bytes: std.ArrayList(u8) = .empty,
};

pub const Session = struct {
    a: Allocator,
    role: Role,
    state: State,
    client_config: ?*const ClientConfig = null,
    server_config: ?*const ServerConfig = null,
    rng: std.Random.DefaultCsprng,

    in: Queue = .{},
    out: Queue = .{},
    app: Queue = .{},
    hs_buf: Queue = .{},
    /// Every handshake message so far, for the transcript hash; freed once the
    /// handshake completes.
    transcript: std.ArrayList(u8) = .empty,

    suite: ?Suite = null,
    read: ?Cipher = null,
    write: ?Cipher = null,
    handshake_secret: Secret = .{},
    master_secret: Secret = .{},
    client_hs: Secret = .{},
    server_hs: Secret = .{},
    client_ap: Secret = .{},
    server_ap: Secret = .{},

    random: [32]u8 = @splat(0),
    session_id: [32]u8 = @splat(0),
    session_id_len: u8 = 0,
    /// Client: the shares offered in the current ClientHello.
    shares: [3]?KeyShare = .{ null, null, null },
    /// Client: the extension types of the current ClientHello.
    offered_extensions: std.ArrayList(u16) = .empty,
    retried: bool = false,
    retry_suite: ?Suite = null,
    cookie: std.ArrayList(u8) = .empty,
    ccs_sent: bool = false,
    client_auth_requested: bool = false,
    certificate_request_context: std.ArrayList(u8) = .empty,
    peer_key: ?PeerKey = null,
    /// Server: the negotiated choices.
    selected_group: ?Group = null,
    selected_scheme: u16 = 0,
    server_name: std.ArrayList(u8) = .empty,
    skip_early_data: usize = 0,
    expected_client_finished: Secret = .{},

    peer_closed: bool = false,
    close_sent: bool = false,
    failure_info: ?Failure = null,
    /// The alert this side is about to send, set by `fail`.
    pending_alert: AlertDescription = .internal_error,
    pending_reason: []const u8 = "",

    /// Starts a client and queues its ClientHello. A configuration the client
    /// cannot start from leaves it `failed` with the reason in `failure`,
    /// and nothing to send.
    pub fn initClient(a: Allocator, config: *const ClientConfig, seed: [32]u8) Allocator.Error!Session {
        var s: Session = .{
            .a = a,
            .role = .client,
            .state = .wait_server_hello,
            .client_config = config,
            .rng = .init(seed),
        };
        errdefer s.deinit();
        s.startClient() catch |e| switch (e) {
            error.Alert => {
                s.state = .failed;
                s.failure_info = .{ .alert = s.pending_alert, .local = true, .reason = s.pending_reason };
                s.out.list.clearRetainingCapacity();
                s.out.start = 0;
                s.wipeSecrets();
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return s;
    }

    pub fn initServer(a: Allocator, config: *const ServerConfig, seed: [32]u8) Session {
        return .{
            .a = a,
            .role = .server,
            .state = .wait_client_hello,
            .server_config = config,
            .rng = .init(seed),
        };
    }

    pub fn deinit(s: *Session) void {
        s.in.deinit(s.a);
        s.out.deinit(s.a);
        crypto.secureZero(u8, s.app.list.allocatedSlice());
        s.app.deinit(s.a);
        s.hs_buf.deinit(s.a);
        s.transcript.deinit(s.a);
        s.offered_extensions.deinit(s.a);
        s.cookie.deinit(s.a);
        s.certificate_request_context.deinit(s.a);
        s.server_name.deinit(s.a);
        if (s.peer_key) |*k| k.bytes.deinit(s.a);
        s.wipeSecrets();
        if (s.read) |*c| c.wipe();
        if (s.write) |*c| c.wipe();
        s.* = undefined;
    }

    fn wipeSecrets(s: *Session) void {
        s.handshake_secret.wipe();
        s.master_secret.wipe();
        s.client_hs.wipe();
        s.server_hs.wipe();
        s.client_ap.wipe();
        s.server_ap.wipe();
        s.expected_client_finished.wipe();
        for (&s.shares) |*k| {
            if (k.*) |*ks| crypto.secureZero(u8, std.mem.asBytes(ks));
            k.* = null;
        }
    }

    // ---- public surface ---------------------------------------------------

    pub fn handshakeDone(s: *const Session) bool {
        return s.state == .connected;
    }

    pub fn failed(s: *const Session) bool {
        return s.state == .failed;
    }

    pub fn failure(s: *const Session) ?Failure {
        return s.failure_info;
    }

    /// Whether the peer sent close_notify.
    pub fn peerClosed(s: *const Session) bool {
        return s.peer_closed;
    }

    /// Bytes waiting to go to the peer.
    pub fn output(s: *const Session) []const u8 {
        return s.out.items();
    }

    pub fn consumeOutput(s: *Session, n: usize) void {
        s.out.consume(n);
    }

    /// Decrypted application data waiting for the reader.
    pub fn appData(s: *const Session) []const u8 {
        return s.app.items();
    }

    pub fn consumeApp(s: *Session, n: usize) void {
        s.app.consume(n);
    }

    /// The server name the client asked for (server side).
    pub fn requestedServerName(s: *const Session) ?[]const u8 {
        return if (s.server_name.items.len == 0) null else s.server_name.items;
    }

    pub fn negotiatedSuite(s: *const Session) ?Suite {
        return s.suite;
    }

    /// Takes bytes received from the peer and processes every complete record.
    pub fn feed(s: *Session, bytes: []const u8) Error!void {
        if (s.state == .failed) return error.TlsFailure;
        try s.in.append(s.a, bytes);
        s.processRecords() catch |e| switch (e) {
            error.Alert => return s.abort(),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Protects application data for the peer. Only after the handshake.
    pub fn writeApp(s: *Session, data: []const u8) Error!void {
        if (s.state != .connected or s.close_sent) return error.TlsFailure;
        s.sendRecord(.application_data, data) catch |e| switch (e) {
            error.Alert => return s.abort(),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Sends a whole handshake message after the handshake, such as a
    /// NewSessionTicket this session never issues on its own. For
    /// known-answer tests that replay a trace.
    pub fn sendRawHandshake(s: *Session, msg: []const u8) Error!void {
        if (s.state != .connected) return error.TlsFailure;
        s.sendRecord(.handshake, msg) catch |e| switch (e) {
            error.Alert => return s.abort(),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Moves this side's sending keys forward and asks the peer to do the
    /// same (KeyUpdate with update_requested).
    pub fn requestKeyUpdate(s: *Session) Error!void {
        if (s.state != .connected or s.close_sent) return error.TlsFailure;
        s.sendRecord(.handshake, &.{ @intFromEnum(HandshakeType.key_update), 0, 0, 1, 1 }) catch |e| switch (e) {
            error.Alert => return s.abort(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        rotate(&s.write);
    }

    /// Queues close_notify. Further writes are refused.
    pub fn close(s: *Session) Allocator.Error!void {
        if (s.close_sent or s.state == .failed) return;
        s.close_sent = true;
        s.sendRecord(.alert, &.{ 1, @intFromEnum(AlertDescription.close_notify) }) catch |e| switch (e) {
            error.Alert => {},
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // ---- failure ----------------------------------------------------------

    fn fail(s: *Session, alert: AlertDescription, reason: []const u8) Fail {
        s.pending_alert = alert;
        s.pending_reason = reason;
        return error.Alert;
    }

    /// Sends the pending alert, protected when keys are in place, and fails.
    fn abort(s: *Session) error{TlsFailure} {
        if (s.state != .failed) {
            s.state = .failed;
            if (s.failure_info == null) {
                s.failure_info = .{ .alert = s.pending_alert, .local = true, .reason = s.pending_reason };
                s.sendRecord(.alert, &.{ 2, @intFromEnum(s.pending_alert) }) catch {};
            }
            s.wipeSecrets();
        }
        return error.TlsFailure;
    }

    fn decodeFail(s: *Session, reason: []const u8) Fail {
        return s.fail(.decode_error, reason);
    }

    // ---- records out ------------------------------------------------------

    /// Sends `payload` as records of `ct`, fragmented at the plaintext limit,
    /// protected with the current write keys when there are any.
    fn sendRecord(s: *Session, ct: ContentType, payload: []const u8) (Fail || Allocator.Error)!void {
        var rest = payload;
        while (true) {
            const n = @min(rest.len, max_plaintext);
            try s.sendFragment(ct, rest[0..n]);
            rest = rest[n..];
            if (rest.len == 0) break;
        }
    }

    fn sendFragment(s: *Session, ct: ContentType, frag: []const u8) (Fail || Allocator.Error)!void {
        const q = &s.out.list;
        // In compatibility mode a client's first protected record follows a
        // dummy ChangeCipherSpec.
        if (s.write != null and s.role == .client and s.client_config.?.compat_mode) try s.sendChangeCipherSpec();
        if (s.write) |*c| {
            const inner_len = frag.len + 1;
            const total = inner_len + suites.tag_len;
            try q.ensureUnusedCapacity(s.a, record_header_len + total);
            var header: [5]u8 = .{ @intFromEnum(ContentType.application_data), 0x03, 0x03, 0, 0 };
            std.mem.writeInt(u16, header[3..5], @intCast(total), .big);
            const inner = try s.a.alloc(u8, inner_len);
            defer {
                crypto.secureZero(u8, inner);
                s.a.free(inner);
            }
            @memcpy(inner[0..frag.len], frag);
            inner[frag.len] = @intFromEnum(ct);
            try s.out.append(s.a, &header);
            const dst = q.addManyAsSliceAssumeCapacity(total);
            c.seal(dst[0..inner_len], dst[inner_len..][0..suites.tag_len], inner, &header) catch
                return s.fail(.internal_error, "record sequence exhausted");
        } else {
            // The first ClientHello goes out as record version 1.0 for
            // compatibility; everything else says 1.2.
            const legacy: u8 = if (s.role == .client and ct == .handshake and s.suite == null) 0x01 else 0x03;
            var header: [5]u8 = .{ @intFromEnum(ct), 0x03, legacy, 0, 0 };
            std.mem.writeInt(u16, header[3..5], @intCast(frag.len), .big);
            try s.out.append(s.a, &header);
            try s.out.append(s.a, frag);
        }
    }

    fn sendChangeCipherSpec(s: *Session) Allocator.Error!void {
        if (s.ccs_sent) return;
        s.ccs_sent = true;
        try s.out.append(s.a, &.{ @intFromEnum(ContentType.change_cipher_spec), 0x03, 0x03, 0x00, 0x01, 0x01 });
    }

    // ---- records in -------------------------------------------------------

    fn processRecords(s: *Session) (Fail || Allocator.Error)!void {
        while (s.state != .failed) {
            const buf = s.in.items();
            if (buf.len < record_header_len) return;
            const ct: ContentType = @enumFromInt(buf[0]);
            if (buf[1] != 0x03) return s.fail(.protocol_version, "record version is not TLS");
            const len = std.mem.readInt(u16, buf[3..5], .big);
            const limit: usize = if (s.read != null) max_ciphertext else max_plaintext;
            if (len > limit) return s.fail(.record_overflow, "record longer than the limit");
            if (buf.len < record_header_len + len) return;
            const header = buf[0..record_header_len].*;
            const payload = try s.a.dupe(u8, buf[record_header_len..][0..len]);
            defer {
                crypto.secureZero(u8, payload);
                s.a.free(payload);
            }
            s.in.consume(record_header_len + len);
            try s.processRecord(ct, header, payload);
        }
    }

    fn processRecord(s: *Session, ct: ContentType, header: [5]u8, payload: []u8) (Fail || Allocator.Error)!void {
        if (ct == .change_cipher_spec) {
            // A middlebox-compatibility CCS: one byte 0x01, only while the
            // handshake runs; dropped.
            if (payload.len != 1 or payload[0] != 1) return s.fail(.unexpected_message, "malformed change_cipher_spec");
            if (s.state == .connected) return s.fail(.unexpected_message, "change_cipher_spec after the handshake");
            if (s.role == .server and s.state == .wait_client_hello) return s.fail(.unexpected_message, "change_cipher_spec before ClientHello");
            return;
        }
        if (s.read) |*c| {
            if (ct != .application_data) return s.fail(.unexpected_message, "unprotected record after keys changed");
            if (payload.len < suites.tag_len + 1) return s.fail(.bad_record_mac, "protected record too short");
            const body_len = payload.len - suites.tag_len;
            const plain = try s.a.alloc(u8, body_len);
            defer {
                crypto.secureZero(u8, plain);
                s.a.free(plain);
            }
            c.open(plain, payload[0..body_len], payload[body_len..][0..suites.tag_len].*, &header) catch |e| switch (e) {
                error.BadRecordMac => {
                    if (s.skip_early_data >= payload.len) {
                        s.skip_early_data -= payload.len;
                        return;
                    }
                    return s.fail(.bad_record_mac, "record authentication failed");
                },
                error.SequenceExhausted => return s.fail(.internal_error, "record sequence exhausted"),
            };
            s.skip_early_data = 0;
            var end = plain.len;
            while (end > 0 and plain[end - 1] == 0) end -= 1;
            if (end == 0) return s.fail(.unexpected_message, "protected record without a content type");
            const inner_ct: ContentType = @enumFromInt(plain[end - 1]);
            const content = plain[0 .. end - 1];
            if (content.len > max_plaintext) return s.fail(.record_overflow, "record plaintext longer than the limit");
            return s.dispatch(inner_ct, content, true);
        }
        return s.dispatch(ct, payload, false);
    }

    fn dispatch(s: *Session, ct: ContentType, content: []const u8, protected: bool) (Fail || Allocator.Error)!void {
        switch (ct) {
            .alert => return s.receiveAlert(content),
            .handshake => {
                if (content.len == 0) return s.fail(.unexpected_message, "empty handshake record");
                try s.hs_buf.append(s.a, content);
                try s.processHandshakeMessages();
            },
            .application_data => {
                if (!protected) return s.fail(.unexpected_message, "unprotected application data");
                if (s.state != .connected) return s.fail(.unexpected_message, "application data before the handshake completed");
                if (s.hs_buf.items().len != 0) return s.fail(.unexpected_message, "application data inside a handshake message");
                if (s.peer_closed) return;
                try s.app.append(s.a, content);
            },
            else => return s.fail(.unexpected_message, "unknown record type"),
        }
    }

    fn receiveAlert(s: *Session, content: []const u8) Fail!void {
        if (content.len != 2) return s.fail(.decode_error, "malformed alert");
        if (s.hs_buf.items().len != 0) return s.fail(.unexpected_message, "alert inside a handshake message");
        const desc: AlertDescription = @enumFromInt(content[1]);
        switch (desc) {
            .close_notify => s.peer_closed = true,
            .user_canceled => {},
            else => {
                s.failure_info = .{ .alert = desc, .local = false, .reason = "the peer sent a fatal alert" };
                s.state = .failed;
                s.wipeSecrets();
            },
        }
    }

    fn processHandshakeMessages(s: *Session) (Fail || Allocator.Error)!void {
        while (s.state != .failed) {
            const buf = s.hs_buf.items();
            if (buf.len < 4) return;
            const len = std.mem.readInt(u24, buf[1..4], .big);
            if (len > max_handshake_message) return s.fail(.illegal_parameter, "handshake message too large");
            if (buf.len < 4 + len) return;
            const raw = try s.a.dupe(u8, buf[0 .. 4 + len]);
            defer s.a.free(raw);
            s.hs_buf.consume(4 + len);
            const ht: HandshakeType = @enumFromInt(raw[0]);
            switch (s.role) {
                .client => try s.clientMessage(ht, raw),
                .server => try s.serverMessage(ht, raw),
            }
        }
    }

    /// A message after which the peer's keys change must end its record.
    fn requireKeyBoundary(s: *Session) Fail!void {
        if (s.hs_buf.items().len != 0) return s.fail(.unexpected_message, "handshake data after a key change in the same record");
    }

    fn appendTranscript(s: *Session, raw: []const u8) Allocator.Error!void {
        try s.transcript.appendSlice(s.a, raw);
    }

    fn transcriptHash(s: *const Session) suites.Digest {
        return suites.hash(s.suite.?, s.transcript.items);
    }

    /// Replaces the first ClientHello in the transcript with its
    /// message_hash stand-in, as a HelloRetryRequest requires.
    fn collapseTranscript(s: *Session) Allocator.Error!void {
        const h = suites.hash(s.suite.?, s.transcript.items);
        s.transcript.clearRetainingCapacity();
        try s.transcript.appendSlice(s.a, &.{ @intFromEnum(HandshakeType.message_hash), 0, 0, h.len });
        try s.transcript.appendSlice(s.a, h.slice());
    }

    fn wvec(s: *Session, w: *wire.Writer, comptime Len: type, b: []const u8) (Fail || Allocator.Error)!void {
        w.vec(Len, b) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Overflow => s.fail(.internal_error, "message field too long"),
        };
    }

    fn wend(s: *Session, w: *wire.Writer, comptime Len: type, mark: usize) Fail!void {
        w.end(Len, mark) catch return s.fail(.internal_error, "message field too long");
    }

    fn sendHandshake(s: *Session, raw: []const u8) (Fail || Allocator.Error)!void {
        try s.appendTranscript(raw);
        try s.sendRecord(.handshake, raw);
    }

    fn randomBytes(s: *Session, buf: []u8) void {
        s.rng.fill(buf);
    }

    fn newShare(s: *Session, group: Group) (Fail || Allocator.Error)!KeyShare {
        const pinned = s.hooks();
        switch (group) {
            .x25519 => {
                if (pinned.x25519_secret) |sk| {
                    return .{ .x25519 = crypto.dh.X25519.KeyPair.generateDeterministic(sk) catch return s.fail(.internal_error, "bad pinned x25519 key") };
                }
                while (true) {
                    var seed: [32]u8 = undefined;
                    s.randomBytes(&seed);
                    const kp = crypto.dh.X25519.KeyPair.generateDeterministic(seed) catch continue;
                    return .{ .x25519 = kp };
                }
            },
            .secp256r1 => {
                const E = crypto.sign.ecdsa.EcdsaP256Sha256;
                if (pinned.p256_secret) |sk| {
                    const secret = E.SecretKey.fromBytes(sk) catch return s.fail(.internal_error, "bad pinned P-256 key");
                    return .{ .p256 = E.KeyPair.fromSecretKey(secret) catch return s.fail(.internal_error, "bad pinned P-256 key") };
                }
                while (true) {
                    var seed: [E.KeyPair.seed_length]u8 = undefined;
                    s.randomBytes(&seed);
                    const kp = E.KeyPair.generateDeterministic(seed) catch continue;
                    return .{ .p256 = kp };
                }
            },
            .secp384r1 => {
                const E = crypto.sign.ecdsa.EcdsaP384Sha384;
                while (true) {
                    var seed: [E.KeyPair.seed_length]u8 = undefined;
                    s.randomBytes(&seed);
                    const kp = E.KeyPair.generateDeterministic(seed) catch continue;
                    return .{ .p384 = kp };
                }
            },
            _ => return s.fail(.internal_error, "unsupported group"),
        }
    }

    fn hooks(s: *const Session) TestHooks {
        return if (s.client_config) |c| c.hooks else if (s.server_config) |c| c.hooks else .{};
    }

    fn installHandshakeKeys(s: *Session, shared: []const u8) Fail!void {
        const suite = s.suite.?;
        s.handshake_secret = suites.handshakeSecret(suite, shared);
        const h = s.transcriptHash();
        s.client_hs = suites.deriveSecret(suite, &s.handshake_secret, "c hs traffic", &h);
        s.server_hs = suites.deriveSecret(suite, &s.handshake_secret, "s hs traffic", &h);
        s.master_secret = suites.masterSecret(suite, &s.handshake_secret);
    }

    fn deriveApplicationSecrets(s: *Session) void {
        const suite = s.suite.?;
        const h = s.transcriptHash();
        s.client_ap = suites.deriveSecret(suite, &s.master_secret, "c ap traffic", &h);
        s.server_ap = suites.deriveSecret(suite, &s.master_secret, "s ap traffic", &h);
    }

    fn setRead(s: *Session, secret: Secret) void {
        if (s.read) |*c| c.wipe();
        s.read = .init(s.suite.?, secret);
    }

    fn setWrite(s: *Session, secret: Secret) void {
        if (s.write) |*c| c.wipe();
        s.write = .init(s.suite.?, secret);
    }

    fn finishHandshake(s: *Session) void {
        s.state = .connected;
        s.transcript.clearAndFree(s.a);
        s.wipeSecrets();
    }

    // ---- extensions -------------------------------------------------------

    const Extensions = struct {
        const max = 32;
        types: [max]u16 = undefined,
        data: [max][]const u8 = undefined,
        n: usize = 0,

        fn get(e: *const Extensions, t: u16) ?[]const u8 {
            for (e.types[0..e.n], e.data[0..e.n]) |x, d| if (x == t) return d;
            return null;
        }
    };

    /// Parses an extension block, refusing duplicates and a pre_shared_key
    /// that is not last.
    fn parseExtensions(s: *Session, block: []const u8) Fail!Extensions {
        var out: Extensions = .{};
        var r: wire.Reader = .init(block);
        while (!r.done()) {
            const t = r.int(u16) catch return s.decodeFail("truncated extension");
            const d = r.vec(u16) catch return s.decodeFail("truncated extension");
            for (out.types[0..out.n]) |x| if (x == t) return s.fail(.illegal_parameter, "duplicate extension");
            if (out.n == Extensions.max) return s.fail(.illegal_parameter, "too many extensions");
            out.types[out.n] = t;
            out.data[out.n] = d;
            out.n += 1;
        }
        if (out.get(ExtensionType.pre_shared_key) != null and out.types[out.n - 1] != ExtensionType.pre_shared_key)
            return s.fail(.illegal_parameter, "pre_shared_key is not the last extension");
        return out;
    }

    fn offered(s: *const Session, t: u16) bool {
        return std.mem.findScalar(u16, s.offered_extensions.items, t) != null;
    }

    fn recordOffered(s: *Session, block: []const u8) (Fail || Allocator.Error)!void {
        s.offered_extensions.clearRetainingCapacity();
        const exts = try s.parseExtensions(block);
        try s.offered_extensions.appendSlice(s.a, exts.types[0..exts.n]);
    }

    // ---- client -----------------------------------------------------------

    fn startClient(s: *Session) (Fail || Allocator.Error)!void {
        const cfg = s.client_config.?;
        if (cfg.verification == .trust and cfg.server_name == null)
            return s.fail(.internal_error, "certificate verification needs a server name");
        if (cfg.cipher_suites.len == 0 or cfg.key_share_groups.len == 0)
            return s.fail(.internal_error, "no cipher suites or key share groups");
        if (cfg.hooks.random) |r| s.random = r else s.randomBytes(&s.random);
        if (cfg.compat_mode) {
            s.session_id_len = 32;
            s.randomBytes(&s.session_id);
        }
        for (cfg.key_share_groups, 0..) |g, i| {
            if (i >= s.shares.len) break;
            s.shares[i] = try s.newShare(g);
        }
        try s.sendClientHello(cfg.hooks.client_hello_extensions);
    }

    fn sendClientHello(s: *Session, extension_override: ?[]const u8) (Fail || Allocator.Error)!void {
        const cfg = s.client_config.?;
        var w: wire.Writer = .init(s.a);
        defer w.deinit();
        try w.int(u8, @intFromEnum(HandshakeType.client_hello));
        const body = try w.begin(u24);
        try w.int(u16, 0x0303);
        try w.bytes(&s.random);
        try s.wvec(&w, u8, s.session_id[0..s.session_id_len]);
        const suites_mark = try w.begin(u16);
        for (cfg.cipher_suites) |cs| try w.int(u16, @intFromEnum(cs));
        try s.wend(&w, u16, suites_mark);
        try w.bytes(&.{ 1, 0 });
        const exts_start = w.list.items.len + 2;
        if (extension_override) |block| {
            try s.wvec(&w, u16, block);
        } else {
            const exts = try w.begin(u16);
            if (cfg.server_name) |name| {
                if (x509.parseIp(name) == null and name.len > 0 and name.len < 256) {
                    try w.int(u16, ExtensionType.server_name);
                    const ext = try w.begin(u16);
                    const list = try w.begin(u16);
                    try w.int(u8, 0);
                    try s.wvec(&w, u16, name);
                    try s.wend(&w, u16, list);
                    try s.wend(&w, u16, ext);
                }
            }
            try w.int(u16, ExtensionType.supported_groups);
            {
                const ext = try w.begin(u16);
                const list = try w.begin(u16);
                for (cfg.groups) |g| try w.int(u16, @intFromEnum(g));
                try s.wend(&w, u16, list);
                try s.wend(&w, u16, ext);
            }
            try w.int(u16, ExtensionType.key_share);
            {
                const ext = try w.begin(u16);
                const list = try w.begin(u16);
                for (&s.shares) |*maybe| {
                    const k = &(maybe.* orelse continue);
                    try w.int(u16, @intFromEnum(k.group()));
                    var buf: [97]u8 = undefined;
                    try s.wvec(&w, u16, k.publicBytes(&buf));
                }
                try s.wend(&w, u16, list);
                try s.wend(&w, u16, ext);
            }
            try w.int(u16, ExtensionType.supported_versions);
            try w.bytes(&.{ 0, 3, 2, 0x03, 0x04 });
            try w.int(u16, ExtensionType.signature_algorithms);
            {
                const ext = try w.begin(u16);
                const list = try w.begin(u16);
                for (cfg.signature_schemes) |sch| try w.int(u16, sch);
                try s.wend(&w, u16, list);
                try s.wend(&w, u16, ext);
            }
            if (s.cookie.items.len != 0) {
                try w.int(u16, ExtensionType.cookie);
                const ext = try w.begin(u16);
                try s.wvec(&w, u16, s.cookie.items);
                try s.wend(&w, u16, ext);
            }
            try s.wend(&w, u16, exts);
        }
        try s.wend(&w, u24, body);
        try s.recordOffered(w.list.items[exts_start..]);
        try s.sendHandshake(w.list.items);
    }

    fn clientMessage(s: *Session, ht: HandshakeType, raw: []const u8) (Fail || Allocator.Error)!void {
        const body = raw[4..];
        switch (s.state) {
            .wait_server_hello => {
                if (ht != .server_hello) return s.fail(.unexpected_message, "expected ServerHello");
                return s.clientServerHello(raw, body);
            },
            .wait_encrypted_extensions => {
                if (ht != .encrypted_extensions) return s.fail(.unexpected_message, "expected EncryptedExtensions");
                try s.clientEncryptedExtensions(body);
                try s.appendTranscript(raw);
                s.state = .wait_certificate_or_request;
            },
            .wait_certificate_or_request => switch (ht) {
                .certificate_request => {
                    try s.clientCertificateRequest(body);
                    try s.appendTranscript(raw);
                    s.state = .wait_certificate;
                },
                .certificate => {
                    try s.clientCertificate(body);
                    try s.appendTranscript(raw);
                    s.state = .wait_certificate_verify;
                },
                else => return s.fail(.unexpected_message, "expected Certificate"),
            },
            .wait_certificate => {
                if (ht != .certificate) return s.fail(.unexpected_message, "expected Certificate");
                try s.clientCertificate(body);
                try s.appendTranscript(raw);
                s.state = .wait_certificate_verify;
            },
            .wait_certificate_verify => {
                if (ht != .certificate_verify) return s.fail(.unexpected_message, "expected CertificateVerify");
                try s.clientCertificateVerify(body);
                try s.appendTranscript(raw);
                s.state = .wait_server_finished;
            },
            .wait_server_finished => {
                if (ht != .finished) return s.fail(.unexpected_message, "expected Finished");
                return s.clientServerFinished(raw, body);
            },
            .connected => return s.postHandshake(ht, body),
            // The server states never occur on a client.
            else => unreachable,
        }
    }

    fn clientServerHello(s: *Session, raw: []const u8, body: []const u8) (Fail || Allocator.Error)!void {
        const cfg = s.client_config.?;
        var r: wire.Reader = .init(body);
        const legacy_version = r.int(u16) catch return s.decodeFail("truncated ServerHello");
        const random = r.array(32) catch return s.decodeFail("truncated ServerHello");
        const session_id = r.vec(u8) catch return s.decodeFail("truncated ServerHello");
        const suite_wire = r.int(u16) catch return s.decodeFail("truncated ServerHello");
        const compression = r.int(u8) catch return s.decodeFail("truncated ServerHello");
        const ext_block = r.vec(u16) catch return s.decodeFail("truncated ServerHello");
        r.expectEnd() catch return s.decodeFail("trailing bytes in ServerHello");

        const exts = try s.parseExtensions(ext_block);
        const version = exts.get(ExtensionType.supported_versions) orelse
            return s.fail(.protocol_version, "the server does not speak TLS 1.3");
        if (version.len != 2 or std.mem.readInt(u16, version[0..2], .big) != tls13)
            return s.fail(.illegal_parameter, "the server selected a version that was not offered");
        if (legacy_version != 0x0303) return s.fail(.illegal_parameter, "ServerHello legacy_version is not 1.2");
        if (!std.mem.eql(u8, session_id, s.session_id[0..s.session_id_len]))
            return s.fail(.illegal_parameter, "ServerHello session id does not echo ours");
        if (compression != 0) return s.fail(.illegal_parameter, "ServerHello selected compression");
        const suite = Suite.fromWire(suite_wire) orelse return s.fail(.illegal_parameter, "the server selected an unknown cipher suite");
        if (std.mem.findScalar(Suite, cfg.cipher_suites, suite) == null)
            return s.fail(.illegal_parameter, "the server selected a cipher suite that was not offered");
        if (s.retry_suite) |rs| if (rs != suite) return s.fail(.illegal_parameter, "ServerHello changed the HelloRetryRequest's cipher suite");

        const is_retry = std.mem.eql(u8, random, &hello_retry_random);
        for (exts.types[0..exts.n]) |t| {
            const allowed = t == ExtensionType.supported_versions or t == ExtensionType.key_share or
                (is_retry and t == ExtensionType.cookie);
            if (!allowed) return s.fail(.unsupported_extension, "ServerHello carries an extension that was not offered");
            if (!s.offered(t) and t != ExtensionType.cookie) return s.fail(.unsupported_extension, "ServerHello carries an extension that was not offered");
        }

        if (is_retry) {
            if (s.retried) return s.fail(.unexpected_message, "a second HelloRetryRequest");
            s.retried = true;
            s.retry_suite = suite;
            s.suite = suite;
            var changed = false;
            var new_group: ?Group = null;
            if (exts.get(ExtensionType.key_share)) |ks| {
                if (ks.len != 2) return s.decodeFail("malformed HelloRetryRequest key_share");
                const g: Group = @enumFromInt(std.mem.readInt(u16, ks[0..2], .big));
                if (std.mem.findScalar(Group, cfg.groups, g) == null or !groupSupported(g))
                    return s.fail(.illegal_parameter, "HelloRetryRequest asks for a group that was not offered");
                for (&s.shares) |*k| if (k.*) |*ks2| if (ks2.group() == g)
                    return s.fail(.illegal_parameter, "HelloRetryRequest asks for a group already shared");
                new_group = g;
                changed = true;
            }
            if (exts.get(ExtensionType.cookie)) |c| {
                var cr: wire.Reader = .init(c);
                const cookie = cr.vec(u16) catch return s.decodeFail("malformed cookie");
                cr.expectEnd() catch return s.decodeFail("malformed cookie");
                if (cookie.len == 0) return s.decodeFail("empty cookie");
                s.cookie.clearRetainingCapacity();
                try s.cookie.appendSlice(s.a, cookie);
                changed = true;
            }
            if (!changed) return s.fail(.illegal_parameter, "HelloRetryRequest would not change the ClientHello");
            try s.collapseTranscript();
            try s.appendTranscript(raw);
            if (new_group) |g| {
                for (&s.shares) |*k| {
                    if (k.*) |*ks| crypto.secureZero(u8, std.mem.asBytes(ks));
                    k.* = null;
                }
                s.shares[0] = try s.newShare(g);
            }
            if (cfg.compat_mode) try s.sendChangeCipherSpec();
            try s.sendClientHello(cfg.hooks.retry_hello_extensions);
            return;
        }

        const ks = exts.get(ExtensionType.key_share) orelse return s.fail(.missing_extension, "ServerHello has no key_share");
        var kr: wire.Reader = .init(ks);
        const g: Group = @enumFromInt(kr.int(u16) catch return s.decodeFail("malformed key_share"));
        const peer = kr.vec(u16) catch return s.decodeFail("malformed key_share");
        kr.expectEnd() catch return s.decodeFail("malformed key_share");
        const share = for (&s.shares) |*k| {
            if (k.*) |*sh| if (sh.group() == g) break sh;
        } else return s.fail(.illegal_parameter, "the server's key share is for a group we did not share");
        var shared_buf: [48]u8 = undefined;
        const shared = share.exchange(peer, &shared_buf) orelse return s.fail(.illegal_parameter, "invalid key share");
        defer crypto.secureZero(u8, &shared_buf);

        s.suite = suite;
        try s.appendTranscript(raw);
        try s.installHandshakeKeys(shared);
        try s.requireKeyBoundary();
        s.setRead(s.server_hs);
        // Everything this side sends from here on, alerts included, is
        // protected with the client handshake keys.
        s.setWrite(s.client_hs);
        s.state = .wait_encrypted_extensions;
    }

    fn clientEncryptedExtensions(s: *Session, body: []const u8) Fail!void {
        var r: wire.Reader = .init(body);
        const block = r.vec(u16) catch return s.decodeFail("truncated EncryptedExtensions");
        r.expectEnd() catch return s.decodeFail("trailing bytes in EncryptedExtensions");
        const exts = try s.parseExtensions(block);
        for (exts.types[0..exts.n], exts.data[0..exts.n]) |t, d| {
            switch (t) {
                ExtensionType.server_name => if (d.len != 0) return s.decodeFail("non-empty server_name acknowledgement"),
                ExtensionType.supported_groups,
                ExtensionType.max_fragment_length,
                ExtensionType.use_srtp,
                ExtensionType.heartbeat,
                ExtensionType.alpn,
                ExtensionType.client_certificate_type,
                ExtensionType.server_certificate_type,
                ExtensionType.early_data,
                ExtensionType.record_size_limit,
                => {},
                ExtensionType.key_share,
                ExtensionType.supported_versions,
                ExtensionType.pre_shared_key,
                ExtensionType.cookie,
                ExtensionType.signature_algorithms,
                ExtensionType.psk_key_exchange_modes,
                => return s.fail(.illegal_parameter, "EncryptedExtensions carries a hello-only extension"),
                else => {},
            }
            if (t != ExtensionType.supported_groups and !s.offered(t))
                return s.fail(.unsupported_extension, "EncryptedExtensions carries an extension that was not offered");
        }
    }

    fn clientCertificateRequest(s: *Session, body: []const u8) (Fail || Allocator.Error)!void {
        var r: wire.Reader = .init(body);
        const context = r.vec(u8) catch return s.decodeFail("truncated CertificateRequest");
        const block = r.vec(u16) catch return s.decodeFail("truncated CertificateRequest");
        r.expectEnd() catch return s.decodeFail("trailing bytes in CertificateRequest");
        if (context.len != 0) return s.fail(.illegal_parameter, "CertificateRequest context during the handshake");
        const exts = try s.parseExtensions(block);
        if (exts.get(ExtensionType.signature_algorithms) == null)
            return s.fail(.missing_extension, "CertificateRequest has no signature_algorithms");
        s.client_auth_requested = true;
        s.certificate_request_context.clearRetainingCapacity();
    }

    fn clientCertificate(s: *Session, body: []const u8) (Fail || Allocator.Error)!void {
        const cfg = s.client_config.?;
        var r: wire.Reader = .init(body);
        const context = r.vec(u8) catch return s.decodeFail("truncated Certificate");
        if (context.len != 0) return s.fail(.illegal_parameter, "server Certificate has a request context");
        var list = r.sub(u24) catch return s.decodeFail("truncated Certificate");
        r.expectEnd() catch return s.decodeFail("trailing bytes in Certificate");
        var chain: [x509.max_chain_len][]const u8 = undefined;
        var n: usize = 0;
        while (!list.done()) {
            const der = list.vec(u24) catch return s.decodeFail("truncated certificate entry");
            const ext_block = list.vec(u16) catch return s.decodeFail("truncated certificate entry");
            if (der.len == 0) return s.decodeFail("empty certificate entry");
            _ = try s.parseExtensions(ext_block);
            if (n == chain.len) return s.fail(.bad_certificate, "certificate chain too long");
            chain[n] = der;
            n += 1;
        }
        if (n == 0) return s.decodeFail("the server sent no certificate");
        switch (cfg.verification) {
            .trust => |t| {
                var bundles: [2]*const Certificate.Bundle = undefined;
                var nb: usize = 0;
                for ([_]?*const Certificate.Bundle{ t.anchors, t.system_anchors }) |maybe| {
                    if (maybe) |b| {
                        bundles[nb] = b;
                        nb += 1;
                    }
                }
                try s.verifyServerChain(chain[0..n], bundles[0..nb], cfg.server_name.?, t.now_sec);
            },
            .insecure_accept_any => {},
        }
        const leaf = x509.parse(chain[0]) orelse return s.fail(.bad_certificate, "unparseable server certificate");
        if (s.peer_key) |*k| k.bytes.deinit(s.a);
        s.peer_key = .{ .algo = leaf.pub_key_algo };
        try s.peer_key.?.bytes.appendSlice(s.a, leaf.pubKey());
    }

    fn verifyServerChain(s: *Session, chain: []const []const u8, bundles: []const *const Certificate.Bundle, host: []const u8, now_sec: i64) Fail!void {
        x509.verifyChain(chain, bundles, host, now_sec) catch |e| return switch (e) {
            error.BadCertificate => s.fail(.bad_certificate, "the server certificate is not valid for this host"),
            error.UnsupportedCertificate => s.fail(.unsupported_certificate, "the server certificate uses an unsupported algorithm"),
            error.CertificateExpired => s.fail(.certificate_expired, "the server certificate has expired or is not yet valid"),
            error.UnknownCa => s.fail(.unknown_ca, "the server certificate is not issued by a trusted authority"),
        };
    }

    fn clientCertificateVerify(s: *Session, body: []const u8) Fail!void {
        const cfg = s.client_config.?;
        var r: wire.Reader = .init(body);
        const scheme = r.int(u16) catch return s.decodeFail("truncated CertificateVerify");
        const sig = r.vec(u16) catch return s.decodeFail("truncated CertificateVerify");
        r.expectEnd() catch return s.decodeFail("trailing bytes in CertificateVerify");
        if (std.mem.findScalar(u16, cfg.signature_schemes, scheme) == null)
            return s.fail(.illegal_parameter, "CertificateVerify uses a scheme that was not offered");
        // The Certificate before this message stored it.
        const key = &s.peer_key.?;
        const h = s.transcriptHash();
        var content_buf: [64 + 34 + suites.max_hash_len]u8 = undefined;
        const content = verifyContent(&content_buf, "TLS 1.3, server CertificateVerify", &h);
        verifySignature(scheme, key.algo, key.bytes.items, sig, content) catch |e| return switch (e) {
            error.SchemeMismatch => s.fail(.illegal_parameter, "CertificateVerify scheme does not match the certificate key"),
            error.BadSignature => s.fail(.decrypt_error, "CertificateVerify signature is invalid"),
        };
    }

    fn clientServerFinished(s: *Session, raw: []const u8, body: []const u8) (Fail || Allocator.Error)!void {
        const suite = s.suite.?;
        const h = s.transcriptHash();
        const expected = suites.finishedData(suite, &s.server_hs, &h);
        if (body.len != expected.len) return s.decodeFail("Finished has the wrong length");
        if (!suites.finishedMatches(&expected, body)) return s.fail(.decrypt_error, "server Finished does not verify");
        try s.appendTranscript(raw);
        try s.requireKeyBoundary();
        s.deriveApplicationSecrets();
        s.setRead(s.server_ap);

        if (s.client_auth_requested) {
            // No client certificate: an empty Certificate and no CertificateVerify.
            var w: wire.Writer = .init(s.a);
            defer w.deinit();
            try w.bytes(&.{ @intFromEnum(HandshakeType.certificate), 0, 0, 4, 0, 0, 0, 0 });
            try s.sendHandshake(w.list.items);
        }
        const fh = s.transcriptHash();
        const verify = suites.finishedData(suite, &s.client_hs, &fh);
        var msg: [4 + suites.max_hash_len]u8 = undefined;
        msg[0] = @intFromEnum(HandshakeType.finished);
        std.mem.writeInt(u24, msg[1..4], verify.len, .big);
        @memcpy(msg[4..][0..verify.len], verify.slice());
        try s.sendHandshake(msg[0 .. 4 + verify.len]);
        s.setWrite(s.client_ap);
        s.finishHandshake();
    }

    // ---- post-handshake ---------------------------------------------------

    fn postHandshake(s: *Session, ht: HandshakeType, body: []const u8) (Fail || Allocator.Error)!void {
        switch (ht) {
            .new_session_ticket => {
                if (s.role != .client) return s.fail(.unexpected_message, "NewSessionTicket from a client");
                var r: wire.Reader = .init(body);
                _ = r.int(u32) catch return s.decodeFail("truncated NewSessionTicket");
                _ = r.int(u32) catch return s.decodeFail("truncated NewSessionTicket");
                _ = r.vec(u8) catch return s.decodeFail("truncated NewSessionTicket");
                const ticket = r.vec(u16) catch return s.decodeFail("truncated NewSessionTicket");
                if (ticket.len == 0) return s.decodeFail("empty session ticket");
                const block = r.vec(u16) catch return s.decodeFail("truncated NewSessionTicket");
                r.expectEnd() catch return s.decodeFail("trailing bytes in NewSessionTicket");
                _ = try s.parseExtensions(block);
                // Resumption is not supported; the ticket is dropped.
            },
            .key_update => {
                if (body.len != 1) return s.decodeFail("malformed KeyUpdate");
                if (body[0] > 1) return s.fail(.illegal_parameter, "KeyUpdate request value is not 0 or 1");
                try s.requireKeyBoundary();
                rotate(&s.read);
                if (body[0] == 1 and !s.close_sent) {
                    try s.sendRecord(.handshake, &.{ @intFromEnum(HandshakeType.key_update), 0, 0, 1, 0 });
                    rotate(&s.write);
                }
            },
            else => return s.fail(.unexpected_message, "unexpected post-handshake message"),
        }
    }

    // ---- server -----------------------------------------------------------

    fn serverMessage(s: *Session, ht: HandshakeType, raw: []const u8) (Fail || Allocator.Error)!void {
        const body = raw[4..];
        switch (s.state) {
            .wait_client_hello, .wait_retry_client_hello => {
                if (ht != .client_hello) return s.fail(.unexpected_message, "expected ClientHello");
                return s.serverClientHello(raw, body);
            },
            .wait_client_finished => {
                if (ht != .finished) return s.fail(.unexpected_message, "expected Finished");
                const expected = s.expected_client_finished;
                if (body.len != expected.len) return s.decodeFail("Finished has the wrong length");
                if (!suites.finishedMatches(&expected, body)) return s.fail(.decrypt_error, "client Finished does not verify");
                try s.requireKeyBoundary();
                s.setRead(s.client_ap);
                s.finishHandshake();
            },
            .connected => return s.postHandshake(ht, body),
            // The client states never occur on a server.
            else => unreachable,
        }
    }

    const ClientHello = struct {
        random: *const [32]u8,
        session_id: []const u8,
        suites_list: []const u8,
        exts: Extensions,
    };

    fn parseClientHello(s: *Session, body: []const u8) Fail!ClientHello {
        var r: wire.Reader = .init(body);
        _ = r.int(u16) catch return s.decodeFail("truncated ClientHello");
        const random = r.array(32) catch return s.decodeFail("truncated ClientHello");
        const session_id = r.vec(u8) catch return s.decodeFail("truncated ClientHello");
        if (session_id.len > 32) return s.decodeFail("ClientHello session id longer than 32 bytes");
        const suites_list = r.vec(u16) catch return s.decodeFail("truncated ClientHello");
        if (suites_list.len == 0 or suites_list.len % 2 != 0) return s.decodeFail("malformed cipher suite list");
        const compression = r.vec(u8) catch return s.decodeFail("truncated ClientHello");
        if (compression.len != 1 or compression[0] != 0) return s.fail(.illegal_parameter, "ClientHello offers compression");
        if (r.done()) return s.fail(.protocol_version, "the client does not speak TLS 1.3");
        const block = r.vec(u16) catch return s.decodeFail("truncated ClientHello");
        r.expectEnd() catch return s.decodeFail("trailing bytes in ClientHello");
        const exts = try s.parseExtensions(block);
        const versions = exts.get(ExtensionType.supported_versions) orelse
            return s.fail(.protocol_version, "the client does not speak TLS 1.3");
        var vr: wire.Reader = .init(versions);
        var vl = vr.sub(u8) catch return s.decodeFail("malformed supported_versions");
        vr.expectEnd() catch return s.decodeFail("malformed supported_versions");
        if (vl.remaining() == 0 or vl.remaining() % 2 != 0) return s.decodeFail("malformed supported_versions");
        var has13 = false;
        while (!vl.done()) {
            if ((vl.int(u16) catch unreachable) == tls13) has13 = true;
        }
        if (!has13) return s.fail(.protocol_version, "the client does not speak TLS 1.3");
        return .{ .random = random, .session_id = session_id, .suites_list = suites_list, .exts = exts };
    }

    fn clientOffersSuite(list: []const u8, suite: Suite) bool {
        var i: usize = 0;
        while (i + 1 < list.len) : (i += 2) {
            if (std.mem.readInt(u16, list[i..][0..2], .big) == @intFromEnum(suite)) return true;
        }
        return false;
    }

    fn groupSupported(g: Group) bool {
        return g == .x25519 or g == .secp256r1 or g == .secp384r1;
    }

    fn serverClientHello(s: *Session, raw: []const u8, body: []const u8) (Fail || Allocator.Error)!void {
        const cfg = s.server_config.?;
        const ch = try s.parseClientHello(body);
        const exts = &ch.exts;

        // Groups the client supports and the shares it sent.
        const groups_ext = exts.get(ExtensionType.supported_groups);
        const shares_ext = exts.get(ExtensionType.key_share);
        if (groups_ext == null) return s.fail(.missing_extension, "ClientHello has no supported_groups");
        if (shares_ext == null) return s.fail(.missing_extension, "ClientHello has no key_share");
        var gr: wire.Reader = .init(groups_ext.?);
        var group_list = gr.sub(u16) catch return s.decodeFail("malformed supported_groups");
        gr.expectEnd() catch return s.decodeFail("malformed supported_groups");
        if (group_list.remaining() == 0 or group_list.remaining() % 2 != 0) return s.decodeFail("malformed supported_groups");
        const client_groups = group_list.buf;

        var kr: wire.Reader = .init(shares_ext.?);
        var share_list = kr.sub(u16) catch return s.decodeFail("malformed key_share");
        kr.expectEnd() catch return s.decodeFail("malformed key_share");
        const Share = struct { group: Group, key: []const u8 };
        var shares: [8]Share = undefined;
        var n_shares: usize = 0;
        while (!share_list.done()) {
            const g: Group = @enumFromInt(share_list.int(u16) catch return s.decodeFail("malformed key_share"));
            const key = share_list.vec(u16) catch return s.decodeFail("malformed key_share");
            if (key.len == 0) return s.decodeFail("empty key share");
            if (!listHasU16(client_groups, @intFromEnum(g))) return s.fail(.illegal_parameter, "key share for a group not in supported_groups");
            for (shares[0..n_shares]) |x| if (x.group == g) return s.fail(.illegal_parameter, "two key shares for one group");
            if (n_shares == shares.len) return s.fail(.illegal_parameter, "too many key shares");
            shares[n_shares] = .{ .group = g, .key = key };
            n_shares += 1;
        }

        if (s.state == .wait_retry_client_hello) {
            // The retried hello must answer the HelloRetryRequest.
            if (!std.mem.eql(u8, ch.session_id, s.session_id[0..s.session_id_len]))
                return s.fail(.illegal_parameter, "retried ClientHello changed its session id");
            if (!clientOffersSuite(ch.suites_list, s.suite.?))
                return s.fail(.illegal_parameter, "retried ClientHello dropped the selected cipher suite");
            if (n_shares != 1 or shares[0].group != s.selected_group.?)
                return s.fail(.illegal_parameter, "retried ClientHello does not share the requested group");
            if (s.cookie.items.len != 0) {
                const c = exts.get(ExtensionType.cookie) orelse return s.fail(.missing_extension, "retried ClientHello has no cookie");
                var cr: wire.Reader = .init(c);
                const echoed = cr.vec(u16) catch return s.decodeFail("malformed cookie");
                if (!std.mem.eql(u8, echoed, s.cookie.items)) return s.fail(.illegal_parameter, "retried ClientHello changed the cookie");
            }
            if (exts.get(ExtensionType.early_data) != null) return s.fail(.illegal_parameter, "retried ClientHello offers early data");
            return s.serverHello(raw, &ch, shares[0].key);
        }

        // Cipher suite: the server's preference.
        const suite = for (cfg.cipher_suites) |cs| {
            if (clientOffersSuite(ch.suites_list, cs)) break cs;
        } else return s.fail(.handshake_failure, "no cipher suite in common");

        // Signature scheme for our key.
        const sig_ext = exts.get(ExtensionType.signature_algorithms) orelse
            return s.fail(.missing_extension, "ClientHello has no signature_algorithms");
        var sr: wire.Reader = .init(sig_ext);
        var schemes = sr.sub(u16) catch return s.decodeFail("malformed signature_algorithms");
        sr.expectEnd() catch return s.decodeFail("malformed signature_algorithms");
        if (schemes.remaining() == 0 or schemes.remaining() % 2 != 0) return s.decodeFail("malformed signature_algorithms");
        const want: u16 = if (cfg.hooks.signature) |sig| sig.scheme else switch (cfg.identity.key) {
            .p256 => SignatureScheme.ecdsa_secp256r1_sha256,
            .ed25519 => SignatureScheme.ed25519,
        };
        if (!listHasU16(schemes.buf, want)) return s.fail(.handshake_failure, "the client does not accept our certificate's signature scheme");
        s.selected_scheme = want;

        // Group: a share the client sent in our preference order, else the
        // first group in common through a HelloRetryRequest.
        var chosen: ?Group = null;
        var chosen_key: ?[]const u8 = null;
        for (cfg.groups) |g| {
            if (!groupSupported(g) or !listHasU16(client_groups, @intFromEnum(g))) continue;
            const key = for (shares[0..n_shares]) |x| {
                if (x.group == g) break x.key;
            } else null;
            if (cfg.strict_group_preference) {
                chosen = g;
                chosen_key = key;
                break;
            }
            if (key != null) {
                chosen = g;
                chosen_key = key;
                break;
            }
            if (chosen == null) chosen = g;
        }
        const group = chosen orelse return s.fail(.handshake_failure, "no key exchange group in common");

        if (exts.get(ExtensionType.server_name)) |sn| try s.readServerName(sn);
        if (exts.get(ExtensionType.early_data) != null) s.skip_early_data = 1 << 16;
        s.suite = suite;
        s.selected_group = group;
        @memcpy(s.session_id[0..ch.session_id.len], ch.session_id);
        s.session_id_len = @intCast(ch.session_id.len);

        if (chosen_key == null) {
            // HelloRetryRequest.
            try s.appendTranscript(raw);
            try s.collapseTranscript();
            var w: wire.Writer = .init(s.a);
            defer w.deinit();
            try w.int(u8, @intFromEnum(HandshakeType.server_hello));
            const b = try w.begin(u24);
            try w.int(u16, 0x0303);
            try w.bytes(&hello_retry_random);
            try s.wvec(&w, u8, ch.session_id);
            try w.int(u16, @intFromEnum(suite));
            try w.int(u8, 0);
            if (cfg.hooks.hello_retry_extensions) |block| {
                try s.wvec(&w, u16, block);
                const hrr_exts = try s.parseExtensions(block);
                if (hrr_exts.get(ExtensionType.cookie)) |c| {
                    var cr: wire.Reader = .init(c);
                    const cookie = cr.vec(u16) catch return s.fail(.internal_error, "bad pinned cookie");
                    try s.cookie.appendSlice(s.a, cookie);
                }
            } else {
                const e = try w.begin(u16);
                try w.bytes(&.{ 0, 43, 0, 2, 0x03, 0x04 });
                try w.int(u16, ExtensionType.key_share);
                try w.int(u16, 2);
                try w.int(u16, @intFromEnum(group));
                try s.wend(&w, u16, e);
            }
            try s.wend(&w, u24, b);
            try s.sendHandshake(w.list.items);
            if (ch.session_id.len != 0) try s.sendChangeCipherSpec();
            s.state = .wait_retry_client_hello;
            return;
        }
        return s.serverHello(raw, &ch, chosen_key.?);
    }

    fn readServerName(s: *Session, ext: []const u8) (Fail || Allocator.Error)!void {
        var r: wire.Reader = .init(ext);
        var list = r.sub(u16) catch return s.decodeFail("malformed server_name");
        r.expectEnd() catch return s.decodeFail("malformed server_name");
        while (!list.done()) {
            const kind = list.int(u8) catch return s.decodeFail("malformed server_name");
            const name = list.vec(u16) catch return s.decodeFail("malformed server_name");
            if (kind == 0 and s.server_name.items.len == 0) try s.server_name.appendSlice(s.a, name);
        }
    }

    fn serverHello(s: *Session, raw: []const u8, ch: *const ClientHello, peer_share: []const u8) (Fail || Allocator.Error)!void {
        const cfg = s.server_config.?;
        const suite = s.suite.?;
        try s.appendTranscript(raw);
        if (cfg.hooks.random) |r| s.random = r else s.randomBytes(&s.random);
        const share = try s.newShare(s.selected_group.?);
        var shared_buf: [48]u8 = undefined;
        defer crypto.secureZero(u8, &shared_buf);
        const shared = share.exchange(peer_share, &shared_buf) orelse
            return s.fail(.illegal_parameter, "invalid key share");

        var w: wire.Writer = .init(s.a);
        defer w.deinit();
        try w.int(u8, @intFromEnum(HandshakeType.server_hello));
        const b = try w.begin(u24);
        try w.int(u16, 0x0303);
        try w.bytes(&s.random);
        try s.wvec(&w, u8, ch.session_id);
        try w.int(u16, @intFromEnum(suite));
        try w.int(u8, 0);
        const e = try w.begin(u16);
        try w.int(u16, ExtensionType.key_share);
        const ks = try w.begin(u16);
        try w.int(u16, @intFromEnum(share.group()));
        var pub_buf: [97]u8 = undefined;
        try s.wvec(&w, u16, share.publicBytes(&pub_buf));
        try s.wend(&w, u16, ks);
        try w.bytes(&.{ 0, 43, 0, 2, 0x03, 0x04 });
        try s.wend(&w, u16, e);
        try s.wend(&w, u24, b);
        try s.sendHandshake(w.list.items);
        if (ch.session_id.len != 0) try s.sendChangeCipherSpec();

        try s.installHandshakeKeys(shared);
        try s.requireKeyBoundary();
        s.setWrite(s.server_hs);
        s.setRead(s.client_hs);

        // EncryptedExtensions, Certificate, CertificateVerify and Finished go
        // out as one flight.
        var flight: wire.Writer = .init(s.a);
        defer flight.deinit();
        {
            var m: wire.Writer = .init(s.a);
            defer m.deinit();
            try m.int(u8, @intFromEnum(HandshakeType.encrypted_extensions));
            const mb = try m.begin(u24);
            if (cfg.hooks.encrypted_extensions) |block| {
                try s.wvec(&m, u16, block);
            } else {
                const me = try m.begin(u16);
                if (s.server_name.items.len != 0) try m.bytes(&.{ 0, 0, 0, 0 });
                try s.wend(&m, u16, me);
            }
            try s.wend(&m, u24, mb);
            try s.appendTranscript(m.list.items);
            try flight.bytes(m.list.items);
        }
        {
            var m: wire.Writer = .init(s.a);
            defer m.deinit();
            try m.int(u8, @intFromEnum(HandshakeType.certificate));
            const mb = try m.begin(u24);
            try m.int(u8, 0);
            const list = try m.begin(u24);
            for (cfg.identity.chain) |der| {
                try s.wvec(&m, u24, der);
                try m.int(u16, 0);
            }
            try s.wend(&m, u24, list);
            try s.wend(&m, u24, mb);
            try s.appendTranscript(m.list.items);
            try flight.bytes(m.list.items);
        }
        {
            const h = s.transcriptHash();
            var content_buf: [64 + 34 + suites.max_hash_len]u8 = undefined;
            const content = verifyContent(&content_buf, "TLS 1.3, server CertificateVerify", &h);
            var sig_buf: [512]u8 = undefined;
            const sig = try s.sign(content, &sig_buf);
            var m: wire.Writer = .init(s.a);
            defer m.deinit();
            try m.int(u8, @intFromEnum(HandshakeType.certificate_verify));
            const mb = try m.begin(u24);
            try m.int(u16, s.selected_scheme);
            try s.wvec(&m, u16, sig);
            try s.wend(&m, u24, mb);
            try s.appendTranscript(m.list.items);
            try flight.bytes(m.list.items);
        }
        {
            const h = s.transcriptHash();
            const verify = suites.finishedData(suite, &s.server_hs, &h);
            var msg: [4 + suites.max_hash_len]u8 = undefined;
            msg[0] = @intFromEnum(HandshakeType.finished);
            std.mem.writeInt(u24, msg[1..4], verify.len, .big);
            @memcpy(msg[4..][0..verify.len], verify.slice());
            try s.appendTranscript(msg[0 .. 4 + verify.len]);
            try flight.bytes(msg[0 .. 4 + verify.len]);
        }
        try s.sendRecord(.handshake, flight.list.items);
        s.deriveApplicationSecrets();
        s.setWrite(s.server_ap);
        // The client's Finished covers the transcript through ours.
        const h = s.transcriptHash();
        s.expected_client_finished = suites.finishedData(suite, &s.client_hs, &h);
        s.state = .wait_client_finished;
    }

    fn sign(s: *Session, content: []const u8, buf: []u8) Fail![]const u8 {
        const cfg = s.server_config.?;
        if (cfg.hooks.signature) |sig| {
            if (sig.bytes.len > buf.len) return s.fail(.internal_error, "pinned signature too long");
            @memcpy(buf[0..sig.bytes.len], sig.bytes);
            return buf[0..sig.bytes.len];
        }
        var noise: [32]u8 = undefined;
        s.randomBytes(&noise);
        switch (cfg.identity.key) {
            .p256 => |kp| {
                const E = crypto.sign.ecdsa.EcdsaP256Sha256;
                const signature = kp.sign(content, noise) catch return s.fail(.internal_error, "signing failed");
                var der_buf: [E.Signature.der_encoded_length_max]u8 = undefined;
                const der = signature.toDer(&der_buf);
                @memcpy(buf[0..der.len], der);
                return buf[0..der.len];
            },
            .ed25519 => |kp| {
                const signature = kp.sign(content, noise) catch return s.fail(.internal_error, "signing failed");
                const bytes = signature.toBytes();
                @memcpy(buf[0..bytes.len], &bytes);
                return buf[0..bytes.len];
            },
        }
    }
};

/// Replaces a direction's keys with the next generation and wipes the old.
fn rotate(c: *?Cipher) void {
    const next = c.*.?.updated();
    c.*.?.wipe();
    c.* = next;
}

fn listHasU16(list: []const u8, want: u16) bool {
    var i: usize = 0;
    while (i + 1 < list.len) : (i += 2) {
        if (std.mem.readInt(u16, list[i..][0..2], .big) == want) return true;
    }
    return false;
}

/// The signed content of a CertificateVerify: 64 spaces, the context string,
/// a zero byte and the transcript hash.
fn verifyContent(buf: []u8, context: []const u8, h: *const suites.Digest) []const u8 {
    @memset(buf[0..64], 0x20);
    @memcpy(buf[64..][0..context.len], context);
    buf[64 + context.len] = 0;
    const off = 64 + context.len + 1;
    @memcpy(buf[off..][0..h.len], h.slice());
    return buf[0 .. off + h.len];
}

const SignatureError = error{ SchemeMismatch, BadSignature };

/// Checks a CertificateVerify signature with the peer's leaf key.
fn verifySignature(scheme: u16, algo: Certificate.Parsed.PubKeyAlgo, key: []const u8, sig: []const u8, msg: []const u8) SignatureError!void {
    switch (scheme) {
        SignatureScheme.ecdsa_secp256r1_sha256 => {
            if (algo != .X9_62_id_ecPublicKey or algo.X9_62_id_ecPublicKey != .X9_62_prime256v1) return error.SchemeMismatch;
            const E = crypto.sign.ecdsa.EcdsaP256Sha256;
            const s = E.Signature.fromDer(sig) catch return error.BadSignature;
            const pk = E.PublicKey.fromSec1(key) catch return error.BadSignature;
            s.verify(msg, pk) catch return error.BadSignature;
        },
        SignatureScheme.ecdsa_secp384r1_sha384 => {
            if (algo != .X9_62_id_ecPublicKey or algo.X9_62_id_ecPublicKey != .secp384r1) return error.SchemeMismatch;
            const E = crypto.sign.ecdsa.EcdsaP384Sha384;
            const s = E.Signature.fromDer(sig) catch return error.BadSignature;
            const pk = E.PublicKey.fromSec1(key) catch return error.BadSignature;
            s.verify(msg, pk) catch return error.BadSignature;
        },
        SignatureScheme.ed25519 => {
            if (algo != .curveEd25519) return error.SchemeMismatch;
            const E = crypto.sign.Ed25519;
            if (sig.len != E.Signature.encoded_length or key.len != E.PublicKey.encoded_length) return error.BadSignature;
            const s = E.Signature.fromBytes(sig[0..E.Signature.encoded_length].*);
            const pk = E.PublicKey.fromBytes(key[0..E.PublicKey.encoded_length].*) catch return error.BadSignature;
            s.verify(msg, pk) catch return error.BadSignature;
        },
        SignatureScheme.rsa_pss_rsae_sha256,
        SignatureScheme.rsa_pss_rsae_sha384,
        SignatureScheme.rsa_pss_rsae_sha512,
        => {
            if (algo != .rsaEncryption) return error.SchemeMismatch;
            try verifyPss(scheme, key, sig, msg);
        },
        SignatureScheme.rsa_pss_pss_sha256,
        SignatureScheme.rsa_pss_pss_sha384,
        SignatureScheme.rsa_pss_pss_sha512,
        => {
            if (algo != .rsassa_pss) return error.SchemeMismatch;
            try verifyPss(scheme, key, sig, msg);
        },
        // PKCS#1 v1.5 signatures are for certificates only in TLS 1.3.
        else => return error.SchemeMismatch,
    }
}

fn verifyPss(scheme: u16, key: []const u8, sig: []const u8, msg: []const u8) SignatureError!void {
    const rsa = Certificate.rsa;
    if (!rsaKeyShape(key)) return error.BadSignature;
    const parts = rsa.PublicKey.parseDer(key) catch return error.BadSignature;
    switch (parts.modulus.len) {
        inline 128, 256, 384, 512 => |n| {
            if (sig.len != n) return error.BadSignature;
            const pk = rsa.PublicKey.fromBytes(parts.exponent, parts.modulus) catch return error.BadSignature;
            const s = rsa.PSSSignature.fromBytes(n, sig);
            switch (scheme) {
                SignatureScheme.rsa_pss_rsae_sha256, SignatureScheme.rsa_pss_pss_sha256 => rsa.PSSSignature.verify(n, s, msg, pk, crypto.hash.sha2.Sha256) catch return error.BadSignature,
                SignatureScheme.rsa_pss_rsae_sha384, SignatureScheme.rsa_pss_pss_sha384 => rsa.PSSSignature.verify(n, s, msg, pk, crypto.hash.sha2.Sha384) catch return error.BadSignature,
                else => rsa.PSSSignature.verify(n, s, msg, pk, crypto.hash.sha2.Sha512) catch return error.BadSignature,
            }
        },
        else => return error.BadSignature,
    }
}

/// An RSAPublicKey whose two integers lie inside `key`, the layout std's
/// `parseDer` reads without checking.
fn rsaKeyShape(key: []const u8) bool {
    var r: wire.Reader = .init(key);
    const Hdr = struct {
        fn read(rd: *wire.Reader, tag: u8) ?[]const u8 {
            const t = rd.int(u8) catch return null;
            if (t != tag) return null;
            const first = rd.int(u8) catch return null;
            var len: usize = first;
            if (first & 0x80 != 0) {
                const n = first & 0x7f;
                if (n == 0 or n > 4) return null;
                len = 0;
                for (0..n) |_| len = (len << 8) | (rd.int(u8) catch return null);
            }
            return rd.bytes(len) catch null;
        }
    };
    const seq = Hdr.read(&r, 0x30) orelse return false;
    var inner: wire.Reader = .init(seq);
    _ = Hdr.read(&inner, 0x02) orelse return false;
    _ = Hdr.read(&inner, 0x02) orelse return false;
    return true;
}
