const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const http = codex_auth.api.http;
const refresh = codex_auth.auth.oauth_refresh;

var request_marker_path: []const u8 = &.{};

fn request(allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!http.HttpResult {
    var marker = try std.Io.Dir.cwd().createFile(app_runtime.io(), request_marker_path, .{ .exclusive = true });
    defer marker.close(app_runtime.io());
    try marker.writeStreamingAll(app_runtime.io(), "requested\n");

    const deadline = std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds() + 100;
    while (std.Io.Timestamp.now(app_runtime.io(), .real).toMilliseconds() < deadline) {
        std.Thread.yield() catch {};
    }
    return .{
        .body = try allocator.dupe(u8, "{\"access_token\":\"e30.eyJleHAiOjQxMDI0NDQ4MDB9.x\",\"refresh_token\":\"rotated\"}"),
        .status_code = 200,
    };
}

fn lockExclusive(file: std.Io.File) anyerror!void {
    try file.lock(app_runtime.io(), .exclusive);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    request_marker_path = args[2];
    _ = try refresh.refreshAccountWith(
        init.gpa,
        args[1],
        "acct",
        false,
        false,
        1,
        request,
        lockExclusive,
    );
}
