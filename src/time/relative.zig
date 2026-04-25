const std = @import("std");

pub fn formatRelativeTimeAlloc(allocator: std.mem.Allocator, ts: i64, now: i64) ![]u8 {
    if (ts <= 0) return std.fmt.allocPrint(allocator, "-", .{});
    var delta: i64 = now - ts;
    if (delta < 0) delta = 0;
    if (delta < 60) {
        return std.fmt.allocPrint(allocator, "Now", .{});
    }
    if (delta < 3600) {
        return std.fmt.allocPrint(allocator, "{d}m ago", .{@divTrunc(delta, 60)});
    }
    if (delta < 86400) {
        return std.fmt.allocPrint(allocator, "{d}h ago", .{@divTrunc(delta, 3600)});
    }
    return std.fmt.allocPrint(allocator, "{d}d ago", .{@divTrunc(delta, 86400)});
}

pub fn formatRelativeTimeOrDashAlloc(allocator: std.mem.Allocator, ts: ?i64, now: i64) ![]u8 {
    if (ts == null or ts.? <= 0) {
        return std.fmt.allocPrint(allocator, "-", .{});
    }
    return formatRelativeTimeAlloc(allocator, ts.?, now);
}
