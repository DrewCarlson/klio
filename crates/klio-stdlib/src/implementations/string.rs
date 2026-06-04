use super::{
    Arc, CallCtx, RuntimeError, Value, char, char_unit_to_scalar, char_unit_to_string,
    char_units_to_string, make_exception, make_list, make_sequence, perform_regex_replace,
    recv_int_radix,
};

// ============================================================
// String members (receiver in args[0])
// ============================================================

pub(crate) fn recv_string<'a>(
    args: &'a [Value],
    what: &str,
) -> Result<&'a Arc<String>, RuntimeError> {
    match args.first() {
        Some(Value::String(s)) => Ok(s),
        Some(other) => Err(RuntimeError::Type(format!(
            "{what} requires a String receiver, got {other:?}"
        ))),
        None => Err(RuntimeError::Type(format!("{what} requires a receiver"))),
    }
}

pub(crate) fn arg_as_string(v: &Value, what: &str) -> Result<String, RuntimeError> {
    match v {
        Value::String(s) => Ok((**s).clone()),
        Value::Char(c) => Ok(char_unit_to_string(*c)),
        Value::Int(n) => Ok(n.to_string()),
        Value::Double(d) => Ok(d.to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        other => Err(RuntimeError::Type(format!(
            "{what} requires a String-like argument, got {other:?}"
        ))),
    }
}

/// Number of UTF-16 code units in `s` — Kotlin's `String.length` /
/// indexing unit (an astral scalar counts as 2).
pub(crate) fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// The UTF-16 code unit at index `i` (Kotlin `String` indexing), if any.
pub(crate) fn utf16_unit_at(s: &str, i: usize) -> Option<u16> {
    s.encode_utf16().nth(i)
}

/// The UTF-16 code units of `s`, as Kotlin would iterate/index its chars.
pub(crate) fn utf16_units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// Case-insensitive equality of two UTF-16 code units (Kotlin's
/// `equals(ignoreCase=true)` per-char rule). Lone surrogates compare by
/// raw equality (no case mapping).
pub(crate) fn char_units_eq_ignore_case(a: u16, b: u16) -> bool {
    match (char_unit_to_scalar(a), char_unit_to_scalar(b)) {
        (Some(ca), Some(cb)) => {
            ca == cb
                || ca.to_lowercase().eq(cb.to_lowercase())
                || ca.to_uppercase().eq(cb.to_uppercase())
        }
        _ => a == b,
    }
}

/// The substring spanning UTF-16 units `[start, end)`. A surrogate pair
/// split by a boundary becomes lone surrogate(s), rendered lossily.
pub(crate) fn utf16_slice(s: &str, start: usize, end: usize) -> String {
    let units: Vec<u16> = s.encode_utf16().collect();
    char_units_to_string(units[start..end].iter().copied())
}

pub(crate) fn string_length(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.length")?;
    Ok(Value::new_int(utf16_len(s)))
}

/// `String.toString()` — the receiver itself.
pub(crate) fn string_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toString")?.clone();
    Ok(Value::String(s))
}

/// `String.encodeToByteArray()` and `String.toByteArray()` — the
/// receiver's UTF-8 bytes as a Kotlin signed `ByteArray`. Upstream
/// declares these `expect`/intrinsic with no body for the platform to
/// supply; an explicit charset argument is treated as UTF-8.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn string_to_byte_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toByteArray")?;
    let items: Vec<Value> = s.as_bytes().iter().map(|b| Value::Byte(*b as i8)).collect();
    Ok(Value::Array {
        items: klio_runtime::ObjRef::new(items),
        prim: Some(klio_runtime::PrimitiveArrayKind::Byte),
    })
}

/// `ByteArray.decodeToString(startIndex = 0, endIndex = size,
/// throwOnInvalidSequence = false)` — decode the byte range as UTF-8.
/// Malformed sequences become U+FFFD, matching Kotlin's default
/// (non-throwing) behaviour.
#[allow(
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap
)]
pub(crate) fn byte_array_decode_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let bytes: Vec<u8> = match ctx.args.first() {
        Some(Value::Array { items, .. }) => items
            .borrow()
            .iter()
            .map(|v| match v {
                Value::Byte(b) => *b as u8,
                Value::UByte(b) => *b,
                Value::Int(i) => *i as u8,
                Value::Long(l) => *l as u8,
                _ => 0,
            })
            .collect(),
        _ => {
            return Err(RuntimeError::Type(
                "decodeToString requires a ByteArray receiver".into(),
            ));
        }
    };
    let len = bytes.len() as i64;
    let start = ctx.args.get(1).and_then(Value::as_i64).unwrap_or(0);
    let end = ctx.args.get(2).and_then(Value::as_i64).unwrap_or(len);
    if start < 0 || end > len || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!(
                "decodeToString: [{start}, {end}) out of bounds for length {len}"
            )),
        )));
    }
    let s = String::from_utf8_lossy(&bytes[start as usize..end as usize]).into_owned();
    Ok(Value::String(Arc::new(s)))
}

pub(crate) fn string_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.uppercase")?;
    Ok(Value::String(Arc::new(s.to_uppercase())))
}

pub(crate) fn string_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lowercase")?;
    Ok(Value::String(Arc::new(s.to_lowercase())))
}

pub(crate) fn string_plus(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    use std::fmt::Write;
    let s = recv_string(ctx.args, "String.plus")?.clone();
    let other = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("String.plus requires one argument".into()))?;
    let mut joined = String::with_capacity(s.len());
    joined.push_str(&s);
    // An instance operand must stringify through its (possibly
    // overridden) `toString()` so `"x=" + obj` matches the string
    // template `"x=$obj"`; the `Display` impl only knows the default
    // `Class@hash` form.
    if matches!(other, Value::Instance(_)) {
        let CallCtx { out, host, .. } = ctx;
        if let Some(r) = host.invoke_method(&other, "toString", &[], *out)
            && let Value::String(t) = r?
        {
            joined.push_str(&t);
            return Ok(Value::String(Arc::new(joined)));
        }
    }
    write!(joined, "{other}").unwrap();
    Ok(Value::String(Arc::new(joined)))
}

// Kotlin String index is a non-negative Int reinterpreted as a usize offset.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn string_get(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.get")?;
    let Some(Value::Int(idx)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type(
            "String.get requires an Int index".into(),
        ));
    };
    if *idx < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("index {idx} out of bounds")),
        )));
    }
    let i = *idx as usize;
    match utf16_unit_at(s, i) {
        Some(c) => Ok(Value::Char(c)),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!(
                "index {idx} out of bounds (length {})",
                utf16_len(s)
            )),
        ))),
    }
}

// Kotlin String.substring works in Int code-unit indices; the length and the
// bounds-checked start/end convert between usize and i64.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn string_substring(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substring")?;
    let len = utf16_len(s) as i64;
    let (start, end) = match &ctx.args[1..] {
        [s] if s.is_integral() => (s.as_i64().unwrap(), len),
        [a, b] if a.is_integral() && b.is_integral() => (a.as_i64().unwrap(), b.as_i64().unwrap()),
        _ => {
            return Err(RuntimeError::Arity(
                "substring requires 1 or 2 Int args".into(),
            ));
        }
    };
    if start < 0 || end > len || start > end {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IndexOutOfBoundsException",
            Some(format!("substring({start},{end}) on length {len}")),
        )));
    }
    Ok(Value::String(Arc::new(utf16_slice(
        s,
        start as usize,
        end as usize,
    ))))
}

/// `CharSequence.padStart(length, padChar = ' ')` / `padEnd`. Host
/// impls so the call doesn't route to upstream's `String.padStart =
/// (this as CharSequence).padStart(...)`, whose explicit upcast klio
/// ignores in overload selection — it re-dispatches to `String.padStart`
/// and recurses forever, allocating a `StringBuilder` each level (OOM).
// Kotlin pad length is an Int; the current code-unit count and the
// non-negative pad delta convert between usize and i64.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn string_pad(
    ctx: &mut CallCtx,
    at_start: bool,
    who: &str,
) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, who)?;
    let cur_len = utf16_len(s) as i64;
    let length = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Arity(format!("{who} requires an Int length")))?;
    if length < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Desired length {length} is less than zero.")),
        )));
    }
    let pad: u16 = match ctx.args.get(2) {
        Some(Value::Char(c)) => *c,
        None => u16::from(b' '),
        Some(other) => {
            return Err(RuntimeError::Type(format!(
                "{who}: padChar must be a Char, got {other}"
            )));
        }
    };
    if length <= cur_len {
        return Ok(Value::String(Arc::clone(s)));
    }
    let pad_count = (length - cur_len) as usize;
    let padding: String = char_units_to_string(std::iter::repeat_n(pad, pad_count));
    let out = if at_start {
        format!("{padding}{s}")
    } else {
        format!("{s}{padding}")
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_pad_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_pad(ctx, true, "padStart")
}

pub(crate) fn string_pad_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_pad(ctx, false, "padEnd")
}

pub(crate) fn string_starts_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.startsWith")?;
    let prefix = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("startsWith requires an argument".into()))?,
        "startsWith",
    )?;
    Ok(Value::Bool(s.starts_with(&prefix)))
}

/// `String.regionMatches(thisOffset, other, otherOffset, length,
/// ignoreCase = false)` — true when the `length`-char regions match.
/// Out-of-range offsets/lengths yield `false` (Kotlin semantics).
// Kotlin offsets/length are Ints; the bounds-checked values convert between
// usize and i64 against the code-unit counts.
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub(crate) fn string_region_matches(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.regionMatches")?;
    let this_off = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: thisOffset".into()))?;
    let other = arg_as_string(
        ctx.args
            .get(2)
            .ok_or_else(|| RuntimeError::Arity("regionMatches: other".into()))?,
        "regionMatches",
    )?;
    let other_off = ctx
        .args
        .get(3)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: otherOffset".into()))?;
    let length = ctx
        .args
        .get(4)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("regionMatches: length".into()))?;
    let ignore_case = matches!(ctx.args.get(5), Some(Value::Bool(true)));
    let sc = utf16_units(s);
    let oc = utf16_units(&other);
    if length < 0
        || this_off < 0
        || other_off < 0
        || this_off + length > sc.len() as i64
        || other_off + length > oc.len() as i64
    {
        return Ok(Value::Bool(false));
    }
    for i in 0..length as usize {
        let a = sc[this_off as usize + i];
        let b = oc[other_off as usize + i];
        let eq = if ignore_case {
            char_units_eq_ignore_case(a, b)
        } else {
            a == b
        };
        if !eq {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

/// `internal inline fun String.skipWhile(startIndex, predicate)` —
/// kotlin.text helper used by Duration's parser. Returns the first
/// index >= startIndex whose char fails `predicate` (or `length`).
// Kotlin startIndex is an Int; the non-negative cursor indexes the code units.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_skip_while(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.skipWhile")?;
    let start = ctx
        .args
        .get(1)
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("skipWhile: startIndex".into()))?;
    let block = ctx
        .args
        .get(2)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("skipWhile: predicate".into()))?;
    let chars = utf16_units(s);
    let CallCtx { out, host, .. } = ctx;
    let mut i = if start < 0 { 0i64 } else { start };
    while (i as usize) < chars.len() {
        let c = Value::Char(chars[i as usize]);
        let keep = host.invoke_callable(&block, std::slice::from_ref(&c), *out)?;
        if !matches!(keep, Value::Bool(true)) {
            break;
        }
        i += 1;
    }
    Ok(Value::new_int(i))
}

pub(crate) fn string_ends_with(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.endsWith")?;
    let suffix = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("endsWith requires an argument".into()))?,
        "endsWith",
    )?;
    Ok(Value::Bool(s.ends_with(&suffix)))
}

pub(crate) fn string_filter(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.filter")?.clone();
    if ctx.args.len() < 2 {
        return Err(RuntimeError::Arity("filter requires a block".into()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut kept: Vec<u16> = Vec::new();
    for ch in s.encode_utf16() {
        let v = Value::Char(ch);
        if matches!(
            host.invoke_callable(&block, std::slice::from_ref(&v), *out)?,
            Value::Bool(true)
        ) {
            kept.push(ch);
        }
    }
    Ok(Value::String(Arc::new(char_units_to_string(kept))))
}

pub(crate) fn string_count(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.count")?.clone();
    if ctx.args.len() == 1 {
        // Kotlin String.count() returns the Int code-unit count.
        #[allow(clippy::cast_possible_wrap)]
        return Ok(Value::new_int(utf16_len(&s) as i64));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut n: i64 = 0;
    for ch in s.encode_utf16() {
        let v = Value::Char(ch);
        if matches!(
            host.invoke_callable(&block, std::slice::from_ref(&v), *out)?,
            Value::Bool(true)
        ) {
            n += 1;
        }
    }
    Ok(Value::new_int(n))
}

pub(crate) fn string_map(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.map")?.clone();
    if ctx.args.len() < 2 {
        return Err(RuntimeError::Arity("map requires a block".into()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    let mut result: Vec<Value> = Vec::with_capacity(utf16_len(&s));
    for ch in s.encode_utf16() {
        let v = Value::Char(ch);
        let r = host.invoke_callable(&block, std::slice::from_ref(&v), *out)?;
        result.push(r);
    }
    Ok(make_list(result, false))
}

pub(crate) fn string_any(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.any")?.clone();
    if ctx.args.len() == 1 {
        return Ok(Value::Bool(!s.is_empty()));
    }
    let block = ctx.args[1].clone();
    let CallCtx { out, host, .. } = ctx;
    for ch in s.encode_utf16() {
        let v = Value::Char(ch);
        if matches!(
            host.invoke_callable(&block, std::slice::from_ref(&v), *out)?,
            Value::Bool(true)
        ) {
            return Ok(Value::Bool(true));
        }
    }
    Ok(Value::Bool(false))
}

pub(crate) fn string_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.all")?.clone();
    let block = ctx.args.get(1).cloned();
    let Some(block) = block else {
        return Err(RuntimeError::Arity("all requires a block".into()));
    };
    let CallCtx { out, host, .. } = ctx;
    for ch in s.encode_utf16() {
        let v = Value::Char(ch);
        if !matches!(
            host.invoke_callable(&block, std::slice::from_ref(&v), *out)?,
            Value::Bool(true)
        ) {
            return Ok(Value::Bool(false));
        }
    }
    Ok(Value::Bool(true))
}

pub(crate) fn string_none(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = string_any(ctx)?;
    Ok(Value::Bool(matches!(r, Value::Bool(false))))
}

/// `String.equals(other, ignoreCase = false)` — the kotlin.text form
/// with the optional case-insensitivity flag. A `String` compares equal
/// only to another `String`; with `ignoreCase` the comparison folds case.
pub(crate) fn string_equals(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.equals")?;
    let ignore_case = matches!(ctx.args.get(2), Some(Value::Bool(true)));
    let eq = match ctx.args.get(1) {
        Some(Value::String(o)) => {
            if ignore_case {
                s.to_lowercase() == o.to_lowercase()
            } else {
                s.as_str() == o.as_str()
            }
        }
        _ => false,
    };
    Ok(Value::Bool(eq))
}

pub(crate) fn string_contains(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.contains")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("contains requires an argument".into()))?,
        "contains",
    )?;
    Ok(Value::Bool(s.contains(&needle)))
}

pub(crate) fn string_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.indexOf")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("indexOf requires an argument".into()))?,
        "indexOf",
    )?;
    Ok(Value::new_int(byte_to_char_index(s, s.find(&needle))))
}

pub(crate) fn string_last_index_of(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lastIndexOf")?;
    let needle = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("lastIndexOf requires an argument".into()))?,
        "lastIndexOf",
    )?;
    Ok(Value::new_int(byte_to_char_index(s, s.rfind(&needle))))
}

// Kotlin indexOf/lastIndexOf return an Int code-unit index (or -1).
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn byte_to_char_index(s: &str, byte: Option<usize>) -> i64 {
    let Some(b) = byte else { return -1 };
    s[..b].encode_utf16().count() as i64
}

pub(crate) fn string_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.replace")?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let (r, s) = (Arc::clone(r), Arc::clone(s));
        let repl = ctx.args.get(2).cloned();
        return perform_regex_replace(ctx, &r, &s, repl, false, "replace");
    }
    let old = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("replace requires old".into()))?,
        "replace",
    )?;
    let new = arg_as_string(
        ctx.args
            .get(2)
            .ok_or_else(|| RuntimeError::Arity("replace requires new".into()))?,
        "replace",
    )?;
    Ok(Value::String(Arc::new(s.replace(&old, &new))))
}

/// trim / trimStart / trimEnd, honoring the optional argument: a vararg Char
/// set, a `(Char)->Boolean` predicate, or nothing (whitespace).
pub(crate) fn string_trim_generic(
    ctx: &mut CallCtx,
    trim_start: bool,
    trim_end: bool,
    who: &str,
) -> Result<Value, RuntimeError> {
    let cs: Vec<u16> = utf16_units(recv_string(ctx.args, who)?);
    let extra: Vec<Value> = ctx.args[1..].to_vec();
    // `keep[i]` = char i is NOT trimmable.
    let keep: Vec<bool> = if extra.is_empty() {
        cs.iter()
            .map(|&c| !char_unit_to_scalar(c).is_some_and(char::is_whitespace))
            .collect()
    } else if extra.iter().all(|v| matches!(v, Value::Char(_))) {
        let set: Vec<u16> = extra
            .iter()
            .map(|v| match v {
                Value::Char(c) => *c,
                _ => unreachable!(),
            })
            .collect();
        cs.iter().map(|c| !set.contains(c)).collect()
    } else {
        let block = extra[0].clone();
        let CallCtx { out, host, .. } = ctx;
        let mut keep = Vec::with_capacity(cs.len());
        for c in &cs {
            let trimmable = matches!(
                host.invoke_callable(&block, &[Value::Char(*c)], *out)?,
                Value::Bool(true)
            );
            keep.push(!trimmable);
        }
        keep
    };
    let lo = if trim_start {
        keep.iter().position(|&k| k).unwrap_or(cs.len())
    } else {
        0
    };
    let hi = if trim_end {
        keep.iter().rposition(|&k| k).map_or(0, |p| p + 1)
    } else {
        cs.len()
    };
    let hi = hi.max(lo);
    Ok(Value::String(Arc::new(char_units_to_string(
        cs[lo..hi].iter().copied(),
    ))))
}
pub(crate) fn string_trim(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, true, true, "String.trim")
}
pub(crate) fn string_trim_start(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, true, false, "String.trimStart")
}
pub(crate) fn string_trim_end(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    string_trim_generic(ctx, false, true, "String.trimEnd")
}

// Kotlin repeat count is a non-negative Int used as a usize multiplier.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn string_repeat(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.repeat")?;
    let Some(Value::Int(n)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("repeat requires an Int count".into()));
    };
    if *n < 0 {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("Count `n` must be non-negative, but was {n}")),
        )));
    }
    Ok(Value::String(Arc::new(s.repeat(*n as usize))))
}

pub(crate) fn string_reversed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.reversed")?;
    Ok(Value::String(Arc::new(s.chars().rev().collect())))
}

#[allow(clippy::type_complexity)]
pub(crate) fn string_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.compareTo")?;
    let Some(Value::String(other)) = ctx.args.get(1) else {
        return Err(RuntimeError::Type("compareTo requires a String".into()));
    };
    let r = crate::text::compare_utf16(s, other);
    Ok(Value::Int(match r {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }))
}

// radix is validated to 2..=36 before the conversion to u32.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toInt")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toInt")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    parse_int_radix(s, radix as u32)
        .ok()
        .filter(|v| (i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(v))
        .map(Value::new_int)
        .ok_or_else(|| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NumberFormatException",
                Some(format!("For input string: \"{s}\"")),
            ))
        })
}

// radix is validated to 2..=36 before the conversion to u32.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_to_int_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toIntOrNull")?;
    let Ok(radix) = recv_int_radix(ctx.args.get(1), "String.toIntOrNull") else {
        return Ok(Value::Null);
    };
    if !(2..=36).contains(&radix) {
        return Ok(Value::Null);
    }
    // Bounds-check against the Int range: a value that fits i64 but overflows
    // i32 must return null, not a truncated Int.
    Ok(parse_int_radix(s, radix as u32)
        .ok()
        .filter(|v| (i64::from(i32::MIN)..=i64::from(i32::MAX)).contains(v))
        .map_or(Value::Null, Value::new_int))
}

pub(crate) fn parse_int_radix(s: &str, radix: u32) -> Result<i64, ()> {
    let s = s.trim();
    if s.is_empty() {
        return Err(());
    }
    let (negative, body) = if let Some(rest) = s.strip_prefix('-') {
        (true, rest)
    } else if let Some(rest) = s.strip_prefix('+') {
        (false, rest)
    } else {
        (false, s)
    };
    if body.is_empty() {
        return Err(());
    }
    let mut acc: i64 = 0;
    for ch in body.chars() {
        let d = ch.to_digit(radix).ok_or(())?;
        acc = acc.checked_mul(i64::from(radix)).ok_or(())?;
        acc = acc.checked_add(i64::from(d)).ok_or(())?;
    }
    if negative {
        acc = acc.checked_neg().ok_or(())?;
    }
    Ok(acc)
}

pub(crate) fn string_to_list(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toList")?;
    let items: Vec<Value> = s.encode_utf16().map(Value::Char).collect();
    Ok(make_list(items, false))
}

pub(crate) fn string_split(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(string_split_items(ctx, "String.split")?, false))
}

/// `splitToSequence(...)` shares `split`'s delimiter handling and
/// yields the same substrings as a `Sequence<String>`. klio collects
/// eagerly and wraps the result (faithful for finite inputs, which is
/// every `String`).
pub(crate) fn string_split_to_sequence(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_sequence(string_split_items(
        ctx,
        "String.splitToSequence",
    )?))
}

pub(crate) fn string_split_items(ctx: &mut CallCtx, who: &str) -> Result<Vec<Value>, RuntimeError> {
    let s = recv_string(ctx.args, who)?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let limit = match ctx.args.get(2) {
            None => 0i64,
            Some(v) if v.is_integral() => v.as_i64().unwrap(),
            _ => return Err(RuntimeError::Type("split limit must be Int".into())),
        };
        let parts: Vec<&str> = if limit <= 0 {
            r.re.split(s).collect()
        } else {
            // limit is positive here; Kotlin's split limit is a usize bound.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            r.re.splitn(s, limit as usize).collect()
        };
        return Ok(parts
            .into_iter()
            .map(|p| Value::String(Arc::new(p.to_string())))
            .collect());
    }
    // `split(vararg delimiters: String/Char, ignoreCase = false, limit = 0)`:
    // collect every String/Char delimiter, plus a trailing Bool (ignoreCase)
    // and Int (limit). Splitting on the FIRST delimiter only, or ignoring the
    // limit, were both bugs.
    let mut delims: Vec<String> = Vec::new();
    let mut ignore_case = false;
    let mut limit = 0i64;
    let push_delim = |v: &Value, delims: &mut Vec<String>| -> bool {
        match v {
            Value::String(d) => {
                delims.push((**d).clone());
                true
            }
            Value::Char(c) => {
                delims.push(c.to_string());
                true
            }
            _ => false,
        }
    };
    for a in &ctx.args[1..] {
        match a {
            Value::String(_) | Value::Char(_) => {
                push_delim(a, &mut delims);
            }
            Value::Bool(b) => ignore_case = *b,
            // The vararg `delimiters` may arrive packed into an Array/List
            // (named-argument call form, e.g. `split(",", limit = 2)`).
            Value::Array { items, .. } | Value::List { items, .. } => {
                for it in items.borrow().iter() {
                    if !push_delim(it, &mut delims) {
                        return Err(RuntimeError::Type(
                            "String.split delimiters must be String or Char".into(),
                        ));
                    }
                }
            }
            v if v.is_integral() => limit = v.as_i64().unwrap(),
            // A skipped default parameter (e.g. ignoreCase when only limit is
            // named) arrives as Null — ignore it.
            Value::Null => {}
            _ => {
                return Err(RuntimeError::Type(
                    "String.split requires String, Char, or Regex delimiters".into(),
                ));
            }
        }
    }
    if delims.is_empty() {
        return Err(RuntimeError::Type(
            "String.split requires at least one delimiter".into(),
        ));
    }
    Ok(split_on_any(s, &delims, ignore_case, limit))
}

/// Split `s` on any of `delims` (left-to-right, non-overlapping), honoring a
/// positive `limit` (max substrings) and ASCII `ignore_case`. An empty
/// delimiter is skipped.
// The Kotlin split limit is an Int; the produced-segment count compares against it.
#[allow(clippy::cast_possible_wrap)]
pub(crate) fn split_on_any(
    s: &str,
    delims: &[String],
    ignore_case: bool,
    limit: i64,
) -> Vec<Value> {
    let nonempty: Vec<&str> = delims
        .iter()
        .map(String::as_str)
        .filter(|d| !d.is_empty())
        .collect();
    if nonempty.is_empty() {
        return vec![Value::String(Arc::new(s.to_string()))];
    }
    let mut out: Vec<Value> = Vec::new();
    let mut seg_start = 0usize;
    let mut i = 0usize;
    while i < s.len() {
        if limit > 0 && out.len() as i64 == limit - 1 {
            break;
        }
        if !s.is_char_boundary(i) {
            i += 1;
            continue;
        }
        let mut matched: Option<usize> = None;
        for d in &nonempty {
            let end = i + d.len();
            if end <= s.len() && s.is_char_boundary(end) {
                let cand = &s[i..end];
                let eq = if ignore_case {
                    cand.eq_ignore_ascii_case(d)
                } else {
                    cand == *d
                };
                if eq {
                    matched = Some(d.len());
                    break;
                }
            }
        }
        if let Some(dlen) = matched {
            out.push(Value::String(Arc::new(s[seg_start..i].to_string())));
            i += dlen;
            seg_start = i;
        } else {
            i += 1;
        }
    }
    out.push(Value::String(Arc::new(s[seg_start..].to_string())));
    out
}

// chunked size is validated positive before being used as a usize chunk width.
#[allow(clippy::cast_sign_loss)]
pub(crate) fn string_chunked(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.chunked")?;
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
    let chars: Vec<u16> = utf16_units(s);
    let mut pieces: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let end = (i + size).min(chars.len());
        pieces.push(char_units_to_string(chars[i..end].iter().copied()));
        i += size;
    }
    let mut out: Vec<Value> = Vec::with_capacity(pieces.len());
    match transform {
        None => {
            for p in pieces {
                out.push(Value::String(Arc::new(p)));
            }
        }
        Some(block) => {
            let CallCtx {
                out: sink, host, ..
            } = ctx;
            for p in pieces {
                let arg = Value::String(Arc::new(p));
                let r = host.invoke_callable(&block, std::slice::from_ref(&arg), *sink)?;
                out.push(r);
            }
        }
    }
    Ok(make_list(out, false))
}

// windowed size and step are validated positive before use as usize widths.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_windowed(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.windowed")?;
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
    let partial = match ctx.args.get(3) {
        None => false,
        Some(Value::Bool(b)) => *b,
        _ => {
            return Err(RuntimeError::Type(
                "windowed partialWindows must be Bool".into(),
            ));
        }
    };
    if step <= 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: Arc::new("kotlin.IllegalArgumentException".into()),
            message: Some(Arc::new(format!("step {step} must be greater than zero."))),
            cause: None,
        }));
    }
    let chars: Vec<u16> = utf16_units(s);
    let size = *size as usize;
    let step = step as usize;
    let mut out: Vec<Value> = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let end = i + size;
        if end <= chars.len() {
            let win = char_units_to_string(chars[i..end].iter().copied());
            out.push(Value::String(Arc::new(win)));
        } else if partial {
            let win = char_units_to_string(chars[i..].iter().copied());
            out.push(Value::String(Arc::new(win)));
        } else {
            break;
        }
        i += step;
    }
    Ok(make_list(out, false))
}

pub(crate) fn string_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toDouble")?;
    s.parse::<f64>().map(Value::Double).map_err(|_| {
        RuntimeError::Thrown(make_exception(
            "kotlin.NumberFormatException",
            Some(format!("For input string: \"{s}\"")),
        ))
    })
}

fn number_format_error(s: &str) -> RuntimeError {
    RuntimeError::Thrown(make_exception(
        "kotlin.NumberFormatException",
        Some(format!("For input string: \"{s}\"")),
    ))
}

pub(crate) fn string_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toFloat")?;
    s.parse::<f32>()
        .map(Value::Float)
        .map_err(|_| number_format_error(s))
}

pub(crate) fn string_to_float_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toFloatOrNull")?;
    Ok(s.parse::<f32>().map_or(Value::Null, Value::Float))
}

#[allow(clippy::cast_possible_truncation)]
pub(crate) fn string_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toShort")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toShort")?;
    parse_int_radix(s, radix as u32)
        .ok()
        .filter(|v| (i64::from(i16::MIN)..=i64::from(i16::MAX)).contains(v))
        .map(|v| Value::Short(v as i16))
        .ok_or_else(|| number_format_error(s))
}

#[allow(clippy::cast_possible_truncation)]
pub(crate) fn string_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toByte")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toByte")?;
    parse_int_radix(s, radix as u32)
        .ok()
        .filter(|v| (i64::from(i8::MIN)..=i64::from(i8::MAX)).contains(v))
        .map(|v| Value::Byte(v as i8))
        .ok_or_else(|| number_format_error(s))
}

/// Deprecated `String.capitalize()` / `decapitalize()`: upper/lower-case the
/// first character (locale-independent), leaving the rest unchanged.
pub(crate) fn string_capitalize(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.capitalize")?;
    let mut it = s.chars();
    let out = match it.next() {
        Some(c) => c.to_uppercase().collect::<String>() + it.as_str(),
        None => String::new(),
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_decapitalize(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.decapitalize")?;
    let mut it = s.chars();
    let out = match it.next() {
        Some(c) => c.to_lowercase().collect::<String>() + it.as_str(),
        None => String::new(),
    };
    Ok(Value::String(Arc::new(out)))
}

// ============================================================
// Additional String members
// ============================================================

pub(crate) fn string_substring_before(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringBefore")?;
    let delim = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("substringBefore requires a delimiter".into()))?,
        "substringBefore",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.find(&delim) {
        Some(i) => s[..i].to_string(),
        None => missing,
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_substring_after(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringAfter")?;
    let delim = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("substringAfter requires a delimiter".into()))?,
        "substringAfter",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.find(&delim) {
        Some(i) => s[i + delim.len()..].to_string(),
        None => missing,
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_substring_before_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringBeforeLast")?;
    let delim = arg_as_string(
        ctx.args.get(1).ok_or_else(|| {
            RuntimeError::Arity("substringBeforeLast requires a delimiter".into())
        })?,
        "substringBeforeLast",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.rfind(&delim) {
        Some(i) => s[..i].to_string(),
        None => missing,
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_substring_after_last(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.substringAfterLast")?;
    let delim = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("substringAfterLast requires a delimiter".into()))?,
        "substringAfterLast",
    )?;
    let missing = match ctx.args.get(2) {
        Some(Value::String(d)) => (**d).clone(),
        Some(Value::Char(c)) => c.to_string(),
        _ => (**s).clone(),
    };
    let out = match s.rfind(&delim) {
        Some(i) => s[i + delim.len()..].to_string(),
        None => missing,
    };
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn string_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.replaceFirst")?;
    if let Some(Value::Regex(r)) = ctx.args.get(1) {
        let (r, s) = (Arc::clone(r), Arc::clone(s));
        let repl = ctx.args.get(2).cloned();
        return perform_regex_replace(ctx, &r, &s, repl, true, "replaceFirst");
    }
    let old = arg_as_string(
        ctx.args
            .get(1)
            .ok_or_else(|| RuntimeError::Arity("replaceFirst requires old".into()))?,
        "replaceFirst",
    )?;
    let new = arg_as_string(
        ctx.args
            .get(2)
            .ok_or_else(|| RuntimeError::Arity("replaceFirst requires new".into()))?,
        "replaceFirst",
    )?;
    Ok(Value::String(Arc::new(s.replacen(&old, &new, 1))))
}

pub(crate) fn string_trim_indent(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimIndent")?;
    let lines: Vec<&str> = s.split('\n').collect();
    // Compute the minimum indent of non-blank lines.
    let min_indent = lines
        .iter()
        .filter(|l| !l.chars().all(char::is_whitespace))
        .map(|l| l.chars().take_while(|c| *c == ' ' || *c == '\t').count())
        .min()
        .unwrap_or(0);
    let mut out_lines: Vec<String> = lines
        .iter()
        .map(|l| {
            if l.chars().all(char::is_whitespace) {
                String::new()
            } else {
                l.chars().skip(min_indent).collect()
            }
        })
        .collect();
    // Trim leading and trailing blank lines.
    while out_lines.first().is_some_and(std::string::String::is_empty) {
        out_lines.remove(0);
    }
    while out_lines.last().is_some_and(std::string::String::is_empty) {
        out_lines.pop();
    }
    Ok(Value::String(Arc::new(out_lines.join("\n"))))
}

pub(crate) fn string_trim_margin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.trimMargin")?;
    let prefix = match ctx.args.get(1) {
        None => "|".to_string(),
        Some(Value::String(p)) => (**p).clone(),
        Some(Value::Char(c)) => c.to_string(),
        Some(other) => format!("{other}"),
    };
    let lines: Vec<&str> = s.split('\n').collect();
    let mut out_lines: Vec<String> = Vec::with_capacity(lines.len());
    for l in &lines {
        let trimmed_start = l.trim_start_matches([' ', '\t']);
        if let Some(rest) = trimmed_start.strip_prefix(&prefix) {
            out_lines.push(rest.to_string());
        } else {
            out_lines.push((*l).to_string());
        }
    }
    // Trim a single leading/trailing blank line (matching Kotlin behavior).
    if out_lines
        .first()
        .is_some_and(|l| l.chars().all(char::is_whitespace) && l.is_empty())
    {
        out_lines.remove(0);
    }
    if out_lines
        .last()
        .is_some_and(|l| l.chars().all(char::is_whitespace) && l.is_empty())
    {
        out_lines.pop();
    }
    Ok(Value::String(Arc::new(out_lines.join("\n"))))
}

pub(crate) fn string_lines(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.lines")?;
    // Kotlin lines() splits on \r\n, \r, and \n.
    let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
    let items: Vec<Value> = normalized
        .split('\n')
        .map(|p| Value::String(Arc::new(p.to_string())))
        .collect();
    Ok(make_list(items, false))
}

pub(crate) fn string_to_char_array(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toCharArray")?;
    Ok(make_list(
        s.encode_utf16().map(Value::Char).collect(),
        false,
    ))
}

// radix is validated to 2..=36 before the conversion to u32.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLong")?;
    let radix = recv_int_radix(ctx.args.get(1), "String.toLong")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    parse_int_radix(s, radix as u32)
        .map(Value::Long)
        .map_err(|()| {
            RuntimeError::Thrown(make_exception(
                "kotlin.NumberFormatException",
                Some(format!("For input string: \"{s}\"")),
            ))
        })
}

// radix is validated to 2..=36 before the conversion to u32.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn string_to_long_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toLongOrNull")?;
    let Ok(radix) = recv_int_radix(ctx.args.get(1), "String.toLongOrNull") else {
        return Ok(Value::Null);
    };
    if !(2..=36).contains(&radix) {
        return Ok(Value::Null);
    }
    Ok(parse_int_radix(s, radix as u32).map_or(Value::Null, Value::Long))
}

pub(crate) fn string_to_double_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toDoubleOrNull")?;
    Ok(s.parse::<f64>().map_or(Value::Null, Value::Double))
}

pub(crate) fn string_to_boolean(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toBoolean")?;
    Ok(Value::Bool(s.eq_ignore_ascii_case("true")))
}

pub(crate) fn string_to_boolean_strict_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = recv_string(ctx.args, "String.toBooleanStrictOrNull")?;
    let r: &str = s;
    Ok(match r {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        _ => Value::Null,
    })
}

// ============================================================
// String.format / kotlin.text.format
// ============================================================

pub(crate) fn string_format_static(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let fmt = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type("format requires a format String".into())),
    };
    let args: Vec<Value> = ctx.args[1..].to_vec();
    Ok(Value::String(Arc::new(format_kotlin(&fmt, &args)?)))
}

pub(crate) fn string_format_member(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Receiver-style `"%d".format(x)` — receiver is args[0], format args follow.
    string_format_static(ctx)
}

/// Render a format string in the printf subset Kotlin commonly uses:
/// `%[flags][width][.precision]conversion` for d, x, X, o, s, c, b, f, e, E, g, G, %, n.
pub(crate) fn format_kotlin(fmt: &str, args: &[Value]) -> Result<String, RuntimeError> {
    let mut out = String::with_capacity(fmt.len());
    let bytes: Vec<char> = fmt.chars().collect();
    let mut i = 0;
    let mut arg_idx = 0usize;
    while i < bytes.len() {
        let c = bytes[i];
        if c != '%' {
            out.push(c);
            i += 1;
            continue;
        }
        i += 1;
        if i >= bytes.len() {
            return Err(RuntimeError::Thrown(make_exception(
                "java.util.UnknownFormatConversionException",
                Some("trailing %".into()),
            )));
        }
        // Optional argument index `n$`.
        let start_i = i;
        let mut idx_override: Option<usize> = None;
        let mut j = i;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        if j > i && j < bytes.len() && bytes[j] == '$' {
            let n: usize = bytes[i..j].iter().collect::<String>().parse().unwrap_or(0);
            if n > 0 {
                idx_override = Some(n - 1);
            }
            i = j + 1;
        } else {
            i = start_i;
        }
        // Flags.
        let mut flag_left = false;
        let mut flag_zero = false;
        let mut flag_plus = false;
        let mut flag_space = false;
        let mut flag_hash = false;
        let mut flag_comma = false;
        while i < bytes.len() {
            match bytes[i] {
                '-' => flag_left = true,
                '0' => flag_zero = true,
                '+' => flag_plus = true,
                ' ' => flag_space = true,
                '#' => flag_hash = true,
                ',' => flag_comma = true,
                _ => break,
            }
            i += 1;
        }
        // Width.
        let mut width: Option<usize> = None;
        let wstart = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        if i > wstart {
            width = Some(
                bytes[wstart..i]
                    .iter()
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0),
            );
        }
        // Precision.
        let mut precision: Option<usize> = None;
        if i < bytes.len() && bytes[i] == '.' {
            i += 1;
            let pstart = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i > pstart {
                precision = Some(
                    bytes[pstart..i]
                        .iter()
                        .collect::<String>()
                        .parse()
                        .unwrap_or(0),
                );
            }
        }
        if i >= bytes.len() {
            return Err(RuntimeError::Thrown(make_exception(
                "java.util.UnknownFormatConversionException",
                Some("incomplete format specifier".into()),
            )));
        }
        let conv = bytes[i];
        i += 1;
        if conv == '%' {
            out.push('%');
            continue;
        }
        if conv == 'n' {
            out.push('\n');
            continue;
        }
        let consumed_idx = idx_override.unwrap_or(arg_idx);
        if idx_override.is_none() {
            arg_idx += 1;
        }
        let arg = args.get(consumed_idx).cloned().unwrap_or(Value::Null);
        let body = format_conv(
            conv, &arg, flag_plus, flag_space, flag_hash, flag_zero, flag_comma, precision,
        )?;
        let padded = pad_spec(&body, width, flag_left, flag_zero && !is_string_like(conv));
        out.push_str(&padded);
    }
    Ok(out)
}

pub(crate) fn is_string_like(c: char) -> bool {
    matches!(c, 's' | 'S' | 'c' | 'C' | 'b' | 'B')
}

pub(crate) fn pad_spec(body: &str, width: Option<usize>, left: bool, zero: bool) -> String {
    let Some(w) = width else {
        return body.to_string();
    };
    let cur = body.encode_utf16().count();
    if cur >= w {
        return body.to_string();
    }
    let pad = w - cur;
    let ch = if zero { '0' } else { ' ' };
    let pad_str: String = std::iter::repeat_n(ch, pad).collect();
    if zero {
        // Zero-pad after any sign / prefix.
        if let Some(rest) = body.strip_prefix('-') {
            return format!("-{pad_str}{rest}");
        }
        if let Some(rest) = body.strip_prefix('+') {
            return format!("+{pad_str}{rest}");
        }
    }
    if left {
        format!("{body}{pad_str}")
    } else {
        format!("{pad_str}{body}")
    }
}

// Single match dispatch over the printf conversion char; the flag bools mirror
// the printf flag set and the body stays one cohesive match for correctness.
// %x/%X/%o reinterpret the integer bits unsigned, %c maps an Int code point, and
// %g truncates the base-10 exponent, matching Java's Formatter.
#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    clippy::fn_params_excessive_bools,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap
)]
pub(crate) fn format_conv(
    conv: char,
    arg: &Value,
    plus: bool,
    space: bool,
    hash: bool,
    _zero: bool,
    comma: bool,
    precision: Option<usize>,
) -> Result<String, RuntimeError> {
    match conv {
        'd' | 'i' => {
            let n = as_long_for_format(arg)?;
            let mut s = if comma {
                fmt_with_commas(n)
            } else {
                n.unsigned_abs().to_string()
            };
            if n < 0 {
                s = format!("-{s}");
            } else if plus {
                s = format!("+{s}");
            } else if space {
                s = format!(" {s}");
            }
            Ok(s)
        }
        'x' | 'X' => {
            let n = as_long_for_format(arg)?;
            let raw = if conv == 'X' {
                format!("{:X}", n as u64)
            } else {
                format!("{:x}", n as u64)
            };
            let prefixed = if hash {
                if conv == 'X' {
                    format!("0X{raw}")
                } else {
                    format!("0x{raw}")
                }
            } else {
                raw
            };
            Ok(prefixed)
        }
        'o' => {
            let n = as_long_for_format(arg)?;
            Ok(format!("{:o}", n as u64))
        }
        'b' | 'B' => {
            // Kotlin: %b is "false" for null, "true" for non-null non-boolean;
            // booleans render literally.
            let s = match arg {
                Value::Null => "false".to_string(),
                Value::Bool(b) => b.to_string(),
                _ => "true".to_string(),
            };
            Ok(if conv == 'B' { s.to_uppercase() } else { s })
        }
        's' | 'S' => {
            let mut s = match arg {
                Value::String(v) => (**v).clone(),
                Value::Null => "null".to_string(),
                other => format!("{other}"),
            };
            if let Some(p) = precision {
                s = char_units_to_string(s.encode_utf16().take(p));
            }
            Ok(if conv == 'S' { s.to_uppercase() } else { s })
        }
        'c' | 'C' => {
            let s = match arg {
                Value::Char(c) => char_unit_to_string(*c),
                Value::Int(n) => char::from_u32(*n as u32)
                    .ok_or_else(|| RuntimeError::Type(format!("%c: invalid code point {n}")))?
                    .to_string(),
                _ => {
                    return Err(RuntimeError::Type(
                        "%c requires Char or Int code point".into(),
                    ));
                }
            };
            Ok(if conv == 'C' { s.to_uppercase() } else { s })
        }
        'f' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6);
            let raw = format!("{:.*}", p, d.abs());
            let mut s = if comma {
                insert_commas_decimal(&raw)
            } else {
                raw
            };
            if d.is_sign_negative() && !d.is_nan() {
                s = format!("-{s}");
            } else if plus {
                s = format!("+{s}");
            } else if space {
                s = format!(" {s}");
            }
            Ok(s)
        }
        'e' | 'E' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6);
            let raw = format!("{:.*e}", p, d.abs());
            // Rust gives e.g. `1.234e2`; Java wants `1.234e+02`.
            let s = normalize_scientific(&raw, conv == 'E');
            let mut out = s;
            if d.is_sign_negative() {
                out = format!("-{out}");
            } else if plus {
                out = format!("+{out}");
            } else if space {
                out = format!(" {out}");
            }
            Ok(out)
        }
        'g' | 'G' => {
            let d = as_double_for_format(arg)?;
            let p = precision.unwrap_or(6).max(1);
            let exp = if d == 0.0 {
                0
            } else {
                d.abs().log10().floor() as i32
            };
            let use_scientific = exp < -4 || exp >= p as i32;
            if use_scientific {
                format_conv(
                    if conv == 'G' { 'E' } else { 'e' },
                    arg,
                    plus,
                    space,
                    hash,
                    false,
                    comma,
                    Some(p - 1),
                )
            } else {
                let prec = (p as i32 - 1 - exp).max(0) as usize;
                format_conv('f', arg, plus, space, hash, false, comma, Some(prec))
            }
        }
        _ => Err(RuntimeError::Thrown(make_exception(
            "java.util.UnknownFormatConversionException",
            Some(format!("conversion: {conv}")),
        ))),
    }
}

pub(crate) fn as_long_for_format(v: &Value) -> Result<i64, RuntimeError> {
    if let Some(n) = v.as_i64() {
        return Ok(n);
    }
    match v {
        Value::Char(c) => Ok(i64::from(u32::from(*c))),
        Value::Bool(b) => Ok(i64::from(*b)),
        _ => Err(RuntimeError::Type(format!(
            "integer format spec requires Int-like, got {v:?}"
        ))),
    }
}

pub(crate) fn as_double_for_format(v: &Value) -> Result<f64, RuntimeError> {
    match v {
        Value::Double(d) => Ok(*d),
        Value::Int(n) => Ok(f64::from(*n)),
        _ => Err(RuntimeError::Type(format!(
            "float format spec requires Number, got {v:?}"
        ))),
    }
}

pub(crate) fn fmt_with_commas(n: i64) -> String {
    let s = n.unsigned_abs().to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

pub(crate) fn insert_commas_decimal(s: &str) -> String {
    let (whole, frac) = match s.split_once('.') {
        Some((w, f)) => (w, Some(f)),
        None => (s, None),
    };
    let mut out = String::new();
    for (i, ch) in whole.chars().enumerate() {
        if i > 0 && (whole.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    if let Some(f) = frac {
        out.push('.');
        out.push_str(f);
    }
    out
}

pub(crate) fn normalize_scientific(s: &str, upper: bool) -> String {
    let (mantissa, exp) = s.split_once('e').unwrap_or((s, "0"));
    let mut exp_n: i32 = exp.parse().unwrap_or(0);
    let exp_sign = if exp_n < 0 { '-' } else { '+' };
    exp_n = exp_n.abs();
    let e_letter = if upper { 'E' } else { 'e' };
    format!("{mantissa}{e_letter}{exp_sign}{exp_n:02}")
}
