const std = @import("std");
const codex_auth = @import("codex_auth");

const auto = codex_auth.auto;
const fixtures = @import("support/fixtures.zig");
const test_fixtures = fixtures;
const registry = codex_auth.registry;
const CandidateIndex = auto.CandidateIndex;

test "candidate index refreshes cached ranking after a reset window expires" {
    const gpa = std.testing.allocator;

    var reg = fixtures.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try fixtures.appendAccount(gpa, &reg, "active@example.com", "", null);
    try fixtures.appendAccount(gpa, &reg, "reset@example.com", "", null);
    try fixtures.appendAccount(gpa, &reg, "steady@example.com", "", null);

    const active_account_key = try fixtures.accountKeyForEmailAlloc(gpa, "active@example.com");
    defer gpa.free(active_account_key);
    const reset_account_key = try fixtures.accountKeyForEmailAlloc(gpa, "reset@example.com");
    defer gpa.free(reset_account_key);
    const steady_account_key = try fixtures.accountKeyForEmailAlloc(gpa, "steady@example.com");
    defer gpa.free(steady_account_key);

    try registry.setActiveAccountKey(gpa, &reg, active_account_key);

    const reset_idx = registry.findAccountIndexByAccountKey(&reg, reset_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[reset_idx].last_usage = .{
        .primary = .{ .used_percent = 95.0, .window_minutes = 300, .resets_at = 1010 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[reset_idx].last_usage_at = 100;

    const steady_idx = registry.findAccountIndexByAccountKey(&reg, steady_account_key) orelse return error.TestExpectedEqual;
    reg.accounts.items[steady_idx].last_usage = .{
        .primary = .{ .used_percent = 60.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
    };
    reg.accounts.items[steady_idx].last_usage_at = 50;

    var index = CandidateIndex{};
    defer index.deinit(gpa);

    try index.rebuild(gpa, &reg, 1000);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, steady_account_key));

    try index.rebuildIfScoreExpired(gpa, &reg, 1011);
    try std.testing.expect(index.best() != null);
    try std.testing.expect(std.mem.eql(u8, index.best().?.account_key, reset_account_key));
}
