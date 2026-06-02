//! Small, self-contained helpers for literal handling and package-
//! head classification — kept apart from the main lowering module
//! so that bulk only carries the genuinely lowering-bound code.

use klio_ast::Expr;

/// A bare identifier is a package head when it's lowercase (Kotlin
/// package names are lowercase by convention) or one of the
/// primitive companion roots whose `MAX_VALUE` / `MIN_VALUE` /
/// `SIZE_BITS` constants are routed through `primitive_companion_const`.
pub(super) fn is_package_head(name: &str) -> bool {
    if name.chars().next().is_some_and(char::is_lowercase) {
        return true;
    }
    matches!(
        name,
        "Int"
            | "Long"
            | "Short"
            | "Byte"
            | "UInt"
            | "ULong"
            | "UShort"
            | "UByte"
            | "Float"
            | "Double"
            | "Char"
            | "Boolean"
            | "String"
    )
}

/// A genuine top-level package root. [`is_package_head`] treats any
/// lowercase identifier as a package head, which is fine at
/// statement scope but misfires inside a receiver lambda, where an
/// unresolved lowercase name like `twin` is actually a member of
/// the lexically enclosing `this@Outer`. Restrict the FQN-flattening
/// paths to these real roots when no local `this` is in scope but an
/// enclosing one may be.
pub(super) fn is_pkg_root(name: &str) -> bool {
    matches!(
        name,
        "kotlin" | "kotlinx" | "java" | "javax" | "io" | "org" | "com" | "net"
    )
}

/// Widen an integer literal whose target slot is `Long` from `Int`
/// to `Long`. Kotlin lets `val n: Long = 0` and `fun f(n: Long = 0)`
/// take a bare `0`; the AST still encodes that as an `Int` literal
/// because the parser cannot see the target type. Without this
/// rewrite the literal keeps its `Int` runtime representation and
/// later arithmetic truncates. Integer-to-floating widening is NOT
/// implicit in Kotlin (`val d: Double = 1` is a type error there),
/// and `Byte`/`Short` slots promote to `Int` in arithmetic anyway,
/// so neither needs a rewrite.
#[must_use]
pub fn widen_numeric_literal(e: &Expr, ty: &klio_ast::TypeRef) -> Option<Expr> {
    if ty.nullable || ty.name.name != "Long" {
        return None;
    }
    match e {
        Expr::IntLit {
            value,
            kind: klio_ast::IntLitKind::Int,
            span,
        } => Some(Expr::IntLit {
            value: *value,
            kind: klio_ast::IntLitKind::Long,
            span: *span,
        }),
        _ => None,
    }
}
