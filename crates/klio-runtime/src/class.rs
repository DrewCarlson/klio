use crate::{Env, ObjRef, Value};

use std::sync::{Arc, Mutex};

/// A declared Kotlin class as the interpreter sees it at runtime.
// The flags are independent class modifiers read individually across the crate.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug)]
pub struct ClassDef {
    pub name: String,
    pub fqn: String,
    /// Runtime-retained annotation class names applied to this
    /// declaration. Populated at class-registration time from the
    /// AST, filtered to spec §17 RUNTIME retention (the default).
    /// `KClass.annotations` / `KClass.findAnnotation` walk this
    /// list when reflection asks for them.
    pub annotation_names: Vec<String>,
    pub primary_params: Vec<ClassParamDef>,
    /// Member functions keyed by simple name.
    pub methods: Vec<MethodDef>,
    /// Body `val`/`var` properties (not primary-ctor properties). Each
    /// initializer expression runs against the instance scope during
    /// construction.
    pub body_properties: Vec<PropertyDef>,
    pub init_blocks: Vec<Arc<klio_ast::Block>>,
    /// For each entry in `init_blocks`, the index of `body_properties`
    /// it runs BEFORE — matching Kotlin's source-order rule that an
    /// `init { … }` block interleaves with body-property initializers
    /// in declaration order. Same length as `init_blocks`.
    pub init_block_property_positions: Vec<usize>,
    pub is_data: bool,
    /// `true` for a `value class` / `@JvmInline value class`. Like a
    /// data class, the compiler synthesises `equals`/`hashCode`/
    /// `toString` over the single backing property, so structural
    /// equality and display follow the data-class path.
    pub is_value: bool,
    pub is_object: bool,
    /// `true` for an `enum class`. The entry instances live on
    /// `enum_entries` of the same `ClassDef`.
    pub is_enum: bool,
    /// `true` when the declaration carried the `sealed` modifier.
    pub is_sealed: bool,
    /// Simple supertype names recorded from `class Foo : Bar(), Baz`. Used by
    /// runtime `is`-checks to walk a class's parent chain by name; no
    /// generics, no diamond resolution.
    pub supertype_names: Vec<String>,
    /// Resolved parent class for method-resolution chain walking. Single
    /// inheritance only — populated from the first non-interface supertype
    /// that resolves to a `Value::Class` at registration time.
    pub parent: ObjRef<Option<Arc<ClassDef>>>,
    /// Resolved interface supertypes (any number). Walked after `parent` for
    /// default-method lookup and `is`-check membership. Each entry is a
    /// `ClassDef` with `is_interface = true`.
    pub interfaces: ObjRef<Vec<Arc<ClassDef>>>,
    /// `true` for a class declared with the `interface` keyword.
    pub is_interface: bool,
    /// `true` for a `fun interface` (a SAM interface eligible for lambda
    /// conversion via the constructor-call form `Foo { … }`).
    pub is_fun_interface: bool,
    /// Constructor argument expressions for the parent class, captured at
    /// declaration time from `: Parent(args)`. Evaluated in the subclass's
    /// constructor env when an instance is built.
    pub parent_ctor_args: Vec<Arc<klio_ast::Expr>>,
    /// `true` when the declaration carried the `open` modifier.
    pub is_open: bool,
    /// `true` for an `abstract class`. Direct instantiation is rejected; the
    /// class may declare members whose method/property carries
    /// `is_abstract = true`.
    pub is_abstract: bool,
    /// `true` for an `inner class`. Instances built from one of these store
    /// an outer-instance reference on `InstanceData.outer`.
    pub is_inner: bool,
    /// `true` for the synthetic `ClassDef` built from an `object { … }`
    /// expression. Drives the `Foo$N@hash` form used by `toString`.
    pub is_anonymous: bool,
    /// Secondary constructors. The order is the source-declared order.
    pub secondary_ctors: Vec<Arc<klio_ast::SecondaryCtor>>,
    /// Eagerly-constructed enum entries in source order. Each value is a
    /// `Value::Instance` whose class is either this `ClassDef` or a
    /// synthetic per-entry subclass when the entry declared an override
    /// body. Populated after the enclosing `Arc<ClassDef>` exists so
    /// entries can carry a `Arc<ClassDef>` back-reference.
    pub enum_entries: ObjRef<Vec<(String, Value)>>,
    /// Companion object, if any. Stored as a class with `is_object: true`.
    /// Companion object instance. Interior mutability lets the
    /// interpreter defer construction until after the enclosing
    /// class is bound to the env, so `class Outer { companion {
    /// val X = Outer() } }` can resolve `Outer` during its
    /// companion's init. Construction sites set this once.
    pub companion: ObjRef<Option<ObjRef<InstanceData>>>,
    /// For a companion-object class (`is_object: true` built from a
    /// `companion object` declaration), this points back to the enclosing
    /// class. Lets the interpreter expose enum entries / `entries` inside
    /// the companion's own method bodies.
    pub enclosing_class: ObjRef<Option<Arc<ClassDef>>>,
    /// Nested classes by simple name (both plain nested and `inner` —
    /// `is_inner` lives on the nested class's own `ClassDef`).
    pub nested_classes: ObjRef<Vec<(String, Arc<ClassDef>)>>,
    /// Captured env in which the class was declared (for closure-like
    /// resolution in method bodies).
    pub captured_env: ObjRef<Env>,
    /// Inheritance-delegation table: for each delegated supertype entry,
    /// the supertype name and the expression that produces the delegate
    /// instance. Evaluated once during construction; the resulting value
    /// is stored on the instance under `$$delegate$<idx>`. Resolved by
    /// the interpreter to forward calls to abstract methods that are not
    /// overridden in this class.
    pub supertype_delegates: ObjRef<Vec<SupertypeDelegate>>,
    /// Synthesized forwarder methods built once the delegated interfaces
    /// are resolved (at parent-link time). Walked by `find_method_walk`
    /// after the class's own methods miss but before the parent chain.
    pub delegate_forwarders: ObjRef<Vec<MethodDef>>,
    /// Lazily-constructed singleton for `is_object` classes that are
    /// nested inside another classifier. Top-level objects materialize
    /// their singleton at file load and bind it in globals; nested
    /// objects (including ones inside sealed classes) need lazy
    /// construction the first time `Outer.NestedObj` is read.
    pub object_singleton: ObjRef<Option<ObjRef<InstanceData>>>,
}

#[derive(Debug, Clone)]
pub struct SupertypeDelegate {
    /// Simple name of the delegated interface (the type written before
    /// `by`). Used so the runtime can look up the interface's method
    /// table for forwarder synthesis.
    pub interface_name: String,
    /// Resolved interface class, if it resolves at registration time.
    pub interface: Option<Arc<ClassDef>>,
    /// Delegate expression — evaluated in the primary-ctor parameter
    /// scope at construction.
    pub expr: Arc<klio_ast::Expr>,
    /// Field key on the instance where the resolved delegate value lives.
    pub field_key: String,
}

#[derive(Debug, Clone)]
pub struct ClassParamDef {
    /// `Some(true)` for `var`, `Some(false)` for `val`, `None` if the param
    /// isn't a property.
    pub property: Option<bool>,
    pub name: String,
    pub default: Option<Arc<klio_ast::Expr>>,
    /// Declared type's simple name (e.g. `"Long"`). Used to normalize a
    /// bare integer-literal constructor argument to the field's declared
    /// primitive type, matching Kotlin's literal typing, so `C(n = 1)`
    /// with `n: Long` stores a `Long`, not an `Int`.
    pub declared_type: Option<String>,
    /// The full declared-type shape, including generic arguments and
    /// nullability (e.g. `List<Item>`, `Map<String, Item>`, `Item?`).
    /// `declared_type` keeps only the head name; reflective consumers
    /// (such as the JSON decoder) need the element/value types that the
    /// bare name discards.
    pub declared_shape: Option<TypeShape>,
}

/// A structural view of a declared type retained for reflection: the head
/// type name, whether it is nullable, and its generic arguments (each a
/// `TypeShape` in turn, so arbitrarily nested types like
/// `Map<String, List<Item>>` are fully represented). Star projections and
/// function types collapse to a name with no arguments.
#[derive(Debug, Clone)]
pub struct TypeShape {
    pub name: String,
    pub nullable: bool,
    pub args: Vec<TypeShape>,
}

impl TypeShape {
    /// Build a `TypeShape` from a parsed AST type reference, recursing into
    /// generic arguments and skipping star projections.
    #[must_use]
    pub fn from_type_ref(t: &klio_ast::TypeRef) -> Self {
        TypeShape {
            name: t.name.name.clone(),
            nullable: t.nullable,
            args: t
                .type_args
                .iter()
                .filter(|a| !a.is_star)
                .map(|a| TypeShape::from_type_ref(&a.ty))
                .collect(),
        }
    }
}

// The flags are independent member modifiers read individually across the crate.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone)]
pub struct MethodDef {
    pub name: String,
    pub decl: Arc<klio_ast::Function>,
    pub is_operator: bool,
    pub is_open: bool,
    pub is_override: bool,
    /// `true` when the source carried the `abstract` modifier on this
    /// member. Abstract methods may have `decl.body == None`.
    pub is_abstract: bool,
    /// When `Some`, calls to this method dispatch through the bundled
    /// lambda instead of executing `decl.body`. Populated when a lambda is
    /// SAM-converted to a `fun interface` instance — the synthesized
    /// subclass replaces the single abstract method with this binding.
    pub sam_lambda: Option<Value>,
    /// When `Some(field_key)`, this is a synthesized inheritance-delegation
    /// forwarder: calls to this method are routed to the stored delegate
    /// instance found under `field_key` on the receiver, dispatching the
    /// same method name on the delegate.
    pub delegate_field: Option<String>,
    /// IR `FuncId` of the lowered method body (with `this` as the
    /// implicit first param). Set by class registration when the
    /// method body has been lowered into the active IR module;
    /// `None` for abstract / SAM-replaced / delegate-forwarder
    /// methods that have no IR body of their own.
    pub ir_fn_id: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct PropertyDef {
    pub name: String,
    pub mutable: bool,
    pub init: Option<Arc<klio_ast::Expr>>,
    /// Custom getter body, if the source declared `get() = …` / `get() { … }`.
    pub getter: Option<Arc<klio_ast::Accessor>>,
    /// Custom setter body, if the source declared `set(value) { … }`.
    pub setter: Option<Arc<klio_ast::Accessor>>,
    /// `val foo by expr` — the delegate expression. Evaluated once at
    /// instance construction; its result is stored under
    /// `__delegate$<name>` in the instance field map and consulted on
    /// every read/write of the property.
    pub delegate: Option<Arc<klio_ast::Expr>>,
    /// `true` when the property was declared `abstract`. Such properties
    /// have no `init` and serve as a contract for subclasses.
    pub is_abstract: bool,
    /// `true` for a `lateinit var`. Reads before the first write throw
    /// `kotlin.UninitializedPropertyAccessException`.
    pub is_lateinit: bool,
    /// Declared non-nullable primitive type name (`Int`, `Long`, `Short`,
    /// `Byte`, `Float`, `Double`, `Boolean`, `Char`) for properties with
    /// no initializer. Lets construction supply the type's zero value
    /// instead of leaving the field `Null` — matters for `protected var
    /// modCount: Int` and similar declarations in `expect` classes.
    pub primitive_zero: Option<Value>,
}

#[derive(Debug)]
pub struct InstanceData {
    pub class: Arc<ClassDef>,
    /// Field name → value. Insertion ordered (Vec keeps order for `toString`
    /// on data classes).
    pub fields: Vec<(String, Value)>,
    /// For an `inner class` instance, the captured enclosing-class
    /// instance. Bare-name lookups inside an inner method fall through to
    /// this outer's fields, and `this@Outer` resolves to it.
    pub outer: Option<Value>,
    /// Per-instance identity, assigned at construction from a monotonic
    /// counter on the interpreter. Drives `Foo@<hex>` in the default
    /// `toString` for plain (non-data, non-enum, non-singleton) classes.
    pub identity: u64,
    /// Opaque per-instance state owned by a native host binding —
    /// kotlinx.io's `Buffer` stashes its byte queue here, for
    /// example. Lifecycle is tied to the instance: the state is
    /// dropped when the last `ObjRef<InstanceData>` clone is
    /// released, no side-map cleanup needed.
    pub native_state: Option<NativeState>,
}

/// Native-side data attached to a `Value::Instance`. The `kind`
/// discriminator is a free-form string (convention: the FQN of the
/// owning native binding, e.g. `"kotlinx.io.Buffer"`) that downcasts
/// surface as a panic-on-mismatch guard so two libraries don't
/// accidentally trample each other's storage on the same instance.
pub struct NativeState {
    pub kind: &'static str,
    pub data: Arc<Mutex<dyn std::any::Any + Send + Sync>>,
}

impl std::fmt::Debug for NativeState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "NativeState({})", self.kind)
    }
}

impl ClassDef {
    /// Walk the class chain (self, then parent, then grandparent, …) and
    /// return the first method matching `name`, paired with the class that
    /// declared it.
    #[must_use]
    pub fn find_method(self: &Arc<Self>, name: &str) -> Option<(MethodDef, Arc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_method_walk(self, name, &mut seen)
    }

    /// Like `find_method`, but among overloads with this name, prefers one
    /// whose first declared parameter type name matches `arg_type_name` —
    /// used by operator dispatch to pick `plus(Bag)` over `plus(Int)` when
    /// the argument is a `Bag`. Falls back to the unspecific lookup.
    #[must_use]
    pub fn find_method_for_arg(
        self: &Arc<Self>,
        name: &str,
        arg_type_name: Option<&str>,
    ) -> Option<(MethodDef, Arc<ClassDef>)> {
        if let Some(arg) = arg_type_name {
            let mut seen: Vec<*const ClassDef> = Vec::new();
            if let Some(found) = find_method_for_arg_walk(self, name, arg, &mut seen) {
                return Some(found);
            }
        }
        self.find_method(name)
    }

    /// Walk the class chain searching for a body property declaration of the
    /// given name. Returns the property and the class that declared it.
    #[must_use]
    pub fn find_body_property(
        self: &Arc<Self>,
        name: &str,
    ) -> Option<(PropertyDef, Arc<ClassDef>)> {
        let mut seen: Vec<*const ClassDef> = Vec::new();
        find_body_property_walk(self, name, &mut seen)
    }

    /// Returns the list of declared interface supertypes (resolved).
    #[must_use]
    pub fn interface_refs(&self) -> Vec<Arc<ClassDef>> {
        self.interfaces.borrow().clone()
    }

    /// Collect companions reachable from this class: self, parent chain, and
    /// transitive interfaces. Used to resolve bare-name references to
    /// companion-object members (`Counter.n` accessed as `n` inside a
    /// `Counter.inc()` default body that runs on a class implementing
    /// `Counter`).
    #[must_use]
    pub fn all_companions(self: &Arc<Self>) -> Vec<ObjRef<InstanceData>> {
        let mut out: Vec<ObjRef<InstanceData>> = Vec::new();
        let mut seen: Vec<*const ClassDef> = Vec::new();
        collect_companions_walk(self, &mut out, &mut seen);
        out
    }

    /// True when this class or any of its named supertypes matches `name`.
    /// Walks the chain by simple name through `captured_env`. Cycles are
    /// guarded against by bounding the walk to a small depth.
    #[must_use]
    pub fn is_subtype_of(&self, name: &str) -> bool {
        if self.name == name || self.fqn == name {
            return true;
        }
        let mut frontier: Vec<String> = self.supertype_names.clone();
        let mut seen: Vec<String> = vec![self.name.clone()];
        let mut steps = 0;
        while let Some(parent_name) = frontier.pop() {
            if steps > 64 {
                return false;
            }
            steps += 1;
            if parent_name == name {
                return true;
            }
            if seen.iter().any(|s| s == &parent_name) {
                continue;
            }
            seen.push(parent_name.clone());
            let Some(v) = self.captured_env.borrow().lookup(&parent_name) else {
                continue;
            };
            if let Value::Class(c) = v {
                if c.name == name || c.fqn == name {
                    return true;
                }
                for p in &c.supertype_names {
                    frontier.push(p.clone());
                }
            }
        }
        false
    }
}

fn collect_companions_walk(
    cls: &Arc<ClassDef>,
    out: &mut Vec<ObjRef<InstanceData>>,
    seen: &mut Vec<*const ClassDef>,
) {
    let ptr = Arc::as_ptr(cls);
    if seen.contains(&ptr) || seen.len() > 128 {
        return;
    }
    seen.push(ptr);
    if let Some(c) = cls.companion.borrow().as_ref() {
        out.push(c.clone());
    }
    if let Some(parent) = cls.parent.borrow().clone() {
        collect_companions_walk(&parent, out, seen);
    }
    for iface in cls.interfaces.borrow().iter() {
        collect_companions_walk(iface, out, seen);
    }
    // Spec §6.1: a companion-object decl scope is ULD to the companion
    // decl scope of the parent of its parent classifier. Walk the
    // enclosing class chain so members of a companion can read names
    // from the enclosing class's companion.
    if let Some(encl) = cls.enclosing_class.borrow().clone() {
        collect_companions_walk(&encl, out, seen);
    }
}

fn find_method_for_arg_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    arg_type_name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.contains(&ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    let arg_matches = |m: &MethodDef| -> bool {
        m.decl
            .params
            .first()
            .is_some_and(|p| p.ty.name.name == arg_type_name)
    };
    if let Some(m) = cls
        .methods
        .iter()
        .find(|m| m.name == name && m.decl.body.is_some() && arg_matches(m))
    {
        return Some((m.clone(), Arc::clone(cls)));
    }
    if let Some(parent) = cls.parent.borrow().clone()
        && let Some(found) = find_method_for_arg_walk(&parent, name, arg_type_name, seen)
    {
        return Some(found);
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_method_for_arg_walk(iface, name, arg_type_name, seen) {
            return Some(found);
        }
    }
    None
}

fn find_method_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(MethodDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.contains(&ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    if let Some(m) = cls.methods.iter().find(|m| {
        m.name == name
            && (m.decl.body.is_some() || m.sam_lambda.is_some() || m.delegate_field.is_some())
    }) {
        return Some((m.clone(), Arc::clone(cls)));
    }
    // Inheritance-delegation forwarders synthesized at parent-link
    // resolution time. Consulted before the parent chain so a delegated
    // member wins over a default body the same way an explicit override
    // would.
    if let Some(m) = cls
        .delegate_forwarders
        .borrow()
        .iter()
        .find(|m| m.name == name)
    {
        return Some((m.clone(), Arc::clone(cls)));
    }
    // Walk the parent chain (concrete superclass) before interfaces — a
    // concrete-method inherited from a parent class wins over an interface
    // default with the same signature.
    if let Some(parent) = cls.parent.borrow().clone()
        && let Some(found) = find_method_walk(&parent, name, seen)
    {
        return Some(found);
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_method_walk(iface, name, seen) {
            return Some(found);
        }
    }
    // Fall back to an abstract declaration on the class itself — only useful
    // for error reporting at call time.
    if let Some(m) = cls.methods.iter().find(|m| m.name == name) {
        return Some((m.clone(), Arc::clone(cls)));
    }
    None
}

fn find_body_property_walk(
    cls: &Arc<ClassDef>,
    name: &str,
    seen: &mut Vec<*const ClassDef>,
) -> Option<(PropertyDef, Arc<ClassDef>)> {
    let ptr = Arc::as_ptr(cls);
    if seen.contains(&ptr) || seen.len() > 128 {
        return None;
    }
    seen.push(ptr);
    if let Some(p) = cls.body_properties.iter().find(|p| p.name == name) {
        return Some((p.clone(), Arc::clone(cls)));
    }
    if let Some(parent) = cls.parent.borrow().clone()
        && let Some(found) = find_body_property_walk(&parent, name, seen)
    {
        return Some(found);
    }
    for iface in cls.interfaces.borrow().iter() {
        if let Some(found) = find_body_property_walk(iface, name, seen) {
            return Some(found);
        }
    }
    None
}

impl InstanceData {
    #[must_use]
    pub fn get(&self, name: &str) -> Option<Value> {
        self.fields
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.clone())
    }
    pub fn set(&mut self, name: &str, v: Value) -> bool {
        if let Some(slot) = self.fields.iter_mut().find(|(n, _)| n == name) {
            slot.1 = v;
            true
        } else {
            false
        }
    }
    pub fn define(&mut self, name: &str, v: Value) {
        if !self.set(name, v.clone()) {
            self.fields.push((name.to_string(), v));
        }
    }

    /// Fetch the instance's native-state cell, creating it via `init`
    /// on first access.
    ///
    /// # Panics
    ///
    /// Panics when the instance already carries native state under a
    /// different `kind`, which indicates two host bindings are
    /// fighting over the same instance.
    pub fn ensure_native_state<T: std::any::Any + Send + Sync>(
        &mut self,
        kind: &'static str,
        init: impl FnOnce() -> T,
    ) -> Arc<Mutex<dyn std::any::Any + Send + Sync>> {
        if let Some(ns) = &self.native_state {
            assert_eq!(
                ns.kind, kind,
                "native_state kind mismatch: instance carries `{}`, binding asked for `{}`",
                ns.kind, kind,
            );
            return Arc::clone(&ns.data);
        }
        let data: Arc<Mutex<dyn std::any::Any + Send + Sync>> = Arc::new(Mutex::new(init()));
        self.native_state = Some(NativeState {
            kind,
            data: Arc::clone(&data),
        });
        data
    }
}
