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

    /// Per spec §13.2.1: for every variable α with `S <: α` and `α <: T`,
    /// derive `S <: T`. Repeats until no fresh constraints are produced.
    pub fn incorporate(&mut self) -> Result<(), InferenceError> {
        loop {
            let mut new_constraints: Vec<(Type, Type)> = Vec::new();
            for bs in self.bounds.values() {
                for s in &bs.lower {
                    for t in &bs.upper {
                        new_constraints.push((s.clone(), t.clone()));
                    }
                }
            }
            let before = self.pending.len() + self.seen.len();
            for (s, t) in new_constraints {
                self.add_constraint(s, t);
            }
            let after_pending = self.pending.len();
            if after_pending == 0 {
                break;
            }
            self.reduce()?;
            let after = self.pending.len() + self.seen.len();
            if after == before {
                break;
            }
        }
        Ok(())
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
