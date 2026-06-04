use super::{
    Arc, CallCtx, ObjRef, RuntimeError, Value, char_unit_to_string, char_units_to_string,
    make_exception, utf16_len, utf16_unit_at,
};

// ============================================================
// StringBuilder
// ============================================================

pub(crate) fn sb_arg(args: &[Value], what: &str) -> Result<ObjRef<String>, RuntimeError> {
    match args.first() {
        Some(Value::StringBuilder(s)) => Ok(s.clone()),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a StringBuilder receiver"
        ))),
    }
}

/// `String()` / `String(chars: CharArray)` / `String(chars, offset, length)`
/// / `String(other: CharSequence)`. klio registers `String` as a host ctor so
/// these shapes don't hit a 0-arg-only declaration.
// offset/count are Int args clamped to be non-negative before use as usize.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        None => String::new(),
        // CharArray is a Value::Array, but some producers (e.g. toCharArray)
        // yield a Value::List of chars — accept either.
        Some(arr @ (Value::Array { .. } | Value::List { .. })) => {
            let (items, prim_is_byte) = match arr {
                Value::Array { items, prim } => (
                    items,
                    matches!(
                        prim,
                        Some(
                            klio_runtime::PrimitiveArrayKind::Byte
                                | klio_runtime::PrimitiveArrayKind::UByte
                        )
                    ),
                ),
                Value::List { items, .. } => (items, false),
                _ => unreachable!(),
            };
            let elems = items.borrow();
            let (start, count) = if ctx.args.len() >= 3 {
                let off = ctx.args[1].as_i64().unwrap_or(0).max(0) as usize;
                let cnt = ctx.args[2].as_i64().unwrap_or(0).max(0) as usize;
                (off, cnt)
            } else {
                (0, elems.len())
            };
            let end = start.saturating_add(count).min(elems.len());
            if start > elems.len() || end > elems.len() {
                return Err(RuntimeError::Thrown(make_exception(
                    "kotlin.IndexOutOfBoundsException",
                    Some(format!(
                        "offset {start}, count {count}, size {}",
                        elems.len()
                    )),
                )));
            }
            // `String(ByteArray[, offset, length][, charset])` decodes
            // bytes as UTF-8; `String(CharArray[, offset, count])` builds
            // from UTF-16 code units. `byteArrayOf` tags its array
            // `prim = Byte` even though the literal elements arrive as
            // `Int`, so key off the array kind (with an element-kind
            // fallback) rather than reading every slot as a NUL char.
            let is_bytes =
                prim_is_byte || matches!(elems.first(), Some(Value::Byte(_) | Value::UByte(_)));
            if is_bytes {
                let bytes: Vec<u8> = elems[start..end]
                    .iter()
                    .map(|v| match v {
                        Value::Byte(b) => *b as u8,
                        Value::UByte(b) => *b,
                        Value::Int(i) => *i as u8,
                        _ => 0,
                    })
                    .collect();
                String::from_utf8_lossy(&bytes).into_owned()
            } else {
                char_units_to_string(elems[start..end].iter().map(|v| match v {
                    Value::Char(c) => *c,
                    _ => 0u16,
                }))
            }
        }
        Some(Value::String(s)) => (**s).clone(),
        Some(Value::StringBuilder(sb)) => sb.borrow().clone(),
        Some(other) => format!("{other}"),
    };
    Ok(Value::String(Arc::new(s)))
}

// The capacity arg is a non-negative Int used as a usize reservation.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn string_builder_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let seed = match ctx.args {
        [] => String::new(),
        [Value::String(s)] => (**s).clone(),
        [Value::Int(n)] => {
            if *n < 0 {
                return Err(RuntimeError::Thrown(make_exception(
                    "kotlin.NegativeArraySizeException",
                    Some(format!("{n}")),
                )));
            }
            String::with_capacity(*n as usize)
        }
        _ => {
            return Err(RuntimeError::Type(
                "StringBuilder takes 0 or 1 argument".into(),
            ));
        }
    };
    Ok(Value::StringBuilder(ObjRef::new(seed)))
}

pub(crate) fn append_value(buf: &mut String, v: &Value) {
    match v {
        Value::Null => buf.push_str("null"),
        Value::String(s) => buf.push_str(s),
        Value::Char(c) => buf.push_str(&char_unit_to_string(*c)),
        other => {
            use std::fmt::Write;
            let _ = write!(buf, "{other}");
        }
    }
}

/// The UTF-16 units of a `CharArray` / `CharSequence` / `Char` argument,
/// for the range ops. Computed before borrowing the receiver so a
/// self-referential insert can't double-borrow.
fn value_to_utf16(v: &Value) -> Option<Vec<u16>> {
    match v {
        Value::String(s) => Some(s.encode_utf16().collect()),
        Value::StringBuilder(sb) => Some(sb.borrow().encode_utf16().collect()),
        Value::Char(u) => Some(vec![*u]),
        Value::Array { items, .. } => items
            .borrow()
            .iter()
            .map(|e| {
                if let Value::Char(u) = e {
                    Some(*u)
                } else {
                    None
                }
            })
            .collect(),
        _ => None,
    }
}

fn range_oob(msg: String) -> RuntimeError {
    RuntimeError::Thrown(make_exception("kotlin.IndexOutOfBoundsException", Some(msg)))
}

/// `StringBuilder.setRange(startIndex, endIndex, value: String)` — replace
/// the UTF-16 units in `[startIndex, endIndex)` with `value`. A bodyless
/// `expect` otherwise.
pub(crate) fn string_builder_set_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setRange")?;
    let start = ctx.args.get(1).and_then(Value::as_i64).unwrap_or(0);
    let end = ctx.args.get(2).and_then(Value::as_i64).unwrap_or(0);
    let value = ctx
        .args
        .get(3)
        .and_then(value_to_utf16)
        .ok_or_else(|| RuntimeError::Type("setRange value must be a String".into()))?;
    let mut buf = sb.borrow_mut();
    let mut units: Vec<u16> = buf.encode_utf16().collect();
    let len = units.len() as i64;
    if start < 0 || start > len || start > end || end > len {
        return Err(range_oob(format!(
            "startIndex: {start}, endIndex: {end}, length: {len}"
        )));
    }
    #[allow(clippy::cast_sign_loss)]
    units.splice(start as usize..end as usize, value);
    *buf = String::from_utf16_lossy(&units);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

/// `StringBuilder.appendRange(value, startIndex, endIndex)` — append
/// `value[startIndex, endIndex)` (CharArray or CharSequence). A bodyless
/// `expect` otherwise.
pub(crate) fn string_builder_append_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.appendRange")?;
    let value = ctx
        .args
        .get(1)
        .and_then(value_to_utf16)
        .ok_or_else(|| RuntimeError::Type("appendRange value must be a CharArray/CharSequence".into()))?;
    let start = ctx.args.get(2).and_then(Value::as_i64).unwrap_or(0);
    let end = ctx.args.get(3).and_then(Value::as_i64).unwrap_or(value.len() as i64);
    let vlen = value.len() as i64;
    if start < 0 || start > end || end > vlen {
        return Err(range_oob(format!(
            "startIndex: {start}, endIndex: {end}, size: {vlen}"
        )));
    }
    #[allow(clippy::cast_sign_loss)]
    let slice = &value[start as usize..end as usize];
    let mut buf = sb.borrow_mut();
    let mut units: Vec<u16> = buf.encode_utf16().collect();
    units.extend_from_slice(slice);
    *buf = String::from_utf16_lossy(&units);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

/// `StringBuilder.insertRange(index, value, startIndex, endIndex)` — insert
/// `value[startIndex, endIndex)` at `index`. A bodyless `expect` otherwise.
pub(crate) fn string_builder_insert_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.insertRange")?;
    let index = ctx.args.get(1).and_then(Value::as_i64).unwrap_or(0);
    let value = ctx
        .args
        .get(2)
        .and_then(value_to_utf16)
        .ok_or_else(|| RuntimeError::Type("insertRange value must be a CharArray/CharSequence".into()))?;
    let start = ctx.args.get(3).and_then(Value::as_i64).unwrap_or(0);
    let end = ctx.args.get(4).and_then(Value::as_i64).unwrap_or(value.len() as i64);
    let vlen = value.len() as i64;
    if start < 0 || start > end || end > vlen {
        return Err(range_oob(format!(
            "startIndex: {start}, endIndex: {end}, size: {vlen}"
        )));
    }
    let mut buf = sb.borrow_mut();
    let mut units: Vec<u16> = buf.encode_utf16().collect();
    let len = units.len() as i64;
    if index < 0 || index > len {
        return Err(range_oob(format!("index: {index}, length: {len}")));
    }
    #[allow(clippy::cast_sign_loss)]
    units.splice(
        index as usize..index as usize,
        value[start as usize..end as usize].iter().copied(),
    );
    *buf = String::from_utf16_lossy(&units);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

pub(crate) fn string_builder_append(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // `append(value: CharSequence?/CharArray, startIndex: Int, endIndex: Int)`
    // is the subrange overload — it appends `value[startIndex, endIndex)`, not
    // the three arguments separately. Detect it (a CharSequence/CharArray
    // value followed by two Ints) and route to the range append; everything
    // else is the single-value `append`.
    if ctx.args.len() == 4
        && matches!(
            ctx.args.get(1),
            Some(Value::String(_) | Value::StringBuilder(_) | Value::Array { .. })
        )
        && ctx.args.get(2).and_then(Value::as_i64).is_some()
        && ctx.args.get(3).and_then(Value::as_i64).is_some()
    {
        return string_builder_append_range(ctx);
    }
    let sb = sb_arg(ctx.args, "StringBuilder.append")?;
    {
        let mut buf = sb.borrow_mut();
        for v in &ctx.args[1..] {
            append_value(&mut buf, v);
        }
    }
    Ok(Value::StringBuilder(sb))
}

/// `StringBuilder.set(index, value: Char)` (`sb[i] = c`) — replace the
/// UTF-16 unit at `index`, in place. A bodyless `expect` otherwise.
pub(crate) fn string_builder_set(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.set")?;
    let index = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("StringBuilder.set index must be an Int".into()))?;
    let Some(Value::Char(unit)) = ctx.args.get(2) else {
        return Err(RuntimeError::Type(
            "StringBuilder.set value must be a Char".into(),
        ));
    };
    let mut buf = sb.borrow_mut();
    let mut units: Vec<u16> = buf.encode_utf16().collect();
    if index < 0 || (index as usize) >= units.len() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {index}, length: {}", units.len())),
        )));
    }
    units[index as usize] = *unit;
    *buf = String::from_utf16_lossy(&units);
    Ok(Value::Unit)
}

pub(crate) fn string_builder_append_line(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.appendLine")?;
    {
        let mut buf = sb.borrow_mut();
        for v in &ctx.args[1..] {
            append_value(&mut buf, v);
        }
        buf.push('\n');
    }
    Ok(Value::StringBuilder(sb))
}

pub(crate) fn string_builder_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.length")?;
    Ok(Value::new_int(sb.borrow().chars().count()))
}

pub(crate) fn string_builder_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.toString")?;
    Ok(Value::String(Arc::new(sb.borrow().clone())))
}

// The index is an Int; the bounds-checked value indexes the code units.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn string_builder_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.get")?;
    let Some(idx) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(
            "StringBuilder[index] requires Int".into(),
        ));
    };
    let buf = sb.borrow();
    let n = utf16_len(&buf) as i64;
    if idx < 0 || idx >= n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    Ok(Value::Char(utf16_unit_at(&buf, idx as usize).unwrap()))
}

pub(crate) fn string_builder_is_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.isEmpty")?;
    Ok(Value::Bool(sb.borrow().is_empty()))
}

pub(crate) fn string_builder_is_not_empty(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.isNotEmpty")?;
    Ok(Value::Bool(!sb.borrow().is_empty()))
}

pub(crate) fn string_builder_clear(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.clear")?;
    sb.borrow_mut().clear();
    Ok(Value::StringBuilder(sb))
}

// idx is an Int char index; negatives are rejected above, so the conversion to
// usize is on a non-negative value.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn sb_char_byte(buf: &str, idx: i64) -> Option<usize> {
    if idx < 0 {
        return None;
    }
    if idx as usize == buf.chars().count() {
        return Some(buf.len());
    }
    buf.char_indices().nth(idx as usize).map(|(b, _)| b)
}

// The char count fits an Int (Kotlin length); insert index is an Int.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_insert(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.insert")?;
    let Some(idx) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("insert index must be Int".into()));
    };
    let v = ctx
        .args
        .get(2)
        .ok_or_else(|| RuntimeError::Arity("insert requires a value".into()))?;
    let mut piece = String::new();
    append_value(&mut piece, v);
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx > n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    let byte = sb_char_byte(&buf, idx).unwrap();
    buf.insert_str(byte, &piece);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

// The char count fits an Int (Kotlin length); deleteAt index is an Int.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_delete_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteAt")?;
    let Some(idx) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("deleteAt index must be Int".into()));
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx >= n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    let byte = sb_char_byte(&buf, idx).unwrap();
    let ch = buf[byte..].chars().next().unwrap();
    buf.replace_range(byte..byte + ch.len_utf8(), "");
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

// The char count fits an Int (Kotlin length); the range bounds are Ints.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_delete_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteRange")?;
    let Some(start) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("deleteRange start must be Int".into()));
    };
    let Some(end) = ctx.args.get(2).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("deleteRange end must be Int".into()));
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if start < 0 || end > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("startIndex: {start}, endIndex: {end}, length: {n}")),
        )));
    }
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    buf.replace_range(sb_byte..eb_byte, "");
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

// The char count fits an Int (Kotlin length); newLength is an Int.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_set_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setLength")?;
    let Some(new_len) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("setLength requires Int".into()));
    };
    if new_len < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("newLength: {new_len}")),
        )));
    }
    let mut buf = sb.borrow_mut();
    let cur = buf.chars().count() as i64;
    if new_len <= cur {
        let byte = sb_char_byte(&buf, new_len).unwrap();
        buf.truncate(byte);
    } else {
        for _ in cur..new_len {
            buf.push('\u{0}');
        }
    }
    drop(buf);
    Ok(Value::Unit)
}

pub(crate) fn string_builder_reverse(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.reverse")?;
    let rev: String = sb.borrow().chars().rev().collect();
    *sb.borrow_mut() = rev;
    Ok(Value::StringBuilder(sb))
}

// The char count fits an Int (Kotlin length); start/end are Ints.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_substring(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.substring")?;
    let Some(start) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("substring start must be Int".into()));
    };
    let buf = sb.borrow();
    let n = buf.chars().count() as i64;
    let end = match ctx.args.get(2) {
        None => n,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("substring end must be Int".into())),
    };
    if start < 0 || end > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("startIndex: {start}, endIndex: {end}, length: {n}")),
        )));
    }
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    Ok(Value::String(Arc::new(buf[sb_byte..eb_byte].to_string())))
}

// The char count fits an Int (Kotlin length); setCharAt index is an Int.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_set_char_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setCharAt")?;
    let Some(idx) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("setCharAt index must be Int".into()));
    };
    let ch = match ctx.args.get(2) {
        Some(Value::Char(c)) => *c,
        _ => return Err(RuntimeError::Type("setCharAt requires a Char".into())),
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if idx < 0 || idx >= n {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index: {idx}, length: {n}")),
        )));
    }
    let byte = sb_char_byte(&buf, idx).unwrap();
    let old = buf[byte..].chars().next().unwrap();
    buf.replace_range(byte..byte + old.len_utf8(), &char_unit_to_string(ch));
    drop(buf);
    Ok(Value::Unit)
}

/// `replace(startIndex, endIndex, newString)` — splice `newString` over the
/// `[start, end)` char range. Returns the builder (Kotlin/JVM semantics).
// The char count fits an Int (Kotlin length); start/end are Ints.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.replace")?;
    let Some(start) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("replace start must be Int".into()));
    };
    let Some(end) = ctx.args.get(2).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("replace end must be Int".into()));
    };
    let repl = match ctx.args.get(3) {
        Some(Value::String(s)) => (**s).clone(),
        Some(other) => format!("{other}"),
        None => {
            return Err(RuntimeError::Type(
                "replace requires a replacement string".into(),
            ));
        }
    };
    let mut buf = sb.borrow_mut();
    let n = buf.chars().count() as i64;
    if start < 0 || start > n || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("start {start}, end {end}, length {n}")),
        )));
    }
    // Kotlin/JVM clamps the end to the current length.
    let end = end.min(n);
    let sb_byte = sb_char_byte(&buf, start).unwrap();
    let eb_byte = sb_char_byte(&buf, end).unwrap();
    buf.replace_range(sb_byte..eb_byte, &repl);
    drop(buf);
    Ok(Value::StringBuilder(sb))
}

// The char count fits an Int (Kotlin length); lastIndex returns it minus one.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_builder_last_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.lastIndex")?;
    let n = sb.borrow().chars().count() as i64;
    Ok(Value::new_int(n - 1))
}
