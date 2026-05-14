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
        }
    }

    /// Seed the captured-name set for a nested function builder
    /// (lambda body). When the lambda body's lowering hits a
    /// `Path { name }` that does not resolve locally but appears
    /// in `outer_names`, lowering emits a `LoadCapture` and
    /// records the name in `capture_order` so the enclosing
    /// `Inst::Lambda` knows which outer regs to snapshot.
    pub fn set_outer_names(&mut self, names: std::collections::HashSet<String>) {
        self.outer_names = names;
    }

    /// Record a capture reference encountered during lowering.
    /// Returns the per-lambda capture index. Idempotent for the
    /// same name.
    pub fn record_capture(&mut self, name: &str) -> u16 {
        if let Some(&r) = self.capture_regs.get(name) {
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

    /// Resolve a simple name through the scope chain. Returns
    /// `None` when the name is not a local/parameter — callers can
    /// fall back to module-level lookup (top-level functions,
    /// imports, etc.).
    #[must_use]
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
