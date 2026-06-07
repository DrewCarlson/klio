//! `klio-diagnostics-gen build` — mines kotlinc factory declarations and
//! emits `src/diagnostics/generated/factories.zig`.
//!
//! Ported as a `pub fn run` taking parsed arguments, not a real `main`.

const std = @import("std");

const gen = @import("diagnostics_gen.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Exit codes mirroring the Rust binary's `ExitCode` usage.
pub const SUCCESS: u8 = 0;
pub const FAILURE: u8 = 1;
pub const USAGE: u8 = 2;

pub const Cmd = union(enum) {
    build: Build,
    /// An unrecognized subcommand; carries its name for the error message.
    unknown: []const u8,

    pub const Build = struct {
        /// Path to the upstream Kotlin checkout root.
        kotlin: ?[]const u8 = null,
        /// Output path for the generated factories file.
        out: ?[]const u8 = null,
    };
};

/// Parse a raw argument vector (excluding the program name) into a `Cmd`,
/// matching the Rust `main`'s subcommand + flag handling.
pub fn parseArgs(args: []const []const u8) Cmd {
    const cmd_name = if (args.len >= 1) args[0] else "build";
    const rest: []const []const u8 = if (args.len > 1) args[1..] else &.{};
    if (std.mem.eql(u8, cmd_name, "build")) {
        var build_cmd = Cmd.Build{};
        var i: usize = 0;
        while (i < rest.len) {
            if (std.mem.eql(u8, rest[i], "--kotlin")) {
                if (i + 1 < rest.len) {
                    build_cmd.kotlin = rest[i + 1];
                    i += 2;
                    continue;
                }
            } else if (std.mem.eql(u8, rest[i], "--out")) {
                if (i + 1 < rest.len) {
                    build_cmd.out = rest[i + 1];
                    i += 2;
                    continue;
                }
            }
            i += 1;
        }
        return .{ .build = build_cmd };
    }
    return .{ .unknown = cmd_name };
}

/// Run a parsed subcommand. `writer`/`err_writer` receive stdout/stderr text.
/// Returns the process exit code.
pub fn run(
    allocator: Allocator,
    io: Io,
    cmd: Cmd,
    err_writer: *std.Io.Writer,
) Allocator.Error!u8 {
    return switch (cmd) {
        .build => |b| build(allocator, io, b, err_writer),
        .unknown => |name| {
            err_writer.print("unknown subcommand: {s}\n", .{name}) catch {};
            err_writer.print("usage: klio-diagnostics-gen build [--kotlin <path>] [--out <path>]\n", .{}) catch {};
            return USAGE;
        },
    };
}

fn build(allocator: Allocator, io: Io, args: Cmd.Build, err_writer: *std.Io.Writer) Allocator.Error!u8 {
    const kotlin = if (args.kotlin) |k|
        try allocator.dupe(u8, k)
    else
        try defaultKotlinRoot(allocator);
    defer allocator.free(kotlin);

    const out = if (args.out) |o|
        try allocator.dupe(u8, o)
    else
        try defaultOutFile(allocator);
    defer allocator.free(out);

    if (!isDir(io, kotlin)) {
        err_writer.print("kotlin checkout not found: {s}\n", .{kotlin}) catch {};
        return USAGE;
    }

    err_writer.print("mining {s}\n", .{kotlin}) catch {};
    const factories = try gen.mine(allocator, io, kotlin);
    defer gen.freeFactories(allocator, factories);
    err_writer.print("found {d} factories\n", .{factories.len}) catch {};

    emit(allocator, io, factories, out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => {
            err_writer.print("emit failed\n", .{}) catch {};
            return FAILURE;
        },
    };
    err_writer.print("wrote {s}\n", .{out}) catch {};
    return SUCCESS;
}

const EmitError = error{WriteFailed} || Allocator.Error;

/// Render `factories` and write them to `out_file`, creating parent
/// directories as needed.
fn emit(allocator: Allocator, io: Io, factories: []const gen.Factory, out_file: []const u8) EmitError!void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(out_file)) |parent| {
        cwd.createDirPath(io, parent) catch return error.WriteFailed;
    }
    const text = try gen.render(allocator, factories);
    defer allocator.free(text);
    cwd.writeFile(io, .{ .sub_path = out_file, .data = text }) catch return error.WriteFailed;
}

/// Kotlin checkout root, resolved relative to the working directory the
/// generator runs from (the workspace root).
fn defaultKotlinRoot(allocator: Allocator) Allocator.Error![]u8 {
    return allocator.dupe(u8, "kotlin");
}

/// Output path for the generated factories file, relative to the workspace
/// root the generator runs from.
fn defaultOutFile(allocator: Allocator) Allocator.Error![]u8 {
    return allocator.dupe(u8, "src/diagnostics/generated/factories.zig");
}

fn isDir(io: Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const testing = std.testing;

test "parseArgs defaults to build" {
    const args = [_][]const u8{};
    const cmd = parseArgs(&args);
    try testing.expect(cmd == .build);
    try testing.expect(cmd.build.kotlin == null);
    try testing.expect(cmd.build.out == null);
}

test "parseArgs reads kotlin and out flags" {
    const args = [_][]const u8{ "build", "--kotlin", "/k", "--out", "/o" };
    const cmd = parseArgs(&args);
    try testing.expect(cmd == .build);
    try testing.expectEqualStrings("/k", cmd.build.kotlin.?);
    try testing.expectEqualStrings("/o", cmd.build.out.?);
}

test "parseArgs reports an unknown subcommand" {
    const args = [_][]const u8{"frobnicate"};
    const cmd = parseArgs(&args);
    try testing.expect(cmd == .unknown);
    try testing.expectEqualStrings("frobnicate", cmd.unknown);
}

test "run reports an unknown subcommand" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err_buf: [256]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);
    const code = try run(testing.allocator, io, .{ .unknown = "frobnicate" }, &err_w);
    try testing.expectEqual(USAGE, code);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "unknown subcommand: frobnicate") != null);
}

test "build reports a missing kotlin checkout" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var err_buf: [256]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);
    const cmd = Cmd{ .build = .{ .kotlin = "this/dir/does/not/exist", .out = "ignored" } };
    const code = try run(testing.allocator, io, cmd, &err_w);
    try testing.expectEqual(USAGE, code);
    try testing.expect(std.mem.indexOf(u8, err_w.buffered(), "kotlin checkout not found") != null);
}
