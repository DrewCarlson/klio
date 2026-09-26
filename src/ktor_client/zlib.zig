//! Raw DEFLATE and CRC-32 natives behind klio's ktor-utils content encoders,
//! over std.compress.flate. They stand where the JVM actuals use
//! java.util.zip's `Deflater(nowrap)`, `Inflater(nowrap)` and `CRC32`: the
//! gzip container (header, checksum, trailer) stays in Kotlin, as on the JVM.
//!
//! A deflater and an inflater both work as input arrives and hand back what
//! they have produced.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const net = @import("net.zig");
const sync = @import("sync.zig");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const HostBindings = stdlib.HostBindings;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Stream state lives outside the collected heap and moves between threads.
const gpa = std.heap.c_allocator;

pub fn register(b: *HostBindings) Allocator.Error!void {
    const P = "io.ktor.util.";
    try b.register(P ++ "__kkz_deflater", nDeflater);
    try b.register(P ++ "__kkz_deflate", nDeflate);
    try b.register(P ++ "__kkz_deflate_finish", nDeflateFinish);
    try b.register(P ++ "__kkz_inflater", nInflater);
    try b.register(P ++ "__kkz_inflate_input", nInflateInput);
    try b.register(P ++ "__kkz_inflate_finish", nInflateFinish);
    try b.register(P ++ "__kkz_inflate_take", nInflateTake);
    try b.register(P ++ "__kkz_inflate_remaining", nInflateRemaining);
    try b.register(P ++ "__kkz_inflate_error", nInflateError);
    try b.register(P ++ "__kkz_free", nFree);
    try b.register(P ++ "__kkz_crc32", nCrc32);
    try b.register(P ++ "__kkz_deflate_message", nDeflateMessage);
    try b.register(P ++ "__kkz_inflate_message", nInflateMessage);
}

// ---- streams ------------------------------------------------------------------

/// A raw DEFLATE compressor. Pinned in memory: the compressor's writer
/// points at `window` and at `out`.
pub const Deflater = struct {
    out: std.Io.Writer.Allocating,
    window: []u8,
    compress: flate.Compress,
    finished: bool = false,

    pub fn create() Allocator.Error!*Deflater {
        const d = try gpa.create(Deflater);
        errdefer gpa.destroy(d);
        d.out = .init(gpa);
        errdefer d.out.deinit();
        try d.out.ensureUnusedCapacity(64);
        d.window = try gpa.alloc(u8, flate.max_window_len);
        errdefer gpa.free(d.window);
        // Level 6 is java.util.zip's DEFAULT_COMPRESSION.
        d.compress = flate.Compress.init(&d.out.writer, d.window, .raw, .default) catch return error.OutOfMemory;
        d.finished = false;
        return d;
    }

    pub fn destroy(d: *Deflater) void {
        d.out.deinit();
        gpa.free(d.window);
        gpa.destroy(d);
    }

    pub fn write(d: *Deflater, bytes: []const u8) Allocator.Error!void {
        d.compress.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    /// Emits everything written so far, ending at a byte boundary with the
    /// stream still open.
    pub fn flush(d: *Deflater) Allocator.Error!void {
        d.compress.writer.flush() catch return error.OutOfMemory;
    }

    pub fn finish(d: *Deflater) Allocator.Error!void {
        if (d.finished) return;
        d.finished = true;
        d.compress.finish() catch return error.OutOfMemory;
    }

    /// The compressed bytes produced so far, owned by the caller.
    pub fn take(d: *Deflater) Allocator.Error!?[]u8 {
        const produced = d.out.written();
        if (produced.len == 0) return null;
        const copy = try gpa.dupe(u8, produced);
        d.out.clearRetainingCapacity();
        return copy;
    }
};

/// A raw DEFLATE decompressor that inflates as input arrives, as the JVM's
/// `Inflater(nowrap)` does. std's decompressor pulls its input from a reader,
/// so it runs on a thread of its own over a reader that waits for the next
/// `input`. Each `input` returns once the decompressor has used everything it
/// was given, with the output of every symbol that input completed. The
/// decompressor reads up to four bytes ahead of the symbol it decodes, so the
/// last few symbols of an input wait for the next input or for `finish`.
pub const Inflater = struct {
    m: sync.Lock = .{},
    cv: sync.Cond = .{},
    /// Input not yet read by the decompressor.
    pending: std.ArrayList(u8) = .empty,
    pending_pos: usize = 0,
    /// No more input will come (`finish`).
    closed: bool = false,
    /// The inflater is being freed; the decompressor stops.
    cancelled: bool = false,
    /// The decompressor is waiting for input.
    starved: bool = false,
    /// The decompressor has stopped: at the end of the stream or on a failure.
    done: bool = false,
    ended: bool = false,
    failure: ?[]const u8 = null,
    output: std.ArrayList(u8) = .empty,
    taken: usize = 0,
    /// Input the decompressor had read past the end of the stream.
    after: std.ArrayList(u8) = .empty,
    feed: std.Io.Reader,
    feed_buffer: [4096]u8 = undefined,
    /// The decompressor's output. Only its thread writes it; `published`
    /// bytes of it are in `output`.
    out: std.Io.Writer.Allocating,
    published: usize = 0,
    thread: ?std.Thread = null,

    const feed_vtable: std.Io.Reader.VTable = .{ .stream = feedStream };

    pub fn create() Allocator.Error!*Inflater {
        const inf = try gpa.create(Inflater);
        errdefer gpa.destroy(inf);
        inf.* = .{
            .feed = .{ .vtable = &feed_vtable, .buffer = &.{}, .seek = 0, .end = 0 },
            .out = .init(gpa),
        };
        inf.feed.buffer = &inf.feed_buffer;
        inf.thread = std.Thread.spawn(.{ .stack_size = 1 << 20, .allocator = gpa }, run, .{inf}) catch
            return error.OutOfMemory;
        return inf;
    }

    pub fn destroy(inf: *Inflater) void {
        inf.lock();
        inf.cancelled = true;
        inf.cv.broadcast();
        inf.unlock();
        if (inf.thread) |t| t.join();
        inf.pending.deinit(gpa);
        inf.output.deinit(gpa);
        inf.after.deinit(gpa);
        inf.out.deinit();
        gpa.destroy(inf);
    }

    fn lock(inf: *Inflater) void {
        inf.m.lock();
    }

    fn unlock(inf: *Inflater) void {
        inf.m.unlock();
    }

    /// Waits on the condition from an interpreter thread, which counts as
    /// blocking for the collector.
    fn waitBlocking(inf: *Inflater) void {
        runtime.gc.enterBlockingSafe();
        inf.cv.wait(&inf.m);
        runtime.gc.exitBlockingSafe();
    }

    /// Gives the decompressor more input and waits until it has used all of
    /// it. False once the input is known to be invalid.
    pub fn input(inf: *Inflater, bytes: []const u8) Allocator.Error!bool {
        inf.lock();
        defer inf.unlock();
        try inf.pending.appendSlice(gpa, bytes);
        if (inf.done) return inf.failure == null;
        inf.starved = false;
        inf.cv.broadcast();
        while (!inf.done and !(inf.starved and inf.pending_pos == inf.pending.items.len)) inf.waitBlocking();
        return inf.failure == null;
    }

    /// Ends the input and waits for the decompressor. False with `failure`
    /// set when the input was not a complete DEFLATE stream.
    pub fn finish(inf: *Inflater) bool {
        inf.lock();
        defer inf.unlock();
        inf.closed = true;
        inf.cv.broadcast();
        while (!inf.done) inf.waitBlocking();
        return inf.ended and inf.failure == null;
    }

    /// Up to `max` bytes of output not yet taken, owned by the caller.
    pub fn take(inf: *Inflater, max: usize) Allocator.Error!?[]u8 {
        inf.lock();
        defer inf.unlock();
        const rest = inf.output.items[inf.taken..];
        const n = @min(rest.len, max);
        if (n == 0) return null;
        const copy = try gpa.dupe(u8, rest[0..n]);
        inf.taken += n;
        if (inf.taken == inf.output.items.len) {
            inf.output.clearRetainingCapacity();
            inf.taken = 0;
        }
        return copy;
    }

    /// The input after the end of the DEFLATE stream (a gzip trailer), owned
    /// by the caller.
    pub fn remaining(inf: *Inflater) Allocator.Error![]u8 {
        inf.lock();
        defer inf.unlock();
        if (!inf.ended) return gpa.dupe(u8, "");
        return std.mem.concat(gpa, u8, &.{ inf.after.items, inf.pending.items[inf.pending_pos..] });
    }

    /// The failure message, if the input was found to be invalid.
    pub fn failureMessage(inf: *Inflater) ?[]const u8 {
        inf.lock();
        defer inf.unlock();
        return inf.failure;
    }

    /// Moves what the decompressor has written into `output`. Called on the
    /// decompressor's thread with the lock held.
    fn publishLocked(inf: *Inflater) Allocator.Error!void {
        const written = inf.out.written();
        if (written.len > inf.published) {
            try inf.output.appendSlice(gpa, written[inf.published..]);
            inf.published = written.len;
        }
    }

    /// The feed's `stream`: hands the decompressor pending input, waiting for
    /// more when there is none.
    fn feedStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const inf: *Inflater = @alignCast(@fieldParentPtr("feed", r));
        inf.lock();
        defer inf.unlock();
        while (inf.pending_pos == inf.pending.items.len and !inf.cancelled) {
            if (inf.closed) return error.EndOfStream;
            // Every symbol decoded so far is complete: hand the output over
            // before waiting, so the caller of `input` sees it.
            inf.publishLocked() catch return error.ReadFailed;
            inf.starved = true;
            inf.cv.broadcast();
            inf.cv.wait(&inf.m);
        }
        if (inf.cancelled) return error.ReadFailed;
        inf.starved = false;
        const n = try w.write(limit.slice(inf.pending.items[inf.pending_pos..]));
        inf.pending_pos += n;
        if (inf.pending_pos == inf.pending.items.len) {
            inf.pending.clearRetainingCapacity();
            inf.pending_pos = 0;
        }
        return n;
    }

    fn run(inf: *Inflater) void {
        // Direct mode: the decompressor writes into `out`, which keeps the
        // history its matches copy from.
        var decompress: flate.Decompress = .init(&inf.feed, .raw, &.{});
        var failure: ?[]const u8 = null;
        var ended = false;
        while (true) {
            _ = decompress.reader.stream(&inf.out.writer, .limited(1 << 16)) catch |e| {
                switch (e) {
                    error.EndOfStream => ended = true,
                    error.WriteFailed => failure = out_of_memory,
                    error.ReadFailed => failure = if (decompress.err) |derr| describe(derr) else invalid_input,
                }
                break;
            };
            inf.lock();
            const published = inf.publishLocked();
            inf.unlock();
            published catch {
                failure = out_of_memory;
                break;
            };
            inf.trimHistory();
        }
        inf.lock();
        defer inf.unlock();
        inf.publishLocked() catch {
            if (failure == null) failure = out_of_memory;
        };
        if (ended) {
            inf.after.appendSlice(gpa, inf.feed.buffered()) catch {
                failure = out_of_memory;
            };
        }
        inf.ended = ended and failure == null;
        inf.failure = if (inf.cancelled) null else failure;
        inf.done = true;
        inf.cv.broadcast();
    }

    /// Keeps the last window of output, the history later matches read,
    /// once everything before it is published.
    fn trimHistory(inf: *Inflater) void {
        const keep = flate.history_len;
        const written = inf.out.written();
        if (written.len < 1 << 20 or inf.published != written.len) return;
        std.mem.copyForwards(u8, written[0..keep], written[written.len - keep ..]);
        inf.out.shrinkRetainingCapacity(keep);
        inf.published = keep;
    }

    const out_of_memory = "Out of memory while decompressing.";
    const invalid_input = "Compressed input is invalid.";

    /// The zlib message the JVM's DataFormatException carries, where one
    /// corresponds.
    fn describe(err: flate.Decompress.Error) []const u8 {
        return switch (err) {
            error.EndOfStream => "Compressed input is incomplete.",
            error.InvalidBlockType => "invalid block type",
            error.WrongStoredBlockNlen => "invalid stored block lengths",
            error.InvalidDynamicBlockHeader,
            error.OversubscribedHuffmanTree,
            error.IncompleteHuffmanTree,
            => "invalid code lengths set",
            error.InvalidCode => "invalid literal/length code",
            error.InvalidMatch => "invalid distance too far back",
            error.MissingEndOfBlockCode => "invalid code -- missing end-of-block",
            else => invalid_input,
        };
    }
};

const Stream = union(enum) {
    deflater: *Deflater,
    inflater: *Inflater,
};

const Table = struct {
    mutex: sync.Mutex = .{},
    streams: std.AutoHashMapUnmanaged(u64, Stream) = .empty,
    next: u64 = 1,
};

var table: Table = .{};

fn put(s: Stream) Allocator.Error!u64 {
    table.mutex.lock();
    defer table.mutex.unlock();
    const id = table.next;
    table.next += 1;
    try table.streams.put(gpa, id, s);
    return id;
}

/// A stream is used by one coroutine at a time; the table lock only guards
/// the lookup.
fn get(id: i64) ?Stream {
    if (id <= 0) return null;
    table.mutex.lock();
    defer table.mutex.unlock();
    return table.streams.get(@intCast(id));
}

// ---- natives ----------------------------------------------------------------

fn argRange(ctx: *CallCtx, i: usize, off: i64, len: i64) Allocator.Error!?[]u8 {
    if (off < 0 or len < 0) return null;
    const Copy = struct {
        off: usize,
        out: []u8,
        fn run(st: *const @This(), bytes: []u8) i64 {
            if (st.off > bytes.len or bytes.len - st.off < st.out.len) return -1;
            @memcpy(st.out, bytes[st.off..][0..st.out.len]);
            return 0;
        }
    };
    const out = try gpa.alloc(u8, @intCast(len));
    const st: Copy = .{ .off = @intCast(off), .out = out };
    const r = net.withBytes(ctx, i, false, &st, Copy.run) catch |e| {
        gpa.free(out);
        return e;
    };
    if (r == null or r.? != 0) {
        gpa.free(out);
        return null;
    }
    return out;
}

fn bytesResult(a: Allocator, bytes: ?[]u8) Allocator.Error!EvalResult {
    const b = bytes orelse return .{ .ok = .Null };
    defer gpa.free(b);
    return .{ .ok = try net.newByteArray(a, b) };
}

fn nDeflater(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const d = try Deflater.create();
    const id = put(.{ .deflater = d }) catch |e| {
        d.destroy();
        return e;
    };
    return net.int(@intCast(id));
}

/// `__kkz_deflate(h, bytes, off, len): ByteArray?`: compresses the range and
/// returns the compressed bytes produced so far.
fn nDeflate(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_deflate: unknown deflater");
    if (s != .deflater) return net.typeErr("__kkz_deflate: not a deflater");
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kkz_deflate: the byte range does not fit the array");
    defer gpa.free(bytes);
    try s.deflater.write(bytes);
    return bytesResult(ctx.allocator, try s.deflater.take());
}

fn nDeflateFinish(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_deflate_finish: unknown deflater");
    if (s != .deflater) return net.typeErr("__kkz_deflate_finish: not a deflater");
    try s.deflater.finish();
    return bytesResult(ctx.allocator, try s.deflater.take());
}

fn nInflater(ctx: *CallCtx) Allocator.Error!EvalResult {
    _ = ctx;
    const inf = try Inflater.create();
    const id = put(.{ .inflater = inf }) catch |e| {
        inf.destroy();
        return e;
    };
    return net.int(@intCast(id));
}

/// `__kkz_inflate_input(h, bytes, off, len): Boolean`: inflates the range;
/// false once the input is known to be invalid (`__kkz_inflate_error` says
/// how).
fn nInflateInput(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_inflate_input: unknown inflater");
    if (s != .inflater) return net.typeErr("__kkz_inflate_input: not an inflater");
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kkz_inflate_input: the byte range does not fit the array");
    defer gpa.free(bytes);
    return .{ .ok = .{ .Bool = try s.inflater.input(bytes) } };
}

/// `__kkz_inflate_finish(h): Boolean`: false when the input is not a
/// complete DEFLATE stream (`__kkz_inflate_error` says how).
fn nInflateFinish(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_inflate_finish: unknown inflater");
    if (s != .inflater) return net.typeErr("__kkz_inflate_finish: not an inflater");
    return .{ .ok = .{ .Bool = s.inflater.finish() } };
}

fn nInflateTake(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_inflate_take: unknown inflater");
    if (s != .inflater) return net.typeErr("__kkz_inflate_take: not an inflater");
    const max: usize = @intCast(@max(net.argInt(ctx, 1), 0));
    return bytesResult(ctx.allocator, try s.inflater.take(max));
}

/// The input after the end of the DEFLATE stream (a gzip trailer).
fn nInflateRemaining(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return net.typeErr("__kkz_inflate_remaining: unknown inflater");
    if (s != .inflater) return net.typeErr("__kkz_inflate_remaining: not an inflater");
    const rest = try s.inflater.remaining();
    defer gpa.free(rest);
    return .{ .ok = try net.newByteArray(ctx.allocator, rest) };
}

fn nInflateError(ctx: *CallCtx) Allocator.Error!EvalResult {
    const s = get(net.argInt(ctx, 0)) orelse return .{ .ok = .Null };
    if (s != .inflater) return .{ .ok = .Null };
    const msg = s.inflater.failureMessage() orelse return .{ .ok = .Null };
    return .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, msg) } };
}

fn nFree(ctx: *CallCtx) Allocator.Error!EvalResult {
    const id = net.argInt(ctx, 0);
    if (id <= 0) return .{ .ok = .Unit };
    const s = blk: {
        table.mutex.lock();
        defer table.mutex.unlock();
        const kv = table.streams.fetchRemove(@intCast(id)) orelse return .{ .ok = .Unit };
        break :blk kv.value;
    };
    switch (s) {
        .deflater => |d| d.destroy(),
        .inflater => |inf| inf.destroy(),
    }
    return .{ .ok = .Unit };
}

/// `__kkz_crc32(crc, bytes, off, len): Int`: the CRC-32 of the range
/// continued from `crc` (0 to start), as java.util.zip.CRC32 computes it.
fn nCrc32(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kkz_crc32: the byte range does not fit the array");
    defer gpa.free(bytes);
    const start: u32 = @bitCast(@as(i32, @truncate(net.argInt(ctx, 0))));
    return net.int(@as(i32, @bitCast(crc32Update(start, bytes))));
}

// ---- per-message deflate (WebSocket permessage-deflate) -----------------------

/// Compresses one message with a fresh compressor and flushes it to a byte
/// boundary without ending the stream, the shape RFC 7692 sends. Level -1 is
/// the default (6), 0 stores, 1 to 9 are zlib's levels. The caller owns the
/// result.
pub fn deflateMessage(data: []const u8, level: i64) error{ OutOfMemory, InvalidLevel }![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.ensureUnusedCapacity(64);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    if (level == 0) {
        var raw = flate.Compress.Raw.init(&out.writer, window, .raw) catch return error.OutOfMemory;
        raw.writer.writeAll(data) catch return error.OutOfMemory;
        raw.writer.flush() catch return error.OutOfMemory;
    } else {
        const opts: flate.Compress.Options = switch (level) {
            -1, 6 => .level_6,
            1 => .level_1,
            2 => .level_2,
            3 => .level_3,
            4 => .level_4,
            5 => .level_5,
            7 => .level_7,
            8 => .level_8,
            9 => .level_9,
            else => return error.InvalidLevel,
        };
        const c = try gpa.create(flate.Compress);
        defer gpa.destroy(c);
        c.* = flate.Compress.init(&out.writer, window, .raw, opts) catch return error.OutOfMemory;
        c.writer.writeAll(data) catch return error.OutOfMemory;
        c.writer.flush() catch return error.OutOfMemory;
    }
    return gpa.dupe(u8, out.written());
}

pub const MessageInflate = union(enum) {
    /// The message's output, owned by the caller.
    ok: []u8,
    failure: []const u8,
    too_large: usize,
};

/// Inflates one message of a permessage-deflate stream: `data` followed by
/// the empty stored block the sender removed, decoded after `history`, the
/// stream's earlier output (at most a window of it). The message must end
/// at a block boundary. Output past `max` bytes fails as too large.
pub fn inflateMessage(history: []const u8, data: []const u8, max: usize) Allocator.Error!MessageInflate {
    const input = try std.mem.concat(gpa, u8, &.{ data, &.{ 0x00, 0x00, 0xff, 0xff } });
    defer gpa.free(input);
    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Direct mode: matches copy from the history in the output buffer.
    const kept = history[history.len - @min(history.len, flate.history_len) ..];
    out.writer.writeAll(kept) catch return error.OutOfMemory;
    var decompress: flate.Decompress = .init(&reader, .raw, &.{});
    while (true) {
        _ = decompress.reader.stream(&out.writer, .limited(1 << 16)) catch |e| switch (e) {
            // A final block ends the stream.
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => {
                const derr = decompress.err orelse return .{ .failure = Inflater.invalid_input };
                // The input ran out at a block boundary: the message is whole.
                if (derr == error.EndOfStream and decompress.state == .block_header and reader.seek == input.len) break;
                return .{ .failure = Inflater.describe(derr) };
            },
        };
        const produced = out.written().len - kept.len;
        if (produced > max) return .{ .too_large = produced };
    }
    const produced = out.written()[kept.len..];
    if (produced.len > max) return .{ .too_large = produced.len };
    return .{ .ok = try gpa.dupe(u8, produced) };
}

/// `__kkz_deflate_message(bytes, off, len, level): ByteArray?`: null for a
/// level outside -1..9.
fn nDeflateMessage(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bytes = (try argRange(ctx, 0, net.argInt(ctx, 1), net.argInt(ctx, 2))) orelse
        return net.typeErr("__kkz_deflate_message: the byte range does not fit the array");
    defer gpa.free(bytes);
    const out = deflateMessage(bytes, net.argInt(ctx, 3)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLevel => return .{ .ok = .Null },
    };
    return bytesResult(ctx.allocator, out);
}

/// `__kkz_inflate_message(history, bytes, off, len, max): Any`: the output as
/// a ByteArray, or the failure as a String.
fn nInflateMessage(ctx: *CallCtx) Allocator.Error!EvalResult {
    const history = (try argRange(ctx, 0, 0, arrayLen(ctx, 0))) orelse
        return net.typeErr("__kkz_inflate_message: history is not a byte array");
    defer gpa.free(history);
    const bytes = (try argRange(ctx, 1, net.argInt(ctx, 2), net.argInt(ctx, 3))) orelse
        return net.typeErr("__kkz_inflate_message: the byte range does not fit the array");
    defer gpa.free(bytes);
    const max: usize = @intCast(@max(net.argInt(ctx, 4), 0));
    return switch (try inflateMessage(history, bytes, max)) {
        .ok => |out| bytesResult(ctx.allocator, out),
        .failure => |msg| .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, msg) } },
        .too_large => |n| blk: {
            const msg = try std.fmt.allocPrint(gpa, "Inflated data exceeds limit: {d} > {d}", .{ n, max });
            defer gpa.free(msg);
            break :blk .{ .ok = .{ .String = try runtime.strInit(ctx.allocator, msg) } };
        },
    };
}

fn arrayLen(ctx: *const CallCtx, i: usize) i64 {
    if (i >= ctx.args.len or ctx.args[i] != .Array) return -1;
    return @intCast(ctx.args[i].Array.len());
}

pub fn crc32Update(crc: u32, bytes: []const u8) u32 {
    // std's Crc32 keeps the complemented register; resuming from a finished
    // value complements it back first.
    var h: std.hash.Crc32 = .{ .crc = ~crc };
    h.update(bytes);
    return h.final();
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn deflateAll(chunks: []const []const u8) ![]u8 {
    const d = try Deflater.create();
    defer d.destroy();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (chunks) |c| {
        try d.write(c);
        if (try d.take()) |p| {
            defer gpa.free(p);
            try out.appendSlice(gpa, p);
        }
    }
    try d.finish();
    if (try d.take()) |p| {
        defer gpa.free(p);
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

fn takeAll(inf: *Inflater, out: *std.ArrayList(u8)) !void {
    while (try inf.take(1000)) |p| {
        defer gpa.free(p);
        try out.appendSlice(gpa, p);
    }
}

/// Inflates `compressed` fed in pieces of `step` bytes.
fn inflateSteps(compressed: []const u8, step: usize) !struct { data: []u8, rest: []u8 } {
    const inf = try Inflater.create();
    defer inf.destroy();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < compressed.len) : (i += step) {
        if (!try inf.input(compressed[i..@min(i + step, compressed.len)])) return error.InflateFailed;
        try takeAll(inf, &out);
    }
    if (!inf.finish()) return error.InflateFailed;
    try takeAll(inf, &out);
    return .{ .data = try out.toOwnedSlice(gpa), .rest = try inf.remaining() };
}

fn inflateAll(compressed: []const u8) !struct { data: []u8, rest: []u8 } {
    const r = try inflateSteps(compressed, @max(compressed.len, 1));
    return .{ .data = r.data, .rest = r.rest };
}

test "deflate then inflate round-trips text, binary and empty input" {
    var big: [100_000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate((i * 7) ^ (i >> 5));
    const cases = [_][]const []const u8{
        &.{"hello, hello, hello, compressed world"},
        &.{ big[0..40_000], big[40_000..] },
        &.{},
        &.{ "", "a", "" },
    };
    for (cases) |chunks| {
        const compressed = try deflateAll(chunks);
        defer gpa.free(compressed);
        const r = try inflateAll(compressed);
        defer gpa.free(r.data);
        defer gpa.free(r.rest);
        const joined = try std.mem.concat(gpa, u8, chunks);
        defer gpa.free(joined);
        try testing.expectEqualSlices(u8, joined, r.data);
        try testing.expectEqual(@as(usize, 0), r.rest.len);
    }
}

test "inflate reads a known gzip stream's body and leaves its trailer" {
    // `printf 'hello, klio\n' | gzip -n`: a 10-byte header, the raw DEFLATE
    // body, then the CRC-32 and the size.
    const gz = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7,
        0x51, 0xc8, 0xce, 0xc9, 0xcc, 0xe7, 0x02, 0x00, 0x5a, 0xf4, 0x5a, 0xd9, 0x0c, 0x00, 0x00, 0x00,
    };
    const r = try inflateAll(gz[10..]);
    defer gpa.free(r.data);
    defer gpa.free(r.rest);
    try testing.expectEqualStrings("hello, klio\n", r.data);
    try testing.expectEqualSlices(u8, gz[gz.len - 8 ..], r.rest);
    try testing.expectEqual(std.mem.readInt(u32, gz[gz.len - 8 ..][0..4], .little), crc32Update(0, r.data));
}

test "inflate refuses an incomplete or invalid stream" {
    const compressed = try deflateAll(&.{"some text that compresses into several bytes of deflate output"});
    defer gpa.free(compressed);
    try testing.expectError(error.InflateFailed, inflateAll(compressed[0 .. compressed.len / 2]));
    try testing.expectError(error.InflateFailed, inflateAll(&.{ 0xff, 0xff, 0xff }));
}

test "inflate gives the same result for input in any pieces, past its history window" {
    // Over a megabyte of output with long-distance matches, so the
    // decompressor drops published output and keeps only its window.
    const big = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(big);
    var rng = std.Random.DefaultPrng.init(7);
    const words = [_][]const u8{ "alpha ", "beta ", "gamma ", "delta ", "epsilon\n" };
    var at: usize = 0;
    while (at < big.len) {
        const word = words[rng.random().uintLessThan(usize, words.len)];
        const n = @min(word.len, big.len - at);
        @memcpy(big[at..][0..n], word[0..n]);
        at += n;
    }
    const compressed = try deflateAll(&.{big});
    defer gpa.free(compressed);
    for ([_]usize{ 1, 7, 4096, compressed.len }) |step| {
        if (step == 1 and compressed.len > 200_000) continue;
        const r = try inflateSteps(compressed, step);
        defer gpa.free(r.data);
        defer gpa.free(r.rest);
        try testing.expectEqualSlices(u8, big, r.data);
        try testing.expectEqual(@as(usize, 0), r.rest.len);
    }
    const small = try deflateAll(&.{big[0..50_000]});
    defer gpa.free(small);
    const r = try inflateSteps(small, 1);
    defer gpa.free(r.data);
    defer gpa.free(r.rest);
    try testing.expectEqualSlices(u8, big[0..50_000], r.data);
}

test "inflate hands back a block's output before the stream ends" {
    // A stored block "hello" that is not the last, then the first byte of
    // the next block: the output is there before any more input.
    const first = [_]u8{ 0x00, 0x05, 0x00, 0xfa, 0xff, 'h', 'e', 'l', 'l', 'o', 0x01 };
    const inf = try Inflater.create();
    defer inf.destroy();
    try testing.expect(try inf.input(&first));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try takeAll(inf, &out);
    try testing.expectEqualStrings("hello", out.items);
    // The rest of the final stored block: " klio", then a trailer.
    const rest = [_]u8{ 0x05, 0x00, 0xfa, 0xff, ' ', 'k', 'l', 'i', 'o', 'T', 'R' };
    try testing.expect(try inf.input(&rest));
    try testing.expect(inf.finish());
    try takeAll(inf, &out);
    try testing.expectEqualStrings("hello klio", out.items);
    const after = try inf.remaining();
    defer gpa.free(after);
    try testing.expectEqualStrings("TR", after);
}

test "inflate reports invalid input as it arrives, and stops when freed early" {
    const bad = try Inflater.create();
    defer bad.destroy();
    try testing.expect(!try bad.input(&.{ 0xff, 0x00, 0x00, 0x00 }));
    try testing.expectEqualStrings("invalid block type", bad.failureMessage().?);
    try testing.expect(!bad.finish());

    // Freed while the decompressor waits for input.
    const compressed = try deflateAll(&.{"a stream that is never finished, only freed"});
    defer gpa.free(compressed);
    const early = try Inflater.create();
    try testing.expect(try early.input(compressed[0 .. compressed.len / 2]));
    early.destroy();

    // Freed before any input.
    const idle = try Inflater.create();
    idle.destroy();
}

/// RFC 7692's sending rule, as ktor applies it: a message that ends in an
/// empty stored block drops its last four bytes; otherwise a zero byte
/// starts the block the receiver completes.
fn frameMessage(compressed: []const u8) ![]u8 {
    const padded = [_]u8{ 0, 0, 0, 0xff, 0xff };
    if (std.mem.endsWith(u8, compressed, &padded)) return gpa.dupe(u8, compressed[0 .. compressed.len - 4]);
    return std.mem.concat(gpa, u8, &.{ compressed, &.{0} });
}

test "inflateMessage decodes RFC 7692's examples, with and without a shared window" {
    const first = [_]u8{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    const r1 = try inflateMessage("", &first, 1 << 20);
    defer gpa.free(r1.ok);
    try testing.expectEqualStrings("Hello", r1.ok);
    // The second "Hello" is a match into the first message's output.
    const second = [_]u8{ 0xf2, 0x00, 0x11, 0x00, 0x00 };
    const r2 = try inflateMessage("Hello", &second, 1 << 20);
    defer gpa.free(r2.ok);
    try testing.expectEqualStrings("Hello", r2.ok);
    // Without the window the match reaches before the stream.
    try testing.expect(try inflateMessage("", &second, 1 << 20) == .failure);
    // A stored block.
    const stored = [_]u8{ 0x00, 0x05, 0x00, 0xfa, 0xff, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00 };
    const r3 = try inflateMessage("", &stored, 1 << 20);
    defer gpa.free(r3.ok);
    try testing.expectEqualStrings("Hello", r3.ok);
}

test "deflateMessage output inflates at every level, and limits and bad input fail" {
    const text = "per-message deflate, per-message deflate, per-message deflate " ** 20;
    for ([_]i64{ -1, 0, 1, 6, 9 }) |level| {
        const compressed = try deflateMessage(text, level);
        defer gpa.free(compressed);
        const framed = try frameMessage(compressed);
        defer gpa.free(framed);
        const r = try inflateMessage("", framed, 1 << 20);
        defer gpa.free(r.ok);
        try testing.expectEqualStrings(text, r.ok);
        if (level != 0) try testing.expect(framed.len < text.len / 4);
    }
    try testing.expectError(error.InvalidLevel, deflateMessage("x", 10));

    const compressed = try deflateMessage(text, -1);
    defer gpa.free(compressed);
    const framed = try frameMessage(compressed);
    defer gpa.free(framed);
    try testing.expect(try inflateMessage("", framed, 100) == .too_large);
    try testing.expectEqualStrings("invalid block type", (try inflateMessage("", &.{ 0xff, 0xff }, 100)).failure);
}

test "inflateMessage follows a sender that keeps its window across messages" {
    // A peer with context takeover: one compressor, flushed per message, the
    // later messages matching into the earlier ones.
    const d = try Deflater.create();
    defer d.destroy();
    const messages = [_][]const u8{ "the quick brown fox jumps", "the quick brown fox jumps over the lazy dog", "the lazy dog" };
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(gpa);
    for (messages) |msg| {
        try d.write(msg);
        try d.flush();
        const produced = (try d.take()).?;
        defer gpa.free(produced);
        const framed = try frameMessage(produced);
        defer gpa.free(framed);
        // The framing's extra byte starts the stored block the receiver ends;
        // the sender's stream goes on as if it had written that block.
        const r = try inflateMessage(history.items, framed, 1 << 20);
        defer gpa.free(r.ok);
        try testing.expectEqualStrings(msg, r.ok);
        try history.appendSlice(gpa, r.ok);
    }
}

test "crc32 matches java.util.zip.CRC32 and resumes across chunks" {
    try testing.expectEqual(@as(u32, 0xcbf43926), crc32Update(0, "123456789"));
    try testing.expectEqual(crc32Update(0, "123456789"), crc32Update(crc32Update(0, "1234"), "56789"));
    try testing.expectEqual(@as(u32, 0), crc32Update(0, ""));
}

fn call(f: *const fn (*CallCtx) Allocator.Error!EvalResult, args: []const Value) !Value {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx: CallCtx = .{ .args = args, .out = cap.output(), .host = h.host(), .allocator = testing.allocator };
    return switch (try f(&ctx)) {
        .ok => |v| v,
        .err => error.NativeFailed,
    };
}

fn appendBytes(list: *std.ArrayList(u8), v: Value) !void {
    if (v == .Null) return;
    defer v.release(testing.allocator);
    const arr = v.Array;
    for (0..arr.len()) |k| try list.append(gpa, @bitCast(arr.get(k).Byte));
}

test "the natives compress, decompress and checksum a byte array range" {
    const text = "klio compresses this, klio compresses this, klio compresses this";
    const src = try net.newByteArray(testing.allocator, "xx" ++ text ++ "yy");
    defer src.release(testing.allocator);
    const n: i64 = text.len;

    const d = (try call(nDeflater, &.{})).asI64().?;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    try appendBytes(&compressed, try call(nDeflate, &.{ Value.newInt(d), src, Value.newInt(2), Value.newInt(n) }));
    try appendBytes(&compressed, try call(nDeflateFinish, &.{Value.newInt(d)}));
    _ = try call(nFree, &.{Value.newInt(d)});
    try testing.expect(compressed.items.len < text.len);

    try compressed.appendSlice(gpa, "TRAILER!");
    const packed_bytes = try net.newByteArray(testing.allocator, compressed.items);
    defer packed_bytes.release(testing.allocator);
    const inf = (try call(nInflater, &.{})).asI64().?;
    defer _ = call(nFree, &.{Value.newInt(inf)}) catch {};
    const total: i64 = @intCast(compressed.items.len);
    _ = try call(nInflateInput, &.{ Value.newInt(inf), packed_bytes, Value.newInt(0), Value.newInt(5) });
    _ = try call(nInflateInput, &.{ Value.newInt(inf), packed_bytes, Value.newInt(5), Value.newInt(total - 5) });
    try testing.expect((try call(nInflateFinish, &.{Value.newInt(inf)})).Bool);
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    while (true) {
        const part = try call(nInflateTake, &.{ Value.newInt(inf), Value.newInt(10) });
        if (part == .Null) break;
        try appendBytes(&plain, part);
    }
    try testing.expectEqualStrings(text, plain.items);
    var rest: std.ArrayList(u8) = .empty;
    defer rest.deinit(gpa);
    try appendBytes(&rest, try call(nInflateRemaining, &.{Value.newInt(inf)}));
    try testing.expectEqualStrings("TRAILER!", rest.items);
    try testing.expect((try call(nInflateError, &.{Value.newInt(inf)})) == .Null);

    const crc = (try call(nCrc32, &.{ Value.newInt(0), src, Value.newInt(2), Value.newInt(n) })).asI64().?;
    try testing.expectEqual(@as(i64, @as(i32, @bitCast(crc32Update(0, text)))), crc);

    try testing.expectError(error.NativeFailed, call(nDeflate, &.{ Value.newInt(inf), src, Value.newInt(0), Value.newInt(1) }));
    try testing.expectError(error.NativeFailed, call(nCrc32, &.{ Value.newInt(0), src, Value.newInt(60), Value.newInt(n) }));
    try testing.expectError(error.NativeFailed, call(nInflateInput, &.{ Value.newInt(424242), src, Value.newInt(0), Value.newInt(1) }));
}

test "the inflater reports a truncated stream" {
    const compressed = try deflateAll(&.{"a stream that will be cut short before its final block ends"});
    defer gpa.free(compressed);
    const cut = compressed.len - 3;
    const arr = try net.newByteArray(testing.allocator, compressed[0..cut]);
    defer arr.release(testing.allocator);
    const inf = (try call(nInflater, &.{})).asI64().?;
    defer _ = call(nFree, &.{Value.newInt(inf)}) catch {};
    _ = try call(nInflateInput, &.{ Value.newInt(inf), arr, Value.newInt(0), Value.newInt(@intCast(cut)) });
    try testing.expect(!(try call(nInflateFinish, &.{Value.newInt(inf)})).Bool);
    const msg = try call(nInflateError, &.{Value.newInt(inf)});
    defer msg.release(testing.allocator);
    const g = msg.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("Compressed input is incomplete.", g.get().bytes);
}
