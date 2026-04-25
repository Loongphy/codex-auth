const std = @import("std");
const codex_auth = @import("codex_auth");

const account = codex_auth.auth.account;
const auth = codex_auth.auth.core;
const considerStoredAuthInfoForRefresh = account.considerStoredAuthInfoForRefresh;

fn makeStoredAuthInfoForTest(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    chatgpt_account_id: ?[]const u8,
    last_refresh: []const u8,
) !auth.AuthInfo {
    return .{
        .email = null,
        .chatgpt_account_id = if (chatgpt_account_id) |account_id| try allocator.dupe(u8, account_id) else null,
        .chatgpt_user_id = try allocator.dupe(u8, "user-1"),
        .record_key = null,
        .access_token = try allocator.dupe(u8, access_token),
        .last_refresh = try allocator.dupe(u8, last_refresh),
        .plan = null,
        .auth_mode = .chatgpt,
    };
}

test "stored auth selection skips newer snapshots missing account id" {
    const gpa = std.testing.allocator;

    var best_info: ?auth.AuthInfo = null;
    defer if (best_info) |*info| info.deinit(gpa);

    const valid = try makeStoredAuthInfoForTest(
        gpa,
        "stale-token",
        "acct-stale",
        "2026-03-20T00:00:00Z",
    );
    considerStoredAuthInfoForRefresh(gpa, &best_info, valid);

    const missing_account_id = try makeStoredAuthInfoForTest(
        gpa,
        "fresh-token",
        null,
        "2026-03-21T00:00:00Z",
    );
    considerStoredAuthInfoForRefresh(gpa, &best_info, missing_account_id);

    try std.testing.expect(best_info != null);
    try std.testing.expect(std.mem.eql(u8, best_info.?.access_token.?, "stale-token"));
    try std.testing.expect(std.mem.eql(u8, best_info.?.chatgpt_account_id.?, "acct-stale"));
    try std.testing.expect(std.mem.eql(u8, best_info.?.last_refresh.?, "2026-03-20T00:00:00Z"));
}
