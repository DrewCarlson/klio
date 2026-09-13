const std = @import("std");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");

const Block = core_func.Block;
const BlockId = core_ids.BlockId;
const ClassId = core_ids.ClassId;
const FuncId = core_ids.FuncId;
const Module = root_ir.Module;
const Param = core_func.Param;
const TypeRef = core_ids.TypeRef;

/// Options for the symbol-index test func pusher.
pub const TestFuncOpts = struct {
    /// `null` = body-bearing; otherwise a header stub with no blocks.
    stub: bool = false,
    low_priority: bool = false,
    /// Mark the last parameter `vararg`.
    last_vararg: bool = false,
    /// Give every parameter but the last a default, and type the last
    /// parameter `Function0` (the trailing-lambda gap shape).
    fn_tail_with_defaults: bool = false,
    /// First parameter is a synthesized receiver `this`.
    extension: bool = false,
    /// Type name for every user parameter (default `Int`).
    param_ty: []const u8 = "Int",
};

/// Push a top-level func with the given simple name, FQN, package, and
/// user-parameter count, returning its id. Used by the symbol-index tests.
pub fn pushTestFuncOpts(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8, user_params: usize, opts: TestFuncOpts) !FuncId {
    const id = m.nextFuncId();
    const n_params = user_params + @as(usize, if (opts.extension) 1 else 0);
    const params = try a.alloc(Param, n_params);
    for (params, 0..) |*p, i| {
        p.* = .{ .name = "x", .ty = .{ .name = opts.param_ty, .nullable = false, .args = &.{} }, .default = null };
        if (opts.extension and i == 0) {
            p.name = "this";
            p.ty.name = "String";
        }
        if (opts.fn_tail_with_defaults) {
            if (i + 1 == n_params) {
                p.ty.name = "Function0";
            } else if (!(opts.extension and i == 0)) {
                p.has_default = true;
            }
        }
        if (opts.last_vararg and i + 1 == n_params) p.is_vararg = true;
    }
    const blocks = try a.alloc(Block, if (opts.stub) 0 else 1);
    if (!opts.stub) {
        blocks[0] = .{ .id = BlockId.from(0), .insts = &.{}, .terminator = .{ .Return = null } };
    }
    try m.funcs.append(a, .{
        .id = id,
        .name = name,
        .fqn = fqn,
        .package = package,
        .params = params,
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 0,
        .blocks = blocks,
        .entry = BlockId.from(0),
        .is_suspend = false,
        .low_priority = opts.low_priority,
    });
    try m.func_index.append(a, .{ .name = name, .id = id });
    return id;
}

pub fn pushTestFunc(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8, user_params: usize) !FuncId {
    return pushTestFuncOpts(m, a, name, fqn, package, user_params, .{});
}

pub fn deferReasonOf(res: Module.BareCallResolution) ?Module.ResolveDeferReason {
    return switch (res.outcome) {
        .resolved => null,
        .deferred => |r| r,
    };
}

pub fn freeTestModule(m: *Module, a: Allocator) void {
    for (m.funcs.items) |f| {
        a.free(f.params);
        a.free(f.blocks);
    }
    m.deinit(a);
}

/// Record a declared-signature entry (all params `ty_name`, non-null,
/// no generic args) for a stub, mirroring phase-1 header registration.
pub fn putTestDeclSig(m: *Module, a: Allocator, id: FuncId, ty_name: []const u8, n: usize) !void {
    const sig = try a.alloc(TypeRef, n);
    for (sig) |*ty| ty.* = .{ .name = try a.dupe(u8, ty_name), .nullable = false, .args = &.{} };
    try m.decl_user_sig.put(id.int(), sig);
}

pub fn pushTestClass(m: *Module, a: Allocator, name: []const u8, fqn: []const u8, package: []const u8) !ClassId {
    return m.addClass(a, .{
        .id = ClassId.from(0),
        .name = name,
        .fqn = fqn,
        .package = package,
        .primary_params = &.{},
        .methods = &.{},
        .init_block = null,
        .companion = null,
        .supertypes = &.{},
    });
}
