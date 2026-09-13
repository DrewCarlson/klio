//! Static type checker: `parse -> resolve -> typecheck -> interp`, aborting
//! before the interpreter on failure. Produces a `TypeCheck` result carrying a
//! `Span -> Type` side table for every expression typed, plus a diagnostic
//! sink.
//!
//! The pass is tolerant. The resolver is permissive and a stdlib name such as
//! `listOf` resolves to nothing at this stage, so every uncertain shape
//! becomes `Type.Unresolved` and propagates silently; a hard diagnostic is
//! reserved for a program that is unambiguously wrong. Flow sensitivity comes
//! from the CFG: smart-cast, definite-assignment and reachability facts are
//! queried per program point, so `if (x != null) x.length` typechecks for
//! `x: String?`.

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
