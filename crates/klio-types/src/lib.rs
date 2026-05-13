//! Kotlin type system.
//!
//! Provides a `Type` enum that models the slice of the Kotlin type system the
//! interpreter currently consumes: the primitive builtins, `Unit`, `Any`,
//! `Nothing`, nullability via `T?`, function types, and integer ranges.
//! Full user-class generics are represented through `Type::Generic`; anything
//! that would require type-parameter machinery we don't yet implement is
//! modeled as `Type::Unresolved`.

use std::fmt;

use klio_ast::TypeRef;
use thiserror::Error;

pub mod constraints;

/// Variance marker on a generic instantiation argument.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Variance {
    #[default]
    Invariant,
    Out,
    In,
}

impl From<klio_ast::Variance> for Variance {
    fn from(v: klio_ast::Variance) -> Self {
        match v {
            klio_ast::Variance::Invariant => Self::Invariant,
            klio_ast::Variance::Out => Self::Out,
            klio_ast::Variance::In => Self::In,
        }
    }
}

/// A single type argument inside a `Type::Generic` instantiation, carrying
/// the use-site projection (`out`/`in`/invariant) so subtyping can apply
/// the right variance per pair.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GenericArg {
    pub variance: Variance,
    /// `*` star-projection. When true, `ty` is `Type::Any` (read view).
    pub is_star: bool,
    pub ty: Type,
}

/// A Kotlin type.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Type {
    Unit,
    Boolean,
    Byte,
    Short,
    Int,
    Long,
    UByte,
    UShort,
    UInt,
    ULong,
    Float,
    Double,
    Char,
    String,
    Any,
    Nothing,
    Nullable(Box<Type>),
    Function {
        params: Vec<Type>,
        return_type: Box<Type>,
        /// Distinguishes `suspend (T) -> R` from `(T) -> R`. Per spec §18.1
        /// these are distinct function types; one is not assignable to
        /// the other.
        is_suspend: bool,
    },
    Range(Box<Type>),
    /// Reference to a generic type parameter declared on an enclosing
    /// function or class (`T`, `E`, …). Treated as `Unresolved`-compatible
    /// for subtyping unless the checker has a binding.
    TypeParam(String),
    /// Instantiation of a generic class: `Box<Int>`, `List<out Any>`, …
    /// The base name is the simple class name; for builtin instantiations
    /// like `List<Int>` we keep the short name.
    Generic {
        name: String,
        args: Vec<GenericArg>,
    },
    /// Intersection of two or more types: `A & B`. Per spec §13 the
    /// greatest lower bound of two types is their intersection. Smart-cast
    /// composition (`if (x is A && x is B)`) materializes one. Subtyping:
    /// `T <: A & B` iff `T <: A ∧ T <: B`; `A & B <: T` iff some component
    /// is a subtype of `T`. Intersections are kept normalized (flattened,
    /// no `Any`/`Unresolved`/duplicate components) by `Type::intersect`.
    Intersection(Vec<Type>),
    /// A type the resolver could not name. Treated as compatible with
    /// everything for the purposes of error recovery so unrelated errors do
    /// not cascade.
    Unresolved,
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unit => f.write_str("Unit"),
            Self::Boolean => f.write_str("Boolean"),
            Self::Byte => f.write_str("Byte"),
            Self::Short => f.write_str("Short"),
            Self::Int => f.write_str("Int"),
            Self::Long => f.write_str("Long"),
            Self::UByte => f.write_str("UByte"),
            Self::UShort => f.write_str("UShort"),
            Self::UInt => f.write_str("UInt"),
            Self::ULong => f.write_str("ULong"),
            Self::Float => f.write_str("Float"),
            Self::Double => f.write_str("Double"),
            Self::Char => f.write_str("Char"),
            Self::String => f.write_str("String"),
            Self::Any => f.write_str("Any"),
            Self::Nothing => f.write_str("Nothing"),
            Self::Nullable(inner) => write!(f, "{inner}?"),
            Self::Function { params, return_type, is_suspend } => {
                if *is_suspend {
                    f.write_str("suspend ")?;
                }
                f.write_str("(")?;
                for (i, p) in params.iter().enumerate() {
                    if i > 0 {
                        f.write_str(", ")?;
                    }
                    write!(f, "{p}")?;
                }
                write!(f, ") -> {return_type}")
            }
            Self::Range(inner) => write!(f, "Range<{inner}>"),
            Self::TypeParam(name) => f.write_str(name),
            Self::Generic { name, args } => {
                f.write_str(name)?;
                f.write_str("<")?;
                for (i, a) in args.iter().enumerate() {
                    if i > 0 {
                        f.write_str(", ")?;
                    }
                    if a.is_star {
                        f.write_str("*")?;
                    } else {
                        match a.variance {
                            Variance::Out => f.write_str("out ")?,
                            Variance::In => f.write_str("in ")?,
                            Variance::Invariant => {}
                        }
                        write!(f, "{}", a.ty)?;
                    }
                }
                f.write_str(">")
            }
            Self::Intersection(parts) => {
                for (i, p) in parts.iter().enumerate() {
                    if i > 0 {
                        f.write_str(" & ")?;
                    }
                    write!(f, "{p}")?;
                }
                Ok(())
            }
            Self::Unresolved => f.write_str("<unresolved>"),
        }
    }
}

impl Type {
    /// Strip a single `Nullable` wrapper if present.
    #[must_use]
    pub fn non_null(&self) -> &Type {
        match self {
            Self::Nullable(inner) => inner,
            _ => self,
        }
    }

    /// `true` if values of this type can be `null`.
    #[must_use]
    pub fn is_nullable(&self) -> bool {
        matches!(self, Self::Nullable(_))
    }

    /// Wrap in `Nullable` unless already nullable.
    #[must_use]
    pub fn as_nullable(self) -> Type {
        if self.is_nullable() {
            self
        } else {
            Type::Nullable(Box::new(self))
        }
    }

    /// Intersection constructor with spec-driven normalization (§13.2.3).
    /// Flattens nested intersections, drops `Any` / `Unresolved` (they are
    /// no-ops in a greatest-lower-bound), and removes any component whose
    /// supertype is already present. A single-component result collapses
    /// to that component; an empty intersection collapses to `Any` (the
    /// degenerate identity element).
    #[must_use]
    pub fn intersect(parts: Vec<Type>) -> Type {
        let mut flat: Vec<Type> = Vec::with_capacity(parts.len());
        for p in parts {
            match p {
                Type::Intersection(inner) => flat.extend(inner),
                Type::Any | Type::Unresolved => {}
                other => flat.push(other),
            }
        }
        // Drop duplicates and supertypes-of-members.
        let mut keep: Vec<Type> = Vec::with_capacity(flat.len());
        for t in flat {
            if keep.iter().any(|k| k.is_subtype_of(&t)) {
                continue;
            }
            keep.retain(|k| !t.is_subtype_of(k));
            keep.push(t);
        }
        match keep.len() {
            0 => Type::Any,
            1 => keep.into_iter().next().unwrap(),
            _ => Type::Intersection(keep),
        }
    }

    /// Subtyping check covering the rules currently consumed by typeck:
    ///
    /// * `Nothing <: T` for every `T`.
    /// * `T <: T?` for every non-null `T`.
    /// * `Any` is the top of the non-null lattice; `Any?` is the absolute top.
    /// * `Nullable(A) <: Nullable(B)` iff `A <: B`.
    /// * Function types are compared by arity, contravariant params and
    ///   covariant return.
    /// * `Unresolved` is compatible with everything in both directions to
    ///   avoid cascading errors.
    #[must_use]
    pub fn is_subtype_of(&self, other: &Type) -> bool {
        if matches!(self, Self::Unresolved) || matches!(other, Self::Unresolved) {
            return true;
        }
        // Type parameters act as permissive wildcards at the subtype
        // boundary unless both sides name the same parameter. The
        // constraint solver narrows them when inference runs; outside of
        // inference the checker keeps user code parity-stable.
        if matches!(self, Self::TypeParam(_)) || matches!(other, Self::TypeParam(_)) {
            if let (Self::TypeParam(a), Self::TypeParam(b)) = (self, other) {
                return a == b;
            }
            return true;
        }
        if self == other {
            return true;
        }
        if matches!(self, Self::Nothing) {
            return true;
        }
        // Intersection on the right: must be a subtype of every component.
        if let Self::Intersection(parts) = other {
            return parts.iter().all(|p| self.is_subtype_of(p));
        }
        // Intersection on the left: any component being a subtype suffices.
        if let Self::Intersection(parts) = self {
            return parts.iter().any(|p| p.is_subtype_of(other));
        }
        match (self, other) {
            (_, Self::Nullable(inner)) => self.non_null().is_subtype_of(inner),
            (Self::Nullable(_), _) => false,
            (_, Self::Any) => !self.is_nullable(),
            (
                Self::Function { params: lp, return_type: lr, is_suspend: ls },
                Self::Function { params: rp, return_type: rr, is_suspend: rs },
            ) => {
                ls == rs
                    && lp.len() == rp.len()
                    && lp.iter().zip(rp.iter()).all(|(l, r)| r.is_subtype_of(l))
                    && lr.is_subtype_of(rr)
            }
            (Self::Range(a), Self::Range(b)) => a.is_subtype_of(b),
            (Self::TypeParam(a), Self::TypeParam(b)) => a == b,
            (Self::Generic { name: an, args: aa }, Self::Generic { name: bn, args: ba }) => {
                if an != bn || aa.len() != ba.len() {
                    return false;
                }
                aa.iter().zip(ba.iter()).all(|(l, r)| {
                    if l.is_star || r.is_star {
                        return true;
                    }
                    let var = match (l.variance, r.variance) {
                        (Variance::Out, _) | (_, Variance::Out) => Variance::Out,
                        (Variance::In, _) | (_, Variance::In) => Variance::In,
                        _ => Variance::Invariant,
                    };
                    match var {
                        Variance::Out => l.ty.is_subtype_of(&r.ty),
                        Variance::In => r.ty.is_subtype_of(&l.ty),
                        Variance::Invariant => l.ty == r.ty,
                    }
                })
            }
            _ => false,
        }
    }
}

/// Errors produced by the typing utilities.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TypeError {
    #[error("unknown type `{0}`")]
    UnknownType(String),
    #[error("cannot unify `{lhs}` with `{rhs}`")]
    Mismatch { lhs: Type, rhs: Type },
}

/// Look up a builtin by short name (`Int`) or fully qualified name
/// (`kotlin.Int`). Returns `None` if unknown.
#[must_use]
pub fn builtin_by_name(name: &str) -> Option<Type> {
    let short = name.strip_prefix("kotlin.").unwrap_or(name);
    match short {
        "Unit" => Some(Type::Unit),
        "Boolean" => Some(Type::Boolean),
        "Byte" => Some(Type::Byte),
        "Short" => Some(Type::Short),
        "Int" => Some(Type::Int),
        "Long" => Some(Type::Long),
        "UByte" => Some(Type::UByte),
        "UShort" => Some(Type::UShort),
        "UInt" => Some(Type::UInt),
        "ULong" => Some(Type::ULong),
        "Float" => Some(Type::Float),
        "Double" => Some(Type::Double),
        "Char" => Some(Type::Char),
        "String" => Some(Type::String),
        "Any" => Some(Type::Any),
        "Nothing" => Some(Type::Nothing),
        _ => None,
    }
}

/// Convert an AST `TypeRef` into a `Type`. Unknown names yield an error.
pub fn convert_type_ref(t: &TypeRef) -> Result<Type, TypeError> {
    match builtin_by_name(&t.name.name) {
        Some(ty) => Ok(if t.nullable { ty.as_nullable() } else { ty }),
        None => Err(TypeError::UnknownType(t.name.name.clone())),
    }
}

/// Like `convert_type_ref` but returns `Type::Unresolved` for unknown names.
///
/// User-defined generic types (`Box<T>`, `Producer<T>`, …) are kept as
/// `Type::Unresolved` so subtyping stays permissive; variance and bound
/// enforcement happens declaration-side in the type checker. The
/// `Type::Generic` form is reserved for cases where the checker explicitly
/// builds it (e.g. for declaration-aware variance composition in a future
/// pass).
#[must_use]
pub fn convert_type_ref_lossy(t: &TypeRef) -> Type {
    if t.name.name == "*" {
        return Type::Any;
    }
    if let Some(ft) = &t.function {
        let params: Vec<Type> = ft.params.iter().map(convert_type_ref_lossy).collect();
        let ret = convert_type_ref_lossy(&ft.ret);
        let func = Type::Function {
            params,
            return_type: Box::new(ret),
            is_suspend: ft.is_suspend,
        };
        return if t.nullable { func.as_nullable() } else { func };
    }
    let base = match builtin_by_name(&t.name.name) {
        Some(ty) => ty,
        None => Type::Unresolved,
    };
    if t.nullable {
        base.as_nullable()
    } else {
        base
    }
}


/// Unify two concrete types. With no generics, unification is structural
/// equality with `Unresolved` acting as a wildcard.
pub fn unify(lhs: &Type, rhs: &Type) -> Result<Type, TypeError> {
    if matches!(lhs, Type::Unresolved) {
        return Ok(rhs.clone());
    }
    if matches!(rhs, Type::Unresolved) {
        return Ok(lhs.clone());
    }
    match (lhs, rhs) {
        (a, b) if a == b => Ok(a.clone()),
        (Type::Nullable(a), Type::Nullable(b)) => Ok(Type::Nullable(Box::new(unify(a, b)?))),
        (
            Type::Function { params: lp, return_type: lr, is_suspend: ls },
            Type::Function { params: rp, return_type: rr, is_suspend: rs },
        ) if lp.len() == rp.len() && ls == rs => {
            let mut params = Vec::with_capacity(lp.len());
            for (a, b) in lp.iter().zip(rp.iter()) {
                params.push(unify(a, b)?);
            }
            let return_type = Box::new(unify(lr, rr)?);
            Ok(Type::Function { params, return_type, is_suspend: *ls })
        }
        (Type::Range(a), Type::Range(b)) => Ok(Type::Range(Box::new(unify(a, b)?))),
        (a, b) => Err(TypeError::Mismatch { lhs: a.clone(), rhs: b.clone() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_ast::Ident;
    use klio_span::{FileId, Span};

    fn ident(name: &str) -> Ident {
        Ident { name: name.into(), span: Span::new(FileId(0), 0, name.len() as u32) }
    }

    fn type_ref(name: &str, nullable: bool) -> TypeRef {
        TypeRef {
            name: ident(name),
            nullable,
            span: Span::new(FileId(0), 0, 0),
            type_args: Vec::new(),
            function: None,
            definitely_non_null: false,
            annotations: Vec::new(),
        }
    }

    #[test]
    fn builtin_lookup_short_names() {
        for (name, ty) in [
            ("Unit", Type::Unit),
            ("Boolean", Type::Boolean),
            ("Byte", Type::Byte),
            ("Short", Type::Short),
            ("Int", Type::Int),
            ("Long", Type::Long),
            ("Float", Type::Float),
            ("Double", Type::Double),
            ("Char", Type::Char),
            ("String", Type::String),
            ("Any", Type::Any),
            ("Nothing", Type::Nothing),
        ] {
            assert_eq!(builtin_by_name(name), Some(ty));
        }
    }

    #[test]
    fn builtin_lookup_fqn() {
        assert_eq!(builtin_by_name("kotlin.Int"), Some(Type::Int));
        assert_eq!(builtin_by_name("kotlin.String"), Some(Type::String));
    }

    #[test]
    fn builtin_lookup_unknown() {
        assert_eq!(builtin_by_name("Banana"), None);
        assert_eq!(builtin_by_name("kotlin.collections.List"), None);
    }

    #[test]
    fn display_renders_types() {
        assert_eq!(Type::Int.to_string(), "Int");
        assert_eq!(Type::Nullable(Box::new(Type::Int)).to_string(), "Int?");
        let f = Type::Function {
            params: vec![Type::Int, Type::String],
            return_type: Box::new(Type::Boolean),
            is_suspend: false,
        };
        assert_eq!(f.to_string(), "(Int, String) -> Boolean");
        let s = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::Boolean),
            is_suspend: true,
        };
        assert_eq!(s.to_string(), "suspend (Int) -> Boolean");
        assert_eq!(Type::Range(Box::new(Type::Int)).to_string(), "Range<Int>");
    }

    #[test]
    fn nothing_is_bottom_of_everything() {
        for t in [
            Type::Int,
            Type::String,
            Type::Any,
            Type::Nullable(Box::new(Type::Int)),
            Type::Nullable(Box::new(Type::Any)),
        ] {
            assert!(Type::Nothing.is_subtype_of(&t), "Nothing should be <: {t}");
        }
    }

    #[test]
    fn any_is_top_of_non_null_lattice() {
        assert!(Type::Int.is_subtype_of(&Type::Any));
        assert!(Type::String.is_subtype_of(&Type::Any));
        assert!(!Type::Nullable(Box::new(Type::Int)).is_subtype_of(&Type::Any));
        assert!(Type::Nullable(Box::new(Type::Int))
            .is_subtype_of(&Type::Nullable(Box::new(Type::Any))));
    }

    #[test]
    fn non_null_promotes_to_nullable() {
        assert!(Type::Int.is_subtype_of(&Type::Nullable(Box::new(Type::Int))));
        assert!(!Type::Nullable(Box::new(Type::Int)).is_subtype_of(&Type::Int));
    }

    #[test]
    fn function_subtyping_is_variance_aware() {
        let id_int = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::Int),
            is_suspend: false,
        };
        let id_any_in_int_out = Type::Function {
            params: vec![Type::Any],
            return_type: Box::new(Type::Int),
            is_suspend: false,
        };
        assert!(id_any_in_int_out.is_subtype_of(&id_int));
        assert!(!id_int.is_subtype_of(&id_any_in_int_out));
        // Spec §18.1: suspending and non-suspending function types are
        // distinct; neither is a subtype of the other.
        let id_int_susp = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::Int),
            is_suspend: true,
        };
        assert!(!id_int.is_subtype_of(&id_int_susp));
        assert!(!id_int_susp.is_subtype_of(&id_int));
    }

    #[test]
    fn unresolved_is_compatible_everywhere() {
        assert!(Type::Unresolved.is_subtype_of(&Type::Int));
        assert!(Type::Int.is_subtype_of(&Type::Unresolved));
    }

    #[test]
    fn unify_identical_returns_input() {
        assert_eq!(unify(&Type::Int, &Type::Int), Ok(Type::Int));
    }

    #[test]
    fn unify_incompatible_errors() {
        let err = unify(&Type::Int, &Type::String).unwrap_err();
        assert!(matches!(err, TypeError::Mismatch { .. }));
    }

    #[test]
    fn unify_with_unresolved_picks_concrete() {
        assert_eq!(unify(&Type::Unresolved, &Type::Int), Ok(Type::Int));
        assert_eq!(unify(&Type::Int, &Type::Unresolved), Ok(Type::Int));
    }

    #[test]
    fn unify_nested_function_types() {
        let a = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::Unresolved),
            is_suspend: false,
        };
        let b = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::String),
            is_suspend: false,
        };
        let merged = unify(&a, &b).unwrap();
        assert_eq!(
            merged,
            Type::Function {
                params: vec![Type::Int],
                return_type: Box::new(Type::String),
                is_suspend: false,
            }
        );
    }

    #[test]
    fn convert_type_ref_known_and_nullable() {
        assert_eq!(convert_type_ref(&type_ref("Int", false)), Ok(Type::Int));
        assert_eq!(
            convert_type_ref(&type_ref("Int", true)),
            Ok(Type::Nullable(Box::new(Type::Int)))
        );
    }

    #[test]
    fn convert_type_ref_unknown_errors() {
        let err = convert_type_ref(&type_ref("Widget", false)).unwrap_err();
        assert!(matches!(err, TypeError::UnknownType(ref n) if n == "Widget"));
    }

    #[test]
    fn convert_type_ref_lossy_falls_back_to_unresolved() {
        assert_eq!(convert_type_ref_lossy(&type_ref("Widget", false)), Type::Unresolved);
        assert_eq!(
            convert_type_ref_lossy(&type_ref("Int", true)),
            Type::Nullable(Box::new(Type::Int))
        );
    }

    #[test]
    fn intersect_drops_any_and_unresolved() {
        assert_eq!(
            Type::intersect(vec![Type::Int, Type::Any, Type::Unresolved]),
            Type::Int
        );
    }

    #[test]
    fn intersect_flattens_nested() {
        let inner = Type::intersect(vec![Type::Int, Type::String]);
        let outer = Type::intersect(vec![inner, Type::Boolean]);
        match outer {
            Type::Intersection(parts) => assert_eq!(parts.len(), 3),
            other => panic!("expected intersection, got {other}"),
        }
    }

    #[test]
    fn intersect_drops_supertype_components() {
        let r = Type::intersect(vec![Type::Int, Type::Any]);
        assert_eq!(r, Type::Int);
    }

    #[test]
    fn intersect_subtype_must_satisfy_every_part() {
        let i = Type::intersect(vec![Type::Int, Type::Nullable(Box::new(Type::Int))]);
        // Int <: Int & Int? (both parts satisfied)
        assert!(Type::Int.is_subtype_of(&i));
    }

    #[test]
    fn intersect_left_any_part_suffices_for_supertype() {
        let i = Type::Intersection(vec![Type::Int, Type::String]);
        assert!(i.is_subtype_of(&Type::Any));
    }

    #[test]
    fn intersect_display() {
        let i = Type::Intersection(vec![Type::Int, Type::String]);
        assert_eq!(i.to_string(), "Int & String");
    }

    #[test]
    fn as_nullable_is_idempotent() {
        let t = Type::Int.as_nullable();
        assert_eq!(t.clone().as_nullable(), t);
    }
}
