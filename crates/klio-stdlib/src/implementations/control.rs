use super::{CallCtx, Value, RuntimeError, ObjRef, Arc};

pub(crate) fn builders_build_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildList expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::List {
        items: ObjRef::new(Vec::new()),
        mutable: true,
        enum_class: None,
        backing: None,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::List { items, .. } = buildable else { unreachable!() };
    Ok(Value::List { items, mutable: false, enum_class: None, backing: None })
}

pub(crate) fn builders_build_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildSet expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::List {
        items: ObjRef::new(Vec::new()),
        mutable: true,
        enum_class: None,
        backing: None,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::List { items, .. } = buildable else { unreachable!() };
    let mut deduped: Vec<Value> = Vec::new();
    for v in items.borrow().iter() {
        if !deduped.iter().any(|x| Value::structural_eq_boxed(x, v)) {
            deduped.push(v.clone());
        }
    }
    Ok(Value::Set { items: ObjRef::new(deduped), mutable: false, backing: None })
}

pub(crate) fn builders_build_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity("buildMap expects (block) or (capacity, block)".into()));
    }
    let block = ctx.args[ctx.args.len() - 1].clone();
    let buildable = Value::Map {
        entries: ObjRef::new(Vec::new()),
        mutable: true,
    };
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &buildable, *out)?;
    }
    let Value::Map { entries, .. } = buildable else { unreachable!() };
    Ok(Value::Map { entries, mutable: false })
}

pub(crate) fn builders_build_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity("buildString expects (block)".into()));
    }
    let block = ctx.args[0].clone();
    let sb = Value::StringBuilder(ObjRef::new(String::new()));
    {
        let CallCtx { out, host, .. } = ctx;
        host.invoke_callable_with_this(&block, &[], &sb, *out)?;
    }
    let Value::StringBuilder(s) = sb else { unreachable!() };
    Ok(Value::String(Arc::new(s.borrow().clone())))
}

pub(crate) fn contract_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx.args.first().cloned().unwrap_or(Value::Null);
    let msg = match v {
        Value::String(s) => (*s).clone(),
        other => format!("{other}"),
    };
    Err(RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlin.IllegalStateException".into()),
        message: Some(Arc::new(msg)),
        cause: None,
    }))
}

pub(crate) fn contract_todo(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let msg = match ctx.args.first().cloned() {
        Some(Value::String(s)) => format!("An operation is not implemented: {s}"),
        Some(other) => format!("An operation is not implemented: {other}"),
        None => "An operation is not implemented.".to_string(),
    };
    Err(RuntimeError::Thrown(Value::Exception {
        fqn: Arc::new("kotlin.NotImplementedError".into()),
        message: Some(Arc::new(msg)),
        cause: None,
    }))
}

