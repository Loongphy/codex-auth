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

fn usageLineAlloc(allocator: std.mem.Allocator, timestamp: []const u8, used_percent: f64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"timestamp\":\"{s}\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"rate_limits\":{{\"primary\":{{\"used_percent\":{d:.1},\"window_minutes\":300,\"resets_at\":123}},\"secondary\":{{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456}},\"plan_type\":\"pro\"}}}}}}",
        .{ timestamp, used_percent },
    );
}

test "parse token_count usage" {
    const gpa = std.testing.allocator;
    const snap = sessions.parseUsageLine(gpa, line) orelse return error.TestExpectedEqual;
    try std.testing.expect(snap.primary != null);
    try std.testing.expect(snap.secondary != null);
}

test "scan latest usage chooses newest valid event from the most recent three rollout files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const rollout_a = try usageLineAlloc(gpa, "2025-01-01T00:00:05.000Z", 50.0);
    defer gpa.free(rollout_a);
    const rollout_b = try usageLineAlloc(gpa, "2025-01-01T00:00:07.000Z", 70.0);
    defer gpa.free(rollout_b);
    const rollout_d = try usageLineAlloc(gpa, "2025-01-01T00:00:09.000Z", 90.0);
    defer gpa.free(rollout_d);

    const path_a = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-a.jsonl" });
    defer gpa.free(path_a);
    const path_b = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-b.jsonl" });
    defer gpa.free(path_b);
    const path_c = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-c.jsonl" });
    defer gpa.free(path_c);
    const path_d = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-d.jsonl" });
    defer gpa.free(path_d);

    try std.fs.cwd().writeFile(.{ .sub_path = path_a, .data = rollout_a });
    try std.fs.cwd().writeFile(.{ .sub_path = path_b, .data = rollout_b });
    try std.fs.cwd().writeFile(.{ .sub_path = path_c, .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = path_d, .data = rollout_d });

    const base_time = @as(i128, std.time.nanoTimestamp());
    {
        var file = try std.fs.cwd().openFile(path_d, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time, base_time);
    }
    {
        var file = try std.fs.cwd().openFile(path_c, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + std.time.ns_per_s, base_time + std.time.ns_per_s);
    }
    {
        var file = try std.fs.cwd().openFile(path_b, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (2 * std.time.ns_per_s), base_time + (2 * std.time.ns_per_s));
    }
    {
        var file = try std.fs.cwd().openFile(path_a, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (3 * std.time.ns_per_s), base_time + (3 * std.time.ns_per_s));
    }

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings(path_b, latest.path);
    try std.testing.expectEqual(@as(i64, 1735689607000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 70.0), latest.snapshot.primary.?.used_percent);
}

test "scan latest usage ignores rollout files beyond the most recent three" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const path_a = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-a.jsonl" });
    defer gpa.free(path_a);
    const path_b = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-b.jsonl" });
    defer gpa.free(path_b);
    const path_c = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-c.jsonl" });
    defer gpa.free(path_c);
    const path_d = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", "rollout-d.jsonl" });
    defer gpa.free(path_d);

    const older_valid = try usageLineAlloc(gpa, "2025-01-01T00:00:09.000Z", 90.0);
    defer gpa.free(older_valid);
    try std.fs.cwd().writeFile(.{ .sub_path = path_a, .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = path_b, .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = path_c, .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = path_d, .data = older_valid });

    const base_time = @as(i128, std.time.nanoTimestamp());
    {
        var file = try std.fs.cwd().openFile(path_d, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time, base_time);
    }
    {
        var file = try std.fs.cwd().openFile(path_c, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + std.time.ns_per_s, base_time + std.time.ns_per_s);
    }
    {
        var file = try std.fs.cwd().openFile(path_b, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (2 * std.time.ns_per_s), base_time + (2 * std.time.ns_per_s));
    }
    {
        var file = try std.fs.cwd().openFile(path_a, .{ .mode = .read_write });
        defer file.close();
        try file.updateTimes(base_time + (3 * std.time.ns_per_s), base_time + (3 * std.time.ns_per_s));
    }

    const latest = try sessions.scanLatestUsageWithSource(gpa, codex_home);
    try std.testing.expect(latest == null);
}
