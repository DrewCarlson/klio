const std = @import("std");
const Allocator = std.mem.Allocator;

/// Type reference inside the IR. Today this is a textual FQN/name
/// — the evaluator resolves against the class table at runtime.
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

/// Identifier for a virtual register inside one function body.
pub const Reg = enum(u32) {
    _,
    pub fn from(v: u32) Reg {
        return @enumFromInt(v);
    }
    pub fn int(self: Reg) u32 {
        return @intFromEnum(self);
    }
};

/// One implicit-receiver tower entry: the receiver's type head, plus the
/// label under which its VALUE is addressable from nested scopes
/// (`this@<label>` — the extension fn or receiver lambda name), when one
/// is bound. A null label still serves resolution/derivation; only static
/// EMISSION with an outer receiver needs the value channel.
/// One contextual function-type parameter shape carried into a lambda body.
pub const PendingCtxFnShape = struct {
    name: []const u8,
    ctx_types: []const []const u8,
    n_regular: usize,
};

pub const ReceiverTowerEntry = struct {
    head: []const u8,
    label: ?[]const u8 = null,
};

/// Identifier for a basic block inside one function body.
pub const BlockId = enum(u32) {
    _,
    pub fn from(v: u32) BlockId {
        return @enumFromInt(v);
    }
    pub fn int(self: BlockId) u32 {
        return @intFromEnum(self);
    }
};

/// Identifier for a function inside the IR module.
pub const FuncId = enum(u32) {
    _,
    pub fn from(v: u32) FuncId {
        return @enumFromInt(v);
    }
    pub fn int(self: FuncId) u32 {
        return @intFromEnum(self);
    }
};

/// Stable identity of one virtual override family. A slot is rooted at the
/// declaration selected against the call site's static receiver type; the
/// link step maps `(runtime ClassId, MethodSlotId)` to the concrete `FuncId`.
/// Keeping this distinct from `FuncId` makes the bytecode contract explicit
/// even though the initial stable numbering reuses the root declaration id.
/// Handles into a `CallVirtual` instruction's host-receiver site memo
/// (see the field docs there). Built by the exec arm from the live
/// instruction and threaded into the host's virtual dispatch so the
/// resolution can stamp the site; null when the call carries argument
/// names or a parameter map (the memoized direct dispatch binds
/// positionally).
pub const VirtNativeSite = struct {
    cls: *u64,
    native: *u64,
    name_ptr: *u64,
    name_len: *u32,
};

/// One reified type-parameter substitution: the parameter's name and the
/// rendered actual type it stands for.
pub const ReifiedName = struct { name: []const u8, actual: []const u8 };

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

/// Identifier for a class declared in the IR module.
pub const ClassId = enum(u32) {
    _,
    pub fn from(v: u32) ClassId {
        return @enumFromInt(v);
    }
    pub fn int(self: ClassId) u32 {
        return @intFromEnum(self);
    }
};

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
    const owner_end = std.mem.indexOfScalar(u8, name[prefix.len..], 0) orelse return null;
    const owner_text = name[prefix.len .. prefix.len + owner_end];
    const owner_int = std.fmt.parseInt(u32, owner_text, 10) catch return null;
    const length_start = prefix.len + owner_end + 1;
    const colon = std.mem.indexOfScalar(u8, name[length_start..], ':') orelse return null;
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

/// One scope-true type rename carried by `Inst.BuildObject`: the simple
/// name a reference uses and the mangled lift name it resolves to in the
/// object expression's lexical scope.
pub const ScopeRename = struct { name: []const u8, renamed: []const u8 };

/// One classifier resolved at an anonymous-object expression's lexical site.
/// Runtime-lowered object members use its exact FQN instead of re-resolving a
/// bare name in their intentionally small side module.
pub const ScopeClassRef = struct {
    name: []const u8,
    fqn: []const u8,
    has_companion: bool,
};
