//! Teardown off the critical path: an arena whose chunks came from the page
//! allocator unmaps one region per chunk, kernel work worth milliseconds at
//! the end of a stage. The arenas release on a detached thread, or inline
//! when no thread can be had.

const std = @import("std");

/// Frees every arena in `list`, which the page allocator owns and which is
/// freed with them.
pub fn releaseArenas(list: []std.heap.ArenaAllocator) void {
    if (list.len == 0) {
        std.heap.page_allocator.free(list);
        return;
    }
    if (std.Thread.spawn(.{ .stack_size = 64 * 1024 }, releaseThread, .{list})) |t| {
        t.detach();
    } else |_| {
        releaseThread(list);
    }
}

fn releaseThread(list: []std.heap.ArenaAllocator) void {
    for (list) |*a| a.deinit();
    std.heap.page_allocator.free(list);
}
