//! Sparkline component with configurable aggregation and styling.

const std = @import("std");
const charting = @import("charting.zig");
const progress = @import("progress.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Style = style_mod.Style;
pub const Summary = charting.Summary;
pub const DataRange = charting.DataRange;

pub const Sparkline = struct {
    allocator: std.mem.Allocator,
    data: std.array_list.Managed(f64),
    display_width: u16,
    summary: Summary,
    retention_limit: ?usize,
    spark_style: Style,
    empty_char: []const u8,
    glyphs: []const []const u8,
    fixed_range: ?DataRange,
    gradient_start: ?Color,
    gradient_end: ?Color,

    const default_glyphs = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

    pub fn init(allocator: std.mem.Allocator) Sparkline {
        return .{
            .allocator = allocator,
            .data = std.array_list.Managed(f64).init(allocator),
            .display_width = 40,
            .summary = .last,
            .retention_limit = 40,
            .spark_style = blk: {
                var s = Style{};
                s = s.fg(Color.green());
                break :blk charting.inlineStyle(s);
            },
            .empty_char = " ",
            .glyphs = default_glyphs[0..],
            .fixed_range = null,
            .gradient_start = null,
            .gradient_end = null,
        };
    }

    pub fn deinit(self: *Sparkline) void {
        self.data.deinit();
    }

    pub fn push(self: *Sparkline, value: f64) !void {
        try self.data.append(value);
        self.enforceRetention();
    }

    pub fn setData(self: *Sparkline, data: []const f64) !void {
        self.data.clearRetainingCapacity();
        try self.data.appendSlice(data);
        self.enforceRetention();
    }

    pub fn clear(self: *Sparkline) void {
        self.data.clearRetainingCapacity();
    }

    pub fn setWidth(self: *Sparkline, width: u16) void {
        self.display_width = @max(1, width);
        if (self.retention_limit) |limit| {
            if (limit < self.display_width) {
                self.retention_limit = self.display_width;
            }
        }
        self.enforceRetention();
    }

    pub fn setSummary(self: *Sparkline, summary: Summary) void {
        self.summary = summary;
    }

    pub fn setRetentionLimit(self: *Sparkline, limit: ?usize) void {
        self.retention_limit = if (limit) |value| @max(value, self.display_width) else null;
        self.enforceRetention();
    }

    pub fn setStyle(self: *Sparkline, style: Style) void {
        self.spark_style = charting.inlineStyle(style);
    }

    pub fn setEmptyChar(self: *Sparkline, empty_char: []const u8) void {
        self.empty_char = empty_char;
    }

    pub fn setGlyphs(self: *Sparkline, glyphs: []const []const u8) void {
        if (glyphs.len > 0) self.glyphs = glyphs;
    }

    pub fn setRange(self: *Sparkline, range: ?DataRange) void {
        self.fixed_range = if (range) |value| value.normalized() else null;
    }

    pub fn setGradient(self: *Sparkline, start: ?Color, end: ?Color) void {
        self.gradient_start = start;
        self.gradient_end = end;
    }

    pub fn view(self: *const Sparkline, allocator: std.mem.Allocator) ![]const u8 {
        if (self.display_width == 0) return try allocator.dupe(u8, "");

        var visible = try self.bucketValues(allocator);
        defer visible.deinit();

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        if (visible.items.len == 0) {
            for (0..self.display_width) |_| try writer.writeAll(self.empty_char);
            return try result.toOwnedSlice();
        }

        const range = self.fixed_range orelse self.computeRange(visible.items);
        const glyph_count = self.glyphs.len;
        const max_index = glyph_count - 1;

        for (visible.items, 0..) |value, index| {
            const normalized = if (range.span() > 0)
                charting.clampUnit((value - range.min) / range.span())
            else
                0.5;

            const glyph_index = @min(max_index, @as(usize, @intFromFloat(@round(normalized * @as(f64, @floatFromInt(max_index))))));
            const glyph = self.glyphs[glyph_index];

            if (self.gradient_start != null and self.gradient_end != null) {
                const t = if (visible.items.len <= 1) 0.0 else @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(visible.items.len - 1));
                const color = progress.interpolateColor(self.gradient_start.?, self.gradient_end.?, t);
                var style = self.spark_style.fg(color);
                style = charting.inlineStyle(style);
                const rendered = try style.render(allocator, glyph);
                defer allocator.free(rendered);
                try writer.writeAll(rendered);
            } else {
                const rendered = try self.spark_style.render(allocator, glyph);
                defer allocator.free(rendered);
                try writer.writeAll(rendered);
            }
        }

        if (visible.items.len < self.display_width) {
            for (0..(@as(usize, self.display_width) - visible.items.len)) |_| {
                try writer.writeAll(self.empty_char);
            }
        }

        return try result.toOwnedSlice();
    }

    fn enforceRetention(self: *Sparkline) void {
        if (self.retention_limit) |limit| {
            while (self.data.items.len > limit) {
                _ = self.data.orderedRemove(0);
            }
        }
    }

    fn bucketValues(self: *const Sparkline, allocator: std.mem.Allocator) !std.array_list.Managed(f64) {
        var buckets = std.array_list.Managed(f64).init(allocator);
        const width = @as(usize, self.display_width);
        if (self.data.items.len == 0 or width == 0) return buckets;

        if (self.data.items.len <= width) {
            try buckets.appendSlice(self.data.items);
            return buckets;
        }

        const data_len_f = @as(f64, @floatFromInt(self.data.items.len));
        const width_f = @as(f64, @floatFromInt(width));

        for (0..width) |bucket_index| {
            const start = @min(self.data.items.len, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(bucket_index)) * data_len_f / width_f))));
            const end = @min(self.data.items.len, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(bucket_index + 1)) * data_len_f / width_f))));
            const slice = if (end > start) self.data.items[start..end] else self.data.items[start .. @min(self.data.items.len, start + 1)];
            try buckets.append(summarize(slice, self.summary));
        }

        return buckets;
    }

    fn computeRange(self: *const Sparkline, values: []const f64) DataRange {
        _ = self;
        var min_value = values[0];
        var max_value = values[0];
        for (values[1..]) |value| {
            min_value = @min(min_value, value);
            max_value = @max(max_value, value);
        }
        const range = DataRange{ .min = min_value, .max = max_value };
        return range.normalized();
    }
};

fn summarize(values: []const f64, summary: Summary) f64 {
    if (values.len == 0) return 0;

    return switch (summary) {
        .last => values[values.len - 1],
        .average => blk: {
            var total: f64 = 0;
            for (values) |value| total += value;
            break :blk total / @as(f64, @floatFromInt(values.len));
        },
        .minimum => blk: {
            var value = values[0];
            for (values[1..]) |item| value = @min(value, item);
            break :blk value;
        },
        .maximum => blk: {
            var value = values[0];
            for (values[1..]) |item| value = @max(value, item);
            break :blk value;
        },
        .sum => blk: {
            var total: f64 = 0;
            for (values) |value| total += value;
            break :blk total;
        },
    };
}
