//! Builders for assembling an IR `Func` block-by-block.
//!
//! The lowering pass in `lower` uses these to emit instructions. Kept
//! separate from the type definitions so the lowering surface is small
//! enough to skim.

const std = @import("std");
const ast = @import("ast");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;

const Block = ir.Block;
const BlockId = ir.BlockId;
const Const = ir.Const;
const Func = ir.Func;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;
const CatchHandler = ir.CatchHandler;

const StringSet = std.StringHashMap(void);
const StringRegMap = std.StringHashMap(Reg);
const StringFuncIdMap = std.StringHashMap(FuncId);

/// Per inline-fn-splice frame: a lambda-param substitution map paired
/// with the `inline_return` snapshot taken when the frame was pushed.
const InlineLambdaFrame = struct {
    subst: std.StringHashMap(*const ast.Expr),
    snapshot: []InlineReturn,
};

/// One `(result reg, join block)` entry on the `inline_return` stack:
/// a `return` inside an inlined body assigns the result and jumps to
/// the join (the inline call's value).
pub const InlineReturn = struct {
    reg: Reg,
    join: BlockId,
};

/// One labeled-return target for a spliced inline-argument lambda:
/// `return@<inlineFnName>` inside such a lambda is a local return
/// from the lambda invocation (its value), not a return of the caller.
pub const InlineLambdaRet = struct {
    label: []const u8,
    reg: Reg,
    end: BlockId,
};

/// Per-function builder. Owns a fresh register counter, the list of
/// blocks, and a "current block" cursor that the lowering pass
/// appends to. Carries a simple scope stack so the lowering pass
/// can resolve `Path { name }` reads against function parameters
/// and locally introduced bindings.
/// Declaring package of the decl whose body/initializer/thunk is being
/// lowered. Seeded by the build driver per top-level decl (functions,
/// classes — including accessors, init blocks and ctor thunks — and
/// top-level properties) and read by every `FuncBuilder` on init, so the
/// symbol index always keys on the caller's package. `""` is the
/// no-package case.
threadlocal var lower_self_package: []const u8 = "";

/// Install the caller package for subsequently-created builders. Returns
/// the previous value so a nested lowering restores it on exit.
pub fn setLowerSelfPackage(pkg: []const u8) []const u8 {
    const prev = lower_self_package;
    lower_self_package = pkg;
    return prev;
}

/// Per-file top-level property renames: span FileId -> (simple name ->
/// renamed global name). Kotlin scopes a `private` top-level property to
/// its declaring file and gives same-named top-level properties in
/// different packages distinct storage, but the lowered globals table is
/// flat, so the build driver renames colliding declarations (per-file
/// mangle for `private`, declaring-FQN slots across packages) and bare
/// references resolve through the reference's own span file (an
/// inline-spliced body keeps its declaring file's spans, so a splice
/// still reads the right file's property).
pub const FilePrivateRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_private_renames: ?*const FilePrivateRenames = null;

/// Install the per-file property rename table for the duration of
/// a lowering pass. Returns the previous value for restoration.
pub fn setLowerFilePrivateRenames(m: ?*const FilePrivateRenames) ?*const FilePrivateRenames {
    const prev = lower_file_private_renames;
    lower_file_private_renames = m;
    return prev;
}

/// The renamed global name for `name` referenced from `file`, when that
/// file resolves it to a renamed top-level property.
pub fn filePrivateRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_private_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// File-keyed type renames: span FileId -> (simple type name -> mangled
/// lift name). Kotlin scopes a file-`private` top-level class or
/// typealias to its declaring file; the build driver mangles one whose
/// simple name another file also claims as a type, and references —
/// value-position heads and type positions (`as` / `is` / supertypes) —
/// rewrite through the reference's own span file.
pub const FileTypeRenames = std.AutoHashMap(u32, std.StringHashMap([]const u8));

threadlocal var lower_file_type_renames: ?*const FileTypeRenames = null;

/// Install the per-file type rename table for the duration of a lowering
/// pass. Returns the previous value for restoration.
pub fn setLowerFileTypeRenames(m: ?*const FileTypeRenames) ?*const FileTypeRenames {
    const prev = lower_file_type_renames;
    lower_file_type_renames = m;
    return prev;
}

/// The mangled lift name for the type `name` referenced from `file`, when
/// that file declares it as a renamed file-private class or typealias.
pub fn fileTypeRename(name: []const u8, file: u32) ?[]const u8 {
    const m = lower_file_type_renames orelse return null;
    const inner = m.get(file) orelse return null;
    return inner.get(name);
}

/// The whole per-file type rename map for `file`, for callers that
/// flatten the visible renames (the `BuildObject` scope snapshot).
pub fn fileTypeRenamesFor(file: u32) ?*const std.StringHashMap([]const u8) {
    const m = lower_file_type_renames orelse return null;
    return m.getPtr(file);
}

/// Scope-true renames carried into a runtime anon-object member-body
/// lowering: the lexical site's flattened rename snapshot from the
/// `BuildObject` instruction. Installed around the side-module lowering
/// and consulted by `scopeTypeRename` after the (empty) chain walk.
threadlocal var lower_anon_scope_renames: []const ir.ScopeRename = &.{};

/// Install the anon-scope rename snapshot. Returns the previous value
/// for restoration.
pub fn setLowerAnonScopeRenames(rs: []const ir.ScopeRename) []const ir.ScopeRename {
    const prev = lower_anon_scope_renames;
    lower_anon_scope_renames = rs;
    return prev;
}

/// The currently-installed anon-scope rename snapshot (empty outside an
/// anon-object member-body lowering).
pub fn anonScopeRenames() []const ir.ScopeRename {
    return lower_anon_scope_renames;
}

/// The rename for `name` in the installed anon-scope snapshot; first
/// entry wins (nearer scopes were flattened first).
pub fn anonScopeRename(name: []const u8) ?[]const u8 {
    for (lower_anon_scope_renames) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.renamed;
    }
    return null;
}

pub const FuncBuilder = struct {
    allocator: Allocator,
    module: *Module,
    blocks: std.ArrayList(Block) = .empty,
    cur: BlockId,
    next_reg: u32,
    /// Scope stack. The bottom frame holds the function's parameter
    /// bindings; lowering pushes a fresh frame per block expression
    /// so val/var declarations are popped correctly.
    scopes: std.ArrayList(StringRegMap) = .empty,
    /// Names visible to the function but living in an enclosing
    /// frame. Lowering a lambda body seeds these from the outer
    /// `FuncBuilder`'s scope chain; references to them lower as
    /// `LoadCapture` insts and record the capture-name so the
    /// lambda-construction site knows which outer registers to
    /// snapshot.
    outer_names: StringSet,
    capture_order: std.ArrayList([]const u8) = .empty,
    capture_regs: StringRegMap,
    /// Loop context stack. Each frame names the loop's continue
    /// target (header / latch) and break target (exit). The frame's
    /// optional `label` matches an explicit `break@label` /
    /// `continue@label`; bare jumps target the innermost frame.
    loops: std.ArrayList(LoopFrame) = .empty,
    /// Names declared as `var` (mutable) in any live scope. `val`
    /// bindings are absent. Used by compound-assignment lowering to
    /// pick between rebind (Path target on a `var`) and plusAssign
    /// dispatch (Path target on a `val`).
    mutables: StringSet,
    /// `var` locals each get a permanent "home" register. Reads of
    /// the local always resolve to this reg; writes emit a Move
    /// into it. This gives the IR's flat block model the slot
    /// semantics that mutable Kotlin locals need.
    mutable_homes: StringRegMap,
    /// Names that are boxed into a shared `Value.Cell` because a
    /// nested lambda captures them (Kotlin `Ref` boxing). Their home
    /// reg holds the `Cell`; reads emit `CellGet`, writes `CellSet`,
    /// and the declaration emits `MakeCell`.
    boxed_vars: StringSet,
    /// Locals declared with an `: Any` (or other erased) type
    /// annotation — used by the `==` lowering to detect a boxed
    /// operand the same way the tree walker does.
    any_typed_locals: StringSet,
    /// When the function is a class method, the simple name of
    /// the owning class. Used by `super.method()` lowering to
    /// emit `Inst.CallSuper` with the right starting class.
    owner_class: ?[]const u8 = null,
    /// Declaring package of the function currently being lowered
    /// (`""` for a user script). The symbol index keys bare-call
    /// preference on this so a same-named function in the caller's
    /// own package wins over an imported / stdlib sibling.
    self_package: []const u8 = "",
    /// Declared receiver-type name of the enclosing *extension* function
    /// (`fun Source.forEach(...)` → `"Source"`). Lets bare-call resolution
    /// prefer a same-named extension overload whose `this`-param type
    /// matches the enclosing receiver instead of an arity-only pick.
    /// `null` for plain functions and class methods.
    recv_ty: ?[]const u8 = null,
    /// Names declared on the owning class (methods, body
    /// properties, primary-ctor properties). Used by method-
    /// body lowering to know whether an unqualified `foo(...)`
    /// is `this.foo(...)` (a class member) or a global lookup.
    own_members: StringSet,
    /// Member names of the lexically enclosing class, carried into a
    /// lambda body. Unlike `own_members` this never reroutes a bare
    /// reference through `this.<member>`; it only lets an enclosing
    /// member out-prioritise a same-named imported extension.
    enclosing_members: StringSet,
    /// Private methods of `owner_class` that have already been
    /// lowered (so their `FuncIds` are known). A bare call resolving
    /// to a name in this map binds statically to the listed `FuncId`
    /// rather than virtual-dispatching.
    private_method_fids: StringFuncIdMap,
    /// When the function is `tailrec`, the simple name of the
    /// function itself. Self-calls are lowered as `Terminator.TailJump`
    /// to keep the stack flat across recursion.
    tailrec_self: ?[]const u8 = null,
    /// Whether the tailrec function carries an implicit leading `this`
    /// param (instance method / extension). A bare recursive call keeps
    /// the same receiver, so the tail jump's arg run must lead with it.
    tailrec_self_this: bool = false,
    /// Names bound as parameters at the function entry (set by
    /// `bind_params`). Used by call-site lowering to recognise
    /// when an identifier-as-callee is a function-typed param.
    param_names: StringSet,
    /// Names declared as *local functions* (`fun foo() …` inside a
    /// body). A `recv.foo()` call resolves to such a local — but a
    /// local `val`/`var` of the same name must NOT hijack member-call
    /// syntax.
    local_fns: StringSet,
    /// Subset of `local_fns` declared as extensions (`fun R.f(...)`);
    /// a bare call must prepend the implicit receiver as `this`.
    local_ext_fns: StringSet,
    /// Declared type annotation per local (`val resp: HttpResponse`),
    /// used by inline-overload receiver narrowing.
    local_decl_types: std.StringHashMap([]const u8),
    /// Recorded initializer expression per un-annotated local, so the
    /// narrowing can infer a type from the init call's return type. The
    /// AST outlives the lowering pass.
    local_init_exprs: std.StringHashMap(*const ast.Expr),
    /// Params whose declared type is a receiver-typed function
    /// (`block: T.() -> R`). A bare call `block(...)` on one of these
    /// must dispatch with the enclosing `this` as the implicit
    /// receiver.
    receiver_lambda_params: StringSet,
    /// Params (and locals) whose declared type is an unconstrained
    /// generic type-parameter (`T` of a `fun <T : Comparable<T>>`).
    /// Kotlin desugars a comparison operator on such an operand to
    /// `a.compareTo(b) <op> 0` — the total order, unlike the IEEE
    /// primitive operators.
    generic_typed_params: StringSet,
    /// Reified type-parameter names bound by an in-progress inline
    /// splice, each mapped to the register holding the resolved class
    /// value. A nested splice whose call-site type argument names an
    /// enclosing splice's reified parameter (`trySuspend<TaskType>(...)`
    /// inside a spliced `sleepWhile<reified TaskType>` body) chains
    /// through this instead of a global lookup of the parameter name.
    reified_type_binds: StringRegMap,
    /// Stack of user `finally { … }` blocks (innermost on top) whose
    /// lexical scope encloses the current cursor. A `return X` reached
    /// during inline expansion replays each finally body inline before
    /// exiting.
    finally_stack: std.ArrayList(ast.Block) = .empty,
    is_lambda_body: bool,
    is_anon_fn_body: bool,
    is_named_local_fn: bool,
    is_inline: bool,
    /// True while lowering a default-argument thunk. A default
    /// expression executes in the declaring function's scope, not as
    /// a member of the (extension) receiver.
    is_param_thunk: bool,
    /// Inline-expansion state. `inline_return` is a stack of
    /// (result reg, join block): a `return` inside an inlined body
    /// assigns the result and jumps to the join. `inline_stack`
    /// guards recursive inline.
    inline_return: std.ArrayList(InlineReturn) = .empty,
    inline_stack: std.ArrayList([]const u8) = .empty,
    /// Per inline-fn-splice frame: the lambda-param substitution map
    /// *and* a snapshot of `inline_return` as it was when this frame
    /// was pushed. An unlabeled `return` inside a spliced lambda must
    /// localize to the owner splice (restore the snapshot).
    inline_lambda_subst: std.ArrayList(InlineLambdaFrame) = .empty,
    /// Labeled-return targets for spliced inline-argument lambdas.
    inline_lambda_ret: std.ArrayList(InlineLambdaRet) = .empty,
    /// Simple name of the call whose arguments are currently being
    /// lowered, so a lambda literal in argument position can record it
    /// as its implicit label (`with(n) { … }` → the lambda's body Func
    /// gets `implicit_label = "with"`).
    pending_lambda_label: ?[]const u8 = null,
    /// Expected type for the expression currently in tail position of a
    /// typed context (a `val x: T = …` initializer, a `fun f(): T = …`
    /// expression body, or `return …`). Lets an inline `reified` call
    /// with no explicit `<…>` infer its type argument from context.
    pending_expected: ?ast.TypeRef = null,
    /// Declared return type of the function being lowered, used to infer
    /// the type argument of a reified inline call in `return …` position.
    declared_return: ?ast.TypeRef = null,

    pub fn init(allocator: Allocator, module: *Module) Allocator.Error!FuncBuilder {
        var self = FuncBuilder{
            .allocator = allocator,
            .module = module,
            .self_package = lower_self_package,
            .cur = BlockId.from(0),
            .next_reg = 0,
            .outer_names = StringSet.init(allocator),
            .capture_regs = StringRegMap.init(allocator),
            .mutables = StringSet.init(allocator),
            .mutable_homes = StringRegMap.init(allocator),
            .boxed_vars = StringSet.init(allocator),
            .any_typed_locals = StringSet.init(allocator),
            .own_members = StringSet.init(allocator),
            .enclosing_members = StringSet.init(allocator),
            .private_method_fids = StringFuncIdMap.init(allocator),
            .param_names = StringSet.init(allocator),
            .local_fns = StringSet.init(allocator),
            .local_decl_types = std.StringHashMap([]const u8).init(allocator),
            .local_init_exprs = std.StringHashMap(*const ast.Expr).init(allocator),
            .local_ext_fns = StringSet.init(allocator),
            .receiver_lambda_params = StringSet.init(allocator),
            .generic_typed_params = StringSet.init(allocator),
            .reified_type_binds = StringRegMap.init(allocator),
            .is_lambda_body = false,
            .is_anon_fn_body = false,
            .is_named_local_fn = false,
            .is_inline = false,
            .is_param_thunk = false,
        };
        const entry = Block{
            .id = BlockId.from(0),
            .insts = &.{},
            .terminator = .{ .Return = null },
        };
        try self.blocks.append(allocator, entry);
        try self.scopes.append(allocator, StringRegMap.init(allocator));
        return self;
    }

    pub fn deinit(self: *FuncBuilder) void {
        const a = self.allocator;
        for (self.blocks.items) |*b| {
            if (b.insts.len != 0) a.free(b.insts);
            if (b.catches.len != 0) a.free(b.catches);
        }
        self.blocks.deinit(a);
        for (self.scopes.items) |*s| s.deinit();
        self.scopes.deinit(a);
        self.outer_names.deinit();
        self.capture_order.deinit(a);
        self.capture_regs.deinit();
        self.loops.deinit(a);
        self.mutables.deinit();
        self.mutable_homes.deinit();
        self.boxed_vars.deinit();
        self.any_typed_locals.deinit();
        self.own_members.deinit();
        self.enclosing_members.deinit();
        self.private_method_fids.deinit();
        self.param_names.deinit();
        self.local_fns.deinit();
        self.local_decl_types.deinit();
        self.local_init_exprs.deinit();
        self.local_ext_fns.deinit();
        self.receiver_lambda_params.deinit();
        self.generic_typed_params.deinit();
        self.reified_type_binds.deinit();
        self.finally_stack.deinit(a);
        self.inline_return.deinit(a);
        self.inline_stack.deinit(a);
        for (self.inline_lambda_subst.items) |*frame| {
            frame.subst.deinit();
            a.free(frame.snapshot);
        }
        self.inline_lambda_subst.deinit(a);
        self.inline_lambda_ret.deinit(a);
    }

    /// Set the expected (tail-position) type, returning the previous
    /// value so the caller can restore it after lowering the expression.
    pub fn pushExpected(self: *FuncBuilder, ty: ?ast.TypeRef) ?ast.TypeRef {
        const prev = self.pending_expected;
        self.pending_expected = ty;
        return prev;
    }
    pub fn restoreExpected(self: *FuncBuilder, prev: ?ast.TypeRef) void {
        self.pending_expected = prev;
    }
    pub fn peekExpected(self: *const FuncBuilder) ?ast.TypeRef {
        return self.pending_expected;
    }
    pub fn setDeclaredReturn(self: *FuncBuilder, ty: ?ast.TypeRef) void {
        self.declared_return = ty;
    }
    pub fn declaredReturn(self: *const FuncBuilder) ?ast.TypeRef {
        return self.declared_return;
    }

    pub fn currentInlineFn(self: *const FuncBuilder) ?[]const u8 {
        if (self.inline_stack.items.len == 0) return null;
        return self.inline_stack.items[self.inline_stack.items.len - 1];
    }
    pub fn pushInlineLambdaRet(self: *FuncBuilder, label: []const u8, r: Reg, end: BlockId) Allocator.Error!void {
        try self.inline_lambda_ret.append(self.allocator, .{ .label = label, .reg = r, .end = end });
    }
    pub fn popInlineLambdaRet(self: *FuncBuilder) void {
        _ = self.inline_lambda_ret.pop();
    }
    pub fn inlineLambdaRetFor(self: *const FuncBuilder, label: []const u8) ?InlineReturn {
        var i = self.inline_lambda_ret.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.inline_lambda_ret.items[i];
            if (std.mem.eql(u8, f.label, label)) return .{ .reg = f.reg, .join = f.end };
        }
        return null;
    }

    pub fn inlineActiveReturn(self: *const FuncBuilder) ?InlineReturn {
        if (self.inline_return.items.len == 0) return null;
        return self.inline_return.items[self.inline_return.items.len - 1];
    }
    pub fn pushInlineReturn(self: *FuncBuilder, r: Reg, join: BlockId) Allocator.Error!void {
        try self.inline_return.append(self.allocator, .{ .reg = r, .join = join });
    }
    pub fn popInlineReturn(self: *FuncBuilder) void {
        _ = self.inline_return.pop();
    }
    /// Take ownership of the current `inline_return` stack, leaving it
    /// empty. The caller must `restoreInlineReturn` the returned slice.
    pub fn takeInlineReturn(self: *FuncBuilder) Allocator.Error![]InlineReturn {
        const owned = try self.inline_return.toOwnedSlice(self.allocator);
        self.inline_return = .empty;
        return owned;
    }
    pub fn restoreInlineReturn(self: *FuncBuilder, saved: []InlineReturn) Allocator.Error!void {
        self.inline_return.clearRetainingCapacity();
        try self.inline_return.appendSlice(self.allocator, saved);
        self.allocator.free(saved);
    }
    pub fn inlineInProgress(self: *const FuncBuilder, name: []const u8) bool {
        for (self.inline_stack.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
    pub fn pushInlineName(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.inline_stack.append(self.allocator, name);
    }
    pub fn popInlineName(self: *FuncBuilder) void {
        _ = self.inline_stack.pop();
    }
    /// Push an inline-fn-splice frame. Takes ownership of `m`; a
    /// snapshot of the current `inline_return` is duplicated into the
    /// frame.
    pub fn pushInlineLambdaFrame(self: *FuncBuilder, m: std.StringHashMap(*const ast.Expr)) Allocator.Error!void {
        const snap = try self.allocator.dupe(InlineReturn, self.inline_return.items);
        try self.inline_lambda_subst.append(self.allocator, .{ .subst = m, .snapshot = snap });
    }
    pub fn popInlineLambdaFrame(self: *FuncBuilder) void {
        if (self.inline_lambda_subst.pop()) |frame| {
            var f = frame;
            f.subst.deinit();
            self.allocator.free(f.snapshot);
        }
    }
    /// Only the innermost inline frame's lambda params are in scope.
    pub fn inlineLambdaFor(self: *const FuncBuilder, name: []const u8) ?*const ast.Expr {
        if (self.inline_lambda_subst.items.len == 0) return null;
        const top = &self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1];
        return top.subst.get(name);
    }
    /// The `inline_return` snapshot captured when the innermost
    /// inline-lambda frame was pushed — the owner splice's localize
    /// target for an unlabeled `return` in a lambda from that frame.
    /// Borrowed; valid until the frame is popped.
    pub fn inlineLambdaOwnerReturn(self: *const FuncBuilder) ?[]const InlineReturn {
        if (self.inline_lambda_subst.items.len == 0) return null;
        return self.inline_lambda_subst.items[self.inline_lambda_subst.items.len - 1].snapshot;
    }

    pub fn markAnyTyped(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.any_typed_locals.put(name, {});
    }
    pub fn isAnyTyped(self: *const FuncBuilder, name: []const u8) bool {
        return self.any_typed_locals.contains(name);
    }

    pub fn markMutable(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.mutables.put(name, {});
    }
    pub fn isMutable(self: *const FuncBuilder, name: []const u8) bool {
        return self.mutables.contains(name);
    }

    pub fn setMutableHome(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        try self.mutable_homes.put(name, reg);
    }
    pub fn mutableHome(self: *const FuncBuilder, name: []const u8) ?Reg {
        return self.mutable_homes.get(name);
    }

    /// Replace the boxed-var set with `names`. Takes ownership of
    /// `names`; the previous set is freed.
    pub fn setBoxedVars(self: *FuncBuilder, names: StringSet) void {
        self.boxed_vars.deinit();
        self.boxed_vars = names;
    }
    pub fn markBoxed(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.boxed_vars.put(name, {});
    }
    /// Remove a boxing mark added transiently (e.g. for the duration of an
    /// inline-body splice) so it cannot leak onto a same-named caller local.
    pub fn unmarkBoxed(self: *FuncBuilder, name: []const u8) void {
        _ = self.boxed_vars.remove(name);
    }
    pub fn isBoxed(self: *const FuncBuilder, name: []const u8) bool {
        return self.boxed_vars.contains(name);
    }
    /// Snapshot the boxed-var set into a fresh owned `StringSet` the
    /// caller must `deinit`.
    pub fn boxedVarsSnapshot(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.boxed_vars);
    }

    /// Seed the captured-name set for a nested function builder
    /// (lambda body). Takes ownership of `names`.
    pub fn setOuterNames(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = true;
    }
    pub fn setOuterNamesWithoutLambda(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        // The one body shape lowered this way is an anonymous-function
        // expression (`fun(...) { ... }`). It is not a lambda for
        // return/label semantics (`return` is local), but its bare names
        // resolve against the enclosing receivers exactly like a lambda's,
        // and its implicit `this` arrives through the capture slot.
        self.is_anon_fn_body = true;
    }
    pub fn isAnonFnBody(self: *const FuncBuilder) bool {
        return self.is_anon_fn_body;
    }
    /// A body whose implicit `this` arrives through the closure capture
    /// slot rather than a bound parameter, and whose bare names resolve
    /// against the receivers in scope at its creation site: lambda bodies,
    /// named local fns, and anonymous-function bodies.
    pub fn capturesThisSlot(self: *const FuncBuilder) bool {
        return self.is_lambda_body or self.is_anon_fn_body;
    }
    pub fn setInline(self: *FuncBuilder, inline_: bool) void {
        self.is_inline = inline_;
    }
    pub fn isLambdaBody(self: *const FuncBuilder) bool {
        return self.is_lambda_body;
    }
    pub fn setOuterNamesNamedLocalFn(self: *FuncBuilder, names: StringSet) void {
        self.outer_names.deinit();
        self.outer_names = names;
        self.is_lambda_body = true;
        self.is_named_local_fn = true;
    }
    pub fn isNamedLocalFn(self: *const FuncBuilder) bool {
        return self.is_named_local_fn;
    }

    /// Record a capture reference encountered during lowering.
    /// Returns the per-lambda capture index. Idempotent for the
    /// same name.
    pub fn recordCapture(self: *FuncBuilder, name: []const u8) Allocator.Error!u16 {
        if (self.capture_regs.contains(name)) {
            for (self.capture_order.items, 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return @intCast(i);
            }
            return 0;
        }
        const idx: u16 = @intCast(self.capture_order.items.len);
        try self.capture_order.append(self.allocator, name);
        const r = self.allocReg();
        try self.capture_regs.put(name, r);
        return idx;
    }

    /// True when a name names an outer-frame capture this builder is
    /// allowed to reference.
    pub fn knowsOuter(self: *const FuncBuilder, name: []const u8) bool {
        return self.outer_names.contains(name);
    }

    /// Capture-name list in declaration order.
    pub fn capturesTaken(self: *const FuncBuilder) []const []const u8 {
        return self.capture_order.items;
    }

    pub fn pushLoop(self: *FuncBuilder, label: ?[]const u8, cont_t: BlockId, brk_t: BlockId) Allocator.Error!void {
        try self.loops.append(self.allocator, .{
            .label = label,
            .continue_target = cont_t,
            .break_target = brk_t,
        });
    }
    pub fn popLoop(self: *FuncBuilder) void {
        _ = self.loops.pop();
    }
    pub fn loopFor(self: *const FuncBuilder, label: ?[]const u8) ?*const LoopFrame {
        if (label) |l| {
            var i = self.loops.items.len;
            while (i > 0) {
                i -= 1;
                const f = &self.loops.items[i];
                if (f.label) |fl| {
                    if (std.mem.eql(u8, fl, l)) return f;
                }
            }
            return null;
        }
        if (self.loops.items.len == 0) return null;
        return &self.loops.items[self.loops.items.len - 1];
    }

    /// Bind a name in the current scope.
    pub fn bind(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        try self.scopes.items[self.scopes.items.len - 1].put(name, reg);
    }

    /// Rebind a name. If the name is already bound in some live frame,
    /// update that frame's mapping in place; otherwise bind it in the
    /// current scope.
    pub fn rebind(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].contains(name)) {
                try self.scopes.items[i].put(name, reg);
                return;
            }
        }
        try self.scopes.items[self.scopes.items.len - 1].put(name, reg);
    }

    pub fn setOwnerClass(self: *FuncBuilder, name: []const u8) void {
        self.owner_class = name;
    }
    pub fn ownerClass(self: *const FuncBuilder) ?[]const u8 {
        return self.owner_class;
    }
    pub fn setRecvTy(self: *FuncBuilder, name: ?[]const u8) void {
        self.recv_ty = name;
    }
    pub fn recvTy(self: *const FuncBuilder) ?[]const u8 {
        return self.recv_ty;
    }
    /// Replace the own-members set. Takes ownership of `set`.
    pub fn setOwnMembers(self: *FuncBuilder, set: StringSet) void {
        self.own_members.deinit();
        self.own_members = set;
    }
    pub fn ownMembers(self: *const FuncBuilder) *const StringSet {
        return &self.own_members;
    }
    /// Replace the enclosing-members set. Takes ownership of `set`.
    pub fn setEnclosingMembers(self: *FuncBuilder, set: StringSet) void {
        self.enclosing_members.deinit();
        self.enclosing_members = set;
    }
    /// The lexically enclosing class declares a member named `name`.
    pub fn hasEnclosingMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name) or self.enclosing_members.contains(name);
    }
    /// The enclosing-class member set to hand a lambda lowered inside
    /// this builder. The caller owns the returned set.
    pub fn enclosingMembersForChild(self: *const FuncBuilder) Allocator.Error!StringSet {
        if (self.own_members.count() == 0) {
            return cloneStringSet(self.allocator, &self.enclosing_members);
        }
        return cloneStringSet(self.allocator, &self.own_members);
    }
    /// Replace the private-method-fid map. Takes ownership of `map`.
    pub fn setPrivateMethodFids(self: *FuncBuilder, map: StringFuncIdMap) void {
        self.private_method_fids.deinit();
        self.private_method_fids = map;
    }
    pub fn privateMethodFid(self: *const FuncBuilder, name: []const u8) ?FuncId {
        return self.private_method_fids.get(name);
    }
    pub fn hasOwnMember(self: *const FuncBuilder, name: []const u8) bool {
        return self.own_members.contains(name);
    }
    /// Swap-in a new `owner_class` + `own_members` pair and return the
    /// previous values, so an inline splice can run the spliced body in
    /// the inline fn's enclosing-class context and then restore the
    /// caller's. Ownership of `own_members` passes in; ownership of the
    /// returned set passes back out.
    pub fn swapOwnerContext(
        self: *FuncBuilder,
        owner_class: ?[]const u8,
        own_members: StringSet,
    ) struct { class: ?[]const u8, members: StringSet } {
        const prev_class = self.owner_class;
        const prev_members = self.own_members;
        self.owner_class = owner_class;
        self.own_members = own_members;
        return .{ .class = prev_class, .members = prev_members };
    }
    pub fn restoreOwnerContext(
        self: *FuncBuilder,
        owner_class: ?[]const u8,
        own_members: StringSet,
    ) void {
        self.owner_class = owner_class;
        self.own_members.deinit();
        self.own_members = own_members;
    }
    pub fn setParamThunk(self: *FuncBuilder, on: bool) void {
        self.is_param_thunk = on;
    }
    pub fn isParamThunk(self: *const FuncBuilder) bool {
        return self.is_param_thunk;
    }
    pub fn setTailrecSelf(self: *FuncBuilder, name: []const u8) void {
        self.tailrec_self = name;
    }
    pub fn tailrecSelf(self: *const FuncBuilder) ?[]const u8 {
        return self.tailrec_self;
    }
    pub fn setTailrecSelfHasThis(self: *FuncBuilder, on: bool) void {
        self.tailrec_self_this = on;
    }
    pub fn tailrecSelfHasThis(self: *const FuncBuilder) bool {
        return self.tailrec_self_this;
    }
    /// Record a local's declared type / initializer for inline-overload
    /// receiver narrowing.
    pub fn setLocalDeclType(self: *FuncBuilder, name: []const u8, ty: []const u8) Allocator.Error!void {
        try self.local_decl_types.put(name, ty);
        _ = self.local_init_exprs.remove(name);
    }
    pub fn setLocalInitExpr(self: *FuncBuilder, name: []const u8, e: *const ast.Expr) Allocator.Error!void {
        try self.local_init_exprs.put(name, e);
        _ = self.local_decl_types.remove(name);
    }
    pub fn localDeclType(self: *const FuncBuilder, name: []const u8) ?[]const u8 {
        return self.local_decl_types.get(name);
    }
    pub fn localInitExpr(self: *const FuncBuilder, name: []const u8) ?*const ast.Expr {
        return self.local_init_exprs.get(name);
    }

    pub fn markLocalFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_fns.put(name, {});
    }
    pub fn isLocalFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_fns.contains(name);
    }
    pub fn markLocalExtFn(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.local_ext_fns.put(name, {});
    }
    pub fn isLocalExtFn(self: *const FuncBuilder, name: []const u8) bool {
        return self.local_ext_fns.contains(name);
    }
    pub fn markReceiverLambdaParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.receiver_lambda_params.put(name, {});
    }
    pub fn isReceiverLambdaParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.receiver_lambda_params.contains(name);
    }
    /// The receiver-lambda-param names this builder knows. The caller
    /// owns the returned set.
    pub fn receiverLambdaParamNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.receiver_lambda_params);
    }
    /// Seed this builder's receiver-lambda-param set from an enclosing
    /// scope's. Copies the names; the caller keeps ownership of `names`.
    pub fn inheritReceiverLambdaParams(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.receiver_lambda_params.put(k.*, {});
    }
    pub fn unmarkReceiverLambdaParam(self: *FuncBuilder, name: []const u8) void {
        _ = self.receiver_lambda_params.remove(name);
    }
    /// The local-extension-function names this builder knows. The caller
    /// owns the returned set.
    pub fn localExtFnNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        return cloneStringSet(self.allocator, &self.local_ext_fns);
    }
    /// Seed this builder's local-extension-function set from an enclosing
    /// scope's, so a captured local ext fn called bare in a nested lambda
    /// still gets the enclosing receiver prepended. Copies the names; the
    /// caller keeps ownership of `names`.
    pub fn inheritLocalExtFns(self: *FuncBuilder, names: *const StringSet) Allocator.Error!void {
        var it = names.keyIterator();
        while (it.next()) |k| try self.local_ext_fns.put(k.*, {});
    }
    pub fn markGenericTypedParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.generic_typed_params.put(name, {});
    }
    pub fn isGenericTypedParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.generic_typed_params.contains(name);
    }
    pub fn clearGenericTypedParam(self: *FuncBuilder, name: []const u8) void {
        _ = self.generic_typed_params.remove(name);
    }
    /// Record a splice's reified type-parameter binding; returns the
    /// shadowed binding (if any) so the splice can restore it on exit.
    pub fn bindReifiedType(self: *FuncBuilder, name: []const u8, reg: Reg) Allocator.Error!?Reg {
        const prev = self.reified_type_binds.get(name);
        try self.reified_type_binds.put(name, reg);
        return prev;
    }
    pub fn restoreReifiedType(self: *FuncBuilder, name: []const u8, prev: ?Reg) void {
        if (prev) |r| {
            self.reified_type_binds.put(name, r) catch {};
        } else {
            _ = self.reified_type_binds.remove(name);
        }
    }
    pub fn resolveReifiedType(self: *const FuncBuilder, name: []const u8) ?Reg {
        return self.reified_type_binds.get(name);
    }
    pub fn pushFinally(self: *FuncBuilder, block: ast.Block) Allocator.Error!void {
        try self.finally_stack.append(self.allocator, block);
    }
    pub fn popFinally(self: *FuncBuilder) void {
        _ = self.finally_stack.pop();
    }
    /// Snapshot the active finally blocks into a fresh owned slice.
    pub fn activeFinallys(self: *const FuncBuilder) Allocator.Error![]ast.Block {
        return self.allocator.dupe(ast.Block, self.finally_stack.items);
    }
    /// Replace the finally stack with `replacement`, returning the
    /// previous stack as an owned slice. Takes ownership of
    /// `replacement`.
    pub fn swapFinallyStack(self: *FuncBuilder, replacement: []ast.Block) Allocator.Error![]ast.Block {
        const prev = try self.finally_stack.toOwnedSlice(self.allocator);
        self.finally_stack = .empty;
        try self.finally_stack.appendSlice(self.allocator, replacement);
        self.allocator.free(replacement);
        return prev;
    }
    pub fn markParam(self: *FuncBuilder, name: []const u8) Allocator.Error!void {
        try self.param_names.put(name, {});
    }
    pub fn isParam(self: *const FuncBuilder, name: []const u8) bool {
        return self.param_names.contains(name);
    }

    pub fn resolve(self: *const FuncBuilder, name: []const u8) ?Reg {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |r| return r;
        }
        return null;
    }

    /// Attach catch handlers + an optional finally id to a block.
    /// Takes ownership of `catches`.
    pub fn attachCatches(
        self: *FuncBuilder,
        block: BlockId,
        catches: []CatchHandler,
        finally: ?BlockId,
    ) void {
        const cur = block.int();
        if (self.blocks.items[cur].catches.len != 0) self.allocator.free(self.blocks.items[cur].catches);
        self.blocks.items[cur].catches = catches;
        self.blocks.items[cur].finally = finally;
    }

    /// Mark `done` as the post-finally sentinel for the try-region
    /// whose body's entry block is `body_entry`.
    pub fn setFinallyDoneFor(self: *FuncBuilder, body_entry: BlockId, done: BlockId) void {
        self.blocks.items[body_entry.int()].finally_done = done;
        self.blocks.items[done.int()].finally_done_for = body_entry;
    }

    /// Snapshot every register currently bound in any live scope, in
    /// ascending register order. The caller owns the returned slice.
    pub fn capturedRegs(self: *const FuncBuilder) Allocator.Error![]Reg {
        var out: std.ArrayList(Reg) = .empty;
        defer out.deinit(self.allocator);
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();
        for (self.scopes.items) |*frame| {
            var it = frame.valueIterator();
            while (it.next()) |r| {
                const gop = try seen.getOrPut(r.int());
                if (!gop.found_existing) try out.append(self.allocator, r.*);
            }
        }
        const slice = try out.toOwnedSlice(self.allocator);
        std.sort.pdq(Reg, slice, {}, struct {
            fn less(_: void, a: Reg, b: Reg) bool {
                return a.int() < b.int();
            }
        }.less);
        return slice;
    }

    /// Names currently visible across the live scope chain. The caller
    /// owns the returned set.
    pub fn visibleNames(self: *const FuncBuilder) Allocator.Error!StringSet {
        var out = StringSet.init(self.allocator);
        for (self.scopes.items) |*frame| {
            var it = frame.keyIterator();
            while (it.next()) |k| try out.put(k.*, {});
        }
        // Include names captured from the enclosing scope so a nested
        // lambda's body knows it can reach them by walking the capture
        // chain.
        var oit = self.outer_names.keyIterator();
        while (oit.next()) |k| try out.put(k.*, {});
        return out;
    }

    /// Push a fresh scope.
    pub fn pushScope(self: *FuncBuilder) Allocator.Error!void {
        try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
    }

    /// Pop the current scope.
    pub fn popScope(self: *FuncBuilder) Allocator.Error!void {
        if (self.scopes.pop()) |frame| {
            var f = frame;
            f.deinit();
        }
        if (self.scopes.items.len == 0) {
            try self.scopes.append(self.allocator, StringRegMap.init(self.allocator));
        }
    }

    /// Allocate a fresh register.
    pub fn allocReg(self: *FuncBuilder) Reg {
        const r = Reg.from(self.next_reg);
        self.next_reg += 1;
        return r;
    }

    /// Allocate a fresh empty block.
    pub fn allocBlock(self: *FuncBuilder) Allocator.Error!BlockId {
        const id = BlockId.from(@intCast(self.blocks.items.len));
        try self.blocks.append(self.allocator, .{
            .id = id,
            .insts = &.{},
            .terminator = .Unreachable,
        });
        return id;
    }

    /// Switch the cursor to a block.
    pub fn switchTo(self: *FuncBuilder, b: BlockId) void {
        self.cur = b;
    }

    /// Append an instruction to the current block.
    pub fn push(self: *FuncBuilder, inst: Inst) Allocator.Error!void {
        const cur = self.cur.int();
        const block = &self.blocks.items[cur];
        const old = block.insts;
        const new = try self.allocator.alloc(Inst, old.len + 1);
        @memcpy(new[0..old.len], old);
        new[old.len] = inst;
        if (old.len != 0) self.allocator.free(old);
        block.insts = new;
    }

    /// Finalise the current block with a terminator.
    pub fn terminate(self: *FuncBuilder, t: Terminator) void {
        const cur = self.cur.int();
        self.blocks.items[cur].terminator = t;
    }

    /// Convenience: intern a constant and emit a `Const` inst.
    pub fn emitConst(self: *FuncBuilder, c: Const) Allocator.Error!Reg {
        const dst = self.allocReg();
        const id = try self.module.internConst(self.allocator, c);
        try self.push(.{ .Const = .{ .dst = dst, .value = id } });
        return dst;
    }

    /// Finish building. The block list is handed off into the returned
    /// `Func`, and the builder's `blocks` are cleared so a subsequent
    /// `deinit` does not double-free them. Caller supplies the metadata
    /// that lives outside the per-function blocks.
    pub fn finish(
        self: *FuncBuilder,
        name: []const u8,
        fqn: []const u8,
        return_ty: TypeRef,
    ) Allocator.Error!Func {
        const n_locals = self.next_reg;
        const blocks = try self.blocks.toOwnedSlice(self.allocator);
        self.blocks = .empty;
        const capture_order = try self.allocator.dupe([]const u8, self.capture_order.items);
        return Func{
            .id = FuncId.from(0), // assigned by the caller when adding to Module
            .name = name,
            .fqn = fqn,
            .params = &.{},
            .return_ty = return_ty,
            .n_locals = n_locals,
            .blocks = blocks,
            .entry = BlockId.from(0),
            .is_suspend = false,
            .is_tailrec = self.tailrec_self != null,
            .is_lambda = false,
            .is_inline = self.is_inline,
            .capture_order = capture_order,
            .implicit_label = null,
            .low_priority = false,
        };
    }
};

pub const LoopFrame = struct {
    label: ?[]const u8,
    continue_target: BlockId,
    break_target: BlockId,
};

/// Duplicate a `StringHashMap(void)` into a fresh owned set sharing the
/// borrowed key slices.
fn cloneStringSet(allocator: Allocator, src: *const StringSet) Allocator.Error!StringSet {
    var out = StringSet.init(allocator);
    var it = src.keyIterator();
    while (it.next()) |k| try out.put(k.*, {});
    return out;
}

// -------------------------------------------------------------------------
// TypeRef builder constructors (mirrors the Rust `impl TypeRef`).
// -------------------------------------------------------------------------

pub fn typeUnit() TypeRef {
    return .{ .name = "kotlin.Unit", .nullable = false, .args = &.{} };
}
pub fn typeNothing() TypeRef {
    return .{ .name = "kotlin.Nothing", .nullable = false, .args = &.{} };
}
pub fn typeInt() TypeRef {
    return .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
}
pub fn typeLong() TypeRef {
    return .{ .name = "kotlin.Long", .nullable = false, .args = &.{} };
}
pub fn typeBool() TypeRef {
    return .{ .name = "kotlin.Boolean", .nullable = false, .args = &.{} };
}
pub fn typeString() TypeRef {
    return .{ .name = "kotlin.String", .nullable = false, .args = &.{} };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Free a `Func` produced by `finish` in a test: its per-block instruction
/// / catch slices (skipping the comptime-empty sentinels), the block list,
/// and the capture-name list.
fn freeFunc(func: Func) void {
    for (func.blocks) |b| {
        if (b.insts.len != 0) testing.allocator.free(b.insts);
        if (b.catches.len != 0) testing.allocator.free(b.catches);
    }
    testing.allocator.free(func.blocks);
    if (func.capture_order.len != 0) testing.allocator.free(func.capture_order);
}

test {
    testing.refAllDecls(@This());
}

test "alloc_reg increments" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r0 = b.allocReg();
    const r1 = b.allocReg();
    try testing.expectEqual(@as(u32, 0), r0.int());
    try testing.expectEqual(@as(u32, 1), r1.int());
}

test "bind and resolve through scope chain" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const p = b.allocReg();
    try b.bind("x", p);
    try testing.expectEqual(p, b.resolve("x").?);
    try testing.expect(b.resolve("y") == null);
}

test "rebind updates the frame holding the name" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r0 = b.allocReg();
    try b.bind("n", r0);
    try b.pushScope();
    const r1 = b.allocReg();
    try b.rebind("n", r1);
    try b.popScope();
    // The outer frame's binding was updated in place.
    try testing.expectEqual(r1, b.resolve("n").?);
}

test "alloc_block extends the block list" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.blocks.items.len);
    const nb = try b.allocBlock();
    try testing.expectEqual(@as(u32, 1), nb.int());
    try testing.expectEqual(@as(usize, 2), b.blocks.items.len);
}

test "push appends instructions to the current block" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const r = try b.emitConst(.{ .Int = 7 });
    b.terminate(.{ .Return = r });
    const func = try b.finish("f", "test.f", typeInt());
    defer freeFunc(func);
    try testing.expectEqual(@as(usize, 1), func.blocks[0].insts.len);
    try testing.expect(func.blocks[0].insts[0] == .Const);
}

test "record_capture is idempotent" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const idx_a = try b.recordCapture("a");
    const idx_b = try b.recordCapture("b");
    const idx_a_again = try b.recordCapture("a");
    try testing.expectEqual(@as(u16, 0), idx_a);
    try testing.expectEqual(@as(u16, 1), idx_b);
    try testing.expectEqual(@as(u16, 0), idx_a_again);
    try testing.expectEqual(@as(usize, 2), b.capturesTaken().len);
}

test "loop frame lookup by label and innermost" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const c0 = try b.allocBlock();
    const e0 = try b.allocBlock();
    try b.pushLoop("outer", c0, e0);
    const c1 = try b.allocBlock();
    const e1 = try b.allocBlock();
    try b.pushLoop(null, c1, e1);
    // Bare lookup hits the innermost frame.
    try testing.expectEqual(c1, b.loopFor(null).?.continue_target);
    // Labeled lookup finds the matching outer frame.
    try testing.expectEqual(c0, b.loopFor("outer").?.continue_target);
    try testing.expect(b.loopFor("missing") == null);
}

test "finish carries tailrec and inline flags" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    b.setTailrecSelf("f");
    b.setInline(true);
    const func = try b.finish("f", "test.f", typeUnit());
    defer freeFunc(func);
    try testing.expect(func.is_tailrec);
    try testing.expect(func.is_inline);
}
