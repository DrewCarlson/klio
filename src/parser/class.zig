//! Class / interface / object / enum declaration parsing, including
//! supertype lists, primary-constructor params, and class bodies.
//!
//! Free functions over `*Parser`.

const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");

const root = @import("parser.zig");
const support = @import("support.zig");
const types = @import("types.zig");
const file = @import("file.zig");
const stmt = @import("stmt.zig");
const members = @import("members.zig");
const expr = @import("expr.zig");

const Parser = root.Parser;
const ClassModifiers = root.ClassModifiers;

const Annotation = ast.Annotation;
const Block = ast.Block;
const Class = ast.Class;
const ClassParam = ast.ClassParam;
const CtorDelegation = ast.CtorDelegation;
const Decl = ast.Decl;
const EnumEntry = ast.EnumEntry;
const Expr = ast.Expr;
const Ident = ast.Ident;
const ObjectDecl = ast.ObjectDecl;
const SecondaryCtor = ast.SecondaryCtor;
const TypeRef = ast.TypeRef;
const Visibility = ast.Visibility;

/// Parsed supertype list: the supertypes, each entry's optional constructor
/// argument list, and each entry's optional `by`-delegate expression.
pub const SupertypeList = struct {
    types: []TypeRef,
    args: []?[]Expr,
    arg_names: []const ?[]const ?[]const u8,
    delegates: []?Expr,
};

/// Result of `parseClassBody`: members, init blocks, the position of each
/// init block (number of members already seen), and secondary ctors.
pub const ClassBody = struct {
    members: []Decl,
    init_blocks: []Block,
    init_block_positions: []usize,
    secondary_ctors: []SecondaryCtor,
};

/// Result of `parseEnumClassBody`: members, init blocks, init-block
/// positions, and the declared enum entries.
pub const EnumClassBody = struct {
    members: []Decl,
    init_blocks: []Block,
    init_block_positions: []usize,
    entries: []EnumEntry,
    secondary_ctors: []SecondaryCtor,
};

pub fn parseClass(
    p: *Parser,
    mods: ClassModifiers,
    visibility: Visibility,
    annotations: []Annotation,
) ?Class {
    const kw = support.bump(p); // `class` / `interface`
    const is_interface = std.meta.activeTag(kw.kind) == .Keyword and
        kw.kind.Keyword == .Interface;
    const name = support.parseIdent(p, "class name") orelse return null;
    skipNlIfHeaderContinues(p);
    var type_params: []ast.TypeParam = &.{};
    if (std.meta.activeTag(support.peekKind(p).*) == .Lt) {
        type_params = types.parseTypeParams(p, false);
    }
    skipNlIfHeaderContinues(p);
    // A `context(...)` clause on the primary constructor is unsupported.
    if (support.peekKeywordIdent(p, "context") and
        p.pos + 1 < p.tokens.len and std.meta.activeTag(p.tokens[p.pos + 1].kind) == .LParen)
    {
        const ctx_start = support.currentSpan(p);
        _ = support.bump(p); // `context`
        var depth: i32 = 0;
        while (true) {
            const t = support.peekKind(p).*;
            switch (std.meta.activeTag(t)) {
                .LParen => depth += 1,
                .RParen => {
                    depth -= 1;
                    _ = support.bump(p);
                    if (depth == 0) break;
                    continue;
                },
                .Eof => break,
                else => {},
            }
            _ = support.bump(p);
        }
        const ctx_end = p.tokens[p.pos -| 1].span;
        support.errWithFactory(
            p,
            &diagnostics.generated.UNSUPPORTED,
            "E0307",
            "Context parameters on constructors are unsupported.",
            ctx_start.join(ctx_end),
        );
        skipNlIfHeaderContinues(p);
    }
    skipPrimaryCtorAnnotations(p);
    const primary_ctor_visibility = parsePrimaryCtorHeader(p);
    var primary_params: []ClassParam = &.{};
    var has_primary_ctor = false;
    if (std.meta.activeTag(support.peekKind(p).*) == .LParen) {
        _ = support.bump(p);
        primary_params = parseClassParamList(p);
        _ = support.expect(p, .RParen, "`)`");
        has_primary_ctor = true;
    }
    const sup = parseOptionalSupertypesFull(p);
    const where_bounds = types.parseWhereClause(p);
    var class_members: []Decl = undefined;
    var init_blocks: []Block = undefined;
    var init_block_positions: []usize = undefined;
    var enum_entries: []EnumEntry = undefined;
    var secondary_ctors: []SecondaryCtor = undefined;
    if (mods.is_enum) {
        const eb = parseEnumClassBody(p, name);
        class_members = eb.members;
        init_blocks = eb.init_blocks;
        init_block_positions = eb.init_block_positions;
        enum_entries = eb.entries;
        secondary_ctors = eb.secondary_ctors;
    } else {
        const cb = parseClassBody(p);
        class_members = cb.members;
        init_blocks = cb.init_blocks;
        init_block_positions = cb.init_block_positions;
        enum_entries = &.{};
        secondary_ctors = cb.secondary_ctors;
    }
    const end = p.tokens[p.pos -| 1].span;
    return Class{
        .name = name,
        .type_params = type_params,
        .where_bounds = where_bounds,
        .primary_params = primary_params,
        .has_primary_ctor = has_primary_ctor,
        .primary_ctor_visibility = primary_ctor_visibility,
        .init_blocks = init_blocks,
        .init_block_positions = init_block_positions,
        .supertypes = sup.types,
        .supertype_args = sup.args,
        .supertype_arg_names = sup.arg_names,
        .supertype_delegates = sup.delegates,
        .is_data = mods.is_data,
        .is_companion = mods.is_companion,
        .is_enum = mods.is_enum,
        .is_sealed = mods.is_sealed,
        // `abstract` implies `open`.
        .is_open = mods.is_open or mods.is_abstract,
        .is_abstract = mods.is_abstract,
        .is_inner = mods.is_inner,
        .secondary_ctors = secondary_ctors,
        .is_interface = is_interface,
        .is_fun_interface = mods.is_fun_interface,
        .is_value = mods.is_value,
        .is_annotation = mods.is_annotation,
        .is_expect = mods.is_expect,
        .is_actual = mods.is_actual,
        .enum_entries = enum_entries,
        .members = class_members,
        .visibility = visibility,
        .annotations = annotations,
        .span = kw.span.join(end),
    };
}

/// Skip newlines only when the first non-newline token continues the class
/// header (`<`, `(`, `:`, `{`, a ctor annotation `@`, `where`, or a
/// visibility/`constructor` keyword). A bodyless class (`class A`) must not
/// swallow the newline that separates it from the next declaration, so a
/// `class A` / `class B` pair on consecutive lines parses as two statements.
fn skipNlIfHeaderContinues(p: *Parser) void {
    if (std.meta.activeTag(support.peekKind(p).*) != .Newline) return;
    var i = p.pos;
    while (i < p.tokens.len and std.meta.activeTag(p.tokens[i].kind) == .Newline) {
        i += 1;
    }
    if (i >= p.tokens.len) return;
    const k = p.tokens[i].kind;
    const continues = switch (k) {
        .Lt, .LParen, .Colon, .LBrace => true,
        .AtNoWs, .AtPostWs, .AtPreWs, .AtBothWs => true,
        .Ident => blk: {
            const t = support.text(p, p.tokens[i].span);
            break :blk std.mem.eql(u8, t, "where") or
                std.mem.eql(u8, t, "constructor") or
                std.mem.eql(u8, t, "public") or
                std.mem.eql(u8, t, "private") or
                std.mem.eql(u8, t, "protected") or
                std.mem.eql(u8, t, "internal") or
                std.mem.eql(u8, t, "actual") or
                std.mem.eql(u8, t, "expect");
        },
        else => false,
    };
    if (continues) p.pos = i;
}

/// Consume an optional primary-constructor annotation run:
/// `class Foo @Inject @Deprecated(...) internal constructor(...)`.
/// Kotlin requires the `constructor` keyword when the primary
/// constructor is annotated/modified, so only consume a leading
/// `@…` run when it is actually followed by `[visibility]
/// constructor` — otherwise the `@` belongs to the *next*
/// top-level declaration (e.g. `annotation class A` then
/// `@A fun f()`) and must be left untouched. klio treats
/// primary-ctor annotations as runtime no-ops.
fn skipPrimaryCtorAnnotations(p: *Parser) void {
    if (!support.peekKind(p).isAt()) {
        return;
    }
    const ann_save = p.pos;
    while (support.peekKind(p).isAt()) {
        if (file.parseAnnotationSet(p) == null) {
            break;
        }
        support.skipNl(p);
    }
    // Skip an optional run of constructor modifiers (visibility plus the
    // `actual`/`expect` soft keywords, in any order — e.g. `@JvmOverloads
    // public actual constructor`), then require `constructor`.
    var probe = p.pos;
    while (probe < p.tokens.len) {
        while (probe < p.tokens.len and
            std.meta.activeTag(p.tokens[probe].kind) == .Newline) probe += 1;
        if (probe >= p.tokens.len or std.meta.activeTag(p.tokens[probe].kind) != .Ident) break;
        const t = support.text(p, p.tokens[probe].span);
        const is_ctor_mod = std.mem.eql(u8, t, "public") or
            std.mem.eql(u8, t, "private") or
            std.mem.eql(u8, t, "protected") or
            std.mem.eql(u8, t, "internal") or
            std.mem.eql(u8, t, "actual") or
            std.mem.eql(u8, t, "expect");
        if (!is_ctor_mod) break;
        probe += 1;
    }
    while (probe < p.tokens.len and
        std.meta.activeTag(p.tokens[probe].kind) == .Newline) probe += 1;
    const is_primary_ctor = probe < p.tokens.len and
        std.meta.activeTag(p.tokens[probe].kind) == .Ident and
        std.mem.eql(u8, support.text(p, p.tokens[probe].span), "constructor");
    if (!is_primary_ctor) {
        p.pos = ann_save; // the `@` annotates the next decl
    }
}

/// Consume an optional explicit primary constructor header:
/// `class Foo [visibility] [actual|expect]* constructor(...)`.
/// Scan a run of soft-keyword constructor modifiers (in any
/// order) that must terminate in `constructor`; commit only
/// then. `actual`/`expect` are runtime-inert here (klio's
/// expect/actual is name-keyed), visibility is recorded.
fn parsePrimaryCtorHeader(p: *Parser) ?Visibility {
    const saved = p.pos;
    var vis: ?Visibility = null;
    var consumed_modifier = false;
    while (true) {
        if (std.meta.activeTag(support.peekKind(p).*) != .Ident) {
            break;
        }
        const t = support.text(p, support.currentSpan(p));
        if (std.mem.eql(u8, t, "public")) {
            vis = .Public;
        } else if (std.mem.eql(u8, t, "private")) {
            vis = .Private;
        } else if (std.mem.eql(u8, t, "protected")) {
            vis = .Protected;
        } else if (std.mem.eql(u8, t, "internal")) {
            vis = .Internal;
        } else if (std.mem.eql(u8, t, "actual") or std.mem.eql(u8, t, "expect")) {
            // runtime-inert
        } else {
            break;
        }
        _ = support.bump(p);
        support.skipNl(p);
        consumed_modifier = true;
    }
    const at_ctor = std.meta.activeTag(support.peekKind(p).*) == .Ident and
        std.mem.eql(u8, support.text(p, support.currentSpan(p)), "constructor");
    if (at_ctor) {
        _ = support.bump(p); // `constructor`
        support.skipNl(p);
        return vis;
    }
    if (consumed_modifier) {
        // The run was not a constructor header — restore.
        p.pos = saved;
    }
    return null;
}

/// Parse an enum class body: optional entry list (comma-separated, with
/// optional `(...)` ctor args and optional `{...}` per-entry body),
/// optional `;` then regular class-body members.
pub fn parseEnumClassBody(p: *Parser, enum_name: Ident) EnumClassBody {
    // Helper: enum-class body content (after the optional `;`) shares the
    // member-parsing shape of a regular class body, minus secondary
    // constructors.
    var member_list: std.ArrayList(Decl) = .empty;
    var init_block_list: std.ArrayList(Block) = .empty;
    var init_block_positions: std.ArrayList(usize) = .empty;
    var entries: std.ArrayList(EnumEntry) = .empty;
    var secondary_ctors: std.ArrayList(SecondaryCtor) = .empty;
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) != .LBrace) {
        return .{
            .members = ownedDecls(p, &member_list),
            .init_blocks = ownedBlocks(p, &init_block_list),
            .init_block_positions = ownedUsizes(p, &init_block_positions),
            .entries = ownedEntries(p, &entries),
            .secondary_ctors = ownedSecondaryCtors(p, &secondary_ctors),
        };
    }
    _ = support.bump(p);
    // Parse entries until `;`, `}`, or EOF.
    while (true) {
        support.skipNl(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof, .Semicolon => break,
            else => {},
        }
        const annotations = file.parseAnnotations(p);
        const name = support.parseIdent(p, "enum entry name") orelse break;
        const start = name.span;
        var args: std.ArrayList(Expr) = .empty;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .LParen) {
            _ = support.bump(p);
            while (true) {
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .RParen) {
                    break;
                }
                // An enum entry may pass named constructor arguments
                // (`ENTRY(1, "x", viaBroadcast = true)`); consume and drop the
                // `name =` label — entry args bind positionally here.
                _ = expr.tryConsumeNamedArgName(p);
                const a = expr.parseExpr(p) orelse break;
                args.append(p.allocator, a) catch @panic("OOM");
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                    _ = support.bump(p);
                } else {
                    break;
                }
            }
            _ = support.expect(p, .RParen, "`)`");
        }
        var body_members: []Decl = &.{};
        var body: ?ClassBody = null;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .LBrace) {
            const cb = parseClassBody(p);
            body_members = cb.members;
            body = cb;
        }
        const end = p.tokens[p.pos -| 1].span;
        const entry_args = args.toOwnedSlice(p.allocator) catch @panic("OOM");
        if (body) |cb| {
            // `B(args) { … }` declares an anonymous subclass of the enum whose
            // instance is the entry: the body's properties, `init` blocks,
            // functions, and nested classes become members of a synthesized
            // nested class `$B : Enum(args)`, instantiated for the entry at
            // VM start. The entry name itself stays the entry value.
            const synth = std.fmt.allocPrint(p.allocator, "${s}", .{name.name}) catch @panic("OOM");
            const sups = p.allocator.alloc(TypeRef, 1) catch @panic("OOM");
            sups[0] = .{
                .name = enum_name,
                .nullable = false,
                .span = name.span,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            };
            const sargs = p.allocator.alloc(?[]Expr, 1) catch @panic("OOM");
            sargs[0] = entry_args;
            const sdel = p.allocator.alloc(?Expr, 1) catch @panic("OOM");
            sdel[0] = null;
            member_list.append(p.allocator, .{ .Class = .{
                .name = .{ .name = synth, .span = name.span },
                .type_params = &.{},
                .where_bounds = &.{},
                .primary_params = &.{},
                .init_blocks = cb.init_blocks,
                .init_block_positions = cb.init_block_positions,
                .supertypes = sups,
                .supertype_args = sargs,
                .supertype_delegates = sdel,
                .is_data = false,
                .is_companion = false,
                .is_enum = true,
                .is_sealed = false,
                .is_open = false,
                .is_abstract = false,
                .is_inner = false,
                .secondary_ctors = cb.secondary_ctors,
                .is_interface = false,
                .is_fun_interface = false,
                .is_value = false,
                .is_annotation = false,
                .is_expect = false,
                .is_actual = false,
                .enum_entries = &.{},
                .members = cb.members,
                .visibility = .Public,
                .primary_ctor_visibility = null,
                .annotations = &.{},
                .span = start.join(end),
            } }) catch @panic("OOM");
        }
        entries.append(p.allocator, .{
            .name = name,
            .args = entry_args,
            .body_members = body_members,
            .annotations = annotations,
            .span = start.join(end),
        }) catch @panic("OOM");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
            continue;
        }
        break;
    }
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) == .Semicolon) {
        _ = support.bump(p);
        // Continue with regular class-body members until `}`.
        while (true) {
            support.skipNl(p);
            switch (support.peekKind(p).*) {
                .RBrace, .Eof => break,
                else => {},
            }
            if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
                std.mem.eql(u8, support.text(p, support.currentSpan(p)), "init"))
            {
                _ = support.bump(p);
                support.skipNl(p);
                if (stmt.parseBlock(p)) |b| {
                    init_block_positions.append(p.allocator, member_list.items.len) catch @panic("OOM");
                    init_block_list.append(p.allocator, b) catch @panic("OOM");
                }
                continue;
            }
            // A secondary constructor in the enum body: `constructor(n: Int) :
            // this(n, "x")`, called for the entries whose arguments fit it.
            const mod_save = p.pos;
            const flags = file.skipModifiersWithFlags(p);
            if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
                std.mem.eql(u8, support.text(p, support.currentSpan(p)), "constructor"))
            {
                if (parseSecondaryCtor(p, flags.visibility, flags.annotations.items)) |sc| {
                    secondary_ctors.append(p.allocator, sc) catch @panic("OOM");
                }
                continue;
            }
            p.pos = mod_save;
            if (file.parseTopDecl(p)) |d| {
                member_list.append(p.allocator, d) catch @panic("OOM");
            } else {
                _ = support.bump(p);
            }
        }
    }
    _ = support.expect(p, .RBrace, "`}`");
    return .{
        .members = ownedDecls(p, &member_list),
        .init_blocks = ownedBlocks(p, &init_block_list),
        .init_block_positions = ownedUsizes(p, &init_block_positions),
        .entries = ownedEntries(p, &entries),
        .secondary_ctors = ownedSecondaryCtors(p, &secondary_ctors),
    };
}

pub fn parseCompanionObjectAsClass(
    p: *Parser,
    visibility: Visibility,
    annotations: []Annotation,
) ?Class {
    const kw = support.bump(p); // `object`
    // Optional companion name. If absent, name as "Companion".
    const name = if (std.meta.activeTag(support.peekKind(p).*) == .Ident)
        (support.parseIdent(p, "companion name") orelse return null)
    else
        Ident{ .name = "Companion", .span = kw.span };
    const sup = parseOptionalSupertypesFull(p);
    const cb = parseClassBody(p);
    const end = p.tokens[p.pos -| 1].span;
    return Class{
        .name = name,
        .type_params = &.{},
        .where_bounds = &.{},
        .primary_params = &.{},
        .init_blocks = cb.init_blocks,
        .init_block_positions = cb.init_block_positions,
        .supertypes = sup.types,
        .supertype_args = sup.args,
        .supertype_arg_names = sup.arg_names,
        .supertype_delegates = sup.delegates,
        .is_data = false,
        .is_companion = true,
        .is_enum = false,
        .is_sealed = false,
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .secondary_ctors = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .is_value = false,
        .is_annotation = false,
        .is_expect = false,
        .is_actual = false,
        .enum_entries = &.{},
        .members = cb.members,
        .visibility = visibility,
        .primary_ctor_visibility = null,
        .annotations = annotations,
        .span = kw.span.join(end),
    };
}

pub fn parseObject(
    p: *Parser,
    is_data: bool,
    is_expect: bool,
    is_actual: bool,
    visibility: Visibility,
    annotations: []Annotation,
) ?ObjectDecl {
    const kw = support.bump(p); // `object`
    const name = support.parseIdent(p, "object name") orelse return null;
    const sup = parseOptionalSupertypesFull(p);
    const cb = parseClassBody(p);
    const end = p.tokens[p.pos -| 1].span;
    return ObjectDecl{
        .name = name,
        .supertypes = sup.types,
        .supertype_args = sup.args,
        .supertype_arg_names = sup.arg_names,
        .supertype_delegates = sup.delegates,
        .annotations = annotations,
        .members = cb.members,
        .init_blocks = cb.init_blocks,
        .init_block_positions = cb.init_block_positions,
        .is_data = is_data,
        .is_expect = is_expect,
        .is_actual = is_actual,
        .visibility = visibility,
        .span = kw.span.join(end),
    };
}

pub fn parseOptionalSupertypes(p: *Parser) struct { types: []TypeRef, args: []?[]Expr } {
    const sup = parseOptionalSupertypesFull(p);
    return .{ .types = sup.types, .args = sup.args };
}

pub fn parseOptionalSupertypesFull(p: *Parser) SupertypeList {
    var type_list: std.ArrayList(TypeRef) = .empty;
    var args_list: std.ArrayList(?[]Expr) = .empty;
    var names_list: std.ArrayList(?[]const ?[]const u8) = .empty;
    var delegates: std.ArrayList(?Expr) = .empty;
    const save = p.pos;
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) != .Colon) {
        p.pos = save;
        return .{
            .types = ownedTypes(p, &type_list),
            .args = ownedArgsList(p, &args_list),
            .arg_names = names_list.toOwnedSlice(p.allocator) catch @panic("OOM"),
            .delegates = ownedDelegates(p, &delegates),
        };
    }
    _ = support.bump(p);
    while (true) {
        support.skipNl(p);
        const t = types.parseType(p) orelse break;
        type_list.append(p.allocator, t) catch @panic("OOM");
        // Optional constructor call `Bar(args)` after the type name.
        if (std.meta.activeTag(support.peekKind(p).*) == .LParen) {
            _ = support.bump(p);
            var args: std.ArrayList(Expr) = .empty;
            var arg_names: std.ArrayList(?[]const u8) = .empty;
            while (true) {
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .RParen) {
                    break;
                }
                var this_name: ?[]const u8 = null;
                if (std.meta.activeTag(support.peekKind(p).*) == .Ident) {
                    const arg_save = p.pos;
                    const label = support.parseIdent(p, "arg label");
                    if (std.meta.activeTag(support.peekKind(p).*) == .Eq) {
                        _ = support.bump(p);
                        support.skipNl(p);
                        if (label) |l| this_name = l.name;
                    } else {
                        p.pos = arg_save;
                    }
                }
                const a = expr.parseExpr(p) orelse break;
                args.append(p.allocator, a) catch @panic("OOM");
                arg_names.append(p.allocator, this_name) catch @panic("OOM");
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                    _ = support.bump(p);
                } else {
                    break;
                }
            }
            _ = support.expect(p, .RParen, "`)`");
            args_list.append(p.allocator, args.toOwnedSlice(p.allocator) catch @panic("OOM")) catch @panic("OOM");
            names_list.append(p.allocator, arg_names.toOwnedSlice(p.allocator) catch @panic("OOM")) catch @panic("OOM");
            delegates.append(p.allocator, null) catch @panic("OOM");
        } else if (eqlOpt(support.peekIdentText(p), "by")) {
            _ = support.bump(p);
            support.skipNl(p);
            const prev = p.suppress_trailing_lambda;
            p.suppress_trailing_lambda = true;
            const de = expr.parseExpr(p);
            p.suppress_trailing_lambda = prev;
            args_list.append(p.allocator, null) catch @panic("OOM");
            names_list.append(p.allocator, null) catch @panic("OOM");
            delegates.append(p.allocator, de) catch @panic("OOM");
        } else {
            args_list.append(p.allocator, null) catch @panic("OOM");
            names_list.append(p.allocator, null) catch @panic("OOM");
            delegates.append(p.allocator, null) catch @panic("OOM");
        }
        // A comma continues the supertype list and may sit on the next line,
        // but a trailing newline with no comma is the statement separator and
        // must be left for the caller (`class A : B()` then a sibling decl).
        const comma_save = p.pos;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
            continue;
        }
        p.pos = comma_save;
        break;
    }
    return .{
        .types = ownedTypes(p, &type_list),
        .args = ownedArgsList(p, &args_list),
        .arg_names = names_list.toOwnedSlice(p.allocator) catch @panic("OOM"),
        .delegates = ownedDelegates(p, &delegates),
    };
}

pub fn parseClassBody(p: *Parser) ClassBody {
    var member_list: std.ArrayList(Decl) = .empty;
    var init_block_list: std.ArrayList(Block) = .empty;
    var init_block_positions: std.ArrayList(usize) = .empty;
    var secondary_ctors: std.ArrayList(SecondaryCtor) = .empty;
    const save = p.pos;
    support.skipNl(p);
    if (std.meta.activeTag(support.peekKind(p).*) != .LBrace) {
        p.pos = save;
        return .{
            .members = ownedDecls(p, &member_list),
            .init_blocks = ownedBlocks(p, &init_block_list),
            .init_block_positions = ownedUsizes(p, &init_block_positions),
            .secondary_ctors = ownedSecondaryCtors(p, &secondary_ctors),
        };
    }
    _ = support.bump(p);
    while (true) {
        stmt.skipStmtSeparators(p);
        switch (support.peekKind(p).*) {
            .RBrace, .Eof => break,
            else => {},
        }
        if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
            std.mem.eql(u8, support.text(p, support.currentSpan(p)), "init"))
        {
            _ = support.bump(p);
            support.skipNl(p);
            if (stmt.parseBlock(p)) |b| {
                // Record the init block's position as the number of
                // members already seen — runs before the next member
                // (and after earlier ones).
                init_block_positions.append(p.allocator, member_list.items.len) catch @panic("OOM");
                init_block_list.append(p.allocator, b) catch @panic("OOM");
            }
            continue;
        }
        // Skip any modifiers in front of the next member. After that we
        // can detect a `constructor` keyword to branch to secondary-ctor
        // parsing.
        const mod_save = p.pos;
        const flags = file.skipModifiersWithFlags(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
            std.mem.eql(u8, support.text(p, support.currentSpan(p)), "constructor"))
        {
            if (flags.suspend_span) |sp| {
                support.err(
                    p,
                    "T0114",
                    "`suspend` modifier is not allowed on a constructor",
                    sp,
                );
            }
            if (parseSecondaryCtor(p, flags.visibility, flags.annotations.items)) |sc| {
                secondary_ctors.append(p.allocator, sc) catch @panic("OOM");
            }
            continue;
        }
        // Roll back the modifier consumption so `parseTopDecl` can do
        // it itself (it depends on flags for the member it sees).
        p.pos = mod_save;
        if (file.parseTopDecl(p)) |d| {
            member_list.append(p.allocator, d) catch @panic("OOM");
        } else {
            _ = support.bump(p);
        }
    }
    _ = support.expect(p, .RBrace, "`}`");
    return .{
        .members = ownedDecls(p, &member_list),
        .init_blocks = ownedBlocks(p, &init_block_list),
        .init_block_positions = ownedUsizes(p, &init_block_positions),
        .secondary_ctors = ownedSecondaryCtors(p, &secondary_ctors),
    };
}

pub fn parseSecondaryCtor(
    p: *Parser,
    visibility: Visibility,
    annotations: []Annotation,
) ?SecondaryCtor {
    const kw = support.bump(p); // `constructor`
    _ = support.expect(p, .LParen, "`(`") orelse return null;
    const params = members.parseParamList(p);
    _ = support.expect(p, .RParen, "`)`") orelse return null;
    support.skipNl(p);
    var delegation: CtorDelegation = .None;
    var delegation_arg_names: []const ?[]const u8 = &.{};
    if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
        _ = support.bump(p);
        support.skipNl(p);
        // Either `this` or `super` keyword, followed by `(args)`.
        const is_this: ?bool = switch (support.peekKind(p).*) {
            .Keyword => |k| switch (k) {
                .This => true,
                .Super => false,
                else => null,
            },
            else => null,
        };
        if (is_this) |this_kind| {
            _ = support.bump(p);
            _ = support.expect(p, .LParen, "`(`");
            var args: std.ArrayList(Expr) = .empty;
            var arg_names: std.ArrayList(?[]const u8) = .empty;
            var any_named = false;
            while (true) {
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .RParen) {
                    break;
                }
                // A named delegation argument (`this(groups = …, slots = …)`)
                // binds the target constructor's parameter of that name; the
                // names ride beside the positional expressions.
                const an = expr.tryConsumeNamedArgName(p);
                if (an != null) any_named = true;
                arg_names.append(p.allocator, an) catch @panic("OOM");
                // A delegation argument may be a spread (`super("0", *x, "4")`).
                const a = expr.parseValueArgument(p) orelse break;
                args.append(p.allocator, a) catch @panic("OOM");
                support.skipNl(p);
                if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
                    _ = support.bump(p);
                } else {
                    break;
                }
            }
            _ = support.expect(p, .RParen, "`)`");
            const arg_slice = args.toOwnedSlice(p.allocator) catch @panic("OOM");
            delegation_arg_names = if (any_named) (arg_names.toOwnedSlice(p.allocator) catch @panic("OOM")) else &.{};
            delegation = if (this_kind)
                CtorDelegation{ .This = arg_slice }
            else
                CtorDelegation{ .Super = arg_slice };
        }
    }
    support.skipNl(p);
    const body = if (std.meta.activeTag(support.peekKind(p).*) == .LBrace)
        stmt.parseBlock(p)
    else
        null;
    const end = p.tokens[p.pos -| 1].span;
    return SecondaryCtor{
        .params = params,
        .delegation = delegation,
        .delegation_arg_names = delegation_arg_names,
        .body = body,
        .visibility = visibility,
        .annotations = annotations,
        .span = kw.span.join(end),
    };
}

pub fn parseClassParamList(p: *Parser) []ClassParam {
    var params: std.ArrayList(ClassParam) = .empty;
    while (true) {
        support.skipNl(p);
        const annotations = file.parseAnnotations(p);
        // Visibility modifiers in front of a param.
        var visibility: Visibility = .Public;
        while (std.meta.activeTag(support.peekKind(p).*) == .Ident) {
            const t = support.text(p, support.currentSpan(p));
            if (std.mem.eql(u8, t, "public")) {
                visibility = .Public;
                _ = support.bump(p);
                support.skipNl(p);
            } else if (std.mem.eql(u8, t, "private")) {
                visibility = .Private;
                _ = support.bump(p);
                support.skipNl(p);
            } else if (std.mem.eql(u8, t, "protected")) {
                visibility = .Protected;
                _ = support.bump(p);
                support.skipNl(p);
            } else if (std.mem.eql(u8, t, "internal")) {
                visibility = .Internal;
                _ = support.bump(p);
                support.skipNl(p);
            } else if (std.mem.eql(u8, t, "override") or
                std.mem.eql(u8, t, "final") or
                std.mem.eql(u8, t, "open") or
                std.mem.eql(u8, t, "abstract") or
                std.mem.eql(u8, t, "lateinit") or
                std.mem.eql(u8, t, "actual") or
                std.mem.eql(u8, t, "expect"))
            {
                _ = support.bump(p);
                support.skipNl(p);
            } else {
                break;
            }
        }
        switch (support.peekKind(p).*) {
            .RParen, .Eof => break,
            else => {},
        }
        // Optional `vararg` modifier on a primary-ctor parameter.
        var is_vararg = false;
        if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
            std.mem.eql(u8, support.text(p, support.currentSpan(p)), "vararg"))
        {
            _ = support.bump(p);
            support.skipNl(p);
            is_vararg = true;
        }
        const property: ?bool = switch (support.peekKind(p).*) {
            .Keyword => |k| switch (k) {
                .Val => blk: {
                    _ = support.bump(p);
                    break :blk false;
                },
                .Var => blk: {
                    _ = support.bump(p);
                    break :blk true;
                },
                else => null,
            },
            else => null,
        };
        const name = support.parseIdent(p, "parameter name") orelse {
            members.recoverUntilParen(p);
            break;
        };
        const start = name.span;
        _ = support.expect(p, .Colon, "`:`");
        const ty = types.parseType(p) orelse TypeRef{
            .name = Ident{ .name = "Any", .span = name.span },
            .nullable = true,
            .span = name.span,
            .type_args = &.{},
            .function = null,
            .definitely_non_null = false,
            .annotations = &.{},
            .qualified_path = null,
        };
        // An explicit-backing-field clause is never legal on a constructor
        // property: reject `val xs: List<Int> field: MutableList<Int> = …`
        // at the `field` token and consume the clause to recover.
        if (std.meta.activeTag(support.peekKind(p).*) == .Ident and
            std.mem.eql(u8, support.text(p, support.currentSpan(p)), "field"))
        {
            const is_clause = p.pos + 1 < p.tokens.len and switch (p.tokens[p.pos + 1].kind) {
                .Colon, .Eq => true,
                else => false,
            };
            if (is_clause) {
                const field_tok = support.bump(p);
                support.err(
                    p,
                    "E0015",
                    "explicit backing fields are not allowed on constructor properties",
                    field_tok.span,
                );
                if (std.meta.activeTag(support.peekKind(p).*) == .Colon) {
                    _ = support.bump(p);
                    _ = types.parseType(p);
                }
            }
        }
        var default: ?Expr = null;
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Eq) {
            _ = support.bump(p);
            support.skipNl(p);
            default = expr.parseExpr(p);
        }
        const end = if (default) |d| d.span() else ty.span;
        params.append(p.allocator, .{
            .property = property,
            .name = name,
            .ty = ty,
            .default = default,
            .visibility = visibility,
            .is_vararg = is_vararg,
            .annotations = annotations,
            .span = start.join(end),
        }) catch @panic("OOM");
        support.skipNl(p);
        if (std.meta.activeTag(support.peekKind(p).*) == .Comma) {
            _ = support.bump(p);
        } else {
            break;
        }
    }
    return params.toOwnedSlice(p.allocator) catch @panic("OOM");
}

// ---------- helpers ----------

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

fn ownedDecls(p: *Parser, list: *std.ArrayList(Decl)) []Decl {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedBlocks(p: *Parser, list: *std.ArrayList(Block)) []Block {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedUsizes(p: *Parser, list: *std.ArrayList(usize)) []usize {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedEntries(p: *Parser, list: *std.ArrayList(EnumEntry)) []EnumEntry {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedSecondaryCtors(p: *Parser, list: *std.ArrayList(SecondaryCtor)) []SecondaryCtor {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedTypes(p: *Parser, list: *std.ArrayList(TypeRef)) []TypeRef {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedArgsList(p: *Parser, list: *std.ArrayList(?[]Expr)) []?[]Expr {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}

fn ownedDelegates(p: *Parser, list: *std.ArrayList(?Expr)) []?Expr {
    return list.toOwnedSlice(p.allocator) catch @panic("OOM");
}
