//! Small shared helpers behind the field paths: the result constructors,
//! the resolution-guard wrapper, getter evaluation, intrinsic lookup and
//! dispatch, and the name/shape predicates every ladder consults.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const host_globals = @import("../host_globals.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;

const host_fields = @import("../host_fields.zig");
const fldTls = host_fields.fldTls;
const missTraceEnvCached = host_fields.missTraceEnvCached;

const read_paths = @import("read_paths.zig");
const accessorFastGet = read_paths.accessorFastGet;

const get_field_inner = @import("get_field_inner.zig");
const getFieldInner = get_field_inner.getFieldInner;

pub inline fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

pub inline fn errRes(e: EvalError) EvalResult {
    return .{ .err = e };
}

/// The active coroutine scope (top of the driver stack), if any. The
/// driver stack lives with the coroutine machinery in `coroutines.zig`;
/// a `driveRoot` activation pushes its scope there.
pub fn activeCoroScope() ?Value {
    return vmhost.coroutines.activeCoroScope();
}

/// The lexically enclosing `this` displaced by a receiver lambda, or
/// `null`. Reports the top of the shared enclosing-`this` stack
/// (`with_outer_this(|s| s.borrow().last().cloned())`), which member
/// dispatch and the access-enclosing machinery push onto — so a bare
/// member-property read inside a member-extension / receiver-lambda body
/// can resolve against the lexically enclosing class instance.
pub fn outerThisLast(self: *VmHost) ?Value {
    return vmhost.host_call_member.enclosingThis(self);
}

/// Run `f` only if `(id, name)` is not already being resolved through
/// the `get_field` heuristic fallbacks; pushes/pops the pair so the
/// recursion is bounded by the distinct instances on the stack. Returns
/// `null` when the pair is already active.
pub fn withFieldResolvePair(
    self: *VmHost,
    allocator: Allocator,
    id: usize,
    name: []const u8,
    receiver: *const Value,
    suppress_cc_redirect: bool,
    member_probe: bool,
) Allocator.Error!?EvalResult {
    for (fldTls().field_resolve_stack.items) |k| {
        if (k.id == id and std.mem.eql(u8, k.name, name)) return null;
    }
    // Back the process-global guard stack on `page_allocator` (it is cleared
    // capacity-retaining at run boundaries; a per-run-arena backing would
    // leave the retained capacity dangling once that arena is torn down).
    fldTls().field_resolve_stack.append(std.heap.page_allocator, .{ .id = id, .name = name }) catch {};
    const r = try getFieldInner(self, allocator, receiver, name, suppress_cc_redirect, member_probe, false);
    var i: usize = fldTls().field_resolve_stack.items.len;
    while (i > 0) {
        i -= 1;
        const k = fldTls().field_resolve_stack.items[i];
        if (k.id == id and std.mem.eql(u8, k.name, name)) {
            _ = fldTls().field_resolve_stack.orderedRemove(i);
            break;
        }
    }
    return r;
}

/// Last `.`-delimited segment of a dotted name (`a.b.c` -> `c`).
pub fn lastSegment(s: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, s, '.')) |i| return s[i + 1 ..];
    return s;
}

/// Number of UTF-16 code units in `s` (Kotlin `String` length unit),
/// falling back to the byte count for malformed UTF-8.
/// UTF-16 code units, agreeing with what `String.length` reports.
///
/// Delegates to the stdlib's counter rather than
/// `std.unicode.calcUtf16LeLen`, whose `catch s.len` fallback silently
/// returns the BYTE length for any string kotlinc considers valid but UTF-8
/// does not — a lone surrogate is stored WTF-8 (`ED A0 80`), so `"\ud800"`
/// reported `length == 1` but `lastIndex == 2` and `indices == 0..2`.
/// kotlinx-io's Utf8Test iterates `string.indices` and indexes the string,
/// so the extra indices threw IndexOutOfBounds on every lone-surrogate case.
pub fn utf16Len(s: []const u8) usize {
    const n = stdlib.text.utf16Len(s);
    return if (n < 0) 0 else @intCast(n);
}

/// Build a frozen `List` value over `items`. `enum_entries` marks the
/// `EnumName.entries` list. Consumes `items` into the backing cell.
pub fn frozenList(allocator: Allocator, items: std.ArrayList(Value), enum_entries: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, items),
        .mutable = false,
        .enum_entries = enum_entries,
        .backing = null,
    });
}

/// Run the IR-lowered function `fid` with the receiver bound as the
/// sole positional argument (custom getter / extension prop invocation).
pub fn evalGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    return evalGetterTagged(self, allocator, fid, receiver, "untagged");
}

pub fn evalGetterTagged(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value, site: []const u8) Allocator.Error!EvalResult {
    const mptr: *const Module = self.module.asPtr();
    const func = mptr.funcById(fid) orelse {
        const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
        return errRes(.{ .Type = msg });
    };
    // Frameless serve for the canonical getter shape on a claimed class.
    if (accessorFastGet(self, mptr, func, &receiver)) |r| return r;
    // Host-served compose snapshot getters (`SnapshotState*.readable`,
    // `Snapshot.current`): classified once per Func, exactly like the
    // static-call routes in exec_call's hostStaticServe.
    {
        if (func.host_route == 0) {
            const route: ir.snapshot_fast.Route = blk: {
                if (func.params.len > 3) break :blk .none;
                const last_ty: []const u8 = if (func.params.len == 0) "" else func.params[func.params.len - 1].ty.name;
                break :blk ir.snapshot_fast.classify(func.fqn, func.params.len, last_ty);
            };
            @constCast(func).host_route = @intFromEnum(route);
        }
        switch (@as(ir.snapshot_fast.Route, @enumFromInt(func.host_route))) {
            .state_readable_getter => {
                if (host_globals.composeSnapshotGlobals(self)) |g| {
                    if (ir.snapshot_fast.serveStateReadableGetter(&receiver, &g.ts, &g.gs)) |v| {
                        return .{ .ok = v };
                    }
                }
            },
            .current_getter => {
                if (host_globals.composeSnapshotGlobals(self)) |g| {
                    if (ir.snapshot_fast.serveCurrentSnapshot(&g.ts, &g.gs)) |v| {
                        return .{ .ok = v };
                    }
                }
            },
            else => {},
        }
    }
    // Frameless serve for the wider leaf-expression shape (a getter that
    // combines a couple of stored reads with primitive arithmetic).
    if (try ir.eval.leafExprServe(VmHost, allocator, mptr, func, &.{receiver}, self)) |r| return r;
    // Compiled kl_ leaf gate: the getter path is a member-dispatch
    // commit point like any other — a branchy accessor body the
    // frameless evaluator declines (inWholeSeconds' unit chase) still
    // serves natively when its leaf is registered.
    if (try ir.eval.tryLeafValues(VmHost, allocator, mptr, func, &.{receiver}, self, null)) |lo| switch (lo) {
        .val => |v| return .{ .ok = v },
        .raise => |e| return errRes(e),
    };
    // Pin the receiver as a GC root across the getter's re-entrant evaluation.
    // A getter body allocates and hits safe points; the only handle to the
    // receiver here is this native local (the frame-chain walk cannot see it
    // until the new frame's params are installed), so a collection mid-getter
    // would otherwise sweep it — and everything transitively reachable through
    // it, which the getter is about to read.
    if (missTraceEnvCached()) |w| {
        if (std.mem.find(u8, func.name, w) != null) {
            const rc: []const u8 = if (receiver == .Instance) className(receiver.Instance) else receiver.typeFqn();
            std.debug.print("[getter] {s}#{d} recv={s} site={s}\n", .{ func.name, fid.int(), rc, site });
            ir.eval.dumpFrameChainForDiagAlways();
        }
    }
    const ka = self.ka.mark();
    defer self.ka.restore(ka);
    self.ka.push(receiver);
    var args: std.ArrayList(Value) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, receiver);
    var args_owned: std.ArrayList(Value) = .empty;
    try args_owned.appendSlice(allocator, args.items);
    vmhost.emitPath(allocator, "getter", func.fqn, fid, &receiver, &.{});
    return ir.eval.evalWith(VmHost, allocator, mptr, func, args_owned, self);
}

/// `instance_prop_getters.get((class, name))` -> `?FuncId`.
pub fn lookupPairFunc(map: anytype, a: []const u8, b: []const u8) ?FuncId {
    return map.get(.{ .a = a, .b = b });
}

/// Accessor lookup for a HIERARCHY HOP: the simple key first, then the
/// hop class's registered FQN key. A PRIVATE class registers its
/// accessors under the FQN only (the shared simple slot must not let a
/// private namesake capture unrelated dispatch), so an inherited getter
/// from a private base (SnapshotMapSet's `size` behind
/// SnapshotMapKeySet) resolves through the FQN alone.
pub fn lookupPairFuncHop(self: *VmHost, map: anytype, cn: []const u8, b: []const u8) ?FuncId {
    if (map.get(.{ .a = cn, .b = b })) |f| return f;
    const fqn: ?[]const u8 = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        const d = cg.get().get(cn) orelse break :blk null;
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().fqn;
    };
    if (fqn) |f| {
        if (!std.mem.eql(u8, f, cn)) return map.get(.{ .a = f, .b = b });
    }
    return null;
}

/// Look up an intrinsic by FQN: the pack-supplied bindings overlay
/// first, then the stdlib default implementation.
pub fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only; consult it unguarded
    // (gated on the published link flag) instead of taking two shared
    // reader locks per lookup.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

/// Invoke a resolved stdlib intrinsic with `args`, mapping a thrown /
/// non-local-return / suspend `RuntimeError` to the matching
/// `EvalError`.
pub fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_fields", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
    var ih = VmIntrinsicHost{
        .module = self.module,
        .closures = self.closures,
        .globals = self.globals,
        .classes = self.classes,
        .prog = self.prog,
        .anon_methods = self.anon_methods,
        .class_default_outer = self.class_default_outer,
        .instance_id_counter = self.instance_id_counter,
        .out_sink = self.out_sink,
        .threads = self.threads,
        .object_states = self.object_states,
        .singletons_by_id = self.singletons_by_id,
        .allocator = allocator,
    };
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = ih.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| ok(v),
        .err => |e| switch (e) {
            .Thrown => |v| errRes(.{ .Throw = v }),
            .Return => |v| errRes(.{ .NonLocalReturn = v }),
            // Keep each message-carrying kind intact: collapsing to the
            // tag name buries the real failure text.
            .Unbound => |s| errRes(.{ .Unbound = s }),
            .Type => |s| errRes(.{ .Type = s }),
            .Arity => |s| errRes(.{ .Arity = s }),
            .Unimplemented => |s| errRes(.{ .Unimplemented = s }),
            .CalleeFailed => |s| errRes(.{ .CalleeFailed = s }),
            else => blk: {
                const s = @tagName(e);
                break :blk errRes(.{ .Type = try allocator.dupe(u8, s) });
            },
        },
    };
}

pub fn typeHeadOf(name: []const u8) []const u8 {
    var h = std.mem.trimEnd(u8, name, "?");
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    if (std.mem.findScalarLast(u8, h, '.')) |d| h = h[d + 1 ..];
    return h;
}

/// A boxed capture (an anon-object method's captured outer `var` stored
/// in its capture env as a shared Cell) reads THROUGH the cell — the cell
/// is a carrier, never a user value.
pub fn unwrapCellRead(r: EvalResult) EvalResult {
    if (r == .ok and r.ok == .Cell) {
        const cg = r.ok.Cell.borrow();
        defer cg.deinit();
        return .{ .ok = cg.get().* };
    }
    return r;
}

/// A discarded dispatch-miss message from a probe. Host miss messages are
/// `allocPrint`-built with a `Vm::` prefix; static literals never carry one.
pub fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (!runtime.freeScratch()) return;
    if (e != .Unimplemented) return;
    if (std.mem.startsWith(u8, e.Unimplemented, "Vm::")) allocator.free(e.Unimplemented);
}

/// The receiver's class fqn for diagnostics — an instance names its
/// declaring class instead of the opaque `<instance>` tag.
pub fn receiverLabel(receiver: *const Value) []const u8 {
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        return cg.get().fqn;
    }
    return receiver.typeFqn();
}

/// `KClass.simpleName` of a runtime class name: a nested class is stored
/// lifted (`Outer$Inner`) and a local class under its function mangle
/// (`Name$lc<fn>`); the simple name is the declared identifier alone.
pub fn classSimpleName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.find(u8, n, "$lc")) |i| n = n[0..i];
    if (std.mem.findLastAny(u8, n, "$.")) |i| {
        if (i + 1 < n.len) n = n[i + 1 ..];
    }
    return n;
}

/// The enclosing-class lift name of a nested class / companion lift name:
/// `Root$Companion$Plugin` -> `Root`, `Outer$Inner` -> `Outer`. Null when the
/// name has no nesting marker.
pub fn enclosingNameOf(name: []const u8) ?[]const u8 {
    if (std.mem.find(u8, name, "$Companion$")) |i| return name[0..i];
    if (std.mem.findScalarLast(u8, name, '$')) |i| return name[0..i];
    return null;
}

// -------------------------------------------------------------------------
// Small shared helpers.
// -------------------------------------------------------------------------

/// Anon-method registry key `"<class>\u{1f}<method>"`. The registry is
/// keyed on a single string, built as a unit-separated concatenation of
/// `(class, name)` cached per-call.
pub fn anonKey(class_name: []const u8, method: []const u8) []const u8 {
    return std.fmt.bufPrint(&fldTls().anon_key_buf, "{s}\u{1f}{s}", .{ class_name, method }) catch class_name;
}

/// The runtime class simple name of an instance.
pub fn className(inst: ObjRef(InstanceData)) []const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().name;
}

/// The instance's class FQN (falling back to its simple name when no FQN
/// is recorded). Used to key a native property-getter binding.
pub fn classFqnOf(inst: ObjRef(InstanceData)) []const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const fqn = cg.get().fqn;
    return if (fqn.len != 0) fqn else cg.get().name;
}

/// Whether the instance's class is a host-synthesised class — anonymous
/// (built through `newSynthInstance`) with a package-qualified FQN that
/// differs from its simple name. The native `KlioChannel` qualifies; a
/// source `object : I {}` literal does not (its FQN is its bare `$anon$N`
/// name), so only host synth classes reach the native property-getter
/// probe.
pub fn instanceIsHostSynth(inst: ObjRef(InstanceData)) bool {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (!cg.get().is_anonymous) return false;
    const fqn = cg.get().fqn;
    return fqn.len != 0 and
        std.mem.findScalar(u8, fqn, '.') != null and
        !std.mem.eql(u8, fqn, cg.get().name);
}

/// The first declared supertype simple name of an instance's class.
pub fn firstSupertypeOf(inst: ObjRef(InstanceData)) ?[]const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const sts = cg.get().supertype_names;
    return if (sts.len > 0) sts[0] else null;
}

/// The first declared supertype simple name of class `cn`, via the
/// runtime class table.
/// The simple name of a companion singleton from its mangled registry key
/// (`Owner$Companion$Key` → `Key`).
pub fn companionSimpleName(mangled: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, mangled, '$')) |i| mangled[i + 1 ..] else mangled;
}

pub fn firstSupertype(self: *VmHost, cn: []const u8) ?[]const u8 {
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(cn)) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            const sts = dg.get().supertype_names;
            return if (sts.len > 0) sts[0] else null;
        }
    }
    // A dotted nested name (`Modifier.Node`) may register under its lifted
    // mangled key.
    if (host_call_member.mangledClassKeyOf(self, cn)) |m| {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(m)) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            const sts = dg.get().supertype_names;
            return if (sts.len > 0) sts[0] else null;
        }
    }
    return null;
}

pub fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

pub fn matchAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

pub fn listLen(items: ValueList) usize {
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

/// `len` (as `i64`) of an array / list / string receiver, or `null`.
pub fn collectionLen(receiver: *const Value) ?i64 {
    return switch (receiver.*) {
        .Array => |a| @intCast(a.len()),
        .List => |l| @intCast(listLen(l.items)),
        // `Collection<*>.indices` / `lastIndex` apply to sets too; without
        // this arm `setOf(1).indices` was a runtime dispatch error. Views
        // (`backing != null`) keep falling through — their length belongs
        // to the view machinery.
        .Set => |st| if (st.backing == null) blk: {
            const g = st.items.borrow();
            defer g.deinit();
            break :blk @intCast(g.get().items.len);
        } else null,
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk @intCast(utf16Len(g.get().bytes));
        },
        else => null,
    };
}
