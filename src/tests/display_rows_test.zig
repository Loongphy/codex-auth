const std = @import("std");
const display_rows = @import("../display_rows.zig");
const registry = @import("../registry.zig");

fn makeRegistry() registry.Registry {
    return .{
        .version = 3,
        .active_account_id = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
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

test "Scenario: Given same email with two team accounts and one plus account when building display rows then they are grouped and numbered" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "acc-team-2", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "acc-team-1", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "acc-plus-1", "user@example.com", "", .plus);
    try registry.setActiveAccount(gpa, &reg, "acc-team-1");

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 4);
    try std.testing.expect(rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "team #1"));
    try std.testing.expect(rows.rows[1].is_active);
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "team #2"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "plus"));
    try std.testing.expect(rows.selectable_row_indices.len == 3);
}

test "Scenario: Given grouped accounts with aliases when building display rows then aliases override numbered plan labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "acc-team-2", "user@example.com", "work", .team);
    try appendAccount(gpa, &reg, "acc-team-1", "user@example.com", "backup", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 3);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "backup") or std.mem.eql(u8, rows.rows[1].account_cell, "work"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "backup") or std.mem.eql(u8, rows.rows[2].account_cell, "work"));
}
