//! Receiver, shadow and arity probes shared across the call paths.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const inline_state = @import("../inline_state.zig");
const inline_call = @import("../inline_call.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const FuncId = ir.FuncId;
const Func = ir.Func;
const exprSpan = helpers.exprSpan;

const paths_mod = @import("paths.zig");
const scopeTypeRename = paths_mod.scopeTypeRename;

const lambda_mod = @import("lambda.zig");
const argFnArities = lambda_mod.argFnArities;

const call_mod = @import("call.zig");
const anyReified = call_mod.anyReified;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRef = arg_shape_mod.argDeclTypeRef;
const argEvidenceLitKind = arg_shape_mod.argEvidenceLitKind;

const type_probe_mod = @import("type_probe.zig");
const buildArgShapes = type_probe_mod.buildArgShapes;
const paramLitKind = type_probe_mod.paramLitKind;

const block_mod = @import("block.zig");
const idGet = block_mod.idGet;

const tests_shapes_mod = @import("tests_shapes.zig");
const Module = tests_shapes_mod.Module;
const span = tests_shapes_mod.span;

pub fn indexDeferReason(res: ir.Module.BareCallResolution) ?ir.Module.ResolveDeferReason {
    return switch (res.outcome) {
        .resolved => null,
        .deferred => |r| r,
    };
}

/// Kotlin does not resolve a value-position reference whose only declaration
/// lives in a package the caller neither declares, imports, nor sees by default.
/// Record the unresolved diagnostic in that case; a reference denotes the
/// declaration itself, so a tier-5 verdict is final. True when recorded, so the
/// caller can suppress the lenient bind.
pub fn recordOutOfScopeRef(
    b: *FuncBuilder,
    name: []const u8,
    ref_span: ir.Span,
    fqn: []const u8,
    tier: ?u8,
) Allocator.Error!bool {
    if (tier != ir.Module.other_package_tier) return false;
    // The verdict is trustworthy only for a declaration with a real package: a
    // bare FQN is a lift artifact whose scoping metadata is unreliable, since an
    // upstream class can lose its package during the lift and read as the empty
    // package. Rejecting it would be a false positive.
    if (std.mem.findScalar(u8, fqn, '.') == null) return false;
    if (runtime.envOnce("KLIO_UNRES_TRACE") != null) {
        std.debug.print("[unres] name={s} fqn={s} inline_fn={s} owner={s} window={} depth={d}\n", .{
            name, fqn, b.currentInlineFn() orelse "-", b.owner_class orelse "-",
            b.lambda_splice_resolve != null, b.scopes.items.len,
        });
    }
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn,
        .fqn_b = "",
        .span = ref_span,
        .kind = .unresolved,
    });
    return true;
}

/// The FQN of a class by id, for an out-of-scope value-reference diagnostic.
pub fn classFqnOf(b: *FuncBuilder, id: ir.ClassId) []const u8 {
    if (idGet(ir.Class, b.module.classes.items, id.int())) |c| return c.fqn;
    return "<invalid>";
}

/// Record an ambiguous bare call into the module's lowering diagnostics, which
/// the build driver reports before the program runs. Each candidate carries its
/// declaration span so a true duplicate's report can point at both.
pub fn recordAmbiguousCall(b: *FuncBuilder, name: []const u8, call_span: ir.Span, res: ir.Module.BareCallResolution) Allocator.Error!void {
    const fqn_a = if (res.first) |f| fqnOf(b, f) else "?";
    const fqn_b = if (res.second) |s| fqnOf(b, s) else "?";
    const span_a: ?ir.Span = if (res.first) |f| b.module.decl_span.get(f.int()) else null;
    const span_b: ?ir.Span = if (res.second) |s| b.module.decl_span.get(s.int()) else null;
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn_a,
        .fqn_b = fqn_b,
        .span = call_span,
        .span_a = span_a,
        .span_b = span_b,
    });
}

/// Kotlin does not resolve an unqualified call whose every candidate lives in a
/// package the caller neither declares, imports, nor sees by default. When the
/// bound target is a plain top-level function in such a package, record the
/// unresolved diagnostic and tell the caller to suppress the bind.
/// Receiver-bound extensions are the heuristic's domain and never classify as
/// out of scope here.
pub fn recordOutOfScopeCall(
    b: *FuncBuilder,
    name: []const u8,
    call_span: ir.Span,
    final_id: FuncId,
    index_res: ir.Module.BareCallResolution,
) Allocator.Error!bool {
    const file = call_span.file;
    // A bare call whose name is a known class member in a receiver context is
    // routed to runtime member-or-global dispatch: the implicit receiver may
    // supply the member, so the reference is not out of scope even when the only
    // package-scope candidate is unimported.
    if (inReceiverContext(b) and anyReceiverClassDeclares(b, name)) return false;
    // Only the index's own out-of-scope verdicts count: a unique exact-arity
    // match, or a tier-5 candidate set. Loose-shape deferrals stay with the
    // heuristic, since those binds are provisional and the runtime may still
    // dispatch a member or re-pick an overload.
    const precise = switch (index_res.outcome) {
        .resolved => true,
        .deferred => |r| r == .unimported_set or r == .type_overload,
    };
    // A loose-shape deferral is unresolved too when every rankable candidate is
    // out of scope, that is when the winning tier is `other_package_tier`. The
    // member-redispatch guard is `inReceiverContext`: inside one, a runtime
    // member of the same name may still bind, so the loose-shape rejection fires
    // only outside any receiver context.
    const loose_out_of_scope = switch (index_res.outcome) {
        .resolved => false,
        .deferred => |r| switch (r) {
            .default_param_shape,
            .vararg_only,
            .trailing_lambda_shape,
            .arity_mismatch,
            .low_priority_only,
            .bodyless_only,
            => index_res.tier == ir.Module.other_package_tier and !inReceiverContext(b),
            // The index defers a vararg or default call to `extension_form` when
            // an in-scope extension namesake exists, unable to tell whether the
            // receiver applies. Outside a receiver context no receiver can supply
            // one, so a heuristic landing on a tier-5 non-extension top-level
            // function is the unresolved reference kotlinc rejects.
            .extension_form => !inReceiverContext(b),
            else => false,
        },
    };
    if (!precise and !loose_out_of_scope) return false;
    // With at least one candidate ranked in a visible tier the call resolves among
    // those at runtime, by argument types. A heuristic fallback that happened to
    // land on an invisible same-name namesake does not make it out of scope; only
    // a set whose every rankable candidate is out of scope is unresolved.
    if (index_res.tier < ir.Module.other_package_tier) return false;
    if (!isNonExt(b, final_id)) return false;
    const tier = b.module.bareCallTierOf(final_id, name, b.self_package, file) orelse return false;
    if (tier != ir.Module.other_package_tier) return false;
    // A bare-FQN target is a lift artifact with unreliable scoping metadata; see
    // `recordOutOfScopeRef`.
    if (std.mem.findScalar(u8, fqnOf(b, final_id), '.') == null) return false;
    const fqn_a = if (index_res.first) |f| fqnOf(b, f) else fqnOf(b, final_id);
    const fqn_b = if (index_res.second) |s2| fqnOf(b, s2) else "";
    try b.module.resolve_diags.append(b.allocator, .{
        .name = name,
        .fqn_a = fqn_a,
        .fqn_b = fqn_b,
        .span = call_span,
        .kind = .unresolved,
    });
    return true;
}

/// Whether the current `this` is a spliced receiver-lambda subject of a known
/// type that is not the enclosing owner and does not declare `name`. An
/// own-member read must then take the walking load rather than a GetField on the
/// subject. Mirrors the write side's `spliceReceiverHidesMember`.
pub fn spliceSubjectHidesOwnMember(b: *FuncBuilder, name: []const u8) bool {
    if (!inline_call.rfsEnabled() or b.encl_tower_depth == 0) return false;
    const recv = b.spliceRecvTy() orelse b.spliceHintRecv() orelse return false;
    var head = std.mem.trimEnd(u8, recv, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (std.mem.findScalarLast(u8, head, '.')) |d| head = head[d + 1 ..];
    const owner = b.ownerClass() orelse return false;
    if (std.mem.eql(u8, head, owner)) return false;
    if (inline_state.memberPropAst(head, name) != null) return false;
    if (b.module.classId(head)) |cid| {
        if (cid.int() < b.module.classes.items.len) {
            const c = &b.module.classes.items[cid.int()];
            for (c.primary_params) |*pp| {
                if (std.mem.eql(u8, pp.name, name)) return false;
            }
        }
    }
    return true;
}

pub fn inReceiverContext(b: *const FuncBuilder) bool {
    // A binding named `this` that is an ordinary user parameter, backtick-quoted
    // on a receiver-less function, is not a dispatch receiver.
    const this_binding = !b.this_is_plain_param and b.resolve("this") != null;
    return b.capturesThisSlot() or this_binding or b.ownerClass() != null or
        b.isParamThunk() or b.recvTy() != null;
}

/// An extension declared on a function type has a receiver with no members a bare
/// call could bind, `invoke`/`call` being its whole surface. Deferring a resolved
/// top-level call to the runtime member-first walk from such a body is wrong: the
/// runtime's SAM arm invokes a callable receiver for any member name no extension
/// claims, calling the suspend block itself.
pub fn fnTypedRecvCannotShadow(b: *const FuncBuilder, name: []const u8) bool {
    const rt = b.recvTy() orelse return false;
    if (!recvHeadIsFunctionType(rt)) return false;
    return !std.mem.eql(u8, name, "invoke") and !std.mem.eql(u8, name, "call");
}

/// Whether a recorded receiver-type head denotes a function type in any spelling:
/// the parser's `"<function>"` tag, a spelled-out `(P) -> R`, or the erased
/// builtin names. Tighter than `headIsFunctionType`: the erased names must end in
/// digits so a user class named `FunctionTable` never claims the closed surface.
pub fn recvHeadIsFunctionType(rt: []const u8) bool {
    if (std.mem.eql(u8, rt, "<function>")) return true;
    if (std.mem.find(u8, rt, "->") != null) return true;
    var head = rt;
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    for ([_][]const u8{ "Function", "SuspendFunction", "KFunction", "KSuspendFunction" }) |p| {
        if (std.mem.startsWith(u8, head, p) and head.len > p.len) {
            var all_digits = true;
            for (head[p.len..]) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits) return true;
        }
    }
    return false;
}

/// Whether a bare name in an implicit-receiver context could bind to a member of
/// that receiver, so a static bind to a same-named top-level function would
/// shadow it. Decides whether to defer a resolved bare call to the runtime
/// member-first walk.
///
/// A lambda, scope-function, parameter-thunk or extension body has an implicit
/// receiver whose concrete type is unknown at lowering time, so it always defers.
/// A plain method body's receiver type is known, and its own hierarchy decides
/// precisely. Only a genuinely unknown receiver falls back to the program-wide
/// member-name set.
fn lambdaRecvHeadDeclares(b: *const FuncBuilder, name: []const u8) ?bool {
    const h = eagerLambdaRecvHead(b) orelse return null;
    const hs = b.module.registry.hierarchy_shadow_names.get(h) orelse return null;
    if (!hs.complete) return null;
    return hs.names.contains(name);
}

fn memberShadowPossible(b: *const FuncBuilder, name: []const u8) bool {
    if (b.capturesThisSlot() or b.isParamThunk() or
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name)))
    {
        // Where the recorded receiver head does not declare the name, the
        // remaining implicit receivers are checked below rather than answering a
        // blanket true.
        if (lambdaRecvHeadDeclares(b, name)) |ans| {
            if (ans) return true;
        } else {
            return true;
        }
    }
    if (b.hasEnclosingMember(name)) return true;
    if (b.ownerClass()) |oc| {
        if (ownerChainShadowContains(b, oc, name)) |shadowed| return shadowed;
    }
    return b.module.registry.class_member_names.contains(name);
}

/// Whether `name` is a member along the owner class's hierarchy or any of its
/// lifted outer classes' hierarchies, since a nested class's method body sees the
/// outer classes as implicit receivers. Null when any set along the chain is
/// missing or incomplete, and the caller must stay conservative.
pub fn ownerChainShadowContains(b: *const FuncBuilder, owner: []const u8, name: []const u8) ?bool {
    var found = false;
    var end = owner.len;
    while (true) {
        const hs = b.module.registry.hierarchy_shadow_names.get(owner[0..end]) orelse return null;
        if (!hs.complete) return null;
        if (name.len != 0 and hs.names.contains(name)) found = true;
        const dollar = std.mem.findScalarLast(u8, owner[0..end], '$') orelse break;
        end = dollar;
    }
    return found;
}

/// The direct-bind guards' question: does any class this context's receiver could
/// be declare `name` as a member. Unlike `memberShadowPossible`, an
/// unknown-receiver context does not answer true, since those guards bind direct
/// precisely when no class declares the name, and only a plain method body may
/// narrow the program-wide universe to its own and outer hierarchies.
pub fn anyReceiverClassDeclares(b: *const FuncBuilder, name: []const u8) bool {
    if (receiverTypeKnown(b, name)) {
        if (b.ownerClass()) |oc| {
            if (ownerChainShadowContains(b, oc, name)) |ans| return ans;
        }
    }
    // A lambda context whose receiver head is recorded answers from that head plus
    // the enclosing chain; the program-wide name universe is the fallback only
    // when neither is known.
    if (lambdaRecvHeadDeclares(b, name)) |ans| {
        if (ans) return true;
        if (b.ownerClass()) |oc| {
            if (ownerChainShadowContains(b, oc, name)) |a2| return a2;
        }
        return false;
    }
    return b.module.registry.class_member_names.contains(name);
}

pub fn receiverTypeKnown(b: *const FuncBuilder, name0: []const u8) bool {
    if (b.capturesThisSlot() or b.isParamThunk() or
        (b.recvTy() != null and !fnTypedRecvCannotShadow(b, name0)))
    {
        // A receiver-lambda body whose head typeck recorded is a known-receiver
        // context, so the membership walk can answer from that head.
        if (recvheadAuditOn()) {
            if (eagerLambdaRecvHead(b)) |h| {
                const precise = b.module.registry.hierarchy_shadow_names.get(h) != null;
                std.debug.print("[RECVHEAD-AUDIT] '{s}' head={s} hier={}\n", .{ name0, h, precise });
            }
        }
        return false;
    }
    const oc = b.ownerClass() orelse return false;
    return ownerChainShadowContains(b, oc, "") != null;
}

/// The typeck-recorded receiver head for this builder's lambda body.
pub fn eagerLambdaRecvHead(b: *const FuncBuilder) ?[]const u8 {
    const sp = b.body_span orelse return null;
    return b.module.eagerRecvHeadOf(sp);
}

fn recvheadAuditOn() bool {
    const S = struct {
        var cached: ?bool = null;
    };
    if (S.cached) |v| return v;
    const on = runtime.envOnce("KLIO_RECVHEAD_AUDIT") != null;
    S.cached = on;
    return on;
}

pub fn fqnOf(b: *FuncBuilder, id: FuncId) []const u8 {
    if (b.module.funcById(id)) |f| return f.fqn;
    return "<invalid>";
}

pub fn isNonExt(b: *FuncBuilder, fid: FuncId) bool {
    const f = b.module.funcById(fid) orelse return true;
    return f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this");
}

/// Whether the enclosing class or a supertype declares a member named `name`.
/// Scoped to the current `owner_class`, since a bare `::name` or `this.name` can
/// only resolve to the enclosing class's members or a global.
pub fn enclosingDeclaresMember(b: *const FuncBuilder, name: []const u8) bool {
    const oc = b.ownerClass() orelse return false;
    const methods = b.module.registry.hierarchy_methods.get(oc) orelse return false;
    return methods.contains(name);
}

/// True when `f` shares its simple name and arity with another overload whose
/// parameter at `pidx` has a different declared type. A bare call is lowered to
/// one arbitrarily-picked overload before the runtime types its arguments, so a
/// disagreeing parameter is not an authoritative coercion target: leaving a
/// numeric literal at its natural type lets the runtime resolver pick.
pub fn overloadParamTypeConflicts(module: *const Module, f: *const Func, pidx: usize) bool {
    if (pidx >= f.params.len) return false;
    const want_ty = f.params[pidx].ty.name;
    const cands = module.funcsBySimpleName(f.name);
    if (cands.len < 2) return false;
    for (cands) |cid| {
        const g = module.funcById(cid) orelse continue;
        if (g.params.len != f.params.len) continue;
        if (pidx >= g.params.len) continue;
        if (!std.mem.eql(u8, g.params[pidx].ty.name, want_ty)) return true;
    }
    return false;
}

/// The simple head of a type name: drop a package qualifier and any generic
/// arguments (`kotlin.collections.Iterable<Int>` -> `Iterable`).
pub fn typeHead(s: []const u8) []const u8 {
    var t = s;
    if (std.mem.findScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.findScalarLast(u8, t, '.')) |dot| t = t[dot + 1 ..];
    // A use-site projection keeps the underlying name as its head: an `out#T`
    // receiver is a `T` for class and bound lookups.
    if (std.mem.startsWith(u8, t, "in#"))
        t = t["in#".len..]
    else if (std.mem.startsWith(u8, t, "out#"))
        t = t["out#".len..];
    return std.mem.trim(u8, t, " ");
}

pub fn userFunctionDeclared(b: *const FuncBuilder, name: []const u8) bool {
    for (b.module.funcsBySimpleName(name)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (!shippedPackage(f.package)) return true;
    }
    return false;
}

/// A declaring package that belongs to the shipped stdlib or a library pack
/// rather than to the program being lowered.
fn shippedPackage(pkg: []const u8) bool {
    if (pkg.len == 0) return false;
    for ([_][]const u8{ "kotlin", "kotlinx", "androidx", "io.ktor", "org.jetbrains" }) |root| {
        if (std.mem.eql(u8, pkg, root)) return true;
        if (pkg.len > root.len and std.mem.startsWith(u8, pkg, root) and pkg[root.len] == '.') return true;
    }
    return false;
}

pub fn argStaticHead(b: *FuncBuilder, a: *const Expr) ?[]const u8 {
    if (a.* != .Path) return null;
    const p = a.Path;
    if (p.segments.len != 1) return null;
    if (b.localDeclType(p.segments[0].name)) |t| return typeHead(t);
    return null;
}

/// Expected per-argument lambda arities for a member call whose receiver is a
/// class name: the lifted companion and class method registry resolves the
/// member's declared signature statically. Null when nothing is provable. The
/// channel exists so a `() -> R` block drops its parser-injected `it`.
fn classMemberArgArities(b: *FuncBuilder, receiver: *const Expr, mname: []const u8, args: []const Expr, ast_arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (receiver.* != .Path) return null;
    const rsegs = receiver.Path.segments;
    if (rsegs.len == 0) return null;
    var rname = rsegs[rsegs.len - 1].name;
    if (std.mem.eql(u8, rname, "Companion") and rsegs.len >= 2) rname = rsegs[rsegs.len - 2].name;
    if (rname.len == 0 or !std.ascii.isUpper(rname[0])) return null;
    if (b.resolve(rname) != null or b.knowsOuter(rname)) return null;
    const a2 = b.allocator;
    var probe_arity: usize = args.len;
    while (probe_arity <= args.len + 3) : (probe_arity += 1) {
        const comp_key = std.fmt.allocPrint(a2, "{s}$Companion$Companion\x00{s}\x00{d}", .{ rname, mname, probe_arity }) catch return null;
        defer a2.free(comp_key);
        const cls_key = std.fmt.allocPrint(a2, "{s}\x00{s}\x00{d}", .{ rname, mname, probe_arity }) catch return null;
        defer a2.free(cls_key);
        const fid = b.module.registry.member_method_fids.get(comp_key) orelse
            b.module.registry.member_method_fids.get(cls_key) orelse continue;
        const f = b.module.funcById(fid) orelse continue;
        return try argFnArities(b, f, args, ast_arg_names, 1);
    }
    return null;
}

/// Expected lambda arities for an explicit-receiver call. Class and object members
/// are authoritative; otherwise a statically typed receiver selects visible
/// extension candidates by declared receiver head, and a shape every best-scope
/// candidate agrees on is safe to lower.
pub fn memberCallArgArities(b: *FuncBuilder, receiver: *const Expr, mname: []const u8, args: []const Expr, ast_arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (try classMemberArgArities(b, receiver, mname, args, ast_arg_names)) |arities| return arities;
    const recv_ty = argDeclTypeRef(b, receiver) orelse return null;
    const recv_head = typeHead(recv_ty.name);
    if (recv_head.len == 0) return null;

    const caller_file = exprSpan(receiver).file;
    const caller_pkg = b.module.packageOfFile(caller_file) orelse b.self_package;
    var best_tier: u8 = 255;
    var agreed: ?[]i16 = null;
    errdefer if (agreed) |a| b.allocator.free(a);

    for (b.module.funcsBySimpleName(mname)) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind == .instance_method or f.params.len == 0 or
            !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (f.kind == .member_extension) {
            const owner = b.module.registry.member_ext_owner_class.get(fid) orelse continue;
            const lexical_owner = b.ownerClass() orelse continue;
            if (!b.module.classIsOrExtends(lexical_owner, owner)) continue;
        }
        const candidate_head = typeHead(f.params[0].ty.name);
        if (!b.module.classIsOrExtends(recv_head, candidate_head)) continue;
        const tier = b.module.scopeTier(f.fqn, f.package, mname, caller_pkg, caller_file);
        if (tier > 3 or tier > best_tier) continue;
        const arities = (try argFnArities(b, f, args, ast_arg_names, 1)) orelse continue;
        if (tier < best_tier) {
            if (agreed) |old| b.allocator.free(old);
            agreed = arities;
            best_tier = tier;
            continue;
        }
        if (agreed) |old| {
            if (!std.mem.eql(i16, old, arities)) {
                b.allocator.free(arities);
                b.allocator.free(old);
                agreed = null;
                return null;
            }
            b.allocator.free(arities);
        } else {
            agreed = arities;
        }
    }
    return agreed;
}

/// A short all-caps head (`T`, `R`, `K1`) is a type parameter spelling, not a
/// class name. `staticTypeClassId` rejects it too, but only after a lookup.
pub fn bareTypeParamHead(name: []const u8) bool {
    const h = typeHead(std.mem.trimEnd(u8, name, "?"));
    return h.len != 0 and h.len <= 2 and std.ascii.isUpper(h[0]);
}

/// Whether the receiver's static class or a supertype declares an inline member
/// named `name` with a reified type parameter taking `nargs` arguments, which is
/// honored only by splicing.
pub fn receiverMemberIsReifiedInline(b: *FuncBuilder, receiver: *const Expr, name: []const u8, nargs: usize) Allocator.Error!bool {
    const head = (try inline_call.gateReceiverHead(b, receiver)) orelse return false;
    var h = std.mem.trimEnd(u8, head, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    const cands = inline_state.candidatesForName(name) orelse return false;
    for (cands) |cf| {
        if (cf.receiver_type != null or !anyReified(cf.type_params)) continue;
        const owner = inline_state.inlineMemberOwner(cf) orelse continue;
        if (!std.mem.eql(u8, typeHead(h), owner) and !b.module.classIsOrExtends(typeHead(h), owner)) continue;
        if (cf.params.len < nargs) continue;
        var required: usize = 0;
        for (cf.params) |*p| {
            if (p.default == null and !p.is_vararg) required += 1;
        }
        if (nargs < required) continue;
        return true;
    }
    return false;
}

pub fn receiverStaticMemberApplies(b: *FuncBuilder, receiver: *const Expr, name: []const u8, args: []const Expr, arg_names: []const ?[]const u8, caller_file: span.FileId) Allocator.Error!bool {
    const head = (try inline_call.gateReceiverHead(b, receiver)) orelse return false;
    var h = std.mem.trimEnd(u8, head, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (h.len == 0) return false;
    const cid = (if (std.mem.findScalar(u8, h, '.') != null)
        b.module.classIdByFqn(h)
    else
        b.module.uniqueClassIdBySimpleName(h)) orelse return false;
    const argc = args.len;
    if (argc > 8) return false;
    // The arguments' declared-type evidence decides, not arity alone, so a
    // reified member extension is the target and must splice.
    const shapes = try buildArgShapes(b, args, arg_names);
    defer b.allocator.free(shapes);
    const res = b.module.resolveMemberCall(cid, name, shapes[0..argc], .{
        .caller_file = caller_file,
        .lexical_owner = null,
        .actual_type_param_bounds = &.{},
        .receiver_type = null,
    });
    if (runtime.envOnce("KLIO_SAM_TRACE") != null) {
        std.debug.print("[rsma] {s} head={s} applicable={} shapes:", .{ name, h, res.applicable });
        for (shapes[0..argc]) |*sh| std.debug.print(" {s}", .{if (sh.ty) |t| t.name else "?"});
        std.debug.print("\n", .{});
    }
    return res.applicable;
}

/// The reified type-argument name a call binds from its expected type: a single
/// reified parameter that is the declared return type takes the expected head.
/// Spelled as the class table holds it, a nested class by its lifted name.
pub fn reifiedNamesFromExpected(b: *FuncBuilder, cf: *const ast.Function, exp: ?*const ast.TypeRef) Allocator.Error!?[]const []const u8 {
    const e = exp orelse return null;
    const rt = cf.return_type orelse return null;
    if (cf.type_params.len != 1 or !cf.type_params[0].is_reified) return null;
    if (!std.mem.eql(u8, rt.name.name, cf.type_params[0].name.name)) return null;
    const rendered = try renderExpectedTypeName(b, e);
    if (rendered.len == 0) return null;
    const out = try b.allocator.alloc([]const u8, 1);
    out[0] = rendered;
    return out;
}

/// An expected type spelled as the class table holds it, with its type arguments,
/// which the runtime `typeOf<T>()` needs. Heads rename through the scope, dotted
/// heads through the qualified-suffix lookup.
fn renderExpectedTypeName(b: *FuncBuilder, e: *const ast.TypeRef) Allocator.Error![]const u8 {
    const head0 = std.mem.trimEnd(u8, e.name.name, "?");
    if (head0.len == 0) return "";
    var head: []const u8 = head0;
    if (std.mem.findScalar(u8, head0, '.') != null) {
        if (b.module.classIdByQualifiedSuffix(head0)) |cid| {
            if (cid.int() < b.module.classes.items.len) head = b.module.classes.items[cid.int()].name;
        }
    } else if (scopeTypeRename(b, head0, e.name.span.file.int())) |renamed| {
        head = renamed;
    }
    if (e.type_args.len == 0) {
        if (!e.nullable) return head;
        return std.fmt.allocPrint(b.allocator, "{s}?", .{head});
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(b.allocator, head);
    try out.append(b.allocator, '<');
    for (e.type_args, 0..) |*ta, i| {
        if (i != 0) try out.appendSlice(b.allocator, ", ");
        if (ta.is_star) {
            try out.append(b.allocator, '*');
            continue;
        }
        try out.appendSlice(b.allocator, try renderExpectedTypeName(b, &ta.ty));
    }
    try out.append(b.allocator, '>');
    if (e.nullable) try out.append(b.allocator, '?');
    return out.toOwnedSlice(b.allocator);
}

/// A receiver or context type's bare head: no nullability, type arguments,
/// package or outer-class prefix.
fn receiverTypeSimple(ty: []const u8) []const u8 {
    const head = typeHead(std.mem.trimEnd(u8, ty, "?"));
    return if (std.mem.findScalarLast(u8, head, '$')) |i| head[i + 1 ..] else head;
}

/// The innermost implicit receiver whose static type head is `ty`: a spliced
/// receiver-lambda subject, else the declaration's own receiver or owner instance.
pub fn implicitReceiverOfType(b: *FuncBuilder, ty: []const u8) Allocator.Error!?Reg {
    const want = receiverTypeSimple(ty);
    // Spliced receiver-lambda subjects, innermost first.
    var si = b.subject_binds.items.len;
    while (si > 0) {
        si -= 1;
        const sb = b.subject_binds.items[si];
        const h = sb.head orelse continue;
        if (receiverHeadIs(b, h, want)) return sb.reg;
    }
    // The declaration's own receiver or owner instance.
    if (b.resolve("this")) |this_reg| {
        const head = b.recvTy() orelse b.ownerClass() orelse return null;
        return if (receiverHeadIs(b, head, want)) this_reg else null;
    }
    if (b.capturesThisSlot()) {
        const head = b.enclosingRecvTy() orelse b.ownerClass() orelse return null;
        if (receiverHeadIs(b, head, want)) return try b.loadCaptureHoisted("this");
    }
    return null;
}

/// `head` names `want` or a class extending it.
fn receiverHeadIs(b: *const FuncBuilder, head: []const u8, want: []const u8) bool {
    const h = receiverTypeSimple(head);
    return std.mem.eql(u8, h, want) or b.module.classIsOrExtends(h, want);
}

/// For a bare inner-class construction: the spliced receiver-lambda subject bound
/// as the innermost `this` when its static type is the inner class's outer.
pub fn spliceSubjectOuterFor(b: *FuncBuilder, class_id: ir.ClassId) ?Reg {
    if (class_id.int() >= b.module.classes.items.len) return null;
    const cls = &b.module.classes.items[class_id.int()];
    if (!cls.is_inner) return null;
    const outer = b.module.registry.enclosing_class.get(cls.name) orelse
        b.module.registry.enclosing_class.get(cls.fqn) orelse return null;
    const want = receiverTypeSimple(outer);
    var si = b.subject_binds.items.len;
    while (si > 0) {
        si -= 1;
        const sb = b.subject_binds.items[si];
        const h = sb.head orelse continue;
        if (receiverHeadIs(b, h, want)) return sb.reg;
    }
    return null;
}

/// Whether `cls_name`'s companion object carries the simple name `name`.
pub fn ownCompanionNamed(b: *const FuncBuilder, cls_name: []const u8, name: []const u8) bool {
    const comp = b.module.registry.companion_singletons.get(cls_name) orelse return false;
    const simple = if (std.mem.findScalarLast(u8, comp, '$')) |i| comp[i + 1 ..] else comp;
    return std.mem.eql(u8, simple, name);
}

/// Every named argument names a declared parameter; Kotlin binds named arguments
/// by parameter name, and a candidate lacking the name is not applicable.
pub fn namedArgsNameParams(params: []const ir.Param, arg_names: []const ?[]const u8) bool {
    for (arg_names) |maybe| {
        const an = maybe orelse continue;
        var found = false;
        for (params) |*p| {
            if (std.mem.eql(u8, p.name, an)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Whether the primary constructor's declared parameter types definitely cannot
/// accept the literal argument types, the constructor-side twin of
/// `factorySigRejectsArgs`.
pub fn ctorSigRejectsArgs(b: *FuncBuilder, params: []const ir.Param, args: []const Expr) bool {
    for (args, 0..) |*a, i| {
        if (i >= params.len) break;
        var ak_opt = argEvidenceLitKind(b, a);
        if (ak_opt == null) {
            if (argDeclTypeRef(b, a)) |ty| ak_opt = paramLitKind(ty.name);
        }
        const ak = ak_opt orelse continue;
        const pk = paramLitKind(params[i].ty.name) orelse continue;
        if (ak != pk) return true;
    }
    return false;
}
