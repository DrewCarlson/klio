//! Shared runtime types for the interpreter and the stdlib.
//!
//! `Value`, `RuntimeError`, the `Output` trait, and `Env` live here so that
//! `klio-stdlib` can express Rust-native intrinsics in terms of the same
//! types `klio-interp` evaluates against, without either crate depending on
//! the other.
#![allow(unsafe_code)] // `ObjRef`'s adaptive cell; see its safety docs.

mod float_fmt;

mod objcell;
pub use objcell::*;

mod host;
pub use host::*;

mod value;
pub use value::*;

mod class;
pub use class::*;

mod output;
pub use output::*;

mod env;
pub use env::*;

mod gc_traverse;
pub(crate) use gc_traverse::{publish_env, publish_value};

/// The whole point of the value-model migration: a `Value` (and the
/// interpreter state reachable through it) can be sent and shared
/// across OS threads. If a future change reintroduces an `Rc` /
/// `RefCell` / non-`Send` payload anywhere in the graph, this fails
/// to compile — the regression guard for the parallel backing.
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Value>();
    assert_send_sync::<ObjRef<Value>>();
    assert_send_sync::<Env>();
    assert_send_sync::<ClassDef>();
};

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn make_class(name: &str, is_data: bool, is_object: bool, is_enum: bool) -> Arc<ClassDef> {
        Arc::new(ClassDef {
            name: name.to_string(),
            fqn: name.to_string(),
            annotation_names: Vec::new(),
            primary_params: Vec::new(),
            methods: Vec::new(),
            body_properties: Vec::new(),
            init_blocks: Vec::new(),
            init_block_property_positions: Vec::new(),
            is_data,
            is_value: false,
            is_object,
            is_enum,
            is_sealed: false,
            supertype_names: Vec::new(),
            parent: ObjRef::new(None),
            interfaces: ObjRef::new(Vec::new()),
            is_interface: false,
            is_fun_interface: false,
            parent_ctor_args: Vec::new(),
            is_open: false,
            is_abstract: false,
            is_inner: false,
            is_anonymous: false,
            secondary_ctors: Vec::new(),
            enum_entries: ObjRef::new(Vec::new()),
            companion: ObjRef::new(None),
            enclosing_class: ObjRef::new(None),
            nested_classes: ObjRef::new(Vec::new()),
            captured_env: ObjRef::new(Env::new()),
            supertype_delegates: ObjRef::new(Vec::new()),
            delegate_forwarders: ObjRef::new(Vec::new()),
            object_singleton: ObjRef::new(None),
        })
    }

    #[test]
    fn plain_instance_display_uses_class_at_hex() {
        let cls = make_class("Foo", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 0x2a,
            native_state: None,
        });
        assert_eq!(format!("{}", Value::Instance(inst)), "Foo@2a");
    }

    #[test]
    fn data_instance_display_unchanged() {
        // Data classes still render via the data-class form; identity is
        // irrelevant. (Field rendering exercised by integration tests.)
        let cls = make_class("D", true, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 99,
            native_state: None,
        });
        assert_eq!(format!("{}", Value::Instance(inst)), "D()");
    }

    #[test]
    fn enum_entries_is_runtime_type_matches_both() {
        let entries = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: Some(Arc::new("Color".to_string())),
            backing: None,
        };
        assert!(entries.is_runtime_type("List"));
        assert!(entries.is_runtime_type("EnumEntries"));
        assert!(entries.is_runtime_type("Collection"));

        let plain = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: None,
            backing: None,
        };
        assert!(plain.is_runtime_type("List"));
        assert!(!plain.is_runtime_type("EnumEntries"));
    }

    #[test]
    fn publish_deep_nested_graph_publishes_every_cell() {
        // List -> Instance -> field Map -> Cell
        let cell = ObjRef::new(Value::Int(7));
        let map_entries = ObjRef::new(vec![(
            Value::String(Arc::new("k".into())),
            Value::Cell(cell.clone()),
        )]);
        let map = Value::Map {
            entries: map_entries.clone(),
            mutable: true,
        };
        let cls = make_class("Holder", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: vec![("m".into(), map)],
            outer: None,
            identity: 1,
            native_state: None,
        });
        let items = ObjRef::new(vec![Value::Instance(inst.clone())]);
        let root = Value::List {
            items: items.clone(),
            mutable: false,
            enum_class: None,
            backing: None,
        };

        assert!(!items.is_shared());
        assert!(!inst.is_shared());
        assert!(!map_entries.is_shared());
        assert!(!cell.is_shared());

        root.publish_deep();

        assert!(items.is_shared());
        assert!(inst.is_shared());
        assert!(map_entries.is_shared());
        assert!(cell.is_shared());
        // captured_env of the embedded ClassDef is reached too.
        if let Value::Instance(i) = &Value::Instance(inst.clone()) {
            assert!(i.borrow().class.captured_env.is_shared());
        }
    }

    #[test]
    fn publish_deep_cyclic_graph_terminates() {
        // Instance whose field is a Cell pointing back to the instance.
        let cls = make_class("Node", false, false, false);
        let inst = ObjRef::new(InstanceData {
            class: cls,
            fields: Vec::new(),
            outer: None,
            identity: 1,
            native_state: None,
        });
        let cell = ObjRef::new(Value::Instance(inst.clone()));
        inst.borrow_mut()
            .fields
            .push(("self".into(), Value::Cell(cell.clone())));

        // Env whose parent chain loops back on itself.
        let env_cell: ObjRef<Env> = ObjRef::new(Env::new());
        env_cell.borrow_mut().parent = Some(env_cell.clone());
        env_cell
            .borrow_mut()
            .define("here", Value::Instance(inst.clone()));
        let lam = Value::Lambda {
            params: Arc::new(Vec::new()),
            body: Arc::new(klio_ast::Block {
                stmts: Vec::new(),
                span: klio_span::Span::new(klio_span::FileId(0), 0, 0),
            }),
            env: env_cell.clone(),
            absorb_return: false,
        };

        Value::Instance(inst.clone()).publish_deep();
        lam.publish_deep();

        assert!(inst.is_shared());
        assert!(cell.is_shared());
        assert!(env_cell.is_shared());
    }

    #[test]
    fn publish_deep_is_idempotent() {
        let cell = ObjRef::new(Value::Int(1));
        let items = ObjRef::new(vec![Value::Cell(cell.clone())]);
        let root = Value::List {
            items: items.clone(),
            mutable: true,
            enum_class: None,
            backing: None,
        };

        root.publish_deep();
        root.publish_deep();

        assert!(items.is_shared());
        assert!(cell.is_shared());
    }

    #[test]
    fn publish_deep_scalars_are_noops() {
        Value::Int(42).publish_deep();
        Value::String(Arc::new("hi".into())).publish_deep();
        Value::Null.publish_deep();
        Value::Unit.publish_deep();
        Value::IrClosure {
            id: 0,
            captures: Arc::new(vec![Value::Int(1), Value::Bool(true)]),
        }
        .publish_deep();
    }

    #[test]
    fn enum_entries_keeps_list_type_fqn_for_dispatch() {
        // Stdlib member dispatch keys on type_fqn — EnumEntries values must
        // continue to dispatch through `kotlin.collections.List`.
        let entries = Value::List {
            items: ObjRef::new(vec![Value::Int(1)]),
            mutable: false,
            enum_class: Some(Arc::new("Color".to_string())),
            backing: None,
        };
        assert_eq!(entries.type_fqn(), "kotlin.collections.List");
    }

    /// The `gc` backing: a cell reachable from a registered root
    /// survives collection; a cell that nothing references is swept
    /// (the heap drops its retaining `Arc`). Memory safety holds
    /// regardless — a swept-but-still-cloned cell stays alive via its
    /// own strong count.
    #[cfg(feature = "gc")]
    #[test]
    fn gc_collect_keeps_reachable_sweeps_garbage() {
        // A root env holding a list value: the list cell is reachable.
        let env: ObjRef<Env> = ObjRef::new(Env::new());
        let live = ObjRef::new(vec![Value::Int(7)]);
        env.borrow_mut().define(
            "xs",
            Value::List {
                items: live.clone(),
                mutable: true,
                enum_class: None,
                backing: None,
            },
        );
        gc::register_root_env(&env);

        // An unrooted cell. We keep the `ObjRef` alive across the
        // collection so its backing address cannot be recycled (which
        // would alias another cell's identity): the cell stays live
        // via this clone's strong count, but it is unreachable from
        // any registered root, so the sweep must drop the *heap's*
        // retaining handle for it.
        let garbage = ObjRef::new(vec![Value::Int(99)]);
        let garbage_id = garbage.identity();
        assert!(
            gc::heap_contains(garbage_id),
            "newly allocated cell is registered"
        );

        gc::collect();

        // The reachable list cell's contents are intact post-collect.
        assert!(matches!(live.borrow().as_slice(), [Value::Int(7)]));
        // The unreachable cell's heap retainer was dropped by the
        // sweep even though the cell itself is still alive here.
        assert!(
            !gc::heap_contains(garbage_id),
            "unreachable cell should have been swept from the heap"
        );
        assert!(
            matches!(garbage.borrow().as_slice(), [Value::Int(99)]),
            "swept-but-clone-alive cell is still safely usable"
        );
        // The root-reachable cell survived collection.
        assert!(
            gc::heap_contains(live.identity()),
            "reachable cell must survive collection"
        );
        drop(garbage);
    }
}
