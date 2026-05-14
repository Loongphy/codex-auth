const std = @import("std");
const codex_auth = @import("codex_auth");

const auth = codex_auth.auth.core;
const me_api = codex_auth.api.me;
const registry = codex_auth.registry;

test "parse OpenAI me response normalizes identity metadata" {
    const gpa = std.testing.allocator;
    const body =
        \\{
        \\  "id": "user_123",
        \\  "email": "USER@Example.COM",
        \\  "name": "User Example"
        \\}
    ;

    const me = try me_api.parseMeResponse(gpa, body);
    defer me.deinit(gpa);

    try std.testing.expectEqualStrings("user_123", me.user_id);
    try std.testing.expectEqualStrings("user@example.com", me.email);
    try std.testing.expectEqualStrings("User Example", me.name.?);
}

test "API key account key includes user id and stable key fingerprint" {
    const gpa = std.testing.allocator;

    const first = try registry.apiKeyAccountKeyAlloc(gpa, "user_123", "sk-test-a");
    defer gpa.free(first);
    const second = try registry.apiKeyAccountKeyAlloc(gpa, "user_123", "sk-test-b");
    defer gpa.free(second);
    const repeated = try registry.apiKeyAccountKeyAlloc(gpa, "user_123", "sk-test-a");
    defer gpa.free(repeated);

    try std.testing.expect(std.mem.startsWith(u8, first, "apikey::user_123::"));
    try std.testing.expectEqualStrings(first, repeated);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "API key auth record uses /v1/me email for list grouping" {
    const gpa = std.testing.allocator;

    var info = try auth.parseAuthInfoData(gpa,
        \\{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test-key"}
    );
    defer info.deinit(gpa);

    const me = me_api.MeResult{
        .user_id = try gpa.dupe(u8, "user_123"),
        .email = try gpa.dupe(u8, "person@example.com"),
        .name = null,
    };
    defer me.deinit(gpa);

    var rec = try registry.accountFromApiKeyMe(gpa, "", &info, &me);
    defer registry.freeAccountRecord(gpa, &rec);

    try std.testing.expectEqual(registry.AuthMode.apikey, rec.auth_mode.?);
    try std.testing.expectEqualStrings("person@example.com", rec.email);
    try std.testing.expectEqualStrings("user_123", rec.chatgpt_user_id);
    try std.testing.expect(std.mem.startsWith(u8, rec.account_key, "apikey::user_123::"));
    try std.testing.expect(rec.account_name != null);
    try std.testing.expect(std.mem.startsWith(u8, rec.account_name.?, "sk-"));
    try std.testing.expect(std.mem.indexOf(u8, rec.account_name.?, "***") != null);
}
