//! Table component for displaying tabular data.
//! Supports column headers, alignment, and styling.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const border_mod = @import("../style/border.zig");
const Color = @import("../style/color.zig").Color;
const measure = @import("../layout/measure.zig");
const keys = @import("../input/keys.zig");

pub fn Table(comptime num_cols: usize) type {
    return struct {
        allocator: std.mem.Allocator,

        // Data
        headers: [num_cols][]const u8,
        rows: std.array_list.Managed([num_cols][]const u8),

        // Appearance
        col_widths: [num_cols]?u16,
        col_aligns: [num_cols]Align,
        border_chars: border_mod.BorderChars,
        show_header: bool,
        show_border: bool,

        // Styling
        header_style: style_mod.Style,
        cell_style: style_mod.Style,
        border_style: style_mod.Style,
        alt_row_style: ?style_mod.Style,
        cursor_row_style: style_mod.Style,

        // Interactive state
        cursor_row: usize,
        focused: bool,
        y_offset: usize,
        visible_rows: u16,

        // Row borders
        show_row_borders: bool,

        // Per-cell styling callback
        style_func: ?*const fn (usize, usize) ?style_mod.Style,

        const Self = @This();

        pub const Align = enum {
            left,
            center,
            right,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .headers = .{""} ** num_cols,
                .rows = std.array_list.Managed([num_cols][]const u8).init(allocator),
                .col_widths = .{null} ** num_cols,
                .col_aligns = .{.left} ** num_cols,
                .border_chars = border_mod.Border.normal,
                .show_header = true,
                .show_border = true,
                .header_style = blk: {
                    var s = style_mod.Style{};
                    s = s.bold(true);
                    s = s.inline_style(true);
                    break :blk s;
                },
                .cell_style = blk: {
                    var s = style_mod.Style{};
                    s = s.inline_style(true);
                    break :blk s;
                },
                .border_style = blk: {
                    var s = style_mod.Style{};
                    s = s.fg(Color.gray(12));
                    s = s.inline_style(true);
                    break :blk s;
                },
                .alt_row_style = null,
                .cursor_row_style = blk2: {
                    var s2 = style_mod.Style{};
                    s2 = s2.bold(true);
                    s2 = s2.reverse(true);
                    s2 = s2.inline_style(true);
                    break :blk2 s2;
                },
                .cursor_row = 0,
                .focused = false,
                .y_offset = 0,
                .visible_rows = 10,
                .show_row_borders = false,
                .style_func = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit();
        }

        /// Set column headers
        pub fn setHeaders(self: *Self, headers: [num_cols][]const u8) void {
            self.headers = headers;
        }

        /// Add a row
        pub fn addRow(self: *Self, row: [num_cols][]const u8) !void {
            try self.rows.append(row);
        }

        /// Add multiple rows
        pub fn addRows(self: *Self, rows: []const [num_cols][]const u8) !void {
            try self.rows.appendSlice(rows);
        }

        /// Clear all rows
        pub fn clearRows(self: *Self) void {
            self.rows.clearRetainingCapacity();
        }

        /// Set column width
        pub fn setColumnWidth(self: *Self, col: usize, width: u16) void {
            if (col < num_cols) {
                self.col_widths[col] = width;
            }
        }

        /// Set column alignment
        pub fn setColumnAlign(self: *Self, col: usize, align_val: Align) void {
            if (col < num_cols) {
                self.col_aligns[col] = align_val;
            }
        }

        /// Set border style
        pub fn setBorder(self: *Self, border: border_mod.BorderChars) void {
            self.border_chars = border;
        }

        /// Focus the table for interactive mode
        pub fn focus(self: *Self) void {
            self.focused = true;
        }

        /// Blur the table
        pub fn blur(self: *Self) void {
            self.focused = false;
        }

        /// Get the currently selected row index
        pub fn selectedRow(self: *const Self) usize {
            return self.cursor_row;
        }

        /// Handle key event for navigation
        pub fn handleKey(self: *Self, key: keys.KeyEvent) void {
            if (!self.focused) return;

            switch (key.key) {
                .up => {
                    if (self.cursor_row > 0) self.cursor_row -= 1;
                    self.ensureRowVisible();
                },
                .down => {
                    if (self.rows.items.len > 0 and self.cursor_row < self.rows.items.len - 1) {
                        self.cursor_row += 1;
                    }
                    self.ensureRowVisible();
                },
                .page_up => {
                    if (self.cursor_row >= self.visible_rows) {
                        self.cursor_row -= self.visible_rows;
                    } else {
                        self.cursor_row = 0;
                    }
                    self.ensureRowVisible();
                },
                .page_down => {
                    self.cursor_row += self.visible_rows;
                    if (self.rows.items.len > 0 and self.cursor_row >= self.rows.items.len) {
                        self.cursor_row = self.rows.items.len - 1;
                    }
                    self.ensureRowVisible();
                },
                .home => {
                    self.cursor_row = 0;
                    self.y_offset = 0;
                },
                .end => {
                    if (self.rows.items.len > 0) {
                        self.cursor_row = self.rows.items.len - 1;
                    }
                    self.ensureRowVisible();
                },
                .char => |c| switch (c) {
                    'j' => {
                        if (self.rows.items.len > 0 and self.cursor_row < self.rows.items.len - 1) {
                            self.cursor_row += 1;
                        }
                        self.ensureRowVisible();
                    },
                    'k' => {
                        if (self.cursor_row > 0) self.cursor_row -= 1;
                        self.ensureRowVisible();
                    },
                    'g' => {
                        self.cursor_row = 0;
                        self.y_offset = 0;
                    },
                    'G' => {
                        if (self.rows.items.len > 0) {
                            self.cursor_row = self.rows.items.len - 1;
                        }
                        self.ensureRowVisible();
                    },
                    else => {},
                },
                else => {},
            }
        }

        fn ensureRowVisible(self: *Self) void {
            if (self.cursor_row < self.y_offset) {
                self.y_offset = self.cursor_row;
            } else if (self.cursor_row >= self.y_offset + self.visible_rows) {
                self.y_offset = self.cursor_row - self.visible_rows + 1;
            }
        }

        /// Calculate actual column widths
        fn calculateWidths(self: *const Self) [num_cols]usize {
            var widths: [num_cols]usize = .{0} ** num_cols;

            // Check headers
            for (0..num_cols) |i| {
                if (self.col_widths[i]) |w| {
                    widths[i] = w;
                } else {
                    widths[i] = @max(widths[i], measure.width(self.headers[i]));
                }
            }

            // Check rows
            for (self.rows.items) |row| {
                for (0..num_cols) |i| {
                    if (self.col_widths[i] == null) {
                        widths[i] = @max(widths[i], measure.width(row[i]));
                    }
                }
            }

            return widths;
        }

        /// Render the table
        pub fn view(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
            var result = std.array_list.Managed(u8).init(allocator);
            const writer = result.writer();

            const widths = self.calculateWidths();

            // Top border
            if (self.show_border) {
                try self.writeBorderLine(writer, allocator, widths, .top);
                try writer.writeByte('\n');
            }

            // Header
            if (self.show_header) {
                try self.writeRow(writer, allocator, self.headers, widths, self.header_style);
                try writer.writeByte('\n');

                // Header separator
                if (self.show_border) {
                    try self.writeBorderLine(writer, allocator, widths, .middle);
                    try writer.writeByte('\n');
                }
            }

            // Data rows (with viewport if focused)
            const start_row = if (self.focused) self.y_offset else 0;
            const end_row = if (self.focused)
                @min(start_row + self.visible_rows, self.rows.items.len)
            else
                self.rows.items.len;

            for (start_row..end_row) |row_idx| {
                const row = self.rows.items[row_idx];
                const row_style = if (self.focused and row_idx == self.cursor_row)
                    self.cursor_row_style
                else if (self.style_func) |func| blk: {
                    if (func(row_idx, 0)) |s| {
                        break :blk s;
                    }
                    break :blk if (self.alt_row_style != null and row_idx % 2 == 1)
                        self.alt_row_style.?
                    else
                        self.cell_style;
                } else if (self.alt_row_style != null and row_idx % 2 == 1)
                    self.alt_row_style.?
                else
                    self.cell_style;

                try self.writeRow(writer, allocator, row, widths, row_style);
                if (row_idx < end_row - 1 or self.show_border) {
                    try writer.writeByte('\n');
                }

                // Row borders between data rows
                if (self.show_row_borders and row_idx < end_row - 1) {
                    try self.writeBorderLine(writer, allocator, widths, .middle);
                    try writer.writeByte('\n');
                }
            }

            // Bottom border
            if (self.show_border) {
                try self.writeBorderLine(writer, allocator, widths, .bottom);
            }

            return result.toOwnedSlice();
        }

        fn writeRow(
            self: *const Self,
            writer: anytype,
            allocator: std.mem.Allocator,
            row: [num_cols][]const u8,
            widths: [num_cols]usize,
            row_style: style_mod.Style,
        ) !void {
            if (self.show_border) {
                const border_rendered = try self.border_style.render(allocator, self.border_chars.vertical);
                try writer.writeAll(border_rendered);
            }

            for (0..num_cols) |i| {
                if (i > 0 and self.show_border) {
                    const border_rendered = try self.border_style.render(allocator, self.border_chars.vertical);
                    try writer.writeAll(border_rendered);
                }

                try writer.writeByte(' ');

                const cell = row[i];
                const width = widths[i];
                const cell_width = measure.width(cell);
                const padding = if (width > cell_width) width - cell_width else 0;

                switch (self.col_aligns[i]) {
                    .left => {
                        const styled = try row_style.render(allocator, cell);
                        try writer.writeAll(styled);
                        for (0..padding) |_| try writer.writeByte(' ');
                    },
                    .center => {
                        const left_pad = padding / 2;
                        const right_pad = padding - left_pad;
                        for (0..left_pad) |_| try writer.writeByte(' ');
                        const styled = try row_style.render(allocator, cell);
                        try writer.writeAll(styled);
                        for (0..right_pad) |_| try writer.writeByte(' ');
                    },
                    .right => {
                        for (0..padding) |_| try writer.writeByte(' ');
                        const styled = try row_style.render(allocator, cell);
                        try writer.writeAll(styled);
                    },
                }

                try writer.writeByte(' ');
            }

            if (self.show_border) {
                const border_rendered = try self.border_style.render(allocator, self.border_chars.vertical);
                try writer.writeAll(border_rendered);
            }
        }

        const BorderPosition = enum { top, middle, bottom };

        fn writeBorderLine(
            self: *const Self,
            writer: anytype,
            allocator: std.mem.Allocator,
            widths: [num_cols]usize,
            pos: BorderPosition,
        ) !void {
            const left = switch (pos) {
                .top => self.border_chars.top_left,
                .middle => self.border_chars.middle_left,
                .bottom => self.border_chars.bottom_left,
            };
            const mid = switch (pos) {
                .top => self.border_chars.middle_top,
                .middle => self.border_chars.cross,
                .bottom => self.border_chars.middle_bottom,
            };
            const right = switch (pos) {
                .top => self.border_chars.top_right,
                .middle => self.border_chars.middle_right,
                .bottom => self.border_chars.bottom_right,
            };

            const left_styled = try self.border_style.render(allocator, left);
            try writer.writeAll(left_styled);

            for (0..num_cols) |i| {
                if (i > 0) {
                    const mid_styled = try self.border_style.render(allocator, mid);
                    try writer.writeAll(mid_styled);
                }

                const h_styled = try self.border_style.render(allocator, self.border_chars.horizontal);
                for (0..widths[i] + 2) |_| {
                    try writer.writeAll(h_styled);
                }
            }

            const right_styled = try self.border_style.render(allocator, right);
            try writer.writeAll(right_styled);
        }
    };
}

/// Create a table with dynamic column count
pub fn DynamicTable(allocator: std.mem.Allocator) DynamicTableType {
    return DynamicTableType.init(allocator);
}

pub const DynamicTableType = struct {
    allocator: std.mem.Allocator,
    headers: std.array_list.Managed([]const u8),
    rows: std.array_list.Managed(std.array_list.Managed([]const u8)),
    border_chars: border_mod.BorderChars,
    show_header: bool,
    show_border: bool,

    pub fn init(allocator: std.mem.Allocator) DynamicTableType {
        return .{
            .allocator = allocator,
            .headers = std.array_list.Managed([]const u8).init(allocator),
            .rows = std.array_list.Managed(std.array_list.Managed([]const u8)).init(allocator),
            .border_chars = border_mod.Border.normal,
            .show_header = true,
            .show_border = true,
        };
    }

    pub fn deinit(self: *DynamicTableType) void {
        self.headers.deinit();
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
    }

    pub fn setHeaders(self: *DynamicTableType, headers: []const []const u8) !void {
        self.headers.clearRetainingCapacity();
        try self.headers.appendSlice(headers);
    }

    pub fn addRow(self: *DynamicTableType, cells: []const []const u8) !void {
        var row = std.array_list.Managed([]const u8).init(self.allocator);
        try row.appendSlice(cells);
        try self.rows.append(row);
    }
};
