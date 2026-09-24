//! Lowering from sema: translates each body's records into IR over the
//! identities `core/bridge` allocated. Nothing here derives a type, picks
//! a callee or reads a name for execution; a missing record fails the body.
//!
//! Files and the package that owns each:
//! - `builder.zig` (C1): `Program`, `Builder`, blocks and registers.
//! - `records.zig` (C1): the record lookups, as `Builder` methods.
//! - `env.zig` (C1): receivers, locals, cells and captures.
//! - `body.zig` (C1): body entry, statements, the expression switch.
//! - `name.zig` (C1): reads and writes of locals, parameters, properties.
//! - `call.zig`, `dispatch.zig` (C2): argument runs and the call's `How`.
//! - `control.zig`, `operator.zig`, `types.zig` (C3): control flow,
//!   operators and the primitive table, type tests.
//! - `classes.zig`, `lambda.zig`, `refs.zig`, `lower.zig` (C4): class
//!   bodies, closures, callable references, the program driver.
//! - `inline.zig` (D): inline instantiation from IR.

pub const builder = @import("builder.zig");
pub const records = @import("records.zig");
pub const env = @import("env.zig");
pub const body = @import("body.zig");
pub const name = @import("name.zig");
pub const call = @import("call.zig");
pub const dispatch = @import("dispatch.zig");
pub const control = @import("control.zig");
pub const operator = @import("operator.zig");
pub const types = @import("types.zig");
pub const classes = @import("classes.zig");
pub const lambda = @import("lambda.zig");
pub const refs = @import("refs.zig");
pub const lower = @import("lower.zig");
pub const inline_ = @import("inline.zig");
pub const compose = @import("compose.zig");

pub const Error = records.Error;
pub const Program = builder.Program;
pub const Builder = builder.Builder;
pub const lowerProgram = lower.lowerProgram;
pub const lowerProgramOver = lower.lowerProgramOver;

test {
    const testing = @import("std").testing;
    testing.refAllDecls(builder);
    testing.refAllDecls(records);
    testing.refAllDecls(env);
    testing.refAllDecls(body);
    testing.refAllDecls(name);
    testing.refAllDecls(call);
    testing.refAllDecls(dispatch);
    testing.refAllDecls(control);
    testing.refAllDecls(operator);
    testing.refAllDecls(types);
    testing.refAllDecls(classes);
    testing.refAllDecls(lambda);
    testing.refAllDecls(refs);
    testing.refAllDecls(lower);
    testing.refAllDecls(inline_);
    testing.refAllDecls(compose);
}
