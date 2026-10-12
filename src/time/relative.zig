const std = @import("std");

pub fn formatRelativeTimeAlloc(allocator: std.mem.Allocator, ts: i64, now: i64) ![]u8 {
    if (ts <= 0) return allocator.print("-", .{});
    var delta: i64 = now - ts;
    if (delta < 0) delta = 0;
    if (delta < 60) {
        return allocator.print("Now", .{});
    }
    if (delta < 3600) {
        return allocator.print("{d}m ago", .{@divTrunc(delta, 60)});
    }
    if (delta < 86400) {
        return allocator.print("{d}h ago", .{@divTrunc(delta, 3600)});
    }
    return allocator.print("{d}d ago", .{@divTrunc(delta, 86400)});
}

pub fn formatRelativeTimeOrDashAlloc(allocator: std.mem.Allocator, ts: ?i64, now: i64) ![]u8 {
    if (ts == null or ts.? <= 0) {
        return allocator.print("-", .{});
    }
    return formatRelativeTimeAlloc(allocator, ts.?, now);
}
