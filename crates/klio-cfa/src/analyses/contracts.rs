//! Contract-effect catalogue consumed by the lowering. Spec §12.2.5
//! contracts describe a function's effect on the surrounding flow:
//! a precondition that holds on the post-call path, a lambda that
//! runs a specific number of times, or a smart-cast established by
//! a runtime check.
//!
//! For now we hardcode the stdlib contracts. User contracts declared
//! via `kotlin.contracts.contract { ... }` extend the same table
//! when the typechecker parses them — landing in a follow-up.

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

/// Lookup table for stdlib functions that participate in contract
/// effects. The returned slice lists every effect to emit on the
/// post-call path.
#[must_use]
pub fn stdlib_contract(name: &str) -> &'static [ContractEffect] {
    use ContractEffect::*;
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
