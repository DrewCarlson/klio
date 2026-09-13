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

/// A basic block: linear instruction stream + terminator. When
/// `catches` is non-empty, a `Throw` reaching this block (or any
/// block reached from it without first leaving the try scope)
/// looks up a matching handler before propagating.
pub const Block = struct {
    id: BlockId,
    insts: []Inst,
    terminator: Terminator,
    catches: []CatchHandler = &.{},
    /// Finally-block id to execute on every exit from this block's
    /// try-region (normal fall-through, catches, returns, throws).
    /// Paired with `finally_done` (the synthesized exit sentinel)
    /// so the eval can tell "I'm jumping into finally" apart from
    /// "I've finished finally."
    finally: ?BlockId = null,
    /// The post-finally sentinel for this try-region — control
    /// reaches it only after the user finally body has run to
    /// completion.
    finally_done: ?BlockId = null,
    /// When this block IS the post-finally sentinel for some
    /// try-region, this carries the `BlockId` of that region's body
    /// entry — the matching key for the `TryFrame.body` the eval
    /// popped.
    finally_done_for: ?BlockId = null,
    /// When this block is the JOIN of a catch-only try (no finally),
    /// this carries the try body's entry block. Normal flow arriving
    /// here pops that body's `TryFrame` — without the marker a
    /// catch-only entry only left the stack via a throw, so a loop
    /// body's `try { } catch { }` grew the stack by one per iteration
    /// (and every Goto's finally scan walked it: quadratic in
    /// iterations for a long-lived frame like DeepRecursive's
    /// runCallLoop).
    catch_done_for: ?BlockId = null,
    /// Entering this block arms a labeled-return absorption region for a
    /// splice of the named inline function (see `LrAbsorb`).
    lr_absorb: ?LrAbsorb = null,
    /// Try-region body-entry ids whose `TryFrame` this block pops when it
    /// exits via `Goto`. Set on the block that carries an inline `return`'s
    /// jump-to-join: the return replays its enclosing finallys inline and
    /// jumps straight to the inline join, bypassing the finally sentinel
    /// that would otherwise pop those frames — so without this the frames
    /// linger and a LATER plain return in the same runtime frame re-runs
    /// the finally (a spliced `try { return … } finally { … }` applied its
    /// snapshot twice).
    pop_on_exit: []const BlockId = &.{},
};

/// A function body in IR form.
/// First-class classification of a lowered function, used by the
/// runtime extension scorer to recognize a member-extension directly
/// instead of probing the `member_ext_owner_class` side table. A
/// *member extension* (`class C { fun R.f(p) { … } }`) lowers to a func
/// with a leading `"this"` param exactly like an `instance_method` and a
/// `top_level_extension`, so `param[0] == "this"` alone cannot tell them
/// apart — this kind makes the distinction authoritative. The owner-class
/// gate that decides member-extension *visibility* stays in
/// `ModuleRegistry.member_ext_owner_class` (keyed by `FuncId`); the kind
/// is the additive predicate that selects which funcs are gated.
pub const FuncKind = enum {
    /// Ordinary top-level / local function, or a constructor/init thunk.
    plain,
    /// Instance method `class C { fun f(p) { … } }` (leading `"this"`).
    instance_method,
    /// Top-level extension `fun R.f(p) { … }` (leading `"this"`).
    top_level_extension,
    /// Member extension `class C { fun R.f(p) { … } }` (leading `"this"`),
    /// gated by its declaring class through `member_ext_owner_class`.
    member_extension,
};

/// `Func.fast_call` flag: the eligible body carries its receiver as the
/// leading `"this"` param, so the fast dispatch seeds the caller's instance
/// `this` as an enclosing receiver exactly as the full path does.
pub const FAST_CALL_EXT_FLAG: u16 = 0x4000;

/// `Func.fast_call` flag: the callee's simple name has same-arity peers, so
/// only the CALL SITE can say whether the baked target is the one scope
/// resolution picks. Eligible in every other respect; the site resolves the
/// question once and caches the verdict on its own instruction.
pub const FAST_CALL_AMBIG_FLAG: u16 = 0x2000;

/// Whether the declaration currently LOWERING carries
/// `@Suppress("DEPRECATION_ERROR")`: under it kotlinc restores
/// `@Deprecated(level = ERROR)` candidates to ordinary overload ranking,
/// so the resolvers consult this when filtering low-priority overloads.
pub threadlocal var suppress_deprecation_error: bool = false;

pub fn setSuppressDeprecationError(v: bool) bool {
    const prev = suppress_deprecation_error;
    suppress_deprecation_error = v;
    return prev;
}

/// The effective low-priority rank of a candidate at the current site: a
/// deprecation-ERROR overload ranks ordinary under the suppression.
pub fn rankLowPriority(f: *const Func) bool {
    return f.low_priority and !(f.deprecated_error and suppress_deprecation_error);
}

pub const Func = struct {
    id: FuncId,
    name: []const u8,
    fqn: []const u8,
    /// Declaring package path (`"foo.bar"`), the empty string for a
    /// user script with no package header. Uniform on every func — the
    /// symbol index keys bare-call preference on the caller's package,
    /// and `""` is the ordinary "no package" case, not a separate code
    /// path.
    package: []const u8 = "",
    /// For the forwarding lambda of an adapted callable reference: the
    /// target and the adaptation (`fqn|arity|unit`), so two wrappers of
    /// the same adaptation of the same target compare and hash equal.
    ref_key: []const u8 = "",
    params: []Param,
    return_ty: TypeRef,
    /// Whether `return_ty` came from an explicit `: T` in the source. A
    /// function with an expression body and no annotation gets `Unit` as a
    /// PLACEHOLDER, so `return_ty` alone cannot distinguish "returns Unit"
    /// from "return type not recorded". Any consumer that treats the return
    /// type as a fact about the function must check this first.
    return_ty_declared: bool = false,
    n_locals: u32,
    blocks: []Block,
    /// Lazy IR: `offset + 1` of this function's `blocks` in its module's
    /// `deferred_func_section` when they are deferred (so `blocks` is empty
    /// until the first execution decodes them), `0` when present. A function
    /// "has a body" iff `blocks.len != 0 OR deferred_offset != 0` — see
    /// `hasBody`, which every "is this bodyless?" check must consult so a
    /// deferred function is never mistaken for a native / abstract stub.
    deferred_offset: u32 = 0,
    entry: BlockId,
    is_suspend: bool,
    /// First-class func classification for the extension scorer. Defaults
    /// to `plain`; set to `member_extension` at the member-extension
    /// lowering site, distinguishing it from a same-shaped instance method
    /// or top-level extension.
    kind: FuncKind = .plain,
    is_tailrec: bool = false,
    /// Monomorphic call fast-path plan, cached on first call (the evaluator
    /// fills it via the host). `0` = not yet computed, `1` = ineligible (use the
    /// full dispatch), otherwise the low 14 bits are the eligible parameter
    /// count + 2: a user function a positional, exact-arity call dispatches
    /// straight to its body. `FAST_CALL_EXT_FLAG` marks a receiver-carrying
    /// body (baked extension / member) whose dispatch must seed the caller's
    /// `this` as an enclosing receiver. See `eval`'s `.Call` fast path.
    fast_call: u16 = 0,
    /// Which argument-coercion walks can ever apply to this func's declared
    /// params, computed on first frame entry: bit0 = computed, bit1 = a
    /// non-vararg `Long` param exists (Int->Long widening), bit2 = >=2 params
    /// with a type-variable-typed one (generic Int/Long peer widening).
    /// Filled in place under the same benign-race convention as `fast_call`.
    coerce_plan: u8 = 0,
    /// VM-plan P2 classification: 0 unknown, 1 flattenable (every
    /// instruction in the simple subset, no catches/finally), 2 not.
    /// Filled lazily under the same benign-race convention as
    /// `coerce_plan`.
    flat_class: u8 = 0,
    /// Index of `"this"` in `capture_order`, cached on first use by
    /// `callerThisValue` (hot: every GetField in a lambda frame consults
    /// it). `-2` = not yet computed, `-1` = no `this` capture.
    this_cap_idx: i32 = -2,
    /// Accessor-shape memo (benign-race fill): 0 = unknown, 1 = not an
    /// accessor, 2 = the body is exactly `LoadParam #0; GetField; return`
    /// with `acc_field` holding the GetField name ConstId. See
    /// `accessorFieldConst`.
    acc_state: u8 = 0,
    acc_field: u32 = 0,
    /// Single-fill (CAS from 0) claimed receiver-class identity and its
    /// packed stored-slot route for the frameless accessor read; only the
    /// CAS winner writes `acc_route`, so the pair never tears. A stale
    /// baked value mismatches every live identity harmlessly.
    acc_cls: u64 = 0,
    acc_route: u64 = 0,
    /// Cached `leafExprBody` verdict: 0 = unasked, 1 = no, 2 = yes.
    leaf_state: u8 = 0,
    /// Fused-tier verdict, memoized like `leaf_state`: 0 = unasked, 1 =
    /// eligible (this body and, transitively, every statically-resolved
    /// callee), 2 = ineligible, 3 = classification in progress (a cycle
    /// reads as eligible for the frame asking and settles when the root
    /// classification completes).
    fuse_state: u8 = 0,
    /// Trivial property-initializer memo (benign-race fill): 0 = unasked,
    /// 1 = not trivial, 2 = the body returns one constant
    /// (`triv_init_val` = ConstId), 3 = it echoes one parameter
    /// (`triv_init_val` = param index). Construction serves 2/3 without a
    /// framed eval — a builder-heavy write path otherwise pays one full
    /// eval per `= 0`-style field.
    triv_init_state: u8 = 0,
    triv_init_val: u32 = 0,
    /// Host-served static routing memo (snapshot_fast): 0 = unasked,
    /// then a `snapshot_fast.Route` value.
    host_route: u8 = 0,
    /// Compose fast-path verdict for this body (`compose_fast.Route`),
    /// classified once on first execution like `host_route`.
    compose_route: u8 = 0,
    /// Throw-capable host-serve route (`hostRouteServeThrowing`): 0 unasked,
    /// 1 none, 2 the gap-buffer changelist wrapper, 3 the link-buffer one.
    throw_route: u8 = 0,
    /// Cached `frameNoFill` verdict: 0 = unasked, 1 = must fill,
    /// 2 = register file may start unfilled.
    frame_fill_state: u8 = 0,
    /// Scalar-replay (`kl_`) route memo: 0 unresolved, 1 none, else the
    /// registered NativeLeafFn as an address. The table is write-once
    /// before the program runs, so the first resolution is final;
    /// benign-race fill.
    leaf_route: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Leaf bail damper: bit 31 = the leaf SERVED at least once (sticky —
    /// a genre-mixed fn must never be disabled); low bits count bails
    /// while never-served. A leaf that only ever bails is structural for
    /// this program's call shapes, and every attempt still pays marshal +
    /// a partial body — past the threshold the route flips to `none`.
    leaf_bail_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// The bytecode-stream table for this func (`bc.funcStreams` memo):
    /// 0 unresolved, 1 none, else a `*const bc.FuncStreams` address.
    /// `bc_memo_fuse` records which allow_fuse variant the memo holds
    /// (1 = false, 2 = true); a caller wanting the other variant takes
    /// the shared-cache path. Benign-race fill.
    bc_memo: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bc_memo_fuse: u8 = 0,
    /// The loop JIT owns a block of this function: its compiled code deopts to
    /// an instruction index, which only an UNFUSED stream can resume at, so
    /// this function's streams stop fusing once the flag is set. Every other
    /// function keeps fusion whether or not the JIT is enabled.
    bc_jit_owned: bool = false,
    /// Function-JIT hotness probe, shared across threads so the per-activation
    /// cost is one atomic load instead of a per-thread state-map lookup: low
    /// bits count activations, bit 30 = some thread compiled a body (consult
    /// the per-thread state), bit 31 = compilation declined (sticky; stop
    /// probing). See `jit_loop` for the encoding.
    func_jit_probe: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// `bc.streamGen()` at fill time; a cache reset frees the streams the
    /// memo points at, so a stale generation must fall to the shared path.
    bc_memo_gen: u32 = 0,
    /// The frameless leaf serve hit a STRUCTURALLY unsupported
    /// instruction in this body: every future serve would abandon at the
    /// same instruction, so the attempt (which may execute half the body
    /// before abandoning, doubling the call's work) is skipped outright.
    /// Value-dependent abandons never set this. Benign-race fill.
    leaf_hopeless: u8 = 0,
    /// True when `params[0]` is a *synthesized* `this` receiver — an
    /// instance method's / extension's / local-extension's dispatch
    /// receiver, a constructor's or init thunk's instance under
    /// construction, or any other frame the lowerer injects a leading
    /// `this` for. It distinguishes a genuine receiver from a user
    /// parameter that merely spells its name `this` (`fun f(\`this\`: T)`),
    /// which is not a dispatch receiver. Set wherever the implicit leading
    /// `this` param is bound.
    has_receiver_param: bool = false,
    /// True for synthetic lambda bodies. `return` inside the body
    /// propagates as a non-local return through this frame instead
    /// of being caught locally.
    is_lambda: bool = false,
    /// True when lowering had a declared function-type shape for this
    /// closure. When false, `lambda_has_receiver == false` means unknown
    /// rather than a proven receiver-less function.
    lambda_receiver_shape_known: bool = false,
    /// True when this callable's function type declares an extension
    /// receiver. The receiver is supplied at invocation and is not counted
    /// in `params`; keeping that shape explicitly prevents the VM from
    /// inferring receiver binding from an extra argument or a `this` capture.
    lambda_has_receiver: bool = false,
    /// True when the lambda kept its parser-injected `it` because no
    /// expected function type constrained it (`val l = {}`, `{} as Any`):
    /// kotlinc types such a lambda `() -> R`, so its arity reads as zero.
    lambda_it_unconstrained: bool = false,
    /// Declared receiver head of a receiver-lambda body. Unlike a local
    /// extension function this receiver is supplied at invocation rather
    /// than occupying a parameter slot; the VM uses the head to select the
    /// compatible receiver from the implicit-receiver tower.
    lambda_receiver_ty: ?[]const u8 = null,
    /// True for `inline fun`. A non-local `return` from a lambda
    /// passed to an inline function unwinds *through* this frame
    /// (back to the function that wrote the lambda) rather than
    /// being caught here.
    is_inline: bool = false,
    /// Capture-name list in `LoadCapture` index order. Non-empty for
    /// anon-object method bodies that close over outer names — the
    /// dispatch site materialises the capture-value vector in this
    /// order so `Inst.LoadCapture` reads the right snapshot per
    /// instance.
    capture_order: [][]const u8 = &.{},
    /// For a lambda body, the simple name of the function the lambda
    /// literal was passed to (`with`, `apply`, a user HOF). This is the
    /// lambda's implicit label, so `this@with` inside the body resolves
    /// to the receiver this lambda was invoked with. `null` for ordinary
    /// functions and for lambdas not in argument position.
    implicit_label: ?[]const u8 = null,
    /// Marked `@kotlin.internal.LowPriorityInOverloadResolution` or
    /// `@Deprecated(level = DeprecationLevel.ERROR)`. Such a function is
    /// only a valid overload-resolution target when no ordinary candidate
    /// applies. Overload selection skips it while any normal sibling
    /// fits.
    low_priority: bool = false,
    /// The low-priority mark came from `@Deprecated(level = ERROR|HIDDEN)`
    /// (not `@LowPriorityInOverloadResolution`): a caller-side
    /// `@Suppress("DEPRECATION_ERROR")` restores such a candidate to
    /// ordinary ranking, exactly as kotlinc resolves under the suppression.
    deprecated_error: bool = false,
    /// An `expect` declaration. Its `actual` may live outside the pack's source
    /// set, in which case NOTHING serves the call — and a bodyless declaration
    /// that nothing serves used to return `Unit` silently, which is the single
    /// most confusing failure klio can produce (the call runs nothing and the
    /// program limps on with a wrong value). Knowing the declaration is an
    /// `expect` lets the runtime say so, and say what to run to list the rest.
    is_expect: bool = false,
    /// Carries the source `override` modifier. Dispatch of a call resolved
    /// against a STATIC receiver type (an implicit-`this` / inline-spliced
    /// own-member call) must exclude a runtime subtype's same-name overload
    /// that is NOT an override — it is out of the static type's member scope.
    is_override: bool = false,
    /// Carries the source `open` modifier. A method that is neither `open` nor
    /// `override` (an `override` is open-by-default) cannot be overridden, so a
    /// `recv.name()` call resolving to it is monomorphic even when the receiver
    /// class is `open`. Serialized with the function header.
    is_open: bool = false,
    /// Carries the source `final` modifier. Meaningful on an `override` member:
    /// `final override fun` seals the method against any further override, so it
    /// is monomorphic despite `is_override`. Redundant (but honored) on a plain
    /// member.
    is_final: bool = false,
    /// Resolved fully-qualified candidate names for each source-level
    /// annotation on this function (e.g. `kotlin.test.Test`), so a test
    /// runner can discover `@Test`/`@Ignore`/etc. without re-parsing.
    /// Populated by the in-memory build path; empty for the baked image.
    annotation_names: []const []const u8 = &.{},

    /// True when this function has an IR body — present blocks, or blocks
    /// deferred to the image's lazy-IR section. Distinguishes a real function
    /// (whose body may be lazily decoded) from a native / abstract / `expect`
    /// stub (no blocks, not deferred). Every "is this bodyless?" check uses
    /// this, never a bare `blocks.len`, so deferral stays invisible to dispatch.
    pub fn hasBody(self: *const Func) bool {
        return self.blocks.len != 0 or self.deferred_offset != 0;
    }

    /// The GetField name ConstId when this function's body is exactly the
    /// accessor shape `LoadParam #0; GetField; return` — the canonical
    /// property-getter lowering — else null. Cached in place under the
    /// `fast_call` benign-race convention. An image func's body decodes
    /// lazily; classify the real instructions (`accessorFieldConstIn`),
    /// or never for a caller without the module in hand.
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

    /// Whether this body is a *leaf expression*: one block, no handlers, a
    /// `Return` of a register, and nothing but parameter loads, constants,
    /// stored-field reads, moves and primitive operators in between. Such a
    /// body observes nothing beyond its arguments and the fields it reads,
    /// so it can be evaluated without building a frame at all.
    ///
    /// The classification is a pure function of the lowered body; cache it
    /// on first ask under the same benign-race convention as `acc_state`.
    pub fn leafExprBody(self: *const Func) bool {
        switch (self.leaf_state) {
            1 => return false,
            2, 3 => return true,
            else => {},
        }
        // A DEFERRED body carries no blocks until the image section decodes
        // it. Classifying one here would cache "not a leaf" for a function
        // that becomes a leaf the moment it loads, which is how `Stack.isEmpty`
        // and every other tiny library accessor lost the frameless tier.
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

    /// Whether every register read in the body is dominated by a write: a
    /// read is admitted when an earlier instruction of the SAME block wrote
    /// the register, or the ENTRY block wrote it (the entry runs before any
    /// other block, so its writes dominate everything). When this holds the
    /// leaf serve can skip zero-filling its register bank — no path can
    /// observe a stale slot.
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

    /// Whether a fresh frame for this func may leave its register file
    /// unfilled: every register read in the body is preceded by a write on
    /// ALL paths from entry, so no path can observe a stale slot. Beyond
    /// `leafNoFill`'s same-block/entry rule this runs a must-written
    /// dataflow over the CFG (join = intersection over predecessors), so
    /// branch-and-join initialization (`val x = if (c) a else b`) proves
    /// too. Funcs with catch/finally/labeled-return absorption keep the
    /// eager fill — an exception edge can enter a handler with only part
    /// of a block's writes done. The proof covers program reads only; the
    /// frame layer's written mask keeps the collector and suspension
    /// snapshots away from unwritten slots.
    pub fn frameNoFill(self: *const Func) bool {
        switch (self.frame_fill_state) {
            1 => return false,
            2 => return true,
            else => {},
        }
        // A deferred body has no blocks to analyze yet; decide (and cache)
        // only once it is decoded.
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
        // Per-block summary: `gen` = registers the block writes, `exposed` =
        // registers it reads before writing them itself. An instruction's own
        // def never covers its own use (operands are read first), so uses are
        // checked against strictly earlier instructions only. The scratch
        // lives in TLS: stack arrays this size are poisoned on every call
        // under the safe builds, and every slot consulted below is written
        // first (`gen`/`exposed` per block, `in` in the explicit init loop).
        const gen = &frame_fill_scratch[0];
        const exposed = &frame_fill_scratch[1];
        for (self.blocks, 0..) |*b, bi| {
            var written: RegSet = regSetEmpty();
            var expo: RegSet = regSetEmpty();
            for (b.insts) |*inst| {
                // `CtxScope.ctx_args` is a contiguous run of `n_ctx`
                // registers, but the register visitor's run convention
                // covers only the `args`+`n_args` field pair — the run's
                // tail registers would go unreported as uses. Keep the
                // eager fill for such bodies.
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
        // Forward must-written fixpoint. Unreachable blocks keep the ALL
        // set and verify vacuously — they never run. A `TailJump` resets
        // the register file, so it contributes no edge (the entry's in-set
        // is pinned empty anyway); `TailCallFunc` leaves the function.
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

    /// Structural admission only. Which INSTRUCTIONS a leaf serve can
    /// actually execute is decided per instruction as it runs, because a
    /// body may reach a value-returning path made entirely of leaf work
    /// while an untaken branch does something the serve cannot do — the
    /// guard shape `if (!ok) reportFailure(lazyMessage())` is the common
    /// case, and its taken path is a constant and a return.
    fn classifyLeafExprBody(self: *const Func) bool {
        if (self.is_suspend or self.is_lambda) return false;
        if (self.blocks.len == 0 or self.blocks.len > LEAF_MAX_BLOCKS) return false;
        if (self.n_locals > LEAF_MAX_REGS) return false;
        var total: usize = 0;
        for (self.blocks) |*b| {
            // A finally-carrying body needs the try-stack machinery: the
            // frameless walk would return straight out of the try region
            // and never run the finally.
            if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return false;
            total += b.insts.len;
            if (total > LEAF_MAX_INSTS) return false;
            switch (b.terminator) {
                // A `Return` with no register is a `Unit` return — the shape
                // of every guard helper, which is exactly what this admits.
                .Return, .Goto, .Branch => {},
                // A guard's FAILING arm (`if (!ok) throw ...`) never runs on
                // the path this exists to serve. Admit it structurally and let
                // the walk abandon if it ever lands there, the same rule the
                // instruction set follows — otherwise every `assert`/`require`
                // helper builds an activation to evaluate one comparison.
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

/// Bounds for `leafExprBody`. A leaf serve keeps its registers in a fixed
/// stack array, so both the register count and the body length are capped;
/// the block bound keeps a guard-shaped body admissible without admitting
/// real control flow, and `LEAF_MAX_STEPS` bounds the walk itself.
pub const LEAF_MAX_REGS: u32 = 64;

/// CFG size bound for `frameNoFill`'s dataflow: the scratch sets are fixed
/// buffers, and a body past this many blocks keeps the eager fill.
pub const FRAME_FILL_MAX_BLOCKS: usize = 256;

/// Register-set width for `frameDefBeforeUse`, in 64-bit words. Compose's
/// composables and slot-table walkers run 70-500 locals (`GapComposer.end`
/// alone carries 502); capping the analysis at one word sent every one of
/// them to the eager fill.
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

/// `frameDefBeforeUse` scratch (gen / exposed / in). Thread-local so the
/// once-per-func analysis never pays the safe builds' stack poisoning, and
/// concurrent first-asks on different threads stay independent.
pub threadlocal var frame_fill_scratch: [3][FRAME_FILL_MAX_BLOCKS]RegSet = undefined;

pub const LEAF_MAX_INSTS: usize = 96;

pub const LEAF_MAX_BLOCKS: usize = 32;

pub const LEAF_MAX_STEPS: usize = 160;

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    default: ?BlockId,
    /// Source function-type arity when this parameter is `@Composable`.
    /// Null distinguishes an ordinary function parameter from a composable
    /// zero-argument parameter.
    composable_arity: ?u8 = null,
    /// Extension-receiver + context slots of a `@Composable` function-typed
    /// parameter — the leading value slots a NON-inline sink's lambda takes
    /// beyond `composable_arity` when invoked through the value protocol.
    composable_recv_slots: u8 = 0,
    /// True when the primary-ctor param doubles as a class property
    /// (`val name` / `var name` prefix on the param). The Vm uses
    /// this flag to decide which primary args become instance
    /// fields.
    is_property: bool = false,
    /// `vararg` parameter — variadic, runtime-collected into an
    /// array. The Vm packs trailing positional args into a typed
    /// array before binding.
    is_vararg: bool = false,
    /// True when the parameter declares a default value. The lowered
    /// default expression lives in a separate thunk (so `default` above
    /// stays `null`), but the flag is needed at lower time to decide
    /// whether a same-named factory function is applicable to a given
    /// argument count.
    has_default: bool = false,
};
