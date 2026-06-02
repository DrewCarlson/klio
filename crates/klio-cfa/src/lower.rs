//! AST → CFG lowering. Walks a `klio_ast::Block` (function / accessor
//! / init body) and produces a `Cfg` per spec §12.1.1.
//!
//! Lowering carries a "current block" that subsequent nodes append
//! to. Control-flow forms (`if`, `when`, `while`, `try`, `&&`, `||`,
//! `?:`, `?.`, `!!`, `as`, `return`/`throw`/`break`/`continue`) split
//! the current block and rewire it through the new blocks they
//! create. Terminator-emitting forms leave the current block set to
//! a fresh "dead" block with no predecessors so later statements
//! still lower cleanly into the IR (the reachability analysis will
//! prune them later).
//!
//! The lowering does not consult type information; every `Eval`
//! node is emitted with `Type::Unresolved`. A later integration
//! step routes typed expression results from the typechecker into
//! the lowering so analyses (smart-cast, reachability) can read
//! them.

use crate::builder::CfgBuilder;
use crate::ir::{
    BlockId, Cfg, EdgeKind, ExprRef, FieldId, LoopId, Node, Pattern, Place, Reg,
    SwitchArm, Symbol, Terminator,
};
use klio_ast::{
    BinOp, Block, Catch, Decl, Expr, Ident, PostfixOp, Stmt, StringPart, UnOp, WhenBranch,
    WhenPatternKind,
};
use klio_span::Span;
use klio_types::Type;

/// Lowered output: the CFG plus three side tables.
///
/// * `reg_for_span` maps an expression's source span to the register
///   that holds its computed value (last write wins when the same
///   span is evaluated along multiple paths).
/// * `reg_to_place` maps a register to the `Place` it reads, so an
///   `AssumeIs(reg, T)` on a path can refine the original place.
/// * `span_to_pos` maps a span to the `(block, node_idx)` where its
///   `Eval` lands. Smart-cast / VIA queries consult this to recover
///   the in-state right *before* the expression executes — the
///   semantics the typechecker has historically needed.
pub struct Lowered {
    pub cfg: Cfg,
    pub reg_for_span: std::collections::HashMap<(u32, u32), Reg>,
    pub reg_to_place: std::collections::HashMap<Reg, Place>,
    pub span_to_pos: std::collections::HashMap<(u32, u32), (BlockId, usize)>,
    /// Aliasing introduced by `val b = a` style bindings. Maps the
    /// new local to the place it shadows so smart-cast lookups can
    /// follow the chain. Kept here (rather than in the CFG IR) so
    /// the typechecker can consult it without an extra analysis.
    pub aliases: std::collections::HashMap<Symbol, Place>,
}

struct LoopFrame {
    #[allow(dead_code)]
    id: LoopId,
    /// Block that `continue` jumps to (typically the loop head).
    cont_target: BlockId,
    /// Block that `break` jumps to (typically the loop exit).
    break_target: BlockId,
    label: Option<String>,
}

struct LabelFrame {
    name: String,
    /// Block that `return@name` / `break@name` jumps to.
    target: BlockId,
    /// Register for the lambda/block's value, if any. Populated when
    /// `return@name expr` is encountered.
    result: Option<Reg>,
}

struct TryFrame {
    /// Each entry is (exception-type, handler-entry-block). Order
    /// matches source order; the first matching handler wins.
    handlers: Vec<(Option<Type>, BlockId)>,
    /// Block to flow into for the normal-exit copy of the finally,
    /// when one is present.
    finally_entry: Option<BlockId>,
}

/// Refinement implied by the truthiness of a boolean-typed register.
/// Carried in `pending_refinements` so `lower_if` / `lower_when` /
/// `lower_short_circuit` can emit the matching `AssumeIs` or
/// `AssumeNull` on the correct branch arm.
#[derive(Debug, Clone)]
enum Refinement {
    Is { reg: Reg, ty: Type, class_name: Option<String>, polarity: bool, span: Span },
    NullEq { reg: Reg, span: Span, eq_null: bool },
    /// Reference-equality of two registers, both of which hold a
    /// `Place`. Used to narrow each place to the intersection of
    /// the two on the truthy branch.
    RefEq { reg_a: Reg, reg_b: Reg, span: Span },
    /// `!cond` flips polarity of every contained refinement.
    Not(Box<Refinement>),
    /// `&&` of multiple refinements — all hold on the true branch.
    And(Vec<Refinement>),
    /// `||` of multiple refinements — only the intersection holds on
    /// the true branch, and the union on the false branch. For now we
    /// only emit the symmetric facts; broader handling lives in the
    /// constraint-system milestone.
    Or(Vec<Refinement>),
}

pub struct Lowering {
    b: CfgBuilder,
    loop_stack: Vec<LoopFrame>,
    label_stack: Vec<LabelFrame>,
    try_stack: Vec<TryFrame>,
    reg_for_span: std::collections::HashMap<(u32, u32), Reg>,
    reg_to_place: std::collections::HashMap<Reg, Place>,
    pending_refinements: std::collections::HashMap<Reg, Refinement>,
    span_to_pos: std::collections::HashMap<(u32, u32), (BlockId, usize)>,
    aliases: std::collections::HashMap<Symbol, Place>,
}

impl Lowering {
    #[must_use] 
    pub fn new() -> Self {
        Self {
            b: CfgBuilder::new(),
            loop_stack: Vec::new(),
            label_stack: Vec::new(),
            try_stack: Vec::new(),
            reg_for_span: std::collections::HashMap::new(),
            reg_to_place: std::collections::HashMap::new(),
            pending_refinements: std::collections::HashMap::new(),
            span_to_pos: std::collections::HashMap::new(),
            aliases: std::collections::HashMap::new(),
        }
    }

    /// Lower a function body. The CFG has one entry block and one
    /// synthetic exit block; every `return` jumps to the exit. The
    /// implicit fall-off-the-end of a `Unit`-typed body is wired to
    /// the exit by an explicit `Goto`.
    #[must_use] 
    pub fn lower_function(mut self, body: &Block, source: Span) -> Lowered {
        let entry = self.b.new_block();
        let exit = self.b.new_block();
        let mut cur = entry;
        // Establish a synthetic "function" label so `return` (no label)
        // can jump to `exit` without a separate codepath.
        self.label_stack.push(LabelFrame {
            name: "<fn>".into(),
            target: exit,
            result: None,
        });
        self.lower_block(body, &mut cur);
        self.b.set_terminator(cur, Terminator::Goto(exit));
        self.b.set_terminator(exit, Terminator::Return(None));
        let cfg = self.b.finish(entry, vec![exit], source);
        Lowered {
            cfg,
            reg_for_span: self.reg_for_span,
            reg_to_place: self.reg_to_place,
            span_to_pos: self.span_to_pos,
            aliases: self.aliases,
        }
    }

    /// Emit the `AssumeIs` / `AssumeNull` nodes implied by a
    /// refinement onto `blk`. `truth` is the polarity to interpret
    /// the refinement under: `true` for the then-arm, `false` for
    /// the else-arm.
    fn emit_refinement(&mut self, blk: BlockId, refinement: &Refinement, truth: bool) {
        match refinement {
            Refinement::Is { reg, ty, class_name, polarity, span } => {
                let effective = *polarity == truth;
                self.b.push(
                    blk,
                    Node::AssumeIs {
                        reg: *reg,
                        ty: ty.clone(),
                        class_name: class_name.clone(),
                        polarity: effective,
                        span: *span,
                    },
                );
            }
            Refinement::NullEq { reg, span, eq_null } => {
                // `x == null` true on then; the refinement is "x == null".
                // Truth=true keeps eq_null; truth=false flips it.
                let effective = *eq_null == truth;
                self.b
                    .push(blk, Node::AssumeNull { reg: *reg, eq_null: effective, span: *span });
            }
            Refinement::RefEq { reg_a, reg_b, span } => {
                self.b.push(
                    blk,
                    Node::AssumeRefEq {
                        reg_a: *reg_a,
                        reg_b: *reg_b,
                        polarity: truth,
                        span: *span,
                    },
                );
            }
            Refinement::Not(inner) => self.emit_refinement(blk, inner, !truth),
            Refinement::And(parts) => {
                if truth {
                    for p in parts {
                        self.emit_refinement(blk, p, true);
                    }
                }
                // On the false arm of `a && b`, neither part is
                // individually known — we drop refinements.
            }
            Refinement::Or(parts) => {
                if !truth {
                    for p in parts {
                        self.emit_refinement(blk, p, false);
                    }
                }
                // On the true arm of `a || b`, neither part is
                // individually known — we drop refinements.
            }
        }
    }

    fn lower_block(&mut self, block: &Block, cur: &mut BlockId) -> Option<Reg> {
        let mut last: Option<Reg> = None;
        for stmt in &block.stmts {
            last = self.lower_stmt(stmt, cur);
        }
        last
    }

    fn lower_stmt(&mut self, stmt: &Stmt, cur: &mut BlockId) -> Option<Reg> {
        match stmt {
            Stmt::Expr(e) => Some(self.lower_expr(e, cur)),
            Stmt::Decl(Decl::Property(p)) => {
                let span = p.name.span;
                self.b.push(
                    *cur,
                    Node::DeclLocal {
                        place: Symbol(p.name.name.clone()),
                        declared_ty: Type::Unresolved,
                        span,
                    },
                );
                if let Some(init) = &p.init {
                    let r = self.lower_expr(init, cur);
                    // Spec §14.1.5 bound smart casts: when an
                    // immutable local binds to a place expression
                    // (another local or a member chain) we record
                    // the aliasing so smart-cast lookups for the new
                    // name can follow the chain.
                    if !p.mutable
                        && let Some(src) = self.expr_to_place(init) {
                            self.aliases.insert(Symbol(p.name.name.clone()), src);
                        }
                    self.b.push(
                        *cur,
                        Node::Assign {
                            lhs: Place::Local(Symbol(p.name.name.clone())),
                            rhs: r,
                            span,
                        },
                    );
                }
                None
            }
            Stmt::Decl(_) => None,
            Stmt::Assign { target, op: _, value, span } => {
                let rhs = self.lower_expr(value, cur);
                let lhs_place = self.expr_to_place(target);
                let place = lhs_place.unwrap_or(Place::Local(Symbol("<expr>".into())));
                // Record both the assignment span and the LHS
                // target's span as pointing at the position right
                // before the Assign node executes. The typechecker
                // queries this for the val-first-write check.
                let pos = self.b.current_node_count(*cur).unwrap_or(0);
                self.span_to_pos.insert((span.start, span.end), (*cur, pos));
                let lhs_span = target.span();
                self.span_to_pos
                    .insert((lhs_span.start, lhs_span.end), (*cur, pos));
                self.b.push(*cur, Node::Assign { lhs: place, rhs, span: *span });
                None
            }
            Stmt::DestructuringDecl { names, init, span, .. } => {
                let r = self.lower_expr(init, cur);
                for n in names {
                    if n.name == "_" {
                        continue;
                    }
                    self.b.push(
                        *cur,
                        Node::DeclLocal {
                            place: Symbol(n.name.clone()),
                            declared_ty: Type::Unresolved,
                            span: *span,
                        },
                    );
                    self.b.push(
                        *cur,
                        Node::Assign {
                            lhs: Place::Local(Symbol(n.name.clone())),
                            rhs: r,
                            span: *span,
                        },
                    );
                }
                None
            }
        }
    }

    fn expr_to_place(&self, e: &Expr) -> Option<Place> {
        match e {
            Expr::Path { segments, .. } if segments.len() == 1 => {
                Some(Place::Local(Symbol(segments[0].name.clone())))
            }
            Expr::Member { receiver, name, safe: false, .. } => {
                let inner = self.expr_to_place(receiver)?;
                Some(Place::Field {
                    receiver: Box::new(inner),
                    field: FieldId(name.name.clone()),
                })
            }
            Expr::This { .. } => Some(Place::This),
            _ => None,
        }
    }

    fn fresh_dead_block(&mut self) -> BlockId {
        let b = self.b.new_block();
        // Default terminator is Unreachable; that's exactly what we want.
        b
    }

    fn record_reg(&mut self, span: Span, reg: Reg) -> Reg {
        self.reg_for_span.insert((span.start, span.end), reg);
        reg
    }

    fn emit_eval(&mut self, cur: BlockId, span: Span) -> Reg {
        let reg = self.b.new_reg();
        // Capture the position the eval lands at *before* pushing it
        // so smart-cast queries can read the in-state just before the
        // expression evaluates — that's the semantic the checker
        // historically needed.
        let pos = self
            .b
            .current_node_count(cur)
            .expect("emit_eval target block must exist");
        self.span_to_pos.insert((span.start, span.end), (cur, pos));
        self.b
            .push(cur, Node::Eval { reg, expr: ExprRef { span, ty: Type::Unresolved } });
        self.record_reg(span, reg)
    }

    fn lower_expr(&mut self, expr: &Expr, cur: &mut BlockId) -> Reg {
        match expr {
            Expr::IntLit { span, .. }
            | Expr::FloatLit { span, .. }
            | Expr::BoolLit { span, .. }
            | Expr::NullLit { span }
            | Expr::CharLit { span, .. } => self.emit_eval(*cur, *span),

            Expr::StringTemplate { parts, span } => {
                for p in parts {
                    if let StringPart::Interp(e) = p {
                        let _ = self.lower_expr(e, cur);
                    }
                }
                self.emit_eval(*cur, *span)
            }

            Expr::Path { span, .. }
            | Expr::This { span, .. }
            | Expr::Super { span, .. }
            | Expr::PropertyRef { span, .. } => {
                let reg = self.emit_eval(*cur, *span);
                if let Some(place) = self.expr_to_place(expr) {
                    self.reg_to_place.insert(reg, place);
                }
                reg
            }

            Expr::Member { receiver, span, .. } => {
                let _ = self.lower_expr(receiver, cur);
                let reg = self.emit_eval(*cur, *span);
                if let Some(place) = self.expr_to_place(expr) {
                    self.reg_to_place.insert(reg, place);
                }
                reg
            }
            Expr::MemberRef { receiver, span, .. } => {
                let _ = self.lower_expr(receiver, cur);
                self.emit_eval(*cur, *span)
            }

            Expr::Call { callee, args, span, .. } => {
                // Spec §12.2.5 callsInPlace(EXACTLY_ONCE): if the
                // callee is one of the stdlib scope functions and
                // the last argument is a lambda literal, inline the
                // lambda body into the current block before any
                // contract effects so subsequent statements see the
                // body's assignments and narrowings.
                let exactly_once = lambda_calls_in_place(callee, args);
                let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len());
                let _ = self.lower_expr(callee, cur);
                if exactly_once {
                    // Lower all non-lambda args normally; the trailing
                    // lambda body is inlined directly into `cur`.
                    let lambda_idx = args.len() - 1;
                    for (i, a) in args.iter().enumerate() {
                        if i == lambda_idx {
                            break;
                        }
                        arg_regs.push(self.lower_expr(a, cur));
                    }
                    if let Expr::Lambda { body, .. } = &args[lambda_idx] {
                        let _ = self.lower_block(body, cur);
                    }
                    let result = self.emit_eval(*cur, *span);
                    self.apply_contract_effects(callee, &arg_regs, args, *cur, *span);
                    result
                } else {
                    for a in args {
                        arg_regs.push(self.lower_expr(a, cur));
                    }
                    let result = self.emit_eval(*cur, *span);
                    self.apply_contract_effects(callee, &arg_regs, args, *cur, *span);
                    result
                }
            }
            Expr::Index { receiver, args, span } => {
                let _ = self.lower_expr(receiver, cur);
                for a in args {
                    let _ = self.lower_expr(a, cur);
                }
                self.emit_eval(*cur, *span)
            }
            Expr::Spread { expr, span } => {
                let _ = self.lower_expr(expr, cur);
                self.emit_eval(*cur, *span)
            }

            Expr::Binary { op, lhs, rhs, span } => self.lower_binary(*op, lhs, rhs, *span, cur),

            Expr::Unary { op, expr, span } => {
                let inner = self.lower_expr(expr, cur);
                if matches!(op, UnOp::PreInc | UnOp::PreDec)
                    && let Some(place) = self.expr_to_place(expr) {
                        self.b.push(*cur, Node::Assign { lhs: place, rhs: inner, span: *span });
                    }
                let result = self.emit_eval(*cur, *span);
                if matches!(op, UnOp::Not)
                    && let Some(r) = self.pending_refinements.get(&inner).cloned() {
                        self.pending_refinements
                            .insert(result, Refinement::Not(Box::new(r)));
                    }
                result
            }

            Expr::Postfix { op, expr, span } => match op {
                PostfixOp::Inc | PostfixOp::Dec => {
                    let r = self.lower_expr(expr, cur);
                    if let Some(place) = self.expr_to_place(expr) {
                        self.b.push(*cur, Node::Assign { lhs: place, rhs: r, span: *span });
                    }
                    self.emit_eval(*cur, *span)
                }
                PostfixOp::NotNull => {
                    let r = self.lower_expr(expr, cur);
                    self.b.push(
                        *cur,
                        Node::AssumeNull { reg: r, eq_null: false, span: *span },
                    );
                    self.b.push(*cur, Node::Assert { reg: r, span: *span });
                    r
                }
            },

            Expr::If { cond, then_branch, else_branch, span } => {
                self.lower_if(cond, then_branch, else_branch.as_deref(), *span, cur)
            }

            Expr::When { subject, branches, span, .. } => {
                self.lower_when(subject.as_deref(), branches, *span, cur)
            }

            Expr::While { cond, body, span } => self.lower_while(cond, body, *span, cur),
            Expr::DoWhile { body, cond, span } => {
                self.lower_do_while(body.as_deref(), cond, *span, cur)
            }
            Expr::For { iter, body, span, .. } => self.lower_for(iter, body, *span, cur),

            Expr::Return { value, label, span } => {
                let r = value.as_ref().map(|v| self.lower_expr(v, cur));
                let target = self.return_target(label.as_ref());
                if let Some(reg) = r {
                    self.label_set_result(label.as_ref(), reg);
                }
                self.b.set_terminator(*cur, Terminator::Goto(target));
                *cur = self.fresh_dead_block();
                self.emit_eval(*cur, *span)
            }
            Expr::Break { label, span } => {
                let target = self.break_target(label.as_ref());
                self.b.set_terminator(*cur, Terminator::Goto(target));
                *cur = self.fresh_dead_block();
                self.emit_eval(*cur, *span)
            }
            Expr::Continue { label, span } => {
                let target = self.continue_target(label.as_ref());
                self.b.set_terminator(*cur, Terminator::Goto(target));
                *cur = self.fresh_dead_block();
                self.emit_eval(*cur, *span)
            }
            Expr::Throw { value, span } => {
                let r = self.lower_expr(value, cur);
                self.route_throw(*cur, r);
                *cur = self.fresh_dead_block();
                self.emit_eval(*cur, *span)
            }

            Expr::Labeled { label, expr, .. } => {
                let target = self.b.new_block();
                let label_id = self.b.new_label();
                self.b.push(target, Node::LabelMark { label: label_id });
                self.label_stack.push(LabelFrame {
                    name: label.name.clone(),
                    target,
                    result: None,
                });
                let r = self.lower_expr(expr, cur);
                self.b.set_terminator(*cur, Terminator::Goto(target));
                let frame = self.label_stack.pop().unwrap();
                *cur = target;
                frame.result.unwrap_or(r)
            }

            Expr::Block(b) => self
                .lower_block(b, cur)
                .unwrap_or_else(|| self.emit_eval(*cur, b.span)),

            Expr::Try { body, catches, finally, span } => {
                self.lower_try(body, catches, finally.as_ref(), *span, cur)
            }

            Expr::Lambda { body, span, .. } => {
                let _ = body;
                self.emit_eval(*cur, *span)
            }
            Expr::AnonFun { span, .. } => self.emit_eval(*cur, *span),
            Expr::ObjectExpr { span, .. } => self.emit_eval(*cur, *span),

            Expr::IsCheck { expr, ty, negated, span } => {
                let r = self.lower_expr(expr, cur);
                let result = self.b.new_reg();
                self.b.push(
                    *cur,
                    Node::Eval { reg: result, expr: ExprRef { span: *span, ty: Type::Boolean } },
                );
                let ty_t = klio_types::convert_type_ref_lossy(ty);
                let class_name = if klio_types::builtin_by_name(&ty.name.name).is_none() {
                    Some(ty.name.name.clone())
                } else {
                    None
                };
                self.pending_refinements.insert(
                    result,
                    Refinement::Is {
                        reg: r,
                        ty: ty_t,
                        class_name,
                        polarity: !*negated,
                        span: *span,
                    },
                );
                self.record_reg(*span, result)
            }
            Expr::As { expr, ty, safe, span } => {
                let r = self.lower_expr(expr, cur);
                let ty_t = klio_types::convert_type_ref_lossy(ty);
                let class_name = if klio_types::builtin_by_name(&ty.name.name).is_none() {
                    Some(ty.name.name.clone())
                } else {
                    None
                };
                if !*safe {
                    self.b.push(
                        *cur,
                        Node::AssumeIs {
                            reg: r,
                            ty: ty_t,
                            class_name,
                            polarity: true,
                            span: *span,
                        },
                    );
                    self.b.push(*cur, Node::Assert { reg: r, span: *span });
                }
                self.emit_eval(*cur, *span)
            }
        }
    }

    fn lower_binary(
        &mut self,
        op: BinOp,
        lhs: &Expr,
        rhs: &Expr,
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        match op {
            BinOp::And => self.lower_short_circuit(lhs, rhs, span, cur, /*short_on_false=*/ true),
            BinOp::Or => self.lower_short_circuit(lhs, rhs, span, cur, /*short_on_false=*/ false),
            BinOp::Elvis => self.lower_elvis(lhs, rhs, span, cur),
            BinOp::Eq | BinOp::Neq | BinOp::IdentEq | BinOp::IdentNeq => {
                let l = self.lower_expr(lhs, cur);
                let r = self.lower_expr(rhs, cur);
                let result = self.emit_eval(*cur, span);
                let eq_op = matches!(op, BinOp::Eq | BinOp::IdentEq);
                if is_null_lit(rhs) {
                    self.pending_refinements.insert(
                        result,
                        Refinement::NullEq { reg: l, span, eq_null: eq_op },
                    );
                } else if is_null_lit(lhs) {
                    self.pending_refinements.insert(
                        result,
                        Refinement::NullEq { reg: r, span, eq_null: eq_op },
                    );
                } else if self.reg_to_place.contains_key(&l)
                    && self.reg_to_place.contains_key(&r)
                {
                    // Cross-variable reference equality on two
                    // place expressions. Negation flips at branch
                    // emission time via `emit_refinement(truth=...)`.
                    let refinement = Refinement::RefEq { reg_a: l, reg_b: r, span };
                    let wrapped = if eq_op {
                        refinement
                    } else {
                        Refinement::Not(Box::new(refinement))
                    };
                    self.pending_refinements.insert(result, wrapped);
                }
                result
            }
            _ => {
                let _ = self.lower_expr(lhs, cur);
                let _ = self.lower_expr(rhs, cur);
                self.emit_eval(*cur, span)
            }
        }
    }

    /// `a && b` => evaluate `a`; if true, evaluate `b`; result is the
    /// boolean of the joined block. `a || b` is symmetric.
    fn lower_short_circuit(
        &mut self,
        lhs: &Expr,
        rhs: &Expr,
        span: Span,
        cur: &mut BlockId,
        short_on_false: bool,
    ) -> Reg {
        let l = self.lower_expr(lhs, cur);
        let lhs_refinement = self.pending_refinements.get(&l).cloned();
        let rhs_blk = self.b.new_block();
        let join = self.b.new_block();
        let (then_blk, else_blk) = if short_on_false { (rhs_blk, join) } else { (join, rhs_blk) };
        self.b.set_terminator(*cur, Terminator::Branch { cond: l, then_blk, else_blk });
        self.b.push(
            rhs_blk,
            Node::Assume { reg: l, polarity: short_on_false },
        );
        if let Some(r) = &lhs_refinement {
            // On the rhs-eval block, lhs's truth-polarity matches
            // `short_on_false` (for `&&` we evaluate rhs when lhs is
            // true; for `||` when lhs is false).
            self.emit_refinement(rhs_blk, r, short_on_false);
        }
        let mut rhs_cur = rhs_blk;
        let r_reg = self.lower_expr(rhs, &mut rhs_cur);
        let rhs_refinement = self.pending_refinements.get(&r_reg).cloned();
        self.b.set_terminator(rhs_cur, Terminator::Goto(join));
        self.b.push(
            join,
            Node::Assume { reg: l, polarity: !short_on_false },
        );
        let combined = match (lhs_refinement, rhs_refinement) {
            (Some(a), Some(b)) => Some(if short_on_false {
                Refinement::And(vec![a, b])
            } else {
                Refinement::Or(vec![a, b])
            }),
            (Some(a), None) | (None, Some(a)) => Some(a),
            (None, None) => None,
        };
        *cur = join;
        let result = self.emit_eval(*cur, span);
        if let Some(r) = combined {
            self.pending_refinements.insert(result, r);
        }
        result
    }

    /// `a ?: b` => evaluate `a`; if non-null, that's the result; if
    /// null, evaluate `b`. Lowered as a null-check branch.
    fn lower_elvis(
        &mut self,
        lhs: &Expr,
        rhs: &Expr,
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        let l = self.lower_expr(lhs, cur);
        let null_blk = self.b.new_block();
        let nonnull_blk = self.b.new_block();
        let join = self.b.new_block();
        self.b
            .set_terminator(*cur, Terminator::Branch { cond: l, then_blk: nonnull_blk, else_blk: null_blk });
        self.b.push(
            null_blk,
            Node::AssumeNull { reg: l, eq_null: true, span },
        );
        let mut null_cur = null_blk;
        let _ = self.lower_expr(rhs, &mut null_cur);
        self.b.set_terminator(null_cur, Terminator::Goto(join));
        self.b.push(
            nonnull_blk,
            Node::AssumeNull { reg: l, eq_null: false, span },
        );
        self.b.set_terminator(nonnull_blk, Terminator::Goto(join));
        *cur = join;
        self.emit_eval(*cur, span)
    }

    fn lower_if(
        &mut self,
        cond: &Expr,
        then_branch: &Expr,
        else_branch: Option<&Expr>,
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        let c = self.lower_expr(cond, cur);
        let refinement = self.pending_refinements.get(&c).cloned();
        let then_blk = self.b.new_block();
        let else_blk = self.b.new_block();
        let join = self.b.new_block();
        self.b.set_terminator(*cur, Terminator::Branch { cond: c, then_blk, else_blk });

        self.b.push(then_blk, Node::Assume { reg: c, polarity: true });
        if let Some(r) = &refinement {
            self.emit_refinement(then_blk, r, true);
        }
        let mut then_cur = then_blk;
        let _ = self.lower_expr(then_branch, &mut then_cur);
        self.b.set_terminator(then_cur, Terminator::Goto(join));

        self.b.push(else_blk, Node::Assume { reg: c, polarity: false });
        if let Some(r) = &refinement {
            self.emit_refinement(else_blk, r, false);
        }
        let mut else_cur = else_blk;
        if let Some(e) = else_branch {
            let _ = self.lower_expr(e, &mut else_cur);
        }
        self.b.set_terminator(else_cur, Terminator::Goto(join));

        *cur = join;
        self.emit_eval(*cur, span)
    }

    fn lower_when(
        &mut self,
        subject: Option<&Expr>,
        branches: &[WhenBranch],
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        let subj_reg = subject.map(|s| self.lower_expr(s, cur));
        let join = self.b.new_block();

        let mut next = self.b.new_block();
        self.b.set_terminator(*cur, Terminator::Goto(next));

        for branch in branches {
            let arm_body = self.b.new_block();
            let fall = self.b.new_block();
            for (i, pat) in branch.patterns.iter().enumerate() {
                let last = i + 1 == branch.patterns.len();
                let try_next = if last { fall } else { self.b.new_block() };
                self.lower_when_pattern(&pat.kind, subj_reg, next, arm_body, try_next);
                next = try_next;
            }
            let mut arm_cur = arm_body;
            let _ = self.lower_expr(&branch.body, &mut arm_cur);
            self.b.set_terminator(arm_cur, Terminator::Goto(join));
            next = fall;
        }
        // No-arm-matched fallthrough flows to the join; spec §8.10 says
        // a subject-bound `when` without `else` throws at runtime — that
        // detail is handled by the typechecker/interpreter, not CFG.
        self.b.set_terminator(next, Terminator::Goto(join));
        *cur = join;
        self.emit_eval(*cur, span)
    }

    /// Lower a single `when` pattern: evaluate it against `subj` if
    /// `subj.is_some()` else as a boolean condition; on match branch
    /// to `match_blk`, on miss branch to `miss_blk`.
    fn lower_when_pattern(
        &mut self,
        kind: &WhenPatternKind,
        subj: Option<Reg>,
        before: BlockId,
        match_blk: BlockId,
        miss_blk: BlockId,
    ) {
        let mut cur = before;
        match kind {
            WhenPatternKind::Value(e) => {
                let v = self.lower_expr(e, &mut cur);
                if let Some(s) = subj {
                    let cmp = self.b.new_reg();
                    self.b.push(
                        cur,
                        Node::Eval {
                            reg: cmp,
                            expr: ExprRef { span: e.span(), ty: Type::Boolean },
                        },
                    );
                    let _ = s;
                    self.b.set_terminator(
                        cur,
                        Terminator::Branch { cond: cmp, then_blk: match_blk, else_blk: miss_blk },
                    );
                } else {
                    self.b.set_terminator(
                        cur,
                        Terminator::Branch { cond: v, then_blk: match_blk, else_blk: miss_blk },
                    );
                }
            }
            WhenPatternKind::InRange(e) | WhenPatternKind::NotInRange(e) => {
                let _ = self.lower_expr(e, &mut cur);
                let cmp = self.b.new_reg();
                self.b.push(
                    cur,
                    Node::Eval { reg: cmp, expr: ExprRef { span: e.span(), ty: Type::Boolean } },
                );
                self.b.set_terminator(
                    cur,
                    Terminator::Branch { cond: cmp, then_blk: match_blk, else_blk: miss_blk },
                );
            }
            WhenPatternKind::IsType(ty) | WhenPatternKind::NotIsType(ty) => {
                let negated = matches!(kind, WhenPatternKind::NotIsType(_));
                let polarity = !negated;
                let cmp = self.b.new_reg();
                let ty_t = klio_types::convert_type_ref_lossy(ty);
                let class_name = if klio_types::builtin_by_name(&ty.name.name).is_none() {
                    Some(ty.name.name.clone())
                } else {
                    None
                };
                if let Some(s) = subj {
                    self.b.push(
                        cur,
                        Node::AssumeIs {
                            reg: s,
                            ty: ty_t.clone(),
                            class_name,
                            polarity,
                            span: ty.span,
                        },
                    );
                    self.b.push(
                        cur,
                        Node::Eval { reg: cmp, expr: ExprRef { span: ty.span, ty: Type::Boolean } },
                    );
                    let arms = vec![SwitchArm {
                        pattern: Pattern::Is { ty: ty_t, polarity },
                        target: match_blk,
                    }];
                    self.b.set_terminator(cur, Terminator::Switch { reg: s, arms, default: miss_blk });
                } else {
                    self.b.set_terminator(
                        cur,
                        Terminator::Branch { cond: cmp, then_blk: match_blk, else_blk: miss_blk },
                    );
                }
            }
            WhenPatternKind::Else => {
                self.b.set_terminator(cur, Terminator::Goto(match_blk));
            }
        }
    }

    fn lower_while(&mut self, cond: &Expr, body: &Expr, span: Span, cur: &mut BlockId) -> Reg {
        let head = self.b.new_block();
        let body_blk = self.b.new_block();
        let exit = self.b.new_block();
        let lid = self.b.new_loop();

        self.b.set_terminator(*cur, Terminator::Goto(head));

        let c = {
            let mut head_cur = head;
            let r = self.lower_expr(cond, &mut head_cur);
            self.b.set_terminator(
                head_cur,
                Terminator::Branch { cond: r, then_blk: body_blk, else_blk: exit },
            );
            r
        };

        self.b.push(body_blk, Node::Assume { reg: c, polarity: true });
        self.loop_stack.push(LoopFrame {
            id: lid,
            cont_target: head,
            break_target: exit,
            label: None,
        });
        let mut body_cur = body_blk;
        let _ = self.lower_expr(body, &mut body_cur);
        self.b.push(body_cur, Node::Backedge { loop_id: lid });
        self.b.set_terminator(body_cur, Terminator::Goto(head));
        self.loop_stack.pop();

        self.b.push(exit, Node::Assume { reg: c, polarity: false });
        *cur = exit;
        self.emit_eval(*cur, span)
    }

    fn lower_do_while(
        &mut self,
        body: Option<&Expr>,
        cond: &Expr,
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        let head = self.b.new_block();
        let cond_blk = self.b.new_block();
        let exit = self.b.new_block();
        let lid = self.b.new_loop();

        self.b.set_terminator(*cur, Terminator::Goto(head));
        self.loop_stack.push(LoopFrame {
            id: lid,
            cont_target: cond_blk,
            break_target: exit,
            label: None,
        });
        let mut head_cur = head;
        if let Some(b) = body {
            let _ = self.lower_expr(b, &mut head_cur);
        }
        self.b.set_terminator(head_cur, Terminator::Goto(cond_blk));
        self.loop_stack.pop();

        let mut cond_cur = cond_blk;
        let r = self.lower_expr(cond, &mut cond_cur);
        self.b.push(cond_cur, Node::Backedge { loop_id: lid });
        self.b
            .set_terminator(cond_cur, Terminator::Branch { cond: r, then_blk: head, else_blk: exit });

        self.b.push(exit, Node::Assume { reg: r, polarity: false });
        *cur = exit;
        self.emit_eval(*cur, span)
    }

    fn lower_for(&mut self, iter: &Expr, body: &Expr, span: Span, cur: &mut BlockId) -> Reg {
        // Spec §7.2.4: `for (x in xs) body` desugars to an iterator while
        // loop. The lowering here is conservative — we evaluate `xs`,
        // then loop body up to an indeterminate count. Reachability and
        // killDataFlow only need a backedge and the standard loop shape.
        let _ = self.lower_expr(iter, cur);
        let head = self.b.new_block();
        let body_blk = self.b.new_block();
        let exit = self.b.new_block();
        let lid = self.b.new_loop();
        self.b.set_terminator(*cur, Terminator::Goto(head));
        let cond = self.b.new_reg();
        self.b.push(
            head,
            Node::Eval { reg: cond, expr: ExprRef { span, ty: Type::Boolean } },
        );
        self.b
            .set_terminator(head, Terminator::Branch { cond, then_blk: body_blk, else_blk: exit });
        self.loop_stack.push(LoopFrame {
            id: lid,
            cont_target: head,
            break_target: exit,
            label: None,
        });
        let mut body_cur = body_blk;
        let _ = self.lower_expr(body, &mut body_cur);
        self.b.push(body_cur, Node::Backedge { loop_id: lid });
        self.b.set_terminator(body_cur, Terminator::Goto(head));
        self.loop_stack.pop();
        *cur = exit;
        self.emit_eval(*cur, span)
    }

    fn lower_try(
        &mut self,
        body: &Block,
        catches: &[Catch],
        finally: Option<&Block>,
        span: Span,
        cur: &mut BlockId,
    ) -> Reg {
        let handlers_entry: Vec<(Option<Type>, BlockId)> = catches
            .iter()
            .map(|c| {
                let blk = self.b.new_block();
                (Some(klio_types::convert_type_ref_lossy(&c.ty)), blk)
            })
            .collect();

        let join = self.b.new_block();
        let finally_entry_blk = finally.map(|_| self.b.new_block());
        let normal_finally_blk = finally.map(|_| self.b.new_block());

        self.try_stack.push(TryFrame {
            handlers: handlers_entry.clone(),
            finally_entry: finally_entry_blk,
        });

        // Body
        let body_blk = self.b.new_block();
        self.b.set_terminator(*cur, Terminator::Goto(body_blk));
        let mut body_cur = body_blk;
        let _ = self.lower_block(body, &mut body_cur);
        let body_exit_to = normal_finally_blk.unwrap_or(join);
        self.b.set_terminator(body_cur, Terminator::Goto(body_exit_to));
        // Exception edges from every node in the body to each handler.
        for (ty, h) in &handlers_entry {
            self.b
                .add_edge(body_blk, *h, EdgeKind::Exception { ty: ty.clone() });
        }

        // Handlers: each catch body lowers like a block; its normal exit
        // flows into the finally (if any) and then to the join.
        for (catch, (_, h_entry)) in catches.iter().zip(handlers_entry.iter()) {
            let mut h_cur = *h_entry;
            let _ = self.lower_block(&catch.body, &mut h_cur);
            let h_exit_to = normal_finally_blk.unwrap_or(join);
            self.b.set_terminator(h_cur, Terminator::Goto(h_exit_to));
        }

        self.try_stack.pop();

        // Finally has two copies per spec §12.1.1: one for the normal
        // exit and one (currently shared) for each exception path. The
        // normal-exit copy is emitted explicitly; the exception-path
        // copy lives at `finally_entry_blk` and is reached from any
        // uncaught throw via the try-stack walk.
        if let (Some(fin), Some(normal_fin), Some(throw_fin)) =
            (finally, normal_finally_blk, finally_entry_blk)
        {
            let mut nf_cur = normal_fin;
            let _ = self.lower_block(fin, &mut nf_cur);
            self.b.set_terminator(nf_cur, Terminator::Goto(join));
            self.b.add_edge(nf_cur, join, EdgeKind::FinallyExit);

            let mut tf_cur = throw_fin;
            let _ = self.lower_block(fin, &mut tf_cur);
            // Exception-path finally re-throws into the enclosing try
            // (or, if none, leaves the function). For now we wire it
            // to `join` and let reachability prune it later when we
            // have type info.
            self.b.set_terminator(tf_cur, Terminator::Goto(join));
            self.b.add_edge(tf_cur, join, EdgeKind::FinallyExit);
        }

        *cur = join;
        self.emit_eval(*cur, span)
    }

    fn route_throw(&mut self, from: BlockId, reg: Reg) {
        // Wire the throw terminator on `from`; the topmost try frame's
        // handlers get exception edges.
        self.b.set_terminator(from, Terminator::Throw(reg));
        if let Some(frame) = self.try_stack.last() {
            let handlers = frame.handlers.clone();
            let finally_entry = frame.finally_entry;
            for (ty, h) in &handlers {
                self.b.add_edge(from, *h, EdgeKind::Exception { ty: ty.clone() });
            }
            if let Some(fe) = finally_entry {
                self.b.add_edge(from, fe, EdgeKind::FinallyEntry);
            }
        }
    }

    fn return_target(&self, label: Option<&Ident>) -> BlockId {
        match label {
            Some(name) => self
                .label_stack
                .iter()
                .rev()
                .find(|f| f.name == name.name).map_or_else(|| self.fn_target(), |f| f.target),
            None => self.fn_target(),
        }
    }

    fn fn_target(&self) -> BlockId {
        // The function frame is always the bottom-most label frame.
        self.label_stack
            .first()
            .map(|f| f.target)
            .expect("function lowering must push a synthetic label")
    }

    fn break_target(&self, label: Option<&Ident>) -> BlockId {
        match label {
            Some(name) => self
                .loop_stack
                .iter()
                .rev()
                .find(|f| f.label.as_deref() == Some(&name.name))
                .map(|f| f.break_target)
                .or_else(|| self.loop_stack.last().map(|f| f.break_target))
                .expect("break outside of a loop"),
            None => self
                .loop_stack
                .last()
                .map(|f| f.break_target)
                .expect("break outside of a loop"),
        }
    }

    fn continue_target(&self, label: Option<&Ident>) -> BlockId {
        match label {
            Some(name) => self
                .loop_stack
                .iter()
                .rev()
                .find(|f| f.label.as_deref() == Some(&name.name))
                .map(|f| f.cont_target)
                .or_else(|| self.loop_stack.last().map(|f| f.cont_target))
                .expect("continue outside of a loop"),
            None => self
                .loop_stack
                .last()
                .map(|f| f.cont_target)
                .expect("continue outside of a loop"),
        }
    }

    fn label_set_result(&mut self, label: Option<&Ident>, reg: Reg) {
        if let Some(name) = label
            && let Some(frame) = self
                .label_stack
                .iter_mut()
                .rev()
                .find(|f| f.name == name.name)
            {
                frame.result = Some(reg);
            }
    }
}

impl Default for Lowering {
    fn default() -> Self {
        Self::new()
    }
}

fn is_null_lit(e: &Expr) -> bool {
    matches!(e, Expr::NullLit { .. })
}

fn simple_name(callee: &Expr) -> Option<&str> {
    match callee {
        Expr::Path { segments, .. } if segments.len() == 1 => Some(&segments[0].name),
        _ => None,
    }
}

/// True when `callee` is a stdlib scope function whose contract
/// invokes the trailing lambda argument exactly once on the normal
/// path. Per spec §12.2.5 the body's effects (assignments,
/// narrowings, declarations) propagate to the caller scope and the
/// CFG should inline them inline so VIA and smart-cast see them
/// without crossing a lambda boundary.
fn lambda_calls_in_place(callee: &Expr, args: &[Expr]) -> bool {
    let Some(last) = args.last() else { return false };
    if !matches!(last, Expr::Lambda { .. }) {
        return false;
    }
    match callee {
        // `recv.let/run/apply/also { ... }` — member-form. `with` is
        // top-level but takes a receiver as a positional argument.
        Expr::Member { name, safe: false, .. } => matches!(
            name.name.as_str(),
            "let" | "run" | "apply" | "also"
        ),
        Expr::Path { segments, .. } if segments.len() == 1 => {
            let name = segments[0].name.as_str();
            // `run { ... }` / `with(x) { ... }` — top-level scope fns.
            if matches!(name, "run" | "with") {
                return true;
            }
            // User-declared `contract { callsInPlace(block,
            // EXACTLY_ONCE) }`: if the registry records the
            // trailing-arg position as exactly-once, treat the
            // call like a scope function so the lambda body's
            // assignments / smart-casts flow to the caller scope.
            // Positional check by the trailing arg's name in the
            // candidate user fn's contract list — sufficient for
            // the EXACTLY_ONCE shape since the inlining only
            // needs to identify the lambda arg, not the exact
            // declared param.
            let user_params = crate::analyses::contracts::user_exactly_once_params(name);
            !user_params.is_empty()
        }
        _ => false,
    }
}

impl Lowering {
    /// Apply spec §12.2.5 contract effects to the post-call block.
    /// The effect catalogue lives in
    /// [`crate::analyses::contracts::stdlib_contract`]; the lowering
    /// just translates each `ContractEffect` into the corresponding
    /// `Assume*` node and replays any pending refinement on the
    /// predicate register.
    fn apply_contract_effects(
        &mut self,
        callee: &Expr,
        arg_regs: &[Reg],
        args: &[Expr],
        cur: BlockId,
        span: Span,
    ) {
        use crate::analyses::contracts::{stdlib_contract, ContractEffect};
        let Some(name) = simple_name(callee) else { return };
        for effect in stdlib_contract(name) {
            match effect {
                ContractEffect::AssumeNonNull { arg_idx } => {
                    if let (Some(r), Some(_)) = (arg_regs.get(*arg_idx), args.get(*arg_idx)) {
                        self.b.push(
                            cur,
                            Node::AssumeNull { reg: *r, eq_null: false, span },
                        );
                    }
                }
                ContractEffect::AssumePredicate { arg_idx } => {
                    if let (Some(r), Some(_)) = (arg_regs.get(*arg_idx), args.get(*arg_idx)) {
                        self.b.push(cur, Node::Assume { reg: *r, polarity: true });
                        if let Some(refinement) = self.pending_refinements.get(r).cloned() {
                            self.emit_refinement(cur, &refinement, true);
                        }
                    }
                }
            }
        }
    }
}

/// Convenience entry point: lower a function body into a CFG.
#[must_use] 
pub fn lower_function(body: &Block, source: Span) -> Lowered {
    Lowering::new().lower_function(body, source)
}
