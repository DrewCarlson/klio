//! Reference runners: `kotlinc-native` and JVM `kotlinc`. Both are downloaded
//! on demand via `parity`'s install machinery and are never assumed on PATH.
//!
//! Compiled artifacts are cached under `target/bench-cache/` keyed by
//! source-content hash so repeated bench passes don't recompile.

const std = @import("std");
const parity = @import("parity");

pub const KOTLIN_JVM_VERSION: []const u8 = "2.4.0";

/// Error outcomes for a reference-runner invocation. Carried as data so the
/// caller decides how to surface it. Variants owning heap text document the
/// owner; `deinit` frees them.
pub const RefError = union(enum) {
    Io: []const u8,
    Install: []const u8,
    Compile: []const u8,
    NoJava,
    Disabled: []const u8,

    pub fn deinit(self: RefError, allocator: std.mem.Allocator) void {
        switch (self) {
            .Io => |s| allocator.free(s),
            .Install => |s| allocator.free(s),
            .Compile => |s| allocator.free(s),
            .Disabled => |s| allocator.free(s),
            .NoJava => {},
        }
    }

    /// Render the error message. Caller owns the returned bytes.
    pub fn message(self: RefError, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .Io => |s| std.fmt.allocPrint(allocator, "io: {s}", .{s}),
            .Install => |s| std.fmt.allocPrint(allocator, "install: {s}", .{s}),
            .Compile => |s| std.fmt.allocPrint(allocator, "compile: {s}", .{s}),
            .NoJava => allocator.dupe(
                u8,
                "java not found on PATH (required to run JVM kotlinc); set JAVA_HOME or install a JDK",
            ),
            .Disabled => |s| std.fmt.allocPrint(allocator, "ref runner disabled: {s}", .{s}),
        };
    }
};

/// `Result<Duration, RefError>` carried as data. `median_ns` is the median
/// per-run wall time in nanoseconds.
pub const RefResult = union(enum) {
    ok: u64,
    err: RefError,
};

fn workspaceRoot(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return allocator.dupe(u8, ".");
}

fn benchCacheDir(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error![]u8 {
    if (try getEnvVar(allocator, io, "CARGO_TARGET_DIR")) |target| {
        defer allocator.free(target);
        return std.fs.path.join(allocator, &.{ target, "bench-cache" });
    }
    const root = try workspaceRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "target", "bench-cache" });
}

fn hashFile(allocator: std.mem.Allocator, io: std.Io, p: []const u8) std.mem.Allocator.Error![]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, allocator, .unlimited) catch
        try allocator.dupe(u8, "");
    defer allocator.free(bytes);
    const h = std.hash.Wyhash.hash(0, bytes);
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{h});
}

fn isFile(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Look up one environment variable from the parent process. Reads
/// `/proc/self/environ`; returns an owned copy of the value or `null`.
fn getEnvVar(allocator: std.mem.Allocator, io: std.Io, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/environ", allocator, .unlimited) catch
        return null;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return try allocator.dupe(u8, entry[eq + 1 ..]);
        }
    }
    return null;
}

/// Build an `Environ.Map` from the parent process environment so spawned
/// children inherit PATH/JAVA_HOME/etc. Caller deinits the map.
fn procEnvMap(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    const data = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/environ", allocator, .unlimited) catch
        return map;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
    }
    return map;
}

/// Locate the requested `kotlinc` via the `parity` install machinery. The
/// returned path is owned by the caller. The label prefixes any install
/// error.
fn findKotlinc(allocator: std.mem.Allocator, kind: parity.KotlincKind, label: []const u8) std.mem.Allocator.Error!RefResultPath {
    const r = try parity.findKotlincKind(allocator, kind);
    switch (r) {
        .ok => |path| return .{ .ok = path },
        .err => |e| {
            const detail = try e.message(allocator);
            defer allocator.free(detail);
            e.deinit(allocator);
            const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ label, detail });
            return .{ .err = .{ .Install = msg } };
        },
    }
}

const RefResultPath = union(enum) {
    ok: []u8,
    err: RefError,
};

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ---------------------- kotlinc-native ----------------------

/// Time a single end-to-end run of `kotlinc-native` (compile + execute).
/// Compilation is cached; only the execution time is measured.
pub fn timeKotlincNative(allocator: std.mem.Allocator, io: std.Io, file: []const u8, iters: u32) std.mem.Allocator.Error!RefResult {
    const kpath = try findKotlinc(allocator, .Native, "kotlinc-native");
    switch (kpath) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const kotlinc = kpath.ok;
    defer allocator.free(kotlinc);

    var env = try procEnvMap(allocator, io);
    defer env.deinit();

    const cache_base = try benchCacheDir(allocator, io);
    defer allocator.free(cache_base);
    const cache = try std.fs.path.join(allocator, &.{ cache_base, "native" });
    defer allocator.free(cache);
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};

    const key = try hashFile(allocator, io, file);
    defer allocator.free(key);
    const exe_name = try std.fmt.allocPrint(allocator, "{s}.kexe", .{key});
    defer allocator.free(exe_name);
    const exe = try std.fs.path.join(allocator, &.{ cache, exe_name });
    defer allocator.free(exe);

    if (!isFile(io, exe)) {
        const r = std.process.run(allocator, io, .{
            .argv = &.{ kotlinc, file, "-o", exe },
            .environ_map = &env,
        }) catch return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn kotlinc-native") } };
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (!termOk(r.term)) {
            const msg = try std.fmt.allocPrint(allocator, "kotlinc-native:\n{s}\n{s}", .{ r.stdout, r.stderr });
            return .{ .err = .{ .Compile = msg } };
        }
    }

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        var t = std.time.Timer.start() catch unreachable;
        const out = std.process.run(allocator, io, .{
            .argv = &.{exe},
            .environ_map = &env,
        }) catch return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn kotlinc-native binary") } };
        defer allocator.free(out.stdout);
        defer allocator.free(out.stderr);
        if (!termOk(out.term)) {
            const msg = try std.fmt.allocPrint(allocator, "kotlinc-native binary exit {any}", .{out.term});
            return .{ .err = .{ .Compile = msg } };
        }
        try samples.append(allocator, t.read());
    }
    std.mem.sort(u64, samples.items, {}, std.sort.asc(u64));
    return .{ .ok = samples.items[samples.items.len / 2] };
}

// ---------------------- kotlinc JVM ----------------------

fn kotlincJvmFilename() []const u8 {
    return "kotlinc";
}

fn kotlincJvmRoot(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!RefResultPath {
    if (try getEnvVar(allocator, io, "KLIO_KOTLINC_JVM_HOME")) |v| {
        defer allocator.free(v);
        const probe = try std.fs.path.join(allocator, &.{ v, "bin", kotlincJvmFilename() });
        defer allocator.free(probe);
        if (isFile(io, probe)) return .{ .ok = try allocator.dupe(u8, v) };
    }
    const cache = try benchCacheDir(allocator, io);
    defer allocator.free(cache);
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};
    const dest_name = try std.fmt.allocPrint(allocator, "kotlinc-{s}", .{KOTLIN_JVM_VERSION});
    defer allocator.free(dest_name);
    const dest = try std.fs.path.join(allocator, &.{ cache, dest_name });
    {
        const probe = try std.fs.path.join(allocator, &.{ dest, "bin", kotlincJvmFilename() });
        defer allocator.free(probe);
        if (isFile(io, probe)) return .{ .ok = dest };
    }
    const r = try installKotlincJvm(allocator, io, KOTLIN_JVM_VERSION, cache, dest);
    if (r) |e| {
        allocator.free(dest);
        return .{ .err = e };
    }
    return .{ .ok = dest };
}

fn installKotlincJvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    version: []const u8,
    cache: []const u8,
    dest: []const u8,
) std.mem.Allocator.Error!?RefError {
    var env = try procEnvMap(allocator, io);
    defer env.deinit();

    const archive_name = try std.fmt.allocPrint(allocator, "kotlin-compiler-{s}.zip", .{version});
    defer allocator.free(archive_name);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/JetBrains/kotlin/releases/download/v{s}/{s}",
        .{ version, archive_name },
    );
    defer allocator.free(url);
    const archive_path = try std.fs.path.join(allocator, &.{ cache, archive_name });
    defer allocator.free(archive_path);
    printErr("[bench] downloading {s}\n", .{url});
    const tmp = try std.fmt.allocPrint(allocator, "{s}.part", .{archive_path});
    defer allocator.free(tmp);
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const curl = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fL", "--retry", "3", "--retry-delay", "2", "-o", tmp, url },
        .environ_map = &env,
    }) catch null;
    var ok = false;
    if (curl) |c| {
        defer allocator.free(c.stdout);
        defer allocator.free(c.stderr);
        ok = termOk(c.term);
    }
    if (!ok) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return RefError{ .Install = try std.fmt.allocPrint(allocator, "download failed: {s}", .{url}) };
    }
    std.Io.Dir.cwd().rename(tmp, archive_path, io) catch {};

    const staging = try std.fmt.allocPrint(allocator, "{s}/.kotlinc-{s}.partial", .{ cache, version });
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().createDirPath(io, staging) catch {};

    const unzip = std.process.run(allocator, io, .{
        .argv = &.{ "unzip", "-q", archive_path, "-d", staging },
        .environ_map = &env,
    }) catch return RefError{ .Install = try allocator.dupe(u8, "unzip spawn") };
    defer allocator.free(unzip.stdout);
    defer allocator.free(unzip.stderr);
    if (!termOk(unzip.term)) {
        return RefError{ .Install = try allocator.dupe(u8, "unzip failed") };
    }

    const inner = try std.fs.path.join(allocator, &.{ staging, "kotlinc" });
    defer allocator.free(inner);
    {
        const st = std.Io.Dir.cwd().statFile(io, inner, .{}) catch null;
        if (st == null or st.?.kind != .directory) {
            return RefError{ .Install = try allocator.dupe(u8, "kotlinc/ missing in archive") };
        }
    }
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    std.Io.Dir.cwd().rename(inner, dest, io) catch {};
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().deleteFile(io, archive_path) catch {};

    // Make scripts executable.
    for ([_][]const u8{ "kotlinc", "kotlin", "kotlinc-jvm" }) |name| {
        const p = std.fs.path.join(allocator, &.{ dest, "bin", name }) catch continue;
        defer allocator.free(p);
        if (isFile(io, p)) {
            const chmod = std.process.run(allocator, io, .{
                .argv = &.{ "chmod", "+x", p },
                .environ_map = &env,
            }) catch continue;
            allocator.free(chmod.stdout);
            allocator.free(chmod.stderr);
        }
    }
    return null;
}

fn locateJava(allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!RefResultPath {
    if (try getEnvVar(allocator, io, "JAVA_HOME")) |home| {
        defer allocator.free(home);
        const p = try std.fs.path.join(allocator, &.{ home, "bin", "java" });
        if (isFile(io, p)) return .{ .ok = p };
        allocator.free(p);
    }
    if (try getEnvVar(allocator, io, "PATH")) |path| {
        defer allocator.free(path);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const p = std.fs.path.join(allocator, &.{ dir, "java" }) catch continue;
            if (isFile(io, p)) return .{ .ok = p };
            allocator.free(p);
        }
    }
    return .{ .err = .NoJava };
}

/// Compile to JVM bytecode (cached) and time `java -jar ...` runs.
pub fn timeKotlincJvm(allocator: std.mem.Allocator, io: std.Io, file: []const u8, iters: u32) std.mem.Allocator.Error!RefResult {
    {
        const j = try locateJava(allocator, io);
        switch (j) {
            .err => |e| return .{ .err = e },
            .ok => |p| allocator.free(p),
        }
    }
    const root = try kotlincJvmRoot(allocator, io);
    switch (root) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const kotlinc_home = root.ok;
    defer allocator.free(kotlinc_home);

    var env = try procEnvMap(allocator, io);
    defer env.deinit();

    const kotlinc = try std.fs.path.join(allocator, &.{ kotlinc_home, "bin", kotlincJvmFilename() });
    defer allocator.free(kotlinc);
    const cache_base = try benchCacheDir(allocator, io);
    defer allocator.free(cache_base);
    const cache = try std.fs.path.join(allocator, &.{ cache_base, "jvm" });
    defer allocator.free(cache);
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};

    const key = try hashFile(allocator, io, file);
    defer allocator.free(key);
    const jar_name = try std.fmt.allocPrint(allocator, "{s}.jar", .{key});
    defer allocator.free(jar_name);
    const jar = try std.fs.path.join(allocator, &.{ cache, jar_name });
    defer allocator.free(jar);

    if (!isFile(io, jar)) {
        const r = std.process.run(allocator, io, .{
            .argv = &.{ kotlinc, file, "-include-runtime", "-d", jar },
            .environ_map = &env,
        }) catch return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn kotlinc") } };
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (!termOk(r.term)) {
            const msg = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ r.stdout, r.stderr });
            return .{ .err = .{ .Compile = msg } };
        }
    }

    const java = try locateJava(allocator, io);
    switch (java) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }
    const java_path = java.ok;
    defer allocator.free(java_path);

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(allocator);
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        var t = std.time.Timer.start() catch unreachable;
        const out = std.process.run(allocator, io, .{
            .argv = &.{ java_path, "-jar", jar },
            .environ_map = &env,
        }) catch return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn java") } };
        defer allocator.free(out.stdout);
        defer allocator.free(out.stderr);
        if (!termOk(out.term)) {
            const msg = try std.fmt.allocPrint(allocator, "java exit {any}: {s}", .{ out.term, out.stderr });
            return .{ .err = .{ .Compile = msg } };
        }
        try samples.append(allocator, t.read());
    }
    std.mem.sort(u64, samples.items, {}, std.sort.asc(u64));
    return .{ .ok = samples.items[samples.items.len / 2] };
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print(fmt, args) catch {};
}
