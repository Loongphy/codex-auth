const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const registry = @import("../registry/root.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");
const timestamp = @import("../time/timestamp.zig");

const base_headers = [_][]const u8{ "#*", "ACCOUNT", "PLAN", "PLAN EXPIRE", "5H", "WEEKLY", "LAST", "AUTH EXPIRE", "RESET CREDITS" };
const base_desired_widths = [_]usize{ 2, 18, 8, 11, 12, 12, 10, 16, 14 };
const base_minimum_widths = [_]usize{ 1, 8, 4, 8, 4, 6, 5, 10, 8 };
const base_column_count = base_headers.len;
const available_status = "available";
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
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.access_token_expires_at);
    defer allocator.free(token_expiry);
    const plan_expiry = try rows.formatFutureDateAlloc(allocator, account.plan_expires_at, now);
    defer allocator.free(plan_expiry);
    const reset_credits_cell = try resetCreditsCell(allocator, account);
    defer allocator.free(reset_credits_cell);

    const number = row.number;
    var values: [base_column_count][]const u8 = undefined;
    var widths: [base_column_count]usize = undefined;
    var minimums: [base_column_count]usize = undefined;
    var count: usize = 0;
    const base_values = [_][]const u8{ number, row.account, row.plan, plan_expiry, row.rate_5h, row.rate_week, row.last, token_expiry, reset_credits_cell };
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
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn visibleBaseColumns(max_cols: ?usize, number_width: usize) [base_column_count]bool {
    var visible: [base_column_count]bool = undefined;
    for (&visible) |*value| value.* = true;
    const limit = max_cols orelse return visible;
    const drop_order = [_]usize{ 8, 7, 6, 3, 5, 2 };
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
