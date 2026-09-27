//! Text for types and symbols: census details, the class inspector and the
//! oracle dump. Callable ids follow kotlinc's `CallableId` rendering,
//! `package/path/Class.name`, so the dump compares against the oracle.

const std = @import("std");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const records = @import("records.zig");
const names_mod = @import("names.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;

pub fn typeStr(s: *Sema, a: Allocator, t: TypeId) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try writeType(s, a, &buf, t);
    return buf.items;
}

pub fn writeType(s: *Sema, a: Allocator, buf: *std.ArrayList(u8), t: TypeId) Allocator.Error!void {
    switch (s.types.get(t)) {
        .none => try buf.appendSlice(a, "<none>"),
        .err => try buf.appendSlice(a, "<error>"),
        .variable => |v| try buf.print(a, "?{d}{s}", .{ v.id, if (v.nullable) "?" else if (v.dnn) " & Any" else "" }),
        .int_lit => try buf.appendSlice(a, "<integer literal>"),
        .param => |p| {
            try buf.appendSlice(a, s.str(s.syms.name(p.sym)));
            if (p.dnn) try buf.appendSlice(a, " & Any");
            if (p.nullable) try buf.append(a, '?');
        },
        .intersection => |parts| {
            for (parts, 0..) |p, i| {
                if (i != 0) try buf.appendSlice(a, " & ");
                try writeType(s, a, buf, p);
            }
        },
        .class => |c| {
            try buf.appendSlice(a, s.str(s.syms.classInfo(c.sym).fqn));
            if (c.args.len != 0) {
                try buf.append(a, '<');
                for (c.args, 0..) |arg, i| {
                    if (i != 0) try buf.appendSlice(a, ", ");
                    switch (arg.variance) {
                        .star => {
                            try buf.append(a, '*');
                            continue;
                        },
                        .in => try buf.appendSlice(a, "in "),
                        .out => try buf.appendSlice(a, "out "),
                        .inv => {},
                    }
                    try writeType(s, a, buf, arg.ty);
                }
                try buf.append(a, '>');
            }
            if (c.nullable) try buf.append(a, '?');
        },
    }
}

/// `kotlin/collections` for the package of `sym`.
pub fn packagePath(s: *Sema, a: Allocator, sym: Sym) Allocator.Error![]const u8 {
    const pkg = s.syms.packageOf(sym);
    if (pkg == .none) return "";
    const fqn = s.str(s.syms.packageInfo(pkg).fqn);
    const out = try a.dupe(u8, fqn);
    for (out) |*ch| {
        if (ch.* == '.') ch.* = '/';
    }
    return out;
}

/// The class path of a class symbol relative to its package, dotted:
/// `Map.Entry`.
pub fn classPath(s: *Sema, a: Allocator, cls: Sym) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var cur = cls;
    while (cur != .none and s.syms.kind(cur) == .class) {
        try parts.append(a, s.str(s.syms.name(cur)));
        cur = s.syms.owner(cur);
    }
    var buf: std.ArrayList(u8) = .empty;
    var i = parts.items.len;
    while (i > 0) {
        i -= 1;
        try buf.appendSlice(a, parts.items[i]);
        if (i != 0) try buf.append(a, '.');
    }
    return buf.items;
}

/// A ClassId as kotlinc renders it: `kotlin/collections/Map.Entry`.
pub fn classId(s: *Sema, a: Allocator, cls: Sym) Allocator.Error![]const u8 {
    const pkg = try packagePath(s, a, cls);
    const path = try classPath(s, a, cls);
    if (pkg.len == 0) return path;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ pkg, path });
}

/// A CallableId as kotlinc renders it: `kotlin/collections/List.get` for a
/// member, `kotlin/io/println` for a top-level function, `.<init>` for a
/// constructor.
pub fn callableId(s: *Sema, a: Allocator, sym: Sym) Allocator.Error![]const u8 {
    const owner_cls = s.syms.enclosingClass(sym);
    const pkg = try packagePath(s, a, sym);
    const simple = s.str(s.syms.name(sym));
    if (owner_cls != .none and s.syms.owner(sym) == owner_cls) {
        const path = try classPath(s, a, owner_cls);
        if (pkg.len == 0) return std.fmt.allocPrint(a, "{s}.{s}", .{ path, simple });
        return std.fmt.allocPrint(a, "{s}/{s}.{s}", .{ pkg, path, simple });
    }
    if (pkg.len == 0) return a.dupe(u8, simple);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ pkg, simple });
}

/// A type erased for signature comparison, as the oracle prints it; see
/// `Namer.erasedType`.
pub fn erasedType(s: *Sema, a: Allocator, t: TypeId) Allocator.Error![]const u8 {
    const n: Namer = .{ .s = s, .a = a };
    return n.erasedType(t);
}

// ------------------------------------------------------- oracle targets --

/// Names declarations the way kotlinc's FIR identifies them, for the oracle
/// dump (tools/sema-oracle): `pkg/Class.name|receiver|params` for
/// callables, `local:name@offset` for anything declared in a body,
/// `object:`/`enum:`/`field:` for classifiers used as values and backing
/// fields.
pub const Namer = struct {
    s: *Sema,
    a: Allocator,
    /// Moves a declaration's start, as the parser spans it, to where
    /// kotlinc's PSI starts it (modifiers, annotations and bound comments
    /// included). Identity when unset.
    decl_start: ?*const fn (ctx: *const anyopaque, sym: Sym, start: u32) u32 = null,
    ctx: *const anyopaque = undefined,

    /// Where a declaration starts in its file, or null for a declaration
    /// with no source.
    pub fn declOffset(self: Namer, sym: Sym) ?u32 {
        const start = parserStart(self.s, sym) orelse return null;
        const f = self.decl_start orelse return start;
        return f(self.ctx, sym, start);
    }

    /// A class as the oracle names it: its ClassId, or `local:Name@offset`
    /// for a local class (`local:<anonymous>@offset` for an object
    /// expression or an enum entry's body, which kotlinc models as an
    /// anonymous object).
    pub fn classSymbol(self: Namer, cls: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        if (!isLocalClass(s, cls)) return classId(s, self.a, cls);
        const info = s.syms.classInfo(cls);
        const anonymous = info.kind == .anonymous or info.kind == .enum_entry;
        const name = if (anonymous) "<anonymous>" else s.str(s.syms.name(cls));
        const off = self.declOffset(cls) orelse return std.fmt.allocPrint(self.a, "local:{s}@?", .{name});
        return std.fmt.allocPrint(self.a, "local:{s}@{d}", .{ name, off });
    }

    /// `local:name@offset` for a local, a parameter or a local function.
    pub fn localName(self: Namer, sym: Sym) Allocator.Error![]const u8 {
        const name = self.s.str(self.s.syms.name(sym));
        const off = self.declOffset(sym) orelse return std.fmt.allocPrint(self.a, "local:{s}@?", .{name});
        return std.fmt.allocPrint(self.a, "local:{s}@{d}", .{ name, off });
    }

    /// A callable's name with its owner, no signature: `pkg/Class.name`,
    /// `pkg/name`, `name` in the root package, `local:name@offset` in a body.
    pub fn callableName(self: Namer, sym_in: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        const sym = throughAccessor(s, sym_in);
        if (s.syms.kind(sym) != .constructor and isBodyLocal(s, sym)) return self.localName(sym);
        const simple = if (s.syms.kind(sym) == .constructor) "<init>" else s.str(s.syms.name(sym));
        const owner = s.syms.owner(sym);
        if (owner != .none and s.syms.kind(owner) == .class) {
            return std.fmt.allocPrint(self.a, "{s}.{s}", .{ try self.classSymbol(owner), simple });
        }
        const pkg = try packagePath(s, self.a, sym);
        if (pkg.len == 0) return self.a.dupe(u8, simple);
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ pkg, simple });
    }

    /// A type erased for signature comparison: a class type as its class, a
    /// type parameter by name, a trailing `?` when nullable, `T&Any` for a
    /// definitely non-null type and the parts of an intersection joined by
    /// `&`.
    pub fn erasedType(self: Namer, t: TypeId) Allocator.Error![]const u8 {
        const s = self.s;
        const a = self.a;
        return switch (s.types.get(t)) {
            .class => |c| std.fmt.allocPrint(a, "{s}{s}", .{ try self.classSymbol(c.sym), if (c.nullable) "?" else "" }),
            .param => |p| std.fmt.allocPrint(a, "{s}{s}{s}", .{ s.str(s.syms.name(p.sym)), if (p.dnn) "&Any" else "", if (p.nullable) "?" else "" }),
            .intersection => |parts| blk: {
                var buf: std.ArrayList(u8) = .empty;
                for (parts, 0..) |p, i| {
                    if (i != 0) try buf.append(a, '&');
                    try buf.appendSlice(a, try self.erasedType(p));
                }
                break :blk buf.items;
            },
            else => "<error>",
        };
    }

    /// The declared, erased signature the oracle appends to a callable:
    /// `|receiver|param,param`, `T...` for a vararg element.
    fn signature(self: Namer, sym: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        const a = self.a;
        var buf: std.ArrayList(u8) = .empty;
        try buf.append(a, '|');
        const recv = try headers.receiverType(s, sym);
        if (recv != .none) try buf.appendSlice(a, try self.erasedType(recv));
        try buf.append(a, '|');
        const kind = s.syms.kind(sym);
        if (kind == .function or kind == .constructor) {
            for (s.syms.functionInfo(sym).params, 0..) |p, i| {
                if (i != 0) try buf.append(a, ',');
                try buf.appendSlice(a, try self.erasedType(try headers.paramType(s, p)));
                if (s.syms.flags(p).vararg) try buf.appendSlice(a, "...");
            }
        }
        return buf.items;
    }

    /// The resolved declaration as the oracle's `target` column.
    pub fn target(self: Namer, sym_in: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        const a = self.a;
        const sym = throughAccessor(s, sym_in);
        switch (s.syms.kind(sym)) {
            .local, .value_param => {
                if (backingFieldOf(s, sym)) |prop| return std.fmt.allocPrint(a, "field:{s}", .{try self.callableName(prop)});
                return self.localName(sym);
            },
            .enum_entry => return std.fmt.allocPrint(a, "enum:{s}.{s}", .{ try self.classSymbol(s.syms.owner(sym)), s.str(s.syms.name(sym)) }),
            .class => return std.fmt.allocPrint(a, "object:{s}", .{try self.classSymbol(sym)}),
            .function, .property => {
                if (samInterface(s, sym)) |iface| return std.fmt.allocPrint(a, "sam:{s}", .{try self.classSymbol(iface)});
                if (isBodyLocal(s, sym)) return self.localName(sym);
                return std.fmt.allocPrint(a, "{s}{s}", .{ try self.callableName(sym), try self.signature(sym) });
            },
            .constructor => return std.fmt.allocPrint(a, "{s}{s}", .{ try self.callableName(sym), try self.signature(sym) }),
            .type_alias => return std.fmt.allocPrint(a, "alias:{s}", .{s.str(s.syms.name(sym))}),
            .package, .type_param => return std.fmt.allocPrint(a, "<{s}>", .{@tagName(s.syms.kind(sym))}),
        }
    }

    /// The implicit `this` of a class as the oracle prints a receiver:
    /// `obj@` for an object or companion, `this@` otherwise.
    pub fn classReceiver(self: Namer, cls: Sym) Allocator.Error![]const u8 {
        const s = self.s;
        if (cls == .none or s.syms.kind(cls) != .class) return "this@?";
        const k = s.syms.classInfo(cls).kind;
        const prefix = if (k == .object or k == .companion) "obj@" else "this@";
        return std.fmt.allocPrint(self.a, "{s}{s}", .{ prefix, try self.classSymbol(cls) });
    }

    /// Where a receiver comes from, as the oracle's `dispatch`/`extension`
    /// column.
    pub fn receiver(self: Namer, r: records.Receiver) Allocator.Error![]const u8 {
        const s = self.s;
        return switch (r) {
            .none => "-",
            .expr => "expr",
            .implicit => |imp| switch (imp.kind) {
                .class_this, .object => self.classReceiver(imp.owner),
                // An anonymous function with a receiver is a lambda to
                // kotlinc: `fun String.() { length }`.
                .extension => switch (s.syms.get(imp.owner).decl) {
                    .anon_fun, .lambda => std.fmt.allocPrint(self.a, "lambda@{d}", .{self.declOffset(imp.owner) orelse 0}),
                    else => std.fmt.allocPrint(self.a, "ext@{s}", .{try self.callableName(imp.owner)}),
                },
                .lambda => std.fmt.allocPrint(self.a, "lambda@{d}", .{self.declOffset(imp.owner) orelse 0}),
                .context => std.fmt.allocPrint(self.a, "ctx@{s}", .{s.str(s.syms.name(imp.owner))}),
                // kotlinc names `super` as an explicit receiver.
                .super_ => "expr",
            },
        };
    }
};

/// Where the parser starts a declaration: the byte offset of the first
/// token its span covers, or null for a declaration with no source.
pub fn parserStart(s: *Sema, sym: Sym) ?u32 {
    return switch (s.syms.get(sym).decl) {
        .none, .file => null,
        inline else => |d| if (d) |x| x.span.start else null,
    };
}

/// The property whose backing field `sym` is: the analysis declares
/// `field` as a local of the property's accessors, kotlinc as the
/// property's field.
pub fn backingFieldOf(s: *Sema, sym: Sym) ?Sym {
    if (s.syms.kind(sym) != .local or s.syms.name(sym) != names_mod.wk.field) return null;
    const owner = s.syms.owner(sym);
    if (owner == .none or s.syms.kind(owner) != .property) return null;
    return owner;
}

/// The fun interface whose SAM constructor `sym` is: the analysis declares
/// one function per interface, kotlinc names it `sam:<interface>`.
pub fn samInterface(s: *Sema, sym: Sym) ?Sym {
    if (s.syms.kind(sym) != .function or !s.syms.flags(sym).synthetic) return null;
    var it = s.sam_ctors.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == sym) return e.key_ptr.*;
    }
    return null;
}

/// Whether `sym` is `invoke` of a `kotlin.FunctionN` or
/// `kotlin.coroutines.SuspendFunctionN` class, which takes an extension
/// function type's receiver as its first parameter.
pub fn isFunctionInvoke(s: *Sema, sym: Sym) bool {
    if (s.syms.kind(sym) != .function or s.syms.name(sym) != names_mod.wk.invoke) return false;
    const owner = s.syms.owner(sym);
    if (owner == .none or s.syms.kind(owner) != .class) return false;
    const n: u32 = @intCast(s.syms.functionInfo(sym).params.len);
    return s.function_classes.get(n) == owner or s.suspend_function_classes.get(n) == owner;
}

/// Whether `member` is indexed under its name in `cls`'s declared members.
/// A function or class that a body declares while a class scope is the
/// innermost owner (an `init` block, a property initializer) is owned by
/// the class but not declared by it.
fn declaredBy(s: *Sema, cls: Sym, member: Sym) bool {
    const n = s.syms.name(member);
    for (symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
        if (m == member) return true;
    }
    return false;
}

/// Declared in a body rather than in a package or a class: kotlinc names it
/// by its declaration offset.
pub fn isBodyLocal(s: *Sema, sym: Sym) bool {
    switch (s.syms.kind(sym)) {
        .local, .value_param => return true,
        .package => return false,
        else => {},
    }
    const owner = s.syms.owner(sym);
    if (owner == .none) return s.syms.get(sym).file != symbols.NO_FILE;
    return switch (s.syms.kind(owner)) {
        .package => false,
        .class => if (s.syms.kind(sym) == .constructor) false else !declaredBy(s, owner, sym),
        else => true,
    };
}

/// A class kotlinc identifies by its declaration offset: a local class, an
/// object expression, an enum entry's body, or a class nested in one.
pub fn isLocalClass(s: *Sema, cls: Sym) bool {
    var cur = cls;
    while (cur != .none and s.syms.kind(cur) == .class) {
        const k = s.syms.classInfo(cur).kind;
        if (k == .anonymous or k == .enum_entry) return true;
        if (isBodyLocal(s, cur)) return true;
        cur = s.syms.owner(cur);
    }
    return false;
}

/// The property an accessor belongs to, else `sym` itself.
fn throughAccessor(s: *Sema, sym: Sym) Sym {
    if (s.syms.kind(sym) != .function) return sym;
    const p = s.syms.functionInfo(sym).property;
    return if (p != .none) p else sym;
}
