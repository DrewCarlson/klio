//! Constructor selection and the values a call binds: class lookups, secondary
//! ctor ranking, parent-chain argument thunks, the local-class parent chain.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = runtime.NameHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

const common = @import("common.zig");
const boundHead = common.boundHead;
const installCtorBounds = common.installCtorBounds;
const typeErr = common.typeErr;

const ctor_defaults = @import("ctor_defaults.zig");
const packSecondaryVarargs = ctor_defaults.packSecondaryVarargs;
const scoreCtorHeadsVararg = ctor_defaults.scoreCtorHeadsVararg;

const ctor_path = @import("ctor_path.zig");
const classDefPrimaryParamCount = ctor_path.classDefPrimaryParamCount;
const instanceOfClassName = ctor_path.instanceOfClassName;
const isAllUpper = ctor_path.isAllUpper;

const super_chain = @import("super_chain.zig");
const UnitOrErr = super_chain.UnitOrErr;
const bindThrowableArgs = super_chain.bindThrowableArgs;
const isBuiltinThrowableName = super_chain.isBuiltinThrowableName;

/// Look up a runtime `ClassDef` by simple name; the handle is fresh, caller frees.
/// `KLIO_CTOR_NAME_PROBE=1`: how many name-keyed lookups one program's
/// constructions make. A site carrying a `ClassId` is only resolved if the
/// path from it to the object never consults a name, so this counts what
/// would have to go.
pub var ctor_name_probes: std.atomic.Value(usize) = .init(0);
pub var ctor_count: std.atomic.Value(usize) = .init(0);

var ctor_probe_state: u8 = 0;
pub fn ctorNameProbeOn() bool {
    if (ctor_probe_state == 0)
        ctor_probe_state = if (std.c.getenv("KLIO_CTOR_NAME_PROBE") != null) 2 else 1;
    return ctor_probe_state == 2;
}

var ctor_audit_state: u8 = 0;
pub fn ctorNameAuditOn() bool {
    if (ctor_audit_state == 0)
        ctor_audit_state = if (std.c.getenv("KLIO_CTOR_NAME_AUDIT") != null) 2 else 1;
    return ctor_audit_state == 2;
}

threadlocal var ctor_audit_depth: usize = 0;
threadlocal var sampled: usize = 0;

/// True when this is the outermost construction on the thread.
pub fn ctorAuditEnter() bool {
    ctor_audit_depth += 1;
    return ctor_audit_depth == 1;
}

pub fn ctorAuditLeave() void {
    if (ctor_audit_depth != 0) ctor_audit_depth -= 1;
}

/// Set while the SAM parameter mask is being computed, so the probes it
/// makes are not attributed to a construction that happens to be running the
/// function it is asked about.
threadlocal var in_sam_mask: bool = false;

pub fn samMaskEnter() bool {
    const prev = in_sam_mask;
    in_sam_mask = true;
    return prev;
}

pub fn samMaskLeave(prev: bool) void {
    in_sam_mask = prev;
}

var ctor_pick_audit_state: u8 = 0;

/// `KLIO_CTOR_PICK_AUDIT=1`: run the lowering-side constructor pick beside the
/// value scoring on every construction and report where the two disagree.
pub fn ctorPickAuditOn() bool {
    if (ctor_pick_audit_state == 0)
        ctor_pick_audit_state = if (std.c.getenv("KLIO_CTOR_PICK_AUDIT") != null) 2 else 1;
    return ctor_pick_audit_state == 2;
}

/// `KLIO_CTOR_PICK_AUDIT=all` also names the constructions the site left open.
pub fn ctorPickAuditAll() bool {
    const v = std.c.getenv("KLIO_CTOR_PICK_AUDIT") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "all");
}

var ctor_pick_serve_state: u8 = 0;

/// Whether a construction takes the constructor its site named. Off leaves
/// every construction on the value scoring, which is what the audit compares
/// against.
pub fn ctorPickServeOn() bool {
    if (ctor_pick_serve_state == 0) {
        const v = std.c.getenv("KLIO_CTOR_PICK_SERVE");
        const off = (v != null and std.mem.eql(u8, std.mem.span(v.?), "0")) or ctorPickAuditOn();
        ctor_pick_serve_state = if (off) 1 else 2;
    }
    return ctor_pick_serve_state == 2;
}

pub var ctor_pick_agree: std.atomic.Value(usize) = .init(0);
pub var ctor_pick_differ: std.atomic.Value(usize) = .init(0);
pub var ctor_pick_undecided: std.atomic.Value(usize) = .init(0);

pub fn ctorPickAuditDump() void {
    if (!ctorPickAuditOn()) return;
    std.debug.print("[ctor-pick] agree={d} differ={d} static_undecided={d}\n", .{
        ctor_pick_agree.load(.monotonic),
        ctor_pick_differ.load(.monotonic),
        ctor_pick_undecided.load(.monotonic),
    });
}

pub fn ctorNameProbeDump() void {
    if (std.c.getenv("KLIO_CTOR_NAME_PROBE") == null) return;
    std.debug.print("[ctor-name] constructions={d} class_def_by_name_probes={d}\n", .{ ctor_count.load(.monotonic), ctor_name_probes.load(.monotonic) });
}

/// The runtime `ClassDef` a `ClassId` names, without going through the class
/// table's string keys.
///
/// The index is filled once per module from the ids the build already has. A
/// null answer is not "no such class": a class registered while the program
/// runs has no row, so the caller falls back to the name lookup and the
/// contract is unchanged.
/// The module `ClassId` a `ClassDef` resolves to, through the def's own memo
/// so the fqn probe runs once per class rather than once per use.
pub fn classIdOfDef(self: *VmHost, def: ObjRef(ClassDef)) ?ir.ClassId {
    const mod_id = @intFromPtr(self.module.asPtrConst());
    {
        const g = def.borrow();
        defer g.deinit();
        if (g.get().resolve_mod.load(.monotonic) == mod_id) {
            const plus1 = g.get().resolve_cid.load(.acquire);
            if (plus1 != 0) return ir.ClassId.from(plus1 - 1);
        }
    }
    const fqn = classDefFqnOf(def);
    const cid = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classIdByFqn(fqn) orelse return null;
    };
    const g = def.borrowMut();
    defer g.deinit();
    const d = g.get();
    if (d.resolve_mod.cmpxchgStrong(0, mod_id, .acq_rel, .monotonic) == null or
        d.resolve_mod.load(.monotonic) == mod_id)
    {
        d.resolve_cid.store(cid.int() + 1, .release);
    }
    return cid;
}

fn classDefFqnOf(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().fqn;
}

/// The `ClassDef` of `child`'s first non-interface supertype, by id.
///
/// The ctor chain walks parents once per construction and reached each by
/// name. A class's parent cannot change, so the id is resolved once and
/// memoized on the child beside the strings `first_super_*` already keep.
/// Null means "not answerable by id here" and the caller keeps its name
/// path: a parent outside this module, or a class registered at execution.
pub fn superDefById(self: *VmHost, child: ObjRef(ClassDef), parent_key: []const u8) ?ObjRef(ClassDef) {
    const mod_id = @intFromPtr(self.module.asPtrConst());
    {
        const g = child.borrow();
        defer g.deinit();
        if (g.get().super_cid_mod.load(.monotonic) == mod_id) {
            const plus1 = g.get().super_cid.load(.acquire);
            if (plus1 != 0) return classDefById(self, ir.ClassId.from(plus1 - 1));
            return null;
        }
    }
    const cid: ?ir.ClassId = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        break :blk m.classIdByFqn(parent_key) orelse m.uniqueClassIdBySimpleName(parent_key);
    };
    {
        const g = child.borrowMut();
        defer g.deinit();
        const d = g.get();
        if (d.super_cid_mod.cmpxchgStrong(0, mod_id, .acq_rel, .monotonic) == null or
            d.super_cid_mod.load(.monotonic) == mod_id)
        {
            d.super_cid.store(if (cid) |c| c.int() + 1 else 0, .release);
            d.super_cid_mod.store(mod_id, .release);
        }
    }
    const c = cid orelse return null;
    return classDefById(self, c);
}

pub fn classDefById(self: *VmHost, class: ir.ClassId) ?ObjRef(ClassDef) {
    const mod_id = @intFromPtr(self.module.asPtrConst());
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        const img = pg.get();
        // The table describes ONE module. Another module's id takes the name
        // path rather than claiming it: rebuilding the table per module made
        // two modules clear it between each other's constructions. Per-module
        // tables were then built and measured — they changed the audit by
        // nothing, because the probes a layered run makes inside a
        // construction are its ctor BODY's member calls, not this lookup.
        if (img.class_defs_module_identity != mod_id) return null;
        if (class.int() < img.class_defs_by_id.items.len) {
            if (img.class_defs_by_id.items[class.int()]) |d| return d.clone();
        }
    }
    // An empty slot: a class registered while the program runs. Resolve it
    // once and keep it.
    const names = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class.int() >= m.classes.items.len) return null;
        const c = &m.classes.items[class.int()];
        break :blk .{ c.fqn, c.name };
    };
    const found = classDefByName(self, names[0]) orelse classDefByName(self, names[1]) orelse return null;
    {
        const pg = self.prog.borrowMut();
        defer pg.deinit();
        const img = pg.get();
        if (img.class_defs_module_identity == mod_id and
            class.int() < img.class_defs_by_id.items.len and
            img.class_defs_by_id.items[class.int()] == null)
        {
            img.class_defs_by_id.items[class.int()] = found.clone();
        }
    }
    return found;
}

pub fn classDefByName(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    // Either knob arms the counter. Counting only under the PROBE knob made
    // the audit silently measure nothing whenever it ran alone, which is the
    // failure mode an audit is supposed to be immune to.
    if ((ctorNameProbeOn() or ctorNameAuditOn()) and !in_sam_mask) {
        const n = ctor_name_probes.fetchAdd(1, .monotonic);
        // `KLIO_CTOR_NAME_PROBE=2` names the callers of the first few probes,
        // because guessing which of a dozen call sites runs per construction
        // has been wrong twice.
        const v = std.c.getenv("KLIO_CTOR_NAME_PROBE");
        _ = &sampled;
        if (v != null and v.?[0] == '2' and ctor_audit_depth > 0 and sampled < 3) {
            std.debug.print("[ctor-name-site] probe={d} name={s} ret=0x{x}\n", .{ n, name, @returnAddress() });
            sampled += 1;
            std.debug.dumpCurrentStackTrace(.{});
        }
        // `=3` prints only the immediate caller, so a sweep can tally which
        // call sites a whole corpus reaches without a stack dump each time.
        if (v != null and v.?[0] == '3') {
            std.debug.print("[ctor-name-ret] 0x{x}\n", .{@returnAddress()});
        }
    }
    const g = self.classes.borrow();
    defer g.deinit();
    if (g.get().get(name)) |d| return d.clone();
    return null;
}

/// Resolve a dotted qualifier (`Outer.Inner`) as a `.`-aligned suffix of a
/// registered FQN, shortest match winning, so a nested base is told apart from
/// a same-simple-name class in scope. Fresh handle; caller frees.
pub fn classDefByQualifiedSuffix(self: *VmHost, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.findScalar(u8, qualified, '.') == null) return null;
    const g = self.classes.borrow();
    defer g.deinit();
    var best: ?ObjRef(ClassDef) = null;
    var best_len: usize = std.math.maxInt(usize);
    var it = g.get().valueIterator();
    while (it.next()) |d| {
        const dg = d.borrow();
        const fqn = dg.get().fqn;
        const ok = std.mem.endsWith(u8, fqn, qualified) and
            (fqn.len == qualified.len or fqn[fqn.len - qualified.len - 1] == '.');
        const flen = fqn.len;
        dg.deinit();
        if (ok and flen < best_len) {
            if (best) |b| b.deinit();
            best_len = flen;
            best = d.clone();
        }
    }
    return best;
}

/// Class-keyed side tables key on the FQN when there is one: the simple-name
/// entry may belong to a same-named class in another package.
pub fn sideTableKey(fqn: ?[]const u8, name: []const u8) []const u8 {
    const f = fqn orelse return name;
    return if (f.len != 0) f else name;
}

pub fn secondaryCtors(self: *VmHost, fqn: ?[]const u8, name: []const u8) []const root.build.SecondaryCtorEntry {
    const g = self.prog.borrow();
    defer g.deinit();
    const key = sideTableKey(fqn, name);
    const entries = g.get().secondary_ctors.get(key) orelse &.{};
    if (runtime.envOnce("KLIO_CTOR_TRACE") != null) {
        std.debug.print("[ctor] lookup key={s} entries={d}", .{ key, entries.len });
        for (entries) |e| {
            var withdef: usize = 0;
            for (e.default_arg_thunks) |d| {
                if (d != null) withdef += 1;
            }
            std.debug.print(" [params={d} defaults={d}]", .{ e.param_count, withdef });
        }
        std.debug.print("\n", .{});
    }
    return entries;
}

/// Whether a declared secondary ctor binds `n` arguments by count, required
/// through total. Gates ctor applicability: no bindable ctor, no construction.
pub fn classSecondaryCtorCanBind(self: *VmHost, fqn: []const u8, name: []const u8, n: usize) bool {
    const entries = secondaryCtors(self, if (fqn.len != 0) fqn else null, name);
    for (entries) |e| {
        var required: usize = 0;
        for (e.default_arg_thunks) |d| {
            if (d == null) required += 1;
        }
        if (n >= required and n <= e.param_count) return true;
    }
    return false;
}

pub fn valueTypeHead(v: Value) []const u8 {
    const fqn = v.typeFqn();
    if (std.mem.findScalarLast(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

pub fn headInSet(head: []const u8, set: []const []const u8) bool {
    for (set) |h| {
        if (std.mem.eql(u8, head, h)) return true;
    }
    return false;
}

pub const integral_heads = [_][]const u8{ "Int", "Long", "Short", "Byte", "UInt", "ULong", "UShort", "UByte", "Char" };

pub const collectionish_heads = [_][]const u8{ "Collection", "MutableCollection", "Iterable", "MutableIterable", "List", "MutableList", "Set", "MutableSet", "Sequence" };

/// Whether a parameter declared `declared` accepts `arg`: a class-instance arg
/// must subtype a concrete class-typed parameter; `Any` and type params take all.
pub fn paramAcceptsArg(self: *VmHost, declared_in: []const u8, arg: *const Value) bool {
    const declared = boundHead(declared_in);
    if (std.mem.eql(u8, declared, "Any")) return true;
    if (declared.len <= 2 and isAllUpper(declared)) return true;
    // A function-typed parameter accepts any callable regardless of arity head:
    // a receiver-style lambda and its declared head count receivers differently.
    if (std.mem.startsWith(u8, declared, "Function")) {
        return switch (arg.*) {
            .IrClosure => true,
            .Instance => blk: {
                const g = arg.Instance.borrow();
                defer g.deinit();
                break :blk g.get().get("__sam_target__") != null;
            },
            else => false,
        };
    }
    if (arg.* == .Instance) {
        if (instanceOfClassName(arg, declared)) return true;
        // Disqualify only when `declared` names a real class: a typealias has no
        // ClassDef, so its mismatch is unconfirmed and must not reject.
        return !namesAClass(self, declared);
    }
    // A builtin value against a definitely-different builtin kind cannot match; kind 0 accepts.
    const gk = builtinTypeKind(valueTypeHead(arg.*));
    const dk = builtinTypeKind(declared);
    if (gk != 0 and dk != 0 and gk != dk) return false;
    return true;
}

/// Whether `name` is a registered class, memoized by the name's identity.
///
/// Secondary-constructor scoring asks this of every declared parameter type
/// on every construction, and the answer is a property of the program. The
/// strings are the class table's and a declaration's own, so pointer
/// identity keys it; the length and the dispatch generation guard an
/// address the allocator reused.
const ClassNameMemo = struct {
    ptr: usize = 0,
    len: usize = 0,
    gen: u32 = 0,
    is_class: bool = false,
    valid: bool = false,
};
const NameMemoTls = struct { cache: [512]ClassNameMemo = @splat(.{}) };
const name_memo_tls = runtime.tls_fast.PerThread(NameMemoTls);

fn namesAClass(self: *VmHost, name: []const u8) bool {
    const gen = host_call_member.dispatchCacheGen();
    const key = @intFromPtr(name.ptr);
    const cache = &name_memo_tls.get().cache;
    const slot = &cache[(key >> 3) % cache.len];
    if (slot.valid and slot.ptr == key and slot.len == name.len and slot.gen == gen)
        return slot.is_class;
    const d = classDefByName(self, name);
    const is_class = d != null;
    if (d) |dd| dd.deinit();
    slot.* = .{ .ptr = key, .len = name.len, .gen = gen, .is_class = is_class, .valid = true };
    return is_class;
}

/// Coarse bucket for a builtin type head; a cross-kind mismatch disqualifies a
/// candidate. `0` is not a recognised concrete builtin and matches anything.
pub fn builtinTypeKind(head: []const u8) u8 {
    if (headInSet(head, &integral_heads)) return 1;
    if (std.mem.eql(u8, head, "Float") or std.mem.eql(u8, head, "Double")) return 2;
    if (std.mem.eql(u8, head, "Boolean")) return 3;
    if (std.mem.eql(u8, head, "String")) return 5;
    if (headInSet(head, &collectionish_heads)) return 6;
    if (std.mem.eql(u8, head, "Map") or std.mem.eql(u8, head, "MutableMap") or
        std.mem.eql(u8, head, "HashMap") or std.mem.eql(u8, head, "LinkedHashMap")) return 7;
    return 0;
}

/// Type-fit of a candidate's declared param heads against the runtime args, on
/// the scale `chooseSecondaryCtor` ranks with: exact head +2, family match +1, a
/// callable meeting a FunctionN head +2, definite cross-family mismatch null.
pub fn scoreCtorHeads(self: *VmHost, heads: []const []const u8, args: []const Value) ?i32 {
    var score: i32 = 0;
    var i: usize = 0;
    const static_heads = common.ctor_static_heads;
    while (i < args.len and i < heads.len) : (i += 1) {
        const declared = boundHead(heads[i]);
        const got = valueTypeHead(args[i]);
        // The call site's declared head, the only evidence separating a subtype
        // argument from a supertype-typed one, which is what Kotlin selects on.
        if (static_heads) |sh| {
            if (i < sh.len) {
                if (sh[i]) |declared_arg| {
                    if (std.mem.eql(u8, declared, declared_arg)) {
                        score += 2;
                        continue;
                    }
                }
            }
        }
        if (std.mem.eql(u8, declared, got)) {
            score += 2;
            continue;
        }
        if (std.mem.startsWith(u8, declared, "Function") and isCallableArg(&args[i])) {
            score += 2;
            continue;
        }
        // A confirmed subtype ranks below an exact head but above a non-refutal.
        if (args[i] == .Instance and instanceOfClassName(&args[i], declared)) {
            score += 1;
            continue;
        }
        const decl_integral = headInSet(declared, &integral_heads);
        const decl_collish = headInSet(declared, &collectionish_heads);
        const got_integral = headInSet(got, &integral_heads);
        const got_collish = headInSet(got, &collectionish_heads);
        if (decl_collish and got_collish) {
            score += 1;
            continue;
        }
        if (decl_integral and got_integral) {
            score += 1;
            continue;
        }
        if ((decl_integral and got_collish) or (decl_collish and got_integral)) return null;
        if (!paramAcceptsArg(self, declared, &args[i])) return null;
    }
    return score;
}

pub fn isCallableArg(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure => true,
        else => false,
    };
}

/// A secondary ctor with defaulted extra parameters is a candidate only when no
/// primary takes the call; exact-arity callers keep `exact_arity`.
pub fn chooseSecondaryCtor(self: *VmHost, entries: []const root.build.SecondaryCtorEntry, args: []const Value) ?root.build.SecondaryCtorEntry {
    return chooseSecondaryCtorArity(self, entries, args, true);
}

pub fn chooseSecondaryCtorDefaulted(self: *VmHost, entries: []const root.build.SecondaryCtorEntry, args: []const Value) ?root.build.SecondaryCtorEntry {
    return chooseSecondaryCtorArity(self, entries, args, false);
}

pub fn chooseSecondaryCtorArity(self: *VmHost, entries: []const root.build.SecondaryCtorEntry, args: []const Value, exact_arity: bool) ?root.build.SecondaryCtorEntry {
    // Two passes: a `@Deprecated(level = HIDDEN)` constructor is no source-level
    // candidate, so it is reached only when the class has no other secondary.
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        const want_low = pass == 1;
        var best: ?root.build.SecondaryCtorEntry = null;
        var best_score: i32 = -1;
        for (entries) |e| {
            if (e.low_priority != want_low) continue;
            // A `vararg` takes any number of trailing arguments, none included,
            // once the fixed prefix is supplied; an exact-arity pick needs one.
            if (e.vararg_index) |v| {
                if (args.len < v) continue;
                if (exact_arity and args.len < e.param_count) continue;
                const score = scoreCtorHeadsVararg(self, e.param_type_heads, v, args) orelse continue;
                if (score > best_score) {
                    best_score = score;
                    best = e;
                }
                continue;
            }
            // All-defaulted trailing parameters take fewer arguments; an exact count outranks.
            if (e.param_count < args.len) continue;
            if (e.param_count > args.len) {
                if (exact_arity) continue;
                var all_defaulted = true;
                var di: usize = args.len;
                while (di < e.param_count) : (di += 1) {
                    if (di >= e.default_arg_thunks.len or e.default_arg_thunks[di] == null) {
                        all_defaulted = false;
                        break;
                    }
                }
                if (!all_defaulted) continue;
            }
            const heads = e.param_type_heads[0..@min(args.len, e.param_type_heads.len)];
            const score = (scoreCtorHeads(self, heads, args) orelse continue) +
                (if (e.param_count == args.len) @as(i32, 1000) else 0);
            if (score > best_score) {
                best_score = score;
                best = e;
            }
        }
        if (best != null) return best;
    }
    return null;
}

pub const DeferredCtorBody = struct { fqn: ?[]const u8, name: []const u8, body: FuncId, args: []Value };

/// `chooseSecondaryCtor` restricted to the constructors source can name.
pub fn chooseOrdinarySecondaryCtor(self: *VmHost, entries: []const root.build.SecondaryCtorEntry, args: []const Value) ?root.build.SecondaryCtorEntry {
    var ordinary: std.ArrayList(root.build.SecondaryCtorEntry) = .empty;
    defer ordinary.deinit(self.allocator);
    for (entries) |e| if (!e.low_priority) {
        ordinary.append(self.allocator, e) catch return null;
    };
    return chooseSecondaryCtorDefaulted(self, ordinary.items, args);
}

/// `scoreCtorHeads` where an integral value scores a full match against any
/// integral head: a literal's runtime tag is no distinction between them.
pub fn scoreCtorHeadsWidening(self: *VmHost, heads: []const []const u8, args: []const Value) ?i32 {
    // An exact head, an exact typealias target, and an integral pair all score
    // the full match; every other position falls back to the ordinary scorer.
    var score: i32 = 0;
    var i: usize = 0;
    while (i < args.len and i < heads.len) : (i += 1) {
        const got = valueTypeHead(args[i]);
        const declared = blk: {
            const head = boundHead(heads[i]);
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(head) orelse head;
        };
        if (std.mem.eql(u8, declared, got) or
            (headInSet(declared, &integral_heads) and headInSet(got, &integral_heads)))
        {
            score += 2;
            continue;
        }
        const one = scoreCtorHeads(self, heads[i .. i + 1], args[i .. i + 1]) orelse return null;
        score += one;
    }
    return score;
}

pub fn expandParentSecondaryThisArgs(
    self: *VmHost,
    allocator: Allocator,
    class_fqn: ?[]const u8,
    class_name: []const u8,
    args: *std.ArrayList(Value),
    arg_names: ?[]const ?[]const u8,
    bodies: *std.ArrayList(DeferredCtorBody),
    super_args: *?std.ArrayList(Value),
    /// The class's def where the caller already holds it. The walk climbs on
    /// its second turn and looks the next one up by name, but the first turn
    /// is the class the caller just resolved, and it ran on every
    /// construction with a parent.
    def_hint: ?ObjRef(ClassDef),
) Allocator.Error!UnitOrErr {
    var depth: usize = 0;
    var names = arg_names;
    // The loop climbs `this(...)` delegations WITHIN one class — it never
    // reassigns `class_name` or `class_fqn` — so resolving the def per turn
    // asked for the same class over and over. One resolution, and the
    // caller's handle serves even that when it has one.
    const def = if (def_hint) |h| h.clone() else (classDefByName(self, sideTableKey(class_fqn, class_name)) orelse return .{ .ok = {} });
    defer def.deinit();
    while (depth < 64) : (depth += 1) {
        const prev_bounds = installCtorBounds(def);
        defer common.ctor_bounds = prev_bounds;
        const primary_count = classDefPrimaryParamCount(def);
        const entries = secondaryCtors(self, class_fqn, class_name);
        // Named header arguments bind by name; an omitted parameter takes its
        // default, evaluated in parameter order with the values bound so far.
        var entry_opt: ?root.build.SecondaryCtorEntry = null;
        if (names) |nm| {
            var any_named = false;
            for (nm) |n| if (n != null) {
                any_named = true;
            };
            if (any_named) {
                for (entries) |e| {
                    const slots = try allocator.alloc(?Value, e.param_count);
                    defer allocator.free(slots);
                    @memset(slots, null);
                    var ok = true;
                    var pos: usize = 0;
                    for (args.items, 0..) |v, i| {
                        const n: ?[]const u8 = if (i < nm.len) nm[i] else null;
                        var slot: ?usize = null;
                        if (n) |want| {
                            for (e.param_names, 0..) |pn, pi| if (std.mem.eql(u8, pn, want)) {
                                slot = pi;
                                break;
                            };
                        } else {
                            while (pos < e.param_count and slots[pos] != null) pos += 1;
                            if (pos < e.param_count) slot = pos;
                        }
                        const si = slot orelse {
                            ok = false;
                            break;
                        };
                        slots[si] = v;
                    }
                    if (!ok) continue;
                    var ordered: std.ArrayList(Value) = .empty;
                    var pi: usize = 0;
                    while (pi < e.param_count) : (pi += 1) {
                        if (slots[pi]) |v| {
                            try ordered.append(allocator, v);
                            continue;
                        }
                        const dfid = (if (pi < e.default_arg_thunks.len) e.default_arg_thunks[pi] else null) orelse {
                            ok = false;
                            break;
                        };
                        const fr = try funcAt(self, dfid, "secondary ctor default");
                        switch (fr) {
                            .err => |err| return .{ .err = err },
                            .ok => |func| {
                                const thunk_args = try ctorThunkArgs(allocator, def, null, ordered.items, e.param_count);
                                defer allocator.free(thunk_args);
                                switch (try evalThunk(self, func, thunk_args)) {
                                    .ok => |v| try ordered.append(allocator, v),
                                    .err => |err| return .{ .err = err },
                                }
                            },
                        }
                    }
                    if (!ok) {
                        ordered.deinit(allocator);
                        continue;
                    }
                    args.deinit(allocator);
                    args.* = ordered;
                    entry_opt = e;
                    names = null;
                    break;
                }
            }
        }
        // A header call resolves only among the constructors source can name.
        const entry = entry_opt orelse chooseOrdinarySecondaryCtor(self, entries, args.items) orelse {
            return .{ .ok = {} };
        };
        if (args.items.len == primary_count and primary_count != 0) {
            // At the primary's count the primary keeps the call unless the secondary fits better.
            const dg = def.borrow();
            var primary_heads: std.ArrayList([]const u8) = .empty;
            defer primary_heads.deinit(allocator);
            for (dg.get().primary_params) |pp| try primary_heads.append(allocator, pp.declared_type orelse "");
            dg.deinit();
            const primary_score = scoreCtorHeadsWidening(self, primary_heads.items, args.items) orelse -1;
            const heads = entry.param_type_heads[0..@min(args.items.len, entry.param_type_heads.len)];
            const secondary_score = scoreCtorHeadsWidening(self, heads, args.items) orelse -1;
            if (secondary_score <= primary_score) {
                return .{ .ok = {} };
            }
        }
        if (try packSecondaryVarargs(self, allocator, entry, args.items)) |pk| {
            args.deinit(allocator);
            args.* = std.ArrayList(Value).fromOwnedSlice(pk);
        }
        var full_args: std.ArrayList(Value) = .empty;
        try full_args.appendSlice(allocator, args.items);
        {
            // The omitted trailing parameters take their defaults, in order.
            var idx = args.items.len;
            while (idx < entry.param_count) : (idx += 1) {
                const dfid = entry.default_arg_thunks[idx] orelse break;
                const fr = try funcAt(self, dfid, "secondary ctor default");
                switch (fr) {
                    .err => |e| return .{ .err = e },
                    .ok => |func| {
                        const thunk_args = try ctorThunkArgs(allocator, def, null, full_args.items, entry.param_count);
                        defer allocator.free(thunk_args);
                        switch (try evalThunk(self, func, thunk_args)) {
                            .ok => |v| try full_args.append(allocator, v),
                            .err => |e| return .{ .err = e },
                        }
                    },
                }
            }
        }
        for (full_args.items, 0..) |*arg, i| {
            if (i >= entry.param_type_heads.len) break;
            if (arg.* != .Int) continue;
            if (scalarRetag(entry.param_type_heads[i], arg.Int)) |rv| arg.* = rv;
        }
        if (entry.body) |body_fid| {
            // The body runs after initialization, so its argument copy is pinned
            // for the rest of the construction; it outlives every list freed here.
            const body_args = try allocator.dupe(Value, full_args.items);
            self.ka.pushSlice(body_args);
            try bodies.append(allocator, .{ .fqn = class_fqn, .name = class_name, .body = body_fid, .args = body_args });
        }
        var target: std.ArrayList(Value) = .empty;
        const full_with_recv = try ctorThunkArgs(allocator, def, null, full_args.items, 0);
        defer allocator.free(full_with_recv);
        for (entry.delegation_arg_thunks) |fid| {
            const fr = try funcAt(self, fid, "secondary ctor arg");
            switch (fr) {
                .err => |e| return .{ .err = e },
                .ok => |func| {
                    switch (try evalThunk(self, func, full_with_recv)) {
                        .ok => |v| try target.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        full_args.deinit(allocator);
        if (entry.is_super or !entry.is_this) {
            // `super(…)` names the parent's args; no delegation is an implicit `super()`.
            args.deinit(allocator);
            args.* = .empty;
            super_args.* = target;
            return .{ .ok = {} };
        }
        // The delegated arguments become this class's; the caller's chain pins
        // them once the loop settles, since a pin here would outlive its store.
        args.deinit(allocator);
        args.* = target;
    }
    return .{ .err = try typeErr(allocator, "secondary constructor delegation for `{s}` is recursive", .{class_name}) };
}

pub fn parentCtorArgThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().parent_ctor_args.get(sideTableKey(fqn, name));
}

/// Argument labels of the primary super-ctor delegation, parallel to
/// `parentCtorArgThunks`. `null` when the call was fully positional.
pub fn parentCtorArgNames(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const ?[]const u8 {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().parent_ctor_arg_names.get(sideTableKey(fqn, name));
}

/// Index of `param_name` in `pp`, binding a named super-ctor argument to its slot.
pub fn paramIndexByName(pp: []const runtime.ClassParamDef, param_name: []const u8) ?usize {
    for (pp, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, param_name)) return i;
    }
    return null;
}

/// The `this` slot for a primary-ctor default-arg thunk: an inner class's
/// defaults evaluate against the outer hint's instance; other classes get Null.
pub fn ctorThunkThisSlot(class_def: ObjRef(ClassDef), outer_hint: ?*const Value) Value {
    const oh = outer_hint orelse return .Null;
    const dg = class_def.borrow();
    defer dg.deinit();
    if (!dg.get().is_inner) return .Null;
    return oh.*;
}

/// Argument vector for a secondary-ctor delegation or default thunk; an inner
/// class's thunks lead with the enclosing instance. `pad_to` excludes that slot.
pub fn ctorThunkArgs(allocator: Allocator, class_def: ?ObjRef(ClassDef), outer_hint: ?*const Value, args: []const Value, pad_to: usize) Allocator.Error![]Value {
    const inner = blk: {
        const d = class_def orelse break :blk false;
        const dg = d.borrow();
        defer dg.deinit();
        break :blk dg.get().is_inner;
    };
    const lead: usize = if (inner) 1 else 0;
    const out = try allocator.alloc(Value, lead + @max(args.len, pad_to));
    if (inner) out[0] = if (outer_hint) |oh| oh.* else .Null;
    @memcpy(out[lead .. lead + args.len], args);
    for (out[lead + args.len ..]) |*slot| slot.* = .Null;
    return out;
}

pub fn primaryDefaultThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().primary_ctor_default_thunks.get(sideTableKey(fqn, name));
}

pub fn classDelegateThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) []const root.build.StrFunc {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().class_delegates.get(sideTableKey(fqn, name)) orelse &.{};
}

/// Serve a trivial property initializer (one constant or parameter echo) with no
/// framed eval; null means run the body. `all` is `[this, ctor args...]`.
pub fn trivialInitServe(allocator: Allocator, m: *const ir.Module, func: *const ir.Func, all: []const Value) Allocator.Error!?Value {
    if (func.triv_init_state == 0) {
        const mut = @constCast(func);
        mut.triv_init_state = 1;
        // An image func decodes its body lazily; classify the real blocks.
        if (func.blocks.len == 0) _ = m.ensureFuncBody(mut);
        if (func.blocks.len == 1) one: {
            const blk = &func.blocks[0];
            if (blk.h().catches.len != 0 or blk.h().finally != null) break :one;
            if (blk.terminator != .Return) break :one;
            const ret_reg = blk.terminator.Return orelse break :one;
            if (blk.insts.len > 24) break :one;
            // Trivial when every inst is a param load or a Const writing the
            // returned register; the last write to it decides the served value.
            var state: u8 = 0;
            var val: u32 = 0;
            for (blk.insts) |*inst| switch (inst.*) {
                .Trace => {},
                .Const => |c| {
                    if (c.dst.int() != ret_reg.int()) break :one;
                    state = 2;
                    val = c.value.int();
                },
                .LoadParam => |lp| {
                    if (lp.dst.int() == ret_reg.int()) {
                        state = 3;
                        val = lp.idx;
                    }
                },
                else => break :one,
            };
            if (state == 0) break :one;
            mut.triv_init_val = val;
            mut.triv_init_state = state;
        }
        if (runtime.envOnce("KLIO_TRIV_TRACE") != null) {
            std.debug.print("[triv] {s} state={d} val={d} blocks={d}", .{ func.name, func.triv_init_state, func.triv_init_val, func.blocks.len });
            if (func.blocks.len >= 1) {
                std.debug.print(" term={s} insts:", .{@tagName(std.meta.activeTag(func.blocks[0].terminator))});
                for (func.blocks[0].insts) |*bi| std.debug.print(" {s}", .{@tagName(std.meta.activeTag(bi.*))});
            }
            std.debug.print("\n", .{});
        }
    }
    switch (func.triv_init_state) {
        2 => {
            if (func.triv_init_val >= m.consts.items.len) return null;
            return try ir.eval.constToValue(allocator, &m.consts.items[func.triv_init_val]);
        },
        3 => {
            if (func.triv_init_val >= all.len) return null;
            const v = all[func.triv_init_val];
            v.retain();
            return v;
        },
        else => return null,
    }
}

pub fn bodyPropInit(self: *VmHost, class_fqn: ?[]const u8, class_name: []const u8, prop_name: []const u8) ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().body_prop_inits.get(.{ .a = sideTableKey(class_fqn, class_name), .b = prop_name });
}

pub fn appendPrimaryCtorPropertyFields(
    allocator: Allocator,
    fields: *std.ArrayList(InstanceData.Field),
    class_def: ObjRef(ClassDef),
    args: []const Value,
) Allocator.Error!void {
    const dg = class_def.borrow();
    defer dg.deinit();
    for (dg.get().primary_params, 0..) |param, i| {
        if (param.property == null or i >= args.len) continue;
        try fields.append(allocator, .{ .name = param.name, .value = adoptDeclaredNumeric(&param, args[i]) });
    }
}

/// kotlinc adopts an integer literal to the declared type at the call site, so
/// this retags `.Int` values, and `Array` elements, at the property boundary.
pub fn adoptDeclaredNumeric(param: *const runtime.ClassParamDef, v: Value) Value {
    const shape = if (param.declared_shape) |*sh| sh else return v;
    if (v == .Int) {
        if (scalarRetag(shape.name, v.Int)) |rv| return rv;
        return v;
    }
    if (std.mem.eql(u8, shape.name, "Array") and shape.args.len == 1 and v == .Array) {
        const elem = shape.args[0].name;
        if (!scalarRetagName(elem)) return v;
        switch (v.Array.storage()) {
            .boxed => |vl| {
                const g = vl.borrowMut();
                defer g.deinit();
                for (g.get().items) |*it| {
                    if (it.* == .Int) {
                        if (scalarRetag(elem, it.Int)) |rv| it.* = rv;
                    }
                }
            },
            .scalars => {},
        }
    }
    return v;
}

pub fn scalarRetagName(name: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, name, "Byte") or eq(u8, name, "Short") or eq(u8, name, "Long");
}

/// Simple head of a declared type name: no package, type arguments, or `?`.
pub fn typeHeadOfName(name: []const u8) []const u8 {
    var t = std.mem.trimEnd(u8, name, "?");
    if (std.mem.findScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.findScalarLast(u8, t, '.')) |d| t = t[d + 1 ..];
    return t;
}

pub fn scalarRetag(name: []const u8, iv: i64) ?Value {
    const eq = std.mem.eql;
    if (eq(u8, name, "Byte")) return .{ .Byte = @truncate(iv) };
    if (eq(u8, name, "Short")) return .{ .Short = @truncate(iv) };
    if (eq(u8, name, "Long")) return .{ .Long = iv };
    return null;
}

/// Instance-identity counter for host modules that mint instances directly.
pub fn mintInstanceId(self: *VmHost) u64 {
    return nextInstanceId(self);
}

pub fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

pub fn funcAt(self: *VmHost, fid: FuncId, comptime ctx: []const u8) Allocator.Error!union(enum) { ok: *const ir.Func, err: EvalError } {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const f = m.funcById(fid) orelse {
        return .{ .err = try typeErr(self.allocator, ctx ++ " FuncId {d} out of range", .{fid.int()}) };
    };
    // An image decodes bodies lazily and this func is about to be called, so
    // force the body: an undecoded one runs empty and returns Unit.
    if (f.blocks.len == 0) _ = m.ensureFuncBody(@constCast(f));
    return .{ .ok = f };
}

/// Storage key for `prop`: the owner-mangled registry key when it privately
/// shadows a supertype's same-name property, which Kotlin gives its own cell.
pub fn shadowFieldKey(self: *VmHost, cls: []const u8, prop: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ cls, prop }) catch return prop;
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.private_shadow_props.getKey(probe)) |k| return k;
    return mg.get().registry.override_cell_props.getKey(probe) orelse prop;
}

/// Whether `cls`'s `prop` privately shadows a supertype's stored property.
pub fn isPrivateShadowProp(self: *VmHost, cls: []const u8, prop: []const u8) bool {
    var buf: [256]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ cls, prop }) catch return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.private_shadow_props.getKey(probe) != null;
}

/// Evaluate `func` against `args`; the module handle is borrowed for the call.
pub fn evalThunk(self: *VmHost, func: *const ir.Func, args: []const Value) Allocator.Error!EvalResult {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    var args_list = try ir.eval.acquireArgsCap(self.allocator, args.len);
    errdefer ir.eval.releaseArgs(self.allocator, &args_list);
    if (args_list.capacity >= args.len) args_list.appendSliceAssumeCapacity(args) else try args_list.appendSlice(self.allocator, args);
    vmhost.emitPath(self.allocator, "ctor_thunk", func.fqn, func.id, null, args);
    // Ownership of `args_list` transfers into `evalWith`: the frame adopts
    // it as its `params` backing and frees it on `frame.deinit()`.
    return ir.eval.evalWith(VmHost, self.allocator, mg.get(), func, args_list, self);
}

/// Initialize a local class instance's module parent chain from the leaf's
/// `$super$arg$<i>` thunks, binding each ancestor's fields and init thunks.
pub fn initLocalParentChain(
    self: *VmHost,
    allocator: Allocator,
    inst: ObjRef(InstanceData),
    inst_value: Value,
    cls: ObjRef(ClassDef),
    cls_name: []const u8,
    leaf_args: []const Value,
) Allocator.Error!?ir.eval.EvalError {
    var cur_def: ?ObjRef(ClassDef) = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk if (g.get().parent) |p| p.clone() else null;
    };
    // A builtin throwable parent (`class MyException : Exception("...")`) has
    // no ClassDef; its constructor arguments still bind `message`/`cause`.
    const builtin_throwable_parent = blk: {
        if (cur_def != null) break :blk false;
        const g = cls.borrow();
        defer g.deinit();
        for (g.get().supertype_names) |sn| {
            const simple = if (std.mem.findScalarLast(u8, sn, '.')) |d| sn[d + 1 ..] else sn;
            if (isBuiltinThrowableName(simple)) break :blk true;
        }
        break :blk false;
    };
    if (runtime.envOnce("KLIO_INIT_DEBUG") != null) {
        const g = cls.borrow();
        defer g.deinit();
        std.debug.print("[init-debug] local parent chain {s}: parent={} builtin_throwable={} supers={d}\n", .{ cls_name, cur_def != null, builtin_throwable_parent, g.get().supertype_names.len });
    }
    if (cur_def == null and !builtin_throwable_parent) return null;
    var cur_args: std.ArrayList(Value) = .empty;
    defer cur_args.deinit(allocator);
    {
        var ai: usize = 0;
        while (true) : (ai += 1) {
            var kb: [48]u8 = undefined;
            const nm = std.fmt.bufPrint(&kb, "$super$arg${d}", .{ai}) catch break;
            const key = try std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ cls_name, nm });
            const present = blk: {
                const tbl = self.anon_methods.borrow();
                defer tbl.deinit();
                break :blk tbl.get().contains(key);
            };
            allocator.free(key);
            if (!present) break;
            switch (try host_call_member.callMember(self, allocator, &inst_value, nm, leaf_args)) {
                .ok => |v| try cur_args.append(allocator, v),
                .err => |e| return e,
            }
        }
    }
    if (runtime.envOnce("KLIO_INIT_DEBUG") != null) std.debug.print("[init-debug] local parent chain {s}: super args evaluated={d}\n", .{ cls_name, cur_args.items.len });
    if (builtin_throwable_parent) {
        try bindThrowableArgs(self, inst, cur_args.items, true);
        return null;
    }
    // The stdlib `Exception`/`Throwable` binds message and cause by name.
    if (cur_def) |pd| {
        const pg = pd.borrow();
        const pn = pg.get().name;
        pg.deinit();
        const simple = if (std.mem.findScalarLast(u8, pn, '.')) |d| pn[d + 1 ..] else pn;
        if (isBuiltinThrowableName(simple)) try bindThrowableArgs(self, inst, cur_args.items, true);
    }
    while (cur_def) |pd| {
        defer pd.deinit();
        const pg = pd.borrow();
        const p_name = pg.get().name;
        const p_fqn = pg.get().fqn;
        for (pg.get().primary_params, 0..) |*pp, i| {
            if (i >= cur_args.items.len) break;
            const g = inst.borrowMut();
            defer g.deinit();
            if (g.get().get(pp.name) == null) {
                if (runtime.reclaimEnabled()) cur_args.items[i].retain();
                try g.get().ensureFieldsOwned(allocator, 1);
                try g.get().fields.append(allocator, .{ .name = pp.name, .value = cur_args.items[i] });
                g.get().invalidateShape();
            }
        }
        for (pg.get().body_properties) |*bp| {
            if (bodyPropInit(self, p_fqn, p_name, bp.name)) |fid| {
                const fr = try funcAt(self, fid, "parent body prop init");
                switch (fr) {
                    .err => |e| {
                        pg.deinit();
                        return e;
                    },
                    .ok => |func| {
                        var all: std.ArrayList(Value) = .empty;
                        defer all.deinit(allocator);
                        try all.append(allocator, inst_value);
                        try all.appendSlice(allocator, cur_args.items);
                        const served = blk: {
                            const mg3 = self.module.borrow();
                            defer mg3.deinit();
                            break :blk try trivialInitServe(allocator, mg3.get(), func, all.items);
                        };
                        const r: ir.eval.EvalResult = if (served) |sv| .{ .ok = sv } else try evalThunk(self, func, all.items);
                        switch (r) {
                            .ok => |v| {
                                const g = inst.borrowMut();
                                defer g.deinit();
                                if (g.get().get(bp.name) == null) {
                                    try g.get().define(allocator, shadowFieldKey(self, p_name, bp.name), v);
                                }
                            },
                            .err => |e| {
                                pg.deinit();
                                return e;
                            },
                        }
                    },
                }
            } else if (bp.init == null and bp.getter == null and bp.delegate == null) {
                const g = inst.borrowMut();
                defer g.deinit();
                if (g.get().get(bp.name) == null) {
                    try g.get().ensureFieldsOwned(allocator, 1);
                    try g.get().fields.append(allocator, .{ .name = bp.name, .value = bp.primitive_zero orelse Value.Null });
                    g.get().invalidateShape();
                }
            }
        }
        var next_args: std.ArrayList(Value) = .empty;
        var have_next = false;
        if (parentCtorArgThunks(self, p_fqn, p_name)) |thunks| {
            have_next = true;
            for (thunks) |fid| {
                const fr = try funcAt(self, fid, "parent ctor arg");
                switch (fr) {
                    .err => |e| {
                        next_args.deinit(allocator);
                        pg.deinit();
                        return e;
                    },
                    .ok => |func| {
                        switch (try evalParentCtorThunk(self, func, cur_args.items, null)) {
                            .ok => |v| next_args.append(allocator, v) catch {},
                            .err => |e| {
                                next_args.deinit(allocator);
                                pg.deinit();
                                return e;
                            },
                        }
                    },
                }
            }
        }
        const next_def: ?ObjRef(ClassDef) = if (pg.get().parent) |np| np.clone() else null;
        pg.deinit();
        cur_args.deinit(allocator);
        cur_args = if (have_next) next_args else .empty;
        if (!have_next) next_args.deinit(allocator);
        cur_def = next_def;
    }
    return null;
}

pub fn evalParentCtorThunk(
    self: *VmHost,
    func: *const ir.Func,
    args: []const Value,
    outer_hint: ?*const Value,
) Allocator.Error!EvalResult {
    if (!func.has_receiver_param) return evalThunk(self, func, args);
    var all: std.ArrayList(Value) = .empty;
    defer all.deinit(self.allocator);
    try all.append(self.allocator, if (outer_hint) |outer| outer.* else .Null);
    try all.appendSlice(self.allocator, args);
    return evalThunk(self, func, all.items);
}
