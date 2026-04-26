//! Bar chart widget with vertical and horizontal layouts.

const std = @import("std");
const charting = @import("charting.zig");
const measure = @import("../layout/measure.zig");
const join = @import("../layout/join.zig");
const style_mod = @import("../style/style.zig");

pub const Style = style_mod.Style;
pub const DataRange = charting.DataRange;
pub const Orientation = charting.Orientation;
pub const ValueFormatter = charting.ValueFormatter;

pub const Bar = struct {
    allocator: std.mem.Allocator,
    label: []const u8,
    value: f64,
    style: ?Style = null,
    glyph: []const u8 = "█",

    pub fn init(allocator: std.mem.Allocator, label: []const u8, value: f64) !Bar {
        return .{
            .allocator = allocator,
            .label = try allocator.dupe(u8, label),
            .value = value,
        };
    }

    pub fn deinit(self: *Bar) void {
        self.allocator.free(self.label);
    }

    pub fn setStyle(self: *Bar, style: Style) void {
        self.style = charting.inlineStyle(style);
    }

    pub fn setGlyph(self: *Bar, glyph: []const u8) void {
        self.glyph = glyph;
    }
};

pub const BarChart = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    orientation: Orientation,
    bars: std.array_list.Managed(Bar),
    bar_width: u16,
    gap: u16,
    domain: ?DataRange,
    baseline: f64,
    show_labels: bool,
    show_values: bool,
    axis_style: Style,
    label_style: Style,
    value_style: Style,
    positive_style: Style,
    negative_style: Style,
    formatter: ?ValueFormatter,

    pub fn init(allocator: std.mem.Allocator) BarChart {
        return .{
            .allocator = allocator,
            .width = 40,
            .height = 12,
            .orientation = .vertical,
            .bars = std.array_list.Managed(Bar).init(allocator),
            .bar_width = 2,
            .gap = 1,
            .domain = null,
            .baseline = 0,
            .show_labels = true,
            .show_values = false,
            .axis_style = charting.inlineStyle(Style{}),
            .label_style = charting.inlineStyle(Style{}),
            .value_style = charting.inlineStyle(Style{}),
            .positive_style = charting.inlineStyle(Style{}),
            .negative_style = charting.inlineStyle(Style{}),
            .formatter = null,
        };
    }

    pub fn deinit(self: *BarChart) void {
        for (self.bars.items) |*bar| bar.deinit();
        self.bars.deinit();
    }

    pub fn clear(self: *BarChart) void {
        for (self.bars.items) |*bar| bar.deinit();
        self.bars.clearRetainingCapacity();
    }

    pub fn addBar(self: *BarChart, bar: Bar) !void {
        try self.bars.append(bar);
    }

    pub fn setSize(self: *BarChart, width: u16, height: u16) void {
        self.width = @max(8, width);
        self.height = @max(4, height);
    }

    pub fn setOrientation(self: *BarChart, orientation: Orientation) void {
        self.orientation = orientation;
    }

    pub fn setBarWidth(self: *BarChart, bar_width: u16) void {
        self.bar_width = @max(1, bar_width);
    }

    pub fn setGap(self: *BarChart, gap: u16) void {
        self.gap = gap;
    }

    pub fn setDomain(self: *BarChart, domain: ?DataRange) void {
        self.domain = if (domain) |d| d.normalized() else null;
    }

    pub fn setBaseline(self: *BarChart, baseline: f64) void {
        self.baseline = baseline;
    }

    pub fn setFormatter(self: *BarChart, formatter: ?ValueFormatter) void {
        self.formatter = formatter;
    }

    pub fn view(self: *const BarChart, allocator: std.mem.Allocator) ![]const u8 {
        if (self.bars.items.len == 0) return try allocator.dupe(u8, "");

        return switch (self.orientation) {
            .vertical => self.renderVertical(allocator),
            .horizontal => self.renderHorizontal(allocator),
        };
    }

    fn resolvedDomain(self: *const BarChart) DataRange {
        if (self.domain) |domain| return domain.normalized();

        var min_value = self.baseline;
        var max_value = self.baseline;
        for (self.bars.items) |bar| {
            min_value = @min(min_value, bar.value);
            max_value = @max(max_value, bar.value);
        }

        const range = DataRange{ .min = min_value, .max = max_value };
        return range.normalized();
    }

    fn renderVertical(self: *const BarChart, allocator: std.mem.Allocator) ![]const u8 {
        const domain = self.resolvedDomain();
        const label_rows: usize = if (self.show_labels) 1 else 0;
        const plot_height = @max(@as(usize, 1), @as(usize, self.height) -| label_rows);
        const total_slot_width = @as(usize, self.bar_width) + @as(usize, self.gap);
        const plot_width = @max(@as(usize, self.width), self.bars.items.len * total_slot_width);

        var buffer = try charting.CellBuffer.init(allocator, plot_width, plot_height);
        defer buffer.deinit();
        var owned_values = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (owned_values.items) |value| allocator.free(value);
            owned_values.deinit();
        }
        for (0..plot_height) |y| for (0..plot_width) |x| buffer.setSlice(x, y, " ", null);

        const baseline_row = charting.mapY(self.baseline, domain, plot_height);
        for (0..plot_width) |x| buffer.setSlice(x, baseline_row, "─", self.axis_style);

        for (self.bars.items, 0..) |bar, index| {
            const start_x = index * total_slot_width;
            const end_x = @min(plot_width, start_x + @as(usize, self.bar_width));
            const target_row = charting.mapY(bar.value, domain, plot_height);
            const top = @min(target_row, baseline_row);
            const bottom = @max(target_row, baseline_row);
            const bar_style = bar.style orelse if (bar.value >= self.baseline) self.positive_style else self.negative_style;

            for (top..bottom + 1) |y| {
                for (start_x..end_x) |x| {
                    buffer.setSlice(x, y, bar.glyph, bar_style);
                }
            }

            if (self.show_values) {
                const label = try self.formatValue(allocator, bar.value);
                try owned_values.append(label);
                const row = if (bar.value >= self.baseline) top -| 1 else @min(plot_height - 1, bottom + 1);
                const start = start_x + ((end_x - start_x) -| measure.width(label)) / 2;
                buffer.writeText(start, row, label, self.value_style);
            }
        }

        const plot = try buffer.render(allocator);
        defer allocator.free(plot);
        if (!self.show_labels) return try allocator.dupe(u8, plot);

        var label_row = try charting.CellBuffer.init(allocator, plot_width, 1);
        defer label_row.deinit();
        var owned_labels = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (owned_labels.items) |label| allocator.free(label);
            owned_labels.deinit();
        }
        for (0..plot_width) |x| label_row.setSlice(x, 0, " ", null);

        for (self.bars.items, 0..) |bar, index| {
            const start_x = index * total_slot_width;
            const label_width = measure.width(bar.label);
            const label_start = start_x + (@as(usize, self.bar_width) -| @min(label_width, @as(usize, self.bar_width))) / 2;
            const clipped = try truncateLabel(allocator, bar.label, @as(usize, self.bar_width));
            try owned_labels.append(clipped);
            label_row.writeText(label_start, 0, clipped, self.label_style);
        }

        const labels = try label_row.render(allocator);
        defer allocator.free(labels);
        return try join.vertical(allocator, .left, &.{ plot, labels });
    }

    fn renderHorizontal(self: *const BarChart, allocator: std.mem.Allocator) ![]const u8 {
        const domain = self.resolvedDomain();
        const label_width = if (self.show_labels) self.maxLabelWidth() else 0;
        const label_offset: usize = label_width + (if (label_width > 0) @as(usize, 1) else 0);
        const plot_width = @max(@as(usize, 1), @as(usize, self.width) -| label_offset);
        const total_slot_height = @as(usize, self.bar_width) + @as(usize, self.gap);
        const plot_height = @max(@as(usize, self.height), self.bars.items.len * total_slot_height);

        var buffer = try charting.CellBuffer.init(allocator, label_offset + plot_width, plot_height);
        defer buffer.deinit();
        var owned_values = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (owned_values.items) |value| allocator.free(value);
            owned_values.deinit();
        }
        for (0..buffer.height) |y| for (0..buffer.width) |x| buffer.setSlice(x, y, " ", null);

        const offset = label_offset;
        const baseline_col = offset + charting.mapX(self.baseline, domain, plot_width);
        for (0..plot_height) |y| buffer.setSlice(baseline_col, y, "│", self.axis_style);

        for (self.bars.items, 0..) |bar, index| {
            const start_y = index * total_slot_height;
            const end_y = @min(plot_height, start_y + @as(usize, self.bar_width));
            const target_col = offset + charting.mapX(bar.value, domain, plot_width);
            const left = @min(target_col, baseline_col);
            const right = @max(target_col, baseline_col);
            const bar_style = bar.style orelse if (bar.value >= self.baseline) self.positive_style else self.negative_style;

            for (start_y..end_y) |y| {
                if (self.show_labels and y == start_y) {
                    buffer.writeText(0, y, bar.label, self.label_style);
                }

                for (left..right + 1) |x| {
                    buffer.setSlice(x, y, bar.glyph, bar_style);
                }

                if (self.show_values and y == start_y) {
                    const value_text = try self.formatValue(allocator, bar.value);
                    try owned_values.append(value_text);
                    const text_x = if (bar.value >= self.baseline)
                        @min(buffer.width - measure.width(value_text), right + 1)
                    else
                        @max(offset, left -| (measure.width(value_text) + 1));
                    buffer.writeText(text_x, y, value_text, self.value_style);
                }
            }
        }

        return try buffer.render(allocator);
    }

    fn maxLabelWidth(self: *const BarChart) usize {
        var max_width: usize = 0;
        for (self.bars.items) |bar| {
            max_width = @max(max_width, measure.width(bar.label));
        }
        return max_width;
    }

    fn formatValue(self: *const BarChart, allocator: std.mem.Allocator, value: f64) ![]const u8 {
        const formatter = self.formatter orelse charting.defaultFormatter;
        return try formatter(allocator, value);
    }
};

fn truncateLabel(allocator: std.mem.Allocator, label: []const u8, width: usize) ![]const u8 {
    if (width == 0) return try allocator.dupe(u8, "");
    if (measure.width(label) <= width) return try allocator.dupe(u8, label);
    return try measure.truncate(allocator, label, width);
}
