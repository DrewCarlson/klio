//! Kotlin type system.
//!
//! Provides a `Type` enum that models the slice of the Kotlin type system the
//! interpreter needs at Milestone 4: the primitive builtins, `Unit`, `Any`,
//! `Nothing`, nullability via `T?`, function types, and integer ranges.
//! Generics are intentionally deferred: anything that would require a real
//! type parameter is modeled as `Type::Unresolved`.

use std::fmt;

use klio_ast::TypeRef;
use thiserror::Error;

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
            Self::Float => f.write_str("Float"),
            Self::Double => f.write_str("Double"),
            Self::Char => f.write_str("Char"),
            Self::String => f.write_str("String"),
            Self::Any => f.write_str("Any"),
            Self::Nothing => f.write_str("Nothing"),
            Self::Nullable(inner) => write!(f, "{inner}?"),
            Self::Function { params, return_type } => {
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

    /// Subtyping check covering the rules used by Milestone 4:
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
        if self == other {
            return true;
        }
        if matches!(self, Self::Nothing) {
            return true;
        }
        match (self, other) {
            (_, Self::Nullable(inner)) => self.non_null().is_subtype_of(inner),
            (Self::Nullable(_), _) => false,
            (_, Self::Any) => !self.is_nullable(),
            (
                Self::Function { params: lp, return_type: lr },
                Self::Function { params: rp, return_type: rr },
            ) => {
                lp.len() == rp.len()
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
            Type::Function { params: lp, return_type: lr },
            Type::Function { params: rp, return_type: rr },
        ) if lp.len() == rp.len() => {
            let mut params = Vec::with_capacity(lp.len());
            for (a, b) in lp.iter().zip(rp.iter()) {
                params.push(unify(a, b)?);
            }
            let return_type = Box::new(unify(lr, rr)?);
            Ok(Type::Function { params, return_type })
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
        };
        assert_eq!(f.to_string(), "(Int, String) -> Boolean");
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
        };
        let id_any_in_int_out = Type::Function {
            params: vec![Type::Any],
            return_type: Box::new(Type::Int),
        };
        assert!(id_any_in_int_out.is_subtype_of(&id_int));
        assert!(!id_int.is_subtype_of(&id_any_in_int_out));
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
        };
        let b = Type::Function {
            params: vec![Type::Int],
            return_type: Box::new(Type::String),
        };
        let merged = unify(&a, &b).unwrap();
        assert_eq!(
            merged,
            Type::Function {
                params: vec![Type::Int],
                return_type: Box::new(Type::String),
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
    fn as_nullable_is_idempotent() {
        let t = Type::Int.as_nullable();
        assert_eq!(t.clone().as_nullable(), t);
    }
}
