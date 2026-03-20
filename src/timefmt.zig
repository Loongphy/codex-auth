const std = @import("std");

pub fn parseSimpleDurationSeconds(raw: []const u8) ?u32 {
    if (raw.len < 2) return null;
    const unit = raw[raw.len - 1];
    const value = std.fmt.parseInt(u32, raw[0 .. raw.len - 1], 10) catch return null;
    if (value == 0) return null;
    return switch (unit) {
        's' => value,
        'm' => std.math.mul(u32, value, 60) catch null,
        'h' => std.math.mul(u32, value, 60 * 60) catch null,
        else => null,
    };
}

pub fn formatSimpleDurationAlloc(allocator: std.mem.Allocator, seconds: u32) ![]u8 {
    if (seconds != 0 and @mod(seconds, 60 * 60) == 0) {
        return std.fmt.allocPrint(allocator, "{d}h", .{@divTrunc(seconds, 60 * 60)});
    }
    if (seconds != 0 and @mod(seconds, 60) == 0) {
        return std.fmt.allocPrint(allocator, "{d}m", .{@divTrunc(seconds, 60)});
    }
    return std.fmt.allocPrint(allocator, "{d}s", .{seconds});
}

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

test "parseSimpleDurationSeconds supports seconds minutes and hours" {
    try std.testing.expectEqual(@as(?u32, 4), parseSimpleDurationSeconds("4s"));
    try std.testing.expectEqual(@as(?u32, 240), parseSimpleDurationSeconds("4m"));
    try std.testing.expectEqual(@as(?u32, 14_400), parseSimpleDurationSeconds("4h"));
}

test "parseSimpleDurationSeconds rejects malformed values" {
    try std.testing.expect(parseSimpleDurationSeconds("0s") == null);
    try std.testing.expect(parseSimpleDurationSeconds("4S") == null);
    try std.testing.expect(parseSimpleDurationSeconds("1.5m") == null);
    try std.testing.expect(parseSimpleDurationSeconds("1h30m") == null);
    try std.testing.expect(parseSimpleDurationSeconds("m") == null);
}

test "formatSimpleDurationAlloc uses canonical suffixes" {
    const seconds = try formatSimpleDurationAlloc(std.testing.allocator, 4);
    defer std.testing.allocator.free(seconds);
    try std.testing.expect(std.mem.eql(u8, seconds, "4s"));

    const minutes = try formatSimpleDurationAlloc(std.testing.allocator, 240);
    defer std.testing.allocator.free(minutes);
    try std.testing.expect(std.mem.eql(u8, minutes, "4m"));

    const hours = try formatSimpleDurationAlloc(std.testing.allocator, 14_400);
    defer std.testing.allocator.free(hours);
    try std.testing.expect(std.mem.eql(u8, hours, "4h"));
}
