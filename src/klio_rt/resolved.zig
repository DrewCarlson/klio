//! The runtime a program `klio transpile --native` compiled from sema's
//! lowering links against. The program describes itself by id at startup:
//! its classes, the natives it calls, the host value kinds' classes, and
//! the functions the host may call back (a class's `toString` when a native
//! prints an instance, an exception's constructor when a native throws).
//! From that this builds a module of the resolved tables, with a stub body
//! per callback that calls the compiled function, and runs the program
//! inside a VM over it. Every host interaction (a native, a host member, an
//! operator on values whose kinds were not known statically, the exception
//! a native throws) then runs the interpreter's own code, and reaches the
//! program's classes through the same tables the interpreter reads.
//!
//! An entry that raises into the program calls its throw hook, which
//! unwinds to the program's handler; it does so only once its own work is
//! done, so the unwinding skips no Zig state.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir");
const stdlib = @import("stdlib");
const cli = @import("cli");

const interp_ir = cli.interp_ir;
const Vm = interp_ir.Vm;
const VmHost = interp_ir.VmHost;
const Value = runtime.Value;
const CValue = runtime.CValue;
const toC = runtime.toC;
const fromC = runtime.fromC;
const ObjRef = runtime.ObjRef;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const NativeId = ir.NativeId;
const MethodSlotId = ir.MethodSlotId;
const Resolved = ir.Resolved;

pub const NONE: u32 = std.math.maxInt(u32);

fn alloc() std.mem.Allocator {
    return std.heap.c_allocator;
}

const abi_mod = cli.cgen_abi;
pub const abi = abi_mod.abi;
pub const Flags = abi_mod.Flags;

export fn klio_r_abi() u64 {
    return abi;
}

// ---------------------------------------------------------------------------
// What the program describes (`klio_r_program` and its parts in the header)

pub const ClassDesc = extern struct {
    id: u32,
    name: [*:0]const u8,
    fqn: [*:0]const u8,
    flags: u32,
    n_slots: u32,
    slot_names: ?[*]const [*:0]const u8,
    seeds: ?[*]const u8,
    n_ancestors: u32,
    ancestors: ?[*]const u32,
    n_ancestor_names: u32,
    ancestor_names: ?[*]const [*:0]const u8,
    n_primary: u32,
    primary: ?[*]const [*:0]const u8,
    primary_mutable: ?[*]const u8,
    host_slot: u32,
};

/// A compiled function the host may call: 0 with its result in `out`, 1
/// with a throwable in `out`.
pub const Fn = *const fn (argv: [*]const CValue, argc: u32, out: *CValue) callconv(.c) i32;

/// A function the host may call: a compiled one (`fn`), or a native.
pub const FunctionDesc = extern struct {
    function: ?Fn,
    native: u32,
    arity: u32,
};

pub const DispatchDesc = extern struct { cls: u32, slot: u32, function: u32 };

pub const NativeDesc = extern struct {
    name: [*:0]const u8,
    /// The binding's table: 0 natives, 1 constructors, 2 the members the
    /// VM implements, 3 none.
    table: u32,
    key: [*:0]const u8,
    /// 1: a companion member the host implements as static; 2: an instance
    /// member whose receiver may hold a host value.
    flags: u32,
    reified: u32,
    /// -1 when the native takes no vararg.
    vararg_back: i32,
    op: u32,
};

/// An exception the host raises, and the program function that constructs
/// it; `fqn` names a host exception it stands for.
pub const RaisedDesc = extern struct { fqn: ?[*:0]const u8, cls: u32, function: u32 };

/// The exceptions the runtime itself raises, in `ProgramDesc.raised` order.
pub const Raise = abi_mod.Raise;

pub const ProgramDesc = extern struct {
    classes: [*]const ClassDesc,
    n_classes: u32,
    functions: [*]const FunctionDesc,
    n_functions: u32,
    dispatch: [*]const DispatchDesc,
    n_dispatch: u32,
    natives: [*]const NativeDesc,
    n_natives: u32,
    /// The slot of each base member a native calls back through, by
    /// `runtime.WellKnown`, `NONE` where the base declares none.
    well_known: [*]const u32,
    n_well_known: u32,
    /// One per `Raise`, `cls == NONE` where the program builds none.
    raised: [*]const RaisedDesc,
    n_raised: u32,
    by_fqn: [*]const RaisedDesc,
    n_by_fqn: u32,
    /// The host value kinds' classes: `scalars` in the order Unit, Boolean,
    /// Char, Byte, Short, Int, Long, Float, Double, UByte, UShort, UInt,
    /// ULong, String, Array; then by value kind, primitive array kind, range
    /// kind and function arity; and the root slot of `invoke` by arity.
    scalars: [*]const u32,
    by_tag: [*]const u32,
    n_tags: u32,
    prim_array: [*]const u32,
    n_prim: u32,
    range: [*]const u32,
    progression: [*]const u32,
    n_range: u32,
    function: [*]const u32,
    n_function: u32,
    invoke_slot: [*]const u32,
    n_invoke: u32,
    /// The root slots of `equals`, `hashCode` and `toString`, `NONE` for none.
    equals_slot: u32,
    hash_code_slot: u32,
    to_string_slot: u32,
    /// The base's `KlioMatchGroups`, `cls == NONE` where the program builds none.
    match_groups: RaisedDesc,
    /// Throws a throwable into the program; never returns.
    throw_value: *const fn (v: CValue) callconv(.c) noreturn,
};

// ---------------------------------------------------------------------------
// The module the program runs inside

var module_ref: ObjRef(ir.Module) = undefined;
var tables: *Resolved = undefined;
var functions: []const FunctionDesc = &.{};
var throw_hook: ?*const fn (v: CValue) callconv(.c) noreturn = null;
var vm: Vm = undefined;
/// Valid while the program runs.
var host: ?*VmHost = null;

fn module() *const ir.Module {
    return module_ref.asPtrConst();
}

/// The native every stub body calls: argument 0 is the index of the
/// compiled function to run over the rest.
const TRAMPOLINE: u32 = 0;

fn trampoline(ctx: *runtime.CallCtx) std.mem.Allocator.Error!runtime.EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Int) return .{ .err = .{ .Type = "a compiled function's stub lost its index" } };
    const i: usize = @intCast(ctx.args[0].Int);
    if (i >= functions.len) return .{ .err = .{ .Type = "a compiled function's index is past the program's table" } };
    const f = functions[i].function orelse return .{ .err = .{ .Type = "a native entry has no compiled function" } };
    const rest = ctx.args[1..];
    const argv = try alloc().alloc(CValue, @max(rest.len, 1));
    defer alloc().free(argv);
    for (rest, 0..) |v, k| argv[k] = toC(v);
    var out: CValue = undefined;
    const st = f(argv.ptr, @intCast(rest.len), &out);
    return if (st == 0) .{ .ok = fromC(out) } else .{ .err = .{ .Thrown = fromC(out) } };
}

fn unboundNative(ctx: *runtime.CallCtx) std.mem.Allocator.Error!runtime.EvalResult {
    _ = ctx;
    return .{ .err = .{ .Unbound = "no host function binds this native" } };
}

fn optSlot(raw: u32) ?MethodSlotId {
    return if (raw == NONE) null else MethodSlotId.from(raw);
}

fn optClass(raw: u32) ?ClassId {
    return if (raw == NONE) null else ClassId.from(raw);
}

fn buildDef(a: std.mem.Allocator, d: *const ClassDesc) !ObjRef(runtime.ClassDef) {
    var def = try minimalDef(a, std.mem.span(d.name), std.mem.span(d.fqn));
    const lslots = try a.alloc(runtime.LayoutSlot, d.n_slots);
    var i: u32 = 0;
    while (i < d.n_slots) : (i += 1) {
        const seed: ir.SlotSeed = if (d.seeds) |s| @enumFromInt(s[i]) else .null_ref;
        lslots[i] = .{ .name = if (d.slot_names) |ns| std.mem.span(ns[i]) else "", .seed = ir.resolved.seedValue(seed) };
    }
    const names = try a.alloc([]const u8, d.n_ancestor_names);
    i = 0;
    while (i < d.n_ancestor_names) : (i += 1) names[i] = std.mem.span(d.ancestor_names.?[i]);
    def.supertype_names = names;
    const f = d.flags;
    def.is_data = f & Flags.data != 0;
    def.is_value = f & Flags.value != 0;
    def.is_object = f & Flags.object != 0;
    def.is_enum = f & Flags.enum_ != 0;
    def.is_sealed = f & Flags.sealed != 0;
    def.is_interface = f & Flags.interface != 0;
    def.is_fun_interface = f & Flags.fun_interface != 0;
    def.is_open = f & Flags.open != 0;
    def.is_abstract = f & Flags.abstract != 0;
    def.is_inner = f & Flags.inner != 0;
    def.is_anonymous = f & Flags.anonymous != 0;
    def.is_annotation = f & Flags.annotation != 0;
    if (d.n_primary != 0) {
        const params = try a.alloc(runtime.ClassParamDef, d.n_primary);
        i = 0;
        while (i < d.n_primary) : (i += 1) params[i] = .{
            .property = switch (d.primary_mutable.?[i]) {
                0 => null,
                1 => false,
                else => true,
            },
            .name = std.mem.span(d.primary.?[i]),
            .default = null,
            .declared_type = null,
            .declared_shape = null,
        };
        def.primary_params = params;
    }
    def.ir_class = d.id;
    def.layout_slots = lslots;
    return ObjRef(runtime.ClassDef).init(a, def);
}

fn minimalDef(a: std.mem.Allocator, name: []const u8, fqn: []const u8) !runtime.ClassDef {
    return .{
        .name = name,
        .fqn = fqn,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(runtime.InstanceData)).init(a, null),
        .enclosing_class = try ObjRef(?ObjRef(runtime.ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(runtime.Env).init(a, runtime.Env.init(a)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(runtime.InstanceData)).init(a, null),
    };
}

fn raisedOf(d: RaisedDesc) ?ir.resolved.Raised {
    if (d.cls == NONE or d.function == NONE) return null;
    return .{ .class = ClassId.from(d.cls), .ctor = FuncId.from(d.function) };
}

/// The stub body of compiled function `i`, `arity` parameters: its index
/// and the parameters handed to the trampoline, the result returned.
fn stubBody(a: std.mem.Allocator, i: u32, arity: u32, const_id: ir.ConstId) ![]ir.Block {
    const insts = try a.alloc(ir.Inst, arity + 2);
    insts[0] = .{ .Const = .{ .dst = ir.Reg.from(0), .value = const_id } };
    var k: u32 = 0;
    while (k < arity) : (k += 1) insts[k + 1] = .{ .LoadParam = .{ .dst = ir.Reg.from(k + 1), .idx = @intCast(k) } };
    insts[arity + 1] = .{ .CallNative = .{ .dst = ir.Reg.from(arity + 1), .native = NativeId.from(TRAMPOLINE), .args = ir.Reg.from(0), .n_args = arity + 1 } };
    const blocks = try a.alloc(ir.Block, 1);
    blocks[0] = .{ .id = ir.BlockId.from(0), .insts = insts, .terminator = .{ .Return = ir.Reg.from(arity + 1) } };
    _ = i;
    return blocks;
}

/// The tables `ir.resolved.slotTarget` reads, from the program's dispatch:
/// every root the program dispatches on gets one index, and each class a
/// vtable holding its implementation there with the root it serves.
fn denseTables(a: std.mem.Allocator, r: *Resolved, dispatch: []const DispatchDesc, n_classes: u32) !void {
    var n_roots: u32 = 0;
    for (dispatch) |d| n_roots = @max(n_roots, d.slot + 1);
    const index = try a.alloc(u32, n_roots);
    @memset(index, ir.resolved.NONE);
    const iface = try a.alloc(u32, n_roots);
    @memset(iface, ir.resolved.NONE);
    var n_slots: u32 = 0;
    for (dispatch) |d| if (index[d.slot] == ir.resolved.NONE) {
        index[d.slot] = n_slots;
        n_slots += 1;
    };
    const vtables = try a.alloc(ir.resolved.VSlot, @as(usize, n_classes) * n_slots);
    @memset(vtables, .{});
    for (dispatch) |d| {
        if (d.cls >= n_classes) continue;
        vtables[@as(usize, d.cls) * n_slots + index[d.slot]] = .{ .root = d.slot, .func = d.function };
    }
    for (r.classes, 0..) |*c, k| c.vtable = vtables[k * n_slots ..][0..n_slots];
    r.slot_index = index;
    r.slot_iface = iface;
}

fn buildProgram(p: *const ProgramDesc) !void {
    const a = alloc();
    // The natives bind as `klio run` binds them: the stdlib's and every
    // installed pack's host functions.
    _ = cli.sema_cmd_mod.hostBinding(a);
    var m = ir.Module.init(a);
    const r = try a.create(Resolved);
    r.* = .{};

    var max_class: u32 = 0;
    for (p.classes[0..p.n_classes]) |d| max_class = @max(max_class, d.id + 1);
    const scalars = p.scalars[0..15];
    for (scalars) |c| if (c != NONE) {
        max_class = @max(max_class, c + 1);
    };
    const dummy = try ObjRef(runtime.ClassDef).init(a, try minimalDef(a, "", ""));
    const classes = try a.alloc(ir.resolved.ClassRt, max_class);
    for (classes) |*c| c.* = .{ .def = dummy };
    try m.class_ancestors.ensureTotalCapacity(a, max_class);
    var i: u32 = 0;
    while (i < max_class) : (i += 1) m.class_ancestors.appendAssumeCapacity(&.{});
    for (p.classes[0..p.n_classes]) |*d| {
        const seeds = try a.alloc(ir.SlotSeed, d.n_slots);
        for (seeds, 0..) |*s, k| s.* = if (d.seeds) |sd| @enumFromInt(sd[k]) else .null_ref;
        classes[d.id] = .{ .def = try buildDef(a, d), .seeds = seeds, .host_slot = d.host_slot };
        const anc = try a.alloc(ClassId, d.n_ancestors + 1);
        anc[0] = ClassId.from(d.id);
        for (anc[1..], 0..) |*x, k| x.* = ClassId.from(d.ancestors.?[k]);
        std.mem.sort(ClassId, anc, {}, struct {
            fn lt(_: void, x: ClassId, y: ClassId) bool {
                return x.int() < y.int();
            }
        }.lt);
        m.class_ancestors.items[d.id] = anc;
    }
    r.classes = classes;

    // Natives: the trampoline, then the program's, as it numbers them.
    const natives = try a.alloc(ir.resolved.NativeRt, p.n_natives + 1);
    natives[TRAMPOLINE] = .{ .func = trampoline, .name = "<compiled function>" };
    for (p.natives[0..p.n_natives], natives[1..]) |d, *n| {
        n.* = .{
            .func = unboundNative,
            .name = std.mem.span(d.name),
            .table = switch (d.table) {
                0 => .natives,
                1 => .constructors,
                2 => .members,
                4 => .tries,
                else => .unbound,
            },
            .key = std.mem.span(d.key),
            .reified = @intCast(d.reified),
            .vararg_back = if (d.vararg_back >= 0) @intCast(d.vararg_back) else null,
            .op = @enumFromInt(d.op),
            .static_ = d.flags & 1 != 0,
            .receiver = d.flags & 2 != 0,
        };
        _ = ir.bridge.rebindNative(n, cli.sema_cmd_mod.hostNative, stdlib.constructorNative, interp_ir.hostMemberFn, interp_ir.hostMemberTry);
    }
    r.natives = natives;

    // One function per entry: a stub body calling the compiled function,
    // or a header whose native runs.
    functions = p.functions[0..p.n_functions];
    const func_native = try a.alloc(NativeId, p.n_functions);
    for (functions, 0..) |f, k| {
        const id = FuncId.from(@intCast(k));
        const cid: ir.ConstId = ir.ConstId.from(@intCast(m.consts.items.len));
        try m.consts.append(a, .{ .Int = @intCast(k) });
        const params = try a.alloc(ir.Param, f.arity);
        for (params) |*pp| pp.* = .{ .name = "", .ty = .{ .name = "", .nullable = true, .args = &.{} }, .default = null };
        const compiled = f.function != null;
        func_native[k] = if (compiled) .none else NativeId.from(f.native + 1);
        try m.funcs.append(a, .{
            .id = id,
            .name = "<compiled>",
            .fqn = "<compiled>",
            .params = params,
            .return_ty = .{ .name = "", .nullable = true, .args = &.{} },
            .n_locals = f.arity + 2,
            .blocks = if (compiled) try stubBody(a, @intCast(k), f.arity, cid) else &.{},
            .entry = ir.BlockId.from(0),
            .is_suspend = false,
        });
    }
    r.func_native = func_native;
    for (p.dispatch[0..p.n_dispatch]) |d| {
        try m.method_dispatch.put(ir.Module.methodDispatchKey(ClassId.from(d.cls), MethodSlotId.from(d.slot)), FuncId.from(d.function));
    }
    try denseTables(a, r, p.dispatch[0..p.n_dispatch], @intCast(max_class));

    for (&r.well_known.values, 0..) |*wk, k| wk.* = if (k < p.n_well_known) optSlot(p.well_known[k]) else null;

    const h = &r.host_class;
    h.unit = optClass(scalars[0]);
    h.boolean = optClass(scalars[1]);
    h.char = optClass(scalars[2]);
    h.byte = optClass(scalars[3]);
    h.short = optClass(scalars[4]);
    h.int = optClass(scalars[5]);
    h.long = optClass(scalars[6]);
    h.float = optClass(scalars[7]);
    h.double = optClass(scalars[8]);
    h.ubyte = optClass(scalars[9]);
    h.ushort = optClass(scalars[10]);
    h.uint = optClass(scalars[11]);
    h.ulong = optClass(scalars[12]);
    h.string = optClass(scalars[13]);
    h.array = optClass(scalars[14]);
    for (h.by_tag[0..@min(p.n_tags, h.by_tag.len)], 0..) |*x, k| x.* = optClass(p.by_tag[k]);
    for (h.prim_array[0..@min(p.n_prim, h.prim_array.len)], 0..) |*x, k| x.* = optClass(p.prim_array[k]);
    for (h.range[0..@min(p.n_range, h.range.len)], 0..) |*x, k| {
        x.* = optClass(p.range[k]);
        h.progression[k] = optClass(p.progression[k]);
    }
    const fns = try a.alloc(ClassId, p.n_function);
    for (fns, 0..) |*x, k| x.* = ClassId.from(p.function[k]);
    h.function = fns;
    const inv = try a.alloc(MethodSlotId, p.n_invoke);
    for (inv, 0..) |*x, k| x.* = MethodSlotId.from(p.invoke_slot[k]);
    h.invoke_slot = inv;
    h.equals_slot = optSlot(p.equals_slot);
    h.hash_code_slot = optSlot(p.hash_code_slot);
    h.to_string_slot = optSlot(p.to_string_slot);

    const raised = p.raised[0..p.n_raised];
    const e = &r.exceptions;
    const at = struct {
        fn get(rs: []const RaisedDesc, k: Raise) ?ir.resolved.Raised {
            const idx = @intFromEnum(k);
            return if (idx < rs.len) raisedOf(rs[idx]) else null;
        }
    };
    e.null_pointer = at.get(raised, .npe);
    e.class_cast = at.get(raised, .class_cast);
    e.arithmetic = at.get(raised, .arithmetic);
    e.uninitialized_property = at.get(raised, .uninitialized);
    e.index_out_of_bounds = at.get(raised, .index);
    e.array_index_out_of_bounds = at.get(raised, .array_index);
    e.string_index_out_of_bounds = at.get(raised, .string_index);
    r.base.init_failed = at.get(raised, .init_failed);
    r.base.no_class_def = at.get(raised, .no_class_def);
    r.base.match_groups = raisedOf(p.match_groups);
    for (p.by_fqn[0..p.n_by_fqn]) |d| {
        const x = raisedOf(d) orelse continue;
        try e.by_fqn.put(a, std.mem.span(d.fqn.?), x);
    }

    m.resolved = r;
    tables = r;
    throw_hook = p.throw_value;
    module_ref = try ObjRef(ir.Module).init(a, m);
    vm = try Vm.new(a, module_ref);
}

/// Describes the program. Called before `klio_nat_begin`, so what it builds
/// is permanent.
export fn klio_r_describe(p: *const ProgramDesc) void {
    buildProgram(p) catch @panic("klio_r_describe: out of memory");
}

const MainFn = *const fn () callconv(.c) void;

fn runMain(main_fn: MainFn, v: *Vm) std.mem.Allocator.Error!void {
    var h = v.makeHost(output());
    host = &h;
    defer host = null;
    main_fn();
}

fn runBody(main_fn: MainFn) c_int {
    const prep = vm.runCalls(output(), MainFn, main_fn, runMain) catch @panic("klio_r_run: out of memory");
    if (prep) |_| return 1;
    return 0;
}

/// Runs the program's `main` inside the VM, on the large stack `klio run`
/// uses. Returns the exit status of a run that returned.
export fn klio_r_run(main_fn: MainFn) c_int {
    runtime.tls_fast.claimOwner();
    return runtime.runOnBigStackMainThread(MainFn, c_int, runBody, main_fn);
}

fn theHost() *VmHost {
    return host orelse fatal("the program reached the runtime outside its run");
}

// ---------------------------------------------------------------------------
// Output

var out_ctx: u8 = 0;

fn outWrite(ctx: *anyopaque, bytes: []const u8) void {
    _ = ctx;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn outWriteln(ctx: *anyopaque, bytes: []const u8) void {
    outWrite(ctx, bytes);
    outWrite(ctx, "\n");
}

const out_vtable: runtime.Output.VTable = .{ .write = outWrite, .writeln = outWriteln };

pub fn output() runtime.Output {
    return .{ .ctx = @ptrCast(&out_ctx), .vtable = &out_vtable };
}

// ---------------------------------------------------------------------------
// Raising into the program

/// An internal failure: the compiled program asked for something its
/// tables do not have. Reported and fatal, as the VM's internal errors are.
pub fn fatal(what: []const u8) noreturn {
    failed(what, "");
}

fn failed(what: []const u8, why: []const u8) noreturn {
    const pre = "runtime error: ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, what.ptr, what.len);
    if (why.len != 0) {
        _ = std.c.write(2, ": ", 2);
        _ = std.c.write(2, why.ptr, why.len);
    }
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

fn uncaughtText(what: []const u8, message: ?[]const u8) noreturn {
    const pre = "Exception in thread \"main\" ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, what.ptr, what.len);
    if (message) |m| {
        _ = std.c.write(2, ": ", 2);
        _ = std.c.write(2, m.ptr, m.len);
    }
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

/// An uncaught `what` over a cause, which the program builds no instance of.
fn uncaughtCaused(what: []const u8, cause: []const u8) noreturn {
    const pre = "Exception in thread \"main\" ";
    _ = std.c.write(2, pre.ptr, pre.len);
    _ = std.c.write(2, what.ptr, what.len);
    const caused = "\nCaused by: ";
    _ = std.c.write(2, caused.ptr, caused.len);
    _ = std.c.write(2, cause.ptr, cause.len);
    _ = std.c.write(2, "\n", 1);
    std.c.exit(1);
}

fn throwValue(v: Value) noreturn {
    if (throw_hook) |t| t(toC(v));
    uncaughtText("exception", null);
}

/// A result of the VM's: its value, or what it threw raised into the program.
fn land(r: ir.eval.EvalResult, what: []const u8) CValue {
    return switch (r) {
        .ok => |v| toC(v),
        .err => |e| switch (e) {
            .Throw => |v| throwValue(v),
            .Type, .Unsupported, .Unbound, .Unimplemented, .CalleeFailed, .Arity => |m| failed(what, m),
            else => failed(what, @tagName(e)),
        },
    };
}

fn nextIdentity() u64 {
    const st = vm.resolved_state orelse return 0;
    return st.cell.data.takeIdentity();
}

/// Builds exception `which` with `message` through the class the program
/// registered for it and throws it, as the VM raises its own.
pub fn raise(which: Raise, message: ?[]const u8) noreturn {
    const a = alloc();
    const msg: Value = if (message) |m| .{ .String = runtime.strInit(a, m) catch @panic("raise: out of memory") } else .Null;
    raiseValue(which, msg);
}

fn raiseValue(which: Raise, msg: Value) noreturn {
    const e = &tables.exceptions;
    const raised: ?ir.resolved.Raised = switch (which) {
        .npe => e.null_pointer,
        .class_cast => e.class_cast,
        .arithmetic => e.arithmetic,
        .uninitialized => e.uninitialized_property,
        .index => e.index_out_of_bounds,
        .array_index => e.array_index_out_of_bounds orelse e.index_out_of_bounds,
        .string_index => e.string_index_out_of_bounds orelse e.index_out_of_bounds,
        .init_failed => tables.base.init_failed,
        .no_class_def => tables.base.no_class_def,
    };
    const rz = raised orelse {
        const text: ?[]const u8 = if (msg == .String) msg.String.asPtrConst().bytes else null;
        uncaughtText(raiseName(which), text);
    };
    const inst = build(rz, &.{msg});
    throwValue(inst);
}

fn raiseName(which: Raise) []const u8 {
    return switch (which) {
        .npe => "kotlin.NullPointerException",
        .class_cast => "kotlin.ClassCastException",
        .arithmetic => "kotlin.ArithmeticException",
        .uninitialized => "kotlin.UninitializedPropertyAccessException",
        .index => "kotlin.IndexOutOfBoundsException",
        .array_index => "klio.ArrayIndexOutOfBoundsException",
        .string_index => "klio.StringIndexOutOfBoundsException",
        .init_failed => "klio.ExceptionInInitializerError",
        .no_class_def => "klio.NoClassDefFoundError",
    };
}

/// A new instance of `rz.class` built by its constructor over `args`.
fn build(rz: ir.resolved.Raised, args: []const Value) Value {
    const a = alloc();
    const inst = ir.resolved.instantiate(a, tables, rz.class, nextIdentity()) catch @panic("raise: out of memory");
    runtime.keepalivePush(inst);
    var call: std.ArrayList(Value) = .empty;
    call.append(a, inst) catch @panic("raise: out of memory");
    call.appendSlice(a, args) catch @panic("raise: out of memory");
    const res = theHost().runResolved(a, module(), rz.ctor, call.items) catch @panic("raise: out of memory");
    call.deinit(a);
    switch (res) {
        .ok => {},
        .err => |err| switch (err) {
            .Throw => |v| throwValue(v),
            else => fatal("an exception's constructor failed"),
        },
    }
    return inst;
}

/// Raises exception `which` (a `Raise`) with `message` (a `String?`).
export fn klio_r_raise(which: u32, message: CValue) noreturn {
    raiseValue(@enumFromInt(which), fromC(message));
}

/// By the unit an initializer belongs to: the `toString()` of what it threw
/// first, which every later use's error names.
var init_failures: std.StringHashMapUnmanaged([]const u8) = .empty;

/// The initializer of `name_z` (an object's, a companion's, a file's or an
/// enum's, named with its noun: `object pkg.Config`) threw `cause`, or
/// `cause` is null on a later use of one that did. The first use gets
/// `ExceptionInInitializerError` over the throw, or the throw itself when it
/// is an `Error`. Every later use gets `NoClassDefFoundError("Could not
/// initialize <name>")`, caused by an `ExceptionInInitializerError` naming
/// the first failure.
export fn klio_r_init_failed(cause: CValue, name_z: [*:0]const u8) noreturn {
    const a = alloc();
    const c = fromC(cause);
    const name = std.mem.span(name_z);
    if (c != .Null) {
        const text = fromC(klio_r_to_string(cause));
        const owned = std.heap.smp_allocator.dupe(u8, if (text == .String) text.String.asPtrConst().bytes else "kotlin.Throwable") catch @panic("init failure: out of memory");
        init_failures.put(std.heap.smp_allocator, name, owned) catch @panic("init failure: out of memory");
        if (isError(c)) throwValue(c);
        const rz = tables.base.init_failed orelse uncaughtCaused(raiseName(.init_failed), owned);
        throwValue(build(rz, &.{ .Null, c }));
    }
    const text = std.fmt.allocPrint(a, "Could not initialize {s}", .{name}) catch @panic("init failure: out of memory");
    const nc = tables.base.no_class_def orelse uncaughtText(raiseName(.no_class_def), text);
    var first: Value = .Null;
    if (init_failures.get(name)) |t| if (tables.base.init_failed) |rz| {
        const m = std.fmt.allocPrint(a, "Exception {s} [in thread \"main\"]", .{t}) catch @panic("init failure: out of memory");
        first = build(rz, &.{ .{ .String = runtime.strInit(a, m) catch @panic("init failure: out of memory") }, .Null });
    };
    throwValue(build(nc, &.{ .{ .String = runtime.strInit(a, text) catch @panic("init failure: out of memory") }, first }));
}

/// Whether `v` is an instance of `kotlin.Error`.
fn isError(v: Value) bool {
    const err = tables.exceptions.by_fqn.get("kotlin.Error") orelse return false;
    const cls = ir.resolved.classOf(tables, &v) orelse return false;
    return ir.resolved.isA(module(), cls, err.class);
}

/// An uncaught throwable, reported as the JVM reports it; the program ends
/// with status 1.
export fn klio_r_uncaught(vcv: CValue) noreturn {
    const S = struct {
        var busy: bool = false;
    };
    // Rendering runs the throwable's `toString`, which can throw itself.
    if (S.busy) std.c.exit(1);
    S.busy = true;
    const v = fromC(vcv);
    if (host == null) uncaughtText("exception", null);
    const s = fromC(klio_r_to_string(vcv));
    _ = v;
    uncaughtText(if (s == .String) s.String.asPtrConst().bytes else "exception", null);
}

/// A virtual call no class of the program and no host member answers.
export fn klio_r_no_method(name: [*:0]const u8) noreturn {
    failed("no implementation of", std.mem.span(name));
}

/// Control reached code the lowering marked unreachable.
export fn klio_r_unreachable() noreturn {
    fatal("reached unreachable code");
}

// ---------------------------------------------------------------------------
// Classes, instances and type tests

/// A fresh instance of `cls` with every slot holding its seed.
export fn klio_r_new(cls: u32) CValue {
    if (cls >= tables.classes.len) fatal("an instance of a class the program did not register");
    return toC(ir.resolved.instantiate(alloc(), tables, ClassId.from(cls), nextIdentity()) catch @panic("klio_r_new: out of memory"));
}

/// The class of `v`, `NONE` for a value whose kind has none.
export fn klio_r_class_of(cv: CValue) u32 {
    const v = fromC(cv);
    const c = ir.resolved.classOf(tables, &v) orelse return NONE;
    return c.int();
}

/// `v is C` (or `C?` when `nullable`).
export fn klio_r_is_a(cv: CValue, cls: u32, nullable: i32) i32 {
    const v = fromC(cv);
    if (v == .Null) return nullable;
    const c = ir.resolved.classOf(tables, &v) orelse return 0;
    return @intFromBool(ir.resolved.isA(module(), c, ClassId.from(cls)));
}

fn className(c: u32) []const u8 {
    if (c >= tables.classes.len) return "?";
    return tables.classes[c].def.asPtrConst().fqn;
}

/// `v as C` (`as? C` when `safe`, `C?` when `nullable`): `v` itself when
/// it is a `C`, else null for `as?`, a `NullPointerException` for a null
/// and a `ClassCastException` for anything else.
export fn klio_r_cast(vcv: CValue, cls: u32, nullable: i32, safe: i32) CValue {
    if (klio_r_is_a(vcv, cls, nullable) != 0) return vcv;
    if (safe != 0) return toC(.Null);
    const v = fromC(vcv);
    var buf: [512]u8 = undefined;
    if (v == .Null) {
        const msg = std.fmt.bufPrint(&buf, "null cannot be cast to non-null type {s}", .{className(cls)}) catch "null cannot be cast";
        raise(.npe, msg);
    }
    const from = klio_r_class_of(vcv);
    const msg = std.fmt.bufPrint(&buf, "class {s} cannot be cast to class {s}", .{ className(from), className(cls) }) catch "class cast";
    raise(.class_cast, msg);
}

/// The `KClass` of class `cls`.
export fn klio_r_kclass(cls: u32) CValue {
    if (cls >= tables.classes.len) fatal("a class literal of a class the program did not register");
    return toC(.{ .Class = tables.classes[cls].def.clone() });
}

/// The `KClass` of `v`'s class.
export fn klio_r_class_value(cv: CValue) CValue {
    const v = fromC(cv);
    if (v == .Null) raise(.npe, null);
    const c = klio_r_class_of(cv);
    if (c == NONE) fatal("a value whose class the program did not register");
    return klio_r_kclass(c);
}

// ---------------------------------------------------------------------------
// Fields

/// Field `slot` of `obj`, as `GetFieldSlot` reads it: an unsigned value's
/// one field is its signed bits, an unsigned array's its signed array.
export fn klio_r_get(ocv: CValue, slot: u32) CValue {
    const obj = fromC(ocv);
    switch (obj) {
        .Instance => |inst| return toC(runtime.InstanceData.slotGet(inst, slot) orelse fatal("a field slot past the instance's fields")),
        .Null => raise(.npe, null),
        .UByte => |u| if (slot == 0) return toC(.{ .Byte = @bitCast(u) }),
        .UShort => |u| if (slot == 0) return toC(.{ .Short = @bitCast(u) }),
        .UInt => |u| if (slot == 0) return toC(.{ .Int = @bitCast(u) }),
        .ULong => |u| if (slot == 0) return toC(.{ .Long = @bitCast(u) }),
        .Array => |arr| if (slot == 0) if (arr.primKind()) |k| {
            const signed: ?runtime.PrimitiveArrayKind = switch (k) {
                .UByte => .Byte,
                .UShort => .Short,
                .UInt => .Int,
                .ULong => .Long,
                else => null,
            };
            if (signed) |sk| switch (arr.storage()) {
                .scalars => |pb| return toC(.{ .Array = runtime.ArrayData.scalars(pb.clone(), sk) }),
                .boxed => {},
            };
        },
        else => {},
    }
    fatal("a field read of a value with no fields");
}

export fn klio_r_set(ocv: CValue, slot: u32, vcv: CValue) void {
    const obj = fromC(ocv);
    switch (obj) {
        .Instance => |inst| {
            _ = runtime.InstanceData.slotSet(inst, slot, fromC(vcv)) orelse fatal("a field slot past the instance's fields");
        },
        .Null => raise(.npe, null),
        else => fatal("a field write of a value with no fields"),
    }
}

/// `BoxValue`: the instance of scalar value class `cls` over the number `vcv`
/// in field `slot`, which runs no init block; an instance or a null is itself.
export fn klio_r_box_value(vcv: CValue, cls: u32, slot: u32) CValue {
    const v = fromC(vcv);
    if (v == .Instance or v == .Null) return vcv;
    const boxed = klio_r_new(cls);
    klio_r_set(boxed, slot, vcv);
    return boxed;
}

/// `UnboxValue`: the number an instance of scalar value class `cls` holds in
/// field `slot`; anything else is itself.
export fn klio_r_unbox_value(vcv: CValue, cls: u32, slot: u32) CValue {
    const v = fromC(vcv);
    if (v != .Instance or v.Instance.asPtrConst().class_id != cls) return vcv;
    return toC(runtime.InstanceData.slotGet(v.Instance, slot) orelse fatal("a field slot past the instance's fields"));
}

// ---------------------------------------------------------------------------
// Natives and host members, through the VM's host

fn argValues(argv: [*]const CValue, argc: u32) []Value {
    const vals = alloc().alloc(Value, argc) catch @panic("klio_rt: out of memory");
    for (vals, 0..) |*v, i| v.* = fromC(argv[i]);
    return vals;
}

/// Runs native `n` (as the program numbers them) over the argument run.
export fn klio_r_native_call(n: u32, argv: [*]const CValue, argc: u32) CValue {
    const a = alloc();
    const vals = argValues(argv, argc);
    const r = theHost().callNative(a, NativeId.from(n + 1), vals) catch @panic("klio_r_native_call: out of memory");
    a.free(vals);
    return land(r, tables.natives[n + 1].name);
}

// ---------------------------------------------------------------------------
// Operators on values whose kinds were not known statically

const BinOpInst = @FieldType(ir.Inst, "BinOp");

/// `op` as the VM applies it: arithmetic, comparison, equality through the
/// operands' `equals`, and string templates through their `toString`.
export fn klio_r_binop(op: u32, acv: CValue, bcv: CValue) CValue {
    const zero = ir.Reg.from(0);
    const bo: BinOpInst = .{ .dst = zero, .op = @enumFromInt(op), .lhs = zero, .rhs = zero };
    const r = ir.eval.binopValue(VmHost, alloc(), fromC(acv), fromC(bcv), BinOpInst, bo, theHost()) catch @panic("klio_r_binop: out of memory");
    return land(r, "operator");
}

export fn klio_r_unop(op: u32, vcv: CValue) CValue {
    const v = fromC(vcv);
    const u: ir.UnOp = @enumFromInt(op);
    const out: ?Value = switch (u) {
        .Plus => v,
        .Neg => switch (v) {
            .Int => |i| .{ .Int = 0 -% i },
            .Long => |l| .{ .Long = 0 -% l },
            .Short => |s| .{ .Int = -@as(i32, s) },
            .Byte => |b| .{ .Int = -@as(i32, b) },
            .Double => |d| .{ .Double = -d },
            .Float => |f| .{ .Float = -f },
            else => null,
        },
        .Inc, .Dec => blk: {
            const d: i64 = if (u == .Inc) 1 else -1;
            break :blk switch (v) {
                .Int => |i| .{ .Int = i +% @as(i32, @intCast(d)) },
                .Long => |l| .{ .Long = l +% d },
                .Short => |s| .{ .Short = s +% @as(i16, @intCast(d)) },
                .Byte => |b| .{ .Byte = b +% @as(i8, @intCast(d)) },
                .Char => |c| .{ .Char = c +% @as(u16, @bitCast(@as(i16, @intCast(d)))) },
                .UInt => |x| .{ .UInt = x +% @as(u32, @bitCast(@as(i32, @intCast(d)))) },
                .ULong => |x| .{ .ULong = x +% @as(u64, @bitCast(d)) },
                .UShort => |x| .{ .UShort = x +% @as(u16, @bitCast(@as(i16, @intCast(d)))) },
                .UByte => |x| .{ .UByte = x +% @as(u8, @bitCast(@as(i8, @intCast(d)))) },
                .Double => |x| .{ .Double = x + @as(f64, @floatFromInt(d)) },
                .Float => |x| .{ .Float = x + @as(f32, @floatFromInt(d)) },
                else => null,
            };
        },
        .ToByte, .ToShort, .ToInt, .ToLong, .ToFloat, .ToDouble, .ToChar => runtime.numconv.convert(u.conversion().?, v),
        .Inv, .ToRawBits, .ToBits, .FloatFromBits, .DoubleFromBits, .CountTrailingZeroBits, .UIntToFloat, .UIntToDouble, .ULongToFloat, .ULongToDouble, .Sin, .Cos, .Sqrt, .ToULong, .ToUInt, .ToUShort, .ToUByte, .UnsignedBits => runtime.numfn.apply(u.function().?, v),
    };
    return toC(out orelse fatal("a unary operator on a value it does not apply to"));
}

/// Runs the implementation of `slot` in `v`'s class over `args`, as the
/// VM's closure members do; null when the tables name none or it throws.
fn slotCall(v: *const Value, slot: ?MethodSlotId, args: []const Value) ?Value {
    const sl = slot orelse return null;
    const cls = ir.resolved.classOf(tables, v) orelse return null;
    const f = module().methodSlotTarget(cls, sl) orelse return null;
    const a = alloc();
    const res = (if (f.int() < tables.func_native.len and tables.func_native[f.int()] != .none)
        theHost().callNative(a, tables.func_native[f.int()], args)
    else
        theHost().runResolved(a, module(), f, args)) catch @panic("slotCall: out of memory");
    return switch (res) {
        .ok => |x| x,
        .err => null,
    };
}

/// `u == v` for two captured values: both null, or `u.equals(v)` through
/// the class tables, else the values' own equality.
export fn klio_r_equals(ucv: CValue, vcv: CValue) i32 {
    const u = fromC(ucv);
    const v = fromC(vcv);
    if (u == .Null or v == .Null) return @intFromBool(u == .Null and v == .Null);
    if (slotCall(&u, tables.host_class.equals_slot, &.{ u, v })) |res| return @intFromBool(res == .Bool and res.Bool);
    return @intFromBool(Value.structuralEq(&u, &v));
}

/// `v.hashCode()`, 0 for null: its class's implementation, else the
/// host's member of a value the tables do not describe.
export fn klio_r_hash_code(vcv: CValue) i32 {
    const v = fromC(vcv);
    if (v == .Null) return 0;
    if (slotCall(&v, tables.host_class.hash_code_slot, &.{v})) |res| return if (res == .Int) res.Int else 0;
    const any_hash = interp_ir.hostMemberFn("kotlin.Any.hashCode") orelse fatal("the host has no `Any.hashCode`");
    const r = any_hash(theHost(), alloc(), &.{v}) catch @panic("klio_r_hash_code: out of memory");
    const h = fromC(land(r, "hashCode"));
    return if (h == .Int) h.Int else 0;
}

/// An instance's identity hash.
export fn klio_r_identity_hash(vcv: CValue) i32 {
    const v = fromC(vcv);
    return switch (v) {
        .Instance => |inst| @truncate(@as(i64, @bitCast(inst.asPtrConst().identity))),
        else => 0,
    };
}

/// A lambda's text: `stem` (its class as the JVM names it) and its hash.
export fn klio_r_lambda_text(stem: [*:0]const u8, vcv: CValue) CValue {
    const a = alloc();
    const s = std.fmt.allocPrint(a, "{s}@{x}", .{ std.mem.span(stem), @as(u32, @bitCast(klio_r_identity_hash(vcv))) }) catch @panic("klio_r_lambda_text: out of memory");
    return toC(.{ .String = runtime.strInitOwned(a, s) catch @panic("klio_r_lambda_text: out of memory") });
}

/// A string template's concatenation: each side rendered by its `toString`.
export fn klio_r_concat(acv: CValue, bcv: CValue) CValue {
    return klio_r_binop(@intFromEnum(ir.BinOp.StringConcat), acv, bcv);
}

/// `v.toString()` as a string value.
export fn klio_r_to_string(vcv: CValue) CValue {
    const a = alloc();
    const empty: Value = .{ .String = runtime.strInit(a, "") catch @panic("klio_r_to_string: out of memory") };
    return klio_r_concat(toC(empty), vcv);
}

// ---------------------------------------------------------------------------
// Arrays

fn lengthOf(v: *const Value) usize {
    return switch (v.*) {
        .Array => |arr| arr.len(),
        .String => |s| blk: {
            const g = s.borrow();
            defer g.deinit();
            break :blk g.get().u16_len;
        },
        else => 0,
    };
}

fn raiseIndex(v: *const Value, index: i32) noreturn {
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Index {d} out of bounds for length {d}", .{ index, lengthOf(v) }) catch "Index out of bounds";
    raise(if (v.* == .String) .string_index else .array_index, msg);
}

export fn klio_r_array_get(acv: CValue, index: i32) CValue {
    const arr = fromC(acv);
    switch (arr) {
        .Array, .String => {},
        .Null => raise(.npe, null),
        else => fatal("an element read of a value that is not an array"),
    }
    const idx: Value = .{ .Int = index };
    const v = ir.eval.fastIndexGet(&arr, &idx) orelse raiseIndex(&arr, index);
    return toC(v);
}

export fn klio_r_array_set(acv: CValue, index: i32, vcv: CValue) void {
    const arr = fromC(acv);
    switch (arr) {
        .Array => {},
        .Null => raise(.npe, null),
        else => fatal("an element write of a value that is not an array"),
    }
    const idx: Value = .{ .Int = index };
    _ = ir.eval.fastIndexSet(alloc(), &arr, &idx, fromC(vcv)) orelse raiseIndex(&arr, index);
}

/// An array of class `cls` (`Array` or a primitive array) over `argv`.
export fn klio_r_new_array(cls: u32, argv: [*]const CValue, argc: u32) CValue {
    const a = alloc();
    const h = &tables.host_class;
    const run = a.alloc(Value, argc) catch @panic("klio_r_new_array: out of memory");
    defer a.free(run);
    for (run, 0..) |*v, i| v.* = fromC(argv[i]);
    if (h.array) |ac| if (ac.int() == cls) {
        var list: std.ArrayList(Value) = .empty;
        list.appendSlice(a, run) catch @panic("klio_r_new_array: out of memory");
        return toC(runtime.ArrayData.fromBoxedList(runtime.ValueList.init(a, list) catch @panic("klio_r_new_array: out of memory")));
    };
    for (h.prim_array, 0..) |c, k| {
        if (c == null or c.?.int() != cls) continue;
        return toC(runtime.ArrayData.initPacked(a, @enumFromInt(k), run) catch @panic("klio_r_new_array: out of memory"));
    }
    fatal("an array of a class that is not an array class");
}

test "the ABI hash is stable within one build" {
    try std.testing.expectEqual(abi, klio_r_abi());
}

test "a stub body hands its index and parameters to the trampoline" {
    const blocks = try stubBody(std.testing.allocator, 3, 2, ir.ConstId.from(7));
    defer {
        std.testing.allocator.free(blocks[0].insts);
        std.testing.allocator.free(blocks);
    }
    const insts = blocks[0].insts;
    try std.testing.expectEqual(@as(usize, 4), insts.len);
    try std.testing.expectEqual(@as(u32, 7), insts[0].Const.value.int());
    try std.testing.expectEqual(@as(u16, 1), insts[2].LoadParam.idx);
    const call = insts[3].CallNative;
    try std.testing.expectEqual(TRAMPOLINE, call.native.int());
    try std.testing.expectEqual(@as(u32, 3), call.n_args);
    try std.testing.expectEqual(@as(u32, 0), call.args.int());
    try std.testing.expectEqual(@as(u32, 3), blocks[0].terminator.Return.?.int());
}

test "a compiled program's dispatch answers through the dense tables, each class for the roots it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Resolved = .{};
    const classes = try a.alloc(ir.resolved.ClassRt, 3);
    for (classes) |*c| c.* = .{ .def = undefined };
    r.classes = classes;
    // Class 0 implements roots 5 and 9, class 1 overrides root 5 only,
    // class 2 is outside both.
    const dispatch = [_]DispatchDesc{
        .{ .cls = 0, .slot = 5, .function = 11 },
        .{ .cls = 0, .slot = 9, .function = 12 },
        .{ .cls = 1, .slot = 5, .function = 13 },
    };
    try denseTables(a, &r, &dispatch, 3);
    const slotTarget = ir.resolved.slotTarget;
    try std.testing.expectEqual(@as(u32, 11), slotTarget(&r, ClassId.from(0), MethodSlotId.from(5)).?.int());
    try std.testing.expectEqual(@as(u32, 12), slotTarget(&r, ClassId.from(0), MethodSlotId.from(9)).?.int());
    try std.testing.expectEqual(@as(u32, 13), slotTarget(&r, ClassId.from(1), MethodSlotId.from(5)).?.int());
    try std.testing.expect(slotTarget(&r, ClassId.from(1), MethodSlotId.from(9)) == null);
    try std.testing.expect(slotTarget(&r, ClassId.from(2), MethodSlotId.from(5)) == null);
    try std.testing.expect(slotTarget(&r, ClassId.from(0), MethodSlotId.from(7)) == null);
}
