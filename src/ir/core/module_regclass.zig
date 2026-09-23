//! What class a register holds, read off the lowered IR.
//!
//! The receiver deriver answers "what is this expression's type" from the AST,
//! and where Kotlin's inference needs a step the deriver does not take — a
//! generic return, a loop variable, a lambda parameter — it answers nothing,
//! and every field read and member call on that receiver stays on the name.
//!
//! The lowered function already carries the answer for a large share of those:
//! a register written by `NewInstance` holds that class, one written by a
//! `Call` holds the callee's declared return, and a `Move` holds what its
//! source holds. None of that needs type inference; it needs the definitions
//! read in order.
//!
//! The lattice is the usual one and the iteration is optimistic: every
//! register starts at `top` (no definition seen), a definition whose class is
//! known lowers it to that class, a second definition of a different class or
//! any definition whose class is unknown lowers it to `bottom`. Values only
//! ever move down, so the fixpoint terminates, and a register left at `top`
//! has no reaching definition and is reported as unknown.

const std = @import("std");

const runtime = @import("runtime");

const core_class = @import("class.zig");
const core_ids = @import("ids.zig");
const core_inst = @import("inst.zig");
const m_static = @import("module_static.zig");
const m_props = @import("module_props.zig");
const m_fields = @import("module_fields.zig");
const applicability = @import("applicability");

const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const Inst = core_inst.Inst;
const Allocator = std.mem.Allocator;

const Module = @import("../ir.zig").Module;
const Func = @import("func.zig").Func;

/// `top` is "no definition reached this register yet", `bottom` "the
/// definitions disagree, or one of them holds a class this pass cannot name".
pub const RegClass = union(enum) {
    top,
    /// The register's declared type head, and the module class it names when
    /// one does. A host-backed classifier — `IntArray`, `String` — has a head
    /// and no class: no slot can be claimed against it, but the head is what
    /// proves a builtin property.
    known: Ty,
    bottom,

    pub const Ty = struct { head: []const u8, cid: ?ClassId };

    pub fn meet(self: RegClass, other: RegClass) RegClass {
        if (self == .bottom or other == .bottom) return .bottom;
        if (self == .top) return other;
        if (other == .top) return self;
        return if (std.mem.eql(u8, self.known.head, other.known.head)) self else .bottom;
    }

    pub fn classId(self: RegClass) ?ClassId {
        return switch (self) {
            .known => |t| t.cid,
            else => null,
        };
    }

    pub fn head(self: RegClass) ?[]const u8 {
        return switch (self) {
            .known => |t| t.head,
            else => null,
        };
    }
};

/// The class a type head names, when exactly one class answers to it and that
/// class holds interpreted instances. A host-backed classifier is not one: its
/// values carry no module class, so a slot claimed against it reads nothing.
fn tyOfHead(self: *const Module, head_in: []const u8) ?RegClass.Ty {
    const head = m_static.staticTypeHead(std.mem.trimEnd(u8, head_in, "?"));
    if (head.len == 0) return null;
    const cid = self.classIdByFqn(head) orelse self.uniqueClassIdBySimpleName(head) orelse return null;
    if (cid.int() >= self.classes.items.len) return null;
    const c = &self.classes.items[cid.int()];
    // A host-backed classifier or a placeholder holds no interpreted layout,
    // so nothing can claim a slot against it; its head still identifies it.
    if (c.is_stub or c.is_intrinsic_backed) return .{ .head = c.fqn, .cid = null };
    return .{ .head = c.fqn, .cid = cid };
}

fn declaredReturnTy(self: *const Module, fid: FuncId) ?RegClass.Ty {
    const f = self.funcById(fid) orelse return null;
    // An unannotated expression body carries `Unit` as a placeholder, not as
    // evidence, which is what `return_ty_declared` is for.
    if (!f.return_ty_declared) return null;
    if (f.return_ty.nullable) return null;
    return tyOfHead(self, f.return_ty.name);
}

/// What one instruction's destination register holds, given what the registers
/// it reads currently hold. Null means the instruction writes no register.
fn defClass(self: *const Module, f: *const Func, inst: *const Inst, state: []const RegClass) ?RegClass {
    switch (inst.*) {
        .NewInstance => |ni| {
            if (ni.class.int() >= self.classes.items.len) return .bottom;
            const c = &self.classes.items[ni.class.int()];
            if (c.is_stub) return .bottom;
            return .{ .known = .{ .head = c.fqn, .cid = if (c.is_intrinsic_backed) null else ni.class } };
        },
        .Move => |mv| return if (mv.src.int() < state.len) state[mv.src.int()] else .bottom,
        // `x!!` narrows nullability, never the class.
        .NotNullAssert => |nn| return if (nn.src.int() < state.len) state[nn.src.int()] else .bottom,
        .LateinitCheck => |lc| return if (lc.src.int() < state.len) state[lc.src.int()] else .bottom,
        // `x as T` says what the register holds from there on. A SAFE cast can
        // write null instead, so it says nothing.
        .Cast => |c| {
            if (c.safe or c.ty.nullable) return .bottom;
            return if (tyOfHead(self, c.ty.name)) |t| .{ .known = t } else .bottom;
        },
        .Call => |c| return if (declaredReturnTy(self, c.func)) |t| .{ .known = t } else .bottom,
        .CallVirtual => |cv| return if (declaredReturnTy(self, FuncId.from(cv.slot.int()))) |t|
            .{ .known = t }
        else
            .bottom,
        .LoadParam => |lp| {
            if (lp.idx >= f.params.len) return .bottom;
            const p = &f.params[lp.idx];
            if (p.ty.nullable or p.is_vararg) return .bottom;
            return if (tyOfHead(self, p.ty.name)) |t| .{ .known = t } else .bottom;
        },
        // A member call the lowering resolved names its declaration, whose
        // declared return types the result exactly as a `Call`'s does.
        .CallMember => |cm| {
            const fid = cm.x().resolved orelse return .bottom;
            return if (declaredReturnTy(self, fid)) |t| .{ .known = t } else .bottom;
        },
        // A field read the route pass bound to a getter is that getter's call;
        // one bound to a declared slot holds that property's declared type.
        .GetField => |gf| switch (gf.own_kind) {
            .getter => return if (declaredReturnTy(self, FuncId.from(gf.own_slot))) |t|
                .{ .known = t }
            else
                .bottom,
            .slot => {
                const cid = gf.own_cls orelse return .bottom;
                const entry = m_fields.classFieldLayout(self, cid) orelse return .bottom;
                if (gf.own_slot >= entry.slots.len) return .bottom;
                const head = entry.slots[gf.own_slot].type_head;
                if (head.len == 0) return .bottom;
                return if (tyOfHead(self, head)) |t| .{ .known = t } else .bottom;
            },
            else => return .bottom,
        },
        // A bare `object` read is the singleton, so the register holds an
        // instance of that class. A constructor or type reference is the
        // classifier itself, which is a different value.
        .LoadGlobal => |lg| {
            if (lg.ctor_ref or lg.type_qualifier) return .bottom;
            const cid = lg.class orelse return .bottom;
            if (cid.int() >= self.classes.items.len) return .bottom;
            const c = &self.classes.items[cid.int()];
            if (!c.is_object or c.is_intrinsic_backed) return .bottom;
            return .{ .known = .{ .head = c.fqn, .cid = cid } };
        },
        else => {},
    }
    // Every other instruction that writes a register writes something this
    // pass cannot name. Reflection rather than a list, so an instruction added
    // later is unknown rather than silently absent.
    var has_dst = false;
    core_inst.visitInstRegs(inst, &has_dst, struct {
        fn cb(ctx: *bool, r: core_ids.Reg, is_def: bool) void {
            _ = r;
            if (is_def) ctx.* = true;
        }
    }.cb);
    return if (has_dst) .bottom else null;
}

fn defReg(inst: *const Inst) ?core_ids.Reg {
    const Found = struct { r: ?core_ids.Reg = null };
    var found: Found = .{};
    core_inst.visitInstRegs(inst, &found, struct {
        fn cb(ctx: *Found, r: core_ids.Reg, is_def: bool) void {
            if (is_def and ctx.r == null) ctx.r = r;
        }
    }.cb);
    return found.r;
}

/// Fill `state` with what each of the function's registers holds. `state` must
/// be at least `f.n_locals` long.
pub fn inferRegisterClasses(self: *const Module, f: *const Func, state: []RegClass) void {
    @memset(state, .top);
    // A register a catch handler or a label absorb writes takes a value no
    // instruction produced, so nothing here can name it.
    for (f.blocks) |*b| {
        const h = b.h();
        for (h.catches) |c| {
            if (c.exception_reg.int() < state.len) state[c.exception_reg.int()] = .bottom;
        }
        if (h.lr_absorb) |lr| {
            if (lr.value_reg.int() < state.len) state[lr.value_reg.int()] = .bottom;
        }
    }
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        var changed = false;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                const produced = defClass(self, f, inst, state) orelse continue;
                const dst = defReg(inst) orelse continue;
                if (dst.int() >= state.len) continue;
                const next = state[dst.int()].meet(produced);
                if (!std.meta.eql(next, state[dst.int()])) {
                    state[dst.int()] = next;
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

/// Record, on every field read the receiver deriver left without one, the
/// class the receiver register's own definitions name.
///
/// `GetField.own_cls` is a hint and never an index: `linkGetterRoutes` runs
/// after this and turns the ones it can prove into a slot, a getter or a
/// property slot, under the guards that make a claim safe against a subclass.
/// A register whose definitions disagree, or whose producer holds a class this
/// pass cannot name, records nothing.
///
/// `KLIO_REGCLASS=0` withdraws it.
pub fn linkReceiverClasses(self: *Module, allocator: Allocator) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_REGCLASS") orelse "1", "0")) return;
    var filled: usize = 0;
    var open: usize = 0;
    var state: std.ArrayList(RegClass) = .empty;
    defer state.deinit(allocator);
    for (self.funcs.items) |*f| {
        if (f.blocks.len == 0) continue;
        var any = false;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .GetField and inst.GetField.own_kind == .none and
                    inst.GetField.own_cls == null)
                {
                    any = true;
                    break;
                }
            }
            if (any) break;
        }
        if (!any) continue;
        state.resize(allocator, f.n_locals) catch continue;
        inferRegisterClasses(self, f, state.items);
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .GetField) continue;
                const gf = &inst.GetField;
                if (gf.own_kind != .none or gf.own_cls != null) continue;
                if (gf.receiver.int() >= state.items.len) {
                    open += 1;
                    continue;
                }
                const cid = state.items[gf.receiver.int()].classId() orelse {
                    open += 1;
                    continue;
                };
                gf.own_cls = cid;
                filled += 1;
            }
        }
    }
    if (runtime.envOnce("KLIO_REGCLASS_PROBE") != null)
        std.debug.print("[regclass-link] field_read_class_filled={d} still_none={d}\n", .{ filled, open });
}

/// Heads whose `size` is the array's own length. `Array` covers the boxed
/// form; the unsigned array classes are value classes wrapping one, so their
/// `size` is a declared property with a body and not this.
/// Every classifier the runtime represents as an `Array` value. An unsigned
/// array is a view over the signed buffer of the same length, so the element
/// count these properties report is the same one.
const array_size_heads = [_][]const u8{
    "kotlin.Array",       "kotlin.IntArray",     "kotlin.LongArray",
    "kotlin.ByteArray",   "kotlin.ShortArray",   "kotlin.FloatArray",
    "kotlin.DoubleArray", "kotlin.CharArray",    "kotlin.BooleanArray",
    "kotlin.UIntArray",   "kotlin.ULongArray",   "kotlin.UShortArray",
    "kotlin.UByteArray",
};

fn headServesBuiltin(head: []const u8, which: core_inst.BuiltinField, index_props_ok: bool) bool {
    return switch (which) {
        .none => false,
        .array_last_index, .array_indices => index_props_ok and for (array_size_heads) |h| {
            if (std.mem.eql(u8, h, head)) break true;
        } else false,
        .array_size => for (array_size_heads) |h| {
            if (std.mem.eql(u8, h, head)) break true;
        } else false,
        .string_length => std.mem.eql(u8, head, "kotlin.String"),
        // A value class over a signed buffer or scalar: the backing is the
        // read, and only the unsigned classifiers have one.
        .array_storage => for (unsigned_array_heads) |h| {
            if (std.mem.eql(u8, h, head)) break true;
        } else false,
        .scalar_data => for (unsigned_scalar_heads) |h| {
            if (std.mem.eql(u8, h, head)) break true;
        } else false,
    };
}

const unsigned_array_heads = [_][]const u8{
    "kotlin.UIntArray", "kotlin.ULongArray", "kotlin.UShortArray", "kotlin.UByteArray",
};
const unsigned_scalar_heads = [_][]const u8{
    "kotlin.UInt", "kotlin.ULong", "kotlin.UShort", "kotlin.UByte",
};

/// Prove the builtin property a field read names, where the receiver's static
/// head is the host classifier that DECLARES it.
///
/// A declared member cannot be shadowed by a user extension, and a host
/// classifier holds no interpreted layout for a slot to be claimed against, so
/// this is the only resolved form these reads have. Proving it is what lets
/// the runtime's tag test be an assertion rather than a derivation.
///
/// `KLIO_BUILTIN_FIELD=0` withdraws it.
pub fn linkBuiltinFields(self: *Module, allocator: Allocator, index_props_ok: bool) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_BUILTIN_FIELD") orelse "1", "0")) return;
    var proven: usize = 0;
    var open: usize = 0;
    var state: std.ArrayList(RegClass) = .empty;
    defer state.deinit(allocator);
    for (self.funcs.items) |*f| {
        if (f.blocks.len == 0) continue;
        var any = false;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .GetField and inst.GetField.builtin != .none and
                    !inst.GetField.builtin_proven and inst.GetField.own_kind == .none)
                {
                    any = true;
                    break;
                }
            }
            if (any) break;
        }
        if (!any) continue;
        state.resize(allocator, f.n_locals) catch continue;
        inferRegisterClasses(self, f, state.items);
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .GetField) continue;
                const gf = &inst.GetField;
                if (gf.builtin == .none or gf.builtin_proven or gf.own_kind != .none) continue;
                const h = if (gf.receiver.int() < state.items.len)
                    state.items[gf.receiver.int()].head()
                else
                    null;
                if (h != null and headServesBuiltin(h.?, gf.builtin, index_props_ok)) {
                    gf.builtin_proven = true;
                    proven += 1;
                } else {
                    open += 1;
                }
            }
        }
    }
    if (runtime.envOnce("KLIO_REGCLASS_PROBE") != null)
        std.debug.print("[builtin-field] proven={d} open={d}\n", .{ proven, open });
}

/// Prove the builtin OPERATION a member call names, where the receiver's
/// static head is a classifier whose values are never interpreted instances.
///
/// `linkBuiltinMembers` asks the same question of the head lowering recorded
/// on the site, and most sites record none. The register's own definitions
/// name one for many more: an array parameter, an array-returning call, a
/// register moved from either.
///
/// `KLIO_BUILTIN_PROVEN=0` withdraws it, as it does the recorded-head pass.
pub fn linkBuiltinMemberRegs(self: *Module, allocator: Allocator) void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_BUILTIN_PROVEN") orelse "1", "0")) return;
    const host_only = m_props.hostOnlyHeads(self);
    var proven: usize = 0;
    var open: usize = 0;
    var state: std.ArrayList(RegClass) = .empty;
    defer state.deinit(allocator);
    for (self.funcs.items) |*f| {
        if (f.blocks.len == 0) continue;
        var any = false;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .CallMember and inst.CallMember.builtin != .none and
                    !inst.CallMember.builtin_proven)
                {
                    any = true;
                    break;
                }
            }
            if (any) break;
        }
        if (!any) continue;
        state.resize(allocator, f.n_locals) catch continue;
        inferRegisterClasses(self, f, state.items);
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = &inst.CallMember;
                if (cm.builtin == .none or cm.builtin_proven) continue;
                const h = if (cm.receiver.int() < state.items.len)
                    state.items[cm.receiver.int()].head()
                else
                    null;
                if (h != null and m_props.builtinValueHead(h.?, cm.builtin, host_only)) {
                    cm.builtin_proven = true;
                    proven += 1;
                } else {
                    open += 1;
                }
            }
        }
    }
    if (runtime.envOnce("KLIO_REGCLASS_PROBE") != null)
        std.debug.print("[builtin-member-reg] proven={d} open={d}\n", .{ proven, open });
}

/// `KLIO_REGCLASS_PROBE=1`: how many field reads the receiver deriver left
/// without a class the register's own definitions name.
pub fn probeRegisterClasses(self: *const Module, allocator: Allocator) void {
    if (runtime.envOnce("KLIO_REGCLASS_PROBE") == null) return;
    var read_no_cls: usize = 0;
    var read_gained: usize = 0;
    var no_producer: usize = 0;
    const n_tags = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields.len;
    var producer: [n_tags]usize = @splat(0);
    // bad index, vararg, empty head, no class of that name, nullable, host-backed or stub
    var param_why: [6]usize = @splat(0);
    var call_no_cls: usize = 0;
    var call_gained: usize = 0;
    var call_with_args: usize = 0;
    var call_virtual: usize = 0;
    var call_direct: usize = 0;
    var call_deferred: usize = 0;
    var state: std.ArrayList(RegClass) = .empty;
    defer state.deinit(allocator);
    for (self.funcs.items) |*f| {
        if (f.blocks.len == 0) continue;
        state.resize(allocator, f.n_locals) catch continue;
        inferRegisterClasses(self, f, state.items);
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                switch (inst.*) {
                    .GetField => |gf| {
                        if (gf.own_kind != .none or gf.own_cls != null) continue;
                        read_no_cls += 1;
                        if (gf.receiver.int() < state.items.len and
                            state.items[gf.receiver.int()].classId() != null) {
                            read_gained += 1;
                            continue;
                        }
                        // What writes the register this read could not name.
                        // A register with several writers is counted once per
                        // distinct writer tag, so the tally says which
                        // producers the lattice would have to learn.
                        var seen_def = false;
                        for (f.blocks) |*b2| {
                            for (b2.insts) |*d| {
                                const dr = defReg(d) orelse continue;
                                if (dr.int() != gf.receiver.int()) continue;
                                seen_def = true;
                                const t = @intFromEnum(std.meta.activeTag(d.*));
                                if (t < producer.len) producer[t] += 1;
                                if (d.* == .LoadParam) {
                                    const lp = d.LoadParam;
                                    if (lp.idx >= f.params.len) {
                                        param_why[0] += 1;
                                    } else {
                                        const pp = &f.params[lp.idx];
                                        const head = m_static.staticTypeHead(std.mem.trimEnd(u8, pp.ty.name, "?"));
                                        if (pp.is_vararg) {
                                            param_why[1] += 1;
                                        } else if (head.len == 0) {
                                            param_why[2] += 1;
                                        } else if (self.classIdByFqn(head) == null and
                                            self.uniqueClassIdBySimpleName(head) == null)
                                        {
                                            param_why[3] += 1;
                                            if (runtime.envOnce("KLIO_REGCLASS_PARAM") != null)
                                                std.debug.print("[regclass-param] no-class {s} in={s}\n", .{ pp.ty.name, f.fqn });
                                        } else if (pp.ty.nullable) {
                                            param_why[4] += 1;
                                        } else {
                                            param_why[5] += 1;
                                            if (runtime.envOnce("KLIO_REGCLASS_PARAM") != null) {
                                                const fname = switch (self.consts.items[gf.field.int()]) {
                                                    .String => |str| str,
                                                    else => "?",
                                                };
                                                std.debug.print("[regclass-param] host-or-stub {s}.{s} in={s}\n", .{ pp.ty.name, fname, f.fqn });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (!seen_def) no_producer += 1;
                    },
                    .CallMember => |cm| {
                        if (cm.x().resolved != null) continue;
                        call_no_cls += 1;
                        const cid = if (cm.receiver.int() < state.items.len)
                            state.items[cm.receiver.int()].classId()
                        else
                            null;
                        if (cid == null) continue;
                        call_gained += 1;
                        const nm = switch (self.consts.items[cm.name.int()]) {
                            .String => |str| str,
                            else => continue,
                        };
                        // Argument shapes from the same register classes: the
                        // run `args .. args + n_args` is the call's arguments.
                        var shapes: [16]applicability.ArgShape = undefined;
                        if (cm.n_args > shapes.len) {
                            call_with_args += 1;
                            continue;
                        }
                        var all_known = true;
                        for (0..cm.n_args) |ai| {
                            const ar = cm.args.int() + @as(u32, @intCast(ai));
                            const acid = if (ar < state.items.len) state.items[ar].classId() else null;
                            if (acid == null) {
                                all_known = false;
                                break;
                            }
                            shapes[ai] = .{ .ty = .{
                                .name = self.classes.items[acid.?.int()].fqn,
                                .nullable = false,
                                .args = &.{},
                            } };
                        }
                        if (!all_known) {
                            call_with_args += 1;
                            continue;
                        }
                        const r = self.resolveMemberCall(cid.?, nm, shapes[0..cm.n_args], .{
                            .caller_file = if (self.decl_span.get(f.id.int())) |sp| sp.file else null,
                        });
                        switch (r.dispatch) {
                            .virtual => if (r.target != null) {
                                call_virtual += 1;
                            } else {
                                call_deferred += 1;
                            },
                            .direct => call_direct += 1,
                            .deferred => call_deferred += 1,
                        }
                    },
                    else => {},
                }
            }
        }
    }
    std.debug.print("[regclass] field_read_no_class={d} gains_class={d}  call_member_unresolved={d} gains_class={d}\n", .{
        read_no_cls, read_gained, call_no_cls, call_gained,
    });
    std.debug.print("[regclass] nullary_with_class: virtual={d} direct={d} deferred={d}  with_args={d}\n", .{
        call_virtual, call_direct, call_deferred, call_with_args,
    });
    std.debug.print("[regclass] classless receivers with no writing instruction={d}\n", .{no_producer});
    std.debug.print("[regclass-param] bad_idx={d} vararg={d} empty_head={d} no_class={d} nullable={d} host_or_stub={d}\n", .{
        param_why[0], param_why[1], param_why[2], param_why[3], param_why[4], param_why[5],
    });
    inline for (@typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields) |fl| {
        if (producer[fl.value] != 0)
            std.debug.print("[regclass-producer] {d:>7}  {s}\n", .{ producer[fl.value], fl.name });
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "the lattice meets on the head and keeps the class apart" {
    const a: RegClass = .{ .known = .{ .head = "pkg.A", .cid = ClassId.from(1) } };
    const b: RegClass = .{ .known = .{ .head = "pkg.B", .cid = ClassId.from(2) } };
    const host: RegClass = .{ .known = .{ .head = "kotlin.IntArray", .cid = null } };
    try std.testing.expectEqual(RegClass.top, (RegClass{ .top = {} }).meet(.top));
    // `top` is no information, so it takes the other side.
    try std.testing.expect((RegClass{ .top = {} }).meet(a) == .known);
    try std.testing.expect(a.meet(a) == .known);
    // Definitions that disagree name nothing.
    try std.testing.expect(a.meet(b) == .bottom);
    try std.testing.expect(a.meet(.bottom) == .bottom);
    // A host classifier carries a head with no class: no slot can be claimed
    // against it, and the head is what proves a builtin property.
    try std.testing.expect(host.classId() == null);
    try std.testing.expectEqualStrings("kotlin.IntArray", host.head().?);
    try std.testing.expect(headServesBuiltin("kotlin.IntArray", .array_size, true));
    // An unsigned array is a view over a signed buffer of the same length.
    try std.testing.expect(headServesBuiltin("kotlin.UIntArray", .array_size, true));
    try std.testing.expect(headServesBuiltin("kotlin.String", .string_length, true));
    try std.testing.expect(!headServesBuiltin("kotlin.String", .array_size, true));
    // `indices` and `lastIndex` are shadowable, so the head alone does not
    // prove them: a build that declares either name withdraws the whole class.
    try std.testing.expect(headServesBuiltin("kotlin.IntArray", .array_last_index, true));
    try std.testing.expect(!headServesBuiltin("kotlin.IntArray", .array_last_index, false));
    try std.testing.expect(headServesBuiltin("kotlin.IntArray", .array_indices, true));
    try std.testing.expect(!headServesBuiltin("kotlin.IntArray", .array_indices, false));
    // `size` is a declared member, not shadowable, so the verdict does not reach it.
    try std.testing.expect(headServesBuiltin("kotlin.IntArray", .array_size, false));
}

/// How many declarations of `name` the class and its ancestors carry. One
/// means argument shapes cannot change the pick.
///
/// `Class.methods` holds executable bodies only — an interface's abstract
/// header is absent from it, which is why a count taken there reported zero
/// for every `Comparator.compare`. The canonical table is `decl_sigs`, the
/// same one the slot linker reads.
fn countHierarchyDecls(self: *const Module, cid: ClassId, name: []const u8) usize {
    var n: usize = 0;
    if (cid.int() >= self.classes.items.len) return 0;
    n += countDeclSigs(self, cid, name);
    if (cid.int() < self.class_ancestors.items.len) {
        for (self.class_ancestors.items[cid.int()]) |anc| n += countDeclSigs(self, anc, name);
    }
    for (self.classes.items[cid.int()].methods) |fid| {
        const g = self.funcById(fid) orelse continue;
        if (std.mem.eql(u8, g.name, name)) n += 1;
    }
    if (cid.int() < self.class_ancestors.items.len) {
        for (self.class_ancestors.items[cid.int()]) |anc| {
            if (anc.int() >= self.classes.items.len) continue;
            for (self.classes.items[anc.int()].methods) |fid| {
                const g = self.funcById(fid) orelse continue;
                if (std.mem.eql(u8, g.name, name)) n += 1;
            }
        }
    }
    // The name-keyed supertype chain reaches edges the ancestor closure does
    // not, which is why `hierarchyDeclaresMethod` asks both.
    const c = &self.classes.items[cid.int()];
    const chain: []const []const u8 = self.registry.class_super_names.get(c.name) orelse &.{};
    for (chain) |sup| {
        const sid = self.classIdByFqn(sup) orelse self.classId(sup) orelse continue;
        if (sid.int() >= self.classes.items.len) continue;
        for (self.classes.items[sid.int()].methods) |fid| {
            const g = self.funcById(fid) orelse continue;
            if (std.mem.eql(u8, g.name, name)) n += 1;
        }
    }
    return n;
}

/// Instance-method declarations of `name` owned by exactly `cid`.
fn countDeclSigs(self: *const Module, cid: ClassId, name: []const u8) usize {
    var n: usize = 0;
    var it = self.decl_sigs.iterator();
    while (it.next()) |e| {
        const owner = e.value_ptr.enclosing_class orelse continue;
        if (owner.int() != cid.int()) continue;
        if (e.value_ptr.kind != .instance_method) continue;
        const g = self.funcById(FuncId.from(e.key_ptr.*)) orelse continue;
        if (std.mem.eql(u8, g.name, name)) n += 1;
    }
    return n;
}

/// `KLIO_MEMBER_PROBE=1`: why each member call that still dispatches by name
/// does. The receiver class comes from the site's recorded head where it has
/// one and from the register's definitions otherwise, so the split separates
/// "no receiver type" from the questions that have one.
pub fn probeMemberByName(self: *Module, allocator: Allocator) void {
    if (runtime.envOnce("KLIO_MEMBER_PROBE") == null) return;
    // no class, host-backed class, hierarchy declares it, an extension could
    // serve it, nothing declares it
    var why: [5]usize = @splat(0);
    // arg heads unknown, virtual with a target, virtual with none, direct, deferred
    var decl_why: [5]usize = @splat(0);
    var sole_decl: usize = 0;
    var zero_decl: usize = 0;
    var by_arity: usize = 0;
    var by_arity_simple: usize = 0;
    var by_arity_ambig: usize = 0;
    const n_tags2 = @typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields.len;
    var recv_producer: [n_tags2]usize = @splat(0);
    // bad index, vararg, empty head, no class of that name, nullable, host-backed or stub
    var recv_param_why: [6]usize = @splat(0);
    var state: std.ArrayList(RegClass) = .empty;
    defer state.deinit(allocator);
    const names_on = runtime.envOnce("KLIO_MEMBER_PROBE_NAMES") != null;
    for (self.funcs.items) |*f| {
        if (f.blocks.len == 0) continue;
        var any = false;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* == .CallMember and inst.CallMember.x().resolved == null and
                    !inst.CallMember.builtin_proven)
                {
                    any = true;
                    break;
                }
            }
            if (any) break;
        }
        if (!any) continue;
        state.resize(allocator, f.n_locals) catch continue;
        inferRegisterClasses(self, f, state.items);
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = inst.CallMember;
                if (cm.x().resolved != null or cm.builtin_proven) continue;
                const nm = switch (self.consts.items[cm.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                const ty: ?RegClass.Ty = blk: {
                    if (cm.x().static_recv) |sr| {
                        if (sr.int() < self.consts.items.len and self.consts.items[sr.int()] == .String) {
                            const h = m_static.staticTypeHead(std.mem.trimEnd(u8, self.consts.items[sr.int()].String, "?"));
                            if (tyOfHead(self, h)) |t| break :blk t;
                        }
                    }
                    if (cm.receiver.int() < state.items.len) {
                        if (state.items[cm.receiver.int()] == .known) break :blk state.items[cm.receiver.int()].known;
                    }
                    break :blk null;
                };
                const t = ty orelse {
                    why[0] += 1;
                    if (names_on) std.debug.print("[member-why] no_class .{s} in={s}\n", .{ nm, f.fqn });
                    // What writes the receiver the lattice could not name, so
                    // the tally says which producer the lattice has to learn
                    // rather than which name happened to be called.
                    for (f.blocks) |*b3| {
                        for (b3.insts) |*d| {
                            const dr = defReg(d) orelse continue;
                            if (dr.int() != cm.receiver.int()) continue;
                            const tg = @intFromEnum(std.meta.activeTag(d.*));
                            if (tg < recv_producer.len) recv_producer[tg] += 1;
                            if (d.* == .LoadParam) {
                                const lp = d.LoadParam;
                                if (lp.idx >= f.params.len) {
                                    recv_param_why[0] += 1;
                                } else {
                                    const pp = &f.params[lp.idx];
                                    const ph = m_static.staticTypeHead(std.mem.trimEnd(u8, pp.ty.name, "?"));
                                    if (pp.is_vararg) {
                                        recv_param_why[1] += 1;
                                    } else if (ph.len == 0) {
                                        recv_param_why[2] += 1;
                                    } else if (self.classIdByFqn(ph) == null and
                                        self.uniqueClassIdBySimpleName(ph) == null)
                                    {
                                        recv_param_why[3] += 1;
                                        if (names_on) std.debug.print("[member-param] no-class {s} .{s} in={s}\n", .{ pp.ty.name, nm, f.fqn });
                                    } else if (pp.ty.nullable) {
                                        recv_param_why[4] += 1;
                                    } else {
                                        recv_param_why[5] += 1;
                                        if (names_on) std.debug.print("[member-param] host-or-stub {s}.{s} in={s}\n", .{ pp.ty.name, nm, f.fqn });
                                    }
                                }
                            }
                        }
                    }
                    continue;
                };
                const cid = t.cid orelse {
                    why[1] += 1;
                    if (names_on) std.debug.print("[member-why] host {s}.{s} in={s}\n", .{ t.head, nm, f.fqn });
                    continue;
                };
                if (m_props.hierarchyDeclaresName(self, cid, nm) or
                    m_props.anyAncestorDeclaresName(self, cid, nm) or
                    m_props.hierarchyDeclaresMethod(self, cid, nm))
                {
                    why[2] += 1;
                    // The class declares it, so the question is what the
                    // resolver says when asked with the call's own shape.
                    var shapes: [16]applicability.ArgShape = undefined;
                    var n_shapes: usize = 0;
                    var heads_known = true;
                    if (cm.n_args <= shapes.len) {
                        for (0..cm.n_args) |ai| {
                            const ar = cm.args.int() + @as(u32, @intCast(ai));
                            const acid = if (ar < state.items.len) state.items[ar].classId() else null;
                            if (acid == null) {
                                heads_known = false;
                                break;
                            }
                            shapes[ai] = .{ .ty = .{
                                .name = self.classes.items[acid.?.int()].fqn,
                                .nullable = false,
                                .args = &.{},
                            } };
                        }
                        n_shapes = cm.n_args;
                    } else heads_known = false;
                    if (!heads_known) {
                        decl_why[0] += 1;
                        // A name the hierarchy declares exactly once needs no
                        // argument shapes to pick: there is nothing to pick
                        // BETWEEN. Counting these separates "the resolver
                        // needs types" from "the resolver needs nothing".
                        const decls = countHierarchyDecls(self, cid, nm);
                        if (decls == 1) sole_decl += 1 else if (decls == 0) zero_decl += 1;
                        // The registry keys a declaration by (head, name,
                        // arity). A hit needs no argument shapes at all: the
                        // arity already picked, and overrides of one root
                        // share the slot the call would name.
                        var kb: [256]u8 = undefined;
                        const key = std.fmt.bufPrint(&kb, "{s}\x00{s}\x00{d}", .{ t.head, nm, cm.n_args }) catch "";
                        if (key.len != 0 and self.registry.member_method_fids.get(key) != null) {
                            by_arity += 1;
                        } else {
                            var kb2: [256]u8 = undefined;
                            const simple = if (std.mem.findScalarLast(u8, t.head, '.')) |i| t.head[i + 1 ..] else t.head;
                            const key2 = std.fmt.bufPrint(&kb2, "{s}\x00{s}\x00{d}", .{ simple, nm, cm.n_args }) catch "";
                            if (key2.len != 0 and self.registry.member_method_fids.get(key2) != null) {
                                if (self.registry.member_method_ambiguous.contains(key2)) by_arity_ambig += 1 else by_arity_simple += 1;
                            }
                        }
                        if (names_on) std.debug.print("[member-decl] arg_heads decls={d} {s}.{s} in={s}\n", .{ decls, t.head, nm, f.fqn });
                    } else {
                        const r = self.resolveMemberCall(cid, nm, shapes[0..n_shapes], .{
                            .caller_file = if (self.decl_span.get(f.id.int())) |sp| sp.file else null,
                        });
                        switch (r.dispatch) {
                            .virtual => if (r.target != null) {
                                decl_why[1] += 1;
                            } else {
                                decl_why[2] += 1;
                            },
                            .direct => decl_why[3] += 1,
                            .deferred => {
                                decl_why[4] += 1;
                                if (names_on) std.debug.print("[member-decl] deferred {s}.{s} applicable={} saw={} in={s}\n", .{ t.head, nm, r.applicable, r.saw_candidates, f.fqn });
                            },
                        }
                    }
                    continue;
                }
                if (m_props.extensionCouldServe(self, cid, nm)) {
                    why[3] += 1;
                    if (names_on) std.debug.print("[member-why] extension {s}.{s} in={s}\n", .{ t.head, nm, f.fqn });
                    continue;
                }
                why[4] += 1;
                if (names_on) std.debug.print("[member-why] nothing {s}.{s} in={s}\n", .{ t.head, nm, f.fqn });
            }
        }
    }
    std.debug.print("[member-decl] arg_heads_unknown_sole_decl={d} zero_decl={d} by_arity_fqn={d} by_arity_simple={d} by_arity_ambig={d}\n", .{ sole_decl, zero_decl, by_arity, by_arity_simple, by_arity_ambig });
    std.debug.print("[member-param] bad_idx={d} vararg={d} empty_head={d} no_class={d} nullable={d} host_or_stub={d}\n", .{
        recv_param_why[0], recv_param_why[1], recv_param_why[2],
        recv_param_why[3], recv_param_why[4], recv_param_why[5],
    });
    inline for (@typeInfo(@typeInfo(Inst).@"union".tag_type.?).@"enum".fields) |fl| {
        if (recv_producer[fl.value] != 0)
            std.debug.print("[member-producer] {d: >8}  {s}\n", .{ recv_producer[fl.value], fl.name });
    }
    std.debug.print("[member-why] no_class={d} host_class={d} hierarchy_declares={d} extension={d} nothing_declares={d}\n", .{
        why[0], why[1], why[2], why[3], why[4],
    });
    std.debug.print("[member-decl] arg_heads_unknown={d} virtual_target={d} virtual_none={d} direct={d} deferred={d}\n", .{
        decl_why[0], decl_why[1], decl_why[2], decl_why[3], decl_why[4],
    });
}
