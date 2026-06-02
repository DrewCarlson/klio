use super::{CallCtx, Value, RuntimeError, BufRead, Arc};

// ============================================================
// io
// ============================================================

/// Render a value via its user-overridden `toString()` when one
/// exists, falling back to the runtime's structural Display
/// rendering. Used by `println` / `print` so plain-class instances
/// pick up `override fun toString()` rather than always landing on
/// the default `ClassName@<hex>` shape.
pub(crate) fn render_via_user_to_string(
    ctx: &mut CallCtx,
    v: &Value,
) -> String {
    if matches!(v, Value::Instance(_)) {
        let CallCtx { out, host, .. } = ctx;
        if let Some(Ok(Value::String(s))) =
            host.invoke_method(v, "toString", &[], *out)
        {
            return (*s).clone();
        }
    }
    format!("{v}")
}

pub(crate) fn io_println(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.len() {
        0 => {
            ctx.out.writeln("");
            Ok(Value::Unit)
        }
        1 => {
            let v = ctx.args[0].clone();
            let rendered = render_via_user_to_string(ctx, &v);
            ctx.out.writeln(&rendered);
            Ok(Value::Unit)
        }
        _ => Err(RuntimeError::Arity(format!(
            "println expects 0 or 1 arguments, got {}",
            ctx.args.len()
        ))),
    }
}

pub(crate) fn io_print(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    match ctx.args.len() {
        0 => Ok(Value::Unit),
        1 => {
            let v = ctx.args[0].clone();
            let rendered = render_via_user_to_string(ctx, &v);
            ctx.out.write(&rendered);
            Ok(Value::Unit)
        }
        _ => Err(RuntimeError::Arity(format!(
            "print expects 0 or 1 arguments, got {}",
            ctx.args.len()
        ))),
    }
}

pub(crate) fn io_read_line(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let mut buf = String::new();
    match std::io::stdin().lock().read_line(&mut buf) {
        Ok(0) => Ok(Value::Null),
        Ok(_) => {
            if buf.ends_with('\n') {
                buf.pop();
                if buf.ends_with('\r') {
                    buf.pop();
                }
            }
            Ok(Value::String(Arc::new(buf)))
        }
        Err(e) => Err(RuntimeError::Type(format!("readLine failed: {e}"))),
    }
}

