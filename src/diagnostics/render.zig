//! Diagnostic renderers. Each format consumes the same `[Diagnostic]` slice
//! against a `SourceMap`; choose the renderer that matches your downstream
//! consumer (terminal, JSON-consuming tooling, SARIF aggregator).

const std = @import("std");

pub const plain = @import("render/plain.zig");
pub const json = @import("render/json.zig");
pub const sarif = @import("render/sarif.zig");

pub const Format = enum {
    Plain,
    Json,
    Sarif,

    pub fn fromStr(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "plain")) return .Plain;
        if (std.mem.eql(u8, s, "json")) return .Json;
        if (std.mem.eql(u8, s, "sarif")) return .Sarif;
        return null;
    }
};

test "format from str" {
    try std.testing.expectEqual(Format.Plain, Format.fromStr("plain").?);
    try std.testing.expectEqual(Format.Json, Format.fromStr("json").?);
    try std.testing.expectEqual(Format.Sarif, Format.fromStr("sarif").?);
    try std.testing.expect(Format.fromStr("nope") == null);
}
