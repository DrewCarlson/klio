//! Tree-walking interpreter.
//!
//! Runtime types (`Value`, `RuntimeError`, `Env`, `Output`) live in
//! `klio-runtime` and are shared with `klio-stdlib`. The interpreter walks
//! the AST, looks up names in the local/file/global scope chain, and
//! dispatches calls and member accesses against the stdlib's hand-written
//! intrinsics whenever a builtin FQN matches.

use klio_ast::{
    AssignOp, BinOp, Block, Decl, Expr, FunctionBody, KotlinFile, PostfixOp, Stmt, StringPart,
    TypeRef, UnOp,
};
pub use klio_runtime::{
    CallCtx, CaptureOutput, ClassDef, ClassParamDef, Env, InstanceData, MethodDef, Output,
    PropertyDef, RuntimeError, StdlibFn, StdoutOutput, Value,
};
use std::cell::RefCell;
use std::rc::Rc;

pub mod suspend_lower;

/// Short-name → FQN aliases for stdlib symbols a Kotlin program may
/// reference without an explicit import. Mirrors the implicit imports the
/// real Kotlin compiler installs.
const IMPLICIT_ALIASES: &[(&str, &str)] = &[
    ("print", "kotlin.io.print"),
    ("println", "kotlin.io.println"),
    ("readLine", "kotlin.io.readLine"),
    // Implicit `kotlin.*` exception constructors mirror Kotlin's default imports.
    ("ArithmeticException", "kotlin.ArithmeticException"),
    ("ClassCastException", "kotlin.ClassCastException"),
    ("Error", "kotlin.Error"),
    ("Exception", "kotlin.Exception"),
    ("IllegalArgumentException", "kotlin.IllegalArgumentException"),
    ("IllegalStateException", "kotlin.IllegalStateException"),
    ("IndexOutOfBoundsException", "kotlin.IndexOutOfBoundsException"),
    ("NoSuchElementException", "kotlin.NoSuchElementException"),
    ("NullPointerException", "kotlin.NullPointerException"),
    ("RuntimeException", "kotlin.RuntimeException"),
    ("Throwable", "kotlin.Throwable"),
    ("UnsupportedOperationException", "kotlin.UnsupportedOperationException"),
    // Collection constructors / aliases (implicit `kotlin.collections.*` imports).
    ("Pair", "kotlin.Pair"),
    ("Triple", "kotlin.Triple"),
    ("emptyList", "kotlin.collections.emptyList"),
    ("emptyMap", "kotlin.collections.emptyMap"),
    ("emptySet", "kotlin.collections.emptySet"),
    ("listOf", "kotlin.collections.listOf"),
    ("mapOf", "kotlin.collections.mapOf"),
    ("mutableListOf", "kotlin.collections.mutableListOf"),
    ("mutableMapOf", "kotlin.collections.mutableMapOf"),
    ("mutableSetOf", "kotlin.collections.mutableSetOf"),
    ("setOf", "kotlin.collections.setOf"),
    ("to", "kotlin.to"),
    ("ArrayList", "kotlin.collections.ArrayList"),
    ("HashMap", "kotlin.collections.HashMap"),
    ("HashSet", "kotlin.collections.HashSet"),
    ("LinkedHashMap", "kotlin.collections.LinkedHashMap"),
    ("LinkedHashSet", "kotlin.collections.LinkedHashSet"),
    ("sequenceOf", "kotlin.sequences.sequenceOf"),
    ("emptySequence", "kotlin.sequences.emptySequence"),
    ("generateSequence", "kotlin.sequences.generateSequence"),
    // Range progressions — the parser desugars `lhs downTo rhs` etc. to a
    // call on these bare names.
    ("downTo", "kotlin.ranges.downTo"),
    ("step", "kotlin.ranges.step"),
    ("until", "kotlin.ranges.until"),
    // `kotlin.text.*` implicit imports.
    ("Regex", "kotlin.text.Regex"),
    ("StringBuilder", "kotlin.text.StringBuilder"),
];

pub struct Interpreter {
    globals: Rc<RefCell<Env>>,
    /// Top-level properties keyed by simple name. Used to dispatch reads
    /// and writes through custom getters/setters or property delegates.
    top_level_props: std::collections::HashMap<String, PropertyDef>,
    /// `@Retention` value declared on each annotation class (`SOURCE`,
    /// `BINARY`, or `RUNTIME`). Populated when an `annotation class`
    /// is registered. Drives whether the annotation surfaces through
    /// `KClass.annotations`. Defaults to `RUNTIME` (spec §17.2) when
    /// the annotation class doesn't declare an explicit retention.
    annotation_class_retentions: std::collections::HashMap<String, String>,
    /// Class table populated at registration so reflection can look
    /// up a `ClassDef` by simple name without walking the lexical
    /// scope chain. `synthesize_annotation_value` consults this when
    /// building `KClass.annotations` instances.
    class_table: std::collections::HashMap<String, Rc<ClassDef>>,
    /// Stack of pending coroutine continuation holders. Pushed by
    /// `suspendCoroutine` / `suspendCoroutineUninterceptedOrReturn`
    /// before the user lambda runs; the synthetic `Continuation`
    /// value passed into that lambda writes back into the top
    /// holder when `resume` / `resumeWith` / `resumeWithException`
    /// is called. Drained by the suspending-call site after the
    /// lambda returns to produce its result.
    coroutine_continuations: Vec<Rc<RefCell<ContinuationSlot>>>,
    /// Stack of currently-driving suspend frames. Pushed when a
    /// suspend body's state machine starts running, popped on
    /// return or suspension. The top frame is the one a captured
    /// continuation would resume.
    active_suspend_frames: Vec<Rc<RefCell<klio_runtime::SuspendFrame>>>,
    /// Names registered as suspending functions, populated at
    /// top-level decl registration so the suspend-body lowering
    /// recognises calls to user-declared `suspend fun foo()`.
    suspend_function_names: suspend_lower::SuspendNameSet,
    /// Monotonic counter for synthesizing unique names for anonymous-object
    /// `ClassDef`s. Only surfaces in diagnostic-style debug output.
    anon_class_counter: usize,
    /// Monotonic counter for per-instance identity, surfaced through the
    /// default `Foo@<hex>` `toString`. Stamped onto every `InstanceData`
    /// at construction.
    instance_id_counter: u64,
    /// Extension functions keyed by the simple name of the declared
    /// receiver type. `recv.foo(args)` looks here after instance methods
    /// and stdlib intrinsics have been exhausted, picks the first
    /// signature whose name matches, and dispatches with `this` bound to
    /// the receiver.
    extensions: std::collections::HashMap<String, Vec<ExtensionFn>>,
    /// Extension properties keyed by simple receiver-type name. Looked up
    /// after class-member resolution at a property read or write site;
    /// the chosen getter/setter is invoked with `this` bound to the
    /// receiver value. No backing field; reads/writes must go through
    /// declared accessors.
    extension_properties: std::collections::HashMap<String, Vec<ExtensionProp>>,
    /// Stack of reified type-parameter bindings for in-flight `inline fun`
    /// calls. Each frame maps a type-param name (`T`) to the simple type
    /// name resolved at the call site (`"String"`, `"Int"`, …). `is`-checks
    /// and `T::class` consult the top frame.
    reified_stack: Vec<std::collections::HashMap<String, String>>,
    /// Stack of labels bound to enclosing loops. Each loop pushes either
    /// its bound label (when wrapped by `Expr::Labeled`) or `None` (plain
    /// loop) before evaluating its body and pops on exit. A loop swallows
    /// a labeled break / continue only when the top entry is `Some(l)`
    /// matching the signal's label — keeping nested unlabeled loops from
    /// swallowing a parent's labeled signal.
    loop_label_stack: Vec<Option<String>>,
    /// Set by `eval_labeled` after pushing a label entry so the directly
    /// enclosed `For` / `While` evaluator knows the label entry is already
    /// on the stack and avoids pushing its own `None` placeholder.
    label_already_pushed_for_loop: bool,
    /// Top-level `typealias` map keyed by alias name → underlying head
    /// type name. Populated from the file's declarations before
    /// evaluation. Used to redirect identifier resolution (constructor
    /// calls through an alias name) and runtime type checks
    /// (`x is Alias`, `x as Alias`) to the alias target.
    type_aliases: std::collections::HashMap<String, String>,
    /// Stack of implicit lambda labels — pushed by the higher-order
    /// dispatcher right before invoking a lambda argument. Lambda call
    /// frames consult the top entry to swallow `LabeledReturn` matching
    /// the enclosing call name (`forEach`, `map`, …). Spec §4.2.
    implicit_lambda_label_stack: Vec<String>,
    /// Stack of active `tailrec` frames. Each entry records the function
    /// name and the set of `Expr::Call` spans inside the current body that
    /// have been classified as tail-position self-calls. The `eval_call`
    /// path consults the top frame: a matching span raises
    /// `RuntimeError::TailContinue`, which the enclosing call frame catches
    /// to rebind parameters and re-evaluate the body without growing the
    /// host call stack.
    tailrec_stack: Vec<TailrecFrame>,
    /// Per-expression static types, supplied by the type checker before
    /// evaluation begins. Empty when the interpreter is invoked without
    /// typecheck (older tests, REPL warmups). Used at `==` sites to
    /// switch Float/Double equality to bit-equality when either operand's
    /// static type is `Any` / `Any?` / `Number` / `Number?`, matching the
    /// spec §8.9.2 expansion.
    expr_types: std::collections::HashMap<klio_span::Span, klio_types::Type>,
    /// Renaming imports (§10.1) shadow the original unqualified name in the
    /// current file. Maps the *original* simple name (the last path segment)
    /// to the chosen alias so we can surface a helpful "renamed to <alias>"
    /// message when a user references the shadowed name.
    import_renames: std::collections::HashMap<String, String>,
    /// Dotted package name from the file's `package` header (if any), used to
    /// stamp fully-qualified names onto user-declared classes and enums so the
    /// default `Any.toString` and `Enum.valueOf` failure messages match JVM
    /// Kotlin's `<package>.<simple-name>` form.
    current_package: Option<String>,
    /// FQN → native binding installed from a loaded pack. Wins over
    /// the static `klio_stdlib::implementation` lookup so a pack can
    /// shadow or augment the in-process stdlib.
    installed_bindings: std::collections::HashMap<String, klio_runtime::StdlibFn>,
    /// Top-level function overloads keyed by simple name. The env
    /// still holds the last-defined `Value::Function` for each name
    /// (so paths and references resolve), but this side-map carries
    /// every overload so `eval_call` can pick the most-specific
    /// candidate at a call site. Order matches source declaration
    /// order, used as a deterministic tiebreaker.
    top_level_overloads:
        std::collections::HashMap<String, Vec<(Rc<klio_ast::Function>, Rc<RefCell<Env>>)>>,
    /// Implicit-import packages contributed by every loaded pack.
    /// Unioned with `klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES` so
    /// resolver / typeck see the same surface regardless of source.
    pack_implicit_packages: Vec<String>,
    /// `is_known_package` surface contributed by every loaded pack —
    /// the set of packages reachable through the pack's symbol index.
    pack_known_packages: std::collections::HashSet<String>,
}

/// Holder a `Continuation<T>` writes into when its `resume` /
/// `resumeWith` / `resumeWithException` is called inside a
/// `suspendCoroutine { cont -> … }` block. The enclosing
/// suspending call site reads the slot once the user lambda
/// returns and produces either a normal value or a re-thrown
/// exception.
#[derive(Debug, Clone)]
enum ContinuationSlot {
    Pending,
    Resumed(Value),
    Failed(Value),
}

struct TailrecFrame {
    name: String,
    sites: Rc<std::collections::HashSet<klio_span::Span>>,
}

#[derive(Clone)]
/// Resolved LHS handle for `++` / `--`. Captures the receiver / index
/// values of a chained target so the spine is evaluated exactly once
/// across the read-then-write cycle (spec ch.9 hygienic / call-by-need).
enum IncDecLValue {
    Ident(String),
    Index { recv: Value, idxs: Vec<Value> },
    Member { recv: Value, name: String },
}

#[derive(Clone)]
struct ExtensionFn {
    decl: Rc<klio_ast::Function>,
    env: Rc<RefCell<Env>>,
}

#[derive(Clone)]
struct ExtensionProp {
    decl: Rc<klio_ast::Property>,
    env: Rc<RefCell<Env>>,
}

impl Interpreter {
    #[must_use]
    pub fn new() -> Self {
        let mut env = Env::new();
        for (name, fqn) in IMPLICIT_ALIASES {
            if let Some(func) = klio_stdlib::implementation(fqn) {
                env.define(*name, Value::Intrinsic { fqn, func });
            }
        }
        Self {
            globals: Rc::new(RefCell::new(env)),
            top_level_props: std::collections::HashMap::new(),
            annotation_class_retentions: std::collections::HashMap::new(),
            class_table: std::collections::HashMap::new(),
            coroutine_continuations: Vec::new(),
            active_suspend_frames: Vec::new(),
            suspend_function_names: suspend_lower::SuspendNameSet::with_intrinsics(),
            anon_class_counter: 0,
            instance_id_counter: 0,
            extensions: std::collections::HashMap::new(),
            extension_properties: std::collections::HashMap::new(),
            reified_stack: Vec::new(),
            loop_label_stack: Vec::new(),
            label_already_pushed_for_loop: false,
            type_aliases: std::collections::HashMap::new(),
            implicit_lambda_label_stack: Vec::new(),
            tailrec_stack: Vec::new(),
            expr_types: std::collections::HashMap::new(),
            import_renames: std::collections::HashMap::new(),
            current_package: None,
            installed_bindings: std::collections::HashMap::new(),
            top_level_overloads: std::collections::HashMap::new(),
            pack_implicit_packages: Vec::new(),
            pack_known_packages: std::collections::HashSet::new(),
        }
    }

    /// Install bindings, implicit packages, and the package surface
    /// from a loaded `klio-pack`. The pack carries the FQN → host
    /// symbol mapping; `host` resolves each host symbol to a Rust
    /// `StdlibFn` that the interpreter will dispatch when a call site
    /// hits that FQN. Returns the number of bindings installed.
    ///
    /// Multiple packs may be installed; later packs shadow earlier
    /// packs at colliding FQNs. The static
    /// `klio_stdlib::implementation` table acts as a fallback for FQNs
    /// no pack has bound.
    pub fn install_pack(
        &mut self,
        pack: &klio_pack::PackReader,
        host: &klio_stdlib::HostBindings,
    ) -> Result<usize, klio_pack::PackError> {
        use klio_pack::schema::{decode, BindingManifest, PackManifest, SymbolIndex};
        use klio_pack::section_names;
        if let Some(bytes) = pack.read_section(section_names::MANIFEST)? {
            let manifest: PackManifest = decode(&bytes)?;
            if manifest.abi_version > klio_pack::SUPPORTED_ABI_VERSION {
                return Err(klio_pack::PackError::AbiMismatch {
                    library_id: manifest.library_id,
                    found: manifest.abi_version,
                    supported: klio_pack::SUPPORTED_ABI_VERSION,
                });
            }
            for pkg in manifest.implicit_packages {
                if !self.pack_implicit_packages.iter().any(|p| p == &pkg) {
                    self.pack_implicit_packages.push(pkg.clone());
                }
                self.pack_known_packages.insert(pkg.clone());
                klio_stdlib::register_known_package(pkg);
            }
        }
        if let Some(bytes) = pack.read_section(section_names::SYMBOLS)? {
            let symbols: SymbolIndex = decode(&bytes)?;
            for record in symbols.entries {
                if !record.package.is_empty() {
                    self.pack_known_packages.insert(record.package.clone());
                    klio_stdlib::register_known_package(record.package);
                }
            }
        }
        let mut installed = 0usize;
        if let Some(bytes) = pack.read_section(section_names::BINDINGS)? {
            let manifest: BindingManifest = decode(&bytes)?;
            for b in manifest.bindings {
                if let Some(f) = host.resolve(&b.host_symbol) {
                    self.installed_bindings.insert(b.fqn, f);
                    installed += 1;
                }
            }
        }
        Ok(installed)
    }

    /// Register a set of parsed pack source files as if they had been
    /// loaded as additional sibling files in the module. Top-level
    /// declarations land directly in the shared globals so subsequent
    /// `run` / `run_module` invocations can see them. `main` functions
    /// inside pack sources are intentionally not invoked.
    pub fn register_pack_sources(
        &mut self,
        files: &[KotlinFile],
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        for file in files {
            self.run_with_output_mode(file, out, /*invoke_main=*/ false, /*persist=*/ true)?;
        }
        Ok(())
    }

    /// Look up an intrinsic by name through the captured global env.
    /// Used by the IR Host to resolve bare top-level identifiers
    /// (`println`, user `fun foo`) to a callable Value.
    pub fn lookup_global_callable(&self, name: &str) -> Option<klio_runtime::Value> {
        self.globals.borrow().lookup(name)
    }

    /// True when the named symbol has more than one top-level
    /// overload registered. IR call sites route these through the
    /// tree walker's eval_call so overload resolution picks the
    /// right arity / arg-type match rather than the single Value
    /// stashed in globals.
    pub fn has_top_level_overloads(&self, name: &str) -> bool {
        self.top_level_overloads
            .get(name)
            .map_or(false, |v| v.len() > 1)
    }

    /// Re-enter the IR evaluator against a stashed closure with a
    /// full IrHost so member calls / new-instance / etc. work.
    /// Looked up by invoke_callable_value when it encounters a
    /// `Value::IrClosure`.
    pub fn invoke_ir_closure_with_host(
        &mut self,
        id: u64,
        captures: &[Value],
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let slot = IR_CLOSURE_TABLE.with(|t| t.borrow().get(id as usize).cloned().flatten())
            .ok_or_else(|| RuntimeError::Type(format!("IR closure id {id} not in registry")))?;
        let func = slot
            .module
            .funcs
            .get(slot.body_func.0 as usize)
            .cloned()
            .ok_or_else(|| RuntimeError::Type("IR closure body_func out of range".into()))?;
        let class_names: Vec<String> = slot
            .module
            .classes
            .iter()
            .map(|c| c.name.clone())
            .collect();
        let mut host = IrHost {
            interp: self,
            out,
            class_names,
            closures: Vec::new(),
        };
        klio_ir::eval::eval_with_captures(
            &slot.module,
            &func,
            args.to_vec(),
            captures.to_vec(),
            &mut host,
        )
        .map_err(|e| RuntimeError::Type(e.to_string()))
    }

    /// Synthesize and dispatch a member call from pre-evaluated
    /// values. Used by the IR host so extension-function lookup
    /// + arg-type-aware dispatch + named-arg reordering fire
    /// through the existing eval_call machinery rather than the
    /// IR host's narrower call_member path.
    pub fn invoke_named_member_call(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let empty = vec![None; args.len()];
        self.invoke_named_member_call_with_names(receiver, name, args, &empty, out)
    }

    /// Same as `invoke_named_member_call` but threads named args
    /// through so foo(a = 1, b = 2) reorder fires.
    pub fn invoke_named_member_call_with_names(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        use klio_ast::{Expr, Ident};
        use klio_span::{FileId, Span};
        let dummy_span = Span::new(FileId(0), 0, 0);
        let env = Rc::new(RefCell::new(klio_runtime::Env::with_parent(Rc::clone(&self.globals))));
        env.borrow_mut().define("__ir_self".to_string(), receiver.clone());
        let mut arg_exprs: Vec<Expr> = Vec::with_capacity(args.len());
        for (i, v) in args.iter().enumerate() {
            let slot = format!("__ir_arg_{i}");
            env.borrow_mut().define(slot.clone(), v.clone());
            arg_exprs.push(Expr::Path {
                segments: vec![Ident { name: slot, span: dummy_span }],
                span: dummy_span,
            });
        }
        let names: Vec<Option<String>> = if arg_names.len() == args.len() {
            arg_names.to_vec()
        } else {
            vec![None; args.len()]
        };
        let call = Expr::Call {
            callee: Box::new(Expr::Member {
                receiver: Box::new(Expr::Path {
                    segments: vec![Ident { name: "__ir_self".into(), span: dummy_span }],
                    span: dummy_span,
                }),
                name: Ident { name: name.to_string(), span: dummy_span },
                safe: false,
                span: dummy_span,
            }),
            args: arg_exprs,
            arg_names: names,
            type_args: Vec::new(),
            is_infix: false,
            span: dummy_span,
        };
        self.eval_expr(&call, &env, out)
    }

    /// Same as `invoke_named_intrinsic` but threads named args
    /// through so default-value fill + reorder fires.
    pub fn invoke_named_intrinsic_with_names(
        &mut self,
        name: &str,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        use klio_ast::{Expr, Ident};
        use klio_span::{FileId, Span};
        let dummy_span = Span::new(FileId(0), 0, 0);
        let env = Rc::new(RefCell::new(klio_runtime::Env::with_parent(Rc::clone(&self.globals))));
        let mut arg_exprs: Vec<Expr> = Vec::with_capacity(args.len());
        for (i, v) in args.iter().enumerate() {
            let slot = format!("__ir_arg_{i}");
            env.borrow_mut().define(slot.clone(), v.clone());
            arg_exprs.push(Expr::Path {
                segments: vec![Ident { name: slot, span: dummy_span }],
                span: dummy_span,
            });
        }
        let names: Vec<Option<String>> = if arg_names.len() == args.len() {
            arg_names.to_vec()
        } else {
            vec![None; args.len()]
        };
        let call = Expr::Call {
            callee: Box::new(Expr::Path {
                segments: vec![Ident { name: name.to_string(), span: dummy_span }],
                span: dummy_span,
            }),
            args: arg_exprs,
            arg_names: names,
            type_args: Vec::new(),
            is_infix: false,
            span: dummy_span,
        };
        self.eval_expr(&call, &env, out)
    }

    /// Invoke a name-dispatched intrinsic (`repeat`, `let`, `apply`,
    /// `listOf`, …) that the tree walker recognises by simple name
    /// inside `eval_call`. Used by the IR host to route these forms
    /// back through the existing machinery without forcing the IR
    /// evaluator to reimplement them. Args are pre-evaluated values
    /// — the wrapper synthesises a fresh AST Call from a literal
    /// callable name and bound argument placeholders so existing
    /// dispatch fires.
    pub fn invoke_named_intrinsic(
        &mut self,
        name: &str,
        args: &[klio_runtime::Value],
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, RuntimeError> {
        use klio_ast::{Expr, Ident};
        use klio_span::{FileId, Span};
        let dummy_span = Span::new(FileId(0), 0, 0);
        // Stash the pre-evaluated args as locals so the synthesised
        // call's arg-Expr nodes resolve to them. We use a dedicated
        // env layer so the names don't leak.
        let env = Rc::new(RefCell::new(klio_runtime::Env::with_parent(Rc::clone(&self.globals))));
        let mut arg_exprs: Vec<Expr> = Vec::with_capacity(args.len());
        for (i, v) in args.iter().enumerate() {
            let slot_name = format!("__ir_arg_{i}");
            env.borrow_mut().define(slot_name.clone(), v.clone());
            arg_exprs.push(Expr::Path {
                segments: vec![Ident { name: slot_name, span: dummy_span }],
                span: dummy_span,
            });
        }
        let arg_count = arg_exprs.len();
        let call = Expr::Call {
            callee: Box::new(Expr::Path {
                segments: vec![Ident { name: name.to_string(), span: dummy_span }],
                span: dummy_span,
            }),
            args: arg_exprs,
            arg_names: vec![None; arg_count],
            type_args: Vec::new(),
            is_infix: false,
            span: dummy_span,
        };
        self.eval_expr(&call, &env, out)
    }

    /// Look up an intrinsic by FQN. Checks pack-installed bindings
    /// first, falls back to the static `klio_stdlib` table.
    #[must_use]
    pub fn lookup_intrinsic(&self, fqn: &str) -> Option<klio_runtime::StdlibFn> {
        if let Some(f) = self.installed_bindings.get(fqn) {
            return Some(*f);
        }
        klio_stdlib::implementation(fqn)
    }

    /// Single source of truth for "did a pack install a binding for
    /// this FQN?". Use this from dispatch sites that want to let a
    /// pack-installed native impl shadow a baked-in fallback
    /// (intrinsic alias / BoundMethod / shim Kotlin body / etc.).
    #[must_use]
    pub fn binding_override(&self, fqn: &str) -> Option<klio_runtime::StdlibFn> {
        self.installed_bindings.get(fqn).copied()
    }

    /// Returns the implicit-import packages contributed by loaded
    /// packs (`install_pack`). The stdlib defaults remain in
    /// `klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES`; this list adds
    /// any packs that declared more.
    #[must_use]
    pub fn pack_implicit_packages(&self) -> &[String] {
        &self.pack_implicit_packages
    }

    /// Returns true when `package_path` appears in any loaded pack's
    /// implicit-imports list or symbol index. Stdlib coverage from
    /// `klio_stdlib::is_known_package` is additive.
    #[must_use]
    pub fn is_pack_known_package(&self, package_path: &str) -> bool {
        self.pack_known_packages.contains(package_path)
    }

    /// Compose `<file-package>.<simple>` for a top-level user-declared class.
    /// When the file has no `package` header, returns the simple name unchanged.
    fn qualify_simple_name(&self, simple: &str) -> String {
        match &self.current_package {
            Some(pkg) if !pkg.is_empty() => format!("{pkg}.{simple}"),
            _ => simple.to_string(),
        }
    }

    /// Supply per-expression static types from the type checker. Calls
    /// to the interpreter that skip this step still work (the map stays
    /// empty); features that depend on static types will fall back to
    /// AST-only heuristics in that case.
    pub fn with_expr_types(
        mut self,
        types: std::collections::HashMap<klio_span::Span, klio_types::Type>,
    ) -> Self {
        self.expr_types = types;
        self
    }

    /// Merge additional `(span, type)` pairs into the interpreter's
    /// per-expression type map without resetting it. Used by the
    /// pack loader to layer in a pack's frozen `typeck` section.
    pub fn extend_expr_types(
        &mut self,
        types: impl IntoIterator<Item = (klio_span::Span, klio_types::Type)>,
    ) {
        self.expr_types.extend(types);
    }

    /// Consult per-expression static types: an operand is "boxed" if its
    /// static type is `Any` / `Any?`, OR if its AST shape is a syntactic
    /// `as Any` / `as Number` cast (fallback when typeck data is missing).
    fn is_boxed_operand(&self, expr: &Expr) -> bool {
        if let Some(t) = self.expr_types.get(&expr.span()) {
            if type_is_boxing_for_floats(t) {
                return true;
            }
        }
        is_boxed_to_any_form(expr)
    }

    /// Walk the typealias map to the underlying head type name. Returns
    /// the input unchanged when no alias matches. Caps at 32 hops to
    /// guarantee termination if the user wrote a cycle (typeck emits
    /// T0038 in that case but the interp must still not hang).
    fn resolve_type_alias(&self, name: &str) -> String {
        let mut cur = name.to_string();
        for _ in 0..32 {
            match self.type_aliases.get(&cur) {
                Some(next) if next != &cur => cur = next.clone(),
                _ => return cur,
            }
        }
        cur
    }

    /// True when `name` refers to an erased (non-reified) generic
    /// type parameter at this point in the program — i.e. it does
    /// not resolve to any built-in, user class, object, or type
    /// alias the runtime knows about. `as T` against such a name
    /// is the spec's unchecked-cast form and must pass through at
    /// runtime; the static diagnostic side (T0083) lives in the
    /// typechecker.
    fn is_erased_type_param(&self, name: &str) -> bool {
        if klio_types::builtin_by_name(name).is_some() {
            return false;
        }
        if self.type_aliases.contains_key(name) {
            return false;
        }
        if self.globals.borrow().lookup(name).is_some() {
            // A binding exists at this name — it's a class, object,
            // or value reference, not an erased param.
            return false;
        }
        // Match common stdlib generic container names so we don't
        // treat them as erased.
        !matches!(
            name,
            "List"
                | "MutableList"
                | "Collection"
                | "MutableCollection"
                | "Set"
                | "MutableSet"
                | "Map"
                | "MutableMap"
                | "Iterable"
                | "MutableIterable"
                | "Iterator"
                | "MutableIterator"
                | "Sequence"
                | "Array"
                | "ByteArray"
                | "ShortArray"
                | "IntArray"
                | "LongArray"
                | "FloatArray"
                | "DoubleArray"
                | "BooleanArray"
                | "CharArray"
                | "Pair"
                | "Triple"
                | "Result"
                | "Comparable"
                | "Comparator"
                | "Throwable"
                | "Exception"
                | "RuntimeException"
                | "Error"
                | "Function"
                | "Function0"
                | "Function1"
                | "Function2"
        )
    }

    /// Resolve a type name through the active reified-type frame. Returns
    /// the original name unchanged when no rebinding is active.
    /// Synthesize a `Value::Class` for a Kotlin built-in type name when one
    /// is needed at runtime — used by `Int::class`, reified-T class literals,
    /// and `T::class` for any primitive parameter. The class is intentionally
    /// minimal: no methods, no companion, no parent. The reflection surface
    /// the user can reach is just `simpleName` and `qualifiedName`.
    fn synth_primitive_class(&self, name: &str) -> Option<Value> {
        let fqn = match name {
            "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" | "Boolean" | "Char"
            | "Unit" | "String" | "Any" | "Nothing" | "Number" | "CharSequence" => {
                format!("kotlin.{name}")
            }
            "List" | "MutableList" | "Set" | "MutableSet" | "Map" | "MutableMap"
            | "Collection" | "MutableCollection" | "Iterable" | "MutableIterable"
            | "Iterator" | "MutableIterator" | "Array" | "IntArray" | "LongArray"
            | "DoubleArray" | "FloatArray" | "ShortArray" | "ByteArray" | "BooleanArray"
            | "CharArray" => format!("kotlin.collections.{name}"),
            "IntRange" | "LongRange" | "CharRange" => {
                format!("kotlin.ranges.{name}")
            }
            "Pair" | "Triple" => format!("kotlin.{name}"),
            _ => return None,
        };
        Some(Value::Class(Rc::new(ClassDef {
            name: name.to_string(),
            fqn,
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            is_data: false,
            is_object: false,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            supertype_names: Vec::new(),
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::clone(&self.globals),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        })))
    }

    /// Build a `Value::Instance` representing a runtime-retained
    /// annotation application. The instance carries the annotation
    /// class so user-side `is`-checks (`it is Foo`) and
    /// `findAnnotation<Foo>()` discriminate correctly. Falls back
    /// to a string holder when the annotation class isn't
    /// registered (e.g. references to a stdlib annotation type
    /// that isn't user-declared).
    fn synthesize_annotation_value(&self, name: &str) -> Value {
        if let Some(c) = self.class_table.get(name) {
            let inst = Rc::new(RefCell::new(InstanceData {
                class: Rc::clone(c),
                fields: Vec::new(),
                outer: None,
                identity: 0,
            native_state: None,
            }));
            return Value::Instance(inst);
        }
        Value::String(Rc::new(name.to_string()))
    }

    /// Filter an AST annotation list to those with `@Retention(RUNTIME)`.
    /// Per spec §17.2 the default retention is RUNTIME; only an
    /// explicit `@Retention(AnnotationRetention.SOURCE)` or
    /// `BINARY` excludes an annotation from runtime reflection.
    fn runtime_annotation_names(&self, annotations: &[klio_ast::Annotation]) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for ann in annotations {
            let Some(simple) = ann.path.last().map(|s| s.name.clone()) else { continue };
            // Look up the annotation class's own @Retention.
            let retention = self
                .annotation_class_retentions
                .get(&simple)
                .cloned()
                .unwrap_or_else(|| "RUNTIME".to_string());
            if retention == "RUNTIME" {
                out.push(simple);
            }
        }
        out
    }

    fn resolve_reified(&self, name: &str) -> String {
        for frame in self.reified_stack.iter().rev() {
            if let Some(real) = frame.get(name) {
                return real.clone();
            }
        }
        name.to_string()
    }

    fn push_reified_frame(&mut self, decl: &klio_ast::Function, type_args: &[klio_ast::TypeRef]) {
        if !decl.is_inline {
            return;
        }
        let mut frame = std::collections::HashMap::new();
        for (i, tp) in decl.type_params.iter().enumerate() {
            if !tp.is_reified {
                continue;
            }
            if let Some(arg) = type_args.get(i) {
                frame.insert(tp.name.name.clone(), arg.name.name.clone());
            }
        }
        if !frame.is_empty() {
            self.reified_stack.push(frame);
        } else {
            // Push an empty frame anyway so depth bookkeeping in
            // `pop_reified_frame` always pairs with the push site.
            self.reified_stack.push(frame);
        }
    }

    fn pop_reified_frame(&mut self, decl: &klio_ast::Function) {
        if !decl.is_inline {
            return;
        }
        if decl.type_params.iter().any(|tp| tp.is_reified) || true {
            // We pushed unconditionally for any inline fn (including the
            // empty-frame case) so pop unconditionally too.
            self.reified_stack.pop();
        }
    }

    fn next_instance_id(&mut self) -> u64 {
        self.instance_id_counter = self.instance_id_counter.wrapping_add(1);
        self.instance_id_counter
    }

    pub fn run(&mut self, file: &KotlinFile) -> Result<Value, RuntimeError> {
        self.run_with_output(file, &mut StdoutOutput)
    }

    /// Run a multi-file module. Each file's top-level declarations
    /// register into the shared globals first, then the file
    /// containing `fun main` is run with its own imports applied.
    /// This is the minimal multi-file interpreter contract: all
    /// declarations from sibling files are visible cross-file, but
    /// each file's `import` list applies only inside that file's
    /// declarations as they execute.
    /// Lower a single source file to IR and execute its `main`
    /// function through `klio_ir::eval`. Returns the value of
    /// `main` (typically `Unit`) or an evaluation error.
    ///
    /// This is the entry point for the IR-eval cutover work
    /// (`--ir-eval` flag in klio-cli). The Host bridges back to
    /// this interpreter for dispatch the IR evaluator cannot
    /// resolve standalone — top-level fn calls, member calls,
    /// instance construction.
    pub fn run_ir(
        &mut self,
        file: &KotlinFile,
        out: &mut dyn Output,
    ) -> Result<klio_runtime::Value, String> {
        // Use the existing tree-walker as the bootstrap pass so
        // class shells, top-level fns, and stdlib bindings are
        // available to the IR Host. The walker registers everything
        // into the interpreter's globals and class_table before we
        // dispatch through the IR.
        self.run_with_output_impl(file, out, /*invoke_main=*/ false, /*persist=*/ true)
            .map_err(|e| format!("bootstrap: {e}"))?;

        // Now lower the file's classes / top-level fns into an IR
        // module. Classes go first so Path→NewInstance routing
        // sees them.
        let mut module = klio_ir::Module::default();
        for d in &file.decls {
            if let Decl::Class(c) = d {
                let _ = klio_ir::lower::lower_class(&mut module, c);
            }
        }
        let mut main_id: Option<klio_ir::FuncId> = None;
        for d in &file.decls {
            if let Decl::Function(f) = d {
                let func = klio_ir::lower::lower_function(&mut module, f);
                if f.name.name == "main" {
                    main_id = Some(func.id);
                }
            }
        }
        let main_id = main_id.ok_or_else(|| "no `fun main` in file".to_string())?;
        let func = module.funcs[main_id.0 as usize].clone();
        // Pre-stash class names indexed by IR ClassId so the Host
        // can resolve NewInstance(class_id, args) without re-walking
        // the module.
        let class_names: Vec<String> = module
            .classes
            .iter()
            .map(|c| c.name.clone())
            .collect();
        let mut host = IrHost {
            interp: self,
            out,
            class_names,
            closures: Vec::new(),
        };
        klio_ir::eval::eval_with(&module, &func, Vec::new(), &mut host)
            .map_err(|e| format!("ir eval: {e}"))
    }

    pub fn run_module(
        &mut self,
        files: &[KotlinFile],
    ) -> Result<Value, RuntimeError> {
        self.run_module_with_output(files, &mut StdoutOutput)
    }

    pub fn run_module_with_output(
        &mut self,
        files: &[KotlinFile],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if files.is_empty() {
            return Err(RuntimeError::NoMain);
        }
        // Walk every file first to populate the shared globals with
        // every cross-file class / function / property declaration.
        // We do this by feeding each non-main file through
        // run_with_output, which registers its top-level decls and
        // returns without invoking `main` (because the file doesn't
        // have one). Then run the main file.
        let main_idx = files.iter().position(|f| {
            f.decls.iter().any(|d| {
                matches!(d, klio_ast::Decl::Function(f) if f.name.name == "main")
            })
        });
        for (i, file) in files.iter().enumerate() {
            if Some(i) == main_idx {
                continue;
            }
            // Non-main file: register top-level decls into the
            // shared globals (persist=true), don't call main
            // (invoke_main=false).
            self.run_with_output_mode(file, out, false, true)?;
        }
        if let Some(idx) = main_idx {
            // The main file's decls also persist into globals so
            // they survive any subsequent invocation against the
            // same Interpreter instance.
            self.run_with_output_mode(&files[idx], out, true, true)
        } else {
            Err(RuntimeError::NoMain)
        }
    }

    fn globals_ref(&self) -> Rc<RefCell<Env>> {
        Rc::clone(&self.globals)
    }

    pub fn run_with_output(
        &mut self,
        file: &KotlinFile,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.run_with_output_mode(file, out, /*invoke_main=*/ true, /*persist=*/ false)
    }

    /// Internal entry point. When `invoke_main` is true the file's
    /// `fun main` is called after every declaration is in scope;
    /// when false the function returns `Unit` once all decls have
    /// been registered. `persist` controls whether the file's
    /// declarations land directly in the shared globals (so other
    /// files in the same module can see them) or in a transient
    /// file-scoped environment.
    pub fn run_with_output_mode(
        &mut self,
        file: &KotlinFile,
        out: &mut dyn Output,
        invoke_main: bool,
        persist: bool,
    ) -> Result<Value, RuntimeError> {
        let _ = (invoke_main, persist);
        self.run_with_output_impl(file, out, invoke_main, persist)
    }

    fn run_with_output_impl(
        &mut self,
        file: &KotlinFile,
        out: &mut dyn Output,
        invoke_main: bool,
        persist: bool,
    ) -> Result<Value, RuntimeError> {
        // When `persist` is true, register decls directly into the
        // shared globals so sibling files in a module can see them
        // after this call returns. Otherwise (the common single-
        // file path) decls live in a transient file-scoped env that
        // drops on return.
        let file_env = if persist {
            Rc::clone(&self.globals)
        } else {
            Rc::new(RefCell::new(Env::with_parent(Rc::clone(&self.globals))))
        };

        // Record the file's package so user-declared classes get a fully-
        // qualified `<package>.<simple-name>` FQN, matching JVM Kotlin's
        // `Any.toString` and `Enum.valueOf` failure-message conventions.
        self.current_package = file.package.as_ref().map(|p| {
            p.path.iter().map(|i| i.name.as_str()).collect::<Vec<_>>().join(".")
        });

        // Apply imports (spec §10.1).
        //  * `import path.X as Y` binds `Y` to whatever `path.X` resolves to
        //    in the stdlib registry and records the original simple name so
        //    referencing `X` unqualified surfaces a "renamed to `Y`"
        //    diagnostic.
        //  * `import path.X` (no alias) binds the simple name `X`.
        //  * `import path.*` binds every stdlib symbol whose FQN starts with
        //    `path.` and whose remainder has no further `.`.
        self.import_renames.clear();
        let bind_fqn = |env: &Rc<RefCell<Env>>, simple: String, fqn: &str, out: &mut dyn Output| {
            if let Some(func) = klio_stdlib::implementation(fqn) {
                let fqn_static: &'static str = leak_fqn(fqn);
                let is_property = klio_stdlib::lookup(fqn)
                    .map_or(false, |s| matches!(s.kind, klio_stdlib::SymbolKind::Property));
                let bound = if is_property {
                    let mut ctx = CallCtx { args: &[], out };
                    match func(&mut ctx) {
                        Ok(v) => v,
                        Err(_) => Value::Intrinsic { fqn: fqn_static, func },
                    }
                } else {
                    Value::Intrinsic { fqn: fqn_static, func }
                };
                env.borrow_mut().define(simple, bound);
            }
        };
        for imp in &file.imports {
            let fqn = imp
                .path
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>()
                .join(".");
            if imp.wildcard {
                let prefix = format!("{fqn}.");
                let symbols: Vec<String> = klio_stdlib::all_symbol_names()
                    .filter(|n| {
                        n.starts_with(&prefix) && !n[prefix.len()..].contains('.')
                    })
                    .map(|n| n.to_string())
                    .collect();
                for sym_fqn in symbols {
                    let simple = sym_fqn[prefix.len()..].to_string();
                    bind_fqn(&file_env, simple, &sym_fqn, out);
                }
                continue;
            }
            let Some(last_seg) = imp.path.last() else { continue };
            let simple = imp
                .alias
                .as_ref()
                .map(|a| a.name.clone())
                .unwrap_or_else(|| last_seg.name.clone());
            bind_fqn(&file_env, simple.clone(), &fqn, out);
            if let Some(alias_ident) = &imp.alias {
                self.import_renames
                    .insert(last_seg.name.clone(), alias_ident.name.clone());
            }
        }

        // Register top-level `typealias` declarations so constructor calls
        // through an alias name (`val x = S()` where `typealias S = String`)
        // and runtime type checks (`v is Alias`, `v as Alias`) route to the
        // underlying head type at evaluation time.
        for d in &file.decls {
            if let Decl::TypeAlias(a) = d {
                self.type_aliases
                    .insert(a.name.name.clone(), a.target.name.name.clone());
            }
        }

        // Forward-declare top-level functions so source order doesn't matter.
        // Extension functions (`fun T.foo(...)`) register into the
        // per-receiver table instead of binding a callable by name.
        for d in &file.decls {
            if let Decl::Function(f) = d {
                let decl = Rc::new(f.clone());
                if f.is_suspend {
                    self.suspend_function_names.insert(f.name.name.clone());
                }
                if let Some(recv) = &f.receiver_type {
                    self.extensions
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionFn {
                            decl: Rc::clone(&decl),
                            env: Rc::clone(&file_env),
                        });
                    continue;
                }
                self.top_level_overloads
                    .entry(f.name.name.clone())
                    .or_default()
                    .push((Rc::clone(&decl), Rc::clone(&file_env)));
                // When a pack has installed a native binding for this
                // top-level FQN (`<package>.<fn-name>`), bind the
                // simple name to the intrinsic so the shim's default
                // Kotlin body doesn't shadow the binding.
                let value = if let Some(pkg) = self.current_package.as_deref() {
                    let fqn = format!("{pkg}.{}", f.name.name);
                    if let Some(func) = self.binding_override(&fqn) {
                        let fqn_static: &'static str = leak_fqn(&fqn);
                        Value::Intrinsic { fqn: fqn_static, func }
                    } else {
                        Value::Function {
                            decl,
                            env: Rc::clone(&file_env),
                        }
                    }
                } else {
                    Value::Function {
                        decl,
                        env: Rc::clone(&file_env),
                    }
                };
                file_env.borrow_mut().define(f.name.name.clone(), value);
            }
        }

        // Build class declarations next so property initializers can reference
        // class constructors. Inheritance requires two passes: first build
        // every class shell (so all sibling/parent classes are in scope as
        // `Value::Class`); next resolve parent links; only then construct
        // standalone object singletons and enum entries — both of which may
        // depend on an inherited parent at instance-construction time.
        let mut pending_objects: Vec<(String, Rc<ClassDef>)> = Vec::new();
        let mut pending_enums: Vec<(Rc<ClassDef>, usize)> = Vec::new();
        let mut all_classes: Vec<Rc<ClassDef>> = Vec::new();
        for (idx, d) in file.decls.iter().enumerate() {
            match d {
                Decl::Class(c) => {
                    let class = self.build_class_shell(c, &file_env, out)?;
                    self.class_table
                        .insert(c.name.name.clone(), Rc::clone(&class));
                    file_env
                        .borrow_mut()
                        .define(c.name.name.clone(), Value::Class(Rc::clone(&class)));
                    if c.is_enum {
                        pending_enums.push((Rc::clone(&class), idx));
                    }
                    all_classes.push(class);
                }
                Decl::Object(o) => {
                    let class = self.build_object_class(o, &file_env, out)?;
                    all_classes.push(Rc::clone(&class));
                    pending_objects.push((o.name.name.clone(), class));
                }
                _ => {}
            }
        }
        // Resolve parent links now that every class is in the env.
        for class in &all_classes {
            self.resolve_parent_link(class);
        }
        // Construct enum entries (each may invoke its enum class's ctor).
        for (class, idx) in pending_enums {
            if let Decl::Class(c) = &file.decls[idx] {
                self.build_enum_entries(&class, c, &file_env, out)?;
            }
        }
        // Construct standalone object singletons (parent init runs through
        // the chain at construct time if they declared a parent).
        for (name, class) in pending_objects {
            let inst = self.construct_object_singleton(&class, out)?;
            file_env.borrow_mut().define(name, Value::Instance(inst));
        }

        // Evaluate top-level property initializers in source order. Custom
        // accessors and delegates land in `top_level_props`; reads/writes
        // of the bare name then route through `read_top_level_property` /
        // `write_top_level_property`.
        for d in &file.decls {
            if let Decl::Property(p) = d {
                if let Some(recv) = &p.receiver_type {
                    self.extension_properties
                        .entry(recv.name.name.clone())
                        .or_default()
                        .push(ExtensionProp {
                            decl: Rc::new(p.clone()),
                            env: Rc::clone(&file_env),
                        });
                    continue;
                }
                let pdef = PropertyDef {
                    name: p.name.name.clone(),
                    mutable: p.mutable,
                    init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                    getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                    setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                    delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                    is_abstract: p.is_abstract,
                    is_lateinit: p.is_lateinit,
                };
                if let Some(delegate_expr) = &pdef.delegate {
                    let dval = self.eval_expr(delegate_expr, &file_env, out)?;
                    // Spec ch.9: when the delegate value's class declares
                    // `operator fun provideDelegate(thisRef, property)`, the
                    // stored delegate is the call's result, not the raw
                    // initializer. Top-level properties have no `thisRef`,
                    // so pass `null`.
                    let dval = self.maybe_provide_delegate(dval, &Value::Null, &p.name.name, &file_env, out)?;
                    file_env
                        .borrow_mut()
                        .define(format!("__delegate${}", p.name.name), dval);
                } else if let Some(init) = &pdef.init {
                    let v = self.eval_expr(init, &file_env, out)?;
                    file_env.borrow_mut().define(p.name.name.clone(), v);
                } else if pdef.is_lateinit {
                    file_env
                        .borrow_mut()
                        .define(p.name.name.clone(), make_lateinit_sentinel(&p.name.name));
                } else if pdef.getter.is_none() {
                    file_env.borrow_mut().define(p.name.name.clone(), Value::Null);
                }
                self.top_level_props.insert(p.name.name.clone(), pdef);
            }
        }

        if !invoke_main {
            return Ok(Value::Unit);
        }
        let main = file_env.borrow().lookup("main");
        let Some(Value::Function { decl, env }) = main else {
            return Err(RuntimeError::NoMain);
        };
        self.call_function(&decl, &env, &[], out)
    }

    fn call_function(
        &mut self,
        decl: &klio_ast::Function,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        // Suspend functions go through the state-machine driver so
        // suspendCoroutine calls inside the body can pause /
        // resume. Non-suspending functions use the direct call
        // path.
        if decl.is_suspend && matches!(decl.body.as_ref(), Some(klio_ast::FunctionBody::Block(_))) {
            let rc = Rc::new(decl.clone());
            return self.drive_suspend_function(&rc, captured_env, args, out);
        }
        self.call_function_named(decl, captured_env, args, &[], out)
    }

    /// Evaluate a value-argument list, unwrapping any leading `*expr`
    /// spread markers. Returns the evaluated values in source order plus a
    /// parallel mask identifying which entries originated from a spread.
    fn eval_args_with_spread(
        &mut self,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(Vec<Value>, Vec<bool>), RuntimeError> {
        let mut vals = Vec::with_capacity(args.len());
        let mut mask = Vec::with_capacity(args.len());
        for a in args {
            match a {
                Expr::Spread { expr, .. } => {
                    vals.push(self.eval_expr(expr, env, out)?);
                    mask.push(true);
                }
                _ => {
                    vals.push(self.eval_expr(a, env, out)?);
                    mask.push(false);
                }
            }
        }
        Ok((vals, mask))
    }

    fn call_function_named(
        &mut self,
        decl: &klio_ast::Function,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.call_function_named_spread(decl, captured_env, args, arg_names, &[], out)
    }

    fn call_function_named_spread(
        &mut self,
        decl: &klio_ast::Function,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        arg_names: &[Option<String>],
        is_spread: &[bool],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        // Owned mutable bindings so the mutual-tailrec trampoline can
        // replace `decl` / `captured_env` / `args` in place when a
        // `RuntimeError::TailJump` arrives. The non-tailrec path runs
        // exactly one iteration of the outer loop.
        let mut cur_decl: Rc<klio_ast::Function> = Rc::new(decl.clone());
        let mut cur_captured: Rc<RefCell<Env>> = Rc::clone(captured_env);
        let mut cur_args: Vec<Value> = args.to_vec();
        let mut cur_arg_names: Vec<Option<String>> = arg_names.to_vec();
        let mut cur_is_spread: Vec<bool> = is_spread.to_vec();
        loop {
        let decl: &klio_ast::Function = &cur_decl;
        let captured_env: &Rc<RefCell<Env>> = &cur_captured;
        let args: &[Value] = &cur_args;
        let arg_names: &[Option<String>] = &cur_arg_names;
        let is_spread: &[bool] = &cur_is_spread;
        // If a vararg parameter exists, gather the positional args that map
        // into its slot into a single Array. Spread arguments flatten in.
        let vararg_idx = decl.params.iter().position(|p| p.is_vararg);
        let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(captured_env))));
        if let Some(va_i) = vararg_idx {
            // Match positional args before va_i to params[0..va_i]; collect
            // the remaining positional args (until trailing named-args or
            // post-vararg positionals) into the vararg array. Named args go
            // to their declared slot.
            let n_params = decl.params.len();
            let mut slot: Vec<Option<Value>> = vec![None; n_params];
            let mut vararg_items: Vec<Value> = Vec::new();
            let mut pos_index: usize = 0;
            for (i, a) in args.iter().enumerate() {
                let name = arg_names.get(i).cloned().unwrap_or(None);
                let spread = is_spread.get(i).copied().unwrap_or(false);
                if let Some(n) = name {
                    let Some(idx) = decl.params.iter().position(|p| p.name.name == n) else {
                        return Err(RuntimeError::Arity(format!(
                            "no parameter named `{n}` on `{}`",
                            decl.name.name
                        )));
                    };
                    if idx == va_i && spread {
                        if let Value::Array { items, .. } = a {
                            for e in items.borrow().iter() {
                                vararg_items.push(e.clone());
                            }
                            continue;
                        }
                    }
                    slot[idx] = Some(a.clone());
                    continue;
                }
                // Positional.
                if pos_index < va_i {
                    slot[pos_index] = Some(a.clone());
                    pos_index += 1;
                } else if pos_index == va_i {
                    if spread {
                        if let Value::Array { items, .. } = a {
                            for e in items.borrow().iter() {
                                vararg_items.push(e.clone());
                            }
                        } else {
                            return Err(RuntimeError::Type(
                                "`*` spread requires an array argument".into(),
                            ));
                        }
                    } else {
                        vararg_items.push(a.clone());
                    }
                    // Stay at pos_index = va_i so further positional args
                    // accumulate into vararg_items until a named arg or
                    // end.
                } else {
                    // unreachable in normal use
                    slot[pos_index] = Some(a.clone());
                    pos_index += 1;
                }
            }
            // Materialize the vararg slot as a Value::Array.
            let arr = Value::Array {
                items: Rc::new(RefCell::new(vararg_items)),
                prim: None,
            };
            if slot[va_i].is_none() {
                slot[va_i] = Some(arr);
            }
            for (i, p) in decl.params.iter().enumerate() {
                let v = if let Some(v) = slot[i].take() {
                    v
                } else if let Some(d) = &p.default {
                    self.eval_expr(d, &frame, out)?
                } else if p.is_vararg {
                    Value::Array { items: Rc::new(RefCell::new(Vec::new())), prim: None }
                } else {
                    return Err(RuntimeError::Arity(format!(
                        "missing argument for `{}` (parameter `{}`)",
                        decl.name.name, p.name.name
                    )));
                };
                frame.borrow_mut().define(p.name.name.clone(), v);
            }
        } else {
            if args.len() > decl.params.len() {
                return Err(RuntimeError::Arity(format!(
                    "`{}` expects at most {} arguments, got {}",
                    decl.name.name,
                    decl.params.len(),
                    args.len()
                )));
            }
            let param_names: Vec<&str> = decl.params.iter().map(|p| p.name.name.as_str()).collect();
            let slotted = reorder_named_args(args, arg_names, &param_names, &decl.name.name)?;
            for (i, p) in decl.params.iter().enumerate() {
                let v = if let Some(Some(v)) = slotted.get(i) {
                    v.clone()
                } else if let Some(d) = &p.default {
                    self.eval_expr(d, &frame, out)?
                } else {
                    return Err(RuntimeError::Arity(format!(
                        "missing argument for `{}` (parameter `{}`)",
                        decl.name.name, p.name.name
                    )));
                };
                let v = self.maybe_sam_coerce(v, Some(&p.ty.name.name), captured_env, out)?;
                frame.borrow_mut().define(p.name.name.clone(), v);
            }
        }
        // `tailrec` trampoline: install a frame describing this function's
        // tail-position self-call sites, then loop. Any tail-position self
        // call inside the body raises `RuntimeError::TailContinue(args)`
        // which we catch here, rebind the params from the new args, and
        // resume — keeping the host stack flat.
        let tailrec_pushed = if decl.is_tailrec {
            if let Some(body) = &decl.body {
                let sites = collect_tail_call_sites(body);
                self.tailrec_stack.push(TailrecFrame {
                    name: decl.name.name.clone(),
                    sites: Rc::new(sites),
                });
                true
            } else {
                false
            }
        } else {
            false
        };
        let result = loop {
            let r = match &decl.body {
                Some(FunctionBody::Block(b)) => self.eval_block(b, &frame, out),
                Some(FunctionBody::Expr(e)) => self.eval_expr(e, &frame, out),
                None => Err(RuntimeError::Unimplemented("function without body".into())),
            };
            match r {
                Err(RuntimeError::TailContinue(new_args, new_arg_names))
                    if tailrec_pushed =>
                {
                    if let Err(e) = self.rebind_for_tail_call(decl, &frame, &new_args, &new_arg_names, out) {
                        break Err(e);
                    }
                    continue;
                }
                other => break other,
            }
        };
        if tailrec_pushed {
            self.tailrec_stack.pop();
        }
        // Mutual `tailrec` hop: the inner loop bubbled out a TailJump
        // before resolving; replace the active decl/env/args and
        // restart the outer loop so the new callee runs in the same
        // host frame.
        if let Err(RuntimeError::TailJump(callee, new_args, new_arg_names)) = &result {
            if let Value::Function { decl: new_decl, env: new_env } = callee {
                if new_decl.is_tailrec {
                    cur_decl = Rc::clone(new_decl);
                    cur_captured = Rc::clone(new_env);
                    cur_args = new_args.clone();
                    cur_arg_names = new_arg_names.clone();
                    cur_is_spread = vec![false; cur_args.len()];
                    continue;
                }
            }
        }
        return match result {
            Ok(v) => Ok(v),
            Err(RuntimeError::Return(v)) => Ok(v),
            Err(RuntimeError::LabeledReturn(l, v)) => {
                if l == decl.name.name {
                    Ok(v)
                } else {
                    Err(RuntimeError::LabeledReturn(l, v))
                }
            }
            Err(e) => Err(e),
        };
        }
    }

    /// Rebind the parameters of a `tailrec` function from new argument
    /// values at the start of a trampoline iteration. Mirrors the binding
    /// logic in `call_function_named_spread` but writes into the existing
    /// `frame`. Defaults are re-evaluated each iteration when a slot is
    /// missing, matching kotlinc's semantics.
    fn rebind_for_tail_call(
        &mut self,
        decl: &klio_ast::Function,
        frame: &Rc<RefCell<Env>>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        let n_params = decl.params.len();
        let mut slot: Vec<Option<Value>> = vec![None; n_params];
        for (i, a) in args.iter().enumerate() {
            let name = arg_names.get(i).cloned().unwrap_or(None);
            if let Some(n) = name {
                let Some(idx) = decl.params.iter().position(|p| p.name.name == n) else {
                    return Err(RuntimeError::Arity(format!(
                        "no parameter named `{n}` on `{}`",
                        decl.name.name
                    )));
                };
                slot[idx] = Some(a.clone());
            } else if i < n_params {
                slot[i] = Some(a.clone());
            }
        }
        for (i, p) in decl.params.iter().enumerate() {
            let v = if let Some(v) = slot[i].take() {
                v
            } else if let Some(d) = &p.default {
                self.eval_expr(d, frame, out)?
            } else {
                return Err(RuntimeError::Arity(format!(
                    "missing argument for `{}` (parameter `{}`)",
                    decl.name.name, p.name.name
                )));
            };
            frame.borrow_mut().define(p.name.name.clone(), v);
        }
        Ok(())
    }

    /// Receiver-type keys an extension declaration may match for a given
    /// runtime value. Simple-name based: for a user `Value::Instance` the
    /// instance's class plus every parent class on the chain (so an
    /// extension on the parent applies to subclasses); for builtins, the
    /// last segment of `type_fqn()`. `Any` is always appended so a
    /// universal `fun Any.foo()` matches everything.
    fn receiver_type_names(value: &Value) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        match value {
            Value::Instance(inst) => {
                let class = Rc::clone(&inst.borrow().class);
                out.push(class.name.clone());
                let mut cur = class.parent.borrow().clone();
                while let Some(p) = cur {
                    out.push(p.name.clone());
                    cur = p.parent.borrow().clone();
                }
            }
            Value::Class(c) => {
                // A bare reference to a class can dispatch to extensions
                // on the class's companion object via the enclosing class
                // name, e.g. `Foo.bar()` where `bar` is declared on
                // `Foo.Companion`. Match the registration key shape used
                // for those extensions.
                if let Some(comp) = c.companion.borrow().as_ref() {
                    let comp_name = &comp.borrow().class.name;
                    out.push(format!("{}.{}", c.name, comp_name));
                    out.push(comp_name.clone());
                    // The `Companion` keyword aliases the companion
                    // regardless of its declared name, per Kotlin spec.
                    out.push(format!("{}.Companion", c.name));
                    out.push("Companion".to_string());
                }
                out.push(c.name.clone());
            }
            _ => {
                let fqn = value.type_fqn();
                let simple = fqn.rsplit('.').next().unwrap_or(fqn);
                out.push(simple.to_string());
                if simple.starts_with("MutableList") {
                    out.push("List".to_string());
                } else if simple.starts_with("MutableSet") {
                    out.push("Set".to_string());
                } else if simple.starts_with("MutableMap") {
                    out.push("Map".to_string());
                }
                // Surface stdlib interface aliases so extensions on
                // `Iterable` / `Collection` / `CharSequence` / `Comparable`
                // dispatch through any subtype receiver.
                match simple {
                    "List" | "MutableList" | "Set" | "MutableSet" | "Array"
                    | "IntArray" | "LongArray" | "DoubleArray" | "FloatArray"
                    | "ShortArray" | "ByteArray" | "BooleanArray" | "CharArray" => {
                        out.push("Collection".to_string());
                        out.push("Iterable".to_string());
                    }
                    "Map" | "MutableMap" => {
                        out.push("Iterable".to_string());
                    }
                    "String" => {
                        out.push("CharSequence".to_string());
                        out.push("Comparable".to_string());
                    }
                    "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" => {
                        out.push("Number".to_string());
                        out.push("Comparable".to_string());
                    }
                    "Char" | "Boolean" => {
                        out.push("Comparable".to_string());
                    }
                    "IntRange" | "LongRange" | "CharRange" => {
                        out.push("Iterable".to_string());
                        out.push("ClosedRange".to_string());
                    }
                    _ => {}
                }
            }
        }
        out.push("Any".to_string());
        out
    }

    fn try_extension_call(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        arg_names: &[Option<String>],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let keys = Self::receiver_type_names(receiver);
        let mut chosen: Option<ExtensionFn> = None;
        'outer: for key in &keys {
            if let Some(list) = self.extensions.get(key) {
                for ext in list {
                    if ext.decl.name.name == name && args.len() <= ext.decl.params.len() {
                        chosen = Some(ext.clone());
                        break 'outer;
                    }
                }
            }
        }
        // Nullable-receiver fallback: when the value is null and no concrete
        // key matched, dispatch through any extension whose declared
        // receiver type carries a `?`. Matches `fun T?.foo()` shape.
        if chosen.is_none() && matches!(receiver, Value::Null) {
            for list in self.extensions.values() {
                for ext in list {
                    let nullable_recv = ext
                        .decl
                        .receiver_type
                        .as_ref()
                        .map(|r| r.nullable)
                        .unwrap_or(false);
                    if nullable_recv
                        && ext.decl.name.name == name
                        && args.len() <= ext.decl.params.len()
                    {
                        chosen = Some(ext.clone());
                        break;
                    }
                }
                if chosen.is_some() {
                    break;
                }
            }
        }
        // Generic extension fallback: `fun <T> T.foo(...)` registers under
        // the type-parameter name `T`. Match any receiver when no concrete
        // key has answered first.
        if chosen.is_none() {
            for (key, list) in &self.extensions {
                for ext in list {
                    let is_generic_receiver = ext.decl.type_params.iter().any(|tp| tp.name.name == *key);
                    if is_generic_receiver
                        && ext.decl.name.name == name
                        && args.len() <= ext.decl.params.len()
                    {
                        chosen = Some(ext.clone());
                        break;
                    }
                }
                if chosen.is_some() {
                    break;
                }
            }
        }
        let Some(ext) = chosen else { return Ok(None) };
        let mut arg_vals = Vec::with_capacity(args.len());
        for a in args {
            arg_vals.push(self.eval_expr(a, env, out)?);
        }
        let v = self.call_extension(&ext.decl, &ext.env, receiver.clone(), &arg_vals, arg_names, out)?;
        Ok(Some(v))
    }

    /// Value-based variant of `try_extension_call`: arguments are already
    /// evaluated. Operator-overloading dispatch sites use this so they don't
    /// have to synthesize fresh AST nodes for already-computed operand values.
    fn try_extension_call_with_values(
        &mut self,
        receiver: &Value,
        name: &str,
        arg_vals: &[Value],
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let keys = Self::receiver_type_names(receiver);
        let mut chosen: Option<ExtensionFn> = None;
        'outer: for key in &keys {
            if let Some(list) = self.extensions.get(key) {
                for ext in list {
                    if ext.decl.name.name == name && arg_vals.len() <= ext.decl.params.len() {
                        chosen = Some(ext.clone());
                        break 'outer;
                    }
                }
            }
        }
        if chosen.is_none() {
            for (key, list) in &self.extensions {
                for ext in list {
                    let is_generic_receiver = ext.decl.type_params.iter().any(|tp| tp.name.name == *key);
                    if is_generic_receiver
                        && ext.decl.name.name == name
                        && arg_vals.len() <= ext.decl.params.len()
                    {
                        chosen = Some(ext.clone());
                        break;
                    }
                }
                if chosen.is_some() {
                    break;
                }
            }
        }
        let Some(ext) = chosen else { return Ok(None) };
        let arg_names: Vec<Option<String>> = vec![None; arg_vals.len()];
        let v = self.call_extension(&ext.decl, &ext.env, receiver.clone(), arg_vals, &arg_names, out)?;
        Ok(Some(v))
    }

    /// Dispatch a binary arithmetic / range operator to a user `operator fun`
    /// (member or extension) on the LHS. Returns `Some` if a suitable operator
    /// function was invoked, `None` to defer to the built-in numeric rules.
    fn try_user_binop_dispatch(
        &mut self,
        op: BinOp,
        l: &Value,
        r: &Value,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let name = match op {
            BinOp::Add => "plus",
            BinOp::Sub => "minus",
            BinOp::Mul => "times",
            BinOp::Div => "div",
            BinOp::Rem => "rem",
            BinOp::Range => "rangeTo",
            BinOp::RangeUntil => "rangeUntil",
            _ => return Ok(None),
        };
        if let Value::Instance(inst) = l {
            let class = Rc::clone(&inst.borrow().class);
            let arg_type_simple = match r {
                Value::Instance(i) => Some(i.borrow().class.name.clone()),
                _ => None,
            };
            if let Some((m, _)) =
                class.find_method_for_arg(name, arg_type_simple.as_deref())
            {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    let v = self.call_method(&inst, &m, &[r.clone()], &[None], out)?;
                    return Ok(Some(v));
                }
            }
        }
        self.try_extension_call_with_values(l, name, &[r.clone()], out)
    }

    /// Dispatch a unary operator (`+a`, `-a`, `!a`) to a user `operator fun`.
    fn try_user_unop_dispatch(
        &mut self,
        op: UnOp,
        v: &Value,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let name = match op {
            UnOp::Pos => "unaryPlus",
            UnOp::Neg => "unaryMinus",
            UnOp::Not => "not",
            _ => return Ok(None),
        };
        if let Value::Instance(inst) = v {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(name) {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    let r = self.call_method(&inst, &m, &[], &[], out)?;
                    return Ok(Some(r));
                }
            }
        }
        self.try_extension_call_with_values(v, name, &[], out)
    }

    /// Spec ch.9 `contains` convention: `x in c` lowers to `c.contains(x)`.
    /// Returns `Some(bool)` when the haystack provides a user `operator fun
    /// contains`, `None` to defer to the built-in `value_in` rules.
    fn try_user_contains_dispatch(
        &mut self,
        needle: &Value,
        haystack: &Value,
        out: &mut dyn Output,
    ) -> Result<Option<bool>, RuntimeError> {
        let check_bool = |v: Value| -> Result<bool, RuntimeError> {
            match v {
                Value::Bool(b) => Ok(b),
                other => Err(RuntimeError::Type(format!(
                    "`contains` must return Boolean, got {other:?}"
                ))),
            }
        };
        if let Value::Instance(inst) = haystack {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method("contains") {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    let v = self.call_method(&inst, &m, &[needle.clone()], &[None], out)?;
                    return Ok(Some(check_bool(v)?));
                }
            }
        }
        if let Some(v) = self.try_extension_call_with_values(haystack, "contains", &[needle.clone()], out)? {
            return Ok(Some(check_bool(v)?));
        }
        Ok(None)
    }

    fn call_extension(
        &mut self,
        decl: &klio_ast::Function,
        captured_env: &Rc<RefCell<Env>>,
        receiver: Value,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if args.len() > decl.params.len() {
            return Err(RuntimeError::Arity(format!(
                "extension `{}` expects at most {} arguments, got {}",
                decl.name.name,
                decl.params.len(),
                args.len()
            )));
        }
        let param_names: Vec<&str> = decl.params.iter().map(|p| p.name.name.as_str()).collect();
        let slotted = reorder_named_args(args, arg_names, &param_names, &decl.name.name)?;
        let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(captured_env))));
        // Spec §8.24: inside the extension body and any lambda nested in
        // it, `this@<fnName>` must resolve to the extension receiver.
        let this_at_fn = format!("this@{}", decl.name.name);
        frame.borrow_mut().define(this_at_fn, receiver.clone());
        frame.borrow_mut().define("this", receiver);
        for (i, p) in decl.params.iter().enumerate() {
            let v = if let Some(Some(v)) = slotted.get(i) {
                v.clone()
            } else if let Some(d) = &p.default {
                self.eval_expr(d, &frame, out)?
            } else {
                return Err(RuntimeError::Arity(format!(
                    "missing argument for extension `{}` (parameter `{}`)",
                    decl.name.name, p.name.name
                )));
            };
            frame.borrow_mut().define(p.name.name.clone(), v);
        }
        let result = match &decl.body {
            Some(FunctionBody::Block(b)) => self.eval_block(b, &frame, out),
            Some(FunctionBody::Expr(e)) => self.eval_expr(e, &frame, out),
            None => Err(RuntimeError::Unimplemented("extension without body".into())),
        };
        match result {
            Ok(v) => Ok(v),
            Err(RuntimeError::Return(v)) => Ok(v),
            Err(e) => Err(e),
        }
    }

    fn eval_block(
        &mut self,
        block: &Block,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let scope = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
        let mut last = Value::Unit;
        for stmt in &block.stmts {
            last = self.eval_stmt(stmt, &scope, out)?;
        }
        Ok(last)
    }

    fn eval_stmt(
        &mut self,
        stmt: &Stmt,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match stmt {
            Stmt::Expr(e) => self.eval_expr(e, env, out),
            Stmt::Decl(Decl::Property(p)) => {
                let value = match &p.init {
                    Some(e) => self.eval_expr(e, env, out)?,
                    None => Value::Null,
                };
                env.borrow_mut().define(p.name.name.clone(), value);
                Ok(Value::Unit)
            }
            Stmt::Decl(Decl::Function(f)) => {
                let value = Value::Function {
                    decl: Rc::new(f.clone()),
                    env: Rc::clone(env),
                };
                env.borrow_mut().define(f.name.name.clone(), value);
                Ok(Value::Unit)
            }
            Stmt::Decl(Decl::Class(c)) => {
                let class = self.build_class(c, env, out)?;
                env.borrow_mut().define(c.name.name.clone(), Value::Class(class));
                Ok(Value::Unit)
            }
            Stmt::Decl(Decl::Object(o)) => {
                let class = self.build_object_class(o, env, out)?;
                let inst = self.construct_object_singleton(&class, out)?;
                env.borrow_mut().define(o.name.name.clone(), Value::Instance(inst));
                Ok(Value::Unit)
            }
            Stmt::Decl(Decl::TypeAlias(_)) => {
                // Typealiases are transparent — typeck has already unfolded
                // every use site. The interp has no runtime representation
                // for them. Nested aliases are rejected by typeck (T0039)
                // but we still tolerate them here so the pipeline runs.
                Ok(Value::Unit)
            }
            Stmt::DestructuringDecl { names, init, .. } => {
                let value = self.eval_expr(init, env, out)?;
                let components = destructure_components(self, &value, names, out)?;
                for (n, c) in names.iter().zip(components) {
                    if n.name == "_" {
                        continue;
                    }
                    env.borrow_mut().define(n.name.clone(), c);
                }
                Ok(Value::Unit)
            }
            Stmt::Assign { target, op, value, span } => {
                // §7.1.3 safe assignment. If any `safe: true` Member appears
                // along the LHS spine, expand the innermost one into the
                // when-shaped form `when (val $tmp = recv) { null -> null;
                // else -> $tmp.<rest> = value }`. Evaluating the receiver may
                // short-circuit before the RHS is touched, matching the spec
                // expansion's semantics. Multiple safe operators in the LHS
                // are unwound by recursion: the rewrite drops one safe at a
                // time, so the next eval_stmt invocation will find the next.
                if let Some(safe_recv) = innermost_safe_lhs_receiver(target) {
                    let recv_val = self.eval_expr(&safe_recv, env, out)?;
                    if matches!(recv_val, Value::Null) {
                        return Ok(Value::Unit);
                    }
                    // Tmp name lives in a fresh child scope so reused names
                    // in nested rewrites shadow rather than collide.
                    let tmp_name = "$$safe_assign_tmp".to_string();
                    let scope = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
                    scope.borrow_mut().define(tmp_name.clone(), recv_val);
                    let rewritten = rewrite_dropping_innermost_safe(target, &tmp_name);
                    let new_stmt = Stmt::Assign {
                        target: rewritten,
                        op: *op,
                        value: value.clone(),
                        span: *span,
                    };
                    return self.eval_stmt(&new_stmt, &scope, out);
                }
                let new_value = self.eval_expr(value, env, out)?;
                // §7.1.2 operator-assignment dispatch. Compound ops first
                // attempt `*Assign` (plusAssign / minusAssign / …) on the
                // LHS receiver. When that resolves to a member or to a
                // built-in mutable collection, the in-place mutation
                // replaces the read/arith/write fallback. Falls through
                // to the existing `A = A op B` path when no `*Assign`
                // candidate exists.
                if !matches!(op, AssignOp::Assign) {
                    if let Some(()) = self.try_compound_assign_dispatch(target, *op, &new_value, env, out)? {
                        return Ok(Value::Unit);
                    }
                }
                // Member-style assignment: `obj.field = value` or
                // implicit `field = value` inside a method body. The latter
                // happens because the resolver-level desugaring binds field
                // names directly in the method's frame env, but a write to
                // them must propagate back into the instance.
                if let Expr::Member { receiver, name, safe: false, .. } = target {
                    let recv = self.eval_expr(receiver, env, out)?;
                    if let Value::Instance(inst) = &recv {
                        let class = Rc::clone(&inst.borrow().class);
                        let pdef = class.find_body_property(&name.name).map(|(p, _)| p);
                        if pdef.is_none() {
                            if let Some(ep) = self.find_extension_property(&recv, &name.name) {
                                let cur = if !matches!(op, AssignOp::Assign) {
                                    Some(self.try_extension_property_get(&recv, &name.name, out)?
                                        .ok_or_else(|| RuntimeError::Unbound(name.name.clone()))?)
                                } else { None };
                                let final_value = match op {
                                    AssignOp::Assign => new_value,
                                    other => {
                                        let binop = compound_to_binop(*other);
                                        eval_binop(binop, cur.unwrap(), new_value)?
                                    }
                                };
                                let _ = ep;
                                self.try_extension_property_set(&recv, &name.name, final_value, out)?;
                                return Ok(Value::Unit);
                            }
                        }
                        let cur = if matches!(op, AssignOp::Assign) {
                            // Plain assignment: no need to read the old
                            // value — skip the getter so it isn't fired
                            // as a side effect of the write.
                            None
                        } else if pdef.as_ref().map_or(false, |p| p.delegate.is_some() || p.getter.is_some()) {
                            // For delegated / computed properties, route
                            // reads through the dispatch path so compound
                            // assignments observe the right "current" value.
                            Some(self.read_instance_property(inst, pdef.as_ref().unwrap(), out)?)
                        } else {
                            inst.borrow().get(&name.name)
                        };
                        let final_value = match op {
                            AssignOp::Assign => new_value,
                            other => {
                                let current = cur.ok_or_else(|| {
                                    RuntimeError::Unbound(format!(
                                        "{}.{}",
                                        inst.borrow().class.name,
                                        name.name
                                    ))
                                })?;
                                let binop = compound_to_binop(*other);
                                eval_binop(binop, current, new_value)?
                            }
                        };
                        if let Some(pdef) = &pdef {
                            if pdef.delegate.is_some() || pdef.setter.is_some() {
                                self.write_instance_property(inst, pdef, final_value, out)?;
                                return Ok(Value::Unit);
                            }
                        }
                        inst.borrow_mut().define(&name.name, final_value);
                        return Ok(Value::Unit);
                    }
                    // `ClassName.prop = v` — write through to the
                    // companion-object instance when the class has one.
                    if let Value::Class(class) = &recv {
                        let comp_opt = class.companion.borrow().clone();
                        if let Some(comp) = comp_opt.as_ref() {
                            if comp.borrow().get(&name.name).is_some() {
                                let comp_inst = Rc::clone(comp);
                                let final_value = match op {
                                    AssignOp::Assign => new_value,
                                    other => {
                                        let current = comp_inst
                                            .borrow()
                                            .get(&name.name)
                                            .ok_or_else(|| {
                                                RuntimeError::Unbound(name.name.clone())
                                            })?;
                                        let binop = compound_to_binop(*other);
                                        eval_binop(binop, current, new_value)?
                                    }
                                };
                                comp_inst.borrow_mut().define(&name.name, final_value);
                                return Ok(Value::Unit);
                            }
                        }
                    }
                    // Non-instance receiver — only valid target is an
                    // extension property's setter (e.g. `var Int.foo`).
                    if self.find_extension_property(&recv, &name.name).is_some() {
                        let final_value = match op {
                            AssignOp::Assign => new_value,
                            other => {
                                let cur = self.try_extension_property_get(&recv, &name.name, out)?
                                    .ok_or_else(|| RuntimeError::Unbound(name.name.clone()))?;
                                let binop = compound_to_binop(*other);
                                eval_binop(binop, cur, new_value)?
                            }
                        };
                        self.try_extension_property_set(&recv, &name.name, final_value, out)?;
                        return Ok(Value::Unit);
                    }
                    return Err(RuntimeError::Type(format!(
                        "cannot assign to `.{}` on non-instance receiver",
                        name.name
                    )));
                }
                // Indexed assignment: `xs[i] = v` (and compound forms).
                // Routes to a typed setter for `Value::Array` / mutable
                // `Value::List` / `Value::Map`; other receivers fall to
                // the catch-all error.
                if let Expr::Index { receiver, args: idx_args, .. } = target {
                    let recv = self.eval_expr(receiver, env, out)?;
                    let mut idx_vals: Vec<Value> = Vec::with_capacity(idx_args.len());
                    for a in idx_args {
                        idx_vals.push(self.eval_expr(a, env, out)?);
                    }
                    return self.assign_index(recv, &idx_vals, *op, new_value, out);
                }
                let Expr::Path { segments, .. } = target else {
                    return Err(RuntimeError::Unimplemented(
                        "assignment target other than ident".into(),
                    ));
                };
                if segments.len() != 1 {
                    return Err(RuntimeError::Unimplemented(
                        "qualified assignment target".into(),
                    ));
                }
                let name = &segments[0].name;
                // Top-level property write — route through delegate /
                // custom setter if declared.
                let tlp = self.top_level_props.get(name).cloned();
                if let Some(pdef) = &tlp {
                    if pdef.delegate.is_some() || pdef.setter.is_some() {
                        let current = if matches!(op, AssignOp::Assign) {
                            None
                        } else {
                            Some(self.read_top_level_property(pdef, env, out)?)
                        };
                        let final_value = match op {
                            AssignOp::Assign => new_value,
                            other => {
                                let binop = compound_to_binop(*other);
                                eval_binop(binop, current.unwrap(), new_value)?
                            }
                        };
                        self.write_top_level_property(pdef, final_value, env, out)?;
                        return Ok(Value::Unit);
                    }
                }
                // Resolve the read-source for compound assignment against the
                // live `this` chain (matches the read path).
                let final_value = match op {
                    AssignOp::Assign => new_value,
                    other => {
                        let current = self
                            .read_ident_live(name, env)
                            .map_err(|_| RuntimeError::Unbound(name.clone()))?;
                        let binop = compound_to_binop(*other);
                        eval_binop(binop, current, new_value)?
                    }
                };
                // Walk the `this` chain to write a class field / companion /
                // outer-class field. Delegated / setter properties on the
                // innermost `this` still go through the delegate path first.
                // A lexical binding that lives strictly closer (deeper) than
                // a particular `this` shadows that class field — e.g. a
                // `var name = ...` declared in the method body.
                let name_hit = env.borrow().lookup_with_depth(name);
                let this_chain = env.borrow().lookup_all_with_depth("this");
                for (idx, (this_val, this_depth)) in this_chain.iter().enumerate() {
                    let Value::Instance(inst) = this_val else { continue };
                    let class = Rc::clone(&inst.borrow().class);
                    if idx == 0 {
                        if let Some((pdef, _)) = class.find_body_property(name) {
                            if pdef.delegate.is_some() || pdef.setter.is_some() {
                                self.write_instance_property(&inst, &pdef, final_value, out)?;
                                return Ok(Value::Unit);
                            }
                        }
                    }
                    if let Some((_, d)) = &name_hit {
                        if *d <= *this_depth {
                            // Lexical binding wins (method param / local /
                            // ctor-env pre-bind). Still mirror to the
                            // instance when this is the backing field for a
                            // class property — keeps `g.message` consistent
                            // after init-block assignments.
                            env.borrow_mut().assign(name, final_value.clone())?;
                            if inst.borrow().get(name).is_some() {
                                inst.borrow_mut().define(name, final_value);
                            }
                            return Ok(Value::Unit);
                        }
                    }
                    if inst.borrow().get(name).is_some() {
                        inst.borrow_mut().define(name, final_value.clone());
                        let _ = env.borrow_mut().assign(name, final_value);
                        return Ok(Value::Unit);
                    }
                    for comp in class.all_companions() {
                        if comp.borrow().get(name).is_some() {
                            comp.borrow_mut().define(name, final_value);
                            return Ok(Value::Unit);
                        }
                    }
                    let mut cur_outer = inst.borrow().outer.clone();
                    while let Some(Value::Instance(oi)) = cur_outer {
                        if oi.borrow().get(name).is_some() {
                            oi.borrow_mut().define(name, final_value.clone());
                            let _ = env.borrow_mut().assign(name, final_value);
                            return Ok(Value::Unit);
                        }
                        cur_outer = oi.borrow().outer.clone();
                    }
                }
                env.borrow_mut().assign(name, final_value)?;
                Ok(Value::Unit)
            }
        }
    }

    fn eval_expr(
        &mut self,
        expr: &Expr,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match expr {
            Expr::IntLit { value, kind, .. } => match kind {
                klio_ast::IntLitKind::Long => Ok(Value::Long(*value)),
                klio_ast::IntLitKind::Int => Ok(Value::new_int(*value as i32)),
                klio_ast::IntLitKind::UInt => Ok(Value::UInt(*value as u32)),
                klio_ast::IntLitKind::ULong => Ok(Value::ULong(*value as u64)),
            },
            Expr::BoolLit { value, .. } => Ok(Value::Bool(*value)),
            Expr::NullLit { .. } => Ok(Value::Null),
            Expr::FloatLit { value, kind, .. } => match kind {
                klio_ast::FloatLitKind::Float => Ok(Value::Float(*value as f32)),
                klio_ast::FloatLitKind::Double => Ok(Value::Double(*value)),
            },
            Expr::CharLit { value, .. } => Ok(Value::Char(*value)),
            Expr::StringTemplate { parts, .. } => {
                let mut s = String::new();
                for part in parts {
                    match part {
                        StringPart::Text(t) => s.push_str(t),
                        StringPart::ShortInterp(id) => {
                            let v = self.lookup_with_this(&id.name, env, out)?;
                            let r = self.format_value(&v, out)?;
                            s.push_str(&r);
                        }
                        StringPart::Interp(e) => {
                            let v = self.eval_expr(e, env, out)?;
                            let r = self.format_value(&v, out)?;
                            s.push_str(&r);
                        }
                    }
                }
                Ok(Value::String(Rc::new(s)))
            }
            Expr::Path { segments, .. } => {
                // Single-segment paths first try the lexical env, then fall
                // back to a property access on the implicit `this` receiver
                // (matches how Kotlin resolves bare names inside a lambda
                // with receiver).
                if segments.len() == 1 {
                    let name = &segments[0].name;
                    // Spec §10.1 renaming imports: an `import path.X as Y`
                    // shadows the implicit-prelude `X` in this file. If `X`
                    // appears unqualified and would only resolve through the
                    // prelude (nothing local provides it), report the rename.
                    if let Some(alias) = self.import_renames.get(name) {
                        if env.borrow().lookup_excluding(name, &self.globals).is_none() {
                            return Err(RuntimeError::Unbound(format!(
                                "{name} (renamed to `{alias}` by an import in this file)"
                            )));
                        }
                    }
                    // A top-level property with a delegate or custom
                    // accessor takes precedence over a plain env lookup
                    // so reads route through `getValue` / the getter.
                    if let Some(pdef) = self.top_level_props.get(name).cloned() {
                        if pdef.delegate.is_some() || pdef.getter.is_some() {
                            return self.read_top_level_property(&pdef, env, out);
                        }
                    }
                    // Bare-name dispatch on `this` for a computed /
                    // delegated property — before any env lookup that
                    // would surface the pre-bound (stale or null) field.
                    if let Some(Value::Instance(inst)) = env.borrow().lookup("this") {
                        let class = Rc::clone(&inst.borrow().class);
                        if let Some((pdef, _)) = class.find_body_property(name) {
                            if pdef.delegate.is_some() || pdef.getter.is_some() {
                                return self.read_instance_property(&inst, &pdef, out);
                            }
                        }
                    }
                    // Compare a lexical binding for `name` against any
                    // enclosing `this`-instance field by scope depth. A
                    // local `val name = ...` lives in a child block scope
                    // (closer than `this`), so it wins. A pre-existing
                    // captured-env binding (top-level intrinsic, outer
                    // function param) lives further out than the `this` of
                    // the method body, so the class field shadows it.
                    let name_hit = env.borrow().lookup_with_depth(name);
                    let this_chain = env.borrow().lookup_all_with_depth("this");
                    let innermost_this = this_chain.first().map(|(v, _)| v.clone());
                    for (this_val, this_depth) in &this_chain {
                        let resolved_via_class = || -> Option<Value> {
                            let Value::Instance(inst) = this_val else { return None };
                            if let Some(v) = inst.borrow().get(name) {
                                return Some(v);
                            }
                            let class = Rc::clone(&inst.borrow().class);
                            for comp in class.all_companions() {
                                if let Some(v) = comp.borrow().get(name) {
                                    return Some(v);
                                }
                            }
                            if class.is_object {
                                if let Some(enc) = class.enclosing_class.borrow().clone() {
                                    if enc.is_enum {
                                        if name == "entries" {
                                            let items: Vec<Value> = enc
                                                .enum_entries
                                                .borrow()
                                                .iter()
                                                .map(|(_, v)| v.clone())
                                                .collect();
                                            return Some(Value::List {
                                                items: Rc::new(RefCell::new(items)),
                                                mutable: false,
                                                enum_class: Some(Rc::new(enc.name.clone())),
                                            });
                                        }
                                        for (n, v) in enc.enum_entries.borrow().iter() {
                                            if n == name {
                                                return Some(v.clone());
                                            }
                                        }
                                    }
                                }
                            }
                            // Inside an enum class's own method bodies, bare
                            // `RED` / `GREEN` resolve to the entry, and bare
                            // `entries` yields the entry list.
                            if class.is_enum {
                                if name == "entries" {
                                    let items: Vec<Value> = class
                                        .enum_entries
                                        .borrow()
                                        .iter()
                                        .map(|(_, v)| v.clone())
                                        .collect();
                                    return Some(Value::List {
                                        items: Rc::new(RefCell::new(items)),
                                        mutable: false,
                                        enum_class: Some(Rc::new(class.name.clone())),
                                    });
                                }
                                for (n, v) in class.enum_entries.borrow().iter() {
                                    if n == name {
                                        return Some(v.clone());
                                    }
                                }
                            }
                            let mut cur_outer = inst.borrow().outer.clone();
                            while let Some(Value::Instance(oi)) = cur_outer {
                                if let Some(v) = oi.borrow().get(name) {
                                    return Some(v);
                                }
                                cur_outer = oi.borrow().outer.clone();
                            }
                            // Nested class / nested object on the
                            // enclosing class chain. `class A { class B }`
                            // — inside A's method body, bare `B` resolves
                            // to the nested classifier (object → singleton,
                            // class → Value::Class).
                            let mut cur_cls: Option<Rc<ClassDef>> = Some(Rc::clone(&class));
                            while let Some(cc) = cur_cls {
                                if let Some(nc) = lookup_nested_class(&cc, name) {
                                    if nc.is_object {
                                        if let Some(inst) = nc.object_singleton.borrow().clone() {
                                            return Some(Value::Instance(inst));
                                        }
                                    }
                                    return Some(Value::Class(nc));
                                }
                                cur_cls = cc.enclosing_class.borrow().clone();
                            }
                            None
                        };
                        // If a lexical binding lives strictly closer than this
                        // `this`, take it: a `val name = ...` introduced inside
                        // the method body shadows the class field.
                        if let Some((v, d)) = &name_hit {
                            if *d <= *this_depth {
                                if let Some(prop_name) = lateinit_sentinel_name(v) {
                                    return Err(lateinit_throw(&prop_name));
                                }
                                return Ok(v.clone());
                            }
                        }
                        if let Some(v) = resolved_via_class() {
                            if let Some(prop_name) = lateinit_sentinel_name(&v) {
                                return Err(lateinit_throw(&prop_name));
                            }
                            return Ok(v);
                        }
                    }
                    if let Some((v, _)) = name_hit {
                        if let Some(prop_name) = lateinit_sentinel_name(&v) {
                            return Err(lateinit_throw(&prop_name));
                        }
                        return Ok(v);
                    }
                    if let Some(this_val) = innermost_this {
                        let fqn = format!("{}.{}", this_val.type_fqn(), name);
                        if let Some(func) = self.lookup_intrinsic(&fqn) {
                            let args = [this_val];
                            let mut ctx = CallCtx { args: &args, out };
                            return func(&mut ctx);
                        }
                    }
                    // Typealias redirection: `typealias S = Foo` with `S(...)`
                    // at the call site has the parser produce `Expr::Path["S"]`
                    // here. If `S` itself isn't bound but resolves to a name
                    // that is, hand back that value so a downstream `Call`
                    // can invoke the underlying constructor.
                    let aliased = self.resolve_type_alias(name);
                    if aliased != *name {
                        if let Some(v) = env.borrow().lookup(&aliased) {
                            return Ok(v);
                        }
                    }
                    return Err(RuntimeError::Unbound(name.clone()));
                }
                self.eval_path(segments, env)
            }
            Expr::Call { callee, args, arg_names, type_args, is_infix, span } => {
                // tailrec interception: if we're inside a tailrec function
                // and this exact call span is a recognized tail-position
                // self call, evaluate the arguments (spread-aware) and
                // bubble `TailContinue` so the trampoline rebinds and loops.
                if let Some(top) = self.tailrec_stack.last() {
                    if top.sites.contains(span) {
                        if let Some(callee_name) = simple_callee_name(callee) {
                            if callee_name == top.name {
                                let (vals, mask) = self.eval_args_with_spread(args, env, out)?;
                                let flat = flatten_spreads(vals, &mask);
                                return Err(RuntimeError::TailContinue(flat, arg_names.to_vec()));
                            }
                            // Mutual tailrec: a tail-position call to
                            // another top-level `tailrec` function hops
                            // through the enclosing trampoline so the
                            // chain reuses a single host frame.
                            let callee_val = env.borrow().lookup(callee_name);
                            if let Some(Value::Function { decl, .. }) = &callee_val {
                                if decl.is_tailrec {
                                    let (vals, mask) = self.eval_args_with_spread(args, env, out)?;
                                    let flat = flatten_spreads(vals, &mask);
                                    return Err(RuntimeError::TailJump(
                                        callee_val.clone().unwrap(),
                                        flat,
                                        arg_names.to_vec(),
                                    ));
                                }
                            }
                        }
                    }
                }
                if *is_infix {
                    if let Some(name) = simple_callee_name(callee) {
                        let known_top = env.borrow().lookup(name).is_some();
                        if !known_top {
                            if let Some(lowered) =
                                lower_infix_call(callee, args, arg_names, type_args, *span)
                            {
                                return self.eval_expr(&lowered, env, out);
                            }
                        }
                    }
                }
                self.eval_call(callee, args, arg_names, type_args, env, out)
            }
            Expr::Binary { op, lhs, rhs, .. } => {
                if matches!(op, BinOp::And | BinOp::Or) {
                    let l = self.eval_expr(lhs, env, out)?;
                    let Value::Bool(lb) = l else {
                        return Err(RuntimeError::Type("logical op requires Bool".into()));
                    };
                    if matches!(op, BinOp::And) && !lb {
                        return Ok(Value::Bool(false));
                    }
                    if matches!(op, BinOp::Or) && lb {
                        return Ok(Value::Bool(true));
                    }
                    let r = self.eval_expr(rhs, env, out)?;
                    let Value::Bool(rb) = r else {
                        return Err(RuntimeError::Type("logical op requires Bool".into()));
                    };
                    return Ok(Value::Bool(rb));
                }
                // Elvis short-circuits: only evaluate the RHS when LHS
                // is null. This matters when the RHS has side effects
                // (e.g. `m[key] ?: error("…")`).
                if matches!(op, BinOp::Elvis) {
                    let l = self.eval_expr(lhs, env, out)?;
                    return if matches!(l, Value::Null) {
                        self.eval_expr(rhs, env, out)
                    } else {
                        Ok(l)
                    };
                }
                let l = self.eval_expr(lhs, env, out)?;
                let r = self.eval_expr(rhs, env, out)?;
                // `x in y` / `x !in y` — membership / range tests outside `when`.
                if matches!(op, BinOp::In | BinOp::NotIn) {
                    let inside = if let Some(b) = self.try_user_contains_dispatch(&l, &r, out)? {
                        b
                    } else {
                        value_in(&l, &r)?
                    };
                    let result = if matches!(op, BinOp::NotIn) { !inside } else { inside };
                    return Ok(Value::Bool(result));
                }
                // Spec §8.9.2: when an `==` operand is "boxed" through `as Any`
                // / `as Any?`, equality follows `Any.equals` (which on JVM is
                // bit-equality for floats: NaN equals NaN, 0.0 != -0.0).
                // Detect the boxed form syntactically; the precise spec rule
                // requires static type info we don't thread here.
                if matches!(op, BinOp::Eq | BinOp::Neq)
                    && (self.is_boxed_operand(lhs) || self.is_boxed_operand(rhs))
                {
                    let eq = match (&l, &r) {
                        (Value::Double(a), Value::Double(b)) => a.to_bits() == b.to_bits(),
                        (Value::Float(a), Value::Float(b)) => a.to_bits() == b.to_bits(),
                        _ => Value::structural_eq(&l, &r),
                    };
                    let res = if matches!(op, BinOp::Eq) { eq } else { !eq };
                    return Ok(Value::Bool(res));
                }
                // Spec §4.1.2: a data class inheriting equals from a base
                // (final or open) defers to the inherited body. Eq/Neq on
                // instances first checks for a user-declared `equals` method
                // body in the chain via `find_method`. Found → call it.
                // Not found → fall through to `structural_eq` as before.
                if matches!(op, BinOp::Eq | BinOp::Neq) {
                    if let Value::Instance(inst) = &l {
                        let class = Rc::clone(&inst.borrow().class);
                        if let Some((m, owner)) = class.find_method("equals") {
                            if m.decl.body.is_some() {
                                let v = self.call_method_with_owner(
                                    inst, &owner, &m, &[r.clone()], &[None], out,
                                )?;
                                let b = matches!(v, Value::Bool(true));
                                return Ok(Value::Bool(if matches!(op, BinOp::Eq) { b } else { !b }));
                            }
                        }
                    }
                }
                // Ordered comparisons against user instances (incl. enum
                // entries) dispatch through `compare_with_user` so user
                // `compareTo` and enum-ordinal ordering both work.
                if matches!(op, BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge)
                    && (matches!(l, Value::Instance(_)) || matches!(r, Value::Instance(_)))
                {
                    let ord = self.compare_with_user(&l, &r, out)?;
                    let res = match op {
                        BinOp::Lt => ord.is_lt(),
                        BinOp::Le => ord.is_le(),
                        BinOp::Gt => ord.is_gt(),
                        BinOp::Ge => ord.is_ge(),
                        _ => unreachable!(),
                    };
                    return Ok(Value::Bool(res));
                }
                // Spec ch.9: arithmetic / range operators on user types lower
                // to `operator fun plus / minus / times / div / rem / rangeTo
                // / rangeUntil` calls on the LHS. Tried before the built-in
                // numeric rules so a `plus(Int)` overload on a user type wins
                // when the primitive arms can't apply.
                if matches!(
                    op,
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Rem
                        | BinOp::Range | BinOp::RangeUntil
                ) && matches!(l, Value::Instance(_))
                {
                    if let Some(v) = self.try_user_binop_dispatch(*op, &l, &r, out)? {
                        return Ok(v);
                    }
                }
                eval_binop(*op, l, r)
            }
            Expr::Unary { op, expr, .. } => {
                if matches!(op, UnOp::PreInc | UnOp::PreDec) {
                    return self.eval_prefix_incdec(*op, expr, env, out);
                }
                let v = self.eval_expr(expr, env, out)?;
                // Spec ch.9: unary operators on user types lower to
                // `unaryPlus` / `unaryMinus` / `not`.
                if matches!(op, UnOp::Pos | UnOp::Neg | UnOp::Not)
                    && matches!(v, Value::Instance(_))
                {
                    if let Some(r) = self.try_user_unop_dispatch(*op, &v, out)? {
                        return Ok(r);
                    }
                }
                eval_unop(*op, v)
            }
            Expr::Postfix { op, expr, .. } => self.eval_postfix(*op, expr, env, out),
            Expr::If { cond, then_branch, else_branch, .. } => {
                let c = self.eval_expr(cond, env, out)?;
                let Value::Bool(b) = c else {
                    return Err(RuntimeError::Type("`if` condition must be Bool".into()));
                };
                if b {
                    self.eval_expr(then_branch, env, out)
                } else if let Some(e) = else_branch {
                    self.eval_expr(e, env, out)
                } else {
                    Ok(Value::Unit)
                }
            }
            Expr::DoWhile { body, cond, .. } => {
                let pushed_here = if self.label_already_pushed_for_loop {
                    self.label_already_pushed_for_loop = false;
                    false
                } else {
                    self.loop_label_stack.push(None);
                    true
                };
                let result = (|| -> Result<Value, RuntimeError> {
                    loop {
                        if let Some(body) = body {
                            match self.eval_expr(body, env, out) {
                                Ok(_) => {}
                                Err(RuntimeError::Break) => break,
                                Err(RuntimeError::Continue) => {}
                                Err(RuntimeError::LabeledBreak(ref l))
                                    if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                                {
                                    break
                                }
                                Err(RuntimeError::LabeledContinue(ref l))
                                    if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                                {
                                    // fall through to condition check
                                }
                                Err(e) => return Err(e),
                            }
                        }
                        let c = self.eval_expr(cond, env, out)?;
                        let Value::Bool(b) = c else {
                            return Err(RuntimeError::Type("`do-while` condition must be Bool".into()));
                        };
                        if !b {
                            break;
                        }
                    }
                    Ok(Value::Unit)
                })();
                if pushed_here {
                    self.loop_label_stack.pop();
                }
                result
            }
            Expr::While { cond, body, .. } => {
                let pushed_here = if self.label_already_pushed_for_loop {
                    self.label_already_pushed_for_loop = false;
                    false
                } else {
                    self.loop_label_stack.push(None);
                    true
                };
                let result = (|| -> Result<Value, RuntimeError> {
                    loop {
                        let c = self.eval_expr(cond, env, out)?;
                        let Value::Bool(b) = c else {
                            return Err(RuntimeError::Type("`while` condition must be Bool".into()));
                        };
                        if !b {
                            break;
                        }
                        match self.eval_expr(body, env, out) {
                            Ok(_) => {}
                            Err(RuntimeError::Break) => break,
                            Err(RuntimeError::Continue) => continue,
                            Err(RuntimeError::LabeledBreak(ref l))
                                if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                            {
                                break
                            }
                            Err(RuntimeError::LabeledContinue(ref l))
                                if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                            {
                                continue
                            }
                            Err(e) => return Err(e),
                        }
                    }
                    Ok(Value::Unit)
                })();
                if pushed_here {
                    self.loop_label_stack.pop();
                }
                result
            }
            Expr::For { vars, iter, body, .. } => {
                let it = self.eval_expr(iter, env, out)?;
                let items: Box<dyn Iterator<Item = Value>> = match it {
                    Value::Range { start, end, step, kind } => {
                        let it = range_iter(start, end, step);
                        match kind {
                            klio_runtime::RangeKind::Long => Box::new(it.map(Value::Long)),
                            klio_runtime::RangeKind::Int => {
                                Box::new(it.map(|v| Value::new_int(v as i32)))
                            }
                            klio_runtime::RangeKind::Char => Box::new(it.map(|v| {
                                char::from_u32(v as u32).map(Value::Char).unwrap_or(Value::Null)
                            })),
                        }
                    }
                    Value::List { items, .. } => {
                        Box::new(items.borrow().clone().into_iter())
                    }
                    Value::Array { items, .. } => {
                        Box::new(items.borrow().clone().into_iter())
                    }
                    Value::Set { items, .. } => {
                        Box::new(items.borrow().clone().into_iter())
                    }
                    Value::Map { entries, .. } => {
                        let snapshot: Vec<Value> = entries
                            .borrow()
                            .iter()
                            .map(|(k, v)| Value::MapEntry {
                                key: Box::new(k.clone()),
                                value: Box::new(v.clone()),
                            })
                            .collect();
                        Box::new(snapshot.into_iter())
                    }
                    Value::Sequence(data) => {
                        // Materialize lazily-evaluated upstream items into a
                        // Vec so `for (x in seq)` walks them once.
                        let items = self.materialize_sequence(&data, out)?;
                        Box::new(items.into_iter())
                    }
                    Value::String(s) => {
                        let chars: Vec<Value> = s.chars().map(Value::Char).collect();
                        Box::new(chars.into_iter())
                    }
                    other => {
                        // §7.2.3 fallback: drive the receiver as an iterable
                        // via overloadable `iterator()` / `hasNext()` / `next()`
                        // operator functions. Items are eagerly materialized
                        // into a Vec so the host iterator does not need to
                        // borrow `self` across the body evaluation.
                        let items = self.materialize_user_iterable(&other, env, out)?;
                        Box::new(items.into_iter())
                    }
                };
                let pushed_here = if self.label_already_pushed_for_loop {
                    self.label_already_pushed_for_loop = false;
                    false
                } else {
                    self.loop_label_stack.push(None);
                    true
                };
                let mut loop_result: Result<Value, RuntimeError> = Ok(Value::Unit);
                for v in items {
                    let scope = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
                    if vars.len() == 1 {
                        scope.borrow_mut().define(vars[0].name.clone(), v);
                    } else {
                        let components = match destructure_components(self, &v, vars, out) {
                            Ok(c) => c,
                            Err(e) => {
                                loop_result = Err(e);
                                break;
                            }
                        };
                        for (var, c) in vars.iter().zip(components) {
                            // Spec ch.9: `_` placeholder binds nothing.
                            if var.name == "_" {
                                continue;
                            }
                            scope.borrow_mut().define(var.name.clone(), c);
                        }
                    }
                    match self.eval_expr(body, &scope, out) {
                        Ok(_) => {}
                        Err(RuntimeError::Break) => break,
                        Err(RuntimeError::Continue) => continue,
                        Err(RuntimeError::LabeledBreak(ref l))
                            if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                        {
                            break
                        }
                        Err(RuntimeError::LabeledContinue(ref l))
                            if matches!(self.loop_label_stack.last(), Some(Some(top)) if top == l) =>
                        {
                            continue
                        }
                        Err(e) => {
                            loop_result = Err(e);
                            break;
                        }
                    }
                }
                if pushed_here {
                    self.loop_label_stack.pop();
                }
                loop_result
            }
            Expr::Return { value, label, .. } => {
                let v = match value {
                    Some(e) => self.eval_expr(e, env, out)?,
                    None => Value::Unit,
                };
                match label {
                    Some(l) => Err(RuntimeError::LabeledReturn(l.name.clone(), v)),
                    None => Err(RuntimeError::Return(v)),
                }
            }
            Expr::Break { label, .. } => match label {
                Some(l) => Err(RuntimeError::LabeledBreak(l.name.clone())),
                None => Err(RuntimeError::Break),
            },
            Expr::Continue { label, .. } => match label {
                Some(l) => Err(RuntimeError::LabeledContinue(l.name.clone())),
                None => Err(RuntimeError::Continue),
            },
            Expr::Labeled { label, expr, .. } => {
                self.eval_labeled(&label.name, expr, env, out)
            }
            Expr::Block(b) => self.eval_block(b, env, out),
            Expr::Member { receiver, name, safe, .. } => {
                // Primitive companion-object constants: `Int.MAX_VALUE`,
                // `Double.NaN`, etc. The bare receiver name is not a
                // bound identifier, so intercept here before falling
                // through to the env-driven path.
                if !*safe {
                    if let Expr::Path { segments, .. } = receiver.as_ref() {
                        if segments.len() == 1 {
                            if let Some(v) =
                                primitive_companion_const(&segments[0].name, &name.name)
                            {
                                return Ok(v);
                            }
                        }
                    }
                }
                // `super.foo` — read a property from the parent class.
                if matches!(receiver.as_ref(), Expr::Super { .. }) {
                    let inst = match env.borrow().lookup("this") {
                        Some(Value::Instance(i)) => i,
                        _ => {
                            return Err(RuntimeError::Type(
                                "`super` is only valid inside an instance method".into(),
                            ));
                        }
                    };
                    // Instance fields (including parent-declared ones) live
                    // on the same field vec, so a property read just goes
                    // through the regular path.
                    if let Some(v) = inst.borrow().get(&name.name) {
                        return Ok(v);
                    }
                    return Err(RuntimeError::Unimplemented(format!(
                        "super.{}",
                        name.name
                    )));
                }
                // Try a flattened static lookup first (e.g. `kotlin.math.PI`).
                if !*safe {
                    if let Some(fqn) = try_qualified_name(expr) {
                        if let Some(func) = self.lookup_intrinsic(&fqn) {
                            let mut ctx = CallCtx { args: &[], out };
                            return func(&mut ctx);
                        }
                    }
                }
                let recv = self.eval_expr(receiver, env, out)?;
                if *safe && matches!(recv, Value::Null) {
                    return Ok(Value::Null);
                }
                self.eval_property_access(recv, &name.name, out)
            }
            Expr::Index { receiver, args, .. } => {
                let recv = self.eval_expr(receiver, env, out)?;
                // Array indexing — single Int argument.
                if let Value::Array { items, .. } = &recv {
                    if args.len() != 1 {
                        return Err(RuntimeError::Type(
                            "Array indexing takes one Int argument".into(),
                        ));
                    }
                    let idx = self.eval_expr(&args[0], env, out)?;
                    let Some(i) = idx.as_i64() else {
                        return Err(RuntimeError::Type(
                            "Array indexing requires an Int".into(),
                        ));
                    };
                    let items_ref = items.borrow();
                    let n = items_ref.len() as i64;
                    if i < 0 || i >= n {
                        return Err(RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new(
                                "kotlin.IndexOutOfBoundsException".to_string(),
                            ),
                            message: Some(Rc::new(format!(
                                "Index {i} out of bounds for length {n}"
                            ))),
                            cause: None,
                        }));
                    }
                    return Ok(items_ref[i as usize].clone());
                }
                // User-class indexed read — dispatch `operator fun get`.
                if let Value::Instance(inst) = &recv {
                    let class = Rc::clone(&inst.borrow().class);
                    let mut idx_vals: Vec<Value> = Vec::with_capacity(args.len());
                    for a in args {
                        idx_vals.push(self.eval_expr(a, env, out)?);
                    }
                    let first_arg_type = idx_vals.first().map(value_runtime_type_name);
                    if let Some((m, _)) = class.find_method_for_arg("get", first_arg_type.as_deref()) {
                        let arg_names: Vec<Option<String>> = vec![None; idx_vals.len()];
                        return self.call_method(inst, &m, &idx_vals, &arg_names, out);
                    }
                }
                let mut arg_vals = Vec::with_capacity(args.len() + 1);
                arg_vals.push(recv);
                for a in args {
                    arg_vals.push(self.eval_expr(a, env, out)?);
                }
                let fqn = format!("{}.get", arg_vals[0].type_fqn());
                let Some(func) = self.lookup_intrinsic(&fqn) else {
                    return Err(RuntimeError::Unimplemented(fqn));
                };
                let mut ctx = CallCtx { args: &arg_vals, out };
                func(&mut ctx)
            }
            Expr::Throw { value, .. } => {
                let v = self.eval_expr(value, env, out)?;
                Err(RuntimeError::Thrown(v))
            }
            Expr::Try { body, catches, finally, .. } => {
                self.eval_try(body, catches, finally.as_ref(), env, out)
            }
            Expr::Lambda { params, body, .. } => Ok(Value::Lambda {
                params: Rc::new(params.iter().map(|p| p.name.clone()).collect()),
                body: Rc::new(body.clone()),
                env: Rc::clone(env),
                absorb_return: false,
            }),
            Expr::This { qualifier: Some(label), .. } => {
                let qname = format!("this@{}", label.name);
                env.borrow().lookup(&qname).ok_or_else(|| {
                    RuntimeError::Type(format!(
                        "`{qname}` is not bound in this scope"
                    ))
                })
            }
            Expr::This { qualifier: None, .. } => env
                .borrow()
                .lookup("this")
                .ok_or_else(|| RuntimeError::Type("`this` is not bound in this scope".into())),
            Expr::Super { .. } => Err(RuntimeError::Type(
                "`super` may only be used as the receiver of a member access".into(),
            )),
            Expr::PropertyRef { name, .. } => {
                // `::ClassName` resolves to a class reference when the name
                // is in scope as a class. `::topLevelFn` resolves to a
                // function reference. Everything else falls back to the
                // lightweight `Value::PropertyRef` used by delegate
                // `getValue` / `setValue`.
                if let Some(v) = env.borrow().lookup(&name.name) {
                    if matches!(v, Value::Class(_) | Value::Function { .. }) {
                        return Ok(v);
                    }
                }
                Ok(Value::PropertyRef { name: Rc::new(name.name.clone()) })
            }
            Expr::MemberRef { receiver, name, .. } => {
                // `T::class` / `Int::class` — resolve through the reified
                // frame, then look the resolved name up through file scope
                // and globals. When the resolved name is a Kotlin primitive
                // (or other classifier without a user-side `Value::Class`),
                // synthesize one so `simpleName` / `qualifiedName` work.
                if let Expr::Path { segments, .. } = receiver.as_ref() {
                    if segments.len() == 1 {
                        let raw = &segments[0].name;
                        let resolved = self.resolve_reified(raw);
                        let lookup = env
                            .borrow()
                            .lookup(&resolved)
                            .or_else(|| self.globals.borrow().lookup(&resolved));
                        if let Some(v) = lookup {
                            return self.eval_member_ref(&v, &name.name);
                        }
                        if let Some(v) = self.synth_primitive_class(&resolved) {
                            return self.eval_member_ref(&v, &name.name);
                        }
                    }
                }
                let recv = self.eval_expr(receiver, env, out)?;
                self.eval_member_ref(&recv, &name.name)
            }
            Expr::IsCheck { expr, ty, negated, .. } => {
                let v = self.eval_expr(expr, env, out)?;
                let resolved = self.resolve_type_alias(&self.resolve_reified(&ty.name.name));
                let mut matched = v.is_runtime_type(&resolved);
                if !matched && matches!(v, Value::Null) {
                    // `null is T?` → true for nullable types; we don't track
                    // nullability on TypeRef beyond the parsed flag.
                    matched = ty.nullable;
                }
                Ok(Value::Bool(matched ^ *negated))
            }
            Expr::As { expr, ty, safe, .. } => {
                let v = self.eval_expr(expr, env, out)?;
                let resolved = self.resolve_type_alias(&self.resolve_reified(&ty.name.name));
                let matched = if matches!(v, Value::Null) {
                    ty.nullable
                } else {
                    v.is_runtime_type(&resolved)
                };
                if matched {
                    Ok(v)
                } else if *safe {
                    Ok(Value::Null)
                } else if self.is_erased_type_param(&resolved) {
                    // Spec §15.1: `as T` where T is a non-reified
                    // type parameter is an unchecked cast — the
                    // runtime cannot verify it because T is erased,
                    // so the value passes through. T0083 covers the
                    // static diagnostic at the typechecker side.
                    Ok(v)
                } else {
                    let actual = if matches!(v, Value::Null) {
                        "null".to_string()
                    } else {
                        v.type_fqn().to_string()
                    };
                    Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.ClassCastException".to_string()),
                        message: Some(Rc::new(format!(
                            "class {actual} cannot be cast to class {}",
                            ty.name.name
                        ))),
                        cause: None,
                    }))
                }
            }
            Expr::AnonFun { params, body, span, .. } => {
                let block = match body.as_deref() {
                    Some(FunctionBody::Block(b)) => b.clone(),
                    Some(FunctionBody::Expr(e)) => klio_ast::Block {
                        stmts: vec![klio_ast::Stmt::Expr(klio_ast::Expr::Return {
                            value: Some(Box::new(e.clone())),
                            label: None,
                            span: e.span(),
                        })],
                        span: e.span(),
                    },
                    None => klio_ast::Block { stmts: Vec::new(), span: *span },
                };
                Ok(Value::Lambda {
                    params: Rc::new(params.iter().map(|p| p.name.name.clone()).collect()),
                    body: Rc::new(block),
                    env: Rc::clone(env),
                    absorb_return: true,
                })
            }
            Expr::When { subject, subject_binding, branches, span } => {
                self.eval_when(
                    subject.as_deref(),
                    subject_binding.as_ref(),
                    branches,
                    *span,
                    env,
                    out,
                )
            }
            Expr::Spread { span, .. } => Err(RuntimeError::Unimplemented(format!(
                "`*` spread is only valid as a value-argument at a call site (at {:?})",
                span
            ))),
            Expr::ObjectExpr { supertypes, supertype_args, supertype_delegates, members, span } => {
                self.eval_object_expr(
                    supertypes,
                    supertype_args,
                    supertype_delegates,
                    members,
                    *span,
                    env,
                    out,
                )
            }
        }
    }

    /// Build a fresh anonymous `ClassDef` for an `object { … }` expression,
    /// closure-capture the enclosing env, run construction (including parent
    /// ctor invocation when a concrete supertype was provided), and return
    /// the single resulting instance.
    fn eval_object_expr(
        &mut self,
        supertypes: &[klio_ast::TypeRef],
        supertype_args: &[Option<Vec<Expr>>],
        supertype_delegates: &[Option<Expr>],
        members: &[Decl],
        span: klio_span::Span,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.anon_class_counter += 1;
        let anon_name = format!("<no name provided>");
        let synth = klio_ast::Class {
            name: klio_ast::Ident { name: anon_name, span },
            type_params: Vec::new(),
            where_bounds: Vec::new(),
            primary_params: Vec::new(),
            init_blocks: Vec::new(),
            supertypes: supertypes.to_vec(),
            supertype_args: supertype_args.to_vec(),
            supertype_delegates: supertype_delegates.to_vec(),
            is_data: false,
            is_companion: false,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            secondary_ctors: Vec::new(),
            is_interface: false,
            is_fun_interface: false,
            is_value: false,
            is_annotation: false,
            enum_entries: Vec::new(),
            members: members.to_vec(),
            visibility: klio_ast::Visibility::Public,
            primary_ctor_visibility: None,
            annotations: Vec::new(),
            span,
        };
        let class = self.build_class_shell(&synth, env, out)?;
        self.resolve_parent_link(&class);
        // Anonymous objects are singletons-with-a-parent. Construct via the
        // regular instance pipeline so a `: Parent(args)` clause runs the
        // parent ctor chain; mark the class as object-like so display
        // matches the kotlinc-native shape for trivial cases.
        let v = self.construct_instance(&class, &[], &[], out)?;
        Ok(v)
    }

    fn eval_when(
        &mut self,
        subject: Option<&Expr>,
        subject_binding: Option<&klio_ast::WhenBinding>,
        branches: &[klio_ast::WhenBranch],
        _span: klio_span::Span,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let subject_val = match subject {
            Some(e) => Some(self.eval_expr(e, env, out)?),
            None => None,
        };
        // `when (val v = subject)` — bind `v` in a fresh scope visible only
        // to the branch bodies.
        let scope = if let (Some(binding), Some(v)) = (subject_binding, &subject_val) {
            let s = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
            s.borrow_mut().define(binding.name.name.clone(), v.clone());
            s
        } else {
            Rc::clone(env)
        };
        let env = &scope;
        for branch in branches {
            let mut fire = false;
            for p in &branch.patterns {
                match &p.kind {
                    klio_ast::WhenPatternKind::Else => {
                        fire = true;
                    }
                    klio_ast::WhenPatternKind::Value(e) => {
                        match &subject_val {
                            Some(s) => {
                                let rhs = self.eval_expr(e, env, out)?;
                                if Value::structural_eq(s, &rhs) {
                                    fire = true;
                                }
                            }
                            None => {
                                let v = self.eval_expr(e, env, out)?;
                                let Value::Bool(b) = v else {
                                    return Err(RuntimeError::Type(
                                        "subject-free `when` branch must be Boolean".into(),
                                    ));
                                };
                                if b {
                                    fire = true;
                                }
                            }
                        }
                    }
                    klio_ast::WhenPatternKind::InRange(e) => {
                        let Some(s) = &subject_val else {
                            return Err(RuntimeError::Type(
                                "`in` pattern requires a when subject".into(),
                            ));
                        };
                        let rhs = self.eval_expr(e, env, out)?;
                        if value_in(s, &rhs)? {
                            fire = true;
                        }
                    }
                    klio_ast::WhenPatternKind::NotInRange(e) => {
                        let Some(s) = &subject_val else {
                            return Err(RuntimeError::Type(
                                "`!in` pattern requires a when subject".into(),
                            ));
                        };
                        let rhs = self.eval_expr(e, env, out)?;
                        if !value_in(s, &rhs)? {
                            fire = true;
                        }
                    }
                    klio_ast::WhenPatternKind::IsType(ty) => {
                        let Some(s) = &subject_val else {
                            return Err(RuntimeError::Type(
                                "`is` pattern requires a when subject".into(),
                            ));
                        };
                        if s.is_runtime_type(&ty.name.name) {
                            fire = true;
                        }
                    }
                    klio_ast::WhenPatternKind::NotIsType(ty) => {
                        let Some(s) = &subject_val else {
                            return Err(RuntimeError::Type(
                                "`!is` pattern requires a when subject".into(),
                            ));
                        };
                        if !s.is_runtime_type(&ty.name.name) {
                            fire = true;
                        }
                    }
                }
                if fire {
                    break;
                }
            }
            if fire {
                return self.eval_expr(&branch.body, env, out);
            }
        }
        // No branch matched. Kotlin runtime throws NoWhenBranchMatchedException
        // with the exact message:
        // "No matching branch was found for given input."
        Err(RuntimeError::Thrown(Value::Exception {
            fqn: Rc::new("kotlin.NoWhenBranchMatchedException".to_string()),
            message: None,
            cause: None,
        }))
    }

    fn eval_try(
        &mut self,
        body: &Block,
        catches: &[klio_ast::Catch],
        finally: Option<&Block>,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let body_result = self.eval_block(body, env, out);
        let result_after_catch = match body_result {
            Err(RuntimeError::Thrown(thrown)) => {
                let mut handled: Option<Result<Value, RuntimeError>> = None;
                for c in catches {
                    if exception_matches(&thrown, &c.ty.name.name) {
                        let scope = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
                        scope.borrow_mut().define(c.binding.name.clone(), thrown.clone());
                        handled = Some(self.eval_block(&c.body, &scope, out));
                        break;
                    }
                }
                handled.unwrap_or(Err(RuntimeError::Thrown(thrown)))
            }
            other => other,
        };

        if let Some(fb) = finally {
            // Finally always runs; if it errors, that error wins.
            let fin = self.eval_block(fb, env, out);
            if let Err(e) = fin {
                return Err(e);
            }
        }
        result_after_catch
    }

    /// Evaluate `label@ inner`. When `inner` is a loop we run the loop
    /// directly so a matching labeled `continue` resumes the loop's next
    /// iteration; otherwise (lambda / `run { ... }` / plain expressions)
    /// we evaluate and catch a matching labeled return / break.
    fn eval_labeled(
        &mut self,
        label: &str,
        inner: &Expr,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match inner {
            Expr::For { .. } | Expr::While { .. } | Expr::DoWhile { .. } => {
                self.loop_label_stack.push(Some(label.to_string()));
                self.label_already_pushed_for_loop = true;
                let result = self.eval_expr(inner, env, out);
                // The For / While evaluator pops only when it pushed its
                // own `None` placeholder; we always pop the entry we put
                // on here.
                self.loop_label_stack.pop();
                self.label_already_pushed_for_loop = false;
                match result {
                    Err(RuntimeError::LabeledBreak(ref l)) if l == label => Ok(Value::Unit),
                    other => other,
                }
            }
            _ => {
                let result = self.eval_expr(inner, env, out);
                match result {
                    Ok(v) => Ok(v),
                    Err(RuntimeError::LabeledReturn(ref l, v)) if l == label => Ok(v),
                    Err(RuntimeError::LabeledBreak(ref l)) if l == label => Ok(Value::Unit),
                    Err(e) => Err(e),
                }
            }
        }
    }

    fn call_lambda(
        &mut self,
        params: &[String],
        body: &klio_ast::Block,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.call_lambda_with_this(params, body, captured_env, args, None, false, out)
    }

    fn call_lambda_with_this(
        &mut self,
        params: &[String],
        body: &klio_ast::Block,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        this_binding: Option<Value>,
        absorb_return: bool,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        // Implicit `it` parameter: a lambda literal without an arrow
        // header that takes exactly one argument binds the argument as
        // `it`. Anonymous functions never go through this path (their
        // declared param list is always explicit).
        let bind_it = params.is_empty() && args.len() == 1 && !absorb_return;
        if !bind_it && args.len() > params.len() {
            return Err(RuntimeError::Arity(format!(
                "lambda expects at most {} arguments, got {}",
                params.len(),
                args.len()
            )));
        }
        let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(captured_env))));
        for (i, name) in params.iter().enumerate() {
            let v = args.get(i).cloned().unwrap_or(Value::Null);
            frame.borrow_mut().define(name.clone(), v);
        }
        if bind_it {
            frame.borrow_mut().define("it".to_string(), args[0].clone());
        }
        if let Some(this_val) = this_binding {
            frame.borrow_mut().define("this", this_val);
        }
        let result = self.eval_block(body, &frame, out);
        let implicit_label = self.implicit_lambda_label_stack.last().cloned();
        match result {
            Ok(v) => Ok(v),
            // Anonymous-function bodies (`fun (...) { return v }`) catch
            // their own `return` — the value becomes the call's result.
            Err(RuntimeError::Return(v)) if absorb_return => Ok(v),
            // For lambda literals, a bare `return` is a non-local return
            // out of the enclosing function (the lambda is inline at the
            // dispatch site). Propagate the signal upward.
            Err(RuntimeError::LabeledReturn(l, v))
                if implicit_label.as_deref() == Some(l.as_str()) =>
            {
                Ok(v)
            }
            Err(e) => Err(e),
        }
    }

    /// Resolve a bare identifier: lexical env first, then the implicit-this
    /// fallback (for lambda-with-receiver scopes). Mirrors the resolution
    /// rule used by `Expr::Path` evaluation but reusable from places like
    /// string-template interpolation.
    fn lookup_with_this(
        &mut self,
        name: &str,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let name_hit = env.borrow().lookup_with_depth(name);
        let this_chain = env.borrow().lookup_all_with_depth("this");
        for (this_val, this_depth) in &this_chain {
            if let Some((v, d)) = &name_hit {
                if *d <= *this_depth {
                    return Ok(v.clone());
                }
            }
            if let Value::Instance(inst) = this_val {
                if let Some(v) = inst.borrow().get(name) {
                    return Ok(v);
                }
                let class = Rc::clone(&inst.borrow().class);
                for comp in class.all_companions() {
                    if let Some(v) = comp.borrow().get(name) {
                        return Ok(v);
                    }
                }
                let mut cur_outer = inst.borrow().outer.clone();
                while let Some(Value::Instance(oi)) = cur_outer {
                    if let Some(v) = oi.borrow().get(name) {
                        return Ok(v);
                    }
                    cur_outer = oi.borrow().outer.clone();
                }
            }
        }
        if let Some((v, _)) = name_hit {
            return Ok(v);
        }
        if let Some((this_val, _)) = this_chain.into_iter().next() {
            let fqn = format!("{}.{}", this_val.type_fqn(), name);
            if let Some(func) = self.lookup_intrinsic(&fqn) {
                let args = [this_val];
                let mut ctx = CallCtx { args: &args, out };
                return func(&mut ctx);
            }
        }
        Err(RuntimeError::Unbound(name.to_string()))
    }

    /// Invoke any callable `Value` (Lambda, Function, Intrinsic, bound
    /// method) with positional/named arguments. Used by member-call
    /// dispatch when a property holds a callable.
    pub fn invoke_callable_value(
        &mut self,
        callee: &Value,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match callee {
            Value::IrClosure { id, captures } => {
                self.invoke_ir_closure_with_host(*id, captures, args, out)
            }
            Value::Lambda { params, body, env, absorb_return } => {
                self.call_lambda_with_this(params, body, env, args, None, *absorb_return, out)
            }
            Value::Function { decl, env } => {
                self.call_function_named(decl, env, args, arg_names, out)
            }
            Value::Intrinsic { func, .. } => {
                let mut ctx = CallCtx { args, out };
                func(&mut ctx)
            }
            Value::BoundMethod { fqn, func, receiver } => {
                let mut all = Vec::with_capacity(args.len() + 1);
                all.push((**receiver).clone());
                all.extend_from_slice(args);
                let user_args = reorder_intrinsic_args(fqn, all, arg_names)?;
                let mut ctx = CallCtx { args: &user_args, out };
                func(&mut ctx)
            }
            Value::BoundUserMethod { receiver, method } => {
                self.call_method(receiver, method, args, arg_names, out)
            }
            _ => Err(RuntimeError::Type(format!(
                "value is not callable: {callee:?}"
            ))),
        }
    }

    pub fn invoke_lambda(
        &mut self,
        lambda: &Value,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Value::Lambda { params, body, env, absorb_return } = lambda else {
            return Err(RuntimeError::Type(format!(
                "expected a lambda, got {lambda:?}"
            )));
        };
        self.call_lambda_with_this(params, body, env, args, None, *absorb_return, out)
    }

    /// Invoke a lambda whose body may contain `return@<label>` where
    /// `label` is the name of the calling higher-order function (e.g.
    /// `forEach`, `map`, `filter`). Catches `LabeledReturn` matching that
    /// label so the non-local return terminates only the current lambda
    /// invocation. Spec §4.2 implicit lambda labels.
    pub fn invoke_lambda_labeled(
        &mut self,
        lambda: &Value,
        label: &str,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.implicit_lambda_label_stack.push(label.to_string());
        let r = self.invoke_lambda(lambda, args, out);
        self.implicit_lambda_label_stack.pop();
        r
    }

    /// Handles `receiver.{let,also,apply,run,takeIf,takeUnless}(lambda)`.
    /// Returns `Ok(Some(value))` when the name was a scoping fn (caller skips
    /// the normal intrinsic dispatch), `Ok(None)` otherwise.
    ///
    /// Receiver binding follows Kotlin semantics:
    ///   * `let`, `also`, `takeIf`, `takeUnless` bind the receiver as `it`.
    ///   * `apply`, `run` bind it as `this`.
    /// Top-level lambda-taking helpers: `repeat`, `runCatching`, `require`,
    /// `check`, `error`, `checkNotNull`, `requireNotNull`, `TODO`. Returns
    /// `Ok(Some(v))` when handled, `Ok(None)` to fall through.
    fn try_eval_top_level_lambda_helper(
        &mut self,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        match name {
            "run" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "`run` requires a lambda argument".into(),
                    ));
                };
                Ok(Some(self.call_lambda(params, body, captured, &[], out)?))
            }
            "suspend" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                if !matches!(lam, Value::Lambda { .. }) {
                    return Err(RuntimeError::Type(
                        "`suspend` requires a lambda argument".into(),
                    ));
                }
                Ok(Some(lam))
            }
            "buildList" | "buildSet" if (1..=2).contains(&args.len()) => {
                let lambda = args.last().unwrap();
                let lam = self.eval_expr(lambda, env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(format!("`{name}` requires a lambda argument")));
                };
                let mutable = Value::List {
                    items: Rc::new(RefCell::new(Vec::new())),
                    mutable: true,
                    enum_class: None,
                };
                self.call_lambda_with_this(params, body, captured, &[], Some(mutable.clone()), false, out)?;
                let Value::List { items, .. } = mutable else { unreachable!() };
                if name == "buildSet" {
                    let mut deduped: Vec<Value> = Vec::new();
                    for v in items.borrow().iter() {
                        if !deduped.iter().any(|x| Value::structural_eq(x, v)) {
                            deduped.push(v.clone());
                        }
                    }
                    return Ok(Some(Value::Set {
                        items: Rc::new(RefCell::new(deduped)),
                        mutable: false,
                    }));
                }
                Ok(Some(Value::List { items, mutable: false, enum_class: None }))
            }
            "buildMap" if (1..=2).contains(&args.len()) => {
                let lambda = args.last().unwrap();
                let lam = self.eval_expr(lambda, env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("`buildMap` requires a lambda argument".into()));
                };
                let mutable = Value::Map {
                    entries: Rc::new(RefCell::new(Vec::new())),
                    mutable: true,
                };
                self.call_lambda_with_this(params, body, captured, &[], Some(mutable.clone()), false, out)?;
                let Value::Map { entries, .. } = mutable else { unreachable!() };
                Ok(Some(Value::Map { entries, mutable: false }))
            }
            "buildString" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("`buildString` requires a lambda argument".into()));
                };
                let sb = Value::StringBuilder(Rc::new(RefCell::new(String::new())));
                self.call_lambda_with_this(params, body, captured, &[], Some(sb.clone()), false, out)?;
                let Value::StringBuilder(s) = sb else { unreachable!() };
                Ok(Some(Value::String(Rc::new(s.borrow().clone()))))
            }
            "repeat" if args.len() == 2 => {
                let n = self.eval_expr(&args[0], env, out)?;
                let lam = self.eval_expr(&args[1], env, out)?;
                let Value::Int(n) = n else {
                    return Err(RuntimeError::Type("repeat requires an Int count".into()));
                };
                // IR closures dispatch through the IR registry;
                // tree-walker lambdas use the existing path.
                if let Value::IrClosure { .. } = &lam {
                    for i in 0..n {
                        self.invoke_callable_value(&lam, &[Value::Int(i)], &[None], out)?;
                    }
                    return Ok(Some(Value::Unit));
                }
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("repeat requires a lambda".into()));
                };
                for i in 0..n {
                    self.call_lambda(params, body, captured, &[Value::Int(i)], out)?;
                }
                Ok(Some(Value::Unit))
            }
            "require" => {
                let cond = self.eval_expr(&args[0], env, out)?;
                let Value::Bool(b) = cond else {
                    return Err(RuntimeError::Type("require expects a Bool".into()));
                };
                if !b {
                    let msg = if let Some(a) = args.get(1) {
                        let v = self.eval_expr(a, env, out)?;
                        match v {
                            Value::Lambda { params, body, env: captured, .. } => {
                                let r = self.call_lambda(&params, &body, &captured, &[], out)?;
                                Some(format!("{r}"))
                            }
                            other => Some(format!("{other}")),
                        }
                    } else {
                        Some("Failed requirement.".to_string())
                    };
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IllegalArgumentException".into()),
                        message: msg.map(Rc::new),
                        cause: None,
                    }));
                }
                Ok(Some(Value::Unit))
            }
            "check" => {
                let cond = self.eval_expr(&args[0], env, out)?;
                let Value::Bool(b) = cond else {
                    return Err(RuntimeError::Type("check expects a Bool".into()));
                };
                if !b {
                    let msg = if let Some(a) = args.get(1) {
                        let v = self.eval_expr(a, env, out)?;
                        match v {
                            Value::Lambda { params, body, env: captured, .. } => {
                                let r = self.call_lambda(&params, &body, &captured, &[], out)?;
                                Some(format!("{r}"))
                            }
                            other => Some(format!("{other}")),
                        }
                    } else {
                        Some("Check failed.".to_string())
                    };
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IllegalStateException".into()),
                        message: msg.map(Rc::new),
                        cause: None,
                    }));
                }
                Ok(Some(Value::Unit))
            }
            "error" if args.len() == 1 => {
                let v = self.eval_expr(&args[0], env, out)?;
                let msg = match v {
                    Value::String(s) => (*s).clone(),
                    other => format!("{other}"),
                };
                Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.IllegalStateException".into()),
                    message: Some(Rc::new(msg)),
                    cause: None,
                }))
            }
            "checkNotNull" => {
                let v = self.eval_expr(&args[0], env, out)?;
                if matches!(v, Value::Null) {
                    let msg = if let Some(a) = args.get(1) {
                        let lv = self.eval_expr(a, env, out)?;
                        match lv {
                            Value::Lambda { params, body, env: captured, .. } => {
                                let r = self.call_lambda(&params, &body, &captured, &[], out)?;
                                Some(format!("{r}"))
                            }
                            other => Some(format!("{other}")),
                        }
                    } else {
                        Some("Required value was null.".to_string())
                    };
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IllegalStateException".into()),
                        message: msg.map(Rc::new),
                        cause: None,
                    }));
                }
                Ok(Some(v))
            }
            "requireNotNull" => {
                let v = self.eval_expr(&args[0], env, out)?;
                if matches!(v, Value::Null) {
                    let msg = if let Some(a) = args.get(1) {
                        let lv = self.eval_expr(a, env, out)?;
                        match lv {
                            Value::Lambda { params, body, env: captured, .. } => {
                                let r = self.call_lambda(&params, &body, &captured, &[], out)?;
                                Some(format!("{r}"))
                            }
                            other => Some(format!("{other}")),
                        }
                    } else {
                        Some("Required value was null.".to_string())
                    };
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IllegalArgumentException".into()),
                        message: msg.map(Rc::new),
                        cause: None,
                    }));
                }
                Ok(Some(v))
            }
            "TODO" => {
                let msg = match args.first() {
                    Some(a) => {
                        let v = self.eval_expr(a, env, out)?;
                        match v {
                            Value::String(s) => format!("An operation is not implemented: {s}"),
                            other => format!("An operation is not implemented: {other}"),
                        }
                    }
                    None => "An operation is not implemented.".to_string(),
                };
                Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.NotImplementedError".into()),
                    message: Some(Rc::new(msg)),
                    cause: None,
                }))
            }
            _ => Ok(None),
        }
    }

    fn try_eval_scoping_member(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let kind = match name {
            "let" | "also" | "apply" | "run" | "takeIf" | "takeUnless" => name,
            _ => return Ok(None),
        };
        if args.len() != 1 {
            return Err(RuntimeError::Arity(format!(
                "`.{kind}` expects exactly one lambda argument"
            )));
        }
        let lam = self.eval_expr(&args[0], env, out)?;
        let Value::Lambda { params, body, env: captured, .. } = &lam else {
            return Err(RuntimeError::Type(format!(
                "`.{kind}` requires a lambda argument, got {lam:?}"
            )));
        };
        // Lambdas with implicit `it` get the receiver bound as their sole
        // parameter; lambdas declared with an explicit `->` head obey their
        // own param list. For `apply` / `run` we instead bind `this`.
        let use_this = matches!(kind, "apply" | "run");
        let (lam_args, this_binding): (&[Value], Option<Value>) = if use_this {
            (&[], Some(receiver.clone()))
        } else {
            (std::slice::from_ref(receiver), None)
        };
        let result = self.call_lambda_with_this(params, body, captured, lam_args, this_binding, false, out)?;
        Ok(Some(match kind {
            "let" | "run" => result,
            "also" | "apply" => receiver.clone(),
            "takeIf" => match result {
                Value::Bool(true) => receiver.clone(),
                Value::Bool(false) => Value::Null,
                other => {
                    return Err(RuntimeError::Type(format!(
                        "`takeIf` predicate must return Bool, got {other:?}"
                    )))
                }
            },
            "takeUnless" => match result {
                Value::Bool(false) => receiver.clone(),
                Value::Bool(true) => Value::Null,
                other => {
                    return Err(RuntimeError::Type(format!(
                        "`takeUnless` predicate must return Bool, got {other:?}"
                    )))
                }
            },
            _ => unreachable!(),
        }))
    }

    /// `joinToString(sep?, prefix?, postfix?, limit?, truncated?)` with an
    /// optional trailing-lambda `transform`. Returns `Ok(Some(s))` when this
    /// is a joinToString call we recognize, `Ok(None)` to fall back to the
    /// no-transform intrinsic. Supports the positional-args shape that
    /// covers virtually all real Kotlin usage.
    fn eval_join_to_string(
        &mut self,
        receiver: &Value,
        args: &[Expr],
        arg_names: &[Option<String>],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let items: Vec<Value> = match receiver {
            Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
            _ => return Ok(None),
        };
        let mut evaluated: Vec<Value> = Vec::with_capacity(args.len());
        for a in args {
            evaluated.push(self.eval_expr(a, env, out)?);
        }
        // Pick up the trailing lambda (which is always positional in
        // Kotlin) before reordering, so it doesn't get shuffled.
        let last_is_lambda = matches!(evaluated.last(), Some(Value::Lambda { .. }))
            && arg_names.last().is_none_or(|n| n.is_none());
        let trailing_lambda = if last_is_lambda {
            let v = evaluated.pop();
            v
        } else {
            None
        };
        let names_for_reorder: &[Option<String>] = if last_is_lambda {
            &arg_names[..arg_names.len() - 1]
        } else {
            arg_names
        };
        // Generic reorder via the upstream signature registry — no hard-
        // coded param list lives here anymore.
        let mut vals = reorder_intrinsic_args(
            "kotlin.collections.joinToString",
            evaluated,
            names_for_reorder,
        )?;
        let _ = &mut vals;
        let transform = trailing_lambda;
        // No transform and no other args → defer to the plain intrinsic.
        if transform.is_none() && vals.is_empty() {
            return Ok(None);
        }
        // `Value::Null` here means "named-arg reordering left this slot
        // unset" — use the spec default rather than the literal string
        // "null".
        let opt_str = |v: Option<&Value>, default: &str| -> String {
            match v {
                None | Some(Value::Null) => default.to_string(),
                Some(other) => format_string_like(other),
            }
        };
        let separator = opt_str(vals.first(), ", ");
        let prefix = opt_str(vals.get(1), "");
        let postfix = opt_str(vals.get(2), "");
        let limit: i64 = match vals.get(3) {
            None | Some(Value::Null) => -1,
            Some(v) => v.as_i64().unwrap_or(-1),
        };
        let truncated = opt_str(vals.get(4), "...");
        let mut s = String::new();
        s.push_str(&prefix);
        let mut count = 0i64;
        for v in items {
            if limit >= 0 && count >= limit {
                s.push_str(&separator);
                s.push_str(&truncated);
                break;
            }
            if count > 0 {
                s.push_str(&separator);
            }
            let piece = if let Some(t) = &transform {
                let Value::Lambda { params, body, env: captured, .. } = t else { unreachable!() };
                let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                format_string_like(&r)
            } else {
                format!("{v}")
            };
            s.push_str(&piece);
            count += 1;
        }
        s.push_str(&postfix);
        Ok(Some(Value::String(Rc::new(s))))
    }

    /// `generateSequence(seed) { it -> next }` or `generateSequence { nextOrNull }`.
    /// Indexed assignment for `xs[i] = v` and the compound forms.
    /// Routes through `Value::Array`, mutable `Value::List`, and
    /// `Value::Map`. Other receivers surface as a typed error.
    fn assign_index(
        &mut self,
        receiver: Value,
        idx_vals: &[Value],
        op: AssignOp,
        new_value: Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match receiver {
            Value::Array { items, .. } => {
                if idx_vals.len() != 1 {
                    return Err(RuntimeError::Type(
                        "Array indexing takes one Int argument".into(),
                    ));
                }
                let Some(i) = idx_vals[0].as_i64() else {
                    return Err(RuntimeError::Type(
                        "Array indexing requires an Int".into(),
                    ));
                };
                let mut items_mut = items.borrow_mut();
                let n = items_mut.len() as i64;
                if i < 0 || i >= n {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IndexOutOfBoundsException".to_string()),
                        message: Some(Rc::new(format!(
                            "Index {i} out of bounds for length {n}"
                        ))),
                        cause: None,
                    }));
                }
                let idx = i as usize;
                let final_value = match op {
                    AssignOp::Assign => new_value,
                    other => {
                        let current = items_mut[idx].clone();
                        eval_binop(compound_to_binop(other), current, new_value)?
                    }
                };
                items_mut[idx] = final_value;
                Ok(Value::Unit)
            }
            Value::List { items, mutable, .. } => {
                if !mutable {
                    return Err(RuntimeError::Type(
                        "cannot assign through an index on a read-only List".into(),
                    ));
                }
                if idx_vals.len() != 1 {
                    return Err(RuntimeError::Type(
                        "List indexing takes one Int argument".into(),
                    ));
                }
                let Some(i) = idx_vals[0].as_i64() else {
                    return Err(RuntimeError::Type(
                        "List indexing requires an Int".into(),
                    ));
                };
                let mut items_mut = items.borrow_mut();
                let n = items_mut.len() as i64;
                if i < 0 || i >= n {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IndexOutOfBoundsException".to_string()),
                        message: Some(Rc::new(format!(
                            "Index {i} out of bounds for length {n}"
                        ))),
                        cause: None,
                    }));
                }
                let idx = i as usize;
                let final_value = match op {
                    AssignOp::Assign => new_value,
                    other => {
                        let current = items_mut[idx].clone();
                        eval_binop(compound_to_binop(other), current, new_value)?
                    }
                };
                items_mut[idx] = final_value;
                Ok(Value::Unit)
            }
            Value::Map { entries, mutable } => {
                if !mutable {
                    return Err(RuntimeError::Type(
                        "cannot assign through an index on a read-only Map".into(),
                    ));
                }
                if idx_vals.len() != 1 {
                    return Err(RuntimeError::Type(
                        "Map indexing takes one key argument".into(),
                    ));
                }
                let key = idx_vals[0].clone();
                let final_value = match op {
                    AssignOp::Assign => new_value,
                    other => {
                        let cur = entries
                            .borrow()
                            .iter()
                            .find(|(k, _)| Value::structural_eq(k, &key))
                            .map(|(_, v)| v.clone())
                            .unwrap_or(Value::Null);
                        eval_binop(compound_to_binop(other), cur, new_value)?
                    }
                };
                let mut entries_mut = entries.borrow_mut();
                if let Some(pos) =
                    entries_mut.iter().position(|(k, _)| Value::structural_eq(k, &key))
                {
                    entries_mut[pos].1 = final_value;
                } else {
                    entries_mut.push((key, final_value));
                }
                Ok(Value::Unit)
            }
            Value::Instance(ref inst) => {
                // Dispatch `operator fun set(...)` on the receiver. For
                // compound forms (`a[i] += x`), evaluate the current value
                // via `operator fun get(...)` first and combine.
                let class = Rc::clone(&inst.borrow().class);
                let value_to_write = match op {
                    AssignOp::Assign => new_value,
                    other => {
                        let get_method = class.find_method("get");
                        let Some((m, _)) = get_method else {
                            return Err(RuntimeError::Type(format!(
                                "compound indexed assignment requires `operator fun get`/`set` on `{}`",
                                class.name
                            )));
                        };
                        let arg_names: Vec<Option<String>> = vec![None; idx_vals.len()];
                        let cur = self.call_method(inst, &m, idx_vals, &arg_names, out)?;
                        eval_binop(compound_to_binop(other), cur, new_value)?
                    }
                };
                let set_method = class.find_method("set");
                let Some((m, _)) = set_method else {
                    return Err(RuntimeError::Type(format!(
                        "cannot assign through an index on `{}` — declare `operator fun set(...)`",
                        class.name
                    )));
                };
                let mut all_args: Vec<Value> = Vec::with_capacity(idx_vals.len() + 1);
                all_args.extend_from_slice(idx_vals);
                all_args.push(value_to_write);
                let arg_names: Vec<Option<String>> = vec![None; all_args.len()];
                self.call_method(inst, &m, &all_args, &arg_names, out)?;
                Ok(Value::Unit)
            }
            other => Err(RuntimeError::Type(format!(
                "cannot assign through an index on `{other}`"
            ))),
        }
    }

    /// Recognizes `arrayOf` / `arrayOfNulls` / `Array(n) { init }` and
    /// every typed primitive-array constructor by simple name. Returns
    /// `Ok(None)` when the name isn't a constructor so the caller can
    /// keep dispatching.
    fn try_eval_array_constructor(
        &mut self,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        use klio_runtime::PrimitiveArrayKind;
        let prim_kind = match name {
            "IntArray" => Some(PrimitiveArrayKind::Int),
            "LongArray" => Some(PrimitiveArrayKind::Long),
            "DoubleArray" => Some(PrimitiveArrayKind::Double),
            "FloatArray" => Some(PrimitiveArrayKind::Float),
            "ShortArray" => Some(PrimitiveArrayKind::Short),
            "ByteArray" => Some(PrimitiveArrayKind::Byte),
            "BooleanArray" => Some(PrimitiveArrayKind::Boolean),
            "CharArray" => Some(PrimitiveArrayKind::Char),
            _ => None,
        };
        // Lowercase variadic factories: `intArrayOf(1, 2, 3)`,
        // `doubleArrayOf(1.0, 2.0)`, etc. Element type is tagged so
        // member dispatch / `is`-checks recognize the primitive variant.
        let variadic_prim_kind = match name {
            "intArrayOf" => Some(PrimitiveArrayKind::Int),
            "longArrayOf" => Some(PrimitiveArrayKind::Long),
            "doubleArrayOf" => Some(PrimitiveArrayKind::Double),
            "floatArrayOf" => Some(PrimitiveArrayKind::Float),
            "shortArrayOf" => Some(PrimitiveArrayKind::Short),
            "byteArrayOf" => Some(PrimitiveArrayKind::Byte),
            "booleanArrayOf" => Some(PrimitiveArrayKind::Boolean),
            "charArrayOf" => Some(PrimitiveArrayKind::Char),
            "uintArrayOf" => Some(PrimitiveArrayKind::UInt),
            "ulongArrayOf" => Some(PrimitiveArrayKind::ULong),
            "ushortArrayOf" => Some(PrimitiveArrayKind::UShort),
            "ubyteArrayOf" => Some(PrimitiveArrayKind::UByte),
            _ => None,
        };
        if let Some(k) = variadic_prim_kind {
            let mut items = Vec::with_capacity(args.len());
            for a in args {
                items.push(self.eval_expr(a, env, out)?);
            }
            return Ok(Some(Value::Array {
                items: Rc::new(RefCell::new(items)),
                prim: Some(k),
            }));
        }
        let default_prim_value = |k: PrimitiveArrayKind| match k {
            PrimitiveArrayKind::Int
            | PrimitiveArrayKind::Long
            | PrimitiveArrayKind::Short
            | PrimitiveArrayKind::Byte => Value::Int(0),
            PrimitiveArrayKind::UInt => Value::UInt(0),
            PrimitiveArrayKind::ULong => Value::ULong(0),
            PrimitiveArrayKind::UShort => Value::UShort(0),
            PrimitiveArrayKind::UByte => Value::UByte(0),
            PrimitiveArrayKind::Double | PrimitiveArrayKind::Float => Value::Double(0.0),
            PrimitiveArrayKind::Boolean => Value::Bool(false),
            PrimitiveArrayKind::Char => Value::Char('\u{0}'),
        };
        // Generic `arrayOf(args...)`: variadic, no lambda. Element type is
        // erased at runtime so we accept any mix.
        if name == "arrayOf" {
            let mut items = Vec::with_capacity(args.len());
            for a in args {
                items.push(self.eval_expr(a, env, out)?);
            }
            return Ok(Some(Value::Array {
                items: Rc::new(RefCell::new(items)),
                prim: None,
            }));
        }
        // `arrayOfNulls<T>(n)` — n nulls in a generic array.
        if name == "arrayOfNulls" && args.len() == 1 {
            let n = self.eval_expr(&args[0], env, out)?;
            let Value::Int(n) = n else {
                return Err(RuntimeError::Type(
                    "arrayOfNulls expects an Int size".into(),
                ));
            };
            if n < 0 {
                return Err(RuntimeError::Type(format!(
                    "arrayOfNulls: negative array size {n}"
                )));
            }
            let items: Vec<Value> = (0..n).map(|_| Value::Null).collect();
            return Ok(Some(Value::Array {
                items: Rc::new(RefCell::new(items)),
                prim: None,
            }));
        }
        // `Array(n) { init }` — generic array, lambda-initialized.
        if name == "Array" && args.len() == 2 {
            let n = self.eval_expr(&args[0], env, out)?;
            let Value::Int(n) = n else {
                return Err(RuntimeError::Type("Array expects an Int size".into()));
            };
            if n < 0 {
                return Err(RuntimeError::Type(format!(
                    "Array: negative array size {n}"
                )));
            }
            let lam = self.eval_expr(&args[1], env, out)?;
            let mut items = Vec::with_capacity(n as usize);
            for i in 0..n {
                let v = self.invoke_lambda(&lam, &[Value::Int(i)], out)?;
                items.push(v);
            }
            return Ok(Some(Value::Array {
                items: Rc::new(RefCell::new(items)),
                prim: None,
            }));
        }
        // Typed primitive-array constructors: `IntArray(n)` zeroes; the
        // two-arg form initializes via a lambda.
        if let Some(k) = prim_kind {
            if args.len() == 1 {
                let n = self.eval_expr(&args[0], env, out)?;
                let Value::Int(n) = n else {
                    return Err(RuntimeError::Type(format!(
                        "{name} expects an Int size"
                    )));
                };
                if n < 0 {
                    return Err(RuntimeError::Type(format!(
                        "{name}: negative array size {n}"
                    )));
                }
                let items: Vec<Value> = (0..n).map(|_| default_prim_value(k)).collect();
                return Ok(Some(Value::Array {
                    items: Rc::new(RefCell::new(items)),
                    prim: Some(k),
                }));
            }
            if args.len() == 2 {
                let n = self.eval_expr(&args[0], env, out)?;
                let Value::Int(n) = n else {
                    return Err(RuntimeError::Type(format!(
                        "{name} expects an Int size"
                    )));
                };
                if n < 0 {
                    return Err(RuntimeError::Type(format!(
                        "{name}: negative array size {n}"
                    )));
                }
                let lam = self.eval_expr(&args[1], env, out)?;
                let mut items = Vec::with_capacity(n as usize);
                for i in 0..n {
                    let v = self.invoke_lambda(&lam, &[Value::Int(i)], out)?;
                    items.push(v);
                }
                return Ok(Some(Value::Array {
                    items: Rc::new(RefCell::new(items)),
                    prim: Some(k),
                }));
            }
        }
        Ok(None)
    }

    fn eval_generate_sequence(
        &mut self,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        use klio_runtime::{SequenceData, SequenceSource};
        let vals: Vec<Value> = args
            .iter()
            .map(|a| self.eval_expr(a, env, out))
            .collect::<Result<_, _>>()?;
        match vals.as_slice() {
            [Value::Lambda { .. }] => {
                let lam = vals.into_iter().next().unwrap();
                Ok(Value::Sequence(Rc::new(SequenceData {
                    source: SequenceSource::Generate {
                        seed: None,
                        next: Box::new(lam),
                    },
                    ops: Vec::new(),
                })))
            }
            [_, Value::Lambda { .. }] => {
                let mut it = vals.into_iter();
                let seed = it.next().unwrap();
                let lam = it.next().unwrap();
                let seeded = if matches!(seed, Value::Null) {
                    None
                } else {
                    Some(Box::new(seed))
                };
                Ok(Value::Sequence(Rc::new(SequenceData {
                    source: SequenceSource::Generate {
                        seed: seeded,
                        next: Box::new(lam),
                    },
                    ops: Vec::new(),
                })))
            }
            _ => Err(RuntimeError::Type(
                "generateSequence expects `(seed, next)` or `(next)` with `next` a lambda".into(),
            )),
        }
    }

    /// Dispatch a member call on a `Value::Sequence` receiver. Intermediate
    /// ops append to a cloned op chain; terminal ops drive the lazy
    /// materializer.
    fn try_eval_sequence_member(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        use klio_runtime::{SeqOp, SequenceData};
        let Value::Sequence(data) = receiver else { return Ok(None) };
        // Intermediate ops: clone the op chain, append, return new Sequence.
        let push_op = |op: SeqOp| -> Value {
            let mut ops = data.ops.clone();
            ops.push(op);
            Value::Sequence(Rc::new(SequenceData {
                source: data.source.clone(),
                ops,
            }))
        };
        match name {
            "map" | "filter" | "filterNot" | "takeWhile" | "dropWhile" | "flatMap"
            | "distinctBy" => {
                let lam = match args.first() {
                    Some(e) => self.eval_expr(e, env, out)?,
                    None => {
                        return Err(RuntimeError::Arity(format!(
                            "Sequence.{name} requires a lambda"
                        )))
                    }
                };
                if !matches!(lam, Value::Lambda { .. }) {
                    return Err(RuntimeError::Type(format!(
                        "Sequence.{name} requires a lambda argument"
                    )));
                }
                let op = match name {
                    "map" => SeqOp::Map(lam),
                    "filter" => SeqOp::Filter(lam),
                    "filterNot" => SeqOp::FilterNot(lam),
                    "takeWhile" => SeqOp::TakeWhile(lam),
                    "dropWhile" => SeqOp::DropWhile(lam),
                    "flatMap" => SeqOp::FlatMap(lam),
                    "distinctBy" => SeqOp::DistinctBy(lam),
                    _ => unreachable!(),
                };
                return Ok(Some(push_op(op)));
            }
            "take" | "drop" => {
                let n = match args.first() {
                    Some(e) => self.eval_expr(e, env, out)?,
                    _ => return Err(RuntimeError::Arity(format!("Sequence.{name} requires an Int"))),
                };
                let Some(n) = n.as_i64() else {
                    return Err(RuntimeError::Type(format!(
                        "Sequence.{name} requires an Int argument"
                    )));
                };
                let op = if name == "take" { SeqOp::Take(n) } else { SeqOp::Drop(n) };
                return Ok(Some(push_op(op)));
            }
            "distinct" => return Ok(Some(push_op(SeqOp::Distinct))),
            "sorted" => return Ok(Some(push_op(SeqOp::Sorted(false)))),
            "sortedDescending" => return Ok(Some(push_op(SeqOp::Sorted(true)))),
            "sortedBy" | "sortedByDescending" => {
                let lam = match args.first() {
                    Some(e) => self.eval_expr(e, env, out)?,
                    _ => {
                        return Err(RuntimeError::Arity(format!(
                            "Sequence.{name} requires a selector lambda"
                        )))
                    }
                };
                if !matches!(lam, Value::Lambda { .. }) {
                    return Err(RuntimeError::Type(format!(
                        "Sequence.{name} requires a lambda argument"
                    )));
                }
                return Ok(Some(push_op(SeqOp::SortedBy(lam, name == "sortedByDescending"))));
            }
            "sortedWith" => {
                let cmp = match args.first() {
                    Some(e) => self.eval_expr(e, env, out)?,
                    _ => {
                        return Err(RuntimeError::Arity(
                            "Sequence.sortedWith requires a Comparator".into(),
                        ))
                    }
                };
                if !matches!(cmp, Value::Comparator { .. }) {
                    return Err(RuntimeError::Type(
                        "Sequence.sortedWith requires a Comparator".into(),
                    ));
                }
                return Ok(Some(push_op(SeqOp::SortedWith(cmp))));
            }
            _ => {}
        }
        // Terminal ops: materialize and operate on the resulting Vec.
        let terminal = matches!(
            name,
            "toList"
                | "toMutableList"
                | "toSet"
                | "toMap"
                | "count"
                | "first"
                | "last"
                | "sumOf"
                | "fold"
                | "reduce"
                | "forEach"
                | "any"
                | "all"
                | "none"
                | "find"
                | "joinToString"
                | "maxOf"
                | "minOf"
                | "max"
                | "min"
                | "maxOrNull"
                | "minOrNull"
                | "sum"
                | "average"
                | "indices"
                | "lastIndex"
                | "groupBy"
                | "associate"
                | "associateBy"
                | "associateWith"
                | "partition"
        );
        if !terminal {
            return Ok(None);
        }
        let items = self.materialize_sequence(data, out)?;
        // Wrap as a List and reuse the existing collection dispatcher,
        // which already handles every terminal we care about.
        let as_list = Value::List { items: Rc::new(RefCell::new(items)), mutable: false, enum_class: None };
        if name == "toList" {
            return Ok(Some(as_list));
        }
        if name == "toMutableList" {
            let Value::List { items, .. } = as_list else { unreachable!() };
            return Ok(Some(Value::List { items, mutable: true, enum_class: None }));
        }
        if name == "toSet" {
            let Value::List { items, .. } = as_list else { unreachable!() };
            let mut deduped: Vec<Value> = Vec::new();
            for v in items.borrow().iter() {
                if !deduped.iter().any(|x| Value::structural_eq(x, v)) {
                    deduped.push(v.clone());
                }
            }
            return Ok(Some(Value::Set {
                items: Rc::new(RefCell::new(deduped)),
                mutable: false,
            }));
        }
        // For count/first/last/joinToString/any/all/.../etc., delegate to
        // the List version of the same op. These code paths all live in
        // the existing intrinsic / HOF dispatchers.
        if name == "joinToString" {
            // Named-arg reordering for Sequence.joinToString isn't wired —
            // most uses are positional; if a user reorders names against
            // a Sequence receiver they can `.toList()` first.
            return self.eval_join_to_string(&as_list, args, &[], env, out);
        }
        // Predicate-free terminal ops on the materialized list.
        let Value::List { items, .. } = &as_list else { unreachable!() };
        let borrow = items.borrow();
        if args.is_empty() {
            match name {
                "count" => return Ok(Some(Value::new_int(borrow.len()))),
                "first" => {
                    return borrow.first().cloned().ok_or_else(|| {
                        RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.NoSuchElementException".into()),
                            message: Some(Rc::new("Sequence is empty.".into())),
                            cause: None,
                        })
                    }).map(Some)
                }
                "last" => {
                    return borrow.last().cloned().ok_or_else(|| {
                        RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.NoSuchElementException".into()),
                            message: Some(Rc::new("Sequence is empty.".into())),
                            cause: None,
                        })
                    }).map(Some)
                }
                _ => {}
            }
        }
        drop(borrow);
        if let Some(v) = self.try_eval_collection_higher_order(&as_list, name, args, env, out)? {
            return Ok(Some(v));
        }
        // Predicate-free intrinsics like `kotlin.collections.List.sum` /
        // `max` / `toMap` / `indices` route through the regular intrinsic
        // table now that the receiver is a List.
        let fqn = format!("kotlin.collections.List.{name}");
        if let Some(func) = self.lookup_intrinsic(&fqn) {
            let mut arg_vals = vec![as_list.clone()];
            for a in args {
                arg_vals.push(self.eval_expr(a, env, out)?);
            }
            let mut ctx = CallCtx { args: &arg_vals, out };
            return Ok(Some(func(&mut ctx)?));
        }
        Ok(None)
    }

    /// §7.2.3 user-defined iterator dispatch. Given a receiver that fell out
    /// of every built-in `for`-loop iterable arm, look up an `iterator()`
    /// member or extension function, then drive the returned iterator via
    /// `hasNext()` / `next()` until exhaustion. Items are eagerly collected
    /// into a `Vec` so the outer loop can iterate them without borrowing
    /// `self`. A receiver with no `iterator()` produces the same type error
    /// the previous catch-all emitted.
    fn materialize_user_iterable(
        &mut self,
        recv: &Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Vec<Value>, RuntimeError> {
        let iter = self.call_zero_arg_member(recv, "iterator", env, out)?
            .ok_or_else(|| RuntimeError::Type(format!(
                "`for` requires a Range or collection or a value with an `iterator()` method, got {recv:?}"
            )))?;
        let mut items = Vec::new();
        loop {
            let has = self.call_zero_arg_member(&iter, "hasNext", env, out)?
                .ok_or_else(|| RuntimeError::Type(
                    "iterator returned by `iterator()` has no `hasNext()` method".into(),
                ))?;
            let Value::Bool(b) = has else {
                return Err(RuntimeError::Type(
                    "`Iterator.hasNext()` must return Boolean".into(),
                ));
            };
            if !b {
                break;
            }
            let next = self.call_zero_arg_member(&iter, "next", env, out)?
                .ok_or_else(|| RuntimeError::Type(
                    "iterator returned by `iterator()` has no `next()` method".into(),
                ))?;
            items.push(next);
            // Guard against runaway iterators in pathological user code.
            if items.len() > 100_000_000 {
                return Err(RuntimeError::Type(
                    "`for` iterator exceeded 100,000,000 items".into(),
                ));
            }
        }
        Ok(items)
    }

    /// Helper for the user-iterator path: invoke a zero-argument member on
    /// `recv` via the class's method table first, falling back to a matching
    /// extension function in scope. Returns `Ok(None)` when no candidate is
    /// found so the caller can produce a tailored diagnostic.
    fn call_zero_arg_member(
        &mut self,
        recv: &Value,
        name: &str,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        if let Value::Instance(inst) = recv {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(name) {
                let v = self.call_method(inst, &m, &[], &[], out)?;
                return Ok(Some(v));
            }
        }
        if let Some(v) = self.try_extension_call(recv, name, &[], &[], env, out)? {
            return Ok(Some(v));
        }
        Ok(None)
    }

    /// §7.1.2 operator-assignment dispatch. Reads the LHS once, then tries
    /// to invoke the matching `*Assign` operator on it. Returns `Some(())`
    /// when an in-place mutation handled the assignment, `None` to let the
    /// caller fall through to the read/arith/write expansion. The LHS is
    /// evaluated as an expression (e.g. through any custom getter), so
    /// receivers with side-effects observe the same single read kotlinc
    /// would emit when expanding to `lhs.plusAssign(rhs)`.
    fn try_compound_assign_dispatch(
        &mut self,
        target: &Expr,
        op: AssignOp,
        rhs: &Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<()>, RuntimeError> {
        let method = match op {
            AssignOp::Add => "plusAssign",
            AssignOp::Sub => "minusAssign",
            AssignOp::Mul => "timesAssign",
            AssignOp::Div => "divAssign",
            AssignOp::Rem => "remAssign",
            AssignOp::Assign => return Ok(None),
        };
        let cur = self.eval_expr(target, env, out)?;
        // User-class member dispatch.
        if let Value::Instance(inst) = &cur {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(method) {
                self.call_method(&inst.clone(), &m, &[rhs.clone()], &[None], out)?;
                return Ok(Some(()));
            }
        }
        // Built-in mutable collections (spec stdlib operator extensions).
        match (&cur, method) {
            (Value::List { items, mutable: true, .. }, "plusAssign") => {
                items.borrow_mut().push(rhs.clone());
                return Ok(Some(()));
            }
            (Value::List { items, mutable: true, .. }, "minusAssign") => {
                let mut v = items.borrow_mut();
                if let Some(pos) = v.iter().position(|x| Value::structural_eq(x, rhs)) {
                    v.remove(pos);
                }
                return Ok(Some(()));
            }
            (Value::Set { items, mutable: true, .. }, "plusAssign") => {
                let mut v = items.borrow_mut();
                if !v.iter().any(|x| Value::structural_eq(x, rhs)) {
                    v.push(rhs.clone());
                }
                return Ok(Some(()));
            }
            (Value::Set { items, mutable: true, .. }, "minusAssign") => {
                let mut v = items.borrow_mut();
                if let Some(pos) = v.iter().position(|x| Value::structural_eq(x, rhs)) {
                    v.remove(pos);
                }
                return Ok(Some(()));
            }
            (Value::Map { entries, mutable: true, .. }, "plusAssign") => {
                // Spec: `map += pair` puts the key/value into the map.
                if let Value::Pair(k, v) = rhs {
                    let mut es = entries.borrow_mut();
                    if let Some(pos) = es.iter().position(|(ek, _)| Value::structural_eq(ek, k)) {
                        es[pos].1 = (**v).clone();
                    } else {
                        es.push(((**k).clone(), (**v).clone()));
                    }
                    return Ok(Some(()));
                }
            }
            (Value::Map { entries, mutable: true, .. }, "minusAssign") => {
                let mut es = entries.borrow_mut();
                if let Some(pos) = es.iter().position(|(ek, _)| Value::structural_eq(ek, rhs)) {
                    es.remove(pos);
                }
                return Ok(Some(()));
            }
            _ => {}
        }
        // Extension dispatch. Pass the RHS as a synthetic argument by
        // wrapping it as an Expr::Path lookup of a temporary; the simpler
        // route is to extend try_extension_call to accept value args, but
        // for now we synthesize a fresh binding in a child scope.
        let scope = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
        let tmp = "$$compound_assign_rhs".to_string();
        scope.borrow_mut().define(tmp.clone(), rhs.clone());
        let arg_expr = Expr::Path {
            segments: vec![klio_ast::Ident { name: tmp.clone(), span: target.span() }],
            span: target.span(),
        };
        if let Some(_v) = self.try_extension_call(&cur, method, &[arg_expr], &[None], &scope, out)? {
            return Ok(Some(()));
        }
        Ok(None)
    }

    /// Drive the lazy pull. Sort ops break the stream into stages: when one
    /// is present we materialize the pre-sort portion, sort the buffer,
    /// then recurse with the remaining ops over an `Items` source.
    fn materialize_sequence(
        &mut self,
        data: &klio_runtime::SequenceData,
        out: &mut dyn Output,
    ) -> Result<Vec<Value>, RuntimeError> {
        use klio_runtime::{SeqOp, SequenceData, SequenceSource};
        // Split at the first sort op.
        if let Some(first_sort) = data.ops.iter().position(is_sort_op) {
            let pre = SequenceData {
                source: data.source.clone(),
                ops: data.ops[..first_sort].to_vec(),
            };
            let mut buffered = self.materialize_streaming(&pre, out)?;
            self.apply_sort_op(&data.ops[first_sort], &mut buffered, out)?;
            // Re-issue the remainder as a fresh Items-sourced Sequence.
            let rest = SequenceData {
                source: SequenceSource::Items(Rc::new(buffered)),
                ops: data.ops[first_sort + 1..].to_vec(),
            };
            return self.materialize_sequence(&rest, out);
        }
        let _ = SeqOp::Map(Value::Unit); // keep unused import quiet on some paths
        self.materialize_streaming(data, out)
    }

    fn materialize_streaming(
        &mut self,
        data: &klio_runtime::SequenceData,
        out: &mut dyn Output,
    ) -> Result<Vec<Value>, RuntimeError> {
        let mut emitted: Vec<Value> = Vec::new();
        let mut op_state: Vec<OpState> = data
            .ops
            .iter()
            .map(|op| OpState::for_op(op))
            .collect();
        let mut source_state = SourceState::new(&data.source);
        let mut stop = false;
        let safety_limit: u64 = 10_000_000;
        let mut iters: u64 = 0;
        while !stop {
            iters += 1;
            if iters > safety_limit {
                return Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.RuntimeException".into()),
                    message: Some(Rc::new(format!(
                        "Sequence materialization exceeded {safety_limit} iterations; use a Take to bound it."
                    ))),
                    cause: None,
                }));
            }
            let item = match self.pull_sequence_source(&data.source, &mut source_state, out)? {
                Some(v) => v,
                None => break,
            };
            self.feed_seq_ops(&data.ops, &mut op_state, 0, item, &mut emitted, &mut stop, out)?;
        }
        Ok(emitted)
    }

    fn apply_sort_op(
        &mut self,
        op: &klio_runtime::SeqOp,
        items: &mut Vec<Value>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        use klio_runtime::SeqOp;
        match op {
            SeqOp::Sorted(descending) => {
                let desc = *descending;
                self.insertion_sort_values(items, desc, out)?;
                Ok(())
            }
            SeqOp::SortedBy(sel, descending) => {
                let desc = *descending;
                let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
                for v in items.drain(..) {
                    let key = self.invoke_seq_lambda(sel, std::slice::from_ref(&v), out)?;
                    keyed.push((key, v));
                }
                self.insertion_sort_keyed(&mut keyed, desc, out)?;
                *items = keyed.into_iter().map(|(_, v)| v).collect();
                Ok(())
            }
            SeqOp::SortedWith(cmp) => {
                let Value::Comparator { steps, descending } = cmp else {
                    return Err(RuntimeError::Type(
                        "Sequence.sortedWith requires a Comparator".into(),
                    ));
                };
                if steps.is_empty() {
                    self.insertion_sort_values(items, *descending, out)?;
                    return Ok(());
                }
                // Precompute selector keys per item.
                let outer_desc = *descending;
                let mut keyed: Vec<(Vec<Value>, Value)> = Vec::with_capacity(items.len());
                for v in items.drain(..) {
                    let mut keys = Vec::with_capacity(steps.len());
                    for (sel, _) in steps.iter() {
                        let k = self.invoke_seq_lambda(sel, std::slice::from_ref(&v), out)?;
                        keys.push(k);
                    }
                    keyed.push((keys, v));
                }
                let mut err: Option<RuntimeError> = None;
                keyed.sort_by(|a, b| {
                    if err.is_some() { return std::cmp::Ordering::Equal; }
                    for ((k1, k2), (_, step_desc)) in a.0.iter().zip(b.0.iter()).zip(steps.iter()) {
                        match self.compare_with_user(k1, k2, out) {
                            Ok(std::cmp::Ordering::Equal) => continue,
                            Ok(mut o) => {
                                if *step_desc { o = o.reverse(); }
                                if outer_desc { o = o.reverse(); }
                                return o;
                            }
                            Err(e) => { err = Some(e); return std::cmp::Ordering::Equal; }
                        }
                    }
                    std::cmp::Ordering::Equal
                });
                if let Some(e) = err { return Err(e); }
                *items = keyed.into_iter().map(|(_, v)| v).collect();
                Ok(())
            }
            _ => unreachable!("not a sort op"),
        }
    }

    fn pull_sequence_source(
        &mut self,
        source: &klio_runtime::SequenceSource,
        state: &mut SourceState,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        use klio_runtime::SequenceSource;
        match (source, state) {
            (SequenceSource::Items(items), SourceState::Items { index }) => {
                let i = *index;
                if i >= items.len() {
                    return Ok(None);
                }
                *index += 1;
                Ok(Some(items[i].clone()))
            }
            (
                SequenceSource::Generate { seed, next },
                SourceState::Generate { last, started },
            ) => {
                if !*started {
                    *started = true;
                    if let Some(s) = seed {
                        *last = Some((**s).clone());
                        return Ok(Some((**s).clone()));
                    }
                    // Nullary lambda: first call.
                    let Value::Lambda { params, body, env: captured, .. } = &**next else {
                        return Err(RuntimeError::Type(
                            "generateSequence requires a lambda".into(),
                        ));
                    };
                    let v = self.call_lambda(params, body, captured, &[], out)?;
                    if matches!(v, Value::Null) {
                        return Ok(None);
                    }
                    *last = Some(v.clone());
                    return Ok(Some(v));
                }
                // Already started.
                let Value::Lambda { params, body, env: captured, .. } = &**next else {
                    return Err(RuntimeError::Type(
                        "generateSequence requires a lambda".into(),
                    ));
                };
                let v = if let Some(prev) = last.as_ref().cloned() {
                    self.call_lambda(params, body, captured, std::slice::from_ref(&prev), out)?
                } else {
                    self.call_lambda(params, body, captured, &[], out)?
                };
                if matches!(v, Value::Null) {
                    return Ok(None);
                }
                *last = Some(v.clone());
                Ok(Some(v))
            }
            _ => unreachable!("source/state mismatch"),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn feed_seq_ops(
        &mut self,
        ops: &[klio_runtime::SeqOp],
        state: &mut [OpState],
        idx: usize,
        item: Value,
        emitted: &mut Vec<Value>,
        stop: &mut bool,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        if *stop {
            return Ok(());
        }
        if idx == ops.len() {
            emitted.push(item);
            return Ok(());
        }
        use klio_runtime::SeqOp;
        match &ops[idx] {
            SeqOp::Map(lam) => {
                let v = self.invoke_seq_lambda(lam, &[item], out)?;
                self.feed_seq_ops(ops, state, idx + 1, v, emitted, stop, out)
            }
            SeqOp::Filter(lam) => {
                let r = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                if matches!(r, Value::Bool(true)) {
                    self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
                } else {
                    Ok(())
                }
            }
            SeqOp::FilterNot(lam) => {
                let r = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                if matches!(r, Value::Bool(false)) {
                    self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
                } else {
                    Ok(())
                }
            }
            SeqOp::Take(_) => {
                let OpState::Counter(remaining) = &mut state[idx] else { unreachable!() };
                if *remaining <= 0 {
                    *stop = true;
                    return Ok(());
                }
                *remaining -= 1;
                self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
            }
            SeqOp::Drop(_) => {
                let OpState::Counter(remaining) = &mut state[idx] else { unreachable!() };
                if *remaining > 0 {
                    *remaining -= 1;
                    return Ok(());
                }
                self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
            }
            SeqOp::TakeWhile(lam) => {
                let OpState::Flag(done) = &mut state[idx] else { unreachable!() };
                if *done {
                    *stop = true;
                    return Ok(());
                }
                let r = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                if matches!(r, Value::Bool(true)) {
                    self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
                } else {
                    *done = true;
                    *stop = true;
                    Ok(())
                }
            }
            SeqOp::DropWhile(lam) => {
                let OpState::Flag(dropping) = &mut state[idx] else { unreachable!() };
                if *dropping {
                    let r = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                    if matches!(r, Value::Bool(true)) {
                        return Ok(());
                    }
                    *dropping = false;
                }
                self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
            }
            SeqOp::Distinct => {
                let OpState::Seen(seen) = &mut state[idx] else { unreachable!() };
                if seen.iter().any(|x| Value::structural_eq(x, &item)) {
                    return Ok(());
                }
                seen.push(item.clone());
                self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
            }
            SeqOp::DistinctBy(lam) => {
                let key = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                let OpState::Seen(seen) = &mut state[idx] else { unreachable!() };
                if seen.iter().any(|x| Value::structural_eq(x, &key)) {
                    return Ok(());
                }
                seen.push(key);
                self.feed_seq_ops(ops, state, idx + 1, item, emitted, stop, out)
            }
            SeqOp::Sorted(_) | SeqOp::SortedBy(_, _) | SeqOp::SortedWith(_) => {
                // Sort ops are pulled out by `materialize_sequence` before
                // we get here, so this branch is unreachable in practice.
                unreachable!("sort ops handled by materialize_sequence");
            }
            SeqOp::FlatMap(lam) => {
                let r = self.invoke_seq_lambda(lam, std::slice::from_ref(&item), out)?;
                let inner: Vec<Value> = match r {
                    Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
                    Value::Range { start, end, step, kind } => {
                        let mut v = Vec::new();
                        let mut cur = start;
                        let mk = |c: i64| match kind {
                            klio_runtime::RangeKind::Long => Value::Long(c),
                            klio_runtime::RangeKind::Int => Value::new_int(c as i32),
                            klio_runtime::RangeKind::Char => char::from_u32(c as u32)
                                .map(Value::Char)
                                .unwrap_or(Value::Null),
                        };
                        if step > 0 {
                            while cur <= end {
                                v.push(mk(cur));
                                cur = cur.saturating_add(step);
                            }
                        } else {
                            while cur >= end {
                                v.push(mk(cur));
                                cur = cur.saturating_add(step);
                            }
                        }
                        v
                    }
                    other => {
                        return Err(RuntimeError::Type(format!(
                            "Sequence.flatMap selector must return a List/Set/Range, got {other:?}"
                        )))
                    }
                };
                for v in inner {
                    if *stop {
                        break;
                    }
                    self.feed_seq_ops(ops, state, idx + 1, v, emitted, stop, out)?;
                }
                Ok(())
            }
        }
    }

    fn invoke_seq_lambda(
        &mut self,
        lam: &Value,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Value::Lambda { params, body, env: captured, .. } = lam else {
            return Err(RuntimeError::Type("expected a lambda".into()));
        };
        self.call_lambda(params, body, captured, args, out)
    }

    fn eval_sorted_with(
        &mut self,
        receiver: Value,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let cmp_val = args
            .first()
            .ok_or_else(|| RuntimeError::Arity("sortedWith requires a Comparator".into()))
            .and_then(|a| self.eval_expr(a, env, out))?;
        let Value::Comparator { steps, descending } = cmp_val else {
            return Err(RuntimeError::Type(
                "sortedWith expects a Comparator argument".into(),
            ));
        };
        let mut items: Vec<Value> = match &receiver {
            Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
            _ => unreachable!(),
        };
        // Empty step chain: Comparator.naturalOrder() / reverseOrder() — sort
        // items directly using the value-level comparison.
        if steps.is_empty() {
            self.insertion_sort_values(&mut items, descending, out)?;
            return Ok(Value::List { items: Rc::new(RefCell::new(items)), mutable: false, enum_class: None });
        }
        // Insertion sort lets us call back into the interpreter (`&mut self`)
        // from within comparisons, which is required when a step's keys are
        // user `Value::Instance`s that override `compareTo`.
        for i in 1..items.len() {
            let mut j = i;
            while j > 0 {
                let ord = self.compare_with_comparator(&steps, descending, &items[j - 1], &items[j], out)?;
                if matches!(ord, std::cmp::Ordering::Greater) {
                    items.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
        Ok(Value::List { items: Rc::new(RefCell::new(items)), mutable: false, enum_class: None })
    }

    /// Comparator-shaped methods on a `Value::Comparator` receiver:
    /// `thenBy { … }`, `thenByDescending { … }`, `reversed()`.
    fn try_eval_comparator_member(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let Value::Comparator { steps, descending } = receiver else {
            return Ok(None);
        };
        match name {
            "thenBy" | "thenByDescending" => {
                if args.len() != 1 {
                    return Err(RuntimeError::Arity(format!(
                        "Comparator.{name} expects one selector lambda"
                    )));
                }
                let sel = self.eval_expr(&args[0], env, out)?;
                if !matches!(sel, Value::Lambda { .. }) {
                    return Err(RuntimeError::Type(format!(
                        "Comparator.{name} expects a key-selector lambda"
                    )));
                }
                let mut chain: Vec<(Value, bool)> = (**steps).clone();
                chain.push((sel, name == "thenByDescending"));
                Ok(Some(Value::Comparator {
                    steps: Rc::new(chain),
                    descending: *descending,
                }))
            }
            "reversed" => Ok(Some(Value::Comparator {
                steps: Rc::clone(steps),
                descending: !*descending,
            })),
            "compare" => {
                if args.len() != 2 {
                    return Err(RuntimeError::Arity(
                        "Comparator.compare expects two arguments".into(),
                    ));
                }
                let a = self.eval_expr(&args[0], env, out)?;
                let b = self.eval_expr(&args[1], env, out)?;
                let ord = self.compare_with_comparator(steps, *descending, &a, &b, out)?;
                let n: i32 = match ord {
                    std::cmp::Ordering::Less => -1,
                    std::cmp::Ordering::Equal => 0,
                    std::cmp::Ordering::Greater => 1,
                };
                Ok(Some(Value::Int(n)))
            }
            "thenComparing" | "then" | "thenDescending" | "thenComparator" => {
                if args.len() != 1 {
                    return Err(RuntimeError::Arity(format!(
                        "Comparator.{name} expects one argument"
                    )));
                }
                let invert = name == "thenDescending";
                let other = self.eval_expr(&args[0], env, out)?;
                match other {
                    Value::Comparator { steps: other_steps, descending: other_desc } => {
                        let mut chain: Vec<(Value, bool)> = (**steps).clone();
                        for (sel, d) in other_steps.iter() {
                            chain.push((sel.clone(), *d ^ other_desc ^ invert));
                        }
                        Ok(Some(Value::Comparator {
                            steps: Rc::new(chain),
                            descending: *descending,
                        }))
                    }
                    Value::Lambda { .. } => {
                        let mut chain: Vec<(Value, bool)> = (**steps).clone();
                        chain.push((other, invert));
                        Ok(Some(Value::Comparator {
                            steps: Rc::new(chain),
                            descending: *descending,
                        }))
                    }
                    _ => Err(RuntimeError::Type(format!(
                        "Comparator.{name} expects a Comparator or selector lambda"
                    ))),
                }
            }
            _ => Ok(None),
        }
    }

    fn compare_with_comparator(
        &mut self,
        steps: &Rc<Vec<(Value, bool)>>,
        descending: bool,
        a: &Value,
        b: &Value,
        out: &mut dyn Output,
    ) -> Result<std::cmp::Ordering, RuntimeError> {
        if steps.is_empty() {
            let mut ord = self.compare_with_user(a, b, out)?;
            if descending {
                ord = ord.reverse();
            }
            return Ok(ord);
        }
        for (sel, step_desc) in steps.iter() {
            let mut ord = self.apply_comparator_step(sel, a, b, out)?;
            if *step_desc {
                ord = ord.reverse();
            }
            if descending {
                ord = ord.reverse();
            }
            if !matches!(ord, std::cmp::Ordering::Equal) {
                return Ok(ord);
            }
        }
        Ok(std::cmp::Ordering::Equal)
    }

    /// A comparator step is either a key-selector (1-arg lambda returning a
    /// `Comparable` key) or a direct comparison (2-arg lambda returning Int).
    /// `thenComparator { a, b -> ... }` stores the latter; `compareBy` /
    /// `thenBy` store the former.
    fn apply_comparator_step(
        &mut self,
        sel: &Value,
        a: &Value,
        b: &Value,
        out: &mut dyn Output,
    ) -> Result<std::cmp::Ordering, RuntimeError> {
        let Value::Lambda { params, body, env: captured, .. } = sel else {
            return Err(RuntimeError::Type("comparator selector must be a lambda".into()));
        };
        if params.len() >= 2 {
            let pair = [a.clone(), b.clone()];
            let v = self.call_lambda(params, body, captured, &pair, out)?;
            let Value::Int(n) = v else {
                return Err(RuntimeError::Type(
                    "comparator lambda must return Int".into(),
                ));
            };
            return Ok(n.cmp(&0));
        }
        let ka = self.call_lambda(params, body, captured, std::slice::from_ref(a), out)?;
        let kb = self.call_lambda(params, body, captured, std::slice::from_ref(b), out)?;
        match (matches!(ka, Value::Null), matches!(kb, Value::Null)) {
            (true, true) => Ok(std::cmp::Ordering::Equal),
            (true, false) => Ok(std::cmp::Ordering::Less),
            (false, true) => Ok(std::cmp::Ordering::Greater),
            (false, false) => self.compare_with_user(&ka, &kb, out),
        }
    }

    /// Lambda-bearing members on a `Value::Result` receiver. The pure
    /// data members (`isSuccess`/`isFailure`/`getOrNull`/`exceptionOrNull`/
    /// `getOrDefault`) live in the stdlib intrinsic table.
    fn try_eval_result_member(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let Value::Result { ok, payload } = receiver else {
            return Ok(None);
        };
        match name {
            "fold" if args.len() == 2 => {
                let on_success = self.eval_expr(&args[0], env, out)?;
                let on_failure = self.eval_expr(&args[1], env, out)?;
                let lam = if *ok { &on_success } else { &on_failure };
                let Value::Lambda { params, body, env: captured, .. } = lam else {
                    return Err(RuntimeError::Type(
                        "Result.fold expects two lambdas".into(),
                    ));
                };
                let arg_slice = [(**payload).clone()];
                Ok(Some(self.call_lambda(params, body, captured, &arg_slice, out)?))
            }
            "map" if args.len() == 1 => {
                if !*ok {
                    return Ok(Some(receiver.clone()));
                }
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("Result.map expects a lambda".into()));
                };
                let arg_slice = [(**payload).clone()];
                let v = self.call_lambda(params, body, captured, &arg_slice, out)?;
                Ok(Some(Value::Result { ok: true, payload: Box::new(v) }))
            }
            "mapCatching" if args.len() == 1 => {
                if !*ok {
                    return Ok(Some(receiver.clone()));
                }
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "Result.mapCatching expects a lambda".into(),
                    ));
                };
                let arg_slice = [(**payload).clone()];
                match self.call_lambda(params, body, captured, &arg_slice, out) {
                    Ok(v) => Ok(Some(Value::Result { ok: true, payload: Box::new(v) })),
                    Err(RuntimeError::Thrown(e)) => Ok(Some(Value::Result {
                        ok: false,
                        payload: Box::new(e),
                    })),
                    Err(e) => Err(e),
                }
            }
            "onSuccess" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "Result.onSuccess expects a lambda".into(),
                    ));
                };
                if *ok {
                    let arg_slice = [(**payload).clone()];
                    self.call_lambda(params, body, captured, &arg_slice, out)?;
                }
                Ok(Some(receiver.clone()))
            }
            "onFailure" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "Result.onFailure expects a lambda".into(),
                    ));
                };
                if !*ok {
                    let arg_slice = [(**payload).clone()];
                    self.call_lambda(params, body, captured, &arg_slice, out)?;
                }
                Ok(Some(receiver.clone()))
            }
            "getOrElse" if args.len() == 1 => {
                if *ok {
                    return Ok(Some((**payload).clone()));
                }
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "Result.getOrElse expects a lambda".into(),
                    ));
                };
                let arg_slice = [(**payload).clone()];
                Ok(Some(self.call_lambda(params, body, captured, &arg_slice, out)?))
            }
            _ => Ok(None),
        }
    }

    /// `runCatching { block }` (no receiver) or `T.runCatching { block }`
    /// (with `receiver` set, which becomes the lambda's `this`). The block
    /// is invoked with no value arguments; thrown `RuntimeError::Thrown`
    /// payloads turn into `Result.failure`.
    fn eval_run_catching(
        &mut self,
        lam: &Value,
        receiver: Option<Value>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Value::Lambda { params, body, env: captured, .. } = lam else {
            return Err(RuntimeError::Type(
                "runCatching expects a lambda".into(),
            ));
        };
        let res = self.call_lambda_with_this(params, body, captured, &[], receiver, false, out);
        match res {
            Ok(v) => Ok(Value::Result { ok: true, payload: Box::new(v) }),
            Err(RuntimeError::Thrown(e)) => Ok(Value::Result {
                ok: false,
                payload: Box::new(e),
            }),
            Err(e) => Err(e),
        }
    }

    /// Host bridge: drive a `runBlocking { … }` lambda to
    /// completion. The lambda's body is lowered as if it were a
    /// suspend fun's body and driven through the state machine.
    /// If the body suspends, we keep the frame alive — its
    /// captured continuation must eventually be resumed by user
    /// code (or the call will hang).
    pub fn run_blocking(
        &mut self,
        lam: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Value::Lambda { params, body, env: captured, .. } = lam else {
            return Err(RuntimeError::Type(
                "runBlocking expects a lambda".into(),
            ));
        };
        // Synthesise an AST Function out of the lambda so the
        // suspend-body lowering can partition it. The synthetic
        // function takes no parameters and uses the lambda's
        // body verbatim.
        let synth = Rc::new(klio_ast::Function {
            name: klio_ast::Ident {
                name: "<runBlocking>".to_string(),
                span: body.span,
            },
            receiver_type: None,
            type_params: Vec::new(),
            where_bounds: Vec::new(),
            params: Vec::new(),
            return_type: None,
            body: Some(klio_ast::FunctionBody::Block((**body).clone())),
            is_open: false,
            is_override: false,
            is_abstract: false,
            is_operator: false,
            is_inline: false,
            is_infix: false,
            is_tailrec: false,
            is_suspend: true,
            visibility: klio_ast::Visibility::Public,
            annotations: Vec::new(),
            span: body.span,
        });
        // We don't care about the lambda's params here because
        // runBlocking's outer lambda is zero-arity in our model.
        // The captured env is the closure env for the body.
        let _ = params;
        let result = self.drive_suspend_function(&synth, captured, &[], out)?;
        if !matches!(result, Value::CoroutineSuspended(_)) {
            return Ok(result);
        }
        // The lambda suspended. The captured continuation is held
        // by whatever async machinery user code wired up; it must
        // eventually call resume(...) for our driver loop to
        // re-enter. Since we have no scheduler, the only way
        // forward is for the user code to have synchronously
        // arranged a resume — but at this point the synchronous
        // path already returned without doing so. Surface a
        // diagnostic rather than hang silently.
        Err(RuntimeError::Type(
            "runBlocking { … } suspended with no continuation resumed. \
             The block reached a suspension point and returned without any \
             cont.resume / cont.resumeWith / cont.resumeWithException firing, \
             so there is nothing to drive the coroutine forward."
                .into(),
        ))
    }

    /// Lower a suspend `fun foo()`'s body to a SuspendBody and run
    /// its state machine. Returns the final value when the body
    /// completes synchronously, or `Value::CoroutineSuspended(frame)`
    /// when execution paused mid-state. Caller handles either.
    fn drive_suspend_function(
        &mut self,
        decl: &Rc<klio_ast::Function>,
        captured_env: &Rc<RefCell<Env>>,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Some(body) = suspend_lower::lower(decl, &self.suspend_function_names) else {
            return Err(RuntimeError::Type(format!(
                "suspend fun `{}` has no block body",
                decl.name.name
            )));
        };
        // Set up a fresh env for the suspend body. Param bindings
        // live in this env; the state machine reads/writes the
        // locals slot for cross-state values.
        let frame_env = Rc::new(RefCell::new(Env::with_parent(Rc::clone(captured_env))));
        for (p, v) in decl.params.iter().zip(args.iter()) {
            frame_env.borrow_mut().define(p.name.name.clone(), v.clone());
        }
        let frame = Rc::new(RefCell::new(klio_runtime::SuspendFrame {
            decl: Rc::clone(decl),
            body: Rc::new(body),
            env: frame_env,
            locals: Vec::new(),
            state: 0,
            caller: None,
        }));
        self.drive_suspend_frame(&frame, None, out)
    }

    /// Run a suspend frame until its body either completes
    /// (returns a value) or pauses (returns
    /// `Value::CoroutineSuspended`). `resumed_value` is bound to
    /// the entry state's resume_target before execution.
    fn drive_suspend_frame(
        &mut self,
        frame: &Rc<RefCell<klio_runtime::SuspendFrame>>,
        mut resumed_value: Option<Value>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.active_suspend_frames.push(Rc::clone(frame));
        let result = (|| {
            loop {
                let (body, state_idx) = {
                    let f = frame.borrow();
                    (Rc::clone(&f.body), f.state)
                };
                let state = body
                    .states
                    .get(state_idx)
                    .cloned()
                    .ok_or_else(|| {
                        RuntimeError::Type(
                            "suspend state machine ran off the end".into(),
                        )
                    })?;
                // Bind resume target before the state's stmts run.
                // When the previous state ended at a suspending
                // call whose result needs to flow into the *return*
                // value (no explicit target), `resumed_value` is
                // threaded directly into `last`.
                let mut last = match &state.resume_target {
                    Some(target) => {
                        let value = resumed_value.take().unwrap_or(Value::Unit);
                        frame.borrow().env.borrow_mut().define(target.clone(), value);
                        Value::Unit
                    }
                    None => resumed_value.take().unwrap_or(Value::Unit),
                };
                // Execute the state's stmts against the frame's env.
                let env = Rc::clone(&frame.borrow().env);
                for stmt in &state.stmts {
                    let v = self.eval_stmt(stmt, &env, out)?;
                    if matches!(v, Value::CoroutineSuspended(_)) {
                        return Ok(v);
                    }
                    last = v;
                }
                match state.transition {
                    klio_runtime::SuspendTransition::Return => {
                        return Ok(last);
                    }
                    klio_runtime::SuspendTransition::Goto(next) => {
                        // After a suspending call the last expression's
                        // value becomes the resume value for the next
                        // state. If we're here without a real suspension,
                        // the suspendCoroutine call resumed synchronously
                        // and `last` holds the resumed value.
                        resumed_value = Some(last);
                        frame.borrow_mut().state = next;
                    }
                    klio_runtime::SuspendTransition::Branch { then_state, else_state } => {
                        let next = if matches!(last, Value::Bool(true)) {
                            then_state
                        } else {
                            else_state
                        };
                        frame.borrow_mut().state = next;
                    }
                }
            }
        })();
        self.active_suspend_frames.pop();
        result
    }

    /// Spec §18.2 `suspendCoroutine` / `suspendCoroutineUninterceptedOrReturn`.
    /// Allocates a continuation slot, builds a synthetic
    /// `Continuation` value bound to it, invokes the user lambda,
    /// and reads back whichever of `resume` / `resumeWith` /
    /// `resumeWithException` populated the slot. The state-machine
    /// lowering that lets a `suspend` body actually pause across
    /// dispatcher boundaries lives in `kotlinx.coroutines` — out
    /// of scope; what we provide here is the language-level
    /// machinery that lets a synchronous `suspendCoroutine { cont ->
    /// cont.resume(v) }` produce `v`.
    pub fn eval_suspend_coroutine(
        &mut self,
        lam: &Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let Value::Lambda { params, body, env: captured, .. } = lam else {
            return Err(RuntimeError::Type(
                "suspendCoroutine expects a lambda".into(),
            ));
        };
        let slot = Rc::new(RefCell::new(ContinuationSlot::Pending));
        self.coroutine_continuations.push(Rc::clone(&slot));
        let cont = self.make_continuation_value(Rc::clone(&slot));
        let lambda_result = self.call_lambda(params, body, captured, &[cont], out);
        let direct = match lambda_result {
            Ok(v) => v,
            Err(e) => {
                self.coroutine_continuations.pop();
                return Err(e);
            }
        };
        let slot_state = slot.borrow().clone();
        match slot_state {
            ContinuationSlot::Resumed(v) => {
                self.coroutine_continuations.pop();
                Ok(v)
            }
            ContinuationSlot::Failed(e) => {
                self.coroutine_continuations.pop();
                Err(RuntimeError::Thrown(e))
            }
            ContinuationSlot::Pending => {
                // The lambda didn't resume synchronously: a real
                // suspension. The driving suspend frame's state
                // machine will pause here; if no frame is active
                // (raw `suspendCoroutine` outside a state machine)
                // fall back to the previous "return the direct
                // value" behavior for the spec's
                // "Uninterceptedy"-shortcut case.
                if let Some(frame) = self.active_suspend_frames.last().cloned() {
                    // Don't pop the continuation slot — it lives
                    // on past this call so the captured cont can
                    // resume the frame later.
                    Ok(Value::CoroutineSuspended(frame))
                } else {
                    self.coroutine_continuations.pop();
                    Ok(direct)
                }
            }
        }
    }

    /// Build a synthetic `Continuation<T>` value the user lambda
    /// receives in `suspendCoroutine { cont -> … }`. Implemented as
    /// a `Value::Instance` of a runtime-only synthetic class so
    /// `cont.resume(v)` / `cont.resumeWith(r)` /
    /// `cont.resumeWithException(e)` and the `context` accessor
    /// dispatch through the standard member-lookup path.
    /// `kotlin.coroutines.EmptyCoroutineContext` as a synthetic
    /// `Value::Instance`. Returned by `Continuation.context` and
    /// available as the `coroutineContext` top-level property in a
    /// suspend body.
    fn empty_coroutine_context(&self) -> Value {
        let class = Rc::new(ClassDef {
            name: "EmptyCoroutineContext".to_string(),
            fqn: "kotlin.coroutines.EmptyCoroutineContext".to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            is_data: false,
            is_object: true,
            is_enum: false,
            is_sealed: false,
            supertype_names: vec!["CoroutineContext".to_string()],
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: true,
            secondary_ctors: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::new(RefCell::new(klio_runtime::Env::new())),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        });
        Value::Instance(Rc::new(RefCell::new(InstanceData {
            class,
            fields: Vec::new(),
            outer: None,
            identity: 0,
            native_state: None,
        })))
    }

    fn make_continuation_value(&self, slot: Rc<RefCell<ContinuationSlot>>) -> Value {
        let class = Rc::new(ClassDef {
            name: "Continuation".to_string(),
            fqn: "kotlin.coroutines.Continuation".to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            is_data: false,
            is_object: false,
            is_enum: false,
            is_sealed: false,
            supertype_names: vec!["Continuation".to_string()],
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: true,
            secondary_ctors: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::new(RefCell::new(klio_runtime::Env::new())),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        });
        let inst = Rc::new(RefCell::new(InstanceData {
            class,
            fields: Vec::new(),
            outer: None,
            identity: 0,
            native_state: None,
        }));
        // The active suspendCoroutine call holds the slot at the top
        // of coroutine_continuations; the instance itself is a
        // marker. resume / resumeWith / resumeWithException
        // dispatch reaches in through the stack.
        let _ = slot;
        Value::Instance(inst)
    }

    /// Indexed higher-order list ops: `mapIndexed`, `forEachIndexed`,
    /// `filterIndexed`. The lambda receives `(index, value)`.
    fn try_eval_indexed_higher_order(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let items: Vec<Value> = match receiver {
            Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
            _ => return Ok(None),
        };
        match name {
            "mapIndexed" | "forEachIndexed" | "filterIndexed" => {}
            _ => return Ok(None),
        }
        let lam_expr = args.last().ok_or_else(|| {
            RuntimeError::Arity(format!("{name} requires a lambda argument"))
        })?;
        let lam = self.eval_expr(lam_expr, env, out)?;
        let Value::Lambda { params, body, env: captured, .. } = &lam else {
            return Err(RuntimeError::Type(format!("{name} requires a lambda argument")));
        };
        match name {
            "mapIndexed" => {
                let mut out_items = Vec::with_capacity(items.len());
                for (i, v) in items.into_iter().enumerate() {
                    let r = self.call_lambda(
                        params, body, captured,
                        &[Value::new_int(i), v], out,
                    )?;
                    out_items.push(r);
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            "forEachIndexed" => {
                for (i, v) in items.into_iter().enumerate() {
                    self.call_lambda(
                        params, body, captured,
                        &[Value::new_int(i), v], out,
                    )?;
                }
                Ok(Some(Value::Unit))
            }
            "filterIndexed" => {
                let mut out_items = Vec::new();
                for (i, v) in items.into_iter().enumerate() {
                    let r = self.call_lambda(
                        params, body, captured,
                        &[Value::new_int(i), v.clone()], out,
                    )?;
                    if matches!(r, Value::Bool(true)) {
                        out_items.push(v);
                    }
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            _ => unreachable!(),
        }
    }

    /// Map higher-order ops: `filterKeys`, `filterValues`, `mapKeys`,
    /// `mapValues`, `getOrElse`, `getOrPut`, `forEach`.
    fn try_eval_map_higher_order(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let entries_rc = match receiver {
            Value::Map { entries, .. } => Rc::clone(entries),
            _ => return Ok(None),
        };
        match name {
            "filterKeys" | "filterValues" | "mapKeys" | "mapValues" => {
                let lam_expr = args.last().ok_or_else(|| {
                    RuntimeError::Arity(format!("{name} requires a lambda"))
                })?;
                let lam = self.eval_expr(lam_expr, env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(format!("{name} requires a lambda")));
                };
                let entries = entries_rc.borrow().clone();
                let mut out_entries: Vec<(Value, Value)> = Vec::new();
                match name {
                    "filterKeys" => {
                        for (k, v) in entries {
                            let r = self.call_lambda(params, body, captured, std::slice::from_ref(&k), out)?;
                            if matches!(r, Value::Bool(true)) {
                                out_entries.push((k, v));
                            }
                        }
                    }
                    "filterValues" => {
                        for (k, v) in entries {
                            let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                            if matches!(r, Value::Bool(true)) {
                                out_entries.push((k, v));
                            }
                        }
                    }
                    "mapKeys" => {
                        for (k, v) in entries {
                            let entry = Value::MapEntry { key: Box::new(k.clone()), value: Box::new(v.clone()) };
                            let new_k = self.call_lambda(params, body, captured, std::slice::from_ref(&entry), out)?;
                            out_entries.push((new_k, v));
                        }
                    }
                    "mapValues" => {
                        for (k, v) in entries {
                            let entry = Value::MapEntry { key: Box::new(k.clone()), value: Box::new(v.clone()) };
                            let new_v = self.call_lambda(params, body, captured, std::slice::from_ref(&entry), out)?;
                            out_entries.push((k, new_v));
                        }
                    }
                    _ => unreachable!(),
                }
                Ok(Some(Value::Map {
                    entries: Rc::new(RefCell::new(out_entries)),
                    mutable: false,
                }))
            }
            "getOrElse" if args.len() == 2 => {
                let key = self.eval_expr(&args[0], env, out)?;
                let entries = entries_rc.borrow();
                if let Some((_, v)) = entries.iter().find(|(k, _)| Value::structural_eq(k, &key)) {
                    return Ok(Some(v.clone()));
                }
                drop(entries);
                let lam = self.eval_expr(&args[1], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("getOrElse requires a lambda".into()));
                };
                let r = self.call_lambda(params, body, captured, &[], out)?;
                Ok(Some(r))
            }
            "getOrPut" if args.len() == 2 => {
                let key = self.eval_expr(&args[0], env, out)?;
                if let Some((_, v)) = entries_rc.borrow().iter().find(|(k, _)| Value::structural_eq(k, &key)) {
                    return Ok(Some(v.clone()));
                }
                let lam = self.eval_expr(&args[1], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("getOrPut requires a lambda".into()));
                };
                let new_v = self.call_lambda(params, body, captured, &[], out)?;
                entries_rc.borrow_mut().push((key, new_v.clone()));
                Ok(Some(new_v))
            }
            "forEach" if args.len() == 1 => {
                let lam = self.eval_expr(&args[0], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type("forEach requires a lambda".into()));
                };
                let entries = entries_rc.borrow().clone();
                for (k, v) in entries {
                    let entry = Value::MapEntry { key: Box::new(k), value: Box::new(v) };
                    self.call_lambda(params, body, captured, std::slice::from_ref(&entry), out)?;
                }
                Ok(Some(Value::Unit))
            }
            _ => Ok(None),
        }
    }

    /// Higher-order collection operations that take a lambda. Like scoping
    /// fns these need to call back into the interpreter, so they live here
    /// rather than in stdlib intrinsics.
    fn try_eval_collection_higher_order(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        self.implicit_lambda_label_stack.push(name.to_string());
        let r = self.try_eval_collection_higher_order_inner(receiver, name, args, env, out);
        self.implicit_lambda_label_stack.pop();
        r
    }

    fn try_eval_collection_higher_order_inner(
        &mut self,
        receiver: &Value,
        name: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let (items, is_sequence) = match receiver {
            Value::List { items, .. } => (items.borrow().clone(), false),
            Value::Set { items, .. } => (items.borrow().clone(), false),
            Value::Map { entries, .. } => (
                entries
                    .borrow()
                    .iter()
                    .map(|(k, v)| Value::MapEntry {
                        key: Box::new(k.clone()),
                        value: Box::new(v.clone()),
                    })
                    .collect(),
                false,
            ),
            Value::Sequence(_) => {
                // Sequence receivers go through the dedicated sequence
                // dispatcher (handled before this generic HOF dispatch).
                return Ok(None);
            }
            _ => return Ok(None),
        };
        let lam_expr = match name {
            "map" | "filter" | "filterNot" | "forEach" | "any" | "all" | "none" | "find"
            | "first" | "firstOrNull" | "last" | "lastOrNull"
            | "count" | "sumOf" | "maxOf" | "minOf" | "fold" | "reduce" | "sortedBy"
            | "sortedByDescending" | "distinctBy" | "groupBy" | "associate" | "associateBy"
            | "associateWith" | "partition" | "flatMap" | "takeWhile" | "dropWhile" => {
                // Predicate-free forms like `xs.count()` / `xs.any()` fall
                // through to the regular stdlib dispatcher so they pick up
                // the no-arg intrinsic. The HOF path only fires when the
                // call actually carries a lambda.
                match args.last() {
                    Some(a) => a,
                    None => return Ok(None),
                }
            }
            _ => return Ok(None),
        };
        let initial = if matches!(name, "fold") {
            args.first()
                .ok_or_else(|| RuntimeError::Arity("fold requires an initial value".into()))?
                .clone()
        } else {
            Expr::NullLit { span: klio_span::Span::new(klio_span::FileId(0), 0, 0) }
        };
        let _ = initial; // keep clippy quiet — fold reads its initial below
        let lam = self.eval_expr(lam_expr, env, out)?;
        // Allow callable references (`Foo::name`, `String::uppercase`,
        // `::topFn`) as the higher-order argument by wrapping the call
        // through `invoke_callable_value`. We synthesize a tiny lambda
        // shim by routing all single-argument applications through a
        // helper closure.
        let lam_for_dispatch = lam.clone();
        let mut apply_to = |this: &mut Interpreter,
                            recv: Value,
                            out: &mut dyn Output|
         -> Result<Value, RuntimeError> {
            match &lam_for_dispatch {
                Value::Lambda { params, body, env: captured, absorb_return } => this
                    .call_lambda_with_this(
                        params,
                        body,
                        captured,
                        std::slice::from_ref(&recv),
                        None,
                        *absorb_return,
                        out,
                    ),
                Value::PropertyRef { name: pname } => this.eval_property_access(recv, pname, out),
                _ => this.invoke_callable_value(&lam_for_dispatch, &[recv], &[], out),
            }
        };
        let _ = &mut apply_to;
        let Value::Lambda { params, body, env: captured, .. } = &lam else {
            // For non-lambda callables, route through `apply_to` for the
            // operations that take a single-argument transform. Fall
            // through with synthesized output for those cases below; the
            // remaining ops still require a real Lambda.
            return match name {
                "map" => {
                    let mut out_items = Vec::with_capacity(items.len());
                    for v in items {
                        out_items.push(apply_to(self, v, out)?);
                    }
                    Ok(Some(wrap_collection(out_items, is_sequence)))
                }
                "forEach" => {
                    for v in items {
                        apply_to(self, v, out)?;
                    }
                    Ok(Some(Value::Unit))
                }
                "filter" => {
                    let mut out_items = Vec::new();
                    for v in items {
                        let r = apply_to(self, v.clone(), out)?;
                        if matches!(r, Value::Bool(true)) {
                            out_items.push(v);
                        }
                    }
                    Ok(Some(wrap_collection(out_items, is_sequence)))
                }
                "filterNot" => {
                    let mut out_items = Vec::new();
                    for v in items {
                        let r = apply_to(self, v.clone(), out)?;
                        if matches!(r, Value::Bool(false)) {
                            out_items.push(v);
                        }
                    }
                    Ok(Some(wrap_collection(out_items, is_sequence)))
                }
                "sortedBy" => {
                    let mut tagged: Vec<(Value, Value)> = Vec::with_capacity(items.len());
                    for v in items {
                        let k = apply_to(self, v.clone(), out)?;
                        tagged.push((k, v));
                    }
                    tagged.sort_by(|a, b| {
                        klio_stdlib::compare_values(&a.0, &b.0).unwrap_or(std::cmp::Ordering::Equal)
                    });
                    let result: Vec<Value> = tagged.into_iter().map(|(_, v)| v).collect();
                    Ok(Some(wrap_collection(result, is_sequence)))
                }
                "groupBy" => {
                    let mut entries: Vec<(Value, Vec<Value>)> = Vec::new();
                    for v in items {
                        let k = apply_to(self, v.clone(), out)?;
                        match entries.iter_mut().find(|(ek, _)| Value::structural_eq(ek, &k)) {
                            Some((_, list)) => list.push(v),
                            None => entries.push((k, vec![v])),
                        }
                    }
                    let map_entries: Vec<(Value, Value)> = entries
                        .into_iter()
                        .map(|(k, vs)| {
                            (
                                k,
                                Value::List {
                                    items: Rc::new(RefCell::new(vs)),
                                    mutable: false,
                                    enum_class: None,
                                },
                            )
                        })
                        .collect();
                    Ok(Some(Value::Map {
                        entries: Rc::new(RefCell::new(map_entries)),
                        mutable: false,
                    }))
                }
                _ => Err(RuntimeError::Type(format!(
                    "`.{name}` requires a lambda argument"
                ))),
            };
        };
        match name {
            "forEach" => {
                for v in items {
                    self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                }
                Ok(Some(Value::Unit))
            }
            "map" => {
                let mut out_items = Vec::with_capacity(items.len());
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    out_items.push(r);
                }
                Ok(Some(wrap_collection(out_items, is_sequence)))
            }
            "filter" => {
                let mut out_items = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        out_items.push(v);
                    }
                }
                Ok(Some(wrap_collection(out_items, is_sequence)))
            }
            "filterNot" => {
                let mut out_items = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(false)) {
                        out_items.push(v);
                    }
                }
                Ok(Some(wrap_collection(out_items, is_sequence)))
            }
            "any" => {
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        return Ok(Some(Value::Bool(true)));
                    }
                }
                Ok(Some(Value::Bool(false)))
            }
            "all" => {
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if !matches!(r, Value::Bool(true)) {
                        return Ok(Some(Value::Bool(false)));
                    }
                }
                Ok(Some(Value::Bool(true)))
            }
            "none" => {
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        return Ok(Some(Value::Bool(false)));
                    }
                }
                Ok(Some(Value::Bool(true)))
            }
            "find" | "firstOrNull" => {
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        return Ok(Some(v));
                    }
                }
                Ok(Some(Value::Null))
            }
            "first" => {
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        return Ok(Some(v));
                    }
                }
                Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.NoSuchElementException".into()),
                    message: Some(Rc::new(
                        "Collection contains no element matching the predicate.".into(),
                    )),
                    cause: None,
                }))
            }
            "lastOrNull" => {
                let mut found: Option<Value> = None;
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        found = Some(v);
                    }
                }
                Ok(Some(found.unwrap_or(Value::Null)))
            }
            "last" => {
                let mut found: Option<Value> = None;
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        found = Some(v);
                    }
                }
                found.map(Some).ok_or_else(|| {
                    RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.NoSuchElementException".into()),
                        message: Some(Rc::new(
                            "Collection contains no element matching the predicate.".into(),
                        )),
                        cause: None,
                    })
                })
            }
            "count" => {
                let mut n = 0i64;
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        n += 1;
                    }
                }
                Ok(Some(Value::new_int(n)))
            }
            "sumOf" => {
                let mut acc_int: Option<i64> = Some(0);
                let mut acc_dbl: Option<f64> = None;
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if r.is_integral() {
                        let n = r.as_i64().unwrap();
                        if let Some(a) = acc_int.as_mut() {
                            *a = a.wrapping_add(n);
                        } else if let Some(a) = acc_dbl.as_mut() {
                            *a += n as f64;
                        }
                    } else if r.is_floating() {
                        let d = r.as_f64().unwrap();
                        if let Some(a) = acc_int.take() {
                            acc_dbl = Some(a as f64 + d);
                        } else if let Some(a) = acc_dbl.as_mut() {
                            *a += d;
                        }
                    } else {
                        return Err(RuntimeError::Type(format!(
                            "sumOf selector must return Int or Double, got {r:?}"
                        )));
                    }
                }
                Ok(Some(match acc_dbl {
                    Some(d) => Value::Double(d),
                    None => Value::new_int(acc_int.unwrap_or(0)),
                }))
            }
            "maxOf" | "minOf" => {
                let mut best: Option<Value> = None;
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    best = Some(match (best, r) {
                        (None, r) => r,
                        (Some(a), b) => choose_extreme(name, a, b)?,
                    });
                }
                best.ok_or_else(|| {
                    RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.NoSuchElementException".into()),
                        message: Some(Rc::new("Collection is empty.".into())),
                        cause: None,
                    })
                })
                .map(Some)
            }
            "fold" => {
                let mut acc = self.eval_expr(&args[0], env, out)?;
                for v in items {
                    let lam_args = [acc.clone(), v];
                    acc = self.call_lambda(params, body, captured, &lam_args, out)?;
                }
                Ok(Some(acc))
            }
            "reduce" => {
                let mut iter = items.into_iter();
                let Some(mut acc) = iter.next() else {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.UnsupportedOperationException".into()),
                        message: Some(Rc::new("Empty collection can't be reduced.".into())),
                        cause: None,
                    }));
                };
                for v in iter {
                    let lam_args = [acc.clone(), v];
                    acc = self.call_lambda(params, body, captured, &lam_args, out)?;
                }
                Ok(Some(acc))
            }
            "sortedBy" | "sortedByDescending" => {
                let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
                for v in items {
                    let key = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    keyed.push((key, v));
                }
                let descending = name == "sortedByDescending";
                self.insertion_sort_keyed(&mut keyed, descending, out)?;
                let out_items: Vec<Value> = keyed.into_iter().map(|(_, v)| v).collect();
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            "distinctBy" => {
                let mut keys: Vec<Value> = Vec::new();
                let mut out_items: Vec<Value> = Vec::new();
                for v in items {
                    let key = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if !keys.iter().any(|k| Value::structural_eq(k, &key)) {
                        keys.push(key);
                        out_items.push(v);
                    }
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            "groupBy" => {
                let mut groups: Vec<(Value, Vec<Value>)> = Vec::new();
                for v in items {
                    let key = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if let Some(slot) = groups.iter_mut().find(|(k, _)| Value::structural_eq(k, &key)) {
                        slot.1.push(v);
                    } else {
                        groups.push((key, vec![v]));
                    }
                }
                let entries: Vec<(Value, Value)> = groups
                    .into_iter()
                    .map(|(k, vs)| (k, Value::List { items: Rc::new(RefCell::new(vs)), mutable: false, enum_class: None }))
                    .collect();
                Ok(Some(Value::Map {
                    entries: Rc::new(RefCell::new(entries)),
                    mutable: false,
                }))
            }
            "associate" => {
                // Lambda must return a Pair.
                let mut entries: Vec<(Value, Value)> = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    let Value::Pair(k, val) = r else {
                        return Err(RuntimeError::Type(
                            "associate selector must return Pair".into(),
                        ));
                    };
                    let key = *k;
                    if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &key)) {
                        slot.1 = *val;
                    } else {
                        entries.push((key, *val));
                    }
                }
                Ok(Some(Value::Map {
                    entries: Rc::new(RefCell::new(entries)),
                    mutable: false,
                }))
            }
            "associateBy" => {
                let mut entries: Vec<(Value, Value)> = Vec::new();
                for v in items {
                    let key = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &key)) {
                        slot.1 = v;
                    } else {
                        entries.push((key, v));
                    }
                }
                Ok(Some(Value::Map {
                    entries: Rc::new(RefCell::new(entries)),
                    mutable: false,
                }))
            }
            "associateWith" => {
                let mut entries: Vec<(Value, Value)> = Vec::new();
                for v in items {
                    let val = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if let Some(slot) = entries.iter_mut().find(|(kk, _)| Value::structural_eq(kk, &v)) {
                        slot.1 = val;
                    } else {
                        entries.push((v, val));
                    }
                }
                Ok(Some(Value::Map {
                    entries: Rc::new(RefCell::new(entries)),
                    mutable: false,
                }))
            }
            "partition" => {
                let mut yes = Vec::new();
                let mut no = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        yes.push(v);
                    } else {
                        no.push(v);
                    }
                }
                Ok(Some(Value::Pair(
                    Box::new(Value::List { items: Rc::new(RefCell::new(yes)), mutable: false, enum_class: None }),
                    Box::new(Value::List { items: Rc::new(RefCell::new(no)), mutable: false, enum_class: None }),
                )))
            }
            "flatMap" => {
                let mut out_items = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    match r {
                        Value::List { items, .. } => out_items.extend(items.borrow().clone()),
                        Value::Set { items, .. } => out_items.extend(items.borrow().clone()),
                        Value::Range { start, end, step, kind } => {
                            for n in range_iter(start, end, step) {
                                out_items.push(match kind {
                                    klio_runtime::RangeKind::Long => Value::Long(n),
                                    klio_runtime::RangeKind::Int => Value::new_int(n as i32),
                                    klio_runtime::RangeKind::Char => char::from_u32(n as u32)
                                        .map(Value::Char)
                                        .unwrap_or(Value::Null),
                                });
                            }
                        }
                        other => {
                            return Err(RuntimeError::Type(format!(
                                "flatMap selector must return a List/Set/Range, got {other:?}"
                            )))
                        }
                    }
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            "takeWhile" => {
                let mut out_items = Vec::new();
                for v in items {
                    let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                    if matches!(r, Value::Bool(true)) {
                        out_items.push(v);
                    } else {
                        break;
                    }
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            "dropWhile" => {
                let mut out_items = Vec::new();
                let mut dropping = true;
                for v in items {
                    if dropping {
                        let r = self.call_lambda(params, body, captured, std::slice::from_ref(&v), out)?;
                        if matches!(r, Value::Bool(true)) {
                            continue;
                        }
                        dropping = false;
                    }
                    out_items.push(v);
                }
                Ok(Some(Value::List { items: Rc::new(RefCell::new(out_items)), mutable: false, enum_class: None }))
            }
            _ => unreachable!(),
        }
    }

    /// Build a `ClassDef` shell from a parsed `Class` — methods/properties,
    /// companion, modifiers. Enum entries and parent-link resolution are
    /// done in later passes by the caller; that ordering is what lets a
    /// subclass declared above its parent in source order still work, and
    /// lets enum-entry construction see resolved methods.
    fn build_class_shell(
        &mut self,
        c: &klio_ast::Class,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Rc<ClassDef>, RuntimeError> {
        // Spec §17.2: capture the @Retention on an annotation class
        // when it is declared, so applications of that class can
        // be filtered when reflection asks for them later.
        if c.is_annotation {
            let retention = extract_retention(&c.annotations).unwrap_or_else(|| "RUNTIME".to_string());
            self.annotation_class_retentions
                .insert(c.name.name.clone(), retention);
        }
        let mut methods = Vec::new();
        let mut body_properties = Vec::new();
        // Defer companion-object construction until after the outer
        // class is built and bound to env so the companion's own
        // initializers can reference the enclosing class by name
        // (`class M { companion { val DEFAULT = M(...) } }`).
        let mut companion_ast: Option<klio_ast::Class> = None;
        for m in &c.members {
            match m {
                Decl::Function(f) => methods.push(MethodDef {
                    name: f.name.name.clone(),
                    decl: Rc::new(f.clone()),
                    is_operator: false,
                    is_open: f.is_open,
                    is_override: f.is_override,
                    is_abstract: f.is_abstract,
                    sam_lambda: None,
                    delegate_field: None,
                }),
                Decl::Property(p) => body_properties.push(PropertyDef {
                    name: p.name.name.clone(),
                    mutable: p.mutable,
                    init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                    getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                    setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                    delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                    is_abstract: p.is_abstract,
                    is_lateinit: p.is_lateinit,
                }),
                Decl::Class(inner) if inner.is_companion => {
                    companion_ast = Some(inner.clone());
                }
                _ => {}
            }
        }
        // Nested (non-companion) classes — collected here, parent-link
        // resolution happens after the outer class is itself in scope.
        let mut nested: Vec<(String, Rc<klio_ast::Class>)> = Vec::new();
        let mut nested_objects: Vec<(String, klio_ast::ObjectDecl)> = Vec::new();
        for m in &c.members {
            match m {
                Decl::Class(inner) if !inner.is_companion => {
                    nested.push((inner.name.name.clone(), Rc::new(inner.clone())));
                }
                Decl::Object(o) => {
                    nested_objects.push((o.name.name.clone(), o.clone()));
                }
                _ => {}
            }
        }
        let primary_params = c
            .primary_params
            .iter()
            .map(|p| ClassParamDef {
                property: p.property,
                name: p.name.name.clone(),
                default: p.default.as_ref().map(|e| Rc::new(e.clone())),
            })
            .collect();
        let init_blocks = c
            .init_blocks
            .iter()
            .map(|b| Rc::new(b.clone()))
            .collect();
        // Capture parent-ctor args from the first supertype that has them.
        let parent_ctor_args: Vec<Rc<klio_ast::Expr>> = c
            .supertype_args
            .iter()
            .find_map(|a| a.as_ref())
            .map(|args| args.iter().map(|e| Rc::new(e.clone())).collect())
            .unwrap_or_default();
        let secondary_ctors: Vec<Rc<klio_ast::SecondaryCtor>> = c
            .secondary_ctors
            .iter()
            .map(|s| Rc::new(s.clone()))
            .collect();
        // Inheritance-delegation table — paired with `supertypes`. Each
        // entry carries the supertype name and the delegate expression
        // (evaluated at construction into a field on the instance).
        // Forwarder synthesis happens later at parent-link resolution,
        // once the named interface is reliably in scope.
        let mut supertype_delegates: Vec<klio_runtime::SupertypeDelegate> = Vec::new();
        for (idx, opt) in c.supertype_delegates.iter().enumerate() {
            let Some(expr) = opt else { continue };
            let iface_name = c
                .supertypes
                .get(idx)
                .map(|t| t.name.name.clone())
                .unwrap_or_default();
            supertype_delegates.push(klio_runtime::SupertypeDelegate {
                interface_name: iface_name,
                interface: None,
                expr: Rc::new(expr.clone()),
                field_key: format!("$$delegate${}", idx),
            });
        }
        let outer_class = Rc::new(ClassDef {
            name: c.name.name.clone(),
            fqn: self.qualify_simple_name(&c.name.name),
            annotation_names: self.runtime_annotation_names(&c.annotations),
            primary_params,
            methods,
            body_properties,
            init_blocks,
            is_data: c.is_data,
            is_object: c.is_companion,
            is_enum: c.is_enum,
            is_sealed: c.is_sealed,
            is_open: c.is_open,
            is_abstract: c.is_abstract,
            is_inner: c.is_inner,
            is_anonymous: c.name.name == "<no name provided>",
            secondary_ctors,
            supertype_names: c.supertypes.iter().map(|t| t.name.name.clone()).collect(),
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: c.is_interface,
            is_fun_interface: c.is_fun_interface,
            parent_ctor_args,
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::clone(env),
            supertype_delegates: RefCell::new(supertype_delegates),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        });
        // Bind the outer class into env *before* building the
        // companion object so its initializers can reference the
        // enclosing class by simple name. The same env binding
        // happens further down for nested-class shell resolution;
        // we hoist it here so the companion benefits too.
        let had_self = env.borrow().lookup(&c.name.name).is_some();
        if !had_self {
            env.borrow_mut()
                .define(c.name.name.clone(), Value::Class(Rc::clone(&outer_class)));
        }
        if let Some(ast) = companion_ast {
            let comp_class = self.build_class_shell(&ast, env, out)?;
            let comp_inst = self.construct_object_singleton(&comp_class, out)?;
            *outer_class.companion.borrow_mut() = Some(comp_inst);
        }
        // Set companion's back-link to the enclosing class so its method
        // bodies can see enum entries / `entries` when the enclosing class
        // is an enum.
        if let Some(comp) = outer_class.companion.borrow().as_ref() {
            *comp.borrow().class.enclosing_class.borrow_mut() =
                Some(Rc::clone(&outer_class));
        }
        // Build nested-class shells against the same env. Each shell's
        // `captured_env` is the outer class's env so inner methods can
        // resolve names the outer class can see.
        let mut nested_built: Vec<(String, Rc<ClassDef>)> = Vec::with_capacity(nested.len());
        let mut pending_nested_enums: Vec<(Rc<ClassDef>, Rc<klio_ast::Class>)> = Vec::new();
        for (n, inner) in &nested {
            let nested_class = self.build_class_shell(inner, env, out)?;
            // Back-link the nested class to its enclosing class so bare-name
            // reads inside the nested class (or its companion) can reach
            // the enclosing class's companion. Spec §6.1: companion decl
            // scope is ULD to the companion decl scope of the parent of
            // its parent classifier.
            *nested_class.enclosing_class.borrow_mut() = Some(Rc::clone(&outer_class));
            if let Some(comp) = nested_class.companion.borrow().as_ref() {
                *comp.borrow().class.enclosing_class.borrow_mut() =
                    Some(Rc::clone(&nested_class));
            }
            if inner.is_enum {
                pending_nested_enums.push((Rc::clone(&nested_class), Rc::clone(inner)));
            }
            nested_built.push((n.clone(), nested_class));
        }
        for (n, o) in &nested_objects {
            let nested_class = self.build_object_class(o, env, out)?;
            *nested_class.enclosing_class.borrow_mut() = Some(Rc::clone(&outer_class));
            nested_built.push((n.clone(), nested_class));
        }
        for (_, nc) in &nested_built {
            self.resolve_parent_link(nc);
        }
        // Build enum entries for nested enums after parent links resolve.
        for (nc, ast) in pending_nested_enums {
            self.build_enum_entries(&nc, &ast, env, out)?;
        }
        if !had_self {
            env.borrow_mut().remove_local(&c.name.name);
        }
        *outer_class.nested_classes.borrow_mut() = nested_built;
        Ok(outer_class)
    }

    /// Resolve `class.parent` (first non-interface class supertype) and
    /// `class.interfaces` (every supertype that resolves to an interface).
    /// Supertype names that don't resolve to a `Value::Class` in scope are
    /// silently dropped — `kotlinc` would have rejected those at compile
    /// time, so the runtime treats them as unobservable.
    fn resolve_parent_link(&mut self, class: &Rc<ClassDef>) {
        let mut parent: Option<Rc<ClassDef>> = None;
        let mut ifaces: Vec<Rc<ClassDef>> = Vec::new();
        for name in &class.supertype_names {
            if let Some(Value::Class(c)) = class.captured_env.borrow().lookup(name) {
                if c.is_interface {
                    ifaces.push(c);
                } else if parent.is_none() {
                    parent = Some(c);
                }
            }
        }
        *class.parent.borrow_mut() = parent;
        *class.interfaces.borrow_mut() = ifaces;
        // Resolve each delegated supertype's interface and synthesize
        // forwarder methods for every interface member not already
        // declared on this class. `equals` / `hashCode` / `toString`
        // from `Any` are intentionally not delegated.
        let mut forwarders: Vec<MethodDef> = Vec::new();
        let mut delegates = class.supertype_delegates.borrow().clone();
        for delegate in delegates.iter_mut() {
            if delegate.interface.is_none() {
                if let Some(Value::Class(c)) =
                    class.captured_env.borrow().lookup(&delegate.interface_name)
                {
                    if c.is_interface {
                        delegate.interface = Some(c);
                    }
                }
            }
            let Some(iface) = &delegate.interface else { continue };
            let mut iface_methods: Vec<String> = Vec::new();
            collect_interface_member_names(iface, &mut iface_methods, &mut Vec::new());
            for mname in iface_methods {
                if class.methods.iter().any(|m| m.name == mname) {
                    continue;
                }
                if forwarders.iter().any(|m| m.name == mname) {
                    continue;
                }
                if matches!(mname.as_str(), "equals" | "hashCode" | "toString") {
                    continue;
                }
                let proto = iface.methods.iter().find(|m| m.name == mname).cloned();
                let Some(proto) = proto else { continue };
                forwarders.push(MethodDef {
                    name: mname,
                    decl: proto.decl,
                    is_operator: proto.is_operator,
                    is_open: true,
                    is_override: true,
                    is_abstract: false,
                    sam_lambda: None,
                    delegate_field: Some(delegate.field_key.clone()),
                });
            }
        }
        *class.supertype_delegates.borrow_mut() = delegates;
        *class.delegate_forwarders.borrow_mut() = forwarders;
    }

    /// Back-compat shim — local class declarations (`Stmt::Decl(Decl::Class)`)
    /// still go through `build_class`, which now resolves the parent link
    /// against the in-scope env right after build.
    fn build_class(
        &mut self,
        c: &klio_ast::Class,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Rc<ClassDef>, RuntimeError> {
        let class = self.build_class_shell(c, env, out)?;
        self.resolve_parent_link(&class);
        if c.is_enum {
            self.build_enum_entries(&class, c, env, out)?;
        }
        Ok(class)
    }

    /// Build one `Value::Instance` per enum entry. When an entry declares
    /// body members, the entry instance uses a synthetic sub-`ClassDef`
    /// whose methods override the enum-class methods. The instance always
    /// carries `name` and `ordinal` fields plus the primary-ctor properties.
    fn build_enum_entries(
        &mut self,
        class: &Rc<ClassDef>,
        c: &klio_ast::Class,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        for (ordinal, entry) in c.enum_entries.iter().enumerate() {
            let mut arg_vals = Vec::with_capacity(entry.args.len());
            for a in &entry.args {
                arg_vals.push(self.eval_expr(a, env, out)?);
            }
            // Sub-class for entries with body overrides.
            let entry_class = if entry.body_members.is_empty() {
                Rc::clone(class)
            } else {
                let mut methods = class.methods.clone();
                let mut body_properties = class.body_properties.clone();
                for m in &entry.body_members {
                    match m {
                        Decl::Function(f) => {
                            let new_m = MethodDef {
                                name: f.name.name.clone(),
                                decl: Rc::new(f.clone()),
                                is_operator: false,
                                is_open: f.is_open,
                                is_override: f.is_override,
                                is_abstract: f.is_abstract,
                    sam_lambda: None,
                    delegate_field: None,
                            };
                            if let Some(slot) =
                                methods.iter_mut().find(|m| m.name == f.name.name)
                            {
                                *slot = new_m;
                            } else {
                                methods.push(new_m);
                            }
                        }
                        Decl::Property(p) => body_properties.push(PropertyDef {
                            name: p.name.name.clone(),
                            mutable: p.mutable,
                            init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                            getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                            setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                            delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                            is_abstract: p.is_abstract,
                            is_lateinit: p.is_lateinit,
                        }),
                        _ => {}
                    }
                }
                Rc::new(ClassDef {
                    name: class.name.clone(),
                    fqn: class.fqn.clone(),
                    annotation_names: class.annotation_names.clone(),
                    primary_params: class.primary_params.clone(),
                    methods,
                    body_properties,
                    init_blocks: class.init_blocks.clone(),
                    is_data: false,
                    is_object: false,
                    is_enum: true,
                    is_sealed: class.is_sealed,
                    is_open: false,
                    is_abstract: false,
                    is_inner: false,
                    is_anonymous: false,
                    secondary_ctors: class.secondary_ctors.clone(),
                    supertype_names: class.supertype_names.clone(),
                    parent: RefCell::new(class.parent.borrow().clone()),
                    interfaces: RefCell::new(class.interfaces.borrow().clone()),
                    is_interface: false,
                    is_fun_interface: false,
                    parent_ctor_args: class.parent_ctor_args.clone(),
                    enum_entries: RefCell::new(Vec::new()),
                    companion: RefCell::new(class.companion.borrow().clone()),
                    enclosing_class: RefCell::new(class.enclosing_class.borrow().clone()),
                    nested_classes: RefCell::new(class.nested_classes.borrow().clone()),
                    captured_env: Rc::clone(&class.captured_env),
                    supertype_delegates: RefCell::new(class.supertype_delegates.borrow().clone()),
                    delegate_forwarders: RefCell::new(class.delegate_forwarders.borrow().clone()),
                    object_singleton: RefCell::new(None),
                })
            };
            // Construct the instance against the entry class.
            let arg_names: Vec<Option<String>> = vec![None; arg_vals.len()];
            let v = self.construct_instance(&entry_class, &arg_vals, &arg_names, out)?;
            // Augment with `name` / `ordinal`.
            if let Value::Instance(inst) = &v {
                inst.borrow_mut().define(
                    "name",
                    Value::String(Rc::new(entry.name.name.clone())),
                );
                inst.borrow_mut().define("ordinal", Value::new_int(ordinal));
            }
            class
                .enum_entries
                .borrow_mut()
                .push((entry.name.name.clone(), v));
        }
        Ok(())
    }

    fn build_object_class(
        &mut self,
        o: &klio_ast::ObjectDecl,
        env: &Rc<RefCell<Env>>,
        _out: &mut dyn Output,
    ) -> Result<Rc<ClassDef>, RuntimeError> {
        let mut methods = Vec::new();
        let mut body_properties = Vec::new();
        for m in &o.members {
            match m {
                Decl::Function(f) => methods.push(MethodDef {
                    name: f.name.name.clone(),
                    decl: Rc::new(f.clone()),
                    is_operator: false,
                    is_open: f.is_open,
                    is_override: f.is_override,
                    is_abstract: f.is_abstract,
                    sam_lambda: None,
                    delegate_field: None,
                }),
                Decl::Property(p) => body_properties.push(PropertyDef {
                    name: p.name.name.clone(),
                    mutable: p.mutable,
                    init: p.init.as_ref().map(|e| Rc::new(e.clone())),
                    getter: p.getter.as_ref().map(|a| Rc::new(a.clone())),
                    setter: p.setter.as_ref().map(|a| Rc::new(a.clone())),
                    delegate: p.delegate.as_ref().map(|e| Rc::new(e.clone())),
                    is_abstract: p.is_abstract,
                    is_lateinit: p.is_lateinit,
                }),
                _ => {}
            }
        }
        Ok(Rc::new(ClassDef {
            name: o.name.name.clone(),
            fqn: self.qualify_simple_name(&o.name.name),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods,
            body_properties,
            init_blocks: Vec::new(),
            is_data: o.is_data,
            is_object: true,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            supertype_names: o.supertypes.iter().map(|t| t.name.name.clone()).collect(),
            parent: RefCell::new(None),
            interfaces: RefCell::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: o
                .supertype_args
                .iter()
                .find_map(|a| a.as_ref())
                .map(|args| args.iter().map(|e| Rc::new(e.clone())).collect())
                .unwrap_or_default(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::clone(env),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        }))
    }

    /// Eagerly construct a singleton (companion or standalone object).
    fn construct_object_singleton(
        &mut self,
        class: &Rc<ClassDef>,
        out: &mut dyn Output,
    ) -> Result<Rc<RefCell<InstanceData>>, RuntimeError> {
        let identity = self.next_instance_id();
        let inst = Rc::new(RefCell::new(InstanceData {
            class: Rc::clone(class),
            fields: Vec::new(),
            outer: None,
            identity,
            native_state: None,
        }));
        // Invoke the parent constructor when the object extends a class
        // with a primary ctor (e.g. `object Red : Color(0xff0000)`).
        if !class.parent_ctor_args.is_empty() {
            let ctor_env = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
            if let Some(parent) = class.parent.borrow().clone() {
                let mut parent_args: Vec<Value> =
                    Vec::with_capacity(class.parent_ctor_args.len());
                for e in &class.parent_ctor_args {
                    parent_args.push(self.eval_expr(e, &ctor_env, out)?);
                }
                let parent_arg_names: Vec<Option<String>> = vec![None; parent_args.len()];
                self.run_ctor_chain(&parent, &inst, &parent_args, &parent_arg_names, out)?;
            }
        }
        self.run_body_initializers(class, &inst, out)?;
        Ok(inst)
    }

    /// Construct a regular class instance from constructor args. Walks the
    /// parent chain top-down so a parent's primary ctor + init blocks run
    /// before the child's, matching Kotlin's construction order.
    fn construct_instance(
        &mut self,
        class: &Rc<ClassDef>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.construct_instance_with_outer(class, args, arg_names, None, out)
    }

    /// Public wrapper so the IR Host can construct user-class
    /// instances by name (looked up through the class table).
    pub fn construct_by_name(
        &mut self,
        class_name: &str,
        args: &[Value],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let names: Vec<Option<String>> = vec![None; args.len()];
        self.construct_by_name_with_names(class_name, args, &names, out)
    }

    /// Construct an instance honouring named args + default values.
    /// Used by the IR Host's new_instance_named callback so
    /// `Foo(y = 99)` reorders correctly against `class Foo(x: Int = 1, y: Int = 2)`.
    pub fn construct_by_name_with_names(
        &mut self,
        class_name: &str,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let class = self
            .class_table
            .get(class_name)
            .cloned()
            .ok_or_else(|| RuntimeError::Type(format!("unknown class `{class_name}`")))?;
        self.construct_instance(&class, args, arg_names, out)
    }

    fn construct_instance_with_outer(
        &mut self,
        class: &Rc<ClassDef>,
        args: &[Value],
        arg_names: &[Option<String>],
        outer: Option<Value>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if class.is_abstract {
            return Err(RuntimeError::Thrown(Value::Exception {
                fqn: Rc::new("kotlin.InstantiationError".to_string()),
                message: Some(Rc::new(format!(
                    "Cannot create an instance of an abstract class: {}",
                    class.name
                ))),
                cause: None,
            }));
        }
        if class.is_interface {
            return Err(RuntimeError::Thrown(Value::Exception {
                fqn: Rc::new("kotlin.InstantiationError".to_string()),
                message: Some(Rc::new(format!(
                    "Cannot create an instance of an interface: {}",
                    class.name
                ))),
                cause: None,
            }));
        }
        let identity = self.next_instance_id();
        let inst = Rc::new(RefCell::new(InstanceData {
            class: Rc::clone(class),
            fields: Vec::new(),
            outer,
            identity,
            native_state: None,
        }));
        // Pick primary vs secondary by arity. We match the call to a
        // secondary first only when the primary's arity doesn't already fit
        // (so `Foo()` on a class with a no-arg primary still uses primary).
        let primary_arity_fits = args.len() <= class.primary_params.len()
            && args.len() >= class
                .primary_params
                .iter()
                .filter(|p| p.default.is_none())
                .count();
        let has_primary = !class.primary_params.is_empty() || class.secondary_ctors.is_empty();
        let secondary_idx = if !primary_arity_fits || (!has_primary && args.len() > 0) {
            class
                .secondary_ctors
                .iter()
                .position(|s| s.params.len() == args.len())
        } else {
            None
        };
        if let Some(idx) = secondary_idx {
            self.run_secondary_ctor(class, &inst, idx, args, arg_names, out)?;
        } else {
            self.run_ctor_chain(class, &inst, args, arg_names, out)?;
        }
        Ok(Value::Instance(inst))
    }

    /// Run primary-ctor binding + init blocks for `class` and all of its
    /// ancestors. `args` / `arg_names` apply to the leaf class — the
    /// subclass's `: Parent(...)` clause feeds the parent's ctor.
    fn run_ctor_chain(
        &mut self,
        class: &Rc<ClassDef>,
        inst: &Rc<RefCell<InstanceData>>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        let param_names: Vec<&str> =
            class.primary_params.iter().map(|p| p.name.as_str()).collect();
        let slotted = reorder_named_args(args, arg_names, &param_names, &class.name)?;
        let ctor_env = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
        for (i, p) in class.primary_params.iter().enumerate() {
            let v = if let Some(Some(v)) = slotted.get(i) {
                v.clone()
            } else if let Some(d) = &p.default {
                self.eval_expr(d, &ctor_env, out)?
            } else {
                return Err(RuntimeError::Arity(format!(
                    "missing argument for `{}` (parameter `{}`)",
                    class.name, p.name
                )));
            };
            ctor_env.borrow_mut().define(p.name.clone(), v.clone());
            if p.property.is_some() {
                inst.borrow_mut().define(&p.name, v);
            }
        }
        // Super-constructor invocation: evaluate the parent-ctor args in this
        // class's ctor frame (so subclass params are visible), then drive the
        // parent's ctor chain into the same instance — its property bindings
        // and init blocks land on `inst` before ours do.
        if let Some(parent) = class.parent.borrow().clone() {
            let mut parent_args: Vec<Value> = Vec::with_capacity(class.parent_ctor_args.len());
            for e in &class.parent_ctor_args {
                parent_args.push(self.eval_expr(e, &ctor_env, out)?);
            }
            let parent_arg_names: Vec<Option<String>> = vec![None; parent_args.len()];
            self.run_ctor_chain(&parent, inst, &parent_args, &parent_arg_names, out)?;
        } else if !class.parent_ctor_args.is_empty() {
            // Parent is a built-in supertype (no ClassDef captured). When it
            // is a Throwable subtype, surface `message` and `cause` from the
            // parent-ctor arguments so user subclasses observe spec §3.12
            // accessors (`Throwable(message, cause)`).
            let parent_name = class.supertype_names.first().map(|s| s.as_str()).unwrap_or("");
            if is_builtin_throwable(parent_name) {
                let mut parent_args: Vec<Value> =
                    Vec::with_capacity(class.parent_ctor_args.len());
                for e in &class.parent_ctor_args {
                    parent_args.push(self.eval_expr(e, &ctor_env, out)?);
                }
                if let Some(msg) = parent_args.first() {
                    if !matches!(msg, Value::Null) {
                        inst.borrow_mut().define("message", msg.clone());
                    } else {
                        inst.borrow_mut().define("message", Value::Null);
                    }
                }
                if let Some(cause) = parent_args.get(1) {
                    inst.borrow_mut().define("cause", cause.clone());
                }
            }
        }
        // Inheritance delegation: evaluate `: I by expr` in the primary-ctor
        // frame after super-init and before body initializers so the delegate
        // is observable to init blocks but lifetimes match Kotlin's spec
        // (delegate captured once at construction).
        let delegate_descriptors = class.supertype_delegates.borrow().clone();
        for d in &delegate_descriptors {
            let v = self.eval_expr(&d.expr, &ctor_env, out)?;
            inst.borrow_mut().define(&d.field_key, v);
        }
        // After parent chain, run this class's body properties + init blocks.
        self.run_body_initializers_with_env(class, inst, &ctor_env, out)
    }

    /// Run one of a class's secondary constructors. The body executes after
    /// the delegation chain resolves to the primary constructor (which runs
    /// init blocks once). Body bodies of intermediate secondaries fire in
    /// outermost-call → innermost-delegation → ... → primary order.
    fn run_secondary_ctor(
        &mut self,
        class: &Rc<ClassDef>,
        inst: &Rc<RefCell<InstanceData>>,
        idx: usize,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        let sec = Rc::clone(&class.secondary_ctors[idx]);
        // Bind the secondary's params into a fresh ctor env.
        let param_names: Vec<&str> = sec.params.iter().map(|p| p.name.name.as_str()).collect();
        let slotted = reorder_named_args(args, arg_names, &param_names, &class.name)?;
        let ctor_env = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
        for (i, p) in sec.params.iter().enumerate() {
            let v = if let Some(Some(v)) = slotted.get(i) {
                v.clone()
            } else if let Some(d) = &p.default {
                self.eval_expr(d, &ctor_env, out)?
            } else {
                return Err(RuntimeError::Arity(format!(
                    "missing argument for `{}` (parameter `{}`)",
                    class.name, p.name.name
                )));
            };
            ctor_env.borrow_mut().define(p.name.name.clone(), v);
        }
        // Resolve delegation. Explicit `: this(args)` / `: super(args)`; if
        // the header is absent, an implicit `: this()` (or `: super()` when
        // no primary exists) is used.
        let delegation = sec.delegation.clone();
        let has_primary_or_other_secondaries =
            !class.primary_params.is_empty() || !class.secondary_ctors.is_empty();
        let _ = has_primary_or_other_secondaries;
        match delegation {
            klio_ast::CtorDelegation::This(dargs) => {
                let mut vals = Vec::with_capacity(dargs.len());
                for e in &dargs {
                    vals.push(self.eval_expr(e, &ctor_env, out)?);
                }
                let names: Vec<Option<String>> = vec![None; vals.len()];
                self.dispatch_ctor(class, inst, &vals, &names, out)?;
            }
            klio_ast::CtorDelegation::Super(dargs) => {
                // No primary on this class; bind nothing for primary,
                // evaluate super args in this secondary's frame, drive the
                // parent's ctor chain into the same instance, then run this
                // class's body initializers + init blocks once in a fresh
                // env (so body-property names can't be clobbered by — or
                // clobber — the secondary's params).
                if let Some(parent) = class.parent.borrow().clone() {
                    let mut vals = Vec::with_capacity(dargs.len());
                    for e in &dargs {
                        vals.push(self.eval_expr(e, &ctor_env, out)?);
                    }
                    let names: Vec<Option<String>> = vec![None; vals.len()];
                    self.run_ctor_chain(&parent, inst, &vals, &names, out)?;
                }
                let init_env =
                    Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
                self.run_body_initializers_with_env(class, inst, &init_env, out)?;
            }
            klio_ast::CtorDelegation::None => {
                // Implicit: `: this()` when a primary exists, else
                // `: super()`.
                if !class.primary_params.is_empty() || class.parent.borrow().is_none() {
                    // Primary with no args, or no parent — run primary path.
                    self.run_ctor_chain(class, inst, &[], &[], out)?;
                } else {
                    // No primary; implicitly delegate to super() with no args.
                    if let Some(parent) = class.parent.borrow().clone() {
                        self.run_ctor_chain(&parent, inst, &[], &[], out)?;
                    }
                    self.run_body_initializers_with_env(class, inst, &ctor_env, out)?;
                }
            }
        }
        // Finally, run the secondary's body — primary init blocks have
        // already executed. Bind `this` directly into `ctor_env` so a
        // parameter shadowing a class field works correctly: the bare-name
        // resolver compares name-depth to `this`-depth (a deeper class
        // field only wins when the lexical binding is in an enclosing
        // scope, not at the same frame as `this`).
        if let Some(body) = &sec.body {
            ctor_env
                .borrow_mut()
                .define("this", Value::Instance(Rc::clone(inst)));
            self.eval_block(body, &ctor_env, out)?;
        }
        Ok(())
    }

    /// Dispatch a `this(args)` delegation: pick another constructor on the
    /// same class by arity (primary or secondary). Drives the chain into
    /// the same instance.
    fn dispatch_ctor(
        &mut self,
        class: &Rc<ClassDef>,
        inst: &Rc<RefCell<InstanceData>>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        // If the arg count matches the primary, run the primary chain.
        if args.len() <= class.primary_params.len()
            && args.len()
                >= class
                    .primary_params
                    .iter()
                    .filter(|p| p.default.is_none())
                    .count()
            && !class.primary_params.is_empty()
        {
            return self.run_ctor_chain(class, inst, args, arg_names, out);
        }
        // Otherwise look for a matching secondary.
        if let Some(idx) = class
            .secondary_ctors
            .iter()
            .position(|s| s.params.len() == args.len())
        {
            return self.run_secondary_ctor(class, inst, idx, args, arg_names, out);
        }
        // Fall back to primary even if arity doesn't match (it will error
        // there with a clearer message).
        self.run_ctor_chain(class, inst, args, arg_names, out)
    }

    fn run_body_initializers(
        &mut self,
        class: &Rc<ClassDef>,
        inst: &Rc<RefCell<InstanceData>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        let env = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
        self.run_body_initializers_with_env(class, inst, &env, out)
    }

    fn run_body_initializers_with_env(
        &mut self,
        class: &Rc<ClassDef>,
        inst: &Rc<RefCell<InstanceData>>,
        ctor_env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        // Bind `this` so init blocks and body property initializers can refer
        // to the instance directly.
        ctor_env
            .borrow_mut()
            .define("this", Value::Instance(Rc::clone(inst)));

        // Body declarations and init blocks execute in the source-order they
        // appeared in the class body. The class AST already preserves this
        // order in `members`; init blocks are collected separately, so we
        // approximate Kotlin's "body order" by interleaving body properties
        // first then init blocks. For the program shapes in this milestone
        // (init blocks reference primary params or already-set properties)
        // this matches Kotlin's observable behavior.
        for p in &class.body_properties {
            // Abstract properties have no backing field of their own — the
            // override on the concrete subclass provides storage. Skipping
            // here also keeps a Null write from clobbering a value the
            // subclass's primary-ctor property already wrote.
            if p.is_abstract {
                continue;
            }
            if let Some(delegate_expr) = &p.delegate {
                let dval = self.eval_expr(delegate_expr, ctor_env, out)?;
                // Spec ch.9: if the delegate value's class declares
                // `operator fun provideDelegate(thisRef, property)`, call
                // it once at property-init time and store the result.
                let this_ref = Value::Instance(Rc::clone(inst));
                let dval = self.maybe_provide_delegate(dval, &this_ref, &p.name, ctor_env, out)?;
                inst.borrow_mut()
                    .define(&format!("__delegate${}", p.name), dval);
                continue;
            }
            let v = if let Some(e) = &p.init {
                self.eval_expr(e, ctor_env, out)?
            } else if p.is_lateinit {
                make_lateinit_sentinel(&p.name)
            } else if p.getter.is_some() && p.init.is_none() {
                // Pure custom-getter property — no backing field needed.
                // We still emit a Null slot so writes inside a custom
                // setter that target `field` find a home.
                Value::Null
            } else {
                Value::Null
            };
            inst.borrow_mut().define(&p.name, v.clone());
            ctor_env.borrow_mut().define(p.name.clone(), v);
        }
        for b in &class.init_blocks {
            self.eval_block(b, ctor_env, out)?;
        }
        Ok(())
    }

    /// Read a top-level property, honoring delegate / custom getter
    /// dispatch. Plain properties just fall through to the env.
    fn read_top_level_property(
        &mut self,
        pdef: &PropertyDef,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if pdef.delegate.is_some() {
            let key = format!("__delegate${}", pdef.name);
            let dval = env
                .borrow()
                .lookup(&key)
                .ok_or_else(|| RuntimeError::Unbound(key.clone()))?;
            let owner = Value::Null;
            let prop = Value::PropertyRef { name: Rc::new(pdef.name.clone()) };
            return self.call_delegate_get(&dval, &owner, &prop, env, out);
        }
        if let Some(getter) = &pdef.getter {
            let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
            // `field` reads the backing slot if one exists.
            if let Some(v) = env.borrow().lookup(&pdef.name) {
                frame.borrow_mut().define("field", v);
            }
            return self.eval_accessor_body(getter, &frame, out);
        }
        let v = env
            .borrow()
            .lookup(&pdef.name)
            .ok_or_else(|| RuntimeError::Unbound(pdef.name.clone()))?;
        if let Some(name) = lateinit_sentinel_name(&v) {
            return Err(lateinit_throw(&name));
        }
        Ok(v)
    }

    /// Write a top-level property, dispatching to a delegate's
    /// `setValue` or to a custom setter. Plain `var` falls through to
    /// the env.
    fn write_top_level_property(
        &mut self,
        pdef: &PropertyDef,
        new_value: Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        if pdef.delegate.is_some() {
            let key = format!("__delegate${}", pdef.name);
            let dval = env
                .borrow()
                .lookup(&key)
                .ok_or_else(|| RuntimeError::Unbound(key.clone()))?;
            let owner = Value::Null;
            let prop = Value::PropertyRef { name: Rc::new(pdef.name.clone()) };
            self.call_delegate_set(&dval, &owner, &prop, new_value, env, out)?;
            return Ok(());
        }
        if let Some(setter) = &pdef.setter {
            let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(env))));
            let param_name = setter
                .params
                .first()
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "value".to_string());
            frame.borrow_mut().define(param_name, new_value.clone());
            if let Some(v) = env.borrow().lookup(&pdef.name) {
                frame.borrow_mut().define("field", v);
            }
            self.eval_accessor_body(setter, &frame, out)?;
            // Propagate any write to `field` inside the setter back to
            // the backing slot.
            if let Some(updated) = frame.borrow().lookup("field") {
                let _ = env.borrow_mut().assign(&pdef.name, updated);
            }
            return Ok(());
        }
        env.borrow_mut().assign(&pdef.name, new_value)
    }

    fn read_instance_property(
        &mut self,
        inst: &Rc<RefCell<InstanceData>>,
        pdef: &PropertyDef,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if pdef.delegate.is_some() {
            let key = format!("__delegate${}", pdef.name);
            let dval = inst
                .borrow()
                .get(&key)
                .ok_or_else(|| RuntimeError::Unbound(key.clone()))?;
            let owner = Value::Instance(Rc::clone(inst));
            let prop = Value::PropertyRef { name: Rc::new(pdef.name.clone()) };
            let env = Rc::clone(&inst.borrow().class.captured_env);
            return self.call_delegate_get(&dval, &owner, &prop, &env, out);
        }
        if let Some(getter) = &pdef.getter {
            let class = Rc::clone(&inst.borrow().class);
            let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
            frame
                .borrow_mut()
                .define("this", Value::Instance(Rc::clone(inst)));
            for (n, v) in inst.borrow().fields.iter() {
                frame.borrow_mut().define(n.clone(), v.clone());
            }
            if let Some(v) = inst.borrow().get(&pdef.name) {
                frame.borrow_mut().define("field", v);
            }
            return self.eval_accessor_body(getter, &frame, out);
        }
        let v = inst
            .borrow()
            .get(&pdef.name)
            .ok_or_else(|| RuntimeError::Unbound(pdef.name.clone()))?;
        if let Some(name) = lateinit_sentinel_name(&v) {
            return Err(lateinit_throw(&name));
        }
        Ok(v)
    }

    fn write_instance_property(
        &mut self,
        inst: &Rc<RefCell<InstanceData>>,
        pdef: &PropertyDef,
        new_value: Value,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        if pdef.delegate.is_some() {
            let key = format!("__delegate${}", pdef.name);
            let dval = inst
                .borrow()
                .get(&key)
                .ok_or_else(|| RuntimeError::Unbound(key.clone()))?;
            let owner = Value::Instance(Rc::clone(inst));
            let prop = Value::PropertyRef { name: Rc::new(pdef.name.clone()) };
            let env = Rc::clone(&inst.borrow().class.captured_env);
            self.call_delegate_set(&dval, &owner, &prop, new_value, &env, out)?;
            return Ok(());
        }
        if let Some(setter) = &pdef.setter {
            let class = Rc::clone(&inst.borrow().class);
            let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&class.captured_env))));
            frame
                .borrow_mut()
                .define("this", Value::Instance(Rc::clone(inst)));
            for (n, v) in inst.borrow().fields.iter() {
                frame.borrow_mut().define(n.clone(), v.clone());
            }
            let param_name = setter
                .params
                .first()
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "value".to_string());
            frame.borrow_mut().define(param_name, new_value.clone());
            if let Some(v) = inst.borrow().get(&pdef.name) {
                frame.borrow_mut().define("field", v);
            }
            self.eval_accessor_body(setter, &frame, out)?;
            if let Some(updated) = frame.borrow().lookup("field") {
                inst.borrow_mut().define(&pdef.name, updated);
            }
            return Ok(());
        }
        inst.borrow_mut().define(&pdef.name, new_value);
        Ok(())
    }

    fn eval_accessor_body(
        &mut self,
        acc: &klio_ast::Accessor,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let r = match &acc.body {
            FunctionBody::Block(b) => self.eval_block(b, env, out),
            FunctionBody::Expr(e) => self.eval_expr(e, env, out),
        };
        match r {
            Ok(v) => Ok(v),
            Err(RuntimeError::Return(v)) => Ok(v),
            Err(e) => Err(e),
        }
    }

    /// Dispatch `delegate.getValue(thisRef, prop)` on either a built-in
    /// delegate value or a user-supplied delegate object.
    fn call_delegate_get(
        &mut self,
        delegate: &Value,
        owner: &Value,
        prop: &Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if let Value::Delegate(d) = delegate {
            return self.call_builtin_delegate_get(d, prop, env, out);
        }
        if let Value::Instance(inst) = delegate {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method("getValue") {
                return self.call_method(inst, &m, &[owner.clone(), prop.clone()], &[], out);
            }
        }
        let _ = env;
        if let Some(v) = self.try_extension_call_with_values(
            delegate,
            "getValue",
            &[owner.clone(), prop.clone()],
            out,
        )? {
            return Ok(v);
        }
        Err(RuntimeError::Type(
            "property delegate has no `getValue` method".into(),
        ))
    }

    fn call_delegate_set(
        &mut self,
        delegate: &Value,
        owner: &Value,
        prop: &Value,
        new_value: Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        if let Value::Delegate(d) = delegate {
            return self.call_builtin_delegate_set(d, prop, new_value, env, out);
        }
        if let Value::Instance(inst) = delegate {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method("setValue") {
                self.call_method(
                    inst,
                    &m,
                    &[owner.clone(), prop.clone(), new_value],
                    &[],
                    out,
                )?;
                return Ok(());
            }
        }
        let _ = env;
        if self
            .try_extension_call_with_values(
                delegate,
                "setValue",
                &[owner.clone(), prop.clone(), new_value],
                out,
            )?
            .is_some()
        {
            return Ok(());
        }
        Err(RuntimeError::Type(
            "property delegate has no `setValue` method".into(),
        ))
    }

    fn call_builtin_delegate_get(
        &mut self,
        d: &Rc<RefCell<klio_runtime::DelegateKind>>,
        prop: &Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let snapshot = d.borrow().clone();
        match snapshot {
            klio_runtime::DelegateKind::Lazy { producer, cached } => {
                if let Some(v) = cached {
                    return Ok(v);
                }
                let v = self.call_value_no_args(&producer, env, out)?;
                *d.borrow_mut() = klio_runtime::DelegateKind::Lazy {
                    producer,
                    cached: Some(v.clone()),
                };
                Ok(v)
            }
            klio_runtime::DelegateKind::Observable { value, .. } => Ok(value),
            klio_runtime::DelegateKind::NotNull { value, .. } => match value {
                Some(v) => Ok(v),
                None => {
                    let pname = if let Value::PropertyRef { name } = prop {
                        (**name).clone()
                    } else {
                        "?".to_string()
                    };
                    Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.IllegalStateException".to_string()),
                        message: Some(Rc::new(format!(
                            "Property {pname} should be initialized before get."
                        ))),
                        cause: None,
                    }))
                }
            },
        }
    }

    fn call_builtin_delegate_set(
        &mut self,
        d: &Rc<RefCell<klio_runtime::DelegateKind>>,
        prop: &Value,
        new_value: Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        let snapshot = d.borrow().clone();
        match snapshot {
            klio_runtime::DelegateKind::Lazy { .. } => Err(RuntimeError::Type(
                "cannot assign to a `val` property delegated by `lazy`".into(),
            )),
            klio_runtime::DelegateKind::Observable { value: old, on_change } => {
                *d.borrow_mut() = klio_runtime::DelegateKind::Observable {
                    value: new_value.clone(),
                    on_change: on_change.clone(),
                };
                self.call_value_with_args(
                    &on_change,
                    &[prop.clone(), old, new_value],
                    env,
                    out,
                )?;
                Ok(())
            }
            klio_runtime::DelegateKind::NotNull { name, .. } => {
                *d.borrow_mut() = klio_runtime::DelegateKind::NotNull {
                    value: Some(new_value),
                    name,
                };
                Ok(())
            }
        }
    }

    fn eval_delegates_member(
        &mut self,
        member: &str,
        args: &[Expr],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match member {
            "observable" => {
                if args.len() != 2 {
                    return Err(RuntimeError::Arity(
                        "Delegates.observable expects (initial, onChange)".into(),
                    ));
                }
                let initial = self.eval_expr(&args[0], env, out)?;
                let on_change = self.eval_expr(&args[1], env, out)?;
                Ok(Value::Delegate(Rc::new(RefCell::new(
                    klio_runtime::DelegateKind::Observable {
                        value: initial,
                        on_change,
                    },
                ))))
            }
            "notNull" => {
                if !args.is_empty() {
                    return Err(RuntimeError::Arity(
                        "Delegates.notNull takes no arguments".into(),
                    ));
                }
                Ok(Value::Delegate(Rc::new(RefCell::new(
                    klio_runtime::DelegateKind::NotNull {
                        value: None,
                        name: String::new(),
                    },
                ))))
            }
            other => Err(RuntimeError::Unimplemented(format!("Delegates.{other}"))),
        }
    }

    /// Invoke a `Value` (Function or Lambda) with no arguments.
    fn call_value_no_args(
        &mut self,
        callee: &Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        self.call_value_with_args(callee, &[], env, out)
    }

    fn call_value_with_args(
        &mut self,
        callee: &Value,
        args: &[Value],
        _env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match callee {
            Value::Function { decl, env } => {
                self.call_function(decl, env, args, out)
            }
            Value::Lambda { params, body, env, absorb_return } => {
                self.call_lambda_with_this(params, body, env, args, None, *absorb_return, out)
            }
            Value::Intrinsic { func, .. } => {
                let mut ctx = CallCtx { args, out };
                func(&mut ctx)
            }
            Value::BoundMethod { func, receiver, .. } => {
                let mut all = Vec::with_capacity(args.len() + 1);
                all.push((**receiver).clone());
                all.extend_from_slice(args);
                let mut ctx = CallCtx { args: &all, out };
                func(&mut ctx)
            }
            Value::BoundUserMethod { receiver, method } => {
                let arg_names: Vec<Option<String>> = vec![None; args.len()];
                self.call_method(receiver, method, args, &arg_names, out)
            }
            other => Err(RuntimeError::Type(format!(
                "cannot invoke non-callable delegate component: {other:?}"
            ))),
        }
    }

    /// Invoke a user method on an instance. The frame env binds `this` and
    /// each primary-ctor property + body property by name, so member bodies
    /// can reference `x` instead of `this.x`.
    fn call_method(
        &mut self,
        recv: &Rc<RefCell<InstanceData>>,
        method: &MethodDef,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        // The owning class is the leaf instance's class — most-derived
        // resolution finds whichever override wins, so `super` always
        // resolves against that override's parent. Caller can swap in a
        // different owner via `call_method_with_owner`.
        let owner = Rc::clone(&recv.borrow().class);
        self.call_method_with_owner(recv, &owner, method, args, arg_names, out)
    }

    /// Invoke a method with an explicit "owner class" — the class whose
    /// `parent` is treated as `super` inside the method body. Used by
    /// `super.method()` dispatch to step exactly one level up the chain.
    fn call_method_with_owner(
        &mut self,
        recv: &Rc<RefCell<InstanceData>>,
        owner: &Rc<ClassDef>,
        method: &MethodDef,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let leaf_class = Rc::clone(&recv.borrow().class);
        let method_env =
            Rc::new(RefCell::new(Env::with_parent(Rc::clone(&leaf_class.captured_env))));
        method_env
            .borrow_mut()
            .define("this", Value::Instance(Rc::clone(recv)));
        // Bind a synthetic marker so `super.foo` resolution inside the body
        // can find the owner class and step to its parent. Stored as a
        // `Value::Class` so env lookups give it back uniformly.
        method_env
            .borrow_mut()
            .define("__owner_class__", Value::Class(Rc::clone(owner)));
        // Note: primary-ctor / body property fields on `this` are NOT
        // pre-bound into the frame env. Bare-name reads inside the method
        // resolve through the live instance via `Expr::Path` /
        // `lookup_with_this` so that values written after frame entry
        // (`super.bump()` mutating `count`, etc.) are observed.
        // The only field-shaped slots we lift are non-public internals
        // (e.g. `__delegate$X`) — left out as well, since delegate reads go
        // through `read_instance_property` rather than the env.
        // Qualified-this bindings: bind `this@<ClassName>` for the receiver's
        // own class (and every ancestor class name in its hierarchy), then
        // walk the `outer` chain (for inner / local classes nested inside
        // another class) and do the same for each outer instance. Field
        // values are read live through the `outer` chain in the bare-name
        // lookup path, so a frame-local snapshot would diverge from
        // `this@Outer.count` writes inside an inner-class body.
        bind_qualified_this(&method_env, recv);
        let mut cur_outer = recv.borrow().outer.clone();
        while let Some(Value::Instance(oi)) = cur_outer {
            bind_qualified_this(&method_env, &oi);
            cur_outer = oi.borrow().outer.clone();
        }
        // Bind nested-class names so an unqualified `Inner()` inside an
        // outer-class method captures `this` as the outer. We bind inner
        // classes as `BoundInnerClass` with the current receiver; plain
        // nested classes get bound as `Value::Class`.
        for (n, nc) in owner.nested_classes.borrow().iter() {
            if method_env.borrow().lookup(n).is_some() {
                continue;
            }
            let val = if nc.is_inner {
                Value::BoundInnerClass {
                    class: Rc::clone(nc),
                    outer: Rc::clone(recv),
                }
            } else {
                Value::Class(Rc::clone(nc))
            };
            method_env.borrow_mut().define(n.clone(), val);
        }
        if let Some(lam) = method.sam_lambda.clone() {
            if let Value::Lambda { params, body, env: captured, .. } = lam {
                return self.call_lambda(&params, &body, &captured, args, out);
            }
        }
        // Inheritance-delegation forwarder: route the call to the delegate
        // stored on the receiver. Method dispatch happens through normal
        // resolution on the delegate's runtime class, so an explicit body
        // override on the implementing class wins (it would have masked
        // the forwarder in `find_method_walk`).
        if let Some(field_key) = &method.delegate_field {
            let delegate_val = recv
                .borrow()
                .get(field_key)
                .ok_or_else(|| RuntimeError::Unbound(field_key.clone()))?;
            return self.invoke_delegate(&delegate_val, &method.name, args, arg_names, out);
        }
        self.call_function_named(&method.decl, &method_env, args, arg_names, out)
    }

    /// Dispatch a delegated method onto the delegate value. The delegate is
    /// usually a `Value::Instance`; we forward through normal method
    /// resolution so the delegate's own overrides (including chained
    /// delegation) compose naturally.
    fn invoke_delegate(
        &mut self,
        delegate: &Value,
        name: &str,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if let Value::Instance(inst) = delegate {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(name) {
                return self.call_method(inst, &m, args, arg_names, out);
            }
            // Property access surfaced as a zero-arg call (interface
            // property getters synthesized as `fun get<Name>()` in this
            // runtime would already have matched above). Fall back to
            // direct field read so a property-shaped member reaches its
            // backing value.
            if args.is_empty() {
                if let Some(v) = inst.borrow().get(name) {
                    return Ok(v);
                }
            }
        }
        Err(RuntimeError::Unimplemented(format!(
            "delegate.{name}: not callable on delegate value"
        )))
    }

    /// Build a synthetic instance that satisfies a `fun interface` via a
    /// SAM lambda. Walks the interface's method table to find the single
    /// abstract method, then builds a subclass whose only difference is
    /// that the abstract slot is filled by a `MethodDef` whose
    /// `sam_lambda` carries the user's lambda.
    /// Spec §4.1.6: implicit lambda → fun-interface conversion at an
    /// argument site. If `param_ty_name` resolves to a `fun interface`
    /// class in scope and `value` is a `Value::Lambda`, lift it via
    /// `sam_construct`. Otherwise return `value` unchanged.
    fn maybe_sam_coerce(
        &mut self,
        value: Value,
        param_ty_name: Option<&str>,
        scope_env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if !matches!(value, Value::Lambda { .. }) {
            return Ok(value);
        }
        let Some(name) = param_ty_name else { return Ok(value) };
        let looked = scope_env
            .borrow()
            .lookup(name)
            .or_else(|| self.globals.borrow().lookup(name));
        if let Some(Value::Class(cls)) = looked {
            if cls.is_fun_interface {
                return self.sam_construct(&cls, value, out);
            }
        }
        Ok(value)
    }

    fn sam_construct(
        &mut self,
        iface: &Rc<ClassDef>,
        lambda: Value,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        // Find the single abstract method on the interface.
        let mut sam: Option<MethodDef> = None;
        for m in &iface.methods {
            let has_body = m.decl.body.is_some();
            if !has_body {
                if sam.is_some() {
                    return Err(RuntimeError::Type(format!(
                        "fun interface `{}` must declare exactly one abstract method",
                        iface.name
                    )));
                }
                sam = Some(m.clone());
            }
        }
        let Some(sam) = sam else {
            return Err(RuntimeError::Type(format!(
                "fun interface `{}` has no abstract method to satisfy",
                iface.name
            )));
        };
        // If the lambda was written without an explicit header (no `->`)
        // and the SAM has exactly one parameter, inject `it` as the lone
        // parameter so the body's `it` reference resolves.
        let lambda = if let Value::Lambda { params, body, env, absorb_return } = lambda {
            if params.is_empty() && sam.decl.params.len() == 1 {
                Value::Lambda { params: Rc::new(vec!["it".into()]), body, env, absorb_return }
            } else {
                Value::Lambda { params, body, env, absorb_return }
            }
        } else {
            lambda
        };
        let mut methods = iface.methods.clone();
        for m in &mut methods {
            if m.name == sam.name {
                m.sam_lambda = Some(lambda.clone());
                m.is_abstract = false;
            }
        }
        let synth = Rc::new(ClassDef {
            name: iface.name.clone(),
            fqn: iface.fqn.clone(),
            annotation_names: iface.annotation_names.clone(),
            primary_params: Vec::new(),
            methods,
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            is_data: false,
            is_object: false,
            is_enum: false,
            is_sealed: false,
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: true,
            secondary_ctors: Vec::new(),
            supertype_names: vec![iface.name.clone()],
            parent: RefCell::new(None),
            interfaces: RefCell::new(vec![Rc::clone(iface)]),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            enum_entries: RefCell::new(Vec::new()),
            companion: RefCell::new(None),
            enclosing_class: RefCell::new(None),
            nested_classes: RefCell::new(Vec::new()),
            captured_env: Rc::clone(&iface.captured_env),
            supertype_delegates: RefCell::new(Vec::new()),
            delegate_forwarders: RefCell::new(Vec::new()),
            object_singleton: RefCell::new(None),
        });
        let identity = self.next_instance_id();
        let inst = Rc::new(RefCell::new(InstanceData {
            class: synth,
            fields: Vec::new(),
            outer: None,
            identity,
            native_state: None,
        }));
        let _ = out;
        Ok(Value::Instance(inst))
    }

    /// Resolve `Receiver::name` — class literals (`Foo::class`), member
    /// references (`Foo::method`, `instance::method`), and the existing
    /// property-ref form. Tightly minimal — enough for the patterns
    /// `KClass.simpleName`, `KFunction.call`, and `KProperty1.get` to
    /// work in user code.
    fn eval_member_ref(&mut self, recv: &Value, name: &str) -> Result<Value, RuntimeError> {
        // `Foo::class` / `instance::class` — produce a `Value::Class` (our
        // KClass surface).
        if name == "class" {
            return match recv {
                Value::Class(c) => Ok(Value::Class(Rc::clone(c))),
                Value::Instance(i) => Ok(Value::Class(Rc::clone(&i.borrow().class))),
                _ => Err(RuntimeError::Type(
                    "`::class` requires a class or instance receiver".into(),
                )),
            };
        }
        // `Foo::method` — bind a callable. For now we look the method up on
        // the class's method table and produce a `Value::Function` from its
        // declaration; the user-side surface (`.call(receiver, …)`) is
        // handled by `Function.call` dispatch which already exists.
        if let Value::Class(c) = recv {
            if let Some((m, _)) = c.find_method(name) {
                return Ok(Value::Function {
                    decl: Rc::clone(&m.decl),
                    env: Rc::clone(&c.captured_env),
                });
            }
            // `Foo::propertyName` — produce a lightweight `KProperty1` whose
            // `.get(receiver)` reads the named field off the instance.
            let is_property = c
                .primary_params
                .iter()
                .any(|p| p.name == name && p.property.is_some())
                || c.body_properties.iter().any(|p| p.name == name)
                || c.find_body_property(name).is_some();
            if is_property {
                return Ok(Value::PropertyRef { name: Rc::new(name.to_string()) });
            }
            // `String::uppercase` etc. — primitive / stdlib class member
            // references. Bind to the corresponding stdlib intrinsic so
            // `xs.map(String::uppercase)` dispatches at call time.
            let fqn = format!("{}.{}", c.fqn, name);
            if let Some(func) = self.lookup_intrinsic(&fqn) {
                let fqn_static: &'static str = leak_fqn(&fqn);
                return Ok(Value::Intrinsic { fqn: fqn_static, func });
            }
        }
        // `instance::method` — produce a `Value::BoundUserMethod` that the
        // call-dispatch path invokes through `call_method` with the captured
        // receiver. Falls back to a `Value::PropertyRef` when the name
        // resolves as a property (data-class property, body property, etc.).
        if let Value::Instance(inst) = recv {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(name) {
                return Ok(Value::BoundUserMethod {
                    receiver: Rc::clone(inst),
                    method: Rc::new(m),
                });
            }
            let is_property = class
                .primary_params
                .iter()
                .any(|p| p.name == name && p.property.is_some())
                || class.body_properties.iter().any(|p| p.name == name)
                || class.find_body_property(name).is_some();
            if is_property {
                return Ok(Value::PropertyRef { name: Rc::new(name.to_string()) });
            }
        }
        Err(RuntimeError::Type(format!("unresolved callable reference `::{name}`")))
    }

    /// Auto-generated `toString` / `equals` / `hashCode` / `componentN` /
    /// `copy` on instances. Returns `Ok(None)` to fall through.
    fn eval_instance_auto_member(
        &mut self,
        recv: &Rc<RefCell<InstanceData>>,
        name: &str,
        args: &[Expr],
        arg_names: &[Option<String>],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let class = Rc::clone(&recv.borrow().class);
        match name {
            "toString" if args.is_empty() => {
                // For data, enum, object, and plain classes alike, defer to
                // the `Display` impl on `Value::Instance` — that's where the
                // `Foo@<hex>` form for plain classes is centralized.
                let s = format!("{}", Value::Instance(Rc::clone(recv)));
                Ok(Some(Value::String(Rc::new(s))))
            }
            "hashCode" if args.is_empty() => {
                // Cheap structural hash for data classes; identity-ish for
                // plain classes (we don't expose pointer addresses, so use
                // a zero — matches no kotlinc output we currently inspect).
                if class.is_data {
                    let mut h: i64 = 0;
                    for p in &class.primary_params {
                        let v = recv.borrow().get(&p.name).unwrap_or(Value::Null);
                        h = h.wrapping_mul(31).wrapping_add(value_hash(&v));
                    }
                    Ok(Some(Value::new_int(h)))
                } else {
                    // Plain-class default: identity-based, matching the
                    // `Foo@<hex>` toString. Truncated from u64 to i32.
                    let id = recv.borrow().identity;
                    Ok(Some(Value::Int(id as i32)))
                }
            }
            "equals" if args.len() == 1 => {
                let other = self.eval_expr(&args[0], env, out)?;
                let me = Value::Instance(Rc::clone(recv));
                Ok(Some(Value::Bool(Value::structural_eq(&me, &other))))
            }
            "clone" if args.is_empty() && class.is_enum => {
                // Spec §3.9: enum entries cannot be cloned. The synthesized
                // `protected final fun clone(): Any` throws.
                Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.CloneNotSupportedException".into()),
                    message: Some(Rc::new(format!(
                        "Enum entry of `{}` cannot be cloned",
                        class.name
                    ))),
                    cause: None,
                }))
            }
            "copy" if class.is_data && !class.is_object => {
                let mut arg_vals = Vec::with_capacity(args.len());
                for a in args {
                    arg_vals.push(self.eval_expr(a, env, out)?);
                }
                Ok(Some(self.data_class_copy(recv, &arg_vals, arg_names, out)?))
            }
            _ if class.is_data && !class.is_object && name.starts_with("component") && args.is_empty() => {
                let idx: usize = name["component".len()..].parse().unwrap_or(0);
                if idx == 0 || idx > class.primary_params.len() {
                    return Ok(None);
                }
                let p = &class.primary_params[idx - 1];
                Ok(recv.borrow().get(&p.name).map(Some).unwrap_or(None))
            }
            _ => Ok(None),
        }
    }

    fn insertion_sort_values(
        &mut self,
        items: &mut Vec<Value>,
        descending: bool,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        for i in 1..items.len() {
            let mut j = i;
            while j > 0 {
                let mut ord = self.compare_with_user(&items[j - 1], &items[j], out)?;
                if descending { ord = ord.reverse(); }
                if matches!(ord, std::cmp::Ordering::Greater) {
                    items.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
        Ok(())
    }

    fn insertion_sort_keyed(
        &mut self,
        keyed: &mut Vec<(Value, Value)>,
        descending: bool,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        for i in 1..keyed.len() {
            let mut j = i;
            while j > 0 {
                let mut ord = self.compare_with_user(&keyed[j - 1].0, &keyed[j].0, out)?;
                if descending { ord = ord.reverse(); }
                if matches!(ord, std::cmp::Ordering::Greater) {
                    keyed.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
        Ok(())
    }

    /// Render a value to a string, dispatching the user's `toString()` for
    /// `Value::Instance` when the class defines one.
    fn format_value(&mut self, v: &Value, out: &mut dyn Output) -> Result<String, RuntimeError> {
        if let Value::Instance(inst) = v {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _o)) = class.find_method("toString").filter(|(m, _)| m.decl.body.is_some()) {
                let r = self.call_method(inst, &m, &[], &[], out)?;
                if let Value::String(s) = r {
                    return Ok((*s).clone());
                }
                return Ok(format!("{r}"));
            }
            if class.is_enum {
                // Default enum `toString` is the entry name.
                if let Some(Value::String(s)) = inst.borrow().get("name") {
                    return Ok((*s).clone());
                }
            }
            if !class.is_data {
                return Ok(class.name.clone());
            }
        }
        Ok(format!("{v}"))
    }

    /// Compare two values, dispatching user-defined `operator fun compareTo`
    /// when either operand is a `Value::Instance` whose class defines one.
    /// Otherwise falls back to the stdlib's natural-order comparator.
    fn compare_with_user(
        &mut self,
        a: &Value,
        b: &Value,
        out: &mut dyn Output,
    ) -> Result<std::cmp::Ordering, RuntimeError> {
        // Enum entries compare by ordinal — match Kotlin's `Enum.compareTo`.
        if let (Value::Instance(ai), Value::Instance(bi)) = (a, b) {
            let (ac, bc) = (Rc::clone(&ai.borrow().class), Rc::clone(&bi.borrow().class));
            if ac.is_enum && bc.is_enum && ac.fqn == bc.fqn {
                let ao = ai.borrow().get("ordinal").unwrap_or(Value::Int(0));
                let bo = bi.borrow().get("ordinal").unwrap_or(Value::Int(0));
                if let (Value::Int(x), Value::Int(y)) = (ao, bo) {
                    return Ok(x.cmp(&y));
                }
            }
        }
        if let Value::Instance(inst) = a {
            if let Some(n) = self.try_instance_compare_to(inst, b, out)? {
                return Ok(n.cmp(&0));
            }
        }
        if let Value::Instance(inst) = b {
            if let Some(n) = self.try_instance_compare_to(inst, a, out)? {
                return Ok(0.cmp(&n));
            }
        }
        klio_stdlib::compare_values(a, b)
    }

    /// Resolve an instance's `compareTo` method, evaluating it against
    /// `other`. Returns the `Int` result if the user defined `compareTo`;
    /// `None` if the class has no such method.
    fn try_instance_compare_to(
        &mut self,
        a: &Rc<RefCell<InstanceData>>,
        b: &Value,
        out: &mut dyn Output,
    ) -> Result<Option<i64>, RuntimeError> {
        let class = Rc::clone(&a.borrow().class);
        if let Some((m, _o)) = class.find_method("compareTo") {
            let v = self.call_method(a, &m, std::slice::from_ref(b), &[], out)?;
            return match v.as_i64() {
                Some(n) => Ok(Some(n)),
                None => Err(RuntimeError::Type(format!(
                    "compareTo must return Int, got {v:?}"
                ))),
            };
        }
        // Spec ch.9: extension `operator fun T.compareTo(other)` is also a
        // valid binding for `<` / `<=` / `>` / `>=` dispatch.
        let recv = Value::Instance(Rc::clone(a));
        if let Some(v) = self.try_extension_call_with_values(&recv, "compareTo", &[b.clone()], out)? {
            return match v.as_i64() {
                Some(n) => Ok(Some(n)),
                None => Err(RuntimeError::Type(format!(
                    "compareTo must return Int, got {v:?}"
                ))),
            };
        }
        Ok(None)
    }

    /// `copy(name = value, …)` for data classes: clone the existing primary
    /// fields, then apply each named override before re-running construction.
    fn data_class_copy(
        &mut self,
        recv: &Rc<RefCell<InstanceData>>,
        args: &[Value],
        arg_names: &[Option<String>],
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let class = Rc::clone(&recv.borrow().class);
        let inst = recv.borrow();
        let mut ctor_args: Vec<Value> = Vec::with_capacity(class.primary_params.len());
        let mut ctor_names: Vec<Option<String>> = Vec::with_capacity(class.primary_params.len());
        for p in &class.primary_params {
            let mut chosen: Option<Value> = None;
            for (i, n) in arg_names.iter().enumerate() {
                if let Some(label) = n {
                    if label == &p.name {
                        chosen = Some(args[i].clone());
                    }
                }
            }
            let v = chosen.unwrap_or_else(|| inst.get(&p.name).unwrap_or(Value::Null));
            ctor_args.push(v);
            ctor_names.push(Some(p.name.clone()));
        }
        drop(inst);
        self.construct_instance(&class, &ctor_args, &ctor_names, out)
    }

    fn eval_path(
        &mut self,
        segments: &[klio_ast::Ident],
        env: &Rc<RefCell<Env>>,
    ) -> Result<Value, RuntimeError> {
        if segments.is_empty() {
            return Err(RuntimeError::Type("empty path".into()));
        }
        // Single-segment: env lookup first. Spec §10.1: a renaming import
        // shadows the original simple name in this file when the only
        // binding for it would have come from the implicit prelude. A local
        // val / function / class with the same name is unaffected.
        if segments.len() == 1 {
            let name = &segments[0].name;
            if let Some(alias) = self.import_renames.get(name) {
                if let Some(v) = env.borrow().lookup_excluding(name, &self.globals) {
                    return Ok(v);
                }
                return Err(RuntimeError::Unbound(format!(
                    "{name} (renamed to `{alias}` by an import in this file)"
                )));
            }
            return env
                .borrow()
                .lookup(name)
                .ok_or_else(|| RuntimeError::Unbound(name.clone()));
        }
        // Primitive companion-object constants: `Int.MAX_VALUE`,
        // `Double.NaN`, `Long.MIN_VALUE`, etc.
        if segments.len() == 2 {
            if let Some(v) = primitive_companion_const(&segments[0].name, &segments[1].name) {
                return Ok(v);
            }
        }
        // Multi-segment: treat as a fully qualified stdlib reference.
        let fqn = segments
            .iter()
            .map(|s| s.name.as_str())
            .collect::<Vec<_>>()
            .join(".");
        if let Some(func) = self.lookup_intrinsic(&fqn) {
            // Interned static lifetime needed for Intrinsic::fqn — keep our copy.
            let fqn_static: &'static str = leak_fqn(&fqn);
            return Ok(Value::Intrinsic { fqn: fqn_static, func });
        }
        Err(RuntimeError::Unbound(fqn))
    }

    pub fn eval_property_access(
        &mut self,
        receiver: Value,
        name: &str,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if let Value::Array { items, .. } = &receiver {
            match name {
                "size" => return Ok(Value::new_int(items.borrow().len())),
                "lastIndex" => return Ok(Value::new_int(items.borrow().len() as i64 - 1)),
                "indices" => {
                    let n = items.borrow().len() as i64;
                    return Ok(Value::Range { start: 0, end: n - 1, step: 1, kind: klio_runtime::RangeKind::Int });
                }
                _ => {}
            }
        }
        if let Value::PropertyRef { name: pname } = &receiver {
            if name == "name" {
                return Ok(Value::String(Rc::clone(pname)));
            }
        }
        if let Value::Function { decl, .. } = &receiver {
            if name == "name" {
                return Ok(Value::String(Rc::new(decl.name.name.clone())));
            }
            if name == "parameters" {
                // KFunction.parameters: a `List<KParameter>` reported
                // here as a list of `Value::PropertyRef` carrying the
                // declared parameter names. The lightweight shape
                // satisfies `.size` / `.map { it.name }` use cases
                // common in user code; receiver / type details are not
                // synthesised.
                let items: Vec<Value> = decl
                    .params
                    .iter()
                    .map(|p| Value::PropertyRef { name: Rc::new(p.name.name.clone()) })
                    .collect();
                return Ok(Value::List {
                    items: Rc::new(RefCell::new(items)),
                    mutable: false,
                    enum_class: None,
                });
            }
        }
        if let Value::Class(c) = &receiver {
            match name {
                "simpleName" => return Ok(Value::String(Rc::new(c.name.clone()))),
                "qualifiedName" => return Ok(Value::String(Rc::new(c.fqn.clone()))),
                "starProjectedType" | "createType" => {
                    // KClass.starProjectedType: a lightweight `KType`
                    // surface. Modelled as a String of the form
                    // `<simple-name>` so user code that calls
                    // `.toString()` / `.classifier` on it reads the
                    // class name.
                    return Ok(Value::String(Rc::new(c.name.clone())));
                }
                "isData" => return Ok(Value::Bool(c.is_data)),
                "isAbstract" => return Ok(Value::Bool(c.is_abstract)),
                "isSealed" => return Ok(Value::Bool(c.is_sealed)),
                "isCompanion" => return Ok(Value::Bool(false)),
                "objectInstance" => {
                    // For `object` singletons, the class table can produce
                    // the live instance. Plain classes return null.
                    return Ok(Value::Null);
                }
                "parameters" => {
                    // KFunction.parameters for the primary-constructor
                    // surface — when the class value is being treated
                    // as a `KFunction<T>`, the parameter list comes
                    // from the primary ctor's declared params.
                    let items: Vec<Value> = c
                        .primary_params
                        .iter()
                        .map(|p| Value::PropertyRef { name: Rc::new(p.name.clone()) })
                        .collect();
                    return Ok(Value::List {
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                "memberFunctions" | "declaredMemberFunctions" => {
                    // KClass.memberFunctions: a `Collection<KFunction<*>>`
                    // surfaced as a List of `Value::Function` bound to
                    // each declared method's decl. The Any.toString /
                    // equals / hashCode autos are omitted; only the
                    // user-declared methods are reported.
                    let items: Vec<Value> = c
                        .methods
                        .iter()
                        .map(|m| Value::Function {
                            decl: Rc::clone(&m.decl),
                            env: Rc::clone(&c.captured_env),
                        })
                        .collect();
                    return Ok(Value::List {
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                "memberProperties" | "declaredMemberProperties" => {
                    // KClass.memberProperties: KProperty1 instances, one
                    // per primary-ctor property + body property.
                    let mut items: Vec<Value> = Vec::new();
                    for p in &c.primary_params {
                        if p.property.is_some() {
                            items.push(Value::PropertyRef {
                                name: Rc::new(p.name.clone()),
                            });
                        }
                    }
                    for p in &c.body_properties {
                        items.push(Value::PropertyRef {
                            name: Rc::new(p.name.clone()),
                        });
                    }
                    return Ok(Value::List {
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                "constructors" | "primaryConstructor" => {
                    // KClass.primaryConstructor: a `KFunction` whose
                    // `.call(args)` returns a fresh instance. The
                    // runtime models class construction through
                    // `Value::Class` invocation; we synthesize a
                    // lightweight Function-like value here by returning
                    // the class itself (callable via `Class(args)`).
                    if name == "constructors" {
                        return Ok(Value::List {
                            items: Rc::new(RefCell::new(vec![Value::Class(Rc::clone(c))])),
                            mutable: false,
                            enum_class: None,
                        });
                    }
                    return Ok(Value::Class(Rc::clone(c)));
                }
                "annotations" => {
                    // Synthesize a placeholder annotation instance
                    // per recorded runtime-retained name. The class
                    // for each instance is the registered annotation
                    // class (if known) so `is`-checks against the
                    // annotation type work in user code.
                    let mut items: Vec<Value> = Vec::with_capacity(c.annotation_names.len());
                    for ann_name in &c.annotation_names {
                        items.push(self.synthesize_annotation_value(ann_name));
                    }
                    return Ok(Value::List {
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: None,
                    });
                }
                _ => {}
            }
        }
        if let Value::Instance(inst) = &receiver {
            // If the class declares this property with a delegate or a
            // custom getter, dispatch through it before reading the raw
            // field. (Backing fields live alongside under the same name
            // for plain props — and under `__delegate$name` for delegated
            // ones.)
            let class = Rc::clone(&inst.borrow().class);
            if let Some((pdef, _)) = class.find_body_property(name) {
                if pdef.delegate.is_some() || pdef.getter.is_some() {
                    return self.read_instance_property(inst, &pdef, out);
                }
            }
            if let Some(v) = inst.borrow().get(name) {
                if let Some(prop_name) = lateinit_sentinel_name(&v) {
                    return Err(lateinit_throw(&prop_name));
                }
                return Ok(v);
            }
            // Inheritance-delegation property forwarding: if no field or
            // declared property answered the read, route to a delegate
            // whose interface declares a member of this name.
            let delegates = class.supertype_delegates.borrow().clone();
            for d in &delegates {
                let mut iface_props: Vec<String> = Vec::new();
                if let Some(iface) = &d.interface {
                    collect_interface_property_names(iface, &mut iface_props, &mut Vec::new());
                }
                if iface_props.iter().any(|n| n == name) {
                    if let Some(delegate_val) = inst.borrow().get(&d.field_key) {
                        return self.eval_property_access(delegate_val, name, out);
                    }
                }
            }
            // Nested-class navigation: `outer.Inner` produces a
            // `BoundInnerClass` for inner classes (calling it captures
            // `outer`) or the bare nested `Value::Class` otherwise.
            if let Some(nc) = lookup_nested_class(&class, name) {
                if nc.is_inner {
                    return Ok(Value::BoundInnerClass {
                        class: nc,
                        outer: Rc::clone(inst),
                    });
                }
                return Ok(Value::Class(nc));
            }
            if let Some(v) = self.try_extension_property_get(&receiver, name, out)? {
                return Ok(v);
            }
            // Built-in Throwable surface: `message` / `cause` default to
            // `null` when an instance of a Throwable subclass has not been
            // explicitly populated (e.g. `class MyErr : Throwable()`).
            if matches!(name, "message" | "cause") && instance_is_throwable(inst) {
                return Ok(Value::Null);
            }
            // Companion forwarding: `Instance` of a companion exposes the
            // companion's properties directly. (For class.companion, see
            // Class branch below.)
            return Err(RuntimeError::Unimplemented(format!(
                "{}.{}",
                inst.borrow().class.fqn,
                name
            )));
        }
        if let Value::Class(class) = &receiver {
            // A `Value::Class` for an `object` is really a deferred
            // singleton reference. Construct it (if not already) and
            // route the access to the resulting instance.
            if class.is_object {
                let inst = if let Some(inst) = class.object_singleton.borrow().clone() {
                    inst
                } else {
                    let inst = self.construct_object_singleton(class, out)?;
                    *class.object_singleton.borrow_mut() = Some(Rc::clone(&inst));
                    inst
                };
                return self.eval_property_access(Value::Instance(inst), name, out);
            }
            // `Color.RED` — enum entry as a value.
            if class.is_enum {
                for (n, v) in class.enum_entries.borrow().iter() {
                    if n == name {
                        return Ok(v.clone());
                    }
                }
                // `Color.entries` — `List<Color>` of all entries.
                if name == "entries" {
                    let items: Vec<Value> = class
                        .enum_entries
                        .borrow()
                        .iter()
                        .map(|(_, v)| v.clone())
                        .collect();
                    return Ok(Value::List {
                        items: Rc::new(RefCell::new(items)),
                        mutable: false,
                        enum_class: Some(Rc::new(class.name.clone())),
                    });
                }
            }
            // `Foo.NAME` — companion property, or `Foo.CompanionName` to
            // get the companion instance itself, or nested-object lookup.
            let comp_opt = class.companion.borrow().clone();
            if let Some(comp) = comp_opt.as_ref() {
                if name == comp.borrow().class.name {
                    return Ok(Value::Instance(Rc::clone(comp)));
                }
                // Route through the Instance branch so getter-only
                // properties (`val Foo get() = ...`) dispatch through
                // their getter instead of bottoming out at a missing
                // backing field. find_body_property + read_instance_property
                // walk the companion's class members, which is exactly
                // the same machinery a plain instance access uses.
                let comp_class = Rc::clone(&comp.borrow().class);
                if comp_class.find_body_property(name).is_some()
                    || comp.borrow().get(name).is_some()
                {
                    return self.eval_property_access(
                        Value::Instance(Rc::clone(comp)),
                        name,
                        out,
                    );
                }
            }
            // `Foo.Bar` — nested class (only the non-inner kind is reachable
            // qualified-class-style; an `inner class` must be navigated
            // through an outer instance). For a nested `object`, return the
            // (lazily constructed) singleton instance instead of the class.
            if let Some(nc) = lookup_nested_class(class, name) {
                if !nc.is_inner {
                    if nc.is_object {
                        if let Some(inst) = nc.object_singleton.borrow().clone() {
                            return Ok(Value::Instance(inst));
                        }
                        let inst = self.construct_object_singleton(&nc, out)?;
                        *nc.object_singleton.borrow_mut() = Some(Rc::clone(&inst));
                        return Ok(Value::Instance(inst));
                    }
                    return Ok(Value::Class(nc));
                }
            }
            return Err(RuntimeError::Unimplemented(format!(
                "{}.{}",
                class.fqn, name
            )));
        }
        let fqn = format!("{}.{}", receiver.type_fqn(), name);
        if let Some(func) = self.lookup_intrinsic(&fqn) {
            let args = [receiver];
            let mut ctx = CallCtx { args: &args, out };
            return func(&mut ctx);
        }
        if let Some(v) = self.try_extension_property_get(&receiver, name, out)? {
            return Ok(v);
        }
        Err(RuntimeError::Unimplemented(fqn))
    }

    fn find_extension_property(
        &self,
        receiver: &Value,
        name: &str,
    ) -> Option<ExtensionProp> {
        let keys = Self::receiver_type_names(receiver);
        for key in &keys {
            if let Some(list) = self.extension_properties.get(key) {
                for ep in list {
                    if ep.decl.name.name == name {
                        return Some(ep.clone());
                    }
                }
            }
        }
        None
    }

    fn try_extension_property_get(
        &mut self,
        receiver: &Value,
        name: &str,
        out: &mut dyn Output,
    ) -> Result<Option<Value>, RuntimeError> {
        let Some(ep) = self.find_extension_property(receiver, name) else {
            return Ok(None);
        };
        let Some(getter) = ep.decl.getter.as_ref() else {
            return Err(RuntimeError::Unimplemented(format!(
                "extension property `{}` without getter",
                ep.decl.name.name
            )));
        };
        let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&ep.env))));
        frame.borrow_mut().define("this", receiver.clone());
        let v = self.eval_accessor_body(getter, &frame, out)?;
        Ok(Some(v))
    }

    fn try_extension_property_set(
        &mut self,
        receiver: &Value,
        name: &str,
        new_value: Value,
        out: &mut dyn Output,
    ) -> Result<Option<()>, RuntimeError> {
        let Some(ep) = self.find_extension_property(receiver, name) else {
            return Ok(None);
        };
        let Some(setter) = ep.decl.setter.as_ref() else {
            return Err(RuntimeError::Unimplemented(format!(
                "extension property `{}` without setter",
                ep.decl.name.name
            )));
        };
        let frame = Rc::new(RefCell::new(Env::with_parent(Rc::clone(&ep.env))));
        frame.borrow_mut().define("this", receiver.clone());
        let param_name = setter
            .params
            .first()
            .map(|p| p.name.clone())
            .unwrap_or_else(|| "value".to_string());
        frame.borrow_mut().define(param_name, new_value);
        self.eval_accessor_body(setter, &frame, out)?;
        Ok(Some(()))
    }

    fn eval_call(
        &mut self,
        callee: &Expr,
        args: &[Expr],
        arg_names: &[Option<String>],
        type_args: &[klio_ast::TypeRef],
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let _ = type_args;
        // Top-level overload resolution. When the callee is a bare
        // simple name that resolves to multiple top-level function
        // decls (e.g. kotlinx.atomicfu.atomic(Int) / atomic(Long) /
        // atomic(Boolean)), evaluate the arguments once and pick the
        // most-specific candidate by formal-parameter-type vs
        // argument-runtime-type. Single-overload names fall through
        // to the regular env-lookup path.
        if let Some(name) = simple_callee_name(callee) {
            if let Some(overloads) = self.top_level_overloads.get(name) {
                if overloads.len() >= 2 {
                    let overloads = overloads.clone();
                    let (vals, spread_mask) =
                        self.eval_args_with_spread(args, env, out)?;
                    let flat = flatten_spreads(vals, &spread_mask);
                    if let Some((decl, captured)) =
                        select_overload(&overloads, &flat, arg_names)
                    {
                        return self.call_function_named(
                            &decl, &captured, &flat, arg_names, out,
                        );
                    }
                }
            }
        }
        // Reified-aware dispatch: when the callee resolves by simple name to
        // a `Value::Function` whose decl is `inline fun <reified T> ...`,
        // push a per-call frame that binds each reified type param's name
        // to the simple type name supplied at the call site, run the call,
        // then pop the frame regardless of outcome.
        if !type_args.is_empty() {
            if let Some(name) = simple_callee_name(callee) {
                if let Some(Value::Function { decl, env: captured }) =
                    env.borrow().lookup(name)
                {
                    if decl.is_inline
                        && decl.type_params.iter().any(|tp| tp.is_reified)
                    {
                        let mut arg_vals = Vec::with_capacity(args.len());
                        for a in args {
                            arg_vals.push(self.eval_expr(a, env, out)?);
                        }
                        self.push_reified_frame(&decl, type_args);
                        let result = self.call_function_named(
                            &decl, &captured, &arg_vals, arg_names, out,
                        );
                        self.pop_reified_frame(&decl);
                        return result;
                    }
                }
            }
        }
        // `lazy { producer }` — built-in property delegate. Stays in the
        // interpreter so the producer lambda can be invoked at first
        // read.
        if let Some(name) = simple_callee_name(callee) {
            if name == "lazy" && args.len() == 1 {
                let producer = self.eval_expr(&args[0], env, out)?;
                return Ok(Value::Delegate(Rc::new(RefCell::new(
                    klio_runtime::DelegateKind::Lazy { producer, cached: None },
                ))));
            }
        }
        // `Delegates.observable(initial) { _, old, new -> … }` and
        // `Delegates.notNull<T>()`. Recognized via the callee shape so we
        // don't need a `Value::Class` standing in for the Delegates object.
        if let Expr::Member { receiver, name, safe: false, .. } = callee {
            if let Some(rname) = simple_callee_name(receiver) {
                if rname == "Delegates" {
                    return self.eval_delegates_member(&name.name, args, env, out);
                }
            }
        }
        // `compareBy { selector }` builds a Comparator. Lambda-bearing
        // top-level fns live in the interp like with/let/etc.
        if let Some(name) = simple_callee_name(callee) {
            if name == "generateSequence" {
                return self.eval_generate_sequence(args, env, out);
            }
            if let Some(v) = self.try_eval_array_constructor(name, args, env, out)? {
                return Ok(v);
            }
            // `Comparator<T> { a, b -> Int }` — SAM construction
            // of a Comparator from a 2-arg comparison lambda. The
            // chain dispatcher (apply_comparator_step) already
            // accepts 2-arg lambdas in step position, so we just
            // wrap the lambda directly as the sole step.
            if name == "Comparator" && args.len() == 1 {
                let v = self.eval_expr(&args[0], env, out)?;
                if let Value::Lambda { .. } = &v {
                    return Ok(Value::Comparator {
                        steps: Rc::new(vec![(v, false)]),
                        descending: false,
                    });
                }
                return Err(RuntimeError::Type(
                    "Comparator { … } expects a 2-arg comparison lambda".into(),
                ));
            }
            if name == "compareBy" || name == "compareByDescending" {
                let per_step_descending = name == "compareByDescending";
                let mut steps: Vec<(Value, bool)> = Vec::with_capacity(args.len());
                for a in args {
                    let v = self.eval_expr(a, env, out)?;
                    if !matches!(v, Value::Lambda { .. }) {
                        return Err(RuntimeError::Type(format!(
                            "{name} expects key-selector lambdas"
                        )));
                    }
                    steps.push((v, per_step_descending));
                }
                return Ok(Value::Comparator { steps: Rc::new(steps), descending: false });
            }
            if name == "compareValues" && args.len() == 2 {
                let a = self.eval_expr(&args[0], env, out)?;
                let b = self.eval_expr(&args[1], env, out)?;
                let n: i32 = match (
                    matches!(a, Value::Null),
                    matches!(b, Value::Null),
                ) {
                    (true, true) => 0,
                    (true, false) => -1,
                    (false, true) => 1,
                    (false, false) => match self.compare_with_user(&a, &b, out)? {
                        std::cmp::Ordering::Less => -1,
                        std::cmp::Ordering::Equal => 0,
                        std::cmp::Ordering::Greater => 1,
                    },
                };
                return Ok(Value::Int(n));
            }
            if name == "compareValuesBy" && args.len() >= 3 {
                let a = self.eval_expr(&args[0], env, out)?;
                let b = self.eval_expr(&args[1], env, out)?;
                for sel in &args[2..] {
                    let lam = self.eval_expr(sel, env, out)?;
                    let Value::Lambda { params, body, env: captured, .. } = &lam else {
                        return Err(RuntimeError::Type(
                            "compareValuesBy expects key-selector lambdas".into(),
                        ));
                    };
                    let ka = self.call_lambda(params, body, captured, std::slice::from_ref(&a), out)?;
                    let kb = self.call_lambda(params, body, captured, std::slice::from_ref(&b), out)?;
                    let ord = match (matches!(ka, Value::Null), matches!(kb, Value::Null)) {
                        (true, true) => std::cmp::Ordering::Equal,
                        (true, false) => std::cmp::Ordering::Less,
                        (false, true) => std::cmp::Ordering::Greater,
                        (false, false) => self.compare_with_user(&ka, &kb, out)?,
                    };
                    if !matches!(ord, std::cmp::Ordering::Equal) {
                        let n: i32 = match ord {
                            std::cmp::Ordering::Less => -1,
                            std::cmp::Ordering::Greater => 1,
                            std::cmp::Ordering::Equal => 0,
                        };
                        return Ok(Value::Int(n));
                    }
                }
                return Ok(Value::Int(0));
            }
        }

        // Top-level lambda-taking stdlib helpers. These live in the interp
        // since they need to invoke a lambda from Rust.
        if let Some(name) = simple_callee_name(callee) {
            if let Some(v) = self.try_eval_top_level_lambda_helper(name, args, env, out)? {
                return Ok(v);
            }
        }

        // `runCatching { … }` — invoke the lambda; capture thrown
        // Throwables as a `Result.failure(e)`; otherwise `Result.success(v)`.
        if let Some(name) = simple_callee_name(callee) {
            if name == "runCatching" && args.len() == 1 {
                let lam = self.eval_expr(&args[0], env, out)?;
                return self.eval_run_catching(&lam, None, out);
            }
        }
        // Coroutine intrinsics (spec §18.2). For our purposes a
        // `suspend` block is executed synchronously: there is no
        // state-machine lowering; the suspending function's body
        // runs to completion and any `cont.resume(v)` inside a
        // `suspendCoroutine { … }` writes the result into a slot
        // we read once the lambda returns. Real async (delay,
        // launch, async) lives in kotlinx.coroutines which is
        // out of scope.
        if let Some(name) = simple_callee_name(callee) {
            match name {
                "runBlocking" if args.len() == 1 => {
                    let lam = self.eval_expr(&args[0], env, out)?;
                    return self.run_blocking(&lam, out);
                }
                "suspendCoroutine"
                | "suspendCoroutineUninterceptedOrReturn"
                | "suspendCancellableCoroutine"
                    if args.len() == 1 =>
                {
                    let lam = self.eval_expr(&args[0], env, out)?;
                    return self.eval_suspend_coroutine(&lam, out);
                }
                _ => {}
            }
        }
        // `Result.success(x)` / `Result.failure(e)` — static factories.
        if let Expr::Member { receiver, name, safe: false, .. } = callee {
            if let Some(rname) = simple_callee_name(receiver) {
                if rname == "Result" {
                    match name.name.as_str() {
                        "success" if args.len() == 1 => {
                            let v = self.eval_expr(&args[0], env, out)?;
                            return Ok(Value::Result { ok: true, payload: Box::new(v) });
                        }
                        "failure" if args.len() == 1 => {
                            let v = self.eval_expr(&args[0], env, out)?;
                            return Ok(Value::Result { ok: false, payload: Box::new(v) });
                        }
                        _ => {}
                    }
                }
            }
        }

        // Top-level scoping fn: `with(receiver) { lambda }`. Hardcoded
        // because, like the member-form scoping fns, it needs to invoke a
        // lambda — something stdlib intrinsics can't do today. `with`
        // exposes the receiver as `this` (no `it`).
        if let Some(name) = simple_callee_name(callee) {
            if name == "with" && args.len() == 2 {
                let recv = self.eval_expr(&args[0], env, out)?;
                let lam = self.eval_expr(&args[1], env, out)?;
                let Value::Lambda { params, body, env: captured, .. } = &lam else {
                    return Err(RuntimeError::Type(
                        "`with` requires a lambda as its second argument".into(),
                    ));
                };
                return self.call_lambda_with_this(params, body, captured, &[], Some(recv), false, out);
            }
            // Implicit-this method dispatch: bare `name(args)` resolves to a
            // method on `this` when `name` isn't otherwise bound. This is
            // how `apply { length }` / `apply { uppercase() }` work — the
            // receiver was installed as `this` by the scoping-fn dispatcher.
            if env.borrow().lookup(name).is_none() {
                if let Some(this_val) = env.borrow().lookup("this") {
                    // User-class instance method dispatch.
                    if let Value::Instance(inst) = &this_val {
                        let class = Rc::clone(&inst.borrow().class);
                        if let Some((m, _owner)) = class.find_method(name) {
                            let mut arg_vals = Vec::with_capacity(args.len());
                            for a in args {
                                arg_vals.push(self.eval_expr(a, env, out)?);
                            }
                            return self.call_method(inst, &m, &arg_vals, arg_names, out);
                        }
                        // Companion-method dispatch through the class
                        // chain. Inside a subclass method body, bare
                        // calls resolve through parent companion methods.
                        for comp in class.all_companions() {
                            let comp_class = Rc::clone(&comp.borrow().class);
                            if let Some(m) =
                                comp_class.methods.iter().find(|m| m.name == name)
                            {
                                let m = m.clone();
                                let mut arg_vals = Vec::with_capacity(args.len());
                                for a in args {
                                    arg_vals.push(self.eval_expr(a, env, out)?);
                                }
                                return self.call_method(&comp, &m, &arg_vals, arg_names, out);
                            }
                        }
                    }
                    let fqn = format!("{}.{}", this_val.type_fqn(), name);
                    if let Some(func) = self.lookup_intrinsic(&fqn) {
                        let mut arg_vals = Vec::with_capacity(args.len() + 1);
                        arg_vals.push(this_val);
                        for a in args {
                            arg_vals.push(self.eval_expr(a, env, out)?);
                        }
                        let mut ctx = CallCtx { args: &arg_vals, out };
                        return func(&mut ctx);
                    }
                }
            }
        }

        // Static dotted call shape, e.g. `kotlin.math.abs(-7)`. Flatten the
        // callee chain to an FQN and dispatch directly if the stdlib has it.
        if let Some(fqn) = try_qualified_name(callee) {
            if let Some(func) = self.lookup_intrinsic(&fqn) {
                let mut arg_vals = Vec::with_capacity(args.len());
                for a in args {
                    arg_vals.push(self.eval_expr(a, env, out)?);
                }
                arg_vals = reorder_intrinsic_args(&fqn, arg_vals, arg_names)?;
                let mut ctx = CallCtx { args: &arg_vals, out };
                return func(&mut ctx);
            }
        }

        // `super.method(args...)` — step exactly one class up the chain
        // from the body's owning class and dispatch. With `super<Klazz>`
        // dispatch through the named supertype instead of the parent.
        // With `super@Outer` dispatch through the outer instance's class.
        if let Expr::Member { receiver, name, safe: false, .. } = callee {
            if let Expr::Super { qualifier, label, .. } = receiver.as_ref() {
                let (inst, owner) = if let Some(l) = label {
                    let qname = format!("this@{}", l.name);
                    let Some(Value::Instance(i)) = env.borrow().lookup(&qname) else {
                        return Err(RuntimeError::Type(format!(
                            "`super@{}` does not denote an enclosing receiver",
                            l.name
                        )));
                    };
                    let cls = Rc::clone(&i.borrow().class);
                    (i, cls)
                } else {
                    let i = match env.borrow().lookup("this") {
                        Some(Value::Instance(i)) => i,
                        _ => {
                            return Err(RuntimeError::Type(
                                "`super` is only valid inside an instance method".into(),
                            ));
                        }
                    };
                    let owner = match env.borrow().lookup("__owner_class__") {
                        Some(Value::Class(c)) => c,
                        _ => Rc::clone(&i.borrow().class),
                    };
                    (i, owner)
                };
                let root = resolve_super_root(&owner, qualifier.as_ref())?;
                let Some((m, found_in)) = root.find_method(&name.name) else {
                    return Err(RuntimeError::Unimplemented(format!(
                        "super.{}",
                        name.name
                    )));
                };
                let mut arg_vals = Vec::with_capacity(args.len());
                for a in args {
                    arg_vals.push(self.eval_expr(a, env, out)?);
                }
                return self.call_method_with_owner(
                    &inst, &found_in, &m, &arg_vals, arg_names, out,
                );
            }
        }
        // Method-call shape: `receiver.name(args...)`. Treat as a method
        // dispatch so the receiver becomes args[0] inside the intrinsic.
        if let Expr::Member { receiver, name, safe, .. } = callee {
            let recv = self.eval_expr(receiver, env, out)?;
            if *safe && matches!(recv, Value::Null) {
                return Ok(Value::Null);
            }
            // `Foo::prop.get(receiver)` — KProperty1 reflection-lite read.
            // The lightweight `Value::PropertyRef` carries only a name; the
            // receiver supplies the live instance.
            if let Value::PropertyRef { name: pname } = &recv {
                if name.name == "get" && args.len() == 1 {
                    let receiver = self.eval_expr(&args[0], env, out)?;
                    return self.eval_property_access(receiver, pname, out);
                }
                if name.name == "invoke" {
                    // `prop.invoke(receiver)` — alias for `.get(receiver)`.
                    if args.len() == 1 {
                        let receiver = self.eval_expr(&args[0], env, out)?;
                        return self.eval_property_access(receiver, pname, out);
                    }
                }
                if name.name == "set" && args.len() == 2 {
                    // `KMutableProperty1.set(receiver, value)` writes the
                    // named property on the instance. Honors a custom
                    // setter / property delegate when one is declared.
                    let receiver = self.eval_expr(&args[0], env, out)?;
                    let value = self.eval_expr(&args[1], env, out)?;
                    let Value::Instance(inst) = receiver else {
                        return Err(RuntimeError::Type(
                            "KMutableProperty1.set: receiver must be an instance".into(),
                        ));
                    };
                    let class = Rc::clone(&inst.borrow().class);
                    if let Some((pdef, _)) = class.find_body_property(pname) {
                        if pdef.delegate.is_some() || pdef.setter.is_some() {
                            self.write_instance_property(&inst, &pdef, value, out)?;
                            return Ok(Value::Unit);
                        }
                    }
                    inst.borrow_mut().define(pname.as_str(), value);
                    return Ok(Value::Unit);
                }
                if name.name == "name" && args.is_empty() {
                    return Ok(Value::String(Rc::new((**pname).clone())));
                }
            }
            // `kfn.call(args...)` / `kfn.invoke(args...)` on a reflective
            // function reference (`::topLevelFn` / `Foo::method`).
            if let Value::Function { decl, env: captured } = &recv {
                if name.name == "call" || name.name == "invoke" {
                    let mut arg_vals = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    // Member-function reference (`Foo::method`): the
                    // first `.call` argument is the receiver, and the
                    // remaining arguments are the declared params. The
                    // synthetic Value::Function we built at `Foo::m`
                    // has the method's decl directly (no `this`
                    // parameter), so detect the member shape by
                    // matching the leading instance against a class
                    // that declares the same method.
                    if !arg_vals.is_empty()
                        && arg_vals.len() == decl.params.len() + 1
                    {
                        if let Value::Instance(inst) = &arg_vals[0] {
                            let class = Rc::clone(&inst.borrow().class);
                            if class.find_method(&decl.name.name).is_some() {
                                let receiver = Rc::clone(inst);
                                let rest: Vec<Value> = arg_vals[1..].to_vec();
                                let names_rest: Vec<Option<String>> = if arg_names.len() == arg_vals.len() {
                                    arg_names[1..].to_vec()
                                } else {
                                    vec![None; rest.len()]
                                };
                                let (m, _) = class.find_method(&decl.name.name).unwrap();
                                return self.call_method(&receiver, &m, &rest, &names_rest, out);
                            }
                        }
                    }
                    return self.call_function_named(
                        decl,
                        captured,
                        &arg_vals,
                        arg_names,
                        out,
                    );
                }
                if name.name == "name" {
                    return Ok(Value::String(Rc::new(decl.name.name.clone())));
                }
            }
            // Any-level methods on a class literal (`Foo::class`).
            if let Value::Class(c) = &recv {
                if name.name == "findAnnotation" {
                    // KClass.findAnnotation<A>() — return the first
                    // annotation instance of type `A` if present.
                    let target = type_args.first().map(|ta| ta.name.name.clone());
                    if let Some(target) = target {
                        for ann_name in &c.annotation_names {
                            if ann_name == &target {
                                return Ok(self.synthesize_annotation_value(ann_name));
                            }
                        }
                        return Ok(Value::Null);
                    }
                    return Ok(Value::Null);
                }
                if name.name == "hasAnnotation" {
                    let target = type_args.first().map(|ta| ta.name.name.clone());
                    if let Some(target) = target {
                        return Ok(Value::Bool(
                            c.annotation_names.iter().any(|n| n == &target),
                        ));
                    }
                    return Ok(Value::Bool(false));
                }
                match name.name.as_str() {
                    "equals" if args.len() == 1 => {
                        let other = self.eval_expr(&args[0], env, out)?;
                        return Ok(Value::Bool(Value::structural_eq(&recv, &other)));
                    }
                    "hashCode" if args.is_empty() => {
                        return Ok(Value::new_int(value_hash(&Value::Class(Rc::clone(c)))));
                    }
                    "toString" if args.is_empty() => {
                        return Ok(Value::String(Rc::new(format!("class {}", c.name))));
                    }
                    _ => {}
                }
            }
            // Built-in Array methods kept local — they bridge to a List
            // (for `toList`) or echo a property (for `isEmpty`).
            if let Value::Array { items, prim } = &recv {
                match name.name.as_str() {
                    "toList" if args.is_empty() => {
                        let snapshot = items.borrow().clone();
                        return Ok(Value::List {
                            items: Rc::new(RefCell::new(snapshot)),
                            mutable: false,
                            enum_class: None,
                        });
                    }
                    "isEmpty" if args.is_empty() => {
                        return Ok(Value::Bool(items.borrow().is_empty()));
                    }
                    "isNotEmpty" if args.is_empty() => {
                        return Ok(Value::Bool(!items.borrow().is_empty()));
                    }
                    "iterator" if args.is_empty() => {
                        return Ok(Value::Iterator {
                            items: Rc::clone(items),
                            pos: Rc::new(RefCell::new(0)),
                            prim: *prim,
                        });
                    }
                    _ => {}
                }
            }
            // Iterator method dispatch — hasNext / next / next{TYPE}.
            if let Value::Iterator { items, pos, prim } = &recv {
                match name.name.as_str() {
                    "hasNext" if args.is_empty() => {
                        return Ok(Value::Bool(*pos.borrow() < items.borrow().len()));
                    }
                    "next" if args.is_empty() => {
                        let mut p = pos.borrow_mut();
                        let it = items.borrow();
                        if *p >= it.len() {
                            return Err(RuntimeError::Thrown(Value::Exception {
                                fqn: Rc::new("kotlin.NoSuchElementException".into()),
                                message: Some(Rc::new("Iterator exhausted".into())),
                                cause: None,
                            }));
                        }
                        let v = it[*p].clone();
                        *p += 1;
                        return Ok(v);
                    }
                    other if args.is_empty() && prim.is_some()
                        && other == format!("next{}", prim.unwrap().simple_name()) =>
                    {
                        let mut p = pos.borrow_mut();
                        let it = items.borrow();
                        if *p >= it.len() {
                            return Err(RuntimeError::Thrown(Value::Exception {
                                fqn: Rc::new("kotlin.NoSuchElementException".into()),
                                message: Some(Rc::new("Iterator exhausted".into())),
                                cause: None,
                            }));
                        }
                        let v = it[*p].clone();
                        *p += 1;
                        return Ok(v);
                    }
                    _ => {}
                }
            }
            // Lists also expose `.iterator()`.
            if let Value::List { items, .. } = &recv {
                if name.name == "iterator" && args.is_empty() {
                    return Ok(Value::Iterator {
                        items: Rc::clone(items),
                        pos: Rc::new(RefCell::new(0)),
                        prim: None,
                    });
                }
            }
            // Synthetic kotlin.coroutines.Continuation: resume /
            // resumeWith / resumeWithException write into the
            // active continuation slot.
            if let Value::Instance(inst) = &recv {
                let cls_fqn = inst.borrow().class.fqn.clone();
                if cls_fqn == "kotlin.coroutines.Continuation" {
                    match name.name.as_str() {
                        "resume" | "resumeWith" | "resumeWithException"
                            if args.len() == 1 =>
                        {
                            let v = self.eval_expr(&args[0], env, out)?;
                            let Some(slot) = self.coroutine_continuations.last() else {
                                return Err(RuntimeError::Type(
                                    "continuation used outside an active suspendCoroutine".into(),
                                ));
                            };
                            let mut s = slot.borrow_mut();
                            match name.name.as_str() {
                                "resume" => *s = ContinuationSlot::Resumed(v),
                                "resumeWith" => {
                                    if let Value::Result { ok, payload } = v {
                                        *s = if ok {
                                            ContinuationSlot::Resumed(*payload)
                                        } else {
                                            ContinuationSlot::Failed(*payload)
                                        };
                                    } else {
                                        *s = ContinuationSlot::Resumed(v);
                                    }
                                }
                                "resumeWithException" => *s = ContinuationSlot::Failed(v),
                                _ => unreachable!(),
                            }
                            return Ok(Value::Unit);
                        }
                        "context" if args.is_empty() => {
                            return Ok(self.empty_coroutine_context());
                        }
                        _ => {}
                    }
                }
            }
            // Pack-installed bindings win over user method bodies. A
            // kotlinx-style library may ship a Kotlin shim that
            // declares the class shape, and override individual
            // methods with native impls keyed by FQN. The shim's body
            // remains available as a fallback when a binding is not
            // installed.
            if let Value::Instance(inst) = &recv {
                let cls_fqn = inst.borrow().class.fqn.clone();
                let fqn = format!("{cls_fqn}.{}", name.name);
                if let Some(func) = self.binding_override(&fqn) {
                    let mut user_args = Vec::with_capacity(args.len());
                    for a in args {
                        user_args.push(self.eval_expr(a, env, out)?);
                    }
                    let mut arg_vals = Vec::with_capacity(user_args.len() + 1);
                    arg_vals.push(recv.clone());
                    arg_vals.extend(user_args);
                    let mut ctx = CallCtx { args: &arg_vals, out };
                    return func(&mut ctx);
                }
            }
            // Instance method dispatch (user classes).
            if let Value::Instance(inst) = &recv {
                let class = Rc::clone(&inst.borrow().class);
                let same_name_count = class.methods.iter().filter(|m| m.name == name.name).count();
                let mut arg_vals_opt: Option<Vec<Value>> = None;
                let first_arg_type = if same_name_count > 1 && !args.is_empty() {
                    let mut arg_vals = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    let t = arg_vals.first().map(value_runtime_type_name);
                    arg_vals_opt = Some(arg_vals);
                    t
                } else {
                    None
                };
                if let Some((m, _owner)) = class.find_method_for_arg(&name.name, first_arg_type.as_deref()) {
                    let mut arg_vals = if let Some(v) = arg_vals_opt {
                        v
                    } else {
                        let mut tmp = Vec::with_capacity(args.len());
                        for a in args {
                            tmp.push(self.eval_expr(a, env, out)?);
                        }
                        tmp
                    };
                    let _ = &mut arg_vals;
                    // Reified type args: if the method is `inline fun
                    // <reified T> ...`, push a per-call frame so `T::class`
                    // / `x is T` inside the body see the call-site type.
                    let pushed_reified = if !type_args.is_empty()
                        && m.decl.is_inline
                        && m.decl.type_params.iter().any(|tp| tp.is_reified)
                    {
                        self.push_reified_frame(&m.decl, type_args);
                        true
                    } else {
                        false
                    };
                    let result =
                        self.call_method(inst, &m, &arg_vals, arg_names, out);
                    if pushed_reified {
                        self.pop_reified_frame(&m.decl);
                    }
                    return result;
                }
                // Auto-generated members on every instance / data-class
                // members on data classes.
                if let Some(v) = self.eval_instance_auto_member(inst, &name.name, args, arg_names, env, out)? {
                    return Ok(v);
                }
                // Nested-class construction via `outer.Inner(args)` — for
                // inner classes the receiver is captured as the outer; for
                // a plain nested class we just construct against the class.
                if let Some(nc) = lookup_nested_class(&class, &name.name) {
                    let mut arg_vals = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    let outer = if nc.is_inner {
                        Some(Value::Instance(Rc::clone(inst)))
                    } else {
                        None
                    };
                    return self.construct_instance_with_outer(
                        &nc, &arg_vals, arg_names, outer, out,
                    );
                }
                // Fall through to extension-function dispatch before
                // erroring on a user-class instance.
                if let Some(v) =
                    self.try_extension_call(&recv, &name.name, args, arg_names, env, out)?
                {
                    return Ok(v);
                }
                // Property holding a callable — `inst.fn(args)` where
                // `fn` is a `val fn: (T) -> R` field.
                if let Some(v) = inst.borrow().get(&name.name) {
                    if matches!(v, Value::Lambda { .. } | Value::Function { .. } | Value::Intrinsic { .. } | Value::BoundMethod { .. } | Value::BoundUserMethod { .. }) {
                        let mut arg_vals = Vec::with_capacity(args.len());
                        for a in args {
                            arg_vals.push(self.eval_expr(a, env, out)?);
                        }
                        return self.invoke_callable_value(&v, &arg_vals, arg_names, out);
                    }
                }
                // A function-typed value in scope (e.g. a parameter of type
                // `T.(...) -> R`) may be invoked as `recv.name(args)`. The
                // receiver binds as `this` inside the lambda.
                if let Some(Value::Lambda { params, body, env: captured, .. }) =
                    env.borrow().lookup(&name.name)
                {
                    let mut arg_vals: Vec<Value> = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    return self.call_lambda_with_this(
                        &params,
                        &body,
                        &captured,
                        &arg_vals,
                        Some(recv.clone()),
                        false,
                        out,
                    );
                }
                if let Some(out_val) = self.try_eval_scoping_member(&recv, &name.name, args, env, out)?
                {
                    return Ok(out_val);
                }
                return Err(RuntimeError::Unimplemented(format!(
                    "{}.{}",
                    class.fqn, name.name
                )));
            }
            // Enum static methods: `values()`, `valueOf(name)`.
            if let Value::Class(class) = &recv {
                if class.is_enum {
                    match name.name.as_str() {
                        "values" if args.is_empty() => {
                            let items: Vec<Value> = class
                                .enum_entries
                                .borrow()
                                .iter()
                                .map(|(_, v)| v.clone())
                                .collect();
                            return Ok(Value::List { items: Rc::new(RefCell::new(items)), mutable: false, enum_class: None });
                        }
                        "valueOf" if args.len() == 1 => {
                            let arg = self.eval_expr(&args[0], env, out)?;
                            let Value::String(needle) = &arg else {
                                return Err(RuntimeError::Type(
                                    "valueOf requires a String".into(),
                                ));
                            };
                            for (n, v) in class.enum_entries.borrow().iter() {
                                if n == needle.as_str() {
                                    return Ok(v.clone());
                                }
                            }
                            // Match JVM Kotlin's
                            // `IllegalArgumentException("No enum constant <fqn>.<name>")`.
                            let msg = format!("No enum constant {}.{}", class.fqn, needle);
                            return Err(RuntimeError::Thrown(Value::Exception {
                                fqn: Rc::new(
                                    "kotlin.IllegalArgumentException".to_string(),
                                ),
                                message: Some(Rc::new(msg)),
                                cause: None,
                            }));
                        }
                        _ => {}
                    }
                }
            }
            // Companion method dispatch on `Foo.method(...)`.
            if let Value::Class(class) = &recv {
                let comp_opt = class.companion.borrow().clone();
                if let Some(comp) = comp_opt.as_ref() {
                    let comp_class = Rc::clone(&comp.borrow().class);
                    if let Some(m) = comp_class.methods.iter().find(|m| m.name == name.name) {
                        let m = m.clone();
                        let mut arg_vals = Vec::with_capacity(args.len());
                        for a in args {
                            arg_vals.push(self.eval_expr(a, env, out)?);
                        }
                        return self.call_method(comp, &m, &arg_vals, arg_names, out);
                    }
                }
                // `Outer.Nested(args)` — qualified construction of a
                // plain nested class. (Inner classes require an outer
                // instance and aren't reachable through this path.)
                if let Some(nc) = lookup_nested_class(class, &name.name) {
                    if !nc.is_inner {
                        let mut arg_vals = Vec::with_capacity(args.len());
                        for a in args {
                            arg_vals.push(self.eval_expr(a, env, out)?);
                        }
                        return self.construct_instance(&nc, &arg_vals, arg_names, out);
                    }
                }
                // Extension functions on the class or its companion —
                // `fun Foo.bar()` or `fun Foo.Companion.bar()` invoked
                // via `Foo.bar()`.
                if let Some(v) =
                    self.try_extension_call(&recv, &name.name, args, arg_names, env, out)?
                {
                    return Ok(v);
                }
                return Err(RuntimeError::Unimplemented(format!(
                    "{}.{}",
                    class.fqn, name.name
                )));
            }
            // Scoping intrinsics (let/also/apply/run/takeIf/takeUnless) need
            // to invoke a lambda argument with the receiver. They live in
            // the interpreter so they have access to lambda evaluation.
            if let Some(out_val) = self.try_eval_scoping_member(&recv, &name.name, args, env, out)?
            {
                return Ok(out_val);
            }
            // Comparator-shaped members (thenBy / reversed).
            if let Some(out_val) =
                self.try_eval_comparator_member(&recv, &name.name, args, env, out)?
            {
                return Ok(out_val);
            }
            // `T.runCatching { … }` — extension that invokes a lambda with
            // the receiver bound and captures any thrown Throwable as a
            // `Result.failure`.
            if name.name == "runCatching" && args.len() == 1 {
                let lam = self.eval_expr(&args[0], env, out)?;
                return self.eval_run_catching(&lam, Some(recv), out);
            }
            // Result members (lambda-bearing variants live here; the simpler
            // ones are registered as intrinsics).
            if matches!(recv, Value::Result { .. }) {
                if let Some(out_val) =
                    self.try_eval_result_member(&recv, &name.name, args, env, out)?
                {
                    return Ok(out_val);
                }
            }
            // Sequence dispatcher — handles every member call on a
            // Sequence receiver, since Sequence is lazy and intermediate
            // ops append to its op chain rather than evaluating eagerly.
            if matches!(recv, Value::Sequence(_)) {
                if let Some(out_val) = self.try_eval_sequence_member(&recv, &name.name, args, env, out)? {
                    return Ok(out_val);
                }
            }
            // joinToString with optional transform lambda.
            if name.name == "joinToString"
                && matches!(recv, Value::List { .. } | Value::Set { .. })
            {
                if let Some(out_val) =
                    self.eval_join_to_string(&recv, args, arg_names, env, out)?
                {
                    return Ok(out_val);
                }
            }
            // `sortedWith(comparator)` — receiver is a List, arg is a Comparator.
            if name.name == "sortedWith" && matches!(recv, Value::List { .. } | Value::Set { .. }) {
                return self.eval_sorted_with(recv, args, env, out).map(Some).and_then(|x| Ok(x.unwrap()));
            }
            // `sorted` / `sortedDescending` on a list of user `Value::Instance`
            // — short-circuit so the natural-order sort can dispatch the
            // user's `compareTo` instead of failing in the stdlib's
            // primitive-only comparator.
            if matches!(name.name.as_str(), "sorted" | "sortedDescending")
                && matches!(recv, Value::List { .. } | Value::Set { .. })
                && args.is_empty()
            {
                let items: Vec<Value> = match &recv {
                    Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
                    _ => unreachable!(),
                };
                if items.iter().any(|v| matches!(v, Value::Instance(_))) {
                    let mut sorted = items;
                    self.insertion_sort_values(&mut sorted, name.name == "sortedDescending", out)?;
                    return Ok(Value::List { items: Rc::new(RefCell::new(sorted)), mutable: false, enum_class: None });
                }
            }
            // Indexed higher-order ops on List/Set: mapIndexed / forEachIndexed / filterIndexed.
            if let Some(out_val) =
                self.try_eval_indexed_higher_order(&recv, &name.name, args, env, out)?
            {
                return Ok(out_val);
            }
            // Map higher-order ops: filterKeys/filterValues/mapKeys/mapValues/getOrElse/getOrPut/forEach.
            if let Some(out_val) =
                self.try_eval_map_higher_order(&recv, &name.name, args, env, out)?
            {
                return Ok(out_val);
            }
            // Higher-order collection ops (map/filter/forEach/fold/...). Like
            // scoping fns, they need to call lambdas from Rust, so they live
            // in the interpreter.
            if let Some(out_val) =
                self.try_eval_collection_higher_order(&recv, &name.name, args, env, out)?
            {
                return Ok(out_val);
            }
            let type_fqn = format!("{}.{}", recv.type_fqn(), name.name);
            if let Some(func) = self.lookup_intrinsic(&type_fqn) {
                let mut user_args = Vec::with_capacity(args.len());
                for a in args {
                    user_args.push(self.eval_expr(a, env, out)?);
                }
                user_args = reorder_intrinsic_args(&type_fqn, user_args, arg_names)?;
                let mut arg_vals = Vec::with_capacity(user_args.len() + 1);
                arg_vals.push(recv);
                arg_vals.extend(user_args);
                let mut ctx = CallCtx { args: &arg_vals, out };
                return func(&mut ctx);
            }
            // User-declared extension functions on a matching receiver
            // type. Looked up after member and intrinsic dispatch.
            if let Some(v) =
                self.try_extension_call(&recv, &name.name, args, arg_names, env, out)?
            {
                return Ok(v);
            }
            // Universal `Any` members available on every value.
            match name.name.as_str() {
                "toString" if args.is_empty() => {
                    let s = self.format_value(&recv, out)?;
                    return Ok(Value::String(Rc::new(s)));
                }
                "hashCode" if args.is_empty() => {
                    return Ok(Value::new_int(value_hash(&recv)));
                }
                "equals" if args.len() == 1 => {
                    let other = self.eval_expr(&args[0], env, out)?;
                    return Ok(Value::Bool(Value::structural_eq(&recv, &other)));
                }
                _ => {}
            }
            // `Function.invoke(...)` — explicit invocation of a callable
            // value. Mirrors what `recv(...)` would dispatch.
            if name.name == "invoke" {
                if let Value::Lambda { params, body, env: captured, .. } = &recv {
                    let mut arg_vals = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    return self.call_lambda(params, body, captured, &arg_vals, out);
                }
            }
            // Receiver-typed lambda parameter: `recv.block(args)` where
            // `block` is a local lambda value typed
            // `Recv.(Args) -> R`. Bind `this` to `recv` inside the lambda
            // body so member-style calls in the body resolve against
            // `recv`. Spec §4.1.6.
            if let Some(v) = env.borrow().lookup(&name.name) {
                if let Value::Lambda { params, body, env: captured, .. } = &v {
                    let mut arg_vals = Vec::with_capacity(args.len());
                    for a in args {
                        arg_vals.push(self.eval_expr(a, env, out)?);
                    }
                    return self.call_lambda_with_this(
                        params,
                        body,
                        captured,
                        &arg_vals,
                        Some(recv),
                        false,
                        out,
                    );
                }
            }
            return Err(RuntimeError::Unimplemented(type_fqn));
        }

        let callee_v = self.eval_expr(callee, env, out)?;
        let (mut arg_vals, is_spread_mask) = self.eval_args_with_spread(args, env, out)?;
        match callee_v {
            Value::Intrinsic { fqn, func } => {
                // Spreads not meaningful for intrinsics; flatten them.
                if is_spread_mask.iter().any(|s| *s) {
                    arg_vals = flatten_spreads(arg_vals, &is_spread_mask);
                }
                arg_vals = reorder_intrinsic_args(fqn, arg_vals, arg_names)?;
                // println/print on a user `Value::Instance` calls the user's
                // toString() (or falls back to the simple class name).
                if matches!(fqn, "kotlin.io.println" | "kotlin.io.print") {
                    let mut rewritten: Vec<Value> = Vec::with_capacity(arg_vals.len());
                    for v in arg_vals {
                        if matches!(v, Value::Instance(_)) {
                            let s = self.format_value(&v, out)?;
                            rewritten.push(Value::String(Rc::new(s)));
                        } else {
                            rewritten.push(v);
                        }
                    }
                    arg_vals = rewritten;
                }
                // A pack-installed binding shadows the statically
                // captured `func` so loaded bindings take effect even
                // for intrinsics already bound at startup (implicit
                // aliases, prior callsite caches, etc.).
                let effective = self.binding_override(fqn).unwrap_or(func);
                let mut ctx = CallCtx { args: &arg_vals, out };
                effective(&mut ctx)
            }
            Value::BoundMethod { fqn, func, receiver } => {
                let user_args = reorder_intrinsic_args(fqn, arg_vals, arg_names)?;
                let mut all = Vec::with_capacity(user_args.len() + 1);
                all.push(*receiver);
                all.extend(user_args);
                let effective = self.binding_override(fqn).unwrap_or(func);
                let mut ctx = CallCtx { args: &all, out };
                effective(&mut ctx)
            }
            Value::BoundUserMethod { receiver, method } => {
                self.call_method(&receiver, &method, &arg_vals, arg_names, out)
            }
            Value::Function { decl, env: captured } => {
                // Spec §4.2 implicit lambda labels: a lambda passed as an
                // argument may be exited via `return@<callee-name>`. Bind
                // the callee's simple name onto the lambda-label stack for
                // the duration of the call so lambdas executed inside the
                // user function recognize the label as their own.
                let pushed = simple_callee_name(callee).map(|s| s.to_string());
                if let Some(l) = &pushed {
                    self.implicit_lambda_label_stack.push(l.clone());
                }
                let r = self.call_function_named_spread(&decl, &captured, &arg_vals, arg_names, &is_spread_mask, out);
                if pushed.is_some() {
                    self.implicit_lambda_label_stack.pop();
                }
                r
            }
            Value::Lambda { params, body, env: captured, absorb_return } => {
                self.call_lambda_with_this(&params, &body, &captured, &arg_vals, None, absorb_return, out)
            }
            Value::Class(class) => {
                if class.is_fun_interface
                    && arg_vals.len() == 1
                    && matches!(arg_vals[0], Value::Lambda { .. })
                {
                    let lambda = arg_vals.into_iter().next().unwrap();
                    return self.sam_construct(&class, lambda, out);
                }
                self.construct_instance(&class, &arg_vals, arg_names, out)
            }
            Value::BoundInnerClass { class, outer } => {
                self.construct_instance_with_outer(
                    &class,
                    &arg_vals,
                    arg_names,
                    Some(Value::Instance(outer)),
                    out,
                )
            }
            Value::Instance(inst) => {
                // Spec §5.1.3 + ch.9: function-type supertypes contribute an
                // `invoke` slot, and any class declaring `operator fun
                // invoke(...)` is callable like a function. Member dispatch
                // first; extension `operator fun T.invoke(...)` second.
                let class = Rc::clone(&inst.borrow().class);
                if let Some((method, owner)) = class.find_method("invoke") {
                    return self.call_method_with_owner(
                        &inst,
                        &owner,
                        &method,
                        &arg_vals,
                        arg_names,
                        out,
                    );
                }
                let recv = Value::Instance(Rc::clone(&inst));
                if let Some(v) = self.try_extension_call_with_values(&recv, "invoke", &arg_vals, out)? {
                    return Ok(v);
                }
                Err(RuntimeError::Type(format!(
                    "`{}` is not callable",
                    Value::Instance(inst)
                )))
            }
            other => Err(RuntimeError::Type(format!("`{other}` is not callable"))),
        }
    }

    fn eval_prefix_incdec(
        &mut self,
        op: UnOp,
        target: &Expr,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let is_inc = matches!(op, UnOp::PreInc);
        let lvalue = self.lower_inc_dec_lvalue(target, env, out)?;
        let cur = self.read_inc_dec_lvalue(&lvalue, env, out)?;
        let next = self.apply_inc_dec(cur, is_inc, out)?;
        self.write_inc_dec_lvalue(&lvalue, next.clone(), env, out)?;
        Ok(next)
    }

    fn eval_postfix(
        &mut self,
        op: PostfixOp,
        target: &Expr,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match op {
            PostfixOp::Inc | PostfixOp::Dec => {
                let is_inc = matches!(op, PostfixOp::Inc);
                let lvalue = self.lower_inc_dec_lvalue(target, env, out)?;
                let cur = self.read_inc_dec_lvalue(&lvalue, env, out)?;
                let next = self.apply_inc_dec(cur.clone(), is_inc, out)?;
                self.write_inc_dec_lvalue(&lvalue, next, env, out)?;
                Ok(cur)
            }
            PostfixOp::NotNull => {
                let v = self.eval_expr(target, env, out)?;
                if matches!(v, Value::Null) {
                    Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Rc::new("kotlin.NullPointerException".into()),
                        message: None,
                        cause: None,
                    }))
                } else {
                    Ok(v)
                }
            }
        }
    }

    /// Spec ch.9: `x++` / `++x` / `x--` / `--x` evaluate the LHS spine
    /// once. For `xs[i][j]++`, both `xs[i]` and the inner index `j` are
    /// captured before the read/inc/write cycle runs. This helper resolves
    /// the LHS to a handle pinning those captures.
    fn lower_inc_dec_lvalue(
        &mut self,
        target: &Expr,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<IncDecLValue, RuntimeError> {
        match target {
            Expr::Path { segments, .. } if segments.len() == 1 => {
                Ok(IncDecLValue::Ident(segments[0].name.clone()))
            }
            Expr::Index { receiver, args, .. } => {
                let recv = self.eval_expr(receiver, env, out)?;
                let mut idxs = Vec::with_capacity(args.len());
                for a in args {
                    idxs.push(self.eval_expr(a, env, out)?);
                }
                Ok(IncDecLValue::Index { recv, idxs })
            }
            Expr::Member { receiver, name, safe: false, .. } => {
                let recv = self.eval_expr(receiver, env, out)?;
                Ok(IncDecLValue::Member { recv, name: name.name.clone() })
            }
            _ => Err(RuntimeError::Type(
                "++ / -- requires an identifier, indexed, or member target".into(),
            )),
        }
    }

    fn read_inc_dec_lvalue(
        &mut self,
        l: &IncDecLValue,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        match l {
            IncDecLValue::Ident(name) => self.read_ident_live(name, env),
            IncDecLValue::Index { recv, idxs } => {
                self.index_read_with_values(recv.clone(), idxs.clone(), out)
            }
            IncDecLValue::Member { recv, name } => {
                self.eval_property_access(recv.clone(), name, out)
            }
        }
    }

    fn write_inc_dec_lvalue(
        &mut self,
        l: &IncDecLValue,
        value: Value,
        env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        match l {
            IncDecLValue::Ident(name) => self.write_ident_live(name, value, env),
            IncDecLValue::Index { recv, idxs } => {
                self.assign_index(recv.clone(), idxs, AssignOp::Assign, value, out)?;
                Ok(())
            }
            IncDecLValue::Member { recv, name } => {
                self.write_member_value(recv.clone(), name, value, out)
            }
        }
    }

    /// Mirror of the index-read arm of `Expr::Index`, but starting from
    /// pre-evaluated receiver / index values. Used by inc/dec eval-once
    /// so the LHS spine is not re-evaluated.
    fn index_read_with_values(
        &mut self,
        recv: Value,
        idxs: Vec<Value>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        if let Value::Array { items, .. } = &recv {
            if idxs.len() != 1 {
                return Err(RuntimeError::Type(
                    "Array indexing takes one Int argument".into(),
                ));
            }
            let Some(i) = idxs[0].as_i64() else {
                return Err(RuntimeError::Type(
                    "Array indexing requires an Int".into(),
                ));
            };
            let items_ref = items.borrow();
            let n = items_ref.len() as i64;
            if i < 0 || i >= n {
                return Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Rc::new("kotlin.IndexOutOfBoundsException".to_string()),
                    message: Some(Rc::new(format!(
                        "Index {i} out of bounds for length {n}"
                    ))),
                    cause: None,
                }));
            }
            return Ok(items_ref[i as usize].clone());
        }
        let mut arg_vals = Vec::with_capacity(idxs.len() + 1);
        arg_vals.push(recv);
        arg_vals.extend(idxs);
        let fqn = format!("{}.get", arg_vals[0].type_fqn());
        if let Some(func) = self.lookup_intrinsic(&fqn) {
            let mut ctx = CallCtx { args: &arg_vals, out };
            return func(&mut ctx);
        }
        // User-class `operator fun get(...)` dispatch.
        if let Value::Instance(inst) = &arg_vals[0] {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method("get") {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    let args: Vec<Value> = arg_vals[1..].to_vec();
                    let names: Vec<Option<String>> = vec![None; args.len()];
                    return self.call_method(&inst, &m, &args, &names, out);
                }
            }
        }
        Err(RuntimeError::Unimplemented(fqn))
    }

    /// Mirror of the member-write arm of `Stmt::Assign`, but starting from
    /// a pre-evaluated receiver. Routes through delegated / extension
    /// property setters when applicable, falling back to direct field write.
    fn write_member_value(
        &mut self,
        recv: Value,
        name: &str,
        value: Value,
        out: &mut dyn Output,
    ) -> Result<(), RuntimeError> {
        if let Value::Instance(inst) = &recv {
            let class = Rc::clone(&inst.borrow().class);
            let pdef = class.find_body_property(name).map(|(p, _)| p);
            if let Some(pd) = &pdef {
                if pd.delegate.is_some() || pd.setter.is_some() {
                    self.write_instance_property(inst, pd, value, out)?;
                    return Ok(());
                }
            } else if self.find_extension_property(&recv, name).is_some() {
                self.try_extension_property_set(&recv, name, value, out)?;
                return Ok(());
            }
            inst.borrow_mut().define(name, value);
            return Ok(());
        }
        if self.find_extension_property(&recv, name).is_some() {
            self.try_extension_property_set(&recv, name, value, out)?;
            return Ok(());
        }
        Err(RuntimeError::Type(format!(
            "cannot assign to `.{name}` on non-instance receiver"
        )))
    }

    /// Spec ch.9 / delegated properties: if the delegate value's class
    /// declares `operator fun provideDelegate(thisRef, property)`, invoke
    /// it once at init time and return the call's result; otherwise pass
    /// the original through.
    fn maybe_provide_delegate(
        &mut self,
        dval: Value,
        this_ref: &Value,
        prop_name: &str,
        _env: &Rc<RefCell<Env>>,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let prop = Value::PropertyRef { name: Rc::new(prop_name.to_string()) };
        if let Value::Instance(inst) = &dval {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method("provideDelegate") {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    return self.call_method(
                        &inst,
                        &m,
                        &[this_ref.clone(), prop],
                        &[None, None],
                        out,
                    );
                }
            }
        }
        if let Some(v) = self.try_extension_call_with_values(
            &dval,
            "provideDelegate",
            &[this_ref.clone(), prop],
            out,
        )? {
            return Ok(v);
        }
        Ok(dval)
    }

    /// Apply `inc()` or `dec()`. Spec ch.9: user `operator fun inc / dec`
    /// (member or extension) wins over the built-in primitive arithmetic.
    fn apply_inc_dec(
        &mut self,
        v: Value,
        is_inc: bool,
        out: &mut dyn Output,
    ) -> Result<Value, RuntimeError> {
        let op_name = if is_inc { "inc" } else { "dec" };
        if let Value::Instance(inst) = &v {
            let class = Rc::clone(&inst.borrow().class);
            if let Some((m, _)) = class.find_method(op_name) {
                if m.decl.body.is_some() {
                    let inst = Rc::clone(inst);
                    return self.call_method(&inst, &m, &[], &[], out);
                }
            }
        }
        if let Some(r) = self.try_extension_call_with_values(&v, op_name, &[], out)? {
            return Ok(r);
        }
        match v {
            Value::Int(n) => Ok(Value::Int(if is_inc { n.wrapping_add(1) } else { n.wrapping_sub(1) })),
            Value::Long(n) => Ok(Value::Long(if is_inc { n.wrapping_add(1) } else { n.wrapping_sub(1) })),
            Value::Byte(n) => Ok(Value::Byte(if is_inc { n.wrapping_add(1) } else { n.wrapping_sub(1) })),
            Value::Short(n) => Ok(Value::Short(if is_inc { n.wrapping_add(1) } else { n.wrapping_sub(1) })),
            Value::Float(f) => Ok(Value::Float(if is_inc { f + 1.0 } else { f - 1.0 })),
            Value::Double(f) => Ok(Value::Double(if is_inc { f + 1.0 } else { f - 1.0 })),
            Value::Char(c) => {
                let code = c as u32;
                let next = if is_inc { code.wrapping_add(1) } else { code.wrapping_sub(1) };
                let nc = char::from_u32(next).ok_or_else(|| {
                    RuntimeError::Type("Char ++ / -- out of valid range".into())
                })?;
                Ok(Value::Char(nc))
            }
            other => Err(RuntimeError::Type(format!("`{op_name}` on {other:?}"))),
        }
    }

    /// Resolve an identifier read against live instance / companion / outer
    /// state (matches `Expr::Path` single-segment semantics) before falling
    /// back to the lexical env. Used by `++` / `--` and other operators.
    fn read_ident_live(
        &self,
        name: &str,
        env: &Rc<RefCell<Env>>,
    ) -> Result<Value, RuntimeError> {
        let name_hit = env.borrow().lookup_with_depth(name);
        let this_chain = env.borrow().lookup_all_with_depth("this");
        for (this_val, this_depth) in &this_chain {
            if let Some((v, d)) = &name_hit {
                if *d <= *this_depth {
                    return Ok(v.clone());
                }
            }
            if let Value::Instance(inst) = this_val {
                if let Some(v) = inst.borrow().get(name) {
                    return Ok(v);
                }
                let class = Rc::clone(&inst.borrow().class);
                for comp in class.all_companions() {
                    if let Some(v) = comp.borrow().get(name) {
                        return Ok(v);
                    }
                }
                let mut cur_outer = inst.borrow().outer.clone();
                while let Some(Value::Instance(oi)) = cur_outer {
                    if let Some(v) = oi.borrow().get(name) {
                        return Ok(v);
                    }
                    cur_outer = oi.borrow().outer.clone();
                }
            }
        }
        name_hit
            .map(|(v, _)| v)
            .ok_or_else(|| RuntimeError::Unbound(name.to_string()))
    }

    /// Write an identifier, preferring live instance / companion / outer
    /// state. Mirrors the write path in `Stmt::Assign`.
    fn write_ident_live(
        &self,
        name: &str,
        value: Value,
        env: &Rc<RefCell<Env>>,
    ) -> Result<(), RuntimeError> {
        let name_hit = env.borrow().lookup_with_depth(name);
        let this_chain = env.borrow().lookup_all_with_depth("this");
        for (this_val, this_depth) in &this_chain {
            if let Some((_, d)) = &name_hit {
                if *d <= *this_depth {
                    return env.borrow_mut().assign(name, value);
                }
            }
            if let Value::Instance(inst) = this_val {
                if inst.borrow().get(name).is_some() {
                    inst.borrow_mut().define(name, value);
                    return Ok(());
                }
                let class = Rc::clone(&inst.borrow().class);
                for comp in class.all_companions() {
                    if comp.borrow().get(name).is_some() {
                        comp.borrow_mut().define(name, value);
                        return Ok(());
                    }
                }
                let mut cur_outer = inst.borrow().outer.clone();
                while let Some(Value::Instance(oi)) = cur_outer {
                    if oi.borrow().get(name).is_some() {
                        oi.borrow_mut().define(name, value);
                        return Ok(());
                    }
                    cur_outer = oi.borrow().outer.clone();
                }
            }
        }
        env.borrow_mut().assign(name, value)
    }
}

impl Default for Interpreter {
    fn default() -> Self {
        Self::new()
    }
}

/// Iterate an integer progression. `step` is signed: positive iterates
/// forwards (inclusive end), negative iterates backwards. Zero step is
/// invalid and gives an empty iterator (callers should validate before).
/// Render a value as its string form for collection-shaped output. Strings
/// pass through unquoted; other values go through their `Display` impl.
/// Distinguished sentinel FQN stored on `Value::Exception` to mark an
/// uninitialized `lateinit var` slot. Reads see this and throw the proper
/// `kotlin.UninitializedPropertyAccessException` with a message naming the
/// property. Writes overwrite the slot, clearing the sentinel.
/// Resolve `Type.NAME` to the stdlib companion-object constant value.
/// Returns `None` for any name we don't intercept so the caller can
/// continue dispatching (stdlib FQN lookup, etc.).
fn primitive_companion_const(ty: &str, name: &str) -> Option<Value> {
    match (ty, name) {
        ("Int", "MAX_VALUE") => Some(Value::new_int(i32::MAX)),
        ("Int", "MIN_VALUE") => Some(Value::new_int(i32::MIN)),
        ("Int", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Int", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Long", "MAX_VALUE") => Some(Value::Long(i64::MAX)),
        ("Long", "MIN_VALUE") => Some(Value::Long(i64::MIN)),
        ("Long", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Long", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Short", "MAX_VALUE") => Some(Value::Short(i16::MAX)),
        ("Short", "MIN_VALUE") => Some(Value::Short(i16::MIN)),
        ("Short", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Short", "SIZE_BYTES") => Some(Value::new_int(2)),
        ("Byte", "MAX_VALUE") => Some(Value::Byte(i8::MAX)),
        ("Byte", "MIN_VALUE") => Some(Value::Byte(i8::MIN)),
        ("Byte", "SIZE_BITS") => Some(Value::new_int(8)),
        ("Byte", "SIZE_BYTES") => Some(Value::new_int(1)),
        ("Double", "MAX_VALUE") => Some(Value::Double(f64::MAX)),
        ("Double", "MIN_VALUE") => Some(Value::Double(f64::MIN_POSITIVE)),
        ("Double", "POSITIVE_INFINITY") => Some(Value::Double(f64::INFINITY)),
        ("Double", "NEGATIVE_INFINITY") => Some(Value::Double(f64::NEG_INFINITY)),
        ("Double", "NaN") => Some(Value::Double(f64::NAN)),
        ("Double", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Double", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Float", "MAX_VALUE") => Some(Value::Float(f32::MAX)),
        ("Float", "MIN_VALUE") => Some(Value::Float(f32::MIN_POSITIVE)),
        ("Float", "POSITIVE_INFINITY") => Some(Value::Float(f32::INFINITY)),
        ("Float", "NEGATIVE_INFINITY") => Some(Value::Float(f32::NEG_INFINITY)),
        ("Float", "NaN") => Some(Value::Float(f32::NAN)),
        ("Float", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Float", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Char", "MAX_VALUE") => Some(Value::Char('\u{FFFF}')),
        ("Char", "MIN_VALUE") => Some(Value::Char('\u{0}')),
        ("Char", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Char", "SIZE_BYTES") => Some(Value::new_int(2)),
        _ => None,
    }
}

/// Detect whether an expression is a syntactic "box-to-Any" form. Used
/// at `==` sites to switch Float/Double equality to bit-equality per
/// spec §8.9.2 (the `Any.equals` path matches JVM `Float.equals`).
/// Extract the `AnnotationRetention` value from `@Retention(...)`
/// in an annotation list. Returns `Some("SOURCE"|"BINARY"|"RUNTIME")`
/// when present, otherwise `None` (caller falls back to default).
fn extract_retention(annotations: &[klio_ast::Annotation]) -> Option<String> {
    for ann in annotations {
        let path_last = ann.path.last().map(|s| s.name.as_str()).unwrap_or("");
        if path_last != "Retention" {
            continue;
        }
        if let Some(arg) = ann.args.first() {
            // `@Retention(AnnotationRetention.RUNTIME)` (Member) or
            // `@Retention(RUNTIME)` (Path).
            let name = match arg {
                klio_ast::Expr::Path { segments, .. } => {
                    segments.last().map(|s| s.name.clone())
                }
                klio_ast::Expr::Member { name, .. } => Some(name.name.clone()),
                _ => None,
            };
            if let Some(n) = name {
                return Some(n);
            }
        }
    }
    None
}

fn is_boxed_to_any_form(expr: &Expr) -> bool {
    match expr {
        Expr::As { ty, .. } => {
            let name = &ty.name.name;
            matches!(name.as_str(), "Any" | "Number" | "kotlin.Any" | "kotlin.Number")
        }
        _ => false,
    }
}

/// True if `t` is a static type that boxes a primitive float — i.e. the
/// `==` expansion routes through `Any.equals` rather than `ieee754Equals`.
/// Spec §8.9.2: only the precise float/float static-typed form uses IEEE
/// semantics; anything that boxes (Any, Number, nullable Any?) uses
/// reference-equality / `Float.equals` (bit equality).
fn type_is_boxing_for_floats(t: &klio_types::Type) -> bool {
    use klio_types::Type;
    let inner = match t {
        Type::Nullable(i) => &**i,
        other => other,
    };
    matches!(inner, Type::Any)
}

const LATEINIT_SENTINEL_FQN: &str = "__klio_lateinit_uninitialized__";

/// Bind `this@<ClassName>` for the instance's own class name and every
/// ancestor class name in its hierarchy. Pre-existing bindings (e.g. a
/// closer enclosing scope already defined `this@Foo`) are preserved — the
/// inner scope wins per Kotlin's lexical resolution rules.
fn bind_qualified_this(env: &Rc<RefCell<Env>>, inst: &Rc<RefCell<InstanceData>>) {
    let class = Rc::clone(&inst.borrow().class);
    let mut cur: Option<Rc<ClassDef>> = Some(class);
    while let Some(c) = cur {
        if c.is_anonymous {
            cur = c.parent.borrow().clone();
            continue;
        }
        let qname = format!("this@{}", c.name);
        if env.borrow().lookup(&qname).is_none() {
            env.borrow_mut()
                .define(qname, Value::Instance(Rc::clone(inst)));
        }
        cur = c.parent.borrow().clone();
    }
}

fn make_lateinit_sentinel(name: &str) -> Value {
    Value::Exception {
        fqn: Rc::new(LATEINIT_SENTINEL_FQN.to_string()),
        message: Some(Rc::new(name.to_string())),
        cause: None,
    }
}

fn lateinit_sentinel_name(v: &Value) -> Option<String> {
    match v {
        Value::Exception { fqn, message, .. } if fqn.as_str() == LATEINIT_SENTINEL_FQN => {
            message.as_ref().map(|s| (**s).clone())
        }
        _ => None,
    }
}

fn lateinit_throw(name: &str) -> RuntimeError {
    RuntimeError::Thrown(Value::Exception {
        fqn: Rc::new("kotlin.UninitializedPropertyAccessException".to_string()),
        message: Some(Rc::new(format!(
            "lateinit property {name} has not been initialized"
        ))),
        cause: None,
    })
}

fn format_string_like(v: &Value) -> String {
    match v {
        Value::String(s) => (**s).clone(),
        other => format!("{other}"),
    }
}

/// Wrap a freshly-built `Vec<Value>` in either a `Sequence` (if the source
/// of the higher-order op was a `Sequence`) or a `List`. Used by the
/// collection HOF dispatcher so chained ops on a `Sequence` stay
/// `Sequence`-typed.
/// Per-op state for `materialize_sequence`. Take/Drop carry a remaining
/// counter; TakeWhile/DropWhile a flag; Distinct/DistinctBy a seen-set.
/// Other ops are stateless.
enum OpState {
    None,
    Counter(i64),
    Flag(bool),
    Seen(Vec<Value>),
}

impl OpState {
    fn for_op(op: &klio_runtime::SeqOp) -> Self {
        use klio_runtime::SeqOp;
        match op {
            SeqOp::Take(n) => Self::Counter(*n),
            SeqOp::Drop(n) => Self::Counter(*n),
            SeqOp::TakeWhile(_) => Self::Flag(false),
            SeqOp::DropWhile(_) => Self::Flag(true),
            SeqOp::Distinct => Self::Seen(Vec::new()),
            SeqOp::DistinctBy(_) => Self::Seen(Vec::new()),
            _ => Self::None,
        }
    }
}

/// Reorder a call's `(args, arg_names)` pair into a positional slot vector
/// keyed by the callable's `param_names`. Positional args (None in
/// `arg_names`) fill slots in source order; named args (Some(label)) jump
/// to the slot whose name matches. Slots left unset return `None` so the
/// caller can substitute defaults.
/// Splice spread entries into a positional argument list. Each `true` in
/// `mask` marks an argument that should be replaced by its elements (must
/// be a `Value::Array`). Used by intrinsics that don't carry a real
/// `vararg` parameter but still benefit from `*arr` flattening.
fn flatten_spreads(vals: Vec<Value>, mask: &[bool]) -> Vec<Value> {
    let mut out = Vec::with_capacity(vals.len());
    for (i, v) in vals.into_iter().enumerate() {
        if mask.get(i).copied().unwrap_or(false) {
            if let Value::Array { items, .. } = &v {
                for e in items.borrow().iter() {
                    out.push(e.clone());
                }
                continue;
            }
        }
        out.push(v);
    }
    out
}

fn reorder_named_args(
    args: &[Value],
    arg_names: &[Option<String>],
    param_names: &[&str],
    callee: &str,
) -> Result<Vec<Option<Value>>, RuntimeError> {
    let cap = args.len().max(param_names.len());
    let mut slots: Vec<Option<Value>> = std::iter::repeat_with(|| None).take(cap).collect();
    let mut pos_cursor = 0usize;
    for (i, v) in args.iter().enumerate() {
        let name = arg_names.get(i).and_then(|n| n.as_deref());
        let idx = if let Some(label) = name {
            let Some(found) = param_names.iter().position(|p| *p == label) else {
                return Err(RuntimeError::Arity(format!(
                    "`{callee}` has no parameter named `{label}`"
                )));
            };
            found
        } else {
            // Skip slots already filled by a prior named arg so positional
            // arguments don't clobber them.
            while pos_cursor < slots.len() && slots[pos_cursor].is_some() {
                pos_cursor += 1;
            }
            let here = pos_cursor;
            pos_cursor += 1;
            here
        };
        if idx >= slots.len() {
            slots.resize(idx + 1, None);
        }
        slots[idx] = Some(v.clone());
    }
    Ok(slots)
}

/// Reorder a flat `Vec<Value>` of user-positional args for an intrinsic
/// dispatched at `fqn`. No-op when no named labels are present. When the
/// registry has no param-name list for the FQN, the args pass through
/// unchanged — we rely on Kotlin's "positional first, named last" idiom
/// so positional order is already correct in that case.
fn reorder_intrinsic_args(
    fqn: &str,
    args: Vec<Value>,
    arg_names: &[Option<String>],
) -> Result<Vec<Value>, RuntimeError> {
    if !arg_names.iter().any(|n| n.is_some()) {
        return Ok(args);
    }
    let Some(params) = klio_stdlib::param_names(fqn) else {
        return Ok(args);
    };
    let slotted = reorder_named_args(&args, arg_names, params, fqn)?;
    let mut out: Vec<Value> = slotted.into_iter().map(|s| s.unwrap_or(Value::Null)).collect();
    while matches!(out.last(), Some(Value::Null)) {
        out.pop();
    }
    Ok(out)
}

fn is_sort_op(op: &klio_runtime::SeqOp) -> bool {
    use klio_runtime::SeqOp;
    matches!(op, SeqOp::Sorted(_) | SeqOp::SortedBy(_, _) | SeqOp::SortedWith(_))
}

/// Per-source state for `materialize_sequence`.
enum SourceState {
    Items { index: usize },
    Generate { last: Option<Value>, started: bool },
}

impl SourceState {
    fn new(source: &klio_runtime::SequenceSource) -> Self {
        match source {
            klio_runtime::SequenceSource::Items(_) => Self::Items { index: 0 },
            klio_runtime::SequenceSource::Generate { .. } => Self::Generate {
                last: None,
                started: false,
            },
        }
    }
}

fn wrap_collection(items: Vec<Value>, _as_sequence: bool) -> Value {
    // Sequence receivers are routed through the lazy sequence dispatcher,
    // so by the time we reach here the receiver was a List/Set/Map and we
    // want to return a List.
    Value::List { items: Rc::new(RefCell::new(items)), mutable: false, enum_class: None }
}

/// Pull the N components out of a value for destructuring assignment.
/// Supports `Pair`/`Triple`, `MapEntry`, `List`/`Set`, and user instances
/// with `componentN()` (data classes auto-generate these; plain classes
/// may declare them as `operator fun componentN()`).
fn destructure_components(
    interp: &mut Interpreter,
    value: &Value,
    slots: &[klio_ast::Ident],
    out: &mut dyn Output,
) -> Result<Vec<Value>, RuntimeError> {
    let n = slots.len();
    let pieces: Vec<Value> = match value {
        Value::Pair(a, b) => vec![(**a).clone(), (**b).clone()],
        Value::Triple(a, b, c) => vec![(**a).clone(), (**b).clone(), (**c).clone()],
        Value::MapEntry { key, value } => vec![(**key).clone(), (**value).clone()],
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        Value::Instance(inst) => {
            let class = Rc::clone(&inst.borrow().class);
            let env = interp.globals_ref();
            let mut out_vals = Vec::with_capacity(n);
            for (idx, slot) in slots.iter().enumerate() {
                // Spec ch.9: `_` placeholder skips the `componentK` call.
                if slot.name == "_" {
                    out_vals.push(Value::Unit);
                    continue;
                }
                let mname = format!("component{}", idx + 1);
                // Data classes synthesize componentN — handled by
                // `eval_instance_auto_member`.
                if let Some(v) = interp.eval_instance_auto_member(
                    inst, &mname, &[], &[], &env, out,
                )? {
                    out_vals.push(v);
                    continue;
                }
                if let Some((m, _o)) = class.find_method(&mname) {
                    let v = interp.call_method(inst, &m, &[], &[], out)?;
                    out_vals.push(v);
                    continue;
                }
                return Err(RuntimeError::Unimplemented(format!(
                    "{}.{mname}",
                    class.fqn
                )));
            }
            return Ok(out_vals);
        }
        other => {
            return Err(RuntimeError::Type(format!(
                "cannot destructure {other:?}"
            )))
        }
    };
    if pieces.len() < n {
        return Err(RuntimeError::Type(format!(
            "destructuring expects {n} components, got {}",
            pieces.len()
        )));
    }
    Ok(pieces.into_iter().take(n).collect())
}

/// Runtime `x in y` membership test. Supported operands:
///   * `Int in Range` — honors step direction.
///   * `Any in List/Set` — structural equality.
///   * `Any in Map` — key membership.
///   * `String/Char in String` — substring/contains.
/// Short simple-name for a Value's runtime type, used for overload
/// resolution by argument type. Picks the kind a user would write in a
/// type annotation (`Int` for primitives, `IntRange` for typed ranges,
/// the class's simple name for instances).
/// Pick the most specific overload from a set of candidate
/// top-level function declarations against the supplied argument
/// values. Returns `None` when no candidate is admissible (arity
/// mismatch on every entry, no compatible type pair). The score
/// is the sum of per-parameter mismatch costs:
///
/// * 0 — declared parameter type names an exact match for the
///   argument's runtime type.
/// * 1 — declared parameter type is a numeric supertype (`Number`,
///   `Any`, `Any?`, `Comparable`) or a generic type parameter.
/// * 2 — any other admissible widening (e.g. `Int` argument vs
///   `Long` parameter promotes via Kotlin's arithmetic conversion).
///
/// Candidates with any incompatible parameter slot are rejected.
/// Ties on score break on declaration order (first wins) so the
/// resolution is deterministic across runs.
fn select_overload(
    candidates: &[(Rc<klio_ast::Function>, Rc<RefCell<Env>>)],
    args: &[Value],
    arg_names: &[Option<String>],
) -> Option<(Rc<klio_ast::Function>, Rc<RefCell<Env>>)> {
    let mut best: Option<(usize, usize)> = None;
    for (i, (decl, _env)) in candidates.iter().enumerate() {
        let Some(score) = overload_score(decl, args, arg_names) else {
            continue;
        };
        match best {
            Some((cur_score, _)) if cur_score <= score => {}
            _ => best = Some((score, i)),
        }
    }
    best.map(|(_, i)| (Rc::clone(&candidates[i].0), Rc::clone(&candidates[i].1)))
}

fn overload_score(
    decl: &klio_ast::Function,
    args: &[Value],
    arg_names: &[Option<String>],
) -> Option<usize> {
    // Named arguments are not yet folded into overload scoring;
    // fall through to env dispatch when any are supplied. Common
    // overload sites (atomicfu / kotlinx primitives) use positional
    // args exclusively.
    if arg_names.iter().any(|n| n.is_some()) {
        return None;
    }
    let n_required = decl.params.iter().filter(|p| p.default.is_none() && !p.is_vararg).count();
    let n_max = decl.params.len();
    let has_vararg = decl.params.iter().any(|p| p.is_vararg);
    if !has_vararg && args.len() > n_max {
        return None;
    }
    if args.len() < n_required {
        return None;
    }
    let mut total = 0usize;
    for (i, arg) in args.iter().enumerate() {
        let param_idx = i.min(n_max.saturating_sub(1));
        let Some(param) = decl.params.get(param_idx) else {
            return None;
        };
        let cost = param_cost(&param.ty.name.name, arg)?;
        total = total.saturating_add(cost);
    }
    Some(total)
}

fn param_cost(param_type: &str, arg: &Value) -> Option<usize> {
    let arg_name = value_runtime_type_name(arg);
    if param_type == arg_name {
        return Some(0);
    }
    // Anything matches a generic type parameter (single uppercase
    // identifier) or Any/Any? — but pay a higher cost so concrete
    // matches win.
    if is_generic_param_name(param_type) || param_type == "Any" {
        return Some(3);
    }
    // Numeric widening: Int -> Long, Int -> Double, Int -> Float,
    // Float -> Double. Kotlin's overload resolution treats these as
    // admissible-with-cost; an exact match beats a widening.
    match (param_type, arg_name.as_str()) {
        ("Long", "Int")
        | ("Double", "Int" | "Long" | "Float")
        | ("Float", "Int" | "Long")
        | ("Number", "Int" | "Long" | "Short" | "Byte" | "Float" | "Double") => Some(2),
        ("Comparable", "Int" | "Long" | "Short" | "Byte" | "Float" | "Double" | "Char" | "String") => Some(2),
        // Nullable / specific user-class identity is handled by
        // value_runtime_type_name returning the class simple name.
        // Falling through means the candidate is rejected.
        _ => None,
    }
}

fn is_generic_param_name(s: &str) -> bool {
    let mut chars = s.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_uppercase()) && chars.next().is_none()
}

fn value_runtime_type_name(v: &Value) -> String {
    match v {
        Value::Instance(i) => i.borrow().class.name.clone(),
        Value::Range { kind, step, .. } => {
            let base = match kind {
                klio_runtime::RangeKind::Int => "IntRange",
                klio_runtime::RangeKind::Long => "LongRange",
                klio_runtime::RangeKind::Char => "CharRange",
            };
            if *step == 1 {
                base.to_string()
            } else {
                base.replace("Range", "Progression")
            }
        }
        _ => {
            let fqn = v.type_fqn();
            fqn.rsplit('.').next().unwrap_or(fqn).to_string()
        }
    }
}

fn value_in(needle: &Value, haystack: &Value) -> Result<bool, RuntimeError> {
    match (needle, haystack) {
        (Value::Char(c), Value::Range { start, end, step, kind: klio_runtime::RangeKind::Char }) => {
            let n = *c as i64;
            if *step == 0 {
                return Ok(false);
            }
            if *step > 0 {
                Ok(n >= *start && n <= *end && (n - *start) % *step == 0)
            } else {
                Ok(n <= *start && n >= *end && (*start - n) % (-*step) == 0)
            }
        }
        (n, Value::Range { start, end, step, .. }) if n.is_integral() => {
            let n = &n.as_i64().unwrap();
            if *step == 0 {
                return Ok(false);
            }
            if *step > 0 {
                Ok(*n >= *start && *n <= *end && (*n - *start) % *step == 0)
            } else {
                Ok(*n <= *start && *n >= *end && (*start - *n) % (-*step) == 0)
            }
        }
        // Ranges are typed (`IntRange`, `LongRange`, …). A non-matching
        // needle simply doesn't belong — return `false` rather than erroring
        // so `when (x: Any) { in 1..10 -> … }` works.
        (_, Value::Range { .. }) => Ok(false),
        (v, Value::List { items, .. }) | (v, Value::Set { items, .. }) => {
            Ok(items.borrow().iter().any(|x| Value::structural_eq(x, v)))
        }
        (v, Value::Map { entries, .. }) => Ok(entries
            .borrow()
            .iter()
            .any(|(k, _)| Value::structural_eq(k, v))),
        (Value::String(needle_s), Value::String(hay_s)) => Ok(hay_s.contains(needle_s.as_str())),
        (Value::Char(c), Value::String(hay_s)) => Ok(hay_s.contains(*c)),
        _ => Err(RuntimeError::Type(format!(
            "`in` requires a Range or collection, got needle={needle:?} haystack={haystack:?}"
        ))),
    }
}

fn range_iter(start: i64, end: i64, step: i64) -> Box<dyn Iterator<Item = i64>> {
    if step == 0 {
        return Box::new(std::iter::empty());
    }
    if step > 0 {
        if start > end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur > end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    } else {
        if start < end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur < end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    }
}

fn choose_extreme(name: &str, a: Value, b: Value) -> Result<Value, RuntimeError> {
    let cmp = match (&a, &b) {
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Double(x), Value::Double(y)) => {
            x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal)
        }
        (Value::Int(x), Value::Double(y)) => (*x as f64)
            .partial_cmp(y)
            .unwrap_or(std::cmp::Ordering::Equal),
        (Value::Double(x), Value::Int(y)) => x
            .partial_cmp(&(*y as f64))
            .unwrap_or(std::cmp::Ordering::Equal),
        (Value::String(x), Value::String(y)) => klio_stdlib::compare_utf16(x, y),
        (Value::Char(x), Value::Char(y)) => x.cmp(y),
        _ => return Err(RuntimeError::Type(format!(
            "{name} selector must return a comparable value (Int / Double / String / Char)"
        ))),
    };
    Ok(match (name, cmp) {
        ("maxOf", std::cmp::Ordering::Less) => b,
        ("maxOf", _) => a,
        ("minOf", std::cmp::Ordering::Greater) => b,
        ("minOf", _) => a,
        _ => unreachable!(),
    })
}

fn value_hash(v: &Value) -> i64 {
    if let Some(n) = v.as_i64() {
        return n;
    }
    match v {
        Value::Bool(b) => if *b { 1 } else { 0 },
        Value::Null => 0,
        Value::String(s) => {
            let mut h: i64 = 0;
            for c in s.chars() {
                h = h.wrapping_mul(31).wrapping_add(c as i64);
            }
            h
        }
        Value::Char(c) => *c as i64,
        Value::Double(d) => d.to_bits() as i64,
        Value::Class(c) => {
            let mut h: i64 = 0;
            for ch in c.fqn.chars() {
                h = h.wrapping_mul(31).wrapping_add(ch as i64);
            }
            h
        }
        _ => 0,
    }
}

/// Walk an assignment LHS toward its leaves and return the receiver
/// expression of the innermost `safe: true` `Expr::Member`, if any. The
/// "spine" includes the chain of `Member.receiver` and `Index.receiver`
/// links, mirroring the shapes the parser produces for navigation
/// expressions. `Path` / other leaf nodes terminate the walk.
fn innermost_safe_lhs_receiver(e: &Expr) -> Option<Expr> {
    match e {
        Expr::Member { receiver, safe, .. } => {
            // Descend first — we want the safe operator closest to the leaf
            // receiver so the rewrite peels one operator at a time.
            if let Some(found) = innermost_safe_lhs_receiver(receiver) {
                return Some(found);
            }
            if *safe {
                return Some((**receiver).clone());
            }
            None
        }
        Expr::Index { receiver, .. } => innermost_safe_lhs_receiver(receiver),
        _ => None,
    }
}

/// Deep-clone `e` and replace the innermost `Expr::Member { safe: true, .. }`
/// in the LHS spine with the same Member node carrying `safe: false` and a
/// freshly-bound `Path[tmp_name]` receiver. The recursion is in lock-step
/// with `innermost_safe_lhs_receiver` so the substitution targets the same
/// node that produced the receiver value.
fn rewrite_dropping_innermost_safe(e: &Expr, tmp_name: &str) -> Expr {
    match e {
        Expr::Member { receiver, name, safe, span } => {
            // If a deeper safe exists, recurse so we drop that one first.
            if innermost_safe_lhs_receiver(receiver).is_some() {
                let new_recv = rewrite_dropping_innermost_safe(receiver, tmp_name);
                return Expr::Member {
                    receiver: Box::new(new_recv),
                    name: name.clone(),
                    safe: *safe,
                    span: *span,
                };
            }
            if *safe {
                return Expr::Member {
                    receiver: Box::new(Expr::Path {
                        segments: vec![klio_ast::Ident { name: tmp_name.to_string(), span: *span }],
                        span: *span,
                    }),
                    name: name.clone(),
                    safe: false,
                    span: *span,
                };
            }
            // Should not happen — caller checked the spine had a safe node.
            e.clone()
        }
        Expr::Index { receiver, args, span } => {
            let new_recv = rewrite_dropping_innermost_safe(receiver, tmp_name);
            Expr::Index {
                receiver: Box::new(new_recv),
                args: args.clone(),
                span: *span,
            }
        }
        _ => e.clone(),
    }
}

fn compound_to_binop(op: AssignOp) -> BinOp {
    match op {
        AssignOp::Add => BinOp::Add,
        AssignOp::Sub => BinOp::Sub,
        AssignOp::Mul => BinOp::Mul,
        AssignOp::Div => BinOp::Div,
        AssignOp::Rem => BinOp::Rem,
        AssignOp::Assign => unreachable!(),
    }
}


/// Intern a runtime-built FQN so we can hand back a `&'static str` to
/// callers that expect it. Used sparingly — most FQNs are static literals
/// in the stdlib table.
fn leak_fqn(s: &str) -> &'static str {
    Box::leak(s.to_string().into_boxed_str())
}

/// Returns the bare identifier name for `f(...)`-style calls where the
/// callee is a single-segment path.
/// Walk a class and its ancestors for a nested-class declaration whose
/// simple name matches `name`. Returns the resolved `ClassDef`.
/// Collect simple names of every method declared on an interface and its
/// transitively-inherited interfaces. Used to seed inheritance-delegation
/// forwarder synthesis: every interface member not overridden on the
/// implementing class is routed to the delegate.
fn collect_interface_member_names(
    iface: &Rc<ClassDef>,
    out: &mut Vec<String>,
    seen: &mut Vec<*const ClassDef>,
) {
    let ptr = Rc::as_ptr(iface);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return;
    }
    seen.push(ptr);
    for m in &iface.methods {
        if !out.iter().any(|n| n == &m.name) {
            out.push(m.name.clone());
        }
    }
    for parent in iface.interfaces.borrow().iter() {
        collect_interface_member_names(parent, out, seen);
    }
}

fn collect_interface_property_names(
    iface: &Rc<ClassDef>,
    out: &mut Vec<String>,
    seen: &mut Vec<*const ClassDef>,
) {
    let ptr = Rc::as_ptr(iface);
    if seen.iter().any(|p| *p == ptr) || seen.len() > 128 {
        return;
    }
    seen.push(ptr);
    for p in &iface.body_properties {
        if !out.iter().any(|n| n == &p.name) {
            out.push(p.name.clone());
        }
    }
    for parent in iface.interfaces.borrow().iter() {
        collect_interface_property_names(parent, out, seen);
    }
}

fn lookup_nested_class(cls: &Rc<ClassDef>, name: &str) -> Option<Rc<ClassDef>> {
    let mut cur = Some(Rc::clone(cls));
    let mut steps = 0;
    while let Some(c) = cur {
        if steps > 64 {
            return None;
        }
        steps += 1;
        for (n, nc) in c.nested_classes.borrow().iter() {
            if n == name {
                return Some(Rc::clone(nc));
            }
        }
        cur = c.parent.borrow().clone();
    }
    None
}

/// Materialise a `Value::Range` into a flat Vec the IR's
/// iterator protocol can drive.
fn materialise_range_items(
    start: i64,
    end: i64,
    step: i64,
    kind: klio_runtime::RangeKind,
) -> Vec<klio_runtime::Value> {
    use klio_runtime::{RangeKind, Value};
    let mut out: Vec<Value> = Vec::new();
    let mut cur = start;
    if step > 0 {
        while cur <= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u8 as char)),
            }
            cur = cur.saturating_add(step);
            if cur > end && step > 0 {
                break;
            }
        }
    } else if step < 0 {
        while cur >= end {
            match kind {
                RangeKind::Int => out.push(Value::new_int(cur)),
                RangeKind::Long => out.push(Value::Long(cur)),
                RangeKind::Char => out.push(Value::Char(cur as u8 as char)),
            }
            cur = cur.saturating_add(step);
            if cur < end {
                break;
            }
        }
    }
    out
}

/// Sentinel `StdlibFn` for IR coroutine intrinsics — never invoked
/// directly because `IrHost::call_value` intercepts the matching
/// FQN before falling through to the function pointer.
fn ir_intrinsic_stub(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Err(RuntimeError::Type(
        "ir_intrinsic_stub invoked directly — IR host should have intercepted".into(),
    ))
}

thread_local! {
    /// Active IR closure registry. IrHost::build_closure stashes
    /// the `(module, body_func)` triple per IR-closure id; the
    /// runtime's invoke path looks it up when it encounters a
    /// `Value::IrClosure` so the tree-walker dispatch (repeat,
    /// let, apply, etc.) can invoke closures built by the IR.
    static IR_CLOSURE_TABLE: RefCell<Vec<Option<IrClosureSlot>>> = const { RefCell::new(Vec::new()) };
}

/// Public hook the runtime invokes when it encounters an
/// `Value::IrClosure`. Returns the call result by re-entering the
/// IR evaluator against the stashed module + body func + captures.
pub fn invoke_ir_closure(
    id: u64,
    captures: &[Value],
    args: &[Value],
    out: &mut dyn Output,
) -> Option<Result<Value, RuntimeError>> {
    let slot = IR_CLOSURE_TABLE.with(|t| t.borrow().get(id as usize).cloned().flatten())?;
    let func = slot.module.funcs.get(slot.body_func.0 as usize)?.clone();
    let interp_ptr = std::ptr::null_mut::<Interpreter>();
    // We can't fabricate a fresh &mut Interpreter here. Callers
    // that need full interpreter machinery use the IrHost path
    // directly. For dispatch from inside invoke_callable_value we
    // can synthesise a minimal NullHost — closures that only do
    // pure arithmetic + bound captures still work, which is
    // sufficient for the `repeat(5) { i -> ... }` shape that
    // motivates this hook.
    let _ = interp_ptr;
    let mut host = klio_ir::eval::NullHost;
    let result = klio_ir::eval::eval_with_captures(
        &slot.module,
        &func,
        args.to_vec(),
        captures.to_vec(),
        &mut host,
    );
    let _ = out;
    match result {
        Ok(v) => Some(Ok(v)),
        Err(e) => Some(Err(RuntimeError::Type(e.to_string()))),
    }
}

/// Bridge the IR evaluator back to this interpreter for dispatch
/// that requires the real class table / dispatch machinery.
struct IrHost<'a> {
    interp: &'a mut Interpreter,
    out: &'a mut dyn Output,
    /// Class names indexed by ClassId so NewInstance can resolve
    /// against the interpreter's class_table without re-walking
    /// the IR module.
    class_names: Vec<String>,
    /// Closure side-table — Value::IrClosure carries the slot id;
    /// the host materialises (module_ptr, body_func) at call time.
    closures: Vec<IrClosureSlot>,
}

#[derive(Clone)]
struct IrClosureSlot {
    body_func: klio_ir::FuncId,
    // The module pointer lives inside run_ir; we stash a raw clone
    // since IR Module is Clone. Captures travel with the value.
    module: std::rc::Rc<klio_ir::Module>,
}

impl<'a> klio_ir::eval::Host for IrHost<'a> {
    fn lookup_global(&mut self, name: &str) -> Option<klio_runtime::Value> {
        if let Some(v) = self.interp.lookup_global_callable(name) {
            return Some(v);
        }
        // Special-case the interpreter's name-recognised
        // suspend / coroutine intrinsics so the IR call path can
        // route them back through the tree walker's machinery via
        // a synthetic Value::Intrinsic sentinel that
        // `call_value` intercepts below.
        match name {
            "runBlocking" => {
                return Some(klio_runtime::Value::Intrinsic {
                    fqn: "__klio_intrinsic_runBlocking",
                    func: ir_intrinsic_stub,
                });
            }
            "suspendCoroutine"
            | "suspendCoroutineUninterceptedOrReturn"
            | "suspendCancellableCoroutine" => {
                return Some(klio_runtime::Value::Intrinsic {
                    fqn: "__klio_intrinsic_suspendCoroutine",
                    func: ir_intrinsic_stub,
                });
            }
            _ => {}
        }
        // Probe the stdlib registry by simple name. A common idiom
        // is `repeat(5) { ... }` / `listOf(1, 2)` / `println(...)` —
        // these resolve to FQNs like `kotlin.repeat` /
        // `kotlin.collections.listOf` / `kotlin.io.println`.
        let candidate_fqns: &[String] = &[
            format!("kotlin.{name}"),
            format!("kotlin.io.{name}"),
            format!("kotlin.collections.{name}"),
            format!("kotlin.ranges.{name}"),
            format!("kotlin.text.{name}"),
            format!("kotlin.math.{name}"),
        ];
        for fqn in candidate_fqns {
            if let Some(f) = self.interp.lookup_intrinsic(fqn) {
                let leaked: &'static str = Box::leak(fqn.clone().into_boxed_str());
                return Some(klio_runtime::Value::Intrinsic {
                    fqn: leaked,
                    func: f,
                });
            }
        }
        // Scope functions and higher-order helpers
        // (`repeat` / `let` / `apply` / `also` / `with` / `run` /
        // `takeIf` / `takeUnless` / `require` / `check` /
        // `requireNotNull` / `checkNotNull` / `error` / `TODO`)
        // are name-dispatched inside the tree walker's eval_call
        // rather than registered intrinsics. Return a sentinel so
        // call_value can route them through eval_via_ast below.
        match name {
            "repeat" | "let" | "apply" | "also" | "with" | "run"
            | "takeIf" | "takeUnless" | "require" | "check"
            | "requireNotNull" | "checkNotNull" | "error" | "TODO"
            | "listOf" | "mutableListOf" | "arrayOf" | "setOf"
            | "mapOf" | "mutableMapOf" | "mutableSetOf"
            // Built-in array constructors (one-arg + init-lambda forms).
            | "IntArray" | "LongArray" | "ShortArray" | "ByteArray"
            | "DoubleArray" | "FloatArray" | "BooleanArray" | "CharArray"
            | "UIntArray" | "ULongArray" | "UShortArray" | "UByteArray"
            | "Array"
            // Pair / Triple / `to` infix
            | "Pair" | "Triple" | "to"
            // kotlin.comparisons + ranges helpers
            | "compareBy" | "compareByDescending" | "naturalOrder" | "reverseOrder"
            | "thenBy" | "thenByDescending"
            // Sequence builders + common range helpers
            | "sequenceOf" | "sequence" | "emptyList" | "emptyMap" | "emptySet"
            | "lazyOf" | "lazy" | "buildList" | "buildSet" | "buildMap" | "buildString"
            | "println" | "print" | "readLine"
            | "minOf" | "maxOf" | "abs"
            | "synchronized"
            | "tailrec"
            | "objects" => {
                let leaked: &'static str =
                    Box::leak(format!("__klio_intrinsic_name:{name}").into_boxed_str());
                Some(klio_runtime::Value::Intrinsic {
                    fqn: leaked,
                    func: ir_intrinsic_stub,
                })
            }
            _ => None,
        }
    }

    fn call_value_named(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Route Value::Intrinsic calls through the tree walker's
        // eval_call path so its intrinsic-specific preprocessing
        // (the println/print Instance→toString rewrite, reorder
        // by intrinsic param names, spread flattening) fires.
        if let klio_runtime::Value::Intrinsic { fqn, .. } = callee {
            // Skip the sentinel FQNs handled in call_value below.
            if !fqn.starts_with("__klio_intrinsic_") {
                // Reconstruct a simple-name dispatch through
                // invoke_named_intrinsic_with_names. We pick the
                // last path-segment after the final '.' as the
                // dispatch name so kotlin.io.println → println.
                let simple = fqn.rsplit('.').next().unwrap_or(*fqn);
                return self
                    .interp
                    .invoke_named_intrinsic_with_names(simple, args, arg_names, self.out)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
        }
        let _ = arg_names;
        self.call_value(callee, args)
    }

    fn call_member_named(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        if arg_names.iter().any(|n| n.is_some()) {
            return self
                .interp
                .invoke_named_member_call_with_names(receiver, name, args, arg_names, self.out)
                .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
        }
        self.call_member(receiver, name, args)
    }

    fn new_instance_named(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let name = self
            .class_names
            .get(class.0 as usize)
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "IR ClassId {} not in module index",
                    class.0
                ))
            })?
            .clone();
        self.interp
            .construct_by_name_with_names(&name, args, arg_names, self.out)
            .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()))
    }

    fn call_value(
        &mut self,
        callee: &klio_runtime::Value,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Interpreter-side coroutine intrinsics: detect via the
        // sentinel FQN we stuffed into lookup_global and route to
        // the matching tree-walker entry point. runBlocking takes
        // exactly one lambda arg; the suspend intrinsics also take
        // a lambda arg that runs against a continuation.
        if let klio_runtime::Value::Intrinsic { fqn, .. } = callee {
            // Name-dispatched scope / builder intrinsics route
            // back through the tree walker by synthesising a Call
            // expression and re-running it. Heavy but it lets the
            // IR path cover stdlib surface area that lives in
            // eval_call rather than the registered intrinsic table.
            if let Some(simple) = fqn.strip_prefix("__klio_intrinsic_name:") {
                return self
                    .interp
                    .invoke_named_intrinsic(simple, args, self.out)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
            match *fqn {
                "__klio_intrinsic_runBlocking" => {
                    if args.len() != 1 {
                        return Err(klio_ir::eval::EvalError::Type(
                            "runBlocking expects one lambda".into(),
                        ));
                    }
                    // IR closures need their own invocation path
                    // (run_blocking only knows the AST-Lambda
                    // shape). Call the closure directly — klio is
                    // single-threaded so the body runs to
                    // completion inline, matching the tree-walker
                    // runBlocking semantics for synchronous bodies.
                    if matches!(&args[0], klio_runtime::Value::IrClosure { .. }) {
                        return self.call_value(&args[0], &[]);
                    }
                    return self
                        .interp
                        .run_blocking(&args[0], self.out)
                        .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
                }
                "__klio_intrinsic_suspendCoroutine" => {
                    if args.len() != 1 {
                        return Err(klio_ir::eval::EvalError::Type(
                            "suspendCoroutine expects one lambda".into(),
                        ));
                    }
                    return self
                        .interp
                        .eval_suspend_coroutine(&args[0], self.out)
                        .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
                }
                _ => {}
            }
        }
        // Top-level Value::Function callees may be one of an
        // overload set; the captured-name in globals only points
        // at the most-recently-defined one. Route through the
        // tree walker's name-based dispatch so overload
        // resolution picks the right arity / arg-type match.
        if let klio_runtime::Value::Function { decl, .. } = callee {
            let name = decl.name.name.clone();
            if self.interp.has_top_level_overloads(&name) {
                return self
                    .interp
                    .invoke_named_intrinsic(&name, args, self.out)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
        }
        // Value::Class callee → constructor call. Dispatch through
        // construct_by_name with the class's simple name. Covers
        // pack-imported classes (Buffer, Instant, HttpClient) that
        // the IR module's class_index doesn't see.
        if let klio_runtime::Value::Class(class) = callee {
            return self
                .interp
                .construct_by_name(&class.name, args, self.out)
                .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
        }
        // IrClosure callees dispatch back into the IR evaluator
        // with captures appended to the positional args.
        if let klio_runtime::Value::IrClosure { id, captures } = callee {
            let slot = self
                .closures
                .get(*id as usize)
                .cloned()
                .ok_or_else(|| {
                    klio_ir::eval::EvalError::Type(format!("unknown IrClosure id {id}"))
                })?;
            let body = slot.module.funcs[slot.body_func.0 as usize].clone();
            let mut child = IrHost {
                interp: self.interp,
                out: self.out,
                class_names: self.class_names.clone(),
                closures: self.closures.clone(),
            };
            return klio_ir::eval::eval_with_captures(
                &slot.module,
                &body,
                args.to_vec(),
                captures.iter().cloned().collect(),
                &mut child,
            );
        }
        let names: Vec<Option<String>> = vec![None; args.len()];
        self.interp
            .invoke_callable_value(callee, args, &names, self.out)
            .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()))
    }

    fn build_ast_lambda(
        &mut self,
        params: &[String],
        body: &klio_ast::Block,
        captured_names: &[String],
        captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Materialise a Value::Lambda whose captured env contains
        // the names → values snapshot. The tree walker's
        // call_lambda path then dispatches the body exactly like
        // any other lambda.
        let env = Rc::new(RefCell::new(klio_runtime::Env::with_parent(Rc::clone(&self.interp.globals))));
        for (name, value) in captured_names.iter().zip(captures.iter()) {
            env.borrow_mut().define(name.clone(), value.clone());
        }
        Ok(klio_runtime::Value::Lambda {
            params: Rc::new(params.to_vec()),
            body: Rc::new(body.clone()),
            env,
            absorb_return: false,
        })
    }

    fn build_closure(
        &mut self,
        module: &klio_ir::Module,
        body_func: klio_ir::FuncId,
        captures: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let id = self.closures.len() as u64;
        let slot = IrClosureSlot {
            body_func,
            module: std::rc::Rc::new(module.clone()),
        };
        self.closures.push(slot.clone());
        // Mirror the slot into the thread-local registry so the
        // tree-walker's invoke_callable_value can resolve the
        // closure when it dispatches `repeat { … }` etc. that
        // expected a Value::Lambda but got Value::IrClosure.
        IR_CLOSURE_TABLE.with(|t| {
            let mut b = t.borrow_mut();
            while b.len() <= id as usize {
                b.push(None);
            }
            b[id as usize] = Some(slot);
        });
        Ok(klio_runtime::Value::IrClosure {
            id,
            captures: std::rc::Rc::new(captures),
        })
    }

    fn call_func(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        self.call_func_named(module, func, args, &[])
    }

    fn call_func_named(
        &mut self,
        module: &klio_ir::Module,
        func: klio_ir::FuncId,
        args: Vec<klio_runtime::Value>,
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let f = module
            .funcs
            .get(func.0 as usize)
            .ok_or_else(|| klio_ir::eval::EvalError::Type(format!("unknown FuncId {}", func.0)))?;
        // Route through the tree walker by simple-name dispatch when
        // there are named args, defaults, or overloads — the IR's
        // direct eval_with doesn't yet handle parameter defaults
        // or overload resolution. Falls through to the eval path
        // for nameless / arity-equal calls so simple functions
        // still benefit from the IR's tight loop.
        let name = f.name.clone();
        let has_names = arg_names.iter().any(|n| n.is_some());
        let has_defaults = f.params.iter().any(|p| p.default.is_some());
        let has_overloads = self.interp.has_top_level_overloads(&name);
        if has_names || has_defaults || has_overloads || arg_names.len() == args.len() && args.len() < f.params.len() {
            return self
                .interp
                .invoke_named_intrinsic_with_names(&name, &args, arg_names, self.out)
                .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
        }
        let f = f.clone();
        let mut child = IrHost {
            interp: self.interp,
            out: self.out,
            class_names: self.class_names.clone(),
            closures: self.closures.clone(),
        };
        klio_ir::eval::eval_with(module, &f, args, &mut child)
    }

    fn call_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Iterator-protocol primitives for ranges, arrays, lists,
        // maps and sets. The tree walker's `for-in` is special-
        // cased in eval_call; the IR lowers For to explicit
        // iterator/hasNext/next CallMember insts so the same dispatch
        // applies. Implement the protocol here so the IR-side
        // for-loop runs against built-in collection shapes without
        // each shape needing its own member-method registration.
        match (receiver, name) {
            (klio_runtime::Value::Range { start, end, step, kind }, "iterator") => {
                let items: Vec<klio_runtime::Value> =
                    materialise_range_items(*start, *end, *step, *kind);
                return Ok(klio_runtime::Value::Iterator {
                    items: std::rc::Rc::new(std::cell::RefCell::new(items)),
                    pos: std::rc::Rc::new(std::cell::RefCell::new(0)),
                    prim: None,
                });
            }
            (klio_runtime::Value::List { items, .. }, "iterator") => {
                return Ok(klio_runtime::Value::Iterator {
                    items: std::rc::Rc::clone(items),
                    pos: std::rc::Rc::new(std::cell::RefCell::new(0)),
                    prim: None,
                });
            }
            (klio_runtime::Value::Array { items, prim }, "iterator") => {
                return Ok(klio_runtime::Value::Iterator {
                    items: std::rc::Rc::clone(items),
                    pos: std::rc::Rc::new(std::cell::RefCell::new(0)),
                    prim: *prim,
                });
            }
            (klio_runtime::Value::Iterator { items, pos, .. }, "hasNext") => {
                let has = *pos.borrow() < items.borrow().len();
                return Ok(klio_runtime::Value::Bool(has));
            }
            (klio_runtime::Value::Iterator { items, pos, .. }, "next") => {
                let i = *pos.borrow();
                *pos.borrow_mut() = i + 1;
                let v = items.borrow().get(i).cloned().unwrap_or(klio_runtime::Value::Unit);
                return Ok(v);
            }
            (klio_runtime::Value::Array { items, .. }, "get") if args.len() == 1 => {
                let i = args[0].as_i64().unwrap_or(0) as usize;
                let v = items.borrow().get(i).cloned().unwrap_or(klio_runtime::Value::Unit);
                return Ok(v);
            }
            (klio_runtime::Value::List { items, .. }, "get") if args.len() == 1 => {
                let i = args[0].as_i64().unwrap_or(0) as usize;
                let v = items.borrow().get(i).cloned().unwrap_or(klio_runtime::Value::Unit);
                return Ok(v);
            }
            (klio_runtime::Value::Array { items, .. }, "set") if args.len() == 2 => {
                let i = args[0].as_i64().unwrap_or(0) as usize;
                let mut v = items.borrow_mut();
                while v.len() <= i { v.push(klio_runtime::Value::Unit); }
                v[i] = args[1].clone();
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::List { items, .. }, "set") if args.len() == 2 => {
                let i = args[0].as_i64().unwrap_or(0) as usize;
                let mut v = items.borrow_mut();
                while v.len() <= i { v.push(klio_runtime::Value::Unit); }
                v[i] = args[1].clone();
                return Ok(klio_runtime::Value::Unit);
            }
            (klio_runtime::Value::Array { items, .. }, "size") | (klio_runtime::Value::List { items, .. }, "size") => {
                return Ok(klio_runtime::Value::new_int(items.borrow().len() as i64));
            }
            _ => {}
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            // Enum compareTo / equals dispatched by-ordinal so user
            // enums comparing through `<` / `<=` / `>=` / `>` work
            // without each enum needing an explicit compareTo
            // declaration.
            if inst.borrow().class.is_enum && name == "compareTo" && args.len() == 1 {
                let lhs_ord = inst.borrow().get("ordinal").and_then(|v| v.as_i64()).unwrap_or(0);
                let rhs_ord = if let klio_runtime::Value::Instance(other) = &args[0] {
                    other.borrow().get("ordinal").and_then(|v| v.as_i64()).unwrap_or(0)
                } else {
                    0
                };
                return Ok(klio_runtime::Value::new_int(lhs_ord - rhs_ord));
            }
            // Pack-installed binding override takes precedence over
            // the shim's default Kotlin body. Matches the tree
            // walker's dispatch order (binding_override consulted
            // before class.find_method).
            let cls_fqn = inst.borrow().class.fqn.clone();
            let fqn = format!("{cls_fqn}.{name}");
            if let Some(func) = self.interp.binding_override(&fqn) {
                let mut all = Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                let mut ctx = CallCtx { args: &all, out: self.out };
                return func(&mut ctx)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
            let class = Rc::clone(&inst.borrow().class);
            // Use arg-type-aware overload pick when the first
            // arg's runtime type is known — same routing the tree
            // walker uses for operator dispatch on user classes.
            let first_arg_type = args.first().map(value_runtime_type_name);
            let lookup = class
                .find_method_for_arg(name, first_arg_type.as_deref())
                .or_else(|| class.find_method(name));
            if let Some((method, _)) = lookup {
                let names: Vec<Option<String>> = vec![None; args.len()];
                return self
                    .interp
                    .call_method(inst, &method, args, &names, self.out)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
        }
        // Companion / static-style call: `Foo.barMethod(args)` ―
        // look up barMethod on Foo's companion class and dispatch.
        if let klio_runtime::Value::Class(class) = receiver {
            let comp = class.companion.borrow().clone();
            if let Some(comp_inst) = comp {
                let comp_class = Rc::clone(&comp_inst.borrow().class);
                if let Some((method, _)) = comp_class.find_method(name) {
                    let names: Vec<Option<String>> = vec![None; args.len()];
                    return self
                        .interp
                        .call_method(&comp_inst, &method, args, &names, self.out)
                        .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
                }
            }
            // Top-level intrinsic registered as `<ClassFqn>.<name>`.
            let fqn = format!("{}.{}", class.fqn, name);
            if let Some(func) = self.interp.lookup_intrinsic(&fqn) {
                let mut ctx = CallCtx { args, out: self.out };
                return func(&mut ctx)
                    .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
            }
        }
        if args.is_empty() {
            // Try property access first (getters / fields).
            if let Ok(v) = self
                .interp
                .eval_property_access(receiver.clone(), name, self.out)
            {
                return Ok(v);
            }
            // Fall through to method-call synthesis so auto-generated
            // data-class members (componentN, copy without args, etc.)
            // and extension fns reachable via eval_call fire.
            return self
                .interp
                .invoke_named_member_call(receiver, name, args, self.out)
                .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
        }
        // Extension-style intrinsic on a value type.
        let type_fqn = receiver.type_fqn();
        let intr_fqn = format!("{type_fqn}.{name}");
        if let Some(func) = self.interp.lookup_intrinsic(&intr_fqn) {
            let mut all = Vec::with_capacity(args.len() + 1);
            all.push(receiver.clone());
            all.extend_from_slice(args);
            let mut ctx = CallCtx { args: &all, out: self.out };
            return func(&mut ctx)
                .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()));
        }
        // Last resort: synthesise the call through the tree
        // walker's full member-dispatch path, which picks up
        // extension functions, named args, and `vararg` /
        // default-value handling.
        match self.interp.invoke_named_member_call(receiver, name, args, self.out) {
            Ok(v) => Ok(v),
            Err(e) => Err(klio_ir::eval::EvalError::Type(format!(
                "IR Host: member call `{name}` on {type_fqn} not resolved: {e}"
            ))),
        }
    }

    fn get_field(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Route through eval_property_access so getter properties
        // (`val size get() = ...`), delegated props, and
        // extension props all fire correctly.
        self.interp
            .eval_property_access(receiver.clone(), name, self.out)
            .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()))
    }

    fn instance_of(&mut self, value: &klio_runtime::Value, ty: &klio_ir::TypeRef) -> bool {
        // Route through the runtime's nominal-type machinery so
        // throw/catch and is/as semantics see subtype hierarchies
        // (RuntimeException is-a Exception is-a Throwable) and
        // built-in nominal types (Int : Number : Any).
        value.is_runtime_type(&ty.name)
            || matches!(value, klio_runtime::Value::Exception { fqn, .. } if {
                fqn.as_str() == ty.name
                    || fqn.as_str().ends_with(&format!(".{}", ty.name))
                    // Every Kotlin exception is-a Throwable.
                    || ty.name == "Throwable"
                    || ty.name == "Exception"
                    || ty.name == "RuntimeException"
            })
    }

    fn new_instance(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let name = self
            .class_names
            .get(class.0 as usize)
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Type(format!(
                    "IR ClassId {} not in module index",
                    class.0
                ))
            })?
            .clone();
        self.interp
            .construct_by_name(&name, args, self.out)
            .map_err(|e| klio_ir::eval::EvalError::Type(e.to_string()))
    }
}

/// Lower `a name b` to `a.name(b)` so existing member / extension dispatch
/// in `eval_call` handles it. We only rewrite when the callee is a single
/// bare identifier (the only shape the parser emits with `is_infix=true`)
/// and there are exactly two positional arguments. Falls back to the
/// original call shape (top-level function dispatch) otherwise.
fn lower_infix_call(
    callee: &Expr,
    args: &[Expr],
    arg_names: &[Option<String>],
    type_args: &[klio_ast::TypeRef],
    span: klio_span::Span,
) -> Option<Expr> {
    if args.len() != 2 {
        return None;
    }
    let Expr::Path { segments, .. } = callee else { return None };
    if segments.len() != 1 {
        return None;
    }
    let name = segments[0].clone();
    let receiver = args[0].clone();
    let rhs = args[1].clone();
    let member_span = name.span;
    let member = Expr::Member {
        receiver: Box::new(receiver),
        name,
        safe: false,
        span: member_span,
    };
    Some(Expr::Call {
        callee: Box::new(member),
        args: vec![rhs],
        arg_names: arg_names.get(1..).map(|s| s.to_vec()).unwrap_or_default(),
        type_args: type_args.to_vec(),
        is_infix: false,
        span,
    })
}

fn simple_callee_name(expr: &Expr) -> Option<&str> {
    match expr {
        Expr::Path { segments, .. } if segments.len() == 1 => Some(segments[0].name.as_str()),
        _ => None,
    }
}

/// Collect the spans of every `Expr::Call` inside `body` that is both
/// (a) a self-call to the enclosing function named `fn_name` and
/// (b) in tail position.
///
/// Tail position rules implemented here:
///   * the final stmt-expression of a block whose containing block is tail
///   * either branch of `if` / `when` when the surrounding context is tail
///   * the operand of `return` / `return@fn_name`
///   * the body of an expression-bodied function (entered at `tail=true`)
/// Not tail: inside `try` / `catch` / `finally`, inside loop bodies, inside
/// lambda / anonymous-function bodies (separate frames).
/// Collect every tail-position call site in a function body, regardless
/// of callee. Used by the mutual `tailrec` trampoline so a tail call
/// from `A` into another `tailrec` function `B` can be optimised to a
/// hop in the same host frame.
pub(crate) fn collect_tail_call_sites(
    body: &klio_ast::FunctionBody,
) -> std::collections::HashSet<klio_span::Span> {
    let mut sites = std::collections::HashSet::new();
    match body {
        klio_ast::FunctionBody::Block(b) => walk_block_tail(b, true, "", &mut sites),
        klio_ast::FunctionBody::Expr(e) => walk_expr_tail(e, true, "", &mut sites),
    }
    sites
}

fn is_self_call(callee: &Expr, fn_name: &str) -> bool {
    if fn_name.is_empty() {
        // Empty name acts as a wildcard for `collect_tail_call_sites`.
        return simple_callee_name(callee).is_some();
    }
    matches!(simple_callee_name(callee), Some(n) if n == fn_name)
}

fn walk_block_tail(
    b: &klio_ast::Block,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<klio_span::Span>,
) {
    let n = b.stmts.len();
    for (i, s) in b.stmts.iter().enumerate() {
        let is_last = i + 1 == n;
        let stmt_tail = tail && is_last;
        match s {
            klio_ast::Stmt::Expr(e) => walk_expr_tail(e, stmt_tail, fn_name, sites),
            klio_ast::Stmt::Decl(_) => {}
            klio_ast::Stmt::Assign { target, value, .. } => {
                walk_expr_tail(target, false, fn_name, sites);
                walk_expr_tail(value, false, fn_name, sites);
            }
            klio_ast::Stmt::DestructuringDecl { init, .. } => {
                walk_expr_tail(init, false, fn_name, sites);
            }
        }
    }
}

fn walk_expr_tail(
    e: &Expr,
    tail: bool,
    fn_name: &str,
    sites: &mut std::collections::HashSet<klio_span::Span>,
) {
    match e {
        Expr::Call { callee, args, span, .. } => {
            if tail && is_self_call(callee, fn_name) {
                sites.insert(*span);
            }
            // Recurse into args / callee in non-tail position.
            walk_expr_tail(callee, false, fn_name, sites);
            for a in args {
                walk_expr_tail(a, false, fn_name, sites);
            }
        }
        Expr::If { cond, then_branch, else_branch, .. } => {
            walk_expr_tail(cond, false, fn_name, sites);
            walk_expr_tail(then_branch, tail, fn_name, sites);
            if let Some(eb) = else_branch {
                walk_expr_tail(eb, tail, fn_name, sites);
            }
        }
        Expr::When { subject, branches, .. } => {
            if let Some(s) = subject {
                walk_expr_tail(s, false, fn_name, sites);
            }
            for b in branches {
                for p in &b.patterns {
                    match &p.kind {
                        klio_ast::WhenPatternKind::Value(ex)
                        | klio_ast::WhenPatternKind::InRange(ex)
                        | klio_ast::WhenPatternKind::NotInRange(ex) => {
                            walk_expr_tail(ex, false, fn_name, sites);
                        }
                        _ => {}
                    }
                }
                walk_expr_tail(&b.body, tail, fn_name, sites);
            }
        }
        Expr::Block(b) => walk_block_tail(b, tail, fn_name, sites),
        Expr::Return { value, label, .. } => {
            // Treat `return` / `return@fnName` as a tail-position operand.
            let returns_to_self = match label {
                None => true,
                Some(l) => l.name == fn_name,
            };
            if let Some(v) = value {
                walk_expr_tail(v, returns_to_self, fn_name, sites);
            }
        }
        Expr::Labeled { expr, .. } => walk_expr_tail(expr, tail, fn_name, sites),
        Expr::Try { body, catches, finally, .. } => {
            // try/catch/finally bodies are never tail (spec).
            walk_block_tail(body, false, fn_name, sites);
            for c in catches {
                walk_block_tail(&c.body, false, fn_name, sites);
            }
            if let Some(fb) = finally {
                walk_block_tail(fb, false, fn_name, sites);
            }
        }
        Expr::While { cond, body, .. } => {
            walk_expr_tail(cond, false, fn_name, sites);
            walk_expr_tail(body, false, fn_name, sites);
        }
        Expr::DoWhile { body, cond, .. } => {
            if let Some(b) = body {
                walk_expr_tail(b, false, fn_name, sites);
            }
            walk_expr_tail(cond, false, fn_name, sites);
        }
        Expr::For { iter, body, .. } => {
            walk_expr_tail(iter, false, fn_name, sites);
            walk_expr_tail(body, false, fn_name, sites);
        }
        Expr::Binary { lhs, rhs, .. } => {
            walk_expr_tail(lhs, false, fn_name, sites);
            walk_expr_tail(rhs, false, fn_name, sites);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => {
            walk_expr_tail(expr, false, fn_name, sites);
        }
        Expr::Member { receiver, .. } => walk_expr_tail(receiver, false, fn_name, sites),
        Expr::Index { receiver, args, .. } => {
            walk_expr_tail(receiver, false, fn_name, sites);
            for a in args {
                walk_expr_tail(a, false, fn_name, sites);
            }
        }
        Expr::Throw { value, .. } => walk_expr_tail(value, false, fn_name, sites),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => {
            walk_expr_tail(expr, false, fn_name, sites);
        }
        Expr::Spread { expr, .. } => walk_expr_tail(expr, false, fn_name, sites),
        Expr::Lambda { .. } | Expr::AnonFun { .. } | Expr::ObjectExpr { .. } => {
            // Separate frame: don't descend (and don't recognize tail calls inside).
        }
        _ => {}
    }
}

/// Returns `true` if the given thrown value satisfies a `catch (e: T)`
/// clause with the named type. Spec §16.1: a catch-block is applicable
/// when the runtime type of the thrown value is a subtype of the bound
/// exception parameter. We walk both the built-in exception hierarchy
/// (for `Value::Exception` and any supertype name not present in the
/// captured environment) and the user-declared class chain (for
/// `Value::Instance`), so a user subclass like
/// `class MyErr : RuntimeException(...)` is caught via `RuntimeException`,
/// `Exception`, or `Throwable` without any per-callsite enumeration.
fn exception_matches(thrown: &Value, type_name: &str) -> bool {
    let target = strip_kotlin_prefix(type_name);

    match thrown {
        Value::Exception { .. } => {
            let fqn = thrown.exception_fqn().unwrap_or(thrown.type_fqn());
            let tail = fqn.rsplit('.').next().unwrap_or(fqn);
            if tail == target || fqn == type_name {
                return true;
            }
            if builtin_exception_is_subtype(tail, target) {
                return true;
            }
            // Every `Value::Exception` is a Throwable by construction. Built-in
            // exception types not yet enumerated in the hierarchy table still
            // need to catch as `Throwable` / `Exception`.
            matches!(target, "Throwable" | "Exception")
        }
        Value::Instance(i) => {
            let inst = i.borrow();
            if inst.class.is_subtype_of(type_name) || inst.class.is_subtype_of(target) {
                return true;
            }
            // The user class chain may end at a built-in name (e.g.
            // `RuntimeException`) that isn't itself a `Value::Class` in the
            // captured env. Walk those built-in tails through the built-in
            // hierarchy table so `class MyErr : RuntimeException()` matches
            // `catch (e: Throwable)`.
            let mut frontier: Vec<String> = inst.class.supertype_names.clone();
            let mut seen: Vec<String> = vec![inst.class.name.clone()];
            let mut steps = 0;
            while let Some(p) = frontier.pop() {
                if steps > 64 {
                    break;
                }
                steps += 1;
                if seen.iter().any(|s| s == &p) {
                    continue;
                }
                seen.push(p.clone());
                let pt = strip_kotlin_prefix(&p);
                if pt == target {
                    return true;
                }
                if builtin_exception_is_subtype(pt, target) {
                    return true;
                }
                if let Some(Value::Class(c)) = inst.class.captured_env.borrow().lookup(&p) {
                    for sp in &c.supertype_names {
                        if !seen.iter().any(|s| s == sp) {
                            frontier.push(sp.clone());
                        }
                    }
                }
            }
            false
        }
        _ => {
            let fqn = thrown.type_fqn();
            fqn == type_name
                || fqn.rsplit('.').next().map(|t| t == target).unwrap_or(false)
        }
    }
}

/// Returns true when `name` (simple or `kotlin.`-qualified) names a
/// built-in Throwable type or any of its subtypes that klio surfaces
/// without a user-side `ClassDef`. Used at super-init time to lift
/// `message` / `cause` ctor arguments onto a user subclass instance.
/// True when the instance's class chain reaches a built-in Throwable
/// type without going through a user-defined `ClassDef` for it. Used to
/// answer `Throwable.message` / `Throwable.cause` reads against user
/// subclasses that don't declare those properties themselves.
fn instance_is_throwable(inst: &Rc<RefCell<InstanceData>>) -> bool {
    let b = inst.borrow();
    let mut frontier: Vec<String> = b.class.supertype_names.clone();
    let mut seen: Vec<String> = vec![b.class.name.clone()];
    while let Some(p) = frontier.pop() {
        if seen.iter().any(|s| s == &p) {
            continue;
        }
        seen.push(p.clone());
        if is_builtin_throwable(&p) {
            return true;
        }
        if let Some(Value::Class(c)) = b.class.captured_env.borrow().lookup(&p) {
            for sp in &c.supertype_names {
                if !seen.iter().any(|s| s == sp) {
                    frontier.push(sp.clone());
                }
            }
        }
    }
    false
}

fn is_builtin_throwable(name: &str) -> bool {
    let tail = strip_kotlin_prefix(name);
    if tail == "Throwable" || tail == "Exception" || tail == "Error" {
        return true;
    }
    builtin_exception_parent(tail).is_some()
}

fn strip_kotlin_prefix(name: &str) -> &str {
    name.strip_prefix("kotlin.").unwrap_or(name)
}

/// Direct-parent chain for each built-in exception type the interpreter
/// surfaces. Names are simple (no `kotlin.` prefix). Used to answer
/// subtype queries when the supertype isn't itself a `Value::Class` in the
/// runtime environment.
fn builtin_exception_parent(name: &str) -> Option<&'static str> {
    match name {
        "Throwable" => None,
        "Error" | "Exception" => Some("Throwable"),
        "RuntimeException" => Some("Exception"),
        "IllegalArgumentException"
        | "IllegalStateException"
        | "NullPointerException"
        | "IndexOutOfBoundsException"
        | "ArithmeticException"
        | "ClassCastException"
        | "NoSuchElementException"
        | "UnsupportedOperationException"
        | "UninitializedPropertyAccessException"
        | "NumberFormatException"
        | "NoWhenBranchMatchedException"
        | "ConcurrentModificationException" => Some("RuntimeException"),
        "AssertionError" | "OutOfMemoryError" | "StackOverflowError" | "NotImplementedError" => {
            Some("Error")
        }
        _ => None,
    }
}

fn builtin_exception_is_subtype(name: &str, target: &str) -> bool {
    let name = strip_kotlin_prefix(name);
    let target = strip_kotlin_prefix(target);
    if name == target {
        return true;
    }
    let mut cur = name;
    while let Some(parent) = builtin_exception_parent(cur) {
        if parent == target {
            return true;
        }
        cur = parent;
    }
    false
}

/// Try to flatten a `Path` / `Member` chain into a dotted-name string. Used
/// to detect static FQN references like `kotlin.math.PI` before we
/// otherwise evaluate the chain as a receiver-method access.
/// Resolve the dispatch root for a `super` call. With no qualifier this is
/// the parent class. With `super<Klazz>` it's the named direct supertype
/// (parent or one of the declared interfaces). Errors when the named type
/// is not actually a direct supertype.
fn resolve_super_root(
    owner: &Rc<ClassDef>,
    qualifier: Option<&TypeRef>,
) -> Result<Rc<ClassDef>, RuntimeError> {
    let Some(q) = qualifier else {
        return owner.parent.borrow().clone().ok_or_else(|| {
            RuntimeError::Type(format!(
                "class `{}` has no parent for `super` dispatch",
                owner.name
            ))
        });
    };
    let qname = &q.name.name;
    if let Some(p) = owner.parent.borrow().clone() {
        if &p.name == qname || &p.fqn == qname {
            return Ok(p);
        }
    }
    for iface in owner.interfaces.borrow().iter() {
        if &iface.name == qname || &iface.fqn == qname {
            return Ok(Rc::clone(iface));
        }
    }
    Err(RuntimeError::Type(format!(
        "`super<{qname}>` is not a direct supertype of `{}`",
        owner.name
    )))
}

fn try_qualified_name(expr: &Expr) -> Option<String> {
    match expr {
        Expr::Path { segments, .. } => Some(
            segments
                .iter()
                .map(|s| s.name.as_str())
                .collect::<Vec<_>>()
                .join("."),
        ),
        Expr::Member { receiver, name, safe: false, .. } => {
            let recv = try_qualified_name(receiver)?;
            Some(format!("{recv}.{}", name.name))
        }
        _ => None,
    }
}

fn eval_unop(op: UnOp, v: Value) -> Result<Value, RuntimeError> {
    use klio_runtime::NumericRank;
    match op {
        UnOp::Neg => match &v {
            Value::Int(n) => Ok(Value::Int(n.wrapping_neg())),
            Value::Long(n) => Ok(Value::Long(n.wrapping_neg())),
            // Byte/Short negation promotes to Int per Kotlin spec.
            Value::Short(n) => Ok(Value::new_int(-i64::from(*n))),
            Value::Byte(n) => Ok(Value::new_int(-i64::from(*n))),
            Value::Double(n) => Ok(Value::Double(-n)),
            Value::Float(n) => Ok(Value::Float(-n)),
            _ => Err(RuntimeError::Type(format!("unary Neg on {v:?}"))),
        },
        UnOp::Pos => {
            if v.is_numeric() {
                // Unary + on Byte/Short promotes to Int per Kotlin spec.
                match v.numeric_rank().unwrap() {
                    NumericRank::Byte | NumericRank::Short => {
                        Ok(v.promote_to(NumericRank::Int).unwrap())
                    }
                    _ => Ok(v),
                }
            } else {
                Err(RuntimeError::Type(format!("unary Pos on {v:?}")))
            }
        }
        UnOp::Not => match v {
            Value::Bool(b) => Ok(Value::Bool(!b)),
            other => Err(RuntimeError::Type(format!("unary Not on {other:?}"))),
        },
        UnOp::PreInc | UnOp::PreDec => Err(RuntimeError::Unimplemented(
            "prefix ++/-- on non-ident".into(),
        )),
    }
}

/// Numeric promotion + arithmetic for `+ - * / %`. Returns `None` when the
/// operands are not both numeric — caller falls through to string concat /
/// other arms / type error.
fn eval_numeric_arith(op: BinOp, l: &Value, r: &Value) -> Option<Result<Value, RuntimeError>> {
    use klio_runtime::NumericRank;
    if !(l.is_numeric() && r.is_numeric()) {
        return None;
    }
    let lr = l.numeric_rank().unwrap();
    let rr = r.numeric_rank().unwrap();
    let mut rank = lr.max(rr);
    // Byte / Short arithmetic promotes to Int per Kotlin spec; UByte /
    // UShort promote to UInt by the same rule.
    if matches!(rank, NumericRank::Byte | NumericRank::Short) {
        rank = NumericRank::Int;
    }
    if matches!(rank, NumericRank::UByte | NumericRank::UShort) {
        rank = NumericRank::UInt;
    }
    Some(match rank {
        NumericRank::Int | NumericRank::Long => {
            let a = l.as_i64().unwrap();
            let b = r.as_i64().unwrap();
            let wide_result: i64 = match op {
                BinOp::Add => a.wrapping_add(b),
                BinOp::Sub => a.wrapping_sub(b),
                BinOp::Mul => a.wrapping_mul(b),
                BinOp::Div => {
                    if b == 0 {
                        return Some(Err(RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.ArithmeticException".to_string()),
                            message: Some(Rc::new("/ by zero".to_string())),
                            cause: None,
                        })));
                    }
                    a.wrapping_div(b)
                }
                BinOp::Rem => {
                    if b == 0 {
                        return Some(Err(RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.ArithmeticException".to_string()),
                            message: Some(Rc::new("/ by zero".to_string())),
                            cause: None,
                        })));
                    }
                    a.wrapping_rem(b)
                }
                _ => return None,
            };
            Ok(Value::wrap_integer(rank, wide_result))
        }
        NumericRank::UInt | NumericRank::ULong => {
            let a = l.as_u64().unwrap();
            let b = r.as_u64().unwrap();
            let wide_result: u64 = match op {
                BinOp::Add => a.wrapping_add(b),
                BinOp::Sub => a.wrapping_sub(b),
                BinOp::Mul => a.wrapping_mul(b),
                BinOp::Div => {
                    if b == 0 {
                        return Some(Err(RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.ArithmeticException".to_string()),
                            message: Some(Rc::new("/ by zero".to_string())),
                            cause: None,
                        })));
                    }
                    a.wrapping_div(b)
                }
                BinOp::Rem => {
                    if b == 0 {
                        return Some(Err(RuntimeError::Thrown(Value::Exception {
                            fqn: Rc::new("kotlin.ArithmeticException".to_string()),
                            message: Some(Rc::new("/ by zero".to_string())),
                            cause: None,
                        })));
                    }
                    a.wrapping_rem(b)
                }
                _ => return None,
            };
            Ok(Value::wrap_unsigned(rank, wide_result))
        }
        NumericRank::Float => {
            let a = l.as_f32().unwrap();
            let b = r.as_f32().unwrap();
            let v: f32 = match op {
                BinOp::Add => a + b,
                BinOp::Sub => a - b,
                BinOp::Mul => a * b,
                BinOp::Div => a / b,
                BinOp::Rem => a % b,
                _ => return None,
            };
            Ok(Value::Float(v))
        }
        NumericRank::Double => {
            let a = l.as_f64().unwrap();
            let b = r.as_f64().unwrap();
            let v: f64 = match op {
                BinOp::Add => a + b,
                BinOp::Sub => a - b,
                BinOp::Mul => a * b,
                BinOp::Div => a / b,
                BinOp::Rem => a % b,
                _ => return None,
            };
            Ok(Value::Double(v))
        }
        NumericRank::Byte | NumericRank::Short | NumericRank::UByte | NumericRank::UShort => {
            unreachable!("promoted above")
        }
    })
}

/// Numeric comparison with cross-type promotion. Returns `Some(Ok(Bool))`
/// when both operands are numeric.
fn eval_numeric_compare(op: BinOp, l: &Value, r: &Value) -> Option<bool> {
    use klio_runtime::NumericRank;
    if !(l.is_numeric() && r.is_numeric()) {
        return None;
    }
    let lr = l.numeric_rank().unwrap();
    let rr = r.numeric_rank().unwrap();
    let rank = lr.max(rr);
    let ord = match rank {
        NumericRank::Byte | NumericRank::Short | NumericRank::Int | NumericRank::Long => {
            l.as_i64().unwrap().cmp(&r.as_i64().unwrap())
        }
        NumericRank::UByte | NumericRank::UShort | NumericRank::UInt | NumericRank::ULong => {
            l.as_u64().unwrap().cmp(&r.as_u64().unwrap())
        }
        NumericRank::Float => l.as_f32().unwrap().partial_cmp(&r.as_f32().unwrap())?,
        NumericRank::Double => l.as_f64().unwrap().partial_cmp(&r.as_f64().unwrap())?,
    };
    Some(match op {
        BinOp::Lt => ord.is_lt(),
        BinOp::Le => ord.is_le(),
        BinOp::Gt => ord.is_gt(),
        BinOp::Ge => ord.is_ge(),
        _ => return None,
    })
}

fn eval_binop(op: BinOp, l: Value, r: Value) -> Result<Value, RuntimeError> {
    use BinOp::*;
    use Value::*;
    // Numeric arithmetic (with promotion across all six numeric types) is
    // handled by a single helper so each operator has one rule.
    if matches!(op, Add | Sub | Mul | Div | Rem) {
        if let Some(out) = eval_numeric_arith(op, &l, &r) {
            return out;
        }
    }
    if matches!(op, Lt | Le | Gt | Ge) {
        if let Some(b) = eval_numeric_compare(op, &l, &r) {
            return Ok(Bool(b));
        }
    }
    match (op, &l, &r) {
        (Lt, String(a), String(b)) => Ok(Bool(klio_stdlib::compare_utf16(a, b).is_lt())),
        (Le, String(a), String(b)) => Ok(Bool(klio_stdlib::compare_utf16(a, b).is_le())),
        (Gt, String(a), String(b)) => Ok(Bool(klio_stdlib::compare_utf16(a, b).is_gt())),
        (Ge, String(a), String(b)) => Ok(Bool(klio_stdlib::compare_utf16(a, b).is_ge())),
        // String concatenation: spec §8.5.5. The LHS must be a String;
        // the RHS coerces through `Display`/`toString`. Concrete user
        // values (`Instance`) format via the auto-generated toString.
        (Add, String(a), r) => {
            Ok(String(Rc::new(format!("{}{}", a, r))))
        }
        // `List<T>.plus(other: List<T>): List<T>` and
        // `List<T>.plus(elem: T): List<T>` — stdlib operators.
        (Add, List { items: a, .. }, List { items: b, .. }) => {
            let mut out = a.borrow().clone();
            out.extend(b.borrow().iter().cloned());
            Ok(List { items: Rc::new(RefCell::new(out)), mutable: false, enum_class: None })
        }
        (Add, List { items, .. }, other) => {
            let mut out = items.borrow().clone();
            out.push((*other).clone());
            Ok(List { items: Rc::new(RefCell::new(out)), mutable: false, enum_class: None })
        }
        (Sub, List { items: a, .. }, List { items: b, .. }) => {
            let bb = b.borrow();
            let result: Vec<_> = a
                .borrow()
                .iter()
                .filter(|v| !bb.iter().any(|x| Value::structural_eq(x, v)))
                .cloned()
                .collect();
            Ok(List { items: Rc::new(RefCell::new(result)), mutable: false, enum_class: None })
        }
        (Sub, List { items, .. }, other) => {
            let result: Vec<_> = items
                .borrow()
                .iter()
                .filter(|v| !Value::structural_eq(v, other))
                .cloned()
                .collect();
            Ok(List { items: Rc::new(RefCell::new(result)), mutable: false, enum_class: None })
        }
        // `Map<K, V>.plus(other: Map<K, V>): Map<K, V>` and
        // `Map<K, V>.plus(pair: Pair<K, V>): Map<K, V>` — stdlib operators.
        (Add, Map { entries: a, .. }, Map { entries: b, .. }) => {
            let mut out: Vec<(Value, Value)> = a.borrow().clone();
            for (k, v) in b.borrow().iter() {
                if let Some(pos) = out.iter().position(|(ok, _)| Value::structural_eq(ok, k)) {
                    out[pos].1 = v.clone();
                } else {
                    out.push((k.clone(), v.clone()));
                }
            }
            Ok(Map { entries: Rc::new(RefCell::new(out)), mutable: false })
        }
        (Add, Map { entries, .. }, Pair(first, second)) => {
            let mut out: Vec<(Value, Value)> = entries.borrow().clone();
            let k = (**first).clone();
            let v = (**second).clone();
            if let Some(pos) = out.iter().position(|(ok, _)| Value::structural_eq(ok, &k)) {
                out[pos].1 = v;
            } else {
                out.push((k, v));
            }
            Ok(Map { entries: Rc::new(RefCell::new(out)), mutable: false })
        }
        // `Set<T>.plus(other: Set<T> | T): Set<T>`.
        (Add, Set { items: a, .. }, Set { items: b, .. }) => {
            let mut out: Vec<Value> = a.borrow().clone();
            for v in b.borrow().iter() {
                if !out.iter().any(|x| Value::structural_eq(x, v)) {
                    out.push(v.clone());
                }
            }
            Ok(Set { items: Rc::new(RefCell::new(out)), mutable: false })
        }
        (Add, Set { items, .. }, other) => {
            let mut out: Vec<Value> = items.borrow().clone();
            if !out.iter().any(|x| Value::structural_eq(x, other)) {
                out.push((*other).clone());
            }
            Ok(Set { items: Rc::new(RefCell::new(out)), mutable: false })
        }

        (Eq, a, b) => Ok(Bool(Value::structural_eq(a, b))),
        (Neq, a, b) => Ok(Bool(!Value::structural_eq(a, b))),
        (IdentEq, a, b) => Ok(Bool(Value::structural_eq(a, b))),
        (IdentNeq, a, b) => Ok(Bool(!Value::structural_eq(a, b))),

        (Elvis, Null, b) => Ok((*b).clone()),
        (Elvis, a, _) => Ok((*a).clone()),

        (Range, a, b) if a.is_integral() && b.is_integral() => Ok(Value::Range {
            start: a.as_i64().unwrap(),
            end: b.as_i64().unwrap(),
            step: 1,
            kind: if matches!(a, Long(_)) || matches!(b, Long(_)) {
                klio_runtime::RangeKind::Long
            } else {
                klio_runtime::RangeKind::Int
            },
        }),
        (RangeUntil, a, b) if a.is_integral() && b.is_integral() => Ok(Value::Range {
            start: a.as_i64().unwrap(),
            end: b.as_i64().unwrap().saturating_sub(1),
            step: 1,
            kind: if matches!(a, Long(_)) || matches!(b, Long(_)) {
                klio_runtime::RangeKind::Long
            } else {
                klio_runtime::RangeKind::Int
            },
        }),
        // Char arithmetic: `c1 - c2 -> Int`, `c + n -> Char`, `c - n -> Char`.
        (Sub, Char(a), Char(b)) => Ok(Int(*a as i32 - *b as i32)),
        (Add, Char(c), n) if n.is_integral() => {
            let next = (*c as i64).saturating_add(n.as_i64().unwrap_or(0));
            Ok(char::from_u32(next as u32).map(Char).unwrap_or(Null))
        }
        (Sub, Char(c), n) if n.is_integral() => {
            let next = (*c as i64).saturating_sub(n.as_i64().unwrap_or(0));
            Ok(char::from_u32(next as u32).map(Char).unwrap_or(Null))
        }
        (Range, Char(a), Char(b)) => Ok(Value::Range {
            start: *a as i64,
            end: *b as i64,
            step: 1,
            kind: klio_runtime::RangeKind::Char,
        }),
        (RangeUntil, Char(a), Char(b)) => Ok(Value::Range {
            start: *a as i64,
            end: (*b as i64).saturating_sub(1),
            step: 1,
            kind: klio_runtime::RangeKind::Char,
        }),

        _ => Err(RuntimeError::Type(format!(
            "binary {op:?} on {l:?}, {r:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(src: &str) -> CaptureOutput {
        use klio_lexer::Lexer;
        use klio_parser::Parser;
        use klio_span::SourceMap;

        let mut map = SourceMap::new();
        let id = map.add("test.kt", src);
        let owned = map.get(id).source.clone();
        let lexed = Lexer::new(id, &owned).tokenize();
        assert!(
            !lexed.diagnostics.has_errors(),
            "lex diagnostics: {:?}",
            lexed.diagnostics.diagnostics()
        );
        let (ast, diags) = Parser::new(id, &owned, &lexed.tokens).parse_file();
        assert!(
            !diags.has_errors(),
            "parse diagnostics: {:?}",
            diags.diagnostics()
        );
        let mut out = CaptureOutput::default();
        Interpreter::new().run_with_output(&ast, &mut out).unwrap();
        out
    }

    fn run_err(src: &str) -> RuntimeError {
        use klio_lexer::Lexer;
        use klio_parser::Parser;
        use klio_span::SourceMap;

        let mut map = SourceMap::new();
        let id = map.add("test.kt", src);
        let owned = map.get(id).source.clone();
        let lexed = Lexer::new(id, &owned).tokenize();
        let (ast, _) = Parser::new(id, &owned, &lexed.tokens).parse_file();
        let mut out = CaptureOutput::default();
        Interpreter::new().run_with_output(&ast, &mut out).unwrap_err()
    }

    #[test]
    fn rename_import_binds_alias() {
        // `import kotlin.math.PI as TAU` makes `TAU` resolve to PI's value.
        let out = run("import kotlin.math.PI as TAU\nfun main() { println(TAU) }");
        let line = out.lines.first().expect("output");
        assert!(line.starts_with("3.14"), "got {line:?}");
    }

    #[test]
    fn rename_import_hides_original_short_name() {
        // `import kotlin.collections.listOf as ofList` makes bare `listOf`
        // unresolved in this file; the alias resolves normally.
        let err = run_err(
            "import kotlin.collections.listOf as ofList\nfun main() { println(listOf(1, 2)) }",
        );
        let msg = format!("{err}");
        assert!(msg.contains("listOf"), "got {msg:?}");
        assert!(msg.contains("ofList"), "got {msg:?}");
    }

    #[test]
    fn rename_import_does_not_hide_local_shadow() {
        // A local function with the same short name should still be
        // reachable through unqualified access; the rename only hides the
        // implicitly-imported entity.
        let out = run(
            r#"
            import kotlin.collections.listOf as ofList
            fun listOf(x: Int): Int = x + 1
            fun main() { println(listOf(7)) }
            "#,
        );
        assert_eq!(out.lines, vec!["8"]);
    }

    #[test]
    fn println_one_plus_one() {
        assert_eq!(run("fun main() { println(1 + 1) }").lines, vec!["2"]);
    }

    #[test]
    fn precedence_mul_over_add() {
        assert_eq!(run("fun main() { println(2 + 3 * 4) }").lines, vec!["14"]);
    }

    #[test]
    fn val_and_assignment() {
        let src = r#"
            fun main() {
                var x = 1
                x = x + 41
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["42"]);
    }

    #[test]
    fn compound_assign() {
        let src = r#"
            fun main() {
                var x = 10
                x += 5
                x -= 3
                x *= 2
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["24"]);
    }

    #[test]
    fn if_as_expression() {
        let src = r#"
            fun main() {
                val x = if (1 < 2) 100 else 200
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["100"]);
    }

    #[test]
    fn while_loop_and_break() {
        let src = r#"
            fun main() {
                var i = 0
                while (true) {
                    if (i == 3) break
                    println(i)
                    i = i + 1
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["0", "1", "2"]);
    }

    #[test]
    fn string_template_interp() {
        let src = r#"
            fun main() {
                val n = 7
                println("n=$n, n+1=${n + 1}")
            }
        "#;
        assert_eq!(run(src).lines, vec!["n=7, n+1=8"]);
    }

    #[test]
    fn user_function_positional_args() {
        let src = r#"
            fun add(a: Int, b: Int): Int = a + b
            fun main() { println(add(2, 3)) }
        "#;
        assert_eq!(run(src).lines, vec!["5"]);
    }

    #[test]
    fn user_function_block_body_with_return() {
        let src = r#"
            fun describe(n: Int): String {
                if (n < 0) return "negative"
                if (n == 0) return "zero"
                return "positive"
            }
            fun main() {
                println(describe(-7))
                println(describe(0))
                println(describe(42))
            }
        "#;
        assert_eq!(run(src).lines, vec!["negative", "zero", "positive"]);
    }

    #[test]
    fn function_with_default_parameter() {
        let src = r#"
            fun greet(name: String = "world"): String = "hello, $name"
            fun main() {
                println(greet())
                println(greet("kotlin"))
            }
        "#;
        assert_eq!(run(src).lines, vec!["hello, world", "hello, kotlin"]);
    }

    #[test]
    fn recursive_factorial() {
        let src = r#"
            fun fact(n: Int): Int = if (n <= 1) 1 else n * fact(n - 1)
            fun main() { println(fact(6)) }
        "#;
        assert_eq!(run(src).lines, vec!["720"]);
    }

    #[test]
    fn mutual_recursion() {
        let src = r#"
            fun isEven(n: Int): Boolean = if (n == 0) true else isOdd(n - 1)
            fun isOdd(n: Int): Boolean = if (n == 0) false else isEven(n - 1)
            fun main() {
                println(isEven(10))
                println(isOdd(10))
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "false"]);
    }

    #[test]
    fn for_over_inclusive_range() {
        assert_eq!(
            run("fun main() { for (k in 1..3) { println(k) } }").lines,
            vec!["1", "2", "3"]
        );
    }

    #[test]
    fn for_over_exclusive_range() {
        assert_eq!(
            run("fun main() { for (k in 0..<4) { println(k) } }").lines,
            vec!["0", "1", "2", "3"]
        );
    }

    #[test]
    fn for_with_break_and_continue() {
        let src = r#"
            fun main() {
                for (k in 1..6) {
                    if (k == 3) continue
                    if (k == 5) break
                    println(k)
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["1", "2", "4"]);
    }

    #[test]
    fn postfix_increment_returns_old_value() {
        let src = r#"
            fun main() {
                var x = 10
                val pre = x++
                println(pre)
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["10", "11"]);
    }

    #[test]
    fn postfix_decrement() {
        let src = r#"
            fun main() {
                var x = 5
                x--
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["4"]);
    }

    #[test]
    fn prefix_increment_returns_new_value() {
        let src = r#"
            fun main() {
                var x = 10
                val pre = ++x
                println(pre)
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["11", "11"]);
    }

    #[test]
    fn local_function_inside_block() {
        let src = r#"
            fun main() {
                fun inner(x: Int): Int = x * 10
                println(inner(4))
            }
        "#;
        assert_eq!(run(src).lines, vec!["40"]);
    }

    #[test]
    fn arity_mismatch_too_few_args() {
        let src = r#"
            fun add(a: Int, b: Int): Int = a + b
            fun main() { println(add(1)) }
        "#;
        assert!(matches!(run_err(src), RuntimeError::Arity(_)));
    }

    #[test]
    fn arity_mismatch_too_many_args() {
        let src = r#"
            fun id(x: Int): Int = x
            fun main() { println(id(1, 2)) }
        "#;
        assert!(matches!(run_err(src), RuntimeError::Arity(_)));
    }

    #[test]
    fn division_by_zero_throws_arithmetic_exception() {
        let src = r#"
            fun main() { println(1 / 0) }
        "#;
        let err = run_err(src);
        let RuntimeError::Thrown(Value::Exception { fqn, message, .. }) = err else {
            panic!("expected Thrown(ArithmeticException), got {err:?}")
        };
        assert_eq!(*fqn, "kotlin.ArithmeticException");
        assert_eq!(message.as_deref(), Some(&"/ by zero".to_string()));
    }

    #[test]
    fn division_by_zero_is_catchable() {
        let src = r#"
            fun main() {
                try {
                    println(1 / 0)
                } catch (e: ArithmeticException) {
                    println("caught: ${e.message}")
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["caught: / by zero"]);
    }

    // ---------- stdlib dispatch ----------

    #[test]
    fn stdlib_fqn_call_math_abs() {
        let src = r#"
            fun main() {
                println(kotlin.math.abs(-7))
            }
        "#;
        assert_eq!(run(src).lines, vec!["7"]);
    }

    #[test]
    fn stdlib_fqn_call_math_max() {
        let src = r#"
            fun main() {
                println(kotlin.math.max(3, 9))
            }
        "#;
        assert_eq!(run(src).lines, vec!["9"]);
    }

    #[test]
    fn stdlib_fqn_property_math_pi() {
        let src = r#"
            fun main() {
                val pi = kotlin.math.PI
                println(pi)
            }
        "#;
        let out = run(src);
        // PI displays via Rust's Double formatting; assert prefix.
        assert!(out.lines[0].starts_with("3.14"), "got {:?}", out.lines);
    }

    #[test]
    fn string_length_property() {
        let src = r#"
            fun main() {
                println("hello".length)
            }
        "#;
        assert_eq!(run(src).lines, vec!["5"]);
    }

    #[test]
    fn string_uppercase_method() {
        let src = r#"
            fun main() {
                println("hello".uppercase())
            }
        "#;
        assert_eq!(run(src).lines, vec!["HELLO"]);
    }

    #[test]
    fn string_lowercase_method_on_variable() {
        let src = r#"
            fun main() {
                val s = "MIXED"
                println(s.lowercase())
            }
        "#;
        assert_eq!(run(src).lines, vec!["mixed"]);
    }

    #[test]
    fn safe_call_on_null_short_circuits() {
        let src = r#"
            fun main() {
                val s: String = "ok"
                println(s?.length)
            }
        "#;
        assert_eq!(run(src).lines, vec!["2"]);
    }

    #[test]
    fn unknown_member_errors_with_fqn() {
        let src = r#"
            fun main() { println("hi".bogus()) }
        "#;
        let err = run_err(src);
        let msg = format!("{err}");
        assert!(msg.contains("kotlin.String.bogus"), "got {msg}");
    }

    // ---------- M6b: throw / try / catch / finally ----------

    #[test]
    fn throw_uncaught_propagates() {
        let src = r#"
            fun main() {
                throw IllegalArgumentException("nope")
            }
        "#;
        let err = run_err(src);
        assert!(matches!(err, RuntimeError::Thrown(_)));
    }

    #[test]
    fn try_catch_recovers() {
        let src = r#"
            fun main() {
                val r = try {
                    throw IllegalStateException("boom")
                } catch (e: IllegalStateException) {
                    "caught"
                }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["caught"]);
    }

    #[test]
    fn try_catch_by_supertype() {
        let src = r#"
            fun main() {
                val r = try {
                    throw IllegalArgumentException("bad")
                } catch (e: Throwable) {
                    "got it"
                }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["got it"]);
    }

    #[test]
    fn try_catch_message_property() {
        let src = r#"
            fun main() {
                try {
                    throw IllegalArgumentException("oops")
                } catch (e: IllegalArgumentException) {
                    println(e.message)
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["oops"]);
    }

    #[test]
    fn try_finally_always_runs() {
        let src = r#"
            fun main() {
                try {
                    println("body")
                } finally {
                    println("finally")
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["body", "finally"]);
    }

    #[test]
    fn try_finally_runs_after_catch() {
        let src = r#"
            fun main() {
                try {
                    throw RuntimeException("x")
                } catch (e: Throwable) {
                    println("caught")
                } finally {
                    println("finally")
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["caught", "finally"]);
    }

    #[test]
    fn uncaught_when_no_match() {
        let src = r#"
            fun main() {
                try {
                    throw NullPointerException("npe")
                } catch (e: ArithmeticException) {
                    println("no")
                }
            }
        "#;
        assert!(matches!(run_err(src), RuntimeError::Thrown(_)));
    }

    // ---------- M6b: lambdas + scoping fns ----------

    #[test]
    fn let_returns_lambda_result() {
        let src = r#"
            fun main() {
                val r = 5.let { it * 2 }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["10"]);
    }

    #[test]
    fn also_returns_receiver() {
        let src = r#"
            fun main() {
                val r = 5.also { println(it) }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["5", "5"]);
    }

    #[test]
    fn apply_returns_receiver_with_this() {
        // `apply` exposes the receiver as `this`. Bare names like `length`
        // resolve via the implicit-this fallback.
        let src = r#"
            fun main() {
                val r = "abc".apply { println(length) }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["3", "abc"]);
    }

    #[test]
    fn run_returns_lambda_result_with_this() {
        let src = r#"
            fun main() {
                val r = "abc".run { length }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["3"]);
    }

    #[test]
    fn explicit_this_in_apply() {
        let src = r#"
            fun main() {
                "hi".apply { println(this.uppercase()) }
            }
        "#;
        assert_eq!(run(src).lines, vec!["HI"]);
    }

    #[test]
    fn take_if_filters() {
        let src = r#"
            fun main() {
                val a = 5.takeIf { it > 0 }
                val b = 5.takeIf { it < 0 }
                println(a)
                println(b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["5", "null"]);
    }

    #[test]
    fn take_unless_inverse() {
        let src = r#"
            fun main() {
                val a = 5.takeUnless { it > 0 }
                val b = 5.takeUnless { it < 0 }
                println(a)
                println(b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["null", "5"]);
    }

    #[test]
    fn with_top_level_binds_this() {
        let src = r#"
            fun main() {
                val r = with(10) { this + 1 }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["11"]);
    }

    #[test]
    fn run_top_level_returns_value() {
        let src = r#"
            fun main() {
                val x = run { 1 + 1 }
                println(x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["2"]);
    }

    #[test]
    fn run_top_level_unit_block() {
        let src = r#"
            fun main() {
                run { println("hi") }
            }
        "#;
        assert_eq!(run(src).lines, vec!["hi"]);
    }

    #[test]
    fn run_top_level_nested() {
        let src = r#"
            fun main() {
                val n = run {
                    val inner = run { 5 }
                    inner * 2
                }
                println(n)
            }
        "#;
        assert_eq!(run(src).lines, vec!["10"]);
    }

    #[test]
    fn lambda_with_explicit_params() {
        let src = r#"
            fun apply2(f: Int, a: Int): Int {
                return f
            }
            fun main() {
                val sum = { x: Int, y: Int -> x + y }
                println(sum(3, 4))
            }
        "#;
        assert_eq!(run(src).lines, vec!["7"]);
    }

    #[test]
    fn lambda_closes_over_outer() {
        let src = r#"
            fun main() {
                val factor = 10
                val scale = { x: Int -> x * factor }
                println(scale(4))
            }
        "#;
        assert_eq!(run(src).lines, vec!["40"]);
    }

    // ---------- M6b: indexing + new stdlib intrinsics ----------

    #[test]
    fn string_indexing_returns_char() {
        let src = r#"
            fun main() {
                println("hello"[1])
            }
        "#;
        assert_eq!(run(src).lines, vec!["e"]);
    }

    #[test]
    fn string_substring_two_args_e2e() {
        let src = r#"
            fun main() {
                println("hello".substring(1, 4))
            }
        "#;
        assert_eq!(run(src).lines, vec!["ell"]);
    }

    #[test]
    fn string_starts_ends_contains() {
        let src = r#"
            fun main() {
                println("hello".startsWith("he"))
                println("hello".endsWith("lo"))
                println("hello".contains("ell"))
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "true", "true"]);
    }

    #[test]
    fn string_repeat_and_reversed_e2e() {
        let src = r#"
            fun main() {
                println("ab".repeat(3))
                println("abc".reversed())
            }
        "#;
        assert_eq!(run(src).lines, vec!["ababab", "cba"]);
    }

    #[test]
    fn char_is_digit_e2e() {
        let src = r#"
            fun main() {
                println('5'.isDigit())
                println('a'.isDigit())
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "false"]);
    }

    #[test]
    fn int_bitwise_and_or_xor() {
        let src = r#"
            fun main() {
                println((0b1100).and(0b1010))
                println((0b1100).or(0b1010))
                println((0b1100).xor(0b1010))
            }
        "#;
        assert_eq!(run(src).lines, vec!["8", "14", "6"]);
    }

    #[test]
    fn math_sin_cos_pi() {
        // Match Kotlin's Double.toString: trailing `.0` for integer-valued.
        let src = r#"
            fun main() {
                println(kotlin.math.sin(0.0))
                println(kotlin.math.cos(0.0))
                println(kotlin.math.sqrt(9.0))
            }
        "#;
        assert_eq!(run(src).lines, vec!["0.0", "1.0", "3.0"]);
    }

    // ---------- when / is / sealed ----------

    #[test]
    fn when_subject_bound_with_value_and_else() {
        let src = r#"
            fun describe(x: Int): String = when (x) {
                0 -> "zero"
                1, 2 -> "small"
                else -> "many"
            }
            fun main() {
                println(describe(0))
                println(describe(2))
                println(describe(99))
            }
        "#;
        assert_eq!(run(src).lines, vec!["zero", "small", "many"]);
    }

    #[test]
    fn when_subjectless_boolean_branches() {
        let src = r#"
            fun classify(n: Int): String = when {
                n < 0 -> "neg"
                n == 0 -> "zero"
                else -> "pos"
            }
            fun main() {
                println(classify(-3))
                println(classify(0))
                println(classify(7))
            }
        "#;
        assert_eq!(run(src).lines, vec!["neg", "zero", "pos"]);
    }

    #[test]
    fn when_in_range_pattern() {
        let src = r#"
            fun bucket(n: Int): String = when (n) {
                in 0..9 -> "single"
                in 10..99 -> "double"
                else -> "big"
            }
            fun main() {
                println(bucket(3))
                println(bucket(42))
                println(bucket(500))
            }
        "#;
        assert_eq!(run(src).lines, vec!["single", "double", "big"]);
    }

    #[test]
    fn when_is_type_smart_cast_on_string() {
        let src = r#"
            fun len(x: Any): Int = when (x) {
                is String -> x.length
                is Int -> x
                else -> -1
            }
            fun main() {
                println(len("hello"))
                println(len(7))
                println(len(true))
            }
        "#;
        assert_eq!(run(src).lines, vec!["5", "7", "-1"]);
    }

    #[test]
    fn when_no_match_throws_no_branch_exception() {
        let src = r#"
            fun main() {
                val r = try {
                    when (3) {
                        1 -> "one"
                        2 -> "two"
                    }
                } catch (e: NoWhenBranchMatchedException) {
                    "caught"
                }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["caught"]);
    }

    #[test]
    fn bare_is_check_and_not_is() {
        let src = r#"
            fun main() {
                val x: Any = "hello"
                println(x is String)
                println(x !is Int)
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "true"]);
    }

    #[test]
    fn sealed_class_when_dispatch() {
        let src = r#"
            sealed class Result
            class Ok(val v: Int): Result()
            class Err(val msg: String): Result()
            fun describe(r: Result): String = when (r) {
                is Ok -> "ok=${r.v}"
                is Err -> "err=${r.msg}"
                else -> "?"
            }
            fun main() {
                println(describe(Ok(7)))
                println(describe(Err("boom")))
            }
        "#;
        assert_eq!(run(src).lines, vec!["ok=7", "err=boom"]);
    }

    #[test]
    fn user_exception_caught_via_builtin_supertype() {
        let src = r#"
            open class MyErr : RuntimeException("boom")
            class SubErr : MyErr()
            class TreeErr : Throwable()
            fun main() {
                try { throw MyErr() } catch (e: RuntimeException) { println("a") }
                try { throw MyErr() } catch (e: Exception) { println("b") }
                try { throw MyErr() } catch (e: Throwable) { println("c") }
                try { throw SubErr() } catch (e: MyErr) { println("d") }
                try { throw TreeErr() } catch (e: Throwable) { println("e") }
            }
        "#;
        assert_eq!(run(src).lines, vec!["a", "b", "c", "d", "e"]);
    }

    #[test]
    fn unrelated_user_exception_propagates_past_unmatched_catch() {
        let src = r#"
            class A : Throwable()
            class B : Throwable()
            fun main() {
                try {
                    try { throw A() } catch (e: B) { println("wrong") }
                } catch (e: A) { println("outer") }
            }
        "#;
        assert_eq!(run(src).lines, vec!["outer"]);
    }

    #[test]
    fn abstract_class_cannot_be_instantiated_directly() {
        let src = r#"
            abstract class Shape { abstract fun area(): Double }
            fun main() {
                try {
                    val s = Shape()
                    println(s.area())
                } catch (e: Throwable) {
                    println("caught")
                }
            }
        "#;
        assert_eq!(run(src).lines, vec!["caught"]);
    }

    #[test]
    fn secondary_ctor_delegating_this_runs_init_once() {
        let src = r#"
            class Counter(val n: Int) {
                init { println("init n=$n") }
                constructor() : this(0)
                constructor(a: Int, b: Int) : this(a + b)
            }
            fun main() {
                Counter()
                Counter(2, 3)
            }
        "#;
        // Each `Counter(...)` call runs init exactly once.
        assert_eq!(run(src).lines, vec!["init n=0", "init n=5"]);
    }

    #[test]
    fn inner_class_captures_outer() {
        let src = r#"
            class Outer(val x: Int) {
                inner class Inner {
                    fun show(): String = "x=$x"
                }
            }
            fun main() {
                println(Outer(7).Inner().show())
            }
        "#;
        assert_eq!(run(src).lines, vec!["x=7"]);
    }

    #[test]
    fn inner_class_this_at_outer() {
        let src = r#"
            class A(val v: Int) {
                inner class B {
                    fun outerV(): Int = this@A.v
                }
            }
            fun main() {
                println(A(11).B().outerV())
            }
        "#;
        assert_eq!(run(src).lines, vec!["11"]);
    }

    #[test]
    fn anonymous_object_basic_expression() {
        let src = r#"
            fun main() {
                val o = object {
                    val x = 1
                    fun f(): Int = x + 1
                }
                println(o.f())
            }
        "#;
        assert_eq!(run(src).lines, vec!["2"]);
    }

    #[test]
    fn anonymous_object_implements_interface() {
        let src = r#"
            interface Greeter { fun greet(): String }
            fun main() {
                val g: Greeter = object : Greeter {
                    override fun greet(): String = "hi"
                }
                println(g.greet())
            }
        "#;
        assert_eq!(run(src).lines, vec!["hi"]);
    }

    #[test]
    fn anonymous_object_extends_parent_with_args() {
        let src = r#"
            open class Named(val name: String) {
                open fun greet(): String = "hello $name"
            }
            fun main() {
                val o = object : Named("Anna") {
                    override fun greet(): String = "$name!"
                }
                println(o.greet())
            }
        "#;
        assert_eq!(run(src).lines, vec!["Anna!"]);
    }

    #[test]
    fn anonymous_object_captures_enclosing_local() {
        let src = r#"
            fun main() {
                val base = 100
                val o = object {
                    fun shifted(by: Int): Int = base + by
                }
                println(o.shifted(5))
            }
        "#;
        assert_eq!(run(src).lines, vec!["105"]);
    }

    #[test]
    fn local_class_basic() {
        let src = r#"
            fun main() {
                class Counter(var n: Int) {
                    fun bump() { n = n + 1 }
                }
                val c = Counter(0)
                c.bump()
                c.bump()
                c.bump()
                println(c.n)
            }
        "#;
        assert_eq!(run(src).lines, vec!["3"]);
    }

    #[test]
    fn local_class_captures_enclosing_local() {
        let src = r#"
            fun build(): Int {
                val factor = 7
                class Mul(val n: Int) {
                    fun product(): Int = n * factor
                }
                return Mul(6).product()
            }
            fun main() { println(build()) }
        "#;
        assert_eq!(run(src).lines, vec!["42"]);
    }

    #[test]
    fn local_data_class() {
        let src = r#"
            fun main() {
                data class P(val x: Int, val y: Int)
                val a = P(1, 2)
                val b = P(1, 2)
                println(a)
                println(a == b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["P(x=1, y=2)", "true"]);
    }

    #[test]
    fn local_class_inside_method() {
        let src = r#"
            class Outer(val tag: String) {
                fun run(): String {
                    class H(val v: Int) {
                        fun render(): String = "$tag:$v"
                    }
                    return H(9).render()
                }
            }
            fun main() { println(Outer("T").run()) }
        "#;
        assert_eq!(run(src).lines, vec!["T:9"]);
    }

    #[test]
    fn qualified_this_from_local_class_method() {
        let src = r#"
            class Outer {
                val tag = "outer"
                fun build(): String {
                    class Local { fun show() = "${this@Outer.tag}-local" }
                    return Local().show()
                }
            }
            fun main() { println(Outer().build()) }
        "#;
        assert_eq!(run(src).lines, vec!["outer-local"]);
    }

    #[test]
    fn qualified_this_from_inner_class_method() {
        let src = r#"
            class Outer {
                val tag = "outer"
                inner class Inner { fun show() = "${this@Outer.tag}-inner" }
            }
            fun main() { println(Outer().Inner().show()) }
        "#;
        assert_eq!(run(src).lines, vec!["outer-inner"]);
    }

    #[test]
    fn qualified_this_unknown_label_diagnoses() {
        let src = r#"
            class Outer {
                fun build(): String {
                    class Local { fun show(): String = "${this@Nope}" }
                    return Local().show()
                }
            }
            fun main() { println(Outer().build()) }
        "#;
        let err = run_err(src);
        let msg = format!("{err:?}");
        assert!(msg.contains("this@Nope"), "expected diagnostic mentioning this@Nope, got {msg}");
    }

    #[test]
    fn qualified_this_self_label_inside_method() {
        let src = r#"
            class Outer {
                val tag = "self"
                fun show() = "${this@Outer.tag}"
            }
            fun main() { println(Outer().show()) }
        "#;
        assert_eq!(run(src).lines, vec!["self"]);
    }

    #[test]
    fn index_out_of_bounds_throws_kotlin_exception() {
        let src = r#"
            fun main() {
                try {
                    "ab"[99]
                } catch (e: IndexOutOfBoundsException) {
                    println("caught: ${e.message}")
                }
            }
        "#;
        let out = run(src);
        assert_eq!(out.lines.len(), 1);
        assert!(out.lines[0].starts_with("caught: index"), "got {:?}", out.lines);
    }

    // --- default `toString` for plain classes -------------------------

    #[test]
    fn plain_class_default_tostring_has_class_at_hex() {
        let src = r#"
            class Foo(val x: Int)
            fun main() {
                val f = Foo(1)
                println(f.toString())
            }
        "#;
        let out = run(src);
        assert_eq!(out.lines.len(), 1);
        let s = &out.lines[0];
        assert!(s.starts_with("Foo@"), "expected `Foo@<hex>`, got {s:?}");
        let tail = &s["Foo@".len()..];
        assert!(!tail.is_empty(), "missing hex suffix in {s:?}");
        assert!(
            tail.chars().all(|c| c.is_ascii_hexdigit()),
            "non-hex char in {s:?}"
        );
    }

    #[test]
    fn plain_class_default_tostring_distinct_per_instance() {
        let src = r#"
            class Foo(val x: Int)
            fun main() {
                val a = Foo(1)
                val b = Foo(1)
                println(a.toString() != b.toString())
            }
        "#;
        assert_eq!(run(src).lines, vec!["true"]);
    }

    #[test]
    fn data_class_tostring_unaffected() {
        // Data classes still render as `Name(field=value, …)`, not `Name@hex`.
        let src = r#"
            data class Pt(val x: Int, val y: Int)
            fun main() {
                println(Pt(1, 2))
            }
        "#;
        assert_eq!(run(src).lines, vec!["Pt(x=1, y=2)"]);
    }

    #[test]
    fn enum_entry_tostring_unaffected() {
        let src = r#"
            enum class Color { RED, GREEN }
            fun main() {
                println(Color.RED)
            }
        "#;
        assert_eq!(run(src).lines, vec!["RED"]);
    }

    #[test]
    fn singleton_object_tostring_unaffected() {
        let src = r#"
            object Singleton
            fun main() {
                println(Singleton.toString())
            }
        "#;
        // Singleton objects render as their name, no `@hex` suffix.
        assert_eq!(run(src).lines, vec!["Singleton"]);
    }

    // --- anonymous-object default toString ---------------------------

    #[test]
    fn anon_object_default_tostring_has_at_and_hex_tail() {
        let src = r#"
            fun main() {
                val o = object { val x = 1 }
                println(o.toString())
            }
        "#;
        let out = run(src);
        assert_eq!(out.lines.len(), 1);
        let s = &out.lines[0];
        let at = s.find('@').expect("missing @ in anon-object toString");
        let tail = &s[at + 1..];
        assert!(!tail.is_empty(), "missing hex tail in {s:?}");
        assert!(
            tail.chars().all(|c| c.is_ascii_hexdigit()),
            "non-hex tail in {s:?}"
        );
    }

    #[test]
    fn anon_object_with_explicit_tostring_wins() {
        let src = r#"
            fun main() {
                val o = object { override fun toString(): String = "explicit" }
                println(o)
            }
        "#;
        assert_eq!(run(src).lines, vec!["explicit"]);
    }

    // --- EnumEntries interface ---------------------------------------

    #[test]
    fn enum_entries_is_both_list_and_enum_entries() {
        let src = r#"
            enum class C { A, B }
            fun main() {
                val e = C.entries
                println(e is List<*>)
                println(e is EnumEntries<*>)
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "true"]);
    }

    #[test]
    fn plain_list_is_not_enum_entries() {
        let src = r#"
            fun main() {
                val xs = listOf(1, 2, 3)
                println(xs is List<*>)
                println(xs is EnumEntries<*>)
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "false"]);
    }

    #[test]
    fn enum_entries_supports_list_ops() {
        let src = r#"
            enum class C { A, B, C2 }
            fun main() {
                val e = C.entries
                println(e.size)
                println(e[0])
                println(e[2])
                println(e.map { it.name })
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["3", "A", "C2", "[A, B, C2]"]
        );
    }

    #[test]
    fn operator_plus_user_class_member() {
        let src = r#"
            class Vec2(val x: Int, val y: Int) {
                operator fun plus(o: Vec2): Vec2 = Vec2(x + o.x, y + o.y)
                override fun toString(): String = "($x,$y)"
            }
            fun main() {
                val a = Vec2(1, 2)
                val b = Vec2(3, 4)
                println(a + b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["(4,6)"]);
    }

    #[test]
    fn operator_minus_times_div_rem_user_class() {
        let src = r#"
            class N(val v: Int) {
                operator fun minus(o: N): N = N(v - o.v)
                operator fun times(o: N): N = N(v * o.v)
                operator fun div(o: N): N = N(v / o.v)
                operator fun rem(o: N): N = N(v % o.v)
                override fun toString(): String = "N($v)"
            }
            fun main() {
                val a = N(20)
                val b = N(6)
                println(a - b)
                println(a * b)
                println(a / b)
                println(a % b)
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["N(14)", "N(120)", "N(3)", "N(2)"]
        );
    }

    #[test]
    fn operator_plus_extension() {
        let src = r#"
            class Box(val n: Int) {
                override fun toString(): String = "Box($n)"
            }
            operator fun Box.plus(other: Box): Box = Box(n + other.n)
            fun main() {
                println(Box(2) + Box(3))
            }
        "#;
        assert_eq!(run(src).lines, vec!["Box(5)"]);
    }

    #[test]
    fn operator_unary_minus_plus_not_user_class() {
        let src = r#"
            class Vec(val x: Int) {
                operator fun unaryMinus(): Vec = Vec(-x)
                operator fun unaryPlus(): Vec = Vec(+x)
                override fun toString(): String = "Vec($x)"
            }
            class Flag(val on: Boolean) {
                operator fun not(): Flag = Flag(!on)
                override fun toString(): String = "Flag($on)"
            }
            fun main() {
                println(-Vec(5))
                println(+Vec(-3))
                println(!Flag(true))
            }
        "#;
        assert_eq!(run(src).lines, vec!["Vec(-5)", "Vec(-3)", "Flag(false)"]);
    }

    #[test]
    fn operator_range_to_user_class() {
        let src = r#"
            class Day(val n: Int) {
                operator fun rangeTo(end: Day): String = "Day($n..${end.n})"
            }
            fun main() {
                println(Day(1)..Day(5))
            }
        "#;
        assert_eq!(run(src).lines, vec!["Day(1..5)"]);
    }

    #[test]
    fn destructure_underscore_skips_component() {
        // Spec ch.9: `_` placeholder makes no `componentK` call. Visible
        // here via a counter incremented inside each component getter — the
        // `_` slot must not increment it.
        let src = r#"
            var calls = 0
            class Counted(val a: Int, val b: Int, val c: Int) {
                operator fun component1(): Int { calls = calls + 1; return a }
                operator fun component2(): Int { calls = calls + 1; return b }
                operator fun component3(): Int { calls = calls + 1; return c }
            }
            fun main() {
                val (x, _, z) = Counted(7, 8, 11)
                println(x)
                println(z)
                println(calls)
            }
        "#;
        assert_eq!(run(src).lines, vec!["7", "11", "2"]);
    }

    #[test]
    fn delegate_provide_delegate_member() {
        // Spec ch.9: `provideDelegate` rewrites the stored delegate at
        // property-init time. Here the initializer is a `Factory`; after
        // `provideDelegate` the stored delegate is the `Holder`, whose
        // `getValue` returns the embedded constant.
        let src = r#"
            import kotlin.reflect.KProperty
            class Holder(val v: Int) {
                operator fun getValue(thisRef: Any?, prop: KProperty<*>): Int = v
            }
            class Factory(val base: Int) {
                operator fun provideDelegate(thisRef: Any?, prop: KProperty<*>): Holder = Holder(base + 1)
            }
            class Owner {
                val x: Int by Factory(10)
            }
            fun main() {
                println(Owner().x)
            }
        "#;
        assert_eq!(run(src).lines, vec!["11"]);
    }

    #[test]
    fn pack_install_routes_dispatch_through_bindings() {
        // Build an in-memory pack that binds kotlin.io.println to a
        // synthetic Rust function that prefixes "[PACK]", install it,
        // and verify dispatch through the FQN goes through the
        // installed binding rather than the static stdlib table.
        use klio_pack::schema::{
            encode, Binding, BindingKind, BindingManifest, PackManifest, Purity,
        };
        use klio_pack::{section_names, PackReader, PackWriter};
        use klio_runtime::{CallCtx, RuntimeError, StdlibFn, Value};

        fn marker_println(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
            for v in ctx.args {
                let s = match v {
                    Value::String(s) => s.as_str().to_string(),
                    _ => format!("{v}"),
                };
                ctx.out.writeln(&format!("[PACK] {s}"));
            }
            Ok(Value::Unit)
        }

        let manifest = PackManifest {
            library_id: "test".into(),
            library_version: "0.0.0".into(),
            abi_version: 1,
            implicit_packages: vec![],
            dependencies: vec![],
        };
        let bindings = BindingManifest {
            bindings: vec![Binding {
                fqn: "kotlin.io.println".into(),
                kind: BindingKind::Function,
                host_symbol: "test.println".into(),
                overrides_interpreter: true,
                purity: Purity::Effectful,
                min_arity: 0,
                max_arity: 1,
                platform_actual: false,
            }],
        };
        let mut w = PackWriter::new();
        w.add_raw(section_names::MANIFEST, encode(&manifest).unwrap());
        w.add_raw(section_names::BINDINGS, encode(&bindings).unwrap());
        let bytes = w.finish().unwrap();
        let pack = PackReader::from_bytes(bytes).unwrap();
        let mut host = klio_stdlib::HostBindings::new();
        let marker: StdlibFn = marker_println;
        host.register("test.println", marker);

        use klio_lexer::Lexer;
        use klio_parser::Parser;
        use klio_span::SourceMap;
        let src = r#"fun main() { println("hello") }"#;
        let mut map = SourceMap::new();
        let id = map.add("test.kt", src);
        let owned = map.get(id).source.clone();
        let lexed = Lexer::new(id, &owned).tokenize();
        let (ast, _) = Parser::new(id, &owned, &lexed.tokens).parse_file();
        let mut interp = Interpreter::new();
        let installed = interp.install_pack(&pack, &host).unwrap();
        assert_eq!(installed, 1);
        let mut out = CaptureOutput::default();
        interp.run_with_output(&ast, &mut out).unwrap();
        assert_eq!(out.lines, vec!["[PACK] hello"]);
    }

    #[test]
    fn suspend_anf_nested_calls() {
        // ANF normalisation: a suspend body whose statements contain
        // suspending calls nested inside expressions (binary operands,
        // function arguments, string templates) lowers to a sequence
        // of state-machine states whose results are stitched back via
        // synthetic temps.
        let src = r#"
            import kotlin.coroutines.*
            suspend fun ask(n: Int): Int = suspendCoroutine { cont -> cont.resume(n * 10) }
            suspend fun work(): Int {
                val a = ask(1) + ask(2)
                val b = ask(3) + ask(a)
                println("a=$a b=$b")
                return a + b
            }
            fun main() {
                val r = runBlocking { work() }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["a=30 b=330", "360"]);
    }

    #[test]
    fn suspend_anf_string_template() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun ask(n: Int): Int = suspendCoroutine { cont -> cont.resume(n + 100) }
            suspend fun greet(): String {
                val s = "x=${ask(1)} y=${ask(2)}"
                println(s)
                return "got ${ask(3)}"
            }
            fun main() {
                val r = runBlocking { greet() }
                println(r)
            }
        "#;
        assert_eq!(run(src).lines, vec!["x=101 y=102", "got 103"]);
    }

    #[test]
    fn reflection_member_call_and_property_set() {
        // KFunction.call on a member fn reference takes the receiver
        // as the leading argument. KMutableProperty1.set writes the
        // named property through the class's declared setter (or the
        // raw field when no setter is declared).
        let src = r#"
            class Foo(val x: Int, var y: String) {
                fun hello(name: String): String = "hi $name from $x"
            }
            fun main() {
                val foo = Foo(1, "two")
                val k = Foo::class
                println(k.simpleName)
                val m = Foo::hello
                println(m.call(foo, "world"))
                val p = Foo::x
                println(p.get(foo))
                val q = Foo::y
                println(q.get(foo))
                q.set(foo, "new")
                println(foo.y)
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["Foo", "hi world from 1", "1", "two", "new"]
        );
    }

    #[test]
    fn reflection_kclass_full_surface() {
        // KClass.memberFunctions / memberProperties / primaryConstructor
        // report the declared functions and properties. The synthesised
        // KFunction values respond to `.name` and `.parameters`.
        let src = r#"
            class Foo(val x: Int, var y: String) {
                fun hello(name: String): String = "hi $name"
                fun bye(): String = "bye"
                val z: Int = x * 2
            }
            fun main() {
                val k = Foo::class
                val fns = k.memberFunctions.map { it.name }.sorted()
                println(fns)
                val ps = k.memberProperties.map { it.name }.sorted()
                println(ps)
                val ctor = k.primaryConstructor
                println(ctor?.parameters?.size)
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["[bye, hello]", "[x, y, z]", "2"]
        );
    }

    #[test]
    fn builder_inference_user_fn() {
        // Spec §14: `@BuilderInference` on a user-declared generic fn
        // postpones type-parameter inference past the call site. Our
        // tree-walking interpreter relies on runtime values, so the
        // typecheck side just needs to stop rejecting the call.
        let src = r#"
            @BuilderInference
            fun <T> myBuild(block: MutableList<T>.() -> Unit): List<T> {
                val list = mutableListOf<T>()
                list.block()
                return list
            }
            fun main() {
                val xs = myBuild {
                    add(1)
                    add(2)
                    add(3)
                }
                println(xs)
                val ys = myBuild<String> {
                    add("a")
                    add("b")
                }
                println(ys)
            }
        "#;
        assert_eq!(run(src).lines, vec!["[1, 2, 3]", "[a, b]"]);
    }

    #[test]
    fn receiver_typed_lambda_parameter_call() {
        // `recv.block(args)` where `block` is a local lambda value
        // bound at the call's enclosing scope and the parameter type
        // declares an extension receiver. The lambda's body runs with
        // `this` bound to `recv`.
        let src = r#"
            fun apply2(list: MutableList<Int>, block: MutableList<Int>.() -> Unit) {
                list.block()
            }
            fun main() {
                val xs = mutableListOf<Int>()
                apply2(xs) {
                    add(10)
                    add(20)
                }
                println(xs)
            }
        "#;
        assert_eq!(run(src).lines, vec!["[10, 20]"]);
    }

    #[test]
    fn mutual_tailrec_no_stack_overflow() {
        // Two `tailrec` functions calling each other in tail position
        // must cycle through a single host frame — a 200k-deep
        // even/odd ping-pong would blow the stack with normal
        // recursion.
        let src = r#"
            tailrec fun isEven(n: Int): Boolean = if (n == 0) true else isOdd(n - 1)
            tailrec fun isOdd(n: Int): Boolean = if (n == 0) false else isEven(n - 1)
            fun main() {
                println(isEven(200000))
                println(isOdd(200001))
                println(isEven(7))
                println(isOdd(7))
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "true", "false", "true"]);
    }

    #[test]
    fn delegate_extension_get_set() {
        // Spec ch.9: `operator getValue` / `setValue` may be supplied
        // as extension functions on the delegate type, not just as
        // members of its class. Both class-member and top-level
        // delegated properties must route through the extension.
        let src = r#"
            import kotlin.reflect.KProperty
            class D
            operator fun D.getValue(thisRef: Any?, prop: KProperty<*>): String = "g-${prop.name}"
            operator fun D.setValue(thisRef: Any?, prop: KProperty<*>, v: String) { println("s-${prop.name}=$v") }
            class Owner {
                val a: String by D()
                var b: String by D()
            }
            val topA: String by D()
            var topB: String by D()
            fun main() {
                val o = Owner()
                println(o.a)
                o.b = "x"
                println(topA)
                topB = "y"
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["g-a", "s-b=x", "g-topA", "s-topB=y"]
        );
    }

    #[test]
    fn delegate_nothing_null_this_ref() {
        // Spec ch.9: top-level delegated properties pass `thisRef = null`
        // and may be typed `Nothing?`. The dispatch must accept either
        // `Any?` or `Nothing?` receiver shapes uniformly.
        let src = r#"
            import kotlin.reflect.KProperty
            class A {
                operator fun getValue(thisRef: Any?, prop: KProperty<*>): Int = 10
            }
            class B {
                operator fun getValue(thisRef: Nothing?, prop: KProperty<*>): Int = 20
            }
            val a: Int by A()
            val b: Int by B()
            fun main() {
                println(a)
                println(b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["10", "20"]);
    }

    #[test]
    fn destructure_lambda_params() {
        let src = r#"
            fun main() {
                val pairs = listOf(1 to "a", 2 to "b", 3 to "c")
                pairs.forEach { (n, s) -> println("$n=$s") }
                pairs.forEach { (n, _) -> println(n) }
                pairs.forEach { (_, s) -> println(s) }
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["1=a", "2=b", "3=c", "1", "2", "3", "a", "b", "c"]
        );
    }

    #[test]
    fn destructure_lambda_params_typed() {
        // Spec ch.9: per-slot type annotations are allowed; the runtime
        // ignores them, but the parser must accept them without failing.
        let src = r#"
            fun main() {
                val pairs = listOf(1 to "a", 2 to "b")
                pairs.forEach { (n: Int, s: String) -> println("$n-$s") }
            }
        "#;
        assert_eq!(run(src).lines, vec!["1-a", "2-b"]);
    }

    #[test]
    fn destructure_underscore_in_for_loop() {
        let src = r#"
            fun main() {
                val pairs = listOf(1 to "a", 2 to "b", 3 to "c")
                for ((n, _) in pairs) println(n)
                for ((_, s) in pairs) println(s)
            }
        "#;
        assert_eq!(
            run(src).lines,
            vec!["1", "2", "3", "a", "b", "c"]
        );
    }

    #[test]
    fn operator_inc_user_class() {
        let src = r#"
            class Counter(val n: Int) {
                operator fun inc(): Counter = Counter(n + 1)
                override fun toString(): String = "C($n)"
            }
            fun main() {
                var c = Counter(0)
                println(c++)
                println(c)
                println(++c)
                println(c)
            }
        "#;
        assert_eq!(run(src).lines, vec!["C(0)", "C(1)", "C(2)", "C(2)"]);
    }

    #[test]
    fn operator_inc_indexed() {
        let src = r#"
            fun main() {
                val xs = intArrayOf(10, 20, 30)
                xs[1]++
                println(xs[1])
                ++xs[2]
                println(xs[2])
                println(xs[1]++)
                println(xs[1])
            }
        "#;
        assert_eq!(run(src).lines, vec!["21", "31", "21", "22"]);
    }

    #[test]
    fn operator_inc_member() {
        let src = r#"
            class Box(var n: Int)
            fun main() {
                val b = Box(5)
                b.n++
                println(b.n)
                ++b.n
                println(b.n)
                println(b.n--)
                println(b.n)
            }
        "#;
        assert_eq!(run(src).lines, vec!["6", "7", "7", "6"]);
    }

    #[test]
    fn operator_inc_indexed_chained_eval_once() {
        // Spec ch.9: in `xs[idx()]++` the index expression evaluates once
        // (call-by-need), so a side-effecting `idx()` increments only once
        // even though the lowering reads-then-writes the slot.
        let src = r#"
            var calls = 0
            fun idx(): Int { calls = calls + 1; return 0 }
            fun main() {
                val xs = intArrayOf(100, 200)
                xs[idx()]++
                println(xs[0])
                println(calls)
            }
        "#;
        assert_eq!(run(src).lines, vec!["101", "1"]);
    }

    #[test]
    fn operator_invoke_user_class_member() {
        let src = r#"
            class Greeter(val prefix: String) {
                operator fun invoke(name: String): String = "$prefix, $name"
            }
            fun main() {
                val g = Greeter("hello")
                println(g("world"))
                println(g("kotlin"))
            }
        "#;
        assert_eq!(run(src).lines, vec!["hello, world", "hello, kotlin"]);
    }

    #[test]
    fn operator_invoke_extension() {
        let src = r#"
            class Counter(var n: Int)
            operator fun Counter.invoke(): Int { n = n + 1; return n }
            fun main() {
                val c = Counter(0)
                println(c())
                println(c())
                println(c())
            }
        "#;
        assert_eq!(run(src).lines, vec!["1", "2", "3"]);
    }

    #[test]
    fn operator_compareto_extension() {
        let src = r#"
            class Card(val rank: Int)
            operator fun Card.compareTo(other: Card): Int = rank - other.rank
            fun main() {
                println(Card(2) < Card(7))
                println(Card(9) > Card(7))
                println(Card(5) <= Card(5))
                println(Card(5) >= Card(5))
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "true", "true", "true"]);
    }

    #[test]
    fn operator_contains_user_class() {
        let src = r#"
            class Bag(val items: List<Int>) {
                operator fun contains(x: Int): Boolean {
                    for (i in items) if (i == x) return true
                    return false
                }
            }
            fun main() {
                val b = Bag(listOf(1, 2, 3))
                println(2 in b)
                println(7 in b)
                println(7 !in b)
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "false", "true"]);
    }

    #[test]
    fn coroutines_suspend_resume() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun double(x: Int): Int = suspendCoroutine { cont ->
                cont.resume(x * 2)
            }
            suspend fun chain(): Int {
                val a = double(5)
                val b = double(a)
                return a + b
            }
            fun main() {
                println(runBlocking { chain() })
            }
        "#;
        assert_eq!(run(src).lines, vec!["30"]);
    }

    #[test]
    fn coroutines_pipeline_three_step() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun step(x: Int): Int = suspendCoroutine<Int> { it.resume(x + 10) }
            suspend fun pipeline(): Int {
                val a = step(1)
                val b = step(a)
                val c = step(b)
                return c
            }
            fun main() {
                println(runBlocking { pipeline() })
            }
        "#;
        assert_eq!(run(src).lines, vec!["31"]);
    }

    #[test]
    fn coroutines_capture_and_resume_via_callback() {
        let src = r#"
            import kotlin.coroutines.*
            fun later(action: (Int) -> Unit) { action(99) }
            suspend fun deferred(): Int = suspendCoroutine<Int> { cont ->
                later { v -> cont.resume(v) }
            }
            suspend fun doWork(): Int {
                val a = deferred()
                return a + 1
            }
            fun main() { println(runBlocking { doWork() }) }
        "#;
        assert_eq!(run(src).lines, vec!["100"]);
    }

    #[test]
    fn coroutines_exception_through_try_catch() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun fails(): Int = suspendCoroutine<Int> { cont ->
                cont.resumeWithException(RuntimeException("nope"))
            }
            suspend fun caller(): Int {
                val a = try { fails() } catch (e: RuntimeException) { -1 }
                return a + 100
            }
            fun main() { println(runBlocking { caller() }) }
        "#;
        assert_eq!(run(src).lines, vec!["99"]);
    }

    #[test]
    fn coroutines_for_loop_with_synchronous_suspends() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun unit(x: Int): Int = suspendCoroutine<Int> { it.resume(x) }
            suspend fun sum(n: Int): Int {
                var total = 0
                for (i in 1..n) {
                    total = total + unit(i)
                }
                return total
            }
            fun main() { println(runBlocking { sum(5) }) }
        "#;
        assert_eq!(run(src).lines, vec!["15"]);
    }

    #[test]
    fn coroutines_if_branch_inside_suspend() {
        let src = r#"
            import kotlin.coroutines.*
            suspend fun unit(x: Int): Int = suspendCoroutine<Int> { it.resume(x) }
            suspend fun branchy(n: Int): Int {
                return if (n > 0) unit(n * 10) else unit(-n)
            }
            fun main() {
                println(runBlocking { branchy(5) })
                println(runBlocking { branchy(-3) })
            }
        "#;
        assert_eq!(run(src).lines, vec!["50", "3"]);
    }

    #[test]
    fn coroutines_resume_with_exception() {
        let src = r#"
            import kotlin.coroutines.*
            fun main() {
                val r = runCatching {
                    runBlocking {
                        suspendCoroutine<Int> { cont ->
                            cont.resumeWithException(RuntimeException("boom"))
                        }
                    }
                }
                println(r.isFailure)
                println(r.exceptionOrNull()?.message)
            }
        "#;
        assert_eq!(run(src).lines, vec!["true", "boom"]);
    }
}
