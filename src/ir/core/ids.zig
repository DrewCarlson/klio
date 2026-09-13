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

/// One contextual function-type parameter shape carried into a lambda body.
pub const PendingCtxFnShape = struct {
    name: []const u8,
    ctx_types: []const []const u8,
    n_regular: usize,
};

/// One implicit-receiver tower entry: the receiver's type head plus the `this@<label>` that addresses its value, null when unbound.
pub const ReceiverTowerEntry = struct {
    head: []const u8,
    label: ?[]const u8 = null,
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

/// Out-pointers into a `CallVirtual` site memo: virtual dispatch stamps the resolved class
/// and native here. Null when the call carries argument names or a parameter map.
pub const VirtNativeSite = struct {
    cls: *u64,
    native: *u64,
    name_ptr: *u64,
    name_len: *u32,
};

pub const ReifiedName = struct { name: []const u8, actual: []const u8 };

/// Stable identity of one virtual override family, rooted at the declaration the
/// static receiver type selects; linking maps `(ClassId, MethodSlotId)` to a `FuncId`.
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

/// Identity key for a class type parameter: `$class$`, NUL, owner id, NUL, name
/// length, `:`, name. The parse side also strips an `out#`/`in#` variance prefix.
pub fn classTypeParamIdentity(
    allocator: Allocator,
    owner: ClassId,
    param: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "$class$\x00{d}\x00{d}:{s}",
        .{ owner.int(), param.len, param },
    );
}

pub const ClassTypeParamIdentity = struct {
    owner: ClassId,
    param: []const u8,
};

pub fn parseClassTypeParamIdentity(raw_name: []const u8) ?ClassTypeParamIdentity {
    var name = raw_name;
    if (std.mem.startsWith(u8, name, "out#")) {
        name = name["out#".len..];
    } else if (std.mem.startsWith(u8, name, "in#")) {
        name = name["in#".len..];
    }
    const prefix = "$class$\x00";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const owner_end = std.mem.findScalar(u8, name[prefix.len..], 0) orelse return null;
    const owner_text = name[prefix.len .. prefix.len + owner_end];
    const owner_int = std.fmt.parseInt(u32, owner_text, 10) catch return null;
    const length_start = prefix.len + owner_end + 1;
    const colon = std.mem.findScalar(u8, name[length_start..], ':') orelse return null;
    const length_text = name[length_start .. length_start + colon];
    const param_len = std.fmt.parseInt(usize, length_text, 10) catch return null;
    const param = name[length_start + colon + 1 ..];
    if (param.len != param_len) return null;
    return .{ .owner = ClassId.from(owner_int), .param = param };
}

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

/// A `BuildObject` type rename: the simple name a reference uses, and the mangled lift name.
pub const ScopeRename = struct { name: []const u8, renamed: []const u8 };

/// A classifier resolved at an anonymous-object site, so its lowered members use the exact FQN.
pub const ScopeClassRef = struct {
    name: []const u8,
    fqn: []const u8,
    has_companion: bool,
};
