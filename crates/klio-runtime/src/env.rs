use crate::{ObjRef, Value, RuntimeError, IntrinsicHost, Scheduler, ToI64, Output, publish_value, publish_env};

use std::collections::HashMap;

#[derive(Debug, Default, Clone)]
pub struct Env {
    pub(crate) parent: Option<ObjRef<Env>>,
    pub(crate) vars: HashMap<String, Value>,
}

impl Env {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn with_parent(parent: ObjRef<Env>) -> Self {
        Self { parent: Some(parent), vars: HashMap::new() }
    }

    pub fn define(&mut self, name: impl Into<String>, value: Value) {
        self.vars.insert(name.into(), value);
    }

    /// Remove a binding from this scope (does not touch parent scopes).
    pub fn remove_local(&mut self, name: &str) {
        self.vars.remove(name);
    }

    #[must_use]
    pub fn lookup(&self, name: &str) -> Option<Value> {
        if let Some(v) = self.vars.get(name) {
            return Some(v.clone());
        }
        self.parent.as_ref()?.borrow().lookup(name)
    }

    /// Look up `name` in this scope only, skipping the parent chain. Used by
    /// the interpreter when applying spec §10.1 import renames: a renamed
    /// short name is shadowed if and only if it would have resolved through
    /// the implicit prelude (a parent scope).
    #[must_use]
    pub fn lookup_local(&self, name: &str) -> Option<Value> {
        self.vars.get(name).cloned()
    }

    /// True when this env is a child scope (has a parent). The base
    /// module-globals env has no parent; a layered capture scope does.
    #[must_use]
    pub fn has_parent(&self) -> bool {
        self.parent.is_some()
    }

    /// Resolve `name` ignoring any binding that lives in `stop_at` (compared
    /// by `Rc::ptr_eq`). Used by the interpreter to ask "would this lookup
    /// have come from the implicit prelude?" — pass the prelude env in
    /// `stop_at` and a non-prelude binding (locals, file-scope, …) is
    /// returned; a None means only the prelude could have answered it.
    #[must_use]
    pub fn lookup_excluding(
        &self,
        name: &str,
        stop_at: &ObjRef<Env>,
    ) -> Option<Value> {
        if let Some(v) = self.vars.get(name) {
            return Some(v.clone());
        }
        let parent = self.parent.as_ref()?;
        if ObjRef::ptr_eq(parent, stop_at) {
            return None;
        }
        parent.borrow().lookup_excluding(name, stop_at)
    }

    /// Collect every value bound under `name` walking from the innermost
    /// scope outwards. Returns them in inside-out order. Used to find
    /// enclosing-class `this` bindings when resolving a bare name inside
    /// a local class declared in another class's method body.
    #[must_use]
    pub fn lookup_all(&self, name: &str) -> Vec<Value> {
        let mut out = Vec::new();
        if let Some(v) = self.vars.get(name) {
            out.push(v.clone());
        }
        if let Some(p) = &self.parent {
            out.extend(p.borrow().lookup_all(name));
        }
        out
    }

    /// Look up `name` and return the scope depth (0 = innermost) where it
    /// was found, along with the value. Used to compare a name's lexical
    /// binding against an enclosing `this`-instance field — class fields
    /// only override a lexical binding when the binding is strictly deeper
    /// (closer to the call site) than that `this`.
    #[must_use]
    pub fn lookup_with_depth(&self, name: &str) -> Option<(Value, usize)> {
        if let Some(v) = self.vars.get(name) {
            return Some((v.clone(), 0));
        }
        self.parent
            .as_ref()?
            .borrow()
            .lookup_with_depth(name)
            .map(|(v, d)| (v, d + 1))
    }

    /// Like `lookup_all` but pairs each value with its scope depth.
    #[must_use]
    pub fn lookup_all_with_depth(&self, name: &str) -> Vec<(Value, usize)> {
        let mut out = Vec::new();
        if let Some(v) = self.vars.get(name) {
            out.push((v.clone(), 0));
        }
        if let Some(p) = &self.parent {
            for (v, d) in p.borrow().lookup_all_with_depth(name) {
                out.push((v, d + 1));
            }
        }
        out
    }

    pub fn assign(&mut self, name: &str, value: Value) -> Result<(), RuntimeError> {
        if let Some(slot) = self.vars.get_mut(name) {
            *slot = value;
            return Ok(());
        }
        match &self.parent {
            Some(p) => p.borrow_mut().assign(name, value),
            None => Err(RuntimeError::Unbound(name.to_string())),
        }
    }
}

impl Value {
    /// Address-stable identity for use as a `synchronized` monitor
    /// key. Reference types (instances, containers, cells, builders)
    /// return their backing cell's stable address so two handles to
    /// the same Kotlin object map to the same monitor. Value types
    /// have no identity and return `None` — the caller falls back to
    /// a single shared monitor for them (matching the JVM, where
    /// boxing makes such locks effectively global).
    #[must_use]
    pub fn lock_identity(&self) -> Option<usize> {
        match self {
            Value::Instance(i) => Some(i.identity()),
            Value::List { items, .. }
            | Value::Array { items, .. }
            | Value::Set { items, .. } => Some(items.identity()),
            Value::Map { entries, .. } => Some(entries.identity()),
            Value::Cell(c) => Some(c.identity()),
            Value::StringBuilder(s) => Some(s.identity()),
            _ => None,
        }
    }

    /// Publish every `ObjRef` reachable from this value so the whole
    /// graph is sound to observe from another OS thread. The soundness
    /// primitive a value graph must pass through before it can cross a
    /// thread boundary: `publish()` establishes the happens-before that
    /// `ObjRef`'s `unsafe impl Send/Sync` relies on.
    ///
    /// Cycle-safe. Kotlin object graphs, `Env` parent chains, `Cell`
    /// self-references, and `ClassDef` parent/enclosing links are all
    /// cyclic; recursion is guarded by a visited set keyed on each
    /// cell's address-stable [`ObjRef::identity`]. `publish()` itself
    /// is idempotent, so revisiting a cell is harmless — the visited
    /// check exists purely to guarantee termination.
    ///
    /// Over-approximates by design: when in doubt a reachable cell is
    /// published. It never under-publishes.
    pub fn publish_deep(&self) {
        let mut seen = std::collections::HashSet::new();
        publish_value(self, &mut seen);
    }
}

/// Publish every `ObjRef` reachable from an environment (its bound
/// values and the whole parent chain). Used to make the program's
/// globals sound to observe from a freshly spawned OS thread.
pub fn publish_env_deep(env: &ObjRef<Env>) {
    let mut seen = std::collections::HashSet::new();
    env.publish();
    seen.insert(env.identity());
    publish_env(&env.borrow(), &mut seen);
}
