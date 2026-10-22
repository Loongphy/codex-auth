const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const text_width = @import("../tui/text_width.zig");

const available_status = "available";
const separator_width: usize = 3;
const column_count = table_layout.list_detail_columns.len;

pub fn computeWidths(
    number_width: usize,
    widths: rows.SwitchWidths,
    max_cols: ?usize,
) [column_count]usize {
    const columns = [_]table_layout.ColumnSpec{
        .{
            .id = .number,
            .content_width = @max(number_width, "#*".len),
            .target_width = @max(number_width, "#*".len),
            .min_width = @max(number_width, "#*".len),
        },
        table_layout.columnSpec(.account, @max(widths.email, "ACCOUNT".len)),
        table_layout.columnSpec(.plan, @max(widths.plan, "PLAN".len)),
        table_layout.columnSpec(.rate_5h, @max(widths.rate_5h, "5H".len)),
        table_layout.columnSpec(.rate_week, @max(widths.rate_week, "WEEKLY".len)),
        table_layout.columnSpec(.last, @max(widths.last, "LAST".len)),
        table_layout.columnSpec(.auth_expire, @max("AUTH EXPIRE".len, 16)),
        table_layout.columnSpec(.reset_credits, @max("RESET CREDITS".len, 14)),
    };
    var bounded = [_]usize{0} ** column_count;
    table_layout.allocateColumns(.{
        .columns = &columns,
        .first_order = &table_layout.list_detail_first_order,
        .grow_order = &table_layout.list_detail_grow_order,
        .prefix_width = 0,
        .separator_width = separator_width,
    }, max_cols, &bounded);
    return bounded;
}

pub fn writeHeader(writer: *style.StyledWriter, widths: [column_count]usize) !void {
    try writer.writeStyle(style.role.status);
    var wrote_any = false;
    for (table_layout.list_detail_columns, 0..) |id, index| {
        if (widths[index] == 0) continue;
        if (wrote_any) try writer.out.writeAll(" | ");
        wrote_any = true;
        try table_layout.writeTruncatedPadded(writer.out, headerFor(id, widths[index]), widths[index]);
    }
    try writer.reset();
    try writer.out.writeByte('\n');
}

pub fn write(
    allocator: std.mem.Allocator,
    writer: *style.StyledWriter,
    account: registry.AccountRecord,
    row: anytype,
    widths: [column_count]usize,
) !void {
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.access_token_expires_at);
    defer allocator.free(token_expiry);
    const reset_full = try resetCreditsCell(allocator, account);
    defer allocator.free(reset_full);
    const reset_short = shortResetCell(reset_full);

    const values = [_][]const u8{
        row.number,
        row.account,
        row.plan,
        row.rate_5h,
        row.rate_week,
        row.last,
        token_expiry,
        reset_full,
    };
    const row_style = if (row.number.len != 0 and row.number[0] == '!') style.role.error_text else if (row.number.len != 0 and row.number[0] == '*') style.role.success else "";
    try writer.writeStyle(row_style);
    var wrote_any = false;
    for (table_layout.list_detail_columns, 0..) |id, index| {
        if (widths[index] == 0) continue;
        if (wrote_any) {
            if (row_style.len == 0) try writer.writeStyle(style.role.secondary);
            try writer.out.writeAll(" | ");
            if (row_style.len == 0) try writer.reset();
            try writer.writeStyle(row_style);
        }
        wrote_any = true;
        switch (id) {
            .account => try table_layout.writeAccountTruncatedPadded(writer.out, values[index], widths[index]),
            .rate_5h, .rate_week => try writeUsageCell(writer.out, values[index], widths[index]),
            .reset_credits => try writeResetCell(writer.out, reset_full, reset_short, widths[index]),
            else => try table_layout.writeTruncatedPadded(writer.out, values[index], widths[index]),
        }
    }
    try writer.reset();
    try writer.out.writeByte('\n');
}

fn headerFor(id: table_layout.ColumnId, width: usize) []const u8 {
    return switch (id) {
        .number => "#*",
        .account => "ACCOUNT",
        .plan => "PLAN",
        .credits => "CREDITS",
        .reset_credits => if (width >= "RESET CREDITS".len) "RESET CREDITS" else if (width >= "RESET".len) "RESET" else if (width >= "RC".len) "RC" else "R",
        .rate_5h => "5H",
        .rate_week => "WEEKLY",
        .last => "LAST",
        .auth_expire => if (width >= "AUTH EXPIRE".len) "AUTH EXPIRE" else if (width >= "AUTH EXP".len) "AUTH EXP" else if (width >= "AUTH".len) "AUTH" else "AE"[0..@min(width, "AE".len)],
    };
}

fn writeUsageCell(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (std.mem.indexOfScalar(u8, value, '%')) |percent| {
        const short = value[0 .. percent + 1];
        if (text_width.displayWidth(value) > width and text_width.displayWidth(short) <= width) {
            try table_layout.writeTruncatedPadded(out, short, width);
            return;
        }
    }
    try table_layout.writeTruncatedPadded(out, value, width);
}

fn writeResetCell(out: *std.Io.Writer, full: []const u8, short: []const u8, width: usize) !void {
    if (text_width.displayWidth(full) > width and width < 5 and text_width.displayWidth(short) <= width) {
        try table_layout.writeTruncatedPadded(out, short, width);
        return;
    }
    try table_layout.writeTruncatedPadded(out, full, width);
}

fn shortResetCell(full: []const u8) []const u8 {
    if (std.mem.indexOf(u8, full, " (")) |index| return full[0..index];
    return full;
}

/// `N` from the persisted `reset_credits` count, plus the earliest expiry among
/// the available cards in local `MMM-DD` form (omitted when unknown).
fn resetCreditsCell(allocator: std.mem.Allocator, account: registry.AccountRecord) ![]u8 {
    const usage = account.last_usage orelse return std.fmt.allocPrint(allocator, "-", .{});
    // Count: the summary's available_count when present; otherwise derived
    // from the persisted cards (status == available) — the same backend number.
    var count: ?i64 = usage.reset_credits;
    if (count == null) {
        if (usage.reset_credit) |cards| {
            var derived: i64 = 0;
            for (cards) |card| {
                if (std.mem.eql(u8, card.status, available_status)) derived += 1;
            }
            count = derived;
        }
    }
    const value = count orelse return std.fmt.allocPrint(allocator, "-", .{});
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
        if (local.len >= 10) return std.fmt.allocPrint(allocator, "{d} (exp {s})", .{ value, local[5..10] });
    }
    return std.fmt.allocPrint(allocator, "{d} (-)", .{value});
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
