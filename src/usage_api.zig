const std = @import("std");
const builtin = @import("builtin");
const auth = @import("auth.zig");
const registry = @import("registry.zig");

pub const default_usage_endpoint = "https://chatgpt.com/backend-api/wham/usage";
const request_timeout_secs: []const u8 = "5";

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
    return if (builtin.os.tag == .windows)
        runPowerShellUsageCommand(allocator, endpoint, access_token, account_id)
    else
        runCurlUsageCommand(allocator, endpoint, access_token, account_id);
}

fn runCurlUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !UsageHttpResult {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);
    const account_header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{account_id});
    defer allocator.free(account_header);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--connect-timeout",
            request_timeout_secs,
            "--max-time",
            request_timeout_secs,
            "--write-out",
            "\n%{http_code}",
            "-H",
            authorization,
            "-H",
            account_header,
            "-H",
            "User-Agent: codex-auth",
            "-H",
            "Accept-Encoding: identity",
            endpoint,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const code = switch (result.term) {
        .Exited => |exit_code| exit_code,
        else => return error.RequestFailed,
    };
    if (code != 0) return curlTransportError(code);

    const parsed = parseCurlHttpOutput(result.stdout) orelse return error.CommandFailed;
    const owned_body = try allocator.dupe(u8, parsed.body);
    return .{
        .body = owned_body,
        .status_code = parsed.status_code,
    };
}

fn runPowerShellUsageCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !UsageHttpResult {
    const escaped_token = try escapePowerShellSingleQuoted(allocator, access_token);
    defer allocator.free(escaped_token);
    const escaped_account_id = try escapePowerShellSingleQuoted(allocator, account_id);
    defer allocator.free(escaped_account_id);
    const escaped_endpoint = try escapePowerShellSingleQuoted(allocator, endpoint);
    defer allocator.free(escaped_endpoint);

    const script = try std.fmt.allocPrint(
        allocator,
        "$headers = @{{ Authorization = 'Bearer {s}'; 'ChatGPT-Account-Id' = '{s}'; 'User-Agent' = 'codex-auth'; 'Accept-Encoding' = 'identity' }}; $status = 0; $body = ''; try {{ $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec {s} -Headers $headers -Uri '{s}'; $status = [int]$response.StatusCode; $body = [string]$response.Content }} catch {{ if ($_.Exception.Response) {{ $status = [int]$_.Exception.Response.StatusCode.value__; $stream = $_.Exception.Response.GetResponseStream(); if ($stream) {{ $reader = New-Object System.IO.StreamReader($stream); try {{ $body = $reader.ReadToEnd() }} finally {{ $reader.Dispose() }} }} }} }}; [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))); [Console]::Out.Write(\"`n\"); [Console]::Out.Write($status)",
        .{ escaped_token, escaped_account_id, request_timeout_secs, escaped_endpoint },
    );
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            script,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => {},
        else => {
            allocator.free(result.stdout);
            return error.RequestFailed;
        },
    }
    const parsed = parsePowerShellHttpOutput(allocator, result.stdout) orelse {
        allocator.free(result.stdout);
        return error.CommandFailed;
    };
    allocator.free(result.stdout);
    if (parsed.status_code == null and parsed.body.len == 0) {
        allocator.free(parsed.body);
        return error.RequestFailed;
    }
    return parsed;
}

fn curlTransportError(exit_code: u8) anyerror {
    return switch (exit_code) {
        28 => error.TimedOut,
        else => error.RequestFailed,
    };
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

fn parseCurlHttpOutput(output: []const u8) ?ParsedCurlHttpOutput {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const newline_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const code_slice = std.mem.trim(u8, trimmed[newline_idx + 1 ..], " \r\t");
    if (code_slice.len == 0) return null;
    const status = std.fmt.parseInt(u16, code_slice, 10) catch return null;
    const body = std.mem.trimRight(u8, trimmed[0..newline_idx], "\r");
    return .{
        .body = body,
        .status_code = if (status == 0) null else status,
    };
}

fn parsePowerShellHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?UsageHttpResult {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const newline_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const encoded_body = std.mem.trim(u8, trimmed[0..newline_idx], " \r\t");
    const code_slice = std.mem.trim(u8, trimmed[newline_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, code_slice, 10) catch return null;
    const decoded_body = decodeBase64Alloc(allocator, encoded_body) catch return null;
    return .{
        .body = decoded_body,
        .status_code = if (status == 0) null else status,
    };
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    try decoder.decode(buf, input);
    return buf;
}
