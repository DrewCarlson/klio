//! The extension-function fallback walk: candidate collection, scoring, the cached
//! serve path, and the companion forwards it ends on.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const VmHost = vmhost.VmHost;
const trace = @import("../trace.zig");
const overload_match = @import("../overload_match.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_value = @import("../host_call_value.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ClassDef = runtime.ClassDef;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const applicExactHeadCbM = applicability_probe.applicExactHeadCbM;
const applicExtOwnerRankCb = applicability_probe.applicExtOwnerRankCb;
const applicExtRecvMatchCb = applicability_probe.applicExtRecvMatchCb;
const applicExtSubtypeNameCb = applicability_probe.applicExtSubtypeNameCb;
const applicIdentityConflictCbM = applicability_probe.applicIdentityConflictCbM;
const applicKnownPackageCb = applicability_probe.applicKnownPackageCb;
const applicRefineCbM = applicability_probe.applicRefineCbM;
const applicSubtypeCbM = applicability_probe.applicSubtypeCbM;
const funcDefaults = applicability_probe.funcDefaults;
const paramHasDefault = applicability_probe.paramHasDefault;
const rangeContainsArgKindMatches = applicability_probe.rangeContainsArgKindMatches;
const receiverDefinitelyNotParam = applicability_probe.receiverDefinitelyNotParam;
const runtimeMemberApplicability = applicability_probe.runtimeMemberApplicability;
const shapeOfValueMember = applicability_probe.shapeOfValueMember;
const sigViewOfMember = applicability_probe.sigViewOfMember;

const binding_probe = @import("binding_probe.zig");
const delegateFieldAt = binding_probe.delegateFieldAt;

const caches = @import("caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const extMethodCacheGet = caches.extMethodCacheGet;
const extMethodCachePut = caches.extMethodCachePut;

const flat_call = @import("flat_call.zig");
const prependReceiver = flat_call.prependReceiver;
const receiverHasMemberNamed = flat_call.receiverHasMemberNamed;

const hcm = @import("../host_call_member.zig");
const callFuncRec = hcm.callFuncRec;
const callMemberRec = hcm.callMemberRec;
const checkFuncInRange = hcm.checkFuncInRange;
const checkOverloadUnique = hcm.checkOverloadUnique;
const lookupIntrinsic = hcm.lookupIntrinsic;
const simpleName = hcm.simpleName;

const member_ext_visibility = @import("member_ext_visibility.zig");
const collectClassClosure = member_ext_visibility.collectClassClosure;
const enclosingOwnerSet = member_ext_visibility.enclosingOwnerSet;
const isMemberExt = member_ext_visibility.isMemberExt;
const isMemberExtFid = member_ext_visibility.isMemberExtFid;
const memberExtOwnerObjectClass = member_ext_visibility.memberExtOwnerObjectClass;
const memberExtVisible = member_ext_visibility.memberExtVisible;
const privateFnHiddenHere = member_ext_visibility.privateFnHiddenHere;

const member_presence = @import("member_presence.zig");
const enclosingThisChain = member_presence.enclosingThisChain;
const hostHasMember = member_presence.hostHasMember;

const named_call = @import("named_call.zig");
const committedExtReceiverProven = named_call.committedExtReceiverProven;

const receiver_probe = @import("receiver_probe.zig");
const applicTypeVarCbM = receiver_probe.applicTypeVarCbM;
const candidateArgsDisproven = receiver_probe.candidateArgsDisproven;
const closureParamsDisproveFnParam = receiver_probe.closureParamsDisproveFnParam;
const declArityRefuses = receiver_probe.declArityRefuses;
const enclosingCallableProperty = receiver_probe.enclosingCallableProperty;
const extArityApplicableTL = receiver_probe.extArityApplicableTL;
const isCallable = receiver_probe.isCallable;
const receiverCompatibleWithParam = receiver_probe.receiverCompatibleWithParam;
const receiverImplementsOwnerIdentity = receiver_probe.receiverImplementsOwnerIdentity;
const receiverImplementsType = receiver_probe.receiverImplementsType;
const receiverViolatesTypeParamBound = receiver_probe.receiverViolatesTypeParamBound;
const staticReceiverApplicable = receiver_probe.staticReceiverApplicable;
const strictReceiverProven = receiver_probe.strictReceiverProven;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const root_mod = reflect_anon.root_mod;

const slot_ops = @import("slot_ops.zig");
const rangeElemTypeName = slot_ops.rangeElemTypeName;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const missTraceEnv = static_tail.missTraceEnv;
const missTraceWant = static_tail.missTraceWant;

const stdlib_tail = @import("stdlib_tail.zig");
const numericWidthKind = stdlib_tail.numericWidthKind;

const virtual_tail = @import("virtual_tail.zig");
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;

pub const Candidate = struct { fid: FuncId, func: Func };

/// Whether the declared receiver names a builtin shape this value definitely
/// is not. Instances stay unproven; their hierarchies decide elsewhere.
pub fn builtinReceiverDisproven(receiver: *const Value, declared: []const u8) bool {
    const unsigned_arrays = [_][]const u8{ "UIntArray", "ULongArray", "UShortArray", "UByteArray" };
    switch (receiver.*) {
        .Array => |arr| {
            for (unsigned_arrays) |ua| {
                if (std.mem.eql(u8, declared, ua)) {
                    const view = arr.primKind() orelse return true;
                    // `typeFqn` names the array type; the kind's own
                    // simpleName is the element name.
                    return !std.mem.eql(u8, simpleName(view.typeFqn()), declared);
                }
            }
            return false;
        },
        // Array types are final, so a user instance is never one.
        .Instance => |inst| {
            if (overload_match.builtinParamKind(declared)) |pk| {
                if (pk != .array) return false;
                // A user class spelled like a builtin array is the declared
                // receiver of its own extensions.
                const ig = inst.borrow();
                defer ig.deinit();
                const cg = ig.get().class.borrow();
                defer cg.deinit();
                return !std.mem.eql(u8, simpleName(cg.get().name), declared);
            }
            return false;
        },
        else => return false,
    }
}

/// Resolve a candidate's declared receiver simple name to a class FQN in the
/// candidate's own declaration-file scope: named imports, then its package,
/// then wildcard imports. Null when no known class matches. Receivers of the
/// same simple name in different packages resolve to distinct FQNs.
pub fn resolveExtReceiverFqn(allocator: Allocator, mod: *const Module, c: *const Candidate) ?[]const u8 {
    if (c.func.params.len == 0) return null;
    const nm = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
    if (std.mem.findScalar(u8, nm, '.') != null) {
        if (mod.classIdByFqn(nm)) |cid| return mod.classFqnById(cid);
    }
    const simple = simpleName(nm);
    const ds = mod.decl_span.get(c.fid.int()) orelse return null;
    const file = ds.file;
    for (mod.importAliasPathsIn(file, simple)) |p| {
        if (mod.classIdByFqn(p.fqn)) |cid| return mod.classFqnById(cid);
    }
    if (c.func.package.len != 0) {
        const cand = std.fmt.allocPrint(allocator, "{s}.{s}", .{ c.func.package, simple }) catch return null;
        defer if (runtime.freeScratch()) allocator.free(cand);
        if (mod.classIdByFqn(cand)) |cid| return mod.classFqnById(cid);
    }
    if (mod.registry.import_wildcards.get(file)) |list| {
        for (list.items) |pkg| {
            const cand = std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, simple }) catch return null;
            defer if (runtime.freeScratch()) allocator.free(cand);
            if (mod.classIdByFqn(cand)) |cid| return mod.classFqnById(cid);
        }
    }
    return null;
}

/// Drop cross-package extension twins the runtime receiver rules out: when one
/// candidate's resolved receiver FQN equals the receiver's class FQN, every
/// other candidate of that receiver simple name resolving elsewhere is dropped.
pub fn narrowSameNameExtensionTwins(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: *std.ArrayList(Candidate)) void {
    if (receiver.* != .Instance) return;
    if (candidates.items.len < 2) return;
    const recv_fqn: []const u8 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const n = candidates.items.len;
    const fqns = allocator.alloc(?[]const u8, n) catch return;
    defer allocator.free(fqns);
    for (candidates.items, 0..) |*c, i| fqns[i] = resolveExtReceiverFqn(allocator, mod, c);
    const remove = allocator.alloc(bool, n) catch return;
    defer allocator.free(remove);
    for (remove) |*r| r.* = false;
    var any_removed = false;
    for (candidates.items, 0..) |*c, i| {
        if (c.func.params.len == 0) continue;
        const simple_i = simpleName(std.mem.trimEnd(u8, c.func.params[0].ty.name, "?"));
        var exact_present = false;
        for (candidates.items, 0..) |*o, j| {
            if (o.func.params.len == 0) continue;
            const simple_j = simpleName(std.mem.trimEnd(u8, o.func.params[0].ty.name, "?"));
            if (!std.mem.eql(u8, simple_i, simple_j)) continue;
            const fj = fqns[j] orelse continue;
            if (std.mem.eql(u8, fj, recv_fqn)) {
                exact_present = true;
                break;
            }
        }
        if (!exact_present) continue;
        const fi = fqns[i] orelse continue; // unresolvable, keep
        if (!std.mem.eql(u8, fi, recv_fqn)) {
            remove[i] = true;
            any_removed = true;
        }
    }
    if (!any_removed) return;
    var filtered: std.ArrayList(Candidate) = .empty;
    for (candidates.items, 0..) |cc, i| {
        if (!remove[i]) filtered.append(allocator, cc) catch {};
    }
    candidates.deinit(allocator);
    candidates.* = filtered;
}

/// Serve a memoized member-extension winner: re-find its owner on the
/// enclosing chain and invoke it with that owner pushed. The entry is keyed on
/// chain shape, so it declines when the shape differs from the resolved one.
pub fn serveCachedMemberExt(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, args: []const Value) Allocator.Error!?EvalResult {
    const mg = self.module.borrow();
    const mod = mg.get();
    const f = funcAt(mod, fid) orelse {
        mg.deinit();
        return null;
    };
    if (!f.hasBody() or f.params.len != args.len + 1) {
        mg.deinit();
        return null;
    }
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse {
        mg.deinit();
        return null;
    };
    const inst_opt = memberExtOwnerInstance(self, allocator, receiver, owner) catch {
        mg.deinit();
        return null;
    };
    const inst = inst_opt orelse {
        mg.deinit();
        return null;
    };
    if (inst != .Instance) {
        mg.deinit();
        return null;
    }
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    ir.eval.pushEnclosing(&inst);
    const r = try callFuncRec(self, allocator, mod, fid, all);
    ir.eval.popEnclosing();
    mg.deinit();
    return r;
}

pub fn extFbCounts() [4]u64 {
    return .{ hcm.ext_fb_total, hcm.ext_fb_plain_hit, hcm.ext_fb_chain_hit, hcm.ext_fb_walk };
}

pub fn extensionFnFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, declared_recv: ?[]const u8) Allocator.Error!?EvalResult {
    // The winner is a pure function of (receiver identity, name, arg sig,
    // scope, strict bit) unless a member-extension competes: its applicability
    // rides the enclosing-`this` chain, so `saw_member_ext` vetoes the store.
    runtime.prof.opRoute(3);
    hcm.ext_fb_total += 1;
    var cache_key: ?root_mod.ProgramImage.InstanceMethodKey =
        instanceMethodKeyScoped(self, receiver, name, args, static_recv, declared_recv);
    if (cache_key != null and strict_ext) {
        cache_key.?.sig ^= 0xA5A5_5A5A_C0DE_F00D;
        if (cache_key.?.sig == 0) cache_key.?.sig = 1;
    }
    if (cache_key) |k| {
        if (extMethodCacheGet(self, k)) |fid| {
            hcm.ext_fb_plain_hit += 1;
            if (fid == METHOD_MISS) return null;
            if (missTraceWant(name)) std.debug.print("[extfb] PLAIN-HIT fid={d} name={s} member_ext={}\n", .{ fid, name, isMemberExtFid(self, @enumFromInt(fid)) });
            if (try invokeMethodFuncId(self, allocator, receiver, @enumFromInt(fid), args)) |r| return r;
        }
    }
    // Chain-folded key: with a member-extension in play the resolution is a
    // pure function of (key, enclosing-chain shape), so folding the chain hash
    // keys those calls too.
    const chain_key: ?root_mod.ProgramImage.InstanceMethodKey = blk: {
        var ck = cache_key orelse break :blk null;
        ck.sig ^= ir.eval.enclosingChainClassHash() *% 0x9E3779B97F4A7C15;
        if (ck.sig == 0) ck.sig = 2;
        break :blk ck;
    };
    if (chain_key) |k| {
        if (extMethodCacheGet(self, k)) |fid| {
            hcm.ext_fb_chain_hit += 1;
            if (fid == METHOD_MISS) return null;
            const f: FuncId = @enumFromInt(fid);
            if (isMemberExtFid(self, f)) {
                if (try serveCachedMemberExt(self, allocator, receiver, f, args)) |r| return r;
            } else if (try invokeMethodFuncId(self, allocator, receiver, f, args)) |r| return r;
        }
    }
    var saw_member_ext = false;
    if (runtime.envSetOnce("KLIO_WALK_TRACE")) {
        std.debug.print("[extfb-walk] {s} on {s} strict={} static={s} keyed={}\n", .{ name, receiver.typeFqn(), strict_ext, static_recv orelse "-", cache_key != null });
    }
    hcm.ext_fb_walk += 1;
    const r = try extensionFnFallbackWalk(self, allocator, receiver, name, args, strict_ext, static_recv, declared_recv, cache_key, chain_key, &saw_member_ext);
    if (r == null) {
        if (!saw_member_ext) {
            if (cache_key) |k| extMethodCachePut(self, k, METHOD_MISS);
        } else if (chain_key) |k| {
            extMethodCachePut(self, k, METHOD_MISS);
        }
    }
    return r;
}

/// The full candidate walk. `cache_key` is the scope-folded key (null when the
/// call is uncacheable); `saw_member_ext_out` reports whether a member-extension
/// competed, which vetoes both positive and negative memoization.
pub fn extensionFnFallbackWalk(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, strict_ext: bool, static_recv: ?[]const u8, declared_recv: ?[]const u8, cache_key: ?root_mod.ProgramImage.InstanceMethodKey, chain_key: ?root_mod.ProgramImage.InstanceMethodKey, saw_member_ext_out: *bool) Allocator.Error!?EvalResult {
    var bound_thinned = false;
    ir.eval.callStatsProbe(name);
    const want = args.len + 1;
    if (missTraceWant(name)) {
        const rk: []const u8 = switch (receiver.*) {
            .Instance => |inst| blk: {
                const g = inst.borrow();
                defer g.deinit();
                const cg = g.get().class.borrow();
                defer cg.deinit();
                break :blk cg.get().fqn;
            },
            else => receiver.typeFqn(),
        };
        std.debug.print("[extfb] ENTRY strict={} nargs={d} recv={s} static={s} declared={s}\n", .{
            strict_ext, args.len, rk, static_recv orelse "-", declared_recv orelse "-",
        });
    }

    var visible_owners = try enclosingOwnerSet(self, allocator);
    defer visible_owners.deinit();

    saw_member_ext_out.* = false;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        const mtrace = if (missTraceEnv()) |w| std.mem.eql(u8, w, name) else false;
        if (mtrace) {
            std.debug.print("[extfb] name={s} simple-name fids={d} want={d} args:", .{ name, mod.funcsBySimpleName(name).len, want });
            for (args) |*a| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(a.*))});
            std.debug.print("\n", .{});
        }
        for (mod.funcsBySimpleName(name)) |fid| {
            const f = funcAt(mod, fid) orelse continue;
            if (!(f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"))) {
                if (mtrace) std.debug.print("[extfb]  fid={d} shape-skip nparams={d}\n", .{ fid.int(), f.params.len });
                continue;
            }
            const has_vararg = blk: {
                for (f.params) |*p| {
                    if (p.is_vararg) break :blk true;
                }
                break :blk false;
            };
            if (f.params.len < want and !has_vararg) {
                if (mtrace) std.debug.print("[extfb]  fid={d} shape-skip nparams={d}\n", .{ fid.int(), f.params.len });
                continue;
            }
            // Surplus declared params beyond the supplied args are fillable
            // only when each carries a default or is a vararg.
            if (f.params.len > want) {
                const defaults = funcDefaults(self, &f);
                // A trailing callable binds the last declared parameter, so
                // the fillable gap sits between the args and that slot.
                const last_arg_callable = args.len > 0 and switch (args[args.len - 1]) {
                    .IrClosure => true,
                    else => false,
                };
                const last_param_fn = std.mem.startsWith(u8, f.params[f.params.len - 1].ty.name, "Function") or
                    std.mem.eql(u8, f.params[f.params.len - 1].ty.name, "<function>");
                var lo: usize = want;
                var hi: usize = f.params.len;
                if (last_arg_callable and last_param_fn) {
                    lo = want - 1;
                    hi = f.params.len - 1;
                }
                var fillable = true;
                var k: usize = lo;
                while (k < hi) : (k += 1) {
                    if (!(f.params[k].is_vararg or paramHasDefault(defaults, k))) {
                        fillable = false;
                        break;
                    }
                }
                if (!fillable) {
                    if (mtrace) std.debug.print("[extfb]  fid={d} surplus-skip nparams={d}\n", .{ fid.int(), f.params.len });
                    continue;
                }
            }
            if (isMemberExt(mod, fid)) saw_member_ext_out.* = true;
            if (privateFnHiddenHere(self, mod, fid)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} private-skip\n", .{fid.int()});
                continue;
            }
            if (!memberExtVisible(self, mod, fid, &visible_owners)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} owner-skip\n", .{fid.int()});
                continue;
            }
            // A bodyless header is not executable: selecting it re-enters
            // `callFunc`'s bodyless ladder and cycles.
            if (!host_call_func.executableForm(self, mod, fid, want)) {
                if (mtrace) std.debug.print("[extfb]  fid={d} bodyless-skip\n", .{fid.int()});
                continue;
            }
            if (mtrace) std.debug.print("[extfb]  fid={d} CANDIDATE recv={s}\n", .{ fid.int(), if (mod.decl_sigs.get(fid.int())) |sg| (if (sg.receiver_ty) |rt| rt.name else "-") else "-" });
            try candidates.append(allocator, .{ .fid = fid, .func = f });
        }
    }

    // A low-priority candidate (`@Deprecated(level = ERROR/HIDDEN)`,
    // `@LowPriorityInOverloadResolution`) applies only when no ordinary one does.
    {
        var any_ordinary = false;
        for (candidates.items) |c| {
            if (!c.func.low_priority) {
                any_ordinary = true;
                break;
            }
        }
        if (any_ordinary) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (!c.func.low_priority) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        }
    }

    // Receiver-type filter. The strict probe (the bare-name resolver's
    // innermost-first walk) demands a proven receiver match so an inapplicable
    // extension cannot bind at an inner receiver and pre-empt a member of an
    // outer one. The lenient form scores anyway.
    if (strict_ext) {
        var filtered: std.ArrayList(Candidate) = .empty;
        for (candidates.items) |c| {
            if (c.func.low_priority) continue;
            // Extension resolution is static, so a known static receiver type
            // decides applicability; the value-argument arity must fit too.
            const recv_fits = if (static_recv) |sname|
                staticReceiverApplicable(self, allocator, sname, c.fid, &c.func.params[0].ty) orelse
                    try strictReceiverProven(self, allocator, receiver, c.fid, &c.func.params[0].ty)
            else
                try strictReceiverProven(self, allocator, receiver, c.fid, &c.func.params[0].ty);
            if (!recv_fits) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict recv-unproven static_recv={s}\n", .{ c.fid.int(), static_recv orelse "-" });
                continue;
            }
            // Type-parameter bounds bind here too; the static-hint shortcut
            // cannot see them, so re-check against the runtime receiver.
            if (receiverViolatesTypeParamBound(self, c.fid, &c.func.params[0].ty, receiver)) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict bound-thinned\n", .{c.fid.int()});
                bound_thinned = true;
                continue;
            }
            if (!extArityApplicableTL(self, &c.func, want, args.len != 0 and isCallable(&args[args.len - 1]))) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict arity nparams={d} want={d}\n", .{ c.fid.int(), c.func.params.len, want });
                continue;
            }
            const strict_lam_disproof = blk_sld: {
                if (c.func.params.len < 2) break :blk_sld false;
                for (args, 0..) |*av, ai| {
                    const pi = ai + 1;
                    if (pi >= c.func.params.len) break;
                    if (closureParamsDisproveFnParam(self, &c.func.params[pi].ty, av)) break :blk_sld true;
                }
                break :blk_sld false;
            };
            if (strict_lam_disproof) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict lambda-param-disproof\n", .{c.fid.int()});
                continue;
            }
            if (candidateArgsDisproven(self, &c.func, args)) {
                if (missTraceWant(name)) std.debug.print("[extfb]  fid={d} strict args-disproven\n", .{c.fid.int()});
                continue;
            }
            // A definite static mismatch drops the candidate, except for a
            // companion extension reached through the class value: `X.f`
            // carries declared receiver `X` against an `X.Companion` type.
            if (declared_recv) |dn| {
                const rty = &c.func.params[0].ty;
                const is_companion_recv = std.mem.endsWith(u8, rty.name, ".Companion") or
                    std.mem.eql(u8, rty.name, "Companion");
                if (!is_companion_recv and staticReceiverApplicable(self, allocator, dn, c.fid, rty) == false) continue;
            }
            filtered.append(allocator, c) catch {};
        }
        candidates.deinit(allocator);
        candidates = filtered;
        if (missTraceWant(name)) std.debug.print("[extfb] strict survivors={d}\n", .{candidates.items.len});
        if (candidates.items.len == 0) return null;
    } else {
        // Drop statically inapplicable candidates before any runtime-type
        // ranking; extension resolution is static.
        if (static_recv) |sname| {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                const fits = staticReceiverApplicable(self, allocator, sname, c.fid, &c.func.params[0].ty) orelse true;
                if (fits) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
            if (candidates.items.len == 0) return null;
        }
        // Lenient pass: keep candidates whose receiver match cannot be proven
        // (erased generics), but a definite disproof still drops one.
        {
            const mtr = missTraceWant(name);
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (receiverViolatesTypeParamBound(self, c.fid, &c.func.params[0].ty, receiver)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient bound-skip\n", .{c.fid.int()});
                    bound_thinned = true;
                    continue;
                }
                if (builtinReceiverDisproven(receiver, c.func.params[0].ty.name)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient builtin-disproof\n", .{c.fid.int()});
                    continue;
                }
                if (candidateArgsDisproven(self, &c.func, args)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient args-disproof\n", .{c.fid.int()});
                    continue;
                }
                // Judged by the declared arity (required/vararg), which is
                // authoritative where per-fid default thunks are not.
                if (declArityRefuses(self, c.fid, args.len)) {
                    if (mtr) std.debug.print("[extfb]  fid={d} lenient arity-refuse\n", .{c.fid.int()});
                    continue;
                }
                if (declared_recv) |dn| {
                    // A companion extension reached through the class value
                    // survives the class-vs-companion mismatch.
                    const rty = &c.func.params[0].ty;
                    const is_companion_recv = std.mem.endsWith(u8, rty.name, ".Companion") or
                        std.mem.eql(u8, rty.name, "Companion");
                    // A runtime receiver proving the declared type outranks a
                    // mismatched static hint, which can name an outer scope.
                    const self_repick = blk: {
                        const cf = ir.eval.currentFrameFunc() orelse break :blk false;
                        break :blk cf.id.int() == c.fid.int();
                    };
                    // A class-value receiver records the class as its declared
                    // receiver while the value is a `KClass`, whose own
                    // reflection heads outrank the class-shaped hint.
                    const class_reflection_proves = receiver.* == .Class and
                        receiver.isRuntimeType(simpleName(rty.name));
                    const runtime_proves = !self_repick and
                        (committedExtReceiverProven(self, allocator, c.fid, receiver) or
                            class_reflection_proves);
                    if (!is_companion_recv and !runtime_proves and staticReceiverApplicable(self, allocator, dn, c.fid, rty) == false) {
                        if (mtr) std.debug.print("[extfb]  fid={d} lenient static-recv-refuse dn={s}\n", .{ c.fid.int(), dn });
                        continue;
                    }
                }
                filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
            if (candidates.items.len == 0) return null;
        }
        var any_compat = false;
        for (candidates.items) |c| {
            if (receiverCompatibleWithParam(receiver, &c.func.params[0].ty) and
                !receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) any_compat = true;
        }
        if (missTraceWant(name)) std.debug.print("[extfb] lenient survivors={d} any_compat={}\n", .{ candidates.items.len, any_compat });
        if (any_compat) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (receiverCompatibleWithParam(receiver, &c.func.params[0].ty) and
                    !receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        } else {
            var any_undisproven = false;
            for (candidates.items) |c| {
                if (!receiverDefinitelyNotParam(self, &c.func.params[0].ty, receiver)) any_undisproven = true;
            }
            if (!any_undisproven) return null;
        }
    }

    // A function-typed receiver's declared head picks among a same-named
    // family: `suspend R.() -> T` lowers to `Function0` and `suspend (P) -> T`
    // to `Function1`, one runtime class that nothing below can split.
    if (candidates.items.len > 1) {
        if (declared_recv) |dn| {
            if (std.mem.startsWith(u8, dn, "Function")) {
                var n_exact: usize = 0;
                for (candidates.items) |c| {
                    const rh = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
                    if (std.mem.eql(u8, rh, dn)) n_exact += 1;
                }
                if (n_exact != 0 and n_exact != candidates.items.len) {
                    var filtered: std.ArrayList(Candidate) = .empty;
                    for (candidates.items) |c| {
                        const rh = std.mem.trimEnd(u8, c.func.params[0].ty.name, "?");
                        if (std.mem.eql(u8, rh, dn)) filtered.append(allocator, c) catch {};
                    }
                    candidates.deinit(allocator);
                    candidates = filtered;
                }
            }
        }
    }

    // A class body is an inner scope relative to its file: a member extension
    // of an enclosing class outranks a same-named top-level one, and survivors
    // passed `memberExtVisible`, so their owner is on the enclosing chain.
    if (candidates.items.len > 1) {
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        const mod2 = mg2.get();
        var n_member: usize = 0;
        for (candidates.items) |c| {
            if (isMemberExt(mod2, c.fid)) n_member += 1;
        }
        if (n_member != 0 and n_member != candidates.items.len) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                if (isMemberExt(mod2, c.fid)) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        }
    }

    // Kotlin gathers candidates scope level by scope level and stops at the
    // innermost applicable one, so the call site's own file wins where it has
    // any candidate.
    if (candidates.items.len > 1) {
        const site_file: ?ir.FileId = ir.eval.refSiteFile() orelse
            if (ir.eval.currentCallSiteSpan()) |csp| csp.file else null;
        if (site_file) |sf| {
            const smg = self.module.borrow();
            defer smg.deinit();
            const smod = smg.get();
            // The file tier orders top-level declarations only: a member
            // extension's scope level is its owner's position in the
            // implicit-receiver chain, so skip the tier when all are members.
            var all_member_ext = true;
            for (candidates.items) |c| {
                if (!isMemberExt(smod, c.fid)) {
                    all_member_ext = false;
                    break;
                }
            }
            var same_file: usize = 0;
            for (candidates.items) |c| {
                const ds = smod.decl_span.get(c.fid.int()) orelse continue;
                if (ds.file.int() == sf.int()) same_file += 1;
            }
            if (!all_member_ext and same_file != 0 and same_file != candidates.items.len) {
                var filtered: std.ArrayList(Candidate) = .empty;
                for (candidates.items) |c| {
                    const ds = smod.decl_span.get(c.fid.int()) orelse continue;
                    if (ds.file.int() == sf.int()) filtered.append(allocator, c) catch {};
                }
                candidates.deinit(allocator);
                candidates = filtered;
            }
        }
    }

    // Runs after the scope tiers, so it adjudicates only a residual twin
    // conflict that the receiver's own class FQN settles.
    if (candidates.items.len > 1) {
        narrowSameNameExtensionTwins(self, allocator, receiver, &candidates);
        if (candidates.items.len == 0) return null;
    }

    // A Range receiver carries its element kind, which separates
    // `ClosedRange<Int>` from `ClosedRange<UInt>` where erasure cannot.
    if (candidates.items.len > 1 and receiver.* == .Range) {
        const elem = rangeElemTypeName(receiver.Range.kind);
        var n_match: usize = 0;
        var n_typed: usize = 0;
        for (candidates.items) |c| {
            const rty = &c.func.params[0].ty;
            if (rty.args.len != 1 or !numericWidthKind(rty.args[0].name)) continue;
            n_typed += 1;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, rty.args[0].name, "?"), elem)) n_match += 1;
        }
        if (n_typed != 0 and n_match != 0 and n_match != n_typed) {
            var filtered: std.ArrayList(Candidate) = .empty;
            for (candidates.items) |c| {
                const rty = &c.func.params[0].ty;
                const typed = rty.args.len == 1 and numericWidthKind(rty.args[0].name);
                if (!typed or std.mem.eql(u8, std.mem.trimEnd(u8, rty.args[0].name, "?"), elem)) filtered.append(allocator, c) catch {};
            }
            candidates.deinit(allocator);
            candidates = filtered;
        }
    }

    // Unique-exact-arity pick, taken only when every argument binds its
    // parameter, so a defaulted-arity sibling can win on type fit instead.
    var unique_exact: ?Candidate = null;
    {
        var count: usize = 0;
        for (candidates.items) |c| {
            if (c.func.params.len == want) {
                count += 1;
                unique_exact = c;
            }
        }
        if (count != 1) unique_exact = null;
        if (unique_exact) |c| {
            if (try runtimeMemberApplicability(self, allocator, &c.func, args, null, false) == null)
                unique_exact = null;
        }
    }

    if (missTraceWant(name)) std.debug.print("[extpick] n={d} unique_exact={}\n", .{ candidates.items.len, unique_exact != null });
    var chosen: ?Candidate = null;
    if (candidates.items.len <= 1) {
        chosen = if (candidates.items.len == 1) candidates.items[0] else null;
    } else if (unique_exact != null) {
        chosen = unique_exact;
    } else {
        chosen = try scoreExtCandidates(self, allocator, receiver, candidates.items, args);
    }
    if (missTraceWant(name)) std.debug.print("[extpick] chosen={?d}\n", .{if (chosen) |c| c.fid.int() else null});

    if (chosen == null) return null;

    // Siblings differing only in the receiver's element type select on a
    // static type argument the runtime receiver does not carry: decline, and
    // the element-tag-aware intrinsic fallbacks serve the call dynamically.
    {
        const c = chosen.?;
        const crt = &c.func.params[0].ty;
        if (crt.args.len != 0) {
            for (candidates.items) |o| {
                if (o.fid.int() == c.fid.int()) continue;
                const ort = &o.func.params[0].ty;
                if (!std.mem.eql(u8, ort.name, crt.name)) continue;
                if (o.func.params.len != c.func.params.len) continue;
                if (ort.args.len != crt.args.len or ort.args.len == 0) continue;
                // Only a numeric-width element difference is undecidable;
                // container kinds dispatch per element at runtime.
                if (!numericWidthKind(ort.args[0].name) or !numericWidthKind(crt.args[0].name)) continue;
                if (!std.mem.eql(u8, ort.args[0].name, crt.args[0].name)) {
                    if (trace.enabled(name)) {
                        trace.emit("map=erased_recv_tie_decline name={s} a={s} b={s}", .{ name, c.func.fqn, o.func.fqn });
                    }
                    return null;
                }
            }
        }
    }

    const defer_to_property = blk: {
        const c = chosen.?;
        const is_member_ext = isMemberExt(self.module.borrow().get(), c.fid);
        if (!is_member_ext) break :blk false;
        if (c.func.params.len == 0) break :blk false;
        if (receiverImplementsType(self, receiver, c.func.params[0].ty.name)) break :blk false;
        break :blk (try enclosingCallableProperty(self, allocator, name)) != null;
    };

    // Defer to the Iterable fallback for a bare-package stdlib extension
    // chosen for a user collection.
    const defer_to_iterable = blk: {
        if (receiver.* != .Instance) break :blk false;
        const c = chosen.?;
        const coll = try std.fmt.allocPrint(allocator, "kotlin.collections.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(coll);
        const seq = try std.fmt.allocPrint(allocator, "kotlin.sequences.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(seq);
        if (!(std.mem.eql(u8, c.func.fqn, coll) or std.mem.eql(u8, c.func.fqn, seq))) break :blk false;
        if (!hostHasMember(self, receiver, "iterator")) break :blk false;
        const ip = try std.fmt.allocPrint(allocator, "kotlin.collections.Iterable.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(ip);
        const lp = try std.fmt.allocPrint(allocator, "kotlin.collections.List.{s}", .{name});
        defer if (runtime.freeScratch()) allocator.free(lp);
        break :blk (lookupIntrinsic(self, ip) != null) or (lookupIntrinsic(self, lp) != null);
    };

    // A receiver member takes precedence over any extension, scoped to the
    // case where bound refutation thinned the candidate set. A Range is the
    // exception: its `contains` member takes only its own element kind, so any
    // other argument is the chosen extension's to serve.
    const member_could_take_args = !(receiver.* == .Range and args.len == 1 and
        std.mem.eql(u8, name, "contains") and
        (args[0] == .Range or !rangeContainsArgKindMatches(receiver.Range.kind, &args[0])));
    const defer_to_member = bound_thinned and member_could_take_args and
        receiverHasMemberNamed(self, receiver, name);
    if (!defer_to_property and !defer_to_iterable and !defer_to_member) {
        const c = chosen.?;
        if (trace.enabled(name)) {
            const d = funcDefaults(self, &c.func);
            trace.emit("map=ext_fallback_pick name={s} fqn={s} fid={d} strict={} nparams={d} ndefaults={d} recv_ty={s} p0={s} owner={s}", .{
                name,                     c.func.fqn,
                c.fid.int(),              strict_ext,
                c.func.params.len,        if (d) |dd| dd.len else 0,
                c.func.params[0].ty.name, c.func.params[0].name,
                blk: {
                    const mg2 = self.module.borrow();
                    defer mg2.deinit();
                    break :blk mg2.get().registry.member_ext_owner_class.get(c.fid) orelse "-";
                },
            });
        }
        const all = try prependReceiver(allocator, receiver, args);
        defer if (runtime.freeScratch()) allocator.free(all);
        const mg = self.module.borrow();
        const mod = mg.get();
        // A member-extension body has its declaring class's `this` in scope:
        // push that owner as an enclosing receiver for the call.
        var pushed_owner = false;
        var sam_target: ?Value = null;
        if (mod.registry.member_ext_owner_class.get(c.fid)) |owner| {
            if (try memberExtOwnerInstance(self, allocator, receiver, owner)) |inst| {
                // When the owner is a SAM conversion the fun interface's one
                // method is the member-extension, so the stored lambda serves
                // the call with the extension receiver as its `this`.
                if (funcAt(mod, c.fid) != null and !funcAt(mod, c.fid).?.hasBody()) {
                    if (inst == .Instance) {
                        const g = inst.Instance.borrow();
                        sam_target = g.get().get("__sam_target__");
                        g.deinit();
                    }
                }
                if (sam_target == null) {
                    ir.eval.pushEnclosing(&inst);
                    pushed_owner = true;
                }
            }
        }
        if (sam_target) |t| {
            const r2 = try host_call_value.callValueWithThis(self, allocator, &t, &all[0], all[1..], &.{});
            mg.deinit();
            return r2;
        }
        if (!pushed_owner) maybeWarnLenientExtBind(self, mod, c.fid);
        // Memoize an owner-independent pick under the plain key; when a
        // member-extension competed and lost, the chain-folded key captures
        // the full resolution input instead.
        if (!pushed_owner) {
            if (!saw_member_ext_out.*) {
                if (cache_key) |k| extMethodCachePut(self, k, @intFromEnum(c.fid));
            } else if (chain_key) |k| {
                extMethodCachePut(self, k, @intFromEnum(c.fid));
            }
        } else if (sam_target == null and c.func.params.len == args.len + 1) {
            // A member-extension winner is owner-dependent, but the owner is
            // recovered from the chain at serve time and the key folds the
            // chain shape, so the key still determines the resolution.
            if (chain_key) |k| extMethodCachePut(self, k, @intFromEnum(c.fid));
        }
        const r = try callFuncRec(self, allocator, mod, c.fid, all);
        if (pushed_owner) ir.eval.popEnclosing();
        mg.deinit();
        return r;
    }
    return null;
}

/// Once-per-declaration guard for `maybeWarnLenientExtBind`.
pub var lenient_warned_mutex: runtime.SpinMutex = .{};
pub var lenient_warned: ?std.AutoHashMap(u32, void) = null;

/// Warn once when the fallback binds a shipped pack's extension the call site
/// never imports: Kotlin resolves an extension only when imported or
/// same-package, and such a call's lambdas lower without a declared receiver.
pub fn maybeWarnLenientExtBind(self: *VmHost, mod: *const Module, fid: FuncId) void {
    _ = self;
    const f = funcAt(mod, fid) orelse return;
    if (f.package.len == 0) return;
    if (std.mem.eql(u8, f.package, "kotlin") or std.mem.startsWith(u8, f.package, "kotlin.")) return;
    if (!stdlib.isKnownPackage(f.package)) return;
    const sp = ir.eval.currentCallSiteSpan() orelse return;
    const caller_pkg = mod.packageOfFile(sp.file) orelse "";
    if (std.mem.eql(u8, caller_pkg, f.package)) return;
    if (caller_pkg.len != 0 and stdlib.isKnownPackage(caller_pkg)) return;
    if (mod.importWildcardIn(sp.file, f.package)) return;
    for (mod.importAliasPathsIn(sp.file, f.name)) |p| {
        if (std.mem.eql(u8, p.fqn, f.fqn)) return;
    }
    lenient_warned_mutex.lock();
    defer lenient_warned_mutex.unlock();
    if (lenient_warned == null) lenient_warned = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    const gop = lenient_warned.?.getOrPut(@intFromEnum(fid)) catch return;
    if (gop.found_existing) return;
    std.debug.print(
        "warning: `{s}` binds `{s}` without an import; add `import {s}` — kotlinc rejects the unimported call, and klio may type its lambda arguments incorrectly\n",
        .{ f.name, f.fqn, f.fqn },
    );
}

/// The memo is process-global, so a driver running many programs per process
/// resets it at each run boundary to keep the warning once per run.
pub fn resetLenientWarned() void {
    lenient_warned_mutex.lock();
    defer lenient_warned_mutex.unlock();
    if (lenient_warned) |*m| m.clearRetainingCapacity();
}

/// The instance serving as a member-extension's dispatch receiver: the
/// innermost enclosing receiver whose hierarchy carries `owner`, else the
/// explicit receiver when it does.
pub fn memberExtOwnerInstance(self: *VmHost, allocator: Allocator, receiver: *const Value, owner: []const u8) Allocator.Error!?Value {
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    if (runtime.envOnce("KLIO_MEOI_TRACE")) |w| {
        if (std.mem.eql(u8, owner, w)) {
            std.debug.print("[meoi] owner={s} nentries={d}:", .{ owner, entries.len });
            for (entries) |e| {
                if (e.v == .Instance) {
                    const g = e.v.Instance.borrow();
                    const cg = g.get().class.borrow();
                    std.debug.print(" {s}={}", .{ cg.get().name, receiverImplementsOwnerIdentity(self, &e.v, owner) });
                    cg.deinit();
                    g.deinit();
                } else std.debug.print(" {s}", .{@tagName(e.v)});
            }
            std.debug.print("\n", .{});
        }
    }
    for (entries) |e| {
        if (e.v != .Instance) continue;
        if (receiverImplementsOwnerIdentity(self, &e.v, owner)) return e.v;
        // The owner may sit on the entry's class-nesting tower.
        if (!e.isSubject()) {
            var cur: ?Value = instanceOuterLink(&e.v);
            while (cur) |o| {
                if (o != .Instance) break;
                if (receiverImplementsOwnerIdentity(self, &o, owner)) return o;
                cur = instanceOuterLink(&o);
            }
        }
    }
    if (receiver.* == .Instance and
        receiverImplementsOwnerIdentity(self, receiver, owner)) return receiver.*;
    // The executing call stack's lexical receiver tower: a getter reached
    // through nested lambdas binds its owner as an outer frame's `this`.
    {
        const lex = try ir.eval.frameThisChainAlloc(allocator);
        defer allocator.free(lex);
        for (lex) |v| {
            if (v != .Instance) continue;
            if (receiverImplementsOwnerIdentity(self, &v, owner)) return v;
        }
    }
    // A `by`-delegate of an enclosing receiver stands in as the owner: the
    // wrapper forwards the interface's member extensions to it.
    for (entries) |e| {
        var di: usize = 0;
        while (delegateFieldAt(&e.v, di)) |d| : (di += 1) {
            if (d == .Instance and receiverImplementsOwnerIdentity(self, &d, owner)) return d;
        }
    }
    {
        const lex = try ir.eval.frameThisChainAlloc(allocator);
        defer allocator.free(lex);
        for (lex) |v| {
            var di: usize = 0;
            while (delegateFieldAt(&v, di)) |d| : (di += 1) {
                if (d == .Instance and receiverImplementsOwnerIdentity(self, &d, owner)) return d;
            }
        }
    }
    // An `object`/companion owner is its own dispatch receiver: the
    // singleton is materializable from anywhere it can be imported.
    if (memberExtOwnerObjectClass(self, owner)) |owner_id| {
        if (host_globals.lookupGlobalById(
            self,
            allocator,
            null,
            owner_id,
            false,
        )) |sv| {
            if (sv == .Instance) return sv;
        }
    }
    return null;
}

pub fn instanceOuterLink(v: *const Value) ?Value {
    return switch (v.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            break :blk g.get().outer;
        },
        else => null,
    };
}

/// Ranking key for most-specific extension selection, compared field by field
/// so the winner is unique without a declaration-order tie-break:
///   0. subtype specificity, Kotlin's most-specific rule decided by the
///      subtyping lattice rather than runtime hierarchy distance;
///   1. receiver specificity against the receiver's runtime type;
///   2. applicability score; 3. owner rank, a member extension nearer on the
///      enclosing-`this` chain; 4. parameter specificity; 5. lowest `FuncId`.
pub const ExtKey = [9]i32;

pub fn extKeyGreater(a: ExtKey, b: ExtKey) bool {
    inline for (0..a.len) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

pub fn scoreExtCandidates(self: *VmHost, allocator: Allocator, receiver: *const Value, candidates: []const Candidate, args: []const Value) Allocator.Error!?Candidate {
    // [6] not [24]: safety builds 0xAA-fill the whole declared array; more
    // than 6 args take the heap branch below.
    var shapes_buf: [6]applicability.ArgShape = undefined;
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else
        try allocator.alloc(applicability.ArgShape, args.len);
    defer if (args.len > shapes_buf.len) allocator.free(shapes);
    for (args, 0..) |*a, i| shapes[i] = shapeOfValueMember(self, a);

    const all_sigs = try allocator.alloc(applicability.SigView, candidates.len);
    defer allocator.free(all_sigs);
    for (candidates, 0..) |c, i| all_sigs[i] = sigViewOfMember(self, &c.func, true);

    const recv_shape = shapeOfValueMember(self, receiver);
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .rank_extensions = true,
        .is_extension = true,
        .receiver = recv_shape,
        .all_candidates = all_sigs,
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
        .ext_recv_match = applicExtRecvMatchCb,
        .ext_is_subtype_name = applicExtSubtypeNameCb,
        .ext_owner_rank = applicExtOwnerRankCb,
        .ext_known_package = applicKnownPackageCb,
        .type_var = applicTypeVarCbM,
    };

    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    var best: ?Candidate = null;
    var best_key: ExtKey = .{std.math.minInt(i32)} ** 9;
    for (candidates, 0..) |c, idx| {
        const applied = applicability.applicable(&all_sigs[idx], shapes, scope);
        if (candidates.len > 0 and missTraceWant(candidates[0].func.name)) {
            const mg = self.module.borrow();
            defer mg.deinit();
            const owner = mg.get().registry.member_ext_owner_class.get(c.fid) orelse "-";
            if (applied) |ap| {
                std.debug.print("[extscore] fid={d} owner={s} key={any}\n", .{ c.fid.int(), owner, ap.ext_key.? });
            } else {
                std.debug.print("[extscore] fid={d} owner={s} INAPPLICABLE\n", .{ c.fid.int(), owner });
            }
        }
        const key = (applied orelse continue).ext_key.?;
        if (check_inv and best != null and std.mem.eql(i32, &key, &best_key)) {
            tied.append(self.allocator, c.func) catch {};
        }
        if (best == null or extKeyGreater(key, best_key)) {
            best = c;
            best_key = key;
            if (check_inv) {
                tied.clearRetainingCapacity();
                tied.append(self.allocator, c.func) catch {};
            }
        }
    }
    if (check_inv) {
        if (best) |w| {
            const name: []const u8 = if (candidates.len > 0) candidates[0].func.name else "";
            checkOverloadUnique(name, &w.func, tied.items);
            checkFuncInRange(self, "scoreExtCandidates", w.fid);
        }
    }
    return best;
}

pub fn isSubtypeName(self: *VmHost, allocator: Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return false;
    var q: std.ArrayList([]const u8) = .empty;
    defer q.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    q.append(allocator, a) catch return false;
    while (q.pop()) |c| {
        if (seen.contains(c)) continue;
        seen.put(c, {}) catch {};
        if (std.mem.eql(u8, c, b)) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(c)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |s| q.append(allocator, s) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

pub fn enclosingChainClassOrder(self: *VmHost, allocator: Allocator) Allocator.Error!std.ArrayList([]const u8) {
    var v: std.ArrayList([]const u8) = .empty;
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(allocator);
    // Persistent across the whole chain: a supertype shared by an inner and an
    // outer `this` must appear once, at its innermost occurrence.
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(allocator);
    for (chain) |value| {
        var cur: ?Value = value;
        while (cur) |cv| {
            if (cv == .Instance) {
                const g = cv.Instance.borrow();
                closure.clearRetainingCapacity();
                collectClassClosure(g.get().class.asPtr(), &closure, &seen, allocator);
                for (closure.items) |cd| try v.append(allocator, cd.fqn);
                const outer = g.get().outer;
                g.deinit();
                cur = outer;
            } else break;
        }
    }
    return v;
}

/// A runtime-registered local class publishes its companion instance under the
/// `$companion:<name>` global, and a member call on the class value goes there.
pub fn localClassCompanionForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cname: []const u8 = blk: {
        const cg = receiver.Class.borrow();
        defer cg.deinit();
        if (!cg.get().is_local_runtime) return null;
        break :blk cg.get().name;
    };
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "$companion:{s}", .{cname}) catch return null;
    const local_comp: ?Value = blk: {
        const g = self.globals.borrow();
        defer g.deinit();
        break :blk g.get().lookup(key);
    };
    const lc = local_comp orelse return null;
    if (lc != .Instance) return null;
    const r = try callMemberRec(self, allocator, &lc, name, args);
    if (r == .ok) return r;
    freeDispatchMiss(allocator, r);
    return null;
}

pub fn classCompanionForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const cls = receiver.Class;
    var cname: []const u8 = undefined;
    {
        const cg = cls.borrow();
        cname = cg.get().name;
        // An enum's synthetic statics belong to the enum class, never to its
        // companion, so `Color.values()` must not forward there.
        if (cg.get().is_enum and (std.mem.eql(u8, name, "values") or std.mem.eql(u8, name, "valueOf") or std.mem.eql(u8, name, "entries"))) {
            cg.deinit();
            return null;
        }
        cg.deinit();
    }
    const simple = simpleName(cname);
    if (try localClassCompanionForward(self, allocator, receiver, name, args)) |r| return r;
    const cfqn: []const u8 = blk: {
        const cg = cls.borrow();
        defer cg.deinit();
        break :blk cg.get().fqn;
    };
    const comp_name = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const comp = &mg.get().registry.companion_singletons;
        // Dotted fqn suffixes longest-first: a nested class with a same-named
        // cousin elsewhere resolves its own companion.
        var start: usize = 0;
        while (true) {
            if (comp.get(cfqn[start..])) |c| break :blk c;
            const dot = std.mem.findScalarPos(u8, cfqn, start, '.') orelse break;
            start = dot + 1;
            // Never the bare simple name here: that key is a top-level
            // class's; the class's own name is tried next.
            if (std.mem.findScalarPos(u8, cfqn, start, '.') == null) break;
        }
        if (comp.get(cname)) |c| break :blk c;
        if (comp.get(simple)) |c| break :blk c;
        break :blk null;
    };
    if (comp_name) |cn| {
        const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
            .ok => |maybe| maybe,
            .err => |e| return .{ .err = e },
        };
        if (singleton) |s| {
            if (s == .Instance) {
                const r = try callMemberRec(self, allocator, &s, name, args);
                if (r == .ok) return r;
                freeDispatchMiss(allocator, r);
            }
        }
    }
    return null;
}

pub fn instanceCompanionFallback(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var recv_id: u64 = undefined;
    var start: []const u8 = undefined;
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        recv_id = g.get().identity;
        start = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    // Walk the full supertype graph: a class may list an interface ahead of
    // the superclass whose companion declares `name`.
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    try queue.append(allocator, start);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cname = queue.items[head];
        if (seen.contains(cname)) continue;
        try seen.put(cname, {});
        const comp_name = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.companion_singletons.get(cname);
        };
        if (comp_name) |cn| {
            const singleton: ?Value = switch (try host_globals.objectSingletonForMember(self, cn, name)) {
                .ok => |maybe| maybe,
                .err => |e| return .{ .err = e },
            };
            if (singleton) |s| {
                if (s == .Instance) {
                    const sg = s.Instance.borrow();
                    const sid = sg.get().identity;
                    sg.deinit();
                    if (sid != recv_id) {
                        const r = try callMemberRec(self, allocator, &s, name, args);
                        if (r == .ok) return r;
                        // The companion probe missed: free its discarded
                        // dispatch message before trying the next.
                        freeDispatchMiss(allocator, r);
                    }
                }
            }
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cname)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(allocator, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}
