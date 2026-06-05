use super::{
    AstBinOp, AstBlock, AstUnOp, BinOp, BlockId, Const, Expr, Func, FuncBuilder, FuncId, Inst, Reg,
    Stmt, Terminator, UnOp, arg_lambda_has_nonlocal_return, ast_binop, boxed_cell_reg,
    callee_label, collect_dotted_fqn, collect_path_idents, collect_path_idents_stmt, expr_span,
    inline_fn_ast, inline_fn_ast_for, intern_arg_names, intern_type_args, is_any_typed_path,
    is_boxed_to_any_form,
    is_lower_anon_capture, is_package_head, is_pkg_root, lambda_mutated_outer_vars,
    lambda_writes_outer_var, lower_arg_run, lower_for, lower_for_labeled,
    lower_lambda_body_capturing, lower_lambda_body_capturing_kind, lower_stmt, lower_when,
    resolve_capture, splice_inline_lambda, try_inline_call_with_type_args,
};

/// Lower one expression into the current block. Returns the
/// register holding the result. Statements that do not produce a
/// value (assignments, declarations) return a synthetic `Unit`
/// register so downstream code stays uniform.
/// Lower an expression that appears as the *receiver / qualifier
/// head* of a member access or call (`recv.member`, `recv.m()`,
/// `recv::ref`, `recv.x = v`). A bare single-segment class/interface
/// name here is a *qualifier* — it must stay the `Value::Class` so
/// nested-class (`Outer.Inner`) and companion-member forwarding work
/// — unlike the same Path in value position, which resolves to the
/// companion object. Everything else defers to `lower_expr`.
pub fn lower_receiver(b: &mut FuncBuilder<'_>, expr: &Expr) -> Reg {
    if let Expr::Path { segments, .. } = expr
        && segments.len() == 1
    {
        let n = &segments[0].name;
        // Skip the class-name shortcut when the enclosing class aliases this
        // name to a (mangled) nested object: a bare `Inner` inside `Outer`
        // must reach `Outer$Inner` even though a same-named top-level class
        // owns the bare `class_id`. Falling through to `lower_expr` applies
        // the alias rewrite in the `Expr::Path` arm.
        let aliased = b
            .owner_class()
            .map(str::to_string)
            .and_then(|owner| {
                b.module
                    .registry
                    .nested_object_aliases
                    .get(&owner)
                    .map(|m| m.contains_key(n))
            })
            .unwrap_or(false);
        if !aliased
            && b.resolve(n).is_none()
            && !b.knows_outer(n)
            && b.module.class_id(n).is_some()
        {
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(n.clone()));
            b.push(Inst::LoadGlobal { dst, name: nm });
            return dst;
        }
    }
    // A receiver is not in the call's tail position; drop the
    // expected-type hint so it does not reach a reified inline call here.
    let prev_expected = b.push_expected(None);
    let r = lower_expr(b, expr);
    b.restore_expected(prev_expected);
    r
}

/// Lower one expression into the current block, returning the register
/// holding its value. Value-less forms (assignments, declarations)
/// return a synthetic `Unit` register so downstream code stays uniform.
///
/// # Panics
/// Panics if the AST violates a shape invariant established earlier in
/// lowering: a matched callee or argument node has an unexpected form,
/// or a `this`/binding the surrounding context guarantees is in scope
/// is not resolvable.
// Single dispatch match over every expression form; splitting would
// fragment one match and risk correctness. The numeric-literal casts
// implement Kotlin's defined conversions (UInt/ULong/Int/Float literal
// lowering) and the usize->u8/u32 casts pack argument counts and
// register indices into the IR's fixed-width slots.
/// Among same-name overload candidates, prefer the one whose parameter
/// type at an explicitly-cast argument position (`x as T`) matches the
/// cast target `T`. Kotlin's overload resolution honours such a cast;
/// klio otherwise picks by arity alone (ignoring arg types), so e.g.
/// the deprecated `async(context: Job, …)` overload's delegation
/// `async(context as CoroutineContext, …)` re-selects the `Job` overload
/// (the runtime value is still a `Job`) and recurses forever. Returns
/// `None` when no cast argument disambiguates an arity-matching
/// candidate, so the caller falls back to its arity-first pick.
fn overload_pick_by_cast(
    b: &FuncBuilder<'_>,
    cands: &[FuncId],
    args: &[Expr],
    want: usize,
) -> Option<FuncId> {
    let casts: Vec<(usize, String)> = args
        .iter()
        .enumerate()
        .filter_map(|(i, a)| match a {
            Expr::As { ty, .. } => Some((
                i,
                ty.name
                    .name
                    .rsplit('.')
                    .next()
                    .unwrap_or(&ty.name.name)
                    .to_string(),
            )),
            _ => None,
        })
        .collect();
    if casts.is_empty() {
        return None;
    }
    let mut best: Option<(FuncId, i32)> = None;
    for fid in cands {
        let Some(f) = b.module.funcs.get(fid.0 as usize) else {
            continue;
        };
        if f.blocks.is_empty() || f.params.last().is_some_and(|p| p.is_vararg) {
            continue;
        }
        let base = usize::from(f.params.first().is_some_and(|p| p.name == "this"));
        if f.params.len().saturating_sub(base) != want {
            continue;
        }
        let mut score = 0i32;
        for (i, cast_ty) in &casts {
            if let Some(p) = f.params.get(base + i) {
                let pn = p.ty.name.rsplit('.').next().unwrap_or(&p.ty.name);
                if pn == cast_ty {
                    score += 2;
                }
            }
        }
        if score > 0 && best.is_none_or(|(_, s)| score > s) {
            best = Some((*fid, score));
        }
    }
    best.map(|(f, _)| f)
}

#[allow(
    clippy::too_many_lines,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn lower_expr(b: &mut FuncBuilder<'_>, expr: &Expr) -> Reg {
    // Arm the implicit-label for a call's argument lambdas with the
    // callee's simple name (`with(n) { … }` → "with"). `lower_arg_run`
    // consumes and re-arms it per argument; `Expr::Lambda` reads it.
    if let Expr::Call { callee, .. } = expr {
        b.pending_lambda_label = callee_label(callee);
    }
    match expr {
        Expr::IntLit { value, kind, .. } => {
            // Honour the literal's declared kind (`1L`, `1U`, `1uL`)
            // rather than letting the value range pick. The suffix
            // is what tells `is Long` apart from `is Int` for small
            // values.
            match kind {
                klio_ast::IntLitKind::Long => b.emit_const(Const::Long(*value)),
                klio_ast::IntLitKind::UInt => b.emit_const(Const::UInt(*value as u32)),
                klio_ast::IntLitKind::ULong => b.emit_const(Const::ULong(*value as u64)),
                klio_ast::IntLitKind::Int => {
                    if i32::try_from(*value).is_ok() {
                        b.emit_const(Const::Int(*value as i32))
                    } else {
                        b.emit_const(Const::Long(*value))
                    }
                }
            }
        }
        Expr::FloatLit { value, kind, .. } => match kind {
            klio_ast::FloatLitKind::Float => b.emit_const(Const::Float(*value as f32)),
            klio_ast::FloatLitKind::Double => b.emit_const(Const::Double(*value)),
        },
        Expr::BoolLit { value, .. } => b.emit_const(Const::Bool(*value)),
        Expr::NullLit { .. } => b.emit_const(Const::Null),
        Expr::CharLit { value, .. } => b.emit_const(Const::Char(*value)),

        Expr::Binary { op, lhs, rhs, .. }
            if matches!(op, AstBinOp::Eq | AstBinOp::Neq)
                && (is_boxed_to_any_form(lhs)
                    || is_boxed_to_any_form(rhs)
                    || is_any_typed_path(b, lhs)
                    || is_any_typed_path(b, rhs)) =>
        {
            // `==` on a boxed `Any` operand uses bitwise equality
            // for Double/Float (NaN == NaN true, +0.0 != -0.0)
            // per spec. Emit the dedicated `BoxedEq` / `BoxedNotEq`
            // BinOp so the evaluator picks bitwise FP comparison.
            let l = lower_expr(b, lhs);
            let r = lower_expr(b, rhs);
            let dst = b.alloc_reg();
            let ir_op = match op {
                AstBinOp::Eq => BinOp::BoxedEq,
                AstBinOp::Neq => BinOp::BoxedNotEq,
                _ => unreachable!(),
            };
            b.push(Inst::BinOp {
                dst,
                op: ir_op,
                lhs: l,
                rhs: r,
            });
            dst
        }
        Expr::Binary { op, lhs, rhs, .. } => {
            // `x in haystack` / `x !in haystack` desugar to
            // `haystack.contains(x)` (negated for !in). The right
            // operand is the haystack so dispatch through CallMember.
            if matches!(op, AstBinOp::In | AstBinOp::NotIn) {
                // `x in lo..hi` / `x in lo..<hi` with a range *literal*
                // on the right is the `in` range intrinsic: lower it to
                // `lo <= x && x <= hi` (`x < hi` for `..<`), the same
                // comparison form kotlinc emits. This covers every
                // Comparable endpoint type and — unlike building a range
                // value — supports floating-point ranges (`it in 0.0..1.0`)
                // that klio's integer `Value::Range` cannot represent.
                if let Expr::Binary {
                    op: r_op @ (AstBinOp::Range | AstBinOp::RangeUntil),
                    lhs: lo,
                    rhs: hi,
                    ..
                } = rhs.as_ref()
                {
                    let x = lower_expr(b, lhs);
                    let lo_r = lower_expr(b, lo);
                    let hi_r = lower_expr(b, hi);
                    let ge = b.alloc_reg();
                    b.push(Inst::BinOp {
                        dst: ge,
                        op: BinOp::LessEq,
                        lhs: lo_r,
                        rhs: x,
                    });
                    let upper = if matches!(r_op, AstBinOp::RangeUntil) {
                        BinOp::Less
                    } else {
                        BinOp::LessEq
                    };
                    let le = b.alloc_reg();
                    b.push(Inst::BinOp {
                        dst: le,
                        op: upper,
                        lhs: x,
                        rhs: hi_r,
                    });
                    let both = b.alloc_reg();
                    b.push(Inst::BinOp {
                        dst: both,
                        op: BinOp::And,
                        lhs: ge,
                        rhs: le,
                    });
                    if matches!(op, AstBinOp::NotIn) {
                        let dst = b.alloc_reg();
                        b.push(Inst::Not { dst, src: both });
                        return dst;
                    }
                    return both;
                }
                let recv = lower_expr(b, rhs);
                let arg_slot = b.alloc_reg();
                let l = lower_expr(b, lhs);
                b.push(Inst::Move {
                    dst: arg_slot,
                    src: l,
                });
                let contains = b.alloc_reg();
                let nm = b.module.intern_const(Const::String("contains".into()));
                b.push(Inst::CallMember {
                    dst: contains,
                    receiver: recv,
                    name: nm,
                    args: arg_slot,
                    n_args: 1,
                    arg_names: Vec::new(),
                });
                if matches!(op, AstBinOp::NotIn) {
                    let dst = b.alloc_reg();
                    b.push(Inst::Not { dst, src: contains });
                    return dst;
                }
                return contains;
            }
            // Elvis `a ?: b` short-circuits — when `a` is non-null
            // the right operand must not evaluate. Lower as a
            // conditional branch with phi-style merge.
            if matches!(op, AstBinOp::Elvis) {
                let l = lower_expr(b, lhs);
                let null_r = b.emit_const(Const::Null);
                let is_null = b.alloc_reg();
                b.push(Inst::BinOp {
                    dst: is_null,
                    op: BinOp::Eq,
                    lhs: l,
                    rhs: null_r,
                });
                let then_b = b.alloc_block();
                let else_b = b.alloc_block();
                let join = b.alloc_block();
                let dst = b.alloc_reg();
                b.terminate(Terminator::Branch {
                    cond: is_null,
                    t: then_b,
                    f: else_b,
                });
                b.switch_to(then_b);
                let rv = lower_expr(b, rhs);
                b.push(Inst::Move { dst, src: rv });
                b.terminate(Terminator::Goto(join));
                b.switch_to(else_b);
                b.push(Inst::Move { dst, src: l });
                b.terminate(Terminator::Goto(join));
                b.switch_to(join);
                return dst;
            }
            // Logical `&&` / `||` short-circuit similarly.
            if matches!(op, AstBinOp::And | AstBinOp::Or) {
                let l = lower_expr(b, lhs);
                let then_b = b.alloc_block();
                let else_b = b.alloc_block();
                let join = b.alloc_block();
                let dst = b.alloc_reg();
                b.terminate(Terminator::Branch {
                    cond: l,
                    t: then_b,
                    f: else_b,
                });
                let is_and = matches!(op, AstBinOp::And);
                // `&&`: if l is true → evaluate rhs; else → false.
                // `||`: if l is true → true; else → evaluate rhs.
                if is_and {
                    b.switch_to(then_b);
                    let rv = lower_expr(b, rhs);
                    b.push(Inst::Move { dst, src: rv });
                    b.terminate(Terminator::Goto(join));
                    b.switch_to(else_b);
                    let false_r = b.emit_const(Const::Bool(false));
                    b.push(Inst::Move { dst, src: false_r });
                    b.terminate(Terminator::Goto(join));
                } else {
                    b.switch_to(then_b);
                    let true_r = b.emit_const(Const::Bool(true));
                    b.push(Inst::Move { dst, src: true_r });
                    b.terminate(Terminator::Goto(join));
                    b.switch_to(else_b);
                    let rv = lower_expr(b, rhs);
                    b.push(Inst::Move { dst, src: rv });
                    b.terminate(Terminator::Goto(join));
                }
                b.switch_to(join);
                return dst;
            }
            // Comparison on a generic type-parameter operand
            // (`a < b` where `a: T`): Kotlin desugars this to
            // `a.compareTo(b) <op> 0`. For `Double`/`Float` that is the
            // total order (NaN greatest), not the IEEE primitive — so a
            // generic `maxOf`/`minOf` body returns NaN like the
            // reference compiler. Concrete-typed operands keep the
            // primitive op (e.g. `Double.NaN < 1.0` stays `false`).
            let is_generic_operand = |e: &Expr| -> bool {
                matches!(
                    e,
                    Expr::Path { segments, .. }
                        if segments.len() == 1
                            && b.is_generic_typed_param(&segments[0].name)
                )
            };
            if matches!(
                op,
                AstBinOp::Lt | AstBinOp::Le | AstBinOp::Gt | AstBinOp::Ge
            ) && (is_generic_operand(lhs) || is_generic_operand(rhs))
            {
                let recv = lower_expr(b, lhs);
                let arg_slot = b.alloc_reg();
                let r = lower_expr(b, rhs);
                b.push(Inst::Move {
                    dst: arg_slot,
                    src: r,
                });
                let cmp = b.alloc_reg();
                let nm = b.module.intern_const(Const::String("compareTo".into()));
                b.push(Inst::CallMember {
                    dst: cmp,
                    receiver: recv,
                    name: nm,
                    args: arg_slot,
                    n_args: 1,
                    arg_names: Vec::new(),
                });
                let zero = b.emit_const(Const::Int(0));
                let dst = b.alloc_reg();
                b.push(Inst::BinOp {
                    dst,
                    op: ast_binop(*op),
                    lhs: cmp,
                    rhs: zero,
                });
                return dst;
            }
            let l = lower_expr(b, lhs);
            let r = lower_expr(b, rhs);
            let dst = b.alloc_reg();
            b.push(Inst::BinOp {
                dst,
                op: ast_binop(*op),
                lhs: l,
                rhs: r,
            });
            dst
        }
        Expr::Unary { op, expr, .. }
            if matches!(op, AstUnOp::Neg)
                && matches!(
                    expr.as_ref(),
                    Expr::IntLit { value, kind: klio_ast::IntLitKind::Int, .. }
                        if *value == (i64::from(i32::MAX) + 1)
                ) =>
        {
            // `-2147483648` parses as Neg(IntLit(2147483648)); the
            // operand's value doesn't fit in i32 so general
            // IntLit-lowering would widen to Long. Special-case
            // Int.MIN_VALUE so it stays Int and arithmetic wraps
            // at the 32-bit boundary.
            b.emit_const(Const::Int(i32::MIN))
        }
        Expr::Unary { op, expr, .. } => {
            // Prefix ++ / -- need both an Inc/Dec UnOp AND a
            // write-back to the lvalue. Delegate to a helper that
            // mirrors postfix's Path/Member/Index branches and
            // returns the NEW value (not the old, per Kotlin's
            // pre-inc/pre-dec semantics).
            if matches!(op, AstUnOp::PreInc | AstUnOp::PreDec) {
                let operand = lower_expr(b, expr);
                let dst = b.alloc_reg();
                let u = if matches!(op, AstUnOp::PreInc) {
                    UnOp::Inc
                } else {
                    UnOp::Dec
                };
                b.push(Inst::UnOp {
                    dst,
                    op: u,
                    operand,
                });
                match expr.as_ref() {
                    Expr::Path { segments, .. } if segments.len() == 1 => {
                        if b.is_boxed(&segments[0].name) {
                            let cell = boxed_cell_reg(b, &segments[0].name);
                            b.push(Inst::CellSet { cell, value: dst });
                        } else if let Some(home) = b.mutable_home(&segments[0].name) {
                            b.push(Inst::Move {
                                dst: home,
                                src: dst,
                            });
                        } else if b.has_own_member(&segments[0].name) && b.resolve("this").is_some()
                        {
                            // Method-body `++field` write — route through
                            // SetField on this so the mutation reaches the
                            // instance (mirrors the postfix `field++` path).
                            // Without this a bare-name field inc/dec rebound
                            // a local and the field never updated (e.g.
                            // `suspensions[++lastSuspensionIndex]`).
                            let this_reg = b.resolve("this").unwrap();
                            let field = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::SetField {
                                receiver: this_reg,
                                field,
                                value: dst,
                            });
                        } else if b.knows_outer(&segments[0].name) {
                            let _ = b.record_capture(&segments[0].name);
                            let n = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::StoreGlobal {
                                name: n,
                                value: dst,
                            });
                            b.rebind(&segments[0].name, dst);
                        } else {
                            b.rebind(&segments[0].name, dst);
                        }
                    }
                    Expr::Member {
                        receiver,
                        name,
                        safe: false,
                        ..
                    } => {
                        let recv = lower_receiver(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField {
                            receiver: recv,
                            field,
                            value: dst,
                        });
                    }
                    Expr::Index {
                        receiver,
                        args: idx_args,
                        ..
                    } => {
                        let recv = lower_receiver(b, receiver);
                        let n_keys = idx_args.len();
                        let key_start = b.alloc_reg();
                        let mut key_slots: Vec<Reg> = vec![key_start];
                        for _ in 1..n_keys {
                            key_slots.push(b.alloc_reg());
                        }
                        let val_slot = b.alloc_reg();
                        for (slot, arg) in key_slots.iter().zip(idx_args.iter()) {
                            let r = lower_expr(b, arg);
                            b.push(Inst::Move { dst: *slot, src: r });
                        }
                        b.push(Inst::Move {
                            dst: val_slot,
                            src: dst,
                        });
                        let ret = b.alloc_reg();
                        let nm = b.module.intern_const(Const::String("set".into()));
                        b.push(Inst::CallMember {
                            dst: ret,
                            receiver: recv,
                            name: nm,
                            args: key_start,
                            n_args: (n_keys as u8) + 1,
                            arg_names: Vec::new(),
                        });
                    }
                    _ => {}
                }
                return dst;
            }
            let operand = lower_expr(b, expr);
            let dst = b.alloc_reg();
            match op {
                AstUnOp::Not => b.push(Inst::Not { dst, src: operand }),
                AstUnOp::Neg => b.push(Inst::UnOp {
                    dst,
                    op: UnOp::Neg,
                    operand,
                }),
                AstUnOp::Pos => b.push(Inst::UnOp {
                    dst,
                    op: UnOp::Plus,
                    operand,
                }),
                AstUnOp::PreInc | AstUnOp::PreDec => unreachable!(),
            }
            dst
        }
        Expr::If {
            cond,
            then_branch,
            else_branch,
            ..
        } => {
            // Use a single destination register that both arms
            // write into via Move before jumping to the join.
            // Equivalent to a phi-node-driven SSA result without
            // requiring SSA infrastructure: the evaluator sees the
            // last write at the join site.
            let cond_r = lower_expr(b, cond);
            let t_block = b.alloc_block();
            let f_block = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch {
                cond: cond_r,
                t: t_block,
                f: f_block,
            });
            // Then arm.
            b.switch_to(t_block);
            let t_val = lower_expr(b, then_branch);
            b.push(Inst::Move { dst, src: t_val });
            b.terminate(Terminator::Goto(join));
            // Else arm.
            b.switch_to(f_block);
            let f_val = match else_branch {
                Some(e) => lower_expr(b, e),
                None => b.emit_const(Const::Unit),
            };
            b.push(Inst::Move { dst, src: f_val });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            dst
        }
        Expr::Block(block) => lower_block(b, block),
        Expr::Path { segments, span } => {
            // Inline a bare reference to an enclosing class's (or its
            // companion's) `const val name = <literal>` directly as a
            // constant load — Kotlin's `const val` is compile-time
            // inlined, sidestepping companion-singleton init order
            // (relevant when the companion `object Default : Outer(…)`
            // inherits the outer class and the outer's ctor reads a
            // companion const before the Default singleton is ready).
            if segments.len() == 1
                && let Some(owner) = b.owner_class().map(str::to_string)
                && b.resolve(&segments[0].name).is_none()
            {
                let key = (owner, segments[0].name.clone());
                if let Some(c) = b.module.registry.class_const_inits.get(&key).cloned() {
                    return b.emit_const(c);
                }
            }
            // Nested-object alias rewrite: when inside an outer class
            // whose lift renamed a `private object Inner` to
            // `Outer$Inner` (to avoid colliding with a same-named user
            // top-level), bare references to `Inner` in the outer's
            // method bodies redirect to the renamed lifted class.
            if let Some(owner) = b.owner_class().map(str::to_string) {
                let renamed = b
                    .module
                    .registry
                    .nested_object_aliases
                    .get(&owner)
                    .and_then(|m| m.get(&segments[0].name))
                    .cloned();
                if let Some(renamed) = renamed
                    && b.resolve(&segments[0].name).is_none()
                {
                    let mut new_segs = segments.clone();
                    new_segs[0] = klio_ast::Ident {
                        name: renamed,
                        span: segments[0].span,
                    };
                    let rewritten = Expr::Path {
                        segments: new_segs,
                        span: *span,
                    };
                    return lower_expr(b, &rewritten);
                }
            }
            if segments.len() == 1 {
                // Bare `Unit` is the Unit singleton value (`fun
                // hintEmit(): Unit = Unit`), not a member read — it
                // must not fall through to a `this.Unit` field probe
                // inside a method/extension body.
                if segments[0].name == "Unit" && b.resolve("Unit").is_none() {
                    return b.emit_const(Const::Unit);
                }
                if let Some(r) = b.resolve(&segments[0].name) {
                    if b.is_boxed(&segments[0].name) {
                        // `r` holds the shared `Value::Cell`; read
                        // its current contents.
                        let dst = b.alloc_reg();
                        b.push(Inst::CellGet { dst, cell: r });
                        return dst;
                    }
                    return r;
                }
                // A bare read of a name the enclosing anon object closes
                // over reads that captured value — even when the object
                // also declares a same-named member (the `Continuation(ctx)
                // { override val context get() = context }` factory). The
                // captured outer is in lexical scope and shadows the
                // member's getter for an unqualified read, so resolve via
                // `LoadCapture` rather than a `this.<name>` field probe
                // that would miss the getter-only property. No-op outside
                // anon-method lowering.
                if is_lower_anon_capture(&segments[0].name) {
                    let idx = b.record_capture(&segments[0].name);
                    let cell = b.alloc_reg();
                    b.push(Inst::LoadCapture { dst: cell, idx });
                    if b.is_boxed(&segments[0].name) {
                        let dst = b.alloc_reg();
                        b.push(Inst::CellGet { dst, cell });
                        return dst;
                    }
                    return cell;
                }
                // Lambda-body capture: name lives in an enclosing
                // frame but not as a top-level global.
                if b.knows_outer(&segments[0].name) {
                    let idx = b.record_capture(&segments[0].name);
                    let cell = b.alloc_reg();
                    b.push(Inst::LoadCapture { dst: cell, idx });
                    // Do NOT cache the loaded reg under the capture
                    // name: a later reference in a sibling branch
                    // would reuse a reg whose defining `LoadCapture`
                    // is in a non-dominating block (its value would be
                    // the uninitialized `Unit`). `LoadCapture` reads
                    // the frame-global captures vector, so re-emitting
                    // it at every use is always correct and cheap.
                    if b.is_boxed(&segments[0].name) {
                        let dst = b.alloc_reg();
                        b.push(Inst::CellGet { dst, cell });
                        return dst;
                    }
                    return cell;
                }
                // A bare `coroutineContext` inside a member/extension of
                // a `CoroutineScope` is the receiver's own property
                // (Kotlin: a member of the implicit receiver shadows the
                // top-level suspend `coroutineContext` intrinsic). Lower
                // it to the explicit-property read so the runtime reads
                // the receiver's stored context (ktor's
                // `HttpClientEngine.closed` /
                // `createCallContext` build on the engine's own
                // supervisor) instead of redirecting to the ambient
                // running coroutine. The bare intrinsic — a suspend fn
                // with no `CoroutineScope` receiver, e.g. `yield()` —
                // owns no such member and keeps the redirect.
                if segments[0].name == "coroutineContext"
                    && b.has_own_member("coroutineContext")
                    && let Some(this_reg) = b.resolve("this")
                {
                    let dst = b.alloc_reg();
                    let field = b
                        .module
                        .intern_const(Const::String("$coroutineContext$explicit".to_string()));
                    b.push(Inst::GetField {
                        dst,
                        receiver: this_reg,
                        field,
                    });
                    return dst;
                }
                // Inside a method / extension fn body `this` is
                // bound as the implicit first param. An unqualified
                // identifier that didn't resolve as a local /
                // capture / known outer is most likely a field
                // read on the instance — try `this.<name>` via
                // GetField when the owning class declares this
                // name. Otherwise fall through to LoadGlobal.
                if b.has_own_member(&segments[0].name) {
                    if let Some(this_reg) = b.resolve("this") {
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::GetField {
                            dst,
                            receiver: this_reg,
                            field: nm,
                        });
                        return dst;
                    }
                    // A superclass-constructor delegation argument
                    // thunk runs with the companion initialized but
                    // no `this`. A bare own-member name there is a
                    // companion access: load the enclosing class and
                    // read the member off it (get_field forwards a
                    // Class receiver to its companion singleton). This
                    // must beat the global-class step below so an
                    // unrelated interface/class of the same name (e.g.
                    // a `companion object Key` vs `CoroutineContext.Key`)
                    // does not shadow the class's own companion.
                    if b.is_param_thunk()
                        && let Some(owner) = b.owner_class().map(str::to_string)
                    {
                        let cls = b.alloc_reg();
                        let on = b.module.intern_const(Const::String(owner));
                        b.push(Inst::LoadGlobal { dst: cls, name: on });
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::GetField {
                            dst,
                            receiver: cls,
                            field: nm,
                        });
                        return dst;
                    }
                }
                // A bare name that is a known class is a class
                // reference (`Segment.SIZE`, `Segment.new()`), not an
                // implicit `this.<name>` member read. This must beat
                // the `this`-prefix probe below: inside an instance
                // or object method `this` is bound, and without this
                // check `Segment` would lower to `this.Segment` and
                // miss. The class value flows into get_field /
                // call_member which forward to the companion.
                if b.module.class_id(&segments[0].name).is_some() {
                    let cls = b.alloc_reg();
                    let n = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::LoadGlobal { dst: cls, name: n });
                    // A bare class/interface name in *value* position
                    // (Kotlin: only well-formed when it declares a
                    // companion) is the companion object, not the
                    // class. Qualifier heads (`Foo.member`, `Foo(..)`,
                    // `Foo::class`) lower their receiver via
                    // `lower_receiver` / NewInstance / ClassLiteral and
                    // never reach here. The sentinel read yields the
                    // companion when one exists, else the class value
                    // unchanged (objects / no-companion classes are
                    // untouched).
                    let dst = b.alloc_reg();
                    let sentinel = b
                        .module
                        .intern_const(Const::String("<class-companion-or-self>".to_string()));
                    b.push(Inst::GetField {
                        dst,
                        receiver: cls,
                        field: sentinel,
                    });
                    return dst;
                }
                // A bare builtin type name used as a qualifier
                // (`Long.MAX_VALUE`, `Int.SIZE_BITS`) is a
                // type/companion reference, not `this.<Type>`. Skip
                // the hard `this`-prefix GetField below and use the
                // this-or-global probe so it resolves the same way it
                // does at top level (the primitive-companion table).
                if matches!(
                    segments[0].name.as_str(),
                    "Int"
                        | "Long"
                        | "Short"
                        | "Byte"
                        | "Double"
                        | "Float"
                        | "Char"
                        | "Boolean"
                        | "String"
                        | "UInt"
                        | "ULong"
                        | "UShort"
                        | "UByte"
                ) {
                    let this_idx = b.record_capture("this");
                    let dst = b.alloc_reg();
                    let name = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::LoadFromThisOrGlobal {
                        dst,
                        this_idx,
                        name,
                    });
                    return dst;
                }
                // Not a local and not a known capture. Inside a
                // method / extension fn with `this` bound as a
                // param, try `this.<name>` first via GetField so
                // smart-casted member reads (`when (this) { is X ->
                // "$x" }`) resolve through the receiver instance.
                // Outside that scope fall through to the
                // LoadFromThisOrGlobal probe. A default-arg thunk
                // runs in the declaring scope, not as a member of
                // the receiver, so a bare name there must take the
                // this-or-global probe (resolving top-level objects
                // like `EmptyCoroutineContext`) instead.
                // An imported member of a (possibly named) companion
                // object — `import a.b.C.Factory.RENDEZVOUS` then a
                // bare `RENDEZVOUS` — has no import context in the IR,
                // so rewrite it to the qualified `C.RENDEZVOUS`
                // companion access (companion name is optional in
                // Kotlin) and lower that. Only fires when the import
                // path names a class the module actually declares, so
                // a coincidental same-named local/global is untouched.
                if b.resolve(&segments[0].name).is_none()
                    && let Some(rewrite) = b
                        .module
                        .import_alias_in(segments[0].span.file, &segments[0].name)
                        .and_then(|segs| {
                            let cls_idx =
                                segs.iter().rposition(|s| b.module.class_id(s).is_some())?;
                            (cls_idx + 1 < segs.len())
                                .then(|| (segs[cls_idx].clone(), segs[segs.len() - 1].clone()))
                        })
                {
                    let sp = segments[0].span;
                    let qualified = Expr::Path {
                        segments: vec![
                            klio_ast::Ident {
                                name: rewrite.0,
                                span: sp,
                            },
                            klio_ast::Ident {
                                name: rewrite.1,
                                span: sp,
                            },
                        ],
                        span: sp,
                    };
                    return lower_expr(b, &qualified);
                }
                // A genuinely-bound `this` (`b.resolve("this")` is `Some`)
                // means a real receiver is in scope — a method/extension body
                // OR an *extension* default-arg thunk, whose receiver is bound
                // as a leading `this` param (`fun String.f(end: Int = length)`
                // → the `end` thunk binds `this`). Such a thunk must read
                // `this.length`, not `LoadFromThisOrGlobal` (whose capture
                // slot is empty in a thunk, so `this` would be lost and
                // `length` escape to an unresolved global). A *non*-extension
                // thunk never binds `this`, so it keeps the global probe.
                if let Some(this_reg) = b.resolve("this") {
                    // A bare name that resolves to a known top-level
                    // function is a value-position function reference,
                    // not an implicit `this.<name>` field read. Skip
                    // the GetField shortcut so the global lookup wins
                    // — `get_field` on a non-Instance receiver (List,
                    // Map, Array …) can synthesise misleading values
                    // for unknown field names that downstream calls
                    // then invoke as the callable.
                    let is_known_global = b.module.func_id(&segments[0].name).is_some();
                    if !is_known_global {
                        let dst = b.alloc_reg();
                        let nm = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::GetField {
                            dst,
                            receiver: this_reg,
                            field: nm,
                        });
                        return dst;
                    }
                }
                let this_idx = b.record_capture("this");
                let dst = b.alloc_reg();
                let name = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::LoadFromThisOrGlobal {
                    dst,
                    this_idx,
                    name,
                });
                return dst;
            }
            // Multi-segment paths (`a.b.c`) lower as a chain of
            // GetFields starting from a top-level lookup. The
            // alternative — synthesize a fully-qualified LoadGlobal
            // — is faster but requires more import-resolution
            // context than the lowering pass has today.
            // Try the full FQN first (e.g. `kotlin.math.PI`) — the
            // host's lookup_global knows the package-resolved name
            // for stdlib intrinsics + properties and the IR doesn't
            // carry import context. Fall back to a chain of GetFields
            // off a head LoadGlobal when the FQN doesn't resolve.
            if segments.len() >= 2
                && is_package_head(&segments[0].name)
                && (is_pkg_root(&segments[0].name) || !b.is_lambda_body())
                && b.resolve(&segments[0].name).is_none()
                && b.module.class_id(&segments[0].name).is_none()
            {
                let fqn = segments
                    .iter()
                    .map(|s| s.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".");
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(fqn));
                b.push(Inst::LoadGlobal { dst, name: n });
                return dst;
            }
            let mut iter = segments.iter();
            let first = iter.next().expect("Path has at least one segment");
            let head = if let Some(r) = b.resolve(&first.name) {
                r
            } else {
                // Unresolved head: route through `this` / the
                // enclosing receiver before a bare global so a bare
                // member of `this@Outer` (e.g. inside a receiver
                // lambda) resolves instead of failing as a missing
                // global. Falls back to the global when neither has
                // it.
                let this_idx = b.record_capture("this");
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(first.name.clone()));
                b.push(Inst::LoadFromThisOrGlobal {
                    dst,
                    this_idx,
                    name: n,
                });
                dst
            };
            let mut cur = head;
            for seg in iter {
                let next = b.alloc_reg();
                let field = b.module.intern_const(Const::String(seg.name.clone()));
                b.push(Inst::GetField {
                    dst: next,
                    receiver: cur,
                    field,
                });
                cur = next;
            }
            cur
        }
        Expr::StringTemplate { parts, .. } => {
            let mut cur = b.emit_const(Const::String(String::new()));
            for part in parts {
                let piece = match part {
                    klio_ast::StringPart::Text(s) => b.emit_const(Const::String(s.clone())),
                    klio_ast::StringPart::ShortInterp(ident) => {
                        if let Some(r) = b.resolve(&ident.name) {
                            r
                        } else if b.knows_outer(&ident.name) {
                            let idx = b.record_capture(&ident.name);
                            let dst = b.alloc_reg();
                            b.push(Inst::LoadCapture { dst, idx });
                            b.bind(ident.name.clone(), dst);
                            dst
                        } else if b.has_own_member(&ident.name) && b.resolve("this").is_some() {
                            // Inside a method body, unqualified
                            // `$name` resolves through `this.name`.
                            let this_reg = b.resolve("this").unwrap();
                            let dst = b.alloc_reg();
                            let nm = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::GetField {
                                dst,
                                receiver: this_reg,
                                field: nm,
                            });
                            dst
                        } else if let Some(this_reg) = b.resolve("this") {
                            // `$name` inside an extension fn /
                            // method whose receiver param holds the
                            // referenced field — emit GetField on
                            // the bound `this` reg. Host get_field
                            // falls through to globals when the
                            // field isn't on the instance.
                            let dst = b.alloc_reg();
                            let n = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::GetField {
                                dst,
                                receiver: this_reg,
                                field: n,
                            });
                            dst
                        } else {
                            // Fall back through the captured `this`
                            // slot — the dispatcher may supply a
                            // this-binding (scope fns). Reduces to a
                            // plain global lookup when the captured
                            // this is null.
                            let this_idx = b.record_capture("this");
                            let dst = b.alloc_reg();
                            let n = b.module.intern_const(Const::String(ident.name.clone()));
                            b.push(Inst::LoadFromThisOrGlobal {
                                dst,
                                this_idx,
                                name: n,
                            });
                            dst
                        }
                    }
                    klio_ast::StringPart::Interp(e) => lower_expr(b, e),
                };
                let dst = b.alloc_reg();
                b.push(Inst::BinOp {
                    dst,
                    op: BinOp::StringConcat,
                    lhs: cur,
                    rhs: piece,
                });
                cur = dst;
            }
            cur
        }
        Expr::While { cond, body, .. } => {
            let header = b.alloc_block();
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(header));

            b.switch_to(header);
            let c = lower_expr(b, cond);
            b.terminate(Terminator::Branch {
                cond: c,
                t: body_blk,
                f: exit,
            });

            b.switch_to(body_blk);
            b.push_loop(None, header, exit);
            let _ = lower_expr(b, body);
            b.pop_loop();
            b.terminate(Terminator::Goto(header));

            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Member {
            receiver,
            name,
            safe,
            ..
        } if *safe => {
            // `recv?.x` — null-guard: if recv is null, the whole
            // expression is null; otherwise read the field.
            let recv = lower_receiver(b, receiver);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp {
                dst: is_null,
                op: BinOp::Eq,
                lhs: recv,
                rhs: null_r,
            });
            let then_b = b.alloc_block();
            let else_b = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch {
                cond: is_null,
                t: then_b,
                f: else_b,
            });
            // null branch: dst = null
            b.switch_to(then_b);
            let n = b.emit_const(Const::Null);
            b.push(Inst::Move { dst, src: n });
            b.terminate(Terminator::Goto(join));
            // non-null: dst = recv.field
            b.switch_to(else_b);
            let field = b.module.intern_const(Const::String(name.name.clone()));
            let v = b.alloc_reg();
            b.push(Inst::GetField {
                dst: v,
                receiver: recv,
                field,
            });
            b.push(Inst::Move { dst, src: v });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            dst
        }
        Expr::Member { receiver, name, .. } => {
            // `super.<prop>` is a property read on the superclass —
            // dispatch its getter via the parent chain (a 0-arg
            // `CallSuper`), never `this.<prop>` (which would re-enter
            // an overriding getter, e.g. `override val isActive get()
            // = super.isActive`, and recurse forever). Mirrors the
            // `super.method(...)` CallSuper path.
            if let Expr::Super {
                qualifier, label, ..
            } = receiver.as_ref()
                && let Some(this_reg) = b.resolve("this")
                && let Some(owner) = b.owner_class().map(std::string::ToString::to_string)
            {
                let dst = b.alloc_reg();
                let nm = b.module.intern_const(Const::String(name.name.clone()));
                let oc = b.module.intern_const(Const::String(owner));
                let qual_const = qualifier
                    .as_ref()
                    .map(|t| b.module.intern_const(Const::String(t.name.name.clone())))
                    .or_else(|| {
                        label
                            .as_ref()
                            .map(|id| b.module.intern_const(Const::String(id.name.clone())))
                    });
                let args_start = b.alloc_reg();
                b.push(Inst::CallSuper {
                    dst,
                    receiver: this_reg,
                    owner_class: oc,
                    qualifier: qual_const,
                    name: nm,
                    args: args_start,
                    n_args: 0,
                    arg_names: Vec::new(),
                });
                return dst;
            }
            // Flatten chains like `kotlin.math.PI` into a single FQN
            // lookup against the host when the head is an unresolved
            // identifier (i.e. not a local). Stdlib package roots
            // (`kotlin`, `kotlinx`, etc.) aren't real values, so the
            // chained-GetField fallback would fail at `kotlin` itself.
            if let Some(fqn) = collect_dotted_fqn(expr)
                && let Some(head) = fqn.split('.').next()
                    && is_package_head(head)
                        // Only a genuine package root (`kotlin`,
                        // `kotlinx`, …) flattens inside a lambda body:
                        // there `this` is a captured outer (not
                        // locally resolvable), so an arbitrary
                        // lowercase head like a member field
                        // (`resumeMode.isCancellableMode`) must NOT be
                        // mistaken for an FQN — it is a `this.<field>`
                        // access then an extension-property read.
                        // Mirrors the call-site guards below.
                        && (is_pkg_root(head) || !b.is_lambda_body())
                        && b.resolve(head).is_none()
                        && !b.knows_outer(head)
                        && b.module.class_id(head).is_none()
                        // Inside a method / extension body, the
                        // head could be `this.<head>`; don't
                        // shortcut to a global FQN.
                        && b.resolve("this").is_none()
            {
                let dst = b.alloc_reg();
                let n = b.module.intern_const(Const::String(fqn));
                b.push(Inst::LoadGlobal { dst, name: n });
                return dst;
            }
            // An explicit `recv.coroutineContext` is a literal field read —
            // never the suspend-implicit running-context intrinsic — so it
            // must not be redirected to the active coroutine scope. A
            // `CoroutineScope` such as ktor's `HttpClient` owns its own
            // `coroutineContext` (`engine.coroutineContext + clientJob`), and
            // `client.coroutineContext[Job]` must read *that*. The sentinel
            // field name signals get_field to skip the bare-`coroutineContext`
            // redirect (which still applies to the implicit single-segment
            // form lowered elsewhere).
            if name.name == "coroutineContext" {
                let recv = lower_receiver(b, receiver);
                let dst = b.alloc_reg();
                let field = b
                    .module
                    .intern_const(Const::String("$coroutineContext$explicit".to_string()));
                b.push(Inst::GetField {
                    dst,
                    receiver: recv,
                    field,
                });
                return dst;
            }
            let recv = lower_receiver(b, receiver);
            let dst = b.alloc_reg();
            let field = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::GetField {
                dst,
                receiver: recv,
                field,
            });
            dst
        }
        Expr::Index { receiver, args, .. } => {
            // `r[a, b, ...]` → r.get(a, b, ...). Evaluator's
            // CallMember + host.call_member route dispatches to
            // Value::Map / List / Array / user classes uniformly.
            let recv = lower_receiver(b, receiver);
            let (args_start, count) = lower_arg_run(b, args);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String("get".into()));
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args: count,
                arg_names: Vec::new(),
            });
            dst
        }
        // A member call onto an inline `reified` extension
        // (`xs.filterIsInstance<T>()`): member dispatch drops type
        // arguments, so the reified `is T` / `T::class` reads in the
        // body would test an unbound `T` and accept everything. Splice
        // the extension body with the receiver bound as `this` and each
        // reified type-param bound to its call-site class. Only reified
        // targets take this path — ordinary member extensions keep the
        // normal dispatch so the splice graph stays bounded. (A member
        // function can never be `reified`, so a reified inline target
        // resolved by name is always the intended extension.)
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            type_args: ast_type_args,
            is_infix,
            ..
        } if !*is_infix
            && matches!(callee.as_ref(), Expr::Member { safe: false, .. })
            && (!ast_type_args.is_empty() || b.peek_expected().is_some())
            && match callee.as_ref() {
                Expr::Member { name, .. } => {
                    inline_fn_ast(&name.name).is_some_and(|f| {
                        f.receiver_type.is_some() && f.type_params.iter().any(|tp| tp.is_reified)
                    }) && !b.inline_in_progress(&name.name)
                }
                _ => false,
            } =>
        {
            let Expr::Member { receiver, name, .. } = callee.as_ref() else {
                unreachable!()
            };
            // Capture the expected type before the splice lowers the
            // receiver / arguments (which clear the hint).
            let expected = b.peek_expected().cloned();
            if let Some(r) = try_inline_call_with_type_args(
                b,
                &name.name,
                args,
                ast_arg_names,
                Some(receiver.as_ref()),
                ast_type_args,
                expected.as_ref(),
            ) {
                return r;
            }
            // Splice bailed (recursion guard / default-arg gap):
            // fall back to a plain member dispatch.
            let recv = lower_receiver(b, receiver);
            let (args_start, n_args) = lower_arg_run(b, args);
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            let dst = b.alloc_reg();
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args,
                arg_names,
            });
            dst
        }
        // `repeat(n) { … }` — inline-desugar to a counted loop so
        // the body runs in the caller's eval frame. This must win
        // over the closure-mutating-lambda arms below (the body
        // commonly mutates an outer `var`) and over the generic
        // stdlib-dispatch arm, because dispatching `repeat` to its
        // Rust binding would run a suspending body in a
        // non-resumable Rust frame.
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            ..
        } if matches!(callee.as_ref(), Expr::Member { safe: true, .. }) => {
            // `recv?.m(args)` — null-guard the whole call: if the
            // receiver is null the call expression is null, otherwise
            // dispatch the member. Mirrors the safe-field path.
            let Expr::Member { receiver, name, .. } = callee.as_ref() else {
                unreachable!()
            };
            let recv = lower_receiver(b, receiver);
            let null_r = b.emit_const(Const::Null);
            let is_null = b.alloc_reg();
            b.push(Inst::BinOp {
                dst: is_null,
                op: BinOp::Eq,
                lhs: recv,
                rhs: null_r,
            });
            let then_b = b.alloc_block();
            let else_b = b.alloc_block();
            let join = b.alloc_block();
            let dst = b.alloc_reg();
            b.terminate(Terminator::Branch {
                cond: is_null,
                t: then_b,
                f: else_b,
            });
            b.switch_to(then_b);
            let n = b.emit_const(Const::Null);
            b.push(Inst::Move { dst, src: n });
            b.terminate(Terminator::Goto(join));
            b.switch_to(else_b);
            let (args_start, n_args) = lower_arg_run(b, args);
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            let v = b.alloc_reg();
            b.push(Inst::CallMember {
                dst: v,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args,
                arg_names,
            });
            b.push(Inst::Move { dst, src: v });
            b.terminate(Terminator::Goto(join));
            b.switch_to(join);
            dst
        }
        Expr::Call {
            callee,
            args,
            is_infix,
            ..
        } if !*is_infix
            && args.len() == 2
            && matches!(&args[1], Expr::Lambda { .. })
            && matches!(callee.as_ref(), Expr::Path { segments, .. }
                    if segments.len() == 1
                        && segments[0].name == "repeat"
                        && b.resolve("repeat").is_none()
                        && b.module.func_id("repeat").is_none()) =>
        {
            let Expr::Lambda { params, body, .. } = &args[1] else {
                unreachable!()
            };
            let n_reg = lower_expr(b, &args[0]);
            let i_reg = b.alloc_reg();
            let zero = b.emit_const(Const::Int(0));
            b.push(Inst::Move {
                dst: i_reg,
                src: zero,
            });
            let header = b.alloc_block();
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(header));
            b.switch_to(header);
            let cond = b.alloc_reg();
            b.push(Inst::BinOp {
                dst: cond,
                op: BinOp::Less,
                lhs: i_reg,
                rhs: n_reg,
            });
            b.terminate(Terminator::Branch {
                cond,
                t: body_blk,
                f: exit,
            });
            b.switch_to(body_blk);
            b.push_scope();
            let pname = params
                .first()
                .map_or_else(|| "it".to_string(), |p| p.name.clone());
            b.bind(pname, i_reg);
            b.push_loop(None, header, exit);
            let _ = lower_block(b, body);
            b.pop_loop();
            b.pop_scope();
            let one = b.emit_const(Const::Int(1));
            let nexti = b.alloc_reg();
            b.push(Inst::BinOp {
                dst: nexti,
                op: BinOp::Add,
                lhs: i_reg,
                rhs: one,
            });
            b.push(Inst::Move {
                dst: i_reg,
                src: nexti,
            });
            b.terminate(Terminator::Goto(header));
            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            is_infix,
            ..
        } if args.iter().any(|a| lambda_writes_outer_var(b, a))
            && matches!(callee.as_ref(), Expr::Member { .. })
            && !*is_infix =>
        {
            // Call passing a lambda that assigns to an outer-scope
            // variable. Emit a normal CallMember and a
            // WritebackCaptures Inst for each closure-mutating
            // lambda so the env's mutations are synced back to
            // the caller's regs after the call returns.
            let Expr::Member { receiver, name, .. } = callee.as_ref() else {
                unreachable!()
            };
            let recv = lower_receiver(b, receiver);
            // Lower args individually so we can remember each
            // lambda's reg for writeback.
            let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len());
            for a in args {
                let r = lower_expr(b, a);
                arg_regs.push(r);
            }
            // Compact into a contiguous run for the CallMember
            // arg-slot convention.
            let args_start = if arg_regs.is_empty() {
                Reg(0)
            } else {
                let start = b.alloc_reg();
                b.push(Inst::Move {
                    dst: start,
                    src: arg_regs[0],
                });
                for r in &arg_regs[1..] {
                    let slot = b.alloc_reg();
                    b.push(Inst::Move { dst: slot, src: *r });
                }
                start
            };
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::CallMember {
                dst,
                receiver: recv,
                name: nm,
                args: args_start,
                n_args: args.len() as u8,
                arg_names,
            });
            // Emit writebacks for each closure-mutating lambda
            // argument: read the captured names back out of the
            // lambda's env into the caller's source regs.
            for (i, a) in args.iter().enumerate() {
                let mutated = lambda_mutated_outer_vars(b, a);
                if mutated.is_empty() {
                    continue;
                }
                let lambda_reg = arg_regs[i];
                let mut names: Vec<crate::ConstId> = Vec::with_capacity(mutated.len());
                let mut dsts: Vec<Reg> = Vec::with_capacity(mutated.len());
                for name in &mutated {
                    if let Some(src_reg) = b.resolve(name) {
                        let n = b.module.intern_const(Const::String(name.clone()));
                        names.push(n);
                        dsts.push(src_reg);
                    }
                }
                if !names.is_empty() {
                    b.push(Inst::WritebackCaptures {
                        lambda: lambda_reg,
                        names,
                        dsts,
                    });
                }
            }
            dst
        }
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            type_args: ast_type_args,
            ..
        } if args.iter().any(|a| lambda_writes_outer_var(b, a))
            && matches!(callee.as_ref(), Expr::Path { .. }) =>
        {
            // Top-level fn call passing a closure-mutating lambda.
            // Lower as Call{func}/CallValue against the resolved
            // callable, then emit WritebackCaptures for each
            // mutating lambda arg.
            let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len());
            for a in args {
                let r = lower_expr(b, a);
                arg_regs.push(r);
            }
            // An extension/member fn lowers `this` as its implicit
            // first param. A bare call to one (`proc(a, b) { … }`
            // from inside another extension) must prepend the active
            // receiver, exactly like the non-lambda Call path —
            // otherwise the args shift by one and a lambda argument
            // lands in a value parameter.
            let mut run_regs: Vec<Reg> = Vec::with_capacity(arg_regs.len() + 1);
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
            {
                let needs_this = b
                    .module
                    .func_id(&segments[0].name)
                    .and_then(|fid| b.module.funcs.get(fid.0 as usize))
                    .is_some_and(|f| f.params.first().is_some_and(|p| p.name == "this"));
                if needs_this {
                    let this_reg = b.resolve("this").or_else(|| {
                        if b.knows_outer("this") || b.is_lambda_body() {
                            let idx = b.record_capture("this");
                            let d = b.alloc_reg();
                            b.push(Inst::LoadCapture { dst: d, idx });
                            b.bind("this".to_string(), d);
                            Some(d)
                        } else {
                            None
                        }
                    });
                    if let Some(tr) = this_reg {
                        run_regs.push(tr);
                    }
                }
            }
            run_regs.extend_from_slice(&arg_regs);
            let n_args = run_regs.len() as u8;
            let args_start = if run_regs.is_empty() {
                Reg(0)
            } else {
                let start = b.alloc_reg();
                b.push(Inst::Move {
                    dst: start,
                    src: run_regs[0],
                });
                for r in &run_regs[1..] {
                    let slot = b.alloc_reg();
                    b.push(Inst::Move { dst: slot, src: *r });
                }
                start
            };
            let mut arg_names = intern_arg_names(b.module, ast_arg_names);
            // Keep arg-name slots aligned with the (possibly
            // this-prepended) positional run.
            while arg_names.len() < run_regs.len() {
                arg_names.insert(0, None);
            }
            let dst = b.alloc_reg();
            let Expr::Path { segments, .. } = callee.as_ref() else {
                unreachable!()
            };
            if segments.len() == 1 {
                if let Some(func_id) = b.module.func_id(&segments[0].name) {
                    let type_args = intern_type_args(b.module, ast_type_args);
                    b.push(Inst::Call {
                        dst,
                        func: func_id,
                        args: args_start,
                        n_args,
                        arg_names,
                        type_args,
                        exact: false,
                    });
                } else {
                    // Not a user module fn. A bound local of this
                    // name is the callable (a local lambda var);
                    // otherwise it is a global / scope-fn intrinsic
                    // (`run`, `let`, …) — resolve it as a global
                    // directly. `lower_expr` would prepend an
                    // implicit `this.` inside a method body, turning
                    // `run { … }` into `this.run` and invoking the
                    // receiver instance.
                    let callee_r = if b.resolve(&segments[0].name).is_some() {
                        lower_expr(b, callee)
                    } else {
                        let r = b.alloc_reg();
                        let n = b
                            .module
                            .intern_const(Const::String(segments[0].name.clone()));
                        b.push(Inst::LoadGlobal { dst: r, name: n });
                        r
                    };
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args,
                        arg_names,
                    });
                }
            } else {
                let callee_r = lower_expr(b, callee);
                b.push(Inst::CallValue {
                    dst,
                    callee: callee_r,
                    args: args_start,
                    n_args,
                    arg_names,
                });
            }
            for (i, a) in args.iter().enumerate() {
                let mutated = lambda_mutated_outer_vars(b, a);
                if mutated.is_empty() {
                    continue;
                }
                let lambda_reg = arg_regs[i];
                let mut names: Vec<crate::ConstId> = Vec::with_capacity(mutated.len());
                let mut dsts: Vec<Reg> = Vec::with_capacity(mutated.len());
                for name in &mutated {
                    if let Some(src_reg) = b.resolve(name) {
                        let n = b.module.intern_const(Const::String(name.clone()));
                        names.push(n);
                        dsts.push(src_reg);
                    }
                }
                if !names.is_empty() {
                    b.push(Inst::WritebackCaptures {
                        lambda: lambda_reg,
                        names,
                        dsts,
                    });
                }
            }
            dst
        }
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            ..
        } if args.iter().any(|a| matches!(a, Expr::Spread { .. })) => {
            // Calls containing a `*spread` argument: emit a
            // `CallSpread` Inst whose `parts` list flags each arg
            // as positional or spread. The evaluator flattens the
            // spread sources at call time.
            let callee_reg = lower_expr(b, callee);
            let mut parts: Vec<crate::SpreadPart> = Vec::with_capacity(args.len());
            for a in args {
                if let Expr::Spread { expr: inner, .. } = a {
                    let r = lower_expr(b, inner);
                    parts.push(crate::SpreadPart {
                        reg: r,
                        is_spread: true,
                    });
                } else {
                    let r = lower_expr(b, a);
                    parts.push(crate::SpreadPart {
                        reg: r,
                        is_spread: false,
                    });
                }
            }
            let arg_names = intern_arg_names(b.module, ast_arg_names);
            let dst = b.alloc_reg();
            b.push(Inst::CallSpread {
                dst,
                callee: callee_reg,
                parts,
                arg_names,
            });
            dst
        }
        Expr::Call {
            callee,
            args,
            arg_names: ast_arg_names,
            type_args: ast_type_args,
            is_infix,
            ..
        } => {
            // Inline expansion (suspend-inline only). A bare `Path`
            // callee that names a lambda parameter of the enclosing
            // inline frame is spliced; one that names a registered
            // `suspend inline fun` is expanded so its
            // `suspendCoroutineUninterceptedOrReturn` captures the
            // caller's continuation. Any unsafe shape falls back to a
            // normal call via `None`.
            if !*is_infix
                && let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
            {
                let nm = &segments[0].name;
                if let Some(lam) = b.inline_lambda_for(nm) {
                    return splice_inline_lambda(b, &lam, args);
                }
                // Pick the inline overload by call shape so an overloaded
                // `inline fun get(builder)` / `get(block)` binds a trailing
                // lambda to the function-param form.
                let inline_call_shape = (
                    args.len(),
                    args.last()
                        .is_some_and(|a| matches!(a, Expr::Lambda { .. } | Expr::AnonFun { .. })),
                );
                if let Some(f) = inline_fn_ast_for(nm, Some(inline_call_shape)) {
                    // Inline a suspending builder (continuation
                    // capture), an inline fn whose lambda arg
                    // does a non-local `return` (must target
                    // the caller's frame), or any `inline fun
                    // <reified T>` (`T::class` / `is T` reads
                    // in the body need the call-site type
                    // argument substituted at splice time —
                    // the non-splice path has no `Inst` to
                    // bind a runtime type-parameter value).
                    // Other inline calls keep the normal call
                    // path so the splice graph cannot expand
                    // combinatorially through Flow / Channel
                    // operator chains.
                    let has_reified = f.type_params.iter().any(|tp| tp.is_reified);
                    // Inline when a same-name member of the enclosing receiver
                    // would otherwise shadow this inline fn AND no bodied
                    // same-name function can actually accept this call: a
                    // companion's 1-arg `parse(value)` beside the inherited
                    // 2-arg inline `parse(value, init)` captures the call via
                    // `prefer_member`/`CallMember`, drops the trailing lambda,
                    // and recurses (`ContentDisposition.parse`). Inlining binds
                    // the real inline fn instead. The gates keep the normal
                    // path when a member legitimately handles the call: a
                    // function-typed final param the lambda fills (`Box.map(f)`
                    // — a bodied `map` of matching arity exists, so it is not
                    // shadowed away) or a member matching the call shape
                    // (`String.get(i)` shadowing the InlineOnly `Map.get`).
                    let want = args.len();
                    let trailing_lambda = args
                        .last()
                        .is_some_and(|a| matches!(a, Expr::Lambda { .. } | Expr::AnonFun { .. }));
                    let inline_takes_fn =
                        f.params.last().is_some_and(|p| p.ty.function.is_some());
                    // `want >= 2` confines this to a call with positional
                    // arg(s) *plus* a trailing lambda — the shape a
                    // lower-arity member silently truncates (`parse(value)
                    // { … }` → the 1-arg `parse(value)` drops the lambda).
                    // A single-lambda HOF call (`map { … }`, `let { … }`)
                    // has `want == 1` and stays on the member path, where
                    // the member legitimately receives the lambda.
                    let drops_trailing_lambda = trailing_lambda && want >= 2;
                    // Don't inline when a bodied same-name function can
                    // already accept this call's arity (a top-level overload
                    // of matching shape resolves on the normal path).
                    let a_func_fits = b.module.funcs_by_simple_name(nm).iter().any(|fid| {
                        let Some(mf) = b.module.funcs.get(fid.0 as usize) else {
                            return false;
                        };
                        if mf.blocks.is_empty() {
                            return false;
                        }
                        let has_this = mf.params.first().is_some_and(|p| p.name == "this");
                        let base = usize::from(has_this);
                        let user = mf.params.len() - base;
                        user == want
                            || (want < user
                                && mf.params[(base + want)..]
                                    .iter()
                                    .all(|p| p.default.is_some() || p.is_vararg))
                            || (want > user && mf.params.last().is_some_and(|p| p.is_vararg))
                    });
                    let shadowed_by_member = drops_trailing_lambda
                        && inline_takes_fn
                        && !a_func_fits
                        && b.resolve(nm).is_none()
                        && b.has_own_member(nm);
                    // An inline *extension* fn (`HttpClient.get`) is only
                    // applicable to a bare call when the enclosing implicit
                    // receiver is that type. A bare `get(index)` inside
                    // `CharSequence.indexOfAny` (`this.get(index)`) must not
                    // splice the ktor `HttpClient.get` body — its `get` simple
                    // name collides with the stdlib indexing `get`. Skip the
                    // inline on a *positive* receiver mismatch (the enclosing
                    // receiver type is known and differs), so the call falls
                    // through to normal resolution which binds the real member.
                    // A None enclosing receiver (lambda capture, top level)
                    // keeps the existing behavior.
                    let recv_mismatch = f.receiver_type.as_ref().is_some_and(|rt| {
                        let rn = rt.name.name.as_str();
                        b.recv_ty()
                            .is_some_and(|cur| cur != rn && b.owner_class() != Some(rn))
                    });
                    let needs_inline = !recv_mismatch
                        && (f.is_suspend
                            || arg_lambda_has_nonlocal_return(args)
                            || has_reified
                            || shadowed_by_member);
                    let expected = b.peek_expected().cloned();
                    if needs_inline
                        && let Some(r) = try_inline_call_with_type_args(
                            b,
                            nm,
                            args,
                            ast_arg_names,
                            None,
                            ast_type_args,
                            expected.as_ref(),
                        )
                    {
                        return r;
                    }
                }
            }
            // A bare call to a name the enclosing anon object closes
            // over invokes that captured value — even when the name also
            // names a member of the object. This is the
            // `Continuation(ctx) { override fun resumeWith(r) =
            // resumeWith(r) }` factory: Kotlin's inline expansion binds
            // the crossinline parameter, not the member, so a member
            // dispatch here would self-recurse. The captured name is
            // genuinely in lexical scope (a closed-over outer
            // param/local), so it shadows the same-named member for an
            // unqualified call. Resolve via `LoadCapture` + `CallValue`.
            // Skipped when a real local of that name shadows it, and
            // (since `is_lower_anon_capture` is only set while lowering an
            // anon object's own method bodies) a no-op everywhere else.
            if !*is_infix
                && let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && b.resolve(&segments[0].name).is_none()
                && is_lower_anon_capture(&segments[0].name)
            {
                let idx = b.record_capture(&segments[0].name);
                let callee_r = b.alloc_reg();
                b.push(Inst::LoadCapture { dst: callee_r, idx });
                let (args_start, count) = lower_arg_run(b, args);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                b.push(Inst::CallValue {
                    dst,
                    callee: callee_r,
                    args: args_start,
                    n_args: count,
                    arg_names,
                });
                return dst;
            }
            // Infix call `a fn b` lowers as `a.fn(b)` — the
            // dispatch site is a member call on the receiver
            // even when `fn` is a top-level extension.
            if *is_infix
                && args.len() == 2
                && let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
            {
                let recv = lower_expr(b, &args[0]);
                let (args_start, count) = lower_arg_run(b, &args[1..]);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                let nm = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::CallMember {
                    dst,
                    receiver: recv,
                    name: nm,
                    args: args_start,
                    n_args: count,
                    arg_names,
                });
                return dst;
            }
            // `suspend { … }` builder — the `suspend` keyword in
            // expression position is just a marker that the lambda
            // is suspending. Lower the lambda as-is; the IR's
            // existing lambda evaluator handles suspend bodies.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && segments[0].name == "suspend"
                && args.len() == 1
                && matches!(args[0], Expr::Lambda { .. })
            {
                return lower_expr(b, &args[0]);
            }
            // `contract { … }` (kotlin.contracts) is a compile-time
            // marker with no runtime effect. Its lambda is a DSL of
            // `returns()/implies(...)` calls that must NOT execute, so
            // drop the whole call and yield Unit.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && segments[0].name == "contract"
                && args.len() == 1
                && matches!(args[0], Expr::Lambda { .. })
            {
                return b.emit_const(Const::Unit);
            }
            // Self-call inside a tailrec fn → TailJump terminator
            // instead of a regular Call. Re-binds params and
            // restarts the function's entry block.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && b.tailrec_self().is_some_and(|n| n == segments[0].name)
            {
                let (args_start, count) = lower_arg_run(b, args);
                b.terminate(Terminator::TailJump {
                    args: args_start,
                    n_args: count,
                });
                // Start a dead block so subsequent lowering
                // has a valid current block (unreachable).
                let dead = b.alloc_block();
                b.switch_to(dead);
                return b.emit_const(Const::Unit);
            }
            // A single-name callee that resolves to a local binding
            // or parameter is a value invocation — the local
            // shadows any same-named top-level function — a lambda
            // parameter named `yield` (or any other top-level fn name)
            // must bind to the parameter at the call site, not to the
            // global function.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
            {
                // A bare call to a receiver-lambda param (`block: T.() -> R`)
                // dispatches with the enclosing `this` as receiver —
                // kotlinc rewrites `block()` to `this.block()`. This covers
                // the param reached as a *capture* from a nested lambda
                // (the resolved-own-param case is handled further below in
                // the `b.resolve(...)` block). Without it a captured
                // `block()` whose receiver lives only in the enclosing-this
                // chain runs against the wrong receiver (its creation-scope
                // `this`, e.g. a surrounding `runBlocking` scope).
                if b.is_receiver_lambda_param(&segments[0].name)
                    && b.resolve(&segments[0].name).is_none()
                    && b.knows_outer(&segments[0].name)
                {
                    let this_reg = if b.knows_outer("this") || b.is_lambda_body() {
                        Some(resolve_capture(b, "this"))
                    } else {
                        b.resolve("this")
                    };
                    if let Some(this_reg) = this_reg {
                        let callee_r = resolve_capture(b, &segments[0].name);
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::CallValueWithThis {
                            dst,
                            callee: callee_r,
                            receiver: this_reg,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
                // Kotlin keeps the function and property namespaces
                // separate: in call position `name(args)` resolves
                // to a member function of the enclosing class (own
                // or inherited) even when a same-named value/param
                // is in scope (`init { if (flag) flag(x) }` where
                // `flag` is both a ctor param and a method). Only a
                // genuine local function shadows; a same-named
                // member function outranks the value, so skip the
                // value-invocation path and fall through to member
                // dispatch. A bare param that is not a hierarchy
                // member still invokes the value.
                let redirect_to_member = {
                    let n = &segments[0].name;
                    let is_hierarchy_method = b
                        .owner_class()
                        .and_then(|oc| b.module.registry.hierarchy_methods.get(oc))
                        .is_some_and(|s| s.contains(n));
                    // Only intervene when a value/param actually
                    // shadows the method name — otherwise the
                    // normal member/function dispatch below is
                    // already correct and must not be rerouted.
                    is_hierarchy_method
                        && b.resolve(n).is_some()
                        && !b.is_local_fn(n)
                        && !b.is_local_ext_fn(n)
                        && b.resolve("this").is_some()
                };
                if redirect_to_member {
                    // `name(args)` where `name` names both a
                    // hierarchy member function and an in-scope
                    // value. Kotlin's choice depends on whether
                    // the value is invocable — known only at
                    // runtime — so emit `CallValueOrMember`: the
                    // value is invoked if invocable (a function
                    // type / `operator fun invoke`, the closer
                    // scope), otherwise the member function runs.
                    let this_reg = b.resolve("this").expect("this bound");
                    let callee_reg = b.resolve(&segments[0].name).expect("shadowing value");
                    let callee_reg = if b.is_boxed(&segments[0].name) {
                        let c = b.alloc_reg();
                        b.push(Inst::CellGet {
                            dst: c,
                            cell: callee_reg,
                        });
                        c
                    } else {
                        callee_reg
                    };
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::CallValueOrMember {
                        dst,
                        callee: callee_reg,
                        this_recv: this_reg,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
                if let Some(reg) = b.resolve(&segments[0].name) {
                    // A boxed `var` (captured + reassigned, e.g. a
                    // recursive `lateinit var f = { … f(…) … }`)
                    // holds a shared Cell; unwrap it to the
                    // current callable before invoking.
                    let callee_reg = if b.is_boxed(&segments[0].name) {
                        let c = b.alloc_reg();
                        b.push(Inst::CellGet { dst: c, cell: reg });
                        c
                    } else {
                        reg
                    };
                    // A bare call to a parameter whose declared
                    // type is a receiver-typed function
                    // (`block: T.() -> R`) dispatches with the
                    // enclosing `this` as the receiver — matching
                    // kotlinc's rewrite of `block()` to
                    // `this.block()` inside such a fn.
                    if b.is_receiver_lambda_param(&segments[0].name) {
                        let this_reg = b.resolve("this").or_else(|| {
                            if b.knows_outer("this") || b.is_lambda_body() {
                                let idx = b.record_capture("this");
                                let d = b.alloc_reg();
                                b.push(Inst::LoadCapture { dst: d, idx });
                                Some(d)
                            } else {
                                None
                            }
                        });
                        if let Some(this_reg) = this_reg {
                            let (args_start, count) = lower_arg_run(b, args);
                            let arg_names = intern_arg_names(b.module, ast_arg_names);
                            let dst = b.alloc_reg();
                            b.push(Inst::CallValueWithThis {
                                dst,
                                callee: callee_reg,
                                receiver: this_reg,
                                args: args_start,
                                n_args: count,
                                arg_names,
                            });
                            return dst;
                        }
                    }
                    // A bare call to a *local extension* function
                    // (`fun Appendable.two(x)` declared in this
                    // scope, called `two(n)`) takes the enclosing
                    // implicit receiver as its first `this` param;
                    // prepend it so the user args don't slot into
                    // the receiver position.
                    if b.is_local_ext_fn(&segments[0].name) {
                        let this_reg = b.resolve("this").or_else(|| {
                            if b.knows_outer("this") || b.is_lambda_body() {
                                let idx = b.record_capture("this");
                                let d = b.alloc_reg();
                                b.push(Inst::LoadCapture { dst: d, idx });
                                Some(d)
                            } else {
                                None
                            }
                        });
                        if let Some(this_reg) = this_reg {
                            let recv = b.alloc_reg();
                            b.push(Inst::Move {
                                dst: recv,
                                src: this_reg,
                            });
                            let mut vals: Vec<Reg> = Vec::with_capacity(args.len() + 1);
                            vals.push(recv);
                            for a in args {
                                vals.push(lower_expr(b, a));
                            }
                            let args_start = b.alloc_reg();
                            b.push(Inst::Move {
                                dst: args_start,
                                src: vals[0],
                            });
                            for v in &vals[1..] {
                                let slot = b.alloc_reg();
                                b.push(Inst::Move { dst: slot, src: *v });
                            }
                            let arg_names = intern_arg_names(b.module, ast_arg_names);
                            let dst = b.alloc_reg();
                            b.push(Inst::CallValue {
                                dst,
                                callee: callee_reg,
                                args: args_start,
                                n_args: (vals.len()) as u8,
                                arg_names,
                            });
                            return dst;
                        }
                    }
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_reg,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
            }
            // Whether a single-segment class-name call resolves to the
            // constructor rather than a same-named factory function.
            // Hoisted so both the direct-`Call` path and the
            // class-`NewInstance` path below share one decision (see the
            // detailed rationale at each `else` branch).
            let shadowed_by_class = match callee.as_ref() {
                Expr::Path { segments, .. }
                    if segments.len() == 1
                        && b.module.class_id(&segments[0].name).is_some() =>
                {
                    let name = &segments[0].name;
                    let nargs = args.len();
                    if matches!(args.last(), Some(Expr::Lambda { .. })) {
                        // A trailing lambda (`Widget { … }`) routes to a
                        // same-named factory with a function-typed param to
                        // receive it; only when none fits is it a ctor.
                        let factory_takes_lambda = b
                            .module
                            .func_index
                            .iter()
                            .filter(|(n, _)| n == name)
                            .filter_map(|(_, fid)| b.module.funcs.get(fid.0 as usize))
                            .any(|f| {
                                let last_vararg = f.params.last().is_some_and(|p| p.is_vararg);
                                let arity_ok = last_vararg || nargs <= f.params.len();
                                arity_ok
                                    && f.params.iter().any(|p| p.ty.name.starts_with("Function"))
                            });
                        !factory_takes_lambda
                    } else {
                        // No lambda — treat as a constructor when either the
                        // canonical same-named factory can't take that many
                        // args, OR no same-named factory is applicable to the
                        // supplied positional count at all (the too-few-args
                        // case, e.g. zero-arg `URLBuilder()` against factories
                        // that each need one arg). `decl_user_arity` (stub
                        // pass) reflects source defaults the lowered `Param`s
                        // drop, and resolves even for a body-less stub sibling.
                        let canonical_cant_take = b
                            .module
                            .func_id(name)
                            .and_then(|fid| b.module.funcs.get(fid.0 as usize))
                            .is_some_and(|f| {
                                let last_vararg = f.params.last().is_some_and(|p| p.is_vararg);
                                !last_vararg && nargs > f.params.len()
                            });
                        let any_factory_applicable = b
                            .module
                            .func_index
                            .iter()
                            .filter(|(n, _)| n == name)
                            .filter_map(|(_, fid)| b.module.decl_user_arity.get(&fid.0).copied())
                            .any(|(required, total, vararg)| {
                                let n = nargs as u32;
                                n >= required && (vararg || n <= total)
                            });
                        canonical_cant_take || !any_factory_applicable
                    }
                }
                _ => false,
            };
            // Path-callee with a registered top-level fn → Call{func}.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
            {
                // When a class and a top-level function share
                // A bound local / parameter / captured outer of
                // this name shadows a same-named top-level function
                // (Kotlin scoping). e.g. a Flow operator's
                // `crossinline transform` parameter shadows the
                // top-level `Flow.transform` operator: a bare
                // `transform(v)` inside the operator's lambda must
                // invoke the parameter, not recurse into the
                // operator. Route it through the captured value.
                // Only the captured-outer gap: a name captured
                // from an enclosing scope but not locally bound.
                // Bound locals already route correctly through the
                // resolved-callee path below, and forcing those
                // through `CallValue` mis-invokes a non-callable
                // local of the same name as a top-level fn.
                // Fire only on a genuine shadowing conflict: the
                // name is a captured outer *and* also a registered
                // top-level function. Without the top-level fn the
                // existing capture/global handling is already
                // correct (ordinary captured local funs/lambdas
                // like a recursive `fib`); intercepting those
                // mis-invokes a not-yet-initialised capture.
                let name0 = &segments[0].name;
                let shadowed_by_local = b.knows_outer(name0)
                    && b.resolve(name0).is_none()
                    && b.module.func_id(name0).is_some();
                if shadowed_by_local {
                    // Bind the lexically-enclosing `flow { }`
                    // collector as the receiver so a captured
                    // receiver-function lambda (Flow `map`'s
                    // `{ v -> emit(transform(v)) }`) targets the
                    // right downstream collector. A non-receiver
                    // value lambda (`{ it * 10 }`) ignores the
                    // bound receiver — `invoke_callable_with_this`
                    // only delivers it through a `this` capture or
                    // a zero-param positional, never displacing a
                    // declared value parameter.
                    let callee_r = resolve_capture(b, name0);
                    let this_reg = if b.knows_outer("this") || b.is_lambda_body() {
                        Some(resolve_capture(b, "this"))
                    } else {
                        b.resolve("this")
                    };
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    if let Some(recv) = this_reg {
                        b.push(Inst::CallValueWithThis {
                            dst,
                            callee: callee_r,
                            receiver: recv,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                    } else {
                        b.push(Inst::CallValue {
                            dst,
                            callee: callee_r,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                    }
                    return dst;
                }
                // FQN-precedence for the bare call: when this
                // module declares multiple functions sharing the
                // simple name (i.e. cross-package collision), an
                // explicit `import a.b.foo` routes `foo()` to
                // `a.b.foo` instead of whichever candidate landed
                // first in `func_index`. Matches Kotlin's
                // resolver where an explicit import beats any
                // wildcard / default candidate. Limited to the
                // collision case so single-candidate lookups stay
                // on their existing path (pack-internal calls
                // would otherwise be diverted by stray imports
                // they neither own nor expect to honour).
                let collision = b.module.funcs_by_simple_name(&segments[0].name).len() > 1;
                let imported_func_id = if collision {
                    b.module
                        .import_alias_in(segments[0].span.file, &segments[0].name)
                        .filter(|segs| segs.len() >= 2)
                        .and_then(|segs| b.module.func_id_by_fqn(&segs.join(".")))
                } else {
                    None
                };
                if let Some(func_id) = imported_func_id.filter(|_| !shadowed_by_class) {
                    // Skip the redirect when the resolved
                    // candidate is itself an extension whose
                    // dispatch the regular func_id path
                    // (this-prepended) handles correctly — the
                    // bare-call branch would lose the receiver.
                    let needs_this = b
                        .module
                        .funcs
                        .get(func_id.0 as usize)
                        .is_some_and(|f| f.params.first().is_some_and(|p| p.name == "this"));
                    if !needs_this {
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let type_args = intern_type_args(b.module, ast_type_args);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: func_id,
                            args: args_start,
                            n_args: count,
                            arg_names,
                            type_args,
                            exact: false,
                        });
                        return dst;
                    }
                }
                // Arity-aware bare-call lookup. The legacy
                // `Module::func_id` returns the first user-FQN or
                // first overall — when multiple same-named
                // overloads exist (e.g. `CharSequence.maxOf(selector)`
                // and the top-level `kotlin.comparisons.maxOf(a, b)`)
                // it can return one whose arity doesn't fit the
                // call. Prefer a candidate that matches arity.
                let want = args.len();
                let cands: Vec<FuncId> = b.module.funcs_by_simple_name(&segments[0].name).to_vec();
                let user_params = |f: &Func| {
                    if f.params.first().is_some_and(|p| p.name == "this") {
                        f.params.len() - 1
                    } else {
                        f.params.len()
                    }
                };
                let arity_match = |fid: &FuncId| -> bool {
                    b.module.funcs.get(fid.0 as usize).is_some_and(|f| {
                        // A bodyless `expect` decl can't be
                        // called directly — its actual lives
                        // in the host's intrinsic table.
                        // Skip it so the binding falls through
                        // to the implicit-alias / global
                        // path that resolves the actual.
                        //
                        // A vararg function accepts a variable argument
                        // count, so an exact `user_params == want` match is
                        // only coincidental (it fires when `want` equals the
                        // declared param count). Binding it via a plain
                        // `Call` here would feed the unpacked args to a body
                        // expecting a packed vararg array — e.g.
                        // `mutableListOf("x")` matching the consumed
                        // `mutableListOf(vararg elements)` (one declared
                        // param) and yielding `Unit`. Exclude varargs so
                        // every vararg call routes through the
                        // intrinsic / legacy path that packs them (the same
                        // path a non-coincidental arg count already takes).
                        !f.blocks.is_empty()
                            && f.params.last().is_none_or(|p| !p.is_vararg)
                            && user_params(f) == want
                    })
                };
                let non_ext = |fid: &FuncId| {
                    b.module
                        .funcs
                        .get(fid.0 as usize)
                        .is_some_and(|f| f.params.first().is_none_or(|p| p.name != "this"))
                };
                // `@LowPriorityInOverloadResolution` / `@Deprecated(ERROR)`
                // guard stubs are valid targets only when nothing else fits.
                let not_low = |fid: &FuncId| {
                    b.module
                        .funcs
                        .get(fid.0 as usize)
                        .is_some_and(|f| !f.low_priority)
                };
                // Trailing-lambda arity match: `f(a, …) { lambda }` binds the
                // lambda to the LAST (function-typed) param, with the
                // intermediate params defaulted — so `engine.async(ctx) { … }`
                // matches `CoroutineScope.async(context, start, block)`
                // (`want` = 2, three user params) and prepends `this`, rather
                // than falling through to the receiver-less guard.
                let last_arg_lambda = matches!(args.last(), Some(Expr::Lambda { .. }));
                let arity_match_tl = |fid: &FuncId| -> bool {
                    last_arg_lambda
                        && b.module.funcs.get(fid.0 as usize).is_some_and(|f| {
                            let up = user_params(f);
                            !f.blocks.is_empty()
                                && f.params.last().is_some_and(|p| p.ty.name.starts_with("Function"))
                                && up >= want
                                && want >= 1
                        })
                };
                // Names known to be backed by an intrinsic /
                // implicit-alias (kotlin.* top-level). When no
                // arity-matching IR func exists for these, decline
                // the bind so the call routes through the global
                // intrinsic path that the interp host populates.
                // Mirrors a subset of `klio_stdlib::IMPLICIT_ALIASES`;
                // klio-ir can't depend on klio-stdlib so the list
                // is duplicated here.
                let name_is_alias = matches!(
                    segments[0].name.as_str(),
                    "maxOf"
                        | "minOf"
                        | "max"
                        | "min"
                        | "print"
                        | "println"
                        | "listOf"
                        | "mutableListOf"
                        | "arrayListOf"
                        | "setOf"
                        | "mutableSetOf"
                        | "hashSetOf"
                        | "linkedSetOf"
                        | "mapOf"
                        | "mutableMapOf"
                        | "hashMapOf"
                        | "linkedMapOf"
                        | "arrayOf"
                        | "arrayOfNulls"
                        | "emptyArray"
                        | "emptyList"
                        | "emptySet"
                        | "emptyMap"
                        | "listOfNotNull"
                        | "setOfNotNull"
                        | "buildList"
                        | "buildSet"
                        | "buildMap"
                        | "buildString"
                        | "TODO"
                        | "error"
                        | "compareValues"
                        | "compareValuesBy"
                        | "compareBy"
                        | "compareByDescending"
                        | "naturalOrder"
                        | "reverseOrder"
                        | "sequenceOf"
                        | "emptySequence"
                        | "generateSequence"
                        | "sequence"
                );
                // A handful of alias names carry several consumed-source
                // overloads whose parameter shapes overlap by arity with
                // the call's argument count (e.g. `compareValuesBy(a, b,
                // selector)` vararg vs. `compareValuesBy(a, b, Comparator,
                // selector)`). Picking a same-named IR overload by arity
                // alone selects the wrong one — the host intrinsic
                // dispatches every form correctly, so decline the bind
                // for these and let the call route to the intrinsic.
                let intrinsic_owns_all = matches!(
                    segments[0].name.as_str(),
                    "compareValues" | "compareValuesBy"
                );
                // Declared user-param arity recorded by the driver in the
                // stub pass — available even for a sibling overload whose
                // body has not been lowered yet (a forward reference).
                // `funcs_by_simple_name` only returns top-level FuncIds, so
                // every candidate has a `decl_user_params` entry.
                let decl_arity = |fid: &FuncId| -> Option<u32> {
                    b.module.decl_user_params.get(&fid.0).copied()
                };
                // Kotlin resolves an unqualified call against the members
                // of the enclosing/implicit receiver before the top-level
                // function scope: a member function shadows a same-named
                // top-level function. When the call names a member of the
                // current receiver (own class member or — via the merged
                // `own_members` — an extension receiver's member) and no
                // local value/function shadows it, decline the top-level
                // bind so the member-call fallback below dispatches it on
                // `this`. The `require`/`check` contract calls that carry a
                // trailing lazy-message lambda are the stdlib intrinsics,
                // not a receiver member, so they stay on the top-level path.
                let contract_with_msg = matches!(
                    segments[0].name.as_str(),
                    "require" | "check" | "checkNotNull"
                ) && matches!(args.last(), Some(Expr::Lambda { .. }));
                let prefer_member = b.resolve("this").is_some()
                    && b.has_own_member(&segments[0].name)
                    && b.resolve(&segments[0].name).is_none()
                    && !b.is_local_fn(&segments[0].name)
                    && !b.is_local_ext_fn(&segments[0].name)
                    && !contract_with_msg;
                // An explicit argument cast (`f(x as T)`) is a strong,
                // deliberate overload signal — try it even when the name
                // would otherwise prefer an enclosing-member dispatch, so
                // a delegation like `async(context as CoroutineContext, …)`
                // (where `async` is an extension treated as a member of the
                // receiver scope) reaches the cast-matched overload instead
                // of re-selecting the deprecated `async(Job)` member form.
                let cast_pick = if intrinsic_owns_all {
                    None
                } else {
                    overload_pick_by_cast(b, &cands, args, want)
                };
                let bare_func_id: Option<FuncId> =
                    if intrinsic_owns_all || (prefer_member && cast_pick.is_none()) {
                        None
                    } else {
                        cast_pick
                        .or_else(|| {
                            cands
                                .iter()
                                .find(|fid| non_ext(fid) && arity_match(fid) && not_low(fid))
                                .copied()
                        })
                        .or_else(|| {
                            cands
                                .iter()
                                .find(|fid| !non_ext(fid) && arity_match(fid) && not_low(fid))
                                .copied()
                        })
                        // Trailing-lambda matches: the lambda binds the last
                        // function-typed param with intermediate params
                        // defaulted. Prefer a receiver-form (ext) overload so
                        // the active `this` is prepended, over a receiver-less
                        // guard stub — both before the legacy fallback.
                        .or_else(|| {
                            cands
                                .iter()
                                .find(|fid| !non_ext(fid) && arity_match_tl(fid) && not_low(fid))
                                .copied()
                        })
                        .or_else(|| {
                            cands
                                .iter()
                                .find(|fid| non_ext(fid) && arity_match_tl(fid) && not_low(fid))
                                .copied()
                        })
                        .or_else(|| {
                            if name_is_alias {
                                None
                            } else {
                                // No fully-lowered overload fits the call's
                                // arity. The legacy fallback returns the
                                // first same-named overload regardless of
                                // arity, which mis-binds a forward
                                // reference (e.g. the 1-arg `require(value)`
                                // delegating to the 2-arg
                                // `require(value) { … }` declared below it,
                                // baking an infinite self-call). When that
                                // fallback's declared arity does not fit,
                                // prefer a candidate whose *declared* arity
                                // does — using the stub-pass arity table so
                                // a not-yet-lowered sibling still resolves.
                                let fallback = b.module.func_id(&segments[0].name);
                                #[allow(clippy::cast_possible_truncation)]
                                let want_u32 = want as u32;
                                let fallback_fits = fallback
                                    .and_then(|fid| decl_arity(&fid))
                                    .is_none_or(|n| n == want_u32);
                                if fallback_fits {
                                    fallback
                                } else {
                                    cands
                                        .iter()
                                        .find(|fid| {
                                            non_ext(fid) && decl_arity(fid) == Some(want_u32)
                                        })
                                        .copied()
                                        .or_else(|| {
                                            cands
                                                .iter()
                                                .find(|fid| {
                                                    !non_ext(fid)
                                                        && decl_arity(fid) == Some(want_u32)
                                                })
                                                .copied()
                                        })
                                        .or(fallback)
                                }
                            }
                        })
                };
                // Prefer the same-name extension overload whose receiver type
                // matches the enclosing extension's declared receiver. Inside
                // `fun Source.forEach`, a bare `takeWhile { … }` must bind
                // `Source.takeWhile`, not the arity-equal stdlib
                // `CharSequence.takeWhile` the resolver picked above. Only
                // re-targets among bodied arity-matching extension candidates,
                // and only when the current pick does *not* already match the
                // enclosing receiver — so a correct same-receiver pick (e.g.
                // `Iterable.mapTo` inside `fun Iterable<T>.map`) is untouched.
                let recv_ty_owned = b.recv_ty().map(str::to_string);
                let bare_func_id = match (bare_func_id, recv_ty_owned) {
                    (Some(chosen), Some(recv)) => {
                        let matches_recv = |fid: &FuncId| {
                            b.module.funcs.get(fid.0 as usize).is_some_and(|f| {
                                !f.blocks.is_empty()
                                    && f.params.first().is_some_and(|p| {
                                        p.name == "this" && p.ty.name == recv
                                    })
                            })
                        };
                        if matches_recv(&chosen) {
                            Some(chosen)
                        } else {
                            cands
                                .iter()
                                .copied()
                                .find(|fid| arity_match(fid) && matches_recv(fid))
                                .or(Some(chosen))
                        }
                    }
                    (other, _) => other,
                };
                // The overload was selected from an explicit argument cast
                // (`f(x as T)`) and survived refinement — emit it as an
                // `exact` Call so runtime overload re-resolution does not
                // override the cast by the argument's runtime value type.
                let was_cast = cast_pick.is_some() && bare_func_id == cast_pick;
                if let Some(func_id) = bare_func_id.filter(|_| !shadowed_by_class) {
                    // Extension fn called by its bare name from inside
                    // a receiver-typed scope: prepend the active
                    // `this` reg so `this.launch(block)` flows through
                    // the same Call inst the qualified form would
                    // emit. Detected by the resolved func declaring
                    // `this` as its first param.
                    let needs_this = b
                        .module
                        .funcs
                        .get(func_id.0 as usize)
                        .is_some_and(|f| f.params.first().is_some_and(|p| p.name == "this"));
                    if needs_this {
                        // Resolve a `this` reg even from a lambda
                        // body that hasn't bound it locally — fall
                        // back to a capture so the eval frame
                        // loads the receiver value populated by
                        // `invoke_callable_with_this`.
                        let this_reg_opt: Option<Reg> = b.resolve("this").or_else(|| {
                            if b.knows_outer("this") || b.is_lambda_body() {
                                let idx = b.record_capture("this");
                                let dst = b.alloc_reg();
                                b.push(Inst::LoadCapture { dst, idx });
                                b.bind("this".to_string(), dst);
                                Some(dst)
                            } else {
                                None
                            }
                        });
                        if let Some(this_reg) = this_reg_opt {
                            let mut all: Vec<Expr> = Vec::with_capacity(args.len() + 1);
                            // Synthesise a Path("this") arg expr; the
                            // existing arg-run path resolves it back
                            // to the bound reg.
                            let synth = Expr::Path {
                                segments: vec![klio_ast::Ident {
                                    name: "this".to_string(),
                                    span: expr_span(callee.as_ref()),
                                }],
                                span: expr_span(callee.as_ref()),
                            };
                            all.push(synth);
                            all.extend(args.iter().cloned());
                            let (args_start, count) = lower_arg_run(b, &all);
                            // Trailing-lambda routing for extension
                            // fns with default-valued middle params
                            // (`fun T.launch(context = …, block)` —
                            // `obj.launch { … }` skips the default
                            // context, assigns the lambda to `block`).
                            // Build per-arg names by aligning user-
                            // supplied args with the func's tail
                            // params and emitting an explicit
                            // arg-name for the last user-supplied
                            // arg so call_func_named slots it
                            // correctly.
                            let mut arg_names = intern_arg_names(b.module, ast_arg_names);
                            let target_params: Vec<String> = b
                                .module
                                .funcs
                                .get(func_id.0 as usize)
                                .map(|f| f.params.iter().map(|p| p.name.clone()).collect())
                                .unwrap_or_default();
                            let user_arg_count = all.len() - 1;
                            // Only the trailing-LAMBDA case routes the
                            // last user arg to the target's last param
                            // (`obj.launch(ctx=default) { block }`). A
                            // non-lambda last arg with fewer args than
                            // params is ordinary positional/vararg/
                            // default filling — e.g. `split(" ")` where
                            // `" "` is a vararg delimiter, NOT the
                            // trailing `limit` param. Re-tagging it as
                            // the last param mis-binds it.
                            let trailing_lambda_call =
                                matches!(args.last(), Some(Expr::Lambda { .. }));
                            if !target_params.is_empty()
                                && user_arg_count >= 1
                                && (1 + user_arg_count) < target_params.len()
                                && ast_arg_names.iter().all(std::option::Option::is_none)
                                && trailing_lambda_call
                            {
                                // Synthesise arg_names: positional for
                                // injected `this` + each user arg,
                                // then re-tag the last user arg with
                                // the last param's name so it routes
                                // to that slot.
                                let mut tagged_slots: Vec<Option<crate::ConstId>> =
                                    vec![None; all.len()];
                                let last_param = target_params.last().cloned();
                                if let Some(p_name) = last_param {
                                    let cid = b.module.intern_const(Const::String(p_name));
                                    let last_idx = tagged_slots.len() - 1;
                                    tagged_slots[last_idx] = Some(cid);
                                }
                                arg_names = tagged_slots;
                            }
                            let type_args = intern_type_args(b.module, ast_type_args);
                            // Unqualified call inside a receiver
                            // scope: a member of the (possibly
                            // smart-cast) implicit receiver outranks
                            // a same-named top-level extension. Route
                            // through `call_member` on `this` so the
                            // full precedence applies: receiver
                            // member (using the runtime subtype),
                            // then the builtin/stdlib intrinsic,
                            // then the best-by-receiver extension
                            // fallback.
                            // A direct `Call` to one resolved
                            // `func_id` bypassed all of that and
                            // could recurse (`resumeCancellableWith`)
                            // or mis-bind on a builtin receiver. The
                            // defaulted-middle-param trailing-lambda
                            // arg-name synthesis is extension-fn
                            // specific, so keep the direct `Call`
                            // there.
                            let synth_names_needed = !target_params.is_empty()
                                && user_arg_count >= 1
                                && (1 + user_arg_count) < target_params.len()
                                && ast_arg_names.iter().all(std::option::Option::is_none)
                                && trailing_lambda_call;
                            if !synth_names_needed && !was_cast {
                                // Kotlin: a member of the
                                // (smart-cast) implicit receiver
                                // outranks a same-named top-level
                                // extension. Route through
                                // `call_member` on `this` so the
                                // full precedence applies —
                                // receiver member (incl. a runtime
                                // subtype's), then builtin/stdlib
                                // intrinsic, then the
                                // best-by-receiver extension-fn
                                // fallback. A direct `Call` to one
                                // by-name `func_id` bypassed this
                                // (recursed for
                                // `resumeCancellableWith`,
                                // mis-bound on `Result`).
                                // An explicit argument cast
                                // (`async(context as CoroutineContext,
                                // …)`) is excepted: the cast already
                                // selected the overload, and re-routing
                                // through `call_member` would re-resolve
                                // by the *erased* runtime value type
                                // (here a `Job`), re-selecting the
                                // deprecated `async(Job)` form and
                                // recursing. Emit the direct exact Call.
                                let (uargs_start, ucount) = lower_arg_run(b, args);
                                let uarg_names = intern_arg_names(b.module, ast_arg_names);
                                let nmc = b
                                    .module
                                    .intern_const(Const::String(segments[0].name.clone()));
                                let dst = b.alloc_reg();
                                // In a receiver-lambda body the
                                // implicit `this` is a capture that
                                // a `this`-binding invoke may have
                                // displaced (e.g. `flow { forEach {
                                // emit(it) } }` inside
                                // `List.asFlow()`: `this` is the
                                // FlowCollector, but `forEach`
                                // targets the enclosing `this@asFlow`
                                // receiver). CallMemberOrGlobal adds
                                // the enclosing-`this` and global /
                                // extension fallbacks that plain
                                // CallMember lacks, so the call
                                // resolves against the lexically
                                // enclosing receiver when the lambda
                                // receiver has no such member.
                                if b.is_lambda_body() {
                                    let this_idx = b.record_capture("this");
                                    b.push(Inst::CallMemberOrGlobal {
                                        dst,
                                        this_idx,
                                        name: nmc,
                                        args: uargs_start,
                                        n_args: ucount,
                                        arg_names: uarg_names,
                                    });
                                    return dst;
                                }
                                b.push(Inst::CallMember {
                                    dst,
                                    receiver: this_reg,
                                    name: nmc,
                                    args: uargs_start,
                                    n_args: ucount,
                                    arg_names: uarg_names,
                                });
                                return dst;
                            }
                            let dst = b.alloc_reg();
                            let _ = this_reg;
                            b.push(Inst::Call {
                                dst,
                                func: func_id,
                                args: args_start,
                                n_args: count,
                                arg_names,
                                type_args,
                                exact: was_cast,
                            });
                            return dst;
                        }
                        // No `this` in scope — fall through to the
                        // unmodified Call below; runtime will error
                        // with a clearer "missing receiver" diag.
                    }
                    let callee_is_tailrec = b
                        .module
                        .funcs
                        .get(func_id.0 as usize)
                        .is_some_and(|f| f.is_tailrec)
                        || b.module
                            .tailrec_fn_names
                            .iter()
                            .any(|n| n == &segments[0].name);
                    if b.tailrec_self().is_some()
                        && callee_is_tailrec
                        && ast_arg_names.iter().all(std::option::Option::is_none)
                    {
                        let (args_start, count) = lower_arg_run(b, args);
                        b.terminate(Terminator::TailCallFunc {
                            func: func_id,
                            args: args_start,
                            n_args: count,
                        });
                        let dead = b.alloc_block();
                        b.switch_to(dead);
                        return b.emit_const(Const::Unit);
                    }
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let type_args = intern_type_args(b.module, ast_type_args);
                    let dst = b.alloc_reg();
                    b.push(Inst::Call {
                        dst,
                        func: func_id,
                        args: args_start,
                        n_args: count,
                        arg_names,
                        type_args,
                        exact: was_cast,
                    });
                    return dst;
                }
            }
            // Path-callee with a registered class name. When the call is a
            // constructor (`shadowed_by_class`) build the instance. When a
            // same-named factory should handle it instead but no single
            // `func_id` was resolved above (overloaded — `bare_func_id` was
            // `None`, so the direct-`Call` path was skipped), route through
            // `CallMemberOrGlobal` so runtime overload resolution picks the
            // right factory by argument types. Without this an overloaded
            // factory like `URLBuilder(urlString)` / `URLBuilder(url)` /
            // `URLBuilder(builder)` fell through to `NewInstance` and the
            // argument was bound to the constructor's first param.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && let Some(class_id) = b.module.class_id(&segments[0].name)
            {
                let (args_start, count) = lower_arg_run(b, args);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                if shadowed_by_class {
                    b.push(Inst::NewInstance {
                        dst,
                        class: class_id,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                } else {
                    let this_idx = b.record_capture("this");
                    let nmc = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::CallMemberOrGlobal {
                        dst,
                        this_idx,
                        name: nmc,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                }
                return dst;
            }
            // Inside a method/extension body: unqualified `name(...)`
            // that didn't match a local / top-level fn / class is
            // most likely a method call on `this`. Emit
            // `this.name(args)` via CallMember so the receiver's
            // class dispatch (including IR-native FuncId lookup)
            // fires.
            if let Expr::Path { segments, .. } = callee.as_ref() {
                // A bare contract call carrying a trailing
                // lazy-message lambda — `require(cond) { "msg" }` /
                // `check(...) { ... }` — is the stdlib contract,
                // not a same-named user member. Kotlin resolves
                // this by applicability; here the trailing lambda
                // is the discriminator.
                let contract_with_msg = segments.len() == 1
                    && matches!(
                        segments[0].name.as_str(),
                        "require" | "check" | "checkNotNull"
                    )
                    && matches!(args.last(), Some(Expr::Lambda { .. }));
                if segments.len() == 1
                    && !contract_with_msg
                    && b.resolve(&segments[0].name).is_none()
                    && !b.knows_outer(&segments[0].name)
                    // Only emit this.name(...) when the owning
                    // class declares this name (method or
                    // property); otherwise it's a global call
                    // and the normal CallValue path should fire.
                    && b.has_own_member(&segments[0].name)
                    && let Some(this_reg) = b.resolve("this")
                {
                    // Private own-class methods bind statically:
                    // a `private fun` is invisible to subclasses,
                    // so a bare call to one must reach the
                    // declaring-class implementation rather than
                    // a same-named override in a subclass that
                    // happens to be the runtime receiver.
                    if let Some(fid) = b.private_method_fid(&segments[0].name) {
                        // Prepend `this` as the first positional
                        // argument; the static call's param[0] is
                        // the implicit receiver. The arg-names
                        // vector also gets a leading None so a
                        // named-arg call (`pick(b = 5)`) doesn't
                        // mis-bind the `this` slot to the user's
                        // first named parameter.
                        let args_start = b.alloc_reg();
                        b.push(Inst::Move {
                            dst: args_start,
                            src: this_reg,
                        });
                        for (i, a) in args.iter().enumerate() {
                            let r = lower_expr(b, a);
                            b.push(Inst::Move {
                                dst: Reg(args_start.0 + i as u32 + 1),
                                src: r,
                            });
                        }
                        let mut user_arg_names: Vec<Option<String>> = vec![None];
                        user_arg_names.extend(ast_arg_names.iter().cloned());
                        let arg_names = intern_arg_names(b.module, &user_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: fid,
                            args: args_start,
                            n_args: args.len() as u8 + 1,
                            arg_names,
                            type_args: Vec::new(),
                            exact: false,
                        });
                        return dst;
                    }
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::CallMember {
                        dst,
                        receiver: this_reg,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
            }
            // Unresolved bare-name call. Inside a lambda body that
            // may be invoked with a this-binding, dispatch through
            // CallMemberOrGlobal so a method on the captured this
            // wins over a top-level lookup. For non-lambda frames
            // (or lambdas not this-bound) the captured this is
            // Null and the inst falls back to a regular global
            // call.
            if let Expr::Path { segments, .. } = callee.as_ref()
                && segments.len() == 1
                && b.resolve(&segments[0].name).is_none()
                && !b.knows_outer(&segments[0].name)
                && b.module.class_id(&segments[0].name).is_none()
                && b.module.func_id(&segments[0].name).is_none()
            {
                // Inside a method / extension body `this` is a
                // bound param (not a capture). A bare primitive
                // conversion call — `toInt()` in `fun Byte.and(o)
                // = toInt() and o` — is a member call on the
                // receiver. The receiver is a primitive with no
                // class member table, and CallMemberOrGlobal only
                // sees a *captured* `this` (Null for a param), so
                // dispatch straight on the `this` reg. Limited to
                // the fixed set of stdlib conversion names, none
                // of which is ever a top-level function, so
                // ordinary global calls are unaffected.
                // A bare call to a name the enclosing anon object
                // closes over invokes that lexically-captured
                // value. Read it via `LoadCapture` (this instance's
                // snapshot) and `CallValue` so a captured closure
                // keeps its own captures and cannot recurse onto a
                // same-named capture of an enclosing anon method.
                if is_lower_anon_capture(&segments[0].name) {
                    let idx = b.record_capture(&segments[0].name);
                    let callee_r = b.alloc_reg();
                    b.push(Inst::LoadCapture { dst: callee_r, idx });
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
                let is_primitive_conv = matches!(
                    segments[0].name.as_str(),
                    "toInt"
                        | "toLong"
                        | "toByte"
                        | "toShort"
                        | "toDouble"
                        | "toFloat"
                        | "toChar"
                        | "toBoolean"
                        | "toUInt"
                        | "toULong"
                        | "toUByte"
                        | "toUShort"
                );
                if is_primitive_conv && let Some(this_reg) = b.resolve("this") {
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b
                        .module
                        .intern_const(Const::String(segments[0].name.clone()));
                    b.push(Inst::CallMember {
                        dst,
                        receiver: this_reg,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
                let this_idx = b.record_capture("this");
                let (args_start, count) = lower_arg_run(b, args);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                let nm = b
                    .module
                    .intern_const(Const::String(segments[0].name.clone()));
                b.push(Inst::CallMemberOrGlobal {
                    dst,
                    this_idx,
                    name: nm,
                    args: args_start,
                    n_args: count,
                    arg_names,
                });
                return dst;
            }
            // Built-in stdlib companion shortcuts: `Result.success(x)`,
            // `Result.failure(e)`, etc. The callee parses as
            // Member { Path("Result"), "success" }; rewrite to a
            // direct stdlib FQN dispatch. The class_id check is
            // intentionally omitted for these specific names — once
            // upstream `kotlin/util/Result.kt` is shipped, klio's
            // class table contains a `Result` entry and the shortcut
            // would otherwise be skipped, causing the call to fall
            // through to a member-dispatch path that doesn't know
            // about the Companion.
            if let Expr::Member {
                receiver: recv_box,
                name: mname,
                ..
            } = callee.as_ref()
                && let Expr::Path { segments, .. } = recv_box.as_ref()
                && segments.len() == 1
                && b.resolve(&segments[0].name).is_none()
                && !b.knows_outer(&segments[0].name)
            {
                let head = &segments[0].name;
                let companion_fqns: &[(&str, &str, &str)] = &[
                    ("Result", "success", "kotlin.Result.Companion.success"),
                    ("Result", "failure", "kotlin.Result.Companion.failure"),
                ];
                for (cls, method, fqn) in companion_fqns {
                    if head == cls && mname.name == *method {
                        let callee_r = b.alloc_reg();
                        let n = b.module.intern_const(Const::String((*fqn).to_string()));
                        b.push(Inst::LoadGlobal {
                            dst: callee_r,
                            name: n,
                        });
                        let (args_start, count) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let dst = b.alloc_reg();
                        b.push(Inst::CallValue {
                            dst,
                            callee: callee_r,
                            args: args_start,
                            n_args: count,
                            arg_names,
                        });
                        return dst;
                    }
                }
            }
            // Package-qualified call to a user / pack top-level
            // function. `func_index` is keyed by simple name (the
            // package prefix lives on the decl's `fqn`), so resolve
            // the trailing segment and emit the same `Inst::Call`
            // the bare-name form uses; eval's `pick_overload` then
            // selects the right shape by runtime arg types. Only
            // fires when the tail names a module function, so
            // intrinsic FQNs still take the LoadGlobal path below.
            if let Expr::Member { .. } = callee.as_ref()
                && let Some(fqn) = collect_dotted_fqn(callee)
                && let (Some(head), Some(tail)) = (fqn.split('.').next(), fqn.rsplit('.').next())
            {
                // A real package root (`kotlin.…`, `kotlinx.…`,
                // …) is never a member of an enclosing
                // receiver, even when `this` is bound — Kotlin
                // resolves the qualified call against the
                // package, not the receiver. Allow the FQN
                // flattening through in that case so a
                // `kotlin.synchronized(this, block)` call
                // inside an extension function body doesn't
                // get misread as `this.kotlin.synchronized`.
                let head_is_real_pkg = is_pkg_root(head);
                if tail != fqn
                    && is_package_head(head)
                    && (head_is_real_pkg || !b.is_lambda_body())
                    && b.resolve(head).is_none()
                    && !b.knows_outer(head)
                    && b.module.class_id(head).is_none()
                    && (head_is_real_pkg || b.resolve("this").is_none())
                {
                    // Arity-aware lookup for FQN-flatten calls:
                    // `kotlin.math.max(3, 9)` must bind to the
                    // 2-arg `max` (`kotlin.comparisons.max` /
                    // `kotlin.math.max`), not the 1-param
                    // `CharSequence.max()` from `_Strings.kt`.
                    // Prefer an FQN match, then arity-matched
                    // non-extension, then any FQN match.
                    let want = args.len();
                    let prefix = &fqn;
                    let cands: Vec<FuncId> = b.module.funcs_by_simple_name(tail).to_vec();
                    let pick = cands
                        .iter()
                        .find(|fid| {
                            let Some(f) = b.module.funcs.get(fid.0 as usize) else {
                                return false;
                            };
                            f.fqn == *prefix && f.params.len() == want
                        })
                        .or_else(|| {
                            cands.iter().find(|fid| {
                                let Some(f) = b.module.funcs.get(fid.0 as usize) else {
                                    return false;
                                };
                                let first_is_this =
                                    f.params.first().is_some_and(|p| p.name == "this");
                                !first_is_this && f.params.len() == want
                            })
                        })
                        .copied();
                    if let Some(func_id) = pick {
                        let (args_start, n_args) = lower_arg_run(b, args);
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let type_args = intern_type_args(b.module, ast_type_args);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: func_id,
                            args: args_start,
                            n_args,
                            arg_names,
                            type_args,
                            exact: false,
                        });
                        return dst;
                    }
                }
            }
            // Fully-qualified callee like `kotlin.math.abs(x)` →
            // resolve the FQN as a global and CallValue against the
            // resulting intrinsic / function value. Avoids the
            // chained-GetField that would fail at `kotlin` itself.
            if let Expr::Member { .. } = callee.as_ref()
                && let Some(fqn) = collect_dotted_fqn(callee)
                && let Some(head) = fqn.split('.').next()
            {
                let head_is_real_pkg = is_pkg_root(head);
                if is_package_head(head)
                            && (head_is_real_pkg || !b.is_lambda_body())
                            && b.resolve(head).is_none()
                            && !b.knows_outer(head)
                            && b.module.class_id(head).is_none()
                            // When `this` is bound (we're inside a
                            // method body) the head could be a
                            // field on `this`; don't treat it as a
                            // package FQN unless that field doesn't
                            // exist on the receiver class. A real
                            // package root (`kotlin.…`, `kotlinx.…`)
                            // is never a member of `this`, so allow
                            // it through unconditionally.
                            && (head_is_real_pkg || b.resolve("this").is_none())
                {
                    let callee_r = b.alloc_reg();
                    let n = b.module.intern_const(Const::String(fqn));
                    b.push(Inst::LoadGlobal {
                        dst: callee_r,
                        name: n,
                    });
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    b.push(Inst::CallValue {
                        dst,
                        callee: callee_r,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
            }
            // Lower the callee's receiver / value separately so the
            // dispatcher knows whether to emit CallMember or
            // CallValue.
            if let Expr::Member { receiver, name, .. } = callee.as_ref() {
                // Receiver-typed lambda invocation: `list.block()`
                // where `block: T.() -> R` is a local. Lower
                // as CallValueWithThis so the host binds the
                // receiver as `this` inside the lambda body.
                // Gated tight so stdlib member calls like
                // `xs.sorted()` aren't hijacked by a shared
                // name.
                // Only fire when the local name is bound AND
                // the local has a function-like type. We
                // can't check types at IR-lowering time, but
                // most class methods aren't shadowed by
                // locals — gate the arm narrowly on "name is
                // a known param of the enclosing fn".
                // A bound local named `name` shadows any member:
                // `recv.name(args)` invokes that local. This
                // covers a local extension function (`fun
                // List<T>.mid() = …`, whose closure takes the
                // receiver as its implicit `this` param) and a
                // receiver-typed lambda parameter (`block: T.() ->
                // R`). In both cases the receiver is the first
                // positional argument (the closure's param 0 is
                // `this`), so a plain CallValue suffices and we
                // avoid the unsupported call_value_with_this.
                // Only a local *function* (or function-typed
                // param like `block: T.() -> R`) shadows
                // `recv.name()` — a local `val`/`var` of the same
                // name must NOT hijack a stdlib/member call
                // (`val sorted = …; xs.sorted()` is the member).
                // A captured outer name that holds a callable
                // (e.g. a `Sink.(Int) -> Unit` parameter closed
                // over by a returned lambda, invoked as
                // `sink.g(v)`) shadows a member exactly like a
                // local param/fn. CallMemberOrValue still tries
                // the receiver's member first, so a captured
                // non-callable can't hijack a real member call.
                let anon_cap = is_lower_anon_capture(&name.name)
                    && b.resolve(&name.name).is_none()
                    && !b.is_local_fn(&name.name)
                    && !b.is_param(&name.name)
                    && !b.knows_outer(&name.name);
                let local_callable = b.is_local_fn(&name.name)
                    || b.is_param(&name.name)
                    || b.knows_outer(&name.name)
                    || anon_cap;
                if local_callable {
                    // For an anon-object method a captured name
                    // reaches the body as a lexical capture: record
                    // it and emit `LoadCapture` so it reads this
                    // instance's snapshot (a captured closure keeps
                    // its own captures and cannot collide with a
                    // same-named capture of an enclosing anon
                    // method). Otherwise capture on demand.
                    let local_reg = if anon_cap {
                        let idx = b.record_capture(&name.name);
                        let r = b.alloc_reg();
                        b.push(Inst::LoadCapture { dst: r, idx });
                        r
                    } else {
                        resolve_capture(b, &name.name)
                    };
                    // `recv.name(args)` where `name` is also a
                    // callable local/param. Kotlin dispatches the
                    // member when `recv`'s type has it, and only
                    // the local (a local extension fn, or a
                    // `T.() -> R` param invoked as `recv.block()`)
                    // when it does not. That needs the receiver's
                    // runtime type, so emit CallMemberOrValue: the
                    // member wins if present, else the local is
                    // invoked with `recv` prepended.
                    let recv = lower_receiver(b, receiver);
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let nm = b.module.intern_const(Const::String(name.name.clone()));
                    let dst = b.alloc_reg();
                    b.push(Inst::CallMemberOrValue {
                        dst,
                        receiver: recv,
                        name: nm,
                        fallback: local_reg,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
                // `super.method(...)` — emit `CallSuper` so the
                // host walks the parent class chain rather
                // than re-entering the leaf class's override.
                // `super<Klazz>.method()` passes Klazz so the
                // host dispatches against that specific
                // supertype.
                if let Expr::Super {
                    qualifier, label, ..
                } = receiver.as_ref()
                    && let Some(this_reg) = b.resolve("this")
                    && let Some(owner) = b.owner_class().map(std::string::ToString::to_string)
                {
                    let (args_start, count) = lower_arg_run(b, args);
                    let arg_names = intern_arg_names(b.module, ast_arg_names);
                    let dst = b.alloc_reg();
                    let nm = b.module.intern_const(Const::String(name.name.clone()));
                    let oc = b.module.intern_const(Const::String(owner));
                    // `super<Q>` uses `qualifier` (type
                    // ref); `super@Q` uses `label` (an
                    // identifier).
                    let qual_const = qualifier
                        .as_ref()
                        .map(|t| b.module.intern_const(Const::String(t.name.name.clone())))
                        .or_else(|| {
                            label
                                .as_ref()
                                .map(|id| b.module.intern_const(Const::String(id.name.clone())))
                        });
                    b.push(Inst::CallSuper {
                        dst,
                        receiver: this_reg,
                        owner_class: oc,
                        qualifier: qual_const,
                        name: nm,
                        args: args_start,
                        n_args: count,
                        arg_names,
                    });
                    return dst;
                }
                // Statically rebind `(e as T).f(args)` to the `f`
                // overload whose first-param type is `T`. Upstream
                // bodies (`String.padStart` → `(this as CharSequence).
                // padStart(...).toString()`) rely on JVM-style
                // static-receiver dispatch; klio dispatches by
                // the runtime value's type, so without this the
                // call rebinds to the `String` overload and
                // recurses. Only fires for non-safe `as`-casts —
                // safe `as?` semantics need a null branch.
                if let Expr::As {
                    ty: cast_ty,
                    safe: false,
                    ..
                } = receiver.as_ref()
                {
                    let want_user = args.len();
                    let chosen = b
                        .module
                        .funcs_by_simple_name(&name.name)
                        .iter()
                        .find_map(|fid| {
                            let f = b.module.funcs.get(fid.0 as usize)?;
                            if f.blocks.is_empty() {
                                return None;
                            }
                            let p0 = f.params.first()?;
                            if p0.name != "this" || p0.ty.name != cast_ty.name.name {
                                return None;
                            }
                            let user = f.params.len() - 1;
                            let arity_ok = user == want_user
                                || (want_user < user
                                    && f.params[(1 + want_user)..]
                                        .iter()
                                        .all(|p| p.default.is_some() || p.is_vararg))
                                || (want_user > user
                                    && f.params.last().is_some_and(|p| p.is_vararg));
                            if arity_ok { Some(*fid) } else { None }
                        });
                    if let Some(func_id) = chosen {
                        // Build a contiguous arg run: receiver at
                        // slot 0, user args following. lower the
                        // receiver expression (the `as`-cast is a
                        // no-op on klio runtime values, but the
                        // emitted `Inst::Cast` keeps the schema
                        // honest), then lower each user arg.
                        let recv_reg = lower_receiver(b, receiver);
                        let mut arg_regs: Vec<Reg> = Vec::with_capacity(args.len() + 1);
                        arg_regs.push(recv_reg);
                        for a in args {
                            arg_regs.push(lower_expr(b, a));
                        }
                        let n = arg_regs.len() as u8;
                        let start = b.alloc_reg();
                        b.push(Inst::Move {
                            dst: start,
                            src: arg_regs[0],
                        });
                        for r in &arg_regs[1..] {
                            let slot = b.alloc_reg();
                            b.push(Inst::Move { dst: slot, src: *r });
                        }
                        let arg_names = intern_arg_names(b.module, ast_arg_names);
                        let type_args = intern_type_args(b.module, ast_type_args);
                        let dst = b.alloc_reg();
                        b.push(Inst::Call {
                            dst,
                            func: func_id,
                            args: start,
                            n_args: n,
                            arg_names,
                            type_args,
                            exact: false,
                        });
                        return dst;
                    }
                }
                let recv = lower_receiver(b, receiver);
                let (args_start, count) = lower_arg_run(b, args);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                let nm = b.module.intern_const(Const::String(name.name.clone()));
                b.push(Inst::CallMember {
                    dst,
                    receiver: recv,
                    name: nm,
                    args: args_start,
                    n_args: count,
                    arg_names,
                });
                dst
            } else {
                let callee_r = lower_expr(b, callee);
                let (args_start, count) = lower_arg_run(b, args);
                let arg_names = intern_arg_names(b.module, ast_arg_names);
                let dst = b.alloc_reg();
                b.push(Inst::CallValue {
                    dst,
                    callee: callee_r,
                    args: args_start,
                    n_args: count,
                    arg_names,
                });
                dst
            }
        }
        Expr::DoWhile { body, cond, .. } => {
            let body_blk = b.alloc_block();
            let exit = b.alloc_block();
            b.terminate(Terminator::Goto(body_blk));

            b.switch_to(body_blk);
            b.push_loop(None, body_blk, exit);
            if let Some(body) = body {
                let _ = lower_expr(b, body);
            }
            b.pop_loop();
            let c = lower_expr(b, cond);
            b.terminate(Terminator::Branch {
                cond: c,
                t: body_blk,
                f: exit,
            });

            b.switch_to(exit);
            b.emit_const(Const::Unit)
        }
        Expr::Return { value, label, .. } => {
            let r = value.as_ref().map(|e| {
                // `return …` puts the function's declared return type in
                // tail position for reified-inline type inference. Only a
                // bare `return` (no label) targets the enclosing fn; a
                // labeled return goes to a lambda and keeps no hint.
                let prev = if label.is_none() {
                    Some(b.push_expected(b.declared_return()))
                } else {
                    None
                };
                let lowered = lower_expr(b, e);
                if let Some(prev) = prev {
                    b.restore_expected(prev);
                }
                lowered
            });
            // An unlabeled `return` inside an inlined body returns
            // from that inline fn — which, inlined, is the call's
            // value. Spliced lambda-arg bodies clear the inline-return
            // target, so their non-local `return` falls through to
            // the caller path below (Kotlin non-local semantics).
            if label.is_none()
                && let Some((res, join)) = b.inline_active_return()
            {
                if let Some(rr) = r {
                    b.push(Inst::Move { dst: res, src: rr });
                }
                // Replay every active `finally { … }` block
                // inline before exiting, matching JVM `try-
                // finally` bytecode shape: each non-fallthrough
                // exit from the try body copies the finally body
                // at the exit point. Lower top-down (innermost
                // first); each replay's own statements run with
                // the remaining (outer) finallys still active so
                // a `return` inside a finally body skips its own
                // finally but still threads any further outers.
                let pending = b.active_finallys();
                if !pending.is_empty() {
                    let prior = b.swap_finally_stack(Vec::new());
                    for (idx, blk) in pending.iter().rev().enumerate() {
                        let outer = prior[..prior.len() - (idx + 1)].to_vec();
                        b.swap_finally_stack(outer);
                        let _ = lower_block(b, blk);
                    }
                    b.swap_finally_stack(prior);
                }
                b.terminate(Terminator::Goto(join));
                let dead = b.alloc_block();
                b.switch_to(dead);
                return b.emit_const(Const::Unit);
            }
            // `return@<inlineFnName>` inside a spliced inline-argument
            // lambda is a local return from that lambda invocation.
            if let Some(lbl) = label.as_ref()
                && let Some((res, end)) = b.inline_lambda_ret_for(&lbl.name)
            {
                if let Some(rr) = r {
                    b.push(Inst::Move { dst: res, src: rr });
                }
                b.terminate(Terminator::Goto(end));
                let dead = b.alloc_block();
                b.switch_to(dead);
                return b.emit_const(Const::Unit);
            }
            if let Some(lbl) = label.as_ref() {
                if b.current_inline_fn().is_some() {
                    // Inside a spliced inline body: a plain `Return`
                    // would exit the caller's whole function, not the
                    // labeled frame. `LabeledReturn` walks until the
                    // function whose name matches `lbl` catches it.
                    b.terminate(Terminator::LabeledReturn(lbl.name.clone(), r));
                } else {
                    // Non-spliced closure body: `return@label` here is
                    // a local return from the lambda invocation.
                    b.terminate(Terminator::Return(r));
                }
            } else if b.is_lambda_body() && !b.is_named_local_fn() {
                b.terminate(Terminator::NonLocalReturn(r));
            } else {
                b.terminate(Terminator::Return(r));
            }
            // The post-return path is unreachable; allocate a fresh
            // block so caller code that emits anything after sees a
            // distinct cursor.
            let dead = b.alloc_block();
            b.switch_to(dead);
            b.emit_const(Const::Unit)
        }
        Expr::Throw { value, .. } => {
            let r = lower_expr(b, value);
            b.terminate(Terminator::Throw(r));
            let dead = b.alloc_block();
            b.switch_to(dead);
            b.emit_const(Const::Unit)
        }
        Expr::When {
            subject,
            subject_binding,
            branches,
            ..
        } => {
            // `when (val v = subject) { ... }` binds `v` to the
            // subject's value so pattern arms can refer to it. Push
            // a scope so the binding pops after the when.
            if let (Some(s), Some(bind)) = (subject.as_deref(), subject_binding) {
                b.push_scope();
                let sv = lower_expr(b, s);
                b.bind(bind.name.name.clone(), sv);
                let r = lower_when(b, subject.as_deref(), branches, expr_span(expr));
                b.pop_scope();
                r
            } else {
                lower_when(b, subject.as_deref(), branches, expr_span(expr))
            }
        }
        Expr::Try {
            body,
            catches,
            finally,
            ..
        } => {
            // Exception-edge model: the body block carries a list
            // of CatchHandlers (one per catch arm) and an optional
            // finally block. The evaluator's Throw terminator walks
            // the active block chain, matches the throw against
            // each handler's type_name, jumps to the matching
            // handler with the exception bound to its
            // exception_reg, and runs finally on every exit.
            //
            let result = b.alloc_reg();
            let exit = b.alloc_block();
            let finally_entry = finally.as_ref().map(|_| b.alloc_block());

            // Pre-allocate each catch handler's entry block + the
            // exception register. We'll fill in their bodies after
            // recording the handler metadata.
            let handlers: Vec<(klio_ast::Catch, BlockId, Reg)> = catches
                .iter()
                .map(|c| {
                    let blk = b.alloc_block();
                    let exc = b.alloc_reg();
                    (c.clone(), blk, exc)
                })
                .collect();

            // Body block: stitch CatchHandlers onto the cursor
            // block before lowering the body so any Throw fired
            // during body evaluation routes through them.
            let body_entry = b.alloc_block();
            b.terminate(Terminator::Goto(body_entry));
            b.switch_to(body_entry);
            let cur_id = b.cur;
            let catch_handlers: Vec<crate::CatchHandler> = handlers
                .iter()
                .map(|(c, blk, exc)| crate::CatchHandler {
                    type_name: c.ty.name.name.clone(),
                    handler: *blk,
                    exception_reg: *exc,
                })
                .collect();
            b.attach_catches(cur_id, catch_handlers, finally_entry);
            if let Some(blk) = finally {
                b.push_finally(blk.clone());
            }
            let body_val = lower_block(b, body);
            b.push(Inst::Move {
                dst: result,
                src: body_val,
            });
            if let Some(fin) = finally_entry {
                b.terminate(Terminator::Goto(fin));
            } else {
                b.terminate(Terminator::Goto(exit));
            }

            // Each handler body: bind the exception, lower the
            // catch body, fall through to finally (or exit).
            for (c, blk, exc) in &handlers {
                b.switch_to(*blk);
                b.push_scope();
                b.bind(c.binding.name.clone(), *exc);
                let v = lower_block(b, &c.body);
                b.push(Inst::Move {
                    dst: result,
                    src: v,
                });
                b.pop_scope();
                if let Some(fin) = finally_entry {
                    b.terminate(Terminator::Goto(fin));
                } else {
                    b.terminate(Terminator::Goto(exit));
                }
            }

            // Finally body (if present): lower it inside
            // `finally_entry`. Pop the active-finally stack first
            // so a `return` inside the finally body doesn't replay
            // itself.
            //
            // Routing every path out of the finally through a
            // separate sentinel `finally_done` block is what makes
            // the eval's pop-on-Goto check robust: the user finally
            // body may contain its own control flow (an `if`, a
            // `when`) so its last basic block isn't necessarily
            // `finally_entry`. We pin every fallthrough exit to
            // `finally_done` so the eval can pop the try-stack
            // entry when (and only when) `cur == finally_done` —
            // without that, a later `Return` walking outer scopes
            // would re-enter this finally a second time.
            if let Some(fin) = finally_entry {
                if finally.is_some() {
                    b.pop_finally();
                }
                let finally_done = b.alloc_block();
                b.switch_to(fin);
                if let Some(blk) = finally {
                    let _ = lower_block(b, blk);
                }
                b.terminate(Terminator::Goto(finally_done));
                b.switch_to(finally_done);
                b.set_finally_done_for(cur_id, finally_done);
                b.terminate(Terminator::Goto(exit));
            }

            b.switch_to(exit);
            result
        }
        Expr::Lambda { params, body, .. } => {
            // Lower a Kotlin lambda to a tree-walker-compatible
            // Value::Lambda by emitting Inst::AstLambda. The host
            // (klio-interp's IrHost) populates the captured env
            // from the snapshotted reg values + names — letting
            // existing dispatch paths (call_lambda, invoke_lambda)
            // call IR-lowered lambdas without each pattern-match
            // site adding a separate IrClosure branch.
            //
            // Free-variable analysis: collect every local name
            // visible in the enclosing scope, then walk the
            // lambda body via lower_lambda_body_capturing's
            // FuncBuilder to discover which ones get referenced.
            // Names not bound in the outer scope (top-level fns /
            // stdlib intrinsics) fall through to the tree walker's
            // global lookup at call time.
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let inherited_rlp = b.receiver_lambda_param_names();
            let outer_boxed = b.boxed_vars_snapshot();
            let (body_func, captured_names) = lower_lambda_body_capturing(
                b.module,
                params,
                body,
                outer_names,
                &outer_boxed,
                inherited_rlp,
            );
            // Record the implicit label (the enclosing call's simple name,
            // re-armed by `lower_arg_run`) so `this@<label>` inside the
            // lambda resolves to the receiver it is invoked with.
            if let Some(label) = b.pending_lambda_label.take()
                && let Some(f) = b.module.funcs.get_mut(body_func.0 as usize)
            {
                f.implicit_label = Some(label);
            }
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let mut param_names: Vec<String> = params.iter().map(|p| p.name.clone()).collect();
            if param_names.is_empty() {
                param_names.push("it".to_string());
            }
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body.clone(),
                captures,
                captured_names,
                absorb_return: false,
                body_func: Some(body_func),
            });
            dst
        }
        Expr::Break { label, .. } => {
            if let Some(frame) = b.loop_for(label.as_ref().map(|i| i.name.as_str())).cloned() {
                b.terminate(Terminator::Goto(frame.break_target));
                let dead = b.alloc_block();
                b.switch_to(dead);
            } else {
                b.push(Inst::Trace {
                    span: expr_span(expr),
                });
            }
            b.emit_const(Const::Unit)
        }
        Expr::Continue { label, .. } => {
            if let Some(frame) = b.loop_for(label.as_ref().map(|i| i.name.as_str())).cloned() {
                b.terminate(Terminator::Goto(frame.continue_target));
                let dead = b.alloc_block();
                b.switch_to(dead);
            } else {
                b.push(Inst::Trace {
                    span: expr_span(expr),
                });
            }
            b.emit_const(Const::Unit)
        }
        Expr::For {
            vars, iter, body, ..
        } => lower_for(b, vars, iter, body),
        Expr::IsCheck {
            expr: inner,
            ty,
            negated,
            ..
        } => {
            let s = lower_expr(b, inner);
            let dst = b.alloc_reg();
            b.push(Inst::InstanceOf {
                dst,
                src: s,
                ty: crate::TypeRef {
                    name: ty.name.name.clone(),
                    nullable: ty.nullable,
                    args: Vec::new(),
                },
            });
            if *negated {
                let neg = b.alloc_reg();
                b.push(Inst::Not { dst: neg, src: dst });
                neg
            } else {
                dst
            }
        }
        Expr::As {
            expr: inner,
            ty,
            safe,
            ..
        } => {
            let s = lower_expr(b, inner);
            let dst = b.alloc_reg();
            b.push(Inst::Cast {
                dst,
                src: s,
                ty: crate::TypeRef {
                    name: ty.name.name.clone(),
                    nullable: ty.nullable,
                    args: Vec::new(),
                },
                safe: *safe,
            });
            dst
        }
        Expr::Postfix {
            op, expr: inner, ..
        } => match op {
            klio_ast::PostfixOp::NotNull => {
                let s = lower_expr(b, inner);
                let dst = b.alloc_reg();
                b.push(Inst::NotNullAssert { dst, src: s });
                dst
            }
            klio_ast::PostfixOp::Inc | klio_ast::PostfixOp::Dec => {
                let op = match op {
                    klio_ast::PostfixOp::Inc => UnOp::Inc,
                    klio_ast::PostfixOp::Dec => UnOp::Dec,
                    klio_ast::PostfixOp::NotNull => unreachable!(),
                };
                // For Index targets, evaluate receiver + keys ONCE,
                // read via get(...), inc/dec, write via set(...),
                // returning the snapshot. Otherwise fall through to
                // the generic "evaluate inner once, write back via
                // Path / Member" path.
                if let Expr::Index {
                    receiver,
                    args: idx_args,
                    ..
                } = inner.as_ref()
                {
                    let recv = lower_receiver(b, receiver);
                    let n_keys = idx_args.len();
                    let key_start = b.alloc_reg();
                    let mut key_slots: Vec<Reg> = vec![key_start];
                    for _ in 1..n_keys {
                        key_slots.push(b.alloc_reg());
                    }
                    // Reserve val slot for the write-back contig.
                    let val_slot = b.alloc_reg();
                    for (slot, arg) in key_slots.iter().zip(idx_args.iter()) {
                        let r = lower_expr(b, arg);
                        b.push(Inst::Move { dst: *slot, src: r });
                    }
                    // Read current: get(key…) into `old`.
                    let old = b.alloc_reg();
                    let get_nm = b.module.intern_const(Const::String("get".into()));
                    b.push(Inst::CallMember {
                        dst: old,
                        receiver: recv,
                        name: get_nm,
                        args: key_start,
                        n_args: n_keys as u8,
                        arg_names: Vec::new(),
                    });
                    // new = unop(old)
                    let new = b.alloc_reg();
                    b.push(Inst::UnOp {
                        dst: new,
                        op,
                        operand: old,
                    });
                    b.push(Inst::Move {
                        dst: val_slot,
                        src: new,
                    });
                    // Write back: set(key…, new). Reuses the SAME
                    // key slots so idx() isn't called twice.
                    let set_dst = b.alloc_reg();
                    let set_nm = b.module.intern_const(Const::String("set".into()));
                    b.push(Inst::CallMember {
                        dst: set_dst,
                        receiver: recv,
                        name: set_nm,
                        args: key_start,
                        n_args: (n_keys as u8) + 1,
                        arg_names: Vec::new(),
                    });
                    return old;
                }
                let s = lower_expr(b, inner);
                // Snapshot the old value into a fresh reg before
                // mutating the storage slot — `c++` returns the
                // pre-increment value, and for a `var` local `s` is
                // the home reg, so a later Move into home would
                // overwrite the value we want to return.
                let old = b.alloc_reg();
                b.push(Inst::Move { dst: old, src: s });
                let new = b.alloc_reg();
                b.push(Inst::UnOp {
                    dst: new,
                    op,
                    operand: old,
                });
                match inner.as_ref() {
                    Expr::Path { segments, .. } if segments.len() == 1 => {
                        if b.is_boxed(&segments[0].name) {
                            let cell = boxed_cell_reg(b, &segments[0].name);
                            b.push(Inst::CellSet { cell, value: new });
                        } else if let Some(home) = b.mutable_home(&segments[0].name) {
                            b.push(Inst::Move {
                                dst: home,
                                src: new,
                            });
                        } else if b.has_own_member(&segments[0].name) && b.resolve("this").is_some()
                        {
                            // Method-body `field++` write — route
                            // through SetField on this so the
                            // mutation reaches the instance.
                            let this_reg = b.resolve("this").unwrap();
                            let field = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::SetField {
                                receiver: this_reg,
                                field,
                                value: new,
                            });
                        } else if b.knows_outer(&segments[0].name) {
                            // Lambda-body postfix inc/dec on a
                            // captured outer var: rebind locally
                            // and emit StoreGlobal so the caller's
                            // WritebackCaptures Inst syncs the
                            // mutation back to the outer reg.
                            let _ = b.record_capture(&segments[0].name);
                            let n = b
                                .module
                                .intern_const(Const::String(segments[0].name.clone()));
                            b.push(Inst::StoreGlobal {
                                name: n,
                                value: new,
                            });
                            b.rebind(&segments[0].name, new);
                        } else {
                            b.rebind(&segments[0].name, new);
                        }
                    }
                    Expr::Member {
                        receiver,
                        name,
                        safe: false,
                        ..
                    } => {
                        // `obj.field++` — write the incremented value
                        // back through the same SetField path the
                        // host's set_field uses for class setters.
                        let recv = lower_receiver(b, receiver);
                        let field = b.module.intern_const(Const::String(name.name.clone()));
                        b.push(Inst::SetField {
                            receiver: recv,
                            field,
                            value: new,
                        });
                    }
                    Expr::Index {
                        receiver,
                        args: idx_args,
                        ..
                    } => {
                        // `xs[i]++` — read above, write back via .set(i, new).
                        let recv = lower_receiver(b, receiver);
                        let n_keys = idx_args.len();
                        let key_start = b.alloc_reg();
                        let mut key_slots: Vec<Reg> = vec![key_start];
                        for _ in 1..n_keys {
                            key_slots.push(b.alloc_reg());
                        }
                        let val_slot = b.alloc_reg();
                        for (slot, arg) in key_slots.iter().zip(idx_args.iter()) {
                            let r = lower_expr(b, arg);
                            b.push(Inst::Move { dst: *slot, src: r });
                        }
                        b.push(Inst::Move {
                            dst: val_slot,
                            src: new,
                        });
                        let dst = b.alloc_reg();
                        let nm = b.module.intern_const(Const::String("set".into()));
                        b.push(Inst::CallMember {
                            dst,
                            receiver: recv,
                            name: nm,
                            args: key_start,
                            n_args: (n_keys as u8) + 1,
                            arg_names: Vec::new(),
                        });
                    }
                    _ => {}
                }
                old
            }
        },
        Expr::Labeled {
            label, expr: inner, ..
        } => match inner.as_ref() {
            Expr::While { cond, body, .. } => {
                let header = b.alloc_block();
                let body_blk = b.alloc_block();
                let exit = b.alloc_block();
                b.terminate(Terminator::Goto(header));
                b.switch_to(header);
                let c = lower_expr(b, cond);
                b.terminate(Terminator::Branch {
                    cond: c,
                    t: body_blk,
                    f: exit,
                });
                b.switch_to(body_blk);
                b.push_loop(Some(label.name.clone()), header, exit);
                let _ = lower_expr(b, body);
                b.pop_loop();
                b.terminate(Terminator::Goto(header));
                b.switch_to(exit);
                b.emit_const(Const::Unit)
            }
            Expr::For {
                vars, iter, body, ..
            } => lower_for_labeled(b, vars, iter, body, Some(label.name.clone())),
            Expr::DoWhile { body, cond, .. } => {
                let body_blk = b.alloc_block();
                let exit = b.alloc_block();
                b.terminate(Terminator::Goto(body_blk));
                b.switch_to(body_blk);
                b.push_loop(Some(label.name.clone()), body_blk, exit);
                if let Some(body) = body {
                    let _ = lower_expr(b, body);
                }
                b.pop_loop();
                let c = lower_expr(b, cond);
                b.terminate(Terminator::Branch {
                    cond: c,
                    t: body_blk,
                    f: exit,
                });
                b.switch_to(exit);
                b.emit_const(Const::Unit)
            }
            _ => lower_expr(b, inner),
        },
        Expr::PropertyRef { name, .. } => {
            // `::greet` — if the name is a registered top-level
            // function, load the function value so the result is
            // callable. Otherwise emit a `KProperty`-shaped
            // PropertyRef metadata value.
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            if b.module.func_id(&name.name).is_some() || b.module.class_id(&name.name).is_some() {
                b.push(Inst::LoadGlobal { dst, name: nm });
            } else {
                b.push(Inst::PropertyRef { dst, name: nm });
            }
            dst
        }
        Expr::MemberRef { receiver, name, .. } => {
            // `Outer::Nested` where `Nested` is a (nested) class is a
            // constructor reference, not a bound member ref — load
            // the class value so it is callable, exactly like the
            // no-receiver `::Ctor` form. The receiver here is just a
            // type qualifier with no runtime value.
            if name.name != "class"
                && matches!(receiver.as_ref(), Expr::Path { .. })
                && b.module.class_id(&name.name).is_some()
            {
                let dst = b.alloc_reg();
                let nm = b.module.intern_const(Const::String(name.name.clone()));
                b.push(Inst::LoadGlobal { dst, name: nm });
                return dst;
            }
            let recv = lower_receiver(b, receiver);
            let dst = b.alloc_reg();
            let nm = b.module.intern_const(Const::String(name.name.clone()));
            b.push(Inst::MemberRef {
                dst,
                receiver: recv,
                name: nm,
            });
            dst
        }
        Expr::ObjectExpr { .. } => {
            // Anonymous-object expressions (`object { … }` /
            // `object : Foo { … }`) carry rich AST shape (a body of
            // declarations, supertypes, init blocks) that the IR
            // doesn't model structurally yet. Emit a dedicated
            // `BuildObject` Inst whose host synthesises a fresh
            // `ClassDef` with the snapshotted env on each call.
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let captured_names: Vec<String> = outer_names.iter().cloned().collect();
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let dst = b.alloc_reg();
            b.push(Inst::BuildObject {
                dst,
                ast: Box::new(expr.clone()),
                captured_names,
                captures,
            });
            dst
        }
        Expr::AnonFun { params, body, .. } => {
            // Lower an anonymous function the same way as a lambda:
            // synthesise an AstLambda with the body packed into a
            // `Block`. `fun (x): T = expr` carries `FunctionBody::Expr`
            // — wrap that as a single-statement block whose last
            // expression is the return value.
            let body_block: klio_ast::Block = match body.as_deref() {
                Some(klio_ast::FunctionBody::Block(blk)) => blk.clone(),
                Some(klio_ast::FunctionBody::Expr(e)) => klio_ast::Block {
                    stmts: vec![klio_ast::Stmt::Expr(e.clone())],
                    span: expr_span(expr),
                },
                None => klio_ast::Block {
                    stmts: Vec::new(),
                    span: expr_span(expr),
                },
            };
            let param_names: Vec<String> = params.iter().map(|p| p.name.name.clone()).collect();
            let param_idents: Vec<klio_ast::Ident> =
                params.iter().map(|p| p.name.clone()).collect();
            let outer_names: std::collections::HashSet<String> = b.visible_names();
            let inherited_rlp = b.receiver_lambda_param_names();
            let outer_boxed = b.boxed_vars_snapshot();
            let (body_func, captured_names) = lower_lambda_body_capturing_kind(
                b.module,
                &param_idents,
                &body_block,
                outer_names,
                false,
                &outer_boxed,
                None,
                inherited_rlp,
            );
            let captures: Vec<Reg> = captured_names
                .iter()
                .map(|n| resolve_capture(b, n))
                .collect();
            let dst = b.alloc_reg();
            b.push(Inst::AstLambda {
                dst,
                params: param_names,
                body_ast: body_block,
                captures,
                captured_names,
                absorb_return: true,
                body_func: Some(body_func),
            });
            dst
        }
        Expr::This { qualifier, .. } => {
            // `this` bare resolves to the implicit first param
            // bound by `lower_method` / extension lowering. Inside
            // a lambda body that hasn't bound `this` locally, fall
            // back to the captured `this` slot — populated by the
            // dispatcher when the lambda is called with a
            // this-binding (scope fns like `apply` / `with`).
            // Note: when `this` resolves through a capture (a scope-fn
            // / receiver lambda body), we deliberately do NOT bind it
            // as a local. Binding poisoned later bare-member reads:
            // they would resolve `this` to the captured lambda
            // receiver and emit a raw GetField with no
            // enclosing-receiver fallback, so `this@Outer` followed by
            // a bare enclosing member failed. Leaving `this` unbound
            // keeps subsequent bare names on the this-or-global probe,
            // which tries the lambda receiver, then the enclosing
            // `this@Outer`, then globals — Kotlin's nested-receiver
            // order. Re-emitting LoadCapture per `this` is cheap.
            let this_reg = b.resolve("this").or_else(|| {
                let idx = b.record_capture("this");
                let dst = b.alloc_reg();
                b.push(Inst::LoadCapture { dst, idx });
                Some(dst)
            });
            if let Some(this_reg) = this_reg {
                if let Some(q) = qualifier {
                    let nm = b.module.intern_const(Const::String(q.name.clone()));
                    let dst = b.alloc_reg();
                    b.push(Inst::QualifiedThis {
                        dst,
                        receiver: this_reg,
                        qualifier: nm,
                    });
                    dst
                } else {
                    this_reg
                }
            } else {
                b.push(Inst::Trace {
                    span: expr_span(expr),
                });
                b.emit_const(Const::Unit)
            }
        }
        Expr::Super { .. } => {
            // `super` bare or `super.member` reads the same
            // instance value as `this`; the method-dispatch site
            // would normally walk to the parent class's body.
            // The IR has no native super-dispatch yet, so we
            // return `this` and let the host's call_member fall
            // back to the tree walker's `super.foo()` machinery
            // via `dispatch_member_via_ast` when a method-on-
            // super resolves to a different parent override.
            if let Some(this_reg) = b.resolve("this") {
                this_reg
            } else {
                b.push(Inst::Trace {
                    span: expr_span(expr),
                });
                b.emit_const(Const::Unit)
            }
        }
        Expr::Spread { .. } => {
            // A bare spread outside a call argument list has no
            // lowering yet. Emit a placeholder Trace so the gap is
            // visible in printouts and tests can assert which forms
            // still need work.
            b.push(Inst::Trace {
                span: expr_span(expr),
            });
            b.emit_const(Const::Unit)
        }
    }
}

pub(super) fn lower_block(b: &mut FuncBuilder<'_>, block: &AstBlock) -> Reg {
    b.push_scope();
    // Hoist only the local fn names that an *earlier-declared* local
    // fn in this same block references — that is the strict subset of
    // names that require a shared cell so mutually-recursive sibling
    // fns can resolve a forward reference. Hoisting more names changes
    // the binding of unrelated locals from a direct value to a boxed
    // cell, which then interacts with member-/extension-dispatch in
    // ways that regress unrelated programs (a local-fn-by-value direct
    // bind is what code without forward references is built on).
    let local_fn_decls: Vec<(usize, &klio_ast::Function)> = block
        .stmts
        .iter()
        .enumerate()
        .filter_map(|(i, s)| {
            if let Stmt::Decl(klio_ast::Decl::Function(f)) = s {
                Some((i, f))
            } else {
                None
            }
        })
        .collect();
    for (k_idx, _) in local_fn_decls.iter().enumerate() {
        let (k_pos, k_fn) = local_fn_decls[k_idx];
        let mut needs_hoist = false;
        for (i_pos, i_fn) in &local_fn_decls {
            if *i_pos >= k_pos {
                break;
            }
            // Only an EARLIER local fn referencing `k_fn` justifies a
            // pre-hoist; later references already see `k_fn` bound.
            if let Some(body) = i_fn.body.as_ref() {
                let mut refs = std::collections::HashSet::new();
                match body {
                    klio_ast::FunctionBody::Block(blk) => {
                        for s in &blk.stmts {
                            collect_path_idents_stmt(s, &mut refs);
                        }
                    }
                    klio_ast::FunctionBody::Expr(e) => {
                        collect_path_idents(e, &mut refs);
                    }
                }
                if refs.contains(&k_fn.name.name) {
                    needs_hoist = true;
                    break;
                }
            }
        }
        if needs_hoist && b.mutable_home(&k_fn.name.name).is_none() {
            let null_v = b.emit_const(Const::Null);
            let home = b.alloc_reg();
            b.push(Inst::MakeCell {
                dst: home,
                src: null_v,
            });
            b.set_mutable_home(&k_fn.name.name, home);
            b.mark_mutable(&k_fn.name.name);
            b.mark_boxed(&k_fn.name.name);
            b.bind(k_fn.name.name.clone(), home);
        }
    }
    let mut last: Option<Reg> = None;
    for stmt in &block.stmts {
        last = lower_stmt(b, stmt);
    }
    let result = last.unwrap_or_else(|| b.emit_const(Const::Unit));
    b.pop_scope();
    result
}
