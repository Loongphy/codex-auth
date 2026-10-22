const std = @import("std");
const row_data = @import("rows.zig");
const style = @import("style.zig");
const text_width = @import("../tui/text_width.zig");

pub const SwitchWidths = row_data.SwitchWidths;

pub const LiveListViewport = struct {
    start_row: usize = 0,
    max_rows: ?usize = null,
    max_cols: ?usize = null,
};

pub const live_column_count = 5;
pub const column_count = 8;
const live_account_ident_width: usize = 10;
const account_min_width: usize = 2;
const live_account_suffix_min_width: usize = 10;
const live_account_suffix_min_len: usize = 3;
const live_account_prefix_min_len: usize = 6;

const LiveTableColumn = struct {
    header: []const u8,
    width: usize,
};

pub const Cell = struct {
    text: []const u8,
    indent: usize = 0,
};

pub const LiveTable = struct {
    columns: [live_column_count]LiveTableColumn,
    prefix_width: usize,

    pub fn writeHeader(self: *const LiveTable, writer: *style.StyledWriter) !void {
        try writer.writeStyle(style.role.status);
        try writeRepeat(writer.out, ' ', self.prefix_width);
        try self.writeCells(writer.out, &.{
            .{ .text = self.columns[0].header },
            .{ .text = self.columns[1].header },
            .{ .text = self.columns[2].header },
            .{ .text = self.columns[3].header },
            .{ .text = self.columns[4].header },
        });
        try writer.reset();
        try writer.writeAll("\n");
    }

    pub fn writeGroupRow(self: *const LiveTable, writer: *style.StyledWriter, account: []const u8) !void {
        if (self.columns[0].width == 0) return;
        try writer.writeStyle(style.role.secondary);
        try writeRepeat(writer.out, ' ', self.prefix_width);
        try writeAccountTruncatedPadded(writer.out, account, self.columns[0].width);
        try writer.reset();
        try writer.writeAll("\n");
    }

    pub fn writeDataRow(
        self: *const LiveTable,
        writer: *style.StyledWriter,
        prefix: []const u8,
        cells: [live_column_count]Cell,
        ansi_style: []const u8,
    ) !void {
        try writer.writeStyle(ansi_style);
        try writer.writeAll(prefix);
        if (prefix.len < self.prefix_width) {
            try writeRepeat(writer.out, ' ', self.prefix_width - prefix.len);
        }
        try self.writeCells(writer.out, &cells);
        if (ansi_style.len != 0) try writer.reset();
        try writer.writeAll("\n");
    }

    fn writeCells(
        self: *const LiveTable,
        out: *std.Io.Writer,
        cells: *const [live_column_count]Cell,
    ) !void {
        var wrote_any = false;
        for (self.columns, 0..) |column, i| {
            if (column.width == 0) continue;
            if (wrote_any) try out.writeAll("  ");
            wrote_any = true;
            const indent = @min(cells[i].indent, column.width);
            try writeRepeat(out, ' ', indent);
            if (i == 0) {
                try writeAccountTruncatedPadded(out, cells[i].text, column.width - indent);
            } else {
                try writeTruncatedPadded(out, cells[i].text, column.width - indent);
            }
        }
    }
};

pub fn accountTable(widths: [column_count]usize, prefix_width: usize) LiveTable {
    return .{
        .columns = .{
            .{ .header = "ACCOUNT", .width = widths[0] },
            .{ .header = "PLAN", .width = widths[1] },
            .{ .header = "5H", .width = widths[4] },
            .{ .header = "WEEKLY", .width = widths[5] },
            .{ .header = "LAST", .width = widths[6] },
        },
        .prefix_width = prefix_width,
    };
}

pub fn accountTableForSwitch(widths: SwitchWidths, prefix_width: usize, max_cols: ?usize) LiveTable {
    return accountTable(
        boundColumnWidths(switchWidthsToColumns(widths), prefix_width, max_cols),
        prefix_width,
    );
}

const first_pass_order = [_]usize{ 0, 4, 5, 2, 1, 3, 6 };
const grow_pass_order = [_]usize{ 2, 4, 5, 1, 3, 6, 0 };
const deferred_column_index: usize = 7;
const column_target_widths = [_]usize{
    live_account_ident_width, // ACCOUNT
    "PLAN".len, // PLAN
    2, // CREDITS
    2, // RESET CREDITS
    @max(4, "5H".len), // 5H
    "WEEKLY".len, // WEEKLY
    4, // LAST
    10, // PLAN EXPIRE
};

/// Shared responsive column allocator for every table view.
///
/// Input widths are content widths. A zero input width disables a column
/// (used by the live view to hide CREDITS and RESET CREDITS). The first pass
/// admits columns by priority only when their target width and separator fit;
/// ACCOUNT may use a partial width when nothing else fits. The second pass
/// grows visible columns toward their content width, keeping ACCOUNT last so
/// long labels cannot starve values such as `unlimited` or error names.
/// Columns that receive zero width must be skipped by the caller.
pub fn boundColumnWidths(widths: [column_count]usize, prefix_len: usize, max_cols: ?usize) [column_count]usize {
    const cols = max_cols orelse return widths;
    var bounded = [_]usize{0} ** column_count;
    if (cols <= prefix_len) return bounded;

    var remaining = cols - prefix_len;
    var visible_count: usize = 0;

    // First pass: reserve targets by priority. Separators are charged only
    // when a column actually becomes visible.
    for (first_pass_order) |index| {
        const target = @min(widths[index], column_target_widths[index]);
        if (target == 0) continue;

        if (index == 0) {
            const width = @min(target, remaining);
            if (width < account_min_width) continue;
            bounded[index] = width;
            remaining -= width;
            visible_count += 1;
            continue;
        }

        const separator_width: usize = if (visible_count == 0) 0 else 2;
        if (remaining < target + separator_width) continue;
        bounded[index] = target;
        remaining -= target + separator_width;
        visible_count += 1;
    }

    // Second pass: grow the variable-length credit cell first so values like
    // `unlimited` do not collapse to `u.`, then the usage windows, and keep
    // account identity last so long labels cannot starve other values.
    for (grow_pass_order) |index| {
        if (bounded[index] == 0) continue;
        growBoundedWidth(&remaining, &bounded[index], widths[index]);
    }

    // Deferred pass: admit a low-priority column only after every existing
    // column has had a chance to grow. This keeps the plan-expiry column from
    // stealing width from usage and status cells on mid-sized terminals.
    if (bounded[deferred_column_index] == 0 and widths[deferred_column_index] > 0) {
        const separator_width: usize = if (visible_count == 0) 0 else 2;
        if (remaining > separator_width) {
            const width = @min(widths[deferred_column_index], remaining - separator_width);
            if (width > 0) {
                bounded[deferred_column_index] = width;
                remaining -= width + separator_width;
            }
        }
    }

    return bounded;
}

pub fn switchWidthsToColumns(widths: SwitchWidths) [column_count]usize {
    return .{
        widths.email,
        widths.plan,
        0,
        0,
        widths.rate_5h,
        widths.rate_week,
        widths.last,
        0,
    };
}

fn growBoundedWidth(remaining: *usize, current: *usize, target: usize) void {
    if (current.* >= target) return;
    const amount = @min(remaining.*, target - current.*);
    current.* += amount;
    remaining.* -= amount;
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    const value_width = text_width.displayWidth(value);
    if (value_width >= width) return;
    try out.splatByteAll(' ', width - value_width);
}

pub fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (text_width.displayWidth(value) <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width == 1) {
        try out.writeAll(".");
        return;
    }
    try out.writeAll(value[0..text_width.prefixByteLength(value, width - 1)]);
    try out.writeAll(".");
}

pub fn writeAccountTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    const value_width = text_width.displayWidth(value);
    if (value_width <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width < live_account_suffix_min_width) {
        try writeTruncatedPadded(out, value, width);
        return;
    }

    const max_suffix = width - live_account_prefix_min_len - 1;
    if (max_suffix < live_account_suffix_min_len) {
        try writeTruncatedPadded(out, value, width);
        return;
    }

    const suffix_len = @min(max_suffix, @max(live_account_suffix_min_len, value_width - 1 - live_account_prefix_min_len));
    const prefix_len = width - suffix_len - 1;
    try out.writeAll(value[0..text_width.prefixByteLength(value, prefix_len)]);
    try out.writeAll(".");
    try out.writeAll(value[text_width.suffixStart(value, suffix_len)..]);
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    try out.splatByteAll(ch, count);
}
