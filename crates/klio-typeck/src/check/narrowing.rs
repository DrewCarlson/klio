use super::*;

impl<'r> Checker<'r> {
    // ---- env helpers ----------------------------------------------------

    pub(crate) fn push_frame(&mut self) {
        self.frames.push(Frame::default());
    }

    pub(crate) fn pop_frame(&mut self) {
        self.frames.pop();
    }

    pub(crate) fn current_frame(&mut self) -> &mut Frame {
        self.frames.last_mut().expect("frame stack underflow")
    }

    pub(crate) fn lookup(&self, name: &str) -> Option<&Binding> {
        for f in self.frames.iter().rev() {
            if let Some(b) = f.bindings.get(name) {
                return Some(b);
            }
        }
        None
    }

    /// Narrowed type at the expression located at `query_span`.
    /// Routes through the CFG smart-cast analysis: every refinement
    /// kind the typechecker historically tracked on Frame.narrowings
    /// (is / null / cross-ref-eq / && / || / as / !! / bound aliases /
    /// stdlib contracts) is now emitted as an Assume node by the
    /// lowering and consumed here.
    pub(crate) fn lookup_narrowed_at(&self, name: &str, query_span: Span) -> Option<Type> {
        self.cfg_narrowed_at(name, query_span)
    }

    /// CFG-derived narrowed type for `name` at `query_span`. Walks
    /// the bound-smart-cast alias chain when the place itself has
    /// no recorded fact. Returns `None` if the CFG offers nothing
    /// more specific than the declared type.
    pub(crate) fn cfg_narrowed_at(&self, name: &str, query_span: Span) -> Option<Type> {
        use klio_cfa::analyses::smartcast::{self, Nullability};
        let fn_span = *self.cfg_fn_stack.last()?;
        let lowered = self.lowerings.get(&fn_span)?;
        let (bid, pos) = lowered
            .span_to_pos
            .get(&(query_span.start, query_span.end))
            .copied()?;
        let declared = self.cfg_declared_types();
        let entry = smartcast::solve_with_declared(
            &lowered.cfg,
            &lowered.reg_to_place,
            Some(&declared),
        )
        .into_iter()
        .nth(bid.0 as usize)?;
        let states = smartcast::states_within_block_with_declared(
            &lowered.cfg,
            bid,
            entry,
            &lowered.reg_to_place,
            Some(&declared),
        );
        let state = states.get(pos)?;
        let mut place = klio_cfa::Place::Local(klio_cfa::Symbol(name.to_string()));
        for _ in 0..8 {
            if let Some(fact) = state.map.get(&place) {
                if let Some(t) = fact.narrowed.clone() {
                    // For a user-class narrowing the underlying Type
                    // is `Unresolved`; the typechecker treats that as
                    // "permissive" and recovers the class via
                    // `cfg_narrowed_class_at`. Return it so callers
                    // get the same shape as the legacy frame path.
                    if matches!(fact.null, Nullability::NonNull) && !matches!(t, Type::Unresolved) {
                        return Some(t.non_null().clone());
                    }
                    return Some(t);
                }
                // No type-narrowing but the place is known non-null
                // (or definitely null). Project the declared type's
                // non-null form so the caller sees a usable Type.
                if matches!(fact.null, Nullability::NonNull) {
                    let bound = if let klio_cfa::Place::Local(sym) = &place {
                        self.lookup(&sym.0).map(|b| b.ty.clone())
                    } else {
                        None
                    };
                    if let Some(declared) = bound {
                        if declared.is_nullable() {
                            return Some(declared.non_null().clone());
                        }
                    }
                }
            }
            if let klio_cfa::Place::Local(sym) = &place {
                if let Some(next) = lowered.aliases.get(sym) {
                    place = next.clone();
                    continue;
                }
            }
            break;
        }
        None
    }

    /// GADT-style refinement: when a smart-cast narrowing at
    /// `query_span` has refined a place from `Super<T>` to a
    /// subclass whose typed-supertype chain instantiates
    /// `Super<f(...)>`, derive the substitution that unifies `T`
    /// with the corresponding position in `f(...)`. Returns the
    /// per-type-parameter substitution accumulated over every
    /// in-scope place at this program point; empty when the CFG
    /// has no class narrowings or the declared types don't carry
    /// type parameters.
    pub(crate) fn cfg_gadt_subst_at(&self, query_span: Span) -> std::collections::HashMap<String, Type> {
        let mut subst = std::collections::HashMap::new();
        let Some(fn_span) = self.cfg_fn_stack.last().copied() else { return subst };
        let Some(lowered) = self.lowerings.get(&fn_span) else { return subst };
        let Some((bid, pos)) = lowered
            .span_to_pos
            .get(&(query_span.start, query_span.end))
            .copied()
        else { return subst };
        use klio_cfa::analyses::smartcast;
        let declared = self.cfg_declared_types();
        let entries = smartcast::solve_with_declared(
            &lowered.cfg,
            &lowered.reg_to_place,
            Some(&declared),
        );
        let Some(entry) = entries.into_iter().nth(bid.0 as usize) else {
            return subst;
        };
        let states = smartcast::states_within_block_with_declared(
            &lowered.cfg,
            bid,
            entry,
            &lowered.reg_to_place,
            Some(&declared),
        );
        let Some(state) = states.get(pos) else { return subst };
        for (place, fact) in &state.map {
            let Some(narrowed_class) = &fact.narrowed_class else { continue };
            let klio_cfa::Place::Local(sym) = place else { continue };
            let Some(binding) = self.lookup(&sym.0) else { continue };
            let Type::Generic { name: declared_head, args: declared_args } =
                &binding.ty.non_null()
            else {
                continue;
            };
            let Some(supertype_args) =
                self.walk_supertype_args(narrowed_class, declared_head)
            else {
                continue;
            };
            for (declared_arg, super_arg) in declared_args.iter().zip(supertype_args.iter()) {
                if declared_arg.is_star {
                    continue;
                }
                if let Type::TypeParam(tp_name) = &declared_arg.ty {
                    if !matches!(super_arg, Type::TypeParam(_) | Type::Unresolved) {
                        subst.entry(tp_name.clone()).or_insert_with(|| super_arg.clone());
                    }
                }
            }
        }
        subst
    }

    /// Build a synthetic `Block` representing the primary-
    /// constructor init flow: every declared property becomes a
    /// `Stmt::Decl(Decl::Property(_))` in source order, and every
    /// init block contributes its statements at the position it
    /// appears in `c.members`. Lowering this block produces a CFG
    /// whose exit state's VIA tells us which uninitialized
    /// properties were definitely assigned along every primary-
    /// ctor path.
    pub(crate) fn synthesize_class_init_body(&self, c: &Class) -> Block {
        let mut stmts: Vec<Stmt> = Vec::new();
        // Primary-param properties are pre-assigned by their
        // matching ctor argument; emit a declared-and-assigned
        // shadow as a degenerate `val name = name` so VIA seeds
        // them as Assigned at the synthetic entry.
        for p in &c.primary_params {
            if p.property.is_some() {
                let shadow = Property {
                    mutable: p.property == Some(true),
                    name: p.name.clone(),
                    receiver_type: None,
                    ty: Some(p.ty.clone()),
                    init: Some(Expr::Path {
                        segments: vec![p.name.clone()],
                        span: p.name.span,
                    }),
                    delegate: None,
                    getter: None,
                    setter: None,
                    is_abstract: false,
                    is_open: false,
                    is_override: false,
                    is_lateinit: false,
                    is_const: false,
                    is_inline: false,
                    is_expect: false,
                    is_actual: false,
                    setter_visibility: None,
                    span: p.name.span,
                    visibility: p.visibility,
                    annotations: Vec::new(),
                };
                stmts.push(Stmt::Decl(Decl::Property(shadow)));
            }
        }
        // Walk members in source order so property initializers
        // interleave with init blocks correctly.
        let mut init_block_iter = c.init_blocks.iter();
        for m in &c.members {
            if let Decl::Property(p) = m {
                if p.getter.is_some() || p.delegate.is_some() {
                    continue;
                }
                stmts.push(Stmt::Decl(Decl::Property(p.clone())));
            }
        }
        for ib in init_block_iter.by_ref() {
            for s in &ib.stmts {
                stmts.push(s.clone());
            }
        }
        Block { stmts, span: c.name.span }
    }

    /// VIA classification of `name` at the *exit* of the CFG whose
    /// owning span matches `cfg_span`. Used by the class
    /// post-init walker to ask "did every primary-ctor path
    /// assign this property?" against the synthetic class-init
    /// CFG built by `check_class`.
    pub(crate) fn cfg_via_unassigned_at_exit(&self, cfg_span: Span, name: &str) -> Option<bool> {
        use klio_cfa::analyses::via::{self, AssignState};
        use klio_cfa::dataflow::Flat;
        let lowered = self.lowerings.get(&cfg_span)?;
        let states = via::solve_via(&lowered.cfg);
        let exit = *lowered.cfg.exits.first()?;
        let state = states.get(exit.0 as usize)?;
        let place = klio_cfa::Place::Local(klio_cfa::Symbol(name.to_string()));
        match state.get(&place) {
            Flat::Bottom => None,
            Flat::Value(AssignState::Assigned) => Some(false),
            Flat::Value(AssignState::Unassigned) | Flat::Top => Some(true),
        }
    }

    /// Returns true when the CFG's VIA analysis classifies `name`
    /// as "may not be assigned" at the program point of
    /// `query_span`. Drives the T0020 definite-assignment check
    /// alongside the legacy `assigned` set; once the CFG matches
    /// the legacy behaviour everywhere, the set drops out.
    pub(crate) fn cfg_via_unassigned_at(&self, name: &str, query_span: Span) -> Option<bool> {
        use klio_cfa::analyses::via::{self, AssignState};
        use klio_cfa::dataflow::Flat;
        let fn_span = *self.cfg_fn_stack.last()?;
        let lowered = self.lowerings.get(&fn_span)?;
        let (bid, pos) = lowered
            .span_to_pos
            .get(&(query_span.start, query_span.end))
            .copied()?;
        let entry = via::solve_via(&lowered.cfg)
            .into_iter()
            .nth(bid.0 as usize)?;
        let states = via::states_within_block(&lowered.cfg, bid, entry);
        let state = states.get(pos)?;
        let place = klio_cfa::Place::Local(klio_cfa::Symbol(name.to_string()));
        // `Flat::Bottom` means the place has no VIA fact at this
        // program point — typically a parameter (assigned at
        // function entry, never `DeclLocal`-ed) or a name the
        // typechecker tracks outside the CFG. Return `None` so
        // callers fall back to other signals; only return a
        // verdict when the CFG genuinely tracks the place.
        match state.get(&place) {
            Flat::Bottom => None,
            Flat::Value(AssignState::Assigned) => Some(false),
            Flat::Value(AssignState::Unassigned) | Flat::Top => Some(true),
        }
    }

    /// Returns true when the CFG's reachability analysis classifies
    /// the block containing `query_span` as unreachable. Drives the
    /// W0002 unreachable-code warning. The typechecker's `types` map
    /// is threaded through so `Nothing`-returning expressions
    /// (`error(...)`, `TODO()`) prune their block's successors the
    /// same way an explicit `return` / `throw` would.
    pub(crate) fn cfg_is_unreachable_at(&self, query_span: Span) -> Option<bool> {
        let fn_span = *self.cfg_fn_stack.last()?;
        let lowered = self.lowerings.get(&fn_span)?;
        let (bid, _) = lowered
            .span_to_pos
            .get(&(query_span.start, query_span.end))
            .copied()?;
        let type_map: std::collections::HashMap<(u32, u32), Type> = self
            .types
            .iter()
            .map(|(s, t)| ((s.start, s.end), t.clone()))
            .collect();
        let r = klio_cfa::analyses::reachable::analyse_with_types(
            &lowered.cfg,
            Some(&type_map),
        );
        Some(!r.is_reachable(bid))
    }

    /// Per-place declared-type map drawn from every binding visible
    /// in the active frames. Fed into the smart-cast pass so
    /// `AssumeRefEq` can narrow each side to the other's declared
    /// type when no prior fact applies.
    pub(crate) fn cfg_declared_types(&self) -> std::collections::HashMap<klio_cfa::Place, Type> {
        let mut out = std::collections::HashMap::new();
        for frame in &self.frames {
            for (name, binding) in &frame.bindings {
                out.insert(
                    klio_cfa::Place::Local(klio_cfa::Symbol(name.clone())),
                    binding.ty.clone(),
                );
            }
        }
        out
    }

    /// CFG-derived class-name narrowing for `name` at `query_span`.
    /// Parallels `cfg_narrowed_at` for the user-class branch.
    pub(crate) fn cfg_narrowed_class_at(&self, name: &str, query_span: Span) -> Option<String> {
        let fn_span = *self.cfg_fn_stack.last()?;
        let lowered = self.lowerings.get(&fn_span)?;
        let (bid, pos) = lowered
            .span_to_pos
            .get(&(query_span.start, query_span.end))
            .copied()?;
        use klio_cfa::analyses::smartcast;
        let declared = self.cfg_declared_types();
        let entry = smartcast::solve_with_declared(
            &lowered.cfg,
            &lowered.reg_to_place,
            Some(&declared),
        )
        .into_iter()
        .nth(bid.0 as usize)?;
        let states = smartcast::states_within_block_with_declared(
            &lowered.cfg,
            bid,
            entry,
            &lowered.reg_to_place,
            Some(&declared),
        );
        let state = states.get(pos)?;
        let mut place = klio_cfa::Place::Local(klio_cfa::Symbol(name.to_string()));
        for _ in 0..8 {
            if let Some(fact) = state.map.get(&place) {
                if let Some(cn) = fact.narrowed_class.clone() {
                    return Some(cn);
                }
            }
            if let klio_cfa::Place::Local(sym) = &place {
                if let Some(next) = lowered.aliases.get(sym) {
                    place = next.clone();
                    continue;
                }
            }
            break;
        }
        None
    }

    #[allow(dead_code)]
    pub(crate) fn resolution(&self) -> &Resolution {
        self.resolution
    }

    // ---- sealed-`when` exhaustiveness ----------------------------------

    /// True iff `candidate` is the same class as `target` or a transitive
    /// subclass through the local class table.
    pub(crate) fn is_class_or_subclass(&self, candidate: &str, target: &str) -> bool {
        if candidate == target {
            return true;
        }
        self.is_subtype_of(candidate, target)
    }

    /// All concrete (non-abstract, non-interface, non-sealed) classes whose
    /// transitive supertype chain contains `root`. Used as the leaf set the
    /// branches must cover.
    pub(crate) fn sealed_leaf_subclasses(&self, root: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for (name, info) in &self.classes {
            if name == root {
                continue;
            }
            if info.is_interface {
                continue;
            }
            if !self.is_subtype_of(name, root) {
                continue;
            }
            // Treat sealed/abstract intermediates as non-leaves — their
            // concrete descendants are listed separately.
            if info.is_sealed || info.is_abstract {
                continue;
            }
            out.push(name.clone());
        }
        out.sort();
        out
    }

    pub(crate) fn check_when_exhaustive(
        &mut self,
        subject_class: &str,
        branches: &[WhenBranch],
        when_span: Span,
    ) {
        let Some(root_info) = self.classes.get(subject_class) else { return };
        if !root_info.is_sealed {
            return;
        }
        // Else branch trivially covers everything.
        for b in branches {
            for p in &b.patterns {
                if matches!(p.kind, WhenPatternKind::Else) {
                    return;
                }
            }
        }
        let leaves = self.sealed_leaf_subclasses(subject_class);
        if leaves.is_empty() {
            return;
        }
        let mut missing: Vec<String> = Vec::new();
        for leaf in &leaves {
            let mut covered = false;
            'b: for br in branches {
                for p in &br.patterns {
                    match &p.kind {
                        WhenPatternKind::IsType(t) => {
                            if self.is_class_or_subclass(leaf, &t.name.name) {
                                covered = true;
                                break 'b;
                            }
                        }
                        _ => {}
                    }
                }
            }
            if !covered {
                missing.push(leaf.clone());
            }
        }
        if !missing.is_empty() {
            let list = missing.join(", ");
            self.diagnostics.emit(
                Diagnostic::error(
                    format!(
                        "'when' expression must be exhaustive, add necessary 'is {}' branches or 'else' branch.",
                        if missing.len() == 1 { missing[0].clone() } else { list.clone() }
                    ),
                    when_span,
                )
                .with_code(codes::TYPE_WHEN_NOT_EXHAUSTIVE),
            );
        }
    }
}
