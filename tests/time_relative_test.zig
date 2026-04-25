const std = @import("std");
const timefmt = @import("codex_auth").time.relative;

const formatRelativeTimeAlloc = timefmt.formatRelativeTimeAlloc;
const formatRelativeTimeOrDashAlloc = timefmt.formatRelativeTimeOrDashAlloc;

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
