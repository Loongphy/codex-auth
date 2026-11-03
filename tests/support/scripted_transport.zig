const std = @import("std");
const transport_mod = @import("codex_auth").api.transport;

const Transport = transport_mod.Transport;
const HttpResult = transport_mod.HttpResult;

/// In-memory `Transport` implementation for port-level tests: responses are
/// queued per verb, every request is recorded for structured assertions, and
/// a queued error simulates a transport failure. Lives in tests/support so
/// production code never sees a test seam.
pub const Step = union(enum) {
    respond: struct { body: []const u8, status_code: ?u16 },
    fail: anyerror,
};

pub const RecordedRequest = struct {
    endpoint: []u8,
    access_token: []u8,
    account_id: []u8,
    body: ?[]u8,
};

pub const ScriptedTransport = struct {
    allocator: std.mem.Allocator,
    post_steps: std.ArrayList(Step) = .empty,
    requests: std.ArrayList(RecordedRequest) = .empty,

    pub fn init(allocator: std.mem.Allocator) ScriptedTransport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ScriptedTransport) void {
        for (self.post_steps.items) |step| switch (step) {
            .respond => |r| self.allocator.free(r.body),
            .fail => {},
        };
        self.post_steps.deinit(self.allocator);
        for (self.requests.items) |*req| {
            self.allocator.free(req.endpoint);
            self.allocator.free(req.access_token);
            self.allocator.free(req.account_id);
            if (req.body) |body| self.allocator.free(body);
        }
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transport(self: *ScriptedTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Queues one scripted response; the body is copied, so the caller keeps
    /// owning the text it passed in.
    pub fn queuePostJson(self: *ScriptedTransport, body: []const u8, status_code: ?u16) !void {
        try self.post_steps.append(self.allocator, .{ .respond = .{ .body = try self.allocator.dupe(u8, body), .status_code = status_code } });
    }

    pub fn queuePostJsonFailure(self: *ScriptedTransport, err: anyerror) !void {
        try self.post_steps.append(self.allocator, .{ .fail = err });
    }

    fn record(self: *ScriptedTransport, endpoint: []const u8, access_token: []const u8, account_id: []const u8, body: ?[]const u8) !void {
        try self.requests.append(self.allocator, .{
            .endpoint = try self.allocator.dupe(u8, endpoint),
            .access_token = try self.allocator.dupe(u8, access_token),
            .account_id = try self.allocator.dupe(u8, account_id),
            .body = if (body) |b| try self.allocator.dupe(u8, b) else null,
        });
    }

    fn takePostStep(self: *ScriptedTransport) !Step {
        if (self.post_steps.items.len == 0) return error.UnscriptedRequest;
        return self.post_steps.orderedRemove(0);
    }

    fn selfFrom(ptr: *anyopaque) *ScriptedTransport {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable = Transport.VTable{
        .get_json = getJson,
        .bearer_get_json = bearerGetJson,
        .get_json_batch = getJsonBatch,
        .post_json = postJson,
    };

    fn getJson(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8) anyerror!HttpResult {
        _ = allocator;
        try selfFrom(ptr).record(endpoint, access_token, account_id, null);
        return error.UnscriptedVerb;
    }

    fn bearerGetJson(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8) anyerror!HttpResult {
        _ = allocator;
        try selfFrom(ptr).record(endpoint, access_token, "", null);
        return error.UnscriptedVerb;
    }

    fn getJsonBatch(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, requests: []const transport_mod.BatchRequest, max_concurrency: usize) anyerror!transport_mod.BatchHttpResult {
        _ = allocator;
        _ = requests;
        _ = max_concurrency;
        try selfFrom(ptr).record(endpoint, "", "", null);
        return error.UnscriptedVerb;
    }

    fn postJson(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, access_token: []const u8, account_id: []const u8, body_json: []const u8) anyerror!HttpResult {
        const self = selfFrom(ptr);
        try self.record(endpoint, access_token, account_id, body_json);
        const step = try self.takePostStep();
        switch (step) {
            .fail => |err| return err,
            .respond => |r| {
                defer self.allocator.free(r.body);
                return .{
                    .body = try allocator.dupe(u8, r.body),
                    .status_code = r.status_code,
                };
            },
        }
    }
};
