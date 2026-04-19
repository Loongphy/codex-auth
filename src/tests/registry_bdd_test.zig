const std = @import("std");
const fs = @import("../compat_fs.zig");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

const SyncBddContext = struct {
    allocator: std.mem.Allocator,
    tmp: fs.TmpDir,
    codex_home: []u8,
    reg: registry.Registry,

    fn givenCleanCodexHome(allocator: std.mem.Allocator) !SyncBddContext {
        var tmp = fs.tmpDir(.{});
        const codex_home = try tmp.dir.realpathAlloc(allocator, ".");
        return SyncBddContext{
            .allocator = allocator,
            .tmp = tmp,
            .codex_home = codex_home,
            .reg = bdd.makeEmptyRegistry(),
        };
    }

    fn deinit(self: *SyncBddContext) void {
        self.reg.deinit(self.allocator);
        self.allocator.free(self.codex_home);
        self.tmp.cleanup();
    }

    fn givenActiveAuthJson(self: *SyncBddContext, auth_json: []const u8) !void {
        try self.tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = auth_json });
    }

    fn givenRegisteredAccount(self: *SyncBddContext, email: []const u8, alias: []const u8, plan: ?registry.PlanType) !void {
        try bdd.appendAccount(self.allocator, &self.reg, email, alias, plan);
    }

    fn whenSyncActiveAccountFromAuth(self: *SyncBddContext) !bool {
        return try registry.syncActiveAccountFromAuth(self.allocator, self.codex_home, &self.reg);
    }

    fn thenAccountCountShouldBe(self: *SyncBddContext, expected: usize) !void {
        try std.testing.expect(self.reg.accounts.items.len == expected);
    }

    fn thenActiveEmailShouldBe(self: *SyncBddContext, expected: []const u8) !void {
        const idx = bdd.findAccountIndexByEmail(&self.reg, expected) orelse return error.TestExpectedEqual;
        const expected_account_id = self.reg.accounts.items[idx].account_key;
        try std.testing.expect(self.reg.active_account_key != null);
        try std.testing.expect(std.mem.eql(u8, self.reg.active_account_key.?, expected_account_id));
    }

    fn thenAccountShouldExist(self: *SyncBddContext, email: []const u8) !void {
        const idx = bdd.findAccountIndexByEmail(&self.reg, email);
        try std.testing.expect(idx != null);
    }

    fn thenAccountAuthShouldMatchActive(self: *SyncBddContext, email: []const u8) !void {
        const active_auth_path = try registry.activeAuthPath(self.allocator, self.codex_home);
        defer self.allocator.free(active_auth_path);
        const account_id = try bdd.accountKeyForEmailAlloc(self.allocator, email);
        defer self.allocator.free(account_id);
        const account_auth_path = try registry.accountAuthPath(self.allocator, self.codex_home, account_id);
        defer self.allocator.free(account_auth_path);

        const active_data = try bdd.readFileAlloc(self.allocator, active_auth_path);
        defer self.allocator.free(active_data);
        const account_data = try bdd.readFileAlloc(self.allocator, account_auth_path);
        defer self.allocator.free(account_data);

        try std.testing.expect(std.mem.eql(u8, active_data, account_data));
    }
};

test "Scenario: Given empty registry when syncing auth then auto import and activate" {
    const gpa = std.testing.allocator;
    var ctx = try SyncBddContext.givenCleanCodexHome(gpa);
    defer ctx.deinit();

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "auto@example.com", "plus");
    defer gpa.free(active_auth);
    try ctx.givenActiveAuthJson(active_auth);

    const changed = try ctx.whenSyncActiveAccountFromAuth();

    try std.testing.expect(changed);
    try ctx.thenAccountCountShouldBe(1);
    try ctx.thenActiveEmailShouldBe("auto@example.com");
    try ctx.thenAccountAuthShouldMatchActive("auto@example.com");
}

test "Scenario: Given auth without email when syncing then sync is skipped" {
    const gpa = std.testing.allocator;
    var ctx = try SyncBddContext.givenCleanCodexHome(gpa);
    defer ctx.deinit();

    try ctx.givenRegisteredAccount("keep@example.com", "keep", .pro);
    const keep_account_id = try bdd.accountKeyForEmailAlloc(gpa, "keep@example.com");
    defer gpa.free(keep_account_id);
    try registry.setActiveAccountKey(gpa, &ctx.reg, keep_account_id);

    const invalid_auth = try bdd.authJsonWithoutEmail(gpa);
    defer gpa.free(invalid_auth);
    try ctx.givenActiveAuthJson(invalid_auth);

    const changed = try ctx.whenSyncActiveAccountFromAuth();

    try std.testing.expect(!changed);
    try ctx.thenAccountCountShouldBe(1);
    try ctx.thenActiveEmailShouldBe("keep@example.com");
}

test "Scenario: Given auth without account id when syncing then sync is skipped" {
    const gpa = std.testing.allocator;
    var ctx = try SyncBddContext.givenCleanCodexHome(gpa);
    defer ctx.deinit();

    try ctx.givenRegisteredAccount("keep@example.com", "keep", .pro);
    const keep_account_id = try bdd.accountKeyForEmailAlloc(gpa, "keep@example.com");
    defer gpa.free(keep_account_id);
    try registry.setActiveAccountKey(gpa, &ctx.reg, keep_account_id);

    const invalid_auth = try bdd.authJsonWithoutAccountId(gpa, "legacy@example.com", "pro");
    defer gpa.free(invalid_auth);
    try ctx.givenActiveAuthJson(invalid_auth);

    const changed = try ctx.whenSyncActiveAccountFromAuth();

    try std.testing.expect(!changed);
    try ctx.thenAccountCountShouldBe(1);
    try ctx.thenActiveEmailShouldBe("keep@example.com");
}

test "Scenario: Given malformed auth json when syncing then sync is skipped" {
    const gpa = std.testing.allocator;
    var ctx = try SyncBddContext.givenCleanCodexHome(gpa);
    defer ctx.deinit();

    try ctx.givenRegisteredAccount("keep@example.com", "keep", .pro);
    const keep_account_id = try bdd.accountKeyForEmailAlloc(gpa, "keep@example.com");
    defer gpa.free(keep_account_id);
    try registry.setActiveAccountKey(gpa, &ctx.reg, keep_account_id);

    try ctx.givenActiveAuthJson("{");

    const changed = try ctx.whenSyncActiveAccountFromAuth();

    try std.testing.expect(!changed);
    try ctx.thenAccountCountShouldBe(1);
    try ctx.thenActiveEmailShouldBe("keep@example.com");
}

test "Scenario: Given unmatched active auth email when syncing then append account and switch active" {
    const gpa = std.testing.allocator;
    var ctx = try SyncBddContext.givenCleanCodexHome(gpa);
    defer ctx.deinit();

    try ctx.givenRegisteredAccount("old@example.com", "old", .free);
    const old_account_id = try bdd.accountKeyForEmailAlloc(gpa, "old@example.com");
    defer gpa.free(old_account_id);
    try registry.setActiveAccountKey(gpa, &ctx.reg, old_account_id);

    const active_auth = try bdd.authJsonWithEmailPlan(gpa, "new@example.com", "team");
    defer gpa.free(active_auth);
    try ctx.givenActiveAuthJson(active_auth);

    const changed = try ctx.whenSyncActiveAccountFromAuth();

    try std.testing.expect(changed);
    try ctx.thenAccountCountShouldBe(2);
    try ctx.thenAccountShouldExist("old@example.com");
    try ctx.thenAccountShouldExist("new@example.com");
    try ctx.thenActiveEmailShouldBe("new@example.com");
    try ctx.thenAccountAuthShouldMatchActive("new@example.com");
}

test "Scenario: Given accounts with different remaining usage when selecting best then highest remaining wins" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try bdd.appendAccount(gpa, &reg, "low@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "high@example.com", "", null);

    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 85.0, .window_minutes = 300, .resets_at = null },
        .secondary = .{ .used_percent = 10.0, .window_minutes = 10080, .resets_at = null },
        .credits = null,
        .plan_type = null,
    };
    reg.accounts.items[0].last_usage_at = 100;

    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 40.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };
    reg.accounts.items[1].last_usage_at = 50;

    const best = registry.selectBestAccountIndexByUsage(&reg);
    try std.testing.expect(best != null);
    try std.testing.expect(best.? == 1);
}

test "Scenario: Given equal usage when selecting best then most recent snapshot wins tie" {
    const gpa = std.testing.allocator;
    var reg = bdd.makeEmptyRegistry();
    defer reg.deinit(gpa);

    try bdd.appendAccount(gpa, &reg, "older@example.com", "", null);
    try bdd.appendAccount(gpa, &reg, "newer@example.com", "", null);

    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 50.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };
    reg.accounts.items[0].last_usage_at = 100;

    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 50.0, .window_minutes = 300, .resets_at = null },
        .secondary = null,
        .credits = null,
        .plan_type = null,
    };
    reg.accounts.items[1].last_usage_at = 200;

    const best = registry.selectBestAccountIndexByUsage(&reg);
    try std.testing.expect(best != null);
    try std.testing.expect(best.? == 1);
}
