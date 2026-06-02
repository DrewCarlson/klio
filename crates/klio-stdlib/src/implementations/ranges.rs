use super::{CallCtx, Value, RuntimeError, Arc, range_iter_int, make_list};

// ============================================================
// Range progressions
// ============================================================

pub(crate) fn ranges_down_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_int_args(ctx, "downTo")?;
    Ok(Value::Range { start: a, end: b, step: -1, kind: klio_runtime::RangeKind::Int })
}

pub(crate) fn ranges_until(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = pair_int_args(ctx, "until")?;
    Ok(Value::Range {
        start: a,
        end: b.saturating_sub(1),
        step: 1,
        kind: klio_runtime::RangeKind::Int,
    })
}

pub(crate) fn ranges_step(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Range { start, end, step, kind }, step_arg] if step_arg.is_integral() => {
            let n = step_arg.as_i64().unwrap();
            if n <= 0 {
                return Err(RuntimeError::Thrown(Value::Exception {
                    fqn: Arc::new("kotlin.IllegalArgumentException".into()),
                    message: Some(Arc::new(format!(
                        "Step must be positive, was: {n}."
                    ))),
                    cause: None,
                }));
            }
            let signed = if *step < 0 { -n } else { n };
            let normalized_end = normalize_progression_end(*start, *end, signed);
            Ok(Value::Range { start: *start, end: normalized_end, step: signed, kind: *kind })
        }
        _ => Err(RuntimeError::Type("step requires IntRange . step(Int)".into())),
    }
}

/// Match Kotlin's `IntProgression.fromClosedRange`: the stored `end` is the
/// last element that's actually reachable from `start` with the given
/// `step`. For `1..10 step 2` this normalizes 10 → 9 because 9 is the last
/// reachable value.
pub(crate) fn normalize_progression_end(start: i64, end: i64, step: i64) -> i64 {
    if step == 0 {
        return end;
    }
    if step > 0 {
        if start > end {
            return start - 1;
        }
        let diff = end - start;
        let rem = diff % step;
        end - rem
    } else {
        if start < end {
            return start + 1;
        }
        let diff = start - end;
        let mag = -step;
        let rem = diff % mag;
        end + rem
    }
}

pub(crate) fn pair_int_args(ctx: &CallCtx<'_>, what: &str) -> Result<(i64, i64), RuntimeError> {
    match ctx.args {
        [a, b] if a.is_integral() && b.is_integral() => {
            Ok((a.as_i64().unwrap(), b.as_i64().unwrap()))
        }
        _ => Err(RuntimeError::Type(format!("{what} requires two Int operands"))),
    }
}

pub(crate) fn range_endpoint(kind: klio_runtime::RangeKind, v: i64) -> Value {
    match kind {
        klio_runtime::RangeKind::Long => Value::Long(v),
        klio_runtime::RangeKind::Int => Value::Int(v as i32),
        klio_runtime::RangeKind::Char => Value::Char(v as u16),
    }
}

/// View a receiver as a range's `(start, end, step, kind)`.
///
/// klio represents a range two ways: the host `Value::Range`, and — when the
/// upstream `kotlin.ranges.{Int,Long,Char}{Range,Progression}` constructor is
/// invoked as a class (e.g. `Array<T>.indices`'s getter does `IntRange(0,
/// lastIndex)`) — a generic `Value::Instance` carrying the same `first`/`last`/
/// `step` fields. Range intrinsics accept either so an op like `reversed` works
/// regardless of which form a range value took, without a caller having to
/// normalize first.
pub(crate) fn as_range_view(v: &Value) -> Option<(i64, i64, i64, klio_runtime::RangeKind)> {
    use klio_runtime::RangeKind;
    match v {
        Value::Range { start, end, step, kind } => Some((*start, *end, *step, *kind)),
        Value::Instance(inst) => {
            let b = inst.borrow();
            let fqn = b.class.fqn.as_str();
            if !fqn.starts_with("kotlin.ranges.") {
                return None;
            }
            let kind = if fqn.contains("Long") {
                RangeKind::Long
            } else if fqn.contains("Char") {
                RangeKind::Char
            } else if fqn.contains("Int") {
                RangeKind::Int
            } else {
                return None;
            };
            // IntProgression stores first/last/step; IntRange also exposes
            // start/endInclusive — accept whichever the lowered fields carry.
            let num = |names: &[&str]| -> Option<i64> {
                for n in names {
                    if let Some(val) = b.get(n) {
                        if let Some(i) = val.as_i64() {
                            return Some(i);
                        }
                        if let Value::Char(c) = val {
                            return Some(i64::from(c));
                        }
                    }
                }
                None
            };
            let start = num(&["first", "start"])?;
            let end = num(&["last", "endInclusive"])?;
            let step = num(&["step"]).unwrap_or(1);
            Some((start, end, step, kind))
        }
        _ => None,
    }
}

pub(crate) fn range_view_arg(ctx: &CallCtx, op: &str) -> Result<(i64, i64, i64, klio_runtime::RangeKind), RuntimeError> {
    ctx.args
        .first()
        .and_then(as_range_view)
        .ok_or_else(|| RuntimeError::Type(format!("{op} requires a Range receiver")))
}

pub(crate) fn range_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, _end, _step, kind) = range_view_arg(ctx, "first")?;
    Ok(range_endpoint(kind, start))
}

pub(crate) fn range_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (_start, end, _step, kind) = range_view_arg(ctx, "last")?;
    Ok(range_endpoint(kind, end))
}

pub(crate) fn range_step_field(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (_start, _end, step, kind) = range_view_arg(ctx, "step")?;
    Ok(range_endpoint(kind, step.abs()))
}

pub(crate) fn range_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "toString")?;
    let r = Value::Range { start, end, step, kind };
    Ok(Value::String(Arc::new(format!("{r}"))))
}

pub(crate) fn range_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "contains")?;
    let Some(n) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Range.contains requires an Int argument".into()));
    };
    let (lo, hi) = if step > 0 { (start, end) } else { (end, start) };
    let in_bounds = n >= lo && n <= hi;
    if !in_bounds {
        return Ok(Value::Bool(false));
    }
    let s = step.abs();
    Ok(Value::Bool(((n - start) % s).abs() == 0 || s == 1))
}

pub(crate) fn range_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "isEmpty")?;
    let empty = if step > 0 { start > end } else { start < end };
    Ok(Value::Bool(empty))
}

pub(crate) fn range_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "reversed")?;
    Ok(Value::Range { start: end, end: start, step: -step, kind })
}

pub(crate) fn range_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "toList")?;
    let items: Vec<Value> = range_iter_int(start, end, step)
        .map(|v| range_endpoint(kind, v))
        .collect();
    Ok(make_list(items, false))
}

pub(crate) fn range_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, _kind) = range_view_arg(ctx, "count")?;
    let n = range_iter_int(start, end, step).count() as i64;
    Ok(Value::new_int(n))
}

pub(crate) fn range_sum(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (start, end, step, kind) = range_view_arg(ctx, "sum")?;
    let s: i64 = range_iter_int(start, end, step).sum();
    Ok(match kind {
        klio_runtime::RangeKind::Long => Value::Long(s),
        klio_runtime::RangeKind::Int => Value::new_int(s),
        klio_runtime::RangeKind::Char => Value::new_int(s),
    })
}

