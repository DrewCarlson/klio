//! Front-end-to-IR module builder for the IR-native interpreter.
//!
//! `klio-interp-ir` deliberately does not depend on `klio-interp`.
//! This module owns the AST → IR lowering driver: it takes a parsed
//! Kotlin file and produces a `klio_ir::Module` ready for `Vm::run`.
//! Top-level property initialisers, class lowerings, and function
//! body lowerings happen here. As the cutover progresses the
//! responsibilities expand to include:
//!
//! * Pack class / fn merging (W11)
//! * Synthesised classes for anonymous objects + SAM wrappers (W4)
//! * Suspend state-machine lowering (W6)
//! * Reflection metadata population (W8)

use std::sync::Arc;

use klio_ast::{Decl, Expr, Ident, KotlinFile};
use klio_runtime::{ClassDef, ClassParamDef, PropertyDef};

mod lift;
use lift::{
    collect_used_qualified_supertypes, lift_class_recursive, rewrite_block_field,
    substitute_field_with_this, synthesize_class_from_object,
};

/// Result of building an IR module from a single Kotlin file.
pub struct BuiltModule {
    /// The frozen IR module ready for `Vm::run`.
    pub module: Arc<klio_ir::Module>,
    /// Per-class runtime metadata, keyed by simple class name. The
    /// Vm uses these when allocating instances. As the IR Class
    /// grows to carry the full runtime shape (methods, supertypes,
    /// init blocks lowered as `FuncIds`) this table shrinks and
    /// eventually goes away.
    pub classes: std::collections::HashMap<String, Arc<ClassDef>>,
    /// `(class name, property name) -> FuncId` for body properties
    /// with a literal-style initialiser (`val x: Int = 5`). The Vm
    /// invokes the `FuncId` during allocation to populate the field.
    /// Properties whose init references `this`, captured outer
    /// state, or another instance field land later as the IR grows
    /// to express them.
    pub body_prop_inits: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// `(class name, property name) -> FuncId` for body properties
    /// with a custom getter (`val full: String get() = "$first $last"`).
    /// The Vm calls these `FuncIds` (with `this` as the sole arg) when
    /// `Vm::get_field` is invoked for a custom-getter property.
    pub instance_prop_getters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Custom-setter `FuncIds`, keyed the same as getters. The Vm
    /// invokes the setter (`set(value) { … }`) when `set_field`
    /// targets a property whose class declares one.
    pub instance_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Parent-ctor argument thunks per class. Each entry is the
    /// list of `FuncIds` — one per parent ctor arg — that take the
    /// class's own primary-ctor params and return the value passed
    /// to the parent. `class Dog(name: String) : Animal(name)` ends
    /// up with `{ "Dog" => [thunk(name -> name)] }`.
    pub parent_ctor_args: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// `init { ... }` blocks per class. Each `FuncId` takes `this`
    /// as its sole param and runs the block's statements in order.
    /// `new_instance` invokes them after primary-ctor field
    /// binding + body-property init.
    pub init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// Top-level property initialisers (`val n = 0`). `Vm::run`
    /// invokes each in declaration order at startup so reads
    /// against the global env see the initial value.
    pub top_level_props: Vec<(String, klio_ir::FuncId)>,
    /// Top-level extension properties (`val T.name: U get() = …`).
    /// Keyed by `(receiver simple type name, property name)`. The
    /// Vm probes this table from `get_field` when a regular field
    /// lookup fails.
    pub extension_props: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Extension-property setters keyed by `(receiver type, prop)`.
    /// The Vm invokes the `FuncId` with `[receiver, value]` when
    /// `set_field` targets an extension property declared via
    /// `var T.x: ... set(value) { … }`.
    pub extension_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// `FuncId` of the file's `main`, or `None` when the file has no
    /// `main` entry point.
    pub main: Option<klio_ir::FuncId>,
    /// Names of `object Foo { … }` singleton declarations in source
    /// order. The Vm allocates one instance per name at startup and
    /// publishes it as a global so bare-name `Foo` reads resolve.
    pub object_names: Vec<String>,
    /// Outer-class name → synthesised companion singleton global
    /// name. `Foo.PI` routes through `companion_singletons["Foo"]`'s
    /// instance's `PI` field.
    pub companion_singletons: std::collections::HashMap<String, String>,
    /// Per enum-entry constructor-arg thunks. Each tuple is
    /// `(enum class name, entry name, thunk FuncIds)`. The Vm runs
    /// each thunk at startup and assigns the result into the entry
    /// instance's primary-ctor-param-named field.
    pub enum_entry_arg_inits: Vec<(String, String, Vec<klio_ir::FuncId>)>,
    /// Secondary-ctor dispatch table:
    /// `class_name -> Vec<SecondaryCtorEntry>`. The Vm walks each
    /// class's list when `new_instance` is called with an arity
    /// that doesn't match the primary constructor's signature.
    pub secondary_ctors: std::collections::HashMap<String, Vec<SecondaryCtorEntry>>,
    /// Per-class primary-constructor default-value thunks: one
    /// `Option<FuncId>` slot per primary param (`Some` when the param
    /// declares a default). Each thunk is lowered over `[this,
    /// primary-params…]` so a default may reference an earlier
    /// parameter; `new_instance` evaluates the slot for any param a
    /// caller omits, so a non-literal default (`parameters:
    /// Parameters = Parameters.Empty`, `port: Int = DEFAULT_PORT`)
    /// produces its real value rather than `Null`.
    pub primary_ctor_default_thunks:
        std::collections::HashMap<String, Vec<Option<klio_ir::FuncId>>>,
    /// Class delegation entries: `class W(g: Greeter) : Greeter by g`.
    /// Each tuple is `(supertype simple name, thunk FuncId taking
    /// primary-ctor params)`. The Vm evaluates these at construction
    /// time and stores the result under `__delegate__<superName>` on
    /// the instance; missing methods on `W` then forward to the
    /// delegate.
    pub class_delegates: std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    /// Per-function default-arg thunks. Each entry is keyed by the
    /// target function's `FuncId` and holds an
    /// `Option<FuncId>` slot per parameter; `Some(fid)` runs the
    /// default-init thunk when the caller omits the arg.
    pub func_defaults: std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    /// Inner class → outer class name. Populated during the
    /// recursive lift so the Vm can resolve `this@Outer.X` and
    /// outer-chain field lookups for nested classes lifted to
    /// top-level decls.
    pub enclosing_class: std::collections::HashMap<String, String>,
    /// Pre-lowered method bodies for enum entries with per-entry
    /// `override fun …` blocks. Keyed by (synth class name,
    /// method name) where the synth class is `<EnumClass>$<Entry>`.
    /// The Vm tags each entry instance and routes `call_member`
    /// through this table when the entry has its own overrides.
    pub enum_entry_methods: std::collections::HashMap<
        (String, String),
        (std::sync::Arc<klio_ir::Module>, klio_ir::FuncId),
    >,
    /// `(enum class name, entry name) -> synth class name` for
    /// entries whose body declares method overrides. The Vm reads
    /// this to identify which enum entries have per-entry methods.
    pub enum_entry_synth_class: std::collections::HashMap<(String, String), String>,
    /// Per-function type parameter names (in source order). The Vm
    /// uses this to bind reified type-args as synthesized
    /// `Value::Class` globals for the duration of the call.
    pub func_type_params: std::collections::HashMap<klio_ir::FuncId, Vec<String>>,
    /// Top-level property names declared as `var/val X by <delegate>`.
    pub top_level_delegated_props: std::collections::HashSet<String>,
    /// Body-property `(class, prop)` pairs declared as `by <delegate>`.
    pub delegated_body_props: std::collections::HashSet<(String, String)>,
}

/// Pre-lowered metadata for one secondary constructor. Each entry's
/// `arg_thunks` evaluate the delegation arguments (`: this(...)` or
/// `: super(...)`) against the secondary's positional params, then
/// the Vm dispatches the resulting args to the primary ctor.
#[derive(Clone)]
pub struct SecondaryCtorEntry {
    pub param_count: usize,
    /// Declared parameter names, in order — lets a named call
    /// (`DatePeriod(months = 1)`) reorder against this constructor's own
    /// signature rather than the primary's.
    pub param_names: Vec<String>,
    pub is_super: bool,
    /// `true` for an explicit `: this(...)` delegation. Distinguishes
    /// it from `CtorDelegation::None` (implicit `super()`), which also
    /// has `is_super == false` but must build the instance shell
    /// rather than re-dispatch a sibling constructor.
    pub is_this: bool,
    pub delegation_arg_thunks: Vec<klio_ir::FuncId>,
    /// Per-parameter default-value thunks (one slot per declared param;
    /// `None` when the param has no default). Each is lowered over the
    /// full param list so a default may reference an earlier parameter;
    /// the dispatcher evaluates the trailing ones a caller omitted.
    pub default_arg_thunks: Vec<Option<klio_ir::FuncId>>,
    /// Optional body block lowered as a 1-arg fn taking `this`.
    pub body: Option<klio_ir::FuncId>,
}

/// Lower a single file's declarations into an IR module. Classes are
/// lowered first so `Inst::NewInstance` lookups resolve, then a
/// pre-pass registers stub Funcs for every top-level function so
/// forward references and mutual recursion lower cleanly, then each
/// function body lowers into its reserved slot.
///
/// Top-level property initialisers + delegated properties are not
/// yet wired through — that lands with the property accessor
/// workstream.
/// Drive `build_module` against multiple parsed files. All
/// declarations from every file are concatenated into one
/// synthesised `KotlinFile` and lowered as a single program. Used
/// by `klio run a.kt b.kt …` to share class + function visibility
/// across the sibling files without going through `klio-interp`'s
/// module registry.
#[must_use]
pub fn build_module_files(files: &[KotlinFile]) -> BuiltModule {
    use klio_span::{FileId, Span};
    let mut combined = KotlinFile {
        package: None,
        imports: Vec::new(),
        decls: Vec::new(),
        span: Span::new(FileId(0), 0, 0),
    };
    // Per-class FQN overrides: each pack file's `package` header
    // attaches a `<package>.` prefix to every class declared in
    // that file. The combined module has `package = None`, so the
    // build pass would otherwise emit bare-name FQNs and any
    // FQN-keyed stdlib/pack binding wouldn't resolve at dispatch.
    // Keyed by each class declaration's span (unique per declaration)
    // rather than its simple name: two packs may declare the same
    // simple name in different packages, and a name-keyed map would
    // collapse them to a single (last-writer) FQN.
    let mut fqn_overrides: std::collections::HashMap<klio_span::Span, String> =
        std::collections::HashMap::new();
    // Span-keyed (each function declaration's span is unique) so two
    // pack files declaring the same simple name in different
    // packages don't collapse onto one FQN — same shape the
    // class-side `fqn_overrides` already uses.
    let mut func_fqn_overrides: std::collections::HashMap<klio_span::Span, String> =
        std::collections::HashMap::new();
    for f in files {
        let prefix: String = f
            .package
            .as_ref()
            .map(|p| {
                p.path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".")
            })
            .unwrap_or_default();
        for d in &f.decls {
            collect_class_fqns(d, &prefix, &mut fqn_overrides);
            if let Decl::Function(fn_d) = d
                && !prefix.is_empty()
            {
                func_fqn_overrides.insert(fn_d.span, format!("{}.{}", prefix, fn_d.name.name));
            }
        }
        combined.decls.extend(f.decls.iter().cloned());
        combined.imports.extend(f.imports.iter().cloned());
    }
    build_module_with_overrides(&combined, &fqn_overrides, &func_fqn_overrides)
}

fn collect_class_fqns(
    d: &Decl,
    pkg: &str,
    out: &mut std::collections::HashMap<klio_span::Span, String>,
) {
    if let Decl::Class(c) = d {
        if !pkg.is_empty() {
            out.insert(c.span, format!("{}.{}", pkg, c.name.name));
        }
        // Recurse with the enclosing class appended so nested
        // declarations get proper `pkg.Outer.Inner` FQNs. A flat
        // `pkg` would give every package's `companion object` the
        // same `pkg.Companion`, making FQNs non-unique and
        // mis-resolving FQN-keyed lookups.
        let inner_pkg = if pkg.is_empty() {
            c.name.name.clone()
        } else {
            format!("{}.{}", pkg, c.name.name)
        };
        for m in &c.members {
            collect_class_fqns(m, &inner_pkg, out);
        }
    }
    if let Decl::Object(o) = d
        && !pkg.is_empty()
    {
        out.insert(o.span, format!("{}.{}", pkg, o.name.name));
    }
}

#[must_use]
pub fn build_module(file: &KotlinFile) -> BuiltModule {
    build_module_with_overrides(
        file,
        &std::collections::HashMap::new(),
        &std::collections::HashMap::new(),
    )
}

/// Collect the member names (property-params, body properties, member
/// functions) declared by `start` and every supertype reachable from
/// it among the module's class declarations. Used so a class body's
/// bare references — and call-position name resolution — see inherited
/// members, not just the class's own, matching Kotlin's separate
/// function/property namespaces (a `name(args)` call resolves to an
/// inherited member function even when a same-named value is in scope).
fn collect_hierarchy_method_names(
    start: &str,
    by_name: &std::collections::HashMap<String, &klio_ast::Class>,
    out: &mut std::collections::HashSet<String>,
    seen: &mut std::collections::HashSet<String>,
) {
    if !seen.insert(start.to_string()) {
        return;
    }
    let Some(c) = by_name.get(start) else {
        return;
    };
    for m in &c.members {
        if let Decl::Function(f) = m {
            out.insert(f.name.name.clone());
        }
    }
    for st in &c.supertypes {
        collect_hierarchy_method_names(&st.name.name, by_name, out, seen);
    }
}

/// Like [`collect_hierarchy_method_names`] but also gathers property
/// and property-parameter names across the hierarchy. Used to seed an
/// init block's bare-name set so an inherited member referenced
/// without an explicit receiver (e.g. `initParentJob(parent)` from a
/// subclass `init`) lowers as `this.<name>` rather than a global.
fn collect_hierarchy_member_names(
    start: &str,
    by_name: &std::collections::HashMap<String, &klio_ast::Class>,
    out: &mut std::collections::HashSet<String>,
    seen: &mut std::collections::HashSet<String>,
) {
    if !seen.insert(start.to_string()) {
        return;
    }
    let Some(c) = by_name.get(start) else {
        return;
    };
    for p in &c.primary_params {
        if p.property.is_some() {
            out.insert(p.name.name.clone());
        }
    }
    for m in &c.members {
        match m {
            Decl::Function(f) => {
                out.insert(f.name.name.clone());
            }
            Decl::Property(p) => {
                out.insert(p.name.name.clone());
            }
            _ => {}
        }
    }
    for st in &c.supertypes {
        collect_hierarchy_member_names(&st.name.name, by_name, out, seen);
    }
}

// Int literals narrow to i32 and Double literals narrow to f32, matching
// Kotlin's Int/Float literal types.
#[allow(clippy::cast_possible_truncation)]
fn literal_to_const(e: &klio_ast::Expr) -> Option<klio_ir::Const> {
    use klio_ast::Expr;
    match e {
        Expr::IntLit { value, kind, .. } => match kind {
            klio_ast::IntLitKind::Int | klio_ast::IntLitKind::UInt => {
                Some(klio_ir::Const::Int(*value as i32))
            }
            klio_ast::IntLitKind::Long | klio_ast::IntLitKind::ULong => {
                Some(klio_ir::Const::Long(*value))
            }
        },
        Expr::FloatLit { value, kind, .. } => match kind {
            klio_ast::FloatLitKind::Double => Some(klio_ir::Const::Double(*value)),
            klio_ast::FloatLitKind::Float => Some(klio_ir::Const::Float(*value as f32)),
        },
        Expr::BoolLit { value, .. } => Some(klio_ir::Const::Bool(*value)),
        Expr::CharLit { value, .. } => Some(klio_ir::Const::Char(*value)),
        Expr::StringTemplate { parts, .. } if parts.len() == 1 => match &parts[0] {
            klio_ast::StringPart::Text(s) => Some(klio_ir::Const::String(s.clone())),
            _ => None,
        },
        _ => None,
    }
}

/// Default `Value` for a property declared as a non-nullable primitive
/// with no initializer. Used so an `expect`-declared `protected var
/// modCount: Int` and similar non-null fields start as `0` instead of
/// `Null` at instance construction.
pub(crate) fn primitive_zero_for(p: &klio_ast::Property) -> Option<klio_runtime::Value> {
    if p.init.is_some()
        || p.is_abstract
        || p.is_lateinit
        || p.getter.is_some()
        || p.delegate.is_some()
    {
        return None;
    }
    let ty = p.ty.as_ref()?;
    if ty.nullable {
        return None;
    }
    match ty.name.name.as_str() {
        "Int" => Some(klio_runtime::Value::Int(0)),
        "Long" => Some(klio_runtime::Value::Long(0)),
        "Short" => Some(klio_runtime::Value::Short(0)),
        "Byte" => Some(klio_runtime::Value::Byte(0)),
        "Float" => Some(klio_runtime::Value::Float(0.0)),
        "Double" => Some(klio_runtime::Value::Double(0.0)),
        "Boolean" => Some(klio_runtime::Value::Bool(false)),
        "Char" => Some(klio_runtime::Value::Char(0u16)),
        _ => None,
    }
}

// The whole-file lowering pass: one cohesive walk that threads many shared
// builders and registries through tightly-coupled phases. Splitting it would
// fragment that shared state and risk changing lowering order.
// instance_prop_getters / instance_prop_setters mirror the matching
// ProgramImage field names, so they read alike by design.
#[allow(clippy::too_many_lines, clippy::similar_names)]
fn build_module_with_overrides(
    file: &KotlinFile,
    fqn_overrides: &std::collections::HashMap<klio_span::Span, String>,
    func_fqn_overrides: &std::collections::HashMap<klio_span::Span, String>,
) -> BuiltModule {
    let mut module = klio_ir::Module::default();
    let package_prefix: String = file
        .package
        .as_ref()
        .map(|p| {
            p.path
                .iter()
                .map(|i| i.name.as_str())
                .collect::<Vec<_>>()
                .join(".")
        })
        .unwrap_or_default();

    // Synthesise a `Class` for every `object` declaration so the
    // shared class-lowering pipeline picks them up (members, init,
    // supertypes, accessors). A separate `object_names` list tells
    // the Vm to allocate one instance per object at startup.
    let mut object_names: Vec<String> = Vec::new();
    let mut companion_singletons: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    // Map from lifted nested class name → set of names visible in
    // the outer scope (primary-ctor properties + body members).
    // Lowering merges these into `own_members` so bare references
    // inside the nested class's method bodies lower as
    // `this.<name>` and resolve via the captured outer at runtime.
    let mut nested_outer_members: std::collections::HashMap<
        String,
        std::collections::HashSet<String>,
    > = std::collections::HashMap::new();
    let mut enclosing_class: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    let mut nested_object_aliases: std::collections::HashMap<
        String,
        std::collections::HashMap<String, String>,
    > = std::collections::HashMap::new();
    // An `actual object Foo` supersedes a matching `expect object
    // Foo`. Collect actual-object names up front so the superseded
    // `expect` singleton is neither synthesised into a class nor
    // registered in `object_names` (a bodyless duplicate would
    // shadow the real definition and break member dispatch).
    let actual_object_names: std::collections::HashSet<String> = file
        .decls
        .iter()
        .filter_map(|d| match d {
            Decl::Object(o) if o.is_actual => Some(o.name.name.clone()),
            _ => None,
        })
        .collect();
    // An `actual class Foo` supersedes a matching `expect class Foo`.
    // Collected up front so the superseded `expect` is skipped *before*
    // lifting: otherwise its (bodyless) companion is lifted alongside the
    // actual's real companion, the two `Foo$Companion$Companion` decls
    // collide, and the bodyless one can win — `Foo.parse(...)` then hits
    // `Vm::call_member on KClass`. The later all_decls retain drops the
    // expect class itself, so skipping its lift is consistent.
    let actual_class_names: std::collections::HashSet<String> = file
        .decls
        .iter()
        .filter_map(|d| match d {
            Decl::Class(c) if c.is_actual => Some(c.name.name.clone()),
            _ => None,
        })
        .collect();
    // A `private` top-level `object` declared in a pack package (e.g.
    // `private object State` in kotlin.collections/AbstractIterator.kt)
    // is file-private upstream, but klio publishes every top-level
    // object's singleton under its bare simple name. When a user
    // program declares a type with the same simple name (`class State`),
    // the pack singleton shadows it in bare-name resolution and
    // `State.Active` mis-resolves. To prevent that, such a colliding
    // pack-private object is registered under a `$`-mangled FQN-derived
    // name, and an alias (simple -> mangled) is recorded for every pack
    // class declared in the SAME package so the pack's own bodies (the
    // object is only referenced from siblings in its file/package) keep
    // resolving the bare name. Detection: a top-level object WITH an
    // fqn_override (packaged) whose simple name matches a top-level
    // type WITHOUT an fqn_override (the package-less user program).
    let user_top_type_names: std::collections::HashSet<String> = file
        .decls
        .iter()
        .filter_map(|d| match d {
            Decl::Class(c) if !fqn_overrides.contains_key(&c.span) => Some(c.name.name.clone()),
            Decl::Object(o) if !fqn_overrides.contains_key(&o.span) => Some(o.name.name.clone()),
            _ => None,
        })
        .collect();
    // package -> set of pack class/object simple names declared in it
    // (used to scope the bare-name alias for a mangled object).
    let mut pack_pkg_types: std::collections::HashMap<String, std::collections::HashSet<String>> =
        std::collections::HashMap::new();
    for d in &file.decls {
        let (span, simple) = match d {
            Decl::Class(c) => (c.span, c.name.name.clone()),
            Decl::Object(o) => (o.span, o.name.name.clone()),
            _ => continue,
        };
        if let Some(fqn) = fqn_overrides.get(&span)
            && let Some((pkg, _)) = fqn.rsplit_once('.')
        {
            pack_pkg_types
                .entry(pkg.to_string())
                .or_default()
                .insert(simple);
        }
    }
    // Pending aliases for mangled pack-private objects, applied after
    // all class names are known: (referencing-class-simple-name,
    // object-simple-name, mangled-name).
    let mut pending_object_aliases: Vec<(String, String, String)> = Vec::new();
    // Nested classes mangled to `Outer$Name` on a top-level name collision:
    // qualified source name (`Outer.Name`) → mangled name. A post-pass
    // rewrites subclass supertype references to the mangled name.
    let mut mangled_nested: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    // Simple names declared as a true *top-level* class/object anywhere in
    // the (merged) module. A nested `object` lifted to top level under its
    // bare name would overwrite a same-named top-level class in the global
    // table (last writer wins, so the outcome depends on source load order).
    // `lift_class_recursive` mangles a nested object whose name is in this
    // set to `Outer$Name` instead, leaving the bare name to the real
    // top-level type; `get_field` on a class receiver resolves the mangled
    // form for qualified `Outer.Name` access.
    let top_level_type_names: std::collections::HashSet<String> = file
        .decls
        .iter()
        .filter_map(|d| match d {
            Decl::Class(c) => Some(c.name.name.clone()),
            Decl::Object(o) => Some(o.name.name.clone()),
            _ => None,
        })
        .collect();
    // The set of qualified supertype paths actually used (`Outer.Name`, last
    // two segments). A nested class is only mangled to `Outer$Name` when some
    // class extends it this way — the self-collision that breaks the class
    // table. Without this, a nested type whose simple name merely coincides
    // with an unrelated (e.g. stdlib) type — `TrafficLight.State` vs a
    // stdlib `State` — would be mangled and its bare references broken.
    let used_qualified_supertypes = collect_used_qualified_supertypes(&file.decls);
    let mut all_decls: Vec<Decl> = Vec::with_capacity(file.decls.len());
    for d in &file.decls {
        match d {
            Decl::Object(o) => {
                if o.is_expect && actual_object_names.contains(&o.name.name) {
                    continue;
                }
                let is_pack_private = matches!(o.visibility, klio_ast::Visibility::Private)
                    && fqn_overrides.contains_key(&o.span);
                let collides = user_top_type_names.contains(&o.name.name);
                if is_pack_private && collides {
                    let fqn = fqn_overrides.get(&o.span).cloned().unwrap_or_default();
                    let mangled = fqn.replace('.', "$");
                    object_names.push(mangled.clone());
                    let mut synth = synthesize_class_from_object(o);
                    synth.name = klio_ast::Ident {
                        name: mangled.clone(),
                        span: o.name.span,
                    };
                    all_decls.push(Decl::Class(synth));
                    // Record the alias for every pack class in this
                    // object's package so their bodies keep resolving
                    // the bare object name to the mangled singleton.
                    if let Some((pkg, _)) = fqn.rsplit_once('.')
                        && let Some(types) = pack_pkg_types.get(pkg)
                    {
                        for cls in types {
                            if cls != &o.name.name {
                                pending_object_aliases.push((
                                    cls.clone(),
                                    o.name.name.clone(),
                                    mangled.clone(),
                                ));
                            }
                        }
                    }
                    continue;
                }
                object_names.push(o.name.name.clone());
                // Lift the object's nested classes/objects to top level
                // exactly as a class's are — otherwise a nested type such
                // as `Send.Sender` (a class inside an `object Send`) is
                // never registered and `Send.Sender(…)` / a bare `Sender(…)`
                // inside the object's methods mis-dispatches as a member
                // call on the singleton instead of constructing the nested
                // class.
                let synth = synthesize_class_from_object(o);
                lift_class_recursive(
                    &synth,
                    &[],
                    &mut all_decls,
                    &mut object_names,
                    &mut companion_singletons,
                    &mut nested_outer_members,
                    &mut enclosing_class,
                    &mut nested_object_aliases,
                    &top_level_type_names,
                    &mut mangled_nested,
                    &used_qualified_supertypes,
                );
                all_decls.push(Decl::Class(synth));
            }
            Decl::Class(c) => {
                if c.is_expect && actual_class_names.contains(&c.name.name) {
                    // Superseded by an `actual class`; don't lift it (its
                    // bodyless companion would collide with the actual's
                    // real one). The retain below drops the expect class
                    // regardless, so omitting it here is equivalent.
                    continue;
                }
                lift_class_recursive(
                    c,
                    &[],
                    &mut all_decls,
                    &mut object_names,
                    &mut companion_singletons,
                    &mut nested_outer_members,
                    &mut enclosing_class,
                    &mut nested_object_aliases,
                    &top_level_type_names,
                    &mut mangled_nested,
                    &used_qualified_supertypes,
                );
                all_decls.push(d.clone());
            }
            other => all_decls.push(other.clone()),
        }
    }
    // Wire the package-scoped aliases for any mangled pack-private
    // top-level objects (see the collision note above): each pack class
    // in the object's package resolves the bare object name to its
    // mangled singleton, mirroring the per-class nested-object alias.
    for (cls, simple, mangled) in pending_object_aliases {
        nested_object_aliases
            .entry(cls)
            .or_default()
            .insert(simple, mangled);
    }
    // Repoint supertype references to a nested class that was mangled on a
    // top-level name collision: a subclass `X : Outer.Inner` parses its
    // supertype with `qualified_path = "Outer.Inner"`, while `name` kept the
    // colliding bare `Inner`. Rewrite the bare name to the mangled
    // `Outer$Inner` so parent resolution, `is`-checks, and ctor chaining
    // bind the real nested class instead of the same-named top-level one.
    if !mangled_nested.is_empty() {
        let resolve = |t: &klio_ast::TypeRef| -> Option<String> {
            let qp = t.qualified_path.as_ref()?;
            // Match on the last two segments (`Outer.Inner`); the source may
            // carry a package prefix the map key omits.
            let segs: Vec<&str> = qp.split('.').collect();
            let key = if segs.len() >= 2 {
                format!("{}.{}", segs[segs.len() - 2], segs[segs.len() - 1])
            } else {
                qp.clone()
            };
            mangled_nested.get(&key).cloned()
        };
        for d in &mut all_decls {
            if let Decl::Class(c) = d {
                for t in &mut c.supertypes {
                    if let Some(mangled) = resolve(t) {
                        t.name.name = mangled;
                    }
                }
            }
        }
    }
    // The inline lift loop below has been replaced by
    // `lift_class_recursive`. Disable the original arm so it
    // doesn't execute twice and produce duplicate decls.
    if false {
        for d in &file.decls {
            if let Decl::Class(c) = d {
                for m in &c.members {
                    if let Decl::Object(co) = m {
                        let comp_name = format!("{}$Companion${}", c.name.name, co.name.name);
                        let mut renamed = co.clone();
                        renamed.name = klio_ast::Ident {
                            name: comp_name.clone(),
                            span: co.name.span,
                        };
                        object_names.push(comp_name.clone());
                        all_decls.push(Decl::Class(synthesize_class_from_object(&renamed)));
                        companion_singletons.insert(c.name.name.clone(), comp_name);
                    } else if let Decl::Class(nested) = m {
                        if nested.is_companion {
                            let comp_name =
                                format!("{}$Companion${}", c.name.name, nested.name.name);
                            let mut renamed = nested.clone();
                            renamed.name = klio_ast::Ident {
                                name: comp_name.clone(),
                                span: nested.name.span,
                            };
                            renamed.is_companion = false;
                            // Outer members visible inside the
                            // companion body: primary-ctor + body
                            // names from the enclosing class, plus
                            // enum-specific statics (`entries`,
                            // `values`, `valueOf`) and entry names
                            // when the enclosing class is an enum.
                            let mut extras: std::collections::HashSet<String> =
                                std::collections::HashSet::new();
                            for p in &c.primary_params {
                                extras.insert(p.name.name.clone());
                            }
                            for m in &c.members {
                                match m {
                                    Decl::Property(p) => {
                                        extras.insert(p.name.name.clone());
                                    }
                                    Decl::Function(f) => {
                                        extras.insert(f.name.name.clone());
                                    }
                                    _ => {}
                                }
                            }
                            if c.is_enum {
                                extras.insert("entries".to_string());
                                extras.insert("values".to_string());
                                extras.insert("valueOf".to_string());
                                for e in &c.enum_entries {
                                    extras.insert(e.name.name.clone());
                                }
                            }
                            nested_outer_members.insert(comp_name.clone(), extras);
                            // Companion instances behave like
                            // singletons — register one global.
                            object_names.push(comp_name.clone());
                            all_decls.push(Decl::Class(renamed));
                            companion_singletons.insert(c.name.name.clone(), comp_name);
                        } else {
                            // Plain nested + inner classes — lift
                            // to top level so bare-name access
                            // inside the outer class resolves
                            // through the module's class table.
                            let mut extras: std::collections::HashSet<String> =
                                std::collections::HashSet::new();
                            for p in &c.primary_params {
                                extras.insert(p.name.name.clone());
                            }
                            for m in &c.members {
                                match m {
                                    Decl::Property(p) => {
                                        extras.insert(p.name.name.clone());
                                    }
                                    Decl::Function(f) => {
                                        extras.insert(f.name.name.clone());
                                    }
                                    _ => {}
                                }
                            }
                            nested_outer_members.insert(nested.name.name.clone(), extras);
                            all_decls.push(Decl::Class(nested.clone()));
                        }
                    }
                }
                all_decls.push(d.clone());
            }
        }
    }
    // Pre-collect actual-name sets so the closures used below can
    // skip `expect` declarations that have a matching `actual`.
    let actual_func_names_set: std::collections::HashSet<String> = all_decls
        .iter()
        .filter_map(|d| match d {
            Decl::Function(f) if f.is_actual => Some(f.name.name.clone()),
            _ => None,
        })
        .collect();
    let actual_class_names_set: std::collections::HashSet<String> = all_decls
        .iter()
        .filter_map(|d| match d {
            Decl::Class(c) if c.is_actual => Some(c.name.name.clone()),
            _ => None,
        })
        .collect();
    let actual_object_names_set: std::collections::HashSet<String> = all_decls
        .iter()
        .filter_map(|d| match d {
            Decl::Object(o) if o.is_actual => Some(o.name.name.clone()),
            _ => None,
        })
        .collect();
    // An `actual val`/`actual var` supersedes a matching bodyless
    // `expect val`/`expect var`. Unlike classes/funs/objects, a
    // top-level property has no overload key, so a same-name expect and
    // actual would both lower to a global init — the bodyless expect
    // (no initializer) racing the actual's real init, leaving the
    // global at its null/zero default depending on lowering order.
    // Collecting actual property names lets the retain drop the expect.
    let actual_prop_names_set: std::collections::HashSet<String> = all_decls
        .iter()
        .filter_map(|d| match d {
            Decl::Property(p) if p.is_actual => Some(p.name.name.clone()),
            _ => None,
        })
        .collect();
    // Drop superseded `expect` decls so every downstream pass sees
    // only the active definition for each name.
    all_decls.retain(|d| match d {
        Decl::Function(f) => {
            // Upstream's `suspend inline fun suspendCoroutineUninterceptedOrReturn`
            // is a stub that throws NotImplementedError; the compiler is
            // expected to substitute it. Klio ships a real non-inline,
            // non-suspend implementation in kotlin-coroutines/Intrinsics.kt
            // that drives the slot machinery. Distinguish them by signature
            // so only the upstream stub is dropped.
            if !f.is_expect
                && f.name.name == "suspendCoroutineUninterceptedOrReturn"
                && f.is_inline
                && f.is_suspend
            {
                return false;
            }
            // Upstream's empty-collection factories return singleton
            // `internal object` instances (EmptyList/EmptySet/EmptyMap)
            // that klio's operator dispatch can't recognise as the
            // matching Value::List/Set/Map. Drop the bodies so the
            // klio-stdlib intrinsic returns the right Value kind and
            // `list + elem`, `map - key`, etc. work uniformly.
            if !f.is_expect
                && matches!(f.name.name.as_str(), "emptyList" | "emptySet" | "emptyMap")
                && f.params.is_empty()
            {
                return false;
            }
            // Lazy-sequence factories/builders: klio represents a
            // Sequence as the host Value::Sequence and implements
            // take/map/filter/toList etc. as intrinsics on it. The
            // upstream factory bodies construct upstream Sequence-class
            // INSTANCES (GeneratorSequence/TakeSequence/…) that klio's
            // intrinsics don't recognise (iterating one hits `hasNext on
            // Nothing`); the `sequence { }` / `iterator { }` builders
            // construct a coroutine state machine klio can't run. Drop
            // the bodies so the bare call routes to klio's
            // `kotlin.sequences.*` intrinsic. Gated on the
            // `kotlin.sequences` package FQN so a same-named user fn
            // (especially `iterator`, which collides with many member
            // iterators) is never dropped.
            if !f.is_expect
                && matches!(
                    f.name.name.as_str(),
                    "generateSequence" | "sequenceOf" | "emptySequence" | "sequence" | "iterator"
                )
            {
                let fqn = func_fqn_overrides.get(&f.span).map(String::as_str);
                if fqn == Some(&format!("kotlin.sequences.{}", f.name.name)[..]) {
                    return false;
                }
            }
            // Collection factory functions whose upstream bodies build the
            // result via Array.toMap(dest)/toCollection(dest)/filterNotNull —
            // ops that misbehave on klio's host Array (the destination
            // overload is dropped / a generic `as Array` cast fails), so the
            // factory silently yields an empty or first-only collection. klio
            // implements these factories directly as intrinsics; drop the
            // bodied upstream version (FQN-gated to kotlin.collections, and
            // only when the intrinsic exists) so the bare call routes to the
            // intrinsic instead of the broken body.
            if !f.is_expect
                && matches!(
                    f.name.name.as_str(),
                    "linkedMapOf"
                        | "hashMapOf"
                        | "linkedStringMapOf"
                        | "hashSetOf"
                        | "linkedSetOf"
                        | "sortedSetOf"
                        | "sortedMapOf"
                        | "arrayListOf"
                        | "listOfNotNull"
                        | "setOfNotNull"
                )
            {
                let expected = format!("kotlin.collections.{}", f.name.name);
                let fqn = func_fqn_overrides.get(&f.span).cloned().unwrap_or_else(|| {
                    if package_prefix.is_empty() {
                        f.name.name.clone()
                    } else {
                        format!("{}.{}", package_prefix, f.name.name)
                    }
                });
                if fqn == expected && klio_stdlib::implementation(&expected).is_some() {
                    return false;
                }
            }
            if !f.is_expect {
                return true;
            }
            if actual_func_names_set.contains(&f.name.name) {
                return false;
            }
            // An upstream `expect fun` whose declared FQN is already
            // implemented by a klio intrinsic is shadowed by the
            // host's actual — drop the expect so resolution at lower
            // / runtime time doesn't bind to a bodyless declaration
            // and stop the intrinsic dispatch path from firing.
            let fqn = func_fqn_overrides.get(&f.span).cloned().unwrap_or_else(|| {
                if package_prefix.is_empty() {
                    f.name.name.clone()
                } else {
                    format!("{}.{}", package_prefix, f.name.name)
                }
            });
            if klio_stdlib::implementation(&fqn).is_some() {
                return false;
            }
            // A non-extension factory `expect fun` can live in a
            // different package than the klio intrinsic that implements
            // it — e.g. `kotlin.text.String(chars)` /
            // `kotlin.text.String(chars, offset, length)` are backed by
            // the `kotlin.String` host ctor, and the internal
            // `kotlin.collections.arrayOfNulls(reference, size)` /
            // `kotlin.emptyArray` overloads by `kotlin.<name>`. The
            // exact-FQN check above misses these, leaving the bodyless
            // overload to shadow the intrinsic in bare-name resolution
            // (the call binds the empty body and yields Unit). Drop any
            // bodyless non-extension expect whose simple name is backed
            // by a `kotlin.<name>` intrinsic so the bare call routes to
            // the host ctor. Receiver-qualified expects keep flowing
            // through member dispatch, which already reaches the
            // intrinsic, so they are left in place.
            if f.receiver_type.is_none()
                && klio_stdlib::implementation(&format!("kotlin.{}", f.name.name)).is_some()
            {
                return false;
            }
            // Coroutine intrinsic expect funcs: klio implements the
            // coroutine surface natively (continuation passing /
            // scheduler), not via per-FQN intrinsics. Drop upstream
            // bodyless expects so callers don't bind to them and
            // bounce through klio's native dispatch instead.
            if fqn.starts_with("kotlin.coroutines.") {
                return false;
            }
            true
        }
        Decl::Class(c) => !(c.is_expect && actual_class_names_set.contains(&c.name.name)),
        Decl::Object(o) => !(o.is_expect && actual_object_names_set.contains(&o.name.name)),
        Decl::Property(p)
            if matches!(p.name.name.as_str(), "coroutineContext" | "isInitialized") =>
        {
            // Upstream declares these as `inline val` whose getter
            // throws NotImplementedError ("Implementation is intrinsic")
            // — meant for compiler intrinsic substitution. Klio
            // substitutes them at runtime (active coroutine scope,
            // lateinit-state probe); drop the upstream stub so the
            // call routes through klio's dispatch.
            false
        }
        Decl::Property(p) => !(p.is_expect && actual_prop_names_set.contains(&p.name.name)),
        _ => true,
    });
    let decls: &[Decl] = &all_decls;

    // Map every class declaration by simple name so class-to-class
    // member-name lookups during body lowering have access to the
    // wider file's class shape.
    let mut file_classes: std::collections::HashMap<String, &klio_ast::Class> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            file_classes.insert(c.name.name.clone(), c);
        }
    }
    // Collect class / companion `const val name = <literal>` so the
    // lowering pass can inline bare references to them — avoids
    // companion-singleton init order issues when the enclosing
    // class's primary ctor body reads a companion's `const val`.
    {
        fn collect_consts(
            cls_name: &str,
            members: &[Decl],
            out: &mut std::collections::HashMap<(String, String), klio_ir::Const>,
        ) {
            for m in members {
                match m {
                    Decl::Property(p) if p.is_const => {
                        if let Some(init) = &p.init
                            && let Some(c) = literal_to_const(init)
                        {
                            out.insert((cls_name.to_string(), p.name.name.clone()), c);
                        }
                    }
                    Decl::Class(inner) if inner.is_companion => {
                        collect_consts(cls_name, &inner.members, out);
                    }
                    _ => {}
                }
            }
        }
        let mut class_const_inits: std::collections::HashMap<(String, String), klio_ir::Const> =
            std::collections::HashMap::new();
        for d in decls {
            match d {
                Decl::Class(c) => {
                    collect_consts(&c.name.name, &c.members, &mut class_const_inits);
                }
                // Top-level `const val` (`public const val DEFAULT_PORT = 0`)
                // is a compile-time constant; register it under the sentinel
                // empty-class key so a bare reference inlines the literal
                // (Kotlin's `const val` semantics). Without inlining, a
                // reference read as a runtime global is `Null` when an eager
                // companion/object initializer runs at load before the const's
                // own slot is set (`URLBuilder.Companion`'s `Url(origin)` reads
                // `port = DEFAULT_PORT`).
                Decl::Property(p) if p.is_const => {
                    if let Some(init) = &p.init
                        && let Some(c) = literal_to_const(init)
                    {
                        class_const_inits.insert((String::new(), p.name.name.clone()), c);
                    }
                }
                _ => {}
            }
        }
        module.registry.class_const_inits = class_const_inits;
    }
    // Per-class transitive member-function-name set, so the lowerer
    // can resolve a call-position `name(args)` to a hierarchy member
    // function even when a same-named value/param shadows it.
    let hierarchy_methods: std::collections::HashMap<String, std::collections::HashSet<String>> =
        file_classes
            .keys()
            .map(|cname| {
                let mut methods = std::collections::HashSet::new();
                let mut seen = std::collections::HashSet::new();
                collect_hierarchy_method_names(cname, &file_classes, &mut methods, &mut seen);
                (cname.clone(), methods)
            })
            .collect();
    // Visible to `FuncBuilder` during the body-lowering passes below
    // (the registry is otherwise only assembled at the end of this
    // function, too late for lowering to consult).
    module
        .registry
        .hierarchy_methods
        .clone_from(&hierarchy_methods);
    module
        .registry
        .nested_object_aliases
        .clone_from(&nested_object_aliases);
    // Make every `inline fun` body (top-level or nested) available to
    // the lowerer by simple name. The lowerer only expands a suspend
    // builder (continuation capture) or an inline call whose lambda
    // arg does a non-local return; the rest keep the normal path.
    {
        fn collect_inline(
            d: &Decl,
            out: &mut std::collections::HashMap<String, Vec<std::rc::Rc<klio_ast::Function>>>,
        ) {
            match d {
                Decl::Function(f) if f.is_inline && f.body.is_some() => {
                    // Keep every overload (declaration order) so a call site
                    // can pick the function-param form for a trailing lambda.
                    out.entry(f.name.name.clone())
                        .or_default()
                        .push(std::rc::Rc::new(f.clone()));
                }
                Decl::Class(c) => {
                    for m in &c.members {
                        collect_inline(m, out);
                    }
                }
                Decl::Object(o) => {
                    for m in &o.members {
                        collect_inline(m, out);
                    }
                }
                _ => {}
            }
        }
        let mut inline_fns: std::collections::HashMap<
            String,
            Vec<std::rc::Rc<klio_ast::Function>>,
        > = std::collections::HashMap::new();
        for d in &all_decls {
            collect_inline(d, &mut inline_fns);
        }
        klio_ir::lower::set_inline_fn_asts(inline_fns);

        // Default-import host bindings shadow any same-simple-name
        // inline fn declared in a non-default package. A bare call
        // like `synchronized(lock) { … }` resolves to
        // `kotlin.synchronized` via the default `kotlin.*` import,
        // not to `kotlinx.coroutines.internal.synchronized` (whose
        // package isn't reachable through any user import). Without
        // this, klio's simple-name-keyed inline-AST table would
        // hijack the call and splice in kxco's body, bypassing
        // the host monitor binding.
        let mut shadowed: std::collections::HashSet<String> = std::collections::HashSet::new();
        for fqn in klio_stdlib::implementations::all_fqns() {
            // Split on the LAST `.`: everything before is the
            // declaring scope (package or type), everything after is
            // the simple name we'd see at a call site. A binding's
            // simple name only shadows an inline fn when the
            // declaring scope is one of the spec's implicitly
            // imported packages (i.e. resolvable from a bare call).
            // Member bindings like `String.toInt` don't shadow,
            // because reaching them requires a receiver.
            if let Some(dot) = fqn.rfind('.') {
                let scope = &fqn[..dot];
                let simple = &fqn[dot + 1..];
                if klio_stdlib::is_implicitly_imported_package(scope) {
                    shadowed.insert(simple.to_string());
                }
            }
        }
        klio_ir::lower::set_shadowed_inline_names(shadowed);
    }
    // Top-level (file-scope) property names — `val`/`var` outside any
    // class, excluding extension properties (which carry a receiver and
    // dispatch by type). A bare reference to one inside a method/lambda
    // body lowers as a global read rather than an implicit `this.<name>`
    // field access (see the bare-name shortcut in `lower::expr`).
    {
        let top_props: std::collections::HashSet<String> = all_decls
            .iter()
            .filter_map(|d| match d {
                Decl::Property(p) if p.receiver_type.is_none() => Some(p.name.name.clone()),
                _ => None,
            })
            .collect();
        klio_ir::lower::set_top_level_prop_names(top_props);
    }
    // Non-wildcard imports, keyed first by the declaring file then by
    // the name they bind (alias or last segment), so the lowerer can
    // rewrite a bare reference to an imported (possibly named-)
    // companion member into the qualified `Class.…` access it can
    // lower. Set here, before the body passes, since the registry is
    // otherwise only finalised at the end of this function.
    //
    // `combined.imports` merges every source file's imports (each
    // retaining its original `FileId`); keying by file keeps a Kotlin
    // named import file-local, so a pack file's `import …Foo` neither
    // shadows nor is shadowed by another file's bare `Foo`.
    for imp in &file.imports {
        if imp.wildcard || imp.path.is_empty() {
            continue;
        }
        let segs: Vec<String> = imp.path.iter().map(|i| i.name.clone()).collect();
        let leaf = imp
            .alias
            .as_ref()
            .map_or_else(|| segs.last().unwrap().clone(), |a| a.name.clone());
        // File-scoped: each merged source file keeps its own import set
        // (keyed by the import declaration's `FileId`) so one file's
        // named import never shadows a bare reference in another.
        module
            .registry
            .import_aliases
            .entry(imp.span.file)
            .or_default()
            .insert(leaf, segs);
    }
    // Pre-register every class name so `class_id` resolves
    // regardless of declaration order: a method body may reference
    // a class declared later in the module. `add_class` reuses
    // these reserved slots.
    for d in decls {
        if let Decl::Class(c) = d {
            module.reserve_class(&c.name.name);
        }
    }
    for d in decls {
        if let Decl::Class(c) = d {
            let empty = std::collections::HashSet::new();
            let extras = nested_outer_members.get(&c.name.name).unwrap_or(&empty);
            let cfqn = fqn_overrides.get(&c.span).cloned().unwrap_or_else(|| {
                if package_prefix.is_empty() {
                    c.name.name.clone()
                } else {
                    format!("{}.{}", package_prefix, c.name.name)
                }
            });
            let _ = klio_ir::lower::lower_class_with_extras_fqn(
                &mut module,
                c,
                &file_classes,
                extras,
                &cfqn,
            );
        }
    }

    // Reserve a stub Func slot per top-level function so call-site
    // lowering can resolve forward references. Tracks stub ids in
    // declaration order so overload-name collisions (`fun atomic(Int)`
    // + `fun atomic(Long)` + …) each get their own slot. Note that
    // `expect` decls already shadowed by an `actual` were dropped
    // from `decls` above, so the cursor + lower-body pass sees only
    // active definitions.
    let mut stub_ids: Vec<klio_ir::FuncId> = Vec::new();
    for d in decls {
        if let Decl::Function(f) = d {
            // FuncId is u32-indexed; the module's func count fits.
            #[allow(clippy::cast_possible_truncation)]
            let id = klio_ir::FuncId(module.funcs.len() as u32);
            let fqn = func_fqn_overrides.get(&f.span).cloned().unwrap_or_else(|| {
                if package_prefix.is_empty() {
                    f.name.name.clone()
                } else {
                    format!("{}.{}", package_prefix, f.name.name)
                }
            });
            // Forward-reference stub. Seed an implicit `this` first
            // param for an extension function so a call lowered
            // before the real body (which prepends the receiver) can
            // still detect `needs_this`. The `this` param carries the
            // declared receiver type so bare-call resolution can prefer
            // a same-named extension overload whose receiver matches the
            // enclosing receiver even while this sibling is still a stub
            // (`Source.takeWhile` over `CharSequence.takeWhile` inside
            // `fun Source.forEach`). The real definition replaces this
            // slot when its body is lowered.
            let stub_params: Vec<klio_ir::Param> = if let Some(rt) = &f.receiver_type {
                vec![klio_ir::Param {
                    name: "this".to_string(),
                    ty: klio_ir::TypeRef {
                        name: rt.name.name.clone(),
                        nullable: rt.nullable,
                        args: Vec::new(),
                    },
                    default: None,
                    is_property: false,
                    is_vararg: false,
                    has_default: false,
                }]
            } else {
                Vec::new()
            };
            module.funcs.push(klio_ir::Func {
                id,
                name: f.name.name.clone(),
                fqn,
                params: stub_params,
                return_ty: klio_ir::TypeRef::unit(),
                n_locals: 0,
                blocks: Vec::new(),
                entry: klio_ir::BlockId(0),
                is_suspend: false,
                is_tailrec: f.is_tailrec,
                is_lambda: false,
                is_inline: f.is_inline,
                capture_order: Vec::new(),
                implicit_label: None,
                low_priority: false,
            });
            let nm = f.name.name.clone();
            module.func_index.push((nm.clone(), id));
            module.func_name_index.entry(nm).or_default().push(id);
            if f.is_tailrec {
                module.tailrec_fn_names.push(f.name.name.clone());
            }
            // Record the declared user-param arity so call-site lowering
            // can resolve a forward reference to a later-declared overload
            // by arity while that sibling is still a body-less stub.
            #[allow(clippy::cast_possible_truncation)]
            module.decl_user_params.insert(id.0, f.params.len() as u32);
            #[allow(clippy::cast_possible_truncation)]
            {
                let has_vararg = f.params.last().is_some_and(|p| p.is_vararg);
                let required = f
                    .params
                    .iter()
                    .filter(|p| p.default.is_none() && !p.is_vararg)
                    .count() as u32;
                module
                    .decl_user_arity
                    .insert(id.0, (required, f.params.len() as u32, has_vararg));
            }
            stub_ids.push(id);
        }
    }

    // Lower each function body into its reserved slot.
    let mut main_id: Option<klio_ir::FuncId> = None;
    let mut func_defaults: std::collections::HashMap<
        klio_ir::FuncId,
        Vec<Option<klio_ir::FuncId>>,
    > = std::collections::HashMap::new();
    let mut func_type_params: std::collections::HashMap<klio_ir::FuncId, Vec<String>> =
        std::collections::HashMap::new();
    let mut stub_cursor: usize = 0;
    for d in decls {
        if let Decl::Function(f) = d {
            let func = klio_ir::lower::lower_function_body_into(&mut module, f, &file_classes);
            let id = stub_ids[stub_cursor];
            stub_cursor += 1;
            let mut placed = func;
            placed.id = id;
            // Preserve the FQN that the stub pass installed (it
            // carries the file's package prefix); `lower_function_*`
            // hard-codes a bare-name fqn that would otherwise lose
            // the package on combined builds.
            placed.fqn.clone_from(&module.funcs[id.0 as usize].fqn);
            module.funcs[id.0 as usize] = placed;
            if f.name.name == "main" {
                main_id = Some(id);
            }
            module.top_level.push(id);
            // Record type-param names so the Vm can bind reified
            // type args as synth `Value::Class` globals at call
            // time.
            if !f.type_params.is_empty() {
                let names: Vec<String> = f
                    .type_params
                    .iter()
                    .map(|tp| tp.name.name.clone())
                    .collect();
                func_type_params.insert(id, names);
            }
            // Lower per-param default expressions as 0-arg thunks.
            // The Vm pads missing args at call_func time.
            if f.params.iter().any(|p| p.default.is_some()) {
                // The lowered fn may carry implicit leading params
                // (an extension/method receiver bound as `this`).
                // `func_defaults` is indexed by *lowered* param
                // position (that's how call_func reads it), so pad
                // `offset` empty leading slots and lower each default
                // thunk binding the lowered param prefix — a default
                // like `endIndex = s.length` then resolves `s`
                // against the args call_func has accumulated.
                let lowered_names: Vec<String> = module
                    .funcs
                    .get(id.0 as usize)
                    .map(|lf| lf.params.iter().map(|p| p.name.clone()).collect())
                    .unwrap_or_default();
                let offset = lowered_names.len().saturating_sub(f.params.len());
                let name_refs: Vec<&str> = lowered_names
                    .iter()
                    .map(std::string::String::as_str)
                    .collect();
                let mut slots: Vec<Option<klio_ir::FuncId>> =
                    Vec::with_capacity(lowered_names.len().max(f.params.len()));
                for _ in 0..offset {
                    slots.push(None);
                }
                for (idx, p) in f.params.iter().enumerate() {
                    if let Some(default_expr) = &p.default {
                        let bind_upto = (offset + idx).min(name_refs.len());
                        let widened = klio_ir::lower::widen_numeric_literal(default_expr, &p.ty);
                        let fid = klio_ir::lower::lower_expr_as_param_thunk(
                            &mut module,
                            &name_refs[..bind_upto],
                            widened.as_ref().unwrap_or(default_expr),
                            &format!("__default_{}_{}", f.name.name, p.name.name),
                        );
                        slots.push(Some(fid));
                    } else {
                        slots.push(None);
                    }
                }
                func_defaults.insert(id, slots);
            }
        }
    }

    // Lower body-property initialisers as 0-arg thunks so the Vm
    // can run them at instance allocation time. Inits that
    // reference `this` or captured outer state land as the IR
    // class shape grows; for now they're lowered the same way and
    // either succeed (literal-only inits) or surface a clear
    // failure at run time.
    let mut body_prop_inits: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
    let mut instance_prop_getters: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
    let mut instance_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
    let mut delegated_body_props: std::collections::HashSet<(String, String)> =
        std::collections::HashSet::new();
    let mut primary_ctor_default_thunks: std::collections::HashMap<
        String,
        Vec<Option<klio_ir::FuncId>>,
    > = std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            // Collect own-member names so accessor bodies' bare
            // identifiers resolve via this.<name>.
            let mut own_members: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for p in &c.primary_params {
                if p.property.is_some() {
                    own_members.insert(p.name.name.clone());
                }
            }
            for m in &c.members {
                if let Decl::Property(p) = m {
                    own_members.insert(p.name.name.clone());
                }
                if let Decl::Function(f) = m {
                    own_members.insert(f.name.name.clone());
                }
            }
            // Body-property initialisers may reference primary ctor
            // params + `this` (for accessing already-bound properties
            // declared earlier in the class). Lower as accessor exprs
            // with `[this, ctor_param_names...]` as positional params;
            // the Vm dispatches with `[inst, ctor_args...]`.
            let ctor_param_names: Vec<String> = c
                .primary_params
                .iter()
                .map(|p| p.name.name.clone())
                .collect();
            let mut prop_init_params: Vec<&str> = Vec::with_capacity(1 + ctor_param_names.len());
            prop_init_params.push("this");
            for n in &ctor_param_names {
                prop_init_params.push(n.as_str());
            }
            // Lower each primary-ctor param default over the same
            // `[this, ctor_param_names...]` shape so a default may read
            // an earlier param; `new_instance` evaluates the thunk for
            // an omitted param. Only recorded when at least one param
            // has a default (so the lookup stays cheap for the common
            // no-default class).
            if c.primary_params.iter().any(|p| p.default.is_some()) {
                let slots: Vec<Option<klio_ir::FuncId>> = c
                    .primary_params
                    .iter()
                    .map(|p| {
                        p.default.as_ref().map(|e| {
                            klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &c.name.name,
                                &own_members,
                                &prop_init_params,
                                e,
                                &format!("__ctor_default_{}_{}", c.name.name, p.name.name),
                            )
                        })
                    })
                    .collect();
                primary_ctor_default_thunks.insert(c.name.name.clone(), slots);
            }
            for m in &c.members {
                if let Decl::Property(p) = m {
                    if let Some(init) = &p.init {
                        let fid = klio_ir::lower::lower_accessor_expr_with_expected(
                            &mut module,
                            &c.name.name,
                            &own_members,
                            &prop_init_params,
                            init,
                            &format!("__init_prop_{}_{}", c.name.name, p.name.name),
                            p.ty.clone(),
                        );
                        body_prop_inits.insert((c.name.name.clone(), p.name.name.clone()), fid);
                    } else if let Some(delegate) = &p.delegate {
                        delegated_body_props.insert((c.name.name.clone(), p.name.name.clone()));
                        // evaluate the delegate at construction
                        // time and store under the property name;
                        // get_field on the instance unwraps Lazy /
                        // NotNull / Observable via the same Value::Delegate
                        // logic used for top-level delegates.
                        let fid = klio_ir::lower::lower_accessor_expr(
                            &mut module,
                            &c.name.name,
                            &own_members,
                            &prop_init_params,
                            delegate,
                            &format!("__delegate_prop_{}_{}", c.name.name, p.name.name),
                        );
                        body_prop_inits.insert((c.name.name.clone(), p.name.name.clone()), fid);
                    }
                    if let Some(getter) = &p.getter {
                        let fid = match &getter.body {
                            klio_ast::FunctionBody::Expr(body) => {
                                let rewritten = substitute_field_with_this(&p.name.name, body);
                                Some(klio_ir::lower::lower_accessor_expr(
                                    &mut module,
                                    &c.name.name,
                                    &own_members,
                                    &["this"],
                                    &rewritten,
                                    &format!("__get_{}_{}", c.name.name, p.name.name),
                                ))
                            }
                            klio_ast::FunctionBody::Block(blk) => {
                                let rewritten = rewrite_block_field(blk, &p.name.name);
                                Some(klio_ir::lower::lower_accessor_block(
                                    &mut module,
                                    &c.name.name,
                                    &own_members,
                                    &["this"],
                                    &rewritten,
                                    &format!("__get_{}_{}", c.name.name, p.name.name),
                                ))
                            }
                        };
                        if let Some(fid) = fid {
                            instance_prop_getters
                                .insert((c.name.name.clone(), p.name.name.clone()), fid);
                            // Also key by the class's package-qualified
                            // FQN. Two packages may declare the same
                            // simple class name where only one has a
                            // getter for this property. Two classes
                            // may share a simple name across
                            // packages; the FQN key lets the lookup
                            // bind the getter to the class that
                            // actually declares it.
                            let cfqn = fqn_overrides.get(&c.span).cloned().unwrap_or_else(|| {
                                if package_prefix.is_empty() {
                                    c.name.name.clone()
                                } else {
                                    format!("{}.{}", package_prefix, c.name.name)
                                }
                            });
                            if cfqn != c.name.name {
                                instance_prop_getters.insert((cfqn, p.name.name.clone()), fid);
                            }
                        }
                    }
                    if let Some(setter) = &p.setter {
                        let setter_param_name = setter
                            .params
                            .first()
                            .map_or_else(|| "value".to_string(), |n| n.name.clone());
                        let fid = match &setter.body {
                            klio_ast::FunctionBody::Expr(body) => {
                                let rewritten = substitute_field_with_this(&p.name.name, body);
                                Some(klio_ir::lower::lower_accessor_expr(
                                    &mut module,
                                    &c.name.name,
                                    &own_members,
                                    &["this", setter_param_name.as_str()],
                                    &rewritten,
                                    &format!("__set_{}_{}", c.name.name, p.name.name),
                                ))
                            }
                            klio_ast::FunctionBody::Block(blk) => {
                                let rewritten = rewrite_block_field(blk, &p.name.name);
                                Some(klio_ir::lower::lower_accessor_block(
                                    &mut module,
                                    &c.name.name,
                                    &own_members,
                                    &["this", setter_param_name.as_str()],
                                    &rewritten,
                                    &format!("__set_{}_{}", c.name.name, p.name.name),
                                ))
                            }
                        };
                        if let Some(fid) = fid {
                            instance_prop_setters
                                .insert((c.name.name.clone(), p.name.name.clone()), fid);
                        }
                    }
                }
            }
        }
    }

    // Synthesise a minimal runtime ClassDef for every class in the
    // file. Future workstreams move these fields onto the IR Class
    // (methods, init blocks, supertypes, secondary ctors, ...); for
    // now the Vm uses these for the instance-allocation shape.
    let globals_for_capture = klio_runtime::ObjRef::new(klio_runtime::Env::new());
    let mut classes: std::collections::HashMap<String, Arc<ClassDef>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            let primary_params: Vec<ClassParamDef> = c
                .primary_params
                .iter()
                .map(|p| ClassParamDef {
                    property: p.property,
                    name: p.name.name.clone(),
                    default: p.default.as_ref().map(|e| std::sync::Arc::new(e.clone())),
                    declared_type: Some(p.ty.name.name.clone()),
                    declared_shape: Some(klio_runtime::TypeShape::from_type_ref(&p.ty)),
                })
                .collect();
            let body_properties: Vec<PropertyDef> = c
                .members
                .iter()
                .filter_map(|m| match m {
                    Decl::Property(p) => Some(PropertyDef {
                        name: p.name.name.clone(),
                        mutable: p.mutable,
                        init: p.init.as_ref().map(|e| std::sync::Arc::new(e.clone())),
                        getter: p.getter.as_ref().map(|a| std::sync::Arc::new(a.clone())),
                        setter: p.setter.as_ref().map(|a| std::sync::Arc::new(a.clone())),
                        delegate: p.delegate.as_ref().map(|e| std::sync::Arc::new(e.clone())),
                        is_abstract: p.is_abstract,
                        is_lateinit: p.is_lateinit,
                        primitive_zero: primitive_zero_for(p),
                    }),
                    _ => None,
                })
                .collect();
            let is_object = object_names.iter().any(|n| n == &c.name.name);
            let def = std::sync::Arc::new(ClassDef {
                name: c.name.name.clone(),
                fqn: fqn_overrides.get(&c.span).cloned().unwrap_or_else(|| {
                    if package_prefix.is_empty() {
                        c.name.name.clone()
                    } else {
                        format!("{}.{}", package_prefix, c.name.name)
                    }
                }),
                annotation_names: Vec::new(),
                primary_params,
                methods: Vec::new(),
                body_properties,
                init_blocks: Vec::new(),
                // Translate each init block's source position from
                // "members index" to "body_properties index" — the
                // count of `Decl::Property` entries in `members[0..P]`.
                // The runtime construction loop uses this to interleave
                // init blocks with property initializers in declaration
                // order, matching Kotlin.
                init_block_property_positions: c
                    .init_block_positions
                    .iter()
                    .map(|&p| {
                        c.members[..p.min(c.members.len())]
                            .iter()
                            .filter(|d| matches!(d, Decl::Property(_)))
                            .count()
                    })
                    .collect(),
                is_data: c.is_data,
                is_value: c.is_value,
                is_object,
                is_enum: c.is_enum,
                is_sealed: c.is_sealed,
                is_open: c.is_open,
                is_abstract: c.is_abstract,
                is_inner: c.is_inner,
                is_anonymous: false,
                secondary_ctors: c
                    .secondary_ctors
                    .iter()
                    .map(|sc| std::sync::Arc::new(sc.clone()))
                    .collect(),
                supertype_names: c.supertypes.iter().map(|t| t.name.name.clone()).collect(),
                parent: klio_runtime::ObjRef::new(None),
                interfaces: klio_runtime::ObjRef::new(Vec::new()),
                is_interface: c.is_interface,
                is_fun_interface: c.is_fun_interface,
                parent_ctor_args: Vec::new(),
                enum_entries: klio_runtime::ObjRef::new(Vec::new()),
                companion: klio_runtime::ObjRef::new(None),
                enclosing_class: klio_runtime::ObjRef::new(None),
                nested_classes: klio_runtime::ObjRef::new(Vec::new()),
                captured_env: globals_for_capture.clone(),
                supertype_delegates: klio_runtime::ObjRef::new(Vec::new()),
                delegate_forwarders: klio_runtime::ObjRef::new(Vec::new()),
                object_singleton: klio_runtime::ObjRef::new(None),
            });
            // Additionally key by the fully-qualified name. The
            // primary table is simple-name keyed, so two packs
            // declaring the same simple name would otherwise collapse
            // to a single entry, blocking a constructor from reaching
            // the sibling. The FQN entries are additive (distinct
            // keys) so existing simple-name lookups are unaffected
            // while both definitions stay reachable.
            if !def.fqn.is_empty() && def.fqn != c.name.name {
                classes.insert(def.fqn.clone(), std::sync::Arc::clone(&def));
            }
            classes.insert(c.name.name.clone(), def);
        }
    }
    // Populate enum entries on each `enum class` synthesised
    // ClassDef. Each entry becomes a `Value::Instance` of the same
    // class with `name` + `ordinal` fields populated. The entry's
    // ctor args + body members aren't run — that lands when the IR
    // class shape supports per-entry overrides.
    let mut next_id = 1u64;
    let mut enum_entry_arg_inits: Vec<(String, String, Vec<klio_ir::FuncId>)> = Vec::new();
    let mut enum_entry_methods: std::collections::HashMap<
        (String, String),
        (std::sync::Arc<klio_ir::Module>, klio_ir::FuncId),
    > = std::collections::HashMap::new();
    let mut enum_entry_synth_class: std::collections::HashMap<(String, String), String> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            if !c.is_enum {
                continue;
            }
            if let Some(class_def) = classes.get(&c.name.name).cloned() {
                let mut entries: Vec<(String, klio_runtime::Value)> = Vec::new();
                for (ordinal, entry) in c.enum_entries.iter().enumerate() {
                    let id = next_id;
                    next_id += 1;
                    // ordinal is an enumerate() index reported as Kotlin's i64 ordinal.
                    #[allow(clippy::cast_possible_wrap)]
                    let fields: Vec<(String, klio_runtime::Value)> = vec![
                        (
                            "name".to_string(),
                            klio_runtime::Value::String(std::sync::Arc::new(
                                entry.name.name.clone(),
                            )),
                        ),
                        (
                            "ordinal".to_string(),
                            klio_runtime::Value::new_int(ordinal as i64),
                        ),
                    ];
                    let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                        class: std::sync::Arc::clone(&class_def),
                        fields,
                        outer: None,
                        identity: id,
                        native_state: None,
                    });
                    // Per-entry method overrides — `RED { override fun
                    // f() = … }`. Lower each entry-specific method
                    // body and stash so the Vm can dispatch it
                    // when the entry instance receives a call.
                    if !entry.body_members.is_empty() {
                        let synth_class_name = format!("{}${}", c.name.name, entry.name.name);
                        enum_entry_synth_class.insert(
                            (c.name.name.clone(), entry.name.name.clone()),
                            synth_class_name.clone(),
                        );
                        for em in &entry.body_members {
                            if let Decl::Function(f) = em {
                                if f.body.is_none() {
                                    continue;
                                }
                                let mut sub_module = klio_ir::Module::default();
                                let own: std::collections::HashSet<String> =
                                    std::collections::HashSet::new();
                                let func = klio_ir::lower::lower_method(
                                    &mut sub_module,
                                    f,
                                    &synth_class_name,
                                    &own,
                                );
                                let fid = func.id;
                                let module_rc = std::sync::Arc::new(sub_module);
                                enum_entry_methods.insert(
                                    (synth_class_name.clone(), f.name.name.clone()),
                                    (module_rc, fid),
                                );
                            }
                        }
                        // Tag the entry instance with its synth
                        // class so call_member on the instance can
                        // look up the override.
                        inst.borrow_mut().fields.push((
                            "__enum_entry_class__".to_string(),
                            klio_runtime::Value::String(std::sync::Arc::new(
                                synth_class_name.clone(),
                            )),
                        ));
                    }
                    entries.push((entry.name.name.clone(), klio_runtime::Value::Instance(inst)));
                    // Lower each ctor arg as a 0-arg thunk; the Vm
                    // runs them at startup and patches the result
                    // into the entry instance's primary-param field.
                    if !entry.args.is_empty() {
                        let mut fids: Vec<klio_ir::FuncId> = Vec::with_capacity(entry.args.len());
                        for (idx, arg) in entry.args.iter().enumerate() {
                            let fid = klio_ir::lower::lower_expr_as_thunk(
                                &mut module,
                                arg,
                                &format!("__enum_arg_{}_{}_{idx}", c.name.name, entry.name.name),
                            );
                            fids.push(fid);
                        }
                        enum_entry_arg_inits.push((
                            c.name.name.clone(),
                            entry.name.name.clone(),
                            fids,
                        ));
                    }
                }
                *class_def.enum_entries.borrow_mut() = entries;
            }
        }
    }
    // Resolve runtime parent + interface references so dispatch
    // walks (call_member supertype chain, instance_of class
    // hierarchy, qualified_this outer walks) follow the source-
    // declared chain. Single inheritance picks the first
    // non-interface supertype; the rest are added as interfaces.
    let class_table_snapshot: std::collections::HashMap<String, Arc<ClassDef>> = classes.clone();
    for def in classes.values() {
        for sup_name in &def.supertype_names {
            if let Some(sup_def) = class_table_snapshot.get(sup_name) {
                // A class is never its own supertype. A qualified nested
                // supertype (`Outer.Inner`) collapses to its last segment in
                // `supertype_names`, so a top-level class sharing that simple
                // name (`class Inner : Outer.Inner()`) resolves its own name
                // here — linking it as parent forms a self-cycle that every
                // unguarded parent-chain walk loops on.
                if Arc::ptr_eq(def, sup_def) {
                    continue;
                }
                if sup_def.is_interface {
                    def.interfaces.borrow_mut().push(Arc::clone(sup_def));
                } else if def.parent.borrow().is_none() {
                    *def.parent.borrow_mut() = Some(Arc::clone(sup_def));
                }
            }
        }
    }

    // Lower parent-ctor argument expressions as N-arg thunks
    // parameterised on the class's own primary-ctor params. The Vm
    // invokes these during new_instance to compute the parent's
    // primary-ctor args.
    let mut parent_ctor_args: std::collections::HashMap<String, Vec<klio_ir::FuncId>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d
            && let Some(parent_args) = c.supertype_args.iter().flatten().next()
        {
            let param_names: Vec<String> = c
                .primary_params
                .iter()
                .map(|p| p.name.name.clone())
                .collect();
            let param_refs: Vec<&str> = param_names
                .iter()
                .map(std::string::String::as_str)
                .collect();
            // Companion object (by its own name) and its
            // members are in scope for a superclass-ctor
            // delegation argument (the companion is
            // initialized before the subclass ctor runs).
            let mut own: std::collections::HashSet<String> = std::collections::HashSet::new();
            for m in &c.members {
                if let Decl::Class(inner) = m
                    && inner.is_companion
                {
                    own.insert(inner.name.name.clone());
                    for cm in &inner.members {
                        match cm {
                            Decl::Function(f) => {
                                own.insert(f.name.name.clone());
                            }
                            Decl::Property(p) => {
                                own.insert(p.name.name.clone());
                            }
                            _ => {}
                        }
                    }
                    for p in &inner.primary_params {
                        if p.property.is_some() {
                            own.insert(p.name.name.clone());
                        }
                    }
                }
            }
            let mut fids: Vec<klio_ir::FuncId> = Vec::with_capacity(parent_args.len());
            for (idx, e) in parent_args.iter().enumerate() {
                let fid = klio_ir::lower::lower_expr_as_param_thunk_scoped(
                    &mut module,
                    &param_refs,
                    e,
                    &format!("__parent_ctor_arg_{}_{idx}", c.name.name),
                    Some(c.name.name.as_str()),
                    Some(&own),
                );
                fids.push(fid);
            }
            parent_ctor_args.insert(c.name.name.clone(), fids);
        }
    }

    // Lower each class's init blocks as 1-arg thunks taking `this`.
    let mut init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            if c.init_blocks.is_empty() {
                continue;
            }
            let mut own_members: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for p in &c.primary_params {
                if p.property.is_some() {
                    own_members.insert(p.name.name.clone());
                }
            }
            for m in &c.members {
                if let Decl::Property(p) = m {
                    own_members.insert(p.name.name.clone());
                }
                if let Decl::Function(f) = m {
                    own_members.insert(f.name.name.clone());
                }
            }
            // Inherited members are reachable without an explicit
            // receiver from an init block too.
            {
                let mut seen_sup: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for st in &c.supertypes {
                    collect_hierarchy_member_names(
                        &st.name.name,
                        &file_classes,
                        &mut own_members,
                        &mut seen_sup,
                    );
                }
            }
            // Primary ctor params are visible inside init blocks
            // (whether or not they're `val`/`var` properties). Pass
            // their names as additional positional params; the Vm
            // dispatches each init block with `[this, ctor_args...]`.
            let ctor_param_names: Vec<String> = c
                .primary_params
                .iter()
                .map(|p| p.name.name.clone())
                .collect();
            let mut local_params: Vec<&str> = Vec::with_capacity(1 + ctor_param_names.len());
            local_params.push("this");
            for n in &ctor_param_names {
                local_params.push(n.as_str());
            }
            let mut fids: Vec<klio_ir::FuncId> = Vec::new();
            for (idx, blk) in c.init_blocks.iter().enumerate() {
                let fid = klio_ir::lower::lower_accessor_block(
                    &mut module,
                    &c.name.name,
                    &own_members,
                    &local_params,
                    blk,
                    &format!("__init_block_{}_{idx}", c.name.name),
                );
                fids.push(fid);
            }
            init_blocks.insert(c.name.name.clone(), fids);
        }
    }

    // Per-class delegation expressions: `class W(g: G) : G by g`.
    // Each supertype with `Some(delegate_expr)` lowers as an
    // N-arg thunk parameterised on the class's primary-ctor
    // params; the Vm stores the result at construction time.
    let mut class_delegates: std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            if c.supertype_delegates.is_empty() {
                continue;
            }
            let param_names: Vec<String> = c
                .primary_params
                .iter()
                .map(|p| p.name.name.clone())
                .collect();
            let param_refs: Vec<&str> = param_names
                .iter()
                .map(std::string::String::as_str)
                .collect();
            let mut entries: Vec<(String, klio_ir::FuncId)> = Vec::new();
            for (sup_idx, delegate_opt) in c.supertype_delegates.iter().enumerate() {
                if let Some(delegate_expr) = delegate_opt {
                    let sup_name = c
                        .supertypes
                        .get(sup_idx)
                        .map(|t| t.name.name.clone())
                        .unwrap_or_default();
                    let fid = klio_ir::lower::lower_expr_as_param_thunk(
                        &mut module,
                        &param_refs,
                        delegate_expr,
                        &format!("__class_delegate_{}_{sup_idx}", c.name.name),
                    );
                    entries.push((sup_name, fid));
                }
            }
            if !entries.is_empty() {
                class_delegates.insert(c.name.name.clone(), entries);
            }
        }
    }

    // Per-class secondary-ctor lowering. Each entry captures the
    // delegation arg thunks (parameterised on the secondary's
    // params) plus an optional body block thunk taking `[this,
    // ctor params...]`.
    let mut secondary_ctors: std::collections::HashMap<String, Vec<SecondaryCtorEntry>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            if c.secondary_ctors.is_empty() {
                continue;
            }
            let mut own_members: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for p in &c.primary_params {
                if p.property.is_some() {
                    own_members.insert(p.name.name.clone());
                }
            }
            for m in &c.members {
                if let Decl::Property(p) = m {
                    own_members.insert(p.name.name.clone());
                }
                if let Decl::Function(f) = m {
                    own_members.insert(f.name.name.clone());
                }
                // A bare reference to a companion member in a secondary ctor's
                // delegation args / body resolves to the companion (no `this`
                // exists yet) — e.g. `constructor(p) : this(p, SharedList)`.
                if let Decl::Class(inner) = m
                    && inner.is_companion
                {
                    own_members.insert(inner.name.name.clone());
                    for cm in &inner.members {
                        match cm {
                            Decl::Function(f) => {
                                own_members.insert(f.name.name.clone());
                            }
                            Decl::Property(p) => {
                                own_members.insert(p.name.name.clone());
                            }
                            _ => {}
                        }
                    }
                    for p in &inner.primary_params {
                        if p.property.is_some() {
                            own_members.insert(p.name.name.clone());
                        }
                    }
                }
            }
            let mut entries: Vec<SecondaryCtorEntry> = Vec::new();
            for (sc_idx, sc) in c.secondary_ctors.iter().enumerate() {
                let param_names: Vec<String> =
                    sc.params.iter().map(|p| p.name.name.clone()).collect();
                let param_refs: Vec<&str> = param_names
                    .iter()
                    .map(std::string::String::as_str)
                    .collect();
                let (delegation_args, is_super, is_this) = match &sc.delegation {
                    klio_ast::CtorDelegation::This(args) => (args.clone(), false, true),
                    klio_ast::CtorDelegation::Super(args) => (args.clone(), true, false),
                    klio_ast::CtorDelegation::None => (Vec::new(), false, false),
                };
                let mut arg_fids: Vec<klio_ir::FuncId> = Vec::with_capacity(delegation_args.len());
                for (arg_idx, e) in delegation_args.iter().enumerate() {
                    // Scoped so a bare own/companion member in the delegation
                    // arg (`: this(p, SharedList)`) resolves against the class.
                    let fid = klio_ir::lower::lower_expr_as_param_thunk_scoped(
                        &mut module,
                        &param_refs,
                        e,
                        &format!("__sec_ctor_{}_{sc_idx}_arg{arg_idx}", c.name.name),
                        Some(c.name.name.as_str()),
                        Some(&own_members),
                    );
                    arg_fids.push(fid);
                }
                let default_arg_thunks: Vec<Option<klio_ir::FuncId>> = sc
                    .params
                    .iter()
                    .enumerate()
                    .map(|(p_idx, p)| {
                        p.default.as_ref().map(|e| {
                            klio_ir::lower::lower_expr_as_param_thunk_scoped(
                                &mut module,
                                &param_refs,
                                e,
                                &format!("__sec_ctor_{}_{sc_idx}_def{p_idx}", c.name.name),
                                Some(c.name.name.as_str()),
                                Some(&own_members),
                            )
                        })
                    })
                    .collect();
                let body_fid = sc.body.as_ref().map(|blk| {
                    let mut locals: Vec<&str> = Vec::with_capacity(1 + param_refs.len());
                    locals.push("this");
                    locals.extend_from_slice(&param_refs);
                    klio_ir::lower::lower_accessor_block(
                        &mut module,
                        &c.name.name,
                        &own_members,
                        &locals,
                        blk,
                        &format!("__sec_ctor_body_{}_{sc_idx}", c.name.name),
                    )
                });
                entries.push(SecondaryCtorEntry {
                    param_count: sc.params.len(),
                    param_names: param_names.clone(),
                    is_super,
                    is_this,
                    delegation_arg_thunks: arg_fids,
                    default_arg_thunks,
                    body: body_fid,
                });
            }
            secondary_ctors.insert(c.name.name.clone(), entries);
        }
    }

    // Top-level property initialisers — `val name = expr` /
    // `var name = expr` declared at file scope. Each lowers to a
    // 0-arg thunk. Vm::run drives them at startup.
    let mut top_level_props: Vec<(String, klio_ir::FuncId)> = Vec::new();
    let mut top_level_delegated_props: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    // `const val` is a compile-time constant: its initializer is a
    // constant expression with no dependency on runtime state, and it
    // must be observable before any other top-level initializer runs
    // (an earlier non-const initializer may construct a class whose
    // body references a `const` declared later in source order). Drive
    // every const initializer first, preserving relative declaration
    // order so a const that references an earlier const still sees it.
    let mut const_props: Vec<(String, klio_ir::FuncId)> = Vec::new();
    for d in decls {
        if let Decl::Property(p) = d {
            if p.receiver_type.is_some() || !p.is_const {
                continue;
            }
            if let Some(init) = &p.init {
                let fid = klio_ir::lower::lower_expr_as_thunk(
                    &mut module,
                    init,
                    &format!("__top_prop_init_{}", p.name.name),
                );
                const_props.push((p.name.name.clone(), fid));
            }
        }
    }
    top_level_props.extend(const_props);
    for d in decls {
        if let Decl::Property(p) = d {
            if p.receiver_type.is_some() {
                continue;
            }
            if p.is_const {
                continue;
            }
            if let Some(init) = &p.init {
                let fid = klio_ir::lower::lower_expr_as_thunk(
                    &mut module,
                    init,
                    &format!("__top_prop_init_{}", p.name.name),
                );
                top_level_props.push((p.name.name.clone(), fid));
            } else if let Some(delegate) = &p.delegate {
                top_level_delegated_props.insert(p.name.name.clone());
                // `val X by delegate-expr` — evaluate the delegate
                // value at startup and store under the property
                // name. Vm `lookup_global` unwraps `Value::Delegate(Lazy)`
                // on first read (caches the producer's result).
                let fid = klio_ir::lower::lower_expr_as_thunk(
                    &mut module,
                    delegate,
                    &format!("__top_prop_delegate_{}", p.name.name),
                );
                top_level_props.push((p.name.name.clone(), fid));
            }
        }
    }

    // Top-level extension properties: `val T.name: U get() = …` /
    // `var T.name: U get() = … set(value) { … }`. Each lowers to a
    // 1-arg thunk taking the receiver as `this`.
    let mut extension_props: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
    let mut extension_prop_setters: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
    // Gather every extension property (`val T.name …`): top-level
    // declarations *and* those declared inside a companion / nested
    // object. Companion-scoped extension properties imported via
    // `import Outer.Companion.name` are used exactly like top-level
    // ones (`5.seconds`) — upstream `kotlin.time.Duration.Companion`
    // declares all the `Int/Long/Double.seconds/minutes/…` builders
    // this way — so they lower to the same receiver-keyed thunk.
    let mut ext_prop_decls: Vec<&klio_ast::Property> = Vec::new();
    for d in decls {
        match d {
            Decl::Property(p) if p.receiver_type.is_some() => ext_prop_decls.push(p),
            Decl::Class(c) => {
                for m in &c.members {
                    if let Decl::Property(p) = m
                        && p.receiver_type.is_some()
                    {
                        ext_prop_decls.push(p);
                    }
                }
            }
            Decl::Object(o) => {
                for m in &o.members {
                    if let Decl::Property(p) = m
                        && p.receiver_type.is_some()
                    {
                        ext_prop_decls.push(p);
                    }
                }
            }
            _ => {}
        }
    }
    for p in ext_prop_decls {
        {
            if let Some(recv) = &p.receiver_type {
                if let Some(getter) = &p.getter {
                    let empty_members = std::collections::HashSet::new();
                    let fid = match &getter.body {
                        klio_ast::FunctionBody::Expr(body) => {
                            Some(klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this"],
                                body,
                                &format!("__ext_get_{}_{}", recv.name.name, p.name.name),
                            ))
                        }
                        klio_ast::FunctionBody::Block(blk) => {
                            Some(klio_ir::lower::lower_accessor_block(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this"],
                                blk,
                                &format!("__ext_get_{}_{}", recv.name.name, p.name.name),
                            ))
                        }
                    };
                    if let Some(fid) = fid {
                        extension_props.insert((recv.name.name.clone(), p.name.name.clone()), fid);
                    }
                }
                if let Some(setter) = &p.setter {
                    let setter_param_name = setter
                        .params
                        .first()
                        .map_or_else(|| "value".to_string(), |n| n.name.clone());
                    // Receiver-class members are visible bare-name
                    // inside the extension setter (`set(v) { x = v }`
                    // writes to `this.x`).
                    let mut recv_members: std::collections::HashSet<String> =
                        std::collections::HashSet::new();
                    if let Some(rdef) = classes.get(&recv.name.name) {
                        for p in &rdef.primary_params {
                            recv_members.insert(p.name.clone());
                        }
                        for p in &rdef.body_properties {
                            recv_members.insert(p.name.clone());
                        }
                    }
                    let empty_members = recv_members;
                    let fid = match &setter.body {
                        klio_ast::FunctionBody::Expr(body) => {
                            Some(klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this", setter_param_name.as_str()],
                                body,
                                &format!("__ext_set_{}_{}", recv.name.name, p.name.name),
                            ))
                        }
                        klio_ast::FunctionBody::Block(blk) => {
                            Some(klio_ir::lower::lower_accessor_block(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this", setter_param_name.as_str()],
                                blk,
                                &format!("__ext_set_{}_{}", recv.name.name, p.name.name),
                            ))
                        }
                    };
                    if let Some(fid) = fid {
                        extension_prop_setters
                            .insert((recv.name.name.clone(), p.name.name.clone()), fid);
                    }
                }
            }
        }
    }

    // Materialise the module-scoped runtime registry the Vm reads
    // at dispatch time. Build populates the same data as the loose
    // BuiltModule fields; the long-term plan is to drop those once
    // every dispatch site reads through `module.registry` directly.
    // Local-function default thunks were recorded into the registry
    // during body lowering. Fold them into `func_defaults` (keyed by
    // the local fn's body FuncId) so the closure-call path pads
    // missing trailing args exactly like top-level `call_func` does,
    // and keep them on the registry so a serialized pack carries them.
    let local_fn_defaults = std::mem::take(&mut module.registry.local_fn_defaults);
    for (fid, slots) in &local_fn_defaults {
        func_defaults.entry(*fid).or_insert_with(|| slots.clone());
    }
    // Inherited default arguments: Kotlin forbids an `override` from
    // repeating a default value, but a call that omits the argument
    // still uses the default declared on the overridden supertype
    // member. The override's own FuncId therefore has no thunk for
    // that parameter; without this the Vm pads the gap with `Unit`
    // and downstream type-checked accesses fail. Propagate each
    // supertype member's default-thunk slots onto the overriding
    // member (matched by name + lowered arity, so the `this`-offset
    // slot layout already lines up), leaving any slot the override
    // itself defines untouched.
    {
        let abstract_defaults = module.registry.abstract_member_defaults.clone();
        let by_id: std::collections::HashMap<u32, usize> = module
            .classes
            .iter()
            .enumerate()
            .map(|(i, c)| (c.id.0, i))
            .collect();
        let mut inherited: Vec<(klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>)> = Vec::new();
        for c in &module.classes {
            // Transitive supertype closure.
            let mut anc: Vec<usize> = Vec::new();
            let mut queue: Vec<klio_ir::ClassId> = c.supertypes.clone();
            let mut seen: std::collections::HashSet<u32> = std::collections::HashSet::new();
            while let Some(sid) = queue.pop() {
                if !seen.insert(sid.0) {
                    continue;
                }
                if let Some(&idx) = by_id.get(&sid.0) {
                    anc.push(idx);
                    queue.extend(module.classes[idx].supertypes.iter().copied());
                }
            }
            for &m in &c.methods {
                let (mname, marity) = match module.funcs.get(m.0 as usize) {
                    Some(f) => (f.name.clone(), f.params.len()),
                    None => continue,
                };
                let mut merged: Option<Vec<Option<klio_ir::FuncId>>> =
                    func_defaults.get(&m).cloned();
                for &ai in &anc {
                    for &am in &module.classes[ai].methods {
                        if am.0 == m.0 {
                            continue;
                        }
                        let base = match module.funcs.get(am.0 as usize) {
                            Some(f) if f.name == mname && f.params.len() == marity => am,
                            _ => continue,
                        };
                        let Some(bslots) = func_defaults.get(&base) else {
                            continue;
                        };
                        let cur = merged.get_or_insert_with(|| vec![None; bslots.len()]);
                        if cur.len() < bslots.len() {
                            cur.resize(bslots.len(), None);
                        }
                        for (i, bs) in bslots.iter().enumerate() {
                            if cur[i].is_none() {
                                cur[i] = *bs;
                            }
                        }
                    }
                }
                // Bodyless (abstract / interface) supertype
                // declarations contribute no FuncId, so consult the
                // separately-stashed `(class, method)` default table.
                for &ai in anc.iter().chain(std::iter::once(&by_id[&c.id.0])) {
                    let cn = &module.classes[ai].name;
                    let cn_simple = cn.rsplit('.').next().unwrap_or(cn).to_string();
                    let bslots = abstract_defaults
                        .get(&(cn.clone(), mname.clone()))
                        .or_else(|| abstract_defaults.get(&(cn_simple, mname.clone())));
                    let Some(bslots) = bslots else { continue };
                    let cur = merged.get_or_insert_with(|| vec![None; bslots.len()]);
                    if cur.len() < bslots.len() {
                        cur.resize(bslots.len(), None);
                    }
                    for (i, bs) in bslots.iter().enumerate() {
                        if cur[i].is_none() {
                            cur[i] = *bs;
                        }
                    }
                }
                if let Some(slots) = merged
                    && func_defaults.get(&m) != Some(&slots)
                {
                    inherited.push((m, slots));
                }
            }
        }
        for (fid, slots) in inherited {
            func_defaults.insert(fid, slots);
        }
    }
    // `typealias Name = Target` → Name ↦ Target's simple head name.
    // The type checker unfolds aliases in type position; this lets a
    // bare-name *value* lookup (`Alias.of(...)`, `Alias(...)`)
    // resolve the aliased class at runtime.
    let mut type_aliases: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::TypeAlias(ta) = d {
            let target = ta
                .target
                .name
                .name
                .rsplit('.')
                .next()
                .unwrap_or(&ta.target.name.name)
                .to_string();
            if !target.is_empty() && target != ta.name.name {
                type_aliases.insert(ta.name.name.clone(), target);
            }
        }
    }
    let import_aliases = std::mem::take(&mut module.registry.import_aliases);
    let abstract_member_defaults = std::mem::take(&mut module.registry.abstract_member_defaults);
    let member_ext_owner_class = std::mem::take(&mut module.registry.member_ext_owner_class);
    module.registry = klio_ir::ModuleRegistry {
        object_names: object_names.clone(),
        companion_singletons: companion_singletons.clone(),
        enclosing_class: enclosing_class.clone(),
        func_type_params: func_type_params.clone(),
        top_level_delegated_props: top_level_delegated_props.clone(),
        delegated_body_props: delegated_body_props.clone(),
        local_fn_defaults,
        type_aliases,
        hierarchy_methods,
        import_aliases,
        abstract_member_defaults,
        member_ext_owner_class,
        nested_object_aliases: nested_object_aliases.clone(),
        class_const_inits: std::mem::take(&mut module.registry.class_const_inits),
    };
    BuiltModule {
        module: Arc::new(module),
        classes,
        body_prop_inits,
        instance_prop_getters,
        instance_prop_setters,
        parent_ctor_args,
        init_blocks,
        top_level_props,
        extension_props,
        extension_prop_setters,
        main: main_id,
        object_names,
        companion_singletons,
        enum_entry_arg_inits,
        secondary_ctors,
        primary_ctor_default_thunks,
        class_delegates,
        func_defaults,
        enclosing_class,
        enum_entry_methods,
        enum_entry_synth_class,
        func_type_params,
        top_level_delegated_props,
        delegated_body_props,
    }
}
