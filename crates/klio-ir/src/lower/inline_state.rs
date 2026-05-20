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
        std::collections::HashMap<String, std::rc::Rc<klio_ast::Function>>,
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

/// Install the suspend-inline-fn AST table for the current build.
pub fn set_inline_fn_asts(
    m: std::collections::HashMap<String, std::rc::Rc<klio_ast::Function>>,
) {
    INLINE_FN_ASTS.with(|c| *c.borrow_mut() = m);
}

/// Install the set of simple names owned by default-imported host
/// bindings. Inline expansion is skipped for these names so the call
/// site dispatches through the binding (matches Kotlin's default-import
/// precedence over a same-simple-name declaration in a non-default
/// package, e.g. `kotlinx.coroutines.internal.synchronized`).
pub fn set_shadowed_inline_names(names: std::collections::HashSet<String>) {
    SHADOWED_INLINE_NAMES.with(|c| *c.borrow_mut() = names);
}

pub(super) fn inline_fn_ast(name: &str) -> Option<std::rc::Rc<klio_ast::Function>> {
    let shadowed = SHADOWED_INLINE_NAMES.with(|c| c.borrow().contains(name));
    if shadowed {
        return None;
    }
    INLINE_FN_ASTS.with(|c| c.borrow().get(name).cloned())
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
