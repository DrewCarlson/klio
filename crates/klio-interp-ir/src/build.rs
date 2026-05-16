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

use std::rc::Rc;

use std::cell::RefCell;

use klio_ast::{Decl, Expr, Ident, KotlinFile};
use klio_runtime::{ClassDef, ClassParamDef, PropertyDef};

/// Replace every bare `field` identifier in `expr` with
/// `this.<prop_name>`. Used by accessor-body lowering so the IR
/// thunk reads / writes the backing field on the receiver.
fn substitute_field_with_this(prop_name: &str, expr: &Expr) -> Expr {
    use klio_span::{FileId, Span};
    let dummy = Span::new(FileId(0), 0, 0);
    let mut out = expr.clone();
    walk_field(&mut out, prop_name, dummy);
    out
}

fn walk_field(e: &mut Expr, prop: &str, dummy: klio_span::Span) {
    let mut replace = None;
    if let Expr::Path { segments, .. } = e {
        if segments.len() == 1 && segments[0].name == "field" {
            // Rewrite the raw `field` reference to a synthetic member
            // access on `this` that names the backing slot. Vm
            // get_field / set_field detect the `__klio_field__`
            // prefix and skip the custom-getter/setter dispatch.
            let backing = format!("__klio_field__{prop}");
            replace = Some(Expr::Member {
                receiver: Box::new(Expr::Path {
                    segments: vec![Ident { name: "this".into(), span: dummy }],
                    span: dummy,
                }),
                name: Ident { name: backing, span: dummy },
                safe: false,
                span: dummy,
            });
        }
    }
    if let Some(r) = replace {
        *e = r;
        return;
    }
    match e {
        Expr::Call { callee, args, .. } => {
            walk_field(callee, prop, dummy);
            for a in args {
                walk_field(a, prop, dummy);
            }
        }
        Expr::Member { receiver, .. } => walk_field(receiver, prop, dummy),
        Expr::Binary { lhs, rhs, .. } => {
            walk_field(lhs, prop, dummy);
            walk_field(rhs, prop, dummy);
        }
        Expr::Unary { expr, .. } | Expr::Postfix { expr, .. } => walk_field(expr, prop, dummy),
        Expr::If { cond, then_branch, else_branch, .. } => {
            walk_field(cond, prop, dummy);
            walk_field(then_branch, prop, dummy);
            if let Some(e) = else_branch.as_deref_mut() {
                walk_field(e, prop, dummy);
            }
        }
        Expr::Index { receiver, args, .. } => {
            walk_field(receiver, prop, dummy);
            for a in args {
                walk_field(a, prop, dummy);
            }
        }
        Expr::Block(b) => {
            for s in &mut b.stmts {
                match s {
                    klio_ast::Stmt::Expr(e) => walk_field(e, prop, dummy),
                    klio_ast::Stmt::Assign { target, value, .. } => {
                        walk_field(target, prop, dummy);
                        walk_field(value, prop, dummy);
                    }
                    _ => {}
                }
            }
        }
        Expr::StringTemplate { parts, .. } => {
            for p in parts {
                if let klio_ast::StringPart::Interp(e) = p {
                    walk_field(e, prop, dummy);
                }
            }
        }
        Expr::Return { value, .. } => {
            if let Some(v) = value.as_deref_mut() {
                walk_field(v, prop, dummy);
            }
        }
        Expr::Throw { value, .. } => walk_field(value, prop, dummy),
        Expr::IsCheck { expr, .. } | Expr::As { expr, .. } => walk_field(expr, prop, dummy),
        Expr::Spread { expr, .. } => walk_field(expr, prop, dummy),
        _ => {}
    }
}

fn rewrite_block_field(block: &klio_ast::Block, prop: &str) -> klio_ast::Block {
    use klio_span::{FileId, Span};
    let dummy = Span::new(FileId(0), 0, 0);
    let mut out = block.clone();
    for s in &mut out.stmts {
        match s {
            klio_ast::Stmt::Expr(e) => walk_field(e, prop, dummy),
            klio_ast::Stmt::Assign { target, value, .. } => {
                walk_field(target, prop, dummy);
                walk_field(value, prop, dummy);
            }
            _ => {}
        }
    }
    out
}

/// Recursively walk a class's members and lift companion objects,
/// plain nested classes, and inner classes to top-level entries in
/// `out_decls`. Companion singletons are registered with the Vm's
/// `companion_singletons` table and tagged with the outer's
/// visible-member set in `nested_outer_members`. Returns nothing —
/// mutates the passed-in collections.
fn collect_enclosing_member_names(
    c: &klio_ast::Class,
) -> std::collections::HashSet<String> {
    let mut s: std::collections::HashSet<String> = std::collections::HashSet::new();
    for p in &c.primary_params {
        s.insert(p.name.name.clone());
    }
    for m in &c.members {
        match m {
            Decl::Property(p) => {
                s.insert(p.name.name.clone());
            }
            Decl::Function(f) => {
                s.insert(f.name.name.clone());
            }
            Decl::Class(nested) if nested.is_companion => {
                // Companion's members are visible bare-name to
                // siblings (and to nested classes that walk the
                // enclosing chain).
                for m2 in &nested.members {
                    match m2 {
                        Decl::Property(p) => {
                            s.insert(p.name.name.clone());
                        }
                        Decl::Function(f) => {
                            s.insert(f.name.name.clone());
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    if c.is_enum {
        s.insert("entries".to_string());
        s.insert("values".to_string());
        s.insert("valueOf".to_string());
        for e in &c.enum_entries {
            s.insert(e.name.name.clone());
        }
    }
    s
}

fn lift_class_recursive(
    c: &klio_ast::Class,
    enclosing_chain: &[klio_ast::Class],
    out_decls: &mut Vec<Decl>,
    object_names: &mut Vec<String>,
    companion_singletons: &mut std::collections::HashMap<String, String>,
    nested_outer_members: &mut std::collections::HashMap<
        String,
        std::collections::HashSet<String>,
    >,
    enclosing_class: &mut std::collections::HashMap<String, String>,
) {
    for m in &c.members {
        if let Decl::Object(co) = m {
            // Nested `object Foo { … }` inside a class. Lift as
            // a standalone singleton class — `Outer.Foo` reads
            // resolve the global by the bare name.
            object_names.push(co.name.name.clone());
            enclosing_class.insert(co.name.name.clone(), c.name.name.clone());
            let mut extras: std::collections::HashSet<String> =
                collect_enclosing_member_names(c);
            for outer_c in enclosing_chain.iter().rev() {
                extras.extend(collect_enclosing_member_names(outer_c));
            }
            nested_outer_members.insert(co.name.name.clone(), extras);
            out_decls.push(Decl::Class(synthesize_class_from_object(co)));
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
                let mut extras: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for p in &c.primary_params {
                    extras.insert(p.name.name.clone());
                }
                for m2 in &c.members {
                    match m2 {
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
                // Layer in members visible up the enclosing chain
                // so nested companions can reach the outer's
                // companion statics by bare name.
                for outer_c in enclosing_chain.iter().rev() {
                    extras.extend(collect_enclosing_member_names(outer_c));
                }
                nested_outer_members.insert(comp_name.clone(), extras);
                object_names.push(comp_name.clone());
                enclosing_class.insert(comp_name.clone(), c.name.name.clone());
                let mut next_chain: Vec<klio_ast::Class> = enclosing_chain.to_vec();
                next_chain.push(c.clone());
                lift_class_recursive(
                    &renamed,
                    &next_chain,
                    out_decls,
                    object_names,
                    companion_singletons,
                    nested_outer_members,
                    enclosing_class,
                );
                out_decls.push(Decl::Class(renamed));
                companion_singletons.insert(c.name.name.clone(), comp_name);
            } else {
                let mut extras: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                for p in &c.primary_params {
                    extras.insert(p.name.name.clone());
                }
                for m2 in &c.members {
                    match m2 {
                        Decl::Property(p) => {
                            extras.insert(p.name.name.clone());
                        }
                        Decl::Function(f) => {
                            extras.insert(f.name.name.clone());
                        }
                        _ => {}
                    }
                }
                for outer_c in enclosing_chain.iter().rev() {
                    extras.extend(collect_enclosing_member_names(outer_c));
                }
                nested_outer_members
                    .insert(nested.name.name.clone(), extras);
                enclosing_class
                    .insert(nested.name.name.clone(), c.name.name.clone());
                let mut next_chain: Vec<klio_ast::Class> = enclosing_chain.to_vec();
                next_chain.push(c.clone());
                lift_class_recursive(
                    nested,
                    &next_chain,
                    out_decls,
                    object_names,
                    companion_singletons,
                    nested_outer_members,
                    enclosing_class,
                );
                out_decls.push(Decl::Class(nested.clone()));
            }
        }
    }
}

/// Synthesise a `Class` AST node that mirrors an `ObjectDecl`. The
/// resulting class participates in the regular class-lowering pipeline
/// (members, supertype delegation, init blocks); a separate
/// `object_singletons` map then allocates one instance per name and
/// the Vm publishes it as a global at startup.
fn synthesize_class_from_object(o: &klio_ast::ObjectDecl) -> klio_ast::Class {
    let members: Vec<Decl> = o.members.clone();
    klio_ast::Class {
        name: o.name.clone(),
        type_params: Vec::new(),
        where_bounds: Vec::new(),
        primary_params: Vec::new(),
        init_blocks: Vec::new(),
        supertypes: o.supertypes.clone(),
        supertype_args: o.supertype_args.clone(),
        supertype_delegates: o.supertypes.iter().map(|_| None).collect(),
        is_data: o.is_data,
        is_companion: false,
        is_enum: false,
        is_sealed: false,
        is_expect: o.is_expect,
        is_actual: o.is_actual,
        is_open: false,
        is_abstract: false,
        is_inner: false,
        secondary_ctors: Vec::new(),
        is_interface: false,
        is_fun_interface: false,
        is_value: false,
        is_annotation: false,
        enum_entries: Vec::new(),
        members,
        visibility: klio_ast::Visibility::Public,
        primary_ctor_visibility: None,
        annotations: Vec::new(),
        span: o.span,
    }
}

/// Result of building an IR module from a single Kotlin file.
pub struct BuiltModule {
    /// The frozen IR module ready for `Vm::run`.
    pub module: Rc<klio_ir::Module>,
    /// Per-class runtime metadata, keyed by simple class name. The
    /// Vm uses these when allocating instances. As the IR Class
    /// grows to carry the full runtime shape (methods, supertypes,
    /// init blocks lowered as FuncIds) this table shrinks and
    /// eventually goes away.
    pub classes: std::collections::HashMap<String, Rc<ClassDef>>,
    /// `(class name, property name) -> FuncId` for body properties
    /// with a literal-style initialiser (`val x: Int = 5`). The Vm
    /// invokes the FuncId during allocation to populate the field.
    /// Properties whose init references `this`, captured outer
    /// state, or another instance field land later as the IR grows
    /// to express them.
    pub body_prop_inits:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// `(class name, property name) -> FuncId` for body properties
    /// with a custom getter (`val full: String get() = "$first $last"`).
    /// The Vm calls these FuncIds (with `this` as the sole arg) when
    /// `Vm::get_field` is invoked for a custom-getter property.
    pub instance_prop_getters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Custom-setter FuncIds, keyed the same as getters. The Vm
    /// invokes the setter (`set(value) { … }`) when set_field
    /// targets a property whose class declares one.
    pub instance_prop_setters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Parent-ctor argument thunks per class. Each entry is the
    /// list of FuncIds — one per parent ctor arg — that take the
    /// class's own primary-ctor params and return the value passed
    /// to the parent. `class Dog(name: String) : Animal(name)` ends
    /// up with `{ "Dog" => [thunk(name -> name)] }`.
    pub parent_ctor_args:
        std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// `init { ... }` blocks per class. Each FuncId takes `this`
    /// as its sole param and runs the block's statements in order.
    /// `new_instance` invokes them after primary-ctor field
    /// binding + body-property init.
    pub init_blocks: std::collections::HashMap<String, Vec<klio_ir::FuncId>>,
    /// Top-level property initialisers (`val n = 0`). Vm::run
    /// invokes each in declaration order at startup so reads
    /// against the global env see the initial value.
    pub top_level_props: Vec<(String, klio_ir::FuncId)>,
    /// Top-level extension properties (`val T.name: U get() = …`).
    /// Keyed by `(receiver simple type name, property name)`. The
    /// Vm probes this table from `get_field` when a regular field
    /// lookup fails.
    pub extension_props:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// Extension-property setters keyed by `(receiver type, prop)`.
    /// The Vm invokes the FuncId with `[receiver, value]` when
    /// `set_field` targets an extension property declared via
    /// `var T.x: ... set(value) { … }`.
    pub extension_prop_setters:
        std::collections::HashMap<(String, String), klio_ir::FuncId>,
    /// FuncId of the file's `main`, or `None` when the file has no
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
    pub secondary_ctors:
        std::collections::HashMap<String, Vec<SecondaryCtorEntry>>,
    /// Class delegation entries: `class W(g: Greeter) : Greeter by g`.
    /// Each tuple is `(supertype simple name, thunk FuncId taking
    /// primary-ctor params)`. The Vm evaluates these at construction
    /// time and stores the result under `__delegate__<superName>` on
    /// the instance; missing methods on `W` then forward to the
    /// delegate.
    pub class_delegates:
        std::collections::HashMap<String, Vec<(String, klio_ir::FuncId)>>,
    /// Per-function default-arg thunks. Each entry is keyed by the
    /// target function's `FuncId` and holds an
    /// `Option<FuncId>` slot per parameter; `Some(fid)` runs the
    /// default-init thunk when the caller omits the arg.
    pub func_defaults:
        std::collections::HashMap<klio_ir::FuncId, Vec<Option<klio_ir::FuncId>>>,
    /// Inner class → outer class name. Populated during the
    /// recursive lift so the Vm can resolve `this@Outer.X` and
    /// outer-chain field lookups for nested classes lifted to
    /// top-level decls.
    pub enclosing_class:
        std::collections::HashMap<String, String>,
    /// Pre-lowered method bodies for enum entries with per-entry
    /// `override fun …` blocks. Keyed by (synth class name,
    /// method name) where the synth class is `<EnumClass>$<Entry>`.
    /// The Vm tags each entry instance and routes call_member
    /// through this table when the entry has its own overrides.
    pub enum_entry_methods: std::collections::HashMap<
        (String, String),
        (std::rc::Rc<klio_ir::Module>, klio_ir::FuncId),
    >,
    /// `(enum class name, entry name) -> synth class name` for
    /// entries whose body declares method overrides. The Vm reads
    /// this to identify which enum entries have per-entry methods.
    pub enum_entry_synth_class:
        std::collections::HashMap<(String, String), String>,
    /// Per-function type parameter names (in source order). The Vm
    /// uses this to bind reified type-args as synthesized
    /// `Value::Class` globals for the duration of the call.
    pub func_type_params:
        std::collections::HashMap<klio_ir::FuncId, Vec<String>>,
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
    pub is_super: bool,
    /// `true` for an explicit `: this(...)` delegation. Distinguishes
    /// it from `CtorDelegation::None` (implicit `super()`), which also
    /// has `is_super == false` but must build the instance shell
    /// rather than re-dispatch a sibling constructor.
    pub is_this: bool,
    pub delegation_arg_thunks: Vec<klio_ir::FuncId>,
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
    // build pass would otherwise emit bare-name FQNs and pack
    // bindings keyed by `kotlinx.atomicfu.AtomicInt.<method>`
    // wouldn't resolve at dispatch.
    let mut fqn_overrides: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    let mut func_fqn_overrides: std::collections::HashMap<String, String> =
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
            if let Decl::Function(fn_d) = d {
                if !prefix.is_empty() {
                    func_fqn_overrides
                        .insert(fn_d.name.name.clone(), format!("{}.{}", prefix, fn_d.name.name));
                }
            }
        }
        combined.decls.extend(f.decls.iter().cloned());
    }
    build_module_with_overrides(&combined, &fqn_overrides, &func_fqn_overrides)
}

fn collect_class_fqns(
    d: &Decl,
    pkg: &str,
    out: &mut std::collections::HashMap<String, String>,
) {
    if let Decl::Class(c) = d {
        if !pkg.is_empty() {
            out.insert(c.name.name.clone(), format!("{}.{}", pkg, c.name.name));
        }
        for m in &c.members {
            collect_class_fqns(m, pkg, out);
        }
    }
    if let Decl::Object(o) = d {
        if !pkg.is_empty() {
            out.insert(o.name.name.clone(), format!("{}.{}", pkg, o.name.name));
        }
    }
}

pub fn build_module(file: &KotlinFile) -> BuiltModule {
    build_module_with_overrides(
        file,
        &std::collections::HashMap::new(),
        &std::collections::HashMap::new(),
    )
}

fn build_module_with_overrides(
    file: &KotlinFile,
    fqn_overrides: &std::collections::HashMap<String, String>,
    func_fqn_overrides: &std::collections::HashMap<String, String>,
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
    let mut all_decls: Vec<Decl> = Vec::with_capacity(file.decls.len());
    for d in &file.decls {
        match d {
            Decl::Object(o) => {
                if o.is_expect && actual_object_names.contains(&o.name.name) {
                    continue;
                }
                object_names.push(o.name.name.clone());
                all_decls.push(Decl::Class(synthesize_class_from_object(o)));
            }
            Decl::Class(c) => {
                lift_class_recursive(
                    c,
                    &[],
                    &mut all_decls,
                    &mut object_names,
                    &mut companion_singletons,
                    &mut nested_outer_members,
                    &mut enclosing_class,
                );
                all_decls.push(d.clone());
            }
            other => all_decls.push(other.clone()),
        }
    }
    // The inline lift loop below has been replaced by
    // `lift_class_recursive`. Disable the original arm so it
    // doesn't execute twice and produce duplicate decls.
    if false {
        for d in &file.decls {
            match d {
                Decl::Object(_) => {}
                Decl::Class(c) => {
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
                            nested_outer_members
                                .insert(nested.name.name.clone(), extras);
                            all_decls.push(Decl::Class(nested.clone()));
                        }
                    }
                }
                all_decls.push(d.clone());
                }
                _ => {}
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
    // Drop superseded `expect` decls so every downstream pass sees
    // only the active definition for each name.
    all_decls.retain(|d| match d {
        Decl::Function(f) => !(f.is_expect && actual_func_names_set.contains(&f.name.name)),
        Decl::Class(c) => !(c.is_expect && actual_class_names_set.contains(&c.name.name)),
        Decl::Object(o) => !(o.is_expect && actual_object_names_set.contains(&o.name.name)),
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
    // Pre-register every class name so `class_id` resolves
    // regardless of declaration order: a method body may reference a
    // class declared later in the module (kotlinx-io's `Buffer`
    // methods use `Segment` / `SegmentPool`, both declared after
    // `Buffer`). `add_class` reuses these reserved slots.
    for d in decls {
        if let Decl::Class(c) = d {
            module.reserve_class(&c.name.name);
        }
    }
    for d in decls {
        if let Decl::Class(c) = d {
            let empty = std::collections::HashSet::new();
            let extras = nested_outer_members.get(&c.name.name).unwrap_or(&empty);
            let _ = klio_ir::lower::lower_class_with_extras(
                &mut module,
                c,
                &file_classes,
                extras,
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
            let id = klio_ir::FuncId(module.funcs.len() as u32);
            let fqn = func_fqn_overrides
                .get(&f.name.name)
                .cloned()
                .unwrap_or_else(|| {
                    if package_prefix.is_empty() {
                        f.name.name.clone()
                    } else {
                        format!("{}.{}", package_prefix, f.name.name)
                    }
                });
            module.funcs.push(klio_ir::Func {
                id,
                name: f.name.name.clone(),
                fqn,
                params: Vec::new(),
                return_ty: klio_ir::TypeRef::unit(),
                n_locals: 0,
                blocks: Vec::new(),
                entry: klio_ir::BlockId(0),
                is_suspend: false,
                is_tailrec: f.is_tailrec,
                is_lambda: false,
            });
            module.func_index.push((f.name.name.clone(), id));
            if f.is_tailrec {
                module.tailrec_fn_names.push(f.name.name.clone());
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
            placed.fqn = module.funcs[id.0 as usize].fqn.clone();
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
                let mut slots: Vec<Option<klio_ir::FuncId>> = Vec::with_capacity(f.params.len());
                for p in &f.params {
                    if let Some(default_expr) = &p.default {
                        let fid = klio_ir::lower::lower_expr_as_thunk(
                            &mut module,
                            default_expr,
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
            for m in &c.members {
                if let Decl::Property(p) = m {
                    if let Some(init) = &p.init {
                        let fid = klio_ir::lower::lower_accessor_expr(
                            &mut module,
                            &c.name.name,
                            &own_members,
                            &prop_init_params,
                            init,
                            &format!("__init_prop_{}_{}", c.name.name, p.name.name),
                        );
                        body_prop_inits.insert((c.name.name.clone(), p.name.name.clone()), fid);
                    } else if let Some(delegate) = &p.delegate {
                        delegated_body_props
                            .insert((c.name.name.clone(), p.name.name.clone()));
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
                                let rewritten =
                                    substitute_field_with_this(&p.name.name, body);
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
                        }
                    }
                    if let Some(setter) = &p.setter {
                        let setter_param_name = setter
                            .params
                            .first()
                            .map(|n| n.name.clone())
                            .unwrap_or_else(|| "value".to_string());
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
    let globals_for_capture = std::rc::Rc::new(RefCell::new(klio_runtime::Env::new()));
    let mut classes: std::collections::HashMap<String, Rc<ClassDef>> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Class(c) = d {
            let primary_params: Vec<ClassParamDef> = c
                .primary_params
                .iter()
                .map(|p| ClassParamDef {
                    property: p.property,
                    name: p.name.name.clone(),
                    default: p.default.as_ref().map(|e| std::rc::Rc::new(e.clone())),
                })
                .collect();
            let body_properties: Vec<PropertyDef> = c
                .members
                .iter()
                .filter_map(|m| match m {
                    Decl::Property(p) => Some(PropertyDef {
                        name: p.name.name.clone(),
                        mutable: p.mutable,
                        init: p.init.as_ref().map(|e| std::rc::Rc::new(e.clone())),
                        getter: p.getter.as_ref().map(|a| std::rc::Rc::new(a.clone())),
                        setter: p.setter.as_ref().map(|a| std::rc::Rc::new(a.clone())),
                        delegate: p.delegate.as_ref().map(|e| std::rc::Rc::new(e.clone())),
                        is_abstract: p.is_abstract,
                        is_lateinit: p.is_lateinit,
                    }),
                    _ => None,
                })
                .collect();
            let is_object = object_names.iter().any(|n| n == &c.name.name);
            let def = std::rc::Rc::new(ClassDef {
                name: c.name.name.clone(),
                fqn: fqn_overrides
                    .get(&c.name.name)
                    .cloned()
                    .unwrap_or_else(|| {
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
                is_data: c.is_data,
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
                    .map(|sc| std::rc::Rc::new(sc.clone()))
                    .collect(),
                supertype_names: c
                    .supertypes
                    .iter()
                    .map(|t| t.name.name.clone())
                    .collect(),
                parent: RefCell::new(None),
                interfaces: RefCell::new(Vec::new()),
                is_interface: c.is_interface,
                is_fun_interface: c.is_fun_interface,
                parent_ctor_args: Vec::new(),
                enum_entries: RefCell::new(Vec::new()),
                companion: RefCell::new(None),
                enclosing_class: RefCell::new(None),
                nested_classes: RefCell::new(Vec::new()),
                captured_env: std::rc::Rc::clone(&globals_for_capture),
                supertype_delegates: RefCell::new(Vec::new()),
                delegate_forwarders: RefCell::new(Vec::new()),
                object_singleton: RefCell::new(None),
            });
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
        (std::rc::Rc<klio_ir::Module>, klio_ir::FuncId),
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
                    let mut fields: Vec<(String, klio_runtime::Value)> = Vec::new();
                    fields.push((
                        "name".to_string(),
                        klio_runtime::Value::String(std::rc::Rc::new(entry.name.name.clone())),
                    ));
                    fields.push((
                        "ordinal".to_string(),
                        klio_runtime::Value::new_int(ordinal as i64),
                    ));
                    let inst = std::rc::Rc::new(RefCell::new(klio_runtime::InstanceData {
                        class: std::rc::Rc::clone(&class_def),
                        fields,
                        outer: None,
                        identity: id,
                        native_state: None,
                    }));
                    // Per-entry method overrides — `RED { override fun
                    // f() = … }`. Lower each entry-specific method
                    // body and stash so the Vm can dispatch it
                    // when the entry instance receives a call.
                    if !entry.body_members.is_empty() {
                        let synth_class_name = format!(
                            "{}${}",
                            c.name.name, entry.name.name
                        );
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
                                let module_rc = std::rc::Rc::new(sub_module);
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
                            klio_runtime::Value::String(std::rc::Rc::new(
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
                                &format!(
                                    "__enum_arg_{}_{}_{idx}",
                                    c.name.name, entry.name.name
                                ),
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
    let class_table_snapshot: std::collections::HashMap<String, Rc<ClassDef>> =
        classes.clone();
    for (_, def) in &classes {
        for sup_name in &def.supertype_names {
            if let Some(sup_def) = class_table_snapshot.get(sup_name) {
                if sup_def.is_interface {
                    def.interfaces.borrow_mut().push(Rc::clone(sup_def));
                } else if def.parent.borrow().is_none() {
                    *def.parent.borrow_mut() = Some(Rc::clone(sup_def));
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
        if let Decl::Class(c) = d {
            for parent_args_opt in &c.supertype_args {
                if let Some(parent_args) = parent_args_opt {
                    let param_names: Vec<String> = c
                        .primary_params
                        .iter()
                        .map(|p| p.name.name.clone())
                        .collect();
                    let param_refs: Vec<&str> =
                        param_names.iter().map(|s| s.as_str()).collect();
                    let mut fids: Vec<klio_ir::FuncId> = Vec::with_capacity(parent_args.len());
                    for (idx, e) in parent_args.iter().enumerate() {
                        let fid = klio_ir::lower::lower_expr_as_param_thunk(
                            &mut module,
                            &param_refs,
                            e,
                            &format!("__parent_ctor_arg_{}_{idx}", c.name.name),
                        );
                        fids.push(fid);
                    }
                    parent_ctor_args.insert(c.name.name.clone(), fids);
                    break;
                }
            }
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
            let param_refs: Vec<&str> =
                param_names.iter().map(|s| s.as_str()).collect();
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
            }
            let mut entries: Vec<SecondaryCtorEntry> = Vec::new();
            for (sc_idx, sc) in c.secondary_ctors.iter().enumerate() {
                let param_names: Vec<String> =
                    sc.params.iter().map(|p| p.name.name.clone()).collect();
                let param_refs: Vec<&str> =
                    param_names.iter().map(|s| s.as_str()).collect();
                let (delegation_args, is_super, is_this) = match &sc.delegation {
                    klio_ast::CtorDelegation::This(args) => (args.clone(), false, true),
                    klio_ast::CtorDelegation::Super(args) => (args.clone(), true, false),
                    klio_ast::CtorDelegation::None => (Vec::new(), false, false),
                };
                let mut arg_fids: Vec<klio_ir::FuncId> =
                    Vec::with_capacity(delegation_args.len());
                for (arg_idx, e) in delegation_args.iter().enumerate() {
                    let fid = klio_ir::lower::lower_expr_as_param_thunk(
                        &mut module,
                        &param_refs,
                        e,
                        &format!(
                            "__sec_ctor_{}_{sc_idx}_arg{arg_idx}",
                            c.name.name
                        ),
                    );
                    arg_fids.push(fid);
                }
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
                    is_super,
                    is_this,
                    delegation_arg_thunks: arg_fids,
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
    for d in decls {
        if let Decl::Property(p) = d {
            if p.receiver_type.is_some() {
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
    let mut extension_prop_setters: std::collections::HashMap<
        (String, String),
        klio_ir::FuncId,
    > = std::collections::HashMap::new();
    for d in decls {
        if let Decl::Property(p) = d {
            if let Some(recv) = &p.receiver_type {
                if let Some(getter) = &p.getter {
                    let empty_members = std::collections::HashSet::new();
                    let fid = match &getter.body {
                        klio_ast::FunctionBody::Expr(body) => Some(
                            klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this"],
                                body,
                                &format!("__ext_get_{}_{}", recv.name.name, p.name.name),
                            ),
                        ),
                        klio_ast::FunctionBody::Block(blk) => Some(
                            klio_ir::lower::lower_accessor_block(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this"],
                                blk,
                                &format!("__ext_get_{}_{}", recv.name.name, p.name.name),
                            ),
                        ),
                    };
                    if let Some(fid) = fid {
                        extension_props
                            .insert((recv.name.name.clone(), p.name.name.clone()), fid);
                    }
                }
                if let Some(setter) = &p.setter {
                    let setter_param_name = setter
                        .params
                        .first()
                        .map(|n| n.name.clone())
                        .unwrap_or_else(|| "value".to_string());
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
                        klio_ast::FunctionBody::Expr(body) => Some(
                            klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this", setter_param_name.as_str()],
                                body,
                                &format!(
                                    "__ext_set_{}_{}",
                                    recv.name.name, p.name.name
                                ),
                            ),
                        ),
                        klio_ast::FunctionBody::Block(blk) => Some(
                            klio_ir::lower::lower_accessor_block(
                                &mut module,
                                &recv.name.name,
                                &empty_members,
                                &["this", setter_param_name.as_str()],
                                blk,
                                &format!(
                                    "__ext_set_{}_{}",
                                    recv.name.name, p.name.name
                                ),
                            ),
                        ),
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
    module.registry = klio_ir::ModuleRegistry {
        object_names: object_names.clone(),
        companion_singletons: companion_singletons.clone(),
        enclosing_class: enclosing_class.clone(),
        func_type_params: func_type_params.clone(),
        top_level_delegated_props: top_level_delegated_props.clone(),
        delegated_body_props: delegated_body_props.clone(),
    };
    BuiltModule {
        module: Rc::new(module),
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
