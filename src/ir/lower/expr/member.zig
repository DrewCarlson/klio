//! Member access lowering and the property type probes behind it.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const literals = @import("../literals.zig");
const inline_state = @import("../inline_state.zig");
const ast_scan = @import("../ast_scan.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const ConstId = ir.ConstId;
const Reg = ir.Reg;
const collectDottedFqn = ast_scan.collectDottedFqn;
const isPackageHead = literals.isPackageHead;
const isPkgRoot = literals.isPkgRoot;

const expr_mod = @import("../expr.zig");

const receiver_mod = @import("receiver.zig");
const lowerReceiver = receiver_mod.lowerReceiver;
const resolveSuperThisReg = receiver_mod.resolveSuperThisReg;

const paths_mod = @import("paths.zig");
const classWithCompanion = paths_mod.classWithCompanion;
const scopeTypeRename = paths_mod.scopeTypeRename;

const emit_mod = @import("emit.zig");
const emitFqnWithClassPrefix = emit_mod.emitFqnWithClassPrefix;
const member_call_mod = @import("member_call.zig");
const helpers = @import("../helpers.zig");

const static_type_mod = @import("static_type.zig");
const arg_shape_mod = @import("arg_shape.zig");
const audit_mod = @import("audit.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const typeHead = probe_mod.typeHead;

const block_mod = @import("block.zig");
const implicit_walk = @import("implicit_walk.zig");
const firstSegment = block_mod.firstSegment;
const headIsPackage = block_mod.headIsPackage;

/// `Member` lowering: safe member access, `super.<prop>`, FQN flatten, explicit
/// The declared slot a read of `name` on `receiver`'s static type occupies.
/// The conditions are `fieldSlotClaim`'s; all this adds is resolving the
/// receiver's type to a class.
pub const FieldSlotClaim = struct { cls: ir.ClassId, slot: u32 };

/// The class a receiver expression's static type names, with no claim implied.
fn receiverStaticClass(b: *FuncBuilder, receiver: *const Expr) ?ir.ClassId {
    const declared = arg_shape_mod.argDeclTypeRefLazy(b, receiver);
    var inferred: ?ir.TypeRef = if (declared == null) (staticExprTypeRef(b, receiver) catch null) else null;
    defer if (inferred) |*t| t.deinit(b.allocator);
    const ty = declared orelse inferred orelse {
        // Which receiver SHAPE the deriver cannot type. `recv_type_unknown`
        // is the sole blocker for the largest unresolved class and had no
        // breakdown, so whether it is one shape or a hundred could not be
        // read.
        audit_mod.noteUntypedRecvShape(receiver);
        if (receiver.* == .Path and receiver.Path.segments.len == 1) {
            const rn = receiver.Path.segments[0].name;
            if (b.isParam(rn) and runtime.envOnce("KLIO_UNTYPED_PARAM") != null) {
                std.debug.print("[untyped-param] {s} declty={s} in={s}\n", .{
                    rn,
                    if (b.localDeclType(rn)) |t| t else "<none>",
                    b.ownerClass() orelse "-",
                });
            }
            audit_mod.noteUntypedRecvPath(if (b.isParam(rn))
                .lambda_param
            else if (b.resolve(rn) != null)
                (if (b.localInitExpr(rn)) |ini| blk: {
                    audit_mod.noteUntypedInitShape(ini);
                    // For a call initializer, the question a fix would have
                    // to answer: would a return-type channel reach it?
                    if (ini.* == .Call)
                        audit_mod.lm_untyped_init_call.bump(@intFromEnum(audit_mod.classifyCallReturn(b, ini)));
                    break :blk .local_init_untypeable;
                } else .local_no_init)
            else if (b.knowsOuter(rn))
                .captured
            else
                .other);
        }
        audit_mod.noSlotNote(.recv_type_unknown);
        return null;
    };
    const cid = static_type_mod.staticTypeClassId(b, ty) orelse {
        // Tell "no class has this name" from "several do": the second is a
        // head that lost its package on the way here, and is fixable.
        var head = std.mem.trimEnd(u8, ty.name, "?");
        if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
        audit_mod.noSlotNote(if (std.mem.findScalar(u8, head, '.') == null and
            b.module.simpleNameIsAmbiguous(probe_mod.typeHead(head)))
            .recv_ambiguous_simple
        else
            .recv_not_a_class);
        return null;
    };
    return cid;
}

/// As `receiverFieldSlot`, for a WRITE: the slot must also have no custom
/// setter, which `plain` does not cover. `plain` is about reads, and a property
/// can read straight from its slot while its setter runs code — `counter` in
/// `examples/delegates.kt` stored the raw value past a setter that transformed
/// it until the audit said so.
pub fn receiverWriteSlot(b: *FuncBuilder, receiver: *const Expr, name: []const u8) ?FieldSlotClaim {
    const c = receiverFieldSlot(b, receiver, name) orelse return null;
    const layout = b.module.classFieldLayout(c.cls) orelse return null;
    if (c.slot >= layout.slots.len) return null;
    if (!layout.slots[c.slot].plain_write) return null;
    return c;
}

pub fn receiverFieldSlot(b: *FuncBuilder, receiver: *const Expr, name: []const u8) ?FieldSlotClaim {
    const declared = arg_shape_mod.argDeclTypeRefLazy(b, receiver);
    var inferred: ?ir.TypeRef = if (declared == null) (staticExprTypeRef(b, receiver) catch null) else null;
    defer if (inferred) |*t| t.deinit(b.allocator);
    const ty = declared orelse inferred orelse return null;
    const cid = static_type_mod.staticTypeClassId(b, ty) orelse return null;
    const idx = static_type_mod.fieldSlotClaim(b, cid, name) orelse return null;
    return .{ .cls = cid, .slot = idx };
}

/// `coroutineContext`, and the plain GetField.
pub fn lowerMember(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const m = expr.Member;
    const receiver = m.receiver;
    const name = m.name;

    if (m.safe) {
        // `recv?.x` null-guard. An explicit `recv?.coroutineContext` is a literal
        // member read, or the suspend-implicit redirect serves the ambient context.
        const recv = try lowerReceiver(b, receiver);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = recv, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        const n = try b.emitConst(.Null);
        try b.push(.{ .Move = .{ .dst = dst, .src = n } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        const field_name: []const u8 = if (std.mem.eql(u8, name.name, "coroutineContext"))
            "$coroutineContext$explicit"
        else
            name.name;
        const field = try b.module.internConst(b.allocator, .{ .String = field_name });
        const v = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = v, .receiver = recv, .field = field } });
        try b.push(.{ .Move = .{ .dst = dst, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // `super.<prop>`: the supertype's accessor, or its cell.
    if (receiver.* == .Super) {
        const sup = receiver.Super;
        if (try superBase(b, sup)) |base| {
            const qual: ?[]const u8 = if (sup.qualifier) |qt| qt.name.name else null;
            // What `super.<prop>` names is fixed by the language the same
            // way `super.f()` is: the nearest declaring class's accessor,
            // a direct call, or the cell it stores the property in.
            if (emit_mod.superPropertyAnswer(b, base.owner, qual, name.name, .read)) |ans| {
                const recv_slot = b.allocReg();
                try b.push(.{ .Move = .{ .dst = recv_slot, .src = base.this_reg } });
                const sdst = b.allocReg();
                switch (ans) {
                    .accessor => |fid| try b.push(.{ .Call = .{
                        .dst = sdst,
                        .func = fid,
                        .trailing_lambda = false,
                        .args = recv_slot,
                        .n_args = 1,
                        .arg_names = &.{},
                        .type_args = &.{},
                        .exact = true,
                    } }),
                    .cell => |c| try b.push(.{ .GetField = .{
                        .dst = sdst,
                        .receiver = recv_slot,
                        .field = try b.module.internConst(b.allocator, .{ .String = name.name }),
                        .own_cls = c.cid,
                        .own_slot = c.idx,
                        .own_kind = .super_slot,
                    } }),
                }
                return sdst;
            }
            // The accessor is created when the DECLARING class's body lowers
            // and bodies lower from a pool, and a stored base property has
            // no accessor at all: the link pass settles which, once every
            // body has lowered. The receiver is copied so the settled form,
            // a direct call, owns its argument register.
            const start = emit_mod.superStartClass(b, base.owner, qual) orelse {
                if (runtime.envOnce("KLIO_SUPER_WHY") != null)
                    std.debug.print("[super-why] prop {s}.{s} qualified={} no class in={s}\n", .{ base.owner, name.name, qual != null, build.currentRealFn() orelse "-" });
                return try member_call_mod.emitUnboundSuper(b, base.owner, name.name);
            };
            const recv_slot = b.allocReg();
            try b.push(.{ .Move = .{ .dst = recv_slot, .src = base.this_reg } });
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
            try b.push(.{ .GetField = .{
                .dst = dst,
                .receiver = recv_slot,
                .field = nm,
                .own_cls = start,
                .own_kind = .super_target,
                .own_slot = if (qual != null) 1 else 0,
            } });
            return dst;
        }
    }

    // Flatten chains like `kotlin.math.PI` into a single FQN lookup.
    if (try collectDottedFqn(b.allocator, expr)) |fqn| {
        defer b.allocator.free(fqn);
        const head = firstSegment(fqn);
        // A real package root flattens to an FQN LoadGlobal even inside a class
        // method. A head some declaration's package spells is as real unless a
        // receiver in scope is proven to declare it as a member; only a head
        // that is neither defers to a member when `this` is in scope.
        const head_is_real_pkg = isPkgRoot(head) or blk: {
            if (!b.module.packageHeadDeclared(head)) break :blk false;
            if (b.resolve("this") == null) break :blk true;
            break :blk (try implicit_walk.walk(b, head, null, .property, "member_chain_head")) != .member;
        };
        if (isPackageHead(head) and
            headIsPackage(b, head) and
            b.resolve(head) == null and
            !b.knowsOuter(head) and
            !b.hasEnclosingMember(head) and
            b.module.classId(head) == null and
            (head_is_real_pkg or b.resolve("this") == null))
        {
            if (try emitFqnWithClassPrefix(b, fqn)) |r| return r;
            const dst = b.allocReg();
            const n = try b.module.internConst(b.allocator, .{ .String = fqn });
            try b.push(.{ .LoadGlobal = .{ .dst = dst, .name = n } });
            // A fully-qualified class-with-companion in value position yields its
            // companion singleton, matching the bare-name arm, so `pkg.C === C` holds.
            // The sentinel returns the class or object value when none exists.
            const fqn_simple = if (std.mem.findScalarLast(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
            // A same-FQN factory function keeps the class value: as a call callee it
            // is the factory, and a bare reference reaches its companion through
            // explicit `.Key`.
            if (classWithCompanion(b, fqn_simple) and b.module.funcIdByFqn(fqn) == null) {
                const comp = b.allocReg();
                const sentinel = try b.module.internConst(b.allocator, .{ .String = "<class-companion-or-self>" });
                try b.push(.{ .GetField = .{ .dst = comp, .receiver = dst, .field = sentinel } });
                return comp;
            }
            return dst;
        }
    }

    // An explicit `recv.coroutineContext` is a literal field read.
    if (std.mem.eql(u8, name.name, "coroutineContext")) {
        const recv = try lowerReceiver(b, receiver);
        const dst = b.allocReg();
        const field = try b.module.internConst(b.allocator, .{ .String = "$coroutineContext$explicit" });
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
        return dst;
    }

    // `c.code` on a static Char receiver is the scalar identity read, emitted as
    // `c - NUL` since Char minus Char is Int, which stays in fused loop regions.
    if (std.mem.eql(u8, name.name, "code")) {
        const recv_head: ?[]const u8 = blk: {
            const t = staticExprTypeRef(b, receiver) catch null;
            var tr = t orelse break :blk null;
            defer tr.deinit(b.allocator);
            if (tr.nullable) break :blk null;
            break :blk if (std.mem.eql(u8, typeHead(tr.name), "Char")) "Char" else null;
        };
        if (recv_head != null) {
            const recv = try lowerReceiver(b, receiver);
            const zero = try b.emitConst(.{ .Char = 0 });
            const dst = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = dst, .op = .Sub, .lhs = recv, .rhs = zero } });
            return dst;
        }
    }

    // When the receiver's static type resolves `name` to an in-scope
    // member-extension property rather than a member, Kotlin runs the extension
    // getter: a call to one known function on the declaring instance.
    if (try memberExtPropGetterRead(b, receiver, name.name)) |dst| return dst;
    if (try staticExtPropReadField(b, receiver, name.name)) |marker| {
        const recv = try lowerReceiver(b, receiver);
        const dst = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = marker } });
        return dst;
    }

    // Explicit `this.x` where the enclosing class declares `x` as a private shadow
    // of a supertype's stored property reads its own owner-mangled cell.
    if (receiver.* == .This and receiver.This.qualifier == null) {
        if (b.ownerClass()) |owner| {
            var kb: [256]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ owner, name.name })) |probe| {
                if (b.module.registry.private_shadow_props.getKey(probe)) |key| {
                    const trecv = try lowerReceiver(b, receiver);
                    const tdst = b.allocReg();
                    const tfield = try b.module.internConst(b.allocator, .{ .String = key });
                    try b.push(.{ .GetField = .{ .dst = tdst, .receiver = trecv, .field = tfield } });
                    return tdst;
                }
            } else |_| {}
        }
    }

    const recv = try lowerReceiver(b, receiver);
    const dst = b.allocReg();
    const field = try b.module.internConst(b.allocator, .{ .String = name.name });
    // `recv.x` where the receiver's static type names a class whose layout
    // fixes `x`'s slot. The runtime still proves the receiver IS that class
    // before it serves the index, so a subtype receiver falls back rather
    // than reading the wrong cell.
    const claim = receiverFieldSlot(b, receiver, name.name);
    // `EnumClass.Entry`: the receiver names an enum and the member names one of
    // its entries, both settled here. The runtime compared the name against
    // every entry on every read.
    const entry = enumEntryClaim(b, receiver, name.name);
    try b.push(.{ .GetField = .{
        .dst = dst,
        .receiver = recv,
        .field = field,
        // The receiver's static class is recorded whatever came of it: a read
        // whose answer is a getter cannot be settled while the class body is
        // still lowering, and `linkGetterRoutes` fills it once every body has.
        .own_cls = if (entry) |e| e.cls else if (claim) |c| c.cls else receiverStaticClass(b, receiver),
        .own_slot = if (entry) |e| e.slot else if (claim) |c| c.slot else 0,
        .own_kind = if (entry != null) .enum_entry else if (claim != null) .slot else .none,
    } });
    return dst;
}

/// The enum and entry index a `EnumClass.Entry` read names. The receiver has to
/// be a bare class name: an enum value in a local reads its own members, not
/// the entry table.
fn enumEntryClaim(b: *FuncBuilder, receiver: *const Expr, name: []const u8) ?FieldSlotClaim {
    if (receiver.* != .Path or receiver.Path.segments.len != 1) return null;
    const head = receiver.Path.segments[0].name;
    // A local, parameter or captured name of the same spelling is the value,
    // not the classifier.
    if (b.resolve(head) != null or b.knowsOuter(head)) return null;
    const file = receiver.Path.segments[0].span.file;
    const cid = b.module.classIdIndexed(head, b.self_package, file) orelse
        b.module.classId(head) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const c = &b.module.classes.items[cid.int()];
    if (!c.is_enum) return null;
    const idx = c.enumEntryIndex(name) orelse return null;
    return .{ .cls = cid, .slot = idx };
}

/// The statically known type head of a bare single-name receiver: a typed local or
/// param, else an enclosing-class member walked over the supertype chain.
/// `staticBareReceiverTypeRef` is the argument-carrying half, recorded only for a
/// property whose declared type has arguments naming real classes.
pub fn propTypeRefOn(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?ir.TypeRef {
    if (b.module.registry.class_prop_type_refs.get(.{ .a = owner, .b = name })) |t| return t;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    for (chain) |cls| {
        if (b.module.registry.class_prop_type_refs.get(.{ .a = cls, .b = name })) |t| return t;
    }
    return null;
}

/// A declared property type with the owner's type parameters replaced by the
/// receiver's type arguments. Null when any argument stays a parameter.
pub fn substitutedPropType(
    b: *FuncBuilder,
    owner: []const u8,
    recv_ty: ir.TypeRef,
    declared: ir.TypeRef,
) ?ir.TypeRef {
    if (declared.args.len == 0) return declared;
    if (recv_ty.args.len == 0) return null;
    const cid = b.module.uniqueClassIdBySimpleName(owner) orelse
        b.module.classIdByFqn(owner) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    const tps = b.module.classes.items[cid.int()].type_params;
    if (tps.len == 0 or tps.len != recv_ty.args.len) return null;
    var buf: [4]ir.TypeRef = undefined;
    if (declared.args.len > buf.len) return null;
    for (declared.args, 0..) |darg, i| {
        const dh = typeHead(std.mem.trimEnd(u8, darg.name, "?"));
        var found = false;
        for (tps, 0..) |tp, j| {
            if (!std.mem.eql(u8, tp, dh)) continue;
            const sub = recv_ty.args[j];
            if (sub.name.len == 0 or std.mem.eql(u8, sub.name, "*")) return null;
            if (bareTypeParamHead(sub.name)) return null;
            buf[i] = sub;
            found = true;
            break;
        }
        if (!found) {
            if (bareTypeParamHead(darg.name)) return null;
            buf[i] = darg;
        }
    }
    const owned = b.allocator.dupe(ir.TypeRef, buf[0..declared.args.len]) catch return null;
    return ir.TypeRef{ .name = declared.name, .nullable = declared.nullable, .args = owned };
}

/// A bare type-parameter head is not a property owner; its declared bound is, so
/// the owner lookups chase `M -> Map`.
fn boundOwnerHead(b: *const FuncBuilder, head: []const u8) []const u8 {
    if (b.typeParamBoundRef(head)) |bref| {
        var h = std.mem.trimEnd(u8, bref.name, "?");
        if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
        if (h.len != 0) return typeHead(h);
    }
    return head;
}

pub fn staticBareReceiverTypeRef(b: *const FuncBuilder, recv_name: []const u8) ?ir.TypeRef {
    const self_shadowed = expr_mod.init_self_name != null and std.mem.eql(u8, expr_mod.init_self_name.?, recv_name);
    if (!self_shadowed) {
        if (b.resolve(recv_name) != null) return null;
        if (b.knowsOuter(recv_name)) return null;
    }
    const owner = b.ownerClass() orelse blk: {
        const head = b.recvTy() orelse b.spliceRecvTy() orelse return null;
        break :blk boundOwnerHead(b, typeHead(std.mem.trimEnd(u8, head, "?")));
    };
    if (b.module.registry.class_prop_type_refs.get(.{ .a = owner, .b = recv_name })) |t| return t;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    for (chain) |cls| {
        if (b.module.registry.class_prop_type_refs.get(.{ .a = cls, .b = recv_name })) |t| return t;
    }
    return null;
}

pub fn staticBareReceiverType(b: *const FuncBuilder, recv_name: []const u8) ?[]const u8 {
    // Inside `val writer = writer`'s initializer the local's own name is free, so
    // the reference is the enclosing member, never the shadow being declared.
    const self_shadowed = expr_mod.init_self_name != null and std.mem.eql(u8, expr_mod.init_self_name.?, recv_name);
    // A local/param binding shadows an enclosing member of the same name.
    if (!self_shadowed) {
        if (b.resolve(recv_name) != null) return b.localDeclType(recv_name);
        if (b.knowsOuter(recv_name)) return null;
    }
    // The enclosing class, else the extension receiver: a bare name inside
    // `fun UByteArray.indices()` is a member of the receiver.
    const tr = if (runtime.envOnce("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, recv_name) else false;
    const owner = b.ownerClass() orelse blk: {
        if (std.mem.eql(u8, runtime.envOnce("KLIO_EXT_RECV_PROP") orelse "1", "0")) return null;
    // The splice-receiver hint serves the same role inside an inline extension
    // splice, where the body's builder has no `recvTy` of its own.
        const head = b.recvTy() orelse b.spliceRecvTy() orelse {
            if (tr) std.debug.print("[sbrt] {s}: no owner, no recvTy\n", .{recv_name});
            return null;
        };
        break :blk boundOwnerHead(b, typeHead(std.mem.trimEnd(u8, head, "?")));
    };
    if (tr) std.debug.print("[sbrt] {s}: owner={s} head={?s} ext={?s}\n", .{ recv_name, owner, propTypeHeadOn(b, owner, recv_name), extPropReturnHead(b, owner, recv_name) });
    if (propTypeHeadOn(b, owner, recv_name)) |h| return h;
    if (extPropReturnHead(b, owner, recv_name)) |h| return h;
    // A receiver lambda rebinds `this`, so a bare name inside it can be the
    // receiver's member. Consulted only after the enclosing class declines.
    const recv_head = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse return null;
    const rh = boundOwnerHead(b, typeHead(std.mem.trimEnd(u8, recv_head, "?")));
    if (rh.len == 0 or std.mem.eql(u8, rh, owner)) return null;
    if (propTypeHeadOn(b, rh, recv_name)) |h| return h;
    return extPropReturnHead(b, rh, recv_name);
}

/// The declared return head of an extension property named `name` on `head` or its
/// supertypes: the lowered getter follows the `__ext_get_<Head>_<name>` contract,
/// and its return type is the bare read's static type.
pub fn extPropReturnHead(b: *const FuncBuilder, head: []const u8, name: []const u8) ?[]const u8 {
    if (extPropDeclHead(b, head, name)) |h| return h;
    if (extPropGetterReturn(b, head, name)) |h| return h;
    for (applicability.builtinSupersOf(head)) |sup| {
        if (extPropDeclHead(b, sup, name)) |h| return h;
        if (extPropGetterReturn(b, sup, name)) |h| return h;
    }
    if (b.module.registry.class_super_names.get(head)) |chain| {
        for (chain) |sup| {
            if (extPropDeclHead(b, applicability.simpleName(sup), name)) |h| return h;
            if (extPropGetterReturn(b, applicability.simpleName(sup), name)) |h| return h;
        }
    }
    return null;
}

/// The declaration-scan channel: `(receiver head, name)` recorded before any body
/// lowers, so the answer exists while the declaring library is itself lowering.
fn extPropDeclHead(b: *const FuncBuilder, head: []const u8, name: []const u8) ?[]const u8 {
    const raw = b.module.registry.ext_prop_type_heads.get(.{ .a = head, .b = name }) orelse return null;
    var h = std.mem.trimEnd(u8, raw, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (h.len == 0 or std.mem.eql(u8, h, "Unit")) return null;
    const cid = (if (std.mem.findScalar(u8, h, '.') != null)
        b.module.classIdByFqn(h)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(h)));
    if (cid == null) return null;
    return h;
}

fn extPropGetterReturn(b: *const FuncBuilder, head: []const u8, name: []const u8) ?[]const u8 {
    const tr = if (runtime.envOnce("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, name) else false;
    var buf: [160]u8 = undefined;
    const gname = std.fmt.bufPrint(&buf, "__ext_get_{s}_{s}", .{ head, name }) catch return null;
    const fids = b.module.funcsBySimpleName(gname);
    if (tr) std.debug.print("[extpget] gname={s} fids={d}\n", .{ gname, fids.len });
    if (fids.len == 0) return null;
    const f = b.module.funcById(fids[0]) orelse return null;
    var h = std.mem.trimEnd(u8, f.return_ty.name, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (tr) std.debug.print("[extpget] ret head={s}\n", .{h});
    if (h.len == 0 or std.mem.eql(u8, h, "Unit")) return null;
    const cid = (if (std.mem.findScalar(u8, h, '.') != null)
        b.module.classIdByFqn(h)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(h)));
    if (tr) std.debug.print("[extpget] cid={?}\n", .{cid});
    if (cid == null) return null;
    return h;
}

/// The property-head key for `owner` as the site's file sees it: the
/// scope-resolved class's qualified name, exact when two packages share the
/// simple name. Null when the simple key already is the class. An unqualified
/// nested-class name resolves lexically first, so the walk tries
/// `<outer>.<simple>` outwards along the enclosing class's qualified name.
fn lexicalNestedClassFqn(b: *const FuncBuilder, simple: []const u8, file: ir.FileId) ?[]const u8 {
    const oc = b.ownerClass() orelse return null;
    const cid = b.module.classIdIndexed(oc, b.self_package, file) orelse b.module.classId(oc) orelse return null;
    var fqn = b.module.classFqnById(cid) orelse return null;
    var buf: [512]u8 = undefined;
    while (fqn.len > b.self_package.len) {
        const cand = std.fmt.bufPrint(&buf, "{s}.{s}", .{ fqn, simple }) catch return null;
        if (b.module.classIdByFqn(cand)) |nid| return b.module.classFqnById(nid);
        const dot = std.mem.findScalarLast(u8, fqn, '.') orelse return null;
        fqn = fqn[0..dot];
    }
    return null;
}

fn scopedPropOwnerKey(b: *const FuncBuilder, owner: []const u8, site_file: ?ir.FileId) ?[]const u8 {
    if (std.mem.findScalar(u8, owner, '.') != null) return null;
    const file = site_file orelse (b.self_decl_span orelse return null).file;
    if (lexicalNestedClassFqn(b, owner, file)) |nf| {
        if (runtime.envOnce("KLIO_CIX_TRACE")) |w| {
            if (std.mem.eql(u8, w, owner)) std.debug.print("[cix-prop] {s} file={d} -> {s} (lexical nested)\n", .{ owner, file.int(), nf });
        }
        return nf;
    }
    const cid = b.module.classIdIndexed(owner, b.self_package, file) orelse return null;
    const fqn = b.module.classFqnById(cid) orelse return null;
    if (runtime.envOnce("KLIO_CIX_TRACE")) |w| {
        if (std.mem.eql(u8, w, owner)) std.debug.print("[cix-prop] {s} file={d} -> {s}\n", .{ owner, file.int(), fqn });
    }
    if (std.mem.eql(u8, fqn, owner)) return null;
    return fqn;
}

/// A declared receiver type's own property-head key: the written qualified name
/// when the declaration spelled one, else the head as the site's file resolves it.
pub fn declTypePropOwnerKey(b: *const FuncBuilder, ty: *const ir.TypeRef, site_file: ?ir.FileId) ?[]const u8 {
    for (ty.args) |*a| {
        if (std.mem.startsWith(u8, a.name, "#qual:")) return a.name["#qual:".len..];
    }
    var t = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.findScalar(u8, t, '.') != null) return t;
    return scopedPropOwnerKey(b, t, site_file);
}

pub fn propTypeHeadOn(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?[]const u8 {
    const heads = b.module.registry.class_prop_type_heads;
    if (scopedPropOwnerKey(b, owner, null)) |key| {
        if (heads.get(.{ .a = key, .b = name })) |h| return h;
    }
    if (heads.get(.{ .a = owner, .b = name })) |h| return h;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    for (chain) |cls| {
        if (heads.get(.{ .a = cls, .b = name })) |h| return h;
    }
    // A property typed only by its initializer call: the class registration could
    // not see a pack's factory or class, so the head is read from the initializer
    // here, where every declaration is registered.
    if (propInitCallHead(b, owner, name)) |h| return h;
    for (chain) |cls| {
        if (propInitCallHead(b, cls, name)) |h| return h;
    }
    // A runtime anon-object member body's own property heads travel in the
    // installed snapshot; the synthesized class has no registry entries.
    return build.anonPropHead(owner, name);
}

/// The class a member property's initializer call names: a constructor, or a
/// plain function whose same-named overloads agree on a declared, concrete
/// return head.
pub fn propInitCallHead(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?[]const u8 {
    const p = inline_state.memberPropAst(owner, name) orelse {
        if (runtime.envOnce("KLIO_PROPHEAD_TRACE") != null) std.debug.print("[prophead-lazy] no ast for {s}.{s}\n", .{ owner, name });
        return null;
    };
    if (runtime.envOnce("KLIO_PROPHEAD_TRACE") != null) std.debug.print("[prophead-lazy] {s}.{s} ty={} init={}\n", .{ owner, name, p.ty != null, p.init != null });
    if (p.ty != null) return null;
    const init = p.init orelse return null;
    if (init.* != .Call) return null;
    const callee = init.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const nm = callee.Path.segments[0].name;
    if (nm.len == 0) return null;
    if (std.ascii.isUpper(nm[0]) and b.module.classId(nm) != null) return nm;
    var agreed: ?[]const u8 = null;
    for (b.module.funcsBySimpleName(nm)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        var head = std.mem.trimEnd(u8, f.return_ty.name, "?");
        if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len == 0 or std.mem.eql(u8, head, "Unit") or (head.len <= 2 and std.ascii.isUpper(head[0]))) return null;
        if (agreed) |g| {
            if (!std.mem.eql(u8, g, head)) return null;
        } else agreed = head;
    }
    return agreed;
}

/// Whether `ty` or a supertype declares a member property named `name`. Keyed on
/// `class_prop_type_heads`, which records member and constructor-parameter
/// properties by declaring class.
pub fn staticTypeDeclaresProp(b: *const FuncBuilder, ty: []const u8, name: []const u8) bool {
    const heads = b.module.registry.class_prop_type_heads;
    if (heads.get(.{ .a = ty, .b = name }) != null) return true;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(ty) orelse return false;
    for (chain) |cls| {
        if (heads.get(.{ .a = cls, .b = name }) != null) return true;
    }
    return false;
}

/// The static type head of a member read's receiver: a bare name through the
/// shadow-aware local and member walk, any other expression through its declared
/// or derived type. A nullable receiver reads nothing here.
fn staticReceiverHead(b: *FuncBuilder, receiver: *const Expr) Allocator.Error!?[]const u8 {
    switch (receiver.*) {
        .Path => |p| if (p.segments.len == 1) return staticBareReceiverType(b, p.segments[0].name),
        else => {},
    }
    if (arg_shape_mod.argDeclTypeRefLazy(b, receiver)) |t| {
        if (t.nullable or std.mem.endsWith(u8, t.name, "?")) return null;
        const h = typeHead(t.name);
        return if (h.len == 0) null else h;
    }
    var owned = (staticExprTypeRef(b, receiver) catch null) orelse return null;
    defer owned.deinit(b.allocator);
    if (owned.nullable or std.mem.endsWith(u8, owned.name, "?")) return null;
    const h = typeHead(owned.name);
    return if (h.len == 0) null else try b.allocator.dupe(u8, h);
}

/// The getter of the member-extension property `name` on `ext_recv` that
/// `owner` declares, under the `__ext_get_<Head>_<name>` contract and filtered
/// to the declaring class, since two classes may extend one head with one name.
fn memberExtGetterOn(b: *const FuncBuilder, owner: ir.ClassId, ext_recv: []const u8, name: []const u8) ?ir.FuncId {
    if (owner.int() >= b.module.classes.items.len) return null;
    const c = &b.module.classes.items[owner.int()];
    var buf: [256]u8 = undefined;
    const gname = std.fmt.bufPrint(&buf, "__ext_get_{s}_{s}", .{ typeHead(ext_recv), name }) catch return null;
    var found: ?ir.FuncId = null;
    for (b.module.funcsBySimpleName(gname)) |fid| {
        const of = b.module.registry.member_ext_owner_class.get(fid) orelse continue;
        if (!(std.mem.eql(u8, of, c.fqn) or std.mem.eql(u8, of, c.name))) continue;
        if (found) |prev| {
            if (prev == fid) continue;
            return null;
        }
        found = fid;
    }
    const fid = found orelse return null;
    const f = b.module.funcById(fid) orelse return null;
    if (!f.hasBody() and !b.module.decl_ast_body.contains(fid.int())) return null;
    return fid;
}

/// A qualified read the enclosing class resolves to its own member-extension
/// property: the receiver's static type satisfies the extension receiver and
/// declares no member of that name, so Kotlin runs the extension getter with
/// the enclosing instance as the dispatch receiver. Both are fixed here, so the
/// read is a call to the getter's FuncId; a body that a splice moved into
/// another class's method keeps its declaring instance the same way.
fn memberExtPropGetterRead(b: *FuncBuilder, receiver: *const Expr, name: []const u8) Allocator.Error!?Reg {
    const owner = b.ownerClass() orelse return null;
    const ext_recv = inline_state.memberExtPropRecv(owner, name) orelse return null;
    const static_ty = (try staticReceiverHead(b, receiver)) orelse return null;
    if (!b.module.classIsOrExtends(static_ty, ext_recv)) return null;
    if (staticTypeDeclaresProp(b, static_ty, name)) return null;
    const file = (b.self_decl_span orelse return null).file;
    const owner_cid = emit_mod.ownerClassIdOf(b, file) orelse return null;
    const fid = memberExtGetterOn(b, owner_cid, ext_recv, name) orelse return null;
    const dispatch = (try member_call_mod.lowerMemberExtensionDispatchReceiver(b, owner_cid)) orelse return null;
    const recv = try lowerReceiver(b, receiver);
    const run = try helpers.lowerArgRun(b, &.{});
    const dst = b.allocReg();
    const method_name = try b.module.internConst(b.allocator, .{ .String = name });
    const declared_recv = try b.module.internConst(b.allocator, .{ .String = ext_recv });
    const ctx_handed = try probe_mod.contextHandoverBegin(b, fid, &.{});
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = method_name,
        .args = run[0],
        .n_args = run[1],
        .extra = try b.memberExtra(.{ .declared_recv = declared_recv, .resolved = fid, .dispatch_receiver = dispatch }),
    } });
    try probe_mod.contextHandoverEnd(b, ctx_handed);
    return dst;
}

/// The interned `$extread$<name>` marker when a qualified read resolves, by the
/// static type of the receiver, to an in-scope member-extension property whose
/// getter must win over a same-named stored field. Null when the ordinary field
/// read applies.
fn staticExtPropReadField(b: *FuncBuilder, receiver: *const Expr, name: []const u8) Allocator.Error!?ConstId {
    const recv_name = switch (receiver.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
        else => return null,
    };
    const static_ty = staticBareReceiverType(b, recv_name) orelse return null;
    const owner = b.ownerClass() orelse return null;
    // An in-scope member-extension property whose extension-receiver type the
    // static type satisfies.
    const ext_recv = inline_state.memberExtPropRecv(owner, name) orelse return null;
    if (!b.module.classIsOrExtends(static_ty, ext_recv)) return null;
    // A member of the static type outranks the extension in Kotlin, so the
    // ordinary field read is then correct.
    if (staticTypeDeclaresProp(b, static_ty, name)) return null;
    const marker = try std.fmt.allocPrint(b.allocator, "$extread${s}", .{name});
    return try b.module.internConst(b.allocator, .{ .String = marker });
}

/// The `<Q>` of `super<Q>`: the supertype the call dispatches on. A `super@Label`
/// names the class whose supertypes are walked and is carried by the owner and
/// receiver pair, never by the qualifier.
const SuperBase = struct { this_reg: Reg, owner: []const u8 };

/// The instance and class a `super` expression starts from. Unlabeled `super`
/// starts at the enclosing class on `this`; `super@Outer` in an inner class starts
/// at `Outer` on `this@Outer`, so `super<K>@A.foo()` runs K's implementation
/// against the A instance.
pub fn superBase(b: *FuncBuilder, sup: anytype) Allocator.Error!?SuperBase {
    const this_reg = (try resolveSuperThisReg(b)) orelse return null;
    const owner = b.ownerClass() orelse return null;
    const label = sup.label orelse return .{ .this_reg = this_reg, .owner = owner };
    const target = scopeTypeRename(b, label.name, label.span.file.int()) orelse label.name;
    if (std.mem.eql(u8, target, owner)) return .{ .this_reg = this_reg, .owner = owner };
    if (try implicit_walk.instanceOfClassReg(b, target)) |r| return .{ .this_reg = r, .owner = target };
    expr_mod.orEmitAudit(b, "super_labeled", "QualifiedThis", target);
    const nm = try b.module.internConst(b.allocator, .{ .String = target });
    const dst = b.allocReg();
    try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
    return .{ .this_reg = dst, .owner = target };
}
