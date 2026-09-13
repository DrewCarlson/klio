//! The field-read ladder: the ordered chain a property read walks, from the
//! receiver's own storage out to the extension and enclosing-receiver fallbacks.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const root = @import("../../interp_ir.zig");
const host_impl = @import("../host_impl.zig");
const host_globals = @import("../host_globals.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const StdlibFn = runtime.StdlibFn;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const host_fields = @import("../host_fields.zig");
const hostFreeProperty = host_fields.hostFreeProperty;
const missTraceEnvCached = host_fields.missTraceEnvCached;

const common = @import("common.zig");
const activeCoroScope = common.activeCoroScope;
const anonKey = common.anonKey;
const classFqnOf = common.classFqnOf;
const className = common.className;
const collectionLen = common.collectionLen;
const companionSimpleName = common.companionSimpleName;
const containsStr = common.containsStr;
const dispatchIntrinsic = common.dispatchIntrinsic;
const errRes = common.errRes;
const evalGetterTagged = common.evalGetterTagged;
const firstSupertype = common.firstSupertype;
const frozenList = common.frozenList;
const instanceIsHostSynth = common.instanceIsHostSynth;
const lastSegment = common.lastSegment;
const listLen = common.listLen;
const lookupIntrinsic = common.lookupIntrinsic;
const lookupPairFunc = common.lookupPairFunc;
const lookupPairFuncHop = common.lookupPairFuncHop;
const ok = common.ok;
const receiverLabel = common.receiverLabel;
const withFieldResolvePair = common.withFieldResolvePair;

const enum_static = @import("enum_static.zig");
const enclosingEnumDef = enum_static.enclosingEnumDef;
const enclosingEnumEntry = enum_static.enclosingEnumEntry;
const enumStaticNameHits = enum_static.enumStaticNameHits;

const bound_ref = @import("bound_ref.zig");
const classDeclaresStoredProp = bound_ref.classDeclaresStoredProp;
const sgetterNameMatches = bound_ref.sgetterNameMatches;

const read_paths = @import("read_paths.zig");
const builtinMemberProperty = read_paths.builtinMemberProperty;
const declaredBackingZero = read_paths.declaredBackingZero;
const fillCompanionReadMemo = read_paths.fillCompanionReadMemo;
const freeFieldMiss = read_paths.freeFieldMiss;

const class_access = @import("class_access.zig");
const classReceiverField = class_access.classReceiverField;
const classReflective = class_access.classReflective;
const companionInstanceForClass = class_access.companionInstanceForClass;
const enclosingSimpleFromFqn = class_access.enclosingSimpleFromFqn;

const ext_props = @import("ext_props.zig");
const classExtPropUsesCompanion = ext_props.classExtPropUsesCompanion;
const delegateCall = ext_props.delegateCall;
const extPropDelegateInstance = ext_props.extPropDelegateInstance;
const extensionPropRead = ext_props.extensionPropRead;
const memberExtOwnerRead = ext_props.memberExtOwnerRead;
const resolveExtPropDelegate = ext_props.resolveExtPropDelegate;
const resolveExtensionProp = ext_props.resolveExtensionProp;

const instance_field = @import("instance_field.zig");
const declaresStored = instance_field.declaresStored;
const instanceField = instance_field.instanceField;
const unwrapDelegate = instance_field.unwrapDelegate;

const field_cache = @import("field_cache.zig");
const fieldReadCacheGet = field_cache.fieldReadCacheGet;
const lateinitReadError = field_cache.lateinitReadError;
const sgetterCopyMemo = field_cache.sgetterCopyMemo;
const sgetterMemoSafe = field_cache.sgetterMemoSafe;
const sgetterPutGetter = field_cache.sgetterPutGetter;
const storedNullIsLateinit = field_cache.storedNullIsLateinit;

pub fn getFieldInner(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, suppress_cc_redirect: bool, member_probe: bool, suppress_ext: bool) Allocator.Error!EvalResult {
    if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[getfield-enter] recv={s}/{s} name={s} probe={} ext_suppressed={}\n", .{ host_call_member.debugClassNameOf(self, receiver), @tagName(receiver.*), name, member_probe, suppress_ext });
    }
    // The lowerer marks a read whose static receiver type resolves `name` to a
    // member-extension property; a same-named stored field must not shadow it.
    if (std.mem.startsWith(u8, name, "$extread$")) {
        const prop = name["$extread$".len..];
        if (try extensionPropRead(self, allocator, receiver, prop)) |v| return v;
        return getFieldInner(self, allocator, receiver, prop, suppress_cc_redirect, member_probe, suppress_ext);
    }
    // A property of a `by`-delegated interface the class does not override is the
    // delegate's, even when the interface declares a default getter.
    if (receiver.* == .Instance) {
        if (host_call_member.interfaceDelegateFor(self, allocator, receiver.Instance, name)) |d| {
            switch (try getFieldInner(self, allocator, &d, name, suppress_cc_redirect, member_probe, suppress_ext)) {
                .ok => |v| if (v != .Unit) return ok(v),
                .err => |e| if (e == .Unimplemented) freeFieldMiss(allocator, e) else return .{ .err = e },
            }
        }
    }
    // A bare class name in value position resolves to its companion object, else
    // the receiver. Hoisted: the klio-synthetic sentinel no other arm can claim.
    if (std.mem.eql(u8, name, "<class-companion-or-self>")) {
        if (receiver.* == .Class) {
            // Class-static single-fill memo: the resolution never changes once
            // the singleton exists.
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
    // `X.Companion` names the companion explicitly. One only the serialization
    // plugin would write is not declared, so the class value stands in for it.
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
    // Field-read memo, consulted before the whole ladder: entries exist only for
    // (class, name) pairs that fell through every earlier arm and resolved in
    // `instanceField`, both class-static, so a hit cannot shadow an earlier arm.
    // The index re-verifies by name; `coroutineContext` is suspend-state dependent.
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
                        // A scoped-name entry serves the bare-named slot, never
                        // the lateinit/delegate shapes the ladder's arms decide.
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
    // Progression `first`/`last` reads give the stored bound even when empty,
    // unlike the functions; `step` keeps its sign, Int for Int/Char/UInt.
    if (hostFreeProperty(receiver, name)) |v| return ok(v);
    // Reflective reads on a bound member reference (`this::name`).
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
    // `Throwable.stackTrace`: captured frames; an own `stackTrace` field won above.
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
    // `Throwable.suppressedExceptions`: the hidden list `addSuppressed` maintains.
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
    if ((std.mem.eql(u8, name, "simpleName") or std.mem.eql(u8, name, "qualifiedName")) and receiver.* == .Exception) {
        const g = receiver.Exception.fqn.borrow();
        defer g.deinit();
        const fqn = g.get().bytes;
        const v = if (std.mem.eql(u8, name, "simpleName")) lastSegment(fqn) else fqn;
        return ok(.{ .String = try runtime.strInit(allocator, v) });
    }
    // Explicit `recv.coroutineContext`: bypass the bare-name redirect once.
    if (std.mem.eql(u8, name, "$coroutineContext$explicit")) {
        return getFieldInner(self, allocator, receiver, "coroutineContext", true, member_probe, suppress_ext);
    }
    // Scope-qualified read (`$sgetter$<owner>\u{1f}<name>`): a bare read inside a
    // method. Kotlin dispatches it virtually, so an `open val` overridden in a
    // subclass calls the subclass's getter even from a base-class method. Resolve
    // from the runtime class most-derived first; lexical `owner` is the fallback.
    if (std.mem.startsWith(u8, name, "$sgetter$")) {
        const rest = name["$sgetter$".len..];
        if (std.mem.findScalar(u8, rest, '\u{1f}')) |sep| {
            const owner = rest[0..sep];
            const prop = rest[sep + 1 ..];
            const mptr: *const Module = self.module.asPtr();
            // Reject a foreign implicit receiver before virtual getter or stored
            // lookup, so its same-named member cannot win ahead of the enclosing
            // lexical receiver. When `owner` declares no such property it may.
            if (member_probe and receiver.* == .Instance) {
                const rcn = className(receiver.Instance);
                // The module walk answers from registered class rows, and an anon
                // object's row carries no name-keyed supertype edge, so the
                // value-level runtime chain is an equal authority on ownership.
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
            // A private shadow of a supertype's same-name declaration has its own
            // storage cell under the owner-mangled key, leaving the base's alone.
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
                // The shadow cell is keyed by its declaring class, so a read from
                // an inner scope whose sgetter `owner` is not that class must key
                // by the captured receiver's own class. Only when `owner` declares
                // no stored `prop`: a base-class method binds to the base's cell.
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
                    // implementation: stop before an inherited computed getter. A
                    // private field is excepted, never joining override dispatch.
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
                        // A private never joins override dispatch: a same-named
                        // private outside the lexical owner is a different
                        // declaration. Skip it; inherited public getters resolve.
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
            // Run the lexical `owner`'s getter only when the receiver is an
            // instance of `owner`. In a member probe a foreign candidate falls
            // through to the bare-name lookup, or reports a miss to walk outward.
            const owner_applies = !member_probe or receiver.isRuntimeType(owner) or
                (receiver.* == .Instance and blk: {
                    // The value-level runtime-type check misses native-backed and
                    // pack-loaded subtype chains that only the module walk sees.
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
                        // Inside an inline receiver-splice the frame's `this` is
                        // the splice receiver, so the getter runs on the enclosing
                        // owner instance. Ownership is the module subtype walk.
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
                            // Memoizable only when a member probe takes this same
                            // terminal, the probe's gate being both checks.
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
                // Memoizable only when no lexical-owner getter exists, both
                // execution modes then reaching this recursion.
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
    // Suspend-implicit `coroutineContext`: redirect a bare read to the active
    // coroutine scope's context. With no scope on the driver stack the ambient
    // context is empty, every Kotlin suspend function having one.
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
                // A scope from the stdlib `Continuation(context) {}` factory
                // declares only `context`; prefer `coroutineContext`, then empty.
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
            // No driver scope and no own property: the ambient context is empty.
            switch (try host_globals.ensureObjectSingleton(self, "EmptyCoroutineContext")) {
                .ok => |maybe| if (maybe) |v| return ok(v),
                .err => |e| return errRes(e),
            }
        }
    }
    // Value-class internal read: `value`/`holder` is the wrapped payload.
    if ((std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "holder")) and receiver.* == .Result) {
        const out = receiver.Result.payload.asPtr().*;
        out.retain();
        return ok(out);
    }
    // Backing-field bypass: `field` lowers to this synthetic name, read raw.
    if (std.mem.startsWith(u8, name, "__klio_field__") and receiver.* == .Instance) {
        const raw = name["__klio_field__".len..];
        const g = receiver.Instance.borrow();
        defer g.deinit();
        if (g.get().get(raw)) |v| return ok(v);
        return ok(.Null);
    }
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
                // A dispatcher pool worker reports its registered upstream name.
                if (runtime.threadName(allocator, id)) |overridden| {
                    return ok(.{ .String = try runtime.strInitOwned(allocator, overridden) });
                }
                const s = try std.fmt.allocPrint(allocator, "klio-thread-{d}", .{id});
                return ok(.{ .String = try runtime.strInitOwned(allocator, s) });
            }
        }
    }
    if (receiver.* == .Class) {
        const is_enum = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk g.get().is_enum;
        };
        if (is_enum) {
            // A first read of an entry or of `entries` initializes the enum.
            if (enumStaticNameHits(receiver.Class, name)) {
                if (try host_globals.ensureEnumInit(self, receiver.Class)) |e| return .{ .err = e };
            }
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
    if (receiver.* == .IrClosure) {
        const id = receiver.IrClosure.asPtr().id;
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
    if (receiver.* == .Class) {
        if (try classReceiverField(self, allocator, receiver, name)) |v| return v;
    }
    // A member property outranks a same-named extension property, so skip the
    // extension lookup when the hierarchy declares a member getter.
    const member_getter_shadows = blk: {
        // A builtin receiver's own member property outranks a same-named extension
        // too, so `val LongArray.size` does not capture `a.size` and recurse.
        if (builtinMemberProperty(receiver, name)) break :blk true;
        if (receiver.* != .Instance) break :blk false;
        var cur: ?[]const u8 = className(receiver.Instance);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        var found = false;
        while (cur) |cn_raw| {
            // A dotted nested supertype registers under a mangled key; canonicalize.
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
            // A declared member property, body or constructor-parameter, also
            // outranks a same-named extension; Kotlin resolves the member first.
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
                    // Prefer the resolved parent link; the first supertype name
                    // may be an interface.
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
    if (!member_getter_shadows and !suppress_ext) {
        // A `val X.Companion.name` extension registers under `X`'s simple name.
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
            // A companion extension's getter `this` is the companion instance;
            // route the class value to it. A KClass/Any extension keeps the class.
            var getter_recv = receiver.*;
            if (receiver.* == .Class and try classExtPropUsesCompanion(self, allocator, recv_simple, name)) {
                if (try companionInstanceForClass(self, recv_simple)) |comp| getter_recv = comp;
            }
            // A member-extension getter body has its declaring class's `this` in
            // scope; seed the frame from the enclosing chain.
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
        // Delegated extension property (`val R.x by expr`): materialise the
        // delegate once per property, then read `getValue(thisRef, property)`.
        if (try resolveExtPropDelegate(self, allocator, receiver, recv_simple, name)) |hit| {
            const d = try extPropDelegateInstance(self, allocator, hit.key, name, hit.fid);
            const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInit(allocator, name) } };
            return try delegateCall(self, allocator, &d, "getValue", &.{ receiver.*, prop_ref }, receiver);
        }
    }
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
                // A top-level `lateinit var` is initialized once its global exists.
                if (host_globals.registryHasLateinitProp(self, prop_name)) {
                    const g = self.globals.borrow();
                    defer g.deinit();
                    return ok(.{ .Bool = g.get().lookup(prop_name) != null });
                }
                return ok(.{ .Bool = false });
            }
        },
        else => {},
    }
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
    // `x.data` reinterprets an unsigned inline type as its signed counterpart.
    if (std.mem.eql(u8, name, "data")) {
        switch (receiver.*) {
            .UByte => |x| return ok(.{ .Byte = @bitCast(x) }),
            .UShort => |x| return ok(.{ .Short = @bitCast(x) }),
            .UInt => |x| return ok(.{ .Int = @bitCast(x) }),
            .ULong => |x| return ok(.{ .Long = @bitCast(x) }),
            else => {},
        }
    }
    // Unsigned arrays are value classes over signed storage, so writes through
    // the view must land in the original: share the cell, carry the view kind.
    if (std.mem.eql(u8, name, "storage") and receiver.* == .Array) {
        const a = receiver.Array;
        if (a.primKind()) |k| {
            if (k.signedCounterpart()) |signed| {
                if (a.storage() == .scalars) {
                    return ok(.{ .Array = runtime.ArrayData.scalars(a.storage().scalars.clone(), signed) });
                }
            }
        }
    }
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
    // Stdlib property read on a built-in type, `"abc".length` and the like.
    const type_fqn = receiver.typeFqn();
    const probe_is_toplevel_fn = stdlib.isToplevelFunction(name);
    // `kotlin.math.min`/`max` are binary functions, not accessors: with the
    // receiver as their lone argument they return it, masking the read.
    if (!probe_is_toplevel_fn and !stdlib.isBinaryMathFunction(name)) {
        // The winning probe, or a confirmed miss, is a pure function of
        // (receiver type, name); memoize it on the program image.
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
                // A bare uppercase name is a companion/type reference, whose root
                // `kotlin.<Name>` binding is a conversion intrinsic, not a property.
                if (name.len > 0 and std.ascii.isUpper(name[0])) {
                    const dot = std.mem.findScalarLast(u8, probe, '.') orelse 0;
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
            // An uncached winner's `resolved.fqn` is the request-lifetime dupe.
        }
        if (resolved) |entry| {
            const args = [_]Value{receiver.*};
            const r = try dispatchIntrinsic(self, allocator, entry.fqn, entry.func.?, &args);
            // A strict member probe must not surface a `Type` error from an
            // intrinsic that does not apply here: that is a miss, not an accessor
            // that threw. Outside a probe the wrong-type error propagates.
            if (member_probe and r == .err and r.err == .Type) {
                ir.eval.dumpFrameChainForDiag();
                return errRes(.{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::get_field `{s}` on `{s}`", .{ name, type_fqn }) });
            }
            return r;
        }
    }
    // Class-delegation forwarding: only the properties the delegated interface
    // declares, never extensions or unrelated names.
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
                // Only the dispatch-miss sentinel means "no such member".
                .err => |e| if (e == .Unimplemented) freeFieldMiss(allocator, e) else return .{ .err = e },
            }
        }
    }
    // `Long.MAX_VALUE` and friends, via the primitive-companion table.
    if (receiver.* == .Class) {
        const simple = blk: {
            const g = receiver.Class.borrow();
            defer g.deinit();
            break :blk lastSegment(g.get().name);
        };
        if (stdlib.primitive_companion_const(simple, name)) |v| return ok(v);
    }
    // A bare `Nested` inside `Outer`'s body is the nested classifier, not a
    // same-named companion member; the FQN nesting tree covers baked packs too.
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
                // A private nested object lifts under `Outer$Name` in the registry.
                const lifted: ?[]const u8 = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    if (cid.int() >= mg.get().classes.items.len) break :blk null;
                    break :blk mg.get().classes.items[cid.int()].name;
                };
                if (lifted) |ln| {
                    if (!std.mem.eql(u8, ln, fqn)) {
                        switch (try host_globals.ensureObjectSingleton(self, ln)) {
                            .ok => |maybe| if (maybe) |v| {
                                if (v == .Instance) return ok(v);
                            },
                            .err => |e| return errRes(e),
                        }
                    }
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
    // Companion fallback: a companion `val` is unqualified in the class's bodies.
    if (!member_probe and receiver.* == .Instance) {
        const is_companion_recv = std.mem.find(u8, className(receiver.Instance), "$Companion$") != null;
        var cur: ?[]const u8 = if (is_companion_recv) null else className(receiver.Instance);
        // The first hop's enclosing class comes from the receiver's FQN, whose
        // nesting is unambiguous; `enclosing_class` keys only by simple name.
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
                // The bare name is this class's or an inherited interface's own
                // companion simple name: the singleton itself, not a member of it.
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
                            // A companion read that threw is the outcome, not a miss.
                            .err => |e| if (e == .Throw) return errRes(e) else freeFieldMiss(allocator, e),
                        }
                    }
                }
            }
            // A private nested object lifts under the mangled `Owner$Name`.
            {
                var mbuf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&mbuf, "{s}${s}", .{ cname, name })) |mangled| {
                    switch (try host_globals.ensureObjectSingleton(self, mangled)) {
                        .ok => |maybe| if (maybe) |v| {
                            if (v == .Instance) return ok(v);
                        },
                        .err => |e| return errRes(e),
                    }
                } else |_| {}
            }
            // Supertypes before the enclosing-class chain: a member of an
            // enclosing companion outranks a same-named global found below.
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
    // A top-level function must not outrank a property of an enclosing implicit
    // receiver: try that receiver first, adopting only a non-callable result.
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
    // A bare top-level `const val` inside an extension body resolves as a global.
    // The member probe never adopts one; the walk's terminal arm decides that tier.
    if (!member_probe) {
        if (try memberExtOwnerRead(self, allocator, receiver, name)) |r| return r;
        {
            const gg = self.globals.borrow();
            defer gg.deinit();
            if (gg.get().lookup(name)) |v| return ok(v);
        }
        if (self.lookupGlobal(name)) |v| return ok(v);
        switch (try host_impl.ensureTopLevelInited(self, name)) {
            .ok => |maybe| if (maybe) |v| return ok(v),
            .err => |e| return errRes(e),
        }
    }
    // Enclosing-receiver fallback: a bare read inside a member-extension or
    // receiver-lambda body may name a member of the enclosing class instance.
    if (!member_probe) {
        // The chain is innermost-first, so every entry is a candidate.
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
    // Inner-class fallback: walk the receiver's captured `outer` link.
    if (!member_probe and !self.tls.field_outer_active) {
        self.tls.field_outer_active = true;
        defer self.tls.field_outer_active = false;
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
                // Only the dispatch-miss sentinel is a walkable miss.
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
    // Bare member of the companion of the receiver's class or any enclosing one,
    // reached by walking the enclosing chain. The member probe skips it.
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
    // Native property getter on a host-synthesised instance, last resort:
    // `typeFqn()` is `<instance>` for any `Instance`, so the stdlib probe above
    // never keys on the class. Such a class binds properties zero-arg as
    // `<classFqn>.<name>`; other receivers still report the miss.
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
    // `@Serializer(forClass = C::class)`: `descriptor` is plugin-generated.
    if (try host_call_member.serializerForClassTarget(self, allocator, receiver)) |ser| {
        defer ser.release(allocator);
        const forwarded = try getFieldInner(self, allocator, &ser, name, suppress_cc_redirect, member_probe, suppress_ext);
        switch (forwarded) {
            .ok => return forwarded,
            .err => |e| freeFieldMiss(allocator, e),
        }
    }
    // An enum's static scope encloses its companion, nested objects and entries.
    {
        const plain = blk: {
            const prefix = "$sgetter$";
            if (std.mem.startsWith(u8, name, prefix)) {
                const rest = name[prefix.len..];
                if (std.mem.findScalar(u8, rest, '\u{1f}')) |sep| break :blk rest[sep + 1 ..];
            }
            break :blk name;
        };
        if (enclosingEnumEntry(self, receiver, plain)) |ev| {
            if (runtime.reclaimEnabled()) ev.retain();
            return .{ .ok = ev };
        }
        if (std.mem.eql(u8, plain, "entries")) {
            if (enclosingEnumDef(self, receiver)) |def| {
                defer def.deinit();
                const cls_val: Value = .{ .Class = def.clone() };
                defer if (runtime.reclaimEnabled()) cls_val.release(allocator);
                const forwarded = try getFieldInner(self, allocator, &cls_val, plain, suppress_cc_redirect, member_probe, suppress_ext);
                switch (forwarded) {
                    .ok => return forwarded,
                    .err => |e| freeFieldMiss(allocator, e),
                }
            }
        }
    }
    // A declared backing field with no slot yet: the instance is under
    // construction, reached through a superclass `init` calling an override. The
    // JVM zero is materialized here; filling at allocation doubles residency.
    if (receiver.* == .Instance) {
        if (declaredBackingZero(self, receiver, name)) |zero| {
            const g = receiver.Instance.borrowMut();
            defer g.deinit();
            if (g.get().get(name) == null) {
                try g.get().ensureFieldsOwned(allocator, 1);
                try g.get().fields.append(allocator, .{ .name = name, .value = zero });
                g.get().invalidateShape();
            }
            return .{ .ok = zero };
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
