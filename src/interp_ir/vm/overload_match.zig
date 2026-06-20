//! Declared-vs-runtime type matching for overload selection.
//!
//! The lowered `Param.ty` carries the full declared `TypeRef` (generic
//! arguments, function shapes, a `#suspend` marker, variance prefixes).
//! The head-name scorers in `host_call_func.zig` / `host_call_member.zig`
//! accept a candidate on the head alone; this module refines that verdict
//! with whatever type knowledge the runtime value actually carries:
//! container elements (or the declared element head an empty container was
//! created with), a closure body's declared parameter types, and a closure
//! body's suspend marking.
//!
//! The refinement is a score *delta* so head-level ordering is never
//! flipped: `null` disqualifies the candidate outright (kotlinc would not
//! consider it), a positive delta rewards a declared-type proof so it
//! outranks an unprovable sibling, zero means no knowledge either way, and
//! a small negative delta ranks a suspend-converted binding below an exact
//! one. Disproofs are definite-only — the same discipline as
//! `argDefinitelyNotParamType` — so an unknowable shape keeps today's
//! declaration-order tie instead of gaining a wrong rejection.

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

/// Reward for a declared generic argument / function shape the runtime
/// value proves. Small enough that it can never outrank a head-level
/// score difference (the scorers' tiers are >= 10 apart).
const PROOF_BONUS: i32 = 6;

/// Penalty for binding a not-provably-suspend callable to a `suspend`
/// function-typed parameter: the suspend conversion is legal for a
/// literal, but kotlinc ranks the conversion-free sibling above it.
const SUSPEND_CONVERSION_PENALTY: i32 = 2;

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

fn allUppercase(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// Strip a variance projection prefix and trailing nullability from a
/// lowered type-argument head.
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

/// `loweredTypeRef` appends `#non-null` / `#qual:` markers after the real
/// generic arguments; drop them so positional reasoning sees only types.
fn realArgs(args: []const TypeRef) []const TypeRef {
    var end = args.len;
    while (end > 0 and isMarker(args[end - 1].name)) end -= 1;
    return args[0..end];
}

// -------------------------------------------------------------------------
// Builtin value kinds (shared with the definite-disproof checks in
// host_call_member.zig).
// -------------------------------------------------------------------------

/// Coarse builtin value kinds for definite argument-type disproof.
/// Numeric widths collapse into one kind: klio's lowered literals may
/// carry a narrower tag than the declared parameter type.
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

/// `true` when the parameter's declared builtin kind and the argument's
/// runtime builtin kind are both known and differ — a definite
/// inapplicability kotlinc would never consider. An `Array` argument
/// against a non-array parameter stays non-definite: dispatch can carry a
/// pre-packed vararg array against the vararg's element type.
pub fn builtinKindMismatch(pn: []const u8, arg: *const Value) bool {
    const pk = builtinParamKind(pn) orelse return false;
    const vk = builtinValueKind(arg) orelse return false;
    if (vk == .array and pk != .array) return false;
    return pk != vk;
}

// -------------------------------------------------------------------------
// Tri-state value-vs-declared-type matching.
// -------------------------------------------------------------------------

const Match = enum { proven, disproven, unknown };

/// Is `pn` a plausible declared type parameter rather than a class? The
/// scorers have no candidate `FuncId` context here, so this mirrors the
/// short-all-uppercase convention used across dispatch, excluding names
/// registered as runtime classes.
fn looksLikeTypeParam(self: *VmHost, pn: []const u8) bool {
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

/// One runtime value against one declared type. Definite-only: `disproven`
/// requires positive evidence of incompatibility, everything uncertain is
/// `unknown`.
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
            .IrClosure, .Function, .Intrinsic, .BoundMethod, .BoundUserMethod => {
                const delta = functionShapeDelta(self, head, realArgs(ty.args), v) orelse return .disproven;
                return if (delta > 0) .proven else .unknown;
            },
            // A plain data value is definitely not a function; anything
            // else (an instance with a possible SAM/invoke surface) is
            // unknowable here.
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => return .disproven,
            else => return .unknown,
        }
    }

    const v_ty = runtimeHead(v);
    if (std.mem.eql(u8, head, v_ty) or builtinHeadAccepts(head, v_ty)) {
        const args = realArgs(ty.args);
        if (args.len == 0) return .proven;
        return switch (containerArgsMatch(self, head, args, v, fuel)) {
            .proven => .proven,
            .disproven => .disproven,
            // The head fits; only the generic arguments are unknowable.
            .unknown => .unknown,
        };
    }

    if (builtinKindMismatch(head, v)) return .disproven;

    if (v.* == .Instance) {
        if (instanceIsA(self, v, head)) return .proven;
        if (instanceDefinitelyNot(self, v, head)) return .disproven;
        return .unknown;
    }
    return .unknown;
}

fn runtimeHead(v: *const Value) []const u8 {
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

/// Does the declared head accept this runtime head through the builtin
/// supertype table (`List` value for an `Iterable` parameter, `String`
/// for `CharSequence`, …)?
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

/// Definite instance disproof: the declared head names a registered class,
/// the instance's own class is registered (so its supertype closure is
/// complete), and the walk never reaches the head.
fn instanceDefinitelyNot(self: *VmHost, v: *const Value, target: []const u8) bool {
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(target) == null) return false;
        if (cg.get().get(runtimeHead(v)) == null) return false;
    }
    return !instanceIsA(self, v, target);
}

// -------------------------------------------------------------------------
// Container generic-argument refinement.
// -------------------------------------------------------------------------

/// Element-walk cap for the scorer: enough to type any literal container
/// a call site disambiguates with, without rescanning a large collection
/// once per overload candidate. Elements past the cap leave the verdict
/// at whatever the sampled prefix established (never a disproof).
const SCORER_ELEM_CAP: usize = 16;

/// Match a container value's content knowledge against the declared
/// generic arguments. Element values decide where present; an empty
/// container falls back to the declared element head it was created with
/// (explicit call-site type arguments on the stdlib creators), and is
/// `unknown` when it carries none.
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
        .Set => |s| if (isSetFamily(head)) s.items else null,
        .Array => |arr| if (std.mem.eql(u8, head, "Array")) arr.boxedList() else null,
        else => null,
    };
    if (ty_args.len < 1) return .unknown;
    const declared_elem: ?[]const u8 = switch (v.*) {
        .List => |l| l.declared_elem,
        .Set => |s| s.declared_elem,
        else => null,
    };
    if (v.* == .List) {
        const l = v.List;
        if (!isListFamily(head)) return .unknown;
        const g = l.buf.borrow();
        defer g.deinit();
        const items = g.get().boxed.items;
        if (items.len == 0) return declaredHeadMatch(self, &ty_args[0], declared_elem);
        var acc: Match = .proven;
        for (items, 0..) |*e, i| {
            if (i >= SCORER_ELEM_CAP) break;
            acc = combine(acc, valueMatches(self, &ty_args[0], e, fuel + 1));
            if (acc == .disproven) return .disproven;
        }
        return acc;
    }
    const list = elems orelse return .unknown;
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

/// Does an empty container's recorded element head *prove* the declared
/// generic argument? Used by the strict receiver prover, which needs a
/// positive proof (everything else falls to its lenient pass).
pub fn declaredElemProves(self: *VmHost, want: *const TypeRef, have_head: ?[]const u8) bool {
    return declaredHeadMatch(self, want, have_head) == .proven;
}

/// Declared-vs-declared head comparison for an empty container that
/// carries the element head it was created with. Head-level only: the
/// creation-site type argument is recorded as the written head name, so
/// nested generic arguments on the candidate side stay unknowable.
fn declaredHeadMatch(self: *VmHost, want: *const TypeRef, have_head: ?[]const u8) Match {
    const have = simpleName(have_head orelse return .unknown);
    const want_head = bareHead(want.name);
    if (want_head.len == 0 or std.mem.eql(u8, want_head, "*")) return .proven;
    if (std.mem.eql(u8, want_head, "Any")) return .proven;
    if (looksLikeTypeParam(self, want_head)) return .unknown;
    if (std.mem.eql(u8, want_head, have)) {
        // Nested arguments on the wanted side are not recorded on the
        // value; an exact head match alone cannot prove them.
        return if (realArgs(want.args).len == 0) .proven else .unknown;
    }
    // Both heads known and recognisably different value kinds: definite.
    const wk = builtinParamKind(want_head);
    const hk = builtinParamKind(have);
    if (wk != null and hk != null and wk != hk) return .disproven;
    if (wk != null and hk != null and wk == hk) return .unknown;
    return .unknown;
}

// -------------------------------------------------------------------------
// Function-shape refinement.
// -------------------------------------------------------------------------

/// The slice of a closure's lowered body `Func` the matcher consults.
/// `params` borrows the module's func table, which outlives every call.
const ClosureBody = struct { is_suspend: bool, params: []const ir.Param };

/// Resolve a closure's lowered body `Func`. The side-table records the
/// sub-module the body was lowered into; null means the main program
/// module.
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

/// Declared-vs-declared comparison of one lambda parameter annotation
/// against one declared function-type parameter. Definite only when both
/// heads name recognised builtin value types.
fn lambdaParamMatch(self: *VmHost, declared: *const TypeRef, annotated: *const TypeRef) Match {
    const want = bareHead(declared.name);
    const have = bareHead(annotated.name);
    if (have.len == 0 or std.mem.eql(u8, have, "Unit")) return .unknown;
    if (want.len == 0 or std.mem.eql(u8, want, "Unit")) return .unknown;
    if (std.mem.eql(u8, want, "Any")) return .proven;
    if (looksLikeTypeParam(self, want) or looksLikeTypeParam(self, have)) return .unknown;
    if (std.mem.eql(u8, want, have)) return .proven;
    // Both sides are concrete builtin value types with different names:
    // function-type parameters are invariant, so the annotated lambda can
    // never bind (an `(Int) -> Int` never accepts `{ s: String -> … }`).
    _ = builtinParamKind(want) orelse return .unknown;
    _ = builtinParamKind(have) orelse return .unknown;
    return .disproven;
}

/// Refine a head/arity-accepted callable argument against a declared
/// `FunctionN` parameter: the `#suspend` marker and, for an `IrClosure`
/// whose lambda literal carried parameter type annotations, the parameter
/// types. `null` disqualifies; positive proves; zero is unknowable.
pub fn functionShapeDelta(self: *VmHost, head: []const u8, ty_args: []const TypeRef, arg: *const Value) ?i32 {
    const declared_suspend = ty_args.len > 0 and std.mem.eql(u8, ty_args[0].name, "#suspend");
    const shape = ty_args[@intFromBool(declared_suspend)..];

    const body = switch (arg.*) {
        .IrClosure => |c| closureBodyFunc(self, c.id),
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

    // Positional parameter types, when the declared shape is the plain
    // (no extension receiver) form and the closure declares the same
    // count. `Function{d}` counts value parameters only; the lowered args
    // are `params… , return` (receiver form has one extra slot and stays
    // unknowable here).
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

// -------------------------------------------------------------------------
// Entry point for the scorers.
// -------------------------------------------------------------------------

/// Refine a head-accepted arg/param pair using the declared `TypeRef`'s
/// generic arguments. Callers add the result to the head-level base
/// score; `null` disqualifies the candidate.
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
