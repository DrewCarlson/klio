//! Register type inference: a callee's return type, the live value probes that seed
//! a specialization, and the fixed-point pass over the candidate region.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit = @import("jit");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const inline_analysis = @import("inline_analysis.zig");
const code_cache = @import("cache.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Reg = ir.Reg;
const Allocator = std.mem.Allocator;

const metadata_allocator = code_cache.metadata_allocator;
const RegType = common.RegType;
const INLINE_MAX_BLOCKS = inline_analysis.INLINE_MAX_BLOCKS;
const InlineSite = inline_analysis.InlineSite;
const calleeBlockOrder = inline_analysis.calleeBlockOrder;
const FieldResolver = shapes.FieldResolver;
const arrayOpOf = shapes.arrayOpOf;
const bitwiseOpOf = shapes.bitwiseOpOf;
const cellScalarType = shapes.cellScalarType;
const constType = shapes.constType;
const isArithBinOp = shapes.isArithBinOp;
const isBitwiseBinOp = shapes.isBitwiseBinOp;
const isCmpBinOp = shapes.isCmpBinOp;
const isDivBinOp = shapes.isDivBinOp;
const memberFieldName = shapes.memberFieldName;
const numericConvOf = shapes.numericConvOf;
const trampolinableCallOf = shapes.trampolinableCallOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const trampolinableGlobalOf = shapes.trampolinableGlobalOf;

pub fn isUnitReturn(ty: ir.TypeRef) bool {
    return !ty.nullable and (std.mem.eql(u8, ty.name, "Unit") or ty.name.len == 0);
}

/// Whether a declared return type NAME is any scalar kind. Such a return never takes
/// the frame-resident object protocol, so its register may be slot-typed.
pub fn declaredScalarName(n: []const u8) bool {
    return std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Long") or
        std.mem.eql(u8, n, "Double") or std.mem.eql(u8, n, "Float") or
        std.mem.eql(u8, n, "Boolean") or std.mem.eql(u8, n, "Char") or
        std.mem.eql(u8, n, "Short") or std.mem.eql(u8, n, "Byte");
}

pub fn retRegType(ty: ir.TypeRef) RegType {
    if (ty.nullable) return .unknown;
    const n = ty.name;
    if (std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Char") or
        std.mem.eql(u8, n, "Short") or std.mem.eql(u8, n, "Byte")) return .i32;
    if (std.mem.eql(u8, n, "Long")) return .i64;
    if (std.mem.eql(u8, n, "Double")) return .f64;
    if (std.mem.eql(u8, n, "Float")) return .f32;
    if (std.mem.eql(u8, n, "Boolean")) return .boolean;
    return .unknown;
}

pub threadlocal var ret_type_cache: std.AutoHashMapUnmanaged(usize, RegType) = .empty;

/// The scalar `RegType` a callee returns: the declared type when it names a scalar,
/// else inferred from the body, since an expression-body return records as `Unit`.
pub fn funcReturnRegType(module: *const Module, func: *const Func) RegType {
    const explicit = retRegType(func.return_ty);
    if (explicit != .unknown) return explicit;
    const key = @intFromPtr(func);
    if (ret_type_cache.get(key)) |c| return c;
    // Seed `.unknown` before inferring so a recursive callee re-entering here sees the
    // in-progress entry and stops; the real result overwrites it.
    ret_type_cache.put(metadata_allocator, key, .unknown) catch {};
    const inferred = inferScalarReturnType(metadata_allocator, module, func) orelse .unknown;
    ret_type_cache.put(metadata_allocator, key, inferred) catch {};
    return inferred;
}

/// Infers a callee's scalar return type from its IR body. Null unless every
/// value-return agrees on one scalar type; a nested inferred-return call stays `.unknown`.
fn inferScalarReturnType(a: Allocator, module: *const Module, func: *const Func) ?RegType {
    if (func.blocks.len == 0) return null;
    const n = func.n_locals;
    if (n == 0) return null;
    const types = a.alloc(RegType, n) catch return null;
    defer a.free(types);
    @memset(types, .unknown);
    const empty_ai = a.alloc(?ArrayInfo, n) catch return null;
    defer a.free(empty_ai);
    @memset(empty_ai, null);
    const empty_ci = a.alloc(?RegType, n) catch return null;
    defer a.free(empty_ci);
    @memset(empty_ci, null);
    for (func.params, 0..) |p, i| {
        if (i >= n) break;
        types[i] = retRegType(p.ty);
    }
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (setDefType(types, module, inst, empty_ai, empty_ci)) changed = true;
            }
        }
    }
    var result: RegType = .unknown;
    for (func.blocks) |*blk| {
        const r = switch (blk.terminator) {
            .Return => |maybe_r| maybe_r orelse continue,
            else => continue,
        };
        if (r.int() >= n) return null;
        const t = types[r.int()];
        if (!isScalarRt(t)) return null;
        if (result == .unknown) result = t else if (result != t) return null;
    }
    return if (result == .unknown) null else result;
}

/// Kotlin numeric promotion for an arithmetic op (`Double > Float > Long > Int`;
/// Byte/Short/Char already map to `i32`). An unknown operand yields the other.
fn promoteArith(lt: RegType, rt: RegType) RegType {
    if (lt == .f64 or rt == .f64) return .f64;
    if (lt == .f32 or rt == .f32) return .f32;
    if (lt == .i64 or rt == .i64) return .i64;
    if (lt == .i32 or rt == .i32) return .i32;
    return if (lt != .unknown) lt else rt;
}

pub fn fillInlineTypes(a: Allocator, module: *const Module, site: *const InlineSite, caller_types: []const RegType, ext: []RegType, field_resolver: ?FieldResolver, resolver_user: ?*anyopaque, regs: []const Value, recv_value: ?*const Value) Allocator.Error!void {
    const callee = site.callee;
    const n = callee.n_locals;
    if (n == 0) return;
    const t = ext[site.base .. site.base + n];
    @memset(t, .unknown);
    const eai = try a.alloc(?ArrayInfo, n);
    defer a.free(eai);
    @memset(eai, null);
    const eci = try a.alloc(?RegType, n);
    defer a.free(eci);
    @memset(eci, null);
    // A member inline maps parameter index 1 to the first argument, index 0 being the receiver.
    const arg_base: i64 = if (site.is_member) @as(i64, site.args_reg) - 1 else @as(i64, site.args_reg);
    var order_buf: [INLINE_MAX_BLOCKS]u32 = undefined;
    const order = calleeBlockOrder(callee, &order_buf) orelse return;
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (order) |ob| for (callee.blocks[ob].insts) |*inst| {
            if (inst.* == .LoadParam) {
                const lp = inst.LoadParam;
                if (site.is_member and lp.idx == 0) continue; // receiver: not a scalar
                const ar = arg_base + lp.idx;
                const at: RegType = if (ar >= 0 and ar < caller_types.len) caller_types[@intCast(ar)] else .unknown;
                if (lp.dst.int() < n and setType(t, lp.dst, at)) changed = true;
                continue;
            }
            if (site.is_member) {
                if (trampolinableFieldOf(module, inst)) |fld| {
                    if (field_resolver) |fr| {
                        const rv: *const Value = recv_value orelse &regs[site.recv_reg];
                        if (fr(resolver_user.?, rv, memberFieldName(fld.name))) |idx| {
                            const g = rv.Instance.borrow();
                            const fv: ?Value = if (idx < g.get().fields.items.len) g.get().fields.items[idx].value else null;
                            g.deinit();
                            if (fv) |v| if (cellScalarType(v)) |rt| {
                                if (fld.dst.int() < n and setType(t, fld.dst, rt)) changed = true;
                            };
                        }
                    }
                    continue;
                }
                if (trampolinableFieldSetOf(module, inst) != null) continue;
            }
            if (setDefType(t, module, inst, eai, eci)) changed = true;
        };
    }
}

pub fn isScalarRt(t: RegType) bool {
    return switch (t) {
        .i32, .i64, .f64, .f32, .boolean => true,
        else => false,
    };
}

pub fn tagForRt(t: RegType) ?u8 {
    const T = std.meta.Tag(Value);
    return switch (t) {
        .i32 => @intFromEnum(@as(T, .Int)),
        .i64 => @intFromEnum(@as(T, .Long)),
        .f64 => @intFromEnum(@as(T, .Double)),
        .f32 => @intFromEnum(@as(T, .Float)),
        .boolean => @intFromEnum(@as(T, .Bool)),
        else => null,
    };
}

/// The `RegType` of a live register value: a scalar kind, `.object` for an instance
/// (held in `regs`, so it stays a GC root), or null when unclassifiable.
pub fn liveValueRegType(v: Value) ?RegType {
    if (cellScalarType(v)) |s| return s;
    return switch (v) {
        .Null, .Unit => null,
        else => .object,
    };
}

/// The scalar `RegType` of a `Map`'s values, sampled from any live entry since the
/// value type is uniform; null for an empty map or a non-scalar value type.
pub fn liveMapValueType(recv: Value) ?RegType {
    if (recv != .Map) return null;
    const g = recv.Map.entries.borrow();
    defer g.deinit();
    const pairs = g.get().pairs.items;
    if (pairs.len == 0) return null;
    return cellScalarType(pairs[0].value);
}

pub fn liveElementAt(recv: Value, idx: i64) ?Value {
    if (idx < 0) return null;
    const u: usize = @intCast(idx);
    switch (recv) {
        .List => |l| {
            const g = l.items.borrow();
            defer g.deinit();
            const items = g.get().items;
            return if (u < items.len) items[u] else null;
        },
        .Array => |arr| return if (arr.primKind() == null and u < arr.len()) arr.get(u) else null,
        else => return null,
    }
}

/// Class-cell identity of an `Instance`, the loop-entry guard for a trampolined member
/// call: a later activation with a different class deopts.
pub fn instanceClassIdentity(v: Value) usize {
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().class.identity();
}

/// Element register type and native access width for a packed array kind; null for
/// kinds the JIT does not compile (Float). A `Double` element moves as raw `b64` bits.
pub fn arrayElemShape(kind: runtime.PrimitiveArrayKind) ?struct { rt: RegType, w: jit.ElemW, esize: u8 } {
    return switch (kind) {
        .Boolean => .{ .rt = .boolean, .w = .b8u, .esize = 1 },
        .Byte => .{ .rt = .i32, .w = .b8s, .esize = 1 },
        .UByte => .{ .rt = .i32, .w = .b8u, .esize = 1 },
        .Short => .{ .rt = .i32, .w = .b16s, .esize = 2 },
        .UShort => .{ .rt = .i32, .w = .b16u, .esize = 2 },
        .Char => .{ .rt = .i32, .w = .b16u, .esize = 2 },
        .Int => .{ .rt = .i32, .w = .b32s, .esize = 4 },
        .UInt => .{ .rt = .i32, .w = .b32u, .esize = 4 },
        .Long => .{ .rt = .i64, .w = .b64, .esize = 8 },
        .ULong => .{ .rt = .i64, .w = .b64, .esize = 8 },
        .Double => .{ .rt = .f64, .w = .b64, .esize = 8 },
        .Float => .{ .rt = .f32, .w = .b32u, .esize = 4 },
    };
}

pub const ArrayInfo = struct {
    rt: RegType,
    w: jit.ElemW,
    esize: u8,
    ptr_slot: u32,
    len_slot: u32,
    /// Elements are boxed `Value`s rather than packed scalars: the stride is a whole
    /// `Value` and a read guards the tag exactly as a field read does.
    boxed: bool = false,
    /// Expected element tag for a boxed read; a mismatch deopts.
    tag: u8 = 0,
};


pub fn inferTypes(a: Allocator, module: *const Module, func: *const Func, n_regs: u32, array_info: []const ?ArrayInfo, cell_info: []const ?RegType, regs: []const Value, member_ret: []const RegType) Allocator.Error![]RegType {
    const types = try a.alloc(RegType, n_regs);
    @memset(types, .unknown);
    // Member-call result types are resolved against the live receiver before this pass,
    // since the IR alone cannot name the dispatched method; `setDefType` overrides them.
    for (member_ret, 0..) |rt, r| {
        if (rt != .unknown) types[r] = rt;
    }
    // Seed every register from its live scalar kind: a loop reading a parameter or any
    // prologue-computed value has no in-body instruction to infer from. Sound because the
    // entry unbox re-checks each read reg against its cached type and bails on mismatch.
    {
        var p: usize = 0;
        while (p < n_regs and p < regs.len) : (p += 1) {
            if (array_info[p] != null or cell_info[p] != null) continue;
            // Objects too: an instance built outside the loop has no in-body definition. An
            // `.object` register reaches the body only through the site machinery, which guards its class.
            if (liveValueRegType(regs[p])) |rt| types[p] = rt;
        }
    }
    var changed = true;
    var iters: usize = 0;
    while (changed and iters < 16) : (iters += 1) {
        changed = false;
        for (func.blocks) |*blk| {
            for (blk.insts) |*inst| {
                if (setDefType(types, module, inst, array_info, cell_info)) changed = true;
            }
        }
    }
    return types;
}

pub fn setDefType(types: []RegType, module: *const Module, inst: *const Inst, array_info: []const ?ArrayInfo, cell_info: []const ?RegType) bool {
    if (trampolinableGlobalOf(module, inst)) |lg| {
        return setType(types, lg.dst, .object);
    }
    if (arrayOpOf(module, inst)) |op| {
        const t: RegType = if (op.is_set) .unit else blk: {
            if (op.recv.int() < array_info.len) {
                if (array_info[op.recv.int()]) |ai| break :blk ai.rt;
            }
            break :blk .unknown;
        };
        return setType(types, op.dst, t);
    }
    if (numericConvOf(module, inst)) |nc| {
        return setType(types, nc.dst, nc.to);
    }
    if (bitwiseOpOf(module, inst)) |bo| {
        return setType(types, bo.dst, typeOf(types, bo.lhs));
    }
    // A trampolined top-level call yields its callee's declared scalar return type,
    // `.unknown` for Unit or non-scalar, whose result is then never reboxed.
    if (trampolinableCallOf(inst)) |tc| {
        const f = module.funcById(tc.func) orelse return false;
        return setType(types, tc.dst, funcReturnRegType(module, f));
    }
    if (inst.* == .CellGet) {
        const cg = inst.CellGet;
        const t: RegType = if (cg.cell.int() < cell_info.len) (cell_info[cg.cell.int()] orelse .unknown) else .unknown;
        return setType(types, cg.dst, t);
    }
    const dst_t: ?struct { r: Reg, t: RegType } = switch (inst.*) {
        .Const => |c| .{ .r = c.dst, .t = constType(module.consts.items[c.value.int()]) },
        .Move => |m| .{ .r = m.dst, .t = typeOf(types, m.src) },
        .BinOp => |b| blk: {
            if (isCmpBinOp(b.op)) break :blk .{ .r = b.dst, .t = .boolean };
            if (isArithBinOp(b.op) or isDivBinOp(b.op)) {
                break :blk .{ .r = b.dst, .t = promoteArith(typeOf(types, b.lhs), typeOf(types, b.rhs)) };
            }
            // A bitwise or shift BinOp must be typed here: an untyped dst poisons every later read.
            if (isBitwiseBinOp(b.op)) break :blk .{ .r = b.dst, .t = typeOf(types, b.lhs) };
            break :blk null;
        },
        .Not => |n| .{ .r = n.dst, .t = .boolean },
        .UnOp => |u| .{ .r = u.dst, .t = typeOf(types, u.operand) },
        else => null,
    };
    if (dst_t) |d| return setType(types, d.r, d.t);
    return false;
}

pub fn setType(types: []RegType, r: Reg, t: RegType) bool {
    if (r.int() >= types.len or t == .unknown or types[r.int()] == t) return false;
    // `.null_` is the bottom of a nullable merge, so it never downgrades an already-known
    // concrete type: `{null, scalar}` settles on the scalar rather than oscillating.
    if (t == .null_ and types[r.int()] != .unknown) return false;
    types[r.int()] = t;
    return true;
}

pub fn typeOf(types: []const RegType, r: Reg) RegType {
    if (r.int() < types.len) return types[r.int()];
    return .unknown;
}
