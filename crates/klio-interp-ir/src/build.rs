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
use klio_runtime::{ClassDef, ClassParamDef};

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
            let def = std::rc::Rc::new(ClassDef {
                name: c.name.name.clone(),
                fqn: c.name.name.clone(),
                annotation_names: Vec::new(),
                primary_params,
                methods: Vec::new(),
                body_properties: Vec::new(),
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
        main: main_id,
    }
}
