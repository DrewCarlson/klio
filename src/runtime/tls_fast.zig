//! Owner-thread fast path for the interpreter's per-thread state.
//!
//! Darwin resolves every `threadlocal` access through a `_tlv_get_addr` CALL
//! rather than a register-relative load. LLVM hoists the call out of a loop, so
//! the cost lands wherever a call intervenes — which, in an interpreter, is
//! every hot helper. Measured on a member-call loop it was the top leaf in the
//! profile, and giving the four hottest per-thread structures ordinary global
//! storage ran 11% faster.
//!
//! The interpreter's state is genuinely per-thread, so it cannot simply become
//! global. Instead ONE thread — the one that claims ownership at startup, which
//! is the thread every non-coroutine program runs on — reads its state from an
//! ordinary global, and every other thread keeps its threadlocal. The owner
//! never changes, so no state ever migrates between the two storages: a given
//! thread deterministically reads the same object for the process's life, which
//! is exactly the guarantee `threadlocal` gave.
//!
//! Reading the thread pointer is one instruction on both supported
//! architectures. An architecture without one falls back to "never the owner",
//! which is the threadlocal behavior unchanged.

const std = @import("std");
const builtin = @import("builtin");

/// This thread's unique pointer, in one instruction. `TPIDRRO_EL0` on aarch64
/// is the thread pointer Darwin's own TLS lowering reads; on x86_64 the same
/// value sits at `%gs:0`.
pub inline fn threadPtr() usize {
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

/// Zero until a thread claims ownership. Written once, before any second
/// interpreter thread exists.
var owner: usize = 0;

/// Claim the calling thread as the owner. Called once from the process entry
/// point, on the thread the program runs on.
pub fn claimOwner() void {
    if (comptime !supported()) return;
    @atomicStore(usize, &owner, threadPtr(), .release);
}

pub inline fn supported() bool {
    return builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64;
}

/// Whether the calling thread reads the global copy. False for every thread but
/// the owner, and false everywhere before `claimOwner` runs.
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
