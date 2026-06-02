//! Contract-effect catalogue consumed by the lowering. Spec §12.2.5
//! contracts describe a function's effect on the surrounding flow:
//! a precondition that holds on the post-call path, a lambda that
//! runs a specific number of times, or a smart-cast established by
//! a runtime check.
//!
//! Stdlib contracts live in [`stdlib_contract`] (hardcoded by simple
//! name). User contracts declared via
//! `kotlin.contracts.contract { … }` populate
//! [`USER_INLINE_CONTRACTS`] before lowering — the build pass walks
//! every `inline fun` body once for the contract block and records
//! each `callsInPlace(blockName, EXACTLY_ONCE)` it finds. The
//! lowering then treats a call to that user fn the same way it
//! treats a `let { … }` call: inline the trailing-lambda body into
//! the current block so VIA and smart-cast see the body's effects.

/// One effect a contract imposes on the call site's post-call state.
/// Multiple effects can apply to the same call (e.g. a function
/// that both narrows its first argument and propagates the second
/// argument's refinement).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContractEffect {
    /// `arg(arg_idx)` is non-null after this call returns normally.
    /// Modeled as an `AssumeNull(eq_null=false)` on the arg's reg.
    AssumeNonNull { arg_idx: usize },
    /// The condition expression at `arg(arg_idx)` holds after the
    /// call returns normally. Any `AssumeIs` / `AssumeNull` /
    /// `AssumeRefEq` refinement the lowering recorded for that
    /// register is replayed on the post-call block.
    AssumePredicate { arg_idx: usize },
}

thread_local! {
    /// User-declared `contract { callsInPlace(p, EXACTLY_ONCE) }`
    /// records, keyed by the inline fn's simple name. Each value
    /// lists the parameter names that are invoked exactly once on
    /// the normal path (Kotlin's `InvocationKind.EXACTLY_ONCE`).
    /// The lowering uses this to extend its trailing-lambda inline
    /// scheme to user contracts so a `val` assigned inside the
    /// lambda is observed as definitely assigned at the call site.
    static USER_INLINE_CONTRACTS: std::cell::RefCell<
        std::collections::HashMap<String, Vec<String>>,
    > = std::cell::RefCell::new(std::collections::HashMap::new());
}

/// Replace the user-contract registry. Called once per module
/// build, before any per-function lowering starts. Passing an
/// empty map effectively clears the registry between modules.
pub fn set_user_inline_contracts(
    map: std::collections::HashMap<String, Vec<String>>,
) {
    USER_INLINE_CONTRACTS.with(|c| *c.borrow_mut() = map);
}

/// Lookup the param names of the user inline fn `name` whose
/// contract declares `callsInPlace(p, EXACTLY_ONCE)`. Empty when no
/// user contract is registered for that name.
#[must_use] 
pub fn user_exactly_once_params(name: &str) -> Vec<String> {
    USER_INLINE_CONTRACTS.with(|c| c.borrow().get(name).cloned().unwrap_or_default())
}

/// Lookup table for stdlib functions that participate in contract
/// effects. The returned slice lists every effect to emit on the
/// post-call path.
#[must_use]
pub fn stdlib_contract(name: &str) -> &'static [ContractEffect] {
    use ContractEffect::{AssumeNonNull, AssumePredicate};
    // The slice values live in `static` storage so callers can hand
    // them to the lowering without lifetime gymnastics.
    static NONNULL: &[ContractEffect] = &[AssumeNonNull { arg_idx: 0 }];
    static REQUIRE: &[ContractEffect] = &[AssumePredicate { arg_idx: 0 }];
    match name {
        "requireNotNull" | "checkNotNull" => NONNULL,
        "require" | "check" => REQUIRE,
        _ => &[],
    }
}
