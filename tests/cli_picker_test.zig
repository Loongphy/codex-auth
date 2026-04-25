const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const cli = codex_auth.cli;
const registry = codex_auth.registry;
const isQuitInput = cli.picker.isQuitInput;
const isQuitKey = cli.picker.isQuitKey;
const activeSelectableIndex = cli.picker.activeSelectableIndex;
const accountRowCount = cli.picker.accountRowCount;
const displayedIndexForSelectable = cli.picker.displayedIndexForSelectable;
const selectableIndexForAccountKey = cli.picker.selectableIndexForAccountKey;
const accountIdForSelectable = cli.picker.accountIdForSelectable;
const filterErroredRowsFromSelectableIndices = cli.rows.filterErroredRowsFromSelectableIndices;
const maybeAutoSwitchTargetKeyAlloc = cli.picker.maybeAutoSwitchTargetKeyAlloc;
const renderSwitchScreen = cli.render.renderSwitchScreen;
const renderSwitchList = cli.render.renderSwitchList;
const renderRemoveList = cli.render.renderRemoveList;
const buildSwitchRows = cli.rows.buildSwitchRows;
const buildSwitchRowsWithUsageOverrides = cli.rows.buildSwitchRowsWithUsageOverrides;
const switchTuiFooterText = cli.tui.switchTuiFooterText;
const removeTuiFooterText = cli.tui.removeTuiFooterText;
const importReportMarker = cli.output.importReportMarker;
const mapTuiOutputError = cli.tui.mapTuiOutputError;
const indexWidth = cli.render.indexWidth;
const ansi = struct {
    const red = "\x1b[31m";
};

test "Scenario: Given q quit input when checking switch picker helpers then both line and key shortcuts cancel selection" {
    try std.testing.expect(isQuitInput("q"));
    try std.testing.expect(isQuitInput("Q"));
    try std.testing.expect(!isQuitInput(""));
    try std.testing.expect(!isQuitInput("1"));
    try std.testing.expect(!isQuitInput("qq"));
    try std.testing.expect(isQuitKey('q'));
    try std.testing.expect(isQuitKey('Q'));
    try std.testing.expect(!isQuitKey('j'));
}

fn makeTestRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendTestAccount(
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

fn testUsageSnapshot(now: i64, used_5h: f64, used_weekly: f64) registry.RateLimitSnapshot {
    return .{
        .primary = .{
            .used_percent = used_5h,
            .window_minutes = 300,
            .resets_at = now + 3600,
        },
        .secondary = .{
            .used_percent = used_weekly,
            .window_minutes = 10080,
            .resets_at = now + 7 * 24 * 3600,
        },
        .credits = null,
        .plan_type = .pro,
    };
}

test "Scenario: Given grouped accounts when rendering switch list then child rows keep indentation" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01   Als's Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02   Free") != null);
}

test "Scenario: Given usage overrides when rendering switch list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "401") >= 2);
}

test "Scenario: Given usage overrides when selecting switch accounts then errored rows are skipped" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    try std.testing.expectEqual(@as(usize, 1), rows.selectable_row_indices.len);
    try std.testing.expect(std.mem.eql(u8, accountIdForSelectable(&rows, &reg, 0), "user-1::acc-1"));
}

test "Scenario: Given exhausted active usage when picking an auto-switch target then the best healthy candidate is chosen" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup-a@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "backup-b@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 100, 10);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 35, 15);
    reg.accounts.items[2].last_usage = testUsageSnapshot(now, 5, 8);

    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, null);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = null,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key != null);
    try std.testing.expectEqualStrings("user-1::acc-3", target_key.?);
}

test "Scenario: Given an active api status error when picking an auto-switch target then a healthy candidate is chosen" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 20, 20);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 10, 10);

    const usage_overrides = [_]?[]const u8{ "403", null };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = &usage_overrides,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key != null);
    try std.testing.expectEqualStrings("user-1::acc-2", target_key.?);
}

test "Scenario: Given only exhausted candidates when picking an auto-switch target then no target is returned" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshot(now, 100, 10);
    reg.accounts.items[1].last_usage = testUsageSnapshot(now, 100, 100);

    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, null);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    const target_key = try maybeAutoSwitchTargetKeyAlloc(gpa, .{
        .reg = &reg,
        .usage_overrides = null,
    }, &rows);
    defer if (target_key) |value| gpa.free(value);

    try std.testing.expect(target_key == null);
}

test "Scenario: Given usage overrides when rendering switch list then errored rows still show full display numbers" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "healthy@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "failed@example.com") != null);
}

test "Scenario: Given an active account when rendering switch list then non-selected active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "selected@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    var selected_displayed_idx: ?usize = null;
    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index.?;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, "user-1::acc-1")) {
            selected_displayed_idx = displayedIndexForSelectable(&rows, selectable_idx);
            break;
        }
    }

    try std.testing.expect(selected_displayed_idx != null);
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, selected_displayed_idx.?, false);

    const output = writer.buffered();
    var expected_selected_line_buf: [128]u8 = undefined;
    const expected_selected_line = try std.fmt.bufPrint(
        &expected_selected_line_buf,
        "> {d:0>2} selected@example.com",
        .{selected_displayed_idx.? + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_selected_line) != null);

    const active_displayed_idx = displayedIndexForSelectable(&rows, activeSelectableIndex(&rows).?).?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.fmt.bufPrint(
        &expected_active_line_buf,
        "* {d:0>2} active@example.com",
        .{active_displayed_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is selected when rendering switch list then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, 0, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> 01 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "* 01 active@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given an active account when rendering remove list then non-cursor active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "cursor@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    const cursor_idx = selectableIndexForAccountKey(&rows, &reg, "user-1::acc-1").?;
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, cursor_idx, &checked, false);

    const output = writer.buffered();
    var expected_cursor_line_buf: [128]u8 = undefined;
    const expected_cursor_line = try std.fmt.bufPrint(
        &expected_cursor_line_buf,
        "> [ ] {d:0>2} cursor@example.com",
        .{cursor_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_cursor_line) != null);

    const active_idx = selectableIndexForAccountKey(&rows, &reg, "user-1::acc-2").?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.fmt.bufPrint(
        &expected_active_line_buf,
        "* [ ] {d:0>2} active@example.com",
        .{active_idx + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is the remove cursor then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, 0, &checked, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> [ ] 01 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "* [ ] 01 active@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given switch live feedback when rendering switch screen then the action message stays below the footer" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchScreen(
        &writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        false,
        "Live refresh: api | Refresh in 9s",
        "Switched to healthy@example.com",
        "",
    );

    const output = writer.buffered();
    const footer_pos = std.mem.indexOf(u8, output, "Keys:") orelse return error.TestExpectedEqual;
    const action_pos = std.mem.indexOf(u8, output, "Switched to healthy@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(action_pos > footer_pos);
}

test "Scenario: Given Windows console labels when rendering unicode-prone output then ASCII fallbacks are used" {
    try std.testing.expectEqualStrings(
        "Keys: Up/Down or j/k, 1-9 type, Enter select, Esc or q quit\n",
        switchTuiFooterText(true),
    );
    try std.testing.expectEqualStrings(
        "Keys: Up/Down or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        removeTuiFooterText(true),
    );
    try std.testing.expectEqualStrings("[+]", importReportMarker(.imported, true));
    try std.testing.expectEqualStrings("[~]", importReportMarker(.updated, true));
    try std.testing.expectEqualStrings("[x]", importReportMarker(.skipped, true));
}

test "Scenario: Given non-Windows console labels when rendering unicode-prone output then the richer glyphs remain" {
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ or j/k, 1-9 type, Enter select, Esc or q quit\n",
        switchTuiFooterText(false),
    );
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ or j/k move, Space toggle, 1-9 type, Enter delete, Esc or q quit\n",
        removeTuiFooterText(false),
    );
    try std.testing.expectEqualStrings("✓", importReportMarker(.imported, false));
    try std.testing.expectEqualStrings("✓", importReportMarker(.updated, false));
    try std.testing.expectEqualStrings("✗", importReportMarker(.skipped, false));
}

test "Scenario: Given a live TUI write failure when mapping output errors then it becomes a handled TUI error" {
    try std.testing.expect(mapTuiOutputError(error.WriteFailed) == error.TuiOutputUnavailable);
    try std.testing.expect(mapTuiOutputError(error.EndOfStream) == error.EndOfStream);
}

test "Scenario: Given usage overrides when rendering remove list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, null, &checked, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "401") >= 2);
}

test "Scenario: Given usage overrides when rendering switch list with color then failed rows are highlighted red" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "Scenario: Given usage overrides when rendering remove list with color then failed rows are highlighted red" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, null, &checked, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "Scenario: Given a usage snapshot plan when building switch rows then the displayed plan prefers it over the stored auth plan" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .team,
    };

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    try std.testing.expectEqualStrings("Business", rows.items[0].plan);
}
