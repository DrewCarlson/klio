//! `klio` command-line entry point: argument parsing and subcommand dispatch.
//! `src/main.zig` owns `pub fn main` and calls `cli.run(gpa)` for the exit code.

const std = @import("std");
const parser = @import("parser");

const ir = @import("ir");
/// Re-exported so the native runtime shim reaches the coroutine driver: a compiled
/// program drives coroutines on the same scheduler, not a second one.
pub const interp_ir = @import("interp_ir");
const runtime = @import("runtime");

const io = @import("io.zig");

/// Exported for the `klio_rt` C-ABI library, which drives `runFileIrVm` directly.
pub const commands = @import("commands.zig");
const DiagFormat = commands.DiagFormat;

const pack_cache = @import("pack_cache.zig");
const resolver = @import("resolver");
const RequestedFeatures = pack_cache.RequestedFeatures;

const pack_build = @import("pack_build.zig");
const project = @import("project.zig");
const ide = @import("ide.zig");
const PackCmd = pack_build.PackCmd;

const stdlib_image = @import("stdlib_image.zig");

const unimplemented = @import("unimplemented.zig");

pub const bundle = @import("bundle.zig");
pub const mem_census = @import("mem_census.zig");
const bundle_boot = @import("bundle_boot.zig");

pub const VERSION = "0.1.0";

/// Whether the running executable carries a bundle payload, memoized. Consulted
/// before argv is interpreted: bundle argv belongs to the embedded program.
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
    \\  ide <subcommand>           Emit the project model an editor builds its
    \\                             workspace from (`ide model`), or prune what
    \\                             it materialised (`ide gc`).
    \\
    \\Performance (any command; also via the KLIO_OPT env var):
    \\  --opt <fast|safe|off>      fast (default): JIT + bounded GC. safe: no JIT.
    \\                             off: interpreter + never-free arena.
    \\
    \\Run options:
    \\  --virtual-time             Use deterministic virtual time for coroutines.
    \\  --lazy-bodies              On a cold run, start before the stdlib's bodies lower:
    \\                             each lowers on its first call and the image completes
    \\                             after the program (KLIO_LAZY_BODIES=1, or lazy_bodies
    \\                             under [application] in klio.toml).
    \\  --feature <pack>/<feature> Enable a pack feature (repeatable).
    \\
    \\Test options:
    \\  --filter <substrings>        Run only tests whose Class/method/file matches
    \\                               any of the comma-separated substrings.
    \\  --format <plain|json|ij>     plain (default), a machine-readable JSON summary,
    \\                               or `ij` service messages an IDE test tree reads
    \\                               as each test finishes.
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

pub fn run(gpa: std.mem.Allocator, args_in: std.process.Args) !u8 {
    // The resolver's pool arenas come from the process allocator when it can
    // serve several threads, so their teardown parks blocks instead of unmapping.
    if (pack_cache.allocatorIsThreadSafe(gpa)) resolver.pool_backing = gpa;
    const argv = try io.processArgs(gpa, args_in);
    defer io.freeArgs(gpa, argv);
    return runArgv(gpa, argv);
}

/// `argv[0]` is the program name; the mobile C-ABI `klio_run` synthesizes one.
pub fn runArgv(gpa: std.mem.Allocator, argv: []const []const u8) !u8 {
    // Cap process RSS (default 6 GiB) so a runaway program aborts before OOMing the
    // machine, and arm the opt-in wall-clock deadline. Both are call-once.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    commands.loadLeafLibrary();
    defer commands.leafDiagDump();

    // An appended bundle payload takes over: argv[1..] belongs to the embedded program.
    if (bundle_boot.bundleModeActive()) {
        return bundle_boot.run(gpa, argv);
    }

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
        var feature_specs: std.ArrayList([]const u8) = .empty;
        defer feature_specs.deinit(gpa);
        if (std.c.getenv("KLIO_LANGUAGE")) |env_specs| applyLanguageSpecs(std.mem.span(env_specs));
        var out: ?[]const u8 = null;
        var native = false;
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
            } else if (std.mem.eql(u8, rest[i], "--feature")) {
                i += 1;
                if (i >= rest.len) {
                    printErr(gpa, "error: --feature requires a `<pack>/<feature>` value\n", .{});
                    return 2;
                }
                feature_specs.append(gpa, rest[i]) catch return 1;
            } else if (optionValue(rest[i], "--feature=")) |v| {
                feature_specs.append(gpa, v) catch return 1;
            } else if (optionValue(rest[i], "--language=")) |v| {
                applyLanguageSpecs(v);
            } else if (std.mem.eql(u8, rest[i], "--native")) {
                native = true;
            } else {
                files.append(gpa, rest[i]) catch return 1;
            }
        }
        if (bad or files.items.len == 0) {
            printErr(gpa, "usage: klio transpile <file.kt> [more.kt ...] [-o out.c] [--feature <pack>/<feat>] [--language=<spec>]\n", .{});
            return 2;
        }
        var requested = parseRequestedFeatures(gpa, feature_specs.items);
        defer deinitRequestedFeatures(&requested);
        if (native) return commands.runTranspileNative(gpa, files.items, out, &requested);
        return commands.runTranspile(gpa, files.items, out, &requested);
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
    } else if (std.mem.eql(u8, cmd, "ide")) {
        return ide.run(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bake")) {
        return runBakeCmd(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bundle")) {
        return bundle.runBundle(gpa, rest);
    } else if (std.mem.eql(u8, cmd, "bake-image")) {
        return runBakeImageCmd(gpa, rest, argv[0]);
    } else if (std.mem.eql(u8, cmd, "run-image")) {
        return runRunImageCmd(gpa, rest);
    }

    printErr(gpa, "error: unknown command `{s}`\n\n{s}", .{ cmd, USAGE });
    return 2;
}

fn usageBakeImage(gpa: std.mem.Allocator) u8 {
    printErr(gpa, "usage: klio bake-image <program.kt> -o <base.klio-image> [--feature <pack>/<feat>]\n       klio bake-image --stdlib-cache <dir>\n", .{});
    return 2;
}

fn runBakeImageCmd(gpa: std.mem.Allocator, args: []const []const u8, self_exe: []const u8) u8 {
    var out: ?[]const u8 = null;
    var program: ?[]const u8 = null;
    var stdlib_cache: ?[]const u8 = null;
    // The child half of `--stdlib-cache`: one probe's image in this process.
    var probe: ?[]const u8 = null;
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return usageBakeImage(gpa);
            out = args[i];
        } else if (std.mem.eql(u8, a, "--stdlib-cache")) {
            i += 1;
            if (i >= args.len) return usageBakeImage(gpa);
            stdlib_cache = args[i];
        } else if (std.mem.eql(u8, a, "--probe")) {
            i += 1;
            if (i >= args.len) return usageBakeImage(gpa);
            probe = args[i];
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
    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);
    if (stdlib_cache) |dir| {
        if (program != null or out != null) return usageBakeImage(gpa);
        const cache_rc = stdlib_image.bakeStdlibCache(gpa, dir, &requested, self_exe, probe);
        commands.lowerCensusDump();
        return cache_rc;
    }
    if (probe != null) return usageBakeImage(gpa);
    if (program == null or out == null) return usageBakeImage(gpa);
    const rc = bundle.bakeImage(gpa, &.{program.?}, &requested, out.?);
    // Nearly every library site is lowered here, not at `run`, so the lowering
    // census is only complete when read from a bake.
    commands.lowerCensusDump();
    return rc;
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

/// `KLIO_LAZY_BODIES`: `1`/`true` on, `0`/`false` off, null otherwise.
fn lazyBodiesFromEnv() ?bool {
    const v = runtime.envOnce("KLIO_LAZY_BODIES") orelse return null;
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) return false;
    return null;
}

fn runRunCmd(gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var virtual_time = false;
    var lazy_bodies: ?bool = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--virtual-time")) {
            virtual_time = true;
        } else if (std.mem.eql(u8, a, "--lazy-bodies")) {
            lazy_bodies = true;
        } else if (std.mem.eql(u8, a, "--no-lazy-bodies")) {
            lazy_bodies = false;
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
    // The flag, then the environment, then the working directory's klio.toml.
    runtime.lazy_bodies = lazy_bodies orelse lazyBodiesFromEnv() orelse project.lazyBodiesFromToml(gpa, ".") orelse false;

    if (files.items.len == 0) {
        printErr(gpa, "usage: klio run <file.kt> [<file2.kt> ...]\n", .{});
        return 2;
    }

    // A manifest that names a dependency's feature is asking for it on every
    // run of that project, not only when the command line repeats it.
    for (project.declaredFeatureSpecs(gpa, files.items)) |spec| {
        feature_specs.append(gpa, spec) catch return 2;
    }
    var requested = parseRequestedFeatures(gpa, feature_specs.items);
    defer deinitRequestedFeatures(&requested);
    if (files.items.len == 1) {
        return commands.runFileIrVm(gpa, files.items[0], &requested);
    }
    return commands.runModuleFiles(gpa, files.items, &requested);
}

fn runTestCmd(gpa: std.mem.Allocator, args: []const []const u8, self_exe: []const u8) u8 {
    project.implicit_dependencies = &.{"kotlin.test"};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var feature_specs: std.ArrayList([]const u8) = .empty;
    defer feature_specs.deinit(gpa);
    var only_files: std.ArrayList([]const u8) = .empty;
    defer only_files.deinit(gpa);
    var project_features: std.ArrayList([]const u8) = .empty;
    defer project_features.deinit(gpa);
    var all_features = false;
    var test_group: ?[]const u8 = null;
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
                    printErr(gpa, "error: --format requires a value (plain|json|ij)\n", .{});
                    return 2;
                }
                break :blk args[i];
            };
            if (std.mem.eql(u8, v, "json")) {
                test_format = .json;
            } else if (std.mem.eql(u8, v, "plain")) {
                test_format = .plain;
            } else if (std.mem.eql(u8, v, "ij") or std.mem.eql(u8, v, "teamcity")) {
                test_format = .ij;
            } else {
                printErr(gpa, "error: unknown --format `{s}` (use plain|json|ij)\n", .{v});
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
        } else if (std.mem.startsWith(u8, a, "--test-group")) {
            // Set by the parent when it runs one group per process.
            test_group = if (optionValue(a, "--test-group=")) |vv| vv else blk: {
                i += 1;
                if (i >= args.len) {
                    printErr(gpa, "error: --test-group requires a value\n", .{});
                    return 2;
                }
                break :blk args[i];
            };
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

    if (paths.items.len == 0) paths.append(gpa, ".") catch return 2;

    // `--isolate` re-invokes `klio test` once per discovered test in its own sub-process
    // under a per-test timeout; the child re-parses these base args plus `--filter`.
    if (isolate) {
        var base: std.ArrayList([]const u8) = .empty;
        defer base.deinit(gpa);
        for (paths.items) |p| base.append(gpa, p) catch return 2;
        if (all_features) base.append(gpa, "--all") catch return 2;
        for (project_features.items) |fs| {
            base.append(gpa, "--feature") catch return 2;
            base.append(gpa, fs) catch return 2;
        }
        // Pack features (`<pack>/<feature>`) reach the children too; a test
        // suite written against an opt-in module resolves nothing without them.
        for (feature_specs.items) |fs| {
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

    // Project mode: a directory carrying `klio.toml` with `[[test]]` sets runs that
    // project's composed sources against its built and installed pack. `planTest`
    // returns null for a plain file or dir, so the normal path handles those.
    if (paths.items.len == 1) {
        const sel: project.FeatureSel = if (!all_features and project_features.items.len != 0)
            .{ .selected = project_features.items }
        else
            .all;
        if (project.planTest(gpa, paths.items[0], sel)) |plan| {
            if (buildAndInstallProjectPack(gpa, plan.project_dir, plan.pack_id)) |code| {
                if (code != 0) return code;
            }
            // One group runs here; several run a process each, because a
            // program leaves state behind that the next one in the same
            // process trips over.
            const only = test_group orelse if (plan.groups.len == 1) plan.groups[0].name else {
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(gpa);
                for (plan.groups) |g| names.append(gpa, g.name) catch return 2;

                var base: std.ArrayList([]const u8) = .empty;
                defer base.deinit(gpa);
                for (paths.items) |p| base.append(gpa, p) catch return 2;
                if (all_features) base.append(gpa, "--all") catch return 2;
                for (project_features.items) |fs| {
                    base.append(gpa, "--feature") catch return 2;
                    base.append(gpa, fs) catch return 2;
                }
                for (feature_specs.items) |fs| {
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
                if (list_only) base.append(gpa, "--list") catch return 2;
                base.append(gpa, "--format") catch return 2;
                base.append(gpa, @tagName(test_format)) catch return 2;
                return commands.runTestGroups(gpa, self_exe, names.items, base.items);
            };

            for (plan.groups) |group| {
                if (!std.mem.eql(u8, group.name, only)) continue;
                activateFeatures(gpa, &requested, plan.pack_id, group.active_features);
                return commands.runTestFiles(
                    gpa,
                    group.roots,
                    &requested,
                    only_files.items,
                    filter,
                    test_format,
                    list_only,
                );
            }
            printErr(gpa, "error: no test group named `{s}`\n", .{only});
            return 2;
        }
    }
    return commands.runTestFiles(gpa, paths.items, &requested, only_files.items, filter, test_format, list_only);
}

/// `<pack>/<feat>` keeps its cross-pack meaning; a bare `<feat>` selects the project's own.
fn addFeatureSpec(
    gpa: std.mem.Allocator,
    v: []const u8,
    feature_specs: *std.ArrayList([]const u8),
    project_features: *std.ArrayList([]const u8),
) void {
    if (std.mem.findScalar(u8, v, '/') != null) {
        feature_specs.append(gpa, v) catch {};
    } else {
        project_features.append(gpa, v) catch {};
    }
}

/// Files the pack loader with these under `pack_id`, so its feature sources load.
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

/// Installs the built pack so its API resolves in the tests. Failing exit code, else 0 or null.
fn buildAndInstallProjectPack(gpa: std.mem.Allocator, dir: []const u8, id: []const u8) ?u8 {
    if (id.len == 0) return null; // not a library project, nothing to install
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
    const code = stdlib_image.runBake(gpa, files.items, &requested);
    stdlib_image.finishBackgroundBake();
    return code;
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

/// The value of `--flag <value>` or `--flag=value`, null when absent.
fn packFlag(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) {
            return if (i + 1 < args.len) args[i + 1] else null;
        }
        if (std.mem.startsWith(u8, args[i], name) and
            args[i].len > name.len and args[i][name.len] == '=')
        {
            return args[i][name.len + 1 ..];
        }
    }
    return null;
}

/// The positional arguments, with flags and their values removed.
fn packPositionals(buf: [][]const u8, args: []const []const u8) [][]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--")) {
            // `--flag value` consumes the value too; `--flag=value` stands alone.
            if (std.mem.findScalar(u8, args[i], '=') == null) i += 1;
            continue;
        }
        if (n >= buf.len) break;
        buf[n] = args[i];
        n += 1;
    }
    return buf[0..n];
}

/// Only the minimal positional form; flag-heavy variants take their defaults.
fn parsePackCmd(args: []const []const u8) ?PackCmd {
    const sub = args[0];
    var pos_buf: [8][]const u8 = undefined;
    const pos = packPositionals(&pos_buf, args[1..]);
    if (std.mem.eql(u8, sub, "build")) {
        if (pos.len < 1) return null;
        var build_cmd: PackCmd = .{ .Build = .{ .dir = pos[0] } };
        if (packFlag(args, "--out")) |o| build_cmd.Build.out = o;
        return build_cmd;
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
        var new_cmd: PackCmd = .{ .New = .{ .dir = pos[0] } };
        if (packFlag(args, "--id")) |id| new_cmd.New.id = id;
        return new_cmd;
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

fn applyLanguageSpecs(specs: []const u8) void {
    var it = std.mem.tokenizeAny(u8, specs, ", ");
    while (it.next()) |spec| _ = parser.setLanguageFeature(spec);
}

fn optionValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// The profile flag (`--opt <p>`, `--opt=<p>`, `-O<p>`, `-O <p>`) is applied at process
/// start, before the allocator is chosen, so parsers call this only to consume it. Null
/// when `a` is not the flag, else its value, empty when missing, advancing `i` past it.
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

/// A spec with no `/` names no pack, so it is reported and skipped.
fn parseRequestedFeatures(gpa: std.mem.Allocator, specs: []const []const u8) RequestedFeatures {
    var out = RequestedFeatures.init(gpa);
    for (specs) |spec| {
        if (std.mem.findScalar(u8, spec, '/')) |slash| {
            const pack = std.mem.trim(u8, spec[0..slash], " \t");
            const feat = std.mem.trim(u8, spec[slash + 1 ..], " \t");
            const gop = out.getOrPut(pack) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.StringHashMap(void).init(gpa);
            }
            // `<pack>/<a>,<b>` names several features of one pack at once,
            // the spelling a manifest's `deps` entry uses.
            var feats = std.mem.splitScalar(u8, feat, ',');
            while (feats.next()) |one_raw| {
                const one = std.mem.trim(u8, one_raw, " \t");
                if (one.len != 0) gop.value_ptr.put(one, {}) catch {};
            }
        } else {
            printErr(
                gpa,
                "warning: --feature `{s}` ignored; use `<pack>/<feature>` (e.g. io.ktor/server-core)\n",
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
    var rf = parseRequestedFeatures(gpa, &.{"io.ktor/server-core"});
    defer deinitRequestedFeatures(&rf);
    const feats = rf.get("io.ktor").?;
    try std.testing.expect(feats.contains("server-core"));
}

test "parseRequestedFeatures takes a comma list of one pack's features" {
    const gpa = std.testing.allocator;
    var rf = parseRequestedFeatures(gpa, &.{ "io.ktor/server-content-negotiation, serialization-kotlinx-json", "kotlinx.coroutines/test" });
    defer deinitRequestedFeatures(&rf);
    const ktor = rf.get("io.ktor").?;
    try std.testing.expect(ktor.contains("server-content-negotiation"));
    try std.testing.expect(ktor.contains("serialization-kotlinx-json"));
    try std.testing.expectEqual(@as(u32, 2), ktor.count());
    try std.testing.expect(rf.get("kotlinx.coroutines").?.contains("test"));
}

test "parsePackCmd list and build" {
    const list = parsePackCmd(&.{"list"}).?;
    try std.testing.expectEqualStrings("List", @tagName(list));
    const build = parsePackCmd(&.{ "build", "libdir" }).?;
    try std.testing.expectEqualStrings("Build", @tagName(build));
    try std.testing.expect(parsePackCmd(&.{"build"}) == null);
}
