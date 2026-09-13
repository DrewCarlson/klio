//! Static type checker: `parse -> resolve -> typecheck -> interp`, aborting
//! before the interpreter on failure. Produces a `Span -> Type` side table
//! plus a diagnostic sink.
//!
//! The pass is tolerant: a name the resolver leaves open, as it does most of
//! the stdlib, becomes `Type.Unresolved` and propagates silently, so a hard
//! diagnostic means the program is unambiguously wrong. Flow sensitivity comes
//! from the CFG, queried per program point.

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
