//! `klio` command-line entry point: argument parsing + subcommand
//! dispatch.
//!
//! The parsing is hand-rolled to stay dependency-free; the surface
//! (subcommands, flags, usage) is fixed.
//!
//! The exe root (`src/main.zig`) owns `pub fn main` and calls
//! `cli.run(gpa)`, which returns the process exit code.

const std = @import("std");
const parser = @import("parser");

const ir = @import("ir");
const interp_ir = @import("interp_ir");
const runtime = @import("runtime");

const io = @import("io.zig");

/// Exported for the `klio_rt` C-ABI library (the C transpiler's bootstrap
/// drives `runFileIrVm` directly).
pub const commands = @import("commands.zig");
const DiagFormat = commands.DiagFormat;

const pack_cache = @import("pack_cache.zig");
const RequestedFeatures = pack_cache.RequestedFeatures;

const pack_build = @import("pack_build.zig");
const project = @import("project.zig");
const PackCmd = pack_build.PackCmd;

const stdlib_image = @import("stdlib_image.zig");

const unimplemented = @import("unimplemented.zig");

pub const bundle = @import("bundle.zig");
const bundle_boot = @import("bundle_boot.zig");

pub const VERSION = "0.1.0";

/// Whether the running executable carries a bundle payload (memoized
/// probe). The exe entry point consults this before interpreting argv —
/// bundle argv belongs entirely to the embedded program.
pub const bundleModeActive = bundle_boot.bundleModeActive;

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
    \\                             --language=+Feature[,+Other] enables a parser-gated
    \\                             language feature (kotlinc `-XXLanguage:+Feature`).
    \\  test [path] [options]      Run `kotlin.test` `@Test` functions. A
    \\                             project dir (with klio.toml) tests its
    \\                             composed `[[test]]` sets; default `.`.
    \\                             --all / --feature X select feature modules.
    \\  check <file...> [options]  Type-check `.kt` files and emit diagnostics.
    \\  bake [file...] [options]   Bake the stdlib image cache (`klio run` does
    \\                             this automatically on first use).
    \\  bundle <file|dir> [opts]   Package a program (with its baked
    \\                             dependencies, resources, and rendering
    \\                             backend) into one self-contained executable.
    \\  bake-image <file> -o <p>   Bake the dependency base (stdlib + the
    \\                             program's packs) to a standalone .klio-image.
    \\  run-image <base> <file>    Run a program against a pre-baked base image.
    \\  transpile <file> [-o out]  Emit the program as C over the klio_rt per-op
    \\                             ABI plus its pinned base image (out.c +
    \\                             out.klio-image; compile with zig cc +
    \\                             libklio_rt.a).
    \\  repl                       Start an interactive REPL.
    \\  pack <subcommand>          Build or inspect a `.klio-pack` artifact.
    \\
    \\Performance (any command; also via the KLIO_OPT env var):
    \\  --opt <fast|safe|off>      fast (default): JIT + bounded GC. safe: no JIT.
    \\                             off: interpreter + never-free arena.
    \\
    \\Run options:
    \\  --virtual-time             Use deterministic virtual time for coroutines.
    \\  --feature <pack>/<feature> Enable a pack feature (repeatable).
    \\
    \\Test options:
    \\  --filter <substrings>        Run only tests whose Class/method/file matches
    \\                               any of the comma-separated substrings.
    \\  --format <plain|json>        plain (default) or a machine-readable JSON summary.
    \\  --all / --feature <name>     Select which feature modules' tests to run.
    \\  --list                       List discovered @Test names without running them.
    \\  --isolate [--timeout <s>]    Debug: run each test in its own sub-process with a
    \\                               per-test timeout (default 60s) to pinpoint a hang/crash.
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
    const argv = try io.processArgs(gpa, args_in);
    defer io.freeArgs(gpa, argv);
    return runArgv(gpa, argv);
}

/// Run the CLI over a pre-built argv (argv[0] is the program name). The native
/// entry (`run`) builds argv from the OS process args; the mobile C-ABI entry
/// (`klio_run`, in the app host) synthesizes an argv and calls this directly.
pub fn runArgv(gpa: std.mem.Allocator, argv: []const []const u8) !u8 {
    // Host-protection backstops: cap the process's RSS (default 6 GiB) so a
    // runaway program aborts before OOMing the machine, and arm the opt-in
    // wall-clock run deadline. Both are call-once and default-safe.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    commands.loadLeafLibrary();
    defer commands.leafDiagDump();

    // A bundle payload appended to this executable takes over the whole
    // process: argv[1..] belongs to the embedded program and klio
    // subcommands are unreachable.
    if (bundle_boot.bundleModeActive()) {
        return bundle_boot.run(gpa, argv);
    }

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
    } else if (std.mem.eql(u8, cmd, "transpile-dump")) {
        if (rest.len != 1) {
            printErr(gpa, "usage: klio transpile-dump <file.kt>\n", .{});
            return 2;
        }
        var features = commands.RequestedFeatures.init(gpa);
        defer features.deinit();
        return commands.runTranspileDump(gpa, rest[0], &features);
    } else if (std.mem.eql(u8, cmd, "transpile")) {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(gpa);
        var out: ?[]const u8 = null;
        var bad = false;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "-o")) {
                if (i + 1 >= rest.len or out != null) {
                    bad = true;
                    break;
                }
                out = rest[i + 1];
                i += 1;
            } else {
                files.append(gpa, rest[i]) catch return 1;
            }
        }
        if (bad or files.items.len == 0) {
            printErr(gpa, "usage: klio transpile <file.kt> [more.kt ...] [-o out.c]\n", .{});
            return 2;
        }
        var features = commands.RequestedFeatures.init(gpa);
        defer features.deinit();
        return commands.runTranspile(gpa, files.items, out, &features);
    }
    if (std.c.getenv("KLIO_LANGUAGE")) |env_specs| applyLanguageSpecs(std.mem.span(env_specs));
    if (std.mem.eql(u8, cmd, "run")) {
        return runRunCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "test")) {
        return runTestCmd(gpa, rest, argv[0]);
    } else if (std.mem.eql(u8, cmd, "check")) {
        return runCheckCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        return commands.runRepl(gpa);
    } else if (std.mem.eql(u8, cmd, "pack")) {
        return runPackCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bake")) {
        return runBakeCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bundle")) {
        return bundle.runBundle(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bake-image")) {
        return runBakeImageCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "run-image")) {
        return runRunImageCmd(gpa, rest);
    }

    printErr(gpa, "error: unknown command `{s}`\n\n{s}", .{ cmd, USAGE });
    return 2;
}

fn usageBakeImage(gpa: std.mem.Allocator) u8 {
    printErr(gpa, "usage: klio bake-image <program.kt> -o <base.klio-image> [--feature <pack>/<feat>]\n", .{});
    return 2;
}

fn runBakeImageCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var out: ?[]const u8 = null;
    var program: ?[]const u8 = null;
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return usageBakeImage(gpa);
            out = args[i];
        } else if (std.mem.eql(u8, a, "--feature")) {
            i += 1;
            if (i >= args.len) return usageBakeImage(gpa);
            feature_specs.append(gpa, args[i]) catch return 1;
        } else if (program == null) {
            program = a;
        } else {
            return usageBakeImage(gpa);
        }
    }
    if (program == null or out == null) return usageBakeImage(gpa);
    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);
    return bundle.bakeImage(gpa, &.{program.?}, &requested, out.?);
}

fn runRunImageCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 2) {
        printErr(gpa, "usage: klio run-image <base.klio-image> <program.kt> [args...]\n", .{});
        return 2;
    }
    return bundle.runImage(gpa, args[0], &.{args[1]}, args[2..]);
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
        if (std.mem.eql(u8, a, "--virtual-time")) {
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
        } else if (optionValue(a, "--language=")) |v| {
            applyLanguageSpecs(v);
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

fn runTestCmd(gpa: std.mem.Allocator, args: []const []const u8, self_exe: []const u8) u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var only_files: std.ArrayList([]const u8) = .empty;
    defer only_files.deinit(gpa);
    // Bare `--feature X` (no `/`) selects a project's own feature module for a
    // project-mode run; a `<pack>/<feat>` spec keeps its existing meaning.
    var project_features: std.ArrayList([]const u8) = .empty;
    defer project_features.deinit(gpa);
    var all_features = false;
    var virtual_time = false;
    var filter: ?[]const u8 = null;
    var test_format: commands.TestFormat = .plain;
    var list_only = false;
    var isolate = false;
    var jobs: usize = 1;
    var timeout_s: u64 = 60;
    _ = &jobs;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--virtual-time")) {
            virtual_time = true;
        } else if (std.mem.eql(u8, a, "--format") or optionValue(a, "--format=") != null) {
            const v = if (optionValue(a, "--format=")) |vv| vv else blk: {
                i += 1;
                if (i >= args.len) {
                    printErr(gpa, "error: --format requires a value (plain|json)\n", .{});
                    return 2;
                }
                break :blk args[i];
            };
            if (std.mem.eql(u8, v, "json")) {
                test_format = .json;
            } else if (std.mem.eql(u8, v, "plain")) {
                test_format = .plain;
            } else {
                printErr(gpa, "error: unknown --format `{s}` (use plain|json)\n", .{v});
                return 2;
            }
        } else if (std.mem.eql(u8, a, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, a, "--isolate")) {
            isolate = true;
        } else if (std.mem.eql(u8, a, "--jobs") or optionValue(a, "--jobs=") != null) {
            const v = if (optionValue(a, "--jobs=")) |vv| vv else blk: {
                i += 1;
                if (i >= args.len) {
                    printErr(gpa, "error: --jobs requires a number\n", .{});
                    return 2;
                }
                break :blk args[i];
            };
            jobs = std.fmt.parseInt(usize, v, 10) catch {
                printErr(gpa, "error: --jobs must be a positive integer\n", .{});
                return 2;
            };
            if (jobs == 0) jobs = 1;
        } else if (std.mem.eql(u8, a, "--timeout") or optionValue(a, "--timeout=") != null) {
            const v = if (optionValue(a, "--timeout=")) |vv| vv else blk: {
                i += 1;
                if (i >= args.len) {
                    printErr(gpa, "error: --timeout requires a number of seconds\n", .{});
                    return 2;
                }
                break :blk args[i];
            };
            timeout_s = std.fmt.parseInt(u64, v, 10) catch {
                printErr(gpa, "error: --timeout must be a positive integer (seconds)\n", .{});
                return 2;
            };
            if (timeout_s == 0) timeout_s = 1;
        } else if (std.mem.eql(u8, a, "--all")) {
            all_features = true;
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= args.len) {
                printErr(gpa, "error: --filter requires a name substring\n", .{});
                return 2;
            }
            filter = args[i];
        } else if (optionValue(a, "--filter=")) |v| {
            filter = v;
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
                printErr(gpa, "error: --feature requires a `<feature>` or `<pack>/<feature>` value\n", .{});
                return 2;
            }
            addFeatureSpec(gpa, args[i], &feature_specs, &project_features);
        } else if (optionValue(a, "--feature=")) |v| {
            addFeatureSpec(gpa, v, &feature_specs, &project_features);
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

    // `--isolate` (opt-in debug): re-invoke `klio test` once per discovered
    // test in its own sub-process with a per-test wall-clock timeout, to
    // pinpoint which test hangs or crashes. The child re-parses the same base
    // args (paths + feature/only-file selection) plus `--filter`.
    if (isolate) {
        var base: std.ArrayList([]const u8) = .empty;
        defer base.deinit(gpa);
        for (paths.items) |p| base.append(gpa, p) catch return 2;
        if (all_features) base.append(gpa, "--all") catch return 2;
        for (project_features.items) |fs| {
            base.append(gpa, "--feature") catch return 2;
            base.append(gpa, fs) catch return 2;
        }
        for (only_files.items) |of| {
            base.append(gpa, "--only-file") catch return 2;
            base.append(gpa, of) catch return 2;
        }
        if (filter) |f| {
            base.append(gpa, "--filter") catch return 2;
            base.append(gpa, f) catch return 2;
        }
        return commands.runTestsIsolated(gpa, self_exe, base.items, timeout_s);
    }

    // Project mode: a single directory carrying `klio.toml` (with `[[test]]`
    // sets) runs that project's composed test sources against its
    // built+installed pack — no hand-listed files. `planTest` returns null for
    // a plain file/dir, so the normal path handles everything else.
    //
    // Feature selection: default (and `--all`) tests core + every feature
    // module; `--feature X` narrows to core + the named feature(s).
    if (paths.items.len == 1) {
        const sel: project.FeatureSel = if (!all_features and project_features.items.len != 0)
            .{ .selected = project_features.items }
        else
            .all;
        if (project.planTest(gpa, paths.items[0], sel)) |plan| {
            // Activate the tested features' sources so their tests compile.
            activateFeatures(gpa, &requested, plan.pack_id, plan.active_features);
            if (buildAndInstallProjectPack(gpa, plan.project_dir, plan.pack_id)) |code| {
                if (code != 0) return code;
            }
            return commands.runTestFiles(gpa, plan.roots, &requested, only_files.items, filter, test_format, list_only);
        }
    }
    return commands.runTestFiles(gpa, paths.items, &requested, only_files.items, filter, test_format, list_only);
}

/// Route a `--feature` value: `<pack>/<feat>` keeps its cross-pack meaning; a
/// bare `<feat>` selects the current project's own feature module.
fn addFeatureSpec(
    gpa: std.mem.Allocator,
    v: []const u8,
    feature_specs: *std.ArrayList([]const u8),
    project_features: *std.ArrayList([]const u8),
) void {
    if (std.mem.indexOfScalar(u8, v, '/') != null) {
        feature_specs.append(gpa, v) catch {};
    } else {
        project_features.append(gpa, v) catch {};
    }
}

/// Merge a project's active test features into the requested-feature set under
/// its pack id, so the pack loader includes those feature modules' sources.
fn activateFeatures(
    gpa: std.mem.Allocator,
    requested: *RequestedFeatures,
    pack_id: []const u8,
    features: []const []const u8,
) void {
    if (pack_id.len == 0 or features.len == 0) return;
    const gop = requested.getOrPut(pack_id) catch return;
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(gpa);
    for (features) |f| {
        if (!gop.value_ptr.contains(f)) gop.value_ptr.put(f, {}) catch {};
    }
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
        } else if (optionValue(a, "--language=")) |v| {
            applyLanguageSpecs(v);
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
        } else if (optionValue(a, "--language=")) |v| {
            applyLanguageSpecs(v);
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
/// `+Feature[,+Other]` language specs (`--language=` or `KLIO_LANGUAGE`),
/// applied to the parser's process-wide toggles.
fn applyLanguageSpecs(specs: []const u8) void {
    var it = std.mem.tokenizeAny(u8, specs, ", ");
    while (it.next()) |spec| _ = parser.setLanguageFeature(spec);
}

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
    std.testing.refAllDecls(bundle);
    std.testing.refAllDecls(bundle_boot);
    std.testing.refAllDecls(@import("stub_fetch.zig"));
    std.testing.refAllDecls(@import("shim_extract.zig"));
    std.testing.refAllDecls(project);
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
