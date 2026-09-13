//! Mach-O ad-hoc code signing for `klio bundle`, thin 64-bit little-endian only. An
//! overlay appended past the linker's signature makes a binary the arm64 kernel refuses
//! and cannot re-sign, so the bundle strips the stub's signature, appends the payload
//! plus the 72-byte trailer in its place, extends `__LINKEDIT` over them, and writes a
//! fresh ad-hoc SHA-256 `CodeDirectory` over the whole image. The trailer therefore sits
//! at `LC_CODE_SIGNATURE.dataoff - 72`, where the boot probe reads it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MH_MAGIC_64: u32 = 0xfeedfacf;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;

// Code-signing blob magics and constants (all blob fields are big-endian).
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade0cc0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade0c02;
const CSSLOT_CODEDIRECTORY: u32 = 0;
const CS_ADHOC: u32 = 0x0000_0002;
const CS_LINKER_SIGNED: u32 = 0x0002_0000;
const CS_HASHTYPE_SHA256: u8 = 2;
const CS_EXECSEG_MAIN_BINARY: u64 = 0x1;
/// CodeDirectory version carrying the exec-segment fields, required on arm64.
const CD_VERSION: u32 = 0x2_0400;
/// CodeDirectory header length for `CD_VERSION`: through execSegFlags, before the identifier.
const CD_HEADER_LEN: u32 = 88;
/// Code pages hash at 4 KiB (pageSize = log2(4096) = 12).
const CS_PAGE: u64 = 4096;
const PAGE_LOG2: u8 = 12;
const HASH_LEN: u32 = 32;

/// Mirrors `pack.bundle_format.TRAILER_LEN`, duplicated to avoid the import.
pub const TRAILER_LEN: u64 = 72;

/// Load-command offsets are absolute file offsets, unchanged by stripping the signature.
pub const MachoInfo = struct {
    /// `__TEXT` file range, published as the CodeDirectory exec segment.
    text_fileoff: u64,
    text_filesize: u64,
    /// `__LINKEDIT` segment command offset and its file start.
    linkedit_cmd_off: usize,
    linkedit_fileoff: u64,
    /// `LC_CODE_SIGNATURE` command offset and the current signature region.
    codesig_cmd_off: usize,
    codesig_dataoff: u64,
    codesig_datasize: u64,
};

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn readU64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// `bytes` must cover the mach header plus all load commands. Null unless the input is
/// a thin `MH_MAGIC_64` image with an `LC_CODE_SIGNATURE`.
pub fn parse(bytes: []const u8) ?MachoInfo {
    if (bytes.len < 32) return null;
    if (readU32(bytes, 0) != MH_MAGIC_64) return null;
    const ncmds = readU32(bytes, 16);
    const sizeofcmds = readU32(bytes, 20);
    var info: MachoInfo = .{
        .text_fileoff = 0,
        .text_filesize = 0,
        .linkedit_cmd_off = 0,
        .linkedit_fileoff = 0,
        .codesig_cmd_off = 0,
        .codesig_dataoff = 0,
        .codesig_datasize = 0,
    };
    const cmds_end: usize = 32 + @as(usize, sizeofcmds);
    if (cmds_end > bytes.len) return null;
    var off: usize = 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (off + 8 > cmds_end) return null;
        const cmd = readU32(bytes, off);
        const cmdsize = readU32(bytes, off + 4);
        if (cmdsize < 8 or off + cmdsize > cmds_end) return null;
        if (cmd == LC_SEGMENT_64) {
            if (cmdsize < 72) return null;
            const name = std.mem.sliceTo(bytes[off + 8 ..][0..16], 0);
            if (std.mem.eql(u8, name, "__TEXT")) {
                info.text_fileoff = readU64(bytes, off + 40);
                info.text_filesize = readU64(bytes, off + 48);
            } else if (std.mem.eql(u8, name, "__LINKEDIT")) {
                info.linkedit_cmd_off = off;
                info.linkedit_fileoff = readU64(bytes, off + 40);
            }
        } else if (cmd == LC_CODE_SIGNATURE) {
            if (cmdsize < 16) return null;
            info.codesig_cmd_off = off;
            info.codesig_dataoff = readU32(bytes, off + 8);
            info.codesig_datasize = readU32(bytes, off + 12);
        }
        off += cmdsize;
    }
    if (info.codesig_cmd_off == 0 or info.linkedit_cmd_off == 0) return null;
    return info;
}

/// `LC_CODE_SIGNATURE.dataoff - 72`; null for a non-signable Mach-O, which the caller probes at EOF-72.
pub fn trailerOffset(bytes: []const u8) ?u64 {
    const info = parse(bytes) orelse return null;
    if (info.codesig_dataoff < TRAILER_LEN) return null;
    return info.codesig_dataoff - TRAILER_LEN;
}

/// Signature size, so `__LINKEDIT` and `LC_CODE_SIGNATURE` lay out before the hashes exist.
fn signatureLen(code_limit: u64, identifier: []const u8) u32 {
    const n_code_slots: u32 = @intCast((code_limit + CS_PAGE - 1) / CS_PAGE);
    const ident_z_len: u32 = @intCast(identifier.len + 1);
    const cd_len: u32 = CD_HEADER_LEN + ident_z_len + n_code_slots * HASH_LEN;
    return 12 + 8 + cd_len; // SuperBlob header(12) + one BlobIndex(8) + CD
}

/// `image` is the stripped stub plus the aligned payload and the 72-byte trailer,
/// everything the signature covers; its length becomes the CodeDirectory `codeLimit`.
pub fn sign(gpa: Allocator, image: []const u8, info: MachoInfo, identifier: []const u8) Allocator.Error![]u8 {
    const code_limit: u64 = image.len;
    const sig_len = signatureLen(code_limit, identifier);
    const sig_dataoff = code_limit; // trailer ends here, so the probe reads dataoff-72
    const total: usize = @intCast(code_limit + sig_len);

    var out = try gpa.alloc(u8, total);
    @memcpy(out[0..image.len], image);
    @memset(out[image.len..], 0);

    std.mem.writeInt(u32, out[info.codesig_cmd_off + 8 ..][0..4], @intCast(sig_dataoff), .little);
    std.mem.writeInt(u32, out[info.codesig_cmd_off + 12 ..][0..4], sig_len, .little);
    const le_filesize = sig_dataoff + sig_len - info.linkedit_fileoff;
    std.mem.writeInt(u64, out[info.linkedit_cmd_off + 48 ..][0..8], le_filesize, .little);
    std.mem.writeInt(u64, out[info.linkedit_cmd_off + 32 ..][0..8], std.mem.alignForward(u64, le_filesize, 16384), .little);

    writeSignature(out, sig_dataoff, code_limit, info, identifier);
    return out;
}

/// Writes the embedded-signature SuperBlob (one CodeDirectory) at `sig_off`, hashing
/// `out[0..code_limit]` per page. `out[sig_off..]` must be zeroed and large enough.
fn writeSignature(out: []u8, sig_off: u64, code_limit: u64, info: MachoInfo, identifier: []const u8) void {
    const n_code_slots: u32 = @intCast((code_limit + CS_PAGE - 1) / CS_PAGE);
    const ident_z_len: u32 = @intCast(identifier.len + 1);
    const cd_len: u32 = CD_HEADER_LEN + ident_z_len + n_code_slots * HASH_LEN;
    const super_len: u32 = 12 + 8 + cd_len;

    const sb = out[@intCast(sig_off)..];
    // SuperBlob header + one index pointing at the CodeDirectory.
    std.mem.writeInt(u32, sb[0..4], CSMAGIC_EMBEDDED_SIGNATURE, .big);
    std.mem.writeInt(u32, sb[4..8], super_len, .big);
    std.mem.writeInt(u32, sb[8..12], 1, .big);
    std.mem.writeInt(u32, sb[12..16], CSSLOT_CODEDIRECTORY, .big);
    std.mem.writeInt(u32, sb[16..20], 20, .big);

    // CodeDirectory (version 0x20400).
    const cd = sb[20..];
    const hash_offset: u32 = CD_HEADER_LEN + ident_z_len;
    std.mem.writeInt(u32, cd[0..4], CSMAGIC_CODEDIRECTORY, .big);
    std.mem.writeInt(u32, cd[4..8], cd_len, .big);
    std.mem.writeInt(u32, cd[8..12], CD_VERSION, .big);
    std.mem.writeInt(u32, cd[12..16], CS_ADHOC | CS_LINKER_SIGNED, .big);
    std.mem.writeInt(u32, cd[16..20], hash_offset, .big);
    std.mem.writeInt(u32, cd[20..24], CD_HEADER_LEN, .big); // identOffset
    std.mem.writeInt(u32, cd[24..28], 0, .big); // nSpecialSlots
    std.mem.writeInt(u32, cd[28..32], n_code_slots, .big);
    std.mem.writeInt(u32, cd[32..36], @intCast(code_limit), .big); // codeLimit (< 4 GiB)
    cd[36] = @intCast(HASH_LEN);
    cd[37] = CS_HASHTYPE_SHA256;
    cd[38] = 0; // platform
    cd[39] = PAGE_LOG2;
    std.mem.writeInt(u32, cd[40..44], 0, .big); // spare2
    std.mem.writeInt(u32, cd[44..48], 0, .big); // scatterOffset
    std.mem.writeInt(u32, cd[48..52], 0, .big); // teamOffset
    std.mem.writeInt(u32, cd[52..56], 0, .big); // spare3
    std.mem.writeInt(u64, cd[56..64], 0, .big); // codeLimit64 (unused < 4 GiB)
    std.mem.writeInt(u64, cd[64..72], info.text_fileoff, .big); // execSegBase
    std.mem.writeInt(u64, cd[72..80], info.text_filesize, .big); // execSegLimit
    std.mem.writeInt(u64, cd[80..88], CS_EXECSEG_MAIN_BINARY, .big); // execSegFlags
    @memcpy(cd[CD_HEADER_LEN..][0..identifier.len], identifier);
    cd[CD_HEADER_LEN + identifier.len] = 0;

    var slot: u32 = 0;
    while (slot < n_code_slots) : (slot += 1) {
        const start: usize = @intCast(@as(u64, slot) * CS_PAGE);
        const end: usize = @intCast(@min(@as(u64, slot + 1) * CS_PAGE, code_limit));
        var h: [HASH_LEN]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out[start..end], &h, .{});
        @memcpy(cd[hash_offset + slot * HASH_LEN ..][0..HASH_LEN], &h);
    }
}

fn synthMacho(gpa: Allocator) ![]u8 {
    const ncmds: u32 = 3;
    const seg = 72; // segment_command_64 size
    const sig_cmd = 16; // linkedit_data_command size
    const sizeofcmds: u32 = seg + seg + sig_cmd;
    const text_size: u64 = 4096;
    const le_off: u64 = 4096;
    const le_size: u64 = 256;
    const sig_off: u64 = le_off + 128;
    const sig_size: u64 = 128;
    const file_len: usize = @intCast(sig_off + sig_size);
    var b = try gpa.alloc(u8, file_len);
    @memset(b, 0);
    std.mem.writeInt(u32, b[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, b[16..20], ncmds, .little);
    std.mem.writeInt(u32, b[20..24], sizeofcmds, .little);
    var off: usize = 32;
    std.mem.writeInt(u32, b[off..][0..4], LC_SEGMENT_64, .little);
    std.mem.writeInt(u32, b[off + 4 ..][0..4], seg, .little);
    @memcpy(b[off + 8 ..][0..6], "__TEXT");
    std.mem.writeInt(u64, b[off + 40 ..][0..8], 0, .little); // fileoff
    std.mem.writeInt(u64, b[off + 48 ..][0..8], text_size, .little); // filesize
    off += seg;
    std.mem.writeInt(u32, b[off..][0..4], LC_SEGMENT_64, .little);
    std.mem.writeInt(u32, b[off + 4 ..][0..4], seg, .little);
    @memcpy(b[off + 8 ..][0..10], "__LINKEDIT");
    std.mem.writeInt(u64, b[off + 40 ..][0..8], le_off, .little); // fileoff
    std.mem.writeInt(u64, b[off + 48 ..][0..8], le_size, .little); // filesize
    off += seg;
    std.mem.writeInt(u32, b[off..][0..4], LC_CODE_SIGNATURE, .little);
    std.mem.writeInt(u32, b[off + 4 ..][0..4], sig_cmd, .little);
    std.mem.writeInt(u32, b[off + 8 ..][0..4], @intCast(sig_off), .little);
    std.mem.writeInt(u32, b[off + 12 ..][0..4], @intCast(sig_size), .little);
    return b;
}

test "parse locates the code signature and linkedit" {
    const gpa = std.testing.allocator;
    const b = try synthMacho(gpa);
    defer gpa.free(b);
    const info = parse(b).?;
    try std.testing.expectEqual(@as(u64, 0), info.text_fileoff);
    try std.testing.expectEqual(@as(u64, 4096), info.text_filesize);
    try std.testing.expectEqual(@as(u64, 4096), info.linkedit_fileoff);
    try std.testing.expectEqual(@as(u64, 4096 + 128), info.codesig_dataoff);
    try std.testing.expectEqual(@as(u64, 128), info.codesig_datasize);
    try std.testing.expect(parse("not a macho at all!!") == null);
    try std.testing.expect(parse(b[0..16]) == null);
}

test "sign strips, re-signs, and places the trailer at dataoff-72" {
    const gpa = std.testing.allocator;
    const stub = try synthMacho(gpa);
    defer gpa.free(stub);
    const info = parse(stub).?;

    const core_len: usize = @intCast(info.codesig_dataoff);
    const payload_off = std.mem.alignForward(u64, core_len, 16384);
    const payload_n: usize = 5000;
    const image_len: usize = @intCast(payload_off + payload_n + TRAILER_LEN);
    var image = try gpa.alloc(u8, image_len);
    defer gpa.free(image);
    @memset(image, 0);
    @memcpy(image[0..core_len], stub[0..core_len]);
    const trailer_start = image_len - @as(usize, @intCast(TRAILER_LEN));
    @memcpy(image[trailer_start..][0..8], "KBND\x00KL1");

    const signed = try sign(gpa, image, info, "myapp");
    defer gpa.free(signed);

    const signed_info = parse(signed).?;
    try std.testing.expectEqual(@as(u64, image_len), signed_info.codesig_dataoff);
    const off = trailerOffset(signed).?;
    try std.testing.expectEqual(@as(u64, image_len - TRAILER_LEN), off);
    try std.testing.expectEqualSlices(u8, "KBND\x00KL1", signed[@intCast(off)..][0..8]);

    const sb = signed[image_len..];
    try std.testing.expectEqual(CSMAGIC_EMBEDDED_SIGNATURE, std.mem.readInt(u32, sb[0..4], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, sb[8..12], .big));
    const cd = sb[20..];
    try std.testing.expectEqual(CSMAGIC_CODEDIRECTORY, std.mem.readInt(u32, cd[0..4], .big));
    const code_limit: u64 = image_len;
    const n_slots = std.mem.readInt(u32, cd[28..32], .big);
    try std.testing.expectEqual(@as(u32, @intCast((code_limit + CS_PAGE - 1) / CS_PAGE)), n_slots);
    try std.testing.expectEqual(@as(u32, @intCast(code_limit)), std.mem.readInt(u32, cd[32..36], .big));
    const hash_offset = std.mem.readInt(u32, cd[16..20], .big);
    var slot: u32 = 0;
    while (slot < n_slots) : (slot += 1) {
        const start: usize = @intCast(@as(u64, slot) * CS_PAGE);
        const end: usize = @intCast(@min(@as(u64, slot + 1) * CS_PAGE, code_limit));
        var h: [HASH_LEN]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(signed[start..end], &h, .{});
        try std.testing.expectEqualSlices(u8, &h, cd[hash_offset + slot * HASH_LEN ..][0..HASH_LEN]);
    }
}

test "trailerOffset returns null for a non-signable image" {
    try std.testing.expect(trailerOffset("plain bytes, no mach header here") == null);
}
