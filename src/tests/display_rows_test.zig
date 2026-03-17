const std = @import("std");
const display_rows = @import("../display_rows.zig");
const registry = @import("../registry.zig");

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

test "Scenario: Given same email with two team accounts and one plus account when building display rows then they are grouped and numbered" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);
    try registry.setActiveAccountKey(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960");

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

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "backup", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 3);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "backup") or std.mem.eql(u8, rows.rows[1].account_cell, "work"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "backup") or std.mem.eql(u8, rows.rows[2].account_cell, "work"));
}
