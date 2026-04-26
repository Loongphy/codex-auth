//! Screen buffer management for efficient terminal rendering.
//! Provides double-buffering to minimize flickering and optimize updates.

const std = @import("std");
const ansi = @import("ansi.zig");
const unicode = @import("../unicode.zig");

/// A cell in the screen buffer
pub const Cell = struct {
    char: u21 = ' ',
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    /// True if this cell is the continuation (right half) of a wide character.
    wide: bool = false,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            eqlOptColor(self.fg, other.fg) and
            eqlOptColor(self.bg, other.bg) and
            self.bold == other.bold and
            self.dim == other.dim and
            self.italic == other.italic and
            self.underline == other.underline and
            self.blink == other.blink and
            self.reverse == other.reverse and
            self.strikethrough == other.strikethrough and
            self.wide == other.wide;
    }

    fn eqlOptColor(a: ?Color, b: ?Color) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.eql(b.?);
    }
};

/// Color representation
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

/// Screen buffer for rendering
pub const Screen = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    width: u16,
    height: u16,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Screen {
        const size = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alloc(Cell, size);
        @memset(cells, Cell{});

        return .{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.cells);
    }

    pub fn resize(self: *Screen, new_width: u16, new_height: u16) !void {
        const new_size = @as(usize, new_width) * @as(usize, new_height);
        const new_cells = try self.allocator.alloc(Cell, new_size);
        @memset(new_cells, Cell{});

        // Copy existing content
        const copy_height = @min(self.height, new_height);
        const copy_width = @min(self.width, new_width);

        for (0..copy_height) |y| {
            const old_row_start = y * self.width;
            const new_row_start = y * new_width;
            @memcpy(
                new_cells[new_row_start..][0..copy_width],
                self.cells[old_row_start..][0..copy_width],
            );
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cells, Cell{});
    }

    pub fn getCell(self: *const Screen, x: u16, y: u16) ?*const Cell {
        if (x >= self.width or y >= self.height) return null;
        return &self.cells[@as(usize, y) * self.width + x];
    }

    pub fn setCell(self: *Screen, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * self.width + x;

        // If we're overwriting a wide-char continuation cell, clear the left half
        if (self.cells[idx].wide and x > 0) {
            self.cells[idx - 1] = Cell{};
        }
        // If we're overwriting the left half of a wide char, clear the continuation
        if (!self.cells[idx].wide and x + 1 < self.width and self.cells[idx + 1].wide) {
            self.cells[idx + 1] = Cell{};
        }

        self.cells[idx] = cell;

        // If this is a wide character, set the continuation cell
        const cw = unicode.charWidth(cell.char);
        if (cw == 2 and x + 1 < self.width) {
            var cont = Cell{};
            cont.wide = true;
            cont.fg = cell.fg;
            cont.bg = cell.bg;
            self.cells[idx + 1] = cont;
        }
    }

    pub fn setChar(self: *Screen, x: u16, y: u16, char: u21) void {
        if (x >= self.width or y >= self.height) return;
        var cell = self.cells[@as(usize, y) * self.width + x];
        cell.char = char;
        cell.wide = false;
        self.setCell(x, y, cell);
    }

    /// Write a string to the screen at the given position
    pub fn writeString(self: *Screen, x: u16, y: u16, str: []const u8) u16 {
        var col = x;
        var utf8 = std.unicode.Utf8View.init(str) catch return 0;
        var iter = utf8.iterator();

        while (iter.nextCodepoint()) |cp| {
            const cw = unicode.charWidth(cp);
            if (cw == 0) continue; // Skip zero-width characters
            if (col + cw > self.width) break; // Wide char won't fit
            self.setChar(col, y, cp);
            col += @intCast(cw);
        }

        return col - x;
    }

    /// Render screen differences to the writer
    pub fn renderDiff(self: *const Screen, prev: *const Screen, writer: anytype) !void {
        var last_x: u16 = 0;
        var last_y: u16 = 0;
        var need_move = true;
        var current_cell = Cell{};

        for (0..self.height) |y_usize| {
            const y: u16 = @intCast(y_usize);
            var x_usize: usize = 0;
            while (x_usize < self.width) {
                const x: u16 = @intCast(x_usize);
                const idx = y_usize * self.width + x_usize;
                const cell = self.cells[idx];

                // Skip wide continuation cells
                if (cell.wide) {
                    x_usize += 1;
                    need_move = true;
                    continue;
                }

                const prev_cell = if (idx < prev.cells.len) prev.cells[idx] else Cell{};

                if (!cell.eql(prev_cell)) {
                    // Need to update this cell
                    if (need_move or x != last_x + 1 or y != last_y) {
                        try ansi.cursorTo0(writer, y, x);
                        need_move = false;
                    }

                    // Apply style changes
                    try applyStyle(writer, &current_cell, cell);
                    current_cell = cell;

                    // Write character
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
                    try writer.writeAll(buf[0..len]);

                    const cw = unicode.charWidth(cell.char);
                    last_x = if (cw == 2) x + 1 else x;
                    last_y = y;
                    x_usize += cw;
                } else {
                    x_usize += 1;
                }
            }
        }

        // Reset styles at the end
        try writer.writeAll(ansi.reset);
    }

    /// Render entire screen to writer
    pub fn render(self: *const Screen, writer: anytype) !void {
        try writer.writeAll(ansi.cursor_home);
        try writer.writeAll(ansi.reset);

        var current_cell = Cell{};

        for (0..self.height) |y_usize| {
            if (y_usize > 0) {
                try writer.writeAll("\r\n");
            }

            var x_usize: usize = 0;
            while (x_usize < self.width) {
                const idx = y_usize * self.width + x_usize;
                const cell = self.cells[idx];

                // Skip wide continuation cells
                if (cell.wide) {
                    x_usize += 1;
                    continue;
                }

                try applyStyle(writer, &current_cell, cell);
                current_cell = cell;

                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch 1;
                try writer.writeAll(buf[0..len]);

                const cw = unicode.charWidth(cell.char);
                x_usize += if (cw > 0) cw else 1;
            }
        }

        try writer.writeAll(ansi.reset);
    }

    fn applyStyle(writer: anytype, current: *Cell, new: Cell) !void {
        var needs_reset = false;

        // Check if we need to reset (turning off attributes)
        if ((current.bold and !new.bold) or
            (current.dim and !new.dim) or
            (current.italic and !new.italic) or
            (current.underline and !new.underline) or
            (current.blink and !new.blink) or
            (current.reverse and !new.reverse) or
            (current.strikethrough and !new.strikethrough))
        {
            needs_reset = true;
            try writer.writeAll(ansi.reset);
            current.* = Cell{};
        }

        // Apply foreground color
        if (!eqlOptColor(current.fg, new.fg)) {
            if (new.fg) |fg| {
                try ansi.fgRgb(writer, fg.r, fg.g, fg.b);
            } else {
                try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.fg_default});
            }
        }

        // Apply background color
        if (!eqlOptColor(current.bg, new.bg)) {
            if (new.bg) |bg| {
                try ansi.bgRgb(writer, bg.r, bg.g, bg.b);
            } else {
                try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bg_default});
            }
        }

        // Apply text attributes
        if (!current.bold and new.bold) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bold});
        if (!current.dim and new.dim) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.dim});
        if (!current.italic and new.italic) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.italic});
        if (!current.underline and new.underline) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
        if (!current.blink and new.blink) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.blink});
        if (!current.reverse and new.reverse) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.reverse});
        if (!current.strikethrough and new.strikethrough) try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});
    }

    fn eqlOptColor(a: ?Color, b: ?Color) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.eql(b.?);
    }
};
