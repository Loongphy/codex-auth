const std = @import("std");
const codex_auth = @import("codex_auth");

const cli = codex_auth.cli;
const registry = codex_auth.registry;

const SwitchRow = cli.rows.SwitchRow;
const StyledWriter = cli.render.StyledWriter;

fn renderListScreenViewport(
    out: *std.Io.Writer,
    reg: *registry.Registry,
    rows: []const SwitchRow,
    idx_width: usize,
    widths: cli.render.SwitchWidths,
    use_color: bool,
    status_line: []const u8,
    viewport: cli.render.LiveListViewport,
) !void {
    var styled = StyledWriter.init(out, use_color);
    try cli.render.renderListScreenViewport(&styled, reg, rows, idx_width, widths, status_line, viewport);
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

fn testMutableString(comptime value: []const u8) []u8 {
    return @constCast(value);
}

fn testRow(
    comptime account: []const u8,
    comptime plan: []const u8,
    comptime rate_5h: []const u8,
    comptime rate_week: []const u8,
    comptime last: []const u8,
) SwitchRow {
    return .{
        .account_index = 0,
        .account = testMutableString(account),
        .plan = plan,
        .rate_5h = testMutableString(rate_5h),
        .rate_week = testMutableString(rate_week),
        .last = testMutableString(last),
        .depth = 0,
        .is_active = false,
        .has_error = false,
        .is_header = false,
    };
}

fn expectLinesWithin(output: []const u8, max_cols: usize) !void {
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(line.len <= max_cols);
    }
}

test "Scenario: Given a narrow table when rendering then account identity and usage columns are kept before plan and last" {
    var rows = [_]SwitchRow{
        testRow("very-long-account-name@example.com", "Business", "100%", "42%", "Now"),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderListScreenViewport(&writer, &reg, &rows, 2, .{
        .email = 32,
        .plan = 8,
        .rate_5h = 4,
        .rate_week = 6,
        .last = 4,
    }, false, "", .{
        .start_row = 0,
        .max_rows = 1,
        .max_cols = 33,
    });

    const output = writer.buffered();
    try expectLinesWithin(output, 33);
    try std.testing.expect(std.mem.indexOf(u8, output, "very-l.ple.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Now") == null);
}

test "Scenario: Given remaining table width when rendering then status plan and last expand before account becomes complete" {
    var rows = [_]SwitchRow{
        testRow("very-long-account-name@example.com", "Business", "100%", "42%", "Now"),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderListScreenViewport(&writer, &reg, &rows, 2, .{
        .email = 32,
        .plan = 8,
        .rate_5h = 4,
        .rate_week = 6,
        .last = 4,
    }, false, "", .{
        .start_row = 0,
        .max_rows = 1,
        .max_cols = 50,
    });

    const output = writer.buffered();
    try expectLinesWithin(output, 50);
    try std.testing.expect(std.mem.indexOf(u8, output, "very-l.mple.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Now") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "very-long-account-name@example.com") == null);
}

test "Scenario: Given an alias-sized account label when rendering a narrow table then the alias remains complete" {
    var rows = [_]SwitchRow{
        testRow("work-main", "Business", "31%", "42%", "Now"),
    };
    var reg = makeTestRegistry();
    defer reg.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try renderListScreenViewport(&writer, &reg, &rows, 2, .{
        .email = 9,
        .plan = 8,
        .rate_5h = 4,
        .rate_week = 6,
        .last = 4,
    }, false, "", .{
        .start_row = 0,
        .max_rows = 1,
        .max_cols = 33,
    });

    const output = writer.buffered();
    try expectLinesWithin(output, 33);
    try std.testing.expect(std.mem.indexOf(u8, output, "work-main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "31%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "42%") != null);
}

const table_format = codex_auth.tui.table;

fn appendListAccount(allocator: std.mem.Allocator, reg: *registry.Registry, email: []const u8) !void {
    const sep = std.mem.indexOf(u8, email, "@").?;
    const record_key = try std.fmt.allocPrint(allocator, "user-{s}::{s}", .{ email[0..sep], email[sep + 1 ..] });
    defer allocator.free(record_key);
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, email[sep + 1 ..]),
        .chatgpt_user_id = try allocator.dupe(u8, email[0..sep]),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, email[0..sep]),
        .account_name = null,
        .plan = .pro,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = .{
            .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = 4102444800 },
            .secondary = .{ .used_percent = 42, .window_minutes = 10080, .resets_at = 4103049600 },
            .credits = null,
            .plan_type = .pro,
        },
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn hasDotOnlyCell(line: []const u8) bool {
    for (line, 0..) |ch, index| {
        if (ch != '.') continue;
        const before_is_space = index == 0 or line[index - 1] == ' ';
        const after_is_space = index + 1 == line.len or line[index + 1] == ' ';
        if (before_is_space and after_is_space) return true;
    }
    return false;
}

test "Scenario: Given widths from 5 to 130 when rendering the plain list then lines fit and no cell is only a dot" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendListAccount(gpa, &reg, "very-long-account-name@example.com");

    var width: usize = 5;
    while (width <= 130) : (width += 1) {
        var buffer: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, width);
        const output = writer.buffered();
        try expectLinesWithin(output, width);

        var header: []const u8 = "";
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (header.len == 0) header = line;
            try std.testing.expect(!hasDotOnlyCell(line));
        }
        if (std.mem.indexOf(u8, header, "5H") != null) {
            try std.testing.expect(std.mem.indexOf(u8, output, "100%") != null);
        }
    }
}

test "Scenario: Given a FileNotFound override and a long account when rendering at 70 columns then the override stays readable" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendListAccount(gpa, &reg, "very-long-account-name@example.com");

    var overrides = [_]?[]const u8{"FileNotFound"};
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, &overrides, 70);
    const output = writer.buffered();
    try expectLinesWithin(output, 70);
    try std.testing.expect(std.mem.indexOf(u8, output, "FileNotFound") != null);
}

test "Scenario: Given compact list widths when rendering then headers use CR, RC and RESET fallbacks" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendListAccount(gpa, &reg, "very-long-account-name@example.com");

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 40);
    var output = writer.buffered();
    try expectLinesWithin(output, 40);
    try std.testing.expect(std.mem.indexOf(u8, output, "PLAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RC") != null);

    buffer = undefined;
    writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 46);
    output = writer.buffered();
    try expectLinesWithin(output, 46);
    try std.testing.expect(std.mem.indexOf(u8, output, "RC") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET CREDITS") == null);

    reg.accounts.items[0].last_usage = null;
    buffer = undefined;
    writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 60);
    output = writer.buffered();
    try expectLinesWithin(output, 60);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET") != null);
}

test "Scenario: Given unlimited credits when rendering at 120 columns then the value is not collapsed to u." {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendListAccount(gpa, &reg, "work-main@example.com");
    reg.accounts.items[0].last_usage.?.credits = .{
        .has_credits = true,
        .unlimited = true,
        .balance = null,
    };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 120);
    const output = writer.buffered();
    try expectLinesWithin(output, 120);
    try std.testing.expect(std.mem.indexOf(u8, output, "unlimited") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "u.") == null);
}

test "Scenario: Given low-priority metadata when narrowing then LAST hides before CREDITS" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendListAccount(gpa, &reg, "very-long-account-name@example.com");
    reg.accounts.items[0].last_usage.?.credits = .{
        .has_credits = true,
        .unlimited = true,
        .balance = null,
    };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table_format.writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 48);
    const output = writer.buffered();
    try expectLinesWithin(output, 48);
    try std.testing.expect(std.mem.indexOf(u8, output, "LAST") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CR") != null);
}

test "plain and live views keep shared columns in the same relative order" {
    const table_layout = cli.table_layout;
    var previous: ?usize = null;
    for (table_layout.list_detail_columns) |id| {
        if (id == .number) continue;
        const position = std.mem.indexOfScalar(table_layout.ColumnId, &table_layout.plain_columns, id) orelse
            return error.TestUnexpectedResult;
        if (previous) |prev| try std.testing.expect(position > prev);
        previous = position;
    }
}
