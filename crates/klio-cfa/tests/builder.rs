//! Exercises the IR + builder by constructing canonical CFG shapes
//! by hand and snapshotting their printed form. These tests run
//! before any AST → CFG lowering exists; they pin the IR API so
//! later phases can rely on it.

use klio_cfa::{
    CfgBuilder, ExprRef, FieldId, Node, Pattern, Place, SwitchArm, Symbol, Terminator, print_cfg,
};
use klio_span::{FileId, Span};
use klio_types::Type;

fn span(s: u32, e: u32) -> Span {
    Span {
        file: FileId(0),
        start: s,
        end: e,
    }
}

#[test]
fn straight_line() {
    // r0 = x; r1 = y; tmp = r0; return tmp
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let r0 = b.new_reg();
    let r1 = b.new_reg();
    b.push(
        entry,
        Node::Eval {
            reg: r0,
            expr: ExprRef {
                span: span(0, 1),
                ty: Type::Int,
            },
        },
    );
    b.push(
        entry,
        Node::Eval {
            reg: r1,
            expr: ExprRef {
                span: span(2, 3),
                ty: Type::Int,
            },
        },
    );
    b.push(
        entry,
        Node::Assign {
            lhs: Place::Local(Symbol("tmp".into())),
            rhs: r0,
            span: span(4, 7),
        },
    );
    b.set_terminator(entry, Terminator::Return(Some(r1)));
    let cfg = b.finish(entry, vec![entry], span(0, 10));
    insta::assert_snapshot!(print_cfg(&cfg));
}

#[test]
fn branch_join() {
    // if (cond) then-blk else else-blk -> join
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let then_blk = b.new_block();
    let else_blk = b.new_block();
    let join = b.new_block();

    let cond = b.new_reg();
    let rt = b.new_reg();
    let rf = b.new_reg();

    b.push(
        entry,
        Node::Eval {
            reg: cond,
            expr: ExprRef {
                span: span(0, 4),
                ty: Type::Boolean,
            },
        },
    );
    b.set_terminator(
        entry,
        Terminator::Branch {
            cond,
            then_blk,
            else_blk,
        },
    );

    b.push(
        then_blk,
        Node::Assume {
            reg: cond,
            polarity: true,
        },
    );
    b.push(
        then_blk,
        Node::Eval {
            reg: rt,
            expr: ExprRef {
                span: span(5, 6),
                ty: Type::Int,
            },
        },
    );
    b.set_terminator(then_blk, Terminator::Goto(join));

    b.push(
        else_blk,
        Node::Assume {
            reg: cond,
            polarity: false,
        },
    );
    b.push(
        else_blk,
        Node::Eval {
            reg: rf,
            expr: ExprRef {
                span: span(7, 8),
                ty: Type::Int,
            },
        },
    );
    b.set_terminator(else_blk, Terminator::Goto(join));

    b.set_terminator(join, Terminator::Return(None));

    let cfg = b.finish(entry, vec![join], span(0, 12));
    insta::assert_snapshot!(print_cfg(&cfg));
}

#[test]
fn is_check_arm_carries_assume_is() {
    // when (x) { is String -> body; else -> def }
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let str_arm = b.new_block();
    let def_arm = b.new_block();
    let join = b.new_block();

    let subj = b.new_reg();
    b.push(
        entry,
        Node::Eval {
            reg: subj,
            expr: ExprRef {
                span: span(0, 1),
                ty: Type::Any,
            },
        },
    );
    b.set_terminator(
        entry,
        Terminator::Switch {
            reg: subj,
            arms: vec![SwitchArm {
                pattern: Pattern::Is {
                    ty: Type::String,
                    polarity: true,
                },
                target: str_arm,
            }],
            default: def_arm,
        },
    );

    b.push(
        str_arm,
        Node::AssumeIs {
            reg: subj,
            ty: Type::String,
            class_name: None,
            polarity: true,
            span: span(0, 1),
        },
    );
    b.set_terminator(str_arm, Terminator::Goto(join));

    b.push(
        def_arm,
        Node::AssumeIs {
            reg: subj,
            ty: Type::String,
            class_name: None,
            polarity: false,
            span: span(0, 1),
        },
    );
    b.set_terminator(def_arm, Terminator::Goto(join));

    b.set_terminator(join, Terminator::Return(None));

    let cfg = b.finish(entry, vec![join], span(0, 30));
    insta::assert_snapshot!(print_cfg(&cfg));
}

#[test]
fn loop_with_backedge() {
    // while (cond) { body }
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let head = b.new_block();
    let body = b.new_block();
    let exit = b.new_block();
    let lid = b.new_loop();

    b.set_terminator(entry, Terminator::Goto(head));

    let cond = b.new_reg();
    b.push(
        head,
        Node::Eval {
            reg: cond,
            expr: ExprRef {
                span: span(0, 1),
                ty: Type::Boolean,
            },
        },
    );
    b.set_terminator(
        head,
        Terminator::Branch {
            cond,
            then_blk: body,
            else_blk: exit,
        },
    );

    b.push(
        body,
        Node::Assume {
            reg: cond,
            polarity: true,
        },
    );
    b.push(body, Node::Backedge { loop_id: lid });
    b.set_terminator(body, Terminator::Goto(head));

    b.push(
        exit,
        Node::Assume {
            reg: cond,
            polarity: false,
        },
    );
    b.set_terminator(exit, Terminator::Return(None));

    let cfg = b.finish(entry, vec![exit], span(0, 30));
    insta::assert_snapshot!(print_cfg(&cfg));
}

#[test]
fn try_catch_finally_edges() {
    // try { body } catch (e: T) { handler } finally { fin }
    use klio_cfa::EdgeKind;
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let body = b.new_block();
    let handler = b.new_block();
    let fin = b.new_block();
    let after = b.new_block();

    b.set_terminator(entry, Terminator::Goto(body));

    let r0 = b.new_reg();
    b.push(
        body,
        Node::Eval {
            reg: r0,
            expr: ExprRef {
                span: span(0, 5),
                ty: Type::Int,
            },
        },
    );
    b.set_terminator(body, Terminator::Goto(fin));
    b.add_edge(
        body,
        handler,
        EdgeKind::Exception {
            ty: Some(Type::String),
        },
    );

    let r1 = b.new_reg();
    b.push(
        handler,
        Node::Eval {
            reg: r1,
            expr: ExprRef {
                span: span(6, 9),
                ty: Type::Int,
            },
        },
    );
    b.set_terminator(handler, Terminator::Goto(fin));

    b.set_terminator(fin, Terminator::Goto(after));
    b.add_edge(fin, after, EdgeKind::FinallyExit);

    b.set_terminator(after, Terminator::Return(None));

    let cfg = b.finish(entry, vec![after], span(0, 40));
    insta::assert_snapshot!(print_cfg(&cfg));
}

#[test]
fn field_place_path() {
    // p.x.y = r0
    let mut b = CfgBuilder::new();
    let entry = b.new_block();
    let r0 = b.new_reg();
    b.push(
        entry,
        Node::Eval {
            reg: r0,
            expr: ExprRef {
                span: span(0, 1),
                ty: Type::Int,
            },
        },
    );
    let place = Place::Field {
        receiver: Box::new(Place::Field {
            receiver: Box::new(Place::Local(Symbol("p".into()))),
            field: FieldId("x".into()),
        }),
        field: FieldId("y".into()),
    };
    b.push(
        entry,
        Node::Assign {
            lhs: place,
            rhs: r0,
            span: span(2, 9),
        },
    );
    b.set_terminator(entry, Terminator::Return(None));
    let cfg = b.finish(entry, vec![entry], span(0, 10));
    insta::assert_snapshot!(print_cfg(&cfg));
}
