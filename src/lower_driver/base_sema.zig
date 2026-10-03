//! The base image's sema section: the base's names, types and symbols as
//! the bake left them, and what a program's analysis, the bridge and
//! lowering ask about a base declaration beyond its header (its annotation
//! classes, its deprecation, its contract). A run decodes it into a `Sema`
//! whose base symbols have no AST and whose base files have no text, and
//! analyzes its program over that: no base file is read or parsed.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const interp_ir = @import("interp_ir");

const Allocator = std.mem.Allocator;
const codec = interp_ir.codec;
const Growable = codec.Growable;
const symbols = sema.symbols;
const Sym = sema.Sym;
const Name = sema.Name;
const TypeId = sema.TypeId;

fn KV(comptime K: type, comptime V: type) type {
    return struct { k: K, v: V };
}

/// A base file as the source map holds it for a run over the image: its
/// path and where its lines start, so a frame in a base function names its
/// line, and no text.
pub const Source = struct {
    path: []const u8,
    line_starts: []const u32,
};

pub const Image = struct {
    names: Growable([]const u8),
    types: Growable(sema.types.Type),
    err_type: TypeId,
    syms: Growable(symbols.Symbol),
    classes: Growable(symbols.ClassInfo),
    functions: Growable(symbols.FunctionInfo),
    properties: Growable(symbols.PropertyInfo),
    params: Growable(symbols.ParamInfo),
    locals: Growable(symbols.LocalInfo),
    type_params: Growable(symbols.TypeParamInfo),
    aliases: Growable(symbols.TypeAliasInfo),
    entries: Growable(symbols.EnumEntryInfo),
    packages: Growable(symbols.PackageInfo),
    by_fqn: []const KV(Name, Sym),
    root_package: Sym,
    files: Growable(sema.FileCtx),
    builtins: sema.Builtins,
    t: sema.Sema.CommonTypes,
    function_classes: []const KV(u32, Sym),
    suspend_function_classes: []const KV(u32, Sym),
    kfunction_classes: []const KV(u32, Sym),
    ksuspend_function_classes: []const KV(u32, Sym),
    next_type_var: u32,
    sam_ctors: []const KV(Sym, Sym),
    contracts: []const KV(Sym, []const sema.body.Effect),
    annotation_classes: []const KV(u64, []const Sym),
    deprecations: []const KV(Sym, sema.usecheck.Deprecation),
    opt_in_markers: []const KV(Sym, sema.optin.Level),
};

/// `Sema` fields the image does not carry: the arena, and what a body's
/// resolution keeps for itself (records, inference state, smart-cast
/// subjects, the scopes of classes declared in bodies) or remembers of
/// questions asked, which a run asks again of the tables.
const not_carried = [_][]const u8{
    "arena",            "scratch_base",       "scratch_open",    "scratch_high",    "scratch_levels",  "scratch_depth",   "fn_class_of",     "census",          "builtins_bound",  "expr_types",      "backing_fields",
    "default_packages", "var_solution",       "open_var_bounds", "reified_vars",    "operator_memo",
    "path_subjects",    "path_property",      "path_base",       "nonnull_implies", "bool_implies", "exhaustive_whens",     "local_writes",
    "sealed_inheritors", "lookup_memo",       "local_classifiers", "local_class_scopes", "pending_setters",
    "refs",             "builder_owners",     "dsl_markers",
};

comptime {
    @setEvalBranchQuota(20_000);
    for (@typeInfo(sema.Sema).@"struct".fields) |f| {
        const carried = @hasField(Image, f.name);
        var skipped = false;
        for (not_carried) |n| {
            if (std.mem.eql(u8, n, f.name)) skipped = true;
        }
        if (!carried and !skipped) @compileError("the base image does not carry Sema." ++ f.name);
    }
}

/// Asks, of every base declaration with an AST, what a program's build may
/// ask of it later without one: its header, its annotation classes at each
/// site, its deprecation, and a function's contract. Run on the bake's sema
/// before `image`.
pub fn complete(s: *sema.Sema) Allocator.Error!void {
    try sema.headers.resolveAllHeaders(s);
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        if (!s.syms.get(sym).decl.hasAst()) continue;
        inline for (@typeInfo(sema.headers.AnnotationSite).@"enum".fields) |f| {
            const site: sema.headers.AnnotationSite = @enumFromInt(f.value);
            const written = sema.headers.writtenAnnotations(s, sym, site) orelse &.{};
            if (written.len != 0) _ = try sema.headers.annotationClasses(s, sym, site);
        }
        _ = try sema.usecheck.ownDeprecation(s, sym);
        if (s.syms.kind(sym) == .class) _ = try sema.optin.markerLevel(s, sym);
        if (s.syms.kind(sym) == .function) _ = try sema.body.contractOf(s, sym);
    }
}

fn pairs(comptime K: type, comptime V: type, a: Allocator, map: anytype) Allocator.Error![]const KV(K, V) {
    var out: std.ArrayList(KV(K, V)) = .empty;
    var it = map.iterator();
    while (it.next()) |e| try out.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(K, V), out.items, {}, struct {
        fn lt(_: void, x: KV(K, V), y: KV(K, V)) bool {
            return keyInt(x.k) < keyInt(y.k);
        }
    }.lt);
    return out.items;
}

fn keyInt(k: anytype) u64 {
    return switch (@typeInfo(@TypeOf(k))) {
        .int => k,
        .@"enum" => @intFromEnum(k),
        else => @compileError("unsorted key"),
    };
}

/// The first `n` files of `map`, the base's, as the image carries them.
pub fn sources(a: Allocator, map: *const span.SourceMap, n: usize) Allocator.Error![]const Source {
    const out = try a.alloc(Source, n);
    for (out, map.files.items[0..n]) |*o, f| {
        o.* = .{ .path = f.path, .line_starts = if (f.line_starts.len != 0) f.line_starts else try lineStarts(a, f.source) };
    }
    return out;
}

/// The image of `s` as the bake leaves it. Its slices borrow `s` and `a`.
pub fn image(a: Allocator, s: *sema.Sema) Allocator.Error!Image {
    var deps: std.ArrayList(KV(Sym, sema.usecheck.Deprecation)) = .empty;
    var dit = s.deprecations.iterator();
    while (dit.next()) |e| if (e.value_ptr.*) |d| try deps.append(a, .{ .k = e.key_ptr.*, .v = d });
    std.mem.sort(KV(Sym, sema.usecheck.Deprecation), deps.items, {}, struct {
        fn lt(_: void, x: KV(Sym, sema.usecheck.Deprecation), y: KV(Sym, sema.usecheck.Deprecation)) bool {
            return x.k.int() < y.k.int();
        }
    }.lt);
    var contracts: std.ArrayList(KV(Sym, []const sema.body.Effect)) = .empty;
    var cit = s.contracts.iterator();
    while (cit.next()) |e| if (e.value_ptr.len != 0) try contracts.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(Sym, []const sema.body.Effect), contracts.items, {}, struct {
        fn lt(_: void, x: KV(Sym, []const sema.body.Effect), y: KV(Sym, []const sema.body.Effect)) bool {
            return x.k.int() < y.k.int();
        }
    }.lt);
    var markers: std.ArrayList(KV(Sym, sema.optin.Level)) = .empty;
    var mit = s.opt_in_markers.iterator();
    while (mit.next()) |e| if (e.value_ptr.*) |l| try markers.append(a, .{ .k = e.key_ptr.*, .v = l });
    std.mem.sort(KV(Sym, sema.optin.Level), markers.items, {}, struct {
        fn lt(_: void, x: KV(Sym, sema.optin.Level), y: KV(Sym, sema.optin.Level)) bool {
            return x.k.int() < y.k.int();
        }
    }.lt);
    var anns: std.ArrayList(KV(u64, []const Sym)) = .empty;
    var ait = s.annotation_classes.iterator();
    while (ait.next()) |e| if (e.value_ptr.len != 0) try anns.append(a, .{ .k = e.key_ptr.*, .v = e.value_ptr.* });
    std.mem.sort(KV(u64, []const Sym), anns.items, {}, struct {
        fn lt(_: void, x: KV(u64, []const Sym), y: KV(u64, []const Sym)) bool {
            return x.k < y.k;
        }
    }.lt);
    const syms = &s.syms;
    return .{
        .names = .of(@constCast(s.names.strs.items)),
        .types = .of(s.types.items.items),
        .err_type = s.types.err_id,
        .syms = .of(syms.syms.items),
        .classes = .of(syms.classes.items),
        .functions = .of(syms.functions.items),
        .properties = .of(syms.properties.items),
        .params = .of(syms.params.items),
        .locals = .of(syms.locals.items),
        .type_params = .of(syms.type_params.items),
        .aliases = .of(syms.aliases.items),
        .entries = .of(syms.entries.items),
        .packages = .of(syms.packages.items),
        .by_fqn = try pairs(Name, Sym, a, syms.by_fqn),
        .root_package = syms.root_package,
        .files = .of(s.files.items),
        .builtins = s.builtins,
        .t = s.t,
        .function_classes = try pairs(u32, Sym, a, s.function_classes),
        .suspend_function_classes = try pairs(u32, Sym, a, s.suspend_function_classes),
        .kfunction_classes = try pairs(u32, Sym, a, s.kfunction_classes),
        .ksuspend_function_classes = try pairs(u32, Sym, a, s.ksuspend_function_classes),
        .next_type_var = s.next_type_var,
        .sam_ctors = try pairs(Sym, Sym, a, s.sam_ctors),
        .contracts = contracts.items,
        .annotation_classes = anns.items,
        .deprecations = deps.items,
        .opt_in_markers = markers.items,
    };
}

fn lineStarts(a: Allocator, source: []const u8) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    try out.append(a, 0);
    for (source, 0..) |b, i| if (b == '\n') try out.append(a, @intCast(i + 1));
    return out.items;
}

fn mapOf(comptime K: type, comptime V: type, a: Allocator, kvs: []const KV(K, V)) Allocator.Error!std.AutoHashMapUnmanaged(K, V) {
    var out: std.AutoHashMapUnmanaged(K, V) = .empty;
    try out.ensureTotalCapacity(a, @intCast(kvs.len));
    for (kvs) |e| out.putAssumeCapacity(e.k, e.v);
    return out;
}

/// A `Sema` over the base `img` holds, in `a`, which must outlive it with
/// the buffer `img` was decoded from.
pub fn load(a: Allocator, img: *const Image) Allocator.Error!*sema.Sema {
    const s = try a.create(sema.Sema);
    var names: sema.Names = .{ .arena = a, .strs = img.names.list() };
    try names.map.ensureTotalCapacity(a, @intCast(names.strs.items.len));
    for (names.strs.items, 0..) |str, i| names.map.putAssumeCapacity(str, @enumFromInt(@as(u32, @intCast(i))));
    var syms: symbols.Symbols = .{
        .arena = a,
        .syms = img.syms.list(),
        .classes = img.classes.list(),
        .functions = img.functions.list(),
        .properties = img.properties.list(),
        .params = img.params.list(),
        .locals = img.locals.list(),
        .type_params = img.type_params.list(),
        .aliases = img.aliases.list(),
        .entries = img.entries.list(),
        .packages = img.packages.list(),
        .by_fqn = try mapOf(Name, Sym, a, img.by_fqn),
        .root_package = img.root_package,
    };
    for (syms.syms.items, 0..) |sym, i| {
        if (sym.kind != .package) continue;
        try syms.package_by_fqn.put(a, syms.packages.items[sym.detail].fqn, Sym.from(@intCast(i)));
    }
    s.* = .{
        .arena = a,
        .names = names,
        .syms = syms,
        .types = try sema.types.TypeStore.fromItems(a, img.types.list(), img.err_type),
        .files = img.files.list(),
        .builtins = img.builtins,
        .builtins_bound = true,
        .census = sema.Census.init(a),
        .function_classes = try mapOf(u32, Sym, a, img.function_classes),
        .suspend_function_classes = try mapOf(u32, Sym, a, img.suspend_function_classes),
        .kfunction_classes = try mapOf(u32, Sym, a, img.kfunction_classes),
        .ksuspend_function_classes = try mapOf(u32, Sym, a, img.ksuspend_function_classes),
        .t = img.t,
        .next_type_var = img.next_type_var,
        .sam_ctors = try mapOf(Sym, Sym, a, img.sam_ctors),
        .contracts = try mapOf(Sym, []const sema.body.Effect, a, img.contracts),
        .annotation_classes = try mapOf(u64, []const Sym, a, img.annotation_classes),
    };
    try s.deprecations.ensureTotalCapacity(a, @intCast(img.deprecations.len));
    for (img.deprecations) |e| s.deprecations.putAssumeCapacity(e.k, e.v);
    try s.opt_in_markers.ensureTotalCapacity(a, @intCast(img.opt_in_markers.len));
    for (img.opt_in_markers) |e| s.opt_in_markers.putAssumeCapacity(e.k, e.v);
    return s;
}
