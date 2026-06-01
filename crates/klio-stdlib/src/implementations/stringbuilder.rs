use super::*;

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
pub(crate) fn string_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        None => String::new(),
        // CharArray is a Value::Array, but some producers (e.g. toCharArray)
        // yield a Value::List of chars — accept either.
        Some(Value::Array { items, .. }) | Some(Value::List { items, .. }) => {
            let chars = items.borrow();
            let (start, count) = if ctx.args.len() >= 3 {
                let off = ctx.args[1].as_i64().unwrap_or(0).max(0) as usize;
                let cnt = ctx.args[2].as_i64().unwrap_or(0).max(0) as usize;
                (off, cnt)
            } else {
                (0, chars.len())
            };
            let end = start.saturating_add(count).min(chars.len());
            if start > chars.len() || end > chars.len() {
                return Err(RuntimeError::Thrown(make_exception(
                    "kotlin.IndexOutOfBoundsException",
                    Some(format!("offset {start}, count {count}, size {}", chars.len())),
                )));
            }
            char_units_to_string(chars[start..end].iter().map(|v| match v {
                Value::Char(c) => *c,
                _ => 0u16,
            }))
        }
        Some(Value::String(s)) => (**s).clone(),
        Some(Value::StringBuilder(sb)) => sb.borrow().clone(),
        Some(other) => format!("{other}"),
    };
    Ok(Value::String(Arc::new(s)))
}

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
        _ => return Err(RuntimeError::Type(
            "StringBuilder takes 0 or 1 argument".into(),
        )),
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

pub(crate) fn string_builder_append(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.append")?;
    {
        let mut buf = sb.borrow_mut();
        for v in &ctx.args[1..] {
            append_value(&mut buf, v);
        }
    }
    Ok(Value::StringBuilder(sb))
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

pub(crate) fn string_builder_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.get")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type(
            "StringBuilder[index] requires Int".into(),
        )),
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

pub(crate) fn sb_char_byte(buf: &str, idx: i64) -> Option<usize> {
    if idx < 0 {
        return None;
    }
    if idx as usize == buf.chars().count() {
        return Some(buf.len());
    }
    buf.char_indices().nth(idx as usize).map(|(b, _)| b)
}

pub(crate) fn string_builder_insert(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.insert")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("insert index must be Int".into())),
    };
    let v = ctx.args.get(2).ok_or_else(|| {
        RuntimeError::Arity("insert requires a value".into())
    })?;
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

pub(crate) fn string_builder_delete_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteAt")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteAt index must be Int".into())),
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

pub(crate) fn string_builder_delete_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.deleteRange")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteRange start must be Int".into())),
    };
    let end = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("deleteRange end must be Int".into())),
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

pub(crate) fn string_builder_set_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setLength")?;
    let new_len = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("setLength requires Int".into())),
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

pub(crate) fn string_builder_substring(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.substring")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("substring start must be Int".into())),
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

pub(crate) fn string_builder_set_char_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.setCharAt")?;
    let idx = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("setCharAt index must be Int".into())),
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
pub(crate) fn string_builder_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.replace")?;
    let start = match ctx.args.get(1).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("replace start must be Int".into())),
    };
    let end = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("replace end must be Int".into())),
    };
    let repl = match ctx.args.get(3) {
        Some(Value::String(s)) => (**s).clone(),
        Some(other) => format!("{other}"),
        None => return Err(RuntimeError::Type("replace requires a replacement string".into())),
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

pub(crate) fn string_builder_last_index(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let sb = sb_arg(ctx.args, "StringBuilder.lastIndex")?;
    let n = sb.borrow().chars().count() as i64;
    Ok(Value::new_int(n - 1))
}

