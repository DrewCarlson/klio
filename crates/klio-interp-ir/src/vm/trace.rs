//! Env-gated dispatch tracing for diagnosing name-resolution bugs.
//!
//! A bare call (`f(x)`) on an overloaded / member / extension name binds
//! one `FuncId`, and several layers can pick the wrong one: lower-time
//! arity binding, runtime `pick_overload`, member-vs-global precedence,
//! the receiver chain inside a coroutine/lambda block. When a program
//! mis-dispatches it is hard to see *which* layer chose *which* target.
//!
//! Set `KLIO_TRACE_RESOLVE` to a comma-separated list of simple function
//! names (or `*` for every call) to log each dispatch decision to stderr:
//!
//! ```text
//! KLIO_TRACE_RESOLVE=execute,async  klio run prog.kt
//! [RESOLVE] call_func execute fid=1873 fqn=io.ktor.client.engine.klio.KlioClientEngine.execute argc=1
//! [RESOLVE] member-pick execute recv=DefaultSender -> fid=204 (of 1)
//! [RESOLVE] global-overload execute -> fid=204 (of 3 candidates)
//! ```
//!
//! Zero cost when unset: the filter is parsed from the environment once
//! and cached, and every trace point is guarded by [`enabled`], so a
//! disabled trace is a single relaxed atomic load and a set lookup that
//! never runs.

use std::collections::HashSet;
use std::sync::OnceLock;

static FILTER: OnceLock<Option<HashSet<String>>> = OnceLock::new();

fn filter() -> Option<&'static HashSet<String>> {
    FILTER
        .get_or_init(|| {
            std::env::var("KLIO_TRACE_RESOLVE").ok().map(|s| {
                s.split(',')
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
        })
        .as_ref()
}

/// True when dispatch decisions for `name` should be logged.
pub(crate) fn enabled(name: &str) -> bool {
    filter().is_some_and(|set| set.contains("*") || set.contains(name))
}

/// Emit one trace line (callers gate with [`enabled`] via `trace_resolve!`).
pub(crate) fn emit(args: std::fmt::Arguments<'_>) {
    eprintln!("[RESOLVE] {args}");
}

/// A short receiver-kind label for a dispatch trace (the runtime value's
/// class name for an instance, or a coarse variant tag otherwise).
pub(crate) fn recv_label(v: &klio_runtime::Value) -> String {
    use klio_runtime::Value;
    match v {
        Value::Instance(i) => i.borrow().class.name.clone(),
        Value::Class(c) => format!("Class({})", c.name),
        Value::String(_) => "String".into(),
        Value::Array { .. } => "Array".into(),
        Value::Null => "Null".into(),
        Value::Unit => "Unit".into(),
        other => format!("{}", DiscriminantOnly(other)),
    }
}

struct DiscriminantOnly<'a>(&'a klio_runtime::Value);
impl std::fmt::Display for DiscriminantOnly<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = format!("{:?}", self.0);
        let head: String = s.chars().take_while(|c| c.is_alphanumeric()).collect();
        write!(f, "{head}")
    }
}

/// Log a dispatch decision for `name` only when tracing is enabled for it.
/// The format arguments are evaluated lazily, so a disabled trace costs
/// nothing beyond the `enabled` check.
macro_rules! trace_resolve {
    ($name:expr, $($arg:tt)*) => {
        if $crate::vm::trace::enabled($name) {
            $crate::vm::trace::emit(format_args!($($arg)*));
        }
    };
}
pub(crate) use trace_resolve;
