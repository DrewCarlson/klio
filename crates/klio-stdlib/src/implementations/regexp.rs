use super::*;

// ============================================================
// Regex / MatchResult / MatchGroup
// ============================================================

use klio_runtime::{MatchData, MatchGroupData, RegexData};

pub(crate) fn regex_arg(args: &[Value], what: &str) -> Result<Arc<RegexData>, RuntimeError> {
    match args.first() {
        Some(Value::Regex(r)) => Ok(Arc::clone(r)),
        _ => Err(RuntimeError::Type(format!("{what} requires a Regex receiver"))),
    }
}

/// Preprocess a Kotlin / Java-flavored pattern into a Rust-regex-compatible
/// pattern. Today: expand `\Q...\E` literal blocks (which Rust's `regex`
/// doesn't support) into byte-by-byte escaped equivalents.
pub(crate) fn preprocess_pattern(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.peek() {
                Some('Q') => {
                    chars.next();
                    let mut lit = String::new();
                    while let Some(&nc) = chars.peek() {
                        if nc == '\\' {
                            let mut clone = chars.clone();
                            clone.next();
                            if let Some('E') = clone.peek() {
                                chars.next();
                                chars.next();
                                break;
                            }
                        }
                        lit.push(nc);
                        chars.next();
                    }
                    out.push_str(&regex::escape(&lit));
                    continue;
                }
                Some(_) => {
                    out.push('\\');
                    out.push(chars.next().unwrap());
                    continue;
                }
                None => {
                    out.push('\\');
                    continue;
                }
            }
        }
        out.push(c);
    }
    out
}

pub(crate) fn compile_regex(pattern: &str) -> Result<Arc<RegexData>, RuntimeError> {
    let prepared = preprocess_pattern(pattern);
    match regex::Regex::new(&prepared) {
        Ok(re) => Ok(Arc::new(RegexData {
            pattern: Arc::new(pattern.to_string()),
            re,
        })),
        Err(e) => Err(RuntimeError::Thrown(make_exception(
            "kotlin.text.PatternSyntaxException",
            Some(format!("invalid regex: {e}")),
        ))),
    }
}

pub(crate) fn byte_to_char(s: &str, byte: usize) -> i64 {
    s[..byte].encode_utf16().count() as i64
}

pub(crate) fn build_match(re: &Arc<RegexData>, input: &Arc<String>, caps: regex::Captures<'_>) -> MatchData {
    let mut groups: Vec<Option<MatchGroupData>> = Vec::with_capacity(caps.len());
    for i in 0..caps.len() {
        match caps.get(i) {
            Some(m) => {
                let start = byte_to_char(input, m.start());
                let end = m.end();
                let end_char = byte_to_char(input, end);
                let end_inclusive = if end_char == 0 && start == 0 && m.as_str().is_empty() {
                    -1
                } else {
                    end_char - 1
                };
                groups.push(Some(MatchGroupData {
                    value: Arc::new(m.as_str().to_string()),
                    start,
                    end_inclusive,
                }));
            }
            None => groups.push(None),
        }
    }
    let end_byte = caps.get(0).map_or(0, |m| m.end());
    MatchData {
        input: Arc::clone(input),
        groups,
        end_byte,
        regex: Arc::clone(re),
    }
}

pub(crate) fn regex_ctor(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let pat = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type("Regex requires a String pattern".into())),
    };
    Ok(Value::Regex(compile_regex(&pat)?))
}

pub(crate) fn regex_pattern(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.pattern")?;
    Ok(Value::String(Arc::clone(&r.pattern)))
}

pub(crate) fn regex_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.toString")?;
    Ok(Value::String(Arc::clone(&r.pattern)))
}

pub(crate) fn regex_matches(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matches")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matches requires a String input".into())),
    };
    Ok(Value::Bool(
        r.re.find(&s).is_some_and(|m| m.start() == 0 && m.end() == s.len()),
    ))
}

pub(crate) fn regex_contains_match_in(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.containsMatchIn")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.containsMatchIn requires a String".into(),
        )),
    };
    Ok(Value::Bool(r.re.is_match(&s)))
}

pub(crate) fn regex_find(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.find")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.find requires a String".into())),
    };
    let start = match ctx.args.get(2) {
        None => 0usize,
        Some(v) if v.is_integral() => {
            let n = v.as_i64().unwrap();
            let mut bi = 0usize;
            for (i, (b, _)) in s.char_indices().enumerate() {
                if i as i64 == n {
                    bi = b;
                    break;
                }
                bi = s.len();
            }
            if n == 0 { 0 } else { bi }
        }
        _ => return Err(RuntimeError::Type("Regex.find startIndex must be Int".into())),
    };
    let caps = r.re.captures_at(&s, start);
    match caps {
        Some(c) => Ok(Value::Match(Arc::new(build_match(&r, &s, c)))),
        None => Ok(Value::Null),
    }
}

pub(crate) fn regex_find_all(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.findAll")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.findAll requires a String".into())),
    };
    let mut items = Vec::new();
    for caps in r.re.captures_iter(&s) {
        items.push(Value::Match(Arc::new(build_match(&r, &s, caps))));
    }
    Ok(make_sequence(items))
}

pub(crate) fn regex_match_entire(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matchEntire")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matchEntire requires a String".into())),
    };
    let Some(caps) = r.re.captures(&s) else { return Ok(Value::Null) };
    let m0 = caps.get(0).unwrap();
    if m0.start() == 0 && m0.end() == s.len() {
        Ok(Value::Match(Arc::new(build_match(&r, &s, caps))))
    } else {
        Ok(Value::Null)
    }
}

pub(crate) fn regex_match_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.matchAt")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.matchAt requires a String".into())),
    };
    let idx = match ctx.args.get(2).and_then(Value::as_i64) {
        Some(n) => n,
        _ => return Err(RuntimeError::Type("Regex.matchAt requires Int index".into())),
    };
    let mut byte = s.len();
    for (i, (b, _)) in s.char_indices().enumerate() {
        if i as i64 == idx {
            byte = b;
            break;
        }
    }
    let Some(caps) = r.re.captures_at(&s, byte) else { return Ok(Value::Null) };
    if caps.get(0).is_some_and(|m| m.start() == byte) {
        Ok(Value::Match(Arc::new(build_match(&r, &s, caps))))
    } else {
        Ok(Value::Null)
    }
}

pub(crate) fn regex_matches_at(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match regex_match_at(ctx)? {
        Value::Null => Ok(Value::Bool(false)),
        _ => Ok(Value::Bool(true)),
    }
}

/// Expand a Kotlin replacement template against a single match's
/// groups. Kotlin's syntax differs from Rust's: `$n` / `${n}` reference
/// a group by index, `${name}` references a named group, and `\`
/// escapes the next character (`\$` is a literal `$`, `\\` a literal
/// `\`). A `$` not followed by a digit or `{` is itself an error in
/// Kotlin; we emit it literally to stay total.
pub(crate) fn expand_kotlin_replacement(
    template: &str,
    regex: &RegexData,
    groups: &[Option<MatchGroupData>],
) -> String {
    let group_text = |idx: usize| -> &str {
        groups
            .get(idx)
            .and_then(|g| g.as_ref())
            .map(|g| g.value.as_str())
            .unwrap_or("")
    };
    let chars: Vec<char> = template.chars().collect();
    let mut out = String::with_capacity(template.len());
    let mut i = 0;
    while i < chars.len() {
        match chars[i] {
            '\\' => {
                if i + 1 < chars.len() {
                    out.push(chars[i + 1]);
                    i += 2;
                } else {
                    i += 1;
                }
            }
            '$' => {
                i += 1;
                if i < chars.len() && chars[i] == '{' {
                    i += 1;
                    let mut key = String::new();
                    while i < chars.len() && chars[i] != '}' {
                        key.push(chars[i]);
                        i += 1;
                    }
                    if i < chars.len() {
                        i += 1; // consume '}'
                    }
                    if let Ok(idx) = key.parse::<usize>() {
                        out.push_str(group_text(idx));
                    } else if let Some(idx) =
                        regex.re.capture_names().position(|n| n == Some(key.as_str()))
                    {
                        out.push_str(group_text(idx));
                    }
                } else {
                    let mut num = String::new();
                    while i < chars.len() && chars[i].is_ascii_digit() {
                        num.push(chars[i]);
                        i += 1;
                    }
                    if let Ok(idx) = num.parse::<usize>() {
                        out.push_str(group_text(idx));
                    } else {
                        out.push('$');
                    }
                }
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// Shared engine for `Regex.replace` / `Regex.replaceFirst` and the
/// `String.replace(Regex, …)` family. `repl` is either a `String`
/// template (Kotlin `$group` substitution) or a callable
/// `(MatchResult) -> CharSequence`.
pub(crate) fn perform_regex_replace(
    ctx: &mut CallCtx,
    r: &Arc<RegexData>,
    s: &Arc<String>,
    repl: Option<Value>,
    first_only: bool,
    who: &str,
) -> Result<Value, RuntimeError> {
    match repl {
        Some(Value::String(template)) => {
            let mut out = String::with_capacity(s.len());
            let mut last = 0usize;
            for caps in r.re.captures_iter(s) {
                let m0 = caps.get(0).unwrap();
                out.push_str(&s[last..m0.start()]);
                last = m0.end();
                let md = build_match(r, s, caps);
                out.push_str(&expand_kotlin_replacement(&template, r, &md.groups));
                if first_only {
                    break;
                }
            }
            out.push_str(&s[last..]);
            Ok(Value::String(Arc::new(out)))
        }
        Some(block) => {
            // Collect match spans first so the call-back borrow of `ctx`
            // does not overlap the regex iterator's borrow of `s`.
            let mut spans: Vec<(usize, usize, MatchData)> = Vec::new();
            for caps in r.re.captures_iter(s) {
                let m0 = caps.get(0).unwrap();
                let (start, end) = (m0.start(), m0.end());
                spans.push((start, end, build_match(r, s, caps)));
                if first_only {
                    break;
                }
            }
            let mut out = String::with_capacity(s.len());
            let mut last = 0usize;
            let CallCtx { out: sink, host, .. } = ctx;
            for (start, end, md) in spans {
                out.push_str(&s[last..start]);
                last = end;
                let mr = Value::Match(Arc::new(md));
                let rv = host.invoke_callable(&block, std::slice::from_ref(&mr), *sink)?;
                match rv {
                    Value::String(rs) => out.push_str(&rs),
                    Value::Char(c) => out.push_str(&char_unit_to_string(c)),
                    other => {
                        return Err(RuntimeError::Type(format!(
                            "{who} transform must return a CharSequence, got {other:?}"
                        )))
                    }
                }
            }
            out.push_str(&s[last..]);
            Ok(Value::String(Arc::new(out)))
        }
        None => Err(RuntimeError::Arity(format!("{who} requires a replacement"))),
    }
}

pub(crate) fn regex_replace(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replace")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replace requires a String".into())),
    };
    let repl = ctx.args.get(2).cloned();
    perform_regex_replace(ctx, &r, &s, repl, false, "Regex.replace")
}

pub(crate) fn regex_replace_first(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.replaceFirst")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.replaceFirst requires a String".into())),
    };
    let repl = ctx.args.get(2).cloned();
    perform_regex_replace(ctx, &r, &s, repl, true, "Regex.replaceFirst")
}

pub(crate) fn regex_split(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let r = regex_arg(ctx.args, "Regex.split")?;
    let s = match ctx.args.get(1) {
        Some(Value::String(s)) => s.clone(),
        _ => return Err(RuntimeError::Type("Regex.split requires a String".into())),
    };
    let limit = match ctx.args.get(2) {
        None => 0i64,
        Some(v) if v.is_integral() => v.as_i64().unwrap(),
        _ => return Err(RuntimeError::Type("Regex.split limit must be Int".into())),
    };
    let parts: Vec<&str> = if limit <= 0 {
        r.re.split(&s).collect()
    } else {
        r.re.splitn(&s, limit as usize).collect()
    };
    let items: Vec<Value> = parts
        .into_iter()
        .map(|p| Value::String(Arc::new(p.to_string())))
        .collect();
    Ok(make_list(items, false))
}

pub(crate) fn kotlin_literal_escape(s: &str) -> String {
    // Kotlin renders Regex.escape("x") as `\Qx\E`. The `\E` sentinel inside
    // the source itself needs to terminate and re-open the literal block.
    let parts: Vec<&str> = s.split("\\E").collect();
    let mut out = String::with_capacity(s.len() + 4);
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            out.push_str("\\E\\\\E\\Q");
        }
        out.push_str("\\Q");
        out.push_str(part);
        out.push_str("\\E");
    }
    if out.is_empty() {
        "\\Q\\E".into()
    } else {
        out
    }
}

pub(crate) fn regex_static_escape(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.escape requires a String literal".into(),
        )),
    };
    Ok(Value::String(Arc::new(kotlin_literal_escape(&s))))
}

pub(crate) fn regex_from_literal(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.fromLiteral requires a String".into(),
        )),
    };
    Ok(Value::Regex(compile_regex(&kotlin_literal_escape(&s))?))
}

pub(crate) fn regex_static_escape_replacement(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let s = match ctx.args.first() {
        Some(Value::String(s)) => (**s).clone(),
        _ => return Err(RuntimeError::Type(
            "Regex.escapeReplacement requires a String".into(),
        )),
    };
    // Rust's regex replacement only needs `$` escaped; `\` is literal.
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c == '$' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    Ok(Value::String(Arc::new(out)))
}

pub(crate) fn match_arg(args: &[Value], what: &str) -> Result<Arc<MatchData>, RuntimeError> {
    match args.first() {
        Some(Value::Match(m)) => Ok(Arc::clone(m)),
        _ => Err(RuntimeError::Type(format!(
            "{what} requires a MatchResult receiver"
        ))),
    }
}

pub(crate) fn match_result_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.value")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref()).ok_or_else(|| {
        RuntimeError::Type("MatchResult has no whole-match group".into())
    })?;
    Ok(Value::String(Arc::clone(&g0.value)))
}

pub(crate) fn match_result_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.range")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref()).ok_or_else(|| {
        RuntimeError::Type("MatchResult has no whole-match group".into())
    })?;
    Ok(Value::Range { start: g0.start, end: g0.end_inclusive, step: 1, kind: klio_runtime::RangeKind::Int })
}

pub(crate) fn match_result_group_values(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.groupValues")?;
    let items: Vec<Value> = m
        .groups
        .iter()
        .map(|g| match g {
            Some(gd) => Value::String(Arc::clone(&gd.value)),
            None => Value::String(Arc::new(String::new())),
        })
        .collect();
    Ok(make_list(items, false))
}

pub(crate) fn match_result_groups(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.groups")?;
    let items: Vec<Value> = m
        .groups
        .iter()
        .map(|g| match g {
            Some(gd) => Value::MatchGroup {
                value: Arc::clone(&gd.value),
                start: gd.start,
                end_inclusive: gd.end_inclusive,
            },
            None => Value::Null,
        })
        .collect();
    Ok(make_list(items, false))
}

pub(crate) fn match_result_next(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.next")?;
    let mut start = m.end_byte;
    // Avoid infinite loops on zero-width matches: advance one char.
    let g0 = m.groups.first().and_then(|g| g.as_ref());
    if let Some(g) = g0 {
        if g.end_inclusive < g.start {
            if let Some((next_b, _)) = m.input[start..].char_indices().nth(1) {
                start += next_b;
            } else {
                start = m.input.len();
            }
        }
    }
    if start > m.input.len() {
        return Ok(Value::Null);
    }
    match m.regex.re.captures_at(&m.input, start) {
        Some(c) => Ok(Value::Match(Arc::new(build_match(&m.regex, &m.input, c)))),
        None => Ok(Value::Null),
    }
}

pub(crate) fn match_result_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let m = match_arg(ctx.args, "MatchResult.toString")?;
    let g0 = m.groups.first().and_then(|g| g.as_ref());
    Ok(Value::String(Arc::new(
        g0.map(|g| (*g.value).clone()).unwrap_or_default(),
    )))
}

pub(crate) fn match_group_value(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.first() {
        Some(Value::MatchGroup { value, .. }) => Ok(Value::String(Arc::clone(value))),
        _ => Err(RuntimeError::Type(
            "MatchGroup.value requires a MatchGroup receiver".into(),
        )),
    }
}

pub(crate) fn match_group_range(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.first() {
        Some(Value::MatchGroup { start, end_inclusive, .. }) => Ok(Value::Range {
            start: *start,
            end: *end_inclusive,
            step: 1,
            kind: klio_runtime::RangeKind::Int,
        }),
        _ => Err(RuntimeError::Type(
            "MatchGroup.range requires a MatchGroup receiver".into(),
        )),
    }
}

