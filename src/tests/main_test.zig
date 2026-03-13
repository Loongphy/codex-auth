const std = @import("std");
const main_mod = @import("../main.zig");
const registry = @import("../registry.zig");

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .last_attributed_rollout = null,
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_id: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    try reg.accounts.append(allocator, .{
        .account_id = try allocator.dupe(u8, account_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
    });
}

test "Scenario: Given alias and email queries when finding matching accounts then both matching strategies still work" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "acc-team-1234", "user@example.com", "work", .team);
    try appendAccount(gpa, &reg, "acc-plus-9999", "other@example.com", "", .plus);

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

    try appendAccount(gpa, &reg, "acc-team-1234", "user@example.com", "work", .team);

    var matches = try main_mod.findMatchingAccounts(gpa, &reg, "acc-team");
    defer matches.deinit(gpa);
    try std.testing.expect(matches.items.len == 0);
}
