//! What a program `klio transpile --native` emits and the runtime it links
//! (`klio_rt`) agree on beyond the header: the class flag bits, and a hash
//! of every enumeration whose ordinals cross the boundary as numbers. The
//! program checks the hash at startup, so a program built by one klio and
//! linked against another's runtime stops rather than misreads a table.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir");

/// `klio_r_class.flags`.
pub const Flags = struct {
    pub const data: u32 = 1;
    pub const value: u32 = 2;
    pub const object: u32 = 4;
    pub const enum_: u32 = 8;
    pub const sealed: u32 = 16;
    pub const interface: u32 = 32;
    pub const fun_interface: u32 = 64;
    pub const open: u32 = 128;
    pub const abstract: u32 = 256;
    pub const inner: u32 = 512;
    pub const anonymous: u32 = 1024;
    pub const annotation: u32 = 2048;
};

/// The exceptions the runtime raises into a program itself, as
/// `klio_r_raise` numbers them and `klio_r_program.raised` orders them.
pub const Raise = enum(u32) {
    npe = 0,
    class_cast = 1,
    arithmetic = 2,
    uninitialized = 3,
    index = 4,
    array_index = 5,
    string_index = 6,
    init_failed = 7,
    no_class_def = 8,
};

/// The value kinds a host class table is indexed by, the slot seeds, the
/// host ops, the array and range kinds, the operators and the well-known
/// members, by name and order.
pub const abi: u64 = blk: {
    @setEvalBranchQuota(200_000);
    var h: u64 = 0xcbf29ce484222325;
    const sets = .{
        @typeInfo(std.meta.Tag(runtime.Value)).@"enum".fields,
        @typeInfo(ir.SlotSeed).@"enum".fields,
        @typeInfo(ir.resolved.HostOp).@"enum".fields,
        @typeInfo(runtime.PrimitiveArrayKind).@"enum".fields,
        @typeInfo(runtime.RangeKind).@"enum".fields,
        @typeInfo(ir.BinOp).@"enum".fields,
        @typeInfo(ir.UnOp).@"enum".fields,
        @typeInfo(runtime.WellKnown).@"enum".fields,
    };
    for (sets) |fields| {
        for (fields) |f| {
            for (f.name) |c| {
                h ^= c;
                h *%= 0x100000001b3;
            }
            h ^= 0xff;
            h *%= 0x100000001b3;
        }
    }
    break :blk h;
};

test "the hash moves when an ordinal it covers does" {
    try std.testing.expect(abi != 0xcbf29ce484222325);
}
