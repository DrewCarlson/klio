//! `VmHost` field access: reading and writing a named property on a
//! receiver — stored fields, custom getters/setters, extension
//! properties, and the inner-class outer-chain fallbacks.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.
//! Implements the ordered field-resolution dispatch chain (get/set/member-ref).

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const root = @import("../interp_ir.zig");
const host_impl = @import("host_impl.zig");
const host_globals = @import("host_globals.zig");
const host_call_member = @import("host_call_member.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const SupertypeDelegate = runtime.SupertypeDelegate;
const MethodDef = runtime.MethodDef;
const RangeKind = runtime.RangeKind;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const UnitResult = ir.eval.UnitResult;

inline fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

inline fn errRes(e: EvalError) EvalResult {
    return .{ .err = e };
}

// -------------------------------------------------------------------------
// Thread-local resolution guards.
//
// Bound the heuristic field-resolution recursion and expose the
// suspend-implicit coroutine scope / displaced enclosing `this`. They
// are empty/false until the coroutine driver and the access-enclosing
// machinery push onto them, matching the default state at process start.
// -------------------------------------------------------------------------

/// `(instance id, field name)` pairs currently being resolved through
/// the `get_field` heuristic fallbacks. Bounds the recursion to the
/// distinct instances on the stack.
threadlocal var field_resolve_stack: std.ArrayList(ResolvePair) = .empty;

/// Re-entrancy flag for the inner-class outer-chain field fallback.
threadlocal var field_outer_active: bool = false;

/// Assert (Debug) the field-resolution stack and its re-entrancy flags are
/// clear at a run boundary and reset them so leaked-across-runs state is a
/// loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(field_resolve_stack.items.len == 0);
    std.debug.assert(!field_outer_active);
    field_resolve_stack.clearRetainingCapacity();
    field_outer_active = false;
}

const ResolvePair = struct { id: usize, name: []const u8 };

/// The active coroutine scope (top of the driver stack), if any. The
/// driver stack lives with the coroutine machinery in `coroutines.zig`;
/// a `driveRoot` activation pushes its scope there.
fn activeCoroScope() ?Value {
    return vmhost.coroutines.activeCoroScope();
}

/// The lexically enclosing `this` displaced by a receiver lambda, or
/// `null`. Reports the top of the shared enclosing-`this` stack
/// (`with_outer_this(|s| s.borrow().last().cloned())`), which member
/// dispatch and the access-enclosing machinery push onto — so a bare
/// member-property read inside a member-extension / receiver-lambda body
/// can resolve against the lexically enclosing class instance.
fn outerThisLast(self: *VmHost) ?Value {
    return vmhost.host_call_member.enclosingThis(self);
}

/// Run `f` only if `(id, name)` is not already being resolved through
/// the `get_field` heuristic fallbacks; pushes/pops the pair so the
/// recursion is bounded by the distinct instances on the stack. Returns
/// `null` when the pair is already active.
fn withFieldResolvePair(
    self: *VmHost,
    allocator: Allocator,
    id: usize,
    name: []const u8,
    receiver: *const Value,
    suppress_cc_redirect: bool,
    member_probe: bool,
) Allocator.Error!?EvalResult {
    for (field_resolve_stack.items) |k| {
        if (k.id == id and std.mem.eql(u8, k.name, name)) return null;
    }
    // Back the process-global guard stack on `page_allocator` (it is cleared
    // capacity-retaining at run boundaries; a per-run-arena backing would
    // leave the retained capacity dangling once that arena is torn down).
    field_resolve_stack.append(std.heap.page_allocator, .{ .id = id, .name = name }) catch {};
    const r = try getFieldInner(self, allocator, receiver, name, suppress_cc_redirect, member_probe, false);
    var i: usize = field_resolve_stack.items.len;
    while (i > 0) {
        i -= 1;
        const k = field_resolve_stack.items[i];
        if (k.id == id and std.mem.eql(u8, k.name, name)) {
            _ = field_resolve_stack.orderedRemove(i);
            break;
        }
    }
    return r;
}

/// Last `.`-delimited segment of a dotted name (`a.b.c` -> `c`).
fn lastSegment(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| return s[i + 1 ..];
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
fn utf16Len(s: []const u8) usize {
    const n = stdlib.text.utf16Len(s);
    return if (n < 0) 0 else @intCast(n);
}

/// Build a frozen `List` value over `items`. `enum_entries` marks the
/// `EnumName.entries` list. Consumes `items` into the backing cell.
fn frozenList(allocator: Allocator, items: std.ArrayList(Value), enum_entries: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, items),
        .mutable = false,
        .enum_entries = enum_entries,
        .backing = null,
    });
}

/// Run the IR-lowered function `fid` with the receiver bound as the
/// sole positional argument (custom getter / extension prop invocation).
fn evalGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    return evalGetterTagged(self, allocator, fid, receiver, "untagged");
}

fn evalGetterTagged(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value, site: []const u8) Allocator.Error!EvalResult {
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
        if (std.mem.indexOf(u8, func.name, w) != null) {
            const rc: []const u8 = if (receiver == .Instance) className(receiver.Instance) else receiver.typeFqn();
            std.debug.print("[getter] {s}#{d} recv={s} site={s}\n", .{ func.name, fid.int(), rc, site });
            ir.eval.dumpFrameChainForDiagAlways();
        }
    }
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(receiver);
    var args: std.ArrayList(Value) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, receiver);
    var args_owned: std.ArrayList(Value) = .empty;
    try args_owned.appendSlice(allocator, args.items);
    vmhost.emitPath(allocator, "getter", func.fqn, fid, &receiver, &.{});
    return ir.eval.evalWith(VmHost, allocator, mptr, func, args_owned, self);
}

/// `instance_prop_getters.get((class, name))` -> `?FuncId`.
fn lookupPairFunc(map: anytype, a: []const u8, b: []const u8) ?FuncId {
    return map.get(.{ .a = a, .b = b });
}

/// Accessor lookup for a HIERARCHY HOP: the simple key first, then the
/// hop class's registered FQN key. A PRIVATE class registers its
/// accessors under the FQN only (the shared simple slot must not let a
/// private namesake capture unrelated dispatch), so an inherited getter
/// from a private base (SnapshotMapSet's `size` behind
/// SnapshotMapKeySet) resolves through the FQN alone.
fn lookupPairFuncHop(self: *VmHost, map: anytype, cn: []const u8, b: []const u8) ?FuncId {
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
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
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
fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_fields", fqn, null, null, args);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(args);
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

// -------------------------------------------------------------------------
// get_field
// -------------------------------------------------------------------------

pub fn getField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return lexicalReceiverFallback(self, allocator, receiver, name, unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, false, false)));
}

/// Leaf statics route backing: resolve `Owner.member` for a genre-9
/// class handle inside a leaf body. ENUM ENTRIES ONLY — an entry is an
/// eager singleton stored on the ClassDef itself (language-mandated
/// identity), so its cell is rooted for the class's lifetime and
/// borrow-safe for the leaf's duration. Anything else (companion vals,
/// computed statics) returns null and the leaf bails to the exact
/// re-run.
pub fn leafStaticMember(self: *VmHost, owner: []const u8, member: []const u8) ?Value {
    const def = blk: {
        const cg = self.classes.borrow();
        defer cg.deinit();
        break :blk cg.get().get(owner) orelse return null;
    };
    const dg = def.borrow();
    defer dg.deinit();
    if (!dg.get().is_enum) return null;
    for (dg.get().enum_entries) |*e| {
        if (std.mem.eql(u8, e.name, member)) return e.value;
    }
    return null;
}

/// A boxed capture (an anon-object method's captured outer `var` stored
/// in its capture env as a shared Cell) reads THROUGH the cell — the cell
/// is a carrier, never a user value.
fn unwrapCellRead(r: EvalResult) EvalResult {
    if (r == .ok and r.ok == .Cell) {
        const cg = r.ok.Cell.borrow();
        defer cg.deinit();
        return .{ .ok = cg.get().* };
    }
    return r;
}

/// Per-candidate probe for the bare-name resolver's innermost-first walk:
/// resolves only what the receiver itself owns — instance fields,
/// declared properties and their getters, applicable extension
/// properties, builtin member properties. Every global / outer-receiver /
/// companion adoption tail is disabled, so a candidate cannot "resolve" a
/// name it does not own and shadow a real member of a receiver further
/// out; the walk's own terminal arm decides the global fallback, and
/// companions ride the walk as their own candidates.
/// Does class `cn` declare property `name` as a STORED member — a body
/// `val`/`var` or a constructor-parameter property — as opposed to a custom
/// accessor? Such a declaration overrides an inherited accessor-based property,
/// so the setter walk must store the field directly rather than fall through to
/// a supertype's custom setter (`override var x = 0` shadowing `open var x
/// set(...)`).
fn classDeclaresStoredProp(self: *VmHost, cn: []const u8, name: []const u8) bool {
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(cn) orelse return false;
    const dg = def.borrow();
    defer dg.deinit();
    for (dg.get().body_properties) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    for (dg.get().primary_params) |p| {
        if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// Whether stored-field `fname` is the property a scope-qualified
/// `$sgetter$<owner>\u{1f}<prop>` read named: the full name ends with the
/// separator + the field name. Used by the (class, name) memo and the
/// GetField site memo so entries keyed by the FULL scoped name can serve a
/// stored slot whose field is stored under the bare property name.
pub fn sgetterNameMatches(full: []const u8, fname: []const u8) bool {
    if (!std.mem.startsWith(u8, full, "$sgetter$")) return false;
    if (full.len <= fname.len) return false;
    if (!std.mem.endsWith(u8, full, fname)) return false;
    return full[full.len - fname.len - 1] == '\u{1f}';
}

var miss_trace_state: u8 = 0;
var miss_trace_want: []const u8 = "";
/// Cached KLIO_MISS_TRACE value; consulted on per-call paths (the getter
/// runner, the field ladder), where a raw getenv is a spinlock + probe.
fn missTraceEnvCached() ?[]const u8 {
    if (miss_trace_state == 0) {
        if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
            miss_trace_want = w;
            miss_trace_state = 2;
        } else {
            miss_trace_state = 1;
        }
    }
    return if (miss_trace_state == 2) miss_trace_want else null;
}

/// A discarded dispatch-miss message from a probe. Host miss messages are
/// `allocPrint`-built with a `Vm::` prefix; static literals never carry one.
fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (!runtime.freeScratch()) return;
    if (e != .Unimplemented) return;
    if (std.mem.startsWith(u8, e.Unimplemented, "Vm::")) allocator.free(e.Unimplemented);
}

/// Depth bound for the lexical-receiver fallback below: an object literal
/// written inside another one chains, but a capture cycle must not.
threadlocal var anon_recv_depth: usize = 0;

pub fn getMemberField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, true, false));
}

/// `getMemberField` with IMPORTED extension properties suppressed: the
/// implicit-receiver walk's first pass, so an outer receiver's MEMBER wins
/// over an inner receiver's imported extension (Kotlin resolves by lexical
/// scope — a class member outranks an import). The walk retries with the
/// plain form when no member answers anywhere.
pub fn getMemberFieldNoExt(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, true, true));
}

pub const FieldSiteClaim = struct { cls: u64, route: u64 };

/// Frameless accessor-getter serve: when `f`'s body is the canonical
/// `LoadParam #0; GetField; return` shape and the receiver's class claimed
/// the func's single-fill route as a plain stored slot, read the slot
/// directly — no frame, no activation, no chain seeding. The slot serve is
/// exactly what the (class, name) memo would return inside the frame's
/// GetField, re-verified by name; lateinit/delegate shapes decline to the
/// frame path, as does a getter-routed or unclaimed (class, name).
pub fn accessorFastGet(self: *VmHost, mod: *const Module, f: *const ir.Func, receiver: *const Value) ?EvalResult {
    if (receiver.* != .Instance) return null;
    const fc = f.accessorFieldConstIn(mod) orelse return null;
    const claimed = @atomicLoad(u64, @constCast(&f.acc_cls), .acquire);
    if (claimed == 1) return null;
    if (fc.int() >= mod.consts.items.len) return null;
    const fname: []const u8 = switch (mod.consts.items[fc.int()]) {
        .String => |s| s,
        else => return null,
    };
    var cls: u64 = 0;
    {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        cls = @intCast(g.get().class.identity());
    }
    if (claimed == 0) {
        // First resolution claims the func for this class when the memo
        // already routes the read to a stored slot; the claiming call
        // itself still runs the frame path (the memo may not be filled
        // until that run completes).
        if (fieldSiteRoute(self, receiver, fname)) |r| {
            if (r.route & 3 == 1) {
                if (@cmpxchgStrong(u64, @constCast(&f.acc_cls), 0, r.cls, .acq_rel, .monotonic) == null) {
                    @atomicStore(u64, @constCast(&f.acc_route), r.route, .release);
                }
            } else {
                _ = @cmpxchgStrong(u64, @constCast(&f.acc_cls), 0, 1, .acq_rel, .monotonic);
            }
        }
        return null;
    }
    if (claimed != cls) return null;
    const route = @atomicLoad(u64, @constCast(&f.acc_route), .acquire);
    if (route == 0 or route & 3 != 1) return null;
    const idx: usize = @intCast(route >> 2);
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const fields = g.get().fields.items;
    if (idx >= fields.len) return null;
    const fld = &fields[idx];
    if (!std.mem.eql(u8, fld.name, fname) and !sgetterNameMatches(fname, fld.name)) return null;
    const v = fld.value;
    if (v == .Null or v == .Delegate) return null;
    v.retain();
    return ok(v);
}

/// The packed field-read route a `GetField` instruction may claim for the
/// receiver's class: {stored slot index | getter FuncId} + a 2-bit verdict,
/// sourced from the (class, name) memo `getFieldInner` maintains — so a
/// claim exists only for reads that resolved as a plain stored slot or a
/// class getter, with every earlier ladder arm already declined. Null when
/// the memo has no entry for the pair.
/// Whether a stored slot's NULL value is a plain null rather than an unset
/// `lateinit` (whose read must throw) — decided from the class, so a site memo
/// can serve nulls instead of declining every one of them to the ladder.
pub fn storedNullServable(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    _ = self;
    if (receiver.* != .Instance) return false;
    return !storedNullIsLateinit(receiver.Instance, name);
}

/// The WRITE-side sibling of `fieldSiteRoute`: a plain stored-slot verdict for
/// a `SetField`, from the write memo the interpreter's own store fills. A
/// custom setter, an unfilled memo or a name that resolves to no field
/// declines, so the caller keeps the full store path.
pub fn fieldWriteSiteRoute(self: *VmHost, receiver: *const Value, name: []const u8) ?FieldSiteClaim {
    if (receiver.* != .Instance) return null;
    const inst = receiver.Instance;
    const cls_id: usize = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.identity();
    };
    const name_p = host_call_member.memberNameIdentity(self, name) orelse return null;
    const hit = fieldWriteCacheGet(self, cls_id, name_p) orelse return null;
    if (hit.setter != root.ProgramImage.FieldWriteHit.NONE) return null;
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, hit.store_name)) continue;
        if (i > (std.math.maxInt(u64) >> 2)) return null;
        return .{ .cls = @intFromPtr(g.get().class.cell), .route = (@as(u64, @intCast(i)) << 2) | 1 };
    }
    return null;
}

pub fn fieldSiteRoute(self: *VmHost, receiver: *const Value, name: []const u8) ?FieldSiteClaim {
    if (receiver.* != .Instance) return null;
    if (std.mem.eql(u8, name, "coroutineContext")) return null;
    // A property getter reading its own backing store carries the SCOPED
    // name (`$sgetter$<owner>\u{1f}<prop>`), which no (class, name) memo
    // holds — so every such read declined a route and sent the whole body
    // to a frame. When the receiver really is the scoped owner the read is
    // the plain property on the receiver's own class, which is what Kotlin's
    // virtual dispatch resolves it to.
    if (std.mem.startsWith(u8, name, "$sgetter$")) {
        const rest = name["$sgetter$".len..];
        if (std.mem.indexOfScalar(u8, rest, '\u{1f}')) |sep| {
            const owner = rest[0..sep];
            const prop = rest[sep + 1 ..];
            if (prop.len == 0) return null;
            const rcn = className(receiver.Instance);
            const owns = std.mem.eql(u8, rcn, owner) or blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk mg.get().classIsOrExtends(rcn, owner);
            };
            if (!owns) return null;
            return fieldSiteRoute(self, receiver, prop);
        }
        return null;
    }
    const inst = receiver.Instance;
    const cls: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(inst));
    const hit = blk: {
        const name_p = host_call_member.memberNameIdentity(self, name) orelse break :blk null;
        break :blk fieldReadCacheGet(self, @intCast(cls), name_p);
    } orelse return null;
    const NONE = root.ProgramImage.FieldReadHit.NONE;
    if (hit.getter != NONE) return .{ .cls = cls, .route = (@as(u64, hit.getter) << 2) | 2 };
    if (hit.stored_idx != NONE) {
        // An outer-hop slot read packs [63:32]=outer class identity (low
        // 32 bits, exact for identity-counter values), [31:8]=slot index,
        // [7:2]=hop count, tag 3.
        if (hit.outer_hops != 0) {
            if (hit.stored_idx > 0xFFFFFF or hit.outer_hops > 63) return null;
            return .{ .cls = cls, .route = (@as(u64, @truncate(hit.outer_cls)) << 32) |
                (@as(u64, hit.stored_idx) << 8) | (@as(u64, hit.outer_hops) << 2) | 3 };
        }
        return .{ .cls = cls, .route = (@as(u64, hit.stored_idx) << 2) | 1 };
    }
    return null;
}

/// Run a class property getter claimed by a `GetField` site memo.
pub fn runFieldGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    return evalGetterTagged(self, allocator, fid, receiver, "site-memo");
}

/// Whether the getter behind a claimed field-read route is itself a leaf
/// expression. A leaf body only reads fields and does primitive arithmetic,
/// so running one is repeatable — which is what lets the frameless leaf
/// evaluator chain through a property whose backing is another property
/// (`SlotWriter.size` reads `capacity`, which divides `groups.size`).
pub fn fieldGetterIsLeaf(self: *VmHost, fid: FuncId) bool {
    const mptr: *const Module = self.module.asPtr();
    const f = mptr.funcById(fid) orelse return false;
    return f.leafExprBody() and funcRunsItsBody(self, fid);
}

/// Whether calling `fid` really runs its lowered body. A symbol the link
/// step settled onto a native binding, or one that redirects to a sibling
/// declaration, resolves elsewhere — the frameless leaf evaluator must not
/// interpret the body in either case.
/// The module as a stable plain pointer (the leaf gate's field-route
/// thunk chases trivial accessor getters through it).
pub fn hostModulePtr(self: *VmHost) *const Module {
    return self.module.asPtr();
}

pub fn funcRunsItsBody(self: *VmHost, fid: FuncId) bool {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().resolvedNativeForm(fid) == null and
        pg.get().resolvedRedirects(fid).len == 0;
}

/// Kotlin's implicit receivers stack. A bare name inside an object literal's
/// member that the object does not own resolves against the receivers in scope
/// where the literal was WRITTEN — `testScheduler`, read inside an
/// `object : CompositionTestScope { … }` written in a `runTest { }` lambda, is
/// that lambda's `TestScope`. The literal closed over those receivers as its
/// `this` / `this@…` captures, so probe them on a miss. Only a dispatch MISS
/// reaches here, so a name that already resolves keeps its path.
fn lexicalReceiverFallback(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    r: EvalResult,
) Allocator.Error!EvalResult {
    if (r == .ok) return r;
    const e = r.err;
    if (e != .Unimplemented) return r;
    if (receiver.* != .Instance) return r;
    if (anon_recv_depth >= 8) return r;
    const caps: []const InstanceData.Capture = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_captures;
    };
    if (caps.len == 0) return r;
    anon_recv_depth += 1;
    defer anon_recv_depth -= 1;
    for (caps) |c| {
        // Only the LABELLED receivers: the plain `this` capture is the object's
        // `outer` link, already on the normal lookup path.
        if (!std.mem.startsWith(u8, c.name, "this@")) continue;
        if (c.value == .Null or c.value == .Unit) continue;
        switch (try getField(self, allocator, &c.value, name)) {
            .ok => |v| {
                freeMissErr(allocator, e);
                return .{ .ok = v };
            },
            .err => |e2| {
                if (e2 == .Unimplemented) {
                    freeMissErr(allocator, e2);
                } else {
                    freeMissErr(allocator, e);
                    return .{ .err = e2 };
                }
            },
        }
    }
    return r;
}

/// For the loop JIT: the index of `name` in the receiver's instance field list,
/// but only when `name` is a fully plain stored property — an Instance receiver, a
/// stored field of that name, and no custom getter *or setter* for it anywhere in
/// the class hierarchy. Returns null otherwise (a computed getter/setter,
/// delegated, or extension property is not a direct field access and must stay
/// interpreted), so the index is safe for both direct reads and direct writes. The
/// field order is fixed per class, so the index is stable for any instance of the
/// class the call site was compiled against (re-checked by the entry class guard).
pub fn plainStoredFieldIndex(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) ?u32 {
    if (receiver.* != .Instance) return null;
    // Reject if any class in the hierarchy declares a custom getter/setter or
    // DELEGATES the property (`by lazy` stores the delegate object under the
    // property's name — a raw read would leak the wrapper).
    if (runtimeClassDelegatesProp(receiver.Instance, name)) return null;
    {
        var cur: ?[]const u8 = className(receiver.Instance);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            seen.append(allocator, cn) catch return null;
            {
                const pg = self.prog.borrow();
                const hit = lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, name) != null or
                    lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, name) != null;
                pg.deinit();
                if (hit) return null;
            }
            if (delegatedPropRegistered(self, cn, name)) return null;
            cur = firstSupertype(self, cn);
        }
    }
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    for (b.fields.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

fn isScalarTypeName(n: []const u8) bool {
    const names = [_][]const u8{ "Int", "Long", "Double", "Float", "Boolean", "Byte", "Short", "Char" };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return false;
}

/// Like `plainStoredFieldIndex`, but only when the field's declared type is a
/// non-nullable scalar. The loop JIT requires this before inlining a method that
/// also writes a field: a non-nullable scalar read never deopts, so a re-run of
/// the inlined call (on some other deopt) can never double an already-applied
/// write. Returns null for a nullable or non-scalar field (keep it interpreted).
pub fn plainStoredScalarFieldNN(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) ?u32 {
    const idx = plainStoredFieldIndex(self, allocator, receiver, name) orelse return null;
    var cur: ?[]const u8 = className(receiver.Instance);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    while (cur) |cn| {
        cur = null;
        if (containsStr(seen.items, cn)) break;
        seen.append(allocator, cn) catch return null;
        const cg = self.classes.borrow();
        const def = cg.get().get(cn);
        if (def) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().primary_params) |p| {
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    const nn = if (p.declared_shape) |sh| (!sh.nullable and isScalarTypeName(sh.name)) else false;
                    cg.deinit();
                    return if (nn) idx else null;
                }
            }
            for (dg.get().body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    // A non-nullable primitive property carries a primitive zero.
                    const nn = p.primitive_zero != null;
                    cg.deinit();
                    return if (nn) idx else null;
                }
            }
        }
        cg.deinit();
        cur = firstSupertype(self, cn);
    }
    return null;
}

/// `suppress_cc_redirect` skips the suspend-implicit `coroutineContext`
/// redirect for this one resolution (an explicit `recv.coroutineContext`
/// read, lowered to the `$coroutineContext$explicit` sentinel). A
/// parameter scoped to the resolution, threaded through the fallback
/// ladder's own recursion, so it cannot leak into a dispatched getter
/// body or across a re-entrant dispatch.
/// `member_probe` restricts resolution to what the receiver itself owns
/// (see `getMemberField`); the adoption tails — globals, enclosing
/// receivers, outer chain, companions — are skipped so the bare-name
/// walk's candidate order decides precedence.
/// Free a discarded field-resolution-miss message. `getFieldInner` allocates a
/// `Vm::get_field …` string on a total miss; the delegate / companion / outer
/// fallbacks discard it while probing the next receiver. Recognizable by its
/// prefix, so a static `.Unimplemented` literal is never freed. No-op unless a
/// freeing backend is active.
pub fn freeFieldMiss(allocator: Allocator, e: EvalError) void {
    if (!runtime.freeScratch()) return;
    if (e == .Unimplemented and std.mem.startsWith(u8, e.Unimplemented, "Vm::get_field")) {
        allocator.free(e.Unimplemented);
    }
}

/// The properties a builtin receiver declares as MEMBERS (as opposed to the
/// stdlib's extension properties, such as `indices` / `lastIndex`, which a user
/// extension may legitimately shadow).
fn builtinMemberProperty(receiver: *const Value, name: []const u8) bool {
    return switch (receiver.*) {
        .Array => std.mem.eql(u8, name, "size"),
        .List, .Set => std.mem.eql(u8, name, "size"),
        .Map => std.mem.eql(u8, name, "size") or
            std.mem.eql(u8, name, "keys") or
            std.mem.eql(u8, name, "values") or
            std.mem.eql(u8, name, "entries"),
        .String => std.mem.eql(u8, name, "length"),
        else => false,
    };
}

/// Fill the class's `<class-companion-or-self>` memo with the resolved
/// singleton. A losing concurrent filler re-retains the same immortal
/// singleton — benign. The memo's copy is retained once for the class's
/// lifetime.
fn fillCompanionReadMemo(cls: ObjRef(ClassDef), v: Value) void {
    const g = cls.borrow();
    defer g.deinit();
    const d = @constCast(g.get());
    if (d.companion_read_state.load(.monotonic) != 0) return;
    if (runtime.reclaimEnabled()) v.retain();
    d.companion_read_value = v;
    d.companion_read_state.store(2, .release);
}

fn getFieldInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, suppress_cc_redirect: bool, member_probe: bool, suppress_ext: bool) Allocator.Error!EvalResult {
    // Static-type-directed extension-property read. The lowerer emits this
    // marker when a read's STATIC receiver type resolves `name` to an in-scope
    // member-extension property rather than a member: Kotlin runs that getter,
    // so the runtime object's same-named stored field must not shadow it.
    // Resolve the extension directly; fall back to the ordinary read only when
    // no extension applies (a defensive no-op the lowerer should not reach).
    if (std.mem.startsWith(u8, name, "$extread$")) {
        const prop = name["$extread$".len..];
        if (try extensionPropRead(self, allocator, receiver, prop)) |v| return v;
        return getFieldInner(self, allocator, receiver, prop, suppress_cc_redirect, member_probe, suppress_ext);
    }
    // A property of a `by`-delegated interface the class does not override is
    // the delegate's, even when the interface declares a default getter. The
    // ladder below would find that default first and answer with it.
    if (receiver.* == .Instance) {
        if (host_call_member.interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            switch (try getFieldInner(self, allocator, &d, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                .ok => |v| if (v != .Unit) return ok(v),
                .err => |e| if (e == .Unimplemented) freeFieldMiss(allocator, e) else return .{ .err = e },
            }
        }
    }
    // A bare class/interface name used as a value resolves to its companion
    // object, else the receiver unchanged. Hoisted ahead of the ladder: the
    // sentinel is klio-synthetic, so no other arm can ever claim it, and
    // class-value reads are hot enough (enum entries, companion calls) that
    // wading the whole prefix per read showed up in profiles.
    if (std.mem.eql(u8, name, "<class-companion-or-self>")) {
        if (receiver.* == .Class) {
            // Class-static single-fill memo: the resolution (companion
            // singleton / object singleton / the class value itself) never
            // changes once the singleton exists, and this read is hot
            // enough (`Job` in value position per context lookup) that the
            // string-keyed registry probe priced every occurrence.
            {
                const g = receiver.Class.borrow();
                defer g.deinit();
                switch (g.get().companion_read_state.load(.acquire)) {
                    1 => return ok(receiver.*),
                    2 => return ok(g.get().companion_read_value),
                    else => {},
                }
            }
            const cls_name = blk: {
                const g = receiver.Class.borrow();
                defer g.deinit();
                break :blk g.get().name;
            };
            const is_object = blk: {
                const g = receiver.Class.borrow();
                defer g.deinit();
                break :blk g.get().is_object;
            };
            const comp_name: ?[]const u8 = blk: {
                const g = self.module.borrow();
                defer g.deinit();
                break :blk g.get().registry.companion_singletons.get(cls_name);
            };
            if (comp_name) |cn| {
                switch (try host_globals.ensureObjectSingleton(self, cn)) {
                    .ok => |maybe| if (maybe) |s| {
                        fillCompanionReadMemo(receiver.Class, s);
                        return ok(s);
                    },
                    .err => |e| return errRes(e),
                }
            }
            if (is_object) {
                switch (try host_globals.ensureObjectSingleton(self, cls_name)) {
                    .ok => |maybe| if (maybe) |s| {
                        fillCompanionReadMemo(receiver.Class, s);
                        return ok(s);
                    },
                    .err => |e| return errRes(e),
                }
            }
            if (comp_name == null and !is_object) {
                const g = receiver.Class.borrow();
                defer g.deinit();
                @constCast(g.get()).companion_read_state.store(1, .release);
            }
        }
        return ok(receiver.*);
    }
    // `X.Companion` names the companion explicitly. A declared companion is
    // reached by the ladder below; one that only the kotlinx-serialization
    // plugin would have written is not there at all, and the class value
    // stands in for it exactly as a bare `X` in value position does —
    // `Data.Companion.serializer()` then resolves like `Data.serializer()`.
    if (receiver.* == .Class and std.mem.eql(u8, name, "Companion")) {
        const cls_name = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().name;
        };
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cls_name);
        };
        if (comp_name) |cn| {
            switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| if (maybe) |s| return ok(s),
                .err => |e| return errRes(e),
            }
        }
        return ok(receiver.*);
    }
    // Field-read memo, consulted before the whole ladder: entries exist
    // ONLY for (class, name) pairs that previously fell through every
    // earlier arm and resolved in `instanceField` as a custom getter or
    // stored slot — both facts static per class — so a hit can never
    // shadow an earlier arm that would have claimed the read. The
    // stored index re-verifies by name (instances can define extra
    // slots dynamically); `coroutineContext` stays out (its redirect is
    // suspend-state-dependent, not class-static).
    if (receiver.* == .Instance and !std.mem.eql(u8, name, "coroutineContext")) {
        const inst0 = receiver.Instance;
        const class_p0 = blk: {
            const g = inst0.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        };
        const hit: ?root.ProgramImage.FieldReadHit = blk: {
            const name_p = host_call_member.memberNameIdentity(self, name) orelse break :blk null;
            break :blk fieldReadCacheGet(self, class_p0, name_p);
        };
        if (hit) |h| {
            const NONE = root.ProgramImage.FieldReadHit.NONE;
            if (h.getter != NONE) {
                const fid: FuncId = @enumFromInt(h.getter);
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() < mptr.funcCount()) {
                    return try evalGetterTagged(self, allocator, fid, receiver.*, "site562");
                }
            } else if (h.stored_idx != NONE) {
                const v: ?Value = blk: {
                    const g = inst0.borrow();
                    defer g.deinit();
                    const fields = g.get().fields.items;
                    if (h.stored_idx < fields.len) {
                        const fname = fields[h.stored_idx].name;
                        const val = fields[h.stored_idx].value;
                        if (std.mem.eql(u8, fname, name)) break :blk val;
                        // A scoped-name entry serves the bare-named slot,
                        // but never the lateinit/delegate shapes — those
                        // adjudicate by the bare property name, so the
                        // ladder's own arms must decide them.
                        if (sgetterNameMatches(name, fname) and val != .Null and val != .Delegate) {
                            break :blk val;
                        }
                    }
                    break :blk null;
                };
                if (v) |val| {
                    if (val == .Null) {
                        if (storedNullIsLateinit(inst0, name)) {
                            return try lateinitReadError(allocator, name);
                        }
                    }
                    if (val == .Delegate) {
                        return try unwrapDelegate(self, allocator, val.Delegate, name);
                    }
                    return ok(val);
                }
            }
        }
    }
    // Progression `first`/`last`/`step` property *reads* (no parens): `first`/
    // `last` return the stored bound even when empty (the `Iterable.first()`/
    // `last()` *functions*, dispatched as calls, still throw on empty); `step`
    // is always Int (Int/Char/UInt) or Long (Long/ULong) with its sign. Applies
    // to a host `Value.Range` and to a source range `Instance` (e.g.
    // `ULongRange.EMPTY`, whose `step` field would otherwise read back as Int).
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last") or std.mem.eql(u8, name, "step")) {
        if (stdlib.implementations.ranges.asRangeView(receiver)) |view| {
            if (std.mem.eql(u8, name, "step")) {
                return ok(switch (view.kind) {
                    .Long, .ULong => Value{ .Long = view.step },
                    .Int, .Char, .UInt => Value{ .Int = @truncate(view.step) },
                });
            }
            const v: i64 = if (std.mem.eql(u8, name, "first")) view.start else view.end;
            return ok(switch (view.kind) {
                .Int => .{ .Int = @truncate(v) },
                .Long => .{ .Long = v },
                .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
                .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
                .ULong => .{ .ULong = @bitCast(v) },
            });
        }
    }
    // Reflective reads on a *bound* member reference (`this::name`):
    // `.name`/`.simpleName` yield the referenced member's name, and
    // `.isInitialized` answers the lateinit probe against the captured
    // receiver.
    if ((std.mem.eql(u8, name, "isInitialized") or std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) and
        receiver.* == .Instance)
    {
        const inst = receiver.Instance;
        var bound_recv: ?Value = null;
        var bound_name: ?StringRef = null;
        {
            const g = inst.borrow();
            defer g.deinit();
            const b = g.get();
            if (b.get("__bound_receiver__")) |r| {
                if (b.get("__bound_name__")) |n| {
                    if (n == .String) {
                        bound_recv = r;
                        bound_name = n.String;
                    }
                }
            }
        }
        if (bound_recv) |br| {
            const bn = bound_name.?;
            if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) {
                return ok(.{ .String = bn });
            }
            // isInitialized: true iff the captured receiver declares
            // `bound_name` as a lateinit property whose slot is non-Null.
            if (br == .Instance) {
                const ng = bn.borrow();
                defer ng.deinit();
                const bname = ng.get().bytes;
                const g = br.Instance.borrow();
                defer g.deinit();
                const b = g.get();
                const cg = b.class.borrow();
                defer cg.deinit();
                var is_lateinit = false;
                for (cg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, bname) and p.is_lateinit) {
                        is_lateinit = true;
                        break;
                    }
                }
                var initialised = false;
                if (is_lateinit) {
                    for (b.fields.items) |f| {
                        if (std.mem.eql(u8, f.name, bname) and f.value != .Null) {
                            initialised = true;
                            break;
                        }
                    }
                }
                return ok(.{ .Bool = initialised });
            }
            return ok(.{ .Bool = false });
        }
    }
    // `Throwable.stackTrace`: the captured frames as an `Array` of rendered
    // elements. A user throwable that declares its own `stackTrace` field keeps
    // that field (handled by the normal lookup before this point).
    if (std.mem.eql(u8, name, "stackTrace")) {
        const is_throwable = switch (receiver.*) {
            .Exception => true,
            .Instance => |inst| blk: {
                const g = inst.borrow();
                defer g.deinit();
                break :blk g.get().get("stackTrace") == null and
                    vmhost.host_call_member.instanceIsThrowable(self, allocator, inst);
            },
            else => false,
        };
        if (is_throwable) {
            if (try ir.eval.stackTraceArray(allocator, receiver)) |arr| return ok(arr);
        }
    }
    // `Throwable.suppressedExceptions` on an interpreted throwable instance:
    // the hidden `__suppressed__` list `addSuppressed` maintains (empty when
    // none recorded). Host `Exception` values reach the stdlib binding via
    // the intrinsic probes below.
    if (std.mem.eql(u8, name, "suppressedExceptions") and receiver.* == .Instance) {
        const inst = receiver.Instance;
        const declared = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().get(name) != null;
        };
        if (!declared and vmhost.host_call_member.instanceIsThrowable(self, allocator, inst)) {
            if (vmhost.host_call_member.instanceSuppressedList(inst)) |l| return ok(l);
            const items = try runtime.ValueList.init(allocator, .empty);
            return ok(try Value.newList(allocator, .{ .items = items, .mutable = false, .backing = null }));
        }
    }
    // `e::class.simpleName`/`.qualifiedName` for a builtin exception.
    if ((std.mem.eql(u8, name, "simpleName") or std.mem.eql(u8, name, "qualifiedName")) and receiver.* == .Exception) {
        const g = receiver.Exception.fqn.borrow();
        defer g.deinit();
        const fqn = g.get().bytes;
        const v = if (std.mem.eql(u8, name, "simpleName")) lastSegment(fqn) else fqn;
        return ok(.{ .String = try runtime.strInit(allocator, v) });
    }
    // Explicit `recv.coroutineContext` (lowered to this sentinel):
    // bypass the bare-`coroutineContext` redirect for this one read.
    if (std.mem.eql(u8, name, "$coroutineContext$explicit")) {
        return getFieldInner(self, allocator, receiver, "coroutineContext", true, member_probe, suppress_ext);
    }
    // Scope-qualified property read (`$sgetter$<owner>\u{1f}<name>`): a bare
    // property read inside a method. Kotlin dispatches this virtually — an
    // `open val` overridden in a subclass calls the subclass's getter even
    // when read from a base-class method (e.g. `JobSupport.cancelParent`
    // reading `isScopedCoroutine`, overridden by `ScopeCoroutine`). Resolve
    // the getter from the receiver's runtime class (most-derived first); the
    // lexically enclosing `owner`'s getter is only the fallback.
    if (std.mem.startsWith(u8, name, "$sgetter$")) {
        const rest = name["$sgetter$".len..];
        if (std.mem.indexOfScalar(u8, rest, '\u{1f}')) |sep| {
            const owner = rest[0..sep];
            const prop = rest[sep + 1 ..];
            const mptr: *const Module = self.module.asPtr();
            // Reject a foreign implicit receiver before virtual getter or
            // stored-field lookup. Otherwise its unrelated same-named member
            // can win before the enclosing lexical receiver is considered.
            // If the lexical owner does not declare the property, the scoped
            // marker is only a fallback and the candidate may legitimately
            // provide it (for example, a `with` subject).
            if (member_probe and receiver.* == .Instance) {
                const rcn = className(receiver.Instance);
                // The module walk answers from registered class rows; an
                // anonymous object's row (`$anon$N`) may carry no name-keyed
                // supertype edge there, so the value-level runtime chain is
                // an equal authority on ownership — without it a bare private
                // read inside a member extension rejected the very instance
                // that stores the field.
                const owns = std.mem.eql(u8, rcn, owner) or blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get().classIsOrExtends(rcn, owner);
                } or host_call_member.receiverImplementsType(self, receiver, owner);
                const owner_declares = classDeclaresStoredProp(self, owner, prop) or blk: {
                    const pg = self.prog.borrow();
                    defer pg.deinit();
                    break :blk lookupPairFunc(pg.get().body_prop_inits, owner, prop) != null or
                        lookupPairFunc(pg.get().instance_prop_getters, owner, prop) != null or
                        lookupPairFunc(pg.get().instance_prop_private, owner, prop) != null;
                };
                if (missTraceEnvCached()) |w| {
                    if (std.mem.eql(u8, w, prop)) {
                        std.debug.print("[sgp] owner={s} prop={s} rcn={s} owns={} owner_declares={}\n", .{ owner, prop, rcn, owns, owner_declares });
                    }
                }
                if (!owns and owner_declares) {
                    return errRes(.{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::get_field `{s}` on `{s}`", .{ prop, rcn }) });
                }
            }
            // A private SHADOW of a supertype's same-name declaration has
            // its own storage cell under the owner-mangled key; the
            // declaring class's own reads address exactly that cell (the
            // base class's plain cell stays untouched by the shadow).
            if (receiver.* == .Instance) {
                const is_shadow = blk: {
                    const mg2 = self.module.borrow();
                    defer mg2.deinit();
                    break :blk mg2.get().registry.private_shadow_props.getKey(rest) != null;
                };
                if (is_shadow) {
                    const g2 = receiver.Instance.borrow();
                    const owned = g2.get().get(rest);
                    g2.deinit();
                    if (owned) |v| return ok(v);
                }
                // The shadow cell is keyed by its DECLARING class. When the read
                // comes from an inner scope whose sgetter `owner` is NOT that
                // class (an anon object / lambda captured inside it, e.g.
                // `iterator { parent... }` in `MutableSetWrapper`'s anon iterator,
                // where `parent` shadows `SetWrapper.parent`), the owner-mangled
                // `rest` misses. The captured receiver's OWN class supplies the
                // right key. This ONLY applies when the lexical `owner` does not
                // itself declare a stored `prop`: a bare read in a base-class
                // method (`Base.baseRead` reading its own private `x`) is
                // lexically bound to the base's cell and must ignore a subclass's
                // same-name shadow even when the runtime receiver is that subclass.
                const rcn = className(receiver.Instance);
                if (!std.mem.eql(u8, rcn, owner) and !classDeclaresStoredProp(self, owner, prop)) {
                    if (std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ rcn, prop }) catch null) |rk| {
                        defer allocator.free(rk);
                        const rc_shadow = blk: {
                            const mg2 = self.module.borrow();
                            defer mg2.deinit();
                            break :blk mg2.get().registry.private_shadow_props.getKey(rk) != null;
                        };
                        if (rc_shadow) {
                            const g2 = receiver.Instance.borrow();
                            const owned = g2.get().get(rk);
                            g2.deinit();
                            if (owned) |v| return ok(v);
                        }
                    }
                }
            }
            const lexical_private_getter = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk lookupPairFunc(pg.get().instance_prop_private, owner, prop) != null;
            };
            if (receiver.* == .Instance and !lexical_private_getter) {
                var cur: ?[]const u8 = className(receiver.Instance);
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(allocator);
                while (cur) |cn| {
                    cur = null;
                    if (containsStr(seen.items, cn)) break;
                    try seen.append(allocator, cn);
                    const stored_here = blk: {
                        const cg = self.classes.borrow();
                        defer cg.deinit();
                        const def = cg.get().get(cn) orelse break :blk false;
                        const dg = def.borrow();
                        defer dg.deinit();
                        break :blk declaresStored(dg.get(), prop);
                    };
                    // A concrete stored override is itself the virtual
                    // implementation of the property. Stop before an inherited
                    // computed getter and let the ordinary field path select
                    // the override's backing cell — UNLESS the stored field is
                    // a foreign class's PRIVATE property, which never
                    // participates in override dispatch (ktor:
                    // HttpClientEngineBase's private `closed = atomic(false)`
                    // must not answer the HttpClientEngine interface's own
                    // private computed `closed`).
                    const stored_foreign_private = stored_here and
                        !std.mem.eql(u8, cn, owner) and blk: {
                        const pg = self.prog.borrow();
                        defer pg.deinit();
                        break :blk lookupPairFunc(pg.get().instance_prop_private, cn, prop) != null;
                    };
                    if (missTraceEnvCached()) |w| {
                        if (std.mem.eql(u8, w, prop))
                            std.debug.print("[sgw] cn={s} stored={} foreign_priv={}\n", .{ cn, stored_here, stored_foreign_private });
                    }
                    if (stored_here and !stored_foreign_private) {
                        const r = try getFieldInner(self, allocator, receiver, prop, suppress_cc_redirect, member_probe, suppress_ext);
                        if (r == .ok and sgetterMemoSafe(self, className(receiver.Instance), rest, owner, prop)) {
                            sgetterCopyMemo(self, receiver, prop, name);
                        }
                        return r;
                    }
                    const vfid = blk: {
                        const pg = self.prog.borrow();
                        defer pg.deinit();
                        break :blk lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, prop);
                    };
                    if (vfid) |fid| {
                        // A private property never participates in override
                        // dispatch: a same-named private declared anywhere but
                        // the lexical owner is a different declaration (ktor:
                        // HttpClientEngineBase's field-backed `closed` vs the
                        // HttpClientEngine interface's private `closed`
                        // getter). Skip it and keep walking; public inherited
                        // getters (JobSupport's `isActive` read from a
                        // subclass frame) still resolve through the chain.
                        const foreign_private = !std.mem.eql(u8, cn, owner) and blk: {
                            const pg = self.prog.borrow();
                            defer pg.deinit();
                            break :blk lookupPairFunc(pg.get().instance_prop_private, cn, prop) != null;
                        };
                        if (!foreign_private and fid.int() < mptr.funcCount()) {
                            if (sgetterMemoSafe(self, className(receiver.Instance), rest, owner, prop)) {
                                sgetterPutGetter(self, receiver, name, fid);
                            }
                            return evalGetterTagged(self, allocator, fid, receiver.*, "virtual-walk");
                        }
                    }
                    cur = firstSupertype(self, cn);
                }
            }
            // Run the lexical `owner`'s getter against the receiver only when
            // the receiver is actually an instance of `owner` (or a subclass).
            // During a member probe of the implicit-receiver chain, a candidate
            // that is not an `owner` instance — e.g. the StringBuilder receiver
            // inside a `buildString { ... }` lambda when reading an enclosing
            // class's property — must not run the owner's getter against the
            // wrong receiver. It still falls through to the member-only
            // bare-name lookup below, which resolves a property the candidate
            // genuinely owns (a scope receiver's own member) and otherwise
            // reports a probe miss so the resolver continues to the enclosing
            // `owner` receiver further out.
            const owner_applies = !member_probe or receiver.isRuntimeType(owner) or
                (receiver.* == .Instance and blk: {
                    // The value-level runtime-type check misses native-backed
                    // and pack-loaded subtype chains (KlioClientEngine IS an
                    // HttpClientEngine only through the module walk); without
                    // this the owner's getter was skipped and the plain field
                    // fallback below read a base class's PRIVATE stored field.
                    const rcn0 = className(receiver.Instance);
                    const mg0 = self.module.borrow();
                    defer mg0.deinit();
                    break :blk mg0.get().classIsOrExtends(rcn0, owner);
                } or host_call_member.receiverImplementsType(self, receiver, owner));
            if (owner_applies) {
                const fid_opt = blk: {
                    const pg = self.prog.borrow();
                    defer pg.deinit();
                    break :blk lookupPairFunc(pg.get().instance_prop_getters, owner, prop);
                };
                if (fid_opt) |fid| {
                    if (fid.int() < mptr.funcCount()) {
                        // A direct scoped read normally runs with `this` being
                        // an `owner` instance, but inside an inline
                        // receiver-splice (`holder.apply { ... readerTable ... }`)
                        // the frame's `this` is the SPLICE receiver. The
                        // owner's getter must run on the enclosing owner
                        // instance from the receiver chain, never on a foreign
                        // receiver — that misbound every bare enclosing-class
                        // property read inside such a splice. The ownership
                        // test is the module-backed subtype walk, exactly as
                        // the probe guard above uses it — the Value-level
                        // runtime-type check misses native-backed subtype
                        // chains and rerouted the whole collections suite.
                        if (receiver.* == .Instance) {
                            const rcn2 = className(receiver.Instance);
                            const recv_owns = std.mem.eql(u8, rcn2, owner) or blk: {
                                const mg2 = self.module.borrow();
                                defer mg2.deinit();
                                break :blk mg2.get().classIsOrExtends(rcn2, owner);
                            } or host_call_member.receiverImplementsType(self, receiver, owner);
                            if (!recv_owns) {
                                var recv_probe = receiver.*;
                                if (try host_call_member.memberExtOwnerInstance(self, allocator, &recv_probe, owner)) |inst| {
                                    return evalGetterTagged(self, allocator, fid, inst, "owner-enclosing");
                                }
                            }
                            // Memoizable only when a member PROBE would take
                            // this same terminal: the receiver owns `owner`
                            // under both the module walk and the value-level
                            // runtime-type check (the probe's gate).
                            if (recv_owns and receiver.isRuntimeType(owner) and
                                sgetterMemoSafe(self, rcn2, rest, owner, prop))
                            {
                                sgetterPutGetter(self, receiver, name, fid);
                            }
                        }
                        return evalGetterTagged(self, allocator, fid, receiver.*, "owner-lexical");
                    }
                }
            }
            {
                const r = try getFieldInner(self, allocator, receiver, prop, suppress_cc_redirect, member_probe, suppress_ext);
                // Memoizable only when no lexical-owner getter exists at all
                // (then both execution modes fall through to this recursion)
                // and the class-static gates hold.
                if (r == .ok and receiver.* == .Instance) {
                    const no_owner_getter = blk: {
                        const pg = self.prog.borrow();
                        defer pg.deinit();
                        break :blk lookupPairFunc(pg.get().instance_prop_getters, owner, prop) == null;
                    };
                    if (no_owner_getter and sgetterMemoSafe(self, className(receiver.Instance), rest, owner, prop)) {
                        sgetterCopyMemo(self, receiver, prop, name);
                    }
                }
                return r;
            }
        }
    }
    // Suspend-implicit `coroutineContext` intrinsic: redirect a bare
    // read to the active coroutine scope's context. With no scope on the
    // driver stack (a suspend body reached straight from the root, e.g.
    // `suspend fun main`), the ambient context is the empty context —
    // Kotlin's suspend functions always have one — so a receiver that
    // doesn't own the property reads `EmptyCoroutineContext` instead of
    // erroring on a missing member.
    if (std.mem.eql(u8, name, "coroutineContext") and !suppress_cc_redirect) {
        var recv_stores_context = false;
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            recv_stores_context = g.get().get("coroutineContext") != null;
            g.deinit();
        }
        if (activeCoroScope()) |scope| {
            const same = scope == .Instance and receiver.* == .Instance and
                ObjRef(InstanceData).ptrEq(scope.Instance, receiver.Instance);
            if (!same and !recv_stores_context) {
                // The intrinsic is the current continuation's context. A scope
                // built by the stdlib `Continuation(context) {}` factory (a
                // `startCoroutine` completion) declares only `context`, so
                // prefer a scope-owned `coroutineContext` and fall back to its
                // `context`; the empty context is the last resort.
                if (vmhost.host_call_member.hostHasProperty(self, &scope, "coroutineContext")) {
                    return getFieldInner(self, allocator, &scope, "coroutineContext", suppress_cc_redirect, member_probe, suppress_ext);
                }
                if (vmhost.host_call_member.hostHasProperty(self, &scope, "context")) {
                    return getFieldInner(self, allocator, &scope, "context", suppress_cc_redirect, member_probe, suppress_ext);
                }
                switch (try host_globals.ensureObjectSingleton(self, "EmptyCoroutineContext")) {
                    .ok => |maybe| if (maybe) |v| return ok(v),
                    .err => |e| return errRes(e),
                }
            }
        } else if (!recv_stores_context and receiver.* == .Instance and
            !vmhost.host_call_member.hostHasProperty(self, receiver, "coroutineContext"))
        {
            // No driver scope and no own property anywhere on the class
            // chain: the ambient suspend context is the empty context
            // (a suspend body always has one).
            switch (try host_globals.ensureObjectSingleton(self, "EmptyCoroutineContext")) {
                .ok => |maybe| if (maybe) |v| return ok(v),
                .err => |e| return errRes(e),
            }
        }
    }
    // Value-class internal-field read on `kotlin.Result` /
    // `ChannelResult`: a bare `value`/`holder` read yields the payload.
    if ((std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "holder")) and receiver.* == .Result) {
        const out = receiver.Result.payload.asPtr().*;
        out.retain();
        return ok(out);
    }
    // Backing-field bypass: `field` lowers into a read on this synthetic
    // name. Route straight to the raw instance slot.
    if (std.mem.startsWith(u8, name, "__klio_field__") and receiver.* == .Instance) {
        const raw = name["__klio_field__".len..];
        const g = receiver.Instance.borrow();
        defer g.deinit();
        if (g.get().get(raw)) |v| return ok(v);
        return ok(.Null);
    }
    // Anon-object custom getter: invoke a `$get$<name>` anon method when
    // one is registered for the receiver's class.
    if (receiver.* == .Instance) {
        const cls_name = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        const getter_name = try std.fmt.allocPrint(allocator, "$get${s}", .{name});
        defer allocator.free(getter_name);
        const has_getter = blk: {
            const g = self.anon_methods.borrow();
            defer g.deinit();
            break :blk g.get().contains(anonKey(cls_name, getter_name));
        };
        if (has_getter) {
            return self.callMember(allocator, receiver, getter_name, &.{});
        }
    }
    // `Thread` handle property reads (`t.name`, `t.isAlive`).
    if (receiver.* == .BoundMethod) {
        const bm = receiver.BoundMethod;
        if (std.mem.eql(u8, bm.fqn, "kotlin.concurrent.Thread")) {
            const id: u64 = switch (bm.receiver.asPtr().*) {
                .Long => |v| @bitCast(v),
                else => 0,
            };
            if (std.mem.eql(u8, name, "isAlive")) {
                return ok(.{ .Bool = host_impl.threadAlive(self, id) });
            }
            if (std.mem.eql(u8, name, "name")) {
                // A dispatcher pool worker reports its registered
                // upstream-shaped name (`DefaultDispatcher-worker-N`).
                if (runtime.threadName(allocator, id)) |overridden| {
                    return ok(.{ .String = try runtime.strInitOwned(allocator, overridden) });
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
        }
    }
    // Enum: `Color.RED` / `Color.entries` on a `Value::Class`.
    if (receiver.* == .Class) {
        const is_enum = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().is_enum;
        };
        if (is_enum) {
            if (std.mem.eql(u8, name, "entries")) {
                var items: std.ArrayList(Value) = .empty;
                errdefer items.deinit(allocator);
                {
                    const g = receiver.Class.borrow();
                    defer g.deinit();
                    for (g.get().enum_entries) |e| {
                        e.value.retain();
                        try items.append(allocator, e.value);
                    }
                }
                return ok(try frozenList(allocator, items, true));
            }
            const g = receiver.Class.borrow();
            defer g.deinit();
            for (g.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, name)) return ok(e.value);
            }
        }
    }
    // Bound method/property reference field reads.
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const snap = g.get();
        if (snap.get("__bound_receiver__") != null) {
            if (snap.get("__bound_name__")) |n| {
                if (n == .String and (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName"))) {
                    return ok(.{ .String = n.String });
                }
            }
        }
    }
    // KFunction reflection: `::main.name`, `::main.parameters`.
    if (receiver.* == .IrClosure) {
        const id = receiver.IrClosure.id;
        if (self.closures.get(@intCast(id))) |info| {
            const mptr: *const Module = info.module orelse self.module.asPtr();
            if (mptr.funcById(info.body_func)) |f| {
                if (std.mem.eql(u8, name, "name")) {
                    return ok(.{ .String = try runtime.strInit(allocator, f.name) });
                }
                if (std.mem.eql(u8, name, "parameters")) {
                    var items: std.ArrayList(Value) = .empty;
                    errdefer items.deinit(allocator);
                    for (f.params) |p| {
                        try items.append(allocator, .{ .String = try runtime.strInit(allocator, p.name) });
                    }
                    return ok(try frozenList(allocator, items, false));
                }
            }
        }
    }
    // Companion-object forwarding: `Foo.PI` reads `PI` from the companion
    // singleton; nested class / singleton resolution on a class receiver.
    if (receiver.* == .Class) {
        if (try classReceiverField(self, allocator, receiver, name)) |v| return v;
    }
    // A member property (its getter) outranks a same-named extension
    // property. Skip the extension lookup when the receiver's class
    // hierarchy declares a member getter for this name.
    const member_getter_shadows = blk: {
        // A BUILTIN receiver's own member property outranks a same-named
        // extension property too — `LongArray.size` is a member, so
        // `val LongArray.size get() = this.size` does not capture `a.size`
        // (and therefore does not call itself for ever).
        if (builtinMemberProperty(receiver, name)) break :blk true;
        if (receiver.* != .Instance) break :blk false;
        var cur: ?[]const u8 = className(receiver.Instance);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        var found = false;
        while (cur) |cn_raw| {
            // A dotted nested supertype (`Modifier.Node`) lifted under a
            // mangled key registers its properties there; canonicalize the
            // hop so the inherited member is seen (Kotlin resolves the
            // member over a same-named extension property).
            const cn = canon: {
                const cg0 = self.classes.borrow();
                defer cg0.deinit();
                if (cg0.get().get(cn_raw) != null) break :canon cn_raw;
                break :canon host_call_member.mangledClassKeyOf(self, cn_raw) orelse cn_raw;
            };
            cur = null;
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            {
                const pg = self.prog.borrow();
                const hit = lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, name) != null;
                pg.deinit();
                if (hit) {
                    found = true;
                    break;
                }
            }
            // A declared member property (stored body property or
            // constructor-parameter property) also outranks a same-named
            // extension property — Kotlin resolves the member first. Without
            // this a member-reading extension recurses (`val Route.application
            // get() = when (this) { is RoutingRoot -> application; … }`).
            var parent_name: ?[]const u8 = null;
            {
                const cg = self.classes.borrow();
                const def = cg.get().get(cn);
                if (def) |d| {
                    const dg = d.borrow();
                    for (dg.get().body_properties) |p| {
                        if (std.mem.eql(u8, p.name, name)) found = true;
                    }
                    for (dg.get().primary_params) |p| {
                        if (p.property != null and std.mem.eql(u8, p.name, name)) found = true;
                    }
                    // Prefer the RESOLVED parent-class link for the next hop:
                    // supertype_names' first entry may be an interface when the
                    // parent class was recorded through the resolved link only
                    // (BackwardsCompatNode : Modifier.Node(), LayoutModifierNode…).
                    if (dg.get().parent) |par| {
                        const ng = par.borrow();
                        parent_name = ng.get().name;
                        ng.deinit();
                    }
                    dg.deinit();
                }
                cg.deinit();
                if (found) break;
            }
            cur = parent_name orelse firstSupertype(self, cn);
        }
        break :blk found;
    };
    // Top-level / supertype / Any extension property.
    if (!member_getter_shadows and !suppress_ext) {
        // For a class-value receiver (`X.name`), a `val X.Companion.name`
        // extension registers under `X`'s simple name; the getter `this`
        // is `X`'s companion instance, not the class value.
        const recv_simple: []const u8 = switch (receiver.*) {
            .Instance => |i| className(i),
            .Class => |c| blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk lastSegment(g.get().name);
            },
            else => lastSegment(receiver.typeFqn()),
        };
        const ext_fid = try resolveExtensionProp(self, allocator, receiver, recv_simple, name);
        if (ext_fid) |fid| {
            if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
                if (std.mem.eql(u8, w, name)) {
                    std.debug.print("[extprop-serve] {s} recv={s} fid={d} member_probe={} suppress_ext={}\n", .{ name, recv_simple, fid.int(), member_probe, suppress_ext });
                    ir.eval.dumpFrameChainForDiagAlways();
                }
            }
            const mptr: *const Module = self.module.asPtr();
            if (fid.int() >= mptr.funcCount()) {
                const msg = try std.fmt.allocPrint(allocator, "extension prop FuncId {d} out of range", .{fid.int()});
                return errRes(.{ .Type = msg });
            }
            // A companion extension's getter `this` is the class's
            // companion instance; route the class value to it. A KClass/Any
            // keyed extension keeps the class value itself.
            var getter_recv = receiver.*;
            if (receiver.* == .Class and try classExtPropUsesCompanion(self, allocator, recv_simple, name)) {
                if (try companionInstanceForClass(self, recv_simple)) |comp| getter_recv = comp;
            }
            // A member-extension property's getter body has its declaring
            // class's `this` in lexical scope; seed the getter frame with
            // the owner instance from the enclosing chain.
            var pushed_owner = false;
            if (mptr.registry.member_ext_owner_class.get(fid)) |owner| {
                if (try host_call_member.memberExtOwnerInstance(self, allocator, &getter_recv, owner)) |inst| {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
            const r = try evalGetterTagged(self, allocator, fid, getter_recv, "site1202");
            if (pushed_owner) ir.eval.popEnclosing();
            return r;
        }
        // Delegated extension property (`val R.x by expr`): materialise
        // the delegate object once per property, then read through its
        // `getValue(thisRef, property)`.
        if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, name)) |hit| {
            const d = try extPropDelegateInstance(self, allocator, hit.key, name, hit.fid);
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
            return try self.callMember(allocator, &d, "getValue", &.{ receiver.*, prop_ref });
        }
    }
    // Reflection-style accessors on `KClass` / `KProperty` values.
    switch (receiver.*) {
        .Class => {
            if (try classReflective(self, allocator, receiver, name)) |v| return v;
        },
        .PropertyRef => |pr| {
            if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "simpleName")) {
                return ok(.{ .String = pr.name });
            }
            if (std.mem.eql(u8, name, "isInitialized")) {
                const prop_name = blk: {
                    const g = pr.name.borrow();
                    defer g.deinit();
                    break :blk g.get().bytes;
                };
                const chain = try ir.eval.enclosingThisChainAlloc(allocator);
                defer allocator.free(chain);
                for (chain) |o| {
                    if (o == .Instance) {
                        const g = o.Instance.borrow();
                        defer g.deinit();
                        const b = g.get();
                        const cg = b.class.borrow();
                        defer cg.deinit();
                        var is_lateinit = false;
                        for (cg.get().body_properties) |p| {
                            if (std.mem.eql(u8, p.name, prop_name) and p.is_lateinit) {
                                is_lateinit = true;
                                break;
                            }
                        }
                        if (!is_lateinit) continue;
                        var initialised = false;
                        for (b.fields.items) |f| {
                            if (std.mem.eql(u8, f.name, prop_name) and f.value != .Null) {
                                initialised = true;
                                break;
                            }
                        }
                        return ok(.{ .Bool = initialised });
                    }
                }
                return ok(.{ .Bool = false });
            }
        },
        else => {},
    }
    // `lastIndex` / `indices` on arrays + lists + strings.
    if (std.mem.eql(u8, name, "lastIndex")) {
        if (collectionLen(receiver)) |len| {
            return ok(Value.newInt(len - 1));
        }
    }
    if (std.mem.eql(u8, name, "indices")) {
        if (collectionLen(receiver)) |len| {
            return ok(try Value.newRange(allocator, .{ .start = 0, .end = len - 1, .step = 1, .kind = .Int }));
        }
    }
    // The underlying-storage accessor of an unsigned inline type:
    // `UByte(val data: Byte)` etc. `x.data` reinterprets the unsigned scalar
    // as its signed counterpart (used by `UByte.toHexString` == `data.toHexString`).
    if (std.mem.eql(u8, name, "data")) {
        switch (receiver.*) {
            .UByte => |x| return ok(.{ .Byte = @bitCast(x) }),
            .UShort => |x| return ok(.{ .Short = @bitCast(x) }),
            .UInt => |x| return ok(.{ .Int = @bitCast(x) }),
            .ULong => |x| return ok(.{ .Long = @bitCast(x) }),
            else => {},
        }
    }
    // `UByteArray.storage` etc. — the signed array over the SAME bytes.
    // Kotlin's unsigned arrays are value classes over their signed storage,
    // so writes through the view must land in the original (`Random.nextUBytes`
    // fills `array.asByteArray()` in place). Share the backing cell and let
    // the Array value's `prim` carry the signed VIEW kind — the accessors
    // read/write through the view kind over identical byte layout, the same
    // mechanism `IntArray.asUIntArray()` uses in the other direction.
    if (std.mem.eql(u8, name, "storage") and receiver.* == .Array) {
        const a = receiver.Array;
        if (a.prim) |k| {
            if (k.signedCounterpart()) |signed| {
                if (a.storage() == .scalars) {
                    return ok(.{ .Array = runtime.ArrayData.scalars(a.storage().scalars.clone(), signed) });
                }
            }
        }
    }
    // `size` on arrays + collections.
    if (std.mem.eql(u8, name, "size")) {
        switch (receiver.*) {
            .Array => |a| return ok(Value.newInt(@intCast(a.len()))),
            .List => |l| {
                if (stdlib.implementations.collections.sublistViewStale(receiver)) {
                    return errRes(.{ .Throw = try Value.newException(allocator, .{
                        .fqn = try runtime.strInit(allocator, "kotlin.ConcurrentModificationException"),
                        .message = .{},
                        .cause = null,
                    }) });
                }
                return ok(Value.newInt(@intCast(listLen(l.items))));
            },
            .Set => |s| return ok(Value.newInt(@intCast(listLen(s.items)))),
            .Map => |m| {
                const g = m.entries.borrow();
                defer g.deinit();
                return ok(Value.newInt(@intCast(g.get().pairs.items.len)));
            },
            else => {},
        }
    }
    if (receiver.* == .Instance) {
        if (try instanceField(self, allocator, receiver, name, member_probe)) |v| return v;
    }
    // Stdlib property read on a built-in type — `"abc".length`, etc.
    const type_fqn = receiver.typeFqn();
    const probe_is_toplevel_fn = stdlib.isToplevelFunction(name);
    // The binary `kotlin.math.min`/`max` functions are not property
    // accessors: dispatched with the receiver as their lone argument they
    // return it unchanged, which would mask the read as the receiver itself
    // (a bare `min(x, y)` callee in a receiver context is the package
    // function, not a member of the implicit receiver).
    if (!probe_is_toplevel_fn and !stdlib.isBinaryMathFunction(name)) {
        // The winning probe (or confirmed "none") is a pure function of
        // (receiver type, name): memoize it on the program image so a hot
        // property read skips the five allocPrint+lookupIntrinsic probes.
        const cache_key: ?root.ProgramImage.MemberHasKey = blk: {
            const pg = self.prog.borrowMut();
            defer pg.deinit();
            const tp = pg.get().memberNameIdentity(type_fqn) orelse break :blk null;
            const np = pg.get().memberNameIdentity(name) orelse break :blk null;
            break :blk .{ .class_p = tp, .name_p = np };
        };
        var resolved: ?root.ProgramImage.MemberResolveEntry = null;
        var have_verdict = false;
        if (cache_key) |key| {
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (pg.get().field_probe_cache.get(key)) |entry| {
                have_verdict = true;
                if (entry.func != null) resolved = entry;
            }
        }
        if (!have_verdict) {
            const probes = [_][]const u8{
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }),
                try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}),
                try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}),
                try std.fmt.allocPrint(allocator, "kotlin.math.{s}", .{name}),
                try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}),
            };
            defer for (probes) |p| allocator.free(p);
            var winner: ?struct { fqn: []const u8, func: StdlibFn } = null;
            for (probes) |probe| {
                // A bare UPPERCASE name read as a field is a companion/type
                // reference (`Char` in value position inside a method); the
                // root `kotlin.<Name>` binding for such a name is the type's
                // CONSTRUCTOR/conversion intrinsic, never a property — invoking
                // it with the receiver converts the receiver (Type error).
                // Type-qualified constant probes (`kotlin.Int.MAX_VALUE`) stay.
                if (name.len > 0 and std.ascii.isUpper(name[0])) {
                    const dot = std.mem.lastIndexOfScalar(u8, probe, '.') orelse 0;
                    if (std.mem.eql(u8, probe[0..dot], "kotlin")) continue;
                }
                if (lookupIntrinsic(self, probe)) |func| {
                    winner = .{ .fqn = probe, .func = func };
                    break;
                }
            }
            if (cache_key) |key| {
                const pg = self.prog.borrowMut();
                defer pg.deinit();
                const cache = &pg.get().field_probe_cache;
                if (!cache.contains(key)) {
                    if (winner) |w| {
                        const stored = cache.allocator.dupe(u8, w.fqn) catch null;
                        if (stored) |sf| {
                            cache.put(key, .{ .func = w.func, .fqn = sf }) catch cache.allocator.free(sf);
                        }
                    } else {
                        cache.put(key, .{ .func = null, .fqn = "" }) catch {};
                    }
                }
            }
            if (winner) |w| resolved = .{ .func = w.func, .fqn = try allocator.dupe(u8, w.fqn) };
            // The probes buffer frees on scope exit; `resolved.fqn` for the
            // uncached-winner case is the request-lifetime dupe made above.
        }
        if (resolved) |entry| {
            const args = [_]Value{receiver.*};
            const r = try dispatchIntrinsic(self, allocator, entry.fqn, entry.func.?, &args);
            // A strict member probe must not surface a `Type` error from an
            // intrinsic that does not apply to this receiver — e.g. the
            // `kotlin.math.absoluteValue` intrinsic dispatched on a
            // StringBuilder (a `$sgetter$<owner>` read probed against a
            // scope-function receiver). That is a probe miss, not a member
            // whose accessor threw; report it as `.Unimplemented` so the
            // resolver walks on to the enclosing receiver. Outside a probe
            // the read was already bound to this receiver, so the error
            // (a genuine wrong-type access) propagates as before.
            if (member_probe and r == .err and r.err == .Type) {
                ir.eval.dumpFrameChainForDiag();
                return errRes(.{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::get_field `{s}` on `{s}`", .{ name, type_fqn }) });
            }
            return r;
        }
    }
    // Class-delegation forwarding for property reads. Forward only the
    // properties the delegated interface itself declares — Kotlin never
    // forwards extensions or unrelated names to the delegate.
    if (receiver.* == .Instance) {
        var delegates: std.ArrayList(Value) = .empty;
        defer delegates.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            for (g.get().fields.items) |f| {
                if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
                const iface = f.name["__delegate__".len..];
                if (host_call_member.delegatedInterfaceDeclares(self, allocator, receiver.Instance, iface, name) == false) continue;
                try delegates.append(allocator, f.value);
            }
        }
        for (delegates.items) |d| {
            switch (try getFieldInner(self, allocator, &d, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                .ok => |v| if (v != .Unit) return ok(v),
                // Only the dispatch-miss sentinel means "no such member";
                // a real throw from the delegate's accessor must propagate.
                .err => |e| if (e == .Unimplemented) freeFieldMiss(allocator, e) else return .{ .err = e },
            }
        }
    }
    // `Long.MAX_VALUE` / `Int.SIZE_BITS` / `Double.NaN` via the
    // primitive-companion table by the class's simple name.
    if (receiver.* == .Class) {
        const simple = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk lastSegment(g.get().name);
        };
        if (stdlib.primitive_companion_const(simple, name)) |v| return ok(v);
    }
    // A NESTED CLASS of the receiver's class (or a lexically-enclosing class):
    // a bare `Nested` referenced inside `Outer`'s own body resolves to the
    // nested classifier, NOT to a same-named companion member. Uses the nesting
    // tree (built at VM setup from FQNs), so it resolves uniformly for source
    // and baked-pack classes — a source program takes an enclosing-instance walk
    // that a baked pack lacks, which otherwise fell through to the companion
    // fallback below. A nested object resolves to its singleton.
    if (!member_probe and receiver.* == .Instance) {
        const cn0 = className(receiver.Instance);
        const nested_id: ?ir.ClassId = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            const oid = mg.get().classId(cn0) orelse break :blk null;
            break :blk mg.get().classIdNestedIn(oid, name);
        };
        if (nested_id) |cid| {
            const nfqn: ?[]const u8 = blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk mg.get().classFqnById(cid);
            };
            if (nfqn) |fqn| {
                switch (try host_globals.ensureObjectSingleton(self, fqn)) {
                    .ok => |maybe| if (maybe) |v| {
                        if (v == .Instance) return ok(v);
                    },
                    .err => |e| return errRes(e),
                }
                const def: ?ObjRef(ClassDef) = blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    if (cg.get().get(fqn)) |d| break :blk d.clone();
                    break :blk null;
                };
                if (def) |d| return ok(.{ .Class = d });
            }
        }
    }
    // Companion fallback for an instance receiver: a companion `val` is
    // in scope unqualified inside the class's own member bodies. The
    // member probe skips it — companions ride the bare-name walk as
    // their own candidates at the owning class's depth.
    if (!member_probe and receiver.* == .Instance) {
        const is_companion_recv = std.mem.indexOf(u8, className(receiver.Instance), "$Companion$") != null;
        var cur: ?[]const u8 = if (is_companion_recv) null else className(receiver.Instance);
        // The lexically-enclosing class for the *first* hop is taken from the
        // receiver's FQN, whose nesting is unambiguous. The `enclosing_class`
        // map keys by simple name, so when two nested classes share a simple
        // name (`Outer1.Builder` and `Outer2.Builder` both lift to `Builder`)
        // it resolves only one of them; the FQN-derived parent keeps each
        // receiver bound to its own enclosing scope.
        const recv_encl_from_fqn: ?[]const u8 = enclosingSimpleFromFqn(self, receiver.Instance);
        var first_hop = true;
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cname| {
            cur = null;
            if (containsStr(seen.items, cname)) break;
            try seen.append(allocator, cname);
            const comp_name: ?[]const u8 = blk: {
                const g = self.module.borrow();
                defer g.deinit();
                break :blk g.get().registry.companion_singletons.get(cname);
            };
            if (comp_name) |cn| {
                // The bare name IS this class's (or an inherited interface's)
                // companion object's own simple name (`Key` referencing
                // `companion object Key`, registered mangled as
                // `Owner$Companion$Key`): resolve to the companion singleton
                // itself, not a member of it. This covers a super-interface's
                // companion, which a bare reference from a default member /
                // implementor would otherwise miss (the member lookup below
                // only finds members declared *inside* the companion).
                if (std.mem.eql(u8, companionSimpleName(cn), name)) {
                    if (try companionInstanceForClass(self, cname)) |comp| return ok(comp);
                }
                const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                    .ok => |maybe| maybe,
                    .err => |e| return errRes(e),
                };
                if (singleton) |s| {
                    if (s == .Instance) {
                        switch (try getFieldInner(self, allocator, &s, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                            .ok => |v| if (v != .Unit) return ok(v),
                            .err => |e| freeFieldMiss(allocator, e),
                        }
                    }
                }
            }
            // Walk the supertype chain first, then the lexically-enclosing
            // class chain: a member declared by an enclosing class's companion
            // (`HexFormat.Default` referenced bare from the nested
            // `HexFormat.Builder`) is in scope unqualified and must be found
            // before a same-named top-level/global class swaps in below.
            if (firstSupertype(self, cname)) |sup| {
                cur = sup;
            } else if (first_hop and recv_encl_from_fqn != null) {
                cur = recv_encl_from_fqn;
            } else {
                const g = self.module.borrow();
                defer g.deinit();
                cur = g.get().registry.enclosing_class.get(cname);
            }
            first_hop = false;
        }
    }
    // A top-level *function* must not outrank a property of an enclosing
    // implicit receiver. Try the enclosing receiver first when the
    // global is callable, adopting only a non-callable result.
    const global_is_callable = !member_probe and blk: {
        {
            const g = self.module.borrow();
            defer g.deinit();
            if (g.get().hasFuncNamed(name)) break :blk true;
        }
        const gg = self.globals.borrow();
        defer gg.deinit();
        break :blk switch (gg.get().lookup(name) orelse Value.Null) {
            .IrClosure, .Intrinsic, .BoundMethod => true,
            else => false,
        };
    };
    if (global_is_callable) {
        const chain = try ir.eval.enclosingThisChainAlloc(allocator);
        defer allocator.free(chain);
        for (chain) |outer| {
            const skip = outer == .Null or outer == .Unit or
                (outer == .Instance and receiver.* == .Instance and ObjRef(InstanceData).ptrEq(outer.Instance, receiver.Instance));
            if (skip) continue;
            const oid: usize = if (outer == .Instance) outer.Instance.identity() else 0;
            if (try withFieldResolvePair(self, allocator, oid, name, &outer, suppress_cc_redirect, false)) |r| {
                if (r == .ok) {
                    switch (r.ok) {
                        .Unit, .IrClosure, .Intrinsic, .BoundMethod => {},
                        else => return r,
                    }
                }
            }
        }
    }
    // Bare top-level `const val` / `val` referenced inside an extension
    // body — resolve as a global before failing. The member probe never
    // adopts a global: the walk's own terminal arm decides that tier.
    if (!member_probe) {
        if (try memberExtOwnerRead(self, allocator, receiver, name)) |r| return r;
        {
            const gg = self.globals.borrow();
            defer gg.deinit();
            if (gg.get().lookup(name)) |v| return ok(v);
        }
        // Stdlib const-style globals through the full global path.
        if (self.lookupGlobal(name)) |v| return ok(v);
        // Drive a later top-level property's initializer on demand.
        switch (try host_impl.ensureTopLevelInited(self, name)) {
            .ok => |maybe| if (maybe) |v| return ok(v),
            .err => |e| return errRes(e),
        }
    }
    // Enclosing-receiver fallback: a bare member property read inside a
    // member-extension / receiver-lambda body may name a member of the
    // lexically enclosing class instance. The member probe skips it —
    // enclosing receivers are the walk's own candidates.
    if (!member_probe) {
        // The chain holds the lexical receivers innermost-first (an
        // extension receiver sits inside its member-extension owner), so
        // every entry is a candidate, not just the innermost.
        const chain = try ir.eval.enclosingThisChainAlloc(allocator);
        defer allocator.free(chain);
        for (chain) |outer| {
            const same = outer == .Instance and receiver.* == .Instance and ObjRef(InstanceData).ptrEq(outer.Instance, receiver.Instance);
            if (same or outer == .Null or outer == .Unit) continue;
            const oid: usize = if (outer == .Instance) outer.Instance.identity() else 0;
            if (try withFieldResolvePair(self, allocator, oid, name, &outer, suppress_cc_redirect, false)) |r| {
                if (r == .ok and r.ok != .Unit) return r;
            }
        }
    }
    // Inner-class outer-chain fallback: walk the receiver's captured
    // `outer` link for a field of an enclosing-class instance.
    if (!member_probe and !field_outer_active) {
        field_outer_active = true;
        defer field_outer_active = false;
        var cur: ?Value = switch (receiver.*) {
            .Instance => |i| blk: {
                const g = i.borrow();
                defer g.deinit();
                break :blk g.get().outer;
            },
            else => null,
        };
        while (cur) |o| {
            if (o == .Null or o == .Unit) break;
            switch (try getFieldInner(self, allocator, &o, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                .ok => |v| if (v != .Unit) return ok(v),
                // Only the dispatch-miss sentinel is a walkable miss; a
                // throw from an accessor that RAN (SubList.size's
                // ConcurrentModificationException inside an inner-class
                // method) propagates.
                .err => |e| {
                    if (e == .Unimplemented) {
                        freeFieldMiss(allocator, e);
                    } else {
                        return errRes(e);
                    }
                },
            }
            cur = switch (o) {
                .Instance => |i| blk: {
                    const g = i.borrow();
                    defer g.deinit();
                    break :blk g.get().outer;
                },
                else => null,
            };
        }
    }
    // Bare member of the receiver's class — or any lexically-enclosing
    // class's — companion. A nested `Builder` referencing `Default` (a member
    // of the enclosing class's companion) reaches it by walking the enclosing
    // chain. Skipped by the member probe (companions are candidates).
    if (!member_probe and receiver.* == .Instance) {
        var cls_name = className(receiver.Instance);
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const comp_name: ?[]const u8 = blk: {
                const g = self.module.borrow();
                defer g.deinit();
                break :blk g.get().registry.companion_singletons.get(cls_name);
            };
            if (comp_name) |cn| {
                const comp: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                    .ok => |maybe| maybe,
                    .err => |e| return errRes(e),
                };
                if (comp) |c| {
                    const same = c == .Instance and ObjRef(InstanceData).ptrEq(c.Instance, receiver.Instance);
                    if (!same) {
                        switch (try getFieldInner(self, allocator, &c, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                            .ok => |v| return ok(v),
                            .err => |e| freeFieldMiss(allocator, e),
                        }
                    }
                }
            }
            const enc: ?[]const u8 = blk: {
                const g = self.module.borrow();
                defer g.deinit();
                break :blk g.get().registry.enclosing_class.get(cls_name);
            };
            cls_name = enc orelse break;
        }
    }
    // Native property getter on a host-synthesised instance, as a last
    // resort. `typeFqn()` is `<instance>` for any `Instance`, so the
    // stdlib property probe above never keys on the instance's class. A
    // host-synthesised class (e.g. the native `KlioChannel`) exposes
    // properties like `isClosedForSend` through a zero-arg installed
    // binding `<classFqn>.<name>`; read it as a getter once fields,
    // delegation, companion, and enclosing lookups have all declined.
    // Restricted to host synth classes so a user/stdlib property that
    // genuinely does not resolve still reports the miss.
    if (receiver.* == .Instance and !probe_is_toplevel_fn and instanceIsHostSynth(receiver.Instance)) {
        const cls_fqn = classFqnOf(receiver.Instance);
        if (cls_fqn.len != 0) {
            const probe = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name });
            defer allocator.free(probe);
            if (lookupIntrinsic(self, probe)) |func| {
                const args = [_]Value{receiver.*};
                return dispatchIntrinsic(self, allocator, probe, func, &args);
            }
        }
    }
    // `@Serializer(forClass = C::class)` marks a declaration the kotlinx
    // plugin fills in; `descriptor` is one of the properties it generates.
    if (try host_call_member.serializerForClassTarget(self, allocator, receiver)) |ser| {
        defer ser.release(allocator);
        const forwarded = try getFieldInner(self, allocator, &ser, name, suppress_cc_redirect, member_probe, suppress_ext);
        switch (forwarded) {
            .ok => return forwarded,
            .err => |e| freeFieldMiss(allocator, e),
        }
    }
    const tf = try allocator.dupe(u8, receiverLabel(receiver));
    if (ir.eval.errTraceOn())
        std.debug.print("[getfield-miss] name={s} recv={s}\n", .{ name, tf });
    ir.eval.dumpFrameChainForDiag();
    const msg = try std.fmt.allocPrint(allocator, "Vm::get_field `{s}` on `{s}`", .{ name, tf });
    allocator.free(tf);
    return errRes(.{ .Unimplemented = msg });
}


/// The receiver's class fqn for diagnostics — an instance names its
/// declaring class instead of the opaque `<instance>` tag.
fn receiverLabel(receiver: *const Value) []const u8 {
    if (receiver.* == .Instance) {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        return cg.get().fqn;
    }
    return receiver.typeFqn();
}

/// Companion forwarding + nested-class/singleton resolution on a
/// `Value::Class` receiver (the early companion path of `get_field`).
/// Resolve `name` from `class_name`'s own companion object — the companion
/// singleton itself for a `Foo.Companion` access, else a companion
/// `const`/`val`/getter member. Returns null when the class has no companion or
/// the companion has no such member (so a caller can keep walking the class
/// hierarchy); `.err` on an init failure.
fn companionMemberOfClass(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) Allocator.Error!?EvalResult {
    const cn: []const u8 = blk: {
        const g = self.module.borrow();
        defer g.deinit();
        break :blk g.get().registry.companion_singletons.get(class_name) orelse return null;
    };
    // `Counter.Factory` — the companion name resolves to the singleton itself.
    const suffix = try std.fmt.allocPrint(allocator, "$Companion${s}", .{name});
    defer allocator.free(suffix);
    if (std.mem.endsWith(u8, cn, suffix)) {
        switch (try host_globals.ensureObjectSingleton(self, cn)) {
            .ok => |maybe| if (maybe) |s| return ok(s),
            .err => |e| return errRes(e),
        }
    }
    const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
        .ok => |maybe| maybe,
        .err => |e| return errRes(e),
    };
    if (singleton) |s| {
        if (s == .Instance) {
            const field_v: ?Value = blk: {
                const g = s.Instance.borrow();
                defer g.deinit();
                break :blk g.get().get(name);
            };
            if (field_v) |v| return ok(v);
            // No plain backing field — the companion member may be a
            // `val` with a custom getter.
            const comp_cls = className(s.Instance);
            const getter: ?FuncId = blk: {
                const pg = self.prog.borrow();
                defer pg.deinit();
                break :blk lookupPairFunc(pg.get().instance_prop_getters, comp_cls, name);
            };
            if (getter) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() < mptr.funcCount()) {
                    return try evalGetterTagged(self, allocator, fid, s, "site1752");
                }
            }
        }
    }
    return null;
}

fn classReceiverField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const cls_name = blk: {
        const g = receiver.Class.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    // Companion member — the class's own companion first, then inherited ones
    // up the superclass chain: `Sub.MinId` binds `Base.Companion.MinId` when
    // `MinId` is a `const`/`val` on the superclass's companion.
    {
        var cur: ?[]const u8 = cls_name;
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            if (try companionMemberOfClass(self, allocator, cn, name)) |r| return r;
            cur = firstSupertype(self, cn);
        }
    }
    // A nested class registered under its enclosing-qualified FQN
    // (`Outer.Nested`): the exact declaration resolves before the
    // lifted-simple-name probes below. Those keys are ambiguous when two
    // packages declare same-named nested members (gapbuffer's vs
    // linkbuffer's `Operation.Ups` both lift as `Operation$Ups`), and the
    // name-keyed singleton gate would construct whichever twin registered
    // the name — so a nested object resolves its singleton BY CLASS ID.
    {
        const cls_fqn = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        if (cls_fqn.len != 0) {
            const nested_fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ cls_fqn, name });
            defer allocator.free(nested_fqn);
            const nested: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(nested_fqn)) |def| break :blk def.clone();
                break :blk null;
            };
            if (nested) |def| {
                const obj_name: ?[]const u8 = blk: {
                    const dg = def.borrow();
                    defer dg.deinit();
                    if (dg.get().is_object) break :blk dg.get().name;
                    break :blk null;
                };
                if (obj_name) |n| {
                    const nested_cid: ?ir.ClassId = blk: {
                        const mg = self.module.borrow();
                        defer mg.deinit();
                        break :blk mg.get().classIdByFqn(nested_fqn);
                    };
                    const res = if (nested_cid) |cid|
                        try host_globals.ensureObjectSingletonById(self, cid)
                    else
                        try host_globals.ensureObjectSingleton(self, n);
                    switch (res) {
                        .ok => |maybe| if (maybe) |v| {
                            if (v == .Instance) {
                                def.deinit();
                                return ok(v);
                            }
                        },
                        .err => |e| {
                            def.deinit();
                            return errRes(e);
                        },
                    }
                }
                return ok(.{ .Class = def });
            }
        }
    }
    // A nested object lifted as `Outer$Name`: resolve the mangled
    // singleton (then class) for a qualified `Outer.Name` access. First
    // access constructs the singleton through the gate.
    const mangled = try std.fmt.allocPrint(allocator, "{s}${s}", .{ cls_name, name });
    defer allocator.free(mangled);
    switch (try host_globals.ensureObjectSingleton(self, mangled)) {
        .ok => |maybe| if (maybe) |v| {
            if (v == .Instance) return ok(v);
        },
        .err => |e| return errRes(e),
    }
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(mangled)) |def| return ok(.{ .Class = def });
    }
    // Nested singleton object (lifted under its simple name) wins over
    // the class.
    switch (try host_globals.ensureObjectSingleton(self, name)) {
        .ok => |maybe| if (maybe) |v| {
            if (v == .Instance) return ok(v);
        },
        .err => |e| return errRes(e),
    }
    {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(name)) |v| {
            if (v == .Instance) return ok(v);
        }
    }
    // Nested-class access on a class receiver.
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| return ok(.{ .Class = def });
    }
    return null;
}

/// The simple name of the lexically-enclosing class of a nested-class
/// instance, derived from its FQN (`a.b.Outer.Inner` -> the class whose
/// FQN is `a.b.Outer`, returning `Outer`). Null when the receiver's FQN
/// has no parent class (a top-level class, whose parent segment is a
/// package). The FQN nesting is unambiguous where the simple-name
/// `enclosing_class` map collides for nested classes that share a simple
/// name across different enclosing classes.
fn enclosingSimpleFromFqn(self: *VmHost, inst: ObjRef(InstanceData)) ?[]const u8 {
    const fqn: []const u8 = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const last_dot = std.mem.lastIndexOfScalar(u8, fqn, '.') orelse return null;
    const parent_fqn = fqn[0..last_dot];
    const parent_simple = if (std.mem.lastIndexOfScalar(u8, parent_fqn, '.')) |d| parent_fqn[d + 1 ..] else parent_fqn;
    // Confirm the parent FQN names an actual class (not a package): the
    // class table is keyed by simple name, so verify the matching entry's
    // FQN equals the parent FQN before treating it as the enclosing class.
    const cg = self.classes.borrow();
    defer cg.deinit();
    const def = cg.get().get(parent_simple) orelse return null;
    const dg = def.borrow();
    defer dg.deinit();
    if (std.mem.eql(u8, dg.get().fqn, parent_fqn)) return parent_simple;
    return null;
}

/// Reflection-style accessors on a `Value::Class` value (`simpleName`,
/// `isData`, `members`, `supertypes`, `sealedSubclasses`, …).
/// The companion-object singleton instance for class `cls_simple`, or
/// null when the class has no companion. Used to seed a companion
/// extension property's getter `this`.
/// The companion for a class DEF: its fqn's dotted suffixes longest-first
/// (`a.b.Outer.C` -> `b.Outer.C`, `Outer.C`, `C`) so a nested class with a
/// same-named cousin in another outer finds its own companion.
fn companionInstanceForDef(self: *VmHost, fqn: []const u8, simple: []const u8) Allocator.Error!?Value {
    var start: usize = 0;
    while (true) {
        const cand = fqn[start..];
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cand);
        };
        if (comp_name) |cn| {
            return switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| maybe,
                .err => null,
            };
        }
        const dot = std.mem.indexOfScalarPos(u8, fqn, start, '.') orelse break;
        start = dot + 1;
        // Never the bare simple name: that key belongs to a top-level
        // class, and a nested class's own (mangled) name resolves below.
        if (std.mem.indexOfScalarPos(u8, fqn, start, '.') == null) break;
    }
    return companionInstanceForClass(self, simple);
}

fn companionInstanceForClass(self: *VmHost, cls_simple: []const u8) Allocator.Error!?Value {
    const comp_name: ?[]const u8 = blk: {
        const g = self.module.borrow();
        defer g.deinit();
        break :blk g.get().registry.companion_singletons.get(cls_simple);
    };
    const cn = comp_name orelse return null;
    return switch (try host_globals.ensureObjectSingleton(self, cn)) {
        .ok => |maybe| maybe,
        .err => null,
    };
}

fn classReflective(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    const g = cls.borrow();
    defer g.deinit();
    const cd = g.get();
    // `$companion`: the class's companion instance whatever it is named
    // (`companion object Named`), initialized on read — the lookup the
    // serialization runtime's KClass -> generated serializer path needs.
    if (std.mem.eql(u8, name, "$companion")) {
        // A nested class registers under its lifted name and its
        // enclosing-chain-qualified name; the bare simple name belongs to
        // a top-level class and must never answer for a nested one
        // (`Tst$B` without a companion is not `pb.B`).
        if (try companionInstanceForDef(self, cd.fqn, cd.name)) |v| return ok(v);
        if (try companionInstanceForClass(self, cd.name)) |v| return ok(v);
        return ok(.Null);
    }
    // An anonymous object's class has no name: both reflective names
    // are null, matching kotlinc.
    if (std.mem.eql(u8, name, "simpleName")) {
        if (cd.is_anonymous) return ok(.Null);
        return ok(.{ .String = try runtime.strInit(allocator, cd.name) });
    }
    if (std.mem.eql(u8, name, "qualifiedName")) {
        if (cd.is_anonymous) return ok(.Null);
        return ok(.{ .String = try runtime.strInit(allocator, cd.fqn) });
    }
    if (std.mem.eql(u8, name, "isData")) return ok(.{ .Bool = cd.is_data });
    if (std.mem.eql(u8, name, "isOpen")) return ok(.{ .Bool = cd.is_open });
    if (std.mem.eql(u8, name, "isAbstract")) return ok(.{ .Bool = cd.is_abstract });
    if (std.mem.eql(u8, name, "isSealed")) return ok(.{ .Bool = cd.is_sealed });
    if (std.mem.eql(u8, name, "isFinal")) return ok(.{ .Bool = !cd.is_open and !cd.is_abstract });
    if (std.mem.eql(u8, name, "isCompanion")) {
        const mg = self.module.borrow();
        defer mg.deinit();
        var it = mg.get().registry.companion_singletons.valueIterator();
        var found = false;
        while (it.next()) |v| {
            if (std.mem.eql(u8, v.*, cd.name)) {
                found = true;
                break;
            }
        }
        return ok(.{ .Bool = found });
    }
    if (std.mem.eql(u8, name, "isInner")) return ok(.{ .Bool = cd.is_inner });
    if (std.mem.eql(u8, name, "isInterface")) return ok(.{ .Bool = cd.is_interface });
    if (std.mem.eql(u8, name, "isFun")) return ok(.{ .Bool = cd.is_fun_interface });
    if (std.mem.eql(u8, name, "objectInstance")) {
        // Reading `objectInstance` initializes the object, matching the
        // JVM (the read reaches the INSTANCE static field through class
        // initialization).
        if (cd.is_object) {
            switch (try host_globals.ensureObjectSingleton(self, cd.name)) {
                .ok => |maybe| if (maybe) |v| return ok(v),
                .err => |e| return errRes(e),
            }
        }
        return ok(.Null);
    }
    if (matchAny(name, &.{ "members", "declaredMembers", "functions", "declaredFunctions", "memberFunctions", "memberProperties", "declaredMemberProperties" })) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        {
            const mg = self.module.borrow();
            defer mg.deinit();
            for (mg.get().classes.items) |c| {
                if (!std.mem.eql(u8, c.name, cd.name)) continue;
                for (c.methods) |fid| {
                    if (mg.get().funcById(fid)) |f| {
                        try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, f.name) } });
                    }
                }
                break;
            }
        }
        for (cd.primary_params) |p| {
            if (p.property != null) {
                try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, p.name) } });
            }
        }
        for (cd.body_properties) |p| {
            try items.append(allocator, .{ .PropertyRef = .{ .name = try runtime.strInit(allocator, p.name) } });
        }
        return ok(try frozenList(allocator, items, false));
    }
    if (std.mem.eql(u8, name, "supertypes")) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        for (cd.supertype_names) |n| {
            const resolved: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(n);
            };
            if (resolved) |c| {
                try items.append(allocator, .{ .Class = c });
            } else {
                try items.append(allocator, .{ .String = try runtime.strInit(allocator, n) });
            }
        }
        return ok(try frozenList(allocator, items, false));
    }
    if (std.mem.eql(u8, name, "sealedSubclasses")) {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(allocator);
        const cg = self.classes.borrow();
        defer cg.deinit();
        var it = cg.get().valueIterator();
        while (it.next()) |c| {
            const sg = c.borrow();
            defer sg.deinit();
            var matches = false;
            for (sg.get().supertype_names) |sn| {
                if (std.mem.eql(u8, sn, cd.name)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            // The class table keys a lifted nested class under more than one
            // name, so the same definition can be reached twice; report each
            // subclass once.
            var seen = false;
            for (items.items) |prev| {
                const pg = prev.Class.borrow();
                defer pg.deinit();
                if (std.mem.eql(u8, pg.get().fqn, sg.get().fqn)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try items.append(allocator, .{ .Class = c.* });
        }
        return ok(try frozenList(allocator, items, false));
    }
    return null;
}

/// Resolve a top-level / supertype / `Type.Companion` / `Any` extension
/// property `FuncId` for `(recv_simple, name)`. Mirrors the chained
/// `.or_else` probe in `get_field`.
fn resolveExtensionProp(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    const fid = try resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, false) orelse return null;
    if (try memberExtOutOfScope(self, allocator, receiver, fid)) return null;
    return fid;
}

/// A MEMBER extension property (`class C { val R.p get() = … }`) is in scope
/// only while an implicit receiver of its owner class is. For a BUILTIN
/// receiver that already answers the name itself, applying an out-of-scope
/// member extension shadows the member — which Kotlin never does. Upstream
/// kotlinx-serialization's `MapEntrySerializer` declares
/// `override val Map.Entry<K, V>.value get() = this.value`; without this guard
/// every `entry.value` read anywhere binds that getter, and the getter's own
/// `this.value` re-enters it without bound.
fn memberExtOutOfScope(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId) Allocator.Error!bool {
    switch (receiver.*) {
        .Instance, .Class => return false,
        else => {},
    }
    const mptr: *const Module = self.module.asPtr();
    const owner = mptr.registry.member_ext_owner_class.get(fid) orelse return false;
    return (try host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner)) == null;
}

/// Whether a class-value receiver's resolved extension property was
/// registered under the COMPANION key (`X.Companion`). Only that registration
/// runs its getter with the companion instance as `this`; a `KClass`/`Any`
/// keyed extension keeps the class value itself.
fn classExtPropUsesCompanion(self: *VmHost, allocator: Allocator, recv_simple: []const u8, name: []const u8) Allocator.Error!bool {
    const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
    defer allocator.free(comp_key);
    const pg = self.prog.borrow();
    defer pg.deinit();
    return lookupPairFunc(pg.get().extension_props, comp_key, name) != null;
}

/// Resolve and evaluate a (member-)extension property getter for `receiver`,
/// or a delegated extension property. Mirrors the extension arm of the field
/// ladder (`resolveExtensionProp` + owner-`this` seeding) but is entered
/// directly from the `$extread$` marker, so it never consults the
/// stored-field / member-getter-shadow arms. Null when no extension applies.
fn extensionPropRead(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        .Class => |c| blk: {
            const g = c.borrow();
            defer g.deinit();
            break :blk lastSegment(g.get().name);
        },
        else => lastSegment(receiver.typeFqn()),
    };
    if (try resolveExtensionProp(self, allocator, receiver, recv_simple, name)) |fid| {
        const mptr: *const Module = self.module.asPtr();
        if (fid.int() >= mptr.funcCount()) return null;
        // A companion extension's getter `this` is the class's companion
        // instance; route the class value to it. A KClass/Any keyed
        // extension keeps the class value itself.
        var getter_recv = receiver.*;
        if (receiver.* == .Class and try classExtPropUsesCompanion(self, allocator, recv_simple, name)) {
            if (try companionInstanceForClass(self, recv_simple)) |comp| getter_recv = comp;
        }
        // A member-extension property's getter body has its declaring class's
        // `this` in lexical scope; seed the getter frame with the owner
        // instance from the enclosing chain.
        var pushed_owner = false;
        if (mptr.registry.member_ext_owner_class.get(fid)) |owner| {
            if (try host_call_member.memberExtOwnerInstance(self, allocator, &getter_recv, owner)) |inst| {
                ir.eval.pushEnclosing(&inst);
                pushed_owner = true;
            }
        }
        const r = try evalGetterTagged(self, allocator, fid, getter_recv, "ext-prop");
        if (pushed_owner) ir.eval.popEnclosing();
        return r;
    }
    if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, name)) |hit| {
        const d = try extPropDelegateInstance(self, allocator, hit.key, name, hit.fid);
        const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
        return try self.callMember(allocator, &d, "getValue", &.{ receiver.*, prop_ref });
    }
    return null;
}

/// The setter half of `resolveExtensionProp`: walks the same
/// receiver/supertype/companion/`Any` candidate set against the registered
/// extension-property *setters*, so `var T.x set(value)` resolves for a
/// subtype receiver (`var ApplicationCall.receiveType` on a
/// `RoutingPipelineCall`) — not just the exact declared receiver type.
fn resolveExtensionPropSetter(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    return resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, true);
}

/// Whether `name` is settable on `receiver` through an extension-property
/// setter (`var T.name set(value)`) declared on the receiver's type or any
/// supertype. Used by the bare-name write path to route an implicit-`this`
/// assignment to the extension setter instead of a top-level binding.
pub fn hostHasExtPropSetter(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) bool {
    const recv_simple: []const u8 = switch (receiver.*) {
        .Instance => |i| className(i),
        else => lastSegment(receiver.typeFqn()),
    };
    const fid = resolveExtensionPropSetter(self, allocator, receiver, recv_simple, name) catch return false;
    return fid != null;
}

const ExtDelegateHit = struct { key: []const u8, fid: FuncId };

/// Resolve a delegated extension property (`val R.x by expr`) for this
/// receiver: exact declared receiver, then the instance supertype chain.
/// Returns the DECLARING registry key alongside the thunk so the cached
/// delegate object is shared across subtype receivers.
fn resolveExtPropDelegate(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
) Allocator.Error!?ExtDelegateHit {
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().extension_prop_delegates.count() == 0) return null;
        if (lookupPairFunc(pg.get().extension_prop_delegates, recv_simple, name)) |fid| {
            return .{ .key = recv_simple, .fid = fid };
        }
    }
    if (receiver.* == .Instance) {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            for (cg.get().supertype_names) |s| try queue.append(allocator, s);
        }
        var head: usize = 0;
        while (head < queue.items.len) {
            const sup = queue.items[head];
            head += 1;
            if (containsStr(seen.items, sup)) continue;
            try seen.append(allocator, sup);
            {
                const pg = self.prog.borrow();
                defer pg.deinit();
                if (lookupPairFunc(pg.get().extension_prop_delegates, sup, name)) |fid| {
                    return .{ .key = sup, .fid = fid };
                }
            }
            const def: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(sup);
            };
            if (def) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |s| try queue.append(allocator, s);
            }
        }
    }
    return null;
}

/// The materialised delegate object for a delegated extension property:
/// run the delegate thunk once and cache the result as a hidden global
/// keyed by the declaring receiver + property name.
fn extPropDelegateInstance(
    self: *VmHost,
    allocator: Allocator,
    key: []const u8,
    name: []const u8,
    fid: FuncId,
) Allocator.Error!Value {
    var kb: [256]u8 = undefined;
    const cache_name = std.fmt.bufPrint(&kb, "__ext_delegate\x1f{s}\x1f{s}", .{ key, name }) catch
        return runThunkValue(self, allocator, fid);
    {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(cache_name)) |v| return v;
    }
    const v = try runThunkValue(self, allocator, fid);
    const owned_name = try allocator.dupe(u8, cache_name);
    const g = self.globals.borrowMut();
    defer g.deinit();
    g.get().define(owned_name, v) catch {};
    return v;
}

fn runThunkValue(self: *VmHost, allocator: Allocator, fid: FuncId) Allocator.Error!Value {
    const mptr: *const Module = self.module.asPtr();
    const r = try self.callFunc(allocator, mptr, fid, &.{});
    return switch (r) {
        .ok => |v| v,
        .err => Value.Null,
    };
}

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for every class on the lexical receiver tower — a PRIVATE member-ext
/// property (`private val Placeable.mainAxisSize` in each lazy item type)
/// shares its (receiver, name) pair across owners, and only the
/// declaration whose owner is in scope is the one kotlinc bound.
/// One `(owning class, receiver key, property name)` verdict. The registry
/// and the class graph are both fixed once the program is loaded, so a class
/// that does not own `name` for `recv_key` never starts owning it — the
/// negative answer is as cacheable as the positive one.
const OwnerKeyedSlot = struct { key: u64 = 0, gen: u32 = 0, fid: u32 = NO_FID, hit: bool = false };
const NO_FID: u32 = std.math.maxInt(u32);
threadlocal var owner_keyed_memo: [1024]OwnerKeyedSlot = @splat(.{});
threadlocal var owner_keyed_memo_set: [1024]OwnerKeyedSlot = @splat(.{});

fn ownerKeyedSlotKey(cls_ident: usize, recv_key: []const u8, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(std.mem.asBytes(&cls_ident));
    h.update(recv_key);
    h.update(&[_]u8{0});
    h.update(name);
    const v = h.final();
    return if (v == 0) 1 else v;
}

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for one class on the lexical receiver tower.
fn ownerKeyedForClass(cls: ObjRef(runtime.ClassDef), map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    // Probe the WHOLE resolved parent chain, not one supertype level: a
    // coroutine instance's class is several classes below JobSupport, and a
    // member extension declared there is in scope for every subclass body.
    var kb: [512]u8 = undefined;
    var cur: ObjRef(runtime.ClassDef) = cls;
    var depth: usize = 0;
    while (depth < runtime.ClassDef.MAX_WALK) : (depth += 1) {
        const cg = cur.borrow();
        const cd = cg.get();
        if (ownerKeyedProbeOne(cd.fqn, kb[0..], map, recv_key, name)) |fid| {
            cg.deinit();
            return fid;
        }
        if (ownerKeyedProbeOne(cd.name, kb[0..], map, recv_key, name)) |fid| {
            cg.deinit();
            return fid;
        }
        for (cd.supertype_names) |sn| {
            if (ownerKeyedProbeOne(sn, kb[0..], map, recv_key, name)) |fid| {
                cg.deinit();
                return fid;
            }
        }
        const parent = cd.parent orelse {
            cg.deinit();
            return null;
        };
        cg.deinit();
        cur = parent;
    }
    return null;
}

fn ownerKeyedProbeOne(owner: []const u8, kb: []u8, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    if (std.fmt.bufPrint(kb, "{s}\x00{s}", .{ owner, recv_key })) |okey| {
        return lookupPairFunc(map, okey, name);
    } else |_| {
        // A key longer than the inline buffer is vanishingly rare but must
        // still resolve — the probe decides which declaration binds.
        const heap = std.heap.page_allocator;
        const okey = std.fmt.allocPrint(heap, "{s}\x00{s}", .{ owner, recv_key }) catch return null;
        defer heap.free(okey);
        return lookupPairFunc(map, okey, name);
    }
}

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for every class on the lexical receiver tower — a PRIVATE member-ext
/// property (`private val Placeable.mainAxisSize` in each lazy item type)
/// shares its (receiver, name) pair across owners, and only the
/// declaration whose owner is in scope is the one kotlinc bound.
fn ownerKeyedExtProp(comptime setters: bool, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    const memo: *[1024]OwnerKeyedSlot = if (setters) &owner_keyed_memo_set else &owner_keyed_memo;
    var it = ir.eval.frameThisChainIter();
    while (it.next()) |v| {
        if (v != .Instance) continue;
        const cls = blk: {
            const g = v.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        const k = ownerKeyedSlotKey(cls.identity(), recv_key, name);
        const slot = &memo[(k >> 7) % memo.len];
        const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
        if (slot.key == k and slot.gen == gen) {
            if (!slot.hit) continue;
            return FuncId.from(slot.fid);
        }
        const found = ownerKeyedForClass(cls, map, recv_key, name);
        slot.* = .{ .key = k, .gen = gen, .hit = found != null, .fid = if (found) |f| f.int() else NO_FID };
        if (found) |fid| return fid;
    }
    // The bare member-extension call arm passes its DISPATCH OWNER by
    // pushing it on the enclosing chain, never as a frame `this` — inside
    // `MeasureScope.measure` reached via `with(node) { measure(...) }`,
    // the node (which owns `private val Density.targetConstraints`) is
    // only there. Probe those receivers with the same memo.
    var eit = ir.eval.enclosingChainIter();
    while (eit.next()) |v| {
        if (v != .Instance) continue;
        const cls = blk: {
            const g = v.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class;
        };
        const k = ownerKeyedSlotKey(cls.identity(), recv_key, name);
        const slot = &memo[(k >> 7) % memo.len];
        const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
        if (slot.key == k and slot.gen == gen) {
            if (!slot.hit) continue;
            return FuncId.from(slot.fid);
        }
        const found = ownerKeyedForClass(cls, map, recv_key, name);
        slot.* = .{ .key = k, .gen = gen, .hit = found != null, .fid = if (found) |f| f.int() else NO_FID };
        if (found) |fid| return fid;
    }
    return null;
}

/// An IMPORTED companion/member extension property (`import
/// kotlin.time.Duration.Companion.seconds`) is in scope in its importing
/// file without the owner on the receiver tower. Probe the owner-keyed
/// entries named by the executing frame's file imports: the import's fqn
/// minus its leaf IS the declaring owner the registration keyed.
fn importOwnedExtProp(self: *VmHost, map: anytype, recv_key: []const u8, name: []const u8) ?FuncId {
    const f = ir.eval.currentFrameFunc() orelse {
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] no frame func\n", .{});
        }
        return null;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    const file = (module.decl_span.get(f.id.int()) orelse {
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] no decl_span for {s}#{d}\n", .{ f.name, f.id.int() });
        }
        return null;
    }).file;
    if (missTraceEnvCached()) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[imp-ext] fn={s} file={any} paths={d}\n", .{ f.name, file, module.importAliasPathsIn(file, name).len });
    }
    for (module.importAliasPathsIn(file, name)) |path| {
        if (path.fqn.len <= name.len + 1) continue;
        const owner = path.fqn[0 .. path.fqn.len - name.len - 1];
        var kb: [512]u8 = undefined;
        if (ownerKeyedProbeOne(owner, kb[0..], map, recv_key, name)) |fid| return fid;
        if (ownerKeyedProbeOne(owner, kb[0..], map, "Any", name)) |fid| return fid;
    }
    return null;
}

/// Whether the exec-arm fast serve for the builtin `indices`/`lastIndex`
/// extension properties is sound for this program: false as soon as ANY
/// loaded declaration outside the known stdlib packages defines an
/// extension property with either name — Kotlin scoping can then pick
/// the user's shadow, which a receiver-shape serve cannot see. Computed
/// once per dispatch-cache generation over the extension-prop tables
/// (name-global, so it over-declines rather than ever mis-serving).
var index_props_verdict = std.atomic.Value(u64).init(0);
pub fn builtinIndexPropsServable(self: *VmHost) bool {
    const gen: u64 = host_call_member.dispatch_cache_gen.load(.monotonic);
    const packed_v = index_props_verdict.load(.acquire);
    if (packed_v >> 32 == gen) return (packed_v & 1) == 1;
    var shadowed = false;
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        const p = pg.get();
        if (p.owner_keyed_ext_names.contains("indices") or p.owner_keyed_ext_names.contains("lastIndex") or
            p.nullable_ext_props.contains("indices") or p.nullable_ext_props.contains("lastIndex"))
        {
            shadowed = true;
        } else {
            const mptr: *const Module = self.module.asPtr();
            var it = p.extension_props.iterator();
            while (it.next()) |e| {
                const b = e.key_ptr.b;
                if (!std.mem.eql(u8, b, "indices") and !std.mem.eql(u8, b, "lastIndex")) continue;
                const f = mptr.funcById(e.value_ptr.*) orelse {
                    shadowed = true;
                    break;
                };
                if (!stdlib.isKnownPackage(f.package)) {
                    shadowed = true;
                    break;
                }
            }
        }
    }
    index_props_verdict.store((gen << 32) | @as(u64, if (shadowed) 0 else 1), .release);
    return !shadowed;
}

fn resolveExtensionPropImpl(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    recv_simple: []const u8,
    name: []const u8,
    comptime setters: bool,
) Allocator.Error!?FuncId {
    const Pick = struct {
        fn map(p: anytype) @TypeOf(if (setters) p.extension_prop_setters else p.extension_props) {
            return if (setters) p.extension_prop_setters else p.extension_props;
        }
    };
    // A class-value receiver (`X.name`) matches only a companion extension
    // (`val X.Companion.name`, keyed `X.Companion`), never a plain type
    // extension `val X.name` (which applies to instances of `X`). Falling back
    // to the bare `X` key would invoke an instance extension's getter with the
    // class/companion as `this` and recurse.
    if (receiver.* == .Class) {
        const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{recv_simple});
        defer allocator.free(comp_key);
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        // A PRIVATE member extension on the companion registers ONLY under
        // the owner-qualified key, so the plain pair above cannot see it:
        // `class H { private val Float.Companion.p get() = … }` is reached
        // from `Float.p` through these two.
        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
        // A class value IS a `KClass`: a `val KClass<*>.x` extension applies
        // to it directly (`qualifiedOrSimpleName` behind `KClass.cast`'s
        // error message). The getter runs with the class value as `this`,
        // never the companion.
        if (lookupPairFunc(Pick.map(pg.get().*), "KClass", name)) |fid| return fid;
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
        return null;
    }
    // A null receiver dispatches an extension property declared on a NULLABLE
    // receiver type (`val RowColumnParentData?.weight get() = this?.weight ?:
    // 0f`) — kotlinc resolves that statically, so `parentData.weight` with a
    // null parentData runs the getter, never a field read. Only an
    // unambiguous single declaration binds by bare name.
    if (receiver.* == .Null and !setters) {
        const pg = self.prog.borrow();
        defer pg.deinit();
        // The executing frame's package first: same-name nullable
        // extension properties in different packages blank the bare-name
        // entry, but internal visibility means the reading code sits in
        // the declaring package.
        if (ir.eval.currentFramePackage()) |pkg| {
            var buf: [256]u8 = undefined;
            if (pkg.len + 1 + name.len <= buf.len) {
                const key = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ pkg, name }) catch null;
                if (key) |k| {
                    if (pg.get().nullable_ext_props.get(k)) |maybe| {
                        if (maybe) |fid| return fid;
                    }
                }
            }
        }
        if (pg.get().nullable_ext_props.get(name)) |maybe| {
            if (maybe) |fid| return fid;
        }
        return null;
    }
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        // A companion-object receiver arrives under its MANGLED runtime class
        // name (`Target$Companion$Companion`); extension properties on a
        // companion are registered under the SOURCE-WRITTEN receiver type
        // (`Target.Companion`). Every lookup below has to try both, or a
        // companion extension is unreachable from a companion instance.
        var comp_alias_buf: [256]u8 = undefined;
        const comp_alias: ?[]const u8 = blk: {
            const at = std.mem.indexOf(u8, recv_simple, "$Companion") orelse break :blk null;
            if (at == 0) break :blk null;
            break :blk std.fmt.bufPrint(&comp_alias_buf, "{s}.Companion", .{recv_simple[0..at]}) catch null;
        };

        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            if (importOwnedExtProp(self, Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
            // A PRIVATE member extension registers ONLY under the
            // owner-qualified key, so the companion alias must be tried here
            // too — this is the arm that resolves
            // `class H { private val T.Companion.p get() = … }`.
            if (comp_alias) |alias| {
                if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), alias, name)) |fid| return fid;
                if (importOwnedExtProp(self, Pick.map(pg.get().*), alias, name)) |fid| return fid;
            }
        }
        if (missTraceEnvCached()) |w| {
            if (std.mem.eql(u8, w, name))
                std.debug.print("[extprop-walk] try=({s},{s})\n", .{ recv_simple, name });
        }
        if (lookupPairFunc(Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
        if (comp_alias) |alias| {
            if (lookupPairFunc(Pick.map(pg.get().*), alias, name)) |fid| return fid;
        }
        // A file-mangled class (`KeyInfo$f352`, one of two same-simple-name
        // internal classes) registers its extension properties under the
        // SOURCE-WRITTEN receiver name: retry with the base name.
        if (std.mem.indexOf(u8, recv_simple, "$f")) |dol| {
            if (dol > 0 and dol + 2 < recv_simple.len and
                std.ascii.isDigit(recv_simple[dol + 2]))
            {
                if (lookupPairFunc(Pick.map(pg.get().*), recv_simple[0..dol], name)) |fid| return fid;
            }
        }
    }
    // An extension property on a supertype applies to a subtype receiver.
    if (receiver.* == .Instance) {
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            for (cg.get().supertype_names) |s| try queue.append(allocator, s);
        }
        var head: usize = 0;
        while (head < queue.items.len) {
            const sup = queue.items[head];
            head += 1;
            if (containsStr(seen.items, sup)) continue;
            try seen.append(allocator, sup);
            {
                const pg = self.prog.borrow();
                defer pg.deinit();
                if (pg.get().owner_keyed_ext_names.contains(name)) {
                    if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), sup, name)) |fid| return fid;
                }
                if (lookupPairFunc(Pick.map(pg.get().*), sup, name)) |fid| return fid;
            }
            const def: ?ObjRef(ClassDef) = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                break :blk cg.get().get(sup);
            };
            if (def) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().supertype_names) |s| try queue.append(allocator, s);
            }
        }
    }
    // A `Type.Companion` extension property registers under `<outer>.Companion`;
    // a companion-instance receiver (the synthetic `$Companion` class) keys the
    // lookup by its outer class's companion path.
    if (receiver.* == .Instance) {
        const cls = className(receiver.Instance);
        if (std.mem.indexOf(u8, cls, "$Companion")) |i| {
            const outer = cls[0..i];
            const comp_key = try std.fmt.allocPrint(allocator, "{s}.Companion", .{outer});
            defer allocator.free(comp_key);
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (lookupPairFunc(Pick.map(pg.get().*), comp_key, name)) |fid| return fid;
        }
    }
    // An `Any` extension property applies to every receiver — including an
    // owner-gated member extension (`private val Any?.exceptionOrNull` in
    // JobSupport) whose registration recv key is "Any" while the receiver's
    // own head is anything at all; the tower probe above only tried that
    // head.
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (pg.get().owner_keyed_ext_names.contains(name)) {
            if (ownerKeyedExtProp(setters, Pick.map(pg.get().*), "Any", name)) |fid| return fid;
        }
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
    }
    return null;
}

/// Resolve a field on an `Value::Instance` receiver: delegate getValue,
/// custom getter (with override rules), raw slot (lateinit / built-in
/// delegate auto-unwrap), companion/parent walk, outer-chain, enum
/// entries, nested classes, globals.
/// A member of the DECLARING class of the member-extension the innermost frame is
/// executing, read off the instance that made the extension visible.
///
/// `fun Dp.toPx(): Float = value * density` is declared inside `interface Density`:
/// `this` is the `Dp`, and `density` is a member of the enclosing `Density`. That
/// enclosing receiver is in scope for the body and OUTRANKS a top-level name, so
/// both global fallbacks below consult it first. Without this, a `density` reachable
/// as a global -- a lambda's captured parameter, materialised into the global env
/// when the lambda runs as a real closure -- answered the read, and `Dp.toPx` inside
/// `with(density) { size.toPx() }` multiplied by the Density OBJECT instead of its
/// `density: Float`. The probe is member-only, so it cannot recurse back into the
/// global tiers.
fn memberExtOwnerRead(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const f = ir.eval.currentFrameFunc() orelse return null;
    if (f.kind != .member_extension) return null;
    const owner = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.member_ext_owner_class.get(f.id);
    } orelse return null;
    const inst = try vmhost.host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner) orelse return null;
    if (inst == .Instance and receiver.* == .Instance and
        ObjRef(InstanceData).ptrEq(inst.Instance, receiver.Instance)) return null;
    switch (try getMemberField(self, allocator, &inst, name)) {
        .ok => |v| return ok(v),
        .err => |e| {
            if (e == .Unimplemented) {
                freeFieldMiss(allocator, e);
                return null;
            }
            return errRes(e);
        },
    }
}

/// Whether the instance's RUNTIME class chain declares `name` as a
/// `by`-delegated body property. Local classes register at runtime and never
/// reach the module registry's `delegated_body_props`, so the classdef chain
/// is the authority for them.
fn runtimeClassDelegatesProp(inst: anytype, name: []const u8) bool {
    var cur: ?ObjRef(ClassDef) = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var hops: u8 = 0;
    while (cur) |c| : (hops += 1) {
        if (hops > 16) {
            c.deinit();
            return false;
        }
        const g = c.borrow();
        for (g.get().body_properties) |bp| {
            if (bp.delegate != null and std.mem.eql(u8, bp.name, name)) {
                g.deinit();
                c.deinit();
                return true;
            }
        }
        const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
        g.deinit();
        c.deinit();
        cur = next;
    }
    return false;
}

/// Whether (class, prop) is a registered `by`-delegated body property. The
/// registry keys packaged classes by FQN (a bare simple-name alias let a
/// foreign namesake intercept an unrelated class's field), so a simple-name
/// hop also consults the class-index FQN.
fn delegatedPropRegistered(self: *VmHost, cn: []const u8, prop: []const u8) bool {
    const g = self.module.borrow();
    defer g.deinit();
    const mod = g.get();
    if (mod.registry.delegated_body_props.contains(.{ .a = cn, .b = prop })) return true;
    if (mod.classId(cn)) |cid| {
        if (cid.int() < mod.classes.items.len) {
            const fqn = mod.classes.items[cid.int()].fqn;
            if (!std.mem.eql(u8, fqn, cn) and
                mod.registry.delegated_body_props.contains(.{ .a = fqn, .b = prop })) return true;
        }
    }
    return false;
}

fn instanceField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, member_probe: bool) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    const class_name = className(inst);
    // Field-read memo: one probe replaces the delegate walk, the getter
    // BFS, and the stored-slot scan for a (class, name) already resolved
    // once. Both cached facts derive from the static class graph; the
    // stored index re-verifies by name because instances can define
    // extra slots dynamically.
    const cache_fqn = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    // Delegated body property: route through the delegate's `getValue`.
    const delegate_owner: bool = runtimeClassDelegatesProp(inst, name) or blk: {
        // Almost every program declares zero `by`-delegated body properties;
        // skip the per-access supertype walk + scratch allocation entirely then.
        {
            const g = self.module.borrow();
            const none = g.get().registry.delegated_body_props.count() == 0;
            g.deinit();
            if (none) break :blk false;
        }
        // The receiver's OWN class adjudicates by its exact FQN only — a
        // simple-name (or classId-resolved) probe would let a foreign
        // namesake's delegated prop intercept this class's plain field.
        if (blk2: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk2 g.get().registry.delegated_body_props.contains(.{ .a = cache_fqn, .b = name });
        }) break :blk true;
        var cur: ?[]const u8 = firstSupertype(self, class_name);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            if (delegatedPropRegistered(self, cn, name)) break :blk true;
            cur = firstSupertype(self, cn);
        }
        break :blk false;
    };
    if (delegate_owner) {
        const raw: ?Value = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().get(name);
        };
        if (raw) |d| {
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
            return try self.callMember(allocator, &d, "getValue", &.{ receiver.*, prop_ref });
        }
    }
    const recv_fqn = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    // Resolve the custom getter, honoring the most-derived-stored-prop
    // override rule.
    const getter_fid = try resolveInstanceGetter(self, allocator, inst, class_name, recv_fqn, name);
    if (getter_fid) |fid| {
        const mptr: *const Module = self.module.asPtr();
        if (fid.int() >= mptr.funcCount()) {
            const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
            return errRes(.{ .Type = msg });
        }
        fieldReadCachePut(self, inst, cache_fqn, name, .{ .getter = fid.int(), .stored_idx = root.ProgramImage.FieldReadHit.NONE });
        return try evalGetterTagged(self, allocator, fid, receiver.*, "site2500");
    }
    // Most-derived override cell: an initialized `override val/var` keeps
    // its own backing cell under the owner-mangled key (JVM semantics);
    // reads dispatch to the nearest class in the runtime chain that owns
    // one. `super.x` reads the base's plain cell, which the override's
    // store never touches.
    if (blk: {
        const pg = self.module.borrow();
        defer pg.deinit();
        break :blk pg.get().registry.override_cell_props.count() != 0;
    }) {
        var cur2: ?[]const u8 = blk: {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        var hops: u8 = 0;
        while (cur2) |cn2| : (hops += 1) {
            if (hops > 16) break;
            var kb: [256]u8 = undefined;
            const probe = std.fmt.bufPrint(&kb, "{s}\x1f{s}", .{ cn2, name }) catch break;
            const is_cell = blk: {
                const pg = self.module.borrow();
                defer pg.deinit();
                break :blk pg.get().registry.override_cell_props.contains(probe);
            };
            if (is_cell) {
                const g = inst.borrow();
                const owned = g.get().get(probe);
                g.deinit();
                if (owned) |v| return ok(v);
            }
            cur2 = blk: {
                const cg = self.classes.borrow();
                defer cg.deinit();
                const d = cg.get().get(cn2) orelse break :blk null;
                const dg = d.borrow();
                defer dg.deinit();
                const sups = dg.get().supertype_names;
                break :blk if (sups.len != 0) sups[0] else null;
            };
        }
    }
    // Raw instance slot.
    const slot: ?Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const fields = g.get().fields.items;
        for (fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, name)) {
                fieldReadCachePut(self, inst, cache_fqn, name, .{ .getter = root.ProgramImage.FieldReadHit.NONE, .stored_idx = @intCast(fi) });
                break :blk f.value;
            }
        }
        break :blk null;
    };
    if (slot) |v| {
        if (v == .Null) {
            if (storedNullIsLateinit(inst, name)) {
                return try lateinitReadError(allocator, name);
            }
        }
        // Auto-unwrap instance-level built-in delegates.
        if (v == .Delegate) {
            return try unwrapDelegate(self, allocator, v.Delegate, name);
        }
        return ok(v);
    }
    // Companion / parent / interface chain walk for a companion-owned
    // field. The member probe resolves companions and outer instances as
    // the bare-name walk's own candidates instead.
    if (!member_probe) {
        if (try companionParentWalk(self, allocator, inst, name)) |v| return v;
        // Outer-instance chain fallback.
        if (try outerInstanceChain(self, allocator, inst, name)) |v| return v;
        // A nested/companion object resolves a bare name against the
        // enclosing class's superclass companions.
        if (try enclosingCompanionWalk(self, allocator, inst, name)) |v| return v;
    }
    // Enum entry bare-name access.
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        const is_enum = cg.get().is_enum;
        if (is_enum) {
            for (cg.get().enum_entries) |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    const v = e.value;
                    cg.deinit();
                    g.deinit();
                    return ok(v);
                }
            }
            if (std.mem.eql(u8, name, "entries")) {
                var items: std.ArrayList(Value) = .empty;
                errdefer items.deinit(allocator);
                for (cg.get().enum_entries) |e| {
                    e.value.retain();
                    try items.append(allocator, e.value);
                }
                cg.deinit();
                g.deinit();
                return ok(try frozenList(allocator, items, true));
            }
        }
        cg.deinit();
        g.deinit();
    }
    // A member declared by a companion on this receiver's class / supertype /
    // enclosing-class chain is in scope unqualified and must be resolved by the
    // companion walk in `getFieldInner` (which runs after this returns null),
    // not shadowed here by an unrelated global object / class of the same simple
    // name (`Default` from a nested `Builder` is `HexFormat.Companion.Default`,
    // not `kotlin.random.Random.Default`).
    if (!member_probe and try enclosingCompanionDeclares(self, allocator, class_name, name)) {
        return null;
    }
    // Nested-class fallback. An `object` declaration referenced by bare
    // name in value position is its singleton instance, never the bare
    // class value (kotlinc: `val c = EmptyCoroutineContext` binds the
    // object). First access constructs it through the shared gate.
    if (!member_probe) {
        const is_object = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            const def = cg.get().get(name) orelse break :blk false;
            const dg = def.borrow();
            defer dg.deinit();
            break :blk dg.get().is_object;
        };
        if (is_object) {
            switch (try host_globals.ensureObjectSingleton(self, name)) {
                .ok => |maybe| if (maybe) |v| {
                    if (v == .Instance) return ok(v);
                },
                .err => |e| return errRes(e),
            }
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(name)) |def| return ok(.{ .Class = def });
    }
    // Top-level global / module-scoped fallback. An implicit receiver outranks a
    // top-level name, so the executing member-extension's declaring class goes first.
    if (!member_probe) {
        if (try memberExtOwnerRead(self, allocator, receiver, name)) |r| return r;
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(name)) |v| return ok(v);
    }
    return null;
}

/// Whether a companion object on `class_name`'s class / supertype /
/// lexically-enclosing-class chain declares a member named `name`. Keeps
/// `instanceField`'s eager class / global fallback from shadowing an enclosing
/// companion member with an unrelated same-named global classifier.
fn enclosingCompanionDeclares(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) Allocator.Error!bool {
    var cur: ?[]const u8 = class_name;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    while (cur) |cn| {
        cur = null;
        if (containsStr(seen.items, cn)) break;
        try seen.append(allocator, cn);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cn);
        };
        if (comp_name) |comp| {
            switch (try host_globals.objectSingletonForMember(self, comp, name)) {
                .ok => |maybe| if (maybe != null) return true,
                .err => return false,
            }
        }
        if (firstSupertype(self, cn)) |sup| {
            cur = sup;
        } else {
            const g = self.module.borrow();
            defer g.deinit();
            cur = g.get().registry.enclosing_class.get(cn);
        }
    }
    return false;
}

/// Thread-local L1 in front of the shared field-resolution memos: the
/// shared maps live behind the program cell's reader lock, whose atomic
/// state word ping-pongs between cores on every borrow — the same
/// coherence cost the method-cache L1 in `host_call_member` removes.
/// A slot mirrors a shared-map entry; the hit site re-verifies stored
/// slots by name anyway, so a stale slot is at worst a fall-through to
/// the ladder. The generation stamp keeps entries from a finished
/// in-process program (reused cell addresses) from ever hitting,
/// including on still-parked pool worker threads.
const TL_FIELD_CACHE_SIZE = 1024;
const TlFieldReadEntry = struct { class_p: usize = 0, name_p: usize = 0, gen: u32 = 0, state: u8 = 0, miss_ttl: u8 = 0, hit: root.ProgramImage.FieldReadHit = .{ .getter = 0, .stored_idx = 0 } };
threadlocal var tl_field_read_cache: [TL_FIELD_CACHE_SIZE]TlFieldReadEntry = @splat(.{});
const TlFieldWriteEntry = struct { class_p: usize = 0, name_p: usize = 0, gen: u32 = 0, state: u8 = 0, miss_ttl: u8 = 0, hit: root.ProgramImage.FieldWriteHit = .{ .setter = 0, .store_name = "" } };
threadlocal var tl_field_write_cache: [TL_FIELD_CACHE_SIZE]TlFieldWriteEntry = @splat(.{});

inline fn tlFieldSlot(class_p: usize, name_p: usize) usize {
    const h = (@as(u64, @intCast(class_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(name_p));
    return @intCast((h ^ (h >> 17)) & (TL_FIELD_CACHE_SIZE - 1));
}

fn fieldReadCacheGet(self: *VmHost, class_p: usize, name_p: usize) ?root.ProgramImage.FieldReadHit {
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    const e = &tl_field_read_cache[tlFieldSlot(class_p, name_p)];
    if (e.state != 0 and e.class_p == class_p and e.name_p == name_p and e.gen == gen) {
        // state 2: the shared map had no entry at last probe. It is
        // add-only, so re-probe every 64th consult rather than paying
        // the program-cell borrow on every miss forever.
        if (e.state == 2) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return null;
            }
        } else return e.hit;
    }
    const hit: ?root.ProgramImage.FieldReadHit = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().field_read_cache.get(.{ .class_p = class_p, .name_p = name_p });
    };
    if (hit) |h| {
        e.* = .{ .class_p = class_p, .name_p = name_p, .gen = gen, .state = 1, .hit = h };
    } else {
        e.* = .{ .class_p = class_p, .name_p = name_p, .gen = gen, .state = 2, .miss_ttl = 63, .hit = .{ .getter = 0, .stored_idx = 0 } };
    }
    return hit;
}

fn fieldWriteCacheGet(self: *VmHost, class_p: usize, name_p: usize) ?root.ProgramImage.FieldWriteHit {
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    const e = &tl_field_write_cache[tlFieldSlot(class_p, name_p)];
    if (e.state != 0 and e.class_p == class_p and e.name_p == name_p and e.gen == gen) {
        if (e.state == 2) {
            if (e.miss_ttl > 0) {
                e.miss_ttl -= 1;
                return null;
            }
        } else return e.hit;
    }
    const hit: ?root.ProgramImage.FieldWriteHit = blk: {
        const pg = self.prog.borrow();
        defer pg.deinit();
        break :blk pg.get().field_write_cache.get(.{ .class_p = class_p, .name_p = name_p });
    };
    if (hit) |h| {
        e.* = .{ .class_p = class_p, .name_p = name_p, .gen = gen, .state = 1, .hit = h };
    } else {
        e.* = .{ .class_p = class_p, .name_p = name_p, .gen = gen, .state = 2, .miss_ttl = 63, .hit = .{ .setter = 0, .store_name = "" } };
    }
    return hit;
}

/// Insert into the field-read memo, capped so synthesized per-evaluation
/// anonymous classes cannot grow it unboundedly.
fn fieldReadCachePut(self: *VmHost, inst: ObjRef(InstanceData), fqn: []const u8, name: []const u8, hit: root.ProgramImage.FieldReadHit) void {
    if (!ir.eval.dispatchCacheStable()) return;
    // Main-module classes only, exactly like the WRITE memo below: a
    // runtime / anonymous class can be reclaimed mid-program, and a later
    // class cell landing at the same address would alias its identity key.
    // Main-module class cells stay registry-held for the program's life.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().classIdByFqn(fqn) == null) return;
    }
    const class_p = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.identity();
    };
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    // The interned name identity keys the entry: the caller's slice can be
    // side-module or scratch memory, and only the image-interned id is
    // stable (and unique per spelling) for the image's lifetime.
    const name_p = pg.get().memberNameIdentity(name) orelse return;
    if (pg.get().field_read_cache.count() >= 65536) return;
    pg.get().field_read_cache.put(.{ .class_p = class_p, .name_p = name_p }, hit) catch {};
}

/// Insert into the field-WRITE memo. Main-module classes only: a runtime /
/// anonymous class can gain `$set$` overrides after the first write, and its
/// class cell (the identity key) does not outlive the class def.
///
/// `hit.store_name` is re-anchored onto `member_names`: a write reached
/// through a callable reference (`Class::prop`, a delegate's `setValue`)
/// resolves its name from a runtime String's bytes, and storing that slice
/// leaves the entry pointing at freed memory once the String is collected.
/// A later hit then stores the value under a garbage key, and the property
/// reads back null.
fn fieldWriteCachePut(self: *VmHost, inst: ObjRef(InstanceData), fqn: []const u8, name: []const u8, hit: root.ProgramImage.FieldWriteHit) void {
    if (!ir.eval.dispatchCacheStable()) return;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().classIdByFqn(fqn) == null) return;
    }
    const class_p = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.identity();
    };
    const pg = self.prog.borrowMut();
    defer pg.deinit();
    const name_p = pg.get().memberNameIdentity(name) orelse return;
    if (pg.get().field_write_cache.count() >= 65536) return;
    var stable = hit;
    if (hit.setter == root.ProgramImage.FieldWriteHit.NONE) {
        stable.store_name = pg.get().memberNameCanonical(hit.store_name) orelse return;
    }
    pg.get().field_write_cache.put(.{ .class_p = class_p, .name_p = name_p }, stable) catch {};
}

/// The terminal plain store: write through a boxed-capture Cell when the
/// slot holds one, else (re)define the field owning its own reference.
fn storePlainField(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), store_name: []const u8, value: Value) Allocator.Error!UnitResult {
    _ = self;
    // One borrow, one scan: the probe-then-define shape paid two of each per
    // plain write on the memo-hit path (`define` re-scanned what `get` had
    // already located).
    value.retain();
    const g = inst.borrowMut();
    defer g.deinit();
    const b = g.get();
    for (b.fields.items) |*f| {
        if (f.name.ptr == store_name.ptr or std.mem.eql(u8, f.name, store_name)) {
            if (f.value == .Cell) {
                const cg = f.value.Cell.borrowMut();
                defer cg.deinit();
                if (runtime.reclaimEnabled()) cg.get().release(allocator);
                cg.get().* = value;
                return .{ .ok = {} };
            }
            if (runtime.reclaimEnabled()) f.value.release(allocator);
            f.value = value;
            return .{ .ok = {} };
        }
    }
    try b.ensureFieldsOwned(allocator, 1);
    try b.fields.append(allocator, .{ .name = store_name, .value = value });
    b.invalidateShape();
    return .{ .ok = {} };
}

/// Whether a `$sgetter$` resolution for (receiver class, scoped name) is a
/// pure function of the class — every execution mode (member probe or
/// direct read) reaches the same terminal — so the (class, name) memo may
/// serve it. Every consulted fact is class-static: the foreign-receiver
/// probe reject must be inapplicable (the class owns `owner`, or `owner`
/// does not declare the property), and no private-shadow cell may claim
/// the read under either key.
fn sgetterMemoSafe(self: *VmHost, rcn: []const u8, rest: []const u8, owner: []const u8, prop: []const u8) bool {
    const owns = std.mem.eql(u8, rcn, owner) or blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIsOrExtends(rcn, owner);
    };
    const owner_declares_stored = classDeclaresStoredProp(self, owner, prop);
    if (!owns) {
        const owner_declares = owner_declares_stored or blk: {
            const pg = self.prog.borrow();
            defer pg.deinit();
            break :blk lookupPairFunc(pg.get().body_prop_inits, owner, prop) != null or
                lookupPairFunc(pg.get().instance_prop_getters, owner, prop) != null or
                lookupPairFunc(pg.get().instance_prop_private, owner, prop) != null;
        };
        if (owner_declares) return false;
    }
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.private_shadow_props.getKey(rest) != null) return false;
    }
    if (!std.mem.eql(u8, rcn, owner) and !owner_declares_stored) {
        var buf: [256]u8 = undefined;
        const rk = std.fmt.bufPrint(&buf, "{s}\u{1f}{s}", .{ rcn, prop }) catch return false;
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.private_shadow_props.getKey(rk) != null) return false;
    }
    return true;
}

/// Record a `$sgetter$` getter terminal in the (class, name) memo under the
/// FULL scoped name.
fn sgetterPutGetter(self: *VmHost, receiver: *const Value, full_name: []const u8, fid: FuncId) void {
    if (receiver.* != .Instance) return;
    const fqn = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    fieldReadCachePut(self, receiver.Instance, fqn, full_name, .{ .getter = @intCast(fid.int()), .stored_idx = root.ProgramImage.FieldReadHit.NONE });
}

/// After a `$sgetter$` terminal recursed on the bare property and resolved,
/// mirror the bare-name memo entry under the FULL scoped name so later
/// reads (and the GetField site memo) skip the arm's per-read walks.
fn sgetterCopyMemo(self: *VmHost, receiver: *const Value, prop: []const u8, full_name: []const u8) void {
    if (receiver.* != .Instance) return;
    const inst = receiver.Instance;
    var class_p: usize = 0;
    const fqn = blk: {
        const g = inst.borrow();
        defer g.deinit();
        class_p = g.get().class.identity();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const hit = blk: {
        const name_p = host_call_member.memberNameIdentity(self, prop) orelse break :blk null;
        break :blk fieldReadCacheGet(self, class_p, name_p);
    } orelse return;
    fieldReadCachePut(self, inst, fqn, full_name, hit);
}

/// Whether a stored `.Null` in `name`'s slot means an uninitialized
/// `lateinit` property (class-declared).
fn storedNullIsLateinit(inst: ObjRef(InstanceData), name: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    for (cg.get().body_properties) |p| {
        if (std.mem.eql(u8, p.name, name) and p.is_lateinit) return true;
    }
    return false;
}

fn lateinitReadError(allocator: Allocator, name: []const u8) Allocator.Error!EvalResult {
    const m = try std.fmt.allocPrint(allocator, "lateinit property {s} has not been initialized", .{name});
    return errRes(.{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlin.UninitializedPropertyAccessException"),
        .message = .from(try runtime.strInitOwned(allocator, m)),
        .cause = null,
    }) });
}

fn resolveInstanceGetter(
    self: *VmHost,
    allocator: Allocator,
    inst: ObjRef(InstanceData),
    class_name: []const u8,
    recv_fqn: []const u8,
    name: []const u8,
) Allocator.Error!?FuncId {
    const own_is_qualified = !std.mem.eql(u8, recv_fqn, class_name);
    // Own class stores the property -> skip the getter walk entirely.
    {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        if (declaresStored(cg.get(), name)) return null;
    }
    var found: ?FuncId = null;
    if (own_is_qualified) {
        const pg = self.prog.borrow();
        defer pg.deinit();
        found = lookupPairFunc(pg.get().instance_prop_getters, recv_fqn, name);
    }
    if (found != null) return found;
    // Walk the FULL supertype closure breadth-first (nearest-first), not just
    // the first supertype: `class D : I, B()` lists the interface `I` before
    // the base class `B`, so following only `supertype_names[0]` would stop at
    // `I` and never reach `B`'s inherited getter. Methods already BFS the
    // hierarchy (`resolveInstanceMethod`); property getters must too.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    // Seed with the receiver's own class and let the loop expand supers —
    // nearest-first. Pre-pushing the first supertype's OWN supers ahead of
    // it inverted the order: Route's default `selector get() = null` getter
    // was found before RoutingNode's stored ctor-param property could break
    // the walk, so the interface default shadowed the override's field.
    try queue.append(allocator, class_name);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cn = queue.items[head];
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const cdef: ?ObjRef(ClassDef) = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk cg.get().get(cn);
        };
        // A class in the chain that stores `name` overrides any higher
        // base getter — stop and read its field.
        if (cdef) |d| {
            const dg = d.borrow();
            const stored = declaresStored(dg.get(), name);
            dg.deinit();
            if (stored) break;
        }
        {
            const pg = self.prog.borrow();
            const hit = lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, name);
            // A PRIVATE property never participates in inheritance: a read
            // that may bind a private getter arrives scope-qualified
            // (`$sgetter$<owner>`) and resolves in that walk; the inherited
            // chain here must skip it so a base/interface private getter
            // cannot shadow a subclass's own stored field (ktor:
            // HttpClientEngine's private `closed` getter vs
            // HttpClientEngineBase's field-backed atomic `closed`).
            // A private property never participates in INHERITANCE: a base or
            // interface private getter must not shadow a subclass's own stored
            // field (ktor: HttpClientEngine's private `closed` getter vs
            // HttpClientEngineBase's field-backed atomic `closed`). But that
            // reasoning is about SUPERTYPES. On the receiver's OWN class the
            // getter is simply its declaration, and skipping it left a private
            // custom getter unreachable through an EXPLICIT receiver even from
            // inside the class that declares it (`o.orDefault` for a
            // `private val orDefault get() = …` — which is how `KeyboardOptions`
            // reads `Default.autoCorrectOrDefault`). `head == 0` is the receiver's
            // own class; everything after it is inherited.
            const inherited = head != 0;
            const private_here = lookupPairFunc(pg.get().instance_prop_private, cn, name) != null;
            // On an ANONYMOUS receiver class an INHERITED member getter is a
            // supertype-matched guess (the synth lists upstream classes for
            // type checks), and the pack's shadowing EXTENSION property is
            // the real implementation: `ch.onReceive` inside a select must
            // reach the klio clause glue on ReceiveChannel, never upstream
            // BufferedChannel's SelectClause machinery. Stand down when an
            // extension property of the name is keyed on this chain entry.
            const ext_shadows = inherited and hit != null and blk: {
                const ig = inst.borrow();
                defer ig.deinit();
                const icg = ig.get().class.borrow();
                defer icg.deinit();
                if (!icg.get().is_anonymous) break :blk false;
                for (icg.get().supertype_names) |sup| {
                    if (lookupPairFunc(pg.get().extension_props, sup, name) != null) break :blk true;
                }
                break :blk false;
            };
            pg.deinit();
            if (hit != null and !(private_here and inherited) and !ext_shadows) {
                found = hit.?;
                break;
            }
            if (ext_shadows) return null;
        }
        if (cdef) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |sn| queue.append(allocator, sn) catch {};
        }
    }
    return found;
}

/// True when `cdef` stores `name` as a ctor-param or backing-field body
/// property *without* a custom getter / delegate (overriding any
/// inherited `open val … get()`).
fn declaresStored(cdef: *const ClassDef, name: []const u8) bool {
    // An interface stores no state — its `val`/`var` members are abstract
    // declarations, never backing fields (a getter-less interface property is
    // still implicitly abstract even when the parser leaves `is_abstract`
    // unset). So an interface in the hierarchy never overrides a base getter.
    if (cdef.is_interface) return false;
    for (cdef.primary_params) |p| {
        if (std.mem.eql(u8, p.name, name) and p.property != null) return true;
    }
    for (cdef.body_properties) |p| {
        // An `abstract val`/`var` (notably an interface's `val isActive`)
        // stores nothing — it is a declaration to be overridden, not a
        // backing field. Only a concrete property with no getter/delegate is
        // a real stored field that overrides an inherited getter.
        if (std.mem.eql(u8, p.name, name) and p.getter == null and p.delegate == null and !p.is_abstract) return true;
    }
    return false;
}

/// Resolve a built-in property delegate read (`by lazy`, `observable`,
/// `notNull`) to its underlying value, caching a `lazy` producer's
/// result.
fn unwrapDelegate(self: *VmHost, allocator: Allocator, d: ObjRef(runtime.DelegateKind), name: []const u8) Allocator.Error!EvalResult {
    const state = blk: {
        const g = d.borrow();
        defer g.deinit();
        break :blk g.get().*;
    };
    switch (state) {
        .Lazy => |lz| {
            if (lz.cached) |c| return ok(c);
            const result = switch (try self.callValue(allocator, &lz.producer, &.{})) {
                .ok => |v| v,
                .err => |e| return errRes(e),
            };
            {
                const g = d.borrowMut();
                defer g.deinit();
                if (g.get().* == .Lazy) g.get().Lazy.cached = result;
            }
            return ok(result);
        },
        .Observable => |obs| return ok(obs.value),
        .NotNull => |nn| {
            if (nn.value) |x| return ok(x);
            const m = try std.fmt.allocPrint(allocator, "Property {s} should be initialized before get.", .{name});
            return errRes(.{ .Throw = try Value.newException(allocator, .{
                .fqn = try runtime.strInit(allocator, "kotlin.IllegalStateException"),
                .message = .from(try runtime.strInitOwned(allocator, m)),
                .cause = null,
            }) });
        },
    }
}

/// Walk the instance's class parent + interface chain looking for a
/// companion singleton that owns the field.
fn companionParentWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    const seed = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    defer seed.deinit();
    return companionWalkSeeded(self, allocator, seed, name);
}

/// An object/companion nested in a class resolves a bare name against the
/// companion-object members of the enclosing class's superclass hierarchy
/// (`RoutingRoot.Plugin` reads `Call` from `ApplicationCallPipeline`'s
/// companion because `RoutingRoot : … : ApplicationCallPipeline`). Walk from
/// the receiver class's enclosing class.
fn enclosingCompanionWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    // The enclosing class: the resolved `enclosing_class` link when present,
    // else derived from the receiver class's lift name (`Root$Companion$Plugin`
    // / `Outer$Inner`).
    var encl: ?ObjRef(ClassDef) = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        const eg = cg.get().enclosing_class.borrow();
        defer eg.deinit();
        break :blk if (eg.get().*) |e| e.clone() else null;
    };
    if (encl == null) {
        const cls_name = className(inst);
        if (enclosingNameOf(cls_name)) |encl_name| {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(encl_name)) |d| encl = d;
        }
    }
    const seed = encl orelse return null;
    defer seed.deinit();
    return companionWalkSeeded(self, allocator, seed, name);
}

/// The enclosing-class lift name of a nested class / companion lift name:
/// `Root$Companion$Plugin` -> `Root`, `Outer$Inner` -> `Outer`. Null when the
/// name has no nesting marker.
fn enclosingNameOf(name: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, name, "$Companion$")) |i| return name[0..i];
    if (std.mem.lastIndexOfScalar(u8, name, '$')) |i| return name[0..i];
    return null;
}

/// Walk `seed` plus its parent / interface supertypes, returning the first
/// companion-object field named `name`.
fn companionWalkSeeded(self: *VmHost, allocator: Allocator, seed: ObjRef(ClassDef), name: []const u8) Allocator.Error!?EvalResult {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |c| c.deinit();
        queue.deinit(allocator);
    }
    try queue.append(allocator, seed.clone());
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(allocator);
    while (queue.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        const cname = cg.get().name;
        if (containsStr(visited.items, cname)) {
            cg.deinit();
            continue;
        }
        try visited.append(allocator, cname);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| {
                    cg.deinit();
                    return .{ .err = e };
                },
            };
            if (singleton) |s| {
                if (s == .Instance) {
                    const fv: ?Value = blk: {
                        const ig = s.Instance.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(name);
                    };
                    if (fv) |v| {
                        cg.deinit();
                        return ok(v);
                    }
                }
            }
        }
        if (cg.get().parent) |p| try queue.append(allocator, p.clone());
        for (cg.get().interfaces) |ifc| try queue.append(allocator, ifc.clone());
        cg.deinit();
    }
    return null;
}

/// Outer-instance chain fallback for an inner-class method body
/// referencing an enclosing-class field / getter / enum-static.
fn outerInstanceChain(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) Allocator.Error!?EvalResult {
    var cur_outer: ?Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().outer;
    };
    var hops: u8 = 1;
    while (cur_outer) |o| : (hops +|= 1) {
        switch (o) {
            .Instance => |outer_inst| {
                // Resolve through getFieldInner first so an overriding custom
                // getter on the outer instance's runtime (sub)class is invoked
                // virtually, rather than short-circuiting on an inherited raw
                // backing slot (e.g. an `abstract`/`open val` overridden by a
                // getter-only `override`). getFieldInner itself falls back to
                // the raw slot when no getter resolves, so legitimately stored
                // fields still read correctly.
                const oid = outer_inst.identity();
                if (try withFieldResolvePair(self, allocator, oid, name, &o, false, false)) |r| {
                    if (r == .ok and r.ok != .Unit) {
                        // The outer read just filled the OUTER class's own
                        // (class, name) memo; when it answers with a plain
                        // stored slot, propagate an outer-hop route onto
                        // the INNER class so the GetField site serves later
                        // reads without re-walking the chain.
                        if (hops <= 63) prop: {
                            const ocls_id: u64 = blk2: {
                                const g = outer_inst.borrow();
                                defer g.deinit();
                                break :blk2 @intCast(g.get().class.identity());
                            };
                            const name_p = host_call_member.memberNameIdentity(self, name) orelse break :prop;
                            const ohit = fieldReadCacheGet(self, ocls_id, name_p) orelse break :prop;
                            const NONE = root.ProgramImage.FieldReadHit.NONE;
                            if (ohit.getter != NONE or ohit.stored_idx == NONE) break :prop;
                            if (ohit.outer_hops != 0 or ohit.stored_idx > 0xFFFFFF) break :prop;
                            const inner_fqn = blk2: {
                                const ig = inst.borrow();
                                defer ig.deinit();
                                const cg = ig.get().class.borrow();
                                defer cg.deinit();
                                break :blk2 cg.get().fqn;
                            };
                            fieldReadCachePut(self, inst, inner_fqn, name, .{
                                .getter = NONE,
                                .stored_idx = ohit.stored_idx,
                                .outer_hops = hops,
                                .outer_cls = ocls_id,
                            });
                        }
                        return r;
                    }
                }
                {
                    const g = outer_inst.borrow();
                    defer g.deinit();
                    const b = g.get();
                    for (b.fields.items, 0..) |f, fi| {
                        if (!std.mem.eql(u8, f.name, name)) continue;
                        // Memoize the outer-hop slot route on the INNER
                        // class so the GetField site serves later reads
                        // without re-walking the chain (the OpIterator
                        // `operation` accessor read `opCodes` through
                        // this fallback 1.5M times in one recompose
                        // test). The outer's runtime class identity is
                        // verified at serve time.
                        if (fi <= 0xFFFFFF and hops <= 63) {
                            const inner_fqn = blk2: {
                                const ig = inst.borrow();
                                defer ig.deinit();
                                const cg = ig.get().class.borrow();
                                defer cg.deinit();
                                break :blk2 cg.get().fqn;
                            };
                            const ocls: u64 = @intCast(b.class.identity());
                            fieldReadCachePut(self, inst, inner_fqn, name, .{
                                .getter = root.ProgramImage.FieldReadHit.NONE,
                                .stored_idx = @intCast(fi),
                                .outer_hops = hops,
                                .outer_cls = ocls,
                            });
                        }
                        return ok(f.value);
                    }
                }
                cur_outer = blk: {
                    const g = outer_inst.borrow();
                    defer g.deinit();
                    break :blk g.get().outer;
                };
            },
            .Class => |cls| {
                switch (try getField(self, allocator, &o, name)) {
                    .ok => |v| return ok(v),
                    .err => {},
                }
                // Step to the enclosing class.
                const cls_name = blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    break :blk g.get().name;
                };
                const encl: ?[]const u8 = blk: {
                    const g = self.module.borrow();
                    defer g.deinit();
                    break :blk g.get().registry.enclosing_class.get(cls_name);
                };
                cur_outer = if (encl) |n| blk: {
                    const cg = self.classes.borrow();
                    defer cg.deinit();
                    break :blk if (cg.get().get(n)) |c| Value{ .Class = c } else null;
                } else null;
            },
            else => cur_outer = null,
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// set_field
// -------------------------------------------------------------------------

/// Whether the receiver instance declares (or already stores) a member
/// property of this name, anywhere in its class hierarchy. A member
/// property shadows a same-named extension property
/// (`EXTENSION_SHADOWED_BY_MEMBER`), so the extension getter/setter must not
/// fire when the member exists — otherwise `this.value` inside a class that
/// has both a member `value` and an extension `value` re-enters the
/// extension accessor and recurses (e.g. coroutines' `WorkaroundAtomicReference`).
fn instanceDeclaresProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    if (receiver.* != .Instance) return false;
    const inst = receiver.Instance;
    {
        const g = inst.borrow();
        defer g.deinit();
        if (g.get().get(name) != null) return true;
    }
    var cur: ?[]const u8 = className(inst);
    var depth: usize = 0;
    while (cur) |cn| : (depth += 1) {
        if (depth > 64) break;
        var found = false;
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(cn)) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                for (dg.get().primary_params) |p| {
                    if (p.property != null and std.mem.eql(u8, p.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) for (dg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        found = true;
                        break;
                    }
                };
            }
        }
        if (found) return true;
        cur = firstSupertype(self, cn);
    }
    return false;
}

/// The class a `super.prop = v` write was made from, for the duration of that
/// write. The setter search then starts at that class's SUPERTYPES: an
/// overriding setter whose body writes `super.prop` must reach the base
/// accessor, never itself.
threadlocal var super_write_owner: ?[]const u8 = null;

pub fn setField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
    return setFieldInner(self, allocator, receiver, name, value);
}

pub fn setFieldFrom(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    value: Value,
    super_owner: ?[]const u8,
) Allocator.Error!UnitResult {
    if (super_owner == null) return setFieldInner(self, allocator, receiver, name, value);
    const prev = super_write_owner;
    super_write_owner = super_owner;
    defer super_write_owner = prev;
    return setFieldInner(self, allocator, receiver, name, value);
}

fn setFieldInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
    // CONSUME the marker: it belongs to this write only. Writes made inside the
    // base setter we are about to reach are ordinary ones.
    const super_owner: ?[]const u8 = blk: {
        const o = super_write_owner;
        super_write_owner = null;
        break :blk o;
    };
    // Companion forwarding for writes: `Foo.count = 1` routes to the
    // companion singleton instance's field.
    if (receiver.* == .Class) {
        const cls_name = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().name;
        };
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cls_name);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| {
                if (s == .Instance) return setField(self, allocator, &s, name, value);
            }
        }
    }
    const bypass_setter = std.mem.startsWith(u8, name, "__klio_field__");
    const real_name = if (bypass_setter) name["__klio_field__".len..] else name;
    // Field-write memo: one probe replaces the whole ext-setter / delegated /
    // custom-setter / override-cell ladder below for a (class, name) pair the
    // ladder has already classified from class-static facts alone.
    const write_cache_ok = receiver.* == .Instance and !bypass_setter and
        super_owner == null and ir.eval.dispatchCacheStable();
    if (write_cache_ok) {
        const wclass_p = blk: {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            break :blk g.get().class.identity();
        };
        const hit: ?root.ProgramImage.FieldWriteHit = blk: {
            const name_p = host_call_member.memberNameIdentity(self, real_name) orelse break :blk null;
            break :blk fieldWriteCacheGet(self, wclass_p, name_p);
        };
        if (hit) |h| {
            if (h.setter != root.ProgramImage.FieldWriteHit.NONE) {
                switch (try evalSetter(self, allocator, FuncId.from(h.setter), receiver.*, value)) {
                    .ok => return .{ .ok = {} },
                    .err => |e| return .{ .err = e },
                }
            }
            return storePlainField(self, allocator, receiver.Instance, h.store_name, value);
        }
    }
    var write_cacheable = write_cache_ok;
    var plain_recordable = false;
    // Extension-property setter — `var T.x set(value) {…}`. A member property
    // of the same name shadows the extension, so skip it when the receiver
    // declares its own `real_name` (else `this.x = …` recurses through the
    // extension setter).
    if (!bypass_setter and !instanceDeclaresProperty(self, receiver, real_name)) {
        // A `var X.Companion.x` setter registers under `X`'s simple name;
        // its `this` is `X`'s companion instance, not the class value.
        const recv_simple: []const u8 = switch (receiver.*) {
            .Instance => |i| className(i),
            .Class => |c| blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk lastSegment(g.get().name);
            },
            else => lastSegment(receiver.typeFqn()),
        };
        const fid: ?FuncId = try resolveExtensionPropSetter(self, allocator, receiver, recv_simple, real_name);
        if (fid) |f| {
            const mptr: *const Module = self.module.asPtr();
            if (f.int() >= mptr.funcCount()) {
                const msg = try std.fmt.allocPrint(allocator, "ext setter FuncId {d} out of range", .{f.int()});
                return .{ .err = .{ .Type = msg } };
            }
            var setter_recv = receiver.*;
            if (receiver.* == .Class) {
                if (try companionInstanceForClass(self, recv_simple)) |comp| setter_recv = comp;
            }
            // A member-extension property's setter body has its declaring
            // class's `this` in lexical scope; seed the setter frame with
            // the owner instance from the enclosing chain.
            var pushed_owner = false;
            if (mptr.registry.member_ext_owner_class.get(f)) |owner| {
                if (try host_call_member.memberExtOwnerInstance(self, allocator, &setter_recv, owner)) |inst| {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
            const r = try evalSetter(self, allocator, f, setter_recv, value);
            if (pushed_owner) ir.eval.popEnclosing();
            switch (r) {
                .ok => return .{ .ok = {} },
                .err => |e| return .{ .err = e },
            }
        }
        // Delegated extension property (`var R.x by expr`): write through
        // the cached delegate's `setValue(thisRef, property, value)`.
        if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, real_name)) |hit| {
            const d = try extPropDelegateInstance(self, allocator, hit.key, real_name, hit.fid);
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, real_name) } };
            const r = try self.callMember(allocator, &d, "setValue", &.{ receiver.*, prop_ref, value });
            switch (r) {
                .ok => return .{ .ok = {} },
                .err => |e| return .{ .err = e },
            }
        }
    }
    if (receiver.* == .Instance) {
        const inst = receiver.Instance;
        const class_name = className(inst);
        if (!bypass_setter) {
            // Delegated body property -> route through `setValue`.
            const is_delegated: bool = runtimeClassDelegatesProp(inst, real_name) or blk: {
                var cur: ?[]const u8 = class_name;
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(allocator);
                while (cur) |cn| {
                    cur = null;
                    if (containsStr(seen.items, cn)) break;
                    try seen.append(allocator, cn);
                    if (delegatedPropRegistered(self, cn, real_name)) break :blk true;
                    cur = firstSupertype(self, cn);
                }
                break :blk false;
            };
            if (is_delegated) {
                write_cacheable = false;
                const raw: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :blk g.get().get(real_name);
                };
                if (raw) |d| {
                    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, real_name) } };
                    switch (try self.callMember(allocator, &d, "setValue", &.{ receiver.*, prop_ref, value })) {
                        .ok => return .{ .ok = {} },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            // Custom property setter declared on the class or a base. Walk the
            // FULL transitive supertype set, not a single `firstSupertype`
            // chain: a class may inherit the setter from a base that is not its
            // first-declared supertype (`MeasurePassDelegate : Placeable(),
            // Measurable` — the `firstSupertype` chain follows the `Measurable`
            // interface and never reaches `Placeable`, so the custom
            // `measuredSize` setter was skipped and the write hit the backing
            // field directly, its side effects lost).
            const setter_fid: ?FuncId = blk: {
                // `super.prop = v`: the writing class's own setter is exactly the
                // one being overridden, so start the search at its SUPERTYPES. A
                // base whose property is field-backed has no setter at all, and
                // the store below writes the field — which is what `super.prop = v`
                // means.
                if (super_owner) |owner| {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    if (mg.get().registry.class_super_names.get(owner)) |chain| {
                        for (chain) |cn| {
                            const pg = self.prog.borrow();
                            const hit = lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, real_name);
                            pg.deinit();
                            if (hit) |f| break :blk f;
                        }
                    }
                    break :blk null;
                }
                // FQN key first: distinct packs' same-simple-named classes
                // keep distinct FQN keys even when the shared SIMPLE-name
                // slot clobbers (kotlinx-coroutines-test's private `class
                // AtomicBoolean` vs atomicfu's).
                const rf = classFqnOf(inst);
                if (!std.mem.eql(u8, rf, class_name)) {
                    const pg = self.prog.borrow();
                    const hit = lookupPairFunc(pg.get().instance_prop_setters, rf, real_name);
                    pg.deinit();
                    if (hit) |f| break :blk f;
                }
                {
                    const pg = self.prog.borrow();
                    const hit = lookupPairFunc(pg.get().instance_prop_setters, class_name, real_name);
                    pg.deinit();
                    // The simple slot is shared program-wide: accept its fid
                    // for the receiver's OWN class only when the setter's
                    // declaring package matches the receiver class's package
                    // (a foreign namesake's accessor must not intercept a
                    // field-backed write on an unrelated class; the
                    // same-package hit keeps `var counter set(value)` custom
                    // setters over their backing field).
                    if (hit) |f| {
                        const mptr2: *const Module = self.module.asPtr();
                        const fp: []const u8 = if (mptr2.funcById(f)) |ff| ff.package else "";
                        const rpkg: []const u8 = if (std.mem.lastIndexOfScalar(u8, rf, '.')) |d| rf[0..d] else "";
                        if (rpkg.len == 0 or fp.len == 0 or std.mem.eql(u8, fp, rpkg)) break :blk f;
                    }
                }
                // The receiver's OWN class declaring the property as stored
                // (a field-backed `override var x = 0`) shadows any inherited
                // accessor: store the field directly, never reach a supertype's
                // custom setter.
                if (classDeclaresStoredProp(self, class_name, real_name)) break :blk null;
                const rf2 = classFqnOf(inst);
                if (!std.mem.eql(u8, rf2, class_name) and classDeclaresStoredProp(self, rf2, real_name)) break :blk null;
                const mg = self.module.borrow();
                defer mg.deinit();
                if (mg.get().registry.class_super_names.get(class_name)) |chain| {
                    for (chain) |cn| {
                        const pg = self.prog.borrow();
                        const hit = lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, real_name);
                        pg.deinit();
                        if (hit) |f| break :blk f;
                        // A stored override shadows any further-up accessor: an
                        // `override var x = 0` on a middle class overrides a base
                        // `open var x set(...)`, so a write stores the field
                        // rather than reaching the base's custom setter.
                        if (classDeclaresStoredProp(self, cn, real_name)) break :blk null;
                    }
                }
                break :blk null;
            };
            if (setter_fid) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() >= mptr.funcCount()) {
                    const msg = try std.fmt.allocPrint(allocator, "setter FuncId {d} out of range", .{fid.int()});
                    return .{ .err = .{ .Type = msg } };
                }
                if (write_cacheable) {
                    fieldWriteCachePut(self, inst, classFqnOf(inst), real_name, .{
                        .setter = fid.int(),
                        .store_name = "",
                    });
                }
                switch (try evalSetter(self, allocator, fid, receiver.*, value)) {
                    .ok => return .{ .ok = {} },
                    .err => |e| return .{ .err = e },
                }
            }
            // Anon-object / local-class custom setter: dispatch a `$set$<name>`
            // anon method when one is registered for the receiver's class —
            // the write-side mirror of the `$get$<name>` read path.
            {
                const setter_key = try std.fmt.allocPrint(allocator, "$set${s}", .{real_name});
                defer allocator.free(setter_key);
                const has_setter = blk: {
                    const g = self.anon_methods.borrow();
                    defer g.deinit();
                    break :blk g.get().contains(anonKey(class_name, setter_key));
                };
                if (has_setter) {
                    switch (try self.callMember(allocator, receiver, setter_key, &.{value})) {
                        .ok => return .{ .ok = {} },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            // Companion / parent / outer fallback for a write whose name
            // is not an own member of this instance.
            const has_own = blk: {
                const g = inst.borrow();
                defer g.deinit();
                break :blk g.get().get(real_name) != null;
            };
            const is_own_member = blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                for (cg.get().primary_params) |p| {
                    if (std.mem.eql(u8, p.name, real_name)) break :blk true;
                }
                for (cg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, real_name)) break :blk true;
                }
                break :blk false;
            };
            if (is_own_member) plain_recordable = true;
            if (!has_own and !is_own_member) {
                // Interface-delegation forwarding for writes: a `var` the
                // delegated interface declares routes the write to the delegate
                // object (`class Scope(s) : MutableState by s` — `scope.value = x`
                // writes `s.value = x`). Mirrors the read-path forwarding; without
                // it the write would fabricate an own backing field, diverging the
                // delegator from its delegate.
                const deleg_target: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    for (g.get().fields.items) |f| {
                        if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
                        const iface = f.name["__delegate__".len..];
                        if (host_call_member.delegatedInterfaceDeclares(self, allocator, inst, iface, real_name) == true) {
                            break :blk f.value;
                        }
                    }
                    break :blk null;
                };
                if (deleg_target) |d| return setField(self, allocator, &d, real_name, value);
                if (try setCompanionParentWalk(self, allocator, inst, real_name, value)) |r| return r;
                const outer: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :blk g.get().outer;
                };
                if (outer) |o| return setField(self, allocator, &o, real_name, value);
            }
        }
        {
            // A stored `override val/var` keeps its own backing cell under the
            // owner-mangled key (JVM semantics); the read path resolves the
            // nearest such cell in the runtime chain. A plain write must target
            // that SAME cell — writing the base's plain `real_name` cell would
            // leave the override read (which addresses the mangled cell) stale.
            // `super.x = v` still targets the base's plain cell (super_owner
            // set), so keep the plain name then.
            const store_name: []const u8 = if (super_owner != null) real_name else blk: {
                const any_cell = pglobal: {
                    const pg = self.module.borrow();
                    defer pg.deinit();
                    break :pglobal pg.get().registry.override_cell_props.count() != 0;
                };
                if (!any_cell) break :blk real_name;
                var cur3: ?[]const u8 = className(inst);
                var hops3: u8 = 0;
                while (cur3) |cn3| : (hops3 += 1) {
                    if (hops3 > 16) break;
                    var kb3: [256]u8 = undefined;
                    const probe3 = std.fmt.bufPrint(&kb3, "{s}\x1f{s}", .{ cn3, real_name }) catch break;
                    const key = kblk: {
                        const pg = self.module.borrow();
                        defer pg.deinit();
                        break :kblk pg.get().registry.override_cell_props.getKey(probe3);
                    };
                    if (key) |k| break :blk k;
                    cur3 = firstSupertype(self, cn3);
                }
                break :blk real_name;
            };
            if (write_cacheable and plain_recordable) {
                fieldWriteCachePut(self, inst, classFqnOf(inst), real_name, .{
                    .setter = root.ProgramImage.FieldWriteHit.NONE,
                    .store_name = store_name,
                });
            }
            return storePlainField(self, allocator, inst, store_name, value);
        }
    }
    const tf = try allocator.dupe(u8, receiverLabel(receiver));
    if (missTraceEnvCached() != null) {
        std.debug.print("[setfield-miss] `{s}` on `{s}` span={any}\n", .{ name, tf, ir.eval.currentCallSiteSpan() });
        ir.eval.debugPrintFrames();
    }
    const msg = try std.fmt.allocPrint(allocator, "Vm::set_field `{s}` on `{s}`", .{ name, tf });
    allocator.free(tf);
    return .{ .err = .{ .Unimplemented = msg } };
}

/// Walk an instance's class chain (parents + interfaces) and write the
/// field through the first companion singleton that already declares it.
fn setCompanionParentWalk(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8, value: Value) Allocator.Error!?UnitResult {
    var queue: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (queue.items) |c| c.deinit();
        queue.deinit(allocator);
    }
    {
        const g = inst.borrow();
        defer g.deinit();
        try queue.append(allocator, g.get().class.clone());
    }
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(allocator);
    while (queue.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        const cname = cg.get().name;
        if (containsStr(visited.items, cname)) {
            cg.deinit();
            continue;
        }
        try visited.append(allocator, cname);
        const comp_name: ?[]const u8 = blk: {
            const g = self.module.borrow();
            defer g.deinit();
            break :blk g.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| {
                    cg.deinit();
                    return .{ .err = e };
                },
            };
            if (singleton) |s| {
                if (s == .Instance) {
                    const has = blk: {
                        const ig = s.Instance.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(name) != null;
                    };
                    if (has) {
                        cg.deinit();
                        return try setField(self, allocator, &s, name, value);
                    }
                }
            }
        }
        if (cg.get().parent) |p| try queue.append(allocator, p.clone());
        for (cg.get().interfaces) |ifc| try queue.append(allocator, ifc.clone());
        cg.deinit();
    }
    return null;
}

/// Run an IR-lowered setter `fid` with `(receiver, value)` bound.
fn evalSetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value, value: Value) Allocator.Error!UnitResult {
    const mptr: *const Module = self.module.asPtr();
    const func = mptr.funcById(fid) orelse return .{ .err = .{ .Type = "setter FuncId out of range" } };
    var args: std.ArrayList(Value) = .empty;
    try args.append(allocator, receiver);
    try args.append(allocator, value);
    vmhost.emitPath(allocator, "setter", func.fqn, fid, &receiver, &.{value});
    return switch (try ir.eval.evalWith(VmHost, allocator, mptr, func, args, self)) {
        .ok => .{ .ok = {} },
        .err => |e| .{ .err = e },
    };
}

// -------------------------------------------------------------------------
// member_ref
// -------------------------------------------------------------------------

pub fn memberRef(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    // `X::class` is a class reference, not a member ref.
    if (std.mem.eql(u8, name, "class")) {
        if (receiver.* == .Instance) {
            const g = receiver.Instance.borrow();
            defer g.deinit();
            return ok(.{ .Class = g.get().class.clone() });
        }
        return ok(receiver.*);
    }
    // `recv::method` -> a tiny synth Instance whose `__bound_receiver__` /
    // `__bound_name__` fields drive the call_value path.
    const identity = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic) + 1;
    };
    const synth_name = try std.fmt.allocPrint(allocator, "$bound_ref${s}", .{name});
    const synth_class = try ObjRef(ClassDef).init(allocator, .{
        .name = synth_name,
        .fqn = synth_name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    });
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__bound_receiver__", .value = receiver.* });
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try runtime.strInit(allocator, name) } });
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = synth_class,
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return ok(.{ .Instance = inst });
}

// -------------------------------------------------------------------------
// Small shared helpers.
// -------------------------------------------------------------------------

/// Anon-method registry key `"<class>\u{1f}<method>"`. The registry is
/// keyed on a single string, built as a unit-separated concatenation of
/// `(class, name)` cached per-call.
threadlocal var anon_key_buf: [512]u8 = undefined;
fn anonKey(class_name: []const u8, method: []const u8) []const u8 {
    return std.fmt.bufPrint(&anon_key_buf, "{s}\u{1f}{s}", .{ class_name, method }) catch class_name;
}

/// The runtime class simple name of an instance.
fn className(inst: ObjRef(InstanceData)) []const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().name;
}

/// The instance's class FQN (falling back to its simple name when no FQN
/// is recorded). Used to key a native property-getter binding.
fn classFqnOf(inst: ObjRef(InstanceData)) []const u8 {
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
fn instanceIsHostSynth(inst: ObjRef(InstanceData)) bool {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (!cg.get().is_anonymous) return false;
    const fqn = cg.get().fqn;
    return fqn.len != 0 and
        std.mem.indexOfScalar(u8, fqn, '.') != null and
        !std.mem.eql(u8, fqn, cg.get().name);
}

/// The first declared supertype simple name of an instance's class.
fn firstSupertypeOf(inst: ObjRef(InstanceData)) ?[]const u8 {
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
fn companionSimpleName(mangled: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, mangled, '$')) |i| mangled[i + 1 ..] else mangled;
}

fn firstSupertype(self: *VmHost, cn: []const u8) ?[]const u8 {
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

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn matchAny(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, name, c)) return true;
    }
    return false;
}

fn listLen(items: ValueList) usize {
    const g = items.borrow();
    defer g.deinit();
    return g.get().items.len;
}

/// `len` (as `i64`) of an array / list / string receiver, or `null`.
fn collectionLen(receiver: *const Value) ?i64 {
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

// -------------------------------------------------------------------------
// Tests
//
// These exercise dispatch-chain behaviors that do not require a fully
// wired Vm (the foundation's stubbed siblings).
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "utf16Len counts code units, falling back to bytes" {
    try testing.expectEqual(@as(usize, 3), utf16Len("abc"));
    // A BMP multibyte char is one UTF-16 unit.
    try testing.expectEqual(@as(usize, 1), utf16Len("é"));
}

test "lastSegment returns the trailing dotted segment" {
    try testing.expectEqualStrings("c", lastSegment("a.b.c"));
    try testing.expectEqualStrings("x", lastSegment("x"));
}

test "collectionLen reports list and string lengths" {
    const a = testing.allocator;
    var list: std.ArrayList(Value) = .empty;
    try list.append(a, .{ .Int = 1 });
    try list.append(a, .{ .Int = 2 });
    const lv = try Value.newList(a, .{
        .items = try ValueList.init(a, list),
        .mutable = false,
        .enum_entries = false,
        .backing = null,
    });
    defer runtime.listRefOf(lv.List).deinit();
    try testing.expectEqual(@as(i64, 2), collectionLen(&lv).?);

    const s = try runtime.strInit(a, "hello");
    defer s.deinit();
    const sv = Value{ .String = s };
    try testing.expectEqual(@as(i64, 5), collectionLen(&sv).?);

    const iv = Value{ .Int = 7 };
    try testing.expect(collectionLen(&iv) == null);
}

test "containsStr / matchAny membership" {
    const xs = [_][]const u8{ "a", "b" };
    try testing.expect(containsStr(&xs, "a"));
    try testing.expect(!containsStr(&xs, "c"));
    try testing.expect(matchAny("members", &.{ "x", "members" }));
    try testing.expect(!matchAny("nope", &.{ "x", "members" }));
}

test "discarded field probes release their owned miss message" {
    const msg = try testing.allocator.dupe(u8, "Vm::get_field `x` on `T`");
    freeFieldMiss(testing.allocator, .{ .Unimplemented = msg });
    freeFieldMiss(testing.allocator, .{ .Unimplemented = "nested: Vm::get_field is static" });
}

/// The module whose tables `func`'s body indexes against, when that is the
/// program's own module. A flat request built without one is normally read
/// against the CALLER's module, which is wrong whenever the callee was
/// resolved elsewhere: an anonymous object's runtime module delegates base
/// funcs through the shared lazy header section but carries only its own
/// const pool, so the callee's const ids land outside it.
pub fn ownerModuleForFunc(self: *VmHost, func: *const ir.Func) ?*const ir.Module {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    return if (m.funcById(func.id) == func) m else null;
}
