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

fn updateFileTimes(path: []const u8, atime: i128, mtime: i128) !void {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.updateTimes(atime, mtime);
}

test "parse token_count usage" {
    const gpa = std.testing.allocator;
    const snap = sessions.parseUsageLine(gpa, line) orelse return error.TestExpectedEqual;
    try std.testing.expect(snap.primary != null);
    try std.testing.expect(snap.secondary != null);
}

test "scan latest usage chooses newest valid event from the most recent rollout file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const names = [_][]const u8{
        "rollout-a.jsonl",
        "rollout-b.jsonl",
        "rollout-c.jsonl",
        "rollout-d.jsonl",
        "rollout-e.jsonl",
        "rollout-f.jsonl",
        "rollout-g.jsonl",
        "rollout-h.jsonl",
        "rollout-i.jsonl",
        "rollout-j.jsonl",
    };
    var paths: [names.len][]u8 = undefined;
    var initialized: usize = 0;
    defer for (paths[0..initialized]) |path| gpa.free(path);

    for (names, 0..) |name, idx| {
        paths[idx] = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", name });
        initialized = idx + 1;
    }

    const newer_valid = try usageLineAlloc(gpa, "2025-01-01T00:00:09.000Z", 90.0);
    defer gpa.free(newer_valid);
    const older_valid = try usageLineAlloc(gpa, "2025-01-01T00:00:07.000Z", 70.0);
    defer gpa.free(older_valid);

    try std.fs.cwd().writeFile(.{ .sub_path = paths[0], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[1], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[2], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[3], .data = older_valid });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[4], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[5], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[6], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[7], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[8], .data = null_rate_limits_line ++ "\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = paths[9], .data = newer_valid });

    const base_time = @as(i128, std.time.nanoTimestamp());
    for (paths, 0..) |path, idx| {
        const ts = base_time + (@as(i128, @intCast(idx)) * std.time.ns_per_s);
        try updateFileTimes(path, ts, ts);
    }

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings(paths[9], latest.path);
    try std.testing.expectEqual(@as(i64, 1735689609000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 90.0), latest.snapshot.primary.?.used_percent);
}

test "scan latest usage ignores rollout files beyond the most recent file" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const names = [_][]const u8{
        "rollout-a.jsonl",
        "rollout-b.jsonl",
        "rollout-c.jsonl",
        "rollout-d.jsonl",
        "rollout-e.jsonl",
        "rollout-f.jsonl",
        "rollout-g.jsonl",
        "rollout-h.jsonl",
        "rollout-i.jsonl",
        "rollout-j.jsonl",
        "rollout-k.jsonl",
    };
    var paths: [names.len][]u8 = undefined;
    var initialized: usize = 0;
    defer for (paths[0..initialized]) |path| gpa.free(path);

    for (names, 0..) |name, idx| {
        paths[idx] = try std.fs.path.join(gpa, &[_][]const u8{ codex_home, "sessions", "2025", "01", "01", name });
        initialized = idx + 1;
    }

    const older_valid = try usageLineAlloc(gpa, "2025-01-01T00:00:09.000Z", 90.0);
    defer gpa.free(older_valid);
    for (paths[0 .. paths.len - 1]) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = null_rate_limits_line ++ "\n" });
    }
    try std.fs.cwd().writeFile(.{ .sub_path = paths[paths.len - 1], .data = older_valid });

    const base_time = @as(i128, std.time.nanoTimestamp());
    try updateFileTimes(paths[paths.len - 1], base_time, base_time);
    for (paths[0 .. paths.len - 1], 0..) |path, idx| {
        const ts = base_time + (@as(i128, @intCast(idx + 1)) * std.time.ns_per_s);
        try updateFileTimes(path, ts, ts);
    }

    const latest = try sessions.scanLatestUsageWithSource(gpa, codex_home);
    try std.testing.expect(latest == null);
}
