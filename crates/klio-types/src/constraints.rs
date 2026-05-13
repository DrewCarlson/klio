//! Kotlin type-constraint system per spec §13.
//!
//! Implements the foundations: inference variables, per-variable bound
//! sets with the implicit `Nothing <: α <: Any?` bounds, a constraint
//! pool, and reduction + incorporation passes that drive toward a
//! fixpoint. The solver picks a substitution per inference variable
//! using the pull-up / push-down preference and the spec's GLB/LUB
//! routing.
//!
//! Designed to be consumed by the type checker at call sites for
//! type-argument inference, by branch joins for LUB, and by smart-cast
//! composition for GLB (intersection).

use std::collections::{BTreeMap, HashMap, HashSet};

use klio_span::Span;

use crate::{Type, Variance};

/// Fresh inference variable identity. Distinct from `Type::TypeParam`
/// (which models fixed type variables — the body of a generic
/// declaration where the parameter is unknown but immutable).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct InferenceVar(pub u32);

/// Pull-up (largest, LUB of lower bounds) or push-down (smallest, GLB of
/// upper bounds) preference attached to an inference variable. Spec
/// §13.2.2. Variables default to pull-up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SolutionPreference {
    PullUp,
    PushDown,
}

impl Default for SolutionPreference {
    fn default() -> Self {
        Self::PullUp
    }
}

/// Per-variable bound set. The implicit `Nothing <: α <: Any?` bounds
/// are pre-installed; callers may freely add tighter bounds.
#[derive(Debug, Clone, Default)]
pub struct BoundSet {
    pub lower: Vec<Type>,
    pub upper: Vec<Type>,
    pub preference: SolutionPreference,
}

impl BoundSet {
    /// Fresh bound set seeded with the spec's implicit `Nothing <: α`
    /// and `α <: Any?` bounds.
    #[must_use]
    pub fn new() -> Self {
        Self {
            lower: vec![Type::Nothing],
            upper: vec![Type::Nullable(Box::new(Type::Any))],
            preference: SolutionPreference::PullUp,
        }
    }

    pub fn add_lower(&mut self, t: Type) -> bool {
        if self.lower.contains(&t) {
            return false;
        }
        self.lower.push(t);
        true
    }

    pub fn add_upper(&mut self, t: Type) -> bool {
        if self.upper.contains(&t) {
            return false;
        }
        self.upper.push(t);
        true
    }
}

/// Kind of constraint. `Equality` is symmetric and reduces to two
/// subtype constraints (`S <: T` and `T <: S`) plus a union-find
/// merge of any inference vars involved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConstraintKind {
    Subtype,
    Equality,
}

/// Where a constraint came from, so failure diagnostics can point at
/// the responsible source expression instead of a synthesised
/// description. Phase 6 wires renderers to consume this; Phase 1
/// just carries the data alongside every constraint.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Provenance {
    /// Argument at position `arg_idx` of a call at `span` is bound to
    /// a parameter of the inferred function signature.
    CallSite { span: Span, arg_idx: usize },
    /// The return type of a call at `span` flows into the surrounding
    /// expected type.
    Return { span: Span },
    /// The body of a lambda at `span` flows into its expected return.
    LambdaBody { span: Span },
    /// A smart-cast intersection at a CFG join feeds back into the
    /// inference session as a refined bound on an inference variable.
    SmartCast { span: Span },
    /// A bound carried by a declaration-site type parameter.
    Bound { name: String },
    /// LUB join over `if` / `when` / `try` branches.
    LubJoin { span: Span },
    /// Internal derivation by the solver itself (incorporation,
    /// equality propagation, supertype walk). Carries the kind of
    /// derivation so diagnostics can still explain it.
    Derived(&'static str),
}

/// Constraint over types that may contain inference variables. An
/// inference variable is encoded as `Type::TypeParam(name)` where
/// `name` is the textual id assigned by [`ConstraintSystem::fresh`].
#[derive(Debug, Clone)]
pub struct Constraint {
    pub lhs: Type,
    pub rhs: Type,
    pub kind: ConstraintKind,
    pub provenance: Provenance,
}

/// Failure modes the reducer can hit. Surface these through diagnostics
/// T0097–T0099 at the call site.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InferenceError {
    /// Two resolved (non-inference-variable) types are unrelated and the
    /// constraint cannot be satisfied.
    UnsatisfiableConcrete { lhs: Type, rhs: Type },
    /// A nullable lhs flows into a known non-nullable rhs.
    NullableIntoNonNullable { lhs: Type, rhs: Type },
    /// A generic-class supertype required by rhs was not found on lhs.
    MissingSupertype { lhs: Type, rhs_head: String },
    /// Bounds on the same variable form a contradiction.
    ContradictoryBounds(InferenceVar),
}

/// Solver workspace: holds the set of inference variables, their bounds,
/// and the pending constraint pool.
#[derive(Debug, Default)]
pub struct ConstraintSystem {
    pub bounds: HashMap<InferenceVar, BoundSet>,
    /// Stable id-to-name lookup for the textual encoding inside
    /// `Type::TypeParam`.
    var_names: HashMap<String, InferenceVar>,
    next_id: u32,
    pending: Vec<Constraint>,
    /// Constraints already reduced. Prevents the incorporation phase
    /// from re-emitting an `S <: T` that has been processed.
    seen: HashSet<(String, String, ConstraintKind)>,
    /// Equality classes over inference variables. When `α ≡ β` is
    /// derived (either explicitly or by `S <: α ∧ α <: S` for the
    /// same `S`), we collapse them so subsequent constraints share
    /// a single bound set. Phase 2 will rewrite pending constraints
    /// through this map.
    equiv: BTreeMap<InferenceVar, InferenceVar>,
    /// Last `InferenceError` recorded with the failing provenance
    /// attached. The solver continues processing the pool to surface
    /// any additional errors; the caller reads this after solve.
    last_error: Option<(InferenceError, Provenance)>,
}

impl ConstraintSystem {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Allocates a fresh inference variable. The returned `Type` is the
    /// canonical textual encoding used inside constraints.
    pub fn fresh(&mut self, hint: &str) -> (InferenceVar, Type) {
        let id = InferenceVar(self.next_id);
        self.next_id += 1;
        let name = format!("?{hint}{}", id.0);
        self.var_names.insert(name.clone(), id);
        self.bounds.insert(id, BoundSet::new());
        (id, Type::TypeParam(name))
    }

    pub fn set_preference(&mut self, v: InferenceVar, p: SolutionPreference) {
        if let Some(b) = self.bounds.get_mut(&v) {
            b.preference = p;
        }
    }

    /// `true` if `t` is the canonical encoding of an inference variable.
    #[must_use]
    pub fn is_inference_var(&self, t: &Type) -> Option<InferenceVar> {
        if let Type::TypeParam(name) = t {
            self.var_names.get(name).copied()
        } else {
            None
        }
    }

    /// Subtype constraint without provenance. Convenience entry
    /// point preserved for callers that don't yet have a source span
    /// to attribute the failure to.
    pub fn add_constraint(&mut self, lhs: Type, rhs: Type) {
        self.add_constraint_with(lhs, rhs, ConstraintKind::Subtype, Provenance::Derived("legacy"));
    }

    /// Equality constraint. Records `S ≡ T` and reduces to `S <: T`
    /// and `T <: S` in the pending pool; if both sides are inference
    /// vars, also merges their equivalence classes.
    pub fn add_equality(&mut self, lhs: Type, rhs: Type, provenance: Provenance) {
        if let (Some(a), Some(b)) = (self.is_inference_var(&lhs), self.is_inference_var(&rhs)) {
            self.union_vars(a, b);
        }
        self.add_constraint_with(
            lhs.clone(),
            rhs.clone(),
            ConstraintKind::Equality,
            provenance.clone(),
        );
        self.add_constraint_with(rhs, lhs, ConstraintKind::Subtype, provenance);
    }

    /// Subtype constraint with provenance. Use this from the
    /// typechecker; the carried provenance feeds back into failure
    /// diagnostics.
    pub fn add_constraint_with(
        &mut self,
        lhs: Type,
        rhs: Type,
        kind: ConstraintKind,
        provenance: Provenance,
    ) {
        let key = (lhs.to_string(), rhs.to_string(), kind);
        if self.seen.contains(&key) {
            return;
        }
        self.pending.push(Constraint { lhs, rhs, kind, provenance });
    }

    fn union_vars(&mut self, a: InferenceVar, b: InferenceVar) {
        let ra = self.find_root(a);
        let rb = self.find_root(b);
        if ra == rb {
            return;
        }
        // Point the higher-id var at the lower-id one; stable choice.
        let (keep, drop) = if ra.0 <= rb.0 { (ra, rb) } else { (rb, ra) };
        self.equiv.insert(drop, keep);
        // Merge bound sets: drop's bounds become keep's bounds.
        if let Some(dropped) = self.bounds.remove(&drop) {
            let target = self.bounds.entry(keep).or_insert_with(BoundSet::new);
            for t in dropped.lower {
                if !target.lower.contains(&t) {
                    target.lower.push(t);
                }
            }
            for t in dropped.upper {
                if !target.upper.contains(&t) {
                    target.upper.push(t);
                }
            }
            if matches!(dropped.preference, SolutionPreference::PushDown) {
                target.preference = SolutionPreference::PushDown;
            }
        }
    }

    fn find_root(&self, v: InferenceVar) -> InferenceVar {
        let mut cur = v;
        while let Some(parent) = self.equiv.get(&cur) {
            cur = *parent;
        }
        cur
    }

    /// Returns the canonical representative of an inference variable's
    /// equivalence class. After Phase 2 lands, callers use this to
    /// rewrite bounds through the union-find before consulting them.
    pub fn canonical(&self, v: InferenceVar) -> InferenceVar {
        self.find_root(v)
    }

    /// The last unsatisfied constraint together with its provenance,
    /// for diagnostics. Resets when the caller clears it.
    pub fn last_error(&self) -> Option<&(InferenceError, Provenance)> {
        self.last_error.as_ref()
    }

    /// Drains the pending pool, applying spec §13.2.1 reduction rules.
    /// Returns the first inference error encountered, if any. New bounds
    /// can drive incorporation; callers loop reduce / incorporate to a
    /// fixpoint via [`Self::solve_to_fixpoint`].
    pub fn reduce(&mut self) -> Result<(), InferenceError> {
        while let Some(c) = self.pending.pop() {
            let key = (c.lhs.to_string(), c.rhs.to_string(), c.kind);
            if !self.seen.insert(key) {
                continue;
            }
            self.reduce_one(c.lhs, c.rhs, c.kind, c.provenance)?;
        }
        Ok(())
    }

    fn reduce_one(
        &mut self,
        lhs: Type,
        rhs: Type,
        kind: ConstraintKind,
        provenance: Provenance,
    ) -> Result<(), InferenceError> {
        // Inference variable on either side -> add a bound.
        if let Some(v) = self.is_inference_var(&lhs) {
            let v = self.find_root(v);
            self.bounds.entry(v).or_insert_with(BoundSet::new).add_upper(rhs.clone());
            if matches!(kind, ConstraintKind::Equality) {
                self.bounds.get_mut(&v).unwrap().add_lower(rhs);
            }
            return Ok(());
        }
        if let Some(v) = self.is_inference_var(&rhs) {
            let v = self.find_root(v);
            self.bounds.entry(v).or_insert_with(BoundSet::new).add_lower(lhs.clone());
            if matches!(kind, ConstraintKind::Equality) {
                self.bounds.get_mut(&v).unwrap().add_upper(lhs);
            }
            return Ok(());
        }
        // Resolved on both sides.
        let result: Result<(), InferenceError> = match (&lhs, &rhs) {
            // Spec §13.2.1: `S? <: T?` reduces to `S!! <: T` AND `S <: T`.
            // The non-null projection check ensures the underlying
            // types are compatible; the second arm carries the
            // nullability-compatible case.
            (Type::Nullable(a), Type::Nullable(b)) => {
                self.add_constraint_with(
                    (**a).clone(),
                    (**b).clone(),
                    kind,
                    provenance.clone(),
                );
                self.add_constraint_with(
                    a.non_null().clone(),
                    (**b).clone(),
                    kind,
                    provenance.clone(),
                );
                Ok(())
            }
            // Nullable lhs into a non-nullable resolved rhs is a hard
            // fail.
            (Type::Nullable(_), _) if !rhs.is_nullable() => {
                Err(InferenceError::NullableIntoNonNullable { lhs: lhs.clone(), rhs: rhs.clone() })
            }
            // Intersection on the right: reduce per-component.
            (_, Type::Intersection(parts)) => {
                for p in parts.clone() {
                    self.add_constraint_with(lhs.clone(), p, kind, provenance.clone());
                }
                Ok(())
            }
            // Intersection on the left: at least one component must
            // satisfy. We approximate by accepting if any does at the
            // current resolved state.
            (Type::Intersection(parts), _) => {
                if parts.iter().any(|p| p.is_subtype_of(&rhs)) {
                    Ok(())
                } else {
                    Err(InferenceError::UnsatisfiableConcrete { lhs: lhs.clone(), rhs: rhs.clone() })
                }
            }
            // Parameterised generic on both sides with the same head:
            // reduce per-argument with variance-aware containment
            // (spec §13.2.1, the `Q ⪯ F` table).
            (
                Type::Generic { name: an, args: aa },
                Type::Generic { name: bn, args: ba },
            ) if an == bn && aa.len() == ba.len() => {
                for (l, r) in aa.iter().zip(ba.iter()) {
                    if l.is_star || r.is_star {
                        continue;
                    }
                    let var = match (l.variance, r.variance) {
                        (Variance::Out, _) | (_, Variance::Out) => Variance::Out,
                        (Variance::In, _) | (_, Variance::In) => Variance::In,
                        _ => Variance::Invariant,
                    };
                    match var {
                        Variance::Out => {
                            self.add_constraint_with(
                                l.ty.clone(),
                                r.ty.clone(),
                                ConstraintKind::Subtype,
                                provenance.clone(),
                            );
                        }
                        Variance::In => {
                            self.add_constraint_with(
                                r.ty.clone(),
                                l.ty.clone(),
                                ConstraintKind::Subtype,
                                provenance.clone(),
                            );
                        }
                        Variance::Invariant => {
                            // Both directions — i.e. equality on the
                            // type argument.
                            self.add_equality(
                                l.ty.clone(),
                                r.ty.clone(),
                                provenance.clone(),
                            );
                        }
                    }
                }
                Ok(())
            }
            // Pure subtype check between resolved types.
            (a, b) => {
                if a.is_subtype_of(b) {
                    Ok(())
                } else {
                    Err(InferenceError::UnsatisfiableConcrete {
                        lhs: a.clone(),
                        rhs: b.clone(),
                    })
                }
            }
        };
        if let Err(e) = &result {
            self.last_error = Some((e.clone(), provenance));
        }
        result
    }

    /// Per spec §13.2.1: for every variable α with `S <: α` and
    /// `α <: T`, derive `S <: T`. Also derives equalities:
    ///
    /// 1. When the same concrete `S` appears as both an upper and a
    ///    lower bound of α (i.e. `S <: α ∧ α <: S`), record `α ≡ S`.
    /// 2. When two upper bounds on α share a parameterised head
    ///    (e.g. `α <: List<X>` and `α <: List<Int>`), pairwise-
    ///    invariant arguments yield equality constraints
    ///    (`X ≡ Int`). Same for two lower bounds. This is the rule
    ///    that infers a type-parameter from multiple call-site
    ///    requirements without needing supertype lookup.
    /// 3. Cycles `α <: β <: α` collapse both vars through union-find.
    ///
    /// Repeats until no fresh constraints / bounds are produced.
    pub fn incorporate(&mut self) -> Result<(), InferenceError> {
        let mut iterations = 0u32;
        loop {
            iterations += 1;
            if iterations > 1024 {
                // Defensive cap. Reduction never invents fresh class
                // symbols, so termination is guaranteed in theory;
                // the cap catches buggy provenance cycles in practice.
                return Ok(());
            }
            let mut new_constraints: Vec<(Type, Type, ConstraintKind, Provenance)> = Vec::new();

            // (1) Classic transitive closure: S <: α ∧ α <: T ⇒ S <: T.
            //     Also: derive equality when the same concrete type
            //     appears as both bounds.
            for (v, bs) in &self.bounds {
                for s in &bs.lower {
                    for t in &bs.upper {
                        new_constraints.push((
                            s.clone(),
                            t.clone(),
                            ConstraintKind::Subtype,
                            Provenance::Derived("incorporate"),
                        ));
                    }
                }
                // (1a) Equality from same-type bound on both sides.
                for s in &bs.lower {
                    if !is_inference_var_type(s) && bs.upper.iter().any(|t| t == s) {
                        new_constraints.push((
                            Type::TypeParam(self.encode(v)),
                            s.clone(),
                            ConstraintKind::Equality,
                            Provenance::Derived("equality-same-bound"),
                        ));
                    }
                }
            }

            // (2) Equality derivation from paired generic bounds.
            //     For each var, pairs of upper or lower bounds sharing
            //     a parameterised head emit per-arg constraints.
            let var_ids: Vec<InferenceVar> = self.bounds.keys().copied().collect();
            for v in &var_ids {
                let bs = self.bounds.get(v).unwrap().clone();
                self.paired_generic_args(&bs.upper, &mut new_constraints);
                self.paired_generic_args(&bs.lower, &mut new_constraints);
            }

            // (3) Cycle detection: α <: β AND β <: α (both vars).
            let cycles = self.collect_var_cycles();
            for (a, b) in cycles {
                self.union_vars(a, b);
            }

            let before_seen = self.seen.len();
            let before_pending = self.pending.len();
            for (s, t, kind, prov) in new_constraints {
                self.add_constraint_with(s, t, kind, prov);
            }
            if self.pending.is_empty() {
                break;
            }
            self.reduce()?;
            if self.pending.len() == before_pending && self.seen.len() == before_seen {
                break;
            }
        }
        Ok(())
    }

    fn encode(&self, v: &InferenceVar) -> String {
        for (name, id) in &self.var_names {
            if id == v {
                return name.clone();
            }
        }
        format!("?{}", v.0)
    }

    fn paired_generic_args(
        &self,
        bounds: &[Type],
        out: &mut Vec<(Type, Type, ConstraintKind, Provenance)>,
    ) {
        for i in 0..bounds.len() {
            for j in (i + 1)..bounds.len() {
                if let (
                    Type::Generic { name: an, args: aa },
                    Type::Generic { name: bn, args: ba },
                ) = (&bounds[i], &bounds[j])
                {
                    if an != bn || aa.len() != ba.len() {
                        continue;
                    }
                    for (l, r) in aa.iter().zip(ba.iter()) {
                        if l.is_star || r.is_star {
                            continue;
                        }
                        match (l.variance, r.variance) {
                            (Variance::Invariant, Variance::Invariant) => {
                                out.push((
                                    l.ty.clone(),
                                    r.ty.clone(),
                                    ConstraintKind::Equality,
                                    Provenance::Derived("incorporate-generic-equality"),
                                ));
                            }
                            (Variance::Out, Variance::Out) => {
                                // Both bounds are upper bounds with an
                                // out-variant arg; the most-specific
                                // common subtype lives below — leave
                                // the LUB to the solver fixation step.
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    fn collect_var_cycles(&self) -> Vec<(InferenceVar, InferenceVar)> {
        let mut out = Vec::new();
        for (av, bs_a) in &self.bounds {
            for t in &bs_a.upper {
                if let Some(bv) = self.is_inference_var(t) {
                    if let Some(bs_b) = self.bounds.get(&bv) {
                        if bs_b
                            .upper
                            .iter()
                            .any(|s| self.is_inference_var(s) == Some(*av))
                        {
                            out.push((*av, bv));
                        }
                    }
                }
            }
        }
        out
    }

    /// Loops reduce + incorporate to a fixpoint.
    pub fn solve_to_fixpoint(&mut self) -> Result<(), InferenceError> {
        loop {
            self.reduce()?;
            let before = self.seen.len();
            self.incorporate()?;
            if self.seen.len() == before && self.pending.is_empty() {
                break;
            }
        }
        Ok(())
    }

    /// Spec §13.2.2 staged fixation. Builds the dependency graph
    /// `α →dep β` (β occurs in α's bounds), computes SCCs, fixes the
    /// variables in reverse topological order, substituting the
    /// resolved type into every remaining bound before moving on.
    /// This is the entry point that matters once postponed variables
    /// land in Phase 4 — order-independent batches are fixed in
    /// parallel inside a stage, and an SCC of mutually-dependent
    /// vars is resolved together by repeated substitution until the
    /// fix points.
    pub fn solve_staged(&self) -> HashMap<InferenceVar, Type> {
        let vars: Vec<InferenceVar> = self.bounds.keys().copied().collect();
        let mut deps: HashMap<InferenceVar, Vec<InferenceVar>> = HashMap::new();
        for v in &vars {
            let mut targets: Vec<InferenceVar> = Vec::new();
            let bs = self.bounds.get(v).unwrap();
            for t in bs.lower.iter().chain(bs.upper.iter()) {
                collect_vars(t, &self.var_names, &mut targets);
            }
            targets.retain(|t| t != v);
            targets.sort();
            targets.dedup();
            deps.insert(*v, targets);
        }
        let sccs = tarjan_scc(&vars, &deps);
        let mut resolved: HashMap<InferenceVar, Type> = HashMap::new();
        for scc in sccs.iter().rev() {
            // Inside an SCC, iterate: fix each var assuming current
            // substitution of the others; repeat until no var's
            // resolved type changes.
            let mut changed = true;
            let mut local_iters = 0u32;
            while changed && local_iters < 64 {
                changed = false;
                for v in scc {
                    let pick = self.fix_var(*v, &resolved);
                    match resolved.get(v) {
                        Some(prev) if prev == &pick => {}
                        _ => {
                            resolved.insert(*v, pick);
                            changed = true;
                        }
                    }
                }
                local_iters += 1;
            }
        }
        resolved
    }

    fn fix_var(
        &self,
        v: InferenceVar,
        already_resolved: &HashMap<InferenceVar, Type>,
    ) -> Type {
        let bs = match self.bounds.get(&v) {
            Some(bs) => bs,
            None => return Type::Nothing,
        };
        let substitute = |t: &Type| -> Type {
            substitute_vars(t, already_resolved, &self.var_names)
        };
        match bs.preference {
            SolutionPreference::PushDown => {
                let uppers: Vec<Type> = bs
                    .upper
                    .iter()
                    .map(|t| substitute(t))
                    .filter(|t| !matches!(t, Type::Nullable(inner) if matches!(**inner, Type::Any)))
                    .filter(|t| self.is_inference_var(t).is_none())
                    .collect();
                if uppers.is_empty() {
                    Type::Nullable(Box::new(Type::Any))
                } else {
                    Type::intersect(uppers)
                }
            }
            SolutionPreference::PullUp => {
                let lowers: Vec<Type> = bs
                    .lower
                    .iter()
                    .map(|t| substitute(t))
                    .filter(|t| !matches!(t, Type::Nothing))
                    .filter(|t| self.is_inference_var(t).is_none())
                    .collect();
                if lowers.is_empty() {
                    Type::Nothing
                } else {
                    lub_many(&lowers)
                }
            }
        }
    }

    /// Picks a concrete substitution for every inference variable using
    /// the spec §13.2.2 rule: push-down → GLB of upper bounds (= their
    /// intersection); pull-up (and default) → LUB of lower bounds.
    pub fn solve(&self) -> HashMap<InferenceVar, Type> {
        let mut out = HashMap::new();
        for (v, bs) in &self.bounds {
            let candidate = match bs.preference {
                SolutionPreference::PushDown => {
                    let uppers: Vec<Type> = bs
                        .upper
                        .iter()
                        .filter(|t| !matches!(t, Type::Nullable(inner) if matches!(**inner, Type::Any)))
                        .cloned()
                        .collect();
                    if uppers.is_empty() {
                        Type::Nullable(Box::new(Type::Any))
                    } else {
                        Type::intersect(uppers)
                    }
                }
                SolutionPreference::PullUp => {
                    let lowers: Vec<Type> =
                        bs.lower.iter().filter(|t| !matches!(t, Type::Nothing)).cloned().collect();
                    if lowers.is_empty() {
                        Type::Nothing
                    } else {
                        lub_many(&lowers)
                    }
                }
            };
            out.insert(*v, candidate);
        }
        out
    }
}

/// LUB across a slice of resolved types. Conservative implementation:
/// returns the unique element when all entries are equal; otherwise
/// promotes to a common builtin via the spec's normalization rules, and
/// falls back to `Any` / `Any?` for unrelated class types. Lifted into
/// the constraint system via [`ConstraintSystem::solve`].
#[must_use]
pub fn lub_many(types: &[Type]) -> Type {
    if types.is_empty() {
        return Type::Nothing;
    }
    let any_nullable = types.iter().any(Type::is_nullable);
    let mut iter = types.iter().map(|t| t.non_null().clone());
    let first = iter.next().unwrap();
    let mut acc = first;
    for t in iter {
        acc = lub_pair(&acc, &t);
    }
    if any_nullable {
        acc.as_nullable()
    } else {
        acc
    }
}

fn is_inference_var_type(t: &Type) -> bool {
    matches!(t, Type::TypeParam(name) if name.starts_with('?'))
}

/// Collects all inference variables appearing inside `t`.
fn collect_vars(
    t: &Type,
    var_names: &HashMap<String, InferenceVar>,
    out: &mut Vec<InferenceVar>,
) {
    match t {
        Type::TypeParam(name) => {
            if let Some(id) = var_names.get(name) {
                out.push(*id);
            }
        }
        Type::Nullable(inner) => collect_vars(inner, var_names, out),
        Type::Range(inner) => collect_vars(inner, var_names, out),
        Type::Function { params, return_type, .. } => {
            for p in params {
                collect_vars(p, var_names, out);
            }
            collect_vars(return_type, var_names, out);
        }
        Type::Generic { args, .. } => {
            for a in args {
                if !a.is_star {
                    collect_vars(&a.ty, var_names, out);
                }
            }
        }
        Type::Intersection(parts) => {
            for p in parts {
                collect_vars(p, var_names, out);
            }
        }
        _ => {}
    }
}

/// Substitute resolved inference variables inside `t` with their
/// concrete types. Used during staged fixation when prior SCC's
/// variables have already been resolved.
fn substitute_vars(
    t: &Type,
    resolved: &HashMap<InferenceVar, Type>,
    var_names: &HashMap<String, InferenceVar>,
) -> Type {
    match t {
        Type::TypeParam(name) => match var_names.get(name).and_then(|id| resolved.get(id)) {
            Some(r) => r.clone(),
            None => t.clone(),
        },
        Type::Nullable(inner) => {
            Type::Nullable(Box::new(substitute_vars(inner, resolved, var_names)))
        }
        Type::Range(inner) => Type::Range(Box::new(substitute_vars(inner, resolved, var_names))),
        Type::Function { params, return_type, is_suspend } => Type::Function {
            params: params.iter().map(|p| substitute_vars(p, resolved, var_names)).collect(),
            return_type: Box::new(substitute_vars(return_type, resolved, var_names)),
            is_suspend: *is_suspend,
        },
        Type::Generic { name, args } => Type::Generic {
            name: name.clone(),
            args: args
                .iter()
                .map(|a| {
                    if a.is_star {
                        a.clone()
                    } else {
                        crate::GenericArg {
                            variance: a.variance,
                            is_star: false,
                            ty: substitute_vars(&a.ty, resolved, var_names),
                        }
                    }
                })
                .collect(),
        },
        Type::Intersection(parts) => Type::Intersection(
            parts.iter().map(|p| substitute_vars(p, resolved, var_names)).collect(),
        ),
        _ => t.clone(),
    }
}

/// Tarjan's SCC algorithm over inference variables. Returns the
/// SCCs in topological order (deepest dependencies first), so the
/// staged fixation can fix later batches once their dependencies
/// resolve.
fn tarjan_scc(
    vars: &[InferenceVar],
    deps: &HashMap<InferenceVar, Vec<InferenceVar>>,
) -> Vec<Vec<InferenceVar>> {
    let mut idx_of: HashMap<InferenceVar, usize> = HashMap::new();
    let mut lowlink: HashMap<InferenceVar, usize> = HashMap::new();
    let mut on_stack: HashMap<InferenceVar, bool> = HashMap::new();
    let mut stack: Vec<InferenceVar> = Vec::new();
    let mut counter = 0usize;
    let mut sccs: Vec<Vec<InferenceVar>> = Vec::new();

    fn strong_connect(
        v: InferenceVar,
        deps: &HashMap<InferenceVar, Vec<InferenceVar>>,
        idx_of: &mut HashMap<InferenceVar, usize>,
        lowlink: &mut HashMap<InferenceVar, usize>,
        on_stack: &mut HashMap<InferenceVar, bool>,
        stack: &mut Vec<InferenceVar>,
        counter: &mut usize,
        sccs: &mut Vec<Vec<InferenceVar>>,
    ) {
        idx_of.insert(v, *counter);
        lowlink.insert(v, *counter);
        *counter += 1;
        stack.push(v);
        on_stack.insert(v, true);
        if let Some(ns) = deps.get(&v) {
            for w in ns {
                if !idx_of.contains_key(w) {
                    strong_connect(*w, deps, idx_of, lowlink, on_stack, stack, counter, sccs);
                    let lw = *lowlink.get(w).unwrap();
                    let lv = *lowlink.get(&v).unwrap();
                    lowlink.insert(v, lv.min(lw));
                } else if *on_stack.get(w).unwrap_or(&false) {
                    let iw = *idx_of.get(w).unwrap();
                    let lv = *lowlink.get(&v).unwrap();
                    lowlink.insert(v, lv.min(iw));
                }
            }
        }
        if lowlink.get(&v) == idx_of.get(&v) {
            let mut scc: Vec<InferenceVar> = Vec::new();
            while let Some(w) = stack.pop() {
                on_stack.insert(w, false);
                scc.push(w);
                if w == v {
                    break;
                }
            }
            sccs.push(scc);
        }
    }

    for v in vars {
        if !idx_of.contains_key(v) {
            strong_connect(
                *v,
                deps,
                &mut idx_of,
                &mut lowlink,
                &mut on_stack,
                &mut stack,
                &mut counter,
                &mut sccs,
            );
        }
    }
    sccs
}

fn lub_pair(a: &Type, b: &Type) -> Type {
    if a == b {
        return a.clone();
    }
    if matches!(a, Type::Nothing) {
        return b.clone();
    }
    if matches!(b, Type::Nothing) {
        return a.clone();
    }
    if a.is_subtype_of(b) {
        return b.clone();
    }
    if b.is_subtype_of(a) {
        return a.clone();
    }
    Type::Any
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn implicit_bounds_seeded() {
        let bs = BoundSet::new();
        assert!(bs.lower.contains(&Type::Nothing));
        assert!(bs.upper.iter().any(|t| matches!(t, Type::Nullable(_))));
    }

    #[test]
    fn fresh_var_has_distinct_encoding() {
        let mut cs = ConstraintSystem::new();
        let (_, a) = cs.fresh("A");
        let (_, b) = cs.fresh("B");
        assert_ne!(a, b);
    }

    #[test]
    fn reduce_records_upper_bound_for_lhs_var() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(a, Type::Int);
        cs.reduce().unwrap();
        assert!(cs.bounds.get(&av).unwrap().upper.contains(&Type::Int));
    }

    #[test]
    fn reduce_records_lower_bound_for_rhs_var() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(Type::Int, a);
        cs.reduce().unwrap();
        assert!(cs.bounds.get(&av).unwrap().lower.contains(&Type::Int));
    }

    #[test]
    fn reduce_resolved_satisfied() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Int, Type::Any);
        cs.reduce().unwrap();
    }

    #[test]
    fn reduce_resolved_unsatisfied() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Int, Type::String);
        let err = cs.reduce().unwrap_err();
        assert!(matches!(err, InferenceError::UnsatisfiableConcrete { .. }));
    }

    #[test]
    fn reduce_nullable_into_nonnull_fails() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(Type::Nullable(Box::new(Type::Int)), Type::Int);
        assert!(cs.reduce().is_err());
    }

    #[test]
    fn reduce_intersection_rhs_fans_out() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint(
            Type::Int,
            Type::Intersection(vec![Type::Int, Type::Any]),
        );
        cs.reduce().unwrap();
    }

    #[test]
    fn solve_pullup_picks_lub_of_lowers() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_constraint(Type::Int, a.clone());
        cs.add_constraint(Type::Int, a);
        cs.reduce().unwrap();
        let sol = cs.solve();
        assert_eq!(sol.get(&av), Some(&Type::Int));
    }

    #[test]
    fn solve_pushdown_picks_glb_of_uppers() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.set_preference(av, SolutionPreference::PushDown);
        cs.add_constraint(a.clone(), Type::Int);
        cs.add_constraint(a, Type::Any);
        cs.reduce().unwrap();
        let sol = cs.solve();
        assert_eq!(sol.get(&av), Some(&Type::Int));
    }

    #[test]
    fn incorporate_propagates_transitive_constraint() {
        let mut cs = ConstraintSystem::new();
        let (_, a) = cs.fresh("A");
        // Int <: a, a <: Any  => Int <: Any (already true; just check no error).
        cs.add_constraint(Type::Int, a.clone());
        cs.add_constraint(a, Type::Any);
        cs.solve_to_fixpoint().unwrap();
    }

    #[test]
    fn lub_pair_promotes_to_any() {
        assert_eq!(lub_pair(&Type::Int, &Type::String), Type::Any);
    }

    #[test]
    fn lub_lifts_nullable() {
        let r = lub_many(&[Type::Int, Type::Nullable(Box::new(Type::Int))]);
        assert_eq!(r, Type::Nullable(Box::new(Type::Int)));
    }

    use crate::GenericArg;

    fn prov() -> Provenance {
        Provenance::Derived("test")
    }

    #[test]
    fn equality_records_both_bounds() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        cs.add_equality(a, Type::Int, prov());
        cs.reduce().unwrap();
        let bs = cs.bounds.get(&av).unwrap();
        assert!(bs.upper.contains(&Type::Int));
        assert!(bs.lower.contains(&Type::Int));
    }

    #[test]
    fn equality_unions_two_vars() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        let (bv, b) = cs.fresh("B");
        cs.add_equality(a, b, prov());
        // After equality, av and bv point to the same root.
        assert_eq!(cs.canonical(av), cs.canonical(bv));
    }

    #[test]
    fn nullable_subtype_emits_both_arms() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        // (Int? <: A?). The reduction should produce both `Int <: A`
        // and a non-null projection step.
        cs.add_constraint(
            Type::Nullable(Box::new(Type::Int)),
            Type::Nullable(Box::new(a)),
        );
        cs.reduce().unwrap();
        let bs = cs.bounds.get(&av).unwrap();
        assert!(
            bs.lower.iter().any(|t| matches!(t, Type::Int)),
            "expected Int <: A lower bound, got {:?}", bs.lower
        );
    }

    fn invariant(t: Type) -> GenericArg {
        GenericArg { variance: Variance::Invariant, is_star: false, ty: t }
    }

    fn out(t: Type) -> GenericArg {
        GenericArg { variance: Variance::Out, is_star: false, ty: t }
    }

    #[test]
    fn parameterised_generic_invariant_produces_equality() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        // List<A> <: List<Int> — invariant arg implies A ≡ Int.
        cs.add_constraint(
            Type::Generic { name: "List".into(), args: vec![invariant(a)] },
            Type::Generic { name: "List".into(), args: vec![invariant(Type::Int)] },
        );
        cs.reduce().unwrap();
        let bs = cs.bounds.get(&av).unwrap();
        assert!(bs.lower.contains(&Type::Int));
        assert!(bs.upper.contains(&Type::Int));
    }

    #[test]
    fn parameterised_generic_out_emits_subtype_only() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        // List<out A> <: List<out Int> — covariant arg implies A <: Int.
        cs.add_constraint(
            Type::Generic { name: "List".into(), args: vec![out(a)] },
            Type::Generic { name: "List".into(), args: vec![out(Type::Int)] },
        );
        cs.reduce().unwrap();
        let bs = cs.bounds.get(&av).unwrap();
        assert!(bs.upper.contains(&Type::Int));
        assert!(!bs.lower.contains(&Type::Int));
    }

    #[test]
    fn incorporate_derives_equality_from_paired_generic_uppers() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        let (tv, t) = cs.fresh("T");
        // α <: List<T> and α <: List<Int> — invariant arg implies T ≡ Int.
        cs.add_constraint(
            a.clone(),
            Type::Generic { name: "List".into(), args: vec![invariant(t)] },
        );
        cs.add_constraint(
            a,
            Type::Generic { name: "List".into(), args: vec![invariant(Type::Int)] },
        );
        cs.solve_to_fixpoint().unwrap();
        let _ = av;
        let bs = cs.bounds.get(&tv).unwrap();
        assert!(
            bs.lower.contains(&Type::Int) && bs.upper.contains(&Type::Int),
            "T should be equated with Int via incorporation; bounds: lower={:?} upper={:?}",
            bs.lower, bs.upper
        );
    }

    #[test]
    fn solve_staged_fixes_dependent_vars_after_independents() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        let (bv, b) = cs.fresh("B");
        // A <: Int and B <: A. After fixation A = Int, then B = Int.
        cs.add_constraint(Type::Int, a.clone());
        cs.add_constraint(a, b);
        cs.solve_to_fixpoint().unwrap();
        let sol = cs.solve_staged();
        assert_eq!(sol.get(&av), Some(&Type::Int));
        assert_eq!(sol.get(&bv), Some(&Type::Int));
    }

    #[test]
    fn solve_staged_handles_independent_vars_in_one_stage() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        let (bv, b) = cs.fresh("B");
        cs.add_constraint(Type::Int, a);
        cs.add_constraint(Type::String, b);
        cs.solve_to_fixpoint().unwrap();
        let sol = cs.solve_staged();
        assert_eq!(sol.get(&av), Some(&Type::Int));
        assert_eq!(sol.get(&bv), Some(&Type::String));
    }

    #[test]
    fn incorporate_unions_cyclic_vars() {
        let mut cs = ConstraintSystem::new();
        let (av, a) = cs.fresh("A");
        let (bv, b) = cs.fresh("B");
        cs.add_constraint(a.clone(), b.clone());
        cs.add_constraint(b, a);
        cs.solve_to_fixpoint().unwrap();
        assert_eq!(cs.canonical(av), cs.canonical(bv));
    }

    #[test]
    fn last_error_carries_provenance() {
        let mut cs = ConstraintSystem::new();
        cs.add_constraint_with(
            Type::Int,
            Type::String,
            ConstraintKind::Subtype,
            Provenance::CallSite { span: klio_span::Span::new(klio_span::FileId(0), 1, 2), arg_idx: 7 },
        );
        let _ = cs.reduce();
        let (err, prov) = cs.last_error().expect("expected an error");
        assert!(matches!(err, InferenceError::UnsatisfiableConcrete { .. }));
        assert!(matches!(prov, Provenance::CallSite { arg_idx: 7, .. }));
    }
}
