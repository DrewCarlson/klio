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
const FF = runtime.forest.ForestField;
const VmHost = @import("vmhost.zig").VmHost;
const host_instances = @import("host_instances.zig");
const host_call_value = @import("host_call_value.zig");
const host_call_func = @import("host_call_func.zig");

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
const ClassTable = root.ClassTable;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const MaybeValueResult = ir.eval.MaybeValueResult;
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
    // A function-local class is spelled by its `$lc<fn>` alias in lowered
    // type names; at runtime it registers under its bare name, so the check
    // resolves the bare name (the frame's or the latest registered class).
    if (std.mem.indexOf(u8, ty.name, "$lc")) |lci| {
        return instanceOf(self, value, .{ .name = ty.name[0..lci], .nullable = ty.nullable, .args = ty.args });
    }

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
            if (host_call_func.reifiedFromFrame(self, std.heap.smp_allocator, ty.name) orelse lookupGlobal(self, ty.name)) |bound| {
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

    // Typealias indirection: an `is`/`as` against an alias head
    // (`typealias TR = Unit`) behaves as against the aliased target.
    // Only when no real class owns the name; an `expect class` stub that
    // an `actual typealias` supersedes is handled by the last-resort
    // unfold at the end of this function.
    {
        const module_has_class = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(ty.name) != null;
        };
        if (!module_has_class) {
            if (typeAliasTarget(self, ty.name)) |t| {
                return instanceOf(self, value, .{ .name = t, .nullable = ty.nullable, .args = ty.args });
            }
        }
    }

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
            .IrClosure => {
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
    // `x is Enum<*>`: every enum entry is an instance of a class registered
    // with `is_enum` (kotlin.Enum is its implicit supertype).
    if (std.mem.eql(u8, ty.name, "Enum")) {
        if (value.* == .Instance) {
            const g = value.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            if (cg.get().is_enum) return true;
        }
    }
    if (std.mem.eql(u8, ty.name, "EnumEntries")) {
        return switch (value.*) {
            .List => |l| l.enum_entries,
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
                "List",                "Collection",         "Iterable",
                "AbstractList",        "AbstractCollection", "MutableList",
                "MutableCollection",   "MutableIterable",    "ArrayList",
                "AbstractMutableList",
            })) return true;
        },
        .Set => {
            if (matchesAny(ty.name, &.{
                "Set",             "Collection", "Iterable",
                "AbstractSet",     "MutableSet", "MutableCollection",
                "MutableIterable", "HashSet",    "LinkedHashSet",
            })) return true;
        },
        .Map => {
            if (matchesAny(ty.name, &.{
                "Map", "AbstractMap", "MutableMap", "HashMap", "LinkedHashMap",
            })) return true;
        },
        .Range => |r| {
            if (matchesAny(ty.name, &.{
                "IntProgression", "LongProgression", "CharProgression", "Iterable",
            })) return true;
            // A `..` range (step 1) is also an XRange / ClosedRange; a downTo,
            // stepped, or reversed progression is only a progression — even
            // with step 1 (`1..10 step 1` is an IntProgression, not IntRange).
            if (r.step == 1 and !r.progression and matchesAny(ty.name, &.{
                "IntRange", "LongRange", "CharRange", "ClosedRange", "OpenEndRange",
            })) return true;
        },
        else => {},
    }

    // Lambda / function values match `Function<R>`, `Function0`,
    // `Function1`, `Function2`, … (the arity-indexed `FunctionN`
    // hierarchy from kotlin.jvm.functions).
    switch (value.*) {
        .IrClosure => {
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
    // in our module table. A user-`Instance` value keeps the full dotted
    // name so the identity-aware hierarchy walk below can reject a
    // same-simple-name class from another package (`c is b.Shape` when the
    // instance's supertype is `a.Shape`).
    if (value.* != .Instance) {
        if (std.mem.indexOfScalar(u8, ty.name, '.')) |_| {
            if (std.mem.lastIndexOfScalar(u8, ty.name, '.')) |i| {
                const last = ty.name[i + 1 ..];
                const alt: TypeRef = .{ .name = last, .nullable = ty.nullable, .args = ty.args };
                return instanceOf(self, value, alt);
            }
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
            return runtime.Value.builtinThrowableIsA(g.get().bytes, ty.name);
        },
        else => {},
    }

    // User-class instance: walk the runtime ClassDef chain.
    switch (value.*) {
        .Instance => |inst| {
            const builtin_exception_names = [_][]const u8{
                "Throwable",                     "Exception",
                "RuntimeException",              "Error",
                "IllegalArgumentException",      "IllegalStateException",
                "IndexOutOfBoundsException",     "NoSuchElementException",
                "NullPointerException",          "ArithmeticException",
                "ClassCastException",            "NumberFormatException",
                "UnsupportedOperationException", "Any",
            };
            // Resolve the target once: its simple name (for a same-name
            // match) and, when it unambiguously denotes a registered class,
            // its FQN (for an identity check that rejects a same-simple-name
            // class in another package). The parent/interface chain is already
            // linked package-aware (`build_module` resolves each supertype in
            // its own package), so walking it and comparing by identity is
            // collision-proof.
            const target_simple = lastSegment(ty.name);
            const target_fqn = resolveClassFqn(self, ty.name);
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
                if (subtypeMatch(self, cdef.name, cdef.fqn, target_simple, target_fqn, ty.name)) {
                    return true;
                }
                // Direct + transitive interface supertypes.
                if (interfaceChainMatches(self, cdef, target_simple, target_fqn, ty.name)) return true;
                // Walk supertype names — covers chains where the direct parent
                // is a built-in class not in the user class table. A target
                // that names a definite registered class is matched by identity
                // via the parent/interface walks above, so a supertype name is
                // matched directly only for a builtin / ambiguous simple-name
                // target (where identity resolution is unavailable).
                for (cdef.supertype_names) |sup| {
                    if (target_fqn == null and std.mem.eql(u8, sup, target_simple)) return true;
                    if (containsStr(&builtin_exception_names, sup) and
                        containsStr(&builtin_exception_names, target_simple)) return true;
                }
                if (cdef.is_anonymous) {
                    for (cdef.supertype_names) |n| {
                        if (std.mem.eql(u8, n, target_simple)) return true;
                    }
                    // An anonymous class records only the supertypes it was
                    // WRITTEN with, and those are names, not resolved
                    // handles: `object : KSerializer<Int> by …` never filled
                    // `interfaces`, so the direct-name test above was the
                    // whole answer and `is SerializationStrategy` — which
                    // `KSerializer` extends — said false.
                    if (supertypeNameChainMatches(self, cdef, target_simple, target_fqn, ty.name)) return true;
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
    if (value.isRuntimeType(ty.name)) return true;
    // Last resort: a typealias registered under the name (an `expect class`
    // whose platform `actual` is a typealias keeps a class stub in the
    // module, so the eager unfold above was gated off) — match against
    // the aliased target.
    if (typeAliasTarget(self, ty.name)) |t| {
        return instanceOf(self, value, .{ .name = t, .nullable = ty.nullable, .args = ty.args });
    }
    return false;
}

/// Resolve a (possibly chained) `typealias` head to its final target, or
/// null when the name is not an alias.
fn typeAliasTarget(self: *VmHost, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    var cur: []const u8 = name;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const next = mg.get().registry.type_aliases.get(cur) orelse break;
        if (std.mem.eql(u8, next, cur)) break;
        cur = next;
    }
    if (cur.ptr == name.ptr) return null;
    return cur;
}

/// Walk a class's direct + transitive interface supertypes, matching the
/// target against each by identity (`subtypeMatch`). The `interfaces` slices
/// are linked package-aware, so the walk follows the real interface hierarchy;
/// a same-simple-name interface in another package cannot be reached.
/// Whether any TRANSITIVE supertype of a class recorded by NAME matches the
/// target. `interfaceChainMatches` walks resolved `interfaces` handles, which
/// a runtime-synthesized class never has; this resolves each recorded name to
/// its registered declaration and continues from there.
fn supertypeNameChainMatches(
    self: *VmHost,
    cdef: *const ClassDef,
    target_simple: []const u8,
    target_fqn: ?[]const u8,
    raw_target: []const u8,
) bool {
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);
    for (cdef.supertype_names) |n| queue.append(a, n) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const name = queue.items[head];
        if (containsStr(seen.items, name)) continue;
        seen.append(a, name) catch return false;
        const def = classDefByNameLocal(self, name) orelse continue;
        defer def.deinit();
        const dg = def.borrow();
        defer dg.deinit();
        const d = dg.get();
        if (subtypeMatch(self, d.name, d.fqn, target_simple, target_fqn, raw_target)) return true;
        if (interfaceChainMatches(self, d, target_simple, target_fqn, raw_target)) return true;
        for (d.supertype_names) |sn| queue.append(a, sn) catch return false;
        if (d.parent) |parent| {
            const pg = parent.borrow();
            queue.append(a, pg.get().name) catch {};
            pg.deinit();
        }
    }
    return false;
}

fn classDefByNameLocal(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const g = self.classes.borrow();
    defer g.deinit();
    if (g.get().get(name)) |d| return d.clone();
    const simple = lastSegment(name);
    if (simple.len != name.len) {
        if (g.get().get(simple)) |d| return d.clone();
    }
    return null;
}

fn interfaceChainMatches(
    self: *VmHost,
    cdef: *const ClassDef,
    target_simple: []const u8,
    target_fqn: ?[]const u8,
    raw_target: []const u8,
) bool {
    const a = self.allocator;
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |q| q.deinit();
        queue.deinit(a);
    }
    // Dedup by FQN (identity): two same-simple-name interfaces from different
    // packages must each be walked, never collapsed into one.
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);

    for (cdef.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        if (subtypeMatch(self, fg.get().name, fg.get().fqn, target_simple, target_fqn, raw_target)) {
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
        if (containsStr(seen.items, idef.fqn)) continue;
        seen.append(a, idef.fqn) catch return false;
        if (subtypeMatch(self, idef.name, idef.fqn, target_simple, target_fqn, raw_target)) return true;
        // Builtin / ambiguous interface supertypes (e.g. `Comparable`) are not
        // resolved into `interfaces`; match them by simple name only when the
        // target is not a definite registered class (identity unavailable).
        if (target_fqn == null) {
            for (idef.supertype_names) |sup| {
                if (std.mem.eql(u8, sup, target_simple)) return true;
            }
        }
        // Resolved interface supertypes, walked by identity (never re-resolved
        // from a collidable simple name).
        for (idef.interfaces) |sup| {
            queue.append(a, sup.clone()) catch return false;
        }
    }
    return false;
}

/// Best-effort builtin-Throwable parent walk used for `Value.Exception`
/// `is`/`as` matches when the target is one of the exception class's
/// known parents. The common case here is the immediate parent.
fn builtinExceptionParentMatch(tail: []const u8, target: []const u8) bool {
    return runtime.Value.builtinThrowableIsA(tail, target);
}

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`/`host_fields.zig`/`host_call_member.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

/// Synthesize a runtime `ClassDef` matching `build_module`'s shape for a
/// local (function-body) class lowered at runtime.
fn synthLocalClassDef(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!ObjRef(ClassDef) {
    var primary_params = try allocator.alloc(ClassParamDef, class.primary_params.len);
    for (class.primary_params, 0..) |*p, i| {
        primary_params[i] = .{
            .property = p.property,
            .name = p.name.name,
            .default = if (p.default) |*e| FF(ast.Expr).fromPtr(e) else null,
            .declared_type = p.ty.name.name,
            .declared_shape = try TypeShape.fromTypeRef(allocator, &p.ty),
        };
    }
    var body_props: std.ArrayList(PropertyDef) = .empty;
    for (class.members) |*m| {
        if (m.* != .Property) continue;
        const p = m.Property;
        if (p.receiver_type != null) continue;
        try body_props.append(allocator, .{
            .name = p.name.name,
            .mutable = p.mutable,
            .init = if (p.init) |*e| FF(ast.Expr).fromPtr(e) else null,
            .getter = if (p.getter) |g| FF(ast.Accessor).fromPtr(g) else null,
            .setter = if (p.setter) |s| FF(ast.Accessor).fromPtr(s) else null,
            .delegate = if (p.delegate) |e| FF(ast.Expr).fromPtr(e) else null,
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

    // Local classes are registered after the program class graph has been
    // linked, so connect their direct parent/interface handles here. Keeping
    // only the written supertype names makes a direct `is Base` check work but
    // loses Base's transitive interfaces (`Segment` -> `NotCompleted`).
    var parent: ?ObjRef(ClassDef) = null;
    errdefer if (parent) |p| p.deinit();
    var interfaces: std.ArrayList(ObjRef(ClassDef)) = .empty;
    errdefer {
        for (interfaces.items) |iface| iface.deinit();
        interfaces.deinit(allocator);
    }
    {
        const classes = self.classes.borrow();
        defer classes.deinit();
        for (supertype_names, 0..) |name, i| {
            const qualified = if (i < supertype_paths.len) supertype_paths[i] else null;
            // Resolve program classes through the same file/package/import
            // index used during lowering. Only fall back to the runtime table
            // when the supertype is another local class absent from the IR.
            const resolved_fqn: ?[]const u8 = static: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                const file = class.supertypes[i].name.span.file;
                const cid = if (qualified) |path|
                    module.classIdByQualifiedSuffix(path)
                else
                    module.classIdIndexed(name, module.packageOfFile(file) orelse "", file);
                const id = cid orelse break :static null;
                if (id.int() >= module.classes.items.len) break :static null;
                break :static module.classes.items[id.int()].fqn;
            };
            const super_def = if (resolved_fqn) |fqn|
                classes.get().get(fqn) orelse classes.get().get(name)
            else if (qualified) |path|
                classes.get().get(path) orelse classByQualifiedSuffix(classes.get(), path)
            else
                classes.get().get(name);
            const def = super_def orelse continue;
            const dg = def.borrow();
            const is_interface = dg.get().is_interface;
            dg.deinit();
            if (is_interface) {
                try interfaces.append(allocator, def.clone());
            } else if (parent == null) {
                parent = def.clone();
            }
        }
    }
    const interface_slice = try interfaces.toOwnedSlice(allocator);
    errdefer {
        for (interface_slice) |iface| iface.deinit();
        allocator.free(interface_slice);
    }

    // Init blocks, with each block's member-index position converted to the
    // body-property index it runs before (the ClassDef convention), so
    // construction interleaves them with property initializers in
    // declaration order. The blocks themselves execute through the
    // `$init$block$<idx>` anon thunks registered alongside the methods.
    const ib_blocks = try allocator.alloc(FF(ast.Block), class.init_blocks.len);
    const ib_positions = try allocator.alloc(usize, class.init_blocks.len);
    for (class.init_blocks, 0..) |*blk, idx| {
        ib_blocks[idx] = FF(ast.Block).fromPtr(blk);
        const member_pos = if (idx < class.init_block_positions.len) class.init_block_positions[idx] else class.members.len;
        const upto = @min(member_pos, class.members.len);
        var prop_pos: usize = 0;
        for (class.members[0..upto]) |*m| {
            if (m.* == .Property) prop_pos += 1;
        }
        ib_positions[idx] = prop_pos;
    }

    const env = try ObjRef(Env).init(allocator, Env.init(allocator));
    return ObjRef(ClassDef).init(allocator, .{
        .name = class.name.name,
        .fqn = class.name.name,
        .annotation_names = &.{},
        .type_params = blk: {
            const names = try allocator.alloc([]const u8, class.type_params.len);
            for (class.type_params, names) |*tp, *out| out.* = tp.name.name;
            break :blk names;
        },
        .primary_params = primary_params,
        .methods = &.{},
        .body_properties = try body_props.toOwnedSlice(allocator),
        .init_blocks = ib_blocks,
        .init_block_property_positions = ib_positions,
        .is_data = class.is_data,
        .is_value = class.is_value,
        .is_object = false,
        .is_enum = class.is_enum,
        .is_annotation = class.is_annotation,
        .is_sealed = class.is_sealed,
        .supertype_names = supertype_names,
        .supertype_paths = supertype_paths,
        .parent = parent,
        .interfaces = interface_slice,
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
        .is_local_runtime = true,
    });
}

/// Resolve a dotted runtime-only supertype against the class table by an
/// aligned FQN suffix, preferring the least-nested match. Program declarations
/// resolve through the module's scope-aware class index before this fallback.
fn classByQualifiedSuffix(classes: *const ClassTable, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.indexOfScalar(u8, qualified, '.') == null) return null;
    var best: ?ObjRef(ClassDef) = null;
    var best_len: usize = std.math.maxInt(usize);
    var it = classes.valueIterator();
    while (it.next()) |def| {
        const dg = def.borrow();
        const fqn = dg.get().fqn;
        const matches = std.mem.endsWith(u8, fqn, qualified) and
            (fqn.len == qualified.len or fqn[fqn.len - qualified.len - 1] == '.');
        const fqn_len = fqn.len;
        dg.deinit();
        if (matches and fqn_len < best_len) {
            best = def.*;
            best_len = fqn_len;
        }
    }
    return best;
}

/// Lower each member function of `class` into the class's shared side
/// module (an image clone — see `anonSiteModule`) and register it in
/// `anon_methods` under both the arity-qualified and bare keys, with
/// `capture_pairs` bound. `own_members` scopes bare-name resolution inside
/// the bodies.
fn lowerAndRegisterMethods(
    self: *VmHost,
    allocator: Allocator,
    class: *const ast.Class,
    own_members: *const StringSet,
    capture_pairs: []const NameValue,
) Allocator.Error!void {
    var site_mod: ?ObjRef(Module) = null;
    defer if (site_mod) |m| m.deinit();
    // The class's DECLARED property types (ctor `val data: Collection<E>`,
    // annotated body properties) carry into the member lowerings through
    // the same channel the anonymous-object path uses, so a body's
    // `data.iterator()` types its receiver instead of walking by name.
    var prop_heads: std.ArrayList(ir.build.AnonPropHead) = .empty;
    defer prop_heads.deinit(allocator);
    for (class.primary_params) |*pp| {
        if (pp.property == null) continue;
        try prop_heads.append(allocator, .{
            .owner = class.name.name,
            .name = pp.name.name,
            .head = pp.ty.name.name,
        });
    }
    for (class.members) |*m| {
        if (m.* != .Property) continue;
        const p = m.Property;
        if (p.ty) |*ty| {
            try prop_heads.append(allocator, .{
                .owner = class.name.name,
                .name = p.name.name,
                .head = ty.name.name,
            });
        }
    }
    const prev_prop_heads = ir.build.setLowerAnonPropHeads(prop_heads.items);
    defer _ = ir.build.setLowerAnonPropHeads(prev_prop_heads);
    host_instances.anonLowerEnter();
    defer host_instances.anonLowerExit();
    // Occurrence counter per `name#arity`: two same-arity overloads of one
    // name share that key, so each also registers under an indexed key.
    var overload_seen = std.StringHashMap(usize).init(allocator);
    defer overload_seen.deinit();
    for (class.members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.body == null) continue;
                const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, f, class.name.name, own_members);
                // `KLIO_ANON_DUMP=<class>`: the runtime-lowered method IR.
                if (runtime.envOnce("KLIO_ANON_DUMP")) |w| {
                    std.debug.print("[anon-lower] {s}.{s}\n", .{ class.name.name, f.name.name });
                    if (std.mem.eql(u8, w, class.name.name)) {
                        var aw: std.Io.Writer.Allocating = .init(allocator);
                        defer aw.deinit();
                        ir.disasm.dumpModule(&aw.writer, &sub_ref.cell.data, .{ .all = true }) catch {};
                        std.debug.print("[anon-dump] {s}.{s}: funcs={d} len={d}\n{s}\n", .{ class.name.name, f.name.name, sub_ref.cell.data.funcs.items.len, aw.written().len, aw.written() });
                    }
                }
                const fid = func.id;
                const caps = try allocator.dupe(NameValue, capture_pairs);
                const entry: AnonMethodEntry = .{ .module = sub_ref, .func = fid, .captures = caps };
                const tbl = self.anon_methods.borrowMut();
                defer tbl.deinit();
                const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
                const gop = try overload_seen.getOrPut(arity_name);
                if (!gop.found_existing) gop.value_ptr.* = 0 else gop.value_ptr.* += 1;
                const overload_name = try root.anonOverloadMemberName(allocator, arity_name, gop.value_ptr.*);
                try tbl.get().put(try anonKey(allocator, class.name.name, overload_name), .{ .module = sub_ref.clone(), .func = fid, .captures = caps });
                try tbl.get().put(try anonKey(allocator, class.name.name, arity_name), entry);
                try tbl.get().put(try anonKey(allocator, class.name.name, f.name.name), .{ .module = sub_ref.clone(), .func = fid, .captures = caps });
            },
            // A body property with a custom getter registers its accessor
            // thunk, exactly as an anonymous object's does — a local class's
            // `override val size get() = …` is otherwise unreadable.
            .Property => |p| {
                if (p.getter) |getter| {
                    // `field` in the accessor body targets the raw backing
                    // storage (`this.__klio_field__<prop>`), bypassing the
                    // accessor dispatch exactly like a module class's.
                    const gbody = try rewriteAccessorFieldRefs(allocator, getter.body, p.name.name);
                    const thunk = host_instances.synthThunk(p.name, gbody, getter.return_type, p.is_override);
                    const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
                    const fid = func.id;
                    const caps = try allocator.dupe(NameValue, capture_pairs);
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    defer tbl.deinit();
                    try tbl.get().put(try anonKey(allocator, class.name.name, key), .{ .module = sub_ref, .func = fid, .captures = caps });
                }
                // A custom setter registers its 1-arg thunk symmetrically, so a
                // local class's `override var x set(value) { … }` dispatches on
                // writes instead of landing on a phantom raw field.
                if (p.setter) |setter| {
                    const vp: ast.Ident = if (setter.params.len != 0) setter.params[0] else .{ .name = "value", .span = p.name.span };
                    const sbody = try rewriteAccessorFieldRefs(allocator, setter.body, p.name.name);
                    const thunk = try host_instances.synthSetterThunk(allocator, p.name, vp, sbody, p.is_override);
                    const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
                    const fid = func.id;
                    const caps = try allocator.dupe(NameValue, capture_pairs);
                    const key = try std.fmt.allocPrint(allocator, "$set${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    defer tbl.deinit();
                    try tbl.get().put(try anonKey(allocator, class.name.name, key), .{ .module = sub_ref, .func = fid, .captures = caps });
                }
                // A complex initializer (`val items = mutableListOf<...>()`)
                // lowers as a `$init$` thunk the construction pipeline runs;
                // simple literals stay inline (`simpleLiteral`).
                // A delegated property (`var left by Box(left)`) lowers its
                // DELEGATE expression as the `$init$` thunk; construction
                // stores the evaluated delegate under the property name and
                // reads/writes route through getValue/setValue.
                if (p.delegate) |dexpr| {
                    // The delegate expression may read PLAIN constructor
                    // params (`Node(value, left)` with `var left by
                    // Box(left)`), so the thunk declares the primary params
                    // and construction passes the ctor args.
                    var thunk = host_instances.synthThunk(p.name, .{ .Expr = dexpr.* }, null, false);
                    const tparams = try allocator.alloc(ast.Param, class.primary_params.len);
                    for (class.primary_params, 0..) |*pp, pi| {
                        tparams[pi] = .{
                            .name = pp.name,
                            .ty = pp.ty,
                            .default = null,
                            .is_vararg = false,
                            .is_crossinline = false,
                            .is_noinline = false,
                            .annotations = &.{},
                            .span = pp.name.span,
                        };
                    }
                    thunk.params = tparams;
                    const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
                    const fid = func.id;
                    const caps = try allocator.dupe(NameValue, capture_pairs);
                    const key = try std.fmt.allocPrint(allocator, "$init${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    defer tbl.deinit();
                    try tbl.get().put(try anonKey(allocator, class.name.name, key), .{ .module = sub_ref, .func = fid, .captures = caps });
                }
                if (p.init) |init_expr| {
                    // The initializer may read PLAIN constructor params —
                    // including one the property itself shadows (`class N(
                    // property: String) { var property = property }`): declare
                    // the primary params so the bare name binds the param,
                    // never the not-yet-initialized property. Construction
                    // passes the ctor args.
                    var thunk = host_instances.synthThunk(p.name, .{ .Expr = init_expr }, null, false);
                    const tparams = try allocator.alloc(ast.Param, class.primary_params.len);
                    for (class.primary_params, 0..) |*pp, pi| {
                        tparams[pi] = .{
                            .name = pp.name,
                            .ty = pp.ty,
                            .default = null,
                            .is_vararg = false,
                            .is_crossinline = false,
                            .is_noinline = false,
                            .annotations = &.{},
                            .span = pp.name.span,
                        };
                    }
                    thunk.params = tparams;
                    const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
                    const fid = func.id;
                    const caps = try allocator.dupe(NameValue, capture_pairs);
                    const key = try std.fmt.allocPrint(allocator, "$init${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    defer tbl.deinit();
                    try tbl.get().put(try anonKey(allocator, class.name.name, key), .{ .module = sub_ref, .func = fid, .captures = caps });
                }
            },
            else => {},
        }
    }
    // `init { … }` blocks lower as 0-arg thunks over `this`, registered under
    // `$init$block$<idx>` — the same shape the anonymous-object materializer
    // uses — so construction can run them (with the class's captured cells
    // bound) interleaved with the property initializers.
    for (class.init_blocks, 0..) |*blk, idx| {
        const thunk_name: ast.Ident = .{
            .name = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx}),
            .span = blk.span,
        };
        var thunk = host_instances.synthThunk(thunk_name, .{ .Block = blk.* }, null, false);
        // Declare the primary-constructor params, exactly as the
        // `$super$arg$<i>` thunks do: an `init` block may read a constructor
        // PARAMETER that is not a property, and a 0-arg thunk left that name
        // to fall through to a field read on `this`.
        {
            const tparams = try allocator.alloc(ast.Param, class.primary_params.len);
            for (class.primary_params, 0..) |*pp, pi| {
                tparams[pi] = .{
                    .name = pp.name,
                    .ty = pp.ty,
                    .default = null,
                    .is_vararg = false,
                    .is_crossinline = false,
                    .is_noinline = false,
                    .annotations = &.{},
                    .span = pp.name.span,
                };
            }
            thunk.params = tparams;
        }
        const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
        const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
        const caps = try allocator.dupe(NameValue, capture_pairs);
        const tbl = self.anon_methods.borrowMut();
        defer tbl.deinit();
        try tbl.get().put(try anonKey(allocator, class.name.name, thunk_name.name), .{ .module = sub_ref, .func = func.id, .captures = caps });
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
            .Property => |p| try out.put(p.name.name, {}),
            .Function => |*f| try out.put(f.name.name, {}),
            else => {},
        }
    }
}

/// Register the class declarations NESTED inside a local class.
///
/// `registerClass` synthesises a ClassDef for the local class itself and
/// lowers its methods, but never walked its members, so a class declared
/// inside a local class was unresolvable: kotlinx-io's `rawSourceSample`
/// declares `RC4DecryptingSource` inside a test function and an
/// `inner class RC4Key` inside that, and constructing it failed with
/// `unresolved global RC4Key`. Applies to plain nested and `inner` classes
/// alike — neither was registered.
///
/// Recurses, so a class nested two deep inside a local class registers too.
fn registerNestedClasses(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!void {
    for (class.members) |*m| {
        switch (m.*) {
            .Class => |*nested| {
                if (nested.is_companion) {
                    // A LOCAL class's companion: registered under a
                    // mangled runtime name, constructed once here, and
                    // published as the class's `$companion:<name>` global
                    // so a member call on the class value forwards to it
                    // (`W.serializer()` on a local `@Serializable` class).
                    var renamed = nested.*;
                    renamed.name = .{ .name = try std.fmt.allocPrint(allocator, "{s}$Companion", .{class.name.name}), .span = nested.name.span };
                    renamed.is_companion = false;
                    const owned = try allocator.create(ast.Class);
                    owned.* = renamed;
                    _ = try registerClass(self, allocator, owned);
                    try publishLocalSingleton(self, allocator, owned.name.name, try std.fmt.allocPrint(allocator, "$companion:{s}", .{class.name.name}));
                    continue;
                }
                _ = try registerClass(self, allocator, nested);
            },
            // A nested `object` of a local class: registered as a class,
            // constructed once, and bound under its own name so the
            // class's members reach it by bare name.
            .Object => |*o| {
                const synth = try allocator.create(ast.Class);
                synth.* = try build.lift.synthesizeClassFromObject(allocator, o);
                _ = try registerClass(self, allocator, synth);
                try publishLocalSingleton(self, allocator, synth.name.name, synth.name.name);
            },
            else => {},
        }
    }
}

/// Construct the runtime-registered class `class_name` with no arguments
/// and bind the instance to the global `global_name`.
fn publishLocalSingleton(self: *VmHost, allocator: Allocator, class_name: []const u8, global_name: []const u8) Allocator.Error!void {
    const def: ?ObjRef(ClassDef) = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        if (g.get().get(class_name)) |d| break :blk d.clone();
        break :blk null;
    };
    const dbg = runtime.envOnce("KLIO_INIT_DEBUG") != null;
    const d = def orelse {
        if (dbg) std.debug.print("[init-debug] local singleton {s}: class not registered\n", .{class_name});
        return;
    };
    const cv = Value{ .Class = d };
    const r = try host_call_value.callValue(self, allocator, &cv, &.{});
    switch (r) {
        .ok => |inst| {
            if (dbg) std.debug.print("[init-debug] local singleton {s} -> {s} ({s})\n", .{ class_name, global_name, @tagName(std.meta.activeTag(inst)) });
            const g = self.globals.borrowMut();
            defer g.deinit();
            g.get().define(global_name, inst) catch {};
        },
        .err => |e| {
            if (dbg) std.debug.print("[init-debug] local singleton {s} FAILED: {s}\n", .{ class_name, @tagName(std.meta.activeTag(e)) });
        },
    }
}

pub fn registerClass(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!UnitResult {
    // Local classes declared inside fn bodies arrive here at runtime.
    // Synthesise the same ClassDef shape build_module produces and stash
    // it in the Vm's class table.
    var site_mod: ?ObjRef(Module) = null;
    defer if (site_mod) |m| m.deinit();
    host_instances.anonLowerEnter();
    defer host_instances.anonLowerExit();
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
    try registerNestedClasses(self, allocator, class);
    // Parent-constructor arguments (`class C : Base(expr...)`) lower as
    // `$super$arg$<i>` thunks declaring the primary params, so a MODULE
    // parent's fields and body properties can initialize at construction.
    for (class.supertypes, 0..) |_, si| {
        if (si >= class.supertype_args.len) break;
        const sargs = class.supertype_args[si] orelse continue;
        for (sargs, 0..) |*se, ai| {
            const thunk_name: ast.Ident = .{
                .name = try std.fmt.allocPrint(allocator, "$super$arg${d}", .{ai}),
                .span = class.name.span,
            };
            var thunk = host_instances.synthThunk(thunk_name, .{ .Expr = se.* }, null, false);
            const tparams = try allocator.alloc(ast.Param, class.primary_params.len);
            for (class.primary_params, 0..) |*pp, pi| {
                tparams[pi] = .{
                    .name = pp.name,
                    .ty = pp.ty,
                    .default = null,
                    .is_vararg = false,
                    .is_crossinline = false,
                    .is_noinline = false,
                    .annotations = &.{},
                    .span = pp.name.span,
                };
            }
            thunk.params = tparams;
            const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
            const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, &own_members);
            const tbl = self.anon_methods.borrowMut();
            defer tbl.deinit();
            try tbl.get().put(try anonKey(allocator, class.name.name, thunk_name.name), .{ .module = sub_ref, .func = func.id, .captures = &.{} });
            if (runtime.envOnce("KLIO_INIT_DEBUG") != null) std.debug.print("[init-debug] registered {s} for {s}\n", .{ thunk_name.name, class.name.name });
        }
        break;
    }
    return .ok;
}

/// Rewrite bare `field` references in an accessor body to the raw backing
/// member (`this.__klio_field__<prop>`), the same substitution the module
/// class pipeline applies — the host's get/set detect the prefix and bypass
/// the accessor dispatch, so a custom setter's `field = value` writes the
/// stored property instead of recursing or landing on a phantom field.
fn rewriteAccessorFieldRefs(allocator: Allocator, body: ast.FunctionBody, prop: []const u8) Allocator.Error!ast.FunctionBody {
    return switch (body) {
        .Expr => |e| .{ .Expr = (try build.lift.substituteFieldWithThis(allocator, prop, &e)).* },
        .Block => |blk| .{ .Block = try build.lift.rewriteBlockField(allocator, &blk, prop) },
    };
}

/// The class's nested singletons (its companion, its nested objects) sit
/// in the same lexical scope as the class: their bare reads of the
/// enclosing receiver's members walk the same outer.
fn assignNestedOuters(self: *VmHost, allocator: Allocator, class: *const ast.Class, this_val: Value) Allocator.Error!void {
    for (class.members) |*m| {
        const global_name: ?[]const u8 = switch (m.*) {
            .Object => |*o| o.name.name,
            .Class => |*nc| if (nc.is_companion) try std.fmt.allocPrint(allocator, "$companion:{s}", .{class.name.name}) else null,
            else => null,
        };
        const gname = global_name orelse continue;
        const inst: ?Value = blk: {
            const g = self.globals.borrow();
            defer g.deinit();
            break :blk g.get().lookup(gname);
        };
        if (inst) |iv| {
            if (iv == .Instance) {
                const ig = iv.Instance.borrowMut();
                defer ig.deinit();
                const has_outer = if (ig.get().outer) |o| (o != .Null and o != .Unit) else false;
                if (!has_outer) ig.get().outer = this_val;
                if (runtime.envOnce("KLIO_INIT_DEBUG") != null) std.debug.print("[init-debug] outer for {s}: set={}\n", .{ gname, !has_outer });
            }
        }
    }
}

pub fn registerClassCaptured(self: *VmHost, allocator: Allocator, class: *const ast.Class, captured_names: []const []const u8, captures: []const Value) Allocator.Error!UnitResult {
    host_instances.anonLowerEnter();
    defer host_instances.anonLowerExit();
    // The member lowerings below must know which bare names are captured
    // enclosing locals: a captured `count` is nearer than any top-level
    // prop/const of that name and must stay a dynamic read/write.
    const prev_caps = ir.build.setLowerAnonCaptureNames(captured_names);
    defer _ = ir.build.setLowerAnonCaptureNames(prev_caps);
    // The same names go into the capture SET the member lowerings consult
    // (an anonymous object installs it too): a lambda inside a method or a
    // parent-constructor argument then captures `o` through the method's
    // own capture slot, filled by name at dispatch, instead of reading a
    // global that only exists while the method runs.
    var cap_set = StringSet.init(allocator);
    for (captured_names) |n| try cap_set.put(n, {});
    const prev_set = ir.lower.takeLowerAnonCaptures();
    ir.lower.setLowerAnonCaptures(cap_set);
    defer ir.lower.setLowerAnonCaptures(prev_set);
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
            // Same reason as the uncaptured path: a class nested inside a
            // local class is otherwise never registered.
            try registerNestedClasses(self, allocator, class);
            try assignNestedOuters(self, allocator, class, tv);
            try patchCaptureEntries(self, allocator, class, capture_pairs);
            return .ok;
        }
    }
    // No `this` instance captured: patch the just-registered method
    // entries with the captured outer-env so dispatch can layer them
    // under globals.
    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    if (capture_pairs.len == 0) return .ok;
    try patchCaptureEntries(self, allocator, class, capture_pairs);
    return .ok;
}

/// Point every registry entry the class registered (methods, accessor and
/// initializer thunks, init blocks, parent-constructor argument thunks) at
/// the captured enclosing env, and the same for its nested classes: an
/// inner class's `Base({ o + k })` closes over the function's `o` too.
fn patchCaptureEntries(self: *VmHost, allocator: Allocator, class: *const ast.Class, capture_pairs: []NameValue) Allocator.Error!void {
    {
        const tbl = self.anon_methods.borrowMut();
        defer tbl.deinit();
        {
            var ai: usize = 0;
            while (true) : (ai += 1) {
                const nm = try std.fmt.allocPrint(allocator, "$super$arg${d}", .{ai});
                const key = try anonKey(allocator, class.name.name, nm);
                const entry = tbl.get().getPtr(key) orelse break;
                entry.captures = capture_pairs;
            }
        }
        for (class.members) |*m| {
            switch (m.*) {
                .Function => |*f| {
                    const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
                    for ([_][]const u8{ arity_name, f.name.name }) |member| {
                        const key = try anonKey(allocator, class.name.name, member);
                        if (tbl.get().getPtr(key)) |entry| {
                            entry.captures = capture_pairs;
                        }
                    }
                    // The indexed keys of a same-arity overload family are dense
                    // from zero, so patch until one is missing.
                    var overload_index: usize = 0;
                    while (true) : (overload_index += 1) {
                        const member = try root.anonOverloadMemberName(allocator, arity_name, overload_index);
                        const key = try anonKey(allocator, class.name.name, member);
                        const entry = tbl.get().getPtr(key) orelse break;
                        entry.captures = capture_pairs;
                    }
                },
                // Accessor / property-initializer thunks capture the same outer
                // env: `val doubled = count * 2` reads the enclosing fn's cell.
                .Property => |p| {
                    for ([_][]const u8{ "$get$", "$set$", "$init$" }) |prefix| {
                        const nm = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, p.name.name });
                        const key = try anonKey(allocator, class.name.name, nm);
                        if (tbl.get().getPtr(key)) |entry| {
                            entry.captures = capture_pairs;
                        }
                    }
                },
                else => {},
            }
        }
        // The `$init$block$<idx>` thunks capture the same outer env: an
        // `init { count++ }` writes through the enclosing fn's boxed cell.
        for (class.init_blocks, 0..) |_, idx| {
            const nm = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx});
            const key = try anonKey(allocator, class.name.name, nm);
            if (tbl.get().getPtr(key)) |entry| {
                entry.captures = capture_pairs;
            }
        }
    }
    for (class.members) |*m| {
        if (m.* != .Class or m.Class.is_companion) continue;
        try patchCaptureEntries(self, allocator, &m.Class, capture_pairs);
    }
}

/// The `.Class` value for a local class just registered under `name`, so the
/// declaration site can bind the name to it (a local class shadows a same-named
/// top-level function for a constructor call). Null if no such class table
/// entry exists.
pub fn localClassValue(self: *VmHost, allocator: Allocator, name: []const u8) Allocator.Error!MaybeValueResult {
    _ = allocator;
    const cg = self.classes.borrow();
    defer cg.deinit();
    if (cg.get().get(name)) |def| {
        return .{ .ok = .{ .Class = def.clone() } };
    }
    return .{ .ok = null };
}

fn buildCapturePairs(allocator: Allocator, captured_names: []const []const u8, captures: []const Value) Allocator.Error![]NameValue {
    const n = @min(captured_names.len, captures.len);
    var pairs = try allocator.alloc(NameValue, n);
    for (0..n) |i| {
        // The anon-method registry holds these captures for the object's whole
        // lifetime (its methods read them long after the enclosing frame that
        // produced them has returned). Retain so a captured value outlives that
        // frame; released when the registry entry is dropped. No-op under arena.
        if (runtime.reclaimEnabled()) captures[i].retain();
        pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    }
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

/// Resolve a type name from an `is`/`as` check to the FQN of the single
/// registered user/pack class it denotes, or null when it is a bare simple
/// name shared by several classes, a builtin, a generic parameter, or
/// otherwise not a uniquely-registered class. `classIdByFqn` returns null on
/// an ambiguous FQN, so a residual collision stays null and the caller keeps
/// its collision-proof simple-name behaviour.
fn resolveClassFqn(self: *VmHost, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const cid = m.classIdByFqn(name) orelse return null;
    if (cid.int() >= m.classes.items.len) return null;
    return m.classes.items[cid.int()].fqn;
}

/// Identity-aware subtype match for the `is`/`as` hierarchy walk. `ent_name`/
/// `ent_fqn` describe a class reached in the walk; `target_simple`/`target_fqn`
/// the type being tested against (`target_fqn` is non-null only when the
/// target unambiguously denotes a registered class). A same-simple-name match
/// is rejected only when the two names PROVABLY denote different registered
/// classes (different FQNs); otherwise the collision-proof simple-name match is
/// preserved (builtins, generics, anonymous / unregistered classes).
fn subtypeMatch(
    self: *VmHost,
    ent_name: []const u8,
    ent_fqn: []const u8,
    target_simple: []const u8,
    target_fqn: ?[]const u8,
    raw_target: []const u8,
) bool {
    if (std.mem.eql(u8, ent_fqn, raw_target)) return true;
    if (!std.mem.eql(u8, ent_name, target_simple)) return false;
    const tf = target_fqn orelse return true;
    if (std.mem.eql(u8, ent_fqn, tf)) return true;
    // Simple names coincide but the target is a specific, different class.
    // Reject only when the walked class is itself a registered class (so the
    // two provably differ); otherwise keep the simple-name match.
    return resolveClassFqn(self, ent_fqn) == null;
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
        "KProperty",  "KCallable",  "KFunction",        "KFunction0",
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
        "Int",                           "Long",                                 "Short",                           "Byte",                         "Double",              "Float",                      "Char",                     "Boolean",
        "UInt",                          "ULong",                                "UShort",                          "UByte",                        "Number",              "Unit",                       "Nothing",                  "Any",
        // Strings / char sequences.
        "String",                        "CharSequence",                         "StringBuilder",
        // Comparison / common interfaces.
                          "Comparable",                   "Comparator",          "Pair",                       "Triple",
        // Collections + arrays (read-only and mutable).
                          "Array",
        "IntArray",                      "LongArray",                            "ShortArray",                      "ByteArray",                    "DoubleArray",         "FloatArray",                 "CharArray",                "BooleanArray",
        "UIntArray",                     "ULongArray",                           "UShortArray",                     "UByteArray",                   "List",                "MutableList",                "ArrayList",                "AbstractList",
        "AbstractMutableList",           "Collection",                           "MutableCollection",               "AbstractCollection",           "Iterable",            "MutableIterable",            "Iterator",                 "MutableIterator",
        "ListIterator",                  "Set",                                  "MutableSet",                      "HashSet",                      "LinkedHashSet",       "AbstractSet",                "Map",                      "MutableMap",
        "HashMap",                       "LinkedHashMap",                        "AbstractMap",                     "Sequence",                     "EnumEntries",
        // Ranges / progressions.
                "IntRange",                   "LongRange",                "CharRange",
        "IntProgression",                "LongProgression",                      "CharProgression",                 "ClosedRange",                  "OpenEndRange",
        // Reflection.
               "KClass",                     "KProperty",                "KCallable",
        "KFunction",                     "KMutableProperty",
        // Throwable hierarchy.
                            "Throwable",                       "Exception",                    "RuntimeException",    "Error",                      "IllegalArgumentException", "IllegalStateException",
        "IndexOutOfBoundsException",     "ArrayIndexOutOfBoundsException",       "StringIndexOutOfBoundsException", "NullPointerException",         "ArithmeticException", "ClassCastException",         "NoSuchElementException",   "NumberFormatException",
        "UnsupportedOperationException", "UninitializedPropertyAccessException", "ConcurrentModificationException", "NoWhenBranchMatchedException", "AssertionError",      "NegativeArraySizeException",
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
