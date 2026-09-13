//! Entry into and exit out of compiled code: seeding slots from live registers, running
//! a compiled loop or function body, and converting slots back to `Value`s at a deopt.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const type_infer = @import("types.zig");
const code_cache = @import("cache.zig");

const Value = runtime.Value;
const BlockId = ir.BlockId;
const Allocator = std.mem.Allocator;

const debugEnabled = code_cache.debugEnabled;
const CompiledLoop = common.CompiledLoop;
const RETURN_INST = common.RETURN_INST;
const RegType = common.RegType;
const TrampCtx = common.TrampCtx;
const TrampFn = common.TrampFn;
const boxedElemsOf = shapes.boxedElemsOf;
const instanceClassIdentity = type_infer.instanceClassIdentity;

pub const Resume = struct { block: BlockId, inst: u32 };

pub const RunResult = union(enum) {
    resume_at: Resume,
    bail,
};

/// Caches each indexed array's buffer pointer and length in its high slots, at loop entry
/// and after every host callback: a callback runs arbitrary Kotlin that may grow the store
/// (moving the buffer) or rebind the register, and native code reads the cache behind
/// nothing but a bounds check. False when the register no longer holds the compiled-for array.
pub fn reseedArrays(self: *const CompiledLoop, regs: []const Value, slots: []i64) bool {
    for (self.arrays) |au| {
        if (au.reg.int() >= regs.len) return false;
        const v = regs[au.reg.int()];
        if (au.boxed) {
            const vl = boxedElemsOf(v) orelse return false;
            const g = vl.borrow();
            const items = g.get().items;
            g.deinit();
            slots[au.ptr_slot] = @bitCast(@intFromPtr(items.ptr));
            slots[au.len_slot] = @intCast(items.len);
            continue;
        }
        if (v != .Array or v.Array.primKind() != au.kind or v.Array.storage() != .scalars) return false;
        const g = v.Array.storage().scalars.borrow();
        const pb = g.get();
        slots[au.ptr_slot] = @bitCast(@intFromPtr(pb.bytes.items.ptr));
        slots[au.len_slot] = @intCast(pb.len());
        g.deinit();
    }
    return true;
}

pub fn runLoop(self: *const CompiledLoop, regs: []Value, slots: []i64, tags: []u8, tramp: ?TrampFn, user: ?*anyopaque) RunResult {
    @memcpy(tags[0..self.n_regs], self.box_tags[0..self.n_regs]);
    var r: usize = 0;
    while (r < self.n_regs) : (r += 1) {
        slots[r] = 0;
        // A register the loop READS must carry its live-in value, so a kind that does not fit its
        // slot bails to the interpreter. A written-only register is seeded too where it can be:
        // the write may sit behind an untaken branch and the exit reboxes every written register.
        const must_seed = self.read_set[r];
        if (!must_seed and !self.def_set[r]) continue;
        if (r >= regs.len) {
            if (must_seed) return .bail;
            continue;
        }
        const v = regs[r];
        switch (self.reg_types[r]) {
            .i32 => switch (v) {
                .Int => |x| slots[r] = x,
                .Char => |x| {
                    slots[r] = x;
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Char));
                },
                .Short => |x| {
                    slots[r] = x;
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Short));
                },
                .Byte => |x| {
                    slots[r] = x;
                    if (!self.def_set[r]) tags[r] = @intFromEnum(@as(std.meta.Tag(Value), .Byte));
                },
                else => if (must_seed) return .bail,
            },
            .i64 => switch (v) {
                .Long => |x| slots[r] = x,
                else => if (must_seed) return .bail,
            },
            .f64 => switch (v) {
                .Double => |x| slots[r] = @bitCast(x),
                else => if (must_seed) return .bail,
            },
            .f32 => switch (v) {
                .Float => |x| slots[r] = @as(u32, @bitCast(x)),
                else => if (must_seed) return .bail,
            },
            .boolean => switch (v) {
                .Bool => |b| slots[r] = if (b) 1 else 0,
                else => if (must_seed) return .bail,
            },
            .unit => if (v != .Unit and must_seed) return .bail,
            .null_ => if (v != .Null and must_seed) return .bail,
            .object => {},
            .unknown => if (must_seed) return .bail,
        }
    }

    if (!reseedArrays(self, regs, slots)) return .bail;

    // Unbox each capture cell's scalar into its register's slot: no calls or GC run inside
    // the loop, and the scalar is written back through the box at exit.
    for (self.cells) |cu| {
        if (cu.reg.int() >= regs.len) return .bail;
        const v = regs[cu.reg.int()];
        if (v != .Cell) return .bail;
        const g = v.Cell.borrow();
        const inner = g.get().*;
        g.deinit();
        slots[cu.reg.int()] = cellSlotIn(cu.rt, inner) orelse return .bail;
    }

    for (self.nullables) |nu| {
        if (!nu.live_in) continue;
        if (nu.reg.int() >= regs.len) return .bail;
        const v = regs[nu.reg.int()];
        if (v == .Null) {
            slots[nu.reg.int()] = 0;
            slots[nu.flag_slot] = 1;
        } else {
            slots[nu.reg.int()] = cellSlotIn(nu.rt, v) orelse return .bail;
            slots[nu.flag_slot] = 0;
        }
    }

    // One reserved slot holds the `*TrampCtx` the native sites load into rdi, the other the
    // host callback.
    var tctx: TrampCtx = undefined;
    // Field bases and direct callees are seeded even with no TRAMPOLINE site left: a direct
    // call consumes the site, and its receiver's field base still needs caching.
    {
        if (self.regs_ptr_slot != 0) slots[self.regs_ptr_slot] = @bitCast(@intFromPtr(regs.ptr));
        for (self.field_bases) |fb| {
            if (fb.recv_reg >= regs.len or regs[fb.recv_reg] != .Instance) return .bail;
            if (instanceClassIdentity(regs[fb.recv_reg]) != fb.recv_class) return .bail;
            const g = regs[fb.recv_reg].Instance.borrow();
            slots[fb.ptr_slot] = @bitCast(@intFromPtr(g.get().fields.items.ptr));
            g.deinit();
        }
        // A direct call reaches its callee's body WITHOUT that body's own entry guard, so this
        // entry proves the layout it was compiled against still holds on the receiver.
        for (self.direct_sites) |ds| {
            const rr = ds.recv_reg;
            if (rr >= regs.len or regs[rr] != .Instance) return .bail;
            if (instanceClassIdentity(regs[rr]) != ds.callee.guard_class) return .bail;
            if (ds.callee.method_fields.len == 0) continue;
            const g = regs[rr].Instance.borrow();
            defer g.deinit();
            const items = g.get().fields.items;
            for (ds.callee.method_fields) |mf| {
                if (mf.idx >= items.len or
                    !(items[mf.idx].name.ptr == mf.name.ptr or std.mem.eql(u8, items[mf.idx].name, mf.name))) return .bail;
            }
        }
    }
    if (self.call_sites.len != 0) {
        if (tramp == null or user == null) return .bail;
        // Each member call's receiver must still be an Instance of the class the site was
        // compiled against, or its method and return type could differ this activation: deopt.
        for (self.call_sites) |site| {
            if (site.recv_varies or site.recv_class == 0 or !(site.is_member or site.is_field or site.is_field_set)) continue;
            if (site.recv_reg >= regs.len) return .bail;
            const rv = regs[site.recv_reg];
            if (rv != .Instance or instanceClassIdentity(rv) != site.recv_class) return .bail;
        }
        // The native-field receiver is a validated loop-invariant Instance, so its field buffer
        // neither moves nor resizes for the duration of the native run.
        tctx = .{ .slots = slots.ptr, .compiled = self, .user = user.?, .tags = tags.ptr };
        slots[self.uc_slot] = @bitCast(@intFromPtr(&tctx));
        slots[self.tramp_slot] = @bitCast(@intFromPtr(tramp.?));
    }

    const fnptr = self.exec.entry(*const fn ([*]i64) callconv(.c) u64);
    const code = fnptr(slots.ptr);
    const target = BlockId.from(@intCast(code >> 32));
    const inst: u32 = @truncate(code & 0xffff_ffff);

    const rebox_skip: u32 = if (self.call_sites.len != 0) tctx.deopt_skip_reg else std.math.maxInt(u32);
    r = 0;
    while (r < self.n_regs) : (r += 1) {
        if (!self.def_set[r]) continue;
        if (r >= regs.len) continue;
        if (r == rebox_skip) continue;
        regs[r] = switch (self.reg_types[r]) {
            .i32 => valueFromSlotTagged(.i32, tags[r], slots[r]),
            .i64 => .{ .Long = slots[r] },
            .f64 => .{ .Double = @bitCast(slots[r]) },
            .f32 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(slots[r]))))) },
            .boolean => .{ .Bool = slots[r] != 0 },
            .unit => .Unit,
            .null_ => .Null,
            .object => regs[r],
            .unknown => regs[r],
        };
    }

    // Write each cell's cached scalar back through its box. Its TAG is the kind the
    // writeback must restore: a captured `Char` var must not come back as an `Int`.
    for (self.cells) |cu| {
        if (cu.reg.int() >= regs.len) continue;
        const v = regs[cu.reg.int()];
        if (v != .Cell) continue;
        const g = v.Cell.borrowMut();
        const prev_tag: u8 = @intFromEnum(std.meta.activeTag(g.get().*));
        g.get().* = valueFromSlotTagged(cu.rt, prev_tag, slots[cu.reg.int()]);
        g.deinit();
    }

    for (self.nullables) |nu| {
        if (!nu.live_out or nu.reg.int() >= regs.len) continue;
        regs[nu.reg.int()] = if (slots[nu.flag_slot] != 0) .Null else valueFromSlotTagged(nu.rt, tags[nu.reg.int()], slots[nu.reg.int()]);
    }
    return .{ .resume_at = .{ .block = target, .inst = inst } };
}

/// Reads a cell's inner scalar into an i64 slot; null when the box no longer holds the
/// specialized kind, which deopts.
pub fn cellSlotIn(rt: RegType, v: Value) ?i64 {
    return switch (rt) {
        .i32 => switch (v) {
            .Int => |x| x,
            .Char => |x| x,
            .Short => |x| x,
            .Byte => |x| x,
            else => null,
        },
        .i64 => switch (v) {
            .Long => |x| x,
            else => null,
        },
        .f64 => switch (v) {
            .Double => |x| @bitCast(x),
            else => null,
        },
        .f32 => switch (v) {
            .Float => |x| @as(u32, @bitCast(x)),
            else => null,
        },
        .boolean => switch (v) {
            .Bool => |b| if (b) 1 else 0,
            else => null,
        },
        else => null,
    };
}

pub fn valueFromSlot(rt: RegType, s: i64) Value {
    return switch (rt) {
        .i32 => .{ .Int = @truncate(s) },
        .i64 => .{ .Long = s },
        .f64 => .{ .Double = @bitCast(s) },
        .f32 => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(s))))) },
        .boolean => .{ .Bool = s != 0 },
        else => .Unit,
    };
}

pub const INT_TAG: u8 = @intFromEnum(@as(std.meta.Tag(Value), .Int));

/// As `valueFromSlot`, but an `.i32` slot boxes back to its register's ORIGINAL kind
/// (`Char`/`Short`/`Byte`) instead of always `.Int`.
pub fn valueFromSlotTagged(rt: RegType, tag: u8, s: i64) Value {
    if (rt == .i32) {
        const T = std.meta.Tag(Value);
        return switch (@as(T, @enumFromInt(tag))) {
            .Char => .{ .Char = @truncate(@as(u64, @bitCast(s))) },
            .Short => .{ .Short = @truncate(s) },
            .Byte => .{ .Byte = @truncate(s) },
            else => .{ .Int = @truncate(s) },
        };
    }
    return valueFromSlot(rt, s);
}

/// A whole-function native run's outcome: `code.inst == RETURN_INST` means the function
/// returned `value`, otherwise `code` is an interpreter resume point with registers reboxed.
pub const FuncOutcome = struct { code: Resume, value: Value };

pub fn runFunc(self: *const CompiledLoop, regs: []Value, params: []const Value, slots: []i64, tags: []u8, tramp: ?TrampFn, user: ?*anyopaque) ?FuncOutcome {
    // No blanket slot zeroing: Kotlin's definite-assignment rule means the compiled body
    // never reads a register before writing it, and param and trampoline slots are seeded here.
    @memcpy(tags[0..self.n_regs], self.box_tags[0..self.n_regs]);
    // Method mode: the receiver must be an Instance of exactly the class the body was
    // specialized on, whose stored-field indexes and kinds it uses; anything else declines.
    if (self.method_mode) {
        if (params.len == 0 or params[0] != .Instance) {
            if (debugEnabled()) std.debug.print("[jit-dbg] method run: recv not instance (len={d} tag={s})\n", .{ params.len, if (params.len > 0) @tagName(std.meta.activeTag(params[0])) else "none" });
            return null;
        }
        if (instanceClassIdentity(params[0]) != self.guard_class) {
            if (debugEnabled()) std.debug.print("[jit-dbg] method run: class {x} != guard {x}\n", .{ instanceClassIdentity(params[0]), self.guard_class });
            return null;
        }
        const g = params[0].Instance.borrow();
        const bthis = g.get();
        const items = bthis.fields.items;
        if (self.guard_shape == 0 or bthis.shapeOf() != self.guard_shape) {
            for (self.method_fields) |mf| {
                if (mf.idx >= items.len or !(items[mf.idx].name.ptr == mf.name.ptr or std.mem.eql(u8, items[mf.idx].name, mf.name))) {
                    g.deinit();
                    return null;
                }
            }
        }
        slots[self.entry_fbase_slot] = @bitCast(@intFromPtr(items.ptr));
        g.deinit();
    }
    var i: u32 = 0;
    while (i < self.n_params) : (i += 1) {
        if (i >= params.len) return null;
        if (self.param_rt[i] == .object) continue; // seeded into a frame register
        const sv = cellSlotIn(self.param_rt[i], params[i]) orelse {
            if (self.method_mode and debugEnabled()) std.debug.print("[jit-dbg] method run: param {d} kind {s} rt {s}\n", .{ i, @tagName(std.meta.activeTag(params[i])), @tagName(self.param_rt[i]) });
            return null; // kind changed: interpret
        };
        slots[self.param_slot_base + i] = sv;
    }
    var tctx: TrampCtx = undefined;
    if (self.call_sites.len != 0 and self.has_tramp_sites) {
        if (tramp == null or user == null) return null;
        tctx = .{ .slots = slots.ptr, .compiled = self, .user = user.?, .tags = tags.ptr };
        slots[self.uc_slot] = @bitCast(@intFromPtr(&tctx));
        slots[self.tramp_slot] = @bitCast(@intFromPtr(tramp.?));
    }
    const fnptr = self.exec.entry(*const fn ([*]i64) callconv(.c) u64);
    const code = fnptr(slots.ptr);
    const target = BlockId.from(@intCast(code >> 32));
    const inst: u32 = @truncate(code & 0xffff_ffff);
    if (inst == RETURN_INST) {
        // Frame-resident return: the taken `Return` recorded its register index and the handlers
        // left the value there; it is handed back retained.
        const frame_reg = slots[self.result_reg_slot];
        if (frame_reg >= 0) {
            const rr: u64 = @intCast(frame_reg);
            if (rr < regs.len) {
                const v = regs[rr];
                v.retain();
                return .{ .code = .{ .block = target, .inst = inst }, .value = v };
            }
            return .{ .code = .{ .block = target, .inst = inst }, .value = .Unit };
        }
        return .{ .code = .{ .block = target, .inst = inst }, .value = valueFromSlot(self.result_rt, slots[self.result_slot]) };
    }
    const skip_reg: u32 = if (self.call_sites.len != 0 and self.has_tramp_sites) tctx.deopt_skip_reg else std.math.maxInt(u32);
    var r: u32 = 0;
    while (r < self.n_regs) : (r += 1) {
        if (!self.def_set[r] or r >= regs.len or r == skip_reg) continue;
        switch (self.reg_types[r]) {
            .i32, .i64, .f64, .f32, .boolean => regs[r] = valueFromSlot(self.reg_types[r], slots[r]),
            else => {},
        }
    }
    return .{ .code = .{ .block = target, .inst = inst }, .value = .Unit };
}

/// Frame register buffers live outside the GC heap (see `eval.regsAlloc`); growth here
/// must use the same allocator.
pub inline fn regsGrowAlloc(fallback: Allocator) Allocator {
    if (!runtime.reclaimEnabled() and runtime.gc.gc_enabled) return std.heap.c_allocator;
    return fallback;
}
