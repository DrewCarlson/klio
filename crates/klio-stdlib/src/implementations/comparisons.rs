use super::*;

pub(crate) fn cmp_compare_values_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() < 3 {
        return Err(RuntimeError::Arity("compareValuesBy expects (a, b, selector, ...)".into()));
    }
    let a = ctx.args[0].clone();
    let b = ctx.args[1].clone();
    let selectors: Vec<Value> = ctx.args[2..].to_vec();
    let CallCtx { out, host, .. } = ctx;
    for sel in selectors {
        if !matches!(&sel, Value::Lambda { .. } | Value::IrClosure { .. }) {
            return Err(RuntimeError::Type(
                "compareValuesBy expects key-selector lambdas".into(),
            ));
        }
        let ka = host.invoke_callable(&sel, std::slice::from_ref(&a), *out)?;
        let kb = host.invoke_callable(&sel, std::slice::from_ref(&b), *out)?;
        let ord = match (matches!(ka, Value::Null), matches!(kb, Value::Null)) {
            (true, true) => std::cmp::Ordering::Equal,
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            (false, false) => compare_values(&ka, &kb)?,
        };
        if !matches!(ord, std::cmp::Ordering::Equal) {
            return Ok(Value::new_int(match ord {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Greater => 1,
                std::cmp::Ordering::Equal => 0,
            }));
        }
    }
    Ok(Value::new_int(0))
}

pub(crate) fn cmp_comparator_sam(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity("Comparator { … } expects a 2-arg comparison lambda".into()));
    }
    let lam = ctx.args[0].clone();
    if !matches!(&lam, Value::Lambda { .. } | Value::IrClosure { .. }) {
        return Err(RuntimeError::Type(
            "Comparator { … } expects a 2-arg comparison lambda".into(),
        ));
    }
    Ok(Value::Comparator {
        steps: Arc::new(vec![(lam, false)]),
        descending: false,
    })
}

pub(crate) fn cmp_compare_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut steps: Vec<(Value, bool)> = Vec::with_capacity(ctx.args.len());
    for a in ctx.args {
        steps.push((a.clone(), false));
    }
    Ok(Value::Comparator { steps: Arc::new(steps), descending: false })
}

pub(crate) fn cmp_compare_by_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut steps: Vec<(Value, bool)> = Vec::with_capacity(ctx.args.len());
    for a in ctx.args {
        steps.push((a.clone(), true));
    }
    Ok(Value::Comparator { steps: Arc::new(steps), descending: false })
}

pub(crate) fn cmp_compare_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("compareValues expects two arguments".into()));
    }
    let a = &ctx.args[0];
    let b = &ctx.args[1];
    let n: i32 = match (matches!(a, Value::Null), matches!(b, Value::Null)) {
        (true, true) => 0,
        (true, false) => -1,
        (false, true) => 1,
        (false, false) => match compare_values(a, b)? {
            std::cmp::Ordering::Less => -1,
            std::cmp::Ordering::Equal => 0,
            std::cmp::Ordering::Greater => 1,
        },
    };
    Ok(Value::new_int(n as i64))
}

// ============================================================
// Comparator factories
// ============================================================

pub(crate) fn comparator_natural_order(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Empty step chain — the interp's sort path treats an empty-step
    // Comparator as "compare items directly via the natural order".
    Ok(Value::Comparator { steps: Arc::new(Vec::new()), descending: false })
}

pub(crate) fn comparator_reverse_order(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Comparator { steps: Arc::new(Vec::new()), descending: true })
}

