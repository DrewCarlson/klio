//! Recursive-descent parser method implementations, split into topical
//! submodules. Each submodule contributes a `pub(crate)` inherent `impl`
//! block to the crate-root [`crate::Parser`] type.

pub(crate) use crate::*;

pub(crate) mod support;

pub(crate) mod file;

pub(crate) mod class;

pub(crate) mod types;

pub(crate) mod members;

pub(crate) mod stmt;

pub(crate) mod expr;

pub(crate) mod primary;

pub(crate) mod control;
