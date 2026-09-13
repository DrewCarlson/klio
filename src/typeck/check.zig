//! Tolerant static type checker.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const resolver = @import("resolver");
const types = @import("types");
const cfa = @import("cfa");

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const FileId = span.FileId;

pub const KotlinFile = ast.KotlinFile;
pub const Decl = ast.Decl;
pub const Class = ast.Class;
pub const Function = ast.Function;
pub const Property = ast.Property;
pub const ObjectDecl = ast.ObjectDecl;
pub const Param = ast.Param;
pub const Accessor = ast.Accessor;
pub const Block = ast.Block;
pub const Stmt = ast.Stmt;
pub const Expr = ast.Expr;
pub const FunctionBody = ast.FunctionBody;
pub const TypeRef = ast.TypeRef;
pub const TypeParam = ast.TypeParam;
pub const WhereBound = ast.WhereBound;
pub const Visibility = ast.Visibility;
pub const AssignOp = ast.AssignOp;
pub const BinOp = ast.BinOp;
pub const UnOp = ast.UnOp;
pub const PostfixOp = ast.PostfixOp;
pub const WhenBranch = ast.WhenBranch;
pub const WhenPatternKind = ast.WhenPatternKind;
pub const StringPart = ast.StringPart;
pub const Annotation = ast.Annotation;

pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticSink = diagnostics.DiagnosticSink;

pub const Resolution = resolver.Resolution;

pub const Type = types.Type;
pub const GenericArg = types.GenericArg;
pub const Variance = types.Variance;
pub const builtinByName = types.builtinByName;
pub const convertTypeRefLossy = types.convertTypeRefLossy;

pub const Cfg = cfa.Cfg;
pub const Lowered = cfa.lower.Lowered;

/// The per-aspect free functions over `*Checker`.
const phases = @import("check/phases.zig");
const decl = @import("check/decl.zig");
const expr = @import("check/expr.zig");
pub const expr_calls = @import("check/expr_calls.zig");
const annotations = @import("check/annotations.zig");
const visibility = @import("check/visibility.zig");
const narrowing = @import("check/narrowing.zig");
pub const context_params = @import("check/context_params.zig");

pub const helpers = @import("check/helpers.zig");

/// Every container here comes from the one driver-owned arena passed to
/// `typecheck`, freed once the last reader is done, so this has no teardown.
pub const TypeCheck = struct {
    /// Statements have no entry; a missing span was skipped or `Unresolved`.
    types: std.AutoHashMap(Span, Type),
    /// Consumers that feed lowering must skip these. See
    /// `Checker.generic_body_depth`.
    types_instantiation_dependent: std.AutoHashMap(Span, void),
    diagnostics: DiagnosticSink,
    /// Keyed by the owning function's span. The `cfa` analyses read these.
    cfgs: std.AutoHashMap(Span, Cfg),
    /// The chosen declaration's name-span, which lowering composes with its
    /// own decl-span to FuncId map, plus a render ("arity=N;p0=Int;ret=T").
    resolved_calls: std.AutoHashMap(Span, ResolvedCall),
    lambda_recv_heads: std.AutoHashMap(Span, []const u8),
    lambda_param_shapes: std.AutoHashMap(Span, ParamShape),
    /// A plain user class types as `Type.Unresolved`, so a receiver's class
    /// identity lives here instead.
    expr_class: std.AutoHashMap(Span, []const u8),
    /// Ranking only. Separate from `expr_class`, which lowering reads as type
    /// evidence: a head good enough to rank is not one lowering can bind.
    rank_class: std.AutoHashMap(Span, []const u8),

    pub fn typeOf(self: *const TypeCheck, sp: Span) ?*const Type {
        return self.types.getPtr(sp);
    }

    pub fn resolvedCallOf(self: *const TypeCheck, sp: Span) ?ResolvedCall {
        return self.resolved_calls.get(sp);
    }
};

pub const ParamShape = struct { has_receiver: bool, arity: u16 };

pub const ResolvedCall = struct {
    decl_span: ?Span,
    render: []const u8,
    /// Set for an image declaration, which carries FuncIds and no spans.
    extern_fid: ?u32 = null,
};

/// `resolution` is read, never mutated.
pub fn typecheck(
    allocator: Allocator,
    file: *const KotlinFile,
    resolution: *const Resolution,
) Allocator.Error!TypeCheck {
    const user_contracts = try scanUserInlineContracts(allocator, file);
    cfa.analyses.contracts.setUserInlineContracts(user_contracts);
    var tc = try Checker.new(allocator, resolution);
    defer destroyQueryScratch(allocator, tc.query_scratch);
    try tc.run(file);
    try annotations.applySuppressAnnotations(allocator, file, &tc.diagnostics);
    cfa.analyses.contracts.setUserInlineContracts(
        cfa.analyses.contracts.UserInlineContracts.init(allocator),
    );
    return .{
        .types = tc.types,
        .types_instantiation_dependent = tc.types_instantiation_dependent,
        .diagnostics = tc.diagnostics,
        .cfgs = tc.cfgs,
        .resolved_calls = tc.resolved_calls,
        .lambda_recv_heads = tc.lambda_recv_heads,
        .lambda_param_shapes = tc.lambda_param_shapes,
        .expr_class = tc.expr_class,
        .rank_class = tc.rank_class,
    };
}

/// Map each top-level `inline fun` to the parameters its
/// `contract { callsInPlace(p, EXACTLY_ONCE) }` names, so `cfa` lowering can
/// treat a `val` assigned inside such a lambda as assigned at the call site.
fn scanUserInlineContracts(
    allocator: Allocator,
    file: *const KotlinFile,
) Allocator.Error!cfa.analyses.contracts.UserInlineContracts {
    var out = cfa.analyses.contracts.UserInlineContracts.init(allocator);
    for (file.decls) |*d| {
        const f = switch (d.*) {
            .Function => |*f| f,
            else => continue,
        };
        if (!f.is_inline) continue;
        const stmts: []const Stmt = switch (f.body orelse continue) {
            .Block => |b| b.stmts,
            else => continue,
        };
        if (stmts.len == 0) continue;
        const first = stmts[0];
        const call0 = switch (first) {
            .Expr => |*e| switch (e.*) {
                .Call => |c| c,
                else => continue,
            },
            else => continue,
        };
        if (!calleeNameIs(call0.callee, "contract")) continue;
        if (call0.args.len == 0) continue;
        const lam = switch (call0.args[call0.args.len - 1]) {
            .Lambda => |l| l,
            else => continue,
        };
        var once: std.ArrayList([]const u8) = .empty;
        for (lam.body.stmts) |s| {
            const call = switch (s) {
                .Expr => |*e| switch (e.*) {
                    .Call => |c| c,
                    else => continue,
                },
                else => continue,
            };
            if (!calleeNameIs(call.callee, "callsInPlace")) continue;
            if (call.args.len < 2) continue;
            const target_name = switch (call.args[0]) {
                .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else continue,
                else => continue,
            };
            const kind_tail: ?[]const u8 = switch (call.args[1]) {
                .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else null,
                .Member => |m| m.name.name,
                else => null,
            };
            if (kind_tail == null or !std.mem.eql(u8, kind_tail.?, "EXACTLY_ONCE")) continue;
            try once.append(allocator, target_name);
        }
        if (once.items.len != 0) {
            try out.put(f.name.name, try once.toOwnedSlice(allocator));
        } else {
            once.deinit(allocator);
        }
    }
    return out;
}

fn calleeNameIs(callee: *const Expr, name: []const u8) bool {
    return switch (callee.*) {
        .Path => |p| p.segments.len > 0 and std.mem.eql(u8, p.segments[p.segments.len - 1].name, name),
        else => false,
    };
}

/// Per-decl `Span.file` survives the merge, so cross-file visibility checks
/// still work.
pub fn typecheckModule(
    allocator: Allocator,
    files: []const KotlinFile,
    resolution: *const Resolution,
) Allocator.Error!TypeCheck {
    const merged = try mergeModuleFiles(allocator, files);
    const user_contracts = try scanUserInlineContracts(allocator, &merged);
    cfa.analyses.contracts.setUserInlineContracts(user_contracts);
    var tc = try Checker.new(allocator, resolution);
    defer destroyQueryScratch(allocator, tc.query_scratch);
    if (types.pending_extern_decls) |ed| {
        var cit = ed.classes.keyIterator();
        while (cit.next()) |k| {
            if (tc.classes.contains(k.*)) continue;
            var info = ClassInfo.init(allocator);
            // The candidate walk climbs supertypes.
            if (ed.has_extensions) {
                if (ed.supertypes.get(k.*)) |sups| {
                    for (sups) |s| try info.supertypes.append(allocator, s);
                }
            }
            try tc.classes.put(k.*, info);
        }
        tc.extern_fn_return_class = ed.fn_return_class;
        // Without these a member call on an image type finds no candidates.
        if (ed.has_extensions) {
            var eit = ed.extensions.iterator();
            while (eit.next()) |entry| {
                const gop = try tc.extensions.getOrPut(entry.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                for (entry.value_ptr.items) |*x| {
                    const params = try allocator.alloc(Type, x.param_heads.len);
                    for (x.param_heads, x.param_nullable, params) |h, nl, *out| {
                        out.* = try externHeadType(allocator, h, nl);
                    }
                    const defaults = try allocator.alloc(bool, x.param_heads.len);
                    @memset(defaults, false);
                    const varargs = try allocator.alloc(bool, x.param_heads.len);
                    @memset(varargs, false);
                    const pnames = try allocator.alloc([]const u8, x.param_heads.len);
                    @memset(pnames, "");
                    const crossinline = try allocator.alloc(bool, x.param_heads.len);
                    @memset(crossinline, false);
                    const pclasses = try allocator.alloc(?[]const u8, x.param_heads.len);
                    for (x.param_heads, pclasses) |h, *pc| {
                        pc.* = if (ed.classes.contains(h)) h else null;
                    }
                    try gop.value_ptr.append(allocator, .{
                        .name = x.name,
                        .sig = .{
                            .params = params,
                            .has_default = defaults,
                            .param_names = pnames,
                            .is_vararg = varargs,
                            .return_ty = try externHeadType(allocator, x.return_head, x.return_nullable),
                            .is_infix = x.is_infix,
                            .type_param_count = 0,
                            .type_param_names = &.{},
                            .type_param_bounds = &.{},
                            .param_class_names = pclasses,
                            .decl_span = null,
                            .is_suspend = false,
                            .is_extension = true,
                            .is_crossinline_param = crossinline,
                            .extern_fid = x.fid,
                        },
                        .return_class = if (ed.classes.contains(x.return_head)) x.return_head else null,
                    });
                }
            }
        }
        types.pending_extern_decls = null;
    }
    for (files) |*f| {
        const pkg = f.package orelse continue;
        var dotted: std.ArrayList(u8) = .empty;
        for (pkg.path, 0..) |id, i| {
            if (i != 0) try dotted.append(allocator, '.');
            try dotted.appendSlice(allocator, id.name);
        }
        try tc.file_packages.put(f.span.file.int(), try dotted.toOwnedSlice(allocator));
    }
    try tc.run(&merged);
    try annotations.applySuppressAnnotations(allocator, &merged, &tc.diagnostics);
    cfa.analyses.contracts.setUserInlineContracts(
        cfa.analyses.contracts.UserInlineContracts.init(allocator),
    );
    return .{
        .types = tc.types,
        .types_instantiation_dependent = tc.types_instantiation_dependent,
        .diagnostics = tc.diagnostics,
        .cfgs = tc.cfgs,
        .resolved_calls = tc.resolved_calls,
        .lambda_recv_heads = tc.lambda_recv_heads,
        .lambda_param_shapes = tc.lambda_param_shapes,
        .expr_class = tc.expr_class,
        .rank_class = tc.rank_class,
    };
}

/// Backed by the page allocator, not the driver's phase arena, so this
/// teardown is required even though everything else rides that arena.
fn destroyQueryScratch(allocator: Allocator, scratch: *std.heap.ArenaAllocator) void {
    scratch.deinit();
    allocator.destroy(scratch);
}

fn mergeModuleFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!KotlinFile {
    if (files.len == 0) {
        return .{
            .package = null,
            .imports = &.{},
            .decls = &.{},
            .span = Span{ .file = FileId.from(0), .start = 0, .end = 0 },
        };
    }
    var decls: std.ArrayList(Decl) = .empty;
    var imports: std.ArrayList(ast.ImportDecl) = .empty;
    for (files) |f| {
        try decls.appendSlice(allocator, f.decls);
        try imports.appendSlice(allocator, f.imports);
    }
    return .{
        .package = files[0].package,
        .imports = try imports.toOwnedSlice(allocator),
        .decls = try decls.toOwnedSlice(allocator),
        .span = files[0].span,
    };
}

pub const codes = struct {
    pub const TYPE_MISMATCH = "T0001";
    pub const TYPE_UNRESOLVED_REFERENCE = "T0002";
    pub const TYPE_NULL_SAFETY = "T0003";
    pub const TYPE_ARGUMENT_COUNT = "T0004";
    pub const TYPE_MISSING_RETURN = "T0005";
    pub const TYPE_VAL_REASSIGN = "T0006";
    pub const TYPE_ABSTRACT_MEMBER_NOT_IMPLEMENTED = "T0007";
    pub const TYPE_WRONG_RECEIVER = "T0008";
    pub const TYPE_OVERRIDE_NEEDED = "T0009";
    pub const TYPE_OVERRIDE_BUT_PARENT_NOT_OPEN = "T0010";
    pub const TYPE_OVERRIDE_BUT_NO_BASE = "T0011";
    pub const TYPE_DELEGATE_OPERATOR_REQUIRED = "T0012";
    pub const TYPE_DIAMOND_CONFLICT = "T0013";
    pub const TYPE_LATEINIT_VAL = "T0014";
    pub const TYPE_LATEINIT_PRIMITIVE = "T0015";
    pub const TYPE_LATEINIT_WITH_INITIALIZER = "T0016";
    pub const TYPE_LATEINIT_NULLABLE = "T0017";
    pub const TYPE_ACCESSOR_RETURN_TYPE_MISMATCH = "T0018";
    pub const TYPE_WHEN_NOT_EXHAUSTIVE = "T0019";
    pub const TYPE_VAR_NOT_DEFINITELY_ASSIGNED = "T0020";
    pub const TYPE_VARIANCE_VIOLATION = "T0021";
    pub const TYPE_BOUND_NOT_SATISFIED = "T0022";
    pub const TYPE_REIFIED_REQUIRES_INLINE = "T0023";
    pub const TYPE_DECLARATION_VARIANCE_VIOLATION = "T0024";
    pub const TYPE_VARARG_MISUSE = "T0025";
    pub const TYPE_INLINE_MODIFIER_OUTSIDE_INLINE = "T0026";
    pub const TYPE_DEFINITELY_NON_NULL_NOT_TYPE_PARAM = "T0027";
    pub const TYPE_UNCHECKED_CAST = "T0028";
    pub const TYPE_INFIX_MODIFIER_REQUIRED = "T0029";
    pub const TYPE_UNRESOLVED_LABEL = "T0030";
    pub const TYPE_INVISIBLE_MEMBER = "T0031";
    pub const TYPE_INVISIBLE_REFERENCE = "T0032";
    pub const TYPE_CONST_VAL_NOT_TOPLEVEL = "T0033";
    pub const TYPE_CONST_VAL_NON_CONST_INIT = "T0034";
    pub const TYPE_VALUE_CLASS_SHAPE = "T0035";
    pub const TYPE_ANNOTATION_CLASS_SHAPE = "T0036";
    pub const TYPE_ANNOTATION_PARAM_TYPE = "T0037";
    pub const TYPE_RECURSIVE_TYPEALIAS = "T0038";
    pub const TYPE_TYPEALIAS_NOT_TOPLEVEL = "T0039";
    pub const TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER = "T0040";
    pub const TYPE_EXTENSION_PROPERTY_HAS_DELEGATE = "T0041";
    pub const TYPE_EXTENSION_PROPERTY_NEEDS_ACCESSOR = "T0042";
    pub const TYPE_DELEGATION_TARGET_NOT_INTERFACE = "T0043";
    pub const TYPE_DELEGATION_TYPE_MISMATCH = "T0044";
    pub const TYPE_DATA_OBJECT_FORBIDS_EQUALS_HASHCODE = "T0045";
    pub const TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR = "T0046";
    pub const TYPE_SPREAD_REQUIRES_VARARG = "T0047";
    pub const TYPE_NON_TAIL_RECURSIVE_CALL = "T0048";
    pub const TYPE_NO_TAIL_CALLS_FOUND = "T0049";
    pub const TYPE_ENUM_FORBIDS_FINAL_OVERRIDE = "T0050";
    pub const TYPE_THROWABLE_TYPE_PARAMS = "T0051";
    pub const TYPE_TAILREC_ON_OPEN = "T0057";
    pub const TYPE_DATA_CLASS_FORBIDS_COMPONENT_OVERRIDE = "T0058";
    pub const TYPE_DATA_CLASS_FORBIDS_COPY_OVERRIDE = "T0059";
    pub const TYPE_CONSTRUCTOR_DELEGATION_CYCLE = "T0060";
    pub const TYPE_DATA_CLASS_NO_PROPERTIES = "T0061";
    pub const TYPE_DATA_CLASS_VARARG_PROPERTY = "T0062";
    pub const TYPE_INLINE_PROPERTY_HAS_BACKING_FIELD = "T0053";
    pub const TYPE_PROPERTY_NO_BACKING_FIELD_HAS_INITIALIZER = "T0054";
    pub const TYPE_INLINE_PARAM_LEAK = "T0055";
    pub const TYPE_CROSSINLINE_PARAM_LEAK = "T0056";
    pub const TYPE_INHERIT_FROM_FINAL_CLASS = "T0063";
    pub const TYPE_INHERIT_FROM_OBJECT = "T0064";
    pub const TYPE_OVERRIDE_RETURN_TYPE_MISMATCH = "T0065";
    pub const TYPE_OVERRIDE_PROPERTY_MUTABILITY = "T0066";
    pub const TYPE_OVERRIDE_PROPERTY_TYPE = "T0067";
    pub const TYPE_OVERRIDE_VISIBILITY_STRONGER = "T0068";
    pub const TYPE_PRIVATE_AND_OPEN_OR_ABSTRACT_OR_OVERRIDE = "T0070";
    pub const TYPE_SEALED_INHERITOR_NOT_QUALIFIED = "T0071";
    pub const TYPE_DATA_OR_ENUM_CLASS_OPEN_OR_ABSTRACT = "T0072";
    pub const TYPE_LABEL_TARGET_NOT_LABELABLE = "T0078";
    pub const TYPE_PROPERTY_INITIALIZER_CYCLE = "T0076";
    pub const TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE = "T0075";
    pub const TYPE_REFERENCE_EQUALITY_DISTINCT_TYPES = "T0081";
    pub const TYPE_VALUE_EQUALITY_DISTINCT_TYPES = "T0082";
    pub const TYPE_CAST_TO_NON_REIFIED_TYPE_PARAMETER = "T0083";
    pub const TYPE_BARE_TYPE_INFERENCE_FAILED = "T0084";
    pub const TYPE_ANONYMOUS_OBJECT_ESCAPES_PUBLIC = "T0085";
    pub const TYPE_SPREAD_TYPE_MISMATCH = "T0086";
    pub const TYPE_OPERATOR_KEYWORD_MISSING = "T0087";
    pub const TYPE_OPERATOR_SIGNATURE_MISMATCH = "T0088";
    pub const TYPE_NAMED_PARAMETER_NOT_FOUND = "T0089";
    pub const TYPE_NONE_APPLICABLE = "T0090";
    pub const TYPE_OVERLOAD_RESOLUTION_AMBIGUITY = "T0091";
    pub const TYPE_TYPE_ARGUMENT_COUNT_MISMATCH = "T0092";
    pub const TYPE_AMBIGUOUS_SUPER = "T0093";
    pub const TYPE_CONFLICTING_OVERLOADS = "T0094";
    pub const WARN_UNREACHABLE_CODE = "W0002";
    pub const WARN_SENSELESS_COMPARISON = "W0003";
    pub const WARN_USELESS_CAST = "W0004";
    pub const WARN_USELESS_ELVIS = "W0005";
    pub const TYPE_STAR_PROJECTION_WRITE = "T0095";
    pub const TYPE_CIRCULAR_TYPE_BOUND = "T0096";
    pub const TYPE_INFERENCE_FAILED = "T0097";
    pub const TYPE_INFERENCE_AMBIGUOUS = "T0098";
    pub const TYPE_INFERENCE_CYCLE = "T0099";
    pub const TYPE_CANNOT_CHECK_FOR_ERASED_TYPE_PARAMETER = "T0100";
    pub const TYPE_NULLABLE_CLASS_LITERAL_LHS = "T0101";
    pub const TYPE_NON_REIFIED_CLASS_LITERAL = "T0102";
    pub const TYPE_CLASS_LITERAL_LHS_NOT_A_CLASS = "T0103";
    pub const TYPE_CLASS_LITERAL_WITH_TYPE_ARGUMENTS = "T0104";
    pub const TYPE_RUNTIME_UNAVAILABLE_CATCH_TYPE = "T0105";
    pub const TYPE_THROW_NON_THROWABLE = "T0106";
    pub const TYPE_ANNOTATION_CYCLE = "T0107";
    pub const TYPE_ANNOTATION_PARAM_DEFAULT_NOT_CONST = "T0108";
    pub const TYPE_ANNOTATION_NOT_REPEATABLE = "T0109";
    pub const TYPE_ANNOTATION_TARGET_MISMATCH = "T0110";
    pub const TYPE_DEPRECATED_ERROR = "T0111";
    pub const TYPE_OPT_IN_REQUIRED = "T0112";
    pub const TYPE_DSL_SCOPE_VIOLATION = "T0113";
    pub const TYPE_SUSPEND_NOT_ALLOWED = "T0114";
    pub const TYPE_SUSPEND_CALL_FROM_NON_SUSPEND = "T0115";
    pub const TYPE_OVERRIDE_SUSPEND_MISMATCH = "T0069";
    pub const TYPE_SUSPEND_FUNCTION_TYPE_MISMATCH = "T0116";
    pub const TYPE_ASSIGN_OPERATOR_AMBIGUITY = "T0079";
    pub const TYPE_SUPER_QUALIFIER_NOT_SUPERTYPE = "T0073";
    pub const TYPE_ASSIGNMENT_IN_EXPRESSION_CONTEXT = "T0117";
    pub const TYPE_EXPLICIT_BACKING_FIELD = "T0118";
    pub const TYPE_INAPPLICABLE_ALL_TARGET = "T0119";
    pub const WARN_DEPRECATED = "W0006";
    pub const WARN_OPT_IN = "W0007";
    pub const WARN_REDUNDANT_EXPLICIT_BACKING_FIELD = "W0008";
};

/// Lexically stacked. Smart-cast facts live in the CFG, not here.
pub const Frame = struct {
    bindings: std.StringHashMap(Binding),

    pub fn init(allocator: Allocator) Frame {
        return .{ .bindings = std.StringHashMap(Binding).init(allocator) };
    }

    pub fn deinit(self: *Frame) void {
        self.bindings.deinit();
    }
};

pub const Binding = struct {
    ty: Type,
    mutable: bool,
    decl_span: ?Span,
    /// Set for a user class, not a builtin or function type.
    class_name: ?[]const u8,
    /// The bare-identifier spelling (`t: T`) that `convertTypeRefLossy`
    /// collapsed to `Type.Unresolved`, for runtime-availability checks.
    decl_type_name: ?[]const u8,
    /// `ty` above is then the narrowed field type and this the public view,
    /// which reads outside the declaring file see.
    ebf: ?EbfBinding = null,
};

/// The frame binding holds the narrowed field type; this is the public view.
pub const EbfBinding = struct {
    public_ty: Type,
    public_class: ?[]const u8,
    public_display: []const u8,
    /// Narrowing is file-scoped.
    file: FileId,
};

/// Served to reads inside the declaring class's scope; `members` keeps the
/// public property type.
pub const EbfMember = struct {
    field_ty: Type,
    field_class: ?[]const u8,
    public_display: []const u8,
};

/// Recorded at an explicit-backing-field read outside the declaring scope:
/// member calls on it must resolve against the public type.
pub const EbfOutside = struct {
    /// Head class or interface name of the public type.
    head: ?[]const u8,
    display: []const u8,
};

/// Builtins become their exact type, anything else an argument-less `Generic`
/// that ranking compares by name. A short all-caps head stays a type parameter.
fn externHeadType(allocator: Allocator, head: []const u8, nullable: bool) Allocator.Error!Type {
    const base: Type = if (std.mem.eql(u8, head, "Unit"))
        .Unit
    else if (std.mem.eql(u8, head, "Boolean"))
        .Boolean
    else if (std.mem.eql(u8, head, "Byte"))
        .Byte
    else if (std.mem.eql(u8, head, "Short"))
        .Short
    else if (std.mem.eql(u8, head, "Int"))
        .Int
    else if (std.mem.eql(u8, head, "Long"))
        .Long
    else if (std.mem.eql(u8, head, "UByte"))
        .UByte
    else if (std.mem.eql(u8, head, "UShort"))
        .UShort
    else if (std.mem.eql(u8, head, "UInt"))
        .UInt
    else if (std.mem.eql(u8, head, "ULong"))
        .ULong
    else if (std.mem.eql(u8, head, "Float"))
        .Float
    else if (std.mem.eql(u8, head, "Double"))
        .Double
    else if (std.mem.eql(u8, head, "Char"))
        .Char
    else if (std.mem.eql(u8, head, "String"))
        .String
    else if (std.mem.eql(u8, head, "Any"))
        .Any
    else if (std.mem.eql(u8, head, "Nothing"))
        .Nothing
    else if (head.len == 0)
        .Unresolved
    else if (head.len <= 2 and std.ascii.isUpper(head[0]))
        Type{ .TypeParam = head }
    else
        Type{ .Generic = .{ .name = head, .args = &.{} } };
    if (!nullable) return base;
    const inner = try allocator.create(Type);
    inner.* = base;
    return Type{ .Nullable = inner };
}

pub const ExtensionSig = struct {
    name: []const u8,
    sig: FnSig,
    /// Carries `expr_class` through a `recv.ext()` chain, as
    /// `ClassInfo.member_class` does for a regular member.
    return_class: ?[]const u8,
};

pub const ExtensionPropSig = struct {
    name: []const u8,
    ty: Type,
    mutable: bool,
    return_class: ?[]const u8,
};

/// Every parallel slice is in source parameter order.
pub const FnSig = struct {
    params: []Type,
    has_default: []bool,
    param_names: [][]const u8,
    is_vararg: []bool,
    return_ty: Type,
    is_infix: bool,
    /// Filters candidates against an explicit call-site `<...>` list.
    type_param_count: usize,
    type_param_names: [][]const u8,
    /// Upper bounds per type parameter, in declaration order.
    type_param_bounds: [][]Type,
    /// A plain user class types as `Type.Unresolved`, so return-class identity
    /// travels beside the type.
    return_class: ?[]const u8 = null,
    /// Identity of an image declaration, which has no `decl_span`.
    extern_fid: ?u32 = null,
    /// Per parameter whose declared type names a known class.
    param_class_names: []?[]const u8,
    /// Null for synthetic and constructor signatures.
    decl_span: ?Span,
    is_suspend: bool,
    /// A bare call to an extension inside a receiver scope competes with
    /// candidates the flat name registry cannot see, so its pick never records.
    is_extension: bool = false,
    is_crossinline_param: []bool,
    /// Two overloads whose context type-sets differ are shadowed contextual
    /// overloads, not conflicting ones.
    context_types: []const []const u8 = &.{},
};

/// Kept apart from `MemberFlags` so name-keyed override walks keep their
/// semantics.
pub const MemberSig = union(enum) {
    Function: struct {
        param_types: []Type,
        return_ty: Type,
        visibility: Visibility,
        is_suspend: bool,
    },
    Property: struct {
        ty: Type,
        mutable: bool,
        visibility: Visibility,
    },
};

pub const MemberFlags = struct {
    is_open: bool = false,
    is_override: bool = false,
    is_abstract: bool = false,
    is_operator: bool = false,
    is_infix: bool = false,
    has_default_body: bool = false,
};

pub const TypedSupertype = struct {
    name: []const u8,
    args: []Type,
};

/// Records a collision instead of overwriting; see `ambiguous_class_names`.
pub fn putClassChecked(self: anytype, name: []const u8, info: ClassInfo, decl_file: ?FileId) !void {
    if (self.classes.getPtr(name)) |existing| {
        const same = if (existing.decl_file) |ef|
            (if (decl_file) |nf| ef.int() == nf.int() else false)
        else
            decl_file == null;
        if (!same) {
            try self.ambiguous_class_names.put(name, {});
        }
    }
    try self.classes.put(name, info);
}

/// Null when the simple name is ambiguous across packages.
pub fn classNamed(self: anytype, name: []const u8) ?ClassInfo {
    if (self.ambiguous_class_names.contains(name)) return null;
    return self.classes.get(name);
}

pub const ClassInfo = struct {
    /// Relaxes primary-constructor arity checks.
    has_secondary_ctors: bool = false,
    /// Primary-param properties, body properties, and methods.
    members: std.StringHashMap(Type),
    /// `members` collapses overloads to one entry; call-site selection reads
    /// every declared signature from here instead.
    member_methods: std.StringHashMap(std.ArrayList(FnSig)),
    member_mutable: std.StringHashMap(bool),
    ctor: ?FnSig = null,
    abstract_members: std.ArrayList([]const u8) = .empty,
    concrete_members: std.ArrayList([]const u8) = .empty,
    member_flags: std.StringHashMap(MemberFlags),
    member_sigs: std.StringHashMap(MemberSig),
    /// Set when a member's declared type names a user class.
    member_class: std.StringHashMap([]const u8),
    /// Present only for a property declared with a `field` clause.
    member_ebf: std.StringHashMap(EbfMember),
    /// Interfaces and classes alike.
    supertypes: std.ArrayList([]const u8) = .empty,
    typed_supertypes: std.ArrayList(TypedSupertype) = .empty,
    type_param_names: std.ArrayList([]const u8) = .empty,
    is_abstract: bool = false,
    is_interface: bool = false,
    is_sealed: bool = false,
    is_open: bool = false,
    is_object: bool = false,
    is_enum: bool = false,
    /// A local class, or an `object { … }` expression.
    is_local_or_anonymous: bool = false,
    member_visibility: std.StringHashMap(Visibility),
    decl_visibility: Visibility = .Public,
    decl_file: ?FileId = null,
    /// Set only when it diverges from the class's own visibility.
    primary_ctor_visibility: ?Visibility = null,

    pub fn init(allocator: Allocator) ClassInfo {
        return .{
            .members = std.StringHashMap(Type).init(allocator),
            .member_methods = std.StringHashMap(std.ArrayList(FnSig)).init(allocator),
            .member_mutable = std.StringHashMap(bool).init(allocator),
            .member_flags = std.StringHashMap(MemberFlags).init(allocator),
            .member_sigs = std.StringHashMap(MemberSig).init(allocator),
            .member_class = std.StringHashMap([]const u8).init(allocator),
            .member_ebf = std.StringHashMap(EbfMember).init(allocator),
            .member_visibility = std.StringHashMap(Visibility).init(allocator),
        };
    }
};

pub const VisFile = struct {
    visibility: Visibility,
    file: FileId,
};

/// One constraint system shared by every generic call in a single
/// source-level expression.
pub const InferenceSession = struct {
    cs: types.constraints.ConstraintSystem,
    /// Nesting depth of calls currently using the session.
    depth: u32,
    /// Every inference variable created here, under the unique `T@start-end`
    /// name the recorded types carry. A nested call returns before the root
    /// solves, so this is what lets the root substitute its placeholders.
    all_vars: std.ArrayList(SessionVar),
};

pub const SessionVar = struct { unique: []const u8, v: types.constraints.InferenceVar };

pub const TypeAliasInfo = struct {
    type_params: [][]const u8,
    target: TypeRef,
    /// Labels the alias in a cycle diagnostic.
    name_span: Span,
};

/// Each entry's `reachable` slice is owned by the checker's allocator and
/// replaced when its epoch falls behind `nothing_epoch`.
pub const ReachCache = std.AutoHashMap(Span, ReachEntry);

pub const ReachEntry = struct {
    epoch: u64,
    reachable: []bool,
};

pub const Checker = struct {
    allocator: Allocator,
    resolution: *const Resolution,
    types: std.AutoHashMap(Span, Type),
    resolved_calls: std.AutoHashMap(Span, ResolvedCall),
    /// The receiver class head `this` was bound to, by lambda body span. How
    /// lowering answers member-versus-global inside the body.
    lambda_recv_heads: std.AutoHashMap(Span, []const u8),
    /// Declared shape of function-typed lambda parameters the AST leaves
    /// unannotated (`{ f -> f(x) }`), by the parameter ident's span.
    lambda_param_shapes: std.AutoHashMap(Span, ParamShape),
    /// Where control diverges. Reachability consults this small set instead
    /// of walking `types`.
    nothing_spans: std.AutoHashMap(Span, void),
    /// The same spans bucketed by the function active when recorded, so a
    /// query over one CFG reads just its bucket.
    nothing_by_fn: std.AutoHashMap(Span, std.AutoHashMap(Span, void)),
    /// Bumped whenever `nothing_spans` changes. Reachability depends only on
    /// the CFG and that set, so the per-statement query caches against this.
    nothing_epoch: u64,
    /// Valid while the queried function and `nothing_epoch` both match.
    reach_cache: ReachCache,
    /// Populated for path, `this` and constructor-call sites whose static
    /// type is a user class.
    expr_class: std.AutoHashMap(Span, []const u8),
    /// See the field of the same name on the result struct.
    rank_class: std.AutoHashMap(Span, []const u8),
    list_elem: std.AutoHashMap(Span, Type),
    diagnostics: DiagnosticSink,
    frames: std.ArrayList(Frame),
    /// By simple name, each mapping to every overload's signature.
    fns: std.StringHashMap(std.ArrayList(FnSig)),
    /// Dotted package per file. Two same-name signatures from different
    /// packages are not an overload pair.
    file_packages: std.AutoHashMap(u32, []const u8),
    /// Keyed by the receiver type's simple name.
    extensions: std.StringHashMap(std.ArrayList(ExtensionSig)),
    /// Every name declared as an extension on any receiver. A bare call
    /// inside an extension body has that receiver in scope, so these names
    /// stay out of the eager call channel.
    extension_fn_names: std.StringHashMap(void),
    extension_properties: std.StringHashMap(std.ArrayList(ExtensionPropSig)),
    classes: std.StringHashMap(ClassInfo),
    /// For functions known only from a prebuilt image.
    extern_fn_return_class: ?std.StringHashMap([]const u8) = null,
    /// Names declared by more than one class. `classes` is keyed by simple
    /// name, so these would otherwise answer with whichever registered last,
    /// and a wrong answer feeds the eager evidence channel. They answer
    /// nothing instead.
    ambiguous_class_names: std.StringHashMap(void),
    /// Enclosing class name while a class body is checked.
    class_stack: std.ArrayList([]const u8),
    /// Enclosing function's declared/inferred return type for `return`.
    fn_return_stack: std.ArrayList(Type),
    /// Lexically active jump labels bound by enclosing loops or `Labeled`.
    label_stack: std.ArrayList([]const u8),
    fn_visibility: std.StringHashMap(std.ArrayList(VisFile)),
    prop_visibility: std.StringHashMap(VisFile),
    /// Only for a `var` whose setter is more restrictive than the property.
    setter_visibility: std.StringHashMap(VisFile),
    aliases: std.StringHashMap(TypeAliasInfo),
    /// Is the enclosing function `public inline`?
    public_inline_stack: std.ArrayList(bool),
    /// Is each enclosing function or lambda a suspending context?
    suspend_context_stack: std.ArrayList(bool),
    reified_type_params: std.ArrayList(std.StringHashMap(void)),
    /// Every type-parameter name in scope, per enclosing function or class.
    type_params_in_scope: std.ArrayList(std.StringHashMap(void)),
    /// Parallel to `fns`, one entry per overload.
    fn_annotations: std.StringHashMap(std.ArrayList([]Annotation)),
    prop_annotations: std.StringHashMap([]Annotation),
    annotation_class_names: std.StringHashMap(void),
    enum_class_names: std.StringHashMap(void),
    /// Annotation classes themselves marked `@DslMarker`.
    dsl_marker_annotations: std.StringHashMap(void),
    dsl_class_markers: std.StringHashMap(std.StringHashMap(void)),
    /// Active implicit `this` receivers and their dsl markers.
    dsl_receiver_stack: std.ArrayList(DslReceiver),
    cfgs: std.AutoHashMap(Span, Cfg),
    /// CFG plus side tables, per function.
    lowerings: std.AutoHashMap(Span, *Lowered),
    cfg_fn_stack: std.ArrayList(Span),
    /// Nesting depth of function bodies that declare type parameters.
    ///
    /// Kotlin resolves a generic body once against its type parameters, never
    /// against a call site's instantiation: `plusElement` is `plus(element)`
    /// with `element: T`, matching `plus(element: T)`, but substituting
    /// `T = List<String>` would also admit `plus(elements: Iterable<T>)` and
    /// concatenate. So a type recorded at depth > 0 is excluded from the
    /// eager evidence channel.
    generic_body_depth: usize,
    types_instantiation_dependent: std.AutoHashMap(Span, void),
    inference_session: ?InferenceSession,
    /// Set while typing a call to a `@BuilderInference` callee.
    builder_inference_active: bool,
    /// Inside a lambda a bare call may target a member of a receiver the
    /// checker cannot see, so resolution against same-named top-level
    /// functions stays tolerant when no candidate's arity admits the call.
    lambda_depth: usize,
    /// Explicit-backing-field reads outside their declaring scope, whose
    /// member calls must resolve against the public type.
    ebf_outside: std.AutoHashMap(Span, EbfOutside),
    /// Depth of enclosing non-private `inline` functions, where field
    /// narrowing is off: the spliced body may land outside the scope.
    field_narrow_off: usize,
    /// Per-query CFG-analysis scratch, reset by `narrowing.queryScratch`.
    /// Backed by the page allocator so pages are genuinely returned between
    /// queries even when the driver hands the checker a phase arena.
    query_scratch: *std.heap.ArenaAllocator,

    pub const new = phases.new;
    pub const run = phases.run;

    // Bound here so every per-aspect file calls them as `self.<name>(...)`.
    pub const declareTopLevel = decl.declareTopLevel;
    pub const checkDecl = decl.checkDecl;
    pub const checkExpr = expr.checkExpr;
    pub const checkCall = expr_calls.checkCall;
    pub const checkVisibility = visibility.checkVisibility;
    pub const narrow = narrowing.narrow;
};

/// An implicit `this` class name plus its applied dsl-marker names.
pub const DslReceiver = struct {
    name: []const u8,
    markers: std.StringHashMap(void),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(helpers);
    _ = @import("check/tests.zig");
}
