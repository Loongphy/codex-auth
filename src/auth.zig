const std = @import("std");
const registry = @import("registry.zig");

pub const AuthInfo = struct {
    email: ?[]u8,
    chatgpt_account_id: ?[]u8,
    chatgpt_user_id: ?[]u8,
    record_key: ?[]u8,
    access_token: ?[]u8,
    plan: ?registry.PlanType,
    auth_mode: registry.AuthMode,

    pub fn deinit(self: *const AuthInfo, allocator: std.mem.Allocator) void {
        if (self.email) |e| allocator.free(e);
        if (self.chatgpt_account_id) |id| allocator.free(id);
        if (self.chatgpt_user_id) |id| allocator.free(id);
        if (self.record_key) |key| allocator.free(key);
        if (self.access_token) |token| allocator.free(token);
    }
};

const StandardAuthJson = struct {
    auth_mode: []const u8,
    OPENAI_API_KEY: ?[]const u8,
    tokens: struct {
        id_token: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        account_id: []const u8,
    },
    last_refresh: []const u8,
};

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

fn recordKeyAlloc(
    allocator: std.mem.Allocator,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
}

pub fn parseAuthInfo(allocator: std.mem.Allocator, auth_path: []const u8) !AuthInfo {
    var file = try std.fs.cwd().openFile(auth_path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    return try parseAuthInfoData(allocator, data);
}

pub fn parseAuthInfoData(allocator: std.mem.Allocator, data: []const u8) !AuthInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = parsed.value;
    switch (root) {
        .object => |obj| {
        if (obj.get("OPENAI_API_KEY")) |key_val| {
            switch (key_val) {
                .string => |s| {
                    if (s.len > 0) return AuthInfo{
                        .email = null,
                        .chatgpt_account_id = null,
                        .chatgpt_user_id = null,
                        .record_key = null,
                        .access_token = null,
                        .plan = null,
                        .auth_mode = .apikey,
                    };
                },
                else => {},
            }
        }

        if (obj.get("tokens")) |tokens_val| {
            switch (tokens_val) {
                .object => |tobj| {
                    var access_token: ?[]u8 = null;
                    defer if (access_token) |token| allocator.free(token);
                    access_token = if (tobj.get("access_token")) |access_token_val| switch (access_token_val) {
                        .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                        else => null,
                    } else null;
                    var token_chatgpt_account_id: ?[]u8 = null;
                    defer if (token_chatgpt_account_id) |id| allocator.free(id);
                    token_chatgpt_account_id = if (tobj.get("account_id")) |account_id_val| switch (account_id_val) {
                        .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                        else => null,
                    } else null;
                    if (tobj.get("id_token")) |id_tok| {
                        switch (id_tok) {
                            .string => |jwt| {
                                const payload = try decodeJwtPayload(allocator, jwt);
                                defer allocator.free(payload);
                                var payload_json = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
                                defer payload_json.deinit();
                                const claims = payload_json.value;

                                var jwt_chatgpt_account_id: ?[]u8 = null;
                                defer if (jwt_chatgpt_account_id) |id| allocator.free(id);
                                var chatgpt_user_id: ?[]u8 = null;
                                defer if (chatgpt_user_id) |id| allocator.free(id);
                                switch (claims) {
                                    .object => |cobj| {
                                        var email: ?[]u8 = null;
                                        defer if (email) |e| allocator.free(e);
                                        if (cobj.get("email")) |e| {
                                            switch (e) {
                                                .string => |s| email = try normalizeEmailAlloc(allocator, s),
                                                else => {},
                                            }
                                        }

                                        var plan: ?registry.PlanType = null;
                                        if (cobj.get("https://api.openai.com/auth")) |auth_obj| {
                                            switch (auth_obj) {
                                                .object => |aobj| {
                                                    if (aobj.get("chatgpt_account_id")) |ai| {
                                                        switch (ai) {
                                                            .string => |s| {
                                                                if (s.len > 0) {
                                                                    jwt_chatgpt_account_id = try allocator.dupe(u8, s);
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                    if (aobj.get("chatgpt_plan_type")) |pt| {
                                                        switch (pt) {
                                                            .string => |s| plan = parsePlanType(s),
                                                            else => {},
                                                        }
                                                    }
                                                    if (aobj.get("chatgpt_user_id")) |uid| {
                                                        switch (uid) {
                                                            .string => |s| {
                                                                if (s.len > 0) {
                                                                    chatgpt_user_id = try allocator.dupe(u8, s);
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    } else if (aobj.get("user_id")) |uid| {
                                                        switch (uid) {
                                                            .string => |s| {
                                                                if (s.len > 0) {
                                                                    chatgpt_user_id = try allocator.dupe(u8, s);
                                                                }
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                },
                                                else => {},
                                            }
                                        }

                                        const chatgpt_account_id = token_chatgpt_account_id orelse return error.MissingAccountId;
                                        if (jwt_chatgpt_account_id == null) return error.MissingAccountId;
                                        if (!std.mem.eql(u8, chatgpt_account_id, jwt_chatgpt_account_id.?)) return error.AccountIdMismatch;
                                        allocator.free(jwt_chatgpt_account_id.?);
                                        jwt_chatgpt_account_id = null;
                                        const chatgpt_user_id_value = chatgpt_user_id orelse return error.MissingChatgptUserId;
                                        const record_key = try recordKeyAlloc(allocator, chatgpt_user_id_value, chatgpt_account_id);

                                        const info = AuthInfo{
                                            .email = email,
                                            .chatgpt_account_id = chatgpt_account_id,
                                            .chatgpt_user_id = chatgpt_user_id_value,
                                            .record_key = record_key,
                                            .access_token = access_token,
                                            .plan = plan,
                                            .auth_mode = .chatgpt,
                                        };
                                        email = null;
                                        token_chatgpt_account_id = null;
                                        chatgpt_user_id = null;
                                        access_token = null;
                                        return info;
                                    },
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        },
        else => {},
    }

    return AuthInfo{
        .email = null,
        .chatgpt_account_id = null,
        .chatgpt_user_id = null,
        .record_key = null,
        .access_token = null,
        .plan = null,
        .auth_mode = .chatgpt,
    };
}

pub fn convertCpaAuthJson(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCpaFormat,
    };

    const refresh_token = jsonStringField(obj, "refresh_token") orelse return error.MissingRefreshToken;
    if (refresh_token.len == 0) return error.MissingRefreshToken;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(StandardAuthJson{
        .auth_mode = "chatgpt",
        .OPENAI_API_KEY = null,
        .tokens = .{
            .id_token = jsonStringFieldOrDefault(obj, "id_token"),
            .access_token = jsonStringFieldOrDefault(obj, "access_token"),
            .refresh_token = refresh_token,
            .account_id = jsonStringFieldOrDefault(obj, "account_id"),
        },
        .last_refresh = jsonStringFieldOrDefault(obj, "last_refresh"),
    }, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

pub fn decodeJwtPayload(allocator: std.mem.Allocator, jwt: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next();
    const payload_b64 = it.next() orelse return error.InvalidJwt;
    _ = it.next() orelse return error.InvalidJwt;

    const decoded = try base64UrlNoPadDecode(allocator, payload_b64);
    return decoded;
}

fn base64UrlNoPadDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out_len = decoder.calcSizeForSlice(input) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    decoder.decode(buf, input) catch return error.InvalidBase64;
    return buf;
}

fn parsePlanType(s: []const u8) registry.PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(s, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringFieldOrDefault(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return jsonStringField(obj, key) orelse "";
}
