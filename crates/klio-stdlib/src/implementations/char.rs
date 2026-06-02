use super::{Arc, CallCtx, RuntimeError, Value, char, char_unit_to_string, make_exception};

// ============================================================
// Char members
// ============================================================

pub(crate) fn recv_char(args: &[Value], what: &str) -> Result<u16, RuntimeError> {
    match args.first() {
        Some(Value::Char(c)) => Ok(*c),
        Some(other) => Err(RuntimeError::Type(format!(
            "{what} requires a Char receiver, got {other:?}"
        ))),
        None => Err(RuntimeError::Type(format!("{what} requires a receiver"))),
    }
}

/// Decode a `Char` code unit to a Unicode scalar for category/case
/// queries. A lone surrogate has no scalar value (`None`): such chars are
/// not letters/digits/whitespace and have no case mapping.
pub(crate) fn char_unit_to_scalar(unit: u16) -> Option<char> {
    char::from_u32(u32::from(unit))
}

pub(crate) fn char_code(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::new_int(u32::from(recv_char(ctx.args, "Char.code")?)))
}

fn imod(a: i64, b: i64) -> i64 {
    let m = a.rem_euclid(b);
    if m >= 0 { m } else { m + b }
}

// Result narrows back to a Kotlin Int when the progression was Int-typed.
#[allow(clippy::cast_possible_truncation)]
pub(crate) fn internal_get_progression_last_element(
    ctx: &mut CallCtx,
) -> Result<Value, RuntimeError> {
    let args = ctx.args;
    if args.len() != 3 {
        return Err(RuntimeError::Type(
            "getProgressionLastElement expects (start, end, step)".into(),
        ));
    }
    let (start, end, step, is_long) = match (&args[0], &args[1], &args[2]) {
        (Value::Long(s), Value::Long(e), Value::Long(p)) => (*s, *e, *p, true),
        (Value::Int(s), Value::Int(e), Value::Int(p)) => {
            (i64::from(*s), i64::from(*e), i64::from(*p), false)
        }
        _ => {
            return Err(RuntimeError::Type(
                "getProgressionLastElement: args must be all Int or all Long".into(),
            ));
        }
    };
    let last = match step.cmp(&0) {
        std::cmp::Ordering::Greater => {
            if start >= end {
                end
            } else {
                let diff = imod(imod(end, step) - imod(start, step), step);
                end - diff
            }
        }
        std::cmp::Ordering::Less => {
            if start <= end {
                end
            } else {
                let neg = -step;
                let diff = imod(imod(start, neg) - imod(end, neg), neg);
                end + diff
            }
        }
        std::cmp::Ordering::Equal => {
            return Err(RuntimeError::Type("Step is zero.".into()));
        }
    };
    if is_long {
        Ok(Value::Long(last))
    } else {
        Ok(Value::new_int(last as i32))
    }
}
// Char predicates follow kotlinc-native 2.3.21 semantics, driven by Unicode
// general categories rather than Rust's `char::is_*` (which differ on a
// handful of historic scripts, special whitespace, and digit ranges).

pub(crate) fn kt_is_letter(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    matches!(
        unicode_general_category::get_general_category(c),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
    )
}

pub(crate) fn kt_is_digit(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::DecimalNumber
}

// kotlinc-native 2.3.21 whitespace table (from stdlib/native-wasm
// _WhitespaceChars.kt). This is a fixed enumerated set — not Java's
// Character.isWhitespace (which excludes NBSP) and not Rust's
// char::is_whitespace (which excludes 0x1C..=0x1F).
pub(crate) fn kt_is_whitespace(c: char) -> bool {
    let code = c as u32;
    matches!(
        code,
        0x0009..=0x000D
            | 0x001C..=0x0020
            | 0x00A0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
    )
}

pub(crate) fn is_other_uppercase(code: u32) -> bool {
    matches!(code, 0x2160..=0x216F | 0x24B6..=0x24CF | 0x1F130..=0x1F149 | 0x1F150..=0x1F169 | 0x1F170..=0x1F189)
}

// Other_Lowercase contributory property (Unicode 15.x snapshot used by kotlinc-native 2.3.21).
pub(crate) fn is_other_lowercase(code: u32) -> bool {
    const RANGES: &[(u32, u32)] = &[
        (0x00AA, 0x00AA),
        (0x00BA, 0x00BA),
        (0x02B0, 0x02B8),
        (0x02C0, 0x02C1),
        (0x02E0, 0x02E4),
        (0x0345, 0x0345),
        (0x037A, 0x037A),
        (0x1D2C, 0x1D6A),
        (0x1D78, 0x1D78),
        (0x1D9B, 0x1DBF),
        (0x2071, 0x2071),
        (0x207F, 0x207F),
        (0x2090, 0x209C),
        (0x2170, 0x217F),
        (0x24D0, 0x24E9),
        (0x2C7C, 0x2C7D),
        (0xA69C, 0xA69D),
        (0xA770, 0xA770),
        (0xA7F8, 0xA7F9),
        (0xAB5C, 0xAB5F),
    ];
    RANGES.iter().any(|&(lo, hi)| code >= lo && code <= hi)
}

pub(crate) fn kt_is_upper_case(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::UppercaseLetter
        || is_other_uppercase(c as u32)
}

pub(crate) fn kt_is_lower_case(c: char) -> bool {
    use unicode_general_category::GeneralCategory as G;
    unicode_general_category::get_general_category(c) == G::LowercaseLetter
        || is_other_lowercase(c as u32)
}

pub(crate) fn char_is_digit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isDigit")?);
    Ok(Value::Bool(s.is_some_and(kt_is_digit)))
}
pub(crate) fn char_is_letter(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isLetter")?);
    Ok(Value::Bool(s.is_some_and(kt_is_letter)))
}
pub(crate) fn char_is_letter_or_digit(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isLetterOrDigit")?);
    Ok(Value::Bool(
        s.is_some_and(|c| kt_is_letter(c) || kt_is_digit(c)),
    ))
}
pub(crate) fn char_is_whitespace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isWhitespace")?);
    Ok(Value::Bool(s.is_some_and(kt_is_whitespace)))
}
pub(crate) fn char_is_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isUpperCase")?);
    Ok(Value::Bool(s.is_some_and(kt_is_upper_case)))
}
pub(crate) fn char_is_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = char_unit_to_scalar(recv_char(ctx.args, "Char.isLowerCase")?);
    Ok(Value::Bool(s.is_some_and(kt_is_lower_case)))
}
pub(crate) fn char_uppercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.uppercase")?;
    match char_unit_to_scalar(unit) {
        Some(c) => Ok(Value::String(Arc::new(c.to_uppercase().collect()))),
        None => Ok(Value::String(Arc::new(char_unit_to_string(unit)))),
    }
}
pub(crate) fn char_lowercase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.lowercase")?;
    match char_unit_to_scalar(unit) {
        Some(c) => Ok(Value::String(Arc::new(c.to_lowercase().collect()))),
        None => Ok(Value::String(Arc::new(char_unit_to_string(unit)))),
    }
}
pub(crate) fn char_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::String(Arc::new(char_unit_to_string(recv_char(
        ctx.args,
        "Char.toString",
    )?))))
}
/// The radix argument of `digitToInt(radix)` / `digitToIntOrNull(radix)`,
/// validated to Kotlin's 2..36 range (default 10). Returns the radix or an
/// `IllegalArgumentException`.
// `radix` is already validated to 2..=36, so the narrowing cast is exact.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn char_digit_radix(args: &[Value]) -> Result<u32, RuntimeError> {
    let radix = args.get(1).and_then(Value::as_i64).unwrap_or(10);
    if !(2..=36).contains(&radix) {
        return Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!("radix {radix} is not in valid range 2..36")),
        )));
    }
    Ok(radix as u32)
}

pub(crate) fn char_digit_to_int(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.digitToInt")?;
    let radix = char_digit_radix(ctx.args)?;
    match char_unit_to_scalar(unit).and_then(|c| c.to_digit(radix)) {
        Some(d) => Ok(Value::new_int(d)),
        None => Err(RuntimeError::Thrown(make_exception(
            "kotlin.IllegalArgumentException",
            Some(format!(
                "Char {:?} is not a digit in the given radix={radix}",
                char_unit_to_string(unit)
            )),
        ))),
    }
}

pub(crate) fn char_is_high_surrogate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.isHighSurrogate")?;
    Ok(Value::Bool((0xD800..=0xDBFF).contains(&c)))
}
pub(crate) fn char_is_low_surrogate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.isLowSurrogate")?;
    Ok(Value::Bool((0xDC00..=0xDFFF).contains(&c)))
}
pub(crate) fn char_is_surrogate(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let c = recv_char(ctx.args, "Char.isSurrogate")?;
    Ok(Value::Bool((0xD800..=0xDFFF).contains(&c)))
}

// ============================================================
// Additional Char
// ============================================================

/// Single-Char case mapping: Kotlin's `uppercaseChar()/lowercaseChar()` return
/// the original char when the full case mapping isn't a single character
/// (e.g. 'ß'.`uppercaseChar()` == 'ß', not 'S' — only the multi-char
/// `uppercase()` yields "SS").
pub(crate) fn single_case_char(c: char, mut mapping: impl Iterator<Item = char>) -> char {
    let first = mapping.next().unwrap_or(c);
    if mapping.next().is_some() { c } else { first }
}
pub(crate) fn char_uppercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.uppercaseChar")?;
    Ok(Value::Char(match char_unit_to_scalar(unit) {
        Some(c) => single_case_char(c, c.to_uppercase()) as u16,
        None => unit,
    }))
}
pub(crate) fn char_lowercase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.lowercaseChar")?;
    Ok(Value::Char(match char_unit_to_scalar(unit) {
        Some(c) => single_case_char(c, c.to_lowercase()) as u16,
        None => unit,
    }))
}
pub(crate) fn char_digit_to_int_or_null(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.digitToIntOrNull")?;
    let radix = char_digit_radix(ctx.args)?;
    Ok(char_unit_to_scalar(unit)
        .and_then(|c| c.to_digit(radix))
        .map_or(Value::Null, Value::new_int))
}

// ============================================================
// Char title-case
// ============================================================

pub(crate) fn char_titlecase(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.titlecase")?;
    // Most chars: titlecase == uppercase. Three diacritic ligatures (U+01C5,
    // U+01C8, U+01CB, U+01F2) and a handful of compatibility lowercase chars
    // map to a multi-char title form; we approximate via uppercase().
    match char_unit_to_scalar(unit) {
        Some(c) => Ok(Value::String(Arc::new(c.to_uppercase().collect()))),
        None => Ok(Value::String(Arc::new(char_unit_to_string(unit)))),
    }
}

pub(crate) fn char_titlecase_char(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let unit = recv_char(ctx.args, "Char.titlecaseChar")?;
    // Title-case 1:1 mapping — for chars without a specific title form this
    // is the uppercase mapping, and (like uppercaseChar) the original char
    // when the uppercase mapping isn't a single character ('ß' -> 'ß').
    Ok(Value::Char(match char_unit_to_scalar(unit) {
        Some(c) => single_case_char(c, c.to_uppercase()) as u16,
        None => unit,
    }))
}
