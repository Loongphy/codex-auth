const std = @import("std");
const fs = @import("../compat_fs.zig");
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
        .account_name = null,
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
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business #1"));
    try std.testing.expect(rows.rows[1].is_active);
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Business #2"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
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

test "Scenario: Given grouped accounts with a prolite record when building display rows then labels use Pro Lite wording" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .prolite);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Pro Lite"));
}

test "Scenario: Given a grouped account with a fresher usage plan when building display rows then labels and ordering prefer the usage plan" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .free);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "Business"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "Free"));
}

test "Scenario: Given same-email accounts filtered down to one row when building display rows then singleton is decided from the rendered subset" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var grouped_rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer grouped_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), grouped_rows.rows.len);
    try std.testing.expect(grouped_rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, grouped_rows.rows[0].account_cell, "user@example.com"));

    const indices = [_]usize{0};
    var singleton_rows = try display_rows.buildDisplayRows(gpa, &reg, &indices);
    defer singleton_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), singleton_rows.rows.len);
    try std.testing.expect(singleton_rows.rows[0].account_index != null);
    try std.testing.expect(std.mem.eql(u8, singleton_rows.rows[0].account_cell, "user@example.com"));
}

test "Scenario: Given singleton accounts with alias and account name combinations when building display rows then email labels are preserved" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-4QmYj7PkN2sLx8AcVbR3TwHd::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "alias-name@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-8LnCq5VzR1mHx9SfKpT4JdWe::518a44d9-ba75-4bad-87e5-ae9377042960", "alias-only@example.com", "backup", .team);
    try appendAccount(gpa, &reg, "user-2RbFk6NsQ8vLp3XtJmW7CyHa::a4021fa5-998b-4774-989f-784fa69c367b", "name-only@example.com", "", .team);
    reg.accounts.items[2].account_name = try gpa.dupe(u8, "Sandbox");
    try appendAccount(gpa, &reg, "user-9TwHs4KmP7xNc2LdVrQ6BjYe::d8f0f19d-7b6f-4db8-b7a8-07b9fbf5774a", "fallback@example.com", "", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "alias-name@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "alias-only@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "fallback@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "name-only@example.com"));
}

test "Scenario: Given mixed singleton and grouped accounts when building display rows then singleton rows keep email while grouped rows keep preferred labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-6JpMv8XrT3nLc9QsHbW4DyKa::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "solo@example.com", "solo", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Solo Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "work", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "solo@example.com"));
    try std.testing.expect(rows.rows[1].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "work (Primary Workspace)"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
}

test "Scenario: Given grouped accounts with account names when building display rows then child labels use the same precedence" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Backup Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(
        (std.mem.eql(u8, rows.rows[1].account_cell, "work (Primary Workspace)") and
            std.mem.eql(u8, rows.rows[2].account_cell, "Backup Workspace")) or
            (std.mem.eql(u8, rows.rows[1].account_cell, "Backup Workspace") and
                std.mem.eql(u8, rows.rows[2].account_cell, "work (Primary Workspace)")),
    );
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "Plus"));
}
