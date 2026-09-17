//! Kotlin AST.
const std = @import("std");
const span = @import("span");

pub const Span = span.Span;

pub const Ident = struct {
    name: []const u8,
    span: Span,
};

/// The value behind an optional boxed node, for a reader that wants the
/// optional by value.
pub fn unbox(p: anytype) ?@TypeOf(p.?.*) {
    return if (p) |x| x.* else null;
}

/// Boxes `value` for a pointer payload.
pub fn box(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!*@TypeOf(value) {
    const p = try allocator.create(@TypeOf(value));
    p.* = value;
    return p;
}

pub const Visibility = enum {
    Public,
    Private,
    Protected,
    Internal,

    pub const default: Visibility = .Public;
};

/// Use-site target of an annotation; `None` is a plain `@Foo` with no target.
pub const AnnotationUseSite = enum {
    Field,
    Property,
    Get,
    Set,
    Receiver,
    Param,
    SetParam,
    Delegate,
    File,
    /// Expands over every applicable anchor; see `annotation_targets.expandAll`.
    All,
};

pub const annotation_targets = @import("annotation_targets.zig");
pub const alias_expand = @import("alias_expand.zig");

pub const Annotation = struct {
    use_site: ?AnnotationUseSite,
    path: []Ident,
    type_args: []TypeRef,
    args: []Expr,
    arg_names: []?[]const u8,
    span: Span,
};

/// Whether an accessor body reads or writes the backing `field`; an uncovered
/// shape answers false.
pub fn accessorUsesField(a: *const Accessor) bool {
    return switch (a.body) {
        .Block => |b| blockUsesField(&b),
        .Expr => |e| exprUsesField(&e),
    };
}

pub fn blockUsesField(b: *const Block) bool {
    for (b.stmts) |s| {
        const hit = switch (s) {
            .Expr => |*e| exprUsesField(e),
            .Assign => |a| exprUsesField(&a.target) or exprUsesField(&a.value),
            .Decl => |d| switch (d.*) {
                .Property => |p| if (p.init) |i| exprUsesField(i) else false,
                else => false,
            },
            else => false,
        };
        if (hit) return true;
    }
    return false;
}

pub fn exprUsesField(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field"),
        .Block => |b| blockUsesField(&b),
        .If => |i| exprUsesField(i.cond) or exprUsesField(i.then_branch) or
            (if (i.else_branch) |eb| exprUsesField(eb) else false),
        .When => |w| (if (w.subject) |s| exprUsesField(s) else false) or blk: {
            for (w.branches) |*b| {
                if (exprUsesField(&b.body)) break :blk true;
            }
            break :blk false;
        },
        .Call => |c| exprUsesField(c.callee) or blk: {
            for (c.args) |*a| if (exprUsesField(a)) break :blk true;
            break :blk false;
        },
        .Index => |x| blk: {
            if (exprUsesField(x.receiver)) break :blk true;
            for (x.args) |*a| if (exprUsesField(a)) break :blk true;
            break :blk false;
        },
        .Binary => |b| exprUsesField(b.lhs) or exprUsesField(b.rhs),
        .Return => |r| if (r.value) |v| exprUsesField(v) else false,
        .Member => |m| exprUsesField(m.receiver),
        .Unary => |x| exprUsesField(x.expr),
        .Postfix => |x| exprUsesField(x.expr),
        .As => |x| exprUsesField(x.expr),
        .IsCheck => |x| exprUsesField(x.expr),
        .Spread => |x| exprUsesField(x.expr),
        .Labeled => |x| exprUsesField(x.expr),
        else => false,
    };
}

pub const KotlinFile = struct {
    package: ?PackageHeader,
    imports: []ImportDecl,
    decls: []Decl,
    span: Span,
    file_annotations: []Annotation = &.{},
    /// The parser saw a `@Composable` annotation somewhere in the file, so the
    /// compose pass has something to do.
    has_composable: bool = false,
};

fn rewriteAliasedTypeName(ty: *TypeRef, aliases: *const std.StringHashMap([]const u8)) void {
    if (ty.function != null) return;
    if (aliases.get(ty.name.name)) |target| ty.name.name = target;
}

fn expandAliasesInDecls(decls: []Decl, aliases: *const std.StringHashMap([]const u8)) void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                for (f.params) |*p| rewriteAliasedTypeName(&p.ty, aliases);
                if (f.receiver_type) |rt| rewriteAliasedTypeName(rt, aliases);
                if (f.return_type) |rt| rewriteAliasedTypeName(rt, aliases);
            },
            .Class => |*c| {
                for (c.primary_params) |*p| rewriteAliasedTypeName(&p.ty, aliases);
                expandAliasesInDecls(c.members, aliases);
            },
            .Object => |*o| expandAliasesInDecls(o.members, aliases),
            else => {},
        }
    }
}

/// Replace this file's class typealiases with their target class in function
/// signatures and constructor parameters, in place. A typealias is file-scoped,
/// so resolving it any later lets the flat global name table capture the
/// parameter with a same-named class from another module.
pub fn expandFileClassAliases(allocator: std.mem.Allocator, file: *KotlinFile) void {
    var aliases = std.StringHashMap([]const u8).init(allocator);
    defer aliases.deinit();
    for (file.decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function != null) continue;
        if (ta.target.name.name.len == 0) continue;
        if (std.mem.eql(u8, ta.target.name.name, ta.name.name)) continue;
        aliases.put(ta.name.name, ta.target.name.name) catch return;
    }
    if (aliases.count() == 0) return;
    expandAliasesInDecls(file.decls, &aliases);
}

pub const PackageHeader = struct {
    path: []Ident,
    span: Span,
};

pub const ImportDecl = struct {
    path: []Ident,
    alias: ?Ident,
    wildcard: bool,
    span: Span,
};

/// One entry of a `context(name: Type, ...)` clause; `"_"` is anonymous.
pub const ContextParam = struct {
    name: Ident,
    ty: TypeRef,
    span: Span,
};

pub const Decl = union(enum) {
    Function: Function,
    /// Boxed: the largest `Decl` variant, and the stable pointee keeps interior pointers valid.
    Property: *Property,
    Class: Class,
    Object: ObjectDecl,
    TypeAlias: TypeAlias,
};

pub const TypeAlias = struct {
    name: Ident,
    type_params: []TypeParam,
    target: TypeRef,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const Function = struct {
    name: Ident,
    /// Boxed: a type reference is a hundred bytes and most functions have no
    /// receiver, so the absent case costs a pointer.
    receiver_type: ?*TypeRef,
    context_params: []ContextParam = &.{},
    type_params: []TypeParam,
    where_bounds: []WhereBound,
    params: []Param,
    /// Boxed, like `receiver_type`.
    return_type: ?*TypeRef,
    body: ?FunctionBody,
    is_open: bool,
    is_override: bool,
    is_final: bool = false,
    is_abstract: bool,
    is_operator: bool,
    is_inline: bool,
    is_infix: bool,
    is_tailrec: bool,
    is_suspend: bool,
    /// Bodyless: lowering is skipped, dispatch goes through the `actual`.
    is_expect: bool,
    is_actual: bool,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const Variance = enum {
    Invariant,
    Out,
    In,

    pub const default: Variance = .Invariant;
};

pub const TypeParam = struct {
    name: Ident,
    variance: Variance,
    upper_bound: ?TypeRef,
    is_reified: bool,
    annotations: []Annotation,
    span: Span,
};

pub const WhereBound = struct {
    name: Ident,
    bound: TypeRef,
    span: Span,
};

pub const TypeArg = struct {
    variance: Variance,
    /// `*` star-projection; `ty` is unused when set.
    is_star: bool,
    ty: TypeRef,
    span: Span,
};

pub const FunctionBody = union(enum) {
    Block: Block,
    Expr: Expr,
};

pub const Param = struct {
    name: Ident,
    ty: TypeRef,
    /// Boxed so an absent default costs a pointer, not an inline `Expr`.
    default: ?*Expr,
    is_vararg: bool,
    is_crossinline: bool,
    is_noinline: bool,
    annotations: []Annotation,
    span: Span,
};

pub const Property = struct {
    mutable: bool,
    name: Ident,
    context_params: []ContextParam = &.{},
    /// Boxed, as are `ty` and `init`: each is absent on most properties.
    receiver_type: ?*TypeRef,
    ty: ?*TypeRef,
    init: ?*Expr,
    /// `init` is `None` when set. Boxed.
    delegate: ?*Expr,
    /// Boxed; the shared-graph codec resolves `PropertyDef.getter` to this node.
    getter: ?*Accessor,
    /// Boxed; the parameter is named `value` when the source omits a name.
    setter: ?*Accessor,
    is_abstract: bool,
    is_open: bool,
    is_override: bool,
    is_lateinit: bool,
    is_const: bool,
    is_inline: bool,
    is_expect: bool,
    is_actual: bool,
    /// From a bodyless `private set`; `None` inherits the property's visibility.
    setter_visibility: ?Visibility,
    /// Reads inside the declaring scope see the field type, outside the property
    /// type. Boxed.
    explicit_field: ?*ExplicitField = null,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

/// Member and top-level `val` properties only.
pub const ExplicitField = struct {
    ty: ?*TypeRef,
    /// When absent the field must be definitely assigned on every construction path.
    init: ?*Expr,
    /// Span of the `field` keyword token.
    span: Span,
};

pub const Accessor = struct {
    params: []Ident,
    return_type: ?*TypeRef,
    body: FunctionBody,
    visibility: ?Visibility,
    /// This accessor alone is inlined; `Property.is_inline` inlines both.
    is_inline: bool,
    annotations: []Annotation,
    span: Span,
};

/// What a class rarely carries: where bounds, init blocks, named
/// supertype arguments, secondary constructors and enum entries. Out of
/// line so a class is 184 bytes rather than 272; the stdlib holds three
/// thousand and one in eight fills the box.
pub const ClassExtra = struct {
    where_bounds: []WhereBound = &.{},
    /// Interleaved with body-property initializers per `init_block_positions`.
    init_blocks: []Block = &.{},
    /// Index into `members` per entry: position `N` runs before `members[N]`'s
    /// initializer. Same length as `init_blocks`.
    init_block_positions: []usize = &.{},
    /// Parallel to `supertype_args`: each argument's label, `null` when
    /// positional; empty means all positional.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    secondary_ctors: []SecondaryCtor = &.{},
    /// Entries of an enum class; its post-`;` declarations are `members`.
    enum_entries: []EnumEntry = &.{},

    pub fn isDefault(self: *const ClassExtra) bool {
        return self.where_bounds.len == 0 and self.init_blocks.len == 0 and
            self.init_block_positions.len == 0 and self.supertype_arg_names.len == 0 and
            self.secondary_ctors.len == 0 and self.enum_entries.len == 0;
    }
};

pub const no_class_extra: ClassExtra = .{};

pub const Class = struct {
    name: Ident,
    type_params: []TypeParam,
    primary_params: []ClassParam,
    /// False for `class A { constructor(...) }`, which gains no implicit
    /// zero-argument constructor.
    has_primary_ctor: bool = true,
    supertypes: []TypeRef,
    /// Per supertype, the `: Bar(a, b)` arguments. `None` is no `(...)` at all,
    /// an empty list the explicit `: Bar()`.
    supertype_args: []?[]Expr,
    supertype_delegates: []?Expr,
    is_data: bool,
    is_companion: bool,
    is_enum: bool,
    is_sealed: bool,
    is_open: bool,
    is_abstract: bool,
    is_inner: bool,
    is_interface: bool,
    is_fun_interface: bool,
    is_value: bool,
    is_annotation: bool,
    is_expect: bool,
    /// Matched to an `expect class` by simple name.
    is_actual: bool,
    members: []Decl,
    visibility: Visibility,
    /// From `class Foo private constructor(...)`; `None` inherits the class visibility.
    primary_ctor_visibility: ?Visibility,
    annotations: []Annotation,
    span: Span,
    /// Null when every rare field is empty; read through `x()`, written
    /// through `xMut()`.
    extra: ?*const ClassExtra = null,

    pub inline fn x(self: *const Class) *const ClassExtra {
        return self.extra orelse &no_class_extra;
    }

    /// The box to write, allocated on first use.
    pub fn xMut(self: *Class, allocator: std.mem.Allocator) std.mem.Allocator.Error!*ClassExtra {
        if (self.extra) |e| return @constCast(e);
        const e = try allocator.create(ClassExtra);
        e.* = .{};
        self.extra = e;
        return e;
    }
};

/// A boxed `ClassExtra`, or null when every field is at its default.
pub fn classExtra(allocator: std.mem.Allocator, e: ClassExtra) std.mem.Allocator.Error!?*const ClassExtra {
    if (e.isDefault()) return null;
    const p = try allocator.create(ClassExtra);
    p.* = e;
    return p;
}

pub const EnumEntry = struct {
    name: Ident,
    args: []Expr,
    /// Per argument, the parameter a named argument binds; `null` when positional.
    arg_names: []const ?[]const u8 = &.{},
    body_members: []Decl,
    annotations: []Annotation,
    span: Span,
};

pub const ClassParam = struct {
    /// `None` when not a property, `Some(true)` for `var`, `Some(false)` for `val`.
    property: ?bool,
    name: Ident,
    ty: TypeRef,
    default: ?Expr,
    visibility: Visibility,
    is_vararg: bool,
    annotations: []Annotation,
    span: Span,
};

pub const SecondaryCtor = struct {
    params: []Param,
    delegation: CtorDelegation,
    /// Per argument, the parameter a named argument binds; `null` when positional.
    delegation_arg_names: []const ?[]const u8 = &.{},
    body: ?Block,
    visibility: Visibility,
    annotations: []Annotation,
    span: Span,
};

pub const CtorDelegation = union(enum) {
    This: []Expr,
    Super: []Expr,
    /// Implicit `: this()` when a primary constructor exists, else `: super()`.
    None,
};

pub const ObjectDecl = struct {
    name: Ident,
    supertypes: []TypeRef,
    members: []Decl,
    init_blocks: []Block,
    init_block_positions: []usize,
    /// Per supertype, the `(args)`; `None` when none was written.
    supertype_args: []?[]Expr,
    /// Parallel to `supertype_args`: labels, `null` when positional.
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    /// Parallel to `supertypes`: the `by` delegate, `null` for a plain supertype.
    supertype_delegates: []?Expr = &.{},
    annotations: []Annotation = &.{},
    is_data: bool,
    is_expect: bool,
    is_actual: bool,
    visibility: Visibility,
    span: Span,
};

/// What a type reference rarely carries: its annotations and, for a
/// qualified spelling, the path. Out of line so a type reference is 72
/// bytes rather than 104; parameters, type arguments and supertypes each
/// hold one inline.
pub const TypeRefExtra = struct {
    annotations: []Annotation = &.{},
    /// `name` keeps only the last segment, so this distinguishes `Outer.Inner`
    /// from a same-named top-level class.
    qualified_path: ?[]const u8 = null,

    pub fn isDefault(self: *const TypeRefExtra) bool {
        return self.annotations.len == 0 and self.qualified_path == null;
    }
};

pub const no_type_ref_extra: TypeRefExtra = .{};

pub const TypeRef = struct {
    name: Ident,
    nullable: bool,
    span: Span,
    type_args: []TypeArg,
    /// Set for a function type, whose `name.name` then carries the synthetic tag
    /// `"<function>"` so name-based consumers treat it as unresolved; `nullable`
    /// covers the function type itself (`((Int) -> Int)?`).
    function: ?*FunctionTypeRef,
    /// Typeck rejects it on a non-type-parameter receiver; interp treats it as the base `T`.
    definitely_non_null: bool,
    /// Null when the reference carries no annotation and no qualified path;
    /// read through `x()`.
    extra: ?*const TypeRefExtra = null,

    pub inline fn x(self: *const TypeRef) *const TypeRefExtra {
        return self.extra orelse &no_type_ref_extra;
    }
};

/// A boxed `TypeRefExtra`, or null when both fields are at their defaults.
pub fn typeRefExtra(allocator: std.mem.Allocator, e: TypeRefExtra) std.mem.Allocator.Error!?*const TypeRefExtra {
    if (e.isDefault()) return null;
    const p = try allocator.create(TypeRefExtra);
    p.* = e;
    return p;
}

pub const FunctionTypeRef = struct {
    receiver: ?TypeRef,
    params: []TypeRef,
    ret: TypeRef,
    is_suspend: bool,
    /// Leading `context(A, B)` block, equivalent to the flattened function type.
    /// Named entries are rejected by the parser.
    context_params: []TypeRef = &.{},
    span: Span,
};

pub const Block = struct {
    stmts: []Stmt,
    span: Span,
};

/// `Stmt` payloads are boxed for the same reason as the expression's: a
/// declaration is hundreds of bytes and an assignment carries two
/// expressions, while most statements are one expression.
pub const AssignStmt = struct {
    target: Expr,
    op: AssignOp,
    value: Expr,
    span: Span,
};

/// Each name receives `expr.componentN()`; `_` evaluates its component for
/// effect without binding.
pub const DestructuringDeclStmt = struct {
    mutable: bool,
    names: []Ident,
    /// Name-based `(val a, val n = prop) = x` reads the property each name gives;
    /// positional forms read `componentN`.
    by_name: bool = false,
    sources: []Ident = &.{},
    init: Expr,
    span: Span,
};

pub const Stmt = union(enum) {
    Expr: Expr,
    Decl: *Decl,
    Assign: *AssignStmt,
    DestructuringDecl: *DestructuringDeclStmt,
};

pub const AssignOp = enum {
    Assign,
    Add,
    Sub,
    Mul,
    Div,
    Rem,
};

pub const IntLitKind = enum {
    Int,
    Long,
    UInt,
    ULong,

    pub const default: IntLitKind = .Int;
};

pub const FloatLitKind = enum {
    Double,
    Float,

    pub const default: FloatLitKind = .Double;
};

/// The `Expr` variants below are boxed: each is far larger than a call or a
/// path, and an inline payload would size every expression by the largest.
/// Boxed, an expression is 80 bytes where it was 288.
/// `vars` holds one name, or more for `for ((k, v) in m)`, where each element
/// supplies the matching component.
    
pub const ForExpr = struct {
    vars: []Ident,
    by_name: bool = false,
/// True even for a one-element group: `for ([b] in xs)` calls `component1()`,
/// `for (x in xs)` binds the element.
    destructured: bool = false,
    var_sources: []Ident = &.{},
    var_ty: ?TypeRef,
    iter: *Expr,
    body: *Expr,
    span: Span,
};

    
pub const TryExpr = struct {
    body: Block,
    catches: []Catch,
    finally: ?Block,
    span: Span,
};

/// `qualifier` carries `super<Base>.foo()`, needed when several supertypes
/// supply a matching member; `label` carries `super@Outer.foo()`, dispatching
/// through the outer class's parent.
    
pub const SuperExpr = struct {
    qualifier: ?TypeRef,
    label: ?Ident,
    span: Span,
};

/// `subject` is `None` for the subject-free `when { cond -> ... }`. The first
/// match supplies the result; no match and no `else` throws
/// `kotlin.NoWhenBranchMatchedException`.
    
pub const WhenExpr = struct {
    subject: ?*Expr,
    subject_binding: ?WhenBinding,
    branches: []WhenBranch,
    span: Span,
};

    
pub const IsCheckExpr = struct {
    expr: *Expr,
    ty: TypeRef,
    negated: bool,
    span: Span,
};

/// Under `safe` a failed cast yields `null` instead of throwing `kotlin.ClassCastException`.
    
pub const AsExpr = struct {
    expr: *Expr,
    ty: TypeRef,
    safe: bool,
    span: Span,
};

    
pub const AnonFunExpr = struct {
    receiver_ty: ?TypeRef,
    context_params: []ContextParam = &.{},
    params: []Param,
    return_ty: ?TypeRef,
    body: ?*FunctionBody,
    is_suspend: bool,
    span: Span,
};

/// Captures the enclosing scope for its method bodies; each occurrence gives
/// a fresh `ClassDef` and one instance.
    
pub const ObjectLiteral = struct {
    supertypes: []TypeRef,
    supertype_args: []?[]Expr,
    supertype_arg_names: []const ?[]const ?[]const u8 = &.{},
    supertype_delegates: []?Expr,
    members: []Decl,
    init_blocks: []Block,
    /// See `Class.init_block_positions`.
    init_block_positions: []usize,
    span: Span,
};

pub const LambdaExpr = struct {
    params: []Ident,
    /// Aligned with `params`, `null` per unannotated slot; empty when the
    /// literal declares no header.
    param_tys: []?TypeRef = &.{},
    /// Read by the compose pass to transform an `@Composable { ... }` literal
    /// bound to an untyped val.
    annotations: []Annotation = &.{},
    body: Block,
    span: Span,
    /// The parser injected the single `it`; real arity comes from the expected
    /// type, so `{ x() }` is `() -> R` in value position and `(T) -> R` where
    /// one parameter is expected.
    implicit_it: bool = false,
};

pub const Expr = union(enum) {
    IntLit: struct {
        value: i64,
        kind: IntLitKind,
        span: Span,
    },
    FloatLit: struct {
        value: f64,
        kind: FloatLitKind,
        span: Span,
    },
    BoolLit: struct {
        value: bool,
        span: Span,
    },
    NullLit: struct {
        span: Span,
    },
    CharLit: struct {
        value: u16,
        span: Span,
    },
    StringTemplate: struct {
        parts: []StringPart,
        span: Span,
    },
    Path: struct {
        segments: []Ident,
        span: Span,
    },
    Member: struct {
        receiver: *Expr,
        name: Ident,
        safe: bool,
        span: Span,
    },
    /// `arg_names` is parallel to `args`: the label where the source wrote
    /// `label = arg`, `None` where positional. `type_args` holds call-site type
    /// arguments, consumed by reified type parameters.
    Call: struct {
        callee: *Expr,
        args: []Expr,
        arg_names: []?[]const u8,
        type_args: []TypeRef,
        is_infix: bool,
    /// A trailing lambda binds to the LAST parameter; a parenthesized
    /// `f(x, { ... })` binds positionally and leaves this false.
        has_trailing_lambda: bool = false,
        /// Parentheses enclose the whole call, so a following lambda invokes its result.
        grouped: bool = false,
        span: Span,
    },
    Index: struct {
        receiver: *Expr,
        args: []Expr,
        span: Span,
    },
    Binary: struct {
        op: BinOp,
        lhs: *Expr,
        rhs: *Expr,
        span: Span,
    },
    Unary: struct {
        op: UnOp,
        expr: *Expr,
        span: Span,
    },
    Postfix: struct {
        op: PostfixOp,
        expr: *Expr,
        span: Span,
    },
    If: struct {
        cond: *Expr,
        then_branch: *Expr,
        else_branch: ?*Expr,
        span: Span,
    },
    While: struct {
        cond: *Expr,
        body: *Expr,
        span: Span,
    },
    /// The body is optional, covering `do; while (c)`.
    DoWhile: struct {
        body: ?*Expr,
        cond: *Expr,
        span: Span,
    },
    /// `vars` holds one name, or more for `for ((k, v) in m)`, where each element
    /// supplies the matching component.
    For: *ForExpr,
    Return: struct {
        value: ?*Expr,
        label: ?Ident,
        span: Span,
    },
    Break: struct {
        label: ?Ident,
        span: Span,
    },
    Continue: struct {
        label: ?Ident,
        span: Span,
    },
    Labeled: struct {
        label: Ident,
        expr: *Expr,
        span: Span,
    },
    Block: Block,
    Throw: struct {
        value: *Expr,
        span: Span,
    },
    Try: *TryExpr,
    Lambda: *LambdaExpr,
    This: struct {
        qualifier: ?Ident,
        span: Span,
    },
    /// `qualifier` carries `super<Base>.foo()`, needed when several supertypes
    /// supply a matching member; `label` carries `super@Outer.foo()`, dispatching
    /// through the outer class's parent.
    Super: *SuperExpr,
    PropertyRef: struct {
        name: Ident,
        span: Span,
    },
    MemberRef: struct {
        receiver: *Expr,
        name: Ident,
        /// `Alias<Any>::foo`: written type arguments make the qualifier a type, so
        /// the reference is unbound even where the qualifier names an object.
        qualifier_type_args: []TypeRef = &.{},
        span: Span,
    },
    /// `subject` is `None` for the subject-free `when { cond -> ... }`. The first
    /// match supplies the result; no match and no `else` throws
    /// `kotlin.NoWhenBranchMatchedException`.
    When: *WhenExpr,
    IsCheck: *IsCheckExpr,
    /// Under `safe` a failed cast yields `null` instead of throwing `kotlin.ClassCastException`.
    As: *AsExpr,
    AnonFun: *AnonFunExpr,
    /// Valid only as a top-level value argument; typeck rejects a non-`vararg`
    /// bound parameter.
    Spread: struct {
        expr: *Expr,
        span: Span,
    },
    /// Captures the enclosing scope for its method bodies; each occurrence gives
    /// a fresh `ClassDef` and one instance.
    ObjectExpr: *ObjectLiteral,

    pub fn span(self: *const Expr) Span {
        return switch (self.*) {
            .IntLit => |e| e.span,
            .FloatLit => |e| e.span,
            .BoolLit => |e| e.span,
            .NullLit => |e| e.span,
            .CharLit => |e| e.span,
            .StringTemplate => |e| e.span,
            .Path => |e| e.span,
            .Member => |e| e.span,
            .Call => |e| e.span,
            .Index => |e| e.span,
            .Binary => |e| e.span,
            .Unary => |e| e.span,
            .Postfix => |e| e.span,
            .If => |e| e.span,
            .While => |e| e.span,
            .DoWhile => |e| e.span,
            .For => |e| e.span,
            .Return => |e| e.span,
            .Break => |e| e.span,
            .Continue => |e| e.span,
            .Labeled => |e| e.span,
            .Throw => |e| e.span,
            .Try => |e| e.span,
            .Lambda => |e| e.span,
            .This => |e| e.span,
            .Super => |e| e.span,
            .PropertyRef => |e| e.span,
            .MemberRef => |e| e.span,
            .When => |e| e.span,
            .IsCheck => |e| e.span,
            .As => |e| e.span,
            .AnonFun => |e| e.span,
            .Spread => |e| e.span,
            .ObjectExpr => |e| e.span,
            .Block => |b| b.span,
        };
    }
};

/// `when (val name: Ty = subject)`; `ty` is `None` when the annotation was omitted.
pub const WhenBinding = struct {
    name: Ident,
    ty: ?TypeRef,
    annotations: []Annotation,
    span: Span,
};

pub const WhenBranch = struct {
    /// The branch fires when any pattern matches; `Else` may only appear alone.
    patterns: []WhenPattern,
    body: Expr,
    span: Span,
};

pub const WhenPattern = struct {
    kind: WhenPatternKind,
    span: Span,
};

pub const WhenPatternKind = union(enum) {
    /// Equality against the subject, or a Boolean condition in a subject-free `when`.
    Value: Expr,
    InRange: Expr,
    NotInRange: Expr,
    /// Implies a smart cast in the branch body when the subject is a single identifier.
    IsType: TypeRef,
    NotIsType: TypeRef,
    Else,
};

pub const Catch = struct {
    binding: Ident,
    ty: TypeRef,
    body: Block,
    span: Span,
};

pub const StringPart = union(enum) {
    Text: []const u8,
    ShortInterp: Ident,
    /// Boxed so a `StringPart` stays pointer-sized; most parts are plain `Text`.
    Interp: *Expr,
};

pub const BinOp = enum {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Neq,
    IdentEq,
    IdentNeq,
    Lt,
    Le,
    Gt,
    Ge,
    In,
    NotIn,
    And,
    Or,
    Range,
    RangeUntil,
    Elvis,
    Assign,
};

pub const UnOp = enum {
    Neg,
    Pos,
    Not,
    PreInc,
    PreDec,
};

pub const PostfixOp = enum {
    Inc,
    Dec,
    NotNull,
};

test "expr span returns inline-variant span" {
    const f = span.FileId.from(0);
    const s = Span.init(f, 3, 7);
    const e = Expr{ .IntLit = .{ .value = 42, .kind = .Int, .span = s } };
    try std.testing.expect(e.span().eql(s));
}

test "expr span returns block span" {
    const f = span.FileId.from(0);
    const s = Span.init(f, 1, 9);
    const e = Expr{ .Block = .{ .stmts = &.{}, .span = s } };
    try std.testing.expect(e.span().eql(s));
}

test "enum defaults match kotlin source defaults" {
    try std.testing.expectEqual(Visibility.Public, Visibility.default);
    try std.testing.expectEqual(Variance.Invariant, Variance.default);
    try std.testing.expectEqual(IntLitKind.Int, IntLitKind.default);
    try std.testing.expectEqual(FloatLitKind.Double, FloatLitKind.default);
}

test "recursive expr nodes box through pointers" {
    const f = span.FileId.from(0);
    var lit = Expr{ .IntLit = .{ .value = 1, .kind = .Int, .span = Span.init(f, 0, 1) } };
    const u = Expr{ .Unary = .{ .op = .Neg, .expr = &lit, .span = Span.init(f, 0, 2) } };
    try std.testing.expectEqual(UnOp.Neg, u.Unary.op);
    try std.testing.expectEqual(@as(i64, 1), u.Unary.expr.IntLit.value);
}

// Whether a body declares something, exhaustive over every `Stmt` and `Expr`
// case. Two passes read it: lowering, whose instructions point into an object
// expression or a local classifier, and the type checker, whose workers share
// the signature and class tables a local declaration writes.

/// What a walk counts as a declaration inside a body.
pub const Declares = struct {
    /// An `object : T {}` expression counts.
    object_exprs: bool = false,
    /// A nested `fun` counts; a nested class or object always does.
    nested_fns: bool = false,
};

/// Whether `b` declares anything `opts` counts.
pub fn bodyDeclares(comptime opts: Declares, b: *const FunctionBody) bool {
    return bodyHas(opts, b);
}

/// Whether the bodies `d` owns declare anything `opts` counts: its own body,
/// a property's initialiser and accessors, and the same for every member of a
/// class or object. `d` itself is not a declaration inside a body, so it never
/// answers for itself.
pub fn declBodiesDeclare(comptime opts: Declares, d: *const Decl) bool {
    return switch (d.*) {
        .Function => |*f| if (f.body) |*b| bodyHas(opts, b) else false,
        .Property => propertyHas(opts, d.Property),
        .Class => |*c| {
            for (c.members) |*m| if (declBodiesDeclare(opts, m)) return true;
            return false;
        },
        .Object => |*o| {
            for (o.members) |*m| if (declBodiesDeclare(opts, m)) return true;
            return false;
        },
        .TypeAlias => false,
    };
}

fn bodyHas(comptime opts: Declares, b: *const FunctionBody) bool {
    return switch (b.*) {
        .Block => |*blk| blockHas(opts, blk),
        .Expr => |*e| exprHas(opts, e),
    };
}

fn blockHas(comptime opts: Declares, b: *const Block) bool {
    for (b.stmts) |*s| if (stmtHas(opts, s)) return true;
    return false;
}

fn stmtHas(comptime opts: Declares, s: *const Stmt) bool {
    return switch (s.*) {
        .Expr => |*e| exprHas(opts, e),
        .Decl => |d| declHas(opts, d),
        .Assign => |a| exprHas(opts, &a.target) or exprHas(opts, &a.value),
        .DestructuringDecl => |dd| exprHas(opts, &dd.init),
    };
}

fn propertyHas(comptime opts: Declares, p: *const Property) bool {
    if (p.init) |e| if (exprHas(opts, e)) return true;
    if (p.explicit_field) |ef| {
        if (ef.init) |e| if (exprHas(opts, e)) return true;
    }
    if (p.delegate) |e| if (exprHas(opts, e)) return true;
    if (p.getter) |acc| if (bodyHas(opts, &acc.body)) return true;
    if (p.setter) |acc| if (bodyHas(opts, &acc.body)) return true;
    return false;
}

fn declHas(comptime opts: Declares, d: *const Decl) bool {
    return switch (d.*) {
        // A nested function registers its signature where the checker's
        // workers can see it; lowering only cares about classifiers.
        .Function => |*f| if (opts.nested_fns)
            true
        else if (f.body) |*b| bodyHas(opts, b) else false,
        .Property => propertyHas(opts, d.Property),
        // Declared inside a body: an `Inst.RegisterClass` points at it.
        .Class, .Object => true,
        .TypeAlias => false,
    };
}

fn optExprHas(comptime opts: Declares, e: ?*const Expr) bool {
    return if (e) |x| exprHas(opts, x) else false;
}

fn exprHas(comptime opts: Declares, e: *const Expr) bool {
    return switch (e.*) {
        .ObjectExpr => opts.object_exprs,
        .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .This, .Super, .PropertyRef, .Break, .Continue => false,
        .StringTemplate => |*x| {
            for (x.parts) |*p| switch (p.*) {
                .Interp => |ie| if (exprHas(opts, ie)) return true,
                .Text, .ShortInterp => {},
            };
            return false;
        },
        .Member => |*x| exprHas(opts, x.receiver),
        .Call => |*x| {
            if (exprHas(opts, x.callee)) return true;
            for (x.args) |*a| if (exprHas(opts, a)) return true;
            return false;
        },
        .Index => |*x| {
            if (exprHas(opts, x.receiver)) return true;
            for (x.args) |*a| if (exprHas(opts, a)) return true;
            return false;
        },
        .Binary => |*x| exprHas(opts, x.lhs) or exprHas(opts, x.rhs),
        .Unary => |*x| exprHas(opts, x.expr),
        .Postfix => |*x| exprHas(opts, x.expr),
        .If => |*x| exprHas(opts, x.cond) or exprHas(opts, x.then_branch) or optExprHas(opts, x.else_branch),
        .While => |*x| exprHas(opts, x.cond) or exprHas(opts, x.body),
        .DoWhile => |*x| optExprHas(opts, x.body) or exprHas(opts, x.cond),
        .For => |x| exprHas(opts, x.iter) or exprHas(opts, x.body),
        .Return => |*x| optExprHas(opts, x.value),
        .Labeled => |*x| exprHas(opts, x.expr),
        .Block => |*x| blockHas(opts, x),
        .Throw => |*x| exprHas(opts, x.value),
        .Try => |x| {
            if (blockHas(opts, &x.body)) return true;
            for (x.catches) |*c| if (blockHas(opts, &c.body)) return true;
            if (x.finally) |*fb| if (blockHas(opts, fb)) return true;
            return false;
        },
        .Lambda => |x| blockHas(opts, &x.body),
        .MemberRef => |*x| exprHas(opts, x.receiver),
        .When => |x| {
            if (optExprHas(opts, x.subject)) return true;
            for (x.branches) |*br| {
                if (exprHas(opts, &br.body)) return true;
                for (br.patterns) |*p| switch (p.kind) {
                    .Value => |*ve| if (exprHas(opts, ve)) return true,
                    .InRange => |*ie| if (exprHas(opts, ie)) return true,
                    .NotInRange => |*ie| if (exprHas(opts, ie)) return true,
                    .IsType, .NotIsType, .Else => {},
                };
            }
            return false;
        },
        .IsCheck => |x| exprHas(opts, x.expr),
        .As => |x| exprHas(opts, x.expr),
        .AnonFun => |x| if (x.body) |b| bodyHas(opts, b) else false,
        .Spread => |*x| exprHas(opts, x.expr),
    };
}

fn testSpan() Span {
    return .{ .file = @enumFromInt(0), .start = 0, .end = 0 };
}

fn testFn(body: ?FunctionBody) Function {
    return .{
        .name = .{ .name = "f", .span = testSpan() },
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = null,
        .body = body,
        .is_open = false,
        .is_override = false,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = testSpan(),
    };
}

test "a nested function answers only the walk that counts one" {
    // fun outer() { fun inner() {} }
    var inner = Decl{ .Function = testFn(.{ .Block = .{ .stmts = &.{}, .span = testSpan() } }) };
    var stmts = [_]Stmt{.{ .Decl = &inner }};
    const outer = Decl{ .Function = testFn(.{ .Block = .{ .stmts = &stmts, .span = testSpan() } }) };

    // The checker's walk: a nested `fun` registers a signature in the shared
    // table, so the body checks serially.
    try std.testing.expect(declBodiesDeclare(.{ .nested_fns = true }, &outer));
    // Lowering's walk: only a classifier matters to it.
    try std.testing.expect(!declBodiesDeclare(.{}, &outer));
    try std.testing.expect(!declBodiesDeclare(.{ .object_exprs = true }, &outer));

    // A body that declares nothing answers neither.
    const bare = Decl{ .Function = testFn(.{ .Block = .{ .stmts = &.{}, .span = testSpan() } }) };
    try std.testing.expect(!declBodiesDeclare(.{ .nested_fns = true }, &bare));
    // Nor does a bodyless declaration.
    const abstract = Decl{ .Function = testFn(null) };
    try std.testing.expect(!declBodiesDeclare(.{ .nested_fns = true }, &abstract));
}

test "a local function inside a lambda answers" {
    // fun outer() { run { fun inner() {} } }
    var inner = Decl{ .Function = testFn(.{ .Block = .{ .stmts = &.{}, .span = testSpan() } }) };
    var lambda_stmts = [_]Stmt{.{ .Decl = &inner }};
    var lambda = LambdaExpr{
        .params = &.{},
        .body = .{ .stmts = &lambda_stmts, .span = testSpan() },
        .span = testSpan(),
    };
    var lambda_expr = Expr{ .Lambda = &lambda };
    var outer_stmts = [_]Stmt{.{ .Expr = lambda_expr }};
    const outer = Decl{ .Function = testFn(.{ .Block = .{ .stmts = &outer_stmts, .span = testSpan() } }) };
    try std.testing.expect(declBodiesDeclare(.{ .nested_fns = true }, &outer));
    try std.testing.expect(!declBodiesDeclare(.{}, &outer));
    _ = &lambda_expr;
}

test {
    _ = annotation_targets;
    _ = alias_expand;
}
