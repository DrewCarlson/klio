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
//!   uncertain shape as `Type.Unresolved` and silently propagates it.
//!   Hard diagnostics are reserved for cases where the program is
//!   unambiguously wrong.
//!
//! * Flow-insensitive with narrow smart-cast support. We thread a
//!   `Frame` of name -> narrowed type through conditional branches so
//!   `if (x != null) x.length` typechecks even when `x: String?`.
//!
//! * Pass placement. `parse -> resolve -> typecheck -> interp`. A
//!   typecheck failure aborts before interp.

const std = @import("std");

pub const check = @import("check.zig");

pub const TypeCheck = check.TypeCheck;
pub const typecheck = check.typecheck;
pub const typecheckModule = check.typecheckModule;
pub const Checker = check.Checker;
pub const codes = check.codes;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(check);
}
