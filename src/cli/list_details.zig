const std = @import("std");
const registry = @import("../registry/root.zig");
const app_runtime = @import("../core/runtime.zig");
const rows = @import("rows.zig");
const style = @import("style.zig");
const table_layout = @import("table_layout.zig");

const max_columns = 64;
const base_headers = [_][]const u8{ "#*", "ACCOUNT", "PLAN", "5H", "WEEKLY", "NEXT RESET LOCAL", "LAST", "ACCESS EXP LOCAL" };
const base_desired_widths = [_]usize{ 2, 18, 8, 12, 12, 16, 10, 16 };
const base_minimum_widths = [_]usize{ 1, 8, 4, 4, 6, 10, 5, 10 };
const base_column_count = base_headers.len;
const credit_width: usize = 23;
const separator_width: usize = 3;

pub fn writeHeader(writer: *style.StyledWriter, reg: *const registry.Registry, number_width: usize, max_cols: ?usize) !void {
    const visible_base = visibleBaseColumns(max_cols, number_width);
    const card_count = visibleCardCount(maxCardCount(reg), max_cols, visible_base, number_width);
    var values: [max_columns][]const u8 = undefined;
    var widths: [max_columns]usize = undefined;
    var minimums: [max_columns]usize = undefined;
    var count: usize = 0;
    for (base_headers, 0..) |value, index| {
        if (!visible_base[index]) continue;
        values[count] = value;
        widths[count] = if (index == 0) number_width else base_desired_widths[index];
        minimums[count] = if (index == 0) number_width else base_minimum_widths[index];
        count += 1;
    }
    var labels: [max_columns][16]u8 = undefined;
    for (0..card_count) |index| {
        const label = std.fmt.bufPrint(&labels[index], "C{d} EXP", .{index + 1}) catch "C EXP";
        values[count] = label;
        widths[count] = credit_width;
        minimums[count] = credit_width;
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
    max_cards: usize,
    max_cols: ?usize,
) !void {
    const visible_base = visibleBaseColumns(max_cols, number_width);
    const card_count = visibleCardCount(max_cards, max_cols, visible_base, number_width);
    const next_reset = try nextResetText(allocator, account.last_usage);
    defer allocator.free(next_reset);
    const token_expiry = try rows.formatTimestampAlloc(allocator, account.auth_expires_at);
    defer allocator.free(token_expiry);

    const number = row.number;
    var values: [max_columns][]const u8 = undefined;
    var widths: [max_columns]usize = undefined;
    var minimums: [max_columns]usize = undefined;
    var owned_expiries: [max_columns][]u8 = undefined;
    var owned_expiry_count: usize = 0;
    defer for (owned_expiries[0..owned_expiry_count]) |expiry| allocator.free(expiry);
    var count: usize = 0;
    const base_values = [_][]const u8{ number, row.account, row.plan, row.rate_5h, row.rate_week, next_reset, row.last, token_expiry };
    for (base_values, 0..) |value, index| {
        if (!visible_base[index]) continue;
        values[count] = value;
        widths[count] = if (index == 0) number_width else base_desired_widths[index];
        minimums[count] = if (index == 0) number_width else base_minimum_widths[index];
        count += 1;
    }
    for (0..card_count) |index| {
        const expiry = try creditExpiryAlloc(allocator, account.last_usage, index);
        owned_expiries[owned_expiry_count] = expiry;
        owned_expiry_count += 1;
        values[count] = expiry;
        widths[count] = credit_width;
        minimums[count] = credit_width;
        count += 1;
    }
    const row_style = if (number.len != 0 and number[0] == '!') style.role.error_text else if (number.len != 0 and number[0] == '*') style.role.success else "";
    try writeAlignedRow(writer, values[0..count], widths[0..count], minimums[0..count], max_cols, true, row_style, false);
}

fn maxCardCount(reg: *const registry.Registry) usize {
    var result: usize = 0;
    for (reg.accounts.items) |account| {
        if (account.last_usage) |usage| {
            if (usage.reset_credit_details) |details| result = @max(result, details.credits.len);
        }
    }
    return result;
}

fn visibleBaseColumns(max_cols: ?usize, number_width: usize) [base_column_count]bool {
    var visible: [base_column_count]bool = undefined;
    for (&visible) |*value| value.* = true;
    const limit = max_cols orelse return visible;
    const drop_order = [_]usize{ 7, 6, 5, 2 };
    while (minimumTableWidth(visible, 0, number_width) > limit) {
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

fn visibleCardCount(max_cards: usize, max_cols: ?usize, visible_base: [base_column_count]bool, number_width: usize) usize {
    var count = @min(max_cards, max_columns - base_column_count);
    const limit = max_cols orelse return count;
    while (count > 0 and minimumTableWidth(visible_base, count, number_width) > limit) : (count -= 1) {}
    return count;
}

fn minimumTableWidth(visible_base: [base_column_count]bool, card_count: usize, number_width: usize) usize {
    var total: usize = 0;
    var column_count: usize = 0;
    for (base_minimum_widths, 0..) |width, index| {
        if (!visible_base[index]) continue;
        total += if (index == 0) @max(width, number_width) else width;
        column_count += 1;
    }
    total += card_count * credit_width;
    column_count += card_count;
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
    var widths: [max_columns]usize = undefined;
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

fn nextResetText(allocator: std.mem.Allocator, snapshot: ?registry.RateLimitSnapshot) ![]u8 {
    var next: ?i64 = null;
    const now = std.Io.Timestamp.now(app_runtime.io(), .real).toSeconds();
    if (snapshot) |usage| {
        for ([_]?registry.RateLimitWindow{ usage.primary, usage.secondary }) |maybe_window| {
            const window = maybe_window orelse continue;
            const timestamp = window.resets_at orelse continue;
            if (timestamp <= now) continue;
            if (next == null or timestamp < next.?) next = timestamp;
        }
    }
    return rows.formatTimestampAlloc(allocator, next);
}

fn creditExpiryAlloc(allocator: std.mem.Allocator, snapshot: ?registry.RateLimitSnapshot, index: usize) ![]u8 {
    const usage = snapshot orelse return allocator.dupe(u8, "-");
    const details = usage.reset_credit_details orelse return allocator.dupe(u8, "-");
    if (index >= details.credits.len) return allocator.dupe(u8, "-");
    const expiry = details.credits[index].expires_at orelse return allocator.dupe(u8, "-");
    if (expiry.len < 19 or expiry[10] != 'T') return std.fmt.allocPrint(allocator, "{s} TZ?", .{expiry});

    var date_time: [19]u8 = undefined;
    @memcpy(&date_time, expiry[0..19]);
    date_time[10] = ' ';

    var zone: []const u8 = "TZ?";
    if (expiry.len > 19) {
        if (expiry[expiry.len - 1] == 'Z' or expiry[expiry.len - 1] == 'z') {
            zone = "UTC";
        } else {
            var offset_start: ?usize = null;
            for (expiry[19..], 19..) |value, offset| {
                if (value == '+' or value == '-') {
                    offset_start = offset;
                    break;
                }
            }
            if (offset_start) |start| zone = expiry[start..];
        }
    }
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ date_time[0..], zone });
}
