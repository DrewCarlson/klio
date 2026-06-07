//! Thin binding over the system zstd library. Only the entry points the
//! pack format needs are declared; the C header is not required because
//! the symbols are linked directly from `libzstd`.
//!
//! `dst`/`uncompressed_len` capacities come from the pack directory, so
//! the decoder never has to trust the frame's embedded content size.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn ZSTD_compressBound(srcSize: usize) usize;
extern fn ZSTD_compress(
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    srcSize: usize,
    compressionLevel: c_int,
) usize;
extern fn ZSTD_decompress(
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    srcSize: usize,
) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;

extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_freeCCtx(cctx: ?*anyopaque) usize;
extern fn ZSTD_createDCtx() ?*anyopaque;
extern fn ZSTD_freeDCtx(dctx: ?*anyopaque) usize;
extern fn ZSTD_compress_usingDict(
    ctx: ?*anyopaque,
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    srcSize: usize,
    dict: [*]const u8,
    dictSize: usize,
    compressionLevel: c_int,
) usize;
extern fn ZSTD_decompress_usingDict(
    dctx: ?*anyopaque,
    dst: [*]u8,
    dstCapacity: usize,
    src: [*]const u8,
    srcSize: usize,
    dict: [*]const u8,
    dictSize: usize,
) usize;

/// Errors surfaced from the zstd codec. `message` borrows zstd's static
/// error-name table, so it stays valid for the process lifetime.
pub const ZstdError = error{ OutOfMemory, ZstdFailed };

/// The most recent zstd error name. Set whenever a codec call returns
/// `error.ZstdFailed`; callers read it to build a `PackError.Compression`.
pub threadlocal var last_error: []const u8 = "unknown zstd error";

fn checkError(code: usize) ZstdError!usize {
    if (ZSTD_isError(code) != 0) {
        last_error = std.mem.span(ZSTD_getErrorName(code));
        return error.ZstdFailed;
    }
    return code;
}

/// Compress `src` and return a freshly allocated buffer holding the zstd
/// frame. The caller owns the result.
pub fn compress(allocator: Allocator, src: []const u8, level: i32) ZstdError![]u8 {
    const bound = ZSTD_compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);
    const written = try checkError(ZSTD_compress(
        dst.ptr,
        dst.len,
        src.ptr,
        src.len,
        @intCast(level),
    ));
    return try allocator.realloc(dst, written);
}

/// Decompress `src` into a buffer of exactly `uncompressed_len` bytes
/// (the size recorded in the pack directory). Fails if the frame expands
/// to a different length.
pub fn decompress(allocator: Allocator, src: []const u8, uncompressed_len: usize) ZstdError![]u8 {
    const dst = try allocator.alloc(u8, uncompressed_len);
    errdefer allocator.free(dst);
    const written = try checkError(ZSTD_decompress(dst.ptr, dst.len, src.ptr, src.len));
    if (written != uncompressed_len) {
        last_error = "decompressed length does not match the pack directory";
        return error.ZstdFailed;
    }
    return dst;
}

/// Compress `src` against `dict`. The caller owns the returned frame.
pub fn compressDict(allocator: Allocator, src: []const u8, dict: []const u8, level: i32) ZstdError![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeCCtx(cctx);
    const bound = ZSTD_compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);
    const written = try checkError(ZSTD_compress_usingDict(
        cctx,
        dst.ptr,
        dst.len,
        src.ptr,
        src.len,
        dict.ptr,
        dict.len,
        @intCast(level),
    ));
    return try allocator.realloc(dst, written);
}

/// Decompress `src` against `dict` into exactly `uncompressed_len` bytes.
pub fn decompressDict(
    allocator: Allocator,
    src: []const u8,
    dict: []const u8,
    uncompressed_len: usize,
) ZstdError![]u8 {
    const dctx = ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeDCtx(dctx);
    const dst = try allocator.alloc(u8, uncompressed_len);
    errdefer allocator.free(dst);
    const written = try checkError(ZSTD_decompress_usingDict(
        dctx,
        dst.ptr,
        dst.len,
        src.ptr,
        src.len,
        dict.ptr,
        dict.len,
    ));
    if (written != uncompressed_len) {
        last_error = "decompressed length does not match the pack directory";
        return error.ZstdFailed;
    }
    return dst;
}

test "round trips bytes through the system zstd" {
    const a = std.testing.allocator;
    const src = "klio pack zstd round trip " ** 16;
    const packed_bytes = try compress(a, src, 3);
    defer a.free(packed_bytes);
    try std.testing.expect(packed_bytes.len < src.len);
    const back = try decompress(a, packed_bytes, src.len);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, src, back);
}

test "round trips against a dictionary" {
    const a = std.testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog " ** 4;
    const src = "the quick brown fox is fast and the lazy dog is slow " ** 4;
    const packed_bytes = try compressDict(a, src, dict, 3);
    defer a.free(packed_bytes);
    const back = try decompressDict(a, packed_bytes, dict, src.len);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, src, back);
}
