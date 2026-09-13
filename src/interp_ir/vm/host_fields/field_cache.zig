//! The field-site caches: the thread-local L1 in front of the shared
//! read/write memos, the plain-slot store, and the synthetic-getter memo.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const VmHost = vmhost.VmHost;
const root = @import("../../interp_ir.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
const UnitResult = ir.eval.UnitResult;

const host_fields = @import("../host_fields.zig");
const TL_FIELD_CACHE_SIZE = host_fields.TL_FIELD_CACHE_SIZE;

const common = @import("common.zig");
const errRes = common.errRes;
const lookupPairFunc = common.lookupPairFunc;

const bound_ref = @import("bound_ref.zig");
const classDeclaresStoredProp = bound_ref.classDeclaresStoredProp;

pub inline fn tlFieldSlot(class_p: usize, name_p: usize) usize {
    const h = (@as(u64, @intCast(class_p)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(name_p));
    return @intCast((h ^ (h >> 17)) & (TL_FIELD_CACHE_SIZE - 1));
}

pub fn fieldReadCacheGet(self: *VmHost, class_p: usize, name_p: usize) ?root.ProgramImage.FieldReadHit {
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    const e = &self.tls.tl_field_read_cache[tlFieldSlot(class_p, name_p)];
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

pub fn fieldWriteCacheGet(self: *VmHost, class_p: usize, name_p: usize) ?root.ProgramImage.FieldWriteHit {
    const gen = host_call_member.dispatch_cache_gen.load(.monotonic);
    const e = &self.tls.tl_field_write_cache[tlFieldSlot(class_p, name_p)];
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
pub fn fieldReadCachePut(self: *VmHost, inst: ObjRef(InstanceData), fqn: []const u8, name: []const u8, hit: root.ProgramImage.FieldReadHit) void {
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
pub fn fieldWriteCachePut(self: *VmHost, inst: ObjRef(InstanceData), fqn: []const u8, name: []const u8, hit: root.ProgramImage.FieldWriteHit) void {
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
pub fn storePlainField(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), store_name: []const u8, value: Value) Allocator.Error!UnitResult {
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
pub fn sgetterMemoSafe(self: *VmHost, rcn: []const u8, rest: []const u8, owner: []const u8, prop: []const u8) bool {
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
pub fn sgetterPutGetter(self: *VmHost, receiver: *const Value, full_name: []const u8, fid: FuncId) void {
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
pub fn sgetterCopyMemo(self: *VmHost, receiver: *const Value, prop: []const u8, full_name: []const u8) void {
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
pub fn storedNullIsLateinit(inst: ObjRef(InstanceData), name: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    for (cg.get().body_properties) |p| {
        if (std.mem.eql(u8, p.name, name) and p.is_lateinit) return true;
    }
    return false;
}

pub fn lateinitReadError(allocator: Allocator, name: []const u8) Allocator.Error!EvalResult {
    return errRes(try ir.eval.lateinitThrow(allocator, name));
}
