//! A total site census over a lowered module.
//!
//! Every instruction of every function is classified into exactly one site kind,
//! and every site kind carries a verdict: does the instruction name its target,
//! or does the runtime re-derive it from a name at execution? The classifying
//! switch is exhaustive over `Inst` and `Terminator`, so an instruction cannot
//! enter the IR without a classification — the census is complete by
//! construction rather than by upkeep.
//!
//! This is the static half of the ratchet. Its counterpart is the executed
//! census in `eval/diag.zig`, which counts the same decision at run time;
//! together they answer "how many sites are unresolved" and "how often does an
//! unresolved site run".
//!
//! Read it with `KLIO_SITE_CENSUS=1` (or any run under `KLIO_DISPATCH_STATS`).
//! `KLIO_SITE_CENSUS=lowered` restricts the walk to bodies already materialised,
//! which answers a different question — what the run actually lowered — and is
//! not comparable to a whole-program count.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

const Inst = ir.Inst;
const Terminator = ir.Terminator;
const Module = ir.Module;
const Func = ir.Func;

/// What the runtime must do at this site to reach its target.
pub const Verdict = enum(u8) {
    /// The instruction names its target: a `FuncId`, a `ClassId`, a method slot,
    /// a register, or a fixed index. No name is hashed and no table is probed.
    resolved,
    /// The target is re-derived from a name at execution. This is the column the
    /// resolution work drives to zero.
    unresolved,
    /// The target is a value the program computes, so Kotlin fixes nothing
    /// statically and there is nothing to resolve. A member of this column needs
    /// a justification, not a fix.
    dynamic_by_design,
};

/// Which kind of decision the site makes.
pub const Class = enum(u8) {
    /// Selecting a function to run.
    call,
    /// Reaching a field of an object.
    field,
    /// Reaching a named binding that is not a field.
    name,
    /// Selecting the receiver a later site dispatches on.
    receiver,
    /// Naming a type, for a cast, a test, or a context lookup.
    type_op,
    /// Everything with no target to resolve: arithmetic, moves, control flow.
    plain,
};

/// One row of the census. The kind names the instruction form, not the
/// instruction: two forms of the same instruction that differ in whether
/// lowering bound a target are separate kinds, because only then can one of
/// them reach zero.
pub const SiteKind = enum(u8) {
    // ---- calls ----
    /// `Call`: a `FuncId` chosen at lowering.
    call_static_id,
    /// `TailCallFunc`: the same, as a terminator.
    call_tail_static_id,
    /// `TailJump`: re-entry into this same function.
    call_tail_self,
    /// `CallVirtual`: a class-relative method slot chosen at lowering.
    call_virtual_slot,
    /// `CallMember` carrying `extra.resolved`.
    call_member_resolved,
    /// `CallMember` without one: the member is found by name at execution.
    call_member_by_name,
    /// `CallSpread` with a `virtual_slot`.
    call_spread_slot,
    /// `CallSpread` naming a member to dispatch by name.
    call_spread_member_name,
    /// `CallSpread` naming a bare global to resolve by name.
    call_spread_bare_name,
    /// `CallSpread` invoking a computed callable.
    call_spread_value,
    /// `CallMemberOrGlobal`: lowering could not decide between a member of an
    /// implicit receiver and a top-level function.
    call_member_or_global,
    /// `CallMemberOrGlobal` whose global leg a link pass proved is the only
    /// one that can win: no receiver in scope at the site declares the name,
    /// no extension of it exists, and the site already names the target. The
    /// member walk is then a longer route to that same declaration.
    call_member_or_global_static,
    /// `CallValueOrMember`: between a callable local and a member.
    call_value_or_member,
    /// `CallMemberOrValue`: between a member and a callable local.
    call_member_or_value,
    /// `CallValue`: invoking a callable the program computed.
    call_value,
    /// `CallValueWithThis`: the same, with a bound receiver.
    call_value_with_this,
    /// `NewInstance`: the `ClassId` is chosen at lowering, but the constructor
    /// overload is still selected from argument values at execution, so the
    /// target function is not named. Resolving it means recording the chosen
    /// constructor's `FuncId` on the instruction.
    call_new_instance,
    call_new_instance_sole_ctor,
    /// `NewInstance` carrying the constructor lowering resolved: the class's
    /// own overload set, decided from the call's shape and its static argument
    /// heads. Filled by `linkCtorPicks` once every class has lowered.
    call_new_instance_ctor_id,
    /// `NewList`: a fixed intrinsic.
    call_new_list,

    // ---- fields ----
    /// `GetField` carrying a declared slot of the receiver class's published
    /// layout. The runtime serves it directly: no name lookup, no discovery
    /// ladder. Claimed only for a plain stored property of a final class, so
    /// no accessor and no override can stand between the slot and the read.
    field_read_slot_claimed,
    /// The property is answered by an accessor, and the site names the getter
    /// rather than the name. Filled by `linkGetterRoutes` once every class
    /// body has lowered, since the getter does not exist before then.
    field_read_getter,
    /// The site carries a property slot and the receiver's runtime class picks
    /// the implementation out of the property table, the way a virtual call
    /// does. What the getter route cannot reach: a property declared where no
    /// implementation lives.
    field_read_prop_slot,
    name_enum_entry,
    field_write_slot_claimed,
    /// `GetField` whose field name is a builtin property of a host classifier
    /// the receiver's static head names: `size` on an array, `length` on a
    /// String. There is no declaration to bind, and no user extension can
    /// shadow a declared member, so naming the operation is the resolved form.
    field_read_builtin,
    /// `GetField`: a field name plus a per-site memo keyed by class and shape.
    field_read_by_name,
    /// `SetField`: a field name, no memo.
    field_write_by_name,
    /// `CompoundField`: read-modify-write by name.
    field_rmw_by_name,
    /// `Index`: the `get` operator, dispatched by name on the receiver.
    field_index_read,
    /// `IndexSet`: the `set` operator, dispatched by name.
    field_index_write,

    // ---- names ----
    /// `CellGet`: a boxed local, addressed by register.
    name_cell_read,
    /// `CellSet`: the same.
    name_cell_write,
    /// `LoadParam`: a parameter index.
    name_read_param_slot,
    /// `LoadOuterThis`: an inner-class instance's outer, one hop along its outer link.
    name_read_outer_this,
    /// `LoadDispatchThis`: a member-extension frame's dispatch receiver, handed over by the caller.
    name_read_dispatch_this,
    /// `LoadContextParam`: a contextual frame's context parameter, handed over by the caller.
    name_read_context_slot,
    /// `ContextPush` / `ContextPop`: the context arguments a call hands its contextual callee.
    call_context_push,
    call_context_pop,
    /// `LoadCapture`: a capture index.
    name_read_capture_slot,
    /// `LoadGlobal` carrying a `FuncId` or a `ClassId`.
    name_read_global_resolved,
    /// `LoadGlobal` carrying neither: resolved through the host by name.
    name_read_global_by_name,
    /// `LoadFromThisOrGlobal`: lowering could not decide between a member of an
    /// implicit receiver and a top-level binding.
    name_read_this_or_global,
    /// `StoreToThisOrGlobal`: the write counterpart.
    name_write_this_or_global,
    /// `StoreGlobal`: a top-level write by name.
    name_write_global_by_name,
    /// `StoreGlobal` carrying the property's slot.
    name_write_global_slot,
    /// `PropertyRef`: `::name`, a reflective reference that carries the name by
    /// definition.
    name_property_ref,
    /// `MemberRef` carrying a `FuncId`.
    name_member_ref_resolved,
    /// `MemberRef` without one: bound by name against the receiver.
    name_member_ref_by_name,
    /// `Lambda`: a `FuncId` for the body.
    name_lambda_resolved,

    // ---- receivers ----
    /// `QualifiedThis`: `this@Q`, walked along the dynamic enclosing chain.
    recv_qualified_this,
    /// `EnclosingPush`: extends that chain.
    recv_enclosing_push,
    /// `EnclosingPop`: retracts it.
    recv_enclosing_pop,

    // ---- types ----
    /// A `<class-companion-or-self>` read: a bare class name in value position.
    /// The spelling is fixed at lowering and the answer comes from the class's
    /// own memo, keyed by the class object rather than by any name. Resolved:
    /// there is no name left for the runtime to look anything up under.
    field_read_companion_or_self,
    /// `CallMember` naming a builtin operation over a static receiver head no
    /// interpreted instance can wear — in practice an array subscript. The
    /// site names the operation and the receiver kind, and the path is TOTAL:
    /// an array with an index outside it raises here rather than declining
    /// into the by-name walk. That totality is the whole of the claim, and
    /// `KLIO_BUILTIN_AUDIT` reported String and out-of-range declines until
    /// it held.
    call_member_builtin_op,
    /// `Cast`: the target type resolves by name.
    type_cast_by_name,
    /// `as T` where the site names the class and the test is an id comparison.
    type_cast_class,
    /// `InstanceOf`: the same.
    type_instanceof_by_name,
    /// `is T` where the site names the class and the test is an id comparison.
    type_instanceof_class,

    // ---- no target ----
    /// `Const`, `Move`, `MakeCell`, `BinOp`, `UnOp`, `Not`, `NotNullAssert`,
    /// `LateinitCheck`, `Trace`, `SuspendResumePoint`: operands are registers.
    plain_inst,
    /// `Goto`, `Branch`, `Switch`, `Return`, `Throw`, `Unreachable`,
    /// `NonLocalReturn`, `LabeledReturn`: control flow within the function.
    plain_terminator,
};

pub const kind_count = @typeInfo(SiteKind).@"enum".fields.len;

/// The class and verdict of each kind, as one table so a new kind must declare
/// both. Indexed by `@intFromEnum(SiteKind)`.
const Row = struct { class: Class, verdict: Verdict };

const rows: [kind_count]Row = blk: {
    var t: [kind_count]Row = undefined;
    const C = Class;
    const V = Verdict;
    t[@intFromEnum(SiteKind.call_static_id)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_tail_static_id)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_tail_self)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_virtual_slot)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_member_resolved)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_member_by_name)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_spread_slot)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_spread_member_name)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_spread_bare_name)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_spread_value)] = .{ .class = C.call, .verdict = V.dynamic_by_design };
    t[@intFromEnum(SiteKind.call_member_or_global)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_member_or_global_static)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_value_or_member)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_member_or_value)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_value)] = .{ .class = C.call, .verdict = V.dynamic_by_design };
    t[@intFromEnum(SiteKind.call_value_with_this)] = .{ .class = C.call, .verdict = V.dynamic_by_design };
    t[@intFromEnum(SiteKind.call_new_instance)] = .{ .class = C.call, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.call_new_instance_sole_ctor)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_new_instance_ctor_id)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_new_list)] = .{ .class = C.call, .verdict = V.resolved };

    t[@intFromEnum(SiteKind.field_read_slot_claimed)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.field_read_getter)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.field_read_prop_slot)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_enum_entry)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.field_write_slot_claimed)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.field_read_builtin)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.field_read_by_name)] = .{ .class = C.field, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.field_write_by_name)] = .{ .class = C.field, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.field_rmw_by_name)] = .{ .class = C.field, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.field_index_read)] = .{ .class = C.field, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.field_index_write)] = .{ .class = C.field, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_cell_read)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_cell_write)] = .{ .class = C.name, .verdict = V.resolved };

    t[@intFromEnum(SiteKind.name_read_param_slot)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_dispatch_this)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_outer_this)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_context_slot)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_context_push)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_context_pop)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_capture_slot)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_global_resolved)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_read_global_by_name)] = .{ .class = C.name, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_read_this_or_global)] = .{ .class = C.name, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_write_this_or_global)] = .{ .class = C.name, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_write_global_by_name)] = .{ .class = C.name, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_write_global_slot)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_property_ref)] = .{ .class = C.name, .verdict = V.dynamic_by_design };
    t[@intFromEnum(SiteKind.name_member_ref_resolved)] = .{ .class = C.name, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.name_member_ref_by_name)] = .{ .class = C.name, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.name_lambda_resolved)] = .{ .class = C.name, .verdict = V.resolved };

    t[@intFromEnum(SiteKind.recv_qualified_this)] = .{ .class = C.receiver, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.recv_enclosing_push)] = .{ .class = C.receiver, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.recv_enclosing_pop)] = .{ .class = C.receiver, .verdict = V.unresolved };

    t[@intFromEnum(SiteKind.field_read_companion_or_self)] = .{ .class = C.field, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.call_member_builtin_op)] = .{ .class = C.call, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.type_cast_by_name)] = .{ .class = C.type_op, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.type_cast_class)] = .{ .class = C.type_op, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.type_instanceof_by_name)] = .{ .class = C.type_op, .verdict = V.unresolved };
    t[@intFromEnum(SiteKind.type_instanceof_class)] = .{ .class = C.type_op, .verdict = V.resolved };

    t[@intFromEnum(SiteKind.plain_inst)] = .{ .class = C.plain, .verdict = V.resolved };
    t[@intFromEnum(SiteKind.plain_terminator)] = .{ .class = C.plain, .verdict = V.resolved };
    break :blk t;
};

pub fn classOf(k: SiteKind) Class {
    return rows[@intFromEnum(k)].class;
}

pub fn verdictOf(k: SiteKind) Verdict {
    return rows[@intFromEnum(k)].verdict;
}

/// Classify one instruction. The switch names every `Inst` tag, so adding one
/// without deciding what it resolves is a compile error.
/// `classify` plus the refinements that need the class table.
pub fn refine(module: ?*const Module, inst: *const Inst) SiteKind {
    const k = classify(inst);
    if (k == .call_member_or_global) {
        const m0 = module orelse return k;
        const cg = inst.CallMemberOrGlobal;
        if (!cg.global_only) return k;
        const fid = cg.func orelse return k;
        // An extension target needs its receiver prepended, which the global
        // leg cannot do, so the claim does not name it.
        const fd = m0.funcById(fid) orelse return k;
        if (fd.params.len != 0 and std.mem.eql(u8, fd.params[0].name, "this")) return k;
        return .call_member_or_global_static;
    }
    if (k != .call_new_instance) return k;
    const m = module orelse return k;
    const cid = inst.NewInstance.class;
    if (cid.int() >= m.classes.items.len) return k;
    const c = &m.classes.items[cid.int()];
    // One constructor is no choice: the site names its target as exactly as a
    // `Call` does.
    if (c.hasSoleCtor()) return .call_new_instance_sole_ctor;
    if (inst.NewInstance.ctor_pick != ir.CTOR_PICK_NONE) return .call_new_instance_ctor_id;
    return k;
}

pub fn classify(inst: *const Inst) SiteKind {
    return switch (inst.*) {
        .Call => .call_static_id,
        .CallVirtual => .call_virtual_slot,
        .CallMember => |cm| if (cm.x().resolved != null)
            .call_member_resolved
        else if (cm.builtin_proven)
            .call_member_builtin_op
        else
            .call_member_by_name,
        .CallSpread => |cs| if (cs.virtual_slot != null)
            .call_spread_slot
        else if (cs.member != null)
            .call_spread_member_name
        else if (cs.name != null)
            .call_spread_bare_name
        else
            .call_spread_value,
        .CallMemberOrGlobal => .call_member_or_global,
        .CallValueOrMember => .call_value_or_member,
        .CallMemberOrValue => .call_member_or_value,
        .CallValue => .call_value,
        .CallValueWithThis => .call_value_with_this,
        .NewInstance => .call_new_instance,
        .NewList => .call_new_list,

        .GetField => |gf| switch (gf.own_kind) {
            .enum_entry => .name_enum_entry,
            .slot => .field_read_slot_claimed,
            .getter => .field_read_getter,
            .prop_slot => .field_read_prop_slot,
            .companion_or_self => .field_read_companion_or_self,
            // A super read the link pass settled on the base's cell; one it
            // could not settle is by name in the census, since the runtime
            // refuses it, and the count says the emitter is missing a fact.
            .super_slot => .field_read_slot_claimed,
            .super_target => .field_read_by_name,
            .none => if (gf.builtin_proven) .field_read_builtin else .field_read_by_name,
        },
        .SetField => |sf| switch (sf.own_kind) {
            .super_slot => .field_write_slot_claimed,
            .super_target => .field_write_by_name,
            else => if (sf.own_cls != null) .field_write_slot_claimed else .field_write_by_name,
        },
        .CompoundField => .field_rmw_by_name,
        .Index => .field_index_read,
        .IndexSet => .field_index_write,
        .CellGet => .name_cell_read,
        .CellSet => .name_cell_write,

        .LoadParam => .name_read_param_slot,
        .LoadDispatchThis => .name_read_dispatch_this,
        .LoadOuterThis => .name_read_outer_this,
        .LoadContextParam => .name_read_context_slot,
        .ContextPush => .call_context_push,
        .ContextPop => .call_context_pop,
        .LoadCapture => .name_read_capture_slot,
        .LoadGlobal => |lg| if (lg.func != null or lg.class != null or lg.slot != null)
            .name_read_global_resolved
        else
            .name_read_global_by_name,
        .LoadFromThisOrGlobal => .name_read_this_or_global,
        .StoreToThisOrGlobal => .name_write_this_or_global,
        .StoreGlobal => |sg| if (sg.slot != null) .name_write_global_slot else .name_write_global_by_name,
        .PropertyRef => .name_property_ref,
        .MemberRef => |mr| if (mr.func != null) .name_member_ref_resolved else .name_member_ref_by_name,
        .Lambda => .name_lambda_resolved,

        .QualifiedThis => .recv_qualified_this,
        .EnclosingPush => .recv_enclosing_push,
        .EnclosingPop => .recv_enclosing_pop,

        .Cast => |ca| if (ca.cls() != null) .type_cast_class else .type_cast_by_name,
        .InstanceOf => |io| if (io.cls != null) .type_instanceof_class else .type_instanceof_by_name,

        .Const,
        .SuspendResumePoint,
        .Move,
        .MakeCell,
        .BinOp,
        .UnOp,
        .Not,
        .NotNullAssert,
        .LateinitCheck,
        .Trace,
        => .plain_inst,

        // Lowered from sema: every operand is an id.
        .CallStatic,
        .RCallVirtual,
        .CallInterface,
        .CallNative,
        .RCallValue,
        .RNewInstance,
        .GetFieldSlot,
        .SetFieldSlot,
        .LoadStatic,
        .StoreStatic,
        .LoadObject,
        .MakeClosure,
        .FunctionRef,
        .RPropertyRef,
        .ClassLiteral,
        .ClassOf,
        .RInstanceOf,
        .RCast,
        .InstanceOfDyn,
        .CastDyn,
        .ArrayGet,
        .ArraySet,
        .NewArray,
        => .plain_inst,
    };
}

/// Classify one terminator, on the same total-switch rule.
pub fn classifyTerminator(t: *const Terminator) SiteKind {
    return switch (t.*) {
        .TailCallFunc => .call_tail_static_id,
        .TailJump => .call_tail_self,
        .Goto,
        .Branch,
        .Switch,
        .Return,
        .Throw,
        .Unreachable,
        .NonLocalReturn,
        .LabeledReturn,
        => .plain_terminator,
    };
}

/// The identifier a site resolves by, for a diagnostic that names it. `"-"`
/// when the site carries no name (an indexing operator, an enclosing push).
/// The receiver head a site was lowered with, or `?` when it carried none.
fn siteRecvHead(module: *const Module, inst: *const Inst) []const u8 {
    const own: ?ir.ClassId = switch (inst.*) {
        .GetField => |gf| gf.own_cls,
        .SetField => |sf| sf.own_cls,
        else => null,
    };
    if (own) |c| {
        if (c.int() < module.classes.items.len) return module.classes.items[c.int()].fqn;
    }
    const id: ?ir.ConstId = switch (inst.*) {
        // An explicit receiver records `declared_recv`; the extension-body
        // implicit receiver records `static_recv`. Either names the head.
        .CallMember => |cm| cm.x().static_recv orelse cm.x().declared_recv,
        else => null,
    };
    const cid = id orelse return "?";
    if (cid.int() >= module.consts.items.len) return "?";
    return switch (module.consts.items[cid.int()]) {
        .String => |str| str,
        else => "?",
    };
}

pub fn siteName(module: *const Module, inst: *const Inst) []const u8 {
    const id: ?ir.ConstId = switch (inst.*) {
        .CallMember => |cm| cm.name,
        .CallMemberOrValue => |c| c.name,
        .CallValueOrMember => |c| c.name,
        .CallMemberOrGlobal => |c| c.name,
        .CallSpread => |cs| cs.member orelse cs.name,
        .GetField => |gf| gf.field,
        .SetField => |sf| sf.field,
        .CompoundField => |cf| cf.field,
        .LoadGlobal => |lg| lg.name,
        .LoadFromThisOrGlobal => |lt| lt.name,
        .StoreToThisOrGlobal => |st| st.name,
        .StoreGlobal => |sg| sg.name,
        .PropertyRef => |pr| pr.name,
        .MemberRef => |mr| mr.name,
        .QualifiedThis => |qt| qt.qualifier,
        .Index, .IndexSet => null,
        else => null,
    };
    const cid = id orelse return switch (inst.*) {
        .Index => "get",
        .IndexSet => "set",
        .Cast => |c| c.ty.name,
        .InstanceOf => |io| io.ty.name,
        .NewInstance => |ni| if (ni.class.int() < module.classes.items.len) module.classes.items[ni.class.int()].fqn else "<init>",
        else => "-",
    };
    const i = cid.int();
    if (i >= module.consts.items.len) return "-";
    const c = module.consts.items[i];
    return if (c == .String) c.String else "-";
}

/// The register holding the value a site dispatches on, where it has one, so a
/// diagnostic can name the receiver's runtime type.
pub fn siteReceiver(inst: *const Inst) ?ir.Reg {
    return switch (inst.*) {
        .CallMember => |cm| cm.receiver,
        .CallMemberOrValue => |c| c.receiver,
        .CallValueOrMember => |c| c.this_recv,
        .GetField => |gf| gf.receiver,
        .SetField => |sf| sf.receiver,
        .CompoundField => |cf| cf.receiver,
        .Index => |ix| ix.receiver,
        .IndexSet => |ix| ix.receiver,
        .MemberRef => |mr| mr.receiver,
        .QualifiedThis => |qt| qt.receiver,
        else => null,
    };
}

/// Whether an execution of this site kind is reported to the resolution
/// ratchet. A `false` is a NAMED GAP in the executed census: the static census
/// still counts the sites, but `KLIO_REQUIRE_RESOLVED` cannot catch one
/// running. The switch is total, so a new kind must declare which it is.
pub fn ratchetHooked(k: SiteKind) bool {
    return switch (k) {
        // Reached through an interpreter tier's instruction gate.
        .call_member_by_name,
        .call_spread_member_name,
        .call_spread_bare_name,
        .call_member_or_global,
        .call_value_or_member,
        .call_member_or_value,
        .call_new_instance,
        .field_read_by_name,
        .field_write_by_name,
        .field_rmw_by_name,
        .field_index_read,
        .field_index_write,
        .name_read_global_by_name,
        .name_read_this_or_global,
        .name_write_this_or_global,
        .name_write_global_by_name,
        .name_member_ref_by_name,
        .recv_qualified_this,
        .recv_enclosing_push,
        .recv_enclosing_pop,
        .type_cast_by_name,
        .type_instanceof_by_name,
        => true,
        // Nothing to report: these name their target already.
        .call_context_push,
        .call_context_pop,
        .type_instanceof_class,
        .type_cast_class,
        .call_member_builtin_op,
        .field_read_companion_or_self,
        .call_static_id,
        .call_tail_static_id,
        .call_tail_self,
        .call_virtual_slot,
        .call_member_resolved,
        .call_spread_slot,
        .call_spread_value,
        .call_value,
        .call_value_with_this,
        .call_new_list,
        .name_cell_read,
        .name_cell_write,
        .name_read_param_slot,
        .name_read_dispatch_this,
        .name_read_outer_this,
        .name_read_context_slot,
        .name_read_capture_slot,
        .field_read_slot_claimed,
        .field_read_getter,
        .field_read_prop_slot,
        .field_read_builtin,
        .call_new_instance_sole_ctor,
        .call_new_instance_ctor_id,
        .call_member_or_global_static,
        .name_enum_entry,
        .field_write_slot_claimed,
        .name_read_global_resolved,
        .name_write_global_slot,
        .name_property_ref,
        .name_member_ref_resolved,
        .name_lambda_resolved,
        .plain_inst,
        .plain_terminator,
        => false,
    };
}

pub const Counts = struct {
    kinds: [kind_count]u64 = @splat(0),
    /// Functions the module can address.
    funcs: u64 = 0,
    /// Functions whose instruction stream the walk read.
    funcs_walked: u64 = 0,
    /// Functions that declare a body the walk could not materialise. A non-zero
    /// value means the census is incomplete and its zeros do not count.
    funcs_unreadable: u64 = 0,
    /// Declaration-only functions: host-backed, `expect`, or abstract.
    funcs_bodyless: u64 = 0,
    blocks: u64 = 0,

    pub fn total(self: *const Counts) u64 {
        var n: u64 = 0;
        for (self.kinds) |c| n += c;
        return n;
    }

    pub fn byVerdict(self: *const Counts, v: Verdict) u64 {
        var n: u64 = 0;
        for (self.kinds, 0..) |c, i| {
            if (rows[i].verdict == v) n += c;
        }
        return n;
    }

    pub fn byClassVerdict(self: *const Counts, c: Class, v: Verdict) u64 {
        var n: u64 = 0;
        for (self.kinds, 0..) |cnt, i| {
            if (rows[i].class == c and rows[i].verdict == v) n += cnt;
        }
        return n;
    }

    pub fn get(self: *const Counts, k: SiteKind) u64 {
        return self.kinds[@intFromEnum(k)];
    }

    pub fn addFunc(self: *Counts, f: *const Func) void {
        self.addFuncIn(null, f);
    }

    /// `module` refines the kinds that need the class table to decide: a
    /// construction of a class with one constructor has nothing to choose.
    pub fn addFuncIn(self: *Counts, module: ?*const Module, f: *const Func) void {
        self.funcs_walked += 1;
        for (f.blocks) |*b| {
            self.blocks += 1;
            for (b.insts) |*inst| self.kinds[@intFromEnum(refine(module, inst))] += 1;
            self.kinds[@intFromEnum(classifyTerminator(&b.terminator))] += 1;
        }
    }
};

/// How much of the module the walk covers.
pub const Coverage = enum {
    /// Materialise every deferred body first: the whole program's sites.
    whole_program,
    /// Only bodies already in memory: what this run lowered. Not comparable to
    /// a `whole_program` count.
    lowered_only,
};

pub fn census(module: *const Module, coverage: Coverage) Counts {
    var c: Counts = .{};
    const n = module.funcCount();
    c.funcs = n;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const f = module.funcById(@enumFromInt(i)) orelse continue;
        if (f.blocks.len == 0) {
            if (!f.hasBody()) {
                c.funcs_bodyless += 1;
                continue;
            }
            if (coverage == .lowered_only) continue;
            if (!module.ensureFuncBody(@constCast(f))) {
                c.funcs_unreadable += 1;
                continue;
            }
        }
        c.addFuncIn(module, f);
    }
    return c;
}

fn pct(n: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total));
}

var census_state: u8 = 0;
var census_coverage: Coverage = .whole_program;

/// Whether the static census runs, resolved once. `KLIO_SITE_CENSUS` turns it on
/// by itself; a `KLIO_DISPATCH_STATS` run gets it alongside the executed census.
pub fn censusOn() bool {
    if (census_state == 0) {
        census_state = 1;
        if (runtime.envOnce("KLIO_SITE_CENSUS")) |v| {
            if (v.len != 0 and !std.mem.eql(u8, v, "0")) census_state = 2;
            if (std.mem.eql(u8, v, "lowered")) census_coverage = .lowered_only;
        } else if (runtime.envOnce("KLIO_DISPATCH_STATS") != null) {
            census_state = 2;
        }
    }
    return census_state == 2;
}

pub fn dump(module: *const Module) void {
    if (!censusOn()) return;
    dumpWith(module, census_coverage);
}

const NameRow = struct { name: []const u8, n: usize };

/// `KLIO_SITE_NAMES=<kind>`: the identifiers the unresolved sites of one
/// kind resolve by, most frequent first.
///
/// The counts say which kind is left; this says WHICH NAMES are, and every
/// residual closed in this campaign was found by reading one of them back to
/// the code that emitted it.
fn dumpNames(module: *const Module, want: []const u8) void {
    const a = std.heap.page_allocator;
    var counts = runtime.NameHashMap(usize).init(a);
    defer counts.deinit();
    const n_funcs = module.funcCount();
    var fi: u32 = 0;
    while (fi < n_funcs) : (fi += 1) {
        const f = module.funcById(@enumFromInt(fi)) orelse continue;
        if (f.blocks.len == 0) continue;
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                const k = refine(module, inst);
                if (verdictOf(k) != .unresolved) continue;
                if (!std.mem.eql(u8, @tagName(k), want)) continue;
                const nm = siteName(module, inst);
                // The head the site would have to name a member on. Without
                // it a name row says what is unresolved and not what stands
                // in front of it, which is the question the row is read for.
                var kb: [192]u8 = undefined;
                const key = std.fmt.bufPrint(&kb, "{s} on {s}", .{ nm, siteRecvHead(module, inst) }) catch nm;
                const gop = counts.getOrPut(key) catch continue;
                if (!gop.found_existing) gop.key_ptr.* = a.dupe(u8, key) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }
    var name_rows: std.ArrayList(NameRow) = .empty;
    defer name_rows.deinit(a);
    var it = counts.iterator();
    while (it.next()) |e| name_rows.append(a, .{ .name = e.key_ptr.*, .n = e.value_ptr.* }) catch {};
    std.mem.sort(NameRow, name_rows.items, {}, struct {
        fn gt(_: void, x: NameRow, y: NameRow) bool {
            return x.n > y.n;
        }
    }.gt);
    for (name_rows.items, 0..) |r, i| {
        if (i >= 20) break;
        std.debug.print("[site-name] {d:>8}  {s}\n", .{ r.n, r.name });
    }
}

pub fn dumpWith(module: *const Module, coverage: Coverage) void {
    const c = census(module, coverage);
    // After `census`, which materialises the deferred bodies the walk needs.
    if (runtime.envOnce("KLIO_SITE_NAMES")) |want| dumpNames(module, want);
    const total = c.total();
    if (total == 0) return;
    std.debug.print(
        "[site-census] coverage={s} funcs={d} walked={d} bodyless={d} unreadable={d} blocks={d} sites={d}\n",
        .{ @tagName(coverage), c.funcs, c.funcs_walked, c.funcs_bodyless, c.funcs_unreadable, c.blocks, total },
    );
    inline for (@typeInfo(Verdict).@"enum".fields) |f| {
        const n = c.byVerdict(@enumFromInt(f.value));
        std.debug.print("[site-census] {s}={d} ({d:.2}%)\n", .{ f.name, n, pct(n, total) });
    }
    inline for (@typeInfo(Class).@"enum".fields) |cf| {
        const r = c.byClassVerdict(@enumFromInt(cf.value), .resolved);
        const u = c.byClassVerdict(@enumFromInt(cf.value), .unresolved);
        const d = c.byClassVerdict(@enumFromInt(cf.value), .dynamic_by_design);
        if (r + u + d != 0) std.debug.print(
            "[site-class] {s:<9} resolved={d:<9} unresolved={d:<9} dynamic={d}\n",
            .{ cf.name, r, u, d },
        );
    }
    inline for (@typeInfo(SiteKind).@"enum".fields) |f| {
        const n = c.kinds[f.value];
        if (n != 0) std.debug.print("[site-kind] {d:>10} {d:>6.2}%  {s:<11} {s}\n", .{
            n,
            pct(n, total),
            @tagName(rows[f.value].verdict),
            f.name,
        });
    }
}

const testing = std.testing;

test "every site kind carries a class and a verdict" {
    // `rows` is built by index, so a kind nobody filled in reads as undefined
    // memory rather than failing to compile. Reading each entry's tag catches it.
    inline for (@typeInfo(SiteKind).@"enum".fields) |f| {
        const r = rows[f.value];
        try testing.expect(@intFromEnum(r.class) < @typeInfo(Class).@"enum".fields.len);
        try testing.expect(@intFromEnum(r.verdict) < @typeInfo(Verdict).@"enum".fields.len);
    }
}

test "the classifier separates a bound member call from a by-name one" {
    const bound_extra = ir.CallMemberExtra{ .resolved = @enumFromInt(7) };
    const bound = Inst{ .CallMember = .{
        .dst = ir.Reg.from(0),
        .receiver = ir.Reg.from(1),
        .name = @enumFromInt(0),
        .args = ir.Reg.from(2),
        .n_args = 0,
        .extra = &bound_extra,
    } };
    try testing.expectEqual(SiteKind.call_member_resolved, classify(&bound));
    try testing.expectEqual(Verdict.resolved, verdictOf(classify(&bound)));

    const by_name = Inst{ .CallMember = .{
        .dst = ir.Reg.from(0),
        .receiver = ir.Reg.from(1),
        .name = @enumFromInt(0),
        .args = ir.Reg.from(2),
        .n_args = 0,
    } };
    try testing.expectEqual(SiteKind.call_member_by_name, classify(&by_name));
    try testing.expectEqual(Verdict.unresolved, verdictOf(classify(&by_name)));
}

test "a proven builtin property is resolved and an unproven one is not" {
    const proven = Inst{ .GetField = .{
        .dst = ir.Reg.from(0),
        .receiver = ir.Reg.from(1),
        .field = @enumFromInt(0),
        .builtin = .array_size,
        .builtin_proven = true,
    } };
    try testing.expectEqual(SiteKind.field_read_builtin, classify(&proven));
    try testing.expectEqual(Verdict.resolved, verdictOf(classify(&proven)));

    // The name alone is not the proof: a user class with a `size` property
    // reads the same name and answers it from its own layout.
    const named = Inst{ .GetField = .{
        .dst = ir.Reg.from(0),
        .receiver = ir.Reg.from(1),
        .field = @enumFromInt(0),
        .builtin = .array_size,
    } };
    try testing.expectEqual(SiteKind.field_read_by_name, classify(&named));
    try testing.expectEqual(Verdict.unresolved, verdictOf(classify(&named)));
}

test "the classifier separates a bound global read from a by-name one" {
    const bound = Inst{ .LoadGlobal = .{ .dst = ir.Reg.from(0), .name = @enumFromInt(0), .func = @enumFromInt(3) } };
    try testing.expectEqual(SiteKind.name_read_global_resolved, classify(&bound));
    const by_name = Inst{ .LoadGlobal = .{ .dst = ir.Reg.from(0), .name = @enumFromInt(0) } };
    try testing.expectEqual(SiteKind.name_read_global_by_name, classify(&by_name));
}

test "the or-instructions are each their own unresolved kind" {
    var cmg = ir.CallMemberOrGlobalInst{
        .dst = ir.Reg.from(0),
        .this_idx = 0,
        .name = @enumFromInt(0),
        .args = ir.Reg.from(1),
        .n_args = 0,
        .arg_names = &.{},
    };
    const a = Inst{ .CallMemberOrGlobal = &cmg };
    try testing.expectEqual(SiteKind.call_member_or_global, classify(&a));

    const b = Inst{ .CallValueOrMember = .{
        .dst = ir.Reg.from(0),
        .callee = ir.Reg.from(1),
        .this_recv = ir.Reg.from(2),
        .name = @enumFromInt(0),
        .args = ir.Reg.from(3),
        .n_args = 0,
    } };
    try testing.expectEqual(SiteKind.call_value_or_member, classify(&b));

    const c = Inst{ .CallMemberOrValue = .{
        .dst = ir.Reg.from(0),
        .receiver = ir.Reg.from(1),
        .name = @enumFromInt(0),
        .fallback = ir.Reg.from(2),
        .args = ir.Reg.from(3),
        .n_args = 0,
    } };
    try testing.expectEqual(SiteKind.call_member_or_value, classify(&c));

    const d = Inst{ .LoadFromThisOrGlobal = .{ .dst = ir.Reg.from(0), .this_idx = 0, .name = @enumFromInt(0) } };
    try testing.expectEqual(SiteKind.name_read_this_or_global, classify(&d));

    inline for (.{ a, b, c, d }) |inst| {
        try testing.expectEqual(Verdict.unresolved, verdictOf(classify(&inst)));
        try testing.expectEqual(Class.call, classOf(classify(&a)));
    }
}

test "counting walks blocks and terminators" {
    var insts = [_]Inst{
        .{ .Const = .{ .dst = ir.Reg.from(0), .value = @enumFromInt(0) } },
        .{ .GetField = .{ .dst = ir.Reg.from(1), .receiver = ir.Reg.from(0), .field = @enumFromInt(0) } },
    };
    var blocks = [_]ir.Block{.{
        .id = @enumFromInt(0),
        .insts = &insts,
        .terminator = .{ .Return = ir.Reg.from(1) },
    }};
    var f = ir.Func{
        .id = @enumFromInt(0),
        .name = "f",
        .fqn = "f",
        .params = &.{},
        .return_ty = .{ .name = "Unit", .nullable = false, .args = &.{} },
        .n_locals = 2,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
        .is_suspend = false,
    };
    var c: Counts = .{};
    c.addFunc(&f);
    try testing.expectEqual(@as(u64, 1), c.blocks);
    try testing.expectEqual(@as(u64, 3), c.total());
    try testing.expectEqual(@as(u64, 1), c.get(.field_read_by_name));
    try testing.expectEqual(@as(u64, 1), c.get(.plain_terminator));
    try testing.expectEqual(@as(u64, 1), c.byVerdict(.unresolved));
    try testing.expectEqual(@as(u64, 1), c.byClassVerdict(.field, .unresolved));
}

test "every unresolved site kind is reported to the ratchet" {
    // The executed census must be able to see every kind the static census
    // counts as unresolved; a gap here is a hole in the ratchet, not a detail.
    inline for (@typeInfo(SiteKind).@"enum".fields) |f| {
        const k: SiteKind = @enumFromInt(f.value);
        if (verdictOf(k) == .unresolved) try testing.expect(ratchetHooked(k));
        if (verdictOf(k) == .resolved) try testing.expect(!ratchetHooked(k));
    }
}
