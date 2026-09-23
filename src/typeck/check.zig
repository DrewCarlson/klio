//! Tolerant static type checker.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const resolver = @import("resolver");
pub const types = @import("types");
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
pub const expr = @import("check/expr.zig");
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
    /// A plain user class types as `Type.unresolved`, so a receiver's class
    /// identity lives here instead.
    expr_class: std.AutoHashMap(Span, []const u8),
    /// Ranking only. Separate from `expr_class`, which lowering reads as type
    /// evidence: a head good enough to rank is not one lowering can bind.
    rank_class: std.AutoHashMap(Span, []const u8),
    /// What the body pass's workers allocated: the results above point into
    /// these, so they live as long as the result does.
    worker_arenas: []*std.heap.ArenaAllocator = &.{},
    /// The workers' query scratch and solve memo arenas, kept whole so the
    /// result frees them with the rest.
    worker_scratch: []std.heap.ArenaAllocator = &.{},

    /// Frees the workers' memory. Everything else was allocated from the
    /// allocator the check ran on; a caller that gave it an arena frees the
    /// rest by dropping that.
    pub fn deinit(self: *TypeCheck, allocator: Allocator) void {
        for (self.worker_arenas) |arena| {
            arena.deinit();
            allocator.destroy(arena);
        }
        allocator.free(self.worker_arenas);
        self.worker_arenas = &.{};
        for (self.worker_scratch) |*arena| arena.deinit();
        allocator.free(self.worker_scratch);
        self.worker_scratch = &.{};
    }

    /// Moves every worker arena out, on a page-allocator slice the caller
    /// frees with them, so their teardown can run off the critical path;
    /// `deinit` then has none left to free.
    pub fn takeArenas(self: *TypeCheck, allocator: Allocator) ?[]std.heap.ArenaAllocator {
        const n = self.worker_arenas.len + self.worker_scratch.len;
        const out = std.heap.page_allocator.alloc(std.heap.ArenaAllocator, n) catch return null;
        var i: usize = 0;
        for (self.worker_arenas) |arena| {
            out[i] = arena.*;
            i += 1;
            allocator.destroy(arena);
        }
        for (self.worker_scratch) |arena| {
            out[i] = arena;
            i += 1;
        }
        allocator.free(self.worker_arenas);
        self.worker_arenas = &.{};
        allocator.free(self.worker_scratch);
        self.worker_scratch = &.{};
        return out;
    }

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
    defer destroySolveMemo(allocator, tc.solve_memo);
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
        .worker_arenas = try tc.worker_arenas.toOwnedSlice(allocator),
        .worker_scratch = try tc.worker_scratch.toOwnedSlice(allocator),
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
pub const ModuleOptions = struct {
    /// Threads for the body pass. Each worker allocates from an arena of its
    /// own, so `allocator` need not be thread-safe.
    body_threads: usize = 1,
    /// False skips the declaration-level diagnostic passes and merges from the
    /// workers only what a reader of the call resolutions and types needs; the
    /// stage that records a base's eager call picks reads nothing else.
    diagnostics: bool = true,
};

pub fn typecheckModule(
    allocator: Allocator,
    files: []const KotlinFile,
    resolution: *const Resolution,
) Allocator.Error!TypeCheck {
    return typecheckModuleOpts(allocator, files, resolution, .{});
}

/// Wall time of the last body check's phases, for the stage trace of a bake.
pub const StageTiming = struct { serial_ns: u64 = 0, pool_ns: u64 = 0, merge_ns: u64 = 0, threads: usize = 0 };
pub var stage_timing: StageTiming = .{};

pub fn typecheckModuleOpts(
    allocator: Allocator,
    files: []const KotlinFile,
    resolution: *const Resolution,
    opts: ModuleOptions,
) Allocator.Error!TypeCheck {
    const merged = try mergeModuleFiles(allocator, files);
    const user_contracts = try scanUserInlineContracts(allocator, &merged);
    cfa.analyses.contracts.setUserInlineContracts(user_contracts);
    var tc = try Checker.new(allocator, resolution);
    tc.body_threads = opts.body_threads;
    tc.report_diagnostics = opts.diagnostics;
    stage_timing = .{};
    defer destroyQueryScratch(allocator, tc.query_scratch);
    defer destroySolveMemo(allocator, tc.solve_memo);
    if (types.pending_extern_decls) |ed| {
        var cit = ed.classes.iterator();
        const trace_class = std.c.getenv("KLIO_EXTERN_TRACE");
        while (cit.next()) |e| {
            if (tc.classes.contains(e.key_ptr.*)) continue;
            const info = try externClassInfo(allocator, e.value_ptr);
            if (trace_class) |tcn| {
                if (std.mem.eql(u8, std.mem.span(tcn), e.key_ptr.*)) {
                    std.debug.print("[extern-class] {s} tparams={d} supers={d} props={d} methods={d}\n", .{ e.key_ptr.*, info.type_param_names.items.len, info.typed_supertypes.items.len, e.value_ptr.props.len, e.value_ptr.methods.len });
                    for (info.typed_supertypes.items) |st| {
                        std.debug.print("[extern-class]   super {s} args={d}", .{ st.name, st.args.len });
                        for (st.args) |*a| std.debug.print(" {f}", .{a.*});
                        std.debug.print("\n", .{});
                    }
                    var mit = info.members.iterator();
                    while (mit.next()) |me| std.debug.print("[extern-class]   member {s}: {f}\n", .{ me.key_ptr.*, me.value_ptr.* });
                }
            }
            try tc.classes.put(e.key_ptr.*, info);
        }
        tc.extern_fn_return_class = ed.fn_return_class;
        // Without these a member call on an image type finds no candidates.
        if (ed.has_extensions) {
            var eit = ed.extensions.iterator();
            while (eit.next()) |entry| {
                const gop = try tc.extensions.getOrPut(entry.key_ptr.*);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                for (entry.value_ptr.items) |*x| {
                    const sig = try externFnSig(allocator, x, &.{});
                    try gop.value_ptr.append(allocator, .{
                        .name = x.name,
                        .sig = sig,
                        .return_class = sig.return_class,
                    });
                }
            }
        }
        // Top-level functions, so `listOf(1, 2)` types as `List<Int>` and a
        // bare call's pick can name its image declaration.
        if (ed.has_extensions and !types.tcOff("TOPFN")) {
            var tit = ed.top_level.iterator();
            while (tit.next()) |entry| {
                for (entry.value_ptr.items) |*x| {
                    var sig = try externFnSig(allocator, x, &.{});
                    // The image's top-level functions type a call; which one a
                    // bare name binds is decided by the caller's package and
                    // imports, which lowering holds and this table does not.
                    sig.extern_fid = null;
                    try decl.pushFnSig(&tc, entry.key_ptr.*, sig, false);
                }
            }
        }
        if (ed.package_roots) |pr| {
            var rit = pr.keyIterator();
            while (rit.next()) |k| try tc.package_roots.put(k.*, {});
        }
        types.pending_extern_decls = null;
    }
    for (files) |*f| {
        for (f.imports) |*imp| {
            if (imp.path.len != 0) try tc.package_roots.put(imp.path[0].name, {});
        }
        const pkg = f.package orelse continue;
        if (pkg.path.len != 0) try tc.package_roots.put(pkg.path[0].name, {});
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
        .worker_arenas = try tc.worker_arenas.toOwnedSlice(allocator),
        .worker_scratch = try tc.worker_scratch.toOwnedSlice(allocator),
    };
}

/// Backed by the page allocator, not the driver's phase arena, so this
/// teardown is required even though everything else rides that arena.
/// Replaces the inline-contracts registry a check left behind with an empty
/// one on `allocator`: a caller that ran the check on an arena drops that
/// arena, and the registry must not keep pointing into it.
pub fn resetUserInlineContracts(allocator: Allocator) void {
    cfa.analyses.contracts.setUserInlineContracts(cfa.analyses.contracts.UserInlineContracts.init(allocator));
}

fn destroyQueryScratch(allocator: Allocator, scratch: *std.heap.ArenaAllocator) void {
    scratch.deinit();
    allocator.destroy(scratch);
}

fn destroySolveMemo(allocator: Allocator, memo: *narrowing.SolveMemo) void {
    memo.arena.deinit();
    allocator.destroy(memo);
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
    /// collapsed to `Type.unresolved`, for runtime-availability checks.
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
/// The simple name of an image head: the last segment of a qualified one.
fn externSimpleName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "out#")) n = n[4..];
    if (std.mem.startsWith(u8, n, "in#")) n = n[3..];
    if (std.mem.findScalarLast(u8, n, '.')) |d| n = n[d + 1 ..];
    return n;
}

/// A class-owned type parameter is spelled by identity in a member's
/// signature (`$class$<owner><len>:<name>`); the name is its tail.
fn classOwnedParamName(name: []const u8) ?[]const u8 {
    const prefix = "$class$\x00";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const sep = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    const after = rest[sep + 1 ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    return after[colon + 1 ..];
}

/// A `#suspend`, `#non-null` or `#qual:` argument is a flag, not a type.
fn externIsMarker(t: *const types.ExternType) bool {
    return t.name.len != 0 and t.name[0] == '#';
}

/// The checker's type for an image type. Type-parameter names in `tparams`
/// become `TypeParam`; a parameterised head becomes `Generic`; a
/// `Function<N>` head becomes the function type it spells; anything else
/// the checker does not model is `Unresolved` carrying its simple name.
fn externType(allocator: Allocator, t: *const types.ExternType, tparams: *const std.StringHashMap(void)) Allocator.Error!Type {
    if (std.mem.eql(u8, t.name, "*")) return .Any;
    const simple = classOwnedParamName(t.name) orelse externSimpleName(t.name);
    var is_suspend = false;
    var real: usize = 0;
    for (t.args) |*a| {
        if (externIsMarker(a)) {
            if (std.mem.eql(u8, a.name, "#suspend")) is_suspend = true;
        } else real += 1;
    }
    const base: Type = blk: {
        if (std.mem.startsWith(u8, simple, "Function") and simple.len > "Function".len) arity: {
            const n = std.fmt.parseInt(usize, simple["Function".len..], 10) catch break :arity;
            if (real < n + 1) break :arity;
            const has_receiver = real == n + 2;
            const params = try allocator.alloc(Type, n);
            var receiver_head: ?[]const u8 = null;
            var ret: Type = Type.unresolved;
            var idx: usize = 0;
            for (t.args) |*a| {
                if (externIsMarker(a)) continue;
                if (has_receiver and idx == 0) {
                    receiver_head = externSimpleName(a.name);
                } else if (idx < real - 1) {
                    params[idx - @intFromBool(has_receiver)] = try externType(allocator, a, tparams);
                } else {
                    ret = try externType(allocator, a, tparams);
                }
                idx += 1;
            }
            const boxed = try allocator.create(Type);
            boxed.* = ret;
            break :blk .{ .Function = .{ .params = params, .return_type = boxed, .is_suspend = is_suspend, .receiver_head = receiver_head } };
        }
        if (types.builtinByName(simple)) |b| {
            if (real == 0) break :blk b;
        }
        if (real == 0 and tparams.contains(simple)) break :blk .{ .TypeParam = try allocator.dupe(u8, simple) };
        if (real != 0) {
            const args = try allocator.alloc(GenericArg, real);
            var i: usize = 0;
            for (t.args) |*a| {
                if (externIsMarker(a)) continue;
                args[i] = try externArg(allocator, a, tparams);
                i += 1;
            }
            break :blk .{ .Generic = .{ .name = try allocator.dupe(u8, simple), .args = args } };
        }
        break :blk .{ .Unresolved = simple };
    };
    return if (t.nullable) try base.asNullable(allocator) else base;
}

fn externArg(allocator: Allocator, t: *const types.ExternType, tparams: *const std.StringHashMap(void)) Allocator.Error!GenericArg {
    if (std.mem.eql(u8, t.name, "*")) return .{ .variance = .Invariant, .is_star = true, .ty = .Any };
    const variance: types.Variance = if (std.mem.startsWith(u8, t.name, "out#")) .Out else if (std.mem.startsWith(u8, t.name, "in#")) .In else .Invariant;
    return .{ .variance = variance, .is_star = false, .ty = try externType(allocator, t, tparams) };
}

/// An image declaration's `FnSig`. `outer_tparams` are the declaring class's
/// type parameters.
fn externFnSig(allocator: Allocator, ef: *const types.ExternFn, outer_tparams: []const []const u8) Allocator.Error!FnSig {
    var tparams = std.StringHashMap(void).init(allocator);
    defer tparams.deinit();
    for (outer_tparams) |n| try tparams.put(n, {});
    for (ef.type_params) |n| try tparams.put(n, {});
    const n = ef.params.len;
    const params = try allocator.alloc(Type, n);
    for (ef.params, params) |*p, *dst| dst.* = try externType(allocator, p, &tparams);
    const has_default = try allocator.alloc(bool, n);
    if (ef.param_defaults.len == n) @memcpy(has_default, ef.param_defaults) else @memset(has_default, false);
    const pnames = try allocator.alloc([]const u8, n);
    if (ef.param_names.len == n) @memcpy(pnames, ef.param_names) else @memset(pnames, "");
    const varargs = try allocator.alloc(bool, n);
    @memset(varargs, false);
    if (ef.has_vararg and n != 0) varargs[n - 1] = true;
    const crossinline = try allocator.alloc(bool, n);
    @memset(crossinline, false);
    const pclasses = try allocator.alloc(?[]const u8, n);
    for (params, pclasses) |*p, *pc| pc.* = helpers.classNameOfType(p);
    const return_ty: Type = if (ef.return_ty) |*rt| try externType(allocator, rt, &tparams) else Type.unresolved;
    const bounds = try allocator.alloc([]Type, ef.type_params.len);
    for (bounds) |*b| b.* = &.{};
    return .{
        .params = params,
        .has_default = has_default,
        .param_names = pnames,
        .is_vararg = varargs,
        .return_ty = return_ty,
        .is_infix = false,
        .type_param_count = ef.type_params.len,
        .type_param_names = @constCast(ef.type_params),
        .type_param_bounds = bounds,
        .param_class_names = pclasses,
        .return_class = helpers.classNameOfType(&return_ty),
        .decl_span = null,
        .is_suspend = ef.is_suspend,
        .is_extension = ef.receiver != null,
        .receiver_ty = if (ef.receiver) |*r| try externType(allocator, r, &tparams) else null,
        .is_crossinline_param = crossinline,
        .extern_fid = ef.fid,
    };
}

/// An image class as the checker's `ClassInfo`: its parameters, typed
/// supertypes, properties, methods and primary constructor.
fn externClassInfo(allocator: Allocator, ec: *const types.ExternClass) Allocator.Error!ClassInfo {
    var info = ClassInfo.init(allocator);
    if (types.tcOff("EXTERN")) {
        for (ec.supertypes) |*st| try info.supertypes.append(allocator, externSimpleName(st.name));
        return info;
    }
    info.is_interface = ec.is_interface;
    info.is_abstract = ec.is_abstract;
    info.is_open = ec.is_open or ec.is_abstract or ec.is_interface;
    info.is_enum = ec.is_enum;
    info.has_secondary_ctors = ec.has_secondary_ctors;
    var ctp = std.StringHashMap(void).init(allocator);
    defer ctp.deinit();
    for (ec.type_params) |n| {
        try info.type_param_names.append(allocator, n);
        try ctp.put(n, {});
    }
    for (ec.supertypes) |*st| {
        const simple = externSimpleName(st.name);
        try info.supertypes.append(allocator, simple);
        var real: usize = 0;
        for (st.args) |*a| {
            if (!externIsMarker(a)) real += 1;
        }
        const targs = try allocator.alloc(Type, real);
        var i: usize = 0;
        for (st.args) |*a| {
            if (externIsMarker(a)) continue;
            targs[i] = if (std.mem.eql(u8, a.name, "*")) Type.unresolved else try externType(allocator, a, &ctp);
            i += 1;
        }
        try info.typed_supertypes.append(allocator, .{ .name = simple, .args = targs });
    }
    const implicit_open = ec.is_interface or ec.is_abstract;
    for (ec.props) |*p| {
        const ty: Type = if (p.ty) |*t| try externType(allocator, t, &ctp) else Type.unresolved;
        try info.members.put(p.name, ty);
        try info.member_mutable.put(p.name, false);
        try info.member_sigs.put(p.name, .{ .Property = .{ .ty = try ty.clone(allocator), .mutable = false, .visibility = .Public } });
        if (ty != .TypeParam) if (helpers.classNameOfType(&ty)) |cn| try info.member_class.put(p.name, cn);
        try info.member_visibility.put(p.name, .Public);
        try info.member_flags.put(p.name, .{
            .is_open = implicit_open,
            .is_override = false,
            .is_abstract = p.is_abstract,
            .is_operator = false,
            .is_infix = false,
            .has_default_body = false,
        });
        if (p.is_abstract) try info.abstract_members.append(allocator, p.name) else try info.concrete_members.append(allocator, p.name);
    }
    for (ec.methods) |*ef| {
        const sig = try externFnSig(allocator, ef, ec.type_params);
        {
            const gop = try info.member_methods.getOrPut(ef.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, sig);
        }
        const param_types = try allocator.alloc(Type, sig.params.len);
        for (sig.params, param_types) |*p, *dst| dst.* = try p.clone(allocator);
        try info.member_sigs.put(ef.name, .{ .Function = .{
            .param_types = param_types,
            .return_ty = try sig.return_ty.clone(allocator),
            .visibility = .Public,
            .is_suspend = ef.is_suspend,
        } });
        const ret = try allocator.create(Type);
        ret.* = try sig.return_ty.clone(allocator);
        const fn_params = try allocator.alloc(Type, sig.params.len);
        for (sig.params, fn_params) |*p, *dst| dst.* = try p.clone(allocator);
        try info.members.put(ef.name, .{ .Function = .{ .params = fn_params, .return_type = ret, .is_suspend = ef.is_suspend } });
        if (sig.return_class) |cn| try info.member_class.put(ef.name, cn);
        try info.member_flags.put(ef.name, .{
            .is_open = implicit_open or !ef.has_body,
            .is_override = false,
            .is_abstract = !ef.has_body and implicit_open,
            .is_operator = false,
            .is_infix = false,
            .has_default_body = ef.has_body,
        });
        if (ef.has_body) try info.concrete_members.append(allocator, ef.name) else try info.abstract_members.append(allocator, ef.name);
        try info.member_visibility.put(ef.name, .Public);
    }
    if (ec.ctor) |*ctor| {
        info.ctor = try externCtorSig(allocator, ec, ctor);
        if (ec.secondary_ctors.len != 0) try info.ctors.append(allocator, info.ctor.?);
    }
    for (ec.secondary_ctors) |*sc| {
        try info.ctors.append(allocator, try externCtorSig(allocator, ec, sc));
    }
    return info;
}

/// A constructor's signature returns the class, instantiated by its own
/// type parameters.
fn externCtorSig(allocator: Allocator, ec: *const types.ExternClass, ctor: *const types.ExternFn) Allocator.Error!FnSig {
    var sig = try externFnSig(allocator, ctor, &.{});
    sig.return_ty = try classInstanceType(allocator, ec.name, ec.type_params);
    sig.return_class = ec.name;
    sig.type_param_count = ec.type_params.len;
    sig.type_param_names = @constCast(ec.type_params);
    const bounds = try allocator.alloc([]Type, ec.type_params.len);
    for (bounds) |*b| b.* = &.{};
    sig.type_param_bounds = bounds;
    return sig;
}

/// `Box<T>` for a generic class, the bare class otherwise.
pub fn classInstanceType(allocator: Allocator, name: []const u8, type_params: []const []const u8) Allocator.Error!Type {
    if (type_params.len == 0) return .{ .Unresolved = name };
    const targs = try allocator.alloc(GenericArg, type_params.len);
    for (type_params, targs) |n, *dst| dst.* = .{ .variance = .Invariant, .is_star = false, .ty = .{ .TypeParam = try allocator.dupe(u8, n) } };
    return .{ .Generic = .{ .name = try allocator.dupe(u8, name), .args = targs } };
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
    /// A plain user class types as `Type.unresolved`, so return-class identity
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
    /// Declared extension receiver, with the function's own type parameters
    /// as `TypeParam`: the receiver a call is made on binds them.
    receiver_ty: ?Type = null,
    is_crossinline_param: []bool,
    /// Two overloads whose context type-sets differ are shadowed contextual
    /// overloads, not conflicting ones.
    context_types: []const []const u8 = &.{},
    /// `@LowPriorityInOverloadResolution` or `@Deprecated(level = ERROR|HIDDEN)`:
    /// kotlinc keeps such a declaration out of the candidate set while any
    /// ordinary overload applies.
    low_priority: bool = false,
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
        // An `expect` and its `actual` are one class. The actual carries
        // the bodies; where it declares no members of its own the expect's
        // member surface stands in, so keep whichever declares more.
        if (!same and (existing.is_expect != info.is_expect)) {
            const keep_existing = if (existing.is_expect)
                info.members.count() == 0 and info.member_methods.count() == 0
            else
                true;
            if (keep_existing) return;
            try self.classes.put(name, info);
            return;
        }
        if (!same) {
            try self.ambiguous_class_names.put(name, {});
        }
    }
    try self.classes.put(name, info);
}

/// Null when the simple name is ambiguous across packages.
/// Whether `first` can head a package-qualified path: the root of a package
/// some checked file, one of its imports, or the image declares in.
pub fn packageRoot(self: *const Checker, first: []const u8) bool {
    if (types.tcOff("PKGROOT")) return true;
    return self.package_roots.contains(first);
}

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
    /// Every constructor, primary first, when the class declares more than
    /// the primary one; a construction then selects among them.
    ctors: std.ArrayList(FnSig) = .empty,
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
    /// An `expect` declaration: its `actual` is the same class, not a
    /// namesake competing for the simple name.
    is_expect: bool = false,
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
    /// A body worker's view of the top-level bindings: the seed the main
    /// checker holds, read through this pointer instead of cloned per worker.
    /// Frame 0 of such a worker is empty, and every lookup that reaches it
    /// consults this map. Null on the main checker.
    shared_globals: ?*const std.StringHashMap(Binding) = null,
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
    /// The first segment of every package a checked file, its imports or the
    /// image declares. A qualified path whose head is not one of these names
    /// a value in scope, never a package.
    package_roots: std.StringHashMap(void),
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
    /// The extension receivers whose bodies enclose the expression being
    /// checked, each with the `class_stack` depth at which it was pushed.
    ///
    /// Deliberately NOT `class_stack`: that one decides private-member
    /// visibility, and an extension body must not see its receiver's privates.
    /// This channel records identity only — it answers what `this` IS, and
    /// nothing reads it to make a checking decision.
    this_ext_stack: std.ArrayList(ThisExtRecv),
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
    /// Parallel to `type_params_in_scope`: the upper bound's class head for
    /// each parameter that declares one. A value typed by the parameter has
    /// that class's members, which is what a member access on it resolves
    /// against.
    type_param_bounds_in_scope: std.ArrayList(std.StringHashMap([]const u8)),
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
    /// The enclosing function's dataflow solutions; see `narrowing.SolveMemo`.
    solve_memo: *narrowing.SolveMemo,
    /// Spans recorded in `types` since the root inference session began; only
    /// these can carry its variables.
    types_journal: std.ArrayList(Span),
    /// Threads for the body pass; each worker allocates from an arena of its own.
    body_threads: usize,
    /// See `ModuleOptions.diagnostics`.
    report_diagnostics: bool = true,
    /// The workers' arenas, handed to the result.
    worker_arenas: std.ArrayList(*std.heap.ArenaAllocator),
    worker_scratch: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    /// One owned copy of every class name the checker records by span or
    /// binding. A name read off a type would die with that type.
    names: std.StringHashMap(void),

    pub const new = phases.new;
    pub const run = phases.run;

    /// The checker's own copy of `s`, shared by every record of that name.
    pub fn internName(self: *Checker, s: []const u8) Allocator.Error![]const u8 {
        const gop = try self.names.getOrPut(s);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, s);
        return gop.key_ptr.*;
    }

    pub fn internOpt(self: *Checker, s: ?[]const u8) Allocator.Error!?[]const u8 {
        return if (s) |x| try self.internName(x) else null;
    }

    // Bound here so every per-aspect file calls them as `self.<name>(...)`.
    pub const declareTopLevel = decl.declareTopLevel;
    pub const checkDecl = decl.checkDecl;
    pub const checkExpr = expr.checkExpr;
    pub const dumpUnresolvedByKind = expr.dumpUnresolvedByKind;
    pub const setUnresolvedProbe = expr.setUnresolvedProbe;
    pub const checkCall = expr_calls.checkCall;
    pub const checkVisibility = visibility.checkVisibility;
    pub const narrow = narrowing.narrow;
};

/// An implicit `this` class name plus its applied dsl-marker names.
/// An extension receiver in scope, and how deep `class_stack` was when it
/// became the innermost `this`.
pub const ThisExtRecv = struct {
    name: []const u8,
    class_depth: usize,
    /// The label `this@label` names it by: the extension function's name,
    /// or the callee a receiver lambda was passed to.
    label: ?[]const u8 = null,
};

pub const DslReceiver = struct {
    name: []const u8,
    markers: std.StringHashMap(void),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(helpers);
    _ = @import("check/tests.zig");
}
