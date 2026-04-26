//! Plotting canvas with braille and cell-based markers.

const std = @import("std");
const charting = @import("charting.zig");
const style_mod = @import("../style/style.zig");

pub const Marker = charting.Marker;
pub const Point = charting.Point;
pub const DataRange = charting.DataRange;
pub const Style = style_mod.Style;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    x_range: DataRange,
    y_range: DataRange,
    marker: Marker,
    background_glyph: []const u8,
    point_glyph: []const u8,
    line_glyph: []const u8,
    default_style: Style,
    operations: std.array_list.Managed(Operation),

    const Operation = union(enum) {
        point: PointOp,
        line: LineOp,
        rect: RectOp,
        text: TextOp,
    };

    const PointOp = struct {
        point: Point,
        style: Style,
        glyph: ?[]const u8 = null,
    };

    const LineOp = struct {
        from: Point,
        to: Point,
        style: Style,
        glyph: ?[]const u8 = null,
    };

    const RectOp = struct {
        min: Point,
        max: Point,
        filled: bool,
        style: Style,
        glyph: ?[]const u8 = null,
    };

    const TextOp = struct {
        origin: Point,
        text: []const u8,
        style: Style,
    };

    const BrailleCell = struct {
        bits: u8 = 0,
        style: ?Style = null,
    };

    pub fn init(allocator: std.mem.Allocator) Canvas {
        return .{
            .allocator = allocator,
            .width = 40,
            .height = 12,
            .x_range = .{ .min = 0, .max = 1 },
            .y_range = .{ .min = 0, .max = 1 },
            .marker = .braille,
            .background_glyph = " ",
            .point_glyph = "•",
            .line_glyph = "█",
            .default_style = charting.inlineStyle(Style{}),
            .operations = std.array_list.Managed(Operation).init(allocator),
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.operations.deinit();
    }

    pub fn clear(self: *Canvas) void {
        self.operations.clearRetainingCapacity();
    }

    pub fn setSize(self: *Canvas, width: u16, height: u16) void {
        self.width = @max(1, width);
        self.height = @max(1, height);
    }

    pub fn setRanges(self: *Canvas, x_range: DataRange, y_range: DataRange) void {
        self.x_range = x_range.normalized();
        self.y_range = y_range.normalized();
    }

    pub fn setMarker(self: *Canvas, marker: Marker) void {
        self.marker = marker;
    }

    pub fn setStyle(self: *Canvas, style: Style) void {
        self.default_style = charting.inlineStyle(style);
    }

    pub fn setGlyphs(self: *Canvas, point_glyph: []const u8, line_glyph: []const u8) void {
        self.point_glyph = point_glyph;
        self.line_glyph = line_glyph;
    }

    pub fn setBackground(self: *Canvas, glyph: []const u8) void {
        self.background_glyph = glyph;
    }

    pub fn drawPoint(self: *Canvas, x: f64, y: f64) !void {
        try self.drawPointStyled(x, y, self.default_style, null);
    }

    pub fn drawPointStyled(self: *Canvas, x: f64, y: f64, style: Style, glyph: ?[]const u8) !void {
        try self.operations.append(.{
            .point = .{
                .point = .{ .x = x, .y = y },
                .style = charting.inlineStyle(style),
                .glyph = glyph,
            },
        });
    }

    pub fn drawLine(self: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64) !void {
        try self.drawLineStyled(x0, y0, x1, y1, self.default_style, null);
    }

    pub fn drawLineStyled(self: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, style: Style, glyph: ?[]const u8) !void {
        try self.operations.append(.{
            .line = .{
                .from = .{ .x = x0, .y = y0 },
                .to = .{ .x = x1, .y = y1 },
                .style = charting.inlineStyle(style),
                .glyph = glyph,
            },
        });
    }

    pub fn drawRect(self: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, filled: bool, style: Style, glyph: ?[]const u8) !void {
        try self.operations.append(.{
            .rect = .{
                .min = .{ .x = @min(x0, x1), .y = @min(y0, y1) },
                .max = .{ .x = @max(x0, x1), .y = @max(y0, y1) },
                .filled = filled,
                .style = charting.inlineStyle(style),
                .glyph = glyph,
            },
        });
    }

    pub fn drawText(self: *Canvas, x: f64, y: f64, text: []const u8, style: Style) !void {
        try self.operations.append(.{
            .text = .{
                .origin = .{ .x = x, .y = y },
                .text = text,
                .style = charting.inlineStyle(style),
            },
        });
    }

    pub fn view(self: *const Canvas, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.marker) {
            .braille => self.renderBraille(allocator),
            .block, .dot, .ascii => self.renderCells(allocator),
        };
    }

    pub fn drawIntoBuffer(self: *const Canvas, buffer: *charting.CellBuffer) void {
        switch (self.marker) {
            .braille => self.drawBrailleIntoBuffer(buffer),
            .block, .dot, .ascii => self.drawCellIntoBuffer(buffer),
        }
    }

    fn renderCells(self: *const Canvas, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = try charting.CellBuffer.init(allocator, self.width, self.height);
        defer buffer.deinit();

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                buffer.setSlice(x, y, self.background_glyph, null);
            }
        }

        self.drawCellIntoBuffer(&buffer);

        return try buffer.render(allocator);
    }

    fn renderBraille(self: *const Canvas, allocator: std.mem.Allocator) ![]const u8 {
        const cell_count = @as(usize, self.width) * @as(usize, self.height);
        const braille_cells = try allocator.alloc(BrailleCell, cell_count);
        defer allocator.free(braille_cells);
        for (braille_cells) |*cell| cell.* = .{};

        var overlay = try charting.CellBuffer.init(allocator, self.width, self.height);
        defer overlay.deinit();

        for (self.operations.items) |op| {
            switch (op) {
                .point => |point_op| {
                    const x = charting.mapX(point_op.point.x, self.x_range, @as(usize, self.width) * 2);
                    const y = charting.mapY(point_op.point.y, self.y_range, @as(usize, self.height) * 4);
                    setBraillePixel(braille_cells, self.width, x, y, point_op.style);
                },
                .line => |line_op| {
                    const x0 = charting.mapX(line_op.from.x, self.x_range, @as(usize, self.width) * 2);
                    const y0 = charting.mapY(line_op.from.y, self.y_range, @as(usize, self.height) * 4);
                    const x1 = charting.mapX(line_op.to.x, self.x_range, @as(usize, self.width) * 2);
                    const y1 = charting.mapY(line_op.to.y, self.y_range, @as(usize, self.height) * 4);
                    drawBrailleLine(braille_cells, self.width, x0, y0, x1, y1, line_op.style);
                },
                .rect => |rect_op| {
                    const min_x = charting.mapX(rect_op.min.x, self.x_range, @as(usize, self.width) * 2);
                    const min_y = charting.mapY(rect_op.max.y, self.y_range, @as(usize, self.height) * 4);
                    const max_x = charting.mapX(rect_op.max.x, self.x_range, @as(usize, self.width) * 2);
                    const max_y = charting.mapY(rect_op.min.y, self.y_range, @as(usize, self.height) * 4);
                    drawBrailleRect(braille_cells, self.width, min_x, min_y, max_x, max_y, rect_op.filled, rect_op.style);
                },
                .text => |text_op| {
                    const x = charting.mapX(text_op.origin.x, self.x_range, self.width);
                    const y = charting.mapY(text_op.origin.y, self.y_range, self.height);
                    overlay.writeText(x, y, text_op.text, text_op.style);
                },
            }
        }

        var final = try charting.CellBuffer.init(allocator, self.width, self.height);
        defer final.deinit();

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = braille_cells[y * self.width + x];
                if (cell.bits == 0) {
                    final.setSlice(x, y, self.background_glyph, null);
                } else {
                    final.setCodepoint(x, y, @as(u21, 0x2800) + cell.bits, cell.style);
                }
            }
        }

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = overlay.cells[y * self.width + x];
                if (glyphIsBlank(cell.glyph)) continue;
                final.cells[y * self.width + x] = cell;
            }
        }

        return try final.render(allocator);
    }

    fn drawCellIntoBuffer(self: *const Canvas, buffer: *charting.CellBuffer) void {
        for (self.operations.items) |op| {
            switch (op) {
                .point => |point_op| {
                    const x = charting.mapX(point_op.point.x, self.x_range, self.width);
                    const y = charting.mapY(point_op.point.y, self.y_range, self.height);
                    buffer.setSlice(x, y, point_op.glyph orelse self.defaultCellGlyph(), point_op.style);
                },
                .line => |line_op| {
                    const x0 = charting.mapX(line_op.from.x, self.x_range, self.width);
                    const y0 = charting.mapY(line_op.from.y, self.y_range, self.height);
                    const x1 = charting.mapX(line_op.to.x, self.x_range, self.width);
                    const y1 = charting.mapY(line_op.to.y, self.y_range, self.height);
                    drawLineCells(buffer, x0, y0, x1, y1, line_op.glyph orelse self.lineCellGlyph(), line_op.style);
                },
                .rect => |rect_op| {
                    const min_x = charting.mapX(rect_op.min.x, self.x_range, self.width);
                    const min_y = charting.mapY(rect_op.max.y, self.y_range, self.height);
                    const max_x = charting.mapX(rect_op.max.x, self.x_range, self.width);
                    const max_y = charting.mapY(rect_op.min.y, self.y_range, self.height);
                    drawRectCells(buffer, min_x, min_y, max_x, max_y, rect_op.filled, rect_op.glyph orelse self.lineCellGlyph(), rect_op.style);
                },
                .text => |text_op| {
                    const x = charting.mapX(text_op.origin.x, self.x_range, self.width);
                    const y = charting.mapY(text_op.origin.y, self.y_range, self.height);
                    buffer.writeText(x, y, text_op.text, text_op.style);
                },
            }
        }
    }

    fn drawBrailleIntoBuffer(self: *const Canvas, buffer: *charting.CellBuffer) void {
        const cell_count = @as(usize, self.width) * @as(usize, self.height);
        const braille_cells = buffer.allocator.alloc(BrailleCell, cell_count) catch return;
        defer buffer.allocator.free(braille_cells);
        for (braille_cells) |*cell| cell.* = .{};

        for (self.operations.items) |op| {
            switch (op) {
                .point => |point_op| {
                    const x = charting.mapX(point_op.point.x, self.x_range, @as(usize, self.width) * 2);
                    const y = charting.mapY(point_op.point.y, self.y_range, @as(usize, self.height) * 4);
                    setBraillePixel(braille_cells, self.width, x, y, point_op.style);
                },
                .line => |line_op| {
                    const x0 = charting.mapX(line_op.from.x, self.x_range, @as(usize, self.width) * 2);
                    const y0 = charting.mapY(line_op.from.y, self.y_range, @as(usize, self.height) * 4);
                    const x1 = charting.mapX(line_op.to.x, self.x_range, @as(usize, self.width) * 2);
                    const y1 = charting.mapY(line_op.to.y, self.y_range, @as(usize, self.height) * 4);
                    drawBrailleLine(braille_cells, self.width, x0, y0, x1, y1, line_op.style);
                },
                .rect => |rect_op| {
                    const min_x = charting.mapX(rect_op.min.x, self.x_range, @as(usize, self.width) * 2);
                    const min_y = charting.mapY(rect_op.max.y, self.y_range, @as(usize, self.height) * 4);
                    const max_x = charting.mapX(rect_op.max.x, self.x_range, @as(usize, self.width) * 2);
                    const max_y = charting.mapY(rect_op.min.y, self.y_range, @as(usize, self.height) * 4);
                    drawBrailleRect(braille_cells, self.width, min_x, min_y, max_x, max_y, rect_op.filled, rect_op.style);
                },
                .text => |text_op| {
                    const x = charting.mapX(text_op.origin.x, self.x_range, self.width);
                    const y = charting.mapY(text_op.origin.y, self.y_range, self.height);
                    buffer.writeText(x, y, text_op.text, text_op.style);
                },
            }
        }

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = braille_cells[y * self.width + x];
                if (cell.bits == 0) continue;
                buffer.setCodepoint(x, y, @as(u21, 0x2800) + cell.bits, cell.style);
            }
        }
    }

    fn defaultCellGlyph(self: *const Canvas) []const u8 {
        return switch (self.marker) {
            .braille => "•",
            .block => if (self.point_glyph.len > 0) self.point_glyph else "█",
            .dot => if (self.point_glyph.len > 0) self.point_glyph else "•",
            .ascii => if (self.point_glyph.len > 0) self.point_glyph else "*",
        };
    }

    fn lineCellGlyph(self: *const Canvas) []const u8 {
        return switch (self.marker) {
            .braille => "•",
            .block => if (self.line_glyph.len > 0) self.line_glyph else "█",
            .dot => if (self.line_glyph.len > 0) self.line_glyph else "•",
            .ascii => if (self.line_glyph.len > 0) self.line_glyph else "*",
        };
    }
};

fn glyphIsBlank(glyph: charting.Glyph) bool {
    return switch (glyph) {
        .slice => |slice| slice.len == 0 or std.mem.eql(u8, slice, " "),
        .codepoint => |cp| cp == ' ' or cp == 0x2800,
    };
}

fn drawLineCells(buffer: *charting.CellBuffer, x0: usize, y0: usize, x1: usize, y1: usize, glyph: []const u8, style: ?Style) void {
    const dx = @as(isize, @intCast(x1)) - @as(isize, @intCast(x0));
    const dy = @as(isize, @intCast(y1)) - @as(isize, @intCast(y0));
    const steps = @max(@abs(dx), @abs(dy));
    if (steps == 0) {
        buffer.setSlice(x0, y0, glyph, style);
        return;
    }

    const step_x = @as(f64, @floatFromInt(dx)) / @as(f64, @floatFromInt(steps));
    const step_y = @as(f64, @floatFromInt(dy)) / @as(f64, @floatFromInt(steps));

    var x = @as(f64, @floatFromInt(x0));
    var y = @as(f64, @floatFromInt(y0));
    var i: usize = 0;
    while (i <= @as(usize, @intCast(steps))) : (i += 1) {
        buffer.setSlice(
            @as(usize, @intFromFloat(@round(x))),
            @as(usize, @intFromFloat(@round(y))),
            glyph,
            style,
        );
        x += step_x;
        y += step_y;
    }
}

fn drawRectCells(buffer: *charting.CellBuffer, min_x: usize, min_y: usize, max_x: usize, max_y: usize, filled: bool, glyph: []const u8, style: ?Style) void {
    const left = @min(min_x, max_x);
    const right = @max(min_x, max_x);
    const top = @min(min_y, max_y);
    const bottom = @max(min_y, max_y);

    if (filled) {
        for (top..bottom + 1) |y| {
            for (left..right + 1) |x| {
                buffer.setSlice(x, y, glyph, style);
            }
        }
        return;
    }

    drawLineCells(buffer, left, top, right, top, glyph, style);
    drawLineCells(buffer, left, bottom, right, bottom, glyph, style);
    drawLineCells(buffer, left, top, left, bottom, glyph, style);
    drawLineCells(buffer, right, top, right, bottom, glyph, style);
}

fn setBraillePixel(cells: []Canvas.BrailleCell, width: u16, x: usize, y: usize, style: ?Style) void {
    const cell_x = x / 2;
    const cell_y = y / 4;
    if (cell_x >= width) return;
    const height = if (width == 0) 0 else cells.len / width;
    if (cell_y >= height) return;

    const local_x = x % 2;
    const local_y = y % 4;

    const bit = switch (local_x) {
        0 => switch (local_y) {
            0 => @as(u8, 0x01),
            1 => @as(u8, 0x02),
            2 => @as(u8, 0x04),
            else => @as(u8, 0x40),
        },
        else => switch (local_y) {
            0 => @as(u8, 0x08),
            1 => @as(u8, 0x10),
            2 => @as(u8, 0x20),
            else => @as(u8, 0x80),
        },
    };

    const index = cell_y * width + cell_x;
    cells[index].bits |= bit;
    cells[index].style = style;
}

fn drawBrailleLine(cells: []Canvas.BrailleCell, width: u16, x0: usize, y0: usize, x1: usize, y1: usize, style: ?Style) void {
    const dx = @as(isize, @intCast(x1)) - @as(isize, @intCast(x0));
    const dy = @as(isize, @intCast(y1)) - @as(isize, @intCast(y0));
    const steps = @max(@abs(dx), @abs(dy));
    if (steps == 0) {
        setBraillePixel(cells, width, x0, y0, style);
        return;
    }

    const step_x = @as(f64, @floatFromInt(dx)) / @as(f64, @floatFromInt(steps));
    const step_y = @as(f64, @floatFromInt(dy)) / @as(f64, @floatFromInt(steps));

    var x = @as(f64, @floatFromInt(x0));
    var y = @as(f64, @floatFromInt(y0));
    var i: usize = 0;
    while (i <= @as(usize, @intCast(steps))) : (i += 1) {
        setBraillePixel(
            cells,
            width,
            @as(usize, @intFromFloat(@round(x))),
            @as(usize, @intFromFloat(@round(y))),
            style,
        );
        x += step_x;
        y += step_y;
    }
}

fn drawBrailleRect(cells: []Canvas.BrailleCell, width: u16, min_x: usize, min_y: usize, max_x: usize, max_y: usize, filled: bool, style: ?Style) void {
    const left = @min(min_x, max_x);
    const right = @max(min_x, max_x);
    const top = @min(min_y, max_y);
    const bottom = @max(min_y, max_y);

    if (filled) {
        for (top..bottom + 1) |y| {
            for (left..right + 1) |x| {
                setBraillePixel(cells, width, x, y, style);
            }
        }
        return;
    }

    drawBrailleLine(cells, width, left, top, right, top, style);
    drawBrailleLine(cells, width, left, bottom, right, bottom, style);
    drawBrailleLine(cells, width, left, top, left, bottom, style);
    drawBrailleLine(cells, width, right, top, right, bottom, style);
}
