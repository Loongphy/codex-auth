const std = @import("std");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const text_width = @import("../tui/text_width.zig");
const timestamp = @import("../time/timestamp.zig");
const app_runtime = @import("../core/runtime.zig");

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
        table_layout.columnSpec(.plan_expire, @max("PLAN EXPIRE".len, 10)),
        table_layout.columnSpec(.reset_credits, @max("RESET CREDITS".len, 14)),
        table_layout.columnSpec(.rate_5h, @max(widths.rate_5h, "5H".len)),
        table_layout.columnSpec(.rate_week, @max(widths.rate_week, "WEEKLY".len)),
        table_layout.columnSpec(.auth_expire, @max("AUTH EXPIRE".len, 16)),
        table_layout.columnSpec(.last, @max(widths.last, "LAST ACTIVITY".len)),
    };
    var bounded = [_]usize{0} ** column_count;
    table_layout.allocateColumns(.{
        .columns = &columns,
        .first_order = &table_layout.shared_first_order,
        .grow_order = &table_layout.shared_grow_order,
        .deferred_order = &table_layout.shared_deferred_order,
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
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.access_token_expires_at);
    defer allocator.free(token_expiry);
    const plan_expiry = try rows.formatFutureDateAlloc(allocator, account.plan_expires_at, now);
    defer allocator.free(plan_expiry);
    const reset_full = try resetCreditsCell(allocator, account);
    defer allocator.free(reset_full);
    const reset_short = shortResetCell(reset_full);

    const values = [_][]const u8{
        row.number,
        row.account,
        row.plan,
        plan_expiry,
        reset_full,
        row.rate_5h,
        row.rate_week,
        token_expiry,
        row.last,
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
        .last => if (width >= "LAST ACTIVITY".len) "LAST ACTIVITY" else "LAST",
        .auth_expire => if (width >= "AUTH EXPIRE".len) "AUTH EXPIRE" else if (width >= "AUTH EXP".len) "AUTH EXP" else if (width >= "AUTH".len) "AUTH" else "AE"[0..@min(width, "AE".len)],
        .plan_expire => if (width >= "PLAN EXPIRE".len) "PLAN EXPIRE" else if (width >= "PLAN EXP".len) "PLAN EXP" else if (width >= "PLAN".len) "PLAN" else "PE"[0..@min(width, "PE".len)],
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
    if (value == 0) return std.fmt.allocPrint(allocator, "0", .{});
    var earliest: ?i64 = null;
    if (usage.reset_credit) |cards| {
        for (cards) |card| {
            if (!std.mem.eql(u8, card.status, "available")) continue;
            if (timestamp.parseIso8601(card.expires_at orelse "")) |epoch| {
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
