const std = @import("std");
const sessions = @import("../sessions.zig");

const line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:00Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":50.0,\"window_minutes\":60,\"resets_at\":123},\"secondary\":{\"used_percent\":10.0,\"window_minutes\":60,\"resets_at\":123},\"plan_type\":\"pro\"}}}";
const null_rate_limits_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:01Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}";

test "parse token_count usage" {
    const gpa = std.testing.allocator;
    const snap = sessions.parseUsageLine(gpa, line) orelse return error.TestExpectedEqual;
    try std.testing.expect(snap.primary != null);
    try std.testing.expect(snap.secondary != null);
}

test "scan latest usage reads only the newest rollout file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const valid_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-valid.jsonl" });
    defer gpa.free(valid_path);
    const newer_null_path = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-null.jsonl" });
    defer gpa.free(newer_null_path);

    try std.fs.cwd().writeFile(.{ .sub_path = valid_path, .data = line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = newer_null_path, .data = null_rate_limits_line ++ "\n" });

    const base_time = @as(i128, std.time.nanoTimestamp());
    {
        var valid_file = try std.fs.cwd().openFile(valid_path, .{ .mode = .read_write });
        defer valid_file.close();
        try valid_file.updateTimes(base_time, base_time);
    }
    {
        var newer_null_file = try std.fs.cwd().openFile(newer_null_path, .{ .mode = .read_write });
        defer newer_null_file.close();
        try newer_null_file.updateTimes(base_time + std.time.ns_per_s, base_time + std.time.ns_per_s);
    }

    const latest = try sessions.scanLatestUsageWithSource(gpa, codex_home);
    try std.testing.expect(latest == null);
}
