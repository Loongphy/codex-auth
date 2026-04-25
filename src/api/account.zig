const std = @import("std");
const chatgpt_http = @import("http.zig");

pub const default_account_endpoint = "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27";

pub const AccountEntry = struct {
    account_id: []u8,
    account_name: ?[]u8,

    pub fn deinit(self: *const AccountEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.account_id);
        if (self.account_name) |name| allocator.free(name);
    }
};

pub const FetchResult = struct {
    entries: ?[]AccountEntry,
    status_code: ?u16,

    pub fn deinit(self: *const FetchResult, allocator: std.mem.Allocator) void {
        if (self.entries) |entries| {
            for (entries) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }
    }
};

pub fn fetchAccountsForTokenDetailed(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !FetchResult {
    const http_result = try chatgpt_http.runGetJsonCommand(allocator, endpoint, access_token, account_id);
    defer allocator.free(http_result.body);
    if (http_result.body.len == 0) {
        return .{
            .entries = null,
            .status_code = http_result.status_code,
        };
    }

    return .{
        .entries = try parseAccountsResponse(allocator, http_result.body),
        .status_code = http_result.status_code,
    };
}

pub fn parseAccountsResponse(allocator: std.mem.Allocator, body: []const u8) !?[]AccountEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };
    const accounts_value = root_obj.get("accounts") orelse return null;
    const accounts_obj = switch (accounts_value) {
        .object => |obj| obj,
        else => return null,
    };

    var entries = std.ArrayList(AccountEntry).empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var it = accounts_obj.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "default")) continue;
        const entry_obj = switch (kv.value_ptr.*) {
            .object => |obj| obj,
            else => continue,
        };
        const account_value = entry_obj.get("account") orelse continue;
        const account_obj = switch (account_value) {
            .object => |obj| obj,
            else => continue,
        };
        const account_id_value = account_obj.get("account_id") orelse continue;
        const account_id = switch (account_id_value) {
            .string => |value| value,
            else => continue,
        };
        if (account_id.len == 0) continue;

        const owned_account_id = try allocator.dupe(u8, account_id);
        errdefer allocator.free(owned_account_id);
        const owned_account_name = try parseAccountNameAlloc(allocator, account_obj.get("name"));
        errdefer if (owned_account_name) |name| allocator.free(name);

        try entries.append(allocator, .{
            .account_id = owned_account_id,
            .account_name = owned_account_name,
        });
    }

    return try entries.toOwnedSlice(allocator);
}

fn parseAccountNameAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const raw = switch (value orelse return null) {
        .string => |name| name,
        .null => return null,
        else => return null,
    };
    if (raw.len == 0) return null;
    return try allocator.dupe(u8, raw);
}
