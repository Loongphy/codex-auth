const std = @import("std");
const types = @import("http_types.zig");
const curl_impl = @import("http_curl.zig");

pub const HttpResult = types.HttpResult;
pub const BatchRequest = types.BatchRequest;
pub const BatchHttpResult = types.BatchHttpResult;

/// Transport port: the boundary between the endpoint modules (usage, me,
/// account, reset_credits) and the HTTP machinery.
///
/// Workflow entry points assemble `Transport.curl()`, so the shipped binary
/// always talks through the real curl child process. Tests wire a scripted
/// in-memory transport instead (tests/support/scripted_transport.zig) and
/// exercise endpoint logic in-process: typed request capture, queued
/// responses and fault injection, without spawning a process per request.
///
/// Endpoint modules migrate onto this port one at a time; reset_credits is
/// the reference. The curl assembly itself (argv, exit codes, timeouts,
/// output caps) stays covered by the fake-curl integration tests.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_json: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8) anyerror!HttpResult,
        bearer_get_json: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8) anyerror!HttpResult,
        get_json_batch: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, requests: []const BatchRequest, max_concurrency: usize) anyerror!BatchHttpResult,
        post_json: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8, body_json: []const u8) anyerror!HttpResult,
    };

    pub fn getJson(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8) !HttpResult {
        return self.vtable.get_json(self.ptr, allocator, endpoint, access_token, account_id);
    }

    pub fn bearerGetJson(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8) !HttpResult {
        return self.vtable.bearer_get_json(self.ptr, allocator, endpoint, access_token);
    }

    pub fn getJsonBatch(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, requests: []const BatchRequest, max_concurrency: usize) !BatchHttpResult {
        return self.vtable.get_json_batch(self.ptr, allocator, endpoint, requests, max_concurrency);
    }

    pub fn postJson(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8, body_json: []const u8) !HttpResult {
        return self.vtable.post_json(self.ptr, allocator, endpoint, access_token, account_id, body_json);
    }

    /// Production assembly: every verb shells out to the real curl child.
    pub fn curl() Transport {
        return .{ .ptr = &curl_state, .vtable = &curl_vtable };
    }
};

var curl_state: u8 = 0;

const curl_vtable = Transport.VTable{
    .get_json = curlGetJson,
    .bearer_get_json = curlBearerGetJson,
    .get_json_batch = curlGetJsonBatch,
    .post_json = curlPostJson,
};

fn curlGetJson(_: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8) anyerror!HttpResult {
    return curl_impl.runGetJsonCommand(allocator, endpoint, access_token, account_id);
}

fn curlBearerGetJson(_: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8) anyerror!HttpResult {
    return curl_impl.runBearerGetJsonCommand(allocator, endpoint, access_token);
}

fn curlGetJsonBatch(_: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, requests: []const BatchRequest, max_concurrency: usize) anyerror!BatchHttpResult {
    return curl_impl.runGetJsonBatchCommand(allocator, endpoint, requests, max_concurrency);
}

fn curlPostJson(_: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8, body_json: []const u8) anyerror!HttpResult {
    return curl_impl.runCurlPostJsonCommand(allocator, endpoint, access_token, account_id, body_json);
}
