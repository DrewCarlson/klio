//! `VmHost` instance construction: allocating a `Value.Instance` for a
//! `ClassId` (running primary/secondary ctors, init blocks, body-property
//! init, delegation), building anonymous-object instances, and selecting
//! the outer instance an inner-class instance captures.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const host_globals = @import("host_globals.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_member = @import("host_call_member.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../build.zig");
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
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

// -------------------------------------------------------------------------
// Per-thread constructor-shell recursion guard for secondary-ctor shell
// construction. Lazy `object` re-entrancy is handled separately by the
// shared object-init state table in `host_globals.zig`; this stack only
// breaks same-class shell recursion during secondary-ctor dispatch.
// -------------------------------------------------------------------------

threadlocal var ctor_guard: std.ArrayListUnmanaged([]const u8) = .empty;

/// Assert (Debug) the constructor-shell guard is clear at a run boundary
/// and reset it so leaked-across-runs state is a loud failure.
pub fn resetReceiverTls() void {
    std.debug.assert(ctor_guard.items.len == 0);
    ctor_guard.clearRetainingCapacity();
}

/// True while `name`'s constructor shell is being built on this thread.
pub fn ctorGuardContains(name: []const u8) bool {
    for (ctor_guard.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn ctorGuardPush(name: []const u8) void {
    ctor_guard.append(std.heap.page_allocator, name) catch {};
}

fn ctorGuardPop() void {
    _ = ctor_guard.pop();
}

// -------------------------------------------------------------------------
// Small accessors over `self.classes` and `self.prog`. Each returns a
// fresh handle / copy; the caller frees.
// -------------------------------------------------------------------------

/// Look up a runtime `ClassDef` by simple name, returning a fresh handle.
fn classDefByName(self: *VmHost, name: []const u8) ?ObjRef(ClassDef) {
    const g = self.classes.borrow();
    defer g.deinit();
    if (g.get().get(name)) |d| return d.clone();
    return null;
}

/// Resolve a class written with a dotted qualifier (`Outer.Inner`) by
/// matching it as a `.`-aligned suffix of a registered class's FQN, taking
/// the shortest (least-nested) FQN among matches. Disambiguates a nested base
/// from a same-simple-name class in scope — including a subtype named like its
/// base. `null` when `qualified` is unqualified or unmatched.
fn classDefByQualifiedSuffix(self: *VmHost, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.indexOfScalar(u8, qualified, '.') == null) return null;
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

/// Class-keyed side tables hold one entry under the class's simple name
/// and (when it differs) one under its FQN. A caller that knows the
/// resolved FQN resolves through it exclusively — the simple-name entry
/// may belong to a same-simple-name class from another package — while a
/// simple-name-only caller (synthesized classes) keeps the legacy view.
fn sideTableKey(fqn: ?[]const u8, name: []const u8) []const u8 {
    const f = fqn orelse return name;
    return if (f.len != 0) f else name;
}

/// The static argument heads the current construction site supplied, set by
/// the eval arm and consumed ONCE: a delegation or a default thunk builds
/// further instances underneath and must rank on its own terms.
threadlocal var ctor_static_heads: ?[]const ?[]const u8 = null;

/// The construction site's static heads live in this thread-owned buffer:
/// the array a site hands over is freed when the site returns (the bytecode
/// tier's NewInstance arm never takes it back), and a later secondary-ctor
/// ranking on the same thread read the freed array. The head strings are
/// module constants, so copying the slice array is enough. A site with more
/// arguments than the buffer holds ranks without static heads.
const CTOR_HEADS_MAX = 32;
threadlocal var ctor_static_heads_buf: [CTOR_HEADS_MAX]?[]const u8 = undefined;

pub fn setCtorArgStaticHeads(self: *VmHost, heads: []const ?[]const u8) void {
    _ = self;
    if (heads.len == 0 or heads.len > CTOR_HEADS_MAX) {
        ctor_static_heads = null;
        return;
    }
    @memcpy(ctor_static_heads_buf[0..heads.len], heads);
    ctor_static_heads = ctor_static_heads_buf[0..heads.len];
}

/// Forget any construction-site heads left installed by a path that never
/// took them (a host class, a factory, a value-class shortcut): the slice
/// they name is freed when the site returns, and the next secondary-ctor
/// ranking on this thread would read it.
pub fn clearCtorArgStaticHeads(self: *VmHost) void {
    _ = self;
    ctor_static_heads = null;
}

fn takeCtorStaticHeads() ?[]const ?[]const u8 {
    const v = ctor_static_heads;
    ctor_static_heads = null;
    return v;
}

fn secondaryCtors(self: *VmHost, fqn: ?[]const u8, name: []const u8) []const root.build.SecondaryCtorEntry {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().secondary_ctors.get(sideTableKey(fqn, name)) orelse &.{};
}

/// Whether any declared secondary constructor of the class can bind `n`
/// arguments by count (required-without-defaults through total). Serves the
/// dispatcher's ctor-applicability gate: a capitalized bare call whose class
/// has no bindable constructor is not a construction.
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

/// Simple runtime type-name head of a value (`IntArray`, `Int`).
fn valueTypeHead(v: Value) []const u8 {
    const fqn = v.typeFqn();
    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

/// Pick the secondary ctor for `args` by arity, disambiguating same-arity
/// overloads by argument type (`AtomicIntArray(size: Int)` vs
/// `AtomicIntArray(array: IntArray)`). Falls back to the first arity match when
/// no parameter type distinguishes them.
fn headInSet(head: []const u8, set: []const []const u8) bool {
    for (set) |h| {
        if (std.mem.eql(u8, head, h)) return true;
    }
    return false;
}

const integral_heads = [_][]const u8{ "Int", "Long", "Short", "Byte", "UInt", "ULong", "UShort", "UByte", "Char" };
const collectionish_heads = [_][]const u8{ "Collection", "MutableCollection", "Iterable", "MutableIterable", "List", "MutableList", "Set", "MutableSet", "Sequence" };

/// Whether a constructor parameter declared `declared` can accept `arg`. A
/// class-instance argument must be a subtype of a concrete class-typed
/// parameter; otherwise a `this(...)` / constructor delegation whose named args
/// map to a differently-typed constructor (e.g. a `color: Color`/`Int`
/// secondary vs the primary's `textForegroundStyle: TextForegroundStyle`) would
/// silently bind the wrong slot. Type parameters (`T`, `E`) and `Any` accept
/// anything; non-instance values (primitives, null, lambdas) are left to the
/// arity/family logic.
fn paramAcceptsArg(self: *VmHost, declared: []const u8, arg: *const Value) bool {
    if (std.mem.eql(u8, declared, "Any")) return true;
    if (declared.len <= 2 and isAllUpper(declared)) return true;
    // A function-typed parameter accepts any callable argument regardless of
    // the recorded arity head — a receiver-style suspend lambda's declared
    // head (`Function0`) and the closure's own shape count receivers
    // differently, and rejecting here let a `this(...)`-delegating secondary
    // constructor lose its lambda to the primary's SAM slot
    // (`SuspendingPointerInputModifierNodeImpl`'s deprecated handler ctor).
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
        // Only disqualify when `declared` is a class the argument is NOT: a
        // typealias or otherwise-unresolved receiver name (a `Point` alias for
        // `FloatFloatPair`) has no ClassDef, so the mismatch is unconfirmed and
        // the candidate must not be rejected.
        const kd = classDefByName(self, declared);
        if (kd) |d| d.deinit();
        return kd == null;
    }
    // A non-instance builtin value (String, a list, an Int, …) offered to a
    // parameter of a definitely-different builtin kind cannot match — a
    // `String` param must not swallow a `List` argument, which would let an
    // overloaded `this(...)` delegation pick a same-arity ctor with swapped
    // parameters and recurse. Unknown kinds (0, e.g. a class type or a
    // supertype like `Any`/`Number`) accept anything.
    const gk = builtinTypeKind(valueTypeHead(arg.*));
    const dk = builtinTypeKind(declared);
    if (gk != 0 and dk != 0 and gk != dk) return false;
    return true;
}

/// Coarse bucket for a builtin type head, so a definite cross-kind argument
/// mismatch (a list for a string param) disqualifies a constructor candidate.
/// `0` means "not a recognised concrete builtin" (class, type parameter, or a
/// supertype like `Number`/`CharSequence`) and matches anything.
fn builtinTypeKind(head: []const u8) u8 {
    if (headInSet(head, &integral_heads)) return 1;
    if (std.mem.eql(u8, head, "Float") or std.mem.eql(u8, head, "Double")) return 2;
    if (std.mem.eql(u8, head, "Boolean")) return 3;
    if (std.mem.eql(u8, head, "String")) return 5;
    if (headInSet(head, &collectionish_heads)) return 6;
    if (std.mem.eql(u8, head, "Map") or std.mem.eql(u8, head, "MutableMap") or
        std.mem.eql(u8, head, "HashMap") or std.mem.eql(u8, head, "LinkedHashMap")) return 7;
    return 0;
}

/// Type-fit of one ctor candidate's declared param heads against the
/// runtime args, on the shared scale `chooseSecondaryCtor` ranks with:
/// exact head +2, family match +1 (+2 for a callable meeting a
/// FunctionN head, which is Kotlin's more-specific pick vs a SAM slot),
/// definite cross-family mismatch = null (disqualified).
fn scoreCtorHeads(self: *VmHost, heads: []const []const u8, args: []const Value) ?i32 {
    var score: i32 = 0;
    var i: usize = 0;
    const static_heads = ctor_static_heads;
    while (i < args.len and i < heads.len) : (i += 1) {
        const declared = heads[i];
        const got = valueTypeHead(args[i]);
        // The argument's DECLARED head, where the call site knew one. An
        // interpreted instance reports no class of its own at run time, so
        // this is the only evidence that can tell a subtype argument from a
        // supertype-typed one — which is what Kotlin selects on.
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
        // Confirmed subtype (superclass or interface chain) is positive
        // evidence, below an exact head match: `TweenSpec` fits an
        // `AnimationSpec<T>` slot and must outrank a candidate whose slot
        // (`VectorizedAnimationSpec<V>`) merely fails to disqualify.
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

fn isCallableArg(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure => true,
        else => false,
    };
}

fn chooseSecondaryCtor(self: *VmHost, entries: []const root.build.SecondaryCtorEntry, args: []const Value) ?root.build.SecondaryCtorEntry {
    // Two passes. A `@Deprecated(level = HIDDEN)` constructor is not a
    // source-level candidate in kotlinc at all — it exists only for binary
    // compatibility — so it must never beat an ordinary one. It stays reachable
    // as a LAST resort (a class whose only secondary constructor is hidden).
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        const want_low = pass == 1;
        var best: ?root.build.SecondaryCtorEntry = null;
        var best_score: i32 = -1;
        for (entries) |e| {
            if (e.low_priority != want_low) continue;
            if (e.param_count != args.len) continue;
            const score = scoreCtorHeads(self, e.param_type_heads, args) orelse continue;
            // Reached only when no parameter disqualified this candidate: it is a
            // genuine arity+type match, so it is eligible as the fallback too.
            if (score > best_score) {
                best_score = score;
                best = e;
            }
        }
        if (best != null) return best;
    }
    return null;
}

/// Expand a superclass constructor call that selects a secondary
/// `this(...)` constructor into the primary arguments used to initialize that
/// class. This is required when an expect constructor maps to an actual
/// secondary constructor with a differently shaped primary constructor.
fn expandParentSecondaryThisArgs(
    self: *VmHost,
    allocator: Allocator,
    class_fqn: ?[]const u8,
    class_name: []const u8,
    args: *std.ArrayList(Value),
) Allocator.Error!UnitOrErr {
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const def = classDefByName(self, sideTableKey(class_fqn, class_name)) orelse return .{ .ok = {} };
        const primary_count = classDefPrimaryParamCount(def);
        def.deinit();
        const entries = secondaryCtors(self, class_fqn, class_name);
        const entry = chooseSecondaryCtor(self, entries, args.items) orelse return .{ .ok = {} };
        if (args.items.len == primary_count and primary_count != 0) return .{ .ok = {} };
        if (!entry.is_this) return .{ .ok = {} };

        var target: std.ArrayList(Value) = .empty;
        errdefer target.deinit(allocator);
        for (entry.delegation_arg_thunks) |fid| {
            const fr = try funcAt(self, fid, "secondary ctor arg");
            switch (fr) {
                .err => |e| return .{ .err = e },
                .ok => |func| {
                    switch (try evalThunk(self, func, args.items)) {
                        .ok => |v| try target.append(allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        args.deinit(allocator);
        args.* = target;
        runtime.keepalivePushSlice(args.items);
    }
    return .{ .err = try typeErr(allocator, "secondary constructor delegation for `{s}` is recursive", .{class_name}) };
}

fn parentCtorArgThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().parent_ctor_args.get(sideTableKey(fqn, name));
}

/// The argument labels for the super-constructor call in `class`'s primary
/// delegation (`: Base(objects = 2)`), parallel to `parentCtorArgThunks`.
/// `null` when the call was fully positional.
fn parentCtorArgNames(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const ?[]const u8 {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().parent_ctor_arg_names.get(sideTableKey(fqn, name));
}

/// The index of `param_name` in `pp`, or null if none matches. Used to bind
/// a named super-constructor argument to the base parameter of that name.
fn paramIndexByName(pp: []const runtime.ClassParamDef, param_name: []const u8) ?usize {
    for (pp, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, param_name)) return i;
    }
    return null;
}

/// The `this` slot for a primary-ctor default-arg thunk: an INNER class's
/// default expressions evaluate with the enclosing instance as the lexical
/// receiver (`val maxIndex: Int = size` inside `inner class ... ` reads the
/// OUTER `size` — the instance under construction does not exist yet), so
/// the constructing frame's outer hint fills the slot. Non-inner classes
/// have no outer receiver in scope: their slot stays Null.
fn ctorThunkThisSlot(class_def: ObjRef(ClassDef), outer_hint: ?*const Value) Value {
    const oh = outer_hint orelse return .Null;
    const dg = class_def.borrow();
    defer dg.deinit();
    if (!dg.get().is_inner) return .Null;
    return oh.*;
}

fn primaryDefaultThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) ?[]const ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().primary_ctor_default_thunks.get(sideTableKey(fqn, name));
}

fn classDelegateThunks(self: *VmHost, fqn: ?[]const u8, name: []const u8) []const root.build.StrFunc {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().class_delegates.get(sideTableKey(fqn, name)) orelse &.{};
}

/// Serve a trivial property initializer (one constant, or one parameter
/// echo) without a framed eval; null = not trivial, run the body.
/// `all` is the initializer call vector `[this, ctor args...]`.
fn trivialInitServe(allocator: Allocator, m: *const ir.Module, func: *const ir.Func, all: []const Value) Allocator.Error!?Value {
    if (func.triv_init_state == 0) {
        const mut = @constCast(func);
        mut.triv_init_state = 1;
        // An image func decodes its body lazily; classify the real blocks.
        if (func.blocks.len == 0) _ = m.ensureFuncBody(mut);
        if (func.blocks.len == 1) one: {
            const blk = &func.blocks[0];
            if (blk.catches.len != 0 or blk.finally != null) break :one;
            if (blk.terminator != .Return) break :one;
            const ret_reg = blk.terminator.Return orelse break :one;
            if (blk.insts.len > 24) break :one;
            // The lowered thunk prologue loads every ctor param; the body
            // is trivial when each inst is a param load or a Const whose
            // destination is the returned register. The LAST write to the
            // return register decides the served value.
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

fn bodyPropInit(self: *VmHost, class_fqn: ?[]const u8, class_name: []const u8, prop_name: []const u8) ?FuncId {
    const g = self.prog.borrow();
    defer g.deinit();
    return g.get().body_prop_inits.get(.{ .a = sideTableKey(class_fqn, class_name), .b = prop_name });
}

fn appendPrimaryCtorPropertyFields(
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

/// kotlinc ADOPTS an integer literal to the declared type at the call site
/// (`C(2)` with `val s: Short` stores a Short; `arrayOf(1, 2)` bound to
/// `Array<Byte>` holds Bytes). klio's lowering adopts function parameters
/// but not constructor properties, so the declared boundary retags here: an
/// `.Int` value against a narrower declared scalar, and an array/list
/// value's `.Int` elements against a declared `Array<scalar>`. Only the
/// literal-compatible `.Int` repr converts — a genuinely Int-typed value
/// cannot reach a `Short` slot in valid Kotlin.
fn adoptDeclaredNumeric(param: *const runtime.ClassParamDef, v: Value) Value {
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

fn scalarRetagName(name: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, name, "Byte") or eq(u8, name, "Short") or eq(u8, name, "Long");
}

/// The simple head of a declared type name: no package qualifier, generic
/// arguments, or nullability.
fn typeHeadOfName(name: []const u8) []const u8 {
    var t = std.mem.trimEnd(u8, name, "?");
    if (std.mem.indexOfScalar(u8, t, '<')) |lt| t = t[0..lt];
    if (std.mem.lastIndexOfScalar(u8, t, '.')) |d| t = t[d + 1 ..];
    return t;
}

fn scalarRetag(name: []const u8, iv: i64) ?Value {
    const eq = std.mem.eql;
    if (eq(u8, name, "Byte")) return .{ .Byte = @truncate(iv) };
    if (eq(u8, name, "Short")) return .{ .Short = @truncate(iv) };
    if (eq(u8, name, "Long")) return .{ .Long = iv };
    return null;
}

/// The instance-identity counter for host modules that mint interpreted
/// instances directly (the persistent-collection fast paths).
pub fn mintInstanceId(self: *VmHost) u64 {
    return nextInstanceId(self);
}

fn nextInstanceId(self: *VmHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// Materialise a `*const Func` for `fid` against the host module, or an
/// error result when the id is out of range.
fn funcAt(self: *VmHost, fid: FuncId, comptime ctx: []const u8) Allocator.Error!union(enum) { ok: *const ir.Func, err: EvalError } {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    return .{ .ok = m.funcById(fid) orelse {
        return .{ .err = try typeErr(self.allocator, ctx ++ " FuncId {d} out of range", .{fid.int()}) };
    } };
}

/// The storage key for `prop` declared by `cls`: the owner-mangled
/// registry key when the property is a recorded private SHADOW of a
/// supertype's same-name declaration (its own distinct cell, Kotlin
/// semantics), else the plain name. The mangled slice is the registry's
/// own stable key.
fn shadowFieldKey(self: *VmHost, cls: []const u8, prop: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ cls, prop }) catch return prop;
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.private_shadow_props.getKey(probe)) |k| return k;
    return mg.get().registry.override_cell_props.getKey(probe) orelse prop;
}

/// Whether `cls`'s `prop` is a recorded private SHADOW of a supertype's
/// same-name stored property — a distinct cell whose store must leave the
/// base's plain cell untouched.
fn isPrivateShadowProp(self: *VmHost, cls: []const u8, prop: []const u8) bool {
    var buf: [256]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ cls, prop }) catch return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    return mg.get().registry.private_shadow_props.getKey(probe) != null;
}

/// Evaluate `func` against `args`, returning its result. The module
/// handle is borrowed for the call's duration.
fn evalThunk(self: *VmHost, func: *const ir.Func, args: []const Value) Allocator.Error!EvalResult {
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

/// Initialize a runtime-registered LOCAL class instance's MODULE parent
/// chain: evaluate the leaf's `$super$arg$<i>` thunks (registered by
/// `registerClass`) against the constructor args, bind each module
/// ancestor's primary-param fields, run its body-property init thunks, and
/// continue up with that level's own parent-ctor-arg thunks. Parent
/// `init { }` blocks are not yet replayed here.
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
            const simple = if (std.mem.lastIndexOfScalar(u8, sn, '.')) |d| sn[d + 1 ..] else sn;
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
    // Leaf-level super args via the anon `$super$arg$<i>` thunks.
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
    // The parent may be the stdlib's own `Exception`/`Throwable` class def,
    // whose message and cause are bound by name rather than by primary
    // parameters.
    if (cur_def) |pd| {
        const pg = pd.borrow();
        const pn = pg.get().name;
        pg.deinit();
        const simple = if (std.mem.lastIndexOfScalar(u8, pn, '.')) |d| pn[d + 1 ..] else pn;
        if (isBuiltinThrowableName(simple)) try bindThrowableArgs(self, inst, cur_args.items, true);
    }
    while (cur_def) |pd| {
        defer pd.deinit();
        const pg = pd.borrow();
        const p_name = pg.get().name;
        const p_fqn = pg.get().fqn;
        // Bind primary-param fields.
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
        // Body-property init thunks (static build map).
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
        // Next level's args via the module side table.
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

fn evalParentCtorThunk(
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

// -------------------------------------------------------------------------
// Free helpers used only by the construction flow.
// -------------------------------------------------------------------------

fn simpleLiteral(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    switch (e.*) {
        .IntLit => |l| return Value.newInt(l.value),
        .FloatLit => |l| return if (l.kind == .Float)
            Value{ .Float = @floatCast(l.value) }
        else
            Value{ .Double = l.value },
        .BoolLit => |l| return Value{ .Bool = l.value },
        .NullLit => return Value.Null,
        .CharLit => |l| return Value{ .Char = l.value },
        .StringTemplate => |t| {
            for (t.parts) |p| {
                if (p != .Text) return null;
            }
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            for (t.parts) |p| {
                try buf.appendSlice(allocator, p.Text);
            }
            const owned = try buf.toOwnedSlice(allocator);
            return Value{ .String = try runtime.strInitOwned(allocator, owned) };
        },
        else => return null,
    }
}

fn emptyList(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newList(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

fn emptySet(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newSet(allocator, .{
        .items = try ObjRef(std.ArrayList(Value)).init(allocator, .empty),
        .mutable = mutable,
        .backing = null,
    });
}

fn emptyMap(allocator: Allocator, mutable: bool) Allocator.Error!Value {
    return try Value.newMap(allocator, .{
        .entries = try runtime.MapEntries.init(allocator, .{}),
        .mutable = mutable,
    });
}

fn defaultValueForPrimary(allocator: Allocator, e: *const ast.Expr) Allocator.Error!?Value {
    if (try simpleLiteral(allocator, e)) |v| return v;
    if (e.* == .Call) {
        const c = e.Call;
        if (c.args.len != 0) return null;
        if (c.callee.* == .Path) {
            const segs = c.callee.Path.segments;
            if (segs.len == 1) {
                const nm = segs[0].name;
                const eq = std.mem.eql;
                if (eq(u8, nm, "mutableListOf") or eq(u8, nm, "arrayListOf") or eq(u8, nm, "ArrayList")) {
                    return try emptyList(allocator, true);
                }
                if (eq(u8, nm, "listOf") or eq(u8, nm, "emptyList")) {
                    return try emptyList(allocator, false);
                }
                if (eq(u8, nm, "mutableSetOf") or eq(u8, nm, "hashSetOf") or eq(u8, nm, "linkedSetOf")) {
                    return try emptySet(allocator, true);
                }
                if (eq(u8, nm, "setOf") or eq(u8, nm, "emptySet")) {
                    return try emptySet(allocator, false);
                }
                if (eq(u8, nm, "mutableMapOf") or eq(u8, nm, "hashMapOf") or eq(u8, nm, "linkedMapOf")) {
                    return try emptyMap(allocator, true);
                }
                if (eq(u8, nm, "mapOf") or eq(u8, nm, "emptyMap")) {
                    return try emptyMap(allocator, false);
                }
            }
        }
    }
    return null;
}

/// Resolve a single-segment `Path` default against the const registry,
/// returning its `Value` when present.
fn pathConstDefault(self: *VmHost, e: *const ast.Expr) Allocator.Error!?Value {
    if (e.* != .Path) return null;
    const segs = e.Path.segments;
    if (segs.len != 1) return null;
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    if (m.registry.class_const_inits.get(.{ .a = "", .b = segs[0].name })) |c| {
        return try ir.eval.constToValue(self.allocator, &c);
    }
    return null;
}

/// Pack trailing positional args into the primary ctor's `vararg` slot.
/// `class_fqn`, when known, keys the module class exactly so a
/// same-simple-name class from another package cannot supply the params.
fn packPrimaryCtorVarargs(self: *VmHost, class_fqn: ?[]const u8, class_name: []const u8, args: []Value) Allocator.Error![]Value {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    const by_fqn: ?ir.ClassId = if (class_fqn) |fq| m.classIdByFqn(fq) else null;
    const cid = by_fqn orelse m.classId(class_name) orelse return args;
    if (cid.int() >= m.classes.items.len) return args;
    const ir_cls = &m.classes.items[cid.int()];
    const params = ir_cls.primary_params;
    if (params.len == 0) return args;
    // Declared numeric parameter typing (kotlinc literal typing): an Int
    // reaching a `Long`/`Short`/`Byte` parameter can only have been an
    // integer literal, so it takes the declared type before the init body
    // and the property stores see it (`LongRange(1, 0)` hands
    // `LongProgression` two Longs).
    for (args, 0..) |*arg, i| {
        if (i >= params.len) break;
        if (arg.* != .Int) continue;
        if (scalarRetag(typeHeadOfName(params[i].ty.name), arg.Int)) |rv| arg.* = rv;
    }
    const last = params[params.len - 1];
    if (!last.is_vararg) return args;
    const fixed = if (params.len == 0) 0 else params.len - 1;
    if (args.len == params.len and args.len > 0 and args[args.len - 1] == .Array) {
        return args;
    }
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(self.allocator);
    var i: usize = 0;
    while (i < fixed and i < args.len) : (i += 1) {
        try out.append(self.allocator, args[i]);
    }
    var rest: std.ArrayList(Value) = .empty;
    errdefer rest.deinit(self.allocator);
    var j: usize = fixed;
    while (j < args.len) : (j += 1) {
        try rest.append(self.allocator, args[j]);
    }
    try out.append(self.allocator, runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(self.allocator, rest)));
    self.allocator.free(args);
    return out.toOwnedSlice(self.allocator);
}

// -------------------------------------------------------------------------
// Methods this flow depends on, kept here so the construction path is
// self-contained; they read shared `VmHost` state.
// -------------------------------------------------------------------------

fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only; consult it unguarded
    // (gated on the published link flag) instead of taking two shared
    // reader locks per lookup.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    {
        const g = self.prog.borrow();
        defer g.deinit();
        const bg = g.get().installed_bindings.borrow();
        defer bg.deinit();
        if (bg.get().resolve(fqn)) |f| return f;
    }
    return stdlib.implementation(fqn);
}

fn dispatchIntrinsic(self: *VmHost, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(self.allocator, "intrinsic_instances", fqn, null, null, args);
    const keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(keepalive);
    runtime.keepalivePushSlice(args);
    var ih = VmIntrinsicHost{
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
    defer {
        ih.module.deinit();
        ih.closures.deinit();
        ih.globals.deinit();
        ih.classes.deinit();
        ih.prog.deinit();
        ih.anon_methods.deinit();
        ih.class_default_outer.deinit();
        ih.instance_id_counter.deinit();
        ih.out_sink.deinit();
        ih.threads.deinit();
        ih.object_states.deinit();
    }
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = ih.intrinsicHost(),
        .allocator = self.allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn_lt;
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| switch (e) {
            .Thrown => |v| .{ .err = .{ .Throw = v } },
            .Return => |v| .{ .err = .{ .NonLocalReturn = v } },
            .Suspend => |wake| blk: {
                const st = try self.allocator.create(ir.eval.SuspendState);
                st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
                break :blk .{ .err = .{ .Suspended = st } };
            },
            .Unbound => |m| .{ .err = .{ .Unbound = m } },
            .Type => |m| .{ .err = .{ .Type = m } },
            .Arity => |m| .{ .err = .{ .Arity = m } },
            .Unimplemented => |m| .{ .err = .{ .Unimplemented = m } },
            .CalleeFailed => |m| .{ .err = .{ .CalleeFailed = m } },
            else => .{ .err = try typeErr(self.allocator, "{s}", .{@tagName(e)}) },
        },
    };
}

fn isBuiltinThrowableName(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IllegalArgumentException",        "IllegalStateException",
        "IndexOutOfBoundsException",       "NullPointerException",
        "ClassCastException",              "ArithmeticException",
        "NumberFormatException",           "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
        "CancellationException",           "ArrayIndexOutOfBoundsException",
        "StringIndexOutOfBoundsException", "UninitializedPropertyAccessException",
        "NoWhenBranchMatchedException",    "NegativeArraySizeException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Whether the instance already carries a non-null field under `key`.
fn hasNonNullField(inst: ObjRef(InstanceData), key: []const u8) bool {
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items) |f| {
        if (std.mem.eql(u8, f.name, key) and f.value != .Null) return true;
    }
    return false;
}

fn retainField(g: *InstanceData, allocator: Allocator, key: []const u8) void {
    var i: usize = 0;
    while (i < g.fields.items.len) {
        if (std.mem.eql(u8, g.fields.items[i].name, key)) {
            _ = g.fields.orderedRemove(i);
            g.invalidateShape();
        } else {
            i += 1;
        }
    }
    _ = allocator;
}

fn pushField(g: *InstanceData, allocator: Allocator, key: []const u8, v: Value) Allocator.Error!void {
    try g.ensureFieldsOwned(allocator, 1);
    try g.fields.append(allocator, .{ .name = key, .value = v });
    g.invalidateShape();
}

/// Bind the conventional `(message[, cause])` super-args onto a leaf
/// Throwable instance.
fn bindThrowableArgs(self: *VmHost, inst: ObjRef(InstanceData), args: []const Value, only_when_unset: bool) Allocator.Error!void {
    // The unset probe runs before the exclusive borrow below: the
    // instance lock is not reentrant, so a read taken under the held
    // write borrow deadlocks the constructing thread against itself.
    const skip_single = only_when_unset and args.len == 1 and
        hasNonNullField(inst, if (args[0] == .Instance) "cause" else "message");
    if (skip_single) return;
    const g = inst.borrowMut();
    defer g.deinit();
    const i = g.get();
    if (args.len == 1) {
        const only = args[0];
        const is_cause = only == .Instance;
        const key: []const u8 = if (is_cause) "cause" else "message";
        retainField(i, self.allocator, key);
        try pushField(i, self.allocator, key, only);
    } else if (args.len >= 2) {
        retainField(i, self.allocator, "message");
        retainField(i, self.allocator, "cause");
        try pushField(i, self.allocator, "message", args[0]);
        try pushField(i, self.allocator, "cause", args[1]);
    }
}

const UnitOrErr = union(enum) { ok: void, err: EvalError };

/// Dispatch the parent's matching secondary-ctor chain on the same leaf.
fn runSuperCtorChain(
    self: *VmHost,
    leaf: *const Value,
    class_fqn: ?[]const u8,
    class_name: []const u8,
    args: []const Value,
    arg_names: ?[]const ?[]const u8,
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    if (isBuiltinThrowableName(class_name)) {
        if (leaf.* == .Instance) {
            try bindThrowableArgs(self, leaf.Instance, args, true);
            // fillInStackTrace at construction (JVM order): the throwable's
            // super-chain just established it as a Throwable, so capture here.
            var tv = leaf.*;
            try ir.eval.attachStackTrace(self.allocator, &tv);
        }
        return .{ .ok = {} };
    }
    const entries = secondaryCtors(self, class_fqn, class_name);
    const chosen: ?root.build.SecondaryCtorEntry = chooseSecondaryCtor(self, entries, args);
    // The chosen constructor's declared numeric parameter types retag
    // integer arguments the same way the primary path does.
    const args_typed: []Value = try self.allocator.dupe(Value, args);
    defer self.allocator.free(args_typed);
    if (chosen) |e| {
        for (args_typed, 0..) |*arg, i| {
            if (i >= e.param_type_heads.len) break;
            if (arg.* != .Int) continue;
            if (scalarRetag(e.param_type_heads[i], arg.Int)) |rv| arg.* = rv;
        }
    }
    const entry = chosen orelse {
        // No secondary ctor takes this shape: the class delegates through
        // its PRIMARY ctor (`open class A(msg: String) : B(msg)`). Bind
        // its property params onto the leaf where the leaf does not
        // already carry them (child overrides win), evaluate the
        // supertype-call args against the primary params, and continue
        // the chain with the parent.
        const def = classDefByName(self, sideTableKey(class_fqn, class_name)) orelse return .{ .ok = {} };
        defer def.deinit();
        if (leaf.* == .Instance) {
            const dg = def.borrow();
            const pp = dg.get().primary_params;
            var k: usize = 0;
            while (k < args.len) : (k += 1) {
                // A named super-constructor argument (`: Base(objects = 2)`)
                // binds to the base parameter of that name, not by position;
                // an unnamed argument keeps its positional slot.
                const target: usize =
                    if (arg_names) |names|
                        (if (k < names.len) (if (names[k]) |nm| (paramIndexByName(pp, nm) orelse k) else k) else k)
                    else
                        k;
                if (target >= pp.len) continue;
                if (pp[target].property == null) continue;
                if (hasNonNullField(leaf.Instance, pp[target].name)) continue;
                const g = leaf.Instance.borrowMut();
                retainField(g.get(), self.allocator, pp[target].name);
                try pushField(g.get(), self.allocator, pp[target].name, adoptDeclaredNumeric(&pp[target], args[k]));
                g.deinit();
            }
            dg.deinit();
        }
        const thunks = parentCtorArgThunks(self, class_fqn, class_name) orelse return .{ .ok = {} };
        var parent_args: std.ArrayList(Value) = .empty;
        defer parent_args.deinit(self.allocator);
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "parent ctor arg");
            switch (fr) {
                .err => |e| return .{ .err = e },
                .ok => |func| {
                    switch (try evalParentCtorThunk(self, func, args, outer_hint)) {
                        .ok => |v| try parent_args.append(self.allocator, v),
                        .err => |e| return .{ .err = e },
                    }
                },
            }
        }
        const pref = firstNonInterfaceSuper(self, def) orelse return .{ .ok = {} };
        if (std.mem.eql(u8, pref.name, class_name)) return .{ .ok = {} };
        // The labels of this class's super-constructor call apply to the
        // parent's parameters, so thread them into the parent's frame.
        const parent_names = parentCtorArgNames(self, class_fqn, class_name);
        return try runSuperCtorChain(self, leaf, pref.fqn, pref.name, parent_args.items, parent_names, outer_hint);
    };

    var next_args: std.ArrayList(Value) = .empty;
    defer next_args.deinit(self.allocator);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return .{ .err = e },
            .ok => |func| {
                switch (try evalThunk(self, func, args_typed)) {
                    .ok => |v| try next_args.append(self.allocator, v),
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    if (entry.is_this) {
        switch (try runSuperCtorChain(self, leaf, class_fqn, class_name, next_args.items, null, outer_hint)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    } else if (entry.is_super) {
        // The `super(...)` target is the parent of the class whose ctor
        // we're currently running.
        var parent_name: ?[]const u8 = null;
        var parent_fqn: ?[]const u8 = null;
        if (classDefByName(self, sideTableKey(class_fqn, class_name))) |def| {
            const dg = def.borrow();
            if (dg.get().parent) |parent| {
                const pcg = parent.borrow();
                parent_name = pcg.get().name;
                parent_fqn = pcg.get().fqn;
                pcg.deinit();
            }
            dg.deinit();
            def.deinit();
        }
        if (parent_name) |p| {
            switch (try runSuperCtorChain(self, leaf, parent_fqn, p, next_args.items, null, outer_hint)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
    }
    if (entry.body) |body_fid| {
        const fr = try funcAt(self, body_fid, "secondary ctor body");
        switch (fr) {
            .err => {},
            .ok => |body_func| {
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(self.allocator);
                try all.append(self.allocator, leaf.*);
                try all.appendSlice(self.allocator, args_typed);
                switch (try evalThunk(self, body_func, all.items)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    return .{ .ok = {} };
}

const ChainEntry = struct { name: []const u8, fqn: ?[]const u8 = null, args: []Value };

/// Evaluate every named class-to-class delegation below the direct
/// superclass of an object expression. The direct call has already been
/// evaluated in the enclosing lexical scope; subsequent calls use each
/// class's primary-constructor parameters, just like named construction.
fn extendAnonymousParentCtorArgs(
    self: *VmHost,
    allocator: Allocator,
    direct_def: ObjRef(ClassDef),
    direct_args: []Value,
    outer_hint: ?*const Value,
    fields: *std.ArrayList(InstanceData.Field),
    args_by_class: *std.StringHashMap([]Value),
) Allocator.Error!UnitOrErr {
    var cur_def: ?ObjRef(ClassDef) = direct_def.clone();
    defer if (cur_def) |d| d.deinit();
    var cur_args: []const Value = direct_args;
    var depth: usize = 0;

    while (cur_def) |cdef| {
        if (depth >= 128) break;
        depth += 1;

        const cur_name = classDefName(cdef);
        const cur_fqn = classDefFqn(cdef);
        const thunks = parentCtorArgThunks(self, cur_fqn, cur_name) orelse break;
        const pref = firstNonInterfaceSuper(self, cdef) orelse break;
        if (std.mem.eql(u8, pref.name, cur_name)) break;

        var parent_args: std.ArrayList(Value) = .empty;
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "anonymous parent ctor arg");
            switch (fr) {
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
                .ok => |func| switch (try evalParentCtorThunk(self, func, cur_args, outer_hint)) {
                    .ok => |v| try parent_args.append(allocator, v),
                    .err => |e| {
                        parent_args.deinit(allocator);
                        return .{ .err = e };
                    },
                },
            }
        }

        const parent_def = classDefByName(self, sideTableKey(pref.fqn, pref.name)) orelse {
            parent_args.deinit(allocator);
            break;
        };
        if (classDefIsInterface(parent_def)) {
            parent_def.deinit();
            parent_args.deinit(allocator);
            break;
        }
        switch (try reorderNamedSuperArgs(
            self,
            allocator,
            parent_def,
            pref.fqn,
            pref.name,
            parentCtorArgNames(self, cur_fqn, cur_name),
            &parent_args,
            outer_hint,
        )) {
            .ok => {},
            .err => |e| {
                parent_def.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        switch (try padParentCtorDefaults(self, allocator, parent_def, pref.fqn, pref.name, &parent_args, outer_hint)) {
            .ok => {},
            .err => |e| {
                parent_def.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        const packed_args = try packPrimaryCtorVarargs(self, pref.fqn, pref.name, try parent_args.toOwnedSlice(allocator));
        try appendPrimaryCtorPropertyFields(allocator, fields, parent_def, packed_args);
        try args_by_class.put(pref.name, packed_args);

        cur_def.?.deinit();
        cur_def = parent_def;
        cur_args = packed_args;
    }
    return .{ .ok = {} };
}

/// Whether a chain entry denotes the same class as (`fqn`, `name`):
/// resolved-FQN identity when both sides carry one, written-name
/// equality otherwise.
fn chainEntryIs(entry: *const ChainEntry, fqn: ?[]const u8, name: []const u8) bool {
    if (entry.fqn) |ef| {
        if (fqn) |f| return std.mem.eql(u8, ef, f);
    }
    return std.mem.eql(u8, entry.name, name);
}

/// Resolve a supertype written as a simple name from `child_fqn`'s
/// perspective: the child's own package first (Kotlin scoping), then the
/// program-wide simple-name view — so a same-simple-name class from
/// another package cannot become the parent.
fn classDefForSuper(self: *VmHost, child_fqn: []const u8, child_name: []const u8, sup_name: []const u8) ?ObjRef(ClassDef) {
    const pkg = ir.packageOfFqn(child_fqn, child_name);
    if (pkg.len != 0) {
        const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pkg, sup_name }) catch
            return classDefByName(self, sup_name);
        defer self.allocator.free(qualified);
        if (classDefByName(self, qualified)) |d| return d;
    }
    return classDefByName(self, sup_name);
}

const SuperRef = struct { name: []const u8, fqn: ?[]const u8 };

/// First supertype of `def` that is not a known interface — the parent
/// the ctor chain delegates to. Resolution is package-aware via
/// `classDefForSuper`; a name with no runtime def (a builtin Throwable
/// parent) is returned with a null fqn, preserving the written name.
fn firstNonInterfaceSuper(self: *VmHost, def: ObjRef(ClassDef)) ?SuperRef {
    const dg = def.borrow();
    defer dg.deinit();
    // Single-fill memo: the answer is a pure function of the (immutable)
    // class graph, and this runs on every instance construction.
    switch (@atomicLoad(u8, @constCast(&dg.get().first_super_state), .acquire)) {
        1 => return null,
        2 => {
            const idx = dg.get().first_super_index;
            return .{
                .name = dg.get().supertype_names[idx],
                .fqn = dg.get().first_super_fqn,
            };
        },
        else => {},
    }
    const child_fqn = dg.get().fqn;
    const child_name = dg.get().name;
    const paths = dg.get().supertype_paths;
    for (dg.get().supertype_names, 0..) |n, i| {
        const qp: ?[]const u8 = if (i < paths.len) paths[i] else null;
        const sd = if (qp) |p| (classDefByQualifiedSuffix(self, p) orelse classDefForSuper(self, child_fqn, child_name, n)) else classDefForSuper(self, child_fqn, child_name, n);
        if (sd) |s| {
            const is_iface = classDefIsInterface(s);
            const sfqn = classDefFqn(s);
            s.deinit();
            if (is_iface) continue;
            if (i <= 255) {
                const d = @constCast(dg.get());
                d.first_super_index = @intCast(i);
                d.first_super_fqn = sfqn;
                @atomicStore(u8, &d.first_super_state, 2, .release);
            }
            return .{ .name = n, .fqn = sfqn };
        }
        // NOT memoized: the runtime class table can still grow, and a
        // parent that registers later must be found by the next call.
        return .{ .name = n, .fqn = null };
    }
    // Every supertype resolved and none was a class: stable — memoize.
    @atomicStore(u8, &@constCast(dg.get()).first_super_state, 1, .release);
    return null;
}

/// Run the class's `init { … }` blocks whose source position equals
/// `before_prop_idx`. Each block takes `this` plus the class's args.
fn runInitBlocksAt(
    self: *VmHost,
    cls: ObjRef(ClassDef),
    before_prop_idx: usize,
    inst_value: *const Value,
    chain: []const ChainEntry,
    fallback_args: []const Value,
) Allocator.Error!UnitOrErr {
    const cls_name = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().name;
    };
    const cls_fqn = classDefFqn(cls);
    const fids: []const FuncId = blk: {
        const g = self.prog.borrow();
        defer g.deinit();
        break :blk g.get().init_blocks.get(sideTableKey(cls_fqn, cls_name)) orelse {
            // A runtime-registered local class has no build-time side-table
            // entry; its init blocks lowered as `$init$block$<idx>` anon
            // thunks at registration (with the enclosing scope's captured
            // cells bound). Run the ones due at this property position.
            return runAnonInitBlocksAt(self, cls, cls_name, before_prop_idx, inst_value, fallback_args);
        };
    };
    var cls_args: []const Value = fallback_args;
    for (chain) |*c| {
        if (chainEntryIs(c, cls_fqn, cls_name)) {
            cls_args = c.args;
            break;
        }
    }
    const body_len = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().body_properties.len;
    };
    for (fids, 0..) |fid, i| {
        const pos = blk: {
            const g = cls.borrow();
            defer g.deinit();
            const positions = g.get().init_block_property_positions;
            break :blk if (i < positions.len) positions[i] else std.math.maxInt(usize);
        };
        const effective = if (pos == std.math.maxInt(usize)) body_len else pos;
        if (effective != before_prop_idx) continue;
        const fr = try funcAt(self, fid, "init block");
        switch (fr) {
            .err => {},
            .ok => |f| {
                // See the body-prop-init note: an `init { }` block is class-body
                // scope too, so a lambda created inside it must snapshot the
                // instance as an enclosing receiver.
                var encl_v = inst_value.*;
                ir.eval.pushEnclosing(&encl_v);
                defer ir.eval.popEnclosing();
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(self.allocator);
                try all.append(self.allocator, inst_value.*);
                try all.appendSlice(self.allocator, cls_args);
                switch (try evalThunk(self, f, all.items)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
            },
        }
    }
    return .{ .ok = {} };
}

/// Run a runtime-registered local class's `$init$block$<idx>` anon thunks
/// whose declaration position matches `before_prop_idx`. The ClassDef's
/// `init_block_property_positions` (filled by `synthLocalClassDef`) carries
/// each block's body-property index; a block declared after every property
/// has position == body_properties.len, matching the terminal call.
/// `ctor_args` are the constructor arguments, forwarded so an `init` block can
/// read a primary-constructor PARAMETER that is not a property. The thunks
/// declare the primary params (see `lowerAndRegisterMethods`), so without the
/// arguments a bare `key` in `init { require(key.isNotEmpty()) }` fell through
/// to a field read on `this` — `Vm::get_field key on RC4Key` in kotlinx-io's
/// rawSourceSample.
pub fn runAnonInitBlocksAt(
    self: *VmHost,
    cls: ObjRef(ClassDef),
    cls_name: []const u8,
    before_prop_idx: usize,
    inst_value: *const Value,
    ctor_args: []const Value,
) Allocator.Error!UnitOrErr {
    const allocator = self.allocator;
    const n_blocks = blk: {
        const g = cls.borrow();
        defer g.deinit();
        break :blk g.get().init_block_property_positions.len;
    };
    if (n_blocks == 0) return .{ .ok = {} };
    for (0..n_blocks) |idx| {
        const pos = blk: {
            const g = cls.borrow();
            defer g.deinit();
            break :blk g.get().init_block_property_positions[idx];
        };
        if (pos != before_prop_idx) continue;
        const nm = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx});
        defer allocator.free(nm);
        const has = blk: {
            const key = try anonKey(allocator, cls_name, nm);
            defer allocator.free(key);
            const ag = self.anon_methods.borrow();
            defer ag.deinit();
            break :blk ag.get().contains(key);
        };
        if (!has) continue;
        switch (try host_call_member.callMember(self, allocator, inst_value, nm, ctor_args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .ok = {} };
}

// -------------------------------------------------------------------------
// `new_instance_named`
// -------------------------------------------------------------------------

/// `outer_hint` is the constructing frame's own `this` (when it is an
/// instance), threaded through the whole construction path down to
/// `materializeInstance` so an inner-class instance can capture it as its
/// `outer`. A call argument scoped to one construction dispatch: it cannot
/// leak across a coroutine park (no valid Kotlin suspension point exists
/// inside ctor/init/default-param evaluation), and nested shell
/// constructions see the same hint the entry call received.
pub fn newInstanceNamed(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    // KLIO_CTOR_TRAP=<fqn>: print the executing frame when this exact
    // class constructs — the instrument for a wrong-class pick whose
    // instance only fails much later.
    if (runtime.envOnce("KLIO_CTOR_TRAP")) |want| {
        const mg0 = self.module.borrow();
        const m0 = mg0.get();
        const fqn0: []const u8 = if (class.int() < m0.classes.items.len) m0.classes.items[class.int()].fqn else "";
        mg0.deinit();
        if (std.mem.eql(u8, fqn0, want)) {
            const cf0 = ir.eval.currentFrameFunc();
            std.debug.print("[ctor-trap] {s} nargs={d} in={s}\n", .{ want, args.len, if (cf0) |c| (if (c.fqn.len != 0) c.fqn else c.name) else "<none>" });
        }
    }
    // Intrinsic-backed classes route through the host ctor.
    {
        const mg = self.module.borrow();
        const m = mg.get();
        var fqn: ?[]const u8 = null;
        if (class.int() < m.classes.items.len) {
            fqn = m.classes.items[class.int()].fqn;
        }
        mg.deinit();
        if (fqn) |f| {
            if (isIntrinsicClass(f)) {
                // Unsigned arrays take the intrinsic for the array-arg
                // form too: `UIntArray(intArray)` is the storage-wrapping
                // constructor (an unsigned VIEW over the signed buffer),
                // which the source value-class instance cannot represent.
                const unsigned_wrap = std.mem.startsWith(u8, f, "kotlin.U") and std.mem.endsWith(u8, f, "Array");
                // A collection constructor takes a collection/array argument
                // legitimately (`ArrayList(this)` in `toMutableList`); routing
                // it past the intrinsic built a HOLLOW interpreted instance of
                // the expect-class shell that serves no member at all.
                const collection_ctor = std.mem.startsWith(u8, f, "kotlin.collections.");
                const first_is_array = args.len > 0 and args[0] == .Array and
                    !unsigned_wrap and !collection_ctor and !std.mem.eql(u8, f, "kotlin.String");
                if (!first_is_array) {
                    if (lookupIntrinsic(self, f)) |intrinsic| {
                        return dispatchIntrinsic(self, f, intrinsic, args);
                    }
                }
            }
        }
    }

    var any_named = false;
    for (arg_names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    if (!any_named) {
        return newInstance(self, allocator, class, args, outer_hint);
    }

    const class_name = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class.int() >= m.classes.items.len) {
            return .{ .err = try typeErr(allocator, "Vm::new_instance_named: ClassId {d} not found", .{class.int()}) };
        }
        break :blk m.classes.items[class.int()].name;
    };
    const class_fqn = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().classes.items[class.int()].fqn;
    };
    // Primary param names, off the IR class.
    var primary_names: std.ArrayList([]const u8) = .empty;
    defer primary_names.deinit(allocator);
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        for (m.classes.items[class.int()].primary_params) |p| {
            try primary_names.append(allocator, p.name);
        }
    }
    var supplied_names: std.ArrayList([]const u8) = .empty;
    defer supplied_names.deinit(allocator);
    for (arg_names) |n| {
        if (n) |nm| try supplied_names.append(allocator, nm);
    }
    // FQN first: named-argument construction must read the params of the
    // exact class the ClassId resolved, not a simple-name twin.
    const class_def = classDefByName(self, class_fqn) orelse classDefByName(self, class_name);
    defer if (class_def) |d| d.deinit();

    // Prefer the primary signature when every supplied name names a
    // primary param.
    var all_primary = true;
    for (supplied_names.items) |nm| {
        var found = false;
        for (primary_names.items) |p| {
            if (std.mem.eql(u8, p, nm)) {
                found = true;
                break;
            }
        }
        if (!found) {
            all_primary = false;
            break;
        }
    }
    if (all_primary) {
        const n = primary_names.items.len;
        var reordered = try allocator.alloc(?Value, n);
        defer allocator.free(reordered);
        for (reordered) |*slot| slot.* = null;
        // Kotlin binds a TRAILING LAMBDA to the LAST parameter, whatever gap the
        // named arguments leave in between: `B("b", n = 11) { }` against
        // `B(label, flag = …, n = …, content)` puts the block in `content` and
        // defaults `flag`. The plain positional walk below would instead drop it
        // into the first free slot (`flag`) and shift everything after it — the
        // named function path already handles this (`padArgsWithDefaults`), the
        // constructor path did not.
        const trailing_slot: ?usize = blk: {
            if (n == 0 or args.len == 0) break :blk null;
            const last = args.len - 1;
            if (arg_names[last] != null) break :blk null;
            if (!isCallableArg(&args[last])) break :blk null;
            // The last parameter must be the function-typed one, and must not
            // already be claimed by name.
            for (arg_names) |an| {
                if (an) |nm| {
                    if (std.mem.eql(u8, nm, primary_names.items[n - 1])) break :blk null;
                }
            }
            // Read the last parameter's LOWERED type off the IR class: the
            // `ClassDef` is not always reachable by name from every build path,
            // and the IR class is the same table `primary_names` came from.
            const mg2 = self.module.borrow();
            defer mg2.deinit();
            const irc = mg2.get().classes.items[class.int()];
            if (n - 1 >= irc.primary_params.len) break :blk null;
            if (!std.mem.startsWith(u8, irc.primary_params[n - 1].ty.name, "Function")) break :blk null;
            break :blk n - 1;
        };
        var next_pos: usize = 0;
        var overflow = false;
        for (args, 0..) |v, i| {
            if (trailing_slot) |ts| {
                if (i == args.len - 1) {
                    reordered[ts] = v;
                    continue;
                }
            }
            if (arg_names[i]) |nm| {
                for (primary_names.items, 0..) |p, idx| {
                    if (std.mem.eql(u8, p, nm)) {
                        reordered[idx] = v;
                        break;
                    }
                }
            } else {
                while (next_pos < n and reordered[next_pos] != null) next_pos += 1;
                if (next_pos >= n) {
                    overflow = true;
                    break;
                }
                reordered[next_pos] = v;
                next_pos += 1;
            }
        }
        var primary_satisfiable = !overflow;
        if (primary_satisfiable) {
            for (reordered, 0..) |slot, idx| {
                if (slot != null) continue;
                const has_default = blk: {
                    // The IR class is the authority: `ClassDef` is not reachable
                    // by name from every build path (it is null under the parity
                    // harness), and treating that as "no default" made a
                    // satisfiable named call fall through to the positional
                    // fallback, which scrambled the binding.
                    {
                        const mg2 = self.module.borrow();
                        defer mg2.deinit();
                        const irc = mg2.get().classes.items[class.int()];
                        if (idx < irc.primary_params.len and irc.primary_params[idx].has_default) break :blk true;
                    }
                    if (class_def) |d| {
                        const dg = d.borrow();
                        defer dg.deinit();
                        if (idx < dg.get().primary_params.len) {
                            break :blk dg.get().primary_params[idx].default != null;
                        }
                    }
                    break :blk false;
                };
                if (!has_default) {
                    primary_satisfiable = false;
                    break;
                }
            }
        }
        if (primary_satisfiable) {
            const default_thunks = primaryDefaultThunks(self, class_fqn, class_name);
            var final_args: std.ArrayList(Value) = .empty;
            defer final_args.deinit(allocator);
            for (reordered, 0..) |slot, idx| {
                if (slot) |v| {
                    try final_args.append(allocator, v);
                    continue;
                }
                var resolved: Value = .Null;
                var simple = false;
                if (class_def) |d| {
                    var dflt: ?*const ast.Expr = null;
                    {
                        const dg = d.borrow();
                        defer dg.deinit();
                        if (idx < dg.get().primary_params.len) {
                            if (dg.get().primary_params[idx].default) |ff| dflt = ff.get();
                        }
                    }
                    if (dflt) |e| {
                        if (try defaultValueForPrimary(allocator, e)) |v| {
                            resolved = v;
                            simple = true;
                        } else if (try pathConstDefault(self, e)) |v| {
                            resolved = v;
                            simple = true;
                        }
                    }
                }
                // A skipped parameter whose default is a complex expression
                // (`parameters: Parameters = Parameters.Empty`) cannot be read
                // as a literal/path constant; evaluate its default-arg thunk,
                // exactly as the positional path does, so the slot is the real
                // default rather than a spurious `null` (which a later
                // `.appendAll(null)` would hang on).
                if (!simple and default_thunks != null and idx < default_thunks.?.len) {
                    if (default_thunks.?[idx]) |dfid| {
                        const fr = try funcAt(self, dfid, "primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                const tslot: Value = if (class_def) |d| ctorThunkThisSlot(d, outer_hint) else .Null;
                                try thunk_args.append(allocator, tslot); // `this`
                                try thunk_args.appendSlice(allocator, final_args.items);
                                while (thunk_args.items.len < primary_names.items.len + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| resolved = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
                try final_args.append(allocator, resolved);
            }
            return newInstance(self, allocator, class, final_args.items, outer_hint);
        }
    }

    // A named arg names a secondary-constructor parameter.
    const entries = secondaryCtors(self, class_fqn, class_name);
    var chosen: ?root.build.SecondaryCtorEntry = null;
    for (entries) |e| {
        if (e.param_count < args.len) continue;
        var all_named_match = true;
        for (supplied_names.items) |nm| {
            var found = false;
            for (e.param_names) |p| {
                if (std.mem.eql(u8, p, nm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_named_match = false;
                break;
            }
        }
        if (all_named_match) {
            chosen = e;
            break;
        }
    }
    if (chosen) |entry| {
        var slots = try allocator.alloc(?Value, entry.param_count);
        defer allocator.free(slots);
        for (slots) |*s| s.* = null;
        var next_pos: usize = 0;
        for (args, 0..) |v, i| {
            if (arg_names[i]) |nm| {
                for (entry.param_names, 0..) |p, idx| {
                    if (std.mem.eql(u8, p, nm)) {
                        slots[idx] = v;
                        break;
                    }
                }
            } else {
                while (next_pos < slots.len and slots[next_pos] != null) next_pos += 1;
                if (next_pos < slots.len) {
                    slots[next_pos] = v;
                    next_pos += 1;
                }
            }
        }
        var full: std.ArrayList(Value) = .empty;
        defer full.deinit(allocator);
        for (slots, 0..) |slot, idx| {
            if (slot) |v| {
                try full.append(allocator, v);
                continue;
            }
            if (idx < entry.default_arg_thunks.len) {
                if (entry.default_arg_thunks[idx]) |dfid| {
                    const fr = try funcAt(self, dfid, "secondary ctor default");
                    switch (fr) {
                        .err => |e| return .{ .err = e },
                        .ok => |func| {
                            var targs: std.ArrayList(Value) = .empty;
                            defer targs.deinit(allocator);
                            try targs.appendSlice(allocator, full.items);
                            while (targs.items.len < entry.param_count) {
                                try targs.append(allocator, .Null);
                            }
                            switch (try evalThunk(self, func, targs.items)) {
                                .ok => |v| try full.append(allocator, v),
                                .err => |e| return .{ .err = e },
                            }
                        },
                    }
                    continue;
                }
            }
            try full.append(allocator, .Null);
        }
        return newInstance(self, allocator, class, full.items, outer_hint);
    }
    // A named-arg call to a same-named top-level FACTORY function (a class or
    // interface with a factory, e.g. kotlinx `MutableSharedFlow(replay=…,
    // extraBufferCapacity=…)`): reorder against the factory's own parameters.
    // The positional `newInstance` below would bind the named args by position
    // and mis-score the factory — or, for an interface, fail to instantiate.
    if (findNamedFactory(self, class_name, arg_names)) |fid| {
        const mg = self.module.borrow();
        defer mg.deinit();
        return self.callFuncNamed(allocator, mg.get(), fid, args, arg_names);
    }
    return newInstance(self, allocator, class, args, outer_hint);
}

/// A same-named top-level factory function whose parameters include every
/// supplied argument name, so a named-arg `Foo(name = v)` call can target the
/// factory `fun Foo(name: T = …)` rather than a constructor. Excludes instance
/// methods / extensions (a leading `this` receiver) and bodyless declarations.
fn findNamedFactory(self: *VmHost, class_name: []const u8, arg_names: []const ?[]const u8) ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const m = mg.get();
    for (m.funcsBySimpleName(class_name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        var all_match = true;
        for (arg_names) |an| {
            const nm = an orelse continue;
            var found = false;
            for (f.params) |p| {
                if (std.mem.eql(u8, p.name, nm)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                all_match = false;
                break;
            }
        }
        if (all_match) return fid;
    }
    return null;
}

fn isIntrinsicClass(fqn: []const u8) bool {
    const names = [_][]const u8{
        "kotlin.text.StringBuilder",        "kotlin.text.Regex",
        "kotlin.collections.HashMap",       "kotlin.collections.HashSet",
        "kotlin.collections.LinkedHashMap", "kotlin.collections.LinkedHashSet",
        "kotlin.collections.ArrayList",     "kotlin.IntArray",
        "kotlin.LongArray",                 "kotlin.ShortArray",
        "kotlin.ByteArray",                 "kotlin.FloatArray",
        "kotlin.DoubleArray",               "kotlin.BooleanArray",
        "kotlin.CharArray",                 "kotlin.UIntArray",
        "kotlin.ULongArray",                "kotlin.UShortArray",
        "kotlin.UByteArray",                "kotlin.Array",
        "kotlin.String",                    "kotlin.UByte",
        "kotlin.UShort",                    "kotlin.UInt",
        "kotlin.ULong",
    };
    for (names) |n| {
        if (std.mem.eql(u8, fqn, n)) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// `new_instance`
// -------------------------------------------------------------------------

pub fn newInstance(self: *VmHost, allocator: Allocator, class: ClassId, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    // IR class name / fqn (off the frozen module).
    var ir_name: []const u8 = undefined;
    var ir_fqn: []const u8 = undefined;
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (class.int() >= m.classes.items.len) {
            return .{ .err = try typeErr(allocator, "Vm::new_instance: ClassId {d} not found in module", .{class.int()}) };
        }
        ir_name = m.classes.items[class.int()].name;
        ir_fqn = m.classes.items[class.int()].fqn;
    }
    // Builtin Throwable hierarchy: host-backed via the intrinsic.
    if (root.isBuiltinThrowableFqn(ir_fqn)) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            // fillInStackTrace at construction: a builtin throwable
            // (`RuntimeException(msg)`) captures the stack when constructed.
            var r = try dispatchIntrinsic(self, ir_fqn, intrinsic, args);
            if (r == .ok) try ir.eval.attachStackTrace(allocator, &r.ok);
            return r;
        }
    }
    // Builtin tuple classes (`kotlin.Pair` / `kotlin.Triple`) have a
    // distinct runtime `Value` representation and an intrinsic
    // constructor; route construction there so the result is a
    // `Value.Pair` / `Value.Triple` rather than a generic data-class
    // Instance (which would print as `Pair(first=…, second=…)`).
    if (std.mem.eql(u8, ir_fqn, "kotlin.Pair") or std.mem.eql(u8, ir_fqn, "kotlin.Triple")) {
        if (lookupIntrinsic(self, ir_fqn)) |intrinsic| {
            return dispatchIntrinsic(self, ir_fqn, intrinsic, args);
        }
    }

    // The lowering-resolved ClassId carries the exact identity; resolve
    // the runtime ClassDef by FQN (the table's authoritative key) so a
    // same-simple-name class from another package can never swap in. The
    // simple-name view remains the fallback for synthesized classes that
    // only register under their simple name.
    var class_def = classDefByName(self, ir_fqn) orelse classDefByName(self, ir_name) orelse {
        return .{ .err = .{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::new_instance: no runtime ClassDef registered for `{s}`", .{ir_name}) } };
    };
    defer class_def.deinit();

    if (classDefIsAbstract(class_def)) {
        return throwInstantiation(self, allocator, "Cannot create an instance of an abstract class: {s}", classDefName(class_def));
    }
    if (classDefIsInterface(class_def)) {
        return try interfaceConstruct(self, allocator, class_def, args);
    }

    const class_name = classDefName(class_def);
    const n_primary_initial = classDefPrimaryParamCount(class_def);

    // Kotlin initializes a class's companion at the first instantiation of
    // the class (when not already initialized by direct access), the
    // class's own companion before its ancestors' — kotlinc order. An init
    // failure aborts the instantiation at this access site.
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            const cname = classDefName(c);
            const comp_name: ?[]const u8 = blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk mg.get().registry.companion_singletons.get(cname);
            };
            if (comp_name) |cn| {
                switch (try host_globals.ensureObjectSingleton(self, cn)) {
                    .ok => {},
                    .err => |e| {
                        c.deinit();
                        return .{ .err = e };
                    },
                }
            }
            const next: ?ObjRef(ClassDef) = blk: {
                const g = c.borrow();
                defer g.deinit();
                break :blk if (g.get().parent) |pp| pp.clone() else null;
            };
            c.deinit();
            cur = next;
        }
    }

    // Secondary-ctor dispatch. The construction site's static argument heads
    // are consumed here and re-installed only across the two ranking regions
    // below, so nothing evaluated underneath (a delegation, a default) ranks
    // against this site's types.
    // Snapshot the taken heads into this frame: a construction underneath (a
    // delegation argument, a default) rewrites the thread's buffer.
    var site_heads_buf: [CTOR_HEADS_MAX]?[]const u8 = undefined;
    const site_heads: ?[]const ?[]const u8 = if (takeCtorStaticHeads()) |sh| blk: {
        @memcpy(site_heads_buf[0..sh.len], sh);
        break :blk site_heads_buf[0..sh.len];
    } else null;
    ctor_static_heads = site_heads;
    defer ctor_static_heads = null;
    const zero_primary_secondary = n_primary_initial == 0 and blk: {
        for (secondaryCtors(self, classDefFqn(class_def), class_name)) |e| {
            if (e.param_count == args.len) break :blk true;
        }
        break :blk false;
    };
    // A same-arity primary/secondary pair selects by TYPE, like any other
    // overload set: when the best-fitting secondary scores strictly better
    // than the primary's declared heads (a lambda meeting the secondary's
    // FunctionN slot vs the primary's SAM-class slot —
    // `SuspendingPointerInputModifierNodeImpl`'s deprecated-handler ctor),
    // the secondary takes the call.
    const same_arity_secondary_better = args.len == n_primary_initial and n_primary_initial != 0 and blk: {
        var best_sec: i32 = -1;
        for (secondaryCtors(self, classDefFqn(class_def), class_name)) |e| {
            if (e.param_count != args.len) continue;
            if (scoreCtorHeads(self, e.param_type_heads, args)) |sc| {
                if (sc > best_sec) best_sec = sc;
            }
        }
        if (best_sec < 0) break :blk false;
        const prim_score = blk2: {
            var heads: std.ArrayList([]const u8) = .empty;
            defer heads.deinit(allocator);
            const dg = class_def.borrow();
            defer dg.deinit();
            for (dg.get().primary_params) |*p| {
                heads.append(allocator, p.declared_type orelse "") catch break :blk2 @as(?i32, 0);
            }
            break :blk2 scoreCtorHeads(self, heads.items, args);
        };
        const prim = prim_score orelse break :blk true;
        break :blk best_sec > prim;
    };
    const shell_guarded = ctorGuardContains(class_name);
    if (!shell_guarded and (args.len != n_primary_initial or zero_primary_secondary or same_arity_secondary_better)) {
        ctor_static_heads = site_heads;
        if (try dispatchSecondaryCtor(self, allocator, class, class_def, args, outer_hint)) |res| {
            return res;
        }
    }

    // Primary-ctor path.
    return primaryCtorPath(self, allocator, class_def, ir_name, args, outer_hint);
}

// --- ClassDef accessors (each takes a borrowed handle) ---

fn classDefName(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().name;
}

fn classDefFqn(d: ObjRef(ClassDef)) []const u8 {
    const g = d.borrow();
    defer g.deinit();
    return g.get().fqn;
}

fn classDefIsAbstract(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_abstract;
}

fn classDefIsInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_interface;
}

fn classDefIsObject(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_object;
}

fn classDefIsInner(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_inner;
}

/// Wrap a callable into an instance of the `fun interface` named by a
/// parameter's declared type — Kotlin's SAM conversion, which happens at the
/// call boundary, so the value the callee sees IS an instance of the
/// interface. The caller's reference MOVES into the wrapper (the argument slot
/// it came from is overwritten with the wrapper), so nothing is retained here.
///
/// Null when no conversion applies: not a callable, a `Function` slot, a type
/// parameter, or a name that is not a `fun interface`.
pub fn samWrapForParamType(self: *VmHost, allocator: Allocator, v: *const Value, ty_name: []const u8) Allocator.Error!?Value {
    if (v.* != .IrClosure) return null;
    if (ty_name.len <= 2 or std.mem.startsWith(u8, ty_name, "Function")) return null;
    const bare = std.mem.trimEnd(u8, ty_name, "?");
    const simple = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, bare, '.') orelse break :blk bare;
        break :blk bare[dot + 1 ..];
    };
    const pd = classDefByName(self, simple) orelse return null;
    defer pd.deinit();
    if (!classDefIsFunInterface(pd)) return null;
    if (runtime.envOnce("KLIO_SAM_WRAP_TRACE") != null) {
        std.debug.print("[sam-wrap] ty={s} simple={s}\n", .{ ty_name, simple });
    }
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(allocator, .{ .name = "__sam_target__", .value = v.* });
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = pd.clone(),
        .fields = fields,
        .outer = null,
        .identity = nextInstanceId(self),
        .native_state = null,
    });
    return .{ .Instance = inst };
}

/// Whether `ty_name` names a `fun interface`, for the per-func mask below.
pub fn paramTypeIsFunInterface(self: *VmHost, ty_name: []const u8) bool {
    if (ty_name.len <= 2 or std.mem.startsWith(u8, ty_name, "Function")) return false;
    const bare = std.mem.trimEnd(u8, ty_name, "?");
    const simple = blk: {
        const dot = std.mem.lastIndexOfScalar(u8, bare, '.') orelse break :blk bare;
        break :blk bare[dot + 1 ..];
    };
    const pd = classDefByName(self, simple) orelse return false;
    defer pd.deinit();
    return classDefIsFunInterface(pd);
}

fn classDefIsFunInterface(d: ObjRef(ClassDef)) bool {
    const g = d.borrow();
    defer g.deinit();
    return g.get().is_fun_interface;
}

fn classDefPrimaryParamCount(d: ObjRef(ClassDef)) usize {
    const g = d.borrow();
    defer g.deinit();
    return g.get().primary_params.len;
}

fn throwInstantiation(self: *VmHost, allocator: Allocator, comptime fmt: []const u8, name: []const u8) Allocator.Error!EvalResult {
    _ = self;
    const msg = try std.fmt.allocPrint(allocator, fmt, .{name});
    return .{ .err = .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInitOwned(allocator, try allocator.dupe(u8, "kotlin.InstantiationError")),
        .message = .from(try runtime.strInitOwned(allocator, msg)),
        .cause = null,
    }) } };
}

/// Interface "construction": `List(size){init}`, SAM conversion, or a
/// same-named factory function.
fn interfaceConstruct(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), args: []const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // `List(size){init}` / `MutableList(size){init}`.
    if ((std.mem.eql(u8, class_name, "List") or std.mem.eql(u8, class_name, "MutableList")) and args.len == 2) {
        if (args[0].asI64()) |size| {
            const init = args[1];
            var items: std.ArrayList(Value) = .empty;
            errdefer items.deinit(allocator);
            var i: i64 = 0;
            while (i < size) : (i += 1) {
                const idx = Value.newInt(i);
                switch (try self.callValue(allocator, &init, &.{idx})) {
                    .ok => |v| try items.append(allocator, v),
                    .err => |e| return .{ .err = e },
                }
            }
            return .{ .ok = try Value.newList(allocator, .{
                .items = try ObjRef(std.ArrayList(Value)).init(allocator, items),
                .mutable = std.mem.eql(u8, class_name, "MutableList"),
                .enum_entries = false,
                .backing = null,
            }) };
        }
    }
    // SAM conversion: `FunInterface(lambda)`.
    if (classDefIsFunInterface(class_def) and args.len == 1) {
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        // The SAM instance owns one ref to its target; `args[0]` is a borrow.
        if (runtime.reclaimEnabled()) args[0].retain();
        try fields.append(allocator, .{ .name = "__sam_target__", .value = args[0] });
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = class_def.clone(),
            .fields = fields,
            .outer = null,
            .identity = identity,
            .native_state = null,
        });
        return .{ .ok = .{ .Instance = inst } };
    }
    // Same-named factory function.
    if (try pickFactory(self, allocator, class_name, args)) |fid| {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const mg = module_ref.borrow();
        defer mg.deinit();
        return self.callFunc(allocator, mg.get(), fid, args);
    }
    {
        const module_ref = self.module.clone();
        defer module_ref.deinit();
        const mg = module_ref.borrow();
        defer mg.deinit();
        const m = mg.get();
        if (runtime.envOnce("KLIO_NU_TRACE") != null) {
            std.debug.print("[ifact] {s} nargs={d} cands={d} tags:", .{ class_name, args.len, m.funcsBySimpleName(class_name).len });
            for (args) |*av| std.debug.print(" {s}", .{@tagName(av.*)});
            std.debug.print("\n", .{});
            for (m.funcsBySimpleName(class_name)) |fid2| {
                const f2 = m.funcById(fid2) orelse continue;
                std.debug.print("[ifact] fid={d} body={} np={d} p0={s} def1={}\n", .{ fid2.int(), f2.hasBody(), f2.params.len, if (f2.params.len > 0) f2.params[0].name else "-", funcParamHasDefault(self, fid2, 1) });
            }
        }
    }
    return throwInstantiation(self, allocator, "Cannot create an instance of an interface: {s}", class_name);
}

fn isAllUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

fn funcParamHasDefault(self: *VmHost, fid: FuncId, idx: usize) bool {
    const g = self.prog.borrow();
    defer g.deinit();
    if (g.get().func_defaults.get(fid.int())) |slots| {
        if (idx < slots.len) {
            return slots[idx] != null;
        }
    }
    return false;
}

/// Returns the constructed instance value, or `null` to fall through to
/// the primary-ctor path.
fn dispatchSecondaryCtor(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), args: []const Value, outer_hint: ?*const Value) Allocator.Error!?EvalResult {
    const ctor_keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ctor_keepalive);
    runtime.keepalivePushSlice(args);
    const class_name = classDefName(class_def);
    const entries = secondaryCtors(self, classDefFqn(class_def), class_name);
    var chosen: ?root.build.SecondaryCtorEntry = chooseSecondaryCtor(self, entries, args);
    // Everything below constructs further values; the site's static heads
    // describe THIS call's arguments only.
    ctor_static_heads = null;
    if (chosen == null) {
        for (entries) |e| {
            // A hidden binary-compat constructor must not swallow an
            // under-applied call the PRIMARY constructor serves:
            // `KeyboardOptions()` was picking the hidden
            // `constructor(autoCorrect: Boolean = Default.autoCorrectOrDefault, …)`
            // over the primary, and then evaluating its default expressions.
            if (e.low_priority) continue;
            if (e.param_count > args.len) {
                var all_default = true;
                var idx = args.len;
                while (idx < e.default_arg_thunks.len) : (idx += 1) {
                    if (e.default_arg_thunks[idx] == null) {
                        all_default = false;
                        break;
                    }
                }
                if (!all_default) continue;
                // The provided args must type-match this larger candidate's
                // params (same subtype guard as chooseSecondaryCtor), so the
                // fallback does not bind a class value to a mismatched slot and
                // re-select the wrong ctor a `this(...)` delegation should skip.
                var typ_ok = true;
                var j: usize = 0;
                while (j < args.len and j < e.param_type_heads.len) : (j += 1) {
                    if (!paramAcceptsArg(self, e.param_type_heads[j], &args[j])) {
                        typ_ok = false;
                        break;
                    }
                }
                if (!typ_ok) continue;
                chosen = e;
                break;
            }
        }
    }
    const entry = chosen orelse return null;

    // Materialize the full positional argument list, filling trailing
    // params the caller omitted from their default thunks.
    var full_args: std.ArrayList(Value) = .empty;
    defer full_args.deinit(allocator);
    try full_args.appendSlice(allocator, args);
    {
        var idx = args.len;
        while (idx < entry.param_count) : (idx += 1) {
            if (idx >= entry.default_arg_thunks.len or entry.default_arg_thunks[idx] == null) {
                return EvalResult{ .err = try typeErr(allocator, "secondary ctor param {d} has no default to apply", .{idx}) };
            }
            const dfid = entry.default_arg_thunks[idx].?;
            const fr = try funcAt(self, dfid, "secondary ctor default");
            switch (fr) {
                .err => |e| return EvalResult{ .err = e },
                .ok => |func| {
                    var thunk_args: std.ArrayList(Value) = .empty;
                    defer thunk_args.deinit(allocator);
                    try thunk_args.appendSlice(allocator, full_args.items);
                    while (thunk_args.items.len < entry.param_count) {
                        try thunk_args.append(allocator, .Null);
                    }
                    const full_keepalive = runtime.keepaliveMark();
                    runtime.keepalivePushSlice(full_args.items);
                    const evaluated = evalThunk(self, func, thunk_args.items);
                    runtime.keepaliveRestore(full_keepalive);
                    switch (try evaluated) {
                        .ok => |v| try full_args.append(allocator, v),
                        .err => |e| return EvalResult{ .err = e },
                    }
                },
            }
        }
    }
    runtime.keepalivePushSlice(full_args.items);

    // Evaluate the delegation args.
    var target_args: std.ArrayList(Value) = .empty;
    defer target_args.deinit(allocator);
    for (entry.delegation_arg_thunks) |fid| {
        const fr = try funcAt(self, fid, "secondary ctor arg");
        switch (fr) {
            .err => |e| return EvalResult{ .err = e },
            .ok => |func| {
                const target_keepalive = runtime.keepaliveMark();
                runtime.keepalivePushSlice(target_args.items);
                const evaluated = evalThunk(self, func, full_args.items);
                runtime.keepaliveRestore(target_keepalive);
                switch (try evaluated) {
                    .ok => |v| try target_args.append(allocator, v),
                    .err => |e| return EvalResult{ .err = e },
                }
            },
        }
    }
    runtime.keepalivePushSlice(target_args.items);

    var inst_v: Value = undefined;
    if (entry.is_super) {
        switch (try superDelegation(self, allocator, class, class_def, target_args.items, outer_hint)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else if (entry.is_this) {
        switch (try newInstance(self, allocator, class, target_args.items, outer_hint)) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    } else {
        // Implicit `super()`.
        ctorGuardPush(class_name);
        const shell = try newInstance(self, allocator, class, &.{}, outer_hint);
        ctorGuardPop();
        switch (shell) {
            .ok => |v| inst_v = v,
            .err => |e| return EvalResult{ .err = e },
        }
    }
    runtime.keepalivePush(inst_v);

    // Body block.
    if (entry.body) |body_fid| {
        const fr = try funcAt(self, body_fid, "secondary ctor body");
        switch (fr) {
            .err => {},
            .ok => |body_func| {
                var all: std.ArrayList(Value) = .empty;
                defer all.deinit(allocator);
                try all.append(allocator, inst_v);
                try all.appendSlice(allocator, full_args.items);
                switch (try evalThunk(self, body_func, all.items)) {
                    .ok => {},
                    .err => |e| return EvalResult{ .err = e },
                }
            },
        }
    }
    return EvalResult{ .ok = inst_v };
}

/// The `: super(...)` arm. Returns the constructed leaf instance, or an
/// error (including `Unimplemented` when no parent class def exists for a
/// non-Throwable parent).
fn superDelegation(self: *VmHost, allocator: Allocator, class: ClassId, class_def: ObjRef(ClassDef), target_args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    // Resolve the parent def: prefer the resolved `parent`, else the
    // first supertype name.
    var parent_def: ?ObjRef(ClassDef) = null;
    {
        const dg = class_def.borrow();
        if (dg.get().parent) |p| parent_def = p.clone();
        if (parent_def == null) {
            if (dg.get().supertype_names.len > 0) {
                parent_def = classDefByName(self, dg.get().supertype_names[0]);
            }
        }
        dg.deinit();
    }
    defer if (parent_def) |p| p.deinit();

    if (parent_def) |pdef| {
        const pname = classDefName(pdef);
        // The labels of this class's super-constructor call apply to the
        // parent's parameters, so a named argument binds by parameter name.
        const cur_names = parentCtorArgNames(self, classDefFqn(class_def), class_name);
        ctorGuardPush(class_name);
        const leaf_res = try newInstance(self, allocator, class, &.{}, outer_hint);
        ctorGuardPop();
        const leaf = switch (leaf_res) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        if (leaf == .Instance) {
            const g = leaf.Instance.borrowMut();
            const inst = g.get();
            const pg = pdef.borrow();
            const pp = pg.get().primary_params;
            var k: usize = 0;
            while (k < target_args.len) : (k += 1) {
                const target: usize =
                    if (cur_names) |names|
                        (if (k < names.len) (if (names[k]) |nm| (paramIndexByName(pp, nm) orelse k) else k) else k)
                    else
                        k;
                if (target >= pp.len) continue;
                if (pp[target].property != null) {
                    retainField(inst, allocator, pp[target].name);
                    try pushField(inst, allocator, pp[target].name, target_args[k]);
                }
            }
            pg.deinit();
            g.deinit();
        }
        switch (try runSuperCtorChain(self, &leaf, classDefFqn(pdef), pname, target_args, cur_names, outer_hint)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
        return .{ .ok = leaf };
    }

    // No user ClassDef for the parent — a builtin (Throwable hierarchy).
    var parent_name: []const u8 = "";
    {
        const dg = class_def.borrow();
        if (dg.get().supertype_names.len > 0) parent_name = dg.get().supertype_names[0];
        dg.deinit();
    }
    const is_throwable_name = isBuiltinThrowableNameNoCancel(parent_name);
    if (!is_throwable_name) {
        return .{ .err = .{ .Unimplemented = try std.fmt.allocPrint(allocator, "Vm::new_instance: secondary ctor super-delegation for `{s}` (no parent class def)", .{class_name}) } };
    }
    const leaf_res = try newInstance(self, allocator, class, &.{}, outer_hint);
    const leaf = switch (leaf_res) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (leaf == .Instance) {
        try bindThrowableArgs(self, leaf.Instance, target_args, false);
    }
    return .{ .ok = leaf };
}

fn isBuiltinThrowableNameNoCancel(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IOException",                     "EOFException",
        "IllegalArgumentException",        "IllegalStateException",
        "IndexOutOfBoundsException",       "NullPointerException",
        "ClassCastException",              "ArithmeticException",
        "NumberFormatException",           "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn primaryCtorPath(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args_in: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const n_primary = classDefPrimaryParamCount(class_def);

    var effective: std.ArrayList(Value) = .empty;
    defer effective.deinit(allocator);
    try effective.appendSlice(allocator, args_in);

    // Pack trailing positional args into the primary ctor's vararg slot.
    {
        const owned = try allocator.dupe(Value, effective.items);
        const packed_args = try packPrimaryCtorVarargs(self, classDefFqn(class_def), class_name, owned);
        effective.clearRetainingCapacity();
        try effective.appendSlice(allocator, packed_args);
        allocator.free(packed_args);
    }

    // Same-named factory wins when the ctor definitely cannot take args.
    {
        const provided = effective.items.len;
        var ctor_unsatisfiable = provided > n_primary;
        if (!ctor_unsatisfiable) {
            var idx = provided;
            while (idx < n_primary) : (idx += 1) {
                const dg = class_def.borrow();
                const no_default = idx < dg.get().primary_params.len and dg.get().primary_params[idx].default == null;
                dg.deinit();
                if (no_default) {
                    ctor_unsatisfiable = true;
                    break;
                }
            }
        }
        if (!ctor_unsatisfiable) {
            for (effective.items, 0..) |a, i| {
                const declared: ?[]const u8 = blk: {
                    const dg = class_def.borrow();
                    defer dg.deinit();
                    if (i < dg.get().primary_params.len) break :blk dg.get().primary_params[i].declared_type;
                    break :blk null;
                };
                if (declared) |t| {
                    const ty = TypeRef{ .name = t, .nullable = true, .args = &.{} };
                    if (host_call_func.runtimeParamPoints(self, &ty, &a) == null) {
                        ctor_unsatisfiable = true;
                        break;
                    }
                }
            }
        }
        if (ctor_unsatisfiable) {
            // The primary ctor cannot take these argument TYPES, but a
            // secondary ctor might: `LocalDate(Int, Month, Int)` matches the
            // secondary `(year, month: Month, day)`, not the primary
            // `(year, monthNumber: Int, day)`. Dispatch the secondary BEFORE
            // falling to a same-named factory function — a deprecated
            // `@LowPriorityInOverloadResolution fun Name(...) = Name(...)`
            // factory would otherwise self-recurse without bound.
            if (!ctorGuardContains(class_name)) {
                const cid: ?ClassId = blk: {
                    const mg = self.module.borrow();
                    defer mg.deinit();
                    break :blk mg.get().classIdByFqn(classDefFqn(class_def));
                };
                if (cid) |c| {
                    if (try dispatchSecondaryCtor(self, allocator, c, class_def, effective.items, outer_hint)) |res| return res;
                }
            }
            if (try pickFactory(self, allocator, class_name, effective.items)) |fid| {
                const module_ref = self.module.clone();
                defer module_ref.deinit();
                const mg = module_ref.borrow();
                defer mg.deinit();
                return self.callFunc(allocator, mg.get(), fid, effective.items);
            }
        }
    }

    // Fill omitted trailing params from default thunks.
    if (effective.items.len < n_primary) {
        const default_thunks = primaryDefaultThunks(self, classDefFqn(class_def), class_name);
        var idx = effective.items.len;
        while (idx < n_primary) : (idx += 1) {
            var dflt_expr: ?*const ast.Expr = null;
            {
                const dg = class_def.borrow();
                defer dg.deinit();
                if (idx < dg.get().primary_params.len) {
                    if (dg.get().primary_params[idx].default) |ff| dflt_expr = ff.get();
                }
            }
            var v: Value = .Null;
            var resolved = false;
            if (dflt_expr) |e| {
                if (try defaultValueForPrimary(allocator, e)) |lv| {
                    v = lv;
                    resolved = true;
                } else if (try pathConstDefault(self, e)) |lv| {
                    v = lv;
                    resolved = true;
                }
            }
            if (!resolved) {
                if (default_thunks) |slots| {
                    if (idx < slots.len) {
                        if (slots[idx]) |dfid| {
                            const fr = try funcAt(self, dfid, "primary ctor default");
                            switch (fr) {
                                .err => {},
                                .ok => |func| {
                                    var thunk_args: std.ArrayList(Value) = .empty;
                                    defer thunk_args.deinit(allocator);
                                    try thunk_args.append(allocator, ctorThunkThisSlot(class_def, outer_hint)); // `this`
                                    try thunk_args.appendSlice(allocator, effective.items);
                                    while (thunk_args.items.len < n_primary + 1) {
                                        try thunk_args.append(allocator, .Null);
                                    }
                                    switch (try evalThunk(self, func, thunk_args.items)) {
                                        .ok => |rv| v = rv,
                                        .err => |e| return .{ .err = e },
                                    }
                                },
                            }
                        }
                    }
                }
            }
            try effective.append(allocator, v);
        }
    }

    if (effective.items.len != n_primary) {
        // Same-named factory with matching arity.
        if (try pickFactory(self, allocator, class_name, effective.items)) |fid| {
            const module_ref = self.module.clone();
            defer module_ref.deinit();
            const mg = module_ref.borrow();
            defer mg.deinit();
            return self.callFunc(allocator, mg.get(), fid, effective.items);
        }
        // Compose ABI completion: a same-named COMPOSABLE factory (a
        // file-private `@Composable fun Stack(...)` shadowed by a pack's
        // internal `class Stack`) carries the pass-appended ($composer,
        // $changed) pair the ctor-shaped call site never wrote. With a
        // composer ambient, complete the pair and re-pick.
        {
            if (@import("compose.zig").currentComposer()) |c| {
                var ext: std.ArrayList(Value) = .empty;
                defer ext.deinit(allocator);
                try ext.appendSlice(allocator, effective.items);
                try ext.append(allocator, c);
                try ext.append(allocator, .{ .Int = 0 });
                if (try pickFactory(self, allocator, class_name, ext.items)) |fid| {
                    const module_ref = self.module.clone();
                    defer module_ref.deinit();
                    const mg = module_ref.borrow();
                    defer mg.deinit();
                    return self.callFunc(allocator, mg.get(), fid, ext.items);
                }
            }
        }
        // A same-named member EXTENSION on an enclosing implicit receiver is
        // Kotlin's target when the ctor shape does not fit: `validate {
        // Stack(h) { ... } }` calls the file's `MockViewValidator.Stack`,
        // never the pack's internal `class Stack` constructor.
        {
            const encl = ir.eval.enclosingEntriesAlloc(allocator) catch &.{};
            defer allocator.free(@constCast(encl));
            for (encl) |e| {
                if (e.v != .Instance) continue;
                const r = try host_call_member.callMember(self, allocator, &e.v, class_name, effective.items);
                if (!(r == .err and r.err == .Unimplemented)) return r;
                if (r.err == .Unimplemented) {
                    const m3 = r.err.Unimplemented;
                    if (std.mem.indexOf(u8, m3, "Vm::call_member") != null and runtime.freeScratch()) {
                        allocator.free(m3);
                    }
                }
            }
        }
        if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
            std.debug.print("[ctor-arity-miss] class={s} fqn={s} n_primary={d} got={d}\n", .{ class_name, classDefFqn(class_def), n_primary, effective.items.len });
            ir.eval.dumpFrameChainForDiagAlways();
        }
        return .{ .err = try typeErr(allocator, "{s}() expects {d} args, got {d}", .{ class_name, n_primary, effective.items.len }) };
    }

    // Implicit SAM conversion at the constructor boundary: a raw callable
    // bound to a parameter whose declared type is a fun interface wraps
    // into a SAM instance, exactly as the explicit `Iface { … }` form
    // does. The wrapped value is what dispatch relies on for the
    // interface's method identity — a receiver-typed single method
    // (`PointerInputEventHandler`'s `PointerInputScope.invoke()`) can
    // only bind its extension receiver through the instance's class.
    for (effective.items, 0..) |a, i| {
        if (a != .IrClosure) continue;
        const declared: ?[]const u8 = blk: {
            const dg = class_def.borrow();
            defer dg.deinit();
            if (i < dg.get().primary_params.len) break :blk dg.get().primary_params[i].declared_type;
            break :blk null;
        };
        const dt = declared orelse continue;
        if (dt.len == 0 or std.mem.startsWith(u8, dt, "Function")) continue;
        const pd = classDefByName(self, dt) orelse continue;
        defer pd.deinit();
        if (!classDefIsFunInterface(pd)) continue;
        const identity = nextInstanceId(self);
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        if (runtime.reclaimEnabled()) a.retain();
        try fields.append(allocator, .{ .name = "__sam_target__", .value = a });
        const inst = try ObjRef(InstanceData).init(allocator, .{
            .class = pd.clone(),
            .fields = fields,
            .outer = null,
            .identity = identity,
            .native_state = null,
        });
        effective.items[i] = .{ .Instance = inst };
    }

    return materializeInstance(self, allocator, class_def, ir_name, effective.items, outer_hint);
}

/// Reorder a named super-constructor call's arguments (`: Base(objects = 2)`)
/// into the parent's declared parameter order. `arg_names[k]`, when non-null,
/// names the base parameter argument `k` binds to; unnamed arguments keep
/// their position. Gaps opened by named binding are filled with the
/// parameter default so the downstream positional field-binding is correct.
/// No-op when nothing is named. `args` is rewritten in place to length
/// `n_primary`.
fn reorderNamedSuperArgs(
    self: *VmHost,
    allocator: Allocator,
    parent_def: ObjRef(ClassDef),
    fqn: ?[]const u8,
    name: []const u8,
    arg_names: ?[]const ?[]const u8,
    args: *std.ArrayList(Value),
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    const names = arg_names orelse return .{ .ok = {} };
    var any_named = false;
    for (names) |n| {
        if (n != null) {
            any_named = true;
            break;
        }
    }
    if (!any_named) return .{ .ok = {} };
    const n_primary = classDefPrimaryParamCount(parent_def);
    if (n_primary == 0) return .{ .ok = {} };

    var ordered = try allocator.alloc(?Value, n_primary);
    defer allocator.free(ordered);
    for (ordered) |*o| o.* = null;
    for (args.items, 0..) |v, k| {
        var target = k;
        if (k < names.len) {
            if (names[k]) |nm| {
                const dg = parent_def.borrow();
                if (paramIndexByName(dg.get().primary_params, nm)) |ti| target = ti;
                dg.deinit();
            }
        }
        if (target < n_primary) ordered[target] = v;
    }

    const default_thunks = primaryDefaultThunks(self, fqn, name);
    var filled: std.ArrayList(Value) = .empty;
    errdefer filled.deinit(allocator);
    var i: usize = 0;
    while (i < n_primary) : (i += 1) {
        if (ordered[i]) |v| {
            try filled.append(allocator, v);
            continue;
        }
        var dflt_expr: ?*const ast.Expr = null;
        {
            const dg = parent_def.borrow();
            defer dg.deinit();
            if (i < dg.get().primary_params.len) {
                if (dg.get().primary_params[i].default) |ff| dflt_expr = ff.get();
            }
        }
        var v: Value = .Null;
        if (dflt_expr) |de| {
            if (try defaultValueForPrimary(allocator, de)) |lv| {
                v = lv;
            } else if (try pathConstDefault(self, de)) |lv| {
                v = lv;
            } else if (default_thunks) |slots| {
                if (i < slots.len) {
                    if (slots[i]) |dfid| {
                        const fr = try funcAt(self, dfid, "parent primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                try thunk_args.append(allocator, ctorThunkThisSlot(parent_def, outer_hint));
                                try thunk_args.appendSlice(allocator, filled.items);
                                while (thunk_args.items.len < n_primary + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| v = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
        try filled.append(allocator, v);
    }

    args.clearRetainingCapacity();
    try args.appendSlice(allocator, filled.items);
    filled.deinit(allocator);
    return .{ .ok = {} };
}

/// Pad a parent class's super-delegation args with the defaults for any
/// trailing primary-ctor params the subclass omitted. A subclass that writes
/// `: Base(a)` for `Base(a, b = default)` delegates only `a`; without this the
/// `b` slot would materialize as Unit instead of running its default. Mirrors
/// the direct-construction default fill. `args` is grown in place.
fn padParentCtorDefaults(
    self: *VmHost,
    allocator: Allocator,
    parent_def: ObjRef(ClassDef),
    fqn: ?[]const u8,
    name: []const u8,
    args: *std.ArrayList(Value),
    outer_hint: ?*const Value,
) Allocator.Error!UnitOrErr {
    const n_primary = classDefPrimaryParamCount(parent_def);
    if (args.items.len >= n_primary) return .{ .ok = {} };
    const default_thunks = primaryDefaultThunks(self, fqn, name);
    var idx = args.items.len;
    while (idx < n_primary) : (idx += 1) {
        var dflt_expr: ?*const ast.Expr = null;
        {
            const dg = parent_def.borrow();
            defer dg.deinit();
            if (idx < dg.get().primary_params.len) {
                if (dg.get().primary_params[idx].default) |ff| dflt_expr = ff.get();
            }
        }
        var v: Value = .Null;
        var resolved = false;
        if (dflt_expr) |e| {
            if (try defaultValueForPrimary(allocator, e)) |lv| {
                v = lv;
                resolved = true;
            } else if (try pathConstDefault(self, e)) |lv| {
                v = lv;
                resolved = true;
            }
        }
        if (!resolved) {
            if (default_thunks) |slots| {
                if (idx < slots.len) {
                    if (slots[idx]) |dfid| {
                        const fr = try funcAt(self, dfid, "parent primary ctor default");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                var thunk_args: std.ArrayList(Value) = .empty;
                                defer thunk_args.deinit(allocator);
                                try thunk_args.append(allocator, ctorThunkThisSlot(parent_def, outer_hint)); // `this`
                                try thunk_args.appendSlice(allocator, args.items);
                                while (thunk_args.items.len < n_primary + 1) {
                                    try thunk_args.append(allocator, .Null);
                                }
                                switch (try evalThunk(self, func, thunk_args.items)) {
                                    .ok => |rv| v = rv,
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
        try args.append(allocator, v);
    }
    return .{ .ok = {} };
}

/// Among same-named factory overloads pick the best applicable declaration.
fn pickFactory(self: *VmHost, allocator: Allocator, class_name: []const u8, args: []const Value) Allocator.Error!?FuncId {
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const mg = module_ref.borrow();
    defer mg.deinit();
    const m = mg.get();
    var best_ord: ?FuncId = null;
    var best_ord_score: i32 = std.math.minInt(i32);
    var best_low: ?FuncId = null;
    var best_low_score: i32 = std.math.minInt(i32);
    for (m.funcsBySimpleName(class_name)) |fid| {
        const f = m.funcById(fid) orelse continue;
        if (!f.hasBody()) continue;
        if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        const score = (try host_call_func.runtimeFuncApplicability(self, allocator, m, fid, args)) orelse {
            if (runtime.envOnce("KLIO_FACTORY_TRACE") != null) std.debug.print("[factory] {s}#{d} params={d} inapplicable\n", .{ f.fqn, fid.int(), f.params.len });
            continue;
        };
        if (runtime.envOnce("KLIO_FACTORY_TRACE") != null) std.debug.print("[factory] {s}#{d} points={d} low={}\n", .{ f.fqn, fid.int(), score.points, score.low_priority });
        if (score.low_priority) {
            if (best_low == null or score.points > best_low_score) {
                best_low = fid;
                best_low_score = score.points;
            }
        } else if (best_ord == null or score.points > best_ord_score) {
            best_ord = fid;
            best_ord_score = score.points;
        }
    }
    return best_ord orelse best_low;
}

/// The lexically enclosing class name for an inner/nested class: the
/// build registry's `enclosing_class` map (filled when nested classes are
/// lifted to the top level), falling back to the runtime def's resolved
/// enclosing-class handle.
fn enclosingClassNameOf(self: *VmHost, class_def: ObjRef(ClassDef), ir_name: []const u8) ?[]const u8 {
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        const reg = &mg.get().registry;
        if (reg.enclosing_class.get(ir_name)) |n| return n;
        const def_name = classDefName(class_def);
        if (!std.mem.eql(u8, def_name, ir_name)) {
            if (reg.enclosing_class.get(def_name)) |n| return n;
        }
    }
    const g = class_def.borrow();
    defer g.deinit();
    const eg = g.get().enclosing_class.borrow();
    defer eg.deinit();
    if (eg.get().*) |e| {
        const ng = e.borrow();
        defer ng.deinit();
        return ng.get().name;
    }
    return null;
}

/// True when `v` is an `Instance` whose class is `want` or a subtype of it
/// (simple name or FQN, walking the resolved parent chain and each class's
/// transitive interface supertypes).
fn instanceOfClassName(v: *const Value, want: []const u8) bool {
    if (v.* != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    var cur: ?ObjRef(ClassDef) = g.get().class.clone();
    while (cur) |c| {
        const cg = c.borrow();
        const matched = std.mem.eql(u8, cg.get().name, want) or
            std.mem.eql(u8, cg.get().fqn, want) or
            classDefImplements(cg.get(), want, 0);
        const next: ?ObjRef(ClassDef) = if (cg.get().parent) |p| p.clone() else null;
        cg.deinit();
        c.deinit();
        if (matched) {
            if (next) |n| n.deinit();
            return true;
        }
        cur = next;
    }
    return false;
}

/// Whether `d` names `want` among its (transitive) interface supertypes.
/// Walks resolved `interfaces` refs recursively and falls back to the raw
/// `supertype_names` for interfaces never resolved into refs (builtin or
/// cross-pack names) — an interface-typed parameter must accept a class
/// implementing it (`TweenSpec` for `AnimationSpec<T>`).
fn classDefImplements(d: *const ClassDef, want: []const u8, depth: u32) bool {
    if (depth > 16) return false;
    for (d.supertype_names) |sn| {
        if (std.mem.eql(u8, sn, want)) return true;
    }
    for (d.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        const idef = fg.get();
        if (std.mem.eql(u8, idef.name, want) or std.mem.eql(u8, idef.fqn, want)) return true;
        if (classDefImplements(idef, want, depth + 1)) return true;
    }
    return false;
}

/// The `outer` link of an `Instance` value, `null` otherwise.
fn instanceOuterOf(v: *const Value) ?Value {
    if (v.* != .Instance) return null;
    const g = v.Instance.borrow();
    defer g.deinit();
    return g.get().outer;
}

/// First instance of `want` reachable through `v`'s `outer` links,
/// excluding `v` itself. The walk is Kotlin's class-nesting rule: inside a
/// member of `Inner`, `this@Outer` is in scope as the receiver reachable
/// through the dispatch receiver's captured outer.
fn outerWalkMatch(v: *const Value, want: []const u8) ?Value {
    var cur = instanceOuterOf(v);
    while (cur) |c| {
        if (instanceOfClassName(&c, want)) return c;
        cur = instanceOuterOf(&c);
    }
    return null;
}

/// Pick the outer instance a freshly-materialized inner-class instance
/// captures, keyed on the inner class's lexically enclosing class. The
/// receivers in scope at the construction site are, innermost first: the
/// constructing frame's own `this` (the hint) with its class-nesting tower
/// (`this`, `this.outer`, …), then the enclosing-receiver chain, where each
/// dispatch-receiver entry carries its own tower but a `with`/`run` subject
/// contributes only itself. The first receiver that is an instance of the
/// enclosing class (or a subtype) supplies the outer:
///
/// 1. the hint itself — the bare `Inner()`-inside-a-member case, and the
///    receiver-lambda case where the subject is of the enclosing class
///    (`with(other) { Inner() }` constructs `other.Inner()`);
/// 2. the hint's outer walk — a member of `Inner` constructing a sibling
///    `Inner()` reaches `this@Outer` through its own outer link, never
///    through an unrelated receiver inherited from a caller frame. Skipped
///    when the hint IS the innermost receiver-lambda subject: a displaced
///    `with(x) { … }` subject brings only itself into scope, and the
///    lambda's lexical tower continues on the chain (the displaced `this`);
/// 3. the chain, innermost first, each entry checked directly and — for
///    non-subject entries — through its outer walk;
/// 4. else the explicit hint as given (no class data, or no candidate of
///    the enclosing class — matches the pre-class-keyed behavior).
fn selectInnerOuter(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, outer_hint: ?*const Value) Allocator.Error!?Value {
    const want = enclosingClassNameOf(self, class_def, ir_name) orelse {
        if (runtime.envOnce("KLIO_OUTER_TRACE")) |w| {
            if (std.mem.indexOf(u8, ir_name, w) != null) std.debug.print("[outer] {s}: no enclosing-class record, hint={}\n", .{ ir_name, outer_hint != null });
        }
        if (outer_hint) |h| return h.*;
        return null;
    };
    if (runtime.envOnce("KLIO_OUTER_TRACE")) |w| {
        if (std.mem.indexOf(u8, ir_name, w) != null) std.debug.print("[outer] {s}: want={s} hint={}\n", .{ ir_name, want, outer_hint != null });
    }
    if (outer_hint) |h| {
        if (instanceOfClassName(h, want)) return h.*;
    }
    const entries = try ir.eval.enclosingEntriesAlloc(allocator);
    defer allocator.free(entries);
    const hint_is_subject = blk: {
        const h = outer_hint orelse break :blk false;
        if (h.* != .Instance) break :blk false;
        for (entries) |*e| {
            if (!e.isSubject()) continue;
            break :blk e.v == .Instance and
                ObjRef(InstanceData).ptrEq(h.Instance, e.v.Instance);
        }
        break :blk false;
    };
    if (!hint_is_subject) {
        if (outer_hint) |h| {
            if (outerWalkMatch(h, want)) |m| return m;
        }
    }
    for (entries) |*e| {
        if (instanceOfClassName(&e.v, want)) return e.v;
        if (!e.isSubject()) {
            if (outerWalkMatch(&e.v, want)) |m| return m;
        }
    }
    if (outer_hint) |h| return h.*;
    return null;
}

fn materializeInstance(self: *VmHost, allocator: Allocator, class_def: ObjRef(ClassDef), ir_name: []const u8, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    const class_name = classDefName(class_def);
    const class_fqn = classDefFqn(class_def);
    const identity = nextInstanceId(self);
    const ctor_keepalive = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ctor_keepalive);

    // Build the parent ctor-arg chain top-down. Each entry carries the
    // resolved FQN alongside the written name, so every per-class side
    // table (ctor args, init blocks, body-prop inits) is read for the
    // exact class, never a same-simple-name twin.
    var chain: std.ArrayList(ChainEntry) = .empty;
    defer {
        for (chain.items) |c| allocator.free(c.args);
        chain.deinit(allocator);
    }
    {
        const owned = try allocator.dupe(Value, args);
        try chain.append(allocator, .{ .name = ir_name, .fqn = class_fqn, .args = owned });
        runtime.keepalivePushSlice(owned);
    }
    var cur_class = ir_name;
    var cur_fqn: ?[]const u8 = class_fqn;
    var cur_args: []const Value = args;

    var throwable_message: ?Value = null;
    var throwable_cause: ?Value = null;
    var is_throwable = false;

    // Direct-parent Throwable message/cause recovery.
    {
        const parent_ref = firstNonInterfaceSuper(self, class_def);
        if (parent_ref) |pref| {
            if (isThrowableDirectName(pref.name)) {
                is_throwable = true;
                if (parentCtorArgThunks(self, cur_fqn, cur_class)) |thunks| {
                    for (thunks, 0..) |fid, idx| {
                        const fr = try funcAt(self, fid, "parent ctor arg");
                        switch (fr) {
                            .err => {},
                            .ok => |func| {
                                switch (try evalParentCtorThunk(self, func, cur_args, outer_hint)) {
                                    .ok => |v| {
                                        if (idx == 0) throwable_message = v else if (idx == 1) throwable_cause = v;
                                        runtime.keepalivePush(v);
                                    },
                                    .err => |e| return .{ .err = e },
                                }
                            },
                        }
                    }
                }
            }
        }
    }

    // Walk the parent ctor chain.
    while (parentCtorArgThunks(self, cur_fqn, cur_class)) |thunks| {
        const cur_def = classDefByName(self, sideTableKey(cur_fqn, cur_class));
        var parent_ref: ?SuperRef = null;
        if (cur_def) |d| {
            parent_ref = firstNonInterfaceSuper(self, d);
            d.deinit();
        }
        const pref = parent_ref orelse break;
        const pname = pref.name;

        // Evaluate this level's super-args.
        var parent_args: std.ArrayList(Value) = .empty;
        for (thunks) |fid| {
            const fr = try funcAt(self, fid, "parent ctor arg");
            switch (fr) {
                .err => |e| {
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
                .ok => |func| {
                    const parent_keepalive = runtime.keepaliveMark();
                    runtime.keepalivePushSlice(parent_args.items);
                    const evaluated = evalParentCtorThunk(self, func, cur_args, outer_hint);
                    runtime.keepaliveRestore(parent_keepalive);
                    switch (try evaluated) {
                        .ok => |v| parent_args.append(allocator, v) catch {},
                        .err => |e| {
                            parent_args.deinit(allocator);
                            return .{ .err = e };
                        },
                    }
                },
            }
        }

        if (isThrowableChainName(pname)) {
            is_throwable = true;
            if (throwable_message == null and parent_args.items.len > 0) throwable_message = parent_args.items[0];
            if (throwable_cause == null and parent_args.items.len > 1) throwable_cause = parent_args.items[1];
            parent_args.deinit(allocator);
            break;
        }
        if (std.mem.eql(u8, pname, cur_class)) {
            parent_args.deinit(allocator);
            break;
        }
        const parent_def = classDefByName(self, sideTableKey(pref.fqn, pname));
        const parent_is_iface = if (parent_def) |d| classDefIsInterface(d) else true;
        if (parent_def == null or parent_is_iface) {
            if (parent_def) |d| d.deinit();
            parent_args.deinit(allocator);
            break;
        }
        switch (try expandParentSecondaryThisArgs(self, allocator, pref.fqn, pname, &parent_args)) {
            .ok => {},
            .err => |e| {
                if (parent_def) |d| d.deinit();
                parent_args.deinit(allocator);
                return .{ .err = e };
            },
        }
        // Reorder any named super-constructor arguments into the parent's
        // parameter order before the positional field-binding below reads
        // them (`: Base(objects = 2)` must set `objects`, not the first slot).
        if (parent_def) |d| {
            switch (try reorderNamedSuperArgs(self, allocator, d, pref.fqn, pname, parentCtorArgNames(self, cur_fqn, cur_class), &parent_args, outer_hint)) {
                .ok => {},
                .err => |e| {
                    d.deinit();
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            // The handle stays live for the defaults-padding block below,
            // which releases it on every path — a second deinit here
            // double-freed the class def under the reclaim profile.
        }
        // Fill any trailing primary-ctor params the subclass omitted from
        // its `super(...)` delegation with the parent's defaults.
        if (parent_def) |d| {
            switch (try padParentCtorDefaults(self, allocator, d, pref.fqn, pname, &parent_args, outer_hint)) {
                .ok => {},
                .err => |e| {
                    d.deinit();
                    parent_args.deinit(allocator);
                    return .{ .err = e };
                },
            }
            d.deinit();
        }
        // Pack the delegation args for the parent's vararg primary param.
        const packed_parent = try packPrimaryCtorVarargs(self, pref.fqn, pname, try parent_args.toOwnedSlice(allocator));
        // `chain` owns this duped copy (freed on chain teardown) and it
        // outlives the loop, so the next iteration reads its super-args from
        // it. The packed buffer is a dead full allocation once duped.
        const chain_args = try allocator.dupe(Value, packed_parent);
        try chain.append(allocator, .{ .name = pname, .fqn = pref.fqn, .args = chain_args });
        runtime.keepalivePushSlice(chain_args);
        if (runtime.freeScratch()) allocator.free(packed_parent);
        cur_class = pname;
        cur_fqn = pref.fqn;
        cur_args = chain_args;
    }

    // Apply primary-param properties bottom-up so child overrides win.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    errdefer fields.deinit(allocator);
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            var cls_def = classDefByName(self, sideTableKey(chain.items[ci].fqn, cls_name));
            var use_def = false;
            if (cls_def) |d| {
                if (classDefIsInterface(d)) {
                    d.deinit();
                    cls_def = null;
                } else {
                    use_def = true;
                }
            }
            if (!use_def and std.mem.eql(u8, cls_name, class_name)) {
                cls_def = class_def.clone();
                use_def = true;
            }
            if (cls_def) |d| {
                defer d.deinit();
                const dg = d.borrow();
                const pp = dg.get().primary_params;
                var k: usize = 0;
                while (k < pp.len and k < cls_args.len) : (k += 1) {
                    if (pp[k].property != null) {
                        const fv = adoptDeclaredNumeric(&pp[k], cls_args[k]);
                        // Dedup on the STORAGE key: a subclass's private
                        // SHADOW of a base ctor property lives in its own
                        // owner-mangled cell and must not displace the base's
                        // plain cell (base-class code reads it by plain name).
                        // An OVERRIDE cell keeps the old behavior — the
                        // child's cell supersedes the plain one.
                        const store_key = shadowFieldKey(self, cls_name, pp[k].name);
                        retainFieldList(&fields, allocator, store_key);
                        if (store_key.len != pp[k].name.len and !isPrivateShadowProp(self, cls_name, pp[k].name)) {
                            retainFieldList(&fields, allocator, pp[k].name);
                        }
                        // The instance owns one ref to each primary-ctor field.
                        if (runtime.reclaimEnabled()) fv.retain();
                        try fields.append(allocator, .{ .name = store_key, .value = fv });
                    }
                }
                dg.deinit();
            }
        }
    }

    // A plain (non-property) primary-ctor parameter a member body reads is
    // captured by Kotlin as a synthesized field. Seed each under its name when
    // nothing else owns it: a property param (seeded above, own or inherited)
    // or a same-class body property (seeded from its initializer below) holds
    // the name instead, so skip those — else a duplicate/shadowing cell would
    // displace the real property. Runs after the whole property pass so an
    // inherited property (a base `val root` under a subclass's plain `root`
    // param) is already present and wins.
    {
        var ci: usize = chain.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls_name = chain.items[ci].name;
            const cls_args = chain.items[ci].args;
            var cls_def = classDefByName(self, sideTableKey(chain.items[ci].fqn, cls_name));
            var use_def = false;
            if (cls_def) |d| {
                if (classDefIsInterface(d)) {
                    d.deinit();
                    cls_def = null;
                } else {
                    use_def = true;
                }
            }
            if (!use_def and std.mem.eql(u8, cls_name, class_name)) {
                cls_def = class_def.clone();
                use_def = true;
            }
            if (cls_def) |d| {
                defer d.deinit();
                const dg = d.borrow();
                const pp = dg.get().primary_params;
                var k: usize = 0;
                while (k < pp.len and k < cls_args.len) : (k += 1) {
                    if (pp[k].property != null) continue;
                    const pnm = pp[k].name;
                    var present = false;
                    for (fields.items) |f| {
                        if (std.mem.eql(u8, f.name, pnm)) {
                            present = true;
                            break;
                        }
                    }
                    if (present) continue;
                    var owned_by_body = false;
                    for (dg.get().body_properties) |bp| {
                        if (std.mem.eql(u8, bp.name, pnm)) {
                            owned_by_body = true;
                            break;
                        }
                    }
                    if (owned_by_body) continue;
                    const fv = cls_args[k];
                    if (runtime.reclaimEnabled()) fv.retain();
                    try fields.append(allocator, .{ .name = pnm, .value = fv });
                }
                dg.deinit();
            }
        }
    }

    // Seed non-nullable primitive `var` fields with their type zero.
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            const g = c.borrow();
            for (g.get().body_properties) |p| {
                if (p.init != null or p.getter != null or p.delegate != null) continue;
                if (p.primitive_zero) |zv| {
                    var exists = false;
                    for (fields.items) |f| {
                        if (std.mem.eql(u8, f.name, p.name)) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) try fields.append(allocator, .{ .name = p.name, .value = zv });
                }
            }
            const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
            g.deinit();
            c.deinit();
            cur = next;
        }
    }

    // Materialise the instance.
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def.clone(),
        .fields = fields,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    const inst_value = Value{ .Instance = inst };
    // The instance under construction is reachable only through this host local
    // until it is returned and bound; its body-property/init-block initializers
    // run user code (safe points), so pin it across construction or a collection
    // there sweeps the half-built shell and frees its field list out from under
    // us. (Object/companion singletons are additionally pinned via the in-flight
    // object-state table, but regular instances have no such anchor.)
    const ka_inst = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka_inst);
    runtime.keepalivePush(inst_value);

    // Attach a stored default-outer.
    {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            const og = self.class_default_outer.borrow();
            const default_outer = og.get().get(class_name);
            og.deinit();
            if (default_outer) |o| {
                // `outer` is an owned field (teardown releases it); the value
                // read from the default-outer table is a borrow, so retain.
                o.retain();
                const g = inst.borrowMut();
                g.get().outer = o;
                g.deinit();
            }
        }
    }
    // Inner-class outer selection.
    if (classDefIsInner(class_def)) {
        const has_outer = blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().outer != null;
        };
        if (!has_outer) {
            if (try selectInnerOuter(self, allocator, class_def, ir_name, outer_hint)) |outer_v| {
                // `selectInnerOuter` hands back a borrow of the outer-hint /
                // capture; `outer` is an owned field, so retain before storing.
                outer_v.retain();
                const g = inst.borrowMut();
                g.get().outer = outer_v;
                g.deinit();
            }
        }
    }

    // Make an object / companion singleton shell visible before its init
    // runs. A gate-driven construction records the in-flight instance in
    // the shared object-init table, so re-entrant reads from the
    // constructing thread (the object referencing itself during its own
    // init) observe it while other threads keep waiting — the singleton
    // only publishes into `globals` after construction completes. A
    // construction NOT driven through the gate (a runtime-registered
    // local object) publishes directly, as before.
    if (classDefIsObject(class_def)) {
        if (!host_globals.noteObjectInFlight(self, class_name, inst_value)) {
            const g = self.globals.borrowMut();
            g.get().define(class_name, inst_value) catch {};
            g.deinit();
        }
    }

    // Evaluate class-delegation expressions. A `by <expr>` interface
    // delegation declared on any class in the chain forwards the
    // delegated interface's members, so each level's delegate thunks run
    // against that level's resolved super-args — not only the leaf's, so a
    // subclass of a delegating base inherits its delegate fields. Leaf
    // first: a more-derived class's delegation for an interface overrides
    // a base's, so the first delegate field for a given interface wins and
    // a later (base-level) one is skipped. The leaf is keyed on its
    // runtime `class_name` (the side table's key), not the IR name the
    // chain records, which can differ when the def was resolved through a
    // sibling/fqn lookup.
    {
        for (chain.items, 0..) |c, idx| {
            const lookup_name = if (idx == 0) class_name else c.name;
            const delegates = classDelegateThunks(self, c.fqn, lookup_name);
            for (delegates) |sf| {
                const fr = try funcAt(self, sf.func, "class delegate");
                // The delegation expression evaluates in the class body's
                // scope: an inner class's `Density by this@Outer` reaches
                // the enclosing instance through the under-construction
                // instance's outer link. Make the instance an enclosing
                // receiver for the thunk so the labeled-this walk finds it.
                var inst_v = Value{ .Instance = inst };
                ir.eval.pushEnclosing(&inst_v);
                defer ir.eval.popEnclosing();
                switch (fr) {
                    .err => {},
                    .ok => |func| {
                        switch (try evalThunk(self, func, c.args)) {
                            .ok => |v| {
                                const key = try std.fmt.allocPrint(allocator, "__delegate__{s}", .{sf.name});
                                const g = inst.borrowMut();
                                const already = g.get().get(key) != null;
                                if (!already) {
                                    try g.get().ensureFieldsOwned(allocator, 1);
                                    try g.get().fields.append(allocator, .{ .name = key, .value = v });
                                    g.get().invalidateShape();
                                }
                                g.deinit();
                            },
                            .err => |e| return .{ .err = e },
                        }
                    },
                }
            }
        }
    }
    if (throwable_message) |m| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "message", .value = m });
        g.get().invalidateShape();
        g.deinit();
    }
    if (throwable_cause) |c| {
        const g = inst.borrowMut();
        try g.get().fields.append(allocator, .{ .name = "cause", .value = c });
        g.get().invalidateShape();
        g.deinit();
    }
    // fillInStackTrace at construction (JVM order) for a user Throwable
    // subclass: its parent chain bottomed out at a builtin Throwable.
    if (is_throwable) {
        var tv = Value{ .Instance = inst };
        try ir.eval.attachStackTrace(allocator, &tv);
    }

    // Body properties: walk the parent chain bottom-up.
    var chain_classes: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (chain_classes.items) |c| c.deinit();
        chain_classes.deinit(allocator);
    }
    {
        var cur: ?ObjRef(ClassDef) = class_def.clone();
        while (cur) |c| {
            try chain_classes.append(allocator, c.clone());
            const g = c.borrow();
            const next: ?ObjRef(ClassDef) = if (g.get().parent) |p| p.clone() else null;
            g.deinit();
            c.deinit();
            cur = next;
        }
    }
    {
        var ci: usize = chain_classes.items.len;
        while (ci > 0) {
            ci -= 1;
            const cls = chain_classes.items[ci];
            const cls_name = classDefName(cls);
            const cls_fqn = classDefFqn(cls);
            const body_len = blk: {
                const g = cls.borrow();
                defer g.deinit();
                break :blk g.get().body_properties.len;
            };
            const cls_args: []const Value = blk: {
                for (chain.items) |*c| {
                    if (chainEntryIs(c, cls_fqn, cls_name)) break :blk c.args;
                }
                break :blk args;
            };
            var prop_idx: usize = 0;
            while (prop_idx < body_len) : (prop_idx += 1) {
                switch (try runInitBlocksAt(self, cls, prop_idx, &inst_value, chain.items, args)) {
                    .ok => {},
                    .err => |e| return .{ .err = e },
                }
                const prop_name = blk: {
                    const g = cls.borrow();
                    defer g.deinit();
                    break :blk g.get().body_properties[prop_idx].name;
                };
                if (bodyPropInit(self, cls_fqn, cls_name, prop_name)) |fid| {
                    const fr = try funcAt(self, fid, "body prop init");
                    switch (fr) {
                        .err => |e| return .{ .err = e },
                        .ok => |func| {
                            // The initializer runs in the class body's
                            // scope, so a lambda created inside it must see
                            // the instance as an enclosing receiver — a
                            // closure snapshots the chain at creation, and
                            // without this a bare name inside
                            // `Job(..).apply { invokeOnCompletion { stateLock } }`
                            // saw only the `apply` receiver and fell through to
                            // the global. Same treatment the class DELEGATE
                            // thunk already gets below; the instance is passed
                            // as the thunk's `this` PARAMETER, which is not the
                            // same as being on the enclosing chain.
                            var encl_v = inst_value;
                            ir.eval.pushEnclosing(&encl_v);
                            defer ir.eval.popEnclosing();
                            var all: std.ArrayList(Value) = .empty;
                            defer all.deinit(allocator);
                            try all.append(allocator, inst_value);
                            try all.appendSlice(allocator, cls_args);
                            var v = blk_v: {
                                const mg3 = self.module.borrow();
                                defer mg3.deinit();
                                if (try trivialInitServe(allocator, mg3.get(), func, all.items)) |sv| break :blk_v sv;
                                break :blk_v switch (try evalThunk(self, func, all.items)) {
                                    .ok => |rv| rv,
                                    .err => |e| return .{ .err = e },
                                };
                            };
                            v = try maybeProvideDelegate(self, allocator, cls_name, prop_name, &inst_value, v);
                            const g = inst.borrowMut();
                            try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), v);
                            g.deinit();
                        },
                    }
                } else {
                    const init_expr = blk: {
                        const g = cls.borrow();
                        defer g.deinit();
                        break :blk g.get().body_properties[prop_idx].init;
                    };
                    if (init_expr) |ie| {
                        const v = (try simpleLiteral(allocator, ie.get())) orelse blk: {
                            // A local class's complex initializer was lowered
                            // as a runtime `$init$` thunk at registration.
                            const init_name = try std.fmt.allocPrint(allocator, "$init${s}", .{prop_name});
                            defer allocator.free(init_name);
                            const has = hblk: {
                                const key = try anonKey(allocator, cls_name, init_name);
                                defer allocator.free(key);
                                const ag = self.anon_methods.borrow();
                                defer ag.deinit();
                                break :hblk ag.get().contains(key);
                            };
                            if (has) {
                                switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, cls_args)) {
                                    .ok => |rv| break :blk rv,
                                    .err => |e| return .{ .err = e },
                                }
                            }
                            break :blk Value.Null;
                        };
                        const g = inst.borrowMut();
                        try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), v);
                        g.deinit();
                    } else {
                        // A local class's delegated property: the delegate
                        // expression was lowered as a `$init$` thunk at
                        // registration; evaluate it and store the delegate
                        // under the property name (the shape the getValue/
                        // setValue read/write routes expect).
                        const has_delegate = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            break :blk g.get().body_properties[prop_idx].delegate != null;
                        };
                        if (has_delegate) {
                            const init_name = try std.fmt.allocPrint(allocator, "$init${s}", .{prop_name});
                            defer allocator.free(init_name);
                            const has_thunk = hblk: {
                                const key = try anonKey(allocator, cls_name, init_name);
                                defer allocator.free(key);
                                const ag = self.anon_methods.borrow();
                                defer ag.deinit();
                                break :hblk ag.get().contains(key);
                            };
                            if (has_thunk) {
                                switch (try host_call_member.callMember(self, allocator, &inst_value, init_name, cls_args)) {
                                    .ok => |rv| {
                                        const g = inst.borrowMut();
                                        try g.get().define(allocator, shadowFieldKey(self, cls_name, prop_name), rv);
                                        g.deinit();
                                    },
                                    .err => |e| return .{ .err = e },
                                }
                            }
                        }
                        const skip = blk: {
                            const g = cls.borrow();
                            defer g.deinit();
                            const bp = g.get().body_properties[prop_idx];
                            break :blk bp.getter != null or bp.delegate != null or bp.is_abstract;
                        };
                        if (!skip) {
                            const exists = blk: {
                                const g = inst.borrow();
                                defer g.deinit();
                                break :blk g.get().get(prop_name) != null;
                            };
                            if (!exists) {
                                const g = inst.borrowMut();
                                try g.get().fields.append(allocator, .{ .name = prop_name, .value = .Null });
                                g.get().invalidateShape();
                                g.deinit();
                            }
                        }
                    }
                }
            }
            switch (try runInitBlocksAt(self, cls, body_len, &inst_value, chain.items, args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
    }

    return .{ .ok = inst_value };
}

/// `provideDelegate` hook for a delegated body property.
fn maybeProvideDelegate(self: *VmHost, allocator: Allocator, cls_name: []const u8, prop_name: []const u8, inst_value: *const Value, v: Value) Allocator.Error!Value {
    if (v != .Instance) return v;
    const is_delegated = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (mod.registry.delegated_body_props.contains(.{ .a = cls_name, .b = prop_name })) break :blk true;
        if (mod.classId(cls_name)) |cid| {
            if (cid.int() < mod.classes.items.len) {
                const fqn = mod.classes.items[cid.int()].fqn;
                if (mod.registry.delegated_body_props.contains(.{ .a = fqn, .b = prop_name })) break :blk true;
            }
        }
        break :blk false;
    };
    if (!is_delegated) return v;
    // The delegate provides a `provideDelegate` operator when its OWN runtime
    // class chain declares one — including a SAM-converted `fun interface`
    // (e.g. `PropertyDelegateProvider { … }`), whose abstract method carries a
    // `sam_lambda` rather than a module-level `FuncId`. Checking the instance's
    // runtime class (not the static IR class) catches both forms; a plain
    // `ReadOnlyProperty`/`ReadWriteProperty` delegate has only `getValue`/
    // `setValue`, so it is left untouched.
    const has_provide = blk: {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cls_ref = g.get().class;
        // A concrete `provideDelegate` somewhere on the runtime class chain.
        if (ClassDef.findMethod(cls_ref, allocator, "provideDelegate")) |hit| {
            hit.class.deinit();
            break :blk true;
        }
        // A SAM-converted `fun interface` carries no materialized method; its
        // abstract surface is recorded in `hierarchy_methods` (the same table
        // `samInstanceDispatch` consults to route a call to the lambda).
        const dcls = blk2: {
            const cg = cls_ref.borrow();
            defer cg.deinit();
            break :blk2 cg.get().name;
        };
        const mg = self.module.borrow();
        defer mg.deinit();
        if (mg.get().registry.hierarchy_methods.get(dcls)) |methods| {
            break :blk methods.contains("provideDelegate");
        }
        break :blk false;
    };
    if (!has_provide) return v;
    const prop_ref = Value{ .PropertyRef = .{ .name = try runtime.strInitOwned(allocator, try allocator.dupe(u8, prop_name)) } };
    switch (try self.callMember(allocator, &v, "provideDelegate", &.{ inst_value.*, prop_ref })) {
        .ok => |rep| return rep,
        .err => return v,
    }
}

fn retainFieldList(fields: *std.ArrayList(InstanceData.Field), allocator: Allocator, key: []const u8) void {
    _ = allocator;
    var i: usize = 0;
    while (i < fields.items.len) {
        if (std.mem.eql(u8, fields.items[i].name, key)) {
            _ = fields.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn isThrowableDirectName(name: []const u8) bool {
    const names = [_][]const u8{
        "Throwable",                       "Exception",
        "RuntimeException",                "Error",
        "IllegalArgumentException",        "IllegalStateException",
        "IndexOutOfBoundsException",       "NullPointerException",
        "ClassCastException",              "ArithmeticException",
        "NumberFormatException",           "NoSuchElementException",
        "ConcurrentModificationException", "UnsupportedOperationException",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn isThrowableChainName(name: []const u8) bool {
    if (isBuiltinThrowableNameNoCancel(name)) return true;
    return std.mem.eql(u8, name, "CancellationException");
}

// -------------------------------------------------------------------------
// The vtable routes `build_object` here.
// -------------------------------------------------------------------------

/// `(class, member)` key for `anon_methods`, unit-separated. Must match
/// `run.zig`/`host_fields.zig`/`host_call_member.zig`.
fn anonKey(allocator: Allocator, class_name: []const u8, member: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\u{1f}{s}", .{ class_name, member });
}

fn buildCapturePairs(allocator: Allocator, captured_names: []const []const u8, captures: []const Value) Allocator.Error![]NameValue {
    const n = @min(captured_names.len, captures.len);
    var pairs = try allocator.alloc(NameValue, n);
    for (0..n) |i| {
        // The anon-method registry holds these captures for the object's whole
        // lifetime; retain so a captured value outlives the enclosing frame that
        // produced it. Released when the registry entry is dropped. No-op arena.
        if (runtime.reclaimEnabled()) captures[i].retain();
        pairs[i] = .{ .name = captured_names[i], .value = captures[i] };
    }
    return pairs;
}

fn findCapture(pairs: []const NameValue, name: []const u8) ?Value {
    for (pairs) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

/// A captured mutable local arrives as its shared cell. A field or super-arg
/// initialized from it must SNAPSHOT the content at construction — storing the
/// cell makes every later read see the local's current value (`val name = key`
/// in an object literal built inside a lambda tracked `key` live).
fn snapshotCapture(v: Value) Value {
    switch (v) {
        .Cell => |c| {
            const g = c.borrow();
            defer g.deinit();
            const inner = g.get().*;
            inner.retain();
            return inner;
        },
        else => return v,
    }
}

/// Is `expr` a bare one-segment name the captured scope can resolve
/// directly — a captured local, or a field of the captured enclosing
/// `this`? Exactly these are filled without a thunk at instance build;
/// every other expression evaluates through a lowered thunk.
fn bareCaptureResolvable(expr: *const ast.Expr, pairs: []const NameValue) bool {
    if (expr.* != .Path or expr.Path.segments.len != 1) return false;
    const nm = expr.Path.segments[0].name;
    // Direct captures ONLY. The capture-name list is site-static, so this
    // answer holds for every construction. Probing the captured `this` for a
    // FIELD of the name is a first-instance fact: this decision is cached
    // per SITE, and `object : Iterator { var left = count }` built first
    // under a receiver STORING `count` skipped the init thunk — the next
    // receiver, whose `count` is a custom getter with no backing field, then
    // constructed with `left = null`. The runtime fills still read the
    // captured `this` directly where that resolves; the thunk is the
    // fallback that works for every receiver shape.
    return findCapture(pairs, nm) != null;
}

/// Like `synthThunk` but carrying the custom setter's single value parameter,
/// so an anonymous-object / local-class `override var x set(value) { … }`
/// lowers as a 1-arg method the field-write path can dispatch. The param
/// slice is allocated from `allocator` (the thunk is lowered immediately, so
/// any per-call allocator outliving the lowering works).
pub fn synthSetterThunk(allocator: Allocator, name: ast.Ident, value_param: ast.Ident, body: ast.FunctionBody, is_override: bool) Allocator.Error!ast.Function {
    var f = synthThunk(name, body, null, is_override);
    const params = try allocator.alloc(ast.Param, 1);
    params[0] = .{
        .name = value_param,
        .ty = .{
            .name = .{ .name = "Any", .span = value_param.span },
            .nullable = true,
            .span = value_param.span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        },
        .default = null,
        .is_vararg = false,
        .is_crossinline = false,
        .is_noinline = false,
        .annotations = &.{},
        .span = value_param.span,
    };
    f.params = params;
    return f;
}

/// Synthesize a body-less 0-arg getter/init thunk `Function` from an
/// accessor or expression body so it can be lowered as an anon method.
pub fn synthThunk(name: ast.Ident, body: ast.FunctionBody, return_type: ?ast.TypeRef, is_override: bool) ast.Function {
    return .{
        .name = name,
        .receiver_type = null,
        .type_params = &.{},
        .where_bounds = &.{},
        .params = &.{},
        .return_type = return_type,
        .body = body,
        .is_open = false,
        .is_override = is_override,
        .is_abstract = false,
        .is_operator = false,
        .is_inline = false,
        .is_infix = false,
        .is_tailrec = false,
        .is_suspend = false,
        .is_expect = false,
        .is_actual = false,
        .visibility = .Public,
        .annotations = &.{},
        .span = name.span,
    };
}

/// Stable synthetic class name for an anonymous-object expression, keyed by the
/// AST node address (the program is immutable, so the address is a stable site
/// id). The first instantiation of a site mints `$anon$<n>` and registers the
/// site's class + methods under it; later instantiations of the same site reuse
/// that name, so the `classes`/`anon_methods` registries stay bounded by the
/// number of `object` expressions in the program instead of growing per instance
/// (a per-request leak for a server). Names are permanent (page-allocator) since
/// they are used as long-lived map keys.
var anon_site_names: std.AutoHashMapUnmanaged(usize, []const u8) = .empty;
var anon_site_lock: runtime.SpinMutex = .{};

/// Record the enclosing declaration's type-parameter names for a lowered
/// anon-object method, so `typeParamOf`-based adjudication sees `Key` in
/// `add(element: Key)` as a type variable rather than a nominal class.
fn inheritAnonTypeParams(self: *VmHost, tps: []const []const u8, fid: FuncId) void {
    if (tps.len == 0) return;
    const mg = self.module.borrowMut();
    defer mg.deinit();
    const reg = &mg.get().registry;
    if (reg.func_type_params.contains(fid)) return;
    var lst: std.ArrayList([]const u8) = .empty;
    for (tps) |tp| {
        const d = reg.allocator.dupe(u8, tp) catch return;
        lst.append(reg.allocator, d) catch return;
    }
    reg.func_type_params.put(fid, lst) catch {};
}

fn anonSiteName(expr: *const ast.Expr) []const u8 {
    const key = @intFromPtr(expr);
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    if (anon_site_names.get(key)) |n| return n;
    const n = anon_site_names.count();
    const name = std.fmt.allocPrint(std.heap.page_allocator, "$anon${d}", .{n}) catch return "$anon$x";
    anon_site_names.put(std.heap.page_allocator, key, name) catch {};
    return name;
}

/// An `object` literal's field/init/super-arg initializers that need real
/// evaluation are lowered into side modules. Those modules are site-stable
/// (pure functions of the AST site — captures resolve at run time, not lowering
/// time), so they are lowered once per site and cached here, keyed by the
/// site's AST address. Reused by every instantiation: a per-request `object`
/// literal evaluates the cached thunks instead of re-lowering them into fresh
/// Module cells that, when swept, free only their header and leak the lowered
/// IR they own.
const AnonComplexInit = struct { name: []const u8, module: ObjRef(Module), func: FuncId };
const AnonInitThunk = struct { module: ObjRef(Module), func: FuncId, prop_pos: usize };
const AnonSuperArgThunk = struct { module: ObjRef(Module), func: FuncId };
/// One `object : Iface by <expr> {}` delegate initializer, parallel to the
/// site's supertype list; null when the slot has no delegate or a bare
/// captured name serves it directly.
const AnonDelegateThunk = struct { module: ObjRef(Module), func: FuncId };
const AnonSiteThunks = struct {
    complex_prop_inits: []const AnonComplexInit,
    init_thunks: []const AnonInitThunk,
    super_arg_thunks: []const []const ?AnonSuperArgThunk,
    delegate_thunks: []const ?AnonDelegateThunk = &.{},
};
var anon_site_thunks: std.AutoHashMapUnmanaged(usize, AnonSiteThunks) = .empty;
var anon_site_thunks_root_registered = std.atomic.Value(bool).init(false);

/// GC root: shade every cached anon-site thunk sub-module so the cached lowered
/// IR is never swept (it is reused across all instantiations of the site). Read
/// without locking: the stop-the-world handshake parks every mutator at a safe
/// point and neither `get` nor `put` spans a safe point, so the map is stable
/// here.
fn gcMarkAnonSites(m: *runtime.gc.Marker) void {
    var it = anon_site_thunks.valueIterator();
    while (it.next()) |t| {
        for (t.complex_prop_inits) |c| m.shade(&c.module.cell.hdr);
        for (t.init_thunks) |i| m.shade(&i.module.cell.hdr);
        for (t.super_arg_thunks) |slots| {
            for (slots) |s| if (s) |th| m.shade(&th.module.cell.hdr);
        }
        for (t.delegate_thunks) |s| if (s) |th| m.shade(&th.module.cell.hdr);
    }
}

fn anonSiteThunksGet(key: usize) ?AnonSiteThunks {
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    return anon_site_thunks.get(key);
}

/// Clear the process-global anon-`object` site caches at a program-run
/// boundary. Both are keyed by AST-node address, which is only stable within a
/// single run; a later run can reuse a freed address, so a stale entry would
/// dispatch through a thunk sub-module owned by the finished run's allocator
/// (a cross-run use-after-free). Frees the permanent (page-allocator) site
/// names and thunk-list spines; the thunk sub-module cells are GC cells the
/// collector reclaims once unrooted. Run-boundary only (no workers live).
pub fn resetAnonSiteCache() void {
    const pa = std.heap.page_allocator;
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    {
        var it = anon_site_names.valueIterator();
        while (it.next()) |n| pa.free(n.*);
        anon_site_names.clearAndFree(pa);
    }
    {
        var it = anon_site_thunks.valueIterator();
        while (it.next()) |t| {
            if (t.complex_prop_inits.len != 0) pa.free(t.complex_prop_inits);
            if (t.init_thunks.len != 0) pa.free(t.init_thunks);
            for (t.super_arg_thunks) |slots| if (slots.len != 0) pa.free(slots);
            if (t.super_arg_thunks.len != 0) pa.free(t.super_arg_thunks);
            if (t.delegate_thunks.len != 0) pa.free(t.delegate_thunks);
        }
        anon_site_thunks.clearAndFree(pa);
    }
    // The shared side-module clone must not cross a program boundary: its
    // identity gate compares run-module CELL ADDRESSES, and an arena-reusing
    // driver hands the next program's module the same address — the stale
    // clone then serves classes whose shallow-shared method slices point
    // into the finished program's freed storage.
    if (shared_anon_module != null) {
        runtime.gc.forgetCell(&shared_anon_module.?.cell.hdr);
        shared_anon_module = null;
        if (shared_anon_arena) |holder| {
            holder.deinit();
            std.heap.page_allocator.destroy(holder);
            shared_anon_arena = null;
        }
    }
}

/// Publish a site's thunks (first publisher wins). A racing second build of the
/// same site loses; the loser's modules are left unrooted and GC reclaims them.
/// Returns the entry now in the cache.
fn anonSiteThunksPut(key: usize, entry: AnonSiteThunks) AnonSiteThunks {
    anon_site_lock.lock();
    defer anon_site_lock.unlock();
    if (anon_site_thunks.get(key)) |existing| return existing;
    anon_site_thunks.put(std.heap.page_allocator, key, entry) catch return entry;
    return entry;
}

/// The side module a runtime-synthesized class's members lower into: a
/// `cloneForExtend` of the main module, built lazily ONCE per synthesis call
/// and shared by every member/thunk lowering of that site. The clone sees the
/// whole image — classes, registries, the shared lazy func-id space — so a
/// member body's calls resolve and bind statically exactly as build-time
/// lowering would, and an emitted main-space FuncId/slot resolves both
/// through the host and through the side module itself (the cloned header
/// section serves ids below the append range). `Module.default` (the old
/// empty side module) left every call in every anon body name-dynamic.
/// `KLIO_ANON_BASE=0` restores the empty side module.
/// One process-wide side module shared by every synthesis site: a compose
/// run synthesizes hundreds of sites, and per-site clones of the image's
/// registry/indices blew the RSS cap. Appends serialize under
/// `anonLowerEnter`/`anonLowerExit`, held by callers around LOWERING
/// sections only (never around thunk execution).
var shared_anon_module: ?ObjRef(Module) = null;
var shared_anon_arena: ?*std.heap.ArenaAllocator = null;
/// Cell identity of the run module `shared_anon_module` was cloned from.
/// An in-process driver that builds and frees a module PER PROGRAM (the
/// parity itests) must not serve a later program from a side module whose
/// shallow-shared tables point into the freed earlier module — the stale
/// clone's appended-class method slices dangle and the first anon-method
/// bare call segfaults. A base-identity mismatch drops the cache and
/// re-clones from the live module.
var shared_anon_base_identity: usize = 0;
var anon_lower_mutex: runtime.SpinMutex = .{};
var anon_lower_owner: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var anon_lower_depth: usize = 0;

pub fn anonLowerEnter() void {
    const me: u64 = @as(u64, @intCast(std.Thread.getCurrentId())) +% 1;
    if (anon_lower_owner.load(.acquire) == me) {
        anon_lower_depth += 1;
        return;
    }
    anon_lower_mutex.lock();
    anon_lower_owner.store(me, .release);
    anon_lower_depth = 1;
}

pub fn anonLowerExit() void {
    anon_lower_depth -= 1;
    if (anon_lower_depth == 0) {
        anon_lower_owner.store(0, .release);
        anon_lower_mutex.unlock();
    }
}

/// Caller must hold the anon-lower lock across this call AND every
/// `lowerMethod` into the returned module.
pub fn anonSiteModule(self: *VmHost, allocator: Allocator, cache: *?ObjRef(Module)) Allocator.Error!ObjRef(Module) {
    if (cache.*) |m| return m.clone();
    // Default ON: the image-clone side module makes anon bodies resolve
    // and bind statically. The historical RSS blowup was the shared
    // clone renting the RUN ARENA — with the side module on its own real
    // allocator (below), a full compose suite measures RSS-neutral
    // against the empty-module mode, and single classes measure neutral
    // or better. `KLIO_ANON_BASE=0` restores the empty side module.
    if (std.mem.eql(u8, runtime.envOnce("KLIO_ANON_BASE") orelse "1", "0")) {
        return ObjRef(Module).init(allocator, Module.default(allocator));
    }
    if (shared_anon_module != null and shared_anon_base_identity != self.module.identity()) {
        // A real free, not the refcount-gated `deinit` (a no-op under the
        // arena and tracing-GC modes): the retired clone is a whole deep
        // Module (~tens of MB) and a multi-program harness swaps it every
        // program — leaking it ratcheted the process into the RSS cap.
        // `Module.deinit` cannot free a cloneForExtend product (it would
        // free base buffers the clone only borrows), so the clone lives in
        // its OWN arena and retirement drops the arena wholesale. Handles
        // the finished program handed out are dead with it.
        runtime.gc.forgetCell(&shared_anon_module.?.cell.hdr);
        shared_anon_module = null;
        if (shared_anon_arena) |holder| {
            holder.deinit();
            std.heap.page_allocator.destroy(holder);
            shared_anon_arena = null;
        }
    }
    if (shared_anon_module == null) {
        shared_anon_base_identity = self.module.identity();
        const mg = self.module.borrow();
        defer mg.deinit();
        // The shared side module owns a REAL allocator, never the run
        // arena: every lowering's scratch (candidate lists, type clones,
        // solved bindings) rents from `module.registry.allocator` and
        // frees on the way out — frees that were no-ops against the
        // harness arena, which is what accumulated an entire suite's
        // lowering scratch into the RSS cap. Persistent appends (the
        // lowered funcs themselves) stay bounded and live for the
        // process, matching the module's own lifetime.
        const holder = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        holder.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        shared_anon_arena = holder;
        var cloned = try mg.get().cloneForExtend(holder.allocator());
        cloned.anon_side = true;
        // PERMANENT cell, and never on the program-perm list: this cache
        // outlives programs and is freed only by the identity swap above.
        // A nursery mint here was swept by the next unrelated major (no
        // root shades it) — the swap's arena teardown is the sole owner.
        const saved_perm = runtime.gc.alloc_perm;
        const saved_ppc = runtime.gc.program_perm_collect;
        runtime.gc.alloc_perm = true;
        runtime.gc.program_perm_collect = false;
        shared_anon_module = try ObjRef(Module).init(holder.allocator(), cloned);
        runtime.gc.program_perm_collect = saved_ppc;
        runtime.gc.alloc_perm = saved_perm;
    }
    const ref = shared_anon_module.?.clone();
    cache.* = ref.clone();
    return ref;
}

pub fn buildObject(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, captured_names: []const []const u8, captures: []const Value, scope_renames: []const ir.ScopeRename, scope_classes: []const ir.ScopeClassRef) Allocator.Error!EvalResult {
    if (expr.* != .ObjectExpr) {
        return .{ .err = try typeErr(allocator, "Vm::build_object: not an ObjectExpr AST node", .{}) };
    }
    if (runtime.gc.gc_enabled and !anon_site_thunks_root_registered.swap(true, .monotonic)) {
        runtime.gc.registerRoot(gcMarkAnonSites);
    }
    // The member bodies below lower into fresh side modules with none of
    // the build's scope registries; install the lexical site's rename
    // snapshot so a reference to a mangled private nested class (or a
    // renamed file-private type) still resolves scope-true.
    const prev_renames = ir.build.setLowerAnonScopeRenames(scope_renames);
    defer _ = ir.build.setLowerAnonScopeRenames(prev_renames);
    const prev_classes = ir.build.setLowerAnonScopeClasses(scope_classes);
    defer _ = ir.build.setLowerAnonScopeClasses(prev_classes);
    const prev_caps = ir.build.setLowerAnonCaptureNames(captured_names);
    defer _ = ir.build.setLowerAnonCaptureNames(prev_caps);
    const obj = expr.ObjectExpr;
    const members = obj.members;
    const supertypes = obj.supertypes;
    const supertype_args = obj.supertype_args;

    const capture_pairs = try buildCapturePairs(allocator, captured_names, captures);
    // The pair array is consumed here (its retained values move into the
    // instance's `anon_captures`); free the array spine at exit. The values are
    // NOT freed here — the instance owns them now.
    defer if (runtime.freeScratch()) allocator.free(capture_pairs);
    const identity = nextInstanceId(self);
    // Site-stable class name: shared by every instantiation of this `object`
    // expression so the class/method registries don't grow per instance.
    const synth_class_name = anonSiteName(expr);
    // Whether this site's class + methods are already registered (a prior
    // instantiation built them). On a hit the per-method lowering and the
    // class-def construction are skipped — only the per-instance captures,
    // field/super-arg initializers, and instance allocation run.
    const site_built = blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().contains(synth_class_name);
    };
    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
        std.debug.print("[ANON] site name={s} built={} ptr=0x{x} members={d}\n", .{ synth_class_name, site_built, @intFromPtr(expr), members.len });
    }

    // One image clone per synthesis call, shared by every lowering below.
    var site_mod: ?ObjRef(Module) = null;
    defer if (site_mod) |m| m.deinit();

    // Collect the anon object's own + inherited + enclosing member names so
    // bare identifiers inside method bodies resolve through `this`.
    var own_members = StringSet.init(allocator);
    defer own_members.deinit();
    for (members) |*m| {
        switch (m.*) {
            .Property => |p| try own_members.put(p.name.name, {}),
            .Function => |*f| try own_members.put(f.name.name, {}),
            else => {},
        }
    }
    for (supertypes) |*sup| {
        const sup_name = ir.build.anonScopeRename(sup.name.name) orelse sup.name.name;
        const pdef = classDefByName(self, sup_name) orelse continue;
        defer pdef.deinit();
        const dg = pdef.borrow();
        defer dg.deinit();
        for (dg.get().primary_params) |p| try own_members.put(p.name, {});
        for (dg.get().body_properties) |p| try own_members.put(p.name, {});
        for (dg.get().methods) |me| try own_members.put(me.name, {});
    }
    if (findCapture(capture_pairs, "this")) |tv| {
        if (tv == .Instance) {
            const ig = tv.Instance.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            for (cg.get().primary_params) |p| try own_members.put(p.name, {});
            for (cg.get().body_properties) |p| try own_members.put(p.name, {});
            for (cg.get().methods) |me| try own_members.put(me.name, {});
        }
    }

    // A CALLABLE the object closes over whose name matches a top-level
    // *extension* fn must NOT be value-captured; drop it so a bare call in
    // the body resolves through the global/member path. But a captured
    // name that the object *overrides* (a member of its own class or a
    // supertype, e.g. the crossinline `iterator` param behind
    // `Iterable { … }`) shadows that member and must stay value-captured,
    // or the override would recurse. A NON-callable captured value stays
    // captured regardless: it can never serve the extension call, and a
    // value READ of the name (a local `val read` used as `read.add(x)`)
    // must see the local — Kotlin scoping puts the local first.
    var anon_cap_set = StringSet.init(allocator);
    for (captured_names) |n| {
        var names_extension = false;
        const mg = self.module.borrow();
        const m = mg.get();
        for (m.funcsBySimpleName(n)) |fid| {
            if (m.funcById(fid)) |f| {
                if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) {
                    names_extension = true;
                    break;
                }
            }
        }
        mg.deinit();
        const captured_callable = if (findCapture(capture_pairs, n)) |v| switch (v) {
            .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
            else => false,
        } else false;
        if (!names_extension or !captured_callable or own_members.contains(n)) try anon_cap_set.put(n, {});
    }
    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
        std.debug.print("[ANON] site={s} captured=", .{synth_class_name});
        for (captured_names) |n| std.debug.print("{s},", .{n});
        std.debug.print("\n", .{});
    }
    ir.lower.setLowerAnonCaptures(anon_cap_set);
    // `setLowerAnonCaptures` takes ownership; clear it after lowering.

    // The anon class's property type heads, carried into the member
    // lowerings: a declared annotation as written, an un-annotated
    // initializer derived from the CAPTURED value's runtime class —
    // `val iterator = sequence.iterator()` resolves `iterator` on the
    // captured sequence's class and records the declared return's head, so
    // the sibling `hasNext()`/`next()` bodies type their bare `iterator`
    // reads and bind statically. `KLIO_ANON_PROP=0` disables.
    var prop_heads: std.ArrayList(ir.build.AnonPropHead) = .empty;
    defer prop_heads.deinit(allocator);
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_ANON_PROP") orelse "1", "0")) {
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.ty) |*ty| {
                try prop_heads.append(allocator, .{
                    .owner = synth_class_name,
                    .name = p.name.name,
                    .head = ty.name.name,
                });
                continue;
            }
            const init_expr: *const ast.Expr = if (p.init) |*e| e else continue;
            const head: ?[]const u8 = blk: {
                if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
                    const v = findCapture(capture_pairs, init_expr.Path.segments[0].name) orelse break :blk null;
                    break :blk v.typeFqn();
                }
                if (init_expr.* != .Call) break :blk null;
                const callee = init_expr.Call.callee;
                if (callee.* != .Member) break :blk null;
                const recv = callee.Member.receiver;
                if (recv.* != .Path or recv.Path.segments.len != 1) break :blk null;
                // The receiver reaches the body either as a direct value
                // capture or as a FIELD of the captured enclosing `this`
                // (an outer-class ctor property like `sequence`).
                const rv: Value = findCapture(capture_pairs, recv.Path.segments[0].name) orelse rblk: {
                    const tv = findCapture(capture_pairs, "this") orelse break :blk null;
                    if (tv != .Instance) break :blk null;
                    const ig = tv.Instance.borrow();
                    defer ig.deinit();
                    for (ig.get().fields.items) |fld| {
                        if (std.mem.eql(u8, fld.name, recv.Path.segments[0].name)) break :rblk fld.value;
                    }
                    break :blk null;
                };
                const mg = self.module.borrow();
                defer mg.deinit();
                const module = mg.get();
                const owner_cid = module.classIdByFqn(rv.typeFqn()) orelse break :blk null;
                const recv_ref: ir.TypeRef = .{ .name = rv.typeFqn(), .nullable = false, .args = &.{} };
                const resolved = module.resolveMemberCall(owner_cid, callee.Member.name.name, &.{}, .{
                    .caller_file = obj.span.file,
                    .lexical_owner = null,
                    .actual_type_param_bounds = &.{},
                    .receiver_type = recv_ref,
                });
                const target = resolved.target orelse break :blk null;
                const f = module.funcById(target) orelse break :blk null;
                var h = std.mem.trimEnd(u8, f.return_ty.name, "?");
                if (std.mem.indexOfScalar(u8, h, '<')) |lt| h = h[0..lt];
                if (h.len == 0 or std.mem.eql(u8, h, "Unit")) break :blk null;
                // A return left as the owner's own type parameter names no
                // class and types nothing.
                if (module.classIdByFqn(h) == null and module.uniqueClassIdBySimpleName(h) == null) break :blk null;
                break :blk h;
            };
            if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                std.debug.print("[ANON] prop {s}.{s} head={s}\n", .{ synth_class_name, p.name.name, head orelse "<none>" });
            }
            if (head) |h| {
                try prop_heads.append(allocator, .{
                    .owner = synth_class_name,
                    .name = p.name.name,
                    .head = h,
                });
            }
        }
    }
    const prev_prop_heads = ir.build.setLowerAnonPropHeads(prop_heads.items);
    defer _ = ir.build.setLowerAnonPropHeads(prev_prop_heads);

    // Lower each method + getter into the shared `anon_methods` registry
    // (once per site, on the first instantiation). The shared side module's
    // appends serialize under the anon-lower lock, held for the lowering
    // sections only.
    // Type parameters of the function whose body the `object` expression
    // sits in: its members' declared types reference them as type VARIABLES
    // (`ConcurrentSet<Key>()`'s `add(element: Key)`), so each lowered method
    // registers them for the dispatch-side adjudicators — otherwise an
    // unrelated registered class of the same simple name (`Key`) refutes
    // perfectly valid arguments.
    const inherited_tps: []const []const u8 =
        if (site_built) &.{} else ir.eval.currentFrameTypeParams();
    anonLowerEnter();
    // Occurrence counter per `name#arity`: two same-arity overloads of one
    // name share that key, so each also registers under an indexed key.
    var overload_seen = std.StringHashMap(usize).init(allocator);
    defer overload_seen.deinit();
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.body == null) {
                    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                        std.debug.print("[ANON] skip bodyless fn {s}.{s}\n", .{ synth_class_name, f.name.name });
                    }
                    continue;
                }
                if (site_built) continue; // methods already registered for this site
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, f, synth_class_name, &own_members);
                const fid = func.id;
                const tbl = self.anon_methods.borrowMut();
                inheritAnonTypeParams(self, inherited_tps, fid);
                const arity_name = try std.fmt.allocPrint(allocator, "{s}#{d}", .{ f.name.name, f.params.len });
                const gop = try overload_seen.getOrPut(arity_name);
                if (!gop.found_existing) gop.value_ptr.* = 0 else gop.value_ptr.* += 1;
                const overload_name = try root.anonOverloadMemberName(allocator, arity_name, gop.value_ptr.*);
                tbl.get().put(try anonKey(allocator, synth_class_name, overload_name), .{ .module = sub_ref.clone(), .func = fid, .captures = &.{} }) catch {};
                if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                    std.debug.print("[ANON] method {s}.{s} fid={d}\n", .{ synth_class_name, arity_name, fid.int() });
                }
                // Captures are stored per-instance (`InstanceData.anon_captures`),
                // not in this shared registry entry — the entry's method/module is
                // site-stable, the captures vary per object, and holding them here
                // would root every request's value graph forever.
                tbl.get().put(try anonKey(allocator, synth_class_name, arity_name), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                tbl.get().put(try anonKey(allocator, synth_class_name, f.name.name), .{ .module = sub_ref.clone(), .func = fid, .captures = &.{} }) catch {};
                tbl.deinit();
            },
            .Property => |p| {
                if (p.getter) |getter| if (!site_built) {
                    const thunk = synthThunk(p.name, getter.body, getter.return_type, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const fid = func.id;
                    if (runtime.envOnce("KLIO_ANON_AUDIT") != null) {
                        std.debug.print("[ANON] getter {s}.{s} fid={d}\n", .{ synth_class_name, p.name.name, fid.int() });
                    }
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
                // A `by`-delegated property registers a getter thunk that
                // dispatches `getValue` on the delegate instance (stored as a
                // `<name>$klio_delegate` field by the complex-init pass), so a
                // bare read inside a sibling member — or a qualified read from
                // outside — resolves instead of missing as a phantom field.
                if (p.delegate != null) if (!site_built) {
                    const dfield = try std.fmt.allocPrint(allocator, "{s}$klio_delegate", .{p.name.name});
                    const recv_expr = try allocator.create(ast.Expr);
                    const segs = try allocator.alloc(ast.Ident, 1);
                    segs[0] = .{ .name = dfield, .span = p.name.span };
                    recv_expr.* = .{ .Path = .{ .segments = segs, .span = p.name.span } };
                    const callee = try allocator.create(ast.Expr);
                    callee.* = .{ .Member = .{
                        .receiver = recv_expr,
                        .name = .{ .name = "getValue", .span = p.name.span },
                        .safe = false,
                        .span = p.name.span,
                    } };
                    const call_args = try allocator.alloc(ast.Expr, 2);
                    call_args[0] = .{ .NullLit = .{ .span = p.name.span } };
                    call_args[1] = .{ .NullLit = .{ .span = p.name.span } };
                    const arg_names = try allocator.alloc(?[]const u8, 2);
                    arg_names[0] = null;
                    arg_names[1] = null;
                    const body_expr: ast.Expr = .{ .Call = .{
                        .callee = callee,
                        .args = call_args,
                        .arg_names = arg_names,
                        .type_args = &.{},
                        .is_infix = false,
                        .span = p.name.span,
                    } };
                    const thunk = synthThunk(p.name, .{ .Expr = body_expr }, p.ty, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const key = try std.fmt.allocPrint(allocator, "$get${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = func.id, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
                // A custom setter registers its 1-arg thunk symmetrically, so
                // `obj.x = v` dispatches the override (`drawContext.canvas =
                // canvas` writing through to the wrapped drawParams) instead of
                // landing on a phantom raw field.
                if (p.setter) |setter| if (!site_built) {
                    const vp: ast.Ident = if (setter.params.len != 0) setter.params[0] else .{ .name = "value", .span = p.name.span };
                    const thunk = try synthSetterThunk(allocator, p.name, vp, setter.body, p.is_override);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                    const fid = func.id;
                    const key = try std.fmt.allocPrint(allocator, "$set${s}", .{p.name.name});
                    const tbl = self.anon_methods.borrowMut();
                    tbl.get().put(try anonKey(allocator, synth_class_name, key), .{ .module = sub_ref, .func = fid, .captures = &.{} }) catch {};
                    tbl.deinit();
                };
            },
            else => {},
        }
    }

    anonLowerExit();

    // The complex property-init / `init { … }` / supertype-ctor-arg thunks are
    // site-stable: lower them once and cache (keyed by the AST site), reuse
    // after. The cached sub-modules are kept alive by `gcMarkAnonSites`.
    const site_key = @intFromPtr(expr);
    var complex_prop_inits: []const AnonComplexInit = &.{};
    var init_thunks: []const AnonInitThunk = &.{};
    var super_arg_thunks: []const []const ?AnonSuperArgThunk = &.{};
    var delegate_thunks: []const ?AnonDelegateThunk = &.{};
    if (anonSiteThunksGet(site_key)) |cached| {
        complex_prop_inits = cached.complex_prop_inits;
        init_thunks = cached.init_thunks;
        super_arg_thunks = cached.super_arg_thunks;
        delegate_thunks = cached.delegate_thunks;
        ir.lower.setLowerAnonCaptures(null);
    } else {
        anonLowerEnter();
        defer anonLowerExit();
        // Complex property initializers: anything past a literal or a bare
        // captured name evaluates through a lowered thunk.
        var complex_local: std.ArrayList(AnonComplexInit) = .empty;
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            if (p.delegate) |*dexpr| {
                const dfield = try std.fmt.allocPrint(allocator, "{s}$klio_delegate", .{p.name.name});
                const thunk_name: ast.Ident = .{
                    .name = try std.fmt.allocPrint(allocator, "$init${s}", .{dfield}),
                    .span = p.name.span,
                };
                const thunk = synthThunk(thunk_name, .{ .Expr = dexpr.*.* }, null, false);
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
                try complex_local.append(allocator, .{ .name = dfield, .module = sub_ref, .func = func.id });
                continue;
            }
            const init_expr: *const ast.Expr = if (p.init) |*e|
                e
            else if (p.explicit_field) |ef|
                (if (ef.init) |*finit| finit else continue)
            else
                continue;
            const is_lit = (try simpleLiteral(allocator, init_expr)) != null;
            if (is_lit) continue;
            // A bare one-segment name resolvable from the captured scope is
            // filled directly at field init below. Any other bare name (a
            // top-level property, an object singleton, a class reference) must
            // evaluate through a lowered thunk like every other initializer —
            // the capture pairs alone cannot resolve it.
            if (bareCaptureResolvable(init_expr, capture_pairs)) continue;
            const thunk_name: ast.Ident = .{
                .name = try std.fmt.allocPrint(allocator, "$init${s}", .{p.name.name}),
                .span = p.name.span,
            };
            const thunk = synthThunk(thunk_name, .{ .Expr = init_expr.* }, null, false);
            const sub_ref = try anonSiteModule(self, allocator, &site_mod);
            const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
            try complex_local.append(allocator, .{ .name = p.name.name, .module = sub_ref, .func = func.id });
        }

        // `init { … }` blocks lower as 0-arg method thunks over `this`, each
        // tagged with the number of properties declared before it so the run
        // below interleaves blocks and property initializers in declaration
        // order.
        var init_local: std.ArrayList(AnonInitThunk) = .empty;
        for (obj.init_blocks, 0..) |*blk, idx| {
            const member_pos = if (idx < obj.init_block_positions.len) obj.init_block_positions[idx] else members.len;
            const upto = @min(member_pos, members.len);
            var prop_pos: usize = 0;
            for (members[0..upto]) |*m| {
                if (m.* == .Property) prop_pos += 1;
            }
            const thunk_name: ast.Ident = .{
                .name = try std.fmt.allocPrint(allocator, "$init$block${d}", .{idx}),
                .span = blk.span,
            };
            const thunk = synthThunk(thunk_name, .{ .Block = blk.* }, null, false);
            const sub_ref = try anonSiteModule(self, allocator, &site_mod);
            const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &own_members);
            try init_local.append(allocator, .{ .module = sub_ref, .func = func.id, .prop_pos = prop_pos });
        }

        // A thunk for every supertype ctor arg the captured scope cannot
        // resolve directly: `object : Base(g + 1)` evaluates `g + 1` for real.
        // These run against the *enclosing* `this` — a super arg is evaluated
        // before the object exists and never sees its members, so they lower
        // with no own-member set.
        const super_local = try allocator.alloc([]const ?AnonSuperArgThunk, supertypes.len);
        {
            var no_members = StringSet.init(allocator);
            defer no_members.deinit();
            for (supertypes, 0..) |_, si| {
                const arg_exprs: []const ast.Expr = blk: {
                    if (si < supertype_args.len) {
                        if (supertype_args[si]) |ae| break :blk ae;
                    }
                    break :blk &.{};
                };
                const slots = try allocator.alloc(?AnonSuperArgThunk, arg_exprs.len);
                for (arg_exprs, 0..) |*ae, ai| {
                    slots[ai] = null;
                    if ((try simpleLiteral(allocator, ae)) != null) continue;
                    if (bareCaptureResolvable(ae, capture_pairs)) continue;
                    // A bare class/interface name resolves to its companion at
                    // build time (`evalSuperArg`); the synthetic thunk module
                    // has no class registry to resolve the companion, so skip
                    // thunking it.
                    if (ae.* == .Path and ae.Path.segments.len == 1) {
                        const cn = ae.Path.segments[0].name;
                        const has_comp = blk2: {
                            const mg = self.module.borrow();
                            defer mg.deinit();
                            break :blk2 mg.get().registry.companion_singletons.get(cn) != null;
                        };
                        if (has_comp and findCapture(capture_pairs, cn) == null) continue;
                    }
                    const thunk_name: ast.Ident = .{
                        .name = try std.fmt.allocPrint(allocator, "$superarg${d}${d}", .{ si, ai }),
                        .span = obj.span,
                    };
                    const thunk = synthThunk(thunk_name, .{ .Expr = ae.* }, null, false);
                    const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                    const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &no_members);
                    slots[ai] = .{ .module = sub_ref, .func = func.id };
                }
                super_local[si] = slots;
            }
        }

        // Supertype-delegate initializers (`object : Iface by <expr> {}`):
        // anything past a bare captured name evaluates through a lowered
        // thunk against the ENCLOSING scope, like a super-ctor arg. The
        // result lands in the `__delegate__<Iface>` field below.
        const del_local = try allocator.alloc(?AnonDelegateThunk, supertypes.len);
        {
            var no_members2 = StringSet.init(allocator);
            defer no_members2.deinit();
            for (supertypes, 0..) |_, si| {
                del_local[si] = null;
                if (si >= obj.supertype_delegates.len) continue;
                const de = obj.supertype_delegates[si] orelse continue;
                if (bareCaptureResolvable(&de, capture_pairs)) continue;
                const thunk_name: ast.Ident = .{
                    .name = try std.fmt.allocPrint(allocator, "$delegate${d}", .{si}),
                    .span = obj.span,
                };
                const thunk = synthThunk(thunk_name, .{ .Expr = de }, null, false);
                const sub_ref = try anonSiteModule(self, allocator, &site_mod);
                const func = try ir.lower.lowerMethod(&sub_ref.cell.data, &thunk, synth_class_name, &no_members2);
                del_local[si] = .{ .module = sub_ref, .func = func.id };
            }
        }
        ir.lower.setLowerAnonCaptures(null);

        // Copy the spines into permanent storage so `gcMarkAnonSites` can read
        // them cross-thread and the lowered sub-modules are rooted (reused, not
        // re-lowered, by every later instantiation).
        const pa = std.heap.page_allocator;
        const cpi_perm = pa.dupe(AnonComplexInit, complex_local.items) catch @panic("KGC: anon-site thunk cache alloc failed");
        const it_perm = pa.dupe(AnonInitThunk, init_local.items) catch @panic("KGC: anon-site thunk cache alloc failed");
        const sat_perm = pa.alloc([]const ?AnonSuperArgThunk, super_local.len) catch @panic("KGC: anon-site thunk cache alloc failed");
        for (super_local, 0..) |slots, i| sat_perm[i] = pa.dupe(?AnonSuperArgThunk, slots) catch @panic("KGC: anon-site thunk cache alloc failed");
        const del_perm = pa.dupe(?AnonDelegateThunk, del_local) catch @panic("KGC: anon-site thunk cache alloc failed");
        // The per-call spine arrays are dead now (the modules they referenced
        // live on, by value, in the permanent copies).
        if (runtime.freeScratch()) {
            complex_local.deinit(allocator);
            init_local.deinit(allocator);
            for (super_local) |slots| allocator.free(slots);
            allocator.free(super_local);
            allocator.free(del_local);
        }
        const winner = anonSiteThunksPut(site_key, .{
            .complex_prop_inits = cpi_perm,
            .init_thunks = it_perm,
            .super_arg_thunks = sat_perm,
            .delegate_thunks = del_perm,
        });
        complex_prop_inits = winner.complex_prop_inits;
        init_thunks = winner.init_thunks;
        super_arg_thunks = winner.super_arg_thunks;
        delegate_thunks = winner.delegate_thunks;
    }

    // The anon ClassDef is site-stable: on a hit, reuse the one a prior
    // instantiation registered; on a miss, build it and register it under the
    // site name (the per-instance captures and field values are applied below,
    // not stored in the class).
    const class_def = if (site_built) blk: {
        const g = self.classes.borrow();
        defer g.deinit();
        break :blk g.get().get(synth_class_name).?.clone();
    } else blk: {
        // Body-property defs from the object's own properties.
        var body_props: std.ArrayList(PropertyDef) = .empty;
        for (members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            const storage_init: ?*const ast.Expr = if (p.init) |*e|
                e
            else if (p.explicit_field) |ef|
                (if (ef.init) |*finit| finit else null)
            else
                null;
            try body_props.append(allocator, .{
                .name = p.name.name,
                .mutable = p.mutable,
                .init = if (storage_init) |e| FF(ast.Expr).fromPtr(e) else null,
                .getter = if (p.getter) |g| FF(ast.Accessor).fromPtr(g) else null,
                .setter = if (p.setter) |s| FF(ast.Accessor).fromPtr(s) else null,
                .delegate = if (p.delegate) |e| FF(ast.Expr).fromPtr(e) else null,
                .is_abstract = p.is_abstract,
                .is_lateinit = p.is_lateinit,
                .primitive_zero = build.primitiveZeroFor(p),
            });
        }
        var supertype_names = try allocator.alloc([]const u8, supertypes.len);
        for (supertypes, 0..) |*t, i| {
            supertype_names[i] = ir.build.anonScopeRename(t.name.name) orelse sup: {
                // A qualified supertype (`object : Modifier.Node()`) names a
                // lifted nested class registered under its mangled name
                // (`Modifier$Node`). Recording the bare simple name would make
                // the inherited-method walk resolve ANY same-named class —
                // compose has several unrelated `Node`s.
                if (t.qualified_path) |qp| {
                    const mangled = try allocator.dupe(u8, qp);
                    for (mangled) |*ch| {
                        if (ch.* == '.') ch.* = '$';
                    }
                    if (classDefByName(self, mangled)) |def| {
                        def.deinit();
                        break :sup mangled;
                    }
                    allocator.free(mangled);
                }
                break :sup t.name.name;
            };
        }

        // First non-interface supertype as resolved parent class.
        var anon_parent: ?ObjRef(ClassDef) = null;
        for (supertype_names) |sn| {
            const def = classDefByName(self, sn) orelse continue;
            const is_iface = b2: {
                const dg = def.borrow();
                defer dg.deinit();
                break :b2 dg.get().is_interface;
            };
            if (!is_iface) {
                anon_parent = def;
                break;
            }
            def.deinit();
        }

        const env = try ObjRef(Env).init(allocator, Env.init(allocator));
        const cd = try ObjRef(ClassDef).init(allocator, .{
            .name = synth_class_name,
            .fqn = synth_class_name,
            .annotation_names = &.{},
            .primary_params = &.{},
            .methods = &.{},
            .body_properties = try body_props.toOwnedSlice(allocator),
            .init_blocks = &.{},
            .init_block_property_positions = &.{},
            .is_data = false,
            .is_value = false,
            .is_object = false,
            .is_enum = false,
            .is_sealed = false,
            .supertype_names = supertype_names,
            .parent = anon_parent,
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
            .captured_env = env,
            .supertype_delegates = &.{},
            .delegate_forwarders = &.{},
            .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        });
        {
            const g = self.classes.borrowMut();
            defer g.deinit();
            try g.get().put(synth_class_name, cd.clone());
        }
        break :blk cd;
    };
    // The synthesized anon class lives only in this stack local until it is
    // registered into `classes` (below) and adopted by the instance; pin it
    // across the body-property / super-arg initializer evals so a collection
    // there cannot sweep it (its `gc_trace` reaches its parent and captured env).
    const ka_class = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka_class);
    runtime.keepalivePushCell(&class_def.cell.hdr);

    // Initialise body-property fields.
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    {
        const cg = class_def.borrow();
        defer cg.deinit();
        for (cg.get().body_properties) |p| {
            // An abstract or getter/delegate-backed property has no backing
            // field; seeding a Null slot would shadow the overriding getter.
            if (p.is_abstract or p.getter != null or p.delegate != null) continue;
            var v: Value = .Null;
            if (p.init) |init_field| {
                const init_expr = init_field.get();
                if (try simpleLiteral(allocator, init_expr)) |lit| {
                    v = lit;
                } else if (init_expr.* == .Path and init_expr.Path.segments.len == 1) {
                    const nm = init_expr.Path.segments[0].name;
                    if (findCapture(capture_pairs, nm)) |cv| {
                        v = snapshotCapture(cv);
                    } else if (findCapture(capture_pairs, "this")) |tv| {
                        if (tv == .Instance) {
                            const ig = tv.Instance.borrow();
                            defer ig.deinit();
                            if (ig.get().get(nm)) |fv| v = fv;
                        }
                    }
                }
            } else if (p.primitive_zero) |pz| {
                v = pz;
            }
            try fields.append(allocator, .{ .name = p.name, .value = v });
        }
    }

    // Populate parent primary-param fields from supertype ctor args, and
    // stash each supertype's evaluated ctor args. A pre-lowered thunk
    // evaluates the arg in the enclosing scope (`this` is the captured
    // enclosing receiver, or Null at top level); the direct path covers
    // literals and captured names.
    var super_args_by_class = std.StringHashMap([]Value).init(allocator);
    defer super_args_by_class.deinit();
    var direct_parent: ?ObjRef(ClassDef) = null;
    defer if (direct_parent) |p| p.deinit();
    // A builtin throwable base (`class MyException : Exception("...")`) has
    // no ClassDef to run a constructor chain through; its arguments bind the
    // instance's `message`/`cause` once the instance exists.
    var throwable_args: ?[]const Value = null;
    for (supertypes, 0..) |*sup, idx| {
        const arg_exprs = if (idx < supertype_args.len) (supertype_args[idx] orelse continue) else continue;
        var vals = try allocator.alloc(Value, arg_exprs.len);
        for (arg_exprs, 0..) |*ae, ai| {
            if (idx < super_arg_thunks.len and ai < super_arg_thunks[idx].len and super_arg_thunks[idx][ai] != null) {
                const th = super_arg_thunks[idx][ai].?;
                const outer_this: Value = findCapture(capture_pairs, "this") orelse .Null;
                switch (try runAnonThunk(self, allocator, th.module, th.func, &outer_this, capture_pairs)) {
                    .ok => |v| vals[ai] = v,
                    .err => |e| return .{ .err = e },
                }
            } else {
                vals[ai] = try evalSuperArg(self, allocator, ae, capture_pairs);
            }
        }
        const resolved_name = blk: {
            const cg = class_def.borrow();
            defer cg.deinit();
            break :blk if (idx < cg.get().supertype_names.len) cg.get().supertype_names[idx] else sup.name.name;
        };
        const parent_def = classDefByName(self, resolved_name);
        if (parent_def == null) {
            const simple = if (std.mem.lastIndexOfScalar(u8, resolved_name, '.')) |d| resolved_name[d + 1 ..] else resolved_name;
            if (isBuiltinThrowableName(simple)) throwable_args = vals;
        }
        if (parent_def) |pdef| {
            defer pdef.deinit();
            var ordered = std.ArrayList(Value).fromOwnedSlice(vals);
            const arg_names = if (idx < obj.supertype_arg_names.len) obj.supertype_arg_names[idx] else null;
            switch (try reorderNamedSuperArgs(self, allocator, pdef, classDefFqn(pdef), classDefName(pdef), arg_names, &ordered, null)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            // The object-expression's superclass constructor call may select a
            // SECONDARY constructor (`object : Connector(source, source,
            // intent)` hits Connector's 3-arg `this(...)` that delegates to the
            // 6-arg primary). Expand it into the primary arguments before
            // padding, so the primary's property fields (`renderIntent`) get
            // the delegated value instead of a default — padding a secondary
            // arg list to the primary width filled the tail with nulls.
            switch (try expandParentSecondaryThisArgs(self, allocator, classDefFqn(pdef), classDefName(pdef), &ordered)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            switch (try padParentCtorDefaults(self, allocator, pdef, classDefFqn(pdef), classDefName(pdef), &ordered, null)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            vals = try packPrimaryCtorVarargs(self, classDefFqn(pdef), classDefName(pdef), try ordered.toOwnedSlice(allocator));
            try appendPrimaryCtorPropertyFields(allocator, &fields, pdef, vals);
            if (!classDefIsInterface(pdef) and direct_parent == null) direct_parent = pdef.clone();
        }
        try super_args_by_class.put(resolved_name, vals);
    }

    if (direct_parent) |pdef| {
        const direct_name = classDefName(pdef);
        if (super_args_by_class.get(direct_name)) |direct_args| {
            const outer_hint: ?Value = findCapture(capture_pairs, "this");
            switch (try extendAnonymousParentCtorArgs(
                self,
                allocator,
                pdef,
                direct_args,
                if (outer_hint) |*v| v else null,
                &fields,
                &super_args_by_class,
            )) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
    }

    const outer: ?Value = findCapture(capture_pairs, "this");
    // `outer` is an owned field of the instance (its teardown releases it);
    // `findCapture` returns a borrow, so retain before adopting it.
    if (outer) |o| o.retain();
    // Move the captures onto the instance: it owns the refs `buildCapturePairs`
    // retained (released on teardown). The `capture_pairs` array itself is freed
    // at function exit; the values live on in `anon_caps`.
    const anon_caps = try allocator.alloc(InstanceData.Capture, capture_pairs.len);
    for (capture_pairs, 0..) |p, i| anon_caps[i] = .{ .name = p.name, .value = p.value };
    const anon_enclosing = try ir.eval.captureChainAlloc(allocator);
    if (runtime.reclaimEnabled()) {
        for (anon_enclosing) |e| e.v.retain();
    }
    const inst = try ObjRef(InstanceData).init(allocator, .{
        .class = class_def,
        .fields = fields,
        .outer = outer,
        .identity = identity,
        .native_state = null,
        .anon_captures = anon_caps,
        .anon_enclosing = anon_enclosing,
    });
    if (throwable_args) |ta| try bindThrowableArgs(self, inst, ta, true);
    const inst_value: Value = .{ .Instance = inst.clone() };

    // Run the concrete superclass chain's body-property initializers.
    var parent_chain: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (parent_chain.items) |c| c.deinit();
        parent_chain.deinit(allocator);
    }
    {
        var cur: ?ObjRef(ClassDef) = blk: {
            const ig = inst.borrow();
            defer ig.deinit();
            const cg = ig.get().class.borrow();
            defer cg.deinit();
            break :blk if (cg.get().parent) |p| p.clone() else null;
        };
        var step: usize = 0;
        while (cur) |c| {
            if (step > 128) {
                c.deinit();
                break;
            }
            step += 1;
            const next = blk: {
                const cg = c.borrow();
                defer cg.deinit();
                break :blk if (cg.get().parent) |p| p.clone() else null;
            };
            try parent_chain.append(allocator, c);
            cur = next;
        }
    }
    // Bottom-up so a parent's field exists before a nearer ancestor. Each
    // parent's `init { … }` blocks run interleaved with its body-property
    // initializers in declaration order, exactly as in a named
    // construction (`runInitBlocksAt`).
    var super_chain_entries: std.ArrayList(ChainEntry) = .empty;
    defer super_chain_entries.deinit(allocator);
    for (parent_chain.items) |c| {
        const cg = c.borrow();
        const cname = cg.get().name;
        cg.deinit();
        try super_chain_entries.append(allocator, .{
            .name = cname,
            .args = super_args_by_class.get(cname) orelse &.{},
        });
    }
    var ci: usize = parent_chain.items.len;
    while (ci > 0) {
        ci -= 1;
        const cls = parent_chain.items[ci];
        const cls_name = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        };
        const cls_fqn = classDefFqn(cls);
        const cls_args: []Value = super_args_by_class.get(cls_name) orelse &.{};
        const props = blk: {
            const cg = cls.borrow();
            defer cg.deinit();
            break :blk try allocator.dupe(PropertyDef, cg.get().body_properties);
        };
        // The dupe is a shallow array of `PropertyDef` (each field a borrow into
        // the class def / AST); free the array spine once this level is built.
        defer if (runtime.freeScratch()) allocator.free(props);
        for (props, 0..) |p, pi| {
            switch (try runInitBlocksAt(self, cls, pi, &inst_value, super_chain_entries.items, cls_args)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
            const fid = bodyPropInit(self, cls_fqn, cls_name, p.name) orelse continue;
            const mg = self.module.borrow();
            const m = mg.get();
            const func = m.funcById(fid) orelse {
                mg.deinit();
                continue;
            };
            mg.deinit();
            var all: std.ArrayList(Value) = .empty;
            try all.append(allocator, inst_value);
            try all.appendSlice(allocator, cls_args);
            const module_ref = self.module.clone();
            served: {
                const mg2 = module_ref.borrow();
                const v = trivialInitServe(allocator, mg2.get(), func, all.items) catch |e| {
                    mg2.deinit();
                    module_ref.deinit();
                    return e;
                } orelse {
                    mg2.deinit();
                    break :served;
                };
                mg2.deinit();
                module_ref.deinit();
                all.deinit(allocator);
                const already = blk: {
                    const ig = inst.borrow();
                    defer ig.deinit();
                    break :blk ig.get().get(p.name) != null;
                };
                if (!already) {
                    const ig = inst.borrowMut();
                    defer ig.deinit();
                    try ig.get().define(allocator, p.name, v);
                } else if (runtime.reclaimEnabled()) v.release(allocator);
                continue;
            }
            vmhost.emitPath(allocator, "object_build", func.fqn, fid, &inst_value, cls_args);
            const r = try ir.eval.evalWith(VmHost, allocator, module_ref.borrow().get(), func, all, self);
            module_ref.deinit();
            switch (r) {
                .ok => |v| {
                    const already = blk: {
                        const ig = inst.borrow();
                        defer ig.deinit();
                        break :blk ig.get().get(p.name) != null;
                    };
                    if (!already) {
                        const ig = inst.borrowMut();
                        defer ig.deinit();
                        try ig.get().define(allocator, p.name, v);
                    }
                },
                .err => |e| return .{ .err = e },
            }
        }
        switch (try runInitBlocksAt(self, cls, props.len, &inst_value, super_chain_entries.items, cls_args)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    // Run the anon object's own `init { … }` blocks and complex property
    // inits interleaved in declaration order: blocks positioned before a
    // property run before that property's initializer.
    var next_init: usize = 0;
    var prop_idx: usize = 0;
    for (members) |*m| {
        if (m.* != .Property) continue;
        while (next_init < init_thunks.len and init_thunks[next_init].prop_pos <= prop_idx) : (next_init += 1) {
            const it = init_thunks[next_init];
            switch (try runAnonThunk(self, allocator, it.module, it.func, &inst_value, capture_pairs)) {
                .ok => {},
                .err => |e| return .{ .err = e },
            }
        }
        prop_idx += 1;
        const pname = m.Property.name.name;
        const cpi: ?AnonComplexInit = blk: {
            for (complex_prop_inits) |c| {
                if (std.mem.eql(u8, c.name, pname)) break :blk c;
                // A delegated property's initializer stores the DELEGATE
                // instance under `<name>$klio_delegate`.
                if (c.name.len == pname.len + "$klio_delegate".len and
                    std.mem.startsWith(u8, c.name, pname) and
                    std.mem.endsWith(u8, c.name, "$klio_delegate"))
                {
                    break :blk c;
                }
            }
            break :blk null;
        };
        const c = cpi orelse continue;
        switch (try runAnonThunk(self, allocator, c.module, c.func, &inst_value, capture_pairs)) {
            .ok => |v| {
                const ig = inst.borrowMut();
                defer ig.deinit();
                try ig.get().define(allocator, c.name, v);
            },
            .err => |e| return .{ .err = e },
        }
    }
    while (next_init < init_thunks.len) : (next_init += 1) {
        const it = init_thunks[next_init];
        switch (try runAnonThunk(self, allocator, it.module, it.func, &inst_value, capture_pairs)) {
            .ok => {},
            .err => |e| return .{ .err = e },
        }
    }

    // Interface delegation (`object : Iface by expr {}`): store the delegate
    // value as a `__delegate__<Iface>` field so the member/field forwarders
    // reach it (a named class does this through its ctor; the runtime synthesis
    // here would otherwise drop it). A delegate that is a captured name resolves
    // through `capture_pairs`.
    {
        const delegates = obj.supertype_delegates;
        for (supertypes, 0..) |*sup, i| {
            if (i >= delegates.len) break;
            const de = delegates[i] orelse continue;
            var dv: ?Value = switch (de) {
                .Path => |p| if (p.segments.len == 1) findCapture(capture_pairs, p.segments[0].name) else null,
                else => null,
            };
            // Any other delegate expression (`object : RawSink by Buffer()
            // {}`) evaluates through its site-cached thunk.
            if (dv == null and i < delegate_thunks.len) {
                if (delegate_thunks[i]) |th| {
                    switch (try runAnonThunk(self, allocator, th.module, th.func, &inst_value, capture_pairs)) {
                        .ok => |v2| dv = v2,
                        .err => |e| return .{ .err = e },
                    }
                }
            }
            const v = dv orelse continue;
            const key = try std.fmt.allocPrint(allocator, "__delegate__{s}", .{sup.name.name});
            v.retain();
            const ig = inst.borrowMut();
            const already = ig.get().get(key) != null;
            if (!already) {
                try ig.get().fields.append(allocator, .{ .name = key, .value = v });
                ig.get().invalidateShape();
            } else {
                v.release(allocator);
            }
            ig.deinit();
        }
    }

    return .{ .ok = inst_value };
}

/// Run one lowered anon-object thunk: captures resolve through
/// `capture_pairs`, the enclosing scope's names are layered over globals
/// for the call's duration, and `inst_value` binds as `this` — the
/// instance under construction for property-init / `init`-block thunks,
/// the captured enclosing receiver (or Null) for supertype-ctor-arg
/// thunks, which run before the instance exists.
fn runAnonThunk(
    self: *VmHost,
    allocator: Allocator,
    mref: ObjRef(Module),
    fid: FuncId,
    inst_value: *const Value,
    capture_pairs: []const NameValue,
) Allocator.Error!EvalResult {
    const mg = mref.borrow();
    const sub_mod = mg.get();
    const func = sub_mod.funcById(fid) orelse {
        mg.deinit();
        return .{ .ok = .Unit };
    };
    const prev = self.globals.clone();
    if (capture_pairs.len != 0) {
        const scoped = try ObjRef(Env).init(allocator, Env.withParent(allocator, self.globals.clone()));
        const sg = scoped.borrowMut();
        for (capture_pairs) |nv| sg.get().define(nv.name, nv.value) catch {};
        sg.deinit();
        self.globals = scoped;
    }
    // Pin the active globals scope across the body eval (see the same pattern in
    // host_call_member): a transient capture-layer env is reachable only through
    // this stack-local field. Also pin the thunk's sub-module: it is a transient
    // cell held only by this stack-local `mref` (anon-object init/property/super
    // thunks lower into fresh side modules), and the eval frame keeps it as a raw
    // `*const Module` the collector cannot reach — so a collection during the
    // body would sweep it and dangle `frame.module`.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePushCell(&self.globals.cell.hdr);
    runtime.keepalivePushCell(&mref.cell.hdr);
    var cap_vec: std.ArrayList(Value) = .empty;
    for (func.capture_order) |cn| {
        if (std.mem.eql(u8, cn, "this")) {
            try cap_vec.append(allocator, inst_value.*);
        } else {
            try cap_vec.append(allocator, findCapture(capture_pairs, cn) orelse .Null);
        }
    }
    var all: std.ArrayList(Value) = .empty;
    try all.append(allocator, inst_value.*);
    vmhost.emitPath(allocator, "object_build", func.fqn, fid, inst_value, &.{});
    const r = try ir.eval.evalWithCaptures(VmHost, allocator, sub_mod, func, all, cap_vec, self);
    mg.deinit();
    self.globals.deinit();
    self.globals = prev;
    return r;
}

/// Evaluate a supertype ctor-arg expression to a value: literals, then a
/// bare captured name, then a field reached through the captured outer
/// `this`.
fn evalSuperArg(self: *VmHost, allocator: Allocator, expr: *const ast.Expr, capture_pairs: []const NameValue) Allocator.Error!Value {
    if (try simpleLiteral(allocator, expr)) |v| return v;
    if (expr.* == .Path and expr.Path.segments.len == 1) {
        const nm = expr.Path.segments[0].name;
        if (findCapture(capture_pairs, nm)) |v| return snapshotCapture(v);
        // A bare class/interface name in value position resolves to its
        // companion object — e.g. the CEH factory's
        // `AbstractCoroutineContextElement(CoroutineExceptionHandler)` passes
        // the interface's companion `Key`. (The super-arg thunk is skipped for
        // such names so this path runs, since the thunk's synthetic module has
        // no class registry to resolve the companion.)
        const comp_name: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.companion_singletons.get(nm);
        };
        if (comp_name) |cn| {
            switch (try host_globals.ensureObjectSingleton(self, cn)) {
                .ok => |maybe| if (maybe) |v| return v,
                .err => {},
            }
        }
        if (findCapture(capture_pairs, "this")) |tv| {
            if (tv == .Instance) {
                const ig = tv.Instance.borrow();
                defer ig.deinit();
                if (ig.get().get(nm)) |v| return v;
            }
        }
    }
    return .Null;
}

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "isIntrinsicClass / isBuiltinThrowableName classification" {
    try testing.expect(isIntrinsicClass("kotlin.text.StringBuilder"));
    try testing.expect(isIntrinsicClass("kotlin.Array"));
    try testing.expect(!isIntrinsicClass("com.example.Widget"));
    try testing.expect(isBuiltinThrowableName("CancellationException"));
    try testing.expect(isBuiltinThrowableNameNoCancel("IOException"));
    try testing.expect(!isBuiltinThrowableNameNoCancel("CancellationException"));
}

test "simpleLiteral resolves literal expr forms" {
    const a = testing.allocator;
    const span = @import("span");
    const f = span.FileId.from(0);
    const s = span.Span.init(f, 0, 1);
    var int_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = s } };
    const iv = (try simpleLiteral(a, &int_expr)).?;
    try testing.expectEqual(@as(i64, 7), iv.asI64().?);
    var bool_expr = ast.Expr{ .BoolLit = .{ .value = true, .span = s } };
    const bv = (try simpleLiteral(a, &bool_expr)).?;
    try testing.expect(bv.Bool);
    var null_expr = ast.Expr{ .NullLit = .{ .span = s } };
    const nv = (try simpleLiteral(a, &null_expr)).?;
    try testing.expect(nv == .Null);
}

test "ctor guard stack push/contains/pop" {
    try testing.expect(!ctorGuardContains("Foo"));
    ctorGuardPush("Foo");
    try testing.expect(ctorGuardContains("Foo"));
    ctorGuardPop();
    try testing.expect(!ctorGuardContains("Foo"));
}
