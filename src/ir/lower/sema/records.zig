//! The records a body's nodes hold, as `Builder` methods over
//! `sema.output`: `b.call(id)`, `b.name(id)`, `b.typeTest(id)`, ... A node
//! without the record its construct needs is `error.Unrecorded`: the
//! builder keeps which one missed, the body fails naming it, and nothing
//! falls back.

const ast = @import("ast");
const sema = @import("sema");

const builder = @import("builder.zig");

const Builder = builder.Builder;
const NodeId = ast.NodeId;
const Sym = sema.Sym;
const TypeId = sema.TypeId;
const output = sema.output;
const rec = sema.records;

pub const Error = error{ OutOfMemory, Unrecorded, Unsupported };

pub const CallRec = rec.CallRec;
pub const NameRec = rec.NameRec;
pub const RecvRec = rec.RecvRec;
pub const TypeTestRec = rec.TypeTestRec;
pub const RefRec = rec.RefRec;
pub const LambdaRec = rec.LambdaRec;
pub const RefKind = rec.RefKind;
pub const ForGroup = output.ForGroup;
pub const Compound = output.Compound;
pub const DestructEntry = output.DestructEntry;
pub const Delegate = output.Delegate;
/// A `when` pattern's test: `equals`, `contains` or a type test.
pub const WhenPattern = output.WhenPattern;

/// Keeps which record `id` lacked, for the error its body reports.
fn missed(b: *Builder, id: NodeId, what: []const u8, e: output.Error) Error {
    if (e == error.Unrecorded) b.miss = .{ .node = id, .what = what };
    return e;
}

/// The node's call: a call, constructor, invoke, index access or operator.
pub fn call(b: *Builder, id: NodeId) Error!CallRec {
    return output.call(b.p.s, b.recs, id) catch |e| missed(b, id, "call", e);
}

/// The node's call of `kind`: a group's part (`iterator`, `get_value`, ...).
pub fn callOf(b: *Builder, id: NodeId, kind: RefKind) Error!CallRec {
    return output.callOf(b.p.s, b.recs, id, kind) catch |e| missed(b, id, @tagName(kind), e);
}

/// The node's read or write of a local, parameter or property, or an
/// object or enum entry used as a value.
pub fn name(b: *Builder, id: NodeId) Error!NameRec {
    return output.name(b.p.s, b.recs, id) catch |e| missed(b, id, "name", e);
}

/// Every name the node holds, in order: a dotted path's value segments.
pub fn names(b: *Builder, id: NodeId) Error![]const NameRec {
    return output.names(b.p.s, b.recs, id) catch |e| missed(b, id, "name", e);
}

/// The name record the node holds for the name at offset `anchor`: a path
/// segment, a member, an assignment's target. Null for a package or
/// classifier qualifier; a caller that needs one reports `nameMissed`.
pub fn nameAt(b: *Builder, id: NodeId, anchor: u32) ?NameRec {
    return output.nameAt(b.p.s, b.recs, id, anchor);
}

/// `error.Unrecorded` for a name `nameAt` did not find.
pub fn nameMissed(b: *Builder, id: NodeId) Error {
    return missed(b, id, "name", error.Unrecorded);
}

/// `this` / `this@L`.
pub fn recv(b: *Builder, id: NodeId) Error!RecvRec {
    return output.recv(b.recs, id) catch |e| missed(b, id, "receiver", e);
}

/// `is`, `as`, a catch parameter, a class literal.
pub fn typeTest(b: *Builder, id: NodeId) Error!TypeTestRec {
    return output.typeTest(b.recs, id) catch |e| missed(b, id, "type test", e);
}

/// Every type test of the node in order.
pub fn typeTests(b: *Builder, id: NodeId) Error![]const TypeTestRec {
    return output.typeTests(b.p.s, b.recs, id) catch |e| missed(b, id, "type test", e);
}

/// A callable reference.
pub fn ref(b: *Builder, id: NodeId) Error!RefRec {
    return output.ref(b.recs, id) catch |e| missed(b, id, "reference", e);
}

/// A lambda or anonymous function.
pub fn lambda(b: *Builder, id: NodeId) Error!LambdaRec {
    return output.lambda(b.recs, id) catch |e| missed(b, id, "lambda", e);
}

/// The function or lambda a `return` leaves.
pub fn returnTarget(b: *Builder, id: NodeId) Error!Sym {
    return output.returnTarget(b.recs, id) catch |e| missed(b, id, "return target", e);
}

/// The symbol a declaration node declares.
pub fn decl(b: *Builder, id: NodeId) Error!Sym {
    return output.decl(b.recs, id) catch |e| missed(b, id, "declaration", e);
}

/// The expression's type, variables solved; `.none` for a node that is not
/// a resolved expression.
pub fn exprType(b: *Builder, id: NodeId) TypeId {
    return output.exprType(b.recs, id);
}

/// `for`'s `iterator`, `hasNext` and `next`.
pub fn forGroup(b: *Builder, id: NodeId) Error!ForGroup {
    return output.forGroup(b.p.s, b.recs, id) catch |e| missed(b, id, "for", e);
}

/// A compound assignment's or increment's records.
pub fn compound(b: *Builder, id: NodeId) Error!Compound {
    return output.compound(b.p.s, b.recs, id) catch |e| missed(b, id, "compound assignment", e);
}

/// A destructuring's entry written at offset `entry`; null for `_`.
pub fn destructureEntry(b: *Builder, id: NodeId, entry: u32) Error!?DestructEntry {
    return output.destructureEntry(b.p.s, b.recs, id, entry) catch |e| missed(b, id, "destructuring", e);
}

/// The test of the `when` pattern at offset `pattern`.
pub fn whenPattern(b: *Builder, when_id: NodeId, pattern: u32) Error!WhenPattern {
    return output.whenPattern(b.p.s, b.recs, when_id, pattern) catch |e| missed(b, when_id, "when pattern", e);
}

/// A delegated property's `provideDelegate`, `getValue` and `setValue`.
pub fn delegate(b: *Builder, id: NodeId) Error!Delegate {
    return output.delegate(b.p.s, b.recs, id) catch |e| missed(b, id, "delegate", e);
}

/// A class's supertype initializers, in the order written.
pub fn supers(b: *Builder, id: NodeId) Error![]const CallRec {
    return output.supers(b.p.s, b.recs, id) catch |e| missed(b, id, "supertype call", e);
}
