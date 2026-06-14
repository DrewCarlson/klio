//! `VmHost` class-side dispatch: `is`/`as` checks (`instance_of`,
//! `is_concrete_cast_target`) and runtime class registration for
//! locally-declared / anonymous-object classes lowered during eval.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");

const root = @import("../interp_ir.zig");
const build = @import("../build.zig");
const VmHost = @import("vmhost.zig").VmHost;

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const Env = runtime.Env;
const InstanceData = runtime.InstanceData;
const TypeShape = runtime.TypeShape;
const ClassParamDef = runtime.ClassParamDef;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const TypeRef = ir.TypeRef;
const UnitResult = ir.eval.UnitResult;

/// Whether `name` denotes a concrete type a checked cast can test
/// against (user/pack class, a reified type-param bound to a class,
/// or a builtin). Anything else is an erased type parameter, for
/// which `x as <that>` is an unchecked, non-throwing cast.
pub fn isConcreteCastTarget(self: *VmHost, name: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0) return false;
    // A user / pack class declaration.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().classId(n) != null) return true;
    }
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().contains(n)) return true;
    }
    // A reified type parameter bound to a concrete class value at the
    // call site (`Value::Class` whose name differs from the bare param
    // name) — the cast can be checked against it.
    {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(n)) |v| {
            switch (v) {
                .Class => |c| {
                    const ccg = c.borrow();
                    defer ccg.deinit();
                    if (!std.mem.eql(u8, ccg.get().name, n)) return true;
                },
                else => {},
            }
        }
    }
    return isBuiltinTypeName(n);
}

pub fn instanceOf(self: *VmHost, value: *const Value, ty: TypeRef) bool {
    // `null is T?` is true for any nullable type. `null is T`
    // (non-null T) is false.
    if (value.* == .Null) return ty.nullable;

    // Reified type parameter resolution: the inline-fn splice binds the
    // reified type-param name (e.g. `T`) to the call-site type
    // argument's class value as a global. An `x is T` check against the
    // unresolved type-param name redirects to a check against that bound
    // class's simple name. Only fires when the type name is not already
    // a class in the module — otherwise a legitimate `is Foo` check
    // where `Foo` happens to be registered as a global would recurse
    // forever resolving its own name.
    {
        const module_has_class = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(ty.name) != null;
        };
        if (!module_has_class) {
            if (lookupGlobal(self, ty.name)) |bound| {
                switch (bound) {
                    .Class => |cls| {
                        const cg = cls.borrow();
                        defer cg.deinit();
                        if (!std.mem.eql(u8, cg.get().name, ty.name)) {
                            const resolved: TypeRef = .{
                                .name = cg.get().name,
                                .nullable = ty.nullable,
                                .args = ty.args,
                            };
                            return instanceOf(self, value, resolved);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // `Any` is the universal supertype for non-null values.
    if (std.mem.eql(u8, ty.name, "Any")) return true;

    // Reflection-style checks against synth bound refs. `Box::v` lowers
    // as an Instance with `__bound_receiver__` (a Class for unbound prop
    // refs, an Instance for bound method refs). Match KProperty /
    // KFunction / KCallable accordingly so `is`-checks return what
    // kotlinc produces.
    if (isReflectionTypeName(ty.name)) {
        switch (value.*) {
            .Instance => |inst| {
                const g = inst.borrow();
                defer g.deinit();
                if (g.get().get("__bound_receiver__")) |br| {
                    const is_property = (br == .Class);
                    if (std.mem.eql(u8, ty.name, "KProperty") or
                        std.mem.eql(u8, ty.name, "KMutableProperty")) return is_property;
                    if (std.mem.eql(u8, ty.name, "KFunction") or
                        std.mem.eql(u8, ty.name, "KFunction0") or
                        std.mem.eql(u8, ty.name, "KFunction1") or
                        std.mem.eql(u8, ty.name, "KFunction2")) return !is_property;
                    if (std.mem.eql(u8, ty.name, "KCallable")) return true;
                    return false;
                }
            },
            else => {},
        }
        // `::greet` for a top-level fn surfaces as a Value::IrClosure (or
        // Function). Treat those as KFunction / KCallable.
        switch (value.*) {
            .IrClosure, .Function => {
                return std.mem.eql(u8, ty.name, "KFunction") or
                    std.mem.eql(u8, ty.name, "KCallable") or
                    std.mem.eql(u8, ty.name, "KFunction0") or
                    std.mem.eql(u8, ty.name, "KFunction1") or
                    std.mem.eql(u8, ty.name, "KFunction2");
            },
            else => {},
        }
    }

    if (std.mem.eql(u8, ty.name, "KClass")) return value.* == .Class;
    if (std.mem.eql(u8, ty.name, "EnumEntries")) {
        return switch (value.*) {
            .List => |l| l.enum_class != null,
            else => false,
        };
    }

    // Builtin collection / array / range values match their Kotlin
    // supertype names. klio represents these as host value variants (not
    // user Instances), so without this an `is`/`as` against
    // List/Collection/Iterable/Array/Set/Map/range fails. Mutable views
    // match the Mutable* supertypes too — the read-only/mutable
    // distinction is erased on the JVM, so kotlinc reports `listOf(…) is
    // MutableList` as true; match that.
    switch (value.*) {
        .Array => {
            if (std.mem.eql(u8, ty.name, "Array")) return true;
        },
        .List => {
            if (matchesAny(ty.name, &.{
                "List",            "Collection",          "Iterable",
                "AbstractList",    "AbstractCollection",  "MutableList",
                "MutableCollection", "MutableIterable",   "ArrayList",
                "AbstractMutableList",
            })) return true;
        },
        .Set => {
            if (matchesAny(ty.name, &.{
                "Set",               "Collection",      "Iterable",
                "AbstractSet",       "MutableSet",      "MutableCollection",
                "MutableIterable",   "HashSet",         "LinkedHashSet",
            })) return true;
        },
        .Map => {
            if (matchesAny(ty.name, &.{
                "Map", "AbstractMap", "MutableMap", "HashMap", "LinkedHashMap",
            })) return true;
        },
        .Range => {
            if (matchesAny(ty.name, &.{
                "IntRange",        "LongRange",       "CharRange",
                "IntProgression",  "LongProgression", "CharProgression",
                "ClosedRange",     "OpenEndRange",    "Iterable",
            })) return true;
        },
        else => {},
    }

    // Lambda / function values match `Function<R>`, `Function0`,
    // `Function1`, `Function2`, … (the arity-indexed `FunctionN`
    // hierarchy from kotlin.jvm.functions).
    switch (value.*) {
        .IrClosure, .Function => {
            if (std.mem.eql(u8, ty.name, "Function")) return true;
            if (std.mem.startsWith(u8, ty.name, "Function")) {
                const rest = ty.name["Function".len..];
                if (rest.len != 0 and allAsciiDigit(rest)) return true;
            }
        },
        else => {},
    }

    // Dotted nested-class names (`S.A`, `Outer.Inner`) — match by the
    // last segment, which corresponds to the lifted top-level class name
    // in our module table.
    if (std.mem.indexOfScalar(u8, ty.name, '.')) |_| {
        if (std.mem.lastIndexOfScalar(u8, ty.name, '.')) |i| {
            const last = ty.name[i + 1 ..];
            const alt: TypeRef = .{ .name = last, .nullable = ty.nullable, .args = ty.args };
            return instanceOf(self, value, alt);
        }
    }

    // Generic type-parameter casts (`x as T`) are erased at runtime —
    // Kotlin matches them unchecked. Single-letter (or short uppercase)
    // type names are conventionally generic parameters and have no class
    // entry; treat them as accept-any-non-null — unless the call site
    // bound a reified type-param to a concrete `Value::Class`, in which
    // case redirect the check to that class's name.
    if (matchesAny(ty.name, &.{
        "T", "U", "V", "K", "R", "E", "X", "Y", "Z", "A", "B", "C", "D",
    })) {
        const bound = blk: {
            const gg = self.globals.borrow();
            defer gg.deinit();
            break :blk gg.get().lookup(ty.name);
        };
        if (bound) |b| {
            switch (b) {
                .Class => |c| {
                    const cg = c.borrow();
                    defer cg.deinit();
                    const alt: TypeRef = .{ .name = cg.get().name, .nullable = ty.nullable, .args = ty.args };
                    return instanceOf(self, value, alt);
                },
                else => {},
            }
        }
        const is_user_class = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().contains(ty.name)) break :blk true;
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(ty.name) != null;
        };
        if (!is_user_class) {
            return value.* != .Null;
        }
    }

    // Exception values match by walking the builtin Throwable hierarchy.
    // The nominal type for every Exception loses the specific class name,
    // so resolve `catch (e: IllegalArgumentException)` against the throw
    // site's actual fqn here.
    switch (value.*) {
        .Exception => |e| {
            const g = e.fqn.borrow();
            defer g.deinit();
            const fqn = g.get().*;
            const tail = lastSegment(fqn);
            if (std.mem.eql(u8, tail, ty.name)) return true;
            if (matchesAny(ty.name, &.{ "Throwable", "Any" })) return true;
            // `Error`-side throwables are not `Exception`s: kotlinc
            // matches `catch (e: Error)` and not `catch (e: Exception)`
            // for AssertionError / FileFailedToInitializeException and
            // kin.
            if (std.mem.eql(u8, ty.name, "Exception")) return !isErrorSideThrowable(tail);
            if (std.mem.eql(u8, ty.name, "Error")) return isErrorSideThrowable(tail);
            return builtinExceptionParentMatch(tail, ty.name);
        },
        else => {},
    }

    // User-class instance: walk the runtime ClassDef chain.
    switch (value.*) {
        .Instance => |inst| {
            const builtin_exception_names = [_][]const u8{
                "Throwable",                  "Exception",
                "RuntimeException",           "Error",
                "IllegalArgumentException",   "IllegalStateException",
                "IndexOutOfBoundsException",  "NoSuchElementException",
                "NullPointerException",       "ArithmeticException",
                "ClassCastException",         "NumberFormatException",
                "UnsupportedOperationException", "Any",
            };
            var cur: ?ObjRef(ClassDef) = blk: {
                const g = inst.borrow();
                defer g.deinit();
                break :blk g.get().class.clone();
            };
            while (cur) |c| {
                defer c.deinit();
                cur = null;
                const cg = c.borrow();
                defer cg.deinit();
                const cdef = cg.get();
                if (std.mem.eql(u8, cdef.name, ty.name) or std.mem.eql(u8, cdef.fqn, ty.name)) {
                    return true;
                }
                // Direct + transitive interface supertypes.
                if (interfaceChainMatches(self, cdef, ty.name)) return true;
                // Walk supertype names — covers chains where the direct
                // parent is a built-in exception class that isn't itself
                // in the user class table.
                for (cdef.supertype_names) |sup| {
                    if (std.mem.eql(u8, sup, ty.name)) return true;
                    if (containsStr(&builtin_exception_names, sup) and
                        containsStr(&builtin_exception_names, ty.name)) return true;
                }
                if (cdef.is_anonymous) {
                    for (cdef.supertype_names) |n| {
                        if (std.mem.eql(u8, n, ty.name)) return true;
                    }
                }
                if (cdef.parent) |parent| {
                    cur = parent.clone();
                }
            }
            // `Any` matches every instance.
            if (std.mem.eql(u8, ty.name, "Any")) return true;
            return false;
        },
        else => {},
    }

    const nominal = value.typeFqn();
    if (std.mem.eql(u8, nominal, ty.name)) return true;
    if (nominal.len > ty.name.len + 1 and
        nominal[nominal.len - ty.name.len - 1] == '.' and
        std.mem.eql(u8, nominal[nominal.len - ty.name.len ..], ty.name))
    {
        return true;
    }
    // Builtin runtime types satisfy their nominal supertypes.
    return value.isRuntimeType(ty.name);
}

/// Walk a class's direct + transitive interface supertypes, matching
/// `name` against each.
fn interfaceChainMatches(self: *VmHost, cdef: *const ClassDef, name: []const u8) bool {
    const a = self.allocator;
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |q| q.deinit();
        queue.deinit(a);
    }
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);

    for (cdef.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        if (std.mem.eql(u8, fg.get().name, name) or std.mem.eql(u8, fg.get().fqn, name)) {
            return true;
        }
        queue.append(a, iface.clone()) catch return false;
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const iface = queue.items[head];
        head += 1;
        const fg = iface.borrow();
        defer fg.deinit();
        const idef = fg.get();
        if (containsStr(seen.items, idef.name)) continue;
        seen.append(a, idef.name) catch return false;
        if (std.mem.eql(u8, idef.name, name) or std.mem.eql(u8, idef.fqn, name)) return true;
        for (idef.supertype_names) |sup| {
            if (std.mem.eql(u8, sup, name)) return true;
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(sup)) |d| {
                queue.append(a, d.clone()) catch return false;
            }
        }
        for (idef.interfaces) |sup| {
            queue.append(a, sup.clone()) catch return false;
        }
    }
    return false;
}

/// Throwables on the `kotlin.Error` side of the hierarchy (everything
/// else thrown as a `Value.Exception` descends from `kotlin.Exception`).
fn isErrorSideThrowable(tail: []const u8) bool {
    const error_side = [_][]const u8{
        "Error",                           "AssertionError",
        "NotImplementedError",             "OutOfMemoryError",
        "StackOverflowError",              "FileFailedToInitializeException",
    };
    return containsStr(&error_side, tail);
}

/// Best-effort builtin-Throwable parent walk used for `Value.Exception`
/// `is`/`as` matches when the target is one of the exception class's
/// known parents. The common case here is the immediate parent.
fn builtinExceptionParentMatch(tail: []const u8, target: []const u8) bool {
    const runtime_exc = [_][]const u8{
        "IllegalArgumentException",       "IllegalStateException",
        "IndexOutOfBoundsException",      "ArrayIndexOutOfBoundsException",
        "StringIndexOutOfBoundsException", "NullPointerException",
        "ArithmeticException",            "ClassCastException",
        "NoSuchElementException",         "NumberFormatException",
        "UnsupportedOperationException",  "UninitializedPropertyAccessException",
        "ConcurrentModificationException", "NoWhenBranchMatchedException",
    };
    if (std.mem.eql(u8, target, "RuntimeException") and containsStr(&runtime_exc, tail)) return true;
    if (std.mem.eql(u8, target, "IndexOutOfBoundsException") and
        (std.mem.eql(u8, tail, "ArrayIndexOutOfBoundsException") or
            std.mem.eql(u8, tail, "StringIndexOutOfBoundsException"))) return true;
    if (std.mem.eql(u8, target, "Error") and std.mem.eql(u8, tail, "AssertionError")) return true;
    if (std.mem.eql(u8, target, "Exception") and std.mem.eql(u8, tail, "RuntimeException")) return true;
    if (std.mem.eql(u8, target, "Throwable") and
        (std.mem.eql(u8, tail, "Error") or std.mem.eql(u8, tail, "Exception"))) return true;
    return false;
}

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`/`host_fields.zig`/`host_call_member.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

/// Synthesize a runtime `ClassDef` matching `build_module`'s shape for a
/// local (function-body) class lowered at runtime.
fn synthLocalClassDef(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!ObjRef(ClassDef) {
    _ = self;
    var primary_params = try allocator.alloc(ClassParamDef, class.primary_params.len);
    for (class.primary_params, 0..) |*p, i| {
        primary_params[i] = .{
            .property = p.property,
            .name = p.name.name,
            .default = if (p.default) |*e| e else null,
            .declared_type = p.ty.name.name,
            .declared_shape = try TypeShape.fromTypeRef(allocator, &p.ty),
        };
    }
    var body_props: std.ArrayList(PropertyDef) = .empty;
    for (class.members) |*m| {
        if (m.* != .Property) continue;
        const p = &m.Property;
        try body_props.append(allocator, .{
            .name = p.name.name,
            .mutable = p.mutable,
            .init = if (p.init) |*e| e else null,
            .getter = if (p.getter) |*g| g else null,
            .setter = if (p.setter) |*s| s else null,
            .delegate = if (p.delegate) |*e| e else null,
            .is_abstract = p.is_abstract,
            .is_lateinit = p.is_lateinit,
            .primitive_zero = build.primitiveZeroFor(p),
        });
    }
    var supertype_names = try allocator.alloc([]const u8, class.supertypes.len);
    var supertype_paths = try allocator.alloc(?[]const u8, class.supertypes.len);
    for (class.supertypes, 0..) |*t, i| {
        supertype_names[i] = t.name.name;
        supertype_paths[i] = t.qualified_path;
    }

    const env = try ObjRef(Env).init(allocator, Env.init(allocator));
    return ObjRef(ClassDef).init(allocator, .{
        .name = class.name.name,
        .fqn = class.name.name,
        .annotation_names = &.{},
        .primary_params = primary_params,
        .methods = &.{},
        .body_properties = try body_props.toOwnedSlice(allocator),
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = class.is_data,
        .is_value = class.is_value,
        .is_object = false,
        .is_enum = class.is_enum,
        .is_sealed = class.is_sealed,
        .supertype_names = supertype_names,
        .supertype_paths = supertype_paths,
        .parent = null,
        .interfaces = &.{},
        .is_interface = class.is_interface,
        .is_fun_interface = class.is_fun_interface,
        .parent_ctor_args = &.{},
        .is_open = class.is_open,
        .is_abstract = class.is_abstract,
        .is_inner = class.is_inner,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = env,
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
}

/// Lower each member function of `class` into a per-method side module and
/// register it in `anon_methods` under both the arity-qualified and bare
/// keys, with `capture_pairs` bound. `own_members` scopes bare-name
/// resolution inside the bodies.
fn lowerAndRegisterMethods(
    self: *VmHost,
    allocator: Allocator,
    class: *const ast.Class,
    own_members: *const StringSet,
    capture_pairs: []const NameValue,
) Allocator.Error!void {
    for (class.members) |*m| {
        if (m.* != .Function) continue;
        const f = &m.Function;
        if (f.body == null) continue;
        const sub_ref = try ObjRef(Module).init(allocator, Module.default(allocator));
        const func = try ir.lower.lowerMethod(&sub_ref.cell.data, f, class.name.name, own_members);
        const fid = func.id;
        const caps = try allocator.dupe(NameValue, capture_pairs);
        const entry: AnonMethodEntry = .{ .module = sub_ref, .func = fid, .captures = caps };
        const tbl = self.anon_methods.borrowMut();
        defer tbl.deinit();
        const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
        try tbl.get().put(try anonKey(allocator, class.name.name, arity_name), entry);
        try tbl.get().put(try anonKey(allocator, class.name.name, f.name.name), .{ .module = sub_ref.clone(), .func = fid, .captures = caps });
    }
}

/// Collect a local class's own member names (primary-ctor properties, body
/// properties, methods) into `out`.
fn collectOwnMembers(class: *const ast.Class, out: *StringSet) Allocator.Error!void {
    for (class.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (class.members) |*m| {
        switch (m.*) {
            .Property => |*p| try out.put(p.name.name, {}),
            .Function => |*f| try out.put(f.name.name, {}),
            else => {},
        }
    }
}

pub fn registerClass(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!UnitResult {
    // Local classes declared inside fn bodies arrive here at runtime.
    // Synthesise the same ClassDef shape build_module produces and stash
    // it in the Vm's class table.
    const def = try synthLocalClassDef(self, allocator, class);
    {
        const g = self.classes.borrowMut();
        defer g.deinit();
        try g.get().put(class.name.name, def);
    }
    // Lower local-class methods into per-method side modules.
    var own_members = StringSet.init(allocator);
    defer own_members.deinit();
    try collectOwnMembers(class, &own_members);
    try lowerAndRegisterMethods(self, allocator, class, &own_members, &.{});
    return .ok;
}

pub fn registerClassCaptured(self: *VmHost, allocator: Allocator, class: *const ast.Class, captured_names: []const []const u8, captures: []const Value) Allocator.Error!UnitResult {
    switch (try registerClass(self, allocator, class)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }
    // Snapshot `this` from the captured outer env so instances of this
    // local class get an `outer` pointing back at the enclosing receiver.
    var captured_this: ?Value = null;
    for (captured_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "this") and i < captures.len) {
            captured_this = captures[i];
            break;
        }
    }
    if (captured_this) |this_val| {
        const g = self.class_default_outer.borrowMut();
        defer g.deinit();
        try g.get().put(class.name.name, this_val);
    }
    // Re-lower the local class's methods with the captured outer's field
    // + member names merged into own_members, so bare references to outer
    // properties lower as `this.X` and resolve via the outer chain.
    if (captured_this) |tv| {
        if (tv == .Instance) {
            var own_members = StringSet.init(allocator);
            defer own_members.deinit();
            {
                const ig = tv.Instance.borrow();
                defer ig.deinit();
                const cg = ig.get().class.borrow();
                defer cg.deinit();
                for (cg.get().primary_params) |p| try own_members.put(p.name, {});
                for (cg.get().body_properties) |p| try own_members.put(p.name, {});
            }
            try collectOwnMembers(class, &own_members);
            const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
            try lowerAndRegisterMethods(self, allocator, class, &own_members, capture_pairs);
            return .ok;
        }
    }
    // No `this` instance captured: patch the just-registered method
    // entries with the captured outer-env so dispatch can layer them
    // under globals.
    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    if (capture_pairs.len == 0) return .ok;
    const tbl = self.anon_methods.borrowMut();
    defer tbl.deinit();
    for (class.members) |*m| {
        if (m.* != .Function) continue;
        const f = &m.Function;
        const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
        for ([_][]const u8{ arity_name, f.name.name }) |member| {
            const key = try anonKey(allocator, class.name.name, member);
            if (tbl.get().getPtr(key)) |entry| {
                entry.captures = capture_pairs;
            }
        }
    }
    return .ok;
}

fn buildCapturePairs(allocator: Allocator, captured_names: []const []const u8, captures: []const Value) Allocator.Error![]NameValue {
    const n = @min(captured_names.len, captures.len);
    var pairs = try allocator.alloc(NameValue, n);
    for (0..n) |i| pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    return pairs;
}

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

fn lookupGlobal(self: *VmHost, name: []const u8) ?Value {
    const g = self.globals.borrow();
    defer g.deinit();
    return g.get().lookup(name);
}

fn matchesAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn allAsciiDigit(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn lastSegment(fqn: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

fn isReflectionTypeName(name: []const u8) bool {
    return matchesAny(name, &.{
        "KProperty",  "KCallable",  "KFunction",  "KFunction0",
        "KFunction1", "KFunction2", "KMutableProperty",
    });
}

/// Recognise the builtin / stdlib type names that are not registered as
/// user classes but are still concrete cast targets (so `x as String`
/// against a non-String still throws). Used to distinguish a real
/// checked cast from an erased type-parameter cast (`x as TBuilder`).
fn isBuiltinTypeName(name: []const u8) bool {
    const builtins = [_][]const u8{
        // Primitives + their boxed/number forms.
        "Int",    "Long",   "Short",   "Byte",    "Double",  "Float",   "Char",   "Boolean",
        "UInt",   "ULong",  "UShort",  "UByte",   "Number",  "Unit",    "Nothing", "Any",
        // Strings / char sequences.
        "String", "CharSequence", "StringBuilder",
        // Comparison / common interfaces.
        "Comparable", "Comparator", "Pair", "Triple",
        // Collections + arrays (read-only and mutable).
        "Array",      "IntArray",   "LongArray",  "ShortArray", "ByteArray",  "DoubleArray",
        "FloatArray", "CharArray",  "BooleanArray", "UIntArray", "ULongArray",
        "UShortArray", "UByteArray",
        "List",       "MutableList", "ArrayList",  "AbstractList", "AbstractMutableList",
        "Collection", "MutableCollection", "AbstractCollection",
        "Iterable",   "MutableIterable", "Iterator", "MutableIterator", "ListIterator",
        "Set",        "MutableSet", "HashSet",    "LinkedHashSet", "AbstractSet",
        "Map",        "MutableMap", "HashMap",    "LinkedHashMap", "AbstractMap",
        "Sequence",   "EnumEntries",
        // Ranges / progressions.
        "IntRange",       "LongRange",       "CharRange", "IntProgression", "LongProgression",
        "CharProgression", "ClosedRange",    "OpenEndRange",
        // Reflection.
        "KClass", "KProperty", "KCallable", "KFunction", "KMutableProperty",
        // Throwable hierarchy.
        "Throwable",                  "Exception",            "RuntimeException", "Error",
        "IllegalArgumentException",   "IllegalStateException", "IndexOutOfBoundsException",
        "ArrayIndexOutOfBoundsException", "StringIndexOutOfBoundsException",
        "NullPointerException",       "ArithmeticException",  "ClassCastException",
        "NoSuchElementException",     "NumberFormatException", "UnsupportedOperationException",
        "UninitializedPropertyAccessException", "ConcurrentModificationException",
        "NoWhenBranchMatchedException", "AssertionError",
    };
    if (containsStr(&builtins, name)) return true;
    return std.mem.startsWith(u8, name, "Function");
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "is_builtin_type_name recognizes primitives, collections, and FunctionN" {
    try testing.expect(isBuiltinTypeName("Int"));
    try testing.expect(isBuiltinTypeName("String"));
    try testing.expect(isBuiltinTypeName("MutableList"));
    try testing.expect(isBuiltinTypeName("IllegalArgumentException"));
    try testing.expect(isBuiltinTypeName("Function3"));
    try testing.expect(isBuiltinTypeName("Function"));
    try testing.expect(!isBuiltinTypeName("Widget"));
    try testing.expect(!isBuiltinTypeName("TBuilder"));
}

test "builtin_exception_parent_match walks the known hierarchy" {
    try testing.expect(builtinExceptionParentMatch("IllegalArgumentException", "RuntimeException"));
    try testing.expect(builtinExceptionParentMatch("ArrayIndexOutOfBoundsException", "IndexOutOfBoundsException"));
    try testing.expect(builtinExceptionParentMatch("AssertionError", "Error"));
    try testing.expect(builtinExceptionParentMatch("RuntimeException", "Exception"));
    try testing.expect(builtinExceptionParentMatch("Exception", "Throwable"));
    try testing.expect(!builtinExceptionParentMatch("IllegalArgumentException", "Error"));
}
