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

use klio_ast::{Decl, KotlinFile};
use klio_runtime::{ClassDef, ClassParamDef, PropertyDef};

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
    /// FuncId of the file's `main`, or `None` when the file has no
    /// `main` entry point.
    pub main: Option<klio_ir::FuncId>,
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

    // Map every class declaration by simple name so class-to-class
    // member-name lookups during body lowering have access to the
    // wider file's class shape.
    let mut file_classes: std::collections::HashMap<String, &klio_ast::Class> =
        std::collections::HashMap::new();
    for d in &file.decls {
        if let Decl::Class(c) = d {
            file_classes.insert(c.name.name.clone(), c);
        }
    }
    for d in &file.decls {
        if let Decl::Class(c) = d {
            let _ = klio_ir::lower::lower_class_with_file(&mut module, c, &file_classes);
        }
    }

    // Reserve a stub Func slot per top-level function so call-site
    // lowering can resolve forward references.
    let mut stub_ids: std::collections::HashMap<String, klio_ir::FuncId> =
        std::collections::HashMap::new();
    for d in &file.decls {
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
    for d in &file.decls {
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
    for d in &file.decls {
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
                        if let klio_ast::FunctionBody::Expr(body) = &getter.body {
                            let fid = klio_ir::lower::lower_accessor_expr(
                                &mut module,
                                &c.name.name,
                                &own_members,
                                &["this"],
                                body,
                                &format!("__get_{}_{}", c.name.name, p.name.name),
                            );
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
    for d in &file.decls {
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

    BuiltModule {
        module: Rc::new(module),
        classes,
        body_prop_inits,
        instance_prop_getters,
        main: main_id,
    }
}
