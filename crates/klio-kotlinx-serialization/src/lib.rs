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

use klio_runtime::{CallCtx, RuntimeError, TypeShape, Value};

klio_stdlib::host_bindings! {
    pub fn host_bindings() {
        "kotlinx.serialization.__klsx_ctorParamNames" => ctor_param_names,
        "kotlinx.serialization.__klsx_get"            => prop_get,
        "kotlinx.serialization.__klsx_construct"      => construct,
        // JSON format: reflective encode (runtime-value driven) and
        // type-driven decode (guided by each ctor param's declared type).
        "kotlinx.serialization.json.__klsx_jsonEncode" => json_encode,
        "kotlinx.serialization.json.__klsx_jsonDecode" => json_decode,
    }
}

// ----- JSON encode (reflective over the runtime value) -----

#[allow(clippy::cast_possible_wrap, clippy::cast_lossless)]
fn value_to_json(v: &Value, ctx: &mut CallCtx) -> Result<serde_json::Value, RuntimeError> {
    use serde_json::Value as J;
    Ok(match v {
        Value::Null | Value::Unit => J::Null,
        Value::Bool(b) => J::Bool(*b),
        Value::Int(i) => J::Number((i64::from(*i)).into()),
        Value::Long(l) => J::Number((*l).into()),
        Value::Short(s) => J::Number((i64::from(*s)).into()),
        Value::Byte(b) => J::Number((i64::from(*b)).into()),
        Value::Double(d) => serde_json::Number::from_f64(*d).map_or(J::Null, J::Number),
        Value::Float(f) => serde_json::Number::from_f64(f64::from(*f)).map_or(J::Null, J::Number),
        Value::Char(c) => J::String(
            char::from_u32(u32::from(*c))
                .unwrap_or('\u{fffd}')
                .to_string(),
        ),
        Value::String(s) => J::String((**s).clone()),
        Value::Instance(inst) => {
            let cls = Arc::clone(&inst.borrow().class);
            if cls.is_enum {
                let nm = inst.borrow().get("name");
                match nm {
                    Some(Value::String(s)) => J::String((*s).clone()),
                    _ => J::String(cls.name.clone()),
                }
            } else {
                let names: Vec<String> = cls
                    .primary_params
                    .iter()
                    .filter(|p| p.property.is_some())
                    .map(|p| p.name.clone())
                    .collect();
                let mut map = serde_json::Map::new();
                for name in names {
                    let pv = read_prop(v, &name, ctx)?;
                    map.insert(name, value_to_json(&pv, ctx)?);
                }
                J::Object(map)
            }
        }
        Value::List { items, .. } | Value::Array { items, .. } | Value::Set { items, .. } => {
            let elems: Vec<Value> = items.borrow().clone();
            let mut arr = Vec::with_capacity(elems.len());
            for e in &elems {
                arr.push(value_to_json(e, ctx)?);
            }
            J::Array(arr)
        }
        Value::Map { entries, .. } => {
            let pairs: Vec<(Value, Value)> = entries.borrow().clone();
            let mut map = serde_json::Map::new();
            for (k, val) in &pairs {
                map.insert(map_key(k), value_to_json(val, ctx)?);
            }
            J::Object(map)
        }
        other => J::String(format!("{other:?}")),
    })
}

/// Read property `name` off `obj` (instance field first, then a getter).
fn read_prop(obj: &Value, name: &str, ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if let Value::Instance(inst) = obj
        && let Some(v) = inst.borrow().get(name)
    {
        return Ok(v);
    }
    let out: &mut dyn klio_runtime::Output = ctx.out;
    match ctx.host.invoke_method(obj, name, &[], out) {
        Some(Ok(v)) => Ok(v),
        Some(Err(e)) => Err(e),
        None => Ok(Value::Null),
    }
}

fn map_key(k: &Value) -> String {
    match k {
        Value::String(s) => (**s).clone(),
        Value::Int(i) => i.to_string(),
        Value::Long(l) => l.to_string(),
        Value::Bool(b) => b.to_string(),
        other => format!("{other:?}"),
    }
}

fn json_encode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let value = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Type("__klsx_jsonEncode: missing value".into()))?;
    let pretty = matches!(ctx.args.get(1), Some(Value::Bool(true)));
    let jv = value_to_json(&value, ctx)?;
    let s = if pretty {
        serde_json::to_string_pretty(&jv)
    } else {
        serde_json::to_string(&jv)
    }
    .map_err(|e| RuntimeError::Type(format!("json encode: {e}")))?;
    Ok(Value::String(Arc::new(s)))
}

// ----- JSON decode (driven by the target class's declared types) -----

fn is_primitive_ty(t: &str) -> bool {
    matches!(
        t,
        "Int" | "Long" | "Short" | "Byte" | "Double" | "Float" | "Boolean" | "Char" | "String"
    )
}

fn is_map_ty(t: &str) -> bool {
    matches!(
        t,
        "Map" | "MutableMap" | "HashMap" | "LinkedHashMap" | "MutableMap.MutableEntry"
    )
}

/// Resolve a declared simple type name to a user/runtime class value, if
/// it names one (and isn't a primitive).
fn resolve_class(t: &str, ctx: &mut CallCtx) -> Option<Value> {
    if is_primitive_ty(t) {
        return None;
    }
    let cls_val = ctx.host.lookup_global(t)?;
    class_of(&cls_val).map(|_| cls_val)
}

/// Decode a JSON value into a klio `Value`, guided by the declared type
/// `shape` (head name plus generic arguments and nullability). `shape ==
/// None` means the target type is unknown, in which case numbers/strings
/// decode to their natural klio kind and objects become a generic map.
#[allow(clippy::cast_possible_truncation)]
fn decode_field(
    j: &serde_json::Value,
    shape: Option<&TypeShape>,
    ctx: &mut CallCtx,
) -> Result<Value, RuntimeError> {
    use serde_json::Value as J;
    let ty = shape.map(|s| s.name.as_str());
    Ok(match j {
        J::Null => Value::Null,
        J::Bool(b) => Value::Bool(*b),
        J::Number(n) => match ty {
            Some("Long") => Value::Long(n.as_i64().unwrap_or(0)),
            Some("Int") => Value::Int(n.as_i64().unwrap_or(0) as i32),
            Some("Short") => Value::Short(n.as_i64().unwrap_or(0) as i16),
            Some("Byte") => Value::Byte(n.as_i64().unwrap_or(0) as i8),
            Some("Double") => Value::Double(n.as_f64().unwrap_or(0.0)),
            Some("Float") => Value::Float(n.as_f64().unwrap_or(0.0) as f32),
            _ => {
                if let Some(i) = n.as_i64() {
                    if i32::try_from(i).is_ok() {
                        Value::Int(i as i32)
                    } else {
                        Value::Long(i)
                    }
                } else {
                    Value::Double(n.as_f64().unwrap_or(0.0))
                }
            }
        },
        J::String(s) => {
            // An enum-typed field decodes the entry by name.
            if let Some(t) = ty
                && let Some(cls_val) = resolve_class(t, ctx)
                && let Some(cls) = class_of(&cls_val)
                && cls.is_enum
                && let Some(entry) = cls
                    .enum_entries
                    .borrow()
                    .iter()
                    .find(|(n, _)| n == s)
                    .map(|(_, v)| v.clone())
            {
                entry
            } else {
                Value::String(Arc::new(s.clone()))
            }
        }
        J::Array(arr) => {
            // The element type is the first generic argument of the
            // declared collection type (e.g. `List<Item>` → `Item`).
            let elem = shape.and_then(|s| s.args.first());
            let mut items = Vec::with_capacity(arr.len());
            for e in arr {
                items.push(decode_field(e, elem, ctx)?);
            }
            Value::List {
                items: klio_runtime::ObjRef::new(items),
                mutable: false,
                enum_class: None,
                backing: None,
            }
        }
        J::Object(map) => {
            if let Some(t) = ty
                && is_map_ty(t)
            {
                // A declared map: keys come straight from JSON object keys,
                // values decode by the map's second generic argument.
                let val_shape = shape.and_then(|s| s.args.get(1));
                let mut entries: Vec<(Value, Value)> = Vec::with_capacity(map.len());
                for (k, val) in map {
                    entries.push((
                        Value::String(Arc::new(k.clone())),
                        decode_field(val, val_shape, ctx)?,
                    ));
                }
                Value::Map {
                    entries: klio_runtime::ObjRef::new(entries),
                    mutable: false,
                }
            } else if let Some(t) = ty
                && let Some(cls_val) = resolve_class(t, ctx)
            {
                // A nested @Serializable class: construct it.
                decode_object(map, &cls_val, ctx)?
            } else {
                // Unknown target type: a generic string-keyed map.
                let mut entries: Vec<(Value, Value)> = Vec::with_capacity(map.len());
                for (k, val) in map {
                    entries.push((Value::String(Arc::new(k.clone())), decode_field(val, None, ctx)?));
                }
                Value::Map {
                    entries: klio_runtime::ObjRef::new(entries),
                    mutable: false,
                }
            }
        }
    })
}

/// Construct an instance of `cls_val` from a JSON object, decoding each
/// primary-constructor property by its declared type shape.
fn decode_object(
    map: &serde_json::Map<String, serde_json::Value>,
    cls_val: &Value,
    ctx: &mut CallCtx,
) -> Result<Value, RuntimeError> {
    let cls = class_of(cls_val)
        .ok_or_else(|| RuntimeError::Type("__klsx_jsonDecode: expected a class".into()))?;
    let params: Vec<(String, Option<TypeShape>)> = cls
        .primary_params
        .iter()
        .filter(|p| p.property.is_some())
        .map(|p| (p.name.clone(), p.declared_shape.clone()))
        .collect();
    let mut args: Vec<Value> = Vec::with_capacity(params.len());
    for (name, shape) in &params {
        let v = match map.get(name) {
            Some(jv) => decode_field(jv, shape.as_ref(), ctx)?,
            None => Value::Null,
        };
        args.push(v);
    }
    let out: &mut dyn klio_runtime::Output = ctx.out;
    ctx.host.invoke_callable(cls_val, &args, out)
}

fn json_decode(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type("__klsx_jsonDecode: first arg must be a String".into())),
    };
    let cls_val = ctx.args.get(1).cloned().unwrap_or(Value::Null);
    let j: serde_json::Value = serde_json::from_str(&s)
        .map_err(|e| RuntimeError::Type(format!("json decode: {e}")))?;
    if let serde_json::Value::Object(map) = &j
        && class_of(&cls_val).is_some_and(|c| !c.is_enum)
    {
        return decode_object(map, &cls_val, ctx);
    }
    let shape = class_of(&cls_val).map(|c| TypeShape {
        name: c.name.clone(),
        nullable: false,
        args: Vec::new(),
    });
    decode_field(&j, shape.as_ref(), ctx)
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
