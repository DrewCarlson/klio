use crate::{
    Arc, ITERABLE_FALLBACK_ACTIVE, MEMBER_ONLY_PROBE, VmHost, VmIntrinsicHost, kotlin_hash_code,
    materialise_range_items, member_is_property, pack_vararg_args, pad_args_with_defaults,
    receiver_compatible_with_param, value_structural_hash, with_call_outer_guard,
};

/// A resolved extension-dispatch candidate paired with its overload
/// score key `(arg-score, owner-rank, specificity)`.
type ScoredCandidate = ((klio_ir::FuncId, klio_ir::Func), (i32, i32, i32));

impl VmHost<'_> {
    // single dispatch over every built-in member; one match keeps receiver kinds together.
    // casts implement Kotlin numeric/index conversions; receiver arms repeat small bodies.
    #[allow(
        clippy::too_many_lines,
        clippy::cast_sign_loss,
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        clippy::match_same_arms
    )]
    pub(crate) fn call_member(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Member-only probe applies to *this* resolution only — once a
        // member is found and its body runs, nested calls resolve
        // normally. Capture and clear the flag here so it never leaks
        // into a dispatched member's execution.
        let member_only = MEMBER_ONLY_PROBE.with(|c| {
            let p = c.get();
            c.set(false);
            p
        });
        // Built-in delegate protocol: `delegate.getValue(thisRef,
        // prop)` / `setValue(thisRef, prop, v)` for a `by lazy { }`,
        // `Delegates.observable`, `notNull()`, etc. The delegated
        // class-body / top-level property read explicitly invokes
        // this, so a `Value::Delegate` receiver must honour it.
        if let klio_runtime::Value::Delegate(d) = receiver {
            match name {
                "getValue" => {
                    let state = d.borrow().clone();
                    return match state {
                        klio_runtime::DelegateKind::Lazy { producer, cached } => {
                            if let Some(c) = cached {
                                return Ok(c);
                            }
                            let result =
                                <Self as klio_ir::eval::Host>::call_value(self, &producer, &[])?;
                            if let klio_runtime::DelegateKind::Lazy { cached, .. } =
                                &mut *d.borrow_mut()
                            {
                                *cached = Some(result.clone());
                            }
                            Ok(result)
                        }
                        klio_runtime::DelegateKind::Observable { value, .. } => Ok(value),
                        klio_runtime::DelegateKind::NotNull { value, .. } => match value {
                            Some(x) => Ok(x),
                            None => Err(klio_ir::eval::EvalError::Throw(
                                klio_runtime::Value::Exception {
                                    fqn: Arc::new("kotlin.IllegalStateException".into()),
                                    message: Some(Arc::new(
                                        "Property should be initialized before get.".into(),
                                    )),
                                    cause: None,
                                },
                            )),
                        },
                    };
                }
                "setValue" => {
                    if let Some(new_v) = args.get(2) {
                        let mut st = d.borrow_mut();
                        match &mut *st {
                            klio_runtime::DelegateKind::Lazy { cached, .. } => {
                                *cached = Some(new_v.clone());
                            }
                            klio_runtime::DelegateKind::Observable { value, on_change } => {
                                let old = value.clone();
                                *value = new_v.clone();
                                let cb = on_change.clone();
                                drop(st);
                                if !matches!(cb, klio_runtime::Value::Null) {
                                    let _ = <Self as klio_ir::eval::Host>::call_value(
                                        self,
                                        &cb,
                                        &[klio_runtime::Value::Null, old, new_v.clone()],
                                    );
                                }
                            }
                            klio_runtime::DelegateKind::NotNull { value, .. } => {
                                *value = Some(new_v.clone());
                            }
                        }
                    }
                    return Ok(klio_runtime::Value::Unit);
                }
                _ => {}
            }
        }
        // Pack-installed binding overlay: when a loaded pack
        // registers `<typeFqn>.<name>` the Rust binding shadows the
        // interpreted shim body. Probe before the IR method walk so
        // the native fast path always wins.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            let cls_fqn = snap.class.fqn.clone();
            let cls_name = snap.class.name.clone();
            drop(snap);
            let mut probes: Vec<String> =
                vec![format!("{cls_fqn}.{name}"), format!("{cls_name}.{name}")];
            // Walk the supertype chain so a binding registered on a
            // base class (e.g. `kotlinx.coroutines.JobSupport.cancel`)
            // matches dispatch on a private subclass instance the
            // pack synthesised (`StandaloneCoroutine`, `TimeoutCoroutine`).
            {
                let mut queue: std::collections::VecDeque<String> =
                    std::collections::VecDeque::new();
                let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
                queue.push_back(cls_name.clone());
                queue.push_back(cls_fqn.clone());
                while let Some(cur) = queue.pop_front() {
                    if !seen.insert(cur.clone()) {
                        continue;
                    }
                    if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                        for sup in &def.supertype_names {
                            probes.push(format!("{sup}.{name}"));
                            queue.push_back(sup.clone());
                        }
                    }
                }
            }
            for p in &probes {
                if let Some(func) = self.prog.installed_bindings.resolve(p) {
                    let mut all_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all_args.push(receiver.clone());
                    all_args.extend_from_slice(args);
                    return self.dispatch_intrinsic(func, &all_args);
                }
            }
            // klio-stdlib intrinsics keyed by `<classFqn>.<name>` also
            // back host-synthesised instances created by
            // `new_synth_instance` (e.g. the `kotlin.sequences.SequenceScope`
            // from the `sequence { }` builder, whose `yield`/`yieldAll`
            // members are intrinsics). Restricted to anonymous/synth
            // classes so a real user/data-class instance (e.g.
            // `Value`-backed `Triple`, whose `kotlin.Triple.toList`
            // intrinsic expects the `Value::Triple` variant, not an
            // Instance) keeps its normal method/extension dispatch.
            if inst.borrow().class.is_anonymous {
                let synth_probes = [format!("{cls_fqn}.{name}"), format!("{cls_name}.{name}")];
                for p in &synth_probes {
                    if let Some(func) = self.lookup_intrinsic(p) {
                        let mut all_args: Vec<klio_runtime::Value> =
                            Vec::with_capacity(args.len() + 1);
                        all_args.push(receiver.clone());
                        all_args.extend_from_slice(args);
                        return self.dispatch_intrinsic(func, &all_args);
                    }
                }
            }
            // Built-in Any/AutoCloseable extension probes for a user
            // Instance receiver. `kotlin.io.use` / `kotlin.AutoCloseable.use`
            // are bound on the stdlib side; let the call site reach
            // them by name when the user class hasn't shadowed them.
            let any_probes = [
                format!("kotlin.io.{name}"),
                format!("kotlin.AutoCloseable.{name}"),
                format!("kotlin.Any.{name}"),
            ];
            for p in &any_probes {
                if let Some(func) = self.lookup_intrinsic(p) {
                    let mut all_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all_args.push(receiver.clone());
                    all_args.extend_from_slice(args);
                    return self.dispatch_intrinsic(func, &all_args);
                }
            }
        }
        // `Delegates.notNull` / `Delegates.observable` /
        // `Delegates.vetoable` — synthesise the proper
        // `Value::Delegate` directly. The singleton itself is
        // surfaced via `lookup_global` as a sentinel Intrinsic.
        // `Thread` handle returned by `kotlin.concurrent.thread`. The
        // body already ran to completion on the calling stack (see
        // `concurrent_thread`), so `join()` is a no-op whose
        // happens-before guarantee already holds; `isAlive` is false
        // and `name` is a stable string. `fence_and_publish` marks the
        // join boundary.
        if let klio_runtime::Value::BoundMethod {
            fqn, receiver: tid, ..
        } = receiver
            && *fqn == "kotlin.concurrent.Thread"
        {
            let id = match **tid {
                klio_runtime::Value::Long(v) => v as u64,
                _ => 0,
            };
            match name {
                "join" => {
                    return self
                        .join_spawned(id)
                        .map(|()| klio_runtime::Value::Unit)
                        .map_err(|e| match e {
                            klio_runtime::RuntimeError::Thrown(v) => {
                                klio_ir::eval::EvalError::Throw(v)
                            }
                            other => klio_ir::eval::EvalError::Type(format!("{other}")),
                        });
                }
                "isAlive" => return Ok(klio_runtime::Value::Bool(self.thread_alive(id))),
                "name" => {
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "klio-thread-{id}"
                    ))));
                }
                "start" | "interrupt" => return Ok(klio_runtime::Value::Unit),
                _ => {}
            }
        }
        if let klio_runtime::Value::Intrinsic { fqn, .. } = receiver
            && *fqn == "kotlin.properties.Delegates"
        {
            match (name, args.len()) {
                ("notNull", 0) => {
                    return Ok(klio_runtime::Value::Delegate(klio_runtime::ObjRef::new(
                        klio_runtime::DelegateKind::NotNull {
                            value: None,
                            name: String::new(),
                        },
                    )));
                }
                ("observable", 2) => {
                    return Ok(klio_runtime::Value::Delegate(klio_runtime::ObjRef::new(
                        klio_runtime::DelegateKind::Observable {
                            value: args[0].clone(),
                            on_change: args[1].clone(),
                        },
                    )));
                }
                _ => {}
            }
        }
        // Static call on a class-or-intrinsic receiver: probe stdlib
        // by `<receiver-fqn>.<name>` so `Regex.escape("x")` and
        // `Color.values()` route through the matching binding. The
        // intrinsic value carries its package-qualified fqn; classes
        // surface as the simple name (matching klio-stdlib's bare
        // class-method registrations).
        if let klio_runtime::Value::Intrinsic { fqn, .. } = receiver {
            let probe = format!("{fqn}.{name}");
            if let Some(func) = self.lookup_intrinsic(&probe) {
                return self.dispatch_intrinsic(func, args);
            }
        }
        if let klio_runtime::Value::Class(cls) = receiver {
            let probe_simple = format!("{}.{}", cls.name, name);
            if let Some(func) = self.lookup_intrinsic(&probe_simple) {
                return self.dispatch_intrinsic(func, args);
            }
            let probe_fqn = format!("{}.{}", cls.fqn, name);
            if let Some(func) = self.lookup_intrinsic(&probe_fqn) {
                return self.dispatch_intrinsic(func, args);
            }
        }
        // `List<T>.optimizeReadOnlyList()` — an internal upstream
        // helper that collapses 0/1-element ArrayLists into the
        // shared `EmptyList` / `listOf(single)` singletons. klio's
        // runtime lists are uniform, so the helper is a no-op:
        // return the receiver unchanged.
        if name == "optimizeReadOnlyList"
            && args.is_empty()
            && matches!(receiver, klio_runtime::Value::List { .. })
        {
            return Ok(receiver.clone());
        }
        // `listIterator(index)` and `listIterator()` on a List: a
        // ListIterator starting from the given position. klio's
        // runtime models it with the same `Value::Iterator` shape as
        // a plain iterator — the upstream stdlib bodies only use
        // `hasNext`/`next` on the result.
        if name == "listIterator"
            && args.len() <= 1
            && let klio_runtime::Value::List { items, .. } = receiver
        {
            let start = match args.first() {
                Some(klio_runtime::Value::Int(n)) => *n as usize,
                Some(klio_runtime::Value::Long(n)) => *n as usize,
                _ => 0,
            };
            let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
            return Ok(klio_runtime::Value::Iterator {
                items: klio_runtime::ObjRef::new(items_clone),
                pos: klio_runtime::ObjRef::new(start),
                prim: None,
            });
        }
        // `for (x in someIterator)` lowers as `someIterator.iterator()`
        // → the iterator itself (matches Kotlin's `Iterator: Iterable`
        // / self-iterator convention upstream stdlib relies on).
        if name == "iterator"
            && args.is_empty()
            && matches!(
                receiver,
                klio_runtime::Value::Iterator { .. } | klio_runtime::Value::RangeIter { .. }
            )
        {
            return Ok(receiver.clone());
        }
        // Built-in iterator protocol for collections + ranges. The
        // IR's for-loop lowers as `receiver.iterator()` plus a
        // `hasNext` / `next` loop, so these have to dispatch
        // natively rather than through the stdlib FQN table.
        if name == "iterator" && args.is_empty() {
            match receiver {
                klio_runtime::Value::List { items, .. } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Set { items, .. } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Map { entries, .. } => {
                    let entries_clone: Vec<klio_runtime::Value> = entries
                        .borrow()
                        .iter()
                        .map(|(k, v)| klio_runtime::Value::MapEntry {
                            key: Box::new(k.clone()),
                            value: Box::new(v.clone()),
                            backing: None,
                        })
                        .collect();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(entries_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                klio_runtime::Value::Range {
                    start,
                    end,
                    step,
                    kind,
                } => {
                    // Lazy O(1)-memory iterator: compute each element
                    // arithmetically rather than materialising the whole
                    // range into a Vec (a `for (i in 0..N)` / `repeat(N)`
                    // would otherwise allocate N Values up front and OOM).
                    return Ok(klio_runtime::Value::RangeIter {
                        cur: klio_runtime::ObjRef::new(*start),
                        end: *end,
                        step: *step,
                        kind: *kind,
                    });
                }
                klio_runtime::Value::Array { items, prim } => {
                    let items_clone: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items_clone),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: *prim,
                    });
                }
                klio_runtime::Value::String(s) => {
                    let items: Vec<klio_runtime::Value> =
                        s.encode_utf16().map(klio_runtime::Value::Char).collect();
                    return Ok(klio_runtime::Value::Iterator {
                        items: klio_runtime::ObjRef::new(items),
                        pos: klio_runtime::ObjRef::new(0),
                        prim: None,
                    });
                }
                _ => {}
            }
        }
        // Sequence terminal ops: materialise the lazy pipeline then
        // dispatch the op against the materialised vector.
        if let klio_runtime::Value::Sequence(_) = receiver {
            let terminal = matches!(
                name,
                "toList"
                    | "toMutableList"
                    | "toSet"
                    | "count"
                    | "sum"
                    | "average"
                    | "sumOf"
                    // first/firstOrNull/find/any/none are handled by
                    // short-circuiting Sequence intrinsics (bounded
                    // materialization) — must NOT be eagerly materialized here.
                    | "last"
                    | "lastOrNull"
                    | "forEach"
                    | "fold"
                    | "reduce"
                    | "iterator"
                    | "max"
                    | "maxOrNull"
                    | "min"
                    | "minOrNull"
                    | "maxBy"
                    | "minBy"
                    | "maxByOrNull"
                    | "minByOrNull"
                    | "maxOf"
                    | "minOf"
                    | "joinToString"
                    | "all"
                    | "contains"
                    | "groupBy"
                    | "associate"
                    | "associateBy"
                    | "associateWith"
                    | "partition"
                    | "indexOf"
                    | "indexOfFirst"
                    | "toMap"
                    | "toHashSet"
                    | "toMutableSet"
                    | "windowed"
                    | "chunked"
                    | "zipWithNext"
                    | "zip"
                    | "unzip"
                    | "scan"
                    | "runningFold"
                    | "runningReduce"
                    | "plus"
                    | "minus"
                    | "reduceOrNull"
                    | "foldRight"
                    | "reduceRight"
            );
            if terminal {
                let items = self.materialise_sequence(receiver)?;
                let as_list = klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: false,
                    enum_class: None,
                    backing: None,
                };
                // Materialize Sequence arguments too, so ops that take another
                // sequence (e.g. `seq.zip(otherSeq)`) reach the List intrinsic
                // with a List argument it can iterate.
                let mut margs: Vec<klio_runtime::Value> = Vec::with_capacity(args.len());
                for a in args {
                    if matches!(a, klio_runtime::Value::Sequence(_)) {
                        let it = self.materialise_sequence(a)?;
                        margs.push(klio_runtime::Value::List {
                            items: klio_runtime::ObjRef::new(it),
                            mutable: false,
                            enum_class: None,
                            backing: None,
                        });
                    } else {
                        margs.push(a.clone());
                    }
                }
                return self.call_member(&as_list, name, &margs);
            }
        }
        // Sequence pipeline ops: append the op to a fresh
        // SequenceData and return a new Sequence value.
        if let klio_runtime::Value::Sequence(seq) = receiver {
            let make_seq = |new_op: klio_runtime::SeqOp| -> klio_runtime::Value {
                let mut ops = seq.ops.clone();
                ops.push(new_op);
                klio_runtime::Value::Sequence(Arc::new(klio_runtime::SequenceData {
                    source: seq.source.clone(),
                    ops,
                }))
            };
            match (name, args.len()) {
                ("map", 1) => return Ok(make_seq(klio_runtime::SeqOp::Map(args[0].clone()))),
                ("onEach", 1) => return Ok(make_seq(klio_runtime::SeqOp::OnEach(args[0].clone()))),
                ("mapIndexed", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::MapIndexed(args[0].clone())));
                }
                ("filterIndexed", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::FilterIndexed(
                        args[0].clone(),
                    )));
                }
                ("filter", 1) => return Ok(make_seq(klio_runtime::SeqOp::Filter(args[0].clone()))),
                ("filterNot", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::FilterNot(args[0].clone())));
                }
                ("take", 1) => {
                    if let Some(n) = args[0].as_i64() {
                        return Ok(make_seq(klio_runtime::SeqOp::Take(n)));
                    }
                }
                ("drop", 1) => {
                    if let Some(n) = args[0].as_i64() {
                        return Ok(make_seq(klio_runtime::SeqOp::Drop(n)));
                    }
                }
                ("takeWhile", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::TakeWhile(args[0].clone())));
                }
                ("dropWhile", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::DropWhile(args[0].clone())));
                }
                ("flatMap", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::FlatMap(args[0].clone())));
                }
                ("distinct", 0) => return Ok(make_seq(klio_runtime::SeqOp::Distinct)),
                ("distinctBy", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::DistinctBy(args[0].clone())));
                }
                ("sorted", 0) => return Ok(make_seq(klio_runtime::SeqOp::Sorted(false))),
                ("sortedDescending", 0) => return Ok(make_seq(klio_runtime::SeqOp::Sorted(true))),
                ("sortedBy", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedBy(
                        args[0].clone(),
                        false,
                    )));
                }
                ("sortedByDescending", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedBy(
                        args[0].clone(),
                        true,
                    )));
                }
                ("sortedWith", 1) => {
                    return Ok(make_seq(klio_runtime::SeqOp::SortedWith(args[0].clone())));
                }
                // `constrainOnce()` constrains a sequence to a single
                // iteration. klio re-materializes from the (immutable) source
                // each time rather than holding a consumable iterator, so the
                // constraint is a no-op: return the sequence unchanged.
                ("constrainOnce", 0) => return Ok(receiver.clone()),
                _ => {}
            }
        }
        // Inner-class construction: `outer.Inner(args)` constructs an
        // Inner instance with the outer stored on the instance's
        // `outer` field. The lifted inner class lives at top level.
        if let klio_runtime::Value::Instance(outer_inst) = receiver {
            let def_opt = self.classes.borrow().get(name).cloned();
            if let Some(def) = def_opt
                && def.is_inner
            {
                let class_id = self.module.class_id(name);
                if let Some(class_id) = class_id {
                    let v = <Self as klio_ir::eval::Host>::new_instance(self, class_id, args)?;
                    if let klio_runtime::Value::Instance(i) = &v {
                        i.borrow_mut().outer =
                            Some(klio_runtime::Value::Instance(outer_inst.clone()));
                    }
                    return Ok(v);
                }
            }
        }
        // Nested-class construction on a class receiver:
        // `Container.Nested(args)` or `Sealed.Variant(args)` — look
        // up the named class in the module table and construct. Prefer
        // the receiver's OWN nested member (resolved by qualified FQN)
        // over a same-simple-name global: a user `sealed class S { data
        // class Error(...) }` declares `S.Error`, which must not
        // resolve to the builtin `kotlin.Error` that shares the simple
        // name. Fall back to the bare simple-name lookup for nested
        // types whose qualified FQN isn't registered.
        if let klio_runtime::Value::Class(cls) = receiver {
            let qualified = self
                .module
                .class_id_by_fqn(&format!("{}.{}", cls.fqn, name))
                .or_else(|| {
                    if cls.name == cls.fqn {
                        None
                    } else {
                        self.module
                            .class_id_by_fqn(&format!("{}.{}", cls.name, name))
                    }
                });
            if let Some(class_id) = qualified.or_else(|| self.module.class_id(name)) {
                return <Self as klio_ir::eval::Host>::new_instance(self, class_id, args);
            }
        }
        // Companion forwarding for method calls: `Foo.parse("…")`
        // routes through the companion singleton's method.
        if let klio_runtime::Value::Class(cls) = receiver {
            // companion_singletons is keyed by simple name; an
            // embedded-stdlib / pack class can present its fqn, so
            // probe both the name and the fqn's simple tail.
            // Walks the supertype chain so an inherited companion
            // (`class Sub : Base()` with `companion object` on
            // `Base`) is reachable via `Sub.<member>`.
            let mut probe_classes: Vec<String> = Vec::new();
            probe_classes.push(cls.name.clone());
            if !cls.fqn.is_empty() && cls.fqn != cls.name {
                probe_classes.push(cls.fqn.clone());
            }
            // Walk supertypes for inherited companions.
            let runtime_def_opt = self.classes.borrow().get(&cls.name).cloned();
            if let Some(def) = runtime_def_opt {
                let mut cur = def.parent.borrow().clone();
                while let Some(p) = cur {
                    probe_classes.push(p.name.clone());
                    if !p.fqn.is_empty() && p.fqn != p.name {
                        probe_classes.push(p.fqn.clone());
                    }
                    let parent = p.parent.borrow().clone();
                    cur = parent;
                }
            }
            let mut comp_name: Option<String> = None;
            for k in &probe_classes {
                if let Some(c) = self.module.registry.companion_singletons.get(k).cloned() {
                    comp_name = Some(c);
                    break;
                }
                if let Some(tail) = k.rsplit('.').next()
                    && let Some(c) = self.module.registry.companion_singletons.get(tail).cloned()
                {
                    comp_name = Some(c);
                    break;
                }
            }
            if let Some(comp_name) = comp_name {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton) = singleton
                    && matches!(singleton, klio_runtime::Value::Instance(_))
                {
                    // Forward to the companion instance. Only the
                    // specific "this exact member is not on the
                    // companion" Unimplemented falls through (so
                    // other resolution can try); any *other*
                    // error — including an Unimplemented from
                    // deeper inside the companion method's body —
                    // propagates rather than being masked as
                    // member-on-KClass.
                    let no_such = format!("`{name}` on");
                    match self.call_member(&singleton, name, args) {
                        Ok(v) => return Ok(v),
                        Err(klio_ir::eval::EvalError::Unimplemented(m))
                            if m.contains("Vm::call_member") && m.contains(&no_such) => {}
                        Err(e) => return Err(e),
                    }
                }
            }
            // Enum.values() — synthesise the entries list from the class.
            if cls.is_enum && (name == "values") && args.is_empty() {
                let items: Vec<klio_runtime::Value> = cls
                    .enum_entries
                    .borrow()
                    .iter()
                    .map(|(_, v)| v.clone())
                    .collect();
                return Ok(klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: false,
                    enum_class: Some(Arc::new(cls.name.clone())),
                    backing: None,
                });
            }
            // Enum.valueOf("X") — find entry by name.
            if cls.is_enum
                && name == "valueOf"
                && args.len() == 1
                && let klio_runtime::Value::String(s) = &args[0]
            {
                if let Some((_, v)) = cls
                    .enum_entries
                    .borrow()
                    .iter()
                    .find(|(n, _)| n == s.as_str())
                {
                    return Ok(v.clone());
                }
                return Err(klio_ir::eval::EvalError::Throw(
                    klio_runtime::Value::Exception {
                        fqn: std::sync::Arc::new("kotlin.IllegalArgumentException".to_string()),
                        message: Some(std::sync::Arc::new(format!(
                            "No enum constant {}.{}",
                            cls.fqn, s
                        ))),
                        cause: None,
                    },
                ));
            }
        }
        // Null-receiver `equals` — `a == null` with `a: T?` lowers
        // through `equals`, which Kotlin returns `true` only when
        // both sides are null. `null.equals(x)` ≡ `x == null`.
        if matches!(receiver, klio_runtime::Value::Null) && name == "equals" && args.len() == 1 {
            return Ok(klio_runtime::Value::Bool(matches!(
                args[0],
                klio_runtime::Value::Null
            )));
        }
        // SAM-instance dispatch: a synthetic `FunInterface { … }`
        // wrapper carries its lambda under `__sam_target__`. Any
        // method call on the receiver invokes the stored callable.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let target = inst.borrow().get("__sam_target__");
            if let Some(target) = target {
                // A SAM wrapper invokes its lambda for *any* method
                // name. Under a member-only probe that is not a real
                // member of the named call (`c.collect(…)` on a SAM
                // `FlowCollector` whose method is `emit`), so report
                // not-found and let the probe continue its
                // implicit-receiver search. Non-probe resolution still
                // SAM-dispatches normally.
                if member_only {
                    return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                        "Vm::call_member `{name}` (member-only: \
                             SAM dispatch is not a member)"
                    )));
                }
                // The SAM wrapper invokes its lambda for the fun
                // interface's own method(s) — its single abstract method
                // (`compare` / `test` / `apply`). A call by a name that is
                // NOT a declared method of the interface is a top-level
                // extension on the SAM (`cmp.reversed()`, `cmp.thenBy { }`
                // — the stdlib `Comparator<T>` extensions): it must
                // dispatch as an extension with the SAM as receiver, not
                // splice the lambda with the extension's (wrong-arity)
                // args. The interface's declared method names live in the
                // registry's hierarchy map; when it has no entry (a
                // synthetic wrapper with no method table), keep the legacy
                // invoke-for-any-name behaviour.
                let cls_name = inst.borrow().class.name.clone();
                let declared = self.module.registry.hierarchy_methods.get(&cls_name);
                let dispatch_lambda = match declared {
                    Some(methods) if !methods.is_empty() => methods.contains(name),
                    _ => true,
                };
                if dispatch_lambda {
                    return self.call_value(&target, args);
                }
            }
        }
        // Bound method/property-reference dispatch: a `recv::member`
        // wrapper routes calls through the captured receiver + name.
        // Property refs (receiver is a class) handle `get(arg)` as
        // a property read on `arg`. Method refs (receiver is an
        // instance) forward all args through `call_member`.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let snap = inst.borrow();
            let recv_capt = snap.get("__bound_receiver__");
            let name_capt = snap.get("__bound_name__");
            drop(snap);
            if let (Some(rc), Some(klio_runtime::Value::String(n))) = (recv_capt, name_capt) {
                if matches!(name, "name" | "simpleName") {
                    // Field reads on the ref itself; handled by
                    // get_field.
                } else if matches!(&rc, klio_runtime::Value::Class(_)) {
                    // Unbound reference invoked through `get`/`call`/
                    // `invoke`: a property ref reads `arg.<n>`, a
                    // function ref calls `arg.<n>(rest)`.
                    if matches!(name, "get" | "call" | "invoke") && !args.is_empty() {
                        let first = args[0].clone();
                        let rest: Vec<klio_runtime::Value> = args[1..].to_vec();
                        if rest.is_empty() && member_is_property(&self.classes, &first, &n) {
                            return self.get_field(&first, &n);
                        }
                        return self.call_member(&first, &n, &rest);
                    }
                } else if matches!(name, "get" | "call" | "invoke")
                    && args.is_empty()
                    && member_is_property(&self.classes, &rc, &n)
                {
                    // Bound property reference invoked with no args.
                    return self.get_field(&rc, &n);
                } else {
                    // Bound method reference: forward the call.
                    return self.call_member(&rc, &n, args);
                }
            }
        }
        // SAM conversion: a callable (lambda / closure / function
        // ref) passed where a `fun interface` is expected accepts
        // any method call by forwarding to the underlying invoke.
        if matches!(
            receiver,
            klio_runtime::Value::Lambda { .. }
                | klio_runtime::Value::IrClosure { .. }
                | klio_runtime::Value::Function { .. }
                | klio_runtime::Value::Intrinsic { .. }
        ) {
            // A user extension on a function type
            // (`fun (() -> T).foo()`) lowers to a top-level fn whose
            // first param is the receiver. When one named `name`
            // exists, it must win over the SAM-invoke shortcut, which
            // would otherwise just call the receiver and discard the
            // intended dispatch. Defer to the extension-fn fallback.
            let has_ext = self.module.funcs_by_simple_name(name).iter().any(|fid| {
                self.module.funcs.get(fid.0 as usize).is_some_and(|f| {
                    f.params.first().is_some_and(|p| p.name == "this")
                        && f.params.len() > args.len()
                })
            });
            if name != "invoke"
                && !has_ext
                && let Ok(v) = self.call_value(receiver, args)
            {
                return Ok(v);
            }
        }
        // KClass equality + hash + toString — structural by the
        // class's `name`. `Person::class == Person::class` is true,
        // distinct classes compare unequal.
        if let klio_runtime::Value::Class(a) = receiver {
            match (name, args.len()) {
                ("equals", 1) => {
                    let eq = if let klio_runtime::Value::Class(b) = &args[0] {
                        a.name == b.name
                    } else {
                        false
                    };
                    return Ok(klio_runtime::Value::Bool(eq));
                }
                ("hashCode", 0) => {
                    use std::hash::{Hash, Hasher};
                    let mut h = std::collections::hash_map::DefaultHasher::new();
                    a.name.hash(&mut h);
                    return Ok(klio_runtime::Value::new_int(h.finish() as i64));
                }
                ("toString", 0) => {
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "class {}",
                        a.name
                    ))));
                }
                _ => {}
            }
        }
        // KFunction reflection surface on a closure / function value.
        // `f.call(a, b)` / `f.invoke(a, b)` dispatch the callable;
        // `f.name` / `f.parameters` report the lowered Func metadata.
        if matches!(
            receiver,
            klio_runtime::Value::IrClosure { .. }
                | klio_runtime::Value::Lambda { .. }
                | klio_runtime::Value::Function { .. }
        ) {
            match name {
                "invoke" | "call" => {
                    return <Self as klio_ir::eval::Host>::call_value(self, receiver, args);
                }
                _ => {}
            }
            if args.is_empty()
                && let klio_runtime::Value::IrClosure { id, .. } = receiver
                && let Some(info) = self.closures.get(*id as usize)
                && let Some(f) = self.module.funcs.get(info.body_func.0 as usize)
            {
                match name {
                    "name" => {
                        return Ok(klio_runtime::Value::String(Arc::new(f.name.clone())));
                    }
                    "parameters" => {
                        let items: Vec<klio_runtime::Value> = f
                            .params
                            .iter()
                            .map(|p| klio_runtime::Value::String(Arc::new(p.name.clone())))
                            .collect();
                        return Ok(klio_runtime::Value::List {
                            items: klio_runtime::ObjRef::new(items),
                            mutable: false,
                            enum_class: None,
                            backing: None,
                        });
                    }
                    _ => {}
                }
            }
        }
        // PropertyRef invocation: `nameRef.get(p)` / `nameRef.call(p)`
        // reads the named property from the receiver. `hashCode`
        // and `equals` route to structural equality on the name.
        if let klio_runtime::Value::PropertyRef { name: pname } = receiver {
            match (name, args.len()) {
                ("get" | "call" | "invoke", 1) => {
                    return self.get_field(&args[0], pname);
                }
                ("hashCode", 0) => {
                    return Ok(klio_runtime::Value::new_int(i64::from(
                        value_structural_hash(receiver),
                    )));
                }
                ("equals", 1) => {
                    return Ok(klio_runtime::Value::Bool(
                        klio_runtime::Value::structural_eq(receiver, &args[0]),
                    ));
                }
                ("toString", 0) => {
                    return Ok(klio_runtime::Value::String(Arc::new(format!(
                        "property {pname}"
                    ))));
                }
                _ => {}
            }
        }
        // Enum entries compare by ordinal natively. `Color.RED <
        // Color.BLUE` lowers as `RED.compareTo(BLUE)`.
        if name == "compareTo"
            && args.len() == 1
            && let (klio_runtime::Value::Instance(a), klio_runtime::Value::Instance(b)) =
                (receiver, &args[0])
        {
            let cls = a.borrow().class.clone();
            if cls.is_enum {
                let ord_a = a
                    .borrow()
                    .get("ordinal")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                let ord_b = b
                    .borrow()
                    .get("ordinal")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                return Ok(klio_runtime::Value::new_int(ord_a - ord_b));
            }
        }
        // Natural-order sort on a list of user `Value::Instance` —
        // dispatch each pair through `compareTo` so user-overridden
        // ordering wins. Stdlib's `compare_values` rejects Instance
        // pairs; this branch wins before the stdlib probe.
        if (name == "sorted" || name == "sortedDescending")
            && args.is_empty()
            && let klio_runtime::Value::List { items, .. } = receiver
        {
            let snap: Vec<klio_runtime::Value> = items.borrow().clone();
            if snap
                .iter()
                .any(|v| matches!(v, klio_runtime::Value::Instance(_)))
            {
                let mut sorted = snap;
                let descending = name == "sortedDescending";
                for i in 1..sorted.len() {
                    let mut j = i;
                    while j > 0 {
                        let a = sorted[j - 1].clone();
                        let b = sorted[j].clone();
                        let cmp_val = self.call_member(&a, "compareTo", &[b])?;
                        let n = cmp_val.as_i64().unwrap_or(0);
                        let greater = if descending { n < 0 } else { n > 0 };
                        if greater {
                            sorted.swap(j - 1, j);
                            j -= 1;
                        } else {
                            break;
                        }
                    }
                }
                return Ok(klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(sorted),
                    mutable: false,
                    enum_class: None,
                    backing: None,
                });
            }
        }
        // Comparator chaining + reversal + compare.
        if let klio_runtime::Value::Comparator { steps, descending } = receiver {
            if name == "compare" && args.len() == 2 {
                let a = args[0].clone();
                let b = args[1].clone();
                let mut ord = std::cmp::Ordering::Equal;
                if steps.is_empty() {
                    ord = klio_stdlib::compare_values(&a, &b)
                        .map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))?;
                } else {
                    for (sel, step_desc) in steps.iter() {
                        // Two shapes are supported:
                        //   key-selector lambda: `{ x -> key }` —
                        //     invoke with one arg per side, compare
                        //     the resulting keys.
                        //   comparator lambda: `{ a, b -> n }` —
                        //     invoke once with both values; the
                        //     return value is the comparison int.
                        let n_params = match sel {
                            klio_runtime::Value::IrClosure { id, .. } => {
                                self.closures.get(*id as usize).map_or(1, |c| c.n_params)
                            }
                            _ => 1,
                        };
                        let o = if n_params >= 2 {
                            let r = self.call_value(sel, &[a.clone(), b.clone()])?;
                            let n = r.as_i64().unwrap_or(0);
                            n.cmp(&0)
                        } else {
                            let ka = self.call_value(sel, std::slice::from_ref(&a))?;
                            let kb = self.call_value(sel, std::slice::from_ref(&b))?;
                            klio_stdlib::compare_values(&ka, &kb)
                                .map_err(|e| klio_ir::eval::EvalError::Type(format!("{e}")))?
                        };
                        let flipped = if *step_desc { o.reverse() } else { o };
                        if flipped != std::cmp::Ordering::Equal {
                            ord = flipped;
                            break;
                        }
                    }
                }
                if *descending {
                    ord = ord.reverse();
                }
                let n: i64 = match ord {
                    std::cmp::Ordering::Less => -1,
                    std::cmp::Ordering::Equal => 0,
                    std::cmp::Ordering::Greater => 1,
                };
                return Ok(klio_runtime::Value::new_int(n));
            }
            match name {
                "thenBy" | "thenByDescending" if args.len() == 1 => {
                    let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                    chain.push((args[0].clone(), name == "thenByDescending"));
                    return Ok(klio_runtime::Value::Comparator {
                        steps: Arc::new(chain),
                        descending: *descending,
                    });
                }
                "then" | "thenComparing" | "thenDescending" | "thenComparator"
                    if args.len() == 1 =>
                {
                    let invert = name == "thenDescending";
                    match &args[0] {
                        klio_runtime::Value::Comparator {
                            steps: other_steps,
                            descending: other_desc,
                        } => {
                            let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                            for (sel, d) in other_steps.iter() {
                                chain.push((sel.clone(), *d ^ other_desc ^ invert));
                            }
                            return Ok(klio_runtime::Value::Comparator {
                                steps: Arc::new(chain),
                                descending: *descending,
                            });
                        }
                        klio_runtime::Value::Lambda { .. }
                        | klio_runtime::Value::IrClosure { .. } => {
                            let mut chain: Vec<(klio_runtime::Value, bool)> = (**steps).clone();
                            chain.push((args[0].clone(), invert));
                            return Ok(klio_runtime::Value::Comparator {
                                steps: Arc::new(chain),
                                descending: *descending,
                            });
                        }
                        _ => {}
                    }
                }
                "reversed" if args.is_empty() => {
                    return Ok(klio_runtime::Value::Comparator {
                        steps: Arc::clone(steps),
                        descending: !*descending,
                    });
                }
                _ => {}
            }
        }
        // `r.contains(x)` on a Range — covers Int/Long/Char ranges
        // used in `when` arms and `x in 'a'..'z'` checks.
        if name == "contains"
            && args.len() == 1
            && let klio_runtime::Value::Range {
                start,
                end,
                step,
                kind,
            } = receiver
        {
            let inside = match (&args[0], kind) {
                (klio_runtime::Value::Char(c), klio_runtime::RangeKind::Char) => {
                    let cv = i64::from(*c);
                    cv >= *start && cv <= *end && (cv - *start) % step == 0
                }
                _ => {
                    if let Some(v) = args[0].as_i64() {
                        v >= *start && v <= *end && (v - *start) % step == 0
                    } else {
                        false
                    }
                }
            };
            return Ok(klio_runtime::Value::Bool(inside));
        }
        // `m.contains(key)` / `m.containsKey(key)` / `m.containsValue(v)` for Map.
        if let klio_runtime::Value::Map { entries, .. } = receiver {
            match (name, args.len()) {
                ("contains" | "containsKey", 1) => {
                    let needle = &args[0];
                    let has = entries
                        .borrow()
                        .iter()
                        .any(|(k, _)| klio_runtime::Value::structural_eq_boxed(k, needle));
                    return Ok(klio_runtime::Value::Bool(has));
                }
                ("containsValue", 1) => {
                    let needle = &args[0];
                    let has = entries
                        .borrow()
                        .iter()
                        .any(|(_, v)| klio_runtime::Value::structural_eq_boxed(v, needle));
                    return Ok(klio_runtime::Value::Bool(has));
                }
                _ => {}
            }
        }
        // `Collection<T>.toTypedArray()` — used by upstream
        // `Collection<Deferred<T>>.awaitAll()`
        // (`AwaitAll(toTypedArray()).await()`).
        if let klio_runtime::Value::List { items, .. } = receiver
            && name == "toTypedArray"
            && args.is_empty()
        {
            let v: Vec<klio_runtime::Value> = items.borrow().clone();
            return Ok(klio_runtime::Value::Array {
                items: klio_runtime::ObjRef::new(v),
                prim: None,
            });
        }
        // Generic Array → List conversion + a couple of frequently
        // used array-shape methods.
        if let klio_runtime::Value::Array { items, .. } = receiver {
            match (name, args.len()) {
                ("toList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                        enum_class: None,
                        backing: None,
                    });
                }
                ("toMutableList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: true,
                        enum_class: None,
                        backing: None,
                    });
                }
                ("asList", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::List {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                        enum_class: None,
                        backing: None,
                    });
                }
                ("toTypedArray", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Array {
                        items: klio_runtime::ObjRef::new(v),
                        prim: None,
                    });
                }
                ("toSet", 0) => {
                    let v: Vec<klio_runtime::Value> = items.borrow().clone();
                    return Ok(klio_runtime::Value::Set {
                        items: klio_runtime::ObjRef::new(v),
                        mutable: false,
                        backing: None,
                    });
                }
                // `CharArray.concatToString()` /
                // `concatToString(startIndex, endIndex)` — join the
                // Char elements.
                ("concatToString", 0 | 2) => {
                    let chars = items.borrow();
                    let (start, end) = if args.len() == 2 {
                        let s = args[0].as_i64().unwrap_or(0).max(0) as usize;
                        let e = args[1].as_i64().unwrap_or(chars.len() as i64).max(0) as usize;
                        (s.min(chars.len()), e.min(chars.len()))
                    } else {
                        (0, chars.len())
                    };
                    let s = klio_runtime::char_units_to_string(
                        chars[start..end.max(start)].iter().filter_map(|v| match v {
                            klio_runtime::Value::Char(c) => Some(*c),
                            _ => None,
                        }),
                    );
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                _ => {}
            }
        }
        // Indexed get/set on Array variants.
        if name == "get"
            && args.len() == 1
            && let klio_runtime::Value::Array { items, .. } = receiver
            && let Some(idx) = args[0].as_i64()
        {
            let b = items.borrow();
            if let Some(v) = b.get(idx as usize).cloned() {
                return Ok(v);
            }
            // Out-of-bounds (or negative) array index: throw a catchable
            // IndexOutOfBoundsException, not fall through to a path that
            // mis-casts and raises ClassCastException.
            let len = b.len();
            return Err(klio_ir::eval::EvalError::Throw(
                klio_runtime::Value::Exception {
                    fqn: Arc::new("kotlin.ArrayIndexOutOfBoundsException".to_string()),
                    message: Some(Arc::new(format!(
                        "Index {idx} out of bounds for length {len}"
                    ))),
                    cause: None,
                },
            ));
        }
        if name == "set"
            && args.len() == 2
            && let klio_runtime::Value::Array { items, .. } = receiver
            && let Some(idx) = args[0].as_i64()
        {
            let len = items.borrow().len();
            if let Some(slot) = items.borrow_mut().get_mut(idx as usize) {
                *slot = args[1].clone();
                return Ok(klio_runtime::Value::Unit);
            }
            return Err(klio_ir::eval::EvalError::Throw(
                klio_runtime::Value::Exception {
                    fqn: Arc::new("kotlin.ArrayIndexOutOfBoundsException".to_string()),
                    message: Some(Arc::new(format!(
                        "Index {idx} out of bounds for length {len}"
                    ))),
                    cause: None,
                },
            ));
        }
        // Built-in collection in-place mutation operators.
        match (receiver, name) {
            (
                klio_runtime::Value::List {
                    items,
                    mutable: true,
                    ..
                },
                "plusAssign",
            ) if args.len() == 1 => {
                items.borrow_mut().push(args[0].clone());
                return Ok(klio_runtime::Value::Unit);
            }
            (
                klio_runtime::Value::List {
                    items,
                    mutable: true,
                    ..
                },
                "minusAssign",
            ) if args.len() == 1 => {
                let mut v = items.borrow_mut();
                if let Some(pos) = v
                    .iter()
                    .position(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.remove(pos);
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (
                klio_runtime::Value::Set {
                    items,
                    mutable: true,
                    ..
                },
                "plusAssign",
            ) if args.len() == 1 => {
                let mut v = items.borrow_mut();
                if !v
                    .iter()
                    .any(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.push(args[0].clone());
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (
                klio_runtime::Value::Set {
                    items,
                    mutable: true,
                    ..
                },
                "minusAssign",
            ) if args.len() == 1 => {
                let mut v = items.borrow_mut();
                if let Some(pos) = v
                    .iter()
                    .position(|x| klio_runtime::Value::structural_eq(x, &args[0]))
                {
                    v.remove(pos);
                }
                return Ok(klio_runtime::Value::Unit);
            }
            (
                klio_runtime::Value::Map {
                    entries,
                    mutable: true,
                    ..
                },
                "plusAssign",
            ) if args.len() == 1 => {
                if let klio_runtime::Value::Pair(k, val) = &args[0] {
                    let mut e = entries.borrow_mut();
                    if let Some(slot) = e
                        .iter_mut()
                        .find(|(ek, _)| klio_runtime::Value::structural_eq(ek, k))
                    {
                        slot.1 = (**val).clone();
                    } else {
                        e.push(((**k).clone(), (**val).clone()));
                    }
                }
                return Ok(klio_runtime::Value::Unit);
            }
            _ => {}
        }
        // Pair / Triple / MapEntry component / first / second / etc.
        match (receiver, name) {
            (klio_runtime::Value::Pair(a, _), "component1" | "first") => return Ok((**a).clone()),
            (klio_runtime::Value::Pair(_, b), "component2" | "second") => return Ok((**b).clone()),
            (klio_runtime::Value::Triple(a, _, _), "component1" | "first") => {
                return Ok((**a).clone());
            }
            (klio_runtime::Value::Triple(_, b, _), "component2" | "second") => {
                return Ok((**b).clone());
            }
            (klio_runtime::Value::Triple(_, _, c), "component3" | "third") => {
                return Ok((**c).clone());
            }
            (klio_runtime::Value::MapEntry { key, .. }, "component1" | "key") => {
                return Ok((**key).clone());
            }
            (klio_runtime::Value::MapEntry { value, .. }, "component2" | "value") => {
                return Ok((**value).clone());
            }
            // `MutableMap.MutableEntry.setValue(v)` writes through to the
            // backing map (when this entry came from a live `entries` view)
            // and returns the previous value.
            (
                klio_runtime::Value::MapEntry {
                    key,
                    value,
                    backing,
                },
                "setValue",
            ) => {
                let new_v = args.first().cloned().unwrap_or(klio_runtime::Value::Unit);
                let prev = (**value).clone();
                if let Some(entries) = backing {
                    let mut b = entries.borrow_mut();
                    if let Some(slot) = b
                        .iter_mut()
                        .find(|(k, _)| klio_runtime::Value::structural_eq(k, key))
                    {
                        slot.1 = new_v;
                    }
                }
                return Ok(prev);
            }
            _ => {}
        }
        if let klio_runtime::Value::Iterator { items, pos, .. } = receiver {
            match name {
                "hasNext" if args.is_empty() => {
                    return Ok(klio_runtime::Value::Bool(
                        *pos.borrow() < items.borrow().len(),
                    ));
                }
                "next" | "nextInt" | "nextLong" | "nextChar" | "nextByte" | "nextShort"
                | "nextDouble" | "nextFloat" | "nextBoolean"
                    if args.is_empty() =>
                {
                    let p = *pos.borrow();
                    let v = items.borrow().get(p).cloned().ok_or_else(|| {
                        klio_ir::eval::EvalError::Throw(klio_runtime::Value::Exception {
                            fqn: Arc::new("kotlin.NoSuchElementException".to_string()),
                            message: Some(Arc::new("iterator exhausted".into())),
                            cause: None,
                        })
                    })?;
                    *pos.borrow_mut() = p + 1;
                    return Ok(v);
                }
                _ => {}
            }
        }
        // Lazy range-iterator protocol: compute the next element from
        // `cur`/`step` so iteration is O(1) memory. `hasNext` compares
        // against the inclusive `end` honoring the step's sign; `next`
        // yields the current value (widened by `kind`) then advances.
        if let klio_runtime::Value::RangeIter {
            cur,
            end,
            step,
            kind,
        } = receiver
        {
            match name {
                "hasNext" if args.is_empty() => {
                    let c = *cur.borrow();
                    let more = match (*step).cmp(&0) {
                        std::cmp::Ordering::Greater => c <= *end,
                        std::cmp::Ordering::Less => c >= *end,
                        std::cmp::Ordering::Equal => false,
                    };
                    return Ok(klio_runtime::Value::Bool(more));
                }
                "next" | "nextInt" | "nextLong" | "nextChar" | "nextByte" | "nextShort"
                | "nextDouble" | "nextFloat" | "nextBoolean"
                    if args.is_empty() =>
                {
                    let c = *cur.borrow();
                    let more = match (*step).cmp(&0) {
                        std::cmp::Ordering::Greater => c <= *end,
                        std::cmp::Ordering::Less => c >= *end,
                        std::cmp::Ordering::Equal => false,
                    };
                    if !more {
                        return Err(klio_ir::eval::EvalError::Throw(
                            klio_runtime::Value::Exception {
                                fqn: Arc::new("kotlin.NoSuchElementException".to_string()),
                                message: Some(Arc::new("iterator exhausted".into())),
                                cause: None,
                            },
                        ));
                    }
                    *cur.borrow_mut() = c.saturating_add(*step);
                    return Ok(match kind {
                        klio_runtime::RangeKind::Int => klio_runtime::Value::new_int(c),
                        klio_runtime::RangeKind::Long => klio_runtime::Value::Long(c),
                        klio_runtime::RangeKind::Char => klio_runtime::Value::Char(c as u16),
                    });
                }
                _ => {}
            }
        }
        // Data-class auto members (componentN, equals, hashCode,
        // toString, copy) — synthesised structurally from the
        // primary-ctor fields. Resolves before the IR method walk
        // so user-declared override-method bodies still take
        // precedence (we check find_method first).
        if let klio_runtime::Value::Instance(inst) = receiver {
            let is_data = inst.borrow().class.is_data;
            // A `value class` gets the same compiler-synthesised
            // `equals`/`hashCode`/`toString` over its single backing
            // property as a data class (but no `copy`).
            let is_value = inst.borrow().class.is_value;
            let has_user_override = {
                let start_name = inst.borrow().class.name.clone();
                let mut queue: std::collections::VecDeque<String> =
                    std::collections::VecDeque::new();
                let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
                queue.push_back(start_name);
                let mut found = false;
                while let Some(cur) = queue.pop_front() {
                    if !seen.insert(cur.clone()) {
                        continue;
                    }
                    if let Some(ir_class) = self.module.classes.iter().find(|c| c.name == cur) {
                        for fid in &ir_class.methods {
                            if let Some(f) = self.module.funcs.get(fid.0 as usize)
                                && f.name == name
                            {
                                found = true;
                                break;
                            }
                        }
                    }
                    if found {
                        break;
                    }
                    if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                        for sup in &def.supertype_names {
                            queue.push_back(sup.clone());
                        }
                    }
                }
                found
            };
            let is_object = inst.borrow().class.is_object;
            if is_data && is_object && !has_user_override && name == "toString" {
                // `data object` renders as the bare class name even
                // though `is_data` is set. Short-circuit before the
                // structural data-class shape below.
                let i = inst.borrow();
                return Ok(klio_runtime::Value::String(Arc::new(i.class.name.clone())));
            }
            if (is_data || is_value) && !has_user_override && args.is_empty() {
                if is_data
                    && let Some(rest) = name.strip_prefix("component")
                    && let Ok(n) = rest.parse::<usize>()
                    && n >= 1
                {
                    let i = inst.borrow();
                    if let Some(p) = i.class.primary_params.get(n - 1)
                        && let Some(v) = i.get(&p.name)
                    {
                        return Ok(v);
                    }
                }
                if name == "toString" {
                    let i = inst.borrow();
                    let mut s = String::new();
                    s.push_str(&i.class.name);
                    s.push('(');
                    for (idx, p) in i.class.primary_params.iter().enumerate() {
                        if idx > 0 {
                            s.push_str(", ");
                        }
                        s.push_str(&p.name);
                        s.push('=');
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        s.push_str(&v.to_string());
                    }
                    s.push(')');
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                if name == "hashCode" {
                    let i = inst.borrow();
                    let mut h: i32 = 0;
                    for p in &i.class.primary_params {
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        h = h.wrapping_mul(31).wrapping_add(value_structural_hash(&v));
                    }
                    return Ok(klio_runtime::Value::new_int(i64::from(h)));
                }
            }
            if is_data && !has_user_override && name == "copy" {
                let class_def = inst.borrow().class.clone();
                let n_params = class_def.primary_params.len();
                if args.len() <= n_params {
                    let mut new_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
                    let i = inst.borrow();
                    for (idx, p) in class_def.primary_params.iter().enumerate() {
                        let v = if idx < args.len() {
                            args[idx].clone()
                        } else {
                            i.get(&p.name).unwrap_or(klio_runtime::Value::Null)
                        };
                        new_args.push(v);
                    }
                    drop(i);
                    if let Some(class_id) = self.module.class_id(&class_def.name) {
                        return <VmHost as klio_ir::eval::Host>::new_instance(
                            self, class_id, &new_args,
                        );
                    }
                }
            }
            if (is_data || is_value) && !has_user_override && args.len() == 1 && name == "equals" {
                let i = inst.borrow();
                let class_fqn = i.class.fqn.clone();
                let same = matches!(&args[0],
                    klio_runtime::Value::Instance(o) if o.borrow().class.fqn == class_fqn);
                if !same {
                    return Ok(klio_runtime::Value::Bool(false));
                }
                let klio_runtime::Value::Instance(o) = &args[0] else {
                    unreachable!()
                };
                let names: Vec<String> = i
                    .class
                    .primary_params
                    .iter()
                    .map(|p| p.name.clone())
                    .collect();
                drop(i);
                let lhs = inst.borrow();
                let rhs = o.borrow();
                for n in &names {
                    let a = lhs.get(n).unwrap_or(klio_runtime::Value::Null);
                    let b = rhs.get(n).unwrap_or(klio_runtime::Value::Null);
                    if !klio_runtime::Value::structural_eq(&a, &b) {
                        return Ok(klio_runtime::Value::Bool(false));
                    }
                }
                return Ok(klio_runtime::Value::Bool(true));
            }
        }
        // Runtime-lowered method dispatch: anonymous-object instances
        // (class name prefixed `$anon$`) and local classes registered
        // via Inst::RegisterClass both stash methods in anon_methods.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let class_name = inst.borrow().class.name.clone();
            // Anon-object / local-class methods are stored under both
            // an arity-tagged key (`name#argc`) and the plain name.
            // Prefer the arity match so overloaded members (e.g.
            // SegmentWriteContext.setUnchecked with 3/4/5/6 args)
            // dispatch correctly; fall back to the plain name.
            let arity_name = format!("{name}#{}", args.len());
            let key = (class_name, name.to_string());
            // Enum entries tagged with __enum_entry_class__ route
            // method calls to the entry-specific override class
            // first, before falling back to the enum class's own
            // members.
            let entry_tag = inst.borrow().get("__enum_entry_class__");
            if let Some(klio_runtime::Value::String(tag)) = entry_tag {
                let entry_arity_key = ((*tag).clone(), arity_name.clone());
                let entry_key = ((*tag).clone(), name.to_string());
                let entry_method = {
                    let tbl = self.anon_methods.borrow();
                    tbl.get(&entry_arity_key)
                        .or_else(|| tbl.get(&entry_key))
                        .cloned()
                };
                if let Some((module_rc, fid, _)) = entry_method {
                    let func = module_rc
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .ok_or_else(|| {
                            klio_ir::eval::EvalError::Type(format!(
                                "enum-entry method FuncId {} out of range",
                                fid.0
                            ))
                        })?;
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all.push(receiver.clone());
                    all.extend_from_slice(args);
                    let all = pack_vararg_args(&func, all);
                    return klio_ir::eval::eval_with(&module_rc, &func, all, self);
                }
            }
            let entry = {
                let tbl = self.anon_methods.borrow();
                let arity_key = (key.0.clone(), arity_name.clone());
                tbl.get(&arity_key).or_else(|| tbl.get(&key)).cloned()
            };
            if let Some((module_rc, fid, captures)) = entry {
                let func = module_rc
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "anon method FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                let all = pack_vararg_args(&func, all);
                // Layer captured outer-env names onto globals for the
                // duration of the method call so the body's
                // bare-name globals resolve to the captured values.
                let prev = self.globals.clone();
                if !captures.is_empty() {
                    let scoped =
                        klio_runtime::ObjRef::new(klio_runtime::Env::with_parent(prev.clone()));
                    for (n, v) in &captures {
                        scoped.borrow_mut().define(n.clone(), v.clone());
                    }
                    self.globals = scoped;
                }
                // Lexical capture vector aligned to the method's
                // `LoadCapture` index order. Each name resolves to the
                // value snapshotted at object construction (the
                // receiver for `this`); a captured closure then carries
                // its own captures positionally and cannot collapse
                // onto a same-named capture of an enclosing anon
                // method through ambient globals.
                let cap_vec: Vec<klio_runtime::Value> = func
                    .capture_order
                    .iter()
                    .map(|n| {
                        if n == "this" {
                            return receiver.clone();
                        }
                        captures
                            .iter()
                            .find(|(cn, _)| cn == n)
                            .map_or(klio_runtime::Value::Null, |(_, v)| v.clone())
                    })
                    .collect();
                let result =
                    klio_ir::eval::eval_with_captures(&module_rc, &func, all, cap_vec, self);
                self.globals = prev;
                return result;
            }
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            // Walk the IR class + its supertypes breadth-first
            // looking for a method matching `name`. The receiver's
            // runtime ClassDef.supertype_names provides the chain;
            // each name maps back to a klio_ir::Class via the
            // module's class_index.
            let class_name = inst.borrow().class.name.clone();
            // Resolve the receiver's own class by its fully-qualified
            // name: two packages may declare the same simple name,
            // and a bare-name lookup would bind the first IR class
            // and lose this class's members. Supertype levels keep
            // the simple-name walk (their names are recorded simple).
            let recv_fqn = inst.borrow().class.fqn.clone();
            let mut first = true;
            let mut queue: std::collections::VecDeque<String> = std::collections::VecDeque::new();
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            queue.push_back(class_name);
            while let Some(cur_name) = queue.pop_front() {
                if !seen.insert(cur_name.clone()) {
                    continue;
                }
                let by_fqn = if first {
                    self.module
                        .class_id_by_fqn(&recv_fqn)
                        .and_then(|cid| self.module.classes.get(cid.0 as usize))
                        .cloned()
                } else {
                    None
                };
                first = false;
                let ir_class = by_fqn.or_else(|| {
                    self.module
                        .classes
                        .iter()
                        .find(|c| c.name == cur_name)
                        .cloned()
                });
                if let Some(ir_class) = ir_class {
                    // Gather every method named `name` so we can pick
                    // an overload by scoring runtime arg types.
                    let candidates: Vec<klio_ir::Func> = ir_class
                        .methods
                        .iter()
                        .filter_map(|fid| self.module.funcs.get(fid.0 as usize).cloned())
                        .filter(|f| f.name == name)
                        .collect();
                    if let Some(f) = self.pick_method_overload(&candidates, args) {
                        // Under a member-only probe, a member that
                        // only matches by SAM-converting a lambda
                        // argument to a `fun interface` parameter is
                        // NOT the resolution Kotlin wants — a
                        // same-named extension whose parameter is the
                        // exact function type is more specific
                        // (`flow.collect { … }` binds
                        // `Flow<T>.collect(action)`, not the
                        // `collect(collector: FlowCollector)` member).
                        // Decline so the probe continues / the
                        // extension fallback resolves it; otherwise
                        // the raw lambda is passed where a
                        // FlowCollector is expected and emissions are
                        // silently dropped.
                        if member_only {
                            let skip =
                                usize::from(f.params.first().is_some_and(|p| p.name == "this"));
                            let sam_lambda =
                                f.params[skip..].iter().zip(args.iter()).any(|(p, a)| {
                                    let callable = matches!(
                                        a,
                                        klio_runtime::Value::Lambda { .. }
                                            | klio_runtime::Value::IrClosure { .. }
                                            | klio_runtime::Value::Function { .. }
                                            | klio_runtime::Value::BoundMethod { .. }
                                    );
                                    let pn = p.ty.name.as_str();
                                    let fn_ty = pn.starts_with("Function")
                                        || (pn.len() <= 2
                                            && pn.chars().all(|c| c.is_ascii_uppercase()));
                                    // A lambda can only bind a
                                    // non-function-typed parameter via
                                    // SAM conversion; an exact
                                    // function-typed extension is more
                                    // specific. (klio's
                                    // `is_fun_interface` is unreliable
                                    // for pack interfaces, so don't
                                    // gate on it.)
                                    callable && !fn_ty
                                });
                            if sam_lambda {
                                return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                                    "Vm::call_member `{name}` \
                                             (member-only: SAM-lambda \
                                             member deferred to extension)"
                                )));
                            }
                        }
                        let mut all_args: Vec<klio_runtime::Value> =
                            Vec::with_capacity(args.len() + 1);
                        all_args.push(receiver.clone());
                        all_args.extend_from_slice(args);
                        // Fill omitted trailing params from the
                        // method's recorded default-arg thunks, then
                        // collect a trailing `vararg`. The implicit
                        // `this` is already in `all_args`, so
                        // positions align with the lowered param list.
                        let module = Arc::clone(&self.module);
                        let defaults = self.prog.func_defaults.get(&f.id).cloned();
                        let all_args = if defaults.is_some() && all_args.len() < f.params.len() {
                            pad_args_with_defaults(
                                &module,
                                f.params.len(),
                                &all_args,
                                defaults.as_ref(),
                                self,
                            )?
                        } else {
                            all_args
                        };
                        let all_args = pack_vararg_args(&f, all_args);
                        return klio_ir::eval::eval_with(&module, &f, all_args, self);
                    }
                }
                // Push runtime supertype names; the Vm's
                // class_table maps each name back to a ClassDef
                // whose supertype_names continues the walk.
                if let Some(def) = self.classes.borrow().get(&cur_name).cloned() {
                    for sup in &def.supertype_names {
                        queue.push_back(sup.clone());
                    }
                }
            }
        }
        // Generic Any.toString / equals / hashCode fallback —
        // structural where appropriate, reference-based for opaque
        // values. Runs after the user-method walk so override
        // bodies still win.
        if let klio_runtime::Value::Instance(inst) = receiver {
            if args.is_empty() && name == "toString" {
                let i = inst.borrow();
                // Enum entries render as the bare entry name unless
                // the user override fired (the user-method walk
                // above runs first and wins).
                if i.class.is_enum
                    && let Some(klio_runtime::Value::String(s)) = i.get("name")
                {
                    return Ok(klio_runtime::Value::String(Arc::clone(&s)));
                }
                // Singleton `object` decls — including `data
                // object` — render as the bare class name.
                if i.class.is_object {
                    return Ok(klio_runtime::Value::String(Arc::new(i.class.name.clone())));
                }
                // Data classes render structurally `Name(p1=v1, …)`.
                if i.class.is_data {
                    let mut s = String::new();
                    s.push_str(&i.class.name);
                    s.push('(');
                    for (idx, p) in i.class.primary_params.iter().enumerate() {
                        if idx > 0 {
                            s.push_str(", ");
                        }
                        s.push_str(&p.name);
                        s.push('=');
                        let v = i.get(&p.name).unwrap_or(klio_runtime::Value::Null);
                        s.push_str(&v.to_string());
                    }
                    s.push(')');
                    return Ok(klio_runtime::Value::String(Arc::new(s)));
                }
                return Ok(klio_runtime::Value::String(Arc::new(format!(
                    "{}@{:x}",
                    i.class.fqn, i.identity
                ))));
            }
            if args.is_empty() && name == "hashCode" {
                let i = inst.borrow();
                return Ok(klio_runtime::Value::new_int(i.identity as i64));
            }
            if args.len() == 1 && name == "equals" {
                if let klio_runtime::Value::Instance(o) = &args[0] {
                    let same = klio_runtime::ObjRef::ptr_eq(inst, o);
                    return Ok(klio_runtime::Value::Bool(same));
                }
                return Ok(klio_runtime::Value::Bool(false));
            }
        }
        // `kotlin.Unit` is the singleton `object Unit`; its `Any`
        // methods must be well-defined so any code path comparing a
        // state slot or container value to Unit with `==` resolves
        // through `Unit.equals(x)` rather than failing to dispatch.
        if matches!(receiver, klio_runtime::Value::Unit) {
            match (name, args.len()) {
                ("equals", 1) => {
                    return Ok(klio_runtime::Value::Bool(matches!(
                        args[0],
                        klio_runtime::Value::Unit
                    )));
                }
                ("hashCode", 0) => {
                    return Ok(klio_runtime::Value::new_int(0));
                }
                ("toString", 0) => {
                    return Ok(klio_runtime::Value::String(Arc::new(
                        "kotlin.Unit".to_string(),
                    )));
                }
                _ => {}
            }
        }
        // `hashCode()` on a builtin value type (number, Char, Boolean, String,
        // collection, range). These have no user override and no `<type>.
        // hashCode` intrinsic, so without an explicit handler the call fell
        // through to a fallback that recursed and exhausted memory. Compute
        // the Kotlin-faithful hash directly. Instances keep their own
        // identity/override path below.
        if args.is_empty()
            && name == "hashCode"
            && !matches!(
                receiver,
                klio_runtime::Value::Instance(_)
                    | klio_runtime::Value::Class(_)
                    | klio_runtime::Value::PropertyRef { .. }
            )
        {
            return Ok(klio_runtime::Value::new_int(i64::from(kotlin_hash_code(
                receiver,
            ))));
        }
        // Stdlib member dispatch: probe the receiver's type FQN
        // for a `<typeFqn>.<name>` intrinsic, then for the common
        // package-extension fallbacks. For 0-arg call shapes the
        // type-prefixed form (property read) wins; for n-arg call
        // shapes the package-prefixed form (extension fn) wins so
        // `1..10 step 2` resolves to `kotlin.ranges.step(...)`
        // rather than the property `IntRange.step`.
        let type_fqn = receiver.type_fqn();
        let probes: Vec<String> = if args.is_empty() {
            vec![
                format!("{type_fqn}.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.text.{name}"),
                format!("kotlin.ranges.{name}"),
                format!("kotlin.{name}"),
            ]
        } else {
            vec![
                format!("kotlin.ranges.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.text.{name}"),
                format!("{type_fqn}.{name}"),
                format!("kotlin.{name}"),
            ]
        };
        // A pack-defined exception class (`CompletionHandlerException`,
        // `JobCancellationException`, …) is a `Value::Instance` whose
        // `type_fqn()` is its own class, so the `kotlin.Throwable.*`
        // intrinsics (`message`, `cause`, `addSuppressed`,
        // `suppressedExceptions`, …) are never probed. When the
        // receiver's supertype chain reaches the Throwable family,
        // probe `kotlin.Throwable.<name>` too so those resolve.
        let mut probes = probes;
        // A MutableList/Set/Map IS-A List/Set/Map, so an op registered only on
        // the read-only type (e.g. Set.sorted / Set.toTypedArray) must also be
        // reachable from a mutable receiver — otherwise it falls through to a
        // fragile upstream body. The reverse also holds: read-only/mutable are
        // erased on the JVM, and a genuinely-mutable value (e.g. `MutableMap.keys`,
        // which is a `MutableSet`) can carry a read-only runtime tag, so the
        // mutator intrinsics (`remove`/`add`/`clear`) must stay reachable from a
        // read-only receiver too — otherwise dispatch falls through to a
        // decl-only upstream shim that self-recurses. Probe the sibling type's
        // intrinsic right after this type's own.
        if let Some(sibling_fqn) = match type_fqn {
            "kotlin.collections.MutableList" => Some("kotlin.collections.List"),
            "kotlin.collections.MutableSet" => Some("kotlin.collections.Set"),
            "kotlin.collections.MutableMap" => Some("kotlin.collections.Map"),
            "kotlin.collections.List" => Some("kotlin.collections.MutableList"),
            "kotlin.collections.Set" => Some("kotlin.collections.MutableSet"),
            "kotlin.collections.Map" => Some("kotlin.collections.MutableMap"),
            _ => None,
        } {
            let probe = format!("{sibling_fqn}.{name}");
            let anchor = format!("{type_fqn}.{name}");
            match probes.iter().position(|p| p == &anchor) {
                Some(pos) => probes.insert(pos + 1, probe),
                None => probes.push(probe),
            }
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            let is_throwable = {
                let classes = self.classes.borrow();
                let mut stack = vec![inst.borrow().class.name.clone()];
                let mut seen = std::collections::HashSet::new();
                let mut found = false;
                while let Some(cn) = stack.pop() {
                    if !seen.insert(cn.clone()) {
                        continue;
                    }
                    if matches!(
                        cn.as_str(),
                        "Throwable"
                            | "Exception"
                            | "RuntimeException"
                            | "Error"
                            | "CancellationException"
                    ) {
                        found = true;
                        break;
                    }
                    if let Some(d) = classes.get(&cn) {
                        stack.extend(d.supertype_names.iter().cloned());
                    }
                }
                found
            };
            if is_throwable {
                probes.push(format!("kotlin.Throwable.{name}"));
            }
        }
        // A top-level stdlib function (`listOf`, `mutableListOf`,
        // `minOf`, `println`, …) is never a member or extension of an
        // arbitrary receiver. Skip the speculative receiver-prepend
        // probe for these so a bare call inside a receiver-typed
        // lambda (e.g. `runBlocking { listOf(1, 2) }`) resolves to
        // the top-level function instead of `receiver.listOf(...)`.
        // A real member declared anywhere in the receiver's class
        // hierarchy (including interface supertypes) outranks a
        // same-named stdlib builtin op. Without this a user/pack
        // `operator fun get` (e.g. `CoroutineContext.get`, a custom
        // container) mis-routes to the collection `Map.get`/`List.get`
        // when called bare on an extension receiver. Stdlib
        // *extensions* are not class members, so `host_has_member`
        // stays false for them and the probe still fires.
        let member_shadows_stdlib = matches!(receiver, klio_runtime::Value::Instance(_))
            && self.host_has_member(receiver, name);
        // A visible member-extension on the receiver type declared in
        // the enclosing-class chain outranks the stdlib type-name
        // probe — without this, `operator fun Int.unaryPlus()` in a
        // class would lose to `kotlin.Int.unaryPlus` when invoked
        // bare inside the class's body. Cheap scan over the registry
        // of member-extension owners for one whose owner is in scope.
        let user_member_ext_shadows = {
            let chain = self.enclosing_this_chain();
            let mut owners: std::collections::HashSet<String> = std::collections::HashSet::new();
            for v in &chain {
                let mut cur: Option<klio_runtime::Value> = Some(v.clone());
                while let Some(cv) = cur {
                    if let klio_runtime::Value::Instance(inst) = &cv {
                        let b = inst.borrow();
                        owners.insert(b.class.name.clone());
                        owners.insert(b.class.fqn.clone());
                        let mut p = b.class.parent.borrow().clone();
                        while let Some(pp) = p {
                            owners.insert(pp.name.clone());
                            owners.insert(pp.fqn.clone());
                            let parent = pp.parent.borrow().clone();
                            p = parent;
                        }
                        let outer = b.outer.clone();
                        cur = outer;
                    } else {
                        break;
                    }
                }
            }
            let want = args.len() + 1;
            let mut found = false;
            for fid in self.module.funcs_by_simple_name(name) {
                let owner_ok = self
                    .module
                    .registry
                    .member_ext_owner_class
                    .get(fid)
                    .is_some_and(|o| owners.contains(o));
                if !owner_ok {
                    continue;
                }
                if let Some(f) = self.module.funcs.get(fid.0 as usize)
                    && !f.params.is_empty()
                    && f.params.len() >= want
                {
                    found = true;
                    break;
                }
            }
            found
        };
        if !member_shadows_stdlib
            && !user_member_ext_shadows
            && !klio_stdlib::is_toplevel_function(name)
        {
            for probe in &probes {
                if let Some(func) = self.lookup_intrinsic(probe) {
                    let mut all_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all_args.push(receiver.clone());
                    all_args.extend_from_slice(args);
                    return self.dispatch_intrinsic(func, &all_args);
                }
            }
        }
        // `IntRange`/`LongRange`/`CharRange` is `Iterable`. By here
        // the range-specific intrinsics (`step`, `contains`,
        // `reversed`, `toList`, …) have had their probe; anything
        // left is a generic Iterable op, so materialise to a List
        // and re-dispatch *before* the user-extension fallback. This
        // makes a range take the exact same path as a List (so
        // `(0..3).map { }` resolves to the stdlib List.map and isn't
        // hijacked by an unrelated user `fun Tree<T>.map`).
        if let klio_runtime::Value::Range {
            start,
            end,
            step,
            kind,
        } = receiver
        {
            let items = materialise_range_items(*start, *end, *step, *kind);
            let as_list = klio_runtime::Value::List {
                items: klio_runtime::ObjRef::new(items),
                mutable: false,
                enum_class: None,
                backing: None,
            };
            return self.call_member(&as_list, name, args);
        }
        // Class-delegation pre-pass: an instance constructed with
        // `: I by g` stores its delegate under `__delegate__<I>`.
        // Try forwarding the call there BEFORE the extension-fn
        // fallback below — without this order, a same-simple-name
        // shipped extension (e.g. `Iterable<T>.all`) hijacks
        // `loggedRepo.all()` and runs against the wrong shape.
        // Only swallow `Unimplemented` here (klio's "no such
        // member" sentinel); a real error from the delegate's body
        // must propagate to the caller, not silently fall through
        // and let the extension fallback re-dispatch.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let delegates: Vec<klio_runtime::Value> = inst
                .borrow()
                .fields
                .iter()
                .filter_map(|(n, v)| {
                    if n.starts_with("__delegate__") {
                        Some(v.clone())
                    } else {
                        None
                    }
                })
                .collect();
            for d in delegates {
                match self.call_member(&d, name, args) {
                    Ok(v) => return Ok(v),
                    Err(klio_ir::eval::EvalError::Unimplemented(_)) => {}
                    Err(e) => return Err(e),
                }
            }
        }
        // Extension fn fallback: a user-defined `fun T.name(...)`
        // lowers as a top-level fn whose first param is the
        // receiver. Look it up by simple name and dispatch with
        // receiver prepended.
        {
            // Gather every top-level fn named `name` with the right
            // arity for an extension call (receiver + args). Pick the
            // candidate whose first (receiver) parameter type best
            // matches the actual receiver, so `bytes.encodeBase64()`
            // and `byteString.encodeBase64()` resolve to their own
            // overloads rather than the first-declared one.
            let want = args.len() + 1;
            // Accept an extension whose declared arity is >= the
            // supplied (receiver + args) count when every trailing
            // unsupplied parameter has a default.
            // Member-extension visibility filter: a `class C { fun
            // R.f(...) { … } }` is registered in `func_index` for
            // dispatch but its visibility is restricted to call
            // sites whose enclosing-class chain includes `C`. Build
            // the set of class names reachable through the current
            // call's enclosing-`this` chain so the candidate filter
            // can drop member-extensions whose owner isn't visible.
            let visible_owners: std::collections::HashSet<String> = {
                let chain = self.enclosing_this_chain();
                let mut set: std::collections::HashSet<String> = std::collections::HashSet::new();
                let add_class_and_supers =
                    |cls: &Arc<klio_runtime::ClassDef>,
                     set: &mut std::collections::HashSet<String>| {
                        set.insert(cls.name.clone());
                        if !cls.fqn.is_empty() && cls.fqn != cls.name {
                            set.insert(cls.fqn.clone());
                        }
                        let mut cur = cls.parent.borrow().clone();
                        while let Some(p) = cur {
                            set.insert(p.name.clone());
                            if !p.fqn.is_empty() && p.fqn != p.name {
                                set.insert(p.fqn.clone());
                            }
                            let parent = p.parent.borrow().clone();
                            cur = parent;
                        }
                    };
                for v in &chain {
                    let mut cursor: Option<klio_runtime::Value> = Some(v.clone());
                    while let Some(cv) = cursor {
                        if let klio_runtime::Value::Instance(inst) = &cv {
                            let b = inst.borrow();
                            add_class_and_supers(&b.class, &mut set);
                            let outer = b.outer.clone();
                            cursor = outer;
                        } else {
                            break;
                        }
                    }
                }
                set
            };
            let candidates: Vec<(klio_ir::FuncId, klio_ir::Func)> = self
                .module
                .funcs_by_simple_name(name)
                .iter()
                .filter_map(|fid| {
                    self.module
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .map(|f| (*fid, f))
                })
                // Only genuine extension / member-extension fns
                // participate in `recv.name(args)` dispatch: their
                // lowered first param is the synthetic receiver `this`.
                // A plain top-level `fun name(a, b)` (first param not
                // `this`) is NOT an extension and must never be a
                // member-call candidate — otherwise a user `fun
                // apply(f, x)` would shadow the stdlib `T.apply` and
                // bind the receiver to its first value param.
                .filter(|(_fid, f)| {
                    f.params.len() >= want && f.params.first().is_some_and(|p| p.name == "this")
                })
                .filter(|(fid, _)| {
                    match self.module.registry.member_ext_owner_class.get(fid) {
                        None => true, // top-level extension: always visible
                        Some(owner) => visible_owners.contains(owner),
                    }
                })
                .collect();
            // Receiver-type filter (call_member fallback): when at
            // least one candidate's declared receiver type accepts
            // the actual receiver, keep only those.
            let any_compat = candidates
                .iter()
                .any(|(_, f)| receiver_compatible_with_param(receiver, &f.params[0].ty));
            let candidates: Vec<(klio_ir::FuncId, klio_ir::Func)> = if any_compat {
                candidates
                    .into_iter()
                    .filter(|(_, f)| receiver_compatible_with_param(receiver, &f.params[0].ty))
                    .collect()
            } else {
                candidates
            };
            let unique_exact: Option<(klio_ir::FuncId, klio_ir::Func)> = {
                // Kotlin disambiguates same-named extensions by
                // applicable arity first. When exactly one candidate's
                // declared arity equals the supplied (receiver + args)
                // count it is the unique applicable overload — pick it
                // before type-scoring, which otherwise mis-ranks a
                // `suspend ()->T` receiver (its lowered arity includes
                // the continuation) as `Function1` and selects the
                // wrong receiver-form `startCoroutine` /
                // `createCoroutineUnintercepted`.
                let mut it = candidates.iter().filter(|(_, f)| f.params.len() == want);
                match (it.next(), it.next()) {
                    (Some(only), None) => Some(only.clone()),
                    _ => None,
                }
            };
            let chosen = if candidates.len() <= 1 {
                // Single candidate: still verify the receiver type is
                // compatible. Without this guard, a same-simple-name
                // extension declared on an unrelated receiver (e.g.
                // the shipped `Iterable<T>.all` shim picked for a
                // `Logged` instance that delegates `Repository` via
                // `by`) wins by default and its body runs against the
                // wrong shape — usually surfacing as an `iterator()`
                // lookup failure when the body tries to iterate the
                // receiver.
                candidates.into_iter().next()
            } else if unique_exact.is_some() {
                unique_exact
            } else {
                // Score the receiver (param 0) *and* every value
                // argument against the declared parameter types, so
                // overloads that differ only in an argument type are
                // resolved correctly (`Byte.and(Int)` vs
                // `Byte.and(Long)` for `byte and 0xffL`). An exact
                // declared arity is also preferred over a
                // defaulted-tail match.
                // Candidate receiver-type names, for Kotlin's
                // "most-specific receiver" tie-break: when scores tie,
                // prefer the candidate whose receiver type is a
                // (transitive) subtype of the most *other* candidates'
                // receiver types. `Job` is a subtype of the candidate
                // `CoroutineContext`; the sibling `CoroutineScope` is
                // not — so `x.ensureActive()` binds `Job.ensureActive`
                // rather than the recursive `CoroutineContext` /
                // `CoroutineScope` variants.
                let recv_tys: Vec<String> = candidates
                    .iter()
                    .map(|(_, f)| f.params[0].ty.name.clone())
                    .collect();
                let is_subtype = |a: &str, b: &str| -> bool {
                    if a == b {
                        return false;
                    }
                    let mut q = vec![a.to_string()];
                    let mut seen = std::collections::HashSet::new();
                    while let Some(c) = q.pop() {
                        if !seen.insert(c.clone()) {
                            continue;
                        }
                        if c == b {
                            return true;
                        }
                        if let Some(d) = self.classes.borrow().get(&c).cloned() {
                            for s in &d.supertype_names {
                                q.push(s.clone());
                            }
                        }
                    }
                    false
                };
                // Member-extension override tie-break: when multiple
                // candidates name the same member-ext (a subclass
                // overrides a base's `fun R.f`), prefer the candidate
                // whose owner class is closest to the *innermost*
                // enclosing-`this` instance — that's the runtime
                // subclass override. Top-level extensions (no owner)
                // get a neutral rank so they are picked only when
                // no member-extension candidate scores higher overall.
                let chain_class_order: Vec<String> = {
                    let chain = self.enclosing_this_chain();
                    let mut v: Vec<String> = Vec::new();
                    for value in &chain {
                        let mut cursor: Option<klio_runtime::Value> = Some(value.clone());
                        while let Some(cv) = cursor {
                            if let klio_runtime::Value::Instance(inst) = &cv {
                                let b = inst.borrow();
                                v.push(b.class.name.clone());
                                let mut cur = b.class.parent.borrow().clone();
                                while let Some(p) = cur {
                                    v.push(p.name.clone());
                                    let parent = p.parent.borrow().clone();
                                    cur = parent;
                                }
                                let outer = b.outer.clone();
                                cursor = outer;
                            } else {
                                break;
                            }
                        }
                    }
                    v
                };
                let owner_rank_for = |fid: klio_ir::FuncId| -> i32 {
                    if let Some(owner) = self.module.registry.member_ext_owner_class.get(&fid) {
                        if let Some(pos) = chain_class_order.iter().position(|c| c == owner) {
                            // Closer to the innermost `this` = higher rank.
                            return (chain_class_order.len() as i32) - (pos as i32);
                        }
                        return 0;
                    }
                    0
                };
                let mut best: Option<ScoredCandidate> = None;
                for (idx, (fid, f)) in candidates.into_iter().enumerate() {
                    // Drop candidates whose declared receiver type
                    // can't accommodate this call's actual receiver.
                    // Without this filter, a same-simple-name extension
                    // declared on an unrelated receiver (e.g. the
                    // shipped `Iterable<T>.all` shim picked for a
                    // `Logged` instance that delegates `Repository`
                    // via `by`) wins by default and its body runs
                    // against the wrong shape — usually surfacing as
                    // an `iterator()` lookup failure when the body
                    // tries to iterate the receiver.
                    let recv_score = self
                        .overload_score_arg(&f.params[0].ty, receiver)
                        .unwrap_or(-1);
                    let mut score = recv_score;
                    for (i, a) in args.iter().enumerate() {
                        if let Some(p) = f.params.get(i + 1) {
                            score += self.overload_score_arg(&p.ty, a).unwrap_or(-1);
                        }
                    }
                    if f.params.len() == want {
                        score += 5;
                    }
                    let spec = recv_tys
                        .iter()
                        .enumerate()
                        .filter(|(j, t)| *j != idx && is_subtype(&recv_tys[idx], t))
                        .count() as i32;
                    let owner_rank = owner_rank_for(fid);
                    let key = (score, owner_rank, spec);
                    if best.as_ref().is_none_or(|(_, k)| key > *k) {
                        best = Some(((fid, f), key));
                    }
                }
                best.map(|(c, _)| c)
            };
            if chosen.is_some() && member_only {
                // Member-only probe: the receiver-member walk did not
                // resolve `name`; a top-level extension is not a
                // member, so report not-found so the caller continues
                // its implicit-receiver search.
                return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                    "Vm::call_member `{name}` (member-only probe)"
                )));
            }
            if let Some((fid, _func)) = chosen {
                // Runaway-recursion guard, scoped to the top-level
                // extension dispatch only. Re-entering this block for
                // the same (name, receiver-instance) is legitimate at
                // bounded depth (e.g. a coroutine `dispatchResume`
                // chain), but *unbounded* same-key re-entry is the
                // pathological extension self-rebind: a generic
                // extension whose body calls itself on the same
                // receiver re-enters forever. Allow a generous depth,
                // then decline so CallMemberOrGlobal continues to the
                // lexically enclosing receiver. Legitimate recursive
                // *member* methods dispatch through the IR method
                // walk above, not here.
                const MAX_SAME_KEY_DEPTH: u32 = 48;
                struct ExtGuard(Option<(String, u64)>);
                impl Drop for ExtGuard {
                    fn drop(&mut self) {
                        if let Some(k) = self.0.take() {
                            EXT_CHOSEN_DEPTH.with(|s| {
                                let mut m = s.borrow_mut();
                                if let Some(d) = m.get_mut(&k) {
                                    *d -= 1;
                                    if *d == 0 {
                                        m.remove(&k);
                                    }
                                }
                            });
                        }
                    }
                }
                thread_local! {
                    static EXT_CHOSEN_DEPTH: std::cell::RefCell<
                        std::collections::HashMap<(String, u64), u32>,
                    > = std::cell::RefCell::new(
                        std::collections::HashMap::new(),
                    );
                }
                let guard = if let klio_runtime::Value::Instance(inst) = receiver {
                    let key = (name.to_string(), inst.borrow().identity);
                    let depth = EXT_CHOSEN_DEPTH.with(|s| {
                        let mut m = s.borrow_mut();
                        let d = m.entry(key.clone()).or_insert(0);
                        *d += 1;
                        *d
                    });
                    if depth > MAX_SAME_KEY_DEPTH {
                        // Unbounded self-rebind: undo and decline.
                        EXT_CHOSEN_DEPTH.with(|s| {
                            let mut m = s.borrow_mut();
                            if let Some(d) = m.get_mut(&key) {
                                *d -= 1;
                                if *d == 0 {
                                    m.remove(&key);
                                }
                            }
                        });
                        None
                    } else {
                        Some(ExtGuard(Some(key)))
                    }
                } else {
                    Some(ExtGuard(None))
                };
                if let Some(_g) = guard {
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all.push(receiver.clone());
                    all.extend_from_slice(args);
                    // call_func pads defaulted params, packs varargs
                    // and honours a pack-installed binding that
                    // shadows a bodyless `expect` extension.
                    let module = Arc::clone(&self.module);
                    return self.call_func(&module, fid, all);
                }
            }
        }
        // Class-delegation forwarding: when the receiver instance
        // was constructed with `: I by g`, the stored
        // `__delegate__<I>` field holds the delegate; forward
        // unmatched method calls there.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let delegates: Vec<klio_runtime::Value> = inst
                .borrow()
                .fields
                .iter()
                .filter_map(|(n, v)| {
                    if n.starts_with("__delegate__") {
                        Some(v.clone())
                    } else {
                        None
                    }
                })
                .collect();
            for d in delegates {
                if let Ok(v) = self.call_member(&d, name, args) {
                    return Ok(v);
                }
            }
        }
        // Companion-method forwarding: `Foo.bar(...)` where the
        // receiver is the class itself dispatches to `bar` declared
        // in `Foo`'s companion object. Mirrors the companion-field
        // forwarding in `get_field`; needed when a top-level
        // function shares the class's name so the qualifier resolves
        // to the class value rather than the companion.
        if let klio_runtime::Value::Class(cls) = receiver {
            let simple = cls.name.rsplit('.').next().unwrap_or(&cls.name).to_string();
            let comp_name = self
                .module
                .registry
                .companion_singletons
                .get(&cls.name)
                .or_else(|| self.module.registry.companion_singletons.get(&simple))
                .cloned();
            if let Some(comp_name) = comp_name {
                let singleton = self.globals.borrow().lookup(&comp_name);
                if let Some(singleton @ klio_runtime::Value::Instance(_)) = singleton
                    && let Ok(v) = self.call_member(&singleton, name, args)
                {
                    return Ok(v);
                }
            }
        }
        // Reflective `KSerializer` synthesis (the kotlinx-serialization
        // compiler-plugin replacement). `T.serializer()` /
        // `Companion.serializer()` on a `@Serializable` class with no
        // hand-written or `with=` serializer reaches here only after
        // every real dispatch (including a user-declared companion
        // `serializer()`) has missed. When the kotlinx-serialization
        // pack is loaded it registers a top-level
        // `ReflectiveKSerializer` class; build one over the target
        // class so the program gets a working serializer by
        // reflecting the primary-constructor properties.
        if name == "serializer"
            && args.is_empty()
            && matches!(
                receiver,
                klio_runtime::Value::Class(_) | klio_runtime::Value::BoundInnerClass { .. }
            )
        {
            let factory = self.classes.borrow().get("ReflectiveKSerializer").cloned();
            if let Some(def) = factory
                && let Some(class_id) = self.module.class_id(&def.name)
            {
                let ctor_args = [receiver.clone()];
                return <VmHost as klio_ir::eval::Host>::new_instance(self, class_id, &ctor_args);
            }
        }
        // Companion fallback for an instance receiver: inside a
        // class's own member body, a companion function/property is
        // in scope unqualified (`fun plus(d) = of(x + d)` where
        // `of` is on the companion). The bare call lowered as
        // `this.of(...)`; the instance has no such member, so route
        // to the class's companion singleton before failing.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let mut cur = Some(inst.borrow().class.name.clone());
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            while let Some(cname) = cur.take() {
                if !seen.insert(cname.clone()) {
                    break;
                }
                let comp_name = self
                    .module
                    .registry
                    .companion_singletons
                    .get(&cname)
                    .cloned();
                if let Some(comp_name) = comp_name {
                    let singleton = self.globals.borrow().lookup(&comp_name);
                    if let Some(singleton) = singleton
                        && matches!(singleton, klio_runtime::Value::Instance(_))
                        && let Ok(v) = self.call_member(&singleton, name, args)
                    {
                        return Ok(v);
                    }
                }
                let next = self
                    .classes
                    .borrow()
                    .get(&cname)
                    .and_then(|d| d.supertype_names.first().cloned());
                cur = next;
            }
        }
        // The COROUTINE_SUSPENDED singleton has a fixed member
        // surface: it stringifies to its own name and equality is
        // identity against the sole instance.
        if matches!(receiver, klio_runtime::Value::CoroutineSuspended) {
            match name {
                "toString" => {
                    return Ok(klio_runtime::Value::String(Arc::new(
                        "COROUTINE_SUSPENDED".to_string(),
                    )));
                }
                "hashCode" => return Ok(klio_runtime::Value::Int(0)),
                "equals" => {
                    return Ok(klio_runtime::Value::Bool(matches!(
                        args.first(),
                        Some(klio_runtime::Value::CoroutineSuspended)
                    )));
                }
                _ => {}
            }
        }
        // Function-typed property invoked by name: `body()` where
        // `body: () -> T` is a (constructor) property. No method
        // `body` exists, so read the callable field and invoke it.
        if let klio_runtime::Value::Instance(inst) = receiver {
            let field = inst
                .borrow()
                .fields
                .iter()
                .find(|(n, _)| n == name)
                .map(|(_, v)| v.clone());
            if let Some(v) = field
                && matches!(
                    v,
                    klio_runtime::Value::Lambda { .. }
                        | klio_runtime::Value::IrClosure { .. }
                        | klio_runtime::Value::Function { .. }
                        | klio_runtime::Value::BoundMethod { .. }
                        | klio_runtime::Value::Instance(_)
                )
            {
                return <Self as klio_ir::eval::Host>::call_value(self, &v, args);
            }
        }
        // `recv.member(...)` where `member` is not a member of the
        // receiver's type but is a function-typed property of the
        // lexically enclosing `this` — an extension-function-typed
        // member invoked with an explicit receiver. (Upstream
        // `SafeFlow.collectSafely(collector)` does `collector.block()`
        // where `block: suspend FlowCollector<T>.() -> Unit` is a
        // field of the enclosing `SafeFlow`.) Invoke the callable
        // with the receiver as its extension-receiver argument.
        if let Some(klio_runtime::Value::Instance(encl)) = self.enclosing_this() {
            let cand = encl
                .borrow()
                .fields
                .iter()
                .find(|(n, _)| n == name)
                .map(|(_, v)| v.clone());
            if let Some(v) = cand
                && matches!(
                    v,
                    klio_runtime::Value::Lambda { .. }
                        | klio_runtime::Value::IrClosure { .. }
                        | klio_runtime::Value::Function { .. }
                        | klio_runtime::Value::BoundMethod { .. }
                )
            {
                // Bind the explicit receiver as the callable's
                // implicit `this` so the body's bare member calls
                // (e.g. `emit(value)` inside a `flow { … }` block)
                // resolve against the receiver via its `this`
                // capture slot.
                use klio_runtime::IntrinsicHost as _;
                let mut sink = self.out_sink.clone();
                let r = {
                    let mut intrinsic = VmIntrinsicHost {
                        scheduler: &mut *self.scheduler,
                        module: Arc::clone(&self.module),
                        closures: self.closures.clone(),
                        globals: self.globals.clone(),
                        classes: self.classes.clone(),
                        prog: Arc::clone(&self.prog),
                        anon_methods: self.anon_methods.clone(),
                        class_default_outer: self.class_default_outer.clone(),
                        instance_id_counter: Arc::clone(&self.instance_id_counter),
                        out_sink: self.out_sink.clone(),
                        threads: Arc::clone(&self.threads),
                    };
                    intrinsic.invoke_callable_with_this(&v, args, receiver, &mut sink)
                };
                return r.map_err(|e| match e {
                    klio_runtime::RuntimeError::Thrown(tv) => klio_ir::eval::EvalError::Throw(tv),
                    klio_runtime::RuntimeError::Return(rv) => {
                        klio_ir::eval::EvalError::NonLocalReturn(rv)
                    }
                    klio_runtime::RuntimeError::Suspend(wake) => {
                        klio_ir::eval::EvalError::Suspended(Box::new(klio_ir::eval::SuspendState {
                            token: 0,
                            frames: Vec::new(),
                            wake_in_millis: wake,
                            pending_resume_reg: None,
                        }))
                    }
                    other => klio_ir::eval::EvalError::Type(format!("{other}")),
                });
            }
        }
        // Inner-class outer-chain fallback: a bare call inside an
        // `inner class` method may target an enclosing-class member,
        // reachable through the receiver's captured `outer` link
        // rather than the receiver-lambda `enclosing_this` stack.
        if let Some(hit) = with_call_outer_guard(|active| {
            if !active {
                return None;
            }
            let mut cur = match receiver {
                klio_runtime::Value::Instance(i) => i.borrow().outer.clone(),
                _ => None,
            };
            while let Some(o) = cur {
                if matches!(o, klio_runtime::Value::Null | klio_runtime::Value::Unit) {
                    break;
                }
                match self.call_member(&o, name, args) {
                    Ok(v) => return Some(Ok(v)),
                    // Only "method not found here" continues the walk;
                    // a real throw / suspension from the resolved
                    // enclosing method must propagate.
                    Err(klio_ir::eval::EvalError::Unimplemented(_)) => {}
                    Err(e) => return Some(Err(e)),
                }
                cur = match &o {
                    klio_runtime::Value::Instance(i) => i.borrow().outer.clone(),
                    _ => None,
                };
            }
            None
        }) {
            return hit;
        }
        // Iterable fallback: a user class that exposes an
        // `iterator()` method is iterable; an unbound member call
        // can resolve to the stdlib `Iterable.<name>` extension by
        // draining the iterator into a List and re-dispatching the
        // call there. A re-entry guard prevents loops when the
        // iterator returned is itself a user Instance whose members
        // would otherwise re-trigger this fallback. Guarded by the
        // probe `hasNext` / `next` so a non-Iterator Instance with
        // only `iterator()` doesn't drain.
        if let klio_runtime::Value::Instance(_) = receiver {
            let already_active = ITERABLE_FALLBACK_ACTIVE.with(std::cell::Cell::get);
            if !already_active && self.host_has_member(receiver, "iterator") {
                let intrinsic = self
                    .lookup_intrinsic(&format!("kotlin.collections.Iterable.{name}"))
                    .or_else(|| self.lookup_intrinsic(&format!("kotlin.collections.List.{name}")));
                if let Some(f) = intrinsic {
                    ITERABLE_FALLBACK_ACTIVE.with(|c| c.set(true));
                    let drain_result = self.drain_iterable_to_list(receiver);
                    ITERABLE_FALLBACK_ACTIVE.with(|c| c.set(false));
                    let drained = drain_result?;
                    let mut new_args: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    new_args.push(drained);
                    new_args.extend(args.iter().cloned());
                    return self.dispatch_intrinsic(f, &new_args);
                }
            }
        }
        Err(klio_ir::eval::EvalError::Unimplemented(format!(
            "Vm::call_member `{name}` on `{}`",
            receiver.type_fqn()
        )))
    }

    pub(crate) fn host_has_member(&mut self, receiver: &klio_runtime::Value, name: &str) -> bool {
        let klio_runtime::Value::Instance(inst) = receiver else {
            return false;
        };
        let cls = inst.borrow().class.name.clone();
        if self
            .module
            .registry
            .hierarchy_methods
            .get(&cls)
            .is_some_and(|m| m.contains(name))
        {
            return true;
        }
        // Fall back to the runtime ClassDef chain for classes that
        // predate the registry's hierarchy map (e.g. embedded
        // stdlib). Walk the *whole* supertype graph (every parent and
        // interface, breadth-first), not just the first parent — a
        // pack interface-declared `operator fun get` / `emit` lives on
        // an interface supertype, and missing it makes a real member
        // fall through to a same-named stdlib builtin.
        let mut queue: std::collections::VecDeque<String> = std::collections::VecDeque::new();
        queue.push_back(cls);
        let mut seen = std::collections::HashSet::new();
        while let Some(cur_name) = queue.pop_front() {
            if !seen.insert(cur_name.clone()) {
                continue;
            }
            if let Some(def) = self.classes.borrow().get(&cur_name).cloned() {
                let has = def
                    .methods
                    .iter()
                    .any(|m| m.name == name || m.name.rsplit('.').next() == Some(name));
                if has {
                    return true;
                }
                if def.primary_params.iter().any(|p| p.name == name) {
                    return true;
                }
                if def.body_properties.iter().any(|p| p.name == name) {
                    return true;
                }
                for sup in &def.supertype_names {
                    queue.push_back(sup.clone());
                }
            }
        }
        false
    }

    // single dispatch over named-argument member calls; splitting fragments one match
    #[allow(clippy::too_many_lines)]
    pub(crate) fn call_member_named(
        &mut self,
        receiver: &klio_runtime::Value,
        name: &str,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // data-class `copy(name = …, age = …)` — reorder named args
        // into the primary-ctor param positions, defaulting missing
        // slots to the receiver's current field values.
        if name == "copy"
            && let klio_runtime::Value::Instance(inst) = receiver
        {
            let class_def = inst.borrow().class.clone();
            if class_def.is_data {
                let n_params = class_def.primary_params.len();
                let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; n_params];
                let mut positional_idx = 0usize;
                for (i, a) in args.iter().enumerate() {
                    if let Some(Some(arg_name)) = arg_names.get(i) {
                        if let Some(pos) = class_def
                            .primary_params
                            .iter()
                            .position(|p| &p.name == arg_name)
                        {
                            slots[pos] = Some(a.clone());
                        }
                    } else {
                        if positional_idx < n_params {
                            slots[positional_idx] = Some(a.clone());
                        }
                        positional_idx += 1;
                    }
                }
                let inst_ref = inst.borrow();
                let mut new_args: Vec<klio_runtime::Value> = Vec::with_capacity(n_params);
                for (idx, p) in class_def.primary_params.iter().enumerate() {
                    let v = slots[idx]
                        .take()
                        .or_else(|| inst_ref.get(&p.name))
                        .unwrap_or(klio_runtime::Value::Null);
                    new_args.push(v);
                }
                drop(inst_ref);
                if let Some(class_id) = self.module.class_id(&class_def.name) {
                    return <VmHost as klio_ir::eval::Host>::new_instance(
                        self, class_id, &new_args,
                    );
                }
            }
        }
        // Stdlib intrinsic dispatch with named args: reorder
        // according to the stdlib's declared param order so callers
        // can pass `padEnd(padChar = '*', length = 4)`.
        if arg_names.iter().any(std::option::Option::is_some) {
            let type_fqn = receiver.type_fqn();
            let probes = [
                format!("{type_fqn}.{name}"),
                format!("kotlin.text.{name}"),
                format!("kotlin.collections.{name}"),
                format!("kotlin.{name}"),
            ];
            for probe in &probes {
                if let Some(params) = klio_stdlib::param_names(probe) {
                    let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; params.len()];
                    // 1. Bind every named argument to its slot.
                    let mut positionals: Vec<klio_runtime::Value> = Vec::new();
                    for (i, a) in args.iter().enumerate() {
                        if let Some(Some(arg_name)) = arg_names.get(i) {
                            if let Some(pos) = params.iter().position(|p| *p == arg_name.as_str()) {
                                slots[pos] = Some(a.clone());
                            }
                        } else {
                            positionals.push(a.clone());
                        }
                    }
                    // 2. A trailing lambda binds to the last
                    //    parameter (Kotlin's trailing-lambda rule:
                    //    `joinToString(separator = "; ") { … }` puts
                    //    the transform in `transform`, not slot 0).
                    if matches!(
                        positionals.last(),
                        Some(
                            klio_runtime::Value::IrClosure { .. }
                                | klio_runtime::Value::Lambda { .. }
                        )
                    ) && !params.is_empty()
                        && slots[params.len() - 1].is_none()
                    {
                        slots[params.len() - 1] = positionals.pop();
                    }
                    // 3. Remaining positionals fill empty slots
                    //    left-to-right (skipping named-filled ones).
                    let mut pit = positionals.into_iter();
                    for slot in &mut slots {
                        if slot.is_none() {
                            match pit.next() {
                                Some(v) => *slot = Some(v),
                                None => break,
                            }
                        }
                    }
                    let mut reordered: Vec<klio_runtime::Value> = slots
                        .into_iter()
                        .map(|s| s.unwrap_or(klio_runtime::Value::Null))
                        .collect();
                    while matches!(reordered.last(), Some(klio_runtime::Value::Null)) {
                        reordered.pop();
                    }
                    if let Some(func) = self.lookup_intrinsic(probe) {
                        let mut all_args: Vec<klio_runtime::Value> =
                            Vec::with_capacity(reordered.len() + 1);
                        all_args.push(receiver.clone());
                        all_args.extend(reordered);
                        return self.dispatch_intrinsic(func, &all_args);
                    }
                    break;
                }
            }
        }
        // User extension / member fn with named args: route through
        // `call_func_named` so names slot by the resolved function's
        // own parameter list and omitted (incl. *leading* defaulted)
        // params are filled — `recv.f(h = x)` for
        // `fun R.f(flag: Boolean = true, h: H)` must bind `h`, not
        // shift `x` into `flag`. Without this the fall-through dropped
        // `arg_names` and bound positionally.
        if arg_names.iter().any(std::option::Option::is_some) {
            if let Some(fid) = self.resolve_ext_overload(name, receiver, args, arg_names) {
                let module = Arc::clone(&self.module);
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                let mut names: Vec<Option<String>> = Vec::with_capacity(arg_names.len() + 1);
                names.push(None); // implicit `this` receiver slot
                names.extend(arg_names.iter().cloned());
                return self.call_func_named(&module, fid, all, &names);
            }
            // An instance method called with named / omitted arguments:
            // resolve it by walking the receiver's class hierarchy and
            // route through `call_func_named` so names slot by the
            // method's own parameter list and defaulted params fill.
            // The positional `call_member` / overload scorer below
            // can't match a reordered or short named-arg call.
            if let klio_runtime::Value::Instance(inst) = receiver {
                let start = inst.borrow().class.name.clone();
                let mut queue: std::collections::VecDeque<String> =
                    std::collections::VecDeque::new();
                let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
                queue.push_back(start);
                let mut method_fid: Option<klio_ir::FuncId> = None;
                while let Some(cur) = queue.pop_front() {
                    if !seen.insert(cur.clone()) {
                        continue;
                    }
                    if let Some(ir_class) = self.module.classes.iter().find(|c| c.name == cur)
                        && let Some(fid) = ir_class.methods.iter().find(|fid| {
                            self.module
                                .funcs
                                .get(fid.0 as usize)
                                // Tolerate a package/class-qualified
                                // lowered name (`Cls.method`) as well as
                                // Bare method name OR its trailing
                                // qualified-name segment — matches what
                                // `host_has_member` reports, so a
                                // member it sees as present is actually
                                // dispatchable.
                                .is_some_and(|f| {
                                    f.name == name || f.name.rsplit('.').next() == Some(name)
                                })
                        })
                    {
                        method_fid = Some(*fid);
                        break;
                    }
                    if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                        for sup in &def.supertype_names {
                            queue.push_back(sup.clone());
                        }
                    }
                }
                if let Some(fid) = method_fid {
                    let module = Arc::clone(&self.module);
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                    all.push(receiver.clone());
                    all.extend_from_slice(args);
                    let mut names: Vec<Option<String>> = Vec::with_capacity(arg_names.len() + 1);
                    names.push(None); // implicit `this` receiver slot
                    names.extend(arg_names.iter().cloned());
                    return self.call_func_named(&module, fid, all, &names);
                }
            }
        }
        // Positional / no-named-args instance call. Run normal
        // dispatch FIRST so klio's stdlib-intrinsic shadowing wins —
        // A native stdlib-bound method must beat a pack's IR
        // fallback-stub body of the same name (the stub typically
        // returns a constant that would spin a CAS loop forever).
        // Only if `call_member` yields klio's "no such member"
        // sentinel (`Unimplemented`) do we walk the class hierarchy
        // in `module.classes` for a method that lowers with a
        // class-qualified func name, reached bare from inside a
        // closure — `host_has_member` reports it as present but
        // `call_member` cannot dispatch the bare name alone.
        let primary = self.call_member(receiver, name, args);
        if !matches!(primary, Err(klio_ir::eval::EvalError::Unimplemented(_))) {
            return primary;
        }
        if let klio_runtime::Value::Instance(inst) = receiver {
            let start = inst.borrow().class.name.clone();
            let mut queue: std::collections::VecDeque<String> = std::collections::VecDeque::new();
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            queue.push_back(start);
            let mut method_fid: Option<klio_ir::FuncId> = None;
            while let Some(cur) = queue.pop_front() {
                if !seen.insert(cur.clone()) {
                    continue;
                }
                if let Some(ir_class) = self.module.classes.iter().find(|c| c.name == cur)
                    && let Some(fid) = ir_class.methods.iter().find(|fid| {
                        self.module.funcs.get(fid.0 as usize).is_some_and(|f| {
                            f.name == name || f.name.rsplit('.').next() == Some(name)
                        })
                    })
                {
                    method_fid = Some(*fid);
                    break;
                }
                if let Some(def) = self.classes.borrow().get(&cur).cloned() {
                    for sup in &def.supertype_names {
                        queue.push_back(sup.clone());
                    }
                }
            }
            if let Some(fid) = method_fid {
                let module = Arc::clone(&self.module);
                let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(args.len() + 1);
                all.push(receiver.clone());
                all.extend_from_slice(args);
                let mut names: Vec<Option<String>> = vec![None; all.len()];
                names.truncate(all.len());
                return self.call_func_named(&module, fid, all, &names);
            }
        }
        primary
    }
}
