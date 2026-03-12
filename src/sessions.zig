const std = @import("std");
const registry = @import("registry.zig");

pub const LatestUsage = struct {
    path: []u8,
    mtime: i64,
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
        try candidates.append(allocator, .{
            .path = try std.fs.path.join(allocator, &[_][]const u8{ sessions_root, entry.path }),
            .mtime = @intCast(stat.mtime),
        });
    }

    std.mem.sort(RolloutCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: RolloutCandidate, b: RolloutCandidate) bool {
            return a.mtime > b.mtime;
        }
    }.lessThan);

    if (candidates.items.len == 0) return null;

    const latest_idx: usize = 0;
    const snapshot = try scanFileForUsage(allocator, candidates.items[latest_idx].path);
    if (snapshot == null) return null;

    const path = candidates.items[latest_idx].path;
    const mtime = candidates.items[latest_idx].mtime;
    for (candidates.items, 0..) |other, idx| {
        if (idx != latest_idx) allocator.free(other.path);
    }
    candidates.clearRetainingCapacity();
    return .{
        .path = path,
        .mtime = mtime,
        .snapshot = snapshot.?,
    };
}

fn scanFileForUsage(allocator: std.mem.Allocator, path: []const u8) !?registry.RateLimitSnapshot {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    var last: ?registry.RateLimitSnapshot = null;

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (parseUsageLine(allocator, trimmed)) |snap| {
            if (last) |*prev| {
                registry.freeRateLimitSnapshot(allocator, prev);
            }
            last = snap;
        }
    }
    return last;
}

pub fn parseUsageLine(allocator: std.mem.Allocator, line: []const u8) ?registry.RateLimitSnapshot {
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

    return parseRateLimits(allocator, rate_limits);
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

fn isRolloutFile(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".jsonl")) return false;
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "rollout-");
}
