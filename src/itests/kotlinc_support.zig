//! Locates or installs the reference Kotlin compilers (`kotlinc` on the JVM
//! by default, Kotlin/Native also supported), compiles and runs a `.kt` file
//! with them, and compares that output with the program's run through the
//! harness binary (`klio_child`). JVM `kotlinc` compiles a file in about a
//! second, where per-file native codegen and linking take hours over a corpus.

const std = @import("std");
const runtime = @import("runtime");
const klio_child = @import("klio_child");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TARGET_VERSION: []const u8 = "2.4.20";

/// Diagnostic outcomes for a locate/install/compile attempt, carried as data;
/// `deinit` frees the variants owning heap text.
pub const KotlincError = union(enum) {
    NoKotlinc,
    NoJava,
    Compile: []const u8,
    Install: []const u8,
    UnsupportedPlatform: []const u8,
    Io: []const u8,

    pub fn deinit(self: KotlincError, allocator: Allocator) void {
        switch (self) {
            .Compile => |s| allocator.free(s),
            .Install => |s| allocator.free(s),
            .UnsupportedPlatform => |s| allocator.free(s),
            .Io => |s| allocator.free(s),
            .NoKotlinc, .NoJava => {},
        }
    }

    /// Render the error message. Caller owns the returned bytes.
    pub fn message(self: KotlincError, allocator: Allocator) Allocator.Error![]u8 {
        return switch (self) {
            .NoKotlinc => allocator.dupe(
                u8,
                "kotlinc not found. Set KLIO_KOTLINC_JVM_HOME to a kotlinc dist, or let the harness auto-install.",
            ),
            .NoJava => allocator.dupe(
                u8,
                "java not found on PATH (required to run JVM kotlinc output); set JAVA_HOME or install a JDK.",
            ),
            .Compile => |s| std.fmt.allocPrint(allocator, "kotlinc compile failed:\n{s}", .{s}),
            .Install => |s| std.fmt.allocPrint(allocator, "kotlinc install failed: {s}", .{s}),
            .UnsupportedPlatform => |s| std.fmt.allocPrint(allocator, "no kotlinc prebuilt for platform: {s}", .{s}),
            .Io => |s| std.fmt.allocPrint(allocator, "io error: {s}", .{s}),
        };
    }
};

/// `Result<PathBuf, KotlincError>` carried as data; `ok` is a caller-owned path.
pub const PathResult = union(enum) {
    ok: []u8,
    err: KotlincError,
};

pub const KotlincKind = enum {
    /// JVM `kotlinc` (`kotlin-compiler-<v>.zip` from JetBrains GitHub).
    Jvm,
    /// `kotlinc-native` (`kotlin-native-prebuilt-<slug>-<v>.tar.gz`, under `~/.konan/`).
    Native,

    fn binaryName(self: KotlincKind) []const u8 {
        return switch (self) {
            .Jvm => "kotlinc",
            .Native => "kotlinc-native",
        };
    }

    fn envOverride(self: KotlincKind) []const u8 {
        return switch (self) {
            .Jvm => "KLIO_KOTLINC_JVM_HOME",
            .Native => "KLIO_KOTLINC_NATIVE",
        };
    }
};

fn javaFilename() []const u8 {
    return "java";
}

fn threadedIo(allocator: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}


/// One environment variable of the parent; owned.
fn getEnvVar(allocator: Allocator, io: Io, name: []const u8) Allocator.Error!?[]u8 {
    _ = io;
    return runtime.procEnvGetVar(allocator, name);
}

/// An `Environ.Map` of the parent environment, so children inherit PATH and JAVA_HOME.
fn procEnvMap(allocator: Allocator, io: Io) Allocator.Error!std.process.Environ.Map {
    _ = io;
    var map = std.process.Environ.Map.init(allocator);
    runtime.procEnvPutAllInto(allocator, &map);
    return map;
}


fn isFile(io: Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn workspaceRoot(allocator: Allocator) Allocator.Error![]u8 {
    return allocator.dupe(u8, ".");
}

/// `target/parity-cache` (under `CARGO_TARGET_DIR` when set): the kotlinc
/// installs, the jars and their outputs. `scripts/sema-oracle.sh` finds the
/// JVM install there too.
fn cacheDir(allocator: Allocator, io: Io) Allocator.Error![]u8 {
    if (try getEnvVar(allocator, io, "CARGO_TARGET_DIR")) |target| {
        defer allocator.free(target);
        return std.fs.path.join(allocator, &.{ target, "parity-cache" });
    }
    const root = try workspaceRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "target", "parity-cache" });
}

/// `~/.konan` (or `KONAN_DATA_DIR`), where Kotlin/Native distributions live.
fn konanRoot(allocator: Allocator, io: Io) Allocator.Error!PathResult {
    if (try getEnvVar(allocator, io, "KONAN_DATA_DIR")) |v| {
        return .{ .ok = v };
    }
    if (try getEnvVar(allocator, io, "HOME")) |home| {
        defer allocator.free(home);
        return .{ .ok = try std.fs.path.join(allocator, &.{ home, ".konan" }) };
    }
    return .{ .err = .{ .Install = try allocator.dupe(u8, "HOME not set; cannot resolve ~/.konan") } };
}

const NativeSlug = struct {
    slug: []const u8,
    subdir: []const u8,
    ext: []const u8,
};

/// Kotlin/Native distribution descriptor: os-arch slug, CDN subdir, extension.
fn nativePlatformSlug(allocator: Allocator) Allocator.Error!union(enum) { ok: NativeSlug, err: []u8 } {
    const builtin = @import("builtin");
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    if (os == .macos and arch == .aarch64) {
        return .{ .ok = .{ .slug = "macos-aarch64", .subdir = "macos", .ext = "tar.gz" } };
    } else if (os == .macos and arch == .x86_64) {
        return .{ .ok = .{ .slug = "macos-x86_64", .subdir = "macos", .ext = "tar.gz" } };
    } else if (os == .linux and arch == .x86_64) {
        return .{ .ok = .{ .slug = "linux-x86_64", .subdir = "linux", .ext = "tar.gz" } };
    } else if (os == .windows and arch == .x86_64) {
        return .{ .ok = .{ .slug = "windows-x86_64", .subdir = "windows", .ext = "zip" } };
    }
    return .{ .err = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ @tagName(os), @tagName(arch) }) };
}

/// JVM install directory for `version` (default-cached layout). Caller owns.
fn jvmInstallDir(allocator: Allocator, io: Io, version: []const u8) Allocator.Error![]u8 {
    const cache = try cacheDir(allocator, io);
    defer allocator.free(cache);
    const name = try std.fmt.allocPrint(allocator, "kotlinc-{s}", .{version});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache, name });
}

pub fn findKotlinc(allocator: Allocator, io: Io) Allocator.Error!PathResult {
    _ = io;
    return findKotlincKind(allocator, .Jvm);
}

/// Locate the requested `kotlinc`: the kind-specific env var, the default cached
/// install location, then `PATH`. `KLIO_NO_AUTO_INSTALL_KOTLINC=1` bars install.
pub fn findKotlincKind(allocator: Allocator, kind: KotlincKind) Allocator.Error!PathResult {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    if (try locateKotlinc(allocator, io, kind)) |p| {
        return .{ .ok = p };
    }
    if (try getEnvVar(allocator, io, "KLIO_NO_AUTO_INSTALL_KOTLINC")) |v| {
        defer allocator.free(v);
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            return .{ .err = .NoKotlinc };
        }
    }
    switch (try installKotlincKind(allocator, io, kind, TARGET_VERSION)) {
        .ok => |p| allocator.free(p),
        .err => |e| return .{ .err = e },
    }
    if (try locateKotlinc(allocator, io, kind)) |p| {
        return .{ .ok = p };
    }
    return .{ .err = .NoKotlinc };
}

fn locateKotlinc(allocator: Allocator, io: Io, kind: KotlincKind) Allocator.Error!?[]u8 {
    const binary = kind.binaryName();
    if (try getEnvVar(allocator, io, kind.envOverride())) |v| {
        defer allocator.free(v);
        // Accept either override form: a dist root holding `bin/kotlinc`, or the binary.
        if (isFile(io, v)) {
            return try allocator.dupe(u8, v);
        }
        const inside = try std.fs.path.join(allocator, &.{ v, "bin", binary });
        if (isFile(io, inside)) {
            return inside;
        }
        allocator.free(inside);
    }
    switch (kind) {
        .Jvm => {
            const dir = try jvmInstallDir(allocator, io, TARGET_VERSION);
            defer allocator.free(dir);
            const p = try std.fs.path.join(allocator, &.{ dir, "bin", binary });
            if (isFile(io, p)) {
                return p;
            }
            allocator.free(p);
        },
        .Native => {
            // Match any kotlin-native-prebuilt-*-{TARGET_VERSION} dir under ~/.konan.
            switch (try konanRoot(allocator, io)) {
                .err => |e| e.deinit(allocator),
                .ok => |root| {
                    defer allocator.free(root);
                    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch
                        return null;
                    defer dir.close(io);
                    var it = dir.iterate();
                    while (it.next(io) catch null) |entry| {
                        const s = entry.name;
                        if (std.mem.startsWith(u8, s, "kotlin-native-prebuilt-") and
                            std.mem.find(u8, s, TARGET_VERSION) != null and
                            std.mem.find(u8, s, "-RC") == null)
                        {
                            const p = try std.fs.path.join(allocator, &.{ root, s, "bin", binary });
                            if (isFile(io, p)) {
                                return p;
                            }
                            allocator.free(p);
                        }
                    }
                },
            }
        },
    }
    if (try getEnvVar(allocator, io, "PATH")) |path| {
        defer allocator.free(path);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const p = try std.fs.path.join(allocator, &.{ seg, binary });
            if (isFile(io, p)) {
                return p;
            }
            allocator.free(p);
        }
    }
    return null;
}

fn locateJava(allocator: Allocator, io: Io) Allocator.Error!PathResult {
    if (try getEnvVar(allocator, io, "JAVA_HOME")) |home| {
        defer allocator.free(home);
        const p = try std.fs.path.join(allocator, &.{ home, "bin", javaFilename() });
        if (isFile(io, p)) return .{ .ok = p };
        allocator.free(p);
    }
    if (try getEnvVar(allocator, io, "PATH")) |path| {
        defer allocator.free(path);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            const p = try std.fs.path.join(allocator, &.{ seg, javaFilename() });
            if (isFile(io, p)) return .{ .ok = p };
            allocator.free(p);
        }
    }
    return .{ .err = .NoJava };
}

pub fn installKotlinc(allocator: Allocator, io: Io, version: []const u8) Allocator.Error!PathResult {
    return installKotlincKind(allocator, io, .Jvm, version);
}

/// Download and extract the distribution, a no-op when it already works.
pub fn installKotlincKind(allocator: Allocator, io: Io, kind: KotlincKind, version: []const u8) Allocator.Error!PathResult {
    return switch (kind) {
        .Jvm => installJvm(allocator, io, version),
        .Native => installNative(allocator, io, version),
    };
}

fn installJvm(allocator: Allocator, io: Io, version: []const u8) Allocator.Error!PathResult {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .macos, .linux, .windows => {},
        else => return .{ .err = .{ .UnsupportedPlatform = try std.fmt.allocPrint(
            allocator,
            "{s}-{s}",
            .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) },
        ) } },
    }

    const cache = try cacheDir(allocator, io);
    defer allocator.free(cache);
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};

    const dest_name = try std.fmt.allocPrint(allocator, "kotlinc-{s}", .{version});
    defer allocator.free(dest_name);
    const dest = try std.fs.path.join(allocator, &.{ cache, dest_name });
    errdefer allocator.free(dest);
    const kotlinc = try std.fs.path.join(allocator, &.{ dest, "bin", KotlincKind.Jvm.binaryName() });
    defer allocator.free(kotlinc);
    if (isFile(io, kotlinc)) {
        return .{ .ok = dest };
    }

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
    printErr("[kotlinc] installing JVM kotlinc {s} into {s}\n", .{ version, cache });
    printErr("[kotlinc] downloading {s}\n", .{url});
    if (try download(allocator, io, &env, url, archive_path)) |e| {
        allocator.free(dest);
        return .{ .err = e };
    }

    const staging = try std.fmt.allocPrint(allocator, "{s}/.kotlinc-{s}.partial", .{ cache, version });
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().createDirPath(io, staging) catch {};
    if (try extractArchive(allocator, io, &env, archive_path, staging, "zip")) |e| {
        allocator.free(dest);
        return .{ .err = e };
    }

    const inner = try std.fs.path.join(allocator, &.{ staging, "kotlinc" });
    defer allocator.free(inner);
    if (!isDir(io, inner)) {
        allocator.free(dest);
        return .{ .err = .{ .Install = try allocator.dupe(u8, "kotlinc/ missing in archive") } };
    }
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    std.Io.Dir.cwd().rename(inner, std.Io.Dir.cwd(), dest, io) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "rename {s} -> {s}: {s}", .{ inner, dest, @errorName(e) });
        allocator.free(dest);
        return .{ .err = .{ .Install = msg } };
    };
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().deleteFile(io, archive_path) catch {};

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

    if (!isFile(io, kotlinc)) {
        const msg = try std.fmt.allocPrint(allocator, "{s} missing after extract", .{kotlinc});
        allocator.free(dest);
        return .{ .err = .{ .Install = msg } };
    }
    printErr("[kotlinc] kotlinc {s} ready at {s}\n", .{ version, dest });
    return .{ .ok = dest };
}

fn installNative(allocator: Allocator, io: Io, version: []const u8) Allocator.Error!PathResult {
    const slug = switch (try nativePlatformSlug(allocator)) {
        .ok => |s| s,
        .err => |s| return .{ .err = .{ .UnsupportedPlatform = s } },
    };
    const root = switch (try konanRoot(allocator, io)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(root);
    std.Io.Dir.cwd().createDirPath(io, root) catch {};

    const dir_name = try std.fmt.allocPrint(allocator, "kotlin-native-prebuilt-{s}-{s}", .{ slug.slug, version });
    defer allocator.free(dir_name);
    const dest = try std.fs.path.join(allocator, &.{ root, dir_name });
    errdefer allocator.free(dest);
    const kotlinc = try std.fs.path.join(allocator, &.{ dest, "bin", KotlincKind.Native.binaryName() });
    defer allocator.free(kotlinc);
    if (isFile(io, kotlinc)) {
        return .{ .ok = dest };
    }

    var env = try procEnvMap(allocator, io);
    defer env.deinit();

    const archive_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ dir_name, slug.ext });
    defer allocator.free(archive_name);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://download.jetbrains.com/kotlin/native/builds/releases/{s}/{s}/{s}",
        .{ version, slug.subdir, archive_name },
    );
    defer allocator.free(url);
    const archive_path = try std.fs.path.join(allocator, &.{ root, archive_name });
    defer allocator.free(archive_path);
    printErr("[kotlinc] installing kotlin-native {s} ({s}) into {s}\n", .{ version, slug.slug, root });
    printErr("[kotlinc] downloading {s}\n", .{url});
    if (try download(allocator, io, &env, url, archive_path)) |e| {
        allocator.free(dest);
        return .{ .err = e };
    }

    const staging = try std.fmt.allocPrint(allocator, "{s}/.{s}.partial", .{ root, dir_name });
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().createDirPath(io, staging) catch {};
    if (try extractArchive(allocator, io, &env, archive_path, staging, slug.ext)) |e| {
        allocator.free(dest);
        return .{ .err = e };
    }

    const extracted = blk: {
        const named = try std.fs.path.join(allocator, &.{ staging, dir_name });
        if (isDir(io, named)) break :blk named;
        allocator.free(named);
        // Fallback: pick the single top-level dir the archive produced.
        var dir = std.Io.Dir.cwd().openDir(io, staging, .{ .iterate = true }) catch {
            allocator.free(dest);
            return .{ .err = .{ .Install = try std.fmt.allocPrint(
                allocator,
                "unexpected archive layout under {s}",
                .{staging},
            ) } };
        };
        defer dir.close(io);
        var only: ?[]u8 = null;
        var count: usize = 0;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            count += 1;
            if (only) |o| allocator.free(o);
            only = try std.fs.path.join(allocator, &.{ staging, entry.name });
        }
        if (count != 1) {
            if (only) |o| allocator.free(o);
            allocator.free(dest);
            return .{ .err = .{ .Install = try std.fmt.allocPrint(
                allocator,
                "unexpected archive layout under {s}",
                .{staging},
            ) } };
        }
        break :blk only.?;
    };
    defer allocator.free(extracted);

    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    std.Io.Dir.cwd().rename(extracted, std.Io.Dir.cwd(), dest, io) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "rename {s} -> {s}: {s}", .{ extracted, dest, @errorName(e) });
        allocator.free(dest);
        return .{ .err = .{ .Install = msg } };
    };
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().deleteFile(io, archive_path) catch {};

    if (!isFile(io, kotlinc)) {
        const msg = try std.fmt.allocPrint(allocator, "{s} missing after extract", .{kotlinc});
        allocator.free(dest);
        return .{ .err = .{ .Install = msg } };
    }
    printErr("[kotlinc] kotlin-native {s} ready at {s}\n", .{ version, dest });
    return .{ .ok = dest };
}

/// Download `url` to `dest` via curl then wget; a `KotlincError` or null.
fn download(allocator: Allocator, io: Io, env: *std.process.Environ.Map, url: []const u8, dest: []const u8) Allocator.Error!?KotlincError {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.part", .{dest});
    defer allocator.free(tmp);
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var ok = false;
    if (std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fL", "--retry", "3", "--retry-delay", "2", "-o", tmp, url },
        .environ_map = env,
    })) |c| {
        defer allocator.free(c.stdout);
        defer allocator.free(c.stderr);
        ok = termOk(c.term);
    } else |_| {}

    if (!ok) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        if (std.process.run(allocator, io, .{
            .argv = &.{ "wget", "-O", tmp, url },
            .environ_map = env,
        })) |w| {
            defer allocator.free(w.stdout);
            defer allocator.free(w.stderr);
            ok = termOk(w.term);
        } else |_| {}
    }

    if (!ok) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return KotlincError{ .Install = try std.fmt.allocPrint(allocator, "download failed: {s}", .{url}) };
    }
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), dest, io) catch {};
    return null;
}

/// Extract `archive` into `into`, zip via unzip and otherwise tar.
fn extractArchive(allocator: Allocator, io: Io, env: *std.process.Environ.Map, archive: []const u8, into: []const u8, ext: []const u8) Allocator.Error!?KotlincError {
    const r = if (std.mem.eql(u8, ext, "zip"))
        std.process.run(allocator, io, .{
            .argv = &.{ "unzip", "-q", archive, "-d", into },
            .environ_map = env,
        })
    else
        std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xf", archive, "-C", into },
            .environ_map = env,
        });
    const out = r catch |e| {
        return KotlincError{ .Install = try std.fmt.allocPrint(allocator, "extract spawn: {s}", .{@errorName(e)}) };
    };
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);
    if (!termOk(out.term)) {
        return KotlincError{ .Install = try std.fmt.allocPrint(
            allocator,
            "extract {s} failed (exit {any})",
            .{ archive, out.term },
        ) };
    }
    return null;
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub const ExpectedHit = struct { stdout: []u8, exit: ?i32 };

pub fn PResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: KotlincError,
    };
}


pub const ParityReport = struct {
    matched: bool,
    kotlinc_stdout: []const u8,
    klio_stdout: []const u8,
    kotlinc_exit: ?i32,
    klio_error: ?[]const u8,
};

fn termExit(term: std.process.Child.Term) ?i32 {
    return switch (term) {
        .exited => |c| @intCast(c),
        else => null,
    };
}

fn readFileOrEmpty(allocator: Allocator, io: Io, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch
        (allocator.alloc(u8, 0) catch unreachable);
}

fn readFileOpt(allocator: Allocator, io: Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch null;
}

fn writeFile(io: Io, path: []const u8, contents: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents }) catch {};
}

/// 16-hex-digit render of the std default hasher, the corpus cache key format.
fn hashHex(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const h = std.hash.Wyhash.hash(0, bytes);
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{h});
}

fn cacheKey(allocator: Allocator, io: Io, file: []const u8) Allocator.Error![]u8 {
    const bytes = readFileOrEmpty(allocator, io, file);
    defer allocator.free(bytes);
    return hashHex(allocator, bytes);
}

fn envFlag(allocator: Allocator, io: Io, name: []const u8) bool {
    const v = (getEnvVar(allocator, io, name) catch return false) orelse return false;
    defer allocator.free(v);
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

fn javaXmxMb(allocator: Allocator, io: Io) u64 {
    if (getEnvVar(allocator, io, "KLIO_PARITY_JAVA_XMX_MB") catch null) |v| {
        defer allocator.free(v);
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch null) |n| {
            if (n > 0) return n;
        }
    }
    return 2048;
}

fn javaTimeout(allocator: Allocator, io: Io) Io.Timeout {
    var secs: u64 = 60;
    if (getEnvVar(allocator, io, "KLIO_PARITY_JAVA_TIMEOUT_SECS") catch null) |v| {
        defer allocator.free(v);
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch null) |n| {
            if (n > 0) secs = n;
        }
    }
    return .{ .duration = .{ .raw = Io.Duration.fromSeconds(@intCast(secs)), .clock = .awake } };
}

/// Compile a `.kt` file into a self-contained jar, cached by content hash.
pub fn compileWithKotlinc(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!PResult([]u8) {
    const kotlinc = switch (try findKotlinc(allocator, io)) {
        .err => |e| return .{ .err = e },
        .ok => |k| k,
    };
    defer allocator.free(kotlinc);
    var env = try procEnvMap(allocator, io);
    defer env.deinit();
    const cache = try cacheDir(allocator, io);
    defer allocator.free(cache);
    const dir = try std.fs.path.join(allocator, &.{ cache, "jars" });
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const key = try cacheKey(allocator, io, file);
    defer allocator.free(key);
    const out = try std.fmt.allocPrint(allocator, "{s}/{s}.jar", .{ dir, key });
    errdefer allocator.free(out);
    if (isFile(io, out)) return .{ .ok = out };
    const err_path = try std.fmt.allocPrint(allocator, "{s}/{s}.err", .{ dir, key });
    defer allocator.free(err_path);
    if (readFileOpt(allocator, io, err_path)) |prior| {
        allocator.free(out);
        return .{ .err = .{ .Compile = prior } };
    }
    const r = std.process.run(allocator, io, .{
        .argv = &.{ kotlinc, file, "-include-runtime", "-d", out },
        .environ_map = &env,
    }) catch {
        allocator.free(out);
        return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn kotlinc") } };
    };
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!termOk(r.term)) {
        const msg = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ r.stdout, r.stderr });
        writeFile(io, err_path, msg);
        allocator.free(out);
        return .{ .err = .{ .Compile = msg } };
    }
    return .{ .ok = out };
}

/// Run a compiled jar under `java -jar`, returning owned stdout and exit code.
pub fn runKotlincJar(allocator: Allocator, io: Io, jar: []const u8) Allocator.Error!PResult(ExpectedHit) {
    const java = switch (try locateJava(allocator, io)) {
        .err => |e| return .{ .err = e },
        .ok => |j| j,
    };
    defer allocator.free(java);
    var env = try procEnvMap(allocator, io);
    defer env.deinit();
    const xmx = try std.fmt.allocPrint(allocator, "-Xmx{d}m", .{javaXmxMb(allocator, io)});
    defer allocator.free(xmx);
    const r = std.process.run(allocator, io, .{
        .argv = &.{ java, xmx, "-jar", jar },
        .environ_map = &env,
        .timeout = javaTimeout(allocator, io),
    }) catch {
        return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn java") } };
    };
    allocator.free(r.stderr);
    return .{ .ok = .{ .stdout = r.stdout, .exit = termExit(r.term) } };
}

fn expectedCacheDir(allocator: Allocator, io: Io) Allocator.Error![]u8 {
    const cache = try cacheDir(allocator, io);
    defer allocator.free(cache);
    const name = try std.fmt.allocPrint(allocator, "expected-{s}", .{TARGET_VERSION});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache, name });
}

fn readExpected(allocator: Allocator, io: Io, key: []const u8) Allocator.Error!?ExpectedHit {
    const dir = try expectedCacheDir(allocator, io);
    defer allocator.free(dir);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out", .{ dir, key });
    defer allocator.free(out_path);
    const out = readFileOpt(allocator, io, out_path) orelse return null;
    const exit_path = try std.fmt.allocPrint(allocator, "{s}/{s}.exit", .{ dir, key });
    defer allocator.free(exit_path);
    var exit: ?i32 = null;
    if (readFileOpt(allocator, io, exit_path)) |raw| {
        defer allocator.free(raw);
        exit = std.fmt.parseInt(i32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
    }
    return .{ .stdout = out, .exit = exit };
}

fn writeExpected(allocator: Allocator, io: Io, key: []const u8, stdout: []const u8, exit: ?i32) Allocator.Error!void {
    const dir = try expectedCacheDir(allocator, io);
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out", .{ dir, key });
    defer allocator.free(out_path);
    writeFile(io, out_path, stdout);
    if (exit) |code| {
        const exit_path = try std.fmt.allocPrint(allocator, "{s}/{s}.exit", .{ dir, key });
        defer allocator.free(exit_path);
        const s = try std.fmt.allocPrint(allocator, "{d}", .{code});
        defer allocator.free(s);
        writeFile(io, exit_path, s);
    }
}

/// kotlinc output for one `.kt` file, cached by content hash; stdout is owned.
pub fn kotlincOutput(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!PResult(ExpectedHit) {
    const key = try cacheKey(allocator, io, file);
    defer allocator.free(key);
    if (try readExpected(allocator, io, key)) |hit| return .{ .ok = hit };
    const jar = switch (try compileWithKotlinc(allocator, io, file)) {
        .err => |e| return .{ .err = e },
        .ok => |j| j,
    };
    defer allocator.free(jar);
    const run = switch (try runKotlincJar(allocator, io, jar)) {
        .err => |e| return .{ .err = e },
        .ok => |r| r,
    };
    try writeExpected(allocator, io, key, run.stdout, run.exit);
    return .{ .ok = run };
}


/// Runs `file` through kotlinc and through the harness binary and compares
/// their stdout.
pub fn check(allocator: Allocator, io: Io, file: []const u8) !PResult(ParityReport) {
    if (envFlag(allocator, io, "KLIO_SKIP_KOTLINC_PARITY")) {
        return .{ .err = .NoKotlinc };
    }
    const ko = switch (try kotlincOutput(allocator, io, file)) {
        .err => |e| return .{ .err = e },
        .ok => |v| v,
    };
    var env = try klio_child.baseEnv(allocator);
    defer env.deinit();
    const r = try klio_child.runKlio(allocator, &env, &.{ klio_child.bin(), "run", file }, .{});
    if (r.exitedZero()) {
        allocator.free(r.stderr);
        return .{ .ok = .{
            .matched = std.mem.eql(u8, ko.stdout, r.stdout),
            .kotlinc_stdout = ko.stdout,
            .klio_stdout = r.stdout,
            .kotlinc_exit = ko.exit,
            .klio_error = null,
        } };
    }
    return .{ .ok = .{
        .matched = false,
        .kotlinc_stdout = ko.stdout,
        .klio_stdout = r.stdout,
        .kotlinc_exit = ko.exit,
        .klio_error = r.stderr,
    } };
}

/// A unified-style diff, empty when the outputs match. Owned by `allocator`.
pub fn renderDiff(allocator: Allocator, report: *const ParityReport) Allocator.Error![]u8 {
    if (report.matched) return allocator.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "--- kotlinc\n");
    try out.appendSlice(allocator, "+++ klio\n");

    var a_list: std.ArrayList([]const u8) = .empty;
    defer a_list.deinit(allocator);
    var b_list: std.ArrayList([]const u8) = .empty;
    defer b_list.deinit(allocator);
    try collectLines(allocator, report.kotlinc_stdout, &a_list);
    try collectLines(allocator, report.klio_stdout, &b_list);
    const max = @max(a_list.items.len, b_list.items.len);
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const x: ?[]const u8 = if (i < a_list.items.len) a_list.items[i] else null;
        const y: ?[]const u8 = if (i < b_list.items.len) b_list.items[i] else null;
        if (x != null and y != null) {
            if (std.mem.eql(u8, x.?, y.?)) {
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, x.?);
                try out.append(allocator, '\n');
            } else {
                try out.append(allocator, '-');
                try out.appendSlice(allocator, x.?);
                try out.append(allocator, '\n');
                try out.append(allocator, '+');
                try out.appendSlice(allocator, y.?);
                try out.append(allocator, '\n');
            }
        } else if (x != null) {
            try out.append(allocator, '-');
            try out.appendSlice(allocator, x.?);
            try out.append(allocator, '\n');
        } else if (y != null) {
            try out.append(allocator, '+');
            try out.appendSlice(allocator, y.?);
            try out.append(allocator, '\n');
        }
    }
    if (report.klio_error) |e| {
        try out.appendSlice(allocator, "klio error: ");
        try out.appendSlice(allocator, e);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// `str.lines()` semantics: split on `\n`, drop a final trailing empty token.
fn collectLines(allocator: Allocator, s: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        try out.append(allocator, l);
    }
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) {
        _ = out.pop();
    }
}

test "cache_key_is_stable_for_same_contents" {
    const a = std.testing.allocator;
    var threaded = threadedIo(a);
    defer threaded.deinit();
    const io = threaded.io();
    const path = "klio-kotlinc-cache-key.kt";
    writeFile(io, path, "fun main() { println(1) }");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const k1 = try cacheKey(a, io, path);
    defer a.free(k1);
    const k2 = try cacheKey(a, io, path);
    defer a.free(k2);
    try std.testing.expectEqualStrings(k1, k2);
}

test "renderDiff marks the differing lines and the klio error" {
    const a = std.testing.allocator;
    const report: ParityReport = .{
        .matched = false,
        .kotlinc_stdout = "a\nb\n",
        .klio_stdout = "a\nc\nd\n",
        .kotlinc_exit = 0,
        .klio_error = "boom",
    };
    const d = try renderDiff(a, &report);
    defer a.free(d);
    try std.testing.expectEqualStrings("--- kotlinc\n+++ klio\n a\n-b\n+c\n+d\nklio error: boom\n", d);
    const same: ParityReport = .{ .matched = true, .kotlinc_stdout = "x\n", .klio_stdout = "x\n", .kotlinc_exit = 0, .klio_error = null };
    const none = try renderDiff(a, &same);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test {
    std.testing.refAllDecls(@This());
}

test "TARGET_VERSION is the expected default" {
    try std.testing.expectEqualStrings("2.4.20", TARGET_VERSION);
}

test "KotlincKind binary and env names" {
    try std.testing.expectEqualStrings("kotlinc", KotlincKind.Jvm.binaryName());
    try std.testing.expectEqualStrings("kotlinc-native", KotlincKind.Native.binaryName());
    try std.testing.expectEqualStrings("KLIO_KOTLINC_JVM_HOME", KotlincKind.Jvm.envOverride());
    try std.testing.expectEqualStrings("KLIO_KOTLINC_NATIVE", KotlincKind.Native.envOverride());
}

test "KotlincError messages render the expected display text" {
    const a = std.testing.allocator;
    {
        const m = try (KotlincError{ .NoKotlinc = {} }).message(a);
        defer a.free(m);
        try std.testing.expect(std.mem.startsWith(u8, m, "kotlinc not found."));
    }
    {
        const m = try (KotlincError{ .NoJava = {} }).message(a);
        defer a.free(m);
        try std.testing.expect(std.mem.startsWith(u8, m, "java not found on PATH"));
    }
    {
        var e = KotlincError{ .Compile = try a.dupe(u8, "boom") };
        defer e.deinit(a);
        const m = try e.message(a);
        defer a.free(m);
        try std.testing.expectEqualStrings("kotlinc compile failed:\nboom", m);
    }
    {
        var e = KotlincError{ .UnsupportedPlatform = try a.dupe(u8, "linux-riscv64") };
        defer e.deinit(a);
        const m = try e.message(a);
        defer a.free(m);
        try std.testing.expectEqualStrings("no kotlinc prebuilt for platform: linux-riscv64", m);
    }
}

