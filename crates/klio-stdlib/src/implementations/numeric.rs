use super::{Value, RuntimeError, CallCtx, make_exception, Arc, kotlin_float_total_cmp, arg2, num_extreme};

// ============================================================
// Int members
// ============================================================

pub(crate) fn recv_int(args: &[Value], what: &str) -> Result<i64, RuntimeError> {
    args.first()
        .and_then(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires an integer receiver")))
}

pub(crate) fn recv_int_radix(v: Option<&Value>, what: &str) -> Result<i64, RuntimeError> {
    match v {
        None => Ok(10),
        Some(v) => v.as_i64().ok_or_else(|| {
            RuntimeError::Type(format!("{what} radix must be Int"))
        }),
    }
}

pub(crate) fn int_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let n = recv_int(ctx.args, "Int.toString")?;
    let radix = recv_int_radix(ctx.args.get(1), "Int.toString")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    Ok(Value::String(Arc::new(int_to_radix_string(n, radix as u32))))
}

pub(crate) fn int_to_radix_string(n: i64, radix: u32) -> String {
    if n == 0 {
        return "0".to_string();
    }
    let negative = n < 0;
    let mut x = if negative {
        // Cast through i128 to handle i64::MIN. Kotlin renders the absolute
        // digit run with a leading `-`.
        i128::from(n).unsigned_abs()
    } else {
        n as u128
    };
    let mut digits = Vec::new();
    while x > 0 {
        let d = (x % u128::from(radix)) as u32;
        x /= u128::from(radix);
        digits.push(std::char::from_digit(d, radix).unwrap());
    }
    if negative {
        digits.push('-');
    }
    digits.iter().rev().collect()
}

pub(crate) fn int_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_int(ctx.args, "Int.toLong")?))
}
pub(crate) fn int_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_int(ctx.args, "Int.toDouble")? as f64))
}
pub(crate) fn int_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_int(ctx.args, "Int.toFloat")? as f32))
}
pub(crate) fn int_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Identity for Int receivers; truncates Long/Short/Byte if any caller
    // routes through this slot.
    Ok(Value::new_int((recv_int(ctx.args, "Int.toInt")?) as i32))
}
pub(crate) fn int_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_int(ctx.args, "Int.toShort")?))
}
pub(crate) fn int_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_int(ctx.args, "Int.toByte")?))
}

// Long-only conversion methods (when the receiver is `Value::Long`).
// These intentionally mirror the Int-family — `recv_int` widens any
// integral receiver to i64, so they cover Long, Int, Short, Byte.
pub(crate) fn long_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_int(ctx.args, "Long.toLong")?))
}
pub(crate) fn long_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(recv_int(ctx.args, "Long.toInt")?))
}
pub(crate) fn long_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_int(ctx.args, "Long.toShort")?))
}
pub(crate) fn long_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_int(ctx.args, "Long.toByte")?))
}
pub(crate) fn long_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_int(ctx.args, "Long.toDouble")? as f64))
}
pub(crate) fn long_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_int(ctx.args, "Long.toFloat")? as f32))
}

pub(crate) fn recv_unsigned(args: &[Value], what: &str) -> Result<u64, RuntimeError> {
    args.first()
        .and_then(Value::as_u64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires an integer receiver")))
}

pub(crate) fn to_ubyte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UByte(recv_unsigned(ctx.args, "toUByte")? as u8))
}
pub(crate) fn to_ushort(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UShort(recv_unsigned(ctx.args, "toUShort")? as u16))
}
pub(crate) fn to_uint(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::UInt(recv_unsigned(ctx.args, "toUInt")? as u32))
}
pub(crate) fn to_ulong(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::ULong(recv_unsigned(ctx.args, "toULong")?))
}
pub(crate) fn unsigned_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(recv_unsigned(ctx.args, "toInt")? as i64))
}
pub(crate) fn unsigned_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(recv_unsigned(ctx.args, "toLong")? as i64))
}
pub(crate) fn unsigned_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(recv_unsigned(ctx.args, "toShort")? as i64))
}
pub(crate) fn unsigned_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(recv_unsigned(ctx.args, "toByte")? as i64))
}
pub(crate) fn unsigned_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_unsigned(ctx.args, "toDouble")? as f64))
}
pub(crate) fn unsigned_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_unsigned(ctx.args, "toFloat")? as f32))
}
pub(crate) fn unsigned_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_unsigned(ctx.args, "toString")?;
    Ok(Value::String(std::sync::Arc::new(v.to_string())))
}

// Float receiver conversions.
pub(crate) fn float_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(f64::from(recv_float(ctx.args, "Float.toDouble")?)))
}
pub(crate) fn float_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_float(ctx.args, "Float.toFloat")?))
}
pub(crate) fn float_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toInt")?)))
}
pub(crate) fn float_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(f32_to_i64_kotlin(recv_float(ctx.args, "Float.toLong")?)))
}
pub(crate) fn float_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toShort")?)))
}
pub(crate) fn float_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(f32_to_i32_kotlin(recv_float(ctx.args, "Float.toByte")?)))
}

pub(crate) fn float_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_float(ctx.args, "Float.toString")?;
    Ok(Value::String(Arc::new(klio_runtime::kotlin_float_to_string(d))))
}
pub(crate) fn float_is_nan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isNaN")?.is_nan()))
}
pub(crate) fn float_is_infinite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isInfinite")?.is_infinite()))
}
pub(crate) fn float_is_finite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_float(ctx.args, "Float.isFinite")?.is_finite()))
}
pub(crate) fn float_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_float(ctx.args, "Float.compareTo")?;
    let b = ctx.args.get(1).and_then(Value::as_f32).ok_or_else(|| {
        RuntimeError::Type("Float.compareTo requires a number".into())
    })?;
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    Ok(Value::new_int(kotlin_float_total_cmp(f64::from(a), f64::from(b)) as i64))
}

// Double additional conversions (Float).
pub(crate) fn double_to_float(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Float(recv_double(ctx.args, "Double.toFloat")? as f32))
}
pub(crate) fn double_to_double(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(recv_double(ctx.args, "Double.toDouble")?))
}
pub(crate) fn double_to_short(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_short(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toShort")?)))
}
pub(crate) fn double_to_byte(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_byte(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toByte")?)))
}

pub(crate) fn int_binop<F: Fn(i32, i32) -> i32>(
    ctx: &CallCtx<'_>,
    what: &str,
    op: F,
) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, what)? as i32;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires an Int argument")));
    };
    Ok(Value::new_int(op(a, b as i32)))
}

pub(crate) fn int_and(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.and", |a, b| a & b)
}
pub(crate) fn int_or(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.or", |a, b| a | b)
}
pub(crate) fn int_xor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.xor", |a, b| a ^ b)
}
pub(crate) fn int_inv(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(!recv_int(ctx.args, "Int.inv")?))
}
pub(crate) fn int_shl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.shl", |a, b| a.wrapping_shl((b & 31) as u32))
}
pub(crate) fn int_shr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.shr", |a, b| a.wrapping_shr((b & 31) as u32))
}
pub(crate) fn int_ushr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    int_binop(ctx, "Int.ushr", |a, b| ((a as u32).wrapping_shr((b & 31) as u32)) as i32)
}

pub(crate) fn long_binop<F: Fn(i64, i64) -> i64>(
    ctx: &CallCtx<'_>,
    what: &str,
    op: F,
) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, what)?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type(format!("{what} requires a Long argument")));
    };
    Ok(Value::Long(op(a, b)))
}
pub(crate) fn long_and(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.and", |a, b| a & b) }
pub(crate) fn long_or(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.or", |a, b| a | b) }
pub(crate) fn long_xor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> { long_binop(ctx, "Long.xor", |a, b| a ^ b) }
pub(crate) fn long_inv(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(!recv_int(ctx.args, "Long.inv")?))
}
pub(crate) fn long_shl(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.shl", |a, b| a.wrapping_shl((b & 63) as u32))
}
pub(crate) fn long_shr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.shr", |a, b| a.wrapping_shr((b & 63) as u32))
}
pub(crate) fn long_ushr(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    long_binop(ctx, "Long.ushr", |a, b| ((a as u64).wrapping_shr((b & 63) as u32)) as i64)
}
pub(crate) fn long_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let n = recv_int(ctx.args, "Long.toString")?;
    let radix = recv_int_radix(ctx.args.get(1), "Long.toString")?;
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} was not in valid range 2..36")),
        )));
    }
    Ok(Value::String(Arc::new(int_to_radix_string(n, radix as u32))))
}
pub(crate) fn long_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, "Long.compareTo")?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Long.compareTo requires a Long".into()));
    };
    Ok(Value::Int(if a < b { -1 } else { i32::from(a > b) }))
}
pub(crate) fn int_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_int(ctx.args, "Int.compareTo")?;
    let Some(b) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("Int.compareTo requires an Int".into()));
    };
    Ok(Value::Int(if a < b { -1 } else { i32::from(a > b) }))
}

// ============================================================
// Double members
// ============================================================

pub(crate) fn recv_double(args: &[Value], what: &str) -> Result<f64, RuntimeError> {
    args.first()
        .and_then(Value::as_f64)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a numeric receiver")))
}

pub(crate) fn recv_float(args: &[Value], what: &str) -> Result<f32, RuntimeError> {
    args.first()
        .and_then(Value::as_f32)
        .ok_or_else(|| RuntimeError::Type(format!("{what} requires a numeric receiver")))
}

pub(crate) fn double_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_double(ctx.args, "Double.toString")?;
    Ok(Value::String(Arc::new(klio_runtime::kotlin_double_to_string(d))))
}
pub(crate) fn double_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(f64_to_i32_kotlin(recv_double(ctx.args, "Double.toInt")?)))
}
pub(crate) fn double_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Long(f64_to_i64_kotlin(recv_double(ctx.args, "Double.toLong")?)))
}

/// Kotlin's `Double.toInt` semantics: truncate toward zero, saturate at
/// `Int.MIN_VALUE`/`Int.MAX_VALUE` for out-of-range, `NaN → 0`.
pub(crate) fn f64_to_i32_kotlin(d: f64) -> i32 {
    if d.is_nan() {
        return 0;
    }
    if d >= f64::from(i32::MAX) {
        return i32::MAX;
    }
    if d <= f64::from(i32::MIN) {
        return i32::MIN;
    }
    d as i32
}

pub(crate) fn f64_to_i64_kotlin(d: f64) -> i64 {
    if d.is_nan() {
        return 0;
    }
    if d >= i64::MAX as f64 {
        return i64::MAX;
    }
    if d <= i64::MIN as f64 {
        return i64::MIN;
    }
    d as i64
}

pub(crate) fn f32_to_i32_kotlin(d: f32) -> i32 {
    if d.is_nan() {
        return 0;
    }
    if d >= i32::MAX as f32 {
        return i32::MAX;
    }
    if d <= i32::MIN as f32 {
        return i32::MIN;
    }
    d as i32
}

pub(crate) fn f32_to_i64_kotlin(d: f32) -> i64 {
    if d.is_nan() {
        return 0;
    }
    if d >= i64::MAX as f32 {
        return i64::MAX;
    }
    if d <= i64::MIN as f32 {
        return i64::MIN;
    }
    d as i64
}
pub(crate) fn double_is_nan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isNaN")?.is_nan()))
}

// IEEE-754 bit reflection. `toRawBits` preserves the exact bit pattern;
// `toBits` collapses every NaN to the single canonical quiet NaN
// (matching `java.lang.Double.doubleToLongBits`/`Float.floatToIntBits`);
// `fromBits` reconstructs the value.
pub(crate) fn double_to_raw_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_double(ctx.args, "Double.toRawBits")?;
    Ok(Value::Long(d.to_bits() as i64))
}
pub(crate) fn double_to_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = recv_double(ctx.args, "Double.toBits")?;
    let bits = if d.is_nan() { 0x7ff8_0000_0000_0000u64 } else { d.to_bits() };
    Ok(Value::Long(bits as i64))
}
pub(crate) fn double_from_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let bits = ctx
        .args
        .iter()
        .rev()
        .find_map(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("Double.fromBits requires a Long".into()))?;
    Ok(Value::Double(f64::from_bits(bits as u64)))
}
pub(crate) fn float_to_raw_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let f = recv_float(ctx.args, "Float.toRawBits")?;
    Ok(Value::new_int(i64::from(f.to_bits() as i32)))
}
pub(crate) fn float_to_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let f = recv_float(ctx.args, "Float.toBits")?;
    let bits = if f.is_nan() { 0x7fc0_0000u32 } else { f.to_bits() };
    Ok(Value::new_int(i64::from(bits as i32)))
}
pub(crate) fn float_from_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let bits = ctx
        .args
        .iter()
        .rev()
        .find_map(Value::as_i64)
        .ok_or_else(|| RuntimeError::Type("Float.fromBits requires an Int".into()))?;
    Ok(Value::Float(f32::from_bits(bits as u32)))
}
pub(crate) fn double_is_infinite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isInfinite")?.is_infinite()))
}
pub(crate) fn double_is_finite(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Bool(recv_double(ctx.args, "Double.isFinite")?.is_finite()))
}
pub(crate) fn double_compare_to(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let a = recv_double(ctx.args, "Double.compareTo")?;
    let b = ctx.args.get(1).and_then(Value::as_f64).ok_or_else(|| {
        RuntimeError::Type("Double.compareTo requires a number".into())
    })?;
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    Ok(Value::Int(kotlin_float_total_cmp(a, b) as i32))
}

// ============================================================
// Boolean members
// ============================================================

pub(crate) fn bool_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Bool(b)) = ctx.args.first() else {
        return Err(RuntimeError::Type("Boolean.toString requires a Boolean".into()));
    };
    Ok(Value::String(Arc::new(b.to_string())))
}

// ============================================================
// Additional Int
// ============================================================

pub(crate) fn int_coerce_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceIn")?;
    match &ctx.args[1..] {
        [Value::Range { start, end, .. }] => {
            Ok(Value::new_int(v.max(*start).min(*end)))
        }
        [a, b] if a.is_integral() && b.is_integral() => {
            let lo = a.as_i64().unwrap();
            let hi = b.as_i64().unwrap();
            Ok(Value::new_int(v.max(lo).min(hi)))
        }
        _ => Err(RuntimeError::Type("coerceIn requires (min, max) or a range".into())),
    }
}

pub(crate) fn int_coerce_at_least(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceAtLeast")?;
    let Some(lo) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("coerceAtLeast requires an Int".into()));
    };
    Ok(Value::new_int(v.max(lo)))
}

pub(crate) fn int_coerce_at_most(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = recv_int(ctx.args, "Int.coerceAtMost")?;
    let Some(hi) = ctx.args.get(1).and_then(Value::as_i64) else {
        return Err(RuntimeError::Type("coerceAtMost requires an Int".into()));
    };
    Ok(Value::new_int(v.min(hi)))
}

/// `coerceIn` / `coerceAtLeast` / `coerceAtMost` for Long and Double
/// receivers (the Int forms have their own arms above). Composed from
/// `num_extreme` so the result keeps the receiver's numeric kind and
/// the same widening rules as `minOf`/`maxOf`.
/// `Int`/`Long`/… `floorDiv` — integer division rounded toward
/// negative infinity (Kotlin's `floorDiv`, distinct from `/` which
/// truncates toward zero). Result widens to `Long` if either operand
/// is `Long`, else `Int`.
/// `Int`/`Long`.`countLeadingZeroBits()` — leading zeros in the
/// two's-complement bit pattern (32 / 64 wide). Result is Int.
pub(crate) fn num_count_leading_zero_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countLeadingZeroBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).leading_zeros() as i32,
        Value::Int(v) => (*v as u32).leading_zeros() as i32,
        Value::Short(v) => (*v as u16).leading_zeros() as i32,
        Value::Byte(v) => (*v as u8).leading_zeros() as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countLeadingZeroBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(i64::from(n)))
}

/// `Int`/`Long`.`countTrailingZeroBits()`.
pub(crate) fn num_count_trailing_zero_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countTrailingZeroBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).trailing_zeros() as i32,
        Value::Int(v) => (*v as u32).trailing_zeros() as i32,
        Value::Short(v) => (*v as u16).trailing_zeros().min(16) as i32,
        Value::Byte(v) => (*v as u8).trailing_zeros().min(8) as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countTrailingZeroBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(i64::from(n)))
}

/// `Int`/`Long`.`countOneBits()` (population count).
pub(crate) fn num_count_one_bits(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .ok_or_else(|| RuntimeError::Arity("countOneBits".into()))?;
    let n = match recv {
        Value::Long(v) => (*v as u64).count_ones() as i32,
        Value::Int(v) => (*v as u32).count_ones() as i32,
        Value::Short(v) => (*v as u16).count_ones() as i32,
        Value::Byte(v) => (*v as u8).count_ones() as i32,
        other => {
            return Err(RuntimeError::Type(format!(
                "countOneBits requires an integer, got {other:?}"
            )))
        }
    };
    Ok(Value::new_int(i64::from(n)))
}

pub(crate) fn num_floor_div(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "floorDiv")?;
    let (x, y) = (
        a.as_i64()
            .ok_or_else(|| RuntimeError::Type("floorDiv requires integers".into()))?,
        b.as_i64()
            .ok_or_else(|| RuntimeError::Type("floorDiv requires integers".into()))?,
    );
    if y == 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: std::sync::Arc::new("kotlin.ArithmeticException".to_string()),
            message: Some(std::sync::Arc::new("/ by zero".to_string())),
            cause: None,
        }));
    }
    let mut q = x / y;
    let r = x % y;
    if r != 0 && ((r < 0) != (y < 0)) {
        q -= 1;
    }
    let wide = matches!(a, Value::Long(_)) || matches!(b, Value::Long(_));
    Ok(if wide {
        Value::Long(q)
    } else {
        Value::new_int(q)
    })
}

/// `Int`/`Long`/… `mod` — remainder whose sign follows the divisor
/// (Kotlin's `mod`, distinct from `%` whose sign follows the
/// dividend). Result widens to `Long` if either operand is `Long`.
pub(crate) fn num_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "mod")?;
    let (x, y) = (
        a.as_i64()
            .ok_or_else(|| RuntimeError::Type("mod requires integers".into()))?,
        b.as_i64()
            .ok_or_else(|| RuntimeError::Type("mod requires integers".into()))?,
    );
    if y == 0 {
        return Err(RuntimeError::Thrown(Value::Exception {
            fqn: std::sync::Arc::new("kotlin.ArithmeticException".to_string()),
            message: Some(std::sync::Arc::new("/ by zero".to_string())),
            cause: None,
        }));
    }
    let mut r = x % y;
    if r != 0 && ((r < 0) != (y < 0)) {
        r += y;
    }
    let wide = matches!(a, Value::Long(_)) || matches!(b, Value::Long(_));
    Ok(if wide {
        Value::Long(r)
    } else {
        Value::new_int(r)
    })
}

pub(crate) fn num_coerce_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceIn: missing receiver".into()))?;
    match &ctx.args[1..] {
        [Value::Range { start, end, .. }] => {
            let lo = num_extreme(&[recv, Value::Long(*start)], false, "coerceIn")?;
            num_extreme(&[lo, Value::Long(*end)], true, "coerceIn")
        }
        [min, max] => {
            let lo = num_extreme(&[recv, min.clone()], false, "coerceIn")?;
            num_extreme(&[lo, max.clone()], true, "coerceIn")
        }
        _ => Err(RuntimeError::Type(
            "coerceIn requires (min, max) or a range".into(),
        )),
    }
}

pub(crate) fn num_coerce_at_least(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtLeast: missing receiver".into()))?;
    let min = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtLeast requires a minimum".into()))?;
    num_extreme(&[recv, min], false, "coerceAtLeast")
}

pub(crate) fn num_coerce_at_most(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let recv = ctx
        .args
        .first()
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtMost: missing receiver".into()))?;
    let max = ctx
        .args
        .get(1)
        .cloned()
        .ok_or_else(|| RuntimeError::Arity("coerceAtMost requires a maximum".into()))?;
    num_extreme(&[recv, max], true, "coerceAtMost")
}

pub(crate) fn int_to_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Kotlin's `Int.toChar()` is a narrowing conversion: it keeps the low
    // 16 bits (the resulting UTF-16 code unit), never throwing.
    let v = recv_int(ctx.args, "Int.toChar")?;
    Ok(Value::Char(v as u16))
}

