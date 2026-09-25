const std = @import("std");
const Allocator = std.mem.Allocator;

/// Type reference in the IR: a textual name resolved against the class table at runtime.
pub const TypeRef = struct {
    name: []const u8,
    nullable: bool,
    args: []TypeRef,

    pub fn eql(self: TypeRef, other: TypeRef) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;
        if (self.nullable != other.nullable) return false;
        if (self.args.len != other.args.len) return false;
        for (self.args, other.args) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn clone(self: TypeRef, allocator: Allocator) Allocator.Error!TypeRef {
        const args = try allocator.alloc(TypeRef, self.args.len);
        var initialized: usize = 0;
        errdefer {
            for (args[0..initialized]) |*arg| arg.deinit(allocator);
            allocator.free(args);
        }
        for (self.args, args) |src, *dst| {
            dst.* = try src.clone(allocator);
            initialized += 1;
        }
        const name = try allocator.dupe(u8, self.name);
        return .{
            .name = name,
            .nullable = self.nullable,
            .args = args,
        };
    }

    pub fn deinit(self: *TypeRef, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.args) |*a| a.deinit(allocator);
        allocator.free(self.args);
    }
};

pub const Reg = enum(u32) {
    _,
    pub fn from(v: u32) Reg {
        return @enumFromInt(v);
    }
    pub fn int(self: Reg) u32 {
        return @intFromEnum(self);
    }
};

pub const BlockId = enum(u32) {
    _,
    pub fn from(v: u32) BlockId {
        return @enumFromInt(v);
    }
    pub fn int(self: BlockId) u32 {
        return @intFromEnum(self);
    }
};

pub const FuncId = enum(u32) {
    _,
    pub fn from(v: u32) FuncId {
        return @enumFromInt(v);
    }
    pub fn int(self: FuncId) u32 {
        return @intFromEnum(self);
    }
};

pub const MethodSlotId = enum(u32) {
    _,
    pub fn from(v: u32) MethodSlotId {
        return @enumFromInt(v);
    }
    pub fn fromFunc(id: FuncId) MethodSlotId {
        return @enumFromInt(id.int());
    }
    pub fn int(self: MethodSlotId) u32 {
        return @intFromEnum(self);
    }
};

pub const ClassId = enum(u32) {
    _,
    pub fn from(v: u32) ClassId {
        return @enumFromInt(v);
    }
    pub fn int(self: ClassId) u32 {
        return @intFromEnum(self);
    }
};

/// A host function a bodyless declaration is bound to: an index into
/// `Resolved.natives`.
pub const NativeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub fn from(v: u32) NativeId {
        return @enumFromInt(v);
    }
    pub fn int(self: NativeId) u32 {
        return @intFromEnum(self);
    }
};

/// A top-level property with storage, or an enum entry: an index into
/// `Resolved.statics`.
pub const StaticId = enum(u32) {
    _,
    pub fn from(v: u32) StaticId {
        return @enumFromInt(v);
    }
    pub fn int(self: StaticId) u32 {
        return @intFromEnum(self);
    }
};

/// A `FuncId` field left empty (a property reference with no setter).
pub const NO_FUNC: u32 = std.math.maxInt(u32);

/// Constant pool index for literals too large to fit in a `u32`.
pub const ConstId = enum(u32) {
    _,
    pub fn from(v: u32) ConstId {
        return @enumFromInt(v);
    }
    pub fn int(self: ConstId) u32 {
        return @intFromEnum(self);
    }
};
