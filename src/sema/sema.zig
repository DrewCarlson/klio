//! Semantic analysis: resolves every reference in every body to a declaration
//! identity and types every expression.
//!
//! The analysis runs over parsed files in three passes. `decls` gives every
//! declaration a symbol. `headers` resolves the types a declaration's header
//! names (supertypes, signatures, bounds), on demand and cycle-safe. `body`
//! resolves each body against the scope tower and records, per reference,
//! the declaration it resolved to. A reference the analysis cannot resolve is
//! reported to the census with its reason; it is never guessed.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

pub const names = @import("names.zig");
pub const symbols = @import("symbols.zig");
pub const types = @import("types.zig");
pub const census = @import("census.zig");
pub const decls = @import("decls.zig");
pub const scope = @import("scope.zig");
pub const headers = @import("headers.zig");
pub const subtyping = @import("subtyping.zig");
pub const body = @import("body.zig");
pub const dump = @import("dump.zig");
pub const render = @import("render.zig");
pub const records = @import("records.zig");
pub const output = @import("output.zig");
pub const members = @import("members.zig");
pub const infer = @import("infer.zig");
const scratch_mod = @import("scratch.zig");
/// The bump allocator resolution works in, which lowering uses for its bodies too.
pub const Scratch = scratch_mod.Scratch;
pub const diagnose = @import("diagnose.zig");
pub const exhaustive = @import("exhaustive.zig");
pub const suppress = @import("suppress.zig");
pub const declcheck = @import("declcheck.zig");
pub const annocheck = @import("annocheck.zig");
pub const usecheck = @import("usecheck.zig");
pub const optin = @import("optin.zig");

const Allocator = std.mem.Allocator;
pub const Name = names.Name;
pub const Names = names.Names;
pub const wk = names.wk;
pub const Sym = symbols.Sym;
pub const Symbols = symbols.Symbols;
pub const TypeId = types.TypeId;
pub const TypeStore = types.TypeStore;
pub const Census = census.Census;

pub const SourceFile = struct {
    ast: *const ast.KotlinFile,
    path: []const u8,
    /// Where the file comes from: the base library set, a pack, or the
    /// program. The census reports each separately.
    origin: Origin,
    /// Written by a compiler plugin (the serializers kotlinx.serialization
    /// generates), whose code reads what the plugin's own bytecode may:
    /// a superclass's private property.
    generated: bool = false,
};

pub const Origin = enum(u8) { base, pack, program };

pub const FileCtx = struct {
    /// Null for a base file read back from an image, whose declarations
    /// are in the tables.
    ast: ?*const ast.KotlinFile,
    path: []const u8,
    origin: Origin,
    generated: bool = false,
    package: Sym,
    /// Built on first use by `scope.fileScope`.
    imports: ?*scope.FileImports = null,

    /// How a base image carries a file: without its AST or its imports,
    /// which nothing reads once the base is analyzed.
    pub const codec_as = struct { path: []const u8, origin: Origin, generated: bool, package: Sym };

    pub fn toCodec(self: *const FileCtx, _: Allocator) Allocator.Error!codec_as {
        return .{ .path = self.path, .origin = self.origin, .generated = self.generated, .package = self.package };
    }

    pub fn fromCodec(img: codec_as, _: Allocator) Allocator.Error!FileCtx {
        return .{ .ast = null, .path = img.path, .origin = img.origin, .generated = img.generated, .package = img.package };
    }
};

/// Classes the language itself refers to. Each is declared by Kotlin source
/// in the base set; a missing one is reported once and answers `.none`.
pub const Builtins = struct {
    /// Declared by a library the program may not use; none when absent.
    composable: Sym = .none,
    overload_by_lambda: Sym = .none,
    low_priority: Sym = .none,
    platform_dependent: Sym = .none,
    deprecated: Sym = .none,
    dsl_marker: Sym = .none,
    kfunction: Sym = .none,
    any: Sym = .none,
    nothing: Sym = .none,
    unit: Sym = .none,
    boolean: Sym = .none,
    char: Sym = .none,
    byte: Sym = .none,
    short: Sym = .none,
    int: Sym = .none,
    long: Sym = .none,
    float: Sym = .none,
    double: Sym = .none,
    ubyte: Sym = .none,
    ushort: Sym = .none,
    uint: Sym = .none,
    ulong: Sym = .none,
    string: Sym = .none,
    char_sequence: Sym = .none,
    number: Sym = .none,
    comparable: Sym = .none,
    array: Sym = .none,
    throwable: Sym = .none,
    enum_: Sym = .none,
    annotation: Sym = .none,
    iterable: Sym = .none,
    iterator: Sym = .none,
    collection: Sym = .none,
    list: Sym = .none,
    map: Sym = .none,
    function: Sym = .none,
    kproperty0: Sym = .none,
    kproperty1: Sym = .none,
    kproperty2: Sym = .none,
    kmutable_property0: Sym = .none,
    kmutable_property1: Sym = .none,
    kmutable_property2: Sym = .none,
    kclass: Sym = .none,
    continuation: Sym = .none,
};

/// `KLIO_SEMA_TABLES`: how much each of the analysis's tables holds, for
/// the memory it keeps.
pub fn printTables(s: *Sema) void {
    const T = struct {
        fn list(name: []const u8, l: anytype) void {
            const E = @typeInfo(@TypeOf(l.items)).pointer.child;
            std.debug.print("[sema-tables] {s}: {d} x {d}B = {d}KB (capacity {d}KB)\n", .{ name, l.items.len, @sizeOf(E), l.items.len * @sizeOf(E) / 1024, l.capacity * @sizeOf(E) / 1024 });
        }
        fn map(name: []const u8, m: anytype) void {
            std.debug.print("[sema-tables] {s}: {d} entries (capacity {d})\n", .{ name, m.count(), m.capacity() });
        }
    };
    var nodes: usize = 0;
    for (s.files.items) |f| if (f.ast) |a| {
        nodes += a.node_count;
    };
    std.debug.print("[sema-tables] nodes: {d} in {d} files\n", .{ nodes, s.files.items.len });
    std.debug.print("[sema-tables] scratch high: {d}KB\n", .{s.scratch_high / 1024});
    T.list("refs", s.refs);
    T.list("expr_types", s.expr_types);
    T.list("types", s.types.items);
    T.list("syms", s.syms.syms);
    T.list("functions", s.syms.functions);
    T.list("locals", s.syms.locals);
    T.list("params", s.syms.params);
    T.map("var_solution", s.var_solution);
    T.map("open_var_bounds", s.open_var_bounds);
    T.map("reified_vars", s.reified_vars);
    T.map("lookup_memo", s.lookup_memo);
    T.map("path_subjects", s.path_subjects);
    T.map("types.intern_map", s.types.intern_map);
    T.map("exhaustive_whens", s.exhaustive_whens);
    T.map("contracts", s.contracts);
    T.map("nonnull_implies", s.nonnull_implies);
    T.map("bool_implies", s.bool_implies);
}

pub const Sema = struct {
    arena: Allocator,
    /// What resolving a body works in and drops: constraint systems,
    /// candidate lists, supertype walks, a member's scopes (`scratch`).
    /// Nothing the analysis keeps points into it, so it is emptied after
    /// each top-level declaration and each member of a top-level class
    /// (`resetScratch`), and freed when `resolveAll` ends.
    scratch_base: scratch_mod.Scratch = .{},
    /// `resolveAll` is running: `scratch` is scratch, else `arena`.
    scratch_open: bool = false,
    /// The most scratch held in use when it was emptied: the working data
    /// of the declaration that needed the most.
    scratch_high: usize = 0,
    /// A level of scratch for each declaration whose body another's
    /// resolution types on demand (`pushScratch`), emptied when it returns:
    /// one body asking for the types of many leaves none of their working
    /// data behind. `scratch_depth` of them are in use.
    scratch_levels: std.ArrayList(*scratch_mod.Scratch) = .empty,
    scratch_depth: u32 = 0,
    names: Names,
    syms: Symbols,
    types: TypeStore,
    files: std.ArrayList(FileCtx) = .empty,
    builtins: Builtins = .{},
    builtins_bound: bool = false,
    /// Every committed expression's type, keyed by file and node; see
    /// `output`.
    expr_types: std.ArrayList(records.ExprType) = .empty,
    /// The local an accessor declares for `field`, to the property whose
    /// storage it is.
    backing_fields: std.AutoHashMapUnmanaged(Sym, Sym) = .empty,
    census: Census,
    /// `kotlin.FunctionN` / `kotlin.coroutines.SuspendFunctionN` classes,
    /// synthesized on first use; the compiler declares them, not source.
    function_classes: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    suspend_function_classes: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    kfunction_classes: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    ksuspend_function_classes: std.AutoHashMapUnmanaged(u32, Sym) = .empty,
    /// The four maps above turned around: a class to its arity and which
    /// it is (`fnClassOf`), rebuilt when they have grown.
    fn_class_of: std.AutoHashMapUnmanaged(Sym, FnClass) = .empty,
    /// What a name finds at the top level, by file, while `resolveAll`
    /// runs.
    top_level: scope.TopLevelMemo = .{},
    /// Common type ids, filled once the builtins resolve.
    t: CommonTypes = .{},
    /// The default-import packages that exist, filled on first use.
    default_packages: ?[2][]const Sym = null,
    /// Inference variables are numbered across every constraint system,
    /// so a nested call's variables never alias its caller's.
    next_type_var: u32 = 0,
    /// What each inference variable was fixed to.
    var_solution: std.AutoHashMapUnmanaged(u32, TypeId) = .empty,
    /// The bounds of a variable a call left open, its type parameter's
    /// declared ones included, for the system that adopts it.
    open_var_bounds: std.AutoHashMapUnmanaged(u32, struct { lower: []const TypeId, upper: []const TypeId, declared: []const TypeId = &.{} }) = .empty,
    /// The inference variables that stand for a reified type parameter,
    /// wherever a call adopts them.
    reified_vars: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Whether an overriding function inherits `operator`.
    operator_memo: std.AutoHashMapUnmanaged(Sym, bool) = .empty,
    /// The synthetic SAM constructor of each fun interface asked for.
    sam_ctors: std.AutoHashMapUnmanaged(Sym, Sym) = .empty,
    /// The smart-cast subject standing for each stable member path
    /// (`a.b`), keyed by base subject and property.
    path_subjects: std.AutoHashMapUnmanaged(u64, Sym) = .empty,
    /// The property each of those subjects reads.
    path_property: std.AutoHashMapUnmanaged(Sym, Sym) = .empty,
    /// The subject each of those reads it on.
    path_base: std.AutoHashMapUnmanaged(Sym, Sym) = .empty,
    /// What a local `val` being not null says about the values its
    /// initializer read: `val a = b?.f()` makes `b` not null with `a`.
    nonnull_implies: std.AutoHashMapUnmanaged(Sym, []const @import("body.zig").Implied) = .empty,
    /// What a local Boolean `val` holding a condition says on each outcome: `val ok =
    /// x != null && y is A` makes `x` not null and `y` an `A` where `ok` is true.
    bool_implies: std.AutoHashMapUnmanaged(Sym, @import("body.zig").ImpliedFacts) = .empty,
    /// The `when`s with a subject and no `else` that match every subject,
    /// by `flowcheck.whenKey`.
    exhaustive_whens: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// How many writes to each local `var` have been analyzed: a write
    /// after a `val` read it ends what the `val` implied of it.
    local_writes: std.AutoHashMapUnmanaged(Sym, u32) = .empty,
    /// Each sealed class's direct subtypes, found in its package once asked
    /// for.
    sealed_inheritors: std.AutoHashMapUnmanaged(Sym, []const Sym) = .empty,
    /// `members.lookup`'s answers, keyed by receiver type, name and kind;
    /// cleared when a layer adds declarations.
    lookup_memo: std.AutoHashMapUnmanaged(@import("members.zig").LookupKey, []const @import("members.zig").Member) = .empty,
    /// Each function's `contract { returns(...) implies (...) }` effects,
    /// read from its body once asked for.
    contracts: std.AutoHashMapUnmanaged(Sym, []const @import("body.zig").Effect) = .empty,
    /// Classes declared in a body, by the function, lambda or class that
    /// owns the body, for types written inside it.
    local_classifiers: std.AutoHashMapUnmanaged(Sym, symbols.NameIndex) = .empty,
    /// The scope each class declared in a body resolves its members in,
    /// with the enclosing body's locals visible, for a member's type asked
    /// for before the class body reaches it.
    local_class_scopes: std.AutoHashMapUnmanaged(Sym, *body.Scope) = .empty,
    /// Properties whose setter a pass typing another declaration deferred.
    /// That declaration's own pass resumes its own setter, but not those of
    /// the properties of a class declared in its initializer, which it does
    /// not revisit: `resolveAll` resumes whatever is still pending.
    pending_setters: std.ArrayList(Sym) = .empty,
    /// Every reference resolved, in resolution order.
    refs: std.ArrayList(records.Ref) = .empty,
    /// The annotation classes a declaration carries, by
    /// `headers.annotationKey`: resolved on first use, and read back from a
    /// base image for the base's declarations, which have no AST.
    annotation_classes: std.AutoHashMapUnmanaged(u64, []const Sym) = .empty,
    /// The `@DslMarker` annotation classes a class carries, on itself or a
    /// supertype, by class.
    dsl_markers: std.AutoHashMapUnmanaged(Sym, []const Sym) = .empty,
    /// How each declaration asked about is deprecated, by its own
    /// annotations (`usecheck.ownDeprecation`); read back from a base image
    /// for the base's.
    deprecations: std.AutoHashMapUnmanaged(Sym, ?usecheck.Deprecation) = .empty,
    /// The level each annotation class asked about requires its opt-in at,
    /// null for one that is no `@RequiresOptIn` marker
    /// (`optin.markerLevel`); read back from a base image for the base's.
    opt_in_markers: std.AutoHashMapUnmanaged(Sym, ?optin.Level) = .empty,
    /// The variables calls are inferring from the lambdas passed to them
    /// (builder inference), each to the system of the call inferring it.
    builder_owners: std.AutoHashMapUnmanaged(u32, *infer.System) = .empty,

    pub const CommonTypes = struct {
        any: TypeId = .none,
        any_q: TypeId = .none,
        nothing: TypeId = .none,
        nothing_q: TypeId = .none,
        unit: TypeId = .none,
        boolean: TypeId = .none,
        int: TypeId = .none,
        long: TypeId = .none,
        short: TypeId = .none,
        byte: TypeId = .none,
        double: TypeId = .none,
        float: TypeId = .none,
        char: TypeId = .none,
        string: TypeId = .none,
        uint: TypeId = .none,
        ulong: TypeId = .none,
        ushort: TypeId = .none,
        ubyte: TypeId = .none,
        throwable: TypeId = .none,
    };

    /// Where a resolution's working data goes: scratch while `resolveAll`
    /// runs, `arena` outside it (headers typed before bodies, the checks
    /// after), whose analysis nothing empties.
    pub fn scratch(self: *Sema) Allocator {
        if (!self.scratch_open) return self.arena;
        if (self.scratch_depth == 0) return self.scratch_base.allocator();
        return self.scratch_levels.items[self.scratch_depth - 1].allocator();
    }

    /// Opens a level of scratch for a declaration resolved on demand; true
    /// when it did, which `popScratch` is given.
    pub fn pushScratch(self: *Sema) Allocator.Error!bool {
        if (!self.scratch_open) return false;
        if (self.scratch_levels.items.len == self.scratch_depth) {
            const level = try std.heap.page_allocator.create(scratch_mod.Scratch);
            level.* = .{};
            self.scratch_levels.append(std.heap.page_allocator, level) catch |e| {
                std.heap.page_allocator.destroy(level);
                return e;
            };
        }
        self.scratch_depth += 1;
        return true;
    }

    /// Empties and closes the level `pushScratch` opened.
    pub fn popScratch(self: *Sema, pushed: bool) void {
        if (!pushed) return;
        const level = self.scratch_levels.items[self.scratch_depth - 1];
        self.scratch_high = @max(self.scratch_high, level.inUse());
        level.reset(4 * 1024 * 1024);
        self.scratch_depth -= 1;
    }

    /// Empties scratch, keeping pages for the next declaration. Only where
    /// no call is being resolved: between top-level declarations or the
    /// members of a top-level class.
    pub fn resetScratch(self: *Sema) void {
        if (!self.scratch_open) return;
        self.scratch_high = @max(self.scratch_high, self.scratch_base.inUse());
        self.scratch_base.reset(16 * 1024 * 1024);
        self.top_level.trim();
    }

    pub fn openScratch(self: *Sema) void {
        self.scratch_open = true;
    }

    /// Ends what `openScratch` began and frees scratch's pages.
    pub fn closeScratch(self: *Sema) void {
        self.scratch_high = @max(self.scratch_high, self.scratch_base.inUse());
        self.scratch_open = false;
        self.scratch_base.deinit();
        self.top_level.deinit();
        for (self.scratch_levels.items) |level| {
            level.deinit();
            std.heap.page_allocator.destroy(level);
        }
        self.scratch_levels.deinit(std.heap.page_allocator);
        self.scratch_levels = .empty;
        self.scratch_depth = 0;
    }

    /// `arena` owns everything the analysis keeps; the analysis is dropped
    /// by dropping it.
    pub fn init(arena: Allocator) Allocator.Error!*Sema {
        const s = try arena.create(Sema);
        s.* = .{
            .arena = arena,
            .names = try Names.init(arena),
            .syms = try Symbols.init(arena),
            .types = try TypeStore.init(arena),
            .census = Census.init(arena),
        };
        return s;
    }

    /// Declares every file's symbols, then binds the builtins. Bodies are
    /// resolved by `resolveBodies`.
    ///
    /// Files are added in layers (the base, then a program), and a layer's
    /// symbols follow the previous layer's in a fixed order: its files'
    /// declarations, their synthesized members, then, in the first layer,
    /// the `FunctionN` and `SuspendFunctionN` classes up to `eager_arity`,
    /// then the SAM constructors of the layer's fun interfaces. Nothing in
    /// a layer's range is made on demand, so the same base files number
    /// their symbols the same way in every analysis.
    pub fn addFiles(self: *Sema, files: []const SourceFile) Allocator.Error!void {
        const first: u32 = @intCast(self.syms.count());
        const first_layer = first <= 1;
        const first_file = self.files.items.len;
        for (files) |f| try decls.collectFile(self, f);
        try self.bindBuiltins();
        try decls.markHidden(self, Sym.from(first));
        try decls.linkExpectActual(self, Sym.from(first));
        try decls.linkPlatformShadows(self, Sym.from(first));
        try decls.synthesizeFrom(self, Sym.from(first));
        try decls.checkDeclarations(self, Sym.from(first));
        // A program's imports resolve whether or not anything in the file
        // looks a name up through them: one that names nothing is reported.
        for (self.files.items[first_file..], first_file..) |fc, i| {
            if (fc.origin == .program) _ = try scope.fileImports(self, @intCast(i));
        }
        if (first_layer and self.builtins.function != .none) {
            var n: u32 = 0;
            while (n <= eager_arity) : (n += 1) {
                _ = try self.functionClass(n, false);
                _ = try self.functionClass(n, true);
            }
            n = 0;
            while (n <= eager_arity) : (n += 1) {
                _ = try self.kfunctionClass(n, false);
                _ = try self.kfunctionClass(n, true);
            }
        }
        try body.samConstructorsFrom(self, Sym.from(first));
        self.lookup_memo.clearRetainingCapacity();
    }

    /// Function classes made up front; a larger arity is made on first use.
    pub const eager_arity = 22;

    /// A digest of the first `n` symbols' kind, name and owner: two
    /// analyses that agree on it number those symbols the same way.
    pub fn prefixDigest(self: *const Sema, n: u32) u64 {
        var h = std.hash.Wyhash.init(0);
        var i: u32 = 1;
        while (i < n and i < self.syms.count()) : (i += 1) {
            const sym = Sym.from(i);
            h.update(std.mem.asBytes(&@intFromEnum(self.syms.kind(sym))));
            h.update(self.str(self.syms.name(sym)));
            h.update(std.mem.asBytes(&self.syms.owner(sym).int()));
        }
        return h.final();
    }

    pub fn resolveBodies(self: *Sema, origins: []const Origin) Allocator.Error!void {
        try body.resolveAll(self, origins);
    }

    pub fn classByFqn(self: *const Sema, fqn: []const u8) Sym {
        const n = self.names.lookup(fqn) orelse return .none;
        return self.syms.by_fqn.get(n) orelse .none;
    }

    fn bindBuiltins(self: *Sema) Allocator.Error!void {
        const b = &self.builtins;
        const table = .{
            .{ "any", "kotlin.Any" },
            .{ "nothing", "kotlin.Nothing" },
            .{ "unit", "kotlin.Unit" },
            .{ "boolean", "kotlin.Boolean" },
            .{ "char", "kotlin.Char" },
            .{ "byte", "kotlin.Byte" },
            .{ "short", "kotlin.Short" },
            .{ "int", "kotlin.Int" },
            .{ "long", "kotlin.Long" },
            .{ "float", "kotlin.Float" },
            .{ "double", "kotlin.Double" },
            .{ "ubyte", "kotlin.UByte" },
            .{ "ushort", "kotlin.UShort" },
            .{ "uint", "kotlin.UInt" },
            .{ "ulong", "kotlin.ULong" },
            .{ "string", "kotlin.String" },
            .{ "char_sequence", "kotlin.CharSequence" },
            .{ "number", "kotlin.Number" },
            .{ "comparable", "kotlin.Comparable" },
            .{ "array", "kotlin.Array" },
            .{ "throwable", "kotlin.Throwable" },
            .{ "enum_", "kotlin.Enum" },
            .{ "annotation", "kotlin.Annotation" },
            .{ "iterable", "kotlin.collections.Iterable" },
            .{ "iterator", "kotlin.collections.Iterator" },
            .{ "collection", "kotlin.collections.Collection" },
            .{ "list", "kotlin.collections.List" },
            .{ "map", "kotlin.collections.Map" },
            .{ "function", "kotlin.Function" },
            .{ "kproperty0", "kotlin.reflect.KProperty0" },
            .{ "kproperty1", "kotlin.reflect.KProperty1" },
            .{ "kproperty2", "kotlin.reflect.KProperty2" },
            .{ "kmutable_property0", "kotlin.reflect.KMutableProperty0" },
            .{ "kmutable_property1", "kotlin.reflect.KMutableProperty1" },
            .{ "kmutable_property2", "kotlin.reflect.KMutableProperty2" },
            .{ "kclass", "kotlin.reflect.KClass" },
            .{ "continuation", "kotlin.coroutines.Continuation" },
        };
        const first_layer = !self.builtins_bound;
        self.builtins_bound = true;
        inline for (table) |row| {
            const sym = self.classByFqn(row[1]);
            @field(b, row[0]) = sym;
            if (sym == .none and first_layer) try self.census.missingBuiltin(row[1]);
        }
        b.composable = self.classByFqn("androidx.compose.runtime.Composable");
        b.overload_by_lambda = self.classByFqn("kotlin.OverloadResolutionByLambdaReturnType");
        b.low_priority = self.classByFqn("kotlin.internal.LowPriorityInOverloadResolution");
        b.platform_dependent = self.classByFqn("kotlin.internal.PlatformDependent");
        b.deprecated = self.classByFqn("kotlin.Deprecated");
        b.dsl_marker = self.classByFqn("kotlin.DslMarker");
        b.kfunction = self.classByFqn("kotlin.reflect.KFunction");
        const t = &self.t;
        const ts = &self.types;
        t.any = try self.simpleType(b.any);
        t.any_q = try ts.makeNullable(t.any);
        t.nothing = try self.simpleType(b.nothing);
        t.nothing_q = try ts.makeNullable(t.nothing);
        t.unit = try self.simpleType(b.unit);
        t.boolean = try self.simpleType(b.boolean);
        t.int = try self.simpleType(b.int);
        t.long = try self.simpleType(b.long);
        t.short = try self.simpleType(b.short);
        t.byte = try self.simpleType(b.byte);
        t.double = try self.simpleType(b.double);
        t.float = try self.simpleType(b.float);
        t.char = try self.simpleType(b.char);
        t.string = try self.simpleType(b.string);
        t.uint = try self.simpleType(b.uint);
        t.ulong = try self.simpleType(b.ulong);
        t.ushort = try self.simpleType(b.ushort);
        t.ubyte = try self.simpleType(b.ubyte);
        t.throwable = try self.simpleType(b.throwable);
    }

    /// The non-null type of a class with no type parameters, or the error
    /// type when the class is missing.
    pub fn simpleType(self: *Sema, sym: Sym) Allocator.Error!TypeId {
        if (sym == .none) return self.types.errType();
        return self.types.class(sym, &.{}, false);
    }

    /// `kotlin.FunctionN` (or `SuspendFunctionN`), declared on first use with
    /// `N` input type parameters, an `out R` result and an `operator fun
    /// invoke`.
    pub const FnClass = struct { arity: u32, kind: enum { function, suspend_function, kfunction, ksuspend_function } };

    /// Which of `FunctionN`, `SuspendFunctionN`, `KFunctionN` and
    /// `KSuspendFunctionN` class `cls` is, and its `N`; null for any other.
    pub fn fnClassOf(self: *Sema, cls: Sym) ?FnClass {
        const n = self.function_classes.count() + self.suspend_function_classes.count() + self.kfunction_classes.count() + self.ksuspend_function_classes.count();
        if (self.fn_class_of.count() != n) self.indexFnClasses() catch return self.fnClassScan(cls);
        return self.fn_class_of.get(cls);
    }

    fn indexFnClasses(self: *Sema) Allocator.Error!void {
        self.fn_class_of.clearRetainingCapacity();
        const Each = struct { map: *const std.AutoHashMapUnmanaged(u32, Sym), kind: @FieldType(FnClass, "kind") };
        for ([_]Each{
            .{ .map = &self.function_classes, .kind = .function },
            .{ .map = &self.suspend_function_classes, .kind = .suspend_function },
            .{ .map = &self.kfunction_classes, .kind = .kfunction },
            .{ .map = &self.ksuspend_function_classes, .kind = .ksuspend_function },
        }) |m| {
            var it = m.map.iterator();
            while (it.next()) |e| try self.fn_class_of.put(self.arena, e.value_ptr.*, .{ .arity = e.key_ptr.*, .kind = m.kind });
        }
    }

    /// `fnClassOf` by walking the maps, when indexing them ran out of memory.
    fn fnClassScan(self: *Sema, cls: Sym) ?FnClass {
        const Each = struct { map: *const std.AutoHashMapUnmanaged(u32, Sym), kind: @FieldType(FnClass, "kind") };
        for ([_]Each{
            .{ .map = &self.function_classes, .kind = .function },
            .{ .map = &self.suspend_function_classes, .kind = .suspend_function },
            .{ .map = &self.kfunction_classes, .kind = .kfunction },
            .{ .map = &self.ksuspend_function_classes, .kind = .ksuspend_function },
        }) |m| {
            var it = m.map.iterator();
            while (it.next()) |e| if (e.value_ptr.* == cls) return .{ .arity = e.key_ptr.*, .kind = m.kind };
        }
        return null;
    }

    /// `KFunctionN` / `KSuspendFunctionN`; none when the base declares no
    /// `KFunction`.
    pub fn kfunctionClass(self: *Sema, arity: u32, is_suspend: bool) Allocator.Error!Sym {
        if (self.builtins.kfunction == .none) return .none;
        const map = if (is_suspend) &self.ksuspend_function_classes else &self.kfunction_classes;
        if (map.get(arity)) |s| return s;
        const sym = try decls.synthesizeKFunctionClass(self, arity, is_suspend);
        try map.put(self.arena, arity, sym);
        return sym;
    }

    pub fn functionClass(self: *Sema, arity: u32, is_suspend: bool) Allocator.Error!Sym {
        const map = if (is_suspend) &self.suspend_function_classes else &self.function_classes;
        if (map.get(arity)) |s| return s;
        const sym = try decls.synthesizeFunctionClass(self, arity, is_suspend);
        try map.put(self.arena, arity, sym);
        return sym;
    }

    /// The function type `(params) -> ret`, optionally with a receiver as the
    /// first parameter and `ext_fn` set.
    pub fn functionType(self: *Sema, receiver: TypeId, params: []const TypeId, ret: TypeId, is_suspend: bool, nullable: bool) Allocator.Error!TypeId {
        return self.contextFunctionType(&.{}, receiver, params, ret, is_suspend, nullable);
    }

    /// `context(C...) R.(P...) -> T`: the class takes the contexts first,
    /// then the receiver, then the parameters, as kotlinc lays it out.
    pub fn contextFunctionType(self: *Sema, contexts: []const TypeId, receiver: TypeId, params: []const TypeId, ret: TypeId, is_suspend: bool, nullable: bool) Allocator.Error!TypeId {
        const n: u32 = @intCast(contexts.len + params.len + @intFromBool(receiver != .none));
        const cls = try self.functionClass(n, is_suspend);
        var args: std.ArrayList(types.Arg) = .empty;
        for (contexts) |c| try args.append(self.arena, .{ .variance = .inv, .ty = c });
        if (receiver != .none) try args.append(self.arena, .{ .variance = .inv, .ty = receiver });
        for (params) |p| try args.append(self.arena, .{ .variance = .inv, .ty = p });
        try args.append(self.arena, .{ .variance = .inv, .ty = ret });
        return self.types.classAttrs(cls, args.items, nullable, .{ .ext_fn = receiver != .none, .context_count = @intCast(@min(contexts.len, 15)) });
    }

    /// The array a vararg parameter of element type `elem` holds: a
    /// primitive array for a primitive element, else `Array<out T>`.
    pub fn varargArrayType(self: *Sema, elem: TypeId) Allocator.Error!TypeId {
        const t = self.t;
        const prim = [_]struct { t: TypeId, arr: []const u8 }{
            .{ .t = t.int, .arr = "kotlin.IntArray" },
            .{ .t = t.long, .arr = "kotlin.LongArray" },
            .{ .t = t.double, .arr = "kotlin.DoubleArray" },
            .{ .t = t.float, .arr = "kotlin.FloatArray" },
            .{ .t = t.char, .arr = "kotlin.CharArray" },
            .{ .t = t.boolean, .arr = "kotlin.BooleanArray" },
            .{ .t = t.byte, .arr = "kotlin.ByteArray" },
            .{ .t = t.short, .arr = "kotlin.ShortArray" },
            .{ .t = t.uint, .arr = "kotlin.UIntArray" },
            .{ .t = t.ulong, .arr = "kotlin.ULongArray" },
            .{ .t = t.ubyte, .arr = "kotlin.UByteArray" },
            .{ .t = t.ushort, .arr = "kotlin.UShortArray" },
        };
        for (prim) |p| {
            if (p.t == elem and p.t != .none) {
                const c = self.classByFqn(p.arr);
                if (c != .none) return self.simpleType(c);
            }
        }
        if (self.builtins.array == .none) return self.types.errType();
        return self.types.class(self.builtins.array, &.{.{ .variance = .out, .ty = elem }}, false);
    }

    pub fn fileOf(self: *Sema, file: u32) ?*FileCtx {
        if (file == symbols.NO_FILE or file >= self.files.items.len) return null;
        return &self.files.items[file];
    }

    pub fn str(self: *const Sema, n: Name) []const u8 {
        return self.names.str(n);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = scratch_mod;
    _ = names;
    _ = symbols;
    _ = types;
    _ = census;
    _ = decls;
    _ = scope;
    _ = headers;
    _ = subtyping;
    _ = body;
    _ = dump;
    _ = render;
    _ = @import("tests.zig");
}
