//! What kotlinc refuses in a declaration's shape: modifiers that exclude
//! each other or do not apply, data, value, enum and annotation classes
//! that break their rules, supertypes a class cannot have, `lateinit`,
//! `const`, extension and inline properties, and misused parameter
//! modifiers. Only the program's declarations are checked, once their
//! bodies are resolved; each finding is a `declaration` site naming
//! kotlinc's diagnostic.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const subtyping = @import("subtyping.zig");
const diagnose = @import("diagnose.zig");
const members = @import("members.zig");
const census = @import("census.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Span = span.Span;

/// Checks every declaration of the program's files.
pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        const info = s.syms.get(sym);
        const fc = s.fileOf(info.file) orelse continue;
        if (!checked(fc)) continue;
        if (info.flags.synthetic) continue;
        const c = Checker{ .s = s, .file = info.file };
        // A program's declarations are checked, and each has its AST.
        switch (info.decl) {
            .class => |d| if (info.kind == .class) try c.class(sym, d.?),
            .object => |d| if (info.kind == .class) try c.object(sym, d.?),
            .object_literal => |d| if (info.kind == .class) {
                try c.supertypes(sym, d.?.supertypes, d.?.supertype_args, d.?.supertype_delegates, true);
                try c.inheritedMembers(sym, d.?.span);
            },
            .function => |d| if (info.kind == .function) try c.function(sym, d.?),
            .property => |d| if (info.kind == .property) try c.property(sym, d.?),
            .class_param => |d| if (info.kind == .property) try c.overrides(sym, d.?.is_override, d.?.name.span),
            .secondary_ctor => |d| try c.params(d.?.params, false),
            else => {},
        }
    }
}

const Checker = struct {
    s: *Sema,
    file: u32,

    fn report(self: Checker, sp: Span, factory: census.Factory, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.s.arena, fmt, args);
        try self.s.census.reportFacts(.declaration, self.file, sp, .{ .message = msg, .factory = factory }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    fn warn(self: Checker, sp: Span, factory: census.Factory, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.s.arena, fmt, args);
        try self.s.census.reportFacts(.declaration, self.file, sp, .{ .message = msg, .factory = factory, .severity = .warning }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    /// kotlinc reports a pair of modifiers that exclude each other once on
    /// each.
    fn incompatible(self: Checker, sp: Span, a: []const u8, b: []const u8) Allocator.Error!void {
        try self.report(sp, .INCOMPATIBLE_MODIFIERS, "Modifier '{s}' is incompatible with '{s}'.", .{ a, b });
        try self.report(sp, .INCOMPATIBLE_MODIFIERS, "Modifier '{s}' is incompatible with '{s}'.", .{ b, a });
    }

    fn wrongTarget(self: Checker, sp: Span, modifier: []const u8, target: []const u8) Allocator.Error!void {
        try self.report(sp, .WRONG_MODIFIER_TARGET, "Modifier '{s}' is not applicable to '{s}'.", .{ modifier, target });
    }

    // ------------------------------------------------------------ classes --

    fn class(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        const at = c.name.span;
        // A class nested in an `expect` class is an `expect` too.
        const expect = inExpect(self.s, cls);
        // The parser marks an abstract class open too.
        const open = c.is_open and !c.is_abstract;
        const kind: []const u8 = if (c.is_annotation) "annotation class" else if (c.is_enum) "enum class" else if (c.is_interface) "interface" else "class";
        if (c.is_annotation or c.is_enum or c.is_interface) {
            // What a classifier of this kind cannot be.
            const Mod = struct { on: bool, name: []const u8 };
            const mods = [_]Mod{
                .{ .on = open and !c.is_interface, .name = "open" },
                .{ .on = c.is_abstract and !c.is_interface, .name = "abstract" },
                .{ .on = c.is_sealed and !c.is_interface, .name = "sealed" },
                .{ .on = c.is_data, .name = "data" },
                .{ .on = c.is_inner, .name = "inner" },
                .{ .on = c.is_value, .name = "value" },
            };
            for (mods) |m| if (m.on) try self.wrongTarget(at, m.name, kind);
        } else {
            if (c.is_data) {
                if (open) try self.incompatible(at, "open", "data");
                if (c.is_abstract) try self.incompatible(at, "abstract", "data");
                if (c.is_sealed) try self.incompatible(at, "sealed", "data");
                if (c.is_inner) try self.incompatible(at, "inner", "data");
                if (c.is_value) try self.incompatible(at, "data", "value");
            }
            if (open and c.is_sealed) try self.incompatible(at, "open", "sealed");
            if (c.is_sealed and c.is_inner) try self.incompatible(at, "sealed", "inner");
            if (c.is_data and !c.is_value and !expect) try self.dataClass(c);
            if (c.is_value and !c.is_data and !expect) try self.valueClass(cls, c);
        }
        try self.classParams(c.primary_params);
        if (!expect and !c.is_external) {
            // A class has a primary constructor when it writes one or
            // declares no other.
            const primary = c.has_primary_ctor or c.x().secondary_ctors.len == 0;
            try self.supertypes(cls, c.supertypes, c.supertype_args, c.supertype_delegates, primary and !c.is_interface);
            if (!c.is_annotation) try self.inheritedMembers(cls, at);
        }
        try self.genericThrowable(cls, c.type_params);
        if (c.is_enum and !expect) try self.enumEntries(cls, c);
        try self.constructorCycles(cls);
    }

    /// Secondary constructors that delegate to each other in a circle:
    /// none of them ever reaches a superclass constructor.
    fn constructorCycles(self: Checker, cls: Sym) Allocator.Error!void {
        const s = self.s;
        var next: std.AutoHashMapUnmanaged(Sym, Sym) = .empty;
        const ctors = symbols.Symbols.members(&s.syms.classInfo(cls).members, sema_mod.wk.init);
        for (ctors) |ctor| {
            const d = switch (s.syms.get(ctor).decl) {
                .secondary_ctor => |d| d.?,
                else => continue,
            };
            if (d.delegation != .This) continue;
            for (s.refs.items) |r| {
                if (r.kind != .ctor or r.file != self.file or r.anchor.start != d.span.start or r.anchor.end != d.span.end) continue;
                if (s.syms.kind(r.target) == .constructor) try next.put(s.arena, ctor, r.target);
                break;
            }
        }
        for (ctors) |ctor| {
            const d = switch (s.syms.get(ctor).decl) {
                .secondary_ctor => |d| d.?,
                else => continue,
            };
            var cur = next.get(ctor) orelse continue;
            var steps: usize = 0;
            while (cur != ctor and steps <= ctors.len) : (steps += 1) {
                cur = next.get(cur) orelse break;
            }
            if (cur == ctor) try self.report(d.span, .CYCLIC_CONSTRUCTOR_DELEGATION_CALL, "There's a cycle in the delegation calls chain.", .{});
        }
    }

    fn dataClass(self: Checker, c: *const ast.Class) Allocator.Error!void {
        if (c.primary_params.len == 0) {
            try self.report(c.name.span, .DATA_CLASS_WITHOUT_PARAMETERS, "Data class must have at least one primary constructor parameter.", .{});
            return;
        }
        for (c.primary_params) |p| {
            if (p.is_vararg) {
                try self.report(p.span, .DATA_CLASS_VARARG_PARAMETER, "Primary constructor vararg parameters are prohibited for data classes.", .{});
            } else if (p.property == null) {
                try self.report(p.span, .DATA_CLASS_NOT_PROPERTY_PARAMETER, "Data class primary constructor must only have property ('val' / 'var') parameters.", .{});
            }
        }
    }

    /// A value class wraps one read-only property and extends no class;
    /// `FullValueClasses` lifts both, and lets it be abstract or sealed.
    fn valueClass(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        if (self.language().full_value_classes) return;
        const s = self.s;
        if (c.is_open or c.is_sealed) {
            try self.report(c.name.span, .VALUE_CLASS_NOT_FINAL, "Value class can be only final.", .{});
            return;
        }
        for (c.supertypes) |*tr| {
            const target = s.types.classSym(try self.quietType(cls, tr));
            if (target == .none or target == s.builtins.any or s.syms.kind(target) != .class) continue;
            if (s.syms.classInfo(target).kind == .interface) continue;
            try self.report(tr.span, .VALUE_CLASS_CANNOT_EXTEND_CLASSES, "Value class cannot extend classes.", .{});
        }
        if (c.primary_params.len == 0) {
            try self.report(c.name.span, .VALUE_CLASS_EMPTY_CONSTRUCTOR, "Value class must have exactly one primary constructor parameter.", .{});
            return;
        }
        if (c.primary_params.len > 1) {
            try self.report(c.name.span, .UNSUPPORTED_FEATURE, "The feature \"full value classes\" is experimental and should be enabled explicitly.", .{});
        }
        for (c.primary_params) |p| {
            if (p.property != false) {
                try self.report(p.span, .VALUE_CLASS_CONSTRUCTOR_NOT_FINAL_READ_ONLY_PARAMETER, "Value class primary constructor must only have final read-only ('val') property parameters.", .{});
            }
        }
    }

    /// The language features the checked file was parsed with.
    fn language(self: Checker) ast.LanguageFeatures {
        const fc = self.s.fileOf(self.file) orelse return .{};
        return (fc.ast orelse return .{}).language;
    }

    fn object(self: Checker, cls: Sym, o: *const ast.ObjectDecl) Allocator.Error!void {
        if (o.is_data) {
            // A data object's `equals` and `hashCode` are the language's.
            for (o.members) |*m| switch (m.*) {
                .Function => |*f| {
                    const eq = std.mem.eql(u8, f.name.name, "equals") and f.params.len == 1;
                    const hash = std.mem.eql(u8, f.name.name, "hashCode") and f.params.len == 0;
                    if (f.is_override and f.receiver_type == null and (eq or hash)) {
                        try self.report(f.name.span, .DATA_OBJECT_CUSTOM_EQUALS_OR_HASH_CODE, "Data object cannot have a custom implementation of 'equals' or 'hashCode'.", .{});
                    }
                },
                else => {},
            };
        }
        if (!inExpect(self.s, cls)) {
            try self.supertypes(cls, o.supertypes, o.supertype_args, o.supertype_delegates, true);
            try self.inheritedMembers(cls, o.name.span);
        }
    }

    /// The supertypes a class, object or object expression names:
    /// `initialized` when its constructor must call its superclass's.
    fn supertypes(self: Checker, cls: Sym, written: []const ast.TypeRef, args: []const ?[]ast.Expr, delegates: []const ?ast.Expr, initialized: bool) Allocator.Error!void {
        const s = self.s;
        const local = isLocal(s, cls);
        const anonymous = s.syms.classInfo(cls).kind == .anonymous;
        for (written, 0..) |*tr, i| {
            const t = try self.quietType(cls, tr);
            const target = s.types.classSym(t);
            if (target == .none or s.types.isErr(t) or s.syms.kind(target) != .class) continue;
            const tk = s.syms.classInfo(target).kind;
            const tf = s.syms.flags(target);
            const delegated = i < delegates.len and delegates[i] != null;
            const called = i < args.len and args[i] != null;
            if (delegated and tk != .interface) {
                try self.report(tr.span, .DELEGATION_NOT_TO_INTERFACE, "Delegation is supported only for interfaces.", .{});
            }
            if (tk == .object or tk == .companion) {
                try self.report(tr.span, .SINGLETON_IN_SUPERTYPE, "Cannot extend an object.", .{});
                continue;
            }
            if (tk != .class) continue;
            if (tf.modality == .final and !tf.expect) {
                try self.report(tr.span, .FINAL_SUPERTYPE, "This type is final, so it cannot be extended.", .{});
            }
            if ((local or anonymous) and tf.modality == .sealed) {
                try self.report(tr.span, .SEALED_SUPERTYPE_IN_LOCAL_CLASS, "{s} cannot extend a sealed class.", .{if (anonymous) "Anonymous object" else "Local class"});
            }
            if (initialized and !called) {
                try self.report(tr.span, .SUPERTYPE_NOT_INITIALIZED, "This type has a constructor, so it must be initialized here.", .{});
            }
        }
    }

    /// What a class inherits and must override: an abstract member no
    /// supertype implements (unless the class is abstract), and a member
    /// several supertypes implement, or an interface implements beside
    /// another's abstract one.
    fn inheritedMembers(self: Checker, cls: Sym, at: Span) Allocator.Error!void {
        const s = self.s;
        const info = s.syms.classInfo(cls);
        const abstract_cls = switch (info.kind) {
            .interface => true,
            .class => s.syms.flags(cls).modality == .abstract or s.syms.flags(cls).modality == .sealed,
            .enum_class => true,
            .annotation => return,
            else => false,
        };
        var names: std.AutoArrayHashMapUnmanaged(sema_mod.Name, void) = .empty;
        try self.closureNames(cls, &names);
        var missing: Missing = .{};
        for (names.keys()) |n| {
            for ([_]members.Want{ .function, .property }) |want| {
                try self.slots(cls, at, n, want, abstract_cls, &missing);
            }
        }
        // kotlinc lists every member a class leaves unimplemented in one
        // diagnostic.
        const what = try self.classWord(cls);
        if (info.kind == .enum_entry) {
            const all = try std.mem.concat(s.arena, Sym, &.{ missing.class.items, missing.iface.items });
            if (all.len != 0) try self.report(at, .ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY, "{s} does not implement abstract {s}.", .{ what, try self.memberList(all) });
            return;
        }
        if (missing.class.items.len != 0) {
            try self.report(at, .ABSTRACT_CLASS_MEMBER_NOT_IMPLEMENTED, "{s} is not abstract and does not implement abstract base class {s}.", .{ what, try self.memberList(missing.class.items) });
        }
        if (missing.iface.items.len != 0) {
            try self.report(at, .ABSTRACT_MEMBER_NOT_IMPLEMENTED, "{s} is not abstract and does not implement abstract {s}.", .{ what, try self.memberList(missing.iface.items) });
        }
    }

    /// The abstract members a class leaves unimplemented: a class's, and an
    /// interface's.
    const Missing = struct {
        class: std.ArrayList(Sym) = .empty,
        iface: std.ArrayList(Sym) = .empty,
    };

    /// `member 'fun f(): Unit'`, or `members 'fun f(): Unit', 'val x: Int'`.
    fn memberList(self: Checker, ms: []const Sym) Allocator.Error![]const u8 {
        const s = self.s;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(s.arena, if (ms.len == 1) "member " else "members ");
        for (ms, 0..) |m, i| {
            if (i != 0) try buf.appendSlice(s.arena, ", ");
            try buf.print(s.arena, "'{s}'", .{try diagnose.declarationText(s, s.arena, m)});
        }
        return buf.items;
    }

    /// The member names of every class above `cls`.
    fn closureNames(self: Checker, cls: Sym, out: *std.AutoArrayHashMapUnmanaged(sema_mod.Name, void)) Allocator.Error!void {
        const s = self.s;
        var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
        var work: std.ArrayList(Sym) = .empty;
        try work.append(s.arena, cls);
        while (work.pop()) |c| {
            for (try headers.supertypes(s, c)) |st| {
                const sc = s.types.classSym(st);
                if (sc == .none or s.syms.kind(sc) != .class) continue;
                if ((try seen.getOrPut(s.arena, sc)).found_existing) continue;
                try work.append(s.arena, sc);
                for (s.syms.classInfo(sc).members.keys()) |k| try out.put(s.arena, k, {});
            }
        }
    }

    fn slots(self: Checker, cls: Sym, at: Span, n: sema_mod.Name, want: members.Want, abstract_cls: bool, missing: *Missing) Allocator.Error!void {
        const s = self.s;
        // Every member of the name above the class, however near: which of
        // them the class inherits apart is what overrides whom decides,
        // below. One deprecated as hidden still implements.
        var supplied: std.ArrayList(members.Member) = .empty;
        for (try members.lookupOverridable(s, try headers.selfType(s, cls), n, want)) |m| {
            if (s.syms.owner(m.sym) == cls) continue;
            const k = s.syms.kind(m.sym);
            if (k != .function and k != .property) continue;
            const f = s.syms.flags(m.sym);
            if (f.static or f.visibility == .private) continue;
            if (k == .property) {
                try headers.propertyHeader(s, m.sym);
                if (s.syms.propertyInfo(m.sym).receiver != .none) continue;
            } else {
                try headers.functionHeader(s, m.sym);
                if (s.syms.functionInfo(m.sym).receiver != .none) continue;
            }
            try supplied.append(s.arena, m);
        }
        var done: std.ArrayList(bool) = .empty;
        try done.appendNTimes(s.arena, false, supplied.items.len);
        for (supplied.items, 0..) |m, i| {
            if (done.items[i]) continue;
            // The slot: the members of one signature.
            var group: std.ArrayList(Sym) = .empty;
            for (supplied.items[i..], i..) |o, j| {
                if (done.items[j]) continue;
                if (want == .function and !try members.sameSignature(s, m.sym, m.subst, o.sym, o.subst)) continue;
                done.items[j] = true;
                try group.append(s.arena, o.sym);
            }
            if (try self.declaresOverride(cls, n, want, group.items)) continue;
            try self.inheritedSlot(cls, at, group.items, abstract_cls, missing);
        }
    }

    /// Whether the class declares a member overriding one of `group`.
    fn declaresOverride(self: Checker, cls: Sym, n: sema_mod.Name, want: members.Want, group: []const Sym) Allocator.Error!bool {
        const s = self.s;
        for (symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |own| {
            const k = s.syms.kind(own);
            if ((want == .function and k != .function) or (want == .property and k != .property)) continue;
            for (try members.overridden(s, own)) |b| {
                for (group) |x| if (x == b or try members.overridesTransitively(s, x, b) or try members.overridesTransitively(s, b, x)) return true;
            }
            // A member the language declares (a delegated member, a data
            // class's) stands in for the slot.
            if (s.syms.flags(own).synthetic) return true;
        }
        return false;
    }

    fn inheritedSlot(self: Checker, cls: Sym, at: Span, all: []const Sym, abstract_cls: bool, missing: *Missing) Allocator.Error!void {
        const s = self.s;
        // A member another of the slot overrides is not inherited apart.
        var kept: std.ArrayList(Sym) = .empty;
        for (all) |x| {
            var hidden = false;
            for (all) |y| {
                if (x != y and try members.overridesTransitively(s, y, x)) hidden = true;
            }
            if (!hidden) try kept.append(s.arena, x);
        }
        var class_abstract: Sym = .none;
        var class_concrete: usize = 0;
        var iface_abstract: Sym = .none;
        var iface_concrete: usize = 0;
        for (kept.items) |x| {
            const owner = s.syms.owner(x);
            const from_iface = s.syms.kind(owner) == .class and s.syms.classInfo(owner).kind == .interface;
            const abstract = s.syms.flags(x).modality == .abstract;
            if (from_iface) {
                if (abstract) iface_abstract = x else iface_concrete += 1;
            } else {
                if (abstract) class_abstract = x else class_concrete += 1;
            }
        }
        const what = try self.classWord(cls);
        const name = s.str(s.syms.name(kept.items[0]));
        if (class_abstract != .none) {
            if (!abstract_cls) try missing.class.append(s.arena, class_abstract);
            return;
        }
        if (class_concrete != 0) {
            if (iface_concrete != 0) try self.report(at, .MANY_IMPL_MEMBER_NOT_IMPLEMENTED, "{s} must override '{s}' because it inherits multiple implementations for it.", .{ what, name });
            return;
        }
        if (iface_concrete != 0) {
            if (iface_concrete + @intFromBool(iface_abstract != .none) > 1) {
                try self.report(at, .MANY_INTERFACES_MEMBER_NOT_IMPLEMENTED, "{s} must override '{s}' because it inherits multiple interface methods for it.", .{ what, name });
            }
            return;
        }
        if (iface_abstract != .none and !abstract_cls) try missing.iface.append(s.arena, iface_abstract);
    }

    /// `Class 'C'`, `Object 'O'`, `Interface 'I'`, as kotlinc names the
    /// class a diagnostic is about.
    fn classWord(self: Checker, cls: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        const n = s.str(s.syms.name(cls));
        return switch (s.syms.classInfo(cls).kind) {
            .object, .companion => std.fmt.allocPrint(s.arena, "Object '{s}'", .{n}),
            .interface => std.fmt.allocPrint(s.arena, "Interface '{s}'", .{n}),
            .anonymous => "Class '<anonymous>'",
            // An entry's body is the class `$Entry` in its enum class.
            .enum_entry => std.fmt.allocPrint(s.arena, "Enum entry '{s}.{s}'", .{ s.str(s.syms.name(s.syms.owner(cls))), std.mem.trimStart(u8, n, "$") }),
            else => std.fmt.allocPrint(s.arena, "Class '{s}'", .{n}),
        };
    }

    /// An enum entry without a body implements nothing: every abstract
    /// member of its enum class is missing there.
    fn enumEntries(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        const s = self.s;
        var abstract: std.ArrayList(Sym) = .empty;
        for (s.syms.classInfo(cls).members.values()) |list| for (list.items) |m| {
            const k = s.syms.kind(m);
            if ((k == .function or k == .property) and s.syms.flags(m).modality == .abstract) try abstract.append(s.arena, m);
        };
        if (abstract.items.len == 0) return;
        const list = try self.memberList(abstract.items);
        for (c.x().enum_entries) |e| {
            if (e.body_members.len != 0) continue;
            try self.report(e.name.span, .ABSTRACT_MEMBER_NOT_IMPLEMENTED_BY_ENUM_ENTRY, "Enum entry '{s}.{s}' does not implement abstract {s}.", .{ c.name.name, e.name.name, list });
        }
    }

    /// A type written in a class header, resolved again without reporting:
    /// the header pass has reported what does not resolve.
    fn quietType(self: Checker, cls: Sym, tr: *const ast.TypeRef) Allocator.Error!TypeId {
        const s = self.s;
        s.census.muted += 1;
        defer s.census.muted -= 1;
        return headers.resolveTypeRef(s, .{ .decl = cls, .file = self.file, .header = true }, tr);
    }

    /// A class with type parameters cannot extend `Throwable`: a `catch`
    /// cannot tell its instances apart.
    fn genericThrowable(self: Checker, cls: Sym, tps: []const ast.TypeParam) Allocator.Error!void {
        const s = self.s;
        if (tps.len == 0 or s.builtins.throwable == .none) return;
        if (!try subtyping.isSubtype(s, try headers.selfType(s, cls), try s.simpleType(s.builtins.throwable))) return;
        try self.report(tps[0].span, .GENERIC_THROWABLE_SUBCLASS, "Subclass of 'Throwable' cannot have type parameters.", .{});
    }

    fn classParams(self: Checker, ps: []const ast.ClassParam) Allocator.Error!void {
        var varargs: usize = 0;
        for (ps) |p| varargs += @intFromBool(p.is_vararg);
        if (varargs < 2) return;
        for (ps) |p| if (p.is_vararg) try self.report(p.span, .MULTIPLE_VARARG_PARAMETERS, "Multiple vararg parameters are prohibited.", .{});
    }

    // ---------------------------------------------------------- functions --

    fn function(self: Checker, f: Sym, d: *const ast.Function) Allocator.Error!void {
        const s = self.s;
        const at = d.name.span;
        const member = isMember(s, f);
        // The parser marks an abstract function open too.
        const open = d.is_open and !d.is_abstract;
        if (d.visibility == .Private and member) {
            if (d.is_override) try self.incompatible(at, "private", "override");
            if (open) try self.incompatible(at, "private", "open");
            if (d.is_abstract) try self.incompatible(at, "private", "abstract");
        }
        if (d.is_final and open) try self.incompatible(at, "final", "open");
        if (d.is_final and d.is_abstract) try self.incompatible(at, "final", "abstract");
        if (!d.is_inline) {
            for (d.type_params) |tp| {
                if (tp.is_reified) try self.report(tp.span, .REIFIED_TYPE_PARAMETER_NO_INLINE, "Only type parameters of inline functions can be reified.", .{});
            }
        }
        try self.params(d.params, d.is_inline);
        if (member) try self.overrides(f, d.is_override, at);
        if (d.is_operator) try self.operatorShape(f, d, member);
        if (d.is_inline and !inExpect(s, f) and !try inlinesSomething(s, f, d)) {
            try self.warn(at, .NOTHING_TO_INLINE, "Expected performance impact from inlining is insignificant. Inlining works best for functions with parameters of function types.", .{});
        }
        if (member and d.is_override) try self.parameterNames(f, d);
        if (d.return_type == null and d.visibility != .Private and !isLocalDecl(s, f)) {
            if (d.body) |*b| switch (b.*) {
                .Expr => |*e| try self.escapingAnonymous(at, e),
                else => {},
            };
        }
        if (d.is_infix and ((!member and d.receiver_type == null) or d.params.len != 1 or d.params[0].is_vararg or d.params[0].default != null)) {
            try self.report(at, .INAPPLICABLE_INFIX_MODIFIER, "'infix' modifier is inapplicable on this function: must be a member or an extension function with a single value parameter.", .{});
        }
    }

    /// An override's parameter named otherwise than the overridden one's: a
    /// call naming its arguments means one or the other.
    fn parameterNames(self: Checker, f: Sym, d: *const ast.Function) Allocator.Error!void {
        const s = self.s;
        const bases = try members.overridden(s, f);
        if (bases.len != 1) return;
        const b = bases[0];
        // A member the language declares has no names written to keep.
        if (s.syms.flags(b).synthetic) return;
        const own = s.syms.functionInfo(f).params;
        const theirs = s.syms.functionInfo(b).params;
        if (own.len != theirs.len or own.len != d.params.len) return;
        for (own, theirs, d.params) |p, q, ap| {
            const n = s.str(s.syms.name(q));
            if (std.mem.eql(u8, s.str(s.syms.name(p)), n)) continue;
            try self.warn(ap.span, .PARAMETER_NAME_CHANGED_ON_OVERRIDE, "The corresponding parameter in the supertype '{s}' is named '{s}'. This may cause problems when calling this function with named arguments.", .{ s.str(s.syms.name(s.syms.owner(b))), n });
        }
    }

    /// What an `operator` function of each convention must look like:
    /// its parameter count, its return type, not `suspend` for a delegate.
    fn operatorShape(self: Checker, f: Sym, d: *const ast.Function, member: bool) Allocator.Error!void {
        const s = self.s;
        const at = d.name.span;
        const n = d.name.name;
        const np = d.params.len;
        const eql = std.mem.eql;
        const Rule = struct { count: ?usize = null, at_least: ?usize = null, returns: Sym = .none, not_suspend: bool = false };
        const b = s.builtins;
        // kotlinc holds `inc` and `dec` to no parameter count.
        const rule: Rule = if (oneOf(n, &.{ "inc", "dec" }))
            .{}
        else if (oneOf(n, &.{ "unaryPlus", "unaryMinus", "not", "iterator", "next" }))
            .{ .count = 0 }
        else if (oneOf(n, &.{ "plus", "minus", "times", "div", "rem", "mod", "rangeTo", "rangeUntil" }))
            .{ .count = 1 }
        else if (oneOf(n, &.{ "plusAssign", "minusAssign", "timesAssign", "divAssign", "remAssign", "modAssign" }))
            .{ .count = 1, .returns = b.unit }
        else if (eql(u8, n, "compareTo"))
            .{ .count = 1, .returns = b.int }
        else if (eql(u8, n, "contains"))
            .{ .count = 1, .returns = b.boolean }
        else if (eql(u8, n, "hasNext"))
            .{ .count = 0, .returns = b.boolean }
        else if (eql(u8, n, "equals"))
            .{ .count = 1 }
        else if (eql(u8, n, "get"))
            .{ .at_least = 1 }
        else if (eql(u8, n, "set"))
            .{ .at_least = 2 }
        else if (eql(u8, n, "getValue") or eql(u8, n, "provideDelegate"))
            .{ .count = 2, .not_suspend = true }
        else if (eql(u8, n, "setValue"))
            .{ .count = 3, .not_suspend = true }
        // `of` builds a collection literal.
        else if (eql(u8, n, "invoke") or eql(u8, n, "of"))
            .{}
        else if (std.mem.startsWith(u8, n, "component") and n.len > "component".len and std.fmt.parseInt(u32, n["component".len..], 10) catch 0 > 0)
            .{ .count = 0 }
        else
            return self.inapplicableOperator(at, "illegal function name");
        if (!member and d.receiver_type == null) {
            return self.inapplicableOperator(at, "must be a member or an extension function");
        }
        // A vararg or a default leaves the count to the call; kotlinc
        // weighs those cases itself.
        for (d.params) |p| if (p.is_vararg or p.default != null) return;
        if (rule.not_suspend and d.is_suspend) return self.inapplicableOperator(at, "must not be suspend");
        if (rule.count) |c| if (np != c) {
            return switch (c) {
                0 => self.inapplicableOperator(at, "must have no value parameters"),
                1 => self.inapplicableOperator(at, "must have a single value parameter"),
                else => self.report(at, .INAPPLICABLE_OPERATOR_MODIFIER, "'operator' modifier is not applicable to function: must have {d} value parameters.", .{c}),
            };
        };
        if (rule.at_least) |c| if (np < c) {
            return self.report(at, .INAPPLICABLE_OPERATOR_MODIFIER, "'operator' modifier is not applicable to function: must have at least {d} value parameter{s}.", .{ c, if (c == 1) "" else "s" });
        };
        if (rule.returns != .none) {
            const t = try headers.returnType(s, f);
            if (!s.types.isErr(t) and (s.types.classSym(t) != rule.returns or s.types.isNullable(t))) {
                return self.report(at, .INAPPLICABLE_OPERATOR_MODIFIER, "'operator' modifier is not applicable to function: must return '{s}'.", .{s.str(s.syms.name(rule.returns))});
            }
        }
    }

    fn inapplicableOperator(self: Checker, at: Span, why: []const u8) Allocator.Error!void {
        try self.report(at, .INAPPLICABLE_OPERATOR_MODIFIER, "'operator' modifier is not applicable to function: {s}.", .{why});
    }

    fn params(self: Checker, ps: []const ast.Param, inline_fn: bool) Allocator.Error!void {
        var varargs: usize = 0;
        for (ps) |p| {
            varargs += @intFromBool(p.is_vararg);
            if (p.is_crossinline and p.is_noinline) try self.incompatible(p.span, "crossinline", "noinline");
            if (!inline_fn and (p.is_crossinline or p.is_noinline)) {
                try self.report(p.span, .ILLEGAL_INLINE_PARAMETER_MODIFIER, "Modifier is only allowed for function parameters of an inline function.", .{});
            }
        }
        if (varargs < 2) return;
        for (ps) |p| if (p.is_vararg) try self.report(p.span, .MULTIPLE_VARARG_PARAMETERS, "Multiple vararg parameters are prohibited.", .{});
    }

    // --------------------------------------------------------- properties --

    fn property(self: Checker, p: Sym, d: *const ast.Property) Allocator.Error!void {
        const s = self.s;
        const at = d.name.span;
        const member = isMember(s, p);
        if (d.visibility == .Private and member) {
            if (d.is_override) try self.incompatible(at, "private", "override");
            if (d.is_open) try self.incompatible(at, "private", "open");
            if (d.is_abstract) try self.incompatible(at, "private", "abstract");
        }
        if (d.is_const) {
            if (d.is_abstract) try self.incompatible(at, "const", "abstract");
            if (d.is_open) try self.incompatible(at, "const", "open");
            if (d.is_override) try self.incompatible(at, "const", "override");
        }
        if (member) try self.overrides(p, d.is_override, at);
        if (d.ty == null and d.visibility != .Private and !isLocalDecl(s, p)) {
            if (d.init) |e| try self.escapingAnonymous(at, e);
        }
        if (d.is_lateinit) try self.lateinit(p, d);
        if (d.is_const and !d.mutable) try self.constVal(p, d);
        if (d.receiver_type != null) {
            if (d.init) |e| {
                try self.report(e.span(), .EXTENSION_PROPERTY_WITH_BACKING_FIELD, "Extension property cannot be initialized because it has no backing field.", .{});
            } else if (d.delegate == null and s.syms.flags(p).modality != .abstract and !inExpect(s, p) and !external(s, p) and
                (d.getter == null or (d.mutable and d.setter == null)))
            {
                try self.report(at, .EXTENSION_PROPERTY_MUST_HAVE_ACCESSORS_OR_BE_ABSTRACT, "Extension property must have accessors or be abstract.", .{});
            }
            return;
        }
        if (d.explicit_field) |field| try self.explicitField(p, d, field, member);
        if (d.delegate != null or s.syms.flags(p).modality == .abstract or inExpect(s, p) or d.explicit_field != null) return;
        const in_interface = member and s.syms.classInfo(s.syms.owner(p)).kind == .interface;
        if (in_interface) return;
        if (inlineProperty(d) and hasBackingField(d)) {
            try self.report(at, .INLINE_PROPERTY_WITH_BACKING_FIELD, "Inline property cannot have a backing field.", .{});
            return;
        }
        if (d.init) |e| {
            if (!hasBackingField(d)) try self.report(e.span(), .PROPERTY_INITIALIZER_NO_BACKING_FIELD, "Initializer is prohibited here because this property has no backing field.", .{});
        }
    }

    /// A property that declares its backing field (`field: T = ...`): a
    /// final, non-private `val` of a class, without accessors or a
    /// delegate, whose field's type is a strict subtype of its own and is
    /// initialized.
    fn explicitField(self: Checker, p: Sym, d: *const ast.Property, field: *const ast.ExplicitField, member: bool) Allocator.Error!void {
        const s = self.s;
        const at = field.span;
        if (member and s.syms.classInfo(s.syms.owner(p)).kind == .interface) {
            return self.report(at, .EXPLICIT_BACKING_FIELD_IN_INTERFACE, "Backing fields inside interfaces are prohibited.", .{});
        }
        if (d.delegate != null) {
            return self.report(at, .BACKING_FIELD_FOR_DELEGATED_PROPERTY, "Delegated properties cannot have explicit backing field declarations.", .{});
        }
        if (d.mutable) try self.report(at, .VAR_PROPERTY_WITH_EXPLICIT_BACKING_FIELD, "Only 'val' properties with explicit backing fields are supported.", .{});
        if (d.getter != null or d.setter != null) try self.report(at, .PROPERTY_WITH_EXPLICIT_FIELD_AND_ACCESSORS, "Properties with explicit backing fields cannot have accessors.", .{});
        if (s.syms.flags(p).modality != .final) try self.report(at, .NON_FINAL_PROPERTY_WITH_EXPLICIT_BACKING_FIELD, "Properties with explicit backing fields must be final.", .{});
        if (d.visibility == .Private) try self.report(at, .EXPLICIT_FIELD_VISIBILITY_MUST_BE_LESS_PERMISSIVE, "Private properties cannot have explicit backing fields.", .{});
        if (field.init == null and !assignedInClass(s, p, d.name.name)) {
            try self.report(at, .EXPLICIT_FIELD_MUST_BE_INITIALIZED, "Field must be initialized.", .{});
        }
        const own = try headers.propertyType(s, p);
        const field_t = s.syms.propertyInfo(p).field_ty;
        if (!self.comparable(own, field_t)) return;
        if (!try subtyping.isSubtype(s, field_t, own)) {
            try self.report(at, .INCONSISTENT_BACKING_FIELD_TYPE, "The type of the backing field must be a subtype of the property's type.", .{});
        } else if (try subtyping.isSubtype(s, own, field_t)) {
            try self.warn(at, .REDUNDANT_EXPLICIT_BACKING_FIELD, "Explicit backing field declaration is unnecessary if it has the same type as the property.", .{});
        }
    }

    /// A declaration seen outside its file whose type is inferred as an
    /// object expression's: the type stands for its one supertype, and
    /// with several there is none to pick.
    fn escapingAnonymous(self: Checker, at: Span, e: *const ast.Expr) Allocator.Error!void {
        const s = self.s;
        const o = switch (e.*) {
            .ObjectExpr => |o| o,
            else => return,
        };
        var cls: Sym = .none;
        for (s.refs.items) |r| {
            if (r.kind == .decl and r.file == self.file and r.anchor.start == o.span.start and r.anchor.end == o.span.end) cls = r.target;
        }
        if (cls == .none or s.syms.kind(cls) != .class or s.syms.classInfo(cls).kind != .anonymous) return;
        var n: usize = 0;
        for (try headers.supertypes(s, cls)) |st| {
            if (s.types.classSym(st) != s.builtins.any) n += 1;
        }
        if (n > 1) try self.report(at, .AMBIGUOUS_ANONYMOUS_TYPE_INFERRED, "Right-hand side has an anonymous type. Specify the type explicitly.", .{});
    }

    // ---------------------------------------------------------- overrides --

    /// What a member declared `override` (or overriding without it, which
    /// `member_hidden` reports) must keep of the members it overrides: they
    /// are open, it is visible at least as widely, a function returns a
    /// subtype and is `suspend` exactly when they are, a property has a
    /// subtype (the same type, and is a `var`, over a `var`).
    fn overrides(self: Checker, m: Sym, written: bool, at: Span) Allocator.Error!void {
        const s = self.s;
        const cls = s.syms.owner(m);
        if (cls == .none or s.syms.kind(cls) != .class) return;
        if (inExpect(s, m)) return;
        const bases = try members.overridden(s, m);
        const name = s.str(s.syms.name(m));
        if (bases.len == 0) {
            if (written) try self.report(at, .NOTHING_TO_OVERRIDE, "'{s}' overrides nothing.", .{name});
            return;
        }
        if (!written) return;
        const mf = s.syms.flags(m);
        for (bases) |b| {
            const bf = s.syms.flags(b);
            const where = s.str(s.syms.name(s.syms.owner(b)));
            if (bf.modality == .final) {
                try self.report(at, .OVERRIDING_FINAL_MEMBER, "'{s}' in '{s}' is final and cannot be overridden.", .{ name, where });
            }
            const own_rank = visibilityRank(mf.visibility);
            const base_rank = visibilityRank(bf.visibility);
            if (own_rank < base_rank) {
                try self.report(at, .CANNOT_WEAKEN_ACCESS_PRIVILEGE, "Cannot weaken access privilege {s} for '{s}' in '{s}'.", .{ @tagName(mf.visibility), name, where });
            } else if (own_rank == base_rank and mf.visibility != bf.visibility) {
                try self.report(at, .CANNOT_CHANGE_ACCESS_PRIVILEGE, "Cannot change access privilege {s} for '{s}' in '{s}'.", .{ @tagName(mf.visibility), name, where });
            }
            const base_decl = try diagnose.declarationText(s, s.arena, b);
            switch (s.syms.kind(m)) {
                .function => {
                    if (mf.suspend_ and !bf.suspend_) {
                        try self.report(at, .NON_SUSPEND_OVERRIDDEN_BY_SUSPEND, "Suspend function '{s}' cannot override non-suspend function '{s}' defined in '{s}'.", .{ name, base_decl, where });
                    } else if (!mf.suspend_ and bf.suspend_) {
                        try self.report(at, .SUSPEND_OVERRIDDEN_BY_NON_SUSPEND, "Non-suspend function '{s}' cannot override suspend function '{s}' defined in '{s}'.", .{ name, base_decl, where });
                    }
                    // A generic function's type parameters would have to be
                    // matched to the base's first.
                    if (s.syms.functionInfo(m).type_params.len != 0 or s.syms.functionInfo(b).type_params.len != 0) continue;
                    const own = try headers.returnType(s, m);
                    const base = (try self.inherited(cls, b, try headers.returnType(s, b))) orelse continue;
                    if (!self.comparable(own, base)) continue;
                    if (!try subtyping.isSubtype(s, own, base)) {
                        try self.report(at, .RETURN_TYPE_MISMATCH_ON_OVERRIDE, "Return type of '{s}' is not a subtype of the return type of the overridden member '{s}' defined in '{s}'.", .{ try diagnose.declarationText(s, s.arena, m), base_decl, where });
                    }
                },
                .property => {
                    if (bf.mutable and !mf.mutable) {
                        try self.report(at, .VAR_OVERRIDDEN_BY_VAL, "'var' property '{s}' defined in '{s}' cannot be overridden by 'val' property '{s}'.", .{ base_decl, where, try diagnose.declarationText(s, s.arena, m) });
                        continue;
                    }
                    if (s.syms.propertyInfo(m).type_params.len != 0 or s.syms.propertyInfo(b).type_params.len != 0) continue;
                    const own = try headers.propertyType(s, m);
                    const base = (try self.inherited(cls, b, try headers.propertyType(s, b))) orelse continue;
                    if (!self.comparable(own, base)) continue;
                    if (bf.mutable) {
                        if (!try subtyping.isSubtype(s, own, base) or !try subtyping.isSubtype(s, base, own)) {
                            try self.report(at, .VAR_TYPE_MISMATCH_ON_OVERRIDE, "Type of '{s}' doesn't match the type of the overridden 'var' property '{s}' defined in '{s}'.", .{ try diagnose.declarationText(s, s.arena, m), base_decl, where });
                        }
                    } else if (!try subtyping.isSubtype(s, own, base)) {
                        try self.report(at, .PROPERTY_TYPE_MISMATCH_ON_OVERRIDE, "Type of '{s}' is not a subtype of the overridden property '{s}' defined in '{s}'.", .{ try diagnose.declarationText(s, s.arena, m), base_decl, where });
                    }
                },
                else => {},
            }
        }
    }

    /// `t`, a type of the supertype member `b`, as `cls` inherits it: with
    /// the arguments its supertypes give the declaring class's type
    /// parameters. Null when `b` is not found through them.
    fn inherited(self: Checker, cls: Sym, b: Sym, t: TypeId) Allocator.Error!?TypeId {
        const s = self.s;
        const want: members.Want = if (s.syms.kind(b) == .function) .function else .property;
        const self_subst = try subtyping.classSubst(s, try headers.selfType(s, cls));
        for (try headers.supertypes(s, cls)) |st_decl| {
            const st = try s.types.substitute(st_decl, &self_subst);
            for (try members.lookupEvery(s, st, s.syms.name(b), want)) |cand| {
                if (cand.sym == b) return try s.types.substitute(t, cand.subst);
            }
        }
        return null;
    }

    /// Whether two types are settled enough to compare: neither is an
    /// error, nor holds an inference variable.
    fn comparable(self: Checker, a: TypeId, b: TypeId) bool {
        const s = self.s;
        if (a == .none or b == .none or s.types.isErr(a) or s.types.isErr(b)) return false;
        return s.types.get(a) != .variable and s.types.get(b) != .variable;
    }

    fn lateinit(self: Checker, p: Sym, d: *const ast.Property) Allocator.Error!void {
        const s = self.s;
        const at = d.name.span;
        const factory: census.Factory = .INAPPLICABLE_LATEINIT_MODIFIER;
        if (!d.mutable) try self.report(at, factory, "'lateinit' modifier is allowed only on mutable properties.", .{});
        if (d.init != null) try self.report(at, factory, "'lateinit' modifier is not allowed on properties with initializer.", .{});
        if (d.delegate != null) try self.report(at, factory, "'lateinit' modifier is not allowed on delegated properties.", .{});
        if (d.is_abstract) try self.report(at, factory, "'lateinit' modifier is not allowed on abstract properties.", .{});
        if (d.receiver_type != null) try self.report(at, factory, "'lateinit' modifier is not allowed on extension properties.", .{});
        const t = try headers.propertyType(s, p);
        if (!s.types.isErr(t)) {
            if (try nullableBound(s, t)) {
                try self.report(at, factory, "'lateinit' modifier is not allowed on properties of a type with nullable upper bound.", .{});
            } else if (primitive(s, s.types.classSym(t)) and !s.types.isNullable(t)) {
                try self.report(at, factory, "'lateinit' modifier is not allowed on properties of primitive types.", .{});
            }
        }
        if (d.getter != null or d.setter != null) try self.report(at, factory, "'lateinit' modifier is not allowed on properties with a custom getter or setter.", .{});
    }

    fn constVal(self: Checker, p: Sym, d: *const ast.Property) Allocator.Error!void {
        const s = self.s;
        const owner = s.syms.owner(p);
        const placed = switch (s.syms.kind(owner)) {
            .package => true,
            .class => switch (s.syms.classInfo(owner).kind) {
                .object, .companion => true,
                else => false,
            },
            else => false,
        };
        if (!placed) {
            try self.report(d.name.span, .CONST_VAL_NOT_TOP_LEVEL_OR_OBJECT, "Const 'val' is only allowed on top level, in named objects, in companion objects or companion blocks.", .{});
        }
        if (d.getter != null) try self.report(d.name.span, .CONST_VAL_WITH_GETTER, "Const 'val' should not have a getter.", .{});
        if (d.delegate != null) {
            try self.report(d.name.span, .CONST_VAL_WITH_DELEGATE, "Const 'val' should not have a delegate.", .{});
            return;
        }
        const t = try headers.propertyType(s, p);
        if (!s.types.isErr(t)) {
            const cls = s.types.classSym(t);
            if (s.types.isNullable(t) or !(primitive(s, cls) or unsigned(s, cls) or cls == s.builtins.string)) {
                try self.report(d.span, .TYPE_CANT_BE_USED_FOR_CONST_VAL, "Const 'val' has type '{s}'. Only primitive types and 'String' are allowed.", .{try diagnose.typeText(s, s.arena, t)});
                return;
            }
        }
        const e = d.init orelse {
            if (d.getter == null) try self.report(d.name.span, .CONST_VAL_WITHOUT_INITIALIZER, "Const 'val' must have an initializer.", .{});
            return;
        };
        if (!try constant(s, self.file, e)) {
            try self.report(e.span(), .CONST_VAL_WITH_NON_CONST_INITIALIZER, "Const 'val' initializer must be a constant value.", .{});
        }
    }
};

/// Whether an init block of the class declaring `p` assigns the name `n`.
fn assignedInClass(s: *Sema, p: Sym, n: []const u8) bool {
    const owner = s.syms.owner(p);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    const c = switch (s.syms.get(owner).decl) {
        .class => |c| c.?,
        else => return true,
    };
    for (c.x().init_blocks) |*b| {
        if (assigns(ast.Block, b, n)) return true;
    }
    // A secondary constructor may assign it too.
    for (c.x().secondary_ctors) |*sc| {
        if (sc.body) |*b| if (assigns(ast.Block, b, n)) return true;
    }
    return false;
}

/// Whether an assignment anywhere in `v` writes the name `n`.
fn assigns(comptime T: type, v: *const T, n: []const u8) bool {
    if (T == ast.AssignStmt) {
        switch (v.target) {
            .Path => |pt| if (pt.segments.len == 1 and std.mem.eql(u8, pt.segments[0].name, n)) return true,
            .Member => |m| if (m.receiver.* == .This and std.mem.eql(u8, m.name.name, n)) return true,
            else => {},
        }
    }
    if (comptime plain(T)) return false;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |f| {
                if (assigns(f.type, &@field(v.*, f.name), n)) return true;
            }
            return false;
        },
        .@"union" => switch (v.*) {
            inline else => |*payload| return assigns(@TypeOf(payload.*), payload, n),
        },
        .optional => |o| return if (v.*) |*x| assigns(o.child, x, n) else false,
        .pointer => |pt| switch (pt.size) {
            .one => return assigns(pt.child, v.*, n),
            .slice => {
                for (v.*) |*x| if (assigns(pt.child, x, n)) return true;
                return false;
            },
            else => @compileError("unexpected pointer in an AST node: " ++ @typeName(T)),
        },
        else => return false,
    }
}

/// How widely a visibility shows a member: `protected` and `internal`
/// are not ordered against each other.
fn visibilityRank(v: symbols.Visibility) u2 {
    return switch (v) {
        .private => 0,
        .protected, .internal => 1,
        .public => 2,
    };
}

fn oneOf(n: []const u8, names: []const []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

/// Whether an `inline` function has something inlining pays for: a
/// parameter of a non-null function type it may inline, or a reified type
/// parameter.
fn inlinesSomething(s: *Sema, f: Sym, d: *const ast.Function) Allocator.Error!bool {
    for (d.type_params) |tp| if (tp.is_reified) return true;
    try headers.functionHeader(s, f);
    for (s.syms.functionInfo(f).params, d.params) |p, ap| {
        if (ap.is_noinline) continue;
        const t = try headers.paramType(s, p);
        if (s.types.isErr(t)) return true;
        if (s.types.isNullable(t)) continue;
        if (@import("calls.zig").functionShape(s, t) != null) return true;
    }
    const recv = s.syms.functionInfo(f).receiver;
    if (recv != .none and !s.types.isNullable(recv) and @import("calls.zig").functionShape(s, recv) != null) return true;
    return false;
}

/// Declared in a body: a local function or property.
fn isLocalDecl(s: *Sema, sym: Sym) bool {
    const owner = s.syms.owner(sym);
    if (owner == .none) return false;
    return switch (s.syms.kind(owner)) {
        .package, .class => false,
        else => true,
    };
}

/// Whether `sym` is an `expect` declaration or declared in one: what an
/// `expect` class holds is `expect` too.
fn inExpect(s: *Sema, sym: Sym) bool {
    var cur = sym;
    while (cur != .none) : (cur = s.syms.owner(cur)) {
        switch (s.syms.kind(cur)) {
            .package => return false,
            .class, .function, .property => if (s.syms.flags(cur).expect) return true,
            else => {},
        }
    }
    return false;
}

/// Whether a file's declarations are checked: a program's, and under
/// `KLIO_CHECK_PACKS=1` a pack's too, which kotlinc compiled.
pub fn checked(fc: *const sema_mod.FileCtx) bool {
    if (fc.generated) return false;
    return fc.origin == .program or (fc.origin == .pack and checkPacks());
}

fn checkPacks() bool {
    const v = std.c.getenv("KLIO_CHECK_PACKS") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

/// Declared in a class's body rather than a package or a body.
fn isMember(s: *Sema, sym: Sym) bool {
    const owner = s.syms.owner(sym);
    return owner != .none and s.syms.kind(owner) == .class;
}

/// Declared in a function or lambda body, at any depth.
fn isLocal(s: *Sema, cls: Sym) bool {
    var cur = s.syms.owner(cls);
    while (cur != .none) : (cur = s.syms.owner(cur)) {
        switch (s.syms.kind(cur)) {
            .package => return false,
            .class => {},
            else => return true,
        }
    }
    return false;
}

fn external(s: *Sema, p: Sym) bool {
    if (s.syms.flags(p).external) return true;
    const owner = s.syms.owner(p);
    return owner != .none and s.syms.kind(owner) == .class and s.syms.flags(owner).external;
}

fn inlineProperty(d: *const ast.Property) bool {
    if (d.is_inline) return true;
    const g = d.getter orelse return false;
    if (!g.is_inline) return false;
    return !d.mutable or (if (d.setter) |st| st.is_inline else false);
}

/// Whether a property keeps a field: an accessor the language generates
/// reads or writes it, as does a written one that names `field`.
fn hasBackingField(d: *const ast.Property) bool {
    const g = d.getter orelse return true;
    if (mentionsField(g)) return true;
    if (!d.mutable) return false;
    const st = d.setter orelse return true;
    return mentionsField(st);
}

/// Whether an accessor's body names `field` anywhere, including in a
/// lambda or a string template.
fn mentionsField(a: *const ast.Accessor) bool {
    return mentions(ast.FunctionBody, &a.body, "field");
}

fn mentions(comptime T: type, v: *const T, name: []const u8) bool {
    if (T == ast.Expr) {
        switch (v.*) {
            .Path => |p| if (p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, name)) return true,
            else => {},
        }
    }
    if (T == ast.StringPart) {
        switch (v.*) {
            .ShortInterp => |id| return std.mem.eql(u8, id.name, name),
            else => {},
        }
    }
    if (comptime plain(T)) return false;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |f| {
                if (mentions(f.type, &@field(v.*, f.name), name)) return true;
            }
            return false;
        },
        .@"union" => switch (v.*) {
            inline else => |*payload| return mentions(@TypeOf(payload.*), payload, name),
        },
        .optional => |o| return if (v.*) |*x| mentions(o.child, x, name) else false,
        .pointer => |p| switch (p.size) {
            .one => return mentions(p.child, v.*, name),
            .slice => {
                for (v.*) |*x| if (mentions(p.child, x, name)) return true;
                return false;
            },
            else => @compileError("unexpected pointer in an AST node: " ++ @typeName(T)),
        },
        else => return false,
    }
}

/// A type that holds no expression.
fn plain(comptime T: type) bool {
    if (T == span.Span or T == ast.Ident or T == ast.NodeId or T == ast.TypeRef or T == ast.Annotation) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => true,
        .optional => |o| plain(o.child),
        .pointer => |p| p.size == .slice and plain(p.child),
        else => false,
    };
}

pub fn primitive(s: *Sema, cls: Sym) bool {
    if (cls == .none) return false;
    const b = s.builtins;
    return cls == b.int or cls == b.long or cls == b.short or cls == b.byte or
        cls == b.float or cls == b.double or cls == b.char or cls == b.boolean;
}

pub fn unsigned(s: *Sema, cls: Sym) bool {
    if (cls == .none) return false;
    const b = s.builtins;
    return cls == b.uint or cls == b.ulong or cls == b.ushort or cls == b.ubyte;
}

/// Whether null is among a type's values: it is nullable, or a type
/// parameter one of whose bounds is.
fn nullableBound(s: *Sema, t: TypeId) Allocator.Error!bool {
    if (s.types.isNullable(t)) return true;
    return switch (s.types.get(t)) {
        .param => |pt| blk: {
            const bounds = try headers.typeParamBounds(s, pt.sym);
            if (bounds.len == 0) break :blk true;
            for (bounds) |b| if (!try nullableBound(s, b)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Whether an expression is a compile-time constant as far as its syntax
/// and what its names resolved to tell: literals, `const val`s and the
/// operators and conversions on them. Anything else it cannot rule out
/// answers true, so only a definite non-constant is reported.
pub fn constant(s: *Sema, file: u32, e: *const ast.Expr) Allocator.Error!bool {
    return switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit, .NullLit => true,
        .StringTemplate => |t| blk: {
            for (t.parts) |part| switch (part) {
                .Text => {},
                .ShortInterp => |id| if (!try constName(s, file, id.span)) break :blk false,
                .Interp => |ie| if (!try constant(s, file, ie)) break :blk false,
            };
            break :blk true;
        },
        .Path => |p| constName(s, file, pathAnchor(s, file, p.span, p.segments)),
        .Member => |m| (try constant(s, file, m.receiver)) and try constName(s, file, m.name.span),
        .Binary => |b| (try constant(s, file, b.lhs)) and try constant(s, file, b.rhs),
        .Unary => |u| constant(s, file, u.expr),
        .Call => |c| blk: {
            // A conversion or an infix operator on constants
            // (`1.toLong()`, `1 shl 2`) is constant; any other call is not.
            const callee = c.callee;
            switch (callee.*) {
                .Member => |m| {
                    if (!try constant(s, file, m.receiver)) break :blk false;
                    for (c.args) |*a| if (!try constant(s, file, a)) break :blk false;
                    break :blk intrinsic(s, try refTarget(s, file, m.name.span));
                },
                .Path => |p| {
                    if (c.is_infix and c.args.len == 2) {
                        for (c.args) |*a| if (!try constant(s, file, a)) break :blk false;
                        break :blk intrinsic(s, try refTarget(s, file, pathAnchor(s, file, p.span, p.segments)));
                    }
                    break :blk false;
                },
                else => break :blk true,
            }
        },
        .Lambda, .ObjectExpr, .AnonFun => false,
        else => true,
    };
}

/// Whether the name at `sp` names a `const val`, or what the analysis does
/// not know.
fn constName(s: *Sema, file: u32, sp: Span) Allocator.Error!bool {
    const target = try refTarget(s, file, sp);
    if (target == .none) return true;
    return switch (s.syms.kind(target)) {
        .property => s.syms.flags(target).const_ or constEvaluated(s, target),
        .local, .value_param => false,
        // An enum entry is not a constant of a `const val`.
        .enum_entry => false,
        else => true,
    };
}

/// A member of a builtin number, character, boolean or string class, or a
/// declaration the stdlib marks `@IntrinsicConstEvaluation` (`Char.code`):
/// it folds at compile time.
fn intrinsic(s: *Sema, target: Sym) bool {
    if (target == .none) return true;
    const owner = s.syms.owner(target);
    if (primitive(s, owner) or unsigned(s, owner) or owner == s.builtins.string) return true;
    return constEvaluated(s, target);
}

fn constEvaluated(s: *Sema, target: Sym) bool {
    return switch (s.syms.kind(target)) {
        .function, .property => s.syms.flags(target).intrinsic_const,
        else => false,
    };
}

/// Where a name's reference is anchored: the path, or its last segment.
pub fn pathAnchor(s: *Sema, file: u32, whole: Span, segments: []const ast.Ident) Span {
    if (segments.len == 0) return whole;
    for (s.refs.items) |r| {
        if (r.file == file and r.anchor.start == whole.start and r.anchor.end == whole.end) return whole;
    }
    return segments[segments.len - 1].span;
}

/// The declaration the reference anchored at `sp` resolved to.
pub fn refTarget(s: *Sema, file: u32, sp: Span) Allocator.Error!Sym {
    for (s.refs.items) |r| {
        if (r.file == file and r.anchor.start == sp.start and r.anchor.end == sp.end and r.anchor.file.int() == sp.file.int()) return r.target;
    }
    return .none;
}
