const std = @import("std");
const main_mod = @import("../main.zig");
const registry = @import("../registry.zig");
const bdd = @import("bdd_helpers.zig");

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn writeSnapshot(allocator: std.mem.Allocator, codex_home: []const u8, email: []const u8, plan: []const u8) !void {
    const account_key = try bdd.accountKeyForEmailAlloc(allocator, email);
    defer allocator.free(account_key);
    const snapshot_path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(snapshot_path);
    const auth_json = try bdd.authJsonWithEmailPlan(allocator, email, plan);
    defer allocator.free(auth_json);
    try std.fs.cwd().writeFile(.{ .sub_path = snapshot_path, .data = auth_json });
}

test "Scenario: Given alias and email queries when finding matching accounts then both matching strategies still work" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-A1B2C3D4E5F6::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    try appendAccount(gpa, &reg, "user-Z9Y8X7W6V5U4::518a44d9-ba75-4bad-87e5-ae9377042960", "other@example.com", "", .plus);

    var alias_matches = try main_mod.findMatchingAccounts(gpa, &reg, "work");
    defer alias_matches.deinit(gpa);
    try std.testing.expect(alias_matches.items.len == 1);
    try std.testing.expect(alias_matches.items[0] == 0);

    var email_matches = try main_mod.findMatchingAccounts(gpa, &reg, "other@example");
    defer email_matches.deinit(gpa);
    try std.testing.expect(email_matches.items.len == 1);
    try std.testing.expect(email_matches.items[0] == 1);
}

test "Scenario: Given account_id query when finding matching accounts then it is ignored for switch lookup" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-A1B2C3D4E5F6::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);

    var matches = try main_mod.findMatchingAccounts(gpa, &reg, "67fe2bbb");
    defer matches.deinit(gpa);
    try std.testing.expect(matches.items.len == 0);
}

test "Scenario: Given foreground commands when checking reconcile policy then config commands self-heal services but status does not" {
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .list = .{} }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .auto_switch = .{ .action = .enable } } }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .auto_switch = .{ .configure = .{
        .threshold_5h_percent = 12,
        .threshold_weekly_percent = null,
    } } } }));
    try std.testing.expect(main_mod.shouldReconcileManagedService(.{ .config = .{ .api_usage = .enable } }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .help = {} }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .status = {} }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .version = {} }));
    try std.testing.expect(!main_mod.shouldReconcileManagedService(.{ .daemon = .{ .mode = .once } }));
}

test "Scenario: Given foreground usage refresh targets when checking refresh policy then list and switch refresh but remove does not" {
    try std.testing.expect(main_mod.shouldRefreshForegroundUsage(.list));
    try std.testing.expect(main_mod.shouldRefreshForegroundUsage(.switch_account));
    try std.testing.expect(!main_mod.shouldRefreshForegroundUsage(.remove_account));
}

test "Scenario: Given removed active account with remaining accounts when reconciling then the best usage account becomes active" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const gamma_key = try bdd.accountKeyForEmailAlloc(gpa, "gamma@example.com");
    defer gpa.free(gamma_key);
    try appendAccount(gpa, &reg, alpha_key, "alpha@example.com", "", .plus);
    try appendAccount(gpa, &reg, gamma_key, "gamma@example.com", "", .team);

    const now = std.time.timestamp();
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 100, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .plus,
    };
    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    try writeSnapshot(gpa, codex_home, "alpha@example.com", "plus");
    try writeSnapshot(gpa, codex_home, "gamma@example.com", "team");

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, gamma_key));

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    const gamma_auth = try bdd.authJsonWithEmailPlan(gpa, "gamma@example.com", "team");
    defer gpa.free(gamma_auth);
    try std.testing.expectEqualStrings(gamma_auth, active_auth);
}

test "Scenario: Given stale active key with remaining accounts when reconciling after remove then it is treated as unset" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");

    var reg = makeRegistry();
    defer reg.deinit(gpa);
    const alpha_key = try bdd.accountKeyForEmailAlloc(gpa, "alpha@example.com");
    defer gpa.free(alpha_key);
    const gamma_key = try bdd.accountKeyForEmailAlloc(gpa, "gamma@example.com");
    defer gpa.free(gamma_key);
    try appendAccount(gpa, &reg, alpha_key, "alpha@example.com", "", .plus);
    try appendAccount(gpa, &reg, gamma_key, "gamma@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-stale::acct-stale");
    reg.active_account_activated_at_ms = 1;

    const now = std.time.timestamp();
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 100, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .plus,
    };
    reg.accounts.items[1].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    try writeSnapshot(gpa, codex_home, "alpha@example.com", "plus");
    try writeSnapshot(gpa, codex_home, "gamma@example.com", "team");

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    try std.testing.expect(reg.active_account_key != null);
    try std.testing.expect(std.mem.eql(u8, reg.active_account_key.?, gamma_key));

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    const active_auth = try bdd.readFileAlloc(gpa, active_auth_path);
    defer gpa.free(active_auth);
    const gamma_auth = try bdd.authJsonWithEmailPlan(gpa, "gamma@example.com", "team");
    defer gpa.free(gamma_auth);
    try std.testing.expectEqualStrings(gamma_auth, active_auth);
}

test "Scenario: Given no remaining accounts when reconciling after remove then active auth is deleted" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);

    var reg = makeRegistry();
    defer reg.deinit(gpa);

    const stale_auth = try bdd.authJsonWithEmailPlan(gpa, "removed@example.com", "pro");
    defer gpa.free(stale_auth);
    try tmp.dir.writeFile(.{ .sub_path = "auth.json", .data = stale_auth });

    try main_mod.reconcileActiveAuthAfterRemove(gpa, codex_home, &reg, true);

    const active_auth_path = try registry.activeAuthPath(gpa, codex_home);
    defer gpa.free(active_auth_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile(active_auth_path, .{}));
}

test "Scenario: Given newer registry schema when loading help config then default help settings are used" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const codex_home = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(codex_home);
    try tmp.dir.makePath("accounts");
    try tmp.dir.writeFile(.{
        .sub_path = "accounts/registry.json",
        .data =
        \\{
        \\  "schema_version": 999,
        \\  "auto_switch": {
        \\    "enabled": true,
        \\    "threshold_5h_percent": 1,
        \\    "threshold_weekly_percent": 1
        \\  },
        \\  "api": {
        \\    "usage": true
        \\  },
        \\  "accounts": []
        \\}
        ,
    });

    const help_cfg = main_mod.loadHelpConfig(gpa, codex_home);
    try std.testing.expectEqual(registry.defaultAutoSwitchConfig(), help_cfg.auto_switch);
    try std.testing.expectEqual(registry.defaultApiConfig(), help_cfg.api);
}
