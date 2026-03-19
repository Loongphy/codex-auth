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
const missing_primary_used_percent_line = "{" ++
    "\"timestamp\":\"2025-01-01T00:00:02Z\"," ++
    "\"type\":\"event_msg\"," ++
    "\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"window_minutes\":300,\"resets_at\":123},\"secondary\":{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456},\"plan_type\":\"pro\"}}}";

fn usageLineAlloc(allocator: std.mem.Allocator, timestamp: []const u8, used_percent: f64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"timestamp\":\"{s}\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"rate_limits\":{{\"primary\":{{\"used_percent\":{d:.1},\"window_minutes\":300,\"resets_at\":123}},\"secondary\":{{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456}},\"plan_type\":\"pro\"}}}}}}",
        .{ timestamp, used_percent },
    );
}

fn usageLineWithLargeBalanceAlloc(
    allocator: std.mem.Allocator,
    timestamp: []const u8,
    used_percent: f64,
    balance_len: usize,
) ![]u8 {
    const balance = try allocator.alloc(u8, balance_len);
    defer allocator.free(balance);
    @memset(balance, '9');
    return std.fmt.allocPrint(
        allocator,
        "{{\"timestamp\":\"{s}\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"rate_limits\":{{\"primary\":{{\"used_percent\":{d:.1},\"window_minutes\":300,\"resets_at\":123}},\"secondary\":{{\"used_percent\":10.0,\"window_minutes\":10080,\"resets_at\":456}},\"credits\":{{\"has_credits\":true,\"unlimited\":false,\"balance\":\"{s}\"}},\"plan_type\":\"pro\"}}}}}}",
        .{ timestamp, used_percent, balance },
    );
}

fn updateFileTimes(path: []const u8, atime: i128, mtime: i128) !void {
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    try file.updateTimes(atime, mtime);
}

fn writeLargeRolloutFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    target_bytes: usize,
    trailer_line: []const u8,
) !void {
    var file = try dir.createFile(sub_path, .{});
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    const writer = &file_writer.interface;
    var written: usize = 0;
    const filler_len = 900 * 1024;
    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    @memset(filler, 'x');

    while (written < target_bytes) {
        try writer.writeAll(filler);
        try writer.writeByte('\n');
        written += filler.len + 1;
    }
    try writer.writeAll(trailer_line);
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeOversizedMalformedLineThenTrailer(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    oversized_line_bytes: usize,
    trailer_line: []const u8,
) !void {
    var file = try dir.createFile(sub_path, .{});
    defer file.close();

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    const writer = &file_writer.interface;
    const chunk_len = 900 * 1024;
    const chunk = try allocator.alloc(u8, chunk_len);
    defer allocator.free(chunk);
    @memset(chunk, 'x');

    var written: usize = 0;
    while (written < oversized_line_bytes) {
        const next = @min(chunk.len, oversized_line_bytes - written);
        try writer.writeAll(chunk[0..next]);
        written += next;
    }
    try writer.writeByte('\n');
    try writer.writeAll(trailer_line);
    try writer.writeByte('\n');
    try writer.flush();
}

test "parse token_count usage" {
    const gpa = std.testing.allocator;
    const snap = sessions.parseUsageLine(gpa, line) orelse return error.TestExpectedEqual;
    try std.testing.expect(snap.primary != null);
    try std.testing.expect(snap.secondary != null);
}

test "parse token_count usage ignores windows missing used_percent" {
    const gpa = std.testing.allocator;
    const snap = sessions.parseUsageLine(gpa, missing_primary_used_percent_line) orelse return error.TestExpectedEqual;
    try std.testing.expect(snap.primary == null);
    try std.testing.expect(snap.secondary != null);
    try std.testing.expectEqual(@as(f64, 10.0), snap.secondary.?.used_percent);
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

test "scan latest usage streams rollout files larger than ten megabytes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const large_line = try usageLineAlloc(gpa, "2025-01-01T00:00:11.000Z", 42.0);
    defer gpa.free(large_line);
    try writeLargeRolloutFile(gpa, tmp.dir, "sessions/2025/01/01/rollout-large.jsonl", 11 * 1024 * 1024, large_line);

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings("rollout-large.jsonl", std.fs.path.basename(latest.path));
    try std.testing.expectEqual(@as(i64, 1735689611000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 42.0), latest.snapshot.primary.?.used_percent);
}

test "scan latest usage keeps final line without trailing newline" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const final_line = try usageLineAlloc(gpa, "2025-01-01T00:00:12.000Z", 33.0);
    defer gpa.free(final_line);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2025/01/01/rollout-no-newline.jsonl", .data = final_line });

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings("rollout-no-newline.jsonl", std.fs.path.basename(latest.path));
    try std.testing.expectEqual(@as(i64, 1735689612000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 33.0), latest.snapshot.primary.?.used_percent);
}

test "scan latest usage accepts valid token_count lines above one megabyte" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const large_line = try usageLineWithLargeBalanceAlloc(gpa, "2025-01-01T00:00:13.000Z", 27.0, 2 * 1024 * 1024);
    defer gpa.free(large_line);
    const file_contents = try std.fmt.allocPrint(gpa, "{s}\n", .{large_line});
    defer gpa.free(file_contents);
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2025/01/01/rollout-large-line.jsonl", .data = file_contents });

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings("rollout-large-line.jsonl", std.fs.path.basename(latest.path));
    try std.testing.expectEqual(@as(i64, 1735689613000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 27.0), latest.snapshot.primary.?.used_percent);
    try std.testing.expect(latest.snapshot.credits != null);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), latest.snapshot.credits.?.balance.?.len);
}

test "scan latest usage skips oversized malformed lines and keeps later valid events" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("sessions/2025/01/01");

    const valid_line = try usageLineAlloc(gpa, "2025-01-01T00:00:14.000Z", 64.0);
    defer gpa.free(valid_line);
    try writeOversizedMalformedLineThenTrailer(
        gpa,
        tmp.dir,
        "sessions/2025/01/01/rollout-oversized-line.jsonl",
        11 * 1024 * 1024,
        valid_line,
    );

    var latest = (try sessions.scanLatestUsageWithSource(gpa, codex_home)) orelse return error.TestExpectedEqual;
    defer latest.deinit(gpa);

    try std.testing.expectEqualStrings("rollout-oversized-line.jsonl", std.fs.path.basename(latest.path));
    try std.testing.expectEqual(@as(i64, 1735689614000), latest.event_timestamp_ms);
    try std.testing.expect(latest.snapshot.primary != null);
    try std.testing.expectEqual(@as(f64, 64.0), latest.snapshot.primary.?.used_percent);
}
