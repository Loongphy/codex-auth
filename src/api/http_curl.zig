const std = @import("std");
const types = @import("http_types.zig");
const child = @import("http_child.zig");
const executable = @import("http_executable.zig");

const HttpResult = types.HttpResult;
const BatchRequest = types.BatchRequest;
const BatchHttpResult = types.BatchHttpResult;
const BatchItemResult = types.BatchItemResult;
const BatchItemOutcome = types.BatchItemOutcome;
const request_timeout_secs = types.request_timeout_secs;
const child_process_timeout_ms_value = types.child_process_timeout_ms_value;
const default_max_output_bytes = types.default_max_output_bytes;
const user_agent = types.user_agent;
const runChildCaptureWithInputAndOutputLimit = child.runChildCaptureWithInputAndOutputLimit;
const resolveCurlExecutableForLaunchAlloc = executable.resolveCurlExecutableForLaunchAlloc;
const curl_timeout_exit_code = 28;

const LockedAllocator = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    fn lockedAllocator(self: *LockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn lock(self: *LockedAllocator) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *LockedAllocator) void {
        self.mutex.unlock();
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        return self.allocator.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.unlock();
        self.allocator.rawFree(memory, alignment, ret_addr);
    }
};

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
    const curl_executable = try resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl_executable);

    return runCurlGetJsonCommandWithExecutable(allocator, curl_executable, endpoint, access_token, account_id);
}

fn runCurlGetJsonCommandWithExecutable(
    allocator: std.mem.Allocator,
    curl_executable: []const u8,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);
    const account_header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{account_id});
    defer allocator.free(account_header);

    return try runCurlJsonCommandWithExecutable(allocator, curl_executable, endpoint, &[_][]const u8{ authorization, account_header });
}

fn runCurlJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    headers: []const []const u8,
) !HttpResult {
    const curl_executable = try resolveCurlExecutableForLaunchAlloc(allocator);
    defer allocator.free(curl_executable);

    return runCurlJsonCommandWithExecutable(allocator, curl_executable, endpoint, headers);
}

fn runCurlJsonCommandWithExecutable(
    allocator: std.mem.Allocator,
    curl_executable: []const u8,
    endpoint: []const u8,
    headers: []const []const u8,
) !HttpResult {
    const user_agent_header = "User-Agent: " ++ user_agent;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try appendCurlBaseArgs(allocator, &argv, curl_executable);

    var curl_config = std.ArrayList(u8).empty;
    defer curl_config.deinit(allocator);
    try appendCurlConfigLine(allocator, &curl_config, "url", endpoint);
    try appendCurlConfigLine(allocator, &curl_config, "header", user_agent_header);
    try appendCurlConfigLine(allocator, &curl_config, "header", "Accept: application/json");
    for (headers) |header| {
        try appendCurlConfigLine(allocator, &curl_config, "header", header);
    }

    const result = runChildCaptureWithInputAndOutputLimit(
        allocator,
        argv.items,
        curl_config.items,
        child_process_timeout_ms_value,
        null,
        default_max_output_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => return error.CurlRequired,
        else => return err,
    };
    defer result.deinit(allocator);

    if (result.timed_out) return error.TimedOut;

    switch (result.term) {
        .exited => |code| if (code != 0) {
            if (code == curl_timeout_exit_code) return error.TimedOut;
            return error.RequestFailed;
        },
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
    if (requests.len == 0) return .{ .items = items };

    const curl_executable = resolveCurlExecutableForLaunchAlloc(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => return err,
            else => {
                fillCurlBatchErrorItems(allocator, items, err);
                return .{ .items = items };
            },
        }
    };
    defer allocator.free(curl_executable);

    const worker_count = @min(requests.len, @max(@as(usize, 1), max_concurrency));
    if (worker_count <= 1) {
        runCurlGetJsonBatchSerially(allocator, curl_executable, endpoint, requests, items);
        return .{ .items = items };
    }

    var locked_allocator: LockedAllocator = .{ .allocator = allocator };
    var queue: CurlBatchWorkerQueue = .{
        .allocator = locked_allocator.lockedAllocator(),
        .curl_executable = curl_executable,
        .endpoint = endpoint,
        .requests = requests,
        .items = items,
    };

    const helper_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, helper_count);
    defer allocator.free(threads);

    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |thread| thread.join();
    }

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, CurlBatchWorkerQueue.run, .{&queue}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        spawned_count += 1;
    }

    queue.run();
    return .{ .items = items };
}

const CurlBatchWorkerQueue = struct {
    allocator: std.mem.Allocator,
    curl_executable: []const u8,
    endpoint: []const u8,
    requests: []const BatchRequest,
    items: []BatchItemResult,
    next_index: std.atomic.Value(usize) = .init(0),

    fn run(self: *CurlBatchWorkerQueue) void {
        while (true) {
            const idx = self.next_index.fetchAdd(1, .monotonic);
            if (idx >= self.requests.len) return;
            runCurlBatchItem(self.allocator, self.curl_executable, self.endpoint, self.requests[idx], &self.items[idx]);
        }
    }
};

fn runCurlGetJsonBatchSerially(
    allocator: std.mem.Allocator,
    curl_executable: []const u8,
    endpoint: []const u8,
    requests: []const BatchRequest,
    items: []BatchItemResult,
) void {
    for (requests, 0..) |request, idx| {
        runCurlBatchItem(allocator, curl_executable, endpoint, request, &items[idx]);
    }
}

fn runCurlBatchItem(
    allocator: std.mem.Allocator,
    curl_executable: []const u8,
    endpoint: []const u8,
    request: BatchRequest,
    item: *BatchItemResult,
) void {
    const result = runCurlGetJsonCommandWithExecutable(
        allocator,
        curl_executable,
        endpoint,
        request.access_token,
        request.account_id,
    ) catch |err| {
        item.* = curlBatchErrorItem(allocator, err);
        return;
    };
    item.* = .{
        .body = result.body,
        .status_code = result.status_code,
        .outcome = .ok,
    };
}

fn fillCurlBatchErrorItems(allocator: std.mem.Allocator, items: []BatchItemResult, err: anyerror) void {
    for (items) |*item| {
        item.* = curlBatchErrorItem(allocator, err);
    }
}

fn curlBatchErrorItem(allocator: std.mem.Allocator, err: anyerror) BatchItemResult {
    return switch (err) {
        error.TimedOut => .{
            .body = &.{},
            .status_code = null,
            .outcome = .timeout,
        },
        else => .{
            .body = allocator.dupe(u8, @errorName(err)) catch &.{},
            .status_code = null,
            .outcome = .failed,
        },
    };
}

fn appendCurlBaseArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    curl_executable: []const u8,
) !void {
    try argv.appendSlice(allocator, &.{
        curl_executable,
        "--disable",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        request_timeout_secs,
        "--output",
        "-",
        "--write-out",
        "\n%{http_code}",
        "--config",
        "-",
    });
}

fn appendCurlConfigLine(
    allocator: std.mem.Allocator,
    config: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
) !void {
    try config.appendSlice(allocator, key);
    try config.appendSlice(allocator, " = \"");
    try appendCurlConfigQuotedValue(allocator, config, value);
    try config.appendSlice(allocator, "\"\n");
}

fn appendCurlConfigQuotedValue(
    allocator: std.mem.Allocator,
    config: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        switch (byte) {
            '\\' => try config.appendSlice(allocator, "\\\\"),
            '"' => try config.appendSlice(allocator, "\\\""),
            '\n' => try config.appendSlice(allocator, "\\n"),
            '\r' => try config.appendSlice(allocator, "\\r"),
            '\t' => try config.appendSlice(allocator, "\\t"),
            else => try config.append(allocator, byte),
        }
    }
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
