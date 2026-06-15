//! Generated stdlib symbol index.
//!
//! The on-disk form is `symbols.postcard` (binary, produced by the stdlib
//! generator). At runtime we deserialise once and materialise the
//! `[]SymbolEntry` shape. The decoded strings live for the program's
//! lifetime (allocated from the page allocator), so the borrowed slices on
//! `SymbolEntry` stay valid.

const std = @import("std");
const pack = @import("pack");

const root = @import("../stdlib.zig");
const Modifiers = root.Modifiers;
const SourceLoc = root.SourceLoc;
const SymbolEntry = root.SymbolEntry;
const SymbolKind = root.SymbolKind;

const SYMBOLS_POSTCARD = @embedFile("symbols.postcard");

/// Lazy-init guard. Zig 0.16's std has no `std.once`; this spin lock plus a
/// `done` flag gives the same first-access-decodes-once semantics. The decoded
/// slice is read-only after init.
var init_lock = std.atomic.Value(u32).init(0);
var init_done = std.atomic.Value(bool).init(false);
var symbols: []SymbolEntry = &.{};

/// Static slice of every stdlib symbol mined from upstream Kotlin. First
/// access deserialises the embedded postcard bytes once; every subsequent
/// access reuses the materialised slice.
pub fn stdlibSymbols() []const SymbolEntry {
    if (init_done.load(.acquire)) return symbols;
    while (init_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer init_lock.store(0, .release);
    if (!init_done.load(.acquire)) {
        symbols = decodeSymbols() catch &.{};
        init_done.store(true, .release);
    }
    return symbols;
}

/// Process-lifetime bump arena for the decoded registry. The symbol index
/// deserialises into tens of thousands of small strings/records; routing
/// those through `page_allocator` directly mmaps a full page per allocation
/// (~16 KB minimum on some hosts), inflating a few MB of data into hundreds
/// of MB resident. An arena bump-allocates them into a handful of large
/// chunks. The arena is intentionally never freed (the slices live for the
/// process), matching the Rust `Box::leak` of the materialised registry.
var symbol_arena: std.heap.ArenaAllocator = undefined;

fn decodeSymbols() std.mem.Allocator.Error![]SymbolEntry {
    symbol_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = symbol_arena.allocator();
    var err: pack.PackError = undefined;
    const index = (try pack.schema.decode(pack.schema.SymbolIndex, a, SYMBOLS_POSTCARD, &err)) orelse return &.{};
    const out = try a.alloc(SymbolEntry, index.entries.len);
    for (index.entries, out) |r, *e| {
        e.* = recordToEntry(r);
    }
    return out;
}

fn recordToEntry(r: pack.schema.SymbolRecord) SymbolEntry {
    const kind: SymbolKind = switch (r.kind) {
        .Function => .Function,
        .Property => .Property,
        .Class => .Class,
        .Interface => .Interface,
        .Object => .Object,
        .TypeAlias => .TypeAlias,
    };
    const source: SourceLoc = if (r.source) |s|
        .{ .path = s.path, .line = s.line, .column = s.column }
    else
        .{ .path = "", .line = 0, .column = 0 };
    return .{
        .fqn = r.fqn,
        .package = r.package,
        .name = r.name,
        .kind = kind,
        .receiver = r.receiver,
        .signature = r.signature,
        .param_names = r.param_names,
        .modifiers = .{ .bits = r.modifiers.bits() },
        .source = source,
        .impl_fn = null,
    };
}

const testing = std.testing;

test "symbols decode into a non-empty registry" {
    const syms = stdlibSymbols();
    try testing.expect(syms.len != 0);
}

test "every entry carries a non-empty fqn" {
    for (stdlibSymbols()) |e| {
        try testing.expect(e.fqn.len != 0);
        try testing.expect(e.impl_fn == null);
    }
}
