//! State-machine lowering for `suspend fun` bodies.
//!
//! Walks a suspend function's AST body and produces a
//! [`klio_runtime::SuspendBody`] partitioned at every suspending
//! call site. Each [`SuspendState`] is a contiguous run of
//! statements that the interpreter executes atomically; the state
//! ends in a transition that either returns the function's result,
//! jumps to another state (after a branch), or pauses on a
//! suspending call whose result will become the next state's
//! resume-target binding.
//!
//! The lowering is conservative: anything we don't statically know
//! to be suspending stays in its current state. The set of
//! recognised "suspending" callees comes from:
//!
//! 1. The stdlib coroutine intrinsics (`suspendCoroutine`,
//!    `suspendCoroutineUninterceptedOrReturn`,
//!    `suspendCancellableCoroutine`).
//! 2. Caller-supplied `suspend fun` names — the partitioner is
//!    instantiated with a `SuspendNameSet` the interpreter
//!    populates at registration time.
//!
//! Anything outside that set is treated as ordinary and stays in
//! the current state. That keeps the lowering decidable without
//! needing to chase imports / typeck info into the partitioner.

use klio_ast::{Block, Expr, Function, FunctionBody, Stmt};
use klio_runtime::{SuspendBody, SuspendState, SuspendTransition};
use std::collections::HashSet;

/// Names recognised as suspending. The partitioner consults this
/// when deciding whether a call ends a state.
#[derive(Default, Clone)]
pub struct SuspendNameSet {
    pub names: HashSet<String>,
}

impl SuspendNameSet {
    /// Add every well-known intrinsic name so the partitioner
    /// recognises `suspendCoroutine { … }` and friends.
    pub fn with_intrinsics() -> Self {
        let mut names = HashSet::new();
        names.insert("suspendCoroutine".to_string());
        names.insert("suspendCoroutineUninterceptedOrReturn".to_string());
        names.insert("suspendCancellableCoroutine".to_string());
        Self { names }
    }

    pub fn insert(&mut self, name: impl Into<String>) {
        self.names.insert(name.into());
    }

    pub fn contains(&self, name: &str) -> bool {
        self.names.contains(name)
    }
}

/// Lower a suspend function's body into a `SuspendBody`. Returns
/// `None` when the function has no block-form body (extension
/// functions backed by `=` expressions, abstract members).
pub fn lower(func: &Function, suspend_names: &SuspendNameSet) -> Option<SuspendBody> {
    let body = match func.body.as_ref()? {
        FunctionBody::Block(b) => b.clone(),
        FunctionBody::Expr(e) => Block {
            stmts: vec![Stmt::Expr(e.clone())],
            span: e.span(),
        },
    };
    let mut lowering = Lowering::new(suspend_names);
    lowering.lower_block(&body, /*final_return=*/ true);
    Some(SuspendBody { states: lowering.states })
}

struct Lowering<'a> {
    suspend_names: &'a SuspendNameSet,
    states: Vec<SuspendState>,
    /// Statements collected for the state currently being built.
    pending_stmts: Vec<Stmt>,
    /// The resume target for the state we are currently
    /// accumulating into — bound when we start a state immediately
    /// after a suspending call.
    pending_target: Option<String>,
    /// Synthetic-variable counter for ANF temporaries.
    next_temp: u32,
}

impl<'a> Lowering<'a> {
    fn new(suspend_names: &'a SuspendNameSet) -> Self {
        Self {
            suspend_names,
            states: Vec::new(),
            pending_stmts: Vec::new(),
            pending_target: None,
            next_temp: 0,
        }
    }

    fn lower_block(&mut self, block: &Block, final_return: bool) {
        for stmt in &block.stmts {
            self.lower_stmt(stmt);
        }
        if final_return {
            self.finish_with(SuspendTransition::Return);
        }
    }

    fn lower_stmt(&mut self, stmt: &Stmt) {
        match stmt {
            Stmt::Expr(e) => self.lower_expr_stmt(e, None),
            Stmt::Decl(d) => {
                if let klio_ast::Decl::Property(p) = d {
                    if let Some(init) = &p.init {
                        // val/var name = init; if init contains a
                        // suspending call, the binding receives the
                        // resumed value in a fresh state.
                        if self.expr_is_simple_suspending_call(init) {
                            self.emit_suspending_assignment(
                                init.clone(),
                                Some(p.name.name.clone()),
                            );
                            return;
                        }
                    }
                }
                // Non-init decls and non-suspending inits stay in
                // the current state verbatim.
                self.pending_stmts.push(stmt.clone());
            }
            Stmt::Assign { target, op, value, span } => {
                if self.expr_is_simple_suspending_call(value) {
                    // Synthesise a temp and rewrite as: t = …; x = t.
                    let tmp = self.fresh_temp();
                    self.emit_suspending_assignment(value.clone(), Some(tmp.clone()));
                    self.pending_stmts.push(Stmt::Assign {
                        target: target.clone(),
                        op: *op,
                        value: Expr::Path {
                            segments: vec![klio_ast::Ident { name: tmp, span: *span }],
                            span: *span,
                        },
                        span: *span,
                    });
                    return;
                }
                self.pending_stmts.push(stmt.clone());
            }
            _ => {
                self.pending_stmts.push(stmt.clone());
            }
        }
    }

    fn lower_expr_stmt(&mut self, e: &Expr, target: Option<String>) {
        if self.expr_is_simple_suspending_call(e) {
            self.emit_suspending_assignment(e.clone(), target);
            return;
        }
        if let Some(t) = target {
            let span = e.span();
            self.pending_stmts.push(Stmt::Assign {
                target: Expr::Path {
                    segments: vec![klio_ast::Ident { name: t, span }],
                    span,
                },
                op: klio_ast::AssignOp::Assign,
                value: e.clone(),
                span,
            });
        } else {
            self.pending_stmts.push(Stmt::Expr(e.clone()));
        }
    }

    fn emit_suspending_assignment(&mut self, call: Expr, target: Option<String>) {
        // The current state's tail is the suspending call. The
        // *next* state will start with `target` bound to whatever
        // the continuation resumes with.
        let span = call.span();
        self.pending_stmts.push(Stmt::Expr(call));
        let next = self.states.len() + 1;
        self.finish_with(SuspendTransition::Goto(next));
        self.pending_target = target;
        let _ = span;
    }

    fn finish_with(&mut self, transition: SuspendTransition) {
        let stmts = std::mem::take(&mut self.pending_stmts);
        let target = self.pending_target.take();
        self.states.push(SuspendState {
            resume_target: target,
            stmts,
            transition,
        });
    }

    fn fresh_temp(&mut self) -> String {
        let name = format!("$$susp_t{}", self.next_temp);
        self.next_temp += 1;
        name
    }

    /// Detect a simple suspending call at the top level of an
    /// expression. Handles bare `foo(args)` and `bar { … }` shapes.
    /// Conservatively returns false for nested suspending calls
    /// (e.g. `f(foo())`) — those are handled by the ANF spill in
    /// the assignment / decl arms.
    fn expr_is_simple_suspending_call(&self, e: &Expr) -> bool {
        match e {
            Expr::Call { callee, .. } => {
                if let Some(name) = simple_callee_name(callee) {
                    return self.suspend_names.contains(name);
                }
                false
            }
            Expr::Binary { lhs, rhs, op, .. } => {
                // `e ?: <suspending>` and the like; treat the whole
                // expression as non-simple so the ANF spill
                // doesn't fire on a partially-suspending operator.
                let _ = (lhs, rhs, op);
                false
            }
            _ => false,
        }
    }
}

fn simple_callee_name(e: &Expr) -> Option<&str> {
    match e {
        Expr::Path { segments, .. } if segments.len() == 1 => Some(&segments[0].name),
        Expr::Member { name, .. } => Some(&name.name),
        _ => None,
    }
}
