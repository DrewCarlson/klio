//! Renumbering of the ids a lowered function carries, for bodies lowered on
//! a shard whose lambda and constant ids were allocated locally.

const std = @import("std");
const span = @import("span");
const core_ids = @import("ids.zig");
const core_func = @import("func.zig");
const core_inst = @import("inst.zig");
const ast = @import("ast");

const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const TypeRef = core_ids.TypeRef;

/// Ids at or past a base map through the tables; the rest are the module's own.
pub const IdMap = struct {
    func_base: u32,
    funcs: []const FuncId,
    const_base: u32,
    consts: []const ConstId,

    pub fn mapFunc(self: *const IdMap, id: FuncId) FuncId {
        const i = id.int();
        if (i < self.func_base) return id;
        return self.funcs[i - self.func_base];
    }

    fn mapConst(self: *const IdMap, id: ConstId) ConstId {
        const i = id.int();
        if (i < self.const_base) return id;
        return self.consts[i - self.const_base];
    }
};

/// Rewrites every FuncId and ConstId reachable from `f` in place. A single
/// pointer is followed only to a part the function owns out of line (marked
/// `hashed_by_content`); the rest lead to the AST and the module, which the
/// function only references.
pub fn remapFunc(f: *core_func.Func, m: *const IdMap) void {
    walk(core_func.Func, f, m);
}

fn walk(comptime T: type, v: *T, m: *const IdMap) void {
    if (T == FuncId) {
        v.* = m.mapFunc(v.*);
        return;
    }
    if (T == ConstId) {
        v.* = m.mapConst(v.*);
        return;
    }
    if (T == TypeRef or T == span.Span) return;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                walk(fld.type, &@field(v.*, fld.name), m);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            switch (v.*) {
                inline else => |*payload| walk(@TypeOf(payload.*), payload, m),
            }
        },
        .optional => |o| {
            if (v.*) |*inner| walk(o.child, inner, m);
        },
        .array => |arr| {
            for (v) |*e| walk(arr.child, e, m);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return;
                for (v.*) |*e| walk(p.child, @constCast(e), m);
            },
            .one => if (comptime ownedThroughPointer(p.child)) walk(p.child, @constCast(v.*), m),
            else => {},
        },
        else => {},
    }
}

/// A struct a function owns out of line and the walkers descend into.
fn ownedThroughPointer(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "hashed_by_content");
}

/// A hash of every value a lowered function carries, pointers excluded, so
/// two lowerings of one body can be compared without their addresses.
pub fn semanticHash(f: *const core_func.Func) u64 {
    var h = std.hash.Wyhash.init(0);
    hashWalk(core_func.Func, f, &h);
    return h.final();
}

/// The fingerprint reads two layouts alike: a block's handlers hash as if
/// they were inline, and a call payload's, a function's or a class's fields
/// hash in one fixed order whether a field sits in the struct or in its
/// `extra` box, so a layout change keeps the hash comparable across commits.
fn hashCanonical(comptime T: type, v: *const T, h: *std.hash.Wyhash) bool {
    if (@hasDecl(core_func, "BlockHandlers")) {
        if (T == ?*core_func.BlockHandlers) {
            hashWalk(core_func.BlockHandlers, v.* orelse &core_func.no_handlers, h);
            return true;
        }
    }
    if (T == core_func.Func) {
        hashNamed(v, &.{ "id", "name", "fqn", "package", "ref_key", "params", "return_ty", "return_ty_declared", "n_locals", "blocks", "deferred_offset", "entry", "is_suspend", "kind", "is_tailrec", "fast_call", "coerce_plan", "flat_class", "this_cap_idx", "acc_state", "acc_field", "acc_cls", "acc_route", "leaf_state", "fuse_state", "triv_init_state", "triv_init_val", "host_route", "compose_route", "throw_route", "frame_fill_state", "leaf_route", "leaf_bail_probe", "bc_memo", "bc_memo_fuse", "bc_jit_owned", "func_jit_probe", "bc_memo_gen", "leaf_hopeless", "has_receiver_param", "is_lambda", "lambda_receiver_shape_known", "lambda_has_receiver", "lambda_it_unconstrained", "lambda_receiver_ty", "is_inline", "capture_order", "implicit_label", "low_priority", "deprecated_error", "is_expect", "is_override", "is_open", "is_final", "annotation_names" }, h);
        return true;
    }
    if (T == ast.Class) {
        hashNamed(v, &.{ "name", "type_params", "where_bounds", "primary_params", "has_primary_ctor", "init_blocks", "init_block_positions", "supertypes", "supertype_args", "supertype_arg_names", "supertype_delegates", "is_data", "is_companion", "is_enum", "is_sealed", "is_open", "is_abstract", "is_inner", "secondary_ctors", "is_interface", "is_fun_interface", "is_value", "is_annotation", "is_expect", "is_actual", "enum_entries", "members", "visibility", "primary_ctor_visibility", "annotations", "span" }, h);
        return true;
    }
    if (T == core_inst.Inst) {
        switch (v.*) {
            .CallMember => |*p| {
                h.update("CallMember|");
                hashNamed(p, &.{ "dst", "receiver", "name", "args", "n_args", "arg_names", "trailing_lambda", "static_recv", "declared_recv", "resolved", "site_cls", "site_sig", "site_route", "dispatch_receiver" }, h);
                return true;
            },
            .CallVirtual => |*p| {
                h.update("CallVirtual|");
                hashNamed(p, &.{ "dst", "receiver", "slot", "args", "n_args", "arg_params", "arg_names", "trailing_lambda", "site_cls", "site_native", "site_name_ptr", "site_name_len" }, h);
                return true;
            },
            else => return false,
        }
    }
    return false;
}

/// Hashes `names` of a payload in order, reading a name from the payload when
/// it has the field, else from its `extra` box (or that box's default).
fn hashNamed(payload: anytype, comptime names: []const []const u8, h: *std.hash.Wyhash) void {
    const P = @TypeOf(payload.*);
    const Deref = if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
    const p = if (@typeInfo(P) == .pointer) payload.* else payload;
    inline for (names) |name| {
        if (comptime @hasField(Deref, name)) {
            hashWalk(@TypeOf(@field(p, name)), &@field(p, name), h);
        } else if (comptime @hasField(Deref, "extra")) {
            const E = @typeInfo(@typeInfo(@FieldType(Deref, "extra")).optional.child).pointer.child;
            const e = p.extra orelse &@as(E, .{});
            hashWalk(@TypeOf(@field(e, name)), &@field(e, name), h);
        }
    }
}

fn hashWalk(comptime T: type, v: *const T, h: *std.hash.Wyhash) void {
    if (hashCanonical(T, v, h)) return;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                hashWalk(fld.type, &@field(v.*, fld.name), h);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            // The tag by name, so reordering a union's variants changes no hash.
            h.update(@tagName(std.meta.activeTag(v.*)));
            h.update("|");
            switch (v.*) {
                inline else => |*payload| hashWalk(@TypeOf(payload.*), payload, h),
            }
        },
        .optional => |o| {
            if (v.*) |*inner| {
                h.update("some");
                hashWalk(o.child, inner, h);
            } else h.update("none");
        },
        .array => |arr| for (v) |*e| hashWalk(arr.child, e, h),
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    h.update(v.*);
                    h.update("|");
                } else for (v.*) |*e| hashWalk(p.child, e, h);
            },
            // A boxed AST node is content the instruction carries, hashed
            // through the pointer so the address itself never counts; the AST
            // is a tree, so there is no cycle to guard.
            .one => if (comptime (std.mem.startsWith(u8, @typeName(p.child), "ast.") or ownedThroughPointer(p.child))) hashWalk(p.child, v.*, h),
            else => {},
        },
        .int, .float, .bool, .@"enum" => h.update(std.mem.asBytes(v)),
        else => {},
    }
}

test "ids below the base are untouched and the rest map through the tables" {
    const funcs = [_]FuncId{ FuncId.from(40), FuncId.from(41) };
    const consts = [_]ConstId{ConstId.from(9)};
    const m = IdMap{ .func_base = 10, .funcs = &funcs, .const_base = 3, .consts = &consts };
    try std.testing.expectEqual(FuncId.from(7), m.mapFunc(FuncId.from(7)));
    try std.testing.expectEqual(FuncId.from(41), m.mapFunc(FuncId.from(11)));
    try std.testing.expectEqual(ConstId.from(2), m.mapConst(ConstId.from(2)));
    try std.testing.expectEqual(ConstId.from(9), m.mapConst(ConstId.from(3)));
}
