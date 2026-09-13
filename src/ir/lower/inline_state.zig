//! Process-global registries for the inline-expansion machinery: the
//! `suspend inline fun` AST table and the inline-nesting depth guard. Pure state
//! primitives with no `FuncBuilder` or IR-side dependency, under a
//! single-build-at-a-time contract: the driver installs the tables once per build,
//! then lowers bodies serially.

const std = @import("std");
const ast = @import("ast");
const decl = @import("decl.zig");
const span = @import("span");
pub const runtime = @import("runtime");

const Allocator = std.mem.Allocator;
const StringSet = std.StringHashMap(void);
const FnField = runtime.forest.ForestField(ast.Function);

// Deferred inline-body decode. A stdlib image holds `inline`, object-free function
// bodies in a side section, decoded on first splice. The marker is an empty block
// whose `span.file == span.DEFERRED_BODY_FILE` and whose `span.start` is the body's
// byte offset. The decoder lives in `interp_ir`, which depends on this module, so
// it is injected as a function pointer at base-install time.
const DeferredDecodeFn = *const fn (Allocator, []const u8, u32) ?ast.FunctionBody;
threadlocal var deferred_section: []const u8 = &.{};
threadlocal var deferred_alloc: Allocator = undefined;
threadlocal var deferred_decode: ?DeferredDecodeFn = null;

/// Install the loaded base's deferred-body section, the process-lifetime allocator
/// a decoded body must persist in, and the decoder. Once per build that uses a
/// base; a freshly built base passes an empty section.
pub fn setDeferredSection(section: []const u8, alloc: Allocator, decode: DeferredDecodeFn) void {
    deferred_section = section;
    deferred_alloc = alloc;
    deferred_decode = decode;
}

/// If `f`'s body is a deferred marker, decode the real body from the side section
/// and patch it in place, idempotently. Call before reading a body for splicing.
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
/// last_arg_is_lambda)`. Null when the caller has no shape hint.
pub const CallShape = struct {
    want: usize,
    last_is_lambda: bool,
    /// Declared parameter arity of the trailing lambda or anon-fun argument, a
    /// zero-`->` `{ … }` being 0 since the injected `it` does not count; null when
    /// the last argument is not a lambda. Breaks a trailing-lambda overload tie
    /// toward the candidate whose trailing fn-type parameter arity matches, a bare
    /// `{ … }` handler being unable to supply a reified `T.(X) -> R`'s argument.
    trailing_lambda_arity: ?usize = null,
    /// The call site's file. A `private` inline declaration is scoped to its own
    /// file while the candidate table spans the program; null keeps every candidate.
    call_file: ?span.FileId = null,
    /// The first argument is a class literal, breaking a same-arity reified overload
    /// tie toward the candidate whose first parameter is a `KClass`.
    arg0_class_literal: bool = false,
};

/// Whether `f` is visible to a call in `call_file`: a `private` declaration only
/// from its own file. An unknown call file keeps the candidate.
fn candVisibleFrom(f: *const ast.Function, call_file: ?span.FileId) bool {
    if (f.visibility != .Private) return true;
    const cf = call_file orelse return true;
    return f.name.span.file.int() == cf.int();
}

/// `cands` minus the file-private declarations the call site cannot see. Returns a
/// slice into `buf`, falling back to the unfiltered slice when it does not fit.
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

/// `suspend inline fun` ASTs by simple name, set by the build driver before body
/// lowering. A `suspend inline` builder's `suspendCoroutineUninterceptedOrReturn`
/// must capture the caller's continuation, correct only when the body is truly
/// inlined. Non-suspend inline fns keep the normal call path.
threadlocal var inline_fn_asts: ?std.StringHashMap([]const FnField) = null;

/// Lazy per-name cache of `inline_fn_asts` candidates resolved to plain pointers,
/// so the picking logic stays pointer-based and a name's decls decode once.
threadlocal var inline_fn_asts_resolved: ?std.StringHashMap([]const *const ast.Function) = null;

/// Function-typed `typealias` tags by alias name (`RoutingHandler` ->
/// `"Function0"`), borrowed from `module.registry.type_aliases`, so the shape-based
/// pick recognises a parameter whose declared type aliases a function type.
threadlocal var type_alias_tags: ?*const std.StringHashMap([]const u8) = null;

pub fn setTypeAliasTags(m: *const std.StringHashMap([]const u8)) void {
    type_alias_tags = m;
}

/// Non-receiver parameter arity of `ty` when it denotes a function type, resolving
/// a function-typed `typealias` by its `Function{N}` tag.
fn fnArityOfType(ty: ast.TypeRef) ?usize {
    if (ty.function) |ft| return ft.params.len;
    const tags = type_alias_tags orelse return null;
    const tag = tags.get(ty.name.name) orelse return null;
    if (!std.mem.startsWith(u8, tag, "Function")) return null;
    return std.fmt.parseInt(usize, tag["Function".len..], 10) catch null;
}

/// Simple names a default-imported host binding owns. An inline declaration sharing
/// one cannot be selected from the ad-hoc simple-name table, so ordinary calls fall
/// through to the host binding while scope-aware resolution still finds the source.
threadlocal var shadowed_inline_names: ?StringSet = null;

/// `inline fun` ASTs keyed by the phase-1 header stub's `FuncId`, so a bare call the
/// symbol index resolves to a unique top-level target splices exactly that
/// declaration. Member inline fns carry no stub and stay reachable only through the
/// simple-name candidate table.
threadlocal var inline_fn_ids: ?std.AutoHashMap(u32, FnField) = null;

/// Reverse index from fn address to id, filled lazily as `inlineAstById` resolves a
/// `FnField`, so `inlineIdByAst` answers without decoding the whole inline forest.
threadlocal var inline_id_by_fn: ?std.AutoHashMap(usize, u32) = null;

/// Owner class simple name for each inline member fn AST pointer. Member inline fns
/// carry no `FuncId` stub, so a bare call to a name several unrelated classes
/// declare cannot pick the enclosing-hierarchy overload from the id registry. The
/// build driver fills this by walking the class universe, keyed by the same AST
/// pointers `candidatesFor` returns. Process-lifetime backed so it survives
/// cross-build teardown; the value strings live in the build arena.
threadlocal var inline_member_owner: ?std.AutoHashMap(usize, []const u8) = null;

/// Hard ceiling on combined inline nesting, fn-body plus lambda-arg splices, so
/// transitive expansion cannot recurse without bound; past it, callers fall back.
threadlocal var inline_expand_depth: u32 = 0;

/// Simple names of top-level properties. A bare reference to one inside a method or
/// lambda body resolves as a global read, not an implicit `this.<name>` access.
threadlocal var top_level_prop_names: ?StringSet = null;

const INLINE_EXPAND_MAX: u32 = 8;

/// Install the set of top-level property simple names for the current build. Takes
/// ownership of `names`; any previously installed set is freed.
pub fn setTopLevelPropNames(names: StringSet) void {
    if (top_level_prop_names) |*old| old.deinit();
    top_level_prop_names = names;
}

/// True when `name` is a known top-level (file-scope) property.
pub fn isTopLevelProp(name: []const u8) bool {
    if (top_level_prop_names) |*c| return c.contains(name);
    return false;
}

/// Install the suspend-inline-fn AST table for the current build, each simple name
/// mapping to its inline overloads in declaration order so a call site can
/// disambiguate by trailing-arg shape. Takes ownership of `m` and drops the previous
/// build's `FuncId`-keyed entries, which the driver re-registers.
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

/// Record one top-level `inline fun`'s AST under its phase-1 header stub `FuncId`,
/// called inside the stub loop so every id the symbol index can resolve has its AST
/// on file before phase-2 body lowering. The container outlives the build arena; the
/// AST pointers share it, exactly like `inline_fn_asts`.
var expr_body_members: ?std.StringHashMap(FnField) = null;

/// Record an expression-bodied member with no return annotation under its
/// (owner, name, arity) key, so a caller lowered before the member's own decl pass
/// derives the inferred return on demand.
pub fn registerExprBodyMember(owner: []const u8, f: *const ast.Function) std.mem.Allocator.Error!void {
    if (expr_body_members == null) {
        expr_body_members = std.StringHashMap(FnField).init(std.heap.page_allocator);
    }
    const key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}\x1f{d}", .{ owner, f.name.name, f.params.len });
    if (runtime.envSetOnce("KLIO_EBM_TRACE") and std.mem.eql(u8, f.name.name, "createOnCancellationAction"))
        std.debug.print("[ebm] register owner={s} arity={d}\n", .{ owner, f.params.len });
    try expr_body_members.?.put(key, FnField.fromPtr(f));
}

/// Drop every registered expression-body member AST and free the owned keys. The
/// pointers share one program's build arena, so an in-process driver must clear them
/// at the run boundary.
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
        // A lifted nested class spells `Outer$Inner` while the registration walk
        // spells the source-simple `Inner`; normalize on miss.
        if (std.mem.findScalarLast(u8, owner, '$')) |d| {
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

/// The inline-fn AST registered under a resolved top-level `FuncId`, or null when
/// the target is not an inline fn or carries no stub. Resolves the possibly lazy
/// `FnField` and records the reverse fn-address mapping for `inlineIdByAst`.
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

/// The phase-1 stub `FuncId` under which `f` was registered, or null for a member
/// inline fn: the reverse of `inlineAstById`, letting the resolve audit rank a
/// simple-name pick in the index's own scope tiers.
pub fn inlineIdByAst(f: *const ast.Function) ?u32 {
    if (inline_id_by_fn) |*m| {
        if (m.get(@intFromPtr(f))) |id| return id;
    }
    // Miss: `f` was resolved by name rather than through `inlineAstById`. Only the
    // resolve audit and strict mode call this, so a one-time resolve is acceptable.
    if (inline_fn_ids) |*m| {
        var it = m.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.get() == f) return e.key_ptr.*;
        }
    }
    return null;
}

/// Install the set of simple names owned by default-imported host bindings, for
/// which ad-hoc name lookup is skipped. Takes ownership of `names`.
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

/// Drop the previous build's member-owner map and start a fresh one, once per
/// build before registering owners.
pub fn resetInlineMemberOwners() void {
    if (inline_member_owner) |*m| m.deinit();
    inline_member_owner = std.AutoHashMap(usize, []const u8).init(std.heap.page_allocator);
}

/// Member and object property ASTs by `owner\x1fname`, so reified-type-argument
/// inference can resolve a property-access argument's declared generic type. Keys
/// live in the build arena, under the same teardown discipline as the other tables.
threadlocal var member_prop_asts: ?std.StringHashMap(*const ast.Property) = null;

/// Drop the previous build's property-AST map and start a fresh one.
pub fn resetMemberPropAsts() void {
    if (member_prop_asts) |*m| m.deinit();
    member_prop_asts = std.StringHashMap(*const ast.Property).init(std.heap.page_allocator);
}

/// Record that class or object `owner` declares property `p`. First registration
/// wins, mirroring `class_index` collision semantics.
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

/// Member-extension property receiver-type heads by `owner\x1fname`. Distinct from
/// the first-registration-wins `member_prop_asts`, since a class can declare both a
/// same-named member and a member-extension property and the member would hide it.
/// Used at a read site to detect that the receiver's static type resolves the read
/// to the in-scope extension getter rather than a stored field.
threadlocal var member_ext_prop_recv: ?std.StringHashMap([]const u8) = null;

pub fn resetMemberExtPropRecv() void {
    if (member_ext_prop_recv) |*m| m.deinit();
    member_ext_prop_recv = std.StringHashMap([]const u8).init(std.heap.page_allocator);
}

/// Record that class `owner` declares a member-extension property `name` whose
/// extension-receiver type head is `recv_head`.
pub fn registerMemberExtPropRecv(a: std.mem.Allocator, owner: []const u8, name: []const u8, recv_head: []const u8) void {
    if (member_ext_prop_recv == null) resetMemberExtPropRecv();
    const key = std.fmt.allocPrint(a, "{s}\x1f{s}", .{ owner, name }) catch return;
    const gop = member_ext_prop_recv.?.getOrPut(key) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = recv_head;
}

/// The extension-receiver type head of the member-extension property `owner`
/// declares under `name`, or null when it declares no such extension.
pub fn memberExtPropRecv(owner: []const u8, name: []const u8) ?[]const u8 {
    const m = member_ext_prop_recv orelse return null;
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ owner, name }) catch return null;
    return m.get(key);
}

/// Declared supertype references, with their type arguments, by class or object
/// simple name, so reified-type-argument inference can solve a parameter's type
/// argument from the supertype list of a declaration an argument names.
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

/// The class that declares inline member fn `f`, or null for a top-level inline fn
/// or a member the build driver did not walk.
pub fn inlineMemberOwner(f: *const ast.Function) ?[]const u8 {
    const m = inline_member_owner orelse return null;
    return m.get(@intFromPtr(f));
}

fn candidatesFor(name: []const u8) ?[]const *const ast.Function {
    if (inline_fn_asts_resolved) |*r| {
        if (r.get(name)) |cached| return cached;
    }
    const fields = (if (inline_fn_asts) |*c| c.get(name) else null) orelse return null;
    // Resolve this name's candidates once, decoding only their forest decls, and
    // cache the pointer slice so the picking logic stays pointer-based.
    const a = std.heap.page_allocator;
    var buf = a.alloc(*const ast.Function, fields.len) catch return null;
    // A `@Deprecated(level = ERROR|HIDDEN)` or `@LowPriorityInOverloadResolution`
    // inline overload is not a source-level candidate, yet a binary-compat form can
    // be the sole inline candidate for a name and get spliced.
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

/// Like `inlineFnAstFor` but, with several overloads sharing the name, prefer the
/// one whose extension `receiver_type` matches the call's receiver. `recv_chain`
/// carries the known receiver type then its transitive supertypes, most-derived
/// first, so a base-class extension matches a subclass and its own outranks it.
pub fn inlineFnAstForRecv(
    name: []const u8,
    call: ?CallShape,
    recv_chain: ?[]const []const u8,
) ?*const ast.Function {
    return inlineFnAstForRecvExt(name, call, recv_chain, false);
}

/// As `inlineFnAstForRecv`, with `require_receiver`: for a qualified member call the
/// inline target must be an extension with a `this` receiver, so a top-level
/// overload cannot win the shape-based tie.
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

    // Determine whether overloads span different receiver types and whether any
    // candidate is top-level. A member-inline fn's owner class is its receiver type
    // here, so a bare call inside an extension binds that class's own member.
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

    // With no receiver evidence an extension-only overload set cannot be narrowed,
    // and splicing one binds a receiver the scope may not contain. Decline; the
    // normal dispatch paths decide against the real runtime receivers.
    if (recv_chain == null and !has_toplevel) return null;

    // The effective receiver type: the most-derived chain entry any candidate
    // declares. A subclass extension outranks a base-class one, and when nothing
    // matches the head keeps the narrowing's mismatch fallback.
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

/// Narrowing filter: drop top-level overloads for a member call, and when overloads
/// differ by receiver and the call's receiver type is known, keep only the matching
/// ones.
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
/// `receiver_type`, or the owner class for a member-inline fn.
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
    // Several overloads fit the trailing-lambda shape, so prefer the one whose
    // trailing fn-type parameter arity matches the lambda's, mirroring Kotlin
    // dropping a generic overload the call leaves unconstrained.
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

/// A pass-threaded composable declaration carries a trailing `($composer, $changed)`
/// pair the call site does not write, so shape judgments run on the user params.
fn userParams(f: *const ast.Function) []const ast.Param {
    const p = f.params;
    if (p.len >= 2 and std.mem.eql(u8, p[p.len - 1].name.name, "$changed") and
        std.mem.eql(u8, p[p.len - 2].name.name, "$composer"))
    {
        return p[0 .. p.len - 2];
    }
    return p;
}

/// Parameter arity of `f`'s trailing function-typed parameter, the non-receiver
/// parameters of `T.(A, B) -> R`.
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

/// Disambiguate a call whose last argument is not a lambda among same-name
/// overloads: when exactly one has no required function-typed parameter it is the
/// applicable one. Null defers to first-declared.
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

/// Whether `f` can take `want` positional arguments: at least the required,
/// non-defaulted, non-vararg count, and no more than the declared total unless a
/// vararg absorbs the excess.
/// `ambiguousParamTypes` reports several overloads fitting the arity but declaring
/// different value-parameter types, which shape cannot separate; declining to splice
/// hands the call to normal dispatch, which ranks by argument type.
/// `kclassFirstParamPick` is the unique arity-fitting candidate whose first
/// parameter is declared `KClass`.
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
        // A reified type parameter can only be honoured by splicing, so an ambiguous
        // set containing one keeps its behaviour rather than losing the type argument.
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

/// The single overload whose arity fits the call's argument count. The last-resort
/// discriminator before blind first-declared: a plugin-threaded
/// `remember(k1..k4, calc, $composer, $changed)` fits only the vararg overload.
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

/// Resolve the inline overload of `name` for a call shaped
/// `(positional_arg_count, last_arg_is_lambda)`. Conservative: first-declared wins
/// except for a trailing-lambda call where exactly one arity-fitting overload has a
/// function-typed last parameter.
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

/// Among the inline overloads of `name` fitting the call shape, the one declaring a
/// `reified` type parameter. An explicit `<T>` argument binds such a parameter, so a
/// reified overload outranks a non-reified `KClass<T>` namesake, whose type argument
/// would lower as a constructor value instead of binding `T::class`.
pub fn reifiedInlineFnAstFor(name: []const u8, call: ?CallShape) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return null;
    if (cands.len < 2) return null;
    const shape = call orelse return null;
    if (!shape.last_is_lambda) return null;
    const lead = shape.want -| 1;
    // The first reified overload of this shape: siblings differing only in the
    // block's return type splice the same body.
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

/// A reified inline callee past the ordinary depth still splices, an unspliced body
/// reading the process-global `T` of some outer splice. The higher cap only bounds
/// runaway recursion.
pub fn inlineExpandEnterReified() bool {
    if (inline_expand_depth >= INLINE_EXPAND_MAX * 3) return false;
    inline_expand_depth += 1;
    return true;
}

pub fn inlineExpandLeave() void {
    inline_expand_depth -|= 1;
}

/// Release any installed tables, for tests and for a build driver tearing down
/// between builds.
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
    // Installing the next build's simple-name table drops the previous build's
    // FuncId entries.
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
