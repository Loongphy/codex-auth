const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");

const base_headers = [_][]const u8{ "#*", "ACCOUNT", "PLAN", "5H", "WEEKLY", "LAST", "ACCESS EXPIRE", "RESET CREDITS" };
const base_desired_widths = [_]usize{ 2, 18, 8, 12, 12, 10, 16, 14 };
const base_minimum_widths = [_]usize{ 1, 8, 4, 4, 6, 5, 10, 8 };
const base_column_count = base_headers.len;
const separator_width: usize = 3;

pub fn writeHeader(writer: *style.StyledWriter, number_width: usize, max_cols: ?usize) !void {
    const visible_base = visibleBaseColumns(max_cols, number_width);
    var values: [base_column_count][]const u8 = undefined;
    var widths: [base_column_count]usize = undefined;
    var minimums: [base_column_count]usize = undefined;
    var count: usize = 0;
    for (base_headers, 0..) |value, index| {
        if (!visible_base[index]) continue;
        values[count] = value;
        widths[count] = if (index == 0) number_width else base_desired_widths[index];
        minimums[count] = if (index == 0) number_width else base_minimum_widths[index];
        count += 1;
    }
    try writeAlignedRow(writer, values[0..count], widths[0..count], minimums[0..count], max_cols, false, style.role.status, true);
}

pub fn write(
    allocator: std.mem.Allocator,
    writer: *style.StyledWriter,
    account: registry.AccountRecord,
    row: anytype,
    number_width: usize,
    max_cols: ?usize,
) !void {
    const visible_base = visibleBaseColumns(max_cols, number_width);
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.access_token_expires_at);
    defer allocator.free(token_expiry);
    const reset_credits_cell = try resetCreditsCell(allocator, account);
    defer allocator.free(reset_credits_cell);

    const number = row.number;
    var values: [base_column_count][]const u8 = undefined;
    var widths: [base_column_count]usize = undefined;
    var minimums: [base_column_count]usize = undefined;
    var count: usize = 0;
    const base_values = [_][]const u8{ number, row.account, row.plan, row.rate_5h, row.rate_week, row.last, token_expiry, reset_credits_cell };
    for (base_values, 0..) |value, index| {
        if (!visible_base[index]) continue;
        values[count] = value;
        widths[count] = if (index == 0) number_width else base_desired_widths[index];
        minimums[count] = if (index == 0) number_width else base_minimum_widths[index];
        count += 1;
    }
    const row_style = if (number.len != 0 and number[0] == '!') style.role.error_text else if (number.len != 0 and number[0] == '*') style.role.success else "";
    try writeAlignedRow(writer, values[0..count], widths[0..count], minimums[0..count], max_cols, true, row_style, false);
}

/// `N` from the persisted `reset_credits` count, plus the earliest expiry among
/// the available cards in local `MMM-DD` form (omitted when unknown).
fn resetCreditsCell(allocator: std.mem.Allocator, account: registry.AccountRecord) ![]u8 {
    const usage = account.last_usage orelse return std.fmt.allocPrint(allocator, "-", .{});
    const count = usage.reset_credits orelse return std.fmt.allocPrint(allocator, "-", .{});
    var earliest: ?i64 = null;
    if (usage.reset_credit) |cards| {
        for (cards) |card| {
            if (!std.mem.eql(u8, card.status, "available")) continue;
            if (parseIsoEpoch(card.expires_at orelse "")) |epoch| {
                if (earliest == null or epoch < earliest.?) earliest = epoch;
            }
        }
    }
    if (earliest) |epoch| {
        const local = try rows.formatTimestampAlloc(allocator, epoch);
        defer allocator.free(local);
        if (local.len >= 10) return std.fmt.allocPrint(allocator, "{d} (exp {s})", .{ count, local[5..10] });
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

fn visibleBaseColumns(max_cols: ?usize, number_width: usize) [base_column_count]bool {
    var visible: [base_column_count]bool = undefined;
    for (&visible) |*value| value.* = true;
    const limit = max_cols orelse return visible;
    const drop_order = [_]usize{ 7, 6, 5, 2 };
    while (minimumTableWidth(visible, number_width) > limit) {
        var changed = false;
        for (drop_order) |index| {
            if (visible[index]) {
                visible[index] = false;
                changed = true;
                break;
            }
        }
        if (!changed) break;
    }
    return visible;
}

fn minimumTableWidth(visible: [base_column_count]bool, number_width: usize) usize {
    var total: usize = 0;
    var column_count: usize = 0;
    for (base_minimum_widths, 0..) |width, index| {
        if (!visible[index]) continue;
        total += if (index == 0) @max(width, number_width) else width;
        column_count += 1;
    }
    return if (column_count == 0) 0 else total + (column_count - 1) * separator_width;
}

fn writeAlignedRow(
    writer: *style.StyledWriter,
    values: []const []const u8,
    desired: []const usize,
    minimums: []const usize,
    max_cols: ?usize,
    account_column: bool,
    row_style: []const u8,
    header: bool,
) !void {
    var widths: [base_column_count]usize = undefined;
    for (desired, 0..) |width, index| widths[index] = width;
    if (max_cols) |limit| {
        var total = minimumForWidths(widths[0..values.len]);
        while (total > limit) {
            var changed = false;
            var index = values.len;
            while (index > 0) {
                index -= 1;
                if (widths[index] > minimums[index]) {
                    widths[index] -= 1;
                    total -= 1;
                    changed = true;
                    break;
                }
            }
            if (changed) continue;

            // If the required columns still do not fit, keep the frame inside
            // the terminal rather than allowing a hard wrap.
            for (widths[0..values.len]) |*width| {
                if (total <= limit) break;
                if (width.* > 1) {
                    width.* -= 1;
                    total -= 1;
                }
            }
            if (total > limit) break;
        }
    }
    try writer.writeStyle(row_style);
    for (values, 0..) |value, index| {
        if (index != 0) {
            if (!header and row_style.len == 0) try writer.writeStyle(style.role.secondary);
            try writer.writeAll(" | ");
            if (!header and row_style.len == 0) try writer.reset();
            try writer.writeStyle(row_style);
        }
        if (account_column and index == 1) {
            try table_layout.writeAccountTruncatedPadded(writer.out, value, widths[index]);
        } else {
            try table_layout.writeTruncatedPadded(writer.out, value, widths[index]);
        }
    }
    try writer.reset();
    try writer.writeAll("\n");
}

fn minimumForWidths(widths: []const usize) usize {
    var total: usize = 0;
    for (widths) |width| total += width;
    return total + (widths.len - 1) * separator_width;
}

/// Minimal ISO-8601 parser for the backend shape `YYYY-MM-DDTHH:MM:SS` with an
/// optional trailing zone (`Z` or `±HH:MM`). Returns epoch seconds, or null.
fn parseIsoEpoch(value: []const u8) ?i64 {
    if (value.len < 19 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':') return null;
    const year = std.fmt.parseInt(i64, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, value[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, value[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var epoch = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
    if (value.len > 19) {
        const zone_marker = value[19];
        if (zone_marker == '+' or zone_marker == '-') {
            if (value.len >= 25 and value[22] == ':') {
                const zone_hour = std.fmt.parseInt(i64, value[20..22], 10) catch 0;
                const zone_minute = std.fmt.parseInt(i64, value[23..25], 10) catch 0;
                const offset = zone_hour * 3600 + zone_minute * 60;
                epoch += if (zone_marker == '+') -offset else offset;
            }
        }
    }
    return epoch;
}

/// Howard Hinnant's days_from_civil algorithm.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}
