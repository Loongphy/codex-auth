const std = @import("std");
const codex_auth = @import("codex_auth");

const cli = codex_auth.cli;
const registry = codex_auth.registry;

const renderListScreenViewport = cli.render.renderListScreenViewport;
const SwitchRow = cli.rows.SwitchRow;

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
    try std.testing.expect(std.mem.indexOf(u8, output, "very-l.com") != null);
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
