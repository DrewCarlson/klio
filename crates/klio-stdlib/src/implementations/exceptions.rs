use super::{Value, Arc, CallCtx, RuntimeError, make_list};

// ============================================================
// Exceptions
// ============================================================

pub(crate) fn make_exception(fqn: &str, message: Option<String>) -> Value {
    Value::Exception {
        fqn: Arc::new(fqn.to_string()),
        message: message.map(Arc::new),
        cause: None,
    }
}

pub(crate) fn build_exception(ctx: &CallCtx<'_>, fqn: &str) -> Result<Value, RuntimeError> {
    // Throwable accepts up to two arguments per spec §3.12:
    //   (), (message), (cause), (message, cause).
    // A single Throwable-typed argument is treated as `cause`; anything else
    // becomes `message`.
    let (message, cause) = match (ctx.args.first(), ctx.args.get(1)) {
        (None, _) => (None, None),
        (Some(v), None) => {
            if matches!(v, Value::Exception { .. }) {
                (None, Some(Box::new(v.clone())))
            } else {
                let m = match v {
                    Value::Null => None,
                    Value::String(s) => Some((**s).clone()),
                    other => Some(format!("{other}")),
                };
                (m, None)
            }
        }
        (Some(m), Some(c)) => {
            let msg = match m {
                Value::Null => None,
                Value::String(s) => Some((**s).clone()),
                other => Some(format!("{other}")),
            };
            let cause = match c {
                Value::Null => None,
                // A builtin exception is `Value::Exception`; a user /
                // pack exception subclass is a `Value::Instance` of a
                // Throwable-derived class. Both are valid causes.
                Value::Exception { .. } | Value::Instance(_) => {
                    Some(Box::new(c.clone()))
                }
                _ => return Err(RuntimeError::Type(
                    "Throwable cause must be a Throwable or null".into(),
                )),
            };
            (msg, cause)
        }
    };
    Ok(Value::Exception {
        fqn: Arc::new(fqn.to_string()),
        message: message.map(Arc::new),
        cause,
    })
}

pub(crate) fn excn_throwable(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Throwable")
}
pub(crate) fn excn_exception(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Exception")
}
pub(crate) fn excn_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.Error")
}
pub(crate) fn excn_runtime(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.RuntimeException")
}
pub(crate) fn excn_illegal_argument(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IllegalArgumentException")
}
pub(crate) fn excn_illegal_state(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IllegalStateException")
}
pub(crate) fn excn_npe(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NullPointerException")
}
pub(crate) fn excn_ioob(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.IndexOutOfBoundsException")
}
pub(crate) fn excn_arithmetic(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ArithmeticException")
}
pub(crate) fn excn_class_cast(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ClassCastException")
}
pub(crate) fn excn_no_such_element(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NoSuchElementException")
}
pub(crate) fn excn_unsupported(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.UnsupportedOperationException")
}
pub(crate) fn excn_no_when(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NoWhenBranchMatchedException")
}
pub(crate) fn excn_number_format(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.NumberFormatException")
}
pub(crate) fn excn_concurrent_mod(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.ConcurrentModificationException")
}
pub(crate) fn excn_assertion_error(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    build_exception(ctx, "kotlin.AssertionError")
}

pub(crate) fn throwable_message(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Exception { message, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("message requires a Throwable receiver".into()));
    };
    Ok(message
        .as_ref()
        .map_or(Value::Null, |m| Value::String(Arc::clone(m))))
}

pub(crate) fn throwable_to_string(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(v @ Value::Exception { .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("toString requires a Throwable receiver".into()));
    };
    Ok(Value::String(Arc::new(format!("{v}"))))
}

/// `Throwable.addSuppressed(other)` — klio is single-threaded and
/// does not surface suppressed-exception chains in diagnostics, so
/// this records nothing. Accepts any throwable-shaped receiver.
pub(crate) fn throwable_add_suppressed(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(Value::Unit)
}

/// `Throwable.suppressedExceptions` / `getSuppressed()` — always
/// empty (see [`throwable_add_suppressed`]).
pub(crate) fn throwable_suppressed(_ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    Ok(make_list(Vec::new(), false))
}

pub(crate) fn throwable_cause(ctx: &mut CallCtx) -> Result<Value, RuntimeError> {
    let Some(Value::Exception { cause, .. }) = ctx.args.first() else {
        return Err(RuntimeError::Type("cause requires a Throwable receiver".into()));
    };
    Ok(cause.as_ref().map_or(Value::Null, |c| (**c).clone()))
}

