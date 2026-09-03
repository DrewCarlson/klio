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
const decl = @import("decl.zig");
const span = @import("span");
pub const runtime = @import("runtime");

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
    /// The call site's file. A `private` inline declaration is scoped to
    /// its own file; the simple-name candidate table spans the whole
    /// program, so without this a file-private `List.fastForEach` in one
    /// pack file spliced into an unrelated caller. Null keeps every
    /// candidate (callers that predate the field).
    call_file: ?span.FileId = null,
    /// The first argument is a class literal (`subclass(C::class)`). Breaks
    /// a same-arity reified overload tie toward the candidate whose first
    /// parameter is a `KClass` (`subclass(clazz)` over
    /// `subclass(serializer)`), which registration order otherwise decides.
    arg0_class_literal: bool = false,
};

/// Whether `f` is visible to a call in `call_file`: a `private`
/// declaration only from its own file. Unknown call file keeps the
/// candidate (conservative — the old behavior).
fn candVisibleFrom(f: *const ast.Function, call_file: ?span.FileId) bool {
    if (f.visibility != .Private) return true;
    const cf = call_file orelse return true;
    return f.name.span.file.int() == cf.int();
}

/// `cands` minus the file-private declarations the call site cannot see.
/// Returns a slice into `buf`; falls back to the unfiltered slice when
/// there are more candidates than `buf` holds.
fn visibleCands(cands: []const *const ast.Function, call_file: ?span.FileId, buf: []*const ast.Function) []const *const ast.Function {
    if (call_file == null) return cands;
    if (cands.len > buf.len) return cands;
    var n: usize = 0;
    for (cands) |f| {
        if (candVisibleFrom(f, call_file)) {
            buf[n] = f;
            n += 1;
        }
    }
    return buf[0..n];
}

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
/// `kotlin.synchronized`, `kotlin.arrayOf`). An inline declaration sharing
/// one of these names cannot be selected from the ad-hoc simple-name table;
/// ordinary calls fall through to the host binding, while scope-aware exact
/// resolution can still recover the corresponding source declaration.
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
var expr_body_members: ?std.StringHashMap(FnField) = null;

/// Record an expression-bodied member with NO return annotation under
/// its (owner, name, arity) key, so a caller lowered BEFORE the member's
/// own decl pass can derive the inferred return on demand (declaration
/// order must not decide whether a local types).
pub fn registerExprBodyMember(owner: []const u8, f: *const ast.Function) std.mem.Allocator.Error!void {
    if (expr_body_members == null) {
        expr_body_members = std.StringHashMap(FnField).init(std.heap.page_allocator);
    }
    const key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}\x1f{d}", .{ owner, f.name.name, f.params.len });
    if (runtime.envSetOnce("KLIO_EBM_TRACE") and std.mem.eql(u8, f.name.name, "createOnCancellationAction"))
        std.debug.print("[ebm] register owner={s} arity={d}\n", .{ owner, f.params.len });
    try expr_body_members.?.put(key, FnField.fromPtr(f));
}

/// Drop every registered expression-body member AST (and free the owned
/// keys). The pointers share ONE program's build arena; an in-process
/// driver must clear them at the run boundary or the next program's
/// same-named lookups read freed memory.
pub fn resetExprBodyMembers() void {
    if (expr_body_members) |*m| {
        var it = m.keyIterator();
        while (it.next()) |k| std.heap.page_allocator.free(k.*);
        m.deinit();
        expr_body_members = null;
    }
}

/// The registered expression body for (owner, name, arity), or null.
pub fn exprBodyMemberAst(owner: []const u8, name: []const u8, nparams: usize) ?*const ast.Function {
    var buf: [256]u8 = undefined;
    if (runtime.envSetOnce("KLIO_EBM_TRACE") and std.mem.eql(u8, name, "createOnCancellationAction"))
        std.debug.print("[ebm] lookup owner={s} arity={d} n={d}\n", .{ owner, nparams, if (expr_body_members) |m| m.count() else 0 });
    if (expr_body_members) |*m| {
        const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}\x1f{d}", .{ owner, name, nparams }) catch return null;
        if (m.get(key)) |ff| return ff.get();
        // A LIFTED nested class spells `Outer$Inner`; the registration walk
        // spells the source-simple `Inner`. Normalize on miss.
        if (std.mem.lastIndexOfScalar(u8, owner, '$')) |d| {
            const key2 = std.fmt.bufPrint(&buf, "{s}\x1f{s}\x1f{d}", .{ owner[d + 1 ..], name, nparams }) catch return null;
            if (m.get(key2)) |ff| return ff.get();
        }
    }
    return null;
}

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

/// Install the set of simple names owned by default-imported host bindings.
/// Ad-hoc name lookup is skipped for these names so ordinary calls dispatch
/// through the binding. Takes ownership of `names`.
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

/// Member-EXTENSION property receiver-type heads by `owner\x1fname`. Distinct
/// from `member_prop_asts` (first-registration-wins) because a class can
/// declare BOTH a same-named member (e.g. `override val parent`) AND a
/// member-extension property (`private val Composition.parent`); the member
/// would otherwise hide the extension in that map. Used at a property-read
/// site to detect that the receiver's STATIC type resolves the read to the
/// in-scope extension getter rather than the runtime object's stored field.
threadlocal var member_ext_prop_recv: ?std.StringHashMap([]const u8) = null;

pub fn resetMemberExtPropRecv() void {
    if (member_ext_prop_recv) |*m| m.deinit();
    member_ext_prop_recv = std.StringHashMap([]const u8).init(std.heap.page_allocator);
}

/// Record that class `owner` declares a member-extension property `name`
/// whose extension-receiver type head is `recv_head`.
pub fn registerMemberExtPropRecv(a: std.mem.Allocator, owner: []const u8, name: []const u8, recv_head: []const u8) void {
    if (member_ext_prop_recv == null) resetMemberExtPropRecv();
    const key = std.fmt.allocPrint(a, "{s}\x1f{s}", .{ owner, name }) catch return;
    const gop = member_ext_prop_recv.?.getOrPut(key) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = recv_head;
}

/// The extension-receiver type head of the member-extension property `owner`
/// declares under `name`, or null when `owner` declares no such extension.
pub fn memberExtPropRecv(owner: []const u8, name: []const u8) ?[]const u8 {
    const m = member_ext_prop_recv orelse return null;
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ owner, name }) catch return null;
    return m.get(key);
}

/// Declared supertype references (with their type arguments) by class/object
/// simple name. Reified-type-argument inference reads them so an argument
/// naming a declaration (`serializersModuleOf(BSerializer)` where
/// `object BSerializer : KSerializer<B>`) solves the parameter's type
/// argument from the declaration's own supertype list.
threadlocal var class_supertype_refs: ?std.StringHashMap([]const ast.TypeRef) = null;

pub fn resetClassSupertypeRefs() void {
    if (class_supertype_refs) |*m| m.deinit();
    class_supertype_refs = std.StringHashMap([]const ast.TypeRef).init(std.heap.page_allocator);
}

/// Record `name`'s declared supertypes. First registration wins, matching the
/// other AST registries.
pub fn registerClassSupertypeRefs(name: []const u8, sups: []const ast.TypeRef) void {
    if (sups.len == 0) return;
    if (class_supertype_refs == null) resetClassSupertypeRefs();
    const gop = class_supertype_refs.?.getOrPut(name) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = sups;
}

/// The declared supertypes of `name`, or null.
pub fn classSupertypeRefs(name: []const u8) ?[]const ast.TypeRef {
    const m = class_supertype_refs orelse return null;
    return m.get(name);
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
    var buf = a.alloc(*const ast.Function, fields.len) catch return null;
    // A `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`
    // inline overload is not a source-level candidate (kotlinc hides it): the
    // HIDDEN `Flow.collect(action)` binary-compat form was the SOLE inline
    // candidate for `collect`, so `collect(NopCollector)` spliced it and
    // wrapped the collector in its action-invoking anon object.
    var n: usize = 0;
    for (fields) |ff| {
        const f = ff.get();
        if (decl.annotationsAreLowPriority(f.annotations)) continue;
        buf[n] = f;
        n += 1;
    }
    const resolved = buf[0..n];
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
    const ptrace = if (runtime.envOnce("KLIO_INLINE_PICK")) |w| std.mem.eql(u8, w, name) else false;
    const all = candidatesFor(name) orelse return inlineFnAstFor(name, call);
    var vis_buf: [24]*const ast.Function = undefined;
    const cands = visibleCands(all, if (call) |c| c.call_file else null, &vis_buf);
    if (cands.len == 0) return null;
    if (ptrace) {
        std.debug.print("[ipick] {s} n={d} chain0={s}:", .{ name, cands.len, if (recv_chain) |ch| (if (ch.len > 0) ch[0] else "<empty>") else "<null>" });
        for (cands) |c| std.debug.print(" recv={s}/owner={s}/file={d}", .{ if (c.receiver_type) |rt| rt.name.name else "-", inlineMemberOwner(c) orelse "-", c.name.span.file.int() });
        std.debug.print("\n", .{});
    }
    if (cands.len < 2) return inlineFnAstFor(name, call);

    // Determine whether overloads span different receiver types and
    // whether any candidate is a top-level (no-receiver) overload. A
    // member-inline fn's owner class is its receiver type for this
    // purpose: a bare `traverseChildren(...)` inside an extension on
    // `SlotTableAddressSpace` must bind that class's own member, not a
    // same-named member of an unrelated class that registered first.
    var first_recv: ?[]const u8 = null;
    var have_first = false;
    var multi_recv = false;
    var has_toplevel = false;
    for (cands) |f| {
        if (candRecvName(f)) |rn| {
            if (!have_first) {
                first_recv = rn;
                have_first = true;
            } else if (!eqOpt(first_recv, rn)) {
                multi_recv = true;
            }
        } else {
            has_toplevel = true;
        }
    }

    // No receiver evidence at the call site at all: an extension-only
    // overload set cannot be narrowed — splicing one binds a receiver
    // the scope may not even contain (`get(it)` inside a plain lambda
    // must fall to the receiver walk, not splice `HttpClient.get`).
    // Decline; the normal dispatch paths decide against the real
    // runtime receivers.
    if (recv_chain == null and !has_toplevel) return null;

    // The effective receiver type: the most-derived chain entry that
    // any candidate declares as its receiver. A subclass extension
    // outranks a base-class one for a subclass receiver; when nothing
    // matches, the head keeps the narrowing's mismatch fallback intact.
    const recv_ty: ?[]const u8 = blk: {
        const chain = recv_chain orelse break :blk null;
        if (chain.len == 0) break :blk null;
        for (chain) |rn| {
            for (cands) |f| {
                if (candRecvName(f)) |crn| {
                    if (std.mem.eql(u8, crn, rn)) break :blk rn;
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
            return if (candRecvName(f)) |r| std.mem.eql(u8, r, rt) else false;
        }
    }
    return true;
}

/// A candidate's effective receiver class name: an extension's declared
/// `receiver_type`, or the owner class for a member-inline fn. Null only
/// for a plain top-level inline fn.
fn candRecvName(f: *const ast.Function) ?[]const u8 {
    if (f.receiver_type) |rt| return rt.name.name;
    return inlineMemberOwner(f);
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

/// A pass-threaded composable declaration carries a trailing
/// `($composer, $changed)` pair the CALL SITE does not write; every
/// shape judgment runs on the user-visible params.
fn userParams(f: *const ast.Function) []const ast.Param {
    const p = f.params;
    if (p.len >= 2 and std.mem.eql(u8, p[p.len - 1].name.name, "$changed") and
        std.mem.eql(u8, p[p.len - 2].name.name, "$composer"))
    {
        return p[0 .. p.len - 2];
    }
    return p;
}

/// Parameter arity of `f`'s trailing function-typed parameter (the
/// non-receiver parameters of `T.(A, B) -> R`), or `null` when the last
/// parameter is not a function type.
fn trailingFnTypeArity(f: *const ast.Function) ?usize {
    const params = userParams(f);
    if (params.len == 0) return null;
    return fnArityOfType(params[params.len - 1].ty);
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
    const params = userParams(f);
    const n = params.len;
    if (n == 0) return false;
    if (fnArityOfType(params[n - 1].ty) == null) return false;
    const leading = params[0 .. n - 1];
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

/// Whether `f` can take `want` positional arguments: at least the required
/// (non-defaulted, non-vararg) count, and no more than the declared total —
/// unless a vararg absorbs the excess.
/// Whether several overloads fit the call's arity but declare DIFFERENT
/// value-parameter types. Shape cannot separate those, so the first-declared
/// fallback below is a coin flip. androidx.collection declares
/// `ArraySet<E>.addAllInternal(ArraySet<out E>)` beside
/// `ArraySet<E>.addAllInternal(Collection<E>)`; a bare `addAllInternal(elements)`
/// inside `ArraySet.addAll` spliced the ArraySet body and read `.array` off a
/// List. Declining to splice hands the call to normal dispatch, which ranks by
/// argument type and picks correctly — the same call written `this.addAllInternal(…)`
/// always resolved, because it never reached the splice path.
/// Among arity-fitting candidates, the unique one whose first parameter is
/// declared `KClass` — the overload a class-literal first argument selects.
fn pickKClassParam(cands: []const *const ast.Function, want: usize) ?*const ast.Function {
    var hit: ?*const ast.Function = null;
    for (cands) |f| {
        if (!fitsArity(f, want)) continue;
        const params = userParams(f);
        if (params.len == 0) continue;
        const head = std.mem.trimEnd(u8, params[0].ty.name.name, "?");
        if (!std.mem.eql(u8, head, "KClass")) continue;
        if (hit != null) return null;
        hit = f;
    }
    return hit;
}

fn ambiguousByParamTypes(cands: []const *const ast.Function, want: usize) bool {
    var seen: ?[]const u8 = null;
    for (cands) |f| {
        if (!fitsArity(f, want)) continue;
        // A reified type parameter can only be honoured by splicing, so an
        // ambiguous set containing one keeps the existing behaviour rather
        // than losing the type argument to the runtime walk.
        for (f.type_params) |tp| if (tp.is_reified) return false;
        const params = userParams(f);
        if (params.len == 0) return false;
        const ty = params[0].ty.name.name;
        if (seen) |prev| {
            if (!std.mem.eql(u8, prev, ty)) return true;
        } else seen = ty;
    }
    return false;
}

fn fitsArity(f: *const ast.Function, want: usize) bool {
    const params = userParams(f);
    var required: usize = 0;
    var has_vararg = false;
    for (params) |p| {
        if (p.is_vararg) {
            has_vararg = true;
            continue;
        }
        if (p.default == null) required += 1;
    }
    if (want < required) return false;
    return has_vararg or want <= params.len;
}

/// The single overload whose arity fits the call's argument count, or null
/// when zero or several fit. The last-resort discriminator before blind
/// first-declared: a plugin-threaded `remember(k1..k4, calc, $composer,
/// $changed)` (7 args, lambda NOT last) only fits the vararg overload.
fn pickUniqueArityFit(cands: []const *const ast.Function, want: usize) ?*const ast.Function {
    var only: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (fitsArity(f, want)) {
            only = f;
            count += 1;
            if (count > 1) return null;
        }
    }
    if (count == 1) return only;
    return null;
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
    const all = candidatesFor(name) orelse return null;
    var vis_buf: [24]*const ast.Function = undefined;
    const cands = visibleCands(all, if (call) |c| c.call_file else null, &vis_buf);
    const first: ?*const ast.Function = if (cands.len > 0) cands[0] else null;
    const shape = call orelse return first;
    if (cands.len < 2) return first;
    if (!shape.last_is_lambda) {
        if (shape.arg0_class_literal) {
            if (pickKClassParam(cands, shape.want)) |f| return f;
        }
        if (pickNonlambdaShape(cands)) |f| return f;
        if (pickUniqueArityFit(cands, shape.want)) |f| return f;
        if (ambiguousByParamTypes(cands, shape.want)) return null;
        return first;
    }
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
    return pickUniqueArityFit(cands, shape.want) orelse first;
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

/// A REIFIED inline callee past the ordinary depth still splices: unspliced,
/// its body would read the process-global `T` of some outer splice. The
/// higher cap only bounds runaway recursion.
pub fn inlineExpandEnterReified() bool {
    if (inline_expand_depth >= INLINE_EXPAND_MAX * 3) return false;
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

test "shadowed host name suppresses simple-name inline lookup" {
    defer resetForTest();
    var shadowed = StringSet.init(testing.allocator);
    try shadowed.put("synchronized", {});
    setShadowedInlineNames(shadowed);
    try testing.expect(inlineFnAst("synchronized") == null);
    try testing.expect(isShadowed("synchronized"));
    try testing.expect(!isShadowed("other"));
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
