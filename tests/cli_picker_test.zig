const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const cli = codex_auth.cli;
const live_tui = cli.live_tui;
const registry = codex_auth.registry;
const text_width = codex_auth.tui.text_width;
const isQuitInput = cli.picker.isQuitInput;
const isQuitKey = cli.picker.isQuitKey;
const activeSelectableIndex = cli.picker.activeSelectableIndex;
const maybeAutoSwitchTargetKeyAlloc = cli.picker.maybeAutoSwitchTargetKeyAlloc;
const accountRowCount = cli.picker.accountRowCount;
const displayedIndexForSelectable = cli.picker.displayedIndexForSelectable;
const selectableIndexForAccountKey = cli.picker.selectableIndexForAccountKey;
const accountIdForSelectable = cli.picker.accountIdForSelectable;
const filterErroredRowsFromSelectableIndices = cli.rows.filterErroredRowsFromSelectableIndices;
const renderSwitchScreen = cli.render.renderSwitchScreen;
const renderRemoveScreen = cli.render.renderRemoveScreen;
const liveViewportStartForDisplayIndex = cli.render.liveViewportStartForDisplayIndex;
const SwitchWidths = cli.render.SwitchWidths;
const StyledWriter = cli.render.StyledWriter;
const buildSwitchRows = cli.rows.buildSwitchRows;
const buildSwitchRowsWithUsageOverrides = cli.rows.buildSwitchRowsWithUsageOverrides;
const SwitchRow = cli.rows.SwitchRow;
const switchTuiFooterText = cli.tui.switchTuiFooterText;
const removeTuiFooterText = cli.tui.removeTuiFooterText;
const listTuiFooterText = cli.tui.listTuiFooterText;
const listCreditsTuiFooterText = cli.tui.listCreditsTuiFooterText;
const writeTuiFrameTo = cli.tui.writeTuiFrameTo;
const TuiInputKey = cli.tui.TuiInputKey;
const mapTuiOutputError = cli.tui.mapTuiOutputError;
const indexWidth = cli.render.indexWidth;
const LiveListViewport = cli.render.LiveListViewport;
const ansi = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

fn renderListScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    use_color: bool,
    status_line: []const u8,
    viewport: LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderListScreenViewport(&styled, reg, rows, idx_width, widths, status_line, viewport);
}

fn renderSwitchScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    selected: ?usize,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderSwitchScreenViewport(&styled, reg, rows, idx_width, widths, selected, status_line, action_line, number_input, viewport);
}

fn renderRemoveScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    status_line: []const u8,
    action_line: []const u8,
    number_input: []const u8,
    viewport: LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderRemoveScreenViewport(&styled, reg, rows, idx_width, widths, cursor, checked, status_line, action_line, number_input, viewport);
}

fn renderSwitchList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    use_color: bool,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderSwitchList(&styled, reg, rows, idx_width, widths, cursor);
}

fn renderSwitchListViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    use_color: bool,
    viewport: LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderSwitchListViewport(&styled, reg, rows, idx_width, widths, cursor, viewport);
}

fn renderRemoveList(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderRemoveList(&styled, reg, rows, idx_width, widths, cursor, checked);
}

fn renderRemoveListViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: SwitchWidths,
    cursor: ?usize,
    checked: []const bool,
    use_color: bool,
    viewport: LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderRemoveListViewport(&styled, reg, rows, idx_width, widths, cursor, checked, viewport);
}

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
    const sep = std.mem.findLast(u8, record_key, "::") orelse return error.InvalidRecordKey;
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
    const record_key = try allocator.print("user-{d:0>3}::acc-{d:0>3}", .{ idx, idx });
    defer allocator.free(record_key);
    const email = try allocator.print("account-{d:0>3}@example.com", .{idx});
    defer allocator.free(email);
    try appendTestAccount(allocator, reg, record_key, email, "", .business);
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
            "     group\n" ++
            "*  1   child  Team  -   -       -\n",
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
            "         group\n" ++
            "> [x]  1   child  Team  -   -       -\n",
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
    try std.testing.expect(std.mem.find(u8, output, ">  2 second") != null);
    try std.testing.expect(std.mem.find(u8, output, "01 first") == null);
    try std.testing.expect(std.mem.find(u8, output, "03 third") == null);
    try std.testing.expect(std.mem.find(u8, output, "group") == null);
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
    try std.testing.expect(std.mem.find(u8, output, "     group-name-too-long\n") != null);
    try std.testing.expect(std.mem.find(u8, output, "   1     chi.  Team") != null);
    try std.testing.expect(std.mem.find(u8, output, "group-name-too-long") != null);
    try std.testing.expect(std.mem.find(u8, output, "child-name-too-long") == null);
}

test "Scenario: Given a Cyrillic account label when rendering live rows then truncation preserves UTF-8" {
    var rows = [_]SwitchRow{
        testHeaderRow("gorod.ged"),
        .{
            .account_index = 0,
            .account = testMutableString("Рабочая область"),
            .plan = "Business",
            .rate_5h = testMutableString("99%"),
            .rate_week = testMutableString("100%"),
            .last = testMutableString("Now"),
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
        .email = 6,
        .plan = 8,
        .rate_5h = 3,
        .rate_week = 4,
        .last = 3,
    }, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try std.testing.expect(std.mem.find(u8, output, "Раб.") != null);
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
        .business,
    );
    try appendTestAccount(
        gpa,
        &reg,
        "user-1::acc-2",
        "another-very-long-account-name-that-should-not-wrap@example.com",
        "",
        .business,
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
    try std.testing.expect(std.mem.find(u8, output, "very-long-account-name-that-should-not-wrap") == null);
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
    try std.testing.expect(std.mem.find(u8, switch_output, "\n\n") == null);

    var list_buffer: [2048]u8 = undefined;
    var list_writer: std.Io.Writer = .fixed(&list_buffer);
    try renderListScreenViewport(&list_writer, &reg, &rows, 2, widths, false, "Live refresh: ready", .{});
    const list_output = list_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, list_output, "     ACCOUNT"));
    try std.testing.expect(std.mem.find(u8, list_output, "Live account list:") == null);
    try std.testing.expect(std.mem.find(u8, list_output, "\n\n") == null);

    var remove_buffer: [2048]u8 = undefined;
    var remove_writer: std.Io.Writer = .fixed(&remove_buffer);
    const checked = [_]bool{false};
    try renderRemoveScreen(&remove_writer, &reg, &rows, 2, widths, 0, &checked, false, "Live refresh: ready", "Deleted account@example.com", "");
    const remove_output = remove_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, remove_output, "Select accounts to delete:\n"));
    try std.testing.expect(std.mem.find(u8, remove_output, "\n\n") == null);

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
    try std.testing.expect(std.mem.find(u8, before_output, "> [ ]  2 second@example.com") != null);

    var after_checked = [_]bool{ false, true };
    var after_buffer: [2048]u8 = undefined;
    var after_writer: std.Io.Writer = .fixed(&after_buffer);
    try renderRemoveScreen(&after_writer, &reg, &rows, 2, widths, 1, &after_checked, false, "Live refresh: ready", "", "");
    const after_output = after_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, after_output, "Select accounts to delete:\n"));
    try std.testing.expect(std.mem.find(u8, after_output, "Select accounts to delete: 2\n") == null);
    try std.testing.expect(std.mem.find(u8, after_output, "> [x]  2 second@example.com") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "> [x]  2 second") != null);
    try std.testing.expect(std.mem.find(u8, output, "01 first") == null);
    try std.testing.expect(std.mem.find(u8, output, "03 third") == null);
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
    try std.testing.expect(std.mem.find(u8, top.written(), "  1 account-001@example.com") != null);
    try std.testing.expect(std.mem.find(u8, top.written(), " 21 account-021@example.com") != null);

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
    try std.testing.expect(std.mem.find(u8, bottom.written(), " 99 account-099@example.com") != null);
    try std.testing.expect(std.mem.find(u8, bottom.written(), "138 account-138@example.com") != null);
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
    try std.testing.expect(std.mem.find(u8, out.written(), " 5 account-005@example.com") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "> 11 account-011@example.com") != null);
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
    try std.testing.expect(std.mem.find(u8, out.written(), "> 30 account-030@example.com") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "36 account-036@example.com") != null);
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
    try std.testing.expect(std.mem.find(u8, top.written(), "  1 account-001@example.com") != null);
    try std.testing.expect(std.mem.find(u8, top.written(), "105 account-105@example.com") == null);

    const bottom_start = cli.render.clampLiveViewportStart(rows.items.len, max_rows, rows.items.len);
    try std.testing.expectEqual(@as(usize, 45), bottom_start);

    var bottom: std.Io.Writer.Allocating = .init(gpa);
    defer bottom.deinit();
    try renderSwitchListViewport(&bottom.writer, &reg, rows.items, idx_width, rows.widths, null, false, .{
        .start_row = bottom_start,
        .max_rows = max_rows,
    });
    try std.testing.expect(std.mem.find(u8, bottom.written(), "  1 account-001@example.com") == null);
    try std.testing.expect(std.mem.find(u8, bottom.written(), "105 account-105@example.com") != null);
}

test "Scenario: Given grouped accounts when rendering switch list then child rows keep indentation" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.find(u8, output, " 1   Als's Workspace") != null);
    try std.testing.expect(std.mem.find(u8, output, " 2   Free") != null);
}

test "Scenario: Given usage overrides when rendering switch list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
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

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .business);
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

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy-a@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "healthy-b@example.com", "", .business);

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

test "Scenario: Given live auto switch state when starting then the initial display triggers auto-switch once" {
    var enabled = live_tui.LiveAutoSwitchState.init(true);
    try std.testing.expect(enabled.takePending());
    try std.testing.expect(!enabled.takePending());
    enabled.noteRefreshedDisplay();
    try std.testing.expect(enabled.takePending());
    enabled.noteActionDisplay();
    try std.testing.expect(!enabled.takePending());

    var disabled = live_tui.LiveAutoSwitchState.init(false);
    try std.testing.expect(!disabled.takePending());
    disabled.noteRefreshedDisplay();
    try std.testing.expect(!disabled.takePending());
}

test "Scenario: Given active usage at zero when picking a live auto-switch target then healthy candidate wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "exhausted@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "healthy@example.com", "", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshotWithResets(now, 100, 20, 3600, 7 * 24 * 3600);
    reg.accounts.items[1].last_usage = testUsageSnapshotWithResets(now, 100, 10, 30 * 60, 6 * 60 * 60);
    reg.accounts.items[2].last_usage = testUsageSnapshotWithResets(now, 50, 50, 30 * 60, 30 * 60);

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

test "Scenario: Given active usage above zero when picking a live auto-switch target then no target is chosen" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "healthy@example.com", "", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");
    reg.accounts.items[0].last_usage = testUsageSnapshotWithResets(now, 99, 20, 3600, 7 * 24 * 3600);
    reg.accounts.items[1].last_usage = testUsageSnapshotWithResets(now, 50, 50, 30 * 60, 30 * 60);

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

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "failed@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.find(u8, output, " 1 ") != null);
    try std.testing.expect(std.mem.find(u8, output, " 2 ") != null);
    try std.testing.expect(std.mem.find(u8, output, "healthy@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "failed@example.com") != null);
}

test "Scenario: Given an active account when rendering switch list then non-cursor active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "cursor@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .business);
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
    const expected_cursor_line = try std.mem.print(
        &expected_cursor_line_buf,
        "> {d:>2} cursor@example.com",
        .{cursor_displayed_idx.? + 1},
    );
    try std.testing.expect(std.mem.find(u8, output, expected_cursor_line) != null);

    const active_displayed_idx = displayedIndexForSelectable(&rows, activeSelectableIndex(&rows).?).?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.mem.print(
        &expected_active_line_buf,
        "* {d:>2} active@example.com",
        .{active_displayed_idx + 1},
    );
    try std.testing.expect(std.mem.find(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.find(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is selected when rendering switch list then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, 0, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.find(u8, output, ">  1 active@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "*  1 active@example.com") == null);
    try std.testing.expect(std.mem.find(u8, output, "[ACTIVE]") == null);
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
    try std.testing.expect(std.mem.find(u8, output, ansi.cyan ++ "     ACCOUNT") != null);
    try std.testing.expect(std.mem.find(u8, output, ansi.green ++ ">  1 cursor@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, ansi.green ++ "*  2 active@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "   3 normal@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "\x1b[2m   3 normal@example.com") == null);
}

test "Scenario: Given an active account when rendering remove list then non-cursor active rows use the list marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "cursor@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "active@example.com", "", .business);
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
    const expected_cursor_line = try std.mem.print(
        &expected_cursor_line_buf,
        "> [ ] {d:>2} cursor@example.com",
        .{cursor_idx + 1},
    );
    try std.testing.expect(std.mem.find(u8, output, expected_cursor_line) != null);

    const active_idx = selectableIndexForAccountKey(&rows, &reg, "user-1::acc-2").?;
    var expected_active_line_buf: [128]u8 = undefined;
    const expected_active_line = try std.mem.print(
        &expected_active_line_buf,
        "* [ ] {d:>2} active@example.com",
        .{active_idx + 1},
    );
    try std.testing.expect(std.mem.find(u8, output, expected_active_line) != null);
    try std.testing.expect(std.mem.find(u8, output, "[ACTIVE]") == null);
}

test "Scenario: Given the active account is the remove cursor then the cursor marker wins" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "other@example.com", "", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var checked = [_]bool{ false, false };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderRemoveList(&writer, &reg, rows.items, idx_width, rows.widths, 0, &checked, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.find(u8, output, "> [ ]  1 active@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "* [ ]  1 active@example.com") == null);
    try std.testing.expect(std.mem.find(u8, output, "[ACTIVE]") == null);
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
    try std.testing.expect(std.mem.find(u8, output, ansi.cyan ++ "         ACCOUNT") != null);
    try std.testing.expect(std.mem.find(u8, output, ansi.green ++ "> [ ]  1 cursor@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, ansi.green ++ "  [x]  2 checked@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, ansi.green ++ "* [ ]  3 active@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "  [ ]  4 normal@example.com") != null);
    try std.testing.expect(std.mem.find(u8, output, "\x1b[2m  [ ]  4 normal@example.com") == null);
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
    // An errored row keeps red even under the cursor/active marker: the glyph
    // already shows focus and the alarm must not be hidden.
    try std.testing.expect(std.mem.find(u8, switch_output, ansi.red ++ ">  1 cursor-error@example.com") != null);
    try std.testing.expect(std.mem.find(u8, switch_output, ansi.red ++ "*  2 active-error@example.com") != null);

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
    try std.testing.expect(std.mem.find(u8, remove_output, ansi.red ++ "> [ ]  1 cursor-error@example.com") != null);
    try std.testing.expect(std.mem.find(u8, remove_output, ansi.green ++ "  [x]  2 checked@example.com") != null);
    try std.testing.expect(std.mem.find(u8, remove_output, ansi.red ++ "* [x]  3 active-error@example.com") != null);
}

test "Scenario: Given switch live feedback when rendering switch screen then the action message stays below the footer" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .business);
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
    const footer_pos = std.mem.find(u8, output, "Keys:") orelse return error.TestExpectedEqual;
    const action_pos = std.mem.find(u8, output, "Switched to healthy@example.com") orelse return error.TestExpectedEqual;
    try std.testing.expect(action_pos > footer_pos);
}

test "Scenario: Given switch live feedback with color when rendering switch screen then success and failure actions use action colors" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .business);
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
    try std.testing.expect(std.mem.find(u8, success_writer.buffered(), ansi.green ++ "Switched to healthy@example.com") != null);

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
    try std.testing.expect(std.mem.find(u8, failure_writer.buffered(), ansi.red ++ "Switch failed: denied") != null);
}

test "Scenario: Given live screen status and footers with color when rendering then status and footer styles match command rules" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "healthy@example.com", "", .business);
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
    try std.testing.expect(std.mem.find(u8, switch_output, ansi.cyan ++ "Live refresh: api | Refresh in 25s") != null);
    try std.testing.expect(std.mem.find(u8, switch_output, ansi.cyan ++ "Keys:") != null);

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
    try std.testing.expect(std.mem.find(u8, remove_output, ansi.cyan ++ "Live refresh: api | Refresh in 25s") != null);
    try std.testing.expect(std.mem.find(u8, remove_output, ansi.cyan ++ "Keys:") != null);
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
        "Keys: Up/Down scroll, j/k row, Enter credits, PgUp/PgDn/Home/End page, Esc/q quit\n",
        listTuiFooterText(true),
    );
    try std.testing.expectEqualStrings(
        "Keys: Up/Down or j/k credit, Enter redeem, Esc/q back\n",
        listCreditsTuiFooterText(true),
    );
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
        "Keys: ↑/↓ scroll, j/k row, Enter credits, PgUp/PgDn/Home/End page, Esc/q quit\n",
        listTuiFooterText(false),
    );
    try std.testing.expectEqualStrings(
        "Keys: ↑/↓ or j/k credit, Enter redeem, Esc/q back\n",
        listCreditsTuiFooterText(false),
    );
}

test "Scenario: Given a live TUI write failure when mapping output errors then it becomes a handled TUI error" {
    try std.testing.expect(mapTuiOutputError(error.WriteFailed) == error.TuiOutputUnavailable);
    try std.testing.expect(mapTuiOutputError(error.EndOfStream) == error.EndOfStream);
}

test "Scenario: Given usage overrides when rendering remove list then failed rows show response status in both usage columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
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

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "401" };
    var rows = try buildSwitchRowsWithUsageOverrides(gpa, &reg, &usage_overrides);
    defer rows.deinit(gpa);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const idx_width = @max(@as(usize, 2), indexWidth(rows.selectable_row_indices.len));
    try renderSwitchList(&writer, &reg, rows.items, idx_width, rows.widths, null, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.find(u8, output, ansi.red) != null);
}

test "Scenario: Given usage overrides when rendering remove list with color then failed rows are highlighted red" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
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
    try std.testing.expect(std.mem.find(u8, output, ansi.red) != null);
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
        .plan_type = .business,
    };

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    try std.testing.expectEqualStrings("Business", rows.items[0].plan);
}

test "live list details show reset credits cell and scroll within the viewport" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    const details = try codex_auth.api.usage.parseResetCreditResponse(gpa,
        \\{"available_count":1,"total_earned_count":2,"credits":[
        \\{"id":"first-card","reset_type":"codex_rate_limits","status":"used","granted_at":"2026-08-01T00:00:00Z","expires_at":null,"title":"First card"},
        \\{"id":"last-card","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-10-01T00:00:00Z","title":"Last card","description":"Reset quota.\u001b[2J"}]}
    );
    reg.accounts.items[0].access_token_expires_at = 1790000000;
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 30, .window_minutes = 300, .resets_at = 1790000100 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 1,
        .reset_credit = details,
    };
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var styled_body = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, null, null, false);
    for ([_][]const u8{ "ACCOUNT", "PLAN", "test@e", "TOKEN EXPIRE", "RESETS", "1 (exp 10-01)" }) |expected| {
        try std.testing.expect(std.mem.find(u8, body.written(), expected) != null);
    }
    try std.testing.expect(std.mem.find(u8, body.written(), "00:00:00 UTC") == null);
    try std.testing.expect(std.mem.findScalar(u8, body.written(), 27) == null);
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    var styled_frame = StyledWriter.init(&frame.writer, false);
    const count = std.mem.count(u8, body.written(), "\n") - 1;
    var start: usize = count;
    var viewport = live_tui.listViewport(7, count, live_tui.listFixedLines("ready"), &start);
    viewport.max_cols = null;
    try cli.render.renderListBodyViewport(&styled_frame, body.written(), "ready", viewport);
    try std.testing.expect(std.mem.find(u8, frame.written(), "10-01") != null);
    try std.testing.expect(std.mem.find(u8, frame.written(), "ACCOUNT") != null);
    try std.testing.expect(std.mem.find(u8, frame.written(), "ready") != null);
    try std.testing.expect(std.mem.count(u8, frame.written(), "\n") <= 7);

    body.clearRetainingCapacity();
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, 40, null, false);
    var lines = std.mem.splitScalar(u8, body.written(), '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 40);

    var color_body: std.Io.Writer.Allocating = .init(gpa);
    defer color_body.deinit();
    var colored_writer = StyledWriter.init(&color_body.writer, true);
    try cli.render.renderListBody(gpa, &colored_writer, &reg, rows.items, 2, rows.widths, 120, null, false);
    try std.testing.expect(std.mem.find(u8, color_body.written(), ansi.cyan) != null);
    try std.testing.expect(std.mem.find(u8, color_body.written(), ansi.bold) != null);
}

test "live list derives the reset credits count from available cards when the summary is absent" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    const details = try codex_auth.api.usage.parseResetCreditResponse(gpa,
        \\{"available_count":1,"total_earned_count":2,"credits":[
        \\{"id":"first-card","reset_type":"codex_rate_limits","status":"used","granted_at":"2026-08-01T00:00:00Z","expires_at":null,"title":"First card"},
        \\{"id":"last-card","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-10-01T00:00:00Z","title":"Last card"}]}
    );
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 30, .window_minutes = 300, .resets_at = 1790000100 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = null,
        .reset_credit = details,
    };
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var styled_body = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, null, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "1 (exp 10-01)") != null);
}

test "Scenario: Given a live list cursor when rendering the body then the cursor row shares the active row's green" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    // Email-sorted: the cursor account lands on row 1, the active one on row 2.
    try appendTestAccount(gpa, &reg, "user-1::acc-1", "a-cursor@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "b-active@example.com", "", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-2");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var colored = StyledWriter.init(&body.writer, true);
    try cli.render.renderListBody(gpa, &colored, &reg, rows.items, 2, rows.widths, null, 0, false);

    // Cursor row: the ">" glyph wears the same green as the active row — the
    // glyph, not the color, says which row Enter acts on (the pickers' rule).
    try std.testing.expect(std.mem.find(u8, body.written(), ansi.green ++ ">  1") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), ansi.green ++ "*  2") != null);

    // Cursor on the active row: ">" wins the marker, the green survives.
    body.clearRetainingCapacity();
    try cli.render.renderListBody(gpa, &colored, &reg, rows.items, 2, rows.widths, null, 1, false);
    try std.testing.expect(std.mem.find(u8, body.written(), ansi.green ++ ">  2") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "*  2") == null);
}

test "Scenario: Given grouped accounts when resolving the rail cursor start then group headers do not shift the index" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "a@example.com", "", .pro);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "shared@example.com", "team-a", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-3", "shared@example.com", "team-b", .business);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-3");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    // Live data-row basis: a@=0; the shared-email group header is not a row,
    // and within the group rows order alphabetically by their displayed label
    // (team-a=1, team-b=2 — active status does not reorder the group).
    try std.testing.expectEqual(@as(?usize, 0), cli.render.liveDataIndexForAccountKey(rows.items, &reg, "user-1::acc-1"));
    try std.testing.expectEqual(@as(?usize, 1), cli.render.liveDataIndexForAccountKey(rows.items, &reg, "user-1::acc-2"));
    try std.testing.expectEqual(@as(?usize, 2), cli.render.liveDataIndexForAccountKey(rows.items, &reg, "user-1::acc-3"));
    try std.testing.expectEqual(@as(?usize, null), cli.render.liveDataIndexForAccountKey(rows.items, &reg, "user-1::missing"));
}

test "reset credits panel renders the remaining rail and compact rows" {
    const gpa = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "soon", .title = "Full reset (Weekly + 5 hr)", .expires_at = "2026-11-01T00:00:00Z", .epoch = now + 9 * 86400 },
        .{ .id = "undated", .title = null, .expires_at = null, .epoch = null },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The caller feeds this count to the viewport, so it must include every line.
    const lines = try cli.reset_credits_panel.render(gpa, &out.writer, &cards, .{
        .max_cols = 100,
        .now = now,
        .card_cursor = 0,
        .confirm_pending = true,
        .status = "reset credit redeemed",
        .status_kind = .ok,
        .indent = 6,
    });
    try std.testing.expectEqual(@as(usize, 4), lines);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out.written(), "\n"));
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "      RESETS · 2 available") != null);
    try std.testing.expect(std.mem.find(u8, text, "      > Full reset (Weekly + 5 hr) · ") != null);
    try std.testing.expect(std.mem.find(u8, text, "· in 9d · Enter again to redeem") != null);
    try std.testing.expect(std.mem.find(u8, text, "        untitled") != null);
    try std.testing.expect(std.mem.find(u8, text, "      ✓ reset credit redeemed") != null);
    try std.testing.expect(!std.mem.endsWith(u8, text, "└\n"));
}

test "reset credits panel uses heading and selected color roles" {
    const gpa = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "soon", .title = "Full reset", .expires_at = null, .epoch = null },
        .{ .id = "later", .title = "Later card", .expires_at = null, .epoch = null },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try cli.reset_credits_panel.render(gpa, &out.writer, &cards, .{
        .max_cols = 100,
        .now = now,
        .card_cursor = 0,
        .status = "reset credit redeemed",
        .status_kind = .ok,
        .indent = 4,
        .use_color = true,
    });
    const text = out.written();
    // Borderless design D: the heading carries weight/color, the selected
    // credit is green, and the other credit stays at the default foreground.
    try std.testing.expect(std.mem.find(u8, text, "\x1b[1m\x1b[36mRESETS · 2 available\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[32m> Full reset\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[32m  Later card") == null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[32m✓ reset credit redeemed\x1b[0m") != null);
}

test "reset credits panel draws redeemed cards as struck ghosts in their slots" {
    const gpa = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "weekly", .title = "Weekly limit reset", .expires_at = "2027-01-01T00:00:00Z", .epoch = now + 30 * 86400 },
        .{ .id = "undated", .title = null, .expires_at = null, .epoch = null },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Two consumed ghosts bracket the live card by expiry: the 5h card sits
    // before "weekly", the month card after it, while the cursor has moved on.
    // Success writes no bottom status — each ghost's `redeemed` tag is it.
    const lines = try cli.reset_credits_panel.render(gpa, &out.writer, &cards, .{
        .max_cols = 100,
        .now = now,
        .card_cursor = 0,
        .spent_cards = &.{
            .{ .title = "Month reset", .epoch = now + 60 * 86400 },
            .{ .title = "5h reset credit", .epoch = now + 7 * 86400 },
        },
        .indent = 6,
        .use_color = true,
    });
    try std.testing.expectEqual(@as(usize, 5), lines);
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "RESETS · 2 available") != null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[2m\x1b[9m  5h reset credit") != null);
    // The `redeemed` tag is the success report: a plain space, green, and
    // crucially OUTSIDE the strike — the reset+green SGR pair between the
    // struck span and the tag is what keeps it from being struck through.
    try std.testing.expect(std.mem.find(u8, text, "\x1b[0m\x1b[32m redeemed\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, text, "· redeemed") == null);
    try std.testing.expect(std.mem.find(u8, text, "redeemed") != null);
    // `redeemed` must not sit inside any struck span: every `redeemed` is
    // preceded by a reset since the last strike-open.
    var scan_at: usize = 0;
    while (std.mem.findPos(u8, text, scan_at, "redeemed")) |tag_at| {
        const strike_open = std.mem.findLast(u8, text[0..tag_at], "\x1b[9m") orelse 0;
        const last_reset = std.mem.findLast(u8, text[0..tag_at], "\x1b[0m") orelse 0;
        try std.testing.expect(last_reset > strike_open);
        scan_at = tag_at + 1;
    }
    const ghost_a = std.mem.find(u8, text, "5h reset credit").?;
    const weekly_at = std.mem.find(u8, text, "Weekly limit reset").?;
    const ghost_b = std.mem.find(u8, text, "Month reset").?;
    try std.testing.expect(ghost_a < weekly_at);
    try std.testing.expect(weekly_at < ghost_b);
    try std.testing.expect(std.mem.find(u8, text, "> Weekly limit reset") != null);
    try std.testing.expect(std.mem.find(u8, text, "> 5h") == null);
    try std.testing.expect(std.mem.find(u8, text, "✓") == null);
}

test "reset credits mergedCardLine reports the armed card's line inside the block" {
    const now: i64 = 1_800_000_000;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "a", .title = "A", .expires_at = null, .epoch = now + 10 },
        .{ .id = "b", .title = "B", .expires_at = null, .epoch = now + 20 },
    };
    const spent = [_]cli.reset_credits_panel.Selection.SpentCard{
        .{ .title = "g1", .epoch = now + 5 },
        .{ .title = "g2", .epoch = now + 10 },
        .{ .title = "g3", .epoch = now + 30 },
    };
    // Merged order: RESETS(0) g1(1) g2(2) A(3) B(4) g3(5) — a ghost on a tied
    // expiry still lands ahead of the card, matching the `<=` merge rule.
    try std.testing.expectEqual(@as(usize, 3), cli.reset_credits_panel.mergedCardLine(&cards, &spent, 0));
    try std.testing.expectEqual(@as(usize, 4), cli.reset_credits_panel.mergedCardLine(&cards, &spent, 1));
    // No ghosts: the card sits directly under the heading.
    try std.testing.expectEqual(@as(usize, 2), cli.reset_credits_panel.mergedCardLine(&cards, &.{}, 1));
}

test "reset credits panel keeps spent ghosts until the selection or refresh drops them" {
    const gpa = std.testing.allocator;
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 3, .valid = true };
    defer sel.deinit(gpa);
    var rendered: cli.reset_credits_panel.RenderedIdentity = .{};

    try sel.addSpentCard(gpa, "5h reset credit", 123);
    try sel.addSpentCard(gpa, "Weekly reset", 456);
    try std.testing.expectEqual(@as(usize, 2), sel.spent_cards.items.len);

    // A newer status replaces only the text; the ghosts mark real consumed
    // cards, not the last action, so they stay through a card move too.
    try sel.setStatusFor(gpa, "acct-a", "reset credit redeemed", .ok);
    try sel.setStatusFor(gpa, "acct-a", "redeem failed", .fail);
    sel.moveCardAndInvalidate(gpa, &rendered, .down);
    try std.testing.expect(sel.status == null);
    try std.testing.expectEqual(@as(usize, 2), sel.spent_cards.items.len);

    // Leaving the row (or closing the rail through close/clearSelection)
    // drops them: the ghosts belong to this account's session.
    sel.clearSelection(gpa);
    try std.testing.expectEqual(@as(usize, 0), sel.spent_cards.items.len);
}

test "reset credits panel stays ASCII on Windows" {
    const gpa = std.testing.allocator;
    const now: i64 = 1_800_000_000;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "soon", .title = "Full reset (Weekly + 5 hr)", .expires_at = "2026-11-01T00:00:00Z", .epoch = now + 9 * 86400 },
        .{ .id = "undated", .title = null, .expires_at = null, .epoch = null },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // The rail is borderless on every platform, so Windows only changes the
    // separator and success marker.
    const lines = try cli.reset_credits_panel.render(gpa, &out.writer, &cards, .{
        .max_cols = 100,
        .now = now,
        .card_cursor = 0,
        .confirm_pending = true,
        .status = "reset credit redeemed",
        .status_kind = .ok,
        .indent = 6,
        .is_windows = true,
    });
    try std.testing.expectEqual(@as(usize, 4), lines);
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "      RESETS, 2 available") != null);
    try std.testing.expect(std.mem.find(u8, text, "      > Full reset (Weekly + 5 hr), ") != null);
    try std.testing.expect(std.mem.find(u8, text, ", in 9d, Enter again to redeem") != null);
    try std.testing.expect(std.mem.find(u8, text, "        untitled") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "      OK reset credit redeemed\n"));
    // docs/windows.md: no box-drawing, bullets, arrows or marks in the output.
    for (text) |byte| try std.testing.expect(byte < 0x80);
}

test "reset credits panel keeps every line inside a narrow width budget" {
    const gpa = std.testing.allocator;
    const cards = [_]cli.reset_credits_panel.AvailableCard{
        .{ .id = "soon", .title = "Full reset (Weekly + 5 hr)", .expires_at = null, .epoch = null },
    };
    // Below a three-column text budget the ellipsis itself must shrink instead
    // of widening the line, and the status marker is truncated with its message.
    for ([_]usize{ 1, 2, 3, 4, 5, 9 }) |max_cols| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try cli.reset_credits_panel.render(gpa, &out.writer, &cards, .{
            .max_cols = max_cols,
            .now = 1_800_000_000,
            .status = "reset credit redeemed",
            .status_kind = .ok,
            .is_windows = true,
        });
        var iter = std.mem.splitScalar(u8, out.written(), '\n');
        while (iter.next()) |line| {
            try std.testing.expect(line.len <= max_cols);
        }
    }
}

test "reset credits panel hint tracks the armed credit identity" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const Identity = cli.reset_credits_panel.Identity;
    const card_zero = Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    const card_one = Identity{ .account_key = "acct-a", .credit_id = "card-1" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card_zero));
    try std.testing.expect(sel.isPendingFor(card_zero));
    // The hint must never appear on a card that a second Enter would not redeem.
    try std.testing.expect(!sel.isPendingFor(card_one));
    try std.testing.expect(!sel.isPendingFor(null));
    try std.testing.expect(!sel.isPendingFor(.{ .account_key = "acct-b", .credit_id = "card-0" }));
}

test "reset credits panel approval is dropped by a cursor move queued in the same key batch" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card));
    try std.testing.expectEqual(Step.consume, sel.confirm(gpa, card));
    // A `j` that arrives in the same input batch as the two Enters would move
    // the rail before the queued redeem runs, cancelling it silently; the live
    // loop stops consuming the batch once a redeem is queued.
    sel.moveRow(gpa, .down, 6);
    try std.testing.expect(!sel.approve(gpa, card));
}

test "reset credits panel invalidates a rendered credit when the highlight moves in one key batch" {
    const gpa = std.testing.allocator;
    const Identity = cli.reset_credits_panel.Identity;
    const RenderedIdentity = cli.reset_credits_panel.RenderedIdentity;
    const first = Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    const second = Identity{ .account_key = "acct-a", .credit_id = "card-1" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);
    var rendered: RenderedIdentity = .{};
    defer rendered.deinit(gpa);

    try rendered.set(gpa, first);

    // At a boundary the highlight does not move, so the cached identity still
    // describes the card drawn on screen and remains usable.
    sel.moveCardAndInvalidate(gpa, &rendered, .up);
    try std.testing.expectEqual(@as(usize, 0), sel.card_cursor);
    try std.testing.expectEqualStrings("card-0", rendered.get().?.credit_id);

    // A real move drops the frame identity immediately, before the next render.
    sel.moveCardAndInvalidate(gpa, &rendered, .down);
    try std.testing.expectEqual(@as(usize, 1), sel.card_cursor);
    try std.testing.expect(rendered.get() == null);

    // Simulate the rest of the input batch: Enter can only act on a live frame
    // identity. Without the invalidation above it would arm the old card.
    if (rendered.get()) |identity| _ = sel.confirm(gpa, identity);
    try std.testing.expect(!sel.isPendingFor(first));
    try std.testing.expect(!sel.isPendingFor(second));

    // The new frame publishes the new card; a boundary move keeps it valid.
    try rendered.set(gpa, second);
    sel.moveCardAndInvalidate(gpa, &rendered, .down);
    try std.testing.expectEqual(@as(usize, 1), sel.card_cursor);
    try std.testing.expectEqualStrings("card-1", rendered.get().?.credit_id);
}

test "live list follows the credits rail into the viewport" {
    // A single row above the viewport: scroll up to it.
    try std.testing.expectEqual(@as(usize, 2), live_tui.followViewportStart(40, 10, 20, .{ .first = 2, .last = 2 }));
    // Below the viewport: it becomes the last visible line.
    try std.testing.expectEqual(@as(usize, 30), live_tui.followViewportStart(40, 10, 0, .{ .first = 39, .last = 39 }));
    // Already visible: unchanged.
    try std.testing.expectEqual(@as(usize, 20), live_tui.followViewportStart(40, 10, 20, .{ .first = 25, .last = 25 }));
    // Without a rail the plain clamp still applies.
    try std.testing.expectEqual(@as(usize, 20), live_tui.followViewportStart(40, 10, 20, null));
    try std.testing.expectEqual(@as(usize, 30), live_tui.followViewportStart(40, 10, 99, null));
    // Everything fits on screen, and a zero-height viewport, stay at the top.
    try std.testing.expectEqual(@as(usize, 0), live_tui.followViewportStart(5, 10, 3, .{ .first = 4, .last = 4 }));
    try std.testing.expectEqual(@as(usize, 0), live_tui.followViewportStart(40, 0, 20, .{ .first = 5, .last = 5 }));
}

test "live list keeps the whole credits rail visible, not just its anchor row" {
    // The rail hangs below its row: following the row alone would pin it to the
    // last visible line and push the confirm hint and the redeem result off
    // screen, where a second Enter would still consume a credit.
    try std.testing.expectEqual(
        @as(usize, 30),
        live_tui.followViewportStart(40, 10, 0, .{ .first = 34, .last = 39 }),
    );
    // A rail taller than the viewport keeps its end, where the hint is drawn.
    try std.testing.expectEqual(
        @as(usize, 30),
        live_tui.followViewportStart(40, 10, 0, .{ .first = 20, .last = 39 }),
    );
    // Scrolling up top-aligns the anchor row, which keeps a fitting rail visible.
    try std.testing.expectEqual(
        @as(usize, 2),
        live_tui.followViewportStart(40, 10, 20, .{ .first = 2, .last = 6 }),
    );
    // The rail end is visible but its anchor row scrolled off, and both fit.
    try std.testing.expectEqual(
        @as(usize, 18),
        live_tui.followViewportStart(40, 10, 20, .{ .first = 18, .last = 25 }),
    );
    // A fully visible rail does not move the viewport.
    try std.testing.expectEqual(
        @as(usize, 20),
        live_tui.followViewportStart(40, 10, 20, .{ .first = 22, .last = 27 }),
    );
}

test "reset credits panel orders cards by parsed expiry and keeps undated cards last" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    const details = try codex_auth.api.usage.parseResetCreditResponse(gpa,
        \\{"available_count":3,"total_earned_count":4,"credits":[
        \\{"id":"nov","status":"available","expires_at":"2026-11-01T00:00:00Z","title":"Full reset (Weekly + 5 hr)"},
        \\{"id":"undated","status":"available","expires_at":null,"title":"Late grant"},
        \\{"id":"used","status":"consumed","expires_at":"2026-09-01T00:00:00Z","title":"Used card"},
        \\{"id":"oct","status":"available","expires_at":"2026-10-01T00:00:00Z","title":"Half reset"}]}
    );
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 3,
        .reset_credit = details,
    };

    const cards = try cli.reset_credits_panel.collectAvailable(gpa, &reg.accounts.items[0], &.{});
    defer gpa.free(cards);

    try std.testing.expectEqual(@as(usize, 3), cards.len);
    try std.testing.expectEqualStrings("oct", cards[0].id);
    try std.testing.expectEqual(@as(i64, 1_790_812_800), cards[0].epoch.?);
    try std.testing.expectEqualStrings("nov", cards[1].id);
    try std.testing.expectEqual(@as(i64, 1_793_491_200), cards[1].epoch.?);
    try std.testing.expectEqualStrings("undated", cards[2].id);
    try std.testing.expect(cards[2].epoch == null);
}

test "reset credits panel opens only for rows with a consumable credit" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);

    // No usage snapshot: the row has nothing to open.
    try std.testing.expect(!try cli.reset_credits_panel.hasAvailable(gpa, &reg.accounts.items[0], &.{}));

    const details = try codex_auth.api.usage.parseResetCreditResponse(gpa,
        \\{"available_count":1,"total_earned_count":1,"credits":[
        \\{"id":"only","status":"available","expires_at":null,"title":"Only card"}]}
    );
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 1,
        .reset_credit = details,
    };

    try std.testing.expect(try cli.reset_credits_panel.hasAvailable(gpa, &reg.accounts.items[0], &.{}));
    // A credit already consumed in this session cannot reopen the rail.
    try std.testing.expect(!try cli.reset_credits_panel.hasAvailable(gpa, &reg.accounts.items[0], &.{"only"}));
}

test "reset credits panel bounds multibyte lines by display width" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try cli.reset_credits_panel.render(gpa, &out.writer, &.{}, .{
        .max_cols = 7,
        .now = 1_800_000_000,
        .status = "✓ used",
    });
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(text_width.displayWidth(line) <= 7);
    }
}

test "reset credits panel requires a second confirm on the same credit after moving" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card_zero = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    const card_one = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-1" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card_zero));
    try std.testing.expect(sel.isPendingFor(card_zero));
    sel.moveCard(gpa, .down);
    try std.testing.expect(!sel.isPendingFor(card_zero));
    try std.testing.expectEqual(@as(usize, 1), sel.card_cursor);
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card_one));
    try std.testing.expectEqual(Step.consume, sel.confirm(gpa, card_one));
    try std.testing.expect(sel.approve(gpa, card_one));
    try std.testing.expect(!sel.approve(gpa, card_one));
}

test "reset credits panel drops a pending confirm when the account row moves" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card));
    sel.moveRow(gpa, .down, 4);
    try std.testing.expectEqual(@as(usize, 1), sel.row_cursor);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expect(!sel.valid);
    try std.testing.expectEqual(Step.ignored, sel.confirm(gpa, card));
    sel.moveRow(gpa, .down, 4);
    sel.clampRow(gpa, 1);
    try std.testing.expectEqual(@as(usize, 0), sel.row_cursor);
    try std.testing.expect(!sel.valid);
    sel.updateCards(gpa, 2);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expectEqual(@as(usize, 0), sel.card_cursor);
}

test "reset credits panel cannot confirm a row without a consumable credit" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card));
    sel.clearSelection(gpa);
    try std.testing.expect(!sel.valid);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expectEqual(Step.ignored, sel.confirm(gpa, card));
    try std.testing.expectEqual(Step.ignored, sel.confirm(gpa, card));
    try std.testing.expect(!sel.approve(gpa, card));
}

test "reset credits panel binds a pending confirm to one account and credit" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const first = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    const other_credit = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-9" };
    const other_account = cli.reset_credits_panel.Identity{ .account_key = "acct-b", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, first));
    // A refresh that keeps the list length but swaps the highlighted card must
    // not let the queued second Enter redeem the new card.
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, other_credit));
    try std.testing.expect(!sel.approve(gpa, first));
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, other_credit));
    try std.testing.expect(!sel.approve(gpa, other_account));
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, other_credit));
    try std.testing.expectEqual(Step.consume, sel.confirm(gpa, other_credit));
    try std.testing.expect(sel.approve(gpa, other_credit));
    try std.testing.expect(!sel.approve(gpa, other_credit));
}

test "reset credits panel keeps a confirm armed only while the credit stays highlighted" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const first = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, first));
    sel.updateCards(gpa, 2);
    try std.testing.expect(sel.isPendingFor(first));
    try std.testing.expect(sel.valid);
    sel.moveCard(gpa, .down);
    const second = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-1" };
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, second));
    sel.updateCards(gpa, 1);
    try std.testing.expect(!sel.isPendingFor(second));
    try std.testing.expectEqual(@as(usize, 0), sel.card_cursor);
}

test "reset credits panel moves only the credit cursor, never the account row" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const on_row = cli.reset_credits_panel.Identity{ .account_key = "acct-row-3", .credit_id = "card-1" };
    var sel: cli.reset_credits_panel.Selection = .{
        .expanded = true,
        .row_cursor = 3,
        .card_cursor = 1,
        .card_count = 3,
        .valid = true,
    };
    defer sel.deinit(gpa);

    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, on_row));
    sel.moveCard(gpa, .down);
    try std.testing.expectEqual(@as(usize, 3), sel.row_cursor);
    try std.testing.expectEqual(@as(usize, 2), sel.card_cursor);
    try std.testing.expect(sel.expanded);
    try std.testing.expect(sel.valid);
    try std.testing.expect(!sel.isPendingFor(on_row));

    // The credit cursor clamps at both ends without borrowing a row step from
    // the next account, so holding Down cannot walk off the current account.
    sel.moveCard(gpa, .down);
    try std.testing.expectEqual(@as(usize, 3), sel.row_cursor);
    try std.testing.expectEqual(@as(usize, 2), sel.card_cursor);
    sel.moveCard(gpa, .up);
    sel.moveCard(gpa, .up);
    sel.moveCard(gpa, .up);
    try std.testing.expectEqual(@as(usize, 3), sel.row_cursor);
    try std.testing.expectEqual(@as(usize, 0), sel.card_cursor);

    // Only the explicit row move changes the parent row.
    sel.moveRow(gpa, .down, 6);
    try std.testing.expectEqual(@as(usize, 4), sel.row_cursor);
    try std.testing.expect(!sel.valid);
}

test "reset credits panel reports the last redeem without an empty-list placeholder" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const lines = try cli.reset_credits_panel.render(gpa, &out.writer, &.{}, .{
        .max_cols = 100,
        .now = 1_800_000_000,
        .status = "reset credit redeemed",
        .status_kind = .ok,
        .indent = 4,
    });
    try std.testing.expectEqual(@as(usize, 2), lines);
    try std.testing.expectEqualStrings(
        "    RESETS · 0 available\n    ✓ reset credit redeemed\n",
        out.written(),
    );
    try std.testing.expect(std.mem.find(u8, out.written(), "no available reset credits") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "codex-auth list --api") == null);

    // The same empty rail without a status is only the count, never a hint to
    // go refresh; `0 available` already says there is nothing to use.
    out.clearRetainingCapacity();
    _ = try cli.reset_credits_panel.render(gpa, &out.writer, &.{}, .{
        .max_cols = 100,
        .now = 1_800_000_000,
        .indent = 4,
    });
    try std.testing.expectEqualStrings("    RESETS · 0 available\n", out.written());
}

test "reset credits panel close drops the pending confirm and the status line" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try sel.setStatusFor(gpa, "acct-a", "✓ reset credit redeemed", .ok);
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card));
    sel.close(gpa);
    try std.testing.expect(!sel.expanded);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expectEqualStrings("", sel.status orelse "");
    try std.testing.expectEqual(Step.ignored, sel.confirm(gpa, card));
    sel.toggleExpanded(gpa);
    try std.testing.expect(sel.expanded);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expect(sel.status == null);
}

test "reset credits panel clears the status line when the account row moves" {
    const gpa = std.testing.allocator;
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try sel.setStatusFor(gpa, "acct-a", "✓ reset credit redeemed", .ok);
    sel.moveRow(gpa, .down, 5);
    try std.testing.expect(sel.status == null);
    try sel.setStatusFor(gpa, "acct-a", "✗ redeem failed (HTTP 500)", .fail);
    sel.clearSelection(gpa);
    try std.testing.expect(sel.status == null);
}

test "reset credits panel keeps the redeem report across a card list refresh" {
    const gpa = std.testing.allocator;
    const Step = cli.reset_credits_panel.ConfirmStep;
    const card = cli.reset_credits_panel.Identity{ .account_key = "acct-a", .credit_id = "card-0" };
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try sel.setStatusFor(gpa, "acct-a", "✓ reset credit redeemed", .ok);
    try std.testing.expectEqual(Step.armed, sel.confirm(gpa, card));
    // A background refresh landing right after a redeem replaces the card list
    // under the cursor: it must disarm the confirmation but keep the report of
    // the action that already happened.
    sel.clearCards(gpa);
    try std.testing.expectEqualStrings("✓ reset credit redeemed", sel.status orelse "");
    try std.testing.expectEqual(cli.reset_credits_panel.StatusKind.ok, sel.status_kind);
    try std.testing.expect(!sel.isPendingFor(card));
    try std.testing.expect(!sel.valid);
}

test "reset credits panel binds the status line to its account" {
    const gpa = std.testing.allocator;
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 2, .valid = true };
    defer sel.deinit(gpa);

    try sel.setStatusFor(gpa, "acct-a", "✗ redeem failed (HTTP 500)", .fail);
    try std.testing.expectEqualStrings("✗ redeem failed (HTTP 500)", sel.statusFor("acct-a") orelse "");
    // A refresh can re-sort the rows so the same index resolves to another
    // account: the report belongs to acct-a and must not render under acct-b.
    try std.testing.expect(sel.statusFor("acct-b") == null);
    try sel.setStatusFor(gpa, "acct-b", "✓ reset credit redeemed", .ok);
    try std.testing.expectEqualStrings("✓ reset credit redeemed", sel.statusFor("acct-b") orelse "");
    try std.testing.expect(sel.statusFor("acct-a") == null);
    sel.clearStatus(gpa);
    try std.testing.expect(sel.status == null);
    try std.testing.expect(sel.status_account == null);
}

test "reset credits panel clears the status when the card cursor moves" {
    const gpa = std.testing.allocator;
    var sel: cli.reset_credits_panel.Selection = .{ .expanded = true, .card_count = 3, .valid = true };
    defer sel.deinit(gpa);
    var rendered: cli.reset_credits_panel.RenderedIdentity = .{};

    // A card move re-anchors the highlight: a stale error left under it would
    // read as the new card's failure, and an identical retry error would be
    // indistinguishable from a leftover, so the report must drop with the move.
    try sel.setStatusFor(gpa, "acct-a", "✗ redeem failed (HTTP 500)", .fail);
    sel.moveCardAndInvalidate(gpa, &rendered, .down);
    try std.testing.expect(sel.status == null);
    try std.testing.expect(sel.status_account == null);

    // Digit jumps take the same path as arrows.
    try sel.setStatusFor(gpa, "acct-a", "✗ redeem failed (HTTP 500)", .fail);
    sel.moveCardTo(gpa, 2, &rendered);
    try std.testing.expect(sel.status == null);

    // A move key at the bottom boundary does not move the cursor, so the
    // still-current card keeps its report instead of losing feedback.
    try sel.setStatusFor(gpa, "acct-a", "✗ redeem failed (HTTP 500)", .fail);
    sel.moveCardAndInvalidate(gpa, &rendered, .down);
    try std.testing.expect(sel.statusFor("acct-a") != null);
}

test "reset credits panel splice keeps one line per rendered row" {
    const gpa = std.testing.allocator;
    const body = "header\nrow-a\nrow-b\n";

    const middle = try cli.reset_credits_panel.spliceAfterBodyLine(gpa, body, 0, "RAIL\n");
    defer gpa.free(middle);
    try std.testing.expectEqualStrings("header\nrow-a\nRAIL\nrow-b\n", middle);

    const last = try cli.reset_credits_panel.spliceAfterBodyLine(gpa, body, 1, "RAIL\n");
    defer gpa.free(last);
    try std.testing.expectEqualStrings("header\nrow-a\nrow-b\nRAIL\n", last);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, last, "\n"));
}

test "reset credits panel maps each consume outcome to its status line" {
    const gpa = std.testing.allocator;
    const panel = cli.reset_credits_panel;
    const ConsumeResult = codex_auth.api.reset_credits.ConsumeResult;

    // A fresh redeem reports in place through the spent ghost, not the line.
    var reset_result = ConsumeResult{ .outcome = .reset };
    defer reset_result.deinit(gpa);
    try std.testing.expect((try panel.consumeStatus(gpa, &reset_result)) == null);

    const cases = [_]struct {
        outcome: codex_auth.api.reset_credits.ConsumeOutcome,
        status_code: ?u16 = null,
        error_name: ?[]const u8 = null,
        text: []const u8,
        kind: panel.StatusKind,
    }{
        // already_redeemed consumed nothing this attempt, so unlike a fresh
        // redeem it still needs a line — informational, not a failure.
        .{ .outcome = .already_redeemed, .text = "reset credit already redeemed", .kind = .info },
        .{ .outcome = .nothing_to_reset, .text = "usage does not need a reset right now", .kind = .info },
        .{ .outcome = .no_credit, .text = "reset credit is no longer available; refresh to see current resets", .kind = .fail },
        .{ .outcome = .http_error, .status_code = 500, .text = "redeem failed (HTTP 500)", .kind = .fail },
        .{ .outcome = .http_error, .text = "redeem failed", .kind = .fail },
        .{ .outcome = .unexpected_response, .status_code = 200, .text = "redeem failed (HTTP 200, unexpected response)", .kind = .fail },
        .{ .outcome = .unexpected_response, .text = "redeem failed (unexpected response)", .kind = .fail },
        // Known transport failures use their friendly phrasing; unknown names
        // pass through, and a missing name gets the generic line.
        .{ .outcome = .request_error, .error_name = "TimedOut", .text = "request timed out", .kind = .fail },
        .{ .outcome = .request_error, .error_name = "MissingAuth", .text = "no ChatGPT login on this account", .kind = .fail },
        .{ .outcome = .request_error, .error_name = "WeirdNewError", .text = "WeirdNewError", .kind = .fail },
        .{ .outcome = .request_error, .text = "redeem failed", .kind = .fail },
    };
    for (cases) |case| {
        var result = ConsumeResult{
            .outcome = case.outcome,
            .status_code = case.status_code,
            .error_name = if (case.error_name) |name| try gpa.dupe(u8, name) else null,
        };
        defer result.deinit(gpa);
        const report = (try panel.consumeStatus(gpa, &result)) orelse
            return error.TestUnexpectedResult;
        defer gpa.free(report.text);
        try std.testing.expectEqualStrings(case.text, report.text);
        try std.testing.expectEqual(case.kind, report.kind);
    }
}

test "reset credits panel empty note stays inside the width budget" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // The probe note is a passive line in the rail's spot: indented like the
    // rail, dim when color is on, and gone entirely when it cannot fit.
    const lines = try cli.reset_credits_panel.renderEmptyNote(&out.writer, 4, 100, false);
    try std.testing.expectEqual(@as(usize, 1), lines);
    try std.testing.expectEqualStrings("    no reset credits\n", out.written());

    out.clearRetainingCapacity();
    _ = try cli.reset_credits_panel.renderEmptyNote(&out.writer, 4, 100, true);
    try std.testing.expectEqualStrings("    \x1b[2mno reset credits\x1b[0m\n", out.written());

    out.clearRetainingCapacity();
    _ = try cli.reset_credits_panel.renderEmptyNote(&out.writer, 0, 6, false);
    try std.testing.expectEqualStrings("no ...\n", out.written());

    // At or below the indent there is no room for the note at all.
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), try cli.reset_credits_panel.renderEmptyNote(&out.writer, 4, 4, false));
    try std.testing.expectEqualStrings("", out.written());
}

test "live list maps the credits rail cursor to the rendered account row" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    // Two accounts sharing one email render as a group (header row plus two
    // account rows) alongside a singleton account, so the row indices of
    // rows.items and the rendered data-row indices cannot be used interchangeably.
    try appendTestAccount(gpa, &reg, "user-1::acct-a", "shared@example.com", "", .pro);
    try appendTestAccount(gpa, &reg, "user-1::acct-b", "shared@example.com", "", .plus);
    try appendTestAccount(gpa, &reg, "user-2::acct-c", "other@example.com", "", .pro);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var writer = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, null, null, false);

    const account_count = reg.accounts.items.len;
    var header_rows: usize = 0;
    for (rows.items) |row| {
        if (row.is_header) header_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), header_rows);
    try std.testing.expectEqual(@as(usize, 3), cli.render.liveDataRowCount(rows.items, account_count));
    // The shared email is drawn as one unnumbered line ahead of the group, so
    // the rendered body is one line longer than the data-row count.
    try std.testing.expectEqual(
        cli.render.liveDataRowCount(rows.items, account_count) + header_rows,
        std.mem.count(u8, body.written(), "\n") - 1,
    );
    try std.testing.expect(std.mem.find(u8, body.written(), "shared@example.com") != null);

    // The rail's anchor and the viewport-follow span are body lines, so the
    // data index under a shifted group must map through
    // liveLineIndexForDataIndex: singleton, header line, then two children.
    try std.testing.expectEqual(
        @as(?usize, 0),
        cli.render.liveLineIndexForDataIndex(rows.items, account_count, 0),
    );
    try std.testing.expectEqual(
        @as(?usize, 2),
        cli.render.liveLineIndexForDataIndex(rows.items, account_count, 1),
    );
    try std.testing.expectEqual(
        @as(?usize, 3),
        cli.render.liveLineIndexForDataIndex(rows.items, account_count, 2),
    );
    try std.testing.expect(cli.render.liveLineIndexForDataIndex(rows.items, account_count, 3) == null);

    var iter = std.mem.splitScalar(u8, body.written(), '\n');
    _ = iter.next(); // column header line
    var body_lines = std.ArrayList([]const u8).empty;
    defer body_lines.deinit(gpa);
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        try body_lines.append(gpa, line);
    }
    try std.testing.expectEqual(@as(usize, 4), body_lines.items.len);
    // Line 0 is the singleton, line 1 the group header, lines 2-3 its children.
    try std.testing.expect(std.mem.find(u8, body_lines.items[1], "shared@example.com") != null);
    var shifted: usize = 0;
    for (0..3) |data_index| {
        const line_index = cli.render.liveLineIndexForDataIndex(rows.items, account_count, data_index) orelse
            return error.TestUnexpectedResult;
        const line = body_lines.items[line_index];
        const row_index = cli.render.liveRowIndexForDataIndex(rows.items, account_count, data_index) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(!rows.items[row_index].is_header);
        try std.testing.expect(std.mem.find(u8, line, rows.items[row_index].account) != null);
        if (row_index != data_index) shifted += 1;
    }
    // The naive `rows.items[data_index]` indexing still desyncs from the
    // rendered row once a group header intervenes; the mapping helpers are
    // what keep the rail under the row the cursor points at.
    try std.testing.expect(shifted > 0);
    try std.testing.expect(cli.render.liveRowIndexForDataIndex(rows.items, account_count, 3) == null);
}

test "live list indents grouped account labels inside the account column" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user-1::acct-a", "shared@example.com", "team-a", .pro);
    try appendTestAccount(gpa, &reg, "user-1::acct-b", "shared@example.com", "team-b", .plus);
    try appendTestAccount(gpa, &reg, "user-2::acct-c", "other@example.com", "solo", .pro);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var writer = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, null, null, false);

    const lineCol = struct {
        fn of(text: []const u8, needle: []const u8) usize {
            const at = std.mem.find(u8, text, needle).?;
            const line_start = (std.mem.findScalarLast(u8, text[0..at], '\n') orelse 0) + @intFromBool(at != 0);
            return at - line_start;
        }
    }.of;

    const text = body.written();
    const solo_col = lineCol(text, "solo");
    // Members sit two columns right of the column edge; the group header
    // stays flush with singleton labels.
    try std.testing.expectEqual(solo_col + 2, lineCol(text, "team-a"));
    try std.testing.expectEqual(solo_col + 2, lineCol(text, "team-b"));
    try std.testing.expectEqual(solo_col, lineCol(text, "shared@example.com"));
    // The indent lives inside ACCOUNT: the next column keeps its x position
    // on every row ("Pro" is the singleton's plan, "Plus" the member's).
    try std.testing.expectEqual(lineCol(text, "Pro"), lineCol(text, "Plus"));
}

test "live list renders the bare count when available reset credits have no expiry" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    const details = try codex_auth.api.usage.parseResetCreditResponse(gpa,
        \\{"available_count":1,"total_earned_count":1,"credits":[
        \\{"id":"undated-card","reset_type":"codex_rate_limits","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":null,"title":"Undated card"}]}
    );
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 30, .window_minutes = 300, .resets_at = 1790000100 },
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 1,
        .reset_credit = details,
    };
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var styled_body = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, null, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "(-)") == null);
    try std.testing.expect(std.mem.find(u8, body.written(), "(exp") == null);
}

test "live list shows plan expiry only when it is still in the future" {
    const gpa = std.testing.allocator;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);

    reg.accounts.items[0].plan_expires_at = now + 30 * 86400;
    const expected = try cli.rows.formatFutureDateAlloc(gpa, reg.accounts.items[0].plan_expires_at, now);
    defer gpa.free(expected);

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var styled_body = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, null, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "PLAN EXP") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), expected) != null);

    reg.accounts.items[0].plan_expires_at = now - 30 * 86400;
    body.clearRetainingCapacity();
    try cli.render.renderListBody(gpa, &styled_body, &reg, rows.items, 2, rows.widths, null, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "PLAN EXP") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), expected) == null);
}

test "live list keeps the active marker visible for double-digit accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    for (1..11) |idx| try appendNumberedTestAccount(gpa, &reg, idx);
    reg.active_account_key = try gpa.dupe(u8, "user-010::acc-010");

    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var writer = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, 120, null, false);

    try std.testing.expect(std.mem.find(u8, body.written(), "* 10") != null);
}

test "live list distinguishes unavailable reset details from an empty server list" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var writer = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, 120, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "ACCOUNT") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "CREDIT 1 EXP") == null);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credit = try codex_auth.api.usage.parseResetCreditResponse(gpa,
            \\{"available_count":0,"credits":[]}
        ),
    };
    body.clearRetainingCapacity();
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, 120, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "ACCOUNT") != null);
    try std.testing.expect(std.mem.find(u8, body.written(), "CREDIT 1 EXP") == null);
}

test "live list defers PLAN EXPIRE and keeps the configured column order" {
    const gpa = std.testing.allocator;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "very-long-account-name@example.com", "very-long-account-name", .pro);
    reg.accounts.items[0].plan_expires_at = now + 30 * 86400;
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = .{ .used_percent = 42, .window_minutes = 10080, .resets_at = now + 604800 },
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 3,
    };
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);

    var width: usize = 20;
    while (width <= 140) : (width += 1) {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var writer = StyledWriter.init(&body.writer, false);
        try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, width, null, false);

        var lines = std.mem.splitScalar(u8, body.written(), '\n');
        const header = lines.next() orelse "";
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(line.len <= width);
        }
        if (std.mem.find(u8, header, "5H") != null) {
            try std.testing.expect(std.mem.find(u8, body.written(), "100%") != null);
        }
    }

    var narrow_body: std.Io.Writer.Allocating = .init(gpa);
    defer narrow_body.deinit();
    var narrow_writer = StyledWriter.init(&narrow_body.writer, false);
    try cli.render.renderListBody(gpa, &narrow_writer, &reg, rows.items, 2, rows.widths, 60, null, false);
    try std.testing.expect(std.mem.find(u8, narrow_body.written(), "PLAN EXP") == null);
    var lines = std.mem.splitScalar(u8, narrow_body.written(), '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 60);

    var wide_body: std.Io.Writer.Allocating = .init(gpa);
    defer wide_body.deinit();
    var wide_writer = StyledWriter.init(&wide_body.writer, false);
    try cli.render.renderListBody(gpa, &wide_writer, &reg, rows.items, 2, rows.widths, 200, null, false);
    const body = wide_body.written();
    try std.testing.expect(std.mem.find(u8, body, "PLAN EXP") != null);
    var last_index: usize = 0;
    for ([_][]const u8{ "ACCOUNT", "PLAN", "PLAN EXP", "RESETS", "5H", "WEEKLY", "TOKEN EXPIRE", "LAST" }) |token| {
        const index = std.mem.find(u8, body, token) orelse return error.TestUnexpectedResult;
        try std.testing.expect(index >= last_index);
        last_index = index;
    }
    lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 200);
}

test "live list renders zero reset credits without an expiry marker" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user::account", "test@example.com", "", .pro);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .plan_type = .pro,
        .reset_credits = 0,
        .reset_credit = try codex_auth.api.usage.parseResetCreditResponse(gpa,
            \\{"available_count":0,"credits":[]}
        ),
    };
    var rows = try buildSwitchRows(gpa, &reg);
    defer rows.deinit(gpa);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var writer = StyledWriter.init(&body.writer, false);
    try cli.render.renderListBody(gpa, &writer, &reg, rows.items, 2, rows.widths, null, null, false);
    try std.testing.expect(std.mem.find(u8, body.written(), "0 (-)") == null);
    try std.testing.expect(std.mem.find(u8, body.written(), "0") != null);
}

test "mouse wheel step scales with visible rows" {
    try std.testing.expectEqual(@as(usize, 6), live_tui.mouseWheelRows(1));
    try std.testing.expectEqual(@as(usize, 6), live_tui.mouseWheelRows(18));
    try std.testing.expectEqual(@as(usize, 10), live_tui.mouseWheelRows(30));
    try std.testing.expectEqual(@as(usize, 12), live_tui.mouseWheelRows(80));
}

test "list viewport keys keep paging and accept alternate-scroll wheel arrows" {
    var viewport_start: usize = 9;
    const row_count: usize = 105;
    const max_rows: usize = 20;
    const wheel_rows: usize = live_tui.mouseWheelRows(max_rows);

    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .move_up));
    try std.testing.expectEqual(@as(usize, 3), viewport_start);
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .move_down));
    try std.testing.expectEqual(@as(usize, 9), viewport_start);
    // A wheel notch is one small step, independent of the arrow-scroll step.
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .scroll_down));
    try std.testing.expectEqual(@as(usize, 9 + live_tui.mouse_wheel_lines), viewport_start);
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .scroll_up));
    try std.testing.expectEqual(@as(usize, 9), viewport_start);
    try std.testing.expect(!live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .{ .byte = 'j' }));
    try std.testing.expectEqual(@as(usize, 9), viewport_start);
    try std.testing.expect(!live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .{ .byte = 'k' }));
    try std.testing.expectEqual(@as(usize, 9), viewport_start);

    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .page_down));
    try std.testing.expectEqual(@as(usize, 29), viewport_start);
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .page_up));
    try std.testing.expectEqual(@as(usize, 9), viewport_start);
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .home));
    try std.testing.expectEqual(@as(usize, 0), viewport_start);
    try std.testing.expect(live_tui.applyListViewportKey(row_count, max_rows, &viewport_start, wheel_rows, .end));
    try std.testing.expectEqual(@as(usize, 85), viewport_start);
}

test "display width counts UTF-8 codepoints instead of bytes" {
    try std.testing.expectEqual(@as(usize, 7), text_width.displayWidth("Рабочая"));
    try std.testing.expectEqual(@as(usize, 6), text_width.prefixByteLength("Рабочая", 3));
    try std.testing.expectEqualStrings("чая", "Рабочая"[text_width.suffixStart("Рабочая", 3)..]);
}
