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

pub const default_max_output_bytes = 1024 * 1024;

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

pub const NodeOutcome = enum {
    ok,
    timeout,
    failed,
    node_too_old,
};

pub const ParsedNodeHttpOutput = struct {
    body: []u8,
    status_code: ?u16,
    outcome: NodeOutcome,
};

pub const ChildCaptureResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,

    pub fn deinit(self: *const ChildCaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};
