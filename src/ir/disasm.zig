//! Human-readable IR dump (`klio dump-ir`). Prints a built `Module`'s functions
//! as registers + instructions, classifying every call site as DIRECT (an exact
//! `FuncId`/`ClassId` target), VIRTUAL (a numeric method slot), or DYNAMIC
//! (resolved by name at runtime), and
//! distinguishing a dynamic call the lowerer *did* resolve to a unique target
//! but still left dynamic (BOUND) from one with no carried target (UNBOUND).
//!
//! This is the before/after oracle for static-binding work: the per-function
//! and module Direct/Dynamic tally is the success metric for un-tainting bare
//! calls. It reads a frozen module and never runs anything.

const std = @import("std");
const ir = @import("ir.zig");

const Module = ir.Module;
const Func = ir.Func;
const Inst = ir.Inst;
const Const = ir.Const;

pub const Options = struct {
    /// Substring filter on a function's `name`/`fqn`; null dumps the default set.
    func_filter: ?[]const u8 = null,
    /// Dump every appended function, not just `module.top_level`.
    all: bool = false,
};

/// A call site's binding class, for the Direct/Dynamic tally.
const Kind = enum { direct, virtual, dyn_bound, dyn_unbound };

const Tally = struct {
    direct: usize = 0,
    virtual: usize = 0,
    dyn_bound: usize = 0,
    dyn_unbound: usize = 0,

    fn add(self: *Tally, k: Kind) void {
        switch (k) {
            .direct => self.direct += 1,
            .virtual => self.virtual += 1,
            .dyn_bound => self.dyn_bound += 1,
            .dyn_unbound => self.dyn_unbound += 1,
        }
    }
    fn total(self: Tally) usize {
        return self.direct + self.virtual + self.dyn_bound + self.dyn_unbound;
    }
};

/// Classify a call-form instruction, or null when it is not a call site.
fn classify(inst: *const Inst) ?Kind {
    return switch (inst.*) {
        .Call => .direct,
        .NewInstance => .direct,
        .CallMemberOrGlobal => |c| if (c.func != null or c.class != null or c.candidates != null) .dyn_bound else .dyn_unbound,
        .CallSpread => |c| if (c.virtual_slot != null) .virtual else if (c.candidates != null) .dyn_bound else .dyn_unbound,
        .CallVirtual => .virtual,
        .CallMember => |c| if (c.resolved != null) .direct else .dyn_unbound,
        .CallValue,
        .CallValueWithThis,
        .CallSuper,
        .CallValueOrMember,
        .CallMemberOrValue,
        => .dyn_unbound,
        else => null,
    };
}

fn reg(r: ir.Reg) u32 {
    return r.int();
}

/// The string text of a `Const.String`, or a `<...>` placeholder.
fn constStr(m: *const Module, id: ir.ConstId) []const u8 {
    const i = id.int();
    if (i >= m.consts.items.len) return "<oob>";
    return switch (m.consts.items[i]) {
        .String => |s| s,
        else => "<non-str>",
    };
}

fn funcName(m: *const Module, id: ir.FuncId) []const u8 {
    return if (m.funcById(id)) |f| f.name else "<unknown>";
}

fn className(m: *const Module, id: ir.ClassId) []const u8 {
    for (m.classes.items) |*c| {
        if (c.id.int() == id.int()) return c.name;
    }
    return "<class?>";
}

fn argRun(w: *std.Io.Writer, args: ir.Reg, n: u32) !void {
    if (n == 0) {
        try w.writeAll("()");
        return;
    }
    try w.print("(r{d}..+{d})", .{ reg(args), n });
}

fn dumpInst(w: *std.Io.Writer, m: *const Module, inst: *const Inst, tally: *Tally) !void {
    if (classify(inst)) |k| tally.add(k);
    switch (inst.*) {
        .Const => |c| {
            try w.print("r{d} <- Const c{d} ({s}", .{ reg(c.dst), c.value.int(), constLabel(m, c.value) });
            if (c.value.int() < m.consts.items.len) {
                switch (m.consts.items[c.value.int()]) {
                    .Int => |v| try w.print(" {d}", .{v}),
                    .Long => |v| try w.print(" {d}", .{v}),
                    .Bool => |v| try w.print(" {}", .{v}),
                    .Double => |v| try w.print(" {d}", .{v}),
                    else => {},
                }
            }
            try w.writeAll(")");
        },
        .LoadParam => |c| try w.print("r{d} <- LoadParam #{d}", .{ reg(c.dst), c.idx }),
        .LoadCapture => |c| try w.print("r{d} <- LoadCapture #{d}", .{ reg(c.dst), c.idx }),
        .Move => |c| try w.print("r{d} <- Move r{d}", .{ reg(c.dst), reg(c.src) }),
        .MakeCell => |c| try w.print("r{d} <- MakeCell r{d}", .{ reg(c.dst), reg(c.src) }),
        .CellGet => |c| try w.print("r{d} <- CellGet r{d}", .{ reg(c.dst), reg(c.cell) }),
        .CellSet => |c| try w.print("CellSet r{d} <- r{d}", .{ reg(c.cell), reg(c.value) }),
        .GetField => |c| try w.print("r{d} <- GetField r{d}.'{s}'        [DYN field]", .{ reg(c.dst), reg(c.receiver), constStr(m, c.field) }),
        .SetField => |c| try w.print("SetField r{d}.'{s}' <- r{d}        [DYN field]", .{ reg(c.receiver), constStr(m, c.field), reg(c.value) }),
        .CompoundField => |c| try w.print("CompoundField r{d}.'{s}' {s}= r{d}        [DYN field]", .{ reg(c.receiver), constStr(m, c.field), @tagName(c.op), reg(c.value) }),
        .Index => |c| try w.print("r{d} <- Index r{d}[r{d}]", .{ reg(c.dst), reg(c.receiver), reg(c.index) }),
        .IndexSet => |c| try w.print("IndexSet r{d}[r{d}] <- r{d}", .{ reg(c.receiver), reg(c.index), reg(c.value) }),
        .Call => |c| {
            try w.print("r{d} <- Call {s}#{d} ", .{ reg(c.dst), funcName(m, c.func), c.func.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [DIRECT]");
        },
        .CallMember => |c| {
            try w.print("r{d} <- CallMember r{d}.'{s}' ", .{ reg(c.dst), reg(c.receiver), constStr(m, c.name) });
            try argRun(w, c.args, c.n_args);
            if (c.resolved) |target| {
                if (c.dispatch_receiver) |dispatch| {
                    try w.print(
                        "        [DIRECT member-ext dispatch=r{d} -> {s}#{d}]",
                        .{ reg(dispatch), funcName(m, target), target.int() },
                    );
                } else {
                    try w.print(
                        "        [DIRECT -> {s}#{d}]",
                        .{ funcName(m, target), target.int() },
                    );
                }
            } else {
                try w.print("        [DYN member '{s}']", .{constStr(m, c.name)});
            }
        },
        .CallMemberOrValue => |c| {
            try w.print("r{d} <- CallMemberOrValue r{d}.'{s}' fallback=r{d} ", .{ reg(c.dst), reg(c.receiver), constStr(m, c.name), reg(c.fallback) });
            try argRun(w, c.args, c.n_args);
            try w.print("        [DYN member-or-value '{s}']", .{constStr(m, c.name)});
        },
        .CallVirtual => |c| {
            try w.print("r{d} <- CallVirtual slot#{d} r{d} ", .{ reg(c.dst), c.slot.int(), reg(c.receiver) });
            try argRun(w, c.args, c.n_args);
            if (c.arg_params) |params| {
                try w.writeAll(" params=[");
                for (params, 0..) |param, i| {
                    if (i != 0) try w.writeByte(',');
                    try w.print("{d}", .{param});
                }
                try w.writeByte(']');
            }
            try w.writeAll("        [VIRTUAL]");
        },
        .CallMemberOrGlobal => |c| {
            try w.print("r{d} <- CallMemberOrGlobal this.'{s}' ", .{ reg(c.dst), constStr(m, c.name) });
            try argRun(w, c.args, c.n_args);
            if (c.func) |f| {
                try w.print("        [DYN-bound -> {s}#{d}]", .{ funcName(m, f), f.int() });
            } else if (c.class) |cl| {
                try w.print("        [DYN-bound -> class {s}]", .{className(m, cl)});
            } else if (c.candidates) |ids| {
                try w.print("        [DYN-bounded {d} candidates]", .{ids.len});
            } else {
                try w.print("        [DYN-unbound '{s}']", .{constStr(m, c.name)});
            }
        },
        .CallValue => |c| try w.print("r{d} <- CallValue r{d} (n={d})        [DYN value]", .{ reg(c.dst), reg(c.callee), c.n_args }),
        .CallValueWithThis => |c| try w.print(
            "r{d} <- CallValueWithThis r{d} receiver=r{d} (n={d})        [DYN receiver value]",
            .{ reg(c.dst), reg(c.callee), reg(c.receiver), c.n_args },
        ),
        .CallSpread => |c| {
            try w.print("r{d} <- CallSpread r{d} (parts={d})", .{ reg(c.dst), reg(c.callee), c.parts.len });
            if (c.virtual_slot) |slot| {
                try w.print(" slot#{d}", .{slot.int()});
                if (c.arg_params) |params| {
                    try w.writeAll(" params=[");
                    for (params, 0..) |param, i| {
                        if (i != 0) try w.writeByte(',');
                        try w.print("{d}", .{param});
                    }
                    try w.writeByte(']');
                }
                try w.writeAll("        [VIRTUAL]");
            } else if (c.member) |mid| {
                try w.print("        [DYN member '{s}']", .{constStr(m, mid)});
            } else if (c.candidates) |ids| {
                const name = if (c.name) |nid| constStr(m, nid) else "<missing-name>";
                try w.print("        [DYN-bounded '{s}' {d} candidates]", .{ name, ids.len });
            } else {
                try w.writeAll("        [DYN value]");
            }
        },
        .NewInstance => |c| {
            try w.print("r{d} <- NewInstance {s}#{d} ", .{ reg(c.dst), className(m, c.class), c.class.int() });
            try argRun(w, c.args, c.n_args);
            try w.writeAll("        [DIRECT]");
        },
        .LoadGlobal => |c| {
            try w.print("r{d} <- LoadGlobal '{s}'", .{ reg(c.dst), constStr(m, c.name) });
            if (c.func) |f| try w.print("        [bound -> {s}#{d}]", .{ funcName(m, f), f.int() }) else if (c.class) |cl| try w.print("        [bound -> class {s}]", .{className(m, cl)}) else try w.writeAll("        [unbound]");
        },
        .LoadFromThisOrGlobal => |c| {
            try w.print("r{d} <- LoadFromThisOrGlobal this.'{s}'", .{ reg(c.dst), constStr(m, c.name) });
            if (c.func) |f| try w.print("        [bound -> {s}#{d}]", .{ funcName(m, f), f.int() }) else if (c.class) |cl| try w.print("        [bound -> class {s}]", .{className(m, cl)}) else try w.writeAll("        [unbound]");
        },
        .MemberRef => |c| {
            try w.print(
                "r{d} <- MemberRef r{d}.'{s}'",
                .{ reg(c.dst), reg(c.receiver), constStr(m, c.name) },
            );
            if (c.func) |f|
                try w.print("        [bound -> {s}#{d}]", .{ funcName(m, f), f.int() })
            else
                try w.writeAll("        [unbound]");
        },
        .StoreToThisOrGlobal => |c| try w.print("StoreToThisOrGlobal this.'{s}' <- r{d}", .{ constStr(m, c.name), reg(c.value) }),
        .StoreGlobal => |c| try w.print("StoreGlobal '{s}' <- r{d}", .{ constStr(m, c.name), reg(c.value) }),
        .BinOp => |c| try w.print("r{d} <- BinOp {s} r{d}, r{d}", .{ reg(c.dst), @tagName(c.op), reg(c.lhs), reg(c.rhs) }),
        .UnOp => |c| try w.print("r{d} <- UnOp {s} r{d}", .{ reg(c.dst), @tagName(c.op), reg(c.operand) }),
        .Not => |c| try w.print("r{d} <- Not r{d}", .{ reg(c.dst), reg(c.src) }),
        .Cast => |c| try w.print("r{d} <- Cast r{d}", .{ reg(c.dst), reg(c.src) }),
        .InstanceOf => |c| try w.print("r{d} <- InstanceOf r{d}", .{ reg(c.dst), reg(c.src) }),
        .NotNullAssert => |c| try w.print("r{d} <- NotNullAssert r{d}", .{ reg(c.dst), reg(c.src) }),
        .Lambda => |c| try w.print("r{d} <- Lambda {s}#{d}", .{ reg(c.dst), funcName(m, c.body_func), c.body_func.int() }),
        .AstLambda => |c| {
            try w.print(
                "r{d} <- AstLambda {s}#{d} captures={d}",
                .{ reg(c.dst), if (c.body_func) |fid| funcName(m, fid) else "<deferred>", if (c.body_func) |fid| fid.int() else 0, c.captured_names.len },
            );
            // The capture list, register and name paired, so a wrong `this`
            // capture is visible at the creation site.
            for (c.captures, 0..) |cr, i| {
                try w.print("{s}r{d}:{s}", .{ if (i == 0) " [" else ", ", reg(cr), if (i < c.captured_names.len) c.captured_names[i] else "?" });
            }
            if (c.captures.len != 0) try w.writeAll("]");
        },
        else => try w.print("{s}", .{@tagName(inst.*)}),
    }
    try w.writeAll("\n");
}

fn constLabel(m: *const Module, id: ir.ConstId) []const u8 {
    const i = id.int();
    if (i >= m.consts.items.len) return "oob";
    return @tagName(m.consts.items[i]);
}

fn dumpTerminator(w: *std.Io.Writer, t: *const ir.Terminator) !void {
    switch (t.*) {
        .Goto => |b| try w.print("    goto b{d}\n", .{b.int()}),
        .Branch => |br| try w.print("    branch r{d} ? b{d} : b{d}\n", .{ reg(br.cond), br.t.int(), br.f.int() }),
        .Return => |r| if (r) |rr| try w.print("    return r{d}\n", .{reg(rr)}) else try w.writeAll("    return unit\n"),
        .Throw => |r| try w.print("    throw r{d}\n", .{reg(r)}),
        .Unreachable => try w.writeAll("    unreachable\n"),
        else => try w.print("    {s}\n", .{@tagName(t.*)}),
    }
}

fn dumpFunc(w: *std.Io.Writer, m: *const Module, f: *const Func, mod_tally: *Tally) !void {
    try w.print("func #{d}  {s}(", .{ f.id.int(), f.name });
    for (f.params, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s}", .{p.name});
    }
    try w.print(")   [kind={s}{s}{s} ret={s}{s}]\n", .{
        @tagName(f.kind),
        if (f.is_suspend) " suspend" else "",
        if (f.is_inline) " inline" else "",
        if (f.return_ty.name.len != 0) f.return_ty.name else "-",
        if (f.return_ty.nullable) "?" else "",
    });

    if (!f.hasBody()) {
        try w.writeAll("  <no body (native / abstract / deferred)>\n\n");
        return;
    }
    if (f.blocks.len == 0) {
        try w.writeAll("  <body deferred; not decoded>\n\n");
        return;
    }

    var tally: Tally = .{};
    for (f.blocks) |*b| {
        try w.print("  b{d}:\n", .{b.id.int()});
        for (b.insts) |*inst| {
            try w.writeAll("    ");
            try dumpInst(w, m, inst, &tally);
        }
        try dumpTerminator(w, &b.terminator);
    }
    try w.print("  calls: {d} direct, {d} virtual, {d} dynamic ({d} bound, {d} unbound)\n\n", .{
        tally.direct, tally.virtual, tally.dyn_bound + tally.dyn_unbound, tally.dyn_bound, tally.dyn_unbound,
    });
    mod_tally.direct += tally.direct;
    mod_tally.virtual += tally.virtual;
    mod_tally.dyn_bound += tally.dyn_bound;
    mod_tally.dyn_unbound += tally.dyn_unbound;
}

fn matches(f: *const Func, filter: []const u8) bool {
    return std.mem.indexOf(u8, f.name, filter) != null or std.mem.indexOf(u8, f.fqn, filter) != null;
}

pub fn dumpModule(w: *std.Io.Writer, m: *const Module, opts: Options) !void {
    var mod_tally: Tally = .{};
    var dumped: usize = 0;

    if (opts.func_filter) |filter| {
        for (m.funcs.items) |*f| {
            if (matches(f, filter)) {
                try dumpFunc(w, m, f, &mod_tally);
                dumped += 1;
            }
        }
    } else if (opts.all) {
        for (m.funcs.items) |*f| {
            try dumpFunc(w, m, f, &mod_tally);
            dumped += 1;
        }
    } else {
        // Default: the user program's own functions. `buildModuleFiles` links
        // the whole stdlib + any gated packs into one module, so restrict to
        // funcs with no package header (a user script). For a packaged file
        // (a library/test source) use `--func NAME` to target by name.
        for (m.funcs.items) |*f| {
            // Package-less + not a receiver method + not a synthesized thunk
            // ⇒ a top-level function of a user script (builtin `Pair.toString`
            // is an instance method; `__enum_arg_*`/`__sec_ctor_*` are
            // compiler-synthesized helpers).
            if (f.package.len != 0 or f.has_receiver_param or f.kind != .plain or
                f.is_lambda or std.mem.startsWith(u8, f.name, "__")) continue;
            try dumpFunc(w, m, f, &mod_tally);
            dumped += 1;
        }
        if (dumped == 0) {
            try w.writeAll("(no top-level package-less user functions; this file declares a package — use --func NAME or --all)\n");
        }
    }

    try w.print("module rollup: {d} functions, {d} direct, {d} virtual, {d} dynamic ({d} bound, {d} unbound)\n", .{
        dumped, mod_tally.direct, mod_tally.virtual, mod_tally.dyn_bound + mod_tally.dyn_unbound, mod_tally.dyn_bound, mod_tally.dyn_unbound,
    });
}
