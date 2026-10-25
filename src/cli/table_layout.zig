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

/// Semantic identity of a responsive table column. Visual order is supplied
/// separately, so views such as `list` and `list --live` can keep their own
/// column order while sharing one allocation strategy.
pub const ColumnId = enum {
    number,
    account,
    plan,
    credits,
    reset_credits,
    rate_5h,
    rate_week,
    last,
    auth_expire,
    plan_expire,
};

pub const ColumnSpec = struct {
    id: ColumnId,
    content_width: usize,
    target_width: usize,
    min_width: usize,
    allow_partial: bool = false,
};

pub const ColumnLayout = struct {
    columns: []const ColumnSpec,
    first_order: []const ColumnId,
    grow_order: []const ColumnId,
    deferred_order: []const ColumnId,
    prefix_width: usize,
    separator_width: usize,
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

pub fn accountTable(widths: [live_column_count]usize, prefix_width: usize) LiveTable {
    return .{
        .columns = .{
            .{ .header = "ACCOUNT", .width = widths[0] },
            .{ .header = "PLAN", .width = widths[1] },
            .{ .header = "5H", .width = widths[2] },
            .{ .header = "WEEKLY", .width = widths[3] },
            .{ .header = "LAST", .width = widths[4] },
        },
        .prefix_width = prefix_width,
    };
}

pub const switch_columns = [_]ColumnId{ .account, .plan, .rate_5h, .rate_week, .last };

/// Shared priority for every view. A view simply skips columns it does not
/// support (content width 0). Keep this single list as the source of truth so
/// `list` and `list --live` cannot drift apart.
pub const shared_first_order = [_]ColumnId{
    .number,
    .account,
    .rate_5h,
    .rate_week,
    .plan,
    .reset_credits,
    .credits,
};
pub const shared_grow_order = [_]ColumnId{
    .rate_5h,
    .rate_week,
    .plan,
    .reset_credits,
    .credits,
};
pub const shared_deferred_order = [_]ColumnId{ .auth_expire, .plan_expire, .last };

pub fn accountTableForSwitch(widths: SwitchWidths, prefix_width: usize, max_cols: ?usize) LiveTable {
    const source_widths = [_]usize{ widths.email, widths.plan, widths.rate_5h, widths.rate_week, widths.last };
    var columns: [switch_columns.len]ColumnSpec = undefined;
    for (switch_columns, 0..) |id, index| {
        columns[index] = columnSpec(id, source_widths[index]);
    }
    var bounded = [_]usize{0} ** live_column_count;
    allocateColumns(.{
        .columns = &columns,
        .first_order = &shared_first_order,
        .grow_order = &shared_grow_order,
        .deferred_order = &shared_deferred_order,
        .prefix_width = prefix_width,
        .separator_width = 2,
    }, max_cols, &bounded);
    return accountTable(bounded, prefix_width);
}

pub const plain_columns = [_]ColumnId{ .account, .plan, .plan_expire, .credits, .reset_credits, .rate_5h, .rate_week, .auth_expire, .last };

pub const list_detail_columns = [_]ColumnId{ .number, .account, .plan, .plan_expire, .reset_credits, .rate_5h, .rate_week, .auth_expire, .last };

pub fn defaultTargetWidth(id: ColumnId) usize {
    return switch (id) {
        .number => 2,
        .account => live_account_ident_width,
        .plan => "PLAN".len,
        .credits => 2,
        .reset_credits => 2,
        .rate_5h => @max(4, "5H".len),
        .rate_week => "WEEKLY".len,
        .last => 4,
        .auth_expire => 10,
        .plan_expire => 10,
    };
}

pub fn columnSpec(id: ColumnId, content_width: usize) ColumnSpec {
    const target = defaultTargetWidth(id);
    return .{
        .id = id,
        .content_width = content_width,
        .target_width = target,
        .min_width = if (id == .account) account_min_width else target,
        .allow_partial = id == .account,
    };
}

pub fn allocateColumns(layout: ColumnLayout, max_cols: ?usize, widths: []usize) void {
    @memset(widths, 0);
    if (widths.len != layout.columns.len) return;

    if (max_cols == null) {
        for (layout.columns, 0..) |column, index| widths[index] = column.content_width;
        return;
    }

    const cols = max_cols.?;
    if (cols <= layout.prefix_width) return;

    var remaining = cols - layout.prefix_width;
    var visible_count: usize = 0;

    for (layout.first_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        const column = layout.columns[index];
        if (column.content_width == 0) continue;

        const target = @min(column.content_width, column.target_width);
        if (target == 0) continue;

        const separator = if (visible_count == 0) 0 else layout.separator_width;

        if (column.allow_partial) {
            if (remaining < column.min_width + separator) break;
            const width = @min(target, remaining - separator);
            if (width < column.min_width) break;
            widths[index] = width;
            remaining -= width + separator;
            visible_count += 1;
            continue;
        }

        if (remaining < target + separator) break;
        widths[index] = target;
        remaining -= target + separator;
        visible_count += 1;
    }

    for (layout.grow_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        if (widths[index] == 0) continue;
        growBoundedWidth(&remaining, &widths[index], layout.columns[index].content_width);
    }

    // Deferred columns are admitted only after all normal columns have grown.
    // They still require their target width, so they never become dot-only
    // cells; if the target does not fit, the column stays hidden.
    for (layout.deferred_order) |id| {
        const index = columnIndex(layout.columns, id) orelse continue;
        if (widths[index] != 0) continue;
        const column = layout.columns[index];
        if (column.content_width == 0) continue;
        const target = @min(column.content_width, column.target_width);
        if (target == 0) continue;
        const separator = if (visible_count == 0) 0 else layout.separator_width;
        if (remaining < target + separator) break;
        widths[index] = target;
        remaining -= target + separator;
        visible_count += 1;
        growBoundedWidth(&remaining, &widths[index], column.content_width);
    }

    // ACCOUNT identity is useful but approximate: give every other column,
    // including deferred columns, a chance before expanding it. A long account
    // label therefore cannot squeeze AUTH/PLAN expiry or LAST out of the table.
    if (columnIndex(layout.columns, .account)) |index| {
        if (widths[index] != 0) {
            growBoundedWidth(&remaining, &widths[index], layout.columns[index].content_width);
        }
    }
}

fn columnIndex(columns: []const ColumnSpec, id: ColumnId) ?usize {
    for (columns, 0..) |column, index| {
        if (column.id == id) return index;
    }
    return null;
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

test "plain and live views keep shared columns in the same relative order" {
    var previous: ?usize = null;
    for (list_detail_columns) |id| {
        if (id == .number) continue;
        const position = std.mem.indexOfScalar(ColumnId, &plain_columns, id) orelse
            return error.TestUnexpectedResult;
        if (previous) |prev| try std.testing.expect(position > prev);
        previous = position;
    }
}
