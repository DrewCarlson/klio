//! Name resolution.
//!
//! Walks a parsed `KotlinFile` and produces a side-table that maps every
//! name-use site (`Span`) to the declaration it refers to. Top-level
//! functions and properties are forward-declared so the interpreter's
//! observed evaluation order is preserved. Builtins like `println` and
//! `print` resolve to `Symbol::Builtin` without a declaration site.

use std::collections::HashMap;

use klio_ast::{
    Block, Decl, Expr, Function, FunctionBody, ImportDecl, KotlinFile, Param, Property, Stmt,
    StringPart,
};
use klio_diagnostics::{Diagnostic, DiagnosticSink};
use klio_span::Span;

/// Stable identifier for a resolver-tracked symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SymbolId(pub u32);

/// Kinds of symbols the resolver knows about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SymbolKind {
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
}

/// A single declaration the resolver tracks.
#[derive(Debug, Clone)]
pub struct Symbol {
    pub id: SymbolId,
    pub name: String,
    pub kind: SymbolKind,
    /// Source span of the declaration. `None` for builtins.
    pub decl_span: Option<Span>,
    /// Whether the symbol's declared type is nullable (`T?`). `None` means
    /// the resolver doesn't know (no annotation, inference deferred).
    pub nullable: Option<bool>,
}

/// Lexical scope tree. Each scope has a parent (except the file scope), a
/// kind tag for diagnostics, and a flat name table.
#[derive(Debug, Clone)]
pub struct Scope {
    pub id: ScopeId,
    pub parent: Option<ScopeId>,
    pub kind: ScopeKind,
    pub bindings: HashMap<String, SymbolId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ScopeId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeKind {
    Builtins,
    File,
    Function,
    Block,
    /// Class / object body. Spec §6.1: a declaration scope holding all
    /// member names. Names inside member bodies that don't resolve here
    /// or in an enclosing scope are *not* an R0001 error — they may be
    /// inherited from a supertype or resolved against `this` at runtime.
    ClassBody,
}

/// Output of name resolution.
#[derive(Debug)]
pub struct Resolution {
    pub scopes: Vec<Scope>,
    pub symbols: Vec<Symbol>,
    /// Map from name-use site (`Span` of the referenced identifier) to the
    /// symbol it resolves to.
    pub uses: HashMap<Span, SymbolId>,
    pub diagnostics: DiagnosticSink,
}

impl Resolution {
    #[must_use]
    pub fn symbol(&self, id: SymbolId) -> &Symbol {
        &self.symbols[id.0 as usize]
    }

    #[must_use]
    pub fn scope(&self, id: ScopeId) -> &Scope {
        &self.scopes[id.0 as usize]
    }

    /// Look up the symbol a given name-use span resolves to.
    #[must_use]
    pub fn resolved(&self, use_span: Span) -> Option<&Symbol> {
        self.uses.get(&use_span).map(|id| self.symbol(*id))
    }
}

const BUILTINS: &[&str] = &[
    "println", "print",
    // Stdlib scope functions with contracts (§12.2.5).
    "run", "with", "check", "require", "repeat", "contract",
    // Threads / monitors. `synchronized` is in `kotlin` (implicitly
    // imported); `thread` lives in `kotlin.concurrent` and is reached
    // via `import kotlin.concurrent.thread`, but the use site is a
    // bare name either way so it resolves through the builtins scope.
    // `Thread` is the class whose statics (`Thread.sleep`,
    // `Thread.currentThread`) resolve through the builtins scope as a
    // bare name.
    "synchronized", "thread", "Thread",
    // Spec §14.5 builder-style inference entry points. Typeck threads the
    // lambda body through `check_builder_call` so member references on the
    // implicit receiver (e.g. `add`, `put`) resolve through the receiver's
    // class table.
    "buildList", "buildMap", "buildSet", "sequence", "iterator",
];

/// Resolve a parsed file. The returned `Resolution` always contains a
/// builtins scope and a file scope, even if the input has no declarations.
#[must_use]
pub fn resolve(file: &KotlinFile) -> Resolution {
    let mut r = Resolver::new();
    r.run(file);
    Resolution {
        scopes: r.scopes,
        symbols: r.symbols,
        uses: r.uses,
        diagnostics: r.diagnostics,
    }
}

/// Resolve a multi-file module. Every file's top-level declarations
/// share a module-level scope, but each file applies its own imports
/// only inside its own decls (file-local import scoping per spec
/// §10.1). Use-spans across files remain distinguishable through the
/// `klio_span::FileId` carried on each Span.
pub fn resolve_module(files: &[KotlinFile]) -> Resolution {
    let mut r = Resolver::new();
    let builtins = ScopeId(0);
    let module_scope = r.push_scope(Some(builtins), ScopeKind::File);
    // Phase 1: forward-declare every file's top-level decls into the
    // shared module scope so cross-file references resolve.
    for file in files {
        r.file_package = file.package.as_ref().map(|p| {
            p.path.iter().map(|s| s.name.clone()).collect::<Vec<_>>().join(".")
        });
        for decl in &file.decls {
            r.declare_top_level(module_scope, decl);
        }
    }
    // Phase 2: per-file pass that applies that file's imports inside
    // a fresh child of the module scope, then resolves decl bodies.
    for file in files {
        r.file_package = file.package.as_ref().map(|p| {
            p.path.iter().map(|s| s.name.clone()).collect::<Vec<_>>().join(".")
        });
        let file_scope = r.push_scope(Some(module_scope), ScopeKind::File);
        for imp in &file.imports {
            r.check_import(imp);
        }
        for decl in &file.decls {
            r.resolve_decl(file_scope, decl, /*is_top_level=*/ true);
        }
    }
    Resolution {
        scopes: r.scopes,
        symbols: r.symbols,
        uses: r.uses,
        diagnostics: r.diagnostics,
    }
}

struct Resolver {
    scopes: Vec<Scope>,
    symbols: Vec<Symbol>,
    uses: HashMap<Span, SymbolId>,
    diagnostics: DiagnosticSink,
    /// Dotted package name from the file's `package` header, if any.
    file_package: Option<String>,
    /// Top-level function signature keys already declared, per
    /// `(scope, name, arity, param-type-names)`. Lets overloads with
    /// distinct signatures coexist while still flagging an exact
    /// duplicate (`fun foo()` declared twice) as a redeclaration.
    fn_sig_keys: std::collections::HashSet<(u32, String)>,
}

impl Resolver {
    fn new() -> Self {
        let mut r = Self {
            scopes: Vec::new(),
            symbols: Vec::new(),
            uses: HashMap::new(),
            diagnostics: DiagnosticSink::new(),
            file_package: None,
            fn_sig_keys: std::collections::HashSet::new(),
        };
        let builtins = r.push_scope(None, ScopeKind::Builtins);
        for name in BUILTINS {
            let sym = r.add_symbol((*name).into(), SymbolKind::Builtin, None);
            r.scopes[builtins.0 as usize]
                .bindings
                .insert((*name).into(), sym);
        }
        r
    }

    fn run(&mut self, file: &KotlinFile) {
        let builtins = ScopeId(0);
        let file_scope = self.push_scope(Some(builtins), ScopeKind::File);

        self.file_package = file
            .package
            .as_ref()
            .map(|p| p.path.iter().map(|s| s.name.clone()).collect::<Vec<_>>().join("."));

        for imp in &file.imports {
            self.check_import(imp);
        }

        // Forward-declare every top-level decl so order doesn't matter.
        for decl in &file.decls {
            self.declare_top_level(file_scope, decl);
        }

        for decl in &file.decls {
            self.resolve_decl(file_scope, decl, /*is_top_level=*/ true);
        }
    }

    fn check_import(&mut self, imp: &ImportDecl) {
        if imp.path.is_empty() {
            // Parser already emitted P0047; nothing further to validate.
            return;
        }
        let own_pkg = self.file_package.clone();
        let path_owned: Vec<String> =
            imp.path.iter().map(|seg| seg.name.clone()).collect();
        let path_str = path_owned.join(".");

        // Importing from the file's own package is permitted by the spec and
        // is effectively a no-op (entities of the same package are already
        // visible). Skip diagnostics for that case.
        if let Some(own) = &own_pkg {
            let same_package = if imp.wildcard {
                path_str == *own
            } else {
                // For a non-wildcard import, the package is the path minus
                // the trailing entity segment.
                path_owned
                    .split_last()
                    .map_or(false, |(_, prefix)| prefix.join(".") == *own)
            };
            if same_package {
                return;
            }
        }

        if path_owned[0] != "kotlin" {
            // Non-`kotlin.*` import. Permitted when a loaded pack has
            // registered the package (e.g. `kotlinx.coroutines`,
            // `kotlinx.io`). The candidate package is the path itself
            // for a wildcard import, else the path minus the trailing
            // entity segment.
            let candidate_pkg = if imp.wildcard {
                path_str.clone()
            } else if path_owned.len() >= 2 {
                path_owned[..path_owned.len() - 1].join(".")
            } else {
                path_str.clone()
            };
            if !klio_stdlib::is_known_package(&candidate_pkg) {
                self.diagnostics.emit(
                    Diagnostic::error(
                        format!("no package `{path_str}` is known to this build"),
                        imp.span,
                    )
                    .with_code("R0003")
                    .with_note(
                        "only the `kotlin.*` standard library and installed \
                         packs are available",
                    ),
                );
            }
            return;
        }

        // Path starts with `kotlin`. Validate that the *package portion* is one
        // of the implicitly imported packages we know about. For a wildcard the
        // path is the package itself; for a regular import the package is the
        // path minus the entity segment.
        let candidate_pkg = if imp.wildcard {
            path_str.clone()
        } else if path_owned.len() >= 2 {
            path_owned[..path_owned.len() - 1].join(".")
        } else {
            // `import kotlin` — the whole path is just the package, which
            // matches an implicitly imported package, so let it pass.
            path_str.clone()
        };
        if !klio_stdlib::is_known_package(&candidate_pkg) {
            self.diagnostics.emit(
                Diagnostic::error(
                    format!("no package `{candidate_pkg}` is known to this build"),
                    imp.span,
                )
                .with_code("R0012")
                .with_note(
                    "klio implements the `kotlin.*` standard library packages \
                    mined from upstream Kotlin; see docs/STDLIB.md",
                ),
            );
        }
    }

    fn declare_top_level(&mut self, scope: ScopeId, decl: &Decl) {
        // Extension *functions* are also bound by their bare name as
        // a tolerant fallback: inside a receiver-typed lambda the
        // implicit receiver makes `launch { … }` / `async { … }`
        // (extensions on `CoroutineScope`) callable without an
        // explicit qualifier, and the resolver has no receiver-type
        // info at this pre-typeck stage. Functions never conflict on
        // name alone (overloads), so the bare binding is safe and
        // prevents spurious UNRESOLVED_REFERENCE on valid code. The
        // qualified `recv.ext()` path resolves independently.
        if let Decl::Property(p) = decl {
            if p.receiver_type.is_some() {
                return;
            }
        }
        let (name, kind, span) = match decl {
            Decl::Function(f) => (f.name.name.clone(), SymbolKind::TopLevelFunction, f.name.span),
            Decl::Property(p) => (p.name.name.clone(), SymbolKind::TopLevelProperty, p.name.span),
            Decl::Class(c) => (c.name.name.clone(), SymbolKind::Class, c.name.span),
            Decl::Object(o) => (o.name.name.clone(), SymbolKind::Class, o.name.span),
            Decl::TypeAlias(a) => (a.name.name.clone(), SymbolKind::TypeAlias, a.name.span),
        };
        // Kotlin permits multiple top-level functions to share a
        // name (overloads) and a factory function to share a name
        // with a class/interface (`fun CoroutineScope(...)` +
        // `interface CoroutineScope`). Only an *exact* duplicate
        // signature (`fun foo()` declared twice) is a redeclaration;
        // distinct overloads and factory-fn/class name sharing are
        // legal and disambiguated later by overload resolution.
        if let Decl::Function(f) = decl {
            let mut key = format!("{name}#{}", f.params.len());
            for p in &f.params {
                key.push('|');
                key.push_str(&p.ty.name.name);
            }
            let sig = (scope.0, key);
            if self.fn_sig_keys.contains(&sig) {
                let prev_span = self.scopes[scope.0 as usize]
                    .bindings
                    .get(&name)
                    .and_then(|id| self.symbols[id.0 as usize].decl_span);
                let mut d = Diagnostic::error(
                    format!(
                        "Conflicting declarations: duplicate top-level declaration `{name}`"
                    ),
                    span,
                )
                .with_code("R0004")
                .with_factory(&klio_diagnostics::generated::factories::REDECLARATION);
                if let Some(ps) = prev_span {
                    d = d.with_label(ps, "previous declaration here");
                }
                self.diagnostics.emit(d);
            }
            self.fn_sig_keys.insert(sig);
            let id = self.add_symbol(name.clone(), kind, Some(span));
            self.scopes[scope.0 as usize].bindings.insert(name, id);
            return;
        }
        // A non-function sharing a name with an existing function
        // (or vice-versa) is the legal factory pattern — bind
        // without a conflict diagnostic.
        let func_involved = self.scopes[scope.0 as usize]
            .bindings
            .get(&name)
            .map(|id| {
                matches!(
                    self.symbols[id.0 as usize].kind,
                    SymbolKind::TopLevelFunction
                )
            })
            .unwrap_or(false);
        if func_involved {
            let id = self.add_symbol(name.clone(), kind, Some(span));
            self.scopes[scope.0 as usize].bindings.insert(name, id);
            return;
        }
        self.declare(scope, name, kind, span, /*allow_shadow=*/ false);
    }

    fn declare(
        &mut self,
        scope: ScopeId,
        name: String,
        kind: SymbolKind,
        span: Span,
        allow_shadow: bool,
    ) -> SymbolId {
        // Duplicate-in-same-scope is always an error at file scope; for inner
        // scopes we permit redeclaration but emit a shadowing warning.
        let existing = self.scopes[scope.0 as usize].bindings.get(&name).copied();
        if let Some(prev_id) = existing {
            let prev_kind = self.scopes[scope.0 as usize].kind;
            if matches!(prev_kind, ScopeKind::File) {
                let prev_span = self.symbols[prev_id.0 as usize].decl_span;
                let mut d = Diagnostic::error(
                    format!("Conflicting declarations: duplicate top-level declaration `{name}`"),
                    span,
                )
                .with_code("R0004")
                .with_factory(&klio_diagnostics::generated::factories::REDECLARATION);
                if let Some(ps) = prev_span {
                    d = d.with_label(ps, "previous declaration here");
                }
                self.diagnostics.emit(d);
            } else if allow_shadow {
                // Same-scope redeclaration in a block. Treat as shadow warning.
                self.diagnostics.emit(
                    Diagnostic::warning(format!("`{name}` shadows an earlier binding"), span)
                        .with_code("R0002"),
                );
            }
        }
        let id = self.add_symbol(name.clone(), kind, Some(span));
        self.scopes[scope.0 as usize].bindings.insert(name, id);
        id
    }

    fn resolve_decl(&mut self, scope: ScopeId, decl: &Decl, is_top_level: bool) {
        match decl {
            Decl::Function(f) => self.resolve_function(scope, f),
            Decl::Property(p) => self.resolve_property(scope, p, is_top_level),
            Decl::Class(c) => self.resolve_class_body(scope, &c.primary_params, &c.init_blocks, &c.members),
            Decl::Object(o) => self.resolve_class_body(scope, &[], &[], &o.members),
            Decl::TypeAlias(_) => {
                // The aliased type is resolved by the type checker; no
                // name-use sites inside a typealias target need symbol
                // bindings here.
            }
        }
    }

    /// Walk a class / object body. Spec §6.1: the body is a declaration
    /// scope — every member is visible to every other member regardless
    /// of source order. We pre-declare members into a fresh class scope,
    /// then walk each body. Unresolved bare names inside this scope are
    /// *not* errors: they may be inherited members or `this.x` lookups
    /// that the runtime resolves dynamically.
    fn resolve_class_body(
        &mut self,
        parent: ScopeId,
        primary_params: &[klio_ast::ClassParam],
        init_blocks: &[Block],
        members: &[Decl],
    ) {
        let body_scope = self.push_scope(Some(parent), ScopeKind::ClassBody);
        for p in primary_params {
            let sym = self.add_symbol(
                p.name.name.clone(),
                if p.property.is_some() { SymbolKind::LocalProperty } else { SymbolKind::Parameter },
                Some(p.name.span),
            );
            self.scopes[body_scope.0 as usize].bindings.insert(p.name.name.clone(), sym);
        }
        for m in members {
            let (name, kind, span) = match m {
                Decl::Function(f) => {
                    if f.receiver_type.is_some() {
                        continue;
                    }
                    (f.name.name.clone(), SymbolKind::LocalFunction, f.name.span)
                }
                Decl::Property(p) => {
                    if p.receiver_type.is_some() {
                        continue;
                    }
                    (p.name.name.clone(), SymbolKind::LocalProperty, p.name.span)
                }
                Decl::Class(c) => (c.name.name.clone(), SymbolKind::Class, c.name.span),
                Decl::Object(o) => (o.name.name.clone(), SymbolKind::Class, o.name.span),
                Decl::TypeAlias(a) => (a.name.name.clone(), SymbolKind::TypeAlias, a.name.span),
            };
            let sym = self.add_symbol(name.clone(), kind, Some(span));
            self.scopes[body_scope.0 as usize].bindings.insert(name, sym);
        }
        for b in init_blocks {
            self.resolve_block(body_scope, b, /*new_scope=*/ false);
        }
        for m in members {
            self.resolve_decl(body_scope, m, /*is_top_level=*/ false);
        }
    }

    fn resolve_function(&mut self, parent: ScopeId, f: &Function) {
        let fn_scope = self.push_scope(Some(parent), ScopeKind::Function);
        for p in &f.params {
            self.resolve_param(fn_scope, p);
        }
        if let Some(body) = &f.body {
            match body {
                FunctionBody::Block(b) => self.resolve_block(fn_scope, b, /*new_scope=*/ false),
                FunctionBody::Expr(e) => self.resolve_expr(fn_scope, e),
            }
        }
    }

    fn resolve_param(&mut self, scope: ScopeId, p: &Param) {
        self.declare(scope, p.name.name.clone(), SymbolKind::Parameter, p.name.span, true);
        if let Some(default) = &p.default {
            self.resolve_expr(scope, default);
        }
    }

    fn resolve_property(&mut self, scope: ScopeId, p: &Property, _is_top_level: bool) {
        if let Some(ty) = &p.ty {
            if let Some(id) = self.scopes[scope.0 as usize].bindings.get(&p.name.name) {
                self.symbols[id.0 as usize].nullable = Some(ty.nullable);
            }
        }
        if let Some(init) = &p.init {
            self.resolve_expr(scope, init);
        }
        if let Some(getter) = &p.getter {
            self.resolve_accessor(scope, getter);
        }
        if let Some(setter) = &p.setter {
            self.resolve_accessor(scope, setter);
        }
    }

    fn resolve_accessor(&mut self, parent: ScopeId, acc: &klio_ast::Accessor) {
        let scope = self.push_scope(Some(parent), ScopeKind::Function);
        for p in &acc.params {
            self.declare(scope, p.name.clone(), SymbolKind::Parameter, p.span, true);
        }
        match &acc.body {
            FunctionBody::Block(b) => self.resolve_block(scope, b, /*new_scope=*/ false),
            FunctionBody::Expr(e) => self.resolve_expr(scope, e),
        }
    }

    fn resolve_block(&mut self, parent: ScopeId, block: &Block, new_scope: bool) {
        let scope = if new_scope {
            self.push_scope(Some(parent), ScopeKind::Block)
        } else {
            parent
        };
        // Spec §6: local functions in a statement scope are visible to
        // sibling statements regardless of declaration order, so mutual
        // recursion works. Pre-declare every local `fun` name into the
        // block scope before walking statement bodies. `val` / `var` keep
        // their strict order-of-appearance binding.
        for s in &block.stmts {
            if let Stmt::Decl(Decl::Function(f)) = s {
                let _ = self.declare(
                    scope,
                    f.name.name.clone(),
                    SymbolKind::LocalFunction,
                    f.name.span,
                    true,
                );
            }
        }
        for s in &block.stmts {
            self.resolve_stmt(scope, s);
        }
    }

    fn resolve_stmt(&mut self, scope: ScopeId, stmt: &Stmt) {
        match stmt {
            Stmt::Expr(e) => self.resolve_expr(scope, e),
            Stmt::Decl(d) => match d {
                Decl::Function(f) => {
                    // Name is pre-declared by `resolve_block`; resolve body.
                    self.resolve_function(scope, f);
                }
                Decl::Property(p) => {
                    if let Some(init) = &p.init {
                        self.resolve_expr(scope, init);
                    }
                    let id = self.declare(
                        scope,
                        p.name.name.clone(),
                        SymbolKind::LocalProperty,
                        p.name.span,
                        true,
                    );
                    if let Some(ty) = &p.ty {
                        self.symbols[id.0 as usize].nullable = Some(ty.nullable);
                    }
                }
                Decl::Class(_) | Decl::Object(_) => {}
                Decl::TypeAlias(a) => {
                    // Local-scope typealias — declare the name so subsequent
                    // typeck can flag T0039. The target type has no
                    // name-use sites the resolver tracks today.
                    let _ = self.declare(
                        scope,
                        a.name.name.clone(),
                        SymbolKind::TypeAlias,
                        a.name.span,
                        true,
                    );
                }
            },
            Stmt::Assign { target, value, .. } => {
                self.resolve_expr(scope, target);
                self.resolve_expr(scope, value);
            }
            Stmt::DestructuringDecl { names, init, .. } => {
                self.resolve_expr(scope, init);
                for n in names {
                    if n.name == "_" {
                        continue;
                    }
                    let _ = self.declare(
                        scope,
                        n.name.clone(),
                        SymbolKind::LocalProperty,
                        n.span,
                        true,
                    );
                }
            }
        }
    }

    fn resolve_expr(&mut self, scope: ScopeId, expr: &Expr) {
        match expr {
            Expr::IntLit { .. }
            | Expr::FloatLit { .. }
            | Expr::BoolLit { .. }
            | Expr::NullLit { .. }
            | Expr::CharLit { .. }
            | Expr::Break { .. }
            | Expr::Continue { .. } => {}
            Expr::StringTemplate { parts, .. } => {
                for part in parts {
                    match part {
                        StringPart::Text(_) => {}
                        StringPart::ShortInterp(id) => {
                            self.resolve_name_use(scope, &id.name, id.span);
                        }
                        StringPart::Interp(e) => self.resolve_expr(scope, e),
                    }
                }
            }
            Expr::Path { segments, .. } => {
                if let Some(first) = segments.first() {
                    self.resolve_name_use(scope, &first.name, first.span);
                }
            }
            Expr::Member { receiver, safe, span, .. } => {
                if *safe {
                    self.check_unnecessary_safe_call(scope, receiver, *span);
                }
                self.resolve_expr(scope, receiver);
            }
            Expr::Call { callee, args, .. } => {
                self.resolve_expr(scope, callee);
                for a in args {
                    self.resolve_expr(scope, a);
                }
            }
            Expr::Index { receiver, args, .. } => {
                self.resolve_expr(scope, receiver);
                for a in args {
                    self.resolve_expr(scope, a);
                }
            }
            Expr::Binary { lhs, rhs, .. } => {
                self.resolve_expr(scope, lhs);
                self.resolve_expr(scope, rhs);
            }
            Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
                self.resolve_expr(scope, expr);
            }
            Expr::If { cond, then_branch, else_branch, .. } => {
                self.resolve_expr(scope, cond);
                self.resolve_expr(scope, then_branch);
                if let Some(e) = else_branch {
                    self.resolve_expr(scope, e);
                }
            }
            Expr::While { cond, body, .. } => {
                self.resolve_expr(scope, cond);
                self.resolve_expr(scope, body);
            }
            Expr::DoWhile { body, cond, .. } => {
                if let Some(b) = body {
                    self.resolve_expr(scope, b);
                }
                self.resolve_expr(scope, cond);
            }
            Expr::For { vars, iter, body, .. } => {
                self.resolve_expr(scope, iter);
                let for_scope = self.push_scope(Some(scope), ScopeKind::Block);
                for var in vars {
                    self.declare(for_scope, var.name.clone(), SymbolKind::ForVar, var.span, true);
                }
                self.resolve_expr(for_scope, body);
            }
            Expr::Return { value, .. } => {
                if let Some(v) = value {
                    self.resolve_expr(scope, v);
                }
            }
            Expr::Labeled { expr, .. } => {
                self.resolve_expr(scope, expr);
            }
            Expr::Block(b) => self.resolve_block(scope, b, /*new_scope=*/ true),
            Expr::Throw { value, .. } => self.resolve_expr(scope, value),
            Expr::Try { body, catches, finally, .. } => {
                self.resolve_block(scope, body, /*new_scope=*/ true);
                for c in catches {
                    let catch_scope = self.push_scope(Some(scope), ScopeKind::Block);
                    let sym = self.add_symbol(c.binding.name.clone(), SymbolKind::LocalProperty, Some(c.binding.span));
                    self.scopes[catch_scope.0 as usize]
                        .bindings
                        .insert(c.binding.name.clone(), sym);
                    self.resolve_block(catch_scope, &c.body, /*new_scope=*/ false);
                }
                if let Some(fb) = finally {
                    self.resolve_block(scope, fb, /*new_scope=*/ true);
                }
            }
            Expr::Lambda { params, body, .. } => {
                let lam_scope = self.push_scope(Some(scope), ScopeKind::Block);
                for p in params {
                    let sym = self.add_symbol(p.name.clone(), SymbolKind::Parameter, Some(p.span));
                    self.scopes[lam_scope.0 as usize]
                        .bindings
                        .insert(p.name.clone(), sym);
                }
                self.resolve_block(lam_scope, body, /*new_scope=*/ false);
            }
            Expr::This { .. } | Expr::Super { .. } => {
                // No resolver-level diagnostic. The interpreter checks at
                // evaluation time whether `this` / `super` is bound.
            }
            Expr::When { subject, branches, .. } => {
                if let Some(s) = subject {
                    self.resolve_expr(scope, s);
                }
                for b in branches {
                    for p in &b.patterns {
                        match &p.kind {
                            klio_ast::WhenPatternKind::Value(e)
                            | klio_ast::WhenPatternKind::InRange(e)
                            | klio_ast::WhenPatternKind::NotInRange(e) => {
                                self.resolve_expr(scope, e)
                            }
                            klio_ast::WhenPatternKind::IsType(_)
                            | klio_ast::WhenPatternKind::NotIsType(_)
                            | klio_ast::WhenPatternKind::Else => {}
                        }
                    }
                    self.resolve_expr(scope, &b.body);
                }
            }
            Expr::IsCheck { expr, .. } => self.resolve_expr(scope, expr),
            Expr::As { expr, .. } => self.resolve_expr(scope, expr),
            Expr::AnonFun { params, body, .. } => {
                let fn_scope = self.push_scope(Some(scope), ScopeKind::Block);
                for p in params {
                    let sym = self.add_symbol(
                        p.name.name.clone(),
                        SymbolKind::Parameter,
                        Some(p.name.span),
                    );
                    self.scopes[fn_scope.0 as usize]
                        .bindings
                        .insert(p.name.name.clone(), sym);
                }
                match body.as_deref() {
                    Some(klio_ast::FunctionBody::Block(b)) => {
                        self.resolve_block(fn_scope, b, /*new_scope=*/ false)
                    }
                    Some(klio_ast::FunctionBody::Expr(e)) => self.resolve_expr(fn_scope, e),
                    None => {}
                }
            }
            Expr::PropertyRef { .. } => {
                // `::name` references a property/function by name. The
                // interpreter resolves it as a lightweight metadata
                // value, so no name-use resolution is needed here.
            }
            Expr::MemberRef { receiver, .. } => {
                self.resolve_expr(scope, receiver);
            }
            Expr::Spread { expr, .. } => self.resolve_expr(scope, expr),
            Expr::ObjectExpr { supertype_args, supertype_delegates, members, .. } => {
                for args in supertype_args.iter().flatten() {
                    for a in args {
                        self.resolve_expr(scope, a);
                    }
                }
                for d in supertype_delegates.iter().flatten() {
                    self.resolve_expr(scope, d);
                }
                // Object literal body is a declaration scope per spec §6:
                // members can refer to each other regardless of source order.
                // Pre-declare every member name into a fresh scope, then walk
                // bodies against that scope.
                let body_scope = self.push_scope(Some(scope), ScopeKind::Block);
                for m in members {
                    let (name, kind, span) = match m {
                        Decl::Function(f) => (
                            f.name.name.clone(),
                            SymbolKind::LocalFunction,
                            f.name.span,
                        ),
                        Decl::Property(p) => (
                            p.name.name.clone(),
                            SymbolKind::LocalProperty,
                            p.name.span,
                        ),
                        Decl::Class(_) | Decl::Object(_) | Decl::TypeAlias(_) => continue,
                    };
                    let sym = self.add_symbol(name.clone(), kind, Some(span));
                    self.scopes[body_scope.0 as usize].bindings.insert(name, sym);
                }
                for m in members {
                    self.resolve_member_decl(body_scope, m);
                }
            }
        }
    }

    fn resolve_member_decl(&mut self, scope: ScopeId, decl: &Decl) {
        match decl {
            Decl::Function(f) => {
                let fn_scope = self.push_scope(Some(scope), ScopeKind::Block);
                for p in &f.params {
                    let sym = self.add_symbol(
                        p.name.name.clone(),
                        SymbolKind::Parameter,
                        Some(p.name.span),
                    );
                    self.scopes[fn_scope.0 as usize]
                        .bindings
                        .insert(p.name.name.clone(), sym);
                }
                match &f.body {
                    Some(klio_ast::FunctionBody::Block(b)) => {
                        self.resolve_block(fn_scope, b, /*new_scope=*/ false)
                    }
                    Some(klio_ast::FunctionBody::Expr(e)) => self.resolve_expr(fn_scope, e),
                    None => {}
                }
            }
            Decl::Property(p) => {
                if let Some(e) = &p.init {
                    self.resolve_expr(scope, e);
                }
                if let Some(d) = &p.delegate {
                    self.resolve_expr(scope, d);
                }
            }
            Decl::Class(_) | Decl::Object(_) => {}
            Decl::TypeAlias(_) => {}
        }
    }

    /// `UNNECESSARY_SAFE_CALL`: `s?.x` on a known-non-nullable receiver is a
    /// Kotlin warning. We only flag the easy case — a single-identifier
    /// receiver whose binding was declared with an explicit non-nullable
    /// type — to avoid noise until the inference work in the type checker
    /// gives us a more complete picture.
    fn check_unnecessary_safe_call(&mut self, scope: ScopeId, receiver: &Expr, op_span: Span) {
        let Expr::Path { segments, .. } = receiver else { return };
        if segments.len() != 1 {
            return;
        }
        let name = &segments[0].name;
        let Some(sym_id) = self.lookup(scope, name) else { return };
        let nullable = self.symbols[sym_id.0 as usize].nullable;
        if matches!(nullable, Some(false)) {
            self.diagnostics.emit(
                Diagnostic::from_factory(
                    &klio_diagnostics::generated::factories::UNNECESSARY_SAFE_CALL,
                    op_span,
                )
                .with_message(format!(
                    "Unnecessary safe call on a non-null receiver of type `{name}`"
                ))
                .with_code("R0005"),
            );
        }
    }

    fn resolve_name_use(&mut self, scope: ScopeId, name: &str, span: Span) {
        if let Some(sym) = self.lookup(scope, name) {
            self.uses.insert(span, sym);
        } else if self.is_inside_class_body(scope) {
            // Inside a class / object body the name may be an inherited
            // member or a dynamic `this`-receiver lookup; defer to the
            // interpreter instead of false-positiving R0001.
        } else {
            self.diagnostics.emit(
                Diagnostic::error(format!("Unresolved reference `{name}`"), span)
                    .with_code("R0001")
                    .with_factory(&klio_diagnostics::generated::factories::UNRESOLVED_REFERENCE),
            );
        }
    }

    fn is_inside_class_body(&self, mut scope: ScopeId) -> bool {
        loop {
            let s = &self.scopes[scope.0 as usize];
            if matches!(s.kind, ScopeKind::ClassBody) {
                return true;
            }
            match s.parent {
                Some(p) => scope = p,
                None => return false,
            }
        }
    }

    fn lookup(&self, mut scope: ScopeId, name: &str) -> Option<SymbolId> {
        loop {
            let s = &self.scopes[scope.0 as usize];
            if let Some(id) = s.bindings.get(name) {
                return Some(*id);
            }
            match s.parent {
                Some(p) => scope = p,
                None => return None,
            }
        }
    }

    fn push_scope(&mut self, parent: Option<ScopeId>, kind: ScopeKind) -> ScopeId {
        let id = ScopeId(self.scopes.len() as u32);
        self.scopes.push(Scope {
            id,
            parent,
            kind,
            bindings: HashMap::new(),
        });
        id
    }

    fn add_symbol(
        &mut self,
        name: String,
        kind: SymbolKind,
        decl_span: Option<Span>,
    ) -> SymbolId {
        let id = SymbolId(self.symbols.len() as u32);
        self.symbols.push(Symbol { id, name, kind, decl_span, nullable: None });
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_lexer::Lexer;
    use klio_parser::Parser;
    use klio_span::SourceMap;

    fn parse(src: &str) -> KotlinFile {
        let mut map = SourceMap::new();
        let id = map.add("test.kt", src);
        let owned = map.get(id).source.clone();
        let toks = Lexer::new(id, &owned).tokenize();
        let (ast, _diags) = Parser::new(id, &owned, &toks.tokens).parse_file();
        ast
    }

    /// Collect both factory names and legacy codes from each diagnostic so
    /// tests can assert against either identifier.
    fn codes(r: &Resolution) -> Vec<&'static str> {
        let mut out: Vec<&'static str> = Vec::new();
        for d in r.diagnostics.diagnostics() {
            if let Some(c) = d.legacy_code {
                out.push(c);
            }
            if let Some(f) = d.factory {
                out.push(f.name);
            }
        }
        out
    }

    #[test]
    fn resolves_forward_reference_between_top_level_funs() {
        let ast = parse(
            r#"
            fun main() { greet() }
            fun greet() { println("hi") }
            "#,
        );
        let r = resolve(&ast);
        assert!(
            !r.diagnostics.has_errors(),
            "unexpected diags: {:?}",
            r.diagnostics.diagnostics()
        );
    }

    #[test]
    fn resolves_println_as_builtin() {
        let ast = parse(r#"fun main() { println("hi") }"#);
        let r = resolve(&ast);
        let used = r
            .uses
            .values()
            .map(|id| r.symbol(*id).kind.clone())
            .collect::<Vec<_>>();
        assert!(used.iter().any(|k| matches!(k, SymbolKind::Builtin)));
    }

    #[test]
    fn unresolved_identifier_emits_r0001() {
        let ast = parse(r#"fun main() { println(banana) }"#);
        let r = resolve(&ast);
        assert!(codes(&r).contains(&"R0001"));
    }

    #[test]
    fn non_kotlin_import_emits_r0003() {
        let ast = parse(r#"
            import com.example.Thing
            fun main() {}
        "#);
        let r = resolve(&ast);
        assert!(codes(&r).contains(&"R0003"));
    }

    #[test]
    fn kotlin_import_is_accepted() {
        let ast = parse(r#"
            import kotlin.math.PI
            fun main() {}
        "#);
        let r = resolve(&ast);
        assert!(!codes(&r).contains(&"R0003"));
    }

    #[test]
    fn duplicate_top_level_emits_r0004() {
        let ast = parse(r#"
            fun foo() {}
            fun foo() {}
        "#);
        let r = resolve(&ast);
        assert!(codes(&r).contains(&"R0004"));
    }

    #[test]
    fn shadowing_in_inner_scope_emits_r0002() {
        let ast = parse(r#"
            fun main() {
                val x = 1
                val x = 2
                println(x)
            }
        "#);
        let r = resolve(&ast);
        assert!(codes(&r).contains(&"R0002"));
    }

    #[test]
    fn for_loop_variable_is_resolvable_in_body() {
        let ast = parse(r#"
            fun main() {
                for (i in 1..3) {
                    println(i)
                }
            }
        "#);
        let r = resolve(&ast);
        assert!(!r.diagnostics.has_errors());
        let any_for_var = r
            .uses
            .values()
            .any(|id| matches!(r.symbol(*id).kind, SymbolKind::ForVar));
        assert!(any_for_var, "expected at least one ForVar use");
    }

    #[test]
    fn function_parameter_resolves_inside_body() {
        let ast = parse(r#"
            fun id(x: Int): Int = x
        "#);
        let r = resolve(&ast);
        assert!(!r.diagnostics.has_errors());
        let saw_param = r
            .uses
            .values()
            .any(|id| matches!(r.symbol(*id).kind, SymbolKind::Parameter));
        assert!(saw_param);
    }

    #[test]
    fn mutual_recursion_resolves() {
        let ast = parse(r#"
            fun even(n: Int): Boolean = if (n == 0) true else odd(n - 1)
            fun odd(n: Int): Boolean = if (n == 0) false else even(n - 1)
        "#);
        let r = resolve(&ast);
        assert!(!r.diagnostics.has_errors(), "{:?}", r.diagnostics.diagnostics());
    }

    #[test]
    fn unnecessary_safe_call_on_non_nullable() {
        let ast = parse(r#"
            fun main() {
                val s: String = "hi"
                val n = s?.length
            }
        "#);
        let r = resolve(&ast);
        let warns: Vec<_> = r
            .diagnostics
            .diagnostics()
            .iter()
            .filter(|d| d.code() == Some("UNNECESSARY_SAFE_CALL"))
            .collect();
        assert_eq!(warns.len(), 1, "expected one R0005 warning: {:?}", r.diagnostics.diagnostics());
    }

    #[test]
    fn safe_call_on_nullable_is_silent() {
        let ast = parse(r#"
            fun main() {
                val s: String? = null
                val n = s?.length
            }
        "#);
        let r = resolve(&ast);
        let warns: Vec<_> = r
            .diagnostics
            .diagnostics()
            .iter()
            .filter(|d| d.code() == Some("UNNECESSARY_SAFE_CALL"))
            .collect();
        assert!(warns.is_empty(), "expected no R0005, got {:?}", warns);
    }

    #[test]
    fn class_member_sibling_reference_resolves() {
        // Spec §6.1: class body is a declaration scope; sibling members
        // see each other regardless of source order.
        let ast = parse(r#"
            class C {
                fun a(): Int = b() + 1
                fun b(): Int = 10
            }
            fun main() { println(C().a()) }
        "#);
        let r = resolve(&ast);
        assert!(
            !r.diagnostics.has_errors(),
            "unexpected diags: {:?}",
            r.diagnostics.diagnostics()
        );
    }

    #[test]
    fn forward_reference_to_local_val_in_statement_scope_errors() {
        // Spec §6: statement scopes bind names in source order; forward refs
        // are illegal.
        let ast = parse(r#"
            fun main() {
                println(x)
                val x = 1
            }
        "#);
        let r = resolve(&ast);
        assert!(codes(&r).contains(&"R0001"));
    }

    #[test]
    fn object_literal_member_forward_reference_resolves() {
        let ast = parse(r#"
            interface Greeter { fun hello(): String }
            fun main() {
                val g = object : Greeter {
                    override fun hello() = name
                    val name = "world"
                }
                println(g.hello())
            }
        "#);
        let r = resolve(&ast);
        assert!(
            !r.diagnostics.has_errors(),
            "unexpected diags: {:?}",
            r.diagnostics.diagnostics()
        );
    }

    #[test]
    fn safe_call_without_annotation_is_silent() {
        // Without an explicit annotation we don't know the type; refusing to
        // warn keeps the diagnostic noise-free until inference lands.
        let ast = parse(r#"
            fun main() {
                val s = "hi"
                val n = s?.length
            }
        "#);
        let r = resolve(&ast);
        let warns: Vec<_> = r
            .diagnostics
            .diagnostics()
            .iter()
            .filter(|d| d.code() == Some("UNNECESSARY_SAFE_CALL"))
            .collect();
        assert!(warns.is_empty());
    }
}
