//! Parity harness: locate / install the reference Kotlin compilers
//! (`kotlinc` on the JVM by default; Kotlin/Native is also supported) so a
//! `.kt` file can be compiled and run as a baseline against `klio`.
//!
//! We default to the JVM compiler because native compilation per-file is
//! dominated by LLVM codegen and linking, which makes a corpus sweep take
//! hours. JVM `kotlinc` compiles each file in ~1s and the produced jar runs
//! under `java` in ~200ms, keeping the full sweep tractable. The native path
//! is kept for callers that need a native runtime baseline (e.g. `klio-bench`).

const std = @import("std");

/// glibc: return free heap memory to the OS (see the boundary trim below).
extern "c" fn malloc_trim(pad: usize) c_int;

const ast = @import("ast");
const interp_ir = @import("interp_ir");
const kotlinx_atomicfu = @import("kotlinx_atomicfu");
const kotlinx_coroutines = @import("kotlinx_coroutines");
const kotlinx_serialization = @import("kotlinx_serialization");
const kotlinx_datetime = @import("kotlinx_datetime");
const compose_runtime = @import("compose_runtime");
const compose_ui = @import("compose_ui");
const lexer = @import("lexer");
const pack = @import("pack");
const parser = @import("parser");
const runtime = @import("runtime");
const span = @import("span");
const stdlib = @import("stdlib");
const stdlib_pack = @import("stdlib_pack");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const SourceMap = span.SourceMap;
const KotlinFile = ast.KotlinFile;
const HostBindings = stdlib.HostBindings;

/// Harness entry point (`klio-parity <file.kt>`). The orchestrator wires the
/// real exe; `main.run` is the program logic.
pub const main = @import("main.zig");

/// Default kotlinc version we target (applies to both JVM and Native).
pub const TARGET_VERSION: []const u8 = "2.3.21";

/// Diagnostic outcomes for a locate/install/compile attempt. Carried as data
/// so the caller decides how to surface it. Variants owning heap text document
/// the owner; `deinit` frees them.
pub const ParityError = union(enum) {
    NoKotlinc,
    NoJava,
    Compile: []const u8,
    Install: []const u8,
    UnsupportedPlatform: []const u8,
    Io: []const u8,

    pub fn deinit(self: ParityError, allocator: Allocator) void {
        switch (self) {
            .Compile => |s| allocator.free(s),
            .Install => |s| allocator.free(s),
            .UnsupportedPlatform => |s| allocator.free(s),
            .Io => |s| allocator.free(s),
            .NoKotlinc, .NoJava => {},
        }
    }

    /// Render the error message. Caller owns the returned bytes.
    pub fn message(self: ParityError, allocator: Allocator) Allocator.Error![]u8 {
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

/// `Result<PathBuf, ParityError>` carried as data. `ok` is an owned path; the
/// caller frees it.
pub const PathResult = union(enum) {
    ok: []u8,
    err: ParityError,
};

/// Which Kotlin compiler distribution to download/locate.
pub const KotlincKind = enum {
    /// JVM `kotlinc` (`kotlin-compiler-<v>.zip` from JetBrains GitHub).
    Jvm,
    /// `kotlinc-native` (`kotlin-native-prebuilt-<slug>-<v>.tar.gz` from the
    /// JetBrains CDN, extracted under `~/.konan/`).
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

/// Get a throwaway threaded `Io` for the duration of a call that does its own
/// filesystem work without an externally-threaded `Io`. Mirrors the in-repo
/// `stdlib_pack.readFile` pattern.
fn threadedIo(allocator: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{});
}

/// Look up one environment variable from the parent process. Reads
/// `/proc/self/environ`; returns an owned copy of the value or `null`.
fn getEnvVar(allocator: Allocator, io: Io, name: []const u8) Allocator.Error!?[]u8 {
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
fn procEnvMap(allocator: Allocator, io: Io) Allocator.Error!std.process.Environ.Map {
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

/// The workspace root; resolves to the current directory, since we run from
/// the workspace directory.
fn workspaceRoot(allocator: Allocator) Allocator.Error![]u8 {
    return allocator.dupe(u8, ".");
}

fn parityCacheDir(allocator: Allocator, io: Io) Allocator.Error![]u8 {
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

/// Kotlin/Native distribution descriptor: (archive os-arch slug, CDN subdir,
/// archive extension). Returns the unsupported-platform string on no match;
/// caller owns it.
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
    const cache = try parityCacheDir(allocator, io);
    defer allocator.free(cache);
    const name = try std.fmt.allocPrint(allocator, "kotlinc-{s}", .{version});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache, name });
}

/// Backwards-compatible alias for `findKotlinc(.Jvm)`.
pub fn findKotlinc(allocator: Allocator, io: Io) Allocator.Error!PathResult {
    _ = io;
    return findKotlincKind(allocator, .Jvm);
}

/// Locate the requested `kotlinc` binary. Search order (per kind):
///   1. Kind-specific env var (`KLIO_KOTLINC_JVM_HOME` / `KLIO_KOTLINC_NATIVE`).
///   2. Default cached install location.
///   3. `PATH`.
///
/// When not found, attempts to auto-install unless
/// `KLIO_NO_AUTO_INSTALL_KOTLINC=1`. The returned path is owned by the caller.
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
        // The JVM override is a kotlinc dist root (with bin/kotlinc inside);
        // the native override historically points at the kotlinc-native
        // binary directly. Accept either form for both.
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
            // Match any kotlin-native-prebuilt-*-{TARGET_VERSION} dir under
            // ~/.konan (not just our default slug), to honor pre-existing
            // installs.
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
                            std.mem.indexOf(u8, s, TARGET_VERSION) != null and
                            std.mem.indexOf(u8, s, "-RC") == null)
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

/// Backwards-compatible alias for `installKotlincKind(.Jvm, ...)`.
pub fn installKotlinc(allocator: Allocator, io: Io, version: []const u8) Allocator.Error!PathResult {
    return installKotlincKind(allocator, io, .Jvm, version);
}

/// Download + extract the requested kotlinc distribution. Idempotent: if the
/// destination already has a working binary, this is a no-op. The returned
/// path is the install directory, owned by the caller.
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

    const cache = try parityCacheDir(allocator, io);
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
    printErr("[parity] installing JVM kotlinc {s} into {s}\n", .{ version, cache });
    printErr("[parity] downloading {s}\n", .{url});
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
    printErr("[parity] kotlinc {s} ready at {s}\n", .{ version, dest });
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
    printErr("[parity] installing kotlin-native {s} ({s}) into {s}\n", .{ version, slug.slug, root });
    printErr("[parity] downloading {s}\n", .{url});
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
    printErr("[parity] kotlin-native {s} ready at {s}\n", .{ version, dest });
    return .{ .ok = dest };
}

/// Download `url` to `dest`, trying curl then wget. Returns a `ParityError` on
/// failure, or `null` on success.
fn download(allocator: Allocator, io: Io, env: *std.process.Environ.Map, url: []const u8, dest: []const u8) Allocator.Error!?ParityError {
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
        return ParityError{ .Install = try std.fmt.allocPrint(allocator, "download failed: {s}", .{url}) };
    }
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), dest, io) catch {};
    return null;
}

/// Extract `archive` into `into` (zip via unzip, otherwise tar). Returns a
/// `ParityError` on failure, or `null` on success.
fn extractArchive(allocator: Allocator, io: Io, env: *std.process.Environ.Map, archive: []const u8, into: []const u8, ext: []const u8) Allocator.Error!?ParityError {
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
        return ParityError{ .Install = try std.fmt.allocPrint(allocator, "extract spawn: {s}", .{@errorName(e)}) };
    };
    defer allocator.free(out.stdout);
    defer allocator.free(out.stderr);
    if (!termOk(out.term)) {
        return ParityError{ .Install = try std.fmt.allocPrint(
            allocator,
            "extract {s} failed (exit {any})",
            .{ archive, out.term },
        ) };
    }
    return null;
}

/// Worker count for a parallel sweep. Capped at 6 regardless of core count;
/// override with `KLIO_PARITY_JOBS`.
pub fn defaultJobs(allocator: Allocator) usize {
    var threaded = threadedIo(allocator);
    defer threaded.deinit();
    const io = threaded.io();
    if (getEnvVar(allocator, io, "KLIO_PARITY_JOBS") catch null) |v| {
        defer allocator.free(v);
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch null) |j| {
            return @max(j, 1);
        }
    }
    const cores = std.Thread.getCpuCount() catch 4;
    return std.math.clamp(cores, 1, 6);
}

/// The workspace corpus directory (`tests/fixtures/parity_corpus`).
pub fn corpusDir(allocator: Allocator) Allocator.Error![]u8 {
    return std.fs.path.join(allocator, &.{ "tests", "fixtures", "parity_corpus" });
}

/// The workspace `examples/` directory.
pub fn examplesDir(allocator: Allocator) Allocator.Error![]u8 {
    return allocator.dupe(u8, "examples");
}

/// Every `.kt` file directly under `dir`, sorted by path. Each path is owned by
/// the caller; the outer slice too.
/// Group `files` so programs sharing a dependency-base key run
/// consecutively: grouped, a base cache of ONE covers a whole corpus with
/// one rebuild per distinct mask instead of one per alphabetical mask
/// switch — the difference between a bounded-RSS corpus run and the
/// watchdog cap. Stable (alphabetical) within a group. Best-effort: a file
/// that fails to read/parse keys as 0 and runs first.
pub fn groupByBaseKey(allocator: Allocator, io: Io, files: [][]u8) void {
    const Keyed = struct { key: u64, file: []u8 };
    const keyed = allocator.alloc(Keyed, files.len) catch return;
    defer allocator.free(keyed);
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    for (files, 0..) |f, i| {
        keyed[i] = .{ .key = fileBaseKey(arena_inst.allocator(), io, f), .file = f };
        _ = arena_inst.reset(.retain_capacity);
    }
    std.mem.sort(Keyed, keyed, {}, struct {
        fn lt(_: void, x: Keyed, y: Keyed) bool {
            if (x.key != y.key) return x.key < y.key;
            return std.mem.lessThan(u8, x.file, y.file);
        }
    }.lt);
    for (keyed, 0..) |k, i| files[i] = k.file;
}

fn fileBaseKey(arena: Allocator, io: Io, file: []const u8) u64 {
    const text = readFileOpt(arena, io, file) orelse return 0;
    var map = SourceMap.init(arena);
    const parsed = parsePackFile(arena, &map, file, text) catch return 0;
    const ast_f = switch (parsed) {
        .err => return 0,
        .ok => |f| f,
    };
    var prefixes = std.StringHashMap(void).init(arena);
    collectImportPrefixes(arena, &ast_f, &prefixes) catch return 0;
    collectQualifiedPrefixes(arena, text, &prefixes) catch return 0;
    var imports_coroutines = false;
    var itk = prefixes.keyIterator();
    while (itk.next()) |imp| {
        if (std.mem.startsWith(u8, imp.*, "kotlinx.coroutines")) {
            imports_coroutines = true;
            break;
        }
    }
    base_lock.lock();
    defer base_lock.unlock();
    const mask = packMaskFor(io, &prefixes, imports_coroutines, arena) catch return 0;
    const full = stdlibGateFull(io, &prefixes, mask, arena) catch return 0;
    return (@as(u64, mask) << 1) | @intFromBool(full);
}

pub fn collectKt(allocator: Allocator, io: Io, dir: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch
        return out.toOwnedSlice(allocator);
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kt")) continue;
        const p = try std.fs.path.join(allocator, &.{ dir, entry.name });
        try out.append(allocator, p);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

fn writeFd(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data.ptr + off, data.len - off);
        const e = std.os.linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return;
        if (rc == 0) return;
        off += rc;
    }
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(2, s);
}

// =========================================================================
// kotlinc compile + run, expected-output cache, the klio in-process runners,
// the full parity check + diff, and the corpus build + parallel sweep.
// =========================================================================

pub const ExpectedHit = struct { stdout: []u8, exit: ?i32 };

/// `Result<T, ParityError>` carried as data.
pub fn PResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ParityError,
    };
}

/// `Result<T, String>` carried as data, for the klio-side runners that
/// return a plain string on error.
pub fn SResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []u8,
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

/// 16-hex-digit render of the std default hasher over `bytes`. Matches the
/// stable rendering the corpus cache keys rely on.
fn hashHex(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const h = std.hash.Wyhash.hash(0, bytes);
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{h});
}

/// Content-hash key for `file`, over the file bytes, rendered as 16 hex digits.
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

/// Compile a `.kt` file with JVM `kotlinc` into a self-contained jar, cached
/// by content hash. The returned jar path is owned.
pub fn compileWithKotlinc(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!PResult([]u8) {
    const kotlinc = switch (try findKotlinc(allocator, io)) {
        .err => |e| return .{ .err = e },
        .ok => |k| k,
    };
    defer allocator.free(kotlinc);
    var env = try procEnvMap(allocator, io);
    defer env.deinit();
    const cache = try parityCacheDir(allocator, io);
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

/// Run a previously-compiled jar under `java -jar`, returning captured stdout
/// and exit code (stdout owned).
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

// ---------------------- expected-output cache ----------------------

fn expectedCacheDir(allocator: Allocator, io: Io) Allocator.Error![]u8 {
    const cache = try parityCacheDir(allocator, io);
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

/// kotlinc output for a single `.kt` file, cached by content hash. The
/// returned stdout is owned.
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

// ---------------------- stdout capture sink ----------------------

/// Stdout sink that captures every `println` line for parity diffing. Lines
/// accumulate in `cur` and split on `\n`, trimming the trailing `\n` per
/// line.
pub const CaptureOutput = struct {
    lines: std.ArrayList([]u8),
    cur: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CaptureOutput {
        return .{ .lines = .empty, .cur = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *CaptureOutput) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.cur.deinit(self.allocator);
    }

    fn writeStr(self: *CaptureOutput, s: []const u8) void {
        self.cur.appendSlice(self.allocator, s) catch return;
        while (std.mem.indexOfScalar(u8, self.cur.items, '\n')) |idx| {
            const line = self.allocator.dupe(u8, self.cur.items[0..idx]) catch return;
            self.lines.append(self.allocator, line) catch {
                self.allocator.free(line);
                return;
            };
            const remaining = self.cur.items.len - (idx + 1);
            std.mem.copyForwards(u8, self.cur.items[0..remaining], self.cur.items[idx + 1 ..]);
            self.cur.shrinkRetainingCapacity(remaining);
        }
    }

    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: *CaptureOutput = @ptrCast(@alignCast(ctx));
        self.writeStr(s);
    }
    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: *CaptureOutput = @ptrCast(@alignCast(ctx));
        self.writeStr(s);
        self.writeStr("\n");
    }

    const vtable: runtime.Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: *CaptureOutput) runtime.Output {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Join captured lines into the final program-output string. Owned by
    /// `allocator`.
    pub fn intoJoined(self: *CaptureOutput, allocator: Allocator) Allocator.Error![]u8 {
        if (self.cur.items.len != 0) {
            const trailing = try self.allocator.dupe(u8, self.cur.items);
            try self.lines.append(self.allocator, trailing);
            self.cur.clearRetainingCapacity();
        }
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        for (self.lines.items, 0..) |l, i| {
            if (i != 0) try joined.append(allocator, '\n');
            try joined.appendSlice(allocator, l);
        }
        if (joined.items.len != 0) try joined.append(allocator, '\n');
        return joined.toOwnedSlice(allocator);
    }
};

// ---------------------- klio in-process runners ----------------------

fn joinIdentPath(allocator: Allocator, path: []const ast.Ident) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (path, 0..) |seg, i| {
        if (i != 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, seg.name);
    }
    return out.toOwnedSlice(allocator);
}

fn packageName(allocator: Allocator, file: *const KotlinFile) Allocator.Error![]u8 {
    if (file.package) |p| return joinIdentPath(allocator, p.path);
    return allocator.alloc(u8, 0);
}

fn collectImportPrefixes(allocator: Allocator, file: *const KotlinFile, set: *std.StringHashMap(void)) Allocator.Error!void {
    for (file.imports) |imp| {
        const p = try joinIdentPath(allocator, imp.path);
        if (p.len != 0) {
            const gop = try set.getOrPut(p);
            if (gop.found_existing) allocator.free(p);
        } else allocator.free(p);
    }
}

/// Qualified references reach stdlib/pack code without an import statement
/// (`kotlin.time.Duration` is legal bare), so the import list alone
/// under-opens the stdlib gate and the pack mask. Scan the raw source for
/// `kotlin`/`kotlinx`-rooted dotted tokens and record their two-segment
/// prefix. A match inside a comment or string over-opens the gate, which
/// costs base-build time only — never correctness.
fn collectQualifiedPrefixes(allocator: Allocator, text: []const u8, set: *std.StringHashMap(void)) Allocator.Error!void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "kotlin")) |at| {
        i = at + "kotlin".len;
        if (at > 0) {
            const c = text[at - 1];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
        }
        var j = i;
        if (j < text.len and text[j] == 'x') j += 1;
        if (j >= text.len or text[j] != '.') continue;
        const seg_start = j + 1;
        var k = seg_start;
        while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
        if (k == seg_start or !std.ascii.isLower(text[seg_start])) continue;
        const p = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ text[at..j], text[seg_start..k] });
        const gop = try set.getOrPut(p);
        if (gop.found_existing) allocator.free(p);
    }
}

/// `outer.startsWith(inner ++ ".")`.
fn startsWithDot(allocator: Allocator, outer: []const u8, inner: []const u8) bool {
    const dotted = std.fmt.allocPrint(allocator, "{s}.", .{inner}) catch return false;
    defer allocator.free(dotted);
    return std.mem.startsWith(u8, outer, dotted);
}

/// `imp == pkg || imp.startsWith("pkg.") || pkg.startsWith("imp.")`.
fn matchesImportPrefix(allocator: Allocator, imp: []const u8, pkg: []const u8) bool {
    if (std.mem.eql(u8, imp, pkg)) return true;
    if (startsWithDot(allocator, imp, pkg)) return true;
    if (startsWithDot(allocator, pkg, imp)) return true;
    return false;
}

fn formatVmError(allocator: Allocator, e: interp_ir.VmError) Allocator.Error![]u8 {
    return switch (e) {
        .InvalidMain => allocator.dupe(u8, "runtime error: main function not found in module"),
        .Eval => |s| std.fmt.allocPrint(allocator, "runtime error: {s}", .{s}),
    };
}

/// Parse the embedded stdlib pack's curated `SOURCES` and return the subset
/// whose declared packages are imported (directly or by prefix) somewhere in
/// `existing`. ASTs are allocated into `arena`.
fn embeddedStdlibSources(arena: Allocator, io: Io, existing: []const KotlinFile, map: *SourceMap) Allocator.Error![]KotlinFile {
    var import_prefixes = std.StringHashMap(void).init(arena);
    for (existing) |*f| {
        try collectImportPrefixes(arena, f, &import_prefixes);
    }
    return embeddedStdlibSourcesPrefixed(arena, io, &import_prefixes, map);
}

/// `embeddedStdlibSources` over an explicit import-prefix set; the
/// shared-base loader computes the gate from prefixes alone.
fn embeddedStdlibSourcesPrefixed(arena: Allocator, io: Io, import_prefixes: *const std.StringHashMap(void), map: *SourceMap) Allocator.Error![]KotlinFile {
    var perr: pack.PackError = undefined;
    var env = try procEnvMap(arena, io);
    defer env.deinit();
    const bytes = (try stdlib_pack.stdlibPackBytes(arena, &env, &perr)) orelse return &.{};
    var reader = (try pack.PackReader.fromBytes(arena, bytes, &perr)) orelse return &.{};
    defer reader.deinit();
    const payload = (try reader.readSection(pack.section_names.SOURCES, &perr)) orelse return &.{};
    defer payload.deinit(arena);
    var bundle = (try pack.schema.decode(pack.schema.SourceBundle, arena, payload.slice(), &perr)) orelse return &.{};
    defer bundle.deinit(arena);

    const Parsed = struct { pkg: []u8, ast: KotlinFile };
    var parsed: std.ArrayList(Parsed) = .empty;
    defer parsed.deinit(arena);

    for (bundle.files) |sf| {
        if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
        const fid = try map.add(sf.rel_path, sf.bytes);
        const srcf = map.get(fid).source;
        var lx = try lexer.Lexer.init(arena, fid, srcf);
        const lexed = try lx.tokenize();
        if (lexed.diagnostics.hasErrors()) continue;
        const p = parser.Parser.new(arena, fid, srcf, lexed.tokens);
        const file_ast = p.parseFile();
        if (p.diagnostics.hasErrors()) continue;
        const pkg = try packageName(arena, &file_ast);
        try parsed.append(arena, .{ .pkg = pkg, .ast = file_ast });
    }

    var any_non_implicit = false;
    for (parsed.items) |pr| {
        if (pr.pkg.len != 0 and !stdlib.isImplicitlyImportedPackage(pr.pkg)) {
            any_non_implicit = true;
            break;
        }
    }

    var imported_match = false;
    outer: for (parsed.items) |pr| {
        if (pr.pkg.len == 0) continue;
        var it = import_prefixes.keyIterator();
        while (it.next()) |imp_ptr| {
            if (matchesImportPrefix(arena, imp_ptr.*, pr.pkg)) {
                imported_match = true;
                break :outer;
            }
        }
    }

    const load_gated = imported_match or !any_non_implicit;

    var out: std.ArrayList(KotlinFile) = .empty;
    errdefer out.deinit(arena);
    for (parsed.items) |pr| {
        const is_implicit = pr.pkg.len != 0 and stdlib.isImplicitlyImportedPackage(pr.pkg);
        if (is_implicit or load_gated) {
            try out.append(arena, pr.ast);
        }
    }
    return out.toOwnedSlice(arena);
}

// ---------------------- canonical program loader ----------------------

/// How a program's dependency ASTs are assembled. All three modes flow through
/// the same `buildModuleFiles` + `Vm.run` tail; they differ only in which
/// dependency sources are folded in and how the kotlinx packs are materialized.
pub const LoadMode = enum {
    /// Embedded stdlib only (what `check`'s kotlinc oracle compares against).
    EmbeddedOnly,
    /// Embedded stdlib + the in-repo kotlinx packs parsed straight from source.
    SourcePacks,
    /// Embedded stdlib + the in-repo kotlinx packs round-tripped through a
    /// compiled `.klio-pack` byte image (encode -> decode -> parse), exercising
    /// the compiled-pack load path rather than the raw-source one.
    CompiledPacks,
};

/// A program assembled for one `LoadMode`: the full AST set in build order
/// (deps first, user last), the host bindings to install (none for
/// `EmbeddedOnly`), and the source map the ASTs were parsed against (for
/// locating lowering diagnostics). Everything is allocated into the
/// caller-provided arena.
pub const LoadedProgram = struct {
    asts: []KotlinFile,
    bindings: ?HostBindings,
    map: *const SourceMap,
};

/// One in-repo kotlinx pack source file: path (for spans / pack rel_path) and
/// its UTF-8 bytes, both arena-owned.
const PackSource = struct { path: []u8, text: []u8 };

/// The in-repo kotlinx pack directories, in load order.
/// Number of in-repo packs the parity pipeline can load from source.
pub const N_PACK_DIRS = 17;
/// One bit per in-repo pack dir (`kotlinxPackDirs` order).
pub const PackMask = u32;

fn kotlinxPackDirs(arena: Allocator) Allocator.Error![N_PACK_DIRS][]u8 {
    const ws = try workspaceRoot(arena);
    return .{
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlinx-coroutines" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlinx-atomicfu" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlinx-io" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-runtime-engine" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-androidx-collection" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-mosaic" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui-util" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui-geometry" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui-unit" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui-graphics" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-animation-core" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-runtime-saveable" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-compose-ui-text" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlinx-serialization" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlinx-datetime" }),
        try std.fs.path.join(arena, &.{ ws, "kotlin-klio", "klio-kotlin-test" }),
    };
}

/// Gather the source files of every in-repo kotlinx pack the user program pulls
/// in (by import prefix; coroutines also pulls atomicfu). The returned records
/// are the inputs both `SourcePacks` (parse directly) and `CompiledPacks`
/// (pack-roundtrip then parse) consume.
fn collectKotlinxPackSources(
    arena: Allocator,
    io: Io,
    pack_dirs: []const []const u8,
    import_prefixes: *const std.StringHashMap(void),
    imports_coroutines: bool,
) Allocator.Error!SResult([]PackSource) {
    var out: std.ArrayList(PackSource) = .empty;
    defer out.deinit(arena);
    // One selection authority: the same import-prefix + manifest-dependency
    // closure the baked-base key uses, so collected content can never
    // diverge from the base identity.
    const mask = try packMaskFor(io, import_prefixes, imports_coroutines, arena);
    for (pack_dirs, 0..) |pack_dir, idx| {
        if (mask & (@as(PackMask, 1) << @intCast(idx)) == 0) continue;

        const sources = switch (try collectManifestSources(arena, io, pack_dir)) {
            .err => |e| return .{ .err = e },
            .ok => |s| s,
        };
        for (sources) |src_path| {
            const text = readFileOpt(arena, io, src_path) orelse {
                return .{ .err = try std.fmt.allocPrint(arena, "read {s}", .{src_path}) };
            };
            try out.append(arena, .{ .path = src_path, .text = text });
        }
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

/// Round-trip the collected pack sources through a compiled `.klio-pack` byte
/// image: encode a `SourceBundle` into the `SOURCES` section, then read it back
/// out. This drives the compiled-pack codepath (encode -> decode) for the same
/// bytes `SourcePacks` parses directly, so the differential harness can compare
/// the two load paths. Returns the decoded source files, arena-owned.
fn packRoundtrip(arena: Allocator, sources: []const PackSource) Allocator.Error!SResult([]pack.schema.SourceFile) {
    var files = try arena.alloc(pack.schema.SourceFile, sources.len);
    for (sources, 0..) |s, i| {
        files[i] = .{ .rel_path = s.path, .bytes = s.text };
    }
    const bundle = pack.schema.SourceBundle{ .files = files };

    var perr: pack.PackError = undefined;
    const payload = (try pack.schema.encode(pack.schema.SourceBundle, arena, &bundle, &perr)) orelse
        return .{ .err = try arena.dupe(u8, "encode SourceBundle") };

    var w = pack.PackWriter.init(arena);
    defer w.deinit();
    _ = try w.addZstd(pack.section_names.SOURCES, payload.items);
    const image = (try w.finish(&perr)) orelse
        return .{ .err = try arena.dupe(u8, "write pack image") };

    var reader = (try pack.PackReader.fromBytes(arena, image.items, &perr)) orelse
        return .{ .err = try arena.dupe(u8, "read pack image") };
    defer reader.deinit();
    const section = (try reader.readSection(pack.section_names.SOURCES, &perr)) orelse
        return .{ .err = try arena.dupe(u8, "pack SOURCES section missing") };
    defer section.deinit(arena);
    const decoded = (try pack.schema.decode(pack.schema.SourceBundle, arena, section.slice(), &perr)) orelse
        return .{ .err = try arena.dupe(u8, "decode SourceBundle") };
    return .{ .ok = decoded.files };
}

/// Build the full AST set (and host bindings) for `file` under `mode`. The
/// canonical loader behind `runWithKtc` / `runWithPacks`: each runner is this
/// plus the shared build + `Vm.run` tail. ASTs and bindings live in `arena`.
pub fn loadProgram(arena: Allocator, io: Io, file: []const u8, mode: LoadMode) Allocator.Error!SResult(LoadedProgram) {
    return loadProgramFiles(arena, io, &.{file}, mode);
}

/// Multi-file variant of `loadProgram`: every path in `files` is a user
/// source file, assembled (in order, after packs + stdlib) into one
/// program — the in-process mirror of `klio run a.kt b.kt`.
pub fn loadProgramFiles(arena: Allocator, io: Io, files: []const []const u8, mode: LoadMode) Allocator.Error!SResult(LoadedProgram) {
    // The SourceMap is borrowed by the parsed ASTs (and returned to the
    // caller for diagnostic rendering) for the arena's lifetime; it is
    // never deinit'd so spans stay valid through build + run.
    const map = try arena.create(SourceMap);
    map.* = SourceMap.init(arena);

    var user_asts: std.ArrayList(KotlinFile) = .empty;
    defer user_asts.deinit(arena);
    for (files) |file| {
        const user_src = readFileOpt(arena, io, file) orelse {
            return .{ .err = try std.fmt.allocPrint(arena, "read {s}", .{file}) };
        };
        const user_ast = switch (try parsePackFile(arena, map, file, user_src)) {
            .err => |e| return .{ .err = e },
            .ok => |a| a,
        };
        try user_asts.append(arena, user_ast);
    }

    var asts: std.ArrayList(KotlinFile) = .empty;
    defer asts.deinit(arena);
    var bindings: ?HostBindings = null;

    if (mode == .EmbeddedOnly) {
        const stdlib_asts = try embeddedStdlibSources(arena, io, user_asts.items, map);
        try asts.appendSlice(arena, stdlib_asts);
        try asts.appendSlice(arena, user_asts.items);
        return .{ .ok = .{ .asts = try asts.toOwnedSlice(arena), .bindings = null, .map = map } };
    }

    // SourcePacks / CompiledPacks: fold in the in-repo kotlinx packs.
    const pack_dirs = try kotlinxPackDirs(arena);

    var user_import_prefixes = std.StringHashMap(void).init(arena);
    for (user_asts.items) |*ua| {
        try collectImportPrefixes(arena, ua, &user_import_prefixes);
    }
    var imports_coroutines = false;
    {
        var it = user_import_prefixes.keyIterator();
        while (it.next()) |imp_ptr| {
            const imp = imp_ptr.*;
            if (std.mem.eql(u8, imp, "kotlinx.coroutines") or
                std.mem.startsWith(u8, imp, "kotlinx.coroutines."))
            {
                imports_coroutines = true;
                break;
            }
        }
    }

    const pack_sources = switch (try collectKotlinxPackSources(arena, io, &pack_dirs, &user_import_prefixes, imports_coroutines)) {
        .err => |e| return .{ .err = e },
        .ok => |s| s,
    };

    switch (mode) {
        .SourcePacks => {
            for (pack_sources) |s| {
                const file_ast = switch (try parsePackFile(arena, map, s.path, s.text)) {
                    .err => |e| return .{ .err = e },
                    .ok => |a| a,
                };
                try registerAstPackage(arena, &file_ast);
                try asts.append(arena, file_ast);
            }
        },
        .CompiledPacks => {
            const decoded = switch (try packRoundtrip(arena, pack_sources)) {
                .err => |e| return .{ .err = e },
                .ok => |d| d,
            };
            for (decoded) |sf| {
                const file_ast = switch (try parsePackFile(arena, map, sf.rel_path, sf.bytes)) {
                    .err => |e| return .{ .err = e },
                    .ok => |a| a,
                };
                try registerAstPackage(arena, &file_ast);
                try asts.append(arena, file_ast);
            }
        },
        .EmbeddedOnly => unreachable,
    }

    var probe: std.ArrayList(KotlinFile) = .empty;
    defer probe.deinit(arena);
    try probe.appendSlice(arena, asts.items);
    try probe.appendSlice(arena, user_asts.items);
    const stdlib_asts = try embeddedStdlibSources(arena, io, probe.items, map);
    for (stdlib_asts) |a| {
        try registerAstPackage(arena, &a);
        try asts.append(arena, a);
    }
    try asts.appendSlice(arena, user_asts.items);

    bindings = try packHostBindings(arena);

    return .{ .ok = .{ .asts = try asts.toOwnedSlice(arena), .bindings = bindings, .map = map } };
}

/// Host bindings installed for the pack load modes: stdlib defaults plus
/// the kotlinx coroutines/atomicfu/serialization/datetime overlays.
fn packHostBindings(arena: Allocator) Allocator.Error!HostBindings {
    var b = try HostBindings.withStdlibDefaults(arena);
    {
        var co = try kotlinx_coroutines.hostBindings(arena);
        var it = co.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        co.deinit();
    }
    {
        var af = try kotlinx_atomicfu.hostBindings(arena);
        var it = af.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        af.deinit();
    }
    {
        var sr = try kotlinx_serialization.hostBindings(arena);
        var it = sr.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        sr.deinit();
    }
    {
        var dt = try kotlinx_datetime.hostBindings(arena);
        var it = dt.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        dt.deinit();
    }
    {
        var cr = try compose_runtime.hostBindings(arena);
        var it = cr.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        cr.deinit();
    }
    {
        var cu = try compose_ui.hostBindings(arena);
        var it = cu.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        cu.deinit();
    }
    {
        // Composer-stack intrinsics (interp_ir, touch the implicit-composer TLS).
        var ci = try interp_ir.compose.hostBindings(arena);
        var it = ci.table.iterator();
        while (it.next()) |e| try b.register(e.key_ptr.*, e.value_ptr.*);
        ci.deinit();
    }
    return b;
}

// ---------------------- once-per-process stdlib base ----------------------
//
// Every in-process run used to parse + lower the full embedded stdlib (and
// the kotlinx packs) from scratch. The harnesses run hundreds of programs
// per process, so the dependency set is lowered ONCE per (load mode, pack
// subset, stdlib gate) into an immutable `StdlibBase` on a process-lifetime
// arena; each program then clones the mutable parts onto its own arena and
// lowers only its own declarations (`buildModuleFilesExtend`). A program
// whose top-level names overlap the base's falls back to the original
// whole-program build, so cross-boundary renames and resolution decisions
// are never approximated.

const StdlibBase = interp_ir.build.StdlibBase;

/// One published snapshot: the lowered base plus the SourceMap its spans
/// resolve through. Immutable after publication; read concurrently.
const BaseEntry = struct {
    base: *const StdlibBase,
    map: *const SourceMap,
    /// The cache entry's own arena. Values the enum-entry patch writes into
    /// the SHARED base instances must live exactly as long as the entry, not
    /// as long as the program that happened to evaluate them.
    patch_allocator: ?Allocator = null,
};

var base_lock: runtime.SpinMutex = .{};
var base_arena_state: ?*std.heap.ArenaAllocator = null;

/// A cached dependency base plus the arena that owns its memory, so an
/// evicted base's ~stdlib-sized footprint returns to the OS. `entry` is null
/// when the base for this key is not snapshot-safe (cached so callers stop
/// retrying); such placeholders own no arena and are never evicted.
const CachedBase = struct {
    entry: ?*const BaseEntry,
    arena: ?*std.heap.ArenaAllocator,
    tick: u64,
};
/// key (mode|mask|gate byte) -> cached base.
var base_entries: ?std.AutoHashMap(u64, CachedBase) = null;
var base_tick: u64 = 0;

/// Max number of real (arena-owning) bases to retain; 0 means unbounded (the
/// default, so `klio run` and the reuse-heavy harnesses are unaffected). A
/// batch harness that runs many programs across many pack masks — the e2e
/// corpus — sets a small bound so the process does not accumulate one full
/// stdlib clone per mask. Safe to evict: a base is only referenced inside
/// `getOrBuildBase`/`prepareWithBase` (the run clones what it needs), and the
/// batch harnesses drive it from a single thread.
pub var base_cache_max: usize = 0;
var stdlib_meta_cache: ?StdlibMeta = null;
var pack_meta_cache: [N_PACK_DIRS]?PackMeta = @splat(null);

/// Package universe of the embedded stdlib bundle, for the load gate.
const StdlibMeta = struct {
    pkgs: []const []const u8,
    any_non_implicit: bool,
};

/// One in-repo kotlinx pack's identity + import surface.
const PackMeta = struct {
    lib_id: []const u8,
    import_prefixes: []const []const u8,
    /// `[[deps]]` ids from the pack manifest (transitively chased when
    /// selecting packs: importing compose pulls kotlinx.coroutines and
    /// androidx.collection even though the program never names them).
    deps: []const []const u8,
};

fn baseKey(mode: LoadMode, mask: PackMask, full: bool) u64 {
    // `mask` occupies a full PackMask (one bit per in-repo pack, up to
    // N_PACK_DIRS), so it lands in bits 1..32 and `mode` sits above it (bit
    // 40+), no overlap even when the top mask bit is set.
    return (@as(u64, @intFromEnum(mode)) << 40) | (@as(u64, mask) << 1) | @intFromBool(full);
}

/// `KLIO_TRACE_STDLIB_BASE=1` prints one fast/fallback line per program.
/// Read with a raw `read` loop: `/proc/self/environ` stats as 0 bytes, so
/// the stat-trusting `readFileAlloc` behind `getEnvVar` sees it empty.
var trace_base_flag: ?bool = null;
fn traceBaseEnabled() bool {
    if (trace_base_flag) |v| return v;
    var enabled = false;
    if (@import("builtin").os.tag == .linux) blk: {
        const fd = std.os.linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(fd)) < 0) break :blk;
        const ifd: i32 = @intCast(fd);
        defer _ = std.os.linux.close(ifd);
        var buf: [16384]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const rc = std.os.linux.read(ifd, buf[len..].ptr, buf.len - len);
            const e = std.os.linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) break;
            if (rc == 0) break;
            len += rc;
        }
        var it = std.mem.splitScalar(u8, buf[0..len], 0);
        while (it.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], "KLIO_TRACE_STDLIB_BASE")) {
                const val = entry[eq + 1 ..];
                enabled = val.len != 0 and !std.mem.eql(u8, val, "0");
            }
        }
    }
    trace_base_flag = enabled;
    return enabled;
}

fn baseArenaAllocator() Allocator {
    if (base_arena_state == null) {
        const holder = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch @panic("oom");
        holder.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        base_arena_state = holder;
    }
    return base_arena_state.?.allocator();
}

/// Stdlib bundle package metadata, parsed once per process (under the
/// base lock).
fn stdlibMeta(io: Io) Allocator.Error!*const StdlibMeta {
    if (stdlib_meta_cache) |*m| return m;
    const a = baseArenaAllocator();
    var pkgs: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    var any_non_implicit = false;
    blk: {
        var perr: pack.PackError = undefined;
        var env = try procEnvMap(a, io);
        defer env.deinit();
        const bytes = (try stdlib_pack.stdlibPackBytes(a, &env, &perr)) orelse break :blk;
        var reader = (try pack.PackReader.fromBytes(a, bytes, &perr)) orelse break :blk;
        defer reader.deinit();
        const payload = (try reader.readSection(pack.section_names.SOURCES, &perr)) orelse break :blk;
        const bundle = (try pack.schema.decode(pack.schema.SourceBundle, a, payload.slice(), &perr)) orelse break :blk;
        var map = SourceMap.init(a);
        for (bundle.files) |sf| {
            if (stdlib.isConsumptionDeferredSource(sf.rel_path)) continue;
            const fid = try map.add(sf.rel_path, sf.bytes);
            const srcf = map.get(fid).source;
            var lx = try lexer.Lexer.init(a, fid, srcf);
            const lexed = try lx.tokenize();
            if (lexed.diagnostics.hasErrors()) continue;
            const p = parser.Parser.new(a, fid, srcf, lexed.tokens);
            const file_ast = p.parseFile();
            if (p.diagnostics.hasErrors()) continue;
            const pkg = try packageName(a, &file_ast);
            if (pkg.len == 0) continue;
            if (!stdlib.isImplicitlyImportedPackage(pkg)) any_non_implicit = true;
            const gop = try seen.getOrPut(pkg);
            if (!gop.found_existing) try pkgs.append(a, pkg);
        }
    }
    stdlib_meta_cache = .{ .pkgs = try pkgs.toOwnedSlice(a), .any_non_implicit = any_non_implicit };
    return &stdlib_meta_cache.?;
}

/// Import prefixes + library id of one in-repo kotlinx pack, parsed once
/// per process (under the base lock).
fn packMeta(io: Io, idx: usize) Allocator.Error!*const PackMeta {
    if (pack_meta_cache[idx]) |*m| return m;
    const a = baseArenaAllocator();
    const dirs = try kotlinxPackDirs(a);
    const dir = dirs[idx];
    const lib_id = (try manifestLibraryId(a, io, dir)) orelse try a.alloc(u8, 0);
    var prefixes: std.ArrayList([]const u8) = .empty;
    switch (try collectManifestSources(a, io, dir)) {
        .err => {},
        .ok => |sources| {
            var set = std.StringHashMap(void).init(a);
            var map = SourceMap.init(a);
            for (sources) |src_path| {
                const text = readFileOpt(a, io, src_path) orelse continue;
                const parsed = switch (try parsePackFile(a, &map, src_path, text)) {
                    .err => continue,
                    .ok => |f| f,
                };
                try collectImportPrefixes(a, &parsed, &set);
            }
            var it = set.keyIterator();
            while (it.next()) |k| try prefixes.append(a, k.*);
        },
    }
    pack_meta_cache[idx] = .{
        .lib_id = lib_id,
        .import_prefixes = try prefixes.toOwnedSlice(a),
        .deps = try manifestDepIds(a, io, dir),
    };
    return &pack_meta_cache[idx].?;
}

/// `[[deps]]` ids declared by a pack manifest ("stdlib" included; the
/// mask closure simply finds no pack dir for it).
fn manifestDepIds(allocator: Allocator, io: Io, pack_dir: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    const toml_path = try std.fs.path.join(allocator, &.{ pack_dir, "klio.toml" });
    defer allocator.free(toml_path);
    const toml = readFileOpt(allocator, io, toml_path) orelse return try out.toOwnedSlice(allocator);
    var in_deps = false;
    var it = std.mem.splitScalar(u8, toml, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, std.mem.sliceTo(line, '#'), " \t\r\n");
        if (std.mem.startsWith(u8, l, "[")) {
            in_deps = std.mem.eql(u8, l, "[[deps]]");
            continue;
        }
        if (in_deps and std.mem.startsWith(u8, l, "id")) {
            const rest = std.mem.trimStart(u8, l[2..], " =");
            const v = std.mem.trim(u8, std.mem.trim(u8, rest, " \t\r\n"), "\"");
            if (v.len != 0) try out.append(allocator, try allocator.dupe(u8, v));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Which in-repo packs `import_prefixes` pulls in, as a bitmask over
/// `kotlinxPackDirs` order. Mirrors `collectKotlinxPackSources`' selection
/// (including coroutines forcing atomicfu).
fn packMaskFor(io: Io, import_prefixes: *const std.StringHashMap(void), imports_coroutines: bool, scratch: Allocator) Allocator.Error!PackMask {
    var mask: PackMask = 0;
    var idx: usize = 0;
    while (idx < N_PACK_DIRS) : (idx += 1) {
        const meta = try packMeta(io, idx);
        var wanted = false;
        var it = import_prefixes.keyIterator();
        while (it.next()) |imp_ptr| {
            const imp = imp_ptr.*;
            if (std.mem.eql(u8, imp, meta.lib_id) or
                startsWithDot(scratch, imp, meta.lib_id) or
                startsWithDot(scratch, meta.lib_id, imp))
            {
                wanted = true;
                break;
            }
        }
        if (std.mem.eql(u8, meta.lib_id, "kotlinx.atomicfu") and imports_coroutines) wanted = true;
        if (wanted) mask |= @as(PackMask, 1) << @intCast(idx);
    }
    // Manifest-dependency closure: a selected pack pulls the packs its
    // klio.toml declares, transitively (compose -> kotlinx.coroutines +
    // androidx.collection -> kotlinx.atomicfu).
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < N_PACK_DIRS) : (i += 1) {
            if (mask & (@as(PackMask, 1) << @intCast(i)) == 0) continue;
            const m = try packMeta(io, i);
            for (m.deps) |dep| {
                var j: usize = 0;
                while (j < N_PACK_DIRS) : (j += 1) {
                    if (mask & (@as(PackMask, 1) << @intCast(j)) != 0) continue;
                    const jm = try packMeta(io, j);
                    if (std.mem.eql(u8, jm.lib_id, dep)) {
                        mask |= @as(PackMask, 1) << @intCast(j);
                        changed = true;
                    }
                }
            }
        }
    }
    return mask;
}

/// Whether the stdlib load gate opens fully for this prefix set (mirrors
/// `embeddedStdlibSources`' `load_gated`).
fn stdlibGateFull(io: Io, import_prefixes: *const std.StringHashMap(void), mask: PackMask, scratch: Allocator) Allocator.Error!bool {
    const meta = try stdlibMeta(io);
    if (!meta.any_non_implicit) return true;
    var it = import_prefixes.keyIterator();
    while (it.next()) |imp_ptr| {
        for (meta.pkgs) |pkg| {
            if (matchesImportPrefix(scratch, imp_ptr.*, pkg)) return true;
        }
    }
    var idx: usize = 0;
    while (idx < N_PACK_DIRS) : (idx += 1) {
        if (mask & (@as(PackMask, 1) << @intCast(idx)) == 0) continue;
        const pmeta = try packMeta(io, idx);
        for (pmeta.import_prefixes) |imp| {
            for (meta.pkgs) |pkg| {
                if (matchesImportPrefix(scratch, imp, pkg)) return true;
            }
        }
    }
    return false;
}

/// Get or build the dependency snapshot for (mode, pack mask, gate).
/// Returns null when that base is not snapshot-safe.
fn getOrBuildBase(io: Io, mode: LoadMode, mask: PackMask, full: bool) Allocator.Error!?*const BaseEntry {
    base_lock.lock();
    defer base_lock.unlock();
    // A cached base outlives every program: its permanent cells must NOT
    // land on the program-perm list of whichever program happened to build
    // it first.
    const saved_ppc = runtime.gc.program_perm_collect;
    runtime.gc.program_perm_collect = false;
    defer runtime.gc.program_perm_collect = saved_ppc;

    if (base_entries == null) base_entries = std.AutoHashMap(u64, CachedBase).init(std.heap.page_allocator);
    const key = baseKey(mode, mask, full);
    if (base_entries.?.getPtr(key)) |hit| {
        base_tick += 1;
        hit.tick = base_tick;
        return hit.entry;
    }

    // Evict down BEFORE the build, not after the insert: a full-source base
    // build is the process's RSS spike, and stacking it on top of a full
    // cache put peak-RSS at (cap + 1) bases plus the build transient —
    // exactly what trips the watchdog on the capped harnesses. Making room
    // first bounds coexistence at the cap itself.
    if (base_cache_max > 0) evictBasesToAtMost(base_cache_max - 1);
    // Ride the build transient on a trimmed floor.
    if (@import("builtin").os.tag == .linux) _ = malloc_trim(0);
    // Build each base in its own arena so eviction can hand its pages back.
    const holder = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    holder.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const entry = buildBaseEntry(holder.allocator(), io, mode, mask, full) catch |e| {
        runtime.gc.drainRemembered();
        holder.deinit();
        std.heap.page_allocator.destroy(holder);
        return e;
    };
    base_tick += 1;
    if (entry == null) {
        // Not snapshot-safe: keep no arena, just remember the miss.
        runtime.gc.drainRemembered();
        holder.deinit();
        std.heap.page_allocator.destroy(holder);
        try base_entries.?.put(key, .{ .entry = null, .arena = null, .tick = base_tick });
        return null;
    }
    try base_entries.?.put(key, .{ .entry = entry, .arena = holder, .tick = base_tick });
    evictBasesBeyondCap();
    return entry;
}

/// Drop least-recently-used real bases until at most `base_cache_max` remain
/// (no-op when the cap is 0). Only arena-owning entries count and are evicted;
/// null placeholders are free and kept.
fn evictBasesBeyondCap() void {
    if (base_cache_max == 0) return;
    evictBasesToAtMost(base_cache_max);
}

/// Drop least-recently-used real bases until at most `limit` remain.
fn evictBasesToAtMost(limit: usize) void {
    while (true) {
        var owning: usize = 0;
        var lru_key: u64 = 0;
        var lru_tick: u64 = std.math.maxInt(u64);
        var it = base_entries.?.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.arena == null) continue;
            owning += 1;
            if (kv.value_ptr.tick < lru_tick) {
                lru_tick = kv.value_ptr.tick;
                lru_key = kv.key_ptr.*;
            }
        }
        if (owning <= limit) return;
        const removed = base_entries.?.fetchRemove(lru_key).?;
        const arena = removed.value.arena.?;
        // The evicted base's cells may sit in the GC's remembered set (they
        // were patched by past programs); drain while they are still mapped,
        // or a later collection clears flags through unmapped pages. Safe to
        // drain wholesale here: eviction runs during base resolution, before
        // any nursery cell exists, so no old-to-young edge can be lost.
        runtime.gc.drainRemembered();
        arena.deinit();
        std.heap.page_allocator.destroy(arena);
    }
}

fn buildBaseEntry(a: Allocator, io: Io, mode: LoadMode, mask: PackMask, full: bool) Allocator.Error!?*const BaseEntry {
    if (try loadBakedBase(a, io, mode, mask, full)) |entry| return entry;
    return buildBaseEntryFromSource(a, io, mode, mask, full);
}

/// Load a build-time-baked dependency base for this key. The build graph
/// owns freshness: the generator re-runs whenever the stdlib sources or the
/// interpreter modules change, and each test run step's cache manifest
/// covers the image bytes. Only the EmbeddedOnly bases are baked; other
/// keys — and any read/decode failure — take the source build below.
fn loadBakedBase(a: Allocator, io: Io, mode: LoadMode, mask: PackMask, full: bool) Allocator.Error!?*const BaseEntry {
    if (mode != .EmbeddedOnly or mask != 0) return null;
    const dir = (runtime.procEnvGetVar(a, "KLIO_PARITY_BASE_IMAGES") catch null) orelse return null;
    const path = try std.fmt.allocPrint(a, "{s}/embedded-gate{d}.klio-image", .{ dir, @intFromBool(full) });
    const bytes = readFileOpt(a, io, path) orelse return null;
    const loaded = (try interp_ir.image.load(a, bytes)) orelse return null;
    for (loaded.known_packages) |pkg| stdlib.registerKnownPackage(pkg);
    const entry = try a.create(BaseEntry);
    entry.* = .{ .base = loaded.base, .map = loaded.map, .patch_allocator = a };
    return entry;
}

/// Build the EmbeddedOnly dependency base for one stdlib-gate variant and
/// bake it to image bytes. Null when the base is not snapshot-safe or holds
/// state outside the serializable surface. Entry point for the build-time
/// generator; always builds from source (never round-trips a prior image).
pub fn bakeEmbeddedBase(allocator: Allocator, io: Io, full: bool) Allocator.Error!?[]u8 {
    const entry = (try buildBaseEntryFromSource(allocator, io, .EmbeddedOnly, 0, full)) orelse return null;
    return try interp_ir.image.bake(allocator, entry.base, entry.map, .{});
}

fn buildBaseEntryFromSource(a: Allocator, io: Io, mode: LoadMode, mask: PackMask, full: bool) Allocator.Error!?*const BaseEntry {
    const map = try a.create(SourceMap);
    map.* = SourceMap.init(a);

    var asts: std.ArrayList(KotlinFile) = .empty;
    defer asts.deinit(a);

    if (mode != .EmbeddedOnly and mask != 0) {
        const pack_dirs = try kotlinxPackDirs(a);
        var sources: std.ArrayList(PackSource) = .empty;
        defer sources.deinit(a);
        for (pack_dirs, 0..) |dir, idx| {
            if (mask & (@as(PackMask, 1) << @intCast(idx)) == 0) continue;
            const manifest_sources = switch (try collectManifestSources(a, io, dir)) {
                .err => return null,
                .ok => |s| s,
            };
            for (manifest_sources) |src_path| {
                const text = readFileOpt(a, io, src_path) orelse return null;
                try sources.append(a, .{ .path = src_path, .text = text });
            }
        }
        switch (mode) {
            .SourcePacks => {
                for (sources.items) |s| {
                    const file_ast = switch (try parsePackFile(a, map, s.path, s.text)) {
                        .err => return null,
                        .ok => |f| f,
                    };
                    try registerAstPackage(a, &file_ast);
                    try asts.append(a, file_ast);
                }
            },
            .CompiledPacks => {
                const decoded = switch (try packRoundtrip(a, sources.items)) {
                    .err => return null,
                    .ok => |d| d,
                };
                for (decoded) |sf| {
                    const file_ast = switch (try parsePackFile(a, map, sf.rel_path, sf.bytes)) {
                        .err => return null,
                        .ok => |f| f,
                    };
                    try registerAstPackage(a, &file_ast);
                    try asts.append(a, file_ast);
                }
            },
            .EmbeddedOnly => unreachable,
        }
    }

    // Synthetic prefix set reproducing the gate: the selected stdlib subset
    // is a pure function of the gate boolean, so the snapshot is identical
    // for every program that maps to this key.
    var gate_prefixes = std.StringHashMap(void).init(a);
    if (full) {
        const meta = try stdlibMeta(io);
        for (meta.pkgs) |pkg| try gate_prefixes.put(pkg, {});
    }
    const stdlib_asts = try embeddedStdlibSourcesPrefixed(a, io, &gate_prefixes, map);
    for (stdlib_asts) |s| {
        if (mode != .EmbeddedOnly) try registerAstPackage(a, &s);
        try asts.append(a, s);
    }

    span.active_map = map;
    defer span.active_map = null;
    const base = (try interp_ir.build.buildStdlibBase(a, asts.items)) orelse return null;
    base.user_file_start = @intCast(map.files.items.len);

    const entry = try a.create(BaseEntry);
    entry.* = .{ .base = base, .map = map, .patch_allocator = a };
    return entry;
}

/// Program assembled on the fast path: the extended module plus the map
/// and bindings the shared tail consumes.
const PreparedProgram = struct {
    built: interp_ir.build.BuiltModule,
    map: *const SourceMap,
    bindings: ?HostBindings,
    patch_allocator: ?Allocator = null,
};

/// Try to assemble `files` against the shared dependency base. Returns
/// null when the program must take the whole-program fallback; `.err` when
/// the program itself is invalid (unreadable/unparseable), matching the
/// fallback's failure text.
fn prepareWithBase(arena: Allocator, io: Io, files: []const []const u8, mode: LoadMode) Allocator.Error!?SResult(PreparedProgram) {
    // First parse on a scratch map: the reuse gate and the base key need
    // the user program's decls and imports before the base is chosen.
    var scratch_map = SourceMap.init(arena);
    var texts = try arena.alloc([]const u8, files.len);
    var scratch_asts = try arena.alloc(KotlinFile, files.len);
    for (files, 0..) |file, i| {
        const text = readFileOpt(arena, io, file) orelse {
            return .{ .err = try std.fmt.allocPrint(arena, "read {s}", .{file}) };
        };
        texts[i] = text;
        scratch_asts[i] = switch (try parsePackFile(arena, &scratch_map, file, text)) {
            .err => |e| return .{ .err = e },
            .ok => |f| f,
        };
    }

    var prefixes = std.StringHashMap(void).init(arena);
    for (scratch_asts) |*f| try collectImportPrefixes(arena, f, &prefixes);
    for (texts) |t| try collectQualifiedPrefixes(arena, t, &prefixes);
    var imports_coroutines = false;
    {
        var it = prefixes.keyIterator();
        while (it.next()) |imp_ptr| {
            const imp = imp_ptr.*;
            if (std.mem.eql(u8, imp, "kotlinx.coroutines") or
                std.mem.startsWith(u8, imp, "kotlinx.coroutines."))
            {
                imports_coroutines = true;
                break;
            }
        }
    }

    base_lock.lock();
    const mask: PackMask = if (mode == .EmbeddedOnly) 0 else packMaskFor(io, &prefixes, imports_coroutines, arena) catch |e| {
        base_lock.unlock();
        return e;
    };
    const full = stdlibGateFull(io, &prefixes, mask, arena) catch |e| {
        base_lock.unlock();
        return e;
    };
    base_lock.unlock();

    const entry = (try getOrBuildBase(io, mode, mask, full)) orelse return null;
    if (!interp_ir.build.canExtendBase(entry.base, scratch_asts)) return null;

    // Re-parse the user files onto a map that extends the base's, so user
    // FileIds continue after the base's and base spans stay resolvable.
    const map = try arena.create(SourceMap);
    map.* = SourceMap.init(arena);
    try map.files.appendSlice(map.arena.allocator(), entry.map.files.items);
    var user_asts = try arena.alloc(KotlinFile, files.len);
    for (files, 0..) |file, i| {
        user_asts[i] = switch (try parsePackFile(arena, map, file, texts[i])) {
            .err => |e| return .{ .err = e },
            .ok => |f| f,
        };
    }

    // Lowering reads source text through the active map (the serialization
    // pass copies default values and annotation arguments verbatim), so the
    // map is installed before the build, not only for the VM run.
    span.active_map = map;
    const built = try interp_ir.build.buildModuleFilesExtend(arena, entry.base, user_asts);
    const bindings: ?HostBindings = if (mode == .EmbeddedOnly) null else try packHostBindings(arena);
    return .{ .ok = .{
        .built = built,
        .map = map,
        .bindings = bindings,
        .patch_allocator = entry.patch_allocator,
    } };
}

/// Assemble `file` under `mode`, build the module, and run `main`, returning
/// captured stdout (ok) or an error message (err), owned by `allocator`. The
/// single tail shared by all three load configurations.
pub fn runInMode(allocator: Allocator, io: Io, file: []const u8, mode: LoadMode) Allocator.Error!SResult([]u8) {
    return runFilesInMode(allocator, io, &.{file}, mode);
}

/// Multi-file `runInMode`.
pub fn runFilesInMode(allocator: Allocator, io: Io, files: []const []const u8, mode: LoadMode) Allocator.Error!SResult([]u8) {
    // In-process run path shared by e2e / itests / differential / fuzzer:
    // cap RSS and arm the opt-in deadline so a runaway program can't OOM or
    // hang the harness process. Call-once.
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    // Per-run diagnostic state: the lenient-bind warning prints once per
    // function per PROGRAM, and the memo is process-global.
    interp_ir.resetLenientWarned();

    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Match the production `safe` profile for execution: compiler/lowering
    // data remains phase-scoped in the arena, while runtime cells use the
    // tracing collector's page-returning slab allocator. `off` deliberately
    // retains the arena path as the diagnostic no-GC profile.
    const gc_run = runtime.perf.get().reclaim == .gc;
    const prev_gc_enabled = runtime.gc.gc_enabled;
    const prev_program_started = runtime.gc.program_started;
    const prev_alloc_perm = runtime.gc.alloc_perm;
    const prev_release_to_os = runtime.gc.release_to_os;
    const prev_gc_stress = runtime.gc.gc_stress;
    const prev_gc_poison = runtime.gc.gc_poison;
    const prev_external_accounting = runtime.gc.external_accounting;
    if (gc_run) {
        runtime.gc.gc_enabled = true;
        runtime.gc.program_started = false;
        runtime.gc.alloc_perm = true;
        runtime.gc.release_to_os = runtime.slab.reclaimDormant;
        if (runtime.envOnce("KLIO_GC_DEBUG")) |v| runtime.gc.gc_debug = v.len != 0 and !std.mem.eql(u8, v, "0");
        if (runtime.envOnce("KLIO_GC_HIST")) |v| runtime.gc.gc_hist = v.len != 0 and !std.mem.eql(u8, v, "0");
        if (runtime.envOnce("KLIO_GC_STRESS")) |v| runtime.gc.gc_stress = v.len != 0 and !std.mem.eql(u8, v, "0");
        // Program-perm window: permanent cells minted while THIS program
        // builds and runs belong to the program, and the boundary frees
        // them (`freeProgramPerm`). Shared mints are excluded surgically:
        // `getOrBuildBase` masks the flag around the cached-base build.
        runtime.gc.program_perm_collect = true;
        // The mmap-site tracer normally arms in `main`; the in-process
        // harness needs the same diagnosis surface for its multi-program
        // RSS profile (`kill -TERM` dumps the top live sites).
        if (runtime.envOnce("KLIO_SLAB_TRACE") != null and !runtime.slab.trace_enabled) {
            runtime.slab.trace_enabled = true;
            runtime.slab.trace_all = runtime.envOnce("KLIO_SLAB_TRACE_ALL") != null;
            runtime.slab.installTraceSignalDump();
        }
        if (runtime.envOnce("KLIO_GC_POISON")) |v| runtime.gc.gc_poison = v.len != 0 and !std.mem.eql(u8, v, "0");
        if (runtime.envOnce("KLIO_GC_EXT")) |v| runtime.gc.external_accounting = v.len != 0 and !std.mem.eql(u8, v, "0");
    }
    defer {
        // Every path out of a program — including a diagnostic failure that
        // never constructed a Vm — releases `arena_inst` next; remembered
        // entries pointing into it must not survive that, and the program's
        // permanent cells go with it (the Vm teardown already freed them on
        // the success path; this covers the diag/error exits).
        // The write barrier records cells whatever the reclaim mode, so the
        // remembered set is drained on every path out (an undrained set left
        // entries into this arena for the next program's base eviction to
        // write through, a SIGSEGV once the pages were returned to the OS).
        runtime.gc.drainRemembered();
        if (gc_run) {
            runtime.gc.program_perm_collect = false;
            runtime.gc.freeProgramPerm();
        }
        runtime.gc.external_accounting = prev_external_accounting;
        runtime.gc.gc_poison = prev_gc_poison;
        runtime.gc.gc_stress = prev_gc_stress;
        runtime.gc.release_to_os = prev_release_to_os;
        runtime.gc.alloc_perm = prev_alloc_perm;
        runtime.gc.program_started = prev_program_started;
        runtime.gc.gc_enabled = prev_gc_enabled;
    }

    // Arena-backed run: every cell allocates from `arena_inst`, which frees
    // en masse on `deinit` above, so per-cell `ObjRef.deinit` teardown is
    // wasted work. Switch this thread to the reclaim fast path for the run
    // and restore the prior mode after (the harness runs many programs on
    // one thread, and other tests on it leak-check on `testing.allocator`).
    const prev_reclaim = runtime.reclaimEnabled();
    runtime.setReclaim(false);
    defer runtime.setReclaim(prev_reclaim);

    // Catch any receiver/coroutine thread-local state leaked from a prior run
    // on this thread before assembling the next program.
    interp_ir.resetReceiverThreadLocals();
    interp_ir.resetRunGlobalCaches();
    // Drop the previous program's JIT state: the per-program arena is about to be
    // recycled, so a reused `*Func` address must not inherit stale native code.
    interp_ir.resetJitForTest();

    interp_ir.setCoroutineTimeMode(.Virtual);

    // Fast path: extend the once-per-process dependency base with just this
    // program's decls. Falls back to the whole-program build when the
    // program redeclares a base name (or the base is not snapshot-safe).
    var built: interp_ir.build.BuiltModule = undefined;
    defer span.active_map = null;
    var prog_map: *const SourceMap = undefined;
    var prog_bindings: ?HostBindings = null;
    var prog_patch_alloc: ?Allocator = null;
    var used_base = false;
    if (try prepareWithBase(arena, io, files, mode)) |r| switch (r) {
        .err => |e| return .{ .err = try allocator.dupe(u8, e) },
        .ok => |p| {
            built = p.built;
            prog_map = p.map;
            prog_bindings = p.bindings;
            prog_patch_alloc = p.patch_allocator;
            used_base = true;
        },
    };
    if (!used_base) {
        const loaded = switch (try loadProgramFiles(arena, io, files, mode)) {
            .err => |e| return .{ .err = try allocator.dupe(u8, e) },
            .ok => |p| p,
        };
        span.active_map = loaded.map;
        built = try interp_ir.build.buildModuleFiles(arena, loaded.asts);
        prog_map = loaded.map;
        prog_bindings = loaded.bindings;
    }
    if (traceBaseEnabled()) {
        printErr("[stdlib-base] {s}: {s}\n", .{ if (used_base) "fast" else "fallback", files[0] });
    }
    // Lowering-time resolution diagnostics (ambiguous bare calls) fail
    // the program before it runs, mirroring the `klio run` pipeline.
    const amb_msg: ?[]u8 = blk: {
        const mg = built.module.borrow();
        defer mg.deinit();
        const rdiags = mg.get().resolve_diags.items;
        if (rdiags.len == 0) break :blk null;
        break :blk try rdiags[0].render(allocator, prog_map);
    };
    if (amb_msg) |msg| {
        built.deinit();
        return .{ .err = msg };
    }
    const main_id = built.main orelse {
        built.deinit();
        return .{ .err = try allocator.dupe(u8, "no main function in module") };
    };
    // VM-structural cells (the class graph, globals table, closure spine,
    // output sink) must be PERMANENT: `gcMarkAllVms` deliberately does not
    // shade the closure spine (a strong root there leaked every capture), and
    // it never shades the output sink at all — a nursery-minted spine or sink
    // is swept by the first mid-run major and every later borrow reads freed
    // memory. `vmRun` closes the permanent generation itself right before the
    // program body, exactly like the CLI path.
    const vm_allocator = if (gc_run) runtime.slab.allocator else arena;
    const pair = try interp_ir.Vm.fromBuilt(vm_allocator, &built);
    built.deinit();
    var vm = pair.vm;
    // A base-backed program patches the SHARED cached instances, so its
    // values must live with the cache entry; a whole-program fallback owns
    // its instances outright, and the run arena (which outlives the Vm) is
    // the allocator its field lists were built from.
    vm.patch_allocator = prog_patch_alloc orelse arena;
    defer {
        if (gc_run) interp_ir.resetRunGlobalCaches();
        // Before the VM frees its permanent cells: the remembered set may
        // hold pointers into them (whatever the reclaim mode), and a later
        // drain would otherwise clear flags through freed (possibly
        // unmapped) memory.
        runtime.gc.drainRemembered();
        vm.deinit();
        if (gc_run) {
            // The final collect runs with the program's closure/suspend hooks
            // STILL INSTALLED: they are the only path that frees closure
            // metadata (capture-name/chain arrays) and parked suspension
            // snapshots, and clearing them first leaked every program's
            // worth. The hooks' backing (the Vm's closure spine) is a
            // program-perm cell — alive until `freeProgramPerm` below.
            runtime.gc.collect();
            // NOW nothing from the finished program may remain rooted while
            // its compiler arena is about to be released.
            interp_ir.gcResetProgramHooks();
            // The finished program's build-phase permanent cells (its own VM
            // class/global graph) — the Vm is already out of the root set and
            // the remembered set was drained while these were still mapped.
            runtime.gc.freeProgramPerm();
            // The collect's own trim is rate-limited (32MB of sweep credit);
            // a program boundary is exactly when dormant slab pages should
            // go back regardless, so hundreds of small programs in one
            // process do not ratchet the slab high-water into the RSS cap.
            // Repeated passes step the per-slab idle hysteresis so pages the
            // finished program just vacated actually decommit now.
            var trim_pass: usize = 0;
            while (trim_pass < 4) : (trim_pass += 1) runtime.slab.reclaimDormant();
            // Frame register buffers live on glibc malloc (`regsAlloc`),
            // which hoards freed memory per-thread-arena indefinitely; a
            // multi-program process must hand it back or the high-water
            // ratchets into the RSS cap.
            if (@import("builtin").os.tag == .linux) _ = malloc_trim(0);
            runtime.gc.program_started = false;
            runtime.gc.alloc_perm = true;
        }
    }
    if (prog_bindings) |bindings| try vm.setInstalledBindings(bindings);

    var out = CaptureOutput.init(allocator);
    defer out.deinit();
    // Make the source map reachable from inside the VM so a thrown exception's
    // captured frames resolve to file paths + lines (same as the CLI run path).
    span.active_map = prog_map;
    defer span.active_map = null;
    const result = runMainBigStack(&vm, main_id, out.output());
    switch (result) {
        .ok => {},
        .err => |e| return .{ .err = try formatVmError(allocator, e) },
    }
    return .{ .ok = try out.intoJoined(allocator) };
}

/// Run `main` on a large-stack worker thread so deep legitimate recursion
/// runs to completion rather than overflowing the harness's main stack. The
/// coroutine time mode is thread-local, so it is re-established on the worker.
const MainRunCtx = struct {
    vm: *interp_ir.Vm,
    main: interp_ir.FuncId,
    out: interp_ir.Output,
    time_mode: interp_ir.TimeMode,
    reclaim: bool,
};

fn runMainBigStack(vm: *interp_ir.Vm, main_id: interp_ir.FuncId, out: interp_ir.Output) interp_ir.VmResult {
    const ctx = MainRunCtx{
        .vm = vm,
        .main = main_id,
        .out = out,
        .time_mode = interp_ir.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
    };
    return runtime.runOnBigStack(MainRunCtx, interp_ir.VmResult, runMainEntry, ctx);
}

/// Per-program wall cap (ms) for the in-process itest harnesses: a spinning
/// program then fails "test wall-clock deadline exceeded" and names itself
/// instead of hanging the binary for minutes. Default 60s (a legit in-process
/// program runs in seconds); `KLIO_ITEST_WALL_CAP` overrides (seconds; 0 = off).
fn itestWallCapMs() i64 {
    const s = runtime.envOnce("KLIO_ITEST_WALL_CAP") orelse return 60_000;
    const secs = std.fmt.parseInt(i64, s, 10) catch return 60_000;
    return if (secs <= 0) 0 else secs * 1000;
}

fn runMainEntry(ctx: MainRunCtx) interp_ir.VmResult {
    interp_ir.setCoroutineTimeMode(ctx.time_mode);
    runtime.setReclaim(ctx.reclaim);
    interp_ir.armTestWallDeadlineMs(itestWallCapMs());
    defer interp_ir.clearTestWallDeadline();
    return ctx.vm.run(ctx.main, ctx.out) catch return .{ .err = .{ .Eval = "out of memory" } };
}

/// Run a `.kt` file directly through the `klio` interpreter library, returning
/// captured stdout (ok) or an error message (err), owned by `allocator`.
/// Embedded stdlib only — the configuration `check`'s kotlinc oracle compares
/// against.
pub fn runWithKtc(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!SResult([]u8) {
    return runInMode(allocator, io, file, .EmbeddedOnly);
}

// ---------------------- klio.toml manifest parsing ----------------------

const ManifestRoot = struct {
    root: []const u8,
    include: [][]const u8,
    exclude: [][]const u8,
};

fn manifestPatMatch(rel: []const u8, pat: []const u8) bool {
    if (std.mem.endsWith(u8, pat, "/")) {
        const prefix = pat[0 .. pat.len - 1];
        return std.mem.eql(u8, rel, prefix) or std.mem.startsWith(u8, rel, pat);
    }
    if (std.mem.startsWith(u8, pat, "*")) {
        return std.mem.endsWith(u8, rel, pat[1..]);
    }
    if (std.mem.endsWith(u8, pat, "*")) {
        return std.mem.startsWith(u8, rel, pat[0 .. pat.len - 1]);
    }
    return std.mem.eql(u8, rel, pat);
}

fn stringArray(allocator: Allocator, rest: []const u8) Allocator.Error![][]const u8 {
    var trimmed = std.mem.trim(u8, rest, " \t\r\n");
    trimmed = std.mem.trimStart(u8, trimmed, "[");
    trimmed = std.mem.trimEnd(u8, trimmed, "]");
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |s| {
        const t = std.mem.trim(u8, std.mem.trim(u8, s, " \t\r\n"), "\"");
        if (t.len != 0) try out.append(allocator, try allocator.dupe(u8, t));
    }
    return out.toOwnedSlice(allocator);
}

/// Minimal `klio.toml` reader for `source_roots` + `[[source]]` tables.
fn parseManifestRoots(allocator: Allocator, toml: []const u8) Allocator.Error![]ManifestRoot {
    var logical: std.ArrayList([]u8) = .empty;
    defer {
        for (logical.items) |l| allocator.free(l);
        logical.deinit(allocator);
    }
    var pending: ?std.ArrayList(u8) = null;
    var lines_it = std.mem.splitScalar(u8, toml, '\n');
    while (lines_it.next()) |raw| {
        const before_hash = std.mem.sliceTo(raw, '#');
        const line = std.mem.trim(u8, before_hash, " \t\r\n");
        if (pending) |*buf| {
            try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, line);
            if (std.mem.indexOfScalar(u8, line, ']') != null) {
                try logical.append(allocator, try buf.toOwnedSlice(allocator));
                pending = null;
            }
            continue;
        }
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '[') != null and
            std.mem.indexOfScalar(u8, line, ']') == null and
            std.mem.indexOfScalar(u8, line, '=') != null)
        {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(allocator, line);
            pending = buf;
            continue;
        }
        try logical.append(allocator, try allocator.dupe(u8, line));
    }
    if (pending) |*buf| {
        try logical.append(allocator, try buf.toOwnedSlice(allocator));
    }

    var plain: [][]const u8 = &.{};
    var tables: std.ArrayList(ManifestRoot) = .empty;
    errdefer tables.deinit(allocator);
    var cur: ?ManifestRoot = null;
    var in_source_table = false;
    for (logical.items) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[[source]]")) {
            if (cur) |c| try tables.append(allocator, c);
            cur = ManifestRoot{ .root = try allocator.alloc(u8, 0), .include = &.{}, .exclude = &.{} };
            in_source_table = true;
            continue;
        }
        if (line.len != 0 and line[0] == '[') {
            if (cur) |c| try tables.append(allocator, c);
            cur = null;
            in_source_table = false;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r\n");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r\n");
        if (in_source_table) {
            if (cur) |*c| {
                if (std.mem.eql(u8, key, "root")) {
                    allocator.free(c.root);
                    c.root = try allocator.dupe(u8, std.mem.trim(u8, val, "\""));
                } else if (std.mem.eql(u8, key, "include")) {
                    c.include = try stringArray(allocator, val);
                } else if (std.mem.eql(u8, key, "exclude")) {
                    c.exclude = try stringArray(allocator, val);
                }
            }
        } else if (std.mem.eql(u8, key, "source_roots")) {
            plain = try stringArray(allocator, val);
        }
    }
    if (cur) |c| try tables.append(allocator, c);

    var out: std.ArrayList(ManifestRoot) = .empty;
    errdefer out.deinit(allocator);
    for (plain) |root| {
        try out.append(allocator, .{ .root = root, .include = &.{}, .exclude = &.{} });
    }
    allocator.free(plain);
    try out.appendSlice(allocator, tables.items);
    tables.deinit(allocator);
    return out.toOwnedSlice(allocator);
}

fn freeManifestRoots(allocator: Allocator, roots: []ManifestRoot) void {
    for (roots) |r| {
        allocator.free(r.root);
        for (r.include) |s| allocator.free(s);
        if (r.include.len != 0) allocator.free(r.include);
        for (r.exclude) |s| allocator.free(s);
        if (r.exclude.len != 0) allocator.free(r.exclude);
    }
    allocator.free(roots);
}

const RelAbs = struct { rel: []u8, abs: []u8 };

fn walkKt(allocator: Allocator, io: Io, dir: []const u8, base: []const u8, out: *std.ArrayList(RelAbs)) Allocator.Error!void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            try names.append(allocator, try std.fs.path.join(allocator, &.{ dir, entry.name }));
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (names.items) |p| {
        if (isDir(io, p)) {
            try walkKt(allocator, io, p, base, out);
        } else if (std.mem.endsWith(u8, p, ".kt")) {
            const stripped = if (std.mem.startsWith(u8, p, base) and p.len > base.len)
                p[base.len + 1 ..]
            else
                p;
            const rel = try allocator.dupe(u8, stripped);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            try out.append(allocator, .{ .rel = rel, .abs = try allocator.dupe(u8, p) });
        }
    }
}

fn anyMatch(rel: []const u8, pats: [][]const u8) bool {
    for (pats) |pat| {
        if (manifestPatMatch(rel, pat)) return true;
    }
    return false;
}

/// Collect a pack's Kotlin sources from its `klio.toml`. Returns owned absolute
/// paths sorted by root-relative path, deduplicated.
fn collectManifestSources(allocator: Allocator, io: Io, pack_dir: []const u8) Allocator.Error!SResult([][]u8) {
    const toml_path = try std.fs.path.join(allocator, &.{ pack_dir, "klio.toml" });
    defer allocator.free(toml_path);
    const toml = readFileOpt(allocator, io, toml_path) orelse {
        return .{ .err = try std.fmt.allocPrint(allocator, "read {s}", .{toml_path}) };
    };
    defer allocator.free(toml);
    const roots = try parseManifestRoots(allocator, toml);
    defer freeManifestRoots(allocator, roots);
    var default_root_buf: [1]ManifestRoot = undefined;
    var roots_view: []ManifestRoot = roots;
    if (roots.len == 0) {
        default_root_buf[0] = .{ .root = "src", .include = &.{}, .exclude = &.{} };
        roots_view = default_root_buf[0..1];
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var ki = seen.keyIterator();
        while (ki.next()) |k| allocator.free(k.*);
        seen.deinit();
    }
    const Picked = struct { rel: []u8, abs: []const u8 };
    var picked: std.ArrayList(Picked) = .empty;
    defer {
        for (picked.items) |pk| allocator.free(pk.rel);
        picked.deinit(allocator);
    }

    for (roots_view) |r| {
        const root_path = try std.fs.path.join(allocator, &.{ pack_dir, r.root });
        defer allocator.free(root_path);
        if (!isDir(io, root_path)) continue;
        var found: std.ArrayList(RelAbs) = .empty;
        defer {
            for (found.items) |f| {
                allocator.free(f.rel);
                allocator.free(f.abs);
            }
            found.deinit(allocator);
        }
        try walkKt(allocator, io, root_path, root_path, &found);
        for (found.items) |f| {
            const included = r.include.len == 0 or anyMatch(f.rel, r.include);
            if (!included) continue;
            if (anyMatch(f.rel, r.exclude)) continue;
            const gop = try seen.getOrPut(f.abs);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, f.abs);
                try picked.append(allocator, .{ .rel = try allocator.dupe(u8, f.rel), .abs = gop.key_ptr.* });
            }
        }
    }
    std.mem.sort(Picked, picked.items, {}, struct {
        fn lt(_: void, a: Picked, b: Picked) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lt);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |o| allocator.free(o);
        out.deinit(allocator);
    }
    for (picked.items) |pk| {
        try out.append(allocator, try allocator.dupe(u8, pk.abs));
    }
    return .{ .ok = try out.toOwnedSlice(allocator) };
}

fn parsePackFile(arena: Allocator, map: *SourceMap, path: []const u8, text: []const u8) Allocator.Error!SResult(KotlinFile) {
    const id = try map.add(path, text);
    const srcf = map.get(id).source;
    var lx = try lexer.Lexer.init(arena, id, srcf);
    const lexed = try lx.tokenize();
    if (lexed.diagnostics.hasErrors()) {
        return .{ .err = try std.fmt.allocPrint(arena, "lex: {d} error(s)", .{lexed.diagnostics.diags().len}) };
    }
    const p = parser.Parser.new(arena, id, srcf, lexed.tokens);
    const file_ast = p.parseFile();
    if (p.diagnostics.hasErrors()) {
        return .{ .err = try std.fmt.allocPrint(arena, "parse: {d} error(s)", .{p.diagnostics.diags().len}) };
    }
    return .{ .ok = file_ast };
}

fn manifestLibraryId(allocator: Allocator, io: Io, pack_dir: []const u8) Allocator.Error!?[]u8 {
    const toml_path = try std.fs.path.join(allocator, &.{ pack_dir, "klio.toml" });
    defer allocator.free(toml_path);
    const toml = readFileOpt(allocator, io, toml_path) orelse return null;
    defer allocator.free(toml);
    var it = std.mem.splitScalar(u8, toml, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, std.mem.sliceTo(line, '#'), " \t\r\n");
        if (std.mem.startsWith(u8, l, "id")) {
            const rest = std.mem.trimStart(u8, l[2..], " =");
            const v = std.mem.trim(u8, std.mem.trim(u8, rest, " \t\r\n"), "\"");
            if (v.len != 0) return try allocator.dupe(u8, v);
        }
    }
    return null;
}

fn registerAstPackage(arena: Allocator, file_ast: *const KotlinFile) Allocator.Error!void {
    if (file_ast.package) |pkg| {
        const path = try joinIdentPath(arena, pkg.path);
        if (path.len != 0) stdlib.registerKnownPackage(path);
    }
}

/// Run a `.kt` file through the `klio` interpreter with the in-repo kotlinx
/// packs (coroutines, atomicfu, io) loaded from source and their host bindings
/// installed.
pub fn runWithPacks(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!SResult([]u8) {
    // `runInMode` runs `main` on a 64 MiB worker stack, so deep recursion has
    // headroom.
    return runInMode(allocator, io, file, .SourcePacks);
}

/// Multi-file variant of `runWithPacks` — the in-process mirror of
/// `klio run a.kt b.kt`, for itests exercising cross-package shapes.
pub fn runFilesWithPacks(allocator: Allocator, io: Io, files: []const []const u8) Allocator.Error!SResult([]u8) {
    return runFilesInMode(allocator, io, files, .SourcePacks);
}

// ---------------------- staging helpers ----------------------

const RESERVED = [_][]const u8{
    "as",        "break",     "class",        "continue",  "do",       "else",
    "false",     "for",       "fun",          "if",        "in",       "interface",
    "is",        "null",      "object",       "package",   "return",   "super",
    "this",      "throw",     "true",         "try",       "typealias", "typeof",
    "val",       "var",       "when",         "while",     "abstract", "assert",
    "boolean",   "byte",      "case",         "catch",     "char",     "const",
    "default",   "double",    "enum",         "extends",   "final",    "finally",
    "float",     "goto",      "implements",   "import",    "instanceof", "int",
    "long",      "native",    "new",          "private",   "protected", "public",
    "short",     "static",    "strictfp",     "switch",    "synchronized", "throws",
    "transient", "void",      "volatile",
};

fn sanitizePkgSegment(allocator: Allocator, stem: []const u8) Allocator.Error![]u8 {
    for (RESERVED) |w| {
        if (std.mem.eql(u8, stem, w)) {
            return std.fmt.allocPrint(allocator, "{s}_", .{stem});
        }
    }
    return allocator.dupe(u8, stem);
}

fn capitalizeFirst(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    if (s.len == 0) return allocator.alloc(u8, 0);
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out, s);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

const VALUE_CLASS_MODIFIERS = [_][]const u8{
    "public ",     "private ",   "internal ",  "protected ", "expect ", "actual ",
    "external ",   "open ",      "final ",     "abstract ",  "sealed ", "data ",
    "enum ",       "annotation ", "companion ", "inner ",    "inline ",
};

fn declaresValueClass(line: []const u8) bool {
    var rest = std.mem.trimStart(u8, line, " \t\r\n");
    while (true) {
        if (rest.len != 0 and rest[0] == '@') {
            const after_at = rest[1..];
            var end: usize = after_at.len;
            for (after_at, 0..) |c, i| {
                if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '(') {
                    end = i;
                    break;
                }
            }
            var tail = after_at[end..];
            if (tail.len != 0 and tail[0] == '(') {
                var depth: i32 = 0;
                var i: usize = 0;
                while (i < tail.len) : (i += 1) {
                    switch (tail[i]) {
                        '(' => depth += 1,
                        ')' => {
                            depth -= 1;
                            if (depth == 0) {
                                i += 1;
                                break;
                            }
                        },
                        else => {},
                    }
                }
                tail = tail[i..];
            }
            rest = std.mem.trimStart(u8, tail, " \t\r\n");
            continue;
        }
        var advanced: ?[]const u8 = null;
        for (VALUE_CLASS_MODIFIERS) |m| {
            if (std.mem.startsWith(u8, rest, m)) {
                advanced = std.mem.trimStart(u8, rest[m.len..], " \t\r\n");
                break;
            }
        }
        if (advanced) |next| {
            rest = next;
        } else break;
    }
    return std.mem.startsWith(u8, rest, "value class ") or std.mem.startsWith(u8, rest, "value class\t");
}

/// Inject `@JvmInline` before a `value class` declaration that lacks one.
fn injectJvmInline(allocator: Allocator, src: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var prev_had_jvminline = false;
    var idx: usize = 0;
    while (idx < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, idx, '\n');
        const line_end = if (nl) |n| n + 1 else src.len;
        const line = src[idx..line_end];
        idx = line_end;

        if (declaresValueClass(line) and !prev_had_jvminline) {
            const trimmed = std.mem.trimStart(u8, line, " \t\r\n");
            const indent = line[0 .. line.len - trimmed.len];
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "@JvmInline\n");
        }
        try out.appendSlice(allocator, line);
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len != 0) {
            prev_had_jvminline = std.mem.startsWith(u8, t, "@JvmInline");
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------- float-diff tolerance ----------------------

/// True when the two outputs differ only by a ULP-1 double on `double_pow.kt`.
pub fn knownJvmFloatDiff(path: []const u8, kotlinc_out: []const u8, klio_out: []const u8) bool {
    const files = [_][]const u8{"double_pow.kt"};
    const basename = std.fs.path.basename(path);
    var listed = false;
    for (files) |f| {
        if (std.mem.eql(u8, f, basename)) {
            listed = true;
            break;
        }
    }
    if (!listed) return false;
    var a_buf: [8192][]const u8 = undefined;
    var b_buf: [8192][]const u8 = undefined;
    const na = splitLines(kotlinc_out, &a_buf) orelse return false;
    const nb = splitLines(klio_out, &b_buf) orelse return false;
    if (na != nb) return false;
    for (a_buf[0..na], b_buf[0..nb]) |x, y| {
        if (std.mem.eql(u8, x, y)) continue;
        const xd = std.fmt.parseFloat(f64, x) catch return false;
        const yd = std.fmt.parseFloat(f64, y) catch return false;
        const xb: u64 = @bitCast(xd);
        const yb: u64 = @bitCast(yd);
        if (@max(xb, yb) - @min(xb, yb) > 1) return false;
    }
    return true;
}

fn splitLines(s: []const u8, buf: [][]const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        if (n >= buf.len) return null;
        buf[n] = l;
        n += 1;
    }
    if (n > 0 and buf[n - 1].len == 0) n -= 1;
    return n;
}

// ---------------------- full parity check + diff ----------------------

/// Full parity check: compile + run both compilers, return a report. The
/// report's strings are owned by `allocator`.
pub fn check(allocator: Allocator, io: Io, file: []const u8) Allocator.Error!PResult(ParityReport) {
    runtime.startMemoryWatchdog();
    runtime.startRunDeadline();
    if (envFlag(allocator, io, "KLIO_SKIP_KOTLINC_PARITY")) {
        return .{ .err = .NoKotlinc };
    }
    const ko = switch (try kotlincOutput(allocator, io, file)) {
        .err => |e| return .{ .err = e },
        .ok => |v| v,
    };
    switch (try runWithKtc(allocator, io, file)) {
        .ok => |klio_stdout| {
            return .{ .ok = .{
                .matched = std.mem.eql(u8, ko.stdout, klio_stdout),
                .kotlinc_stdout = ko.stdout,
                .klio_stdout = klio_stdout,
                .kotlinc_exit = ko.exit,
                .klio_error = null,
            } };
        },
        .err => |e| {
            return .{ .ok = .{
                .matched = false,
                .kotlinc_stdout = ko.stdout,
                .klio_stdout = try allocator.alloc(u8, 0),
                .kotlinc_exit = ko.exit,
                .klio_error = e,
            } };
        },
    }
}

/// Render a unified-style diff between the two outputs. Empty string when they
/// match. The returned string is owned by `allocator`.
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

// ---------------------- corpus build + parallel sweep ----------------------

pub const CorpusEntry = struct {
    original: []u8,
    staged: []u8,
    fqcn: []u8,

    pub fn deinit(self: CorpusEntry, allocator: Allocator) void {
        allocator.free(self.original);
        allocator.free(self.staged);
        allocator.free(self.fqcn);
    }
};

pub const CorpusBuild = struct {
    jar: []u8,
    stage_dir: []u8,
    classes: []CorpusEntry,

    pub fn deinit(self: CorpusBuild, allocator: Allocator) void {
        allocator.free(self.jar);
        allocator.free(self.stage_dir);
        for (self.classes) |c| c.deinit(allocator);
        allocator.free(self.classes);
    }
};

pub const SweepVerdict = union(enum) {
    Pass,
    Mismatch: *ParityReport,
    KlioError: []u8,
    KotlincError: []u8,
    Timeout,

    pub fn deinit(self: SweepVerdict, allocator: Allocator) void {
        switch (self) {
            .Mismatch => |r| {
                allocator.free(r.kotlinc_stdout);
                allocator.free(r.klio_stdout);
                if (r.klio_error) |e| allocator.free(e);
                allocator.destroy(r);
            },
            .KlioError, .KotlincError => |m| allocator.free(m),
            .Pass, .Timeout => {},
        }
    }
};

pub const SweepEntryResult = struct {
    path: []u8,
    verdict: SweepVerdict,

    pub fn deinit(self: SweepEntryResult, allocator: Allocator) void {
        allocator.free(self.path);
        self.verdict.deinit(allocator);
    }
};

pub const SweepResult = struct {
    results: []SweepEntryResult,

    pub fn deinit(self: SweepResult, allocator: Allocator) void {
        for (self.results) |r| r.deinit(allocator);
        allocator.free(self.results);
    }

    pub fn passed(self: *const SweepResult) usize {
        var n: usize = 0;
        for (self.results) |r| {
            if (r.verdict == .Pass) n += 1;
        }
        return n;
    }
};

fn corpusEntryKey(allocator: Allocator, io: Io, staged: []const u8) Allocator.Error![]u8 {
    const bytes = readFileOrEmpty(allocator, io, staged);
    defer allocator.free(bytes);
    const hex = try hashHex(allocator, bytes);
    defer allocator.free(hex);
    return std.fmt.allocPrint(allocator, "corpus-{s}", .{hex});
}

fn corpusCacheKey(allocator: Allocator, io: Io, label: []const u8, files: []const []const u8) Allocator.Error![]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(label);
    const sorted = try allocator.dupe([]const u8, files);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (sorted) |f| {
        h.update(std.fs.path.basename(f));
        const bytes = readFileOrEmpty(allocator, io, f);
        defer allocator.free(bytes);
        h.update(bytes);
    }
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{h.final()});
}

/// True when every staged entry already has a cached corpus output.
pub fn corpusOutputsAllCached(allocator: Allocator, io: Io, staged: []const []const u8) bool {
    for (staged) |s| {
        const key = corpusEntryKey(allocator, io, s) catch return false;
        defer allocator.free(key);
        const hit = readExpected(allocator, io, key) catch return false;
        if (hit) |h| {
            allocator.free(h.stdout);
        } else return false;
    }
    return true;
}

/// Run a specific fully-qualified main class out of `jar`.
pub fn runClass(allocator: Allocator, io: Io, jar: []const u8, fqcn: []const u8) Allocator.Error!PResult(ExpectedHit) {
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
        .argv = &.{ java, xmx, "-cp", jar, fqcn },
        .environ_map = &env,
        .timeout = javaTimeout(allocator, io),
    }) catch {
        return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn java") } };
    };
    allocator.free(r.stderr);
    return .{ .ok = .{ .stdout = r.stdout, .exit = termExit(r.term) } };
}

/// kotlinc output for one corpus entry, cached by staged-source hash. On a miss
/// the class is run via `runClass`.
pub fn corpusEntryOutput(allocator: Allocator, io: Io, staged: []const u8, jar: []const u8, fqcn: []const u8) Allocator.Error!PResult(ExpectedHit) {
    const key = try corpusEntryKey(allocator, io, staged);
    defer allocator.free(key);
    if (try readExpected(allocator, io, key)) |hit| return .{ .ok = hit };
    const run = switch (try runClass(allocator, io, jar, fqcn)) {
        .err => |e| return .{ .err = e },
        .ok => |r| r,
    };
    try writeExpected(allocator, io, key, run.stdout, run.exit);
    return .{ .ok = run };
}

/// Compile a whole list of `.kt` files in one `kotlinc` invocation, each staged
/// under a unique package. Cached by `(label, file contents)`.
pub fn compileCorpus(allocator: Allocator, io: Io, label: []const u8, files: []const []const u8) Allocator.Error!PResult(CorpusBuild) {
    const kotlinc = switch (try findKotlinc(allocator, io)) {
        .err => |e| return .{ .err = e },
        .ok => |k| k,
    };
    defer allocator.free(kotlinc);
    var env = try procEnvMap(allocator, io);
    defer env.deinit();
    const cache = try parityCacheDir(allocator, io);
    defer allocator.free(cache);
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};

    const key = try corpusCacheKey(allocator, io, label, files);
    defer allocator.free(key);
    const jar = try std.fmt.allocPrint(allocator, "{s}/corpus-{s}-{s}.jar", .{ cache, label, key });
    errdefer allocator.free(jar);
    const stage = try std.fmt.allocPrint(allocator, "{s}/stage-{s}-{s}", .{ cache, label, key });
    errdefer allocator.free(stage);

    std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    std.Io.Dir.cwd().createDirPath(io, stage) catch {};
    var classes: std.ArrayList(CorpusEntry) = .empty;
    errdefer {
        for (classes.items) |c| c.deinit(allocator);
        classes.deinit(allocator);
    }
    for (files) |file| {
        const stem_full = std.fs.path.basename(file);
        const stem = if (std.mem.lastIndexOfScalar(u8, stem_full, '.')) |dot| stem_full[0..dot] else stem_full;
        const pkg_seg = try sanitizePkgSegment(allocator, stem);
        defer allocator.free(pkg_seg);
        const pkg = try std.fmt.allocPrint(allocator, "klio_parity.{s}.{s}", .{ label, pkg_seg });
        defer allocator.free(pkg);
        const cap = try capitalizeFirst(allocator, stem);
        defer allocator.free(cap);
        const fqcn = try std.fmt.allocPrint(allocator, "{s}.{s}Kt", .{ pkg, cap });
        const src = readFileOpt(allocator, io, file) orelse {
            allocator.free(fqcn);
            allocator.free(jar);
            allocator.free(stage);
            return .{ .err = .{ .Io = try std.fmt.allocPrint(allocator, "read {s}", .{file}) } };
        };
        defer allocator.free(src);
        const rewritten = try injectJvmInline(allocator, src);
        defer allocator.free(rewritten);
        const shimmed = try std.fmt.allocPrint(allocator, "package {s}\n\n{s}", .{ pkg, rewritten });
        defer allocator.free(shimmed);
        const staged = try std.fmt.allocPrint(allocator, "{s}/{s}.kt", .{ stage, stem });
        writeFile(io, staged, shimmed);
        try classes.append(allocator, .{
            .original = try allocator.dupe(u8, file),
            .staged = staged,
            .fqcn = fqcn,
        });
    }

    const classes_slice = try classes.toOwnedSlice(allocator);
    errdefer {
        for (classes_slice) |c| c.deinit(allocator);
        allocator.free(classes_slice);
    }

    if (isFile(io, jar)) {
        return .{ .ok = .{ .jar = jar, .stage_dir = stage, .classes = classes_slice } };
    }

    const tmp = try std.fmt.allocPrint(allocator, "{s}/corpus-{s}-{s}.partial.jar", .{ cache, label, key });
    defer allocator.free(tmp);
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const r = std.process.run(allocator, io, .{
        .argv = &.{ kotlinc, stage, "-include-runtime", "-d", tmp },
        .environ_map = &env,
    }) catch {
        for (classes_slice) |c| c.deinit(allocator);
        allocator.free(classes_slice);
        allocator.free(jar);
        allocator.free(stage);
        return .{ .err = .{ .Io = try allocator.dupe(u8, "spawn kotlinc") } };
    };
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    if (!termOk(r.term)) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        for (classes_slice) |c| c.deinit(allocator);
        allocator.free(classes_slice);
        allocator.free(jar);
        allocator.free(stage);
        return .{ .err = .{ .Compile = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ r.stdout, r.stderr }) } };
    }
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), jar, io) catch {};
    return .{ .ok = .{ .jar = jar, .stage_dir = stage, .classes = classes_slice } };
}

const SweepCtx = struct {
    allocator: Allocator,
    io: Io,
    jar: []const u8,
    entries: []const CorpusEntry,
    next: std.atomic.Value(usize),
    slots: []?SweepVerdict,
};

fn sweepOne(allocator: Allocator, io: Io, jar: []const u8, entry: *const CorpusEntry) Allocator.Error!SweepVerdict {
    const ko = switch (try corpusEntryOutput(allocator, io, entry.staged, jar, entry.fqcn)) {
        .err => |e| {
            const msg = try e.message(allocator);
            e.deinit(allocator);
            return .{ .KotlincError = msg };
        },
        .ok => |v| v,
    };
    switch (try runWithKtc(allocator, io, entry.staged)) {
        .ok => |klio_stdout| {
            if (std.mem.eql(u8, ko.stdout, klio_stdout) or
                knownJvmFloatDiff(entry.original, ko.stdout, klio_stdout))
            {
                allocator.free(ko.stdout);
                allocator.free(klio_stdout);
                return .Pass;
            }
            const report = try allocator.create(ParityReport);
            report.* = .{
                .matched = false,
                .kotlinc_stdout = ko.stdout,
                .klio_stdout = klio_stdout,
                .kotlinc_exit = ko.exit,
                .klio_error = null,
            };
            return .{ .Mismatch = report };
        },
        .err => |e| {
            allocator.free(ko.stdout);
            return .{ .KlioError = e };
        },
    }
}

fn sweepWorker(ctx: *SweepCtx) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.entries.len) break;
        const verdict = sweepOne(ctx.allocator, ctx.io, ctx.jar, &ctx.entries[i]) catch SweepVerdict.Timeout;
        ctx.slots[i] = verdict;
    }
}

/// Run the corpus/examples parity sweep for `paths`.
pub fn runSweep(allocator: Allocator, io: Io, label: []const u8, paths: []const []const u8, jobs: usize) Allocator.Error!PResult(SweepResult) {
    const build = switch (try compileCorpus(allocator, io, label, paths)) {
        .err => |e| return .{ .err = e },
        .ok => |b| b,
    };
    defer build.deinit(allocator);

    const slots = try allocator.alloc(?SweepVerdict, build.classes.len);
    defer allocator.free(slots);
    for (slots) |*s| s.* = null;

    var ctx = SweepCtx{
        .allocator = allocator,
        .io = io,
        .jar = build.jar,
        .entries = build.classes,
        .next = std.atomic.Value(usize).init(0),
        .slots = slots,
    };

    const n = @max(jobs, 1);
    const threads = try allocator.alloc(?std.Thread, n);
    defer allocator.free(threads);
    var spawned_any = false;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, sweepWorker, .{&ctx}) catch null;
    }
    for (threads) |t| {
        if (t) |th| {
            th.join();
            spawned_any = true;
        }
    }
    if (!spawned_any) sweepWorker(&ctx);

    const results = try allocator.alloc(SweepEntryResult, build.classes.len);
    errdefer allocator.free(results);
    for (build.classes, slots, 0..) |entry, slot, i| {
        results[i] = .{
            .path = try allocator.dupe(u8, entry.original),
            .verdict = slot orelse SweepVerdict.Timeout,
        };
    }
    return .{ .ok = .{ .results = results } };
}

// ---------------------- additional tests ----------------------

test "plain_value_class_gets_annotation" {
    const out = try injectJvmInline(std.testing.allocator, "value class UserId(val raw: Int)\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "@JvmInline\nvalue class UserId"));
}

test "modifier_chain_handled" {
    const out = try injectJvmInline(std.testing.allocator, "public value class X(val a: Int)\n");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@JvmInline\npublic value class X") != null);
}

test "existing_annotation_left_alone" {
    const src = "@JvmInline\nvalue class X(val a: Int)\n";
    const out = try injectJvmInline(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "indented_value_class_preserves_indent" {
    const src = "    value class Inner(val a: Int)\n";
    const out = try injectJvmInline(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("    @JvmInline\n    value class Inner(val a: Int)\n", out);
}

test "unrelated_lines_unchanged" {
    const src = "fun main() { println(\"value class\") }\n";
    const out = try injectJvmInline(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "cache_key_is_stable_for_same_contents" {
    const a = std.testing.allocator;
    var threaded = threadedIo(a);
    defer threaded.deinit();
    const io = threaded.io();
    const path = "klio-parity-cache-key.kt";
    writeFile(io, path, "fun main() { println(1) }");
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const k1 = try cacheKey(a, io, path);
    defer a.free(k1);
    const k2 = try cacheKey(a, io, path);
    defer a.free(k2);
    try std.testing.expectEqualStrings(k1, k2);
}

test "manifest_pat_match forms" {
    try std.testing.expect(manifestPatMatch("a/b", "a/"));
    try std.testing.expect(manifestPatMatch("a/b/c", "a/"));
    try std.testing.expect(manifestPatMatch("foo.kt", "*.kt"));
    try std.testing.expect(manifestPatMatch("foobar", "foo*"));
    try std.testing.expect(manifestPatMatch("exact", "exact"));
    try std.testing.expect(!manifestPatMatch("other", "exact"));
}

test "sanitize_pkg_segment suffixes reserved words" {
    const a = std.testing.allocator;
    const s1 = try sanitizePkgSegment(a, "class");
    defer a.free(s1);
    try std.testing.expectEqualStrings("class_", s1);
    const s2 = try sanitizePkgSegment(a, "widget");
    defer a.free(s2);
    try std.testing.expectEqualStrings("widget", s2);
}

test "capitalize_first uppercases leading byte" {
    const a = std.testing.allocator;
    const s = try capitalizeFirst(a, "main");
    defer a.free(s);
    try std.testing.expectEqualStrings("Main", s);
}

test "known_jvm_float_diff only for listed file" {
    try std.testing.expect(!knownJvmFloatDiff("other.kt", "1.0\n", "1.0\n"));
    try std.testing.expect(knownJvmFloatDiff("double_pow.kt", "1.0\n", "1.0\n"));
}

test "capture output line splitting and join" {
    var out = CaptureOutput.init(std.testing.allocator);
    defer out.deinit();
    out.output().writeln("hello");
    out.output().write("wor");
    out.output().write("ld\n");
    const joined = try out.intoJoined(std.testing.allocator);
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("hello\nworld\n", joined);
}

test {
    std.testing.refAllDecls(@This());
}

test "TARGET_VERSION is the expected default" {
    try std.testing.expectEqualStrings("2.3.21", TARGET_VERSION);
}

test "KotlincKind binary and env names" {
    try std.testing.expectEqualStrings("kotlinc", KotlincKind.Jvm.binaryName());
    try std.testing.expectEqualStrings("kotlinc-native", KotlincKind.Native.binaryName());
    try std.testing.expectEqualStrings("KLIO_KOTLINC_JVM_HOME", KotlincKind.Jvm.envOverride());
    try std.testing.expectEqualStrings("KLIO_KOTLINC_NATIVE", KotlincKind.Native.envOverride());
}

test "ParityError messages render the expected display text" {
    const a = std.testing.allocator;
    {
        const m = try (ParityError{ .NoKotlinc = {} }).message(a);
        defer a.free(m);
        try std.testing.expect(std.mem.startsWith(u8, m, "kotlinc not found."));
    }
    {
        const m = try (ParityError{ .NoJava = {} }).message(a);
        defer a.free(m);
        try std.testing.expect(std.mem.startsWith(u8, m, "java not found on PATH"));
    }
    {
        var e = ParityError{ .Compile = try a.dupe(u8, "boom") };
        defer e.deinit(a);
        const m = try e.message(a);
        defer a.free(m);
        try std.testing.expectEqualStrings("kotlinc compile failed:\nboom", m);
    }
    {
        var e = ParityError{ .UnsupportedPlatform = try a.dupe(u8, "linux-riscv64") };
        defer e.deinit(a);
        const m = try e.message(a);
        defer a.free(m);
        try std.testing.expectEqualStrings("no kotlinc prebuilt for platform: linux-riscv64", m);
    }
}
