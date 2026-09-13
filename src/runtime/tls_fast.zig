//! Owner-thread fast path for the interpreter's per-thread state. Darwin
//! resolves every `threadlocal` access through a `_tlv_get_addr` call, and in
//! an interpreter a call intervenes in every hot helper. The state is genuinely
//! per-thread, so one thread, the one that claims ownership at startup and runs
//! every non-coroutine program, reads its state from an ordinary global while
//! every other thread keeps its threadlocal. The owner never changes, so a
//! given thread deterministically reads the same object for the process's
//! life.

const std = @import("std");
const builtin = @import("builtin");

/// This thread's unique pointer, in one instruction. Darwin only, because the
/// register is per-platform and this reads it directly: `TPIDRRO_EL0` on
/// aarch64, `%gs:0` on x86_64. Linux disagrees on both, so reading these there
/// is wrong or trapping, and Darwin is where the cost this dodges lives.
pub inline fn threadPtr() usize {
    if (comptime !supported()) return 0;
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("mrs %[o], TPIDRRO_EL0"
            : [o] "=r" (-> usize),
        ),
        .x86_64 => asm volatile ("movq %%gs:0, %[o]"
            : [o] "=r" (-> usize),
        ),
        else => 0,
    };
}

/// Written once, before any second interpreter thread exists.
var owner: usize = 0;

/// Called once from the process entry point.
pub fn claimOwner() void {
    if (comptime !supported()) return;
    @atomicStore(usize, &owner, threadPtr(), .release);
}

/// Anywhere else every thread keeps its `threadlocal`.
pub inline fn supported() bool {
    return builtin.os.tag.isDarwin() and
        (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64);
}

/// False everywhere before `claimOwner`.
pub inline fn isOwner() bool {
    if (comptime !supported()) return false;
    const o = @atomicLoad(usize, &owner, .monotonic);
    return o != 0 and o == threadPtr();
}

test "before a claim nobody is the owner" {
    const saved = @atomicLoad(usize, &owner, .monotonic);
    defer @atomicStore(usize, &owner, saved, .release);
    @atomicStore(usize, &owner, 0, .release);
    try std.testing.expect(!isOwner());
}

test "the claiming thread is the owner and another thread is not" {
    if (comptime !supported()) return error.SkipZigTest;
    const saved = @atomicLoad(usize, &owner, .monotonic);
    defer @atomicStore(usize, &owner, saved, .release);
    claimOwner();
    try std.testing.expect(isOwner());
    const Other = struct {
        fn run(out: *bool) void {
            out.* = isOwner();
        }
    };
    var other_saw_owner = true;
    const t = try std.Thread.spawn(.{}, Other.run, .{&other_saw_owner});
    t.join();
    try std.testing.expect(!other_saw_owner);
}
