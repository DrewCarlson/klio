//! `VmHost` field access: reading and writing a named property on a
//! receiver — stored fields, custom getters/setters, extension
//! properties, and the inner-class outer-chain fallbacks.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator. Mirrors the ordered field-resolution dispatch chain
//! of `host_fields.rs` (get/set/member-ref).

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

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
// Mirror the crate-private thread-locals `host_fields.rs` and `lib.rs`
// use to bound the heuristic field-resolution recursion and to expose
// the suspend-implicit coroutine scope / displaced enclosing `this`.
// They are empty/false until the coroutine driver and the access-
// enclosing machinery push onto them, matching Rust's default state.
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
/// `null` (Rust `None`) when the pair is already active.
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
    const r = try getFieldInner(self, allocator, receiver, name, suppress_cc_redirect, member_probe);
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

// -------------------------------------------------------------------------
// Small helpers shared with the Rust source's inline closures.
// -------------------------------------------------------------------------

/// Last `.`-delimited segment of a dotted name (`a.b.c` -> `c`).
fn lastSegment(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| return s[i + 1 ..];
    return s;
}

/// Number of UTF-16 code units in `s` (Kotlin `String` length unit),
/// falling back to the byte count for malformed UTF-8.
fn utf16Len(s: []const u8) usize {
    return std.unicode.calcUtf16LeLen(s) catch s.len;
}

/// Build a frozen `List` value over `items` with the given enum-class
/// tag. Consumes `items` into the backing cell.
fn frozenList(allocator: Allocator, items: std.ArrayList(Value), enum_class: ?StringRef) Allocator.Error!Value {
    return .{ .List = .{
        .items = try ValueList.init(allocator, items),
        .mutable = false,
        .enum_class = enum_class,
        .backing = null,
    } };
}

/// Run the IR-lowered function `fid` with the receiver bound as the
/// sole positional argument (custom getter / extension prop invocation).
fn evalGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    const mptr: *const Module = self.module.asPtr();
    if (fid.int() >= mptr.funcs.items.len) {
        const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
        return errRes(.{ .Type = msg });
    }
    const func = &mptr.funcs.items[fid.int()];
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

/// Look up an intrinsic by FQN: the pack-supplied bindings overlay
/// first, then the stdlib default implementation.
fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
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
        .allocator = allocator,
    };
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = ih.intrinsicHost(),
        .allocator = allocator,
    };
    const r = try func(&ctx);
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
    return getFieldInner(self, allocator, receiver, name, false, false);
}

/// Per-candidate probe for the bare-name resolver's innermost-first walk:
/// resolves only what the receiver itself owns — instance fields,
/// declared properties and their getters, applicable extension
/// properties, builtin member properties. Every global / outer-receiver /
/// companion adoption tail is disabled, so a candidate cannot "resolve" a
/// name it does not own and shadow a real member of a receiver further
/// out; the walk's own terminal arm decides the global fallback, and
/// companions ride the walk as their own candidates.
pub fn getMemberField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return getFieldInner(self, allocator, receiver, name, false, true);
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
fn getFieldInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, suppress_cc_redirect: bool, member_probe: bool) Allocator.Error!EvalResult {
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
                const bname = ng.get().*;
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
    // `e::class.simpleName`/`.qualifiedName` for a builtin exception.
    if ((std.mem.eql(u8, name, "simpleName") or std.mem.eql(u8, name, "qualifiedName")) and receiver.* == .Exception) {
        const g = receiver.Exception.fqn.borrow();
        defer g.deinit();
        const fqn = g.get().*;
        const v = if (std.mem.eql(u8, name, "simpleName")) lastSegment(fqn) else fqn;
        return ok(.{ .String = try StringRef.init(allocator, v) });
    }
    // Explicit `recv.coroutineContext` (lowered to this sentinel):
    // bypass the bare-`coroutineContext` redirect for this one read.
    if (std.mem.eql(u8, name, "$coroutineContext$explicit")) {
        return getFieldInner(self, allocator, receiver, "coroutineContext", true, member_probe);
    }
    // Scope-qualified property read (`$sgetter$<owner>\u{1f}<name>`):
    // invoke the lexically enclosing owner's own custom getter.
    if (std.mem.startsWith(u8, name, "$sgetter$")) {
        const rest = name["$sgetter$".len..];
        if (std.mem.indexOfScalar(u8, rest, '\u{1f}')) |sep| {
            const owner = rest[0..sep];
            const prop = rest[sep + 1 ..];
            const pg = self.prog.borrow();
            const fid_opt = lookupPairFunc(pg.get().instance_prop_getters, owner, prop);
            pg.deinit();
            if (fid_opt) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() < mptr.funcs.items.len) {
                    return evalGetter(self, allocator, fid, receiver.*);
                }
            }
            return getFieldInner(self, allocator, receiver, prop, suppress_cc_redirect, member_probe);
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
                return getFieldInner(self, allocator, &scope, "coroutineContext", suppress_cc_redirect, member_probe);
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
    // A bare class/interface name used as a value resolves to its
    // companion object, else the receiver unchanged.
    if (std.mem.eql(u8, name, "<class-companion-or-self>")) {
        if (receiver.* == .Class) {
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
                    .ok => |maybe| if (maybe) |s| return ok(s),
                    .err => |e| return errRes(e),
                }
            }
            if (is_object) {
                switch (try host_globals.ensureObjectSingleton(self, cls_name)) {
                    .ok => |maybe| if (maybe) |s| return ok(s),
                    .err => |e| return errRes(e),
                }
            }
        }
        return ok(receiver.*);
    }
    // Value-class internal-field read on `kotlin.Result` /
    // `ChannelResult`: a bare `value`/`holder` read yields the payload.
    if ((std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "holder")) and receiver.* == .Result) {
        return ok(receiver.Result.payload.*);
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
            const id: u64 = switch (bm.receiver.*) {
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
                    return ok(.{ .String = try StringRef.init(allocator, overridden) });
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return ok(.{ .String = try StringRef.init(allocator, s) });
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
                const enum_name = blk: {
                    const g = receiver.Class.borrow();
                    defer g.deinit();
                    for (g.get().enum_entries) |e| try items.append(allocator, e.value);
                    break :blk g.get().name;
                };
                return ok(try frozenList(allocator, items, try StringRef.init(allocator, enum_name)));
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
            if (info.body_func.int() < mptr.funcs.items.len) {
                const f = &mptr.funcs.items[info.body_func.int()];
                if (std.mem.eql(u8, name, "name")) {
                    return ok(.{ .String = try StringRef.init(allocator, f.name) });
                }
                if (std.mem.eql(u8, name, "parameters")) {
                    var items: std.ArrayList(Value) = .empty;
                    errdefer items.deinit(allocator);
                    for (f.params) |p| {
                        try items.append(allocator, .{ .String = try StringRef.init(allocator, p.name) });
                    }
                    return ok(try frozenList(allocator, items, null));
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
        if (receiver.* != .Instance) break :blk false;
        var cur: ?[]const u8 = className(receiver.Instance);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        var found = false;
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            {
                const pg = self.prog.borrow();
                const hit = lookupPairFunc(pg.get().instance_prop_getters, cn, name) != null;
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
                    dg.deinit();
                }
                cg.deinit();
                if (found) break;
            }
            cur = firstSupertype(self, cn);
        }
        break :blk found;
    };
    // Top-level / supertype / Any extension property.
    if (!member_getter_shadows) {
        const recv_simple: []const u8 = switch (receiver.*) {
            .Instance => |i| className(i),
            else => lastSegment(receiver.typeFqn()),
        };
        const ext_fid = try resolveExtensionProp(self, allocator, receiver, recv_simple, name);
        if (ext_fid) |fid| {
            const mptr: *const Module = self.module.asPtr();
            if (fid.int() >= mptr.funcs.items.len) {
                const msg = try std.fmt.allocPrint(allocator, "extension prop FuncId {d} out of range", .{fid.int()});
                return errRes(.{ .Type = msg });
            }
            // A member-extension property's getter body has its declaring
            // class's `this` in lexical scope; seed the getter frame with
            // the owner instance from the enclosing chain.
            var pushed_owner = false;
            if (mptr.registry.member_ext_owner_class.get(fid)) |owner| {
                if (try host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
            const r = try evalGetter(self, allocator, fid, receiver.*);
            if (pushed_owner) ir.eval.popEnclosing();
            return r;
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
                    break :blk g.get().*;
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
            return ok(.{ .Range = .{ .start = 0, .end = len - 1, .step = 1, .kind = .Int } });
        }
    }
    // `size` on arrays + collections.
    if (std.mem.eql(u8, name, "size")) {
        switch (receiver.*) {
            .Array => |a| return ok(Value.newInt(@intCast(listLen(a.items)))),
            .List => |l| return ok(Value.newInt(@intCast(listLen(l.items)))),
            .Set => |s| return ok(Value.newInt(@intCast(listLen(s.items)))),
            .Map => |m| {
                const g = m.entries.borrow();
                defer g.deinit();
                return ok(Value.newInt(@intCast(g.get().items.len)));
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
    if (!probe_is_toplevel_fn) {
        const probes = [_][]const u8{
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_fqn, name }),
            try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name}),
            try std.fmt.allocPrint(allocator, "kotlin.text.{s}", .{name}),
            try std.fmt.allocPrint(allocator, "kotlin.math.{s}", .{name}),
            try std.fmt.allocPrint(allocator, "kotlin.{s}", .{name}),
        };
        defer for (probes) |p| allocator.free(p);
        for (probes) |probe| {
            if (lookupIntrinsic(self, probe)) |func| {
                const args = [_]Value{receiver.*};
                return dispatchIntrinsic(self, allocator, probe, func, &args);
            }
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
            switch (try getFieldInner(self, allocator, &d, name, suppress_cc_redirect, member_probe)) {
                .ok => |v| if (v != .Unit) return ok(v),
                .err => {},
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
    // Companion fallback for an instance receiver: a companion `val` is
    // in scope unqualified inside the class's own member bodies. The
    // member probe skips it — companions ride the bare-name walk as
    // their own candidates at the owning class's depth.
    if (!member_probe and receiver.* == .Instance) {
        const is_companion_recv = std.mem.indexOf(u8, className(receiver.Instance), "$Companion$") != null;
        var cur: ?[]const u8 = if (is_companion_recv) null else className(receiver.Instance);
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
                const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                    .ok => |maybe| maybe,
                    .err => |e| return errRes(e),
                };
                if (singleton) |s| {
                    if (s == .Instance) {
                        switch (try getFieldInner(self, allocator, &s, name, suppress_cc_redirect, member_probe)) {
                            .ok => |v| if (v != .Unit) return ok(v),
                            .err => {},
                        }
                    }
                }
            }
            cur = firstSupertype(self, cname);
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
            .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => true,
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
                        .Unit, .Function, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => {},
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
            switch (try getFieldInner(self, allocator, &o, name, suppress_cc_redirect, member_probe)) {
                .ok => |v| if (v != .Unit) return ok(v),
                .err => {},
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
    // Bare member of the enclosing class's companion accessed from inside
    // an instance method. Skipped by the member probe (companions are
    // candidates).
    if (!member_probe and receiver.* == .Instance) {
        const cls_name = className(receiver.Instance);
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
                    switch (try getFieldInner(self, allocator, &c, name, suppress_cc_redirect, member_probe)) {
                        .ok => |v| return ok(v),
                        .err => {},
                    }
                }
            }
        }
    }
    const tf = try allocator.dupe(u8, receiverLabel(receiver));
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
fn classReceiverField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
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
        // `Counter.Factory` — the companion name resolves to the
        // companion singleton itself.
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
                    if (fid.int() < mptr.funcs.items.len) {
                        return try evalGetter(self, allocator, fid, s);
                    }
                }
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
    // A nested class registered under its enclosing-qualified FQN
    // (`Outer.Nested`): the exact declaration resolves before any
    // simple-name fallback below can adopt an unrelated namesake from
    // another package.
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
                    switch (try host_globals.ensureObjectSingleton(self, n)) {
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

/// Reflection-style accessors on a `Value::Class` value (`simpleName`,
/// `isData`, `members`, `supertypes`, `sealedSubclasses`, …).
fn classReflective(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    const g = cls.borrow();
    defer g.deinit();
    const cd = g.get();
    if (std.mem.eql(u8, name, "simpleName")) return ok(.{ .String = try StringRef.init(allocator, cd.name) });
    if (std.mem.eql(u8, name, "qualifiedName")) return ok(.{ .String = try StringRef.init(allocator, cd.fqn) });
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
                    if (fid.int() < mg.get().funcs.items.len) {
                        const f = &mg.get().funcs.items[fid.int()];
                        try items.append(allocator, .{ .PropertyRef = .{ .name = try StringRef.init(allocator, f.name) } });
                    }
                }
                break;
            }
        }
        for (cd.primary_params) |p| {
            if (p.property != null) {
                try items.append(allocator, .{ .PropertyRef = .{ .name = try StringRef.init(allocator, p.name) } });
            }
        }
        for (cd.body_properties) |p| {
            try items.append(allocator, .{ .PropertyRef = .{ .name = try StringRef.init(allocator, p.name) } });
        }
        return ok(try frozenList(allocator, items, null));
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
                try items.append(allocator, .{ .String = try StringRef.init(allocator, n) });
            }
        }
        return ok(try frozenList(allocator, items, null));
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
            if (matches) try items.append(allocator, .{ .Class = c.* });
        }
        return ok(try frozenList(allocator, items, null));
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
    return resolveExtensionPropImpl(self, allocator, receiver, recv_simple, name, false);
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
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (lookupPairFunc(Pick.map(pg.get().*), recv_simple, name)) |fid| return fid;
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
    // A `Type.Companion` extension property registers under the outer
    // class name; key the lookup by the outer class.
    if (receiver.* == .Instance) {
        const cls = className(receiver.Instance);
        if (std.mem.indexOf(u8, cls, "$Companion")) |i| {
            const outer = cls[0..i];
            const pg = self.prog.borrow();
            defer pg.deinit();
            if (lookupPairFunc(Pick.map(pg.get().*), outer, name)) |fid| return fid;
        }
    }
    // An `Any` extension property applies to every receiver.
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        if (lookupPairFunc(Pick.map(pg.get().*), "Any", name)) |fid| return fid;
    }
    return null;
}

/// Resolve a field on an `Value::Instance` receiver: delegate getValue,
/// custom getter (with override rules), raw slot (lateinit / built-in
/// delegate auto-unwrap), companion/parent walk, outer-chain, enum
/// entries, nested classes, globals.
fn instanceField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, member_probe: bool) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    const class_name = className(inst);
    // Delegated body property: route through the delegate's `getValue`.
    const delegate_owner: bool = blk: {
        var cur: ?[]const u8 = class_name;
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            try seen.append(allocator, cn);
            {
                const g = self.module.borrow();
                const hit = g.get().registry.delegated_body_props.contains(.{ .a = cn, .b = name });
                g.deinit();
                if (hit) break :blk true;
            }
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
            const prop_ref = Value{ .PropertyRef = .{ .name = try StringRef.init(allocator, name) } };
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
        if (fid.int() >= mptr.funcs.items.len) {
            const msg = try std.fmt.allocPrint(allocator, "getter FuncId {d} out of range", .{fid.int()});
            return errRes(.{ .Type = msg });
        }
        return try evalGetter(self, allocator, fid, receiver.*);
    }
    // Raw instance slot.
    const slot: ?Value = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().get(name);
    };
    if (slot) |v| {
        if (v == .Null) {
            const is_lateinit = blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                for (cg.get().body_properties) |p| {
                    if (std.mem.eql(u8, p.name, name) and p.is_lateinit) break :blk true;
                }
                break :blk false;
            };
            if (is_lateinit) {
                const m = try std.fmt.allocPrint(allocator, "lateinit property {s} has not been initialized", .{name});
                return errRes(.{ .Throw = .{ .Exception = .{
                    .fqn = try StringRef.init(allocator, "kotlin.UninitializedPropertyAccessException"),
                    .message = try StringRef.init(allocator, m),
                    .cause = null,
                } } });
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
                for (cg.get().enum_entries) |e| try items.append(allocator, e.value);
                const ename = cg.get().name;
                const enum_class = try StringRef.init(allocator, ename);
                cg.deinit();
                g.deinit();
                return ok(try frozenList(allocator, items, enum_class));
            }
        }
        cg.deinit();
        g.deinit();
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
    // Top-level global / module-scoped fallback.
    if (!member_probe) {
        const gg = self.globals.borrow();
        defer gg.deinit();
        if (gg.get().lookup(name)) |v| return ok(v);
    }
    return null;
}

/// Resolve an instance custom-getter `FuncId`, applying the
/// most-derived-stored-property override rule and the package-qualified
/// own-class FQN-key discipline.
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
    var cur: ?[]const u8 = if (own_is_qualified) firstSupertypeOf(inst) else class_name;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    while (cur) |cn| {
        cur = null;
        if (containsStr(seen.items, cn)) break;
        try seen.append(allocator, cn);
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
            const hit = lookupPairFunc(pg.get().instance_prop_getters, cn, name);
            pg.deinit();
            if (hit) |fid| {
                found = fid;
                break;
            }
        }
        if (cdef) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            cur = if (dg.get().supertype_names.len > 0) dg.get().supertype_names[0] else null;
        }
    }
    return found;
}

/// True when `cdef` stores `name` as a ctor-param or backing-field body
/// property *without* a custom getter / delegate (overriding any
/// inherited `open val … get()`).
fn declaresStored(cdef: *const ClassDef, name: []const u8) bool {
    for (cdef.primary_params) |p| {
        if (std.mem.eql(u8, p.name, name) and p.property != null) return true;
    }
    for (cdef.body_properties) |p| {
        if (std.mem.eql(u8, p.name, name) and p.getter == null and p.delegate == null) return true;
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
            return errRes(.{ .Throw = .{ .Exception = .{
                .fqn = try StringRef.init(allocator, "kotlin.IllegalStateException"),
                .message = try StringRef.init(allocator, m),
                .cause = null,
            } } });
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
    while (cur_outer) |o| {
        switch (o) {
            .Instance => |outer_inst| {
                {
                    const g = outer_inst.borrow();
                    defer g.deinit();
                    if (g.get().get(name)) |v| return ok(v);
                }
                const oid = outer_inst.identity();
                if (try withFieldResolvePair(self, allocator, oid, name, &o, false, false)) |r| {
                    if (r == .ok and r.ok != .Unit) return r;
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

pub fn setField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
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
    // Extension-property setter — `var T.x set(value) {…}`.
    if (!bypass_setter) {
        const recv_simple: []const u8 = switch (receiver.*) {
            .Instance => |i| className(i),
            else => lastSegment(receiver.typeFqn()),
        };
        const fid: ?FuncId = try resolveExtensionPropSetter(self, allocator, receiver, recv_simple, real_name);
        if (fid) |f| {
            const mptr: *const Module = self.module.asPtr();
            if (f.int() >= mptr.funcs.items.len) {
                const msg = try std.fmt.allocPrint(allocator, "ext setter FuncId {d} out of range", .{f.int()});
                return .{ .err = .{ .Type = msg } };
            }
            // A member-extension property's setter body has its declaring
            // class's `this` in lexical scope; seed the setter frame with
            // the owner instance from the enclosing chain.
            var pushed_owner = false;
            if (mptr.registry.member_ext_owner_class.get(f)) |owner| {
                if (try host_call_member.memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
            const r = try evalSetter(self, allocator, f, receiver.*, value);
            if (pushed_owner) ir.eval.popEnclosing();
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
            const is_delegated: bool = blk: {
                var cur: ?[]const u8 = class_name;
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(allocator);
                while (cur) |cn| {
                    cur = null;
                    if (containsStr(seen.items, cn)) break;
                    try seen.append(allocator, cn);
                    {
                        const g = self.module.borrow();
                        const hit = g.get().registry.delegated_body_props.contains(.{ .a = cn, .b = real_name });
                        g.deinit();
                        if (hit) break :blk true;
                    }
                    cur = firstSupertype(self, cn);
                }
                break :blk false;
            };
            if (is_delegated) {
                const raw: ?Value = blk: {
                    const g = inst.borrow();
                    defer g.deinit();
                    break :blk g.get().get(real_name);
                };
                if (raw) |d| {
                    const prop_ref = Value{ .PropertyRef = .{ .name = try StringRef.init(allocator, real_name) } };
                    switch (try self.callMember(allocator, &d, "setValue", &.{ receiver.*, prop_ref, value })) {
                        .ok => return .{ .ok = {} },
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            // Custom property setter declared on the class or a base.
            const setter_fid: ?FuncId = blk: {
                var cur: ?[]const u8 = class_name;
                var seen: std.ArrayList([]const u8) = .empty;
                defer seen.deinit(allocator);
                while (cur) |cn| {
                    cur = null;
                    if (containsStr(seen.items, cn)) break;
                    try seen.append(allocator, cn);
                    {
                        const pg = self.prog.borrow();
                        const hit = lookupPairFunc(pg.get().instance_prop_setters, cn, real_name);
                        pg.deinit();
                        if (hit) |f| break :blk f;
                    }
                    cur = firstSupertype(self, cn);
                }
                break :blk null;
            };
            if (setter_fid) |fid| {
                const mptr: *const Module = self.module.asPtr();
                if (fid.int() >= mptr.funcs.items.len) {
                    const msg = try std.fmt.allocPrint(allocator, "setter FuncId {d} out of range", .{fid.int()});
                    return .{ .err = .{ .Type = msg } };
                }
                switch (try evalSetter(self, allocator, fid, receiver.*, value)) {
                    .ok => return .{ .ok = {} },
                    .err => |e| return .{ .err = e },
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
            if (!has_own and !is_own_member) {
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
            const g = inst.borrowMut();
            defer g.deinit();
            try g.get().define(allocator, real_name, value);
        }
        return .{ .ok = {} };
    }
    const tf = try allocator.dupe(u8, receiverLabel(receiver));
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
    const func = &mptr.funcs.items[fid.int()];
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
    try fields.append(allocator, .{ .name = "__bound_name__", .value = .{ .String = try StringRef.init(allocator, name) } });
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

/// Anon-method registry key `"<class>\u{1f}<method>"`. The Zig anon
/// registry is keyed on a single string; mirror the Rust `(class, name)`
/// tuple via a unit-separated concatenation cached per-call.
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
fn firstSupertype(self: *VmHost, cn: []const u8) ?[]const u8 {
    const cg = self.classes.borrow();
    defer cg.deinit();
    if (cg.get().get(cn)) |d| {
        const dg = d.borrow();
        defer dg.deinit();
        const sts = dg.get().supertype_names;
        return if (sts.len > 0) sts[0] else null;
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
        .Array => |a| @intCast(listLen(a.items)),
        .List => |l| @intCast(listLen(l.items)),
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk @intCast(utf16Len(g.get().*));
        },
        else => null,
    };
}

// -------------------------------------------------------------------------
// Tests
//
// `host_fields.rs` carries no `#[test]` blocks; these exercise the
// faithful behaviors of the ported dispatch chain that do not require a
// fully wired Vm (the foundation's stubbed siblings).
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
    const lv = Value{ .List = .{
        .items = try ValueList.init(a, list),
        .mutable = false,
        .enum_class = null,
        .backing = null,
    } };
    defer lv.List.items.deinit();
    try testing.expectEqual(@as(i64, 2), collectionLen(&lv).?);

    const s = try StringRef.init(a, "hello");
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
