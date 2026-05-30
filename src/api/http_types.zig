const std = @import("std");
const version = @import("../version.zig");

pub const request_timeout_secs: []const u8 = "5";
pub const request_timeout_ms: []const u8 = "5000";
pub const request_timeout_ms_value: u64 = 5000;
pub const child_process_timeout_ms: []const u8 = "7000";
pub const child_process_timeout_ms_value: u64 = 7000;
pub const user_agent: []const u8 = "codex-auth/" ++ version.app_version;
pub const curl_requirement_hint = "curl is required for API-backed refresh. Install curl or use --skip-api.";

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
