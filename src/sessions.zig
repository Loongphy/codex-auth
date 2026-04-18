const builtin = @import("builtin");
const std = @import("std");
const time_compat = @import("compat_time.zig");
const fs = @import("compat_fs.zig");
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

pub const LatestRolloutEvent = struct {
    path: []u8,
    mtime: i64,
    event_timestamp_ms: i64,
    snapshot: ?registry.RateLimitSnapshot,

    pub fn deinit(self: *LatestRolloutEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.snapshot) |*snapshot| {
            registry.freeRateLimitSnapshot(allocator, snapshot);
        }
    }

    pub fn hasUsableWindows(self: LatestRolloutEvent) bool {
        if (self.snapshot) |snapshot| {
            return snapshot.primary != null or snapshot.secondary != null;
        }
        return false;
    }
};

const RolloutCandidate = struct {
    path: []u8,
    mtime: i64,
};

const ParsedUsageEvent = struct {
    event_timestamp_ms: i64,
    snapshot: ?registry.RateLimitSnapshot,
};

const UsageEventLineJson = struct {
    timestamp: []const u8 = "",
    type: []const u8 = "",
    payload: UsagePayloadJson = .{},
};

const UsagePayloadJson = struct {
    type: []const u8 = "",
    rate_limits: ?UsageRateLimitsJson = null,
};

const UsageRateLimitsJson = struct {
    primary: ?UsageWindowJson = null,
    secondary: ?UsageWindowJson = null,
    credits: ?UsageCreditsJson = null,
    plan_type: ?[]const u8 = null,
};

const UsageWindowJson = struct {
    used_percent: ?std.json.Value = null,
    window_minutes: ?i64 = null,
    resets_at: ?i64 = null,
};

const UsageCreditsJson = struct {
    has_credits: bool = false,
    unlimited: bool = false,
    balance: ?[]const u8 = null,
};

const max_rollout_line_bytes: usize = 10 * 1024 * 1024;
const rollout_full_rescan_interval_ns = 15 * time_compat.ns_per_s;

pub const RolloutScanCache = struct {
    last_full_scan_at_ns: i128 = 0,
    latest: ?LatestRolloutEvent = null,

    pub fn deinit(self: *RolloutScanCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    fn clear(self: *RolloutScanCache, allocator: std.mem.Allocator) void {
        if (self.latest) |*latest| {
            latest.deinit(allocator);
        }
        self.latest = null;
        self.last_full_scan_at_ns = 0;
    }

    fn replace(self: *RolloutScanCache, allocator: std.mem.Allocator, latest: ?LatestRolloutEvent, scanned_at_ns: i128) void {
        if (self.latest) |*cached| {
            cached.deinit(allocator);
        }
        self.latest = latest;
        self.last_full_scan_at_ns = scanned_at_ns;
    }

    fn cloneLatest(self: *const RolloutScanCache, allocator: std.mem.Allocator) !?LatestRolloutEvent {
        if (self.latest) |latest| {
            return try cloneLatestRolloutEvent(allocator, latest);
        }
        return null;
    }
};

pub fn scanLatestUsage(allocator: std.mem.Allocator, codex_home: []const u8) !?registry.RateLimitSnapshot {
    const latest = try scanLatestUsageWithSource(allocator, codex_home);
    if (latest == null) return null;
    allocator.free(latest.?.path);
    return latest.?.snapshot;
}

pub fn scanLatestUsageWithSource(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestUsage {
    var latest_rollout = (try scanLatestRolloutEventWithSource(allocator, codex_home)) orelse return null;
    errdefer latest_rollout.deinit(allocator);
    if (!latest_rollout.hasUsableWindows()) {
        const latest_usable = try scanLatestUsableUsageInFile(allocator, latest_rollout.path, latest_rollout.mtime);
        if (latest_usable == null) {
            latest_rollout.deinit(allocator);
            return null;
        }
        latest_rollout.deinit(allocator);
        return latest_usable;
    }

    const snapshot = latest_rollout.snapshot.?;
    latest_rollout.snapshot = null;
    return .{
        .path = latest_rollout.path,
        .mtime = latest_rollout.mtime,
        .event_timestamp_ms = latest_rollout.event_timestamp_ms,
        .snapshot = snapshot,
    };
}

pub fn scanLatestUsableUsageInFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
) !?LatestUsage {
    var latest_usable = (try scanFileForLatestUsableUsage(allocator, path)) orelse return null;
    errdefer if (latest_usable.snapshot) |*snapshot| {
        registry.freeRateLimitSnapshot(allocator, snapshot);
    };

    const owned_path = try allocator.dupe(u8, path);
    const snapshot = latest_usable.snapshot.?;
    latest_usable.snapshot = null;
    return .{
        .path = owned_path,
        .mtime = mtime,
        .event_timestamp_ms = latest_usable.event_timestamp_ms,
        .snapshot = snapshot,
    };
}

pub fn scanLatestRolloutEventWithSource(allocator: std.mem.Allocator, codex_home: []const u8) !?LatestRolloutEvent {
    const sessions_root = try fs.path.join(allocator, &[_][]const u8{ codex_home, "sessions" });
    defer allocator.free(sessions_root);

    var latest_candidate: ?RolloutCandidate = null;
    defer if (latest_candidate) |candidate| {
        allocator.free(candidate.path);
    };

    var dir = try fs.cwd().openDir(sessions_root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isRolloutFile(entry.path)) continue;
        const stat = try dir.statFile(entry.path);
        const mtime: i64 = @intCast(stat.mtime.nanoseconds);
        if (latest_candidate) |candidate| {
            if (mtime <= candidate.mtime) continue;
        }
        const path = try fs.path.join(allocator, &[_][]const u8{ sessions_root, entry.path });
        errdefer allocator.free(path);
        if (latest_candidate) |candidate| {
            allocator.free(candidate.path);
        }
        latest_candidate = .{
            .path = path,
            .mtime = mtime,
        };
    }

    const candidate = latest_candidate orelse return null;
    const parsed = (try scanFileForUsage(allocator, candidate.path)) orelse return null;

    return .{
        .path = try allocator.dupe(u8, candidate.path),
        .mtime = candidate.mtime,
        .event_timestamp_ms = parsed.event_timestamp_ms,
        .snapshot = parsed.snapshot,
    };
}

pub fn scanLatestRolloutEventWithCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cache: *RolloutScanCache,
) !?LatestRolloutEvent {
    const now_ns = time_compat.nanoTimestamp();

    if (cache.latest) |cached| {
        const stat = fs.cwd().statFile(cached.path) catch |err| switch (err) {
            error.FileNotFound => return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns),
            else => return err,
        };
        const current_mtime: i64 = @intCast(stat.mtime.nanoseconds);
        if (current_mtime != cached.mtime) {
            const reparsed = try scanFileForUsage(allocator, cached.path);
            if (reparsed) |parsed| {
                const updated = try latestRolloutEventFromParsedUsage(allocator, cached.path, current_mtime, parsed);
                cache.replace(allocator, updated, cache.last_full_scan_at_ns);
                return try cache.cloneLatest(allocator);
            }
            return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns);
        }

        if (cache.last_full_scan_at_ns != 0 and (now_ns - cache.last_full_scan_at_ns) < rollout_full_rescan_interval_ns) {
            return try cache.cloneLatest(allocator);
        }
    }

    return try refreshRolloutScanCache(allocator, codex_home, cache, now_ns);
}

fn scanFileForUsage(allocator: std.mem.Allocator, path: []const u8) !?ParsedUsageEvent {
    return scanFileForUsageWithMode(allocator, path, true);
}

fn scanFileForLatestUsableUsage(allocator: std.mem.Allocator, path: []const u8) !?ParsedUsageEvent {
    return scanFileForUsageWithMode(allocator, path, false);
}

fn scanFileForUsageWithMode(allocator: std.mem.Allocator, path: []const u8, keep_latest_unusable: bool) !?ParsedUsageEvent {
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return null;
    if (comptime builtin.os.tag == .windows) {
        return scanFileForUsageStreaming(allocator, file, keep_latest_unusable);
    }

    var map = try file.createMemoryMap(.{
        .len = @intCast(stat.size),
        .protection = .{ .read = true, .write = false },
        .populate = false,
    });
    defer map.destroy(fs.io());

    return scanUsageEventSliceBackwards(allocator, map.memory, keep_latest_unusable);
}

fn scanFileForUsageStreaming(
    allocator: std.mem.Allocator,
    file: fs.File,
    keep_latest_unusable: bool,
) !?ParsedUsageEvent {
    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const reader = &file_reader.interface;
    var line_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer line_buffer.deinit();
    var last: ?ParsedUsageEvent = null;

    while (true) {
        line_buffer.clearRetainingCapacity();
        const line_len = reader.streamDelimiterLimit(
            &line_buffer.writer,
            '\n',
            .limited(max_rollout_line_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return file_reader.err orelse error.ReadFailed,
                };
                continue;
            },
            error.ReadFailed => return file_reader.err orelse error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };
        const line = line_buffer.written();
        const next_byte: ?u8 = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => return file_reader.err orelse error.ReadFailed,
        };
        if (next_byte) |byte| {
            std.debug.assert(byte == '\n');
            _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => unreachable,
                error.ReadFailed => return file_reader.err orelse error.ReadFailed,
            };
        } else if (line_len == 0) {
            break;
        }
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (parseUsageEventLine(allocator, trimmed)) |event| {
            if (!keep_latest_unusable and event.snapshot == null) {
                continue;
            }
            if (last) |*prev| {
                if (prev.snapshot) |*snapshot| {
                    registry.freeRateLimitSnapshot(allocator, snapshot);
                }
            }
            last = event;
        }
    }
    return last;
}

fn scanUsageEventSliceBackwards(
    allocator: std.mem.Allocator,
    contents: []const u8,
    keep_latest_unusable: bool,
) ?ParsedUsageEvent {
    var line_end = contents.len;

    while (line_end > 0) {
        const maybe_newline = std.mem.lastIndexOfScalar(u8, contents[0..line_end], '\n');
        const line_start = if (maybe_newline) |idx| idx + 1 else 0;
        const line = std.mem.trim(u8, contents[line_start..line_end], " \r\t");
        if (line.len != 0 and line.len <= max_rollout_line_bytes) {
            if (parseUsageEventLine(allocator, line)) |event| {
                if (keep_latest_unusable or event.snapshot != null) {
                    return event;
                }
            }
        }

        if (maybe_newline) |idx| {
            line_end = idx;
            continue;
        }
        break;
    }

    return null;
}

fn refreshRolloutScanCache(
    allocator: std.mem.Allocator,
    codex_home: []const u8,
    cache: *RolloutScanCache,
    scanned_at_ns: i128,
) !?LatestRolloutEvent {
    const latest = try scanLatestRolloutEventWithSource(allocator, codex_home);
    cache.replace(allocator, latest, scanned_at_ns);
    return try cache.cloneLatest(allocator);
}

fn latestRolloutEventFromParsedUsage(
    allocator: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
    parsed: ParsedUsageEvent,
) !LatestRolloutEvent {
    errdefer if (parsed.snapshot) |*snapshot| {
        registry.freeRateLimitSnapshot(allocator, snapshot);
    };
    return .{
        .path = try allocator.dupe(u8, path),
        .mtime = mtime,
        .event_timestamp_ms = parsed.event_timestamp_ms,
        .snapshot = parsed.snapshot,
    };
}

fn cloneLatestRolloutEvent(allocator: std.mem.Allocator, latest: LatestRolloutEvent) !LatestRolloutEvent {
    return .{
        .path = try allocator.dupe(u8, latest.path),
        .mtime = latest.mtime,
        .event_timestamp_ms = latest.event_timestamp_ms,
        .snapshot = if (latest.snapshot) |snapshot|
            try registry.cloneRateLimitSnapshot(allocator, snapshot)
        else
            null,
    };
}

pub fn parseUsageLine(allocator: std.mem.Allocator, line: []const u8) ?registry.RateLimitSnapshot {
    const event = parseUsageEventLine(allocator, line) orelse return null;
    return event.snapshot;
}

fn parseUsageEventLine(allocator: std.mem.Allocator, line: []const u8) ?ParsedUsageEvent {
    if (!looksLikeUsageEventLine(line)) return null;

    var parsed = std.json.parseFromSlice(UsageEventLineJson, allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (!std.mem.eql(u8, root.type, "event_msg")) return null;
    if (!std.mem.eql(u8, root.payload.type, "token_count")) return null;

    const event_timestamp_ms = parseTimestampMs(root.timestamp) orelse return null;
    const snapshot = if (root.payload.rate_limits) |rate_limits|
        parseRateLimits(allocator, rate_limits)
    else
        null;
    return .{
        .event_timestamp_ms = event_timestamp_ms,
        .snapshot = snapshot,
    };
}

fn looksLikeUsageEventLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"event_msg\"") != null and
        std.mem.indexOf(u8, line, "\"token_count\"") != null and
        std.mem.indexOf(u8, line, "\"rate_limits\"") != null and
        std.mem.indexOf(u8, line, "\"timestamp\"") != null;
}

fn parseRateLimits(allocator: std.mem.Allocator, parsed: UsageRateLimitsJson) ?registry.RateLimitSnapshot {
    var snap = registry.RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };
    if (parsed.primary) |p| snap.primary = parseWindow(p);
    if (parsed.secondary) |p| snap.secondary = parseWindow(p);
    if (parsed.credits) |c| snap.credits = parseCredits(allocator, c);
    if (parsed.plan_type) |p| snap.plan_type = parsePlanType(p);
    if (snap.primary == null and snap.secondary == null) {
        if (snap.credits) |*credits| {
            if (credits.balance) |balance| allocator.free(balance);
        }
        return null;
    }
    return snap;
}

fn parseWindow(parsed: UsageWindowJson) ?registry.RateLimitWindow {
    const used = parsed.used_percent orelse return null;
    const used_percent = switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => 0.0,
    };
    return .{
        .used_percent = used_percent,
        .window_minutes = parsed.window_minutes,
        .resets_at = parsed.resets_at,
    };
}

fn parseCredits(allocator: std.mem.Allocator, parsed: UsageCreditsJson) registry.CreditsSnapshot {
    var balance: ?[]u8 = null;
    if (parsed.balance) |b| {
        balance = allocator.dupe(u8, b) catch null;
    }
    return .{
        .has_credits = parsed.has_credits,
        .unlimited = parsed.unlimited,
        .balance = balance,
    };
}

fn parsePlanType(s: []const u8) registry.PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "prolite")) return .prolite;
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
    const base = fs.path.basename(path);
    return std.mem.startsWith(u8, base, "rollout-");
}
