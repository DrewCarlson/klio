//! `VmHost` class-side dispatch: `is`/`as` checks and runtime registration of
//! local and anonymous-object classes lowered during eval. Free functions over
//! `*VmHost`, aliased as methods by `vmhost.zig`.

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

/// Whether a class spelled `name` is declared in package `pkg`: the program's
/// own `class B` makes `as? B` a real check only at a site in that package.
pub fn isDeclaredClassNameFrom(self: *VmHost, name: []const u8, pkg: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0) return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const cid = mod.classId(n) orelse return false;
    if (cid.int() >= mod.classes.items.len) return false;
    return std.mem.eql(u8, mod.classes.items[cid.int()].package, pkg);
}

/// Whether `name` denotes a concrete type a checked cast can test against.
/// Anything else is an erased type parameter, whose `x as <that>` never throws.
pub fn isConcreteCastTarget(self: *VmHost, name: []const u8) bool {
    const n = std.mem.trimEnd(u8, name, "?");
    if (n.len == 0) return false;
    if (std.mem.findScalarLast(u8, n, '.')) |dot| {
        if (dot + 1 < n.len and isBuiltinTypeName(n[dot + 1 ..])) return true;
    }
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
    // A reified type param bound to a `.Class` of a different name is checkable.
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

fn closureIsSuspend(self: *VmHost, body_func: ir.FuncId, sub_module: ?*const ir.Module) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = sub_module orelse mg.get();
    const f = m.funcById(body_func) orelse return false;
    return f.is_suspend;
}

fn closureItUnconstrained(self: *VmHost, body_func: ir.FuncId, sub_module: ?*const ir.Module) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = sub_module orelse mg.get();
    const f = m.funcById(body_func) orelse return false;
    return f.lambda_it_unconstrained;
}

pub fn instanceOf(self: *VmHost, value: *const Value, ty: TypeRef) bool {
    // `null is T?` holds for any nullable type; `null is T` does not.
    if (value.* == .Null) return ty.nullable;
    // A local class is spelled `$lc<fn>` in lowered types, registered bare.
    if (std.mem.find(u8, ty.name, "$lc")) |lci| {
        return instanceOf(self, value, .{ .name = ty.name[0..lci], .nullable = ty.nullable, .args = ty.args });
    }

    // A reified type param is a global bound to the call-site class value, so
    // `x is T` redirects to it. Gated on the name not being a module class, or
    // an `is Foo` whose `Foo` is also a global would recurse forever.
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

    if (std.mem.eql(u8, ty.name, "Any")) return true;

    // A typealias head behaves as its target, but only when no real class owns
    // the name; an `expect class` stub falls to the last-resort unfold below.
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

    // In a synth bound ref, `__bound_receiver__` is a Class for an unbound
    // property ref, an Instance for a bound method ref.
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
    // `x is Enum<*>`: every enum entry's class is registered `is_enum`.
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

    // Collections, arrays and ranges are host value variants, not user Instances,
    // so they match their Kotlin supertype names here. Mutable views match the
    // `Mutable*` names too: kotlinc reports `listOf(…) is MutableList` as true.
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
            // stepped or reversed progression is not, even at step 1.
            if (r.step == 1 and !r.progression and matchesAny(ty.name, &.{
                "IntRange", "LongRange", "CharRange", "ClosedRange", "OpenEndRange",
            })) return true;
        },
        else => {},
    }

    switch (value.*) {
        .IrClosure => |c| {
            if (std.mem.eql(u8, ty.name, "Function")) return true;
            const is_suspend_name = std.mem.startsWith(u8, ty.name, "SuspendFunction");
            if (is_suspend_name or std.mem.startsWith(u8, ty.name, "Function")) {
                const rest = ty.name[(if (is_suspend_name) "SuspendFunction".len else "Function".len)..];
                if (rest.len != 0 and allAsciiDigit(rest)) {
                    // `FunctionN` counts the declared parameters plus the
                    // receiver (`Foo.() -> R` is `Function1<Foo, R>`). A suspend
                    // closure is `SuspendFunctionN` and `Function(N+1)`.
                    const want = std.fmt.parseInt(usize, rest, 10) catch return true;
                    const info = self.closures.get(c.asPtr().id) orelse return true;
                    var have = info.n_params + @as(usize, @intFromBool(info.has_receiver));
                    if (info.n_params == 1 and closureItUnconstrained(self, info.body_func, info.module)) have -= 1;
                    const suspend_body = closureIsSuspend(self, info.body_func, info.module);
                    if (is_suspend_name) return suspend_body and want == have;
                    if (suspend_body) have += 1;
                    return want == have;
                }
            }
        },
        else => {},
    }

    // A dotted nested-class name matches by its last segment, the lifted top-level
    // name in the module table. A user Instance keeps the full dotted name, so the
    // identity walk below can reject another package's class.
    if (value.* != .Instance) {
        if (std.mem.findScalar(u8, ty.name, '.')) |_| {
            if (std.mem.findScalarLast(u8, ty.name, '.')) |i| {
                const last = ty.name[i + 1 ..];
                const alt: TypeRef = .{ .name = last, .nullable = ty.nullable, .args = ty.args };
                return instanceOf(self, value, alt);
            }
        }
    }

    // Generic type-parameter casts are erased and match unchecked: a single-letter
    // name with no class entry accepts any non-null, unless a reified bind
    // redirects the check to a concrete class.
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

    // An Exception's nominal type loses the specific class name, so match against
    // the throw site's actual fqn through the builtin Throwable hierarchy.
    switch (value.*) {
        .Exception => |e| {
            const g = e.fqn.borrow();
            defer g.deinit();
            return runtime.Value.builtinThrowableIsA(g.get().bytes, ty.name);
        },
        else => {},
    }

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
            // The target's FQN resolves only when it unambiguously denotes a
            // registered class, letting the identity check reject another
            // package's same-simple-name class.
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
                if (interfaceChainMatches(self, cdef, target_simple, target_fqn, ty.name)) return true;
                // Supertype names cover chains whose parent is a builtin absent
                // from the class table; matched by name only when no identity.
                for (cdef.supertype_names) |sup| {
                    if (target_fqn == null and std.mem.eql(u8, sup, target_simple)) return true;
                    if (containsStr(&builtin_exception_names, sup) and
                        containsStr(&builtin_exception_names, target_simple)) return true;
                }
                if (cdef.is_anonymous or target_fqn == null) {
                    for (cdef.supertype_names) |n| {
                        if (std.mem.eql(u8, n, target_simple)) return true;
                    }
                    // An anonymous class records its written supertypes as names,
                    // never resolved handles, so the walk resolves them itself.
                    if (supertypeNameChainMatches(self, cdef, target_simple, target_fqn, ty.name)) return true;
                }
                if (cdef.parent) |parent| {
                    cur = parent.clone();
                }
            }
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
    if (value.isRuntimeType(ty.name)) return true;
    // Last resort: a typealias the eager unfold skipped because an `expect class`
    // stub still owns the name in the module.
    if (typeAliasTarget(self, ty.name)) |t| {
        return instanceOf(self, value, .{ .name = t, .nullable = ty.nullable, .args = ty.args });
    }
    return false;
}

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

/// Whether any transitive supertype recorded by NAME matches the target: a
/// runtime-synthesized class has no resolved `interfaces` handles to walk.
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
        if (target_fqn == null and std.mem.eql(u8, name, target_simple)) return true;
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

/// Walk a class's interface supertypes, matching each by identity. The
/// `interfaces` slices are linked package-aware, so no other package leaks in.
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
    // Dedup by FQN: two same-simple-name interfaces must each be walked.
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
        // Builtin interface supertypes are absent from `interfaces`; match by
        // simple name only when identity is unavailable.
        if (target_fqn == null) {
            for (idef.supertype_names) |sup| {
                if (std.mem.eql(u8, sup, target_simple)) return true;
            }
        }
        for (idef.interfaces) |sup| {
            queue.append(a, sup.clone()) catch return false;
        }
    }
    return false;
}

fn builtinExceptionParentMatch(tail: []const u8, target: []const u8) bool {
    return runtime.Value.builtinThrowableIsA(tail, target);
}

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`, `host_fields.zig` and `host_call_member.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

/// Captured scope of the local class being registered: a supertype naming a
/// sibling resolves to that `.Class`, as the by-name table holds only the last.
threadlocal var registering_captures: []const NameValue = &.{};

fn capturedClass(name: []const u8) ?ObjRef(ClassDef) {
    for (registering_captures) |nv| {
        if (nv.value == .Class and std.mem.eql(u8, nv.name, name)) return nv.value.Class;
    }
    return null;
}

/// Synthesize the `ClassDef` shape `build_module` produces, for a local class.
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
    var fn_extra: usize = 0;
    for (class.supertypes) |*t| if (t.function) |ft| {
        const tags = try ir.lower.decl.functionSupertypeTags(allocator, ft);
        fn_extra += tags.len - 1;
    };
    var supertype_names = try allocator.alloc([]const u8, class.supertypes.len + fn_extra);
    var supertype_paths = try allocator.alloc(?[]const u8, class.supertypes.len + fn_extra);
    var extra_slot: usize = class.supertypes.len;
    for (class.supertypes, 0..) |*t, i| {
        if (t.function) |ft| {
            const tags = try ir.lower.decl.functionSupertypeTags(allocator, ft);
            supertype_names[i] = tags[0];
            supertype_paths[i] = null;
            for (tags[1..]) |tag| {
                supertype_names[extra_slot] = tag;
                supertype_paths[extra_slot] = null;
                extra_slot += 1;
            }
            continue;
        }
        supertype_names[i] = t.name.name;
        supertype_paths[i] = t.qualified_path;
    }

    // Local classes register after the class graph is linked, so connect their
    // parent/interface handles here: names alone lose transitive interfaces.
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
            // Resolve program classes through the index used at lowering; the
            // runtime table serves only a local class absent from the IR.
            const resolved_fqn: ?[]const u8 = static: {
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                // An erased function-type tag names no class.
                if (i >= class.supertypes.len) break :static null;
                const file = class.supertypes[i].name.span.file;
                const cid = if (qualified) |path|
                    module.classIdByQualifiedSuffix(path)
                else
                    module.classIdIndexed(name, module.packageOfFile(file) orelse "", file);
                const id = cid orelse break :static null;
                if (id.int() >= module.classes.items.len) break :static null;
                break :static module.classes.items[id.int()].fqn;
            };
            const super_def = if (qualified == null and capturedClass(name) != null)
                capturedClass(name)
            else if (resolved_fqn) |fqn|
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

    // ClassDef convention: an init block's position is the body-property index
    // it runs before, so construction interleaves them in declaration order.
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
        .type_param_bounds = try build.classTypeParamBoundHeads(allocator, class.type_params, class.where_bounds),
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

/// Resolve a dotted runtime-only supertype by aligned FQN suffix, preferring the
/// least-nested match. Program declarations resolve through the module first.
fn classByQualifiedSuffix(classes: *const ClassTable, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.findScalar(u8, qualified, '.') == null) return null;
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

/// Lower each member function into the class's side module and register it in
/// `anon_methods` under the arity-qualified and bare keys, `capture_pairs` bound;
/// `own_members` scopes bare names in the bodies.
fn lowerAndRegisterMethods(
    self: *VmHost,
    allocator: Allocator,
    class: *const ast.Class,
    own_members: *const StringSet,
    capture_pairs: []const NameValue,
) Allocator.Error!void {
    var site_mod: ?ObjRef(Module) = null;
    defer if (site_mod) |m| m.deinit();
    // The class's declared property types carry into the member lowerings, so a
    // body's `data.iterator()` types its receiver instead of walking by name.
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
    // Same-arity overloads share the `name#arity` key, so each is also indexed.
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
            .Property => |p| {
                if (p.getter) |getter| {
                    // `field` targets `this.__klio_field__<prop>` directly.
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
                // A complex initializer lowers as a `$init$` thunk; a delegated
                // property lowers its DELEGATE expression as that thunk, stored
                // under the property name for getValue/setValue.
                if (p.delegate) |dexpr| {
                    // The delegate may read plain ctor params, so the thunk
                    // declares them and construction passes the args.
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
                    // Declaring the primary params binds a bare name to the ctor
                    // param, even one the property shadows.
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
    // A non-literal primary-constructor default lowers as a `$default$<i>` thunk
    // declaring the parameters before it, evaluated in the captured scope.
    for (class.primary_params, 0..) |*pp, pi| {
        const dexpr: ast.Expr = pp.default orelse continue;
        if (host_call_value.simpleLiteral(allocator, &dexpr) != null) continue;
        const thunk_name: ast.Ident = .{
            .name = try std.fmt.allocPrint(allocator, "$default${d}", .{pi}),
            .span = pp.name.span,
        };
        var thunk = host_instances.synthThunk(thunk_name, .{ .Expr = dexpr }, null, false);
        const tparams = try allocator.alloc(ast.Param, pi);
        for (class.primary_params[0..pi], 0..) |*prev, k| {
            tparams[k] = .{
                .name = prev.name,
                .ty = prev.ty,
                .default = null,
                .is_vararg = false,
                .is_crossinline = false,
                .is_noinline = false,
                .annotations = &.{},
                .span = prev.name.span,
            };
        }
        thunk.params = tparams;
        const sub_ref = try host_instances.anonSiteModule(self, allocator, &site_mod);
        const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, class.name.name, own_members);
        const caps = try allocator.dupe(NameValue, capture_pairs);
        const tbl = self.anon_methods.borrowMut();
        defer tbl.deinit();
        try tbl.get().put(try anonKey(allocator, class.name.name, thunk_name.name), .{ .module = sub_ref, .func = func.id, .captures = caps });
    }
    // `init { … }` blocks lower as thunks over `this` under `$init$block$<idx>`,
    // run with the captured cells bound.
    for (class.init_blocks, 0..) |*blk, idx| {
        const thunk_name: ast.Ident = .{
            .name = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx}),
            .span = blk.span,
        };
        var thunk = host_instances.synthThunk(thunk_name, .{ .Block = blk.* }, null, false);
        // An `init` block may read a constructor parameter that is not a
        // property, which a 0-arg thunk would leave as a field read on `this`.
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

fn registerNestedClasses(self: *VmHost, allocator: Allocator, class: *const ast.Class) Allocator.Error!void {
    try registerNestedMembers(self, allocator, class.name.name, class.members);
}

/// Register a runtime class's nested classes and objects under `owner`, so the
/// body's members construct them by bare name.
pub const registerNestedClassMembers = registerNestedMembers;

pub fn registerNestedMembers(self: *VmHost, allocator: Allocator, owner: []const u8, members: []const ast.Decl) Allocator.Error!void {
    for (members) |*m| {
        switch (m.*) {
            .Class => |*nested| {
                if (nested.is_companion) {
                    // A local class's companion registers under a mangled name
                    // and publishes as the global `$companion:<owner>`.
                    var renamed = nested.*;
                    renamed.name = .{ .name = try std.fmt.allocPrint(allocator, "{s}$Companion", .{owner}), .span = nested.name.span };
                    renamed.is_companion = false;
                    const owned = try allocator.create(ast.Class);
                    owned.* = renamed;
                    _ = try registerClass(self, allocator, owned);
                    try publishLocalSingleton(self, allocator, owned.name.name, try std.fmt.allocPrint(allocator, "$companion:{s}", .{owner}));
                    continue;
                }
                _ = try registerClass(self, allocator, nested);
            },
            // A nested `object` registers as a class and binds under its name.
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
    // A local class declared in a fn body arrives here at runtime.
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
    var own_members = StringSet.init(allocator);
    defer own_members.deinit();
    try collectOwnMembers(class, &own_members);
    try lowerAndRegisterMethods(self, allocator, class, &own_members, &.{});
    try registerNestedClasses(self, allocator, class);
    // Parent-constructor arguments lower as `$super$arg$<i>` thunks declaring the
    // primary params, so a module parent initializes at construction.
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

/// Rewrite bare `field` to `this.__klio_field__<prop>`; get/set detect that
/// prefix and bypass accessor dispatch, so `field = value` does not recurse.
pub fn rewriteAccessorFieldRefs(allocator: Allocator, body: ast.FunctionBody, prop: []const u8) Allocator.Error!ast.FunctionBody {
    return switch (body) {
        .Expr => |e| .{ .Expr = (try build.lift.substituteFieldWithThis(allocator, prop, &e, null)).* },
        .Block => |blk| .{ .Block = try build.lift.rewriteBlockField(allocator, &blk, prop, null) },
    };
}

/// A class's nested singletons share its lexical scope and so its outer.
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
    // A captured local outranks a top-level prop of that name and stays dynamic.
    const prev_caps = ir.build.setLowerAnonCaptureNames(captured_names);
    defer _ = ir.build.setLowerAnonCaptureNames(prev_caps);
    // A captured `.Cell` is a boxed `var`; the member lowerings box it too, so a
    // write inside a method lands on the cell.
    var boxed_names: std.ArrayList([]const u8) = .empty;
    defer boxed_names.deinit(allocator);
    for (captured_names, 0..) |n, i| {
        if (i < captures.len and captures[i] == .Cell) try boxed_names.append(allocator, n);
    }
    const prev_boxed = ir.build.setLowerAnonBoxedNames(boxed_names.items);
    defer _ = ir.build.setLowerAnonBoxedNames(prev_boxed);
    // The same names go into the capture set the member lowerings consult, so a
    // nested lambda captures through the method's own slot, filled by name at
    // dispatch, not a global that lives only while the method runs.
    var cap_set = StringSet.init(allocator);
    for (captured_names) |n| try cap_set.put(n, {});
    const prev_set = ir.lower.takeLowerAnonCaptures();
    ir.lower.setLowerAnonCaptures(cap_set);
    defer ir.lower.setLowerAnonCaptures(prev_set);
    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    const prev_registering = registering_captures;
    registering_captures = capture_pairs;
    defer registering_captures = prev_registering;
    switch (try registerClass(self, allocator, class)) {
        .ok => {},
        .err => |e| return .{ .err = e },
    }
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
    // Re-lower with the outer's member names merged into `own_members`, so bare
    // outer property reads lower as `this.X` and resolve through the chain.
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
            try lowerAndRegisterMethods(self, allocator, class, &own_members, capture_pairs);
            try registerNestedClasses(self, allocator, class);
            try assignNestedOuters(self, allocator, class, tv);
            try patchCaptureEntries(self, allocator, class, capture_pairs);
            try bindClassFamily(self, allocator, class, capture_pairs);
            return .ok;
        }
    }
    // No `this` captured: patch the method entries with the outer env instead.
    if (capture_pairs.len != 0) try patchCaptureEntries(self, allocator, class, capture_pairs);
    try bindClassFamily(self, allocator, class, capture_pairs);
    return .ok;
}

/// Publish the registration's scope (captured pairs, then each family member by
/// name) on every def of the class and its nested classes. Dispatch layers it
/// under globals, so a method's bare `C(...)` builds this registration.
fn bindClassFamily(self: *VmHost, allocator: Allocator, class: *const ast.Class, capture_pairs: []const NameValue) Allocator.Error!void {
    var list: std.ArrayList(InstanceData.Capture) = .empty;
    for (capture_pairs) |nv| try list.append(allocator, .{ .name = nv.name, .value = nv.value });
    var defs: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (defs.items) |d| d.deinit();
        defs.deinit(allocator);
    }
    try collectFamilyDefs(self, allocator, class, &list, &defs);
    const shared = try list.toOwnedSlice(allocator);
    const enclosing = try ir.eval.captureChainAlloc(allocator);
    if (runtime.reclaimEnabled()) {
        for (enclosing) |e| e.v.retain();
    }
    for (defs.items) |d| {
        const g = d.borrowMut();
        defer g.deinit();
        g.get().local_captures = shared;
        g.get().local_enclosing = enclosing;
    }
}

fn collectFamilyDefs(
    self: *VmHost,
    allocator: Allocator,
    class: *const ast.Class,
    list: *std.ArrayList(InstanceData.Capture),
    defs: *std.ArrayList(ObjRef(ClassDef)),
) Allocator.Error!void {
    const def = classDefByNameLocal(self, class.name.name) orelse return;
    try list.append(allocator, .{ .name = class.name.name, .value = .{ .Class = def.clone() } });
    try defs.append(allocator, def);
    for (class.members) |*m| {
        if (m.* != .Class or m.Class.is_companion) continue;
        try collectFamilyDefs(self, allocator, &m.Class, list, defs);
    }
}

/// Point every registry entry the class registered, and its nested classes', at
/// the captured enclosing env.
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
        for (class.primary_params, 0..) |_, pi| {
            const nm = try std.fmt.allocPrint(allocator, "$default${d}", .{pi});
            const key = try anonKey(allocator, class.name.name, nm);
            if (tbl.get().getPtr(key)) |entry| entry.captures = capture_pairs;
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
                    // Indexed overload keys are dense from zero.
                    var overload_index: usize = 0;
                    while (true) : (overload_index += 1) {
                        const member = try root.anonOverloadMemberName(allocator, arity_name, overload_index);
                        const key = try anonKey(allocator, class.name.name, member);
                        const entry = tbl.get().getPtr(key) orelse break;
                        entry.captures = capture_pairs;
                    }
                },
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

/// The `.Class` for a local class, which shadows a same-named top-level fn.
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
        // The registry holds these captures for the object's whole lifetime, so
        // retain; released when the entry is dropped, a no-op under the arena.
        if (runtime.reclaimEnabled()) captures[i].retain();
        pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    }
    return pairs;
}

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

/// The FQN of the single registered class `name` denotes, or null for a shared
/// simple name, a builtin, a generic parameter, or an ambiguous FQN.
fn resolveClassFqn(self: *VmHost, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const cid = m.classIdByFqn(name) orelse return null;
    if (cid.int() >= m.classes.items.len) return null;
    return m.classes.items[cid.int()].fqn;
}

/// Identity-aware subtype match for the `is`/`as` walk: `target_fqn` is non-null
/// only when the target unambiguously denotes a registered class, so a
/// same-simple-name match is rejected only when the two provably differ.
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
    // Reject only when the walked class is itself registered, so the two differ.
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
    if (std.mem.findScalarLast(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

fn isReflectionTypeName(name: []const u8) bool {
    return matchesAny(name, &.{
        "KProperty",  "KCallable",  "KFunction",        "KFunction0",
        "KFunction1", "KFunction2", "KMutableProperty",
    });
}

/// Builtin and stdlib type names that are not user classes but are still concrete
/// cast targets, so `x as String` throws while `x as TBuilder` stays unchecked.
fn isBuiltinTypeName(name: []const u8) bool {
    const builtins = [_][]const u8{
        // Primitives + their boxed/number forms.
        "Int",                           "Long",                                 "Short",                           "Byte",                         "Double",              "Float",                      "Char",                     "Boolean",
        "UInt",                          "ULong",                                "UShort",                          "UByte",                        "Number",              "Unit",                       "Nothing",                  "Any",
        // Strings / char sequences.
        "String",                        "CharSequence",                         "StringBuilder",
        // Comparison / common interfaces.
                          "Comparable",                   "Comparator",          "Pair",                       "Triple",
        "Entry",                         "MutableEntry",
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
