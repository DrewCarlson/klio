//! Errors produced while encoding or decoding a pack.

const std = @import("std");

/// Errors produced while encoding or decoding a pack. Modeled as data so
/// callers can match on the variant and render the matching message; the
/// `format` method renders the error text.
pub const PackError = union(enum) {
    /// pack header is truncated or shorter than expected
    Truncated,
    /// pack magic bytes do not match `KPK\0`
    BadMagic,
    /// pack format version {found} is not supported (this build understands {expected})
    VersionMismatch: struct { expected: u32, found: u32 },
    /// pack hash mismatch — file is corrupt or modified after writing
    HashMismatch,
    /// decoding failed: {0}
    Decode: []const u8,
    /// encoding failed: {0}
    Encode: []const u8,
    /// zstd error: {0}
    Compression: []const u8,
    /// duplicate section name `{0}` in pack
    DuplicateSection: []const u8,
    /// section `{section}` decoded to {actual} bytes but directory expected {expected}
    LengthMismatch: struct { section: []const u8, expected: u64, actual: u64 },
    /// section directory of {0} bytes is larger than the format permits
    DirectoryTooLarge: usize,
    /// pack `{library_id}` declares abi {found} but this build of klio supports
    /// up to abi {supported}; regenerate the pack against klio >= the matching release
    AbiMismatch: struct { library_id: []const u8, found: u32, supported: u32 },
    /// {0}
    Io: []const u8,

    pub fn format(self: PackError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Truncated => try writer.writeAll("pack header is truncated or shorter than expected"),
            .BadMagic => try writer.writeAll("pack magic bytes do not match `KPK\\0`"),
            .VersionMismatch => |v| try writer.print(
                "pack format version {d} is not supported (this build understands {d})",
                .{ v.found, v.expected },
            ),
            .HashMismatch => try writer.writeAll("pack hash mismatch — file is corrupt or modified after writing"),
            .Decode => |m| try writer.print("decoding failed: {s}", .{m}),
            .Encode => |m| try writer.print("encoding failed: {s}", .{m}),
            .Compression => |m| try writer.print("zstd error: {s}", .{m}),
            .DuplicateSection => |n| try writer.print("duplicate section name `{s}` in pack", .{n}),
            .LengthMismatch => |l| try writer.print(
                "section `{s}` decoded to {d} bytes but directory expected {d}",
                .{ l.section, l.actual, l.expected },
            ),
            .DirectoryTooLarge => |n| try writer.print(
                "section directory of {d} bytes is larger than the format permits",
                .{n},
            ),
            .AbiMismatch => |a| try writer.print(
                "pack `{s}` declares abi {d} but this build of klio supports up to abi {d}; " ++
                    "regenerate the pack against klio >= the matching release",
                .{ a.library_id, a.found, a.supported },
            ),
            .Io => |m| try writer.writeAll(m),
        }
    }
};

test "error messages render the expected display text" {
    const a = std.testing.allocator;
    const Case = struct { err: PackError, want: []const u8 };
    const cases = [_]Case{
        .{ .err = .Truncated, .want = "pack header is truncated or shorter than expected" },
        .{ .err = .BadMagic, .want = "pack magic bytes do not match `KPK\\0`" },
        .{
            .err = .{ .VersionMismatch = .{ .expected = 2, .found = 1 } },
            .want = "pack format version 1 is not supported (this build understands 2)",
        },
        .{ .err = .HashMismatch, .want = "pack hash mismatch — file is corrupt or modified after writing" },
        .{ .err = .{ .DuplicateSection = "manifest" }, .want = "duplicate section name `manifest` in pack" },
        .{
            .err = .{ .LengthMismatch = .{ .section = "ast", .expected = 10, .actual = 7 } },
            .want = "section `ast` decoded to 7 bytes but directory expected 10",
        },
        .{ .err = .{ .DirectoryTooLarge = 99 }, .want = "section directory of 99 bytes is larger than the format permits" },
    };
    for (cases) |case| {
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try case.err.format(&aw.writer);
        const got = try aw.toOwnedSlice();
        defer a.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}
