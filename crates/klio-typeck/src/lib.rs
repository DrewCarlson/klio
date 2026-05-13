//! Static type checker.
//!
//! Runs after the resolver and before the interpreter. Produces a
//! `TypeCheck` result carrying a `Span -> Type` side table for every
//! expression we typed, plus a diagnostic sink.
//!
//! Design choices:
//!
//! * Tolerant. The resolver is permissive — many stdlib names like
//!   `listOf` resolve to "unresolved" at this stage because we have no
//!   global symbol table for the stdlib. The type checker treats every
//!   uncertain shape as `Type::Unresolved` and silently propagates it.
//!   Hard diagnostics are reserved for cases where the program is
//!   unambiguously wrong: explicit-annotation mismatches with concretely
//!   typed initializers, arity mismatches on user-defined callables,
//!   `val` reassignment, and obvious null-unsafe dereferences.
//!
//! * Flow-insensitive with narrow smart-cast support. We thread a
//!   `Frame` of name -> narrowed type through conditional branches so
//!   `if (x != null) x.length` typechecks even when `x: String?`.
//!
//! * Pass placement. `parse -> resolve -> typecheck -> interp`. A
//!   typecheck failure aborts before interp.

pub mod check;

pub use check::{typecheck, typecheck_module, TypeCheck};
