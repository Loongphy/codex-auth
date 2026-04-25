const std = @import("std");
const types = @import("http_types.zig");
const env = @import("http_env.zig");
const child = @import("http_child.zig");
const proxy = @import("http_proxy.zig");
const executable = @import("http_executable.zig");
const parse = @import("http_parse.zig");

const HttpResult = types.HttpResult;
const BatchRequest = types.BatchRequest;
const BatchHttpResult = types.BatchHttpResult;
const BatchItemResult = types.BatchItemResult;
const request_timeout_ms = types.request_timeout_ms;
const request_timeout_ms_value = types.request_timeout_ms_value;
const child_process_timeout_ms_value = types.child_process_timeout_ms_value;
const browser_user_agent = types.browser_user_agent;
const getEnvMap = env.getEnvMap;
const resolveNodeExecutable = executable.resolveNodeExecutable;
const resolveNodeExecutableForLaunchAlloc = executable.resolveNodeExecutableForLaunchAlloc;
const logNodeRequirement = executable.logNodeRequirement;
const runChildCapture = child.runChildCapture;
const runChildCaptureWithInputAndOutputLimit = child.runChildCaptureWithInputAndOutputLimit;
const computeBatchChildTimeoutMs = child.computeBatchChildTimeoutMs;
const computeBatchChildOutputLimitBytes = child.computeBatchChildOutputLimitBytes;
const parseNodeHttpOutput = parse.parseNodeHttpOutput;
const parseBatchNodeHttpOutput = parse.parseBatchNodeHttpOutput;
const needsNodeEnvProxySupportCheck = proxy.needsNodeEnvProxySupportCheck;
const detectNodeEnvProxySupport = proxy.detectNodeEnvProxySupport;
const maybeEnableNodeEnvProxy = proxy.maybeEnableNodeEnvProxy;

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
