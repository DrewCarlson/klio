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
            replace = Some(Expr::Member {
                receiver: Box::new(Expr::Path {
                    segments: vec![Ident { name: "this".into(), span: dummy }],
                    span: dummy,
                }),
                name: Ident { name: prop.to_string(), span: dummy },
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
    /// FuncId of the file's `main`, or `None` when the file has no
    /// `main` entry point.
    pub main: Option<klio_ir::FuncId>,
    /// Names of `object Foo { … }` singleton declarations in source
    /// order. The Vm allocates one instance per name at startup and
    /// publishes it as a global so bare-name `Foo` reads resolve.
    pub object_names: Vec<String>,
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
pub fn build_module(file: &KotlinFile) -> BuiltModule {
    let mut module = klio_ir::Module::default();

    // Synthesise a `Class` for every `object` declaration so the
    // shared class-lowering pipeline picks them up (members, init,
    // supertypes, accessors). A separate `object_names` list tells
    // the Vm to allocate one instance per object at startup.
    let mut object_names: Vec<String> = Vec::new();
    let mut all_decls: Vec<Decl> = Vec::with_capacity(file.decls.len());
    for d in &file.decls {
        match d {
            Decl::Object(o) => {
                object_names.push(o.name.name.clone());
                all_decls.push(Decl::Class(synthesize_class_from_object(o)));
            }
            other => all_decls.push(other.clone()),
        }
    }
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
    for d in decls {
        if let Decl::Class(c) = d {
            let _ = klio_ir::lower::lower_class_with_file(&mut module, c, &file_classes);
        }
    }

    // Reserve a stub Func slot per top-level function so call-site
    // lowering can resolve forward references.
    let mut stub_ids: std::collections::HashMap<String, klio_ir::FuncId> =
        std::collections::HashMap::new();
    for d in decls {
        if let Decl::Function(f) = d {
            let id = klio_ir::FuncId(module.funcs.len() as u32);
            module.funcs.push(klio_ir::Func {
                id,
                name: f.name.name.clone(),
                fqn: f.name.name.clone(),
                params: Vec::new(),
                return_ty: klio_ir::TypeRef::unit(),
                n_locals: 0,
                blocks: Vec::new(),
                entry: klio_ir::BlockId(0),
                is_suspend: false,
                is_tailrec: f.is_tailrec,
            });
            module.func_index.push((f.name.name.clone(), id));
            if f.is_tailrec {
                module.tailrec_fn_names.push(f.name.name.clone());
            }
            stub_ids.insert(f.name.name.clone(), id);
        }
    }

    // Lower each function body into its reserved slot.
    let mut main_id: Option<klio_ir::FuncId> = None;
    for d in decls {
        if let Decl::Function(f) = d {
            let func = klio_ir::lower::lower_function_body_into(&mut module, f, &file_classes);
            let id = *stub_ids.get(&f.name.name).expect("stub registered above");
            let mut placed = func;
            placed.id = id;
            module.funcs[id.0 as usize] = placed;
            if f.name.name == "main" {
                main_id = Some(id);
            }
            module.top_level.push(id);
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
            for m in &c.members {
                if let Decl::Property(p) = m {
                    if let Some(init) = &p.init {
                        let fid = klio_ir::lower::lower_expr_as_thunk(
                            &mut module,
                            init,
                            &format!("__init_prop_{}_{}", c.name.name, p.name.name),
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
            let def = std::rc::Rc::new(ClassDef {
                name: c.name.name.clone(),
                fqn: c.name.name.clone(),
                annotation_names: Vec::new(),
                primary_params,
                methods: Vec::new(),
                body_properties,
                init_blocks: Vec::new(),
                is_data: c.is_data,
                is_object: false,
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
                    entries.push((entry.name.name.clone(), klio_runtime::Value::Instance(inst)));
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
            let mut fids: Vec<klio_ir::FuncId> = Vec::new();
            for (idx, blk) in c.init_blocks.iter().enumerate() {
                let fid = klio_ir::lower::lower_accessor_block(
                    &mut module,
                    &c.name.name,
                    &own_members,
                    &["this"],
                    blk,
                    &format!("__init_block_{}_{idx}", c.name.name),
                );
                fids.push(fid);
            }
            init_blocks.insert(c.name.name.clone(), fids);
        }
    }

    // Top-level property initialisers — `val name = expr` /
    // `var name = expr` declared at file scope. Each lowers to a
    // 0-arg thunk. Vm::run drives them at startup.
    let mut top_level_props: Vec<(String, klio_ir::FuncId)> = Vec::new();
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
            }
        }
    }

    // Top-level extension properties: `val T.name: U get() = …` /
    // `var T.name: U get() = … set(value) { … }`. Each lowers to a
    // 1-arg thunk taking the receiver as `this`.
    let mut extension_props: std::collections::HashMap<(String, String), klio_ir::FuncId> =
        std::collections::HashMap::new();
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
            }
        }
    }

    BuiltModule {
        module: Rc::new(module),
        classes,
        body_prop_inits,
        instance_prop_getters,
        parent_ctor_args,
        init_blocks,
        top_level_props,
        extension_props,
        main: main_id,
        object_names,
    }
}
