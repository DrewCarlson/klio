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

const static_type_mod = @import("static_type.zig");
const staticExprTypeRef = static_type_mod.staticExprTypeRef;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const typeHead = probe_mod.typeHead;

const block_mod = @import("block.zig");
const firstSegment = block_mod.firstSegment;
const headIsPackage = block_mod.headIsPackage;

/// `Member` lowering: safe member access (`recv?.x`), `super.<prop>`, FQN
/// flatten, explicit `coroutineContext`, and the plain GetField.
pub fn lowerMember(b: *FuncBuilder, expr: *const Expr) Allocator.Error!Reg {
    const m = expr.Member;
    const receiver = m.receiver;
    const name = m.name;

    if (m.safe) {
        // `recv?.x` — null-guard. An explicit `recv?.coroutineContext` is a
        // literal member read exactly like the non-safe arm below: without the
        // sentinel the runtime's suspend-implicit redirect served the AMBIENT
        // coroutine's context instead of the receiver's own.
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

    // `super.<prop>` — dispatch its getter via the parent chain.
    if (receiver.* == .Super) {
        const sup = receiver.Super;
        if (try superBase(b, sup)) |base| {
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = name.name });
            const oc = try b.module.internConst(b.allocator, .{ .String = base.owner });
            const qual_const = try superQualifier(b, sup.qualifier);
            const args_start = b.allocReg();
            try b.push(.{ .CallSuper = .{
                .dst = dst,
                .receiver = base.this_reg,
                .owner_class = oc,
                .qualifier = qual_const,
                .name = nm,
                .args = args_start,
                .n_args = 0,
                .arg_names = &.{},
            } });
            return dst;
        }
    }

    // Flatten chains like `kotlin.math.PI` into a single FQN lookup.
    if (try collectDottedFqn(b.allocator, expr)) |fqn| {
        defer b.allocator.free(fqn);
        const head = firstSegment(fqn);
        // A real package root (`kotlin.math.PI`) flattens to an FQN LoadGlobal
        // even inside a class method; only an ambiguous head defers to a member
        // when `this` is in scope. Mirrors the call path (lowerFqnGlobalCall).
        const head_is_real_pkg = isPkgRoot(head);
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
            // companion singleton (Kotlin: `C` yields `C.Companion`), matching the
            // bare-name arm. Without it `pkg.C` loaded the class value while bare
            // `C` loaded the companion, so `pkg.C === C` was false and
            // `context[ContinuationInterceptor]` (an interface with a named
            // companion Key) missed the dispatcher element. The
            // `<class-companion-or-self>` sentinel returns the companion when one
            // exists and the class/object value otherwise, leaving a plain object
            // or a companion-less class unchanged.
            const fqn_simple = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |d| fqn[d + 1 ..] else fqn;
            // A same-FQN factory function (`kotlinx.coroutines.Job` is both an
            // interface with a companion `Key` AND a `fun Job()` factory) keeps
            // the class value: as a call callee it is the factory, and a bare
            // reference reaches its companion through explicit `.Key`. Only a
            // companioned classifier with no such function forwards.
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

    // `c.code` on a STATIC Char receiver is the scalar identity read â
    // emit it as `c - NUL` (Char minus Char is Int in Kotlin, and the
    // subtrahend is code zero), a plain BinOp instead of a dynamic field
    // read: it stays in fused loop regions and skips the runtime
    // extension-getter dispatch per read.
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

    // Static-type-directed extension-property read. When the receiver's
    // STATIC type resolves `name` to an in-scope member-extension property
    // rather than a member of that type, Kotlin runs the extension getter —
    // a same-named stored field the runtime object happens to carry is
    // irrelevant. Emit an extension-read marker so dispatch resolves the
    // extension property instead of that accidental field.
    if (try staticExtPropReadField(b, receiver, name.name)) |marker| {
        const recv = try lowerReceiver(b, receiver);
        const dst = b.allocReg();
        try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = marker } });
        return dst;
    }

    // Explicit `this.x` where the enclosing class declares `x` as a private
    // SHADOW of a supertype's same-name stored property reads ITS OWN
    // owner-mangled cell, matching the bare-name read and the shadow write.
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
    try b.push(.{ .GetField = .{ .dst = dst, .receiver = recv, .field = field } });
    return dst;
}

/// The statically known type-head of a bare single-name receiver: a typed
/// local/param, else an enclosing-class member (property / constructor-
/// parameter property) walked over the owner's supertype chain. Null when the
/// name has no statically known type here (an untyped local, an outer
/// capture, or a name the enclosing class does not declare as a typed member).
/// The full declared TYPE of a bare name that reads a property of the
/// enclosing class or the extension receiver — the argument-carrying half of
/// `staticBareReceiverType`. Only recorded for a property whose declared
/// type has arguments that name real classes, so a `null` here simply means
/// the head-only answer stands.
/// A class property's FULL declared type, following the supertype chain the
/// head lookup follows.
pub fn propTypeRefOn(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?ir.TypeRef {
    if (b.module.registry.class_prop_type_refs.get(.{ .a = owner, .b = name })) |t| return t;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    for (chain) |cls| {
        if (b.module.registry.class_prop_type_refs.get(.{ .a = cls, .b = name })) |t| return t;
    }
    return null;
}

/// A declared property type with the OWNER's type parameters replaced by the
/// receiver's own type arguments. Null when any argument stays a parameter —
/// a partial answer says nothing the head does not already say.
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

/// A bare type-parameter head is not a property owner; its declared BOUND
/// is. `entries` inside `<K, V, M : Map<out K, V>> M.onEachIndexed` reads a
/// Map property, so the owner lookups chase `M -> Map`.
fn boundOwnerHead(b: *const FuncBuilder, head: []const u8) []const u8 {
    if (b.typeParamBoundRef(head)) |bref| {
        var h = std.mem.trimEnd(u8, bref.name, "?");
        if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
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
    // Inside `val writer = writer`'s initializer the local's own name is
    // free (recorded at the decl), so the reference is the enclosing
    // member, never the shadow being declared.
    const self_shadowed = expr_mod.init_self_name != null and std.mem.eql(u8, expr_mod.init_self_name.?, recv_name);
    // A local/param binding shadows an enclosing member of the same name.
    if (!self_shadowed) {
        if (b.resolve(recv_name) != null) return b.localDeclType(recv_name);
        if (b.knowsOuter(recv_name)) return null;
    }
    // The enclosing class, else the EXTENSION RECEIVER — a bare name inside
    // `fun UByteArray.indices()` is a member of the receiver, and a top-level
    // extension has no enclosing class at all, so the search stopped there.
    const tr = if (runtime.envOnce("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, recv_name) else false;
    const owner = b.ownerClass() orelse blk: {
        if (std.mem.eql(u8, runtime.envOnce("KLIO_EXT_RECV_PROP") orelse "1", "0")) return null;
        // The splice-receiver hint serves the same role inside an inline
        // extension splice, where the body's builder has no recvTy of its
        // own.
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
    // RECEIVER's member rather than the enclosing class's:
    // `Duration(raw).apply { … value … }` sits in Duration's companion, whose
    // own surface has no `value` at all. Consulted only after the enclosing
    // class declines, so no answer this walk already gives can change.
    const recv_head = b.recvTy() orelse b.spliceRecvTy() orelse b.enclosingRecvTy() orelse return null;
    const rh = boundOwnerHead(b, typeHead(std.mem.trimEnd(u8, recv_head, "?")));
    if (rh.len == 0 or std.mem.eql(u8, rh, owner)) return null;
    if (propTypeHeadOn(b, rh, recv_name)) |h| return h;
    return extPropReturnHead(b, rh, recv_name);
}

/// The declared return head of an EXTENSION PROPERTY named `name` on
/// `head` (or its builtin/declared supertypes): the lowered getter follows
/// the stable `__ext_get_<Head>_<name>` naming contract, and its return
/// type is the bare read's static type — `indices` inside a `ShortArray`
/// extension body is an `IntRange`, so the desugared `for (i in indices)`
/// iterator call binds.
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

/// The declaration-scan channel: `(receiver head, name)` recorded before
/// any body lowers, so the answer exists while the declaring library is
/// itself still lowering. The head must still name a class to be useful
/// dispatch evidence.
fn extPropDeclHead(b: *const FuncBuilder, head: []const u8, name: []const u8) ?[]const u8 {
    const raw = b.module.registry.ext_prop_type_heads.get(.{ .a = head, .b = name }) orelse return null;
    var h = std.mem.trimEnd(u8, raw, "?");
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (h.len == 0 or std.mem.eql(u8, h, "Unit")) return null;
    const cid = (if (std.mem.indexOfScalar(u8, h, '.') != null)
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
    if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (tr) std.debug.print("[extpget] ret head={s}\n", .{h});
    if (h.len == 0 or std.mem.eql(u8, h, "Unit")) return null;
    const cid = (if (std.mem.indexOfScalar(u8, h, '.') != null)
        b.module.classIdByFqn(h)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(h)));
    if (tr) std.debug.print("[extpget] cid={?}\n", .{cid});
    if (cid == null) return null;
    return h;
}

/// The property-head key for `owner` as the site's file sees it: the
/// scope-resolved class's qualified name, which is exact when two packages
/// share the simple name. Null when the simple key already is the class.
/// An unqualified nested-class name resolves LEXICALLY first: written inside
/// `LinkComposer`, `CompositionContextImpl` is LinkComposer's own nested
/// class, never the same-named one nested in `GapComposer` of the same
/// package (which the package-tiered index cannot tell apart). Walks the
/// enclosing class's qualified name outwards, trying `<outer>.<simple>`.
fn lexicalNestedClassFqn(b: *const FuncBuilder, simple: []const u8, file: ir.FileId) ?[]const u8 {
    const oc = b.ownerClass() orelse return null;
    const cid = b.module.classIdIndexed(oc, b.self_package, file) orelse b.module.classId(oc) orelse return null;
    var fqn = b.module.classFqnById(cid) orelse return null;
    var buf: [512]u8 = undefined;
    while (fqn.len > b.self_package.len) {
        const cand = std.fmt.bufPrint(&buf, "{s}.{s}", .{ fqn, simple }) catch return null;
        if (b.module.classIdByFqn(cand)) |nid| return b.module.classFqnById(nid);
        const dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return null;
        fqn = fqn[0..dot];
    }
    return null;
}

fn scopedPropOwnerKey(b: *const FuncBuilder, owner: []const u8, site_file: ?ir.FileId) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, owner, '.') != null) return null;
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

/// A declared receiver type's own property-head key: the written qualified
/// name when the declaration spelled one (`r: kotlin.text.Regex` reads
/// Regex's `pattern`, never a same-named user class's), else the head as
/// the site's file resolves it.
pub fn declTypePropOwnerKey(b: *const FuncBuilder, ty: *const ir.TypeRef, site_file: ?ir.FileId) ?[]const u8 {
    for (ty.args) |*a| {
        if (std.mem.startsWith(u8, a.name, "#qual:")) return a.name["#qual:".len..];
    }
    var t = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.indexOfScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.indexOfScalar(u8, t, '.') != null) return t;
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
    // A property typed only by its initializer call (`val json = Json {
    // … }`): the class registration could not see a pack's factory or
    // class, so the head is read from the initializer here, where every
    // declaration is registered.
    if (propInitCallHead(b, owner, name)) |h| return h;
    for (chain) |cls| {
        if (propInitCallHead(b, cls, name)) |h| return h;
    }
    // A runtime anon-object member body's own property heads travel in the
    // installed snapshot — the synthesized class has no registry entries.
    return build.anonPropHead(owner, name);
}

/// The class a member property's initializer call names: a constructor
/// (`Json { }` resolves to the class of that name) or a plain function
/// whose same-named overloads agree on a declared, concrete return head.
pub fn propInitCallHead(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?[]const u8 {
    const p = inline_state.memberPropAst(owner, name) orelse {
        if (std.c.getenv("KLIO_PROPHEAD_TRACE") != null) std.debug.print("[prophead-lazy] no ast for {s}.{s}\n", .{ owner, name });
        return null;
    };
    if (std.c.getenv("KLIO_PROPHEAD_TRACE") != null) std.debug.print("[prophead-lazy] {s}.{s} ty={} init={}\n", .{ owner, name, p.ty != null, p.init != null });
    if (p.ty != null) return null;
    const init = p.init orelse return null;
    if (init != .Call) return null;
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
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len == 0 or std.mem.eql(u8, head, "Unit") or (head.len <= 2 and std.ascii.isUpper(head[0]))) return null;
        if (agreed) |g| {
            if (!std.mem.eql(u8, g, head)) return null;
        } else agreed = head;
    }
    return agreed;
}

/// Whether `ty` (or a supertype) declares a member property named `name`.
/// Keyed on `class_prop_type_heads`, which records member and constructor-
/// parameter properties by declaring class.
pub fn staticTypeDeclaresProp(b: *const FuncBuilder, ty: []const u8, name: []const u8) bool {
    const heads = b.module.registry.class_prop_type_heads;
    if (heads.get(.{ .a = ty, .b = name }) != null) return true;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(ty) orelse return false;
    for (chain) |cls| {
        if (heads.get(.{ .a = cls, .b = name }) != null) return true;
    }
    return false;
}

/// When a qualified read `recv.name` resolves — by the STATIC type of `recv`
/// — to an in-scope member-extension property whose getter must win over any
/// same-named stored field on the runtime object, return the interned
/// `$extread$<name>` marker. Null when the ordinary field read applies.
fn staticExtPropReadField(b: *FuncBuilder, receiver: *const Expr, name: []const u8) Allocator.Error!?ConstId {
    const recv_name = switch (receiver.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else return null,
        else => return null,
    };
    const static_ty = staticBareReceiverType(b, recv_name) orelse return null;
    const owner = b.ownerClass() orelse return null;
    // An in-scope member-extension property `name` on the enclosing class
    // whose extension-receiver type the static type satisfies.
    const ext_recv = inline_state.memberExtPropRecv(owner, name) orelse return null;
    if (!b.module.classIsOrExtends(static_ty, ext_recv)) return null;
    // A member of the static type outranks the extension (Kotlin); the
    // ordinary field read is then correct.
    if (staticTypeDeclaresProp(b, static_ty, name)) return null;
    const marker = try std.fmt.allocPrint(b.allocator, "$extread${s}", .{name});
    return try b.module.internConst(b.allocator, .{ .String = marker });
}

/// The `<Q>` of `super<Q>`: the supertype the call dispatches on. A
/// `super@Label` names the class whose supertypes are walked and is carried
/// by the owner/receiver pair (`superBase`), never by the qualifier.
pub fn superQualifier(b: *FuncBuilder, qualifier: ?ast.TypeRef) Allocator.Error!?ConstId {
    if (qualifier) |t| {
        return try b.module.internConst(b.allocator, .{ .String = t.name.name });
    }
    return null;
}

const SuperBase = struct { this_reg: Reg, owner: []const u8 };

/// The instance and class a `super` expression starts from. Unlabeled
/// `super` starts at the enclosing class on `this`; `super@Outer` written in
/// an inner class starts at `Outer` on `this@Outer`, so `super<K>@A.foo()`
/// runs K's implementation against the A instance and its overrides.
pub fn superBase(b: *FuncBuilder, sup: anytype) Allocator.Error!?SuperBase {
    const this_reg = (try resolveSuperThisReg(b)) orelse return null;
    const owner = b.ownerClass() orelse return null;
    const label = sup.label orelse return .{ .this_reg = this_reg, .owner = owner };
    const target = scopeTypeRename(b, label.name, label.span.file.int()) orelse label.name;
    if (std.mem.eql(u8, target, owner)) return .{ .this_reg = this_reg, .owner = owner };
    const nm = try b.module.internConst(b.allocator, .{ .String = target });
    const dst = b.allocReg();
    try b.push(.{ .QualifiedThis = .{ .dst = dst, .receiver = this_reg, .qualifier = nm } });
    return .{ .this_reg = dst, .owner = target };
}
