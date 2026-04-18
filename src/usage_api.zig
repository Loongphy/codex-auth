const std = @import("std");
const fs = @import("compat_fs.zig");
const auth = @import("auth.zig");
const chatgpt_http = @import("chatgpt_http.zig");
const registry = @import("registry.zig");

pub const default_usage_endpoint = "https://chatgpt.com/backend-api/wham/usage";

pub const UsageFetchResult = struct {
    snapshot: ?registry.RateLimitSnapshot,
    status_code: ?u16,
    missing_auth: bool = false,
};

const UsageHttpResult = struct {
    body: []u8,
    status_code: ?u16,
};

const ParsedCurlHttpOutput = struct {
    body: []const u8,
    status_code: ?u16,
};

pub fn fetchActiveUsage(allocator: std.mem.Allocator, codex_home: []const u8) !?registry.RateLimitSnapshot {
    const result = try fetchActiveUsageDetailed(allocator, codex_home);
    return result.snapshot;
}

pub fn fetchActiveUsageDetailed(allocator: std.mem.Allocator, codex_home: []const u8) !UsageFetchResult {
    const auth_path = try registry.activeAuthPath(allocator, codex_home);
    defer allocator.free(auth_path);

    return try fetchUsageForAuthPathDetailed(allocator, auth_path);
}

pub fn fetchUsageForAuthPath(allocator: std.mem.Allocator, auth_path: []const u8) !?registry.RateLimitSnapshot {
    const result = try fetchUsageForAuthPathDetailed(allocator, auth_path);
    return result.snapshot;
}

pub fn fetchUsageForAuthPathDetailed(allocator: std.mem.Allocator, auth_path: []const u8) !UsageFetchResult {
    const info = try auth.parseAuthInfo(allocator, auth_path);
    defer info.deinit(allocator);

    if (info.auth_mode != .chatgpt) return .{ .snapshot = null, .status_code = null, .missing_auth = true };
    const access_token = info.access_token orelse return .{ .snapshot = null, .status_code = null, .missing_auth = true };
    const chatgpt_account_id = info.chatgpt_account_id orelse return .{ .snapshot = null, .status_code = null, .missing_auth = true };

    return try fetchUsageForTokenDetailed(allocator, default_usage_endpoint, access_token, chatgpt_account_id);
}

pub fn fetchUsageForToken(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !?registry.RateLimitSnapshot {
    const result = try fetchUsageForTokenDetailed(allocator, endpoint, access_token, account_id);
    return result.snapshot;
}

pub fn fetchUsageForTokenDetailed(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !UsageFetchResult {
    const http_result = try runUsageCommand(allocator, endpoint, access_token, account_id);
    defer allocator.free(http_result.body);
    if (http_result.body.len == 0) {
        return .{ .snapshot = null, .status_code = http_result.status_code };
    }

    return .{
        .snapshot = try parseUsageResponse(allocator, http_result.body),
        .status_code = http_result.status_code,
    };
}

pub fn parseUsageResponse(allocator: std.mem.Allocator, body: []const u8) !?registry.RateLimitSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    var snapshot = registry.RateLimitSnapshot{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };

    if (root_obj.get("plan_type")) |plan_type| {
        snapshot.plan_type = parsePlanType(plan_type);
    }
    if (root_obj.get("credits")) |credits| {
        snapshot.credits = try parseCredits(allocator, credits);
    }
    if (root_obj.get("rate_limit")) |rate_limit| {
        switch (rate_limit) {
            .object => |obj| {
                if (obj.get("primary_window")) |window| {
                    snapshot.primary = parseWindow(window);
                }
                if (obj.get("secondary_window")) |window| {
                    snapshot.secondary = parseWindow(window);
                }
            },
            else => {},
        }
    }

    if (snapshot.primary == null and snapshot.secondary == null) {
        if (snapshot.credits) |*credits| {
            if (credits.balance) |balance| allocator.free(balance);
        }
        return null;
    }

    return snapshot;
}

fn parseWindow(v: std.json.Value) ?registry.RateLimitWindow {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    const used_percent = if (obj.get("used_percent")) |used| switch (used) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return null,
    } else return null;

    const window_minutes = if (obj.get("limit_window_seconds")) |seconds| switch (seconds) {
        .integer => |value| ceilMinutes(value),
        else => null,
    } else null;
    const resets_at = if (obj.get("reset_at")) |reset_at| switch (reset_at) {
        .integer => |value| value,
        else => null,
    } else null;

    return .{
        .used_percent = used_percent,
        .window_minutes = window_minutes,
        .resets_at = resets_at,
    };
}

fn parseCredits(allocator: std.mem.Allocator, v: std.json.Value) !?registry.CreditsSnapshot {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };

    const has_credits = if (obj.get("has_credits")) |value| switch (value) {
        .bool => |b| b,
        else => false,
    } else false;
    const unlimited = if (obj.get("unlimited")) |value| switch (value) {
        .bool => |b| b,
        else => false,
    } else false;
    const balance = if (obj.get("balance")) |value| switch (value) {
        .string => |s| if (s.len == 0) null else try allocator.dupe(u8, s),
        else => null,
    } else null;

    return .{
        .has_credits = has_credits,
        .unlimited = unlimited,
        .balance = balance,
    };
}

fn parsePlanType(v: std.json.Value) ?registry.PlanType {
    const plan_name = switch (v) {
        .string => |s| s,
        else => return null,
    };

    if (std.ascii.eqlIgnoreCase(plan_name, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(plan_name, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(plan_name, "prolite")) return .prolite;
    if (std.ascii.eqlIgnoreCase(plan_name, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(plan_name, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(plan_name, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(plan_name, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(plan_name, "edu")) return .edu;
    return .unknown;
}

fn ceilMinutes(seconds: i64) ?i64 {
    if (seconds <= 0) return null;
    return @divTrunc(seconds + 59, 60);
}

fn runUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !UsageHttpResult {
    const result = try chatgpt_http.runGetJsonCommand(allocator, endpoint, access_token, account_id);
    return .{
        .body = result.body,
        .status_code = result.status_code,
    };
}
