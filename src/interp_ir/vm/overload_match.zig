//! Declared-vs-runtime type matching for overload selection. The head-name scorers
//! in `host_call_func.zig` / `host_call_member.zig` accept a candidate on its head
//! alone; this refines that with what the runtime value knows: container elements,
//! an empty container's declared element head, a closure's annotations and suspend
//! marking. The verdict is a score delta that never flips head-level ordering: `null`
//! disqualifies, positive rewards a proof, zero means no knowledge, a small negative
//! ranks a suspend conversion below an exact binding; disproofs are definite-only.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;

const Value = runtime.Value;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;

/// Reward for a shape the runtime value proves, below the head-level tiers that sit >=
/// 10 apart.
const PROOF_BONUS: i32 = 6;

/// Ranks a not-provably-suspend callable below its conversion-free sibling, as kotlinc
/// does.
const SUSPEND_CONVERSION_PENALTY: i32 = 2;

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allUppercase(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

fn bareHead(name: []const u8) []const u8 {
    var h = name;
    if (std.mem.startsWith(u8, h, "in#")) h = h["in#".len..];
    if (std.mem.startsWith(u8, h, "out#")) h = h["out#".len..];
    h = simpleName(h);
    return std.mem.trimEnd(u8, h, "?");
}

fn isMarker(name: []const u8) bool {
    return std.mem.eql(u8, name, "#suspend") or
        std.mem.eql(u8, name, "#non-null") or
        std.mem.startsWith(u8, name, "#qual:");
}

/// `loweredTypeRef` appends `#non-null`/`#qual:` markers after the real generic
/// arguments; drop them.
fn realArgs(args: []const TypeRef) []const TypeRef {
    var end = args.len;
    while (end > 0 and isMarker(args[end - 1].name)) end -= 1;
    return args[0..end];
}

/// Coarse builtin kinds for definite disproof. Numeric widths collapse into one:
/// a lowered literal may carry a narrower tag than the declared parameter type.
pub const BuiltinKind = enum { numeric, string, boolean, char, array };

pub fn builtinParamKind(pn: []const u8) ?BuiltinKind {
    const eq = std.mem.eql;
    if (eq(u8, pn, "Int") or eq(u8, pn, "Long") or eq(u8, pn, "Short") or eq(u8, pn, "Byte") or
        eq(u8, pn, "UInt") or eq(u8, pn, "ULong") or eq(u8, pn, "UShort") or eq(u8, pn, "UByte") or
        eq(u8, pn, "Double") or eq(u8, pn, "Float") or eq(u8, pn, "Number")) return .numeric;
    if (eq(u8, pn, "String")) return .string;
    if (eq(u8, pn, "Boolean")) return .boolean;
    if (eq(u8, pn, "Char")) return .char;
    if (eq(u8, pn, "Array") or eq(u8, pn, "IntArray") or eq(u8, pn, "LongArray") or
        eq(u8, pn, "ShortArray") or eq(u8, pn, "ByteArray") or eq(u8, pn, "CharArray") or
        eq(u8, pn, "BooleanArray") or eq(u8, pn, "FloatArray") or eq(u8, pn, "DoubleArray") or
        eq(u8, pn, "UIntArray") or eq(u8, pn, "ULongArray") or eq(u8, pn, "UShortArray") or
        eq(u8, pn, "UByteArray")) return .array;
    return null;
}

pub fn builtinValueKind(v: *const Value) ?BuiltinKind {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .UInt, .ULong, .UShort, .UByte, .Double, .Float => .numeric,
        .String => .string,
        .Bool => .boolean,
        .Char => .char,
        .Array => .array,
        else => null,
    };
}

/// Both kinds known and different. An `Array` argument against a non-array parameter
/// stays non-definite: dispatch can carry a pre-packed vararg array element-wise.
pub fn builtinKindMismatch(pn: []const u8, arg: *const Value) bool {
    const pk = builtinParamKind(pn) orelse return false;
    const vk = builtinValueKind(arg) orelse return false;
    if (vk == .array and pk != .array) return false;
    return pk != vk;
}

const Match = enum { proven, disproven, unknown };

/// Is `pn` a type parameter rather than a class? Short-all-uppercase convention, minus
/// registered class names.
fn looksLikeTypeParam(self: *VmHost, pn: []const u8) bool {
    if (ir.parseClassTypeParamIdentity(pn) != null) return true;
    if (!(pn.len > 0 and pn.len <= 2 and allUppercase(pn))) return false;
    const cg = self.classes.borrow();
    defer cg.deinit();
    return cg.get().get(pn) == null;
}

fn isListFamily(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable") or
        std.mem.eql(u8, pn, "Sequence");
}

fn isSetFamily(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "Set") or std.mem.eql(u8, pn, "MutableSet") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable");
}

fn isMapFamily(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "Map") or std.mem.eql(u8, pn, "MutableMap");
}

pub fn valueDefinitelyNot(self: *VmHost, ty: *const TypeRef, v: *const Value) bool {
    return valueMatches(self, ty, v, 0) == .disproven;
}

pub fn isContainerOrRangeHead(pn: []const u8) bool {
    if (isListFamily(pn) or isSetFamily(pn) or isMapFamily(pn)) return true;
    for ([_][]const u8{
        "IntRange",        "LongRange",        "CharRange",       "UIntRange",
        "ULongRange",      "IntProgression",   "LongProgression", "CharProgression",
        "UIntProgression", "ULongProgression", "ClosedRange",     "OpenEndRange",
    }) |fam| {
        if (std.mem.eql(u8, pn, fam)) return true;
    }
    return false;
}

/// One runtime value against one declared type; `disproven` needs positive evidence,
/// everything uncertain is `unknown`.
fn valueMatches(self: *VmHost, ty: *const TypeRef, v: *const Value, fuel: u8) Match {
    if (fuel > 6) return .unknown;
    const head = bareHead(ty.name);
    if (head.len == 0 or std.mem.eql(u8, head, "*")) return .proven;
    if (std.mem.eql(u8, head, "Any")) return .proven;
    if (std.mem.eql(u8, head, "Unit")) return .unknown;
    if (looksLikeTypeParam(self, head)) return .unknown;

    if (v.* == .Null) {
        return if (ty.nullable) .proven else .disproven;
    }

    if (std.mem.startsWith(u8, head, "Function")) {
        switch (v.*) {
            .IrClosure, .Intrinsic, .BoundMethod => {
                const delta = functionShapeDelta(self, head, realArgs(ty.args), v) orelse return .disproven;
                return if (delta > 0) .proven else .unknown;
            },
            // A data value is never a function; an instance may expose invoke.
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => return .disproven,
            else => return .unknown,
        }
    }

    // `..` (step 1) is an XRange/ClosedRange/XProgression/Iterable; downTo or step
    // != 1 is only an XProgression/Iterable, so `x downTo y` picks Iterable.
    if (v.* == .Range) {
        const r = v.Range;
        const prog: []const u8 = switch (r.kind) {
            .Int => "IntProgression",
            .Long => "LongProgression",
            .Char => "CharProgression",
            .UInt => "UIntProgression",
            .ULong => "ULongProgression",
        };
        const rng: []const u8 = switch (r.kind) {
            .Int => "IntRange",
            .Long => "LongRange",
            .Char => "CharRange",
            .UInt => "UIntRange",
            .ULong => "ULongRange",
        };
        if (std.mem.eql(u8, head, "Iterable") or std.mem.eql(u8, head, prog)) return .proven;
        if (r.step == 1 and (std.mem.eql(u8, head, rng) or
            std.mem.eql(u8, head, "ClosedRange") or std.mem.eql(u8, head, "OpenEndRange"))) return .proven;
        for ([_][]const u8{
            "IntRange",        "LongRange",        "CharRange",       "UIntRange",
            "ULongRange",      "IntProgression",   "LongProgression", "CharProgression",
            "UIntProgression", "ULongProgression", "ClosedRange",     "OpenEndRange",
        }) |fam| {
            if (std.mem.eql(u8, head, fam)) return .disproven;
        }
        // A range satisfies Iterable but is never a List/Set/Map/Collection.
        if (isListFamily(head) or isSetFamily(head) or isMapFamily(head)) return .disproven;
        return .unknown;
    }

    const v_ty = runtimeHead(v);
    if (std.mem.eql(u8, head, v_ty) or builtinHeadAccepts(head, v_ty)) {
        const args = realArgs(ty.args);
        if (args.len == 0) return .proven;
        return switch (containerArgsMatch(self, head, args, v, fuel)) {
            .proven => .proven,
            .disproven => .disproven,
            .unknown => .unknown,
        };
    }

    if (builtinKindMismatch(head, v)) return .disproven;

    if (v.* == .Instance) {
        if (instanceIsA(self, v, head)) return .proven;
        if (instanceDefinitelyNot(self, v, head)) return .disproven;
        return .unknown;
    }

    // A callable against a registered class that is not a `fun interface` can never
    // bind: no SAM conversion applies, so the member `collect(FlowCollector)` stands
    // aside for the extension `collect(action)`. An unregistered head stays unknown.
    switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod => {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(head)) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                if (!dg.get().is_fun_interface) return .disproven;
            }
            return .unknown;
        },
        else => {},
    }
    return .unknown;
}

pub fn runtimeHead(v: *const Value) []const u8 {
    return switch (v.*) {
        .Instance => |i| blk: {
            const g = i.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        },
        else => simpleName(v.typeFqn()),
    };
}

/// Dotted path of a qualified parameter type (`x: a.Box` lowers a `#qual:a.Box` marker
/// arg), else null.
fn qualifiedMarker(ty: *const TypeRef) ?[]const u8 {
    for (ty.args) |*a| {
        if (std.mem.startsWith(u8, a.name, "#qual:")) return a.name["#qual:".len..];
    }
    return null;
}

/// Whether a qualified `param_ty` and the value denote different registered classes
/// sharing a simple name, so the exact-name tier drops the wrong-package candidate.
/// Definite-only: both sides must resolve to registered FQNs.
pub fn crossPackageIdentityConflict(self: *VmHost, param_ty: *const TypeRef, v: *const Value) bool {
    if (v.* != .Instance) return false;
    const target_path = qualifiedMarker(param_ty) orelse return false;
    const arg_fqn = blk: {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        // `fqn` is an immutable arena slice; it outlives the borrow lock.
        break :blk cg.get().fqn;
    };
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const target_cid = m.classIdByFqn(target_path) orelse return false;
    if (target_cid.int() >= m.classes.items.len) return false;
    const arg_cid = m.classIdByFqn(arg_fqn) orelse return false;
    if (arg_cid.int() >= m.classes.items.len) return false;
    return !std.mem.eql(u8, m.classes.items[target_cid.int()].fqn, m.classes.items[arg_cid.int()].fqn);
}

/// Builtin supertype table: a `List` value satisfies an `Iterable` parameter.
fn builtinHeadAccepts(head: []const u8, v_ty: []const u8) bool {
    const supers: []const []const u8 = blk: {
        const eq = std.mem.eql;
        if (eq(u8, v_ty, "List")) break :blk &.{ "Collection", "Iterable", "MutableList", "MutableCollection", "MutableIterable" };
        if (eq(u8, v_ty, "MutableList")) break :blk &.{ "List", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
        if (eq(u8, v_ty, "Set")) break :blk &.{ "Collection", "Iterable", "MutableSet", "MutableCollection", "MutableIterable" };
        if (eq(u8, v_ty, "MutableSet")) break :blk &.{ "Set", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
        if (eq(u8, v_ty, "Map")) break :blk &.{"MutableMap"};
        if (eq(u8, v_ty, "MutableMap")) break :blk &.{"Map"};
        if (eq(u8, v_ty, "String")) break :blk &.{ "CharSequence", "Comparable" };
        break :blk &.{};
    };
    for (supers) |s| {
        if (std.mem.eql(u8, s, head)) return true;
    }
    return false;
}

fn instanceIsA(self: *VmHost, v: *const Value, target: []const u8) bool {
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, runtimeHead(v)) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch return false;
        if (std.mem.eql(u8, simpleName(cur), target)) return true;
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(cur)) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch return false;
        }
    }
    return false;
}

/// Definite only when both classes are registered, so the supertype closure is complete.
fn instanceDefinitelyNot(self: *VmHost, v: *const Value, target: []const u8) bool {
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(target) == null) return false;
        if (cg.get().get(runtimeHead(v)) == null) return false;
    }
    return !instanceIsA(self, v, target);
}

/// Elements walked per candidate; those past the cap leave the sampled prefix's
/// verdict, never a disproof.
const SCORER_ELEM_CAP: usize = 16;

/// Elements decide where present; an empty container falls back to its declared element
/// head.
fn containerArgsMatch(self: *VmHost, head: []const u8, ty_args: []const TypeRef, v: *const Value, fuel: u8) Match {
    if (isMapFamily(head)) {
        if (v.* != .Map or ty_args.len < 2) return .unknown;
        const declared_k: ?[]const u8 = v.Map.declared_key;
        const declared_v: ?[]const u8 = v.Map.declared_value;
        const g = v.Map.entries.borrow();
        defer g.deinit();
        const entries = g.get().pairs.items;
        if (entries.len == 0) {
            const km = declaredHeadMatch(self, &ty_args[0], declared_k);
            const vm = declaredHeadMatch(self, &ty_args[1], declared_v);
            return combine(km, vm);
        }
        var acc: Match = .proven;
        for (entries, 0..) |*e, i| {
            if (i >= SCORER_ELEM_CAP) break;
            acc = combine(acc, valueMatches(self, &ty_args[0], &e.key, fuel + 1));
            acc = combine(acc, valueMatches(self, &ty_args[1], &e.value, fuel + 1));
            if (acc == .disproven) return .disproven;
        }
        return acc;
    }
    const elems: ?runtime.ValueList = switch (v.*) {
        .List => |l| if (isListFamily(head)) l.items else null,
        .Set => |s| if (isSetFamily(head)) s.items else null,
        .Array => |arr| if (std.mem.eql(u8, head, "Array")) arr.boxedList() else null,
        else => null,
    };
    const list = elems orelse return .unknown;
    if (ty_args.len < 1) return .unknown;
    const declared_elem: ?[]const u8 = switch (v.*) {
        .List => |l| l.declared_elem,
        .Set => |s| s.declared_elem,
        else => null,
    };
    const g = list.borrow();
    defer g.deinit();
    const items = g.get().items;
    if (items.len == 0) return declaredHeadMatch(self, &ty_args[0], declared_elem);
    var acc: Match = .proven;
    for (items, 0..) |*e, i| {
        if (i >= SCORER_ELEM_CAP) break;
        acc = combine(acc, valueMatches(self, &ty_args[0], e, fuel + 1));
        if (acc == .disproven) return .disproven;
    }
    return acc;
}

fn combine(a: Match, b: Match) Match {
    if (a == .disproven or b == .disproven) return .disproven;
    if (a == .unknown or b == .unknown) return .unknown;
    return .proven;
}

pub fn declaredElemProves(self: *VmHost, want: *const TypeRef, have_head: ?[]const u8) bool {
    return declaredHeadMatch(self, want, have_head) == .proven;
}

/// Declared-vs-declared for an empty container; head-level only, so nested arguments
/// stay unknowable.
fn declaredHeadMatch(self: *VmHost, want: *const TypeRef, have_head: ?[]const u8) Match {
    const have_full = simpleName(have_head orelse return .unknown);
    // A recorded FULL generic spelling (`List<Int>`) compares by head.
    const have = if (std.mem.findScalar(u8, have_full, '<')) |lt| have_full[0..lt] else have_full;
    const want_head = bareHead(want.name);
    if (want_head.len == 0 or std.mem.eql(u8, want_head, "*")) return .proven;
    if (std.mem.eql(u8, want_head, "Any")) return .proven;
    if (looksLikeTypeParam(self, want_head)) return .unknown;
    if (std.mem.eql(u8, want_head, have)) {
        // Nested arguments on the wanted side are not recorded on the value.
        return if (realArgs(want.args).len == 0) .proven else .unknown;
    }
    const wk = builtinParamKind(want_head);
    const hk = builtinParamKind(have);
    if (wk != null and hk != null and wk != hk) return .disproven;
    if (wk != null and hk != null and wk == hk) return .unknown;
    return .unknown;
}

/// `params` borrows the module's func table, which outlives every call.
const ClosureBody = struct { is_suspend: bool, params: []const ir.Param };

/// A null `info.module` means the body was lowered into the main program module.
fn closureBodyFunc(self: *VmHost, id: u64) ?ClosureBody {
    const info = self.closures.get(@intCast(id)) orelse return null;
    if (info.module) |m| {
        const f = m.funcById(info.body_func) orelse return null;
        return .{ .is_suspend = f.is_suspend, .params = f.params };
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    const f = mg.get().funcById(info.body_func) orelse return null;
    return .{ .is_suspend = f.is_suspend, .params = f.params };
}

/// Definite only when both heads name recognised builtin value types.
fn lambdaParamMatch(self: *VmHost, declared: *const TypeRef, annotated: *const TypeRef) Match {
    const want = bareHead(declared.name);
    const have = bareHead(annotated.name);
    if (have.len == 0 or std.mem.eql(u8, have, "Unit")) return .unknown;
    if (want.len == 0 or std.mem.eql(u8, want, "Unit")) return .unknown;
    if (std.mem.eql(u8, want, "Any")) return .proven;
    if (looksLikeTypeParam(self, want) or looksLikeTypeParam(self, have)) return .unknown;
    if (std.mem.eql(u8, want, have)) return .proven;
    // Function-type parameters are invariant: `(Int) -> Int` never accepts `{ s: String
    // -> … }`.
    _ = builtinParamKind(want) orelse return .unknown;
    _ = builtinParamKind(have) orelse return .unknown;
    return .disproven;
}

/// Refine a head/arity-accepted callable against a declared `FunctionN` parameter by
/// the `#suspend` marker and any lambda annotations. `null` disqualifies, a positive
/// delta proves, zero is unknowable.
pub fn functionShapeDelta(self: *VmHost, head: []const u8, ty_args: []const TypeRef, arg: *const Value) ?i32 {
    const declared_suspend = ty_args.len > 0 and std.mem.eql(u8, ty_args[0].name, "#suspend");
    const shape = ty_args[@intFromBool(declared_suspend)..];

    const body = switch (arg.*) {
        .IrClosure => |c| closureBodyFunc(self, c.asPtr().id),
        else => null,
    };

    var delta: i32 = 0;
    if (body) |b| {
        if (b.is_suspend and !declared_suspend) {
            // A suspend lambda is never a plain function value.
            return null;
        }
        if (b.is_suspend and declared_suspend) delta += PROOF_BONUS;
    }
    if (!declaredSuspendProven(body, declared_suspend)) delta -= SUSPEND_CONVERSION_PENALTY;

    // Positional parameter types, only for the plain (no extension receiver) shape
    // at matching arity: `Function{d}` counts value parameters and the lowered args
    // are `params…, return`, so the receiver form's extra slot stays unknowable.
    const want_n = std.fmt.parseInt(usize, head["Function".len..], 10) catch return delta;
    if (shape.len != want_n + 1) return delta;
    const b = body orelse return delta;
    if (b.params.len != want_n) return delta;
    var all_proven = want_n > 0;
    for (shape[0..want_n], b.params) |*declared, *p| {
        switch (lambdaParamMatch(self, declared, &p.ty)) {
            .disproven => return null,
            .proven => {},
            .unknown => all_proven = false,
        }
    }
    if (all_proven) delta += PROOF_BONUS;
    return delta;
}

fn declaredSuspendProven(body: ?ClosureBody, declared_suspend: bool) bool {
    if (!declared_suspend) return true;
    const b = body orelse return false;
    return b.is_suspend;
}

/// Refine a head-accepted arg/param pair; callers add the result to the head-level base
/// score.
pub fn refineByDeclaredArgs(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) ?i32 {
    const head = bareHead(param_ty.name);
    if (std.mem.startsWith(u8, head, "Function")) {
        return functionShapeDelta(self, head, realArgs(param_ty.args), arg);
    }
    const args = realArgs(param_ty.args);
    if (args.len == 0) return 0;
    return switch (containerArgsMatch(self, head, args, arg, 0)) {
        .proven => PROOF_BONUS,
        .disproven => null,
        .unknown => 0,
    };
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}
