const builtin = @import("builtin");
const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const http = codex_auth.api.http;
const default_max_output_bytes = http.default_max_output_bytes;
const child_process_timeout_ms_value = http.child_process_timeout_ms_value;
const computeBatchChildOutputLimitBytes = http.computeBatchChildOutputLimitBytes;
const runChildCapture = http.runChildCapture;
const runChildCaptureWithOutputLimit = http.runChildCaptureWithOutputLimit;
const ensureExecutableAvailableAlloc = http.ensureExecutableAvailableAlloc;
const resolveExecutablePathEntryForLaunchAlloc = http.resolveExecutablePathEntryForLaunchAlloc;

test "batch child output limit scales with request count" {
    try std.testing.expectEqual(default_max_output_bytes, computeBatchChildOutputLimitBytes(1));
    try std.testing.expectEqual(default_max_output_bytes * 2, computeBatchChildOutputLimitBytes(2));
    try std.testing.expectEqual(default_max_output_bytes * 8, computeBatchChildOutputLimitBytes(8));
}

test "run child capture times out stalled child process" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = switch (builtin.os.tag) {
        .windows => "stall.ps1",
        else => "stall.sh",
    };
    const script_data = switch (builtin.os.tag) {
        .windows =>
        \\Start-Sleep -Seconds 30
        ,
        else =>
        \\#!/bin/sh
        \\sleep 30
        ,
    };

    try tmp.dir.writeFile(app_runtime.io(), .{
        .sub_path = script_name,
        .data = script_data,
    });

    if (builtin.os.tag != .windows) {
        var script_file = try tmp.dir.openFile(app_runtime.io(), script_name, .{ .mode = .read_write });
        defer script_file.close(app_runtime.io());
        try script_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    }

    const script_path = try app_runtime.realPathFileAlloc(allocator, tmp.dir, script_name);
    defer allocator.free(script_path);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "pwsh.exe", "-NoLogo", "-NoProfile", "-File", script_path },
        else => &[_][]const u8{script_path},
    };

    const result = runChildCapture(allocator, argv, 100, null) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
}

test "run child capture preserves partial stdout when child times out" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = switch (builtin.os.tag) {
        .windows => "partial-output.ps1",
        else => "partial-output.sh",
    };
    const script_data = switch (builtin.os.tag) {
        .windows =>
        \\[Console]::Out.Write("." * 64)
        \\[Console]::Out.Flush()
        \\Start-Sleep -Seconds 30
        ,
        else =>
        \\#!/bin/sh
        \\printf '................................................................'
        \\sleep 30
        ,
    };

    try tmp.dir.writeFile(app_runtime.io(), .{
        .sub_path = script_name,
        .data = script_data,
    });

    if (builtin.os.tag != .windows) {
        var script_file = try tmp.dir.openFile(app_runtime.io(), script_name, .{ .mode = .read_write });
        defer script_file.close(app_runtime.io());
        try script_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    }

    const script_path = try app_runtime.realPathFileAlloc(allocator, tmp.dir, script_name);
    defer allocator.free(script_path);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "pwsh.exe", "-NoLogo", "-NoProfile", "-File", script_path },
        else => &[_][]const u8{script_path},
    };
    const timeout_ms: u64 = if (builtin.os.tag == .windows) 3000 else 1000;

    const result = runChildCapture(allocator, argv, timeout_ms, null) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    if (builtin.os.tag != .windows) {
        try std.testing.expect(result.stdout.len > 0);
    }
}

test "run child capture accepts larger custom output limits for batched payloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = switch (builtin.os.tag) {
        .windows => "large-output.ps1",
        else => "large-output.sh",
    };
    const script_data = switch (builtin.os.tag) {
        .windows =>
        \\$chunk = 'a' * 4096
        \\for ($i = 0; $i -lt 320; $i++) {
        \\  [Console]::Out.Write($chunk)
        \\}
        ,
        else =>
        \\#!/bin/sh
        \\head -c 1310720 /dev/zero | tr '\000' 'a'
        ,
    };

    try tmp.dir.writeFile(app_runtime.io(), .{
        .sub_path = script_name,
        .data = script_data,
    });

    if (builtin.os.tag != .windows) {
        var script_file = try tmp.dir.openFile(app_runtime.io(), script_name, .{ .mode = .read_write });
        defer script_file.close(app_runtime.io());
        try script_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    }

    const script_path = try app_runtime.realPathFileAlloc(allocator, tmp.dir, script_name);
    defer allocator.free(script_path);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "pwsh.exe", "-NoLogo", "-NoProfile", "-File", script_path },
        else => &[_][]const u8{script_path},
    };

    try std.testing.expectError(
        error.StreamTooLong,
        runChildCaptureWithOutputLimit(allocator, argv, child_process_timeout_ms_value, null, default_max_output_bytes),
    );

    const result = try runChildCaptureWithOutputLimit(
        allocator,
        argv,
        child_process_timeout_ms_value,
        null,
        computeBatchChildOutputLimitBytes(2),
    );
    defer result.deinit(allocator);

    try std.testing.expect(!result.timed_out);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(result.stdout.len > default_max_output_bytes);
}

test "ensure executable available returns generic executable error for missing path" {
    try std.testing.expectError(
        error.ExecutableRequired,
        ensureExecutableAvailableAlloc(std.testing.allocator, "/definitely/missing/curl"),
    );
}

test "launch path resolution preserves symlink path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try app_runtime.realPathFileAlloc(arena, tmp_dir.dir, ".");
    const curl_path = try std.fs.path.join(arena, &[_][]const u8{ entry, "curl" });

    try tmp_dir.dir.writeFile(app_runtime.io(), .{
        .sub_path = "curl-real",
        .data = "#!/bin/sh\nexit 0\n",
    });
    var real_file = try tmp_dir.dir.openFile(app_runtime.io(), "curl-real", .{ .mode = .read_write });
    defer real_file.close(app_runtime.io());
    try real_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    try tmp_dir.dir.symLink(app_runtime.io(), "curl-real", "curl", .{});

    const resolved = (try resolveExecutablePathEntryForLaunchAlloc(allocator, entry, "curl")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(curl_path, resolved);
}
