use crate::{ClassDef, DelegateKind, Env, InstanceData, ObjRef, SeqOp, SequenceSource, Value};

use std::sync::Arc;

/// Publish (and recurse through) one `ObjRef`. Publishing is always
/// safe and idempotent; the visited set only bounds recursion. Returns
/// `true` when this is the first visit (caller should recurse into the
/// contents), `false` when the cell was already walked.
fn mark_cell<T: ?Sized>(r: &ObjRef<T>, seen: &mut std::collections::HashSet<usize>) -> bool {
    r.publish();
    seen.insert(r.identity())
}

pub(crate) fn publish_env(env: &Env, seen: &mut std::collections::HashSet<usize>) {
    for v in env.vars.values() {
        publish_value(v, seen);
    }
    if let Some(parent) = &env.parent
        && mark_cell(parent, seen)
    {
        publish_env(&parent.borrow(), seen);
    }
}

fn publish_classdef(cls: &Arc<ClassDef>, seen: &mut std::collections::HashSet<usize>) {
    // Key ClassDef walks on the Arc identity so parent/enclosing cycles
    // terminate even though the Arc itself carries no ObjRef cell.
    let arc_id = Arc::as_ptr(cls).cast::<()>() as usize;
    if !seen.insert(arc_id) {
        return;
    }
    if mark_cell(&cls.parent, seen)
        && let Some(p) = cls.parent.borrow().as_ref()
    {
        publish_classdef(p, seen);
    }
    if mark_cell(&cls.interfaces, seen) {
        for iface in cls.interfaces.borrow().iter() {
            publish_classdef(iface, seen);
        }
    }
    if mark_cell(&cls.enum_entries, seen) {
        for (_, v) in cls.enum_entries.borrow().iter() {
            publish_value(v, seen);
        }
    }
    if mark_cell(&cls.companion, seen)
        && let Some(c) = cls.companion.borrow().as_ref()
        && mark_cell(c, seen)
    {
        publish_instance(&c.borrow(), seen);
    }
    if mark_cell(&cls.enclosing_class, seen)
        && let Some(e) = cls.enclosing_class.borrow().as_ref()
    {
        publish_classdef(e, seen);
    }
    if mark_cell(&cls.nested_classes, seen) {
        for (_, nested) in cls.nested_classes.borrow().iter() {
            publish_classdef(nested, seen);
        }
    }
    if mark_cell(&cls.captured_env, seen) {
        publish_env(&cls.captured_env.borrow(), seen);
    }
    if mark_cell(&cls.supertype_delegates, seen) {
        // SupertypeDelegate carries only resolved ClassDefs and
        // immutable Arc<Expr>; recurse the resolved interfaces.
        for d in cls.supertype_delegates.borrow().iter() {
            if let Some(iface) = &d.interface {
                publish_classdef(iface, seen);
            }
        }
    }
    if mark_cell(&cls.delegate_forwarders, seen) {
        for m in cls.delegate_forwarders.borrow().iter() {
            if let Some(v) = &m.sam_lambda {
                publish_value(v, seen);
            }
        }
    }
    if mark_cell(&cls.object_singleton, seen)
        && let Some(s) = cls.object_singleton.borrow().as_ref()
        && mark_cell(s, seen)
    {
        publish_instance(&s.borrow(), seen);
    }
    // Methods can carry SAM-converted lambda values that close over
    // the graph; publish those too.
    for m in &cls.methods {
        if let Some(v) = &m.sam_lambda {
            publish_value(v, seen);
        }
    }
}

fn publish_instance(inst: &InstanceData, seen: &mut std::collections::HashSet<usize>) {
    publish_classdef(&inst.class, seen);
    for (_, v) in &inst.fields {
        publish_value(v, seen);
    }
    if let Some(outer) = &inst.outer {
        publish_value(outer, seen);
    }
}

fn publish_delegate(kind: &DelegateKind, seen: &mut std::collections::HashSet<usize>) {
    match kind {
        DelegateKind::Lazy { producer, cached } => {
            publish_value(producer, seen);
            if let Some(c) = cached {
                publish_value(c, seen);
            }
        }
        DelegateKind::Observable { value, on_change } => {
            publish_value(value, seen);
            publish_value(on_change, seen);
        }
        DelegateKind::NotNull { value, .. } => {
            if let Some(v) = value {
                publish_value(v, seen);
            }
        }
    }
}

// One match over every Value variant; splitting would fragment the dispatch.
#[allow(clippy::too_many_lines)]
pub(crate) fn publish_value(v: &Value, seen: &mut std::collections::HashSet<usize>) {
    match v {
        // Scalars / immutable Arc leaves and the coroutine sentinel:
        // no ObjRef, nothing to publish.
        Value::Unit
        | Value::Int(_)
        | Value::Long(_)
        | Value::Short(_)
        | Value::Byte(_)
        | Value::UInt(_)
        | Value::ULong(_)
        | Value::UShort(_)
        | Value::UByte(_)
        | Value::Double(_)
        | Value::Float(_)
        | Value::Bool(_)
        | Value::String(_)
        | Value::Char(_)
        | Value::Null
        | Value::Range { .. }
        | Value::Intrinsic { .. }
        | Value::BoundMethod { .. }
        | Value::PropertyRef { .. }
        | Value::Regex(_)
        | Value::Match(_)
        | Value::MatchGroup { .. }
        | Value::CoroutineSuspended => {}

        Value::List { items, backing, .. } | Value::Set { items, backing, .. } => {
            if mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    publish_value(elem, seen);
                }
            }
            if let Some(b) = backing
                && mark_cell(&b.entries, seen)
            {
                for (k, v) in b.entries.borrow().iter() {
                    publish_value(k, seen);
                    publish_value(v, seen);
                }
            }
        }
        Value::Array { items, .. } => {
            if mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    publish_value(elem, seen);
                }
            }
        }
        Value::Iterator { items, pos, .. } => {
            if mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    publish_value(elem, seen);
                }
            }
            mark_cell(pos, seen);
        }
        // The lazy range iterator's only ObjRef is the `cur` counter
        // (an i64 cell — no nested values to walk). Publish the cell so
        // the cross-thread fence applies.
        Value::RangeIter { cur, .. } => {
            mark_cell(cur, seen);
        }
        Value::Map { entries, .. } => {
            if mark_cell(entries, seen) {
                for (k, val) in entries.borrow().iter() {
                    publish_value(k, seen);
                    publish_value(val, seen);
                }
            }
        }

        Value::Instance(inst) => {
            if mark_cell(inst, seen) {
                publish_instance(&inst.borrow(), seen);
            }
        }
        Value::BoundUserMethod { receiver, .. } => {
            if mark_cell(receiver, seen) {
                publish_instance(&receiver.borrow(), seen);
            }
        }
        Value::BoundInnerClass { class, outer } => {
            publish_classdef(class, seen);
            if mark_cell(outer, seen) {
                publish_instance(&outer.borrow(), seen);
            }
        }
        Value::Class(cls) => publish_classdef(cls, seen),

        Value::Cell(c) => {
            if mark_cell(c, seen) {
                publish_value(&c.borrow(), seen);
            }
        }
        Value::Delegate(d) => {
            if mark_cell(d, seen) {
                publish_delegate(&d.borrow(), seen);
            }
        }
        Value::StringBuilder(sb) => {
            // String leaf: publish the cell, no inner ObjRef.
            mark_cell(sb, seen);
        }

        Value::Function { env, .. } | Value::Lambda { env, .. } => {
            if mark_cell(env, seen) {
                publish_env(&env.borrow(), seen);
            }
        }

        Value::Pair(a, b) => {
            publish_value(a, seen);
            publish_value(b, seen);
        }
        Value::Triple(a, b, c) => {
            publish_value(a, seen);
            publish_value(b, seen);
            publish_value(c, seen);
        }
        Value::MapEntry {
            key,
            value,
            backing,
        } => {
            publish_value(key, seen);
            publish_value(value, seen);
            if let Some(b) = backing
                && mark_cell(b, seen)
            {
                for (k, v) in b.borrow().iter() {
                    publish_value(k, seen);
                    publish_value(v, seen);
                }
            }
        }
        Value::Result { payload, .. } => publish_value(payload, seen),
        Value::Exception { cause, .. } => {
            if let Some(c) = cause {
                publish_value(c, seen);
            }
        }

        Value::IrClosure { captures, .. } => {
            for cap in captures.iter() {
                publish_value(cap, seen);
            }
        }
        Value::Comparator { steps, .. } => {
            for (step, _) in steps.iter() {
                publish_value(step, seen);
            }
        }
        Value::Sequence(seq) => {
            match &seq.source {
                SequenceSource::Items(items) => {
                    for elem in items.iter() {
                        publish_value(elem, seen);
                    }
                }
                SequenceSource::Generate { seed, next } => {
                    if let Some(s) = seed {
                        publish_value(s, seen);
                    }
                    publish_value(next, seen);
                }
            }
            for op in &seq.ops {
                match op {
                    SeqOp::Map(v)
                    | SeqOp::Filter(v)
                    | SeqOp::FilterNot(v)
                    | SeqOp::OnEach(v)
                    | SeqOp::MapIndexed(v)
                    | SeqOp::FilterIndexed(v)
                    | SeqOp::TakeWhile(v)
                    | SeqOp::DropWhile(v)
                    | SeqOp::FlatMap(v)
                    | SeqOp::DistinctBy(v)
                    | SeqOp::SortedBy(v, _)
                    | SeqOp::SortedWith(v) => publish_value(v, seen),
                    SeqOp::Take(_) | SeqOp::Drop(_) | SeqOp::Distinct | SeqOp::Sorted(_) => {}
                }
            }
        }
    }
}

// ===== GC tracer (feature = "gc") =====
//
// A second walk of the exact same reachability graph as
// `publish_*`, but instead of calling `ObjRef::publish()` on each
// cell it records the cell's identity in the mark set and re-retains
// it in the GC heap (so a cell reachable from a root survives the
// sweep). The traversal shape is kept deliberately identical to the
// `publish_*` family above; if one changes the other must change in
// lockstep. Compiled only under `--features gc`, so the production
// build is byte-identical.

/// Mark + re-retain one cell; returns `true` on first visit so the
/// caller recurses (mirrors `mark_cell`).
#[cfg(feature = "gc")]
fn gc_mark_cell<T: Send + 'static>(
    r: &ObjRef<T>,
    seen: &mut std::collections::HashSet<usize>,
) -> bool {
    gc::retain(&r.0);
    seen.insert(r.identity())
}

#[cfg(feature = "gc")]
pub(crate) fn gc_mark_env_root(env: &ObjRef<Env>, seen: &mut std::collections::HashSet<usize>) {
    if gc_mark_cell(env, seen) {
        gc_mark_env(&env.borrow(), seen);
    }
}

#[cfg(feature = "gc")]
fn gc_mark_env(env: &Env, seen: &mut std::collections::HashSet<usize>) {
    for v in env.vars.values() {
        gc_mark_value(v, seen);
    }
    if let Some(parent) = &env.parent {
        if gc_mark_cell(parent, seen) {
            gc_mark_env(&parent.borrow(), seen);
        }
    }
}

#[cfg(feature = "gc")]
fn gc_mark_classdef(cls: &Arc<ClassDef>, seen: &mut std::collections::HashSet<usize>) {
    let arc_id = Arc::as_ptr(cls) as *const () as usize;
    if !seen.insert(arc_id) {
        return;
    }
    if gc_mark_cell(&cls.parent, seen) {
        if let Some(p) = cls.parent.borrow().as_ref() {
            gc_mark_classdef(p, seen);
        }
    }
    if gc_mark_cell(&cls.interfaces, seen) {
        for iface in cls.interfaces.borrow().iter() {
            gc_mark_classdef(iface, seen);
        }
    }
    if gc_mark_cell(&cls.enum_entries, seen) {
        for (_, v) in cls.enum_entries.borrow().iter() {
            gc_mark_value(v, seen);
        }
    }
    if gc_mark_cell(&cls.companion, seen) {
        if let Some(c) = cls.companion.borrow().as_ref() {
            if gc_mark_cell(c, seen) {
                gc_mark_instance(&c.borrow(), seen);
            }
        }
    }
    if gc_mark_cell(&cls.enclosing_class, seen) {
        if let Some(e) = cls.enclosing_class.borrow().as_ref() {
            gc_mark_classdef(e, seen);
        }
    }
    if gc_mark_cell(&cls.nested_classes, seen) {
        for (_, nested) in cls.nested_classes.borrow().iter() {
            gc_mark_classdef(nested, seen);
        }
    }
    if gc_mark_cell(&cls.captured_env, seen) {
        gc_mark_env(&cls.captured_env.borrow(), seen);
    }
    if gc_mark_cell(&cls.supertype_delegates, seen) {
        for d in cls.supertype_delegates.borrow().iter() {
            if let Some(iface) = &d.interface {
                gc_mark_classdef(iface, seen);
            }
        }
    }
    if gc_mark_cell(&cls.delegate_forwarders, seen) {
        for m in cls.delegate_forwarders.borrow().iter() {
            if let Some(v) = &m.sam_lambda {
                gc_mark_value(v, seen);
            }
        }
    }
    if gc_mark_cell(&cls.object_singleton, seen) {
        if let Some(s) = cls.object_singleton.borrow().as_ref() {
            if gc_mark_cell(s, seen) {
                gc_mark_instance(&s.borrow(), seen);
            }
        }
    }
    for m in &cls.methods {
        if let Some(v) = &m.sam_lambda {
            gc_mark_value(v, seen);
        }
    }
}

#[cfg(feature = "gc")]
fn gc_mark_instance(inst: &InstanceData, seen: &mut std::collections::HashSet<usize>) {
    gc_mark_classdef(&inst.class, seen);
    for (_, v) in &inst.fields {
        gc_mark_value(v, seen);
    }
    if let Some(outer) = &inst.outer {
        gc_mark_value(outer, seen);
    }
}

#[cfg(feature = "gc")]
#[cfg(feature = "gc")]
fn gc_mark_delegate(kind: &DelegateKind, seen: &mut std::collections::HashSet<usize>) {
    match kind {
        DelegateKind::Lazy { producer, cached } => {
            gc_mark_value(producer, seen);
            if let Some(c) = cached {
                gc_mark_value(c, seen);
            }
        }
        DelegateKind::Observable { value, on_change } => {
            gc_mark_value(value, seen);
            gc_mark_value(on_change, seen);
        }
        DelegateKind::NotNull { value, .. } => {
            if let Some(v) = value {
                gc_mark_value(v, seen);
            }
        }
    }
}

#[cfg(feature = "gc")]
pub(crate) fn gc_mark_value(v: &Value, seen: &mut std::collections::HashSet<usize>) {
    match v {
        Value::Unit
        | Value::Int(_)
        | Value::Long(_)
        | Value::Short(_)
        | Value::Byte(_)
        | Value::UInt(_)
        | Value::ULong(_)
        | Value::UShort(_)
        | Value::UByte(_)
        | Value::Double(_)
        | Value::Float(_)
        | Value::Bool(_)
        | Value::String(_)
        | Value::Char(_)
        | Value::Null
        | Value::Range { .. }
        | Value::Intrinsic { .. }
        | Value::BoundMethod { .. }
        | Value::PropertyRef { .. }
        | Value::Regex(_)
        | Value::Match(_)
        | Value::MatchGroup { .. } => {}

        Value::List { items, .. } | Value::Array { items, .. } | Value::Set { items, .. } => {
            if gc_mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    gc_mark_value(elem, seen);
                }
            }
        }
        Value::Iterator { items, pos, .. } => {
            if gc_mark_cell(items, seen) {
                for elem in items.borrow().iter() {
                    gc_mark_value(elem, seen);
                }
            }
            gc_mark_cell(pos, seen);
        }
        Value::Map { entries, .. } => {
            if gc_mark_cell(entries, seen) {
                for (k, val) in entries.borrow().iter() {
                    gc_mark_value(k, seen);
                    gc_mark_value(val, seen);
                }
            }
        }

        Value::Instance(inst) => {
            if gc_mark_cell(inst, seen) {
                gc_mark_instance(&inst.borrow(), seen);
            }
        }
        Value::BoundUserMethod { receiver, .. } => {
            if gc_mark_cell(receiver, seen) {
                gc_mark_instance(&receiver.borrow(), seen);
            }
        }
        Value::BoundInnerClass { class, outer } => {
            gc_mark_classdef(class, seen);
            if gc_mark_cell(outer, seen) {
                gc_mark_instance(&outer.borrow(), seen);
            }
        }
        Value::Class(cls) => gc_mark_classdef(cls, seen),

        Value::Cell(c) => {
            if gc_mark_cell(c, seen) {
                gc_mark_value(&c.borrow(), seen);
            }
        }
        Value::Delegate(d) => {
            if gc_mark_cell(d, seen) {
                gc_mark_delegate(&d.borrow(), seen);
            }
        }
        Value::StringBuilder(sb) => {
            gc_mark_cell(sb, seen);
        }

        Value::Function { env, .. } | Value::Lambda { env, .. } => {
            if gc_mark_cell(env, seen) {
                gc_mark_env(&env.borrow(), seen);
            }
        }
        Value::CoroutineSuspended => {}

        Value::Pair(a, b) => {
            gc_mark_value(a, seen);
            gc_mark_value(b, seen);
        }
        Value::Triple(a, b, c) => {
            gc_mark_value(a, seen);
            gc_mark_value(b, seen);
            gc_mark_value(c, seen);
        }
        Value::MapEntry {
            key,
            value,
            backing: None,
        } => {
            gc_mark_value(key, seen);
            gc_mark_value(value, seen);
        }
        Value::Result { payload, .. } => gc_mark_value(payload, seen),
        Value::Exception { cause, .. } => {
            if let Some(c) = cause {
                gc_mark_value(c, seen);
            }
        }

        Value::IrClosure { captures, .. } => {
            for cap in captures.iter() {
                gc_mark_value(cap, seen);
            }
        }
        Value::Comparator { steps, .. } => {
            for (step, _) in steps.iter() {
                gc_mark_value(step, seen);
            }
        }
        Value::Sequence(seq) => {
            match &seq.source {
                SequenceSource::Items(items) => {
                    for elem in items.iter() {
                        gc_mark_value(elem, seen);
                    }
                }
                SequenceSource::Generate { seed, next } => {
                    if let Some(s) = seed {
                        gc_mark_value(s, seen);
                    }
                    gc_mark_value(next, seen);
                }
            }
            for op in &seq.ops {
                match op {
                    SeqOp::Map(v)
                    | SeqOp::Filter(v)
                    | SeqOp::FilterNot(v)
                    | SeqOp::TakeWhile(v)
                    | SeqOp::DropWhile(v)
                    | SeqOp::FlatMap(v)
                    | SeqOp::DistinctBy(v)
                    | SeqOp::SortedBy(v, _)
                    | SeqOp::SortedWith(v) => gc_mark_value(v, seen),
                    SeqOp::Take(_) | SeqOp::Drop(_) | SeqOp::Distinct | SeqOp::Sorted(_) => {}
                }
            }
        }
    }
}
