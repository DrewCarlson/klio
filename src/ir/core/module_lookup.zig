//! The module's function and constant tables: construction, teardown,
//! lookup by id (decoding a lazily loaded function on first touch), and
//! constant interning.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_consts = @import("consts.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");

const Const = core_consts.Const;
const ConstId = core_ids.ConstId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const constHash = core_consts.constHash;

pub fn init(allocator: Allocator) Module {
    return Module{
        .lookup_cache_gpa = allocator,
        .method_dispatch = std.AutoHashMap(u64, FuncId).init(allocator),
    };
}

pub fn default(allocator: Allocator) Module {
    return Module.init(allocator);
}

pub fn deinit(self: *Module, allocator: Allocator) void {
    self.funcs.deinit(allocator);
    for (self.late_funcs.items) |f| allocator.destroy(f);
    self.late_funcs.deinit(allocator);
    self.classes.deinit(allocator);
    for (self.consts.items) |c| {
        if (c == .String) allocator.free(c.String);
    }
    self.consts.deinit(allocator);
    self.top_level.deinit(allocator);
    if (self.lookup_cache_gpa) |cg| self.const_dedup.deinit(cg);
    self.method_dispatch.deinit();
}

/// Materialise `func`'s deferred `blocks` from the lazy-IR section, clearing `deferred_offset`.
/// Decoded into the module's process-lifetime arena, so the patch outlives a per-program build.
/// A run reads a function's blocks only after this answers true: another thread may be
/// publishing them, and a plain read of `blocks` can see the new length before the pointer.
pub fn ensureFuncBody(self: *const Module, func: *Func) bool {
    // `deferred_offset` is the publication flag: it clears, with release, only after
    // `blocks` is written, so a reader that sees it clear sees the blocks.
    if (@atomicLoad(u32, &func.deferred_offset, .acquire) == 0) return func.blocks.len != 0;
    const decode = self.deferred_func_decode orelse return false;
    // The header lock serializes decode and publication.
    const mut: *Module = @constCast(self);
    while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer mut.func_header_lock.store(false, .release);
    if (func.deferred_offset == 0) return func.blocks.len != 0;
    if (decode(self.deferred_func_arena, self.deferred_func_section, func.deferred_offset - 1)) |blocks| {
        func.blocks = blocks;
        @atomicStore(u32, &func.deferred_offset, 0, .release);
    }
    return func.blocks.len != 0;
}

/// Look up a function by id. Eager build: direct table index. Lazy (loaded image, with
/// `func_header_offsets`): decode the header on first touch, memoised in `func_cache`.
pub fn funcById(self: *const Module, id: FuncId) ?*const Func {
    const i = id.int();
    const base_n: u32 = @intCast(self.func_header_offsets.len);
    // Ids at/after the lazy base range are this module's own appended funcs: dense
    // in `funcs.items` from id == base_n, then `late_funcs`.
    if (i >= base_n) {
        const j = i - base_n;
        if (j < self.funcs.items.len) return &self.funcs.items[j];
        const k = j - self.funcs.items.len;
        if (k < self.late_funcs.items.len) return self.late_funcs.items[k];
        return null;
    }
    // i < base_n: a base func owned by the shared lazy header section. Decode and memoise.
    if (i >= self.func_cache.len) return null;
    if (self.func_cache[i]) |f| return f;
    const off = self.func_header_offsets[i];
    if (off == 0) return null;
    const decode = self.func_header_decode orelse return null;
    const mut: *Module = @constCast(self);
    while (mut.func_header_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer mut.func_header_lock.store(false, .release);
    if (self.func_cache[i]) |f| return f; // lost the race
    const f = self.deferred_func_arena.create(Func) catch return null;
    f.* = decode(self.deferred_func_arena, self.func_header_section, off - 1) orelse return null;
    mut.func_cache[i] = f;
    return f;
}

/// A mutable handle to one of THIS module's own appended funcs; base funcs are immutable.
pub fn funcByIdMut(self: *Module, id: FuncId) ?*Func {
    const i = id.int();
    const base_n: u32 = @intCast(self.func_header_offsets.len);
    if (i < base_n) return null;
    const j = i - base_n;
    if (j < self.funcs.items.len) return &self.funcs.items[j];
    const k = j - self.funcs.items.len;
    if (k < self.late_funcs.items.len) return self.late_funcs.items[k];
    return null;
}

/// Append a constant and return its id; the pool is unsorted and not unique by structural equality.
/// String consts are OWNED: the bytes are duped into `allocator` and freed by `Module.deinit`.
pub fn internConst(self: *Module, allocator: Allocator, c: Const) Allocator.Error!ConstId {
    // Hash-keyed dedup over the append-only pool: the first id with a given hash wins the
    // slot (matching the scan's first match), and a colliding value falls back to the scan.
    if (self.topUpConstDedup(allocator)) {
        const h = constHash(c);
        if (self.const_dedup.get(h)) |id| {
            if (Const.eql(self.consts.items[id.int()], c)) return id;
        } else {
            const id = ConstId.from(@intCast(self.consts.items.len));
            try self.consts.ensureUnusedCapacity(allocator, 1);
            const owned: Const = switch (c) {
                .String => |s| .{ .String = try allocator.dupe(u8, s) },
                else => c,
            };
            self.consts.appendAssumeCapacity(owned);
            self.const_dedup_n = self.consts.items.len;
            try self.const_dedup.put(allocator, h, id);
            return id;
        }
    } else |_| {}
    for (self.consts.items, 0..) |k, i| {
        if (Const.eql(k, c)) return ConstId.from(@intCast(i));
    }
    const id = ConstId.from(@intCast(self.consts.items.len));
    try self.consts.ensureUnusedCapacity(allocator, 1);
    const owned: Const = switch (c) {
        .String => |s| .{ .String = try allocator.dupe(u8, s) },
        else => c,
    };
    self.consts.appendAssumeCapacity(owned);
    return id;
}

pub fn topUpConstDedup(self: *Module, gpa: Allocator) Allocator.Error!void {
    while (self.const_dedup_n < self.consts.items.len) : (self.const_dedup_n += 1) {
        const h = constHash(self.consts.items[self.const_dedup_n]);
        const gop = try self.const_dedup.getOrPut(gpa, h);
        if (!gop.found_existing) gop.value_ptr.* = ConstId.from(@intCast(self.const_dedup_n));
    }
}
