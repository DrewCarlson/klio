const std = @import("std");
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");
const core_inst = @import("inst.zig");

const BlockId = core_ids.BlockId;
const CatchHandler = core_inst.CatchHandler;
const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const Inst = core_inst.Inst;
const LrAbsorb = core_inst.LrAbsorb;
const Module = root_ir.Module;
const Reg = core_ids.Reg;
const Terminator = core_inst.Terminator;
const TypeRef = core_ids.TypeRef;
const visitInstRegs = core_inst.visitInstRegs;
const visitTerminatorRegs = core_inst.visitTerminatorRegs;

/// A basic block: instruction stream plus terminator. With a non-empty `catches`, a
/// `Throw` raised anywhere in the try scope looks up a handler here before propagating.
pub const Block = struct {
    id: BlockId,
    insts: []Inst,
    terminator: Terminator,
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
    /// Entering this block arms a labeled-return absorption region (see `LrAbsorb`).
    lr_absorb: ?LrAbsorb = null,
    /// Try-region body entries whose `TryFrame` this block pops when it exits via `Goto`:
    /// an inline `return` replays its finallys inline and bypasses the sentinel that pops them.
    pop_on_exit: []const BlockId = &.{},
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

/// `Func.fast_call` flag: the body carries its receiver as the leading `"this"` param, so fast dispatch seeds the caller's `this`.
pub const FAST_CALL_EXT_FLAG: u16 = 0x4000;

/// `Func.fast_call` flag: the callee's simple name has same-arity peers, so only the call
/// site can say whether the baked target is what scope resolution picks; it caches that.
pub const FAST_CALL_AMBIG_FLAG: u16 = 0x2000;

/// Whether the declaration currently lowering carries `@Suppress("DEPRECATION_ERROR")`,
/// under which kotlinc restores `@Deprecated(level = ERROR)` candidates to ordinary rank.
pub threadlocal var suppress_deprecation_error: bool = false;

pub fn setSuppressDeprecationError(v: bool) bool {
    const prev = suppress_deprecation_error;
    suppress_deprecation_error = v;
    return prev;
}

/// Effective low-priority rank at the site: a deprecation-ERROR overload ranks ordinary under the suppression.
pub fn rankLowPriority(f: *const Func) bool {
    return f.low_priority and !(f.deprecated_error and suppress_deprecation_error);
}

pub const Func = struct {
    id: FuncId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path; empty for a script with no package header.
    package: []const u8 = "",
    /// For the forwarding lambda of an adapted callable reference: target plus adaptation
    /// (`fqn|arity|unit`), so two wrappers of the same adaptation compare and hash equal.
    ref_key: []const u8 = "",
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
    /// Monomorphic call fast-path plan, cached on first call: 0 = not computed, 1 =
    /// ineligible, else the low 14 bits are the eligible parameter count + 2, plus the flags.
    fast_call: u16 = 0,
    /// Argument-coercion walks that can apply to the declared params, computed on first frame
    /// entry: bit0 = computed, bit1 = a non-vararg `Long` param, bit2 = 2+ params with a type variable.
    coerce_plan: u8 = 0,
    /// Flattening verdict: 0 unknown, 1 flattenable (simple subset, no catches or finally), 2 not.
    flat_class: u8 = 0,
    /// Index of `"this"` in `capture_order`: -2 = not yet computed, -1 = no `this` capture.
    this_cap_idx: i32 = -2,
    /// Accessor-shape memo: 0 = unknown, 1 = not an accessor, 2 = the body is exactly
    /// `LoadParam #0; GetField; return`, with `acc_field` holding the GetField name.
    acc_state: u8 = 0,
    acc_field: u32 = 0,
    /// Single-fill (CAS from 0) claimed receiver-class identity and its packed stored-slot
    /// route for the frameless accessor read; only the winner writes `acc_route`.
    acc_cls: u64 = 0,
    acc_route: u64 = 0,
    /// Cached `leafExprBody` verdict: 0 = unasked, 1 = no, 2 = yes.
    leaf_state: u8 = 0,
    /// Fused-tier verdict: 0 = unasked, 1 = eligible (this body and every statically-resolved
    /// callee), 2 = ineligible, 3 = in progress, which reads eligible until the root settles.
    fuse_state: u8 = 0,
    /// Trivial property-initializer memo: 0 = unasked, 1 = not trivial, 2 = returns one
    /// constant (`triv_init_val` = ConstId), 3 = echoes one parameter (`triv_init_val` = index).
    triv_init_state: u8 = 0,
    triv_init_val: u32 = 0,
    /// Host-served static routing memo: 0 = unasked, else a `snapshot_fast.Route`.
    host_route: u8 = 0,
    /// Compose fast-path verdict (`compose_fast.Route`), classified on first execution.
    compose_route: u8 = 0,
    /// Throw-capable host-serve route (`hostRouteServeThrowing`): 0 unasked, 1 none,
    /// 2 the gap-buffer changelist wrapper, 3 the link-buffer one.
    throw_route: u8 = 0,
    /// Cached `frameNoFill` verdict: 0 = unasked, 1 = must fill, 2 = may start unfilled.
    frame_fill_state: u8 = 0,
    /// Scalar-replay (`kl_`) route memo: 0 unresolved, 1 none, else the registered
    /// NativeLeafFn as an address. The table is write-once before the program runs.
    leaf_route: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Leaf bail damper: bit 31 = the leaf served at least once (sticky), low bits count
    /// bails while never-served. Past the threshold the route flips to `none`.
    leaf_bail_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Bytecode-stream table memo (`bc.funcStreams`): 0 unresolved, 1 none, else a
    /// `*const bc.FuncStreams`. `bc_memo_fuse` says which allow_fuse variant it holds.
    bc_memo: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bc_memo_fuse: u8 = 0,
    /// The loop JIT owns a block here: its deopts resume at instruction indices, so these streams stop fusing.
    bc_jit_owned: bool = false,
    /// Function-JIT hotness probe shared across threads: low bits count activations, bit 30 =
    /// some thread compiled a body, bit 31 = compilation declined (sticky). See `jit_loop`.
    func_jit_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// `bc.streamGen()` at fill time; a stale generation must fall to the shared path.
    bc_memo_gen: u32 = 0,
    /// The frameless leaf serve hit a structurally unsupported instruction here, so every
    /// future serve would abandon at the same place and the attempt is skipped outright.
    leaf_hopeless: u8 = 0,
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
    /// Declared receiver head of a receiver-lambda body. The receiver arrives at invocation
    /// rather than occupying a parameter slot; the head selects it from the receiver tower.
    lambda_receiver_ty: ?[]const u8 = null,
    /// `inline fun`: a non-local `return` from a lambda passed to it unwinds through this frame.
    is_inline: bool = false,
    /// Capture-name list in `LoadCapture` index order; the dispatch site builds the vector in it.
    capture_order: [][]const u8 = &.{},
    /// For a lambda body, the simple name of the function the literal was passed to: its
    /// implicit label, so `this@with` resolves to the receiver it was invoked with.
    implicit_label: ?[]const u8 = null,
    /// Marked `@LowPriorityInOverloadResolution` or `@Deprecated(level = ERROR)`: a valid
    /// overload target only when no ordinary candidate applies.
    low_priority: bool = false,
    /// The low-priority mark came from `@Deprecated(level = ERROR|HIDDEN)`, which a
    /// caller-side `@Suppress("DEPRECATION_ERROR")` restores to ordinary ranking.
    deprecated_error: bool = false,
    /// An `expect` declaration. Its `actual` may live outside the pack's source set, in which
    /// case nothing serves the call and the runtime says so instead of returning `Unit`.
    is_expect: bool = false,
    /// Carries the source `override` modifier. A call resolved against a STATIC receiver type
    /// must exclude a subtype's same-name non-override, which is outside that member scope.
    is_override: bool = false,
    /// Carries `open`. A method neither `open` nor `override` cannot be overridden, so a call to it is monomorphic.
    is_open: bool = false,
    /// Carries `final`. On an `override` member it seals the method, monomorphic despite `is_override`.
    is_final: bool = false,
    /// Resolved fully-qualified names of each source annotation; empty for the baked image.
    annotation_names: []const []const u8 = &.{},

    /// True when this function has an IR body: present blocks, or blocks deferred to the
    /// image's lazy-IR section. Every bodyless check uses this, never a bare `blocks.len`.
    pub fn hasBody(self: *const Func) bool {
        return self.blocks.len != 0 or self.deferred_offset != 0;
    }

    /// The GetField name ConstId when the body is exactly `LoadParam #0; GetField; return`,
    /// else null. An image body decodes lazily, so classification needs the module in hand.
    pub fn accessorFieldConstIn(self: *const Func, module: *const Module) ?ConstId {
        if (self.acc_state == 0 and self.blocks.len == 0) {
            _ = module.ensureFuncBody(@constCast(self));
        }
        return self.accessorFieldConst();
    }

    pub fn accessorFieldConst(self: *const Func) ?ConstId {
        switch (self.acc_state) {
            1 => return null,
            2 => return @enumFromInt(self.acc_field),
            else => {},
        }
        if (self.blocks.len == 0) return null;
        const verdict: ?ConstId = blk: {
            if (self.params.len != 1 or self.is_suspend or self.blocks.len != 1) break :blk null;
            const b = &self.blocks[0];
            if (b.catches.len != 0 or b.insts.len != 2) break :blk null;
            const lp = switch (b.insts[0]) {
                .LoadParam => |lp| lp,
                else => break :blk null,
            };
            if (lp.idx != 0) break :blk null;
            const gf = switch (b.insts[1]) {
                .GetField => |gf| gf,
                else => break :blk null,
            };
            if (gf.receiver != lp.dst) break :blk null;
            const ret = switch (b.terminator) {
                .Return => |r| r orelse break :blk null,
                else => break :blk null,
            };
            if (ret != gf.dst) break :blk null;
            break :blk gf.field;
        };
        if (verdict) |f| {
            @constCast(self).acc_field = @intCast(f.int());
            @constCast(self).acc_state = 2;
            return f;
        }
        @constCast(self).acc_state = 1;
        return null;
    }

    /// Whether this body is a leaf expression: one block, no handlers, a `Return` of a register,
    /// and only parameter loads, constants, stored-field reads, moves and primitive operators,
    /// so it evaluates without building a frame.
    pub fn leafExprBody(self: *const Func) bool {
        switch (self.leaf_state) {
            1 => return false,
            2, 3 => return true,
            else => {},
        }
        // A DEFERRED body carries no blocks until the image section decodes it; classifying
        // one here would cache "not a leaf" for a function that becomes one on load.
        if (self.blocks.len == 0) return false;
        const verdict = self.classifyLeafExprBody();
        @constCast(self).leaf_state = if (!verdict)
            1
        else if (self.leafDefBeforeUse())
            3
        else
            2;
        return verdict;
    }

    /// Whether every register read is dominated by a write, by the same block or by the entry
    /// block. Then the leaf serve can skip zero-filling its register bank.
    pub fn leafNoFill(self: *const Func) bool {
        return self.leaf_state == 3;
    }

    fn leafDefBeforeUse(self: *const Func) bool {
        const Ctx = struct {
            uses: u64 = 0,
            defs: u64 = 0,
            oob: bool = false,
            fn visit(c: *@This(), reg: Reg, is_def: bool) void {
                const r = reg.int();
                if (r >= 64) {
                    c.oob = true;
                    return;
                }
                const bit = @as(u64, 1) << @intCast(r);
                if (is_def) c.defs |= bit else c.uses |= bit;
            }
        };
        var entry_written: u64 = 0;
        for (self.blocks, 0..) |*b, bi| {
            var written: u64 = entry_written;
            for (b.insts) |*inst| {
                var c: Ctx = .{};
                visitInstRegs(inst, &c, Ctx.visit);
                if (c.oob) return false;
                if (c.uses & ~written != 0) return false;
                written |= c.defs;
            }
            var c: Ctx = .{};
            visitTerminatorRegs(&b.terminator, &c, Ctx.visit);
            if (c.oob) return false;
            if (c.uses & ~written != 0) return false;
            written |= c.defs;
            if (bi == 0) entry_written = written;
        }
        return true;
    }

    /// Whether a fresh frame may leave its register file unfilled: every register read is
    /// preceded by a write on ALL paths from entry, proved by a must-written dataflow over the
    /// CFG. Catch/finally/absorption bodies keep the eager fill, since an exception edge can
    /// enter a handler mid-block.
    pub fn frameNoFill(self: *const Func) bool {
        switch (self.frame_fill_state) {
            1 => return false,
            2 => return true,
            else => {},
        }
        // A deferred body has no blocks to analyze yet; decide and cache once it decodes.
        if (self.blocks.len == 0) return false;
        const verdict = self.frameDefBeforeUse();
        @constCast(self).frame_fill_state = if (verdict) 2 else 1;
        return verdict;
    }

    fn frameDefBeforeUse(self: *const Func) bool {
        if (self.n_locals > FRAME_FILL_MAX_REGS) return false;
        const nb = self.blocks.len;
        if (nb == 0 or nb > FRAME_FILL_MAX_BLOCKS) return false;
        const entry_idx = self.entry.int();
        if (entry_idx >= nb) return false;
        for (self.blocks) |*b| {
            if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return false;
        }
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
        const gen = &frame_fill_scratch[0];
        const exposed = &frame_fill_scratch[1];
        for (self.blocks, 0..) |*b, bi| {
            var written: RegSet = regSetEmpty();
            var expo: RegSet = regSetEmpty();
            for (b.insts) |*inst| {
                // `CtxScope.ctx_args` is a run of `n_ctx` registers the `args`+`n_args` convention
                // does not cover, so its tail goes unreported as uses. Keep the eager fill.
                if (inst.* == .CtxScope) return false;
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
        }
        // Forward must-written fixpoint. Unreachable blocks keep the ALL set and verify
        // vacuously; a `TailJump` resets the register file so it contributes no edge.
        const in = &frame_fill_scratch[2];
        for (0..nb) |bi| in[bi] = regSetFull();
        in[entry_idx] = regSetEmpty();
        var rounds: usize = 0;
        while (rounds < nb + 8) : (rounds += 1) {
            var changed = false;
            for (self.blocks, 0..) |*b, bi| {
                var out = in[bi];
                regSetOr(&out, gen[bi]);
                switch (b.terminator) {
                    .Goto => |t| {
                        if (t.int() >= nb) return false;
                        if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                    },
                    .Branch => |br| {
                        for ([2]BlockId{ br.t, br.f }) |t| {
                            if (t.int() >= nb) return false;
                            if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                        }
                    },
                    .Switch => |sw| {
                        for (sw.arms) |arm| {
                            const t = arm.target;
                            if (t.int() >= nb) return false;
                            if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                        }
                        const t = sw.default;
                        if (t.int() >= nb) return false;
                        if (t.int() != entry_idx and regSetAndInto(&in[t.int()], out)) changed = true;
                    },
                    .Return, .Throw, .Unreachable, .TailJump, .TailCallFunc, .NonLocalReturn, .LabeledReturn => {},
                }
            }
            if (!changed) break;
        } else return false;
        for (0..nb) |bi| {
            if (regSetAnyOutside(exposed[bi], in[bi])) return false;
        }
        return true;
    }

    /// Structural admission only. Which instructions a leaf serve can execute is decided as it
    /// runs, since a value-returning path of pure leaf work can sit beside a branch that is not.
    fn classifyLeafExprBody(self: *const Func) bool {
        if (self.is_suspend or self.is_lambda) return false;
        if (self.blocks.len == 0 or self.blocks.len > LEAF_MAX_BLOCKS) return false;
        if (self.n_locals > LEAF_MAX_REGS) return false;
        var total: usize = 0;
        for (self.blocks) |*b| {
            // A finally-carrying body needs the try-stack machinery the frameless walk skips.
            if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return false;
            total += b.insts.len;
            if (total > LEAF_MAX_INSTS) return false;
            switch (b.terminator) {
                // A `Return` with no register is a `Unit` return, the shape of every guard helper.
                .Return, .Goto, .Branch => {},
                // A guard's failing arm never runs on the path this serves; let the walk abandon there.
                .Throw, .Unreachable => {},
                else => return false,
            }
        }
        for (self.params) |*p| {
            if (p.is_vararg or p.default != null) return false;
        }
        return true;
    }
};

/// Bounds for `leafExprBody`: a leaf serve keeps its registers in a fixed stack array, so
/// register count and body length are capped, and the block bound admits guard shapes only.
pub const LEAF_MAX_REGS: u32 = 64;

/// CFG size bound for `frameNoFill`'s dataflow; a larger body keeps the eager fill.
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
inline fn regSetHas(a: RegSet, i: usize) bool {
    return (a[i >> 6] >> @as(u6, @truncate(i))) & 1 != 0;
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
pub threadlocal var frame_fill_scratch: [3][FRAME_FILL_MAX_BLOCKS]RegSet = undefined;

pub const LEAF_MAX_INSTS: usize = 96;

pub const LEAF_MAX_BLOCKS: usize = 32;

pub const LEAF_MAX_STEPS: usize = 160;

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
