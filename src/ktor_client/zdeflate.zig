//! zlib's DEFLATE compressor (deflate.c and trees.c of zlib 1.3.1), for raw
//! streams with zlib's defaults: a 32 KB window, memLevel 8 and the default
//! strategy, at levels 0 to 9. java.util.zip.Deflater is this compressor, so
//! ktor's encoders produce the JVM's bytes exactly, and upstream tests that
//! pin a compressed length or body hold.
//!
//! The port keeps zlib's control flow and state one for one, including the
//! details that decide the output: a hash chain entry of 0 means "none", so
//! window position 0 is never a match source; `deflate` works in rounds
//! bounded by the caller's output space, as `deflate(strm, flush)` does; and
//! a stored block (level 0) is sized by that space. `Deflater` is the
//! java.util.zip surface over it: `setInput`, `deflate(out, flush)`,
//! `needsInput`, `finish` and `finished`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Flush = enum(i32) {
    none = 0,
    partial = 1,
    sync = 2,
    full = 3,
    finish = 4,
    block = 5,
};

// ---- constants (deflate.h, trees.h) ------------------------------------------

const w_bits = 15;
const w_size: u32 = 1 << w_bits;
const w_mask: u32 = w_size - 1;
const window_size: u32 = 2 * w_size;
const mem_level = 8;
const hash_bits = mem_level + 7;
const hash_size: u32 = 1 << hash_bits;
const hash_mask: u32 = hash_size - 1;
const hash_shift = (hash_bits + min_match - 1) / min_match;
const lit_bufsize: u32 = 1 << (mem_level + 6);
const pending_buf_size: u32 = lit_bufsize * 4;
const sym_end: u32 = (lit_bufsize - 1) * 3;

const min_match = 3;
const max_match = 258;
const min_lookahead: u32 = max_match + min_match + 1;
const max_dist: u32 = w_size - min_lookahead;
const win_init: u32 = max_match;
const too_far: u32 = 4096;
const max_stored: u32 = 65535;
const nil: u32 = 0;

const length_codes = 29;
const literals = 256;
const l_codes = literals + 1 + length_codes;
const d_codes = 30;
const bl_codes = 19;
const heap_size = 2 * l_codes + 1;
const max_bits = 15;
const max_bl_bits = 7;
const end_block = 256;
const rep_3_6 = 16;
const repz_3_10 = 17;
const repz_11_138 = 18;
const buf_size = 16;

const stored_block = 0;
const static_trees = 1;
const dyn_trees = 2;

const extra_lbits = [length_codes]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const extra_dbits = [d_codes]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const extra_blbits = [bl_codes]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7 };
const bl_order = [bl_codes]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// A Huffman tree node. zlib overlays `freq` with `code` and `dad` with
/// `len`; every read here follows the write it would see there.
const Node = struct {
    freq: u16 = 0,
    code: u16 = 0,
    dad: u16 = 0,
    len: u16 = 0,
};

/// trees.c's static tables, built as tr_static_init builds them.
const Static = struct {
    ltree: [l_codes + 2]Node,
    dtree: [d_codes]Node,
    dist_code: [512]u8,
    length_code: [max_match - min_match + 1]u8,
    base_length: [length_codes]u8,
    base_dist: [d_codes]u16,
};

const static: Static = blk: {
    @setEvalBranchQuota(100_000);
    var t: Static = undefined;
    var length: u32 = 0;
    var code: u32 = 0;
    while (code < length_codes - 1) : (code += 1) {
        t.base_length[code] = @intCast(length);
        var n: u32 = 0;
        while (n < (@as(u32, 1) << extra_lbits[code])) : (n += 1) {
            t.length_code[length] = @intCast(code);
            length += 1;
        }
    }
    t.base_length[length_codes - 1] = 0;
    t.length_code[length - 1] = @intCast(code);

    var dist: u32 = 0;
    code = 0;
    while (code < 16) : (code += 1) {
        t.base_dist[code] = @intCast(dist);
        var n: u32 = 0;
        while (n < (@as(u32, 1) << extra_dbits[code])) : (n += 1) {
            t.dist_code[dist] = @intCast(code);
            dist += 1;
        }
    }
    dist >>= 7;
    while (code < d_codes) : (code += 1) {
        t.base_dist[code] = @intCast(dist << 7);
        var n: u32 = 0;
        while (n < (@as(u32, 1) << (extra_dbits[code] - 7))) : (n += 1) {
            t.dist_code[256 + dist] = @intCast(code);
            dist += 1;
        }
    }

    var bl_count = [_]u16{0} ** (max_bits + 1);
    for (&t.ltree) |*node| node.* = .{};
    var n: usize = 0;
    while (n <= 143) : (n += 1) {
        t.ltree[n].len = 8;
        bl_count[8] += 1;
    }
    while (n <= 255) : (n += 1) {
        t.ltree[n].len = 9;
        bl_count[9] += 1;
    }
    while (n <= 279) : (n += 1) {
        t.ltree[n].len = 7;
        bl_count[7] += 1;
    }
    while (n <= 287) : (n += 1) {
        t.ltree[n].len = 8;
        bl_count[8] += 1;
    }
    genCodes(&t.ltree, l_codes + 1, &bl_count);
    for (&t.dtree, 0..) |*node, i| {
        node.* = .{ .len = 5, .code = @intCast(biReverse(@intCast(i), 5)) };
    }
    break :blk t;
};

fn biReverse(code_in: u32, len_in: u32) u32 {
    var code = code_in;
    var len = len_in;
    var res: u32 = 0;
    while (true) {
        res |= code & 1;
        code >>= 1;
        res <<= 1;
        len -= 1;
        if (len == 0) break;
    }
    return res >> 1;
}

fn genCodes(tree: []Node, max_code: usize, bl_count: *const [max_bits + 1]u16) void {
    var next_code: [max_bits + 1]u16 = undefined;
    var code: u32 = 0;
    var bits: usize = 1;
    while (bits <= max_bits) : (bits += 1) {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = @truncate(code);
    }
    var n: usize = 0;
    while (n <= max_code) : (n += 1) {
        const len = tree[n].len;
        if (len == 0) continue;
        tree[n].code = @intCast(biReverse(next_code[len], len));
        next_code[len] +%= 1;
    }
}

fn dCode(dist: u32) u8 {
    return if (dist < 256) static.dist_code[dist] else static.dist_code[256 + (dist >> 7)];
}

/// The parameters of one compression level (deflate.c's configuration_table).
const Config = struct {
    good_length: u16,
    max_lazy: u16,
    nice_length: u16,
    max_chain: u16,
    func: enum { stored, fast, slow },
};

const configuration_table = [10]Config{
    .{ .good_length = 0, .max_lazy = 0, .nice_length = 0, .max_chain = 0, .func = .stored },
    .{ .good_length = 4, .max_lazy = 4, .nice_length = 8, .max_chain = 4, .func = .fast },
    .{ .good_length = 4, .max_lazy = 5, .nice_length = 16, .max_chain = 8, .func = .fast },
    .{ .good_length = 4, .max_lazy = 6, .nice_length = 32, .max_chain = 32, .func = .fast },
    .{ .good_length = 4, .max_lazy = 4, .nice_length = 16, .max_chain = 16, .func = .slow },
    .{ .good_length = 8, .max_lazy = 16, .nice_length = 32, .max_chain = 32, .func = .slow },
    .{ .good_length = 8, .max_lazy = 16, .nice_length = 128, .max_chain = 128, .func = .slow },
    .{ .good_length = 8, .max_lazy = 32, .nice_length = 128, .max_chain = 256, .func = .slow },
    .{ .good_length = 32, .max_lazy = 128, .nice_length = 258, .max_chain = 1024, .func = .slow },
    .{ .good_length = 32, .max_lazy = 258, .nice_length = 258, .max_chain = 4096, .func = .slow },
};

const BlockState = enum { need_more, block_done, finish_started, finish_done };

const TreeDesc = struct {
    max_code: i32 = 0,
    kind: enum { l, d, bl },
};

pub const Result = struct {
    /// Bytes written to the output.
    written: usize,
    /// The stream is complete (zlib's Z_STREAM_END).
    stream_end: bool,
};

/// A raw DEFLATE stream (zlib's deflate_state with windowBits -15).
pub const Stream = struct {
    gpa: Allocator,

    // z_stream
    input: []const u8 = &.{},
    in_pos: usize = 0,
    out: []u8 = &.{},
    out_pos: usize = 0,
    total_in: u64 = 0,
    total_out: u64 = 0,

    finishing: bool = false,
    last_flush: i32 = -2,

    pending: std.ArrayList(u8) = .empty,
    pending_out: usize = 0,

    window: []u8,
    prev: []u16,
    head: []u16,
    ins_h: u32 = 0,

    block_start: i64 = 0,
    match_length: u32 = min_match - 1,
    prev_match: u32 = 0,
    match_available: bool = false,
    strstart: u32 = 0,
    match_start: u32 = 0,
    lookahead: u32 = 0,
    prev_length: u32 = min_match - 1,
    max_chain_length: u32,
    max_lazy_match: u32,
    level: u32,
    good_match: u32,
    nice_match: u32,

    dyn_ltree: [heap_size]Node = [_]Node{.{}} ** heap_size,
    dyn_dtree: [2 * d_codes + 1]Node = [_]Node{.{}} ** (2 * d_codes + 1),
    bl_tree: [2 * bl_codes + 1]Node = [_]Node{.{}} ** (2 * bl_codes + 1),
    l_desc: TreeDesc = .{ .kind = .l },
    d_desc: TreeDesc = .{ .kind = .d },
    bl_desc: TreeDesc = .{ .kind = .bl },

    bl_count: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1),
    heap: [2 * l_codes + 1]i32 = [_]i32{0} ** (2 * l_codes + 1),
    heap_len: i32 = 0,
    heap_max: i32 = 0,
    depth: [2 * l_codes + 1]u8 = [_]u8{0} ** (2 * l_codes + 1),

    sym_buf: []u8,
    sym_next: u32 = 0,
    opt_len: u64 = 0,
    static_len: u64 = 0,
    matches: u32 = 0,
    insert: u32 = 0,

    bi_buf: u16 = 0,
    bi_valid: i32 = 0,
    high_water: u64 = 0,

    /// A stream at `level` (-1 is zlib's default, 6). The caller owns the
    /// result and frees it with `destroy`.
    pub fn create(gpa: Allocator, level_in: i32) error{ OutOfMemory, InvalidLevel }!*Stream {
        const level: u32 = if (level_in == -1) 6 else if (level_in >= 0 and level_in <= 9) @intCast(level_in) else return error.InvalidLevel;
        const window = try gpa.alloc(u8, window_size);
        errdefer gpa.free(window);
        const prev = try gpa.alloc(u16, w_size);
        errdefer gpa.free(prev);
        const head = try gpa.alloc(u16, hash_size);
        errdefer gpa.free(head);
        const sym_buf = try gpa.alloc(u8, lit_bufsize * 3);
        errdefer gpa.free(sym_buf);
        const s = try gpa.create(Stream);
        const cfg = configuration_table[level];
        s.* = .{
            .gpa = gpa,
            .window = window,
            .prev = prev,
            .head = head,
            .sym_buf = sym_buf,
            .level = level,
            .max_lazy_match = cfg.max_lazy,
            .good_match = cfg.good_length,
            .nice_match = cfg.nice_length,
            .max_chain_length = cfg.max_chain,
        };
        // zlib leaves the window uninitialized and never reads a byte it
        // has not written (the high-water mark below); zeroing is the same.
        @memset(window, 0);
        @memset(prev, 0);
        @memset(head, 0);
        s.initBlock();
        return s;
    }

    pub fn destroy(s: *Stream) void {
        const gpa = s.gpa;
        s.pending.deinit(gpa);
        gpa.free(s.window);
        gpa.free(s.prev);
        gpa.free(s.head);
        gpa.free(s.sym_buf);
        gpa.destroy(s);
    }

    fn availIn(s: *const Stream) usize {
        return s.input.len - s.in_pos;
    }

    fn availOut(s: *const Stream) usize {
        return s.out.len - s.out_pos;
    }

    fn pendingLen(s: *const Stream) usize {
        return s.pending.items.len - s.pending_out;
    }

    /// zlib's `deflate(strm, flush)` over `input`, from `in_pos`, into `out`.
    pub fn deflate(s: *Stream, input: []const u8, in_pos: *usize, out: []u8, flush: Flush) Allocator.Error!Result {
        s.input = input;
        s.in_pos = in_pos.*;
        s.out = out;
        s.out_pos = 0;
        defer {
            in_pos.* = s.in_pos;
            s.input = &.{};
            s.in_pos = 0;
            s.out = &.{};
        }
        const f: i32 = @intFromEnum(flush);
        if (s.finishing and flush != .finish) return .{ .written = 0, .stream_end = false };
        if (s.availOut() == 0) return .{ .written = 0, .stream_end = false };

        const old_flush = s.last_flush;
        s.last_flush = f;

        if (s.pendingLen() != 0) {
            s.flushPending();
            if (s.availOut() == 0) {
                s.last_flush = -1;
                return .{ .written = s.out_pos, .stream_end = false };
            }
        } else if (s.availIn() == 0 and rank(f) <= rank(old_flush) and flush != .finish) {
            return .{ .written = s.out_pos, .stream_end = false };
        }

        if (s.finishing and s.availIn() != 0) return .{ .written = s.out_pos, .stream_end = false };

        if (s.availIn() != 0 or s.lookahead != 0 or (flush != .none and !s.finishing)) {
            const bstate: BlockState = switch (configuration_table[s.level].func) {
                .stored => try s.deflateStored(flush),
                .fast => try s.deflateFast(flush),
                .slow => try s.deflateSlow(flush),
            };
            if (bstate == .finish_started or bstate == .finish_done) s.finishing = true;
            if (bstate == .need_more or bstate == .finish_started) {
                if (s.availOut() == 0) s.last_flush = -1;
                return .{ .written = s.out_pos, .stream_end = false };
            }
            if (bstate == .block_done) {
                if (flush == .partial) {
                    try s.trAlign();
                } else if (flush != .block) {
                    try s.trStoredBlock(null, 0, false);
                    if (flush == .full) {
                        @memset(s.head, 0);
                        if (s.lookahead == 0) {
                            s.strstart = 0;
                            s.block_start = 0;
                            s.insert = 0;
                        }
                    }
                }
                s.flushPending();
                if (s.availOut() == 0) {
                    s.last_flush = -1;
                    return .{ .written = s.out_pos, .stream_end = false };
                }
            }
        }
        if (flush != .finish) return .{ .written = s.out_pos, .stream_end = false };
        return .{ .written = s.out_pos, .stream_end = true };
    }

    fn rank(f: i32) i32 {
        return f * 2 - (if (f > 4) @as(i32, 9) else 0);
    }

    // ---- output ---------------------------------------------------------------

    fn putByte(s: *Stream, c: u8) Allocator.Error!void {
        try s.pending.append(s.gpa, c);
    }

    fn putShort(s: *Stream, w: u16) Allocator.Error!void {
        try s.putByte(@truncate(w));
        try s.putByte(@truncate(w >> 8));
    }

    fn sendBits(s: *Stream, value: u32, length: i32) Allocator.Error!void {
        if (s.bi_valid > buf_size - length) {
            // C promotes the ush to int before the shift, so a shift by 16
            // leaves nothing in the 16-bit buffer.
            const val: u16 = @truncate(value);
            s.bi_buf |= @truncate(@as(u32, val) << @intCast(s.bi_valid));
            try s.putShort(s.bi_buf);
            s.bi_buf = @truncate(@as(u32, val) >> @intCast(buf_size - s.bi_valid));
            s.bi_valid += length - buf_size;
        } else {
            s.bi_buf |= @truncate(value << @intCast(s.bi_valid));
            s.bi_valid += length;
        }
    }

    fn sendCode(s: *Stream, c: usize, tree: []const Node) Allocator.Error!void {
        try s.sendBits(tree[c].code, tree[c].len);
    }

    fn biFlush(s: *Stream) Allocator.Error!void {
        if (s.bi_valid == 16) {
            try s.putShort(s.bi_buf);
            s.bi_buf = 0;
            s.bi_valid = 0;
        } else if (s.bi_valid >= 8) {
            try s.putByte(@truncate(s.bi_buf));
            s.bi_buf >>= 8;
            s.bi_valid -= 8;
        }
    }

    fn biWindup(s: *Stream) Allocator.Error!void {
        if (s.bi_valid > 8) {
            try s.putShort(s.bi_buf);
        } else if (s.bi_valid > 0) {
            try s.putByte(@truncate(s.bi_buf));
        }
        s.bi_buf = 0;
        s.bi_valid = 0;
    }

    /// Copies as much pending output as fits. A failed allocation cannot
    /// happen here: bi_flush's bytes are appended before the copy, and the
    /// list only shrinks afterwards.
    fn flushPending(s: *Stream) void {
        s.biFlush() catch {};
        var len = s.pendingLen();
        if (len > s.availOut()) len = s.availOut();
        if (len == 0) return;
        @memcpy(s.out[s.out_pos..][0..len], s.pending.items[s.pending_out..][0..len]);
        s.out_pos += len;
        s.pending_out += len;
        s.total_out += len;
        if (s.pendingLen() == 0) {
            s.pending.clearRetainingCapacity();
            s.pending_out = 0;
        }
    }

    fn readBuf(s: *Stream, dest: []u8) u32 {
        const len = @min(s.availIn(), dest.len);
        if (len == 0) return 0;
        @memcpy(dest[0..len], s.input[s.in_pos..][0..len]);
        s.in_pos += len;
        s.total_in += len;
        return @intCast(len);
    }

    // ---- matching (deflate.c) -------------------------------------------------

    inline fn updateHash(s: *Stream, c: u8) void {
        s.ins_h = ((s.ins_h << hash_shift) ^ c) & hash_mask;
    }

    /// INSERT_STRING: returns the previous head of the string's chain.
    inline fn insertString(s: *Stream, str: u32) u32 {
        s.updateHash(s.window[str + (min_match - 1)]);
        const head = s.head[s.ins_h];
        s.prev[str & w_mask] = head;
        s.head[s.ins_h] = @intCast(str);
        return head;
    }

    fn slideHash(s: *Stream) void {
        for (s.head) |*p| p.* = if (p.* >= w_size) @intCast(p.* - w_size) else @intCast(nil);
        for (s.prev) |*p| p.* = if (p.* >= w_size) @intCast(p.* - w_size) else @intCast(nil);
    }

    fn fillWindow(s: *Stream) void {
        while (true) {
            var more: u32 = window_size - s.lookahead - s.strstart;
            if (s.strstart >= w_size + max_dist) {
                const keep = w_size - more;
                std.mem.copyForwards(u8, s.window[0..keep], s.window[w_size..][0..keep]);
                s.match_start -%= w_size;
                s.strstart -= w_size;
                s.block_start -= w_size;
                if (s.insert > s.strstart) s.insert = s.strstart;
                s.slideHash();
                more += w_size;
            }
            if (s.availIn() == 0) break;

            const n = s.readBuf(s.window[s.strstart + s.lookahead ..][0..more]);
            s.lookahead += n;

            if (s.lookahead + s.insert >= min_match) {
                var str = s.strstart - s.insert;
                s.ins_h = s.window[str];
                s.updateHash(s.window[str + 1]);
                while (s.insert != 0) {
                    s.updateHash(s.window[str + min_match - 1]);
                    s.prev[str & w_mask] = s.head[s.ins_h];
                    s.head[s.ins_h] = @intCast(str);
                    str += 1;
                    s.insert -= 1;
                    if (s.lookahead + s.insert < min_match) break;
                }
            }
            if (!(s.lookahead < min_lookahead and s.availIn() != 0)) break;
        }

        if (s.high_water < window_size) {
            const curr: u64 = @as(u64, s.strstart) + s.lookahead;
            if (s.high_water < curr) {
                var init: u64 = window_size - curr;
                if (init > win_init) init = win_init;
                @memset(s.window[@intCast(curr)..][0..@intCast(init)], 0);
                s.high_water = curr + init;
            } else if (s.high_water < curr + win_init) {
                var init: u64 = curr + win_init - s.high_water;
                if (init > window_size - s.high_water) init = window_size - s.high_water;
                @memset(s.window[@intCast(s.high_water)..][0..@intCast(init)], 0);
                s.high_water += init;
            }
        }
    }

    fn longestMatch(s: *Stream, cur_match_in: u32) u32 {
        var cur_match = cur_match_in;
        var chain_length: u32 = s.max_chain_length;
        const scan = s.strstart;
        var best_len: u32 = s.prev_length;
        var nice_match: u32 = s.nice_match;
        const limit: u32 = if (s.strstart > max_dist) s.strstart - max_dist else nil;
        const win = s.window;
        var scan_end1 = win[scan + best_len - 1];
        var scan_end = win[scan + best_len];

        if (s.prev_length >= s.good_match) chain_length >>= 2;
        if (nice_match > s.lookahead) nice_match = s.lookahead;

        while (true) {
            const match = cur_match;
            if (win[match + best_len] == scan_end and
                win[match + best_len - 1] == scan_end1 and
                win[match] == win[scan] and
                win[match + 1] == win[scan + 1])
            {
                // scan[2] and match[2] are equal whenever the hash keys are
                // and the first two bytes are, so zlib does not compare them.
                var len: u32 = 3;
                while (len < max_match and win[scan + len] == win[match + len]) len += 1;
                if (len > best_len) {
                    s.match_start = cur_match;
                    best_len = len;
                    if (len >= nice_match) break;
                    scan_end1 = win[scan + best_len - 1];
                    scan_end = win[scan + best_len];
                }
            }
            cur_match = s.prev[cur_match & w_mask];
            if (cur_match <= limit) break;
            chain_length -= 1;
            if (chain_length == 0) break;
        }

        if (best_len <= s.lookahead) return best_len;
        return s.lookahead;
    }

    // ---- block flushing -------------------------------------------------------

    fn flushBlockOnly(s: *Stream, last: bool) Allocator.Error!void {
        const len: u64 = @intCast(@as(i64, s.strstart) - s.block_start);
        const buf: ?[]const u8 = if (s.block_start >= 0) s.window[@intCast(s.block_start)..] else null;
        try s.trFlushBlock(buf, len, last);
        s.block_start = s.strstart;
        s.flushPending();
    }

    fn tallyLit(s: *Stream, c: u8) bool {
        s.sym_buf[s.sym_next] = 0;
        s.sym_buf[s.sym_next + 1] = 0;
        s.sym_buf[s.sym_next + 2] = c;
        s.sym_next += 3;
        s.dyn_ltree[c].freq +%= 1;
        return s.sym_next == sym_end;
    }

    fn tallyDist(s: *Stream, distance: u32, length: u32) bool {
        const len: u8 = @truncate(length);
        const dist: u16 = @truncate(distance);
        s.sym_buf[s.sym_next] = @truncate(dist);
        s.sym_buf[s.sym_next + 1] = @truncate(dist >> 8);
        s.sym_buf[s.sym_next + 2] = len;
        s.sym_next += 3;
        s.dyn_ltree[@as(usize, static.length_code[len]) + literals + 1].freq +%= 1;
        s.dyn_dtree[dCode(dist - 1)].freq +%= 1;
        return s.sym_next == sym_end;
    }

    fn deflateFast(s: *Stream, flush: Flush) Allocator.Error!BlockState {
        while (true) {
            if (s.lookahead < min_lookahead) {
                s.fillWindow();
                if (s.lookahead < min_lookahead and flush == .none) return .need_more;
                if (s.lookahead == 0) break;
            }

            var hash_head: u32 = nil;
            if (s.lookahead >= min_match) hash_head = s.insertString(s.strstart);

            if (hash_head != nil and s.strstart - hash_head <= max_dist) {
                s.match_length = s.longestMatch(hash_head);
            }
            var bflush: bool = undefined;
            if (s.match_length >= min_match) {
                bflush = s.tallyDist(s.strstart - s.match_start, s.match_length - min_match);
                s.lookahead -= s.match_length;
                if (s.match_length <= s.max_lazy_match and s.lookahead >= min_match) {
                    s.match_length -= 1;
                    while (true) {
                        s.strstart += 1;
                        _ = s.insertString(s.strstart);
                        s.match_length -= 1;
                        if (s.match_length == 0) break;
                    }
                    s.strstart += 1;
                } else {
                    s.strstart += s.match_length;
                    s.match_length = 0;
                    s.ins_h = s.window[s.strstart];
                    s.updateHash(s.window[s.strstart + 1]);
                }
            } else {
                bflush = s.tallyLit(s.window[s.strstart]);
                s.lookahead -= 1;
                s.strstart += 1;
            }
            if (bflush) {
                try s.flushBlockOnly(false);
                if (s.availOut() == 0) return .need_more;
            }
        }
        s.insert = if (s.strstart < min_match - 1) s.strstart else min_match - 1;
        if (flush == .finish) {
            try s.flushBlockOnly(true);
            if (s.availOut() == 0) return .finish_started;
            return .finish_done;
        }
        if (s.sym_next != 0) {
            try s.flushBlockOnly(false);
            if (s.availOut() == 0) return .need_more;
        }
        return .block_done;
    }

    fn deflateSlow(s: *Stream, flush: Flush) Allocator.Error!BlockState {
        while (true) {
            if (s.lookahead < min_lookahead) {
                s.fillWindow();
                if (s.lookahead < min_lookahead and flush == .none) return .need_more;
                if (s.lookahead == 0) break;
            }

            var hash_head: u32 = nil;
            if (s.lookahead >= min_match) hash_head = s.insertString(s.strstart);

            s.prev_length = s.match_length;
            s.prev_match = s.match_start;
            s.match_length = min_match - 1;

            if (hash_head != nil and s.prev_length < s.max_lazy_match and s.strstart - hash_head <= max_dist) {
                s.match_length = s.longestMatch(hash_head);
                if (s.match_length <= 5 and (s.match_length == min_match and s.strstart - s.match_start > too_far)) {
                    s.match_length = min_match - 1;
                }
            }

            if (s.prev_length >= min_match and s.match_length <= s.prev_length) {
                const max_insert = s.strstart + s.lookahead - min_match;
                const bflush = s.tallyDist(s.strstart - 1 - s.prev_match, s.prev_length - min_match);
                s.lookahead -= s.prev_length - 1;
                s.prev_length -= 2;
                while (true) {
                    s.strstart += 1;
                    if (s.strstart <= max_insert) _ = s.insertString(s.strstart);
                    s.prev_length -= 1;
                    if (s.prev_length == 0) break;
                }
                s.match_available = false;
                s.match_length = min_match - 1;
                s.strstart += 1;
                if (bflush) {
                    try s.flushBlockOnly(false);
                    if (s.availOut() == 0) return .need_more;
                }
            } else if (s.match_available) {
                if (s.tallyLit(s.window[s.strstart - 1])) try s.flushBlockOnly(false);
                s.strstart += 1;
                s.lookahead -= 1;
                if (s.availOut() == 0) return .need_more;
            } else {
                s.match_available = true;
                s.strstart += 1;
                s.lookahead -= 1;
            }
        }
        if (s.match_available) {
            _ = s.tallyLit(s.window[s.strstart - 1]);
            s.match_available = false;
        }
        s.insert = if (s.strstart < min_match - 1) s.strstart else min_match - 1;
        if (flush == .finish) {
            try s.flushBlockOnly(true);
            if (s.availOut() == 0) return .finish_started;
            return .finish_done;
        }
        if (s.sym_next != 0) {
            try s.flushBlockOnly(false);
            if (s.availOut() == 0) return .need_more;
        }
        return .block_done;
    }

    fn deflateStored(s: *Stream, flush: Flush) Allocator.Error!BlockState {
        var min_block: u32 = @min(pending_buf_size - 5, w_size);
        var last = false;
        var len: u32 = undefined;
        var left: u32 = undefined;
        var have: u32 = undefined;
        var used: usize = s.availIn();
        while (true) {
            len = max_stored;
            have = @intCast((s.bi_valid + 42) >> 3);
            if (s.availOut() < have) break;
            have = @intCast(s.availOut() - have);
            left = @intCast(@as(i64, s.strstart) - s.block_start);
            if (len > @as(u64, left) + s.availIn()) len = @intCast(left + s.availIn());
            if (len > have) len = have;

            if (len < min_block and ((len == 0 and flush != .finish) or
                flush == .none or
                len != left + s.availIn()))
                break;

            last = flush == .finish and len == left + s.availIn();
            try s.trStoredBlock(null, 0, last);

            const p = s.pending.items;
            p[p.len - 4] = @truncate(len);
            p[p.len - 3] = @truncate(len >> 8);
            p[p.len - 2] = @truncate(~len);
            p[p.len - 1] = @truncate(~len >> 8);

            s.flushPending();

            if (left != 0) {
                if (left > len) left = len;
                const from: usize = @intCast(s.block_start);
                @memcpy(s.out[s.out_pos..][0..left], s.window[from..][0..left]);
                s.out_pos += left;
                s.total_out += left;
                s.block_start += left;
                len -= left;
            }
            if (len != 0) {
                const n = s.readBuf(s.out[s.out_pos..][0..len]);
                s.out_pos += n;
                s.total_out += n;
            }
            if (last) break;
        }

        used -= s.availIn();
        if (used != 0) {
            if (used >= w_size) {
                s.matches = 2;
                @memcpy(s.window[0..w_size], s.input[s.in_pos - w_size ..][0..w_size]);
                s.strstart = w_size;
                s.insert = s.strstart;
            } else {
                if (window_size - s.strstart <= used) {
                    s.strstart -= w_size;
                    std.mem.copyForwards(u8, s.window[0..s.strstart], s.window[w_size..][0..s.strstart]);
                    if (s.matches < 2) s.matches += 1;
                    if (s.insert > s.strstart) s.insert = s.strstart;
                }
                const u: u32 = @intCast(used);
                @memcpy(s.window[s.strstart..][0..u], s.input[s.in_pos - u ..][0..u]);
                s.strstart += u;
                s.insert += @min(u, w_size - s.insert);
            }
            s.block_start = s.strstart;
        }
        if (s.high_water < s.strstart) s.high_water = s.strstart;

        if (last) return .finish_done;

        if (flush != .none and flush != .finish and s.availIn() == 0 and @as(i64, s.strstart) == s.block_start)
            return .block_done;

        have = window_size - s.strstart;
        if (s.availIn() > have and s.block_start >= w_size) {
            s.block_start -= w_size;
            s.strstart -= w_size;
            std.mem.copyForwards(u8, s.window[0..s.strstart], s.window[w_size..][0..s.strstart]);
            if (s.matches < 2) s.matches += 1;
            have += w_size;
            if (s.insert > s.strstart) s.insert = s.strstart;
        }
        if (have > s.availIn()) have = @intCast(s.availIn());
        if (have != 0) {
            _ = s.readBuf(s.window[s.strstart..][0..have]);
            s.strstart += have;
            s.insert += @min(have, w_size - s.insert);
        }
        if (s.high_water < s.strstart) s.high_water = s.strstart;

        have = @intCast((s.bi_valid + 42) >> 3);
        have = @min(pending_buf_size - have, max_stored);
        min_block = @min(have, w_size);
        left = @intCast(@as(i64, s.strstart) - s.block_start);
        if (left >= min_block or
            ((left != 0 or flush == .finish) and flush != .none and s.availIn() == 0 and left <= have))
        {
            len = @min(left, have);
            last = flush == .finish and s.availIn() == 0 and len == left;
            try s.trStoredBlock(s.window[@intCast(s.block_start)..], len, last);
            s.block_start += len;
            s.flushPending();
        }
        return if (last) .finish_started else .need_more;
    }

    // ---- trees (trees.c) ------------------------------------------------------

    fn initBlock(s: *Stream) void {
        for (s.dyn_ltree[0..l_codes]) |*n| n.freq = 0;
        for (s.dyn_dtree[0..d_codes]) |*n| n.freq = 0;
        for (s.bl_tree[0..bl_codes]) |*n| n.freq = 0;
        s.dyn_ltree[end_block].freq = 1;
        s.opt_len = 0;
        s.static_len = 0;
        s.sym_next = 0;
        s.matches = 0;
    }

    fn treeOf(s: *Stream, desc: *const TreeDesc) []Node {
        return switch (desc.kind) {
            .l => &s.dyn_ltree,
            .d => &s.dyn_dtree,
            .bl => &s.bl_tree,
        };
    }

    fn smaller(s: *const Stream, tree: []const Node, n: i32, m: i32) bool {
        const nf = tree[@intCast(n)].freq;
        const mf = tree[@intCast(m)].freq;
        return nf < mf or (nf == mf and s.depth[@intCast(n)] <= s.depth[@intCast(m)]);
    }

    fn pqdownheap(s: *Stream, tree: []const Node, k_in: i32) void {
        var k = k_in;
        const v = s.heap[@intCast(k)];
        var j = k << 1;
        while (j <= s.heap_len) {
            if (j < s.heap_len and s.smaller(tree, s.heap[@intCast(j + 1)], s.heap[@intCast(j)])) j += 1;
            if (s.smaller(tree, v, s.heap[@intCast(j)])) break;
            s.heap[@intCast(k)] = s.heap[@intCast(j)];
            k = j;
            j <<= 1;
        }
        s.heap[@intCast(k)] = v;
    }

    fn genBitlen(s: *Stream, desc: *const TreeDesc) void {
        const tree = s.treeOf(desc);
        const max_code = desc.max_code;
        const stree: ?[]const Node = switch (desc.kind) {
            .l => &static.ltree,
            .d => &static.dtree,
            .bl => null,
        };
        const extra: []const u8 = switch (desc.kind) {
            .l => &extra_lbits,
            .d => &extra_dbits,
            .bl => &extra_blbits,
        };
        const base: i32 = if (desc.kind == .l) literals + 1 else 0;
        const max_length: u16 = if (desc.kind == .bl) max_bl_bits else max_bits;
        var overflow: i32 = 0;

        for (&s.bl_count) |*c| c.* = 0;

        tree[@intCast(s.heap[@intCast(s.heap_max)])].len = 0;

        var h: i32 = s.heap_max + 1;
        while (h < heap_size) : (h += 1) {
            const n = s.heap[@intCast(h)];
            var bits: u16 = tree[tree[@intCast(n)].dad].len + 1;
            if (bits > max_length) {
                bits = max_length;
                overflow += 1;
            }
            tree[@intCast(n)].len = bits;
            if (n > max_code) continue;

            s.bl_count[bits] += 1;
            var xbits: u32 = 0;
            if (n >= base) xbits = extra[@intCast(n - base)];
            const f: u64 = tree[@intCast(n)].freq;
            s.opt_len +%= f * (bits + xbits);
            if (stree) |st| s.static_len +%= f * (st[@intCast(n)].len + xbits);
        }
        if (overflow == 0) return;

        while (true) {
            var bits: usize = max_length - 1;
            while (s.bl_count[bits] == 0) bits -= 1;
            s.bl_count[bits] -= 1;
            s.bl_count[bits + 1] += 2;
            s.bl_count[max_length] -= 1;
            overflow -= 2;
            if (overflow <= 0) break;
        }

        var bits: u16 = max_length;
        while (bits != 0) : (bits -= 1) {
            var n: u32 = s.bl_count[bits];
            while (n != 0) {
                h -= 1;
                const m = s.heap[@intCast(h)];
                if (m > max_code) continue;
                if (tree[@intCast(m)].len != bits) {
                    s.opt_len +%= (@as(u64, bits) -% tree[@intCast(m)].len) *% tree[@intCast(m)].freq;
                    tree[@intCast(m)].len = bits;
                }
                n -= 1;
            }
        }
    }

    fn buildTree(s: *Stream, desc: *TreeDesc) void {
        const tree = s.treeOf(desc);
        const stree: ?[]const Node = switch (desc.kind) {
            .l => &static.ltree,
            .d => &static.dtree,
            .bl => null,
        };
        const elems: i32 = switch (desc.kind) {
            .l => l_codes,
            .d => d_codes,
            .bl => bl_codes,
        };
        var max_code: i32 = -1;

        s.heap_len = 0;
        s.heap_max = heap_size;

        var n: i32 = 0;
        while (n < elems) : (n += 1) {
            if (tree[@intCast(n)].freq != 0) {
                s.heap_len += 1;
                s.heap[@intCast(s.heap_len)] = n;
                max_code = n;
                s.depth[@intCast(n)] = 0;
            } else {
                tree[@intCast(n)].len = 0;
                tree[@intCast(n)].dad = 0;
            }
        }

        while (s.heap_len < 2) {
            const node: i32 = if (max_code < 2) blk: {
                max_code += 1;
                break :blk max_code;
            } else 0;
            s.heap_len += 1;
            s.heap[@intCast(s.heap_len)] = node;
            tree[@intCast(node)].freq = 1;
            s.depth[@intCast(node)] = 0;
            s.opt_len -%= 1;
            if (stree) |st| s.static_len -%= st[@intCast(node)].len;
        }
        desc.max_code = max_code;

        n = @divTrunc(s.heap_len, 2);
        while (n >= 1) : (n -= 1) s.pqdownheap(tree, n);

        var node: i32 = elems;
        while (true) {
            // pqremove
            n = s.heap[1];
            s.heap[1] = s.heap[@intCast(s.heap_len)];
            s.heap_len -= 1;
            s.pqdownheap(tree, 1);
            const m = s.heap[1];

            s.heap_max -= 1;
            s.heap[@intCast(s.heap_max)] = n;
            s.heap_max -= 1;
            s.heap[@intCast(s.heap_max)] = m;

            tree[@intCast(node)].freq = tree[@intCast(n)].freq +% tree[@intCast(m)].freq;
            const dn = s.depth[@intCast(n)];
            const dm = s.depth[@intCast(m)];
            s.depth[@intCast(node)] = (if (dn >= dm) dn else dm) + 1;
            tree[@intCast(n)].dad = @intCast(node);
            tree[@intCast(m)].dad = @intCast(node);
            s.heap[1] = node;
            node += 1;
            s.pqdownheap(tree, 1);
            if (s.heap_len < 2) break;
        }

        s.heap_max -= 1;
        s.heap[@intCast(s.heap_max)] = s.heap[1];

        s.genBitlen(desc);
        genCodes(tree, @intCast(max_code), &s.bl_count);
    }

    fn scanTree(s: *Stream, tree: []Node, max_code: i32) void {
        var prevlen: i32 = -1;
        var nextlen: i32 = tree[0].len;
        var count: i32 = 0;
        var max_count: i32 = 7;
        var min_count: i32 = 4;

        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        }
        tree[@intCast(max_code + 1)].len = 0xffff;

        var n: i32 = 0;
        while (n <= max_code) : (n += 1) {
            const curlen = nextlen;
            nextlen = tree[@intCast(n + 1)].len;
            count += 1;
            if (count < max_count and curlen == nextlen) {
                continue;
            } else if (count < min_count) {
                s.bl_tree[@intCast(curlen)].freq +%= @intCast(count);
            } else if (curlen != 0) {
                if (curlen != prevlen) s.bl_tree[@intCast(curlen)].freq +%= 1;
                s.bl_tree[rep_3_6].freq +%= 1;
            } else if (count <= 10) {
                s.bl_tree[repz_3_10].freq +%= 1;
            } else {
                s.bl_tree[repz_11_138].freq +%= 1;
            }
            count = 0;
            prevlen = curlen;
            if (nextlen == 0) {
                max_count = 138;
                min_count = 3;
            } else if (curlen == nextlen) {
                max_count = 6;
                min_count = 3;
            } else {
                max_count = 7;
                min_count = 4;
            }
        }
    }

    fn sendTree(s: *Stream, tree: []const Node, max_code: i32) Allocator.Error!void {
        var prevlen: i32 = -1;
        var nextlen: i32 = tree[0].len;
        var count: i32 = 0;
        var max_count: i32 = 7;
        var min_count: i32 = 4;

        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        }

        var n: i32 = 0;
        while (n <= max_code) : (n += 1) {
            const curlen = nextlen;
            nextlen = tree[@intCast(n + 1)].len;
            count += 1;
            if (count < max_count and curlen == nextlen) {
                continue;
            } else if (count < min_count) {
                while (true) {
                    try s.sendCode(@intCast(curlen), &s.bl_tree);
                    count -= 1;
                    if (count == 0) break;
                }
            } else if (curlen != 0) {
                if (curlen != prevlen) {
                    try s.sendCode(@intCast(curlen), &s.bl_tree);
                    count -= 1;
                }
                try s.sendCode(rep_3_6, &s.bl_tree);
                try s.sendBits(@intCast(count - 3), 2);
            } else if (count <= 10) {
                try s.sendCode(repz_3_10, &s.bl_tree);
                try s.sendBits(@intCast(count - 3), 3);
            } else {
                try s.sendCode(repz_11_138, &s.bl_tree);
                try s.sendBits(@intCast(count - 11), 7);
            }
            count = 0;
            prevlen = curlen;
            if (nextlen == 0) {
                max_count = 138;
                min_count = 3;
            } else if (curlen == nextlen) {
                max_count = 6;
                min_count = 3;
            } else {
                max_count = 7;
                min_count = 4;
            }
        }
    }

    fn buildBlTree(s: *Stream) i32 {
        s.scanTree(&s.dyn_ltree, s.l_desc.max_code);
        s.scanTree(&s.dyn_dtree, s.d_desc.max_code);
        s.buildTree(&s.bl_desc);
        var max_blindex: i32 = bl_codes - 1;
        while (max_blindex >= 3) : (max_blindex -= 1) {
            if (s.bl_tree[bl_order[@intCast(max_blindex)]].len != 0) break;
        }
        s.opt_len +%= 3 * (@as(u64, @intCast(max_blindex)) + 1) + 5 + 5 + 4;
        return max_blindex;
    }

    fn sendAllTrees(s: *Stream, lcodes: i32, dcodes: i32, blcodes: i32) Allocator.Error!void {
        try s.sendBits(@intCast(lcodes - 257), 5);
        try s.sendBits(@intCast(dcodes - 1), 5);
        try s.sendBits(@intCast(blcodes - 4), 4);
        var r: usize = 0;
        while (r < blcodes) : (r += 1) {
            try s.sendBits(s.bl_tree[bl_order[r]].len, 3);
        }
        try s.sendTree(&s.dyn_ltree, lcodes - 1);
        try s.sendTree(&s.dyn_dtree, dcodes - 1);
    }

    fn compressBlock(s: *Stream, ltree: []const Node, dtree: []const Node) Allocator.Error!void {
        var sx: u32 = 0;
        if (s.sym_next != 0) while (true) {
            var dist: u32 = s.sym_buf[sx];
            dist += @as(u32, s.sym_buf[sx + 1]) << 8;
            var lc: u32 = s.sym_buf[sx + 2];
            sx += 3;
            if (dist == 0) {
                try s.sendCode(lc, ltree);
            } else {
                var code: u32 = static.length_code[lc];
                try s.sendCode(code + literals + 1, ltree);
                var extra: u32 = extra_lbits[code];
                if (extra != 0) {
                    lc -= static.base_length[code];
                    try s.sendBits(lc, @intCast(extra));
                }
                dist -= 1;
                code = dCode(dist);
                try s.sendCode(code, dtree);
                extra = extra_dbits[code];
                if (extra != 0) {
                    dist -= static.base_dist[code];
                    try s.sendBits(dist, @intCast(extra));
                }
            }
            if (sx >= s.sym_next) break;
        };
        try s.sendCode(end_block, ltree);
    }

    fn trStoredBlock(s: *Stream, buf: ?[]const u8, stored_len: u32, last: bool) Allocator.Error!void {
        try s.sendBits((stored_block << 1) + @as(u32, @intFromBool(last)), 3);
        try s.biWindup();
        try s.putShort(@truncate(stored_len));
        try s.putShort(@truncate(~stored_len));
        if (stored_len != 0) try s.pending.appendSlice(s.gpa, buf.?[0..stored_len]);
    }

    fn trAlign(s: *Stream) Allocator.Error!void {
        try s.sendBits(static_trees << 1, 3);
        try s.sendCode(end_block, &static.ltree);
        try s.biFlush();
    }

    fn trFlushBlock(s: *Stream, buf: ?[]const u8, stored_len: u64, last: bool) Allocator.Error!void {
        var opt_lenb: u64 = undefined;
        var static_lenb: u64 = undefined;
        var max_blindex: i32 = 0;

        if (s.level > 0) {
            s.buildTree(&s.l_desc);
            s.buildTree(&s.d_desc);
            max_blindex = s.buildBlTree();
            opt_lenb = (s.opt_len +% 3 +% 7) >> 3;
            static_lenb = (s.static_len +% 3 +% 7) >> 3;
            if (static_lenb <= opt_lenb) opt_lenb = static_lenb;
        } else {
            opt_lenb = stored_len + 5;
            static_lenb = opt_lenb;
        }

        if (stored_len + 4 <= opt_lenb and buf != null) {
            try s.trStoredBlock(buf, @intCast(stored_len), last);
        } else if (static_lenb == opt_lenb) {
            try s.sendBits((static_trees << 1) + @as(u32, @intFromBool(last)), 3);
            try s.compressBlock(&static.ltree, &static.dtree);
        } else {
            try s.sendBits((dyn_trees << 1) + @as(u32, @intFromBool(last)), 3);
            try s.sendAllTrees(s.l_desc.max_code + 1, s.d_desc.max_code + 1, max_blindex + 1);
            try s.compressBlock(&s.dyn_ltree, &s.dyn_dtree);
        }
        s.initBlock();
        if (last) try s.biWindup();
    }
};

/// java.util.zip.Deflater(level, nowrap = true) over a `Stream`: the input
/// set by `setInput` is consumed by `deflate` calls, each one zlib `deflate`
/// round into the caller's buffer, with FINISH once `finish` was called.
pub const Deflater = struct {
    stream: *Stream,
    input: []u8 = &.{},
    in_pos: usize = 0,
    finish_called: bool = false,
    is_finished: bool = false,

    pub fn create(gpa: Allocator, level: i32) error{ OutOfMemory, InvalidLevel }!Deflater {
        return .{ .stream = try Stream.create(gpa, level) };
    }

    pub fn destroy(d: *Deflater) void {
        const gpa = d.stream.gpa;
        gpa.free(d.input);
        d.stream.destroy();
    }

    /// Replaces the unconsumed input with a copy of `bytes`.
    pub fn setInput(d: *Deflater, bytes: []const u8) Allocator.Error!void {
        const gpa = d.stream.gpa;
        const copy = try gpa.dupe(u8, bytes);
        gpa.free(d.input);
        d.input = copy;
        d.in_pos = 0;
    }

    pub fn needsInput(d: *const Deflater) bool {
        return d.in_pos == d.input.len;
    }

    pub fn finish(d: *Deflater) void {
        d.finish_called = true;
    }

    pub fn finished(d: *const Deflater) bool {
        return d.is_finished;
    }

    pub fn totalIn(d: *const Deflater) u64 {
        return d.stream.total_in;
    }

    /// One `Deflater.deflate(out, 0, out.len, flush)` call: the bytes written.
    pub fn deflate(d: *Deflater, out: []u8, flush: Flush) Allocator.Error!usize {
        const f: Flush = if (d.finish_called) .finish else flush;
        const r = try d.stream.deflate(d.input, &d.in_pos, out, f);
        if (r.stream_end) d.is_finished = true;
        return r.written;
    }
};

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

/// The JVM encoder loop (ktor's Deflater.kt): each chunk is set as input and
/// deflated into a 4096-byte buffer until the deflater needs input, then the
/// stream is finished the same way.
fn jvmCompress(gpa: Allocator, level: i32, data: []const u8, chunk: usize) ![]u8 {
    var d = try Deflater.create(gpa, level);
    defer d.destroy();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(chunk, data.len - i);
        try d.setInput(data[i..][0..n]);
        i += n;
        while (!d.needsInput()) {
            const w = try d.deflate(&buf, .none);
            try out.appendSlice(gpa, buf[0..w]);
        }
    }
    d.finish();
    while (!d.finished()) {
        const w = try d.deflate(&buf, .none);
        try out.appendSlice(gpa, buf[0..w]);
    }
    return out.toOwnedSlice(gpa);
}

fn inflateRaw(gpa: Allocator, compressed: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .raw, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "500 bytes compress to the JVM's 276, position 0 never matching" {
    const gpa = testing.allocator;
    var data: [500]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    const out = try jvmCompress(gpa, -1, &data, 4096);
    defer gpa.free(out);
    // java.util.zip.Deflater(DEFAULT_COMPRESSION, true) on the same bytes.
    const jvm_tail = [_]u8{ 0xfd, 0x67, 0x18, 0x81, 0xfe, 0x07, 0x00 };
    try testing.expectEqual(@as(usize, 276), out.len);
    try testing.expectEqualSlices(u8, &jvm_tail, out[out.len - jvm_tail.len ..]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x63, 0x60, 0x64, 0x62 }, out[0..4]);
    const back = try inflateRaw(gpa, out);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &data, back);
}

test "every level round-trips text, binary and repeats across window slides" {
    const gpa = testing.allocator;
    const data = try gpa.alloc(u8, 200_000);
    defer gpa.free(data);
    var seed: u32 = 12345;
    for (data, 0..) |*b, i| {
        seed = seed *% 1103515245 +% 12345;
        b.* = switch ((i / 5000) % 3) {
            0 => "the quick brown fox jumps over the lazy dog "[i % 44],
            1 => @truncate(seed >> 16),
            else => @truncate((i / 7) % 13),
        };
    }
    var level: i32 = 0;
    while (level <= 9) : (level += 1) {
        for ([_]usize{ 4096, 1000, 200_000 }) |chunk| {
            const out = try jvmCompress(gpa, level, data, chunk);
            defer gpa.free(out);
            const back = try inflateRaw(gpa, out);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, data, back);
        }
    }
}

test "a sync flush ends at a byte boundary with the empty stored block, once" {
    const gpa = testing.allocator;
    var d = try Deflater.create(gpa, -1);
    defer d.destroy();
    var buf: [4096]u8 = undefined;
    try d.setInput("Hello");
    var w = try d.deflate(&buf, .none);
    try testing.expectEqual(@as(usize, 0), w);
    w = try d.deflate(&buf, .sync);
    // RFC 7692's "Hello" with its trailing 00 00 ff ff.
    try testing.expectEqualSlices(u8, &[_]u8{ 0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x00, 0x00, 0xff, 0xff }, buf[0..w]);
    try testing.expectEqual(@as(usize, 0), try d.deflate(&buf, .sync));
}

// The inputs of tests/fixtures/ktor/zlib/deflate_oracle.kt, built the same way.

const Lcg = struct {
    seed: u32,

    fn next(r: *Lcg) u32 {
        r.seed = r.seed *% 1103515245 +% 12345;
        return (r.seed >> 16) & 0x7fff;
    }
};

const oracle_words = [_][]const u8{
    "the",     "quick",  "brown",  "fox",     "jumps",  "over",   "lazy",    "dog",     "ktor",
    "klio",    "deflate", "window", "match",  "length", "distance", "huffman",
    "tree",    "block",  "stored", "static",  "dynamic", "literal", "symbol", "a",
    "of",      "and",    "to",     "in",      "is",     "that",   "for",     "it",      "as",
    "with",    "on",
};

fn oracleInput(gpa: Allocator, name: []const u8) ![]u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "empty")) return gpa.alloc(u8, 0);
    if (eql(u8, name, "one")) return gpa.dupe(u8, &[_]u8{42});
    if (eql(u8, name, "three")) return gpa.dupe(u8, "abc");
    if (eql(u8, name, "counting500") or eql(u8, name, "counting70k")) {
        const out = try gpa.alloc(u8, if (eql(u8, name, "counting500")) 500 else 70_000);
        for (out, 0..) |*b, i| b.* = @truncate(i);
        return out;
    }
    if (eql(u8, name, "text120k")) {
        const size = 120_000;
        var r: Lcg = .{ .seed = 1 };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (out.items.len < size) {
            try out.appendSlice(gpa, oracle_words[r.next() % oracle_words.len]);
            try out.append(gpa, if (r.next() % 13 == 0) '\n' else ' ');
        }
        out.shrinkRetainingCapacity(size);
        return out.toOwnedSlice(gpa);
    }
    if (eql(u8, name, "binary70k")) {
        var r: Lcg = .{ .seed = 2 };
        const out = try gpa.alloc(u8, 70_000);
        for (out) |*b| b.* = @truncate(r.next());
        return out;
    }
    if (eql(u8, name, "runs100k")) {
        const size = 100_000;
        var r: Lcg = .{ .seed = 3 };
        const out = try gpa.alloc(u8, size);
        var i: usize = 0;
        while (i < size) {
            const kind = r.next() % 3;
            const len = 1 + r.next() % 600;
            const period = 1 + r.next() % 40;
            const base = r.next();
            var k: u32 = 0;
            while (k < len and i < size) : (k += 1) {
                out[i] = switch (kind) {
                    0 => @truncate(base),
                    1 => @truncate(base + k % period),
                    else => @truncate(r.next()),
                };
                i += 1;
            }
        }
        return out;
    }
    unreachable;
}

/// deflate_oracle.kt's `compress`, call for call.
fn oracleCompress(gpa: Allocator, level: i32, data: []const u8, chunk: usize, out_size: usize, mode: Flush) ![]u8 {
    var d = try Deflater.create(gpa, level);
    defer d.destroy();
    const buf = try gpa.alloc(u8, out_size);
    defer gpa.free(buf);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(chunk, data.len - i);
        try d.setInput(data[i..][0..n]);
        i += n;
        while (!d.needsInput()) try out.appendSlice(gpa, buf[0..try d.deflate(buf, .none)]);
        if (mode != .none) {
            while (true) {
                const w = try d.deflate(buf, mode);
                try out.appendSlice(gpa, buf[0..w]);
                if (w == 0) break;
            }
        }
    }
    d.finish();
    while (!d.finished()) try out.appendSlice(gpa, buf[0..try d.deflate(buf, .none)]);
    return out.toOwnedSlice(gpa);
}

test "the JVM's Deflater bytes at every level, chunking, flush mode and buffer size" {
    const gpa = testing.allocator;
    const jvm = @import("zdeflate_jvm_cases.zig");
    var last_name: []const u8 = "";
    var data: []u8 = &.{};
    defer gpa.free(data);
    for (jvm.cases) |c| {
        if (!std.mem.eql(u8, c.input, last_name)) {
            gpa.free(data);
            data = &.{};
            data = try oracleInput(gpa, c.input);
            last_name = c.input;
        }
        const mode: Flush = @enumFromInt(c.mode);
        const out = try oracleCompress(gpa, c.level, data, c.chunk, c.out, mode);
        defer gpa.free(out);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (out.len != c.len or !std.mem.eql(u8, &hex, c.sha)) {
            std.debug.print("differs from the JVM: {s} level {d} chunk {d} out {d} mode {d}: {d} bytes, expected {d}\n", .{
                c.input, c.level, c.chunk, c.out, c.mode, out.len, c.len,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "invalid levels are refused" {
    try testing.expectError(error.InvalidLevel, Stream.create(testing.allocator, 10));
    try testing.expectError(error.InvalidLevel, Stream.create(testing.allocator, -2));
}
