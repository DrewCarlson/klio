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

/// Sibling files holding the per-aspect free functions over `*Checker`.
const phases = @import("check/phases.zig");
const decl = @import("check/decl.zig");
const expr = @import("check/expr.zig");
const expr_calls = @import("check/expr_calls.zig");
const annotations = @import("check/annotations.zig");
const visibility = @import("check/visibility.zig");
const narrowing = @import("check/narrowing.zig");
pub const context_params = @import("check/context_params.zig");

pub const helpers = @import("check/helpers.zig");

/// Output of the type-checking pass. Every container the checker fills —
/// the `types`/`cfgs` side tables, the diagnostics, and all the scratch the
/// `Checker` holds — is allocated from the single driver-owned arena passed
/// to `typecheck`/`typecheckModule`. The driver frees that arena once the
/// last reader of this output is done, so the result exposes no teardown.
pub const TypeCheck = struct {
    /// Type assigned to each expression by its span. Statements have no
    /// entry. Spans not in this map were either skipped or assigned
    /// `Type.Unresolved`.
    types: std.AutoHashMap(Span, Type),
    diagnostics: DiagnosticSink,
    /// CFGs built during type checking, keyed by the source span of the
    /// owning function. Populated for every function body the checker
    /// visits. Consumers (notably the dataflow analyses in `cfa`)
    /// read this to ground reachability / VIA / smart-cast queries.
    cfgs: std.AutoHashMap(Span, Cfg),
    /// The signature the overload checker CHOSE for each overloaded call,
    /// keyed by call span: the declaring function's name-span (the identity
    /// channel — lowering composes it with its own decl-span -> FuncId map)
    /// plus the compact render ("arity=N;p0=Int;...;ret=T"). The eager half
    /// of the one-engine-two-modes design: recorded once, consumable by
    /// lowering-side audits and typeck-informed evidence.
    resolved_calls: std.AutoHashMap(Span, ResolvedCall),
    lambda_recv_heads: std.AutoHashMap(Span, []const u8),
    lambda_param_shapes: std.AutoHashMap(Span, ParamShape),

    /// Look up the type assigned to an expression by span.
    pub fn typeOf(self: *const TypeCheck, sp: Span) ?*const Type {
        return self.types.getPtr(sp);
    }

    /// The resolution the checker recorded for the call at `sp`.
    pub fn resolvedCallOf(self: *const TypeCheck, sp: Span) ?ResolvedCall {
        return self.resolved_calls.get(sp);
    }
};

/// One recorded overload decision: the chosen declaration's identity and
/// its comparison-stable render.
/// A function-typed parameter's declared shape.
pub const ParamShape = struct { has_receiver: bool, arity: u16 };

pub const ResolvedCall = struct {
    decl_span: ?Span,
    render: []const u8,
};

/// Public entry point. `resolution` is the resolver's output for the same
/// file; the checker reads it but does not mutate it.
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
        .diagnostics = tc.diagnostics,
        .cfgs = tc.cfgs,
        .resolved_calls = tc.resolved_calls,
        .lambda_recv_heads = tc.lambda_recv_heads,
        .lambda_param_shapes = tc.lambda_param_shapes,
    };
}

/// Walk every top-level `inline fun` in `file` and record any
/// `contract { callsInPlace(p, InvocationKind.EXACTLY_ONCE) }`
/// declarations as a map of fn-simple-name -> exactly-once param
/// names. Consumed by `cfa`'s lowering to extend its trailing-lambda
/// inline scheme to user contracts so a `val` assigned inside the
/// lambda is observed as definitely assigned at the call site.
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

/// Multi-file entry point. Synthesizes a merged `KotlinFile` whose decls
/// and imports are the concatenation of every input file's; per-decl
/// `Span.file` is preserved so cross-file visibility checks (T0032)
/// continue to work.
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
        .diagnostics = tc.diagnostics,
        .cfgs = tc.cfgs,
        .resolved_calls = tc.resolved_calls,
        .lambda_recv_heads = tc.lambda_recv_heads,
        .lambda_param_shapes = tc.lambda_param_shapes,
    };
}

/// Return the checker's per-query scratch pages to the OS once the checker
/// is done. The arena's backing is the page allocator, not the driver's
/// phase arena, so this teardown is required even under the
/// driver-owned-arena model.
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

/// Diagnostic codes emitted by the type checker.
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

/// A scope frame mapping local names to their declared/inferred types
/// and mutability. Frames stack lexically. The smart-cast / bound-alias
/// data that used to live here has moved to the CFG; the frame now only
/// holds the binding map.
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
    /// Span of the declaration site for nicer diagnostics.
    decl_span: ?Span,
    /// User-class name when the binding's declared/inferred type refers to a
    /// user class (not a builtin / function type). Used by sealed-`when`
    /// exhaustiveness, member-access lookup, and smart-cast widening of
    /// `val` properties.
    class_name: ?[]const u8,
    /// Original declared-type name when the binding was annotated with a
    /// bare identifier (e.g. `t: T` for a type parameter). Lets
    /// runtime-availability checks recover the spelling that
    /// `convertTypeRefLossy` collapsed to `Type.Unresolved`.
    decl_type_name: ?[]const u8,
    /// Set for a top-level property with an explicit backing field: `ty`
    /// above is the (narrowed) field type; this carries the public view.
    /// Reads outside the declaring file — or where narrowing is switched
    /// off — see the public type instead.
    ebf: ?EbfBinding = null,
};

/// Public view of a top-level explicit-backing-field property (the frame
/// binding itself holds the narrowed field type).
pub const EbfBinding = struct {
    public_ty: Type,
    public_class: ?[]const u8,
    /// Rendered public type for diagnostics (`List<Int>`).
    public_display: []const u8,
    /// File the property is declared in — narrowing is file-scoped.
    file: FileId,
};

/// Per-member record of an explicit backing field: the narrowed (field)
/// type served to reads inside the declaring class's scope. The `members`
/// map keeps the public (property) type.
pub const EbfMember = struct {
    field_ty: Type,
    field_class: ?[]const u8,
    /// Rendered public (property) type for diagnostics.
    public_display: []const u8,
};

/// Recorded at a property-read site that resolved OUTSIDE the declaring
/// scope of an explicit-backing-field property: member calls on that read
/// must resolve against the public type.
pub const EbfOutside = struct {
    /// Head class/interface name of the public type (`List`, user class).
    head: ?[]const u8,
    /// Rendered public type for diagnostics (`List<String>`).
    display: []const u8,
};

/// One extension declaration on a given receiver type.
pub const ExtensionSig = struct {
    name: []const u8,
    sig: FnSig,
    /// User-class name of the declared return type, when applicable.
    /// Drives `expr_class` propagation for `recv.ext()` chains the same
    /// way `ClassInfo.member_class` does for regular members.
    return_class: ?[]const u8,
};

/// One extension-property declaration on a given receiver type.
pub const ExtensionPropSig = struct {
    name: []const u8,
    ty: Type,
    mutable: bool,
    return_class: ?[]const u8,
};

/// Description of a user-declared function, used to check call sites
/// when the callee resolves to a top-level function or a member.
pub const FnSig = struct {
    /// Parameter declared types in source order.
    params: []Type,
    /// True for each parameter that has a default value.
    has_default: []bool,
    /// Names of each parameter (for named-arg calls).
    param_names: [][]const u8,
    /// True for each parameter declared `vararg`.
    is_vararg: []bool,
    return_ty: Type,
    /// True when the source declared the function with the `infix` modifier.
    is_infix: bool,
    /// Number of declaration-site type parameters. Used to filter the OCS
    /// against an explicit call-site `<...>` list.
    type_param_count: usize,
    /// Names of the declaration-site type parameters in order, matching
    /// `type_param_count`.
    type_param_names: [][]const u8,
    /// Per-type-parameter upper bounds. Each inner slice is the bound list
    /// for the corresponding type parameter, in declaration order.
    type_param_bounds: [][]Type,
    /// User-class simple name for each parameter whose declared type names
    /// a known class. `null` for primitive / function / unresolved slots.
    param_class_names: []?[]const u8,
    /// Declaration-name span. `null` for synthetic / constructor sigs.
    decl_span: ?Span,
    /// True when declared with the `suspend` modifier.
    is_suspend: bool,
    /// Declared with an extension receiver (`fun T.f()`): a bare call to
    /// it inside a receiver scope competes with candidates typeck's flat
    /// name registry cannot see, so its pick never enters the eager channel.
    is_extension: bool = false,
    /// True when the function is declared `inline` and the parameter at the
    /// same index is marked `crossinline`.
    is_crossinline_param: []bool,
    /// Declared context-parameter type names, in order. Two overloads whose
    /// context type-sets differ are NOT conflicting (they are shadowed
    /// contextual overloads instead).
    context_types: []const []const u8 = &.{},
};

/// Detailed per-member signature used by override-rule diagnostics
/// (T0065 / T0066 / T0067 / T0068). Stored separately from `MemberFlags`
/// so existing name-keyed override walks keep their semantics.
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
    /// True when a `fun` member carried the `operator` modifier.
    is_operator: bool = false,
    /// True when a `fun` member carried the `infix` modifier.
    is_infix: bool = false,
    /// True when a `fun` member declares an actual body (default impl).
    has_default_body: bool = false,
};

/// A typed-supertype entry: a supertype name paired with its type-arg list.
pub const TypedSupertype = struct {
    name: []const u8,
    args: []Type,
};

/// Description of a user-declared class.
/// Register a class under its simple name, recording a collision instead of
/// overwriting. See `ambiguous_class_names`.
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

/// The class registered under `name`, or null when the simple name is
/// ambiguous across packages.
pub fn classNamed(self: anytype, name: []const u8) ?ClassInfo {
    if (self.ambiguous_class_names.contains(name)) return null;
    return self.classes.get(name);
}

pub const ClassInfo = struct {
    /// Has any secondary constructor — we then relax primary-ctor arity
    /// checks to avoid false positives.
    has_secondary_ctors: bool = false,
    /// Member name -> type. Covers primary-param properties, body
    /// properties, and methods (as `Type.Function`).
    members: std.StringHashMap(Type),
    /// Member method name -> every declared overload's signature. The
    /// `members` map collapses overloads to one entry; call-site overload
    /// selection reads this instead.
    member_methods: std.StringHashMap(std.ArrayList(FnSig)),
    /// Member name -> mutable? (only for properties).
    member_mutable: std.StringHashMap(bool),
    /// Constructor parameter list (primary). Used to type-check `Box(...)`.
    ctor: ?FnSig = null,
    /// Names of declared abstract members on this class.
    abstract_members: std.ArrayList([]const u8) = .empty,
    /// Names of declared concrete members on this class.
    concrete_members: std.ArrayList([]const u8) = .empty,
    /// Per-member modifier flags. Drives T0009/T0010/T0011.
    member_flags: std.StringHashMap(MemberFlags),
    /// Per-member detailed signature used by T0065 / T0066 / T0067 / T0068.
    member_sigs: std.StringHashMap(MemberSig),
    /// Member name -> user-class name when the member's declared type
    /// names a user class.
    member_class: std.StringHashMap([]const u8),
    /// Member name -> explicit-backing-field record. Present only for
    /// properties declared with a `field` clause.
    member_ebf: std.StringHashMap(EbfMember),
    /// Names of supertypes (raw — interfaces or classes).
    supertypes: std.ArrayList([]const u8) = .empty,
    /// Typed supertypes paired with type-arg lists, in declaration order.
    typed_supertypes: std.ArrayList(TypedSupertype) = .empty,
    /// Type parameter names declared on this class.
    type_param_names: std.ArrayList([]const u8) = .empty,
    is_abstract: bool = false,
    is_interface: bool = false,
    is_sealed: bool = false,
    is_open: bool = false,
    /// `object` singleton.
    is_object: bool = false,
    /// `enum class` flag.
    is_enum: bool = false,
    /// Declared inside a function body (local class) or via `object { … }`.
    is_local_or_anonymous: bool = false,
    /// Member name -> effective visibility for access checks.
    member_visibility: std.StringHashMap(Visibility),
    /// Visibility of the class itself.
    decl_visibility: Visibility = .Public,
    /// File the class is declared in.
    decl_file: ?FileId = null,
    /// Visibility of the primary constructor when it diverges from the class.
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

/// Visibility + declaring file of one declaration overload.
pub const VisFile = struct {
    visibility: Visibility,
    file: FileId,
};

/// Shared constraint system threaded through every generic call in a
/// single source-level expression.
pub const InferenceSession = struct {
    cs: types.constraints.ConstraintSystem,
    /// True when a nested call is currently using the session.
    depth: u32,
};

/// Description of a user-declared `typealias`.
pub const TypeAliasInfo = struct {
    /// Declared type-parameter names in source order.
    type_params: [][]const u8,
    /// Right-hand-side `TypeRef` — the alias target.
    target: TypeRef,
    /// Span of the alias's name for cycle-diagnostic labeling.
    name_span: Span,
};

/// Memoized per-function reachability solves, keyed by function span.
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
    /// Chosen-overload record per call span (see TypeCheck.resolved_calls).
    resolved_calls: std.AutoHashMap(Span, ResolvedCall),
    /// Receiver-lambda bodies keyed by their BLOCK span -> the receiver
    /// class head typeck bound `this` to. The eager channel that lets
    /// lowering answer member-vs-global precisely inside lambda bodies.
    lambda_recv_heads: std.AutoHashMap(Span, []const u8),
    /// Function-typed lambda PARAMS keyed by the param ident's span: the
    /// declared shape (receiver-ness + arity) for params the AST leaves
    /// unannotated (`{ f -> f(x) }` against an expected function type).
    lambda_param_shapes: std.AutoHashMap(Span, ParamShape),
    /// Spans whose recorded type is `Nothing`, maintained alongside `types`.
    /// The reachability queries only need to know where control diverges,
    /// so they consult this small set instead of walking the full map.
    nothing_spans: std.AutoHashMap(Span, void),
    /// Candidate `Nothing` spans bucketed by the function context
    /// (`cfg_fn_stack` top) active when they were recorded. The
    /// reachability queries over a function's CFG read just its bucket,
    /// filtered through `nothing_spans` for current membership.
    nothing_by_fn: std.AutoHashMap(Span, std.AutoHashMap(Span, void)),
    /// Bumped whenever `nothing_spans` changes. Reachability over a lowered
    /// CFG depends only on the CFG and this set, so the per-statement
    /// unreachable-code query caches its last solve against this epoch.
    nothing_epoch: u64,
    /// Cached reachability solve for the W0002 per-statement query: valid
    /// while the queried function and `nothing_epoch` both match.
    reach_cache: ReachCache,
    /// User-class name attached to an expression by span — populated for
    /// path / `this` / constructor-call sites whose static type is a
    /// user-declared class.
    expr_class: std.AutoHashMap(Span, []const u8),
    /// Inferred element type for an expression whose runtime value is a
    /// `List<T>`.
    list_elem: std.AutoHashMap(Span, Type),
    diagnostics: DiagnosticSink,
    frames: std.ArrayList(Frame),
    /// Top-level user functions keyed by simple name. A name maps to a list
    /// of signatures so positional overloads can be picked at call sites.
    fns: std.StringHashMap(std.ArrayList(FnSig)),
    /// Declaring package per source file (FileId.int() -> dotted package),
    /// populated by the multi-file entry point. Two same-name signatures
    /// from different packages are not an overload pair (kotlinc's
    /// conflicting-overloads check is per package).
    file_packages: std.AutoHashMap(u32, []const u8),
    /// User-declared extension functions keyed by the receiver type's simple
    /// name.
    extensions: std.StringHashMap(std.ArrayList(ExtensionSig)),
    /// Extension properties keyed by simple receiver-type name.
    extension_properties: std.StringHashMap(std.ArrayList(ExtensionPropSig)),
    /// File-level user classes.
    classes: std.StringHashMap(ClassInfo),
    /// Simple names declared by MORE THAN ONE class. `classes` is keyed by
    /// simple name, so two same-named classes in different packages would
    /// otherwise silently overwrite each other and every lookup would answer
    /// with whichever registered last. A wrong answer is worse than none —
    /// it feeds the eager evidence channel and can disprove valid candidates
    /// downstream — so an ambiguous name answers nothing until typeck
    /// resolves classes per package.
    ambiguous_class_names: std.StringHashMap(void),
    /// Name of the enclosing class while we type-check a class body.
    class_stack: std.ArrayList([]const u8),
    /// Enclosing function's declared/inferred return type for `return`.
    fn_return_stack: std.ArrayList(Type),
    /// Lexically active jump labels bound by enclosing loops or `Labeled`.
    label_stack: std.ArrayList([]const u8),
    /// Visibility + declaring file for each top-level function name.
    fn_visibility: std.StringHashMap(std.ArrayList(VisFile)),
    /// Visibility + declaring file for each top-level property.
    prop_visibility: std.StringHashMap(VisFile),
    /// Per-setter visibility for top-level `var` properties whose setter is
    /// more restrictive than the property itself.
    setter_visibility: std.StringHashMap(VisFile),
    /// Top-level type aliases keyed by simple name.
    aliases: std.StringHashMap(TypeAliasInfo),
    /// Stack of "is the enclosing function `public inline`?" flags.
    public_inline_stack: std.ArrayList(bool),
    /// Stack tracking whether each enclosing function / lambda is a
    /// suspending context.
    suspend_context_stack: std.ArrayList(bool),
    /// Stack of reified type-parameter name sets for each enclosing function.
    reified_type_params: std.ArrayList(std.StringHashMap(void)),
    /// Stack of all type-parameter names in scope for each enclosing
    /// function / class.
    type_params_in_scope: std.ArrayList(std.StringHashMap(void)),
    /// Annotations of each top-level function overload, parallel to `fns`.
    fn_annotations: std.StringHashMap(std.ArrayList([]Annotation)),
    /// Annotations of each top-level property by simple name.
    prop_annotations: std.StringHashMap([]Annotation),
    /// File-level set of `annotation class` simple names.
    annotation_class_names: std.StringHashMap(void),
    /// File-level set of `enum class` simple names.
    enum_class_names: std.StringHashMap(void),
    /// Annotation-class names that are themselves marked `@DslMarker`.
    dsl_marker_annotations: std.StringHashMap(void),
    /// Class name -> set of dsl-marker annotation names applied to that class.
    dsl_class_markers: std.StringHashMap(std.StringHashMap(void)),
    /// Stack of currently-active implicit `this` receivers and their dsl
    /// markers.
    dsl_receiver_stack: std.ArrayList(DslReceiver),
    /// CFGs built during type checking, keyed by owning function span.
    cfgs: std.AutoHashMap(Span, Cfg),
    /// Full lowering output per function: CFG + side tables.
    lowerings: std.AutoHashMap(Span, *Lowered),
    /// Stack of currently-active function spans.
    cfg_fn_stack: std.ArrayList(Span),
    /// Active multi-call inference session, if any.
    inference_session: ?InferenceSession,
    /// Set while typing a call whose callee is annotated `@BuilderInference`.
    builder_inference_active: bool,
    /// Number of lambda bodies currently being checked. Inside a lambda a
    /// bare call may target a member of a receiver the checker cannot see
    /// (user DSL builders), so resolution against same-named top-level
    /// functions stays tolerant when no candidate's arity admits the call.
    lambda_depth: usize,
    /// Property-read sites of explicit-backing-field properties resolved
    /// outside their declaring scope, keyed by the read expression's span.
    /// Member calls on such a receiver must resolve against the public
    /// (property) type.
    ebf_outside: std.AutoHashMap(Span, EbfOutside),
    /// Depth of enclosing non-private `inline` functions. Explicit-
    /// backing-field narrowing is switched off inside them: the inlined
    /// body may land outside the declaring scope.
    field_narrow_off: usize,
    /// Retained arena for per-query CFG-analysis scratch (smart-cast / VIA /
    /// reachability solves). Reset at the start of each query via
    /// `narrowing.queryScratch`; torn down by the typecheck entry points once
    /// the checker is done. Backed by the page allocator so its pages are
    /// genuinely returned between queries even when the driver hands the
    /// checker a phase arena.
    query_scratch: *std.heap.ArenaAllocator,

    pub const new = phases.new;
    pub const run = phases.run;

    // Phase driver hooks. Sibling files supply the bodies; the root binds
    // them as methods so every per-aspect file calls them uniformly through
    // `self.<name>(...)`.
    pub const declareTopLevel = decl.declareTopLevel;
    pub const checkDecl = decl.checkDecl;
    pub const checkExpr = expr.checkExpr;
    pub const checkCall = expr_calls.checkCall;
    pub const checkVisibility = visibility.checkVisibility;
    pub const narrow = narrowing.narrow;
};

/// A dsl-receiver-stack entry: an implicit `this` class name plus its set
/// of applied dsl-marker annotation names.
pub const DslReceiver = struct {
    name: []const u8,
    markers: std.StringHashMap(void),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(helpers);
    _ = @import("check/tests.zig");
}
