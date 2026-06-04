use super::{
    CallCtx, RuntimeError, Value, compare_host_aware, compare_values, make_exception, recv_double,
};

// ============================================================
// math
// ============================================================

pub(crate) fn as_double(v: &Value, what: &str) -> Result<f64, RuntimeError> {
    // Accept every numeric type (Float/Long/Short/Byte too), each widening
    // to f64 like Kotlin's numeric conversions, so math intrinsics aren't
    // limited to `Double`/`Int` operands.
    numeric_as_f64(v).ok_or_else(|| {
        RuntimeError::Type(format!("{what} requires a number, got {v:?}"))
    })
}

pub(crate) fn math_abs(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args {
        [Value::Int(n)] => Ok(Value::Int(n.wrapping_abs())),
        [Value::Long(n)] => Ok(Value::Long(n.wrapping_abs())),
        [Value::Double(n)] => Ok(Value::Double(n.abs())),
        [Value::Float(n)] => Ok(Value::Float(n.abs())),
        _ => Err(RuntimeError::Type("abs requires a number".into())),
    }
}

fn numeric_as_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Int(x) => Some(f64::from(*x)),
        // Kotlin Long widens to Double (may lose precision past 2^53).
        #[allow(clippy::cast_precision_loss)]
        Value::Long(x) => Some(*x as f64),
        Value::Short(x) => Some(f64::from(*x)),
        Value::Byte(x) => Some(f64::from(*x)),
        Value::Float(x) => Some(f64::from(*x)),
        Value::Double(x) => Some(*x),
        _ => None,
    }
}

fn numeric_as_i64(v: &Value) -> Option<i64> {
    match v {
        Value::Int(x) => Some(i64::from(*x)),
        Value::Long(x) => Some(*x),
        Value::Short(x) => Some(i64::from(*x)),
        Value::Byte(x) => Some(i64::from(*x)),
        _ => None,
    }
}

/// Numeric `min`/`max` over any Kotlin number pair (Byte/Short/Int/
/// Long/Float/Double, including mixed). Doubles as the
/// `kotlin.comparisons.minOf`/`maxOf` and `kotlin.math.min`/`max`
/// implementation. Integral pairs keep an integral result (widened
/// to the larger of the two so e.g. `minOf(Long, Int)` is a Long);
/// any floating operand promotes the result to Double.
pub(crate) fn num_extreme(
    args: &[Value],
    want_min: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    let [first, second] = args else {
        return Err(RuntimeError::Arity(format!("{what} expects 2 arguments")));
    };
    let floating = matches!(first, Value::Double(_) | Value::Float(_))
        || matches!(second, Value::Double(_) | Value::Float(_));
    if floating {
        let (x, y) = (
            numeric_as_f64(first)
                .ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
            numeric_as_f64(second)
                .ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
        );
        // Kotlin's minOf/maxOf use Math.min/max, which propagate NaN — unlike
        // Rust's f64::min/max which return the non-NaN operand.
        return Ok(Value::Double(if x.is_nan() || y.is_nan() {
            f64::NAN
        } else if want_min {
            x.min(y)
        } else {
            x.max(y)
        }));
    }
    let (x, y) = (
        numeric_as_i64(first)
            .ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
        numeric_as_i64(second)
            .ok_or_else(|| RuntimeError::Type(format!("{what}: non-numeric arg")))?,
    );
    let r = if want_min { x.min(y) } else { x.max(y) };
    // Widen to Long if either operand was Long; otherwise Int.
    if matches!(first, Value::Long(_)) || matches!(second, Value::Long(_)) {
        Ok(Value::Long(r))
    } else {
        // Kotlin Int min/max keeps an Int result.
        #[allow(clippy::cast_possible_truncation)]
        Ok(Value::Int(r as i32))
    }
}

pub(crate) fn math_min(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    cmp_extreme(ctx, true, "min")
}

pub(crate) fn math_max(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    cmp_extreme(ctx, false, "max")
}

pub(crate) fn cmp_extreme(
    ctx: &mut CallCtx,
    want_min: bool,
    what: &str,
) -> Result<Value, RuntimeError> {
    // Instance-aware path: a user receiver implementing Comparable
    // (`operator fun compareTo`) reaches min/max via call_member,
    // falling back to the primitive num_extreme for plain numbers.
    if let [a, b] = ctx.args {
        if matches!(a, Value::Instance(_)) || matches!(b, Value::Instance(_)) {
            let CallCtx { out, host, .. } = ctx;
            let ord = compare_host_aware(a, b, host, *out)?;
            let pick_first = if want_min {
                ord != std::cmp::Ordering::Greater
            } else {
                ord != std::cmp::Ordering::Less
            };
            return Ok(if pick_first { a.clone() } else { b.clone() });
        }
        // Numeric operands use `num_extreme` (width widening +
        // Math.min/max NaN propagation). Any other `Comparable`
        // (`maxOf("a","b")`, Char) picks by the total comparison
        // order, mirroring the generic `maxOf<T : Comparable<T>>`.
        if !(a.is_numeric() && b.is_numeric()) {
            let ord = compare_values(a, b)?;
            let pick_first = if want_min {
                ord != std::cmp::Ordering::Greater
            } else {
                ord != std::cmp::Ordering::Less
            };
            return Ok(if pick_first { a.clone() } else { b.clone() });
        }
    }
    num_extreme(ctx.args, want_min, what)
}

pub(crate) fn math_sqrt(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let [v] = ctx.args else {
        return Err(RuntimeError::Arity("sqrt expects 1 argument".into()));
    };
    Ok(Value::Double(as_double(v, "sqrt")?.sqrt()))
}

/// `Double.pow(Double)` and `Double.pow(Int)` — Kotlin's only `pow` shape.
/// Receiver is `args[0]`, exponent is `args[1]`.
pub(crate) fn double_pow(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Double.pow expects 1 argument".into()));
    }
    let base = recv_double(ctx.args, "Double.pow")?;
    let exp = as_double(&ctx.args[1], "Double.pow")?;
    Ok(Value::Double(base.powf(exp)))
}

/// `Float.pow(Float)` / `Float.pow(Int)` — like `Double.pow` but keeping a
/// `Float` result.
pub(crate) fn float_pow(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity("Float.pow expects 1 argument".into()));
    }
    #[allow(clippy::cast_possible_truncation)]
    let base = recv_double(ctx.args, "Float.pow")? as f32;
    #[allow(clippy::cast_possible_truncation)]
    let exp = as_double(&ctx.args[1], "Float.pow")? as f32;
    Ok(Value::Float(base.powf(exp)))
}

pub(crate) fn math_sinh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "sinh")?, "sinh")?.sinh()))
}
pub(crate) fn math_cosh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "cosh")?, "cosh")?.cosh()))
}
pub(crate) fn math_tanh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "tanh")?, "tanh")?.tanh()))
}
pub(crate) fn math_asinh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "asinh")?, "asinh")?.asinh()))
}
pub(crate) fn math_acosh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "acosh")?, "acosh")?.acosh()))
}
pub(crate) fn math_atanh(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "atanh")?, "atanh")?.atanh()))
}
pub(crate) fn math_expm1(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "expm1")?, "expm1")?.exp_m1()))
}
pub(crate) fn math_ln1p(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "ln1p")?, "ln1p")?.ln_1p()))
}

pub(crate) fn math_sin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "sin")?, "sin")?.sin()))
}
pub(crate) fn math_cos(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "cos")?, "cos")?.cos()))
}
pub(crate) fn math_tan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "tan")?, "tan")?.tan()))
}
pub(crate) fn math_ln(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "ln")?, "ln")?.ln()))
}
pub(crate) fn math_log(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (x, base) = arg2(ctx, "log")?;
    Ok(Value::Double(
        as_double(x, "log")?.log(as_double(base, "log")?),
    ))
}
pub(crate) fn math_log10(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(
        as_double(arg1(ctx, "log10")?, "log10")?.log10(),
    ))
}
pub(crate) fn math_log2(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "log2")?, "log2")?.log2()))
}
pub(crate) fn math_exp(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "exp")?, "exp")?.exp()))
}
pub(crate) fn math_floor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(
        as_double(arg1(ctx, "floor")?, "floor")?.floor(),
    ))
}
pub(crate) fn math_ceil(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "ceil")?, "ceil")?.ceil()))
}
pub(crate) fn math_round(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    // Kotlin's kotlin.math.round rounds half to even (IEEE rint), unlike
    // Rust's round() which rounds half away from zero.
    Ok(Value::Double(
        as_double(arg1(ctx, "round")?, "round")?.round_ties_even(),
    ))
}
pub(crate) fn math_truncate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(
        as_double(arg1(ctx, "truncate")?, "truncate")?.trunc(),
    ))
}
pub(crate) fn math_hypot(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "hypot")?;
    Ok(Value::Double(
        as_double(a, "hypot")?.hypot(as_double(b, "hypot")?),
    ))
}
/// Kotlin's sign preserves a signed/NaN zero: sign(0.0)=0.0, sign(-0.0)=-0.0,
/// sign(NaN)=NaN. Rust's `signum()` returns ±1.0 for zero, so special-case it.
fn fsign(n: f64) -> f64 {
    if n == 0.0 || n.is_nan() {
        n
    } else {
        n.signum()
    }
}

pub(crate) fn math_sign(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let v = arg1(ctx, "sign")?;
    match v {
        Value::Int(n) => Ok(Value::Int(n.signum())),
        // Long.signum() yields -1/0/1, which always fits an Int.
        #[allow(clippy::cast_possible_truncation)]
        Value::Long(n) => Ok(Value::Int(n.signum() as i32)),
        // Float.sign stays a Float.
        #[allow(clippy::cast_possible_truncation)]
        Value::Float(n) => Ok(Value::Float(fsign(f64::from(*n)) as f32)),
        Value::Double(n) => Ok(Value::Double(fsign(*n))),
        other => Err(RuntimeError::Type(format!(
            "sign requires a number, got {other:?}"
        ))),
    }
}

pub(crate) fn math_cbrt(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "cbrt")?, "cbrt")?.cbrt()))
}

/// `roundToInt()` / `roundToLong()`: round half toward +∞ (Java `Math.round`),
/// throw on NaN, clamp out-of-range to the type's MIN/MAX.
// Kotlin roundToInt() truncates the clamped Double into an Int.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn num_round_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = as_double(arg1(ctx, "roundToInt")?, "roundToInt")?;
    if d.is_nan() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some("Cannot round NaN value.".into()),
        )));
    }
    let r = (d + 0.5).floor();
    let v = if r >= f64::from(i32::MAX) {
        i32::MAX
    } else if r <= f64::from(i32::MIN) {
        i32::MIN
    } else {
        r as i32
    };
    Ok(Value::Int(v))
}

// Kotlin roundToLong() compares against i64 bounds as Double and truncates.
#[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
pub(crate) fn num_round_to_long(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let d = as_double(arg1(ctx, "roundToLong")?, "roundToLong")?;
    if d.is_nan() {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some("Cannot round NaN value.".into()),
        )));
    }
    let r = (d + 0.5).floor();
    let v = if r >= i64::MAX as f64 {
        i64::MAX
    } else if r <= i64::MIN as f64 {
        i64::MIN
    } else {
        r as i64
    };
    Ok(Value::Long(v))
}

// Kotlin takeHighestOneBit reinterprets bits between signed/unsigned.
#[allow(clippy::cast_sign_loss, clippy::cast_possible_wrap)]
pub(crate) fn num_take_highest_one_bit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match arg1(ctx, "takeHighestOneBit")? {
        Value::Int(n) => {
            let u = *n as u32;
            Ok(Value::Int(if u == 0 {
                0
            } else {
                (1u32 << u.ilog2()) as i32
            }))
        }
        Value::Long(n) => {
            let u = *n as u64;
            Ok(Value::Long(if u == 0 {
                0
            } else {
                (1u64 << u.ilog2()) as i64
            }))
        }
        other => Err(RuntimeError::Type(format!(
            "takeHighestOneBit requires an integer, got {other:?}"
        ))),
    }
}

pub(crate) fn num_take_lowest_one_bit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match arg1(ctx, "takeLowestOneBit")? {
        Value::Int(n) => Ok(Value::Int(n & n.wrapping_neg())),
        Value::Long(n) => Ok(Value::Long(n & n.wrapping_neg())),
        other => Err(RuntimeError::Type(format!(
            "takeLowestOneBit requires an integer, got {other:?}"
        ))),
    }
}

// rem_euclid bounds the shift to 0..width before the rotate cast.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn num_rotate_left(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rotateLeft")?;
    let n = b
        .as_i64()
        .ok_or_else(|| RuntimeError::Type("rotateLeft bitCount must be Int".into()))?;
    match a {
        Value::Int(x) => Ok(Value::Int(x.rotate_left(n.rem_euclid(32) as u32))),
        Value::Long(x) => Ok(Value::Long(x.rotate_left(n.rem_euclid(64) as u32))),
        other => Err(RuntimeError::Type(format!(
            "rotateLeft requires an integer, got {other:?}"
        ))),
    }
}

// rem_euclid bounds the shift to 0..width before the rotate cast.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn num_rotate_right(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rotateRight")?;
    let n = b
        .as_i64()
        .ok_or_else(|| RuntimeError::Type("rotateRight bitCount must be Int".into()))?;
    match a {
        Value::Int(x) => Ok(Value::Int(x.rotate_right(n.rem_euclid(32) as u32))),
        Value::Long(x) => Ok(Value::Long(x.rotate_right(n.rem_euclid(64) as u32))),
        other => Err(RuntimeError::Type(format!(
            "rotateRight requires an integer, got {other:?}"
        ))),
    }
}

/// `Double.rem(Double)` / `Float.rem` — IEEE remainder (sign of dividend),
/// same as the `%` operator.
// Float.rem narrows the Double result back to Float.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn num_float_rem(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (a, b) = arg2(ctx, "rem")?;
    let r = as_double(a, "rem")? % as_double(b, "rem")?;
    Ok(if matches!(a, Value::Float(_)) {
        Value::Float(r as f32)
    } else {
        Value::Double(r)
    })
}

/// `Double.mod(Double)` / `Float.mod` — floored modulus (sign of divisor).
// Float.mod narrows the Double result back to Float.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn num_float_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (lhs, rhs) = arg2(ctx, "mod")?;
    let (dividend, divisor) = (as_double(lhs, "mod")?, as_double(rhs, "mod")?);
    let mut rem = dividend % divisor;
    if rem != 0.0 && (rem < 0.0) != (divisor < 0.0) {
        rem += divisor;
    }
    Ok(if matches!(lhs, Value::Float(_)) {
        Value::Float(rem as f32)
    } else {
        Value::Double(rem)
    })
}

// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn math_pi(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(std::f64::consts::PI))
}
// Result signature kept to match the builtin handler function-pointer table.
#[allow(clippy::unnecessary_wraps)]
pub(crate) fn math_e(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(std::f64::consts::E))
}

pub(crate) fn arg1<'a>(ctx: &'a CallCtx<'_>, what: &str) -> Result<&'a Value, RuntimeError> {
    if ctx.args.len() != 1 {
        return Err(RuntimeError::Arity(format!("{what} expects 1 argument")));
    }
    Ok(&ctx.args[0])
}

pub(crate) fn arg2<'a>(
    ctx: &'a CallCtx<'_>,
    what: &str,
) -> Result<(&'a Value, &'a Value), RuntimeError> {
    if ctx.args.len() != 2 {
        return Err(RuntimeError::Arity(format!("{what} expects 2 arguments")));
    }
    Ok((&ctx.args[0], &ctx.args[1]))
}

// ============================================================
// Additional math
// ============================================================

pub(crate) fn math_asin(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "asin")?, "asin")?.asin()))
}
pub(crate) fn math_acos(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "acos")?, "acos")?.acos()))
}
pub(crate) fn math_atan(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Double(as_double(arg1(ctx, "atan")?, "atan")?.atan()))
}
pub(crate) fn math_atan2(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let (y, x) = arg2(ctx, "atan2")?;
    Ok(Value::Double(
        as_double(y, "atan2")?.atan2(as_double(x, "atan2")?),
    ))
}
