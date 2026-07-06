//! `klio` command-line entry point: argument parsing + subcommand
//! dispatch.
//!
//! The parsing is hand-rolled to stay dependency-free; the surface
//! (subcommands, flags, usage) is fixed.
//!
//! The exe root (`src/main.zig`) owns `pub fn main` and calls
//! `cli.run(gpa)`, which returns the process exit code.

const std = @import("std");

const ir = @import("ir");
const interp_ir = @import("interp_ir");
const runtime = @import("runtime");

const io = @import("io.zig");

const commands = @import("commands.zig");
const DiagFormat = commands.DiagFormat;

const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;

const pack_build = @import("pack_build.zig");
const project = @import("project.zig");
const PackCmd = pack_build.PackCmd;

const stdlib_image = @import("stdlib_image.zig");

const unimplemented = @import("unimplemented.zig");

const VERSION = "0.1.0";

const USAGE =
    \\klio — Experimental Kotlin interpreter
    \\
    \\Usage: klio <command> [options]
    \\
    \\Commands:
    \\  lex <file>                 Lex a source file and print tokens.
    \\  parse <file>               Parse a source file and print the AST.
    \\  dump-ir <file> [--func N]  Lower a file and print its IR (no execution),
    \\                             tallying DIRECT vs DYNAMIC call sites.
    \\  run <file...> [options]    Run one or more `.kt` source files.
    \\  test <file|dir...>         Run `kotlin.test` `@Test` functions.
    \\  check <file...> [options]  Type-check `.kt` files and emit diagnostics.
    \\  bake [file...] [options]   Bake the stdlib image cache (`klio run` does
    \\                             this automatically on first use).
    \\  repl                       Start an interactive REPL.
    \\  pack <subcommand>          Build or inspect a `.klio-pack` artifact.
    \\
    \\Performance (any command; also via the KLIO_OPT env var):
    \\  --opt <fast|safe|off>      fast (default): JIT + bounded GC. safe: no JIT.
    \\                             off: interpreter + never-free arena.
    \\
    \\Run options:
    \\  --ir-vm                    Accepted for compatibility (no-op).
    \\  --virtual-time             Use deterministic virtual time for coroutines.
    \\  --feature <pack>/<feature> Enable a pack feature (repeatable).
    \\
    \\Check options:
    \\  --format <plain|json|sarif>  Output format for diagnostics.
    \\  --feature <pack>/<feature>   Enable a pack feature (repeatable).
    \\  --unimplemented              Report unimplemented `expect` declarations.
    \\
;

/// Public entry point. Parses process args, dispatches to the matching
/// subcommand, and returns the process exit code. The exe's `main`
/// calls this, passing the entry-point command-line arguments.
pub fn run(gpa: std.mem.Allocator, args_in: std.process.Args) !u8 {
    // Host-protection backstops: cap the process's RSS (default 6 GiB) so a
    // runaway program aborts before OOMing the machine, and arm the opt-in
    // wall-clock run deadline. Both are call-once and default-safe.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();

    const argv = try io.processArgs(gpa, args_in);
    defer io.freeArgs(gpa, argv);

    // argv[0] is the program name.
    const args = argv[1..];
    if (args.len == 0) {
        printErr(gpa, "{s}", .{USAGE});
        return 2;
    }

    const cmd = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        printOut(gpa, "klio {s}\n", .{VERSION});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printOut(gpa, "{s}", .{USAGE});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "lex")) {
        return runLexCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "parse")) {
        return runParseCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "dump-ir")) {
        return runDumpIrCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "run")) {
        return runRunCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "test")) {
        return runTestCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "check")) {
        return runCheckCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        return commands.runRepl(gpa);
    } else if (std.mem.eql(u8, cmd, "pack")) {
        return runPackCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bake")) {
        return runBakeCmd(gpa, rest);
    }

    printErr(gpa, "error: unknown command `{s}`\n\n{s}", .{ cmd, USAGE });
    return 2;
}

fn runLexCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 1) {
        printErr(gpa, "usage: klio lex <file.kt>\n", .{});
        return 2;
    }
    return commands.runLex(gpa, args[0]);
}

fn runParseCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 1) {
        printErr(gpa, "usage: klio parse <file.kt>\n", .{});
        return 2;
    }
    return commands.runParse(gpa, args[0]);
}

fn runDumpIrCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var file: ?[]const u8 = null;
    var opts: ir.disasm.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, a, "--func")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "usage: klio dump-ir <file.kt> [--func NAME] [--all]\n", .{});
                return 2;
            }
            opts.func_filter = args[i];
        } else if (optionValue(a, "--func=")) |v| {
            opts.func_filter = v;
        } else if (std.mem.startsWith(u8, a, "--")) {
            printErr(gpa, "error: unknown option `{s}`\n", .{a});
            return 2;
        } else {
            file = a;
        }
    }
    if (file == null) {
        printErr(gpa, "usage: klio dump-ir <file.kt> [--func NAME] [--all]\n", .{});
        return 2;
    }
    var requested = parseRequestedFeatures(gpa, &.{});
    defer deinitRequestedFeatures(&requested);
    return commands.runDumpIr(gpa, file.?, opts, &requested);
}

fn runRunCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var virtual_time = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--ir-vm")) {
            // Accepted for compatibility; the IR Vm is the only path.
        } else if (std.mem.eql(u8, a, "--virtual-time")) {
            virtual_time = true;
        } else if (std.mem.eql(u8, a, "--feature")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --feature requires a `<pack>/<feature>` value\n", .{});
                return 2;
            }
            feature_specs.append(gpa, args[i]) catch return 2;
        } else if (optionValue(a, "--feature=")) |v| {
            feature_specs.append(gpa, v) catch return 2;
        } else if (perfOptValue(a, args, &i)) |v| {
            // Applied at startup; validate here so a typo is rejected, not run.
            if (runtime.perf.parseProfile(v) == null) {
                printErr(gpa, "error: unknown --opt `{s}` (use fast|safe|off)\n", .{v});
                return 2;
            }
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-O")) {
            printErr(gpa, "error: unknown option `{s}`\n", .{a});
            return 2;
        } else {
            files.append(gpa, a) catch return 2;
        }
    }

    if (virtual_time) {
        interp_ir.setCoroutineTimeMode(.Virtual);
    }

    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);

    if (files.items.len == 0) {
        printErr(gpa, "usage: klio run <file.kt> [<file2.kt> ...]\n", .{});
        return 2;
    }
    if (files.items.len == 1) {
        return commands.runFileIrVm(gpa, files.items[0], &requested);
    }
    return commands.runModuleFiles(gpa, files.items, &requested);
}

fn runTestCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var only_files: std.ArrayList([]const u8) = .empty;
    defer only_files.deinit(gpa);
    var virtual_time = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--virtual-time")) {
            virtual_time = true;
        } else if (std.mem.eql(u8, a, "--only-file")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --only-file requires a path\n", .{});
                return 2;
            }
            only_files.append(gpa, args[i]) catch return 2;
        } else if (optionValue(a, "--only-file=")) |v| {
            only_files.append(gpa, v) catch return 2;
        } else if (std.mem.eql(u8, a, "--feature")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --feature requires a `<pack>/<feature>` value\n", .{});
                return 2;
            }
            feature_specs.append(gpa, args[i]) catch return 2;
        } else if (optionValue(a, "--feature=")) |v| {
            feature_specs.append(gpa, v) catch return 2;
        } else if (perfOptValue(a, args, &i)) |v| {
            if (runtime.perf.parseProfile(v) == null) {
                printErr(gpa, "error: unknown --opt `{s}` (use fast|safe|off)\n", .{v});
                return 2;
            }
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-O")) {
            printErr(gpa, "error: unknown option `{s}`\n", .{a});
            return 2;
        } else {
            paths.append(gpa, a) catch return 2;
        }
    }

    if (virtual_time) {
        interp_ir.setCoroutineTimeMode(.Virtual);
    }

    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);

    // No path → the project in the current directory.
    if (paths.items.len == 0) paths.append(gpa, ".") catch return 2;

    // Project mode: a single directory carrying `klio.toml` (with `[[test]]`
    // sets) runs that project's composed test sources against its
    // built+installed pack — no hand-listed files. `planTest` returns null for
    // a plain file/dir, so the normal path handles everything else.
    if (paths.items.len == 1) {
        if (project.planTest(gpa, paths.items[0], &requested)) |plan| {
            if (buildAndInstallProjectPack(gpa, plan.project_dir, plan.pack_id)) |code| {
                if (code != 0) return code;
            }
            return commands.runTestFiles(gpa, plan.roots, &requested, only_files.items);
        }
    }
    return commands.runTestFiles(gpa, paths.items, &requested, only_files.items);
}

/// Build the project pack from `dir` and install it so its API resolves in
/// the project's tests. Returns the failing exit code, or 0/null on success.
fn buildAndInstallProjectPack(gpa: std.mem.Allocator, dir: []const u8, id: []const u8) ?u8 {
    if (id.len == 0) return null; // not a library project — nothing to install
    const b = pack_build.runPack(gpa, .{ .Build = .{ .dir = dir } });
    if (b != 0) return b;
    const artifact = std.fmt.allocPrint(gpa, "target/packs/{s}.klio-pack", .{id}) catch return 2;
    defer gpa.free(artifact);
    return pack_build.runPack(gpa, .{ .Install = .{ .pack = artifact } });
}

fn runBakeCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--feature")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --feature requires a `<pack>/<feature>` value\n", .{});
                return 2;
            }
            feature_specs.append(gpa, args[i]) catch return 2;
        } else if (optionValue(a, "--feature=")) |v| {
            feature_specs.append(gpa, v) catch return 2;
        } else if (perfOptValue(a, args, &i)) |v| {
            // Applied at startup; validate here so a typo is rejected, not run.
            if (runtime.perf.parseProfile(v) == null) {
                printErr(gpa, "error: unknown --opt `{s}` (use fast|safe|off)\n", .{v});
                return 2;
            }
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-O")) {
            printErr(gpa, "error: unknown option `{s}`\n", .{a});
            return 2;
        } else {
            files.append(gpa, a) catch return 2;
        }
    }

    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);
    return stdlib_image.runBake(gpa, files.items, &requested);
}

fn runCheckCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var format: DiagFormat = .Plain;
    var want_unimplemented = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--unimplemented")) {
            want_unimplemented = true;
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --format requires a value (plain|json|sarif)\n", .{});
                return 2;
            }
            format = parseFormat(args[i]) orelse {
                printErr(gpa, "error: unknown --format `{s}` (use plain|json|sarif)\n", .{args[i]});
                return 2;
            };
        } else if (optionValue(a, "--format=")) |v| {
            format = parseFormat(v) orelse {
                printErr(gpa, "error: unknown --format `{s}` (use plain|json|sarif)\n", .{v});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--feature")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --feature requires a `<pack>/<feature>` value\n", .{});
                return 2;
            }
            feature_specs.append(gpa, args[i]) catch return 2;
        } else if (optionValue(a, "--feature=")) |v| {
            feature_specs.append(gpa, v) catch return 2;
        } else if (perfOptValue(a, args, &i)) |v| {
            // Applied at startup; validate here so a typo is rejected, not run.
            if (runtime.perf.parseProfile(v) == null) {
                printErr(gpa, "error: unknown --opt `{s}` (use fast|safe|off)\n", .{v});
                return 2;
            }
        } else if (std.mem.startsWith(u8, a, "--") or std.mem.startsWith(u8, a, "-O")) {
            printErr(gpa, "error: unknown option `{s}`\n", .{a});
            return 2;
        } else {
            files.append(gpa, a) catch return 2;
        }
    }

    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);

    if (want_unimplemented) {
        return unimplemented.runCheckUnimplemented(gpa, files.items, &requested);
    }
    return commands.runCheck(gpa, files.items, format, &requested);
}

fn runPackCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        printErr(gpa, "usage: klio pack <build|stdlib|install|list|remove|inspect|verify|new|migrate|publish|search|fetch> ...\n", .{});
        return 2;
    }
    const cmd = parsePackCmd(args) orelse {
        printErr(gpa, "error: unknown or malformed `klio pack` subcommand\n", .{});
        return 2;
    };
    return pack_build.runPack(gpa, cmd);
}

/// Parse the minimal positional form of each pack subcommand. Flag-heavy
/// variants take their defaults here; full flag parsing lands with the
/// pack_build fill.
fn parsePackCmd(args: []const []const u8) ?PackCmd {
    const sub = args[0];
    const pos = args[1..];
    if (std.mem.eql(u8, sub, "build")) {
        if (pos.len < 1) return null;
        return .{ .Build = .{ .dir = pos[0] } };
    } else if (std.mem.eql(u8, sub, "stdlib")) {
        return .{ .Stdlib = .{} };
    } else if (std.mem.eql(u8, sub, "install")) {
        if (pos.len < 1) return null;
        return .{ .Install = .{ .pack = pos[0] } };
    } else if (std.mem.eql(u8, sub, "list")) {
        return .List;
    } else if (std.mem.eql(u8, sub, "remove")) {
        if (pos.len < 1) return null;
        return .{ .Remove = .{ .library_id = pos[0] } };
    } else if (std.mem.eql(u8, sub, "inspect")) {
        if (pos.len < 1) return null;
        return .{ .Inspect = .{ .pack = pos[0] } };
    } else if (std.mem.eql(u8, sub, "verify")) {
        if (pos.len < 1) return null;
        return .{ .Verify = .{ .pack = pos[0] } };
    } else if (std.mem.eql(u8, sub, "new")) {
        if (pos.len < 1) return null;
        return .{ .New = .{ .dir = pos[0] } };
    } else if (std.mem.eql(u8, sub, "migrate")) {
        if (pos.len < 1) return null;
        return .{ .Migrate = .{ .input = pos[0] } };
    } else if (std.mem.eql(u8, sub, "publish")) {
        if (pos.len < 1) return null;
        return .{ .Publish = .{ .pack = pos[0] } };
    } else if (std.mem.eql(u8, sub, "search")) {
        if (pos.len < 1) return null;
        return .{ .Search = .{ .query = pos[0] } };
    } else if (std.mem.eql(u8, sub, "fetch")) {
        if (pos.len < 1) return null;
        return .{ .Fetch = .{ .library_id = pos[0] } };
    }
    return null;
}

fn parseFormat(s: []const u8) ?DiagFormat {
    if (std.mem.eql(u8, s, "plain")) return .Plain;
    if (std.mem.eql(u8, s, "json")) return .Json;
    if (std.mem.eql(u8, s, "sarif")) return .Sarif;
    return null;
}

/// `--name=value` -> `value`, else null.
fn optionValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// The performance profile flag (`--opt <p>` / `--opt=<p>` / `-O<p>` / `-O <p>`)
/// is applied at process start (see `main.zig`), before the allocator is chosen.
/// Subcommand parsers call this to consume it as a recognized no-op. Returns
/// `null` if `a` is not the flag; otherwise the flag's value (empty if missing),
/// advancing `i` past a separate value argument.
fn perfOptValue(a: []const u8, args: []const []const u8, i: *usize) ?[]const u8 {
    if (std.mem.eql(u8, a, "--opt") or std.mem.eql(u8, a, "-O")) {
        if (i.* + 1 < args.len) {
            i.* += 1;
            return args[i.*];
        }
        return "";
    }
    if (optionValue(a, "--opt=")) |v| return v;
    if (std.mem.startsWith(u8, a, "-O") and a.len > 2) return a[2..];
    return null;
}

/// Parse `--feature <pack>/<feature>` specs into a per-pack requested
/// feature map. A bare spec with no `/` can't say which pack to enable
/// the feature on, so it is reported and skipped.
fn parseRequestedFeatures(gpa: std.mem.Allocator, specs: []const []const u8) RequestedFeatures {
    var out = RequestedFeatures.init(gpa);
    for (specs) |spec| {
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
            const pack = std.mem.trim(u8, spec[0..slash], " \t");
            const feat = std.mem.trim(u8, spec[slash + 1 ..], " \t");
            const gop = out.getOrPut(pack) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.StringHashMap(void).init(gpa);
            }
            gop.value_ptr.put(feat, {}) catch {};
        } else {
            printErr(
                gpa,
                "warning: --feature `{s}` ignored; use `<pack>/<feature>` (e.g. io.ktor/server)\n",
                .{spec},
            );
        }
    }
    return out;
}

fn deinitRequestedFeatures(rf: *RequestedFeatures) void {
    var it = rf.valueIterator();
    while (it.next()) |v| v.deinit();
    rf.deinit();
}

fn printOut(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    io.printStdout(gpa, fmt, args);
}

fn printErr(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    io.printStderr(gpa, fmt, args);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(commands);
    std.testing.refAllDecls(pack_cache);
    std.testing.refAllDecls(pack_build);
    std.testing.refAllDecls(unimplemented);
    std.testing.refAllDecls(stdlib_image);
    std.testing.refAllDecls(io);
}

test "parseFormat maps known formats" {
    try std.testing.expectEqual(DiagFormat.Plain, parseFormat("plain").?);
    try std.testing.expectEqual(DiagFormat.Json, parseFormat("json").?);
    try std.testing.expectEqual(DiagFormat.Sarif, parseFormat("sarif").?);
    try std.testing.expect(parseFormat("yaml") == null);
}

test "optionValue extracts =value" {
    try std.testing.expectEqualStrings("json", optionValue("--format=json", "--format=").?);
    try std.testing.expect(optionValue("--format", "--format=") == null);
}

test "parseRequestedFeatures splits pack/feature" {
    const gpa = std.testing.allocator;
    var rf = parseRequestedFeatures(gpa, &.{"io.ktor/server"});
    defer deinitRequestedFeatures(&rf);
    const feats = rf.get("io.ktor").?;
    try std.testing.expect(feats.contains("server"));
}

test "parsePackCmd list and build" {
    const list = parsePackCmd(&.{"list"}).?;
    try std.testing.expectEqualStrings("List", @tagName(list));
    const build = parsePackCmd(&.{ "build", "libdir" }).?;
    try std.testing.expectEqualStrings("Build", @tagName(build));
    try std.testing.expect(parsePackCmd(&.{"build"}) == null);
}
