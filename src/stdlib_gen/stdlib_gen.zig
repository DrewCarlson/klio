//! Stdlib codegen library. Walks the upstream Kotlin stdlib source tree and
//! extracts every top-level and class-member declaration into the schema the
//! generator emits as constant data for `stdlib`. The parser is
//! declaration-only: it reads just enough lexical structure (comments, strings,
//! annotations, modifiers, brackets) to find the next declaration header and
//! skip the rest.

const std = @import("std");

pub const parse = @import("parse.zig");
pub const walk = @import("walk.zig");
pub const emit = @import("emit.zig");
pub const main = @import("main.zig");

pub const Decl = parse.Decl;
pub const DeclKind = parse.DeclKind;
pub const ParsedFile = parse.ParsedFile;
pub const Visibility = parse.Visibility;
pub const parseFile = parse.parseFile;

pub const CollectStats = walk.CollectStats;
pub const FileDecls = walk.FileDecls;
pub const collectDecls = walk.collectDecls;

pub const emitGenerated = emit.emitGenerated;

pub const run = main.run;

test {
    std.testing.refAllDecls(@This());
    _ = parse;
    _ = walk;
    _ = emit;
    _ = main;
}
