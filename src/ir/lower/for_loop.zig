//! `for (x in xs) body` loop lowering. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const Terminator = ir.Terminator;

const lowerExpr = expr.lowerExpr;

pub fn lowerFor(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
) Allocator.Error!Reg {
    return lowerForLabeled(b, vars, iter, body, null);
}

pub fn lowerForLabeled(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    const recv = try lowerExpr(b, iter);
    const it_reg = b.allocReg();
    const zero = b.allocReg();
    try b.push(.{ .Move = .{ .dst = zero, .src = recv } });
    const name = try b.module.internConst(b.allocator, .{ .String = "iterator" });
    const args_start = b.allocReg();
    try b.push(.{ .CallMember = .{
        .dst = it_reg,
        .receiver = zero,
        .name = name,
        .args = args_start,
        .n_args = 0,
        .arg_names = &.{},
    } });
    // Static protocol binding: when the iterable's `iterator()` return
    // resolves to the `Iterator` INTERFACE itself, `hasNext`/`next` emit
    // slot-bound against its roots — the runtime serves those by FuncId
    // (`iterator_protocol` for host iterators, the override slot for
    // interpreted implementors). A convention-based custom iterator (any
    // `operator hasNext/next` without the interface) keeps the by-name
    // form, exactly as before.
    var hn_root: ?ir.FuncId = null;
    var next_root: ?ir.FuncId = null;
    if (try expr.staticExprTypeRef(b, iter)) |ity0| {
        var ity = ity0;
        defer ity.deinit(b.allocator);
        const file = vars[0].span.file;
        if (try expr.nullaryMemberReturnTypeRef(b, ity, "iterator", file)) |irt0| {
            var irt = irt0;
            defer irt.deinit(b.allocator);
            var head = std.mem.trimEnd(u8, irt.name, "?");
            if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
            if (std.mem.lastIndexOfScalar(u8, head, '.')) |d| head = head[d + 1 ..];
            // The interface itself, or a primitive-iterator abstract class
            // (`ByteIterator`): `hasNext` roots on the interface; `next`
            // prefers the head class's own override (whose source body
            // delegates to the `nextByte()`-family the protocol handler
            // serves) and falls back to the interface root.
            const iterator_family = std.mem.eql(u8, head, "Iterator") or
                (std.mem.endsWith(u8, head, "Iterator") and blk_fam: {
                    // The kotlin.collections primitive-iterator family ONLY:
                    // a pack class that happens to end in `Iterator`
                    // (compose's path iterators) has its own dispatch story.
                    const cid = b.module.uniqueClassIdBySimpleName(head) orelse break :blk_fam false;
                    if (cid.int() >= b.module.classes.items.len) break :blk_fam false;
                    break :blk_fam std.mem.startsWith(u8, b.module.classes.items[cid.int()].fqn, "kotlin.collections.");
                });
            if (iterator_family) {
                if (b.module.uniqueClassIdBySimpleName("Iterator")) |icid| {
                    if (icid.int() < b.module.classes.items.len) {
                        const ifqn = b.module.classes.items[icid.int()].fqn;
                        const hn_decls = b.module.memberDecls(ifqn, "hasNext");
                        const nx_decls = b.module.memberDecls(ifqn, "next");
                        if (hn_decls.len != 0) hn_root = hn_decls[0];
                        if (nx_decls.len != 0) next_root = nx_decls[0];
                    }
                }
                if (!std.mem.eql(u8, head, "Iterator")) {
                    if (b.module.uniqueClassIdBySimpleName(head)) |hcid| {
                        if (hcid.int() < b.module.classes.items.len) {
                            const hfqn = b.module.classes.items[hcid.int()].fqn;
                            const own_next = b.module.memberDecls(hfqn, "next");
                            if (own_next.len != 0) next_root = own_next[0];
                            const own_hn = b.module.memberDecls(hfqn, "hasNext");
                            if (own_hn.len != 0) hn_root = own_hn[0];
                        }
                    }
                }
            }
        }
    }
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    const has_next = b.allocReg();
    const hn_name = try b.module.internConst(b.allocator, .{ .String = "hasNext" });
    const hn_args = b.allocReg();
    if (hn_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = has_next,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = hn_args,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = has_next,
        .receiver = it_reg,
        .name = hn_name,
        .args = hn_args,
        .n_args = 0,
        .arg_names = &.{},
    } });
    b.terminate(.{ .Branch = .{
        .cond = has_next,
        .t = body_blk,
        .f = exit,
    } });

    b.switchTo(body_blk);
    try b.pushScope();
    const next_reg = b.allocReg();
    const next_name = try b.module.internConst(b.allocator, .{ .String = "next" });
    const nargs = b.allocReg();
    if (next_root) |root| {
        try b.push(.{ .CallVirtual = .{
            .dst = next_reg,
            .receiver = it_reg,
            .slot = ir.MethodSlotId.fromFunc(root),
            .args = nargs,
            .n_args = 0,
        } });
    } else try b.push(.{ .CallMember = .{
        .dst = next_reg,
        .receiver = it_reg,
        .name = next_name,
        .args = nargs,
        .n_args = 0,
        .arg_names = &.{},
    } });
    if (vars.len == 1) {
        try b.bind(vars[0].name, next_reg);
        if (try expr.iterableElementTypeName(b, iter)) |elem| {
            try b.setLocalDeclTypeOwned(vars[0].name, .{
                .name = elem,
                .nullable = false,
                .args = &.{},
            });
        }
    } else {
        // Each destructured name is bound to the element's `componentN()`, so
        // its type is that accessor's declared return type on the element.
        var elem_ty = try expr.iterableElementTypeRef(b, iter);
        defer if (elem_ty) |*t| t.deinit(b.allocator);
        for (vars, 0..) |v, i| {
            const comp = b.allocReg();
            const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
            const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
            const cargs = b.allocReg();
            try b.push(.{ .CallMember = .{
                .dst = comp,
                .receiver = next_reg,
                .name = nm,
                .args = cargs,
                .n_args = 0,
                .arg_names = &.{},
            } });
            try b.bind(v.name, comp);
            if (elem_ty) |ety| {
                if (try expr.nullaryMemberReturnTypeRef(b, ety, comp_name, iter.span().file)) |ct| {
                    try b.setLocalDeclTypeOwned(v.name, ct);
                }
            }
        }
    }
    try b.pushLoop(label, header, exit);
    _ = try lowerExpr(b, body);
    b.popLoop();
    try b.popScope();
    b.terminate(.{ .Goto = header });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}

test {
    std.testing.refAllDecls(@This());
}
