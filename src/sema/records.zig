//! What the analysis decided at each reference: the declaration it names
//! and where each receiver comes from. Lowering translates these; the
//! oracle dump prints them.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");

const symbols = @import("symbols.zig");
const types = @import("types.zig");
const names_mod = @import("names.zig");

const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Name = names_mod.Name;

/// Where an implicit receiver comes from.
pub const ImplicitKind = enum(u8) {
    /// `this` of a class (the owner is the class; an outer class's `this`
    /// is reached the same way).
    class_this,
    /// The extension receiver of an enclosing extension function or
    /// property (the owner is that function or property).
    extension,
    /// The receiver of a lambda with receiver (the owner is the lambda's
    /// function symbol).
    lambda,
    /// A context parameter (the owner is the parameter symbol).
    context,
    /// An object or companion object whose members are in static scope
    /// (the owner is the object class).
    object,
    /// `super`: the enclosing class's instance (the owner), dispatched
    /// non-virtually to the supertype's declaration.
    super_,
};

pub const Receiver = union(enum) {
    none,
    /// The call's own receiver expression.
    expr,
    implicit: struct { kind: ImplicitKind, owner: Sym },
};

pub const RefKind = enum(u8) {
    /// A named function call.
    call,
    /// A property, local or parameter read.
    read,
    /// An assignment target.
    write,
    ctor,
    get,
    set,
    invoke,
    iterator,
    has_next,
    next,
    component,
    get_value,
    set_value,
    provide_delegate,
    /// A binary or unary operator convention (`plus`, `unaryMinus`, ...),
    /// named by `op`.
    op,
    compare_to,
    equals,
    contains,
    range_to,
    range_until,
    inc,
    dec,
    /// `a op= b` resolved to `opAssign`.
    op_assign,
    /// A callable reference.
    ref,
    /// A classifier used as a value: an object, a companion, an enum entry.
    object,
    /// `this` / `this@L` (dispatch: which implicit receiver).
    this_,
    /// `return` / `return@L` (target: the function or lambda it leaves).
    return_,
    /// A declaration in a body (target: the local property, function, class
    /// or object, an object expression's class, a lambda's function).
    decl,
    /// `is`, `as`, a catch parameter, a class literal (detail: the test).
    type_test,
    /// `C::class` (target: the class or type parameter) or `x::class`
    /// (dispatch `expr`, target the static class when there is one).
    class_literal,
};

/// The type an expression has once its resolution is committed, before
/// the variables it may still mention are solved.
pub const ExprType = struct {
    file: u32,
    node: ast.NodeId,
    sp: span.Span,
    ty: TypeId,
    needs_record: bool = false,
    /// An integer literal's type as the variable its parameter holds: it
    /// applies once that variable is fixed to an integral type, and the
    /// literal keeps its own type otherwise.
    if_integral: bool = false,
};

// ------------------------------------------------------ typed records ----
//
// What lowering reads, per node. A record carries one of these as its
// `detail` where its kind needs more than a target and receivers;
// `output` builds the rest (names, receivers, groups) from the records by
// kind. See docs/design/LOWER-SEMA-PACKAGES.md section 1.

pub const NodeId = ast.NodeId;

pub const CallForm = enum(u8) {
    /// A function, accessor or operator: static, virtual or interface is
    /// lowering's choice from the callee's declaration.
    plain,
    /// Through `super`, `super<T>` or `super@L`: the callee is the
    /// declaration that runs, called non-virtually on the enclosing
    /// instance.
    super_,
    /// `invoke` of a value; the callee node is the value.
    value_invoke,
    /// A constructor making a new instance.
    ctor,
    /// `this(...)` from a secondary constructor, on the same instance.
    this_delegation,
    /// `super(...)` from a secondary constructor, a supertype initializer
    /// `: Base(...)`, or an enum entry's arguments, on the same instance.
    super_delegation,
    /// `Iface { ... }`: a fun interface's synthetic SAM constructor.
    sam_ctor,
};

pub const CallRec = struct {
    callee: Sym,
    form: CallForm,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    /// One entry per parameter the operands map to, in declaration order:
    /// the callee's value parameters after the leading contexts an `invoke`
    /// of a contextual function type takes from the scope.
    args: []const ArgSource = &.{},
    /// Where each context argument comes from: the leading contexts of a
    /// contextual `invoke`, then the callee's own context parameters.
    contexts: []const Receiver = &.{},
    /// The callee's type parameters, solved: a constructor's class's (also
    /// when called through a type alias), a function's own.
    type_args: []const TypeId = &.{},
    /// Parallel to `args`.
    conv: []const Conv = &.{},
    /// The call passes the composer: its callee is `@Composable`, or it is
    /// `invoke` on a value of a composable function type.
    composable: bool = false,
    /// A `when` pattern's `equals`: the subject's type where the pattern
    /// tests it, the earlier branches' smart casts applied.
    subject_ty: TypeId = .none,
};

/// Where one parameter's value comes from.
pub const ArgSource = union(enum) {
    /// The construct's operand at this index (the call's arguments in
    /// source order; `[rhs]` for a binary operator; see the design's 1.4).
    arg: u16,
    /// Omitted; the callee's defaults supply it.
    default,
    /// A vararg parameter's elements in source order; empty when none.
    vararg: []const VarargPart,
    /// The call's extension receiver fills this parameter: `invoke` of an
    /// extension function type called as `recv.f()`.
    receiver,
};

/// One element of a vararg: the operand, whether it is spread, and the
/// conversion that element goes through (each element of a
/// `vararg r: Runnable` may be SAM converted on its own).
pub const VarargPart = struct { arg: u16, spread: bool, conv: Conv = .none };

pub const Conv = union(enum) {
    none,
    /// A function value passed for a fun interface parameter, wrapped in
    /// the interface.
    sam: Sym,
    /// A non-suspend function value passed for a suspend function type.
    suspend_,
};

pub const NameKind = enum(u8) {
    /// A local: `val`/`var`, loop variable, catch binding, destructuring
    /// entry, lambda parameter, `it`.
    local,
    /// A value parameter or a named context parameter.
    param,
    /// A member, top-level, extension or static property.
    property,
    /// `field` in an accessor: the storage of the property `target`.
    backing_field,
    /// An object or companion, or a classifier used as a value.
    object,
    enum_entry,
};

pub const NameRec = struct {
    kind: NameKind,
    write: bool = false,
    target: Sym,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    contexts: []const Receiver = &.{},
};

/// `this` / `this@L`: which implicit receiver.
pub const RecvRec = struct { kind: ImplicitKind, owner: Sym };

pub const TypeTestKind = enum(u8) { is_, not_is, as_, as_safe, catch_, class_literal, class_of };

pub const TypeTestRec = struct {
    kind: TypeTestKind,
    /// The written type resolved; for `class_of` the operand's static type.
    ty: TypeId,
    /// The erased class; `.none` when `ty` is a type parameter, tested
    /// through its reified value.
    class: Sym,
    /// `is T?` and `as T?` admit null.
    nullable: bool,
    /// `catch_`: the parameter's local.
    binding: Sym = .none,
};

pub const RefRec = struct {
    /// A function, a constructor (`::Cls`), or a property.
    target: Sym,
    /// `.expr` for `x::f`; `.implicit` for a member or extension bound to
    /// an implicit receiver; `.none` for an unbound reference.
    bound: Receiver = .none,
    /// The extension receiver a bare reference binds.
    extension: Receiver = .none,
    /// The function type or `KProperty` type the reference has.
    ty: TypeId,
    /// A function target's own type arguments, as the expected type fixed
    /// them; empty without one.
    type_args: []const TypeId = &.{},
    adapt: RefAdapt = .{},
};

pub const RefAdapt = packed struct(u32) {
    /// Trailing parameters left to their defaults.
    defaults: u16 = 0,
    /// Vararg elements passed one by one.
    vararg_elems: bool = false,
    /// The expected type returns `Unit` and the target does not.
    drop_result: bool = false,
    /// Converted to a suspend function type.
    suspend_: bool = false,
    _pad: u13 = 0,
};

pub const LambdaRec = struct {
    /// The committed resolution's function symbol.
    func: Sym,
    /// The function type the literal has, after SAM unwrapping.
    fn_type: TypeId,
    /// The fun interface a SAM conversion wraps it in, else `.none`.
    sam: Sym = .none,
    /// Per written parameter; `.none` for `_` and for a destructured one.
    params: []const Sym = &.{},
    it: Sym = .none,
    /// The locals standing for a contextual function type's contexts.
    contexts: []const Sym = &.{},
    has_receiver: bool = false,
    suspend_: bool = false,
};

/// The typed part of a record, where its kind has one.
pub const Detail = union(enum) {
    none,
    call: *const CallRec,
    type_test: *const TypeTestRec,
    lambda: *const LambdaRec,
    ref: *const RefRec,
};

pub const Ref = struct {
    file: u32,
    /// The node whose resolution made the record: the expression, or the
    /// statement or declaration (an assignment, a destructuring, a
    /// delegated property, a supertype call) that holds the construct.
    /// Several records can share a node; `anchor` tells them apart.
    node: ast.NodeId = .none,
    anchor: span.Span,
    kind: RefKind,
    /// The convention name for `op`, `op_assign` and `component` (as
    /// `componentN`); `.empty` otherwise.
    op: Name = .empty,
    target: Sym,
    dispatch: Receiver = .none,
    extension: Receiver = .none,
    /// The implicit value each context parameter of the callee takes, in
    /// declaration order.
    contexts: []const Receiver = &.{},
    detail: Detail = .none,
};
