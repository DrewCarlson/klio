//! Static expression type inference and the memo that backs it.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const decl_mod = @import("../decl.zig");
const inline_call = @import("../inline_call.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const FuncId = ir.FuncId;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;

const expr_mod = @import("../expr.zig");

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

pub fn argDeclTypeRefLazyUncached(b: *FuncBuilder, arg: *const Expr) ?ir.TypeRef {
    if (runtime.envOnce("KLIO_VALTY_TRACE")) |w| {
        if (arg.* == .Path and arg.Path.segments.len == 1 and std.mem.eql(u8, arg.Path.segments[0].name, w)) {
            std.debug.print("[valty] LAZY {s} decl={s} splice={} lsr={}\n", .{ w, if (b.localDeclTypeRef(w)) |t| t.name else "<unset>", b.spliceParamTy(w) != null, b.lambda_splice_resolve != null });
        }
    }
    if (arg.* == .This and arg.This.qualifier == null) {
        // An extension body spliced into a member binds a new `this` while the
        // flat declaration metadata still names the enclosing member receiver, so
        // the splice receiver wins. A spliced lambda argument skips it.
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
    // `this@label`: the builder's own receiver when its label matches (an ext
    // body's label is its fn name), else the tower entry carrying it.
    if (arg.* == .This) {
        if (arg.This.qualifier) |q| {
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
    // An unsafe cast fixes the argument's static type for overload resolution.
    if (arg.* == .As and !arg.As.safe) {
        return .{ .name = loweredTypeName(b, &arg.As.ty), .nullable = arg.As.ty.nullable, .args = &.{} };
    }
    // A member property read as a receiver: receiver head plus property head.
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
    // `x++`/`x--` evaluates to the operand's prior value and carries its type.
    if (arg.* == .Postfix) return argDeclTypeRefLazy(b, arg.Postfix.expr);
    if (arg.* == .Unary) {
        switch (arg.Unary.op) {
            .Not => return .{ .name = "Boolean", .nullable = false, .args = &.{} },
            .Neg, .Pos => return argDeclTypeRefLazy(b, arg.Unary.expr),
            else => {},
        }
    }
    // Arithmetic on primitives promotes to the wider operand.
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
    // The range classes exist while the operator producing them is builtin.
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
    // `a / b` on a class is an operator member; its declared return is the answer.
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
    // The sole type argument, or a stated element where there is no declaration.
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
    // A class-named receiver's property head is the static type.
    if (arg.* == .Member) {
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
    if (arg.* != .Path) return null;
    const p = arg.Path;
    if (p.segments.len == 2) {
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
    if (p.segments.len != 1) return null;
    // An inlined function's parameters live in the caller builder while their
    // declared types belong to the spliced declaration, so keep the source type as
    // evidence. A spliced lambda argument skips this channel: its free names
    // resolve in the caller scopes and may shadow a same-named inline parameter.
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
    if (b.localDeclTypeRef(p.segments[0].name)) |declared| {
        var result = declared;
        result.nullable = result.nullable or b.localDeclNullable(p.segments[0].name);
        return result;
    }
    // A bare implicit-`this` property read of the enclosing class's own `val`,
    // resolved against the receiver's property table with a nested-class head
    // qualified through the enclosing scope.
    {
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
    }
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
    // The full declared type wins over its head, which throws the arguments away.
    if (staticBareReceiverTypeRef(b, p.segments[0].name)) |full| return full;
    if (staticBareReceiverType(b, p.segments[0].name)) |head| {
        return .{ .name = head, .nullable = false, .args = &.{} };
    }
    // A bare class name used as a value is its companion object.
    const nm = p.segments[0].name;
    if (b.resolve(nm) == null and !b.knowsOuter(nm) and b.module.classId(nm) != null) {
        return .{ .name = nm, .nullable = false, .args = &.{} };
    }
    // A top-level property read carries its declared type head, picked by the same
    // scoping walk a bare call ranks by.
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
var init_chain: [16][]const u8 = @splat(&.{});
pub var init_chain_len: usize = 0;

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
    // A nested class constructed through its own enclosing class name; the bare
    // form resolves through the lexical nested-class walk, the qualified one
    // reached no class at all.
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
    // `Array(size) { init }`: the element type is the lambda's tail expression.
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

/// The memo outlives any one function build, so its storage is process-lifetime.
fn memoAlloc() std.mem.Allocator {
    return std.heap.smp_allocator;
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
    // `lhs ?: <jump>` carries the lhs type made non-null; the jump yields nothing.
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
    // Shapes that name their own type outright.
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
            // A bare `object {}` has denotable type `Any` outside the literal.
            if (obj.supertypes.len == 0) {
                return .{ .name = try b.allocator.dupe(u8, "Any"), .nullable = false, .args = &.{} };
            }
            if (obj.supertypes.len != 1) break :self_named;
            var out = try decl_mod.loweredTypeRef(b.allocator, &obj.supertypes[0], true);
            var h = std.mem.trimEnd(u8, out.name, "?");
            if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
            const bare = (h.len > 0 and h.len <= 2 and std.ascii.isUpper(h[0])) or
                ir.parseClassTypeParamIdentity(h) != null;
            if (h.len == 0 or bare) {
                out.deinit(b.allocator);
                break :self_named;
            }
            return out;
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
            if (p.segments.len != 1) break :self_named;
            const nm = p.segments[0].name;
            if (runtime.envOnce("KLIO_IMPLPROP_TRACE")) |w| {
                if (std.mem.eql(u8, w, nm))
                    std.debug.print("[implprop-guard] {s} resolve={} localfn={} outer={}\n", .{ nm, b.resolve(nm) != null, b.isLocalFn(nm), b.knowsOuter(nm) });
            }
            if (b.resolve(nm) != null or b.isLocalFn(nm) or b.knowsOuter(nm)) break :self_named;
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
            break :self_named;
        },
        // A class-named member read: a nested object, or a companion property under
        // the lifted companion key.
        .Member => |m| {
            if (m.safe) break :self_named;
            const recv_p = m.receiver;
            if (recv_p.* != .Path or recv_p.Path.segments.len != 1 or
                b.resolve(recv_p.Path.segments[0].name) != null or
                b.knowsOuter(recv_p.Path.segments[0].name) or
                b.module.uniqueClassIdBySimpleName(recv_p.Path.segments[0].name) == null)
            {
                // Not a class-named read: a property read on any typeable receiver
                // answers the property's declared type, with the owner's
                // parameters substituted from the receiver's arguments.
                if (expr_mod.od_depth >= 3) break :self_named;
                expr_mod.od_depth += 1;
                const recv_owned = staticExprTypeRef(b, m.receiver) catch null;
                expr_mod.od_depth -= 1;
                var rt = recv_owned orelse break :self_named;
                defer rt.deinit(b.allocator);
                var rh = std.mem.trimEnd(u8, rt.name, "?");
                if (std.mem.findScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
                const head = typeHead(rh);
                if (head.len == 0) break :self_named;
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
                break :self_named;
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
            break :self_named;
        },
            else => {},
        }
    }
    return try localInitTypeRef(b, e);
}

/// The declared return type of a nullary member on a known receiver type, with the
/// receiver's type arguments substituted in. This is what a destructured
/// component needs, each name binding to the element's `componentN()`.
pub fn nullaryMemberReturnTypeRef(
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
    var out = (try b.module.instantiatedCallReturnType(
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
    // A return type left as the owner's own type parameter names no class.
    var head = std.mem.trimEnd(u8, out.name, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (b.module.classIdByFqn(head) == null and
        b.module.uniqueClassIdBySimpleName(typeHead(head)) == null)
    {
        if (trace) std.debug.print("[comp] {s}.{s} unknown head {s}\n", .{ identity, name, out.name });
        out.deinit(b.allocator);
        return null;
    }
    if (trace) std.debug.print("[comp] {s}.{s} -> {s}\n", .{ identity, name, out.name });
    return out;
}
