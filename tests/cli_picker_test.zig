const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const cli = codex_auth.cli;
const live_tui = cli.live_tui;
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
const renderRemoveScreen = cli.render.renderRemoveScreen;
const renderListScreenViewport = cli.render.renderListScreenViewport;
const renderSwitchScreenViewport = cli.render.renderSwitchScreenViewport;
const renderSwitchList = cli.render.renderSwitchList;
const renderRemoveList = cli.render.renderRemoveList;
const renderSwitchListViewport = cli.render.renderSwitchListViewport;
const renderRemoveListViewport = cli.render.renderRemoveListViewport;
const renderRemoveScreenViewport = cli.render.renderRemoveScreenViewport;
const liveViewportStartForDisplayIndex = cli.render.liveViewportStartForDisplayIndex;
const SwitchWidths = cli.render.SwitchWidths;
const buildSwitchRows = cli.rows.buildSwitchRows;
const buildSwitchRowsWithUsageOverrides = cli.rows.buildSwitchRowsWithUsageOverrides;
const SwitchRow = cli.rows.SwitchRow;
const switchTuiFooterText = cli.tui.switchTuiFooterText;
const removeTuiFooterText = cli.tui.removeTuiFooterText;
const listTuiFooterText = cli.tui.listTuiFooterText;
const writeTuiFrameTo = cli.tui.writeTuiFrameTo;
const TuiInputKey = cli.tui.TuiInputKey;
const importReportMarker = cli.output.importReportMarker;
const mapTuiOutputError = cli.tui.mapTuiOutputError;
const indexWidth = cli.render.indexWidth;
const LiveListViewport = cli.render.LiveListViewport;
const ansi = struct {
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
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

fn appendNumberedTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    idx: usize,
) !void {
    const record_key = try std.fmt.allocPrint(allocator, "user-{d:0>3}::acc-{d:0>3}", .{ idx, idx });
    defer allocator.free(record_key);
    const email = try std.fmt.allocPrint(allocator, "account-{d:0>3}@example.com", .{idx});
    defer allocator.free(email);
    try appendTestAccount(allocator, reg, record_key, email, "", .team);
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

fn testUsageSnapshotWithResets(now: i64, used_5h: f64, used_weekly: f64, reset_5h_seconds: i64, reset_weekly_seconds: i64) registry.RateLimitSnapshot {
    return .{
        .primary = .{
            .used_percent = used_5h,
            .window_minutes = 300,
            .resets_at = now + reset_5h_seconds,
        },
        .secondary = .{
            .used_percent = used_weekly,
            .window_minutes = 10080,
            .resets_at = now + reset_weekly_seconds,
        },
        .credits = null,
        .plan_type = .pro,
    };
}

fn testMutableString(comptime value: []const u8) []u8 {
    return @constCast(value);
}

fn testHeaderRow(comptime account: []const u8) SwitchRow {
    return .{
        .account_index = null,
        .account = testMutableString(account),
        .plan = "",
        .rate_5h = testMutableString(""),
        .rate_week = testMutableString(""),
        .last = testMutableString(""),
        .depth = 0,
        .is_active = false,
        .has_error = false,
        .is_header = true,
    };
}

fn testAccountRow(comptime account: []const u8, comptime plan: []const u8, is_active: bool) SwitchRow {
    return .{
        .account_index = 0,
        .account = testMutableString(account),
        .plan = plan,
        .rate_5h = testMutableString("-"),
        .rate_week = testMutableString("-"),
        .last = testMutableString("-"),
        .depth = 0,
        .is_active = is_active,
        .has_error = false,
        .is_header = false,
    };
}

test "Scenario: Given live switch table rows when rendering then table spacing and group rows stay stable" {
    var rows = [_]SwitchRow{
        .{
            .account_index = null,
            .account = testMutableString("group"),
            .plan = "",
            .rate_5h = testMutableString(""),
            .rate_week = testMutableString(""),
            .last = testMutableString(""),
            .depth = 0,
            .is_active = false,
            .has_error = false,
            .is_header = true,
        },
        .{
            .account_index = 0,
            .account = testMutableString("child"),
            .plan = "Team",
            .rate_5h = testMutableString("-"),
            .rate_week = testMutableString("-"),
            .last = testMutableString("-"),
            .depth = 1,
            .is_active = true,
            .has_error = false,
            .is_header = false,
        },
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchList(&writer, &reg, &rows, 2, .{
        .email = 7,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, null, false);

    try std.testing.expectEqualStrings(
        "     ACCOUNT  PLAN  5H  WEEKLY  LAST\n" ++
            "     group  \n" ++
            "* 01   child  Team  -   -       -   \n",
        writer.buffered(),
    );
}

test "Scenario: Given live remove table rows when rendering then checkbox spacing and group rows stay stable" {
    var rows = [_]SwitchRow{
        .{
            .account_index = null,
            .account = testMutableString("group"),
            .plan = "",
            .rate_5h = testMutableString(""),
            .rate_week = testMutableString(""),
            .last = testMutableString(""),
            .depth = 0,
            .is_active = false,
            .has_error = false,
            .is_header = true,
        },
        .{
            .account_index = 0,
            .account = testMutableString("child"),
            .plan = "Team",
            .rate_5h = testMutableString("-"),
            .rate_week = testMutableString("-"),
            .last = testMutableString("-"),
            .depth = 1,
            .is_active = true,
            .has_error = false,
            .is_header = false,
        },
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);
    const checked = [_]bool{true};

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderRemoveList(&writer, &reg, &rows, 2, .{
        .email = 7,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 0, &checked, false);

    try std.testing.expectEqualStrings(
        "         ACCOUNT  PLAN  5H  WEEKLY  LAST\n" ++
            "         group  \n" ++
            "> [x] 01   child  Team  -   -       -   \n",
        writer.buffered(),
    );
}

test "Scenario: Given a live switch viewport when rendering then long lists keep global numbering" {
    var rows = [_]SwitchRow{
        testHeaderRow("group"),
        testAccountRow("first", "Plus", false),
        testAccountRow("second", "Team", false),
        testAccountRow("third", "Free", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchListViewport(&writer, &reg, &rows, 2, .{
        .email = 7,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 1, false, .{ .start_row = 2, .max_rows = 1 });

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> 02 second") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "01 first") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "03 third") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "group") == null);
}

test "Scenario: Given long account labels when rendering live rows then account cells are truncated within the account column" {
    var rows = [_]SwitchRow{
        testHeaderRow("group-name-too-long"),
        .{
            .account_index = 0,
            .account = testMutableString("child-name-too-long"),
            .plan = "Team",
            .rate_5h = testMutableString("-"),
            .rate_week = testMutableString("-"),
            .last = testMutableString("-"),
            .depth = 2,
            .is_active = false,
            .has_error = false,
            .is_header = false,
        },
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchList(&writer, &reg, &rows, 2, .{
        .email = 8,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "     group-n.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  01     chi.  Team") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "group-name-too-long") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "child-name-too-long") == null);
}

test "Scenario: Given a narrow live viewport when rendering then the account column truncates instead of wrapping" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(
        gpa,
        &reg,
        "user-1::acc-1",
        "very-long-account-name-that-should-not-wrap@example.com",
        "",
        .team,
    );
    try appendTestAccount(
        gpa,
        &reg,
        "user-1::acc-2",
        "another-very-long-account-name-that-should-not-wrap@example.com",
        "",
        .team,
    );

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(accountRowCount(rows.items)));
    try renderListScreenViewport(&writer, &reg, rows.items, idx_width, rows.widths, false, "Live refresh: api refresh status line that should not wrap", .{
        .start_row = 0,
        .max_rows = 3,
        .max_cols = 40,
    });

    const output = writer.buffered();
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(line.len <= 40);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "very-long-account-name-that-should-not-wrap") == null);
}

test "Scenario: Given live screens when rendering then vertical spacing stays compact" {
    var rows = [_]SwitchRow{
        testAccountRow("account@example.com", "Team", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);
    const widths: SwitchWidths = .{
        .email = 19,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    };

    var switch_buffer: [2048]u8 = undefined;
    var switch_writer: std.Io.Writer = .fixed(&switch_buffer);
    try renderSwitchScreen(&switch_writer, &reg, &rows, 2, widths, 0, false, "Live refresh: ready", "Switched to account@example.com", "");
    const switch_output = switch_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, switch_output, "Select account to activate:\n"));
    try std.testing.expect(std.mem.indexOf(u8, switch_output, "\n\n") == null);

    var list_buffer: [2048]u8 = undefined;
    var list_writer: std.Io.Writer = .fixed(&list_buffer);
    try renderListScreenViewport(&list_writer, &reg, &rows, 2, widths, false, "Live refresh: ready", .{});
    const list_output = list_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, list_output, "     ACCOUNT"));
    try std.testing.expect(std.mem.indexOf(u8, list_output, "Live account list:") == null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "\n\n") == null);

    var remove_buffer: [2048]u8 = undefined;
    var remove_writer: std.Io.Writer = .fixed(&remove_buffer);
    const checked = [_]bool{false};
    try renderRemoveScreen(&remove_writer, &reg, &rows, 2, widths, 0, &checked, false, "Live refresh: ready", "Deleted account@example.com", "");
    const remove_output = remove_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, remove_output, "Select accounts to delete:\n"));
    try std.testing.expect(std.mem.indexOf(u8, remove_output, "\n\n") == null);

    try std.testing.expectEqual(@as(usize, 3), live_tui.switchFixedLines("", ""));
    try std.testing.expectEqual(@as(usize, 5), live_tui.switchFixedLines("status", "action"));
    try std.testing.expectEqual(@as(usize, 2), live_tui.listFixedLines(""));
    try std.testing.expectEqual(@as(usize, 3), live_tui.listFixedLines("status"));
}

test "Scenario: Given live remove number input when toggling a row then the prompt digits are cleared" {
    var rows = [_]SwitchRow{
        testAccountRow("first@example.com", "Plus", false),
        testAccountRow("second@example.com", "Team", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);
    const widths: SwitchWidths = .{
        .email = 18,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    };

    var before_checked = [_]bool{ false, false };
    var before_buffer: [2048]u8 = undefined;
    var before_writer: std.Io.Writer = .fixed(&before_buffer);
    try renderRemoveScreen(&before_writer, &reg, &rows, 2, widths, 1, &before_checked, false, "Live refresh: ready", "", "2");
    const before_output = before_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, before_output, "Select accounts to delete: 2\n"));
    try std.testing.expect(std.mem.indexOf(u8, before_output, "> [ ] 02 second@example.com") != null);

    var after_checked = [_]bool{ false, true };
    var after_buffer: [2048]u8 = undefined;
    var after_writer: std.Io.Writer = .fixed(&after_buffer);
    try renderRemoveScreen(&after_writer, &reg, &rows, 2, widths, 1, &after_checked, false, "Live refresh: ready", "", "");
    const after_output = after_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, after_output, "Select accounts to delete:\n"));
    try std.testing.expect(std.mem.indexOf(u8, after_output, "Select accounts to delete: 2\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_output, "> [x] 02 second@example.com") != null);
}

test "Scenario: Given long live switch and remove screens when rendering a full-height frame then prompts stay visible" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..40) |idx| try appendNumberedTestAccount(gpa, &reg, idx);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    const terminal_rows: usize = 12;
    const status_line = "Live refresh: api | Refresh in 25s";
    const idx_width = @max(@as(usize, 2), indexWidth(accountRowCount(rows.items)));
    var viewport_start: usize = 0;
    const viewport = live_tui.selectedViewport(
        terminal_rows,
        rows.items,
        0,
        live_tui.switchFixedLines(status_line, ""),
        &viewport_start,
    );
    const bounded_viewport: LiveListViewport = .{
        .start_row = viewport.start_row,
        .max_rows = viewport.max_rows,
        .max_cols = @as(?usize, 80),
    };

    var switch_frame: std.Io.Writer.Allocating = .init(gpa);
    defer switch_frame.deinit();
    try renderSwitchScreenViewport(
        &switch_frame.writer,
        &reg,
        rows.items,
        idx_width,
        rows.widths,
        0,
        true,
        status_line,
        "",
        "",
        bounded_viewport,
    );
    try std.testing.expect(std.mem.startsWith(u8, switch_frame.written(), "Select account to activate:\n"));
    try std.testing.expect(!std.mem.endsWith(u8, switch_frame.written(), "\n\x1b[0m"));

    var switch_screen: std.Io.Writer.Allocating = .init(gpa);
    defer switch_screen.deinit();
    const switch_line_count = try writeTuiFrameTo(&switch_screen.writer, switch_frame.written(), 0);
    try std.testing.expect(switch_line_count <= terminal_rows);

    const checked = try gpa.alloc(bool, rows.selectable_row_indices.len);
    defer gpa.free(checked);
    @memset(checked, false);

    var remove_frame: std.Io.Writer.Allocating = .init(gpa);
    defer remove_frame.deinit();
    try renderRemoveScreenViewport(
        &remove_frame.writer,
        &reg,
        rows.items,
        idx_width,
        rows.widths,
        0,
        checked,
        true,
        status_line,
        "",
        "",
        bounded_viewport,
    );
    try std.testing.expect(std.mem.startsWith(u8, remove_frame.written(), "Select accounts to delete:\n"));
    try std.testing.expect(!std.mem.endsWith(u8, remove_frame.written(), "\n\x1b[0m"));

    var remove_screen: std.Io.Writer.Allocating = .init(gpa);
    defer remove_screen.deinit();
    const remove_line_count = try writeTuiFrameTo(&remove_screen.writer, remove_frame.written(), 0);
    try std.testing.expect(remove_line_count <= terminal_rows);
}

test "Scenario: Given a live remove viewport when rendering then checked row numbering stays stable" {
    var rows = [_]SwitchRow{
        testAccountRow("first", "Plus", false),
        testAccountRow("second", "Team", false),
        testAccountRow("third", "Free", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);
    const checked = [_]bool{ false, true, false };

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderRemoveListViewport(&writer, &reg, &rows, 2, .{
        .email = 7,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 1, &checked, false, .{ .start_row = 1, .max_rows = 1 });

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "> [x] 02 second") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "01 first") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "03 third") == null);
}

test "Scenario: Given a cursor row below the live viewport then viewport start scrolls it into view" {
    var rows = [_]SwitchRow{
        testHeaderRow("group"),
        testAccountRow("first", "Plus", false),
        testAccountRow("second", "Team", false),
        testAccountRow("third", "Free", false),
        testAccountRow("fourth", "Plus", false),
    };

    try std.testing.expectEqual(
        @as(usize, 3),
        liveViewportStartForDisplayIndex(&rows, 3, 2, 0),
    );
}

test "Scenario: Given a long live list when scrolling down then viewport can reach the final rows" {
    var viewport_start: usize = 0;
    const row_count: usize = 105;
    const terminal_rows: usize = 66;
    const fixed_lines = live_tui.listFixedLines("Live refresh: local | Refresh in 9s");
    const max_rows = live_tui.maxTableRows(terminal_rows, fixed_lines);

    try std.testing.expectEqual(@as(usize, 63), max_rows);

    for (0..200) |_| {
        live_tui.scrollListViewport(row_count, max_rows, &viewport_start, .down);
    }

    try std.testing.expectEqual(@as(usize, 42), viewport_start);
    const viewport = live_tui.listViewport(terminal_rows, row_count, fixed_lines, &viewport_start);
    try std.testing.expectEqual(@as(usize, 42), viewport.start_row);
    try std.testing.expectEqual(@as(usize, 63), viewport.max_rows.?);
}

test "Scenario: Given a long live list when paging or jumping then viewport clamps to valid bounds" {
    var viewport_start: usize = 0;
    const row_count: usize = 105;
    const max_rows: usize = 60;

    live_tui.scrollListViewportBy(row_count, max_rows, &viewport_start, .down, max_rows);
    try std.testing.expectEqual(@as(usize, 45), viewport_start);

    live_tui.scrollListViewportBy(row_count, max_rows, &viewport_start, .up, max_rows);
    try std.testing.expectEqual(@as(usize, 0), viewport_start);

    viewport_start = cli.render.clampLiveViewportStart(row_count, max_rows, row_count);
    try std.testing.expectEqual(@as(usize, 45), viewport_start);
}

test "Scenario: Given queued live list scroll keys before rendering then viewport offset saturates and clamps" {
    var viewport_start: usize = std.math.maxInt(usize) - 1;

    live_tui.scrollListViewportBy(105, 60, &viewport_start, .down, 10);

    try std.testing.expectEqual(@as(usize, 45), viewport_start);
}

test "Scenario: Given live auto switch state when starting then the initial display triggers auto-switch once" {
    var enabled = live_tui.LiveAutoSwitchState.init(true);
    try std.testing.expect(enabled.takePending());
    try std.testing.expect(!enabled.takePending());

    enabled.noteRefreshedDisplay();
    try std.testing.expect(enabled.takePending());
    try std.testing.expect(!enabled.takePending());

    enabled.noteRefreshedDisplay();
    enabled.noteActionDisplay();
    try std.testing.expect(!enabled.takePending());

    var disabled = live_tui.LiveAutoSwitchState.init(false);
    disabled.noteRefreshedDisplay();
    try std.testing.expect(!disabled.takePending());
}

test "Scenario: Given a long selectable live list when paging then selection can reach the first and final accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..106) |idx| try appendNumberedTestAccount(gpa, &reg, idx);
    reg.active_account_key = try gpa.dupe(u8, "user-050::acc-050");

    var rows = try live_tui.buildSelectableRows(gpa, .{
        .reg = &reg,
        .usage_overrides = null,
    });
    defer rows.deinit(gpa);

    var selected_key: ?[]u8 = try gpa.dupe(u8, "user-050::acc-050");
    defer if (selected_key) |key| gpa.free(key);

    try std.testing.expect(try live_tui.moveSelectedIndexBy(gpa, &selected_key, &rows, &reg, .up, 60));
    try std.testing.expectEqualStrings("user-001::acc-001", selected_key.?);

    try std.testing.expect(try live_tui.moveSelectedIndexBy(gpa, &selected_key, &rows, &reg, .down, 60));
    try std.testing.expectEqualStrings("user-061::acc-061", selected_key.?);

    try std.testing.expect(try live_tui.moveSelectedIndexToEdge(gpa, &selected_key, &rows, &reg, .down));
    try std.testing.expectEqualStrings("user-105::acc-105", selected_key.?);

    var viewport_start: usize = 0;
    const last_selectable_idx = selectableIndexForAccountKey(&rows, &reg, "user-105::acc-105") orelse return error.TestExpectedEqual;
    const last_display_idx = displayedIndexForSelectable(&rows, last_selectable_idx) orelse return error.TestExpectedEqual;
    const viewport = live_tui.selectedViewport(
        66,
        rows.items,
        last_display_idx,
        live_tui.switchFixedLines("Live refresh: local | Refresh in 9s", ""),
        &viewport_start,
    );

    try std.testing.expectEqual(@as(usize, 43), viewport.start_row);
    try std.testing.expectEqual(@as(usize, 62), viewport.max_rows.?);
}

test "Scenario: Given unselectable rows at live switch edges when viewport scrolling then first and final accounts are reachable" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..139) |idx| try appendNumberedTestAccount(gpa, &reg, idx);

    const usage_overrides = try gpa.alloc(?[]const u8, reg.accounts.items.len);
    defer gpa.free(usage_overrides);
    for (usage_overrides, 0..) |*override, idx| {
        override.* = if (idx < 20 or idx >= 99) "0%" else null;
    }

    var rows = try live_tui.buildSelectableRows(gpa, .{
        .reg = &reg,
        .usage_overrides = usage_overrides,
    });
    defer rows.deinit(gpa);

    const max_rows: usize = 60;
    const first_selectable_idx = selectableIndexForAccountKey(&rows, &reg, "user-021::acc-021") orelse return error.TestExpectedEqual;
    const first_display_idx = displayedIndexForSelectable(&rows, first_selectable_idx) orelse return error.TestExpectedEqual;
    var top_start: usize = 20;
    for (0..10) |_| {
        live_tui.scrollListViewportBy(rows.items.len, max_rows, &top_start, .up, 6);
    }
    try std.testing.expectEqual(@as(usize, 0), top_start);

    var top: std.Io.Writer.Allocating = .init(gpa);
    defer top.deinit();
    try renderSwitchListViewport(&top.writer, &reg, rows.items, 3, rows.widths, first_display_idx, false, .{
        .start_row = top_start,
        .max_rows = max_rows,
    });
    try std.testing.expect(std.mem.indexOf(u8, top.written(), "001 account-001@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, top.written(), "021 account-021@example.com") != null);

    const last_selectable_idx = selectableIndexForAccountKey(&rows, &reg, "user-099::acc-099") orelse return error.TestExpectedEqual;
    const last_display_idx = displayedIndexForSelectable(&rows, last_selectable_idx) orelse return error.TestExpectedEqual;
    var bottom_start: usize = 40;
    for (0..20) |_| {
        live_tui.scrollListViewportBy(rows.items.len, max_rows, &bottom_start, .down, 6);
    }
    try std.testing.expectEqual(@as(usize, 78), bottom_start);

    var bottom: std.Io.Writer.Allocating = .init(gpa);
    defer bottom.deinit();
    try renderSwitchListViewport(&bottom.writer, &reg, rows.items, 3, rows.widths, last_display_idx, false, .{
        .start_row = bottom_start,
        .max_rows = max_rows,
    });
    try std.testing.expect(std.mem.indexOf(u8, bottom.written(), "099 account-099@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom.written(), "138 account-138@example.com") != null);
}

test "Scenario: Given switch selection is at first selectable row when scrolling up then unavailable rows above remain reachable" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..40) |idx| try appendNumberedTestAccount(gpa, &reg, idx);

    const usage_overrides = try gpa.alloc(?[]const u8, reg.accounts.items.len);
    defer gpa.free(usage_overrides);
    for (usage_overrides, 0..) |*override, idx| {
        override.* = if (idx < 10) "0%" else null;
    }

    var rows = try live_tui.buildSelectableRows(gpa, .{
        .reg = &reg,
        .usage_overrides = usage_overrides,
    });
    defer rows.deinit(gpa);

    var selected_key: ?[]u8 = try gpa.dupe(u8, "user-011::acc-011");
    defer if (selected_key) |key| gpa.free(key);

    const max_rows: usize = 20;
    const wheel_rows = live_tui.mouseWheelRows(max_rows);
    var viewport_start: usize = 10;
    const moved = try live_tui.moveSelectedIndex(gpa, &selected_key, &rows, &reg, .up);
    try std.testing.expect(!moved);
    live_tui.scrollListViewportBy(rows.items.len, max_rows, &viewport_start, .up, wheel_rows);
    try std.testing.expectEqual(@as(usize, 4), viewport_start);

    const first_selectable_idx = selectableIndexForAccountKey(&rows, &reg, "user-011::acc-011") orelse return error.TestExpectedEqual;
    const first_display_idx = displayedIndexForSelectable(&rows, first_selectable_idx) orelse return error.TestExpectedEqual;
    const viewport = live_tui.selectableViewport(24, rows.items, first_display_idx, 4, &viewport_start, false);
    try std.testing.expectEqual(@as(usize, 4), viewport.start_row);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderSwitchListViewport(&out.writer, &reg, rows.items, 2, rows.widths, first_display_idx, false, viewport);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "05 account-005@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "> 11 account-011@example.com") != null);
}

test "Scenario: Given switch selection is at final selectable row when scrolling down then unavailable rows below remain reachable" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..40) |idx| try appendNumberedTestAccount(gpa, &reg, idx);

    const usage_overrides = try gpa.alloc(?[]const u8, reg.accounts.items.len);
    defer gpa.free(usage_overrides);
    for (usage_overrides, 0..) |*override, idx| {
        override.* = if (idx >= 30) "0%" else null;
    }

    var rows = try live_tui.buildSelectableRows(gpa, .{
        .reg = &reg,
        .usage_overrides = usage_overrides,
    });
    defer rows.deinit(gpa);

    var selected_key: ?[]u8 = try gpa.dupe(u8, "user-030::acc-030");
    defer if (selected_key) |key| gpa.free(key);

    const max_rows: usize = 20;
    const wheel_rows = live_tui.mouseWheelRows(max_rows);
    var viewport_start: usize = 10;
    const moved = try live_tui.moveSelectedIndex(gpa, &selected_key, &rows, &reg, .down);
    try std.testing.expect(!moved);
    live_tui.scrollListViewportBy(rows.items.len, max_rows, &viewport_start, .down, wheel_rows);
    try std.testing.expectEqual(@as(usize, 16), viewport_start);

    const final_selectable_idx = selectableIndexForAccountKey(&rows, &reg, "user-030::acc-030") orelse return error.TestExpectedEqual;
    const final_display_idx = displayedIndexForSelectable(&rows, final_selectable_idx) orelse return error.TestExpectedEqual;
    const viewport = live_tui.selectableViewport(24, rows.items, final_display_idx, 4, &viewport_start, false);
    try std.testing.expectEqual(@as(usize, 16), viewport.start_row);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderSwitchListViewport(&out.writer, &reg, rows.items, 2, rows.widths, final_display_idx, false, viewport);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "> 30 account-030@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "36 account-036@example.com") != null);
}

test "Scenario: Given a long live table when rendering viewport bounds then both ends are reachable" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    for (1..106) |idx| try appendNumberedTestAccount(gpa, &reg, idx);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    const idx_width = @max(@as(usize, 2), indexWidth(accountRowCount(rows.items)));
    const max_rows: usize = 60;

    var top: std.Io.Writer.Allocating = .init(gpa);
    defer top.deinit();
    try renderSwitchListViewport(&top.writer, &reg, rows.items, idx_width, rows.widths, null, false, .{
        .start_row = 0,
        .max_rows = max_rows,
    });
    try std.testing.expect(std.mem.indexOf(u8, top.written(), "001 account-001@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, top.written(), "105 account-105@example.com") == null);

    const bottom_start = cli.render.clampLiveViewportStart(rows.items.len, max_rows, rows.items.len);
    try std.testing.expectEqual(@as(usize, 45), bottom_start);

    var bottom: std.Io.Writer.Allocating = .init(gpa);
    defer bottom.deinit();
    try renderSwitchListViewport(&bottom.writer, &reg, rows.items, idx_width, rows.widths, null, false, .{
        .start_row = bottom_start,
        .max_rows = max_rows,
    });
    try std.testing.expect(std.mem.indexOf(u8, bottom.written(), "001 account-001@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, bottom.written(), "105 account-105@example.com") != null);
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

test "Scenario: Given live switch navigation shortcuts when an account is unavailable then arrow and j/k keys skip it" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy-a@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "healthy-b@example.com", "", .team);

    const usage_overrides = [_]?[]const u8{ null, "401", null };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);
    try filterErroredRowsFromSelectableIndices(gpa, &rows);

    var selected_account_key: ?[]u8 = try gpa.dupe(u8, "user-1::acc-1");
    defer if (selected_account_key) |key| gpa.free(key);

    try std.testing.expect(try live_tui.moveSelectedIndexForKey(gpa, &selected_account_key, &rows, &reg, TuiInputKey.move_down));
    try std.testing.expectEqualStrings("user-1::acc-3", selected_account_key.?);

    try std.testing.expect(try live_tui.moveSelectedIndexForKey(gpa, &selected_account_key, &rows, &reg, TuiInputKey.move_up));
    try std.testing.expectEqualStrings("user-1::acc-1", selected_account_key.?);

    try std.testing.expect(try live_tui.moveSelectedIndexForKey(gpa, &selected_account_key, &rows, &reg, .{ .byte = 'j' }));
    try std.testing.expectEqualStrings("user-1::acc-3", selected_account_key.?);

    try std.testing.expect(try live_tui.moveSelectedIndexForKey(gpa, &selected_account_key, &rows, &reg, .{ .byte = 'k' }));
    try std.testing.expectEqualStrings("user-1::acc-1", selected_account_key.?);
}

test "Scenario: Given active usage at threshold when picking a live auto-switch target then nearest 5h reset wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup-a@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "backup-b@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshotWithResets(now, 99, 10, 3600, 7 * 24 * 3600);
    reg.accounts.items[1].last_usage = testUsageSnapshotWithResets(now, 5, 5, 30 * 60, 60 * 60);
    reg.accounts.items[2].last_usage = testUsageSnapshotWithResets(now, 50, 50, 5 * 60 + 1, 2 * 60 * 60);

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

test "Scenario: Given equal 5h resets when picking a live auto-switch target then nearest weekly reset wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "backup-a@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "backup-b@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshotWithResets(now, 99, 10, 3600, 7 * 24 * 3600);
    reg.accounts.items[1].last_usage = testUsageSnapshotWithResets(now, 10, 10, 30 * 60, 6 * 60 * 60);
    reg.accounts.items[2].last_usage = testUsageSnapshotWithResets(now, 90, 90, 30 * 60, 30 * 60);

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

test "Scenario: Given an active account when rendering switch list then non-cursor active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "cursor@example.com", "", .team);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .team);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    var cursor_displayed_idx: ?usize = null;
    for (rows.selectable_row_indices, 0..) |row_idx, selectable_idx| {
        const account_idx = rows.items[row_idx].account_index.?;
        if (std.mem.eql(u8, reg.accounts.items[account_idx].account_key, "user-1::acc-1")) {
            cursor_displayed_idx = displayedIndexForSelectable(&rows, selectable_idx);
            break;
        }
    }

    try std.testing.expect(cursor_displayed_idx != null);
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, cursor_displayed_idx.?, false);

    const output = writer.buffered();
    var expected_cursor_line_buf: [128]u8 = undefined;
    const expected_cursor_line = try std.fmt.bufPrint(
        &expected_cursor_line_buf,
        "> {d:0>2} cursor@example.com",
        .{cursor_displayed_idx.? + 1},
    );
    try std.testing.expect(std.mem.indexOf(u8, output, expected_cursor_line) != null);

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

test "Scenario: Given switch list color output when rendering then header cursor active and primary rows use distinct styles" {
    var rows = [_]SwitchRow{
        testAccountRow("cursor@example.com", "Team", false),
        testAccountRow("active@example.com", "Team", true),
        testAccountRow("normal@example.com", "Free", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderSwitchList(&writer, &reg, &rows, 2, .{
        .email = 20,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 0, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.cyan ++ "     ACCOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "> 01 cursor@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "* 02 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  03 normal@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m  03 normal@example.com") == null);
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

test "Scenario: Given remove list color output when rendering then cursor checked active and primary rows use distinct styles" {
    var rows = [_]SwitchRow{
        testAccountRow("cursor@example.com", "Team", false),
        testAccountRow("checked@example.com", "Plus", false),
        testAccountRow("active@example.com", "Free", true),
        testAccountRow("normal@example.com", "Free", false),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);
    const checked = [_]bool{ false, true, false, false };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderRemoveList(&writer, &reg, &rows, 2, .{
        .email = 20,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 0, &checked, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.cyan ++ "         ACCOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "> [ ] 01 cursor@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "  [x] 02 checked@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "* [ ] 03 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "  [ ] 04 normal@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m  [ ] 04 normal@example.com") == null);
}

test "Scenario: Given overlapping row states when rendering live lists then color priority is stable" {
    var switch_rows = [_]SwitchRow{
        testAccountRow("cursor-error@example.com", "Team", false),
        testAccountRow("active-error@example.com", "Team", true),
    };
    switch_rows[0].has_error = true;
    switch_rows[1].has_error = true;
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var switch_buffer: [2048]u8 = undefined;
    var switch_writer: std.Io.Writer = .fixed(&switch_buffer);
    try renderSwitchList(&switch_writer, &reg, &switch_rows, 2, .{
        .email = 28,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 0, true);
    const switch_output = switch_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, switch_output, ansi.green ++ "> 01 cursor-error@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_output, ansi.green ++ "* 02 active-error@example.com") != null);

    var remove_rows = [_]SwitchRow{
        testAccountRow("cursor-error@example.com", "Team", false),
        testAccountRow("checked@example.com", "Team", false),
        testAccountRow("active-error@example.com", "Team", true),
    };
    remove_rows[0].has_error = true;
    remove_rows[2].has_error = true;
    const checked = [_]bool{ false, true, true };

    var remove_buffer: [2048]u8 = undefined;
    var remove_writer: std.Io.Writer = .fixed(&remove_buffer);
    try renderRemoveList(&remove_writer, &reg, &remove_rows, 2, .{
        .email = 26,
        .plan = 4,
        .rate_5h = 2,
        .rate_week = 6,
        .last = 4,
    }, 0, &checked, true);
    const remove_output = remove_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, remove_output, ansi.green ++ "> [ ] 01 cursor-error@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, remove_output, ansi.green ++ "  [x] 02 checked@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, remove_output, ansi.green ++ "* [x] 03 active-error@example.com") != null);
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

test "Scenario: Given switch live feedback with color when rendering switch screen then success and failure actions use action colors" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var success_buffer: [2048]u8 = undefined;
    var success_writer: std.Io.Writer = .fixed(&success_buffer);
    try renderSwitchScreen(
        &success_writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        true,
        "",
        "Switched to healthy@example.com",
        "",
    );
    try std.testing.expect(std.mem.indexOf(u8, success_writer.buffered(), ansi.green ++ "Switched to healthy@example.com") != null);

    var failure_buffer: [2048]u8 = undefined;
    var failure_writer: std.Io.Writer = .fixed(&failure_buffer);
    try renderSwitchScreen(
        &failure_writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        true,
        "",
        "Switch failed: denied",
        "",
    );
    try std.testing.expect(std.mem.indexOf(u8, failure_writer.buffered(), ansi.red ++ "Switch failed: denied") != null);
}

test "Scenario: Given live screen status and footers with color when rendering then status and footer styles match command rules" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .team);
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var switch_buffer: [2048]u8 = undefined;
    var switch_writer: std.Io.Writer = .fixed(&switch_buffer);
    try renderSwitchScreen(
        &switch_writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        true,
        "Live refresh: api | Refresh in 25s",
        "",
        "",
    );
    const switch_output = switch_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, switch_output, ansi.cyan ++ "Live refresh: api | Refresh in 25s") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_output, ansi.cyan ++ "Keys:") != null);

    var remove_buffer: [2048]u8 = undefined;
    var remove_writer: std.Io.Writer = .fixed(&remove_buffer);
    var checked = [_]bool{false};
    try renderRemoveScreen(
        &remove_writer,
        &reg,
        rows.items,
        @max(@as(usize, 2), indexWidth(accountRowCount(rows.items))),
        rows.widths,
        0,
        &checked,
        true,
        "Live refresh: api | Refresh in 25s",
        "",
        "",
    );
    const remove_output = remove_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, remove_output, ansi.cyan ++ "Live refresh: api | Refresh in 25s") != null);
    try std.testing.expect(std.mem.indexOf(u8, remove_output, ansi.cyan ++ "Keys:") != null);
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
    try std.testing.expectEqualStrings(
        "Keys: Up/Down scroll, PgUp/PgDn page, Home/End jump, Esc or q quit\n",
        listTuiFooterText(true),
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
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ scroll, PgUp/PgDn page, Home/End jump, Esc or q quit\n",
        listTuiFooterText(false),
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
