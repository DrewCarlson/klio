//! Thread-local registries for the inline-expansion machinery:
//! the `suspend inline fun` AST table and the inline-nesting depth
//! guard. Kept apart from the main lowering module because they are
//! pure state primitives — no `FuncBuilder` or IR-side dependency.

thread_local! {
    /// `suspend inline fun` ASTs by simple name, set by the build
    /// driver before body lowering. A `suspend inline` builder's
    /// `suspendCoroutineUninterceptedOrReturn` must capture the
    /// *caller's* continuation — only correct when the body is truly
    /// inlined. Non-suspend inline fns keep the normal call path and
    /// klio's frame-kind non-local-return mechanism, so the inline
    /// blast radius stays minimal.
    static INLINE_FN_ASTS: std::cell::RefCell<
        std::collections::HashMap<String, Vec<std::rc::Rc<klio_ast::Function>>>,
    > = std::cell::RefCell::new(std::collections::HashMap::new());

    /// Simple names that a default-imported host binding owns (e.g.
    /// `kotlin.synchronized`, `kotlin.arrayOf`). Any inline fn that
    /// happens to share a simple name with one of these — including
    /// pack-declared inline fns living in `kotlinx.coroutines.internal`
    /// — must NOT shadow Kotlin's default-import resolution at a bare
    /// call site. The lowerer skips inline expansion for these names
    /// so the call falls through to the normal call path, where FQN
    /// dispatch finds the `kotlin.<name>` binding. Set by the build
    /// driver, which has visibility into both the inline AST table
    /// and the host-binding registry.
    static SHADOWED_INLINE_NAMES: std::cell::RefCell<std::collections::HashSet<String>> =
        std::cell::RefCell::new(std::collections::HashSet::new());

    /// Hard ceiling on combined inline nesting (fn-body + lambda-arg
    /// splices) so transitive expansion cannot recurse without
    /// bound; past it, callers fall back to a normal call.
    static INLINE_EXPAND_DEPTH: std::cell::Cell<u32> = const {
        std::cell::Cell::new(0)
    };
}

/// Install the suspend-inline-fn AST table for the current build. Each
/// simple name maps to all its inline overloads (declaration order) so a
/// call site can disambiguate a function-param overload from a value-param
/// one by the trailing-arg shape.
pub fn set_inline_fn_asts<S: ::std::hash::BuildHasher>(
    m: std::collections::HashMap<String, Vec<std::rc::Rc<klio_ast::Function>>, S>,
) {
    INLINE_FN_ASTS.with(|c| *c.borrow_mut() = m.into_iter().collect());
}

/// Install the set of simple names owned by default-imported host
/// bindings. Inline expansion is skipped for these names so the call
/// site dispatches through the binding (matches Kotlin's default-import
/// precedence over a same-simple-name declaration in a non-default
/// package, e.g. `kotlinx.coroutines.internal.synchronized`).
pub fn set_shadowed_inline_names<S: ::std::hash::BuildHasher>(
    names: std::collections::HashSet<String, S>,
) {
    SHADOWED_INLINE_NAMES.with(|c| *c.borrow_mut() = names.into_iter().collect());
}

pub(super) fn inline_fn_ast(name: &str) -> Option<std::rc::Rc<klio_ast::Function>> {
    inline_fn_ast_for(name, None)
}

/// Resolve the inline overload of `name` for a call whose shape is
/// `call = (positional_arg_count, last_arg_is_lambda)`.
///
/// Deliberately conservative: returns the first-declared overload (the
/// historical single-table behavior) in every case *except* a
/// trailing-lambda call for which exactly one arity-fitting overload has a
/// function-typed last parameter — then that overload wins. This is the
/// minimal change that lets `get { … }` bind `get(block: …() -> Unit)`
/// rather than the first-declared `get(builder)` value form, without
/// re-resolving any non-lambda or single-overload call (so member inline
/// calls of a shared name on different receivers are untouched).
pub(super) fn inline_fn_ast_for(
    name: &str,
    call: Option<(usize, bool)>,
) -> Option<std::rc::Rc<klio_ast::Function>> {
    let shadowed = SHADOWED_INLINE_NAMES.with(|c| c.borrow().contains(name));
    if shadowed {
        return None;
    }
    INLINE_FN_ASTS.with(|c| {
        let map = c.borrow();
        let cands = map.get(name)?;
        let first = cands.first().cloned();
        let Some((want, true)) = call else {
            return first;
        };
        if cands.len() < 2 {
            return first;
        }
        // A trailing-lambda call `f(a, …) { lambda }` binds the lambda to
        // the overload's *last* parameter (which must be function-typed),
        // and the `want - 1` leading positional args must satisfy the
        // remaining leading parameters (with defaults/varargs filling the
        // rest). `get { }` (want = 1) thus fits `get(block)` but not
        // `get(urlString, block)` — the lambda can't supply `urlString`.
        let lead = want.saturating_sub(1);
        let fits_trailing_lambda = |f: &klio_ast::Function| {
            let n = f.params.len();
            if n == 0 {
                return false;
            }
            if f.params[n - 1].ty.function.is_none() {
                return false;
            }
            let leading = &f.params[..n - 1];
            let required = leading
                .iter()
                .filter(|p| p.default.is_none() && !p.is_vararg)
                .count();
            let last_lead_vararg = leading.last().is_some_and(|p| p.is_vararg);
            lead >= required && (lead <= leading.len() || last_lead_vararg)
        };
        let mut matches: Vec<&std::rc::Rc<klio_ast::Function>> =
            cands.iter().filter(|f| fits_trailing_lambda(f)).collect();
        if matches.len() == 1 {
            return matches.pop().cloned();
        }
        first
    })
}

const INLINE_EXPAND_MAX: u32 = 8;

pub(super) fn inline_expand_enter() -> bool {
    INLINE_EXPAND_DEPTH.with(|c| {
        let d = c.get();
        if d >= INLINE_EXPAND_MAX {
            false
        } else {
            c.set(d + 1);
            true
        }
    })
}

pub(super) fn inline_expand_leave() {
    INLINE_EXPAND_DEPTH.with(|c| c.set(c.get().saturating_sub(1)));
}
