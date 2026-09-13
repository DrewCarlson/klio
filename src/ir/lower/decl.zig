//! Declaration lowering: the build driver's entry points for class, function and
//! method lowering. `bindParams` is shared with the thunk lowerings.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const mod = @import("mod.zig");
const helpers = @import("helpers.zig");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Module = ir.Module;
const Func = ir.Func;
const Class = ir.Class;
const Param = ir.Param;
const TypeRef = ir.TypeRef;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Terminator = ir.Terminator;
const StringSet = std.StringHashMap(void);

/// File-scoped class registry, simple name to AST class, threaded through the
/// public lowering entry points so cross-class member lookups resolve.
pub const FileClasses = std.StringHashMap(FF(ast.Class));

/// Resolve each source annotation to its fully-qualified candidate names using the
/// declaring file's imports: a qualified path yields itself, a simple name `N` the
/// FQN of every named import bound to `N`, `A.B.N` for each `import A.B.*`, and
/// always bare `N`. De-duplicated, owned by `module.registry.allocator`.
pub fn resolveAnnotationNames(
    module: *Module,
    annotations: []const ast.Annotation,
) Allocator.Error![]const []const u8 {
    if (annotations.len == 0) return &.{};
    const a = module.registry.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (annotations) |*ann| {
        if (ann.path.len == 0) continue;
        const file = ann.span.file;
        if (ann.path.len > 1) {
            const dotted = try joinIdents(a, ann.path, ".");
            try appendUnique(a, &out, dotted);
            continue;
        }
        const name = ann.path[0].name;
        for (module.importAliasPathsIn(file, name)) |p| {
            try appendUnique(a, &out, p.fqn);
        }
        if (module.registry.import_wildcards.get(file)) |list| {
            for (list.items) |pkg| {
                const fqn = try std.fmt.allocPrint(a, "{s}.{s}", .{ pkg, name });
                try appendUnique(a, &out, fqn);
            }
        }
        try appendUnique(a, &out, name);
    }
    return out.toOwnedSlice(a);
}

fn joinIdents(a: Allocator, idents: []const ast.Ident, sep: []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    for (idents, 0..) |id, i| {
        if (i != 0) try buf.appendSlice(a, sep);
        try buf.appendSlice(a, id.name);
    }
    return buf.toOwnedSlice(a);
}

fn appendUnique(a: Allocator, out: *std.ArrayList([]const u8), s: []const u8) Allocator.Error!void {
    for (out.items) |e| {
        if (std.mem.eql(u8, e, s)) return;
    }
    try out.append(a, s);
}

/// Bind function parameters into the current scope, each loaded into a fresh
/// register via `Inst.LoadParam` so later `Path { name }` reads route through it.
/// `varargArrayHead` is the materialized array head a `vararg x: T` parameter has
/// inside the body: the primitive-specialized array, else `Array`.
pub fn varargArrayHead(elem: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, elem, "Byte")) return "ByteArray";
    if (eq(u8, elem, "Short")) return "ShortArray";
    if (eq(u8, elem, "Int")) return "IntArray";
    if (eq(u8, elem, "Long")) return "LongArray";
    if (eq(u8, elem, "Char")) return "CharArray";
    if (eq(u8, elem, "Boolean")) return "BooleanArray";
    if (eq(u8, elem, "Float")) return "FloatArray";
    if (eq(u8, elem, "Double")) return "DoubleArray";
    if (eq(u8, elem, "UByte")) return "UByteArray";
    if (eq(u8, elem, "UShort")) return "UShortArray";
    if (eq(u8, elem, "UInt")) return "UIntArray";
    if (eq(u8, elem, "ULong")) return "ULongArray";
    return "Array";
}

/// The full materialized type of a `vararg x: T` parameter inside the body: the
/// primitive-specialized array, else `Array<out T>` carrying the element, since a
/// head-only `Array` record cannot bind an `Array<out String>` parameter.
pub fn varargArrayTypeRef(allocator: std.mem.Allocator, elem: *const ast.TypeRef) Allocator.Error!ir.TypeRef {
    const head = varargArrayHead(elem.name.name);
    if (!std.mem.eql(u8, head, "Array")) {
        return .{ .name = try allocator.dupe(u8, head), .nullable = false, .args = &.{} };
    }
    var element = try loweredTypeRef(allocator, elem, true);
    errdefer element.deinit(allocator);
    const projected = try std.fmt.allocPrint(allocator, "out#{s}", .{element.name});
    allocator.free(@constCast(element.name));
    element.name = projected;
    const args = try allocator.alloc(ir.TypeRef, 1);
    args[0] = element;
    return .{ .name = try allocator.dupe(u8, "Array"), .nullable = false, .args = args };
}

pub fn bindParams(b: *FuncBuilder, names: []const []const u8) Allocator.Error!void {
    for (names, 0..) |name, i| {
        const dst = b.allocReg();
        try b.push(.{ .LoadParam = .{ .dst = dst, .idx = @intCast(i) } });
        if (b.isBoxed(name)) {
            // A parameter a nested closure writes is a captured-and-mutated
            // enclosing local just like a body `var`, so box it into a shared
            // `Value.Cell`, per Kotlin `Ref` semantics. Reads emit `CellGet`.
            const home = b.allocReg();
            try b.push(.{ .MakeCell = .{ .dst = home, .src = dst } });
            try b.setMutableHome(name, home);
            try b.markMutable(name);
            try b.bind(name, home);
        } else {
            try b.bind(name, dst);
        }
        try b.markParam(name);
    }
}

/// Emit the prologue binding a contextual declaration's context parameters, each
/// loading the nearest in-scope context value of its declared type; `_` parameters
/// resolve for `contextOf` and nested calls but are not bound by name. The caller
/// flags the module as context-using, excluding the stdlib intrinsics, so the
/// runtime feeds receivers into the context stack only for a real declaration.
pub fn emitContextParamLoads(
    b: *FuncBuilder,
    context_params: []const ast.ContextParam,
    type_params: []const ast.TypeParam,
) Allocator.Error!void {
    if (context_params.len == 0) return;
    for (context_params) |*cp| {
        const dst = b.allocReg();
        var erased = cp.ty.function != null;
        for (type_params) |*tp| {
            if (std.mem.eql(u8, tp.name.name, cp.ty.name.name)) {
                erased = true;
                break;
            }
        }
        const ty_name = try loweredTypeName(b.allocator, &cp.ty);
        const ty_const = try b.module.internConst(b.allocator, .{ .String = ty_name });
        try b.push(.{ .CtxLoad = .{ .dst = dst, .ty = ty_const, .erased = erased } });
        if (!std.mem.eql(u8, cp.name.name, "_")) {
            try b.bind(cp.name.name, dst);
            try b.setLocalDeclTypeOwned(
                cp.name.name,
                try loweredTypeRef(b.allocator, &cp.ty, true),
            );
            if (cp.ty.nullable) try b.setLocalDeclNullable(cp.name.name);
            if (cp.ty.function) |ft| {
                if (ft.receiver != null) try b.setLocalDeclRecvFn(cp.name.name);
            }
        }
    }
}

/// Lower a Kotlin class declaration into an IR Class. Methods lower as Funcs with a
/// synthetic `<receiver>` first parameter, the constructor params lifting onto the
/// Class's `primary_params`. The Class becomes reachable through `module.class_id`.
pub fn lowerClass(module: *Module, c: *const ast.Class) Allocator.Error!ClassId {
    var empty = FileClasses.init(module.registry.allocator);
    defer empty.deinit();
    return lowerClassWithFile(module, c, &empty);
}

pub fn lowerClassWithFile(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
) Allocator.Error!ClassId {
    var extra = StringSet.init(module.registry.allocator);
    defer extra.deinit();
    return lowerClassWithExtras(module, c, file_classes, &extra);
}

/// Like `lowerClassWithExtras` but stamps a caller-supplied package-qualified FQN,
/// so two packages declaring the same simple name stay separate definitions.
pub fn lowerClassWithExtrasFqn(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    extra_members: *const StringSet,
    class_fqn: []const u8,
) Allocator.Error!ClassId {
    return lowerClassWithExtrasFqnPkg(module, c, file_classes, extra_members, class_fqn, ir.packageOfFqn(class_fqn, c.name.name));
}

/// Like `lowerClassWithExtrasFqn` but with the declaring package supplied
/// explicitly: a nested or companion class's FQN is class-qualified, so deriving
/// the package from it would hand the symbol index a phantom package.
pub fn lowerClassWithExtrasFqnPkg(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    extra_members: *const StringSet,
    class_fqn: []const u8,
    class_pkg: []const u8,
) Allocator.Error!ClassId {
    lower_class_fqn = class_fqn;
    lower_class_pkg = class_pkg;
    const prev_pkg = setLowerSelfPackage(class_pkg);
    const id = try lowerClassWithExtras(module, c, file_classes, extra_members);
    _ = setLowerSelfPackage(prev_pkg);
    lower_class_fqn = null;
    lower_class_pkg = null;
    return id;
}

/// Package-qualified FQN for the class currently being lowered, read once where the
/// IR `Class` shell is created.
var lower_class_fqn: ?[]const u8 = null;

/// Declaring package matching `lower_class_fqn`; null falls back to deriving it
/// from the FQN.
var lower_class_pkg: ?[]const u8 = null;

/// The caller-package seed lives next to `FuncBuilder`, which reads it on init;
/// re-exported here for the build drivers.
pub const setLowerSelfPackage = build.setLowerSelfPackage;

fn memberDeclKey(a: Allocator, owner: []const u8, f: *const ast.Function) Allocator.Error![]u8 {
    const s = f.name.span;
    return std.fmt.allocPrint(a, "$decl$\x00{s}\x00{s}\x00{d}:{d}:{d}", .{
        owner,
        f.name.name,
        s.file.int(),
        s.start,
        s.end,
    });
}

fn memberOwnerTypeRef(
    module: *const Module,
    allocator: Allocator,
    owner_id: ?ir.ClassId,
    fallback_name: []const u8,
) Allocator.Error!TypeRef {
    const id = owner_id orelse return .{
        .name = fallback_name,
        .nullable = false,
        .args = &.{},
    };
    if (id.int() >= module.classes.items.len) return .{
        .name = fallback_name,
        .nullable = false,
        .args = &.{},
    };
    const class = &module.classes.items[id.int()];
    const args = try allocator.alloc(TypeRef, class.type_params.len);
    for (class.type_params, args) |param, *arg| {
        arg.* = .{
            .name = try ir.classTypeParamIdentity(allocator, id, param),
            .nullable = false,
            .args = &.{},
        };
    }
    return .{
        .name = class.fqn,
        .nullable = false,
        .args = args,
    };
}

/// Whether the class body already declares a zero-parameter function of this name.
/// A hand-written `componentN` wins over the synthesized one, as in Kotlin.
fn declaresNullaryMember(c: *const ast.Class, name: []const u8) bool {
    for (c.members) |*m| {
        if (m.* != .Function) continue;
        const f = &m.Function;
        if (f.params.len == 0 and std.mem.eql(u8, f.name.name, name)) return true;
    }
    return false;
}

fn functionTypeParamShadows(f: *const ast.Function, name: []const u8) bool {
    for (f.type_params) |*param| {
        if (std.mem.eql(u8, param.name.name, name)) return true;
    }
    return false;
}

fn typeRefHasQualifier(ty: TypeRef) bool {
    for (ty.args) |arg| {
        if (std.mem.startsWith(u8, arg.name, "#qual:")) return true;
    }
    return false;
}

fn rewriteClassOwnedTypeRef(
    allocator: Allocator,
    owner: ir.ClassId,
    class_params: []const []const u8,
    f: *const ast.Function,
    own_names: bool,
    ty: *TypeRef,
) Allocator.Error!void {
    for (ty.args) |*arg| {
        try rewriteClassOwnedTypeRef(
            allocator,
            owner,
            class_params,
            f,
            own_names,
            arg,
        );
    }
    if (typeRefHasQualifier(ty.*)) return;
    const prefix: ?[]const u8 = if (std.mem.startsWith(u8, ty.name, "out#"))
        "out#"
    else if (std.mem.startsWith(u8, ty.name, "in#"))
        "in#"
    else
        null;
    const source_name = if (prefix) |p| ty.name[p.len..] else ty.name;
    if (std.mem.findScalar(u8, source_name, '.') != null) return;
    for (class_params) |param| {
        if (!std.mem.eql(u8, source_name, param) or
            functionTypeParamShadows(f, param)) continue;
        const identity = try ir.classTypeParamIdentity(allocator, owner, param);
        const rewritten = if (prefix) |p| blk: {
            const projected = try std.fmt.allocPrint(
                allocator,
                "{s}{s}",
                .{ p, identity },
            );
            allocator.free(identity);
            break :blk projected;
        } else identity;
        if (own_names) allocator.free(ty.name);
        ty.name = rewritten;
        return;
    }
}

fn rewriteMemberFuncTypes(
    module: *const Module,
    allocator: Allocator,
    owner: ?ir.ClassId,
    f: *const ast.Function,
    func: *Func,
) Allocator.Error!void {
    const owner_id = owner orelse return;
    if (owner_id.int() >= module.classes.items.len) return;
    const class_params = module.classes.items[owner_id.int()].type_params;
    for (func.params) |*param| {
        try rewriteClassOwnedTypeRef(
            allocator,
            owner_id,
            class_params,
            f,
            false,
            &param.ty,
        );
    }
    try rewriteClassOwnedTypeRef(
        allocator,
        owner_id,
        class_params,
        f,
        false,
        &func.return_ty,
    );
}

fn loweredMemberTypeRef(
    module: *const Module,
    allocator: Allocator,
    owner: ?ir.ClassId,
    f: *const ast.Function,
    source: *const ast.TypeRef,
    own_names: bool,
) Allocator.Error!TypeRef {
    var ty = try loweredTypeRef(allocator, source, own_names);
    if (owner) |owner_id| {
        if (owner_id.int() < module.classes.items.len) {
            try rewriteClassOwnedTypeRef(
                allocator,
                owner_id,
                module.classes.items[owner_id.int()].type_params,
                f,
                own_names,
                &ty,
            );
        }
    }
    return ty;
}

fn memberOwnerIdForFunction(
    module: *const Module,
    owner_name: []const u8,
    f: *const ast.Function,
) ?ir.ClassId {
    if (module.funcByDeclSpan(f.name.span)) |reserved| {
        if (module.decl_sigs.get(reserved.int())) |sig| {
            if (sig.enclosing_class) |owner| return owner;
        }
    }
    if (std.mem.findScalar(u8, owner_name, '.') != null) {
        return module.classIdByFqn(owner_name);
    }
    return module.uniqueClassIdBySimpleName(owner_name);
}

/// The state each member-header reservation phase reads: the class whose
/// members are being reserved and the identity its stubs are filed under.
const HeaderReserve = struct {
    /// The registry allocator, owning every reserved header's storage.
    a: Allocator,
    module: *Module,
    c: *const ast.Class,
    class_fqn: []const u8,
    class_pkg: []const u8,
    owner_id: ?ClassId,
};

/// Reserve every member-function signature before any class body lowers, so the
/// declaration-span identity stays stable when the body replaces the stub and the
/// owner-scoped index retains the full overload set.
pub fn reserveMemberHeaders(
    module: *Module,
    c: *const ast.Class,
    class_fqn: []const u8,
    class_pkg: []const u8,
) Allocator.Error!void {
    const a = module.registry.allocator;
    const owner_id = module.classIdByFqn(class_fqn) orelse module.classId(c.name.name);
    try backfillOwnerTypeParams(module, a, c, owner_id);
    var ctx: HeaderReserve = .{
        .a = a,
        .module = module,
        .c = c,
        .class_fqn = class_fqn,
        .class_pkg = class_pkg,
        .owner_id = owner_id,
    };
    for (c.members) |*member| {
        if (member.* != .Function) continue;
        const f = &member.Function;
        if (module.funcByDeclSpan(f.name.span)) |id| {
            try module.registerMemberDecl(a, class_fqn, f.name.name, id);
            continue;
        }
        try reserveMemberHeader(&ctx, f);
    }
}

/// A shell registered before the source class was seen carries no type
/// parameters; fill them in from the declaration so member types resolve against
/// the owner's own names.
fn backfillOwnerTypeParams(
    module: *Module,
    a: Allocator,
    c: *const ast.Class,
    owner_id: ?ClassId,
) Allocator.Error!void {
    if (owner_id) |owner| {
        if (owner.int() < module.classes.items.len and
            module.classes.items[owner.int()].type_params.len == 0 and
            c.type_params.len != 0)
        {
            const names = try a.alloc([]const u8, c.type_params.len);
            const variances = try a.alloc(ast.Variance, c.type_params.len);
            for (c.type_params, names, variances) |*param, *name, *variance| {
                name.* = param.name.name;
                variance.* = param.variance;
            }
            module.classes.items[owner.int()].type_params = names;
            module.classes.items[owner.int()].type_param_variance = variances;
        }
    }
}

/// Reserve one member's header: a bodyless func slot plus every declaration
/// table member resolution consults before the body lowers.
fn reserveMemberHeader(ctx: *HeaderReserve, f: *const ast.Function) Allocator.Error!void {
    const decl_key = try memberDeclKey(ctx.a, ctx.c.name.name, f);

    const id = ctx.module.nextFuncId();
    const params = try reservedHeaderParams(ctx, f);
    try appendReservedHeaderFunc(ctx, f, id, params);
    try indexReservedHeader(ctx, f, id);
    try registerFuncTypeParams(ctx.module, f, id);
    try recordReservedHeaderDecl(ctx, f, id, decl_key);
    try recordReservedHeaderFid(ctx, f, id);
}

/// The header's parameter list: the synthesized receiver slot, then each source
/// parameter carrying its full structural type.
fn reservedHeaderParams(ctx: *HeaderReserve, f: *const ast.Function) Allocator.Error![]Param {
    const a = ctx.a;
    const module = ctx.module;
    const c = ctx.c;
    const owner_id = ctx.owner_id;
    const params = try a.alloc(Param, f.params.len + 1);
    params[0] = .{
        .name = "this",
        .ty = if (f.receiver_type) |*rt|
            try loweredMemberTypeRef(module, a, owner_id, f, rt, false)
        else blk: {
            const owner_args = try a.alloc(TypeRef, c.type_params.len);
            for (c.type_params, owner_args) |*param, *arg| {
                arg.* = .{
                    .name = if (owner_id) |owner|
                        try ir.classTypeParamIdentity(a, owner, param.name.name)
                    else
                        param.name.name,
                    .nullable = false,
                    .args = &.{},
                };
            }
            break :blk .{
                .name = ctx.class_fqn,
                .nullable = false,
                .args = owner_args,
            };
        },
        .default = null,
        .is_property = false,
        .is_vararg = false,
        .has_default = false,
    };
    for (f.params, 0..) |*p, i| {
        params[i + 1] = .{
            .name = p.name.name,
            .ty = renameParamHead(
                try loweredMemberTypeRef(
                    module,
                    a,
                    owner_id,
                    f,
                    &p.ty,
                    false,
                ),
                &p.ty,
            ),
            .default = null,
            .composable_arity = @import("compose_pass").composableFunctionArity(&p.ty),
            .composable_recv_slots = @import("compose_pass").composableFunctionRecvSlots(&p.ty),
            .is_property = false,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        };
    }
    return params;
}

/// Append the bodyless func the reserved id names, carrying the declaration's
/// modifiers so overload resolution ranks it before any body lowers.
fn appendReservedHeaderFunc(
    ctx: *HeaderReserve,
    f: *const ast.Function,
    id: FuncId,
    params: []Param,
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn = try std.fmt.allocPrint(a, "{s}.{s}", .{ ctx.class_fqn, f.name.name });
    const return_ty = if (f.return_type) |*rt|
        renameParamHead(try loweredMemberTypeRef(module, a, ctx.owner_id, f, rt, false), rt)
    else
        build.typeUnit();
    try module.appendFunc(.{
        .id = id,
        .name = f.name.name,
        .fqn = fqn,
        .package = ctx.class_pkg,
        .params = params,
        .return_ty = return_ty,
        .return_ty_declared = f.return_type != null,
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = f.is_suspend,
        .kind = if (f.receiver_type != null) .member_extension else .instance_method,
        .is_tailrec = f.is_tailrec,
        .has_receiver_param = true,
        .is_inline = f.is_inline,
        .low_priority = isLowPriorityOverload(f),
        .deprecated_error = annotationsAreDeprecatedError(f.annotations),
        .is_expect = f.is_expect,
        .is_override = f.is_override,
        .is_open = f.is_open,
        .is_final = f.is_final,
    });
}

/// File the reserved header in the name indexes: a member extension also answers
/// to its bare name, and every header answers to its declaration span.
fn indexReservedHeader(ctx: *HeaderReserve, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    if (f.receiver_type != null) {
        try module.func_index.append(a, .{ .name = f.name.name, .id = id });
        try funcNameIndexPush(module, f.name.name, id);
    }
    try module.recordFuncDeclSpan(a, f.name.span, id);
    if (f.receiver_type != null) {
        try module.registry.member_ext_owner_class.put(id, ctx.class_fqn);
        if (f.visibility == .Private) {
            try module.registry.private_fn_files.put(id, f.name.span.file);
        }
    }
}

/// Record the reserved header's declaration shape: arity, signature and the
/// owner-scoped overload index rows applicability reads.
fn recordReservedHeaderDecl(
    ctx: *HeaderReserve,
    f: *const ast.Function,
    id: FuncId,
    decl_key: []const u8,
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const owner_id = ctx.owner_id;
    var has_vararg = false;
    var required: u32 = 0;
    for (f.params) |*p| {
        if (p.is_vararg) has_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
    }
    const arity: Module.DeclArity = .{
        .required = required,
        .total = @intCast(f.params.len),
        .has_vararg = has_vararg,
    };
    const sig = try a.alloc(TypeRef, f.params.len);
    for (f.params, 0..) |*p, i| {
        sig[i] = try loweredMemberTypeRef(
            module,
            a,
            owner_id,
            f,
            &p.ty,
            true,
        );
    }
    try module.decl_user_params.put(id.int(), @intCast(f.params.len));
    try module.decl_user_arity.put(id.int(), arity);
    try module.decl_user_sig.put(id.int(), sig);
    try module.decl_sigs.put(id.int(), .{
        .enclosing_class = owner_id,
        .receiver_ty = if (f.receiver_type) |*rt|
            try loweredMemberTypeRef(module, a, owner_id, f, rt, true)
        else
            null,
        .arity = arity,
        .sig = sig,
        .kind = if (f.receiver_type != null) .member_extension else .instance_method,
        .visibility = f.visibility,
        .is_inline = f.is_inline,
        .is_suspend = f.is_suspend,
        .has_body = f.body != null,
    });
    try module.decl_span.put(id.int(), f.span);
    if (f.body != null) try module.decl_ast_body.put(id.int(), {});
    try module.registry.member_method_fids.put(decl_key, id);
    try module.registerMemberDecl(a, ctx.class_fqn, f.name.name, id);
}

/// Key the reserved header by (class, name, declared arity) so a body lowered
/// later in the same class reaches its signature.
fn recordReservedHeaderFid(ctx: *HeaderReserve, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const key = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ ctx.c.name.name, f.name.name, f.params.len });
    const gop = try ctx.module.registry.member_method_fids.getOrPut(key);
    if (gop.found_existing) {
        a.free(key);
    } else {
        gop.value_ptr.* = id;
    }
}

/// Names captured by the anonymous object whose method is being lowered. They reach
/// the method body as runtime-injected scoped globals, so a `recv.name()` naming one
/// dispatches as CallMemberOrValue with a `LoadGlobal(name)` fallback: the
/// receiver's member wins if present, else the captured callable is invoked.
threadlocal var lower_anon_captures: ?StringSet = null;

/// Install or clear the set of capture names used while lowering an anonymous
/// object's method bodies. Null clears it; takes ownership of `names`.
pub fn setLowerAnonCaptures(names: ?StringSet) void {
    if (lower_anon_captures) |*old| old.deinit();
    lower_anon_captures = names;
}

/// Hand the installed capture set back to the caller, ownership included, so a
/// nested lowering window can install its own and restore this one.
pub fn takeLowerAnonCaptures() ?StringSet {
    const cur = lower_anon_captures;
    lower_anon_captures = null;
    return cur;
}

pub fn isLowerAnonCapture(name: []const u8) bool {
    if (lower_anon_captures) |*c| return c.contains(name);
    return false;
}

/// Collect a class's own and inherited member names into `out`, walking every
/// supertype reachable through the file's class registry.
fn collectMembers(
    c: *const ast.Class,
    file_classes: *const FileClasses,
    out: *StringSet,
    seen: *StringSet,
) Allocator.Error!void {
    {
        const gop = try seen.getOrPut(c.name.name);
        if (gop.found_existing) return;
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                try out.put(f.name.name, {});
            },
            .Property => |p| {
                try out.put(p.name.name, {});
            },
            .Class => |*inner| {
                if (inner.is_companion) {
                    for (inner.members) |*cm| {
                        switch (cm.*) {
                            .Function => |*f| try out.put(f.name.name, {}),
                            .Property => |p| try out.put(p.name.name, {}),
                            else => {},
                        }
                    }
                    for (inner.primary_params) |*p| {
                        if (p.property != null) try out.put(p.name.name, {});
                    }
                }
            },
            else => {},
        }
    }
    for (c.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (c.supertypes) |*sup| {
        if (file_classes.get(sup.name.name)) |parent| {
            try collectMembers(parent.get(), file_classes, out, seen);
        }
    }
}

/// Bit `i` of a member's arity mask is set when some overload binds exactly `i` user
/// arguments, so member-vs-global resolution can be arity-aware. Bit 63: some
/// same-named member takes a vararg, so every arity binds.
pub const ARITY_MASK_VARARG: u64 = @as(u64, 1) << 63;
/// Bit 62: some same-named member declares type parameters. A call with explicit
/// type arguments can only be answered by such a member, so a name whose members all
/// lack them does not shadow a same-named top-level generic function.
pub const ARITY_MASK_TYPE_PARAMS: u64 = @as(u64, 1) << 62;

pub fn funcArityMask(f: *const ast.Function) u64 {
    var required: usize = 0;
    var any_vararg = false;
    for (f.params) |*p| {
        if (p.is_vararg) any_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
    }
    const tp: u64 = if (f.type_params.len != 0) ARITY_MASK_TYPE_PARAMS else 0;
    if (any_vararg) return ARITY_MASK_VARARG | tp;
    var mask: u64 = tp;
    // Every count from `required` up to the full parameter count binds, the
    // trailing defaulted params being omittable.
    var n = required;
    while (n <= f.params.len and n < 62) : (n += 1) mask |= @as(u64, 1) << @intCast(n);
    return mask;
}

pub fn mergeMemberArity(out: *std.StringHashMap(u64), name: []const u8, mask: u64) Allocator.Error!void {
    const gop = try out.getOrPut(name);
    if (gop.found_existing) gop.value_ptr.* |= mask else gop.value_ptr.* = mask;
}

fn collectMemberArities(
    c: *const ast.Class,
    file_classes: *const FileClasses,
    out: *std.StringHashMap(u64),
    seen: *StringSet,
) Allocator.Error!void {
    {
        const gop = try seen.getOrPut(c.name.name);
        if (gop.found_existing) return;
    }
    for (c.members) |*m| {
        if (m.* == .Function) try mergeMemberArity(out, m.Function.name.name, funcArityMask(&m.Function));
        // A property declared with a non-function type cannot bind a call, so record
        // an empty mask: the name is known but takes no arity, and a same-named
        // function overload ORs its own mask in.
        if (m.* == .Property) {
            if (m.Property.ty) |*pt| {
                if (pt.function == null and !isFunctionTypeName(pt.name.name)) try mergeMemberArity(out, m.Property.name.name, 0);
            }
        }
    }
    for (c.primary_params) |*p| {
        if (p.property == null) continue;
        if (p.ty.function == null and !isFunctionTypeName(p.ty.name.name)) try mergeMemberArity(out, p.name.name, 0);
    }
    for (c.supertypes) |*sup| {
        if (file_classes.get(sup.name.name)) |parent| {
            try collectMemberArities(parent.get(), file_classes, out, seen);
        }
    }
}

/// A declared type head that may denote something invokable: a function type
/// spelling, `Any`, a bare single-upper-case type parameter, or a `K*` reflection
/// type.
fn isFunctionTypeName(name: []const u8) bool {
    const head = std.mem.trimEnd(u8, name, "?");
    if (std.mem.startsWith(u8, head, "Function") or std.mem.startsWith(u8, head, "KFunction") or std.mem.startsWith(u8, head, "Suspend")) return true;
    if (std.mem.eql(u8, head, "Any") or std.mem.eql(u8, head, "Nothing")) return true;
    if (head.len <= 2 and head.len != 0 and std.ascii.isUpper(head[0])) return true;
    if (std.mem.startsWith(u8, head, "K") and head.len > 1 and std.ascii.isUpper(head[1])) return true;
    return false;
}

/// Add enum-entry, nested-class, and companion-member names that are visible under
/// their bare names inside the class's method bodies.
pub fn addVisibleMemberNames(
    c: *const ast.Class,
    own_member_names: *StringSet,
) Allocator.Error!void {
    // Enum entry names are visible bare inside the enum's method bodies, and
    // `entries` resolves to the synthesized list of all entries.
    if (c.is_enum) {
        for (c.enum_entries) |*entry| {
            try own_member_names.put(entry.name.name, {});
        }
        // Built-in members on every enum entry: synthesised `name` and `ordinal`.
        // Bare access from method bodies resolves to `this.name`/`this.ordinal`.
        try own_member_names.put("entries", {});
        try own_member_names.put("name", {});
        try own_member_names.put("ordinal", {});
    }
    // Nested class, enum and object names are visible bare inside the enclosing
    // class's method bodies.
    for (c.members) |*m| {
        if (m.* == .Class and !m.Class.is_companion) {
            try own_member_names.put(m.Class.name.name, {});
        }
    }
    // Companion-object members are visible bare inside this class's method bodies.
    for (c.members) |*m| {
        if (m.* == .Class and m.Class.is_companion) {
            const inner = &m.Class;
            for (inner.members) |*cm| {
                switch (cm.*) {
                    .Function => |*f| try own_member_names.put(f.name.name, {}),
                    .Property => |p| try own_member_names.put(p.name.name, {}),
                    else => {},
                }
            }
            for (inner.primary_params) |*p| {
                if (p.property != null) try own_member_names.put(p.name.name, {});
            }
        }
    }
}

/// Lower the default-arg thunks of a bodyless method and stash them under
/// `(class, method)` so a concrete override inherits the declaration's defaults.
fn recordAbstractMemberDefaults(
    module: *Module,
    c: *const ast.Class,
    f: *const ast.Function,
) Allocator.Error!void {
    var any_default = false;
    for (f.params) |*p| {
        if (p.default != null) any_default = true;
    }
    if (!any_default) return;

    const a = module.registry.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.append(a, "this");
    for (f.params) |*p| try names.append(a, p.name.name);
    const name_refs = names.items;

    var slots: std.ArrayList(?FuncId) = .empty;
    errdefer slots.deinit(a);
    try slots.append(a, null); // implicit `this`
    for (f.params, 0..) |*p, idx| {
        if (p.default) |de| {
            const bind_upto = @min(1 + idx, name_refs.len);
            var widened = mod.widenNumericLiteral(de, &p.ty);
            const expr_ptr: *const ast.Expr = if (widened) |*w| w else de;
            const thunk_name = try std.fmt.allocPrint(
                a,
                "__default_abstract_{s}_{s}",
                .{ f.name.name, p.name.name },
            );
            const fid = try mod.lowerExprAsParamThunk(
                module,
                name_refs[0..bind_upto],
                expr_ptr,
                thunk_name,
            );
            try slots.append(a, fid);
        } else {
            try slots.append(a, null);
        }
    }
    // Reserved member headers have stable declaration identities before body
    // lowering, so attach defaults to that exact identity: overloaded abstract
    // methods never share a class/name bucket, and virtual slot roots bind defaults
    // without a source-level lookup.
    if (module.funcByDeclSpan(f.name.span)) |fid| {
        var exact: std.ArrayList(?FuncId) = .empty;
        try exact.appendSlice(a, slots.items);
        const gop = try module.registry.local_fn_defaults.getOrPut(fid);
        if (gop.found_existing) gop.value_ptr.deinit(a);
        gop.value_ptr.* = exact;
    }

    const key = ir.StrPair{ .a = c.name.name, .b = f.name.name };
    try module.registry.abstract_member_defaults.put(key, slots);
}

/// Like `lowerClassWithFile` but mixes an additional set of member names into the
/// class's `own_members`, for a nested class lifted to top level, so bare references
/// inside the inner's body lower as `this.X` against the captured outer.
/// `lowerPrimaryParams` lowers a class's primary-constructor parameters, exposed so
/// a build pre-pass can fill every class's `primary_params` before any method body
/// lowers: a call to a forward-declared class needs its parameter types for
/// trailing-lambda realignment.
pub fn classPrimaryParams(a: Allocator, c: *const ast.Class) Allocator.Error![]Param {
    var primary_params: std.ArrayList(Param) = .empty;
    errdefer primary_params.deinit(a);
    for (c.primary_params) |*p| {
        try primary_params.append(a, .{
            .name = p.name.name,
            // Preserve the lowered parameter type, notably a `Function{N}` head for
            // a `T.() -> R` param, so an argument lambda reads its expected arity.
            .ty = renameParamHead(try loweredTypeRef(a, &p.ty, false), &p.ty),
            .default = null,
            .composable_arity = @import("compose_pass").composableFunctionArity(&p.ty),
                .composable_recv_slots = @import("compose_pass").composableFunctionRecvSlots(&p.ty),
            .is_property = p.property != null,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        });
    }
    return primary_params.toOwnedSlice(a);
}

/// The mangled name an `internal` package-renamed classifier resolves to when
/// referenced from another package through an import of its declaring package;
/// internal visibility spans the whole module, so the reference must follow it.
pub fn importedPkgTypeRename(module: *const Module, name: []const u8, file: ir.FileId) ?[]const u8 {
    if (module.registry.import_wildcards.get(file)) |packages| {
        for (packages.items) |pkg| {
            if (build.pkgTypeRename(name, pkg)) |rn| return rn;
        }
    }
    if (module.registry.import_aliases.get(file)) |m| {
        if (m.get(name)) |paths| {
            for (paths.items) |p| {
                if (std.mem.findScalarLast(u8, p.fqn, '.')) |dot| {
                    if (build.pkgTypeRename(name, p.fqn[0..dot])) |rn| return rn;
                }
            }
        }
    }
    return null;
}

/// Resolve and install a class's nominal superclass edges after every class shell
/// is reserved, so method bodies see the complete hierarchy regardless of order.
pub fn populateClassSupertypes(
    module: *Module,
    c: *const ast.Class,
    class_fqn: []const u8,
    class_pkg: []const u8,
) Allocator.Error!void {
    const a = module.registry.allocator;
    var supertypes: std.ArrayList(ClassId) = .empty;
    errdefer supertypes.deinit(a);
    var supertype_refs: std.ArrayList(TypeRef) = .empty;
    errdefer supertype_refs.deinit(a);
    for (c.supertypes) |*t| {
        if (t.qualified_path) |qp| {
            if (module.classIdByQualifiedSuffix(qp)) |cid| {
                try supertypes.append(a, cid);
                try supertype_refs.append(a, try loweredTypeRef(a, t, false));
                continue;
            }
        }
        // A package-mangled `internal` classifier follows the rename: its own
        // file's map, its package's map, then an import of the declaring package.
        const sup_name = build.fileOrPkgTypeRename(t.name.name, t.name.span.file.int()) orelse
            importedPkgTypeRename(module, t.name.name, t.name.span.file) orelse
            t.name.name;
        if (module.classIdIndexed(sup_name, class_pkg, t.name.span.file)) |cid| {
            try supertypes.append(a, cid);
            try supertype_refs.append(a, try loweredTypeRef(a, t, false));
        }
    }
    const class_id = module.classIdByFqn(class_fqn) orelse return;
    if (class_id.int() >= module.classes.items.len) return;
    const slot = &module.classes.items[class_id.int()];
    slot.supertypes = try supertypes.toOwnedSlice(a);
    slot.supertype_refs = try supertype_refs.toOwnedSlice(a);
}

/// The state every class-member lowering phase reads: the class being lowered,
/// its registered shell, and the tables its member bodies resolve against.
const ClassLower = struct {
    /// The registry allocator, owning everything the lowered class keeps.
    a: Allocator,
    module: *Module,
    c: *const ast.Class,
    class_id: ClassId,
    extra_members: *const StringSet,
    own_member_names: *StringSet,
    own_member_arity: *std.StringHashMap(u64),
    /// The class's method list, sealed onto the shell once every member lowers.
    methods: *std.ArrayList(FuncId),
};

pub fn lowerClassWithExtras(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    extra_members: *const StringSet,
) Allocator.Error!ClassId {
    const a = module.registry.allocator;

    const class_id = try registerClassShell(module, a, c);

    // Collect this class's own member names so method-body lowering can tell
    // `someMember()` from `topLevelFn()`. The lexically enclosing class's members
    // stay separate: they belong to an enclosing `this@Outer`, reached only through
    // the implicit-receiver candidate walk. Routing them through the candidate
    // resolver matches kotlinc, which searches the inner's own `this` then its
    // `outer` links, while a subject brings only itself.
    var own_member_names = StringSet.init(a);
    defer own_member_names.deinit();
    try collectOwnMemberNames(a, c, file_classes, &own_member_names);
    // Per-member arity masks, so a method body's bare call prefers a member only
    // when one is arity-applicable.
    var own_member_arity = std.StringHashMap(u64).init(a);
    defer own_member_arity.deinit();
    try collectOwnMemberArities(a, c, file_classes, &own_member_arity);

    var methods: std.ArrayList(FuncId) = .empty;
    errdefer methods.deinit(a);

    var ctx: ClassLower = .{
        .a = a,
        .module = module,
        .c = c,
        .class_id = class_id,
        .extra_members = extra_members,
        .own_member_names = &own_member_names,
        .own_member_arity = &own_member_arity,
        .methods = &methods,
    };

    for (c.members) |*m| {
        if (m.* == .Function) {
            const f = &m.Function;
            // Skip bodyless methods: they would lower to a func returning Unit, and
            // IR-native member dispatch must fall through to the real override.
            if (f.body == null) {
                try retainBodylessMember(&ctx, f);
                continue;
            }
            try lowerConcreteMember(&ctx, f);
        }
    }
    try lowerDataClassComponents(&ctx);
    // Patch the registered class with its now-known method list.
    if (class_id.int() < module.classes.items.len) {
        const slot = &module.classes.items[class_id.int()];
        slot.methods = try methods.toOwnedSlice(a);
    }
    return class_id;
}

/// Register the class shell first so the class name resolves inside its own
/// method bodies.
fn registerClassShell(module: *Module, a: Allocator, c: *const ast.Class) Allocator.Error!ClassId {
    const class_type_params = try a.alloc([]const u8, c.type_params.len);
    for (c.type_params, class_type_params) |*param, *out| out.* = param.name.name;
    const class_type_param_variance = try a.alloc(ast.Variance, c.type_params.len);
    for (c.type_params, class_type_param_variance) |*param, *out| out.* = param.variance;

    const class_fqn = lower_class_fqn orelse c.name.name;
    const class_id = try module.addClass(a, .{
        .id = ClassId.from(0),
        .name = c.name.name,
        .fqn = class_fqn,
        .package = lower_class_pkg orelse ir.packageOfFqn(class_fqn, c.name.name),
        .primary_params = try classPrimaryParams(a, c),
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
        .type_params = class_type_params,
        .type_param_variance = class_type_param_variance,
        .supertype_refs = &.{},
        .is_inner = c.is_inner,
        .is_abstract = c.is_abstract or c.is_interface or c.is_sealed,
        .is_interface = c.is_interface,
        .is_fun_interface = c.is_fun_interface,
        .is_open = c.is_open,
        .is_enum = c.is_enum,
        .has_primary_ctor = c.has_primary_ctor,
        .is_annotation = c.is_annotation,
        .is_value = c.is_value,
        .receiver_abi = runtime.classifierReceiverAbi(class_fqn),
    });
    if (!module.registry.class_type_param_bounds.contains(class_fqn)) {
        if (try loweredClassTypeParamBounds(a, c)) |bounds| {
            try module.registry.class_type_param_bounds.put(class_fqn, bounds);
        }
    }
    try populateClassSupertypes(
        module,
        c,
        class_fqn,
        lower_class_pkg orelse ir.packageOfFqn(class_fqn, c.name.name),
    );
    return class_id;
}

/// Walk this class and every supertype reachable through the file's class
/// registry so inherited member names also route as `this.<name>`.
fn collectOwnMemberNames(
    a: Allocator,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    own_member_names: *StringSet,
) Allocator.Error!void {
    var seen_for_collect = StringSet.init(a);
    defer seen_for_collect.deinit();
    try collectMembers(c, file_classes, own_member_names, &seen_for_collect);
    try addVisibleMemberNames(c, own_member_names);
}

/// The same supertype walk, recording each member's arity mask.
fn collectOwnMemberArities(
    a: Allocator,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    own_member_arity: *std.StringHashMap(u64),
) Allocator.Error!void {
    var seen_for_arity = StringSet.init(a);
    defer seen_for_arity.deinit();
    try collectMemberArities(c, file_classes, own_member_arity, &seen_for_arity);
}

/// A bodyless member declares a slot without filling it. Record what dispatch
/// and SAM conversion still need from the declaration, and retain a header row
/// where the declaration names a host-backed API.
fn retainBodylessMember(ctx: *ClassLower, f: *const ast.Function) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const c = ctx.c;
    // The abstract slot is skipped, but a concrete `override` inherits
    // its default-arg values, so lower the thunks and stash them by
    // (class, method) for the build pass to fold onto the override.
    try recordAbstractMemberDefaults(module, c, f);
    try recordAbstractMemberArity(ctx, f);
    // An abstract member-extension declaration records its
    // extension-receiver type head, which a SAM conversion of the fun
    // interface binds as the lambda's implicit `this`.
    if (f.receiver_type) |*rt| {
        try module.registry.iface_member_ext_recv.put(.{ .a = c.name.name, .b = f.name.name }, rt.name.name);
    }
    // Likewise its `context(...)` parameter types, which the SAM
    // dispatch resolves from the call site's context scope.
    if (f.context_params.len != 0) {
        var joined: std.ArrayList(u8) = .empty;
        for (f.context_params, 0..) |*cp, ci| {
            if (ci != 0) try joined.append(a, '|');
            try joined.appendSlice(a, cp.ty.name.name);
        }
        try module.registry.iface_member_ctx_types.put(.{ .a = c.name.name, .b = f.name.name }, try joined.toOwnedSlice(a));
    }
    // A bodyless expect-class member is the declaration of a host-backed
    // API, retained as a header row whose decl sig names its member fqn
    // as the host symbol. The link step joins the intrinsic where one
    // exists, and member resolution binds the call statically.
    if (c.is_expect and f.receiver_type == null) {
        if (runtime.envOnce("KLIO_EXPECT_HDR_TRACE") != null)
            std.debug.print("[expect-hdr] {s}.{s} class_fqn={s}\n", .{ c.name.name, f.name.name, lower_class_fqn orelse "-" });
        if (try retainExpectMemberHeader(module, c, f, ctx.class_id)) |hid| {
            try ctx.methods.append(a, hid);
        }
    }
}

/// Record the declared arity so overload picks ranking members above
/// extensions see the bodyless slot; defaulted params widen the mask
/// down to the min arity.
fn recordAbstractMemberArity(ctx: *ClassLower, f: *const ast.Function) Allocator.Error!void {
    var defaults_n: usize = 0;
    for (f.params) |*fp| {
        if (fp.default != null) defaults_n += 1;
    }
    const hi: u6 = @intCast(@min(f.params.len, 63));
    const lo: u6 = @intCast(@min(f.params.len - defaults_n, 63));
    var mask: u64 = 0;
    var ar: u6 = lo;
    while (true) : (ar += 1) {
        mask |= @as(u64, 1) << ar;
        if (ar == hi) break;
    }
    const gop2 = try ctx.module.registry.abstract_member_arity.getOrPut(.{ .a = ctx.c.name.name, .b = f.name.name });
    if (gop2.found_existing) gop2.value_ptr.* |= mask else gop2.value_ptr.* = mask;
}

/// Lower a member that has a body, then index it by the routes member
/// resolution reads.
fn lowerConcreteMember(ctx: *ClassLower, f: *const ast.Function) Allocator.Error!void {
    // Use the method's own FuncId, not `funcs.len() - 1`: lowering a method
    // also pushes its default-arg thunk funcs.
    const placed = try lowerMethodWithMemberContext(
        ctx.module,
        f,
        ctx.c.name.name,
        ctx.own_member_names,
        ctx.extra_members,
        ctx.own_member_arity,
    );
    try ctx.methods.append(ctx.a, placed.id);
    try recordMemberMethodFid(ctx, f.name.name, f.params.len, placed.id);
    try recordMemberDeclSig(ctx, f, placed.id);
}

/// Record this method by (class, name, declared arity) so a sibling body
/// lowered later reaches its signature, owner-scoped so an unrelated
/// class's namesake is never mistaken for it.
fn recordMemberMethodFid(
    ctx: *ClassLower,
    name: []const u8,
    arity: usize,
    id: FuncId,
) Allocator.Error!void {
    const a = ctx.a;
    const ukey = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ ctx.c.name.name, name, arity });
    const gop = try ctx.module.registry.member_method_fids.getOrPut(ukey);
    if (gop.found_existing) {
        a.free(ukey);
    } else {
        gop.value_ptr.* = id;
    }
}

/// Unified declaration record: the member half of the canonical index,
/// the split `decl_user_*` tables covering only top-level declarations.
fn recordMemberDeclSig(ctx: *ClassLower, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    if (module.decl_sigs.contains(id.int())) return;
    var has_vararg = false;
    var required: u32 = 0;
    for (f.params) |*p| {
        if (p.is_vararg) has_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
    }
    const msig = try a.alloc(ir.TypeRef, f.params.len);
    for (f.params, 0..) |*p, i| {
        msig[i] = try loweredTypeRef(a, &p.ty, true);
    }
    try module.decl_sigs.put(id.int(), .{
        .enclosing_class = ctx.class_id,
        .receiver_ty = if (f.receiver_type) |*rt| try loweredTypeRef(a, rt, true) else null,
        .arity = .{ .required = required, .total = @intCast(f.params.len), .has_vararg = has_vararg },
        .sig = msig,
        .kind = if (f.receiver_type != null) .member_extension else .instance_method,
        .visibility = f.visibility,
        .is_inline = f.is_inline,
        .is_suspend = f.is_suspend,
        .has_body = true,
    });
}

/// A data class's `componentN` accessors are members of the class, and member
/// resolution walks declarations, so without declaring them the call falls
/// through to extension lookup. Declaring them also gives each accessor its
/// property's declared return type.
fn lowerDataClassComponents(ctx: *ClassLower) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const c = ctx.c;
    if (!c.is_data) return;
    for (c.primary_params, 0..) |*p, idx| {
        if (p.property == null) continue;
        const cname = try std.fmt.allocPrint(a, "component{d}", .{idx + 1});
        if (declaresNullaryMember(c, cname)) {
            a.free(cname);
            continue;
        }
        const syn = try synthesizeComponentAccessor(a, p, cname);
        const placed = try lowerMethodWithMemberContext(
            module,
            syn,
            c.name.name,
            ctx.own_member_names,
            ctx.extra_members,
            ctx.own_member_arity,
        );
        try ctx.methods.append(a, placed.id);
        // Member resolution reads the owner-scoped overload index, not the
        // class's method list, so the accessor has to land there too.
        if (ctx.class_id.int() < module.classes.items.len) {
            try module.registerMemberDecl(a, module.classes.items[ctx.class_id.int()].fqn, cname, placed.id);
        }
        try recordMemberMethodFid(ctx, cname, 0, placed.id);
        if (!module.decl_sigs.contains(placed.id.int())) {
            try module.decl_sigs.put(placed.id.int(), .{
                .enclosing_class = ctx.class_id,
                .receiver_ty = null,
                .arity = .{ .required = 0, .total = 0, .has_vararg = false },
                .sig = &.{},
                .kind = .instance_method,
                .visibility = p.visibility,
                .is_inline = false,
                .is_suspend = false,
                .has_body = true,
            });
        }
    }
}

/// Build the `componentN` accessor declaration: a nullary operator returning
/// `this.<property>`.
fn synthesizeComponentAccessor(
    a: Allocator,
    p: *const ast.ClassParam,
    cname: []const u8,
) Allocator.Error!*ast.Function {
    const recv = try a.create(ast.Expr);
    recv.* = .{ .This = .{ .qualifier = null, .span = p.span } };
    const syn = try a.create(ast.Function);
    syn.* = .{
        .name = .{ .name = cname, .span = p.name.span },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = p.ty,
        .body = .{ .Expr = .{ .Member = .{
            .receiver = recv,
            .name = p.name,
            .safe = false,
            .span = p.span,
        } } },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = true,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        // Kotlin gives the accessor the property's own visibility.
        .visibility = p.visibility,
        .annotations = &.{},
        .span = p.span,
    };
    return syn;
}

/// Lower one AST function into an IR Func: the body lowers into the entry block,
/// parameters bind via `bindParams`, and the trailing implicit return falls through
/// to a `Return` terminator.
pub fn lowerFunction(module: *Module, f: *const ast.Function) Allocator.Error!Func {
    var empty = FileClasses.init(module.registry.allocator);
    defer empty.deinit();
    return lowerFunctionWithFile(module, f, &empty);
}

pub fn lowerFunctionWithFile(
    module: *Module,
    f: *const ast.Function,
    file_classes: *const FileClasses,
) Allocator.Error!Func {
    const a = module.registry.allocator;
    const func = try lowerFunctionBody(module, f, file_classes);
    const id = module.nextFuncId();
    var placed = func;
    placed.id = id;
    try module.recordFuncDeclSpan(a, f.name.span, id);
    if (f.visibility == .Private) {
        try module.registry.private_fn_files.put(id, f.name.span.file);
    }
    const nm = f.name.name;
    try module.func_index.append(a, .{ .name = nm, .id = id });
    try funcNameIndexPush(module, nm, id);
    try module.appendFunc(placed);
    return placed;
}

/// Lower a function body without registering it in `module.func_index`, so a
/// function's `FuncId` can be reserved first, enabling forward references and
/// mutual recursion.
pub fn lowerFunctionBodyInto(
    module: *Module,
    f: *const ast.Function,
    file_classes: *const FileClasses,
) Allocator.Error!Func {
    return lowerFunctionBody(module, f, file_classes);
}

/// Lowered name for a parameter's declared type. A function type `(A, B) -> R` is
/// tagged `Function2`, the arity excluding a receiver, so runtime overload
/// resolution can match a lambda argument by parameter count.
pub fn loweredTypeName(allocator: Allocator, ty: *const ast.TypeRef) Allocator.Error![]const u8 {
    if (ty.function) |ft| {
        return std.fmt.allocPrint(allocator, "Function{d}", .{ft.params.len});
    }
    return ty.name.name;
}

/// The erased names a class inherits from a function-type supertype: `Function{p}`
/// in the receiver-excluded convention, `Function{p+1}` for a receiver form, and
/// the `SuspendFunction` twins of both for a suspend type.
pub fn functionSupertypeTags(allocator: Allocator, ft: *const ast.FunctionTypeRef) Allocator.Error![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer tags.deinit(allocator);
    const p = ft.params.len;
    try tags.append(allocator, try std.fmt.allocPrint(allocator, "Function{d}", .{p}));
    if (ft.receiver != null) try tags.append(allocator, try std.fmt.allocPrint(allocator, "Function{d}", .{p + 1}));
    if (ft.is_suspend) {
        try tags.append(allocator, try std.fmt.allocPrint(allocator, "SuspendFunction{d}", .{p}));
        if (ft.receiver != null) try tags.append(allocator, try std.fmt.allocPrint(allocator, "SuspendFunction{d}", .{p + 1}));
    }
    return tags.toOwnedSlice(allocator);
}

/// Lowered structural form of a declared type: the head keeps `loweredTypeName`'s
/// rendering, so runtime overload matching is unchanged, while `args` carries the
/// full recursive shape. Source facts with no head-name slot become synthetic
/// marker args (`#suspend`, `#non-null`, `#qual:a.b.C`, `*`, an `in#`/`out#` head
/// prefix), so two parameter lists prove identical only when the declared types
/// really are. With `own_names` every string is duped into `allocator` so the
/// result can be deep-freed; body params borrow the AST names.
/// `applyFileScopedHeadRename` rewrites only the top-level head of a lowered
/// parameter type to the `$f{fid}` mangle of a file-private or internal classifier,
/// keyed by the source reference's own span file, so a member param typed as a
/// file-private `typealias` carries the name the alias registration holds. Scoped
/// to nominal, non-qualified heads so it cannot disturb the structural type.
pub fn renameParamHead(ty: ir.TypeRef, src: *const ast.TypeRef) ir.TypeRef {
    if (src.function != null or src.qualified_path != null) return ty;
    var out = ty;
    out.name = build.fileOrPkgTypeRename(ty.name, src.span.file.int()) orelse ty.name;
    return out;
}

pub fn loweredTypeRef(allocator: Allocator, ty: *const ast.TypeRef, own_names: bool) Allocator.Error!ir.TypeRef {
    var args: std.ArrayList(ir.TypeRef) = .empty;
    errdefer {
        if (own_names) {
            for (args.items) |*arg| arg.deinit(allocator);
        }
        args.deinit(allocator);
    }
    var head: []const u8 = undefined;
    var head_owned = false;
    errdefer if (head_owned) allocator.free(head);
    if (ty.function) |ft| {
        head = try std.fmt.allocPrint(allocator, "Function{d}", .{ft.params.len});
        head_owned = true;
        if (ft.is_suspend) {
            var marker = try markerRef(allocator, "#suspend", own_names);
            errdefer if (own_names) marker.deinit(allocator);
            try args.append(allocator, marker);
        }
        if (ft.receiver) |*recv| {
            var receiver = try loweredTypeRef(allocator, recv, own_names);
            errdefer if (own_names) receiver.deinit(allocator);
            try args.append(allocator, receiver);
        }
        for (ft.params) |*p| {
            var param = try loweredTypeRef(allocator, p, own_names);
            errdefer if (own_names) param.deinit(allocator);
            try args.append(allocator, param);
        }
        var ret = try loweredTypeRef(allocator, &ft.ret, own_names);
        errdefer if (own_names) ret.deinit(allocator);
        try args.append(allocator, ret);
    } else {
        head = if (own_names) try allocator.dupe(u8, ty.name.name) else ty.name.name;
        head_owned = own_names;
        for (ty.type_args) |*ta| {
            var arg = try loweredTypeArg(allocator, ta, own_names);
            errdefer if (own_names) arg.deinit(allocator);
            try args.append(allocator, arg);
        }
    }
    if (ty.definitely_non_null) {
        var marker = try markerRef(allocator, "#non-null", own_names);
        errdefer if (own_names) marker.deinit(allocator);
        try args.append(allocator, marker);
    }
    if (ty.qualified_path) |qp| {
        var marker = ir.TypeRef{
            .name = try std.fmt.allocPrint(allocator, "#qual:{s}", .{qp}),
            .nullable = false,
            .args = &.{},
        };
        errdefer if (own_names) marker.deinit(allocator);
        try args.append(allocator, marker);
    }
    return .{ .name = head, .nullable = ty.nullable, .args = try args.toOwnedSlice(allocator) };
}

fn loweredTypeArg(allocator: Allocator, ta: *const ast.TypeArg, own_names: bool) Allocator.Error!ir.TypeRef {
    if (ta.is_star) return markerRef(allocator, "*", own_names);
    var lowered = try loweredTypeRef(allocator, &ta.ty, own_names);
    errdefer if (own_names) lowered.deinit(allocator);
    const prefix: ?[]const u8 = switch (ta.variance) {
        .Invariant => null,
        .In => "in#",
        .Out => "out#",
    };
    if (prefix) |p| {
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ p, lowered.name });
        if (own_names) allocator.free(lowered.name);
        lowered.name = combined;
    }
    return lowered;
}

fn markerRef(allocator: Allocator, name: []const u8, own_names: bool) Allocator.Error!ir.TypeRef {
    return .{
        .name = if (own_names) try allocator.dupe(u8, name) else name,
        .nullable = false,
        .args = &.{},
    };
}

/// Collect an extension receiver's own and inherited member names, walking
/// supertypes reachable through the file's class registry.
fn collectRecvMembers(
    c: *const ast.Class,
    file_classes: *const FileClasses,
    out: *StringSet,
    seen: *StringSet,
) Allocator.Error!void {
    {
        const gop = try seen.getOrPut(c.name.name);
        if (gop.found_existing) return;
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| try out.put(f.name.name, {}),
            .Property => |p| try out.put(p.name.name, {}),
            else => {},
        }
    }
    for (c.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (c.supertypes) |*sup| {
        if (file_classes.get(sup.name.name)) |parent| {
            try collectRecvMembers(parent.get(), file_classes, out, seen);
        }
    }
}

pub fn lowerFunctionBody(
    module: *Module,
    f: *const ast.Function,
    file_classes: *const FileClasses,
) Allocator.Error!Func {
    const a = module.registry.allocator;
    const prev_sde = ir.setSuppressDeprecationError(
        annotationsSuppressDeprecationError(f.annotations),
    );
    defer _ = ir.setSuppressDeprecationError(prev_sde);
    // Extension functions need `this` bound as the implicit first param so the
    // body's `this` and `this.x` references resolve through the receiver reg.
    if (f.receiver_type) |recv| {
        var members = StringSet.init(a);
        defer members.deinit();
        if (file_classes.get(recv.name.name)) |parent_cls| {
            var seen = StringSet.init(a);
            defer seen.deinit();
            try collectRecvMembers(parent_cls.get(), file_classes, &members, &seen);
        }
        // The receiver type is usually declared in another file, and the module
        // registry carries each type's transitive member-function names regardless
        // of declaring file, so a bare call to a receiver member resolves to it: an
        // implicit-receiver member shadows a same-named top-level function.
        if (module.registry.hierarchy_methods.get(recv.name.name)) |hm| {
            var it = hm.keyIterator();
            while (it.next()) |k| try members.put(k.*, {});
        }
        const implicit = [_][]const u8{"this"};
        var func = try lowerFunctionBodyWithImplicitOwner(module, f, &implicit, null, &members);
        func.kind = .top_level_extension;
        return func;
    } else {
        return lowerFunctionBodyWithImplicitOwner(module, f, &.{}, null, null);
    }
}

/// Record a class method's per-parameter default-arg thunks under its body `FuncId`,
/// so a call omitting trailing defaulted args gets them filled. Methods carry an
/// implicit leading `this`, so default slots are offset by one.
pub fn recordMethodParamDefaults(
    module: *Module,
    f: *const ast.Function,
    body_func: FuncId,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
) Allocator.Error!void {
    var any_default = false;
    for (f.params) |*p| {
        if (p.default != null) any_default = true;
    }
    if (!any_default) return;

    const a = module.registry.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.append(a, "this");
    for (f.params) |*p| try names.append(a, p.name.name);
    const name_refs = names.items;

    var slots: std.ArrayList(?FuncId) = .empty;
    errdefer slots.deinit(a);
    try slots.append(a, null); // implicit `this`
    for (f.params, 0..) |*p, idx| {
        if (p.default) |default_expr| {
            const bind_upto = @min(1 + idx, name_refs.len);
            var widened = mod.widenNumericLiteral(default_expr, &p.ty);
            const expr_ptr: *const ast.Expr = if (widened) |*w| w else default_expr;
            const thunk_name = try std.fmt.allocPrint(
                a,
                "__default_method_{s}_{s}",
                .{ f.name.name, p.name.name },
            );
            // Pass the owner class and own-member set so a default expression naming
            // an enclosing-class member routes through `this.<member>` instead of an
            // unresolved global lookup.
            const fid = try mod.lowerExprAsParamThunkScoped(
                module,
                name_refs[0..bind_upto],
                expr_ptr,
                thunk_name,
                owner_class,
                own_members,
            );
            try slots.append(a, fid);
        } else {
            try slots.append(a, null);
        }
    }
    try module.registry.local_fn_defaults.put(body_func, slots);
}

/// Retain a bodyless expect-class member as a header row: a Func with the declared
/// signature and no body, its decl sig carrying the member fqn as the host symbol.
/// The link step joins the intrinsic where one exists; member resolution binds the
/// call statically either way.
fn retainExpectMemberHeader(
    module: *Module,
    c: *const ast.Class,
    f: *const ast.Function,
    class_id: ir.ClassId,
) Allocator.Error!?FuncId {
    const a = module.registry.allocator;
    const class_fqn = lower_class_fqn orelse return null;
    const member_fqn = try std.fmt.allocPrint(a, "{s}.{s}", .{ class_fqn, f.name.name });
    // One header per (class, name, arity); a prior declaration wins.
    const ukey = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ c.name.name, f.name.name, f.params.len });
    if (module.registry.member_method_fids.contains(ukey)) {
        a.free(ukey);
        a.free(member_fqn);
        return null;
    }
    const id = module.nextFuncId();
    const params = try a.alloc(ir.Param, f.params.len + 1);
    params[0] = .{
        .name = "this",
        .ty = .{ .name = c.name.name, .nullable = false, .args = &.{} },
        .default = null,
        .is_property = false,
        .is_vararg = false,
        .has_default = false,
    };
    var has_vararg = false;
    var required: u32 = 0;
    for (f.params, 0..) |*p, i| {
        if (p.is_vararg) has_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
        params[i + 1] = .{
            .name = p.name.name,
            .ty = try loweredTypeRef(a, &p.ty, true),
            .default = null,
            .is_property = false,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        };
    }
    const ret: ir.TypeRef = if (f.return_type) |*rt|
        try loweredTypeRef(a, rt, true)
    else
        .{ .name = "Unit", .nullable = false, .args = &.{} };
    try module.appendFunc(.{
        .id = id,
        .name = f.name.name,
        .fqn = member_fqn,
        .package = ir.packageOfFqn(class_fqn, c.name.name),
        .params = params,
        .return_ty = ret,
        .return_ty_declared = f.return_type != null,
        .n_locals = 0,
        .blocks = &.{},
        .entry = @enumFromInt(0),
        .is_suspend = f.is_suspend,
        .kind = .instance_method,
    });
    const msig = try a.alloc(ir.TypeRef, f.params.len);
    for (f.params, 0..) |*p, i| {
        msig[i] = try loweredTypeRef(a, &p.ty, true);
    }
    try module.decl_sigs.put(id.int(), .{
        .enclosing_class = class_id,
        .receiver_ty = null,
        .arity = .{ .required = required, .total = @intCast(f.params.len), .has_vararg = has_vararg },
        .sig = msig,
        .kind = .instance_method,
        .visibility = f.visibility,
        .is_inline = false,
        .is_suspend = f.is_suspend,
        .has_body = false,
        .host_symbol = member_fqn,
    });
    try module.registry.member_method_fids.put(ukey, id);
    try funcNameIndexPush(module, f.name.name, id);
    return id;
}

/// A local class's method as a bodyless header under its function-scoped mangled
/// owner, so a member call on a local-class-typed receiver binds this virtual slot
/// at lowering; the runtime slot's by-name fallback executes the real method.
pub fn retainLocalClassMemberHeader(
    module: *Module,
    mangled_owner: []const u8,
    f: *const ast.Function,
) Allocator.Error!void {
    const a = module.registry.allocator;
    const ukey = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ mangled_owner, f.name.name, f.params.len });
    if (module.registry.member_method_fids.contains(ukey)) {
        a.free(ukey);
        return;
    }
    const id = module.nextFuncId();
    const member_fqn = try std.fmt.allocPrint(a, "{s}.{s}", .{ mangled_owner, f.name.name });
    const params = try a.alloc(ir.Param, f.params.len + 1);
    params[0] = .{
        .name = "this",
        .ty = .{ .name = mangled_owner, .nullable = false, .args = &.{} },
        .default = null,
        .is_property = false,
        .is_vararg = false,
        .has_default = false,
    };
    var has_vararg = false;
    var required: u32 = 0;
    for (f.params, 0..) |*p, i| {
        if (p.is_vararg) has_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
        params[i + 1] = .{
            .name = p.name.name,
            .ty = try loweredTypeRef(a, &p.ty, true),
            .default = null,
            .is_property = false,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        };
    }
    const ret: ir.TypeRef = if (f.return_type) |*rt|
        try loweredTypeRef(a, rt, true)
    else
        .{ .name = "Unit", .nullable = false, .args = &.{} };
    try module.appendFunc(.{
        .id = id,
        .name = f.name.name,
        .fqn = member_fqn,
        .package = "",
        .params = params,
        .return_ty = ret,
        .return_ty_declared = f.return_type != null,
        .n_locals = 0,
        .blocks = &.{},
        .entry = @enumFromInt(0),
        .is_suspend = f.is_suspend,
        .kind = .instance_method,
    });
    const msig = try a.alloc(ir.TypeRef, f.params.len);
    for (f.params, 0..) |*p, i| {
        msig[i] = try loweredTypeRef(a, &p.ty, true);
    }
    try module.decl_sigs.put(id.int(), .{
        .enclosing_class = null,
        .receiver_ty = null,
        .arity = .{ .required = required, .total = @intCast(f.params.len), .has_vararg = has_vararg },
        .sig = msig,
        .kind = .instance_method,
        .visibility = f.visibility,
        .is_inline = false,
        .is_suspend = f.is_suspend,
        .has_body = false,
    });
    try module.registry.member_method_fids.put(ukey, id);
}

pub fn lowerMethod(
    module: *Module,
    f: *const ast.Function,
    owner_class: []const u8,
    own_members: *const StringSet,
) Allocator.Error!Func {
    var no_enclosing = StringSet.init(module.registry.allocator);
    defer no_enclosing.deinit();
    return lowerMethodWithMemberContext(module, f, owner_class, own_members, &no_enclosing, null);
}

pub fn lowerMethodWithMemberContext(
    module: *Module,
    f: *const ast.Function,
    owner_class: []const u8,
    own_members: *const StringSet,
    enclosing_members: *const StringSet,
    own_member_arity: ?*const std.StringHashMap(u64),
) Allocator.Error!Func {
    // A method body lowered on its own declares its local classes into the same
    // scope stack a function body does, and must leave it as found.
    const local_class_mark = build.localClassScopeMark();
    defer build.localClassScopeRestore(local_class_mark);
    const a = module.registry.allocator;
    // A member extension function binds its extension receiver as `this`, so a bare
    // member reference in its body may be a member of that receiver or of the
    // enclosing class. Passing the enclosing class's `own_members` would force every
    // such reference into a `this.member` access on the extension receiver, so pass
    // none: bare references lower through the dynamic `this`, enclosing-`this`,
    // global probe. It is registered in `func_index` so a bare call resolves through
    // the same extension-call lowering top-level extensions use.
    if (f.receiver_type != null) {
        const implicit = [_][]const u8{"this"};
        // The owner class is threaded while `own_members` stays null: a `::name`
        // referencing an owner member must bind the dispatch receiver through the
        // qualified-this walk, which the ref lowering keys on the owner-class name.
        // The dispatch owner's members are the enclosing member scope of a member
        // extension's body, so a bare name the extension receiver's static type
        // does not declare resolves to `this@Owner.state`; without the owner set the
        // read lowers to a plain field read on the extension receiver.
        var owner_scope = StringSet.init(a);
        defer owner_scope.deinit();
        {
            var it = own_members.keyIterator();
            while (it.next()) |k| try owner_scope.put(k.*, {});
            var eit = enclosing_members.keyIterator();
            while (eit.next()) |k| try owner_scope.put(k.*, {});
        }
        const func = try lowerFunctionBodyWithImplicitOwnerEnclosing(module, f, &implicit, owner_class, null, &owner_scope, null);
        const reserved_id = module.funcByDeclSpan(f.name.span);
        const id = reserved_id orelse module.nextFuncId();
        var placed = func;
        try rewriteMemberFuncTypes(
            module,
            a,
            memberOwnerIdForFunction(module, owner_class, f),
            f,
            &placed,
        );
        placed.id = id;
        placed.kind = .member_extension;
        if (reserved_id != null) {
            const stub = module.funcById(id).?;
            placed.fqn = stub.fqn;
            placed.package = stub.package;
            module.funcByIdMut(id).?.* = placed;
        } else {
            try module.recordFuncDeclSpan(a, f.name.span, id);
            try module.appendFunc(placed);
            try registerFuncTypeParams(module, f, id);
            const nm = f.name.name;
            try module.func_index.append(a, .{ .name = nm, .id = id });
            try funcNameIndexPush(module, nm, id);
        }
        // Tag this member-extension with its declaring class so the runtime
        // extension-fallback dispatch filters it out at call sites outside it.
        const owner_identity = blk: {
            if (module.decl_sigs.get(id.int())) |sig| {
                if (sig.enclosing_class) |owner_id| {
                    if (owner_id.int() < module.classes.items.len) {
                        break :blk module.classes.items[owner_id.int()].fqn;
                    }
                }
            }
            break :blk owner_class;
        };
        try module.registry.member_ext_owner_class.put(id, owner_identity);
        if (f.visibility == .Private) {
            try module.registry.private_fn_files.put(id, f.name.span.file);
        }
        // Extension member: no enclosing-class own-members in scope, the receiver
        // being `this`, so the thunk runs with no owner_class context.
        try recordMethodParamDefaults(module, f, id, null, null);
        return placed;
    }
    const func = try lowerFunctionBodyWithImplicitOwnerEnclosing(
        module,
        f,
        &[_][]const u8{"this"},
        owner_class,
        own_members,
        enclosing_members,
        own_member_arity,
    );
    const reserved_id = module.funcByDeclSpan(f.name.span);
    const id = reserved_id orelse module.nextFuncId();
    var placed = func;
    try rewriteMemberFuncTypes(
        module,
        a,
        memberOwnerIdForFunction(module, owner_class, f),
        f,
        &placed,
    );
    placed.id = id;
    placed.kind = .instance_method;
    if (reserved_id) |_| {
        const stub = module.funcById(id).?;
        placed.fqn = stub.fqn;
        placed.package = stub.package;
        module.funcByIdMut(id).?.* = placed;
    } else {
        try module.recordFuncDeclSpan(a, f.name.span, id);
        try module.appendFunc(placed);
        try registerFuncTypeParams(module, f, id);
    }
    try recordMethodParamDefaults(module, f, id, owner_class, own_members);
    return placed;
}

/// Register a declaration's type-parameter names in the module registry so
/// generic-signature checks see methods the same way they see top-level functions.
fn registerFuncTypeParams(module: *Module, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    if (f.type_params.len == 0) return;
    const a = module.registry.allocator;
    var tp_names: std.ArrayList([]const u8) = .empty;
    for (f.type_params) |*tp| try tp_names.append(a, tp.name.name);
    try module.registry.func_type_params.put(id, tp_names);
    // The declared bounds register at header time for the same reason the names do:
    // a body lowered before this declaration must see them, or a `where`-bounded
    // receiver proves applicable to anything.
    var bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
    for (f.type_params) |*tp| {
        const first = bounds.items.len;
        if (tp.upper_bound) |*ub| {
            try bounds.append(a, .{
                .param = tp.name.name,
                .bound = ub.name.name,
                .complete = boundTypeRecordComplete(ub),
                .head_only = boundTypeRecordHeadOnly(ub),
            });
        }
        for (f.where_bounds) |*wb| {
            if (!std.mem.eql(u8, wb.name.name, tp.name.name)) continue;
            try bounds.append(a, .{
                .param = tp.name.name,
                .bound = wb.bound.name.name,
                .complete = boundTypeRecordComplete(&wb.bound),
                .head_only = boundTypeRecordHeadOnly(&wb.bound),
            });
        }
        if (bounds.items.len == first) {
            // Kotlin gives an unbounded type parameter the implicit upper bound
            // `Any?`, and a call on such a value can only target a member of that
            // bound. Recording it is what lets a generic body, lowered once with no
            // call site to read an instantiation from, name the declaration it calls.
            try bounds.append(a, .{
                .param = tp.name.name,
                .bound = "kotlin.Any",
                .complete = false,
                .head_only = true,
            });
        } else if (bounds.items.len - first > 1) {
            for (bounds.items[first..]) |*bd| bd.complete = false;
        }
    }
    if (bounds.items.len != 0) {
        try module.registry.func_type_param_bounds.put(id, try bounds.toOwnedSlice(a));
    } else {
        bounds.deinit(a);
    }
}

/// The bound's head still names one classifier, which is enough to own a member
/// call on the parameter even when the record dropped the bound's type arguments.
fn boundTypeRecordHeadOnly(bound: *const ast.TypeRef) bool {
    return !bound.nullable and bound.function == null and
        bound.qualified_path == null and bound.name.name.len != 0;
}

fn boundTypeRecordComplete(bound: *const ast.TypeRef) bool {
    return !bound.nullable and bound.type_args.len == 0 and
        bound.function == null and !bound.definitely_non_null and
        bound.qualified_path == null;
}

/// The bound's type-argument heads, kept only when every argument is a plain
/// concrete reference: unprojected, non-star, no nested arguments, not a function
/// type, and not naming any of the class's own type parameters.
pub fn concreteBoundArgs(
    allocator: Allocator,
    own_params: []const ast.TypeParam,
    upper: *const ast.TypeRef,
) Allocator.Error![]const []const u8 {
    if (upper.type_args.len == 0) return &.{};
    for (upper.type_args) |*ta| {
        if (ta.is_star or ta.variance != .Invariant) return &.{};
        if (ta.ty.type_args.len != 0 or ta.ty.function != null or ta.ty.nullable) return &.{};
        const n = ta.ty.name.name;
        if (n.len == 0) return &.{};
        if (n.len <= 2 and std.ascii.isUpper(n[0])) return &.{};
        for (own_params) |*other| {
            if (std.mem.eql(u8, other.name.name, n)) return &.{};
        }
    }
    const out = try allocator.alloc([]const u8, upper.type_args.len);
    for (upper.type_args, out) |*ta, *dst| dst.* = ta.ty.name.name;
    return out;
}

fn loweredClassTypeParamBounds(
    allocator: Allocator,
    class: *const ast.Class,
) Allocator.Error!?[]const ir.ModuleRegistry.TypeParamBound {
    if (class.type_params.len == 0) return null;
    var bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
    errdefer bounds.deinit(allocator);
    for (class.type_params) |*param| {
        const first = bounds.items.len;
        if (param.upper_bound) |*upper| {
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = upper.name.name,
                .complete = boundTypeRecordComplete(upper),
                .head_only = boundTypeRecordHeadOnly(upper),
                .args = try concreteBoundArgs(allocator, class.type_params, upper),
            });
        }
        for (class.where_bounds) |*where_bound| {
            if (!std.mem.eql(u8, where_bound.name.name, param.name.name)) continue;
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = where_bound.bound.name.name,
                .complete = boundTypeRecordComplete(&where_bound.bound),
                .head_only = boundTypeRecordHeadOnly(&where_bound.bound),
            });
        }
        if (bounds.items.len == first) {
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = "kotlin.Any",
            });
        } else if (bounds.items.len - first > 1) {
            for (bounds.items[first..]) |*bound| bound.complete = false;
        }
    }
    return try bounds.toOwnedSlice(allocator);
}

fn addScopedTypeParamBounds(
    b: *FuncBuilder,
    module: *Module,
    owner_class: ?[]const u8,
    f: *const ast.Function,
) Allocator.Error!void {
    if (owner_class) |owner| {
        try addOwnerClassTypeParamBounds(b, module, owner, f);
    }
    try addOwnTypeParamBounds(b, f);
}

/// Install the enclosing class's type-parameter bounds, keyed both by the
/// owner's identity and by the bare parameter name a body still spells.
fn addOwnerClassTypeParamBounds(
    b: *FuncBuilder,
    module: *Module,
    owner: []const u8,
    f: *const ast.Function,
) Allocator.Error!void {
    const owner_id = scopedOwnerClassId(b, module, owner, f);
    const exact_owner = if (owner_id) |id|
        (if (id.int() < module.classes.items.len)
            module.classes.items[id.int()].fqn
        else
            owner)
    else
        owner;
    if (module.registry.class_type_param_bounds.get(exact_owner) orelse
        module.registry.class_type_param_bounds.get(owner)) |bounds|
    {
        for (bounds) |bound| {
            if (owner_id) |id| {
                try addOwnerBoundIdentityEvidence(b, module, id, bound);
            }
            var shadowed = false;
            for (f.type_params) |*param| {
                if (std.mem.eql(u8, param.name.name, bound.param)) {
                    shadowed = true;
                    break;
                }
            }
            if (!shadowed) {
                try addUnshadowedOwnerBound(b, bound);
            }
        }
    }
}

/// The class id the bounds are keyed under: the reserved header's exact owner
/// where one exists, else the name resolved in this file's scope.
fn scopedOwnerClassId(
    b: *FuncBuilder,
    module: *Module,
    owner: []const u8,
    f: *const ast.Function,
) ?ClassId {
    if (module.funcByDeclSpan(f.name.span)) |reserved| {
        if (module.decl_sigs.get(reserved.int())) |sig| {
            if (sig.enclosing_class) |exact| return exact;
        }
    }
    if (std.mem.findScalar(u8, owner, '.') != null) {
        return module.classIdByFqn(owner);
    }
    return module.classIdIndexed(owner, b.self_package, f.span.file) orelse
        module.uniqueClassIdBySimpleName(owner);
}

/// Record the bound under the owner-qualified parameter identity, rewriting a
/// bound that names another of the owner's own parameters to that identity too.
fn addOwnerBoundIdentityEvidence(
    b: *FuncBuilder,
    module: *Module,
    id: ClassId,
    bound: ir.ModuleRegistry.TypeParamBound,
) Allocator.Error!void {
    const identity = try ir.classTypeParamIdentity(
        b.allocator,
        id,
        bound.param,
    );
    var owned_bound: []const u8 = bound.bound;
    if (id.int() < module.classes.items.len and
        std.mem.findScalar(u8, bound.bound, '.') == null)
    {
        for (module.classes.items[id.int()].type_params) |param| {
            if (!std.mem.eql(u8, param, bound.bound)) continue;
            owned_bound = try b.ownTypeParamText(
                try ir.classTypeParamIdentity(
                    b.allocator,
                    id,
                    param,
                ),
            );
            break;
        }
    }
    try b.addOwnedTypeParamBoundEvidence(
        identity,
        owned_bound,
        bound.complete,
    );
}

/// Record the bound under its bare parameter name, which a body reaches only
/// while no function type parameter shadows it.
fn addUnshadowedOwnerBound(
    b: *FuncBuilder,
    bound: ir.ModuleRegistry.TypeParamBound,
) Allocator.Error!void {
    try b.addTypeParamBoundHeadArgs(
        bound.param,
        bound.bound,
        bound.complete,
        bound.head_only,
        bound.args,
    );
    // A bound whose record kept concrete type arguments also
    // registers the full ref, so a receiver typed by this parameter
    // can substitute a generic callee's lambda params.
    if (bound.args.len != 0) {
        const arg_refs = try b.allocator.alloc(ir.TypeRef, bound.args.len);
        var filled: usize = 0;
        errdefer {
            for (arg_refs[0..filled]) |*t| t.deinit(b.allocator);
            b.allocator.free(arg_refs);
        }
        for (bound.args, arg_refs) |src, *dst| {
            dst.* = .{
                .name = try b.allocator.dupe(u8, src),
                .nullable = false,
                .args = &.{},
            };
            filled += 1;
        }
        try b.addTypeParamBoundRef(bound.param, .{
            .name = try b.allocator.dupe(u8, bound.bound),
            .nullable = false,
            .args = arg_refs,
        });
    }
}

/// Install the function's own type-parameter bounds. A reified parameter is
/// resolved by the splice, so it carries no erased bound.
fn addOwnTypeParamBounds(b: *FuncBuilder, f: *const ast.Function) Allocator.Error!void {
    for (f.type_params) |*param| {
        if (param.is_reified) continue;
        try addOwnTypeParamBound(b, f, param);
    }
}

/// Record one type parameter's bound: its upper bound merged with every `where`
/// clause naming it, defaulting to `kotlin.Any` when it has none.
fn addOwnTypeParamBound(
    b: *FuncBuilder,
    f: *const ast.Function,
    param: *const ast.TypeParam,
) Allocator.Error!void {
    var bound: []const u8 = "kotlin.Any";
    var complete = true;
    var head_only = true;
    var count: usize = 0;
    var bound_ast: ?*const ast.TypeRef = null;
    if (param.upper_bound) |*upper| {
        bound = upper.name.name;
        complete = boundTypeRecordComplete(upper);
        head_only = boundTypeRecordHeadOnly(upper);
        bound_ast = upper;
        count += 1;
    }
    for (f.where_bounds) |*where_bound| {
        if (std.mem.eql(u8, where_bound.name.name, param.name.name)) {
            if (count == 0) {
                bound = where_bound.bound.name.name;
                complete = boundTypeRecordComplete(&where_bound.bound);
                head_only = boundTypeRecordHeadOnly(&where_bound.bound);
                bound_ast = &where_bound.bound;
            }
            count += 1;
        }
    }
    if (count > 1) {
        complete = false;
        head_only = false;
    }
    try b.addTypeParamBoundHeadArgs(
        param.name.name,
        bound,
        complete,
        head_only,
        if (count == 1) if (bound_ast) |upper|
            try concreteBoundArgs(b.allocator, f.type_params, upper)
        else
            &.{} else &.{},
    );
    // The string record drops the bound's type arguments, so keep the full
    // lowered form when there are any and let a receiver typed by this parameter
    // instantiate a call's return type through it.
    if (count == 1) if (bound_ast) |upper| {
        if (upper.type_args.len != 0) {
            try b.addTypeParamBoundRef(
                param.name.name,
                try loweredTypeRef(b.allocator, upper, true),
            );
        }
    };
}

pub fn lowerFunctionBodyWithImplicitOwner(
    module: *Module,
    f: *const ast.Function,
    implicit_params: []const []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
) Allocator.Error!Func {
    return lowerFunctionBodyWithImplicitOwnerEnclosing(
        module,
        f,
        implicit_params,
        owner_class,
        own_members,
        null,
        null,
    );
}

/// The state every function-body lowering phase reads: the builder being filled,
/// the declaration it lowers, and the parameter names in bind order.
const BodyLower = struct {
    /// The registry allocator, owning everything the lowered `Func` keeps.
    a: Allocator,
    module: *Module,
    f: *const ast.Function,
    b: *FuncBuilder,
    implicit_params: []const []const u8,
    owner_class: ?[]const u8,
    /// The implicit params followed by the source parameter names, in bind order.
    names: []const []const u8,
};

/// Lower a method body, threading the lexically enclosing class's member names as
/// the builder's `enclosing_members`, distinct from `own_members`: an enclosing
/// member is in scope only through the implicit-receiver candidate walk.
pub fn lowerFunctionBodyWithImplicitOwnerEnclosing(
    module: *Module,
    f: *const ast.Function,
    implicit_params: []const []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
    enclosing_members: ?*const StringSet,
    own_member_arity: ?*const std.StringHashMap(u64),
) Allocator.Error!Func {
    const a = module.registry.allocator;
    const prev_real_fn = build.pushCurrentRealFn(f.name.name);
    defer build.popCurrentRealFn(prev_real_fn);
    const prev_sde = ir.setSuppressDeprecationError(
        annotationsSuppressDeprecationError(f.annotations),
    );
    defer _ = ir.setSuppressDeprecationError(prev_sde);
    const local_class_mark = build.localClassScopeMark();
    defer build.localClassScopeRestore(local_class_mark);
    const prev_owner = build.pushCurrentOwnerClass(owner_class);
    defer build.popCurrentOwnerClass(prev_owner);
    var b = try FuncBuilder.init(a, module);
    defer b.deinit();
    markComposeValueParams(&b, f);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.appendSlice(a, implicit_params);
    for (f.params) |*p| try names.append(a, p.name.name);

    var ctx: BodyLower = .{
        .a = a,
        .module = module,
        .f = f,
        .b = &b,
        .implicit_params = implicit_params,
        .owner_class = owner_class,
        .names = names.items,
    };

    // Scope setup: everything the body lowering below reads out of the builder.
    try installBoxedVars(&ctx);
    try bindParams(&b, names.items);
    try bindExtensionReceiverLabel(&ctx);
    try seedMemberThisDeclType(&ctx);
    markPlainThisParam(&ctx);
    try recordParamDeclTypes(&ctx);
    try bindLabeledReceiverAliases(&ctx);
    try emitContextParamLoads(&b, f.context_params, f.type_params);
    markContextDeclGate(&ctx);
    try markFunctionTypedParams(&ctx);
    try installTypeParamScope(&ctx);
    try markAnyTypedParams(&ctx);
    try installOwnerAndReceiverType(&ctx);
    try installMemberNameTables(&ctx, own_members, enclosing_members, own_member_arity);
    installTailrecSelf(&ctx);
    b.setInline(f.is_inline);
    // The declared return type is the expected type for an expression body and for a
    // `return …` inside a block body, so a reified inline call can infer.
    b.setDeclaredReturn(f.return_type);

    // The boxed-var set was computed and set before `bindParams` above so the
    // params bind as cells.
    var derived_return: ?TypeRef = null;
    const result = try lowerBodyIntoBuilder(&ctx, &derived_return);
    b.terminate(.{ .Return = result });

    var func = try finishLoweredFunc(&ctx, derived_return);
    func.params = try buildLoweredParams(&ctx);
    try applyReceiverParamType(&ctx, &func);
    try applyFuncDeclFlags(&ctx, &func);
    return func;
}

/// A compose-ABI'd fn's ordered value params, pair excluded, for the call-site
/// `$changed` forwarded-param bit emission.
fn markComposeValueParams(b: *FuncBuilder, f: *const ast.Function) void {
    if (f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 2].name.name, "$composer") and
        std.mem.eql(u8, f.params[f.params.len - 1].name.name, "$changed"))
    {
        b.compose_value_params = f.params[0 .. f.params.len - 2];
    }
}

/// Compute the boxed-var set before binding params so a parameter a nested
/// closure writes binds as a shared cell. The body-`var` half comes from
/// `computeBoxedVars`; this adds any parameter a nested lambda mutates.
fn installBoxedVars(ctx: *BodyLower) Allocator.Error!void {
    const a = ctx.a;
    const b = ctx.b;
    if (ctx.f.body) |body| {
        if (body == .Block) {
            var boxed = try mod.computeBoxedVars(a, body.Block.stmts);
            var assigned = mod.ast_scan.StringSet.init(a);
            defer assigned.deinit();
            try mod.ast_scan.namesAssignedInLambdasRebindsOnly(body.Block.stmts, &assigned);
            for (ctx.names) |pname| {
                if (assigned.contains(pname)) try boxed.put(pname, {});
            }
            for (build.anonBoxedCaptureNames()) |n| try boxed.put(n, {});
            b.setBoxedVars(boxed);
        } else if (build.anonBoxedCaptureNames().len != 0) {
            var boxed = mod.ast_scan.StringSet.init(a);
            for (build.anonBoxedCaptureNames()) |n| try boxed.put(n, {});
            b.setBoxedVars(boxed);
        }
    }
}

/// An extension function's own receiver is addressable as `this@<name>` from
/// anywhere in its body, including inside a spliced receiver-lambda region where
/// the innermost `this` is the splice subject. Bind the labeled slot at entry so
/// the labeled-this lowering resolves it directly.
fn bindExtensionReceiverLabel(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    if (f.receiver_type != null and ctx.names.len != 0 and
        std.mem.eql(u8, ctx.names[0], "this"))
    {
        if (b.resolve("this")) |own_this| {
            const label = try std.fmt.allocPrint(b.allocator, "this@{s}", .{f.name.name});
            try b.bind(label, own_this);
        }
    }
}

/// A normal member's synthesized `this` is not in the source parameter list, so
/// seed it from the reserved declaration header and let explicit `this.member(…)`
/// see the same qualified generic owner type.
fn seedMemberThisDeclType(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    const f = ctx.f;
    const module = ctx.module;
    if (ctx.implicit_params.len != 0 and
        std.mem.eql(u8, ctx.implicit_params[0], "this") and
        f.receiver_type == null)
    {
        if (module.funcByDeclSpan(f.name.span)) |reserved| {
            if (module.funcById(reserved)) |header| {
                if (header.params.len != 0 and
                    std.mem.eql(u8, header.params[0].name, "this"))
                {
                    try b.setLocalDeclTypeOwned(
                        "this",
                        try header.params[0].ty.clone(b.allocator),
                    );
                }
            }
        }
    }
}

/// A user parameter literally named `this` on a receiver-less function is an
/// ordinary value binding, so bare calls must not member-dispatch through it.
fn markPlainThisParam(ctx: *BodyLower) void {
    if (ctx.implicit_params.len == 0 and ctx.owner_class == null) {
        for (ctx.f.params) |*p| {
            if (std.mem.eql(u8, p.name.name, "this")) ctx.b.this_is_plain_param = true;
        }
    }
}

/// Record each declared parameter's static type head so a cast-rebound call can
/// disambiguate overloads by an argument naming a parameter. A vararg parameter's
/// static type inside the body is the materialized array, never the element type.
fn recordParamDeclTypes(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    for (ctx.f.params) |*p| {
        if (p.is_vararg) {
            try b.setLocalDeclTypeOwned(p.name.name, try varargArrayTypeRef(b.allocator, &p.ty));
        } else {
            try b.setLocalDeclTypeOwned(
                p.name.name,
                try loweredTypeRef(b.allocator, &p.ty, true),
            );
        }
        if (p.ty.nullable) try b.setLocalDeclNullable(p.name.name);
        if (p.ty.function) |ft| {
            if (ft.receiver != null) try b.setLocalDeclRecvFn(p.name.name);
            try b.setLocalCallReturn(p.name.name, ft.ret.name.name, ft.ret.nullable);
        }
    }
}

/// Labeled-receiver alias: `this@<fn>` names this function's receiver, so a
/// qualified `this@fn` in a nested lambda captures it rather than the lambda's
/// own `this`.
fn bindLabeledReceiverAliases(ctx: *BodyLower) Allocator.Error!void {
    const a = ctx.a;
    const b = ctx.b;
    const f = ctx.f;
    if (ctx.names.len != 0 and std.mem.eql(u8, ctx.names[0], "this")) {
        if (b.resolve("this")) |this_reg| {
            const label = try std.fmt.allocPrint(a, "this@{s}", .{f.name.name});
            try b.bind(label, this_reg);
            // An extension declaration's receiver is addressable from any nested
            // scope under this label, so the tower entry this body pushes carries
            // the value channel.
            if (f.receiver_type != null) b.setOwnThisLabel(f.name.name);
            // A method also answers to `this@<OwnerClass>`: the class-name label
            // names the class's dispatch receiver, not a nested lambda's own even
            // when that receiver is the same class, since Kotlin labels the lambda
            // receiver by the callee function name. Only for a plain method, whose
            // `this` param is the owner instance; a member extension binds its
            // extension receiver as `this`, so `this@C` is a different receiver.
            if (f.receiver_type == null) {
                if (ctx.owner_class) |oc| {
                    if (!std.mem.eql(u8, oc, f.name.name)) {
                        const clabel = try std.fmt.allocPrint(a, "this@{s}", .{oc});
                        try b.bind(clabel, this_reg);
                    }
                }
            }
        }
    }
}

/// A user contextual declaration makes receivers context sources; the stdlib
/// intrinsics resolve without the runtime receiver stack, so they must not flip
/// the module-wide gate.
fn markContextDeclGate(ctx: *BodyLower) void {
    const b = ctx.b;
    const f = ctx.f;
    if (f.context_params.len != 0 and
        !std.mem.eql(u8, f.name.name, "context") and
        !std.mem.eql(u8, f.name.name, "contextOf"))
    {
        b.module.has_context_decls = true;
    }
}

/// A param whose declared type is a receiver-typed function carries that fact so
/// a bare call `block(...)` lowers to a member call with the enclosing `this` as
/// receiver. Implicit params never come in this shape.
fn markFunctionTypedParams(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    for (ctx.f.params) |*p| {
        if (p.ty.function == null) {
            // An aliased receiver-fn type carries no syntactic function type; the
            // alias registry keeps the receiver-ness the `Function{N}` tag drops.
            if (b.module.registry.recv_fn_aliases.get(p.ty.name.name)) |ar| {
                try b.markReceiverLambdaParam(p.name.name);
                try b.markReceiverLambdaArity(p.name.name, ar);
            }
        }
        if (p.ty.function) |ft| {
            if (ft.receiver != null) {
                try b.markReceiverLambdaParam(p.name.name);
                if (p.ty.function) |fnty| try b.markReceiverLambdaArity(p.name.name, fnty.params.len);
                // Record the declared receiver head so a bare invocation, here or in
                // a nested lambda that captures the param, re-selects the implicit
                // receiver of that type.
                const rh = ft.receiver.?.name.name;
                try b.setReceiverLambdaRecvHead(p.name.name, if (b.isTypeParam(rh)) null else rh);
            } else {
                try b.markPlainFnParam(p.name.name);
                // A trailing lambda binds the callee's last parameter, so a
                // function-typed param is a trailing-lambda call's target only when
                // its own last parameter is a function type.
                if (ft.params.len != 0 and ft.params[ft.params.len - 1].function != null) {
                    try b.markFnParamTakesTrailingLambda(p.name.name);
                }
            }
            // A param typed as a contextual function type: a fully-positional call
            // splits its leading context args from the ordinary ones. Receiver-typed
            // contextual types are out of scope for that form.
            if (ft.context_params.len != 0 and ft.receiver == null) {
                const ctx_types = try b.allocator.alloc([]const u8, ft.context_params.len);
                for (ft.context_params, 0..) |cp, ci| ctx_types[ci] = cp.name.name;
                try b.markContextFnParam(p.name.name, ctx_types, ft.params.len);
            }
        }
    }
}

/// A param whose declared type is one of the function's own generic type
/// parameters: comparison operators on such an operand follow Kotlin's
/// `compareTo` total order, not the IEEE primitive.
fn installTypeParamScope(ctx: *BodyLower) Allocator.Error!void {
    const a = ctx.a;
    const b = ctx.b;
    const f = ctx.f;
    var tp_names = StringSet.init(a);
    defer tp_names.deinit();
    for (f.type_params) |*tp| try tp_names.put(tp.name.name, {});
    // A type parameter with no upper bound has the members of `Any?`, none
    // worth dispatching.
    var tp_unbounded = StringSet.init(a);
    defer tp_unbounded.deinit();
    for (f.type_params) |*tp| {
        if (tp.upper_bound != null) continue;
        var bounded = false;
        for (f.where_bounds) |*wb| {
            if (std.mem.eql(u8, wb.name.name, tp.name.name)) {
                bounded = true;
                break;
            }
        }
        if (!bounded) try tp_unbounded.put(tp.name.name, {});
    }
    b.setSelfDeclSpan(f.name.span);
    b.setHasOwnTypeParams(f.type_params.len != 0);
    // Non-reified type parameters in scope: this function's own, a reified one
    // being resolved by the reified splice, plus the enclosing class's, never
    // reified in Kotlin. A cast to such a name is erased. The outer class
    // installs first so a same-named function parameter keeps the nearer bound.
    try addScopedTypeParamBounds(b, ctx.module, ctx.owner_class, f);
    for (f.params) |*p| {
        if (p.ty.function == null and !p.ty.nullable and tp_names.contains(p.ty.name.name)) {
            try b.markGenericTypedParam(p.name.name);
        }
        if (p.ty.function == null and tp_unbounded.contains(p.ty.name.name)) {
            try b.markErasedRecvParam(p.name.name);
        }
        // A concrete non-function param type does not shadow a same-named
        // top-level function for a call.
        if (p.ty.function == null and !tp_names.contains(p.ty.name.name)) {
            try b.markNonFnParam(p.name.name);
        }
        // A param statically typed as a broad collection returns a `List` from
        // `p + x` even over a runtime `Set`, so the operator lowering coerces it.
        if (p.ty.function == null and helpers.isBroadCollectionTypeName(p.ty.name.name)) {
            try b.markBroadCollectionLocal(p.name.name);
        }
    }
}

/// A param declared `Any` or `Any?` holds a boxed value, so `==` on it uses
/// total-order equality, matching `Double.equals`.
fn markAnyTypedParams(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    for (ctx.f.params) |*p| {
        if (p.ty.function == null and std.mem.eql(u8, p.ty.name.name, "Any")) {
            try b.markAnyTyped(p.name.name);
        }
    }
}

/// Install the owner class, then record the enclosing extension's declared
/// receiver type so a bare call to a same-named extension inside the body
/// resolves to the matching overload.
fn installOwnerAndReceiverType(ctx: *BodyLower) Allocator.Error!void {
    const b = ctx.b;
    if (ctx.owner_class) |owner| {
        b.setOwnerClass(owner);
    }
    if (ctx.f.receiver_type) |*receiver| {
        b.setRecvTypeRefOwned(try loweredTypeRef(b.allocator, receiver, true));
    } else {
        b.setRecvTy(null);
    }
}

/// Copy the caller's member-name tables into the builder: the owner's own
/// members, the lexically enclosing class's, and the own-member arities.
fn installMemberNameTables(
    ctx: *BodyLower,
    own_members: ?*const StringSet,
    enclosing_members: ?*const StringSet,
    own_member_arity: ?*const std.StringHashMap(u64),
) Allocator.Error!void {
    const a = ctx.a;
    const b = ctx.b;
    if (own_members) |set| {
        b.setOwnMembers(try cloneStringSet(a, set));
    }
    if (enclosing_members) |set| {
        if (set.count() != 0) b.setEnclosingMembers(try cloneStringSet(a, set));
    }
    if (own_member_arity) |map| {
        var copy = std.StringHashMap(u64).init(a);
        var it = map.iterator();
        while (it.next()) |e| try copy.put(e.key_ptr.*, e.value_ptr.*);
        b.setOwnMemberArity(copy);
    }
}

/// Name the declaration as its own tail-call target so a self call in tail
/// position lowers to a jump.
fn installTailrecSelf(ctx: *BodyLower) void {
    const b = ctx.b;
    const f = ctx.f;
    if (f.is_tailrec) {
        b.setTailrecSelf(f.name.name);
        b.setTailrecSelfHasThis(ctx.names.len != 0 and std.mem.eql(u8, ctx.names[0], "this"));
        b.setTailrecParams(f.params);
    }
}

/// Lower the declaration's body into the builder, yielding the result register an
/// expression body produces and, through `derived_return`, the return type an
/// unannotated expression body infers.
fn lowerBodyIntoBuilder(ctx: *BodyLower, derived_return: *?TypeRef) Allocator.Error!?ir.Reg {
    const b = ctx.b;
    const f = ctx.f;
    var result: ?ir.Reg = null;
    if (f.body) |body| {
        switch (body) {
            .Block => |*blk| {
                // A block body's fall-through returns Unit, never the tail
                // statement's value: `fun f() { 42 }` returns Unit in Kotlin. A Unit
                // body's last statement is in tail position; a value-returning body
                // reaches its value only through `return`.
                b.tail_pos = f.return_type == null or std.mem.eql(u8, f.return_type.?.name.name, "Unit");
                _ = try mod.lowerBlock(b, blk);
            },
            .Expr => |*e| {
                b.tail_pos = true;
                // An expression body has no statements, so mark its source position
                // here for stack traces, or the frame reports no line.
                try b.push(.{ .Trace = .{ .span = e.span() } });
                const prev = b.pushExpected(f.return_type);
                // An expression body with no annotation carries its inferred return
                // where the static derivation proves one, so callers' locals type
                // through it, which member refutation needs.
                if (f.return_type == null and derived_return.* == null) {
                    derived_return.* = try mod.staticExprTypeRef(b, e);
                }
                result = try mod.lowerExpr(b, e);
                b.restoreExpected(prev);
            },
        }
    }
    return result;
}

/// Seal the builder into a `Func`, carrying the declared return type so the
/// evaluator can normalize a bare integer-literal result to a `Long` return slot;
/// inferred returns stay `Unit`, the coercion only triggering on an explicit `Long`.
fn finishLoweredFunc(ctx: *BodyLower, derived_return: ?TypeRef) Allocator.Error!Func {
    const a = ctx.a;
    const f = ctx.f;
    const fqn = f.name.name;
    const return_ty: TypeRef = if (f.return_type) |*rt|
        renameParamHead(try loweredTypeRef(a, rt, false), rt)
    else if (derived_return) |dr|
        dr
    else
        build.typeUnit();
    var func = try ctx.b.finish(f.name.name, fqn, return_ty);
    func.return_ty_declared = f.return_type != null;
    return func;
}

/// Build the lowered parameter list: the implicit receivers as `Unit`
/// placeholders, then every source parameter.
fn buildLoweredParams(ctx: *BodyLower) Allocator.Error![]Param {
    const a = ctx.a;
    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(a);
    for (ctx.implicit_params) |n| {
        try params.append(a, .{
            .name = n,
            .ty = build.typeUnit(),
            .default = null,
            .is_property = false,
            .is_vararg = false,
            .has_default = false,
        });
    }
    for (ctx.f.params) |*p| {
        // The full structural type rides on the param so the symbol index can prove
        // or refute signature identity between overloads; runtime overload matching
        // keeps reading only the head name and nullability.
        try params.append(a, .{
            .name = p.name.name,
            .ty = renameParamHead(try loweredTypeRef(a, &p.ty, false), &p.ty),
            .default = null,
            .composable_arity = @import("compose_pass").composableFunctionArity(&p.ty),
            .composable_recv_slots = @import("compose_pass").composableFunctionRecvSlots(&p.ty),
            .is_property = false,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        });
    }
    return try params.toOwnedSlice(a);
}

/// An extension fn's synthetic receiver param carries the declared receiver type,
/// not the `Unit` placeholder, so runtime overload resolution picks the right
/// receiver overload instead of falling back to declaration order.
fn applyReceiverParamType(ctx: *BodyLower, func: *Func) Allocator.Error!void {
    const a = ctx.a;
    const f = ctx.f;
    const module = ctx.module;
    if (f.receiver_type) |*rt| {
        if (func.params.len != 0 and std.mem.eql(u8, func.params[0].name, "this")) {
            // The full structural type, head name and generic arguments, so the
            // strict extension-receiver prover can refute a `List<String>` receiver
            // on a list of Ints instead of proving on the bare head.
            func.params[0].ty = try loweredTypeRef(a, rt, false);
        }
    } else if (ctx.owner_class != null and func.params.len != 0 and
        std.mem.eql(u8, func.params[0].name, "this"))
    {
        const owner = ctx.owner_class.?;
        const owner_id = blk: {
            if (module.funcByDeclSpan(f.name.span)) |reserved| {
                if (module.decl_sigs.get(reserved.int())) |sig| {
                    if (sig.enclosing_class) |exact| break :blk exact;
                }
            }
            if (std.mem.findScalar(u8, owner, '.') != null) {
                break :blk module.classIdByFqn(owner);
            }
            break :blk module.classIdIndexed(owner, ctx.b.self_package, f.span.file) orelse
                module.uniqueClassIdBySimpleName(owner);
        };
        func.params[0].ty = try memberOwnerTypeRef(module, a, owner_id, owner);
    }
}

/// Carry the declaration's modifiers and annotation set onto the lowered func.
fn applyFuncDeclFlags(ctx: *BodyLower, func: *Func) Allocator.Error!void {
    const f = ctx.f;
    func.is_suspend = f.is_suspend;
    func.low_priority = isLowPriorityOverload(f);
    func.deprecated_error = annotationsAreDeprecatedError(f.annotations);
    func.is_expect = f.is_expect;
    func.is_override = f.is_override;
    func.is_open = f.is_open;
    func.is_final = f.is_final;
    // A leading `this` injected via `implicit_params` is a synthesized dispatch or
    // extension receiver, distinct from a user param that spells its name `this`.
    func.has_receiver_param = ctx.implicit_params.len != 0 and
        std.mem.eql(u8, ctx.implicit_params[0], "this");
    func.annotation_names = try resolveAnnotationNames(ctx.module, f.annotations);
}

/// A function is excluded from overload resolution while any ordinary candidate
/// applies when it carries `@LowPriorityInOverloadResolution` or
/// `@Deprecated(level = DeprecationLevel.ERROR)`, which mark guard stubs that exist
/// only to produce a compile error. Public so phase-1 header registration can mark
/// stubs before their bodies lower, keeping the filter order-independent.
pub fn isLowPriorityOverload(f: *const ast.Function) bool {
    return annotationsAreLowPriority(f.annotations);
}

/// `@LowPriorityInOverloadResolution`, or `@Deprecated(level = ERROR|HIDDEN)`: none
/// is a source-level candidate in kotlinc, HIDDEN hiding the declaration entirely
/// for binary compatibility. Takes the annotation list directly so a secondary
/// constructor is judged by the same rule as a function.
pub fn annotationsAreLowPriority(annotations: []const ast.Annotation) bool {
    for (annotations) |*ann| {
        const leaf: []const u8 = if (ann.path.len != 0) ann.path[ann.path.len - 1].name else "";
        if (std.mem.eql(u8, leaf, "LowPriorityInOverloadResolution")) {
            return true;
        }
        if (std.mem.eql(u8, leaf, "Deprecated")) {
            // Neither `DeprecationLevel.ERROR` nor `HIDDEN` is a source-level
            // candidate in kotlinc, so both rank as guard stubs.
            for (ann.args) |*arg| {
                if (exprMentionsErrorOrHidden(arg)) return true;
            }
        }
    }
    return false;
}

/// `@Deprecated(level = ERROR|HIDDEN)` alone, the suppressible half of the
/// low-priority mark: `@Suppress("DEPRECATION_ERROR")` at the caller restores such a
/// candidate to ordinary ranking, which `@LowPriorityInOverloadResolution` never is.
pub fn annotationsAreDeprecatedError(annotations: []const ast.Annotation) bool {
    for (annotations) |*ann| {
        const leaf: []const u8 = if (ann.path.len != 0) ann.path[ann.path.len - 1].name else "";
        if (std.mem.eql(u8, leaf, "Deprecated")) {
            for (ann.args) |*arg| {
                if (exprMentionsErrorOrHidden(arg)) return true;
            }
        }
    }
    return false;
}

/// Whether a declaration's annotations carry `@Suppress("DEPRECATION_ERROR")`.
pub fn annotationsSuppressDeprecationError(annotations: []const ast.Annotation) bool {
    for (annotations) |*ann| {
        const leaf: []const u8 = if (ann.path.len != 0) ann.path[ann.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "Suppress")) continue;
        for (ann.args) |*arg| {
            if (arg.* != .StringTemplate) continue;
            for (arg.StringTemplate.parts) |part| {
                if (part == .Text and std.mem.eql(u8, part.Text, "DEPRECATION_ERROR")) return true;
            }
        }
    }
    return false;
}

/// Probe for `@Deprecated(level = DeprecationLevel.ERROR)`, extended to `HIDDEN`:
/// walk the argument expression for an identifier or string literal containing
/// either level name.
fn exprMentionsErrorOrHidden(e: *const ast.Expr) bool {
    switch (e.*) {
        .Path => |p| {
            for (p.segments) |seg| {
                if (std.mem.find(u8, seg.name, "ERROR") != null or std.mem.find(u8, seg.name, "HIDDEN") != null) return true;
            }
        },
        .Member => |m| {
            if (std.mem.find(u8, m.name.name, "ERROR") != null or std.mem.find(u8, m.name.name, "HIDDEN") != null) return true;
            return exprMentionsErrorOrHidden(m.receiver);
        },
        .MemberRef => |m| {
            if (std.mem.find(u8, m.name.name, "ERROR") != null or std.mem.find(u8, m.name.name, "HIDDEN") != null) return true;
            return exprMentionsErrorOrHidden(m.receiver);
        },
        .Call => |c| {
            if (exprMentionsErrorOrHidden(c.callee)) return true;
            for (c.args) |*arg| if (exprMentionsErrorOrHidden(arg)) return true;
        },
        .Binary => |bin| {
            return exprMentionsErrorOrHidden(bin.lhs) or exprMentionsErrorOrHidden(bin.rhs);
        },
        .Unary => |u| return exprMentionsErrorOrHidden(u.expr),
        .Postfix => |u| return exprMentionsErrorOrHidden(u.expr),
        .As => |u| return exprMentionsErrorOrHidden(u.expr),
        .IsCheck => |u| return exprMentionsErrorOrHidden(u.expr),
        .Spread => |u| return exprMentionsErrorOrHidden(u.expr),
        .Labeled => |u| return exprMentionsErrorOrHidden(u.expr),
        else => {},
    }
    return false;
}

/// Push `(name, id)` into the parallel `func_name_index` keyed by simple name.
fn funcNameIndexPush(module: *Module, name: []const u8, id: FuncId) Allocator.Error!void {
    const a = module.registry.allocator;
    const gop = try module.func_name_index.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, id);
}

/// Duplicate a `StringHashMap(void)` into a fresh owned set sharing the borrowed
/// key slices.
fn cloneStringSet(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "resolveAnnotationNames yields fqn candidates from imports" {
    // Arena-backed so the registry's import strings and the freshly joined result
    // candidates, which are mixed-ownership, are reclaimed in one shot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    const ra = m.registry.allocator;
    const file: ir.FileId = @enumFromInt(0);

    // The registry owns and frees every fqn, segs and wildcard string on deinit, so
    // each is duped into the registry allocator.
    {
        var named = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(ra);
        var test_paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
        try test_paths.append(ra, .{ .fqn = try ra.dupe(u8, "kotlin.test.Test"), .segs = try ra.alloc([]const u8, 0) });
        try named.put("Test", test_paths);
        var ignore_paths: std.ArrayList(ir.ModuleRegistry.ImportPath) = .empty;
        try ignore_paths.append(ra, .{ .fqn = try ra.dupe(u8, "t.Skip"), .segs = try ra.alloc([]const u8, 0) });
        try named.put("Ignore", ignore_paths);
        try m.registry.import_aliases.put(file, named);

        var wild: std.ArrayList([]const u8) = .empty;
        try wild.append(ra, try ra.dupe(u8, "org.junit"));
        try m.registry.import_wildcards.put(file, wild);
    }

    const sp = ast.Span{ .file = file, .start = 0, .end = 0 };
    var test_id = [_]ast.Ident{.{ .name = "Test", .span = sp }};
    var ignore_id = [_]ast.Ident{.{ .name = "Ignore", .span = sp }};
    var qual_ids = [_]ast.Ident{ .{ .name = "kotlin", .span = sp }, .{ .name = "test", .span = sp }, .{ .name = "AfterTest", .span = sp } };
    const anns = [_]ast.Annotation{
        .{ .use_site = null, .path = &test_id, .type_args = &.{}, .args = &.{}, .arg_names = &.{}, .span = sp },
        .{ .use_site = null, .path = &ignore_id, .type_args = &.{}, .args = &.{}, .arg_names = &.{}, .span = sp },
        .{ .use_site = null, .path = &qual_ids, .type_args = &.{}, .args = &.{}, .arg_names = &.{}, .span = sp },
    };

    const got = try resolveAnnotationNames(&m, &anns);
    // @Test: named import + wildcard candidate + bare fallback.
    try expectContains(got, "kotlin.test.Test");
    try expectContains(got, "org.junit.Test");
    try expectContains(got, "Test");
    // @Ignore: the FQN behind the alias, plus wildcard and bare.
    try expectContains(got, "t.Skip");
    try expectContains(got, "org.junit.Ignore");
    try expectContains(got, "Ignore");
    // Qualified path passes through verbatim.
    try expectContains(got, "kotlin.test.AfterTest");
}

test "member headers reserve stable ids and preserve same-arity overloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const sp = ast.Span{ .file = ir.FileId.from(0), .start = 10, .end = 20 };
    const scope_ty: ast.TypeRef = .{
        .name = .{ .name = "Scope", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const body: ast.FunctionBody = .{ .Block = .{ .stmts = &.{}, .span = sp } };
    const helper: ast.Function = .{
        .name = .{ .name = "helper", .span = sp },
        .receiver_type = scope_ty,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = body,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Private,
        .annotations = &.{},
        .span = sp,
    };
    const sp_int = ast.Span{ .file = ir.FileId.from(0), .start = 30, .end = 40 };
    const sp_string = ast.Span{ .file = ir.FileId.from(0), .start = 50, .end = 60 };
    var int_ty = scope_ty;
    int_ty.name = .{ .name = "Int", .span = sp_int };
    int_ty.span = sp_int;
    var string_ty = scope_ty;
    string_ty.name = .{ .name = "String", .span = sp_string };
    string_ty.span = sp_string;
    var int_default: ast.Expr = .{ .IntLit = .{ .value = 7, .kind = .Int, .span = sp_int } };
    var int_params = [_]ast.Param{.{
        .name = .{ .name = "value", .span = sp_int },
        .ty = int_ty,
        .default = &int_default,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = sp_int,
    }};
    var string_params = [_]ast.Param{.{
        .name = .{ .name = "value", .span = sp_string },
        .ty = string_ty,
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = sp_string,
    }};
    var int_overload = helper;
    int_overload.name.span = sp_int;
    int_overload.receiver_type = null;
    int_overload.params = &int_params;
    int_overload.body = null;
    int_overload.is_abstract = true;
    int_overload.span = sp_int;
    var string_overload = helper;
    string_overload.name.span = sp_string;
    string_overload.receiver_type = null;
    string_overload.params = &string_params;
    string_overload.span = sp_string;
    const sp_t = ast.Span{ .file = ir.FileId.from(0), .start = 70, .end = 80 };
    var t_ty = scope_ty;
    t_ty.name = .{ .name = "T", .span = sp_t };
    t_ty.span = sp_t;
    var t_params = [_]ast.Param{.{
        .name = .{ .name = "value", .span = sp_t },
        .ty = t_ty,
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = sp_t,
    }};
    var takes_t = helper;
    takes_t.name = .{ .name = "takesT", .span = sp_t };
    takes_t.receiver_type = null;
    takes_t.params = &t_params;
    takes_t.span = sp_t;
    var members = [_]ast.Decl{
        .{ .Function = helper },
        .{ .Function = int_overload },
        .{ .Function = string_overload },
        .{ .Function = takes_t },
    };
    const host_type_params = [_]ast.TypeParam{.{
        .name = .{ .name = "T", .span = sp },
        .variance = .Invariant,
        .upper_bound = null,
        .is_reified = false,
        .annotations = &.{},
        .span = sp,
    }};
    const cls: ast.Class = .{
        .name = .{ .name = "Host", .span = sp },
        .type_params = @constCast(&host_type_params),
        .where_bounds = &.{},
        .primary_params = &.{},
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .is_data = false,
        .is_companion = false,
        .is_enum = false,
        .is_sealed = false,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .enum_entries = &.{},
        .members = &members,
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = sp,
    };
    const owner = try m.reserveClassFqn(a, "Host", "sample.Host", "sample", false);
    try reserveMemberHeaders(&m, &cls, "sample.Host", "sample");
    try recordAbstractMemberDefaults(&m, &cls, &int_overload);

    const id = m.funcByDeclSpan(sp).?;
    const f = m.funcById(id).?;
    try std.testing.expectEqual(ir.FuncKind.member_extension, f.kind);
    try std.testing.expectEqualStrings("sample.Host.helper", f.fqn);
    try std.testing.expectEqualStrings("Scope", f.params[0].ty.name);
    try std.testing.expectEqual(owner, m.decl_sigs.get(id.int()).?.enclosing_class.?);
    try std.testing.expectEqualStrings("sample.Host", m.registry.member_ext_owner_class.get(id).?);
    try std.testing.expectEqual(@as(usize, 1), m.funcsBySimpleName("helper").len);
    const overloads = m.memberDecls("sample.Host", "helper");
    try std.testing.expectEqual(@as(usize, 3), overloads.len);
    try std.testing.expectEqual(ir.FuncKind.instance_method, m.funcById(overloads[1]).?.kind);
    try std.testing.expectEqual(ir.FuncKind.instance_method, m.funcById(overloads[2]).?.kind);
    try std.testing.expectEqualStrings("sample.Host", m.funcById(overloads[1]).?.params[0].ty.name);
    try std.testing.expectEqual(@as(usize, 1), m.funcById(overloads[1]).?.params[0].ty.args.len);
    const owner_param = ir.parseClassTypeParamIdentity(
        m.funcById(overloads[1]).?.params[0].ty.args[0].name,
    ).?;
    try std.testing.expectEqual(owner, owner_param.owner);
    try std.testing.expectEqualStrings("T", owner_param.param);
    try std.testing.expectEqualStrings("Int", m.funcById(overloads[1]).?.params[1].ty.name);
    try std.testing.expectEqualStrings("String", m.funcById(overloads[2]).?.params[1].ty.name);
    const takes_t_id = m.memberDecls("sample.Host", "takesT")[0];
    const takes_t_param = ir.parseClassTypeParamIdentity(
        m.funcById(takes_t_id).?.params[1].ty.name,
    ).?;
    try std.testing.expectEqual(owner, takes_t_param.owner);
    try std.testing.expectEqualStrings("T", takes_t_param.param);
    const exact_defaults = m.registry.local_fn_defaults.get(overloads[1]).?;
    try std.testing.expectEqual(@as(usize, 2), exact_defaults.items.len);
    try std.testing.expect(exact_defaults.items[1] != null);
    try std.testing.expect(m.registry.local_fn_defaults.get(overloads[2]) == null);
}

test "member body receiver keeps its reserved qualified generic owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);
    const left = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Box",
        .fqn = "left.Box",
        .package = "left",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    const right = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Box",
        .fqn = "right.Box",
        .package = "right",
        .type_params = &.{"U"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try std.testing.expect(left != right);

    const sp = ast.Span{ .file = ir.FileId.from(7), .start = 1, .end = 2 };
    const f: ast.Function = .{
        .name = .{ .name = "value", .span = sp },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = .{ .Expr = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = sp } } },
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = sp,
    };
    const reserved = m.nextFuncId();
    try m.appendFunc(.{
        .id = reserved,
        .name = "value",
        .fqn = "right.Box.value",
        .package = "right",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .instance_method,
    });
    try m.recordFuncDeclSpan(a, sp, reserved);
    try m.decl_sigs.put(reserved.int(), .{
        .enclosing_class = right,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });
    const previous_package = build.setLowerSelfPackage("right");
    defer _ = build.setLowerSelfPackage(previous_package);
    const lowered = try lowerFunctionBodyWithImplicitOwnerEnclosing(
        &m,
        &f,
        &.{"this"},
        "Box",
        null,
        null,
        null,
    );
    try std.testing.expectEqualStrings("right.Box", lowered.params[0].ty.name);
    try std.testing.expectEqual(@as(usize, 1), lowered.params[0].ty.args.len);
    const owner_param = ir.parseClassTypeParamIdentity(lowered.params[0].ty.args[0].name).?;
    try std.testing.expectEqual(right, owner_param.owner);
    try std.testing.expectEqualStrings("U", owner_param.param);
}

test "class superclass edges are available before method lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    defer m.deinit(a);

    const base = try m.reserveClassFqn(a, "Base", "sample.Base", "sample", false);
    const derived = try m.reserveClassFqn(a, "Derived", "sample.Derived", "sample", false);
    const sp = ast.Span{ .file = ir.FileId.from(0), .start = 0, .end = 1 };
    const supertype = ast.TypeRef{
        .name = .{ .name = "Base", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var supertypes = [_]ast.TypeRef{supertype};
    var class: ast.Class = undefined;
    class.supertypes = &supertypes;

    try populateClassSupertypes(&m, &class, "sample.Derived", "sample");

    try std.testing.expectEqual(@as(usize, 1), m.classes.items[derived.int()].supertypes.len);
    try std.testing.expectEqual(base, m.classes.items[derived.int()].supertypes[0]);
    try std.testing.expectEqual(
        ir.Module.StaticCompatibility.compatible,
        m.staticTypeCompatibility(
            .{ .name = "sample.Derived", .nullable = false, .args = &.{} },
            .{ .name = "sample.Base", .nullable = false, .args = &.{} },
        ),
    );
}

fn expectContains(haystack: []const []const u8, needle: []const u8) !void {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return;
    }
    return error.TestExpectedEqual;
}

test "function bounds shadow class bounds and mark intersections incomplete" {
    const a = std.testing.allocator;
    var m = Module.default(a);
    defer m.deinit(a);
    const owner_id = try m.addClass(a, .{
        .id = ir.ClassId.from(0),
        .name = "Owner",
        .fqn = "sample.Owner",
        .package = "sample",
        .type_params = &.{"T"},
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
    try m.registry.class_type_param_bounds.put(
        "sample.Owner",
        try a.dupe(ir.ModuleRegistry.TypeParamBound, &.{
            .{ .param = "T", .bound = "kotlin.Any" },
        }),
    );
    const previous_package = build.setLowerSelfPackage("sample");
    defer _ = build.setLowerSelfPackage(previous_package);
    var b = try FuncBuilder.init(a, &m);
    defer b.deinit();

    const sp = ast.Span{ .file = ir.FileId.from(0), .start = 0, .end = 1 };
    const reserved = m.nextFuncId();
    try m.appendFunc(.{
        .id = reserved,
        .name = "value",
        .fqn = "sample.Owner.value",
        .package = "sample",
        .params = &.{},
        .return_ty = build.typeUnit(),
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .kind = .instance_method,
    });
    try m.recordFuncDeclSpan(a, sp, reserved);
    try m.decl_sigs.put(reserved.int(), .{
        .enclosing_class = owner_id,
        .arity = .{ .required = 0, .total = 0, .has_vararg = false },
        .sig = &.{},
        .kind = .instance_method,
        .has_body = true,
    });
    const number_ty = ast.TypeRef{
        .name = .{ .name = "Number", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const params = [_]ast.TypeParam{.{
        .name = .{ .name = "T", .span = sp },
        .variance = .Invariant,
        .upper_bound = number_ty,
        .is_reified = false,
        .annotations = &.{},
        .span = sp,
    }};
    const comparable_ty = ast.TypeRef{
        .name = .{ .name = "Comparable", .span = sp },
        .nullable = false,
        .span = sp,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const where_bounds = [_]ast.WhereBound{.{
        .name = .{ .name = "T", .span = sp },
        .bound = comparable_ty,
        .span = sp,
    }};
    var f: ast.Function = undefined;
    f.name = .{ .name = "value", .span = sp };
    f.span = sp;
    f.type_params = @constCast(&params);
    f.where_bounds = @constCast(&where_bounds);

    try addScopedTypeParamBounds(&b, &m, "Owner", &f);
    const bounds = (try b.typeParamBoundsSlice()).?;
    defer a.free(bounds);
    try std.testing.expectEqual(@as(usize, 2), bounds.len);
    var saw_class = false;
    var saw_function = false;
    for (bounds) |bound| {
        if (std.mem.startsWith(u8, bound.param, "$class$")) {
            saw_class = true;
            try std.testing.expectEqualStrings("kotlin.Any", bound.bound);
            try std.testing.expect(bound.complete);
        } else if (std.mem.eql(u8, bound.param, "T")) {
            saw_function = true;
            try std.testing.expectEqualStrings("Number", bound.bound);
            try std.testing.expect(!bound.complete);
        }
    }
    try std.testing.expect(saw_class);
    try std.testing.expect(saw_function);
}

test "bind params loads each param and marks it" {
    var m = Module.default(std.testing.allocator);
    defer m.deinit(std.testing.allocator);
    var b = try FuncBuilder.init(std.testing.allocator, &m);
    defer b.deinit();
    const names = [_][]const u8{ "a", "b" };
    try bindParams(&b, &names);
    try std.testing.expect(b.isParam("a"));
    try std.testing.expect(b.isParam("b"));
    try std.testing.expect(b.resolve("a") != null);
    try std.testing.expect(b.resolve("b") != null);
}
