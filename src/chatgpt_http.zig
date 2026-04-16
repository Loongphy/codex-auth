const builtin = @import("builtin");
const std = @import("std");

pub const request_timeout_secs: []const u8 = "5";
pub const request_timeout_ms: []const u8 = "5000";
pub const request_timeout_ms_value: u64 = 5000;
pub const child_process_timeout_ms: []const u8 = "7000";
pub const child_process_timeout_ms_value: u64 = 7000;
pub const browser_user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
pub const node_executable_env = "CODEX_AUTH_NODE_EXECUTABLE";
pub const node_use_env_proxy_env = "NODE_USE_ENV_PROXY";
pub const node_requirement_hint = "Node.js 22+ is required for ChatGPT API refresh. Install Node.js 22+ or use the npm package.";

const max_output_bytes = 1024 * 1024;

pub const HttpResult = struct {
    body: []u8,
    status_code: ?u16,
};

const NodeOutcome = enum {
    ok,
    timeout,
    failed,
    node_too_old,
};

const ParsedNodeHttpOutput = struct {
    body: []u8,
    status_code: ?u16,
    outcome: NodeOutcome,
};

const ChildCaptureResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,

    fn deinit(self: *const ChildCaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const ChildProcessWatchdog = struct {
    mutex: std.Thread.Mutex = .{},
    completed: bool = false,
    timed_out: bool = false,

    fn run(self: *ChildProcessWatchdog, child_id: std.process.Child.Id, timeout_ms: u64) void {
        std.Thread.sleep(timeout_ms * std.time.ns_per_ms);

        self.mutex.lock();
        if (self.completed) {
            self.mutex.unlock();
            return;
        }
        self.completed = true;
        self.timed_out = true;
        self.mutex.unlock();

        terminateChildProcess(child_id);
    }

    fn finish(self: *ChildProcessWatchdog) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timed_out = self.timed_out;
        self.completed = true;
        return timed_out;
    }
};

const node_request_script =
    \\const endpoint = process.argv[1];
    \\const accessToken = process.argv[2];
    \\const accountId = process.argv[3];
    \\const timeoutMs = Number(process.argv[4]);
    \\const userAgent = process.argv[5];
    \\const encode = (value) => Buffer.from(value ?? "", "utf8").toString("base64");
    \\const emit = (body, status, outcome) => {
    \\  process.stdout.write(encode(body));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(String(status));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(outcome);
    \\};
    \\const nodeMajor = Number(process.versions?.node?.split(".")[0] ?? 0);
    \\if (!Number.isInteger(nodeMajor) || nodeMajor < 22 || typeof fetch !== "function" || typeof AbortSignal?.timeout !== "function") {
    \\  emit("Node.js 22+ is required.", 0, "node-too-old");
    \\} else {
    \\  void (async () => {
    \\    try {
    \\      const response = await fetch(endpoint, {
    \\        method: "GET",
    \\        headers: {
    \\          "Authorization": "Bearer " + accessToken,
    \\          "ChatGPT-Account-Id": accountId,
    \\          "User-Agent": userAgent,
    \\        },
    \\        signal: AbortSignal.timeout(timeoutMs),
    \\      });
    \\      emit(await response.text(), response.status, "ok");
    \\    } catch (error) {
    \\      const isTimeout = error?.name === "TimeoutError" || error?.name === "AbortError";
    \\      emit(error?.message ?? "", 0, isTimeout ? "timeout" : "error");
    \\    }
    \\  })().catch((error) => {
    \\    emit(error?.message ?? "", 0, "error");
    \\  });
    \\}
;

pub fn runGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    return runNodeGetJsonCommand(allocator, endpoint, access_token, account_id);
}

pub fn ensureNodeExecutableAvailable(allocator: std.mem.Allocator) !void {
    const node_executable = try resolveNodeExecutableForLaunchAlloc(allocator);
    defer allocator.free(node_executable);
}

pub fn resolveNodeExecutableAlloc(allocator: std.mem.Allocator) ![]u8 {
    return resolveNodeExecutable(allocator);
}

pub fn resolveNodeExecutableForDebugAlloc(allocator: std.mem.Allocator) ![]u8 {
    return resolveNodeExecutableForLaunchAlloc(allocator);
}

fn runNodeGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const node_executable = try resolveNodeExecutableForLaunchAlloc(allocator);
    defer allocator.free(node_executable);

    // Use an explicit wait path so failed output collection cannot strand zombies.
    const result = runChildCapture(allocator, &.{
        node_executable,
        "-e",
        node_request_script,
        endpoint,
        access_token,
        account_id,
        request_timeout_ms,
        browser_user_agent,
    }, child_process_timeout_ms_value) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => {
            logNodeRequirement();
            return error.NodeJsRequired;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    if (result.timed_out) return error.NodeProcessTimedOut;

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.RequestFailed,
        else => return error.RequestFailed,
    }

    const parsed = parseNodeHttpOutput(allocator, result.stdout) orelse return error.CommandFailed;

    switch (parsed.outcome) {
        .ok => return .{
            .body = parsed.body,
            .status_code = parsed.status_code,
        },
        .timeout => {
            allocator.free(parsed.body);
            return error.TimedOut;
        },
        .failed => {
            allocator.free(parsed.body);
            return error.RequestFailed;
        },
        .node_too_old => {
            allocator.free(parsed.body);
            logNodeRequirement();
            return error.NodeJsRequired;
        },
    }
}

fn runChildCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
) !ChildCaptureResult {
    var child = std.process.Child.init(argv, allocator);
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try maybeEnableNodeEnvProxy(&env_map);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout = std.ArrayList(u8).empty;
    errdefer stdout.deinit(allocator);
    var stderr = std.ArrayList(u8).empty;
    errdefer stderr.deinit(allocator);

    try child.spawn();
    errdefer reapChildAfterError(&child);

    var watchdog = ChildProcessWatchdog{};
    const watchdog_thread = std.Thread.spawn(.{}, ChildProcessWatchdog.run, .{
        &watchdog,
        child.id,
        timeout_ms,
    }) catch null;
    defer if (watchdog_thread) |thread| thread.join();

    try child.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    const term = try child.wait();
    const timed_out = if (watchdog_thread != null) watchdog.finish() else false;

    return .{
        .term = term,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .timed_out = timed_out,
    };
}

fn terminateChildProcess(child_id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows => {
            std.os.windows.TerminateProcess(child_id, 1) catch {};
        },
        .wasi => {},
        else => {
            std.posix.kill(child_id, std.posix.SIG.KILL) catch {};
        },
    }
}

fn reapChildAfterError(child: *std.process.Child) void {
    _ = child.kill() catch |err| switch (err) {
        error.AlreadyTerminated => {
            _ = child.wait() catch {};
        },
        else => {},
    };
}

fn resolveNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, node_executable_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "node"),
        else => return err,
    };
}

fn maybeEnableNodeEnvProxy(env_map: *std.process.EnvMap) !void {
    if (env_map.get(node_use_env_proxy_env) == null) {
        const all_proxy = env_map.get("ALL_PROXY") orelse env_map.get("all_proxy");
        if (all_proxy) |proxy| {
            if (env_map.get("HTTP_PROXY") == null and env_map.get("http_proxy") == null) {
                try env_map.put("HTTP_PROXY", proxy);
            }
            if (env_map.get("HTTPS_PROXY") == null and env_map.get("https_proxy") == null) {
                try env_map.put("HTTPS_PROXY", proxy);
            }
        }

        if (env_map.get("HTTP_PROXY") != null or
            env_map.get("http_proxy") != null or
            env_map.get("HTTPS_PROXY") != null or
            env_map.get("https_proxy") != null)
        {
            try env_map.put(node_use_env_proxy_env, "1");
        }
    }
}

fn resolveNodeExecutableForLaunchAlloc(allocator: std.mem.Allocator) ![]u8 {
    const node_executable = try resolveNodeExecutable(allocator);
    defer allocator.free(node_executable);
    return ensureExecutableAvailableAlloc(allocator, node_executable);
}

fn ensureExecutableAvailableAlloc(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    if (try resolveExecutableForLaunchAlloc(allocator, executable)) |resolved| return resolved;
    logNodeRequirement();
    return error.NodeJsRequired;
}

fn resolveExecutableForLaunchAlloc(allocator: std.mem.Allocator, executable: []const u8) !?[]u8 {
    if (std.fs.path.isAbsolute(executable) or std.mem.indexOfAny(u8, executable, "/\\") != null) {
        if (!accessPath(executable)) return null;
        return try allocator.dupe(u8, executable);
    }

    const path_value = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(path_value);

    var path_it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        if (try resolveExecutablePathEntryForLaunchAlloc(allocator, entry, executable)) |resolved| return resolved;
    }

    return null;
}

fn resolveExecutablePathEntryForLaunchAlloc(
    allocator: std.mem.Allocator,
    entry: []const u8,
    executable: []const u8,
) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &[_][]const u8{ entry, executable });
    defer allocator.free(candidate);

    if (accessPath(candidate)) {
        return try allocator.dupe(u8, candidate);
    }

    if (builtin.os.tag == .windows and std.fs.path.extension(executable).len == 0) {
        const path_ext = std.process.getEnvVarOwned(allocator, "PATHEXT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ".COM;.EXE;.BAT;.CMD"),
            else => return err,
        };
        defer allocator.free(path_ext);

        var ext_it = std.mem.splitScalar(u8, path_ext, ';');
        while (ext_it.next()) |raw_ext| {
            if (raw_ext.len == 0) continue;
            const ext = std.mem.trim(u8, raw_ext, " \t");
            if (ext.len == 0) continue;

            const ext_candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ candidate, ext });
            defer allocator.free(ext_candidate);

            if (accessPath(ext_candidate)) {
                return try allocator.dupe(u8, ext_candidate);
            }
        }
    }

    return null;
}
fn accessPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn logNodeRequirement() void {
    std.log.warn("{s}", .{node_requirement_hint});
}

fn parseNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?ParsedNodeHttpOutput {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const outcome_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const status_idx = std.mem.lastIndexOfScalar(u8, trimmed[0..outcome_idx], '\n') orelse return null;
    const encoded_body = std.mem.trim(u8, trimmed[0..status_idx], " \r\t");
    const status_slice = std.mem.trim(u8, trimmed[status_idx + 1 .. outcome_idx], " \r\t");
    const outcome_slice = std.mem.trim(u8, trimmed[outcome_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    const decoded_body = decodeBase64Alloc(allocator, encoded_body) catch return null;
    return .{
        .body = decoded_body,
        .status_code = if (status == 0) null else status,
        .outcome = parseNodeOutcome(outcome_slice) orelse {
            allocator.free(decoded_body);
            return null;
        },
    };
}

fn parseNodeOutcome(input: []const u8) ?NodeOutcome {
    if (std.mem.eql(u8, input, "ok")) return .ok;
    if (std.mem.eql(u8, input, "timeout")) return .timeout;
    if (std.mem.eql(u8, input, "error")) return .failed;
    if (std.mem.eql(u8, input, "node-too-old")) return .node_too_old;
    return null;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    try decoder.decode(buf, input);
    return buf;
}

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

    try tmp.dir.writeFile(.{
        .sub_path = script_name,
        .data = script_data,
    });

    if (builtin.os.tag != .windows) {
        var script_file = try tmp.dir.openFile(script_name, .{ .mode = .read_write });
        defer script_file.close();
        try script_file.chmod(0o755);
    }

    const script_path = try tmp.dir.realpathAlloc(allocator, script_name);
    defer allocator.free(script_path);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "pwsh.exe", "-NoLogo", "-NoProfile", "-File", script_path },
        else => &[_][]const u8{script_path},
    };

    const result = try runChildCapture(allocator, argv, 100);
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
}

test "ensure executable available returns NodeJsRequired for missing path" {
    try std.testing.expectError(
        error.NodeJsRequired,
        ensureExecutableAvailableAlloc(std.testing.allocator, "/definitely/missing/node"),
    );
}

test "maybe enable node env proxy sets NODE_USE_ENV_PROXY when HTTP proxy is present" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("HTTPS_PROXY", "http://127.0.0.1:7890");
    try maybeEnableNodeEnvProxy(&env_map);

    try std.testing.expectEqualStrings("1", env_map.get(node_use_env_proxy_env).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
}

test "maybe enable node env proxy maps ALL_PROXY when direct proxy vars are missing" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put("ALL_PROXY", "http://127.0.0.1:7890");
    try maybeEnableNodeEnvProxy(&env_map);

    try std.testing.expectEqualStrings("1", env_map.get(node_use_env_proxy_env).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTP_PROXY").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7890", env_map.get("HTTPS_PROXY").?);
}

test "launch path resolution preserves node symlink path" {
    const allocator = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try tmp_dir.dir.realpathAlloc(arena, ".");
    const node_path = try std.fs.path.join(arena, &[_][]const u8{ entry, "node" });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "node-real",
        .data = "#!/bin/sh\nexit 0\n",
    });
    var real_file = try tmp_dir.dir.openFile("node-real", .{ .mode = .read_write });
    defer real_file.close();
    if (builtin.os.tag != .windows) {
        try real_file.chmod(0o755);
    }
    try tmp_dir.dir.symLink("node-real", "node", .{});

    const resolved = (try resolveExecutablePathEntryForLaunchAlloc(allocator, entry, "node")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings(node_path, resolved);
}
