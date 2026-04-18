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

test "formatRelativeTimeAlloc Now" {
    const now: i64 = 1000;
    const out = try formatRelativeTimeAlloc(std.testing.allocator, 1000, now);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "Now"));
}

test "formatRelativeTimeAlloc minutes" {
    const now: i64 = 1000;
    const out = try formatRelativeTimeAlloc(std.testing.allocator, 880, now);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "2m ago"));
}

test "formatRelativeTimeAlloc hours" {
    const now: i64 = 1000 + (14 * 3600);
    const out = try formatRelativeTimeAlloc(std.testing.allocator, 1000, now);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "14h ago"));
}

test "formatRelativeTimeAlloc days" {
    const now: i64 = 1000 + (24 * 3600);
    const out = try formatRelativeTimeAlloc(std.testing.allocator, 1000, now);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "1d ago"));
}

test "formatRelativeTimeOrDashAlloc dash" {
    const out = try formatRelativeTimeOrDashAlloc(std.testing.allocator, null, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "-"));
}
