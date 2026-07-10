//! Process-global registries for the inline-expansion machinery: the
//! `suspend inline fun` AST table and the inline-nesting depth guard.
//! Kept apart from the main lowering module because they are pure state
//! primitives — no `FuncBuilder` or IR-side dependency.
//!
//! These use module-level state under a single-build-at-a-time contract:
//! the driver installs the tables once per build, then lowers bodies
//! serially.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");
const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const StringSet = std.StringHashMap(void);
const FnField = runtime.forest.ForestField(ast.Function);

// --- Deferred inline-body decode --------------------------------------------
//
// A stdlib image holds `inline`, object-free function bodies in a side section,
// decoded on first splice. The skeleton's marker is an empty block whose
// `span.file == span.DEFERRED_BODY_FILE` and `span.start` is the body's byte
// offset. The decoder lives in `interp_ir` (which depends on this module), so it
// is injected here as a function pointer at base-install time.
const DeferredDecodeFn = *const fn (Allocator, []const u8, u32) ?ast.FunctionBody;
threadlocal var deferred_section: []const u8 = &.{};
threadlocal var deferred_alloc: Allocator = undefined;
threadlocal var deferred_decode: ?DeferredDecodeFn = null;

/// Install the loaded base's deferred-body section, the process-lifetime
/// allocator a decoded body must persist in, and the decoder. Called once per
/// build that uses a base. A freshly-built base passes an empty section (its
/// bodies are not deferred), so this is a no-op there.
pub fn setDeferredSection(section: []const u8, alloc: Allocator, decode: DeferredDecodeFn) void {
    deferred_section = section;
    deferred_alloc = alloc;
    deferred_decode = decode;
}

/// If `f`'s body is a deferred marker, decode the real body from the side
/// section and patch it in place (idempotent: the patched body is no longer a
/// marker). Call before reading an inline function's body for splicing.
pub fn ensureInlineBody(f: *const ast.Function) void {
    const decode = deferred_decode orelse return;
    const body = f.body orelse return;
    if (body != .Block) return;
    const blk = body.Block;
    if (blk.stmts.len != 0 or blk.span.file.int() != span.DEFERRED_BODY_FILE) return;
    if (decode(deferred_alloc, deferred_section, blk.span.start)) |decoded| {
        @constCast(f).body = decoded;
    }
}

/// A call's shape at a candidate site: `(positional_arg_count,
/// last_arg_is_lambda)`. `null` when the caller has no shape hint.
pub const CallShape = struct {
    want: usize,
    last_is_lambda: bool,
    /// Declared parameter arity of the trailing lambda/anon-fun argument
    /// (a zero-`->` `{ … }` is 0, not 1 — the injected `it` does not count),
    /// or `null` when the last argument is not a lambda. Used to break a
    /// trailing-lambda overload tie toward the candidate whose trailing
    /// function-type parameter arity matches: a bare `{ … }` handler picks
    /// the `T.() -> R` (0-param) overload over a reified `T.(X) -> R` one
    /// whose type argument a bare lambda cannot supply.
    trailing_lambda_arity: ?usize = null,
};

/// `suspend inline fun` ASTs by simple name, set by the build driver
/// before body lowering. A `suspend inline` builder's
/// `suspendCoroutineUninterceptedOrReturn` must capture the *caller's*
/// continuation — only correct when the body is truly inlined.
/// Non-suspend inline fns keep the normal call path and klio's
/// frame-kind non-local-return mechanism, so the inline blast radius
/// stays minimal.
threadlocal var inline_fn_asts: ?std.StringHashMap([]const FnField) = null;

/// Lazy per-name cache of `inline_fn_asts` candidates resolved to plain
/// pointers, so the picking logic stays pointer-based and a name's forest decls
/// decode only on first lookup of that name.
threadlocal var inline_fn_asts_resolved: ?std.StringHashMap([]const *const ast.Function) = null;

/// Function-typed `typealias` tags by alias name (`RoutingHandler` ->
/// `"Function0"`), borrowed from `module.registry.type_aliases`. Lets the
/// shape-based overload pick recognise a parameter whose declared type is a
/// typealias for a function type — `body: RoutingHandler` is a trailing
/// lambda slot even though its `TypeRef.function` is `null`.
threadlocal var type_alias_tags: ?*const std.StringHashMap([]const u8) = null;

pub fn setTypeAliasTags(m: *const std.StringHashMap([]const u8)) void {
    type_alias_tags = m;
}

/// Non-receiver parameter arity of `ty` when it denotes a function type,
/// resolving a function-typed `typealias` by its `Function{N}` tag. `null`
/// when `ty` is not (directly or via alias) a function type.
fn fnArityOfType(ty: ast.TypeRef) ?usize {
    if (ty.function) |ft| return ft.params.len;
    const tags = type_alias_tags orelse return null;
    const tag = tags.get(ty.name.name) orelse return null;
    if (!std.mem.startsWith(u8, tag, "Function")) return null;
    return std.fmt.parseInt(usize, tag["Function".len..], 10) catch null;
}

/// Simple names that a default-imported host binding owns (e.g.
/// `kotlin.synchronized`, `kotlin.arrayOf`). Any inline fn sharing a
/// simple name with one of these must NOT shadow Kotlin's default-import
/// resolution at a bare call site; the lowerer skips inline expansion so
/// the call falls through to the normal call path.
threadlocal var shadowed_inline_names: ?StringSet = null;

/// `inline fun` ASTs keyed by the phase-1 header stub's `FuncId`, so a
/// bare call the symbol index resolves to a unique top-level target can
/// splice exactly that declaration — no simple-name re-resolution. The
/// build driver registers each top-level inline fn as it emits the
/// fn's header stub; class/object member inline fns carry no stub and
/// stay reachable only through the simple-name candidate table (the
/// index never resolves them, so a member splice always goes through
/// the receiver/shape narrowing).
threadlocal var inline_fn_ids: ?std.AutoHashMap(u32, FnField) = null;

/// Reverse index `fn-address -> id`, filled lazily as `inlineAstById` resolves a
/// `FnField`. Lets `inlineIdByAst` answer from an already-resolved fn pointer
/// without iterating + resolving every registered inline fn (which would decode
/// the whole inline forest under the lazy path).
threadlocal var inline_id_by_fn: ?std.AutoHashMap(usize, u32) = null;

/// Owner class simple name for each inline MEMBER fn AST pointer. Member
/// inline fns carry no `FuncId` stub (the index never resolves them), so a
/// bare call to a name declared as a member in several unrelated classes
/// cannot pick the enclosing-hierarchy overload from the id registry. The
/// build driver fills this by walking the class universe (user + base),
/// keyed by the same AST pointers `candidatesFor` returns. Backed by the
/// process-lifetime allocator so it survives cross-build teardown; the value
/// strings live in the build arena and are replaced each build via `reset`.
threadlocal var inline_member_owner: ?std.AutoHashMap(usize, []const u8) = null;

/// Hard ceiling on combined inline nesting (fn-body + lambda-arg
/// splices) so transitive expansion cannot recurse without bound; past
/// it, callers fall back to a normal call.
threadlocal var inline_expand_depth: u32 = 0;

/// Simple names of *top-level* (file-scope) properties — `val`/`var`
/// declared outside any class. A bare reference to such a name inside a
/// method/lambda body must resolve as a global property read, not an
/// implicit `this.<name>` field access.
threadlocal var top_level_prop_names: ?StringSet = null;

const INLINE_EXPAND_MAX: u32 = 8;

/// Install the set of top-level property simple names for the current
/// build, so bare-name lowering routes them to a global read instead of
/// an implicit `this.<name>` field access. Takes ownership of `names`;
/// any previously-installed set is freed.
pub fn setTopLevelPropNames(names: StringSet) void {
    if (top_level_prop_names) |*old| old.deinit();
    top_level_prop_names = names;
}

/// True when `name` is a known top-level (file-scope) property.
pub fn isTopLevelProp(name: []const u8) bool {
    if (top_level_prop_names) |*c| return c.contains(name);
    return false;
}

/// Install the suspend-inline-fn AST table for the current build. Each
/// simple name maps to all its inline overloads (declaration order) so a
/// call site can disambiguate a function-param overload from a
/// value-param one by the trailing-arg shape. Takes ownership of `m`.
/// Also drops the previous build's `FuncId`-keyed entries; the driver
/// re-registers them while emitting the new build's header stubs.
pub fn setInlineFnAsts(m: std.StringHashMap([]const FnField)) void {
    if (inline_fn_asts) |*old| old.deinit();
    inline_fn_asts = m;
    if (inline_fn_asts_resolved) |*old| old.deinit();
    inline_fn_asts_resolved = null;
    if (inline_fn_ids) |*old| old.deinit();
    inline_fn_ids = null;
    if (inline_id_by_fn) |*old| old.deinit();
    inline_id_by_fn = null;
}

/// Record one top-level `inline fun`'s AST under its phase-1 header
/// stub `FuncId`. Called by the build driver inside the stub loop, so
/// every id the symbol index can resolve has its AST on file before
/// phase-2 body lowering starts (class-method bodies lower earlier, but
/// the index sees no top-level candidates there and always defers). The
/// map container outlives the build arena (same process-lifetime
/// backing as the other tables here); the AST pointers share the build
/// arena's lifetime exactly like `inline_fn_asts`.
pub fn registerInlineFnId(id: u32, f: FnField) std.mem.Allocator.Error!void {
    if (inline_fn_ids == null) {
        inline_fn_ids = std.AutoHashMap(u32, FnField).init(std.heap.page_allocator);
    }
    try inline_fn_ids.?.put(id, f);
}

/// The inline-fn AST registered under a resolved top-level `FuncId`, or
/// null when the id's target is not an inline fn (or carries no stub —
/// a member fn the index never resolves). Resolves the (possibly lazy)
/// `FnField` and records the reverse `fn-addr -> id` mapping for
/// `inlineIdByAst`.
pub fn inlineAstById(id: u32) ?*const ast.Function {
    if (inline_fn_ids) |*m| {
        if (m.get(id)) |ff| {
            const f = ff.get();
            if (inline_id_by_fn == null) {
                inline_id_by_fn = std.AutoHashMap(usize, u32).init(std.heap.page_allocator);
            }
            inline_id_by_fn.?.put(@intFromPtr(f), id) catch {};
            return f;
        }
    }
    return null;
}

/// The phase-1 stub `FuncId` under which `f` was registered, or null
/// for a member inline fn (no stub, never index-resolved). The reverse
/// of `inlineAstById`; lets the resolve audit rank a simple-name pick
/// in the same scope tiers the index ranks its candidates in. `f` is an
/// already-resolved fn pointer (from a prior `inlineAstById`/candidate
/// lookup), so the reverse map already holds it.
pub fn inlineIdByAst(f: *const ast.Function) ?u32 {
    if (inline_id_by_fn) |*m| {
        if (m.get(@intFromPtr(f))) |id| return id;
    }
    // Miss: `f` was resolved by name (not through `inlineAstById`). Only the
    // resolve audit / strict mode (both off by default) calls this, so the
    // one-time resolve of the id registry is acceptable here.
    if (inline_fn_ids) |*m| {
        var it = m.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.get() == f) return e.key_ptr.*;
        }
    }
    return null;
}

/// Whether a default-imported host binding owns this simple name (see
/// `shadowed_inline_names`); such a name never splices.
pub fn isShadowedInlineName(name: []const u8) bool {
    return isShadowed(name);
}

/// Install the set of simple names owned by default-imported host
/// bindings. Inline expansion is skipped for these names so the call
/// site dispatches through the binding. Takes ownership of `names`.
pub fn setShadowedInlineNames(names: StringSet) void {
    if (shadowed_inline_names) |*old| old.deinit();
    shadowed_inline_names = names;
}

fn isShadowed(name: []const u8) bool {
    if (shadowed_inline_names) |*c| return c.contains(name);
    return false;
}

/// Public view of the same-name inline-fn candidate list, for the bare-call
/// resolver's owner-class hierarchy disambiguation.
pub fn candidatesForName(name: []const u8) ?[]const *const ast.Function {
    return candidatesFor(name);
}

/// Drop the previous build's member-owner map and start a fresh one. Call
/// once per build, before registering owners.
pub fn resetInlineMemberOwners() void {
    if (inline_member_owner) |*m| m.deinit();
    inline_member_owner = std.AutoHashMap(usize, []const u8).init(std.heap.page_allocator);
}

/// Member/object property ASTs by `owner\x1fname`, so reified-type-argument
/// inference can resolve a property-access argument's declared generic type
/// (`Nodes.Draw` -> its getter's `NodeKind<DrawModifierNode>(…)`). Keys live in
/// the build arena; the container follows the same cross-build teardown
/// discipline as the other threadlocal tables (deinit never dereferences the
/// arena-owned keys).
threadlocal var member_prop_asts: ?std.StringHashMap(*const ast.Property) = null;

/// Drop the previous build's property-AST map and start a fresh one.
pub fn resetMemberPropAsts() void {
    if (member_prop_asts) |*m| m.deinit();
    member_prop_asts = std.StringHashMap(*const ast.Property).init(std.heap.page_allocator);
}

/// Record that class/object `owner` declares property `p`. First
/// registration wins (mirrors `class_index` collision semantics).
pub fn registerMemberPropAst(a: std.mem.Allocator, owner: []const u8, p: *const ast.Property) void {
    if (member_prop_asts == null) resetMemberPropAsts();
    const key = std.fmt.allocPrint(a, "{s}\x1f{s}", .{ owner, p.name.name }) catch return;
    const gop = member_prop_asts.?.getOrPut(key) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = p;
}

/// The property AST `owner` declares under `name`, or null.
pub fn memberPropAst(owner: []const u8, name: []const u8) ?*const ast.Property {
    const m = member_prop_asts orelse return null;
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ owner, name }) catch return null;
    return m.get(key);
}

/// Record that inline member fn `f` is declared directly on class `owner`.
pub fn registerInlineMemberOwner(f: *const ast.Function, owner: []const u8) void {
    if (inline_member_owner == null) resetInlineMemberOwners();
    inline_member_owner.?.put(@intFromPtr(f), owner) catch {};
}

/// The class that declares inline member fn `f`, or null for a top-level
/// inline fn (or a member the build driver did not walk).
pub fn inlineMemberOwner(f: *const ast.Function) ?[]const u8 {
    const m = inline_member_owner orelse return null;
    return m.get(@intFromPtr(f));
}

fn candidatesFor(name: []const u8) ?[]const *const ast.Function {
    if (inline_fn_asts_resolved) |*r| {
        if (r.get(name)) |cached| return cached;
    }
    const fields = (if (inline_fn_asts) |*c| c.get(name) else null) orelse return null;
    // Resolve this name's candidates once (decoding only their forest decls) and
    // cache the pointer slice; the picking logic stays pointer-based. Also record
    // the reverse fn-addr -> id map entries via inlineAstById-style population is
    // not needed here (ids come from the id registry).
    const a = std.heap.page_allocator;
    const resolved = a.alloc(*const ast.Function, fields.len) catch return null;
    for (fields, 0..) |ff, i| resolved[i] = ff.get();
    if (inline_fn_asts_resolved == null) {
        inline_fn_asts_resolved = std.StringHashMap([]const *const ast.Function).init(a);
    }
    inline_fn_asts_resolved.?.put(name, resolved) catch return resolved;
    return resolved;
}

pub fn inlineFnAst(name: []const u8) ?*const ast.Function {
    return inlineFnAstFor(name, null);
}

/// Like [`inlineFnAstFor`] but, when several overloads share the name,
/// prefer the one whose extension `receiver_type` matches the call's
/// receiver. `recv_chain` carries the statically-known receiver type
/// followed by its transitive supertypes, most-derived first, so an
/// extension declared on a base class still matches a subclass
/// receiver — and a subclass's own extension outranks the base one.
pub fn inlineFnAstForRecv(
    name: []const u8,
    call: ?CallShape,
    recv_chain: ?[]const []const u8,
) ?*const ast.Function {
    return inlineFnAstForRecvExt(name, call, recv_chain, false);
}

/// As [`inlineFnAstForRecv`], with `require_receiver`: when the call is a
/// qualified member call (`recv.f(...)`) the inline target must be an
/// extension with a `this` receiver — a same-named *top-level* overload
/// is not a valid target and must not win the shape-based tie.
pub fn inlineFnAstForRecvExt(
    name: []const u8,
    call: ?CallShape,
    recv_chain: ?[]const []const u8,
    require_receiver: bool,
) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return inlineFnAstFor(name, call);
    if (cands.len < 2) return inlineFnAstFor(name, call);

    // Determine whether overloads span different receiver types and
    // whether any candidate is a top-level (no-receiver) overload.
    var first_recv: ?[]const u8 = null;
    var have_first = false;
    var multi_recv = false;
    var has_toplevel = false;
    for (cands) |f| {
        if (f.receiver_type) |rt| {
            if (!have_first) {
                first_recv = rt.name.name;
                have_first = true;
            } else if (!eqOpt(first_recv, rt.name.name)) {
                multi_recv = true;
            }
        } else {
            has_toplevel = true;
        }
    }

    // The effective receiver type: the most-derived chain entry that
    // any candidate declares as its receiver. A subclass extension
    // outranks a base-class one for a subclass receiver; when nothing
    // matches, the head keeps the narrowing's mismatch fallback intact.
    const recv_ty: ?[]const u8 = blk: {
        const chain = recv_chain orelse break :blk null;
        if (chain.len == 0) break :blk null;
        for (chain) |rn| {
            for (cands) |f| {
                if (f.receiver_type) |rt| {
                    if (std.mem.eql(u8, rt.name.name, rn)) break :blk rn;
                }
            }
        }
        break :blk chain[0];
    };

    // Count the narrowed candidate subset per the rules above.
    var matched: usize = 0;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) matched += 1;
    }

    const narrowed = matched < cands.len and
        ((require_receiver and has_toplevel) or (multi_recv and recv_ty != null));
    if (!narrowed or matched == 0) return inlineFnAstFor(name, call);
    return pickByShapeNarrowed(cands, call, recv_ty, require_receiver, multi_recv);
}

/// Narrowing filter predicate: drop top-level overloads for a member
/// call, and (when overloads differ by receiver and the call's receiver
/// type is known) keep only matching-receiver overloads.
fn keepNarrowed(
    f: *const ast.Function,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) bool {
    if (require_receiver and f.receiver_type == null) return false;
    if (multi_recv) {
        if (recv_ty) |rt| {
            return if (f.receiver_type) |r| std.mem.eql(u8, r.name.name, rt) else false;
        }
    }
    return true;
}

fn eqOpt(a: ?[]const u8, b: []const u8) bool {
    if (a) |x| return std.mem.eql(u8, x, b);
    return false;
}

/// Shape-based pick restricted to the narrowed candidate subset, without
/// materialising the subset into a temporary slice.
fn pickByShapeNarrowed(
    cands: []const *const ast.Function,
    call: ?CallShape,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) ?*const ast.Function {
    var first: ?*const ast.Function = null;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) {
            first = f;
            break;
        }
    }
    const shape = call orelse return first;
    // Count narrowed candidates for the `< 2` early-out.
    var n_narrowed: usize = 0;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) n_narrowed += 1;
    }
    if (n_narrowed < 2) return first;
    if (!shape.last_is_lambda) {
        return pickNonlambdaShapeNarrowed(cands, recv_ty, require_receiver, multi_recv) orelse first;
    }
    const lead = shape.want -| 1;
    var match: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (!keepNarrowed(f, recv_ty, require_receiver, multi_recv)) continue;
        if (fitsTrailingLambda(f, lead)) {
            match = f;
            count += 1;
        }
    }
    if (count == 1) return match;
    // Several overloads fit the trailing-lambda shape. Prefer the one whose
    // trailing function-type parameter arity matches the lambda's declared
    // arity: a bare `{ … }` handler (arity 0) resolves to the
    // `T.() -> R` overload, not a reified `T.(X) -> R` one whose `X` a
    // parameterless lambda cannot infer. Mirrors Kotlin dropping a generic
    // overload whose type argument is unconstrained by the call.
    if (shape.trailing_lambda_arity) |want_arity| {
        var arity_match: ?*const ast.Function = null;
        var arity_count: usize = 0;
        for (cands) |f| {
            if (!keepNarrowed(f, recv_ty, require_receiver, multi_recv)) continue;
            if (!fitsTrailingLambda(f, lead)) continue;
            if (trailingFnTypeArity(f) == want_arity) {
                arity_match = f;
                arity_count += 1;
            }
        }
        if (arity_count == 1) return arity_match;
    }
    return first;
}

/// Parameter arity of `f`'s trailing function-typed parameter (the
/// non-receiver parameters of `T.(A, B) -> R`), or `null` when the last
/// parameter is not a function type.
fn trailingFnTypeArity(f: *const ast.Function) ?usize {
    if (f.params.len == 0) return null;
    return fnArityOfType(f.params[f.params.len - 1].ty);
}

fn pickNonlambdaShapeNarrowed(
    cands: []const *const ast.Function,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) ?*const ast.Function {
    var only: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (!keepNarrowed(f, recv_ty, require_receiver, multi_recv)) continue;
        if (noRequiredFnParam(f)) {
            only = f;
            count += 1;
            if (count > 1) return null;
        }
    }
    if (count == 1) return only;
    return null;
}

fn fitsTrailingLambda(f: *const ast.Function, lead: usize) bool {
    const n = f.params.len;
    if (n == 0) return false;
    if (fnArityOfType(f.params[n - 1].ty) == null) return false;
    const leading = f.params[0 .. n - 1];
    var required: usize = 0;
    for (leading) |p| {
        if (p.default == null and !p.is_vararg) required += 1;
    }
    const last_lead_vararg = leading.len != 0 and leading[leading.len - 1].is_vararg;
    return lead >= required and (lead <= leading.len or last_lead_vararg);
}

/// Disambiguate a call whose last argument is *not* a lambda among
/// same-name overloads. When exactly one overload has *no* required
/// function-typed parameter, it is the applicable one. Returns `null`
/// (defer to first-declared) when the filter is not decisive.
fn pickNonlambdaShape(cands: []const *const ast.Function) ?*const ast.Function {
    var only: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (noRequiredFnParam(f)) {
            only = f;
            count += 1;
            if (count > 1) return null;
        }
    }
    if (count == 1) return only;
    return null;
}

fn noRequiredFnParam(f: *const ast.Function) bool {
    for (f.params) |p| {
        if (p.ty.function != null and p.default == null and !p.is_noinline) return false;
    }
    return true;
}

/// Resolve the inline overload of `name` for a call whose shape is
/// `call = (positional_arg_count, last_arg_is_lambda)`.
///
/// Deliberately conservative: returns the first-declared overload in
/// every case *except* a trailing-lambda call for which exactly one
/// arity-fitting overload has a function-typed last parameter — then that
/// overload wins.
pub fn inlineFnAstFor(name: []const u8, call: ?CallShape) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return null;
    const first: ?*const ast.Function = if (cands.len > 0) cands[0] else null;
    const shape = call orelse return first;
    if (cands.len < 2) return first;
    if (!shape.last_is_lambda) return pickNonlambdaShape(cands) orelse first;
    const lead = shape.want -| 1;
    var match: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (fitsTrailingLambda(f, lead)) {
            match = f;
            count += 1;
        }
    }
    if (count == 1) return match;
    return first;
}

/// Among the inline overloads of `name` that fit the call shape, return the
/// one declaring a `reified` type parameter (if any). A call with an explicit
/// `<T>` argument binds that argument to a reified parameter, so a reified
/// overload outranks a non-reified `KClass<T>`-parameter namesake of the same
/// shape — without this, `assertFailsWith<E>(msg) { … }` resolves to the
/// `assertFailsWith(KClass<E>, …)` overload and the type argument lowers as a
/// constructor value rather than binding `T::class`.
pub fn reifiedInlineFnAstFor(name: []const u8, call: ?CallShape) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return null;
    if (cands.len < 2) return null;
    const shape = call orelse return null;
    if (!shape.last_is_lambda) return null;
    const lead = shape.want -| 1;
    // The first reified overload of this shape. Sibling reified overloads that
    // differ only in the block's return type (`() -> Any?` vs `() -> Unit`)
    // splice the same body, so the first fitting one is sufficient to bind the
    // type argument as `T::class`.
    for (cands) |f| {
        if (fitsTrailingLambda(f, lead) and fnHasReified(f)) return f;
    }
    return null;
}

fn fnHasReified(f: *const ast.Function) bool {
    for (f.type_params) |tp| if (tp.is_reified) return true;
    return false;
}

pub fn inlineExpandEnter() bool {
    if (inline_expand_depth >= INLINE_EXPAND_MAX) return false;
    inline_expand_depth += 1;
    return true;
}

pub fn inlineExpandLeave() void {
    inline_expand_depth -|= 1;
}

/// Release any installed tables. Used by tests and by a build driver
/// tearing down between builds.
pub fn resetForTest() void {
    if (inline_fn_asts) |*m| {
        m.deinit();
        inline_fn_asts = null;
    }
    if (inline_fn_asts_resolved) |*m| {
        m.deinit();
        inline_fn_asts_resolved = null;
    }
    if (inline_fn_ids) |*m| {
        m.deinit();
        inline_fn_ids = null;
    }
    if (inline_id_by_fn) |*m| {
        m.deinit();
        inline_id_by_fn = null;
    }
    if (shadowed_inline_names) |*s| {
        s.deinit();
        shadowed_inline_names = null;
    }
    if (top_level_prop_names) |*s| {
        s.deinit();
        top_level_prop_names = null;
    }
    inline_expand_depth = 0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "top-level prop names round-trip" {
    defer resetForTest();
    var names = StringSet.init(testing.allocator);
    try names.put("LOGGER", {});
    setTopLevelPropNames(names);
    try testing.expect(isTopLevelProp("LOGGER"));
    try testing.expect(!isTopLevelProp("other"));
}

test "shadowed name suppresses inline lookup" {
    defer resetForTest();
    var shadowed = StringSet.init(testing.allocator);
    try shadowed.put("synchronized", {});
    setShadowedInlineNames(shadowed);
    try testing.expect(inlineFnAst("synchronized") == null);
    try testing.expect(isShadowedInlineName("synchronized"));
    try testing.expect(!isShadowedInlineName("other"));
}

test "inline fn ids register, look up, and reset with the table" {
    defer resetForTest();
    var f: ast.Function = undefined;
    try registerInlineFnId(7, FnField.fromPtr(&f));
    try testing.expect(inlineAstById(7) == @as(?*const ast.Function, &f));
    try testing.expect(inlineAstById(8) == null);
    // Installing the next build's simple-name table drops the previous
    // build's FuncId entries.
    setInlineFnAsts(std.StringHashMap([]const FnField).init(testing.allocator));
    try testing.expect(inlineAstById(7) == null);
}

test "inline expand depth guard caps at max" {
    defer resetForTest();
    var entered: u32 = 0;
    while (inlineExpandEnter()) entered += 1;
    try testing.expectEqual(INLINE_EXPAND_MAX, entered);
    // Past the ceiling, further enters fail until we leave.
    try testing.expect(!inlineExpandEnter());
    inlineExpandLeave();
    try testing.expect(inlineExpandEnter());
}
