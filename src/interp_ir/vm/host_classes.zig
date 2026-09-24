//! `VmHost` class-side dispatch: `is`/`as` checks and runtime registration of
//! local and anonymous-object classes lowered during eval. Free functions over
//! `*VmHost`, aliased as methods by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const VmHost = @import("vmhost.zig").VmHost;
const host_call_func = @import("host_call_func.zig");

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const TypeRef = ir.TypeRef;

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
        "Int",                      "Long",                  "Short",                         "Byte",                                 "Double",                          "Float",                        "Char",                "Boolean",
        "UInt",                     "ULong",                 "UShort",                        "UByte",                                "Number",                          "Unit",                         "Nothing",             "Any",
        // Strings / char sequences.
        "String",                   "CharSequence",          "StringBuilder",
        // Comparison / common interfaces.
                        "Comparable",                           "Comparator",                      "Pair",                         "Triple",              "Entry",
        "MutableEntry",
        // Collections + arrays (read-only and mutable).
                    "Array",                 "IntArray",                      "LongArray",                            "ShortArray",                      "ByteArray",                    "DoubleArray",         "FloatArray",
        "CharArray",                "BooleanArray",          "UIntArray",                     "ULongArray",                           "UShortArray",                     "UByteArray",                   "List",                "MutableList",
        "ArrayList",                "AbstractList",          "AbstractMutableList",           "Collection",                           "MutableCollection",               "AbstractCollection",           "Iterable",            "MutableIterable",
        "Iterator",                 "MutableIterator",       "ListIterator",                  "Set",                                  "MutableSet",                      "HashSet",                      "LinkedHashSet",       "AbstractSet",
        "Map",                      "MutableMap",            "HashMap",                       "LinkedHashMap",                        "AbstractMap",                     "Sequence",                     "EnumEntries",
        // Ranges / progressions.
                "IntRange",
        "LongRange",                "CharRange",             "IntProgression",                "LongProgression",                      "CharProgression",                 "ClosedRange",                  "OpenEndRange",
        // Reflection.
               "KClass",
        "KProperty",                "KCallable",             "KFunction",                     "KMutableProperty",
        // Throwable hierarchy.
                            "Throwable",                       "Exception",                    "RuntimeException",    "Error",
        "IllegalArgumentException", "IllegalStateException", "IndexOutOfBoundsException",     "ArrayIndexOutOfBoundsException",       "StringIndexOutOfBoundsException", "NullPointerException",         "ArithmeticException", "ClassCastException",
        "NoSuchElementException",   "NumberFormatException", "UnsupportedOperationException", "UninitializedPropertyAccessException", "ConcurrentModificationException", "NoWhenBranchMatchedException", "AssertionError",      "NegativeArraySizeException",
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

/// The registered `ClassDef` for `name`, or null. The handle is BORROWED from
/// the class table, which owns it for the program's life; callers that keep it
/// past the table clone it themselves.
pub fn classDefLookup(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    if (name.len == 0) return null;
    const g = self.classes.borrow();
    defer g.deinit();
    return g.get().get(name);
}
