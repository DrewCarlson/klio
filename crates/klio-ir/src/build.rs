//! Builders for assembling an IR `Func` block-by-block.
//!
//! The lowering pass in `crate::lower` uses these to emit
//! instructions. Kept separate from the type definitions so the
//! lowering surface is small enough to skim.

use crate::{Block, BlockId, Const, Func, Inst, Module, Reg, Terminator, TypeRef};

/// Per-function builder. Owns a fresh register counter, the list of
/// blocks, and a "current block" cursor that the lowering pass
/// appends to.
pub struct FuncBuilder<'a> {
    pub module: &'a mut Module,
    pub blocks: Vec<Block>,
    pub cur: BlockId,
    next_reg: u32,
}

impl<'a> FuncBuilder<'a> {
    pub fn new(module: &'a mut Module) -> Self {
        let entry = Block {
            id: BlockId(0),
            insts: Vec::new(),
            terminator: Terminator::Return(None),
        };
        Self {
            module,
            blocks: vec![entry],
            cur: BlockId(0),
            next_reg: 0,
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
