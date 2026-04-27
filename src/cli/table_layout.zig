const std = @import("std");
const row_data = @import("rows.zig");
const style = @import("style.zig");

pub const SwitchWidths = row_data.SwitchWidths;

pub const LiveListViewport = struct {
    start_row: usize = 0,
    max_rows: ?usize = null,
    max_cols: ?usize = null,
};

pub const column_count = 5;
const live_account_ident_width: usize = 10;
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
    columns: [column_count]LiveTableColumn,
    prefix_width: usize,

    pub fn writeHeader(self: *const LiveTable, out: *std.Io.Writer, use_color: bool) !void {
        if (use_color) try out.writeAll(style.ansi.cyan);
        try writeRepeat(out, ' ', self.prefix_width);
        try self.writeCells(out, &.{
            .{ .text = self.columns[0].header },
            .{ .text = self.columns[1].header },
            .{ .text = self.columns[2].header },
            .{ .text = self.columns[3].header },
            .{ .text = self.columns[4].header },
        });
        if (use_color) try out.writeAll(style.ansi.reset);
        try out.writeAll("\n");
    }

    pub fn writeGroupRow(self: *const LiveTable, out: *std.Io.Writer, account: []const u8, use_color: bool) !void {
        if (use_color) try out.writeAll(style.ansi.dim);
        try writeRepeat(out, ' ', self.prefix_width);
        try writeAccountTruncatedPadded(out, account, self.columns[0].width);
        if (use_color) try out.writeAll(style.ansi.reset);
        try out.writeAll("\n");
    }

    pub fn writeDataRow(
        self: *const LiveTable,
        out: *std.Io.Writer,
        prefix: []const u8,
        cells: [column_count]Cell,
        ansi_style: []const u8,
    ) !void {
        if (ansi_style.len != 0) try out.writeAll(ansi_style);
        try out.writeAll(prefix);
        if (prefix.len < self.prefix_width) {
            try writeRepeat(out, ' ', self.prefix_width - prefix.len);
        }
        try self.writeCells(out, &cells);
        if (ansi_style.len != 0) try out.writeAll(style.ansi.reset);
        try out.writeAll("\n");
    }

    fn writeCells(
        self: *const LiveTable,
        out: *std.Io.Writer,
        cells: *const [column_count]Cell,
    ) !void {
        for (self.columns, 0..) |column, i| {
            if (i > 0) try out.writeAll("  ");
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

pub fn accountTable(widths: SwitchWidths, prefix_width: usize) LiveTable {
    return .{
        .columns = .{
            .{ .header = "ACCOUNT", .width = widths.email },
            .{ .header = "PLAN", .width = widths.plan },
            .{ .header = "5H", .width = widths.rate_5h },
            .{ .header = "WEEKLY", .width = widths.rate_week },
            .{ .header = "LAST", .width = widths.last },
        },
        .prefix_width = prefix_width,
    };
}

pub fn boundWidths(widths: SwitchWidths, prefix_width: usize, max_cols: ?usize) SwitchWidths {
    const cols = max_cols orelse return widths;
    const separator_width = 2 * (column_count - 1);
    if (cols <= prefix_width + separator_width) {
        return .{
            .email = 0,
            .plan = 0,
            .rate_5h = 0,
            .rate_week = 0,
            .last = 0,
        };
    }

    var remaining = cols - prefix_width - separator_width;
    var bounded = SwitchWidths{
        .email = 0,
        .plan = 0,
        .rate_5h = 0,
        .rate_week = 0,
        .last = 0,
    };

    growBoundedWidth(&remaining, &bounded.email, @min(widths.email, live_account_ident_width));
    growBoundedWidth(&remaining, &bounded.rate_5h, @min(widths.rate_5h, @max(@as(usize, 4), "5H".len)));
    growBoundedWidth(&remaining, &bounded.rate_week, @min(widths.rate_week, "WEEKLY".len));
    growBoundedWidth(&remaining, &bounded.plan, @min(widths.plan, "PLAN".len));
    growBoundedWidth(&remaining, &bounded.last, @min(widths.last, @as(usize, 3)));

    growBoundedWidth(&remaining, &bounded.rate_5h, widths.rate_5h);
    growBoundedWidth(&remaining, &bounded.rate_week, widths.rate_week);
    growBoundedWidth(&remaining, &bounded.plan, widths.plan);
    growBoundedWidth(&remaining, &bounded.last, widths.last);
    growBoundedWidth(&remaining, &bounded.email, widths.email);

    return bounded;
}

fn growBoundedWidth(remaining: *usize, current: *usize, target: usize) void {
    if (current.* >= target) return;
    const amount = @min(remaining.*, target - current.*);
    current.* += amount;
    remaining.* -= amount;
}

fn writePadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.writeAll(value);
    if (value.len >= width) return;
    try out.splatByteAll(' ', width - value.len);
}

fn writeTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
        try writePadded(out, value, width);
        return;
    }
    if (width == 1) {
        try out.writeAll(".");
        return;
    }
    try out.writeAll(value[0 .. width - 1]);
    try out.writeAll(".");
}

fn writeAccountTruncatedPadded(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
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

    const suffix_len = @min(max_suffix, @max(live_account_suffix_min_len, value.len - 1 - live_account_prefix_min_len));
    const prefix_len = width - suffix_len - 1;
    try out.writeAll(value[0..prefix_len]);
    try out.writeAll(".");
    try out.writeAll(value[value.len - suffix_len ..]);
}

fn writeRepeat(out: *std.Io.Writer, ch: u8, count: usize) !void {
    try out.splatByteAll(ch, count);
}
