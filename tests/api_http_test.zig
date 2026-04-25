const builtin = @import("builtin");
const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const http = codex_auth.api.http;
const BatchItemOutcome = http.BatchItemOutcome;
const NodeOutcome = http.NodeOutcome;
const default_max_output_bytes = http.default_max_output_bytes;
const node_use_env_proxy_env = http.node_use_env_proxy_env;
const child_process_timeout_ms_value = http.child_process_timeout_ms_value;
const parseNodeHttpOutput = http.parseNodeHttpOutput;
const parseBatchNodeHttpOutput = http.parseBatchNodeHttpOutput;
const computeBatchChildOutputLimitBytes = http.computeBatchChildOutputLimitBytes;
const runChildCapture = http.runChildCapture;
const runChildCaptureWithOutputLimit = http.runChildCaptureWithOutputLimit;
const ensureExecutableAvailableAlloc = http.ensureExecutableAvailableAlloc;
const parseNodeVersion = http.parseNodeVersion;
const nodeVersionSupportsEnvProxy = http.nodeVersionSupportsEnvProxy;
const detectNodeEnvProxySupportWithTimeout = http.detectNodeEnvProxySupportWithTimeout;
const maybeEnableNodeEnvProxy = http.maybeEnableNodeEnvProxy;
const deriveWindowsSystemProxyAlloc = http.deriveWindowsSystemProxyAlloc;
const resolveExecutablePathEntryForLaunchAlloc = http.resolveExecutablePathEntryForLaunchAlloc;

test "parse node http output decodes status and body" {
    const allocator = std.testing.allocator;
    const parsed = parseNodeHttpOutput(allocator, "aGVsbG8=\n200\nok\n") orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.body);

    try std.testing.expectEqual(NodeOutcome.ok, parsed.outcome);
    try std.testing.expectEqual(@as(?u16, 200), parsed.status_code);
    try std.testing.expectEqualStrings("hello", parsed.body);
}

test "parse node http output keeps timeout marker" {
    const allocator = std.testing.allocator;
    const parsed = parseNodeHttpOutput(allocator, "\n0\ntimeout\n") orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.body);

    try std.testing.expectEqual(NodeOutcome.timeout, parsed.outcome);
    try std.testing.expectEqual(@as(?u16, null), parsed.status_code);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
}

test "parse batch node http output decodes per-request bodies" {
    const allocator = std.testing.allocator;
    var parsed = try parseBatchNodeHttpOutput(
        allocator,
        "[{\"body\":\"aGVsbG8=\",\"status\":200,\"outcome\":\"ok\"},{\"body\":\"\",\"status\":0,\"outcome\":\"timeout\"}]",
    );
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.items.len);
    try std.testing.expectEqualStrings("hello", parsed.items[0].body);
    try std.testing.expectEqual(@as(?u16, 200), parsed.items[0].status_code);
    try std.testing.expectEqual(BatchItemOutcome.ok, parsed.items[0].outcome);
    try std.testing.expectEqual(@as(usize, 0), parsed.items[1].body.len);
    try std.testing.expectEqual(@as(?u16, null), parsed.items[1].status_code);
    try std.testing.expectEqual(BatchItemOutcome.timeout, parsed.items[1].outcome);
}

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
    // PowerShell startup can be noticeably slower on CI, but the child still
    // runs far longer than either timeout once it emits the initial stdout.
    const timeout_ms: u64 = if (builtin.os.tag == .windows) 3000 else 1000;

    const result = runChildCapture(allocator, argv, timeout_ms, null) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    if (builtin.os.tag != .windows) {
        // PowerShell can time out before its pipe delivers the early stdout on Windows CI.
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

test "ensure executable available returns NodeJsRequired for missing path" {
    try std.testing.expectError(
        error.NodeJsRequired,
        ensureExecutableAvailableAlloc(std.testing.allocator, "/definitely/missing/node"),
    );
}

test "parse node version handles leading v prefix" {
    const version = try parseNodeVersion("v22.21.0\n");

    try std.testing.expectEqual(@as(u32, 22), version.major);
    try std.testing.expectEqual(@as(u32, 21), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);
}

test "node version support gate matches documented ranges" {
    try std.testing.expect(!nodeVersionSupportsEnvProxy(.{ .major = 22, .minor = 20, .patch = 9 }));
    try std.testing.expect(nodeVersionSupportsEnvProxy(.{ .major = 22, .minor = 21, .patch = 0 }));
    try std.testing.expect(!nodeVersionSupportsEnvProxy(.{ .major = 23, .minor = 11, .patch = 1 }));
    try std.testing.expect(nodeVersionSupportsEnvProxy(.{ .major = 24, .minor = 0, .patch = 0 }));
}

test "detect node env proxy support times out blocked helper" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = switch (builtin.os.tag) {
        .windows => "node.cmd",
        else => "node",
    };
    const script_data = switch (builtin.os.tag) {
        .windows =>
        \\@echo off
        \\powershell -NoLogo -NoProfile -Command "Start-Sleep -Seconds 30"
        ,
        else =>
        \\#!/bin/sh
        \\sleep 30
        ,
    };

    try tmp.dir.writeFile(app_runtime.io(), .{ .sub_path = script_name, .data = script_data });
    if (builtin.os.tag != .windows) {
        var script_file = try tmp.dir.openFile(app_runtime.io(), script_name, .{ .mode = .read_write });
        defer script_file.close(app_runtime.io());
        try script_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    }

    const script_path = try app_runtime.realPathFileAlloc(allocator, tmp.dir, script_name);
    defer allocator.free(script_path);

    try std.testing.expect(!detectNodeEnvProxySupportWithTimeout(allocator, script_path, 100));
}

test "maybe enable node env proxy does not set NODE_USE_ENV_PROXY when runtime lacks support" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("HTTPS_PROXY", "http://127.0.0.1:7890");
    try maybeEnableNodeEnvProxy(std.testing.allocator, &env_map, false);

    try std.testing.expect(env_map.get(node_use_env_proxy_env) == null);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
}

test "maybe enable node env proxy sets NODE_USE_ENV_PROXY when HTTP proxy is present" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("HTTPS_PROXY", "http://127.0.0.1:7890");
    try maybeEnableNodeEnvProxy(std.testing.allocator, &env_map, true);

    try std.testing.expectEqualStrings("1", env_map.get(node_use_env_proxy_env).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
}

test "maybe enable node env proxy maps ALL_PROXY when direct proxy vars are missing" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("ALL_PROXY", "http://127.0.0.1:7890");
    try maybeEnableNodeEnvProxy(std.testing.allocator, &env_map, true);

    try std.testing.expectEqualStrings("1", env_map.get(node_use_env_proxy_env).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTP_PROXY").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
}

test "maybe enable node env proxy maps ALL_PROXY even when NODE_USE_ENV_PROXY is already set" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("ALL_PROXY", "http://127.0.0.1:7890");
    try env_map.put(node_use_env_proxy_env, "1");
    try maybeEnableNodeEnvProxy(std.testing.allocator, &env_map, true);

    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTP_PROXY").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
    try std.testing.expectEqualStrings("1", env_map.get(node_use_env_proxy_env).?);
}

test "derive windows system proxy alloc maps shared proxy and explicit overrides" {
    const allocator = std.testing.allocator;
    var proxy = (try deriveWindowsSystemProxyAlloc(
        allocator,
        "127.0.0.1:7890",
        "*.corp;intranet.local;<local>",
    )) orelse return error.TestUnexpectedResult;
    defer proxy.deinit(allocator);

    try std.testing.expectEqualStrings("http://127.0.0.1:7890", proxy.http_proxy.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", proxy.https_proxy.?);
    try std.testing.expectEqualStrings("*.corp,intranet.local", proxy.no_proxy.?);
}

test "derive windows system proxy alloc maps protocol-specific entries" {
    const allocator = std.testing.allocator;
    var proxy = (try deriveWindowsSystemProxyAlloc(
        allocator,
        "http=127.0.0.1:8080;https=https://127.0.0.1:8443",
        null,
    )) orelse return error.TestUnexpectedResult;
    defer proxy.deinit(allocator);

    try std.testing.expectEqualStrings("http://127.0.0.1:8080", proxy.http_proxy.?);
    try std.testing.expectEqualStrings("https://127.0.0.1:8443", proxy.https_proxy.?);
    try std.testing.expect(proxy.no_proxy == null);
}

test "derive windows system proxy alloc maps socks-only entries" {
    const allocator = std.testing.allocator;
    var proxy = (try deriveWindowsSystemProxyAlloc(
        allocator,
        "socks=127.0.0.1:1080",
        null,
    )) orelse return error.TestUnexpectedResult;
    defer proxy.deinit(allocator);

    try std.testing.expectEqualStrings("socks://127.0.0.1:1080", proxy.http_proxy.?);
    try std.testing.expectEqualStrings("socks://127.0.0.1:1080", proxy.https_proxy.?);
    try std.testing.expect(proxy.no_proxy == null);
}

test "launch path resolution preserves node symlink path" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try app_runtime.realPathFileAlloc(arena, tmp_dir.dir, ".");
    const node_path = try std.fs.path.join(arena, &[_][]const u8{ entry, "node" });

    try tmp_dir.dir.writeFile(app_runtime.io(), .{
        .sub_path = "node-real",
        .data = "#!/bin/sh\nexit 0\n",
    });
    var real_file = try tmp_dir.dir.openFile(app_runtime.io(), "node-real", .{ .mode = .read_write });
    defer real_file.close(app_runtime.io());
    if (builtin.os.tag != .windows) {
        try real_file.setPermissions(app_runtime.io(), .fromMode(0o755));
    }
    try tmp_dir.dir.symLink(app_runtime.io(), "node-real", "node", .{});

    const resolved = (try resolveExecutablePathEntryForLaunchAlloc(allocator, entry, "node")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(node_path, resolved);
}
