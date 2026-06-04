use crate::{
    Arc, AtomicOrdering, VmHost, default_value_for_primary, is_builtin_throwable_fqn,
    simple_literal, with_ctor_guard, with_inner_outer_hint,
};

impl VmHost<'_> {
    #[allow(clippy::too_many_lines)]
    pub(crate) fn new_instance_named(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
        arg_names: &[Option<String>],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        // Specific intrinsic-backed classes whose constructor must
        // produce klio's host-owned runtime value (Value::StringBuilder,
        // Value::Map, …) rather than a generic Instance. Listed by
        // FQN so the resolver routes upstream `expect class …`
        // shells to the host ctor without disturbing user-defined
        // classes that happen to share a name.
        if let Some(ir_class) = self.module.classes.get(class.0 as usize) {
            let fqn = ir_class.fqn.as_str();
            let intrinsic_class = matches!(
                fqn,
                "kotlin.text.StringBuilder"
                    | "kotlin.text.Regex"
                    | "kotlin.collections.HashMap"
                    | "kotlin.collections.HashSet"
                    | "kotlin.collections.LinkedHashMap"
                    | "kotlin.collections.LinkedHashSet"
                    | "kotlin.collections.ArrayList"
                    | "kotlin.collections.ArrayDeque"
                    | "kotlin.IntArray"
                    | "kotlin.LongArray"
                    | "kotlin.ShortArray"
                    | "kotlin.ByteArray"
                    | "kotlin.FloatArray"
                    | "kotlin.DoubleArray"
                    | "kotlin.BooleanArray"
                    | "kotlin.CharArray"
                    | "kotlin.Array"
                    | "kotlin.String"
            );
            if intrinsic_class {
                // Skip the intrinsic path when the first arg is itself
                // an Array — that shape (`Array(items)` copy / wrap)
                // doesn't match any klio array ctor and the generic
                // Instance allocation handles it correctly. `String` is
                // exempt: `String(CharArray)` legitimately takes an array.
                let first_is_array =
                    matches!(args.first(), Some(klio_runtime::Value::Array { .. }))
                        && fqn != "kotlin.String";
                if !first_is_array && let Some(intrinsic) = self.lookup_intrinsic(fqn) {
                    return self.dispatch_intrinsic(intrinsic, args);
                }
            }
        }
        if arg_names.iter().all(std::option::Option::is_none) {
            return <Self as klio_ir::eval::Host>::new_instance(self, class, args);
        }
        let ir_class = self.module.classes.get(class.0 as usize).ok_or_else(|| {
            klio_ir::eval::EvalError::Type(format!(
                "Vm::new_instance_named: ClassId {} not found",
                class.0
            ))
        })?;
        let class_name = ir_class.name.clone();
        let primary_names: Vec<String> = ir_class
            .primary_params
            .iter()
            .map(|p| p.name.clone())
            .collect();
        let supplied_names: Vec<String> = arg_names.iter().flatten().cloned().collect();
        let class_def = self.classes.borrow().get(&class_name).cloned();
        // Prefer the primary signature only when every named argument
        // names a primary parameter *and* every parameter the caller
        // omitted has a default — otherwise a secondary constructor whose
        // own defaults cover the gap is the real target (`DatePeriod(days
        // = 5)` skips `years`/`months`; the private primary has no
        // defaults for them). new_instance's trailing-only default pass
        // can't recover a non-trailing omitted slot once materialized, so
        // supply the defaults here.
        if supplied_names
            .iter()
            .all(|nm| primary_names.iter().any(|p| p == nm))
        {
            let n = primary_names.len();
            let mut reordered: Vec<Option<klio_runtime::Value>> = vec![None; n];
            let mut next_pos = 0usize;
            let mut overflow = false;
            for (i, v) in args.iter().enumerate() {
                if let Some(nm) = arg_names.get(i).and_then(std::clone::Clone::clone) {
                    if let Some(idx) = primary_names.iter().position(|p| *p == nm) {
                        reordered[idx] = Some(v.clone());
                    }
                } else {
                    while next_pos < n && reordered[next_pos].is_some() {
                        next_pos += 1;
                    }
                    if next_pos >= n {
                        overflow = true;
                        break;
                    }
                    reordered[next_pos] = Some(v.clone());
                    next_pos += 1;
                }
            }
            let primary_satisfiable = !overflow
                && reordered.iter().enumerate().all(|(idx, slot)| {
                    slot.is_some()
                        || class_def
                            .as_ref()
                            .and_then(|d| d.primary_params.get(idx))
                            .is_some_and(|p| p.default.is_some())
                });
            if primary_satisfiable {
                let final_args: Vec<klio_runtime::Value> = reordered
                    .into_iter()
                    .enumerate()
                    .map(|(idx, slot)| {
                        slot.unwrap_or_else(|| {
                            let dflt = class_def
                                .as_ref()
                                .and_then(|d| d.primary_params.get(idx))
                                .and_then(|p| p.default.as_ref());
                            dflt.and_then(|e| default_value_for_primary(e))
                                // A primary-ctor default that is a bare
                                // reference to a top-level `const val`
                                // (`port: Int = DEFAULT_PORT`) is evaluated
                                // here from the raw AST; resolve the constant
                                // from the const registry so it isn't `Null`
                                // when a companion/object init constructs the
                                // class at load before the const's global slot
                                // is set (`URLBuilder.Companion`'s
                                // `Url(origin)`).
                                .or_else(|| {
                                    if let Some(e) = dflt
                                        && let klio_ast::Expr::Path { segments, .. } = e.as_ref()
                                        && segments.len() == 1
                                    {
                                        return self
                                            .module
                                            .registry
                                            .class_const_inits
                                            .get(&(String::new(), segments[0].name.clone()))
                                            .map(klio_ir::eval::const_to_value);
                                    }
                                    None
                                })
                                .unwrap_or(klio_runtime::Value::Null)
                        })
                    })
                    .collect();
                return <Self as klio_ir::eval::Host>::new_instance(self, class, &final_args);
            }
        }
        // A named argument names a *secondary*-constructor parameter.
        // Reorder against the secondary ctor whose parameter names cover
        // every supplied name, fill its omitted slots from the per-param
        // default thunks, and dispatch the full positional list (whose
        // arity then selects that same secondary ctor in new_instance).
        let entries = self
            .prog
            .secondary_ctors
            .get(&class_name)
            .cloned()
            .unwrap_or_default();
        let chosen = entries.into_iter().find(|e| {
            e.param_count >= args.len()
                && supplied_names
                    .iter()
                    .all(|nm| e.param_names.iter().any(|p| p == nm))
        });
        if let Some(entry) = chosen {
            let mut slots: Vec<Option<klio_runtime::Value>> = vec![None; entry.param_count];
            let mut next_pos = 0usize;
            for (i, v) in args.iter().enumerate() {
                if let Some(nm) = arg_names.get(i).and_then(std::clone::Clone::clone) {
                    if let Some(idx) = entry.param_names.iter().position(|p| *p == nm) {
                        slots[idx] = Some(v.clone());
                    }
                } else {
                    while next_pos < slots.len() && slots[next_pos].is_some() {
                        next_pos += 1;
                    }
                    if next_pos < slots.len() {
                        slots[next_pos] = Some(v.clone());
                        next_pos += 1;
                    }
                }
            }
            let module = Arc::clone(&self.module);
            let mut full: Vec<klio_runtime::Value> = Vec::with_capacity(entry.param_count);
            for (idx, slot) in slots.into_iter().enumerate() {
                if let Some(v) = slot {
                    full.push(v);
                    continue;
                }
                if let Some(dfid) = entry.default_arg_thunks.get(idx).copied().flatten() {
                    let func = module.funcs.get(dfid.0 as usize).cloned().ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "secondary ctor default FuncId {} out of range",
                            dfid.0
                        ))
                    })?;
                    let mut targs = full.clone();
                    targs.resize(entry.param_count, klio_runtime::Value::Null);
                    full.push(klio_ir::eval::eval_with(&module, &func, targs, self)?);
                } else {
                    full.push(klio_runtime::Value::Null);
                }
            }
            return <Self as klio_ir::eval::Host>::new_instance(self, class, &full);
        }
        <Self as klio_ir::eval::Host>::new_instance(self, class, args)
    }

    // Core constructor pipeline; one tightly-coupled allocation flow.
    #[allow(clippy::too_many_lines)]
    pub(crate) fn new_instance(
        &mut self,
        class: klio_ir::ClassId,
        args: &[klio_runtime::Value],
    ) -> Result<klio_runtime::Value, klio_ir::eval::EvalError> {
        let ir_class = self.module.classes.get(class.0 as usize).ok_or_else(|| {
            klio_ir::eval::EvalError::Type(format!(
                "Vm::new_instance: ClassId {} not found in module",
                class.0
            ))
        })?;
        // The builtin Throwable hierarchy ships as declaration-only
        // `expect` classes (no `actual` body stores `message`/`cause`):
        // their construction is host-backed and must produce a
        // `Value::Exception` via the `excn_*` intrinsic, not a generic
        // Instance whose secondary-ctor `super(message)` chain has
        // nowhere to bind the detail message. Gate on the class's own
        // builtin FQN so a user subclass (its own FQN) still allocates a
        // real Instance and chains up through the normal ctor path.
        {
            let fqn = ir_class.fqn.clone();
            if is_builtin_throwable_fqn(&fqn)
                && let Some(intrinsic) = self.lookup_intrinsic(&fqn)
            {
                return self.dispatch_intrinsic(intrinsic, args);
            }
        }
        let mut class_def = self
            .classes
            .borrow()
            .get(&ir_class.name)
            .cloned()
            .ok_or_else(|| {
                klio_ir::eval::EvalError::Unimplemented(format!(
                    "Vm::new_instance: no runtime ClassDef registered for `{}`",
                    ir_class.name
                ))
            })?;
        // A constructor's target is never abstract. Resolving to an
        // abstract class here is a simple-name collision artifact: two
        // distinct fully-qualified classes share a simple name, and
        // the abstract one happened to be registered last. Redirect to
        // the same-simple-name concrete sibling via the FQN entries.
        if class_def.is_abstract {
            let want = ir_class.name.clone();
            let concrete = {
                let g = self.classes.borrow();
                g.values()
                    .find(|d| d.name == want && !d.is_abstract && !d.is_interface)
                    .cloned()
            };
            if let Some(d) = concrete {
                class_def = d;
            }
        }
        // Same collision artifact for an interface: a ctor target whose simple
        // name also names an interface (a nested `Map.Entry` / `MutableEntry`
        // synthesised from a type position vs a user `class Entry` implementing
        // it) may resolve to the interface when it was registered last.
        // Redirect to the concrete same-name sibling so `Entry(...)` constructs
        // the class. A genuine interface with no concrete sibling (`List`,
        // `MutableList`) is left alone for the factory handling below.
        if class_def.is_interface {
            let want = ir_class.name.clone();
            let concrete = {
                let g = self.classes.borrow();
                g.values()
                    .find(|d| d.name == want && !d.is_abstract && !d.is_interface)
                    .cloned()
            };
            if let Some(d) = concrete {
                class_def = d;
            }
        }
        if class_def.is_abstract {
            return Err(klio_ir::eval::EvalError::Throw(
                klio_runtime::Value::Exception {
                    fqn: std::sync::Arc::new("kotlin.InstantiationError".to_string()),
                    message: Some(std::sync::Arc::new(format!(
                        "Cannot create an instance of an abstract class: {}",
                        class_def.name
                    ))),
                    cause: None,
                },
            ));
        }
        if class_def.is_interface {
            // `List(size) { init }` / `MutableList(size) { init }` share the
            // interface's simple name with a top-level factory function. The
            // Kotlin factory is `inline`, so a pack consumer sees only a
            // bodyless stub and the bare call resolves to this interface,
            // landing here. Build the list directly by invoking
            // `init(0)…init(size-1)`, matching the factory's semantics.
            if matches!(class_def.name.as_str(), "List" | "MutableList")
                && args.len() == 2
                && let Some(size) = args[0].as_i64()
            {
                let init = args[1].clone();
                let mut items: Vec<klio_runtime::Value> =
                    Vec::with_capacity(usize::try_from(size).unwrap_or(0));
                for i in 0..size {
                    #[allow(clippy::cast_possible_truncation)]
                    let idx = klio_runtime::Value::Int(i as i32);
                    items.push(self.call_value(&init, &[idx])?);
                }
                return Ok(klio_runtime::Value::List {
                    items: klio_runtime::ObjRef::new(items),
                    mutable: class_def.name == "MutableList",
                    enum_class: None,
                    backing: None,
                });
            }
            // SAM conversion: `FunInterface(lambda)` direct-call
            // path wraps the callable in a synthetic instance whose
            // `__sam_target__` field captures the lambda; method
            // calls on the result invoke the captured callable.
            if class_def.is_fun_interface && args.len() == 1 {
                let identity = self
                    .instance_id_counter
                    .fetch_add(1, AtomicOrdering::Relaxed)
                    + 1;
                let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
                    class: Arc::clone(&class_def),
                    fields: vec![("__sam_target__".to_string(), args[0].clone())],
                    outer: None,
                    identity,
                    native_state: None,
                });
                return Ok(klio_runtime::Value::Instance(inst));
            }
            return Err(klio_ir::eval::EvalError::Throw(
                klio_runtime::Value::Exception {
                    fqn: std::sync::Arc::new("kotlin.InstantiationError".to_string()),
                    message: Some(std::sync::Arc::new(format!(
                        "Cannot create an instance of an interface: {}",
                        class_def.name
                    ))),
                    cause: None,
                },
            ));
        }
        // Secondary-ctor dispatch: when the supplied arg count
        // doesn't match the primary signature, look for a
        // secondary ctor with the matching arity. Evaluate its
        // delegation arg thunks, recurse for `: this(...)`, then
        // run the optional body block.
        let n_primary = class_def.primary_params.len();
        // A class with no primary constructor (only `private
        // constructor(...)` declarations) initialises its fields
        // only in a secondary constructor body. When the arg count
        // happens to equal the (empty) primary's, dispatch must
        // still route to the matching secondary so its body runs —
        // otherwise the instance is left with uninitialised fields.
        let zero_primary_secondary = n_primary == 0
            && self
                .prog
                .secondary_ctors
                .get(&class_def.name)
                .is_some_and(|v| v.iter().any(|e| e.param_count == args.len()));
        let shell_guarded = with_ctor_guard(|g| g.borrow().iter().any(|n| n == &class_def.name));
        if !shell_guarded && (args.len() != n_primary || zero_primary_secondary) {
            let entries = self
                .prog
                .secondary_ctors
                .get(&class_def.name)
                .cloned()
                .unwrap_or_default();
            let chosen = entries
                .iter()
                .find(|e| e.param_count == args.len())
                .or_else(|| {
                    // No exact-arity ctor: accept one with more
                    // parameters when every one the caller omitted has a
                    // default to supply.
                    entries.iter().find(|e| {
                        e.param_count > args.len()
                            && e.default_arg_thunks
                                .iter()
                                .skip(args.len())
                                .all(std::option::Option::is_some)
                    })
                });
            if let Some(entry) = chosen {
                let module = Arc::clone(&self.module);
                // Materialize the full positional argument list, filling
                // trailing parameters the caller omitted from their
                // default thunks (each evaluated against the arguments
                // resolved so far; padded so the thunk sees its arity).
                let mut full_args: Vec<klio_runtime::Value> = args.to_vec();
                for idx in args.len()..entry.param_count {
                    let dfid = entry.default_arg_thunks[idx].ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "secondary ctor param {idx} has no default to apply"
                        ))
                    })?;
                    let func = module.funcs.get(dfid.0 as usize).cloned().ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "secondary ctor default FuncId {} out of range",
                            dfid.0
                        ))
                    })?;
                    let mut thunk_args = full_args.clone();
                    thunk_args.resize(entry.param_count, klio_runtime::Value::Null);
                    let v = klio_ir::eval::eval_with(&module, &func, thunk_args, self)?;
                    full_args.push(v);
                }
                let mut target_args: Vec<klio_runtime::Value> =
                    Vec::with_capacity(entry.delegation_arg_thunks.len());
                for fid in &entry.delegation_arg_thunks {
                    let func = module.funcs.get(fid.0 as usize).cloned().ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "secondary ctor arg FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                    let v = klio_ir::eval::eval_with(&module, &func, full_args.clone(), self)?;
                    target_args.push(v);
                }
                // For `: this(...)` recurse via new_instance with
                // the resolved args. For `: super(...)`, allocate
                // the leaf class shell directly and populate the
                // parent's primary-param fields from the resolved
                // args; the leaf's body props + init blocks run
                // through the normal path below by falling through
                // to the primary-ctor path with empty args.
                let inst_v = if entry.is_super {
                    let parent_def = class_def.parent.borrow().clone().or_else(|| {
                        class_def
                            .supertype_names
                            .first()
                            .and_then(|n| self.classes.borrow().get(n).cloned())
                    });
                    if let Some(pdef) = parent_def {
                        // Allocate the leaf shell under a guard so the
                        // recursive `new_instance` doesn't re-enter
                        // this same secondary ctor and recurse
                        // unbounded.
                        with_ctor_guard(|g| g.borrow_mut().push(class_def.name.clone()));
                        let leaf_res =
                            <Self as klio_ir::eval::Host>::new_instance(self, class, &[]);
                        with_ctor_guard(|g| {
                            g.borrow_mut().pop();
                        });
                        let leaf = leaf_res?;
                        if let klio_runtime::Value::Instance(leaf_inst) = &leaf {
                            for (p, value) in pdef.primary_params.iter().zip(target_args.iter()) {
                                if p.property.is_some() {
                                    let mut i = leaf_inst.borrow_mut();
                                    i.fields.retain(|(n, _)| n != &p.name);
                                    i.fields.push((p.name.clone(), value.clone()));
                                }
                            }
                        }
                        // Dispatch the parent's matching secondary
                        // ctor chain on the same leaf so its body and
                        // any `: this(...)` delegations actually run.
                        // Without this, only the leaf shell is
                        // allocated and the parent's ctor body (which
                        // typically sets fields) is skipped.
                        self.run_super_ctor_chain(&leaf, &pdef.name, &target_args)?;
                        leaf
                    } else {
                        // No user ClassDef for the parent — it's a
                        // built-in. For the Throwable hierarchy the
                        // `super(...)` args are the conventional
                        // `(message, cause)` pair, so allocate the
                        // leaf shell and bind those fields directly
                        // (mirrors the primary-ctor Throwable path).
                        // This is what makes `expect open class
                        // IOException : Exception { constructor(...) }`
                        // and friends usable.
                        let parent_name = class_def
                            .supertype_names
                            .first()
                            .cloned()
                            .unwrap_or_default();
                        let is_throwable_name = matches!(
                            parent_name.as_str(),
                            "Throwable"
                                | "Exception"
                                | "RuntimeException"
                                | "Error"
                                | "IOException"
                                | "EOFException"
                                | "IllegalArgumentException"
                                | "IllegalStateException"
                                | "IndexOutOfBoundsException"
                                | "NullPointerException"
                                | "ClassCastException"
                                | "ArithmeticException"
                                | "NumberFormatException"
                                | "NoSuchElementException"
                                | "ConcurrentModificationException"
                                | "UnsupportedOperationException"
                        );
                        if !is_throwable_name {
                            return Err(klio_ir::eval::EvalError::Unimplemented(format!(
                                "Vm::new_instance: secondary ctor super-delegation for `{}` (no parent class def)",
                                class_def.name
                            )));
                        }
                        let leaf = <Self as klio_ir::eval::Host>::new_instance(self, class, &[])?;
                        if let klio_runtime::Value::Instance(leaf_inst) = &leaf {
                            let mut i = leaf_inst.borrow_mut();
                            // `super(message)` / `super(cause)` /
                            // `super(message, cause)`: a lone
                            // Throwable arg is the cause, a lone
                            // String/null is the message.
                            match target_args.as_slice() {
                                [only] => {
                                    let is_cause = matches!(only, klio_runtime::Value::Instance(_));
                                    let key = if is_cause { "cause" } else { "message" };
                                    i.fields.retain(|(n, _)| n != key);
                                    i.fields.push((key.to_string(), only.clone()));
                                }
                                [msg, cause, ..] => {
                                    i.fields.retain(|(n, _)| n != "message" && n != "cause");
                                    i.fields.push(("message".to_string(), msg.clone()));
                                    i.fields.push(("cause".to_string(), cause.clone()));
                                }
                                [] => {}
                            }
                        }
                        leaf
                    }
                } else if entry.is_this {
                    // `: this(args)` — delegate to a sibling
                    // constructor with the resolved arguments.
                    <Self as klio_ir::eval::Host>::new_instance(self, class, &target_args)?
                } else {
                    // `CtorDelegation::None` — implicit `super()`.
                    // Build the primary instance shell (default
                    // fields + body-prop inits + init blocks) under a
                    // recursion guard so this very constructor isn't
                    // re-dispatched.
                    with_ctor_guard(|g| g.borrow_mut().push(class_def.name.clone()));
                    let shell = <Self as klio_ir::eval::Host>::new_instance(self, class, &[]);
                    with_ctor_guard(|g| {
                        g.borrow_mut().pop();
                    });
                    shell?
                };
                // Body block — evaluate with `[this, ctor_params...]`.
                if let Some(body_fid) = entry.body
                    && let Some(body_func) = module.funcs.get(body_fid.0 as usize).cloned()
                {
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(1 + full_args.len());
                    all.push(inst_v.clone());
                    all.extend_from_slice(&full_args);
                    klio_ir::eval::eval_with(&module, &body_func, all, self)?;
                }
                return Ok(inst_v);
            }
        }
        // Trivial primary-ctor shape: each primary param with
        // `property = Some(...)` becomes an instance field, then
        // body properties with init thunks run to populate their
        // fields. Init blocks, parent ctor chain, secondary ctors,
        // and supertype delegates are not yet handled.
        if !class_def.parent_ctor_args.is_empty()
            || !class_def.supertype_delegates.borrow().is_empty()
        {
            // parent ctor args + supertype delegates handled
            // further below — accept them as non-error here.
        }
        let n_primary = class_def.primary_params.len();
        let mut effective_args: Vec<klio_runtime::Value> = args.to_vec();
        if effective_args.len() < n_primary {
            for idx in effective_args.len()..n_primary {
                let p = &class_def.primary_params[idx];
                let v = match &p.default {
                    Some(e) => default_value_for_primary(e)
                        // A bare top-level `const val` default
                        // (`port: Int = DEFAULT_PORT`) is resolved from the
                        // const registry, so it isn't `Null` when a companion
                        // / object initializer constructs the class at load
                        // before the const's global slot is set.
                        .or_else(|| {
                            if let klio_ast::Expr::Path { segments, .. } = e.as_ref()
                                && segments.len() == 1
                            {
                                return self
                                    .module
                                    .registry
                                    .class_const_inits
                                    .get(&(String::new(), segments[0].name.clone()))
                                    .map(klio_ir::eval::const_to_value);
                            }
                            None
                        })
                        .unwrap_or(klio_runtime::Value::Null),
                    None => klio_runtime::Value::Null,
                };
                effective_args.push(v);
            }
        }
        if effective_args.len() != n_primary {
            // Kotlin allows a top-level factory function with the same
            // name as a class (`fun TimeoutCancellationException(time,
            // delay, coroutine, name)` beside the 2-arg class). When
            // the call's arity doesn't fit any constructor but a
            // same-named module function does, that factory is the
            // resolution — dispatch it instead of failing. (Lower-time
            // can't always pick it: forward-reference stubs hide the
            // real arity.)
            let module = Arc::clone(&self.module);
            let factory = module
                .funcs_by_simple_name(&class_def.name)
                .iter()
                .filter_map(|fid| module.funcs.get(fid.0 as usize).map(|f| (*fid, f)))
                .find(|(_, f)| {
                    !f.blocks.is_empty()
                        && (f.params.len() == effective_args.len()
                            || f.params.last().is_some_and(|p| p.is_vararg))
                })
                .map(|(fid, _)| fid);
            if let Some(fid) = factory {
                return self.call_func(&module, fid, effective_args.clone());
            }
            return Err(klio_ir::eval::EvalError::Arity(format!(
                "{}() expects {n_primary} args, got {}",
                class_def.name,
                effective_args.len()
            )));
        }
        let args = effective_args.as_slice();
        let identity = self
            .instance_id_counter
            .fetch_add(1, AtomicOrdering::Relaxed)
            + 1;
        let mut fields: Vec<(String, klio_runtime::Value)> =
            Vec::with_capacity(class_def.primary_params.len() + class_def.body_properties.len());
        // Walk the parent ctor chain top-down: each parent gets
        // args computed by its child's parent_ctor_args thunks
        // (taking the child's own primary args). Properties from
        // every level land on the same instance, so a class
        // overriding `name` via the parent's primary param sees the
        // field correctly.
        let mut chain: Vec<(String, Vec<klio_runtime::Value>)> = Vec::new();
        chain.push((ir_class.name.clone(), args.to_vec()));
        let mut cur_class = ir_class.name.clone();
        let mut cur_args: Vec<klio_runtime::Value> = args.to_vec();
        // Throwable-style parent ctor handling: when this class
        // extends a built-in `RuntimeException`/`Throwable`/etc.
        // (no user ClassDef registered), evaluate the parent-ctor
        // arg thunks once and bind `message`/`cause` on the
        // instance so user-visible `e.message` works.
        let mut throwable_message: Option<klio_runtime::Value> = None;
        let mut throwable_cause: Option<klio_runtime::Value> = None;
        {
            let cur_def = self.classes.borrow().get(&cur_class).cloned();
            // First non-interface supertype (the class parent) — see the
            // chain-walk note below; an interface listed first is not the
            // throwable ancestor whose `super(...)` carries message/cause.
            let parent_name = cur_def.as_ref().and_then(|d| {
                d.supertype_names
                    .iter()
                    .find(|n| {
                        self.classes
                            .borrow()
                            .get(n.as_str())
                            .is_none_or(|sd| !sd.is_interface)
                    })
                    .cloned()
            });
            if let Some(pname) = parent_name {
                let is_throwable_name = matches!(
                    pname.as_str(),
                    "Throwable"
                        | "Exception"
                        | "RuntimeException"
                        | "Error"
                        | "IllegalArgumentException"
                        | "IllegalStateException"
                        | "IndexOutOfBoundsException"
                        | "NullPointerException"
                        | "ClassCastException"
                        | "ArithmeticException"
                        | "NumberFormatException"
                        | "NoSuchElementException"
                        | "ConcurrentModificationException"
                        | "UnsupportedOperationException"
                );
                // A builtin Throwable parent stores neither `message`
                // nor `cause` itself (its `expect` ctors have no body),
                // whether or not an `expect`-shell ClassDef is
                // registered for it. Evaluate this class's
                // parent-ctor-arg thunks to recover the `super(...)`
                // message/cause and bind them on the leaf.
                if is_throwable_name
                    && let Some(thunks) = self.prog.parent_ctor_args.get(&cur_class).cloned()
                {
                    for (idx, fid) in thunks.iter().enumerate() {
                        if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                            let v = klio_ir::eval::eval_with(
                                &Arc::clone(&self.module),
                                &func,
                                cur_args.clone(),
                                self,
                            )?;
                            match idx {
                                0 => throwable_message = Some(v),
                                1 => throwable_cause = Some(v),
                                _ => {}
                            }
                        }
                    }
                }
            }
        }
        while let Some(thunks) = self.prog.parent_ctor_args.get(&cur_class).cloned() {
            let cur_def = self.classes.borrow().get(&cur_class).cloned();
            // The superclass for ctor chaining is the first *non-interface*
            // supertype — a class may list interfaces before its superclass
            // (`HeadersImpl : Headers, StringValuesImpl(...)`), and the
            // `super(...)` args belong to that superclass, not the interface.
            // A supertype with no registered ClassDef (a builtin like
            // `Throwable`) is treated as the class parent.
            let parent_name = cur_def.as_ref().and_then(|d| {
                d.supertype_names
                    .iter()
                    .find(|n| {
                        self.classes
                            .borrow()
                            .get(n.as_str())
                            .is_none_or(|sd| !sd.is_interface)
                    })
                    .cloned()
            });
            let Some(parent_name) = parent_name else {
                break;
            };
            // Evaluate this level's `super(...)` arguments (against the
            // current level's args) up front — needed to recover a
            // builtin-Throwable ancestor's message/cause even when that
            // ancestor has no user ClassDef to chain into.
            let mut parent_args: Vec<klio_runtime::Value> = Vec::with_capacity(thunks.len());
            for fid in &thunks {
                let func = self
                    .module
                    .funcs
                    .get(fid.0 as usize)
                    .cloned()
                    .ok_or_else(|| {
                        klio_ir::eval::EvalError::Type(format!(
                            "parent ctor arg FuncId {} out of range",
                            fid.0
                        ))
                    })?;
                let module = Arc::clone(&self.module);
                let v = klio_ir::eval::eval_with(&module, &func, cur_args.clone(), self)?;
                parent_args.push(v);
            }
            // A builtin Throwable ancestor (any number of levels up) holds
            // message/cause through these super-args. The direct-parent
            // pass above only checks the immediate parent, so a
            // multi-level hierarchy (`NotFound : AppError :
            // RuntimeException`) would otherwise lose its message.
            let parent_is_throwable = matches!(
                parent_name.as_str(),
                "Throwable"
                    | "Exception"
                    | "RuntimeException"
                    | "Error"
                    | "IOException"
                    | "EOFException"
                    | "IllegalArgumentException"
                    | "IllegalStateException"
                    | "IndexOutOfBoundsException"
                    | "NullPointerException"
                    | "ClassCastException"
                    | "ArithmeticException"
                    | "NumberFormatException"
                    | "NoSuchElementException"
                    | "ConcurrentModificationException"
                    | "UnsupportedOperationException"
                    | "CancellationException"
            );
            if parent_is_throwable {
                if throwable_message.is_none() {
                    throwable_message = parent_args.first().cloned();
                }
                if throwable_cause.is_none() {
                    throwable_cause = parent_args.get(1).cloned();
                }
                break;
            }
            // Resolve to a non-interface parent for ctor chaining.
            let parent_def = self.classes.borrow().get(&parent_name).cloned();
            if parent_def.as_ref().is_none_or(|d| d.is_interface) {
                break;
            }
            chain.push((parent_name.clone(), parent_args.clone()));
            cur_class = parent_name;
            cur_args = parent_args;
        }
        // Apply primary-param properties from each level bottom-up
        // so child overrides win on collision.
        for (cls_name, cls_args) in chain.iter().rev() {
            // The class table is keyed by simple name, so a synthesised
            // interface (`Map.Entry`) can shadow a concrete same-name class
            // (`class Entry`) — the re-lookup would then return the interface
            // (no primary params) and the instance's fields stay empty. The
            // constructor was already redirected to the concrete `class_def`;
            // reuse it for the leaf instead of the shadowing table entry.
            let cls_def = self
                .classes
                .borrow()
                .get(cls_name)
                .cloned()
                .filter(|d| !d.is_interface);
            let cls_def = cls_def.or_else(|| {
                (*cls_name == class_def.name).then(|| Arc::clone(&class_def))
            });
            if let Some(cls_def) = cls_def {
                for (param, value) in cls_def.primary_params.iter().zip(cls_args.iter()) {
                    if param.property.is_some() {
                        // Normalize a bare integer-literal argument to a
                        // `Long` field's declared type, matching Kotlin's
                        // literal typing (`C(n = 1)` with `n: Long`).
                        let mut field_value = value.clone();
                        if param.declared_type.as_deref() == Some("Long")
                            && let klio_runtime::Value::Int(n) = field_value
                        {
                            field_value = klio_runtime::Value::Long(i64::from(n));
                        }
                        fields.retain(|(n, _)| n != &param.name);
                        fields.push((param.name.clone(), field_value));
                    }
                }
            }
        }
        let _ = (&class_def.primary_params, args);
        // Seed non-nullable primitive `var` fields with their type
        // zero so reads before the (possibly missing) init thunk
        // runs don't observe `Null`. Matters for upstream `expect`
        // classes like `AbstractMutableList.modCount: Int` whose
        // declaration has no initializer expression.
        {
            let mut cur = Some(Arc::clone(&class_def));
            while let Some(c) = cur.take() {
                for p in &c.body_properties {
                    if p.init.is_some() || p.getter.is_some() || p.delegate.is_some() {
                        continue;
                    }
                    if let Some(v) = p.primitive_zero.clone()
                        && !fields.iter().any(|(n, _)| n == &p.name)
                    {
                        fields.push((p.name.clone(), v));
                    }
                }
                cur.clone_from(&c.parent.borrow());
            }
        }
        // Materialise the instance with primary-param fields now so
        // body-property initialisers can reference `this` (and read
        // already-bound fields). Body props get appended into the
        // same instance after the init thunks run.
        let inst = klio_runtime::ObjRef::new(klio_runtime::InstanceData {
            class: class_def.clone(),
            fields,
            outer: None,
            identity,
            native_state: None,
        });
        let inst_value = klio_runtime::Value::Instance(inst.clone());
        // Attach a stored default-outer if the class was
        // registered inside a method body via Inst::RegisterClass —
        // lets `this@Outer.X` and outer-field reads resolve.
        if inst.borrow().outer.is_none()
            && let Some(default_outer) = self
                .class_default_outer
                .borrow()
                .get(&class_def.name)
                .cloned()
        {
            inst.borrow_mut().outer = Some(default_outer);
        }
        // Inner-class allocation: the caller's `Inst::NewInstance`
        // handler stashed the active `this` so init bodies can resolve
        // outer-class members through the outer-chain walk in
        // `get_field`. Wire it on the instance before init runs.
        if class_def.is_inner
            && inst.borrow().outer.is_none()
            && let Some(hint) = with_inner_outer_hint(|s| s.borrow().last().cloned())
        {
            inst.borrow_mut().outer = Some(hint);
        }
        // Publish object / companion singletons into globals *before*
        // their body-property initialisers and init blocks run, so a
        // companion whose initialiser (transitively) references the
        // companion's own members resolves to the in-progress
        // instance instead of failing forwarding. This mirrors JVM
        // `<clinit>` semantics, where the (companion) class is loaded
        // and self-referenceable while its static initialiser runs —
        // e.g. upstream `kotlin.time.Duration.Companion`'s `INFINITE`
        // / `NEG_INFINITE` / `INVALID` go through top-level
        // `durationOf*` helpers that call `Duration.fromRawValue`.
        if class_def.is_object {
            self.globals
                .borrow_mut()
                .define(&class_def.name, inst_value.clone());
        }
        // Evaluate class-delegation expressions (`: I by g`) and
        // store the resulting delegate values on the instance
        // under `__delegate__<superName>` so call_member can
        // forward unmatched methods.
        let class_delegate_thunks = self
            .prog
            .class_delegates
            .get(&class_def.name)
            .cloned()
            .unwrap_or_default();
        for (sup_name, fid) in &class_delegate_thunks {
            if let Some(func) = self.module.funcs.get(fid.0 as usize).cloned() {
                let module = Arc::clone(&self.module);
                let v = klio_ir::eval::eval_with(&module, &func, args.to_vec(), self)?;
                inst.borrow_mut()
                    .fields
                    .push((format!("__delegate__{sup_name}"), v));
            }
        }
        if let Some(m) = throwable_message.clone() {
            inst.borrow_mut().fields.push(("message".to_string(), m));
        }
        if let Some(c) = throwable_cause.clone() {
            inst.borrow_mut().fields.push(("cause".to_string(), c));
        }
        // Body properties: walk each class in the parent chain so a
        // subclass instance also picks up the parent's `var/val`
        // body properties. Each init thunk runs with
        // `[this, that-class's-own-ctor-args...]` — a parent's
        // initializer references the parent's primary-ctor params,
        // which are the super-constructor call's evaluated arguments,
        // not the leaf subclass's args (the two differ whenever the
        // subclass adds or reorders params).
        let chain_args_by_class: std::collections::HashMap<String, Vec<klio_runtime::Value>> =
            chain.iter().cloned().collect();
        let mut chain_classes: Vec<Arc<klio_runtime::ClassDef>> = Vec::new();
        {
            let mut cur = Some(Arc::clone(&class_def));
            while let Some(c) = cur.take() {
                chain_classes.push(Arc::clone(&c));
                cur.clone_from(&c.parent.borrow());
            }
        }
        // Bottom-up so parent fields exist before child fields can
        // override the same name. Within each class, init blocks
        // interleave with body-property initializers in declaration
        // order (Kotlin's source-order rule).
        for cls in chain_classes.iter().rev() {
            for (prop_idx, p) in cls.body_properties.iter().enumerate() {
                // Run any init blocks declared before this property.
                self.run_init_blocks_at(cls, prop_idx, &inst_value, &chain_args_by_class, args)?;
                if let Some(fid) = self
                    .prog
                    .body_prop_inits
                    .get(&(cls.name.clone(), p.name.clone()))
                    .copied()
                {
                    let func = self
                        .module
                        .funcs
                        .get(fid.0 as usize)
                        .cloned()
                        .ok_or_else(|| {
                            klio_ir::eval::EvalError::Type(format!(
                                "body prop init FuncId {} out of range",
                                fid.0
                            ))
                        })?;
                    let module = Arc::clone(&self.module);
                    let cls_args: &[klio_runtime::Value] = chain_args_by_class
                        .get(&cls.name)
                        .map_or(args, |v| v.as_slice());
                    let mut all: Vec<klio_runtime::Value> = Vec::with_capacity(1 + cls_args.len());
                    all.push(inst_value.clone());
                    all.extend_from_slice(cls_args);
                    let mut v = klio_ir::eval::eval_with(&module, &func, all, self)?;
                    if self
                        .module
                        .registry
                        .delegated_body_props
                        .contains(&(cls.name.clone(), p.name.clone()))
                        && let klio_runtime::Value::Instance(ref dinst) = v
                    {
                        let dcls_name = dinst.borrow().class.name.clone();
                        let has_provide = self
                            .module
                            .classes
                            .iter()
                            .find(|c| c.name == dcls_name)
                            .is_some_and(|c| {
                                c.methods.iter().any(|fid| {
                                    self.module
                                        .funcs
                                        .get(fid.0 as usize)
                                        .is_some_and(|f| f.name == "provideDelegate")
                                })
                            });
                        if has_provide {
                            let prop_ref = klio_runtime::Value::PropertyRef {
                                name: Arc::new(p.name.clone()),
                            };
                            if let Ok(rep) = <Self as klio_ir::eval::Host>::call_member(
                                self,
                                &v,
                                "provideDelegate",
                                &[inst_value.clone(), prop_ref],
                            ) {
                                v = rep;
                            }
                        }
                    }
                    inst.borrow_mut().define(&p.name, v);
                } else if let Some(init_expr) = p.init.as_ref() {
                    // Runtime-registered class (no lowered thunk):
                    // evaluate the property's init via simple_literal
                    // (covers literal-only inits used in local class
                    // declarations).
                    let v = simple_literal(init_expr).unwrap_or(klio_runtime::Value::Null);
                    inst.borrow_mut().define(&p.name, v);
                } else if p.getter.is_none() && p.delegate.is_none() {
                    // Only seed a null slot when the field doesn't
                    // already exist — child override inits from a
                    // bottom-up walk have already populated the slot.
                    if inst.borrow().get(&p.name).is_none() {
                        inst.borrow_mut()
                            .fields
                            .push((p.name.clone(), klio_runtime::Value::Null));
                    }
                }
            }
            // After all body-property initializers, run any trailing
            // init blocks (those declared after the last property).
            self.run_init_blocks_at(
                cls,
                cls.body_properties.len(),
                &inst_value,
                &chain_args_by_class,
                args,
            )?;
        }
        Ok(inst_value)
    }
}
