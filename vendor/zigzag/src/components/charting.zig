//! Shared plotting primitives for chart-like components.

const std = @import("std");
const measure = @import("../layout/measure.zig");
const style_mod = @import("../style/style.zig");

pub const Style = style_mod.Style;

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const DataRange = struct {
    min: f64,
    max: f64,

    pub fn normalized(self: DataRange) DataRange {
        if (!std.math.isFinite(self.min) or !std.math.isFinite(self.max)) {
            return .{ .min = 0, .max = 1 };
        }

        if (self.min == self.max) {
            return .{
                .min = self.min - 0.5,
                .max = self.max + 0.5,
            };
        }

        if (self.min < self.max) return self;

        return .{
            .min = self.max,
            .max = self.min,
        };
    }

    pub fn span(self: DataRange) f64 {
        const normalized_range = self.normalized();
        return normalized_range.max - normalized_range.min;
    }
};

pub const Marker = enum {
    braille,
    block,
    dot,
    ascii,
};

pub const GraphType = enum {
    line,
    scatter,
    area,
};

pub const Interpolation = enum {
    linear,
    step_start,
    step_center,
    step_end,
    catmull_rom,
    monotone_cubic,
};

pub const Orientation = enum {
    vertical,
    horizontal,
};

pub const Summary = enum {
    last,
    average,
    minimum,
    maximum,
    sum,
};

pub const LegendPosition = enum {
    hidden,
    top,
    bottom,
    left,
    right,
};

pub const AxisLabel = struct {
    value: f64,
    text: []const u8,
};

pub const ValueFormatter = *const fn (std.mem.Allocator, f64) anyerror![]const u8;

pub const Glyph = union(enum) {
    slice: []const u8,
    codepoint: u21,
};

pub const Cell = struct {
    glyph: Glyph = .{ .slice = " " },
    style: ?Style = null,
};

pub const CellBuffer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !CellBuffer {
        const cells = try allocator.alloc(Cell, width * height);
        for (cells) |*cell| cell.* = .{};

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
        };
    }

    pub fn deinit(self: *CellBuffer) void {
        self.allocator.free(self.cells);
    }

    pub fn clear(self: *CellBuffer) void {
        for (self.cells) |*cell| cell.* = .{};
    }

    fn index(self: *const CellBuffer, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    pub fn setGlyph(self: *CellBuffer, x: usize, y: usize, glyph: Glyph, style: ?Style) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[self.index(x, y)] = .{
            .glyph = glyph,
            .style = style,
        };
    }

    pub fn setSlice(self: *CellBuffer, x: usize, y: usize, glyph: []const u8, style: ?Style) void {
        self.setGlyph(x, y, .{ .slice = glyph }, style);
    }

    pub fn setCodepoint(self: *CellBuffer, x: usize, y: usize, codepoint: u21, style: ?Style) void {
        self.setGlyph(x, y, .{ .codepoint = codepoint }, style);
    }

    pub fn writeText(self: *CellBuffer, x: usize, y: usize, text: []const u8, style: ?Style) void {
        if (y >= self.height) return;

        var col = x;
        var i: usize = 0;
        while (i < text.len and col < self.width) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const end = @min(text.len, i + byte_len);
            const glyph = text[i..end];

            var codepoint_width: usize = 1;
            if (end <= text.len) {
                const cp = std.unicode.utf8Decode(glyph) catch 0;
                if (cp != 0) {
                    codepoint_width = @max(1, measure.charWidth(cp));
                }
            }

            self.setSlice(col, y, glyph, style);
            if (codepoint_width > 1) {
                var extra: usize = 1;
                while (extra < codepoint_width and col + extra < self.width) : (extra += 1) {
                    self.setSlice(col + extra, y, " ", style);
                }
            }

            col += codepoint_width;
            i = end;
        }
    }

    pub fn render(self: *const CellBuffer, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        var glyph_buf: [4]u8 = undefined;

        for (0..self.height) |y| {
            if (y > 0) try writer.writeByte('\n');

            for (0..self.width) |x| {
                const cell = self.cells[self.index(x, y)];
                const glyph = switch (cell.glyph) {
                    .slice => |slice| slice,
                    .codepoint => |cp| blk: {
                        const len = try std.unicode.utf8Encode(cp, &glyph_buf);
                        break :blk glyph_buf[0..len];
                    },
                };

                if (cell.style) |base_style| {
                    var inline_style = base_style.inline_style(true);
                    const rendered = try inline_style.render(allocator, glyph);
                    defer allocator.free(rendered);
                    try writer.writeAll(rendered);
                } else {
                    try writer.writeAll(glyph);
                }
            }
        }

        return try result.toOwnedSlice();
    }
};

pub fn inlineStyle(style: Style) Style {
    return style.inline_style(true);
}

pub fn clampUnit(value: f64) f64 {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

pub fn mapToResolution(value: f64, range: DataRange, resolution: usize) usize {
    if (resolution <= 1) return 0;

    const normalized = range.normalized();
    const span = normalized.max - normalized.min;
    if (span <= 0) return 0;

    const unit = clampUnit((value - normalized.min) / span);
    return @intFromFloat(@round(unit * @as(f64, @floatFromInt(resolution - 1))));
}

pub fn mapX(value: f64, range: DataRange, width: usize) usize {
    return mapToResolution(value, range, width);
}

pub fn mapY(value: f64, range: DataRange, height: usize) usize {
    if (height <= 1) return 0;
    const mapped = mapToResolution(value, range, height);
    return (height - 1) - mapped;
}

pub fn defaultFormatter(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    if (value == @trunc(value)) {
        return try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(value))});
    }

    return try std.fmt.allocPrint(allocator, "{d:.2}", .{value});
}
