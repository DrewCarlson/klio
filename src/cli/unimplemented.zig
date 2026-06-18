//! Ahead-of-time "missing implementation" check.
//!
//! Many silent-`Unit` runtime bugs trace to the same shape: an upstream
//! `expect` declaration (or a bodyless `external`) that klio loads but for
//! which no `actual` Kotlin body and no host intrinsic exist. The call
//! resolves, runs nothing, and returns `Unit` — there is no diagnostic.
//!
//! This check loads the program together with every pack it imports and the
//! embedded stdlib, walks all declarations, and reports each `expect`
//! function / property that has neither a body-carrying counterpart (a
//! Kotlin `actual`) nor a registered klio intrinsic backing its FQN. It is
//! the static analogue of the runtime failure mode.

const std = @import("std");

const span = @import("span");
const SourceMap = span.SourceMap;
const Span = span.Span;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Function = ast.Function;
const Property = ast.Property;

const lexer = @import("lexer");
const Lexer = lexer.Lexer;

const parser = @import("parser");
const Parser = parser.Parser;

const io = @import("io.zig");

const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;
const loadInstalledPacks = pack_cache.loadInstalledPacks;
const mergedHostBindings = pack_cache.mergedHostBindings;

/// One unimplemented `expect` declaration awaiting an actual / intrinsic.
const Missing = struct {
    /// `fun` or `val`/`var`.
    kind: []const u8,
    /// Best-effort fully qualified display name (`pkg.Owner.name`).
    display: []const u8,
    file: []const u8,
    line: u32,
};

/// Strip generic args and package qualifier from a type/owner name:
/// `kotlin.collections.List<T>` -> `List`.
fn simpleName(allocator: std.mem.Allocator, n: []const u8) []const u8 {
    const base = if (std.mem.indexOfScalar(u8, n, '<')) |lt| n[0..lt] else n;
    const tail = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[dot + 1 ..] else base;
    const trimmed = std.mem.trim(u8, tail, " \t\r\n");
    return allocator.dupe(u8, trimmed) catch trimmed;
}

/// The owner used to key a declaration: an extension's receiver type if
/// present, else the lexically enclosing class/object (`null` = top level).
fn fnOwner(allocator: std.mem.Allocator, f: *const Function, enclosing: ?[]const u8) ?[]const u8 {
    if (f.receiver_type) |t| return simpleName(allocator, t.name.name);
    if (enclosing) |e| return allocator.dupe(u8, e) catch e;
    return null;
}

fn propOwner(allocator: std.mem.Allocator, p: *const Property, enclosing: ?[]const u8) ?[]const u8 {
    if (p.receiver_type) |t| return simpleName(allocator, t.name.name);
    if (enclosing) |e| return allocator.dupe(u8, e) catch e;
    return null;
}

/// `owner#name` (owner empty for a top-level entity) — the key used to
/// decide whether a body-carrying counterpart exists for an `expect`.
fn implKey(allocator: std.mem.Allocator, owner: ?[]const u8, name: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}#{s}", .{ owner orelse "", name }) catch name;
}

const ExpectDecl = struct {
    kind: []const u8,
    pkg: []const u8,
    owner: ?[]const u8,
    name: []const u8,
    span: Span,
};

const Scan = struct {
    allocator: std.mem.Allocator,
    /// Keys (`owner#name`) that have a body somewhere — a Kotlin `actual`
    /// (or a plain definition) the `expect` can bind to.
    implemented: std.StringHashMap(void),
    /// `expect`s discovered, paired with their owner + package context.
    expects: std.ArrayList(ExpectDecl),

    fn init(allocator: std.mem.Allocator) Scan {
        return .{
            .allocator = allocator,
            .implemented = std.StringHashMap(void).init(allocator),
            .expects = .empty,
        };
    }

    fn deinit(self: *Scan) void {
        self.implemented.deinit();
        self.expects.deinit(self.allocator);
    }

    fn walk(
        self: *Scan,
        decls: []const Decl,
        pkg: []const u8,
        enclosing: ?[]const u8,
        in_abstract_owner: bool,
    ) void {
        for (decls) |*d| {
            switch (d.*) {
                .Function => |*f| {
                    const owner = fnOwner(self.allocator, f, enclosing);
                    if (f.body != null or f.is_actual) {
                        self.implemented.put(implKey(self.allocator, owner, f.name.name), {}) catch {};
                    }
                    // An `expect` (never a body) with no actual/intrinsic is
                    // the target. Abstract members and interface methods are
                    // overridden, not implemented here — skip them.
                    if (f.is_expect and !f.is_abstract and !in_abstract_owner) {
                        self.expects.append(self.allocator, .{
                            .kind = "fun",
                            .pkg = pkg,
                            .owner = owner,
                            .name = f.name.name,
                            .span = f.span,
                        }) catch {};
                    }
                },
                .Property => |p| {
                    const owner = propOwner(self.allocator, p, enclosing);
                    const has_body =
                        p.init != null or p.delegate != null or p.getter != null;
                    if (has_body) {
                        self.implemented.put(implKey(self.allocator, owner, p.name.name), {}) catch {};
                    }
                    if (p.is_expect and !p.is_abstract and !in_abstract_owner) {
                        self.expects.append(self.allocator, .{
                            .kind = "val",
                            .pkg = pkg,
                            .owner = owner,
                            .name = p.name.name,
                            .span = p.span,
                        }) catch {};
                    }
                },
                .Class => |*c| {
                    // Members of an interface / abstract class are dispatched
                    // through overrides, so an absent body there is expected.
                    const abstract_owner = c.is_interface or c.is_abstract;
                    self.walk(c.members, pkg, c.name.name, abstract_owner);
                },
                .Object => |*o| {
                    self.walk(o.members, pkg, o.name.name, false);
                },
                .TypeAlias => {},
            }
        }
    }
};

/// Member names the interpreter resolves directly in `Vm::call_member`
/// (hardcoded arms), not through the binding table — so an `expect` for one
/// is already served and must not be reported. Mirrors the `("name", arity)`
/// arms in `klio-interp-ir`'s `host_call_member.rs`; kept here as an explicit
/// list since those arms are not otherwise enumerable.
const INTERP_BUILTIN_MEMBERS = [_][]const u8{
    // Reified enum reflection, resolved in `call_func_typed` (not a binding).
    "enumValues",
    "enumValueOf",
    "asList",
    "constrainOnce",
    "containsValue",
    "distinct",
    "distinctBy",
    "drop",
    "dropWhile",
    "equals",
    "filter",
    "filterIndexed",
    "filterNot",
    "flatMap",
    "hashCode",
    "map",
    "mapIndexed",
    "notNull",
    "observable",
    "onEach",
    "sorted",
    "sortedBy",
    "sortedByDescending",
    "sortedDescending",
    "sortedWith",
    "take",
    "takeWhile",
    "toList",
    "toMutableList",
    "toSet",
    "toString",
    "toTypedArray",
};

fn isInterpBuiltinMember(name: []const u8) bool {
    for (INTERP_BUILTIN_MEMBERS) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}

const CANDIDATE_PREFIXES = [_][]const u8{
    "kotlin",
    "kotlin.collections",
    "kotlin.text",
    "kotlin.comparisons",
    "kotlin.math",
    "kotlin.io",
    "kotlin.io.encoding",
    "kotlin.ranges",
    "kotlin.sequences",
};

/// Candidate intrinsic FQNs for an `expect` — generous so a real binding
/// under any plausible package/owner spelling counts as implemented. The
/// returned slice and its elements are owned by `allocator`.
fn candidateFqns(
    allocator: std.mem.Allocator,
    pkg: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) std.mem.Allocator.Error![][]const u8 {
    var prefixes: std.ArrayList([]const u8) = .empty;
    defer prefixes.deinit(allocator);
    try prefixes.append(allocator, pkg);
    for (CANDIDATE_PREFIXES) |p| try prefixes.append(allocator, p);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (prefixes.items) |p| {
        if (owner) |o| {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ p, o, name }));
        } else {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ p, name }));
        }
    }
    // A bare `pkg.name` and `owner.name` fallback for unusual keyings.
    if (owner) |o| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ o, name }));
    }
    return out.toOwnedSlice(allocator);
}

/// `(owner, name)` pair used to key member / extension intrinsics.
const OwnerName = struct { owner: []const u8, name: []const u8 };

const OwnerNameContext = struct {
    pub fn hash(_: OwnerNameContext, k: OwnerName) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.owner);
        h.update(&[_]u8{0});
        h.update(k.name);
        return h.final();
    }
    pub fn eql(_: OwnerNameContext, a: OwnerName, b: OwnerName) bool {
        return std.mem.eql(u8, a.owner, b.owner) and std.mem.eql(u8, a.name, b.name);
    }
};

const OwnerNameSet = std.HashMap(OwnerName, void, OwnerNameContext, std.hash_map.default_max_load_percentage);

/// Display name `pkg.owner.name`, dropping empty segments. Owned by `allocator`.
fn displayName(
    allocator: std.mem.Allocator,
    pkg: []const u8,
    owner: ?[]const u8,
    name: []const u8,
) []const u8 {
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    if (pkg.len != 0) {
        parts[n] = pkg;
        n += 1;
    }
    const o = owner orelse "";
    if (o.len != 0) {
        parts[n] = o;
        n += 1;
    }
    parts[n] = name;
    n += 1;
    return std.mem.join(allocator, ".", parts[0..n]) catch name;
}

pub fn runCheckUnimplemented(
    gpa: std.mem.Allocator,
    files: []const []const u8,
    features: *const RequestedFeatures,
) u8 {
    if (files.len == 0) {
        io.writeStderr("usage: klio check --unimplemented <file.kt> [...]\n");
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = SourceMap.init(gpa);
    defer map.deinit();

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(gpa);
    for (files) |path| {
        const src = io.readFile(gpa, path) catch {
            io.printStderr(gpa, "error: cannot read {s}\n", .{path});
            return 2;
        };
        defer gpa.free(src);
        const id = map.add(path, src) catch return 2;
        const owned_src = map.get(id).source;
        var lx = Lexer.init(gpa, id, owned_src) catch return 2;
        var lexed = lx.tokenize() catch return 2;
        defer lexed.deinit(gpa);
        const p = Parser.new(gpa, id, owned_src, lexed.tokens);
        const file_ast = p.parseFile();
        user_asts.append(gpa, file_ast) catch return 2;
    }

    const loaded = loadInstalledPacks(gpa, user_asts.items, &map, features);
    const pack_asts = loaded.asts;

    var scan = Scan.init(arena);
    defer scan.deinit();
    for (pack_asts) |*f| scanFile(&scan, arena, f);
    for (user_asts.items) |*f| scanFile(&scan, arena, f);

    var bindings = mergedHostBindings(gpa);
    defer bindings.deinit();
    // Index every registered intrinsic by (owner, name) and by top-level
    // name. Intrinsics are keyed `pkg.Owner.name` (member / extension) or
    // `pkg.name` (top-level); matching against the real key set catches a
    // binding under any package spelling, far more reliably than guessing.
    var intrinsic_owner_name = OwnerNameSet.init(arena);
    defer intrinsic_owner_name.deinit();
    var intrinsic_top_name = std.StringHashMap(void).init(arena);
    defer intrinsic_top_name.deinit();
    {
        var it = bindings.table.iterator();
        while (it.next()) |entry| {
            const fqn = entry.key_ptr.*;
            const name = lastSegment(fqn) orelse continue;
            if (secondToLastSegment(fqn)) |prev| {
                // A capitalised preceding segment is a type owner; a
                // lowercase one is a package component (top-level fn).
                if (prev.len != 0 and std.ascii.isUpper(prev[0])) {
                    intrinsic_owner_name.put(.{ .owner = prev, .name = name }, {}) catch {};
                    continue;
                }
            }
            intrinsic_top_name.put(name, {}) catch {};
        }
    }

    var missing: std.ArrayList(Missing) = .empty;
    defer missing.deinit(arena);
    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    for (scan.expects.items) |*e| {
        // A Kotlin `actual` / body for this owner+name implements it.
        if (scan.implemented.contains(implKey(arena, e.owner, e.name))) continue;
        // A registered host intrinsic under any candidate FQN implements it.
        const candidates = candidateFqns(arena, e.pkg, e.owner, e.name) catch return 2;
        var served = false;
        for (candidates) |fqn| {
            if (bindings.resolve(fqn) != null) {
                served = true;
                break;
            }
        }
        if (served) continue;
        // …or one indexed by (owner, name). A top-level intrinsic of the
        // same name also serves an extension (`kotlin.math.absoluteValue`
        // backs the `Double.absoluteValue` property), so accept that too.
        if (e.owner) |o| {
            if (intrinsic_owner_name.contains(.{ .owner = o, .name = e.name })) continue;
        }
        if (intrinsic_top_name.contains(e.name)) continue;
        // …or a core interpreter builtin serves it directly.
        if (isInterpBuiltinMember(e.name)) continue;

        const display = displayName(arena, e.pkg, e.owner, e.name);
        // Collapse overload sets / duplicate expects to one line.
        const gop = seen.getOrPut(display) catch return 2;
        if (gop.found_existing) continue;

        const sf = map.get(e.span.file);
        const file = arena.dupe(u8, sf.path) catch sf.path;
        const line = sf.lineCol(e.span.start).line;
        missing.append(arena, .{
            .kind = e.kind,
            .display = display,
            .file = file,
            .line = line,
        }) catch return 2;
    }

    if (missing.items.len == 0) {
        io.writeStdout("no unimplemented expect declarations reachable from the program\n");
        return 0;
    }

    // Order primarily by package prefix (everything before the last `.`),
    // then by full display name. This reproduces the
    // BTreeMap<pkg, Vec<&Missing>> grouping the Rust builds from a
    // display-sorted list: packages in sorted order, and each package's
    // entries in display order.
    std.mem.sort(Missing, missing.items, {}, missingPkgLessThan);

    io.printStdout(
        gpa,
        "{d} expect declaration(s) have no actual or intrinsic (would return Unit at runtime):\n\n",
        .{missing.items.len},
    );
    var current_pkg: ?[]const u8 = null;
    for (missing.items) |*m| {
        const pkg = displayPkg(m.display);
        if (current_pkg == null or !std.mem.eql(u8, current_pkg.?, pkg)) {
            io.printStdout(gpa, "  {s}\n", .{pkg});
            current_pkg = pkg;
        }
        io.printStdout(gpa, "    {s} {s}  ({s}:{d})\n", .{ m.kind, m.display, m.file, m.line });
    }
    return 1;
}

fn scanFile(scan: *Scan, arena: std.mem.Allocator, f: *const KotlinFile) void {
    const pkg = packageName(arena, f);
    scan.walk(f.decls, pkg, null, false);
}

/// Join a file's package path segments with `.` (empty when no header).
fn packageName(arena: std.mem.Allocator, f: *const KotlinFile) []const u8 {
    const header = f.package orelse return "";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    for (header.path) |seg| parts.append(arena, seg.name) catch return "";
    return std.mem.join(arena, ".", parts.items) catch "";
}

/// Last `.`-delimited segment of an FQN, mirroring `rsplit('.').next()`.
fn lastSegment(fqn: []const u8) ?[]const u8 {
    if (fqn.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| return fqn[dot + 1 ..];
    return fqn;
}

/// Second-to-last `.`-delimited segment, mirroring `rsplit('.').nth(1)`.
fn secondToLastSegment(fqn: []const u8) ?[]const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return null;
    const head = fqn[0..last_dot];
    if (std.mem.lastIndexOfScalar(u8, head, '.')) |prev_dot| return head[prev_dot + 1 ..];
    return head;
}

/// Package prefix of a display name: everything before the final `.`,
/// or `""` for a top-level entity.
fn displayPkg(display: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, display, '.')) |dot| return display[0..dot];
    return "";
}

fn missingPkgLessThan(_: void, a: Missing, b: Missing) bool {
    const pa = displayPkg(a.display);
    const pb = displayPkg(b.display);
    return switch (std.mem.order(u8, pa, pb)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.display, b.display),
    };
}

test "simpleName strips generics and qualifier" {
    const a = std.testing.allocator;
    {
        const s = simpleName(a, "kotlin.collections.List<T>");
        defer a.free(s);
        try std.testing.expectEqualStrings("List", s);
    }
    {
        const s = simpleName(a, "  Foo  ");
        defer a.free(s);
        try std.testing.expectEqualStrings("Foo", s);
    }
    {
        const s = simpleName(a, "Bar");
        defer a.free(s);
        try std.testing.expectEqualStrings("Bar", s);
    }
}

test "implKey formats owner#name" {
    const a = std.testing.allocator;
    {
        const k = implKey(a, "Foo", "bar");
        defer a.free(k);
        try std.testing.expectEqualStrings("Foo#bar", k);
    }
    {
        const k = implKey(a, null, "bar");
        defer a.free(k);
        try std.testing.expectEqualStrings("#bar", k);
    }
}

test "candidateFqns covers prefixes and fallbacks" {
    const a = std.testing.allocator;
    const owned = try candidateFqns(a, "my.pkg", "Foo", "bar");
    defer {
        for (owned) |s| a.free(s);
        a.free(owned);
    }
    // pkg + 9 builtin prefixes = 10 owner-qualified, plus owner.name fallback.
    try std.testing.expectEqual(@as(usize, CANDIDATE_PREFIXES.len + 2), owned.len);
    try std.testing.expectEqualStrings("my.pkg.Foo.bar", owned[0]);
    try std.testing.expectEqualStrings("kotlin.Foo.bar", owned[1]);
    try std.testing.expectEqualStrings("Foo.bar", owned[owned.len - 1]);

    const top = try candidateFqns(a, "my.pkg", null, "baz");
    defer {
        for (top) |s| a.free(s);
        a.free(top);
    }
    try std.testing.expectEqual(@as(usize, CANDIDATE_PREFIXES.len + 1), top.len);
    try std.testing.expectEqualStrings("my.pkg.baz", top[0]);
    try std.testing.expectEqualStrings("kotlin.baz", top[1]);
}

test "displayName drops empty segments" {
    const a = std.testing.allocator;
    {
        const d = displayName(a, "kotlin.math", "Double", "absoluteValue");
        defer a.free(d);
        try std.testing.expectEqualStrings("kotlin.math.Double.absoluteValue", d);
    }
    {
        const d = displayName(a, "", null, "println");
        defer a.free(d);
        try std.testing.expectEqualStrings("println", d);
    }
    {
        const d = displayName(a, "pkg", null, "f");
        defer a.free(d);
        try std.testing.expectEqualStrings("pkg.f", d);
    }
}

test "lastSegment and secondToLastSegment" {
    try std.testing.expectEqualStrings("name", lastSegment("a.b.name").?);
    try std.testing.expectEqualStrings("only", lastSegment("only").?);
    try std.testing.expect(lastSegment("") == null);
    try std.testing.expectEqualStrings("b", secondToLastSegment("a.b.name").?);
    try std.testing.expectEqualStrings("a", secondToLastSegment("a.name").?);
    try std.testing.expect(secondToLastSegment("name") == null);
}

test "isInterpBuiltinMember matches known members" {
    try std.testing.expect(isInterpBuiltinMember("map"));
    try std.testing.expect(isInterpBuiltinMember("enumValues"));
    try std.testing.expect(!isInterpBuiltinMember("notAMember"));
}

test "unimplemented usage check" {
    var feats = RequestedFeatures.init(std.testing.allocator);
    defer feats.deinit();
    try std.testing.expectEqual(@as(u8, 2), runCheckUnimplemented(std.testing.allocator, &.{}, &feats));
}
