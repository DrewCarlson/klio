//! Top-level phase driver: checker construction and the `run` pass
//! sequence, plus the per-phase declaration walks. Free functions over
//! `*Checker`.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const resolver = @import("resolver");

const root = @import("../check.zig");
const helpers = root.helpers;

const Allocator = std.mem.Allocator;
const Checker = root.Checker;
const Resolution = resolver.Resolution;

const Span = span.Span;
const FileId = span.FileId;

const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const Class = ast.Class;
const Function = ast.Function;
const Property = ast.Property;
const ObjectDecl = ast.ObjectDecl;
const Param = ast.Param;
const Accessor = ast.Accessor;
const Block = ast.Block;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const FunctionBody = ast.FunctionBody;
const TypeRef = ast.TypeRef;
const Catch = ast.Catch;
const WhenBranch = ast.WhenBranch;
const WhenPatternKind = ast.WhenPatternKind;
const StringPart = ast.StringPart;
const Annotation = ast.Annotation;
const Visibility = ast.Visibility;
const BinOp = ast.BinOp;
const UnOp = ast.UnOp;

const Diagnostic = diagnostics.Diagnostic;

const Type = root.Type;
const Frame = root.Frame;
const PhaseFScope = helpers.PhaseFScope;
const codes = root.codes;

pub fn new(allocator: Allocator, resolution: *const Resolution) Allocator.Error!Checker {
    var frames: std.ArrayList(Frame) = .empty;
    try frames.append(allocator, Frame.init(allocator));
    const query_scratch = try allocator.create(std.heap.ArenaAllocator);
    query_scratch.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return .{
        .allocator = allocator,
        .resolution = resolution,
        .types = std.AutoHashMap(root.Span, root.Type).init(allocator),
        .resolved_calls = std.AutoHashMap(root.Span, root.ResolvedCall).init(allocator),
        .lambda_recv_heads = std.AutoHashMap(root.Span, []const u8).init(allocator),
        .lambda_param_shapes = std.AutoHashMap(root.Span, root.ParamShape).init(allocator),
        .nothing_spans = std.AutoHashMap(root.Span, void).init(allocator),
        .nothing_by_fn = std.AutoHashMap(root.Span, std.AutoHashMap(root.Span, void)).init(allocator),
        .nothing_epoch = 0,
        .reach_cache = root.ReachCache.init(allocator),
        .expr_class = std.AutoHashMap(root.Span, []const u8).init(allocator),
        .list_elem = std.AutoHashMap(root.Span, root.Type).init(allocator),
        .diagnostics = root.DiagnosticSink.init(),
        .frames = frames,
        .fns = std.StringHashMap(std.ArrayList(root.FnSig)).init(allocator),
        .file_packages = std.AutoHashMap(u32, []const u8).init(allocator),
        .extensions = std.StringHashMap(std.ArrayList(root.ExtensionSig)).init(allocator),
        .extension_properties = std.StringHashMap(std.ArrayList(root.ExtensionPropSig)).init(allocator),
        .classes = std.StringHashMap(root.ClassInfo).init(allocator),
        .ambiguous_class_names = std.StringHashMap(void).init(allocator),
        .extension_fn_names = std.StringHashMap(void).init(allocator),
        .class_stack = .empty,
        .fn_return_stack = .empty,
        .label_stack = .empty,
        .fn_visibility = std.StringHashMap(std.ArrayList(root.VisFile)).init(allocator),
        .prop_visibility = std.StringHashMap(root.VisFile).init(allocator),
        .setter_visibility = std.StringHashMap(root.VisFile).init(allocator),
        .aliases = std.StringHashMap(root.TypeAliasInfo).init(allocator),
        .public_inline_stack = .empty,
        .suspend_context_stack = .empty,
        .reified_type_params = .empty,
        .type_params_in_scope = .empty,
        .fn_annotations = std.StringHashMap(std.ArrayList([]ast.Annotation)).init(allocator),
        .prop_annotations = std.StringHashMap([]ast.Annotation).init(allocator),
        .annotation_class_names = std.StringHashMap(void).init(allocator),
        .enum_class_names = std.StringHashMap(void).init(allocator),
        .dsl_marker_annotations = std.StringHashMap(void).init(allocator),
        .dsl_class_markers = std.StringHashMap(std.StringHashMap(void)).init(allocator),
        .dsl_receiver_stack = .empty,
        .cfgs = std.AutoHashMap(root.Span, root.Cfg).init(allocator),
        .lowerings = std.AutoHashMap(root.Span, *root.Lowered).init(allocator),
        .generic_body_depth = 0,
        .types_instantiation_dependent = std.AutoHashMap(root.Span, void).init(allocator),
        .cfg_fn_stack = .empty,
        .inference_session = null,
        .builder_inference_active = false,
        .lambda_depth = 0,
        .ebf_outside = std.AutoHashMap(root.Span, root.EbfOutside).init(allocator),
        .field_narrow_off = 0,
        .query_scratch = query_scratch,
    };
}

pub fn run(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    // First pass: seed signatures of top-level functions, classes and
    // top-level property types so forward references in bodies typecheck.
    for (file.decls) |*d| {
        try self.declareTopLevel(d);
    }
    // Collect dsl-marker annotation classes and the user classes that
    // carry them so per-body DSL-scope diagnostics can consult them as
    // the lambda-receiver stack is pushed.
    {
        var all_classes: std.ArrayList(*const Class) = .empty;
        defer all_classes.deinit(self.allocator);
        try collectAllClasses(self.allocator, file.decls, &all_classes);
        for (all_classes.items) |c| {
            if (!c.is_annotation) continue;
            for (c.annotations) |*a| {
                if (std.mem.eql(u8, annotationSimpleName(a), "DslMarker")) {
                    try self.dsl_marker_annotations.put(c.name.name, {});
                    break;
                }
            }
        }
        for (all_classes.items) |c| {
            if (c.is_annotation) continue;
            var markers = std.StringHashMap(void).init(self.allocator);
            for (c.annotations) |*a| {
                const nm = annotationSimpleName(a);
                if (self.dsl_marker_annotations.contains(nm)) {
                    try markers.put(nm, {});
                }
            }
            if (markers.count() != 0) {
                try self.dsl_class_markers.put(c.name.name, markers);
            } else {
                markers.deinit();
            }
        }
    }
    // Second pass: typecheck bodies.
    for (file.decls) |*d| {
        try self.checkDecl(d);
    }
    // Generics-related diagnostics (reified/inline, vararg, declaration-site variance).
    for (file.decls) |*d| {
        try checkGenericsDecl(self, d);
    }
    // T0027: definitely-non-nullable (`T & Any`) used outside a type parameter.
    {
        var tp_scope: std.ArrayList(std.StringHashMap(void)) = .empty;
        defer {
            for (tp_scope.items) |*s| s.deinit();
            tp_scope.deinit(self.allocator);
        }
        try tp_scope.append(self.allocator, std.StringHashMap(void).init(self.allocator));
        for (file.decls) |*d| {
            try checkDefinitelyNonNullDecl(self, d, &tp_scope);
        }
    }
    // `const val`, `value class`, `annotation class` shape checks.
    // Pre-seed the annotation- and enum-class name sets so the
    // annotation-class parameter-type check (T0037) can recognise other
    // annotation types and enums.
    {
        var anns: std.ArrayList(*const Class) = .empty;
        defer anns.deinit(self.allocator);
        try collectAnnotationClasses(self.allocator, file.decls, &anns);
        for (anns.items) |c| {
            try self.annotation_class_names.put(c.name.name, {});
        }
        var enums: std.ArrayList(*const Class) = .empty;
        defer enums.deinit(self.allocator);
        try collectEnumClasses(self.allocator, file.decls, &enums);
        for (enums.items) |c| {
            try self.enum_class_names.put(c.name.name, {});
        }
    }
    for (file.decls) |*d| {
        try checkPhaseFDecl(self, d, .TopLevel);
    }
    // typealias scope + cycle checks.
    for (file.decls) |*d| {
        try checkPhaseGDecl(self, d, true);
    }
    try checkTypealiasCycles(self);
    // extension property shape checks.
    for (file.decls) |*d| {
        try checkPhaseHDecl(self, d);
    }
    // data object, backing-field, spread, @PublishedApi.
    for (file.decls) |*d| {
        try checkPhaseJDecl(self, d, false);
    }
    // annotation-class self-reference cycle detection.
    try checkAnnotationCycles(self, file);
    // @Target / @Repeatable enforcement.
    try checkAnnotationApplications(self, file);
    // emit deprecation warning/error at every reference to a declaration
    // marked `@Deprecated`.
    try checkDeprecatedReferences(self, file);
    // opt-in propagation for declarations marked with an annotation that
    // itself carries `@RequiresOptIn`.
    try checkOptInReferences(self, file);
    // `tailrec` tail-call analysis.
    for (file.decls) |*d| {
        try checkPhaseKDecl(self, d);
    }
    // declaration-site conflicting-overload detection. The body is
    // owned by the visibility-checking sibling file; drive it when present.
    if (@hasDecl(@import("visibility.zig"), "checkConflictingOverloads")) {
        try @import("visibility.zig").checkConflictingOverloads(self);
    }
    // top-level property initializer cycles.
    try checkPropertyInitializerCycles(self, file);
    // non-property primary-ctor param read from method body.
    for (file.decls) |*d| {
        try checkCtorParamScopeDecl(self, d);
    }
    // Context-parameter position rules and static context-argument resolution.
    try @import("context_params.zig").checkContextParameters(self, file);
}

pub fn checkCtorParamScopeDecl(self: *Checker, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Class => |*c| {
            // Names visible as members of this class — own members and
            // transitively inherited supertype members / properties — are
            // shadowed by their member binding rather than the ctor param.
            // Skip those names when computing the non-property set.
            var member_names = try collectMemberNameSet(self, c);
            defer member_names.deinit();
            var non_prop = std.StringHashMap(Span).init(self.allocator);
            defer non_prop.deinit();
            for (c.primary_params) |*p| {
                if (p.property == null and !member_names.contains(p.name.name)) {
                    try non_prop.put(p.name.name, p.name.span);
                }
            }
            if (non_prop.count() != 0) {
                for (c.members) |*m| {
                    switch (m.*) {
                        .Function => |*f| {
                            if (f.body) |*body| {
                                var local = std.StringHashMap(void).init(self.allocator);
                                defer local.deinit();
                                for (f.params) |*p| try local.put(p.name.name, {});
                                try checkCtorParamInBody(self, body, &non_prop, &local);
                            }
                        },
                        .Property => |p| {
                            // Property initializers run during instance init —
                            // non-property ctor params are visible there.
                            // Accessor bodies are invoked post-construction and
                            // must not see them.
                            if (p.getter) |getter| {
                                var local = std.StringHashMap(void).init(self.allocator);
                                defer local.deinit();
                                try checkCtorParamInBody(self, &getter.body, &non_prop, &local);
                            }
                            if (p.setter) |setter| {
                                var local = std.StringHashMap(void).init(self.allocator);
                                defer local.deinit();
                                for (setter.params) |*i| try local.put(i.name, {});
                                try checkCtorParamInBody(self, &setter.body, &non_prop, &local);
                            }
                        },
                        else => {},
                    }
                }
            }
            for (c.members) |*m| {
                try checkCtorParamScopeDecl(self, m);
            }
        },
        .Object => |*o| {
            for (o.members) |*m| {
                try checkCtorParamScopeDecl(self, m);
            }
        },
        else => {},
    }
}

/// Names that resolve as class members at any point in the class's
/// inheritance chain — own properties / functions / property-form ctor
/// params, plus transitively inherited equivalents via `self.classes`.
pub fn collectMemberNameSet(self: *const Checker, c: *const Class) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(self.allocator);
    for (c.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| try out.put(f.name.name, {}),
            .Property => |p| try out.put(p.name.name, {}),
            else => {},
        }
    }
    for (c.supertypes) |*s| {
        if (root.classNamed(self, s.name.name)) |info| {
            var it = info.members.keyIterator();
            while (it.next()) |k| try out.put(k.*, {});
        }
    }
    return out;
}

pub fn checkCtorParamInBody(
    self: *Checker,
    body: *const FunctionBody,
    non_prop: *const std.StringHashMap(Span),
    local: *std.StringHashMap(void),
) Allocator.Error!void {
    switch (body.*) {
        .Block => |*b| try checkCtorParamInBlock(self, b, non_prop, local),
        .Expr => |*e| try checkCtorParamInExpr(self, e, non_prop, local),
    }
}

pub fn checkCtorParamInBlock(
    self: *Checker,
    b: *const Block,
    non_prop: *const std.StringHashMap(Span),
    local: *std.StringHashMap(void),
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try checkCtorParamInExpr(self, e, non_prop, local),
            .Assign => |*a| {
                try checkCtorParamInExpr(self, &a.target, non_prop, local);
                try checkCtorParamInExpr(self, &a.value, non_prop, local);
            },
            .Decl => |*d| switch (d.*) {
                .Property => |p| {
                    if (p.init) |*init| try checkCtorParamInExpr(self, init, non_prop, local);
                    try local.put(p.name.name, {});
                },
                .Function => |*f| {
                    try local.put(f.name.name, {});
                },
                else => {},
            },
            .DestructuringDecl => |*dd| {
                try checkCtorParamInExpr(self, &dd.init, non_prop, local);
                for (dd.names) |*n| {
                    if (!std.mem.eql(u8, n.name, "_")) try local.put(n.name, {});
                }
            },
        }
    }
}

fn emitCtorParamOutOfScope(self: *Checker, name: []const u8, sp: Span) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "`{s}` is a primary-constructor parameter (not a `val`/`var`) and is not in scope here; declare it as `val {s}` to promote it to a property",
        .{ name, name },
    );
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_NON_PROPERTY_CTOR_PARAM_OUT_OF_SCOPE);
    try self.diagnostics.emit(self.allocator, d);
}

pub fn checkCtorParamInExpr(
    self: *Checker,
    e: *const Expr,
    non_prop: *const std.StringHashMap(Span),
    local: *std.StringHashMap(void),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                const first = p.segments[0];
                if (!local.contains(first.name) and non_prop.contains(first.name)) {
                    try emitCtorParamOutOfScope(self, first.name, first.span);
                }
            }
        },
        .Call => |c| {
            try checkCtorParamInExpr(self, c.callee, non_prop, local);
            for (c.args) |*a| try checkCtorParamInExpr(self, a, non_prop, local);
        },
        .Index => |x| {
            try checkCtorParamInExpr(self, x.receiver, non_prop, local);
            for (x.args) |*a| try checkCtorParamInExpr(self, a, non_prop, local);
        },
        .Binary => |b| {
            try checkCtorParamInExpr(self, b.lhs, non_prop, local);
            try checkCtorParamInExpr(self, b.rhs, non_prop, local);
        },
        .If => |i| {
            try checkCtorParamInExpr(self, i.cond, non_prop, local);
            try checkCtorParamInExpr(self, i.then_branch, non_prop, local);
            if (i.else_branch) |eb| try checkCtorParamInExpr(self, eb, non_prop, local);
        },
        .While => |w| {
            try checkCtorParamInExpr(self, w.cond, non_prop, local);
            try checkCtorParamInExpr(self, w.body, non_prop, local);
        },
        .DoWhile => |w| {
            if (w.body) |b| try checkCtorParamInExpr(self, b, non_prop, local);
            try checkCtorParamInExpr(self, w.cond, non_prop, local);
        },
        .For => |f| {
            try checkCtorParamInExpr(self, f.iter, non_prop, local);
            var inner = try cloneStringSet(self.allocator, local);
            defer inner.deinit();
            for (f.vars) |*v| try inner.put(v.name, {});
            try checkCtorParamInExpr(self, f.body, non_prop, &inner);
        },
        .Block => |*b| try checkCtorParamInBlock(self, b, non_prop, local),
        .Member => |m| try checkCtorParamInExpr(self, m.receiver, non_prop, local),
        .Unary => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .Postfix => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .Labeled => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .Return => |r| {
            if (r.value) |v| try checkCtorParamInExpr(self, v, non_prop, local);
        },
        .Throw => |x| try checkCtorParamInExpr(self, x.value, non_prop, local),
        .IsCheck => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .As => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .Spread => |x| try checkCtorParamInExpr(self, x.expr, non_prop, local),
        .StringTemplate => |st| {
            for (st.parts) |part| {
                switch (part) {
                    .ShortInterp => |id| {
                        if (!local.contains(id.name) and non_prop.contains(id.name)) {
                            try emitCtorParamOutOfScope(self, id.name, id.span);
                        }
                    },
                    .Interp => |pe| try checkCtorParamInExpr(self, pe, non_prop, local),
                    .Text => {},
                }
            }
        },
        .Lambda => |l| {
            var inner = try cloneStringSet(self.allocator, local);
            defer inner.deinit();
            for (l.params) |*p| try inner.put(p.name, {});
            try checkCtorParamInBlock(self, &l.body, non_prop, &inner);
        },
        .When => |w| {
            if (w.subject) |s| try checkCtorParamInExpr(self, s, non_prop, local);
            for (w.branches) |*b| {
                try checkCtorParamInWhenBranch(self, b, non_prop, local);
            }
        },
        .Try => |t| {
            try checkCtorParamInTry(self, &t.body, t.catches, if (t.finally) |*fb| fb else null, non_prop, local);
        },
        else => {},
    }
}

fn checkCtorParamInWhenBranch(
    self: *Checker,
    b: *const WhenBranch,
    non_prop: *const std.StringHashMap(Span),
    local: *std.StringHashMap(void),
) Allocator.Error!void {
    for (b.patterns) |*p| {
        switch (p.kind) {
            .Value, .InRange, .NotInRange => |*e| try checkCtorParamInExpr(self, e, non_prop, local),
            else => {},
        }
    }
    try checkCtorParamInExpr(self, &b.body, non_prop, local);
}

fn checkCtorParamInTry(
    self: *Checker,
    body: *const Block,
    catches: []const Catch,
    finally: ?*const Block,
    non_prop: *const std.StringHashMap(Span),
    local: *std.StringHashMap(void),
) Allocator.Error!void {
    try checkCtorParamInBlock(self, body, non_prop, local);
    for (catches) |*c| {
        var inner = try cloneStringSet(self.allocator, local);
        defer inner.deinit();
        try inner.put(c.binding.name, {});
        try checkCtorParamInBlock(self, &c.body, non_prop, &inner);
    }
    if (finally) |fb| {
        try checkCtorParamInBlock(self, fb, non_prop, local);
    }
}

/// Detect cycles among top-level property initializer reads. A property
/// whose initializer reads another property — directly or transitively
/// back to itself — forms a cycle whose evaluation order is unspecified.
pub fn checkPropertyInitializerCycles(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    const a = self.allocator;
    var props: std.ArrayList(*const Property) = .empty;
    defer props.deinit(a);
    var by_name = std.StringHashMap(usize).init(a);
    defer by_name.deinit();
    for (file.decls) |*d| {
        if (d.* == .Property and d.Property.init != null) {
            const p = d.Property;
            const idx = props.items.len;
            try by_name.put(p.name.name, idx);
            try props.append(a, p);
        }
    }
    if (props.items.len == 0) return;

    var edges = try a.alloc([]usize, props.items.len);
    defer {
        for (edges) |e| a.free(e);
        a.free(edges);
    }
    for (props.items, 0..) |p, idx| {
        var reads = std.AutoHashMap(usize, void).init(a);
        defer reads.deinit();
        try helpers.collectPropertyReads(&p.init.?, &by_name, &reads);
        var list: std.ArrayList(usize) = .empty;
        var it = reads.keyIterator();
        while (it.next()) |k| try list.append(a, k.*);
        edges[idx] = try list.toOwnedSlice(a);
    }

    const sccs = try tarjanSccs(a, edges);
    defer {
        for (sccs) |comp| a.free(comp);
        a.free(sccs);
    }
    for (sccs) |comp| {
        const is_cycle = comp.len > 1 or containsUsize(edges[comp[0]], comp[0]);
        if (!is_cycle) continue;
        // Build the chain string `a -> b -> c`.
        var chain_buf: std.ArrayList(u8) = .empty;
        defer chain_buf.deinit(a);
        for (comp, 0..) |i, k| {
            if (k > 0) try chain_buf.appendSlice(a, " -> ");
            try chain_buf.appendSlice(a, props.items[i].name.name);
        }
        const chain = chain_buf.items;
        for (comp) |i| {
            const p = props.items[i];
            const msg = try std.fmt.allocPrint(
                a,
                "Property `{s}` participates in an initializer cycle: {s}",
                .{ p.name.name, chain },
            );
            var d = Diagnostic.warning(msg, p.init.?.span());
            _ = d.withCode(codes.TYPE_PROPERTY_INITIALIZER_CYCLE);
            try self.diagnostics.emit(a, d);
        }
    }
}

pub fn checkPhaseKDecl(self: *Checker, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try checkTailrecFunction(self, f),
        .Class => |*c| {
            for (c.members) |*m| try checkPhaseKDecl(self, m);
        },
        .Object => |*o| {
            for (o.members) |*m| try checkPhaseKDecl(self, m);
        },
        .Property, .TypeAlias => {},
    }
}

pub fn checkTailrecFunction(self: *Checker, f: *const Function) Allocator.Error!void {
    if (!f.is_tailrec) return;
    if (f.is_open or f.is_override) {
        var d = Diagnostic.warning(
            "tailrec is redundant on an open or override function — virtual dispatch defeats the rewrite",
            f.name.span,
        );
        _ = d.withCode(codes.TYPE_TAILREC_ON_OPEN);
        try self.diagnostics.emit(self.allocator, d);
    }
    const body = f.body orelse return;
    var tail_sites = std.AutoHashMap(Span, void).init(self.allocator);
    defer tail_sites.deinit();
    var all_sites: std.ArrayList(Span) = .empty;
    defer all_sites.deinit(self.allocator);
    switch (body) {
        .Block => |b| {
            try helpers.tailrecWalkBlock(&b, true, f.name.name, &tail_sites);
            try helpers.tailrecCollectAllBlock(self.allocator, &b, f.name.name, &all_sites);
        },
        .Expr => |e| {
            try helpers.tailrecWalkExpr(&e, true, f.name.name, &tail_sites);
            try helpers.tailrecCollectAllExpr(self.allocator, &e, f.name.name, &all_sites);
        },
    }
    if (tail_sites.count() == 0) {
        var d = Diagnostic.warning(
            "a function is marked `tailrec` but no tail calls are found",
            f.name.span,
        );
        _ = d.withCode(codes.TYPE_NO_TAIL_CALLS_FOUND);
        try self.diagnostics.emit(self.allocator, d);
    }
    for (all_sites.items) |sp| {
        if (!tail_sites.contains(sp)) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "recursive call to `{s}` is not a tail call",
                .{f.name.name},
            );
            var d = Diagnostic.warning(msg, sp);
            _ = d.withCode(codes.TYPE_NON_TAIL_RECURSIVE_CALL);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
}

pub fn checkPhaseFDecl(self: *Checker, d: *const Decl, scope: PhaseFScope) Allocator.Error!void {
    switch (d.*) {
        .Property => |p| {
            if (p.is_const) try checkConstVal(self, p, scope);
            if (p.is_inline) try checkInlineProperty(self, p);
            // A property without a backing field cannot declare an
            // initializer. Skip extension properties (T0040 already covers
            // that case) and abstract properties.
            if (p.init != null and !p.is_abstract and p.receiver_type == null and !propertyHasBackingField(p)) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "property `{s}` has custom accessors that don't use `field`, so it has no backing field — initializer is not allowed",
                    .{p.name.name},
                );
                var diag = Diagnostic.err(msg, p.name.span);
                _ = diag.withCode(codes.TYPE_PROPERTY_NO_BACKING_FIELD_HAS_INITIALIZER);
                try self.diagnostics.emit(self.allocator, diag);
            }
        },
        .Class => |*c| {
            if (c.is_value) try checkValueClass(self, c);
            if (c.is_annotation) try checkAnnotationClass(self, c);
            const member_scope: PhaseFScope = if (c.is_companion or scope == .Object) .Object else .Class;
            for (c.members) |*m| {
                try checkPhaseFDecl(self, m, member_scope);
            }
        },
        .Object => |*o| {
            for (o.members) |*m| {
                try checkPhaseFDecl(self, m, .Object);
            }
        },
        .Function, .TypeAlias => {},
    }
}

pub fn checkPhaseHDecl(self: *Checker, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Property => |p| {
            if (p.receiver_type == null) return;
            if (p.init != null) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "extension property `{s}` cannot have an initializer; no backing field is allowed",
                    .{p.name.name},
                );
                var diag = Diagnostic.err(msg, p.name.span);
                _ = diag.withCode(codes.TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER);
                try self.diagnostics.emit(self.allocator, diag);
            }
            if (p.delegate != null) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "extension property `{s}` cannot be declared with a `by` delegate",
                    .{p.name.name},
                );
                var diag = Diagnostic.err(msg, p.name.span);
                _ = diag.withCode(codes.TYPE_EXTENSION_PROPERTY_HAS_DELEGATE);
                try self.diagnostics.emit(self.allocator, diag);
            }
            const need_setter = p.mutable;
            const getter_absent = p.getter == null;
            const setter_absent = need_setter and p.setter == null;
            // An `expect` extension property is a declaration with no body;
            // its accessors come from the `actual`.
            if ((getter_absent or setter_absent) and p.init == null and p.delegate == null and !p.is_expect) {
                const what: []const u8 = if (getter_absent and setter_absent)
                    "explicit getter and setter"
                else if (getter_absent)
                    "explicit getter"
                else
                    "explicit setter";
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "extension property `{s}` requires {s}",
                    .{ p.name.name, what },
                );
                var diag = Diagnostic.err(msg, p.name.span);
                _ = diag.withCode(codes.TYPE_EXTENSION_PROPERTY_NEEDS_ACCESSOR);
                try self.diagnostics.emit(self.allocator, diag);
            }
            if (p.is_lateinit) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "extension property `{s}` cannot be `lateinit`",
                    .{p.name.name},
                );
                var diag = Diagnostic.err(msg, p.name.span);
                _ = diag.withCode(codes.TYPE_EXTENSION_PROPERTY_HAS_INITIALIZER);
                try self.diagnostics.emit(self.allocator, diag);
            }
        },
        .Class => |*c| {
            for (c.members) |*m| try checkPhaseHDecl(self, m);
        },
        .Object => |*o| {
            for (o.members) |*m| try checkPhaseHDecl(self, m);
        },
        else => {},
    }
}

pub fn checkPhaseJDecl(self: *Checker, d: *const Decl, in_accessor: bool) Allocator.Error!void {
    switch (d.*) {
        .Object => |*o| {
            if (o.is_data) {
                for (o.members) |*m| {
                    if (m.* == .Function) {
                        const f = &m.Function;
                        if (std.mem.eql(u8, f.name.name, "equals") or std.mem.eql(u8, f.name.name, "hashCode")) {
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "`data object {s}` cannot override `{s}`",
                                .{ o.name.name, f.name.name },
                            );
                            var diag = Diagnostic.err(msg, f.name.span);
                            _ = diag.withCode(codes.TYPE_DATA_OBJECT_FORBIDS_EQUALS_HASHCODE);
                            try self.diagnostics.emit(self.allocator, diag);
                        }
                    }
                }
            }
            for (o.members) |*m| try checkPhaseJDecl(self, m, false);
        },
        .Class => |*c| {
            for (c.members) |*m| try checkPhaseJDecl(self, m, false);
        },
        .Property => |p| {
            // Extension properties never have a backing field — any `field`
            // reference inside their accessors is invalid.
            const has_backing_field = p.receiver_type == null;
            if (p.getter) |g| {
                try walkAccessorForPhaseJ(self, g, has_backing_field, p.name.name);
            }
            if (p.setter) |s| {
                try walkAccessorForPhaseJ(self, s, has_backing_field, p.name.name);
            }
            if (p.init) |*init| {
                try walkExprForPhaseJ(self, init, in_accessor, true, p.name.name);
            }
        },
        .Function => |*f| {
            if (f.body) |body| {
                switch (body) {
                    .Block => |b| try walkBlockForPhaseJ(self, &b, in_accessor, false, ""),
                    .Expr => |e| try walkExprForPhaseJ(self, &e, in_accessor, false, ""),
                }
            }
        },
        .TypeAlias => {},
    }
}

pub fn walkAccessorForPhaseJ(
    self: *Checker,
    a: *const Accessor,
    has_backing_field: bool,
    prop_name: []const u8,
) Allocator.Error!void {
    switch (a.body) {
        .Block => |b| try walkBlockForPhaseJ(self, &b, true, has_backing_field, prop_name),
        .Expr => |e| try walkExprForPhaseJ(self, &e, true, has_backing_field, prop_name),
    }
}

pub fn walkBlockForPhaseJ(
    self: *Checker,
    b: *const Block,
    in_accessor: bool,
    has_backing_field: bool,
    prop_name: []const u8,
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Decl => |*d| try checkPhaseJDecl(self, d, in_accessor),
            .Expr => |*e| try walkExprForPhaseJ(self, e, in_accessor, has_backing_field, prop_name),
            .Assign => |*a| {
                try walkExprForPhaseJ(self, &a.target, in_accessor, has_backing_field, prop_name);
                try walkExprForPhaseJ(self, &a.value, in_accessor, has_backing_field, prop_name);
            },
            .DestructuringDecl => |*dd| {
                try walkExprForPhaseJ(self, &dd.init, in_accessor, has_backing_field, prop_name);
            },
        }
    }
}

fn checkFieldReference(
    self: *Checker,
    sp: Span,
    in_accessor: bool,
    has_backing_field: bool,
    prop_name: []const u8,
) Allocator.Error!void {
    if (!in_accessor) {
        var d = Diagnostic.err("`field` can only be referenced inside a property accessor body", sp);
        _ = d.withCode(codes.TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR);
        try self.diagnostics.emit(self.allocator, d);
    } else if (!has_backing_field) {
        const detail = if (prop_name.len == 0)
            try self.allocator.dupe(u8, "property has no backing field")
        else
            try std.fmt.allocPrint(self.allocator, "property `{s}` has no backing field", .{prop_name});
        const msg = try std.fmt.allocPrint(self.allocator, "`field` is not available here: {s}", .{detail});
        var d = Diagnostic.err(msg, sp);
        _ = d.withCode(codes.TYPE_BACKING_FIELD_OUTSIDE_ACCESSOR);
        try self.diagnostics.emit(self.allocator, d);
    }
}

pub fn walkExprForPhaseJ(
    self: *Checker,
    e: *const Expr,
    in_accessor: bool,
    has_backing_field: bool,
    prop_name: []const u8,
) Allocator.Error!void {
    if (e.* == .Path) {
        const p = e.Path;
        if (p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field")) {
            try checkFieldReference(self, p.segments[0].span, in_accessor, has_backing_field, prop_name);
        }
    }
    // Recurse through children that may contain `field` references.
    switch (e.*) {
        .Block => |*b| try walkBlockForPhaseJ(self, b, in_accessor, has_backing_field, prop_name),
        .If => |i| {
            try walkExprForPhaseJ(self, i.cond, in_accessor, has_backing_field, prop_name);
            try walkExprForPhaseJ(self, i.then_branch, in_accessor, has_backing_field, prop_name);
            if (i.else_branch) |eb| try walkExprForPhaseJ(self, eb, in_accessor, has_backing_field, prop_name);
        },
        .While => |w| {
            try walkExprForPhaseJ(self, w.cond, in_accessor, has_backing_field, prop_name);
            try walkExprForPhaseJ(self, w.body, in_accessor, has_backing_field, prop_name);
        },
        .DoWhile => |w| {
            if (w.body) |b| try walkExprForPhaseJ(self, b, in_accessor, has_backing_field, prop_name);
            try walkExprForPhaseJ(self, w.cond, in_accessor, has_backing_field, prop_name);
        },
        .For => |f| {
            try walkExprForPhaseJ(self, f.iter, in_accessor, has_backing_field, prop_name);
            try walkExprForPhaseJ(self, f.body, in_accessor, has_backing_field, prop_name);
        },
        .Binary => |b| {
            try walkExprForPhaseJ(self, b.lhs, in_accessor, has_backing_field, prop_name);
            try walkExprForPhaseJ(self, b.rhs, in_accessor, has_backing_field, prop_name);
        },
        .Call => |c| {
            try walkExprForPhaseJ(self, c.callee, in_accessor, has_backing_field, prop_name);
            for (c.args) |*a| try walkExprForPhaseJ(self, a, in_accessor, has_backing_field, prop_name);
        },
        .Index => |x| {
            try walkExprForPhaseJ(self, x.receiver, in_accessor, has_backing_field, prop_name);
            for (x.args) |*a| try walkExprForPhaseJ(self, a, in_accessor, has_backing_field, prop_name);
        },
        .Return => |r| {
            if (r.value) |inner| try walkExprForPhaseJ(self, inner, in_accessor, has_backing_field, prop_name);
        },
        .Unary => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .Postfix => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .Member => |m| try walkExprForPhaseJ(self, m.receiver, in_accessor, has_backing_field, prop_name),
        .Labeled => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .Throw => |x| try walkExprForPhaseJ(self, x.value, in_accessor, has_backing_field, prop_name),
        .IsCheck => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .As => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .Spread => |x| try walkExprForPhaseJ(self, x.expr, in_accessor, has_backing_field, prop_name),
        .Try => |t| {
            try walkBlockForPhaseJ(self, &t.body, in_accessor, has_backing_field, prop_name);
            for (t.catches) |*c| try walkBlockForPhaseJ(self, &c.body, in_accessor, has_backing_field, prop_name);
            if (t.finally) |*fb| try walkBlockForPhaseJ(self, fb, in_accessor, has_backing_field, prop_name);
        },
        .Lambda => |l| {
            // Lambdas inside accessor bodies still see `field`.
            try walkBlockForPhaseJ(self, &l.body, in_accessor, has_backing_field, prop_name);
        },
        .When => |w| {
            if (w.subject) |s| try walkExprForPhaseJ(self, s, in_accessor, has_backing_field, prop_name);
            for (w.branches) |*b| {
                for (b.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| try walkExprForPhaseJ(self, pe, in_accessor, has_backing_field, prop_name),
                        else => {},
                    }
                }
                try walkExprForPhaseJ(self, &b.body, in_accessor, has_backing_field, prop_name);
            }
        },
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Block => |*blk| try walkBlockForPhaseJ(self, blk, in_accessor, has_backing_field, prop_name),
                    .Expr => |*ex| try walkExprForPhaseJ(self, ex, in_accessor, has_backing_field, prop_name),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try checkPhaseJDecl(self, m, false);
        },
        else => {},
    }
}

pub fn checkPhaseGDecl(self: *Checker, d: *const Decl, at_top_level: bool) Allocator.Error!void {
    switch (d.*) {
        .TypeAlias => |*a| {
            if (!at_top_level) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "`typealias {s}` is only allowed at top level",
                    .{a.name.name},
                );
                var diag = Diagnostic.err(msg, a.name.span);
                _ = diag.withCode(codes.TYPE_TYPEALIAS_NOT_TOPLEVEL);
                try self.diagnostics.emit(self.allocator, diag);
            }
        },
        .Class => |*c| {
            for (c.members) |*m| try checkPhaseGDecl(self, m, false);
        },
        .Object => |*o| {
            for (o.members) |*m| try checkPhaseGDecl(self, m, false);
        },
        .Function => |*f| {
            if (f.body) |body| {
                switch (body) {
                    .Block => |b| try walkBlockForPhaseG(self, &b),
                    .Expr => |e| try walkExprForPhaseG(self, &e),
                }
            }
        },
        .Property => {},
    }
}

pub fn walkBlockForPhaseG(self: *Checker, b: *const Block) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Decl => |*d| try checkPhaseGDecl(self, d, false),
            .Expr => |*e| try walkExprForPhaseG(self, e),
            .Assign => |*a| try walkExprForPhaseG(self, &a.value),
            .DestructuringDecl => |*dd| try walkExprForPhaseG(self, &dd.init),
        }
    }
}

pub fn walkExprForPhaseG(self: *Checker, e: *const Expr) Allocator.Error!void {
    switch (e.*) {
        .Block => |*b| try walkBlockForPhaseG(self, b),
        .If => |i| {
            try walkExprForPhaseG(self, i.cond);
            try walkExprForPhaseG(self, i.then_branch);
            if (i.else_branch) |eb| try walkExprForPhaseG(self, eb);
        },
        .While => |w| {
            try walkExprForPhaseG(self, w.cond);
            try walkExprForPhaseG(self, w.body);
        },
        .DoWhile => |w| {
            if (w.body) |b| try walkExprForPhaseG(self, b);
            try walkExprForPhaseG(self, w.cond);
        },
        .For => |f| {
            try walkExprForPhaseG(self, f.iter);
            try walkExprForPhaseG(self, f.body);
        },
        .Lambda => |l| try walkBlockForPhaseG(self, &l.body),
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Block => |*blk| try walkBlockForPhaseG(self, blk),
                    .Expr => |*ex| try walkExprForPhaseG(self, ex),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try checkPhaseGDecl(self, m, false);
        },
        .When => |w| {
            if (w.subject) |s| try walkExprForPhaseG(self, s);
            for (w.branches) |*br| {
                try walkExprForPhaseG(self, &br.body);
            }
        },
        .Labeled => |x| try walkExprForPhaseG(self, x.expr),
        .Try => |t| {
            try walkBlockForPhaseG(self, &t.body);
            if (t.finally) |*f| try walkBlockForPhaseG(self, f);
        },
        else => {},
    }
}

/// Detect direct / transitive `typealias` cycles. Emits T0038 once per
/// alias on a cycle.
pub fn checkTypealiasCycles(self: *Checker) Allocator.Error!void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var it = self.aliases.keyIterator();
    while (it.next()) |k| try names.append(self.allocator, k.*);
    for (names.items) |n| {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        if (try aliasReachesSelf(self, n, n, &seen)) {
            const sp = self.aliases.get(n).?.name_span;
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "recursive typealias `{s}` expands to itself",
                .{n},
            );
            var d = Diagnostic.err(msg, sp);
            _ = d.withCode(codes.TYPE_RECURSIVE_TYPEALIAS);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
}

pub fn aliasReachesSelf(
    self: *const Checker,
    start: []const u8,
    current: []const u8,
    seen: *std.StringHashMap(void),
) Allocator.Error!bool {
    const info = self.aliases.get(current) orelse return false;
    if ((try seen.getOrPut(current)).found_existing) return false;
    // Walk every aliased name appearing anywhere in the target TypeRef.
    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(self.allocator);
    try helpers.collectAliasedNames(self.allocator, &info.target, &targets);
    for (targets.items) |t| {
        if (std.mem.eql(u8, t, start)) return true;
        if (try aliasReachesSelf(self, start, t, seen)) return true;
    }
    return false;
}

/// A property has a backing field iff:
///
/// * no custom accessors (default get/set);
/// * any custom accessor body references `field`;
/// * mutable property with exactly one of get/set custom (the other
///   defaults and needs storage).
///
/// Extension properties never have a backing field.
pub fn propertyHasBackingField(p: *const Property) bool {
    if (p.receiver_type != null) return false;
    const getter = p.getter;
    const setter = p.setter;
    if (getter == null and setter == null) return true;
    if (getter != null and setter == null) {
        if (p.mutable) return true;
        return helpers.accessorUsesField(getter.?);
    }
    if (getter == null and setter != null) {
        if (p.mutable) return true;
        return helpers.accessorUsesField(setter.?);
    }
    return helpers.accessorUsesField(getter.?) or helpers.accessorUsesField(setter.?);
}

/// A non-private function that returns an anonymous object with multiple
/// declared supertypes (and no explicit return type annotation) leaks an
/// unnameable type out of its scope. Single-supertype anonymous objects
/// are implicitly downcast to their supertype, so they are allowed.
pub fn checkAnonymousObjectEscape(self: *Checker, f: *const Function) Allocator.Error!void {
    if (f.visibility == .Private) return;
    if (f.return_type != null) return;
    const body = f.body orelse return;
    const tail: *const Expr = switch (body) {
        .Expr => |*e| e,
        .Block => |b| blk: {
            if (b.stmts.len == 0) return;
            const last = &b.stmts[b.stmts.len - 1];
            switch (last.*) {
                .Expr => |*e| break :blk e,
                else => return,
            }
        },
    };
    if (tail.* != .ObjectExpr) return;
    const oe = tail.ObjectExpr;
    if (oe.supertypes.len < 2) return;
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "anonymous object with multiple supertypes escapes from non-private function `{s}` — declare an explicit return type",
        .{f.name.name},
    );
    var d = Diagnostic.err(msg, oe.span);
    _ = d.withCode(codes.TYPE_ANONYMOUS_OBJECT_ESCAPES_PUBLIC);
    try self.diagnostics.emit(self.allocator, d);
}

pub fn checkInlineParamEscape(self: *Checker, f: *const Function) Allocator.Error!void {
    if (!f.is_inline) return;
    // Only function-typed parameters are inlined (or crossinline /
    // noinline). Plain values (`x: Int`) on an inline fun are not affected.
    var inline_params: std.ArrayList([]const u8) = .empty;
    defer inline_params.deinit(self.allocator);
    var crossinline_params: std.ArrayList([]const u8) = .empty;
    defer crossinline_params.deinit(self.allocator);
    for (f.params) |*p| {
        if (p.ty.function == null) continue;
        if (!p.is_noinline and !p.is_crossinline) {
            try inline_params.append(self.allocator, p.name.name);
        } else if (p.is_crossinline) {
            try crossinline_params.append(self.allocator, p.name.name);
        }
    }
    if (inline_params.items.len == 0 and crossinline_params.items.len == 0) return;
    if (f.body) |body| {
        switch (body) {
            .Block => |b| try walkBlockForInlineEscape(self, &b, inline_params.items, crossinline_params.items),
            .Expr => |e| try walkExprForInlineEscape(self, &e, inline_params.items, crossinline_params.items, true),
        }
    }
}

pub fn walkBlockForInlineEscape(
    self: *Checker,
    b: *const Block,
    inline_params: []const []const u8,
    crossinline_params: []const []const u8,
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try walkExprForInlineEscape(self, e, inline_params, crossinline_params, false),
            .Assign => |*a| {
                try flagInlineEscape(self, &a.value, inline_params, crossinline_params, "stored in a variable");
                try walkExprForInlineEscape(self, &a.value, inline_params, crossinline_params, false);
            },
            .Decl => |*d| switch (d.*) {
                .Property => |p| {
                    if (p.init) |*init| {
                        try flagInlineEscape(self, init, inline_params, crossinline_params, "stored in a variable");
                        try walkExprForInlineEscape(self, init, inline_params, crossinline_params, false);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

pub fn walkExprForInlineEscape(
    self: *Checker,
    e: *const Expr,
    inline_params: []const []const u8,
    crossinline_params: []const []const u8,
    is_callee: bool,
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1 and !is_callee) {
                const n = p.segments[0].name;
                if (sliceContainsStr(inline_params, n)) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "inline parameter `{s}` cannot escape the function body — only direct invocation is allowed",
                        .{n},
                    );
                    var d = Diagnostic.err(msg, p.segments[0].span);
                    _ = d.withCode(codes.TYPE_INLINE_PARAM_LEAK);
                    try self.diagnostics.emit(self.allocator, d);
                }
            }
        },
        .Call => |c| {
            try walkExprForInlineEscape(self, c.callee, inline_params, crossinline_params, true);
            for (c.args) |*a| {
                // An argument position is an escape for a bare inline param
                // reference (we cannot prove the callee is inline).
                try flagInlineEscape(self, a, inline_params, crossinline_params, "passed as an argument");
                try walkExprForInlineEscape(self, a, inline_params, crossinline_params, false);
            }
        },
        .Return => |r| {
            if (r.value) |v| {
                try flagInlineEscape(self, v, inline_params, crossinline_params, "returned from the function");
                try walkExprForInlineEscape(self, v, inline_params, crossinline_params, false);
            }
        },
        .Block => |*b| try walkBlockForInlineEscape(self, b, inline_params, crossinline_params),
        .If => |i| {
            try walkExprForInlineEscape(self, i.cond, inline_params, crossinline_params, false);
            try walkExprForInlineEscape(self, i.then_branch, inline_params, crossinline_params, false);
            if (i.else_branch) |eb| try walkExprForInlineEscape(self, eb, inline_params, crossinline_params, false);
        },
        .Member => |m| {
            try walkExprForInlineEscape(self, m.receiver, inline_params, crossinline_params, false);
        },
        else => {},
    }
}

pub fn flagInlineEscape(
    self: *Checker,
    e: *const Expr,
    inline_params: []const []const u8,
    crossinline_params: []const []const u8,
    action: []const u8,
) Allocator.Error!void {
    if (e.* != .Path) return;
    const p = e.Path;
    if (p.segments.len != 1) return;
    const n = p.segments[0].name;
    // crossinline: store / return are forbidden; argument-passing is
    // allowed when the action is exactly "passed as an argument" — but we
    // still flag store/return.
    if (sliceContainsStr(crossinline_params, n) and !std.mem.eql(u8, action, "passed as an argument")) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "crossinline parameter `{s}` cannot be {s}",
            .{ n, action },
        );
        var d = Diagnostic.err(msg, p.segments[0].span);
        _ = d.withCode(codes.TYPE_CROSSINLINE_PARAM_LEAK);
        try self.diagnostics.emit(self.allocator, d);
        return;
    }
    // inline (non-crossinline, non-noinline): any non-callee use is an
    // escape. Already flagged at the bare-Path case for non-call contexts;
    // only flag here when the bare reference is in an argument list.
    if (sliceContainsStr(inline_params, n) and std.mem.eql(u8, action, "passed as an argument")) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "inline parameter `{s}` cannot be {s}",
            .{ n, action },
        );
        var d = Diagnostic.err(msg, p.segments[0].span);
        _ = d.withCode(codes.TYPE_INLINE_PARAM_LEAK);
        try self.diagnostics.emit(self.allocator, d);
    }
}

pub fn checkInlineProperty(self: *Checker, p: *const Property) Allocator.Error!void {
    // An inline property has no backing field. That means no initializer,
    // no `lateinit`, no `by` delegate, and any custom accessor must avoid
    // the `field` identifier.
    var bad = false;
    if (p.init != null or p.is_lateinit or p.delegate != null) bad = true;
    // An inline property must declare at least one accessor.
    if (p.getter == null and p.setter == null) bad = true;
    if (bad) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`inline` property `{s}` must not have a backing field; declare explicit accessors that do not reference `field`",
            .{p.name.name},
        );
        var d = Diagnostic.err(msg, p.name.span);
        _ = d.withCode(codes.TYPE_INLINE_PROPERTY_HAS_BACKING_FIELD);
        try self.diagnostics.emit(self.allocator, d);
    }
}

pub fn checkConstVal(self: *Checker, p: *const Property, scope: PhaseFScope) Allocator.Error!void {
    if (p.mutable) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`const` modifier is only allowed on `val`, not `var`: `{s}`",
            .{p.name.name},
        );
        var d = Diagnostic.err(msg, p.name.span);
        _ = d.withCode(codes.TYPE_CONST_VAL_NOT_TOPLEVEL);
        try self.diagnostics.emit(self.allocator, d);
    }
    if (!(scope == .TopLevel or scope == .Object)) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`const val` is only allowed at top level or inside an `object`: `{s}`",
            .{p.name.name},
        );
        var d = Diagnostic.err(msg, p.name.span);
        _ = d.withCode(codes.TYPE_CONST_VAL_NOT_TOPLEVEL);
        try self.diagnostics.emit(self.allocator, d);
    }
    if (p.delegate != null or p.getter != null or p.setter != null) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`const val` cannot have a delegate or custom accessor: `{s}`",
            .{p.name.name},
        );
        var d = Diagnostic.err(msg, p.name.span);
        _ = d.withCode(codes.TYPE_CONST_VAL_NON_CONST_INIT);
        try self.diagnostics.emit(self.allocator, d);
    }
    if (p.ty) |ty| {
        if (!helpers.isConstCapableTypeName(ty.name.name) or ty.nullable) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "`const val` must have a primitive or `String` type: `{s}`",
                .{p.name.name},
            );
            var d = Diagnostic.err(msg, ty.span);
            _ = d.withCode(codes.TYPE_CONST_VAL_NON_CONST_INIT);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
    if (p.init) |*init| {
        if (!isConstInitializer(self, init)) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "`const val` initializer must be a compile-time constant: `{s}`",
                .{p.name.name},
            );
            var d = Diagnostic.err(msg, init.span());
            _ = d.withCode(codes.TYPE_CONST_VAL_NON_CONST_INIT);
            try self.diagnostics.emit(self.allocator, d);
        }
    } else {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "`const val` requires an initializer: `{s}`",
            .{p.name.name},
        );
        var d = Diagnostic.err(msg, p.name.span);
        _ = d.withCode(codes.TYPE_CONST_VAL_NON_CONST_INIT);
        try self.diagnostics.emit(self.allocator, d);
    }
}

/// Structural check: is this expression composed solely of literals,
/// references to other `const val` declarations, arithmetic / comparison /
/// string-concat operators over const-capable types, and string templates
/// whose interpolated parts are also const?
pub fn isConstInitializer(self: *const Checker, e: *const Expr) bool {
    switch (e.*) {
        .IntLit, .FloatLit, .BoolLit, .CharLit => return true,
        .NullLit => return false,
        .StringTemplate => |st| {
            for (st.parts) |part| {
                const ok = switch (part) {
                    .Text => true,
                    .ShortInterp => |id| isConstRef(self, id.name),
                    .Interp => |inner| isConstInitializer(self, inner),
                };
                if (!ok) return false;
            }
            return true;
        },
        .Path => |p| {
            if (p.segments.len == 1) {
                return isConstRef(self, p.segments[0].name);
            }
            // Permit qualified references when the leaf is a const val on a
            // known class (best-effort: trailing segment).
            return isConstRef(self, p.segments[p.segments.len - 1].name);
        },
        .Member => |m| {
            if (m.safe) return false;
            // Access expressions to enum entries are constant expressions.
            // Recognize `EnumClass.ENTRY`.
            if (m.receiver.* == .Path) {
                const segs = m.receiver.Path.segments;
                if (segs.len == 1) {
                    if (root.classNamed(self, segs[0].name)) |info| {
                        if (info.is_enum) return true;
                    }
                    // Builtin primitive companion constants (`Long.MAX_VALUE`,
                    // `Int.MIN_VALUE`, `Double.POSITIVE_INFINITY`,
                    // `*.SIZE_BITS`, …) are compile-time constants.
                    if (isPrimitiveCompanionHead(segs[0].name)) return true;
                }
            }
            return isConstInitializer(self, m.receiver) and isConstRef(self, m.name.name);
        },
        .Unary => |u| {
            return (u.op == .Neg or u.op == .Pos or u.op == .Not) and isConstInitializer(self, u.expr);
        },
        .Binary => |b| {
            const op_ok = switch (b.op) {
                .Add, .Sub, .Mul, .Div, .Rem, .Eq, .Neq, .Lt, .Le, .Gt, .Ge, .And, .Or => true,
                else => false,
            };
            return op_ok and isConstInitializer(self, b.lhs) and isConstInitializer(self, b.rhs);
        },
        // Integer bitwise/shift infix functions are compile-time constant in
        // Kotlin (`const val M = 1 shl 30`, `Long.MAX_VALUE / MS`): they
        // parse as an infix call `a shl b` or a member call `a.shl(b)`.
        .Call => |c| {
            switch (c.callee.*) {
                .Path => |segs| {
                    if (c.is_infix and segs.segments.len == 1 and isConstInfix(segs.segments[0].name)) {
                        for (c.args) |*a| {
                            if (!isConstInitializer(self, a)) return false;
                        }
                        return true;
                    }
                    return false;
                },
                .Member => |m| {
                    if (!m.safe and isConstInfix(m.name.name)) {
                        if (!isConstInitializer(self, m.receiver)) return false;
                        for (c.args) |*a| {
                            if (!isConstInitializer(self, a)) return false;
                        }
                        return true;
                    }
                    return false;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// An annotation type's primary-ctor parameter default values must be
/// compile-time constant. Extends `isConstInitializer` with the forms
/// specific to annotation arguments: `T::class` literals, `arrayOf(...)`
/// of constants, and bare enum-entry references.
pub fn isAnnotationParamDefaultConst(self: *const Checker, e: *const Expr) bool {
    if (isConstInitializer(self, e)) return true;
    switch (e.*) {
        // `T::class` class literal.
        .MemberRef => |m| return std.mem.eql(u8, m.name.name, "class"),
        // `arrayOf(...)` / `intArrayOf` / similar primitive-array builders.
        .Call => |c| {
            if (c.callee.* == .Path) {
                const segs = c.callee.Path.segments;
                const leaf = segs[segs.len - 1].name;
                if (isArrayBuilder(leaf)) {
                    for (c.args) |*a| {
                        if (!isAnnotationParamDefaultConst(self, a)) return false;
                    }
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn isConstRef(self: *const Checker, name: []const u8) bool {
    if (self.frames.items[0].bindings.get(name)) |b| {
        if (!b.mutable) {
            return switch (b.ty) {
                .Int, .Long, .Short, .Byte, .Float, .Double, .Boolean, .Char, .String => true,
                else => false,
            };
        }
    }
    return false;
}

fn checkValueClassModifiers(self: *Checker, c: *const Class) Allocator.Error!void {
    const sp = c.name.span;
    if (c.is_open) try emitValueClassShape(self, sp, "`value class {s}` must be final (cannot be `open`)", c.name.name);
    if (c.is_abstract) try emitValueClassShape(self, sp, "`value class {s}` cannot be `abstract`", c.name.name);
    if (c.is_sealed) try emitValueClassShape(self, sp, "`value class {s}` cannot be `sealed`", c.name.name);
    if (c.is_inner) try emitValueClassShape(self, sp, "`value class {s}` cannot be `inner`", c.name.name);
    if (c.is_data) try emitValueClassShape(self, sp, "`value class {s}` cannot be `data`", c.name.name);
    if (c.is_enum) try emitValueClassShape(self, sp, "`value class {s}` cannot be `enum`", c.name.name);
    if (c.is_annotation) try emitValueClassShape(self, sp, "`value class {s}` cannot be `annotation`", c.name.name);
    if (c.init_blocks.len != 0) try emitValueClassShape(self, sp, "`value class {s}` cannot have `init` blocks", c.name.name);
}

fn emitValueClassShape(self: *Checker, sp: Span, comptime fmt: []const u8, name: []const u8) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(self.allocator, fmt, .{name});
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_VALUE_CLASS_SHAPE);
    try self.diagnostics.emit(self.allocator, d);
}

fn emitValueClassShape2(self: *Checker, sp: Span, comptime fmt: []const u8, a0: []const u8, a1: []const u8) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(self.allocator, fmt, .{ a0, a1 });
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_VALUE_CLASS_SHAPE);
    try self.diagnostics.emit(self.allocator, d);
}

pub fn checkValueClass(self: *Checker, c: *const Class) Allocator.Error!void {
    const sp = c.name.span;
    try checkValueClassModifiers(self, c);
    for (c.secondary_ctors) |*sc| {
        if (sc.body) |b| {
            if (b.stmts.len != 0) {
                try emitValueClassShape(self, sp, "`value class {s}` secondary constructors must have empty bodies", c.name.name);
                break;
            }
        }
    }
    var immutable_count: usize = 0;
    var mutable_count: usize = 0;
    for (c.primary_params) |*p| {
        if (p.property) |is_var| {
            if (is_var) mutable_count += 1 else immutable_count += 1;
        }
    }
    if (mutable_count > 0) {
        try emitValueClassShape(self, sp, "`value class {s}` cannot declare a `var` primary-constructor property", c.name.name);
    }
    if (immutable_count != 1) {
        try emitValueClassShape(self, sp, "`value class {s}` must declare exactly one `val` primary-constructor property", c.name.name);
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Property => |p| {
                // Body properties with a backing field are forbidden: an
                // initializer or `lateinit` implies a backing field. A body
                // property with only a `get()` accessor is allowed.
                const has_backing_field = p.init != null or p.is_lateinit or p.delegate != null;
                if (has_backing_field) {
                    try emitValueClassShape(self, sp, "`value class {s}` cannot declare body properties with backing fields", c.name.name);
                }
            },
            .Function => |*f| {
                if (f.is_override and (std.mem.eql(u8, f.name.name, "equals") or std.mem.eql(u8, f.name.name, "hashCode"))) {
                    try emitValueClassShape2(self, sp, "`value class {s}` cannot override `{s}`", c.name.name, f.name.name);
                }
            },
            else => {},
        }
    }
    for (c.supertypes) |*s| {
        if (root.classNamed(self, s.name.name)) |info| {
            if (!info.is_interface) {
                try emitValueClassShape2(self, sp, "`value class {s}` cannot extend non-interface supertype `{s}`", c.name.name, s.name.name);
            }
        }
    }
}

fn emitAnnotationClassShape(self: *Checker, sp: Span, comptime fmt: []const u8, name: []const u8) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(self.allocator, fmt, .{name});
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_ANNOTATION_CLASS_SHAPE);
    try self.diagnostics.emit(self.allocator, d);
}

fn checkAnnotationClassShape(self: *Checker, c: *const Class) Allocator.Error!void {
    const sp = c.name.span;
    if (c.is_open) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `open`", c.name.name);
    if (c.is_abstract) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `abstract`", c.name.name);
    if (c.is_sealed) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `sealed`", c.name.name);
    if (c.is_data) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `data`", c.name.name);
    if (c.is_enum) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `enum`", c.name.name);
    if (c.is_inner) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `inner`", c.name.name);
    if (c.is_value) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot be `value`", c.name.name);
    if (c.secondary_ctors.len != 0) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot have secondary constructors", c.name.name);
    if (c.init_blocks.len != 0) try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot have `init` blocks", c.name.name);
    if (c.members.len != 0) {
        // A bare companion object inside an annotation class is permitted by
        // kotlinc; everything else is rejected.
        for (c.members) |*m| {
            const allowed = m.* == .Class and m.Class.is_companion;
            if (!allowed) {
                try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot have body declarations", c.name.name);
                break;
            }
        }
    }
    if (c.supertypes.len != 0) {
        try emitAnnotationClassShape(self, sp, "`annotation class {s}` cannot declare a supertype", c.name.name);
    }
}

pub fn checkAnnotationClass(self: *Checker, c: *const Class) Allocator.Error!void {
    try checkAnnotationClassShape(self, c);
    for (c.primary_params) |*p| {
        if (p.default) |*default| {
            if (!isAnnotationParamDefaultConst(self, default)) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "annotation-class parameter `{s}` default value must be a compile-time constant",
                    .{p.name.name},
                );
                var d = Diagnostic.err(msg, default.span());
                _ = d.withCode(codes.TYPE_ANNOTATION_PARAM_DEFAULT_NOT_CONST);
                try self.diagnostics.emit(self.allocator, d);
            }
        }
        const head = p.ty.name.name;
        const allowed_head = isAnnotationParamType(head) or
            self.annotation_class_names.contains(head) or
            self.enum_class_names.contains(head);
        if (!allowed_head or p.ty.nullable) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "annotation-class parameter `{s}` has unsupported type `{s}`",
                .{ p.name.name, p.ty.name.name },
            );
            var d = Diagnostic.err(msg, p.ty.span);
            _ = d.withCode(codes.TYPE_ANNOTATION_PARAM_TYPE);
            try self.diagnostics.emit(self.allocator, d);
        } else if (std.mem.eql(u8, p.ty.name.name, "Array")) {
            // Array element type is restricted to the same allowed-type set
            // (primitives / String / KClass / annotation / enum). Look into
            // the first type-argument; reject anything not recognised. `out
            // T` projections are unwrapped via `TypeArg.ty`.
            if (p.ty.type_args.len > 0) {
                const arg = p.ty.type_args[0];
                const inner = arg.ty.name.name;
                const inner_ok = isAnnotationParamType(inner) or
                    self.annotation_class_names.contains(inner) or
                    self.enum_class_names.contains(inner);
                if (!inner_ok or arg.ty.nullable) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "annotation-class parameter `{s}` has `Array` of unsupported element type `{s}`",
                        .{ p.name.name, inner },
                    );
                    var d = Diagnostic.err(msg, arg.ty.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_PARAM_TYPE);
                    try self.diagnostics.emit(self.allocator, d);
                }
            }
        }
    }
}

/// A declaration marked with an annotation that itself carries
/// `@RequiresOptIn(message, level)` requires every reference site to opt
/// in via `@OptIn(MarkerClass::class)` on an enclosing declaration.
/// Reference sites without an active opt-in get a warning (default) or
/// error (level = Level.ERROR).
pub fn checkOptInReferences(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    const a = self.allocator;
    var markers = std.StringHashMap(OptInMarker).init(a);
    defer markers.deinit();
    var classes: std.ArrayList(*const Class) = .empty;
    defer classes.deinit(a);
    try collectAnnotationClasses(a, file.decls, &classes);
    for (classes.items) |c| {
        if (try parseRequiresOptIn(a, c.annotations)) |info| {
            try markers.put(c.name.name, info);
        }
    }
    if (markers.count() == 0) return;
    var required = std.StringHashMap([]const []const u8).init(a);
    defer {
        var it = required.valueIterator();
        while (it.next()) |v| a.free(v.*);
        required.deinit();
    }
    try collectRequiredOptIns(a, file.decls, &markers, &required);
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(a);
    var scope: std.ArrayList([]const u8) = .empty;
    defer scope.deinit(a);
    for (file.decls) |*d| {
        try walkDeclForOptIn(self, d, &markers, &required, &scope, &diags);
    }
    for (diags.items) |d| {
        try self.diagnostics.emit(a, d);
    }
}

/// Emit a warning / error / hidden diagnostic at every bare-name reference
/// to a top-level declaration carrying
/// `@Deprecated(message, replaceWith, level)`. Only top-level functions /
/// properties / classes / typealiases are tracked; member accesses are not
/// flagged.
pub fn checkDeprecatedReferences(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    const a = self.allocator;
    var info = std.StringHashMap(DeprecationInfo).init(a);
    defer info.deinit();
    try collectDeprecationInfo(a, file.decls, &info);
    if (info.count() == 0) return;
    // The tracker is keyed by bare name, with no overload resolution: if a
    // non-deprecated declaration shares the name (`append` has one
    // deprecated overload among many live ones), a use site cannot be
    // attributed to the deprecated one, so the name is dropped rather than
    // flagging every call.
    var clean = std.StringHashMap(void).init(a);
    defer clean.deinit();
    try collectNonDeprecatedNames(a, file.decls, &clean);
    {
        var it = clean.keyIterator();
        while (it.next()) |name| {
            _ = info.remove(name.*);
        }
    }
    if (info.count() == 0) return;
    var diags: std.ArrayList(Diagnostic) = .empty;
    defer diags.deinit(a);
    for (file.decls) |*d| {
        try walkDeclForDeprecation(self, d, &info, &diags);
    }
    for (diags.items) |d| {
        try self.diagnostics.emit(a, d);
    }
}

/// Enforce `@Target` and `@Repeatable` on annotation applications across
/// the whole file.
pub fn checkAnnotationApplications(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    const a = self.allocator;
    var meta = std.StringHashMap(AnnotationMeta).init(a);
    defer {
        var it = meta.valueIterator();
        while (it.next()) |m| {
            if (m.targets) |t| a.free(t);
        }
        meta.deinit();
    }
    var classes: std.ArrayList(*const Class) = .empty;
    defer classes.deinit(a);
    try collectAnnotationClasses(a, file.decls, &classes);
    for (classes.items) |c| {
        var m = AnnotationMeta{ .repeatable = false, .targets = null };
        for (c.annotations) |*ann| {
            const leaf = if (ann.path.len > 0) ann.path[ann.path.len - 1].name else "";
            if (std.mem.eql(u8, leaf, "Repeatable")) {
                m.repeatable = true;
            } else if (std.mem.eql(u8, leaf, "Target")) {
                var targets: std.ArrayList(AnnotationTarget) = .empty;
                for (ann.args) |*arg| {
                    try extractAnnotationTargets(a, arg, &targets);
                }
                m.targets = try targets.toOwnedSlice(a);
            }
        }
        try meta.put(c.name.name, m);
    }
    try annotationWalkFile(self, &meta, file);
}

/// An annotation type cannot reference itself, either directly or
/// indirectly (through another annotation type, or through `Array<T>`
/// whose element is an annotation type).
pub fn checkAnnotationCycles(self: *Checker, file: *const KotlinFile) Allocator.Error!void {
    const a = self.allocator;
    var classes: std.ArrayList(*const Class) = .empty;
    defer classes.deinit(a);
    try collectAnnotationClasses(a, file.decls, &classes);
    if (classes.items.len == 0) return;
    var name_set = std.StringHashMap(void).init(a);
    defer name_set.deinit();
    for (classes.items) |c| try name_set.put(c.name.name, {});
    var deps = std.StringHashMap([]const []const u8).init(a);
    defer {
        var it = deps.valueIterator();
        while (it.next()) |v| a.free(v.*);
        deps.deinit();
    }
    var spans = std.StringHashMap(Span).init(a);
    defer spans.deinit();
    for (classes.items) |c| {
        try spans.put(c.name.name, c.name.span);
        var out: std.ArrayList([]const u8) = .empty;
        for (c.primary_params) |*p| {
            const head = p.ty.name.name;
            if (name_set.contains(head)) {
                try out.append(a, head);
            } else if (std.mem.eql(u8, head, "Array") and p.ty.type_args.len > 0) {
                const inner = p.ty.type_args[0].ty.name.name;
                if (name_set.contains(inner)) {
                    try out.append(a, inner);
                }
            }
        }
        try deps.put(c.name.name, try out.toOwnedSlice(a));
    }
    for (classes.items) |c| {
        const start = c.name.name;
        var seen = std.StringHashMap(void).init(a);
        defer seen.deinit();
        if (try annotationReachesSelf(a, start, start, &deps, &seen)) {
            const sp = spans.get(start).?;
            const msg = try std.fmt.allocPrint(
                a,
                "annotation class `{s}` cannot reference itself, directly or transitively",
                .{start},
            );
            var d = Diagnostic.err(msg, sp);
            _ = d.withCode(codes.TYPE_ANNOTATION_CYCLE);
            try self.diagnostics.emit(a, d);
        }
    }
}

pub fn checkDefinitelyNonNullDecl(
    self: *Checker,
    d: *const Decl,
    tp_scope: *std.ArrayList(std.StringHashMap(void)),
) Allocator.Error!void {
    const a = self.allocator;
    switch (d.*) {
        .Function => |*f| {
            var frame = std.StringHashMap(void).init(a);
            for (f.type_params) |*tp| try frame.put(tp.name.name, {});
            try tp_scope.append(a, frame);
            if (f.receiver_type) |*r| try checkDnnTyperef(self, r, tp_scope.items);
            for (f.params) |*p| try checkDnnTyperef(self, &p.ty, tp_scope.items);
            if (f.return_type) |*rt| try checkDnnTyperef(self, rt, tp_scope.items);
            if (f.body) |body| {
                switch (body) {
                    .Block => |b| try walkBlockForDnn(self, &b, tp_scope),
                    .Expr => |e| try walkExprForDnn(self, &e, tp_scope),
                }
            }
            var popped = tp_scope.pop().?;
            popped.deinit();
        },
        .Class => |*c| {
            var frame = std.StringHashMap(void).init(a);
            for (c.type_params) |*tp| try frame.put(tp.name.name, {});
            try tp_scope.append(a, frame);
            for (c.primary_params) |*cp| try checkDnnTyperef(self, &cp.ty, tp_scope.items);
            for (c.members) |*m| try checkDefinitelyNonNullDecl(self, m, tp_scope);
            var popped = tp_scope.pop().?;
            popped.deinit();
        },
        .Property => |p| {
            if (p.ty) |*t| try checkDnnTyperef(self, t, tp_scope.items);
            if (p.init) |*init| try walkExprForDnn(self, init, tp_scope);
        },
        .Object => |*o| {
            for (o.members) |*m| try checkDefinitelyNonNullDecl(self, m, tp_scope);
        },
        .TypeAlias => |*ta| {
            var frame = std.StringHashMap(void).init(a);
            for (ta.type_params) |*tp| try frame.put(tp.name.name, {});
            try tp_scope.append(a, frame);
            try checkDnnTyperef(self, &ta.target, tp_scope.items);
            var popped = tp_scope.pop().?;
            popped.deinit();
        },
    }
}

pub fn checkDnnTyperef(self: *Checker, t: *const TypeRef, tp_scope: []const std.StringHashMap(void)) Allocator.Error!void {
    if (t.definitely_non_null) {
        var is_tp = false;
        for (tp_scope) |*s| {
            if (s.contains(t.name.name)) {
                is_tp = true;
                break;
            }
        }
        if (!is_tp) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "definitely non-nullable type `{s} & Any` is only allowed when `{s}` is a type parameter",
                .{ t.name.name, t.name.name },
            );
            var d = Diagnostic.err(msg, t.span);
            _ = d.withCode(codes.TYPE_DEFINITELY_NON_NULL_NOT_TYPE_PARAM);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
    for (t.type_args) |*ta| {
        if (!ta.is_star) try checkDnnTyperef(self, &ta.ty, tp_scope);
    }
    if (t.function) |f| {
        if (f.receiver) |*r| try checkDnnTyperef(self, r, tp_scope);
        for (f.params) |*p| try checkDnnTyperef(self, p, tp_scope);
        try checkDnnTyperef(self, &f.ret, tp_scope);
    }
}

pub fn walkBlockForDnn(self: *Checker, b: *const Block, tp_scope: *std.ArrayList(std.StringHashMap(void))) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Decl => |*d| try checkDefinitelyNonNullDecl(self, d, tp_scope),
            .Expr => |*e| try walkExprForDnn(self, e, tp_scope),
            .Assign => |*a| try walkExprForDnn(self, &a.value, tp_scope),
            .DestructuringDecl => |*dd| try walkExprForDnn(self, &dd.init, tp_scope),
        }
    }
}

pub fn walkExprForDnn(self: *Checker, e: *const Expr, tp_scope: *std.ArrayList(std.StringHashMap(void))) Allocator.Error!void {
    switch (e.*) {
        .Block => |*b| try walkBlockForDnn(self, b, tp_scope),
        .If => |i| {
            try walkExprForDnn(self, i.cond, tp_scope);
            try walkExprForDnn(self, i.then_branch, tp_scope);
            if (i.else_branch) |eb| try walkExprForDnn(self, eb, tp_scope);
        },
        .While => |w| {
            try walkExprForDnn(self, w.cond, tp_scope);
            try walkExprForDnn(self, w.body, tp_scope);
        },
        .DoWhile => |w| {
            if (w.body) |b| try walkExprForDnn(self, b, tp_scope);
            try walkExprForDnn(self, w.cond, tp_scope);
        },
        .For => |f| {
            try walkExprForDnn(self, f.iter, tp_scope);
            try walkExprForDnn(self, f.body, tp_scope);
        },
        .Lambda => |l| try walkBlockForDnn(self, &l.body, tp_scope),
        .IsCheck => |x| try checkDnnTyperef(self, &x.ty, tp_scope.items),
        .When => |w| {
            if (w.subject) |s| try walkExprForDnn(self, s, tp_scope);
            if (w.subject_binding) |b| {
                if (b.ty) |*t| try checkDnnTyperef(self, t, tp_scope.items);
            }
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .IsType, .NotIsType => |*t| try checkDnnTyperef(self, t, tp_scope.items),
                        .Value, .InRange, .NotInRange => |*ex| try walkExprForDnn(self, ex, tp_scope),
                        .Else => {},
                    }
                }
                try walkExprForDnn(self, &br.body, tp_scope);
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try checkDefinitelyNonNullDecl(self, m, tp_scope);
        },
        else => {},
    }
}

// ---- Generics + inline diagnostics --------------------------------------

pub fn checkGenericsDecl(self: *Checker, d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try checkGenericsFunction(self, f),
        .Class => |*c| try checkGenericsClass(self, c),
        .Property, .Object, .TypeAlias => {},
    }
}

pub fn checkGenericsFunction(self: *Checker, f: *const Function) Allocator.Error!void {
    // T0023 — reified outside inline
    for (f.type_params) |*tp| {
        if (tp.is_reified and !f.is_inline) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "type parameter `{s}` is `reified` but enclosing function is not `inline`",
                .{tp.name.name},
            );
            var d = Diagnostic.err(msg, tp.span);
            _ = d.withCode(codes.TYPE_REIFIED_REQUIRES_INLINE);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
    // T0026 — crossinline/noinline outside inline
    for (f.params) |*p| {
        if ((p.is_crossinline or p.is_noinline) and !f.is_inline) {
            const which: []const u8 = if (p.is_crossinline) "crossinline" else "noinline";
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "`{s}` parameter `{s}` is only allowed on an `inline` function",
                .{ which, p.name.name },
            );
            var d = Diagnostic.err(msg, p.name.span);
            _ = d.withCode(codes.TYPE_INLINE_MODIFIER_OUTSIDE_INLINE);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
    // T0025 — vararg misuse
    var vararg_idxs: std.ArrayList(usize) = .empty;
    defer vararg_idxs.deinit(self.allocator);
    for (f.params, 0..) |*p, i| {
        if (p.is_vararg) try vararg_idxs.append(self.allocator, i);
    }
    if (vararg_idxs.items.len > 1) {
        for (vararg_idxs.items[1..]) |i| {
            var d = Diagnostic.err(
                "a function may declare at most one `vararg` parameter",
                f.params[i].name.span,
            );
            _ = d.withCode(codes.TYPE_VARARG_MISUSE);
            try self.diagnostics.emit(self.allocator, d);
        }
    }
    if (vararg_idxs.items.len > 0) {
        const i = vararg_idxs.items[0];
        // Following params are allowed only if they have defaults.
        var j = i + 1;
        while (j < f.params.len) : (j += 1) {
            const p = &f.params[j];
            if (p.default == null) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "parameter `{s}` follows a `vararg` and must have a default value",
                    .{p.name.name},
                );
                var d = Diagnostic.err(msg, p.name.span);
                _ = d.withCode(codes.TYPE_VARARG_MISUSE);
                try self.diagnostics.emit(self.allocator, d);
            }
        }
    }
    // Recurse into nested functions/classes inside the body.
    if (f.body) |body| {
        switch (body) {
            .Block => |b| try walkBlockForGenerics(self, &b),
            .Expr => |e| try walkExprForGenerics(self, &e),
        }
    }
}

pub fn checkGenericsClass(self: *Checker, c: *const Class) Allocator.Error!void {
    // T0024 — declaration-site variance positions on member functions.
    for (c.type_params) |*tp| {
        if (tp.variance == .Invariant) continue;
        for (c.members) |*m| {
            if (m.* == .Function) {
                const f = &m.Function;
                // A `private` member is only accessible via `this`, so its
                // parameter / return positions are not observable through the
                // public API. Variance rules don't apply.
                if (f.visibility == .Private) continue;
                try checkMemberVariancePositions(self, tp.name.name, tp.variance, f);
            }
        }
    }
    for (c.members) |*m| {
        try checkGenericsDecl(self, m);
    }
}

pub fn checkMemberVariancePositions(
    self: *Checker,
    param: []const u8,
    variance: ast.Variance,
    f: *const Function,
) Allocator.Error!void {
    // A member that declares its own type parameter of the same name shadows
    // the class parameter inside its signature, so the class's variance does
    // not constrain it.
    for (f.type_params) |*tp| {
        if (std.mem.eql(u8, tp.name.name, param)) return;
    }
    // For `out T`: T must not appear in input positions.
    // For `in T`: T must not appear in output positions.
    switch (variance) {
        .Out => {
            for (f.params) |*p| {
                if (helpers.typeRefUses(&p.ty, param)) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "type parameter `{s}` is `out` but appears in an input position of `{s}`",
                        .{ param, f.name.name },
                    );
                    var d = Diagnostic.err(msg, p.ty.span);
                    _ = d.withCode(codes.TYPE_DECLARATION_VARIANCE_VIOLATION);
                    try self.diagnostics.emit(self.allocator, d);
                }
            }
        },
        .In => {
            if (f.return_type) |*rt| {
                if (helpers.typeRefUses(rt, param)) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "type parameter `{s}` is `in` but appears in an output position of `{s}`",
                        .{ param, f.name.name },
                    );
                    var d = Diagnostic.err(msg, rt.span);
                    _ = d.withCode(codes.TYPE_DECLARATION_VARIANCE_VIOLATION);
                    try self.diagnostics.emit(self.allocator, d);
                }
            }
        },
        .Invariant => {},
    }
}

pub fn walkBlockForGenerics(self: *Checker, b: *const Block) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Decl => |*d| try checkGenericsDecl(self, d),
            .Expr => |*e| try walkExprForGenerics(self, e),
            .Assign => |*a| try walkExprForGenerics(self, &a.value),
            .DestructuringDecl => |*dd| try walkExprForGenerics(self, &dd.init),
        }
    }
}

pub fn walkExprForGenerics(self: *Checker, e: *const Expr) Allocator.Error!void {
    switch (e.*) {
        .Block => |*b| try walkBlockForGenerics(self, b),
        .If => |i| {
            try walkExprForGenerics(self, i.cond);
            try walkExprForGenerics(self, i.then_branch);
            if (i.else_branch) |eb| try walkExprForGenerics(self, eb);
        },
        .While => |w| {
            try walkExprForGenerics(self, w.cond);
            try walkExprForGenerics(self, w.body);
        },
        .DoWhile => |w| {
            if (w.body) |b| try walkExprForGenerics(self, b);
            try walkExprForGenerics(self, w.cond);
        },
        .For => |f| {
            try walkExprForGenerics(self, f.iter);
            try walkExprForGenerics(self, f.body);
        },
        .Lambda => |l| try walkBlockForGenerics(self, &l.body),
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try checkGenericsDecl(self, m);
        },
        else => {},
    }
}

// ============================================================================
// Annotation collectors / walkers.
//
// These mirror the standalone collectors that the multi-phase driver consumes
// from the annotation-check module. They are private to the driver and
// operate over read-only views of the AST.
// ============================================================================

const OptInLevel = enum { Warning, Error };

const OptInMarker = struct {
    level: OptInLevel,
    message: ?[]const u8,
};

const DeprecationLevel = enum { Warning, Error, Hidden };

const DeprecationInfo = struct {
    level: DeprecationLevel,
    message: ?[]const u8,
};

const AnnotationTarget = enum {
    Class,
    AnnotationClass,
    TypeParameter,
    Property,
    Field,
    LocalVariable,
    ValueParameter,
    Constructor,
    Function,
    PropertyGetter,
    PropertySetter,
    Type,
    Expression,
    File,
    TypeAlias,

    fn fromName(name: []const u8) ?AnnotationTarget {
        const map = .{
            .{ "CLASS", AnnotationTarget.Class },
            .{ "ANNOTATION_CLASS", AnnotationTarget.AnnotationClass },
            .{ "TYPE_PARAMETER", AnnotationTarget.TypeParameter },
            .{ "PROPERTY", AnnotationTarget.Property },
            .{ "FIELD", AnnotationTarget.Field },
            .{ "LOCAL_VARIABLE", AnnotationTarget.LocalVariable },
            .{ "VALUE_PARAMETER", AnnotationTarget.ValueParameter },
            .{ "CONSTRUCTOR", AnnotationTarget.Constructor },
            .{ "FUNCTION", AnnotationTarget.Function },
            .{ "PROPERTY_GETTER", AnnotationTarget.PropertyGetter },
            .{ "PROPERTY_SETTER", AnnotationTarget.PropertySetter },
            .{ "TYPE", AnnotationTarget.Type },
            .{ "EXPRESSION", AnnotationTarget.Expression },
            .{ "FILE", AnnotationTarget.File },
            .{ "TYPEALIAS", AnnotationTarget.TypeAlias },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    fn display(self: AnnotationTarget) []const u8 {
        return switch (self) {
            .Class => "CLASS",
            .AnnotationClass => "ANNOTATION_CLASS",
            .TypeParameter => "TYPE_PARAMETER",
            .Property => "PROPERTY",
            .Field => "FIELD",
            .LocalVariable => "LOCAL_VARIABLE",
            .ValueParameter => "VALUE_PARAMETER",
            .Constructor => "CONSTRUCTOR",
            .Function => "FUNCTION",
            .PropertyGetter => "PROPERTY_GETTER",
            .PropertySetter => "PROPERTY_SETTER",
            .Type => "TYPE",
            .Expression => "EXPRESSION",
            .File => "FILE",
            .TypeAlias => "TYPEALIAS",
        };
    }
};

const AnnotationMeta = struct {
    repeatable: bool,
    targets: ?[]const AnnotationTarget,
};

fn isAnnotationParamType(name: []const u8) bool {
    if (helpers.isPrimitiveTypeName(name)) return true;
    const names = [_][]const u8{ "String", "KClass", "kotlin.reflect.KClass", "Array" };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn annotationSimpleName(a: *const Annotation) []const u8 {
    if (a.path.len > 0) return a.path[a.path.len - 1].name;
    return "";
}

fn collectAnnotationClasses(allocator: Allocator, decls: []const Decl, out: *std.ArrayList(*const Class)) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            if (c.is_annotation) try out.append(allocator, c);
            try collectAnnotationClasses(allocator, c.members, out);
        }
    }
}

fn collectAllClasses(allocator: Allocator, decls: []const Decl, out: *std.ArrayList(*const Class)) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            try out.append(allocator, c);
            try collectAllClasses(allocator, c.members, out);
        }
    }
}

fn collectEnumClasses(allocator: Allocator, decls: []const Decl, out: *std.ArrayList(*const Class)) Allocator.Error!void {
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            if (c.is_enum) try out.append(allocator, c);
            try collectEnumClasses(allocator, c.members, out);
        }
    }
}

fn annotationReachesSelf(
    allocator: Allocator,
    start: []const u8,
    current: []const u8,
    deps: *const std.StringHashMap([]const []const u8),
    seen: *std.StringHashMap(void),
) Allocator.Error!bool {
    if ((try seen.getOrPut(current)).found_existing) return false;
    const targets = deps.get(current) orelse return false;
    for (targets) |t| {
        if (std.mem.eql(u8, t, start)) return true;
        if (try annotationReachesSelf(allocator, start, t, deps, seen)) return true;
    }
    return false;
}

fn extractAnnotationTargets(allocator: Allocator, e: *const Expr, out: *std.ArrayList(AnnotationTarget)) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len > 0) {
                if (AnnotationTarget.fromName(p.segments[p.segments.len - 1].name)) |t| {
                    try out.append(allocator, t);
                }
            }
        },
        .Member => |m| {
            if (AnnotationTarget.fromName(m.name.name)) |t| {
                try out.append(allocator, t);
            }
        },
        else => {},
    }
}

// === @Target / @Repeatable walk ===========================================

/// Whether a property declaration is a class member or top-level; drives
/// the target description in `WRONG_ANNOTATION_TARGET` messages.
const PropContainer = enum { TopLevel, Member };

fn annotationWalkFile(self: *Checker, meta: *const std.StringHashMap(AnnotationMeta), file: *const KotlinFile) Allocator.Error!void {
    try annotationCheckSet(self, meta, &.{}, .File);
    for (file.decls) |*d| {
        try annotationWalkDecl(self, meta, d, .TopLevel);
    }
}

fn annotationWalkDecl(self: *Checker, meta: *const std.StringHashMap(AnnotationMeta), d: *const Decl, container: PropContainer) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try annotationWalkFunction(self, meta, f),
        .Property => |p| try annotationWalkProperty(self, meta, p, container),
        .Class => |*c| try annotationWalkClass(self, meta, c),
        .Object => |*o| {
            for (o.members) |*m| try annotationWalkDecl(self, meta, m, .Member);
        },
        .TypeAlias => |*a| {
            try annotationCheckSet(self, meta, a.annotations, .TypeAlias);
        },
    }
}

fn annotationWalkFunction(self: *Checker, meta: *const std.StringHashMap(AnnotationMeta), f: *const Function) Allocator.Error!void {
    try annotationCheckSet(self, meta, f.annotations, .Function);
    for (f.type_params) |*tp| try annotationCheckSet(self, meta, tp.annotations, .TypeParameter);
    for (f.params) |*p| try annotationCheckSet(self, meta, p.annotations, .ValueParameter);
}

fn annotationWalkProperty(self: *Checker, meta: *const std.StringHashMap(AnnotationMeta), p: *const Property, container: PropContainer) Allocator.Error!void {
    try checkPropertyAnnotationSet(self, meta, p.annotations, .{
        .is_var = p.mutable,
        .has_backing_field = annotationShapeHasBackingField(p),
        .is_delegated = p.delegate != null,
    }, container);
    if (p.getter) |g| try annotationCheckSet(self, meta, g.annotations, .PropertyGetter);
    if (p.setter) |s| try annotationCheckSet(self, meta, s.annotations, .PropertySetter);
}

fn annotationWalkClass(self: *Checker, meta: *const std.StringHashMap(AnnotationMeta), c: *const Class) Allocator.Error!void {
    const site: AnnotationTarget = if (c.is_annotation) .AnnotationClass else .Class;
    try annotationCheckSet(self, meta, c.annotations, site);
    for (c.type_params) |*tp| try annotationCheckSet(self, meta, tp.annotations, .TypeParameter);
    for (c.primary_params) |*p| {
        if (p.property) |is_var| {
            try checkPropertyAnnotationSet(self, meta, p.annotations, .{
                .is_ctor_property = true,
                .is_var = is_var,
                .has_backing_field = true,
                .in_annotation_class = c.is_annotation,
            }, .Member);
        } else {
            try annotationCheckSetMsg(self, meta, p.annotations, .ValueParameter, "constructor parameters without corresponding property (consider adding val/var)");
        }
    }
    for (c.secondary_ctors) |*sc| {
        try annotationCheckSet(self, meta, sc.annotations, .Constructor);
        for (sc.params) |*p| try annotationCheckSet(self, meta, p.annotations, .ValueParameter);
    }
    for (c.enum_entries) |*e| try annotationCheckSet(self, meta, e.annotations, .Property);
    for (c.members) |*m| try annotationWalkDecl(self, meta, m, .Member);
}

/// Backing-field presence as target assignment sees it: an explicit
/// `field` clause always supplies one; a delegated / abstract / expect
/// property never has one; otherwise the accessor-shape rule
/// (`propertyHasBackingField`) decides.
fn annotationShapeHasBackingField(p: *const Property) bool {
    if (p.delegate != null or p.is_abstract or p.is_expect) return false;
    if (p.explicit_field != null) return true;
    return propertyHasBackingField(p);
}

fn annotationCheckSet(
    self: *Checker,
    meta: *const std.StringHashMap(AnnotationMeta),
    anns: []const Annotation,
    site: AnnotationTarget,
) Allocator.Error!void {
    const all_msg: []const u8 = switch (site) {
        .ValueParameter => "value parameters, only properties are allowed",
        .LocalVariable => "local properties, only member or top-level properties are allowed",
        else => "elements other than properties",
    };
    try annotationCheckSetMsg(self, meta, anns, site, all_msg);
}

/// The plain (non-property-declaration) annotation-set check: `@Target`
/// applicability against the declaration site kind, `@all:` rejection
/// with the site-specific message, and per-site repetition.
fn annotationCheckSetMsg(
    self: *Checker,
    meta: *const std.StringHashMap(AnnotationMeta),
    anns: []const Annotation,
    site: AnnotationTarget,
    all_msg: []const u8,
) Allocator.Error!void {
    const a = self.allocator;
    var counts = std.StringHashMap(Span).init(a);
    defer counts.deinit();
    for (anns) |*ann| {
        const leaf = if (ann.path.len > 0) ann.path[ann.path.len - 1].name else continue;
        if (ann.use_site != null and ann.use_site.? == .All) {
            try emitInapplicableAllTarget(self, all_msg, ann.span);
            continue;
        }
        // @Target check — only when we know the annotation class and it
        // carries a @Target list.
        if (meta.get(leaf)) |m| {
            if (m.targets) |targets| {
                if (!targetsContain(targets, site)) {
                    var list_buf: std.ArrayList(u8) = .empty;
                    defer list_buf.deinit(a);
                    for (targets, 0..) |t, i| {
                        if (i > 0) try list_buf.appendSlice(a, ", ");
                        try list_buf.appendSlice(a, t.display());
                    }
                    const msg = try std.fmt.allocPrint(
                        a,
                        "annotation `@{s}` cannot be applied to {s} — declared @Target list is {{{s}}}",
                        .{ leaf, site.display(), list_buf.items },
                    );
                    var d = Diagnostic.err(msg, ann.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_TARGET_MISMATCH);
                    try self.diagnostics.emit(a, d);
                }
            }
        }
        // @Repeatable duplicate detection — only when the annotation class is
        // known to be non-repeatable.
        if (counts.get(leaf)) |prev_span| {
            if (meta.get(leaf)) |m| {
                if (!m.repeatable) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "annotation `@{s}` is not repeatable but is applied more than once",
                        .{leaf},
                    );
                    var d = Diagnostic.err(msg, ann.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_NOT_REPEATABLE);
                    _ = try d.withLabel(a, prev_span, "previously applied here");
                    try self.diagnostics.emit(a, d);
                }
            }
        } else {
            try counts.put(leaf, ann.span);
        }
    }
}

fn targetsContain(targets: []const AnnotationTarget, site: AnnotationTarget) bool {
    for (targets) |t| {
        if (t == site) return true;
    }
    return false;
}

pub fn emitInapplicableAllTarget(self: *Checker, what: []const u8, sp: Span) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(
        self.allocator,
        "'@all:' annotations cannot be applied to {s}.",
        .{what},
    );
    var d = Diagnostic.err(msg, sp);
    _ = d.withCode(codes.TYPE_INAPPLICABLE_ALL_TARGET);
    _ = d.withFactory(&diagnostics.generated.INAPPLICABLE_ALL_TARGET);
    try self.diagnostics.emit(self.allocator, d);
}

const at = ast.annotation_targets;

/// Convert a declared `@Target` list into the use-site target set U(A).
/// `null` targets (no `@Target` on the class) admit everything but `file`.
fn useSiteSetFor(targets: ?[]const AnnotationTarget) at.UseSiteSet {
    const list = targets orelse return at.UseSiteSet.no_target;
    var u = at.UseSiteSet{};
    for (list) |t| {
        switch (t) {
            .Field => {
                u.field = true;
                u.delegate = true;
            },
            .Property => u.property = true,
            .PropertyGetter => u.get = true,
            .PropertySetter => u.set = true,
            .ValueParameter => {
                u.param = true;
                u.receiver = true;
                u.setparam = true;
            },
            .File => u.file = true,
            else => {},
        }
    }
    return u;
}

/// kotlinc's lowercase target description, used in the applicable-targets
/// tail of `WRONG_ANNOTATION_TARGET` messages.
fn targetDescription(t: AnnotationTarget) []const u8 {
    return switch (t) {
        .Class => "class",
        .AnnotationClass => "annotation class",
        .TypeParameter => "type parameter",
        .Property => "property",
        .Field => "field",
        .LocalVariable => "local variable",
        .ValueParameter => "value parameter",
        .Constructor => "constructor",
        .Function => "function",
        .PropertyGetter => "property getter",
        .PropertySetter => "property setter",
        .Type => "type usage",
        .Expression => "expression",
        .File => "file",
        .TypeAlias => "typealias",
    };
}

fn joinTargetDescriptions(a: Allocator, targets: []const AnnotationTarget) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    for (targets, 0..) |t, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, targetDescription(t));
    }
    return buf.toOwnedSlice(a);
}

/// kotlinc's description of the property declaration itself, used as the
/// `{0}` of `WRONG_ANNOTATION_TARGET`.
fn propertyTargetDescription(shape: at.PropertyShape, container: PropContainer) []const u8 {
    const member = shape.is_ctor_property or container == .Member;
    if (shape.is_delegated) {
        return if (member) "member property with delegate" else "top level property with delegate";
    }
    if (shape.has_backing_field) {
        return if (member) "member property with backing field" else "top level property with backing field";
    }
    return if (member) "member property without backing field or delegate" else "top level property without backing field or delegate";
}

/// Source spelling of an explicit use-site target.
fn useSiteSpelling(us: ast.AnnotationUseSite) []const u8 {
    return switch (us) {
        .Field => "field",
        .Property => "property",
        .Get => "get",
        .Set => "set",
        .Receiver => "receiver",
        .Param => "param",
        .SetParam => "setparam",
        .Delegate => "delegate",
        .File => "file",
        .All => "all",
    };
}

/// Target assignment for the annotation entries of one property
/// declaration (member, top-level, or primary-constructor `val`/`var`):
/// `@all:` expansion, the LV 2.4 defaulting rule for target-less entries,
/// explicit use-site applicability, and per-anchor repetition.
fn checkPropertyAnnotationSet(
    self: *Checker,
    meta: *const std.StringHashMap(AnnotationMeta),
    anns: []const Annotation,
    shape: at.PropertyShape,
    container: PropContainer,
) Allocator.Error!void {
    const a = self.allocator;
    // Per-anchor first-occurrence spans, keyed by annotation leaf name.
    var seen = [_]std.StringHashMap(Span){std.StringHashMap(Span).init(a)} ** 8;
    defer for (&seen) |*m| m.deinit();
    const anchor_fields = [_][]const u8{ "param", "property", "field", "get", "set", "setparam", "delegate", "receiver" };

    for (anns) |*ann| {
        const leaf = if (ann.path.len > 0) ann.path[ann.path.len - 1].name else continue;
        const m = meta.get(leaf);
        const known_targets: ?[]const AnnotationTarget = if (m) |mm| mm.targets else null;
        const u = useSiteSetFor(known_targets);

        var placement = at.Placement{};
        if (ann.use_site) |us| switch (us) {
            .All => {
                if (shape.is_delegated) {
                    try emitInapplicableAllTarget(self, "delegated properties", ann.span);
                    continue;
                }
                placement = at.expandAll(u, shape);
                if (placement.isEmpty()) {
                    const list = try joinTargetDescriptions(a, known_targets orelse &.{});
                    const msg = try std.fmt.allocPrint(
                        a,
                        "This annotation is not applicable to target 'property' and use-site target '@all'. Applicable targets: {s}",
                        .{list},
                    );
                    var d = Diagnostic.err(msg, ann.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_TARGET_MISMATCH);
                    _ = d.withFactory(&diagnostics.generated.WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET);
                    try self.diagnostics.emit(a, d);
                    continue;
                }
            },
            else => {
                const admitted = switch (us) {
                    .Field => u.field,
                    .Property => u.property,
                    .Get => u.get,
                    .Set => u.set,
                    .Receiver => u.receiver,
                    .Param => u.param,
                    .SetParam => u.setparam,
                    .Delegate => u.delegate,
                    .File => u.file,
                    .All => unreachable,
                };
                if (!admitted and known_targets != null) {
                    const list = try joinTargetDescriptions(a, known_targets.?);
                    const msg = try std.fmt.allocPrint(
                        a,
                        "This annotation is not applicable to target '{s}' and use-site target '@{s}'. Applicable targets: {s}",
                        .{ propertyTargetDescription(shape, container), useSiteSpelling(us), list },
                    );
                    var d = Diagnostic.err(msg, ann.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_TARGET_MISMATCH);
                    _ = d.withFactory(&diagnostics.generated.WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET);
                    try self.diagnostics.emit(a, d);
                    continue;
                }
                switch (us) {
                    .Field => placement.field = true,
                    .Property => placement.property = true,
                    .Get => placement.get = true,
                    .Set => placement.set = true,
                    .Receiver => placement.receiver = true,
                    .Param => placement.param = true,
                    .SetParam => placement.setparam = true,
                    .Delegate => placement.delegate = true,
                    .File, .All => {},
                }
            },
        } else {
            placement = at.defaultPlacement(u, shape);
            if (placement.isEmpty()) {
                // Nothing to default to: the entry stays on the property
                // declaration, where plain target checking rejects an
                // annotation that cannot target a property. Only known
                // classes with an explicit @Target can fail here.
                if (known_targets) |targets| {
                    const list = try joinTargetDescriptions(a, targets);
                    const msg = try std.fmt.allocPrint(
                        a,
                        "This annotation is not applicable to target '{s}'. Applicable targets: {s}",
                        .{ propertyTargetDescription(shape, container), list },
                    );
                    var d = Diagnostic.err(msg, ann.span);
                    _ = d.withCode(codes.TYPE_ANNOTATION_TARGET_MISMATCH);
                    _ = d.withFactory(&diagnostics.generated.WRONG_ANNOTATION_TARGET);
                    try self.diagnostics.emit(a, d);
                }
                continue;
            }
        }

        // Per-anchor repetition: a non-repeatable annotation may reach a
        // given anchor only once, whatever mix of `@all:` / explicit /
        // defaulted entries put it there.
        var repeated: ?Span = null;
        inline for (anchor_fields, 0..) |fname, i| {
            if (@field(placement, fname)) {
                const gop = try seen[i].getOrPut(leaf);
                if (gop.found_existing) {
                    if (repeated == null) repeated = gop.value_ptr.*;
                } else {
                    gop.value_ptr.* = ann.span;
                }
            }
        }
        if (repeated) |prev_span| {
            const non_repeatable = if (m) |mm| !mm.repeatable else false;
            if (non_repeatable) {
                var d = Diagnostic.err("This annotation is not repeatable.", ann.span);
                _ = d.withCode(codes.TYPE_ANNOTATION_NOT_REPEATABLE);
                _ = d.withFactory(&diagnostics.generated.REPEATED_ANNOTATION);
                _ = try d.withLabel(a, prev_span, "previously applied here");
                try self.diagnostics.emit(a, d);
            }
        }
    }
}

// === opt-in collectors ====================================================

fn parseRequiresOptIn(allocator: Allocator, anns: []const Annotation) Allocator.Error!?OptInMarker {
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "RequiresOptIn")) continue;
        var info = OptInMarker{ .level = .Error, .message = null };
        var positional: usize = 0;
        for (a.args, 0..) |*arg, i| {
            const name: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
            const slot: ?[]const u8 = if (name) |nm| blk: {
                if (std.mem.eql(u8, nm, "message")) break :blk "message";
                if (std.mem.eql(u8, nm, "level")) break :blk "level";
                break :blk null;
            } else switch (positional) {
                0 => blk: {
                    positional += 1;
                    break :blk "message";
                },
                1 => blk: {
                    positional += 1;
                    break :blk "level";
                },
                else => null,
            };
            if (slot) |s| {
                if (std.mem.eql(u8, s, "message")) {
                    info.message = try extractStringLiteral(allocator, arg);
                } else if (std.mem.eql(u8, s, "level")) {
                    if (extractOptInLevel(arg)) |lv| info.level = lv;
                }
            }
        }
        return info;
    }
    return null;
}

fn extractOptInLevel(e: *const Expr) ?OptInLevel {
    const name: ?[]const u8 = switch (e.*) {
        .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
    const n = name orelse return null;
    if (std.mem.eql(u8, n, "WARNING")) return .Warning;
    if (std.mem.eql(u8, n, "ERROR")) return .Error;
    return null;
}

fn markerNamesIn(allocator: Allocator, anns: []const Annotation, markers: *const std.StringHashMap(OptInMarker)) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (anns) |*a| {
        if (a.path.len > 0) {
            const leaf = a.path[a.path.len - 1].name;
            if (markers.contains(leaf)) try out.append(allocator, leaf);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn optInMarkersIn(allocator: Allocator, anns: []const Annotation) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "OptIn")) continue;
        for (a.args) |*arg| {
            if (arg.* == .MemberRef) {
                const mr = arg.MemberRef;
                if (std.mem.eql(u8, mr.name.name, "class") and mr.receiver.* == .Path) {
                    const segs = mr.receiver.Path.segments;
                    if (segs.len > 0) try out.append(allocator, segs[segs.len - 1].name);
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn collectRequiredOptIns(
    allocator: Allocator,
    decls: []const Decl,
    markers: *const std.StringHashMap(OptInMarker),
    out: *std.StringHashMap([]const []const u8),
) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                const m = try markerNamesIn(allocator, f.annotations, markers);
                if (m.len != 0) {
                    try out.put(f.name.name, m);
                } else allocator.free(m);
            },
            .Property => |p| {
                const m = try markerNamesIn(allocator, p.annotations, markers);
                if (m.len != 0) {
                    try out.put(p.name.name, m);
                } else allocator.free(m);
            },
            .Class => |*c| {
                const m = try markerNamesIn(allocator, c.annotations, markers);
                if (m.len != 0) {
                    try out.put(c.name.name, m);
                } else allocator.free(m);
                try collectRequiredOptIns(allocator, c.members, markers, out);
            },
            .Object => |*o| {
                try collectRequiredOptIns(allocator, o.members, markers, out);
            },
            .TypeAlias => |*a| {
                const m = try markerNamesIn(allocator, a.annotations, markers);
                if (m.len != 0) {
                    try out.put(a.name.name, m);
                } else allocator.free(m);
            },
        }
    }
}

fn pushScope(allocator: Allocator, scope: *std.ArrayList([]const u8), anns: []const Annotation) Allocator.Error!usize {
    const added = try optInMarkersIn(allocator, anns);
    defer allocator.free(added);
    const n = added.len;
    for (added) |x| try scope.append(allocator, x);
    return n;
}

fn walkDeclForOptIn(
    self: *Checker,
    d: *const Decl,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([]const []const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const a = self.allocator;
    switch (d.*) {
        .Function => |*f| {
            const added = try pushScope(a, scope, f.annotations);
            const self_markers = try markerNamesIn(a, f.annotations, markers);
            defer a.free(self_markers);
            for (self_markers) |m| try scope.append(a, m);
            if (f.body) |body| {
                switch (body) {
                    .Expr => |e| try walkExprForOptIn(self, &e, markers, required, scope, out),
                    .Block => |b| try walkBlockForOptIn(self, &b, markers, required, scope, out),
                }
            }
            for (f.params) |*p| {
                if (p.default) |def| try walkExprForOptIn(self, def, markers, required, scope, out);
            }
            popN(scope, self_markers.len);
            popN(scope, added);
        },
        .Property => |p| {
            const added = try pushScope(a, scope, p.annotations);
            const self_markers = try markerNamesIn(a, p.annotations, markers);
            defer a.free(self_markers);
            for (self_markers) |m| try scope.append(a, m);
            if (p.init) |*init| try walkExprForOptIn(self, init, markers, required, scope, out);
            if (p.getter) |acc| try walkAccessorBodyOptIn(self, &acc.body, markers, required, scope, out);
            if (p.setter) |acc| try walkAccessorBodyOptIn(self, &acc.body, markers, required, scope, out);
            popN(scope, self_markers.len);
            popN(scope, added);
        },
        .Class => |*c| {
            const added = try pushScope(a, scope, c.annotations);
            const self_markers = try markerNamesIn(a, c.annotations, markers);
            defer a.free(self_markers);
            for (self_markers) |m| try scope.append(a, m);
            for (c.init_blocks) |*ib| try walkBlockForOptIn(self, ib, markers, required, scope, out);
            for (c.primary_params) |*p| {
                if (p.default) |*def| try walkExprForOptIn(self, def, markers, required, scope, out);
            }
            for (c.secondary_ctors) |*sc| {
                if (sc.body) |*body| try walkBlockForOptIn(self, body, markers, required, scope, out);
            }
            for (c.enum_entries) |*ee| {
                for (ee.args) |*arg| try walkExprForOptIn(self, arg, markers, required, scope, out);
                for (ee.body_members) |*m| try walkDeclForOptIn(self, m, markers, required, scope, out);
            }
            for (c.members) |*m| try walkDeclForOptIn(self, m, markers, required, scope, out);
            popN(scope, self_markers.len);
            popN(scope, added);
        },
        .Object => |*o| {
            for (o.members) |*m| try walkDeclForOptIn(self, m, markers, required, scope, out);
        },
        .TypeAlias => {},
    }
}

fn walkAccessorBodyOptIn(
    self: *Checker,
    body: *const FunctionBody,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([]const []const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (body.*) {
        .Expr => |*e| try walkExprForOptIn(self, e, markers, required, scope, out),
        .Block => |*b| try walkBlockForOptIn(self, b, markers, required, scope, out),
    }
}

fn walkBlockForOptIn(
    self: *Checker,
    b: *const Block,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([]const []const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try walkExprForOptIn(self, e, markers, required, scope, out),
            .Decl => |*d| try walkDeclForOptIn(self, d, markers, required, scope, out),
            .Assign => |*a| {
                try walkExprForOptIn(self, &a.target, markers, required, scope, out);
                try walkExprForOptIn(self, &a.value, markers, required, scope, out);
            },
            .DestructuringDecl => |*dd| {
                try walkExprForOptIn(self, &dd.init, markers, required, scope, out);
            },
        }
    }
}

fn walkExprForOptIn(
    self: *Checker,
    e: *const Expr,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([]const []const u8),
    scope: *std.ArrayList([]const u8),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                _ = try emitOptInAt(self, p.segments[0].name, p.span, markers, required, scope.items, out);
            }
        },
        .Call => |c| {
            var emitted = false;
            if (c.callee.* == .Path) {
                const segs = c.callee.Path.segments;
                if (segs.len == 1) {
                    emitted = try emitOptInAt(self, segs[0].name, c.span, markers, required, scope.items, out);
                }
            }
            if (!emitted) try walkExprForOptIn(self, c.callee, markers, required, scope, out);
            for (c.args) |*a| try walkExprForOptIn(self, a, markers, required, scope, out);
        },
        .Binary => |b| {
            try walkExprForOptIn(self, b.lhs, markers, required, scope, out);
            try walkExprForOptIn(self, b.rhs, markers, required, scope, out);
        },
        .Member => |m| try walkExprForOptIn(self, m.receiver, markers, required, scope, out),
        .MemberRef => |m| try walkExprForOptIn(self, m.receiver, markers, required, scope, out),
        .Unary => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .Postfix => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .As => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .IsCheck => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .Spread => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .Labeled => |x| try walkExprForOptIn(self, x.expr, markers, required, scope, out),
        .Return => |r| {
            if (r.value) |v| try walkExprForOptIn(self, v, markers, required, scope, out);
        },
        .Throw => |x| try walkExprForOptIn(self, x.value, markers, required, scope, out),
        .Index => |x| {
            try walkExprForOptIn(self, x.receiver, markers, required, scope, out);
            for (x.args) |*a| try walkExprForOptIn(self, a, markers, required, scope, out);
        },
        .If => |i| {
            try walkExprForOptIn(self, i.cond, markers, required, scope, out);
            try walkExprForOptIn(self, i.then_branch, markers, required, scope, out);
            if (i.else_branch) |eb| try walkExprForOptIn(self, eb, markers, required, scope, out);
        },
        .While => |w| {
            try walkExprForOptIn(self, w.cond, markers, required, scope, out);
            try walkExprForOptIn(self, w.body, markers, required, scope, out);
        },
        .DoWhile => |w| {
            try walkExprForOptIn(self, w.cond, markers, required, scope, out);
            if (w.body) |b| try walkExprForOptIn(self, b, markers, required, scope, out);
        },
        .For => |f| {
            try walkExprForOptIn(self, f.iter, markers, required, scope, out);
            try walkExprForOptIn(self, f.body, markers, required, scope, out);
        },
        .When => |w| {
            if (w.subject) |s| try walkExprForOptIn(self, s, markers, required, scope, out);
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| try walkExprForOptIn(self, pe, markers, required, scope, out),
                        else => {},
                    }
                }
                try walkExprForOptIn(self, &br.body, markers, required, scope, out);
            }
        },
        .Try => |t| {
            try walkBlockForOptIn(self, &t.body, markers, required, scope, out);
            for (t.catches) |*c| try walkBlockForOptIn(self, &c.body, markers, required, scope, out);
            if (t.finally) |*f| try walkBlockForOptIn(self, f, markers, required, scope, out);
        },
        .Block => |*blk| try walkBlockForOptIn(self, blk, markers, required, scope, out),
        .Lambda => |l| try walkBlockForOptIn(self, &l.body, markers, required, scope, out),
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Expr => |*e2| try walkExprForOptIn(self, e2, markers, required, scope, out),
                    .Block => |*blk| try walkBlockForOptIn(self, blk, markers, required, scope, out),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try walkDeclForOptIn(self, m, markers, required, scope, out);
            for (oe.init_blocks) |*ib| try walkBlockForOptIn(self, ib, markers, required, scope, out);
            for (oe.supertype_args) |maybe_args| {
                if (maybe_args) |args| {
                    for (args) |*a| try walkExprForOptIn(self, a, markers, required, scope, out);
                }
            }
            for (oe.supertype_delegates) |maybe_del| {
                if (maybe_del) |del| try walkExprForOptIn(self, &del, markers, required, scope, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |part| {
                if (part == .Interp) try walkExprForOptIn(self, part.Interp, markers, required, scope, out);
            }
        },
        else => {},
    }
}

fn emitOptInAt(
    self: *Checker,
    name: []const u8,
    sp: Span,
    markers: *const std.StringHashMap(OptInMarker),
    required: *const std.StringHashMap([]const []const u8),
    scope: []const []const u8,
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!bool {
    const a = self.allocator;
    const needed = required.get(name) orelse return false;
    var emitted = false;
    for (needed) |marker| {
        if (sliceContainsStr(scope, marker)) continue;
        const info = markers.get(marker) orelse continue;
        const suffix: []const u8 = if (info.message) |m|
            (if (m.len != 0) try std.fmt.allocPrint(a, ": {s}", .{m}) else "")
        else
            "";
        const body = try std.fmt.allocPrint(
            a,
            "`{s}` requires opt-in via `@OptIn({s}::class)`{s}",
            .{ name, marker, suffix },
        );
        switch (info.level) {
            .Warning => {
                var d = Diagnostic.warning(body, sp);
                _ = d.withCode(codes.WARN_OPT_IN);
                try out.append(a, d);
            },
            .Error => {
                var d = Diagnostic.err(body, sp);
                _ = d.withCode(codes.TYPE_OPT_IN_REQUIRED);
                try out.append(a, d);
            },
        }
        emitted = true;
    }
    return emitted;
}

// === deprecation collectors ===============================================

fn parseDeprecation(allocator: Allocator, anns: []const Annotation) Allocator.Error!?DeprecationInfo {
    for (anns) |*a| {
        const leaf = if (a.path.len > 0) a.path[a.path.len - 1].name else "";
        if (!std.mem.eql(u8, leaf, "Deprecated")) continue;
        var info = DeprecationInfo{ .level = .Warning, .message = null };
        var positional_idx: usize = 0;
        for (a.args, 0..) |*arg, i| {
            const name: ?[]const u8 = if (i < a.arg_names.len) a.arg_names[i] else null;
            const slot: ?[]const u8 = if (name) |nm| blk: {
                if (std.mem.eql(u8, nm, "message")) break :blk "message";
                if (std.mem.eql(u8, nm, "level")) break :blk "level";
                if (std.mem.eql(u8, nm, "replaceWith")) break :blk "replaceWith";
                break :blk null;
            } else switch (positional_idx) {
                0 => blk: {
                    positional_idx += 1;
                    break :blk "message";
                },
                1 => blk: {
                    positional_idx += 1;
                    break :blk "replaceWith";
                },
                2 => blk: {
                    positional_idx += 1;
                    break :blk "level";
                },
                else => null,
            };
            if (slot) |s| {
                if (std.mem.eql(u8, s, "message")) {
                    info.message = try extractStringLiteral(allocator, arg);
                } else if (std.mem.eql(u8, s, "level")) {
                    if (extractDeprecationLevel(arg)) |lv| info.level = lv;
                }
            }
        }
        return info;
    }
    return null;
}

fn extractDeprecationLevel(e: *const Expr) ?DeprecationLevel {
    const name: ?[]const u8 = switch (e.*) {
        .Path => |p| if (p.segments.len > 0) p.segments[p.segments.len - 1].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
    const n = name orelse return null;
    if (std.mem.eql(u8, n, "WARNING")) return .Warning;
    if (std.mem.eql(u8, n, "ERROR")) return .Error;
    if (std.mem.eql(u8, n, "HIDDEN")) return .Hidden;
    return null;
}

/// Concatenate the Text parts of a pure-text string-literal template into
/// an owned string. Returns null when any non-Text (interpolated) part is
/// present.
fn extractStringLiteral(allocator: Allocator, e: *const Expr) Allocator.Error!?[]const u8 {
    if (e.* == .StringTemplate) {
        const parts = e.StringTemplate.parts;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (parts) |p| {
            switch (p) {
                .Text => |t| try buf.appendSlice(allocator, t),
                else => {
                    buf.deinit(allocator);
                    return null;
                },
            }
        }
        return try buf.toOwnedSlice(allocator);
    }
    return null;
}

fn collectDeprecationInfo(allocator: Allocator, decls: []const Decl, out: *std.StringHashMap(DeprecationInfo)) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                if (try parseDeprecation(allocator, f.annotations)) |info| try out.put(f.name.name, info);
            },
            .Property => |p| {
                if (try parseDeprecation(allocator, p.annotations)) |info| try out.put(p.name.name, info);
            },
            .Class => |*c| {
                if (try parseDeprecation(allocator, c.annotations)) |info| try out.put(c.name.name, info);
            },
            .Object => |*o| {
                for (o.members) |*m| {
                    try collectDeprecationInfo(allocator, m[0..1], out);
                }
            },
            .TypeAlias => |*a| {
                if (try parseDeprecation(allocator, a.annotations)) |info| try out.put(a.name.name, info);
            },
        }
    }
}

/// Names declared at least once *without* `@Deprecated`, mirroring
/// `collectDeprecationInfo`'s walk.
fn collectNonDeprecatedNames(allocator: Allocator, decls: []const Decl, out: *std.StringHashMap(void)) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Function => |*f| {
                if (try parseDeprecation(allocator, f.annotations) == null) try out.put(f.name.name, {});
            },
            .Property => |p| {
                if (try parseDeprecation(allocator, p.annotations) == null) try out.put(p.name.name, {});
            },
            .Class => |*c| {
                if (try parseDeprecation(allocator, c.annotations) == null) try out.put(c.name.name, {});
            },
            .Object => |*o| {
                for (o.members) |*m| {
                    try collectNonDeprecatedNames(allocator, m[0..1], out);
                }
            },
            .TypeAlias => |*a| {
                if (try parseDeprecation(allocator, a.annotations) == null) try out.put(a.name.name, {});
            },
        }
    }
}

fn walkDeclForDeprecation(
    self: *Checker,
    d: *const Decl,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.body) |body| {
                switch (body) {
                    .Expr => |e| try walkExprForDeprecation(self, &e, info, out),
                    .Block => |b| try walkBlockForDeprecation(self, &b, info, out),
                }
            }
            for (f.params) |*p| {
                if (p.default) |def| try walkExprForDeprecation(self, def, info, out);
            }
        },
        .Property => |p| {
            if (p.init) |*init| try walkExprForDeprecation(self, init, info, out);
            if (p.getter) |acc| try walkAccessorBodyDeprecation(self, &acc.body, info, out);
            if (p.setter) |acc| try walkAccessorBodyDeprecation(self, &acc.body, info, out);
        },
        .Class => |*c| {
            for (c.init_blocks) |*ib| try walkBlockForDeprecation(self, ib, info, out);
            for (c.primary_params) |*p| {
                if (p.default) |*def| try walkExprForDeprecation(self, def, info, out);
            }
            for (c.secondary_ctors) |*sc| {
                if (sc.body) |*body| try walkBlockForDeprecation(self, body, info, out);
            }
            for (c.enum_entries) |*ee| {
                for (ee.args) |*arg| try walkExprForDeprecation(self, arg, info, out);
                for (ee.body_members) |*m| try walkDeclForDeprecation(self, m, info, out);
            }
            for (c.members) |*m| try walkDeclForDeprecation(self, m, info, out);
        },
        .Object => |*o| {
            for (o.members) |*m| try walkDeclForDeprecation(self, m, info, out);
        },
        .TypeAlias => {},
    }
}

fn walkAccessorBodyDeprecation(
    self: *Checker,
    body: *const FunctionBody,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (body.*) {
        .Expr => |*e| try walkExprForDeprecation(self, e, info, out),
        .Block => |*b| try walkBlockForDeprecation(self, b, info, out),
    }
}

fn walkBlockForDeprecation(
    self: *Checker,
    b: *const Block,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (b.stmts) |*s| {
        switch (s.*) {
            .Expr => |*e| try walkExprForDeprecation(self, e, info, out),
            .Decl => |*d| try walkDeclForDeprecation(self, d, info, out),
            .Assign => |*a| {
                try walkExprForDeprecation(self, &a.target, info, out);
                try walkExprForDeprecation(self, &a.value, info, out);
            },
            .DestructuringDecl => |*dd| {
                try walkExprForDeprecation(self, &dd.init, info, out);
            },
        }
    }
}

fn walkExprForDeprecation(
    self: *Checker,
    e: *const Expr,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) {
                try emitDeprecationAt(self, p.segments[0].name, p.span, info, out);
            }
        },
        .Call => |c| {
            // Recurse into the callee unless it's a bare-name reference to a
            // deprecated symbol — we emit once for the call as a whole using
            // the call's span.
            var emitted_at_call = false;
            if (c.callee.* == .Path) {
                const segs = c.callee.Path.segments;
                if (segs.len == 1 and info.contains(segs[0].name)) {
                    try emitDeprecationAt(self, segs[0].name, c.span, info, out);
                    emitted_at_call = true;
                }
            }
            if (!emitted_at_call) try walkExprForDeprecation(self, c.callee, info, out);
            for (c.args) |*a| try walkExprForDeprecation(self, a, info, out);
        },
        .Binary => |b| {
            try walkExprForDeprecation(self, b.lhs, info, out);
            try walkExprForDeprecation(self, b.rhs, info, out);
        },
        .Member => |m| try walkExprForDeprecation(self, m.receiver, info, out),
        .MemberRef => |m| try walkExprForDeprecation(self, m.receiver, info, out),
        .Unary => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .Postfix => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .As => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .IsCheck => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .Spread => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .Labeled => |x| try walkExprForDeprecation(self, x.expr, info, out),
        .Return => |r| {
            if (r.value) |v| try walkExprForDeprecation(self, v, info, out);
        },
        .Throw => |x| try walkExprForDeprecation(self, x.value, info, out),
        .Index => |x| {
            try walkExprForDeprecation(self, x.receiver, info, out);
            for (x.args) |*a| try walkExprForDeprecation(self, a, info, out);
        },
        .If => |i| {
            try walkExprForDeprecation(self, i.cond, info, out);
            try walkExprForDeprecation(self, i.then_branch, info, out);
            if (i.else_branch) |eb| try walkExprForDeprecation(self, eb, info, out);
        },
        .While => |w| {
            try walkExprForDeprecation(self, w.cond, info, out);
            try walkExprForDeprecation(self, w.body, info, out);
        },
        .DoWhile => |w| {
            try walkExprForDeprecation(self, w.cond, info, out);
            if (w.body) |b| try walkExprForDeprecation(self, b, info, out);
        },
        .For => |f| {
            try walkExprForDeprecation(self, f.iter, info, out);
            try walkExprForDeprecation(self, f.body, info, out);
        },
        .When => |w| {
            if (w.subject) |s| try walkExprForDeprecation(self, s, info, out);
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| try walkExprForDeprecation(self, pe, info, out),
                        else => {},
                    }
                }
                try walkExprForDeprecation(self, &br.body, info, out);
            }
        },
        .Try => |t| {
            try walkBlockForDeprecation(self, &t.body, info, out);
            for (t.catches) |*c| try walkBlockForDeprecation(self, &c.body, info, out);
            if (t.finally) |*f| try walkBlockForDeprecation(self, f, info, out);
        },
        .Block => |*blk| try walkBlockForDeprecation(self, blk, info, out),
        .Lambda => |l| try walkBlockForDeprecation(self, &l.body, info, out),
        .AnonFun => |af| {
            if (af.body) |b| {
                switch (b.*) {
                    .Expr => |*e2| try walkExprForDeprecation(self, e2, info, out),
                    .Block => |*blk| try walkBlockForDeprecation(self, blk, info, out),
                }
            }
        },
        .ObjectExpr => |oe| {
            for (oe.members) |*m| try walkDeclForDeprecation(self, m, info, out);
            for (oe.init_blocks) |*ib| try walkBlockForDeprecation(self, ib, info, out);
            for (oe.supertype_args) |maybe_args| {
                if (maybe_args) |args| {
                    for (args) |*a| try walkExprForDeprecation(self, a, info, out);
                }
            }
            for (oe.supertype_delegates) |maybe_del| {
                if (maybe_del) |del| try walkExprForDeprecation(self, &del, info, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |part| {
                if (part == .Interp) try walkExprForDeprecation(self, part.Interp, info, out);
            }
        },
        else => {},
    }
}

fn emitDeprecationAt(
    self: *Checker,
    name: []const u8,
    sp: Span,
    info: *const std.StringHashMap(DeprecationInfo),
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const a = self.allocator;
    const d_info = info.get(name) orelse return;
    const suffix: []const u8 = if (d_info.message) |m|
        (if (m.len != 0) try std.fmt.allocPrint(a, ": {s}", .{m}) else "")
    else
        "";
    const body = try std.fmt.allocPrint(a, "`{s}` is deprecated{s}", .{ name, suffix });
    switch (d_info.level) {
        .Warning => {
            var d = Diagnostic.warning(body, sp);
            _ = d.withCode(codes.WARN_DEPRECATED);
            try out.append(a, d);
        },
        .Error, .Hidden => {
            var d = Diagnostic.err(body, sp);
            _ = d.withCode(codes.TYPE_DEPRECATED_ERROR);
            try out.append(a, d);
        },
    }
}

// ============================================================================
// Small local helpers.
// ============================================================================

/// `EnumClass.ENTRY` head names that resolve to a builtin primitive
/// companion (constants like `Long.MAX_VALUE`, `Int.MIN_VALUE`, …).
fn isPrimitiveCompanionHead(name: []const u8) bool {
    const names = [_][]const u8{
        "Int",    "Long",  "Short",  "Byte",
        "Double", "Float", "Char",   "Boolean",
        "UInt",   "ULong", "UShort", "UByte",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn isConstInfix(name: []const u8) bool {
    const names = [_][]const u8{ "shl", "shr", "ushr", "and", "or", "xor", "inv" };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn isArrayBuilder(name: []const u8) bool {
    const names = [_][]const u8{
        "arrayOf",     "intArrayOf",   "longArrayOf",   "shortArrayOf",
        "byteArrayOf", "floatArrayOf", "doubleArrayOf", "booleanArrayOf",
        "charArrayOf", "emptyArray",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn sliceContainsStr(slice: []const []const u8, name: []const u8) bool {
    for (slice) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn containsUsize(slice: []const usize, v: usize) bool {
    for (slice) |x| {
        if (x == v) return true;
    }
    return false;
}

fn popN(scope: *std.ArrayList([]const u8), n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = scope.pop();
    }
}

fn cloneStringSet(allocator: Allocator, src: *const std.StringHashMap(void)) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

// ============================================================================
// Tarjan's strongly-connected-components over an adjacency list.
// ============================================================================

const TarjanScc = struct {
    allocator: Allocator,
    edges: []const []const usize,
    index: usize,
    idx_of: []?usize,
    lowlink: []usize,
    on_stack: []bool,
    stack: std.ArrayList(usize),
    sccs: std.ArrayList([]usize),

    fn strongconnect(self: *TarjanScc, v: usize) Allocator.Error!void {
        self.idx_of[v] = self.index;
        self.lowlink[v] = self.index;
        self.index += 1;
        try self.stack.append(self.allocator, v);
        self.on_stack[v] = true;
        for (self.edges[v]) |w| {
            if (self.idx_of[w] == null) {
                try strongconnect(self, w);
                self.lowlink[v] = @min(self.lowlink[v], self.lowlink[w]);
            } else if (self.on_stack[w]) {
                self.lowlink[v] = @min(self.lowlink[v], self.idx_of[w].?);
            }
        }
        if (self.lowlink[v] == self.idx_of[v].?) {
            var comp: std.ArrayList(usize) = .empty;
            while (true) {
                const w = self.stack.pop().?;
                self.on_stack[w] = false;
                try comp.append(self.allocator, w);
                if (w == v) break;
            }
            try self.sccs.append(self.allocator, try comp.toOwnedSlice(self.allocator));
        }
    }
};

fn tarjanSccs(allocator: Allocator, edges: []const []const usize) Allocator.Error![][]usize {
    const n = edges.len;
    const idx_of = try allocator.alloc(?usize, n);
    defer allocator.free(idx_of);
    @memset(idx_of, null);
    const lowlink = try allocator.alloc(usize, n);
    defer allocator.free(lowlink);
    @memset(lowlink, 0);
    const on_stack = try allocator.alloc(bool, n);
    defer allocator.free(on_stack);
    @memset(on_stack, false);
    var t = TarjanScc{
        .allocator = allocator,
        .edges = edges,
        .index = 0,
        .idx_of = idx_of,
        .lowlink = lowlink,
        .on_stack = on_stack,
        .stack = .empty,
        .sccs = .empty,
    };
    defer t.stack.deinit(allocator);
    var v: usize = 0;
    while (v < n) : (v += 1) {
        if (t.idx_of[v] == null) try t.strongconnect(v);
    }
    return t.sccs.toOwnedSlice(allocator);
}

test {
    std.testing.refAllDecls(@This());
}
