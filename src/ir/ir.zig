//! Compact linear IR for the klio interpreter: a flat instruction stream instead of a
//! tree walk. Each `Func` carries a `[]Block`, each `Block` a `[]Inst` plus a
//! `Terminator`, and operands are `Reg` indices rather than stack slots. The IR reuses
//! `runtime.Value` directly.
//!
//! This file is the module root: it owns the `Module` registry struct and re-exports
//! the rest of the IR from `core/`.

const std = @import("std");
const span = @import("span");

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const FileId = span.FileId;

pub const eval = @import("eval.zig");
pub const bc = @import("bc.zig");
pub const disasm = @import("disasm.zig");

const core_ids = @import("core/ids.zig");
const core_inst = @import("core/inst.zig");
const core_func = @import("core/func.zig");
const core_class = @import("core/class.zig");
const core_consts = @import("core/consts.zig");
const m_lookup = @import("core/module_lookup.zig");
const m_props = @import("core/module_props.zig");

pub const TypeRef = core_ids.TypeRef;
pub const Reg = core_ids.Reg;
pub const BlockId = core_ids.BlockId;
pub const FuncId = core_ids.FuncId;
pub const MethodSlotId = core_ids.MethodSlotId;
pub const ClassId = core_ids.ClassId;
pub const ConstId = core_ids.ConstId;
pub const NativeId = core_ids.NativeId;
pub const StaticId = core_ids.StaticId;
pub const NO_FUNC = core_ids.NO_FUNC;

pub const snapshot_fast = @import("snapshot_fast.zig");

/// Identities and run-time tables for code lowered from sema.
pub const bridge = @import("core/bridge.zig");
pub const resolved = @import("core/resolved.zig");
pub const Resolved = resolved.Resolved;
/// Register liveness, and the renumbering that lets registers share.
pub const regs = @import("core/regs.zig");
/// What a frame is known by from its position.
pub const framemap = @import("core/framemap.zig");
/// The span a frame stands in, from its position.
pub const spanmap = @import("core/spanmap.zig");
/// The try regions a frame stands in, from its position.
pub const trymap = @import("core/trymap.zig");
/// Lowering from sema's records.
pub const lower_sema = @import("lower/sema/mod.zig");

pub const Inst = core_inst.Inst;
pub const NO_UNIT = core_inst.NO_UNIT;
pub const BinOp = core_inst.BinOp;
pub const UnOp = core_inst.UnOp;
pub const visitInstRegs = core_inst.visitInstRegs;
pub const visitTerminatorRegs = core_inst.visitTerminatorRegs;
pub const Terminator = core_inst.Terminator;
pub const CatchHandler = core_inst.CatchHandler;

pub const Block = core_func.Block;
pub const BlockHandlers = core_func.BlockHandlers;
pub const FuncKind = core_func.FuncKind;
pub const Func = core_func.Func;
pub const FuncExtra = core_func.FuncExtra;
pub const Param = core_func.Param;

pub const Class = core_class.Class;
pub const FieldSlot = core_class.FieldSlot;
pub const SlotSeed = core_class.SlotSeed;
pub const DeclaredProp = core_class.DeclaredProp;
pub const CtorArity = core_class.CtorArity;
pub const FieldLayout = core_class.FieldLayout;
pub const FieldLayoutState = core_class.FieldLayoutState;

pub const Module = struct {
    /// A `Module` may be written only during single-threaded setup, before any interpreter
    /// thread runs. Mutating one after execution starts needs its own synchronisation.
    pub const objref_immutable = true;

    funcs: std.ArrayList(Func) = .empty,
    /// Funcs appended after the module went live, each in its own allocation: an append
    /// never moves a `Func` a running frame points at, whereas `funcs` reallocates.
    late_funcs: std.ArrayList(*Func) = .empty,
    /// Route `appendFunc` to `late_funcs`: frames may hold `*const Func` while it grows.
    funcs_live: bool = false,
    /// Lazy IR: byte section holding deferred functions' `blocks`, each self-contained and
    /// decoded on first execution. Borrows the image buffer; empty unless image-loaded.
    deferred_func_section: []const u8 = &.{},
    /// Process-lifetime allocator a decoded `blocks` slice must persist in.
    deferred_func_arena: Allocator = undefined,
    /// Injected decoder (`image.decodeFuncBlocks`), null until installed.
    deferred_func_decode: ?*const fn (Allocator, []const u8, u32) ?[]Block = null,
    /// Lazy IR func headers: per-func sections plus offsets (`id -> offset+1`, 0 = absent),
    /// decoded on first `funcById` and memoised in `func_cache`. Empty unless image-loaded.
    func_header_section: []const u8 = &.{},
    func_header_offsets: []const u32 = &.{},
    func_header_decode: ?*const fn (Allocator, []const u8, u32) ?Func = null,
    func_cache: []?*Func = &.{},
    func_header_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    classes: std.ArrayList(Class) = .empty,
    consts: std.ArrayList(Const) = .empty,
    /// Top-level (file-scope) function ids, in declaration order.
    top_level: std.ArrayList(FuncId) = .empty,
    /// Allocator for `const_dedup`; null disables it, so `internConst` scans.
    lookup_cache_gpa: ?Allocator = null,
    /// `internConst` dedup: const hash to the first `ConstId` with it; a collision falls back to a scan.
    const_dedup: std.AutoHashMapUnmanaged(u64, ConstId) = .empty,
    const_dedup_n: usize = 0,
    package: ?[]const u8 = null,
    /// Link-time virtual dispatch table. Keys pack a runtime `ClassId` in the high word and a
    /// declaration-rooted `MethodSlotId` in the low word; method names never enter dispatch.
    method_dispatch: std.AutoHashMap(u64, FuncId),
    /// Per class, its transitive supertype closure including itself, sorted by
    /// id so a subtype test is a binary search. Rebuilt at link time.
    class_ancestors: std.ArrayList([]const ClassId) = .empty,
    /// The run-time tables of code lowered from sema; null for a module lowered
    /// the other way.
    resolved: ?*Resolved = null,

    pub const init = m_lookup.init;
    pub const default = m_lookup.default;
    pub const deinit = m_lookup.deinit;
    pub const ensureFuncBody = m_lookup.ensureFuncBody;
    pub const funcById = m_lookup.funcById;
    pub const funcByIdMut = m_lookup.funcByIdMut;
    pub const internConst = m_lookup.internConst;
    pub const topUpConstDedup = m_lookup.topUpConstDedup;

    pub const classIsA = m_props.classIsA;
    pub const methodDispatchKey = m_props.methodDispatchKey;
    pub const methodSlotTarget = m_props.methodSlotTarget;
};

pub const Const = core_consts.Const;

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("core/class.zig"));
    testing.refAllDecls(@import("core/consts.zig"));
    testing.refAllDecls(@import("core/func.zig"));
    testing.refAllDecls(@import("core/ids.zig"));
    testing.refAllDecls(@import("core/inst.zig"));
    testing.refAllDecls(@import("core/module_props.zig"));
    testing.refAllDecls(@import("core/module_lookup.zig"));
    testing.refAllDecls(regs);
    testing.refAllDecls(framemap);
    testing.refAllDecls(spanmap);
    testing.refAllDecls(trymap);
    testing.refAllDecls(resolved);
    testing.refAllDecls(bridge);
    _ = lower_sema;
}
