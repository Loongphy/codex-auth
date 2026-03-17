const std = @import("std");
const registry = @import("registry.zig");

pub const AuthInfo = struct {
    email: ?[]u8,
    plan: ?registry.PlanType,
    auth_mode: registry.AuthMode,
    api_key_fingerprint: ?[]u8,

    pub fn deinit(self: *const AuthInfo, allocator: std.mem.Allocator) void {
        if (self.email) |e| allocator.free(e);
        if (self.api_key_fingerprint) |fp| allocator.free(fp);
    }
};

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

pub fn fingerprintApiKeyAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});

    const alphabet = "0123456789abcdef";
    var out: [12]u8 = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const byte = digest[i];
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return try allocator.dupe(u8, &out);
}

pub fn parseAuthInfo(allocator: std.mem.Allocator, auth_path: []const u8) !AuthInfo {
    var file = try std.fs.cwd().openFile(auth_path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = parsed.value;
    switch (root) {
        .object => |obj| {
            if (obj.get("OPENAI_API_KEY")) |key_val| {
                switch (key_val) {
                    .string => |s| {
                        if (s.len > 0) {
                            return AuthInfo{
                                .email = null,
                                .plan = null,
                                .auth_mode = .apikey,
                                .api_key_fingerprint = try fingerprintApiKeyAlloc(allocator, s),
                            };
                        }
                    },
                    else => {},
                }
            }

            if (obj.get("tokens")) |tokens_val| {
                switch (tokens_val) {
                    .object => |tobj| {
                        if (tobj.get("id_token")) |id_tok| {
                            switch (id_tok) {
                                .string => |jwt| {
                                    const payload = try decodeJwtPayload(allocator, jwt);
                                    defer allocator.free(payload);
                                    var payload_json = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
                                    defer payload_json.deinit();
                                    const claims = payload_json.value;

                                    switch (claims) {
                                        .object => |cobj| {
                                            var email: ?[]u8 = null;
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
                                                        if (aobj.get("chatgpt_plan_type")) |pt| {
                                                            switch (pt) {
                                                                .string => |s| plan = parsePlanType(s),
                                                                else => {},
                                                            }
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            }

                                            if (email != null and plan == null) {
                                                @panic("chatgpt auth missing plan");
                                            }

                                            return AuthInfo{
                                                .email = email,
                                                .plan = plan,
                                                .auth_mode = .chatgpt,
                                                .api_key_fingerprint = null,
                                            };
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

    return AuthInfo{ .email = null, .plan = null, .auth_mode = .chatgpt, .api_key_fingerprint = null };
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
