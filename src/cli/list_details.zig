const std = @import("std");
const registry = @import("../registry/root.zig");
const app_runtime = @import("../core/runtime.zig");
const rows = @import("rows.zig");
const table_layout = @import("table_layout.zig");

const max_columns = 64;
const base_headers = [_][]const u8{ "#*", "ACCOUNT", "PLAN", "5H", "WEEKLY", "NEXT RESET", "LAST", "ACCESS TOKEN EXP" };
const base_desired_widths = [_]usize{ 2, 18, 8, 12, 12, 16, 10, 16 };
const base_minimum_widths = [_]usize{ 1, 8, 4, 4, 6, 10, 5, 10 };
const base_column_count = base_headers.len;
const credit_width: usize = 10;
const separator_width: usize = 3;

pub fn writeHeader(allocator: std.mem.Allocator, out: *std.Io.Writer, reg: *const registry.Registry, number_width: usize, max_cols: ?usize) !void {
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
    try writeAlignedRow(out, values[0..count], widths[0..count], minimums[0..count], max_cols, false);
    _ = allocator;
}

pub fn write(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
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
        values[count] = creditExpiry(account.last_usage, index) orelse "-";
        widths[count] = credit_width;
        minimums[count] = credit_width;
        count += 1;
    }
    try writeAlignedRow(out, values[0..count], widths[0..count], minimums[0..count], max_cols, true);
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
    out: *std.Io.Writer,
    values: []const []const u8,
    desired: []const usize,
    minimums: []const usize,
    max_cols: ?usize,
    account_column: bool,
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
    for (values, 0..) |value, index| {
        if (index != 0) try out.writeAll(" | ");
        if (account_column and index == 1) {
            try table_layout.writeAccountTruncatedPadded(out, value, widths[index]);
        } else {
            try table_layout.writeTruncatedPadded(out, value, widths[index]);
        }
    }
    try out.writeAll("\n");
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

fn creditExpiry(snapshot: ?registry.RateLimitSnapshot, index: usize) ?[]const u8 {
    const usage = snapshot orelse return null;
    const details = usage.reset_credit_details orelse return null;
    if (index >= details.credits.len) return null;
    const expiry = details.credits[index].expires_at orelse return null;
    return if (expiry.len >= 10) expiry[0..10] else expiry;
}
