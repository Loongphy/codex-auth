const std = @import("std");
const http = @import("http.zig");

pub const default_me_endpoint = "https://api.openai.com/v1/me";
pub const mini_max_global_base_url = "https://api.minimax.io/v1";
pub const mini_max_china_base_url = "https://api.minimaxi.com/v1";

const MiniMaxProfile = struct {
    models_endpoint: []const u8,
    user_id: []const u8,
    account_label: []const u8,
};

const mini_max_global_profile = MiniMaxProfile{
    .models_endpoint = "https://api.minimax.io/v1/models",
    .user_id = "minimax-global",
    .account_label = "api.minimax.io",
};

const mini_max_china_profile = MiniMaxProfile{
    .models_endpoint = "https://api.minimaxi.com/v1/models",
    .user_id = "minimax-china",
    .account_label = "api.minimaxi.com",
};

pub const MeResult = struct {
    user_id: []u8,
    email: []u8,
    name: ?[]u8,

    pub fn deinit(self: *const MeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.email);
        if (self.name) |value| allocator.free(value);
    }
};

pub fn fetchMeForApiKey(allocator: std.mem.Allocator, api_key: []const u8) !MeResult {
    return fetchMeForApiKeyFromEndpoint(allocator, default_me_endpoint, api_key);
}

pub fn fetchMeForApiKeyWithBaseUrl(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: ?[]const u8,
) !MeResult {
    const profile = miniMaxProfile(base_url orelse return fetchMeForApiKey(allocator, api_key)) orelse
        return fetchMeForApiKey(allocator, api_key);
    const http_result = try http.runBearerGetJsonCommand(allocator, profile.models_endpoint, api_key);
    defer allocator.free(http_result.body);

    if (http_result.status_code) |status| {
        if (status < 200 or status > 299) return error.MiniMaxModelsRequestFailed;
    }
    if (http_result.body.len == 0) return error.MiniMaxModelsRequestFailed;
    try parseMiniMaxModelsResponse(allocator, http_result.body);

    const owned_user_id = try allocator.dupe(u8, profile.user_id);
    errdefer allocator.free(owned_user_id);
    const owned_account_label = try allocator.dupe(u8, profile.account_label);
    errdefer allocator.free(owned_account_label);
    const owned_name = try allocator.dupe(u8, "MiniMax");
    errdefer allocator.free(owned_name);

    return .{
        .user_id = owned_user_id,
        .email = owned_account_label,
        .name = owned_name,
    };
}

pub fn miniMaxModelsEndpoint(base_url: []const u8) ?[]const u8 {
    const profile = miniMaxProfile(base_url) orelse return null;
    return profile.models_endpoint;
}

pub fn parseMiniMaxModelsResponse(allocator: std.mem.Allocator, body: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidMiniMaxModelsResponse,
    };
    const models = switch (obj.get("data") orelse return error.InvalidMiniMaxModelsResponse) {
        .array => |value| value,
        else => return error.InvalidMiniMaxModelsResponse,
    };
    for (models.items) |model| {
        const model_obj = switch (model) {
            .object => |value| value,
            else => continue,
        };
        if (nonEmptyStringField(model_obj, "id") != null) return;
    }
    return error.InvalidMiniMaxModelsResponse;
}

pub fn fetchMeForApiKeyFromEndpoint(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
) !MeResult {
    const http_result = try http.runBearerGetJsonCommand(allocator, endpoint, api_key);
    defer allocator.free(http_result.body);

    if (http_result.status_code) |status| {
        if (status < 200 or status > 299) return error.OpenAIMeRequestFailed;
    }
    if (http_result.body.len == 0) return error.OpenAIMeRequestFailed;

    return try parseMeResponse(allocator, http_result.body);
}

pub fn parseMeResponse(allocator: std.mem.Allocator, body: []const u8) !MeResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidOpenAIMeResponse,
    };

    const id = nonEmptyStringField(obj, "id") orelse
        nonEmptyStringField(obj, "user_id") orelse
        return error.MissingOpenAIUserId;
    const email = nonEmptyStringField(obj, "email") orelse return error.MissingEmail;
    const name = nonEmptyStringField(obj, "name");

    const owned_user_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_user_id);
    const owned_email = try normalizeEmailAlloc(allocator, email);
    errdefer allocator.free(owned_email);
    const owned_name = if (name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_name) |value| allocator.free(value);

    return .{
        .user_id = owned_user_id,
        .email = owned_email,
        .name = owned_name,
    };
}

fn nonEmptyStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

fn miniMaxProfile(base_url: []const u8) ?MiniMaxProfile {
    const trimmed = std.mem.trim(u8, base_url, &std.ascii.whitespace);
    const normalized = std.mem.trimEnd(u8, trimmed, "/");
    if (std.mem.eql(u8, normalized, mini_max_global_base_url)) return mini_max_global_profile;
    if (std.mem.eql(u8, normalized, mini_max_china_base_url)) return mini_max_china_profile;
    return null;
}
