const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const types = @import("http_types.zig");
const env = @import("http_env.zig");

const ChildCaptureResult = types.ChildCaptureResult;
const default_max_output_bytes = types.default_max_output_bytes;
const request_timeout_ms_value = types.request_timeout_ms_value;
const getEnvMap = env.getEnvMap;

pub fn runChildCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    env_map: ?*const std.process.Environ.Map,
) !ChildCaptureResult {
    return runChildCaptureWithInputAndOutputLimit(allocator, argv, null, timeout_ms, env_map, default_max_output_bytes);
}

pub fn runChildCaptureWithOutputLimit(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    env_map: ?*const std.process.Environ.Map,
    output_limit_bytes: usize,
) !ChildCaptureResult {
    return runChildCaptureWithInputAndOutputLimit(allocator, argv, null, timeout_ms, env_map, output_limit_bytes);
}

pub fn runChildCaptureWithInputAndOutputLimit(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
    timeout_ms: u64,
    env_map: ?*const std.process.Environ.Map,
    output_limit_bytes: usize,
) !ChildCaptureResult {
    var local_env_map = try getEnvMap(allocator);
    defer local_env_map.deinit();
    const effective_env_map = env_map orelse &local_env_map;

    var child = std.process.spawn(app_runtime.io(), .{
        .argv = argv,
        .environ_map = effective_env_map,
        .stdin = if (stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        else => return err,
    };
    errdefer child.kill(app_runtime.io());

    if (stdin_bytes) |bytes| {
        try child.stdin.?.writeStreamingAll(app_runtime.io(), bytes);
        child.stdin.?.close(app_runtime.io());
        child.stdin = null;
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(std.heap.page_allocator, app_runtime.io(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout_duration = std.Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    } };
    const timeout = timeout_duration.toDeadline(app_runtime.io());

    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > output_limit_bytes) {
            child.kill(app_runtime.io());
            return error.StreamTooLong;
        }
        if (stderr_reader.buffered().len > output_limit_bytes) {
            child.kill(app_runtime.io());
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => {
            child.kill(app_runtime.io());
            const stdout = try multi_reader.toOwnedSlice(0);
            defer std.heap.page_allocator.free(stdout);
            const stderr = try multi_reader.toOwnedSlice(1);
            defer std.heap.page_allocator.free(stderr);
            return .{
                .term = .{ .unknown = 0 },
                .stdout = try allocator.dupe(u8, stdout),
                .stderr = try allocator.dupe(u8, stderr),
                .timed_out = true,
            };
        },
        else => return err,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(app_runtime.io());
    const stdout = try multi_reader.toOwnedSlice(0);
    defer std.heap.page_allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    defer std.heap.page_allocator.free(stderr);

    return .{
        .term = term,
        .stdout = try allocator.dupe(u8, stdout),
        .stderr = try allocator.dupe(u8, stderr),
        .timed_out = false,
    };
}

pub fn computeBatchChildTimeoutMs(request_count: usize, max_concurrency: usize) u64 {
    const safe_concurrency = @max(@as(usize, 1), max_concurrency);
    const waves = @max(@as(usize, 1), (request_count + safe_concurrency - 1) / safe_concurrency);
    return @as(u64, @intCast(waves)) * request_timeout_ms_value + 2000;
}

pub fn computeBatchChildOutputLimitBytes(request_count: usize) usize {
    return std.math.mul(usize, default_max_output_bytes, @max(@as(usize, 1), request_count)) catch std.math.maxInt(usize);
}
