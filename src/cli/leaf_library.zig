//! The leaf tier's library: `KLIO_LEAVES` names shared libraries of
//! natively compiled leaf bodies, registered by FQN at startup.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");

/// KLIO_LEAVES=<path.so>: load a leaf library and register its bodies by fqn,
/// since bakes are not fid-stable. The dlopened handle is leaked on purpose.
pub fn loadLeafLibrary() void {
    const spec = runtime.envOnce("KLIO_LEAVES") orelse return;
    // Colon-separated; a later library overwrites an earlier key.
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |path| {
        if (path.len == 0) continue;
        var lib = std.DynLib.open(path) catch {
            std.debug.print("warning: KLIO_LEAVES: cannot open {s}\n", .{path});
            continue;
        };
        const Entry = *const fn (reg: *const fn (fqn: [*:0]const u8, f: ir.eval.NativeLeafFn) callconv(.c) void) callconv(.c) void;
        const entry = lib.lookup(Entry, "klio_leaves_entry") orelse {
            std.debug.print("warning: KLIO_LEAVES: {s} has no klio_leaves_entry\n", .{path});
            continue;
        };
        // Frozen KVC constants must match this runtime exactly, or the library is refused.
        const Frozen = *const fn () callconv(.c) *const ir.hot_layout.HotLayout;
        if (lib.lookup(Frozen, "klio_leaves_frozen")) |froz| {
            var live: ir.hot_layout.HotLayout = undefined;
            ir.hot_layout.fillLayout(&live);
            const fr = froz();
            var lay_ok = true;
            inline for (@typeInfo(ir.hot_layout.HotLayout).@"struct".fields) |fld| {
                if (@field(live, fld.name) != @field(fr, fld.name)) lay_ok = false;
            }
            if (!lay_ok) {
                std.debug.print("warning: KLIO_LEAVES: {s} layout mismatch — refused\n", .{path});
                continue;
            }
        }
        entry(&leafRegShim);
    }
}

/// Print leaf-gate engagement counters at exit (KLIO_LEAF_DIAG=1).
pub fn leafDiagDump() void {
    ir.eval.leafDiagDump();
}

fn leafRegShim(fqn: [*:0]const u8, f: ir.eval.NativeLeafFn) callconv(.c) void {
    ir.eval.registerNativeLeafFqn(std.mem.span(fqn), f);
}
