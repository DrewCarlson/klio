//! Native bindings for `kotlinx-serialization-core`.
//!
//! kotlinx-serialization's compiler plugin synthesizes a `KSerializer`
//! for every `@Serializable` class. klio has no compiler plugin, so
//! the pack supplies a *reflective* replacement: `T.serializer()`
//! resolves (via an interpreter hook in klio-interp-ir) to a klioMain
//! `ReflectiveKSerializer`, whose `serialize` / `deserialize` walk the
//! target class's primary-constructor properties using these
//! reflection helpers:
//!
//! - `__klsx_ctorParamNames(kClass)` — ordered names of the
//!   primary-constructor `val`/`var` properties.
//! - `__klsx_get(obj, name)` — read a named property off an instance.
//! - `__klsx_construct(kClass, args)` — build an instance by calling
//!   the primary constructor with the (ordered) argument list.
//!
//! Everything else in serialization-core is pure Kotlin consumed
//! straight from the upstream submodule.

use std::sync::Arc;

use klio_runtime::{CallCtx, RuntimeError, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.serialization.__klsx_ctorParamNames" => ctor_param_names,
        "kotlinx.serialization.__klsx_get"            => prop_get,
        "kotlinx.serialization.__klsx_construct"      => construct,
    }
}

fn class_of(v: &Value) -> Option<Arc<klio_runtime::ClassDef>> {
    match v {
        Value::Class(c) => Some(Arc::clone(c)),
        Value::BoundInnerClass { class, .. } => Some(Arc::clone(class)),
        Value::Instance(inst) => Some(Arc::clone(&inst.borrow().class)),
        _ => None,
    }
}

/// Ordered names of the primary-constructor properties (`val`/`var`
/// params). Plugin-generated serializers serialize exactly these, in
/// declaration order.
fn ctor_param_names(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let cls = ctx
        .args
        .first()
        .and_then(class_of)
        .ok_or_else(|| RuntimeError::Type("__klsx_ctorParamNames: expected a class".into()))?;
    let items: Vec<Value> = cls
        .primary_params
        .iter()
        .filter(|p| p.property.is_some())
        .map(|p| Value::String(Arc::new(p.name.clone())))
        .collect();
    Ok(Value::List {
        items: klio_runtime::ObjRef::new(items),
        mutable: false,
        enum_class: None,
        backing: None,
    })
}

/// Read property `name` off instance `obj`. Routes through
/// `invoke_method` so a custom getter / data-class accessor still
/// applies; falls back to the raw field.
fn prop_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let obj = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Type("__klsx_get: missing receiver".into()))?;
    let name = match ctx.args.get(1) {
        Some(Value::String(s)) => s.as_str().to_string(),
        _ => return Err(RuntimeError::Type("__klsx_get: name must be String".into())),
    };
    if let Value::Instance(inst) = &obj
        && let Some(v) = inst.borrow().get(&name)
    {
        return Ok(v);
    }
    // Defer to a getter via the host (data-class / custom accessor).
    let out: &mut dyn klio_runtime::Output = ctx.out;
    match ctx.host.invoke_method(&obj, &name, &[], out) {
        Some(Ok(v)) => Ok(v),
        Some(Err(e)) => Err(e),
        None => Err(RuntimeError::Type(format!(
            "__klsx_get: `{name}` not found on instance"
        ))),
    }
}

/// Construct an instance of `kClass` by invoking its primary
/// constructor with the supplied (ordered) argument list.
fn construct(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let cls_val = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Type("__klsx_construct: expected a class".into()))?;
    let cls = class_of(&cls_val)
        .ok_or_else(|| RuntimeError::Type("__klsx_construct: expected a class".into()))?;
    let args: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Array { items, .. }) => items.borrow().clone(),
        Some(other) => vec![other.clone()],
        None => Vec::new(),
    };
    let class_value = Value::Class(cls);
    let out: &mut dyn klio_runtime::Output = ctx.out;
    ctx.host.invoke_callable(&class_value, &args, out)
}
