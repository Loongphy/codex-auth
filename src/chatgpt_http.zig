const builtin = @import("builtin");
const std = @import("std");
const app_runtime = @import("runtime.zig");
const winreg = if (builtin.os.tag == .windows) struct {
    extern "advapi32" fn RegGetValueW(
        hkey: std.os.windows.HKEY,
        sub_key: ?[*:0]const u16,
        value_name: ?[*:0]const u16,
        flags: u32,
        actual_type: ?*std.os.windows.ULONG,
        data: ?*anyopaque,
        data_len: ?*u32,
    ) callconv(.winapi) std.os.windows.LSTATUS;

    const RRF_RT_REG_SZ: u32 = 0x00000002;
    const RRF_RT_REG_EXPAND_SZ: u32 = 0x00000004;
    const RRF_RT_REG_DWORD: u32 = 0x00000010;
} else struct {};

pub const request_timeout_secs: []const u8 = "5";
pub const request_timeout_ms: []const u8 = "5000";
pub const request_timeout_ms_value: u64 = 5000;
pub const child_process_timeout_ms: []const u8 = "7000";
pub const child_process_timeout_ms_value: u64 = 7000;
pub const browser_user_agent: []const u8 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
pub const node_executable_env = "CODEX_AUTH_NODE_EXECUTABLE";
pub const node_use_env_proxy_env = "NODE_USE_ENV_PROXY";
pub const node_requirement_hint = "Node.js 22+ is required for ChatGPT API refresh. Install Node.js 22+ or use the npm package.";

const default_max_output_bytes = 1024 * 1024;

fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return try app_runtime.currentEnviron().createMap(allocator);
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const value = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, value);
}

pub const HttpResult = struct {
    body: []u8,
    status_code: ?u16,
};

pub const BatchRequest = struct {
    access_token: []const u8,
    account_id: []const u8,
};

pub const BatchItemOutcome = enum {
    ok,
    timeout,
    failed,
};

pub const BatchItemResult = struct {
    body: []u8,
    status_code: ?u16,
    outcome: BatchItemOutcome,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const BatchHttpResult = struct {
    items: []BatchItemResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
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
    \\const emitAndExit = (body, status, outcome) => {
    \\  process.stdout.write(encode(body));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(String(status));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(outcome, () => process.exit(0));
    \\};
    \\const nodeMajor = Number(process.versions?.node?.split(".")[0] ?? 0);
    \\if (!Number.isInteger(nodeMajor) || nodeMajor < 22 || typeof fetch !== "function" || typeof AbortSignal?.timeout !== "function") {
    \\  emitAndExit("Node.js 22+ is required.", 0, "node-too-old");
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
    \\      emitAndExit(error?.message ?? "", 0, isTimeout ? "timeout" : "error");
    \\    }
    \\  })().catch((error) => {
    \\    emitAndExit(error?.message ?? "", 0, "error");
    \\  });
    \\}
;

const node_batch_request_script =
    \\const readStdin = () => new Promise((resolve, reject) => {
    \\  let data = "";
    \\  process.stdin.setEncoding("utf8");
    \\  process.stdin.on("data", (chunk) => {
    \\    data += chunk;
    \\  });
    \\  process.stdin.on("end", () => resolve(data));
    \\  process.stdin.on("error", reject);
    \\});
    \\const encode = (value) => Buffer.from(value ?? "", "utf8").toString("base64");
    \\const emit = (body, status, outcome) => {
    \\  process.stdout.write(encode(body));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(String(status));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(outcome);
    \\};
    \\const emitAndExit = (body, status, outcome) => {
    \\  process.stdout.write(encode(body));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(String(status));
    \\  process.stdout.write("\n");
    \\  process.stdout.write(outcome, () => process.exit(0));
    \\};
    \\const nodeMajor = Number(process.versions?.node?.split(".")[0] ?? 0);
    \\if (!Number.isInteger(nodeMajor) || nodeMajor < 22 || typeof fetch !== "function" || typeof AbortSignal?.timeout !== "function") {
    \\  emitAndExit("Node.js 22+ is required.", 0, "node-too-old");
    \\} else {
    \\  void (async () => {
    \\    try {
    \\      const payload = JSON.parse(await readStdin());
    \\      const requests = Array.isArray(payload?.requests) ? payload.requests : [];
    \\      const endpoint = String(payload?.endpoint ?? "");
    \\      const timeoutMs = Number(payload?.timeout_ms ?? 0);
    \\      const userAgent = String(payload?.user_agent ?? "");
    \\      const requestedConcurrency = Math.max(1, Number(payload?.concurrency ?? 1) || 1);
    \\      const workerCount = Math.max(1, Math.min(requestedConcurrency, Math.max(1, requests.length)));
    \\      const results = new Array(requests.length);
    \\      let nextIndex = 0;
    \\      const runOne = async (index) => {
    \\        const req = requests[index] ?? {};
    \\        try {
    \\          const response = await fetch(endpoint, {
    \\            method: "GET",
    \\            headers: {
    \\              "Authorization": "Bearer " + String(req.access_token ?? ""),
    \\              "ChatGPT-Account-Id": String(req.account_id ?? ""),
    \\              "User-Agent": userAgent,
    \\            },
    \\            signal: AbortSignal.timeout(timeoutMs),
    \\          });
    \\          results[index] = {
    \\            body: encode(await response.text()),
    \\            status: response.status,
    \\            outcome: "ok",
    \\          };
    \\        } catch (error) {
    \\          const isTimeout = error?.name === "TimeoutError" || error?.name === "AbortError";
    \\          results[index] = {
    \\            body: encode(error?.message ?? ""),
    \\            status: 0,
    \\            outcome: isTimeout ? "timeout" : "error",
    \\          };
    \\        }
    \\      };
    \\      await Promise.all(Array.from({ length: workerCount }, async () => {
    \\        while (true) {
    \\          const index = nextIndex++;
    \\          if (index >= requests.length) return;
    \\          await runOne(index);
    \\        }
    \\      }));
    \\      emit(JSON.stringify(results), 200, "ok");
    \\    } catch (error) {
    \\      emitAndExit(error?.message ?? "", 0, "error");
    \\    }
    \\  })().catch((error) => {
    \\    emitAndExit(error?.message ?? "", 0, "error");
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

pub fn runGetJsonBatchCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    requests: []const BatchRequest,
    max_concurrency: usize,
) !BatchHttpResult {
    return runNodeGetJsonBatchCommand(allocator, endpoint, requests, max_concurrency);
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

    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const node_env_proxy_supported = if (needsNodeEnvProxySupportCheck(&env_map))
        detectNodeEnvProxySupport(allocator, node_executable)
    else
        false;
    try maybeEnableNodeEnvProxy(allocator, &env_map, node_env_proxy_supported);

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
    }, child_process_timeout_ms_value, &env_map) catch |err| switch (err) {
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
        .exited => |code| if (code != 0) return error.RequestFailed,
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

fn runNodeGetJsonBatchCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    requests: []const BatchRequest,
    max_concurrency: usize,
) !BatchHttpResult {
    if (requests.len == 0) {
        return .{ .items = try allocator.alloc(BatchItemResult, 0) };
    }

    const node_executable = try resolveNodeExecutableForLaunchAlloc(allocator);
    defer allocator.free(node_executable);

    var env_map = try getEnvMap(allocator);
    defer env_map.deinit();

    const node_env_proxy_supported = if (needsNodeEnvProxySupportCheck(&env_map))
        detectNodeEnvProxySupport(allocator, node_executable)
    else
        false;
    try maybeEnableNodeEnvProxy(allocator, &env_map, node_env_proxy_supported);

    const Payload = struct {
        endpoint: []const u8,
        timeout_ms: u64,
        concurrency: usize,
        user_agent: []const u8,
        requests: []const BatchRequest,
    };

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();
    try std.json.Stringify.value(Payload{
        .endpoint = endpoint,
        .timeout_ms = request_timeout_ms_value,
        .concurrency = @max(@as(usize, 1), max_concurrency),
        .user_agent = browser_user_agent,
        .requests = requests,
    }, .{}, &payload_writer.writer);

    const result = runChildCaptureWithInputAndOutputLimit(
        allocator,
        &.{
            node_executable,
            "-e",
            node_batch_request_script,
        },
        payload_writer.written(),
        computeBatchChildTimeoutMs(requests.len, @max(@as(usize, 1), max_concurrency)),
        &env_map,
        computeBatchChildOutputLimitBytes(requests.len),
    ) catch |err| switch (err) {
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
        .exited => |code| if (code != 0) return error.RequestFailed,
        else => return error.RequestFailed,
    }

    const parsed = parseNodeHttpOutput(allocator, result.stdout) orelse return error.CommandFailed;
    defer allocator.free(parsed.body);

    switch (parsed.outcome) {
        .ok => return try parseBatchNodeHttpOutput(allocator, parsed.body),
        .timeout => return error.TimedOut,
        .failed => return error.RequestFailed,
        .node_too_old => {
            logNodeRequirement();
            return error.NodeJsRequired;
        },
    }
}

fn runChildCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    env_map: ?*const std.process.Environ.Map,
) !ChildCaptureResult {
    return runChildCaptureWithInputAndOutputLimit(allocator, argv, null, timeout_ms, env_map, default_max_output_bytes);
}

fn runChildCaptureWithOutputLimit(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    timeout_ms: u64,
    env_map: ?*const std.process.Environ.Map,
    output_limit_bytes: usize,
) !ChildCaptureResult {
    return runChildCaptureWithInputAndOutputLimit(allocator, argv, null, timeout_ms, env_map, output_limit_bytes);
}

fn runChildCaptureWithInputAndOutputLimit(
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

fn computeBatchChildTimeoutMs(request_count: usize, max_concurrency: usize) u64 {
    const safe_concurrency = @max(@as(usize, 1), max_concurrency);
    const waves = @max(@as(usize, 1), (request_count + safe_concurrency - 1) / safe_concurrency);
    return @as(u64, @intCast(waves)) * request_timeout_ms_value + 2000;
}

fn computeBatchChildOutputLimitBytes(request_count: usize) usize {
    return std.math.mul(usize, default_max_output_bytes, @max(@as(usize, 1), request_count)) catch std.math.maxInt(usize);
}

fn resolveNodeExecutable(allocator: std.mem.Allocator) ![]u8 {
    return getEnvVarOwned(allocator, node_executable_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "node"),
        else => return err,
    };
}

fn maybeEnableNodeEnvProxy(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    node_env_proxy_supported: bool,
) !void {
    try maybeMapAllProxy(env_map);
    if (node_env_proxy_supported) {
        try maybeApplyWindowsSystemProxyFallback(allocator, env_map);
    }

    if (node_env_proxy_supported and env_map.get(node_use_env_proxy_env) == null and hasNodeProxyConfiguration(env_map)) {
        try env_map.put(node_use_env_proxy_env, "1");
    }
}

fn needsNodeEnvProxySupportCheck(env_map: *std.process.Environ.Map) bool {
    return builtin.os.tag == .windows or hasNodeProxyConfiguration(env_map) or hasAllProxyConfiguration(env_map);
}

fn hasAllProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("ALL_PROXY") != null or env_map.get("all_proxy") != null;
}

const NodeVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

const NodeEnvProxySupportCache = struct {
    mutex: std.Io.Mutex = .init,
    executable: ?[]u8 = null,
    supported: bool = false,
};

var node_env_proxy_support_cache: NodeEnvProxySupportCache = .{};

fn detectNodeEnvProxySupport(allocator: std.mem.Allocator, node_executable: []const u8) bool {
    return detectNodeEnvProxySupportWithTimeout(allocator, node_executable, child_process_timeout_ms_value);
}

fn detectNodeEnvProxySupportWithTimeout(
    allocator: std.mem.Allocator,
    node_executable: []const u8,
    timeout_ms: u64,
) bool {
    node_env_proxy_support_cache.mutex.lockUncancelable(app_runtime.io());
    if (node_env_proxy_support_cache.executable) |cached| {
        if (std.mem.eql(u8, cached, node_executable)) {
            const supported = node_env_proxy_support_cache.supported;
            node_env_proxy_support_cache.mutex.unlock(app_runtime.io());
            return supported;
        }
    }
    node_env_proxy_support_cache.mutex.unlock(app_runtime.io());

    const result = runChildCapture(allocator, &.{ node_executable, "--version" }, timeout_ms, null) catch return false;
    defer result.deinit(allocator);

    if (result.timed_out) return false;
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    const version = parseNodeVersion(result.stdout) catch return false;
    const supported = nodeVersionSupportsEnvProxy(version);

    node_env_proxy_support_cache.mutex.lockUncancelable(app_runtime.io());
    defer node_env_proxy_support_cache.mutex.unlock(app_runtime.io());
    if (node_env_proxy_support_cache.executable) |cached| {
        std.heap.page_allocator.free(cached);
    }
    node_env_proxy_support_cache.executable = std.heap.page_allocator.dupe(u8, node_executable) catch null;
    node_env_proxy_support_cache.supported = supported;
    return supported;
}

fn parseNodeVersion(raw: []const u8) !NodeVersion {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const version_text = if (trimmed.len != 0 and trimmed[0] == 'v') trimmed[1..] else trimmed;

    var parts = std.mem.splitScalar(u8, version_text, '.');
    const major_text = parts.next() orelse return error.InvalidVersion;
    const minor_text = parts.next() orelse return error.InvalidVersion;
    const patch_text = parts.next() orelse return error.InvalidVersion;

    return .{
        .major = try std.fmt.parseInt(u32, major_text, 10),
        .minor = try std.fmt.parseInt(u32, minor_text, 10),
        .patch = try std.fmt.parseInt(u32, patch_text, 10),
    };
}

fn nodeVersionSupportsEnvProxy(version: NodeVersion) bool {
    return version.major >= 24 or (version.major == 22 and version.minor >= 21);
}

fn maybeMapAllProxy(env_map: *std.process.Environ.Map) !void {
    const all_proxy = env_map.get("ALL_PROXY") orelse env_map.get("all_proxy");
    if (all_proxy) |proxy| {
        if (env_map.get("HTTP_PROXY") == null and env_map.get("http_proxy") == null) {
            try env_map.put("HTTP_PROXY", proxy);
        }
        if (env_map.get("HTTPS_PROXY") == null and env_map.get("https_proxy") == null) {
            try env_map.put("HTTPS_PROXY", proxy);
        }
    }
}

fn hasNodeProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("HTTP_PROXY") != null or
        env_map.get("http_proxy") != null or
        env_map.get("HTTPS_PROXY") != null or
        env_map.get("https_proxy") != null;
}

fn hasNoProxyConfiguration(env_map: *std.process.Environ.Map) bool {
    return env_map.get("NO_PROXY") != null or env_map.get("no_proxy") != null;
}

const windows_internet_settings_key = std.unicode.wtf8ToWtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings");
const windows_proxy_enable_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyEnable");
const windows_proxy_server_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyServer");
const windows_proxy_override_value = std.unicode.wtf8ToWtf16LeStringLiteral("ProxyOverride");

const WindowsSystemProxy = struct {
    http_proxy: ?[]u8 = null,
    https_proxy: ?[]u8 = null,
    no_proxy: ?[]u8 = null,

    fn deinit(self: *WindowsSystemProxy, allocator: std.mem.Allocator) void {
        if (self.http_proxy) |value| allocator.free(value);
        if (self.https_proxy) |value| allocator.free(value);
        if (self.no_proxy) |value| allocator.free(value);
        self.* = .{};
    }
};

fn maybeApplyWindowsSystemProxyFallback(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    if (builtin.os.tag != .windows) return;
    if (hasNodeProxyConfiguration(env_map)) return;

    var proxy = (try queryWindowsSystemProxyAlloc(allocator)) orelse return;
    defer proxy.deinit(allocator);

    if (proxy.http_proxy) |value| {
        if (env_map.get("HTTP_PROXY") == null and env_map.get("http_proxy") == null) {
            try env_map.put("HTTP_PROXY", value);
        }
    }
    if (proxy.https_proxy) |value| {
        if (env_map.get("HTTPS_PROXY") == null and env_map.get("https_proxy") == null) {
            try env_map.put("HTTPS_PROXY", value);
        }
    }
    if (proxy.no_proxy) |value| {
        if (!hasNoProxyConfiguration(env_map)) {
            try env_map.put("NO_PROXY", value);
        }
    }
}

fn queryWindowsSystemProxyAlloc(allocator: std.mem.Allocator) !?WindowsSystemProxy {
    if (builtin.os.tag != .windows) return null;

    const proxy_enabled = readWindowsRegistryDword(
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_enable_value,
    ) catch return null;
    if (proxy_enabled == 0) return null;

    const proxy_server = readWindowsRegistryStringAlloc(
        allocator,
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_server_value,
    ) catch |err| switch (err) {
        error.ValueNotFound, error.UnexpectedRegistryType, error.RegistryReadFailed => return null,
        else => return err,
    };
    defer allocator.free(proxy_server);

    const proxy_override = readWindowsRegistryStringAlloc(
        allocator,
        std.os.windows.HKEY_CURRENT_USER,
        windows_internet_settings_key,
        windows_proxy_override_value,
    ) catch |err| switch (err) {
        error.ValueNotFound, error.UnexpectedRegistryType, error.RegistryReadFailed => null,
        else => return err,
    };
    defer if (proxy_override) |value| allocator.free(value);

    return try deriveWindowsSystemProxyAlloc(allocator, proxy_server, proxy_override);
}

fn deriveWindowsSystemProxyAlloc(
    allocator: std.mem.Allocator,
    proxy_server_raw: []const u8,
    proxy_override_raw: ?[]const u8,
) !?WindowsSystemProxy {
    const proxy_server = std.mem.trim(u8, proxy_server_raw, " \t\r\n");
    if (proxy_server.len == 0) return null;

    var result = WindowsSystemProxy{};
    errdefer result.deinit(allocator);

    var default_proxy: ?[]u8 = null;
    defer if (default_proxy) |value| allocator.free(value);

    var entries = std.mem.splitScalar(u8, proxy_server, ';');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;

        if (std.mem.indexOfScalar(u8, entry, '=')) |eq_idx| {
            const key = std.mem.trim(u8, entry[0..eq_idx], " \t\r\n");
            const value = std.mem.trim(u8, entry[eq_idx + 1 ..], " \t\r\n");
            if (value.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(key, "http")) {
                if (result.http_proxy == null) result.http_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "http://");
            } else if (std.ascii.eqlIgnoreCase(key, "https")) {
                if (result.https_proxy == null) result.https_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "http://");
            } else if (std.ascii.eqlIgnoreCase(key, "socks")) {
                const socks_proxy = try normalizeWindowsProxyUrlAlloc(allocator, value, "socks://");
                defer allocator.free(socks_proxy);
                if (result.http_proxy == null) result.http_proxy = try allocator.dupe(u8, socks_proxy);
                if (result.https_proxy == null) result.https_proxy = try allocator.dupe(u8, socks_proxy);
            }
        } else if (default_proxy == null) {
            default_proxy = try normalizeWindowsProxyUrlAlloc(allocator, entry, "http://");
        }
    }

    if (default_proxy) |value| {
        if (result.http_proxy == null) result.http_proxy = try allocator.dupe(u8, value);
        if (result.https_proxy == null) result.https_proxy = try allocator.dupe(u8, value);
    }

    if (result.http_proxy == null and result.https_proxy == null) return null;

    if (proxy_override_raw) |raw| {
        result.no_proxy = try normalizeWindowsNoProxyAlloc(allocator, raw);
    }

    return result;
}

fn normalizeWindowsProxyUrlAlloc(allocator: std.mem.Allocator, raw: []const u8, default_scheme: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, trimmed);
    if (std.mem.indexOf(u8, trimmed, "://") != null) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ default_scheme, trimmed });
}

fn normalizeWindowsNoProxyAlloc(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    var overrides = std.mem.splitScalar(u8, raw, ';');
    while (overrides.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(entry, "<local>")) continue;
        if (entry[0] == '<' and entry[entry.len - 1] == '>') continue;
        try appendNoProxyEntry(allocator, &list, entry);
    }

    if (list.items.len == 0) return null;
    return try list.toOwnedSlice(allocator);
}

fn appendNoProxyEntry(allocator: std.mem.Allocator, list: *std.ArrayList(u8), entry: []const u8) !void {
    if (entry.len == 0) return;
    if (list.items.len != 0) try list.append(allocator, ',');
    try list.appendSlice(allocator, entry);
}

fn readWindowsRegistryDword(
    hkey: std.os.windows.HKEY,
    sub_key: [*:0]const u16,
    value_name: [*:0]const u16,
) error{ RegistryReadFailed, UnexpectedRegistryType, ValueNotFound }!u32 {
    if (builtin.os.tag != .windows) return error.ValueNotFound;

    var actual_type: std.os.windows.ULONG = undefined;
    var reg_size: u32 = @sizeOf(u32);
    var reg_value: u32 = 0;
    const rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_DWORD,
        &actual_type,
        &reg_value,
        &reg_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.DWORD)) return error.UnexpectedRegistryType;
    return reg_value;
}

fn readWindowsRegistryStringAlloc(
    allocator: std.mem.Allocator,
    hkey: std.os.windows.HKEY,
    sub_key: [*:0]const u16,
    value_name: [*:0]const u16,
) error{ OutOfMemory, RegistryReadFailed, UnexpectedRegistryType, ValueNotFound }![]u8 {
    if (builtin.os.tag != .windows) return error.ValueNotFound;

    var actual_type: std.os.windows.ULONG = undefined;
    var buf_size: u32 = 0;
    var rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_SZ | winreg.RRF_RT_REG_EXPAND_SZ,
        &actual_type,
        null,
        &buf_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.SZ) and
        actual_type != @intFromEnum(std.os.windows.REG.ValueType.EXPAND_SZ))
    {
        return error.UnexpectedRegistryType;
    }

    const buf = try allocator.alloc(u16, std.math.divCeil(u32, buf_size, 2) catch unreachable);
    defer allocator.free(buf);

    rc = winreg.RegGetValueW(
        hkey,
        sub_key,
        value_name,
        winreg.RRF_RT_REG_SZ | winreg.RRF_RT_REG_EXPAND_SZ,
        &actual_type,
        buf.ptr,
        &buf_size,
    );
    switch (@as(std.os.windows.Win32Error, @enumFromInt(rc))) {
        .SUCCESS => {},
        .FILE_NOT_FOUND => return error.ValueNotFound,
        else => return error.RegistryReadFailed,
    }
    if (actual_type != @intFromEnum(std.os.windows.REG.ValueType.SZ) and
        actual_type != @intFromEnum(std.os.windows.REG.ValueType.EXPAND_SZ))
    {
        return error.UnexpectedRegistryType;
    }

    const value_z: [*:0]const u16 = @ptrCast(buf.ptr);
    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(value_z)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryReadFailed,
    };
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

    const path_value = getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
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
        const path_ext = getEnvVarOwned(allocator, "PATHEXT") catch |err| switch (err) {
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
        std.Io.Dir.accessAbsolute(app_runtime.io(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(app_runtime.io(), path, .{}) catch return false;
    return true;
}

fn logNodeRequirement() void {
    std.log.warn("{s}", .{node_requirement_hint});
}

fn parseNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?ParsedNodeHttpOutput {
    const trimmed = std.mem.trimEnd(u8, output, "\r\n");
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

fn parseBatchNodeHttpOutput(allocator: std.mem.Allocator, output: []const u8) !BatchHttpResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .array => |array| array,
        else => return error.InvalidBatchOutput,
    };

    const items = try allocator.alloc(BatchItemResult, root.items.len);
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

    for (root.items, 0..) |entry, idx| {
        const obj = switch (entry) {
            .object => |object| object,
            else => return error.InvalidBatchOutput,
        };

        const encoded_body = switch (obj.get("body") orelse return error.InvalidBatchOutput) {
            .string => |value| value,
            else => return error.InvalidBatchOutput,
        };
        const status = switch (obj.get("status") orelse return error.InvalidBatchOutput) {
            .integer => |value| value,
            else => return error.InvalidBatchOutput,
        };
        const outcome_text = switch (obj.get("outcome") orelse return error.InvalidBatchOutput) {
            .string => |value| value,
            else => return error.InvalidBatchOutput,
        };

        items[idx] = .{
            .body = try decodeBase64Alloc(allocator, encoded_body),
            .status_code = if (status == 0) null else std.math.cast(u16, status) orelse return error.InvalidBatchOutput,
            .outcome = if (std.mem.eql(u8, outcome_text, "ok"))
                .ok
            else if (std.mem.eql(u8, outcome_text, "timeout"))
                .timeout
            else if (std.mem.eql(u8, outcome_text, "error"))
                .failed
            else
                return error.InvalidBatchOutput,
        };
    }

    return .{ .items = items };
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

test "run child capture times out child that trickles output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_name = switch (builtin.os.tag) {
        .windows => "trickle.ps1",
        else => "trickle.sh",
    };
    const script_data = switch (builtin.os.tag) {
        .windows =>
        \\for ($i = 0; $i -lt 30; $i++) {
        \\  [Console]::Out.Write(".")
        \\  [Console]::Out.Flush()
        \\  Start-Sleep -Milliseconds 100
        \\}
        ,
        else =>
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 30 ]; do
        \\  printf '.'
        \\  sleep 0.1
        \\  i=$((i + 1))
        \\done
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

    const result = runChildCapture(allocator, argv, 1000, null) catch |err| switch (err) {
        error.OutOfMemory => return error.SkipZigTest,
        else => return err,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.timed_out);
    try std.testing.expect(result.stdout.len > 0);
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
