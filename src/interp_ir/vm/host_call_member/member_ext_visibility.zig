//! Member-extension visibility and shadowing rules, plus interface delegation
//! lookups.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;

const binding_probe = @import("binding_probe.zig");
const isBuiltinScalar = binding_probe.isBuiltinScalar;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const callMemberRec = hcm.callMemberRec;
const simpleName = hcm.simpleName;

const member_presence = @import("member_presence.zig");
const enclosingThisChain = member_presence.enclosingThisChain;

const named_call = @import("named_call.zig");
const callMemberNamed = named_call.callMemberNamed;

const receiver_probe = @import("receiver_probe.zig");
const allUppercase = receiver_probe.allUppercase;
const extArityApplicable = receiver_probe.extArityApplicable;
const receiverCompatibleWithParam = receiver_probe.receiverCompatibleWithParam;
const receiverImplementsHead = receiver_probe.receiverImplementsHead;
const strictReceiverProven = receiver_probe.strictReceiverProven;
const typeParamOf = receiver_probe.typeParamOf;

const reflect_anon = @import("reflect_anon.zig");
const anonKey = reflect_anon.anonKey;
const funcAt = reflect_anon.funcAt;

const static_tail = @import("static_tail.zig");
const freeDispatchMiss = static_tail.freeDispatchMiss;
const missTraceEnv = static_tail.missTraceEnv;
const missTraceWant = static_tail.missTraceWant;
const nuTraceEnv = static_tail.nuTraceEnv;

/// Whether `fid` is a member extension. Authoritative via the func's
/// first-class `kind`; the `member_ext_owner_class` side table carries the
/// owner-gating data (the kind selects which funcs are gated, the side
/// table says by which owner class).
pub fn isMemberExtFid(self: *VmHost, fid: FuncId) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    return isMemberExt(mg.get(), fid);
}

pub fn isMemberExt(mod: *const Module, fid: FuncId) bool {
    if (funcAt(mod, fid)) |f| return f.kind == .member_extension;
    return false;
}

/// Member-extension visibility gate: a member-extension `fid` is visible
/// at a call site only when its declaring (owner) class is reachable
/// through `visible_owners`. Non-member-extensions are unconditionally
/// visible (this function gates nothing for them). Preserves the prior
/// `member_ext_owner_class.get(fid)`-then-`visible_owners.contains(owner)`
/// behavior exactly: the kind selects the gated funcs, the side table
/// supplies the owner.
/// Whether `fid` is a FILE-PRIVATE top-level function whose declaring file
/// is not the currently executing frame's file — Kotlin scopes a private
/// top-level declaration to its file, so such a candidate is invisible here
/// (a file-private `Rect.size()` must never capture `changes.size()`).
pub fn privateFnHiddenHere(self: *VmHost, mod: *const Module, fid: FuncId) bool {
    _ = self;
    const decl_file = mod.registry.private_fn_files.get(fid) orelse return false;
    // A dispatching bound reference carries its creation-site file; the
    // reference site, not the dynamic caller, decides private visibility.
    if (ir.eval.refSiteFile()) |f| return f.int() != decl_file.int();
    const sp = ir.eval.currentCallSiteSpan() orelse return false;
    if (missTraceEnv() != null) {
        if (mod.funcById(fid)) |f| {
            if (missTraceWant(f.name)) std.debug.print("[priv-hidden] {s} decl_file={d} site_file={d} hidden={} exec={s}\n", .{ f.name, decl_file.int(), sp.file.int(), sp.file.int() != decl_file.int(), if (ir.eval.currentFrameFunc()) |cf| (if (cf.fqn.len != 0) cf.fqn else cf.name) else "<none>" });
        }
    }
    return sp.file.int() != decl_file.int();
}

/// A bound reference's creation-site file (`__bound_file__`), if recorded
/// on its synth instance. The invoke arms re-install it around their
/// by-name dispatch via `ir.eval.pushRefSiteFile`.
pub fn boundRefFile(callee: *const Value) ?ir.FileId {
    if (callee.* != .Instance) return null;
    const g = callee.Instance.borrow();
    defer g.deinit();
    const v = g.get().get("__bound_file__") orelse return null;
    if (v != .Int) return null;
    return ir.FileId.from(@intCast(v.Int));
}

pub fn memberExtVisible(self: *VmHost, mod: *const Module, fid: FuncId, visible_owners: *const OwnerSet) bool {
    if (!isMemberExt(mod, fid)) return true;
    const owner = mod.registry.member_ext_owner_class.get(fid) orelse return true;
    if (nuTraceEnv()) |want| {
        if (funcAt(mod, fid)) |f| {
            if (std.mem.eql(u8, f.name, want) or std.mem.eql(u8, want, "1")) {
                std.debug.print("[mev] fid={d} owner={s} vis={}\n", .{ fid.int(), owner, visible_owners.contains(owner) });
                std.debug.print("[mev] receivers:", .{});
                for (visible_owners.sig[0..visible_owners.n]) |p| {
                    const cd: *const ClassDef = @ptrFromInt(p);
                    std.debug.print(" {s}", .{cd.fqn});
                }
                std.debug.print("\n", .{});
            }
        }
    }
    if (visible_owners.contains(owner)) return true;
    // An interface implementation is not an importable extension. `private object
    // EmptyMeasurePolicy : MeasurePolicy { override fun MeasureScope.measure(…) }`
    // declares an interface method body, reachable only with the object as the
    // dispatch receiver -- never by name from an unrelated site. Letting the
    // singleton hatch below hand it out made EVERY `with(policy) { measure(…) }`
    // run `BasicText`'s policy, which sizes to the incoming constraints: a text
    // field then measured itself to the unbounded scroll height.
    if (implementsSupertypeMemberExt(self, mod, owner, fid)) return false;
    // A member extension declared in an `object`/companion is callable
    // wherever the singleton is importable (`import C.Companion.f`): its
    // dispatch receiver is the singleton itself, which is always
    // materializable, so the enclosing-`this` chain need not carry it.
    return ownerIsObjectSingleton(self, owner);
}

/// Whether `owner`'s member extension `fid` implements a same-named member
/// extension declared by one of `owner`'s supertypes -- i.e. it is an interface
/// method body, not an importable extension. `object EmptyMeasurePolicy :
/// MeasurePolicy` overriding `MeasureScope.measure` is the shape: the only way to
/// reach it is with the object as the dispatch receiver.
///
/// Read off the supertypes rather than an `override` modifier: the lowering does
/// not carry the modifier this far, and a supertype declaration is what `override`
/// means anyway.
pub fn implementsSupertypeMemberExt(self: *VmHost, mod: *const Module, owner: []const u8, fid: FuncId) bool {
    const f = funcAt(mod, fid) orelse return false;
    const runtime_owner = if (mod.classIdByFqn(owner)) |id|
        mod.classes.items[id.int()].name
    else
        owner;
    const sups: []const []const u8 = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        const d = g.get().get(runtime_owner) orelse break :blk &.{};
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().supertype_names;
    };
    // The supertype's declaration is ABSTRACT: it carries no body and lowers no
    // func, so it cannot be found among the interface's methods. `iface_member_ext_recv`
    // is where an abstract member EXTENSION is recorded -- keyed by (interface, name),
    // which is exactly the question here.
    for (sups) |sup| {
        if (mod.registry.iface_member_ext_recv.get(.{ .a = sup, .b = f.name }) != null) return true;
    }
    return false;
}

/// Whether a member-extension owner class is a registered `object` /
/// companion singleton.
pub fn ownerIsObjectSingleton(self: *VmHost, owner: []const u8) bool {
    return memberExtOwnerObjectClass(self, owner) != null;
}

/// Exact class identity for an object/companion member-extension owner.
pub fn memberExtOwnerObjectClass(self: *VmHost, owner: []const u8) ?ir.ClassId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    const id = mod.classIdByFqn(owner) orelse return null;
    if (id.int() >= mod.classes.items.len or !mod.classes.items[id.int()].is_object) {
        return null;
    }
    return id;
}

/// A visible member-extension on the receiver type declared in the
/// enclosing-class chain shadows the stdlib type-name probe.
pub fn userMemberExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, argc: usize) Allocator.Error!bool {
    var owners = try enclosingOwnerSet(self, allocator);
    defer owners.deinit();
    const want = argc + 1;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        if (!isMemberExt(mod, fid)) continue;
        const owner = mod.registry.member_ext_owner_class.get(fid) orelse continue;
        if (!owners.contains(owner)) continue;
        if (funcAt(mod, fid)) |f| {
            if (f.params.len == 0 or f.params.len < want) continue;
            // The shadow holds only while the member-extension could
            // actually bind this receiver: a definitely-disproven declared
            // receiver (a private `IntRange.toLong()` against a `Long`)
            // must leave the stdlib probe ladder in charge. Erased-generic
            // receivers stay non-definite and keep shadowing.
            if (argDefinitelyNotParamType(self, &f.params[0].ty, receiver)) continue;
            return true;
        }
    }
    return false;
}

/// A shipped-pack top-level extension the CALL SITE's file has in scope
/// (same package, wildcard import, or named import) whose declared
/// receiver provably holds shadows the stdlib type-name probe: Kotlin's
/// scoping ranks an explicitly imported extension above the implicitly
/// imported stdlib one (ktor's `Char.isLowerCase()` inside a ktor file
/// importing `io.ktor.util.*` beats `kotlin.text.isLowerCase`). Returns
/// `.shadows` when the ladder must stand down for THIS call site,
/// `.potential` when such a candidate exists but is not in scope here
/// (the resolution is file-dependent, so the caller must not memoize),
/// and `.none` otherwise.
pub const PackExtShadow = enum { none, potential, shadows };

pub fn importedPackExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, argc: usize) Allocator.Error!PackExtShadow {
    _ = allocator;
    const want = argc + 1;
    const sp = ir.eval.currentCallSiteSpan();
    const dbg = blk: {
        const S = struct {
            var cached: ?bool = null;
        };
        if (S.cached) |b| break :blk b;
        const b = runtime.envOnce("KLIO_SHADOW_TRACE") != null;
        S.cached = b;
        break :blk b;
    };
    if (dbg) std.debug.print("[shadow] probe name={s} argc={d} cands={d} span={any}\n", .{ name, argc, blk: {
        const mg2 = self.module.borrow();
        defer mg2.deinit();
        break :blk mg2.get().funcsBySimpleName(name).len;
    }, sp });
    var result: PackExtShadow = .none;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        if (!f.hasBody()) continue;
        if (f.package.len == 0) continue;
        // The stdlib's own packages ARE the ladder's surface.
        if (std.mem.eql(u8, f.package, "kotlin") or std.mem.startsWith(u8, f.package, "kotlin.")) continue;
        // Only shipped/pack packages here; plain user declarations are
        // `userToplevelExtShadows`'s domain.
        if (dbg) std.debug.print("[shadow] cand fqn={s} pkg={s} known={} body={}\n", .{ f.fqn, f.package, stdlib.isKnownPackage(f.package), f.hasBody() });
        if (!stdlib.isKnownPackage(f.package)) continue;
        if (f.params.len < want) {
            var has_vararg = false;
            for (f.params) |*p| {
                if (p.is_vararg) {
                    has_vararg = true;
                    break;
                }
            }
            if (!has_vararg) continue;
        } else if (!extArityApplicable(self, &f, want)) continue;
        // NOMINAL receiver match only: a generic / `Any` / function-shape
        // receiver accepts anything and must not stand the whole ladder
        // down (a pack `fun <T> T.get(...)` would otherwise shadow
        // `String.get`). The declared head must be a concrete type the
        // runtime receiver implements.
        {
            var rn = simpleName(f.params[0].ty.name);
            rn = std.mem.trimEnd(u8, rn, "?");
            if (std.mem.eql(u8, rn, "Any") or std.mem.eql(u8, rn, "Unit")) continue;
            if (std.mem.startsWith(u8, rn, "Function")) continue;
            if (rn.len > 0 and rn.len <= 2 and allUppercase(rn)) continue;
            if (typeParamOf(self, fid, rn)) continue;
            if (mod.registry.type_aliases.get(rn)) |t| {
                if (!std.mem.eql(u8, t, rn)) rn = simpleName(t);
            }
            if (!receiverImplementsHead(self, receiver, rn)) continue;
        }
        result = .potential;
        const file = (sp orelse continue).file;
        const in_scope = mod.importWildcardIn(file, f.package) or blk: {
            for (mod.importAliasPathsIn(file, name)) |p| {
                if (std.mem.eql(u8, p.fqn, f.fqn)) break :blk true;
            }
            break :blk false;
        };
        if (in_scope) return .shadows;
    }
    return result;
}

/// A visible USER (non-shipped) top-level extension whose declared
/// receiver type provably holds for this receiver shadows the stdlib
/// type-name probe: a same-package extension (`fun Int.to(o: Int)`)
/// outranks an implicitly imported stdlib extension of the same name
/// (`kotlin.to`), so the stdlib probe ladder must stand down and let the
/// extension fallback bind the user's declaration.
/// Whether the user program declares ANY top-level extension named `name`
/// whose receiver type accepts `receiver` (ignoring the arguments). When true,
/// the `(type, name)` → stdlib-member resolution is ARGUMENT-dependent (the
/// extension shadows the builtin only for arguments it applies to), so it must
/// NOT be memoized by (type, name) alone — else the first call's winner
/// (`1 or 2` → builtin `Int.or`) is wrongly replayed for a different argument
/// shape (`1 or NodeKind` → must reach the extension).
pub fn userToplevelExtNamedExists(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        // A pack/stdlib package's extension normally must not pre-empt the
        // probe ladder it dispatches — EXCEPT on a builtin scalar receiver,
        // where the builtin operators (`Int.or`, …) are host intrinsics, not
        // FuncIds, so a pack's operator overload (`Int.or(NodeKind)`) is a
        // genuine distinct overload that must apply for its own argument type.
        if (stdlib.isKnownPackage(f.package) and
            (std.mem.startsWith(u8, f.package, "kotlin") or !isBuiltinScalar(receiver))) continue;
        if (try strictReceiverProven(self, allocator, receiver, fid, &f.params[0].ty)) return true;
    }
    return false;
}

/// Whether the receiver type declares `name` and none of its declarations
/// takes `argc` value arguments (defaults and varargs count as taking any
/// count at or beyond their minimum).
pub fn memberDeclArityMisfit(self: *VmHost, type_fqn: []const u8, name: []const u8, argc: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var decl_buf: [16]FuncId = undefined;
    var n_decls: usize = 0;
    // The receiver type's own declarations, else the nearest supertypes'.
    var stack: [32]ir.ClassId = undefined;
    var sp: usize = 0;
    var visited: usize = 0;
    if (mod.classIdByFqn(type_fqn) orelse mod.classId(type_fqn)) |cid| {
        stack[sp] = cid;
        sp += 1;
    }
    for (mod.memberDecls(type_fqn, name)) |fid| {
        if (n_decls < decl_buf.len) {
            decl_buf[n_decls] = fid;
            n_decls += 1;
        }
    }
    while (n_decls == 0 and sp > 0 and visited < 64) : (visited += 1) {
        sp -= 1;
        const cid = stack[sp];
        if (cid.int() >= mod.classes.items.len) continue;
        const c = &mod.classes.items[cid.int()];
        for (mod.memberDecls(c.fqn, name)) |fid| {
            if (n_decls < decl_buf.len) {
                decl_buf[n_decls] = fid;
                n_decls += 1;
            }
        }
        if (n_decls == 0) {
            for (c.supertypes) |p| {
                if (sp < stack.len) {
                    stack[sp] = p;
                    sp += 1;
                }
            }
        }
    }
    const decls = decl_buf[0..n_decls];
    if (decls.len == 0) return false;
    for (decls) |fid| {
        const f = funcAt(mod, fid) orelse return false;
        const skip: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const value_params = f.params[skip..];
        var min: usize = 0;
        var open = false;
        for (value_params) |*p| {
            if (p.is_vararg) {
                open = true;
            } else if (!p.has_default) {
                min += 1;
            }
        }
        if (argc == value_params.len) return false;
        if (open and argc >= min) return false;
        if (argc >= min and argc <= value_params.len) return false;
    }
    return true;
}

pub fn userToplevelExtShadows(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!bool {
    const want = args.len + 1;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (mod.funcsBySimpleName(name)) |fid| {
        const f = funcAt(mod, fid) orelse continue;
        // A top-level extension carries `this` as its leading param and is
        // not a member-extension (those go through userMemberExtShadows).
        if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) continue;
        if (isMemberExt(mod, fid)) continue;
        // Only the user's own program shadows the stdlib: a package the
        // stdlib registry or an installed pack owns (kotlin.*, io.ktor.*,
        // …) is the very surface the probe ladder dispatches, so its
        // same-named extensions must not pre-empt it. A user declaration
        // lives in a package no registry knows.
        if (stdlib.isKnownPackage(f.package) and
            (std.mem.startsWith(u8, f.package, "kotlin") or !isBuiltinScalar(receiver))) continue;
        if (f.params.len < want) continue;
        if (!extArityApplicable(self, &f, want)) continue;
        // Only a proven receiver match shadows: an inapplicable namesake
        // (a `String.to` against an `Int` receiver) leaves the stdlib path.
        if (!(try strictReceiverProven(self, allocator, receiver, fid, &f.params[0].ty))) continue;
        // The ARGUMENTS must also be applicable, else this extension is not a
        // candidate for THIS call and must not shadow a same-named stdlib
        // member: `fun Int.or(NodeKind)` does not apply to `1 or 2`, so the
        // builtin `Int.or(Int)` must still win (a member outranks an
        // inapplicable extension). A scalar argument against a user-class
        // parameter is a definite mismatch.
        var args_ok = true;
        for (args, 0..) |*arg, i| {
            if (i + 1 >= f.params.len) break;
            if (!receiverCompatibleWithParam(arg, &f.params[i + 1].ty)) {
                args_ok = false;
                break;
            }
        }
        if (args_ok) return true;
    }
    return false;
}

/// Append `cls` and its full transitive supertype closure — the superclass
/// chain AND every implemented interface, recursively — to `out` in
/// innermost-first order, deduped by pointer identity through `seen`. A
/// member-extension declared as a superclass or interface default body is in
/// scope wherever an enclosing `this` carries that owner ANYWHERE in its
/// hierarchy, so the closure (not just the single `parent` chain) is what
/// gates its visibility. Class pointers are arena-backed and immutable after
/// linking, so reading `name`/`fqn`/`parent`/`interfaces` off `asPtr()` needs
/// no borrow (mirrors `ClassDef.findMethodWalk`).
pub fn collectClassClosure(
    cls: *const ClassDef,
    out: *std.ArrayList(*const ClassDef),
    seen: *std.ArrayList(*const ClassDef),
    allocator: Allocator,
) void {
    for (seen.items) |p| if (p == cls) return;
    if (seen.items.len > ClassDef.MAX_WALK) return;
    seen.append(allocator, cls) catch return;
    out.append(allocator, cls) catch return;
    if (cls.parent) |p| collectClassClosure(p.asPtr(), out, seen, allocator);
    for (cls.interfaces) |iface| collectClassClosure(iface.asPtr(), out, seen, allocator);
}

/// The member EXTENSION named `name` with `nparams` parameters that
/// `receiver`'s class declares or inherits, most-derived first. Answers from
/// the module's per-class member index, so a bare member-extension dispatch
/// costs a walk of the receiver's own supertypes instead of a scan of every
/// same-named declaration in the program.
pub const MEXT_OVERRIDE_MAX = 4;
/// `gen` is the dispatch-cache generation the program boundary bumps: the key
/// is a class identity plus a name's storage address, both of which the next
/// program can mint again, and the entry holds that program's function ids.
pub const MextOverrideEntry = struct {
    cls: u64 = 0,
    name_p: usize = 0,
    nparams: u32 = 0,
    n: u32 = 0,
    fids: [MEXT_OVERRIDE_MAX]u32 = @splat(0),
    valid: bool = false,
    gen: u32 = 0,
};
pub const MEXT_OVERRIDE_SLOTS = 1024;
pub threadlocal var mext_override_cache: [MEXT_OVERRIDE_SLOTS]MextOverrideEntry = @splat(.{});

/// The member EXTENSIONS named `name` with `nparams` parameters that
/// `receiver`'s class declares or inherits, most-derived first (at most
/// `out.len`). Answers from the module's per-class member index behind a
/// direct-mapped per-thread cache, so a repeated bare member-extension
/// dispatch — the changelist executes one operation per node update — costs
/// a probe instead of a scan over every same-named declaration in the
/// program. Returns how many entries of `out` were written.
pub fn memberExtOverridesFor(self: *VmHost, receiver: *const Value, name: []const u8, nparams: usize, out: []ir.FuncId) usize {
    if (receiver.* != .Instance) return 0;
    const cls_id: u64 = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().class.identity());
    };
    const slot = (cls_id ^ (@intFromPtr(name.ptr) >> 3) ^ (nparams *% 0x9E37)) & (MEXT_OVERRIDE_SLOTS - 1);
    const e = mext_override_cache[slot];
    if (e.valid and e.gen == cacheGen() and e.cls == cls_id and e.name_p == @intFromPtr(name.ptr) and e.nparams == nparams) {
        const n = @min(e.n, out.len);
        for (0..n) |i| out[i] = @enumFromInt(e.fids[i]);
        return n;
    }
    var found: [MEXT_OVERRIDE_MAX]ir.FuncId = @splat(@enumFromInt(0));
    const n = memberExtOverrideLookup(self, receiver, name, nparams, &found);
    var entry = MextOverrideEntry{
        .cls = cls_id,
        .name_p = @intFromPtr(name.ptr),
        .nparams = @intCast(nparams),
        .n = @intCast(n),
        .valid = true,
        .gen = cacheGen(),
    };
    for (0..n) |i| entry.fids[i] = @intCast(found[i].int());
    mext_override_cache[slot] = entry;
    const m = @min(n, out.len);
    for (0..m) |i| out[i] = found[i];
    return m;
}

pub fn memberExtOverrideLookup(self: *VmHost, receiver: *const Value, name: []const u8, nparams: usize, out: []ir.FuncId) usize {
    const a = self.allocator;
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(a);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(a);
    {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        collectClassClosure(g.get().class.asPtr(), &closure, &seen, a);
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    var n: usize = 0;
    for (closure.items) |cd| {
        for ([2][]const u8{ cd.fqn, cd.name }) |owner| {
            if (owner.len == 0) continue;
            for (mod.memberDecls(owner, name)) |fid| {
                const fp = mod.funcById(fid) orelse continue;
                if (fp.kind != .member_extension) continue;
                if (fp.params.len != nparams) continue;
                if (fp.params.len == 0 or !std.mem.eql(u8, fp.params[0].name, "this")) continue;
                // Pack functions are lazy-bodied: an unensured declaration
                // reports no body and silently vanished from the pick
                // (foundation-layout's Density.targetConstraints getter
                // fell through to an unresolved global). Ensure first.
                if (fp.blocks.len == 0) _ = mod.ensureFuncBody(@constCast(fp));
                if (!fp.hasBody()) continue;
                var dup = false;
                for (out[0..n]) |seen_fid| {
                    if (seen_fid.int() == fid.int()) dup = true;
                }
                if (dup) continue;
                out[n] = fid;
                n += 1;
                if (n == out.len) return n;
            }
            if (std.mem.eql(u8, cd.fqn, cd.name)) break;
        }
    }
    return n;
}

/// Set of class names (with the full supertype closure — superclasses AND
/// interfaces) reachable through the enclosing-this chain, including each
/// instance's `outer` links, and through the executing frames' own
/// receivers, which the dynamic chain does not carry (an extension body
/// binds its receiver in `params[0]`, never by pushing it; inside
/// `ColumnMeasurePolicy.measure(MeasureScope)` the `MeasureScope` is a
/// `Density`, which is what makes `Dp.roundToPx()` visible there).
///
/// Held as the chain's class identities; a membership probe asks each
/// class's memoized closure-name set (`classClosureNames`). An extension
/// call whose candidates include a member-extension is never served by the
/// inline cache, so it asks for this set on every call, and building it —
/// a closure walk per receiver plus a fresh hash map of every name — grew
/// with the nesting depth of the composition it ran in. Nothing is
/// allocated per call now beyond the chain snapshot.
pub const OwnerSet = struct {
    sig: [OWNER_SIG_MAX]usize = @splat(0),
    n: u32 = 0,
    /// The walked set for a chain longer than `sig` holds.
    owned: ?std.StringHashMap(void) = null,
    fn contains(self: *const OwnerSet, key: []const u8) bool {
        if (self.owned) |*m| return m.contains(key);
        for (self.sig[0..self.n]) |p| {
            if (classClosureNames(@ptrFromInt(p)).contains(key)) return true;
        }
        return false;
    }
    pub fn deinit(self: *OwnerSet) void {
        if (self.owned) |*m| m.deinit();
    }
    fn add(self: *OwnerSet, cls: usize) bool {
        for (self.sig[0..self.n]) |p| if (p == cls) return true;
        if (self.n == OWNER_SIG_MAX) return false;
        self.sig[self.n] = cls;
        self.n += 1;
        return true;
    }
};
pub const OWNER_SIG_MAX = 48;
/// One memoized closure-name set. Class definitions are arena-backed and
/// immutable after linking, so the set is built once per class for the
/// process and shared; the entry is validated by the class's `fqn` slice,
/// which keeps it sound should a definition's address ever be reused.
pub const ClosureNamesEntry = struct { fqn_p: usize, fqn_len: usize, set: *const std.StringHashMap(void) };
pub const ClosureNamesFront = struct { cls: usize = 0, fqn_p: usize = 0, fqn_len: usize = 0, set: ?*const std.StringHashMap(void) = null };
pub const CLOSURE_NAMES_FRONT_SLOTS = 512;
pub threadlocal var closure_names_front: [CLOSURE_NAMES_FRONT_SLOTS]ClosureNamesFront = @splat(.{});
pub var closure_names_lock = std.atomic.Value(bool).init(false);
pub var closure_names_map: ?std.AutoHashMap(usize, ClosureNamesEntry) = null;
pub fn classClosureNames(cls: *const ClassDef) *const std.StringHashMap(void) {
    const key = @intFromPtr(cls);
    const fqn_p = @intFromPtr(cls.fqn.ptr);
    const front = &closure_names_front[((key *% 0x9E3779B97F4A7C15) >> 32) % CLOSURE_NAMES_FRONT_SLOTS];
    if (front.cls == key and front.fqn_p == fqn_p and front.fqn_len == cls.fqn.len) {
        if (front.set) |s| return s;
    }
    const pa = std.heap.page_allocator;
    while (closure_names_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer closure_names_lock.store(false, .release);
    if (closure_names_map == null) closure_names_map = .init(pa);
    const map = &closure_names_map.?;
    const set: *const std.StringHashMap(void) = blk: {
        if (map.get(key)) |e| {
            if (e.fqn_p == fqn_p and e.fqn_len == cls.fqn.len) break :blk e.set;
        }
        const s = pa.create(std.StringHashMap(void)) catch @panic("out of memory");
        s.* = .init(pa);
        var closure: std.ArrayList(*const ClassDef) = .empty;
        defer closure.deinit(pa);
        var seen: std.ArrayList(*const ClassDef) = .empty;
        defer seen.deinit(pa);
        collectClassClosure(cls, &closure, &seen, pa);
        for (closure.items) |cd| {
            s.put(cd.name, {}) catch {};
            s.put(cd.fqn, {}) catch {};
        }
        map.put(key, .{ .fqn_p = fqn_p, .fqn_len = cls.fqn.len, .set = s }) catch {};
        break :blk s;
    };
    front.* = .{ .cls = key, .fqn_p = fqn_p, .fqn_len = cls.fqn.len, .set = set };
    return set;
}
pub fn enclosingOwnerSet(self: *VmHost, allocator: Allocator) Allocator.Error!OwnerSet {
    var out: OwnerSet = .{};
    var overflow = false;
    {
        const chain = try enclosingThisChain(self, allocator);
        defer allocator.free(chain);
        for (chain) |v| {
            var cur: ?Value = v;
            while (cur) |cv| {
                if (cv != .Instance) break;
                const g = cv.Instance.borrow();
                const cls = @intFromPtr(g.get().class.asPtr());
                const outer = g.get().outer;
                g.deinit();
                if (!out.add(cls)) overflow = true;
                cur = outer;
            }
        }
        var fit = ir.eval.frameThisChainIter();
        while (fit.next()) |fv| {
            var cur: ?Value = fv;
            while (cur) |cv| {
                if (cv != .Instance) break;
                const g = cv.Instance.borrow();
                const cls = @intFromPtr(g.get().class.asPtr());
                const outer = g.get().outer;
                g.deinit();
                if (!out.add(cls)) overflow = true;
                cur = outer;
            }
        }
    }
    if (!overflow) return out;
    out.owned = try enclosingOwnerSetWalk(self, allocator);
    return out;
}
/// The walked form of `enclosingOwnerSet`: every closure name of every
/// receiver in scope, in one caller-owned map.
pub fn enclosingOwnerSetWalk(self: *VmHost, allocator: Allocator) Allocator.Error!std.StringHashMap(void) {
    var set: std.StringHashMap(void) = .init(allocator);
    const chain = try enclosingThisChain(self, allocator);
    defer allocator.free(chain);
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(allocator);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(allocator);
    for (chain) |v| {
        var cur: ?Value = v;
        while (cur) |cv| {
            if (cv != .Instance) break;
            const g = cv.Instance.borrow();
            closure.clearRetainingCapacity();
            collectClassClosure(g.get().class.asPtr(), &closure, &seen, allocator);
            for (closure.items) |cd| {
                set.put(cd.name, {}) catch {};
                set.put(cd.fqn, {}) catch {};
            }
            const outer = g.get().outer;
            g.deinit();
            cur = outer;
        }
    }
    var fit = ir.eval.frameThisChainIter();
    while (fit.next()) |fv| {
        var cur: ?Value = fv;
        while (cur) |cv| {
            if (cv != .Instance) break;
            const g = cv.Instance.borrow();
            closure.clearRetainingCapacity();
            collectClassClosure(g.get().class.asPtr(), &closure, &seen, allocator);
            for (closure.items) |cd| {
                set.put(cd.name, {}) catch {};
                set.put(cd.fqn, {}) catch {};
            }
            const outer = g.get().outer;
            g.deinit();
            cur = outer;
        }
    }
    return set;
}

/// `delegateForward` with argument names threaded through, so a delegated
/// member invoked with named arguments binds its parameters by name.
pub fn delegateForwardNamed(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var delegates: std.ArrayList(Value) = .empty;
    defer delegates.deinit(allocator);
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
            const iface = f.name["__delegate__".len..];
            if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) == false) continue;
            try delegates.append(allocator, f.value);
        }
    }
    for (delegates.items) |d| {
        const r = try callMemberNamed(self, allocator, &d, name, args, arg_names);
        switch (r) {
            .ok => return r,
            .err => |e| {
                if (e != .Unimplemented) return r;
                freeDispatchMiss(allocator, r);
            },
        }
    }
    return null;
}

pub fn delegateForward(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value, swallow_unimplemented_only: bool) Allocator.Error!?EvalResult {
    const inst = receiver.Instance;
    var delegates: std.ArrayList(Value) = .empty;
    defer delegates.deinit(allocator);
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
            // Kotlin class delegation forwards only the members the
            // delegated interface itself declares. An extension function
            // or an unrelated name must NOT fall through to the delegate:
            // it would rebind `this` to the delegate object (e.g.
            // `Continuation.resumeCancellableWithInternal` running against
            // the wrapped continuation instead of the DispatchedContinuation
            // wrapper, which silently skipped the dispatcher).
            const iface = f.name["__delegate__".len..];
            if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) == false) continue;
            try delegates.append(allocator, f.value);
        }
    }
    for (delegates.items) |d| {
        const r = try callMemberRec(self, allocator, &d, name, args);
        switch (r) {
            .ok => return r,
            .err => |e| {
                if (swallow_unimplemented_only) {
                    if (e != .Unimplemented) return r;
                }
                // else: swallow all errors and continue. The swallowed miss's
                // `Vm::call_member` message is discarded here; free it.
                freeDispatchMiss(allocator, r);
            },
        }
    }
    return null;
}

/// Whether the interface a class delegates to (named by the suffix of a
/// `__delegate__<iface>` field) declares a member `name` anywhere on its
/// hierarchy. Returns `null` when the interface cannot be resolved (the
/// caller keeps the legacy forward-anything behavior), `true`/`false`
/// when membership is decidable.
/// The delegate a `by` clause makes responsible for `name`, or null when the
/// receiver answers it itself.
///
/// Kotlin generates a forwarding member for EVERY member of a delegated
/// interface the class does not override — including members the interface
/// supplies a default body for. Resolution reaches an inherited default first,
/// so without this the default runs against the wrapper and the delegate is
/// never consulted (`SerialDescriptor.annotations` has a default body, and a
/// `ContextDescriptor(original) : SerialDescriptor by original` reported the
/// empty default instead of the wrapped descriptor's annotations).
pub fn interfaceDelegateFor(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) ?Value {
    var has_delegate = false;
    {
        const g = inst.borrow();
        defer g.deinit();
        for (g.get().fields.items) |f| {
            if (std.mem.startsWith(u8, f.name, "__delegate__")) {
                has_delegate = true;
                break;
            }
        }
    }
    if (!has_delegate) return null;
    // A member the receiver's own class chain declares is not forwarded —
    // that is exactly the `override` the compiler skips generating for.
    if (concreteChainDeclares(self, allocator, inst, name)) return null;
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items) |f| {
        if (!std.mem.startsWith(u8, f.name, "__delegate__")) continue;
        const iface = f.name["__delegate__".len..];
        if (delegatedInterfaceDeclares(self, allocator, inst, iface, name) != true) continue;
        return f.value;
    }
    return null;
}

/// Whether the anon-method table holds a member `name` for `class_name`, at
/// any arity or as an accessor. Entries are keyed `class\x1fname#arity` and
/// `class\x1fname`, so a prefix scan answers "declared at all".
pub fn anonClassDeclares(self: *VmHost, allocator: Allocator, class_name: []const u8, name: []const u8) bool {
    const tbl = self.anon_methods.borrow();
    defer tbl.deinit();
    if (tbl.get().count() == 0) return false;
    var kb: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&kb, "{s}\u{1f}{s}", .{ class_name, name }) catch {
        const p = anonKey(allocator, class_name, name) catch return false;
        defer allocator.free(p);
        return anonTableHasPrefix(tbl.get(), p);
    };
    return anonTableHasPrefix(tbl.get(), prefix);
}

pub fn anonTableHasPrefix(tbl: anytype, prefix: []const u8) bool {
    if (tbl.get(prefix) != null) return true;
    var it = tbl.keyIterator();
    while (it.next()) |k| {
        if (!std.mem.startsWith(u8, k.*, prefix)) continue;
        // Either an exact hit or the `name#arity` form — never a longer name.
        if (k.len == prefix.len or k.*[prefix.len] == '#') return true;
    }
    return false;
}

/// Whether the receiver's own CLASS chain (never its interfaces) declares
/// `name`. An interface's own body is exactly what a `by` clause replaces; a
/// class's is an `override`, which the compiler honours over the delegate.
pub fn concreteChainDeclares(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), name: []const u8) bool {
    {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        for (cg.get().primary_params) |*p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) return true;
        }
        for (cg.get().body_properties) |*p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
    }
    // An anonymous / local class keeps its members in the anon-method table
    // rather than on its `ClassDef`, and `object : I by d { override … }` is
    // the shape that most often carries the override.
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        const class_name = cg.get().name;
        const is_anon = cg.get().is_anonymous;
        const found = is_anon and anonClassDeclares(self, allocator, class_name, name);
        cg.deinit();
        g.deinit();
        if (found) return true;
    }
    const cls = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    defer cls.deinit();
    if (ClassDef.findMethod(cls, allocator, name)) |hit| {
        const cg = hit.class.borrow();
        const from_class = !cg.get().is_interface;
        cg.deinit();
        hit.class.deinit();
        if (from_class) return true;
    }
    // The runtime class def carries only what the class body lowered; the
    // module's class table is the authority on which declaration owns a
    // method, so walk the CLASS supertypes there too.
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = mg.get();
    var cur: ?ir.ClassId = blk: {
        const g = inst.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk module.classIdByFqn(cg.get().fqn) orelse module.classId(cg.get().name);
    };
    var hops: u8 = 0;
    while (cur) |cid| : (hops += 1) {
        if (hops > ClassDef.MAX_WALK or cid.int() >= module.classes.items.len) break;
        const c = &module.classes.items[cid.int()];
        if (c.is_interface) break;
        for (c.methods) |mfid| {
            const f = module.funcById(mfid) orelse continue;
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        cur = null;
        for (c.supertypes) |sid| {
            if (sid.int() >= module.classes.items.len) continue;
            if (module.classes.items[sid.int()].is_interface) continue;
            cur = sid;
            break;
        }
    }
    return false;
}

pub fn delegatedInterfaceDeclares(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), iface_name_raw: []const u8, name: []const u8) ?bool {
    // The key carries the source-spelled supertype; strip generic args
    // (`Continuation<T>` -> `Continuation`).
    var iface_name = iface_name_raw;
    if (std.mem.findScalar(u8, iface_name, '<')) |lt| iface_name = iface_name[0..lt];
    iface_name = std.mem.trim(u8, iface_name, " ");
    if (std.mem.findScalarLast(u8, iface_name, '.')) |dot| iface_name = iface_name[dot + 1 ..];
    if (iface_name.len == 0) return null;

    // Resolve lexically first (the class's captured declaration env), then
    // via the global class table.
    // The lowered hierarchy registry covers what `ClassDef.findMethod`
    // cannot see: abstract interface members have no lowered body, so
    // they never appear in `methods`, yet Kotlin forwards exactly those
    // through `by` delegation (`interface Greeter { fun greet(): String }`).
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(iface_name)) |methods| {
            if (methods.contains(name)) return true;
        }
    }
    const iface_def: ?ObjRef(ClassDef) = blk: {
        {
            const g = inst.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            const eg = cg.get().captured_env.borrow();
            defer eg.deinit();
            if (eg.get().lookup(iface_name)) |v| {
                if (v == .Class) break :blk v.Class.clone();
            }
        }
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(iface_name)) |d| break :blk d.clone();
        break :blk null;
    };
    const def = iface_def orelse return null;
    defer def.deinit();
    if (ClassDef.findMethod(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }
    if (ClassDef.findBodyProperty(def, allocator, name)) |hit| {
        hit.class.deinit();
        return true;
    }

    // A property may be dispatched through its synthesized accessor name.
    if (std.mem.startsWith(u8, name, "$get$") or std.mem.startsWith(u8, name, "$set$")) {
        const prop = name["$get$".len..];
        if (ClassDef.findBodyProperty(def, allocator, prop)) |hit| {
            hit.class.deinit();
            return true;
        }
    }
    return false;
}
