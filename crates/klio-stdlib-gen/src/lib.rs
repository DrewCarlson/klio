//! Stdlib codegen library.
//!
//! Walks the upstream Kotlin stdlib source tree and extracts every public
//! top-level / class-member declaration into a stable schema that the
//! generator emits as Rust constant data in `klio-stdlib/src/generated/`.
//!
//! The parser here is intentionally declaration-only. It does not understand
//! Kotlin expressions or bodies, only enough lexical structure (comments,
//! strings, annotations, modifiers, braces / parens / angle brackets) to find
//! the next declaration header and skip past everything else.

pub mod emit;
pub mod parse;
pub mod walk;

pub use emit::emit_generated;
pub use parse::{Decl, DeclKind, ParsedFile, Visibility, parse_file};
pub use walk::{CollectStats, collect_decls};
