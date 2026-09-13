//! The loop compile gate: validates a natural loop candidate against every
//! bail condition, infers its specialization, drives the emitter, and returns
//! a `CompiledLoop` (or declines).

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit = @import("jit");

const common = @import("common.zig");
const shapes = @import("shapes.zig");
const inline_analysis = @import("inline_analysis.zig");
const type_infer = @import("types.zig");
const loop_shape = @import("loop_shape.zig");
const compiler = @import("compiler.zig");
const run_mod = @import("run.zig");
const code_cache = @import("cache.zig");

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const Reg = ir.Reg;
const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Allocator = std.mem.Allocator;

const debugEnabled = code_cache.debugEnabled;
const ArrayUnbox = common.ArrayUnbox;
const CallSite = common.CallSite;
const CellUnbox = common.CellUnbox;
const CompiledLoop = common.CompiledLoop;
const DirectSite = common.DirectSite;
const FieldBase = common.FieldBase;
const MAX_SLOTS = common.MAX_SLOTS;
const MemberIC = common.MemberIC;
const NullableUnbox = common.NullableUnbox;
const RegType = common.RegType;
const VALUE_SIZE = common.VALUE_SIZE;
const valuePayloadOffset = common.valuePayloadOffset;
const valueTagOffset = common.valueTagOffset;
const Compiler = compiler.Compiler;
const BodyInstPos = inline_analysis.BodyInstPos;
const InlineSite = inline_analysis.InlineSite;
const MAX_RECV_CLASSES = inline_analysis.MAX_RECV_CLASSES;
const argTagSourceReg = inline_analysis.argTagSourceReg;
const directCallTarget = inline_analysis.directCallTarget;
const fjDirectEnabled = inline_analysis.fjDirectEnabled;
const inlinableCallee = inline_analysis.inlinableCallee;
const inlinableMemberCallee = inline_analysis.inlinableMemberCallee;
const instAnyDst = inline_analysis.instAnyDst;
const loopReceiverSource = inline_analysis.loopReceiverSource;
const nativeScalarCallShape = inline_analysis.nativeScalarCallShape;
const receiverClassSet = inline_analysis.receiverClassSet;
const regWrittenInBody = inline_analysis.regWrittenInBody;
const LoopSets = loop_shape.LoopSets;
const collectLoop = loop_shape.collectLoop;
const computeSets = loop_shape.computeSets;
const instReadsDef = loop_shape.instReadsDef;
const isNullCheckBinOp = loop_shape.isNullCheckBinOp;
const typeAt = loop_shape.typeAt;
const INT_TAG = run_mod.INT_TAG;
const FieldResolver = shapes.FieldResolver;
const MemberResolver = shapes.MemberResolver;
const VirtResolver = shapes.VirtResolver;
const arrayOpOf = shapes.arrayOpOf;
const bitwiseOpOf = shapes.bitwiseOpOf;
const bodyStoresInto = shapes.bodyStoresInto;
const boxedElemShape = shapes.boxedElemShape;
const boxedElemsOf = shapes.boxedElemsOf;
const cellScalarType = shapes.cellScalarType;
const isCallableValue = shapes.isCallableValue;
const memberFieldName = shapes.memberFieldName;
const numericConvOf = shapes.numericConvOf;
const trampolinableCallOf = shapes.trampolinableCallOf;
const trampolinableCallValueOf = shapes.trampolinableCallValueOf;
const trampolinableFieldOf = shapes.trampolinableFieldOf;
const trampolinableFieldSetOf = shapes.trampolinableFieldSetOf;
const trampolinableGlobalOf = shapes.trampolinableGlobalOf;
const trampolinableMemberOf = shapes.trampolinableMemberOf;
const trampolinableVirtualOf = shapes.trampolinableVirtualOf;
const ArrayInfo = type_infer.ArrayInfo;
const arrayElemShape = type_infer.arrayElemShape;
const fillInlineTypes = type_infer.fillInlineTypes;
const funcReturnRegType = type_infer.funcReturnRegType;
const inferTypes = type_infer.inferTypes;
const instanceClassIdentity = type_infer.instanceClassIdentity;
const isScalarRt = type_infer.isScalarRt;
const liveElementAt = type_infer.liveElementAt;
const liveMapValueType = type_infer.liveMapValueType;
const liveValueRegType = type_infer.liveValueRegType;

/// Compile the loop, preferring the native boxed-element subscript. Typing a
/// `List` read as its element's scalar kind constrains every register downstream
/// of it, so a body that will not compile under that typing is compiled again
/// with boxed receivers left to the interpreted subscript, rather than losing the
/// loop entirely.
pub fn tryCompile(a: Allocator, module: *const Module, func: *const Func, header: BlockId, regs: []const Value, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque, transient: *bool) Allocator.Error!?CompiledLoop {
    if (try tryCompileWith(a, module, func, header, regs, resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user, transient, true)) |c| return c;
    return tryCompileWith(a, module, func, header, regs, resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user, transient, false);
}

/// Try to compile the natural loop whose header is `header`, specializing array
/// accesses on the kinds observed in `regs` (the live frame). Returns a compiled
/// loop, or null if the loop is not a supported shape.
fn tryCompileWith(a: Allocator, module: *const Module, func: *const Func, header: BlockId, regs: []const Value, resolver: ?MemberResolver, virt_resolver: ?VirtResolver, field_resolver: ?FieldResolver, field_nn_resolver: ?FieldResolver, resolver_user: ?*anyopaque, transient: *bool, allow_boxed: bool) Allocator.Error!?CompiledLoop {
    const body = (try collectLoop(a, func, header)) orelse return null;
    defer a.free(body);

    // Reject try-regions: deopt resumes mid-block, so we must not need to
    // re-establish catch/finally scope.
    var unsupported_shape = false;
    for (body) |bid| {
        const blk = &func.blocks[bid.int()];
        if (blk.catches.len != 0 or blk.finally != null) return null;
        switch (blk.terminator) {
            .Goto, .Branch => {},
            else => return null,
        }
        for (blk.insts) |*inst| {
            if (arrayOpOf(module, inst) != null) continue;
            if (numericConvOf(module, inst) != null) continue;
            if (bitwiseOpOf(module, inst) != null) continue;
            if (trampolinableCallOf(inst) != null) continue;
            if (trampolinableMemberOf(module, inst) != null) continue;
            if (trampolinableVirtualOf(inst) != null) continue;
            if (trampolinableFieldOf(module, inst) != null) continue;
            if (trampolinableFieldSetOf(module, inst) != null) continue;
            if (trampolinableCallValueOf(inst) != null) continue;
            if (trampolinableGlobalOf(module, inst) != null) continue;
            switch (inst.*) {
                .Const, .Move, .BinOp, .Not, .UnOp, .Trace, .CellGet, .CellSet => {},
                else => {
                    if (debugEnabled()) std.debug.print("[jit]   uncompilable inst {s} in {s} b{d}\n", .{ @tagName(inst.*), func.name, bid.int() });
                    unsupported_shape = true;
                },
            }
        }
    }
    if (unsupported_shape) return null;
    if (debugEnabled()) std.debug.print("[jit]   shape accepted for {s} b{d}\n", .{ func.name, header.int() });

    const n_regs: u32 = func.n_locals;

    // Discover indexed arrays, specializing on the kinds in the live frame.
    const array_info = try a.alloc(?ArrayInfo, n_regs);
    defer a.free(array_info);
    @memset(array_info, null);
    var arrays: std.ArrayListUnmanaged(ArrayUnbox) = .empty;
    defer arrays.deinit(a);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const op = arrayOpOf(module, inst) orelse continue;
            const rr = op.recv;
            if (rr.int() >= n_regs or rr.int() >= regs.len) return null;
            if (array_info[rr.int()] != null) continue;
            const v = regs[rr.int()];
            // A packed primitive array is indexed at its element width. A
            // receiver holding objects, and a `Map`, are left for the
            // object-subscript / map paths; a non-packed `set` is compilable
            // only for a `Map`.
            const packed_ok = v == .Array and v.Array.primKind() != null and v.Array.storage() == .scalars;
            if (!packed_ok) {
                // A `List` / reference `Array` of a uniform scalar kind is read
                // natively too, at a whole-`Value` stride behind a tag guard.
                if (allow_boxed and !op.is_set and !bodyStoresInto(module, func, body, rr)) {
                    if (boxedElemsOf(v)) |vl| if (boxedElemShape(vl)) |shape| {
                        const bk: u32 = @intCast(arrays.items.len);
                        array_info[rr.int()] = .{
                            .rt = shape.rt,
                            .w = .b64,
                            .esize = @intCast(VALUE_SIZE),
                            .ptr_slot = n_regs + 2 * bk,
                            .len_slot = n_regs + 2 * bk + 1,
                            .boxed = true,
                            .tag = shape.tag,
                        };
                        arrays.append(a, .{ .reg = rr, .kind = .Int, .ptr_slot = n_regs + 2 * bk, .len_slot = n_regs + 2 * bk + 1, .boxed = true }) catch return null;
                        continue;
                    };
                }
                if (op.is_set and v != .Map) return null;
                continue;
            }
            const kind = v.Array.primKind().?;
            const shape = arrayElemShape(kind) orelse return null;
            const k: u32 = @intCast(arrays.items.len);
            array_info[rr.int()] = .{
                .rt = shape.rt,
                .w = shape.w,
                .esize = shape.esize,
                .ptr_slot = n_regs + 2 * k,
                .len_slot = n_regs + 2 * k + 1,
            };
            arrays.append(a, .{ .reg = rr, .kind = kind, .ptr_slot = n_regs + 2 * k, .len_slot = n_regs + 2 * k + 1 }) catch return null;
        }
    }

    // Inline small pure-scalar top-level callees: their single block is spliced in
    // place of the call, with registers shifted into an extended register space
    // [n_regs .. total_regs).
    var inline_sites: std.ArrayListUnmanaged(InlineSite) = .empty;
    defer inline_sites.deinit(a);
    // Receiver `Move`s a member splice consumed: the splice reads the receiver
    // from the register the Move copies FROM, so the Move itself must not also
    // register as an object-move callback.
    var recv_move_skips: std.ArrayListUnmanaged(BodyInstPos) = .empty;
    defer recv_move_skips.deinit(a);
    var total_regs: u32 = n_regs;
    {
        for (body) |bid| {
            for (func.blocks[bid.int()].insts, 0..) |*inst, ii| {
                if (trampolinableCallOf(inst)) |tc| {
                    const callee = module.funcById(tc.func) orelse continue;
                    if (inlinableCallee(module, callee) and callee.params.len == tc.n_args) {
                        inline_sites.append(a, .{
                            .block = bid,
                            .inst = @intCast(ii),
                            .callee = callee,
                            .base = total_regs,
                            .args_reg = tc.args_reg,
                            .n_args = tc.n_args,
                            .dst = tc.dst,
                        }) catch return null;
                        total_regs += callee.n_locals;
                        if (total_regs > 4096) return null;
                        continue;
                    }
                    // `node.m()` on a receiver the loop REBINDS each iteration
                    // lowers to a static call with the receiver moved into arg 0.
                    // Lowering already chose the body, so the splice needs no
                    // dispatch guard; its `this`-field accesses ride whatever the
                    // receiver register holds on the iteration that runs them.
                    // Without this the call is a plain trampoline the callee
                    // clause refuses outright, and the whole loop goes with it.
                    if (field_resolver != null and tc.n_args >= 1) blk2: {
                        var this_reg: u32 = 0;
                        if (!inlinableMemberCallee(module, callee, &this_reg)) break :blk2;
                        if (callee.params.len != tc.n_args) break :blk2;
                        const rs = loopReceiverSource(func, body, tc.args_reg, bid.int(), @intCast(ii), null, n_regs) orelse break :blk2;
                        if (rs.src >= regs.len or regs[rs.src] != .Instance) break :blk2;
                        inline_sites.append(a, .{
                            .block = bid,
                            .inst = @intCast(ii),
                            .callee = callee,
                            .base = total_regs,
                            .args_reg = tc.args_reg + 1,
                            .n_args = tc.n_args - 1,
                            .dst = tc.dst,
                            .is_member = true,
                            .recv_reg = rs.src,
                            .this_reg = this_reg,
                            .has_result = callee.blocks[0].terminator.Return != null,
                            .resume_at = rs.mv,
                        }) catch return null;
                        recv_move_skips.append(a, rs.mv) catch return null;
                        total_regs += callee.n_locals;
                        if (total_regs > 4096) return null;
                        if (debugEnabled()) std.debug.print("[jit]   splicing member {s} on a rebound receiver in {s}\n", .{ callee.name, func.name });
                        continue;
                    }
                    continue;
                }
                // A loop-invariant VIRTUAL call resolves its monomorphic slot
                // target at compile time and inlines it exactly like a member
                // call (the entry class guard covers the invariant receiver, so
                // the resolved body is the one the runtime dispatch would pick).
                if (trampolinableVirtualOf(inst)) |vc| blk: {
                    if (virt_resolver == null or field_resolver == null) break :blk;
                    if (vc.recv.int() >= regs.len or regs[vc.recv.int()] != .Instance) break :blk;
                    // A receiver the loop REWRITES each iteration is specialized
                    // per class instead: enumerate what its container holds and
                    // give each class an arm, guarded at run time. The call still
                    // registers its trampoline site, which the final miss uses.
                    if (regWrittenInBody(func, body, vc.recv)) {
                        var reps_buf: [MAX_RECV_CLASSES]Value = undefined;
                        const reps = receiverClassSet(func, body, vc.recv.int(), regs, &reps_buf) orelse break :blk;
                        var arms: usize = 0;
                        for (reps) |rep| {
                            const afid = virt_resolver.?(resolver_user.?, &rep, vc.slot) orelse break :blk;
                            const acallee = module.funcById(afid) orelse break :blk;
                            var athis: u32 = 0;
                            if (!inlinableMemberCallee(module, acallee, &athis)) break :blk;
                            if (acallee.params.len != @as(usize, vc.n_args) + 1) break :blk;
                            // An arm that touches `this`-fields would need its
                            // field sites rebound to the base this guard loads
                            // per iteration; that is not built yet.
                            for (acallee.blocks[0].insts) |*ci| {
                                if (trampolinableFieldOf(module, ci) != null or
                                    trampolinableFieldSetOf(module, ci) != null) break :blk;
                            }
                            inline_sites.append(a, .{
                                .block = bid,
                                .inst = @intCast(ii),
                                .callee = acallee,
                                .base = total_regs,
                                .args_reg = vc.args_reg,
                                .n_args = vc.n_args,
                                .dst = vc.dst,
                                .is_member = true,
                                .recv_reg = vc.recv.int(),
                                .this_reg = athis,
                                .has_result = acallee.blocks[0].terminator.Return != null,
                                .guarded = true,
                                .guard_class = instanceClassIdentity(rep),
                            }) catch return null;
                            total_regs += acallee.n_locals;
                            if (total_regs > 4096) return null;
                            arms += 1;
                        }
                        if (debugEnabled()) std.debug.print("[jit]   guarded virtual dispatch: {d} arm(s) in {s}\n", .{ arms, func.name });
                        break :blk; // falls through so the trampoline site registers
                    }
                    const fid = virt_resolver.?(resolver_user.?, &regs[vc.recv.int()], vc.slot) orelse break :blk;
                    const callee = module.funcById(fid) orelse break :blk;
                    var this_reg: u32 = 0;
                    if (!inlinableMemberCallee(module, callee, &this_reg)) break :blk;
                    if (callee.params.len != @as(usize, vc.n_args) + 1) break :blk; // receiver + args
                    var has_write = false;
                    for (callee.blocks[0].insts) |*ci| {
                        if (trampolinableFieldSetOf(module, ci) != null) has_write = true;
                    }
                    if (has_write) {
                        if (field_nn_resolver == null) break :blk;
                        var read_ok = true;
                        for (callee.blocks[0].insts) |*ci| {
                            if (trampolinableFieldOf(module, ci)) |fld| {
                                if (field_nn_resolver.?(resolver_user.?, &regs[vc.recv.int()], memberFieldName(fld.name)) == null) {
                                    read_ok = false;
                                    break;
                                }
                            }
                        }
                        if (!read_ok) break :blk;
                    }
                    if (debugEnabled()) std.debug.print("[jit]   inlining virtual {s}\n", .{callee.name});
                    const has_result = callee.blocks[0].terminator.Return != null;
                    inline_sites.append(a, .{
                        .block = bid,
                        .inst = @intCast(ii),
                        .callee = callee,
                        .base = total_regs,
                        .args_reg = vc.args_reg,
                        .n_args = vc.n_args,
                        .dst = vc.dst,
                        .is_member = true,
                        .recv_reg = vc.recv.int(),
                        .this_reg = this_reg,
                        .has_result = has_result,
                    }) catch return null;
                    total_regs += callee.n_locals;
                    if (total_regs > 4096) return null;
                    continue;
                }
                // Member call to a small `this`-field/scalar method: inline it.
                // Only for a loop-invariant receiver — inlining resolves one method
                // body, so a varying (polymorphic) receiver must keep dynamic dispatch.
                if (trampolinableMemberOf(module, inst)) |mc| {
                    if (mc.resolved != null or mc.dispatch_recv != null) continue;
                    if (resolver == null or field_resolver == null) continue;
                    if (mc.recv.int() >= regs.len or regs[mc.recv.int()] != .Instance) continue;
                    if (regWrittenInBody(func, body, mc.recv)) continue;
                    // The resolver reads every argument it is handed, so the
                    // buffer must be FULLY filled at the length passed: a
                    // partial fill handed over at `n_args` let it read
                    // undefined Values, and a call past the buffer sliced off
                    // the end of it. Decline both rather than resolve on a
                    // truncated list, which could select another overload.
                    var av: [6]Value = undefined;
                    if (mc.n_args > av.len) continue;
                    if (@as(usize, mc.args_reg) + mc.n_args > regs.len) continue;
                    for (0..mc.n_args) |k| av[k] = regs[mc.args_reg + k];
                    const fid = resolver.?(resolver_user.?, &regs[mc.recv.int()], mc.name, av[0..mc.n_args]) orelse continue;
                    const callee = module.funcById(fid) orelse continue;
                    var this_reg: u32 = 0;
                    if (!inlinableMemberCallee(module, callee, &this_reg)) continue;
                    if (callee.params.len != @as(usize, mc.n_args) + 1) continue; // receiver + args
                    // If the method writes a field, every field it reads must be a
                    // non-nullable scalar so the read can never deopt — otherwise a
                    // deopt would re-run the call and double an already-applied write.
                    var has_write = false;
                    for (callee.blocks[0].insts) |*ci| {
                        if (trampolinableFieldSetOf(module, ci) != null) has_write = true;
                    }
                    if (has_write) {
                        if (field_nn_resolver == null) continue;
                        var read_ok = true;
                        for (callee.blocks[0].insts) |*ci| {
                            if (trampolinableFieldOf(module, ci)) |fld| {
                                if (field_nn_resolver.?(resolver_user.?, &regs[mc.recv.int()], memberFieldName(fld.name)) == null) {
                                    read_ok = false;
                                    break;
                                }
                            }
                        }
                        if (!read_ok) continue;
                    }
                    if (debugEnabled()) std.debug.print("[jit]   inlining member {s}\n", .{callee.name});
                    const has_result = callee.blocks[0].terminator.Return != null;
                    inline_sites.append(a, .{
                        .block = bid,
                        .inst = @intCast(ii),
                        .callee = callee,
                        .base = total_regs,
                        .args_reg = mc.args_reg,
                        .n_args = mc.n_args,
                        .dst = mc.dst,
                        .is_member = true,
                        .recv_reg = mc.recv.int(),
                        .this_reg = this_reg,
                        .has_result = has_result,
                    }) catch return null;
                    total_regs += callee.n_locals;
                    if (total_regs > 4096) return null;
                }
            }
        }
    }
    // The splice claims [n_regs .. total_regs) for the inlined callees' registers,
    // so the array caches, provisionally placed straight after the loop's own
    // registers, move above it.
    if (total_regs != n_regs) {
        const shift = total_regs - n_regs;
        for (arrays.items) |*au| {
            au.ptr_slot += shift;
            au.len_slot += shift;
        }
        for (array_info) |*slot| if (slot.*) |*ai| {
            ai.ptr_slot += shift;
            ai.len_slot += shift;
        };
    }
    const arr_slots: u32 = total_regs + 2 * @as(u32, @intCast(arrays.items.len));

    // Discover capture cells, specializing on the scalar kind each box holds in
    // the live frame. The cached scalar reuses the cell register's own slot, so
    // no extra slots are needed. Reject if two cell registers alias the same box
    // (caching + write-back would diverge from the shared-box interpreter).
    const cell_info = try a.alloc(?RegType, n_regs);
    defer a.free(cell_info);
    @memset(cell_info, null);
    var cells: std.ArrayListUnmanaged(CellUnbox) = .empty;
    defer cells.deinit(a);
    var cell_ptrs: std.ArrayListUnmanaged(usize) = .empty;
    defer cell_ptrs.deinit(a);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            const cr: Reg = switch (inst.*) {
                .CellGet => |cg| cg.cell,
                .CellSet => |cs| cs.cell,
                else => continue,
            };
            if (cr.int() >= n_regs or cr.int() >= regs.len) return null;
            if (cell_info[cr.int()] != null) continue;
            if (array_info[cr.int()] != null) return null; // can't be both
            const v = regs[cr.int()];
            if (v != .Cell) return null;
            const g = v.Cell.borrow();
            const inner = g.get().*;
            g.deinit();
            const rt = cellScalarType(inner) orelse return null;
            const box_ptr = v.Cell.identity();
            for (cell_ptrs.items) |p| if (p == box_ptr) return null; // aliased box
            cell_ptrs.append(a, box_ptr) catch return null;
            cell_info[cr.int()] = rt;
            cells.append(a, .{ .reg = cr, .rt = rt }) catch return null;
        }
    }

    // Resolve each dynamic member call's result type against its live receiver;
    // exact member calls carry the declaration identity in IR.
    const member_ret = try a.alloc(RegType, n_regs);
    defer a.free(member_ret);
    @memset(member_ret, .unknown);
    const field_idx_of = try a.alloc(u32, n_regs);
    defer a.free(field_idx_of);
    @memset(field_idx_of, 0);
    // Registers that are a `Map[key]` get result: a nullable scalar (the map's
    // value type, or null when absent). Folded into the nullable set below.
    const map_get_dst = try a.alloc(bool, n_regs);
    defer a.free(map_get_dst);
    @memset(map_get_dst, false);
    for (body) |bid| {
        for (func.blocks[bid.int()].insts) |*inst| {
            if (trampolinableMemberOf(module, inst)) |mc| {
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len) return null;
                var av: [6]Value = undefined;
                if (mc.n_args > av.len) return null;
                if (@as(usize, mc.args_reg) + mc.n_args > regs.len) return null;
                for (0..mc.n_args) |k| av[k] = regs[mc.args_reg + k];
                if (mc.resolved) |fid| {
                    if (module.funcById(fid)) |f| {
                        if (f.is_suspend) return null;
                        if (mc.dst.int() < n_regs) {
                            member_ret[mc.dst.int()] = funcReturnRegType(module, f);
                        }
                    }
                } else if (regs[mc.recv.int()] == .Instance and resolver != null) {
                    if (resolver.?(resolver_user.?, &regs[mc.recv.int()], mc.name, av[0..mc.n_args])) |fid| {
                        if (module.funcById(fid)) |f| {
                            if (f.is_suspend) return null;
                            if (mc.dst.int() < n_regs) member_ret[mc.dst.int()] = funcReturnRegType(module, f);
                        }
                    }
                }
                // Intrinsic/callable/continuation receivers have no FuncId to
                // inspect. Specialize the boxed result from the live loop state;
                // the callback validates that kind on every invocation.
                if (mc.dst.int() < n_regs and member_ret[mc.dst.int()] == .unknown and mc.dst.int() < regs.len) {
                    if (liveValueRegType(regs[mc.dst.int()])) |rt| member_ret[mc.dst.int()] = rt;
                }
                continue;
            }
            if (trampolinableVirtualOf(inst)) |vc| {
                if (vc.recv.int() >= n_regs or vc.recv.int() >= regs.len) return null;
                // Resolve the slot's target on the live receiver for a precise
                // return type (also what the inline path splices); fall back to
                // the live loop state — the callback's result write validates
                // the kind on every invocation.
                if (vc.dst.int() < n_regs and regs[vc.recv.int()] == .Instance and virt_resolver != null) {
                    if (virt_resolver.?(resolver_user.?, &regs[vc.recv.int()], vc.slot)) |fid| {
                        if (module.funcById(fid)) |f| {
                            if (f.is_suspend) return null;
                            member_ret[vc.dst.int()] = funcReturnRegType(module, f);
                        }
                    }
                }
                if (vc.dst.int() < n_regs and member_ret[vc.dst.int()] == .unknown and vc.dst.int() < regs.len) {
                    if (liveValueRegType(regs[vc.dst.int()])) |rt| member_ret[vc.dst.int()] = rt;
                }
                continue;
            }
            if (trampolinableFieldOf(module, inst)) |fld| {
                if (field_resolver == null) return null;
                if (fld.recv.int() >= n_regs or fld.recv.int() >= regs.len) return null;
                if (regs[fld.recv.int()] != .Instance) {
                    // Receiver snapshot null/non-instance — retry on a later snapshot.
                    transient.* = true;
                    return null;
                }
                const idx = field_resolver.?(resolver_user.?, &regs[fld.recv.int()], fld.name) orelse return null;
                const g = regs[fld.recv.int()].Instance.borrow();
                const fv: ?Value = if (idx < g.get().fields.items.len) g.get().fields.items[idx].value else null;
                g.deinit();
                // A scalar field types its dst as that scalar; an instance field
                // types it `.object` (the read writes the boxed value into regs). A
                // null/unclassifiable snapshot is transient — retry later.
                const rt = if (fv) |v| (liveValueRegType(v) orelse {
                    transient.* = true;
                    return null;
                }) else {
                    transient.* = true;
                    return null;
                };
                if (fld.dst.int() >= n_regs) return null;
                member_ret[fld.dst.int()] = rt;
                field_idx_of[fld.dst.int()] = idx;
                continue;
            }
            // Object collection subscript / map subscript: a `get`/`set` on a
            // non-packed receiver. A `Map` receiver routes to the map paths; a
            // `List`/reference `Array` element that is an instance routes to the
            // object subscript.
            if (arrayOpOf(module, inst)) |op| {
                if (op.recv.int() >= n_regs or array_info[op.recv.int()] != null) continue; // packed -> native
                if (op.recv.int() >= regs.len) return null;
                if (regs[op.recv.int()] == .Map) {
                    // Map get types its dst as a nullable scalar (the value type);
                    // map set has no result. Key/value must be scalar.
                    const vt = liveMapValueType(regs[op.recv.int()]) orelse {
                        transient.* = true; // empty map snapshot or non-scalar value
                        return null;
                    };
                    if (op.is_set) continue; // validated in the collection pass
                    if (op.dst.int() >= n_regs) return null;
                    member_ret[op.dst.int()] = vt;
                    map_get_dst[op.dst.int()] = true;
                    continue;
                }
                if (op.is_set) continue;
                if (op.index.int() >= regs.len or op.dst.int() >= n_regs) return null;
                const idx_v = regs[op.index.int()];
                const idx_i: i64 = switch (idx_v) {
                    .Int => |x| x,
                    .Long => |x| x,
                    else => {
                        transient.* = true;
                        return null;
                    },
                };
                const elem = liveElementAt(regs[op.recv.int()], idx_i) orelse {
                    transient.* = true;
                    return null;
                };
                if (liveValueRegType(elem) != .object) return null;
                member_ret[op.dst.int()] = .object;
            }
        }
    }
    if (debugEnabled()) std.debug.print("[jit]   runtime types sampled for {s} b{d}\n", .{ func.name, header.int() });

    // Whole-function type inference must run before liveness so the read/def sets
    // can recognize object registers (held in `regs`, not slots) and exclude them.
    const types = if (total_regs == n_regs)
        try inferTypes(a, module, func, n_regs, array_info, cell_info, regs, member_ret)
    else ext_blk: {
        const caller_types = try inferTypes(a, module, func, n_regs, array_info, cell_info, regs, member_ret);
        defer a.free(caller_types);
        const ext = a.alloc(RegType, total_regs) catch return null;
        @memset(ext, .unknown);
        @memcpy(ext[0..n_regs], caller_types);
        for (inline_sites.items) |*site| try fillInlineTypes(a, module, site, caller_types, ext, field_resolver, resolver_user, regs, null);
        break :ext_blk ext;
    };
    var ok = false;
    defer if (!ok) a.free(types);
    if (debugEnabled()) std.debug.print("[jit]   types inferred for {s} b{d}\n", .{ func.name, header.int() });

    // Original value kind each `.i32` register boxes back to (see `box_tags`).
    // Live-in registers keep their sampled kind; an in-loop definition
    // overrides it — `Int` unless the defining instruction names the kind (a
    // resolved callee's declared `Char`/`Short`/`Byte` return, a `Const`).
    const tags = a.alloc(u8, total_regs) catch return null;
    var tags_ok = false;
    defer if (!tags_ok) a.free(tags);
    @memset(tags, INT_TAG);
    {
        const T = std.meta.Tag(Value);
        for (regs[0..@min(regs.len, n_regs)], 0..) |v, i| {
            switch (v) {
                .Char => tags[i] = @intFromEnum(@as(T, .Char)),
                .Short => tags[i] = @intFromEnum(@as(T, .Short)),
                .Byte => tags[i] = @intFromEnum(@as(T, .Byte)),
                else => {},
            }
        }
        for (body) |bid| {
            for (func.blocks[bid.int()].insts) |*inst| {
                const def = instAnyDst(inst) orelse continue;
                if (def.int() >= total_regs) continue;
                var t: u8 = INT_TAG;
                switch (inst.*) {
                    .Move => |mv| {
                        if (mv.src.int() < total_regs) t = tags[mv.src.int()];
                    },
                    .Const => |c2| {
                        if (c2.value.int() < module.consts.items.len) {
                            switch (module.consts.items[c2.value.int()]) {
                                .Char => t = @intFromEnum(@as(T, .Char)),
                                .Short => t = @intFromEnum(@as(T, .Short)),
                                .Byte => t = @intFromEnum(@as(T, .Byte)),
                                else => {},
                            }
                        }
                    },
                    else => {
                        if (trampolinableMemberOf(module, inst)) |mc| {
                            if (mc.resolved) |fid| {
                                if (module.funcById(fid)) |f2| {
                                    const rn = f2.return_ty.name;
                                    if (std.mem.eql(u8, rn, "Char")) {
                                        t = @intFromEnum(@as(T, .Char));
                                    } else if (std.mem.eql(u8, rn, "Short")) {
                                        t = @intFromEnum(@as(T, .Short));
                                    } else if (std.mem.eql(u8, rn, "Byte")) {
                                        t = @intFromEnum(@as(T, .Byte));
                                    }
                                }
                            }
                        }
                    },
                }
                tags[def.int()] = t;
            }
        }
    }

    // A cell register's slot caches a scalar, so it must not be read or written
    // as a plain scalar anywhere in the loop (only via CellGet/CellSet). Reject
    // if any other instruction (or a branch cond) touches a cell register.
    {
        var reads: [8]Reg = undefined;
        var nr: usize = 0;
        var df: ?Reg = null;
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts) |*inst| {
                instReadsDef(module, inst, &reads, &nr, &df, types);
                for (reads[0..nr]) |rr| {
                    if (rr.int() < n_regs and cell_info[rr.int()] != null) return null;
                }
                if (df) |dd| if (dd.int() < n_regs and cell_info[dd.int()] != null) return null;
            }
            switch (blk.terminator) {
                .Branch => |br| if (br.cond.int() < n_regs and cell_info[br.cond.int()] != null) return null,
                else => {},
            }
        }
    }

    const sets = if (total_regs == n_regs)
        try computeSets(a, module, func, body, header, n_regs, types)
    else sets_blk: {
        const s = try computeSets(a, module, func, body, header, n_regs, types);
        defer {
            a.free(s.read);
            a.free(s.def);
        }
        // Extend with the inlined-callee registers (always scratch: never unboxed
        // from or reboxed to the frame's register array).
        const rd = a.alloc(bool, total_regs) catch return null;
        @memset(rd, false);
        @memcpy(rd[0..n_regs], s.read);
        const df = a.alloc(bool, total_regs) catch return null;
        @memset(df, false);
        @memcpy(df[0..n_regs], s.def);
        break :sets_blk LoopSets{ .read = rd, .def = df };
    };
    defer if (!ok) {
        a.free(sets.read);
        a.free(sets.def);
    };
    if (debugEnabled()) std.debug.print("[jit]   liveness computed for {s} b{d}\n", .{ func.name, header.int() });

    // Array-receiver regs are unboxed as arrays, not scalars; exclude them from
    // the scalar read/def sets and the scalar type requirement.
    for (arrays.items) |au| {
        sets.read[au.reg.int()] = false;
        sets.def[au.reg.int()] = false;
    }
    // Cell regs are unboxed/reboxed through their box, not the scalar sets.
    for (cells.items) |cu| {
        sets.read[cu.reg.int()] = false;
        sets.def[cu.reg.int()] = false;
    }
    // Object regs live in `regs` (a GC root), never in a slot — exclude them.
    for (0..n_regs) |r| {
        if (types[r] == .object) {
            sets.read[r] = false;
            sets.def[r] = false;
        }
    }

    // Nullable-scalar registers: a register merged from a `null` literal and a
    // scalar value. It is typed as its scalar kind but may hold null at run time,
    // tracked by a companion flag slot. Detect them (a `Move` from a `Const null`
    // into a scalar-typed register) and exclude from the scalar read/def sets —
    // a flag-aware unbox/rebox replaces the plain scalar one.
    const nullable = try a.alloc(bool, n_regs);
    defer a.free(nullable);
    @memset(nullable, false);
    {
        const is_null_const = try a.alloc(bool, n_regs);
        defer a.free(is_null_const);
        @memset(is_null_const, false);
        for (body) |bid| for (func.blocks[bid.int()].insts) |*inst| {
            if (inst.* == .Const) {
                const c = inst.Const;
                if (c.dst.int() < n_regs and module.consts.items[c.value.int()] == .Null) is_null_const[c.dst.int()] = true;
            }
        };
        for (body) |bid| for (func.blocks[bid.int()].insts) |*inst| {
            if (inst.* == .Move) {
                const m = inst.Move;
                if (m.dst.int() < n_regs and m.src.int() < n_regs and is_null_const[m.src.int()] and isScalarRt(types[m.dst.int()]))
                    nullable[m.dst.int()] = true;
            }
        };
    }
    // A `Map[key]` result is also a nullable scalar.
    for (0..n_regs) |r| {
        if (map_get_dst[r] and isScalarRt(types[r])) nullable[r] = true;
    }
    var nullables: std.ArrayListUnmanaged(NullableUnbox) = .empty;
    defer nullables.deinit(a);
    const null_flag_slot = try a.alloc(u32, n_regs);
    defer a.free(null_flag_slot);
    @memset(null_flag_slot, 0);
    for (0..n_regs) |r| {
        if (!nullable[r]) continue;
        nullables.append(a, .{ .reg = Reg.from(@intCast(r)), .rt = types[r], .flag_slot = 0, .live_in = sets.read[r], .live_out = sets.def[r] }) catch return null;
        sets.read[r] = false;
        sets.def[r] = false;
    }

    for (0..n_regs) |r| {
        if ((sets.read[r] or sets.def[r]) and types[r] == .unknown) {
            if (debugEnabled()) std.debug.print("[jit]   bail: reg {d} read/def but unknown type in {s}\n", .{ r, func.name });
            return null;
        }
    }

    // Collect and validate trampolined call sites. A call may run arbitrary code
    // (and a GC), so a loop that also indexes arrays is rejected: the array buffer
    // pointer is cached in a slot and a callee could resize the backing store,
    // leaving the cache stale. Capture cells are safe to combine with calls — the
    // callee receives reboxed scalar args, never a reference to the caller's box,
    // and the cached scalar lives in a slot written back only at loop exit.
    var call_sites: std.ArrayListUnmanaged(CallSite) = .empty;
    defer call_sites.deinit(a);
    // A method call on a loop-invariant receiver, held until the slot layout
    // exists to give its callee a window.
    const DirectPre = struct {
        block: BlockId,
        inst: u32,
        callee: FuncId,
        recv_reg: u32,
        args_reg: u32,
        n_args: u32,
        dst: Reg,
        move: BodyInstPos,
    };
    var direct_pre: std.ArrayListUnmanaged(DirectPre) = .empty;
    defer direct_pre.deinit(a);
    var skip_call_insts: std.ArrayListUnmanaged(BodyInstPos) = .empty;
    defer skip_call_insts.deinit(a);
    skip_call_insts.appendSlice(a, recv_move_skips.items) catch return null;
    // `c.bump(1)` lowers to a static call with the receiver MOVED into arg 0.
    // When that receiver is a loop-invariant instance and the callee is a
    // deopt-free compiled method, the loop calls straight into its code — so
    // neither the Move nor the call may be registered as a trampoline site.
    // Found before registration because the Move precedes the call.
    // A direct call jumps straight into the callee's code, so nothing re-seeds the
    // array cache on the way back; those loops keep the trampoline.
    if (fjDirectEnabled() and arrays.items.len == 0) {
        for (body) |bid| {
            const blk = &func.blocks[bid.int()];
            for (blk.insts, 0..) |*inst, i| {
                const tc = trampolinableCallOf(inst) orelse continue;
                if (tc.n_args == 0 or tc.n_args > 6) continue;
                const cf = module.funcById(tc.func) orelse continue;
                if (cf == func or cf.is_suspend or !cf.has_receiver_param or !cf.hasBody()) continue;
                const rs = loopReceiverSource(func, body, tc.args_reg, bid.int(), @intCast(i), types, n_regs) orelse continue;
                // A direct call seeds the callee's field base once at loop entry.
                if (regWrittenInBody(func, body, Reg.from(rs.src))) continue;
                if (rs.src >= regs.len or regs[rs.src] != .Instance) continue;
                direct_pre.append(a, .{
                    .block = bid,
                    .inst = @intCast(i),
                    .callee = tc.func,
                    .recv_reg = rs.src,
                    .args_reg = tc.args_reg,
                    .n_args = tc.n_args,
                    .dst = tc.dst,
                    .move = rs.mv,
                }) catch return null;
                skip_call_insts.append(a, .{ .b = bid.int(), .i = @intCast(i) }) catch return null;
                skip_call_insts.append(a, rs.mv) catch return null;
            }
        }
    }
    const skipCallAt = struct {
        fn f(list: []const BodyInstPos, b: u32, i: u32) bool {
            for (list) |p| {
                if (p.b == b and p.i == i) return true;
            }
            return false;
        }
    }.f;
    for (body) |bid| {
        const blk_insts = func.blocks[bid.int()].insts;
        for (blk_insts, 0..) |*inst, i| {
            // Consumed by a direct call: neither the receiver Move nor the call
            // itself reaches the host.
            if (skipCallAt(skip_call_insts.items, bid.int(), @intCast(i))) continue;
            // Same inline forms as the function tier: registering one as a
            // member/virtual site trampolines to the host once per iteration
            // for two instructions' worth of work.
            if (nativeScalarCallShape(module, inst, types, n_regs)) continue;
            const is_call = trampolinableCallOf(inst) != null;
            const is_member = trampolinableMemberOf(module, inst) != null;
            const is_virtual = trampolinableVirtualOf(inst) != null;
            const is_field = trampolinableFieldOf(module, inst) != null;
            const is_obj_move = switch (inst.*) {
                .Move => |m| typeAt(types, m.dst) == .object or typeAt(types, m.src) == .object,
                else => false,
            };
            const is_null_check = switch (inst.*) {
                .BinOp => |b| isNullCheckBinOp(types, b),
                else => false,
            };
            const map_op = if (arrayOpOf(module, inst)) |op| (op.recv.int() < regs.len and regs[op.recv.int()] == .Map) else false;
            const is_obj_index = if (arrayOpOf(module, inst)) |op| (!op.is_set and !map_op and typeAt(types, op.dst) == .object) else false;
            const is_map_get = if (arrayOpOf(module, inst)) |op| (map_op and !op.is_set) else false;
            const is_map_set = if (arrayOpOf(module, inst)) |op| (map_op and op.is_set) else false;
            const is_call_value = trampolinableCallValueOf(inst) != null;
            const is_load_global = trampolinableGlobalOf(module, inst) != null;
            const is_field_set = trampolinableFieldSetOf(module, inst) != null;
            if (!is_call and !is_member and !is_virtual and !is_field and !is_field_set and !is_obj_move and !is_null_check and !is_obj_index and !is_call_value and !is_load_global and !is_map_get and !is_map_set) continue;
            // Every scalar arg must already live in a typed slot (field reads have none).
            const args_reg: u32 = if (is_call) trampolinableCallOf(inst).?.args_reg else if (is_member) trampolinableMemberOf(module, inst).?.args_reg else if (is_virtual) trampolinableVirtualOf(inst).?.args_reg else if (is_call_value) trampolinableCallValueOf(inst).?.args_reg else 0;
            const n_args: u32 = if (is_call) trampolinableCallOf(inst).?.n_args else if (is_member) trampolinableMemberOf(module, inst).?.n_args else if (is_virtual) trampolinableVirtualOf(inst).?.n_args else if (is_call_value) trampolinableCallValueOf(inst).?.n_args else 0;
            var k: u8 = 0;
            while (k < n_args) : (k += 1) {
                const ar = args_reg + k;
                if (ar >= n_regs or !(isScalarRt(types[ar]) or types[ar] == .object or types[ar] == .null_)) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: call arg reg {d} type {s} in {s}\n", .{ ar, @tagName(types[ar]), func.name });
                    return null;
                }
            }
            // Nearest preceding `.Trace` gives the call's source span.
            var span: ?ir.Span = null;
            var bj: usize = i;
            while (bj > 0) {
                bj -= 1;
                if (blk_insts[bj] == .Trace) {
                    span = blk_insts[bj].Trace.span;
                    break;
                }
            }
            // Per-arg live-tag source through the move chain (see
            // `CallSite.arg_tag_regs`).
            var arg_tag_regs: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
            {
                var q: u8 = 0;
                while (q < n_args and q < 6) : (q += 1) {
                    arg_tag_regs[q] = argTagSourceReg(blk_insts, i, args_reg + q);
                }
            }
            if (is_load_global) {
                const lg = trampolinableGlobalOf(module, inst).?;
                if (lg.dst.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = lg.dst.int(),
                    .name = lg.name,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_load_global = true,
                }) catch return null;
            } else if (is_map_set) {
                // Map store `map[key] = value` (loop-invariant map, scalar key+value).
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.value.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index)) or !isScalarRt(typeAt(types, op.value))) return null;
                if (sets.def[op.recv.int()]) return null; // map must be loop-invariant
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .src_reg = op.value.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_map_set = true,
                }) catch return null;
            } else if (is_map_get) {
                // Map load `map[key]` -> nullable scalar (loop-invariant map, scalar key).
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.dst.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index))) return null;
                if (sets.def[op.recv.int()]) return null;
                call_sites.append(a, .{
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .dst_reg = op.dst.int(),
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_map_get = true,
                }) catch return null;
            } else if (is_call_value) {
                // Invoke a loop-invariant callable value; the result is discarded.
                const cvc = trampolinableCallValueOf(inst).?;
                if (cvc.callee.int() >= n_regs or cvc.callee.int() >= regs.len) return null;
                if (!isCallableValue(regs[cvc.callee.int()])) return null;
                // The callable must be loop-invariant: never written in the body.
                if (sets.def[cvc.callee.int()] or typeAt(types, cvc.callee) != .unknown) return null;
                call_sites.append(a, .{
                    .recv_reg = cvc.callee.int(),
                    .args_reg = cvc.args_reg,
                    .n_args = cvc.n_args,
                    .dst_reg = cvc.dst.int(),
                    .has_result = false,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                    .is_call_value = true,
                }) catch return null;
            } else if (is_obj_index) {
                // Object collection subscript: a `get` whose element is a boxed
                // object. The collection is the (loop-invariant) receiver; the
                // index is a scalar slot register.
                const op = arrayOpOf(module, inst).?;
                if (op.recv.int() >= n_regs or op.index.int() >= n_regs or op.dst.int() >= n_regs) return null;
                if (!isScalarRt(typeAt(types, op.index))) return null;
                call_sites.append(a, .{
                    .dst_reg = op.dst.int(),
                    .recv_reg = op.recv.int(),
                    .args_reg = op.index.int(),
                    .n_args = 1,
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_obj_index = true,
                }) catch return null;
            } else if (is_obj_move) {
                // Copy a boxed register into another (both live in `regs`).
                const m = inst.Move;
                if (m.dst.int() >= n_regs or m.src.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = m.dst.int(),
                    .src_reg = m.src.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_obj_move = true,
                }) catch return null;
            } else if (is_null_check) {
                // Boxed equality / identity test -> boolean slot. Both operands
                // stay in the GC-rooted frame (a null literal is synthesized by
                // the callback rather than read from its unused scalar slot).
                const b = inst.BinOp;
                if (b.lhs.int() >= n_regs or b.rhs.int() >= n_regs or b.dst.int() >= n_regs) return null;
                call_sites.append(a, .{
                    .dst_reg = b.dst.int(),
                    .recv_reg = b.lhs.int(),
                    .src_reg = b.rhs.int(),
                    .has_result = true,
                    .neg = b.op == .NotEq or b.op == .IdentNeq,
                    .identity = b.op == .IdentEq or b.op == .IdentNeq,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .is_null_check = true,
                }) catch return null;
            } else if (is_field) {
                const fld = trampolinableFieldOf(module, inst).?;
                if (fld.recv.int() >= n_regs or fld.recv.int() >= regs.len or regs[fld.recv.int()] != .Instance) return null;
                // A receiver the loop REASSIGNS (a chain cursor) re-checks its
                // class on every read and reads through the callback. One the
                // loop only reads is covered by the entry class guard, so its
                // field buffer is cached at entry and read directly.
                const recv_varies = regWrittenInBody(func, body, fld.recv);
                const rrt = member_ret[fld.dst.int()];
                if (rrt == .unknown or fld.dst.int() >= n_regs or types[fld.dst.int()] != rrt) return null;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = 0,
                    .n_args = 0,
                    .dst_reg = fld.dst.int(),
                    .has_result = true,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .recv_reg = fld.recv.int(),
                    .recv_class = instanceClassIdentity(regs[fld.recv.int()]),
                    .is_field = true,
                    .field_idx = field_idx_of[fld.dst.int()],
                    .recv_varies = recv_varies,
                }) catch return null;
            } else if (is_field_set) {
                const fs = trampolinableFieldSetOf(module, inst).?;
                if (fs.recv.int() >= n_regs or fs.recv.int() >= regs.len or regs[fs.recv.int()] != .Instance) {
                    transient.* = true;
                    return null;
                }
                if (fs.value.int() >= n_regs or !(isScalarRt(typeAt(types, fs.value)) or typeAt(types, fs.value) == .object or typeAt(types, fs.value) == .null_)) return null;
                if (field_resolver == null) return null;
                const idx = field_resolver.?(resolver_user.?, &regs[fs.recv.int()], fs.name) orelse return null;
                const recv_varies = regWrittenInBody(func, body, fs.recv);
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .src_reg = fs.value.int(),
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .recv_reg = fs.recv.int(),
                    .recv_class = instanceClassIdentity(regs[fs.recv.int()]),
                    .is_field_set = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
            } else if (is_call) {
                // An inlined call is emitted in place, not trampolined.
                var inlined = false;
                for (inline_sites.items) |s| {
                    if (s.block.int() == bid.int() and s.inst == i) {
                        inlined = true;
                        break;
                    }
                }
                if (inlined) continue;
                const tc = trampolinableCallOf(inst).?;
                const f = module.funcById(tc.func) orelse return null;
                // The callee must run as a plain interpreted call: no suspend
                // machinery, no implicit receiver to thread, and a REAL body
                // (a bodyless abstract anchor re-dispatches in the arm).
                if (f.is_suspend or f.has_receiver_param or !f.hasBody()) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: callee {s} suspend/receiver in {s}\n", .{ f.name, func.name });
                    return null;
                }
                const rrt = funcReturnRegType(module, f);
                const has_result = rrt != .unknown;
                if (has_result and (tc.dst.int() >= n_regs or types[tc.dst.int()] != rrt)) {
                    if (debugEnabled()) std.debug.print("[jit]   bail: call dst type mismatch in {s}\n", .{func.name});
                    return null;
                }
                call_sites.append(a, .{
                    .func = tc.func,
                    .args_reg = tc.args_reg,
                    .n_args = tc.n_args,
                    .dst_reg = tc.dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                }) catch return null;
            } else if (is_virtual) {
                // An inlined virtual call is emitted in place, not trampolined.
                // Only an UNGUARDED splice consumes the call: guarded arms need
                // this site as the fallback their final miss jumps to.
                var inlined_v = false;
                for (inline_sites.items) |s| {
                    if (s.block.int() == bid.int() and s.inst == i and !s.guarded) {
                        inlined_v = true;
                        break;
                    }
                }
                if (inlined_v) continue;
                const vc = trampolinableVirtualOf(inst).?;
                if (vc.recv.int() >= n_regs or vc.recv.int() >= regs.len) return null;
                // The receiver must be a boxed object register: virtual slots
                // dispatch on instances, and the host reads it straight from
                // the frame (no class guard — the dispatch itself is dynamic).
                if (typeAt(types, vc.recv) != .object and typeAt(types, vc.recv) != .unknown) return null;
                const rrt = member_ret[vc.dst.int()];
                const has_result = rrt != .unknown;
                if (has_result and (vc.dst.int() >= n_regs or types[vc.dst.int()] != rrt)) return null;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = vc.args_reg,
                    .n_args = vc.n_args,
                    .dst_reg = vc.dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                    .is_virtual = true,
                    .virt_slot = vc.slot,
                    .recv_reg = vc.recv.int(),
                }) catch return null;
            } else {
                // An inlined member call is emitted in place, not trampolined.
                var inlined_m = false;
                for (inline_sites.items) |s| {
                    if (s.block.int() == bid.int() and s.inst == i) {
                        inlined_m = true;
                        break;
                    }
                }
                if (inlined_m) continue;
                const mc = trampolinableMemberOf(module, inst).?;
                if (mc.recv.int() >= n_regs or mc.recv.int() >= regs.len) return null;
                if (mc.dispatch_recv) |dispatch| {
                    if (dispatch.int() >= n_regs or dispatch.int() >= regs.len) return null;
                }
                // A loop-invariant receiver is validated once by the entry guard; a
                // boxed receiver that varies (a chain cursor) re-checks its class on
                // every call. Either way the host reads it straight from the frame.
                const recv_varies = typeAt(types, mc.recv) == .object;
                const rrt = member_ret[mc.dst.int()];
                const has_result = rrt != .unknown;
                if (has_result and (mc.dst.int() >= n_regs or types[mc.dst.int()] != rrt)) return null;
                call_sites.append(a, .{
                    .func = @enumFromInt(0),
                    .args_reg = mc.args_reg,
                    .n_args = mc.n_args,
                    .dst_reg = mc.dst.int(),
                    .has_result = has_result,
                    .block = bid,
                    .inst = @intCast(i),
                    .span = span,
                    .arg_tag_regs = arg_tag_regs,
                    .is_member = true,
                    .recv_reg = mc.recv.int(),
                    .recv_tag_reg = argTagSourceReg(blk_insts, i, mc.recv.int()),
                    .name = mc.name,
                    .resolved_member = mc.resolved,
                    .declared_name = mc.declared,
                    .dispatch_recv_reg = if (mc.dispatch_recv) |reg| reg.int() else null,
                    .recv_class = if (regs[mc.recv.int()] == .Instance) instanceClassIdentity(regs[mc.recv.int()]) else 0,
                    .recv_varies = recv_varies or regs[mc.recv.int()] != .Instance,
                }) catch return null;
            }
        }
    }
    // Register the field-access call sites for each member inline (the body's
    // `this`-field reads/writes), contiguously, so the inline emit can reference
    // them by index. They share the call's (block, inst) — a field mismatch deopts
    // to re-run the call.
    for (inline_sites.items) |*site| {
        if (!site.is_member) continue;
        site.field_site_base = @intCast(call_sites.items.len);
        var nf: u32 = 0;
        const recv_varies = regWrittenInBody(func, body, Reg.from(site.recv_reg));
        const recv_class = instanceClassIdentity(regs[site.recv_reg]);
        for (site.callee.blocks[0].insts) |*ci| {
            if (trampolinableFieldOf(module, ci)) |fld| {
                const idx = field_resolver.?(resolver_user.?, &regs[site.recv_reg], memberFieldName(fld.name)) orelse return null;
                const dst = site.base + fld.dst.int();
                if (dst >= total_regs or !isScalarRt(types[dst])) return null;
                call_sites.append(a, .{
                    .dst_reg = dst,
                    .has_result = true,
                    .block = site.block,
                    .inst = site.inst,
                    .recv_reg = site.recv_reg,
                    .recv_class = recv_class,
                    .is_field = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
                nf += 1;
            } else if (trampolinableFieldSetOf(module, ci)) |fs| {
                const idx = field_resolver.?(resolver_user.?, &regs[site.recv_reg], memberFieldName(fs.name)) orelse return null;
                const src = site.base + fs.value.int();
                if (src >= total_regs or !isScalarRt(types[src])) return null;
                call_sites.append(a, .{
                    .dst_reg = 0,
                    .src_reg = src,
                    .block = site.block,
                    .inst = site.inst,
                    .recv_reg = site.recv_reg,
                    .recv_class = recv_class,
                    .is_field_set = true,
                    .field_idx = idx,
                    .recv_varies = recv_varies,
                }) catch return null;
                nf += 1;
            }
        }
        site.n_field_sites = nf;
    }

    const has_calls = call_sites.items.len != 0;
    const uc_slot: u32 = arr_slots;
    const tramp_slot: u32 = arr_slots + 1;
    const calls_base: u32 = arr_slots + (if (has_calls) @as(u32, 2) else 0);
    // One null-flag slot per nullable-scalar register, after the array and call slots.
    for (nullables.items, 0..) |*nu, i| {
        nu.flag_slot = calls_base + @as(u32, @intCast(i));
        null_flag_slot[nu.reg.int()] = nu.flag_slot;
    }
    const nullable_end: u32 = calls_base + @as(u32, @intCast(nullables.items.len));
    if (debugEnabled() and inline_sites.items.len != 0) std.debug.print("[jit]   inlined {d} call(s) in {s}\n", .{ inline_sites.items.len, func.name });
    // A map-get site writes the nullable result; record its dst's flag slot.
    for (call_sites.items) |*site| {
        if (site.is_map_get) site.map_flag_slot = null_flag_slot[site.dst_reg];
    }

    // Native field access: a loop-invariant scalar field read/write is emitted as a
    // direct memory access instead of a callback. One field-base pointer slot is
    // cached per receiver (after the nullable slots); the field's expected Value tag
    // is sampled from the live instance (a read deopts on a tag mismatch).
    var field_bases: std.ArrayListUnmanaged(FieldBase) = .empty;
    defer field_bases.deinit(a);
    for (call_sites.items) |*site| {
        if (!(site.is_field or site.is_field_set) or site.recv_varies) continue;
        if (site.recv_reg >= regs.len or regs[site.recv_reg] != .Instance) continue;
        const vreg: u32 = if (site.is_field) site.dst_reg else site.src_reg;
        const rt = typeAt(types, Reg.from(vreg));
        if (!isScalarRt(rt)) continue;
        // A nullable-scalar value uses a companion null-flag the native path does
        // not manage; keep it on the callback (which syncs the flag).
        if (vreg < nullable.len and nullable[vreg]) continue;
        const tag: u8 = blk: {
            const g = regs[site.recv_reg].Instance.borrow();
            defer g.deinit();
            if (site.field_idx >= g.get().fields.items.len) break :blk 0xff;
            break :blk @intFromEnum(@as(std.meta.Tag(Value), g.get().fields.items[site.field_idx].value));
        };
        if (tag == 0xff) continue;
        // Reuse an existing base slot for the same receiver.
        var ptr_slot: u32 = 0;
        var found = false;
        for (field_bases.items) |fb| {
            if (fb.recv_reg == site.recv_reg) {
                ptr_slot = fb.ptr_slot;
                found = true;
                break;
            }
        }
        if (!found) {
            ptr_slot = nullable_end + @as(u32, @intCast(field_bases.items.len));
            field_bases.append(a, .{
                .recv_reg = site.recv_reg,
                .ptr_slot = ptr_slot,
                .recv_class = instanceClassIdentity(regs[site.recv_reg]),
            }) catch return null;
        }
        site.native = true;
        site.fbase_slot = ptr_slot;
        site.tag = tag;
    }
    var n_slots: u32 = nullable_end + @as(u32, @intCast(field_bases.items.len));
    if (debugEnabled() and field_bases.items.len != 0) std.debug.print("[jit]   native field access on {d} receiver(s) in {s}\n", .{ field_bases.items.len, func.name });

    // Point every guarded arm at the trampoline site its final miss falls to.
    // An arm with no such site would have nowhere to go, so it is dropped and
    // the call simply trampolines as before.
    {
        var gi: usize = 0;
        while (gi < inline_sites.items.len) {
            const isite = &inline_sites.items[gi];
            if (!isite.guarded) {
                gi += 1;
                continue;
            }
            var found = false;
            for (call_sites.items, 0..) |cs, ci| {
                if (cs.block.int() == isite.block.int() and cs.inst == isite.inst) {
                    isite.fallback_site = @intCast(ci);
                    found = true;
                    break;
                }
            }
            if (found) gi += 1 else _ = inline_sites.orderedRemove(gi);
        }
    }
    // A guarded arm reads its receiver's `Value` out of the FRAME (objects are
    // not slot-backed), so it needs the frame register base in a slot.
    var regs_ptr_slot: u32 = 0;
    for (inline_sites.items) |*isite| {
        if (!isite.guarded) continue;
        regs_ptr_slot = n_slots;
        n_slots += 1;
        break;
    }

    // A member call on a LOOP-INVARIANT receiver whose target is a deopt-free
    // compiled method goes straight into that method's code. Loop entry already
    // proves the receiver's class (`recv_class`) and already caches its field
    // buffer for native field access, so the call needs no per-iteration guard —
    // it seeds the callee's argument slots and that cached base, and calls.
    // Without this the loop paid a host round trip per iteration to reach a body
    // that was already compiled.
    var direct_sites: std.ArrayListUnmanaged(DirectSite) = .empty;
    defer direct_sites.deinit(a);
    for (direct_pre.items) |pre| {
        const cf = module.funcById(pre.callee) orelse return null;
        const cl = directCallTarget(module, cf, pre.n_args, &regs[pre.recv_reg], resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user) orelse return null;
        if (cl.guard_class != instanceClassIdentity(regs[pre.recv_reg])) return null;
        var k: u32 = 1;
        while (k < pre.n_args) : (k += 1) {
            const ar = pre.args_reg + k;
            if (ar >= n_regs or typeAt(types, Reg.from(ar)) != cl.param_rt[k]) return null;
        }
        const wants = pre.dst.int() < n_regs and isScalarRt(typeAt(types, pre.dst));
        if (wants and typeAt(types, pre.dst) != cl.result_rt) return null;
        var base_slot: u32 = 0;
        var have_base = false;
        for (field_bases.items) |fb| {
            if (fb.recv_reg == pre.recv_reg) {
                base_slot = fb.ptr_slot;
                have_base = true;
                break;
            }
        }
        if (!have_base) {
            base_slot = n_slots;
            field_bases.append(a, .{
                .recv_reg = pre.recv_reg,
                .ptr_slot = base_slot,
                .recv_class = instanceClassIdentity(regs[pre.recv_reg]),
            }) catch return null;
            n_slots += 1;
        }
        direct_sites.append(a, .{
            .block = pre.block,
            .inst = pre.inst,
            .callee = cl,
            .slot_base = 0,
            .args_reg = pre.args_reg,
            .n_args = pre.n_args,
            .dst = pre.dst,
            .has_result = wants,
            .may_deopt = cl.can_deopt,
            .resume_at = pre.move,
            .fbase_slot = base_slot,
            .recv_reg = pre.recv_reg,
        }) catch return null;
        skip_call_insts.append(a, pre.move) catch return null;
        if (debugEnabled()) std.debug.print("[jit]   direct call {s} on a loop-invariant receiver in {s}\n", .{ cf.name, func.name });
    }
    if (fjDirectEnabled()) {
        for (call_sites.items) |*site| {
            if (!site.is_member or site.recv_varies or site.recv_class == 0) continue;
            if (site.dispatch_recv_reg != null) continue;
            const target = site.resolved_member orelse continue;
            if (site.recv_reg >= regs.len or regs[site.recv_reg] != .Instance) continue;
            const cf = module.funcById(target) orelse continue;
            if (cf == func) continue;
            // The emitter reads callee parameter `i` from `args_reg + i`, and a
            // member site's arguments start at `args_reg`, so the base is biased
            // by one — it must not wrap.
            if (site.n_args != 0 and site.args_reg == 0) continue;
            const cl = directCallTarget(module, cf, site.n_args + 1, &regs[site.recv_reg], resolver, virt_resolver, field_resolver, field_nn_resolver, resolver_user) orelse continue;
            if (cl.guard_class != site.recv_class) continue;
            // Arguments live in typed scalar slots and must be the kinds the
            // callee was specialized on; the result likewise.
            var ok_args = true;
            var k: u32 = 0;
            while (k < site.n_args) : (k += 1) {
                const ar = site.args_reg + k;
                if (ar >= n_regs or typeAt(types, Reg.from(ar)) != cl.param_rt[k + 1]) ok_args = false;
            }
            if (!ok_args) continue;
            const wants_result = site.has_result and site.dst_reg < n_regs and isScalarRt(typeAt(types, Reg.from(site.dst_reg)));
            if (wants_result and typeAt(types, Reg.from(site.dst_reg)) != cl.result_rt) continue;
            // Reuse (or mint) the loop-entry field base for this receiver.
            var base_slot: u32 = 0;
            var have_base = false;
            for (field_bases.items) |fb| {
                if (fb.recv_reg == site.recv_reg) {
                    base_slot = fb.ptr_slot;
                    have_base = true;
                    break;
                }
            }
            if (!have_base) {
                base_slot = n_slots;
                field_bases.append(a, .{
                    .recv_reg = site.recv_reg,
                    .ptr_slot = base_slot,
                    .recv_class = instanceClassIdentity(regs[site.recv_reg]),
                }) catch return null;
                n_slots += 1;
            }
            direct_sites.append(a, .{
                .block = site.block,
                .inst = site.inst,
                .callee = cl,
                .slot_base = 0,
                .args_reg = site.args_reg -% 1, // callee param i reads args_reg + i
                .n_args = site.n_args + 1,
                .dst = Reg.from(site.dst_reg),
                .has_result = wants_result,
                .may_deopt = cl.can_deopt,
                .resume_at = .{ .b = site.block.int(), .i = site.inst },
                .fbase_slot = base_slot,
                .recv_reg = site.recv_reg,
            }) catch return null;
            if (debugEnabled()) std.debug.print("[jit]   direct member call {s} in {s}\n", .{ cf.name, func.name });
        }
        if (direct_sites.items.len != 0) {
            var window: u32 = 0;
            for (direct_sites.items) |*ds| {
                ds.slot_base = n_slots;
                if (ds.callee.n_slots > window) window = ds.callee.n_slots;
            }
            n_slots += window;
            if (n_slots > MAX_SLOTS) return null;
        }
    }

    var c = Compiler{
        .a = a,
        .module = module,
        .func = func,
        .body = body,
        .types = types,
        .array_info = array_info,
        .cell_info = cell_info,
        .call_sites = call_sites.items,
        .inline_sites = inline_sites.items,
        .direct_sites = direct_sites.items,
        .skip_insts = skip_call_insts.items,
        .regs_ptr_slot = regs_ptr_slot,
        .nullable = nullable,
        .null_flag_slot = null_flag_slot,
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .n_regs = n_regs,
        .reg_slots = total_regs,
        .val_payload_off = valuePayloadOffset(),
        .val_tag_off = valueTagOffset(),
        .em = jit.Emitter.init(a),
        .block_label = try a.alloc(?jit.Label, func.blocks.len),
        .exit_targets = .empty,
        .exit_labels = .empty,
        .deopt_codes = .empty,
        .deopt_labels = .empty,
        .epilogue = undefined,
    };
    defer c.em.deinit();
    defer a.free(c.block_label);
    defer c.exit_targets.deinit(a);
    defer c.exit_labels.deinit(a);
    defer c.deopt_codes.deinit(a);
    defer c.deopt_labels.deinit(a);
    @memset(c.block_label, null);

    for (body) |bid| c.block_label[bid.int()] = c.em.newLabel() catch return null;
    c.epilogue = c.em.newLabel() catch return null;

    c.run() catch |e| {
        if (debugEnabled()) std.debug.print("[jit]   bail: codegen {s} in {s}\n", .{ @errorName(e), func.name });
        return null;
    };

    const exec = jit.finalize(c.em.code()) catch return null;
    const arrays_owned = arrays.toOwnedSlice(a) catch return null;
    const cells_owned = cells.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        return null;
    };
    const sites_owned = call_sites.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        return null;
    };
    const nullables_owned = nullables.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        a.free(sites_owned);
        return null;
    };
    const fbases_owned = field_bases.toOwnedSlice(a) catch {
        a.free(arrays_owned);
        a.free(cells_owned);
        a.free(sites_owned);
        a.free(nullables_owned);
        return null;
    };
    ok = true;
    tags_ok = true;
    return CompiledLoop{
        .exec = exec,
        // Inlined-callee registers extend the register space; the unbox/rebox
        // loops range over all of them (the inline ones are scratch — skipped).
        .n_regs = total_regs,
        .n_slots = n_slots,
        .reg_types = types,
        .box_tags = tags,
        .read_set = sets.read,
        .def_set = sets.def,
        .arrays = arrays_owned,
        .cells = cells_owned,
        .nullables = nullables_owned,
        .field_bases = fbases_owned,
        .regs_ptr_slot = regs_ptr_slot,
        .direct_sites = if (direct_sites.items.len != 0)
            (a.dupe(DirectSite, direct_sites.items) catch return null)
        else
            &.{},
        .call_sites = sites_owned,
        .member_ics = blk: {
            const ics = a.alloc(MemberIC, sites_owned.len) catch break :blk &.{};
            @memset(ics, .{});
            break :blk ics;
        },
        .uc_slot = uc_slot,
        .tramp_slot = tramp_slot,
        .allocator = a,
    };
}
