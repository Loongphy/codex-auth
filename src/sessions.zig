const std = @import("std");
const registry = @import("registry.zig");

pub const LatestUsage = struct {
    path: []u8,
    mtime: i64,
    event_timestamp_ms: i64,
    snapshot: registry.RateLimitSnapshot,

    pub fn deinit(self: *LatestUsage, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        registry.freeRateLimitSnapshot(allocator, &self.snapshot);
    }
};

const RolloutCandidate = struct {
    path: []u8,
    mtime: i64,
};

const ParsedUsageEvent = struct {
    event_timestamp_ms: i64,
    snapshot: registry.RateLimitSnapshot,
};

const max_recent_rollout_files: usize = 1;

pub fn scanLatestUsage(allocator: std.mem.Allocator, codex_home: []const u8) !?registry.RateLimitSnapshot {
    const latest = try scanLatestUsageWithSource(allocator, codex_home);
    if (latest == null) return null;
    allocator.free(latest.?.path);
    return latest.?.snapshot;
}

pub fn scanLatestUsageWithSource(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestUsage {
    const sessions_root = try std.fs.path.join(allocator, &[_][]const u8{ codex_home, "sessions" });
    defer allocator.free(sessions_root);

    var candidates = std.ArrayList(RolloutCandidate).empty;
    defer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.path);
        }
        candidates.deinit(allocator);
    }

    var dir = try std.fs.cwd().openDir(sessions_root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isRolloutFile(entry.path)) continue;
        const stat = try dir.statFile(entry.path);
        const path = try std.fs.path.join(allocator, &[_][]const u8{ sessions_root, entry.path });
        errdefer allocator.free(path);
        try candidates.append(allocator, .{
            .path = path,
            .mtime = @intCast(stat.mtime),
        });
    }

    std.mem.sort(RolloutCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: RolloutCandidate, b: RolloutCandidate) bool {
            return a.mtime > b.mtime;
        }
    }.lessThan);

    var best: ?LatestUsage = null;
    const scan_count = @min(candidates.items.len, max_recent_rollout_files);

    for (candidates.items[0..scan_count]) |candidate| {
        const usage = try scanFileForUsage(allocator, candidate.path);
        if (usage == null) continue;

        const parsed = usage.?;
        const better = best == null or
            parsed.event_timestamp_ms > best.?.event_timestamp_ms or
            (parsed.event_timestamp_ms == best.?.event_timestamp_ms and candidate.mtime > best.?.mtime);

        if (!better) {
            var skipped = parsed;
            registry.freeRateLimitSnapshot(allocator, &skipped.snapshot);
            continue;
        }

        if (best) |*prev| {
            allocator.free(prev.path);
            registry.freeRateLimitSnapshot(allocator, &prev.snapshot);
        }

        const path = allocator.dupe(u8, candidate.path) catch |err| {
            var failed = parsed;
            registry.freeRateLimitSnapshot(allocator, &failed.snapshot);
            return err;
        };
        best = .{
            .path = path,
            .mtime = candidate.mtime,
            .event_timestamp_ms = parsed.event_timestamp_ms,
            .snapshot = parsed.snapshot,
        };
    }

    return best;
}

fn scanFileForUsage(allocator: std.mem.Allocator, path: []const u8) !?ParsedUsageEvent {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    var last: ?ParsedUsageEvent = null;

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (parseUsageEventLine(allocator, trimmed)) |event| {
            if (last) |*prev| {
                registry.freeRateLimitSnapshot(allocator, &prev.snapshot);
            }
            last = event;
        }
    }
    return last;
}

pub fn parseUsageLine(allocator: std.mem.Allocator, line: []const u8) ?registry.RateLimitSnapshot {
    const event = parseUsageEventLine(allocator, line) orelse return null;
    return event.snapshot;
}

fn parseUsageEventLine(allocator: std.mem.Allocator, line: []const u8) ?ParsedUsageEvent {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const t = root_obj.get("type") orelse return null;
    const tstr = switch (t) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, tstr, "event_msg")) return null;
    const ts = root_obj.get("timestamp") orelse return null;
    const timestamp = switch (ts) {
        .string => |s| s,
        else => return null,
    };
    const event_timestamp_ms = parseTimestampMs(timestamp) orelse return null;
    const payload = root_obj.get("payload") orelse return null;
    const pobj = switch (payload) {
        .object => |o| o,
        else => return null,
    };
    const ptype = pobj.get("type") orelse return null;
    const pstr = switch (ptype) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, pstr, "token_count")) return null;
    const rate_limits = pobj.get("rate_limits") orelse return null;

    const snapshot = parseRateLimits(allocator, rate_limits) orelse return null;
    return .{
        .event_timestamp_ms = event_timestamp_ms,
        .snapshot = snapshot,
    };
}

fn parseRateLimits(allocator: std.mem.Allocator, v: std.json.Value) ?registry.RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    var snap = registry.RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parsePlanType(s),
            else => {},
        }
    }
    return snap;
}

fn parseWindow(v: std.json.Value) ?registry.RateLimitWindow {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const used = obj.get("used_percent") orelse return null;
    const used_percent = switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };
    const window_minutes = if (obj.get("window_minutes")) |wm| switch (wm) {
        .integer => |i| i,
        else => null,
    } else null;
    const resets_at = if (obj.get("resets_at")) |ra| switch (ra) {
        .integer => |i| i,
        else => null,
    } else null;
    return registry.RateLimitWindow{ .used_percent = used_percent, .window_minutes = window_minutes, .resets_at = resets_at };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) ?registry.CreditsSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const has_credits = if (obj.get("has_credits")) |hc| switch (hc) {
        .bool => |b| b,
        else => false,
    } else false;
    const unlimited = if (obj.get("unlimited")) |u| switch (u) {
        .bool => |b| b,
        else => false,
    } else false;
    var balance: ?[]u8 = null;
    if (obj.get("balance")) |b| {
        switch (b) {
            .string => |s| balance = allocator.dupe(u8, s) catch null,
            else => {},
        }
    }
    return registry.CreditsSnapshot{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

fn parsePlanType(s: []const u8) registry.PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(s, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

fn parseTimestampMs(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;

    const year = parseDecimal(s[0..4]) orelse return null;
    const month = parseDecimal(s[5..7]) orelse return null;
    const day = parseDecimal(s[8..10]) orelse return null;
    const hour = parseDecimal(s[11..13]) orelse return null;
    const minute = parseDecimal(s[14..16]) orelse return null;
    const second = parseDecimal(s[17..19]) orelse return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    var idx: usize = 19;
    var millis: i64 = 0;
    if (idx < s.len and s[idx] == '.') {
        idx += 1;
        const frac_start = idx;
        while (idx < s.len and std.ascii.isDigit(s[idx])) : (idx += 1) {}
        if (idx == frac_start) return null;

        const frac_len = idx - frac_start;
        const use_len = @min(frac_len, 3);
        millis = parseDecimal(s[frac_start .. frac_start + use_len]) orelse return null;
        if (use_len == 1) millis *= 100 else if (use_len == 2) millis *= 10;
    }

    if (idx >= s.len or s[idx] != 'Z' or idx + 1 != s.len) return null;

    const days = daysFromCivil(year, month, day);
    return (((days * 24) + hour) * 60 + minute) * 60 * 1000 + second * 1000 + millis;
}

fn parseDecimal(slice: []const u8) ?i64 {
    if (slice.len == 0) return null;
    var value: i64 = 0;
    for (slice) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        value = value * 10 + (ch - '0');
    }
    return value;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const adjusted_year = year - (if (month <= 2) @as(i64, 1) else 0);
    const era = @divFloor(if (adjusted_year >= 0) adjusted_year else adjusted_year - 399, 400);
    const year_of_era = adjusted_year - era * 400;
    const month_prime = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn isRolloutFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "rollout-");
}
