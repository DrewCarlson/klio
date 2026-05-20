//! Builders for assembling an IR `Func` block-by-block.
//!
//! The lowering pass in `crate::lower` uses these to emit
//! instructions. Kept separate from the type definitions so the
//! lowering surface is small enough to skim.

use crate::{Block, BlockId, Const, Func, Inst, Module, Reg, Terminator, TypeRef};

/// Per-function builder. Owns a fresh register counter, the list of
/// blocks, and a "current block" cursor that the lowering pass
/// appends to. Carries a simple scope stack so the lowering pass
/// can resolve `Path { name }` reads against function parameters
/// and locally introduced bindings.
pub struct FuncBuilder<'a> {
    pub module: &'a mut Module,
    pub blocks: Vec<Block>,
    pub cur: BlockId,
    next_reg: u32,
    /// Scope stack. The bottom frame holds the function's parameter
    /// bindings; lowering pushes a fresh frame per block expression
    /// so val/var declarations are popped correctly.
    scopes: Vec<std::collections::HashMap<String, Reg>>,
    /// Names visible to the function but living in an enclosing
    /// frame. Lowering a lambda body seeds these from the outer
    /// FuncBuilder's scope chain; references to them lower as
    /// `LoadCapture` insts and record the capture-name so the
    /// lambda-construction site knows which outer registers to
    /// snapshot.
    outer_names: std::collections::HashSet<String>,
    capture_order: Vec<String>,
    capture_regs: std::collections::HashMap<String, Reg>,
    /// Loop context stack. Each frame names the loop's continue
    /// target (header / latch) and break target (exit). The frame's
    /// optional `label` matches an explicit `break@label` /
    /// `continue@label`; bare jumps target the innermost frame.
    loops: Vec<LoopFrame>,
    /// Names declared as `var` (mutable) in any live scope. `val`
    /// bindings are absent. Used by compound-assignment lowering to
    /// pick between rebind (Path target on a `var`) and plusAssign
    /// dispatch (Path target on a `val`, e.g. `val xs = mutableListOf…`).
    mutables: std::collections::HashSet<String>,
    /// `var` locals each get a permanent "home" register. Reads of
    /// the local always resolve to this reg; writes emit a Move
    /// into it. This gives the IR's flat block model the slot
    /// semantics that mutable Kotlin locals need — without it, a
    /// rebind inside a loop body just leaves the body's reads
    /// pointing at the pre-loop register and loops never terminate.
    mutable_homes: std::collections::HashMap<String, Reg>,
    /// Names that are boxed into a shared `Value::Cell` because a
    /// nested lambda captures them (Kotlin `Ref` boxing). Their home
    /// reg holds the `Cell`; reads emit `CellGet`, writes `CellSet`,
    /// and the declaration emits `MakeCell`. Captured into a lambda
    /// the cell `Rc` is shared, so writes from a coroutine/closure
    /// are visible at the declaration site.
    boxed_vars: std::collections::HashSet<String>,
    /// Locals declared with an `: Any` (or other erased) type
    /// annotation — used by the `==` lowering to detect a boxed
    /// operand the same way the tree walker does, so
    /// `(0.0 as Any) == (-0.0 as Any)` uses bitwise compare.
    any_typed_locals: std::collections::HashSet<String>,
    /// When the function is a class method, the simple name of
    /// the owning class. Used by `super.method()` lowering to
    /// emit `Inst::CallSuper` with the right starting class.
    owner_class: Option<String>,
    /// Names declared on the owning class (methods, body
    /// properties, primary-ctor properties). Used by method-
    /// body lowering to know whether an unqualified `foo(...)`
    /// is `this.foo(...)` (a class member) or a global lookup.
    own_members: std::collections::HashSet<String>,
    /// Private methods of `owner_class` that have already been
    /// lowered (so their FuncIds are known). A bare call in this
    /// builder's body resolving to a name in this map binds
    /// statically to the listed FuncId rather than virtual-
    /// dispatching, matching Kotlin's rule that a `private fun`
    /// is invisible to subclasses and binds at the declaring
    /// site.
    private_method_fids: std::collections::HashMap<String, crate::FuncId>,
    /// When the function is `tailrec`, the simple name of the
    /// function itself. Self-calls (`Path("<name>")(...)`) are
    /// lowered as `Terminator::TailJump` to keep the stack
    /// flat across recursion.
    tailrec_self: Option<String>,
    /// Names bound as parameters at the function entry (set by
    /// `bind_params`). Used by call-site lowering to recognise
    /// when an identifier-as-callee is a function-typed param
    /// (e.g. a builder lambda) rather than a member of the
    /// receiver.
    param_names: std::collections::HashSet<String>,
    /// Names declared as *local functions* (`fun foo() …` inside a
    /// body). A `recv.foo()` call resolves to such a local (it may
    /// be a local extension fn) — but a local `val`/`var` of the
    /// same name must NOT hijack member-call syntax.
    local_fns: std::collections::HashSet<String>,
    /// Subset of `local_fns` declared as extensions (`fun R.f(...)`);
    /// a bare call must prepend the implicit receiver as `this`.
    local_ext_fns: std::collections::HashSet<String>,
    is_lambda_body: bool,
    is_named_local_fn: bool,
    is_inline: bool,
    /// True while lowering a default-argument thunk. A default
    /// expression executes in the declaring function's scope, not as
    /// a member of the (extension) receiver — so an unqualified name
    /// that isn't a known member must resolve as a global/this probe
    /// rather than a hard `this.<name>` field read.
    is_param_thunk: bool,
    /// Inline-expansion state. `inline_return` is a stack of
    /// (result reg, join block): a `return` inside an inlined body
    /// assigns the result and jumps to the join (the inline call's
    /// value). `inline_stack` guards recursive inline. `inline_lambda_subst`
    /// maps a lambda parameter name to the argument lambda AST for
    /// the current inline frame so `param(args)` splices in place.
    inline_return: Vec<(Reg, BlockId)>,
    inline_stack: Vec<String>,
    /// Per inline-fn-splice frame: the lambda-param substitution map
    /// *and* a snapshot of `inline_return` as it was when this frame
    /// was pushed. A lambda taken from this frame was written in the
    /// body of the inline fn whose splice owns that snapshot, so an
    /// unlabeled `return` inside the spliced lambda must localize to
    /// that owner splice (restore the snapshot), not fall through to
    /// the heuristic non-local-return unwind.
    inline_lambda_subst: Vec<(
        std::collections::HashMap<String, klio_ast::Expr>,
        Vec<(Reg, BlockId)>,
    )>,
    /// Labeled-return targets for spliced inline-argument lambdas:
    /// `return@<inlineFnName>` inside such a lambda is a *local*
    /// return from the lambda invocation (its value), not a return
    /// of the caller. (label, result reg, end block).
    inline_lambda_ret: Vec<(String, Reg, BlockId)>,
}

#[derive(Debug, Clone)]
pub struct LoopFrame {
    pub label: Option<String>,
    pub continue_target: BlockId,
    pub break_target: BlockId,
}

impl<'a> FuncBuilder<'a> {
    pub fn new(module: &'a mut Module) -> Self {
        let entry = Block {
            id: BlockId(0),
            insts: Vec::new(),
            terminator: Terminator::Return(None),
            catches: Vec::new(),
            finally: None,
        };
        Self {
            module,
            blocks: vec![entry],
            cur: BlockId(0),
            next_reg: 0,
            scopes: vec![std::collections::HashMap::new()],
            loops: Vec::new(),
            outer_names: std::collections::HashSet::new(),
            capture_order: Vec::new(),
            capture_regs: std::collections::HashMap::new(),
            mutables: std::collections::HashSet::new(),
            mutable_homes: std::collections::HashMap::new(),
            boxed_vars: std::collections::HashSet::new(),
            any_typed_locals: std::collections::HashSet::new(),
            owner_class: None,
            own_members: std::collections::HashSet::new(),
            private_method_fids: std::collections::HashMap::new(),
            tailrec_self: None,
            param_names: std::collections::HashSet::new(),
            local_fns: std::collections::HashSet::new(),
            local_ext_fns: std::collections::HashSet::new(),
            is_lambda_body: false,
            is_named_local_fn: false,
            is_inline: false,
            is_param_thunk: false,
            inline_return: Vec::new(),
            inline_stack: Vec::new(),
            inline_lambda_subst: Vec::new(),
            inline_lambda_ret: Vec::new(),
        }
    }

    pub fn current_inline_fn(&self) -> Option<String> {
        self.inline_stack.last().cloned()
    }
    pub fn push_inline_lambda_ret(&mut self, label: String, r: Reg, end: BlockId) {
        self.inline_lambda_ret.push((label, r, end));
    }
    pub fn pop_inline_lambda_ret(&mut self) {
        self.inline_lambda_ret.pop();
    }
    pub fn inline_lambda_ret_for(&self, label: &str) -> Option<(Reg, BlockId)> {
        self.inline_lambda_ret
            .iter()
            .rev()
            .find(|(l, _, _)| l == label)
            .map(|(_, r, e)| (*r, *e))
    }

    pub fn inline_active_return(&self) -> Option<(Reg, BlockId)> {
        self.inline_return.last().copied()
    }
    pub fn push_inline_return(&mut self, r: Reg, join: BlockId) {
        self.inline_return.push((r, join));
    }
    pub fn pop_inline_return(&mut self) {
        self.inline_return.pop();
    }
    pub fn take_inline_return(&mut self) -> Vec<(Reg, BlockId)> {
        std::mem::take(&mut self.inline_return)
    }
    pub fn restore_inline_return(&mut self, saved: Vec<(Reg, BlockId)>) {
        self.inline_return = saved;
    }
    pub fn inline_in_progress(&self, name: &str) -> bool {
        self.inline_stack.iter().any(|n| n == name)
    }
    pub fn push_inline_name(&mut self, name: String) {
        self.inline_stack.push(name);
    }
    pub fn pop_inline_name(&mut self) {
        self.inline_stack.pop();
    }
    pub fn push_inline_lambda_frame(
        &mut self,
        m: std::collections::HashMap<String, klio_ast::Expr>,
    ) {
        let snap = self.inline_return.clone();
        self.inline_lambda_subst.push((m, snap));
    }
    pub fn pop_inline_lambda_frame(&mut self) {
        self.inline_lambda_subst.pop();
    }
    /// Only the innermost inline frame's lambda params are in scope.
    pub fn inline_lambda_for(&self, name: &str) -> Option<klio_ast::Expr> {
        self.inline_lambda_subst
            .last()
            .and_then(|(m, _)| m.get(name).cloned())
    }
    /// The `inline_return` snapshot captured when the innermost
    /// inline-lambda frame was pushed — the owner splice's localize
    /// target for an unlabeled `return` in a lambda from that frame.
    pub fn inline_lambda_owner_return(
        &self,
    ) -> Option<Vec<(Reg, BlockId)>> {
        self.inline_lambda_subst.last().map(|(_, s)| s.clone())
    }

    pub fn mark_any_typed(&mut self, name: &str) {
        self.any_typed_locals.insert(name.to_string());
    }

    #[must_use]
    pub fn is_any_typed(&self, name: &str) -> bool {
        self.any_typed_locals.contains(name)
    }

    pub fn mark_mutable(&mut self, name: &str) {
        self.mutables.insert(name.to_string());
    }

    #[must_use]
    pub fn is_mutable(&self, name: &str) -> bool {
        self.mutables.contains(name)
    }

    pub fn set_mutable_home(&mut self, name: &str, reg: Reg) {
        self.mutable_homes.insert(name.to_string(), reg);
    }

    #[must_use]
    pub fn mutable_home(&self, name: &str) -> Option<Reg> {
        self.mutable_homes.get(name).copied()
    }

    pub fn set_boxed_vars(&mut self, names: std::collections::HashSet<String>) {
        self.boxed_vars = names;
    }

    pub fn mark_boxed(&mut self, name: &str) {
        self.boxed_vars.insert(name.to_string());
    }

    #[must_use]
    pub fn is_boxed(&self, name: &str) -> bool {
        self.boxed_vars.contains(name)
    }

    #[must_use]
    pub fn boxed_vars_snapshot(&self) -> std::collections::HashSet<String> {
        self.boxed_vars.clone()
    }

    /// Seed the captured-name set for a nested function builder
    /// (lambda body). When the lambda body's lowering hits a
    /// `Path { name }` that does not resolve locally but appears
    /// in `outer_names`, lowering emits a `LoadCapture` and
    /// records the name in `capture_order` so the enclosing
    /// `Inst::Lambda` knows which outer regs to snapshot.
    pub fn set_outer_names(&mut self, names: std::collections::HashSet<String>) {
        self.outer_names = names;
        self.is_lambda_body = true;
    }

    pub fn set_outer_names_without_lambda(
        &mut self,
        names: std::collections::HashSet<String>,
    ) {
        self.outer_names = names;
    }

    pub fn set_inline(&mut self, inline: bool) {
        self.is_inline = inline;
    }

    pub fn is_lambda_body(&self) -> bool {
        self.is_lambda_body
    }

    pub fn set_outer_names_named_local_fn(
        &mut self,
        names: std::collections::HashSet<String>,
    ) {
        self.outer_names = names;
        self.is_lambda_body = true;
        self.is_named_local_fn = true;
    }

    pub fn is_named_local_fn(&self) -> bool {
        self.is_named_local_fn
    }

    /// Record a capture reference encountered during lowering.
    /// Returns the per-lambda capture index. Idempotent for the
    /// same name.
    pub fn record_capture(&mut self, name: &str) -> u16 {
        if self.capture_regs.contains_key(name) {
            // Already captured at this reg — return its index.
            return self
                .capture_order
                .iter()
                .position(|n| n == name)
                .map(|i| i as u16)
                .unwrap_or(0);
        }
        let idx = self.capture_order.len() as u16;
        self.capture_order.push(name.to_string());
        // Allocate a reg the lambda body will write LoadCapture into.
        let r = self.alloc_reg();
        self.capture_regs.insert(name.to_string(), r);
        idx
    }

    /// True when a name names an outer-frame capture this builder
    /// is allowed to reference.
    #[must_use]
    pub fn knows_outer(&self, name: &str) -> bool {
        self.outer_names.contains(name)
    }

    /// Capture-name list in declaration order. Used by the
    /// lambda-construction site to materialise the corresponding
    /// outer registers.
    pub fn captures_taken(&self) -> &[String] {
        &self.capture_order
    }

    pub fn push_loop(&mut self, label: Option<String>, cont_t: BlockId, brk_t: BlockId) {
        self.loops.push(LoopFrame {
            label,
            continue_target: cont_t,
            break_target: brk_t,
        });
    }

    pub fn pop_loop(&mut self) {
        self.loops.pop();
    }

    #[must_use]
    pub fn loop_for(&self, label: Option<&str>) -> Option<&LoopFrame> {
        match label {
            None => self.loops.last(),
            Some(l) => self.loops.iter().rev().find(|f| f.label.as_deref() == Some(l)),
        }
    }

    /// Bind a name in the current scope.
    pub fn bind(&mut self, name: impl Into<String>, reg: Reg) {
        self.scopes
            .last_mut()
            .expect("at least one scope is always live")
            .insert(name.into(), reg);
    }

    /// Rebind a name. If the name is already bound in some live
    /// frame, update that frame's mapping in place; otherwise bind
    /// it in the current scope. Used by `var` rebind / compound
    /// assignment so writes inside a nested block don't shadow the
    /// outer binding (which would make a `while (n > 0)` after
    /// `n -= 1` loop forever against the outer reg).
    pub fn rebind(&mut self, name: &str, reg: Reg) {
        for frame in self.scopes.iter_mut().rev() {
            if frame.contains_key(name) {
                frame.insert(name.to_string(), reg);
                return;
            }
        }
        self.scopes
            .last_mut()
            .expect("at least one scope is always live")
            .insert(name.to_string(), reg);
    }

    /// Resolve a simple name through the scope chain. Returns
    /// `None` when the name is not a local/parameter — callers can
    /// fall back to module-level lookup (top-level functions,
    /// imports, etc.).
    #[must_use]
    pub fn set_owner_class(&mut self, name: String) {
        self.owner_class = Some(name);
    }
    pub fn owner_class(&self) -> Option<&str> {
        self.owner_class.as_deref()
    }
    pub fn set_own_members(&mut self, set: std::collections::HashSet<String>) {
        self.own_members = set;
    }
    pub fn set_private_method_fids(
        &mut self,
        map: std::collections::HashMap<String, crate::FuncId>,
    ) {
        self.private_method_fids = map;
    }
    #[must_use]
    pub fn private_method_fid(&self, name: &str) -> Option<crate::FuncId> {
        self.private_method_fids.get(name).copied()
    }
    pub fn has_own_member(&self, name: &str) -> bool {
        self.own_members.contains(name)
    }
    /// Swap-in a new owner_class + own_members pair and return the
    /// previous values, so an inline splice can run the spliced body
    /// in the inline fn's enclosing-class context and then restore
    /// the caller's. Returns `(prev_owner_class, prev_own_members)`.
    pub fn swap_owner_context(
        &mut self,
        owner_class: Option<String>,
        own_members: std::collections::HashSet<String>,
    ) -> (Option<String>, std::collections::HashSet<String>) {
        let prev_class = std::mem::replace(&mut self.owner_class, owner_class);
        let prev_members = std::mem::replace(&mut self.own_members, own_members);
        (prev_class, prev_members)
    }
    pub fn restore_owner_context(
        &mut self,
        owner_class: Option<String>,
        own_members: std::collections::HashSet<String>,
    ) {
        self.owner_class = owner_class;
        self.own_members = own_members;
    }
    pub fn set_param_thunk(&mut self, on: bool) {
        self.is_param_thunk = on;
    }
    pub fn is_param_thunk(&self) -> bool {
        self.is_param_thunk
    }
    pub fn set_tailrec_self(&mut self, name: String) {
        self.tailrec_self = Some(name);
    }
    pub fn tailrec_self(&self) -> Option<&str> {
        self.tailrec_self.as_deref()
    }
    pub fn mark_local_fn(&mut self, name: &str) {
        self.local_fns.insert(name.to_string());
    }
    pub fn is_local_fn(&self, name: &str) -> bool {
        self.local_fns.contains(name)
    }
    pub fn mark_local_ext_fn(&mut self, name: &str) {
        self.local_ext_fns.insert(name.to_string());
    }
    pub fn is_local_ext_fn(&self, name: &str) -> bool {
        self.local_ext_fns.contains(name)
    }
    pub fn mark_param(&mut self, name: &str) {
        self.param_names.insert(name.to_string());
    }
    pub fn is_param(&self, name: &str) -> bool {
        self.param_names.contains(name)
    }

    pub fn resolve(&self, name: &str) -> Option<Reg> {
        for frame in self.scopes.iter().rev() {
            if let Some(r) = frame.get(name) {
                return Some(*r);
            }
        }
        None
    }

    /// Attach catch handlers + an optional finally id to a block.
    /// Used by Try lowering to wire the exception-edge metadata
    /// onto the body's entry block.
    pub fn attach_catches(
        &mut self,
        block: BlockId,
        catches: Vec<crate::CatchHandler>,
        finally: Option<BlockId>,
    ) {
        let cur = block.0 as usize;
        self.blocks[cur].catches = catches;
        self.blocks[cur].finally = finally;
    }

    /// Snapshot every register currently bound in any live scope.
    /// Used by lambda lowering to record the closure environment
    /// at construction time.
    #[must_use]
    pub fn captured_regs(&self) -> Vec<Reg> {
        let mut out: Vec<Reg> = Vec::new();
        let mut seen: std::collections::HashSet<u32> = std::collections::HashSet::new();
        for frame in &self.scopes {
            for (_, r) in frame {
                if seen.insert(r.0) {
                    out.push(*r);
                }
            }
        }
        out.sort_by_key(|r| r.0);
        out
    }

    /// Names currently visible across the live scope chain.
    #[must_use]
    pub fn visible_names(&self) -> std::collections::HashSet<String> {
        let mut out: std::collections::HashSet<String> = std::collections::HashSet::new();
        for frame in &self.scopes {
            for k in frame.keys() {
                out.insert(k.clone());
            }
        }
        // Include names captured from the enclosing scope so a
        // nested lambda's body knows it can reach them by walking
        // the capture chain. Without this, `{ { scope } }`'s inner
        // lambda doesn't recognise `scope` as an outer name and
        // lowers it as a global lookup.
        for n in &self.outer_names {
            out.insert(n.clone());
        }
        out
    }

    /// Push a fresh scope (`{` opens a block, lambdas open their
    /// own scope, etc.).
    pub fn push_scope(&mut self) {
        self.scopes.push(std::collections::HashMap::new());
    }

    /// Pop the current scope.
    pub fn pop_scope(&mut self) {
        self.scopes.pop();
        if self.scopes.is_empty() {
            self.scopes.push(std::collections::HashMap::new());
        }
    }

    /// Allocate a fresh register.
    pub fn alloc_reg(&mut self) -> Reg {
        let r = Reg(self.next_reg);
        self.next_reg += 1;
        r
    }

    /// Allocate a fresh empty block.
    pub fn alloc_block(&mut self) -> BlockId {
        let id = BlockId(self.blocks.len() as u32);
        self.blocks.push(Block {
            id,
            insts: Vec::new(),
            terminator: Terminator::Unreachable,
            catches: Vec::new(),
            finally: None,
        });
        id
    }

    /// Switch the cursor to a block.
    pub fn switch_to(&mut self, b: BlockId) {
        self.cur = b;
    }

    /// Append an instruction to the current block.
    pub fn push(&mut self, inst: Inst) {
        let cur = self.cur.0 as usize;
        self.blocks[cur].insts.push(inst);
    }

    /// Finalise the current block with a terminator.
    pub fn terminate(&mut self, t: Terminator) {
        let cur = self.cur.0 as usize;
        self.blocks[cur].terminator = t;
    }

    /// Convenience: intern a constant and emit a `Const` inst.
    pub fn emit_const(&mut self, c: Const) -> Reg {
        let dst = self.alloc_reg();
        let id = self.module.intern_const(c);
        self.push(Inst::Const { dst, value: id });
        dst
    }

    /// Finish building. Caller supplies metadata that lives outside
    /// the per-function blocks (FQN, params, etc.).
    pub fn finish(
        self,
        name: impl Into<String>,
        fqn: impl Into<String>,
        return_ty: TypeRef,
    ) -> Func {
        let n_locals = self.next_reg;
        Func {
            id: crate::FuncId(0), // assigned by the caller when adding to Module
            name: name.into(),
            fqn: fqn.into(),
            params: Vec::new(),
            return_ty,
            n_locals,
            blocks: self.blocks,
            entry: BlockId(0),
        is_suspend: false,
        is_tailrec: self.tailrec_self.is_some(),
        is_lambda: false,
        is_inline: self.is_inline,
        capture_order: self.capture_order.clone(),
        }
    }
}

impl TypeRef {
    pub fn unit() -> Self {
        Self { name: "kotlin.Unit".to_string(), nullable: false, args: Vec::new() }
    }
    pub fn nothing() -> Self {
        Self { name: "kotlin.Nothing".to_string(), nullable: false, args: Vec::new() }
    }
    pub fn int() -> Self {
        Self { name: "kotlin.Int".to_string(), nullable: false, args: Vec::new() }
    }
    pub fn long() -> Self {
        Self { name: "kotlin.Long".to_string(), nullable: false, args: Vec::new() }
    }
    pub fn bool() -> Self {
        Self { name: "kotlin.Boolean".to_string(), nullable: false, args: Vec::new() }
    }
    pub fn string() -> Self {
        Self { name: "kotlin.String".to_string(), nullable: false, args: Vec::new() }
    }
}
