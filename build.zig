const std = @import("std");

/// One Zig module per former Rust crate. `deps` are the non-dev crate
/// dependencies (the acyclic graph). `tested` flips on once a module has been
/// ported with passing `test {}` blocks, which adds it to `zig build test`.
const Mod = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
    tested: bool = false,
};

const mod_list = [_]Mod{
    .{ .name = "span", .tested = true },
    .{ .name = "diagnostics", .deps = &.{"span"}, .tested = true },
    .{ .name = "ast", .deps = &.{"span"}, .tested = true },
    .{ .name = "runtime", .deps = &.{ "ast", "span" }, .tested = true },
    .{ .name = "types", .deps = &.{ "ast", "diagnostics", "span" }, .tested = true },
    .{ .name = "lexer", .deps = &.{ "diagnostics", "span" }, .tested = true },
    .{ .name = "pack", .deps = &.{ "ast", "span", "types" }, .tested = true },
    .{ .name = "parser", .deps = &.{ "ast", "diagnostics", "lexer", "span" }, .tested = true },
    .{ .name = "ir", .deps = &.{ "span", "ast", "types", "runtime", "diagnostics" }, .tested = true },
    .{ .name = "stdlib", .deps = &.{ "runtime", "pack" } },
    .{ .name = "cfa", .deps = &.{ "ast", "diagnostics", "lexer", "parser", "span", "types" } },
    .{ .name = "resolver", .deps = &.{ "span", "ast", "diagnostics", "types", "stdlib" } },
    .{ .name = "interp_ir", .deps = &.{ "ir", "runtime", "ast", "span", "stdlib", "diagnostics" } },
    .{ .name = "stdlib_pack", .deps = &.{ "pack", "stdlib" } },
    .{ .name = "stdlib_gen", .deps = &.{ "pack", "stdlib" } },
    .{ .name = "kotlinx_atomicfu", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "kotlinx_coroutines", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "kotlinx_datetime", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "kotlinx_io", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "kotlinx_serialization", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "ktor_client", .deps = &.{ "runtime", "stdlib" } },
    .{ .name = "typeck", .deps = &.{ "span", "ast", "diagnostics", "resolver", "types", "cfa" } },
    .{ .name = "diagnostics_gen", .deps = &.{} },
    .{ .name = "cli", .deps = &.{ "span", "diagnostics", "lexer", "parser", "resolver", "typeck", "interp_ir", "ast", "pack", "stdlib", "stdlib_pack", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "ktor_client", "runtime", "types" } },
    .{ .name = "parity", .deps = &.{ "ast", "interp_ir", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "lexer", "pack", "parser", "resolver", "runtime", "span", "stdlib", "stdlib_pack", "typeck" } },
    .{ .name = "bench", .deps = &.{ "ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    defer mods.deinit();

    for (mod_list) |m| {
        const mod = b.addModule(m.name, .{
            .root_source_file = b.path(b.fmt("src/{s}/{s}.zig", .{ m.name, m.name })),
            .target = target,
            .optimize = optimize,
        });
        mods.put(m.name, mod) catch @panic("oom");
    }
    for (mod_list) |m| {
        const mod = mods.get(m.name).?;
        for (m.deps) |d| mod.addImport(d, mods.get(d).?);
    }

    const exe = b.addExecutable(.{
        .name = "klio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "span", .module = mods.get("span").? },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the klio binary");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all ported module tests");
    for (mod_list) |m| {
        if (!m.tested) continue;
        const t = b.addTest(.{ .root_module = mods.get(m.name).? });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
