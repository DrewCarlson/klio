//! Textual CFG printer for snapshot tests. Produces a stable, dense
//! representation suitable for golden-file diffs. The format is not
//! the spec's dashed/solid box diagram (that is a graphical form),
//! but it carries the same information in line-oriented text.

use crate::ir::{Cfg, Edge, EdgeKind, Node, Pattern, Place, Terminator};
use std::fmt::Write;

pub fn print_cfg(cfg: &Cfg) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "cfg: entry=b{}", cfg.entry.0);
    if !cfg.exits.is_empty() {
        let exits = cfg
            .exits
            .iter()
            .map(|b| format!("b{}", b.0))
            .collect::<Vec<_>>()
            .join(", ");
        let _ = writeln!(out, "exits: {exits}");
    }
    for blk in &cfg.blocks {
        let _ = writeln!(out);
        let _ = writeln!(out, "b{}:", blk.id.0);
        if !blk.preds.is_empty() {
            let p = blk
                .preds
                .iter()
                .map(format_edge)
                .collect::<Vec<_>>()
                .join(", ");
            let _ = writeln!(out, "  preds: {p}");
        }
        for node in &blk.nodes {
            let _ = writeln!(out, "  {}", format_node(node));
        }
        let _ = writeln!(out, "  term: {}", format_term(&blk.term));
    }
    out
}

fn format_edge(e: &Edge) -> String {
    let label = match &e.kind {
        EdgeKind::Normal => String::new(),
        EdgeKind::True => "(T)".to_string(),
        EdgeKind::False => "(F)".to_string(),
        EdgeKind::Exception { ty } => match ty {
            Some(t) => format!("(throw {t:?})"),
            None => "(throw)".to_string(),
        },
        EdgeKind::FinallyEntry => "(finally-entry)".to_string(),
        EdgeKind::FinallyExit => "(finally-exit)".to_string(),
    };
    format!("b{}{label}", e.block.0)
}

fn format_node(n: &Node) -> String {
    match n {
        Node::Eval { reg, expr } => format!(
            "r{} = eval @{}..{} :: {:?}",
            reg.0, expr.span.start, expr.span.end, expr.ty
        ),
        Node::Assign { lhs, rhs, .. } => format!("assign {} = r{}", format_place(lhs), rhs.0),
        Node::DeclLocal {
            place, declared_ty, ..
        } => {
            format!("decl {} : {:?}", place.0, declared_ty)
        }
        Node::Assume { reg, polarity } => {
            format!("assume {}r{}", if *polarity { "" } else { "!" }, reg.0)
        }
        Node::AssumeIs {
            reg,
            ty,
            class_name,
            polarity,
            ..
        } => {
            let cn = class_name
                .as_ref()
                .map(|s| format!(" [{s}]"))
                .unwrap_or_default();
            format!(
                "assume r{} {} {:?}{cn}",
                reg.0,
                if *polarity { "is" } else { "!is" },
                ty
            )
        }
        Node::AssumeNull { reg, eq_null, .. } => format!(
            "assume r{} {} null",
            reg.0,
            if *eq_null { "==" } else { "!=" }
        ),
        Node::AssumeRefEq {
            reg_a,
            reg_b,
            polarity,
            ..
        } => format!(
            "assume r{} {} r{}",
            reg_a.0,
            if *polarity { "===" } else { "!==" },
            reg_b.0
        ),
        Node::Assert { reg, .. } => format!("assert r{}", reg.0),
        Node::KillDataFlow { place } => format!("kill {}", format_place(place)),
        Node::Backedge { loop_id } => format!("backedge l{}", loop_id.0),
        Node::LabelMark { label } => format!("label l{}", label.0),
        Node::Unreachable => "unreachable".to_string(),
    }
}

fn format_place(p: &Place) -> String {
    match p {
        Place::Local(s) => s.0.clone(),
        Place::Field { receiver, field } => format!("{}.{}", format_place(receiver), field.0),
        Place::This => "this".to_string(),
    }
}

fn format_term(t: &Terminator) -> String {
    match t {
        Terminator::Goto(b) => format!("goto b{}", b.0),
        Terminator::Branch {
            cond,
            then_blk,
            else_blk,
        } => {
            format!("branch r{} -> b{} else b{}", cond.0, then_blk.0, else_blk.0)
        }
        Terminator::Switch { reg, arms, default } => {
            let arms = arms
                .iter()
                .map(|a| format!("{} -> b{}", format_pattern(&a.pattern), a.target.0))
                .collect::<Vec<_>>()
                .join("; ");
            format!("switch r{} [{arms}] default b{}", reg.0, default.0)
        }
        Terminator::Throw(r) => format!("throw r{}", r.0),
        Terminator::Return(Some(r)) => format!("return r{}", r.0),
        Terminator::Return(None) => "return".to_string(),
        Terminator::Unreachable => "unreachable".to_string(),
    }
}

fn format_pattern(p: &Pattern) -> String {
    match p {
        Pattern::Equal(r) => format!("== r{}", r.0),
        Pattern::Is { ty, polarity } => {
            format!("{} {:?}", if *polarity { "is" } else { "!is" }, ty)
        }
        Pattern::Wildcard => "_".to_string(),
    }
}
