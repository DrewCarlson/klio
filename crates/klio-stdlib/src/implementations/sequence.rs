use super::{
    Arc, CallCtx, ObjRef, RuntimeError, Value, make_list, make_set, materialise_sequence,
    materialise_sequence_bounded, range_iter_int, recv_list_items, recv_set_items, recv_string,
};

// ============================================================
// Sequence (eager; same observable output as List)
// ============================================================

/// Build an items-only Sequence from a `Vec`. Used by `asSequence`,
/// `sequenceOf`, and `emptySequence`.
pub(crate) fn make_sequence(items: Vec<Value>) -> Value {
    Value::Sequence(Arc::new(klio_runtime::SequenceData {
        source: klio_runtime::SequenceSource::Items(Arc::new(items)),
        ops: Vec::new(),
    }))
}

/// `sequence { yield(...) ; yieldAll(...) }` builder. klio runs the
/// `suspend SequenceScope<T>.() -> Unit` block eagerly: a host
/// `SequenceScope` instance carries a shared mutable buffer that the
/// `yield`/`yieldAll` intrinsics append to; the collected items become
/// a `Value::Sequence`. Faithful for finite builders (the common case);
/// an unbounded `while (true) { yield(..) }` would grow the buffer and
/// is bounded by the dev memory guard rather than truly lazy.
pub(crate) fn seq_scope_buffer(scope: &Value) -> Option<ObjRef<Vec<Value>>> {
    if let Value::Instance(inst) = scope
        && let Some(Value::List { items, .. }) = inst.borrow().get("__seq_buffer")
    {
        return Some(items);
    }
    None
}

pub(crate) fn run_seq_builder(
    ctx: &mut CallCtx,
    who: &str,
) -> Result<ObjRef<Vec<Value>>, RuntimeError> {
    let block = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity(format!("{who} expects a block")))?;
    let buffer: ObjRef<Vec<Value>> = ObjRef::new(Vec::new());
    let scope = {
        let id = ctx.host.alloc_instance_id();
        ctx.host.new_synth_instance(
            "kotlin.sequences.SequenceScope",
            id,
            vec![(
                "__seq_buffer".to_string(),
                Value::List {
                    items: buffer.clone(),
                    mutable: true,
                    enum_class: None,
                    backing: None,
                },
            )],
        )
    };
    let CallCtx { out, host, .. } = ctx;
    host.invoke_callable_with_this(&block, &[], &scope, *out)?;
    Ok(buffer)
}

pub(crate) fn seq_builder(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = run_seq_builder(ctx, "sequence")?;
    let items = buffer.borrow().clone();
    Ok(make_sequence(items))
}

pub(crate) fn seq_iterator_builder(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = run_seq_builder(ctx, "iterator")?;
    let items = buffer.borrow().clone();
    Ok(Value::Iterator {
        items: ObjRef::new(items),
        pos: ObjRef::new(0),
        prim: None,
    })
}

pub(crate) fn seq_scope_yield(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = seq_scope_buffer(&ctx.args[0])
        .ok_or_else(|| RuntimeError::Type("yield: not a SequenceScope".into()))?;
    if let Some(v) = ctx.args.get(1) {
        buffer.borrow_mut().push(v.clone());
    }
    Ok(Value::Unit)
}

pub(crate) fn seq_scope_yield_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let buffer = seq_scope_buffer(&ctx.args[0])
        .ok_or_else(|| RuntimeError::Type("yieldAll: not a SequenceScope".into()))?;
    let elems: Vec<Value> = match ctx.args.get(1) {
        Some(
            Value::List { items, .. }
            | Value::Set { items, .. }
            | Value::Array { items, .. }
            | Value::Iterator { items, .. },
        ) => items.borrow().clone(),
        Some(Value::Sequence(_)) => {
            let seq = ctx.args[1].clone();
            let CallCtx { out, host, .. } = ctx;
            materialise_sequence(&seq, *host, *out)?
        }
        Some(other) => {
            return Err(RuntimeError::Type(format!(
                "yieldAll: expected an Iterable/Iterator/Sequence, got {other}"
            )));
        }
        None => return Ok(Value::Unit),
    };
    buffer.borrow_mut().extend(elems);
    Ok(Value::Unit)
}

pub(crate) fn seq_from_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_list_items(ctx.args, "asSequence")?;
    Ok(make_sequence(it.borrow().clone()))
}
pub(crate) fn seq_from_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let it = recv_set_items(ctx.args, "asSequence")?;
    Ok(make_sequence(it.borrow().clone()))
}
pub(crate) fn seq_from_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "asSequence")?;
    Ok(make_sequence(s.encode_utf16().map(Value::Char).collect()))
}
pub(crate) fn seq_from_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Range {
        start, end, step, ..
    }) = ctx.args.first()
    else {
        return Err(RuntimeError::Type("asSequence requires an IntRange".into()));
    };
    let items: Vec<Value> = range_iter_int(*start, *end, *step)
        .map(Value::new_int)
        .collect();
    Ok(make_sequence(items))
}
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn seq_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(ctx.args.to_vec()))
}
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn seq_empty(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(Vec::new()))
}

pub(crate) fn seq_generate_sequence(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use klio_runtime::{SequenceData, SequenceSource};
    match ctx.args {
        [lam @ (Value::Lambda { .. } | Value::IrClosure { .. })] => {
            Ok(Value::Sequence(Arc::new(SequenceData {
                source: SequenceSource::Generate {
                    seed: None,
                    next: Box::new(lam.clone()),
                },
                ops: Vec::new(),
            })))
        }
        [seed, lam @ (Value::Lambda { .. } | Value::IrClosure { .. })] => {
            let seeded = if matches!(seed, Value::Null) {
                None
            } else {
                Some(Box::new(seed.clone()))
            };
            Ok(Value::Sequence(Arc::new(SequenceData {
                source: SequenceSource::Generate {
                    seed: seeded,
                    next: Box::new(lam.clone()),
                },
                ops: Vec::new(),
            })))
        }
        _ => Err(RuntimeError::Type(
            "generateSequence expects `(seed, next)` or `(next)` with `next` a lambda".into(),
        )),
    }
}

/// Fast-path Sequence terminal ops handle the special case of an
/// `Items`-source Sequence with no ops. Anything more (intermediate ops,
/// generator sources) goes through `klio-interp`'s lazy materialize path.
pub(crate) fn recv_seq_eager(
    args: &[Value],
    what: &str,
) -> Result<Option<Arc<Vec<Value>>>, RuntimeError> {
    let Some(Value::Sequence(data)) = args.first() else {
        return Err(RuntimeError::Type(format!(
            "{what} requires a Sequence receiver"
        )));
    };
    if !data.ops.is_empty() {
        return Ok(None);
    }
    match &data.source {
        klio_runtime::SequenceSource::Items(items) => Ok(Some(Arc::clone(items))),
        klio_runtime::SequenceSource::Generate { .. } => Ok(None),
    }
}

pub(crate) fn seq_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toList")? else {
        // Has ops or a non-Items source — caller should have routed this
        // through the interpreter's lazy materializer.
        return Err(RuntimeError::Unimplemented(
            "Sequence.toList on a non-trivial source/op chain (dispatch via the interpreter)"
                .into(),
        ));
    };
    Ok(make_list((*items).clone(), false))
}
pub(crate) fn seq_to_mutable_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toMutableList")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.toMutableList on a non-trivial source/op chain".into(),
        ));
    };
    Ok(make_list((*items).clone(), true))
}
pub(crate) fn seq_to_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.toSet")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.toSet on a non-trivial source/op chain".into(),
        ));
    };
    Ok(make_set((*items).clone(), false))
}
pub(crate) fn seq_count_no_pred(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.count")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.count on a non-trivial source/op chain".into(),
        ));
    };
    Ok(Value::new_int(items.len()))
}
/// Append one more op to a Sequence, returning a new lazy Sequence value. Used
/// by predicate terminals (`first { p }` == `filter { p }.first()`) so they
/// short-circuit through the same bounded materializer rather than each
/// reimplementing the pull loop.
pub(crate) fn seq_with_extra_op(seq_val: &Value, op: klio_runtime::SeqOp) -> Value {
    match seq_val {
        Value::Sequence(d) => {
            let mut ops = d.ops.clone();
            ops.push(op);
            Value::Sequence(Arc::new(klio_runtime::SequenceData {
                source: d.source.clone(),
                ops,
            }))
        }
        other => other.clone(),
    }
}

/// The receiver Sequence, with a trailing `Filter(predicate)` op when the call
/// supplies one (the `first { p }` / `find { p }` / `any { p }` shape).
pub(crate) fn seq_with_optional_filter(ctx: &CallCtx, who: &str) -> Result<Value, RuntimeError> {
    let seq = ctx
        .args
        .first()
        .filter(|v| matches!(v, Value::Sequence(_)))
        .cloned()
        .ok_or_else(|| RuntimeError::Type(format!("{who} requires a Sequence receiver")))?;
    Ok(match ctx.args.get(1) {
        Some(pred) => seq_with_extra_op(&seq, klio_runtime::SeqOp::Filter(pred.clone())),
        None => seq,
    })
}

pub(crate) fn seq_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.first")?;
    let CallCtx { out, host, .. } = ctx;
    materialise_sequence_bounded(&target, *host, *out, Some(1))?
        .into_iter()
        .next()
        .ok_or_else(|| {
            RuntimeError::Thrown(Value::Exception {
                fqn: Arc::new("kotlin.NoSuchElementException".into()),
                message: Some(Arc::new(
                    "Sequence contains no element matching the predicate.".into(),
                )),
                cause: None,
            })
        })
}

pub(crate) fn seq_first_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.firstOrNull")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(materialise_sequence_bounded(&target, *host, *out, Some(1))?
        .into_iter()
        .next()
        .unwrap_or(Value::Null))
}

pub(crate) fn seq_any(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.any")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(Value::Bool(
        !materialise_sequence_bounded(&target, *host, *out, Some(1))?.is_empty(),
    ))
}

pub(crate) fn seq_none(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let target = seq_with_optional_filter(ctx, "Sequence.none")?;
    let CallCtx { out, host, .. } = ctx;
    Ok(Value::Bool(
        materialise_sequence_bounded(&target, *host, *out, Some(1))?.is_empty(),
    ))
}
pub(crate) fn seq_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(items) = recv_seq_eager(ctx.args, "Sequence.last")? else {
        return Err(RuntimeError::Unimplemented(
            "Sequence.last on a non-trivial source/op chain".into(),
        ));
    };
    items.last().cloned().ok_or_else(|| {
        RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.NoSuchElementException".into()),
            message: Some(Arc::new("Sequence is empty.".into())),
            cause: None,
        })
    })
}
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn seq_to_string(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Kotlin returns an opaque id like `kotlin.sequences.TransformingSequence@…`.
    // Stable parity for that string is meaningless (it embeds the heap
    // address), so we emit a deterministic placeholder. Programs that need
    // a useful value should call `.toList()` before printing.
    Ok(Value::String(Arc::new(
        "kotlin.sequences.Sequence".to_string(),
    )))
}

pub(crate) fn map_entry_key(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::MapEntry { key, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "Map.Entry.key requires a Map.Entry receiver".into(),
        ));
    };
    Ok((**key).clone())
}
pub(crate) fn map_entry_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::MapEntry { value, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "Map.Entry.value requires a Map.Entry receiver".into(),
        ));
    };
    Ok((**value).clone())
}
pub(crate) fn map_entry_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::MapEntry { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type(
            "Map.Entry.toString requires a Map.Entry receiver".into(),
        ));
    };
    Ok(Value::String(Arc::new(format!("{v}"))))
}
