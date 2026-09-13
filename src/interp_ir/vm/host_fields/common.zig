//! Shared helpers behind the field paths: result constructors, the
//! resolution-guard wrapper, getter evaluation, intrinsic lookup and dispatch,
//! and the name and shape predicates every ladder consults.

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

/// Top of the driver stack a `driveRoot` activation pushes its scope onto.
pub fn activeCoroScope() ?Value {
    return vmhost.coroutines.activeCoroScope();
}

/// Top of the shared enclosing-`this` stack: the lexically enclosing `this` a
/// receiver lambda displaced, so a bare member-property read inside a
/// member-extension body resolves against the enclosing class instance.
pub fn outerThisLast(self: *VmHost) ?Value {
    return vmhost.host_call_member.enclosingThis(self);
}

/// Runs `f` only when `(id, name)` is not already resolving through the
/// `get_field` fallbacks, bounding that recursion to distinct instances.
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
    // The guard stack is process-global and cleared capacity-retaining at run
    // boundaries, so a per-run arena backing would leave that capacity dangling.
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

pub fn lastSegment(s: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, s, '.')) |i| return s[i + 1 ..];
    return s;
}

/// UTF-16 code units, the unit `String.length` reports. The stdlib counter, not
/// `std.unicode.calcUtf16LeLen`, whose fallback returns the byte length for a
/// WTF-8 lone surrogate that kotlinc accepts.
pub fn utf16Len(s: []const u8) usize {
    const n = stdlib.text.utf16Len(s);
    return if (n < 0) 0 else @intCast(n);
}

/// Consumes `items`; `enum_entries` marks an `EnumName.entries` list.
pub fn frozenList(allocator: Allocator, items: std.ArrayList(Value), enum_entries: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ValueList.init(allocator, items),
        .mutable = false,
        .enum_entries = enum_entries,
        .backing = null,
    });
}

/// Runs `fid` with the receiver as its sole positional argument, the shape of a
/// custom getter or extension property.
pub fn evalGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    return evalGetterTagged(self, allocator, fid, receiver, "untagged");
}

pub fn evalGetterTagged(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value, site: []const u8) Allocator.Error!EvalResult {
    const mptr: *const Module = self.module.asPtr();
    const func = mptr.funcById(fid) orelse {
        const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
        return errRes(.{ .Type = msg });
    };
    if (accessorFastGet(self, mptr, func, &receiver)) |r| return r;
    // Host-served compose snapshot getters, classified once per Func like the
    // static-call routes in `hostStaticServe`.
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
    // Frameless serve for the wider leaf shape: stored reads plus arithmetic.
    if (try ir.eval.leafExprServe(VmHost, allocator, mptr, func, &.{receiver}, self)) |r| return r;
    // A branchy accessor the frameless evaluator declines still serves its
    // compiled leaf; the getter path is a commit point like any other.
    if (try ir.eval.tryLeafValues(VmHost, allocator, mptr, func, &.{receiver}, self, null)) |lo| switch (lo) {
        .val => |v| return .{ .ok = v },
        .raise => |e| return errRes(e),
    };
    if (missTraceEnvCached()) |w| {
        if (std.mem.find(u8, func.name, w) != null) {
            const rc: []const u8 = if (receiver == .Instance) className(receiver.Instance) else receiver.typeFqn();
            std.debug.print("[getter] {s}#{d} recv={s} site={s}\n", .{ func.name, fid.int(), rc, site });
            ir.eval.dumpFrameChainForDiagAlways();
        }
    }
    // Pin the receiver as a GC root: until the new frame's params are installed
    // this native local is the only handle the collector can see.
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

pub fn lookupPairFunc(map: anytype, a: []const u8, b: []const u8) ?FuncId {
    return map.get(.{ .a = a, .b = b });
}

/// Accessor lookup across a hierarchy hop: simple key first, then the hop class's
/// FQN key. A private class registers only under the FQN, so the shared simple
/// slot cannot let a private namesake capture unrelated dispatch.
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

/// The pack-supplied bindings overlay shadows the stdlib implementation.
pub fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only, so the published link flag
    // gates an unguarded read instead of two shared reader locks per lookup.
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

/// Maps the intrinsic's `RuntimeError` onto the matching `EvalError`.
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
            // Each message-carrying kind keeps its text; the tag name buries it.
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

/// An anon-object method's captured outer `var` lives in a shared Cell, which is
/// a carrier and never a user value, so the read goes through it.
pub fn unwrapCellRead(r: EvalResult) EvalResult {
    if (r == .ok and r.ok == .Cell) {
        const cg = r.ok.Cell.borrow();
        defer cg.deinit();
        return .{ .ok = cg.get().* };
    }
    return r;
}

/// Frees a probe's discarded miss message: host misses are `allocPrint`-built
/// with a `Vm::` prefix, which static literals never carry.
pub fn freeMissErr(allocator: Allocator, e: EvalError) void {
    if (!runtime.freeScratch()) return;
    if (e != .Unimplemented) return;
    if (std.mem.startsWith(u8, e.Unimplemented, "Vm::")) allocator.free(e.Unimplemented);
}

/// The receiver's class fqn, so a diagnostic names the declaring class.
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

/// `KClass.simpleName` of a runtime class name: a nested class is stored lifted
/// as `Outer$Inner` and a local class under the mangle `Name$lc<fn>`.
pub fn classSimpleName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.find(u8, n, "$lc")) |i| n = n[0..i];
    if (std.mem.findLastAny(u8, n, "$.")) |i| {
        if (i + 1 < n.len) n = n[i + 1 ..];
    }
    return n;
}

/// The enclosing-class lift name: `Root$Companion$Plugin` and `Outer$Inner` give
/// `Root` and `Outer`; null when the name has no nesting marker.
pub fn enclosingNameOf(name: []const u8) ?[]const u8 {
    if (std.mem.find(u8, name, "$Companion$")) |i| return name[0..i];
    if (std.mem.findScalarLast(u8, name, '$')) |i| return name[0..i];
    return null;
}

/// Anon-method registry key: the single string `"<class>\u{1f}<method>"`.
pub fn anonKey(class_name: []const u8, method: []const u8) []const u8 {
    return std.fmt.bufPrint(&fldTls().anon_key_buf, "{s}\u{1f}{s}", .{ class_name, method }) catch class_name;
}

pub fn className(inst: ObjRef(InstanceData)) []const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().name;
}

/// The instance's class FQN, or its simple name when none is recorded.
pub fn classFqnOf(inst: ObjRef(InstanceData)) []const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const fqn = cg.get().fqn;
    return if (fqn.len != 0) fqn else cg.get().name;
}

/// Whether the class is host-synthesised: anonymous, from `newSynthInstance`,
/// with a package-qualified FQN differing from its simple name. A source
/// `object : I {}` has its `$anon$N` name as FQN and does not qualify.
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

pub fn firstSupertypeOf(inst: ObjRef(InstanceData)) ?[]const u8 {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    const sts = cg.get().supertype_names;
    return if (sts.len > 0) sts[0] else null;
}

/// Companion singleton simple name: `Owner$Companion$Key` gives `Key`.
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
    // A dotted nested name may register under its lifted mangled key.
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

pub fn collectionLen(receiver: *const Value) ?i64 {
    return switch (receiver.*) {
        .Array => |a| @intCast(a.len()),
        .List => |l| @intCast(listLen(l.items)),
        // `Collection<*>.indices` and `lastIndex` apply to sets too; a view,
        // with `backing != null`, falls through to the view machinery.
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
