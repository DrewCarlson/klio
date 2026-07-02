//! Declaration lowering — the build driver's entry points: class /
//! function / method lowering. Free functions over the lowering
//! context. `bindParams` (used by the thunk lowerings) is shared with
//! the foundation.

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
const StringFuncIdMap = std.StringHashMap(FuncId);

/// File-scoped class registry: simple name → AST class. Threaded through
/// the public lowering entry points so cross-class member lookups resolve.
pub const FileClasses = std.StringHashMap(FF(ast.Class));

/// Resolve each source annotation to its fully-qualified candidate names
/// using the declaring file's imports. A qualified annotation path
/// (`@a.b.C`) yields the joined dotted path. A simple name `N` yields the
/// FQN of every named import bound to `N` (the alias's import path when an
/// alias matches), `A.B.N` for each `import A.B.*`, and always the bare
/// `N` as a fallback. The returned slice is de-duplicated and owned by
/// `module.registry.allocator`, matching the class/func side-table slices.
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

/// Bind function parameters into the current scope. Each param is loaded
/// into a fresh register via `Inst.LoadParam` so subsequent `Path { name }`
/// reads route through the same register.
// Param index is a u16 slot; a function's parameter count fits it.
pub fn bindParams(b: *FuncBuilder, names: []const []const u8) Allocator.Error!void {
    for (names, 0..) |name, i| {
        const dst = b.allocReg();
        try b.push(.{ .LoadParam = .{ .dst = dst, .idx = @intCast(i) } });
        if (b.isBoxed(name)) {
            // A parameter that a nested closure *writes* (e.g.
            // `consumeEach { destination += it }`) is a captured-and-mutated
            // enclosing local just like a body `var`: box it into a shared
            // `Value.Cell` so the closure's write lands on the cell and is
            // visible here (Kotlin `Ref` semantics). Reads emit `CellGet`,
            // writes `CellSet`, off the home reg holding the cell.
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

/// Lower a Kotlin class declaration into an IR Class. Methods are
/// lowered as Funcs with a synthetic `<receiver>` first parameter
/// (the constructor params are lifted onto the Class's
/// `primary_params` for instance construction). The Class becomes
/// reachable through `module.class_id` so Path-callees that name
/// the class lower to `NewInstance`.
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

/// Like [`lowerClassWithExtras`] but stamps the IR class with a
/// caller-supplied package-qualified FQN. Two packages may declare
/// the same simple class name; a distinct FQN lets `addClass` keep
/// them as separate definitions instead of collapsing one onto the
/// other.
pub fn lowerClassWithExtrasFqn(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    extra_members: *const StringSet,
    class_fqn: []const u8,
) Allocator.Error!ClassId {
    return lowerClassWithExtrasFqnPkg(module, c, file_classes, extra_members, class_fqn, ir.packageOfFqn(class_fqn, c.name.name));
}

/// Like [`lowerClassWithExtrasFqn`] but with the class's DECLARING
/// package supplied explicitly. A nested/companion class's FQN is
/// class-qualified (`pkg.Outer.Inner`), so deriving the package from it
/// would hand the symbol index a phantom package; the build driver knows
/// the file's package and passes it here.
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

/// Package-qualified FQN for the class currently being lowered by
/// `lowerClassWithExtrasFqn`. Read once where the IR `Class` shell is
/// created. A module-level global keeps the existing public signatures
/// (and their other callers/tests) unchanged.
var lower_class_fqn: ?[]const u8 = null;

/// Declaring package matching `lower_class_fqn`, supplied by the build
/// driver (null falls back to deriving it from the FQN).
var lower_class_pkg: ?[]const u8 = null;

/// The caller-package seed lives next to `FuncBuilder` (every builder
/// reads it on init); re-exported here for the build drivers.
pub const setLowerSelfPackage = build.setLowerSelfPackage;

/// Names captured by the anonymous object whose method is being lowered
/// (`object : Flow { collect(c) { c.block() } }` where `block` is an
/// enclosing inline fn's crossinline param). These reach the method
/// body as runtime-injected scoped globals, so a `recv.name()` whose
/// `name` is one of them must dispatch as CallMemberOrValue with a
/// `LoadGlobal(name)` fallback (the receiver's member wins if present,
/// else the captured callable is invoked with the receiver bound).
threadlocal var lower_anon_captures: ?StringSet = null;

/// Install / clear the set of capture names used while lowering an
/// anonymous-object's method bodies. `null` clears it. Takes ownership of
/// `names` when present.
pub fn setLowerAnonCaptures(names: ?StringSet) void {
    if (lower_anon_captures) |*old| old.deinit();
    lower_anon_captures = names;
}

pub fn isLowerAnonCapture(name: []const u8) bool {
    if (lower_anon_captures) |*c| return c.contains(name);
    return false;
}

/// Collect a class's own + inherited member names into `out`, walking
/// every supertype reachable through the file's class registry.
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

/// The bit `i` of a member's arity mask is set when some overload binds
/// exactly `i` user arguments; bit 63 marks a vararg overload (accepts any
/// count). Mirrors `collectMembers`' walk so member-vs-global resolution can
/// be arity-aware.
fn funcArityMask(f: *const ast.Function) u64 {
    var required: usize = 0;
    var any_vararg = false;
    for (f.params) |*p| {
        if (p.is_vararg) any_vararg = true;
        if (p.default == null and !p.is_vararg) required += 1;
    }
    if (any_vararg) return @as(u64, 1) << 63;
    var mask: u64 = 0;
    // Every count from `required` up to the full parameter count binds (the
    // trailing defaulted params may be omitted).
    var n = required;
    while (n <= f.params.len and n < 63) : (n += 1) mask |= @as(u64, 1) << @intCast(n);
    return mask;
}

fn mergeMemberArity(out: *std.StringHashMap(u64), name: []const u8, mask: u64) Allocator.Error!void {
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
    }
    for (c.supertypes) |*sup| {
        if (file_classes.get(sup.name.name)) |parent| {
            try collectMemberArities(parent.get(), file_classes, out, seen);
        }
    }
}

/// Add enum-entry, nested-class, and companion-member names that are
/// visible under their bare names inside the class's method bodies.
fn addVisibleMemberNames(
    c: *const ast.Class,
    own_member_names: *StringSet,
) Allocator.Error!void {
    // Enum entry names are visible under their bare names inside the
    // enum's method bodies (e.g. `RED` in a `Color.hex()` method).
    // `entries` resolves to the built-in synthesized list of all
    // entries.
    if (c.is_enum) {
        for (c.enum_entries) |*entry| {
            try own_member_names.put(entry.name.name, {});
        }
        // Built-in members on every enum entry: synthesised `name`
        // (entry simple name) and `ordinal` (declaration index). Bare
        // access from method bodies resolves to `this.name` /
        // `this.ordinal`.
        try own_member_names.put("entries", {});
        try own_member_names.put("name", {});
        try own_member_names.put("ordinal", {});
    }
    // Nested class / enum / object names are visible under their bare
    // names inside the enclosing class's method bodies (e.g.
    // `TrafficLight.State.RED` reachable as `State.RED` from a
    // TrafficLight method).
    for (c.members) |*m| {
        if (m.* == .Class and !m.Class.is_companion) {
            try own_member_names.put(m.Class.name.name, {});
        }
    }
    // Companion-object members are visible under their bare names inside
    // this class's method bodies.
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

/// Lower the default-arg thunks of a bodyless (abstract) method and
/// stash them under `(class, method)` so a concrete override inherits
/// the declaration's default values.
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
    const key = ir.StrPair{ .a = c.name.name, .b = f.name.name };
    try module.registry.abstract_member_defaults.put(key, slots);
}

/// Same as `lowerClassWithFile` but mixes an additional set of member
/// names into the class's `own_members`. Used when a nested class is
/// lifted to top level: the outer's property + method names are added
/// so bare references inside the inner's body lower as `this.X`
/// (resolved against the captured outer at runtime) instead of
/// `LoadGlobal(X)`.
/// Lower a class's primary-constructor parameters (names + lowered types).
/// Exposed so a build pre-pass can fill every class's `primary_params` before
/// any method body is lowered — a constructor call to a forward-declared class
/// (`class A { fun f() = B("x") {} }; class B(...)`) must see B's parameter
/// types for the argument-lambda arity / trailing-lambda realignment.
pub fn classPrimaryParams(a: Allocator, c: *const ast.Class) Allocator.Error![]Param {
    var primary_params: std.ArrayList(Param) = .empty;
    errdefer primary_params.deinit(a);
    for (c.primary_params) |*p| {
        try primary_params.append(a, .{
            .name = p.name.name,
            // Preserve the lowered parameter type (notably a `Function{N}`
            // head for a `T.() -> R` param) so an argument lambda can read
            // its expected arity and drop a synthetic `it`.
            .ty = try loweredTypeRef(a, &p.ty, false),
            .default = null,
            .is_property = p.property != null,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        });
    }
    return primary_params.toOwnedSlice(a);
}

pub fn lowerClassWithExtras(
    module: *Module,
    c: *const ast.Class,
    file_classes: *const FileClasses,
    extra_members: *const StringSet,
) Allocator.Error!ClassId {
    const a = module.registry.allocator;

    // Register the class shell first so the class name resolves inside
    // its own method bodies (`class Foo { fun copy() = Foo(...) }`).
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
        .is_inner = c.is_inner,
        .is_abstract = c.is_abstract or c.is_interface or c.is_sealed,
    });
    // Collect this class's own member names so method-body lowering can
    // tell `someMember()` (this.someMember) apart from `topLevelFn()`
    // (LoadGlobal). The lexically-enclosing class's members
    // (`extra_members`, for a lifted nested/inner class) are kept SEPARATE
    // — they are members of an enclosing `this@Outer`, reached only
    // through the implicit-receiver candidate walk, never through a direct
    // `this.<name>` on this receiver. Merging them into `own_members`
    // would route an enclosing-member bare call to a plain `CallMember` on
    // this receiver, which then resolved only via the runtime outer-link
    // fallback — a leniency that also fired for a `with`-subject whose
    // outer tower is not in scope. Routing them through the candidate
    // resolver instead matches kotlinc: the inner's own `this` then its
    // `outer` links are searched, while a subject brings only itself.
    var own_member_names = StringSet.init(a);
    defer own_member_names.deinit();
    // Walk this class + every supertype reachable through the file's
    // class registry so inherited member names also route as
    // `this.<name>` in method-body lowering.
    var seen_for_collect = StringSet.init(a);
    defer seen_for_collect.deinit();
    try collectMembers(c, file_classes, &own_member_names, &seen_for_collect);
    try addVisibleMemberNames(c, &own_member_names);
    // Per-member arity masks, so a method body's bare call prefers a member
    // only when one is arity-applicable (a 0-arg member must not shadow a
    // same-named 1-arg top-level function).
    var own_member_arity = std.StringHashMap(u64).init(a);
    defer own_member_arity.deinit();
    var seen_for_arity = StringSet.init(a);
    defer seen_for_arity.deinit();
    try collectMemberArities(c, file_classes, &own_member_arity, &seen_for_arity);

    var methods: std.ArrayList(FuncId) = .empty;
    errdefer methods.deinit(a);
    // Track private methods lowered so far in declaration order so a
    // later method's body can statically bind to an earlier private
    // sibling's FuncId rather than virtual-dispatching it (Kotlin:
    // private members are invisible to subclasses, so the dispatch is
    // fixed to the declaring class). Forward-references would need a
    // reservation pass; the common case (helper declared before its
    // caller) is covered.
    var private_method_fids = StringFuncIdMap.init(a);
    defer private_method_fids.deinit();
    for (c.members) |*m| {
        if (m.* == .Function) {
            const f = &m.Function;
            // Skip bodyless methods (abstract decls in interfaces /
            // abstract classes). They'd lower to a func that just
            // returns Unit; the IR-native member dispatch must fall
            // through to the real override on a concrete subclass, not
            // the abstract slot.
            if (f.body == null) {
                // The abstract slot itself is skipped, but a concrete
                // `override` inherits this declaration's default-arg
                // values. Lower the default thunks and stash them by
                // (class, method) so the build pass can fold them onto
                // the override's own (default-less) parameter slots.
                try recordAbstractMemberDefaults(module, c, f);
                continue;
            }
            // Use the method's own FuncId, not `funcs.len() - 1`:
            // lowering a method also pushes its default-arg thunk funcs,
            // so the last slot is no longer the method body.
            const placed = try lowerMethodWithPrivate(
                module,
                f,
                c.name.name,
                &own_member_names,
                extra_members,
                &private_method_fids,
                &own_member_arity,
            );
            try methods.append(a, placed.id);
            // Record this method by (class, name, declared arity) so a sibling
            // method body lowered later can statically reach its signature
            // (owner-scoped, so a same-named member of an unrelated class is
            // never mistaken for it).
            {
                const ukey = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ c.name.name, f.name.name, f.params.len });
                const gop = try module.registry.member_method_fids.getOrPut(ukey);
                if (gop.found_existing) {
                    a.free(ukey);
                } else {
                    gop.value_ptr.* = placed.id;
                }
            }
            // Unified declaration record: the member half of the canonical
            // index (the split decl_user_* tables cover only top-level
            // declarations). Keys receiver-type membership queries and
            // exact static member binds.
            {
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
                try module.decl_sigs.put(placed.id.int(), .{
                    .enclosing_class = module.classId(c.name.name),
                    .receiver_ty = if (f.receiver_type) |*rt| try loweredTypeRef(a, rt, true) else null,
                    .arity = .{ .required = required, .total = @intCast(f.params.len), .has_vararg = has_vararg },
                    .sig = msig,
                    .kind = if (f.receiver_type != null) .member_extension else .instance_method,
                    .is_inline = f.is_inline,
                    .is_suspend = f.is_suspend,
                    .has_body = true,
                });
            }
            if (f.visibility == .Private) {
                try private_method_fids.put(f.name.name, placed.id);
            }
        }
    }
    var supertypes: std.ArrayList(ClassId) = .empty;
    errdefer supertypes.deinit(a);
    // A supertype reference resolves from the declaring class's own
    // scope (its package + its file's imports), so a cross-package
    // simple-name collision binds the supertype this class can see.
    const class_pkg = lower_class_pkg orelse ir.packageOfFqn(class_fqn, c.name.name);
    for (c.supertypes) |*t| {
        // A qualified supertype (`Outer.Inner`) disambiguates a nested base
        // from a same-simple-name class in scope — including this class's own
        // nested type. Resolve it through the nested-lift registry first so a
        // subtype named like its base (`Engine.Configuration :
        // ApplicationEngine.Configuration()`) binds the base, not itself.
        if (t.qualified_path) |qp| {
            if (module.classIdByQualifiedSuffix(qp)) |cid| {
                try supertypes.append(a, cid);
                continue;
            }
        }
        if (module.classIdIndexed(t.name.name, class_pkg, t.name.span.file)) |cid| {
            try supertypes.append(a, cid);
        }
    }
    // Patch the registered class with its now-known method list and
    // resolved supertypes.
    if (class_id.int() < module.classes.items.len) {
        const slot = &module.classes.items[class_id.int()];
        slot.methods = try methods.toOwnedSlice(a);
        slot.supertypes = try supertypes.toOwnedSlice(a);
    }
    return class_id;
}

/// Lower one AST function into an IR Func. The function body is lowered
/// into the entry block; parameters are bound via `bindParams`; the
/// trailing implicit return falls through to a `Return` terminator.
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
    const nm = f.name.name;
    try module.func_index.append(a, .{ .name = nm, .id = id });
    try funcNameIndexPush(module, nm, id);
    try module.funcs.append(a, placed);
    return placed;
}

/// Lower a function body without registering it in `module.func_index`.
/// Used by the interpreter's pre-pass-then-fill driver so a function's
/// `FuncId` is reserved before its body is lowered (enabling forward
/// references and mutual recursion).
pub fn lowerFunctionBodyInto(
    module: *Module,
    f: *const ast.Function,
    file_classes: *const FileClasses,
) Allocator.Error!Func {
    return lowerFunctionBody(module, f, file_classes);
}

/// Lowered name for a parameter's declared type. A function type
/// `(A, B) -> R` is tagged `Function2` (arity = number of parameters,
/// receiver excluded) so runtime overload resolution can match a lambda
/// argument by its parameter count — the only way to tell apart
/// overloads that differ solely in the shape of a functional parameter.
pub fn loweredTypeName(allocator: Allocator, ty: *const ast.TypeRef) Allocator.Error![]const u8 {
    if (ty.function) |ft| {
        return std.fmt.allocPrint(allocator, "Function{d}", .{ft.params.len});
    }
    return ty.name.name;
}

/// Lowered structural form of a declared type: the head keeps
/// `loweredTypeName`'s rendering (so runtime overload matching, which
/// reads only the head name and nullability, is unchanged) while `args`
/// carries the full recursive shape — generic type arguments, and for a
/// function type its receiver, parameter, and return types. Source
/// facts with no head-name slot are encoded as synthetic marker args
/// (`#suspend` for a suspend function type, `#non-null` for `T & Any`,
/// `#qual:a.b.C` for a qualified path, `*` for a star projection, an
/// `in#`/`out#` head prefix for a variance projection) so two parameter
/// lists prove identical only when the declared types really are. With
/// `own_names` every string is duped into `allocator` so the result can
/// be deep-freed (the phase-1 declared-signature record); body params
/// borrow the AST names like the rest of the lowered IR.
pub fn loweredTypeRef(allocator: Allocator, ty: *const ast.TypeRef, own_names: bool) Allocator.Error!ir.TypeRef {
    var args: std.ArrayList(ir.TypeRef) = .empty;
    errdefer args.deinit(allocator);
    var head: []const u8 = undefined;
    if (ty.function) |ft| {
        head = try std.fmt.allocPrint(allocator, "Function{d}", .{ft.params.len});
        if (ft.is_suspend) try args.append(allocator, try markerRef(allocator, "#suspend", own_names));
        if (ft.receiver) |*recv| try args.append(allocator, try loweredTypeRef(allocator, recv, own_names));
        for (ft.params) |*p| try args.append(allocator, try loweredTypeRef(allocator, p, own_names));
        try args.append(allocator, try loweredTypeRef(allocator, &ft.ret, own_names));
    } else {
        head = if (own_names) try allocator.dupe(u8, ty.name.name) else ty.name.name;
        for (ty.type_args) |*ta| try args.append(allocator, try loweredTypeArg(allocator, ta, own_names));
    }
    if (ty.definitely_non_null) try args.append(allocator, try markerRef(allocator, "#non-null", own_names));
    if (ty.qualified_path) |qp| {
        try args.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "#qual:{s}", .{qp}),
            .nullable = false,
            .args = &.{},
        });
    }
    return .{ .name = head, .nullable = ty.nullable, .args = try args.toOwnedSlice(allocator) };
}

fn loweredTypeArg(allocator: Allocator, ta: *const ast.TypeArg, own_names: bool) Allocator.Error!ir.TypeRef {
    if (ta.is_star) return markerRef(allocator, "*", own_names);
    var lowered = try loweredTypeRef(allocator, &ta.ty, own_names);
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

/// Collect an extension receiver's own + inherited member names, walking
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
    // Extension functions (`fun T.foo(...)`) need `this` bound as the
    // implicit first param so the body's references to `this` and
    // `this.x` resolve through the receiver reg rather than as a free
    // global. Plain top-level functions have no receiver, so no implicit
    // params.
    if (f.receiver_type) |recv| {
        var members = StringSet.init(a);
        defer members.deinit();
        if (file_classes.get(recv.name.name)) |parent_cls| {
            var seen = StringSet.init(a);
            defer seen.deinit();
            try collectRecvMembers(parent_cls.get(), file_classes, &members, &seen);
        }
        // The receiver type is usually declared in another file (a pack
        // declares the interface in one file and its extensions in
        // another — `Source` in Source.kt, `Source.readString` in
        // Utf8.kt). The module registry carries each type's transitive
        // member-function names regardless of declaring file, so a bare
        // call to a receiver member inside the extension body resolves
        // to that member (Kotlin: an implicit-receiver member shadows a
        // same-named top-level function) rather than mis-binding to the
        // top-level function — e.g. `require(byteCount)` reaching
        // `Source.require(Long)`, not `kotlin.require(Boolean)`.
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

/// Record a class method's per-parameter default-arg thunks under its
/// body `FuncId`, so a call that omits trailing defaulted args
/// (`A().g(5)` for `fun g(x, y = 10)`) gets them filled — the same
/// padding top-level / local functions already get. Methods carry an
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
            // Pass the owner class + own-member set so a default
            // expression that references an enclosing-class member
            // (`fun mix(a, b=a*2, c=base+b)` where `base` is a class
            // member) routes the bare name through `this.<member>`
            // instead of an unresolved global lookup.
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

pub fn lowerMethod(
    module: *Module,
    f: *const ast.Function,
    owner_class: []const u8,
    own_members: *const StringSet,
) Allocator.Error!Func {
    var empty = StringFuncIdMap.init(module.registry.allocator);
    defer empty.deinit();
    var no_enclosing = StringSet.init(module.registry.allocator);
    defer no_enclosing.deinit();
    return lowerMethodWithPrivate(module, f, owner_class, own_members, &no_enclosing, &empty, null);
}

pub fn lowerMethodWithPrivate(
    module: *Module,
    f: *const ast.Function,
    owner_class: []const u8,
    own_members: *const StringSet,
    enclosing_members: *const StringSet,
    private_method_fids: *const StringFuncIdMap,
    own_member_arity: ?*const std.StringHashMap(u64),
) Allocator.Error!Func {
    const a = module.registry.allocator;
    // A member extension function (`class C { fun R.f(p) { … } }`) binds
    // its *extension* receiver as `this`, like a top-level extension fn.
    // A bare member reference in its body may be a member of the
    // extension receiver `R` *or* of the enclosing class `C` (`this@C`).
    // Passing `C`'s `own_members` here would force every such reference
    // into a `this.member` access on the *extension* receiver, so `C`
    // members fail. Pass no own-members instead: bare references then
    // lower through the dynamic `this` → enclosing-`this` → global
    // probe, which tries `R`, then the lexically enclosing `C` instance
    // (kept reachable by the caller via the enclosing-`this` stack),
    // then a global. It is also registered in `func_index` so a bare
    // call resolves through the same extension-call lowering top-level
    // extensions use (the receiver is prepended as the implicit `this`).
    if (f.receiver_type != null) {
        const implicit = [_][]const u8{"this"};
        const func = try lowerFunctionBodyWithImplicitOwnerEnclosing(module, f, &implicit, null, null, enclosing_members, null, null);
        const id = module.nextFuncId();
        var placed = func;
        placed.id = id;
        placed.kind = .member_extension;
        try module.funcs.append(a, placed);
        try registerFuncTypeParams(module, f, id);
        const nm = f.name.name;
        try module.func_index.append(a, .{ .name = nm, .id = id });
        try funcNameIndexPush(module, nm, id);
        // Tag this member-extension with its declaring class so the
        // runtime extension-fallback dispatch can filter it out at call
        // sites whose enclosing class chain doesn't include the
        // declaring class.
        try module.registry.member_ext_owner_class.put(id, owner_class);
        // Extension member: no enclosing-class own-members in scope (the
        // receiver is `this`, not the declaring class), so the thunk
        // runs with no owner_class context.
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
        private_method_fids,
        own_member_arity,
    );
    const id = module.nextFuncId();
    var placed = func;
    placed.id = id;
    placed.kind = .instance_method;
    try module.funcs.append(a, placed);
    try registerFuncTypeParams(module, f, id);
    try recordMethodParamDefaults(module, f, id, owner_class, own_members);
    return placed;
}

/// Register a declaration's type-parameter names in the module registry so
/// generic-signature checks (a callee-generic `::name` slot, the generic
/// native-marking escape, call-site type-arg binding) see methods the same
/// way they see top-level functions.
fn registerFuncTypeParams(module: *Module, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    if (f.type_params.len == 0) return;
    const a = module.registry.allocator;
    var tp_names: std.ArrayList([]const u8) = .empty;
    for (f.type_params) |*tp| try tp_names.append(a, tp.name.name);
    try module.registry.func_type_params.put(id, tp_names);
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
        null,
    );
}

pub fn lowerFunctionBodyWithImplicitOwnerPriv(
    module: *Module,
    f: *const ast.Function,
    implicit_params: []const []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
    private_method_fids: ?*const StringFuncIdMap,
) Allocator.Error!Func {
    return lowerFunctionBodyWithImplicitOwnerEnclosing(
        module,
        f,
        implicit_params,
        owner_class,
        own_members,
        null,
        private_method_fids,
        null,
    );
}

/// Lower a method body, threading the lexically-enclosing class's member
/// names (a lifted nested/inner class's outer members) as the builder's
/// `enclosing_members` — distinct from `own_members`. An enclosing member
/// is in scope only through the implicit-receiver candidate walk
/// (`this` → its `outer` links), so a bare reference to one resolves
/// through that walk, not a direct `this.<name>` on this receiver.
pub fn lowerFunctionBodyWithImplicitOwnerEnclosing(
    module: *Module,
    f: *const ast.Function,
    implicit_params: []const []const u8,
    owner_class: ?[]const u8,
    own_members: ?*const StringSet,
    enclosing_members: ?*const StringSet,
    private_method_fids: ?*const StringFuncIdMap,
    own_member_arity: ?*const std.StringHashMap(u64),
) Allocator.Error!Func {
    const a = module.registry.allocator;
    var b = try FuncBuilder.init(a, module);
    defer b.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    try names.appendSlice(a, implicit_params);
    for (f.params) |*p| try names.append(a, p.name.name);
    // Compute the boxed-var set before binding params so a parameter that a
    // nested closure *writes* is bound as a shared cell (Kotlin `Ref`). The
    // body-`var` half comes from `computeBoxedVars`; here we additionally box
    // any parameter a nested lambda mutates.
    if (f.body) |body| {
        if (body == .Block) {
            var boxed = try mod.computeBoxedVars(a, body.Block.stmts);
            var assigned = mod.ast_scan.StringSet.init(a);
            defer assigned.deinit();
            try mod.ast_scan.namesAssignedInLambdas(body.Block.stmts, &assigned);
            for (names.items) |pname| {
                if (assigned.contains(pname)) try boxed.put(pname, {});
            }
            b.setBoxedVars(boxed);
        }
    }
    try bindParams(&b, names.items);
    // A user parameter literally named `this` (backtick-quoted in source) on
    // a receiver-less function is an ordinary value binding, not a dispatch
    // receiver: bare calls in the body must not member-dispatch through it.
    if (implicit_params.len == 0 and owner_class == null) {
        for (f.params) |*p| {
            if (std.mem.eql(u8, p.name.name, "this")) b.this_is_plain_param = true;
        }
    }
    // Record each declared parameter's static type head so a cast-rebound call
    // can disambiguate overloads by an argument that names a parameter (an
    // `Iterable<Int>` parameter must not bind an `IntRange`-typed overload slot).
    for (f.params) |*p| {
        try b.setLocalDeclType(p.name.name, p.ty.name.name);
        if (p.ty.nullable) try b.setLocalDeclNullable(p.name.name);
    }
    // Labeled-receiver alias: `this@<fn>` names this function's receiver. A
    // qualified `this@fn` in a nested lambda (e.g.
    // `sequence { for (x in this@mine) ... }`) then captures this receiver
    // rather than resolving the lambda's own `this` (the builder scope).
    if (names.items.len != 0 and std.mem.eql(u8, names.items[0], "this")) {
        if (b.resolve("this")) |this_reg| {
            const label = try std.fmt.allocPrint(a, "this@{s}", .{f.name.name});
            try b.bind(label, this_reg);
        }
    }
    // A param whose declared type is a receiver-typed function
    // (`block: T.() -> R`) carries that fact so a bare call `block(...)`
    // inside the body lowers to a member-call with the enclosing `this`
    // as receiver. Implicit params (like the class `this` injected for
    // methods) never come in this shape, so we only walk the source
    // params.
    for (f.params) |*p| {
        if (p.ty.function) |ft| {
            if (ft.receiver != null) {
                try b.markReceiverLambdaParam(p.name.name);
            }
        }
    }
    // A param whose declared type is one of the function's own generic
    // type-parameters (e.g. `a: T` of `fun <T : Comparable<T>>`).
    // Comparison operators on such an operand follow Kotlin's
    // `compareTo`-based total order, not the IEEE primitive — the
    // comparison-lowering arm consults this.
    {
        var tp_names = StringSet.init(a);
        defer tp_names.deinit();
        for (f.type_params) |*tp| try tp_names.put(tp.name.name, {});
        b.setHasOwnTypeParams(f.type_params.len != 0);
        for (f.params) |*p| {
            if (p.ty.function == null and !p.ty.nullable and tp_names.contains(p.ty.name.name)) {
                try b.markGenericTypedParam(p.name.name);
            }
            // A concrete non-function param type (not a function type, not a
            // bare generic type-parameter): such a param does not shadow a
            // same-named top-level function for a call (`flow: Flow<T>` vs the
            // `flow {}` builder).
            if (p.ty.function == null and !tp_names.contains(p.ty.name.name)) {
                try b.markNonFnParam(p.name.name);
            }
            // A param statically typed as a broad collection (`Iterable`/
            // `Collection`): `p + x` / `p - x` returns a `List` even when the
            // runtime value is a `Set`, so the operator lowering coerces it.
            if (p.ty.function == null and helpers.isBroadCollectionTypeName(p.ty.name.name)) {
                try b.markBroadCollectionLocal(p.name.name);
            }
        }
    }
    // A param declared `Any` / `Any?` holds a boxed value, so `==` on it uses
    // total-order equality (`NaN == NaN`, `0.0 != -0.0`) like `Double.equals`.
    // `kotlin.test`'s `assertEquals(expected: Any?, actual: Any?)` relies on
    // this for boxed `Double`/`Float` comparisons.
    for (f.params) |*p| {
        if (p.ty.function == null and std.mem.eql(u8, p.ty.name.name, "Any")) {
            try b.markAnyTyped(p.name.name);
        }
    }
    if (owner_class) |owner| {
        b.setOwnerClass(owner);
    }
    // Record the enclosing extension's declared receiver type so a bare
    // call to a same-named extension inside the body resolves to the
    // overload whose receiver type matches (e.g. `Source.takeWhile` over
    // `CharSequence.takeWhile` inside `fun Source.forEach`).
    b.setRecvTy(if (f.receiver_type) |r| r.name.name else null);
    if (own_members) |set| {
        b.setOwnMembers(try cloneStringSet(a, set));
    }
    if (enclosing_members) |set| {
        if (set.count() != 0) b.setEnclosingMembers(try cloneStringSet(a, set));
    }
    if (private_method_fids) |map| {
        b.setPrivateMethodFids(try cloneStringFuncIdMap(a, map));
    }
    if (own_member_arity) |map| {
        var copy = std.StringHashMap(u64).init(a);
        var it = map.iterator();
        while (it.next()) |e| try copy.put(e.key_ptr.*, e.value_ptr.*);
        b.setOwnMemberArity(copy);
    }
    if (f.is_tailrec) {
        b.setTailrecSelf(f.name.name);
        b.setTailrecSelfHasThis(names.items.len != 0 and std.mem.eql(u8, names.items[0], "this"));
    }
    b.setInline(f.is_inline);
    // The declared return type is the expected type for both an
    // expression body (`fun f(): T = …`) and a `return …` inside a block
    // body, so a reified inline call can infer its type argument.
    b.setDeclaredReturn(f.return_type);
    // The boxed-var set (body `var`s plus nested-closure-written params) was
    // computed and set before `bindParams` above so the params bind as cells.
    var result: ?ir.Reg = null;
    if (f.body) |body| {
        switch (body) {
            .Block => |*blk| result = try mod.lowerBlock(&b, blk),
            .Expr => |*e| {
                // An expression body has no statements, so mark its source
                // position here (stack-trace support) — without this a frame
                // running `fun f() = g()` would report no line.
                try b.push(.{ .Trace = .{ .span = e.span() } });
                const prev = b.pushExpected(f.return_type);
                result = try mod.lowerExpr(&b, e);
                b.restoreExpected(prev);
            },
        }
    }
    b.terminate(.{ .Return = result });
    const fqn = f.name.name;
    // Carry the declared return type so the evaluator can normalize a
    // bare integer-literal result to a `Long` return slot (`fun f():
    // Long = 0`). Inferred returns (no annotation) stay `Unit` —
    // harmless, as the coercion only triggers on an explicit `Long`.
    const return_ty: TypeRef = if (f.return_type) |*rt| .{
        .name = try loweredTypeName(a, rt),
        .nullable = rt.nullable,
        .args = &.{},
    } else build.typeUnit();
    var func = try b.finish(f.name.name, fqn, return_ty);

    var params: std.ArrayList(Param) = .empty;
    errdefer params.deinit(a);
    for (implicit_params) |n| {
        try params.append(a, .{
            .name = n,
            .ty = build.typeUnit(),
            .default = null,
            .is_property = false,
            .is_vararg = false,
            .has_default = false,
        });
    }
    for (f.params) |*p| {
        // The full structural type (generic args, function-type shapes)
        // rides on the param so the symbol index can prove or refute
        // signature identity between overloads; runtime overload
        // matching keeps reading only the head name + nullability.
        try params.append(a, .{
            .name = p.name.name,
            .ty = try loweredTypeRef(a, &p.ty, false),
            .default = null,
            .is_property = false,
            .is_vararg = p.is_vararg,
            .has_default = p.default != null,
        });
    }
    func.params = try params.toOwnedSlice(a);
    // An extension fn's synthetic receiver param (`this`) carries the
    // declared receiver type, not the `Unit` placeholder, so runtime
    // overload resolution can pick the right receiver overload (`fun
    // Int.f()` vs `fun Long.f()`) instead of falling back to declaration
    // order.
    if (f.receiver_type) |*rt| {
        if (func.params.len != 0 and std.mem.eql(u8, func.params[0].name, "this")) {
            // Full structural type — head name AND generic arguments — so
            // the strict extension-receiver prover can refute a
            // `List<String>` receiver on a list of Ints instead of
            // proving on the bare head.
            func.params[0].ty = try loweredTypeRef(a, rt, false);
        }
    }
    func.is_suspend = f.is_suspend;
    func.low_priority = isLowPriorityOverload(f);
    // A leading `this` injected via `implicit_params` is a synthesized
    // dispatch/extension receiver, distinguishing it from a user param
    // that merely spells its name `this`.
    func.has_receiver_param = implicit_params.len != 0 and
        std.mem.eql(u8, implicit_params[0], "this");
    func.annotation_names = try resolveAnnotationNames(module, f.annotations);
    return func;
}

/// A function is excluded from overload resolution while any ordinary
/// candidate applies when it carries `@LowPriorityInOverloadResolution`
/// (kotlin-internal) or `@Deprecated(level = DeprecationLevel.ERROR)`.
/// kotlinx.coroutines uses these on the receiver-less `async`/`launch`
/// guard stubs that exist only to produce a compile error and otherwise
/// just `throw`; klio must never bind one over a real overload. Public
/// so phase-1 header registration can mark stubs before their bodies
/// are lowered, keeping the symbol index's low-priority filter
/// order-independent over forward references.
pub fn isLowPriorityOverload(f: *const ast.Function) bool {
    for (f.annotations) |*ann| {
        const leaf: []const u8 = if (ann.path.len != 0) ann.path[ann.path.len - 1].name else "";
        if (std.mem.eql(u8, leaf, "LowPriorityInOverloadResolution")) {
            return true;
        }
        if (std.mem.eql(u8, leaf, "Deprecated")) {
            // `@Deprecated(..., level = DeprecationLevel.ERROR)` and
            // `level = DeprecationLevel.HIDDEN`: neither is a source-level
            // candidate in kotlinc (ERROR rejects the call, HIDDEN hides
            // the declaration entirely — it exists only for binary
            // compatibility), so both rank as guard stubs.
            for (ann.args) |*arg| {
                if (exprMentionsErrorOrHidden(arg)) return true;
            }
        }
    }
    return false;
}

/// Mirror of the Rust `format!("{e:?}").contains("ERROR")` probe used to
/// detect `@Deprecated(level = DeprecationLevel.ERROR)`, extended to
/// `DeprecationLevel.HIDDEN` (not a source-level candidate either): walk
/// the argument expression looking for an identifier / string literal
/// that contains either level name.
fn exprMentionsErrorOrHidden(e: *const ast.Expr) bool {
    switch (e.*) {
        .Path => |p| {
            for (p.segments) |seg| {
                if (std.mem.indexOf(u8, seg.name, "ERROR") != null or std.mem.indexOf(u8, seg.name, "HIDDEN") != null) return true;
            }
        },
        .Member => |m| {
            if (std.mem.indexOf(u8, m.name.name, "ERROR") != null or std.mem.indexOf(u8, m.name.name, "HIDDEN") != null) return true;
            return exprMentionsErrorOrHidden(m.receiver);
        },
        .MemberRef => |m| {
            if (std.mem.indexOf(u8, m.name.name, "ERROR") != null or std.mem.indexOf(u8, m.name.name, "HIDDEN") != null) return true;
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

/// Push `(name, id)` into the parallel `func_name_index` keyed by simple
/// name, mirroring Rust's `func_name_index.entry(nm).or_default().push(id)`.
fn funcNameIndexPush(module: *Module, name: []const u8, id: FuncId) Allocator.Error!void {
    const a = module.registry.allocator;
    const gop = try module.func_name_index.getOrPut(name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, id);
}

/// Duplicate a `StringHashMap(void)` into a fresh owned set sharing the
/// borrowed key slices.
fn cloneStringSet(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

/// Duplicate a `StringHashMap(FuncId)` into a fresh owned map sharing the
/// borrowed key slices.
fn cloneStringFuncIdMap(allocator: Allocator, src: *const StringFuncIdMap) Allocator.Error!StringFuncIdMap {
    var out = StringFuncIdMap.init(allocator);
    var it = src.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "resolveAnnotationNames yields fqn candidates from imports" {
    // Arena-backed so the registry's import strings and the freshly joined
    // result candidates (mixed-ownership) are reclaimed in one shot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Module.default(a);
    const ra = m.registry.allocator;
    const file: ir.FileId = @enumFromInt(0);

    // import kotlin.test.Test ; import t.Skip as Ignore ; import org.junit.*
    // The registry owns and frees every fqn/segs/wildcard string on deinit,
    // so each is duped into the registry allocator.
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
    // @Ignore: aliased import path (the FQN behind the alias) + wildcard + bare.
    try expectContains(got, "t.Skip");
    try expectContains(got, "org.junit.Ignore");
    try expectContains(got, "Ignore");
    // Qualified path passes through verbatim.
    try expectContains(got, "kotlin.test.AfterTest");
}

fn expectContains(haystack: []const []const u8, needle: []const u8) !void {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return;
    }
    return error.TestExpectedEqual;
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
