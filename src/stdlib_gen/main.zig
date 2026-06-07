//! Stdlib codegen entry point.
//!
//! Subcommands:
//! * `build` mines the upstream stdlib sources and emits the encoded symbol
//!   index for `stdlib`.
//! * `coverage` prints implemented / total counts from the current generated
//!   registry.
//!
//! Ported as a `pub fn run` taking parsed arguments, not a real `main`.

const std = @import("std");

const stdlib = @import("stdlib");

const walk = @import("walk.zig");
const emit = @import("emit.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Exit codes mirroring the Rust binary's `ExitCode` usage.
pub const SUCCESS: u8 = 0;
pub const FAILURE: u8 = 1;
pub const STDLIB_MISSING: u8 = 2;

pub const Cmd = union(enum) {
    build: Build,
    coverage,

    pub const Build = struct {
        /// Path to the upstream Kotlin checkout's stdlib root
        /// (`<repo>/kotlin/libraries/stdlib`).
        stdlib: ?[]const u8 = null,
        /// Output directory for generated data
        /// (`<repo>/src/stdlib/generated`).
        out: ?[]const u8 = null,
    };
};

/// Run a parsed subcommand. `writer`/`err_writer` receive stdout/stderr text.
/// Returns the process exit code.
pub fn run(
    allocator: Allocator,
    io: Io,
    cmd: Cmd,
    writer: *std.Io.Writer,
    err_writer: *std.Io.Writer,
) Allocator.Error!u8 {
    return switch (cmd) {
        .build => |b| build(allocator, io, b, err_writer),
        .coverage => coverage(writer),
    };
}

/// Workspace root, two directories up from the crate manifest dir. Matches the
/// Rust `workspace_root` helper; here it resolves relative to the cwd, which
/// the generator is run from.
fn workspaceRoot(allocator: Allocator) Allocator.Error![]const u8 {
    return allocator.dupe(u8, ".");
}

fn build(allocator: Allocator, io: Io, args: Cmd.Build, err_writer: *std.Io.Writer) Allocator.Error!u8 {
    const root = try workspaceRoot(allocator);
    defer allocator.free(root);

    const stdlib_path = if (args.stdlib) |s|
        try allocator.dupe(u8, s)
    else
        try std.fs.path.join(allocator, &.{ root, "kotlin/libraries/stdlib" });
    defer allocator.free(stdlib_path);

    const out_dir = if (args.out) |o|
        try allocator.dupe(u8, o)
    else
        try std.fs.path.join(allocator, &.{ root, "src/stdlib/generated" });
    defer allocator.free(out_dir);

    if (!isDir(io, stdlib_path)) {
        err_writer.print("stdlib root not found: {s}\n", .{stdlib_path}) catch {};
        return STDLIB_MISSING;
    }

    err_writer.print("mining {s}\n", .{stdlib_path}) catch {};
    var result = try walk.collectDecls(allocator, io, stdlib_path);
    defer result.deinit(allocator);

    err_writer.print(
        "scanned {d} files, parsed {d}, failed {d}\n",
        .{ result.stats.files_seen, result.stats.files_parsed, result.stats.files_failed.items.len },
    ) catch {};
    for (result.stats.files_failed.items) |f| {
        err_writer.print("  failed: {s} — {s}\n", .{ f.path, f.err }) catch {};
    }
    err_writer.print("extracted {d} declarations\n", .{result.stats.total_decls}) catch {};

    const n = emit.emitGenerated(allocator, io, out_dir, result.files) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Encode => {
            err_writer.print("emit failed\n", .{}) catch {};
            return FAILURE;
        },
    };
    err_writer.print("wrote {d} symbols to {s}\n", .{ n, out_dir }) catch {};
    return SUCCESS;
}

fn coverage(writer: *std.Io.Writer) Allocator.Error!u8 {
    const c = stdlib.coverage();
    writer.print(
        "implemented {d} / total {d} ({d:.2}%)\n",
        .{ c.implemented, c.total, c.percent() },
    ) catch {};
    if (c.total == 0) {
        writer.print("registry is empty — run `klio-stdlib-gen build` first\n", .{}) catch {};
    }
    return SUCCESS;
}

fn isDir(io: Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const testing = std.testing;

test "coverage prints implemented and total counts" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const code = try coverage(&w);
    try testing.expectEqual(SUCCESS, code);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "implemented") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "total") != null);
}

test "build reports a missing stdlib root" {
    const a = testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buf: [256]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_w = std.Io.Writer.fixed(&err_buf);

    const cmd = Cmd{ .build = .{ .stdlib = "this/dir/does/not/exist", .out = "ignored" } };
    const code = try run(a, io, cmd, &out_w, &err_w);
    try testing.expectEqual(STDLIB_MISSING, code);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "stdlib root not found") != null);
}
