const std = @import("std");
const app_runtime = @import("codex_auth").core.runtime;
const auth = @import("codex_auth").auth.core;
const fixtures = @import("support/fixtures.zig");

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

    const json = try std.fmt.allocPrint(
        gpa,
        "{{\"tokens\":{{\"access_token\":\"access-user@example.com\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ chatgpt_account_id, jwt },
    );
    defer gpa.free(json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(app_runtime.io(), .{ .sub_path = "auth.json", .data = json });
    const auth_path = try app_runtime.realPathFileAlloc(gpa, tmp.dir, "auth.json");
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

test "parse auth info uses default organization when account id is missing" {
    const gpa = std.testing.allocator;
    const chatgpt_account_id = "org-AAUtH9infujszmwhH1BkVd9n";
    const chatgpt_user_id = "user-FWx8fOqtJ2EIvndopK8mPrk4";

    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = "{\"email\":\"org-user@example.com\",\"https://api.openai.com/auth\":{\"organizations\":[{\"id\":\"org-other\",\"is_default\":false,\"role\":\"member\",\"title\":\"Other\"},{\"id\":\"org-AAUtH9infujszmwhH1BkVd9n\",\"is_default\":true,\"role\":\"owner\",\"title\":\"Default\"}],\"groups\":[],\"localhost\":true,\"user_id\":\"user-FWx8fOqtJ2EIvndopK8mPrk4\"}}";

    const h64 = try b64url(gpa, header);
    defer gpa.free(h64);
    const p64 = try b64url(gpa, payload);
    defer gpa.free(p64);

    const jwt = try std.mem.concat(gpa, u8, &[_][]const u8{ h64, ".", p64, ".sig" });
    defer gpa.free(jwt);

    const json = try std.fmt.allocPrint(
        gpa,
        "{{\"tokens\":{{\"access_token\":\"access-org-user@example.com\",\"account_id\":\"\",\"id_token\":\"{s}\"}}}}",
        .{jwt},
    );
    defer gpa.free(json);

    const info = try auth.parseAuthInfoData(gpa, json);
    defer info.deinit(gpa);
    try std.testing.expect(info.email != null);
    try std.testing.expect(std.mem.eql(u8, info.email.?, "org-user@example.com"));
    try std.testing.expect(info.chatgpt_account_id != null);
    try std.testing.expect(std.mem.eql(u8, info.chatgpt_account_id.?, chatgpt_account_id));
    try std.testing.expect(info.chatgpt_user_id != null);
    try std.testing.expect(std.mem.eql(u8, info.chatgpt_user_id.?, chatgpt_user_id));
    try std.testing.expect(info.record_key != null);
    const expected_record_key = try std.fmt.allocPrint(gpa, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
    defer gpa.free(expected_record_key);
    try std.testing.expect(std.mem.eql(u8, info.record_key.?, expected_record_key));
}

test "api key auth" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(app_runtime.io(), .{ .sub_path = "auth.json", .data = "{\"OPENAI_API_KEY\":\"sk-test\"}" });
    const auth_path = try app_runtime.realPathFileAlloc(gpa, tmp.dir, "auth.json");
    defer gpa.free(auth_path);
    const info = try auth.parseAuthInfo(gpa, auth_path);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .apikey);
}

test "parse auth info does not leak duplicated tokens when id token is missing" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(app_runtime.io(), .{
        .sub_path = "auth.json",
        .data = "{\"tokens\":{\"access_token\":\"access-user@example.com\",\"account_id\":\"67fe2bbb-0de6-49a4-b2b3-d1df366d1faf\"}}",
    });
    const auth_path = try app_runtime.realPathFileAlloc(gpa, tmp.dir, "auth.json");
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

    const json = try std.fmt.allocPrint(
        gpa,
        "{{\"tokens\":{{\"access_token\":\"access-user@example.com\",\"account_id\":\"{s}\",\"id_token\":\"{s}\"}}}}",
        .{ token_account_id, jwt },
    );
    defer gpa.free(json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(app_runtime.io(), .{ .sub_path = "auth.json", .data = json });
    const auth_path = try app_runtime.realPathFileAlloc(gpa, tmp.dir, "auth.json");
    defer gpa.free(auth_path);

    try std.testing.expectError(error.AccountIdMismatch, auth.parseAuthInfo(gpa, auth_path));
}

test "convert cpa auth json produces a parseable standard auth snapshot" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "cpa@example.com", "team");
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

test "convert cpa auth json omits empty last refresh" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "empty-refresh@example.com", "plus");
    defer gpa.free(cpa_json);
    const empty_last_refresh = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        "\"last_refresh\":\"2026-03-20T00:00:00Z\"",
        "\"last_refresh\":\"\"",
    );
    defer gpa.free(empty_last_refresh);

    const converted = try auth.convertCpaAuthJson(gpa, empty_last_refresh);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"last_refresh\"") == null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.last_refresh == null);
}

test "convert cpa auth json omits missing last refresh" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "missing-last-refresh@example.com", "plus");
    defer gpa.free(cpa_json);
    const without_last_refresh = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        ",\"last_refresh\":\"2026-03-20T00:00:00Z\"",
        "",
    );
    defer gpa.free(without_last_refresh);

    const converted = try auth.convertCpaAuthJson(gpa, without_last_refresh);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"last_refresh\"") == null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.last_refresh == null);
}

test "convert cpa auth json derives missing account id from id token" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "missing-account-id@example.com", "plus");
    defer gpa.free(cpa_json);
    const without_account_id = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        ",\"account_id\":\"",
        ",\"removed_account_id\":\"",
    );
    defer gpa.free(without_account_id);

    const expected_account_id = try fixtures.chatgptAccountIdForEmailAlloc(gpa, "missing-account-id@example.com");
    defer gpa.free(expected_account_id);
    const expected_json = try std.fmt.allocPrint(gpa, "\"account_id\": \"{s}\"", .{expected_account_id});
    defer gpa.free(expected_json);

    const converted = try auth.convertCpaAuthJson(gpa, without_account_id);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, expected_json) != null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.chatgpt_account_id != null);
    try std.testing.expect(std.mem.eql(u8, info.chatgpt_account_id.?, expected_account_id));
}

test "convert cpa auth json ignores top-level account id" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "mismatched-account-id@example.com", "plus");
    defer gpa.free(cpa_json);
    const source_account_id = try fixtures.chatgptAccountIdForEmailAlloc(gpa, "mismatched-account-id@example.com");
    defer gpa.free(source_account_id);
    const source_json = try std.fmt.allocPrint(gpa, "\"account_id\":\"{s}\"", .{source_account_id});
    defer gpa.free(source_json);
    const mismatched = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        source_json,
        "\"account_id\":\"wrong-account-id\"",
    );
    defer gpa.free(mismatched);

    const expected_json = try std.fmt.allocPrint(gpa, "\"account_id\": \"{s}\"", .{source_account_id});
    defer gpa.free(expected_json);

    const converted = try auth.convertCpaAuthJson(gpa, mismatched);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, expected_json) != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "wrong-account-id") == null);
}

test "convert cpa auth json omits missing refresh token" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithoutRefreshToken(gpa, "missing-refresh@example.com", "plus");
    defer gpa.free(cpa_json);

    const converted = try auth.convertCpaAuthJson(gpa, cpa_json);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"refresh_token\"") == null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .chatgpt);
    try std.testing.expect(info.access_token != null);
}

test "convert cpa auth json requires non-empty id token" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "missing-id-token@example.com", "plus");
    defer gpa.free(cpa_json);
    const without_id_token = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        ",\"id_token\":\"",
        ",\"removed_id_token\":\"",
    );
    defer gpa.free(without_id_token);

    try std.testing.expectError(error.MissingIdToken, auth.convertCpaAuthJson(gpa, without_id_token));
}

test "convert cpa auth json requires non-empty access token" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "missing-access-token@example.com", "plus");
    defer gpa.free(cpa_json);
    const without_access_token = try std.mem.replaceOwned(
        u8,
        gpa,
        cpa_json,
        ",\"access_token\":\"access-missing-access-token@example.com\"",
        "",
    );
    defer gpa.free(without_access_token);

    try std.testing.expectError(error.MissingAccessToken, auth.convertCpaAuthJson(gpa, without_access_token));
}

test "convert cpa auth json trims required token fields" {
    const gpa = std.testing.allocator;
    const cpa_json = try fixtures.cpaJsonWithEmailPlan(gpa, "trimmed-tokens@example.com", "plus");
    defer gpa.free(cpa_json);
    const spaced_id_token = try std.mem.replaceOwned(u8, gpa, cpa_json, "\"id_token\":\"", "\"id_token\":\"  ");
    defer gpa.free(spaced_id_token);
    const spaced_tokens = try std.mem.replaceOwned(
        u8,
        gpa,
        spaced_id_token,
        "\",\"access_token\":\"access-trimmed-tokens@example.com\"",
        "  \",\"access_token\":\" access-trimmed-tokens@example.com \"",
    );
    defer gpa.free(spaced_tokens);

    const converted = try auth.convertCpaAuthJson(gpa, spaced_tokens);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"id_token\": \"  ") == null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"access_token\": \" access-trimmed-tokens@example.com \"") == null);

    const info = try auth.parseAuthInfoData(gpa, converted);
    defer info.deinit(gpa);
    try std.testing.expect(info.auth_mode == .chatgpt);
    try std.testing.expect(info.access_token != null);
    try std.testing.expect(std.mem.eql(u8, info.access_token.?, "access-trimmed-tokens@example.com"));
}

test "convert standard auth json to cpa omits optional empty fields" {
    const gpa = std.testing.allocator;
    const standard_json = try fixtures.authJsonWithEmailPlan(gpa, "standard-no-refresh@example.com", "plus");
    defer gpa.free(standard_json);

    const converted = try auth.convertStandardAuthJsonToCpa(gpa, standard_json);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "\"id_token\": \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"access_token\": \"access-standard-no-refresh@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"refresh_token\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "\"last_refresh\"") == null);
}

test "convert standard auth json to cpa derives account id from id token" {
    const gpa = std.testing.allocator;
    const standard_json = try fixtures.authJsonWithEmailPlan(gpa, "standard-mismatched-account@example.com", "plus");
    defer gpa.free(standard_json);
    const expected_account_id = try fixtures.chatgptAccountIdForEmailAlloc(gpa, "standard-mismatched-account@example.com");
    defer gpa.free(expected_account_id);
    const stale_account_id_json = try std.fmt.allocPrint(gpa, "\"account_id\":\"{s}\"", .{expected_account_id});
    defer gpa.free(stale_account_id_json);
    const mismatched = try std.mem.replaceOwned(
        u8,
        gpa,
        standard_json,
        stale_account_id_json,
        "\"account_id\":\"stale-account-id\"",
    );
    defer gpa.free(mismatched);

    const expected_json = try std.fmt.allocPrint(gpa, "\"account_id\": \"{s}\"", .{expected_account_id});
    defer gpa.free(expected_json);

    const converted = try auth.convertStandardAuthJsonToCpa(gpa, mismatched);
    defer gpa.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, expected_json) != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "stale-account-id") == null);
}
