const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("runtime");
const core_ids = @import("ids.zig");
const core_inst = @import("inst.zig");

const BlockId = core_ids.BlockId;
const CatchHandler = core_inst.CatchHandler;
const FuncId = core_ids.FuncId;
const Inst = core_inst.Inst;
const Reg = core_ids.Reg;
const Terminator = core_inst.Terminator;
const TypeRef = core_ids.TypeRef;
const visitInstRegs = core_inst.visitInstRegs;
const visitTerminatorRegs = core_inst.visitTerminatorRegs;

/// A basic block: instruction stream plus terminator. With a non-empty `catches`, a
/// `Throw` raised anywhere in the try scope looks up a handler here before propagating.
/// The exception-handling metadata of a block, present on the few that carry
/// any: a try body, its join, a finally sentinel, a labeled-return absorption
/// region. Out of line, so a block is 64 bytes rather than 152 and the walkers
/// that remap, hash and encode a function follow the pointer.
pub const BlockHandlers = struct {
    catches: []CatchHandler = &.{},
    /// Finally-block id to run on every exit from this block's try-region. Paired with
    /// `finally_done` so eval can tell entering the finally from having finished it.
    finally: ?BlockId = null,
    /// Post-finally sentinel for this try-region; reached only after the finally completes.
    finally_done: ?BlockId = null,
    /// When this block IS a post-finally sentinel, the try-region body entry it keys: the
    /// match for the `TryFrame.body` eval popped.
    finally_done_for: ?BlockId = null,
    /// When this block is the JOIN of a catch-only try, the try body's entry block. Normal
    /// flow arriving here pops that body's `TryFrame`, which otherwise only a throw does.
    catch_done_for: ?BlockId = null,
    /// Try-region body entries whose `TryFrame` this block pops when it exits via `Goto`:
    /// an inline `return` replays its finallys inline and bypasses the sentinel that pops them.
    pop_on_exit: []const BlockId = &.{},

    /// The remap and fingerprint walkers follow a pointer to this type.
    pub const hashed_by_content = {};

    pub fn any(self: *const BlockHandlers) bool {
        return self.catches.len != 0 or self.finally != null or self.finally_done != null or
            self.finally_done_for != null or self.catch_done_for != null or
            self.pop_on_exit.len != 0;
    }
};

/// What a block without handlers reads through `h()`.
pub const no_handlers: BlockHandlers = .{};

pub const Block = struct {
    id: BlockId,
    insts: []Inst,
    terminator: Terminator,
    /// Null on the blocks that carry none; read through `h()`, written through `handlersMut`.
    handlers: ?*BlockHandlers = null,

    pub inline fn h(self: *const Block) *const BlockHandlers {
        return self.handlers orelse &no_handlers;
    }

    /// The handlers to write, allocated on first use.
    pub fn handlersMut(self: *Block, a: Allocator) Allocator.Error!*BlockHandlers {
        if (self.handlers) |p| return p;
        const p = try a.create(BlockHandlers);
        p.* = .{};
        self.handlers = p;
        return p;
    }
};

/// Classification of a lowered function, for the runtime extension scorer. A member
/// extension lowers with a leading `"this"` param just like an instance method and a
/// top-level extension, so `param[0]` cannot tell them apart.
pub const FuncKind = enum {
    /// Ordinary top-level or local function, or a constructor / init thunk.
    plain,
    instance_method,
    top_level_extension,
    member_extension,
};

/// The header fields most functions leave at their defaults, out of line:
/// the adapted-reference key, a receiver lambda's receiver head, the capture
/// order, the implicit label and the annotation names. A function header is
/// 232 bytes with them boxed, 304 inline, and the image decodes a header per
/// function the run reaches.
pub const FuncExtra = struct {
    /// For the forwarding lambda of an adapted callable reference: target plus adaptation
    /// (`fqn|arity|unit`), so two wrappers of the same adaptation compare and hash equal.
    ref_key: []const u8 = "",
    /// Declared receiver head of a receiver-lambda body. The receiver arrives at invocation
    /// rather than occupying a parameter slot; the head selects it from the receiver tower.
    lambda_receiver_ty: ?[]const u8 = null,
    /// Capture-name list in `LoadCapture` index order; the dispatch site builds the vector in it.
    capture_order: [][]const u8 = &.{},
    /// For a lambda body, the simple name of the function the literal was passed to: its
    /// implicit label, so `this@with` resolves to the receiver it was invoked with.
    implicit_label: ?[]const u8 = null,
    /// Resolved fully-qualified names of each source annotation; empty for the baked image.
    annotation_names: []const []const u8 = &.{},
    /// The class whose members this body's bare names resolve against, for a
    /// body that is not itself a declaration. A lambda runs in a frame whose
    /// implicit receiver its own signature does not spell, and nothing else
    /// records it. Empty means "recorded, and there is none"; null means "not
    /// recorded", which is what a caller must refuse to reason from.
    lexical_owner: ?[]const u8 = null,
    /// The declared type head of each context parameter, in declaration order: the
    /// caller hands the values over as `context` chain entries in this order, and a
    /// frame no caller served derives each from its chain by the type.
    ctx_types: []const []const u8 = &.{},

    pub const hashed_by_content = {};

    pub fn isDefault(self: *const FuncExtra) bool {
        return self.ref_key.len == 0 and self.lambda_receiver_ty == null and self.capture_order.len == 0 and
            self.implicit_label == null and self.annotation_names.len == 0 and self.lexical_owner == null and
            self.ctx_types.len == 0;
    }
};

pub const no_func_extra: FuncExtra = .{};

pub const Func = struct {
    id: FuncId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path; empty for a script with no package header.
    package: []const u8 = "",
    params: []Param,
    return_ty: TypeRef,
    /// Whether `return_ty` came from an explicit `: T`. An expression body with no annotation
    /// gets `Unit` as a PLACEHOLDER, so treat the return type as fact only when this is set.
    return_ty_declared: bool = false,
    n_locals: u32,
    blocks: []Block,
    /// Lazy IR: `offset + 1` of this function's blocks in the module's
    /// `deferred_func_section`, `0` when present. Bodyless checks use `hasBody`.
    deferred_offset: u32 = 0,
    entry: BlockId,
    is_suspend: bool,
    /// Func classification for the extension scorer; `plain` unless the member-extension lowering sets it.
    kind: FuncKind = .plain,
    is_tailrec: bool = false,
    /// Bytecode-stream table memo (`bc.funcStreams`): 0 unresolved, 1 none, else a
    /// `*const bc.FuncStreams`.
    bc_memo: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// `bc.streamGen()` at fill time; a stale generation must fall to the shared path.
    bc_memo_gen: u32 = 0,
    /// True when `params[0]` is a synthesized `this` receiver (a dispatch receiver, an instance
    /// under construction, any injected leading `this`), not a parameter merely spelled `this`.
    has_receiver_param: bool = false,
    /// Synthetic lambda body: `return` propagates as a non-local return through this frame.
    is_lambda: bool = false,
    /// Lowering had a declared function-type shape; false makes `lambda_has_receiver` mean unknown.
    lambda_receiver_shape_known: bool = false,
    /// This callable's function type declares an extension receiver, supplied at invocation
    /// and not counted in `params`, so the VM never infers it from an extra argument.
    lambda_has_receiver: bool = false,
    /// The lambda kept its parser-injected `it` because no expected function type
    /// constrained it: kotlinc types such a lambda `() -> R`, so its arity reads as zero.
    lambda_it_unconstrained: bool = false,
    /// `inline fun`: a non-local `return` from a lambda passed to it unwinds through this frame.
    is_inline: bool = false,
    /// Marked `@LowPriorityInOverloadResolution` or `@Deprecated(level = ERROR)`: a valid
    /// overload target only when no ordinary candidate applies.
    low_priority: bool = false,
    /// The low-priority mark came from `@Deprecated(level = ERROR|HIDDEN)`, which a
    /// caller-side `@Suppress("DEPRECATION_ERROR")` restores to ordinary ranking.
    deprecated_error: bool = false,
    /// An `expect` declaration. Its `actual` may live outside the pack's source set, in which
    /// case nothing serves the call and the runtime says so instead of returning `Unit`.
    is_expect: bool = false,
    /// A lazy build deferred this body: the header stands in its slot and
    /// the body lowers on first execution, so it counts as having a body.
    lazy_deferred: bool = false,
    /// Carries the source `override` modifier. A call resolved against a STATIC receiver type
    /// must exclude a subtype's same-name non-override, which is outside that member scope.
    is_override: bool = false,
    /// Carries `open`. A method neither `open` nor `override` cannot be overridden, so a call to it is monomorphic.
    is_open: bool = false,
    /// Carries `final`. On an `override` member it seals the method, monomorphic despite `is_override`.
    is_final: bool = false,

    /// Null when every rare header field is at its default; read through `x()`.
    extra: ?*const FuncExtra = null,

    /// Run memos an image must not carry: an image built in a process that ran code would
    /// otherwise hand its pointers to the next process.
    pub const image_cache = .{ "bc_memo", "bc_memo_gen" };

    pub inline fn x(self: *const Func) *const FuncExtra {
        return self.extra orelse &no_func_extra;
    }

    /// Replaces the rare fields; a box is allocated only when some field
    /// leaves its default, and a box already there is reused.
    pub fn setExtra(self: *Func, a: Allocator, e: FuncExtra) Allocator.Error!void {
        if (self.extra) |old| {
            @constCast(old).* = e;
            return;
        }
        if (e.isDefault()) return;
        const p = try a.create(FuncExtra);
        p.* = e;
        self.extra = p;
    }

    /// Frees what a builder allocated for this function on `a`: the block
    /// and instruction arrays, the handler boxes, the boxed instruction
    /// payloads and their extras, the capture order and the header's extra
    /// box. For a function built on a general allocator, as the unit tests
    /// do; a module on an arena never needs it.
    pub fn freeBuilt(self: *const Func, a: Allocator) void {
        for (self.blocks) |b| {
            for (b.insts) |inst| switch (inst) {
                .CallMember => |cm| if (cm.extra) |e| a.destroy(e),
                .CallVirtual => |cv| if (cv.extra) |e| a.destroy(e),
                .CallSpread => |p| a.destroy(p),
                .CallMemberOrGlobal => |p| a.destroy(p),
                else => {},
            };
            if (b.insts.len != 0) a.free(b.insts);
            if (b.handlers) |hs| {
                if (hs.catches.len != 0) a.free(hs.catches);
                a.destroy(hs);
            }
        }
        a.free(self.blocks);
        if (self.x().capture_order.len != 0) a.free(self.x().capture_order);
        if (self.extra) |e| a.destroy(e);
    }

    /// True when this function has an IR body: present blocks, or blocks deferred to the
    /// image's lazy-IR section. Every bodyless check uses this, never a bare `blocks.len`.
    pub fn hasBody(self: *const Func) bool {
        // The offset first: a decode on another thread writes the blocks
        // before it clears the offset (`Module.ensureFuncBody`), so blocks
        // read after a cleared offset are the published ones.
        if (@atomicLoad(u32, &self.deferred_offset, .acquire) != 0) return true;
        return self.blocks.len != 0 or self.lazy_deferred;
    }

    /// Whether a fresh frame may leave its register file unfilled: every register read is
    /// preceded by a write on ALL paths from entry (`defBeforeUse`). The function's code table
    /// (`bc.FuncStreams.no_fill`) keeps the answer.
    pub fn frameDefBeforeUse(self: *const Func) bool {
        if (self.n_locals > FRAME_FILL_MAX_REGS) return false;
        return defBeforeUse(self.blocks, self.entry.int());
    }
};

/// Whether every register `blocks` read is written first on every path from `entry`, by a
/// forward must-written dataflow over the edges. A throw in a try region reaches its catch or
/// its finally from wherever the region has got to, and a register stays written once it is,
/// so a handler starts with at least what was written where its region began, the start of
/// the block that names it; a catch with its exception register written too.
pub fn defBeforeUse(blocks: []const Block, entry: u32) bool {
    const nb = blocks.len;
    if (nb == 0 or nb > FRAME_FILL_MAX_BLOCKS) return false;
    if (entry >= nb) return false;
    const Ctx = struct {
        uses: RegSet = regSetEmpty(),
        defs: RegSet = regSetEmpty(),
        oob: bool = false,
        fn visit(c: *@This(), reg: Reg, is_def: bool) void {
            const r = reg.int();
            if (r >= FRAME_FILL_MAX_REGS) {
                c.oob = true;
                return;
            }
            if (is_def) regSetSet(&c.defs, r) else regSetSet(&c.uses, r);
        }
    };
    // Per-block summary: `gen` = registers the block writes, `exposed` = registers it reads
    // before writing them; an instruction's own def never covers its own use. The scratch
    // is thread-local because stack arrays this size are poisoned under safe builds.
    const scratch = frame_fill_scratch.get();
    const gen = &scratch.sets[0];
    const exposed = &scratch.sets[1];
    for (blocks, 0..) |*b, bi| {
        var written: RegSet = regSetEmpty();
        var expo: RegSet = regSetEmpty();
        for (b.insts) |*inst| {
            var c: Ctx = .{};
            visitInstRegs(inst, &c, Ctx.visit);
            if (c.oob) return false;
            regSetOrAndNot(&expo, c.uses, written);
            regSetOr(&written, c.defs);
        }
        var c: Ctx = .{};
        visitTerminatorRegs(&b.terminator, &c, Ctx.visit);
        if (c.oob) return false;
        regSetOrAndNot(&expo, c.uses, written);
        regSetOr(&written, c.defs);
        gen[bi] = written;
        exposed[bi] = expo;
        for (b.h().catches) |ch| {
            if (ch.handler.int() >= nb or ch.exception_reg.int() >= FRAME_FILL_MAX_REGS) return false;
        }
        if (b.h().finally) |f| if (f.int() >= nb) return false;
    }
    // Forward must-written fixpoint. Unreachable blocks keep the ALL set and verify
    // vacuously; nothing reaches the entry with more written than nothing.
    const in = &scratch.sets[2];
    for (0..nb) |bi| in[bi] = regSetFull();
    in[entry] = regSetEmpty();
    var rounds: usize = 0;
    while (rounds < nb + 8) : (rounds += 1) {
        var changed = false;
        for (blocks, 0..) |*b, bi| {
            var out = in[bi];
            regSetOr(&out, gen[bi]);
            switch (b.terminator) {
                .Goto => |t| {
                    if (t.int() >= nb) return false;
                    if (t.int() != entry and regSetAndInto(&in[t.int()], out)) changed = true;
                },
                .Branch => |br| {
                    for ([2]BlockId{ br.t, br.f }) |t| {
                        if (t.int() >= nb) return false;
                        if (t.int() != entry and regSetAndInto(&in[t.int()], out)) changed = true;
                    }
                },
                .Return, .Throw, .Unreachable => {},
            }
            for (b.h().catches) |ch| {
                var at = in[bi];
                regSetSet(&at, ch.exception_reg.int());
                const t = ch.handler.int();
                if (t != entry and regSetAndInto(&in[t], at)) changed = true;
            }
            if (b.h().finally) |f| {
                if (f.int() != entry and regSetAndInto(&in[f.int()], in[bi])) changed = true;
            }
        }
        if (!changed) break;
    } else return false;
    for (0..nb) |bi| {
        if (regSetAnyOutside(exposed[bi], in[bi])) return false;
    }
    return true;
}

/// CFG size bound for `frameDefBeforeUse`'s dataflow; a larger body keeps the eager fill.
pub const FRAME_FILL_MAX_BLOCKS: usize = 256;

/// Register-set width for `frameDefBeforeUse`, in 64-bit words. Compose composables and
/// slot-table walkers run 70 to 500 locals, so one word sends all of them to eager fill.
pub const FRAME_FILL_WORDS: usize = 8;

pub const FRAME_FILL_MAX_REGS: u32 = FRAME_FILL_WORDS * 64;

pub const RegSet = [FRAME_FILL_WORDS]u64;

inline fn regSetEmpty() RegSet {
    return @splat(0);
}
inline fn regSetFull() RegSet {
    return @splat(~@as(u64, 0));
}
inline fn regSetSet(a: *RegSet, i: usize) void {
    a[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
}
inline fn regSetOrAndNot(dst: *RegSet, x: RegSet, notted: RegSet) void {
    for (dst, x, notted) |*d, xv, nv| d.* |= xv & ~nv;
}
inline fn regSetOr(dst: *RegSet, x: RegSet) void {
    for (dst, x) |*d, xv| d.* |= xv;
}
inline fn regSetAndInto(dst: *RegSet, x: RegSet) bool {
    var changed = false;
    for (dst, x) |*d, xv| {
        const nv = d.* & xv;
        if (nv != d.*) {
            d.* = nv;
            changed = true;
        }
    }
    return changed;
}
inline fn regSetAnyOutside(a: RegSet, b: RegSet) bool {
    for (a, b) |av, bv| {
        if (av & ~bv != 0) return true;
    }
    return false;
}

/// `frameDefBeforeUse` scratch (gen / exposed / in). Thread-local so the once-per-func
/// analysis skips the safe builds' stack poisoning and concurrent first-asks stay apart.
const FrameFillScratch = struct { sets: [3][FRAME_FILL_MAX_BLOCKS]RegSet = undefined };
const frame_fill_scratch = runtime.tls_fast.PerThread(FrameFillScratch);

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    default: ?BlockId,
    /// Source function-type arity when this parameter is `@Composable`; null means an ordinary one.
    composable_arity: ?u8 = null,
    /// Extension-receiver and context slots of a `@Composable` function-typed parameter:
    /// the leading value slots a non-inline sink's lambda takes beyond `composable_arity`.
    composable_recv_slots: u8 = 0,
    /// The primary-ctor param doubles as a class property, so its argument becomes a field.
    is_property: bool = false,
    /// `vararg`: trailing positional args are packed into a typed array before binding.
    is_vararg: bool = false,
    /// The parameter declares a default value. The lowered default lives in a separate thunk,
    /// so `default` stays null, but the flag decides applicability by argument count.
    has_default: bool = false,
};

test "a register read before any write on some path from entry needs a filled frame" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var entry_insts = [_]Inst{.{ .Const = .{ .dst = r(0), .value = k } }};
    var then_insts = [_]Inst{.{ .Const = .{ .dst = r(1), .value = k } }};
    var join_insts = [_]Inst{.{ .Move = .{ .dst = r(2), .src = r(1) } }};
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &entry_insts, .terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } } },
        .{ .id = BlockId.from(1), .insts = &then_insts, .terminator = .{ .Goto = BlockId.from(2) } },
        .{ .id = BlockId.from(2), .insts = &join_insts, .terminator = .{ .Return = r(2) } },
    };
    // The join reads r1, which the path straight from the entry never writes.
    try std.testing.expect(!defBeforeUse(&blocks, 0));
    // Written on both paths, it is.
    entry_insts[0] = .{ .Const = .{ .dst = r(1), .value = k } };
    blocks[0].terminator = .{ .Branch = .{ .cond = r(1), .t = BlockId.from(1), .f = BlockId.from(2) } };
    try std.testing.expect(defBeforeUse(&blocks, 0));
}

test "a catch or finally starts with what was written where its try region began" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    // Block 0 writes r0 and enters the try at block 1, which writes r1 and returns; block 2
    // catches into r3 and block 3 is the finally.
    var before = [_]Inst{.{ .Const = .{ .dst = r(0), .value = k } }};
    var body = [_]Inst{.{ .Const = .{ .dst = r(1), .value = k } }};
    var catch_insts = [_]Inst{.{ .Move = .{ .dst = r(2), .src = r(0) } }};
    var fin_insts = [_]Inst{.{ .Move = .{ .dst = r(4), .src = r(0) } }};
    var catches = [_]CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(3) }};
    var try_handlers: BlockHandlers = .{ .catches = &catches, .finally = BlockId.from(3) };
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &before, .terminator = .{ .Goto = BlockId.from(1) } },
        .{ .id = BlockId.from(1), .insts = &body, .terminator = .{ .Return = r(1) }, .handlers = &try_handlers },
        .{ .id = BlockId.from(2), .insts = &catch_insts, .terminator = .{ .Return = r(2) } },
        .{ .id = BlockId.from(3), .insts = &fin_insts, .terminator = .{ .Return = r(4) } },
    };
    try std.testing.expect(defBeforeUse(&blocks, 0));
    // The catch reads its exception.
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(3) } };
    try std.testing.expect(defBeforeUse(&blocks, 0));
    // A register only the try body writes may not be written yet when it throws.
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(1) } };
    try std.testing.expect(!defBeforeUse(&blocks, 0));
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(0) } };
    fin_insts[0] = .{ .Move = .{ .dst = r(4), .src = r(1) } };
    try std.testing.expect(!defBeforeUse(&blocks, 0));
    // Nor is another catch's exception register written.
    fin_insts[0] = .{ .Move = .{ .dst = r(4), .src = r(3) } };
    try std.testing.expect(!defBeforeUse(&blocks, 0));
}
