const std = @import("std");
const common = @import("common.zig");

const PlanType = common.PlanType;
const AuthMode = common.AuthMode;
const AutoSwitchConfig = common.AutoSwitchConfig;
const ApiConfig = common.ApiConfig;
const ApiConfigParseResult = common.ApiConfigParseResult;
const LiveConfig = common.LiveConfig;
const RateLimitSnapshot = common.RateLimitSnapshot;
const RateLimitWindow = common.RateLimitWindow;
const RolloutSignature = common.RolloutSignature;
const CreditsSnapshot = common.CreditsSnapshot;
const defaultApiConfig = common.defaultApiConfig;

pub fn parsePlanType(s: []const u8) ?PlanType {
    if (std.mem.eql(u8, s, "free")) return .free;
    if (std.mem.eql(u8, s, "plus")) return .plus;
    if (std.mem.eql(u8, s, "prolite")) return .prolite;
    if (std.mem.eql(u8, s, "pro")) return .pro;
    if (std.mem.eql(u8, s, "team")) return .team;
    if (std.mem.eql(u8, s, "business")) return .business;
    if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
    if (std.mem.eql(u8, s, "edu")) return .edu;
    return .unknown;
}

pub fn parseAuthMode(s: []const u8) ?AuthMode {
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, s, "apikey")) return .apikey;
    return null;
}

pub fn parseUsage(allocator: std.mem.Allocator, v: std.json.Value) ?RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var snap = RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .plan_type = null };

    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parsePlanType(s),
            else => {},
        }
    }
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    return snap;
}

pub fn parseAutoSwitch(allocator: std.mem.Allocator, cfg: *AutoSwitchConfig, v: std.json.Value) void {
    _ = allocator;
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("enabled")) |enabled| {
        switch (enabled) {
            .bool => |flag| cfg.enabled = flag,
            else => {},
        }
    }
    if (obj.get("threshold_5h_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_5h_percent = value;
        }
    }
    if (obj.get("threshold_weekly_percent")) |threshold| {
        if (parseThresholdPercent(threshold)) |value| {
            cfg.threshold_weekly_percent = value;
        }
    }
}

pub fn parseApiConfig(cfg: *ApiConfig, v: std.json.Value) void {
    _ = parseApiConfigDetailed(cfg, v);
}

pub fn apiConfigNeedsRewrite(v: std.json.Value) bool {
    var cfg = defaultApiConfig();
    const result = parseApiConfigDetailed(&cfg, v);
    return !result.has_object or !result.has_usage or !result.has_account;
}

pub fn parseLiveConfig(cfg: *LiveConfig, v: std.json.Value) void {
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("interval_seconds")) |interval| {
        if (parseLiveIntervalSeconds(interval)) |value| {
            cfg.interval_seconds = value;
        }
    }
}

pub fn liveConfigNeedsRewrite(v: std.json.Value) bool {
    const obj = switch (v) {
        .object => |o| o,
        else => return true,
    };
    if (obj.get("interval_seconds")) |interval| {
        if (parseLiveIntervalSeconds(interval)) |_| {
            return false;
        }
    }
    return true;
}

pub fn parseApiConfigDetailed(cfg: *ApiConfig, v: std.json.Value) ApiConfigParseResult {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{},
    };
    var result = ApiConfigParseResult{ .has_object = true };
    if (obj.get("usage")) |usage| {
        switch (usage) {
            .bool => |flag| {
                cfg.usage = flag;
                result.has_usage = true;
            },
            else => {},
        }
    }
    if (obj.get("account")) |account| {
        switch (account) {
            .bool => |flag| {
                cfg.account = flag;
                result.has_account = true;
            },
            else => {},
        }
    }
    if (result.has_usage and !result.has_account) {
        cfg.account = cfg.usage;
    } else if (result.has_account and !result.has_usage) {
        cfg.usage = cfg.account;
    }
    return result;
}

pub fn parseRolloutSignature(allocator: std.mem.Allocator, v: std.json.Value) ?RolloutSignature {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const path = switch (obj.get("path") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const event_timestamp_ms = readInt(obj.get("event_timestamp_ms")) orelse return null;
    return .{
        .path = allocator.dupe(u8, path) catch return null,
        .event_timestamp_ms = event_timestamp_ms,
    };
}

pub fn parseWindow(v: std.json.Value) ?RateLimitWindow {
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
    return RateLimitWindow{ .used_percent = used_percent, .window_minutes = window_minutes, .resets_at = resets_at };
}

pub fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) ?CreditsSnapshot {
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
    return CreditsSnapshot{ .has_credits = has_credits, .unlimited = unlimited, .balance = balance };
}

pub fn readInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    switch (v.?) {
        .integer => |i| return i,
        else => return null,
    }
}

pub fn parseThresholdPercent(v: std.json.Value) ?u8 {
    const raw = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (raw < 1 or raw > 100) return null;
    return @as(u8, @intCast(raw));
}

pub fn parseLiveIntervalSeconds(v: std.json.Value) ?u16 {
    const raw = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (raw < common.min_live_refresh_interval_seconds or raw > common.max_live_refresh_interval_seconds) return null;
    return @as(u16, @intCast(raw));
}
