use super::{Arc, CallCtx, ObjRef, RuntimeError, Value, make_exception};

// ===== scope functions =====
//
// All scope functions dispatch the user's lambda via
// `ctx.host.invoke_callable`. The intrinsic doesn't see the lambda's
// body — the host wires that back into the interpreter's
// `invoke_callable_value` path.

pub(crate) fn iterable_items(v: &Value, what: &str) -> Result<Vec<Value>, RuntimeError> {
    match v {
        Value::List { items, .. } | Value::Set { items, .. } | Value::Array { items, .. } => {
            Ok(items.borrow().clone())
        }
        Value::Map { entries, .. } => Ok(entries
            .borrow()
            .iter()
            .map(|(k, v)| Value::MapEntry {
                key: Box::new(k.clone()),
                value: Box::new(v.clone()),
                backing: None,
            })
            .collect()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires an iterable receiver"
        ))),
    }
}

pub(crate) fn coll_iter_filter_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "filterNotNull")?;
    let result: Vec<Value> = items
        .into_iter()
        .filter(|v| !matches!(v, Value::Null))
        .collect();
    Ok(make_list(result, false))
}

// Kotlin Long.toDouble() loses precision past 2^53.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn coll_iter_sum_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "sumOf expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "sumOf")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut acc_int: Option<i64> = Some(0);
    let mut acc_dbl: Option<f64> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if r.is_integral() {
            let n = r.as_i64().unwrap();
            if let Some(a) = acc_int.as_mut() {
                *a = a.wrapping_add(n);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += n as f64;
            }
        } else if r.is_floating() {
            let d = r.as_f64().unwrap();
            if let Some(a) = acc_int.take() {
                acc_dbl = Some(a as f64 + d);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += d;
            }
        } else {
            return Err(RuntimeError::Type(format!(
                "sumOf selector must return Int or Double, got {r:?}"
            )));
        }
    }
    Ok(match acc_dbl {
        Some(d) => Value::Double(d),
        None => Value::new_int(acc_int.unwrap_or(0)),
    })
}

pub(crate) fn coll_iter_max_of_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "maxOfOrNull expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "maxOfOrNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        match &best {
            None => best = Some(r),
            Some(b) => {
                if compare_values(&r, b)? == std::cmp::Ordering::Greater {
                    best = Some(r);
                }
            }
        }
    }
    Ok(best.unwrap_or(Value::Null))
}

pub(crate) fn coll_iter_min_of_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "minOfOrNull expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "minOfOrNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        match &best {
            None => best = Some(r),
            Some(b) => {
                if compare_values(&r, b)? == std::cmp::Ordering::Less {
                    best = Some(r);
                }
            }
        }
    }
    Ok(best.unwrap_or(Value::Null))
}

pub(crate) fn coll_iter_distinct_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "distinctBy expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "distinctBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut keys: Vec<Value> = Vec::new();
    let mut result: Vec<Value> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if !keys.iter().any(|k| Value::structural_eq_boxed(k, &key)) {
            keys.push(key);
            result.push(v);
        }
    }
    Ok(make_list(result, false))
}

pub(crate) fn coll_iter_group_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "groupBy expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "groupBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut groups: Vec<(Value, Vec<Value>)> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = groups
            .iter_mut()
            .find(|(k, _)| Value::structural_eq_boxed(k, &key))
        {
            slot.1.push(v);
        } else {
            groups.push((key, vec![v]));
        }
    }
    let entries: Vec<(Value, Value)> = groups
        .into_iter()
        .map(|(k, vs)| (k, make_list(vs, false)))
        .collect();
    Ok(make_map(entries, false))
}

/// `Iterable.groupingBy(keySelector)` — klio represents the lazy
/// `Grouping<T, K>` as a synthetic instance carrying the source items and
/// the key selector. The `Grouping.*` terminals below consume it.
pub(crate) fn coll_iter_grouping_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "groupingBy expects (receiver, keySelector)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "groupingBy")?;
    let block = ctx.args[1].clone();
    let id = ctx.host.alloc_instance_id();
    Ok(ctx.host.new_synth_instance(
        "kotlin.collections.Grouping",
        id,
        vec![
            ("__grouping_src".to_string(), make_list(items, false)),
            ("__grouping_key".to_string(), block),
        ],
    ))
}

/// Extract the (source items, key selector) a `groupingBy` stashed in its
/// synthetic Grouping instance.
pub(crate) fn grouping_parts(v: &Value) -> Result<(Vec<Value>, Value), RuntimeError> {
    if let Value::Instance(inst) = v {
        let b = inst.borrow();
        if let (Some(Value::List { items, .. }), Some(key)) =
            (b.get("__grouping_src"), b.get("__grouping_key"))
        {
            return Ok((items.borrow().clone(), key));
        }
    }
    Err(RuntimeError::Type("expected a Grouping receiver".into()))
}

pub(crate) fn coll_grouping_each_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let CallCtx { out, host, .. } = ctx;
    let mut counts: Vec<(Value, i64)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = counts
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &k))
        {
            slot.1 += 1;
        } else {
            counts.push((k, 1));
        }
    }
    let entries: Vec<(Value, Value)> = counts
        .into_iter()
        .map(|(k, c)| (k, Value::new_int(c)))
        .collect();
    Ok(make_map(entries, false))
}

/// `Grouping.fold(initial) { acc, e -> ... }` and
/// `Grouping.fold(initialSelector, operation)`. The two-arg form's first
/// argument is the constant initial value; klio also accepts a callable
/// initial selector `(key, element) -> R`.
pub(crate) fn coll_grouping_fold(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let initial = ctx.args.get(1).cloned().unwrap_or(Value::Null);
    let op = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("fold expects (initial, operation)".into()))?;
    let CallCtx { out, host, .. } = ctx;
    // entry order follows first appearance of each key
    let mut acc: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        let pos = acc
            .iter()
            .position(|(kk, _)| Value::structural_eq_boxed(kk, &k));
        let cur = match pos {
            Some(p) => acc[p].1.clone(),
            None => {
                // initial may be a constant or a (key, element) selector
                if is_callable(&initial) {
                    host.invoke_callable(&initial, &[k.clone(), v.clone()], *out)?
                } else {
                    initial.clone()
                }
            }
        };
        let next = host.invoke_callable(&op, &[cur, v.clone()], *out)?;
        match pos {
            Some(p) => acc[p].1 = next,
            None => acc.push((k, next)),
        }
    }
    Ok(make_map(acc, false))
}

pub(crate) fn coll_grouping_reduce(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, key) = grouping_parts(&ctx.args[0])?;
    let op = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("reduce expects (operation)".into()))?;
    let CallCtx { out, host, .. } = ctx;
    let mut acc: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let k = host.invoke_callable(&key, std::slice::from_ref(&v), *out)?;
        match acc
            .iter()
            .position(|(kk, _)| Value::structural_eq_boxed(kk, &k))
        {
            Some(p) => {
                let cur = acc[p].1.clone();
                // reduce operation is (key, accumulator, element)
                acc[p].1 = host.invoke_callable(&op, &[k, cur, v], *out)?;
            }
            None => acc.push((k, v)),
        }
    }
    Ok(make_map(acc, false))
}

pub(crate) fn is_callable(v: &Value) -> bool {
    matches!(
        v,
        Value::Lambda { .. }
            | Value::IrClosure { .. }
            | Value::Function { .. }
            | Value::Intrinsic { .. }
            | Value::Instance(_)
    )
}

pub(crate) fn coll_iter_associate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "associate expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "associate")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        let Value::Pair(k, val) = r else {
            return Err(RuntimeError::Type(
                "associate selector must return Pair".into(),
            ));
        };
        let key = *k;
        if let Some(slot) = entries
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &key))
        {
            slot.1 = *val;
        } else {
            entries.push((key, *val));
        }
    }
    Ok(make_map(entries, false))
}

pub(crate) fn coll_iter_associate_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "associateBy expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "associateBy")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = entries
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &key))
        {
            slot.1 = v;
        } else {
            entries.push((key, v));
        }
    }
    Ok(make_map(entries, false))
}

pub(crate) fn coll_iter_associate_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "associateWith expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "associateWith")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let val = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if let Some(slot) = entries
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &v))
        {
            slot.1 = val;
        } else {
            entries.push((v, val));
        }
    }
    Ok(make_map(entries, false))
}

pub(crate) fn coll_iter_sorted_by_impl(
    ctx: &mut CallCtx,
    descending: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!(
            "{what} expects (receiver, block)"
        )));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
    for v in items {
        let key = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        keyed.push((key, v));
    }
    let mut err: Option<RuntimeError> = None;
    keyed.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(&a.0, &b.0) {
            Ok(o) => {
                if descending {
                    o.reverse()
                } else {
                    o
                }
            }
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(
        keyed.into_iter().map(|(_, v)| v).collect(),
        false,
    ))
}

pub(crate) fn coll_iter_sorted_by(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_sorted_by_impl(ctx, false, "sortedBy")
}

pub(crate) fn coll_iter_max_min_by_impl(
    ctx: &mut CallCtx,
    descending: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!(
            "{what} expects (receiver, block)"
        )));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best_key = host.invoke_callable(&block, std::slice::from_ref(&items[0]), *out)?;
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        let key = host.invoke_callable(&block, std::slice::from_ref(v), *out)?;
        let ord = compare_values(&key, &best_key)?;
        let take = if descending {
            ord == std::cmp::Ordering::Less
        } else {
            ord == std::cmp::Ordering::Greater
        };
        if take {
            best_key = key;
            best = v.clone();
        }
    }
    Ok(best)
}

pub(crate) fn coll_iter_max_by_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_max_min_by_impl(ctx, false, "maxByOrNull")
}

pub(crate) fn coll_iter_min_by_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_max_min_by_impl(ctx, true, "minByOrNull")
}

pub(crate) fn coll_mut_list_sort(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.sort")?;
    let mut copy: Vec<Value> = it.borrow().clone();
    let mut err: Option<RuntimeError> = None;
    copy.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(a, b) {
            Ok(o) => o,
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    *it.borrow_mut() = copy;
    Ok(Value::Unit)
}

/// `MutableList.reverse()` — reverse the list in place, returns `Unit`.
/// Upstream `Array<T>.reversed()` / `IntArray.sortedDescending()` build
/// on this via `toMutableList().reverse()`, so without it those return
/// elements in their original order.
pub(crate) fn coll_mut_list_reverse(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.reverse")?;
    it.borrow_mut().reverse();
    Ok(Value::Unit)
}

/// Dispatch `comparator.compare(a, b)` for a non-intrinsic Comparator
/// value (an interpreted object / SAM). Returns the `Int` result as an
/// `i64`. Used by the sorting intrinsics so an interpreted Comparator
/// (from commonMain sources or user code) works alongside klio's
/// `Value::Comparator`.
pub(crate) fn invoke_comparator_compare(
    host: &mut dyn klio_runtime::IntrinsicHost,
    comparator: &Value,
    a: &Value,
    b: &Value,
    out: &mut dyn klio_runtime::Output,
) -> Result<i64, RuntimeError> {
    let args = [a.clone(), b.clone()];
    let r = match host.invoke_method(comparator, "compare", &args, out) {
        Some(r) => r?,
        // A bare callable (lambda-as-Comparator, `Comparator(::cmp)`)
        // compares by direct invocation.
        None => host.invoke_callable(comparator, &args, out)?,
    };
    r.as_i64()
        .ok_or_else(|| RuntimeError::Type("Comparator.compare must return Int".into()))
}

pub(crate) fn coll_iter_sorted_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "sortedWith expects (receiver, comparator)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "sortedWith")?;
    let comparator = ctx.args[1].clone();
    let Value::Comparator { steps, descending } = comparator else {
        // Not klio's intrinsic Comparator value — treat the argument as
        // any object implementing `compare(a, b): Int` (an interpreted
        // stdlib / user Comparator, e.g. one returned by the commonMain
        // `Comparator { ... }` SAM or `compareBy` when those bodies run
        // from source). Sort by dispatching `compare` through the host.
        let mut items: Vec<Value> = items;
        let CallCtx { out, host, .. } = ctx;
        let mut err: Option<RuntimeError> = None;
        for i in 1..items.len() {
            let mut j = i;
            while j > 0 && err.is_none() {
                let a = items[j - 1].clone();
                let b = items[j].clone();
                let ord = match invoke_comparator_compare(*host, &comparator, &a, &b, *out) {
                    Ok(o) => o,
                    Err(e) => {
                        err = Some(e);
                        break;
                    }
                };
                if ord > 0 {
                    items.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
        if let Some(e) = err {
            return Err(e);
        }
        return Ok(make_list(items, false));
    };
    let CallCtx { out, host, .. } = ctx;
    let mut items: Vec<Value> = items;
    let mut err: Option<RuntimeError> = None;
    // Empty step list — Comparator.naturalOrder() / reverseOrder():
    // sort items directly using value-level comparison.
    if steps.is_empty() {
        items.sort_by(|a, b| {
            if err.is_some() {
                return std::cmp::Ordering::Equal;
            }
            match compare_values(a, b) {
                Ok(o) => {
                    if descending {
                        o.reverse()
                    } else {
                        o
                    }
                }
                Err(e) => {
                    err = Some(e);
                    std::cmp::Ordering::Equal
                }
            }
        });
    } else {
        // Insertion sort so callbacks can invoke through host.
        for i in 1..items.len() {
            let mut j = i;
            while j > 0 && err.is_none() {
                let mut ord = std::cmp::Ordering::Equal;
                for (sel, step_desc) in steps.iter() {
                    let lhs_arg = items[j - 1].clone();
                    let rhs_arg = items[j].clone();
                    let ka = match host.invoke_callable(sel, std::slice::from_ref(&lhs_arg), *out) {
                        Ok(v) => v,
                        Err(e) => {
                            err = Some(e);
                            break;
                        }
                    };
                    let kb = match host.invoke_callable(sel, std::slice::from_ref(&rhs_arg), *out) {
                        Ok(v) => v,
                        Err(e) => {
                            err = Some(e);
                            break;
                        }
                    };
                    let o = match compare_values(&ka, &kb) {
                        Ok(o) => o,
                        Err(e) => {
                            err = Some(e);
                            break;
                        }
                    };
                    let flipped = if *step_desc { o.reverse() } else { o };
                    if flipped != std::cmp::Ordering::Equal {
                        ord = flipped;
                        break;
                    }
                }
                if descending {
                    ord = ord.reverse();
                }
                if matches!(ord, std::cmp::Ordering::Greater) {
                    items.swap(j - 1, j);
                    j -= 1;
                } else {
                    break;
                }
            }
        }
    }
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(items, false))
}

pub(crate) fn coll_iter_sorted_by_desc(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_sorted_by_impl(ctx, true, "sortedByDescending")
}

pub(crate) fn coll_iter_extreme(
    ctx: &mut CallCtx,
    want_max: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!(
            "{what} expects (receiver, block)"
        )));
    }
    let items = iterable_items(&ctx.args[0], what)?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut best: Option<Value> = None;
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        best = Some(match best {
            None => r,
            Some(a) => {
                let ord = compare_values(&a, &r)?;
                match (want_max, ord) {
                    (true, std::cmp::Ordering::Less) | (false, std::cmp::Ordering::Greater) => r,
                    _ => a,
                }
            }
        });
    }
    best.ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("Collection is empty.".into())),
            cause: None,
        })
    })
}

pub(crate) fn coll_iter_max_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_extreme(ctx, true, "maxOf")
}

pub(crate) fn coll_iter_min_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_iter_extreme(ctx, false, "minOf")
}

pub(crate) fn coll_iter_on_each(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "onEach expects (receiver, block)".into(),
        ));
    }
    let recv = ctx.args[0].clone();
    let items = iterable_items(&recv, "onEach")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items {
        host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
    }
    Ok(recv)
}

pub(crate) fn coll_iter_map_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(
            "mapNotNull expects (receiver, block)".into(),
        ));
    }
    let items = iterable_items(&ctx.args[0], "mapNotNull")?;
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result = Vec::new();
    for v in items {
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        if !matches!(r, Value::Null) {
            result.push(r);
        }
    }
    Ok(make_list(result, false))
}

pub(crate) fn map_entries_clone(
    v: &Value,
    what: &str,
) -> Result<Vec<(Value, Value)>, RuntimeError> {
    match v {
        Value::Map { entries, .. } => Ok(entries.borrow().clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a Map receiver"
        ))),
    }
}

pub(crate) fn map_get_or_else(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity(
            "getOrElse expects (receiver, key, block)".into(),
        ));
    }
    let entries = map_entries_clone(&ctx.args[0], "getOrElse")?;
    let key = ctx.args[1].clone();
    if let Some((_, v)) = entries
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, &key))
    {
        return Ok(v.clone());
    }
    let block = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable(&block, &[], *out)
}

pub(crate) fn map_get_or_put(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 3 {
        return Err(RuntimeError::Arity(
            "getOrPut expects (receiver, key, block)".into(),
        ));
    }
    let recv = ctx.args[0].clone();
    let Value::Map { entries, .. } = &recv else {
        return Err(RuntimeError::Type(
            "getOrPut requires a MutableMap receiver".into(),
        ));
    };
    let entries_rc = entries.clone();
    let key = ctx.args[1].clone();
    if let Some((_, v)) = entries_rc
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, &key))
    {
        return Ok(v.clone());
    }
    let block = ctx.args[2].clone();
    let CallCtx { out, host, .. } = ctx;
    let new_v = host.invoke_callable(&block, &[], *out)?;
    entries_rc.borrow_mut().push((key, new_v.clone()));
    Ok(new_v)
}

/// `Array<T>.isEmpty()` / `isNotEmpty()` (and the primitive-array
/// variants) — `size == 0`. Stdlib extensions, not member fns.
pub(crate) fn array_len(recv: &Value) -> Option<usize> {
    match recv {
        Value::Array { items, .. } | Value::List { items, .. } => Some(items.borrow().len()),
        _ => None,
    }
}
pub(crate) fn array_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = ctx
        .args
        .first()
        .and_then(array_len)
        .ok_or_else(|| RuntimeError::Type("isEmpty requires an array".into()))?;
    Ok(Value::Bool(r == 0))
}
pub(crate) fn array_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = ctx
        .args
        .first()
        .and_then(array_len)
        .ok_or_else(|| RuntimeError::Type("isNotEmpty requires an array".into()))?;
    Ok(Value::Bool(r != 0))
}

pub(crate) fn array_size_arg(v: &Value, what: &str) -> Result<i64, RuntimeError> {
    let n = v
        .as_i64()
        .ok_or_else(|| RuntimeError::Type(format!("{what} expects an Int size")))?;
    if n < 0 {
        return Err(RuntimeError::Type(format!(
            "{what}: negative array size {n}"
        )));
    }
    Ok(n)
}

// array size validated >= 0 by array_size_arg; the index fits an Int per Kotlin.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn array_ctor_impl(
    ctx: &mut CallCtx,
    name: &str,
    prim: Option<klio_runtime::PrimitiveArrayKind>,
    default: &Value,
) -> Result<Value, RuntimeError> {
    if ctx.args.is_empty() || ctx.args.len() > 2 {
        return Err(RuntimeError::Arity(format!(
            "{name} expects (size) or (size, init)"
        )));
    }
    let n = array_size_arg(&ctx.args[0], name)?;
    if ctx.args.len() == 1 {
        let items: Vec<Value> = (0..n).map(|_| default.clone()).collect();
        return Ok(Value::Array {
            items: ObjRef::new(items),
            prim,
        });
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut items = Vec::with_capacity(n as usize);
    for i in 0..n {
        let v = host.invoke_callable(&block, &[Value::Int(i as i32)], *out)?;
        items.push(v);
    }
    Ok(Value::Array {
        items: ObjRef::new(items),
        prim,
    })
}

pub(crate) fn array_ctor_generic(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(ctx, "Array", None, &Value::Null)
}
pub(crate) fn array_ctor_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "IntArray",
        Some(klio_runtime::PrimitiveArrayKind::Int),
        &Value::Int(0),
    )
}
pub(crate) fn array_ctor_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "LongArray",
        Some(klio_runtime::PrimitiveArrayKind::Long),
        &Value::Long(0),
    )
}
pub(crate) fn array_ctor_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "DoubleArray",
        Some(klio_runtime::PrimitiveArrayKind::Double),
        &Value::Double(0.0),
    )
}
pub(crate) fn array_ctor_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "FloatArray",
        Some(klio_runtime::PrimitiveArrayKind::Float),
        &Value::Float(0.0),
    )
}
pub(crate) fn array_ctor_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "ShortArray",
        Some(klio_runtime::PrimitiveArrayKind::Short),
        &Value::Short(0),
    )
}
pub(crate) fn array_ctor_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "ByteArray",
        Some(klio_runtime::PrimitiveArrayKind::Byte),
        &Value::Byte(0),
    )
}
pub(crate) fn array_ctor_boolean(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "BooleanArray",
        Some(klio_runtime::PrimitiveArrayKind::Boolean),
        &Value::Bool(false),
    )
}
pub(crate) fn array_ctor_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_ctor_impl(
        ctx,
        "CharArray",
        Some(klio_runtime::PrimitiveArrayKind::Char),
        &Value::Char(0u16),
    )
}

// ============================================================
// Collections
// ============================================================

pub(crate) fn make_list(items: Vec<Value>, mutable: bool) -> Value {
    Value::List {
        items: ObjRef::new(items),
        mutable,
        enum_class: None,
        backing: None,
    }
}

pub(crate) fn make_set(items: Vec<Value>, mutable: bool) -> Value {
    let mut deduped: Vec<Value> = Vec::with_capacity(items.len());
    for v in items {
        if !deduped.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
            deduped.push(v);
        }
    }
    Value::Set {
        items: ObjRef::new(deduped),
        mutable,
        backing: None,
    }
}

pub(crate) fn make_map(entries: Vec<(Value, Value)>, mutable: bool) -> Value {
    // Deduplicate keys, last write wins (matches `mapOf("a" to 1, "a" to 2)`).
    let mut out: Vec<(Value, Value)> = Vec::with_capacity(entries.len());
    for (k, v) in entries {
        if let Some(slot) = out
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &k))
        {
            slot.1 = v;
        } else {
            out.push((k, v));
        }
    }
    Value::Map {
        entries: ObjRef::new(out),
        mutable,
    }
}

pub(crate) fn pair_args(ctx: &CallCtx<'_>) -> Result<(Value, Value), RuntimeError> {
    match ctx.args {
        [a, b] => Ok((a.clone(), b.clone())),
        _ => Err(RuntimeError::Arity("Pair expects 2 arguments".into())),
    }
}

pub(crate) fn coll_pair_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_args(ctx)?;
    Ok(Value::Pair(Box::new(a), Box::new(b)))
}

pub(crate) fn coll_to_infix(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_pair_ctor(ctx)
}

// Intrinsic dispatch table requires the uniform Result signature.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_list_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(ctx.args.to_vec(), false))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_list_of_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = ctx
        .args
        .iter()
        .filter(|v| !matches!(v, Value::Null))
        .cloned()
        .collect();
    Ok(make_list(items, false))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: None,
    })
}
pub(crate) fn coll_array_of_nulls(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Two shapes resolve to this intrinsic:
    //   public  fun <reified T> arrayOfNulls(size: Int): Array<T?>
    //   internal fun <T> arrayOfNulls(reference: Array<T>, size: Int): Array<T>
    // The 2-arg internal form (used by toTypedArray / ArrayDeque) passes
    // an existing array as the reified-type carrier; only the trailing
    // `size` matters here, so build `size` nulls regardless of shape.
    if ctx.args.len() == 2 && matches!(ctx.args.first(), Some(Value::Array { .. })) {
        let n = array_size_arg(&ctx.args[1], "arrayOfNulls")?;
        let items: Vec<Value> = (0..n).map(|_| Value::Null).collect();
        return Ok(Value::Array {
            items: ObjRef::new(items),
            prim: None,
        });
    }
    array_ctor_impl(ctx, "arrayOfNulls", None, &Value::Null)
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_empty_array(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(Vec::new()),
        prim: None,
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_int_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Int),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_long_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Long),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_short_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Short),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_byte_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Byte),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_double_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Double),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_float_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Float),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_bool_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Boolean),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_char_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::Char),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_uint_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UInt),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_ulong_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::ULong),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_ushort_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UShort),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_ubyte_array_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Array {
        items: ObjRef::new(ctx.args.to_vec()),
        prim: Some(klio_runtime::PrimitiveArrayKind::UByte),
    })
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_mutable_list_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(ctx.args.to_vec(), true))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_empty_list(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(Vec::new(), false))
}

#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(ctx.args.to_vec(), false))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_mutable_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(ctx.args.to_vec(), true))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_empty_set(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_set(Vec::new(), false))
}

pub(crate) fn coll_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, v) = v else {
            return Err(RuntimeError::Type(
                "mapOf expects Pair arguments (use `key to value` or `Pair(k, v)`)".into(),
            ));
        };
        entries.push(((**k).clone(), (**v).clone()));
    }
    Ok(make_map(entries, false))
}
pub(crate) fn coll_mutable_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, v) = v else {
            return Err(RuntimeError::Type(
                "mutableMapOf expects Pair arguments".into(),
            ));
        };
        entries.push(((**k).clone(), (**v).clone()));
    }
    Ok(make_map(entries, true))
}
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_empty_map(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_map(Vec::new(), false))
}

pub(crate) fn coll_to_typed_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type("toTypedArray requires a receiver".into()))?,
        "toTypedArray",
    )?;
    Ok(Value::Array {
        items: ObjRef::new(items),
        prim: None,
    })
}

#[allow(clippy::unnecessary_wraps)]
pub(crate) fn coll_set_of_not_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = ctx
        .args
        .iter()
        .filter(|v| !matches!(v, Value::Null))
        .cloned()
        .collect();
    Ok(make_set(items, false))
}

/// `sortedSetOf(vararg elements)` — a (mutable) set with keys in natural order.
pub(crate) fn coll_sorted_set_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut items = ctx.args.to_vec();
    let mut err: Option<RuntimeError> = None;
    items.sort_by(|a, b| match compare_values(a, b) {
        Ok(o) => o,
        Err(e) => {
            err = Some(e);
            std::cmp::Ordering::Equal
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_set(items, true))
}

/// `sortedMapOf(vararg pairs)` — a (mutable) map with entries in natural key order.
pub(crate) fn coll_sorted_map_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut entries: Vec<(Value, Value)> = Vec::with_capacity(ctx.args.len());
    for v in ctx.args {
        let Value::Pair(k, val) = v else {
            return Err(RuntimeError::Type(
                "sortedMapOf expects Pair arguments".into(),
            ));
        };
        entries.push(((**k).clone(), (**val).clone()));
    }
    let mut err: Option<RuntimeError> = None;
    entries.sort_by(|a, b| match compare_values(&a.0, &b.0) {
        Ok(o) => o,
        Err(e) => {
            err = Some(e);
            std::cmp::Ordering::Equal
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_map(entries, true))
}

/// `ArrayList()` / `ArrayList(initialCapacity)` — same storage as our
/// `MutableList`; the capacity arg is accepted and ignored.
pub(crate) fn coll_array_list_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] => Ok(make_list(Vec::new(), true)),
        [Value::Int(_n)] => Ok(make_list(Vec::new(), true)),
        [other] => {
            // ArrayList(Collection) shape — copy items.
            match other {
                Value::List { items, .. } | Value::Set { items, .. } => {
                    Ok(make_list(items.borrow().clone(), true))
                }
                _ => Err(RuntimeError::Type(
                    "ArrayList expects no args, an Int capacity, or a Collection".into(),
                )),
            }
        }
        _ => Err(RuntimeError::Arity("ArrayList expects 0 or 1 args".into())),
    }
}

pub(crate) fn coll_hash_map_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] | [Value::Int(_)] => Ok(make_map(Vec::new(), true)),
        [Value::Map { entries, .. }] => Ok(make_map(entries.borrow().clone(), true)),
        _ => Err(RuntimeError::Type(
            "HashMap expects no args, an Int capacity, or a Map".into(),
        )),
    }
}

pub(crate) fn coll_hash_set_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [] | [Value::Int(_)] => Ok(make_set(Vec::new(), true)),
        [Value::List { items, .. } | Value::Set { items, .. }] => {
            Ok(make_set(items.borrow().clone(), true))
        }
        _ => Err(RuntimeError::Type(
            "HashSet expects no args, an Int capacity, or a Collection".into(),
        )),
    }
}

// ----- List / MutableList helpers -----

pub(crate) fn recv_list_items(
    args: &[Value],
    what: &str,
) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    match args.first() {
        Some(Value::List { items, .. }) => Ok(items.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a List receiver"
        ))),
    }
}

pub(crate) fn coll_list_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.size")?;
    Ok(Value::new_int(it.borrow().len()))
}
pub(crate) fn coll_list_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.isEmpty")?;
    Ok(Value::Bool(it.borrow().is_empty()))
}
pub(crate) fn coll_list_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.isNotEmpty")?;
    Ok(Value::Bool(!it.borrow().is_empty()))
}
// Index is bounds-checked >= 0 before the usize cast.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn coll_list_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.get")?;
    let Some(Value::Int(idx)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("List.get requires an Int index".into()));
    };
    let borrow = it.borrow();
    let i = *idx;
    if i < 0 || (i as usize) >= borrow.len() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
                "Index {i} out of bounds for length {}",
                borrow.len()
            ))),
            cause: None,
        }));
    }
    Ok(borrow[i as usize].clone())
}
pub(crate) fn coll_list_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.contains")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("contains requires an argument".into()));
    };
    Ok(Value::Bool(
        it.borrow()
            .iter()
            .any(|v| Value::structural_eq_boxed(v, needle)),
    ))
}
// A collection index fits in i64; Kotlin indexOf returns Int/-1.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_list_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.indexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("indexOf requires an argument".into()));
    };
    let pos = it
        .borrow()
        .iter()
        .position(|v| Value::structural_eq_boxed(v, needle));
    Ok(Value::new_int(pos.map_or(-1, |p| p as i64)))
}
// A collection index fits in i64; Kotlin indexOfFirst returns Int/-1.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_iter_index_of_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "indexOfFirst")?;
    let block = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("indexOfFirst requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    for (i, v) in items.iter().enumerate() {
        if matches!(
            host.invoke_callable(&block, std::slice::from_ref(v), *out)?,
            Value::Bool(true)
        ) {
            return Ok(Value::new_int(i as i64));
        }
    }
    Ok(Value::new_int(-1))
}
// A collection index fits in i64; Kotlin indexOfLast returns Int/-1.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_iter_index_of_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "indexOfLast")?;
    let block = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("indexOfLast requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    let mut found: i64 = -1;
    for (i, v) in items.iter().enumerate() {
        if matches!(
            host.invoke_callable(&block, std::slice::from_ref(v), *out)?,
            Value::Bool(true)
        ) {
            found = i as i64;
        }
    }
    Ok(Value::new_int(found))
}
/// `foldRight(initial) { elem, acc -> … }` — fold from the end. Upstream uses
/// a backward `ListIterator` (hasPrevious) klio doesn't model, so iterate in
/// reverse directly.
pub(crate) fn coll_list_fold_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "foldRight")?;
    let mut acc = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("foldRight requires an initial value".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("foldRight requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().rev() {
        acc = host.invoke_callable(&block, &[v.clone(), acc.clone()], *out)?;
    }
    Ok(acc)
}

/// `reduceRight { elem, acc -> … }` — reduce from the end; throws on empty.
/// `or_null` true for reduceRightOrNull (returns null on empty).
pub(crate) fn reduce_right_impl(ctx: &mut CallCtx, or_null: bool) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "reduceRight")?;
    let block = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("reduceRight requires a block".into()))?;
    if items.is_empty() {
        return if or_null {
            Ok(Value::Null)
        } else {
            Err(RuntimeError::Thrown(make_exception(
                "kotlin.UnsupportedOperationException",
                Some("Empty collection can't be reduced.".into()),
            )))
        };
    }
    let CallCtx { out, host, .. } = ctx;
    let mut acc = items[items.len() - 1].clone();
    for i in (0..items.len() - 1).rev() {
        acc = host.invoke_callable(&block, &[items[i].clone(), acc.clone()], *out)?;
    }
    Ok(acc)
}

pub(crate) fn coll_list_reduce_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    reduce_right_impl(ctx, false)
}

pub(crate) fn coll_list_reduce_right_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    reduce_right_impl(ctx, true)
}

/// `last()` / `last { predicate }` / `lastOrNull { predicate }` /
/// `findLast { predicate }`. With no block, returns the last element (throwing
/// on empty for `last`). With a block, scans in reverse for the last match.
/// `or_null` controls the empty/no-match behavior.
pub(crate) fn coll_list_last_impl(ctx: &mut CallCtx, or_null: bool) -> Result<Value, RuntimeError> {
    let items = iterable_items(&ctx.args[0], "last")?;
    if ctx.args.len() >= 2 {
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        for v in items.iter().rev() {
            if matches!(
                host.invoke_callable(&block, std::slice::from_ref(v), *out)?,
                Value::Bool(true)
            ) {
                return Ok(v.clone());
            }
        }
        return if or_null {
            Ok(Value::Null)
        } else {
            Err(RuntimeError::Thrown(make_exception(
                "kotlin.NoSuchElementException",
                Some("Collection contains no element matching the predicate.".into()),
            )))
        };
    }
    match items.last() {
        Some(v) => Ok(v.clone()),
        None if or_null => Ok(Value::Null),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.NoSuchElementException",
            Some("Collection is empty.".into()),
        ))),
    }
}

pub(crate) fn coll_list_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_list_last_impl(ctx, false)
}

pub(crate) fn coll_list_last_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_list_last_impl(ctx, true)
}

// A collection index fits in i64; Kotlin lastIndexOf returns Int/-1.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_list_last_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.lastIndexOf")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity(
            "lastIndexOf requires an argument".into(),
        ));
    };
    let borrow = it.borrow();
    let pos = borrow
        .iter()
        .rposition(|v| Value::structural_eq_boxed(v, needle));
    Ok(Value::new_int(pos.map_or(-1, |p| p as i64)))
}
fn join_opt_str<'a>(args: &'a [Value], idx: usize, default: &'a str) -> String {
    match args.get(idx) {
        None | Some(Value::Null) => default.to_string(),
        Some(Value::String(s)) => (**s).clone(),
        Some(other) => format!("{other}"),
    }
}
// limit is non-negative when used as a usize take count.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn coll_list_join_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items: Vec<Value> = match ctx.args.first() {
        Some(v) => iterable_items(v, "joinToString")?,
        None => {
            return Err(RuntimeError::Arity(
                "joinToString expects an iterable receiver".into(),
            ));
        }
    };
    // Detect a trailing callable: a lambda/closure appearing as
    // the last positional arg slots into `transform`, leaving the
    // earlier args as separator/prefix/postfix/limit/truncated.
    let mut effective: Vec<Value> = ctx.args[1..].to_vec();
    let mut transform_slot: Option<Value> = None;
    if let Some(last) = effective.last() {
        let is_bound_ref = if let Value::Instance(inst) = last {
            inst.borrow().class.name.starts_with("$bound_ref$")
        } else {
            false
        };
        if matches!(
            last,
            Value::IrClosure { .. } | Value::Lambda { .. } | Value::BoundMethod { .. }
        ) || is_bound_ref
        {
            transform_slot = effective.pop();
        }
    }
    let sep = join_opt_str(&effective, 0, ", ");
    let prefix = join_opt_str(&effective, 1, "");
    let postfix = join_opt_str(&effective, 2, "");
    let limit: i64 = match effective.get(3) {
        None | Some(Value::Null) => -1,
        Some(v) => v.as_i64().unwrap_or(-1),
    };
    let truncated = join_opt_str(&effective, 4, "...");
    let n = items.len();
    let take = if limit < 0 {
        n
    } else {
        (limit as usize).min(n)
    };
    let mut out = String::new();
    out.push_str(&prefix);
    let CallCtx {
        out: writer, host, ..
    } = ctx;
    for (i, v) in items.iter().enumerate().take(take) {
        if i > 0 {
            out.push_str(&sep);
        }
        let piece = if let Some(t) = &transform_slot {
            let r = host.invoke_callable(t, std::slice::from_ref(v), *writer)?;
            match r {
                Value::String(s) => (*s).clone(),
                other => format!("{other}"),
            }
        } else if matches!(v, Value::Instance(_)) {
            // Honour a user-declared `override fun toString()` on an
            // Instance receiver — the structural Display path would
            // otherwise print `ClassName@<id>`.
            match host.invoke_method(v, "toString", &[], *writer) {
                Some(Ok(Value::String(s))) => (*s).clone(),
                _ => format!("{v}"),
            }
        } else {
            format!("{v}")
        };
        out.push_str(&piece);
    }
    if limit >= 0 && n > take {
        if take > 0 {
            out.push_str(&sep);
        }
        out.push_str(&truncated);
    }
    out.push_str(&postfix);
    Ok(Value::String(Arc::new(out)))
}
// limit is non-negative when used as a usize take count.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn coll_array_join_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Reuses the List join logic on the array's items vector. An
    // array argument carries its items in the same `RefCell<Vec<Value>>`
    // as a List, so the implementation works untouched once we route
    // the receiver through `iterable_items`.
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("Array.joinToString requires a receiver".into()))?;
    let items = iterable_items(recv, "Array.joinToString")?;
    let mut effective: Vec<Value> = ctx.args[1..].to_vec();
    let mut transform_slot: Option<Value> = None;
    if let Some(last) = effective.last() {
        let is_bound_ref = if let Value::Instance(inst) = last {
            inst.borrow().class.name.starts_with("$bound_ref$")
        } else {
            false
        };
        if matches!(
            last,
            Value::IrClosure { .. } | Value::Lambda { .. } | Value::BoundMethod { .. }
        ) || is_bound_ref
        {
            transform_slot = effective.pop();
        }
    }
    let sep = join_opt_str(&effective, 0, ", ");
    let prefix = join_opt_str(&effective, 1, "");
    let postfix = join_opt_str(&effective, 2, "");
    let limit: i64 = match effective.get(3) {
        None | Some(Value::Null) => -1,
        Some(v) => v.as_i64().unwrap_or(-1),
    };
    let truncated = join_opt_str(&effective, 4, "...");
    let n = items.len();
    let take = if limit < 0 {
        n
    } else {
        (limit as usize).min(n)
    };
    let mut out = String::new();
    out.push_str(&prefix);
    let CallCtx {
        out: writer, host, ..
    } = ctx;
    for (i, v) in items.iter().enumerate().take(take) {
        if i > 0 {
            out.push_str(&sep);
        }
        let piece = if let Some(t) = &transform_slot {
            let r = host.invoke_callable(t, std::slice::from_ref(v), *writer)?;
            match r {
                Value::String(s) => (*s).clone(),
                other => format!("{other}"),
            }
        } else {
            format!("{v}")
        };
        out.push_str(&piece);
    }
    if limit >= 0 && n > take {
        if take > 0 {
            out.push_str(&sep);
        }
        out.push_str(&truncated);
    }
    out.push_str(&postfix);
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn coll_list_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("List.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}

// Index is bounds-checked >= 0 before the usize cast.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn coll_mut_list_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.add")?;
    // `add(item)` — single user arg → append, returns Boolean.
    // `add(index, item)` — two user args → insert at index, returns Unit.
    let user = ctx.args.len() - 1;
    if user == 1 {
        let arg = ctx.args.get(1).unwrap().clone();
        it.borrow_mut().push(arg);
        return Ok(Value::Bool(true));
    }
    if user >= 2 {
        let Some(Value::Int(i)) = ctx.args.get(1) else {
            return Err(RuntimeError::Type(
                "add(index, item) requires an Int index".into(),
            ));
        };
        let item = ctx.args.get(2).unwrap().clone();
        let mut borrow = it.borrow_mut();
        let idx = *i as usize;
        if *i < 0 || idx > borrow.len() {
            return Err(RuntimeError::Thrown(Value::Exception {
                fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                message: Some(Arc::new(format!(
                    "Index {i} out of bounds for length {}",
                    borrow.len()
                ))),
                cause: None,
            }));
        }
        borrow.insert(idx, item);
        return Ok(Value::Unit);
    }
    Err(RuntimeError::Arity("add requires an argument".into()))
}
pub(crate) fn coll_mut_list_add_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.addFirst")?;
    let Some(v) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("addFirst requires an argument".into()));
    };
    it.borrow_mut().insert(0, v.clone());
    Ok(Value::Unit)
}

pub(crate) fn coll_mut_list_remove_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeFirst")?;
    let mut b = it.borrow_mut();
    if b.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("ArrayDeque is empty.".into())),
            cause: None,
        }));
    }
    Ok(b.remove(0))
}

pub(crate) fn coll_mut_list_remove_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeLast")?;
    let mut b = it.borrow_mut();
    b.pop().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("ArrayDeque is empty.".into())),
            cause: None,
        })
    })
}

// Index is bounds-checked >= 0 before the usize cast.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn coll_mut_list_remove_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAt")?;
    let Some(Value::Int(i)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("removeAt requires an Int index".into()));
    };
    let mut borrow = it.borrow_mut();
    if *i < 0 || (*i as usize) >= borrow.len() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
                "Index {i} out of bounds for length {}",
                borrow.len()
            ))),
            cause: None,
        }));
    }
    Ok(borrow.remove(*i as usize))
}
pub(crate) fn coll_mut_list_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.clear")?;
    it.borrow_mut().clear();
    sync_map_view(&ctx.args[0]);
    Ok(Value::Unit)
}

/// Natural order for the Kotlin types we currently support as `Comparable`.
/// Returns an `Ordering`, or an error when the types can't be compared.
// Per-type rows are kept separate even when sizes coincide across types.
#[allow(clippy::match_same_arms)]
#[must_use]
pub fn primitive_companion_const(ty: &str, name: &str) -> Option<Value> {
    match (ty, name) {
        ("Int", "MAX_VALUE") => Some(Value::new_int(i64::from(i32::MAX))),
        ("Int", "MIN_VALUE") => Some(Value::new_int(i64::from(i32::MIN))),
        ("Int", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Int", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Long", "MAX_VALUE") => Some(Value::Long(i64::MAX)),
        ("Long", "MIN_VALUE") => Some(Value::Long(i64::MIN)),
        ("Long", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Long", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Short", "MAX_VALUE") => Some(Value::Short(i16::MAX)),
        ("Short", "MIN_VALUE") => Some(Value::Short(i16::MIN)),
        ("Short", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Short", "SIZE_BYTES") => Some(Value::new_int(2)),
        ("Byte", "MAX_VALUE") => Some(Value::Byte(i8::MAX)),
        ("Byte", "MIN_VALUE") => Some(Value::Byte(i8::MIN)),
        ("Byte", "SIZE_BITS") => Some(Value::new_int(8)),
        ("Byte", "SIZE_BYTES") => Some(Value::new_int(1)),
        ("Double", "MAX_VALUE") => Some(Value::Double(f64::MAX)),
        ("Double", "MIN_VALUE") => Some(Value::Double(f64::MIN_POSITIVE)),
        ("Double", "POSITIVE_INFINITY") => Some(Value::Double(f64::INFINITY)),
        ("Double", "NEGATIVE_INFINITY") => Some(Value::Double(f64::NEG_INFINITY)),
        ("Double", "NaN") => Some(Value::Double(f64::NAN)),
        ("Double", "SIZE_BITS") => Some(Value::new_int(64)),
        ("Double", "SIZE_BYTES") => Some(Value::new_int(8)),
        ("Float", "MAX_VALUE") => Some(Value::Float(f32::MAX)),
        ("Float", "MIN_VALUE") => Some(Value::Float(f32::MIN_POSITIVE)),
        ("Float", "POSITIVE_INFINITY") => Some(Value::Float(f32::INFINITY)),
        ("Float", "NEGATIVE_INFINITY") => Some(Value::Float(f32::NEG_INFINITY)),
        ("Float", "NaN") => Some(Value::Float(f32::NAN)),
        ("Float", "SIZE_BITS") => Some(Value::new_int(32)),
        ("Float", "SIZE_BYTES") => Some(Value::new_int(4)),
        ("Char", "MAX_VALUE") => Some(Value::Char(0xFFFFu16)),
        ("Char", "MIN_VALUE") => Some(Value::Char(0u16)),
        ("Char", "SIZE_BITS") => Some(Value::new_int(16)),
        ("Char", "SIZE_BYTES") => Some(Value::new_int(2)),
        _ => None,
    }
}

/// Drive a lazy `Value::Sequence` to completion. Each pipeline op
/// invokes its user lambda through the [`IntrinsicHost`] callback
/// surface (not the interpreter's internal call path), so the HOF
/// dispatch lives entirely in the standard library. Sorting ops
/// buffer-then-emit; `SortedWith` dispatches the comparator's
/// `compare` through `invoke_method`.
pub fn materialise_sequence(
    seq_val: &Value,
    host: &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
) -> Result<Vec<Value>, RuntimeError> {
    materialise_sequence_bounded(seq_val, host, out, None)
}

/// Materialize a Sequence, optionally stopping once `max` items have been
/// produced. The bound makes short-circuiting terminals (`first`, `find`,
/// `any`, `take(n).toList()`) pull only as far as needed instead of running
/// the whole (possibly infinite) source — true Kotlin Sequence laziness.
/// The bound applies on the streaming fast path; ops that must buffer (sort,
/// flatMap, distinct) fall back to full materialization, as in Kotlin.
// One streaming/buffered pipeline driver over the SeqOp match; splitting would fragment it.
// Indices round-trip i64<->usize as Kotlin Sequence index/count conversions.
#[allow(
    clippy::too_many_lines,
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn materialise_sequence_bounded(
    seq_val: &Value,
    host: &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
    max: Option<usize>,
) -> Result<Vec<Value>, RuntimeError> {
    use klio_runtime::{SeqOp, SequenceSource};
    let Value::Sequence(seq) = seq_val else {
        return Err(RuntimeError::Type(
            "materialise_sequence: not a Sequence".into(),
        ));
    };
    let call = |host: &mut dyn klio_runtime::IntrinsicHost,
                f: &Value,
                args: &[Value],
                out: &mut dyn klio_runtime::Output|
     -> Result<Value, RuntimeError> { host.invoke_callable(f, args, out) };
    // Streaming fast path: when every op is a per-item stage (no
    // sort, no flatmap, no distinct) we can pump source items
    // through the pipeline one at a time so a `take(n)` short-
    // circuits upstream side effects.
    let all_streaming = seq.ops.iter().all(|op| {
        matches!(
            op,
            SeqOp::Map(_)
                | SeqOp::Filter(_)
                | SeqOp::FilterNot(_)
                | SeqOp::Take(_)
                | SeqOp::Drop(_)
                | SeqOp::TakeWhile(_)
                | SeqOp::DropWhile(_)
                | SeqOp::OnEach(_)
                | SeqOp::MapIndexed(_)
                | SeqOp::FilterIndexed(_)
        )
    });
    if all_streaming {
        // Per-op streaming state.
        let n_ops = seq.ops.len();
        let mut taken: Vec<usize> = vec![0; n_ops];
        let mut dropped: Vec<usize> = vec![0; n_ops];
        let mut take_while_live: Vec<bool> = vec![true; n_ops];
        let mut drop_while_live: Vec<bool> = vec![true; n_ops];
        let mut indices: Vec<usize> = vec![0; n_ops];
        let mut output: Vec<Value> = Vec::new();
        let pump = |host: &mut dyn klio_runtime::IntrinsicHost,
                    out: &mut dyn klio_runtime::Output,
                    mut current: Value,
                    seq_ops: &[SeqOp],
                    taken: &mut [usize],
                    dropped: &mut [usize],
                    take_while_live: &mut [bool],
                    drop_while_live: &mut [bool],
                    indices: &mut [usize],
                    output: &mut Vec<Value>|
         -> Result<bool, RuntimeError> {
            for (idx, op) in seq_ops.iter().enumerate() {
                match op {
                    SeqOp::Map(f) => {
                        current = call(host, f, std::slice::from_ref(&current), out)?;
                    }
                    SeqOp::OnEach(f) => {
                        call(host, f, std::slice::from_ref(&current), out)?;
                    }
                    SeqOp::MapIndexed(f) => {
                        let i = indices[idx];
                        indices[idx] += 1;
                        current = call(host, f, &[Value::new_int(i as i64), current.clone()], out)?;
                    }
                    SeqOp::FilterIndexed(f) => {
                        let i = indices[idx];
                        indices[idx] += 1;
                        if !matches!(
                            call(host, f, &[Value::new_int(i as i64), current.clone()], out)?,
                            Value::Bool(true)
                        ) {
                            return Ok(true);
                        }
                    }
                    SeqOp::Filter(f) => {
                        if !matches!(
                            call(host, f, std::slice::from_ref(&current), out)?,
                            Value::Bool(true)
                        ) {
                            return Ok(true);
                        }
                    }
                    SeqOp::FilterNot(f) => {
                        if matches!(
                            call(host, f, std::slice::from_ref(&current), out)?,
                            Value::Bool(true)
                        ) {
                            return Ok(true);
                        }
                    }
                    SeqOp::Take(n) => {
                        if taken[idx] >= *n as usize {
                            return Ok(false);
                        }
                        taken[idx] += 1;
                    }
                    SeqOp::Drop(n) => {
                        if dropped[idx] < *n as usize {
                            dropped[idx] += 1;
                            return Ok(true);
                        }
                    }
                    SeqOp::TakeWhile(f) => {
                        if !take_while_live[idx] {
                            return Ok(false);
                        }
                        if !matches!(
                            call(host, f, std::slice::from_ref(&current), out)?,
                            Value::Bool(true)
                        ) {
                            take_while_live[idx] = false;
                            return Ok(false);
                        }
                    }
                    SeqOp::DropWhile(f) => {
                        if drop_while_live[idx] {
                            if matches!(
                                call(host, f, std::slice::from_ref(&current), out)?,
                                Value::Bool(true)
                            ) {
                                return Ok(true);
                            }
                            drop_while_live[idx] = false;
                        }
                    }
                    _ => unreachable!("filtered above"),
                }
            }
            output.push(current);
            Ok(true)
        };
        // Has any Take stage reached its cap? If so, the pipeline
        // is exhausted and the source must NOT be pulled again — a
        // subsequent `map { side-effect }` would otherwise fire for
        // an item that take(N) has already excluded.
        let take_cap_reached = |taken: &[usize]| -> bool {
            seq.ops
                .iter()
                .zip(taken.iter())
                .any(|(op, &t)| matches!(op, SeqOp::Take(n) if t >= *n as usize))
        };
        match &seq.source {
            SequenceSource::Items(v) => {
                for v in v.iter() {
                    if take_cap_reached(&taken) {
                        break;
                    }
                    let cont = pump(
                        host,
                        out,
                        v.clone(),
                        &seq.ops,
                        &mut taken,
                        &mut dropped,
                        &mut take_while_live,
                        &mut drop_while_live,
                        &mut indices,
                        &mut output,
                    )?;
                    if !cont {
                        break;
                    }
                    if let Some(m) = max
                        && output.len() >= m
                    {
                        break;
                    }
                }
            }
            SequenceSource::Generate { seed, next } => {
                let mut cur = seed.as_ref().map(|b| (**b).clone());
                let limit = 1_000_000usize;
                let mut produced = 0usize;
                loop {
                    if take_cap_reached(&taken) {
                        break;
                    }
                    let candidate = if let Some(v) = &cur {
                        v.clone()
                    } else {
                        let r = call(host, next, &[], out)?;
                        if matches!(r, Value::Null) {
                            break;
                        }
                        r
                    };
                    produced += 1;
                    if produced > limit {
                        return Err(RuntimeError::Type(
                            "Sequence: generator exceeded 1,000,000 items".into(),
                        ));
                    }
                    let cont = pump(
                        host,
                        out,
                        candidate.clone(),
                        &seq.ops,
                        &mut taken,
                        &mut dropped,
                        &mut take_while_live,
                        &mut drop_while_live,
                        &mut indices,
                        &mut output,
                    )?;
                    if !cont {
                        break;
                    }
                    if let Some(m) = max
                        && output.len() >= m
                    {
                        break;
                    }
                    let r = call(host, next, std::slice::from_ref(&candidate), out)?;
                    if matches!(r, Value::Null) {
                        break;
                    }
                    cur = Some(r);
                }
            }
        }
        return Ok(output);
    }
    let mut items: Vec<Value> = match &seq.source {
        SequenceSource::Items(v) => (**v).clone(),
        SequenceSource::Generate { seed, next } => {
            let mut acc: Vec<Value> = Vec::new();
            let limit = 1024usize;
            let mut cur = seed.as_ref().map(|b| (**b).clone());
            while acc.len() < limit {
                let candidate = if let Some(v) = &cur {
                    v.clone()
                } else {
                    let r = call(host, next, &[], out)?;
                    if matches!(r, Value::Null) {
                        break;
                    }
                    r
                };
                acc.push(candidate.clone());
                let r = call(host, next, std::slice::from_ref(&candidate), out)?;
                if matches!(r, Value::Null) {
                    break;
                }
                cur = Some(r);
            }
            acc
        }
    };
    for op in &seq.ops {
        match op {
            SeqOp::Map(f) => {
                let mut nx: Vec<Value> = Vec::with_capacity(items.len());
                for v in &items {
                    nx.push(call(host, f, std::slice::from_ref(v), out)?);
                }
                items = nx;
            }
            SeqOp::OnEach(f) => {
                for v in &items {
                    call(host, f, std::slice::from_ref(v), out)?;
                }
            }
            SeqOp::MapIndexed(f) => {
                let mut nx: Vec<Value> = Vec::with_capacity(items.len());
                for (i, v) in items.iter().enumerate() {
                    nx.push(call(host, f, &[Value::new_int(i as i64), v.clone()], out)?);
                }
                items = nx;
            }
            SeqOp::FilterIndexed(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for (i, v) in items.iter().enumerate() {
                    if matches!(
                        call(host, f, &[Value::new_int(i as i64), v.clone()], out)?,
                        Value::Bool(true)
                    ) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Filter(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if matches!(
                        call(host, f, std::slice::from_ref(v), out)?,
                        Value::Bool(true)
                    ) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::FilterNot(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if !matches!(
                        call(host, f, std::slice::from_ref(v), out)?,
                        Value::Bool(true)
                    ) {
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Take(n) => {
                let n = *n as usize;
                if n < items.len() {
                    items.truncate(n);
                }
            }
            SeqOp::Drop(n) => {
                let n = (*n as usize).min(items.len());
                items.drain(..n);
            }
            SeqOp::TakeWhile(f) => {
                let mut cutoff = items.len();
                for (i, v) in items.iter().enumerate() {
                    if !matches!(
                        call(host, f, std::slice::from_ref(v), out)?,
                        Value::Bool(true)
                    ) {
                        cutoff = i;
                        break;
                    }
                }
                items.truncate(cutoff);
            }
            SeqOp::DropWhile(f) => {
                let mut start = 0usize;
                while start < items.len() {
                    let v = items[start].clone();
                    if !matches!(
                        call(host, f, std::slice::from_ref(&v), out)?,
                        Value::Bool(true)
                    ) {
                        break;
                    }
                    start += 1;
                }
                items.drain(..start);
            }
            SeqOp::FlatMap(f) => {
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    let mapped = call(host, f, std::slice::from_ref(v), out)?;
                    match mapped {
                        Value::List { items: xs, .. } | Value::Set { items: xs, .. } => {
                            nx.extend(xs.borrow().iter().cloned());
                        }
                        Value::Sequence(_) => {
                            nx.extend(materialise_sequence(&mapped, host, out)?);
                        }
                        other => nx.push(other),
                    }
                }
                items = nx;
            }
            SeqOp::Distinct => {
                let mut seen: Vec<Value> = Vec::new();
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    if !seen.iter().any(|s| Value::structural_eq_boxed(s, v)) {
                        seen.push(v.clone());
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::DistinctBy(f) => {
                let mut seen: Vec<Value> = Vec::new();
                let mut nx: Vec<Value> = Vec::new();
                for v in &items {
                    let key = call(host, f, std::slice::from_ref(v), out)?;
                    if !seen.iter().any(|s| Value::structural_eq_boxed(s, &key)) {
                        seen.push(key);
                        nx.push(v.clone());
                    }
                }
                items = nx;
            }
            SeqOp::Sorted(descending) => {
                let descending = *descending;
                let mut err: Option<RuntimeError> = None;
                items.sort_by(|a, b| {
                    if err.is_some() {
                        return std::cmp::Ordering::Equal;
                    }
                    match compare_values(a, b) {
                        Ok(o) => {
                            if descending {
                                o.reverse()
                            } else {
                                o
                            }
                        }
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    }
                });
                if let Some(e) = err {
                    return Err(e);
                }
            }
            SeqOp::SortedBy(f, descending) => {
                let descending = *descending;
                let mut keyed: Vec<(Value, Value)> = Vec::with_capacity(items.len());
                for v in items.drain(..) {
                    let k = call(host, f, std::slice::from_ref(&v), out)?;
                    keyed.push((k, v));
                }
                let mut err: Option<RuntimeError> = None;
                keyed.sort_by(|a, b| {
                    if err.is_some() {
                        return std::cmp::Ordering::Equal;
                    }
                    match compare_values(&a.0, &b.0) {
                        Ok(o) => {
                            if descending {
                                o.reverse()
                            } else {
                                o
                            }
                        }
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    }
                });
                if let Some(e) = err {
                    return Err(e);
                }
                items = keyed.into_iter().map(|(_, v)| v).collect();
            }
            SeqOp::SortedWith(comparator) => {
                let comp = comparator.clone();
                // Insertion sort so the comparator callback can
                // dispatch back through the host.
                for i in 1..items.len() {
                    let mut j = i;
                    while j > 0 {
                        let a = items[j - 1].clone();
                        let b = items[j].clone();
                        let ord_val = match host.invoke_method(&comp, "compare", &[a, b], out) {
                            Some(Ok(v)) => v,
                            Some(Err(e)) => return Err(e),
                            None => {
                                return Err(RuntimeError::Type(
                                    "SortedWith: comparator has no `compare` method".into(),
                                ));
                            }
                        };
                        let n = ord_val.as_i64().unwrap_or(0);
                        if n > 0 {
                            items.swap(j - 1, j);
                            j -= 1;
                        } else {
                            break;
                        }
                    }
                }
            }
        }
    }
    Ok(items)
}

/// Kotlin's `Double`/`Float` total order (matching `java.lang.Double.compare`):
/// every `NaN` is greater than all other values (including `+Infinity`) and all
/// `NaN`s are equal, and `-0.0 < 0.0`. Implemented via the bit ordering Java's
/// `doubleToLongBits` defines, with `NaN` canonicalised so klio's negative-NaN
/// bit pattern still sorts as the greatest value. (The IEEE `<`/`>` operators
/// keep their own non-total semantics elsewhere.)
// Reinterprets the IEEE bit pattern as i64 for the total order.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn kotlin_float_total_cmp(a: f64, b: f64) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if a < b {
        Ordering::Less
    } else if a > b {
        Ordering::Greater
    } else {
        let bits = |x: f64| -> i64 {
            if x.is_nan() {
                0x7ff8_0000_0000_0000u64 as i64
            } else {
                x.to_bits() as i64
            }
        };
        bits(a).cmp(&bits(b))
    }
}

/// Compare two values by Kotlin's natural ordering.
///
/// # Panics
///
/// Panics if a value reports itself numeric/integral but its `as_i64`
/// or `as_f64` accessor returns `None`, which cannot happen for the
/// built-in value kinds.
pub fn compare_values(a: &Value, b: &Value) -> Result<std::cmp::Ordering, RuntimeError> {
    if a.is_numeric() && b.is_numeric() {
        if a.is_integral() && b.is_integral() {
            return Ok(a.as_i64().unwrap().cmp(&b.as_i64().unwrap()));
        }
        return Ok(kotlin_float_total_cmp(
            a.as_f64().unwrap(),
            b.as_f64().unwrap(),
        ));
    }
    Ok(match (a, b) {
        (Value::String(x), Value::String(y)) => crate::text::compare_utf16(x, y),
        (Value::Char(x), Value::Char(y)) => x.cmp(y),
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        _ => {
            return Err(RuntimeError::Type(format!(
                "values are not comparable: {a:?}, {b:?}"
            )));
        }
    })
}

pub(crate) fn coll_list_sorted(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.sorted")?;
    let mut copy: Vec<Value> = it.borrow().clone();
    // For Instance items, defer to a user-declared
    // `override fun compareTo(...)` via the host. Build a parallel
    // scores array of pairwise comparisons up-front to keep
    // sort_by's closure side-effect-free.
    let needs_host = copy.iter().any(|v| matches!(v, Value::Instance(_)));
    let mut err: Option<RuntimeError> = None;
    if needs_host {
        let CallCtx { out, host, .. } = ctx;
        let mut indexed: Vec<(usize, Value)> = copy.iter().cloned().enumerate().collect();
        indexed.sort_by(|(ia, a), (ib, b)| {
            if err.is_some() {
                return ia.cmp(ib);
            }
            let ord = if matches!(a, Value::Instance(_)) {
                match host.invoke_method(a, "compareTo", std::slice::from_ref(b), *out) {
                    Some(Ok(Value::Int(n))) => i32_to_ordering(n),
                    Some(Err(e)) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                    _ => match compare_values(a, b) {
                        Ok(o) => o,
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    },
                }
            } else {
                match compare_values(a, b) {
                    Ok(o) => o,
                    Err(e) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                }
            };
            if ord == std::cmp::Ordering::Equal {
                ia.cmp(ib)
            } else {
                ord
            }
        });
        if let Some(e) = err {
            return Err(e);
        }
        return Ok(make_list(
            indexed.into_iter().map(|(_, v)| v).collect(),
            false,
        ));
    }
    copy.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(a, b) {
            Ok(o) => o,
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(copy, false))
}

pub(crate) fn i32_to_ordering(n: i32) -> std::cmp::Ordering {
    n.cmp(&0)
}

pub(crate) fn coll_list_sorted_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = coll_list_sorted(ctx)?;
    let Value::List { items, .. } = v else {
        unreachable!()
    };
    let mut out: Vec<Value> = items.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

pub(crate) fn coll_list_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.reversed")?;
    let mut out: Vec<Value> = it.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

// A list length fits in i64.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_list_indices(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.indices")?;
    let len = it.borrow().len() as i64;
    Ok(Value::Range {
        start: 0,
        end: len - 1,
        step: 1,
        kind: klio_runtime::RangeKind::Int,
    })
}

// A list length fits in i64.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn coll_list_last_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.lastIndex")?;
    Ok(Value::new_int(it.borrow().len() as i64 - 1))
}

// Kotlin Long.toDouble() loses precision past 2^53.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn coll_list_sum(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.sum")?;
    let mut acc_int: Option<i64> = Some(0);
    let mut acc_dbl: Option<f64> = None;
    for v in it.borrow().iter() {
        if v.is_integral() {
            let n = v.as_i64().unwrap();
            if let Some(a) = acc_int.as_mut() {
                *a = a.wrapping_add(n);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += n as f64;
            }
        } else if v.is_floating() {
            let d = v.as_f64().unwrap();
            if let Some(a) = acc_int.take() {
                acc_dbl = Some(a as f64 + d);
            } else if let Some(a) = acc_dbl.as_mut() {
                *a += d;
            }
        } else {
            return Err(RuntimeError::Type(format!(
                "List.sum requires numeric elements, got {v:?}"
            )));
        }
    }
    Ok(match acc_dbl {
        Some(d) => Value::Double(d),
        None => Value::new_int(acc_int.unwrap_or(0)),
    })
}

// Kotlin Long.toDouble() loses precision past 2^53.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn coll_list_average(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.average")?;
    let borrow = it.borrow();
    if borrow.is_empty() {
        return Ok(Value::Double(f64::NAN));
    }
    let mut sum = 0.0;
    let mut n = 0i64;
    for v in borrow.iter() {
        sum += match v {
            Value::Int(x) => f64::from(*x),
            Value::Double(x) => *x,
            other => {
                return Err(RuntimeError::Type(format!(
                    "List.average requires numeric elements, got {other:?}"
                )));
            }
        };
        n += 1;
    }
    Ok(Value::Double(sum / n as f64))
}

pub(crate) fn coll_list_max_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.maxOrNull")?;
    let items: Vec<Value> = it.borrow().clone();
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = items[0].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().skip(1) {
        let ord = compare_host_aware(v, &best, host, *out)?;
        if ord == std::cmp::Ordering::Greater {
            best = v.clone();
        }
    }
    Ok(best)
}

pub(crate) fn coll_list_min_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.minOrNull")?;
    let items: Vec<Value> = it.borrow().clone();
    if items.is_empty() {
        return Ok(Value::Null);
    }
    let mut best = items[0].clone();
    let CallCtx { out, host, .. } = ctx;
    for v in items.iter().skip(1) {
        let ord = compare_host_aware(v, &best, host, *out)?;
        if ord == std::cmp::Ordering::Less {
            best = v.clone();
        }
    }
    Ok(best)
}

// host is forwarded straight from a destructured CallCtx; a cross-crate
// caller (math.rs) passes the same &mut &mut, so the type stays as-is.
#[allow(clippy::mut_mut)]
pub(crate) fn compare_host_aware(
    a: &Value,
    b: &Value,
    host: &mut &mut dyn klio_runtime::IntrinsicHost,
    out: &mut dyn klio_runtime::Output,
) -> Result<std::cmp::Ordering, RuntimeError> {
    if matches!(a, Value::Instance(_))
        && let Some(Ok(Value::Int(n))) =
            host.invoke_method(a, "compareTo", std::slice::from_ref(b), out)
    {
        return Ok(i32_to_ordering(n));
    }
    compare_values(a, b)
}

/// Collect `(key, value)` entries from a slice of `Value::Pair`s,
/// last-write-wins on duplicate keys (matching `toMap`/`putAll`).
pub(crate) fn pairs_from_values(
    items: &[Value],
    who: &str,
) -> Result<Vec<(Value, Value)>, RuntimeError> {
    let mut entries: Vec<(Value, Value)> = Vec::new();
    for v in items {
        let Value::Pair(k, val) = v else {
            return Err(RuntimeError::Type(format!(
                "{who} requires a collection of Pair<K, V>"
            )));
        };
        let key = (**k).clone();
        if let Some(slot) = entries
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &key))
        {
            slot.1 = (**val).clone();
        } else {
            entries.push((key, (**val).clone()));
        }
    }
    Ok(entries)
}

pub(crate) fn coll_list_to_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Accept List/Set (recv_list_items) and Array receivers uniformly:
    // upstream `Array<out Pair>.toMap()` and `Iterable<Pair>.toMap()`
    // share this body.
    let items: Vec<Value> = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.borrow().clone(),
        _ => recv_list_items(ctx.args, "toMap")?.borrow().clone(),
    };
    Ok(make_map(pairs_from_values(&items, "toMap")?, false))
}

pub(crate) fn coll_list_distinct(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.distinct")?;
    let mut out: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        if !out.iter().any(|x| Value::structural_eq_boxed(x, v)) {
            out.push(v.clone());
        }
    }
    Ok(make_list(out, false))
}

pub(crate) fn list_take_count(ctx: &CallCtx<'_>, what: &str) -> Result<i64, RuntimeError> {
    let Some(n) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires an Int")));
    };
    if n < 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!(
                "Requested element count {n} is less than zero."
            ))),
            cause: None,
        }));
    }
    Ok(n)
}

// list_take_count validates the count >= 0 before the usize cast.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn coll_list_take_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.takeLast")?;
    let n = list_take_count(ctx, "takeLast")? as usize;
    let borrow = it.borrow();
    let start = borrow.len().saturating_sub(n);
    Ok(make_list(borrow[start..].to_vec(), false))
}
// list_take_count validates the count >= 0 before the usize cast.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn coll_list_drop_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.dropLast")?;
    let n = list_take_count(ctx, "dropLast")? as usize;
    let borrow = it.borrow();
    let end = borrow.len().saturating_sub(n);
    Ok(make_list(borrow[..end].to_vec(), false))
}

// Length fits in i64; indices are bounds-checked >= 0 before the usize cast.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn coll_list_slice(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.slice")?;
    let borrow = it.borrow();
    let len = borrow.len() as i64;
    let out_items: Vec<Value> = match ctx.args.get(1) {
        Some(Value::Range {
            start, end, step, ..
        }) => {
            let mut v = Vec::new();
            for i in range_iter_int(*start, *end, *step) {
                if i < 0 || i >= len {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Arc::new(format!(
                            "Index {i} out of bounds for length {len}"
                        ))),
                        cause: None,
                    }));
                }
                v.push(borrow[i as usize].clone());
            }
            v
        }
        Some(Value::List { items, .. }) => {
            let mut v = Vec::new();
            for idx_val in items.borrow().iter() {
                let Some(i) = idx_val.as_i64() else {
                    return Err(RuntimeError::Type("slice indices must be Int".into()));
                };
                if i < 0 || i >= len {
                    return Err(RuntimeError::Thrown(Value::Exception {
                        fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
                        message: Some(Arc::new(format!(
                            "Index {i} out of bounds for length {len}"
                        ))),
                        cause: None,
                    }));
                }
                v.push(borrow[i as usize].clone());
            }
            v
        }
        _ => {
            return Err(RuntimeError::Type(
                "slice requires an IntRange or List<Int>".into(),
            ));
        }
    };
    Ok(make_list(out_items, false))
}

// Length fits in i64; from/to are bounds-checked >= 0 before the usize cast.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn coll_list_sublist(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.subList")?;
    let Some(from) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("subList requires Int fromIndex".into()));
    };
    let Some(to) = ctx.args.get(2).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("subList requires Int toIndex".into()));
    };
    let borrow = it.borrow();
    let len = borrow.len() as i64;
    if from < 0 || to > len || from > to {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IndexOutOfBoundsException".into()),
            message: Some(Arc::new(format!(
                "fromIndex: {from}, toIndex: {to}, size: {len}"
            ))),
            cause: None,
        }));
    }
    Ok(make_list(
        borrow[from as usize..to as usize].to_vec(),
        false,
    ))
}

pub(crate) fn coll_list_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.plus")?;
    let mut out: Vec<Value> = it.borrow().clone();
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    match arg {
        Value::List { items, .. } | Value::Set { items, .. } => out.extend(items.borrow().clone()),
        single => out.push(single.clone()),
    }
    Ok(make_list(out, false))
}

pub(crate) fn coll_list_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let removals: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let mut out: Vec<Value> = Vec::new();
    let mut remaining = removals.clone();
    for v in it.borrow().iter() {
        if let Some(pos) = remaining
            .iter()
            .position(|r| Value::structural_eq_boxed(r, v))
        {
            remaining.remove(pos);
        } else {
            out.push(v.clone());
        }
    }
    Ok(make_list(out, false))
}

// size is validated > 0 before the usize cast.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn coll_list_chunked(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.chunked")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("chunked requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("Size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let size = *size as usize;
    let transform = match ctx.args.get(2) {
        Some(Value::Null) | None => None,
        Some(v) => Some(v.clone()),
    };
    let chunks: Vec<Vec<Value>> = {
        let borrow = it.borrow();
        let mut chunks: Vec<Vec<Value>> = Vec::new();
        let mut i = 0;
        while i < borrow.len() {
            let end = (i + size).min(borrow.len());
            chunks.push(borrow[i..end].to_vec());
            i += size;
        }
        chunks
    };
    let mut groups: Vec<Value> = Vec::with_capacity(chunks.len());
    match transform {
        None => {
            for c in chunks {
                groups.push(make_list(c, false));
            }
        }
        Some(block) => {
            let CallCtx { out, host, .. } = ctx;
            for c in chunks {
                let window = make_list(c, false);
                let r = host.invoke_callable(&block, std::slice::from_ref(&window), *out)?;
                groups.push(r);
            }
        }
    }
    Ok(make_list(groups, false))
}

// size and step are validated > 0 before the usize casts.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn coll_list_windowed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.windowed")?;
    let Some(Value::Int(size)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("windowed requires an Int size".into()));
    };
    if *size <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("size {size} must be greater than zero."))),
            cause: None,
        }));
    }
    let step = match ctx.args.get(2) {
        None => 1i64,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("windowed step must be Int".into())),
    };
    if step <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("step {step} must be greater than zero."))),
            cause: None,
        }));
    }
    let partial_windows = match ctx.args.get(3) {
        None => false,
        Some(Value::Bool(b)) => *b,
        _ => {
            return Err(RuntimeError::Type(
                "windowed partialWindows must be Bool".into(),
            ));
        }
    };
    let borrow = it.borrow();
    let size = *size as usize;
    let step = step as usize;
    let mut out: Vec<Value> = Vec::new();
    let mut i = 0usize;
    while i < borrow.len() {
        let end = i + size;
        if end <= borrow.len() {
            out.push(make_list(borrow[i..end].to_vec(), false));
        } else if partial_windows {
            out.push(make_list(borrow[i..].to_vec(), false));
        } else {
            break;
        }
        i += step;
    }
    Ok(make_list(out, false))
}

pub(crate) fn coll_list_zip(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let lhs = recv_list_items(ctx.args, "List.zip")?;
    let Some(rhs_val) = ctx.args.get(1).cloned() else {
        return Err(RuntimeError::Arity(
            "zip requires a second collection".into(),
        ));
    };
    // Optional transform: `xs.zip(ys) { x, y -> … }` packs the
    // result via the lambda instead of producing Pair values.
    let transform = ctx.args.get(2).cloned().filter(|v| {
        matches!(
            v,
            Value::IrClosure { .. }
                | Value::Lambda { .. }
                | Value::BoundMethod { .. }
                | Value::Instance(_)
        )
    });
    let rhs: Vec<Value> = match &rhs_val {
        Value::List { items, .. } | Value::Set { items, .. } | Value::Array { items, .. } => {
            items.borrow().clone()
        }
        Value::Range {
            start, end, step, ..
        } => range_iter_int(*start, *end, *step)
            .map(Value::new_int)
            .collect(),
        other => {
            return Err(RuntimeError::Type(format!(
                "zip requires a collection, got {other:?}"
            )));
        }
    };
    let lhs_items: Vec<Value> = lhs.borrow().clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result: Vec<Value> = Vec::with_capacity(lhs_items.len().min(rhs.len()));
    for (a, b) in lhs_items.iter().zip(rhs.iter()) {
        if let Some(t) = &transform {
            let r = host.invoke_callable(t, &[a.clone(), b.clone()], *out)?;
            result.push(r);
        } else {
            result.push(Value::Pair(Box::new(a.clone()), Box::new(b.clone())));
        }
    }
    Ok(make_list(result, false))
}

pub(crate) fn range_iter_int(start: i64, end: i64, step: i64) -> Box<dyn Iterator<Item = i64>> {
    if step == 0 {
        return Box::new(std::iter::empty());
    }
    if step > 0 {
        if start > end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur > end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    } else {
        if start < end {
            return Box::new(std::iter::empty());
        }
        let mut cur = start;
        Box::new(std::iter::from_fn(move || {
            if cur < end {
                None
            } else {
                let v = cur;
                cur = cur.saturating_add(step);
                Some(v)
            }
        }))
    }
}

pub(crate) fn coll_set_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.plus")?;
    let mut out: Vec<Value> = it.borrow().clone();
    let push = |out: &mut Vec<Value>, v: Value| {
        if !out.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
            out.push(v);
        }
    };
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    match arg {
        Value::List { items, .. } | Value::Set { items, .. } => {
            for v in items.borrow().iter() {
                push(&mut out, v.clone());
            }
        }
        single => push(&mut out, single.clone()),
    }
    Ok(Value::Set {
        items: ObjRef::new(out),
        mutable: false,
        backing: None,
    })
}

pub(crate) fn coll_set_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let removals: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let out: Vec<Value> = it
        .borrow()
        .iter()
        .filter(|v| !removals.iter().any(|r| Value::structural_eq_boxed(r, v)))
        .cloned()
        .collect();
    Ok(Value::Set {
        items: ObjRef::new(out),
        mutable: false,
        backing: None,
    })
}

/// `Map + Pair` / `Map + Map` / `Map + Iterable<Pair>` — returns a
/// new map with the entries added (existing keys overwritten,
/// last-write-wins via `make_map`).
pub(crate) fn coll_map_to_mutable_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = match ctx.args.first() {
        Some(Value::Map { entries, .. }) => entries.borrow().clone(),
        _ => {
            return Err(RuntimeError::Type(
                "toMutableMap requires a Map receiver".into(),
            ));
        }
    };
    Ok(make_map(entries, true))
}

pub(crate) fn coll_map_to_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = match ctx.args.first() {
        Some(Value::Map { entries, .. }) => entries.borrow().clone(),
        _ => return Err(RuntimeError::Type("toMap requires a Map receiver".into())),
    };
    Ok(make_map(entries, false))
}

pub(crate) fn coll_map_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.plus")?;
    let mut out: Vec<(Value, Value)> = entries.borrow().clone();
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("plus requires an argument".into()));
    };
    let add_pair = |out: &mut Vec<(Value, Value)>, p: &Value| {
        if let Value::Pair(k, v) = p {
            out.push(((**k).clone(), (**v).clone()));
        }
    };
    match arg {
        Value::Pair(_, _) => add_pair(&mut out, arg),
        Value::Map { entries: e, .. } => out.extend(e.borrow().clone()),
        Value::List { items, .. } | Value::Set { items, .. } => {
            for p in items.borrow().iter() {
                add_pair(&mut out, p);
            }
        }
        _ => {
            return Err(RuntimeError::Type(
                "Map.plus expects a Pair, Map, or Iterable<Pair>".into(),
            ));
        }
    }
    Ok(make_map(out, false))
}

/// `Map - key` / `Map - Iterable<key>` — returns a new map without
/// the given key(s).
pub(crate) fn coll_map_minus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.minus")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("minus requires an argument".into()));
    };
    let keys: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        single => vec![single.clone()],
    };
    let out: Vec<(Value, Value)> = entries
        .borrow()
        .iter()
        .filter(|(k, _)| !keys.iter().any(|rk| Value::structural_eq_boxed(rk, k)))
        .cloned()
        .collect();
    Ok(make_map(out, false))
}

pub(crate) fn coll_set_union(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_set_plus(ctx)
}
pub(crate) fn coll_set_intersect(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.intersect")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("intersect requires an argument".into()));
    };
    let other: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("intersect requires a collection".into())),
    };
    let out: Vec<Value> = it
        .borrow()
        .iter()
        .filter(|v| other.iter().any(|o| Value::structural_eq_boxed(o, v)))
        .cloned()
        .collect();
    Ok(Value::Set {
        items: ObjRef::new(out),
        mutable: false,
        backing: None,
    })
}
pub(crate) fn coll_set_subtract(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    coll_set_minus(ctx)
}

// ----- Set helpers -----

/// After a live `MutableMap.keys`/`.values`/`.entries` view has had its
/// `items` mutated (remove/removeAll/retainAll/clear), rebuild the backing
/// map's entries to mirror the surviving elements. Order-preserving;
/// value-multiplicity-aware for the `values` view.
pub(crate) fn sync_map_view(receiver: &Value) {
    let (items, backing) = match receiver {
        Value::Set {
            items,
            backing: Some(b),
            ..
        }
        | Value::List {
            items,
            backing: Some(b),
            ..
        } => (items.clone(), b.clone()),
        _ => return,
    };
    let items_b = items.borrow();
    let kind = backing.kind;
    let mut entries = backing.entries.borrow_mut();
    // The surviving `items` are an order-preserving subsequence of the
    // pre-mutation projection of the entries (keys / values / entry-keys).
    // Walk both in lockstep: keep an entry when its projection matches the
    // next surviving item, advancing the item cursor; drop it otherwise.
    // Subsequence (not multiset) matching keeps the right entry when values
    // repeat — `values.remove(v)` drops the entry of the *first* matching
    // value, exactly as the JVM view does.
    let mut j = 0usize;
    entries.retain(|(k, v)| {
        let proj = match kind {
            klio_runtime::MapViewKind::Values => v,
            _ => k,
        };
        let matched = items_b.get(j).is_some_and(|it| {
            let target = match (kind, it) {
                (klio_runtime::MapViewKind::Entries, Value::MapEntry { key, .. }) => key.as_ref(),
                _ => it,
            };
            Value::structural_eq_boxed(proj, target)
        });
        if matched {
            j += 1;
            true
        } else {
            false
        }
    });
}

pub(crate) fn recv_set_items(
    args: &[Value],
    what: &str,
) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    match args.first() {
        Some(Value::Set { items, .. }) => Ok(items.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a Set receiver"
        ))),
    }
}

pub(crate) fn coll_set_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.size")?;
    Ok(Value::new_int(it.borrow().len()))
}
pub(crate) fn coll_set_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(
        recv_set_items(ctx.args, "Set.isEmpty")?.borrow().is_empty(),
    ))
}
pub(crate) fn coll_set_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(
        !recv_set_items(ctx.args, "Set.isNotEmpty")?
            .borrow()
            .is_empty(),
    ))
}
pub(crate) fn coll_set_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.contains")?;
    let Some(needle) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("contains requires an argument".into()));
    };
    Ok(Value::Bool(
        it.borrow()
            .iter()
            .any(|v| Value::structural_eq_boxed(v, needle)),
    ))
}
// Range bounds index the array; they are clamped to its length below.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn array_slice_impl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("sliceArray requires a receiver".into()))?;
    let (items, prim) = match recv {
        Value::Array { items, prim } => (items.clone(), *prim),
        _ => {
            return Err(RuntimeError::Type(
                "sliceArray requires an array receiver".into(),
            ));
        }
    };
    let arg = ctx
        .args
        .get(1)
        .ok_or_else(|| RuntimeError::Arity("sliceArray expects (receiver, range)".into()))?;
    let (start, end) = match arg {
        Value::Range {
            start,
            end,
            step: _,
            kind: _,
        } => (*start as usize, *end as usize),
        _ => {
            return Err(RuntimeError::Type(
                "sliceArray expects an IntRange argument".into(),
            ));
        }
    };
    let src = items.borrow();
    let lo = start.min(src.len());
    let hi = (end + 1).min(src.len());
    let slice: Vec<Value> = if lo <= hi {
        src[lo..hi].to_vec()
    } else {
        Vec::new()
    };
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(slice),
        prim,
    })
}

/// Zero value for a primitive-array element kind — the padding that
/// `copyOf(newSize)` writes beyond the original length, matching the
/// default each `*Array(size)` constructor uses.
fn array_prim_default(prim: Option<klio_runtime::PrimitiveArrayKind>) -> Value {
    use klio_runtime::PrimitiveArrayKind as P;
    match prim {
        Some(P::Int) => Value::Int(0),
        Some(P::Long) => Value::Long(0),
        Some(P::Double) => Value::Double(0.0),
        Some(P::Float) => Value::Float(0.0),
        Some(P::Short) => Value::Short(0),
        Some(P::Byte) => Value::Byte(0),
        Some(P::Boolean) => Value::Bool(false),
        Some(P::Char) => Value::Char(0),
        Some(P::UInt) => Value::UInt(0),
        Some(P::ULong) => Value::ULong(0),
        Some(P::UShort) => Value::UShort(0),
        Some(P::UByte) => Value::UByte(0),
        None => Value::Null,
    }
}

/// Optional `Int` index argument with a default when the caller omitted
/// it (these array ops carry default values for the trailing indices).
fn array_opt_index(
    ctx: &CallCtx,
    idx: usize,
    default: i64,
    what: &str,
) -> Result<i64, RuntimeError> {
    match ctx.args.get(idx) {
        None => Ok(default),
        Some(v) => v
            .as_i64()
            .ok_or_else(|| RuntimeError::Type(format!("{what}: index argument must be an Int"))),
    }
}

fn index_oob(msg: String) -> RuntimeError {
    RuntimeError::Thrown(make_exception(
        "kotlin.IndexOutOfBoundsException",
        Some(msg),
    ))
}

/// `Array<T>.copyInto(destination, destinationOffset = 0, startIndex = 0,
/// endIndex = size): destination` and the primitive-array variants.
/// Copies `this[startIndex, endIndex)` into `destination` starting at
/// `destinationOffset`, then returns `destination`. The source range is
/// snapshotted before any write so `this === destination` overlap is
/// well defined and the same backing store is never borrowed mutably and
/// immutably at once.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_copy_into(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let src = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.clone(),
        _ => {
            return Err(RuntimeError::Type(
                "copyInto requires an array receiver".into(),
            ));
        }
    };
    let dest_val = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("copyInto expects (destination, ...)".into()))?;
    let dest = match &dest_val {
        Value::Array { items, .. } => items.clone(),
        _ => {
            return Err(RuntimeError::Type(
                "copyInto destination must be an array".into(),
            ));
        }
    };
    let src_len = src.borrow().len() as i64;
    let dest_offset = array_opt_index(ctx, 2, 0, "copyInto")?;
    let start = array_opt_index(ctx, 3, 0, "copyInto")?;
    let end = array_opt_index(ctx, 4, src_len, "copyInto")?;
    if start < 0 || end > src_len || start > end {
        return Err(index_oob(format!(
            "copyInto: source range [{start}, {end}) out of bounds for length {src_len}"
        )));
    }
    let count = end - start;
    let dest_len = dest.borrow().len() as i64;
    if dest_offset < 0 || dest_offset + count > dest_len {
        return Err(index_oob(format!(
            "copyInto: destination range [{dest_offset}, {}) out of bounds for length {dest_len}",
            dest_offset + count
        )));
    }
    let slice: Vec<Value> = src.borrow()[start as usize..end as usize].to_vec();
    {
        let mut d = dest.borrow_mut();
        let base = dest_offset as usize;
        for (i, v) in slice.into_iter().enumerate() {
            d[base + i] = v;
        }
    }
    Ok(dest_val)
}

/// `Array<T>.copyOf()` and `Array<T>.copyOf(newSize)` (and primitive
/// variants). Both overloads share one host symbol; the no-argument form
/// copies at the current length, the sized form truncates or pads with
/// the element kind's zero value.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_copy_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, prim) = match ctx.args.first() {
        Some(Value::Array { items, prim }) => (items.clone(), *prim),
        _ => {
            return Err(RuntimeError::Type(
                "copyOf requires an array receiver".into(),
            ));
        }
    };
    let cur = items.borrow();
    let new_size = array_opt_index(ctx, 1, cur.len() as i64, "copyOf")?;
    if new_size < 0 {
        return Err(RuntimeError::Type(format!(
            "copyOf: negative new size {new_size}"
        )));
    }
    let new_size = new_size as usize;
    let default = array_prim_default(prim);
    let mut out = Vec::with_capacity(new_size);
    for i in 0..new_size {
        out.push(cur.get(i).cloned().unwrap_or_else(|| default.clone()));
    }
    Ok(Value::Array {
        items: ObjRef::new(out),
        prim,
    })
}

/// `Array<T>.copyOfRange(fromIndex, toIndex)` — a fresh array holding
/// `this[fromIndex, toIndex)`.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_copy_of_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (items, prim) = match ctx.args.first() {
        Some(Value::Array { items, prim }) => (items.clone(), *prim),
        _ => {
            return Err(RuntimeError::Type(
                "copyOfRange requires an array receiver".into(),
            ));
        }
    };
    let cur = items.borrow();
    let len = cur.len() as i64;
    let from = array_opt_index(ctx, 1, 0, "copyOfRange")?;
    let to = array_opt_index(ctx, 2, len, "copyOfRange")?;
    if from < 0 || to > len || from > to {
        return Err(index_oob(format!(
            "copyOfRange: [{from}, {to}) out of bounds for length {len}"
        )));
    }
    let out: Vec<Value> = cur[from as usize..to as usize].to_vec();
    Ok(Value::Array {
        items: ObjRef::new(out),
        prim,
    })
}

/// `Array<T>.fill(element, fromIndex = 0, toIndex = size)` — overwrites
/// the range in place and returns `Unit`.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_fill(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.clone(),
        _ => return Err(RuntimeError::Type("fill requires an array receiver".into())),
    };
    let element = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("fill expects (element, ...)".into()))?;
    let len = items.borrow().len() as i64;
    let from = array_opt_index(ctx, 2, 0, "fill")?;
    let to = array_opt_index(ctx, 3, len, "fill")?;
    if from < 0 || to > len || from > to {
        return Err(index_oob(format!(
            "fill: [{from}, {to}) out of bounds for length {len}"
        )));
    }
    {
        let mut d = items.borrow_mut();
        for slot in d.iter_mut().take(to as usize).skip(from as usize) {
            *slot = element.clone();
        }
    }
    Ok(Value::Unit)
}

/// `Array<T>.sort()` / `sort(fromIndex = 0, toIndex = size)` and the
/// primitive-array variants — sorts the range in place by natural order
/// and returns `Unit`. `Array<T>` elements that are user instances are
/// ordered through their `compareTo` (the same host-aware path
/// `List.sorted` uses); the sort is stable. Upstream declares these
/// `expect` with no klio-runnable body, so without this actual every
/// `sort()` silently no-opped (and `sortedArray` / `sortDescending`,
/// which delegate to it, returned unsorted data).
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_sort(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.clone(),
        _ => return Err(RuntimeError::Type("sort requires an array receiver".into())),
    };
    let len = items.borrow().len() as i64;
    let from = array_opt_index(ctx, 1, 0, "sort")?;
    let to = array_opt_index(ctx, 2, len, "sort")?;
    if from < 0 || to > len || from > to {
        return Err(index_oob(format!(
            "sort: range [{from}, {to}) out of bounds for length {len}"
        )));
    }
    let (from, to) = (from as usize, to as usize);
    let mut buf: Vec<Value> = items.borrow().clone();
    let needs_host = buf[from..to]
        .iter()
        .any(|v| matches!(v, Value::Instance(_)));
    let mut err: Option<RuntimeError> = None;
    if needs_host {
        let CallCtx { out, host, .. } = ctx;
        // Stable, index-aware ordering that defers to a user-declared
        // `compareTo` for instance elements (mirrors `List.sorted`).
        let mut indexed: Vec<(usize, Value)> = buf[from..to].iter().cloned().enumerate().collect();
        indexed.sort_by(|(ia, a), (ib, b)| {
            if err.is_some() {
                return ia.cmp(ib);
            }
            let ord = if matches!(a, Value::Instance(_)) {
                match host.invoke_method(a, "compareTo", std::slice::from_ref(b), *out) {
                    Some(Ok(Value::Int(n))) => i32_to_ordering(n),
                    Some(Err(e)) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                    _ => match compare_values(a, b) {
                        Ok(o) => o,
                        Err(e) => {
                            err = Some(e);
                            std::cmp::Ordering::Equal
                        }
                    },
                }
            } else {
                match compare_values(a, b) {
                    Ok(o) => o,
                    Err(e) => {
                        err = Some(e);
                        std::cmp::Ordering::Equal
                    }
                }
            };
            if ord == std::cmp::Ordering::Equal {
                ia.cmp(ib)
            } else {
                ord
            }
        });
        if let Some(e) = err {
            return Err(e);
        }
        for (slot, (_, v)) in buf[from..to].iter_mut().zip(indexed) {
            *slot = v;
        }
    } else {
        buf[from..to].sort_by(|a, b| {
            if err.is_some() {
                return std::cmp::Ordering::Equal;
            }
            match compare_values(a, b) {
                Ok(o) => o,
                Err(e) => {
                    err = Some(e);
                    std::cmp::Ordering::Equal
                }
            }
        });
        if let Some(e) = err {
            return Err(e);
        }
    }
    *items.borrow_mut() = buf;
    Ok(Value::Unit)
}

/// `Array<T>.sortWith(comparator, fromIndex = 0, toIndex = size)` —
/// in-place stable sort ordered by the supplied `Comparator` (klio's
/// `Value::Comparator`, an interpreted SAM, or a bare callable), returns
/// `Unit`. Like `sort`, this is the missing actual that `sortedWith` /
/// `sortedArrayWith` and the `*Descending` reverse-order variants
/// delegate to.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub(crate) fn array_sort_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items.clone(),
        _ => {
            return Err(RuntimeError::Type(
                "sortWith requires an array receiver".into(),
            ));
        }
    };
    let comparator = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("sortWith expects (comparator, ...)".into()))?;
    let len = items.borrow().len() as i64;
    let from = array_opt_index(ctx, 2, 0, "sortWith")?;
    let to = array_opt_index(ctx, 3, len, "sortWith")?;
    if from < 0 || to > len || from > to {
        return Err(index_oob(format!(
            "sortWith: range [{from}, {to}) out of bounds for length {len}"
        )));
    }
    let (from, to) = (from as usize, to as usize);
    let mut buf: Vec<Value> = items.borrow().clone();
    let mut err: Option<RuntimeError> = None;
    {
        let CallCtx { out, host, .. } = ctx;
        // Stable, index-aware sort so equal elements keep input order
        // and a comparator error short-circuits deterministically.
        let mut indexed: Vec<(usize, Value)> = buf[from..to].iter().cloned().enumerate().collect();
        indexed.sort_by(|(ia, a), (ib, b)| {
            if err.is_some() {
                return ia.cmp(ib);
            }
            match invoke_comparator_compare(*host, &comparator, a, b, *out) {
                Ok(n) => {
                    let ord = i64::cmp(&n, &0);
                    if ord == std::cmp::Ordering::Equal {
                        ia.cmp(ib)
                    } else {
                        ord
                    }
                }
                Err(e) => {
                    err = Some(e);
                    ia.cmp(ib)
                }
            }
        });
        if let Some(e) = err {
            return Err(e);
        }
        for (slot, (_, v)) in buf[from..to].iter_mut().zip(indexed) {
            *slot = v;
        }
    }
    *items.borrow_mut() = buf;
    Ok(Value::Unit)
}

// Kotlin Long.toDouble() loses precision past 2^53.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn array_sum_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    let mut int_acc: i64 = 0;
    let mut dbl_acc: f64 = 0.0;
    let mut as_double = false;
    for v in &items {
        match v {
            Value::Int(_) | Value::Long(_) | Value::Short(_) | Value::Byte(_) => {
                int_acc += v.as_i64().unwrap_or(0);
            }
            Value::Double(d) => {
                if !as_double {
                    dbl_acc = int_acc as f64;
                    as_double = true;
                }
                dbl_acc += *d;
            }
            Value::Float(f) => {
                if !as_double {
                    dbl_acc = int_acc as f64;
                    as_double = true;
                }
                dbl_acc += f64::from(*f);
            }
            _ => return Err(RuntimeError::Type(format!("{what}: non-numeric element"))),
        }
    }
    if as_double {
        Ok(Value::Double(dbl_acc))
    } else {
        Ok(Value::new_int(int_acc))
    }
}

pub(crate) fn array_sum_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_sum_impl(ctx, "Array.sum")
}

// Kotlin Long/length toDouble() loses precision past 2^53.
#[allow(clippy::cast_precision_loss)]
pub(crate) fn array_average_impl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type("Array.average requires a receiver".into()))?,
        "Array.average",
    )?;
    if items.is_empty() {
        return Ok(Value::Double(f64::NAN));
    }
    let mut acc: f64 = 0.0;
    for v in &items {
        let n: f64 = match v {
            Value::Int(_) | Value::Long(_) | Value::Short(_) | Value::Byte(_) => {
                v.as_i64().unwrap_or(0) as f64
            }
            Value::Double(d) => *d,
            Value::Float(f) => f64::from(*f),
            _ => {
                return Err(RuntimeError::Type(
                    "Array.average: non-numeric element".into(),
                ));
            }
        };
        acc += n;
    }
    Ok(Value::Double(acc / items.len() as f64))
}

pub(crate) fn array_max_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    if items.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new(format!("{what}: empty"))),
            cause: None,
        }));
    }
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Greater {
            best = v.clone();
        }
    }
    Ok(best)
}

pub(crate) fn array_max(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_max_impl(ctx, "Array.max")
}

pub(crate) fn array_min_impl(ctx: &mut CallCtx, what: &str) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type(format!("{what} requires a receiver")))?,
        what,
    )?;
    if items.is_empty() {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new(format!("{what}: empty"))),
            cause: None,
        }));
    }
    let mut best = items[0].clone();
    for v in items.iter().skip(1) {
        if compare_values(v, &best)? == std::cmp::Ordering::Less {
            best = v.clone();
        }
    }
    Ok(best)
}

pub(crate) fn array_min(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    array_min_impl(ctx, "Array.min")
}

pub(crate) fn coll_set_sorted(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.sorted")?;
    let mut copy: Vec<Value> = it.borrow().clone();
    let mut err: Option<RuntimeError> = None;
    copy.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(a, b) {
            Ok(o) => o,
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_list(copy, false))
}

pub(crate) fn coll_set_sorted_descending(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = coll_set_sorted(ctx)?;
    let Value::List { items, .. } = v else {
        unreachable!()
    };
    let mut out: Vec<Value> = items.borrow().clone();
    out.reverse();
    Ok(make_list(out, false))
}

pub(crate) fn coll_set_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("Set.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}
pub(crate) fn coll_mut_set_add(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.add")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("add requires an argument".into()));
    };
    let mut borrow = it.borrow_mut();
    if borrow.iter().any(|v| Value::structural_eq_boxed(v, arg)) {
        return Ok(Value::Bool(false));
    }
    borrow.push(arg.clone());
    Ok(Value::Bool(true))
}
pub(crate) fn coll_mut_set_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.remove")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("remove requires an argument".into()));
    };
    let removed = {
        let mut borrow = it.borrow_mut();
        if let Some(pos) = borrow
            .iter()
            .position(|v| Value::structural_eq_boxed(v, arg))
        {
            borrow.remove(pos);
            true
        } else {
            false
        }
    };
    if removed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(removed))
}
pub(crate) fn coll_mut_set_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    recv_set_items(ctx.args, "MutableSet.clear")?
        .borrow_mut()
        .clear();
    sync_map_view(&ctx.args[0]);
    Ok(Value::Unit)
}
pub(crate) fn coll_mut_set_remove_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.removeAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. } | Value::Array { items, .. }) => {
            items.borrow().clone()
        }
        _ => return Err(RuntimeError::Type("removeAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| !other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}
pub(crate) fn coll_mut_set_retain_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.retainAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. } | Value::Array { items, .. }) => {
            items.borrow().clone()
        }
        _ => return Err(RuntimeError::Type("retainAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}

// ----- Map helpers -----

pub(crate) fn recv_map_entries(
    args: &[Value],
    what: &str,
) -> Result<ObjRef<Vec<(Value, Value)>>, RuntimeError> {
    match args.first() {
        Some(Value::Map { entries, .. }) => Ok(entries.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a Map receiver"
        ))),
    }
}

pub(crate) fn coll_map_size(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(
        recv_map_entries(ctx.args, "Map.size")?.borrow().len(),
    ))
}
pub(crate) fn coll_map_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(
        recv_map_entries(ctx.args, "Map.isEmpty")?
            .borrow()
            .is_empty(),
    ))
}
pub(crate) fn coll_map_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(
        !recv_map_entries(ctx.args, "Map.isNotEmpty")?
            .borrow()
            .is_empty(),
    ))
}
pub(crate) fn coll_map_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.get")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("get requires a key".into()))?;
    Ok(map_key_index(ctx, &entries, &key)
        .and_then(|i| entries.borrow().get(i).map(|(_, v)| v.clone()))
        .unwrap_or(Value::Null))
}
pub(crate) fn coll_map_contains_key(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsKey")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("containsKey requires a key".into()))?;
    Ok(Value::Bool(map_key_index(ctx, &entries, &key).is_some()))
}
pub(crate) fn coll_map_contains_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.containsValue")?;
    let Some(value) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("containsValue requires a value".into()));
    };
    Ok(Value::Bool(
        entries
            .borrow()
            .iter()
            .any(|(_, v)| Value::structural_eq_boxed(v, value)),
    ))
}
pub(crate) fn coll_map_keys(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.keys")?;
    let keys: Vec<Value> = entries.borrow().iter().map(|(k, _)| k.clone()).collect();
    Ok(Value::Set {
        items: ObjRef::new(keys),
        mutable: true,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Keys,
        })),
    })
}
pub(crate) fn coll_map_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.values")?;
    let values: Vec<Value> = entries.borrow().iter().map(|(_, v)| v.clone()).collect();
    Ok(Value::List {
        items: ObjRef::new(values),
        mutable: true,
        enum_class: None,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Values,
        })),
    })
}
pub(crate) fn coll_map_entries(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.entries")?;
    let map_entries: Vec<Value> = entries
        .borrow()
        .iter()
        .map(|(k, v)| Value::MapEntry {
            key: Box::new(k.clone()),
            value: Box::new(v.clone()),
            backing: Some(entries.clone()),
        })
        .collect();
    Ok(Value::Set {
        items: ObjRef::new(map_entries),
        mutable: true,
        backing: Some(Box::new(klio_runtime::MapBacking {
            entries,
            kind: klio_runtime::MapViewKind::Entries,
        })),
    })
}
pub(crate) fn coll_map_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("Map.toString requires a receiver".into()))?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}
pub(crate) fn coll_mut_map_put(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.put")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("put requires a key".into()))?;
    let value = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("put requires a value".into()))?;
    if let Some(i) = map_key_index(ctx, &entries, &key) {
        let mut borrow = entries.borrow_mut();
        let prev = std::mem::replace(&mut borrow[i].1, value);
        Ok(prev)
    } else {
        entries.borrow_mut().push((key, value));
        Ok(Value::Null)
    }
}
pub(crate) fn coll_mut_map_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.remove")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("remove requires a key".into()))?;
    if let Some(pos) = map_key_index(ctx, &entries, &key) {
        let (_, v) = entries.borrow_mut().remove(pos);
        Ok(v)
    } else {
        Ok(Value::Null)
    }
}
pub(crate) fn coll_mut_map_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    recv_map_entries(ctx.args, "MutableMap.clear")?
        .borrow_mut()
        .clear();
    Ok(Value::Unit)
}

/// Shared accessor: the entries `ObjRef` of a `Value::Map` receiver.
pub(crate) fn mut_map_entries_rc(
    recv: &Value,
    who: &str,
) -> Result<ObjRef<Vec<(Value, Value)>>, RuntimeError> {
    match recv {
        Value::Map { entries, .. } => Ok(entries.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{who} requires a MutableMap receiver"
        ))),
    }
}

pub(crate) fn map_find(entries: &ObjRef<Vec<(Value, Value)>>, key: &Value) -> Option<Value> {
    entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
        .map(|(_, v)| v.clone())
}

/// Index of `key` in a map's entries, honoring a key instance's custom
/// `equals` — Kotlin Map lookup uses the key's `equals`, not structural
/// identity (e.g. ktor's case-folding `CaseInsensitiveString` keys).
/// Primitive/builtin search keys take the fast structural path; only a
/// class-instance key invokes `equals` through the host. The keys are
/// snapshotted first so invoking `equals` can't conflict with the
/// `entries` borrow.
pub(crate) fn map_key_index(
    ctx: &mut CallCtx,
    entries: &ObjRef<Vec<(Value, Value)>>,
    key: &Value,
) -> Option<usize> {
    if !matches!(key, Value::Instance(_)) {
        return entries
            .borrow()
            .iter()
            .position(|(k, _)| Value::structural_eq_boxed(k, key));
    }
    let keys: Vec<Value> = entries.borrow().iter().map(|(k, _)| k.clone()).collect();
    let CallCtx { out, host, .. } = ctx;
    for (i, k) in keys.iter().enumerate() {
        match host.invoke_method(k, "equals", std::slice::from_ref(key), *out) {
            Some(Ok(Value::Bool(true))) => return Some(i),
            Some(Ok(Value::Bool(false))) => {}
            _ => {
                if Value::structural_eq_boxed(k, key) {
                    return Some(i);
                }
            }
        }
    }
    None
}

pub(crate) fn map_set(entries: &ObjRef<Vec<(Value, Value)>>, key: Value, value: Value) {
    let mut b = entries.borrow_mut();
    if let Some(slot) = b
        .iter_mut()
        .find(|(k, _)| Value::structural_eq_boxed(k, &key))
    {
        slot.1 = value;
    } else {
        b.push((key, value));
    }
}

pub(crate) fn map_remove_key(entries: &ObjRef<Vec<(Value, Value)>>, key: &Value) {
    let mut b = entries.borrow_mut();
    if let Some(pos) = b
        .iter()
        .position(|(k, _)| Value::structural_eq_boxed(k, key))
    {
        b.remove(pos);
    }
}

/// `merge(key, value) { old, new -> … }`: insert `value` if absent, else store
/// the remapping result (or remove the key if it returns null). Returns the new
/// value, or null if removed.
pub(crate) fn map_merge(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "merge")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("merge requires a key".into()))?;
    let value = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("merge requires a value".into()))?;
    let block = ctx
        .args
        .get(3)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("merge requires a remapping block".into()))?;
    let existing = map_find(&entries, &key);
    let CallCtx { out, host, .. } = ctx;
    let new_val = match existing {
        None => value,
        Some(old) => host.invoke_callable(&block, &[old, value], *out)?,
    };
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
}

/// `putIfAbsent(key, value)`: store only if absent; return the previous value
/// (or null).
pub(crate) fn map_put_if_absent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "putIfAbsent")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("putIfAbsent requires a key".into()))?;
    let value = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("putIfAbsent requires a value".into()))?;
    if let Some(old) = map_find(&entries, &key) {
        Ok(old)
    } else {
        map_set(&entries, key, value);
        Ok(Value::Null)
    }
}

/// `replace(key, value)`: replace only if the key is present; return the
/// previous value (or null). The 3-arg `replace(key, old, new): Boolean` form
/// is handled when a third arg is supplied.
pub(crate) fn map_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "replace")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("replace requires a key".into()))?;
    if ctx.args.len() >= 4 {
        // replace(key, oldValue, newValue): Boolean
        let old = ctx.args[2].clone();
        let new = ctx.args[3].clone();
        match map_find(&entries, &key) {
            Some(cur) if Value::structural_eq_boxed(&cur, &old) => {
                map_set(&entries, key, new);
                Ok(Value::Bool(true))
            }
            _ => Ok(Value::Bool(false)),
        }
    } else {
        let value = ctx
            .args
            .get(2)
            .cloned()
            .ok_or_else(|| RuntimeError::Arity("replace requires a value".into()))?;
        match map_find(&entries, &key) {
            Some(old) => {
                map_set(&entries, key, value);
                Ok(old)
            }
            None => Ok(Value::Null),
        }
    }
}

/// `computeIfAbsent(key) { key -> value }`: compute & store a value only if the
/// key is absent; returns the present-or-computed value.
pub(crate) fn map_compute_if_absent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "computeIfAbsent")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("computeIfAbsent requires a key".into()))?;
    if let Some(v) = map_find(&entries, &key) {
        return Ok(v);
    }
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("computeIfAbsent requires a block".into()))?;
    let CallCtx { out, host, .. } = ctx;
    let v = host.invoke_callable(&block, std::slice::from_ref(&key), *out)?;
    map_set(&entries, key, v.clone());
    Ok(v)
}

/// `computeIfPresent(key) { key, old -> new? }`: recompute only if present;
/// remove on null. Returns the new value (or null).
pub(crate) fn map_compute_if_present(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "computeIfPresent")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("computeIfPresent requires a key".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("computeIfPresent requires a block".into()))?;
    let Some(old) = map_find(&entries, &key) else {
        return Ok(Value::Null);
    };
    let CallCtx { out, host, .. } = ctx;
    let new_val = host.invoke_callable(&block, &[key.clone(), old], *out)?;
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
}

/// `compute(key) { key, old? -> new? }`: recompute from the (possibly null)
/// current value; remove on null. Returns the new value (or null).
pub(crate) fn map_compute(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = mut_map_entries_rc(&ctx.args[0].clone(), "compute")?;
    let key = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("compute requires a key".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("compute requires a block".into()))?;
    let old = map_find(&entries, &key).unwrap_or(Value::Null);
    let CallCtx { out, host, .. } = ctx;
    let new_val = host.invoke_callable(&block, &[key.clone(), old], *out)?;
    if matches!(new_val, Value::Null) {
        map_remove_key(&entries, &key);
    } else {
        map_set(&entries, key, new_val.clone());
    }
    Ok(new_val)
}

// ----- Pair members -----

pub(crate) fn recv_pair<'a>(args: &'a [Value], what: &str) -> Result<&'a Value, RuntimeError> {
    args.first()
        .filter(|v| matches!(v, Value::Pair(_, _)))
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a Pair receiver")))
}
pub(crate) fn pair_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(a, _) = recv_pair(ctx.args, "Pair.first")? else {
        unreachable!()
    };
    Ok((**a).clone())
}
pub(crate) fn pair_second(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(_, b) = recv_pair(ctx.args, "Pair.second")? else {
        unreachable!()
    };
    Ok((**b).clone())
}
pub(crate) fn pair_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_pair(ctx.args, "Pair.toString")?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}

// ============================================================
// Additional List ops
// ============================================================

pub(crate) fn coll_list_flatten(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.flatten")?;
    let mut out: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        match v {
            Value::List { items, .. } | Value::Set { items, .. } => {
                out.extend(items.borrow().clone());
            }
            other => {
                return Err(RuntimeError::Type(format!(
                    "flatten requires nested collections, got {other:?}"
                )));
            }
        }
    }
    Ok(make_list(out, false))
}

pub(crate) fn coll_list_unzip(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.unzip")?;
    let mut firsts: Vec<Value> = Vec::new();
    let mut seconds: Vec<Value> = Vec::new();
    for v in it.borrow().iter() {
        let Value::Pair(a, b) = v else {
            return Err(RuntimeError::Type("unzip requires List<Pair<A, B>>".into()));
        };
        firsts.push((**a).clone());
        seconds.push((**b).clone());
    }
    Ok(Value::Pair(
        Box::new(make_list(firsts, false)),
        Box::new(make_list(seconds, false)),
    ))
}

pub(crate) fn coll_list_contains_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.containsAll")?;
    let other = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. }) => items.borrow().clone(),
        _ => {
            return Err(RuntimeError::Type(
                "containsAll requires a collection".into(),
            ));
        }
    };
    let me = it.borrow();
    Ok(Value::Bool(other.iter().all(|o| {
        me.iter().any(|m| Value::structural_eq_boxed(m, o))
    })))
}

pub(crate) fn coll_list_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toList")?;
    Ok(make_list(it.borrow().clone(), false))
}

pub(crate) fn coll_list_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toMutableList")?;
    Ok(make_list(it.borrow().clone(), true))
}

pub(crate) fn coll_list_to_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toSet")?;
    Ok(make_set(it.borrow().clone(), false))
}

pub(crate) fn coll_list_to_mutable_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.toMutableSet")?;
    Ok(make_set(it.borrow().clone(), true))
}

pub(crate) fn coll_list_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "List.withIndex")?;
    let indexed: Vec<Value> = it
        .borrow()
        .iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v.clone())))
        .collect();
    Ok(make_list(indexed, false))
}

pub(crate) fn coll_array_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let items = iterable_items(
        ctx.args
            .first()
            .ok_or_else(|| RuntimeError::Type("Array.withIndex requires a receiver".into()))?,
        "Array.withIndex",
    )?;
    let indexed: Vec<Value> = items
        .into_iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v)))
        .collect();
    Ok(make_list(indexed, false))
}

pub(crate) fn coll_mut_list_add_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.addAll")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("addAll requires an argument".into()));
    };
    let to_add: Vec<Value> = match arg {
        Value::List { items, .. } | Value::Set { items, .. } => items.borrow().clone(),
        other => {
            return Err(RuntimeError::Type(format!(
                "addAll requires a collection, got {other:?}"
            )));
        }
    };
    let changed = !to_add.is_empty();
    it.borrow_mut().extend(to_add);
    Ok(Value::Bool(changed))
}

pub(crate) fn coll_mut_list_remove(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.remove")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("remove requires an argument".into()));
    };
    let removed = {
        let mut b = it.borrow_mut();
        if let Some(pos) = b.iter().position(|v| Value::structural_eq_boxed(v, arg)) {
            b.remove(pos);
            true
        } else {
            false
        }
    };
    if removed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(removed))
}

pub(crate) fn coll_mut_list_remove_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.removeAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("removeAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| !other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}

pub(crate) fn coll_mut_list_retain_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.retainAll")?;
    let other: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("retainAll requires a collection".into())),
    };
    let changed = {
        let mut b = it.borrow_mut();
        let before = b.len();
        b.retain(|v| other.iter().any(|o| Value::structural_eq_boxed(v, o)));
        b.len() != before
    };
    if changed {
        sync_map_view(&ctx.args[0]);
    }
    Ok(Value::Bool(changed))
}

// Index is bounds-checked >= 0 before the usize cast.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn coll_mut_list_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "MutableList.set")?;
    let Some(Value::Int(i)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("set requires an Int index".into()));
    };
    let Some(value) = ctx.args.get(2) else {
        return Err(RuntimeError::Arity("set requires (index, value)".into()));
    };
    let mut b = it.borrow_mut();
    if *i < 0 || (*i as usize) >= b.len() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("Index {i} out of bounds for length {}", b.len())),
        )));
    }
    let prev = std::mem::replace(&mut b[*i as usize], value.clone());
    Ok(prev)
}

// ============================================================
// Additional Set ops
// ============================================================

pub(crate) fn coll_set_contains_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.containsAll")?;
    let other = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. }) => items.borrow().clone(),
        _ => {
            return Err(RuntimeError::Type(
                "containsAll requires a collection".into(),
            ));
        }
    };
    let me = it.borrow();
    Ok(Value::Bool(other.iter().all(|o| {
        me.iter().any(|m| Value::structural_eq_boxed(m, o))
    })))
}

pub(crate) fn coll_set_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toList")?;
    Ok(make_list(it.borrow().clone(), false))
}

pub(crate) fn coll_set_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toMutableList")?;
    Ok(make_list(it.borrow().clone(), true))
}

pub(crate) fn coll_set_to_set_(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toSet")?;
    Ok(make_set(it.borrow().clone(), false))
}

pub(crate) fn coll_set_to_mutable_set_(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.toMutableSet")?;
    Ok(make_set(it.borrow().clone(), true))
}

pub(crate) fn coll_set_with_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "Set.withIndex")?;
    let indexed: Vec<Value> = it
        .borrow()
        .iter()
        .enumerate()
        .map(|(i, v)| Value::Pair(Box::new(Value::new_int(i)), Box::new(v.clone())))
        .collect();
    Ok(make_list(indexed, false))
}

pub(crate) fn coll_mut_set_add_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "MutableSet.addAll")?;
    let to_add: Vec<Value> = match ctx.args.get(1) {
        Some(Value::List { items, .. } | Value::Set { items, .. }) => items.borrow().clone(),
        _ => return Err(RuntimeError::Type("addAll requires a collection".into())),
    };
    let mut b = it.borrow_mut();
    let mut changed = false;
    for v in to_add {
        if !b.iter().any(|x| Value::structural_eq_boxed(x, &v)) {
            b.push(v);
            changed = true;
        }
    }
    Ok(Value::Bool(changed))
}

// ============================================================
// Additional Map ops
// ============================================================

pub(crate) fn coll_map_get_or_default(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.getOrDefault")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity(
            "getOrDefault requires (key, default)".into(),
        ));
    };
    let Some(default) = ctx.args.get(2) else {
        return Err(RuntimeError::Arity(
            "getOrDefault requires (key, default)".into(),
        ));
    };
    Ok(entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
        .map_or_else(|| default.clone(), |(_, v)| v.clone()))
}

pub(crate) fn coll_map_get_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.getValue")?;
    let Some(key) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("getValue requires a key".into()));
    };
    entries
        .borrow()
        .iter()
        .find(|(k, _)| Value::structural_eq_boxed(k, key))
        .map(|(_, v)| v.clone())
        .ok_or_else(|| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NoSuchElementException",
                Some(format!("Key {key} is missing in the map.")),
            ))
        })
}

pub(crate) fn coll_map_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "Map.toList")?;
    let pairs: Vec<Value> = entries
        .borrow()
        .iter()
        .map(|(k, v)| Value::Pair(Box::new(k.clone()), Box::new(v.clone())))
        .collect();
    Ok(make_list(pairs, false))
}

/// `Map.toSortedMap()` / `toSortedMap(comparator)` — a map whose entries are
/// ordered by key. klio's Map preserves insertion order, so we return a new
/// Map with entries pre-sorted by key. The no-arg form sorts by natural key
/// order; a `naturalOrder()`/`reverseOrder()` Comparator is honored directly.
pub(crate) fn coll_map_to_sorted_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Type("toSortedMap requires a Map receiver".into()))?;
    let mut entries = map_entries_clone(recv, "toSortedMap")?;
    // Optional comparator: support naturalOrder/reverseOrder (no selector
    // steps). A selector-based Comparator (compareBy { … }) would need to run
    // the selector lambda per key; not yet handled.
    let descending = match ctx.args.get(1) {
        None => false,
        Some(Value::Comparator { steps, descending }) if steps.is_empty() => *descending,
        Some(Value::Comparator { .. }) => {
            return Err(RuntimeError::Type(
                "toSortedMap with a selector comparator is not yet supported".into(),
            ));
        }
        Some(_) => {
            return Err(RuntimeError::Type(
                "toSortedMap expects a Comparator argument".into(),
            ));
        }
    };
    let mut err: Option<RuntimeError> = None;
    entries.sort_by(|a, b| {
        if err.is_some() {
            return std::cmp::Ordering::Equal;
        }
        match compare_values(&a.0, &b.0) {
            Ok(o) => {
                if descending {
                    o.reverse()
                } else {
                    o
                }
            }
            Err(e) => {
                err = Some(e);
                std::cmp::Ordering::Equal
            }
        }
    });
    if let Some(e) = err {
        return Err(e);
    }
    Ok(make_map(entries, false))
}

pub(crate) fn coll_map_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() >= 2 {
        let items = iterable_items(&ctx.args[0], "count")?;
        let block = ctx.args[1].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut n = 0i64;
        for v in items {
            if matches!(
                host.invoke_callable(&block, std::slice::from_ref(&v), *out)?,
                Value::Bool(true)
            ) {
                n += 1;
            }
        }
        return Ok(Value::new_int(n));
    }
    let entries = recv_map_entries(ctx.args, "Map.count")?;
    Ok(Value::new_int(entries.borrow().len()))
}

pub(crate) fn coll_mut_map_put_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let entries = recv_map_entries(ctx.args, "MutableMap.putAll")?;
    let Some(arg) = ctx.args.get(1) else {
        return Err(RuntimeError::Arity("putAll requires a Map".into()));
    };
    // Upstream has four putAll overloads: putAll(Map) and
    // putAll(Array/Iterable/Sequence<Pair>). Accept a Map's entries
    // directly, or any Pair-bearing collection.
    let to_add: Vec<(Value, Value)> = match arg {
        Value::Map { entries, .. } => entries.borrow().clone(),
        Value::Array { items, .. } | Value::List { items, .. } | Value::Set { items, .. } => {
            pairs_from_values(&items.borrow(), "putAll")?
        }
        Value::Sequence(_) => {
            let seq = ctx.args[1].clone();
            let CallCtx { out, host, .. } = ctx;
            let items = materialise_sequence(&seq, *host, *out)?;
            pairs_from_values(&items, "putAll")?
        }
        _ => {
            return Err(RuntimeError::Type(
                "putAll requires a Map or a collection of Pairs".into(),
            ));
        }
    };
    let mut b = entries.borrow_mut();
    for (k, v) in to_add {
        if let Some(slot) = b
            .iter_mut()
            .find(|(kk, _)| Value::structural_eq_boxed(kk, &k))
        {
            slot.1 = v;
        } else {
            b.push((k, v));
        }
    }
    Ok(Value::Unit)
}

pub(crate) fn coll_mut_map_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Same as put but returns Unit (operator form `m[k] = v`).
    let _ = coll_mut_map_put(ctx)?;
    Ok(Value::Unit)
}

// ============================================================
// Pair extras
// ============================================================

pub(crate) fn pair_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Pair(a, b) = recv_pair(ctx.args, "Pair.toList")? else {
        unreachable!()
    };
    Ok(make_list(vec![(**a).clone(), (**b).clone()], false))
}

// ============================================================
// Triple
// ============================================================

pub(crate) fn recv_triple<'a>(args: &'a [Value], what: &str) -> Result<&'a Value, RuntimeError> {
    args.first()
        .filter(|v| matches!(v, Value::Triple(_, _, _)))
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a Triple receiver")))
}

pub(crate) fn coll_triple_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [a, b, c] => Ok(Value::Triple(
            Box::new(a.clone()),
            Box::new(b.clone()),
            Box::new(c.clone()),
        )),
        _ => Err(RuntimeError::Arity("Triple expects 3 arguments".into())),
    }
}

pub(crate) fn triple_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(a, _, _) = recv_triple(ctx.args, "Triple.first")? else {
        unreachable!()
    };
    Ok((**a).clone())
}
pub(crate) fn triple_second(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(_, b, _) = recv_triple(ctx.args, "Triple.second")? else {
        unreachable!()
    };
    Ok((**b).clone())
}
pub(crate) fn triple_third(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(_, _, c) = recv_triple(ctx.args, "Triple.third")? else {
        unreachable!()
    };
    Ok((**c).clone())
}
pub(crate) fn triple_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_triple(ctx.args, "Triple.toString")?;
    Ok(Value::String(Arc::new(format!("{v}"))))
}
pub(crate) fn triple_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Value::Triple(a, b, c) = recv_triple(ctx.args, "Triple.toList")? else {
        unreachable!()
    };
    Ok(make_list(
        vec![(**a).clone(), (**b).clone(), (**c).clone()],
        false,
    ))
}
