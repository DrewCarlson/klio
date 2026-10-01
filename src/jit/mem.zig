//! Executable memory for compiled code: a heap of chunks, each seen through a
//! view the compiler writes code into and a view the code runs from, so no
//! thread runs code on a page it can write. Apple systems map one view
//! (`MAP_JIT`) whose writability is a per-thread switch; Linux and Android
//! map a memory file twice; Windows maps a pagefile section twice.
//!
//! Code is copied in once and never changed in place, so a chunk only grows.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ Unsupported, OutOfMemory, MapFailed };

const os = builtin.os.tag;
const is_apple = os.isDarwin();

/// Whether this target can run code it writes.
pub const supported = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => os == .macos or os == .ios or os == .linux or os == .windows,
    else => false,
};

/// Code copied into a heap: `w` to write it through, `x` the address it runs at.
pub const Code = struct {
    w: []u8,
    x: usize,
};

const Chunk = struct {
    w: [*]u8,
    x: [*]u8,
    size: usize,
    used: usize,
    next: ?*Chunk,
    /// The memory file (Linux) or section handle (Windows) behind the two views.
    handle: usize,
};

/// A growing set of chunks that code is bump-allocated from. Not thread-safe:
/// its owner holds a lock around `alloc` and the writes that follow.
pub const Heap = struct {
    chunks: ?*Chunk = null,
    chunk_size: usize = 4 * 1024 * 1024,

    /// `len` bytes of code space, 16-byte aligned. Call `beginWrite` before
    /// writing through `w` and `publish` after.
    pub fn alloc(self: *Heap, len: usize) Error!Code {
        if (comptime !supported) return Error.Unsupported;
        const want = std.mem.alignForward(usize, @max(len, 1), 16);
        if (self.chunks) |c| {
            if (c.size - c.used >= want) return take(c, want);
        }
        const c = try mapChunk(@max(self.chunk_size, std.mem.alignForward(usize, want, std.heap.pageSize())));
        c.next = self.chunks;
        self.chunks = c;
        return take(c, want);
    }

    pub fn deinit(self: *Heap) void {
        var cur = self.chunks;
        while (cur) |c| {
            cur = c.next;
            unmapChunk(c);
        }
        self.* = .{};
    }

    /// Whether `addr` is inside code this heap holds.
    pub fn contains(self: *const Heap, addr: usize) bool {
        var cur = self.chunks;
        while (cur) |c| : (cur = c.next) {
            const base = @intFromPtr(c.x);
            if (addr >= base and addr < base + c.used) return true;
        }
        return false;
    }
};

fn take(c: *Chunk, len: usize) Code {
    const off = c.used;
    c.used += len;
    return .{ .w = c.w[off..][0..len], .x = @intFromPtr(c.x) + off };
}

/// Lets this thread write code (Apple's `MAP_JIT` pages are write-protected
/// per thread); every other system writes through its own view.
pub fn beginWrite() void {
    if (comptime is_apple and supported) {
        if (comptime builtin.cpu.arch == .aarch64) pthread_jit_write_protect_np(0);
    }
}

/// Ends the writes `beginWrite` allowed and makes `code` runnable: the
/// instruction cache learns what was written.
pub fn publish(code: Code) void {
    if (comptime !supported) return;
    if (comptime is_apple) {
        if (comptime builtin.cpu.arch == .aarch64) pthread_jit_write_protect_np(1);
        sys_icache_invalidate(@ptrFromInt(code.x), code.w.len);
    } else if (comptime os == .windows) {
        _ = FlushInstructionCache(GetCurrentProcess(), @ptrFromInt(code.x), code.w.len);
    } else if (comptime builtin.cpu.arch == .aarch64) {
        syncICache(code.x, code.w.len);
    }
}

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

/// The AArch64 cache maintenance that makes written code visible to
/// instruction fetch: clean the data lines to the point of unification,
/// invalidate the instruction lines, with the barriers between.
fn syncICache(start: usize, len: usize) void {
    if (comptime builtin.cpu.arch != .aarch64) return;
    const ctr = asm volatile ("mrs %[r], ctr_el0"
        : [r] "=r" (-> u64),
    );
    const dline: usize = @as(usize, 4) << @intCast((ctr >> 16) & 0xF);
    const iline: usize = @as(usize, 4) << @intCast(ctr & 0xF);
    const end = start + len;
    var a = start & ~(dline - 1);
    while (a < end) : (a += dline) {
        asm volatile ("dc cvau, %[a]"
            :
            : [a] "r" (a),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    a = start & ~(iline - 1);
    while (a < end) : (a += iline) {
        asm volatile ("ic ivau, %[a]"
            :
            : [a] "r" (a),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

fn mapChunk(size: usize) Error!*Chunk {
    const c = std.heap.page_allocator.create(Chunk) catch return Error.OutOfMemory;
    errdefer std.heap.page_allocator.destroy(c);
    c.* = .{ .w = undefined, .x = undefined, .size = size, .used = 0, .next = null, .handle = 0 };
    if (comptime is_apple) {
        const p = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .JIT = true },
            -1,
            0,
        ) catch return Error.MapFailed;
        c.w = p.ptr;
        c.x = p.ptr;
    } else if (comptime os == .linux) {
        try mapLinux(c, size);
    } else if (comptime os == .windows) {
        try mapWindows(c, size);
    } else {
        return Error.Unsupported;
    }
    return c;
}

fn unmapChunk(c: *Chunk) void {
    if (comptime is_apple) {
        std.posix.munmap(@alignCast(c.w[0..c.size]));
    } else if (comptime os == .linux) {
        std.posix.munmap(@alignCast(c.w[0..c.size]));
        if (c.x != c.w) std.posix.munmap(@alignCast(c.x[0..c.size]));
        if (c.handle != 0) _ = std.os.linux.close(@intCast(c.handle));
    } else if (comptime os == .windows) {
        _ = UnmapViewOfFile(c.w);
        _ = UnmapViewOfFile(c.x);
        _ = CloseHandle(@ptrFromInt(c.handle));
    }
    std.heap.page_allocator.destroy(c);
}

/// A memory file mapped writable and executable; where the kernel refuses a
/// memory file, one mapping both writable and executable.
fn mapLinux(c: *Chunk, size: usize) Error!void {
    const linux = std.os.linux;
    const fd_rc = linux.memfd_create("klio-jit", linux.MFD.CLOEXEC);
    if (linux.errno(fd_rc) == .SUCCESS) {
        const fd: i32 = @intCast(fd_rc);
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) == .SUCCESS) {
            if (std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0)) |w| {
                if (std.posix.mmap(null, size, .{ .READ = true, .EXEC = true }, .{ .TYPE = .SHARED }, fd, 0)) |x| {
                    c.w = w.ptr;
                    c.x = x.ptr;
                    c.handle = @intCast(fd);
                    return;
                } else |_| std.posix.munmap(w);
            } else |_| {}
        }
        _ = linux.close(fd);
    }
    const p = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return Error.MapFailed;
    c.w = p.ptr;
    c.x = p.ptr;
}

const win = struct {
    const HANDLE = ?*anyopaque;
    const PAGE_EXECUTE_READWRITE: u32 = 0x40;
    const FILE_MAP_WRITE: u32 = 0x0002;
    const FILE_MAP_READ: u32 = 0x0004;
    const FILE_MAP_EXECUTE: u32 = 0x0020;
};

extern "kernel32" fn CreateFileMappingW(file: win.HANDLE, attrs: ?*anyopaque, protect: u32, size_high: u32, size_low: u32, name: ?[*:0]const u16) callconv(.winapi) win.HANDLE;
extern "kernel32" fn MapViewOfFile(mapping: win.HANDLE, access: u32, off_high: u32, off_low: u32, len: usize) callconv(.winapi) ?[*]u8;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: win.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn FlushInstructionCache(process: win.HANDLE, base: ?*const anyopaque, len: usize) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) win.HANDLE;

/// A pagefile section mapped once writable and once executable.
fn mapWindows(c: *Chunk, size: usize) Error!void {
    const invalid: win.HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const h = CreateFileMappingW(invalid, null, win.PAGE_EXECUTE_READWRITE, @intCast(size >> 32), @truncate(size), null) orelse return Error.MapFailed;
    const w = MapViewOfFile(h, win.FILE_MAP_WRITE, 0, 0, size) orelse {
        _ = CloseHandle(h);
        return Error.MapFailed;
    };
    const x = MapViewOfFile(h, win.FILE_MAP_READ | win.FILE_MAP_EXECUTE, 0, 0, size) orelse {
        _ = UnmapViewOfFile(w);
        _ = CloseHandle(h);
        return Error.MapFailed;
    };
    c.w = w;
    c.x = x;
    c.handle = @intFromPtr(h);
}

test "a heap hands out aligned code space from one chunk, and a new chunk when it is full" {
    if (comptime !supported) return error.SkipZigTest;
    var h: Heap = .{ .chunk_size = std.heap.pageSize() };
    defer h.deinit();
    const a = try h.alloc(10);
    const b = try h.alloc(20);
    try std.testing.expect(a.x % 16 == 0 and b.x % 16 == 0);
    try std.testing.expectEqual(a.x + 16, b.x);
    try std.testing.expect(h.contains(a.x) and h.contains(b.x + 19));
    const big = try h.alloc(h.chunk_size);
    try std.testing.expect(h.contains(big.x));
    try std.testing.expect(!h.contains(big.x + big.w.len));
}
