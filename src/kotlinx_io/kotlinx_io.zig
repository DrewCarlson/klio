//! Native bindings for `kotlinx.io`.
//!
//! `Buffer`, `Source`, `Sink`, and `ByteString` are implemented as
//! real common-side Kotlin in the pack's `shim/` source — no native
//! state, no method-body overrides. The only `actual`s the host
//! supplies are the platform-optimised base64 / hex codecs, declared
//! `expect fun` on the Kotlin side. This keeps the pack faithful to
//! upstream's "common code + thin platform actuals" structure.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const PrimitiveArrayKind = runtime.PrimitiveArrayKind;
const HostBindings = stdlib.HostBindings;

/// `actual` implementations of the `expect` codec extensions plus the
/// `kotlinx.io.files` filesystem primitives.
pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    var b = HostBindings.init(allocator);
    // `actual` implementations of the `expect` codec extensions.
    try b.register("kotlinx.io.encodeBase64", base64Encode);
    try b.register("kotlinx.io.decodeBase64", base64Decode);
    try b.register("kotlinx.io.encodeHex", hexEncode);
    try b.register("kotlinx.io.decodeHex", hexDecode);
    // `kotlinx.io.files` filesystem primitives. The Kotlin actuals
    // (klioMain/kotlinx/io/files/Actuals.kt) own the policy/exception
    // logic; these are thin `std::fs` I/O primitives.
    try b.register("kotlinx.io.files.__kxio_readAllBytes", fsReadAllBytes);
    try b.register("kotlinx.io.files.__kxio_writeBytes", fsWriteBytes);
    try b.register("kotlinx.io.files.__kxio_exists", fsExists);
    try b.register("kotlinx.io.files.__kxio_delete", fsDelete);
    try b.register("kotlinx.io.files.__kxio_createDirectories", fsCreateDirectories);
    try b.register("kotlinx.io.files.__kxio_atomicMove", fsAtomicMove);
    try b.register("kotlinx.io.files.__kxio_metadata", fsMetadata);
    try b.register("kotlinx.io.files.__kxio_resolve", fsResolve);
    try b.register("kotlinx.io.files.__kxio_list", fsList);
    try b.register("kotlinx.io.files.__kxio_tempDir", fsTempDir);
    return b;
}

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// `Result<T, RuntimeError>` returned by the argument decoders. OOM stays
/// a Zig error; a `RuntimeError` surfaces as data.
fn ArgResult(comptime T: type) type {
    return union(enum) { val: T, err: EvalResult };
}

fn typeErr(ctx: *CallCtx, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, fmt, args);
    return .{ .err = .{ .Type = msg } };
}

fn argBool(ctx: *CallCtx, idx: usize) std.mem.Allocator.Error!ArgResult(bool) {
    if (idx < ctx.args.len and ctx.args[idx] == .Bool) {
        return .{ .val = ctx.args[idx].Bool };
    }
    return .{ .err = try typeErr(ctx, "kotlinx.io.files: argument {d} must be a Boolean", .{idx}) };
}

/// Read the `idx`th argument as a `String`. Returns an owned copy.
fn argString(ctx: *CallCtx, idx: usize) std.mem.Allocator.Error!ArgResult([]const u8) {
    if (idx < ctx.args.len and ctx.args[idx] == .String) {
        const g = ctx.args[idx].String.borrow();
        defer g.deinit();
        return .{ .val = try ctx.allocator.dupe(u8, g.get().*) };
    }
    return .{ .err = try typeErr(ctx, "kotlinx.io: argument {d} must be a String", .{idx}) };
}

// Kotlin Byte is a signed i8; raw bytes reinterpret it as u8, and an
// Int/Long element narrows via toByte() before that reinterpret.
//
// The returned slice is owned by `ctx.allocator`; the caller frees it.
fn argBytes(ctx: *CallCtx, idx: usize) std.mem.Allocator.Error!ArgResult([]u8) {
    if (idx >= ctx.args.len) {
        return .{ .err = try typeErr(ctx, "kotlinx.io: argument {d} must be a String or byte array", .{idx}) };
    }
    switch (ctx.args[idx]) {
        .String => |s| {
            const g = s.borrow();
            defer g.deinit();
            return .{ .val = try ctx.allocator.dupe(u8, g.get().*) };
        },
        .Array => |a| {
            const elems = try a.snapshot(ctx.allocator);
            defer if (runtime.freeScratch()) ctx.allocator.free(elems);
            const out = try ctx.allocator.alloc(u8, elems.len);
            for (elems, 0..) |v, i| {
                out[i] = switch (v) {
                    .Byte => |bv| @bitCast(bv),
                    .Int => |iv| @bitCast(@as(i8, @truncate(iv))),
                    .Long => |lv| @bitCast(@as(i8, @truncate(lv))),
                    else => 0,
                };
            }
            return .{ .val = out };
        },
        else => return .{ .err = try typeErr(ctx, "kotlinx.io: argument {d} must be a String or byte array", .{idx}) },
    }
}

// A Kotlin `ByteArray` from raw bytes (u8 reinterpreted as signed Byte).
fn bytesValue(ctx: *CallCtx, bytes: []const u8) std.mem.Allocator.Error!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    try items.ensureTotalCapacityPrecise(ctx.allocator, bytes.len);
    for (bytes) |byte| items.appendAssumeCapacity(.{ .Byte = @bitCast(byte) });
    return try runtime.ArrayData.initPacked(ctx.allocator, .Byte, items.items);
}

// A thrown `kotlinx.io.IOException` the Kotlin `try/catch` can catch.
fn ioError(ctx: *CallCtx, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, fmt, args);
    return .{ .err = .{ .Thrown = .{ .Exception = .{
        .fqn = try StringRef.init(ctx.allocator, "kotlinx.io.IOException"),
        .message = try StringRef.initOwned(ctx.allocator, msg),
        .cause = null,
    } } } };
}

fn fsReadAllBytes(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, ctx.allocator, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ioError(ctx, "read {s}: {s}", .{ path, @errorName(e) }),
    };
    defer ctx.allocator.free(bytes);
    return ok(try bytesValue(ctx, bytes));
}

fn fsWriteBytes(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    const data = switch (try argBytes(ctx, 1)) {
        .val => |d| d,
        .err => |e| return e,
    };
    defer ctx.allocator.free(data);
    const append = switch (try argBool(ctx, 2)) {
        .val => |a| a,
        .err => |e| return e,
    };
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    if (append) {
        // Concatenate the existing contents with the new data, then write
        // them back. The `std.Io` file API has no positional seek; the
        // observable result matches `OpenOptions::append`.
        const existing = cwd.readFileAlloc(io, path, ctx.allocator, .unlimited) catch &[_]u8{};
        defer ctx.allocator.free(existing);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(ctx.allocator);
        try combined.appendSlice(ctx.allocator, existing);
        try combined.appendSlice(ctx.allocator, data);
        cwd.writeFile(io, .{ .sub_path = path, .data = combined.items }) catch |e|
            return ioError(ctx, "open {s} for write: {s}", .{ path, @errorName(e) });
    } else {
        cwd.writeFile(io, .{ .sub_path = path, .data = data }) catch |e|
            return ioError(ctx, "open {s} for write: {s}", .{ path, @errorName(e) });
    }
    return ok(.Unit);
}

fn fsExists(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const exists = if (std.Io.Dir.cwd().statFile(io, path, .{})) |_| true else |_| false;
    return ok(.{ .Bool = exists });
}

fn fsDelete(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const is_dir = if (cwd.statFile(io, path, .{})) |st| st.kind == .directory else |_| false;
    const removed = if (is_dir)
        (if (cwd.deleteDir(io, path)) |_| true else |_| false)
    else
        (if (cwd.deleteFile(io, path)) |_| true else |_| false);
    return ok(.{ .Bool = removed });
}

// 0 = created, 1 = already a directory, 2 = exists as a file, 3 = failed.
fn fsCreateDirectories(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(io, path, .{})) |st| {
        if (st.kind == .directory) return ok(Value.newInt(1));
        return ok(Value.newInt(2));
    } else |_| {}
    if (cwd.createDirPath(io, path)) |_| {
        return ok(Value.newInt(0));
    } else |_| {
        return ok(Value.newInt(3));
    }
}

fn fsAtomicMove(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const src = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(src);
    const dst = switch (try argString(ctx, 1)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(dst);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const moved = if (cwd.rename(src, cwd, dst, io)) |_| true else |_| false;
    return ok(.{ .Bool = moved });
}

// `[kind, size]`: kind 0 = absent, 1 = regular file, 2 = directory.
// size is the file length for a regular file, else -1.
fn fsMetadata(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var kind: i64 = 0;
    var size: i64 = -1;
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.kind == .directory) {
            kind = 2;
            size = -1;
        } else {
            kind = 1;
            size = @intCast(st.size);
        }
    } else |_| {}
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(ctx.allocator);
    try items.append(ctx.allocator, .{ .Long = kind });
    try items.append(ctx.allocator, .{ .Long = size });
    return ok(try runtime.ArrayData.initPacked(ctx.allocator, .Long, items.items));
}

fn fsResolve(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, path, &buf) catch |e|
        return ioError(ctx, "resolve {s}: {s}", .{ path, @errorName(e) });
    const owned = try ctx.allocator.dupe(u8, buf[0..n]);
    return ok(.{ .String = try StringRef.initOwned(ctx.allocator, owned) });
}

fn fsList(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const path = switch (try argString(ctx, 0)) {
        .val => |s| s,
        .err => |e| return e,
    };
    defer ctx.allocator.free(path);
    var threaded: std.Io.Threaded = .init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e|
        return ioError(ctx, "list {s}: {s}", .{ path, @errorName(e) });
    defer dir.close(io);

    var names: std.ArrayList(Value) = .empty;
    errdefer {
        for (names.items) |v| v.String.deinit();
        names.deinit(ctx.allocator);
    }
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const owned = try ctx.allocator.dupe(u8, entry.name);
        try names.append(ctx.allocator, .{ .String = try StringRef.initOwned(ctx.allocator, owned) });
    }
    return ok(.{ .List = .{
        .items = try ValueList.init(ctx.allocator, names),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    } });
}

fn fsTempDir(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // Mirrors `std::env::temp_dir()`'s Unix default. The platform's
    // override variable is captured at process start, which an intrinsic
    // cannot reach here, so we report the conventional system temp root.
    const dir: []const u8 = switch (@import("builtin").os.tag) {
        .windows => "C:\\Windows\\Temp",
        else => "/tmp",
    };
    return ok(.{ .String = try StringRef.initOwned(ctx.allocator, try ctx.allocator.dupe(u8, dir)) });
}

fn base64Encode(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const data = switch (try argBytes(ctx, 0)) {
        .val => |d| d,
        .err => |e| return e,
    };
    defer ctx.allocator.free(data);
    const enc = std.base64.standard.Encoder;
    const out = try ctx.allocator.alloc(u8, enc.calcSize(data.len));
    _ = enc.encode(out, data);
    return ok(.{ .String = try StringRef.initOwned(ctx.allocator, out) });
}

fn base64Decode(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const s = switch (try argString(ctx, 0)) {
        .val => |str| str,
        .err => |e| return e,
    };
    defer ctx.allocator.free(s);
    const dec = std.base64.standard.Decoder;
    const out_len = dec.calcSizeForSlice(s) catch |e|
        return typeErr(ctx, "base64 decode: {s}", .{@errorName(e)});
    const out = try ctx.allocator.alloc(u8, out_len);
    defer ctx.allocator.free(out);
    dec.decode(out, s) catch |e|
        return typeErr(ctx, "base64 decode: {s}", .{@errorName(e)});
    // Raw u8 reinterpreted as Kotlin's signed Byte.
    return ok(try bytesValue(ctx, out));
}

fn hexEncode(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const data = switch (try argBytes(ctx, 0)) {
        .val => |d| d,
        .err => |e| return e,
    };
    defer ctx.allocator.free(data);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.ensureTotalCapacityPrecise(ctx.allocator, data.len * 2);
    for (data) |byte| {
        out.appendAssumeCapacity("0123456789abcdef"[byte >> 4]);
        out.appendAssumeCapacity("0123456789abcdef"[byte & 0xf]);
    }
    const owned = try out.toOwnedSlice(ctx.allocator);
    return ok(.{ .String = try StringRef.initOwned(ctx.allocator, owned) });
}

// Each nibble is a 4-bit hex digit, so the packed byte fits u8; the raw
// u8 then reinterprets as Kotlin's signed Byte.
fn hexDecode(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const s = switch (try argString(ctx, 0)) {
        .val => |str| str,
        .err => |e| return e,
    };
    defer ctx.allocator.free(s);
    if (s.len % 2 != 0) {
        return .{ .err = .{ .Type = try ctx.allocator.dupe(u8, "hex string has odd length") } };
    }
    const bytes = try ctx.allocator.alloc(u8, s.len / 2);
    defer ctx.allocator.free(bytes);
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        const hi = hexDigit(s[i]) orelse return typeErr(ctx, "hex: invalid digit `{c}`", .{s[i]});
        const lo = hexDigit(s[i + 1]) orelse return typeErr(ctx, "hex: invalid digit `{c}`", .{s[i + 1]});
        bytes[i / 2] = (hi << 4) | lo;
    }
    return ok(try bytesValue(ctx, bytes));
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn testCtx(args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = undefined,
        .host = undefined,
        .allocator = testing.allocator,
    };
}

fn freeResult(r: EvalResult) void {
    switch (r) {
        .ok => |v| freeValue(v),
        .err => |e| switch (e) {
            .Type, .Arity, .Unbound, .Unimplemented => |m| testing.allocator.free(m),
            .Thrown => |t| freeValue(t),
            else => {},
        },
    }
}

/// Free the heap a returned `Value` owns. The intrinsics allocate from
/// `ctx.allocator`; in production that is an arena, but the unit tests
/// use the debug allocator and must release each allocation by hand.
fn freeString(s: StringRef) void {
    // The intrinsics mint these via `initOwned`, so the cell owns its byte
    // buffer and frees it on the final `deinit` under reclaim.
    s.deinit();
}

fn freeValue(v: Value) void {
    switch (v) {
        .String => |s| freeString(s),
        .Array => |a| a.deinitStorage(),
        .List => |l| {
            const g = l.items.borrow();
            for (g.get().items) |e| freeValue(e);
            g.deinit();
            l.items.deinit();
        },
        .Exception => |e| {
            // The fqn is a string literal (not heap); only the message is.
            e.fqn.deinit();
            if (e.message) |m| freeString(m);
        },
        else => {},
    }
}

/// Absolute path of a testing tmp directory (its `Io.Dir` lives under
/// `.zig-cache/tmp/<rand>`; the intrinsics need an absolute string path).
fn tmpAbsPath(tmp: *testing.TmpDir, alloc: std.mem.Allocator) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return alloc.dupe(u8, buf[0..n]);
}

test "host bindings registers the codec and filesystem entries" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("kotlinx.io.encodeBase64") != null);
    try testing.expect(b.resolve("kotlinx.io.decodeBase64") != null);
    try testing.expect(b.resolve("kotlinx.io.encodeHex") != null);
    try testing.expect(b.resolve("kotlinx.io.decodeHex") != null);
    try testing.expect(b.resolve("kotlinx.io.files.__kxio_readAllBytes") != null);
    try testing.expect(b.resolve("kotlinx.io.files.__kxio_tempDir") != null);
    try testing.expect(b.resolve("kotlinx.io.not.a.symbol") == null);
}

test "base64 round-trips" {
    const src = try StringRef.init(testing.allocator, "hello");
    defer src.deinit();
    const enc_args = [_]Value{.{ .String = src }};
    var ctx = testCtx(&enc_args);
    const enc = try base64Encode(&ctx);
    defer freeResult(enc);
    try testing.expect(enc == .ok);
    const g = enc.ok.String.borrow();
    try testing.expectEqualStrings("aGVsbG8=", g.get().*);
    g.deinit();

    const dec_args = [_]Value{enc.ok};
    var ctx2 = testCtx(&dec_args);
    const dec = try base64Decode(&ctx2);
    defer freeResult(dec);
    try testing.expect(dec == .ok);
    try testing.expect(dec.ok == .Array);
    const items = try dec.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqual(@as(i8, 'h'), items[0].Byte);
    try testing.expectEqual(@as(i8, 'o'), items[4].Byte);
}

test "base64 decode rejects invalid input" {
    const s = try StringRef.init(testing.allocator, "not base64!!!");
    defer s.deinit();
    const args = [_]Value{.{ .String = s }};
    var ctx = testCtx(&args);
    const r = try base64Decode(&ctx);
    defer freeResult(r);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "hex encodes lowercase and decodes back" {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(testing.allocator);
    try items.append(testing.allocator, .{ .Byte = @bitCast(@as(u8, 0xde)) });
    try items.append(testing.allocator, .{ .Byte = @bitCast(@as(u8, 0xad)) });
    const arr = try runtime.ArrayData.initPacked(testing.allocator, .Byte, items.items);
    defer arr.Array.deinitStorage();

    const enc_args = [_]Value{arr};
    var ctx = testCtx(&enc_args);
    const enc = try hexEncode(&ctx);
    defer freeResult(enc);
    try testing.expect(enc == .ok);
    const g = enc.ok.String.borrow();
    try testing.expectEqualStrings("dead", g.get().*);
    g.deinit();

    const dec_args = [_]Value{enc.ok};
    var ctx2 = testCtx(&dec_args);
    const dec = try hexDecode(&ctx2);
    defer freeResult(dec);
    try testing.expect(dec == .ok);
    const out = try dec.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(i8, @bitCast(@as(u8, 0xde))), out[0].Byte);
    try testing.expectEqual(@as(i8, @bitCast(@as(u8, 0xad))), out[1].Byte);
}

test "hex decode rejects odd length" {
    const s = try StringRef.init(testing.allocator, "abc");
    defer s.deinit();
    const args = [_]Value{.{ .String = s }};
    var ctx = testCtx(&args);
    const r = try hexDecode(&ctx);
    defer freeResult(r);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    try testing.expectEqualStrings("hex string has odd length", r.err.Type);
}

test "hex decode rejects an invalid digit" {
    const s = try StringRef.init(testing.allocator, "zz");
    defer s.deinit();
    const args = [_]Value{.{ .String = s }};
    var ctx = testCtx(&args);
    const r = try hexDecode(&ctx);
    defer freeResult(r);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    try testing.expectEqualStrings("hex: invalid digit `z`", r.err.Type);
}

test "arg string rejects a non-string argument" {
    const args = [_]Value{.{ .Int = 1 }};
    var ctx = testCtx(&args);
    const r = try base64Encode(&ctx);
    defer freeResult(r);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    try testing.expectEqualStrings("kotlinx.io: argument 0 must be a String or byte array", r.err.Type);
}

test "filesystem round-trip: write, exists, read, metadata, list, delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(&tmp, testing.allocator);
    defer testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "data.bin" });
    defer testing.allocator.free(file_path);

    const path_ref = try StringRef.init(testing.allocator, file_path);
    defer path_ref.deinit();

    // write "hi"
    {
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(testing.allocator);
        try items.append(testing.allocator, .{ .Byte = 'h' });
        try items.append(testing.allocator, .{ .Byte = 'i' });
        const data = try runtime.ArrayData.initPacked(testing.allocator, .Byte, items.items);
        defer data.Array.deinitStorage();
        const args = [_]Value{ .{ .String = path_ref }, data, .{ .Bool = false } };
        var ctx = testCtx(&args);
        const r = try fsWriteBytes(&ctx);
        defer freeResult(r);
        try testing.expect(r == .ok);
    }

    // exists
    {
        const args = [_]Value{.{ .String = path_ref }};
        var ctx = testCtx(&args);
        const r = try fsExists(&ctx);
        defer freeResult(r);
        try testing.expect(r.ok.Bool);
    }

    // read back
    {
        const args = [_]Value{.{ .String = path_ref }};
        var ctx = testCtx(&args);
        const r = try fsReadAllBytes(&ctx);
        defer freeResult(r);
        const items = try r.ok.Array.snapshot(testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(usize, 2), items.len);
        try testing.expectEqual(@as(i8, 'h'), items[0].Byte);
    }

    // metadata: regular file, size 2
    {
        const args = [_]Value{.{ .String = path_ref }};
        var ctx = testCtx(&args);
        const r = try fsMetadata(&ctx);
        defer freeResult(r);
        const items = try r.ok.Array.snapshot(testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(i64, 1), items[0].Long);
        try testing.expectEqual(@as(i64, 2), items[1].Long);
    }

    // list the directory finds data.bin
    {
        const dir_ref = try StringRef.init(testing.allocator, dir_path);
        defer dir_ref.deinit();
        const args = [_]Value{.{ .String = dir_ref }};
        var ctx = testCtx(&args);
        const r = try fsList(&ctx);
        defer freeResult(r);
        const g = r.ok.List.items.borrow();
        var found = false;
        for (g.get().items) |entry| {
            const eg = entry.String.borrow();
            if (std.mem.eql(u8, eg.get().*, "data.bin")) found = true;
            eg.deinit();
        }
        g.deinit();
        try testing.expect(found);
    }

    // delete
    {
        const args = [_]Value{.{ .String = path_ref }};
        var ctx = testCtx(&args);
        const r = try fsDelete(&ctx);
        defer freeResult(r);
        try testing.expect(r.ok.Bool);
    }
}

test "append concatenates to an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(&tmp, testing.allocator);
    defer testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "log.txt" });
    defer testing.allocator.free(file_path);
    const path_ref = try StringRef.init(testing.allocator, file_path);
    defer path_ref.deinit();

    const ab = try StringRef.init(testing.allocator, "ab");
    defer ab.deinit();
    const cd = try StringRef.init(testing.allocator, "cd");
    defer cd.deinit();

    {
        const args = [_]Value{ .{ .String = path_ref }, .{ .String = ab }, .{ .Bool = false } };
        var ctx = testCtx(&args);
        const r = try fsWriteBytes(&ctx);
        defer freeResult(r);
        try testing.expect(r == .ok);
    }
    {
        const args = [_]Value{ .{ .String = path_ref }, .{ .String = cd }, .{ .Bool = true } };
        var ctx = testCtx(&args);
        const r = try fsWriteBytes(&ctx);
        defer freeResult(r);
        try testing.expect(r == .ok);
    }
    {
        const args = [_]Value{.{ .String = path_ref }};
        var ctx = testCtx(&args);
        const r = try fsReadAllBytes(&ctx);
        defer freeResult(r);
        const items = try r.ok.Array.snapshot(testing.allocator);
        defer testing.allocator.free(items);
        try testing.expectEqual(@as(usize, 4), items.len);
        try testing.expectEqual(@as(i8, 'a'), items[0].Byte);
        try testing.expectEqual(@as(i8, 'd'), items[3].Byte);
    }
}

test "create directories reports its outcome codes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpAbsPath(&tmp, testing.allocator);
    defer testing.allocator.free(dir_path);
    const nested = try std.fs.path.join(testing.allocator, &.{ dir_path, "a", "b", "c" });
    defer testing.allocator.free(nested);
    const nested_ref = try StringRef.init(testing.allocator, nested);
    defer nested_ref.deinit();

    {
        const args = [_]Value{.{ .String = nested_ref }};
        var ctx = testCtx(&args);
        const r = try fsCreateDirectories(&ctx);
        defer freeResult(r);
        try testing.expectEqual(@as(i32, 0), r.ok.Int);
    }
    // Already a directory -> 1.
    {
        const args = [_]Value{.{ .String = nested_ref }};
        var ctx = testCtx(&args);
        const r = try fsCreateDirectories(&ctx);
        defer freeResult(r);
        try testing.expectEqual(@as(i32, 1), r.ok.Int);
    }
}

test "metadata for an absent path is kind 0" {
    const s = try StringRef.init(testing.allocator, "/definitely/not/a/real/path/xyzzy");
    defer s.deinit();
    const args = [_]Value{.{ .String = s }};
    var ctx = testCtx(&args);
    const r = try fsMetadata(&ctx);
    defer freeResult(r);
    const items = try r.ok.Array.snapshot(testing.allocator);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(i64, 0), items[0].Long);
    try testing.expectEqual(@as(i64, -1), items[1].Long);
}

test "temp dir returns a non-empty path" {
    var ctx = testCtx(&.{});
    const r = try fsTempDir(&ctx);
    defer freeResult(r);
    try testing.expect(r == .ok);
    const g = r.ok.String.borrow();
    try testing.expect(g.get().*.len > 0);
    g.deinit();
}
