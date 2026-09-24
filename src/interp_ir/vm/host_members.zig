//! The members the VM implements over host values, which the bridge binds
//! once by the declaration they implement (`bridge.Options.host_fns`): a
//! bodyless member of a host-backed class (`ArrayList.add`), or the root of
//! a slot a host value answers when its class has no implementation of it
//! (`Iterator.hasNext` on a list's iterator). Each entry is found by
//! `resolved.hostKey` of that declaration. A call through one reaches the
//! implementation directly: the stdlib native the member is, over a view
//! of the host that takes no references, or the VM's own code for the
//! value kind.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_member = @import("host_call_member.zig");
const host_fields = @import("host_fields.zig");
const builtin_members = @import("builtin_members.zig");
const stdlib_tail = @import("host_call_member/stdlib_tail.zig");
const class_access = @import("host_fields/class_access.zig");
const host_resolved = @import("host_resolved.zig");
const persistent_list_mut = @import("persistent_list_mut.zig");
const persistent_map_mut = @import("persistent_map_mut.zig");
const persistent_list_eq = @import("persistent_list_eq.zig");
const persistent_map_eq = @import("persistent_map_eq.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const StdlibFn = runtime.StdlibFn;
const EvalResult = ir.eval.EvalResult;
const HostFn = ir.resolved.HostFn;
const HostTry = ir.resolved.HostTry;
const VmHost = vmhost.VmHost;
const coll = stdlib.implementations.collections;
const impl = stdlib.implementations;

const boolVal = host_call_member.boolVal;
const throwExc = host_call_member.throwExc;

/// The member the VM implements under `key` (`resolved.hostKey`), or null.
pub fn resolve(key: []const u8) ?HostFn {
    return table.get(key);
}

/// The fast path the VM puts in front of the declaration `key` names, or
/// null.
pub fn resolveTry(key: []const u8) ?HostTry {
    return tries.get(key);
}

fn vm(h: *anyopaque) *VmHost {
    return @ptrCast(@alignCast(h));
}

fn internal(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalResult {
    return .{ .err = .{ .Unsupported = try std.fmt.allocPrint(a, fmt, args) } };
}

fn tagOf(v: *const Value) []const u8 {
    return @tagName(std.meta.activeTag(v.*));
}

/// The stdlib native `f` (`fqn` names it for traces) as a member.
fn native(comptime fqn: []const u8, comptime f: StdlibFn) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            return host_call_func.callStdlibBorrowed(vm(h), a, fqn, f, args);
        }
    }.call;
}

// ------------------------------------------------------------- iterators --

/// `Iterator.hasNext` on a host iterator: a collection's, a range's or a
/// sequence's.
fn iterHasNext(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    return iterOp(h, a, args, "hasNext");
}

/// `Iterator.next`, and the primitive iterators' `nextInt` and kin.
fn iterNext(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    return iterOp(h, a, args, "next");
}

fn iterMember(comptime name: []const u8) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            return iterOp(h, a, args, name);
        }
    }.call;
}

fn iterOp(h: *anyopaque, a: Allocator, args: []const Value, comptime name: []const u8) Allocator.Error!EvalResult {
    const recv = &args[0];
    const rest = args[1..];
    const r = switch (recv.*) {
        .Iterator => try builtin_members.iteratorMember(a, recv, name, rest),
        .RangeIter => try builtin_members.rangeIterMember(a, recv, name, rest),
        .SeqIter => try builtin_members.seqIterMember(vm(h), a, recv, name, rest),
        else => null,
    };
    return r orelse internal(a, "`Iterator.{s}` on a {s} value", .{ name, tagOf(recv) });
}

/// `Iterable.iterator` of a host collection, array, string or sequence;
/// an iterator is its own.
fn iterableIterator(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const recv = &args[0];
    switch (recv.*) {
        .Iterator, .RangeIter, .SeqIter => {
            recv.retain();
            return .{ .ok = recv.* };
        },
        .Sequence => return (try builtin_members.sequenceMember(vm(h), a, recv, "iterator", &.{})) orelse
            internal(a, "`Sequence.iterator` declined", .{}),
        else => {},
    }
    return (try builtin_members.builtinIterator(a, recv)) orelse internal(a, "`iterator` on a {s} value", .{tagOf(recv)});
}

/// `List.listIterator(index)`: an iterator over the list's own backing, so
/// a `MutableListIterator`'s `set`, `add` and `remove` change the list.
fn listIterator(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const recv = &args[0];
    if (recv.* != .List) return internal(a, "`listIterator` on a {s} value", .{tagOf(recv)});
    const l = recv.List;
    const size: i64 = blk: {
        const g = l.items.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().items.len);
    };
    const idx: i64 = if (args.len > 1) (args[1].asI64() orelse 0) else 0;
    if (idx < 0 or idx > size) {
        const msg = try std.fmt.allocPrint(a, "index: {d}, size: {d}", .{ idx, size });
        return .{ .err = try throwExc(a, "kotlin.IndexOutOfBoundsException", msg) };
    }
    if (coll.sublistViewStale(recv)) return .{ .err = try throwExc(a, "kotlin.ConcurrentModificationException", null) };
    const cap = try builtin_members.captureModCount(a, l.mod_count.get());
    return .{ .ok = try Value.newIterator(a, .{
        .items = l.items.clone(),
        .prim = null,
        .mod_count = .from(cap.mod_count),
        .mutable = l.mutable and l.backing == null and !coll.modCountFrozen(l.mod_count),
        .pos = @intCast(idx),
        .exp_mod = cap.exp_mod,
    }) };
}

// ---------------------------------------------------------------- arrays --

fn arrayOf(a: Allocator, args: []const Value, comptime what: []const u8) Allocator.Error!union(enum) { arr: runtime.ArrayData, err: EvalResult } {
    return switch (args[0]) {
        .Array => |arr| .{ .arr = arr },
        else => .{ .err = try internal(a, "`" ++ what ++ "` on a {s} value", .{tagOf(&args[0])}) },
    };
}

fn arrayIndexError(a: Allocator, index: i64, len: usize) Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(a, "Index {d} out of bounds for length {d}", .{ index, len });
    return .{ .err = try throwExc(a, "java.lang.ArrayIndexOutOfBoundsException", msg) };
}

fn arraySize(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const arr = switch (try arrayOf(a, args, "size")) {
        .arr => |x| x,
        .err => |e| return e,
    };
    return .{ .ok = Value.newInt(@intCast(arr.len())) };
}

fn arrayGet(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const arr = switch (try arrayOf(a, args, "get")) {
        .arr => |x| x,
        .err => |e| return e,
    };
    if (args.len < 2 or args[1] != .Int) return internal(a, "`Array.get` without an Int index", .{});
    if (ir.exec_call.fastIndexGet(&args[0], &args[1])) |v| return .{ .ok = v };
    return arrayIndexError(a, args[1].Int, arr.len());
}

fn arraySet(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const arr = switch (try arrayOf(a, args, "set")) {
        .arr => |x| x,
        .err => |e| return e,
    };
    if (args.len < 3 or args[1] != .Int) return internal(a, "`Array.set` without an Int index and a value", .{});
    if (ir.exec_call.fastIndexSet(a, &args[0], &args[1], args[2]) == null) return arrayIndexError(a, args[1].Int, arr.len());
    return .{ .ok = .Unit };
}

/// `CharArray.concatToString`, over the whole array or `startIndex` to
/// `endIndex`.
fn concatToString(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    if (args[0] != .Array) return internal(a, "`concatToString` on a {s} value", .{tagOf(&args[0])});
    return (try builtin_members.arrayShapeOps(vm(h), a, &args[0], "concatToString", args[1..])) orelse
        internal(a, "`concatToString` with {d} arguments", .{args.len - 1});
}

// ---------------------------------------------------------------- ranges --

/// A progression's `first`, `last` or `step`: the stored bounds, which an
/// empty progression has too.
fn rangeProperty(comptime name: []const u8) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            _ = h;
            const v = host_fields.hostFreeProperty(&args[0], name) orelse
                return internal(a, "`" ++ name ++ "` on a {s} value", .{tagOf(&args[0])});
            return .{ .ok = v };
        }
    }.call;
}

// ------------------------------------------------------- pairs, entries --

/// A member of a pair, a triple or a map entry that `componentMembers`
/// answers: its components, an entry's equality and `setValue`.
fn component(comptime name: []const u8) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            return (try builtin_members.componentMembers(vm(h), a, &args[0], name, args[1..])) orelse
                internal(a, "`" ++ name ++ "` on a {s} value", .{tagOf(&args[0])});
        }
    }.call;
}

fn pairCopy(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const n: usize = switch (args[0]) {
        .Pair => 2,
        .Triple => 3,
        else => return internal(a, "`copy` on a {s} value", .{tagOf(&args[0])}),
    };
    if (args.len < n + 1) return internal(a, "`copy` without every component", .{});
    if (runtime.reclaimEnabled()) for (args[1 .. n + 1]) |v| v.retain();
    if (n == 2) return .{ .ok = try Value.newPair(a, .{ .first = try Value.boxRef(a, args[1]), .second = try Value.boxRef(a, args[2]) }) };
    return .{ .ok = try Value.newTriple(a, .{ .first = try Value.boxRef(a, args[1]), .second = try Value.boxRef(a, args[2]), .third = try Value.boxRef(a, args[3]) }) };
}

// ------------------------------------------------------------------ Any --

/// Whether `v` has an equality of its own that `BoxedEq` answers: the
/// collections, class values, ranges and the other host kinds.
fn boxedEquality(v: *const Value) bool {
    return switch (v.*) {
        .Instance, .Null, .IrClosure, .MapEntry => false,
        else => true,
    };
}

/// `Any.equals`: an instance is equal only to itself; a map entry by its
/// key and value; a function value by what it references; any other host
/// value by its kind's own equality.
fn anyEquals(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const self = vm(h);
    if (args.len < 2) return internal(a, "`equals` without an argument", .{});
    const recv = &args[0];
    const other = &args[1];
    switch (recv.*) {
        .Instance => |inst| return .{ .ok = boolVal(other.* == .Instance and runtime.ObjRef(runtime.InstanceData).ptrEq(inst, other.Instance)) },
        .MapEntry => return component("equals")(h, a, args),
        .IrClosure => return .{ .ok = boolVal(try builtin_members.deepValueEquals(self, a, recv, other)) },
        else => {},
    }
    if (!boxedEquality(recv)) return .{ .ok = boolVal(false) };
    // A sub-list whose list changed shape fails, as any access to it does.
    if (recv.sublistViewStale()) return .{ .err = try throwExc(a, "kotlin.ConcurrentModificationException", null) };
    const Op = @FieldType(ir.Inst, "BinOp");
    const zero = ir.Reg.from(0);
    const bo: Op = .{ .dst = zero, .op = .BoxedEq, .lhs = zero, .rhs = zero };
    return ir.eval.binopValue(VmHost, a, recv.*, other.*, Op, bo, self);
}

/// `Any.hashCode`: an instance's identity; a host value's hash by its kind,
/// its elements' through their own `hashCode`.
fn anyHashCode(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const recv = &args[0];
    switch (recv.*) {
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            return .{ .ok = Value.newInt(@bitCast(g.get().identity)) };
        },
        // A live entry whose map changed shape fails, as any access to it does.
        .MapEntry => return component("hashCode")(h, a, args),
        else => {},
    }
    if (recv.sublistViewStale()) return .{ .err = try throwExc(a, "kotlin.ConcurrentModificationException", null) };
    return .{ .ok = .{ .Int = try builtin_members.hashWithDispatch(vm(h), a, recv) } };
}

/// `Any.toString`: an instance is its class's name and identity; a host
/// value renders as its kind does.
fn anyToString(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const self = vm(h);
    const recv = &args[0];
    const f: ?struct { []const u8, StdlibFn } = switch (recv.*) {
        .Instance => |inst| return .{ .ok = try stdlib_tail.inheritedInstanceToString(a, inst, false) },
        .Class => |c| {
            const g = c.borrow();
            defer g.deinit();
            const label = try std.fmt.allocPrint(a, "class {s}", .{g.get().fqn});
            return .{ .ok = .{ .String = try runtime.strInitOwned(a, label) } };
        },
        .List => .{ "kotlin.collections.List.toString", coll.coll_list_to_string },
        .Set => .{ "kotlin.collections.Set.toString", coll.coll_set_to_string },
        .Map => .{ "kotlin.collections.Map.toString", coll.coll_map_to_string },
        .Pair => .{ "kotlin.Pair.toString", coll.pair_to_string },
        .Triple => .{ "kotlin.Triple.toString", coll.triple_to_string },
        .MapEntry => .{ "kotlin.collections.Map.Entry.toString", impl.sequence.map_entry_to_string },
        .Sequence => .{ "kotlin.sequences.Sequence.toString", impl.sequence.seq_to_string },
        .Range => .{ "kotlin.ranges.IntProgression.toString", impl.ranges.range_to_string },
        .StringBuilder => .{ "kotlin.text.StringBuilder.toString", impl.stringbuilder.string_builder_to_string },
        .Regex => .{ "kotlin.text.Regex.toString", impl.regexp.regex_to_string },
        .Match => .{ "kotlin.text.MatchResult.toString", impl.regexp.match_result_to_string },
        else => null,
    };
    if (f) |nf| return host_call_func.callStdlibBorrowed(self, a, nf[0], nf[1], args[0..1]);
    return .{ .ok = .{ .String = try runtime.strInitOwned(a, try recv.display(a)) } };
}

// ------------------------------------------------------------ primitives --

/// `equals` of a number, a character or a boolean: equal to a value of its
/// own type and value only.
fn primEquals(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    if (args.len < 2) return internal(a, "`equals` without an argument", .{});
    const Op = @FieldType(ir.Inst, "BinOp");
    const zero = ir.Reg.from(0);
    const bo: Op = .{ .dst = zero, .op = .BoxedEq, .lhs = zero, .rhs = zero };
    return ir.eval.binopValue(VmHost, a, args[0], args[1], Op, bo, vm(h));
}

fn primHashCode(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    _ = a;
    return .{ .ok = .{ .Int = builtin_members.kotlinHashCode(&args[0]) } };
}

/// An arithmetic member (`Int.plus`) called as a function: the operation
/// the operator lowers to, over the operands as they are.
fn arith(comptime op: ir.BinOp) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            if (args.len < 2) return internal(a, "`" ++ @tagName(op) ++ "` without an operand", .{});
            if (ir.eval.resolved_ops.integralDivByZero(op, args[0], args[1])) {
                return .{ .err = try throwExc(a, "kotlin.ArithmeticException", "/ by zero") };
            }
            const Op = @FieldType(ir.Inst, "BinOp");
            const zero = ir.Reg.from(0);
            const bo: Op = .{ .dst = zero, .op = op, .lhs = zero, .rhs = zero };
            return ir.eval.binopValue(VmHost, a, args[0], args[1], Op, bo, vm(h));
        }
    }.call;
}

/// `toChar` of a number: its value truncated to a UTF-16 unit, through
/// `Int` for a floating-point one.
fn toChar(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const code: i64 = switch (args[0]) {
        .Char => |c| c,
        .Int => |x| x,
        .Long => |x| x,
        .Short => |x| x,
        .Byte => |x| x,
        .Float => |x| floatToInt(x),
        .Double => |x| floatToInt(x),
        else => return internal(a, "`toChar` on a {s} value", .{tagOf(&args[0])}),
    };
    return .{ .ok = .{ .Char = @truncate(@as(u64, @bitCast(code))) } };
}

/// Kotlin's `toInt` of a floating-point value: NaN is 0, and the rest
/// saturates at `Int`'s bounds.
fn floatToInt(x: anytype) i64 {
    const f: f64 = @floatCast(x);
    if (std.math.isNan(f)) return 0;
    if (f >= @as(f64, std.math.maxInt(i32))) return std.math.maxInt(i32);
    if (f <= @as(f64, std.math.minInt(i32))) return std.math.minInt(i32);
    return @intFromFloat(f);
}

fn boolNot(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    if (args[0] != .Bool) return internal(a, "`not` on a {s} value", .{tagOf(&args[0])});
    return .{ .ok = boolVal(!args[0].Bool) };
}

fn boolOp(comptime which: enum { @"and", @"or", xor }) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            _ = h;
            if (args.len < 2 or args[0] != .Bool or args[1] != .Bool) return internal(a, "`" ++ @tagName(which) ++ "` without two Booleans", .{});
            const x = args[0].Bool;
            const y = args[1].Bool;
            return .{ .ok = boolVal(switch (which) {
                .@"and" => x and y,
                .@"or" => x or y,
                .xor => x != y,
            }) };
        }
    }.call;
}

// --------------------------------------------------------------- matches --

/// `MatchResult.groups` of a host match: a `KlioMatchGroups` over it.
fn matchGroups(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const self = vm(h);
    const module = self.module.asPtrConst();
    const r = module.resolved orelse return internal(a, "`MatchResult.groups` without the class tables", .{});
    const cc = r.base.match_groups orelse return internal(a, "the base declares no KlioMatchGroups", .{});
    return host_resolved.construct(self, a, module, cc, args[0]);
}

fn matchOf(a: Allocator, v: *const Value) Allocator.Error!union(enum) { match: *const runtime.MatchData, err: EvalResult } {
    return switch (v.*) {
        .Match => |m| .{ .match = m.asPtr() },
        else => .{ .err = try internal(a, "a match group read on a {s} value", .{tagOf(v)}) },
    };
}

/// How many groups a host match has, the whole match included.
fn matchGroupCount(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const md = switch (try matchOf(a, &args[0])) {
        .match => |m| m,
        .err => |e| return e,
    };
    return .{ .ok = Value.newInt(@intCast(md.groups.len)) };
}

/// A host match's group by index or by name (`regexp.matchGroupOf`).
fn matchGroup(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    const md = switch (try matchOf(a, &args[0])) {
        .match => |m| m,
        .err => |e| return e,
    };
    return switch (try impl.regexp.matchGroupOf(a, md, args[1])) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = switch (e) {
            .Thrown => |x| .{ .Throw = x },
            .Type => |m| .{ .Type = m },
            else => .{ .Unsupported = "a match group read failed" },
        } },
    };
}

// ----------------------------------------------------------- class values --

/// A `KClass` property the class tables answer (`simpleName`,
/// `qualifiedName`).
fn classProperty(comptime name: []const u8) HostFn {
    return struct {
        fn call(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
            return (try class_access.classReflective(vm(h), a, &args[0], name)) orelse
                internal(a, "`KClass." ++ name ++ "` on a {s} value", .{tagOf(&args[0])});
        }
    }.call;
}

/// `KClass.isInstance`: whether the value's class is the class or one of
/// its subclasses, from the class tables.
fn classIsInstance(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const module = vm(h).module.asPtrConst();
    if (args.len < 2) return internal(a, "`isInstance` without an argument", .{});
    const r = module.resolved orelse return internal(a, "`isInstance` without the class tables", .{});
    const cls = ir.resolved.classOfKClass(&args[0]) orelse return internal(a, "`isInstance` on a {s} value", .{tagOf(&args[0])});
    if (args[1] == .Null) return .{ .ok = boolVal(false) };
    const vc = ir.resolved.classOf(r, &args[1]) orelse return .{ .ok = boolVal(false) };
    return .{ .ok = boolVal(ir.resolved.isA(module, vc, cls)) };
}

// ------------------------------------------------------------ comparators --

fn comparatorCompare(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    return (try builtin_members.comparatorMember(vm(h), a, &args[0], "compare", args[1..])) orelse
        internal(a, "`Comparator.compare` on a {s} value", .{tagOf(&args[0])});
}

// --------------------------------------------------------------- threads --

fn threadId(v: *const Value) ?u64 {
    if (v.* != .BoundMethod) return null;
    const bm = v.BoundMethod;
    if (!std.mem.eql(u8, bm.fqn, "java.lang.Thread")) return null;
    return switch (bm.receiver.asPtr().*) {
        .Long => |x| @bitCast(x),
        else => 0,
    };
}

fn threadJoin(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const id = threadId(&args[0]) orelse return internal(a, "`Thread.join` on a {s} value", .{tagOf(&args[0])});
    return switch (vmhost.host_impl.joinSpawned(vm(h), id)) {
        .ok => .{ .ok = .Unit },
        .err => |e| .{ .err = try host_call_member.mapRuntimeError(a, e) },
    };
}

fn threadIsAlive(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const id = threadId(&args[0]) orelse return internal(a, "`Thread.isAlive` on a {s} value", .{tagOf(&args[0])});
    return .{ .ok = boolVal(vmhost.host_impl.threadAlive(vm(h), id)) };
}

fn threadName(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    const id = threadId(&args[0]) orelse return internal(a, "`Thread.name` on a {s} value", .{tagOf(&args[0])});
    // A `thread { }` handle reports the name it was started with.
    if (vmhost.host_impl.threadNameOf(vm(h), id)) |n| return .{ .ok = .{ .String = try runtime.strInit(a, n) } };
    // The current thread and a dispatcher pool worker report their registered names.
    if (runtime.threadName(a, id)) |overridden| return .{ .ok = .{ .String = try runtime.strInitOwned(a, overridden) } };
    const s = try std.fmt.allocPrint(a, "klio-thread-{d}", .{id});
    return .{ .ok = .{ .String = try runtime.strInitOwned(a, s) } };
}

/// `Thread.start` and `interrupt`: a handle's thread runs from its spawn.
fn threadNoOp(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!EvalResult {
    _ = h;
    _ = threadId(&args[0]) orelse return internal(a, "a `Thread` member on a {s} value", .{tagOf(&args[0])});
    return .{ .ok = .Unit };
}

// ----------------------------------------------------------------- table --

const Entry = struct { []const u8, HostFn };

/// The collection classes' members: each is the stdlib native of the
/// interface member it overrides.
const list_members = [_]Entry{
    .{ "get kotlin.collections.ArrayList.size", native("kotlin.collections.MutableList.size", coll.coll_list_size) },
    .{ "kotlin.collections.ArrayList.isEmpty", native("kotlin.collections.MutableList.isEmpty", coll.coll_list_is_empty) },
    .{ "kotlin.collections.ArrayList.contains", native("kotlin.collections.MutableList.contains", coll.coll_list_contains) },
    .{ "kotlin.collections.ArrayList.containsAll", native("kotlin.collections.MutableList.containsAll", coll.coll_list_contains_all) },
    .{ "kotlin.collections.ArrayList.get", native("kotlin.collections.MutableList.get", coll.coll_list_get) },
    .{ "kotlin.collections.ArrayList.indexOf", native("kotlin.collections.MutableList.indexOf", coll.coll_list_index_of) },
    .{ "kotlin.collections.ArrayList.lastIndexOf", native("kotlin.collections.MutableList.lastIndexOf", coll.coll_list_last_index_of) },
    .{ "kotlin.collections.ArrayList.iterator", iterableIterator },
    .{ "kotlin.collections.ArrayList.listIterator", listIterator },
    .{ "kotlin.collections.ArrayList.add", native("kotlin.collections.MutableList.add", coll.coll_mut_list_add) },
    .{ "kotlin.collections.ArrayList.remove", native("kotlin.collections.MutableList.remove", coll.coll_mut_list_remove) },
    .{ "kotlin.collections.ArrayList.addAll", native("kotlin.collections.MutableList.addAll", coll.coll_mut_list_add_all) },
    .{ "kotlin.collections.ArrayList.removeAll", native("kotlin.collections.MutableList.removeAll", coll.coll_mut_list_remove_all) },
    .{ "kotlin.collections.ArrayList.retainAll", native("kotlin.collections.MutableList.retainAll", coll.coll_mut_list_retain_all) },
    .{ "kotlin.collections.ArrayList.clear", native("kotlin.collections.MutableList.clear", coll.coll_mut_list_clear) },
    .{ "kotlin.collections.ArrayList.set", native("kotlin.collections.MutableList.set", coll.coll_mut_list_set) },
    .{ "kotlin.collections.ArrayList.removeAt", native("kotlin.collections.MutableList.removeAt", coll.coll_mut_list_remove_at) },
    .{ "kotlin.collections.ArrayList.subList", native("kotlin.collections.MutableList.subList", coll.coll_list_sublist) },
};

fn setMembers(comptime cls: []const u8) [11]Entry {
    const p = "kotlin.collections." ++ cls ++ ".";
    return .{
        .{ "get " ++ p ++ "size", native("kotlin.collections.MutableSet.size", coll.coll_set_size) },
        .{ p ++ "isEmpty", native("kotlin.collections.MutableSet.isEmpty", coll.coll_set_is_empty) },
        .{ p ++ "contains", native("kotlin.collections.MutableSet.contains", coll.coll_set_contains) },
        .{ p ++ "containsAll", native("kotlin.collections.MutableSet.containsAll", coll.coll_set_contains_all) },
        .{ p ++ "iterator", iterableIterator },
        .{ p ++ "add", native("kotlin.collections.MutableSet.add", coll.coll_mut_set_add) },
        .{ p ++ "remove", native("kotlin.collections.MutableSet.remove", coll.coll_mut_set_remove) },
        .{ p ++ "addAll", native("kotlin.collections.MutableSet.addAll", coll.coll_mut_set_add_all) },
        .{ p ++ "removeAll", native("kotlin.collections.MutableSet.removeAll", coll.coll_mut_set_remove_all) },
        .{ p ++ "retainAll", native("kotlin.collections.MutableSet.retainAll", coll.coll_mut_set_retain_all) },
        .{ p ++ "clear", native("kotlin.collections.MutableSet.clear", coll.coll_mut_set_clear) },
    };
}

fn mapMembers(comptime cls: []const u8) [12]Entry {
    const p = "kotlin.collections." ++ cls ++ ".";
    return .{
        .{ "get " ++ p ++ "size", native("kotlin.collections.MutableMap.size", coll.coll_map_size) },
        .{ p ++ "isEmpty", native("kotlin.collections.MutableMap.isEmpty", coll.coll_map_is_empty) },
        .{ p ++ "containsKey", native("kotlin.collections.MutableMap.containsKey", coll.coll_map_contains_key) },
        .{ p ++ "containsValue", native("kotlin.collections.MutableMap.containsValue", coll.coll_map_contains_value) },
        .{ p ++ "get", native("kotlin.collections.MutableMap.get", coll.coll_map_get) },
        .{ p ++ "put", native("kotlin.collections.MutableMap.put", coll.coll_mut_map_put) },
        .{ p ++ "remove", native("kotlin.collections.MutableMap.remove", coll.coll_mut_map_remove) },
        .{ p ++ "putAll", native("kotlin.collections.MutableMap.putAll", coll.coll_mut_map_put_all) },
        .{ p ++ "clear", native("kotlin.collections.MutableMap.clear", coll.coll_mut_map_clear) },
        .{ "get " ++ p ++ "keys", native("kotlin.collections.MutableMap.keys", coll.coll_map_keys) },
        .{ "get " ++ p ++ "values", native("kotlin.collections.MutableMap.values", coll.coll_map_values) },
        .{ "get " ++ p ++ "entries", native("kotlin.collections.MutableMap.entries", coll.coll_map_entries) },
    };
}

/// The roots of the slots host iterators answer.
const iterator_members = [_]Entry{
    .{ "kotlin.collections.Iterator.hasNext", iterHasNext },
    .{ "kotlin.collections.Iterator.next", iterNext },
    .{ "kotlin.collections.MutableIterator.remove", iterMember("remove") },
    .{ "kotlin.collections.ListIterator.hasPrevious", iterMember("hasPrevious") },
    .{ "kotlin.collections.ListIterator.previous", iterMember("previous") },
    .{ "kotlin.collections.ListIterator.nextIndex", iterMember("nextIndex") },
    .{ "kotlin.collections.ListIterator.previousIndex", iterMember("previousIndex") },
    .{ "kotlin.collections.MutableListIterator.set", iterMember("set") },
    .{ "kotlin.collections.MutableListIterator.add", iterMember("add") },
    .{ "kotlin.collections.ByteIterator.nextByte", iterNext },
    .{ "kotlin.collections.CharIterator.nextChar", iterNext },
    .{ "kotlin.collections.ShortIterator.nextShort", iterNext },
    .{ "kotlin.collections.IntIterator.nextInt", iterNext },
    .{ "kotlin.collections.LongIterator.nextLong", iterNext },
    .{ "kotlin.collections.FloatIterator.nextFloat", iterNext },
    .{ "kotlin.collections.DoubleIterator.nextDouble", iterNext },
    .{ "kotlin.collections.BooleanIterator.nextBoolean", iterNext },
    .{ "kotlin.sequences.Sequence.iterator", iterableIterator },
    // A sequence builder's scope: the host's, which carries the pending
    // yield between pulls.
    .{ "kotlin.sequences.SequenceScope.yield", native("kotlin.sequences.SequenceScope.yield", impl.sequence.seq_scope_yield) },
    .{ "kotlin.sequences.SequenceScope.yieldAll", native("kotlin.sequences.SequenceScope.yieldAll", impl.sequence.seq_scope_yield_all) },
};

fn arrayMembers(comptime cls: []const u8) [4]Entry {
    const p = "kotlin." ++ cls ++ ".";
    return .{
        .{ "get " ++ p ++ "size", arraySize },
        .{ p ++ "get", arrayGet },
        .{ p ++ "set", arraySet },
        .{ p ++ "iterator", iterableIterator },
    };
}

fn progressionMembers(comptime cls: []const u8) [3]Entry {
    const p = "kotlin.ranges." ++ cls ++ ".";
    return .{
        .{ "get " ++ p ++ "first", rangeProperty("first") },
        .{ "get " ++ p ++ "last", rangeProperty("last") },
        .{ "get " ++ p ++ "step", rangeProperty("step") },
    };
}

fn numberMembers(comptime cls: []const u8, comptime rem: bool) [if (rem) 8 else 7]Entry {
    const p = "kotlin." ++ cls ++ ".";
    const common = [_]Entry{
        .{ p ++ "equals", primEquals },
        .{ p ++ "hashCode", primHashCode },
        .{ p ++ "plus", arith(.Add) },
        .{ p ++ "minus", arith(.Sub) },
        .{ p ++ "times", arith(.Mul) },
        .{ p ++ "div", arith(.Div) },
        .{ p ++ "toChar", toChar },
    };
    return if (rem) common ++ [_]Entry{.{ p ++ "rem", arith(.Mod) }} else common;
}

const other_members = [_]Entry{
    .{ "kotlin.Any.equals", anyEquals },
    .{ "kotlin.Any.hashCode", anyHashCode },
    .{ "kotlin.Any.toString", anyToString },
    .{ "kotlin.Number.toChar", toChar },
    .{ "kotlin.Char.equals", primEquals },
    .{ "kotlin.Char.hashCode", primHashCode },
    .{ "kotlin.Char.plus", arith(.Add) },
    .{ "kotlin.Char.minus", arith(.Sub) },
    .{ "kotlin.Char.toChar", toChar },
    .{ "kotlin.Boolean.equals", primEquals },
    .{ "kotlin.Boolean.hashCode", primHashCode },
    .{ "kotlin.Boolean.not", boolNot },
    .{ "kotlin.Boolean.and", boolOp(.@"and") },
    .{ "kotlin.Boolean.or", boolOp(.@"or") },
    .{ "kotlin.Boolean.xor", boolOp(.xor) },
    .{ "get kotlin.Pair.first", component("first") },
    .{ "get kotlin.Pair.second", component("second") },
    .{ "kotlin.Pair.component1", component("component1") },
    .{ "kotlin.Pair.component2", component("component2") },
    .{ "kotlin.Pair.equals", anyEquals },
    .{ "kotlin.Pair.hashCode", anyHashCode },
    .{ "kotlin.Pair.copy", pairCopy },
    .{ "get kotlin.Triple.first", component("first") },
    .{ "get kotlin.Triple.second", component("second") },
    .{ "get kotlin.Triple.third", component("third") },
    .{ "kotlin.Triple.component1", component("component1") },
    .{ "kotlin.Triple.component2", component("component2") },
    .{ "kotlin.Triple.component3", component("component3") },
    .{ "kotlin.Triple.equals", anyEquals },
    .{ "kotlin.Triple.hashCode", anyHashCode },
    .{ "kotlin.Triple.copy", pairCopy },
    .{ "get kotlin.collections.Map.Entry.key", component("key") },
    .{ "get kotlin.collections.Map.Entry.value", component("value") },
    .{ "kotlin.collections.MutableMap.MutableEntry.setValue", component("setValue") },
    .{ "get kotlin.reflect.KClass.simpleName", classProperty("simpleName") },
    .{ "get kotlin.reflect.KClass.qualifiedName", classProperty("qualifiedName") },
    .{ "kotlin.reflect.KClass.isInstance", classIsInstance },
    .{ "kotlin.Comparator.compare", comparatorCompare },
    .{ "get kotlin.text.MatchResult.value", native("kotlin.text.MatchResult.value", impl.regexp.match_result_value) },
    .{ "get kotlin.text.MatchResult.range", native("kotlin.text.MatchResult.range", impl.regexp.match_result_range) },
    .{ "get kotlin.text.MatchResult.groupValues", native("kotlin.text.MatchResult.groupValues", impl.regexp.match_result_group_values) },
    .{ "get kotlin.text.MatchResult.groups", matchGroups },
    .{ "kotlin.text.__klioMatchGroupCount", matchGroupCount },
    .{ "kotlin.text.__klioMatchGroup", matchGroup },
    .{ "kotlin.text.__klioMatchNamedGroup", matchGroup },
    .{ "get kotlin.text.MatchResult.destructured", native("kotlin.text.MatchResult.destructured", impl.regexp.match_result_destructured) },
    .{ "kotlin.text.MatchResult.next", native("kotlin.text.MatchResult.next", impl.regexp.match_result_next) },
    .{ "get kotlin.text.MatchGroup.value", native("kotlin.text.MatchGroup.value", impl.regexp.match_group_value) },
    .{ "get kotlin.text.MatchGroup.range", native("kotlin.text.MatchGroup.range", impl.regexp.match_group_range) },
    .{ "kotlin.text.concatToString", concatToString },
    .{ "kotlin.collections.toTypedArray", native("kotlin.collections.Collection.toTypedArray", coll.coll_to_typed_array) },
    .{ "get java.lang.Thread.name", threadName },
    .{ "get java.lang.Thread.isAlive", threadIsAlive },
    .{ "java.lang.Thread.join", threadJoin },
    .{ "java.lang.Thread.start", threadNoOp },
    .{ "java.lang.Thread.interrupt", threadNoOp },
};

const entries = list_members ++ setMembers("HashSet") ++ setMembers("LinkedHashSet") ++
    mapMembers("HashMap") ++ mapMembers("LinkedHashMap") ++ iterator_members ++
    arrayMembers("Array") ++ arrayMembers("BooleanArray") ++ arrayMembers("ByteArray") ++
    arrayMembers("CharArray") ++ arrayMembers("ShortArray") ++ arrayMembers("IntArray") ++
    arrayMembers("LongArray") ++ arrayMembers("FloatArray") ++ arrayMembers("DoubleArray") ++
    progressionMembers("IntProgression") ++ progressionMembers("LongProgression") ++
    progressionMembers("CharProgression") ++ progressionMembers("UIntProgression") ++
    progressionMembers("ULongProgression") ++
    numberMembers("Byte", true) ++ numberMembers("Short", true) ++ numberMembers("Int", true) ++
    numberMembers("Long", true) ++ numberMembers("Float", false) ++ numberMembers("Double", false) ++
    other_members;

const table = std.StaticStringMap(HostFn).initComptime(entries);

// ------------------------------------------------------------ fast paths --

/// Whether an instance holds every field `names` lists, so a fast path's
/// writes by those names land in its own slots.
fn hasFields(inst: runtime.ObjRef(runtime.InstanceData), names: []const []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    for (names) |n| if (g.get().get(n) == null) return false;
    return true;
}

fn instanceArg(args: []const Value, n: usize) ?runtime.ObjRef(runtime.InstanceData) {
    if (args.len != n or args[0] != .Instance) return null;
    return args[0].Instance;
}

fn answered(v: ?Value) ?EvalResult {
    return if (v) |x| .{ .ok = x } else null;
}

const vector_fields = [_][]const u8{ "root", "tail", "size", "rootShift", "modCount", "ownership" };
const map_builder_fields = [_][]const u8{ "node", "ownership", "size", "modCount", "operationResult" };

/// `PersistentVectorBuilder.addAll(elements)` and `addAll(index, elements)`
/// with a host list or array.
fn tryVectorAddAll(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    if (args.len < 2 or args[0] != .Instance) return null;
    const inst = args[0].Instance;
    if (!persistent_list_mut.isBuilderClass(inst) or !hasFields(inst, &vector_fields)) return null;
    return answered(switch (args.len) {
        2 => try persistent_list_mut.tryAddAll(a, inst, &args[1]),
        3 => try persistent_list_mut.tryInsertAll(a, inst, &args[1], &args[2]),
        else => null,
    });
}

/// `AbstractMutableList.removeRange(from, to)` on a vector builder; any
/// other list declines.
fn tryVectorRemoveRange(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    const inst = instanceArg(args, 3) orelse return null;
    if (!persistent_list_mut.isBuilderClass(inst) or !hasFields(inst, &vector_fields)) return null;
    return answered(try persistent_list_mut.tryRemoveRange(a, inst, &args[1], &args[2]));
}

fn tryMapBuilderPut(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    const inst = instanceArg(args, 3) orelse return null;
    if (!persistent_map_mut.isBuilderClass(inst) or !hasFields(inst, &map_builder_fields)) return null;
    return answered(try persistent_map_mut.tryPut(vm(h), a, inst, &args[1], &args[2]));
}

fn tryMapBuilderBuild(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    const inst = instanceArg(args, 1) orelse return null;
    if (!persistent_map_mut.isBuilderClass(inst) or !hasFields(inst, &map_builder_fields)) return null;
    return answered(try persistent_map_mut.tryBuild(vm(h), a, inst));
}

fn tryMapBuilder(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    const inst = instanceArg(args, 1) orelse return null;
    if (!persistent_map_mut.isMapClass(inst)) return null;
    return answered(try persistent_map_mut.tryBuilder(vm(h), a, inst));
}

/// `indexOf` on a persistent vector, scanning its leaves; an element that
/// needs its own `equals` declines.
fn tryVectorIndexOf(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    _ = a;
    const inst = instanceArg(args, 2) orelse return null;
    const idx = persistent_list_eq.tryIndexOf(inst, &args[1]) orelse return null;
    return .{ .ok = Value.newInt(idx) };
}

fn tryVectorContains(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    _ = a;
    const inst = instanceArg(args, 2) orelse return null;
    const idx = persistent_list_eq.tryIndexOf(inst, &args[1]) orelse return null;
    return .{ .ok = .{ .Bool = idx >= 0 } };
}

/// `equals` between two persistent vectors.
fn tryVectorEquals(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    _ = a;
    const inst = instanceArg(args, 2) orelse return null;
    if (args[1] != .Instance) return null;
    const eq = persistent_list_eq.tryEquals(inst, args[1].Instance) orelse return null;
    return .{ .ok = .{ .Bool = eq } };
}

/// `equals` between two persistent hash maps, comparing their tries.
fn tryHashMapEquals(h: *anyopaque, a: Allocator, args: []const Value) Allocator.Error!?EvalResult {
    _ = h;
    _ = a;
    const inst = instanceArg(args, 2) orelse return null;
    if (args[1] != .Instance) return null;
    const eq = persistent_map_eq.tryEquals(inst, args[1].Instance) orelse return null;
    return .{ .ok = .{ .Bool = eq } };
}

const immutable = "androidx.compose.runtime.external.kotlinx.collections.immutable.implementations.";

const tries = std.StaticStringMap(HostTry).initComptime(.{
    .{ immutable ++ "immutableList.PersistentVectorBuilder.addAll", tryVectorAddAll },
    .{ "kotlin.collections.AbstractMutableList.removeRange", tryVectorRemoveRange },
    .{ immutable ++ "immutableMap.PersistentHashMapBuilder.put", tryMapBuilderPut },
    .{ immutable ++ "immutableMap.PersistentHashMapBuilder.build", tryMapBuilderBuild },
    .{ immutable ++ "immutableMap.PersistentHashMap.builder", tryMapBuilder },
    .{ immutable ++ "immutableList.AbstractPersistentList.contains", tryVectorContains },
    .{ immutable ++ "immutableList.SmallPersistentVector.indexOf", tryVectorIndexOf },
    .{ "kotlin.collections.AbstractList.indexOf", tryVectorIndexOf },
    .{ "kotlin.collections.AbstractList.equals", tryVectorEquals },
    .{ "kotlin.collections.AbstractMap.equals", tryHashMapEquals },
});

test "every key is a declaration key and names one member" {
    for (entries, 0..) |e, i| {
        const key = e[0];
        const fqn = if (std.mem.startsWith(u8, key, "get ") or std.mem.startsWith(u8, key, "set ")) key[4..] else key;
        try std.testing.expect(std.mem.findScalar(u8, fqn, ' ') == null);
        try std.testing.expect(std.mem.findScalar(u8, fqn, '.') != null);
        for (entries[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, prev[0], key));
    }
    try std.testing.expect(resolve("kotlin.collections.Iterator.hasNext") != null);
    try std.testing.expect(resolve("get kotlin.collections.ArrayList.size") != null);
    try std.testing.expect(resolve("kotlin.collections.ArrayList.size") == null);
}
