const std = @import("std");
const auth = @import("../auth.zig");
const bdd = @import("bdd_helpers.zig");

fn b64url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = encoder.encode(buf, input);
    return buf;
}

test "parse auth info from jwt" {
    const gpa = std.testing.allocator;
    const chatgpt_account_id = "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";
    const chatgpt_user_id = "user-ESYgcy2QkOGZc0NoxSlFCeVT";

    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = "{\"email\":\"user@example.com\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"67fe2bbb-0de6-49a4-b2b3-d1df366d1faf\",\"chatgpt_user_id\":\"user-ESYgcy2QkOGZc0NoxSlFCeVT\",\"user_id\":\"user-ESYgcy2QkOGZc0NoxSlFCeVT\",\"chatgpt_plan_type\":\"pro\"}}";

    const h64 = try b64url(gpa, header);
    defer gpa.free(h64);
    const p64 = try b64url(gpa, payload);
    defer gpa.free(p64);

    const jwt = try std.mem.concat(gpa, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer gpa.free(jwt);

    const json = try std.fmt.allocPrint(gpa,
        "{{\"tokens\":{{\"access_token\":\"access-user@example.com\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ chatgpt_account_id, jwt },
    );
    defer gpa.free(json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = json });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);

    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.email != null);
    try std.testing.expect(std.mem.eql(u8, info.email.?, "user@example.com"));
    try std.testing.expect(info.chatgpt_account_id != null);
    try std.testing.expect(std.mem.eql(u8, info.chatgpt_account_id.?, chatgpt_account_id));
    try std.testing.expect(info.chatgpt_user_id != null);
    try std.testing.expect(std.mem.eql(u8, info.chatgpt_user_id.?, chatgpt_user_id));
    try std.testing.expect(info.record_key != null);
    const expected_record_key = try std.fmt.allocPrint(gpa, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
    defer gpa.free(expected_record_key);
    try std.testing.expect(std.mem.eql(u8, info.record_key.?, expected_record_key));
    try std.testing.expect(info.access_token != null);
    try std.testing.expect(std.mem.eql(u8, info.access_token.?, "access-user@example.com"));
}

test "api key auth" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = "{\"OPENAI_API_KEY\":\"sk-test\"}" });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);
    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .apikey);
}

test "parse auth info does not leak duplicated tokens when id token is missing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "auth.json",
        .data = "{\"tokens\":{\"access_token\":\"access-user@example.com\",\"account_id\":\"67fe2bbb-0de6-49a4-b2b3-d1df366d1faf\"}}",
    });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);

    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.email == null);
    try std.testing.expect(info.chatgpt_account_id == null);
    try std.testing.expect(info.access_token == null);
    try std.testing.expect(info.auth_mode == .chatgpt);
}

test "parse auth info frees allocations on account mismatch" {
    const gpa = std.testing.allocator;
    const token_account_id = "67fe2bbb-0de6-49a4-b2b3-d1df366d1faf";

    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = "{\"email\":\"user@example.com\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"518a44d9-ba75-4bad-87e5-ae9377042960\",\"chatgpt_user_id\":\"user-ESYgcy2QkOGZc0NoxSlFCeVT\",\"user_id\":\"user-ESYgcy2QkOGZc0NoxSlFCeVT\",\"chatgpt_plan_type\":\"pro\"}}";

    const h64 = try b64url(gpa, header);
    defer gpa.free(h64);
    const p64 = try b64url(gpa, payload);
    defer gpa.free(p64);

    const jwt = try std.mem.concat(gpa, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer gpa.free(jwt);

    const json = try std.fmt.allocPrint(gpa,
        "{{\"tokens\":{{\"access_token\":\"access-user@example.com\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ token_account_id, jwt },
    );
    defer gpa.free(json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = json });
    const tmp_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_path);
    const auth_path = try std.fs.path.join(gpa, &[_][]const u8{ tmp_path, "auth.json" });
    defer gpa.free(auth_path);

    try std.testing.expectError(error.AccountIdMismatch, auth.parseAuthInfo(gpa, auth_path));
}

test "convert cpa auth json produces a parseable standard auth snapshot" {
    const gpa = std.testing.allocator;
    const cpa_json = try bdd.cpaJsonWithEmailPlan(gpa, "cpa@example.com", "team");
    defer gpa.free(cpa_json);

    const converted = try auth.convertCpaAuthJson(gpa, cpa_json);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"auth_mode\": \"chatgpt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"refresh_token\": \"refresh-cpa@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"account_id\":") != null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.email != null);
    try std.testing.expect(std.mem.eql(u8, info.email.?, "cpa@example.com"));
    try std.testing.expect(info.record_key != null);
    try std.testing.expect(info.auth_mode == .chatgpt);
}

test "convert cpa auth json requires refresh token" {
    const gpa = std.testing.allocator;
    const cpa_json = try bdd.cpaJsonWithoutRefreshToken(gpa, "missing-refresh@example.com", "plus");
    defer gpa.free(cpa_json);

    try std.testing.expectError(error.MissingRefreshToken, auth.convertCpaAuthJson(gpa, cpa_json));
}
