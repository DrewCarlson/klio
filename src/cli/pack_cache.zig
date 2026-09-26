//! Pack cache and installed-pack loading: walk the cache, parse each pack the
//! user imports, consume the embedded stdlib's curated sources, and merge every
//! pack's host bindings into one table.

const std = @import("std");
const Allocator = std.mem.Allocator;

const span = @import("span");
const SourceMap = span.SourceMap;

const ast = @import("ast");
const KotlinFile = ast.KotlinFile;

const lexer = @import("lexer");
const parser = @import("parser");

const pack = @import("pack");
const schema = pack.schema;
const section_names = pack.section_names;
const PackReader = pack.PackReader;
const PackError = pack.PackError;

const runtime = @import("runtime");

const stdlib = @import("stdlib");
const HostBindings = stdlib.HostBindings;

const stdlib_pack = @import("stdlib_pack");

const kotlinx_atomicfu = @import("kotlinx_atomicfu");
const kotlinx_io = @import("kotlinx_io");
const kotlinx_datetime = @import("kotlinx_datetime");
const kotlinx_coroutines = @import("kotlinx_coroutines");
const kotlinx_serialization = @import("kotlinx_serialization");
const compose_runtime = @import("compose_runtime");
const compose_ui = @import("compose_ui");
const skiko = @import("skiko");
const interp_ir = @import("interp_ir");
const ktor_client = @import("ktor_client");

const io = @import("io.zig");
const qualified_refs = @import("qualified_refs.zig");

/// `library_id` -> requested features; defaults are added unless opted out.
pub const RequestedFeatures = std.StringHashMap(std.StringHashMap(void));

/// Parsed pack ASTs plus the table their `host_symbol` keys resolve against.
pub const LoadedPacks = struct {
    asts: []const KotlinFile,
    bindings: HostBindings,
    /// Parallel to `asts`: the library each file came from, `stdlib` for
    /// the embedded stdlib's. Empty when nothing loaded from the cache.
    lib_ids: []const []const u8 = &.{},
};

/// What the embedded-stdlib source load did. Strings owned by the loader.
pub const EmbeddedReport = struct {
    pkgs: std.ArrayList([]const u8) = .empty,
    any_non_implicit: bool = false,
    /// The gate the load used (true = the full curated set loaded).
    gate_full: bool = false,
    known_packages: std.ArrayList([]const u8) = .empty,
    binding_fqns: std.ArrayList([]const u8) = .empty,
    /// How many of the returned ASTs are the stdlib's, listed last.
    stdlib_asts: usize = 0,
    timing: ParseTiming = .{},
};

/// Where the embedded stdlib source load spent its time, in nanoseconds. The
/// per-file lex and parse figures are summed across every file (CPU time when
/// the files were parsed on a pool), the `lex_parse_wall` figure is the wall
/// time of that pass.
pub const ParseTiming = struct {
    /// Resolving and reading the source bundle.
    sources: u64 = 0,
    register: u64 = 0,
    lex: u64 = 0,
    parse: u64 = 0,
    lex_parse_wall: u64 = 0,
    /// The slowest single file's lex plus parse, and its size in bytes.
    longest: u64 = 0,
    longest_bytes: usize = 0,
    total: u64 = 0,
    files: usize = 0,
    threads: usize = 1,
    /// Pieces the large files were cut into, over all of them.
    pieces: usize = 0,
};

/// One selected pack, identified for cache keying: cache path, stored content
/// hash, resolved active feature names (sorted). Strings owned by the loader.
pub const SelectedPack = struct {
    path: []const u8,
    hash: [pack.format.HASH_LEN]u8,
    features: []const []const u8,
};

pub const Selection = struct {
    packs: std.ArrayList(SelectedPack) = .empty,
    /// The import-prefix universe at fixpoint end; the load gate reads it.
    final_prefixes: std.ArrayList([]const u8) = .empty,
};

pub const LoadOptions = struct {
    /// When false, only cache packs load; the caller supplies the lowered stdlib.
    include_stdlib: bool = true,
    /// Where the stdlib's sources register when not `source_map`: a build on
    /// top of the stdlib image stages the stdlib from a scratch map whose ids
    /// are the image's, and lowers only the packs, which register on
    /// `source_map` after the image's files.
    stdlib_map: ?*SourceMap = null,
    embedded_report: ?*EmbeddedReport = null,
    selection: ?*Selection = null,
    /// When false, an undecodable wanted pack is skipped without the warning.
    report_failures: bool = true,
    /// When false, the ASTs are dropped and a pack carrying the `imports`
    /// section skips parsing its sources.
    asts_needed: bool = true,
    /// When set, the only libraries an import may pull in: a project's declared
    /// dependencies. A pack the manifest does not name stays out however well
    /// its package matches, so what a project can use is what it says it uses.
    /// The set grows as packs load, since a declared dependency's own
    /// dependencies are equally declared. Null keeps the import-driven
    /// behaviour, which is what a loose file outside any project gets.
    declared_lib_ids: ?[]const []const u8 = null,
    /// Libraries never loaded from the cache, however the imports match. Running
    /// a library's own source passes its id here: the sources on the command
    /// line are that library, and loading the installed copy as well would
    /// declare every one of its declarations twice.
    exclude_lib_ids: []const []const u8 = &.{},
    /// Every installed pack with every feature, whatever the imports: what
    /// ships, as a census measures it.
    all: bool = false,
    /// Libraries that load by their own id whatever the imports, as a loaded
    /// pack's `[deps]` do: the dependencies a library's own sources declare,
    /// which they may name by qualified name alone.
    dep_lib_ids: []const []const u8 = &.{},
};

/// `ok` is an owned path, `err` an owned message; the caller frees whichever is set.
pub const PathResult = union(enum) {
    ok: []u8,
    err: []u8,
};

pub const VoidResult = union(enum) {
    ok: void,
    err: []u8,
};

pub const ManifestResult = union(enum) {
    ok: schema.PackManifest,
    err: []u8,
};


fn getEnvVar(allocator: Allocator, name: []const u8) ?[]u8 {
    return runtime.procEnvGetVar(allocator, name) catch null;
}

fn envVarPresent(allocator: Allocator, name: []const u8) bool {
    if (getEnvVar(allocator, name)) |v| {
        allocator.free(v);
        return true;
    }
    return false;
}

fn procEnvMap(allocator: Allocator) std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    runtime.procEnvPutAllInto(allocator, &map);
    return map;
}

fn threadedIo(allocator: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}


fn joinIdentPath(allocator: Allocator, path: []const ast.Ident) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (path, 0..) |id, i| {
        if (i != 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, id.name);
    }
    return buf.toOwnedSlice(allocator);
}

/// The dotted prefixes a user's files imply for the load gate: every `import`,
/// plus the package prefix of every package-rooted qualified reference, since
/// `kotlin.coroutines.Foo` used inline needs no import in Kotlin. Deinit with
/// `freeStringSet`.
fn collectUserImportPrefixes(
    allocator: Allocator,
    user_asts: []const KotlinFile,
) Allocator.Error!std.StringHashMap(void) {
    var out = std.StringHashMap(void).init(allocator);
    errdefer freeStringSet(&out);
    for (user_asts) |f| {
        for (f.imports) |imp| {
            const joined = try joinIdentPath(allocator, imp.path);
            const gop = try out.getOrPut(joined);
            if (gop.found_existing) {
                allocator.free(joined);
            } else {
                gop.value_ptr.* = {};
            }
        }
        // A file in package P implicitly sees all of P, so P joins the gate set.
        if (f.package) |pkg| {
            if (pkg.path.len != 0) {
                const joined = try joinIdentPath(allocator, pkg.path);
                const gop = try out.getOrPut(joined);
                if (gop.found_existing) {
                    allocator.free(joined);
                } else {
                    gop.value_ptr.* = {};
                }
            }
        }
    }
    try mergeQualifiedRefPrefixes(allocator, &out, user_asts);
    return out;
}

/// Qualified-reference prefixes of `user_asts`, owned; feeds the load gate.
pub fn collectQualifiedRefPrefixes(
    allocator: Allocator,
    user_asts: []const KotlinFile,
) Allocator.Error!std.StringHashMap(void) {
    return qualified_refs.collect(allocator, user_asts);
}

pub fn mergeQualifiedRefPrefixes(
    allocator: Allocator,
    out: *std.StringHashMap(void),
    user_asts: []const KotlinFile,
) Allocator.Error!void {
    var qrefs = try qualified_refs.collect(allocator, user_asts);
    defer freeStringSet(&qrefs);
    var it = qrefs.keyIterator();
    while (it.next()) |k| {
        const gop = try out.getOrPut(k.*);
        if (gop.found_existing) continue;
        gop.key_ptr.* = try allocator.dupe(u8, k.*);
        gop.value_ptr.* = {};
    }
}

/// Free a `StringHashMap(void)` whose keys are owned by its allocator.
fn freeStringSet(set: *std.StringHashMap(void)) void {
    var it = set.keyIterator();
    while (it.next()) |k| set.allocator.free(k.*);
    set.deinit();
}

fn packagePathOf(allocator: Allocator, file: KotlinFile) Allocator.Error![]u8 {
    if (file.package) |p| {
        return joinIdentPath(allocator, p.path);
    }
    return allocator.dupe(u8, "");
}


/// One source file registered on the SourceMap, awaiting its lex and parse.
/// The files are registered in bundle order before any is parsed, so FileIds
/// and the resulting AST order never depend on how the parse pass is
/// scheduled.
const ParseJob = struct {
    fid: span.FileId,
    src: []const u8,
    rel_path: []const u8,
    result: Result = .skipped,
    lex_ns: u64 = 0,
    parse_ns: u64 = 0,
    /// Set on a job that parses one piece of a chunked file.
    piece: ?Piece = null,
    /// For a chunked file, the slowest piece's parse: with the lex, its
    /// critical path.
    longest_piece_ns: u64 = 0,
    /// Pieces the file was cut into; zero when it parsed whole.
    pieces: usize = 0,

    const Result = union(enum) {
        /// An allocation failed; the file is dropped silently.
        skipped,
        /// The lexer reported errors; the diagnostic count.
        lex_errors: usize,
        /// The parser reported errors; it holds the diagnostics.
        parse_errors: *parser.Parser,
        ok: KotlinFile,
        /// The file's tokens were cut into this many pieces, each a job of
        /// its own appended to the pool; `lexed` owns the token strings the
        /// pieces borrow until they are assembled.
        pieces: struct { count: usize, lexed: lexer.LexResult },
    };

    /// An owned copy of a token range of the file, ending in `Eof`.
    const Piece = struct { of: usize, index: usize, tokens: []Token, strings: []const []const u8 };
};

const Token = lexer.Token;

/// A file at least this large parses in pieces: once lexed, its token stream
/// is cut at top-level declaration boundaries and each piece parses as a job
/// of its own alongside the other files, so the largest file no longer bounds
/// the wall of the whole parse. `_Arrays.kt` alone is a quarter of the stdlib.
const chunk_min_bytes: usize = 192 * 1024;
/// Source bytes a piece aims for.
const chunk_bytes: usize = 96 * 1024;

fn tokenIsTrivia(t: *const Token) bool {
    return switch (t.kind) {
        .Whitespace, .Newline, .LineComment, .BlockComment => true,
        else => false,
    };
}

/// A token that can open a top-level declaration: a modifier or keyword, a
/// name, or an annotation. After a `}` at depth zero and a newline nothing
/// else can follow at the top level, so a cut before one is a cut between
/// two declarations. `else`, `catch` and `finally` continue the expression
/// whose block just closed, in a property initialiser or an expression body.
fn tokenStartsDecl(t: *const Token, src: []const u8) bool {
    return switch (t.kind) {
        .Keyword => |k| k != .Else,
        .Ident => blk: {
            const text = src[t.span.start..t.span.end];
            break :blk !std.mem.eql(u8, text, "catch") and !std.mem.eql(u8, text, "finally");
        },
        .AtNoWs, .AtPostWs, .AtPreWs, .AtBothWs => true,
        else => false,
    };
}

/// Cut points into `tokens`: index `cuts[k]` starts piece `k+1`. Empty when
/// the file yields fewer than two pieces.
fn pieceCuts(allocator: Allocator, tokens: []const Token, src: []const u8) Allocator.Error![]usize {
    var cuts: std.ArrayList(usize) = .empty;
    errdefer cuts.deinit(allocator);
    var depth: usize = 0;
    var piece_start: u32 = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].kind) {
            .LParen, .LBracket, .LBrace => depth += 1,
            .RParen, .RBracket, .RBrace => depth -|= 1,
            else => continue,
        }
        if (tokens[i].kind != .RBrace or depth != 0) continue;
        var j = i + 1;
        var saw_newline = false;
        while (j < tokens.len and tokenIsTrivia(&tokens[j])) : (j += 1) {
            if (tokens[j].kind == .Newline) saw_newline = true;
        }
        if (j >= tokens.len or !saw_newline or !tokenStartsDecl(&tokens[j], src)) continue;
        if (tokens[j].span.start - piece_start < chunk_bytes) continue;
        try cuts.append(allocator, j);
        piece_start = tokens[j].span.start;
    }
    if (cuts.items.len == 0) {
        cuts.deinit(allocator);
        return &.{};
    }
    return cuts.toOwnedSlice(allocator);
}

/// The tokens of piece `[from, to)` with an `Eof` after them; the last piece
/// carries the file's own. A piece after the first opens with the newline
/// its cut followed, so a look at the token before a declaration finds one.
fn pieceTokens(allocator: Allocator, tokens: []const Token, from: usize, to: usize, fid: span.FileId) Allocator.Error![]Token {
    const last_is_eof = to == tokens.len;
    const lead: usize = @intFromBool(from != 0);
    const out = try allocator.alloc(Token, lead + to - from + @intFromBool(!last_is_eof));
    if (from != 0) {
        const at = tokens[from].span.start;
        out[0] = .{ .kind = .Newline, .span = span.Span.init(fid, at, at) };
    }
    @memcpy(out[lead .. lead + to - from], tokens[from..to]);
    if (!last_is_eof) {
        const end = tokens[to - 1].span.end;
        out[lead + to - from] = .{ .kind = .Eof, .span = span.Span.init(fid, end, end) };
    }
    return out;
}

/// Lex, parse and alias-expand one registered file. Per file the only shared
/// state is the allocator, so jobs may run on any thread.
fn runParseJob(allocator: Allocator, pool: ?*ParsePool, index: usize, job: *ParseJob) void {
    runParseJobIn(allocator, null, pool, index, job);
}

/// `runParseJob`, parsing a whole file in `scratch` when there is one and
/// keeping only its tree (`parser.parseMoved`).
fn runParseJobIn(allocator: Allocator, scratch: ?*std.heap.ArenaAllocator, pool: ?*ParsePool, index: usize, job: *ParseJob) void {
    const t0 = runtime.clockMonotonicNanos();
    if (scratch) |sa| {
        if (job.piece == null) {
            const moved = parser.parseMoved(allocator, sa, job.fid, job.src) catch return;
            if (moved) |tree| {
                var file_ast = tree;
                ast.expandFileClassAliases(allocator, &file_ast);
                job.parse_ns = runtime.clockMonotonicNanos() - t0;
                if (std.c.getenv("KLIO_PARSE_CHECK") != null) checkNamesInSource(job, &file_ast);
                job.result = .{ .ok = file_ast };
                return;
            }
        }
    }
    if (job.piece) |piece| {
        const p = parser.Parser.new(allocator, job.fid, job.src, piece.tokens, piece.strings);
        const file_ast = p.parseFile();
        job.parse_ns = runtime.clockMonotonicNanos() - t0;
        job.result = if (p.diagnostics.hasErrors()) .{ .parse_errors = p } else .{ .ok = file_ast };
        return;
    }
    var lx = lexer.Lexer.init(allocator, job.fid, job.src) catch return;
    var lexed = lx.tokenize() catch return;
    const t1 = runtime.clockMonotonicNanos();
    job.lex_ns = t1 - t0;
    if (lexed.diagnostics.hasErrors()) {
        job.result = .{ .lex_errors = lexed.diagnostics.diags().len };
        lexed.deinit(allocator);
        return;
    }
    if (pool != null and job.src.len >= chunk_min_bytes) {
        const count = pool.?.addPieces(index, lexed.tokens, lexed.strings);
        if (count >= 2) {
            job.result = .{ .pieces = .{ .count = count, .lexed = lexed } };
            return;
        }
    }
    const p = parser.Parser.new(allocator, job.fid, job.src, lexed.tokens, lexed.strings);
    var file_ast = p.parseFile();
    if (p.diagnostics.hasErrors()) {
        job.result = .{ .parse_errors = p };
        lexed.deinit(allocator);
        return;
    }
    lexed.deinit(allocator);
    ast.expandFileClassAliases(allocator, &file_ast);
    job.parse_ns = runtime.clockMonotonicNanos() - t1;
    if (std.c.getenv("KLIO_PARSE_CHECK") != null) checkNamesInSource(job, &file_ast);
    job.result = .{ .ok = file_ast };
}

const max_parse_workers: usize = 64;
/// The parser recurses per nesting level; the reservation is virtual until touched.
const parse_worker_stack: usize = 64 * 1024 * 1024;

/// Whether `a` may serve several threads at once: only the process allocators
/// that document it. A wrapped or arena allocator parses serially.
pub fn allocatorIsThreadSafe(a: Allocator) bool {
    return a.vtable == runtime.slab.allocator.vtable or
        a.vtable == std.heap.smp_allocator.vtable or
        a.vtable == std.heap.c_allocator.vtable or
        a.vtable == std.heap.page_allocator.vtable;
}

/// Threads for `n` parse jobs: one per CPU under the process-wide
/// `KLIO_MAX_WORKERS` ceiling, or `KLIO_PARSE_JOBS` outright.
fn parseWorkerCount(allocator: Allocator, n: usize) usize {
    if (n < 2 or !allocatorIsThreadSafe(allocator)) return 1;
    var want = std.Thread.getCpuCount() catch 1;
    if (getEnvVar(allocator, "KLIO_MAX_WORKERS")) |v| {
        defer allocator.free(v);
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch null) |cap| {
            if (cap >= 1) want = @min(want, cap);
        }
    }
    if (getEnvVar(allocator, "KLIO_PARSE_JOBS")) |v| {
        defer allocator.free(v);
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch null) |cap| {
            if (cap >= 1) want = cap;
        }
    }
    return @min(@min(want, n), max_parse_workers);
}

const ParsePool = struct {
    allocator: Allocator,
    /// The files, then the pieces appended while the pool runs. Reserved up
    /// front for every piece the large files can add, so an append never
    /// moves a job another thread is working on.
    jobs: *std.ArrayList(ParseJob),
    files: usize,
    /// File job indices in dispatch order: largest source first, so the
    /// longest file starts at once and the wall approaches the CPU-time share.
    order: []const usize,
    next: std.atomic.Value(usize) = .init(0),
    /// File jobs claimed and not yet finished; a worker out of work waits on
    /// these, since one of them may still cut a large file into pieces.
    inflight: std.atomic.Value(usize) = .init(0),
    lock: runtime.SpinMutex = .{},
    piece_next: usize = 0,
    /// Rung whenever pieces land or a file finishes; a worker with nothing
    /// to take parks on it rather than yielding in a loop.
    gate: runtime.EventGate = .{},

    fn signal(self: *ParsePool) void {
        self.gate.ring();
    }

    fn takePiece(self: *ParsePool) ?usize {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.files + self.piece_next >= self.jobs.items.len) return null;
        const i = self.files + self.piece_next;
        self.piece_next += 1;
        return i;
    }

    /// Cuts `lexed` into piece jobs for file job `of`; the count added.
    fn addPieces(self: *ParsePool, of: usize, lexed: []const Token, strings: []const []const u8) usize {
        const job = self.jobs.items[of];
        const cuts = pieceCuts(self.allocator, lexed, job.src) catch return 0;
        if (cuts.len == 0) return 0;
        defer self.allocator.free(cuts);
        if (std.c.getenv("KLIO_PARSE_CHECK") != null) {
            std.debug.print("[parse-check] {s}: {d} cuts\n", .{ job.rel_path, cuts.len });
            for (cuts) |c| {
                const at = lexed[c].span.start;
                const end = @min(job.src.len, at + 48);
                std.debug.print("[parse-check]   token {d} at byte {d}: `{s}`\n", .{ c, at, job.src[at..end] });
            }
        }
        self.lock.lock();
        defer self.lock.unlock();
        if (self.jobs.items.len + cuts.len + 1 > self.jobs.capacity) return 0;
        var from: usize = 0;
        var index: usize = 0;
        var k: usize = 0;
        while (k <= cuts.len) : (k += 1) {
            const to = if (k < cuts.len) cuts[k] else lexed.len;
            const tokens = pieceTokens(self.allocator, lexed, from, to, job.fid) catch break;
            self.jobs.appendAssumeCapacity(.{
                .fid = job.fid,
                .src = job.src,
                .rel_path = job.rel_path,
                .piece = .{ .of = of, .index = index, .tokens = tokens, .strings = strings },
            });
            index += 1;
            from = to;
        }
        self.signal();
        return index;
    }

    fn drain(self: *ParsePool) void {
        while (true) {
            const seen = self.gate.epochNow();
            if (self.takePiece()) |i| {
                runParseJob(self.allocator, self, i, &self.jobs.items[i]);
                continue;
            }
            const o = self.next.fetchAdd(1, .monotonic);
            if (o < self.order.len) {
                _ = self.inflight.fetchAdd(1, .monotonic);
                const i = self.order[o];
                runParseJob(self.allocator, self, i, &self.jobs.items[i]);
                _ = self.inflight.fetchSub(1, .release);
                self.signal();
                continue;
            }
            // Every file is claimed; pieces can still appear while one is lexing.
            if (self.inflight.load(.acquire) == 0) return;
            self.gate.waitFrom(seen, 2_000);
        }
    }

    fn worker(self: *ParsePool) void {
        defer runtime.slab.flushMagazines();
        self.drain();
    }

    fn largerFirst(jobs: []const ParseJob, x: usize, y: usize) bool {
        return jobs[x].src.len > jobs[y].src.len;
    }
};

/// Parses the files registered at `fids` in `map` as a pack's sources parse
/// when the pack loads into a run's arena: lexed, parsed whole, one after
/// another, and alias-expanded. By position, null for a file that does not
/// parse, which the loader skips.
pub fn parsePackSources(allocator: Allocator, map: *const SourceMap, fids: []const span.FileId) Allocator.Error![]?KotlinFile {
    var jobs: std.ArrayList(ParseJob) = .empty;
    defer jobs.deinit(allocator);
    for (fids) |fid| {
        const sf = map.get(fid);
        try jobs.append(allocator, .{ .fid = fid, .src = sf.source, .rel_path = sf.path });
    }
    _ = runParseJobsOn(allocator, &jobs, 1);
    const out = try allocator.alloc(?KotlinFile, fids.len);
    for (jobs.items[0..fids.len], out) |job, *o| o.* = switch (job.result) {
        .ok => |f| f,
        else => null,
    };
    return out;
}

/// Lex and parse every job, fanning out over a pool when the allocator can
/// serve one; the calling thread drains alongside. Returns the thread count.
fn runParseJobs(allocator: Allocator, jobs: *std.ArrayList(ParseJob)) usize {
    return runParseJobsOn(allocator, jobs, parseWorkerCount(allocator, jobs.items.len));
}

/// Pieces the files at least `chunk_min_bytes` long can add to the pool.
fn pieceCapacity(jobs: []const ParseJob) usize {
    var n: usize = 0;
    for (jobs) |*j| {
        if (j.src.len >= chunk_min_bytes) n += j.src.len / chunk_bytes + 2;
    }
    return n;
}

fn runParseJobsOn(allocator: Allocator, jobs: *std.ArrayList(ParseJob), want: usize) usize {
    const files = jobs.items.len;
    if (want <= 1) {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        for (jobs.items, 0..) |*job, i| runParseJobIn(allocator, &scratch, null, i, job);
        return 1;
    }
    const order = allocator.alloc(usize, files) catch {
        for (jobs.items, 0..) |*job, i| runParseJob(allocator, null, i, job);
        return 1;
    };
    defer allocator.free(order);
    jobs.ensureUnusedCapacity(allocator, pieceCapacity(jobs.items)) catch {
        for (jobs.items, 0..) |*job, i| runParseJob(allocator, null, i, job);
        return 1;
    };
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, @as([]const ParseJob, jobs.items), ParsePool.largerFirst);
    var pool = ParsePool{ .allocator = allocator, .jobs = jobs, .files = files, .order = order };
    var threads: [max_parse_workers]runtime.platform.Thread = undefined;
    var spawned: usize = 0;
    while (spawned + 1 < want) : (spawned += 1) {
        threads[spawned] = runtime.platform.Thread.spawn(
            .{ .stack_size = parse_worker_stack },
            ParsePool.worker,
            .{&pool},
        ) catch break;
    }
    pool.drain();
    for (threads[0..spawned]) |t| t.join();
    for (jobs.items[0..files], 0..) |*job, i| {
        if (job.result == .pieces) assemblePieces(allocator, jobs.items, i, job);
    }
    return spawned + 1;
}

/// Joins the parsed pieces of file job `index` into its `ok` result, or
/// parses the file whole again when a piece failed, so its diagnostics are
/// the ones a whole parse reports. Frees the pieces and the file's tokens.
fn assemblePieces(allocator: Allocator, jobs: []ParseJob, index: usize, job: *ParseJob) void {
    var info = job.result.pieces;
    defer info.lexed.deinit(allocator);
    job.pieces = info.count;
    var all_ok = true;
    var n_decls: usize = 0;
    var parse_ns: u64 = 0;
    for (jobs) |*pj| {
        const piece = pj.piece orelse continue;
        if (piece.of != index) continue;
        parse_ns += pj.parse_ns;
        job.longest_piece_ns = @max(job.longest_piece_ns, pj.parse_ns);
        switch (pj.result) {
            .ok => |f| n_decls += f.decls.len,
            else => all_ok = false,
        }
    }
    job.parse_ns = parse_ns;
    defer for (jobs) |*pj| {
        const piece = pj.piece orelse continue;
        if (piece.of == index) allocator.free(piece.tokens);
    };
    if (!all_ok) {
        job.result = .skipped;
        runParseJob(allocator, null, index, job);
        return;
    }
    const decls = allocator.alloc(ast.Decl, n_decls) catch {
        job.result = .skipped;
        return;
    };
    var file_ast: ?KotlinFile = null;
    var filled: usize = 0;
    var next_index: usize = 0;
    while (true) {
        var found = false;
        for (jobs) |*pj| {
            const piece = pj.piece orelse continue;
            if (piece.of != index or piece.index != next_index) continue;
            const f = pj.result.ok;
            if (file_ast == null) file_ast = f;
            @memcpy(decls[filled .. filled + f.decls.len], f.decls);
            filled += f.decls.len;
            allocator.free(f.decls);
            if (f.has_composable) file_ast.?.has_composable = true;
            // The piece is spent: a caller walking every job must not see it as a file.
            pj.result = .skipped;
            found = true;
            break;
        }
        if (!found) break;
        next_index += 1;
    }
    var out = file_ast.?;
    out.decls = decls;
    out.span = span.Span.init(job.fid, 0, @intCast(job.src.len));
    ast.expandFileClassAliases(allocator, &out);
    if (std.c.getenv("KLIO_PARSE_CHECK") != null) {
        checkPiecesAgainstWhole(allocator, job, &out);
        checkNamesInSource(job, &out);
    }
    job.result = .{ .ok = out };
}

/// `KLIO_PARSE_CHECK`: parse the file whole again and report the first
/// declaration whose span the piecewise parse got differently.
fn checkPiecesAgainstWhole(allocator: Allocator, job: *const ParseJob, pieced: *const KotlinFile) void {
    var lx = lexer.Lexer.init(allocator, job.fid, job.src) catch return;
    var lexed = lx.tokenize() catch return;
    defer lexed.deinit(allocator);
    const p = parser.Parser.new(allocator, job.fid, job.src, lexed.tokens, lexed.strings);
    const whole = p.parseFile();
    if (whole.decls.len != pieced.decls.len) {
        std.debug.print("[parse-check] {s}: {d} declarations whole, {d} in pieces\n", .{ job.rel_path, whole.decls.len, pieced.decls.len });
    }
    const n = @min(whole.decls.len, pieced.decls.len);
    for (whole.decls[0..n], pieced.decls[0..n], 0..) |*a, *b, i| {
        const sa = declSpan(a);
        const sb = declSpan(b);
        if (sa.start != sb.start or sa.end != sb.end or std.meta.activeTag(a.*) != std.meta.activeTag(b.*) or
            !std.mem.eql(u8, declName(a), declName(b)) or declShape(a) != declShape(b))
        {
            std.debug.print("[parse-check] {s}: declaration {d} differs: whole {s} `{s}` {d}..{d}, pieces {s} `{s}` {d}..{d}\n", .{
                job.rel_path, i, @tagName(a.*), declName(a), sa.start, sa.end, @tagName(b.*), declName(b), sb.start, sb.end,
            });
            return;
        }
    }
}

fn declName(d: *const ast.Decl) []const u8 {
    return switch (d.*) {
        .Function => |*f| f.name.name,
        .Property => |pr| pr.name.name,
        .Class => |*c| c.name.name,
        .Object => |*o| o.name.name,
        .TypeAlias => |*t| t.name.name,
    };
}

/// A coarse shape: parameter and member counts, whether a body is present.
fn declShape(d: *const ast.Decl) usize {
    return switch (d.*) {
        .Function => |*f| f.params.len * 4 + @as(usize, @intFromBool(f.body != null)) * 2 + @as(usize, @intFromBool(f.receiver_type != null)),
        .Property => |pr| @as(usize, @intFromBool(pr.init != null)) * 2 + @as(usize, @intFromBool(pr.getter != null)),
        .Class => |*c| c.members.len * 4 + c.primary_params.len,
        .Object => |*o| o.members.len,
        .TypeAlias => 0,
    };
}

/// `KLIO_PARSE_CHECK`: every declaration name must be a slice of the source.
fn checkNamesInSource(job: *const ParseJob, file: *const KotlinFile) void {
    const lo = @intFromPtr(job.src.ptr);
    const hi = lo + job.src.len;
    for (file.decls, 0..) |*d, i| {
        const n = declName(d);
        const a = @intFromPtr(n.ptr);
        if (n.len > job.src.len or a < lo or a + n.len > hi) {
            std.debug.print("[parse-check] {s}: declaration {d} ({s}) name outside the source: ptr {x} len {d}\n", .{ job.rel_path, i, @tagName(d.*), a, n.len });
        }
    }
}

fn declSpan(d: *const ast.Decl) span.Span {
    return switch (d.*) {
        .Function => |*f| f.span,
        .Property => |pr| pr.span,
        .Class => |*c| c.span,
        .Object => |*o| o.span,
        .TypeAlias => |*t| t.span,
    };
}

/// Consume the embedded stdlib pack's `SOURCES`. Only the Kotlin sources are
/// parsed and registered: `SYMBOLS` and `BINDINGS` are statically linked in and
/// the cache loop skips on-disk `stdlib*` packs. Gated on the user's imports.
fn loadEmbeddedStdlibSources(
    allocator: Allocator,
    user_import_prefixes: *const std.StringHashMap(void),
    source_map: *SourceMap,
    out_asts: *std.ArrayList(KotlinFile),
    out_bindings: *HostBindings,
    report: ?*EmbeddedReport,
) Allocator.Error!void {
    const t_start = runtime.clockMonotonicNanos();
    var timing: ParseTiming = .{};
    const asts_before = out_asts.items.len;
    defer if (report) |rep| {
        timing.total = runtime.clockMonotonicNanos() - t_start;
        rep.timing = timing;
        rep.stdlib_asts = out_asts.items.len - asts_before;
    };

    var env = procEnvMap(allocator);
    defer env.deinit();
    var err: PackError = undefined;
    var sources = (stdlib_pack.stdlibSources(allocator, &env, &err) catch return) orelse {
        // Every pack source failed; surface the builder's message now.
        io.printStderr(allocator, "error: stdlib sources unavailable: {f}\n", .{err});
        io.printStderr(allocator, "set KLIO_STDLIB_PACK to a stdlib .klio-pack, or run from a klio checkout\n", .{});
        return;
    };
    if (sources.files.len == 0) {
        sources.deinit();
        return;
    }
    // The map borrows every source and keeps the bundle's arena, so nothing
    // here copies the sources or indexes their lines.
    source_map.adopt(sources.arena) catch {
        sources.deinit();
        return;
    };
    timing.sources = runtime.clockMonotonicNanos() - t_start;

    const diag = envVarPresent(allocator, "KLIO_PACK_DIAG");

    // The curated set is interdependent: all of it loads, or none.
    const Parsed = struct { pkg: []u8, file: KotlinFile };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer {
        for (parsed.items) |p| allocator.free(p.pkg);
        parsed.deinit(allocator);
    }

    var jobs: std.ArrayList(ParseJob) = .empty;
    defer jobs.deinit(allocator);
    const t_register = runtime.clockMonotonicNanos();
    // `KLIO_TRACE_FILES`: the FileId every stdlib source registers under.
    const files_trace = std.c.getenv("KLIO_TRACE_FILES") != null;
    if (files_trace) std.debug.print("[file] node sizes: Expr {d} Stmt {d} Decl {d} Function {d} TypeRef {d} Ident {d}\n", .{ @sizeOf(ast.Expr), @sizeOf(ast.Stmt), @sizeOf(ast.Decl), @sizeOf(ast.Function), @sizeOf(ast.TypeRef), @sizeOf(ast.Ident) });
    for (sources.files) |sf| {
        // Sources whose interpreted declarations would shadow klio's intrinsics.
        if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
        const fid = source_map.addBorrowed(sf.rel_path, sf.bytes) catch continue;
        if (files_trace) std.debug.print("[file] {d} {s}\n", .{ fid.int(), sf.rel_path });
        jobs.append(allocator, .{
            .fid = fid,
            .src = source_map.get(fid).source,
            .rel_path = sf.rel_path,
        }) catch continue;
    }
    const t_parse = runtime.clockMonotonicNanos();
    timing.register = t_parse - t_register;
    timing.files = jobs.items.len;
    const file_jobs = jobs.items.len;
    timing.threads = runParseJobs(allocator, &jobs);
    timing.lex_parse_wall = runtime.clockMonotonicNanos() - t_parse;

    for (jobs.items[0..file_jobs]) |*job| {
        timing.lex += job.lex_ns;
        timing.parse += job.parse_ns;
        timing.pieces += job.pieces;
        const critical = job.lex_ns + if (job.longest_piece_ns != 0) job.longest_piece_ns else job.parse_ns;
        if (critical > timing.longest) {
            timing.longest = critical;
            timing.longest_bytes = job.src.len;
        }
        if (diag and (std.mem.find(u8, job.rel_path, "Maps.kt") != null or
            std.mem.find(u8, job.rel_path, "Sets.kt") != null))
        {
            io.printStderr(allocator, "[embed source] {s}\n", .{job.rel_path});
        }
        switch (job.result) {
            .skipped, .pieces => {},
            .lex_errors => |n| if (diag) {
                io.printStderr(allocator, "[embed lex err] {s}: {d} diags\n", .{ job.rel_path, n });
            },
            .parse_errors => |p| if (diag) {
                for (p.diagnostics.diags()) |d| {
                    io.printStderr(allocator, "[embed parse err] {s}: {s}\n", .{ job.rel_path, d.message });
                }
            },
            .ok => |file_ast| {
                const pkg = packagePathOf(allocator, file_ast) catch continue;
                parsed.append(allocator, .{ .pkg = pkg, .file = file_ast }) catch {
                    allocator.free(pkg);
                    continue;
                };
            },
        }
    }

    // Implicitly-imported packages are visible without an import, so always load.
    var any_non_implicit = false;
    for (parsed.items) |p| {
        if (p.pkg.len != 0 and !stdlib.isImplicitlyImportedPackage(p.pkg)) {
            any_non_implicit = true;
            break;
        }
    }
    var imported_match = false;
    for (parsed.items) |p| {
        if (p.pkg.len == 0) continue;
        if (importPrefixMatches(allocator, user_import_prefixes, p.pkg)) {
            imported_match = true;
            break;
        }
    }
    const load_gated = imported_match or !any_non_implicit;

    if (report) |rep| {
        rep.any_non_implicit = any_non_implicit;
        rep.gate_full = load_gated;
        var seen_pkgs = std.StringHashMap(void).init(allocator);
        defer seen_pkgs.deinit();
        for (parsed.items) |p| {
            if (p.pkg.len == 0) continue;
            const gop = try seen_pkgs.getOrPut(p.pkg);
            if (!gop.found_existing) try rep.pkgs.append(allocator, try allocator.dupe(u8, p.pkg));
        }
    }

    // An implicit file may import a gated package; close over that by fixpoint.
    var include = try allocator.alloc(bool, parsed.items.len);
    defer allocator.free(include);
    for (parsed.items, 0..) |p, i| {
        const is_implicit = p.pkg.len != 0 and stdlib.isImplicitlyImportedPackage(p.pkg);
        include[i] = is_implicit or load_gated;
    }
    var changed = true;
    while (changed) {
        changed = false;
        var internal_prefixes = std.StringHashMap(void).init(allocator);
        defer internal_prefixes.deinit();
        for (parsed.items, 0..) |p, i| {
            if (!include[i]) continue;
            for (p.file.imports) |imp| {
                if (imp.path.len == 0) continue;
                const upto: usize = if (imp.wildcard) imp.path.len else imp.path.len - 1;
                if (upto == 0) continue;
                var buf: std.ArrayList(u8) = .empty;
                for (imp.path[0..upto], 0..) |seg, k| {
                    if (k != 0) buf.append(allocator, '.') catch break;
                    buf.appendSlice(allocator, seg.name) catch break;
                }
                const key = buf.toOwnedSlice(allocator) catch continue;
                internal_prefixes.put(key, {}) catch allocator.free(key);
            }
        }
        defer {
            var it = internal_prefixes.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
        }
        for (parsed.items, 0..) |p, i| {
            if (include[i] or p.pkg.len == 0) continue;
            if (importPrefixMatches(allocator, &internal_prefixes, p.pkg)) {
                include[i] = true;
                changed = true;
            }
        }
    }
    for (parsed.items, 0..) |p, i| {
        if (!include[i]) continue;
        if (p.pkg.len != 0) {
            stdlib.registerKnownPackage(p.pkg);
            if (report) |rep| try rep.known_packages.append(allocator, try allocator.dupe(u8, p.pkg));
        }
        try out_asts.append(allocator, p.file);
    }

    // The curated klio actuals call internal helpers whose bodies are inert stubs.
    var merged = mergedHostBindings(allocator);
    defer merged.deinit();
    const platform_fqns = [_][]const u8{
        "kotlin.time.__klio_time_systemMillis",
        "kotlin.time.__klio_time_monotonicNanos",
        "kotlin.coroutines.__klio_co_newSlot",
        "kotlin.coroutines.__klio_co_park",
        "kotlin.coroutines.__klio_co_resume",
        "kotlin.coroutines.__klio_co_runRoot",
        "kotlin.coroutines.__klio_co_lastRootParkedOnce",
    };
    for (platform_fqns) |fqn| {
        if (merged.resolve(fqn)) |f| {
            try out_bindings.register(fqn, f);
            if (report) |rep| try rep.binding_fqns.append(allocator, try allocator.dupe(u8, fqn));
        }
    }
}

/// Whether a `[deps]` entry names an installed pack rather than the embedded
/// standard library.
fn isPackDependency(library_id: []const u8) bool {
    return !std.mem.eql(u8, library_id, "stdlib");
}

/// Bidirectional dotted-prefix match: `imp == pkg`, or either starts with the other plus a dot.
pub fn importPrefixMatches(
    allocator: Allocator,
    prefixes: *const std.StringHashMap(void),
    pkg: []const u8,
) bool {
    var it = prefixes.keyIterator();
    while (it.next()) |imp_ptr| {
        const imp = imp_ptr.*;
        if (std.mem.eql(u8, imp, pkg)) return true;
        if (dottedPrefix(allocator, pkg, imp)) return true;
        if (dottedPrefix(allocator, imp, pkg)) return true;
    }
    return false;
}

fn dottedPrefix(allocator: Allocator, s: []const u8, prefix: []const u8) bool {
    _ = allocator;
    if (s.len <= prefix.len) return false;
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    return s[prefix.len] == '.';
}


const PackCandidate = struct {
    /// The pack by its header: its manifest cost a few hundred bytes to read,
    /// and a program that selects it reads the sections it needs by position.
    pack: pack.LazyPack,
    manifest: schema.PackManifest,
    path: []u8,

    fn deinit(self: *PackCandidate, allocator: Allocator) void {
        self.manifest.deinit(allocator);
        self.pack.deinit();
        allocator.free(self.path);
    }
};

/// An installed `.klio-pack` that failed to decode, kept so the loader can name it.
const FailedPack = struct {
    path: []u8,
    msg: []u8,

    fn deinit(self: *FailedPack, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.msg);
    }
};

/// The library id an installed pack was named for. Installed packs are named
/// `<library_id>-<version>.klio-pack`, the version starting at the first dash
/// followed by a digit. Null when the name breaks the convention.
fn packLibIdFromBasename(basename: []const u8) ?[]const u8 {
    const stem = if (std.mem.endsWith(u8, basename, ".klio-pack"))
        basename[0 .. basename.len - ".klio-pack".len]
    else
        basename;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, stem, i, '-')) |dash| {
        if (dash + 1 < stem.len and std.ascii.isDigit(stem[dash + 1])) {
            return if (dash == 0) null else stem[0..dash];
        }
        i = dash + 1;
    }
    return null;
}

/// Decode every `.klio-pack` manifest in the cache, skipping the embedded
/// stdlib. Caller-owned; a file that fails to decode joins `failures`.
fn collectPackCandidates(allocator: Allocator, cache: []const u8, failures: *std.ArrayList(FailedPack)) Allocator.Error![]PackCandidate {
    var candidates: std.ArrayList(PackCandidate) = .empty;
    errdefer {
        for (candidates.items) |*c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch
        return candidates.toOwnedSlice(allocator);
    defer dir.close(fio);
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        if (std.mem.startsWith(u8, entry.name, "stdlib")) continue;
        const path = try std.fs.path.join(allocator, &.{ cache, entry.name });
        var keep_path = false;
        defer if (!keep_path) allocator.free(path);
        var err: PackError = undefined;
        var reader = ((pack.LazyPack.fromPath(allocator, path, &err) catch continue) orelse {
            try appendFailure(allocator, failures, path, "{f}", .{err});
            continue;
        });
        const payload = (reader.readSection(section_names.MANIFEST, &err) catch {
            reader.deinit();
            continue;
        }) orelse {
            try appendFailure(allocator, failures, path, "the manifest section is missing or unreadable", .{});
            reader.deinit();
            continue;
        };
        const manifest = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch {
            payload.deinit(allocator);
            reader.deinit();
            continue;
        }) orelse {
            try appendFailure(allocator, failures, path, "the manifest failed to decode", .{});
            payload.deinit(allocator);
            reader.deinit();
            continue;
        };
        payload.deinit(allocator);
        keep_path = true;
        try candidates.append(allocator, .{ .pack = reader, .manifest = manifest, .path = path });
    }
    return candidates.toOwnedSlice(allocator);
}

fn appendFailure(
    allocator: Allocator,
    failures: *std.ArrayList(FailedPack),
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(msg);
    const path_dup = try allocator.dupe(u8, path);
    try failures.append(allocator, .{ .path = path_dup, .msg = msg });
}

/// Whether `pat`, a pack-root-relative prefix, covers `rel_path`: the path is
/// the prefix itself or a file under it.
fn prefixCovers(rel_path: []const u8, pat_raw: []const u8) bool {
    const pat = std.mem.trimEnd(u8, pat_raw, "/");
    if (std.mem.eql(u8, rel_path, pat)) return true;
    return rel_path.len > pat.len and std.mem.startsWith(u8, rel_path, pat) and rel_path[pat.len] == '/';
}

/// The length of the longest prefix in `sources` covering `rel_path`, null
/// when none does.
fn featureMatchLen(rel_path: []const u8, sources: [][]const u8) ?usize {
    var best: ?usize = null;
    for (sources) |pat_raw| {
        if (!prefixCovers(rel_path, pat_raw)) continue;
        const n = std.mem.trimEnd(u8, pat_raw, "/").len;
        if (best == null or n > best.?) best = n;
    }
    return best;
}

/// Whether `rel_path` falls under any of `sources`, each a pack-root-relative prefix.
fn sourceInFeature(rel_path: []const u8, sources: [][]const u8) bool {
    return featureMatchLen(rel_path, sources) != null;
}

/// The most specific claim on `rel_path`: the longest prefix any feature's
/// `sources` covers it by. A file claimed by several features belongs to the
/// ones whose matching prefix has this length, so `klioMain` can be one
/// module's root while `klioMain/kotlinx/coroutines/test` is another's.
fn gateLen(rel_path: []const u8, manifest: *const schema.PackManifest) ?usize {
    var best: ?usize = null;
    for (manifest.features) |f| {
        const n = featureMatchLen(rel_path, f.sources) orelse continue;
        if (best == null or n > best.?) best = n;
    }
    return best;
}

/// Defaults (unless opted out) plus requested features, expanded over `requires`.
fn resolveActiveFeatures(
    allocator: Allocator,
    manifest: *const schema.PackManifest,
    requested: ?*const std.StringHashMap(void),
) Allocator.Error!std.StringHashMap(void) {
    var active = std.StringHashMap(void).init(allocator);
    errdefer active.deinit();
    for (manifest.default_features) |f| {
        try active.put(f, {});
    }
    if (requested) |req| {
        var it = req.keyIterator();
        while (it.next()) |k| try active.put(k.*, {});
    }
    // Transitively pull in `requires` until the set stops growing.
    while (true) {
        var added = false;
        for (manifest.features) |f| {
            if (active.contains(f.name)) {
                for (f.requires) |r| {
                    const gop = try active.getOrPut(r);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = {};
                        added = true;
                    }
                }
            }
        }
        if (!added) break;
    }
    return active;
}

/// A file gated by a feature needs it active; an ungated core file always
/// loads. Only the most specific claim gates: a file under both `klioMain`
/// (core) and `klioMain/kotlinx/coroutines/test` (test) loads with `test`.
fn sourceIsActive(
    rel_path: []const u8,
    manifest: *const schema.PackManifest,
    active: *const std.StringHashMap(void),
) bool {
    const n = gateLen(rel_path, manifest) orelse return true;
    for (manifest.features) |f| {
        if (featureMatchLen(rel_path, f.sources) != n) continue;
        if (active.contains(f.name)) return true;
    }
    return false;
}

/// The first feature gating an inactive file, to hint what to enable. Borrows `manifest`.
const Gate = struct { feature: []const u8, prefix: []const u8 };

fn inactiveGate(
    rel_path: []const u8,
    manifest: *const schema.PackManifest,
    active: *const std.StringHashMap(void),
) ?Gate {
    if (sourceIsActive(rel_path, manifest, active)) return null;
    const n = gateLen(rel_path, manifest) orelse return null;
    for (manifest.features) |f| {
        for (f.sources) |pat_raw| {
            const p = std.mem.trimEnd(u8, pat_raw, "/");
            if (p.len == n and prefixCovers(rel_path, pat_raw)) {
                return .{ .feature = f.name, .prefix = p };
            }
        }
    }
    return null;
}

/// The first `package a.b.c` in a source file, for the feature hint. Borrows `bytes`.
fn packageOfSource(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "package ")) {
            var rest = std.mem.trim(u8, t["package ".len..], " \t\r");
            rest = std.mem.trimEnd(u8, rest, ";");
            rest = std.mem.trim(u8, rest, " \t\r");
            return rest;
        }
    }
    return null;
}

/// Whether an import names a package or a member of it. A parent star-import does not.
fn importMatchesPackage(allocator: Allocator, import: []const u8, pkg: []const u8) bool {
    if (pkg.len == 0) return false;
    if (std.mem.eql(u8, import, pkg)) return true;
    return dottedPrefix(allocator, import, pkg);
}

const FeatureHint = struct {
    lib: []u8,
    feat: []u8,
    pkg: []u8,

    fn deinit(self: FeatureHint, allocator: Allocator) void {
        allocator.free(self.lib);
        allocator.free(self.feat);
        allocator.free(self.pkg);
    }
};

/// Load one candidate: register its packages, parse its sources or frozen AST
/// bundle, wire its bindings, and append discovered imports to `new_imports`.
fn loadPackCandidate(
    allocator: Allocator,
    c: *const PackCandidate,
    lib_id: []const u8,
    merged: *const HostBindings,
    active_features: *const std.StringHashMap(void),
    user_imports: *const std.StringHashMap(void),
    feature_hints: *std.ArrayList(FeatureHint),
    source_map: *SourceMap,
    out_asts: *std.ArrayList(KotlinFile),
    out_bindings: *HostBindings,
    new_imports: *std.ArrayList([]u8),
    asts_needed: bool,
) Allocator.Error!void {
    const manifest = &c.manifest;
    const reader = &c.pack;
    // Every package this pack ships or declares implicit, so `import x.*` resolves.
    stdlib.registerKnownPackage(manifest.library_id);
    for (manifest.implicit_packages) |p| {
        stdlib.registerKnownPackage(p);
    }
    var loaded_from_sources = false;
    var err: PackError = undefined;
    // Served from the precomputed `imports` section when the pack carries one.
    if (!asts_needed) {
        if (reader.readSection(section_names.IMPORTS, &err) catch null) |payload| {
            defer payload.deinit(allocator);
            if (schema.decode(schema.ImportsBundle, allocator, payload.slice(), &err) catch null) |bundle_val| {
                var bundle = bundle_val;
                defer bundle.deinit(allocator);
                loaded_from_sources = true;
                for (bundle.files) |imf| {
                    if (stdlib.isConsumptionDeferredSource(imf.rel_path)) continue;
                    if (!sourceIsActive(imf.rel_path, manifest, active_features)) {
                        if (inactiveGate(imf.rel_path, manifest, active_features)) |gate| {
                            if (imf.pkg.len != 0) {
                                var imp_it = user_imports.keyIterator();
                                var matched = false;
                                while (imp_it.next()) |imp| {
                                    if (importMatchesPackage(allocator, imp.*, imf.pkg)) {
                                        matched = true;
                                        break;
                                    }
                                }
                                if (matched) {
                                    feature_hints.append(allocator, .{
                                        .lib = try allocator.dupe(u8, lib_id),
                                        .feat = try allocator.dupe(u8, gate.feature),
                                        .pkg = try allocator.dupe(u8, imf.pkg),
                                    }) catch {};
                                }
                            }
                        }
                        continue;
                    }
                    if (imf.pkg.len != 0) stdlib.registerKnownPackage(imf.pkg);
                    for (imf.imports) |imp| {
                        const joined = allocator.dupe(u8, imp) catch continue;
                        new_imports.append(allocator, joined) catch allocator.free(joined);
                    }
                }
            }
        }
        if (loaded_from_sources) {
            try readPackBindings(allocator, reader, lib_id, merged, out_bindings);
            return;
        }
    }
    // Re-parse through the shared SourceMap rather than decoding the frozen
    // `ast` section: fresh FileIds never collide, and it survives schema drift.
    // The frozen bundle serves only when `sources` is absent. The section and
    // its bundle are read into a heap of their own and freed here, whatever
    // `allocator` is: the map keeps its own copy of each file's text.
    var transient = reader.*;
    transient.allocator = std.heap.smp_allocator;
    if (transient.readSection(section_names.SOURCES, &err) catch null) |payload| {
        defer payload.deinit(transient.allocator);
        if (schema.decode(schema.SourceBundle, transient.allocator, payload.slice(), &err) catch null) |bundle_val| {
            var bundle = bundle_val;
            defer bundle.deinit(transient.allocator);
            var jobs: std.ArrayList(ParseJob) = .empty;
            defer jobs.deinit(allocator);
            for (bundle.files) |sf| {
                if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
                // A source under an inactive feature's roots is skipped; record
                // a hint when a user import targets that gated package.
                if (!sourceIsActive(sf.rel_path, manifest, active_features)) {
                    if (inactiveGate(sf.rel_path, manifest, active_features)) |gate| {
                        if (packageOfSource(sf.bytes)) |pkg| {
                            var imp_it = user_imports.keyIterator();
                            var matched = false;
                            while (imp_it.next()) |imp| {
                                if (importMatchesPackage(allocator, imp.*, pkg)) {
                                    matched = true;
                                    break;
                                }
                            }
                            if (matched) {
                                feature_hints.append(allocator, .{
                                    .lib = try allocator.dupe(u8, lib_id),
                                    .feat = try allocator.dupe(u8, gate.feature),
                                    .pkg = try allocator.dupe(u8, pkg),
                                }) catch {};
                            }
                        }
                    }
                    continue;
                }
                const fid = source_map.add(sf.rel_path, sf.bytes) catch continue;
                jobs.append(allocator, .{
                    .fid = fid,
                    .src = source_map.get(fid).source,
                    .rel_path = sf.rel_path,
                }) catch continue;
            }
            _ = runParseJobs(allocator, &jobs);
            for (jobs.items) |job| {
                const file_ast = switch (job.result) {
                    .ok => |f| f,
                    else => continue,
                };
                if (file_ast.package) |pkg| {
                    const path = joinIdentPath(allocator, pkg.path) catch continue;
                    defer allocator.free(path);
                    if (path.len != 0) stdlib.registerKnownPackage(path);
                }
                for (file_ast.imports) |imp| {
                    const joined = joinIdentPath(allocator, imp.path) catch continue;
                    new_imports.append(allocator, joined) catch allocator.free(joined);
                }
                try out_asts.append(allocator, file_ast);
                loaded_from_sources = true;
            }
        }
    }
    if (!loaded_from_sources) {
        if (reader.readSection(section_names.AST, &err) catch null) |payload| {
            defer payload.deinit(allocator);
            if (schema.decode(schema.AstBundle, allocator, payload.slice(), &err) catch null) |ast_bundle_val| {
                const ast_bundle = ast_bundle_val;
                // The KotlinFiles outlive the bundle; free only its spine.
                defer {
                    for (ast_bundle.files) |*f| allocator.free(f.rel_path);
                    allocator.free(ast_bundle.files);
                }
                // Frozen spans carry pack-build-local FileIds, dense from 0,
                // which collide with the run map. Rebase before lowering.
                const src_payload = reader.readSection(section_names.SOURCES, &err) catch null;
                defer if (src_payload) |sp| sp.deinit(allocator);
                var src_bundle: ?schema.SourceBundle = if (src_payload) |sp|
                    schema.decode(schema.SourceBundle, allocator, sp.slice(), &err) catch null
                else
                    null;
                defer if (src_bundle) |*sb| sb.deinit(allocator);
                var src_by_path = std.StringHashMap([]const u8).init(allocator);
                defer src_by_path.deinit();
                if (src_bundle) |sb| {
                    for (sb.files) |sf| src_by_path.put(sf.rel_path, sf.bytes) catch {};
                }
                const dbg = envVarPresent(allocator, "KLIO_AST_REBASE_TRACE");
                for (ast_bundle.files) |*f| {
                    const old_fid = f.kotlin_file.span.file;
                    const src = src_by_path.get(f.rel_path) orelse "";
                    if (source_map.add(f.rel_path, src) catch null) |new_fid| {
                        rebaseFileSpans(&f.kotlin_file, old_fid, new_fid);
                        if (dbg) io.printStderr(allocator, "[ast-rebase] {s}: {d} -> {d}\n", .{ f.rel_path, old_fid.int(), new_fid.int() });
                    }
                }
                for (ast_bundle.files) |f| {
                    if (f.kotlin_file.package) |pkg| {
                        const path = joinIdentPath(allocator, pkg.path) catch continue;
                        defer allocator.free(path);
                        if (path.len != 0) stdlib.registerKnownPackage(path);
                    }
                    for (f.kotlin_file.imports) |imp| {
                        const joined = joinIdentPath(allocator, imp.path) catch continue;
                        new_imports.append(allocator, joined) catch allocator.free(joined);
                    }
                    try out_asts.append(allocator, f.kotlin_file);
                }
            }
        }
    }
    try readPackBindings(allocator, reader, lib_id, merged, out_bindings);
}

/// `reader` is a `PackReader` or a `LazyPack`; both read a section by name.
fn readPackBindings(
    allocator: Allocator,
    reader: anytype,
    lib_id: []const u8,
    merged: *const HostBindings,
    out_bindings: *HostBindings,
) Allocator.Error!void {
    var err: PackError = undefined;
    if (reader.readSection(section_names.BINDINGS, &err) catch null) |payload| {
        defer payload.deinit(allocator);
        if (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch null) |bm_val| {
            var bm = bm_val;
            defer bm.deinit(allocator);
            for (bm.bindings) |b| {
                if (merged.resolve(b.host_symbol)) |f| {
                    // `bm` is freed here, so the FQN dup is leaked; load is one-shot.
                    const leaked = allocator.dupe(u8, b.fqn) catch continue;
                    try out_bindings.register(leaked, f);
                }
            }
        }
    }
    // A merged binding under the pack's library_id but absent from the manifest
    // still applies, so a newer host entry needs no pack rebuild.
    const lib_prefix = std.fmt.allocPrint(allocator, "{s}.", .{lib_id}) catch return;
    defer allocator.free(lib_prefix);
    var entry_it = merged.table.iterator();
    while (entry_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, lib_prefix)) {
            try out_bindings.register(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

/// Rebase every span in a frozen-AST file from its pack-build-local FileId to
/// the run's. Spans that do not carry `old` are left alone.
fn rebaseFileSpans(file: *KotlinFile, old: span.FileId, new: span.FileId) void {
    if (old == new) return;
    walkSpans(KotlinFile, file, old, new);
}

/// Recursive reflection walk mirroring the decoder's type coverage; every
/// reachable `span.Span` with file id `old` is retargeted. The decoder freshly
/// allocated the tree, so casting away const is sound.
fn walkSpans(comptime T: type, value: *T, old: span.FileId, new: span.FileId) void {
    if (comptime T == span.Span) {
        if (value.file == old) value.file = new;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime s.layout == .@"packed") return;
            inline for (s.fields) |f| {
                if (comptime !f.is_comptime) {
                    walkSpans(f.type, &@field(value.*, f.name), old, new);
                }
            }
        },
        .optional => |o| {
            if (value.*) |*inner| walkSpans(o.child, inner, old, new);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return;
                for (@constCast(value.*)) |*item| walkSpans(p.child, item, old, new);
            },
            .one => walkSpans(p.child, @constCast(value.*), old, new),
            else => {},
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            switch (value.*) {
                inline else => |*payload| walkSpans(@TypeOf(payload.*), payload, old, new),
            }
        },
        else => {},
    }
}


/// Walk the pack cache, parse each pack's sources, and build the `HostBindings`
/// the packs declare. The caller prepends the returned ASTs to the user's list
/// before lowering. Only packs the user imports, directly or transitively, load.
/// `requested_features` maps a `library_id` to the features a consumer asked
/// for; feature-gated source roots load only when active.
pub fn loadInstalledPacks(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
) LoadedPacks {
    return loadInstalledPacksOpts(gpa, user_asts, source_map, requested_features, .{});
}

/// `loadInstalledPacks` with the stdlib-image knobs.
pub fn loadInstalledPacksOpts(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
    opts: LoadOptions,
) LoadedPacks {
    return loadInstalledPacksImpl(gpa, user_asts, source_map, requested_features, opts) catch .{
        .asts = &.{},
        .bindings = mergedHostBindings(gpa),
    };
}

fn loadInstalledPacksImpl(
    gpa: Allocator,
    user_asts: []const KotlinFile,
    source_map: *SourceMap,
    requested_features: *const RequestedFeatures,
    opts: LoadOptions,
) Allocator.Error!LoadedPacks {
    var out_asts: std.ArrayList(KotlinFile) = .empty;
    errdefer out_asts.deinit(gpa);
    var out_libs: std.ArrayList([]const u8) = .empty;
    errdefer out_libs.deinit(gpa);
    var out_bindings = mergedHostBindingsInit(gpa);
    errdefer out_bindings.deinit();

    var user_import_prefixes = try collectUserImportPrefixes(gpa, user_asts);
    defer freeStringSet(&user_import_prefixes);

    // Consumed after the cache walk, so a loaded pack importing one of those
    // packages triggers the load too.
    const cache_res = klioCacheDir(gpa);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| {
            gpa.free(e);
            if (opts.include_stdlib) {
                try loadEmbeddedStdlibSources(gpa, &user_import_prefixes, opts.stdlib_map orelse source_map, &out_asts, &out_bindings, opts.embedded_report);
            }
            return .{ .asts = try out_asts.toOwnedSlice(gpa), .bindings = out_bindings };
        },
    };
    defer gpa.free(cache);

    // KLIO_PACK_TRACE: one line per pack the program loads.
    const pack_trace = envVarPresent(gpa, "KLIO_PACK_TRACE");
    var merged = mergedHostBindings(gpa);
    defer merged.deinit();

    // Fixed point: each pass loads packs whose `library_id` matches a known
    // import prefix, and the ASTs it loads contribute imports for the next pass.
    var failed_packs: std.ArrayList(FailedPack) = .empty;
    defer {
        for (failed_packs.items) |*f| f.deinit(gpa);
        failed_packs.deinit(gpa);
    }
    const candidates = try collectPackCandidates(gpa, cache, &failed_packs);
    defer {
        for (candidates) |*c| c.deinit(gpa);
        gpa.free(candidates);
    }

    // known_prefixes owns its keys.
    var known_prefixes = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&known_prefixes);
    {
        var it = user_import_prefixes.keyIterator();
        while (it.next()) |k| {
            const dup = try gpa.dupe(u8, k.*);
            const gop = try known_prefixes.getOrPut(dup);
            if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
        }
    }

    var loaded_lib_ids = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&loaded_lib_ids);
    // The library ids loaded packs declare in `[deps]`: each loads by its own
    // id, where an import prefix also reaches the packs nested under it.
    var dep_ids = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&dep_ids);
    for (opts.dep_lib_ids) |id| {
        if (!isPackDependency(id) or dep_ids.contains(id)) continue;
        try dep_ids.put(try gpa.dupe(u8, id), {});
    }

    var declared = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&declared);
    if (opts.declared_lib_ids) |ids| {
        for (ids) |id| {
            const dup = try gpa.dupe(u8, id);
            const gop = try declared.getOrPut(dup);
            if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
        }
    }
    const restrict = opts.declared_lib_ids != null;
    // An excluded library reads as already loaded, so no pass picks it up.
    for (opts.exclude_lib_ids) |id| {
        const dup = try gpa.dupe(u8, id);
        const gop = try loaded_lib_ids.getOrPut(dup);
        if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
    }

    // Feature requests accumulate across passes: the CLI seed plus pack deps.
    var feature_reqs = try cloneRequestedFeatures(gpa, requested_features);
    defer deinitRequestedFeatures(&feature_reqs);
    if (opts.all) for (candidates) |*c| {
        const lib_id = c.manifest.library_id;
        const dup = try gpa.dupe(u8, lib_id);
        const gop = try known_prefixes.getOrPut(dup);
        if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
        const names = try gpa.alloc([]const u8, c.manifest.features.len);
        defer gpa.free(names);
        for (c.manifest.features, names) |f, *n| n.* = f.name;
        try addFeatureSlice(gpa, &feature_reqs, lib_id, names);
    };

    var feature_hints: std.ArrayList(FeatureHint) = .empty;
    defer {
        for (feature_hints.items) |h| h.deinit(gpa);
        feature_hints.deinit(gpa);
    }

    // Feature fixed point over manifests before any pack loads: otherwise a
    // directly imported pack loads before another pack's manifest has recorded
    // its feature request, making the chain depend on directory order.
    {
        var pre_wanted = std.StringHashMap(void).init(gpa);
        defer freeStringSet(&pre_wanted);
        var pre_prefixes = std.StringHashMap(void).init(gpa);
        defer freeStringSet(&pre_prefixes);
        var pre_deps = std.StringHashMap(void).init(gpa);
        defer freeStringSet(&pre_deps);
        {
            var it = dep_ids.keyIterator();
            while (it.next()) |k| try pre_deps.put(try gpa.dupe(u8, k.*), {});
        }
        {
            var it = known_prefixes.keyIterator();
            while (it.next()) |k| {
                const dup = try gpa.dupe(u8, k.*);
                const gop = try pre_prefixes.getOrPut(dup);
                if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
            }
        }
        var changed = true;
        while (changed) {
            changed = false;
            for (candidates) |*c| {
                const lib_id = c.manifest.library_id;
                if (restrict and !declared.contains(lib_id)) continue;
                if (!pre_deps.contains(lib_id) and !importPrefixMatches(gpa, &pre_prefixes, lib_id)) continue;
                // The contribution loop below is idempotent, so re-visiting is safe.
                if (!pre_wanted.contains(lib_id)) {
                    const dup = try gpa.dupe(u8, lib_id);
                    const gop = try pre_wanted.getOrPut(dup);
                    if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
                    changed = true;
                }
                var active = try resolveActiveFeatures(gpa, &c.manifest, feature_reqs.getPtr(lib_id));
                defer active.deinit();
                for (c.manifest.features) |f| {
                    if (!active.contains(f.name)) continue;
                    for (f.deps) |dep| {
                        const lib = if (std.mem.findScalar(u8, dep, '/')) |slash| dep[0..slash] else dep;
                        if (!pre_prefixes.contains(lib)) {
                            const dup = try gpa.dupe(u8, lib);
                            const gop = try pre_prefixes.getOrPut(dup);
                            if (gop.found_existing) gpa.free(dup) else gop.value_ptr.* = {};
                            changed = true;
                        }
                        // A feature's dependency is as declared as a `[deps]` entry.
                        if (restrict and !declared.contains(lib)) {
                            try declared.put(try gpa.dupe(u8, lib), {});
                            changed = true;
                        }
                        if (std.mem.findScalar(u8, dep, '/')) |slash| {
                            if (try addFeatureReqsChanged(gpa, &feature_reqs, dep[0..slash], dep[slash + 1 ..])) changed = true;
                        }
                    }
                }
                for (c.manifest.dependencies) |dep| {
                    if (restrict) {
                        const dep_dup = gpa.dupe(u8, dep.library_id) catch continue;
                        const dep_gop = declared.getOrPut(dep_dup) catch continue;
                        if (dep_gop.found_existing) gpa.free(dep_dup) else dep_gop.value_ptr.* = {};
                    }
                    // A declared dependency loads with the pack that declares it.
                    if (isPackDependency(dep.library_id) and !pre_deps.contains(dep.library_id)) {
                        try pre_deps.put(try gpa.dupe(u8, dep.library_id), {});
                        changed = true;
                    }
                    if (dep.features.len != 0) {
                        if (try addFeatureSliceChanged(gpa, &feature_reqs, dep.library_id, dep.features)) changed = true;
                    }
                }
            }
        }
    }

    while (true) {
        var progressed = false;
        var new_imports: std.ArrayList([]u8) = .empty;
        defer {
            for (new_imports.items) |s| gpa.free(s);
            new_imports.deinit(gpa);
        }
        var new_prefixes: std.ArrayList([]u8) = .empty;
        defer {
            for (new_prefixes.items) |s| gpa.free(s);
            new_prefixes.deinit(gpa);
        }
        var new_deps: std.ArrayList([]u8) = .empty;
        defer {
            for (new_deps.items) |s| gpa.free(s);
            new_deps.deinit(gpa);
        }

        for (candidates) |*c| {
            const lib_id = c.manifest.library_id;
            if (loaded_lib_ids.contains(lib_id)) continue;
            if (restrict and !declared.contains(lib_id)) continue;
            const wanted = dep_ids.contains(lib_id) or importPrefixMatches(gpa, &known_prefixes, lib_id);
            if (!wanted) continue;
            const lib_dup = try gpa.dupe(u8, lib_id);
            const gop = try loaded_lib_ids.getOrPut(lib_dup);
            if (gop.found_existing) gpa.free(lib_dup) else gop.value_ptr.* = {};
            progressed = true;
            if (pack_trace) io.printStderr(gpa, "[pack-load] {s} {s}\n", .{ lib_id, c.path });

            var active = try resolveActiveFeatures(gpa, &c.manifest, feature_reqs.getPtr(lib_id));
            defer active.deinit();

            if (opts.selection) |sel| {
                var feats = try gpa.alloc([]const u8, active.count());
                var fit = active.keyIterator();
                var fi: usize = 0;
                while (fit.next()) |f| : (fi += 1) feats[fi] = try gpa.dupe(u8, f.*);
                std.mem.sort([]const u8, feats, {}, struct {
                    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.lessThan);
                try sel.packs.append(gpa, .{
                    .path = try gpa.dupe(u8, c.path),
                    .hash = c.pack.packHash(),
                    .features = feats,
                });
            }

            // A dep entry is `lib` or `lib/feat[,feat2]`; the suffix requests
            // features on that dependency.
            for (c.manifest.features) |f| {
                if (active.contains(f.name)) {
                    for (f.deps) |dep| {
                        const lib = if (std.mem.findScalar(u8, dep, '/')) |slash| dep[0..slash] else dep;
                        if (std.mem.findScalar(u8, dep, '/')) |slash| {
                            try addFeatureReqs(gpa, &feature_reqs, lib, dep[slash + 1 ..]);
                        }
                        try new_prefixes.append(gpa, try gpa.dupe(u8, lib));
                        if (restrict and !declared.contains(lib)) {
                            try declared.put(try gpa.dupe(u8, lib), {});
                        }
                    }
                }
            }
            // A declared dependency loads with the pack that declares it, as
            // its classpath would carry it: a qualified reference into it
            // needs no import.
            for (c.manifest.dependencies) |dep| {
                if (isPackDependency(dep.library_id)) {
                    try new_deps.append(gpa, try gpa.dupe(u8, dep.library_id));
                }
                if (dep.features.len != 0) {
                    try addFeatureSlice(gpa, &feature_reqs, dep.library_id, dep.features);
                }
                if (restrict) {
                    const dep_dup = try gpa.dupe(u8, dep.library_id);
                    const dep_gop = try declared.getOrPut(dep_dup);
                    if (dep_gop.found_existing) gpa.free(dep_dup) else dep_gop.value_ptr.* = {};
                }
            }

            try loadPackCandidate(
                gpa,
                c,
                lib_id,
                &merged,
                &active,
                &user_import_prefixes,
                &feature_hints,
                source_map,
                &out_asts,
                &out_bindings,
                &new_imports,
                opts.asts_needed,
            );
            if (out_libs.items.len < out_asts.items.len) {
                const owned = try gpa.dupe(u8, lib_id);
                while (out_libs.items.len < out_asts.items.len) try out_libs.append(gpa, owned);
            }
        }
        if (!progressed) break;
        for (new_imports.items) |imp| {
            if (imp.len == 0) continue;
            const dup = try gpa.dupe(u8, imp);
            const ip = try known_prefixes.getOrPut(dup);
            if (ip.found_existing) gpa.free(dup) else ip.value_ptr.* = {};
        }
        for (new_prefixes.items) |p| {
            const dup = try gpa.dupe(u8, p);
            const pp = try known_prefixes.getOrPut(dup);
            if (pp.found_existing) gpa.free(dup) else pp.value_ptr.* = {};
        }
        for (new_deps.items) |d| {
            if (dep_ids.contains(d)) continue;
            try dep_ids.put(try gpa.dupe(u8, d), {});
        }
    }

    // A wanted pack that failed to decode is a broken environment, not a missing
    // library. A failure another candidate already served stays quiet.
    for (failed_packs.items) |f| {
        if (!opts.report_failures) break;
        const base = std.fs.path.basename(f.path);
        const lib_id = packLibIdFromBasename(base) orelse continue;
        if (loaded_lib_ids.contains(lib_id)) continue;
        if (!dep_ids.contains(lib_id) and !importPrefixMatches(gpa, &known_prefixes, lib_id)) continue;
        io.printStderr(
            gpa,
            "warning: skipping installed pack {s}: {s}\n" ++
                "  imports of `{s}` will not resolve from it; rebuild and reinstall the pack\n" ++
                "  (`klio pack build <libdir>` then `klio pack install <pack>`) or remove the file\n",
            .{ f.path, f.msg, lib_id },
        );
    }

    if (opts.selection) |sel| {
        var it = known_prefixes.keyIterator();
        while (it.next()) |k| try sel.final_prefixes.append(gpa, try gpa.dupe(u8, k.*));
    }

    if (opts.include_stdlib) {
        try loadEmbeddedStdlibSources(gpa, &known_prefixes, opts.stdlib_map orelse source_map, &out_asts, &out_bindings, opts.embedded_report);
    }

    // Hint at features the imports need. Drop hints for packages something else
    // already provided.
    var loaded_pkgs = std.StringHashMap(void).init(gpa);
    defer freeStringSet(&loaded_pkgs);
    for (out_asts.items) |f| {
        if (f.package) |p| {
            const joined = try joinIdentPath(gpa, p.path);
            const gop = try loaded_pkgs.getOrPut(joined);
            if (gop.found_existing) gpa.free(joined) else gop.value_ptr.* = {};
        }
    }

    var shown: std.ArrayList([2][]const u8) = .empty;
    defer shown.deinit(gpa);
    for (feature_hints.items) |h| {
        if (!opts.report_failures) break;
        if (loaded_pkgs.contains(h.pkg)) continue;
        var dup_exists = false;
        for (shown.items) |s| {
            if (std.mem.eql(u8, s[0], h.lib) and std.mem.eql(u8, s[1], h.feat)) {
                dup_exists = true;
                break;
            }
        }
        if (!dup_exists) try shown.append(gpa, .{ h.lib, h.feat });
    }
    std.mem.sort([2][]const u8, shown.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            const c0 = std.mem.order(u8, a[0], b[0]);
            if (c0 != .eq) return c0 == .lt;
            return std.mem.order(u8, a[1], b[1]) == .lt;
        }
    }.lessThan);
    for (shown.items) |s| {
        io.printStderr(
            gpa,
            "note: an import requires feature `{s}` of pack `{s}`; enable it with `--feature {s}/{s}`\n",
            .{ s[1], s[0], s[0], s[1] },
        );
    }

    while (out_libs.items.len < out_asts.items.len) try out_libs.append(gpa, "stdlib");
    return .{ .asts = try out_asts.toOwnedSlice(gpa), .bindings = out_bindings, .lib_ids = try out_libs.toOwnedSlice(gpa) };
}

/// Deep-copy a `RequestedFeatures`. Free with `deinitRequestedFeatures`.
fn cloneRequestedFeatures(allocator: Allocator, src: *const RequestedFeatures) Allocator.Error!RequestedFeatures {
    var out = RequestedFeatures.init(allocator);
    errdefer deinitRequestedFeatures(&out);
    var it = src.iterator();
    while (it.next()) |entry| {
        const lib = try allocator.dupe(u8, entry.key_ptr.*);
        var set = std.StringHashMap(void).init(allocator);
        var fit = entry.value_ptr.keyIterator();
        while (fit.next()) |f| {
            try set.put(try allocator.dupe(u8, f.*), {});
        }
        try out.put(lib, set);
    }
    return out;
}

fn deinitRequestedFeatures(rf: *RequestedFeatures) void {
    const a = rf.allocator;
    var it = rf.iterator();
    while (it.next()) |entry| {
        a.free(entry.key_ptr.*);
        var fit = entry.value_ptr.keyIterator();
        while (fit.next()) |f| a.free(f.*);
        entry.value_ptr.deinit();
    }
    rf.deinit();
}

/// Insert each comma-separated feature in `feats` into `lib`'s set, owning copies.
fn addFeatureReqs(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: []const u8,
) Allocator.Error!void {
    const set = try featureSetFor(allocator, reqs, lib);
    var it = std.mem.splitScalar(u8, feats, ',');
    while (it.next()) |feat_raw| {
        const feat = std.mem.trim(u8, feat_raw, " \t");
        if (feat.len == 0) continue;
        if (!set.contains(feat)) try set.put(try allocator.dupe(u8, feat), {});
    }
}

fn addFeatureSlice(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: [][]const u8,
) Allocator.Error!void {
    const set = try featureSetFor(allocator, reqs, lib);
    for (feats) |feat| {
        if (!set.contains(feat)) try set.put(try allocator.dupe(u8, feat), {});
    }
}

/// `addFeatureReqs` reporting a new addition, the prepass fixpoint's signal.
fn addFeatureReqsChanged(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: []const u8,
) Allocator.Error!bool {
    const set = try featureSetFor(allocator, reqs, lib);
    var changed = false;
    var it = std.mem.splitScalar(u8, feats, ',');
    while (it.next()) |feat_raw| {
        const feat = std.mem.trim(u8, feat_raw, " \t");
        if (feat.len == 0) continue;
        if (!set.contains(feat)) {
            try set.put(try allocator.dupe(u8, feat), {});
            changed = true;
        }
    }
    return changed;
}

fn addFeatureSliceChanged(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
    feats: [][]const u8,
) Allocator.Error!bool {
    const set = try featureSetFor(allocator, reqs, lib);
    var changed = false;
    for (feats) |feat| {
        if (!set.contains(feat)) {
            try set.put(try allocator.dupe(u8, feat), {});
            changed = true;
        }
    }
    return changed;
}

/// Get (or create) the requested-feature set for `lib`, owning the key.
fn featureSetFor(
    allocator: Allocator,
    reqs: *RequestedFeatures,
    lib: []const u8,
) Allocator.Error!*std.StringHashMap(void) {
    if (reqs.getPtr(lib)) |p| return p;
    const key = try allocator.dupe(u8, lib);
    try reqs.put(key, std.StringHashMap(void).init(allocator));
    return reqs.getPtr(lib).?;
}


fn mergedHostBindingsInit(gpa: Allocator) HostBindings {
    return mergedHostBindings(gpa);
}

/// One `HostBindings` for every pack: `klio-stdlib` defaults unioned with what
/// each kotlinx library and ktor-client ships.
pub fn mergedHostBindings(gpa: Allocator) HostBindings {
    var out = HostBindings.withStdlibDefaults(gpa) catch HostBindings.init(gpa);
    mergeInto(&out, kotlinx_atomicfu.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_io.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_datetime.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_coroutines.hostBindings(gpa) catch null);
    mergeInto(&out, kotlinx_serialization.hostBindings(gpa) catch null);
    mergeInto(&out, compose_runtime.hostBindings(gpa) catch null);
    mergeInto(&out, compose_ui.hostBindings(gpa) catch null);
    // org.jetbrains.skia's natives, under the C symbols skiko's glue exports.
    mergeInto(&out, skiko.hostBindings(gpa) catch null);
    // The composer-stack intrinsics touch the VM's implicit-composer threadlocal.
    mergeInto(&out, interp_ir.compose.hostBindings(gpa) catch null);
    // ktor-client is opt-in, but its host functions are always in the registry.
    mergeInto(&out, ktor_client.hostBindings(gpa) catch null);
    return out;
}

fn mergeInto(dst: *HostBindings, src_opt: ?HostBindings) void {
    var src = src_opt orelse return;
    defer src.deinit();
    var it = src.table.iterator();
    while (it.next()) |entry| {
        dst.register(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }
}


fn klioCacheDir(allocator: Allocator) PathResult {
    const home = (runtime.procEnvKlioHome(allocator) catch null) orelse
        return .{ .err = allocator.dupe(u8, "HOME (or KLIO_HOME) env var unset") catch "" };
    defer allocator.free(home);
    const path = std.fs.path.join(allocator, &.{ home, ".klio", "packs" }) catch
        return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
    return .{ .ok = path };
}

/// Manifest of the pack at `path`; `ok` is owned and the caller deinits it.
pub fn readPackManifest(allocator: Allocator, path: []const u8) ManifestResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return memErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();
    const payload = (reader.readSection(section_names.MANIFEST, &err) catch return memErr(allocator)) orelse
        return .{ .err = std.fmt.allocPrint(allocator, "{s}: missing manifest section", .{path}) catch "" };
    defer payload.deinit(allocator);
    const manifest = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return memErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    return .{ .ok = manifest };
}

fn memErr(allocator: Allocator) ManifestResult {
    return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
}

fn packErrMsg(allocator: Allocator, err: PackError) []u8 {
    return std.fmt.allocPrint(allocator, "{any}", .{err}) catch "";
}

/// Copy a `.klio-pack` into the cache as `<library_id>-<version>.klio-pack`.
/// `ok` is the owned destination. Rebuilds the sidecar index best-effort.
pub fn installPackIntoCache(allocator: Allocator, src: []const u8) PathResult {
    const manifest_res = readPackManifest(allocator, src);
    switch (manifest_res) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    var manifest = manifest_res.ok;
    defer manifest.deinit(allocator);

    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    std.Io.Dir.cwd().createDirPath(fio, cache) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };

    const name = std.fmt.allocPrint(allocator, "{s}-{s}.klio-pack", .{
        manifest.library_id, manifest.library_version,
    }) catch return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
    defer allocator.free(name);
    const dest = std.fs.path.join(allocator, &.{ cache, name }) catch
        return .{ .err = allocator.dupe(u8, "out of memory") catch "" };

    // Installing supersedes: two versions side by side would leave the pick to
    // directory order.
    removeOtherVersions(allocator, fio, cache, manifest.library_id, name);

    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, src, allocator, .unlimited) catch |e| {
        allocator.free(dest);
        return .{ .err = std.fmt.allocPrint(allocator, "copy: {s}", .{@errorName(e)}) catch "" };
    };
    defer allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = dest, .data = bytes }) catch |e| {
        allocator.free(dest);
        return .{ .err = std.fmt.allocPrint(allocator, "copy: {s}", .{@errorName(e)}) catch "" };
    };

    rebuildCacheIndex(allocator, cache);
    return .{ .ok = dest };
}

/// Delete every installed `.klio-pack` for `lib_id` except `keep_name`.
/// Best-effort: an undeletable stale version surfaces via failure reporting.
fn removeOtherVersions(allocator: Allocator, fio: std.Io, cache: []const u8, lib_id: []const u8, keep_name: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch return;
    defer dir.close(fio);
    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |s| allocator.free(s);
        stale.deinit(allocator);
    }
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        if (std.mem.eql(u8, entry.name, keep_name)) continue;
        const id = packLibIdFromBasename(entry.name) orelse continue;
        if (!std.mem.eql(u8, id, lib_id)) continue;
        const dup = allocator.dupe(u8, entry.name) catch continue;
        stale.append(allocator, dup) catch {
            allocator.free(dup);
            continue;
        };
    }
    for (stale.items) |s| {
        dir.deleteFile(fio, s) catch {};
    }
}


/// One sidecar `index.json` entry; field names are fixed for format stability.
const CacheIndexEntry = struct {
    library_id: []const u8,
    version: []const u8,
    abi_version: u32,
    path: []const u8,
    dependencies: []const []const u8,
};

const CACHE_INDEX_NAME: []const u8 = "index.json";

/// Rewrite the sidecar `index.json` so later startups skip per-pack header reads.
fn rebuildCacheIndex(allocator: Allocator, cache: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch return;
    defer dir.close(fio);

    var out: std.ArrayList(CacheIndexEntry) = .empty;
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(arena, &.{ cache, entry.name }) catch continue;
        const mr = readPackManifest(allocator, p);
        switch (mr) {
            .err => |e| {
                allocator.free(e);
                continue;
            },
            .ok => {},
        }
        var m = mr.ok;
        defer m.deinit(allocator);
        var deps: std.ArrayList([]const u8) = .empty;
        for (m.dependencies) |d| {
            deps.append(arena, arena.dupe(u8, d.library_id) catch continue) catch continue;
        }
        out.append(arena, .{
            .library_id = arena.dupe(u8, m.library_id) catch continue,
            .version = arena.dupe(u8, m.library_version) catch continue,
            .abi_version = m.abi_version,
            .path = arena.dupe(u8, p) catch continue,
            .dependencies = deps.toOwnedSlice(arena) catch continue,
        }) catch continue;
    }
    std.mem.sort(CacheIndexEntry, out.items, {}, struct {
        fn lessThan(_: void, a: CacheIndexEntry, b: CacheIndexEntry) bool {
            return std.mem.order(u8, a.library_id, b.library_id) == .lt;
        }
    }.lessThan);
    const bytes = std.json.Stringify.valueAlloc(arena, out.items, .{ .whitespace = .indent_2 }) catch return;
    const idx_path = std.fs.path.join(arena, &.{ cache, CACHE_INDEX_NAME }) catch return;
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = idx_path, .data = bytes }) catch return;
}


pub fn listCachePacks(allocator: Allocator) VoidResult {
    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch {
        io.printStderr(allocator, "(no packs installed at {s})\n", .{cache});
        return .{ .ok = {} };
    };
    defer dir.close(fio);

    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(allocator, &.{ cache, entry.name }) catch continue;
        paths.append(allocator, p) catch allocator.free(p);
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (paths.items) |path| {
        const mr = readPackManifest(allocator, path);
        switch (mr) {
            .ok => {
                var m = mr.ok;
                defer m.deinit(allocator);
                var deps_buf: std.ArrayList(u8) = .empty;
                defer deps_buf.deinit(allocator);
                if (m.dependencies.len == 0) {
                    deps_buf.appendSlice(allocator, "\u{2014}") catch {};
                } else {
                    for (m.dependencies, 0..) |d, i| {
                        if (i != 0) deps_buf.appendSlice(allocator, ", ") catch {};
                        deps_buf.appendSlice(allocator, d.library_id) catch {};
                        const fm = formatMin(allocator, d.min_version);
                        defer allocator.free(fm);
                        deps_buf.appendSlice(allocator, fm) catch {};
                    }
                }
                io.printStdout(allocator, "{s: <32}  {s: <10}  abi {d}  deps {s}\n", .{
                    m.library_id, m.library_version, m.abi_version, deps_buf.items,
                });
            },
            .err => |e| {
                defer allocator.free(e);
                io.printStdout(allocator, "{s}: ! {s}\n", .{ path, e });
            },
        }
    }
    return .{ .ok = {} };
}

/// Render a dependency min-version suffix: ` (>=x)` or empty. Owned.
fn formatMin(allocator: Allocator, min: []const u8) []u8 {
    if (min.len == 0) return allocator.dupe(u8, "") catch "";
    return std.fmt.allocPrint(allocator, " (>={s})", .{min}) catch "";
}

/// Remove the cached pack for `library_id` (and `version`). `ok` is owned.
pub fn removeCachePack(allocator: Allocator, library_id: []const u8, version: ?[]const u8) PathResult {
    const cache_res = klioCacheDir(allocator);
    const cache = switch (cache_res) {
        .ok => |c| c,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(cache);

    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(fio, cache, .{ .iterate = true }) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };
    defer dir.close(fio);

    var it = dir.iterate();
    while (it.next(fio) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".klio-pack")) continue;
        const p = std.fs.path.join(allocator, &.{ cache, entry.name }) catch continue;
        var keep_p = false;
        defer if (!keep_p) allocator.free(p);
        const mr = readPackManifest(allocator, p);
        switch (mr) {
            .err => |e| {
                allocator.free(e);
                continue;
            },
            .ok => {},
        }
        var manifest = mr.ok;
        defer manifest.deinit(allocator);
        if (!std.mem.eql(u8, manifest.library_id, library_id)) continue;
        if (version) |v| {
            if (!std.mem.eql(u8, manifest.library_version, v)) continue;
        }
        std.Io.Dir.cwd().deleteFile(fio, p) catch |e|
            return .{ .err = std.fmt.allocPrint(allocator, "{s}", .{@errorName(e)}) catch "" };
        rebuildCacheIndex(allocator, cache);
        keep_p = true;
        return .{ .ok = p };
    }
    return .{ .err = std.fmt.allocPrint(allocator, "no pack matching {s} found in cache", .{library_id}) catch "" };
}


/// Print a pack's format version, hash prefix, sections and decoded counts.
pub fn inspectPack(allocator: Allocator, path: []const u8) VoidResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return voidMemErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();

    io.printStdout(allocator, "file:    {s}\n", .{path});
    io.printStdout(allocator, "format:  v{d}\n", .{reader.formatVersion()});
    const hash = reader.packHash();
    var hash_buf: std.ArrayList(u8) = .empty;
    defer hash_buf.deinit(allocator);
    hash_buf.appendSlice(allocator, "hash:    ") catch {};
    for (hash[0..16]) |b| {
        hash_buf.appendSlice(allocator, std.fmt.bytesToHex(&[_]u8{b}, .lower)[0..]) catch {};
    }
    hash_buf.appendSlice(allocator, "\u{2026}\n") catch {};
    io.writeStdout(hash_buf.items);

    io.writeStdout("sections:\n");
    for (reader.sections()) |e| {
        io.printStdout(allocator, "  - {s: <10} stored={d: >8} bytes  uncompressed={d: >8} bytes  {s}\n", .{
            e.name, e.stored_len, e.uncompressed_len, @tagName(e.compression),
        });
    }

    if (reader.readSection(section_names.MANIFEST, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var m = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer m.deinit(allocator);
        const impl = strSliceDebug(allocator, m.implicit_packages);
        defer allocator.free(impl);
        io.printStdout(allocator, "manifest: library={s} version={s} abi={d} implicit={s}\n", .{
            m.library_id, m.library_version, m.abi_version, impl,
        });
        if (m.features.len != 0) {
            const df = strSliceDebug(allocator, m.default_features);
            defer allocator.free(df);
            io.printStdout(allocator, "default-features: {s}\n", .{df});
            for (m.features) |f| {
                const srcs = strSliceDebug(allocator, f.sources);
                defer allocator.free(srcs);
                var tail: std.ArrayList(u8) = .empty;
                defer tail.deinit(allocator);
                if (f.requires.len != 0) {
                    const rq = strSliceDebug(allocator, f.requires);
                    defer allocator.free(rq);
                    const seg = std.fmt.allocPrint(allocator, " requires={s}", .{rq}) catch "";
                    defer allocator.free(seg);
                    tail.appendSlice(allocator, seg) catch {};
                }
                if (f.deps.len != 0) {
                    const dp = strSliceDebug(allocator, f.deps);
                    defer allocator.free(dp);
                    const seg = std.fmt.allocPrint(allocator, " deps={s}", .{dp}) catch "";
                    defer allocator.free(seg);
                    tail.appendSlice(allocator, seg) catch {};
                }
                io.printStdout(allocator, "  feature {s}: sources={s}{s}\n", .{ f.name, srcs, tail.items });
            }
        }
    }
    if (reader.readSection(section_names.SYMBOLS, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var s = (schema.decode(schema.SymbolIndex, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer s.deinit(allocator);
        io.printStdout(allocator, "symbols:  {d} entries\n", .{s.entries.len});
    }
    if (reader.readSection(section_names.BINDINGS, &err) catch return voidMemErr(allocator)) |payload| {
        defer payload.deinit(allocator);
        var b = (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = packErrMsg(allocator, err) };
        defer b.deinit(allocator);
        io.printStdout(allocator, "bindings: {d} entries\n", .{b.bindings.len});
    }
    return .{ .ok = {} };
}

fn voidMemErr(allocator: Allocator) VoidResult {
    return .{ .err = allocator.dupe(u8, "out of memory") catch "" };
}

/// Render a `[][]const u8` as `["a", "b"]`. Owned by the caller.
fn strSliceDebug(allocator: Allocator, slice: [][]const u8) []u8 {
    var buf: std.ArrayList(u8) = .empty;
    buf.append(allocator, '[') catch return allocator.dupe(u8, "[]") catch "";
    for (slice, 0..) |s, i| {
        if (i != 0) buf.appendSlice(allocator, ", ") catch {};
        buf.append(allocator, '"') catch {};
        buf.appendSlice(allocator, s) catch {};
        buf.append(allocator, '"') catch {};
    }
    buf.append(allocator, ']') catch {};
    return buf.toOwnedSlice(allocator) catch "";
}

/// Read every required section back through the loader and decode it.
pub fn verifyPack(allocator: Allocator, path: []const u8, smoke: ?[]const u8) VoidResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const fio = threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(fio, path, allocator, .unlimited) catch |e|
        return .{ .err = std.fmt.allocPrint(allocator, "read {s}: {s}", .{ path, @errorName(e) }) catch "" };
    var err: PackError = undefined;
    var reader = (PackReader.fromBytes(allocator, bytes, &err) catch return voidMemErr(allocator)) orelse
        return .{ .err = packErrMsg(allocator, err) };
    defer reader.deinit();

    const required = [_][]const u8{
        section_names.MANIFEST,
        section_names.SYMBOLS,
        section_names.BINDINGS,
    };
    for (required) |name| {
        const payload = (reader.readSection(name, &err) catch return voidMemErr(allocator)) orelse
            return .{ .err = std.fmt.allocPrint(allocator, "missing required section `{s}`", .{name}) catch "" };
        defer payload.deinit(allocator);
        if (std.mem.eql(u8, name, section_names.MANIFEST)) {
            var m = (schema.decode(schema.PackManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            m.deinit(allocator);
        } else if (std.mem.eql(u8, name, section_names.SYMBOLS)) {
            var s = (schema.decode(schema.SymbolIndex, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            s.deinit(allocator);
        } else if (std.mem.eql(u8, name, section_names.BINDINGS)) {
            var b = (schema.decode(schema.BindingManifest, allocator, payload.slice(), &err) catch return voidMemErr(allocator)) orelse
                return .{ .err = packErrMsg(allocator, err) };
            b.deinit(allocator);
        }
    }
    if (smoke != null) {
        io.writeStderr("note: pack smoke-run was removed during the IR cutover.\n");
    }
    return .{ .ok = {} };
}


fn registerParseJobs(map: *SourceMap, sources: []const []const u8, jobs: []ParseJob) !void {
    for (sources, 0..) |src, i| {
        const fid = try map.add("f.kt", src);
        jobs[i] = .{ .fid = fid, .src = map.get(fid).source, .rel_path = "f.kt" };
    }
}

/// Runs the jobs of a fixed array through the pool driver and copies the file
/// results back; no file here is large enough to be cut.
fn runJobsOn(a: Allocator, jobs: []ParseJob, want: usize) !usize {
    var list: std.ArrayList(ParseJob) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, jobs);
    const threads = runParseJobsOn(a, &list, want);
    @memcpy(jobs, list.items[0..jobs.len]);
    return threads;
}

test "a large source parses in pieces on the pool as it parses whole" {
    const a = std.heap.smp_allocator;
    // Declarations of every shape a cut must respect: blocks followed by
    // `else`, `catch` and `finally` on their own lines, annotations, and
    // expression bodies between block bodies.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "package p.big\nimport kotlin.collections.List\n");
    var i: usize = 0;
    while (src.items.len < chunk_min_bytes + chunk_bytes) : (i += 1) {
        const decl = try std.fmt.allocPrint(a,
            \\/** Doc {d}. */
            \\fun f{d}(x: Int): Int {{
            \\    return x + {d}
            \\}}
            \\val v{d} = if (f{d}(1) > 0) {{
            \\    1
            \\}}
            \\else {{
            \\    2
            \\}}
            \\val t{d} = try {{
            \\    f{d}(2)
            \\}}
            \\catch (e: Exception) {{
            \\    0
            \\}}
            \\finally {{
            \\}}
            \\@Deprecated("old")
            \\fun g{d}() = f{d}(3)
            \\class C{d} {{
            \\    fun m() = {d}
            \\}}
            \\
        , .{ i, i, i, i, i, i, i, i, i, i, i });
        defer a.free(decl);
        try src.appendSlice(a, decl);
    }
    const source = src.items;
    var pooled_map = SourceMap.init(a);
    defer pooled_map.deinit();
    var pooled: std.ArrayList(ParseJob) = .empty;
    defer pooled.deinit(a);
    {
        const fid = try pooled_map.add("big.kt", source);
        try pooled.append(a, .{ .fid = fid, .src = pooled_map.get(fid).source, .rel_path = "big.kt" });
    }
    try std.testing.expect(runParseJobsOn(a, &pooled, 4) >= 2);
    var serial_map = SourceMap.init(a);
    defer serial_map.deinit();
    var serial: std.ArrayList(ParseJob) = .empty;
    defer serial.deinit(a);
    {
        const fid = try serial_map.add("big.kt", source);
        try serial.append(a, .{ .fid = fid, .src = serial_map.get(fid).source, .rel_path = "big.kt" });
    }
    try std.testing.expectEqual(@as(usize, 1), runParseJobsOn(a, &serial, 1));

    const pf = pooled.items[0];
    const sf = serial.items[0];
    try std.testing.expect(pf.pieces >= 2);
    try std.testing.expect(pf.result == .ok);
    try std.testing.expect(sf.result == .ok);
    for (pooled.items[1..]) |*piece| try std.testing.expect(piece.result == .skipped);
    const pd = pf.result.ok.decls;
    const sd = sf.result.ok.decls;
    try std.testing.expectEqual(sd.len, pd.len);
    try std.testing.expect(pd.len >= 5 * i);
    for (sd, pd) |*x, *y| {
        try std.testing.expectEqual(std.meta.activeTag(x.*), std.meta.activeTag(y.*));
        try std.testing.expectEqualStrings(declName(x), declName(y));
        try std.testing.expectEqual(declSpan(x).start, declSpan(y).start);
        try std.testing.expectEqual(declSpan(x).end, declSpan(y).end);
        try std.testing.expectEqual(declShape(x), declShape(y));
    }
    try std.testing.expectEqualStrings("p", pf.result.ok.package.?.path[0].name);
    try std.testing.expectEqual(@as(usize, 1), pf.result.ok.imports.len);
}

test "parse jobs on a pool match serial parsing and keep file order" {
    // The pool needs an allocator that serves several threads at once.
    const a = std.heap.smp_allocator;
    const sources = [_][]const u8{
        "package p.one\nfun a() = 1\n",
        "package p.two\nval x = 'ab'\n",
        "package p.three\nfun (\n",
        "package p.four\nclass C { fun m(x: Int): Int = x + 1 }\nfun b() = C().m(2)\nval c = 3\n",
        "fun d() = \"${1 + 1}\"\n",
    };
    var pooled_map = SourceMap.init(a);
    defer pooled_map.deinit();
    var pooled: [sources.len]ParseJob = undefined;
    try registerParseJobs(&pooled_map, &sources, &pooled);
    try std.testing.expect(try runJobsOn(a, &pooled, 4) >= 1);

    var serial_map = SourceMap.init(a);
    defer serial_map.deinit();
    var serial: [sources.len]ParseJob = undefined;
    try registerParseJobs(&serial_map, &sources, &serial);
    try std.testing.expectEqual(@as(usize, 1), try runJobsOn(a, &serial, 1));

    try std.testing.expect(pooled[0].result == .ok);
    try std.testing.expect(pooled[1].result == .lex_errors);
    try std.testing.expect(pooled[2].result == .parse_errors);
    try std.testing.expect(pooled[3].result == .ok);
    try std.testing.expect(pooled[4].result == .ok);
    for (&pooled, &serial, 0..) |*pj, *sj, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), pj.fid.int());
        try std.testing.expectEqual(std.meta.activeTag(sj.result), std.meta.activeTag(pj.result));
        switch (pj.result) {
            .pieces => unreachable,
            .ok => |pf| {
                const sf = sj.result.ok;
                try std.testing.expectEqual(pj.fid, pf.span.file);
                try std.testing.expectEqual(sf.decls.len, pf.decls.len);
                try std.testing.expect(sf.span.eql(pf.span));
                try std.testing.expectEqual(sf.package == null, pf.package == null);
            },
            .lex_errors => |n| try std.testing.expectEqual(sj.result.lex_errors, n),
            .parse_errors => |p| try std.testing.expectEqual(sj.result.parse_errors.diagnostics.diags().len, p.diagnostics.diags().len),
            .skipped => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), pooled[3].result.ok.decls.len);
}

test "merged host bindings cover stdlib defaults" {
    var b = mergedHostBindings(std.testing.allocator);
    defer b.deinit();
    try std.testing.expect(!b.isEmpty());
}

test "sourceInFeature matches prefix and exact" {
    var pats = [_][]const u8{ "shim/io/ktor/server", "shim/io/ktor/client/" };
    try std.testing.expect(sourceInFeature("shim/io/ktor/server", &pats));
    try std.testing.expect(sourceInFeature("shim/io/ktor/server/Routing.kt", &pats));
    try std.testing.expect(sourceInFeature("shim/io/ktor/client/Http.kt", &pats));
    try std.testing.expect(!sourceInFeature("shim/io/ktor/serverless", &pats));
    try std.testing.expect(!sourceInFeature("shim/io/ktor/core", &pats));
}

test "resolveActiveFeatures expands defaults and requires" {
    const a = std.testing.allocator;
    var default = [_][]const u8{"core"};
    var req_a = [_][]const u8{"json"};
    var feat_a = schema.FeatureDef{ .name = "json", .sources = &.{}, .deps = &.{}, .requires = &req_a };
    var feats = [_]schema.FeatureDef{feat_a};
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &default,
        .features = &feats,
    };
    var requested = std.StringHashMap(void).init(a);
    defer requested.deinit();
    try requested.put("core", {});
    var active = try resolveActiveFeatures(a, &manifest, &requested);
    defer active.deinit();
    try std.testing.expect(active.contains("core"));
    // "json" is not requested or default, so it is not active.
    try std.testing.expect(!active.contains("json"));
    // "a"-required expansion is covered by a self-requiring feature.
    _ = &feat_a;
}

test "resolveActiveFeatures pulls in transitive requires" {
    const a = std.testing.allocator;
    var default = [_][]const u8{"outer"};
    var req_outer = [_][]const u8{"inner"};
    const f_outer = schema.FeatureDef{ .name = "outer", .sources = &.{}, .deps = &.{}, .requires = &req_outer };
    const f_inner = schema.FeatureDef{ .name = "inner", .sources = &.{}, .deps = &.{}, .requires = &.{} };
    var feats = [_]schema.FeatureDef{ f_outer, f_inner };
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &default,
        .features = &feats,
    };
    var active = try resolveActiveFeatures(a, &manifest, null);
    defer active.deinit();
    try std.testing.expect(active.contains("outer"));
    try std.testing.expect(active.contains("inner"));
}

test "sourceIsActive and inactiveGate" {
    var srcs = [_][]const u8{"shim/server"};
    const f = schema.FeatureDef{ .name = "server", .sources = &srcs, .deps = &.{}, .requires = &.{} };
    var feats = [_]schema.FeatureDef{f};
    const manifest = schema.PackManifest{
        .library_id = "lib",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &.{},
        .features = &feats,
    };
    const a = std.testing.allocator;
    var active = std.StringHashMap(void).init(a);
    defer active.deinit();
    try std.testing.expect(sourceIsActive("shim/core/Core.kt", &manifest, &active));
    try std.testing.expect(!sourceIsActive("shim/server/Routing.kt", &manifest, &active));
    const gate = inactiveGate("shim/server/Routing.kt", &manifest, &active);
    try std.testing.expect(gate != null);
    try std.testing.expectEqualStrings("server", gate.?.feature);
    try std.testing.expectEqualStrings("shim/server", gate.?.prefix);
    try active.put("server", {});
    try std.testing.expect(sourceIsActive("shim/server/Routing.kt", &manifest, &active));
    try std.testing.expect(inactiveGate("shim/server/Routing.kt", &manifest, &active) == null);
}

test "the most specific feature prefix gates a file" {
    var core_srcs = [_][]const u8{ "upstream/kotlinx-coroutines-core", "klioMain" };
    var test_srcs = [_][]const u8{ "upstream/kotlinx-coroutines-test", "klioMain/kotlinx/coroutines/test" };
    var core_req = [_][]const u8{};
    var test_req = [_][]const u8{"core"};
    const core = schema.FeatureDef{ .name = "core", .sources = &core_srcs, .deps = &.{}, .requires = &core_req };
    const tst = schema.FeatureDef{ .name = "test", .sources = &test_srcs, .deps = &.{}, .requires = &test_req };
    var feats = [_]schema.FeatureDef{ core, tst };
    var default = [_][]const u8{"core"};
    const manifest = schema.PackManifest{
        .library_id = "kotlinx.coroutines",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &default,
        .features = &feats,
    };
    const a = std.testing.allocator;
    var active = try resolveActiveFeatures(a, &manifest, null);
    defer active.deinit();
    try std.testing.expect(active.contains("core"));
    try std.testing.expect(!active.contains("test"));

    // Core files under both roots load with the default.
    try std.testing.expect(sourceIsActive("upstream/kotlinx-coroutines-core/common/src/Job.kt", &manifest, &active));
    try std.testing.expect(sourceIsActive("klioMain/kotlinx/coroutines/EventLoop.kt", &manifest, &active));
    // A test-module actual under klioMain is claimed by the longer prefix only.
    try std.testing.expect(!sourceIsActive("klioMain/kotlinx/coroutines/test/TestBuilders.kt", &manifest, &active));
    try std.testing.expect(!sourceIsActive("upstream/kotlinx-coroutines-test/common/src/TestScope.kt", &manifest, &active));
    const gate = inactiveGate("klioMain/kotlinx/coroutines/test/TestBuilders.kt", &manifest, &active);
    try std.testing.expect(gate != null);
    try std.testing.expectEqualStrings("test", gate.?.feature);
    try std.testing.expectEqualStrings("klioMain/kotlinx/coroutines/test", gate.?.prefix);
    // A file claimed by nothing is ungated.
    try std.testing.expect(sourceIsActive("README.kt", &manifest, &active));

    try active.put("test", {});
    try std.testing.expect(sourceIsActive("klioMain/kotlinx/coroutines/test/TestBuilders.kt", &manifest, &active));
    try std.testing.expect(sourceIsActive("upstream/kotlinx-coroutines-test/common/src/TestScope.kt", &manifest, &active));
}

test "features sharing a prefix of equal length both gate it" {
    var a_srcs = [_][]const u8{"upstream/ktor-shared/ktor-serialization/"};
    var b_srcs = [_][]const u8{"upstream/ktor-shared/ktor-serialization"};
    const fa = schema.FeatureDef{ .name = "client-serialization", .sources = &a_srcs, .deps = &.{}, .requires = &.{} };
    const fb = schema.FeatureDef{ .name = "server-serialization", .sources = &b_srcs, .deps = &.{}, .requires = &.{} };
    var feats = [_]schema.FeatureDef{ fa, fb };
    const manifest = schema.PackManifest{
        .library_id = "io.ktor",
        .library_version = "1.0",
        .abi_version = 1,
        .implicit_packages = &.{},
        .dependencies = &.{},
        .default_features = &.{},
        .features = &feats,
    };
    const a = std.testing.allocator;
    var active = std.StringHashMap(void).init(a);
    defer active.deinit();
    const path = "upstream/ktor-shared/ktor-serialization/common/src/ContentConverter.kt";
    try std.testing.expect(!sourceIsActive(path, &manifest, &active));
    try active.put("server-serialization", {});
    try std.testing.expect(sourceIsActive(path, &manifest, &active));
}

test "packageOfSource finds the package line" {
    const src =
        \\// a comment
        \\
        \\   package io.ktor.server ;
        \\
        \\fun main() {}
    ;
    const pkg = packageOfSource(src);
    try std.testing.expect(pkg != null);
    try std.testing.expectEqualStrings("io.ktor.server", pkg.?);
    try std.testing.expect(packageOfSource("fun main() {}") == null);
}

test "importMatchesPackage targets package and members only" {
    const a = std.testing.allocator;
    try std.testing.expect(importMatchesPackage(a, "io.ktor.server", "io.ktor.server"));
    try std.testing.expect(importMatchesPackage(a, "io.ktor.server.Routing", "io.ktor.server"));
    // A parent star import does not target a child package.
    try std.testing.expect(!importMatchesPackage(a, "io.ktor", "io.ktor.server"));
    try std.testing.expect(!importMatchesPackage(a, "io.ktor.server", ""));
}

test "formatMin renders a min-version suffix" {
    const a = std.testing.allocator;
    const empty = formatMin(a, "");
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    const some = formatMin(a, "1.2.0");
    defer a.free(some);
    try std.testing.expectEqualStrings(" (>=1.2.0)", some);
}

test "strSliceDebug renders a quoted, comma-separated list" {
    const a = std.testing.allocator;
    var items = [_][]const u8{ "kotlin", "kotlin.collections" };
    const out = strSliceDebug(a, &items);
    defer a.free(out);
    try std.testing.expectEqualStrings("[\"kotlin\", \"kotlin.collections\"]", out);
    var empty: [0][]const u8 = .{};
    const out2 = strSliceDebug(a, &empty);
    defer a.free(out2);
    try std.testing.expectEqualStrings("[]", out2);
}

test "dottedPrefix only matches on a dot boundary" {
    const a = std.testing.allocator;
    try std.testing.expect(dottedPrefix(a, "io.ktor.server", "io.ktor"));
    try std.testing.expect(!dottedPrefix(a, "io.ktorx", "io.ktor"));
    try std.testing.expect(!dottedPrefix(a, "io.ktor", "io.ktor"));
}

test "cloneRequestedFeatures deep copies the map" {
    const a = std.testing.allocator;
    var src = RequestedFeatures.init(a);
    {
        var set = std.StringHashMap(void).init(a);
        try set.put("server", {});
        try src.put("io.ktor", set);
    }
    defer {
        var it = src.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        src.deinit();
    }
    var cloned = try cloneRequestedFeatures(a, &src);
    defer deinitRequestedFeatures(&cloned);
    const feats = cloned.get("io.ktor").?;
    try std.testing.expect(feats.contains("server"));
}

test "addFeatureReqs splits comma-separated features" {
    const a = std.testing.allocator;
    var reqs = RequestedFeatures.init(a);
    defer deinitRequestedFeatures(&reqs);
    try addFeatureReqs(a, &reqs, "kotlinx.serialization", "json, cbor ,");
    const set = reqs.get("kotlinx.serialization").?;
    try std.testing.expect(set.contains("json"));
    try std.testing.expect(set.contains("cbor"));
    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "packLibIdFromBasename strips the version suffix" {
    try std.testing.expectEqualStrings(
        "kotlinx.coroutines",
        packLibIdFromBasename("kotlinx.coroutines-1.11.0.klio-pack").?,
    );
    try std.testing.expectEqualStrings(
        "io.ktor",
        packLibIdFromBasename("io.ktor-3.5.0.klio-pack").?,
    );
    // A pre-release version keeps the id: the version starts at the first dash-digit.
    try std.testing.expectEqualStrings(
        "mylib",
        packLibIdFromBasename("mylib-1.0.0-beta.klio-pack").?,
    );
    // Not the installed naming convention: no version part at all.
    try std.testing.expect(packLibIdFromBasename("noversion.klio-pack") == null);
    try std.testing.expect(packLibIdFromBasename("-1.0.0.klio-pack") == null);
}

test "rebaseFileSpans retargets every span in a parsed file" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const src =
        \\package p.q
        \\import kotlin.math.max
        \\class C(val x: Int) {
        \\    fun f(y: Int): Int = if (y > 0) x + y else max(x, -y)
        \\}
        \\fun top(): String = "s"
    ;
    const old = span.FileId.from(7);
    var lx = try lexer.Lexer.init(aa, old, src);
    const lexed = try lx.tokenize();
    try std.testing.expect(!lexed.diagnostics.hasErrors());
    const p = parser.Parser.new(aa, old, src, lexed.tokens, lexed.strings);
    var file = p.parseFile();
    try std.testing.expect(!p.diagnostics.hasErrors());
    try std.testing.expectEqual(old, file.span.file);

    const fresh = span.FileId.from(401);
    rebaseFileSpans(&file, old, fresh);

    var count: usize = 0;
    countSpansWithFile(KotlinFile, &file, fresh, &count);
    var stale: usize = 0;
    countSpansWithFile(KotlinFile, &file, old, &stale);
    try std.testing.expect(count > 10);
    try std.testing.expectEqual(@as(usize, 0), stale);
    try std.testing.expectEqual(fresh, file.span.file);
    try std.testing.expectEqual(fresh, file.package.?.span.file);
    try std.testing.expectEqual(fresh, file.imports[0].span.file);
    try std.testing.expectEqual(fresh, file.decls[0].Class.span.file);
}

fn countSpansWithFile(comptime T: type, value: *T, want: span.FileId, count: *usize) void {
    if (comptime T == span.Span) {
        if (value.file == want) count.* += 1;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime s.layout == .@"packed") return;
            inline for (s.fields) |f| {
                if (comptime !f.is_comptime) {
                    countSpansWithFile(f.type, &@field(value.*, f.name), want, count);
                }
            }
        },
        .optional => |o| {
            if (value.*) |*inner| countSpansWithFile(o.child, inner, want, count);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return;
                for (@constCast(value.*)) |*item| countSpansWithFile(p.child, item, want, count);
            },
            .one => countSpansWithFile(p.child, @constCast(value.*), want, count),
            else => {},
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            switch (value.*) {
                inline else => |*payload| countSpansWithFile(@TypeOf(payload.*), payload, want, count),
            }
        },
        else => {},
    }
}
