//! Static expression type inference and the memo that backs it.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const decl_mod = @import("../decl.zig");
const inline_call = @import("../inline_call.zig");
const inline_state = @import("../inline_state.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const FuncId = ir.FuncId;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;

const expr_mod = @import("../expr.zig");

const audit_mod = @import("audit.zig");
const binary_mod = @import("binary.zig");
const isPrimitiveTypeName = binary_mod.isPrimitiveTypeName;
const numericPromotion = binary_mod.numericPromotion;
const staticClassifierArgsComplete = binary_mod.staticClassifierArgsComplete;

const paths_mod = @import("paths.zig");
const loweredTypeName = paths_mod.loweredTypeName;
const scopeTypeRenameFrom = paths_mod.scopeTypeRenameFrom;

const member_mod = @import("member.zig");
const declTypePropOwnerKey = member_mod.declTypePropOwnerKey;
const extPropReturnHead = member_mod.extPropReturnHead;
const propInitCallHead = member_mod.propInitCallHead;
const propTypeHeadOn = member_mod.propTypeHeadOn;
const propTypeRefOn = member_mod.propTypeRefOn;
const staticBareReceiverType = member_mod.staticBareReceiverType;
const staticBareReceiverTypeRef = member_mod.staticBareReceiverTypeRef;
const substitutedPropType = member_mod.substitutedPropType;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;

const type_probe_mod = @import("type_probe.zig");
const buildStaticReturnArgShapes = type_probe_mod.buildStaticReturnArgShapes;
const classNestedInEnclosing = type_probe_mod.classNestedInEnclosing;
const enclosingHasMemberNamed = type_probe_mod.enclosingHasMemberNamed;
const implBoundScan = type_probe_mod.implBoundScan;
const localInitTypeRef = type_probe_mod.localInitTypeRef;

const probe_mod = @import("probe.zig");
const bareTypeParamHead = probe_mod.bareTypeParamHead;
const typeHead = probe_mod.typeHead;

const expected_mod = @import("expected.zig");
const enumClassOfPath = expected_mod.enumClassOfPath;

const tests_shapes_mod = @import("tests_shapes.zig");
const span = tests_shapes_mod.span;

/// A statically known type for one argument, from declared evidence alone: no
/// overload resolution, no call-return derivation. Each rung below answers for
/// one argument shape; a rung that recognises nothing declines to the next.
pub fn argDeclTypeRefLazyUncached(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    traceLazyArgType(b, arg);
    if (arg.* == .This and arg.This.qualifier == null) return bareThisTypeRef(b);
    if (arg.* == .This) return labeledThisTypeRef(b, arg.This);
    if (literalTypeRef(arg)) |t| return t;
    if (castTypeRef(b, arg)) |t| return t;
    if (memberReadTypeRef(b, arg)) |t| return t;
    // `x++`/`x--` evaluates to the operand's prior value and carries its type.
    if (arg.* == .Postfix) return argDeclTypeRefLazy(b, arg.Postfix.expr);
    if (unaryTypeRef(b, arg)) |t| return t;
    if (arithmeticTypeRef(b, arg)) |t| return t;
    // A rung that reaches an answer of its own — a type, or `null` for a shape
    // whose type it declines to name — leaves `settled` true, and that answer
    // is the deriver's; a rung that recognises nothing leaves it false.
    var settled = false;
    if (rangeTypeRef(b, arg, &settled)) |t| return t;
    if (settled) return null;
    if (operatorMemberTypeRef(b, arg)) |t| return t;
    if (indexElementTypeRef(b, arg)) |t| return t;
    if (universalMemberCallTypeRef(arg)) |t| return t;
    if (bareCallTypeRef(b, arg, &settled)) |t| return t;
    if (settled) return null;
    // A class-named receiver's property head is the static type.
    if (arg.* == .Member) return classNamedPropertyTypeRef(b, arg);
    if (arg.* != .Path) return null;
    const p = arg.Path;
    if (p.segments.len == 2) return qualifiedPropertyTypeRef(b, p);
    if (p.segments.len != 1) return null;
    if (spliceParamTypeRef(b, p)) |t| return t;
    if (b.localDeclTypeRef(p.segments[0].name)) |declared| {
        var result = declared;
        result.nullable = result.nullable or b.localDeclNullable(p.segments[0].name);
        return result;
    }
    if (ownPropertyTypeRef(b, p)) |t| return t;
    if (localInitEvidenceTypeRef(b, arg, p)) |t| return t;
    // The full declared type wins over its head, which throws the arguments away.
    if (staticBareReceiverTypeRef(b, p.segments[0].name)) |full| return full;
    if (staticBareReceiverType(b, p.segments[0].name)) |head| {
        return .{ .name = head, .nullable = false, .args = &.{} };
    }
    if (bareClassValueTypeRef(b, p)) |t| return t;
    if (topLevelPropertyTypeRef(b, p)) |t| return t;
    return eagerReceiverTypeRef(b, arg);
}

/// Typeck's head for this expression, asked last. Every rung above derives a
/// type from a declaration the builder can see; this one reads what the
/// checker already worked out, which is the only source for an expression
/// whose type is not written down anywhere. `KLIO_EAGER_RECV=0` puts it back.
pub var eager_recv_counts: [2]u64 = @splat(0);
pub var eager_recv_miss_state: [4]u64 = @splat(0);
pub var eager_recv_miss_kind: [@typeInfo(@typeInfo(Expr).@"union".tag_type.?).@"enum".fields.len]u64 = @splat(0);

fn eagerReceiverTypeRef(b: *const FuncBuilder, e: *const Expr) ?ir.TypeRef {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_EAGER_RECV") orelse "1", "0")) return null;
    eager_recv_counts[0] +%= 1;
    const head = b.module.eagerRecvTypeOf(e.span()) orelse {
        // Aim at what the CONSUMER asks for: the checker's coverage as a
        // whole is a different population from the receivers this rung is
        // asked about, and improving one moved the other by nothing.
        const k = @intFromEnum(std.meta.activeTag(e.*));
        if (k < eager_recv_miss_kind.len) eager_recv_miss_kind[k] +%= 1;
        // Did the checker never see this expression, or see it and fail to
        // name it? The two send the work to different places, and the rung's
        // aggregate cannot tell them apart.
        const st = b.module.eagerEntryState(e.span());
        eager_recv_miss_state[@intFromEnum(st)] +%= 1;
        if (st == .named and runtime.envOnce("KLIO_EAGER_REFUSED") != null) {
            if (b.module.eagerRawHead(e.span())) |h|
                std.debug.print("[eager-refused] {s}\n", .{h});
        }
        if (runtime.envOnce("KLIO_EAGER_RECV_NAMES") != null and
            e.* == .Path and e.Path.segments.len == 1)
        {
            std.debug.print("[eager-recv-name] {s} in={s}\n", .{
                e.Path.segments[0].name,
                build.currentRealFn() orelse "-",
            });
        }
        return null;
    };
    var h = std.mem.trimEnd(u8, head.name, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (h.len == 0) return null;
    eager_recv_counts[1] +%= 1;
    return .{ .name = h, .nullable = head.nullable, .args = &.{} };
}

pub fn dispatchStatsOn() bool {
    return runtime.envOnce("KLIO_DISPATCH_STATS") != null;
}

/// How often the deriver's last rung — typeck's own head — actually answers.
pub fn eagerRecvDump() void {
    if (runtime.envOnce("KLIO_DISPATCH_STATS") == null) return;
    std.debug.print("[untyped-local] no_init={d} of_which_params={d}\n", .{ arg_shape_mod.untyped_local_no_init, arg_shape_mod.untyped_local_no_init_param });
    if (arg_shape_mod.untyped_local_names) |*names| {
        // The twenty most-read names.
        var top: [20]struct { n: []const u8, c: u64 } = undefined;
        var n_top: usize = 0;
        var it = names.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            var pos: usize = n_top;
            while (pos > 0 and top[pos - 1].c < c) : (pos -= 1) {}
            if (pos >= top.len) continue;
            var k: usize = @min(n_top, top.len - 1);
            while (k > pos) : (k -= 1) top[k] = top[k - 1];
            top[pos] = .{ .n = e.key_ptr.*, .c = c };
            if (n_top < top.len) n_top += 1;
        }
        for (top[0..n_top]) |t| std.debug.print("[untyped-local-name] {d:>8}  {s}\n", .{ t.c, t.n });
    }
    inline for (@typeInfo(@typeInfo(Expr).@"union".tag_type.?).@"enum".fields) |f| {
        if (arg_shape_mod.untyped_local_init_kind[f.value] != 0)
            std.debug.print("[untyped-local] {d:>8}  init={s}\n", .{ arg_shape_mod.untyped_local_init_kind[f.value], f.name });
    }
    std.debug.print("[eager-recv] asked={d} served={d}\n", .{ eager_recv_counts[0], eager_recv_counts[1] });
    inline for (@typeInfo(@typeInfo(Expr).@"union".tag_type.?).@"enum".fields) |f| {
        if (eager_recv_miss_kind[f.value] != 0)
            std.debug.print("[eager-recv-miss] {d:>8}  {s}\n", .{ eager_recv_miss_kind[f.value], f.name });
    }
    std.debug.print("[eager-recv-state] no_map={d} never_seen={d} seen_unnamed={d} named_but_refused={d}\n", .{
        eager_recv_miss_state[0], eager_recv_miss_state[1], eager_recv_miss_state[2], eager_recv_miss_state[3],
    });
}


/// `KLIO_VALTY_TRACE=<name>`: what the lazy channel knows about a bare name.
fn traceLazyArgType(b: *FuncBuilder, arg: *const Expr) void {
    if (runtime.envOnce("KLIO_VALTY_TRACE")) |w| {
        if (arg.* == .Path and arg.Path.segments.len == 1 and std.mem.eql(u8, arg.Path.segments[0].name, w)) {
            std.debug.print("[valty] LAZY {s} decl={s} splice={} lsr={}\n", .{ w, if (b.localDeclTypeRef(w)) |t| t.name else "<unset>", b.spliceParamTy(w) != null, b.lambda_splice_resolve != null });
        }
    }
}


/// Bare `this`. An extension body spliced into a member binds a new `this`
/// while the flat declaration metadata still names the enclosing member
/// receiver, so the splice receiver wins. A spliced lambda argument skips it.
fn bareThisTypeRef(b: *FuncBuilder) ?ir.TypeRef {
    if (b.lambda_splice_resolve == null) {
        // The window's full receiver record wins over the head-only channel.
        if (b.spliceRecvTyRef()) |ref| return ref.*;
        if (b.spliceRecvTy()) |head| {
            return .{ .name = head, .nullable = false, .args = &.{} };
        }
    }
    if (b.localDeclTypeRef("this")) |narrowed| return narrowed;
    if (b.recvTypeRef()) |receiver| return receiver;
    if (b.enclosingRecvTy()) |head| {
        return .{ .name = head, .nullable = false, .args = &.{} };
    }
    return null;
}


/// `this@label`: the builder's own receiver when its label matches (an ext
/// body's label is its fn name), else the tower entry carrying it.
fn labeledThisTypeRef(b: *FuncBuilder, this_e: @FieldType(Expr, "This")) ?ir.TypeRef {
if (this_e.qualifier) |q| {
    if (b.own_this_label) |own| {
        if (std.mem.eql(u8, own, q.name)) {
            if (b.recvTypeRef()) |receiver| return receiver;
            if (b.recvTy()) |head| return .{ .name = head, .nullable = false, .args = &.{} };
        }
    }
    for (b.implicit_receiver_tower.items) |entry| {
        const label = entry.label orelse continue;
        if (std.mem.eql(u8, label, q.name)) {
            return .{ .name = entry.head, .nullable = false, .args = &.{} };
        }
    }
}
return null;
}


/// Literals name their own type.
fn literalTypeRef(arg: *const Expr) ?ir.TypeRef {
    switch (arg.*) {
        .IntLit => |lit| return .{
            .name = switch (lit.kind) {
                .Int => if (lit.value >= std.math.minInt(i32) and
                    lit.value <= std.math.maxInt(i32)) "Int" else "Long",
                .Long => "Long",
                .UInt => "UInt",
                .ULong => "ULong",
            },
            .nullable = false,
            .args = &.{},
        },
        .FloatLit => |lit| return .{
            .name = if (lit.kind == .Float) "Float" else "Double",
            .nullable = false,
            .args = &.{},
        },
        .BoolLit => return .{ .name = "Boolean", .nullable = false, .args = &.{} },
        .CharLit => return .{ .name = "Char", .nullable = false, .args = &.{} },
        .StringTemplate => return .{ .name = "String", .nullable = false, .args = &.{} },
        .NullLit => return .{ .name = "Nothing", .nullable = true, .args = &.{} },
        else => {},
    }
    return null;
}


/// An unsafe cast fixes the argument's static type for overload resolution.
fn castTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .As and !arg.As.safe) {
        return .{ .name = loweredTypeName(b, &arg.As.ty), .nullable = arg.As.ty.nullable, .args = &.{} };
    }
    return null;
}


/// A member property read as a receiver: receiver head plus property head.
fn memberReadTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .Member and !arg.Member.safe) {
        const m = arg.Member;
        // A class-named receiver reads the companion's property.
        if (m.receiver.* == .Path and m.receiver.Path.segments.len == 1) {
            const on = m.receiver.Path.segments[0].name;
            if (on.len != 0 and std.ascii.isUpper(on[0]) and
                b.resolve(on) == null and b.module.classId(on) != null)
            {
                var cb2: [96]u8 = undefined;
                if (std.fmt.bufPrint(&cb2, "{s}$Companion", .{on}) catch null) |ck2| {
                    if (b.module.registry.class_prop_type_heads.get(.{ .a = ck2, .b = m.name.name })) |head| {
                        return .{ .name = head, .nullable = false, .args = &.{} };
                    }
                }
                if (b.module.registry.class_prop_type_heads.get(.{ .a = on, .b = m.name.name })) |head| {
                    return .{ .name = head, .nullable = false, .args = &.{} };
                }
            }
        }
        // An enum entry is a value of its enum class, nested enums included.
        if (m.receiver.* == .Path and !std.mem.eql(u8, m.name.name, "entries")) {
            if (enumClassOfPath(b, m.receiver)) |enum_name| {
                return .{ .name = enum_name, .nullable = false, .args = &.{} };
            }
        }
        if (argDeclTypeRefLazy(b, m.receiver)) |rt| {
            var h = std.mem.trimEnd(u8, rt.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const head = typeHead(h);
            // The site's own view of the owner class first: two packages can share
            // a simple name with differently typed properties, and the simple key
            // holds only one.
            const scoped_key = declTypePropOwnerKey(b, &rt, m.name.span.file);
            if (runtime.envOnce("KLIO_CIX_TRACE")) |w| {
                if (std.mem.eql(u8, w, head)) {
                    const hp = if (scoped_key) |k| b.module.registry.class_prop_type_heads.get(.{ .a = k, .b = m.name.name }) else null;
                    std.debug.print("[cix-route] {s}.{s} rt={s} file={d} key={?s} hit={?s}\n", .{ head, m.name.name, rt.name, m.name.span.file.int(), scoped_key, hp });
                }
            }
            if (scoped_key) |key| {
                if (b.module.registry.class_prop_type_heads.get(.{ .a = key, .b = m.name.name })) |ph| {
                    return .{ .name = ph, .nullable = false, .args = &.{} };
                }
                if (propInitCallHead(b, key, m.name.name)) |ph| {
                    return .{ .name = ph, .nullable = false, .args = &.{} };
                }
            }
            // The full declared type, with the owner's type parameters substituted.
            if (propTypeRefOn(b, head, m.name.name)) |declared| {
                if (substitutedPropType(b, head, rt, declared)) |full| return full;
            }
            if (propTypeHeadOn(b, head, m.name.name) orelse
                extPropReturnHead(b, head, m.name.name)) |ph|
            {
                return .{ .name = ph, .nullable = false, .args = &.{} };
            }
            // Builtin properties with no Kotlin declaration to read.
            if (std.mem.eql(u8, head, "Char") and std.mem.eql(u8, m.name.name, "code")) {
                return .{ .name = "Int", .nullable = false, .args = &.{} };
            }
        }
    }
    return null;
}


/// `!x` is Boolean; `-x` and `+x` carry the operand's type.
fn unaryTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .Unary) {
        switch (arg.Unary.op) {
            .Not => return .{ .name = "Boolean", .nullable = false, .args = &.{} },
            .Neg, .Pos => return argDeclTypeRefLazy(b, arg.Unary.expr),
            else => {},
        }
    }
    return null;
}


/// Arithmetic on primitives promotes to the wider operand.
fn arithmeticTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .Binary) {
        switch (arg.Binary.op) {
            .Eq, .Neq, .IdentEq, .IdentNeq, .Lt, .Le, .Gt, .Ge, .In, .NotIn, .And, .Or => {
                return .{ .name = "Boolean", .nullable = false, .args = &.{} };
            },
            .Add, .Sub, .Mul, .Div, .Rem => arith: {
                // Falls through on anything it cannot answer, so the class
                // operator-member arm below still sees a non-primitive operand.
                const lt = argDeclTypeRefLazy(b, arg.Binary.lhs) orelse
                    break :arith;
                const rt = argDeclTypeRefLazy(b, arg.Binary.rhs) orelse
                    break :arith;
                if (lt.nullable or rt.nullable) break :arith;
                const lh = typeHead(std.mem.trimEnd(u8, lt.name, "?"));
                const rh = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
                if (!isPrimitiveTypeName(lh) or !isPrimitiveTypeName(rh)) break :arith;
                // Kotlin's numeric promotion order. A String on either side is
                // concatenation and `Char + Int` is a Char, so both decline.
                // Unsigned arithmetic never mixes with the signed types:
                // `UByte`/`UShort` widen to `UInt`, a `ULong` operand wins.
                const unsigned = [_][]const u8{ "UByte", "UShort", "UInt", "ULong" };
                var l_unsigned = false;
                var r_unsigned = false;
                for (unsigned) |un| {
                    if (std.mem.eql(u8, lh, un)) l_unsigned = true;
                    if (std.mem.eql(u8, rh, un)) r_unsigned = true;
                }
                if (l_unsigned != r_unsigned) break :arith;
                if (l_unsigned) {
                    const w: []const u8 = if (std.mem.eql(u8, lh, "ULong") or
                        std.mem.eql(u8, rh, "ULong")) "ULong" else "UInt";
                    return .{ .name = w, .nullable = false, .args = &.{} };
                }
                const order = [_][]const u8{ "Double", "Float", "Long", "Int" };
                for (order) |w| {
                    if (std.mem.eql(u8, lh, w) or std.mem.eql(u8, rh, w)) {
                        // Byte/Short arithmetic is Int in Kotlin.
                        return .{ .name = w, .nullable = false, .args = &.{} };
                    }
                }
                const small = [_][]const u8{ "Byte", "Short" };
                for (small) |sm| {
                    if (std.mem.eql(u8, lh, sm) and std.mem.eql(u8, rh, sm)) {
                        return .{ .name = "Int", .nullable = false, .args = &.{} };
                    }
                }
            },
            else => {},
        }
    }
    return null;
}


/// The range classes exist while the operator producing them is builtin. A user
/// class shadowing a builtin range's simple name must not capture `1..2`'s
/// members, so that case settles as no static type rather than declining.
fn rangeTypeRef(b: *FuncBuilder, arg: *const Expr, settled: *bool) ?ir.TypeRef {
    settled.* = true;

    if (arg.* == .Binary and arg.Binary.op == .Range) {
        if (argDeclTypeRefLazy(b, arg.Binary.lhs)) |lt| {
            if (!lt.nullable) {
                const lh = typeHead(std.mem.trimEnd(u8, lt.name, "?"));
                const ranges = [_]struct { e: []const u8, r: []const u8 }{
                    .{ .e = "Int", .r = "IntRange" },     .{ .e = "Long", .r = "LongRange" },
                    .{ .e = "Char", .r = "CharRange" },   .{ .e = "UInt", .r = "UIntRange" },
                    .{ .e = "ULong", .r = "ULongRange" },
                };
                for (ranges) |rr| {
                    if (std.mem.eql(u8, lh, rr.e)) {
                        // A user class shadowing a builtin range's simple name
                        // must not capture `1..2`'s members, which would bind that
                        // class's own `contains` and recurse; dropping the static
                        // type dispatches dynamically. The stdlib's own range
                        // classes keep their static type.
                        const shadow_cid = b.module.classIdIndexed(rr.r, b.self_package, arg.span().file) orelse b.module.classId(rr.r);
                        if (shadow_cid) |cid| {
                            if (cid.int() < b.module.classes.items.len) {
                                const fqn = b.module.classes.items[cid.int()].fqn;
                                if (!std.mem.startsWith(u8, fqn, "kotlin.")) return null;
                            }
                        }
                        return .{ .name = rr.r, .nullable = false, .args = &.{} };
                    }
                }
            }
        }
    }
    settled.* = false;
    return null;
}


/// `a / b` on a class is an operator member; its declared return is the answer.
fn operatorMemberTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .Binary) {
        const opname: ?[]const u8 = switch (arg.Binary.op) {
            .Add => "plus",
            .Sub => "minus",
            .Mul => "times",
            .Div => "div",
            .Rem => "rem",
            else => null,
        };
        if (opname) |on| {
            if (argDeclTypeRefLazy(b, arg.Binary.lhs)) |lt| {
                if (!lt.nullable) {
                    var identity = std.mem.trimEnd(u8, lt.name, "?");
                    if (std.mem.findScalar(u8, identity, '<')) |ltp| identity = identity[0..ltp];
                    const lh = typeHead(identity);
                    if (lh.len != 0 and !isPrimitiveTypeName(lh)) {
                        // The operator member is chosen by the same engine that
                        // dispatches it, with the rhs's static type as evidence.
                        // A name-plus-arity shortcut breaks once overloads diverge
                        // on return type, so an unresolvable set stays untyped.
                        const owner_id = if (std.mem.findScalar(u8, identity, '.') != null)
                            b.module.classIdByFqn(identity)
                        else
                            b.module.uniqueClassIdBySimpleName(lh);
                        if (owner_id) |owner| {
                            const rhs_ty = argDeclTypeRefLazy(b, arg.Binary.rhs);
                            const shape = applicability.ArgShape{
                                .ty = rhs_ty,
                                .ty_authoritative = rhs_ty != null,
                            };
                            const resolved = b.module.resolveMemberCall(owner, on, &.{shape}, .{
                                .caller_file = arg.Binary.span.file,
                                .lexical_owner = null,
                                .receiver_type = lt,
                            });
                            if (resolved.target) |fid| {
                                if (b.module.funcById(fid)) |f| {
                                    if (f.return_ty_declared and f.return_ty.name.len != 0) {
                                        return .{
                                            .name = f.return_ty.name,
                                            .nullable = f.return_ty.nullable,
                                            .args = &.{},
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return null;
}


/// The sole type argument, or a stated element where there is no declaration.
fn indexElementTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (arg.* == .Index and arg.Index.args.len == 1) {
        if (argDeclTypeRefLazy(b, arg.Index.receiver)) |rt| {
            if (!rt.nullable) {
                const h = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
                if (std.mem.eql(u8, h, "CharSequence") or std.mem.eql(u8, h, "String") or
                    std.mem.eql(u8, h, "StringBuilder"))
                {
                    return .{ .name = "Char", .nullable = false, .args = &.{} };
                }
                const prim = [_]struct { a: []const u8, e: []const u8 }{
                    .{ .a = "BooleanArray", .e = "Boolean" }, .{ .a = "ByteArray", .e = "Byte" },
                    .{ .a = "ShortArray", .e = "Short" },     .{ .a = "IntArray", .e = "Int" },
                    .{ .a = "LongArray", .e = "Long" },       .{ .a = "CharArray", .e = "Char" },
                    .{ .a = "FloatArray", .e = "Float" },     .{ .a = "DoubleArray", .e = "Double" },
                    .{ .a = "UByteArray", .e = "UByte" },     .{ .a = "UShortArray", .e = "UShort" },
                    .{ .a = "UIntArray", .e = "UInt" },       .{ .a = "ULongArray", .e = "ULong" },
                };
                for (prim) |pa| {
                    if (std.mem.eql(u8, h, pa.a)) {
                        return .{ .name = pa.e, .nullable = false, .args = &.{} };
                    }
                }
            }
        }
    }
    return null;
}


/// A bare call: a local function's declared return, or a unique concrete
/// classifier with no same-named plain function, which is a constructor call
/// whose result head is authoritative. Collisions are left to the ordinary call
/// resolver.
/// `Any`'s members are every value's, whatever the receiver: `x.toString()`
/// is a `String`, `x.hashCode()` an `Int`, `x.equals(y)` a `Boolean`, and no
/// class can declare them otherwise.
fn universalMemberCallTypeRef(arg: *const Expr) ?ir.TypeRef {
    if (arg.* != .Call or arg.Call.callee.* != .Member or arg.Call.type_args.len != 0) return null;
    const name = arg.Call.callee.Member.name.name;
    const n = arg.Call.args.len;
    const head: []const u8 = if (n == 0 and std.mem.eql(u8, name, "toString"))
        "String"
    else if (n == 0 and std.mem.eql(u8, name, "hashCode"))
        "Int"
    else if (n == 1 and std.mem.eql(u8, name, "equals"))
        "Boolean"
    else
        return null;
    return .{ .name = head, .nullable = false, .args = &.{} };
}

fn bareCallTypeRef(b: *FuncBuilder, arg: *const Expr, settled: *bool) ?ir.TypeRef {
    settled.* = true;

    if (arg.* == .Call and arg.Call.callee.* == .Path and arg.Call.callee.Path.segments.len == 1) {
        const seg = arg.Call.callee.Path.segments[0];
        if (b.localCallReturn(seg.name)) |ret| {
            return .{ .name = ret.name, .nullable = ret.nullable, .args = &.{} };
        }
        // A unique concrete classifier with no same-named plain function is a
        // constructor call, so its result head is authoritative; collisions are
        // left to the ordinary call resolver.
        if (b.resolve(seg.name) == null and !b.isLocalFn(seg.name) and
            !enclosingHasMemberNamed(b, seg.name))
        {
            var same_named_function = false;
            for (b.module.funcsBySimpleName(seg.name)) |fid| {
                const f = b.module.funcById(fid) orelse continue;
                if (f.kind == .plain and
                    (f.hasBody() or b.module.decl_ast_body.contains(fid.int())))
                {
                    same_named_function = true;
                    break;
                }
            }
            if (!same_named_function) {
                const pkg = b.module.packageOfFile(seg.span.file) orelse b.self_package;
                if (b.module.classIdIndexed(seg.name, pkg, seg.span.file)) |cid| {
                    if (cid.int() < b.module.classes.items.len) {
                        const class = &b.module.classes.items[cid.int()];
                        if (!class.is_object and !class.is_interface and !class.is_abstract) {
                            const type_args = b.allocator.alloc(
                                ir.TypeRef,
                                arg.Call.type_args.len,
                            ) catch return null;
                            for (arg.Call.type_args, type_args) |*ast_ty, *out| {
                                out.* = decl_mod.loweredTypeRef(
                                    b.allocator,
                                    ast_ty,
                                    true,
                                ) catch return null;
                            }
                            return .{
                                .name = class.fqn,
                                .nullable = false,
                                .args = type_args,
                            };
                        }
                    }
                }
            }
        }
    }
    settled.* = false;
    return null;
}


/// A class-named receiver's property head, read through the property table.
fn classNamedPropertyTypeRef(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    const recv = arg.Member.receiver;
    // A safe read yields a nullable result, so look the property up on the
    // non-null owner and hand the `?` back; a plain read of a nullable
    // receiver keeps declining.
    const safe_read = arg.Member.safe;
    if (recv.* == .Path and recv.Path.segments.len == 1) {
        const owner = recv.Path.segments[0].name;
        if (owner.len != 0 and std.ascii.isUpper(owner[0]) and
            b.resolve(owner) == null and b.module.classId(owner) != null)
        {
            if (b.module.registry.class_prop_type_heads.get(.{ .a = owner, .b = arg.Member.name.name })) |head| {
                return .{ .name = head, .nullable = safe_read, .args = &.{} };
            }
        }
    }
    // Resolve each property segment from its receiver's declared type, so the
    // final member call can use the shared resolver; a call receiver has only
    // a resolved return.
    var owned_recv: ?ir.TypeRef = null;
    defer if (owned_recv) |*t| t.deinit(b.allocator);
    const recv_ty_opt: ?ir.TypeRef = argDeclTypeRefLazy(b, recv) orelse blk: {
        if (recv.* != .Call) break :blk null;
        owned_recv = (staticCallReturnTypeRef(b, recv) catch null) orelse break :blk null;
        break :blk owned_recv;
    };
    if (recv_ty_opt) |receiver_ty| {
        if (receiver_ty.nullable and !safe_read) return null;
        const owner = typeHead(std.mem.trimEnd(u8, receiver_ty.name, "?"));
        const heads = b.module.registry.class_prop_type_heads;
        if (declTypePropOwnerKey(b, &receiver_ty, arg.Member.name.span.file)) |key| {
            if (heads.get(.{ .a = key, .b = arg.Member.name.name })) |head| {
                return .{ .name = head, .nullable = safe_read, .args = &.{} };
            }
        }
        if (heads.get(.{ .a = owner, .b = arg.Member.name.name })) |head| {
            return .{ .name = head, .nullable = safe_read, .args = &.{} };
        }
        const chain: []const []const u8 =
            b.module.registry.class_super_names.get(owner) orelse &.{};
        for (chain) |super_name| {
            if (heads.get(.{ .a = super_name, .b = arg.Member.name.name })) |head| {
                return .{ .name = head, .nullable = safe_read, .args = &.{} };
            }
        }
    }
    return null;
}


/// `Owner.prop`: the declaring class's property head, or the companion's under
/// its lifted key.
fn qualifiedPropertyTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    const owner = p.segments[0].name;
    if (owner.len != 0 and std.ascii.isUpper(owner[0]) and
        b.resolve(owner) == null and b.module.classId(owner) != null)
    {
        if (b.module.registry.class_prop_type_heads.get(.{ .a = owner, .b = p.segments[1].name })) |head| {
            return .{ .name = head, .nullable = false, .args = &.{} };
        }
    // A class-named access reads the companion's property, under its lifted key.
        var cb: [96]u8 = undefined;
        if (std.fmt.bufPrint(&cb, "{s}$Companion", .{owner}) catch null) |ck| {
            if (b.module.registry.class_prop_type_heads.get(.{ .a = ck, .b = p.segments[1].name })) |head| {
                return .{ .name = head, .nullable = false, .args = &.{} };
            }
        }
    }
    return null;
}


/// An inlined function's parameters live in the caller builder while their
/// declared types belong to the spliced declaration, so keep the source type as
/// evidence. A spliced lambda argument skips this channel: its free names
/// resolve in the caller scopes and may shadow a same-named inline parameter.
fn spliceParamTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    if (b.lambda_splice_resolve == null or
        (b.resolve(p.segments[0].name) == null and
            !b.knowsOuter(p.segments[0].name)))
    {
        // A name the caller window cannot see can only be the spliced parameter.
        if (b.spliceParamTy(p.segments[0].name)) |declared| {
            if (declared.function == null) {
                // A declared head that is itself a type parameter of the spliced
                // declaration names nothing here, so the argument's derived type
                // under the local-decl channel wins.
                const dh = declared.name.name;
                const tp_head = ((dh.len > 0 and dh.len <= 2 and
                    std.ascii.isUpper(dh[0])) or b.isTypeParam(dh));
                if (!tp_head) {
                    return .{
                        .name = declared.name.name,
                        .nullable = declared.nullable,
                        .args = &.{},
                    };
                }
            }
        }
    }
    return null;
}


/// A bare implicit-`this` property read of the enclosing class's own `val`,
/// resolved against the receiver's property table with a nested-class head
/// qualified through the enclosing scope.
fn ownPropertyTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    const rhead: ?[]const u8 = if (b.recvTypeRef()) |rt|
        typeHead(std.mem.trimEnd(u8, rt.name, "?"))
    else
        b.ownerClass() orelse b.enclosingRecvTy();
    if (rhead) |rh| {
        if (b.module.registry.class_prop_type_heads.get(.{ .a = rh, .b = p.segments[0].name })) |head| {
            if (head.len != 0 and !b.isTypeParam(head)) {
                const qualified = scopeTypeRenameFrom(b, rh, head, p.segments[0].span.file.int()) orelse head;
                return .{ .name = qualified, .nullable = false, .args = &.{} };
            }
        }
    }
    return null;
}


/// The type a local's own initializer lends it. Kotlin has no initializer
/// cycle, since a local cannot be initialized from one declared after it, but
/// lowering re-asks from a later point in the block where every local is bound,
/// so mutually referencing inits recurse: a local already on the chain refuses
/// to re-enter.
fn localInitEvidenceTypeRef(b: *FuncBuilder, arg: *const Expr, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    if (b.localInitExpr(p.segments[0].name)) |init| {
        // Kotlin has no initializer cycle, since a local cannot be initialized
        // from one declared after it, but lowering re-asks from a later point in
        // the block where every local is bound, so mutually referencing inits
        // recurse. Refuse to re-enter a local already on the chain.
        if (init != arg and pushInitChain(p.segments[0].name)) {
            defer popInitChain();
        // The initializer is read in its declaration scope, where the local's own
        // name was free, so its bare calls must not see the binding that exists at
        // the read point.
            const prev_self = expr_mod.init_self_name;
            if (b.localInitNameFree(p.segments[0].name) and
                !std.mem.eql(u8, runtime.envOnce("KLIO_INIT_SELF") orelse "1", "0"))
                expr_mod.init_self_name = p.segments[0].name;
            defer expr_mod.init_self_name = prev_self;
            if (argDeclTypeRefLazy(b, init)) |inferred| return inferred;
            // Depth-guarded: an elvis or member-call initializer needs the full
            // derivation the lazy reader lacks.
            if (expr_mod.od_depth < 3) {
                expr_mod.od_depth += 1;
                defer expr_mod.od_depth -= 1;
                if (staticExprTypeRef(b, init) catch null) |derived| return derived;
            }
        }
    }
    return null;
}


/// A bare class name used as a value is its companion object.
fn bareClassValueTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    const nm = p.segments[0].name;
    if (b.resolve(nm) == null and !b.knowsOuter(nm) and b.module.classId(nm) != null) {
        return .{ .name = nm, .nullable = false, .args = &.{} };
    }
    return null;
}


/// A top-level property read carries its declared type head, picked by the
/// same scoping walk a bare call ranks by.
fn topLevelPropertyTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) ?ir.TypeRef {
    const nm = p.segments[0].name;
    if (b.resolve(nm) == null and !b.knowsOuter(nm) and !enclosingHasMemberNamed(b, nm)) {
        const file = p.segments[0].span.file;
        const pkg = b.module.packageOfFile(file) orelse b.self_package;
        if (b.module.topLevelPropTypeRef(nm, pkg, file)) |full| return full;
        if (b.module.topLevelPropTypeHead(nm, pkg, file)) |head| {
            return .{ .name = head, .nullable = false, .args = &.{} };
        }
    }
    return null;
}


/// Locals whose initializer the walk is inside, so it refuses to re-enter one.
threadlocal var init_chain: [16][]const u8 = @splat(&.{});
pub threadlocal var init_chain_len: usize = 0;

pub fn pushInitChain(name: []const u8) bool {
    if (init_chain_len == init_chain.len) return false;
    for (init_chain[0..init_chain_len]) |seen| {
        if (std.mem.eql(u8, seen, name)) return false;
    }
    init_chain[init_chain_len] = name;
    init_chain_len += 1;
    return true;
}

pub fn popInitChain() void {
    init_chain_len -= 1;
}

/// The declared slot `name` occupies in `cid`'s published layout, when serving
/// that slot is the whole of the read.
///
/// Four conditions, each one a way the slot's value is NOT the answer:
///
///   - the class has no published layout, or the name is not one of its slots;
///   - the name has more than one cell, because a class in the chain privately
///     shadows or override-cells it, and the read takes the nearest owner's;
///   - the slot is not a plain stored property — a getter's backing slot
///     exists, and reading it must run the getter;
///   - the slot is a body property, whose value arrives when its initializer
///     runs: a read that lands before that is answered by the ladder running
///     the initializer, where the claim would serve the seed;
///   - the owner is open, abstract or an interface, so a subclass may override
///     the property with an accessor and the receiver be that subclass.
///
/// A capture is never claimed: only a declared slot's index is the same in a
/// class and in every subclass.
pub fn fieldSlotClaim(b: *const FuncBuilder, cid: ir.ClassId, name: []const u8) ?u32 {
    const r = fieldSlotClaimWhy(b, cid, name);
    audit_mod.noSlotNote(r.why);
    return r.idx;
}

pub const SlotClaim = struct { idx: ?u32, why: audit_mod.WhyNoSlot };

/// `KLIO_OPEN_SLOT=0`: refuse every open, abstract or interface receiver a
/// field slot, as lowering did before the subclass question was asked.
threadlocal var open_slot_state: u8 = 0;
fn openSlotClaimEnabled() bool {
    if (open_slot_state == 0) {
        const v = runtime.envOnce("KLIO_OPEN_SLOT") orelse "1";
        open_slot_state = if (std.mem.eql(u8, v, "0")) 1 else 2;
    }
    return open_slot_state == 2;
}

/// `KLIO_SLOT_BODY=0` puts a class's own body properties back on the by-name
/// read. On: with the inherited ones excluded, `KLIO_SLOT_SERVE=audit` reads
/// zero divergences over both the example corpus and the stdlib tests, and the
/// share of field reads that claim a slot goes from 25.11% to 51.37%.
/// Which of the three reasons a layout holds no slot of that name. The bucket
/// is a third of all field reads, and the three want different work: naming the
/// getter, accepting that a host class has no layout, and finding out why the
/// deriver named a class that does not declare the name at all.
fn whyNoSuchSlot(b: *const FuncBuilder, cid: ir.ClassId, name: []const u8) audit_mod.WhyNoSlot {
    const c = &b.module.classes.items[cid.int()];
    if (c.is_intrinsic_backed) return .host_backed;
    const key = if (c.name.len != 0) c.name else c.fqn;
    if (b.module.registry.hierarchy_shadow_names.get(key)) |h| {
        if (h.names.contains(name)) return .accessor_or_method;
    }
    return .name_absent;
}

fn bodySlotClaimEnabled() bool {
    return !std.mem.eql(u8, runtime.envOnce("KLIO_SLOT_BODY") orelse "1", "0");
}

fn inheritedBodySlotEnabled() bool {
    return !std.mem.eql(u8, runtime.envOnce("KLIO_INHERITED_BODY_SLOT") orelse "1", "0");
}

/// The claim and the condition that decided it. One statement of the rules, so
/// the census cannot drift from what the claim actually does.
pub fn fieldSlotClaimWhy(b: *const FuncBuilder, cid: ir.ClassId, name: []const u8) SlotClaim {
    if (cid.int() >= b.module.classes.items.len) return .{ .idx = null, .why = .no_class };
    const layout = b.module.classFieldLayout(cid) orelse return .{
        .idx = null,
        // Four different problems wore one name. An interface holds no
        // storage and never will; an object expression's fields are built in
        // another order; `unavailable` means the build looked and could not
        // describe the class; `unpublished` means nothing has written a
        // layout yet, which is an ordering question, not a representation one.
        .why = switch (b.module.classFieldLayoutState(cid) orelse .unpublished) {
            .interface => .no_layout_interface,
            .anonymous => .no_layout_object,
            .local_runtime => .no_layout_local,
            .unavailable => .no_layout_unavailable,
            .unpublished => .no_layout_unpublished,
            .ok => .no_layout,
        },
    };
    const idx = b.module.fieldSlotIndex(cid, name) orelse
        return .{ .idx = null, .why = whyNoSuchSlot(b, cid, name) };
    if (idx >= layout.declared) return .{ .idx = null, .why = .capture_slot };
    if (cellsForProperty(layout.slots[0..layout.declared], name) != 1)
        return .{ .idx = null, .why = .many_cells };
    if (!layout.slots[idx].plain) return .{ .idx = null, .why = .not_plain };
    // A body property's slot holds its seed until the initializer runs, and a
    // read that lands first is answered by the ladder running the initializer
    // — where the claim would serve the seed.
    if (!layout.slots[idx].ctor and !bodySlotClaimEnabled())
        return .{ .idx = null, .why = .body_property };
    const oc = &b.module.classes.items[cid.int()];
    // Being subclassable is not on its own a reason to refuse. The layout is
    // base-prefixed by construction — `own[i]` sits at `base + i`, and a
    // claimed index is always inside the declared region, never among the
    // trailing captures — so a subclass instance holds this class's cell at
    // this class's index. What would break the read is a subclass ANSWERING
    // the name differently: an `override val` with its own cell, or one
    // replaced by an accessor. The build records every (ancestor, member)
    // pair a subclass declares, so that is a question with a whole-program
    // answer rather than a reason to give up on every open class.
    //
    // `KLIO_OPEN_SLOT=0` withdraws the claim, leaving the refusal as it was.
    if (oc.is_open or oc.is_abstract or oc.is_interface) {
        if (!openSlotClaimEnabled() or b.module.subclassDeclaresProp(oc.name, name))
            return .{ .idx = null, .why = .subclassable };
    }
    // Nearest declaration wins, and the layout does not record which class
    // that is. An INHERITED constructor cell is still the base's, so a
    // subclass that replaces the property with an accessor answers from the
    // accessor while the cell holds the base's value: `Counted : Tagged(…)`
    // overrides `Tagged`'s constructor `label` with `get() = "counted:$n"`
    // and read the constructor's `"counted"` instead.
    if (nearestDeclaresGetter(b, cid, name)) return .{ .idx = null, .why = .accessor_or_method };
    // An INHERITED body slot was refused outright because a class between the
    // declarer and this one can replace the property with an accessor and
    // contribute no cell — `Square` overriding `Shape`'s stored `sides` with
    // `get() = 4` reads the inherited 0 — which is the divergence the
    // dual-compute audit found when body properties first claimed. But that is
    // the question `nearestDeclaresGetter` just answered: it walks from THIS
    // class up and stops at the first declaration, so an intervening accessor
    // has already refused above, and a second cell has already been refused by
    // the cell count. `KLIO_INHERITED_BODY_SLOT=0` restores the refusal.
    if (!layout.slots[idx].ctor and idx < layout.base and !inheritedBodySlotEnabled())
        return .{ .idx = null, .why = .body_property };
    // A class that delegates a supertype, or extends a builtin collection,
    // forwards reads to the delegate cell rather than answering from its own
    // slots: `size` on an `ArrayList` subclass is the delegate's size.
    if (layoutHasDelegate(layout.slots)) return .{ .idx = null, .why = .has_delegate };
    return .{ .idx = idx, .why = .claimed };
}

/// Whether the class nearest `cid` in the chain that DECLARES `name` answers
/// it with an accessor. Kotlin resolves a property to the nearest declaration,
/// so that one decides whether a cell or a call answers, whichever class the
/// cell belongs to.
fn nearestDeclaresGetter(b: *const FuncBuilder, cid: ir.ClassId, name: []const u8) bool {
    var cur: ?ir.ClassId = cid;
    var hops: usize = 0;
    while (cur) |c| : (hops += 1) {
        if (hops > 32 or c.int() >= b.module.classes.items.len) return false;
        const cls = &b.module.classes.items[c.int()];
        for (cls.declared_props) |prop| {
            if (!std.mem.eql(u8, prop.name, name)) continue;
            return prop.has_getter;
        }
        cur = if (cls.supertypes.len != 0) cls.supertypes[0] else null;
    }
    return false;
}

/// Whether the layout holds a delegate cell — a `by`-delegated supertype or a
/// builtin-collection base. Both are spelled `__delegate__<name>`.
fn layoutHasDelegate(slots: []const ir.FieldSlot) bool {
    for (slots) |sl| {
        if (std.mem.startsWith(u8, sl.name, "__delegate__")) return true;
    }
    return false;
}

/// How many slots hold the property `name`: its plain cell, plus one
/// owner-mangled cell per class in the chain that shadows or override-cells it.
/// `shadowFieldKey` spells a mangled cell `<owner>\u{1f}<prop>`.
fn cellsForProperty(slots: []const ir.FieldSlot, name: []const u8) usize {
    var n: usize = 0;
    for (slots) |sl| {
        if (std.mem.eql(u8, sl.name, name)) {
            n += 1;
            continue;
        }
        if (sl.name.len > name.len + 1 and
            sl.name[sl.name.len - name.len - 1] == '\x1f' and
            std.mem.eql(u8, sl.name[sl.name.len - name.len ..], name)) n += 1;
    }
    return n;
}

pub fn staticTypeClassId(b: *const FuncBuilder, ty: ir.TypeRef) ?ir.ClassId {
    var identity = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    return if (std.mem.findScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(identity));
}

pub fn ownedClassSelfType(
    allocator: Allocator,
    class: *const ir.Class,
) Allocator.Error!ir.TypeRef {
    const args = try allocator.alloc(ir.TypeRef, class.type_params.len);
    errdefer allocator.free(args);
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |*arg| arg.deinit(allocator);
    }
    for (class.type_params, args) |param, *arg| {
        arg.* = .{
            .name = try ir.classTypeParamIdentity(allocator, class.id, param),
            .nullable = false,
            .args = try allocator.alloc(ir.TypeRef, 0),
        };
        initialized += 1;
    }
    return .{
        .name = try allocator.dupe(u8, class.fqn),
        .nullable = false,
        .args = args,
    };
}

pub fn staticDispatchReceiverTypeRef(
    b: *FuncBuilder,
    target: FuncId,
    call_receiver: ?ir.TypeRef,
    caller_file: ir.FileId,
) Allocator.Error!?ir.TypeRef {
    const sig = b.module.decl_sigs.get(target.int()) orelse return null;
    const owner = sig.enclosing_class orelse return null;
    if (owner.int() >= b.module.classes.items.len) return null;
    if (sig.kind == .instance_method) {
        const receiver = call_receiver orelse return null;
        return try receiver.clone(b.allocator);
    }
    if (sig.kind != .member_extension) return null;

    const owner_class = &b.module.classes.items[owner.int()];
    if (b.recvTypeRef()) |receiver| {
        if (staticTypeClassId(b, receiver)) |receiver_id| {
            if (receiver_id.int() >= b.module.classes.items.len) return null;
            const receiver_class = &b.module.classes.items[receiver_id.int()];
            if (b.module.classIsOrExtends(receiver_class.fqn, owner_class.fqn)) {
                return try receiver.clone(b.allocator);
            }
        }
    }
    const lexical = b.ownerClass() orelse return null;
    const lexical_id = if (std.mem.findScalar(u8, lexical, '.') != null)
        b.module.classIdByFqn(lexical)
    else
        b.module.classIdIndexed(lexical, b.self_package, caller_file);
    const id = lexical_id orelse return null;
    if (id.int() >= b.module.classes.items.len) return null;
    const lexical_class = &b.module.classes.items[id.int()];
    if (!b.module.classIsOrExtends(lexical_class.fqn, owner_class.fqn)) return null;
    return try ownedClassSelfType(b.allocator, lexical_class);
}

/// A constructor call names its own type, so no return derivation is needed.
pub fn ctorInitTypeRef(b: *FuncBuilder, init_expr: *const Expr) Allocator.Error!?ir.TypeRef {
    if (init_expr.* != .Call) return null;
    const call = init_expr.Call;
    if (try nestedCtorInitTypeRef(b, call)) |t| return t;
    if (call.callee.* != .Path or call.callee.Path.segments.len != 1) return null;
    const ident = call.callee.Path.segments[0];
    const citr_trace = if (runtime.envOnce("KLIO_CITR_TRACE")) |w| std.mem.eql(u8, w, ident.name) else false;
    if (citr_trace) std.debug.print("[citr] {s} enter\n", .{ident.name});

    // A local class registers only at runtime, with its captures, so no
    // lowering-time row exists and the module index would answer an unrelated
    // same-named class. The typing record's mangled head proves extension
    // applicability; the runtime binding stays the ctor.
    if (build.isLocalClassInScope(ident.name)) {
        var lc_buf: [160]u8 = undefined;
        if (std.fmt.bufPrint(&lc_buf, "{s}$lc{s}", .{ ident.name, build.currentRealFn() orelse "" }) catch null) |key| {
            if (b.module.registry.class_super_names.get(key) != null) {
                if (citr_trace) std.debug.print("[citr] {s} local-class head {s}\n", .{ ident.name, key });
                return .{ .name = try b.allocator.dupe(u8, key), .nullable = false, .args = &.{} };
            }
        }
    }
    if (b.resolve(ident.name) != null or b.knowsOuter(ident.name)) {
        if (citr_trace) std.debug.print("[citr] {s} bail=local_or_outer\n", .{ident.name});
        return null;
    }
    if (b.module.funcId(ident.name) != null) {
        if (citr_trace) std.debug.print("[citr] {s} bail=func_namesake\n", .{ident.name});
        return null;
    }
    // A collision-mangled internal class is absent from the simple-name index: a
    // same-package reference reaches it through the scope rename ladder, a
    // cross-package one through its exact import. Inside a splice's argument
    // binding the callee frame is pushed, so renaming uses the caller's owner.
    const ref_name = scopeTypeRenameFrom(b, inline_call.spliceLexicalOwner() orelse b.ownerClass(), ident.name, ident.span.file.int()) orelse ident.name;
    const cid = b.module.classIdIndexed(ref_name, b.self_package, ident.span.file) orelse
        b.module.classIdExactImport(ident.name, ident.span.file) orelse {
        if (citr_trace) std.debug.print("[citr] {s} bail=no_class ref_name={s}\n", .{ ident.name, ref_name });
        return null;
    };
    // A member of the enclosing receiver shadows the constructor, as the emission
    // router decides it.
    if (enclosingHasMemberNamed(b, ident.name) and !classNestedInEnclosing(b, cid)) {
        if (citr_trace) std.debug.print("[citr] {s} bail=enclosing_member_shadow owner={s}\n", .{ ident.name, b.ownerClass() orelse "-" });
        return null;
    }
    if (cid.int() >= b.module.classes.items.len) return null;
    const class = &b.module.classes.items[cid.int()];
    // A positionally constructed stub generic lists no primary parameters, so each
    // type argument binds from the argument at its position.
    if (citr_trace) std.debug.print("[citr] {s} class={s} stub={} tps={d} pps={d} nargs={d}\n", .{ ident.name, class.fqn, class.is_stub, class.type_params.len, class.primary_params.len, call.args.len });
    if (try arrayCtorElementTypeRef(b, call, class, citr_trace)) |t| return t;
    if (try stubCtorTypeRef(b, call, class)) |t| return t;

    // An object is not constructed, and a stub or value class has no instance
    // identity for a member call to bind against.
    if (class.is_object or class.is_stub or class.is_value) return null;
    var args = try b.allocator.alloc(ir.TypeRef, call.type_args.len);
    errdefer b.allocator.free(args);
    for (call.type_args, args) |*ty, *out| {
        out.* = try decl_mod.loweredTypeRef(b.allocator, ty, true);
    }
    // With no explicit `<...>` a generic class's arguments infer from the
    // constructor arguments: a param declared bare `E` takes its argument's own
    // type, one declared `X<..., E, ...>` its argument's type argument there.
    if (args.len == 0 and class.type_params.len != 0 and call.args.len != 0) infer: {
        const inferred = try b.allocator.alloc(ir.TypeRef, class.type_params.len);
        var got: usize = 0;
        var ok = true;
        defer if (!ok) {
            for (inferred[0..got]) |*t| t.deinit(b.allocator);
            b.allocator.free(inferred);
        };
        for (class.type_params) |tp| {
            var bound: ?ir.TypeRef = null;
            params: for (class.primary_params, 0..) |*p, pi| {
                if (pi >= call.args.len) break;
                const pt = p.ty;
                if (std.mem.eql(u8, std.mem.trimEnd(u8, pt.name, "?"), tp)) {
                    bound = try staticExprTypeRef(b, &call.args[pi]);
                    break :params;
                }
                for (pt.args, 0..) |pa, ai| {
                    var an = std.mem.trimEnd(u8, pa.name, "?");
                    if (std.mem.startsWith(u8, an, "in#")) an = an[3..];
                    if (std.mem.startsWith(u8, an, "out#")) an = an[4..];
                    if (!std.mem.eql(u8, an, tp)) continue;
                    var at = (try staticExprTypeRef(b, &call.args[pi])) orelse continue :params;
                    defer at.deinit(b.allocator);
                    if (at.args.len == pt.args.len and ai < at.args.len) {
                        bound = try at.args[ai].clone(b.allocator);
                    }
                    break :params;
                }
            }
            var bt = bound orelse {
                ok = false;
                break :infer;
            };
            var bh = std.mem.trimEnd(u8, bt.name, "?");
            if (std.mem.findScalar(u8, bh, '<')) |lt| bh = bh[0..lt];
            const bare_tp = (bh.len > 0 and bh.len <= 2 and std.ascii.isUpper(bh[0])) or
                b.isTypeParam(bh) or ir.parseClassTypeParamIdentity(bh) != null;
            if (bh.len == 0 or bare_tp) {
                bt.deinit(b.allocator);
                ok = false;
                break :infer;
            }
            inferred[got] = bt;
            got += 1;
        }
        b.allocator.free(args);
        args = inferred;
    }
    var derived = ir.TypeRef{
        .name = try b.allocator.dupe(u8, class.fqn),
        .nullable = false,
        .args = args,
    };
    if (!staticClassifierArgsComplete(b, derived)) {
        if (citr_trace) std.debug.print("[citr] {s} bail=args_incomplete\n", .{ident.name});
        derived.deinit(b.allocator);
        return null;
    }
    return derived;
}

/// A nested class constructed through its own enclosing class name; the bare
/// form resolves through the lexical nested-class walk, the qualified one
/// reached no class at all.
fn nestedCtorInitTypeRef(b: *FuncBuilder, call: @FieldType(Expr, "Call")) Allocator.Error!?ir.TypeRef {

    if (call.callee.* == .Member and call.callee.Member.receiver.* == .Path and
        call.callee.Member.receiver.Path.segments.len == 1)
    {
        const outer_name = call.callee.Member.receiver.Path.segments[0].name;
        const inner_name = call.callee.Member.name.name;
        if (outer_name.len != 0 and std.ascii.isUpper(outer_name[0]) and
            inner_name.len != 0 and std.ascii.isUpper(inner_name[0]) and
            b.resolve(outer_name) == null and !b.knowsOuter(outer_name))
        {
            var qb: [128]u8 = undefined;
            if (std.fmt.bufPrint(&qb, "{s}.{s}", .{ outer_name, inner_name }) catch null) |qualified| {
                if (runtime.envOnce("KLIO_CITR_TRACE")) |w| {
                    if (std.mem.eql(u8, w, inner_name)) {
                        const c_opt = b.module.classIdByQualifiedSuffix(qualified);
                        if (c_opt) |c| {
                            const cc = &b.module.classes.items[c.int()];
                            std.debug.print("[citr] dotted {s} -> cid={d} name={s} object={} stub={} value={} abstract={}\n", .{ qualified, c.int(), cc.name, cc.is_object, cc.is_stub, cc.is_value, cc.is_abstract });
                        } else std.debug.print("[citr] dotted {s} -> none\n", .{qualified});
                    }
                }
                if (b.module.classIdByQualifiedSuffix(qualified)) |ncid| {
                    if (ncid.int() < b.module.classes.items.len) {
                        const ncls = &b.module.classes.items[ncid.int()];
                        // A class whose bodies have not lowered is still a header
                        // row; the constructed type is its name.
                        if (!ncls.is_object and !ncls.is_value and !ncls.is_abstract) {
                            return ir.TypeRef{
                                .name = try b.allocator.dupe(u8, ncls.name),
                                .nullable = false,
                                .args = &.{},
                            };
                        }
                    }
                }
            }
        }
    }
    return null;
}

/// `Array(size) { init }`: the element type is the lambda's tail expression.
fn arrayCtorElementTypeRef(
    b: *FuncBuilder,
    call: @FieldType(Expr, "Call"),
    class: *const ir.Class,
    citr_trace: bool,
) Allocator.Error!?ir.TypeRef {

    if (std.mem.eql(u8, class.fqn, "kotlin.Array") and call.type_args.len == 0 and call.args.len == 2 and
        call.args[1] == .Lambda and call.args[1].Lambda.body.stmts.len != 0)
    {
        const stmts = call.args[1].Lambda.body.stmts;
        const tail = &stmts[stmts.len - 1];
        if (citr_trace) std.debug.print("[citr] Array tail={s}\n", .{@tagName(std.meta.activeTag(tail.*))});
        if (tail.* == .Expr) {
            if (citr_trace) std.debug.print("[citr] Array elem={?s}\n", .{if (try staticExprTypeRef(b, &tail.Expr)) |e| e.name else null});
            if (try staticExprTypeRef(b, &tail.Expr)) |elem| {
                var eh = std.mem.trimEnd(u8, elem.name, "?");
                if (std.mem.findScalar(u8, eh, '<')) |lt| eh = eh[0..lt];
                const bare_tp = (eh.len > 0 and eh.len <= 2 and std.ascii.isUpper(eh[0])) or
                    b.isTypeParam(eh) or ir.parseClassTypeParamIdentity(eh) != null;
                if (eh.len != 0 and !bare_tp) {
                    const args1 = try b.allocator.alloc(ir.TypeRef, 1);
                    args1[0] = elem;
                    return ir.TypeRef{ .name = try b.allocator.dupe(u8, class.fqn), .nullable = false, .args = args1 };
                }
                var e2 = elem;
                e2.deinit(b.allocator);
            }
        }
    }
    return null;
}

/// A positionally constructed stub generic lists no primary parameters, so each
/// type argument binds from the argument at its position.
fn stubCtorTypeRef(
    b: *FuncBuilder,
    call: @FieldType(Expr, "Call"),
    class: *const ir.Class,
) Allocator.Error!?ir.TypeRef {

    if (class.is_stub and !class.is_object and !class.is_value and call.type_args.len == 0 and
        class.type_params.len != 0 and class.primary_params.len == 0 and call.args.len == class.type_params.len)
    {
        const inferred = try b.allocator.alloc(ir.TypeRef, class.type_params.len);
        var got: usize = 0;
        var ok = true;
        defer if (!ok) {
            for (inferred[0..got]) |*t| t.deinit(b.allocator);
            b.allocator.free(inferred);
        };
        for (call.args, 0..) |*a, ai| {
            var bt = (try staticExprTypeRef(b, a)) orelse {
                ok = false;
                break;
            };
            var bh = std.mem.trimEnd(u8, bt.name, "?");
            if (std.mem.findScalar(u8, bh, '<')) |lt| bh = bh[0..lt];
            const bare_tp = (bh.len > 0 and bh.len <= 2 and std.ascii.isUpper(bh[0])) or
                b.isTypeParam(bh) or ir.parseClassTypeParamIdentity(bh) != null;
            if (bh.len == 0 or bare_tp) {
                bt.deinit(b.allocator);
                ok = false;
                break;
            }
            inferred[ai] = bt;
            got += 1;
        }
        if (ok) {
            var derived = ir.TypeRef{
                .name = try b.allocator.dupe(u8, class.fqn),
                .nullable = false,
                .args = inferred,
            };
            if (!staticClassifierArgsComplete(b, derived)) {
                derived.deinit(b.allocator);
                return null;
            }
            return derived;
        }
        return null;
    }
    return null;
}


/// The element type a `for (x in xs)` binds `x` to: the sole type argument of the
/// iterable's declared type. Conservative on purpose, since committing to a bare
/// type parameter would disprove candidates a null type leaves open.
pub fn iterableElementTypeRef(b: *FuncBuilder, iter: *const Expr) Allocator.Error!?ir.TypeRef {
    var owned: ?ir.TypeRef = null;
    defer if (owned) |*t| t.deinit(b.allocator);
    var ty: ir.TypeRef = blk: {
        if (argDeclTypeRef(b, iter)) |known| break :blk known;
        // The lazy channel serves `this`, the window's full receiver. Borrowed.
        if (argDeclTypeRefLazy(b, iter)) |lazy_known| break :blk lazy_known;
        owned = (try staticCallReturnTypeRef(b, iter)) orelse
            (try staticExprTypeRef(b, iter)) orelse return null;
        break :blk owned.?;
    };
    // A type-parameter head resolves through its bound: `T : Iterable<String>`
    // binds String elements.
    {
        var h0 = std.mem.trimEnd(u8, ty.name, "?");
        if (std.mem.findScalar(u8, h0, '<')) |lt| h0 = h0[0..lt];
        if (ty.args.len == 0) {
            if (b.typeParamBoundRef(typeHead(h0))) |bref| ty = bref.*;
        }
    }
    // Char sequences iterate Chars by their iterator, not by a type argument.
    {
        var h = std.mem.trimEnd(u8, ty.name, "?");
        if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
        h = typeHead(h);
        if (std.mem.eql(u8, h, "CharSequence") or std.mem.eql(u8, h, "String") or
            std.mem.eql(u8, h, "StringBuilder"))
        {
            return try (ir.TypeRef{
                .name = "Char",
                .nullable = false,
                .args = &.{},
            }).clone(b.allocator);
        }
        const prim_arrays = [_]struct { a: []const u8, e: []const u8 }{
            .{ .a = "BooleanArray", .e = "Boolean" }, .{ .a = "ByteArray", .e = "Byte" },
            .{ .a = "ShortArray", .e = "Short" },     .{ .a = "IntArray", .e = "Int" },
            .{ .a = "LongArray", .e = "Long" },       .{ .a = "CharArray", .e = "Char" },
            .{ .a = "FloatArray", .e = "Float" },     .{ .a = "DoubleArray", .e = "Double" },
            .{ .a = "UByteArray", .e = "UByte" },     .{ .a = "UShortArray", .e = "UShort" },
            .{ .a = "UIntArray", .e = "UInt" },       .{ .a = "ULongArray", .e = "ULong" },
        };
        for (prim_arrays) |pa| {
            if (std.mem.eql(u8, h, pa.a)) {
                return try (ir.TypeRef{
                    .name = pa.e,
                    .nullable = false,
                    .args = &.{},
                }).clone(b.allocator);
            }
        }
    // Ranges and progressions carry their element in the class name, so the
    // single-argument path below cannot reach them.
        const progressions = [_]struct { p: []const u8, e: []const u8 }{
            .{ .p = "IntRange", .e = "Int" },               .{ .p = "LongRange", .e = "Long" },
            .{ .p = "CharRange", .e = "Char" },             .{ .p = "UIntRange", .e = "UInt" },
            .{ .p = "ULongRange", .e = "ULong" },           .{ .p = "IntProgression", .e = "Int" },
            .{ .p = "LongProgression", .e = "Long" },       .{ .p = "CharProgression", .e = "Char" },
            .{ .p = "UIntProgression", .e = "UInt" },       .{ .p = "ULongProgression", .e = "ULong" },
        };
        for (progressions) |pr| {
            if (std.mem.eql(u8, h, pr.p)) {
                return try (ir.TypeRef{
                    .name = pr.e,
                    .nullable = false,
                    .args = &.{},
                }).clone(b.allocator);
            }
        }
    }
    if (ty.args.len != 1) return null;
    var elem = ty.args[0].name;
    // Declaration-site variance is spelling, not structure: the element of
    // `Array<out Array<out T>>` is the inner Array.
    if (std.mem.startsWith(u8, elem, "in#")) elem = elem[3..];
    if (std.mem.startsWith(u8, elem, "out#")) elem = elem[4..];
    if (elem.len == 0) return null;
    // A star projection's element is `Any?`, its own upper bound.
    if (std.mem.eql(u8, elem, "*")) {
        return try (ir.TypeRef{ .name = "Any", .nullable = true, .args = &.{} }).clone(b.allocator);
    }
    if (ty.args[0].nullable) return null;
    // A bare type-parameter element is carried when the scope records a bound: a
    // generic body lowers once with no call site, and the declared upper bound is
    // what Kotlin resolves against.
    if (elem.len <= 2 and std.ascii.isUpper(elem[0])) {
        if (b.typeParamBound(elem) == null) return null;
        return try cloneElemStripped(b, &ty.args[0], elem);
    }
    var head = elem;
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (b.module.classIdByFqn(head) == null and
        b.module.uniqueClassIdBySimpleName(typeHead(head)) == null) return null;
    return try cloneElemStripped(b, &ty.args[0], elem);
}

/// Clone the element type with the variance mangle stripped; consumers key by it.
fn cloneElemStripped(b: *FuncBuilder, arg: *const ir.TypeRef, stripped: []const u8) Allocator.Error!ir.TypeRef {
    var out = try arg.clone(b.allocator);
    if (!std.mem.eql(u8, out.name, stripped)) {
        const owned = try b.allocator.dupe(u8, stripped);
        b.allocator.free(out.name);
        out.name = owned;
    }
    return out;
}

pub fn iterableElementTypeName(b: *FuncBuilder, iter: *const Expr) Allocator.Error!?[]const u8 {
    var elem = (try iterableElementTypeRef(b, iter)) orelse return null;
    defer elem.deinit(b.allocator);
    return try b.allocator.dupe(u8, elem.name);
}

/// Memo for one outermost type query, so a chain of infix calls types each
/// subexpression once. It lives only for that query: builder state cannot change
/// while it runs, and the stamp below drops the memo if it does.
const TyMemo = struct {
    map: std.AutoHashMapUnmanaged(u64, ?ir.TypeRef) = .{},
    /// Lazy answers are borrowed slices, so this map never frees what it holds.
    lazy: std.AutoHashMapUnmanaged(u64, ?ir.TypeRef) = .{},
    owner: ?*FuncBuilder = null,
    stamp: u64 = 0,
    depth: u32 = 0,
};
threadlocal var ty_memo: TyMemo = .{};

/// The memo outlives any one function build, so its storage is the process
/// heap: what a query's clear frees goes back to it and its pages return to
/// the OS, where a free-list allocator kept every thread's peak mapped.
fn memoAlloc() std.mem.Allocator {
    return runtime.slab.allocator;
}

fn tyMemoOn() bool {
    // `KLIO_TY_MEMO=0` disables the static-type memo (bisect aid).
    return !std.mem.eql(u8, runtime.envOnce("KLIO_TY_MEMO") orelse "1", "0");
}

pub const TyMemoHit = struct { ty: ?ir.TypeRef };

fn tyMemoStamp(b: *const FuncBuilder) u64 {
    var h: u64 = if (b.caller_member_scope) |ms| @intFromPtr(ms) else 8;
    h = h *% 31 +% b.inline_stack_visible_base;
    h = h *% 31 +% b.inline_lambda_subst.items.len;
    h = h *% 31 +% b.splice_hidden_bands.items.len;
    h = h *% 31 +% b.local_decl_types.count();
    if (b.lambda_splice_resolve) |ls| h = h *% 31 +% ls.caller_depth *% 7 +% ls.own_base;
    return h;
}

fn tyMemoKey(e: *const Expr, tag: u1) u64 {
    return (@as(u64, @intFromPtr(e)) << 1) | tag;
}

fn tyMemoGet(b: *FuncBuilder, e: *const Expr, tag: u1) ?TyMemoHit {
    if (ty_memo.depth == 0 or ty_memo.owner != b) return null;
    const hit = ty_memo.map.get(tyMemoKey(e, tag)) orelse return null;
    const cloned: ?ir.TypeRef = if (hit) |t| (t.clone(b.allocator) catch return null) else null;
    return .{ .ty = cloned };
}

pub fn tyMemoEnter(b: *FuncBuilder) bool {
    if (!tyMemoOn()) return false;
    if (ty_memo.depth == 0) {
        ty_memo.owner = b;
        ty_memo.stamp = tyMemoStamp(b);
        ty_memo.depth = 1;
        return true;
    }
    ty_memo.depth += 1;
    return false;
}

fn tyMemoLeave(b: *FuncBuilder, owns: bool, e: *const Expr, tag: u1, r: ?ir.TypeRef) void {
    if (!tyMemoOn()) return;
    ty_memo.depth -= 1;
    if (owns) {
        tyMemoClear();
        return;
    }
    if (ty_memo.owner != b or ty_memo.stamp != tyMemoStamp(b)) return;
    const stored: ?ir.TypeRef = if (r) |t| (t.clone(memoAlloc()) catch return) else null;
    ty_memo.map.put(memoAlloc(), tyMemoKey(e, tag), stored) catch {
        if (stored) |t| @constCast(&t).deinit(memoAlloc());
    };
}

fn tyMemoClear() void {
    var it = ty_memo.map.iterator();
    while (it.next()) |ent| if (ent.value_ptr.*) |*t| t.deinit(memoAlloc());
    ty_memo.map.clearRetainingCapacity();
    ty_memo.lazy.clearRetainingCapacity();
    ty_memo.owner = null;
}

pub fn lazyMemoGet(b: *FuncBuilder, e: *const Expr) ?TyMemoHit {
    if (ty_memo.depth == 0 or ty_memo.owner != b) return null;
    const hit = ty_memo.lazy.get(@intFromPtr(e)) orelse return null;
    return .{ .ty = hit };
}

pub fn lazyMemoLeave(b: *FuncBuilder, owns: bool, e: *const Expr, r: ?ir.TypeRef) void {
    if (!tyMemoOn()) return;
    if (!owns and ty_memo.owner == b and ty_memo.stamp == tyMemoStamp(b)) {
        ty_memo.lazy.put(memoAlloc(), @intFromPtr(e), r) catch {};
    }
    ty_memo.depth -= 1;
    if (owns) tyMemoClear();
}

pub fn staticExprTypeRef(b: *FuncBuilder, e: *const Expr) Allocator.Error!?ir.TypeRef {
    if (tyMemoGet(b, e, 0)) |hit| return hit.ty;
    const owns = tyMemoEnter(b);
    const r = try staticExprTypeRefUncached(b, e);
    tyMemoLeave(b, owns, e, 0, r);
    return r;
}

/// Memo entry point for the call-return deriver, re-entered on the same subexpression.
pub fn tyMemoCall(b: *FuncBuilder, e: *const Expr) ?TyMemoHit {
    return tyMemoGet(b, e, 1);
}
pub fn tyMemoCallEnter(b: *FuncBuilder) bool {
    return tyMemoEnter(b);
}
pub fn tyMemoCallLeave(b: *FuncBuilder, owns: bool, e: *const Expr, r: ?ir.TypeRef) void {
    tyMemoLeave(b, owns, e, 1, r);
}

/// A statically known type for an arbitrary expression, the full deriver: the
/// declared channel first, then a constructed class, a resolved call's return,
/// the shapes that name their own type, and finally a local's initializer.
fn staticExprTypeRefUncached(b: *FuncBuilder, e: *const Expr) Allocator.Error!?ir.TypeRef {

    // Literals name their own type, including across a capture boundary.
    switch (e.*) {
        .IntLit => |lit| return .{ .name = try b.allocator.dupe(u8, switch (lit.kind) {
            .Long => "Long",
            .UInt => "UInt",
            .ULong => "ULong",
            .Int => if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32)) "Int" else "Long",
        }), .nullable = false, .args = &.{} },
        .FloatLit => |lit| return .{ .name = try b.allocator.dupe(u8, if (lit.kind == .Float) "Float" else "Double"), .nullable = false, .args = &.{} },
        .BoolLit => return .{ .name = try b.allocator.dupe(u8, "Boolean"), .nullable = false, .args = &.{} },
        .CharLit => return .{ .name = try b.allocator.dupe(u8, "Char"), .nullable = false, .args = &.{} },
        .StringTemplate => return .{ .name = try b.allocator.dupe(u8, "String"), .nullable = false, .args = &.{} },
        else => {},
    }
    if (argDeclTypeRef(b, e)) |known| {
        // A bare type-parameter answer substitutes the receiver's instantiation.
        const kh = typeHead(std.mem.trimEnd(u8, known.name, "?"));
        const bare_k = (kh.len > 0 and kh.len <= 2 and std.ascii.isUpper(kh[0])) or
            b.isTypeParam(kh) or ir.parseClassTypeParamIdentity(kh) != null;
        if (bare_k and e.* == .Path and e.Path.segments.len == 1) {
            const nm2 = e.Path.segments[0].name;
            if (runtime.envOnce("KLIO_IMPLPROP_TRACE")) |w| {
                if (std.mem.eql(u8, w, nm2))
                    std.debug.print("[implprop-bare] {s} known={s} rtref={} rt_args={d}\n", .{ nm2, known.name, b.recvTypeRef() != null, if (b.recvTypeRef()) |r| r.args.len else 0 });
            }
            if (b.recvTypeRef()) |rt| sub_head: {
                const rh = typeHead(std.mem.trimEnd(u8, rt.name, "?"));
                const declared: ir.TypeRef = propTypeRefOn(b, rh, nm2) orelse blk2: {
                    const head = b.module.registry.class_prop_type_heads.get(.{ .a = rh, .b = nm2 }) orelse break :sub_head;
                    break :blk2 .{ .name = head, .nullable = false, .args = &.{} };
                };
                const dh = typeHead(std.mem.trimEnd(u8, declared.name, "?"));
                // The declared type is the owner's parameter, mapped by position.
                if (bareTypeParamHead(dh) and declared.args.len == 0) {
                    const cid = (b.module.uniqueClassIdBySimpleName(rh) orelse
                        b.module.classIdByFqn(rh)) orelse break :sub_head;
                    if (cid.int() >= b.module.classes.items.len) break :sub_head;
                    const tps = b.module.classes.items[cid.int()].type_params;
                    if (tps.len != rt.args.len) break :sub_head;
                    for (tps, 0..) |tp, j| {
                        if (!std.mem.eql(u8, tp, dh)) continue;
                        const sub = rt.args[j];
                        const sh = typeHead(std.mem.trimEnd(u8, sub.name, "?"));
                        if (sh.len == 0 or std.mem.eql(u8, sh, "*") or
                            bareTypeParamHead(sh)) break :sub_head;
                        var out = try sub.clone(b.allocator);
                        out.nullable = out.nullable or declared.nullable;
                        return out;
                    }
                    break :sub_head;
                }
                if (substitutedPropType(b, rh, rt, declared)) |sub| {
                    return try sub.clone(b.allocator);
                }
            }
        }
        // A generic constructor call the eager typer answers head-only; the ctor
        // derivation instantiates the arguments a reified consumer needs.
        if (e.* == .Call and known.args.len == 0) {
            if (try ctorInitTypeRef(b, e)) |t| {
                if (t.args.len != 0) return t;
                var tt = t;
                tt.deinit(b.allocator);
            }
        }
        return try known.clone(b.allocator);
    }
    if (try ctorInitTypeRef(b, e)) |t| return t;
    if (try staticCallReturnTypeRef(b, e)) |t| return t;
    if (try elvisTypeRef(b, e)) |t| return t;
    if (try implicitReceiverPropTypeRef(b, e)) |t| return t;
    // Shapes that name their own type outright. A `settled` answer is the
    // deriver's; otherwise the initializer channel below runs.
    var settled = true;
    if (try selfNamedTypeRef(b, e, &settled)) |t| return t;
    if (settled) return null;
    return try localInitTypeRef(b, e);
}

/// A class property with no declared type, typed from its initializer.
///
/// Kotlin infers it and every read of it wants the answer, but the registry
/// records a head only where the initializer is a literal or a constructor
/// call. `private val _next = atomic<Any>(this)` is neither, so the property
/// has no recorded type at all and every `_next.compareAndSet(...)` on it
/// resolves by name — which is most of what the coroutine and atomicfu
/// internals do.
///
/// The initializer types in a scratch builder owned by the declaring class,
/// which is the scope the initializer itself has. The depth cap is for a
/// property whose initializer reads another inferred property.
threadlocal var prop_init_depth: u8 = 0;
fn inferredPropTypeRef(b: *FuncBuilder, owner: []const u8, name: []const u8) Allocator.Error!?ir.TypeRef {
    if (prop_init_depth >= 3) return null;
    const pa = inline_state.memberPropAst(owner, name) orelse return null;
    // A declared type is `propTypeRefOn`'s answer, and an extension property
    // belongs to its receiver rather than to this owner.
    if (pa.ty != null or pa.receiver_type != null) return null;
    const init = pa.init orelse return null;
    prop_init_depth += 1;
    defer prop_init_depth -= 1;
    var nb = try FuncBuilder.init(b.allocator, b.module);
    nb.markScratch();
    defer nb.deinit();
    nb.setOwnerClass(owner);
    nb.setRecvTy(owner);
    const out = try staticExprTypeRef(&nb, init);
    if (runtime.envOnce("KLIO_PROPTY_TRACE")) |w| {
        if (std.mem.eql(u8, w, "*") or std.mem.eql(u8, w, name)) {
            std.debug.print("[propty] {s}.{s} init={s} ty={s}\n", .{
                owner, name, @tagName(std.meta.activeTag(init.*)),
                if (out) |t| t.name else "-",
            });
        }
    }
    return out;
}

/// The declared type of `name` read on `owner`, else the one its initializer
/// infers.
fn propTypeRefOrInferred(b: *FuncBuilder, owner: []const u8, name: []const u8) Allocator.Error!?ir.TypeRef {
    if (propTypeRefOn(b, owner, name)) |t| return try t.clone(b.allocator);
    return try inferredPropTypeRef(b, owner, name);
}

/// A bare name none of the channels above could type, read off an implicit
/// receiver: `count.inc()` inside a method of the class that declares
/// `val count: Counter`. The name is not a local, a parameter or a capture,
/// and it is not a call — but a receiver in scope declares it, and so names
/// its type.
///
/// Innermost first, which is Kotlin's own order: a lambda receiver that
/// declares the name shadows the enclosing class's property. The walk stops
/// at the owner rather than climbing to its outer, because a nested class
/// cannot see the outer's instance members and answering from one would type
/// the read off an object that is not there.
///
/// `KLIO_IMPLRECV_TY=0` withdraws the channel, so a wrong answer can be told
/// from a wrong reading of one without a rebuild.
fn implicitReceiverPropTypeRef(b: *FuncBuilder, e: *const Expr) Allocator.Error!?ir.TypeRef {
    if (e.* != .Path or e.Path.segments.len != 1) return null;
    if (!implicitRecvTyOn()) return null;
    const nm = e.Path.segments[0].name;
    if (b.resolve(nm) != null or b.knowsOuter(nm)) return null;
    if (b.recvTy()) |rh| {
        if (try propTypeRefOrInferred(b, typeHead(std.mem.trimEnd(u8, rh, "?")), nm)) |t| return t;
    }
    if (b.spliceRecvTy()) |sh| {
        if (try propTypeRefOrInferred(b, typeHead(std.mem.trimEnd(u8, sh, "?")), nm)) |t| return t;
    }
    const owner = b.ownerClass() orelse return null;
    return try propTypeRefOrInferred(b, owner, nm);
}

threadlocal var implrecv_ty_state: u8 = 0;
fn implicitRecvTyOn() bool {
    if (implrecv_ty_state == 0) {
        const val = runtime.envOnce("KLIO_IMPLRECV_TY") orelse "1";
        implrecv_ty_state = if (std.mem.eql(u8, val, "0")) 1 else 2;
    }
    return implrecv_ty_state == 2;
}

/// `lhs ?: <jump>` carries the lhs type made non-null; the jump yields nothing.
fn elvisTypeRef(b: *FuncBuilder, e: *const Expr) Allocator.Error!?ir.TypeRef {

    if (e.* == .Binary and e.Binary.op == .Elvis) {
        const bin = e.Binary;
        if (try staticExprTypeRef(b, bin.lhs)) |lhs_ty| {
            var out = lhs_ty;
            switch (bin.rhs.*) {
                .Continue, .Break, .Return, .Throw => {
                    out.nullable = false;
                    return out;
                },
                else => {},
            }
            // A value rhs makes the result the join of both branches, not the lhs
            // type, which would devirtualize member calls to bodies the runtime
            // receiver overrides. Where one branch subsumes the other the supertype
            // wins; unrelated heads yield no static type.
            out.nullable = false;
            const lhs_head = typeHead(std.mem.trimEnd(u8, out.name, "?"));
            if (try staticExprTypeRef(b, bin.rhs)) |rhs_ty| {
                const rhs_head = typeHead(std.mem.trimEnd(u8, rhs_ty.name, "?"));
                if (std.mem.eql(u8, lhs_head, rhs_head)) {
                    out.nullable = rhs_ty.nullable;
                    return out;
                }
                var lhs_nn = out;
                lhs_nn.name = lhs_head;
                var rhs_nn = rhs_ty;
                rhs_nn.name = rhs_head;
                rhs_nn.nullable = false;
                if (b.module.staticTypeCompatibility(lhs_nn, rhs_nn) == .compatible) {
                    return try rhs_ty.clone(b.allocator);
                }
                if (b.module.staticTypeCompatibility(rhs_nn, lhs_nn) == .compatible) {
                    out.nullable = rhs_ty.nullable;
                    return out;
                }
                return null;
            }
            return out;
        }
    }
    return null;
}

/// Shapes that name their own type outright. `settled` is left false when the
/// shape names no type of its own, so the caller's initializer channel runs.
fn selfNamedTypeRef(b: *FuncBuilder, e: *const Expr, settled: *bool) Allocator.Error!?ir.TypeRef {
    settled.* = true;

self_named: {
    switch (e.*) {
        // The cast is the answer; `as?` carries the null the safe form produces.
    .As => |cast| {
        var out = try decl_mod.loweredTypeRef(b.allocator, &cast.ty, true);
        if (cast.safe) out.nullable = true;
        return out;
    },
    // A single supertype is the object expression's denotable static type;
    // more than one is the anonymous intersection.
        .ObjectExpr => |obj| {
            if (try objectExprTypeRef(b, obj)) |t| return t;
            break :self_named;
        },
    .This => |this_e| {
        if (this_e.qualifier) |q| {
            if (b.module.uniqueClassIdBySimpleName(q.name) != null) {
                return .{ .name = try b.allocator.dupe(u8, q.name), .nullable = false, .args = &.{} };
            }
            // A function-labeled `this@f` names an enclosing receiver the tower
            // records with its label, splice windows included.
            for (b.implicit_receiver_tower.items) |entry| {
                if (entry.label) |lbl| {
                    if (std.mem.eql(u8, lbl, q.name)) {
                        return .{ .name = try b.allocator.dupe(u8, entry.head), .nullable = false, .args = &.{} };
                    }
                }
            }
            // `this@<ownFn>` inside the function's own body is the declared
            // extension receiver, with its type arguments, so an overload rank
            // keeps its element knowledge.
            if (build.currentRealFn()) |rf| {
                if (std.mem.eql(u8, rf, q.name)) {
                    if (b.recvTypeRef()) |declared| return try declared.clone(b.allocator);
                    if (b.recvTy()) |head| {
                        return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
                    }
                }
            }
            return null;
        }
        // Declared extension receiver, then the splice window's actual
        // receiver, then the enclosing class.
        if (b.recvTypeRef()) |declared| return try declared.clone(b.allocator);
        if (b.spliceRecvTyRef()) |art| return try art.clone(b.allocator);
        if (b.spliceRecvTy()) |head| {
            return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
        }
        if (b.ownerClass()) |owner| {
            return .{ .name = try b.allocator.dupe(u8, owner), .nullable = false, .args = &.{} };
        }
        return null;
    },
    // A block in expression position is its last statement, when that is an
    // expression: the branches of an `if` written with braces. A local the
    // block declares is not in the deriver's scope, so a tail that reads one
    // derives nothing, which is the conservative answer.
    .Block => |blk| {
        if (blk.stmts.len == 0) return null;
        const last = &blk.stmts[blk.stmts.len - 1];
        if (last.* != .Expr) return null;
        return try staticExprTypeRef(b, &last.Expr);
    },
    // A conditional's type is what its branches agree on. Kotlin's answer is
    // their least upper bound; this takes the exact case, every branch deriving
    // the same head, which is never a widening.
    .If => |iff| {
        const else_e = iff.else_branch orelse return null;
        const t_then = (try staticExprTypeRef(b, iff.then_branch)) orelse return null;
        const t_else = (try staticExprTypeRef(b, else_e)) orelse return null;
        if (!std.mem.eql(u8, t_then.name, t_else.name)) return null;
        var out = t_then;
        out.nullable = t_then.nullable or t_else.nullable;
        return out;
    },
    .When => |whn| {
        if (whn.branches.len == 0) return null;
        var agreed: ?ir.TypeRef = null;
        var nullable = false;
        for (whn.branches) |*br| {
            const t = (try staticExprTypeRef(b, &br.body)) orelse return null;
            nullable = nullable or t.nullable;
            if (agreed) |a| {
                if (!std.mem.eql(u8, a.name, t.name)) return null;
            } else {
                agreed = t;
            }
        }
        var out = agreed orelse return null;
        out.nullable = nullable;
        return out;
    },
    .Binary => |bin| switch (bin.op) {
        .Eq, .Neq, .IdentEq, .IdentNeq, .Lt, .Le, .Gt, .Ge, .In, .NotIn, .And, .Or => {
            return .{ .name = try b.allocator.dupe(u8, "Boolean"), .nullable = false, .args = &.{} };
        },
        // Kotlin fixes built-in numeric arithmetic by promotion; only
        // both-sides-known non-nullable primitives qualify.
        .Add, .Sub, .Mul, .Div, .Rem => {
            var lhs_owned = try staticExprTypeRef(b, bin.lhs);
            defer if (lhs_owned) |*t| t.deinit(b.allocator);
            var rhs_owned = try staticExprTypeRef(b, bin.rhs);
            defer if (rhs_owned) |*t| t.deinit(b.allocator);
            const lt = lhs_owned orelse break :self_named;
            const rt = rhs_owned orelse break :self_named;
            if (lt.nullable or rt.nullable) break :self_named;
            const promoted = numericPromotion(lt.name, rt.name) orelse break :self_named;
            return .{ .name = try b.allocator.dupe(u8, promoted), .nullable = false, .args = &.{} };
        },
        else => {},
    },
    .Unary => |un| switch (un.op) {
        .Not => return .{ .name = try b.allocator.dupe(u8, "Boolean"), .nullable = false, .args = &.{} },
        .Neg, .Pos => return try staticExprTypeRef(b, un.expr),
        else => {},
    },
    .Postfix => |pf| if (pf.op == .NotNull) {
        var t = (try staticExprTypeRef(b, pf.expr)) orelse break :self_named;
        t.nullable = false;
        if (std.mem.endsWith(u8, t.name, "?")) {
            const trimmed = try b.allocator.dupe(u8, std.mem.trimEnd(u8, t.name, "?"));
            b.allocator.free(t.name);
            t.name = trimmed;
        }
        return t;
    },
    // A bare name reading an enclosing class or companion property lends its
    // declared type. Locals were consulted first, and a same-named local
    // without a type keeps shadowing, since Kotlin resolves the local.
        .Path => |p| {
            if (try barePathSelfTypeRef(b, p)) |t| return t;
            break :self_named;
        },
        .Member => |m| {
            if (try memberReadSelfTypeRef(b, m)) |t| return t;
            break :self_named;
        },
        else => {},
    }
}
    settled.* = false;
    return null;
}

/// A single supertype is the object expression's denotable static type; more
/// than one is the anonymous intersection, which is not denotable.
fn objectExprTypeRef(b: *FuncBuilder, obj: @FieldType(Expr, "ObjectExpr")) Allocator.Error!?ir.TypeRef {

    // A bare `object {}` has denotable type `Any` outside the literal.
    if (obj.supertypes.len == 0) {
        return .{ .name = try b.allocator.dupe(u8, "Any"), .nullable = false, .args = &.{} };
    }
    if (obj.supertypes.len != 1) return null;
    var out = try decl_mod.loweredTypeRef(b.allocator, &obj.supertypes[0], true);
    var h = std.mem.trimEnd(u8, out.name, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
        ir.parseClassTypeParamIdentity(h) != null;
    if (h.len == 0 or bare) {
        out.deinit(b.allocator);
        return null;
    }
    return out;
}

/// A bare name reading an enclosing class or companion property lends its
/// declared type. Locals were consulted first, and a same-named local without a
/// type keeps shadowing, since Kotlin resolves the local.
fn barePathSelfTypeRef(b: *FuncBuilder, p: @FieldType(Expr, "Path")) Allocator.Error!?ir.TypeRef {

    if (p.segments.len != 1) return null;
    const nm = p.segments[0].name;
    if (runtime.envOnce("KLIO_IMPLPROP_TRACE")) |w| {
        if (std.mem.eql(u8, w, nm))
            std.debug.print("[implprop-guard] {s} resolve={} localfn={} outer={}\n", .{ nm, b.resolve(nm) != null, b.isLocalFn(nm), b.knowsOuter(nm) });
    }
    if (b.resolve(nm) != null or b.isLocalFn(nm) or b.knowsOuter(nm)) return null;
    if (b.ownerClass()) |owner| {
        // The full-ref table records only arg-carrying declared types.
        if (propTypeRefOn(b, owner, nm)) |t| return try t.clone(b.allocator);
        if (b.module.registry.class_prop_type_heads.get(.{ .a = owner, .b = nm })) |head| {
            return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
        }
        // Companion properties are in scope in the class body, recorded
        // under the lifted `{Owner}$Companion` key.
        var ckey_buf: [160]u8 = undefined;
        if (std.fmt.bufPrint(&ckey_buf, "{s}$Companion", .{owner})) |ckey| {
            if (propTypeRefOn(b, ckey, nm)) |t| return try t.clone(b.allocator);
            if (b.module.registry.class_prop_type_heads.get(.{ .a = ckey, .b = nm })) |head| {
                return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
            }
        } else |_| {}
    }
    // A property of the implicit receiver, with a type-parameter head
    // chased to its bound.
    impl: {
        const h0 = b.recvTy() orelse b.spliceRecvTy() orelse break :impl;
        var hh = typeHead(std.mem.trimEnd(u8, h0, "?"));
        const impl_trace = if (runtime.envOnce("KLIO_IMPLPROP_TRACE")) |w| std.mem.eql(u8, w, nm) else false;
        if (impl_trace) {
            std.debug.print("[implprop] {s} h0={s} tp={} bref={} tpb={}\n", .{
                nm, h0, b.isTypeParam(hh), b.typeParamBoundRef(hh) != null, b.typeParamBound(hh) != null,
            });
        }
        var bound_full: ?*const ir.TypeRef = null;
        if (b.isTypeParam(hh) or (hh.len > 0 and hh.len <= 2 and std.ascii.isUpper(hh[0]))) {
            if (b.typeParamBoundRef(hh)) |bref| {
                bound_full = bref;
                hh = typeHead(std.mem.trimEnd(u8, bref.name, "?"));
            } else if (b.typeParamBound(hh)) |tpb| {
                // Head-only bound record: the head still names the owner.
                hh = typeHead(std.mem.trimEnd(u8, tpb.bound, "?"));
            } else if (b.enclosingRecvTy()) |eh2| {
                // The lambda's own receiver head may be the spliced
                // callee's literal param, while the enclosing receiver's
                // head carries the real parameter and its bound.
                const hh2 = typeHead(std.mem.trimEnd(u8, eh2, "?"));
                if (b.typeParamBoundRef(hh2)) |bref2| {
                    bound_full = bref2;
                    hh = typeHead(std.mem.trimEnd(u8, bref2.name, "?"));
                } else if (b.typeParamBound(hh2)) |tpb2| {
                    hh = typeHead(std.mem.trimEnd(u8, tpb2.bound, "?"));
                } else if (!(b.isTypeParam(hh2) or (hh2.len > 0 and hh2.len <= 2 and std.ascii.isUpper(hh2[0])))) {
                    hh = hh2;
                } else {
                    hh = implBoundScan(b, nm) orelse break :impl;
                }
            } else {
                // The window's head names a param with no recorded bound,
                // so the unique in-scope bound whose class declares the
                // property is the receiver.
                hh = implBoundScan(b, nm) orelse break :impl;
            }
        }
        if (propTypeRefOn(b, hh, nm)) |declared| {
            if (bound_full) |br| {
                if (substitutedPropType(b, hh, br.*, declared)) |sub| {
                    return try sub.clone(b.allocator);
                }
            } else if (b.recvTypeRef()) |rt| {
                if (substitutedPropType(b, hh, rt, declared)) |sub| {
                    return try sub.clone(b.allocator);
                }
            }
        }
        if (b.module.registry.class_prop_type_heads.get(.{ .a = hh, .b = nm })) |ph| {
            const phh = typeHead(std.mem.trimEnd(u8, ph, "?"));
            if (phh.len > 2 and ir.parseClassTypeParamIdentity(phh) == null and !b.isTypeParam(phh)) {
                return .{ .name = try b.allocator.dupe(u8, ph), .nullable = false, .args = &.{} };
            }
        }
    }
    // A top-level property read lends its declared type under the caller's
    // own scope tiers.
    if (b.module.topLevelPropTypeRef(nm, b.self_package, p.segments[0].span.file)) |t| {
        return try t.clone(b.allocator);
    }
    if (b.module.topLevelPropTypeHeadTiered(nm, b.self_package, p.segments[0].span.file)) |head| {
        const hh = typeHead(std.mem.trimEnd(u8, head, "?"));
        if (hh.len > 2 and ir.parseClassTypeParamIdentity(hh) == null) {
            return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
        }
    }
    return null;
}

/// A class-named member read: a nested object, or a companion property under
/// the lifted companion key.
fn memberReadSelfTypeRef(b: *FuncBuilder, m: @FieldType(Expr, "Member")) Allocator.Error!?ir.TypeRef {

    if (m.safe) return null;
    const recv_p = m.receiver;
    if (recv_p.* != .Path or recv_p.Path.segments.len != 1 or
        b.resolve(recv_p.Path.segments[0].name) != null or
        b.knowsOuter(recv_p.Path.segments[0].name) or
        b.module.uniqueClassIdBySimpleName(recv_p.Path.segments[0].name) == null)
    {
        // Not a class-named read: a property read on any typeable receiver
        // answers the property's declared type, with the owner's
        // parameters substituted from the receiver's arguments.
        if (expr_mod.od_depth >= 3) return null;
        expr_mod.od_depth += 1;
        const recv_owned = staticExprTypeRef(b, m.receiver) catch null;
        expr_mod.od_depth -= 1;
        var rt = recv_owned orelse return null;
        defer rt.deinit(b.allocator);
        var rh = std.mem.trimEnd(u8, rt.name, "?");
        if (std.mem.findScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
        const head = typeHead(rh);
        if (head.len == 0) return null;
        if (runtime.envOnce("KLIO_IMPLPROP_TRACE")) |w| {
            if (std.mem.eql(u8, w, m.name.name)) {
                std.debug.print("[implprop-mem] {s} head={s} refs={} heads={}\n", .{
                    m.name.name, head,
                    propTypeRefOn(b, head, m.name.name) != null,
                    b.module.registry.class_prop_type_heads.get(.{ .a = head, .b = m.name.name }) != null,
                });
            }
        }
        if (propTypeRefOn(b, head, m.name.name)) |declared| {
            if (substitutedPropType(b, head, rt, declared)) |sub| {
                return try sub.clone(b.allocator);
            }
        }
        if (b.module.registry.class_prop_type_heads.get(.{ .a = head, .b = m.name.name })) |ph| {
            const phh = typeHead(std.mem.trimEnd(u8, ph, "?"));
            if (phh.len > 2 and ir.parseClassTypeParamIdentity(phh) == null and !b.isTypeParam(phh)) {
                return .{ .name = try b.allocator.dupe(u8, ph), .nullable = false, .args = &.{} };
            }
        }
        return null;
    }
    const cls = recv_p.Path.segments[0].name;
    var qbuf: [192]u8 = undefined;
    if (std.fmt.bufPrint(&qbuf, "{s}.{s}", .{ cls, m.name.name })) |qual| {
        if (b.module.classIdByQualifiedSuffix(qual) != null) {
            return .{ .name = try b.allocator.dupe(u8, qual), .nullable = false, .args = &.{} };
        }
    } else |_| {}
    var ckbuf: [192]u8 = undefined;
    if (std.fmt.bufPrint(&ckbuf, "{s}$Companion", .{cls})) |ckey| {
        if (propTypeRefOn(b, ckey, m.name.name)) |t| return try t.clone(b.allocator);
        if (b.module.registry.class_prop_type_heads.get(.{ .a = ckey, .b = m.name.name })) |head| {
            return .{ .name = try b.allocator.dupe(u8, head), .nullable = false, .args = &.{} };
        }
    } else |_| {}
    return null;
}


/// The declared return type of a nullary member on a known receiver type, with the
/// receiver's type arguments substituted in. This is what a destructured
/// component needs, each name binding to the element's `componentN()`.
/// The instantiated return of a nullary member call, keeping a return left as a
/// bare type parameter. `nullaryMemberReturnTypeRef` drops those; callers that
/// want to know an expression carries `T` ask here.
/// The declaration a zero-argument member call on `recv` reaches, with the
/// dispatch commitment. `nullaryMemberReturnTypeRefRaw` asks the same question
/// and keeps only the return type; a synthesized call such as a destructuring
/// `componentN()` needs the target itself in order to bind.
pub fn nullaryMemberResolution(
    b: *FuncBuilder,
    recv: ir.TypeRef,
    name: []const u8,
    file: span.FileId,
) Allocator.Error!?ir.Module.MemberResolution {
    var identity = std.mem.trimEnd(u8, recv.name, "?");
    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    if (identity.len == 0) return null;
    const owner = (if (std.mem.findScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(identity))) orelse return null;
    var shape_set = try buildStaticReturnArgShapes(b, &.{}, &.{});
    defer shape_set.deinit(b.allocator);
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    return b.module.resolveMemberCall(owner, name, shape_set.shapes, .{
        .caller_file = file,
        .lexical_owner = null,
        .actual_type_param_bounds = owned_bounds orelse &.{},
        .receiver_type = recv,
    });
}

pub fn nullaryMemberReturnTypeRefRaw(
    b: *FuncBuilder,
    recv: ir.TypeRef,
    name: []const u8,
    file: span.FileId,
) Allocator.Error!?ir.TypeRef {
    const trace = runtime.envOnce("KLIO_COMP_TRACE") != null;
    var identity = std.mem.trimEnd(u8, recv.name, "?");
    if (std.mem.findScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    if (identity.len == 0) return null;
    const owner = (if (std.mem.findScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(typeHead(identity))) orelse {
        if (trace) std.debug.print("[comp] {s}.{s} no owner\n", .{ identity, name });
        return null;
    };
    var shape_set = try buildStaticReturnArgShapes(b, &.{}, &.{});
    defer shape_set.deinit(b.allocator);
    const owned_bounds = try b.typeParamBoundsSlice();
    defer if (owned_bounds) |bounds| b.allocator.free(bounds);
    const resolved = b.module.resolveMemberCall(owner, name, shape_set.shapes, .{
        .caller_file = file,
        .lexical_owner = null,
        .actual_type_param_bounds = owned_bounds orelse &.{},
        .receiver_type = recv,
    });
    // A deferred resolution naming one declaration suffices: this reads a return
    // type, not a dispatch commitment, and an override may only narrow it.
    const target = resolved.target orelse {
        if (trace) std.debug.print("[comp] {s}.{s} no target applicable={} methods={d}\n", .{
            identity,
            name,
            resolved.applicable,
            b.module.classes.items[owner.int()].methods.len,
        });
        return null;
    };
    var dispatch_receiver = try staticDispatchReceiverTypeRef(b, target, recv, file);
    defer if (dispatch_receiver) |*ty| ty.deinit(b.allocator);
    const out = (try b.module.instantiatedCallReturnType(
        b.allocator,
        target,
        recv,
        dispatch_receiver,
        shape_set.shapes,
        &.{},
    )) orelse {
        if (trace) std.debug.print("[comp] {s}.{s} no return type\n", .{ identity, name });
        return null;
    };
    if (trace) std.debug.print("[comp] {s}.{s} -> {s}\n", .{ identity, name, out.name });
    return out;
}

pub fn nullaryMemberReturnTypeRef(
    b: *FuncBuilder,
    recv: ir.TypeRef,
    name: []const u8,
    file: span.FileId,
) Allocator.Error!?ir.TypeRef {
    var out = (try nullaryMemberReturnTypeRefRaw(b, recv, name, file)) orelse return null;
    // A return type left as the owner's own type parameter names no class.
    var head = std.mem.trimEnd(u8, out.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (b.module.classIdByFqn(head) == null and
        b.module.uniqueClassIdBySimpleName(typeHead(head)) == null)
    {
        if (runtime.envOnce("KLIO_COMP_TRACE") != null) {
            std.debug.print("[comp] {s} unknown head {s}\n", .{ name, out.name });
        }
        out.deinit(b.allocator);
        return null;
    }
    return out;
}
