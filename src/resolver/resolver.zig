//! Name resolution.
//!
//! Walks a parsed `KotlinFile` and produces a side-table that maps every
//! name-use site (`Span`) to the declaration it refers to. Top-level
//! functions and properties are forward-declared so the interpreter's
//! observed evaluation order is preserved. Builtins like `println` and
//! `print` resolve to `Symbol.Builtin` without a declaration site.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const stdlib = @import("stdlib");
const span = @import("span");

const Span = span.Span;
const Diagnostic = diagnostics.Diagnostic;
const DiagnosticSink = diagnostics.DiagnosticSink;
const factories = diagnostics.generated;

const Block = ast.Block;
const Decl = ast.Decl;
const Expr = ast.Expr;
const Function = ast.Function;
const FunctionBody = ast.FunctionBody;
const ImportDecl = ast.ImportDecl;
const KotlinFile = ast.KotlinFile;
const Param = ast.Param;
const Property = ast.Property;
const Stmt = ast.Stmt;
const StringPart = ast.StringPart;

/// Stable identifier for a resolver-tracked symbol.
pub const SymbolId = enum(u32) {
    _,
    pub fn from(v: u32) SymbolId {
        return @enumFromInt(v);
    }
    pub fn int(self: SymbolId) u32 {
        return @intFromEnum(self);
    }
};

/// Kinds of symbols the resolver knows about.
pub const SymbolKind = enum {
    /// A top-level function (forward-visible across the whole file).
    TopLevelFunction,
    /// A local function declared inside a block.
    LocalFunction,
    /// A top-level property (`val`/`var`).
    TopLevelProperty,
    /// A `val`/`var` declared inside a block.
    LocalProperty,
    /// A function parameter.
    Parameter,
    /// A `for` loop induction variable.
    ForVar,
    /// An interpreter-provided builtin (`println`, `print`).
    Builtin,
    /// A class declaration.
    Class,
    /// A `typealias` declaration. Aliases are transparent at use sites — the
    /// resolver tracks them as a distinct kind so the type checker can
    /// recognize them when lowering type references and at call sites that
    /// construct through the underlying class.
    TypeAlias,
};

/// A single declaration the resolver tracks.
pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    /// Source span of the declaration. `null` for builtins.
    decl_span: ?Span,
    /// Whether the symbol's declared type is nullable (`T?`). `null` means
    /// the resolver doesn't know (no annotation, inference deferred).
    nullable: ?bool,
};

pub const ScopeId = enum(u32) {
    _,
    pub fn from(v: u32) ScopeId {
        return @enumFromInt(v);
    }
    pub fn int(self: ScopeId) u32 {
        return @intFromEnum(self);
    }
};

pub const ScopeKind = enum {
    Builtins,
    File,
    Function,
    Block,
    /// Class / object body. A declaration scope holding all member names.
    /// Names inside member bodies that don't resolve here or in an
    /// enclosing scope are *not* an R0001 error — they may be inherited
    /// from a supertype or resolved against `this` at runtime.
    ClassBody,
};

/// Lexical scope tree. Each scope has a parent (except the file scope), a
/// kind tag for diagnostics, and a flat name table.
pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    kind: ScopeKind,
    bindings: std.StringHashMap(SymbolId),
};

/// Output of name resolution. Every container and every string the resolver
/// produces is allocated from the single driver-owned arena passed to
/// `resolve`/`resolveModule`; the arena is freed by the driver after the
/// last reader of this output (typeck, then lowering) is done, so the
/// resolution exposes no teardown of its own.
pub const Resolution = struct {
    scopes: std.ArrayList(Scope),
    symbols: std.ArrayList(Symbol),
    /// Map from name-use site (`Span` of the referenced identifier) to the
    /// symbol it resolves to.
    uses: std.AutoHashMap(Span, SymbolId),
    diagnostics: DiagnosticSink,

    pub fn symbol(self: *const Resolution, id: SymbolId) *const Symbol {
        return &self.symbols.items[id.int()];
    }

    pub fn scope(self: *const Resolution, id: ScopeId) *const Scope {
        return &self.scopes.items[id.int()];
    }

    /// Look up the symbol a given name-use span resolves to.
    pub fn resolved(self: *const Resolution, use_span: Span) ?*const Symbol {
        if (self.uses.get(use_span)) |id| return self.symbol(id);
        return null;
    }
};

const BUILTINS = [_][]const u8{
    "println",
    "print",
    // Stdlib scope functions with contracts.
    "run",
    "with",
    "check",
    "require",
    "repeat",
    "contract",
    // Threads / monitors. `synchronized` is in `kotlin` (implicitly
    // imported); `thread` lives in `kotlin.concurrent` and is reached
    // via `import kotlin.concurrent.thread`, but the use site is a
    // bare name either way so it resolves through the builtins scope.
    // `Thread` is the class whose statics (`Thread.sleep`,
    // `Thread.currentThread`) resolve through the builtins scope as a
    // bare name.
    "synchronized",
    "thread",
    "Thread",
    // Builder-style inference entry points. Typeck threads the lambda
    // body through `check_builder_call` so member references on the
    // implicit receiver (e.g. `add`, `put`) resolve through the
    // receiver's class table.
    "buildList",
    "buildMap",
    "buildSet",
    "sequence",
    "iterator",
};

/// Resolve a parsed file. The returned `Resolution` always contains a
/// builtins scope and a file scope, even if the input has no declarations.
/// Resolve a single file. `allocator` must be a driver-owned arena: the
/// resolver allocates every container and string from it and frees nothing,
/// so the driver reclaims the whole workspace by freeing that arena once the
/// resolution's last reader is done.
pub fn resolve(allocator: std.mem.Allocator, file: *const KotlinFile) !Resolution {
    var r = try Resolver.init(allocator);
    try r.run(file);
    return .{
        .scopes = r.scopes,
        .symbols = r.symbols,
        .uses = r.uses,
        .diagnostics = r.diagnostics,
    };
}

/// Resolve a multi-file module. Every file's top-level declarations
/// share a module-level scope, but each file applies its own imports
/// only inside its own decls (file-local import scoping). Use-spans
/// across files remain distinguishable through the `FileId` carried on
/// each Span.
pub fn resolveModule(allocator: std.mem.Allocator, files: []const KotlinFile) !Resolution {
    var r = try Resolver.init(allocator);
    const builtins = ScopeId.from(0);
    const module_scope = try r.pushScope(builtins, .File);
    // Phase 1: forward-declare every file's top-level decls into the
    // shared module scope so cross-file references resolve.
    for (files) |*file| {
        try r.setFilePackage(file);
        for (file.decls) |*decl| {
            try r.declareTopLevel(module_scope, decl);
        }
    }
    // Phase 2: per-file pass that applies that file's imports inside
    // a fresh child of the module scope, then resolves decl bodies.
    for (files) |*file| {
        try r.setFilePackage(file);
        const file_scope = try r.pushScope(module_scope, .File);
        for (file.imports) |*imp| {
            try r.checkImport(imp);
            try r.bindImportLeaf(file_scope, imp);
        }
        for (file.decls) |*decl| {
            try r.resolveDecl(file_scope, decl, true);
        }
    }
    return .{
        .scopes = r.scopes,
        .symbols = r.symbols,
        .uses = r.uses,
        .diagnostics = r.diagnostics,
    };
}

const SigKeyContext = struct {
    pub fn hash(_: SigKeyContext, key: SigKey) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, key.scope);
        h.update(key.key);
        return h.final();
    }
    pub fn eql(_: SigKeyContext, a: SigKey, b: SigKey) bool {
        return a.scope == b.scope and std.mem.eql(u8, a.key, b.key);
    }
};

const SigKey = struct {
    scope: u32,
    key: []const u8,
};

const SigKeyMap = std.HashMap(SigKey, void, SigKeyContext, std.hash_map.default_max_load_percentage);

/// Error set shared by the mutually recursive walk methods. Naming it
/// explicitly breaks the inferred-error-set dependency loop the compiler
/// would otherwise hit on `resolveFunction`/`resolveBlock`/`resolveStmt`.
const ResolveError = error{OutOfMemory};

const Resolver = struct {
    /// Driver-owned arena. Every container spine and every string the
    /// resolver produces is allocated from it; the resolver frees nothing.
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    symbols: std.ArrayList(Symbol),
    uses: std.AutoHashMap(Span, SymbolId),
    diagnostics: DiagnosticSink,
    /// Dotted package name from the file's `package` header, if any.
    /// Overwritten per file.
    file_package: ?[]const u8,
    /// Top-level function signature keys already declared, per
    /// `(scope, name, arity, param-type-names)`. Lets overloads with
    /// distinct signatures coexist while still flagging an exact
    /// duplicate (`fun foo()` declared twice) as a redeclaration.
    fn_sig_keys: SigKeyMap,

    fn init(allocator: std.mem.Allocator) !Resolver {
        var r = Resolver{
            .allocator = allocator,
            .scopes = .empty,
            .symbols = .empty,
            .uses = std.AutoHashMap(Span, SymbolId).init(allocator),
            .diagnostics = DiagnosticSink.init(),
            .file_package = null,
            .fn_sig_keys = SigKeyMap.init(allocator),
        };
        const builtins = try r.pushScope(null, .Builtins);
        for (BUILTINS) |name| {
            const sym = try r.addSymbol(name, .Builtin, null);
            try r.scopes.items[builtins.int()].bindings.put(name, sym);
        }
        return r;
    }

    /// Allocator for resolver-owned strings.
    fn strs(self: *Resolver) std.mem.Allocator {
        return self.allocator;
    }

    fn setFilePackage(self: *Resolver, file: *const KotlinFile) !void {
        self.file_package = null;
        if (file.package) |p| {
            self.file_package = try joinPath(self.strs(), p.path);
        }
    }

    fn run(self: *Resolver, file: *const KotlinFile) !void {
        const builtins = ScopeId.from(0);
        const file_scope = try self.pushScope(builtins, .File);

        try self.setFilePackage(file);

        for (file.imports) |*imp| {
            try self.checkImport(imp);
        }

        // Forward-declare every top-level decl so order doesn't matter.
        for (file.decls) |*decl| {
            try self.declareTopLevel(file_scope, decl);
        }

        // Imported names are in scope at use sites; bind any leaf a
        // declaration didn't already claim.
        for (file.imports) |*imp| {
            try self.bindImportLeaf(file_scope, imp);
        }

        for (file.decls) |*decl| {
            try self.resolveDecl(file_scope, decl, true);
        }
    }

    fn checkImport(self: *Resolver, imp: *const ImportDecl) !void {
        if (imp.path.len == 0) {
            // Parser already emitted P0047; nothing further to validate.
            return;
        }
        const a = self.strs();
        const own_pkg = self.file_package;
        const path_str = try joinPath(a, imp.path);

        // Importing from the file's own package is permitted and is
        // effectively a no-op (entities of the same package are already
        // visible). Skip diagnostics for that case.
        if (own_pkg) |own| {
            const same_package = if (imp.wildcard)
                std.mem.eql(u8, path_str, own)
            else blk: {
                // For a non-wildcard import, the package is the path minus
                // the trailing entity segment.
                const prefix = try joinPath(a, imp.path[0 .. imp.path.len - 1]);
                break :blk std.mem.eql(u8, prefix, own);
            };
            if (same_package) return;
        }

        if (!std.mem.eql(u8, imp.path[0].name, "kotlin")) {
            // Non-`kotlin.*` import. Permitted when a loaded pack has
            // registered the package (e.g. `kotlinx.coroutines`,
            // `kotlinx.io`). The candidate package is the path itself
            // for a wildcard import, else the path minus the trailing
            // entity segment.
            const candidate_pkg = if (imp.wildcard)
                path_str
            else if (imp.path.len >= 2)
                try joinPath(a, imp.path[0 .. imp.path.len - 1])
            else
                path_str;
            if (!stdlib.isKnownPackage(candidate_pkg)) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "no package `{s}` is known to this build",
                    .{path_str},
                );
                var d = Diagnostic.err(msg, imp.span);
                _ = d.withCode("R0003");
                _ = try d.withNote(
                    self.allocator,
                    "only the `kotlin.*` standard library and installed packs are available",
                );
                try self.diagnostics.emit(self.allocator, d);
            }
            return;
        }

        // Path starts with `kotlin`. Validate that the *package portion* is
        // one of the implicitly imported packages we know about. For a
        // wildcard the path is the package itself; for a regular import the
        // package is the path minus the entity segment.
        const candidate_pkg = if (imp.wildcard)
            path_str
        else if (imp.path.len >= 2)
            try joinPath(a, imp.path[0 .. imp.path.len - 1])
        else
            // `import kotlin` — the whole path is just the package, which
            // matches an implicitly imported package, so let it pass.
            path_str;
        if (!stdlib.isKnownPackage(candidate_pkg)) {
            const msg = try std.fmt.allocPrint(
                a,
                "no package `{s}` is known to this build",
                .{candidate_pkg},
            );
            var d = Diagnostic.err(msg, imp.span);
            _ = d.withCode("R0012");
            _ = try d.withNote(
                self.allocator,
                "klio implements the `kotlin.*` standard library packages mined from upstream Kotlin; see docs/STDLIB.md",
            );
            try self.diagnostics.emit(self.allocator, d);
        }
    }

    fn declareTopLevel(self: *Resolver, scope: ScopeId, decl: *const Decl) !void {
        // Extension *functions* are also bound by their bare name as a
        // tolerant fallback: inside a receiver-typed lambda the implicit
        // receiver makes `launch { … }` / `async { … }` (extensions on
        // `CoroutineScope`) callable without an explicit qualifier, and the
        // resolver has no receiver-type info at this pre-typeck stage.
        // Functions never conflict on name alone (overloads), so the bare
        // binding is safe and prevents spurious UNRESOLVED_REFERENCE on
        // valid code. The qualified `recv.ext()` path resolves independently.
        switch (decl.*) {
            .Property => |p| {
                if (p.receiver_type != null) return;
            },
            else => {},
        }
        const name: []const u8, const kind: SymbolKind, const sp: Span = switch (decl.*) {
            .Function => |f| .{ f.name.name, .TopLevelFunction, f.name.span },
            .Property => |p| .{ p.name.name, .TopLevelProperty, p.name.span },
            .Class => |c| .{ c.name.name, .Class, c.name.span },
            .Object => |o| .{ o.name.name, .Class, o.name.span },
            .TypeAlias => |a| .{ a.name.name, .TypeAlias, a.name.span },
        };
        // Kotlin permits multiple top-level functions to share a name
        // (overloads) and a factory function to share a name with a
        // class/interface (`fun CoroutineScope(...)` + `interface
        // CoroutineScope`). Only an *exact* duplicate signature (`fun
        // foo()` declared twice) is a redeclaration; distinct overloads
        // and factory-fn/class name sharing are legal and disambiguated
        // later by overload resolution.
        if (decl.* == .Function) {
            const f = decl.Function;
            var key_buf: std.ArrayList(u8) = .empty;
            try key_buf.print(self.strs(), "{s}#{d}", .{ name, f.params.len });
            for (f.params) |p| {
                try key_buf.append(self.strs(), '|');
                try key_buf.appendSlice(self.strs(), p.ty.name.name);
            }
            const key = key_buf.items;
            const probe = SigKey{ .scope = scope.int(), .key = key };
            if (self.fn_sig_keys.contains(probe)) {
                const prev_span: ?Span = blk: {
                    if (self.scopes.items[scope.int()].bindings.get(name)) |id| {
                        break :blk self.symbols.items[id.int()].decl_span;
                    }
                    break :blk null;
                };
                const msg = try std.fmt.allocPrint(
                    self.strs(),
                    "Conflicting declarations: duplicate top-level declaration `{s}`",
                    .{name},
                );
                var d = Diagnostic.err(msg, sp);
                _ = d.withCode("R0004");
                _ = d.withFactory(&factories.REDECLARATION);
                if (prev_span) |ps| {
                    _ = try d.withLabel(self.allocator, ps, "previous declaration here");
                }
                try self.diagnostics.emit(self.allocator, d);
            }
            try self.fn_sig_keys.put(SigKey{ .scope = scope.int(), .key = key }, {});
            const id = try self.addSymbol(name, kind, sp);
            try self.scopes.items[scope.int()].bindings.put(name, id);
            return;
        }
        // A non-function sharing a name with an existing function (or
        // vice-versa) is the legal factory pattern — bind without a
        // conflict diagnostic.
        const func_involved = blk: {
            if (self.scopes.items[scope.int()].bindings.get(name)) |id| {
                break :blk self.symbols.items[id.int()].kind == .TopLevelFunction;
            }
            break :blk false;
        };
        if (func_involved) {
            const id = try self.addSymbol(name, kind, sp);
            try self.scopes.items[scope.int()].bindings.put(name, id);
            return;
        }
        _ = try self.declare(scope, name, kind, sp, false);
    }

    fn declare(
        self: *Resolver,
        scope: ScopeId,
        name: []const u8,
        kind: SymbolKind,
        sp: Span,
        allow_shadow: bool,
    ) !SymbolId {
        // Duplicate-in-same-scope is always an error at file scope; for
        // inner scopes we permit redeclaration but emit a shadowing warning.
        const existing = self.scopes.items[scope.int()].bindings.get(name);
        if (existing) |prev_id| {
            const prev_kind = self.scopes.items[scope.int()].kind;
            if (prev_kind == .File) {
                const prev_span = self.symbols.items[prev_id.int()].decl_span;
                const msg = try std.fmt.allocPrint(
                    self.strs(),
                    "Conflicting declarations: duplicate top-level declaration `{s}`",
                    .{name},
                );
                var d = Diagnostic.err(msg, sp);
                _ = d.withCode("R0004");
                _ = d.withFactory(&factories.REDECLARATION);
                if (prev_span) |ps| {
                    _ = try d.withLabel(self.allocator, ps, "previous declaration here");
                }
                try self.diagnostics.emit(self.allocator, d);
            } else if (allow_shadow) {
                // Same-scope redeclaration in a block. Treat as shadow warning.
                const msg = try std.fmt.allocPrint(
                    self.strs(),
                    "`{s}` shadows an earlier binding",
                    .{name},
                );
                var d = Diagnostic.warning(msg, sp);
                _ = d.withCode("R0002");
                try self.diagnostics.emit(self.allocator, d);
            }
        }
        const id = try self.addSymbol(name, kind, sp);
        try self.scopes.items[scope.int()].bindings.put(name, id);
        return id;
    }

    fn resolveDecl(self: *Resolver, scope: ScopeId, decl: *const Decl, is_top_level: bool) ResolveError!void {
        switch (decl.*) {
            .Function => |*f| try self.resolveFunction(scope, f),
            .Property => |*p| try self.resolveProperty(scope, p, is_top_level),
            .Class => |*c| try self.resolveClassBody(scope, c.primary_params, c.init_blocks, c.members),
            .Object => |*o| try self.resolveClassBody(scope, &.{}, &.{}, o.members),
            .TypeAlias => {
                // The aliased type is resolved by the type checker; no
                // name-use sites inside a typealias target need symbol
                // bindings here.
            },
        }
    }

    /// Walk a class / object body. The body is a declaration scope — every
    /// member is visible to every other member regardless of source order.
    /// We pre-declare members into a fresh class scope, then walk each
    /// body. Unresolved bare names inside this scope are *not* errors: they
    /// may be inherited members or `this.x` lookups that the runtime
    /// resolves dynamically.
    fn resolveClassBody(
        self: *Resolver,
        parent: ScopeId,
        primary_params: []const ast.ClassParam,
        init_blocks: []const Block,
        members: []const Decl,
    ) ResolveError!void {
        const body_scope = try self.pushScope(parent, .ClassBody);
        for (primary_params) |p| {
            const sym = try self.addSymbol(
                p.name.name,
                if (p.property != null) .LocalProperty else .Parameter,
                p.name.span,
            );
            try self.scopes.items[body_scope.int()].bindings.put(p.name.name, sym);
        }
        for (members) |*m| {
            const name: []const u8, const kind: SymbolKind, const sp: Span = switch (m.*) {
                .Function => |f| blk: {
                    if (f.receiver_type != null) continue;
                    break :blk .{ f.name.name, .LocalFunction, f.name.span };
                },
                .Property => |p| blk: {
                    if (p.receiver_type != null) continue;
                    break :blk .{ p.name.name, .LocalProperty, p.name.span };
                },
                .Class => |c| .{ c.name.name, .Class, c.name.span },
                .Object => |o| .{ o.name.name, .Class, o.name.span },
                .TypeAlias => |a| .{ a.name.name, .TypeAlias, a.name.span },
            };
            const sym = try self.addSymbol(name, kind, sp);
            try self.scopes.items[body_scope.int()].bindings.put(name, sym);
        }
        for (init_blocks) |*b| {
            try self.resolveBlock(body_scope, b, false);
        }
        for (members) |*m| {
            try self.resolveDecl(body_scope, m, false);
        }
    }

    fn resolveFunction(self: *Resolver, parent: ScopeId, f: *const Function) ResolveError!void {
        const fn_scope = try self.pushScope(parent, .Function);
        for (f.params) |*p| {
            try self.resolveParam(fn_scope, p);
        }
        if (f.body) |*body| {
            switch (body.*) {
                .Block => |*b| try self.resolveBlock(fn_scope, b, false),
                .Expr => |*e| try self.resolveExpr(fn_scope, e),
            }
        }
    }

    fn resolveParam(self: *Resolver, scope: ScopeId, p: *const Param) ResolveError!void {
        _ = try self.declare(scope, p.name.name, .Parameter, p.name.span, true);
        if (p.default) |*default| {
            try self.resolveExpr(scope, default);
        }
    }

    fn resolveProperty(self: *Resolver, scope: ScopeId, p: *const Property, _: bool) ResolveError!void {
        if (p.ty) |ty| {
            if (self.scopes.items[scope.int()].bindings.get(p.name.name)) |id| {
                self.symbols.items[id.int()].nullable = ty.nullable;
            }
        }
        if (p.init) |*p_init| {
            try self.resolveExpr(scope, p_init);
        }
        if (p.getter) |*getter| {
            try self.resolveAccessor(scope, getter);
        }
        if (p.setter) |*setter| {
            try self.resolveAccessor(scope, setter);
        }
    }

    fn resolveAccessor(self: *Resolver, parent: ScopeId, acc: *const ast.Accessor) ResolveError!void {
        const scope = try self.pushScope(parent, .Function);
        for (acc.params) |p| {
            _ = try self.declare(scope, p.name, .Parameter, p.span, true);
        }
        switch (acc.body) {
            .Block => |*b| try self.resolveBlock(scope, b, false),
            .Expr => |*e| try self.resolveExpr(scope, e),
        }
    }

    fn resolveBlock(self: *Resolver, parent: ScopeId, block: *const Block, new_scope: bool) ResolveError!void {
        const scope = if (new_scope)
            try self.pushScope(parent, .Block)
        else
            parent;
        // Local functions in a statement scope are visible to sibling
        // statements regardless of declaration order, so mutual recursion
        // works. Pre-declare every local `fun` name into the block scope
        // before walking statement bodies. `val` / `var` keep their strict
        // order-of-appearance binding.
        for (block.stmts) |*s| {
            switch (s.*) {
                .Decl => |d| switch (d) {
                    .Function => |f| {
                        _ = try self.declare(scope, f.name.name, .LocalFunction, f.name.span, true);
                    },
                    else => {},
                },
                else => {},
            }
        }
        for (block.stmts) |*s| {
            try self.resolveStmt(scope, s);
        }
    }

    fn resolveStmt(self: *Resolver, scope: ScopeId, stmt: *const Stmt) ResolveError!void {
        switch (stmt.*) {
            .Expr => |*e| try self.resolveExpr(scope, e),
            .Decl => |*d| switch (d.*) {
                .Function => |*f| {
                    // Name is pre-declared by `resolveBlock`; resolve body.
                    try self.resolveFunction(scope, f);
                },
                .Property => |*p| {
                    if (p.init) |*p_init| {
                        try self.resolveExpr(scope, p_init);
                    }
                    const id = try self.declare(scope, p.name.name, .LocalProperty, p.name.span, true);
                    if (p.ty) |ty| {
                        self.symbols.items[id.int()].nullable = ty.nullable;
                    }
                },
                .Class, .Object => {},
                .TypeAlias => |*a| {
                    // Local-scope typealias — declare the name so subsequent
                    // typeck can flag T0039. The target type has no
                    // name-use sites the resolver tracks today.
                    _ = try self.declare(scope, a.name.name, .TypeAlias, a.name.span, true);
                },
            },
            .Assign => |*as| {
                try self.resolveExpr(scope, &as.target);
                try self.resolveExpr(scope, &as.value);
            },
            .DestructuringDecl => |*dd| {
                try self.resolveExpr(scope, &dd.init);
                for (dd.names) |n| {
                    if (std.mem.eql(u8, n.name, "_")) continue;
                    _ = try self.declare(scope, n.name, .LocalProperty, n.span, true);
                }
            },
        }
    }

    // Single dispatch over every Expr variant; arms are kept per-variant for
    // clarity and several carry explanatory comments, so identical bodies
    // and the overall length are left as-is rather than merged.
    fn resolveExpr(self: *Resolver, scope: ScopeId, expr: *const Expr) ResolveError!void {
        switch (expr.*) {
            .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Break, .Continue => {},
            .StringTemplate => |st| {
                for (st.parts) |part| {
                    switch (part) {
                        .Text => {},
                        .ShortInterp => |id| {
                            try self.resolveNameUse(scope, id.name, id.span);
                        },
                        .Interp => |*e| try self.resolveExpr(scope, e),
                    }
                }
            },
            .Path => |p| {
                if (p.segments.len > 0) {
                    const first = p.segments[0];
                    try self.resolveNameUse(scope, first.name, first.span);
                }
            },
            .Member => |m| {
                if (m.safe) {
                    try self.checkUnnecessarySafeCall(scope, m.receiver, m.span);
                }
                try self.resolveExpr(scope, m.receiver);
            },
            .Call => |c| {
                try self.resolveExpr(scope, c.callee);
                for (c.args) |*a| {
                    try self.resolveExpr(scope, a);
                }
            },
            .Index => |idx| {
                try self.resolveExpr(scope, idx.receiver);
                for (idx.args) |*a| {
                    try self.resolveExpr(scope, a);
                }
            },
            .Binary => |b| {
                try self.resolveExpr(scope, b.lhs);
                try self.resolveExpr(scope, b.rhs);
            },
            .Unary => |u| {
                try self.resolveExpr(scope, u.expr);
            },
            .Postfix => |pf| {
                try self.resolveExpr(scope, pf.expr);
            },
            .If => |iff| {
                try self.resolveExpr(scope, iff.cond);
                try self.resolveExpr(scope, iff.then_branch);
                if (iff.else_branch) |e| {
                    try self.resolveExpr(scope, e);
                }
            },
            .While => |w| {
                try self.resolveExpr(scope, w.cond);
                try self.resolveExpr(scope, w.body);
            },
            .DoWhile => |dw| {
                if (dw.body) |b| {
                    try self.resolveExpr(scope, b);
                }
                try self.resolveExpr(scope, dw.cond);
            },
            .For => |f| {
                try self.resolveExpr(scope, f.iter);
                const for_scope = try self.pushScope(scope, .Block);
                for (f.vars) |v| {
                    _ = try self.declare(for_scope, v.name, .ForVar, v.span, true);
                }
                try self.resolveExpr(for_scope, f.body);
            },
            .Return => |ret| {
                if (ret.value) |v| {
                    try self.resolveExpr(scope, v);
                }
            },
            .Labeled => |l| {
                try self.resolveExpr(scope, l.expr);
            },
            .Block => |*b| try self.resolveBlock(scope, b, true),
            .Throw => |t| try self.resolveExpr(scope, t.value),
            .Try => |t| {
                try self.resolveBlock(scope, &t.body, true);
                for (t.catches) |c| {
                    const catch_scope = try self.pushScope(scope, .Block);
                    const sym = try self.addSymbol(c.binding.name, .LocalProperty, c.binding.span);
                    try self.scopes.items[catch_scope.int()].bindings.put(c.binding.name, sym);
                    try self.resolveBlock(catch_scope, &c.body, false);
                }
                if (t.finally) |fb| {
                    try self.resolveBlock(scope, &fb, true);
                }
            },
            .Lambda => |lam| {
                const lam_scope = try self.pushScope(scope, .Block);
                for (lam.params) |p| {
                    const sym = try self.addSymbol(p.name, .Parameter, p.span);
                    try self.scopes.items[lam_scope.int()].bindings.put(p.name, sym);
                }
                try self.resolveBlock(lam_scope, &lam.body, false);
            },
            .This, .Super => {
                // No resolver-level diagnostic. The interpreter checks at
                // evaluation time whether `this` / `super` is bound.
            },
            .When => |w| {
                if (w.subject) |s| {
                    try self.resolveExpr(scope, s);
                }
                for (w.branches) |b| {
                    for (b.patterns) |*p| {
                        switch (p.kind) {
                            .Value, .InRange, .NotInRange => |*e| {
                                try self.resolveExpr(scope, e);
                            },
                            .IsType, .NotIsType, .Else => {},
                        }
                    }
                    try self.resolveExpr(scope, &b.body);
                }
            },
            .IsCheck => |ic| try self.resolveExpr(scope, ic.expr),
            .As => |a| try self.resolveExpr(scope, a.expr),
            .AnonFun => |af| {
                const fn_scope = try self.pushScope(scope, .Block);
                for (af.params) |p| {
                    const sym = try self.addSymbol(p.name.name, .Parameter, p.name.span);
                    try self.scopes.items[fn_scope.int()].bindings.put(p.name.name, sym);
                }
                if (af.body) |body| {
                    switch (body.*) {
                        .Block => |*b| try self.resolveBlock(fn_scope, b, false),
                        .Expr => |*e| try self.resolveExpr(fn_scope, e),
                    }
                }
            },
            .PropertyRef => {
                // `::name` references a property/function by name. The
                // interpreter resolves it as a lightweight metadata value,
                // so no name-use resolution is needed here.
            },
            .MemberRef => |mr| {
                try self.resolveExpr(scope, mr.receiver);
            },
            .Spread => |sp| try self.resolveExpr(scope, sp.expr),
            .ObjectExpr => |oe| {
                for (oe.supertype_args) |maybe_args| {
                    if (maybe_args) |args| {
                        for (args) |*a| {
                            try self.resolveExpr(scope, a);
                        }
                    }
                }
                for (oe.supertype_delegates) |maybe_d| {
                    if (maybe_d) |*d| {
                        try self.resolveExpr(scope, d);
                    }
                }
                // Object literal body is a declaration scope: members can
                // refer to each other regardless of source order.
                // Pre-declare every member name into a fresh scope, then
                // walk bodies against that scope.
                const body_scope = try self.pushScope(scope, .Block);
                for (oe.members) |*m| {
                    const name: []const u8, const kind: SymbolKind, const sp: Span = switch (m.*) {
                        .Function => |f| .{ f.name.name, .LocalFunction, f.name.span },
                        .Property => |p| .{ p.name.name, .LocalProperty, p.name.span },
                        .Class, .Object, .TypeAlias => continue,
                    };
                    const sym = try self.addSymbol(name, kind, sp);
                    try self.scopes.items[body_scope.int()].bindings.put(name, sym);
                }
                for (oe.members) |*m| {
                    try self.resolveMemberDecl(body_scope, m);
                }
            },
        }
    }

    fn resolveMemberDecl(self: *Resolver, scope: ScopeId, decl: *const Decl) ResolveError!void {
        switch (decl.*) {
            .Function => |*f| {
                const fn_scope = try self.pushScope(scope, .Block);
                for (f.params) |p| {
                    const sym = try self.addSymbol(p.name.name, .Parameter, p.name.span);
                    try self.scopes.items[fn_scope.int()].bindings.put(p.name.name, sym);
                }
                if (f.body) |*body| {
                    switch (body.*) {
                        .Block => |*b| try self.resolveBlock(fn_scope, b, false),
                        .Expr => |*e| try self.resolveExpr(fn_scope, e),
                    }
                }
            },
            .Property => |*p| {
                if (p.init) |*e| {
                    try self.resolveExpr(scope, e);
                }
                if (p.delegate) |*d| {
                    try self.resolveExpr(scope, d);
                }
            },
            .Class, .Object, .TypeAlias => {},
        }
    }

    /// `UNNECESSARY_SAFE_CALL`: `s?.x` on a known-non-nullable receiver is a
    /// Kotlin warning. We only flag the easy case — a single-identifier
    /// receiver whose binding was declared with an explicit non-nullable
    /// type — to avoid noise until the inference work in the type checker
    /// gives us a more complete picture.
    fn checkUnnecessarySafeCall(self: *Resolver, scope: ScopeId, receiver: *const Expr, op_span: Span) !void {
        const segments = switch (receiver.*) {
            .Path => |p| p.segments,
            else => return,
        };
        if (segments.len != 1) return;
        const name = segments[0].name;
        const sym_id = self.lookup(scope, name) orelse return;
        const nullable = self.symbols.items[sym_id.int()].nullable;
        if (nullable) |n| {
            if (!n) {
                const msg = try std.fmt.allocPrint(
                    self.strs(),
                    "Unnecessary safe call on a non-null receiver of type `{s}`",
                    .{name},
                );
                var d = Diagnostic.fromFactory(&factories.UNNECESSARY_SAFE_CALL, op_span);
                _ = d.withMessage(msg);
                _ = d.withCode("R0005");
                try self.diagnostics.emit(self.allocator, d);
            }
        }
    }

    fn resolveNameUse(self: *Resolver, scope: ScopeId, name: []const u8, sp: Span) !void {
        if (self.lookup(scope, name)) |sym| {
            try self.uses.put(sp, sym);
        } else if (self.isInsideClassBody(scope)) {
            // Inside a class / object body the name may be an inherited
            // member or a dynamic `this`-receiver lookup; defer to the
            // interpreter instead of false-positiving R0001.
        } else {
            const msg = try std.fmt.allocPrint(
                self.strs(),
                "Unresolved reference `{s}`",
                .{name},
            );
            var d = Diagnostic.err(msg, sp);
            _ = d.withCode("R0001");
            _ = d.withFactory(&factories.UNRESOLVED_REFERENCE);
            try self.diagnostics.emit(self.allocator, d);
        }
    }

    fn isInsideClassBody(self: *const Resolver, start: ScopeId) bool {
        var scope = start;
        while (true) {
            const s = &self.scopes.items[scope.int()];
            if (s.kind == .ClassBody) return true;
            if (s.parent) |p| {
                scope = p;
            } else {
                return false;
            }
        }
    }

    fn lookup(self: *const Resolver, start: ScopeId, name: []const u8) ?SymbolId {
        var scope = start;
        while (true) {
            const s = &self.scopes.items[scope.int()];
            if (s.bindings.get(name)) |id| {
                return id;
            }
            if (s.parent) |p| {
                scope = p;
            } else {
                return null;
            }
        }
    }

    fn pushScope(self: *Resolver, parent: ?ScopeId, kind: ScopeKind) !ScopeId {
        const id = ScopeId.from(@intCast(self.scopes.items.len));
        try self.scopes.append(self.allocator, .{
            .id = id,
            .parent = parent,
            .kind = kind,
            .bindings = std.StringHashMap(SymbolId).init(self.allocator),
        });
        return id;
    }

    fn addSymbol(self: *Resolver, name: []const u8, kind: SymbolKind, decl_span: ?Span) !SymbolId {
        const id = SymbolId.from(@intCast(self.symbols.items.len));
        try self.symbols.append(self.allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .decl_span = decl_span,
            .nullable = null,
        });
        return id;
    }

    /// Bind the leaf of a non-wildcard import (or its `as` alias) so use
    /// sites of an explicitly imported stdlib value resolve. Only fills a
    /// name that nothing else already binds, so a same-named
    /// local/top-level declaration always wins.
    fn bindImportLeaf(self: *Resolver, scope: ScopeId, imp: *const ImportDecl) !void {
        if (imp.wildcard or imp.path.len == 0) return;
        const leaf = if (imp.alias) |a| a.name else imp.path[imp.path.len - 1].name;
        if (self.lookup(scope, leaf) != null) return;
        const sym = try self.addSymbol(leaf, .Builtin, null);
        try self.scopes.items[scope.int()].bindings.put(leaf, sym);
    }
};

/// Join a path of identifiers with `.` separators into a freshly
/// allocated string the caller owns.
fn joinPath(allocator: std.mem.Allocator, path: []const ast.Ident) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (path, 0..) |seg, i| {
        if (i != 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, seg.name);
    }
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
//
// The resolver's dependency graph excludes the lexer/parser, so the tests
// build the `KotlinFile` AST directly with small helpers rather than parsing
// source text. The assertions mirror the upstream Rust `#[test]` cases.
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_file = span.FileId.from(0);

var next_test_off: u32 = 1;

fn ts() Span {
    const start = next_test_off;
    next_test_off += 1;
    return Span.init(test_file, start, start + 1);
}

fn ident(name: []const u8) ast.Ident {
    return .{ .name = name, .span = ts() };
}

fn typeRef(name: []const u8, nullable: bool) ast.TypeRef {
    return .{
        .name = ident(name),
        .nullable = nullable,
        .span = ts(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

fn emptyFn(name: []const u8) Function {
    return .{
        .name = ident(name),
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = null,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = ts(),
    };
}

fn emptyProp(mutable: bool, name: []const u8) Property {
    return .{
        .mutable = mutable,
        .name = ident(name),
        .receiver_type = null,
        .ty = null,
        .init = null,
        .delegate = null,
        .getter = null,
        .setter = null,
        .is_abstract = false,
        .is_open = false,
        .is_override = false,
        .is_lateinit = false,
        .is_const = false,
        .is_inline = false,
        .is_expect = false,
        .is_actual = false,
        .setter_visibility = null,
        .visibility = .Public,
        .annotations = &.{},
        .span = ts(),
    };
}

fn intParam(name: []const u8) Param {
    return .{
        .name = ident(name),
        .ty = typeRef("Int", false),
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = ts(),
    };
}

fn callExpr(callee: *Expr, args: []Expr) Expr {
    return .{ .Call = .{
        .callee = callee,
        .args = args,
        .arg_names = &.{},
        .type_args = &.{},
        .is_infix = false,
        .span = ts(),
    } };
}

fn pathExpr(name: []const u8) Expr {
    const segs = testing.allocator.alloc(ast.Ident, 1) catch unreachable;
    segs[0] = ident(name);
    return .{ .Path = .{ .segments = segs, .span = ts() } };
}

fn mkClass(name: []const u8, members: []Decl) ast.Class {
    return .{
        .name = ident(name),
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = &.{},
        .init_blocks = &.{},
        .init_block_positions = &.{},
        .supertypes = &.{},
        .supertype_args = &.{},
        .supertype_delegates = &.{},
        .is_data = false,
        .is_companion = false,
        .is_enum = false,
        .is_sealed = false,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .enum_entries = &.{},
        .members = members,
        .visibility = .Public,
        .primary_ctor_visibility = null,
        .annotations = &.{},
        .span = ts(),
    };
}

/// Collect both factory names and legacy codes from each diagnostic so
/// tests can assert against either identifier.
fn codes(allocator: std.mem.Allocator, r: *const Resolution) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    for (r.diagnostics.diags()) |d| {
        if (d.legacy_code) |c| try out.append(allocator, c);
        if (d.factory) |f| try out.append(allocator, f.name);
    }
    return out;
}

fn hasCode(list: []const []const u8, code: []const u8) bool {
    for (list) |c| {
        if (std.mem.eql(u8, c, code)) return true;
    }
    return false;
}

fn countCode(r: *const Resolution, code: []const u8) usize {
    var n: usize = 0;
    for (r.diagnostics.diags()) |d| {
        if (d.code()) |c| {
            if (std.mem.eql(u8, c, code)) n += 1;
        }
    }
    return n;
}

fn anyUseOfKind(r: *const Resolution, kind: SymbolKind) bool {
    var it = r.uses.valueIterator();
    while (it.next()) |id| {
        if (r.symbol(id.*).kind == kind) return true;
    }
    return false;
}

test "resolves forward reference between top level funs" {
    const a = testing.allocator;
    // fun main() { greet() }
    // fun greet() { println("hi") }
    var greet_callee = pathExpr("greet");
    defer a.free(greet_callee.Path.segments);
    const greet_call = callExpr(&greet_callee, &.{});
    var main_stmts = [_]Stmt{.{ .Expr = greet_call }};

    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    var str_parts = [_]StringPart{.{ .Text = "hi" }};
    var str_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = ts() } }};
    const greet_inner = callExpr(&println_callee, &str_args);
    var greet_stmts = [_]Stmt{.{ .Expr = greet_inner }};

    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &main_stmts, .span = ts() } };
    var greet_fn = emptyFn("greet");
    greet_fn.body = .{ .Block = .{ .stmts = &greet_stmts, .span = ts() } };

    var decls = [_]Decl{ .{ .Function = main_fn }, .{ .Function = greet_fn } };
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
}

test "resolves println as builtin" {
    const a = testing.allocator;
    // fun main() { println("hi") }
    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    var str_parts = [_]StringPart{.{ .Text = "hi" }};
    var str_args = [_]Expr{.{ .StringTemplate = .{ .parts = &str_parts, .span = ts() } }};
    const call = callExpr(&println_callee, &str_args);
    var stmts = [_]Stmt{.{ .Expr = call }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(anyUseOfKind(&r, .Builtin));
}

test "unresolved identifier emits r0001" {
    const a = testing.allocator;
    // fun main() { println(banana) }
    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    const banana = pathExpr("banana");
    defer a.free(banana.Path.segments);
    var args = [_]Expr{banana};
    const call = callExpr(&println_callee, &args);
    var stmts = [_]Stmt{.{ .Expr = call }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(hasCode(cs.items, "R0001"));
}

test "non kotlin import emits r0003" {
    const a = testing.allocator;
    // import com.example.Thing
    // fun main() {}
    var imp_path = [_]ast.Ident{ ident("com"), ident("example"), ident("Thing") };
    var imports = [_]ImportDecl{.{ .path = &imp_path, .alias = null, .wildcard = false, .span = ts() }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &.{}, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &imports, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(hasCode(cs.items, "R0003"));
}

test "kotlin import is accepted" {
    const a = testing.allocator;
    // import kotlin.math.PI
    // fun main() {}
    var imp_path = [_]ast.Ident{ ident("kotlin"), ident("math"), ident("PI") };
    var imports = [_]ImportDecl{.{ .path = &imp_path, .alias = null, .wildcard = false, .span = ts() }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &.{}, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &imports, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(!hasCode(cs.items, "R0003"));
}

test "duplicate top level emits r0004" {
    const a = testing.allocator;
    // fun foo() {}
    // fun foo() {}
    var foo1 = emptyFn("foo");
    foo1.body = .{ .Block = .{ .stmts = &.{}, .span = ts() } };
    var foo2 = emptyFn("foo");
    foo2.body = .{ .Block = .{ .stmts = &.{}, .span = ts() } };
    var decls = [_]Decl{ .{ .Function = foo1 }, .{ .Function = foo2 } };
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(hasCode(cs.items, "R0004"));
}

test "shadowing in inner scope emits r0002" {
    const a = testing.allocator;
    // fun main() {
    //     val x = 1
    //     val x = 2
    //     println(x)
    // }
    var x1 = emptyProp(false, "x");
    x1.init = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };
    var x2 = emptyProp(false, "x");
    x2.init = .{ .IntLit = .{ .value = 2, .kind = .Int, .span = ts() } };

    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    const x_use = pathExpr("x");
    defer a.free(x_use.Path.segments);
    var args = [_]Expr{x_use};
    const call = callExpr(&println_callee, &args);

    var stmts = [_]Stmt{
        .{ .Decl = .{ .Property = x1 } },
        .{ .Decl = .{ .Property = x2 } },
        .{ .Expr = call },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(hasCode(cs.items, "R0002"));
}

test "for loop variable is resolvable in body" {
    const a = testing.allocator;
    // fun main() {
    //     for (i in 1..3) { println(i) }
    // }
    var one = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };
    var three = Expr{ .IntLit = .{ .value = 3, .kind = .Int, .span = ts() } };
    var range = Expr{ .Binary = .{ .op = .Range, .lhs = &one, .rhs = &three, .span = ts() } };

    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    const i_use = pathExpr("i");
    defer a.free(i_use.Path.segments);
    var args = [_]Expr{i_use};
    const call = callExpr(&println_callee, &args);
    var body_stmts = [_]Stmt{.{ .Expr = call }};
    var body = Expr{ .Block = .{ .stmts = &body_stmts, .span = ts() } };

    var vars = [_]ast.Ident{ident("i")};
    const for_expr = Expr{ .For = .{
        .vars = &vars,
        .var_ty = null,
        .iter = &range,
        .body = &body,
        .span = ts(),
    } };
    var stmts = [_]Stmt{.{ .Expr = for_expr }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
    try testing.expect(anyUseOfKind(&r, .ForVar));
}

test "function parameter resolves inside body" {
    const a = testing.allocator;
    // fun id(x: Int): Int = x
    const x_use = pathExpr("x");
    defer a.free(x_use.Path.segments);
    var params = [_]Param{intParam("x")};
    var id_fn = emptyFn("id");
    id_fn.params = &params;
    id_fn.return_type = typeRef("Int", false);
    id_fn.body = .{ .Expr = x_use };
    var decls = [_]Decl{.{ .Function = id_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
    try testing.expect(anyUseOfKind(&r, .Parameter));
}

test "mutual recursion resolves" {
    const a = testing.allocator;
    // fun even(n: Int): Boolean = if (n == 0) true else odd(n - 1)
    // fun odd(n: Int): Boolean = if (n == 0) false else even(n - 1)
    // even body
    var even_n = pathExpr("n");
    defer a.free(even_n.Path.segments);
    var even_zero = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = ts() } };
    var even_cond = Expr{ .Binary = .{ .op = .Eq, .lhs = &even_n, .rhs = &even_zero, .span = ts() } };
    var even_then = Expr{ .BoolLit = .{ .value = true, .span = ts() } };
    var odd_callee = pathExpr("odd");
    defer a.free(odd_callee.Path.segments);
    var even_n2 = pathExpr("n");
    defer a.free(even_n2.Path.segments);
    var even_one = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };
    const even_sub = Expr{ .Binary = .{ .op = .Sub, .lhs = &even_n2, .rhs = &even_one, .span = ts() } };
    var even_args = [_]Expr{even_sub};
    var even_else = callExpr(&odd_callee, &even_args);
    const even_if = Expr{ .If = .{ .cond = &even_cond, .then_branch = &even_then, .else_branch = &even_else, .span = ts() } };

    var n_param = [_]Param{intParam("n")};
    var even_fn = emptyFn("even");
    even_fn.params = &n_param;
    even_fn.return_type = typeRef("Boolean", false);
    even_fn.body = .{ .Expr = even_if };

    // odd body
    var odd_n = pathExpr("n");
    defer a.free(odd_n.Path.segments);
    var odd_zero = Expr{ .IntLit = .{ .value = 0, .kind = .Int, .span = ts() } };
    var odd_cond = Expr{ .Binary = .{ .op = .Eq, .lhs = &odd_n, .rhs = &odd_zero, .span = ts() } };
    var odd_then = Expr{ .BoolLit = .{ .value = false, .span = ts() } };
    var even_callee = pathExpr("even");
    defer a.free(even_callee.Path.segments);
    var odd_n2 = pathExpr("n");
    defer a.free(odd_n2.Path.segments);
    var odd_one = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };
    const odd_sub = Expr{ .Binary = .{ .op = .Sub, .lhs = &odd_n2, .rhs = &odd_one, .span = ts() } };
    var odd_args = [_]Expr{odd_sub};
    var odd_else = callExpr(&even_callee, &odd_args);
    const odd_if = Expr{ .If = .{ .cond = &odd_cond, .then_branch = &odd_then, .else_branch = &odd_else, .span = ts() } };

    var n_param2 = [_]Param{intParam("n")};
    var odd_fn = emptyFn("odd");
    odd_fn.params = &n_param2;
    odd_fn.return_type = typeRef("Boolean", false);
    odd_fn.body = .{ .Expr = odd_if };

    var decls = [_]Decl{ .{ .Function = even_fn }, .{ .Function = odd_fn } };
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
}

test "unnecessary safe call on non nullable" {
    const a = testing.allocator;
    // fun main() {
    //     val s: String = "hi"
    //     val n = s?.length
    // }
    var str_parts = [_]StringPart{.{ .Text = "hi" }};
    var s_prop = emptyProp(false, "s");
    s_prop.ty = typeRef("String", false);
    s_prop.init = .{ .StringTemplate = .{ .parts = &str_parts, .span = ts() } };

    var s_recv = pathExpr("s");
    defer a.free(s_recv.Path.segments);
    const member = Expr{ .Member = .{
        .receiver = &s_recv,
        .name = ident("length"),
        .safe = true,
        .span = ts(),
    } };
    var n_prop = emptyProp(false, "n");
    n_prop.init = member;

    var stmts = [_]Stmt{
        .{ .Decl = .{ .Property = s_prop } },
        .{ .Decl = .{ .Property = n_prop } },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expectEqual(@as(usize, 1), countCode(&r, "UNNECESSARY_SAFE_CALL"));
}

test "safe call on nullable is silent" {
    const a = testing.allocator;
    // fun main() {
    //     val s: String? = null
    //     val n = s?.length
    // }
    var s_prop = emptyProp(false, "s");
    s_prop.ty = typeRef("String", true);
    s_prop.init = .{ .NullLit = .{ .span = ts() } };

    var s_recv = pathExpr("s");
    defer a.free(s_recv.Path.segments);
    const member = Expr{ .Member = .{
        .receiver = &s_recv,
        .name = ident("length"),
        .safe = true,
        .span = ts(),
    } };
    var n_prop = emptyProp(false, "n");
    n_prop.init = member;

    var stmts = [_]Stmt{
        .{ .Decl = .{ .Property = s_prop } },
        .{ .Decl = .{ .Property = n_prop } },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expectEqual(@as(usize, 0), countCode(&r, "UNNECESSARY_SAFE_CALL"));
}

test "class member sibling reference resolves" {
    const a = testing.allocator;
    // class C {
    //     fun a(): Int = b() + 1
    //     fun b(): Int = 10
    // }
    // fun main() { println(C().a()) }
    var b_callee = pathExpr("b");
    defer a.free(b_callee.Path.segments);
    var b_call = callExpr(&b_callee, &.{});
    var one = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };
    const add = Expr{ .Binary = .{ .op = .Add, .lhs = &b_call, .rhs = &one, .span = ts() } };
    var a_fn = emptyFn("a");
    a_fn.return_type = typeRef("Int", false);
    a_fn.body = .{ .Expr = add };

    const ten = Expr{ .IntLit = .{ .value = 10, .kind = .Int, .span = ts() } };
    var b_fn = emptyFn("b");
    b_fn.return_type = typeRef("Int", false);
    b_fn.body = .{ .Expr = ten };

    var members = [_]Decl{ .{ .Function = a_fn }, .{ .Function = b_fn } };
    const class_c = mkClass("C", &members);

    // main: println(C().a())
    var c_ctor_callee = pathExpr("C");
    defer a.free(c_ctor_callee.Path.segments);
    var c_ctor = callExpr(&c_ctor_callee, &.{});
    var a_member = Expr{ .Member = .{
        .receiver = &c_ctor,
        .name = ident("a"),
        .safe = false,
        .span = ts(),
    } };
    const a_call = callExpr(&a_member, &.{});
    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    var println_args = [_]Expr{a_call};
    const println_call = callExpr(&println_callee, &println_args);
    var main_stmts = [_]Stmt{.{ .Expr = println_call }};
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &main_stmts, .span = ts() } };

    var decls = [_]Decl{ .{ .Class = class_c }, .{ .Function = main_fn } };
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
}

test "forward reference to local val in statement scope errors" {
    const a = testing.allocator;
    // fun main() {
    //     println(x)
    //     val x = 1
    // }
    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    const x_use = pathExpr("x");
    defer a.free(x_use.Path.segments);
    var args = [_]Expr{x_use};
    const call = callExpr(&println_callee, &args);

    var x_prop = emptyProp(false, "x");
    x_prop.init = .{ .IntLit = .{ .value = 1, .kind = .Int, .span = ts() } };

    var stmts = [_]Stmt{
        .{ .Expr = call },
        .{ .Decl = .{ .Property = x_prop } },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    var cs = try codes(a, &r);
    defer cs.deinit(a);
    try testing.expect(hasCode(cs.items, "R0001"));
}

test "object literal member forward reference resolves" {
    const a = testing.allocator;
    // interface Greeter { fun hello(): String }
    // fun main() {
    //     val g = object : Greeter {
    //         override fun hello() = name
    //         val name = "world"
    //     }
    //     println(g.hello())
    // }
    var hello_abstract = emptyFn("hello");
    hello_abstract.return_type = typeRef("String", false);
    var greeter_members = [_]Decl{.{ .Function = hello_abstract }};
    var greeter = mkClass("Greeter", &greeter_members);
    greeter.is_interface = true;

    // object body
    const name_use = pathExpr("name");
    defer a.free(name_use.Path.segments);
    var hello_impl = emptyFn("hello");
    hello_impl.is_override = true;
    hello_impl.body = .{ .Expr = name_use };

    var str_parts = [_]StringPart{.{ .Text = "world" }};
    var name_prop = emptyProp(false, "name");
    name_prop.init = .{ .StringTemplate = .{ .parts = &str_parts, .span = ts() } };

    var obj_members = [_]Decl{
        .{ .Function = hello_impl },
        .{ .Property = name_prop },
    };
    var greeter_super = [_]ast.TypeRef{typeRef("Greeter", false)};
    var super_args = [_]?[]Expr{null};
    var super_delegates = [_]?Expr{null};
    const obj_expr = Expr{ .ObjectExpr = .{
        .supertypes = &greeter_super,
        .supertype_args = &super_args,
        .supertype_delegates = &super_delegates,
        .members = &obj_members,
        .span = ts(),
    } };
    var g_prop = emptyProp(false, "g");
    g_prop.init = obj_expr;

    // println(g.hello())
    var g_recv = pathExpr("g");
    defer a.free(g_recv.Path.segments);
    var hello_member = Expr{ .Member = .{
        .receiver = &g_recv,
        .name = ident("hello"),
        .safe = false,
        .span = ts(),
    } };
    const hello_call = callExpr(&hello_member, &.{});
    var println_callee = pathExpr("println");
    defer a.free(println_callee.Path.segments);
    var println_args = [_]Expr{hello_call};
    const println_call = callExpr(&println_callee, &println_args);

    var main_stmts = [_]Stmt{
        .{ .Decl = .{ .Property = g_prop } },
        .{ .Expr = println_call },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &main_stmts, .span = ts() } };

    var decls = [_]Decl{ .{ .Class = greeter }, .{ .Function = main_fn } };
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expect(!r.diagnostics.hasErrors());
}

test "safe call without annotation is silent" {
    const a = testing.allocator;
    // fun main() {
    //     val s = "hi"
    //     val n = s?.length
    // }
    var str_parts = [_]StringPart{.{ .Text = "hi" }};
    var s_prop = emptyProp(false, "s");
    s_prop.init = .{ .StringTemplate = .{ .parts = &str_parts, .span = ts() } };

    var s_recv = pathExpr("s");
    defer a.free(s_recv.Path.segments);
    const member = Expr{ .Member = .{
        .receiver = &s_recv,
        .name = ident("length"),
        .safe = true,
        .span = ts(),
    } };
    var n_prop = emptyProp(false, "n");
    n_prop.init = member;

    var stmts = [_]Stmt{
        .{ .Decl = .{ .Property = s_prop } },
        .{ .Decl = .{ .Property = n_prop } },
    };
    var main_fn = emptyFn("main");
    main_fn.body = .{ .Block = .{ .stmts = &stmts, .span = ts() } };
    var decls = [_]Decl{.{ .Function = main_fn }};
    const file = KotlinFile{ .package = null, .imports = &.{}, .decls = &decls, .span = ts() };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var r = try resolve(arena.allocator(), &file);
    try testing.expectEqual(@as(usize, 0), countCode(&r, "UNNECESSARY_SAFE_CALL"));
}
