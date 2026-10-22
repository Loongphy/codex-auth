const std = @import("std");
const codex_auth = @import("codex_auth");

const app_runtime = codex_auth.core.runtime;
const format = codex_auth.tui.table;
const registry = codex_auth.registry;
const printTableRow = format.printTableRow;
const truncateAlloc = format.truncateAlloc;
const formatRateLimitFullAlloc = format.formatRateLimitFullAlloc;
const writeAccountsTable = format.writeAccountsTable;
const writeAccountsTableWithUsageOverrides = format.writeAccountsTableWithUsageOverrides;
const writeAccountsTableWithUsageOverridesForCols = format.writeAccountsTableWithUsageOverridesForCols;
const ansi = struct {
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

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

fn appendApiKeyTestAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    account_key: []const u8,
    email: []const u8,
) !void {
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, account_key),
        .chatgpt_account_id = try allocator.dupe(u8, ""),
        .chatgpt_user_id = try allocator.dupe(u8, "user_api"),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, ""),
        .account_name = null,
        .plan = null,
        .auth_mode = .apikey,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

test "printTableRow handles long cells without underflow" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const widths = [_]usize{3};
    const cells = [_][]const u8{"abcdef"};
    try printTableRow(&writer, &widths, &cells);
    try writer.flush();
}

test "truncateAlloc respects max_len" {
    const out1 = try truncateAlloc("abcdef", 3);
    defer std.heap.page_allocator.free(out1);
    try std.testing.expect(out1.len == 3);
    const out2 = try truncateAlloc("abcdef", 1);
    defer std.heap.page_allocator.free(out2);
    try std.testing.expect(out2.len == 1);
}

test "truncateAlloc preserves UTF-8 codepoint boundaries" {
    const out = try truncateAlloc("Рабочая область", 5);
    defer std.heap.page_allocator.free(out);
    try std.testing.expectEqualStrings("Рабо.", out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "formatRateLimitFullAlloc shows 100% after reset instead of dash-prefixed value" {
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const window = registry.RateLimitWindow{
        .used_percent = 100.0,
        .window_minutes = 300,
        .resets_at = now - 60,
    };

    const formatted = try formatRateLimitFullAlloc(window);
    defer std.heap.page_allocator.free(formatted);

    try std.testing.expectEqualStrings("100%", formatted);
}

test "writeAccountsTable shows zero-padded row numbers for selectable accounts" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Als's Workspace");
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "01   Als's Workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "02   Free") != null);
}

test "writeAccountsTable keeps usage headers short" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "5H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "WEEKLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "USAGE") == null);
}

test "writeAccountsTable shows integer credits balance column" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = .{
            .has_credits = true,
            .unlimited = false,
            .balance = try gpa.dupe(u8, "5.3900"),
        },
        .reset_credits = 2,
        .plan_type = .plus,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus  5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "5.39") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
}

test "writeAccountsTable shows reset credits independently" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);
    reg.accounts.items[0].last_usage = .{
        .primary = null,
        .secondary = null,
        .credits = null,
        .reset_credits = 2,
        .plan_type = .plus,
    };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "RESET CREDITS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus  -") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2") != null);
}

test "writeAccountsTable shows usage override statuses for failed refreshes" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, false, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.count(u8, output, "403") >= 3);
}

test "writeAccountsTable highlights usage override rows in red when color is enabled" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "user@example.com", "", .free);

    const usage_overrides = [_]?[]const u8{ null, "403" };

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverrides(&writer, &reg, true, &usage_overrides);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.red) != null);
}

test "writeAccountsTable uses cyan headers green active rows and default normal rows" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendTestAccount(gpa, &reg, "user-1::acc-1", "active@example.com", "", .business);
    try appendTestAccount(gpa, &reg, "user-1::acc-2", "normal@example.com", "", .free);
    reg.active_account_key = try gpa.dupe(u8, "user-1::acc-1");

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, true);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.cyan ++ "     ACCOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ansi.green ++ "* 01 active@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2m  02 normal@example.com") == null);
}

test "writeAccountsTable prefers usage snapshot plan labels over stored auth plan" {
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

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Business") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Plus") == null);
}

test "writeAccountsTable shows API_KEY in the plan column for API key auth" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);

    try appendApiKeyTestAccount(gpa, &reg, "apikey::user_api::7f3c1d9a2b4e8c2042ce", "user@example.com");

    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTable(&writer, &reg, false);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "API_KEY") != null);
}

fn appendTestAccountWithUsage(allocator: std.mem.Allocator, reg: *registry.Registry, email: []const u8) !void {
    const sep = std.mem.indexOf(u8, email, "@").?;
    const record_key = try std.fmt.allocPrint(allocator, "user-{s}::{s}", .{ email[0..sep], email[sep + 1 ..] });
    defer allocator.free(record_key);
    try appendTestAccount(allocator, reg, record_key, email, email[0..sep], .pro);
    reg.accounts.items[reg.accounts.items.len - 1].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = 1800000000 },
        .secondary = .{ .used_percent = 42, .window_minutes = 10080, .resets_at = 1799000000 },
        .credits = null,
        .plan_type = .pro,
    };
}

test "writeAccountsTableForCols: wide terminal keeps full headers and complete values" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccountWithUsage(gpa, &reg, "very-long-account-name@example.com");
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 200);
    const output = writer.buffered();
    for ([_][]const u8{ "ACCOUNT", "PLAN", "CREDITS", "RESET CREDITS", "5H", "WEEKLY", "LAST ACTIVITY", "100%" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "  .") == null);
    }
}

test "writeAccountsTableForCols: narrow terminal never overflows and keeps percentages" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccountWithUsage(gpa, &reg, "very-long-account-name@example.com");
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 60);
    const output = writer.buffered();
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 60);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CR") != null or std.mem.indexOf(u8, output, "CREDITS") != null);
}

test "writeAccountsTableForCols: very narrow terminal hides low-priority columns" {
    const gpa = std.testing.allocator;
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccountWithUsage(gpa, &reg, "very-long-account-name@example.com");
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 40);
    const output = writer.buffered();
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 40);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "100%") != null);
}

test "formatFutureDateAlloc renders only future dates" {
    const allocator = std.testing.allocator;
    const now: i64 = 1_800_000_000;

    const missing = try codex_auth.cli.rows.formatFutureDateAlloc(allocator, null, now);
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("-", missing);

    const expired = try codex_auth.cli.rows.formatFutureDateAlloc(allocator, now - 1, now);
    defer allocator.free(expired);
    try std.testing.expectEqualStrings("-", expired);

    const boundary = try codex_auth.cli.rows.formatFutureDateAlloc(allocator, now, now);
    defer allocator.free(boundary);
    try std.testing.expectEqualStrings("-", boundary);

    const future = try codex_auth.cli.rows.formatFutureDateAlloc(allocator, now + 86400, now);
    defer allocator.free(future);
    try std.testing.expectEqual(@as(usize, 10), future.len);
    try std.testing.expectEqual(@as(u8, '-'), future[4]);
    try std.testing.expectEqual(@as(u8, '-'), future[7]);
}

test "writeAccountsTable shows plan expiry for future data and hides expired data" {
    const gpa = std.testing.allocator;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user-1::acc-1", "user@example.com", "", .plus);

    reg.accounts.items[0].plan_expires_at = now + 30 * 86400;
    const expected = try codex_auth.cli.rows.formatFutureDateAlloc(gpa, reg.accounts.items[0].plan_expires_at, now);
    defer gpa.free(expected);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 200);
    var output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "PLAN EXPIRE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);

    const expired_at = now - 30 * 86400;
    const expired_text = try codex_auth.cli.rows.formatTimestampAlloc(gpa, expired_at);
    defer gpa.free(expired_text);
    reg.accounts.items[0].plan_expires_at = expired_at;

    buffer = undefined;
    writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, null, 200);
    output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "PLAN EXPIRE") != null);
    if (expired_text.len >= 10) {
        try std.testing.expect(std.mem.indexOf(u8, output, expired_text[0..10]) == null);
    }
}

test "writeAccountsTable defers PLAN EXPIRE on narrow widths" {
    const gpa = std.testing.allocator;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    var reg = makeTestRegistry();
    defer reg.deinit(gpa);
    try appendTestAccount(gpa, &reg, "user-1::acc-1", "very-long-account-name@example.com", "very-long-account-name", .plus);
    reg.accounts.items[0].plan_expires_at = now + 30 * 86400;
    reg.accounts.items[0].last_usage = .{
        .primary = .{ .used_percent = 0, .window_minutes = 300, .resets_at = now + 3600 },
        .secondary = .{ .used_percent = 42, .window_minutes = 10080, .resets_at = now + 604800 },
        .credits = null,
        .plan_type = .plus,
    };

    var overrides = [_]?[]const u8{"FileNotFound"};
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, &overrides, 70);
    var output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "PLAN EXPIRE") == null);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 70);

    const expected = try codex_auth.cli.rows.formatFutureDateAlloc(gpa, reg.accounts.items[0].plan_expires_at, now);
    defer gpa.free(expected);
    buffer = undefined;
    writer = .fixed(&buffer);
    try writeAccountsTableWithUsageOverridesForCols(&writer, &reg, false, &overrides, 200);
    output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "PLAN EXPIRE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, expected) != null);
    lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 200);
}
