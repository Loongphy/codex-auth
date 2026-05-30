const std = @import("std");
const types = @import("http_types.zig");
const env = @import("http_env.zig");
const child = @import("http_child.zig");
const executable = @import("http_executable.zig");

const HttpResult = types.HttpResult;
const BatchRequest = types.BatchRequest;
const BatchHttpResult = types.BatchHttpResult;
const BatchItemResult = types.BatchItemResult;
const BatchItemOutcome = types.BatchItemOutcome;
const request_timeout_secs = types.request_timeout_secs;
const child_process_timeout_ms_value = types.child_process_timeout_ms_value;
const user_agent = types.user_agent;
const getEnvMap = env.getEnvMap;
const runChildCapture = child.runChildCapture;
const resolveCurlExecutableForLaunchAlloc = executable.resolveCurlExecutableForLaunchAlloc;

const CurlHttpOutput = struct {
    body: []u8,
    status_code: ?u16,
};

pub fn runGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    return runCurlGetJsonCommand(allocator, endpoint, access_token, account_id);
}

pub fn runBearerGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
) !HttpResult {
    return runCurlBearerGetJsonCommand(allocator, endpoint, access_token);
}

pub fn runGetJsonBatchCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    requests: []const BatchRequest,
    max_concurrency: usize,
) !BatchHttpResult {
    return runCurlGetJsonBatchCommand(allocator, endpoint, requests, max_concurrency);
}

pub fn ensureCurlExecutableAvailable(allocator: std.mem.Allocator) !void {
    const curl_executable = try resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl_executable);
}

pub fn resolveCurlExecutableAlloc(allocator: std.mem.Allocator) ![]u8 {
    return resolveCurlExecutableForLaunchAlloc(allocator);
}

fn runCurlBearerGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
) !HttpResult {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);

    return try runCurlJsonCommand(allocator, endpoint, &[_][]const u8{authorization});
}

fn runCurlGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);
    const account_header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{account_id});
    defer allocator.free(account_header);

    return try runCurlJsonCommand(allocator, endpoint, &[_][]const u8{ authorization, account_header });
}

fn runCurlJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    headers: []const []const u8,
) !HttpResult {
    const curl_executable = try resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl_executable);

    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const user_agent_header = "User-Agent: " ++ user_agent;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try appendCurlBaseArgs(allocator, &argv, curl_executable, user_agent_header);
    for (headers) |header| {
        try argv.append(allocator, "--header");
        try argv.append(allocator, header);
    }
    try argv.append(allocator, endpoint);

    const result = runChildCapture(
        allocator,
        argv.items,
        child_process_timeout_ms_value,
        &env_map,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => return error.CurlRequired,
        else => return err,
    };
    defer result.deinit(allocator);

    if (result.timed_out) return error.TimedOut;

    switch (result.term) {
        .exited => |code| if (code != 0) return error.RequestFailed,
        else => return error.RequestFailed,
    }

    const parsed = try parseCurlHttpOutput(allocator, result.stdout);
    return .{
        .body = parsed.body,
        .status_code = parsed.status_code,
    };
}

fn runCurlGetJsonBatchCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    requests: []const BatchRequest,
    max_concurrency: usize,
) !BatchHttpResult {
    _ = max_concurrency;
    const items = try allocator.alloc(BatchItemResult, requests.len);
    errdefer allocator.free(items);
    for (items) |*item| item.* = .{
        .body = &.{},
        .status_code = null,
        .outcome = .failed,
    };
    errdefer {
        for (items) |*item| {
            if (item.body.len != 0) allocator.free(item.body);
        }
    }

    for (requests, 0..) |request, idx| {
        const result = runCurlGetJsonCommand(
            allocator,
            endpoint,
            request.access_token,
            request.account_id,
        ) catch |err| {
            items[idx] = switch (err) {
                error.TimedOut => .{
                    .body = &.{},
                    .status_code = null,
                    .outcome = .timeout,
                },
                else => .{
                    .body = try allocator.dupe(u8, @errorName(err)),
                    .status_code = null,
                    .outcome = .failed,
                },
            };
            continue;
        };
        items[idx] = .{
            .body = result.body,
            .status_code = result.status_code,
            .outcome = .ok,
        };
    }

    return .{ .items = items };
}

fn appendCurlBaseArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    curl_executable: []const u8,
    user_agent_header: []const u8,
) !void {
    try argv.appendSlice(allocator, &.{
        curl_executable,
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        request_timeout_secs,
        "--output",
        "-",
        "--write-out",
        "\n%{http_code}",
        "--header",
        user_agent_header,
        "--header",
        "Accept: application/json",
    });
}

fn parseCurlHttpOutput(allocator: std.mem.Allocator, output: []const u8) !CurlHttpOutput {
    const trimmed = std.mem.trimEnd(u8, output, "\r\n");
    const status_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return error.CommandFailed;
    const status_slice = std.mem.trim(u8, trimmed[status_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, status_slice, 10) catch return error.CommandFailed;
    const body = try allocator.dupe(u8, trimmed[0..status_idx]);
    return .{
        .body = body,
        .status_code = if (status == 0) null else status,
    };
}
