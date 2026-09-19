const std = @import("std");
const common = @import("common.zig");

const PlanType = common.PlanType;
const AuthMode = common.AuthMode;
const LiveConfig = common.LiveConfig;
const RateLimitSnapshot = common.RateLimitSnapshot;
const RateLimitWindow = common.RateLimitWindow;
const RolloutSignature = common.RolloutSignature;
const CreditsSnapshot = common.CreditsSnapshot;
const RateLimitResetCredit = common.RateLimitResetCredit;
const RateLimitResetCredits = common.RateLimitResetCredits;

pub fn normalizePlanType(s: []const u8) PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "prolite")) return .prolite;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "team") or
        std.ascii.eqlIgnoreCase(s, "self_serve_business_usage_based")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "business") or
        std.ascii.eqlIgnoreCase(s, "enterprise_cbp_usage_based") or
        std.ascii.eqlIgnoreCase(s, "enterprise") or
        std.ascii.eqlIgnoreCase(s, "hc")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "education") or std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

pub fn parseStoredPlanType(s: []const u8, schema_version: u32) PlanType {
    if (schema_version < 4) return normalizePlanType(s);

    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "prolite")) return .prolite;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

pub fn parseAuthMode(s: []const u8) ?AuthMode {
    if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
    if (std.mem.eql(u8, s, "apikey")) return .apikey;
    return null;
}

pub fn parseUsage(allocator: std.mem.Allocator, v: std.json.Value, schema_version: u32) ?RateLimitSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var snap = RateLimitSnapshot{ .primary = null, .secondary = null, .credits = null, .reset_credits = null, .reset_credit_details = null, .plan_type = null };

    if (obj.get("plan_type")) |p| {
        switch (p) {
            .string => |s| snap.plan_type = parseStoredPlanType(s, schema_version),
            else => {},
        }
    }
    if (obj.get("primary")) |p| snap.primary = parseWindow(p);
    if (obj.get("secondary")) |p| snap.secondary = parseWindow(p);
    if (obj.get("credits")) |c| snap.credits = parseCredits(allocator, c);
    snap.reset_credits = readInt(obj.get("reset_credits"));
    if (obj.get("reset_credit_details")) |details| {
        snap.reset_credit_details = parseResetCreditDetails(allocator, details) catch null;
    }
    return snap;
}

pub fn parseResetCreditDetails(allocator: std.mem.Allocator, v: std.json.Value) !?RateLimitResetCredits {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const available_count = readInt(obj.get("available_count")) orelse return null;
    const total_earned_count = readInt(obj.get("total_earned_count"));
    var credits = std.ArrayList(RateLimitResetCredit).empty;
    errdefer {
        for (credits.items) |credit| common.freeRateLimitResetCredit(allocator, credit);
        credits.deinit(allocator);
    }
    if (obj.get("credits")) |credits_value| {
        const items = switch (credits_value) {
            .array => |array| array.items,
            else => return null,
        };
        for (items) |item| {
            const item_obj = switch (item) {
                .object => |item_obj| item_obj,
                else => continue,
            };
            const credit = try parseResetCredit(allocator, item_obj) orelse continue;
            credits.append(allocator, credit) catch |err| {
                common.freeRateLimitResetCredit(allocator, credit);
                return err;
            };
        }
    }
    return .{
        .available_count = available_count,
        .total_earned_count = total_earned_count,
        .credits = try credits.toOwnedSlice(allocator),
    };
}

fn parseResetCredit(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?RateLimitResetCredit {
    const id = try requiredStringAlloc(allocator, obj.get("id")) orelse return null;
    errdefer allocator.free(id);
    const reset_type = try requiredStringAlloc(allocator, obj.get("reset_type")) orelse {
        allocator.free(id);
        return null;
    };
    errdefer allocator.free(reset_type);
    const status = try requiredStringAlloc(allocator, obj.get("status")) orelse {
        allocator.free(id);
        allocator.free(reset_type);
        return null;
    };
    errdefer allocator.free(status);
    const granted_at = try requiredStringAlloc(allocator, obj.get("granted_at")) orelse {
        allocator.free(id);
        allocator.free(reset_type);
        allocator.free(status);
        return null;
    };
    errdefer allocator.free(granted_at);
    const expires_at = try parseOptionalStoredStringAlloc(allocator, obj.get("expires_at"));
    errdefer if (expires_at) |value| allocator.free(value);
    const title = try parseOptionalStoredStringAlloc(allocator, obj.get("title"));
    errdefer if (title) |value| allocator.free(value);
    const description = try parseOptionalStoredStringAlloc(allocator, obj.get("description"));
    errdefer if (description) |value| allocator.free(value);
    return .{
        .id = id,
        .reset_type = reset_type,
        .status = status,
        .granted_at = granted_at,
        .expires_at = expires_at,
        .title = title,
        .description = description,
    };
}

fn requiredStringAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const text = switch (value orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return try allocator.dupe(u8, text);
}

fn parseOptionalStoredStringAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const text = switch (value orelse return null) {
        .string => |s| s,
        .null => return null,
        else => return null,
    };
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
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
        .number_string, .string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
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
