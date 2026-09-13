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

const common = @import("host_fields/common.zig");
const ok = common.ok;
const errRes = common.errRes;
const activeCoroScope = common.activeCoroScope;
const outerThisLast = common.outerThisLast;
const withFieldResolvePair = common.withFieldResolvePair;
const lastSegment = common.lastSegment;
const utf16Len = common.utf16Len;
const frozenList = common.frozenList;
const evalGetter = common.evalGetter;
const evalGetterTagged = common.evalGetterTagged;
const lookupPairFunc = common.lookupPairFunc;
const lookupPairFuncHop = common.lookupPairFuncHop;
const lookupIntrinsic = common.lookupIntrinsic;
const dispatchIntrinsic = common.dispatchIntrinsic;
const typeHeadOf = common.typeHeadOf;
const unwrapCellRead = common.unwrapCellRead;
const freeMissErr = common.freeMissErr;
const receiverLabel = common.receiverLabel;
const classSimpleName = common.classSimpleName;
const enclosingNameOf = common.enclosingNameOf;
const anonKey = common.anonKey;
const className = common.className;
const classFqnOf = common.classFqnOf;
const instanceIsHostSynth = common.instanceIsHostSynth;
const firstSupertypeOf = common.firstSupertypeOf;
const companionSimpleName = common.companionSimpleName;
const firstSupertype = common.firstSupertype;
const containsStr = common.containsStr;
const matchAny = common.matchAny;
const listLen = common.listLen;
const collectionLen = common.collectionLen;

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

/// Re-entrancy flag for the inner-class outer-chain field fallback.

/// Assert (Debug) the field-resolution stack and its re-entrancy flags are
/// clear at a run boundary and reset them so leaked-across-runs state is a
/// loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(fldTls().field_resolve_stack.items.len == 0);
    std.debug.assert(!fldTls().field_outer_active);
    fldTls().field_resolve_stack.clearRetainingCapacity();
    fldTls().field_outer_active = false;
}

/// Every per-thread cache this module keeps, as ONE threadlocal. Darwin
/// resolves a threadlocal access through a `_tlv_get_addr` CALL, and the
/// field paths touch several of these per operation — as one struct the
/// base is fetched once and each cache is an offset from it.
pub const FieldsTls = struct {
    field_resolve_stack: std.ArrayList(ResolvePair) = .empty,
    field_outer_active: bool = false,
    anon_recv_depth: usize = 0,
    owner_keyed_memo: [1024]OwnerKeyedSlot = @splat(.{}),
    owner_keyed_memo_set: [1024]OwnerKeyedSlot = @splat(.{}),
    tl_field_read_cache: [TL_FIELD_CACHE_SIZE]TlFieldReadEntry = @splat(.{}),
    tl_field_write_cache: [TL_FIELD_CACHE_SIZE]TlFieldWriteEntry = @splat(.{}),
    super_write_owner: ?[]const u8 = null,
    anon_key_buf: [512]u8 = undefined,
};
/// Owner thread reads the global copy, every other thread its own — see
/// `runtime.tls_fast`.
var fld_tls_owner: FieldsTls = .{};
threadlocal var fld_tls_other: FieldsTls = .{};
pub inline fn fldTls() *FieldsTls {
    return if (runtime.tls_fast.isOwner()) &fld_tls_owner else &fld_tls_other;
}

/// This thread's field caches. Resolved ONCE when a `VmHost` view is built (a
/// handful of times per run) and reached through `self.tls` afterwards: on
/// Darwin a threadlocal access is a `_tlv_get_addr` CALL, and these caches sit
/// on the per-field-operation path, so re-resolving them per operation put
/// thread-local access at the top of the interpreter profile.
pub fn currentTls() *FieldsTls {
    return fldTls();
}

const ResolvePair = struct { id: usize, name: []const u8 };

// -------------------------------------------------------------------------
// get_field
// -------------------------------------------------------------------------

pub fn getField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return lexicalReceiverFallback(self, allocator, receiver, name, unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, false, false)));
}

const enum_static = @import("host_fields/enum_static.zig");
pub const enumTableClass = enum_static.enumTableClass;
pub const leafStaticMember = enum_static.leafStaticMember;
pub const enumTableDef = enum_static.enumTableDef;
pub const enumStaticNameHits = enum_static.enumStaticNameHits;
const enumEntryByOwner = enum_static.enumEntryByOwner;
pub const enclosingEnumEntry = enum_static.enclosingEnumEntry;
pub const enclosingEnumDef = enum_static.enclosingEnumDef;
pub const enclosingEnumEntryByOwner = enum_static.enclosingEnumEntryByOwner;

const bound_ref = @import("host_fields/bound_ref.zig");
pub const BoundRefParts = bound_ref.BoundRefParts;
pub const boundRefParts = bound_ref.boundRefParts;
pub const stampRefAdaptation = bound_ref.stampRefAdaptation;
const classDeclaresStoredProp = bound_ref.classDeclaresStoredProp;
pub const sgetterNameMatches = bound_ref.sgetterNameMatches;
pub const memberRef = bound_ref.memberRef;

var miss_trace_state: u8 = 0;
var miss_trace_want: []const u8 = "";
/// Cached KLIO_MISS_TRACE value; consulted on per-call paths (the getter
/// runner, the field ladder), where a raw getenv is a spinlock + probe.
pub fn missTraceEnvCached() ?[]const u8 {
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

/// Depth bound for the lexical-receiver fallback below: an object literal
/// written inside another one chains, but a capture cycle must not.

const read_paths = @import("host_fields/read_paths.zig");
pub const getMemberField = read_paths.getMemberField;
pub const getMemberFieldNoExt = read_paths.getMemberFieldNoExt;
pub const FieldSiteClaim = read_paths.FieldSiteClaim;
pub const accessorFastGet = read_paths.accessorFastGet;
pub const storedNullServable = read_paths.storedNullServable;
pub const fieldWriteSiteRoute = read_paths.fieldWriteSiteRoute;
pub const fieldSiteRoute = read_paths.fieldSiteRoute;
pub const runFieldGetter = read_paths.runFieldGetter;
pub const fieldGetterIsLeaf = read_paths.fieldGetterIsLeaf;
pub const hostModulePtr = read_paths.hostModulePtr;
pub const funcRunsItsBody = read_paths.funcRunsItsBody;
const lexicalReceiverFallback = read_paths.lexicalReceiverFallback;
pub const plainStoredFieldIndex = read_paths.plainStoredFieldIndex;
const declaredBackingZero = read_paths.declaredBackingZero;
const isScalarTypeName = read_paths.isScalarTypeName;
pub const plainStoredScalarFieldNN = read_paths.plainStoredScalarFieldNN;
pub const freeFieldMiss = read_paths.freeFieldMiss;
const builtinMemberProperty = read_paths.builtinMemberProperty;
const fillCompanionReadMemo = read_paths.fillCompanionReadMemo;

const get_field_inner = @import("host_fields/get_field_inner.zig");
const getFieldInner = get_field_inner.getFieldInner;

const class_access = @import("host_fields/class_access.zig");
const companionMemberOfClass = class_access.companionMemberOfClass;
const classReceiverField = class_access.classReceiverField;
const enclosingSimpleFromFqn = class_access.enclosingSimpleFromFqn;
const companionInstanceForDef = class_access.companionInstanceForDef;
const companionInstanceForClass = class_access.companionInstanceForClass;
pub const companionOfClassValue = class_access.companionOfClassValue;
const classReflective = class_access.classReflective;

const ext_props = @import("host_fields/ext_props.zig");
const resolveExtensionProp = ext_props.resolveExtensionProp;
const memberExtOutOfScope = ext_props.memberExtOutOfScope;
const classExtPropUsesCompanion = ext_props.classExtPropUsesCompanion;
const extensionPropRead = ext_props.extensionPropRead;
const resolveExtensionPropSetter = ext_props.resolveExtensionPropSetter;
const delegateCall = ext_props.delegateCall;
pub const hostHasExtProp = ext_props.hostHasExtProp;
pub const extPropDeclaredCallable = ext_props.extPropDeclaredCallable;
pub const declaredTypeIsCallable = ext_props.declaredTypeIsCallable;
pub const enclosingCompanionMember = ext_props.enclosingCompanionMember;
pub const hostHasExtPropSetter = ext_props.hostHasExtPropSetter;
const ExtDelegateHit = ext_props.ExtDelegateHit;
const resolveExtPropDelegate = ext_props.resolveExtPropDelegate;
const extPropDelegateInstance = ext_props.extPropDelegateInstance;
const runThunkValue = ext_props.runThunkValue;
const ownerKeyedSlotKey = ext_props.ownerKeyedSlotKey;
const ownerKeyedForClass = ext_props.ownerKeyedForClass;
const ownerKeyedProbeOne = ext_props.ownerKeyedProbeOne;
const ownerKeyedExtProp = ext_props.ownerKeyedExtProp;
const ownerKeyedViaDelegates = ext_props.ownerKeyedViaDelegates;
const importOwnedExtProp = ext_props.importOwnedExtProp;
const resolveExtensionPropImpl = ext_props.resolveExtensionPropImpl;
const memberExtOwnerRead = ext_props.memberExtOwnerRead;
const runtimeClassDelegatesProp = ext_props.runtimeClassDelegatesProp;
const delegatedPropRegistered = ext_props.delegatedPropRegistered;

/// Probe the owner-qualified extension-prop keys (`"<Owner>\x00<recv>"`)
/// for every class on the lexical receiver tower — a PRIVATE member-ext
/// property (`private val Placeable.mainAxisSize` in each lazy item type)
/// shares its (receiver, name) pair across owners, and only the
/// declaration whose owner is in scope is the one kotlinc bound.
/// One `(owning class, receiver key, property name)` verdict. The registry
/// and the class graph are both fixed once the program is loaded, so a class
/// that does not own `name` for `recv_key` never starts owning it — the
/// negative answer is as cacheable as the positive one.
pub const OwnerKeyedSlot = struct { key: u64 = 0, gen: u32 = 0, fid: u32 = NO_FID, hit: bool = false };
pub const NO_FID: u32 = std.math.maxInt(u32);

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

const instance_field = @import("host_fields/instance_field.zig");
const instanceField = instance_field.instanceField;
const enclosingCompanionDeclares = instance_field.enclosingCompanionDeclares;
const resolveInstanceGetter = instance_field.resolveInstanceGetter;
const declaresStored = instance_field.declaresStored;
const unwrapDelegate = instance_field.unwrapDelegate;
const companionParentWalk = instance_field.companionParentWalk;
const enclosingCompanionWalk = instance_field.enclosingCompanionWalk;
const companionWalkSeeded = instance_field.companionWalkSeeded;
const outerInstanceChain = instance_field.outerInstanceChain;
const instanceDeclaresProperty = instance_field.instanceDeclaresProperty;

/// Thread-local L1 in front of the shared field-resolution memos: the
/// shared maps live behind the program cell's reader lock, whose atomic
/// state word ping-pongs between cores on every borrow — the same
/// coherence cost the method-cache L1 in `host_call_member` removes.
/// A slot mirrors a shared-map entry; the hit site re-verifies stored
/// slots by name anyway, so a stale slot is at worst a fall-through to
/// the ladder. The generation stamp keeps entries from a finished
/// in-process program (reused cell addresses) from ever hitting,
/// including on still-parked pool worker threads.
pub const TL_FIELD_CACHE_SIZE = 1024;
const TlFieldReadEntry = struct { class_p: usize = 0, name_p: usize = 0, gen: u32 = 0, state: u8 = 0, miss_ttl: u8 = 0, hit: root.ProgramImage.FieldReadHit = .{ .getter = 0, .stored_idx = 0 } };
const TlFieldWriteEntry = struct { class_p: usize = 0, name_p: usize = 0, gen: u32 = 0, state: u8 = 0, miss_ttl: u8 = 0, hit: root.ProgramImage.FieldWriteHit = .{ .setter = 0, .store_name = "" } };

const field_cache = @import("host_fields/field_cache.zig");
const tlFieldSlot = field_cache.tlFieldSlot;
const fieldReadCacheGet = field_cache.fieldReadCacheGet;
const fieldWriteCacheGet = field_cache.fieldWriteCacheGet;
const fieldReadCachePut = field_cache.fieldReadCachePut;
const fieldWriteCachePut = field_cache.fieldWriteCachePut;
const storePlainField = field_cache.storePlainField;
const sgetterMemoSafe = field_cache.sgetterMemoSafe;
const sgetterPutGetter = field_cache.sgetterPutGetter;
const sgetterCopyMemo = field_cache.sgetterCopyMemo;
const storedNullIsLateinit = field_cache.storedNullIsLateinit;
const lateinitReadError = field_cache.lateinitReadError;

// -------------------------------------------------------------------------
// set_field
// -------------------------------------------------------------------------

/// The class a `super.prop = v` write was made from, for the duration of that
/// write. The setter search then starts at that class's SUPERTYPES: an
/// overriding setter whose body writes `super.prop` must reach the base
/// accessor, never itself.

const set_field = @import("host_fields/set_field.zig");
pub const setField = set_field.setField;
pub const setFieldFrom = set_field.setFieldFrom;
const setFieldInner = set_field.setFieldInner;
const setCompanionParentWalk = set_field.setCompanionParentWalk;
const evalSetter = set_field.evalSetter;

// -------------------------------------------------------------------------
// Tests
//
// These exercise dispatch-chain behaviors that do not require a fully
// wired Vm (the foundation's stubbed siblings).
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    inline for (.{ common, enum_static, bound_ref, read_paths, get_field_inner, class_access, ext_props, instance_field, field_cache, set_field }) |m| testing.refAllDecls(m);
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

/// A property read that answers from the receiver's own representation and
/// consults nothing else. A compiled program has no module to dispatch through
/// and reads these here, so there is one implementation rather than two.
pub fn hostFreeProperty(receiver: *const Value, name: []const u8) ?Value {
    // Progression `first`/`last`/`step` *reads* (no parens): `first`/`last`
    // return the stored bound even when empty (the `Iterable.first()`/`last()`
    // *functions*, dispatched as calls, still throw on empty); `step` is always
    // Int (Int/Char/UInt) or Long (Long/ULong) with its sign. Applies to a host
    // `Value.Range` and to a source range `Instance` (e.g. `ULongRange.EMPTY`,
    // whose `step` field would otherwise read back as Int).
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last") or std.mem.eql(u8, name, "step")) {
        if (stdlib.implementations.ranges.asRangeView(receiver)) |view| {
            if (std.mem.eql(u8, name, "step")) {
                return switch (view.kind) {
                    .Long, .ULong => Value{ .Long = view.step },
                    .Int, .Char, .UInt => Value{ .Int = @truncate(view.step) },
                };
            }
            const v: i64 = if (std.mem.eql(u8, name, "first")) view.start else view.end;
            return switch (view.kind) {
                .Int => .{ .Int = @truncate(v) },
                .Long => .{ .Long = v },
                .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
                .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
                .ULong => .{ .ULong = @bitCast(v) },
            };
        }
    }
    return null;
}
