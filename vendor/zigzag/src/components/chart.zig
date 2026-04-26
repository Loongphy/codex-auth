//! Cartesian chart widget with axes, legend, and multiple datasets.

const std = @import("std");
const charting = @import("charting.zig");
const canvas_mod = @import("canvas.zig");
const join = @import("../layout/join.zig");
const measure = @import("../layout/measure.zig");
const style_mod = @import("../style/style.zig");

pub const Style = style_mod.Style;
pub const AxisLabel = charting.AxisLabel;
pub const DataRange = charting.DataRange;
pub const GraphType = charting.GraphType;
pub const Interpolation = charting.Interpolation;
pub const LegendPosition = charting.LegendPosition;
pub const Marker = charting.Marker;
pub const Point = charting.Point;
pub const ValueFormatter = charting.ValueFormatter;

pub const Axis = struct {
    title: []const u8 = "",
    bounds: ?DataRange = null,
    labels: []const AxisLabel = &.{},
    tick_count: u8 = 5,
    show_line: bool = true,
    show_labels: bool = true,
    show_grid: bool = false,
    style: Style = charting.inlineStyle(Style{}),
    label_style: Style = charting.inlineStyle(Style{}),
    title_style: Style = charting.inlineStyle((Style{}).bold(true)),
    grid_style: Style = charting.inlineStyle(Style{}),
    formatter: ?ValueFormatter = null,
};

pub const Dataset = struct {
    allocator: std.mem.Allocator,
    label: []const u8,
    points: std.array_list.Managed(Point),
    style: Style,
    graph_type: GraphType,
    interpolation: Interpolation,
    interpolation_steps: u8,
    curve_tension: f64,
    show_points: bool,
    point_glyph: ?[]const u8,
    fill_to: ?f64,

    pub fn init(allocator: std.mem.Allocator, label: []const u8) !Dataset {
        return .{
            .allocator = allocator,
            .label = try allocator.dupe(u8, label),
            .points = std.array_list.Managed(Point).init(allocator),
            .style = charting.inlineStyle(Style{}),
            .graph_type = .line,
            .interpolation = .linear,
            .interpolation_steps = 8,
            .curve_tension = 0.5,
            .show_points = false,
            .point_glyph = null,
            .fill_to = null,
        };
    }

    pub fn deinit(self: *Dataset) void {
        self.allocator.free(self.label);
        self.points.deinit();
    }

    pub fn setStyle(self: *Dataset, style: Style) void {
        self.style = charting.inlineStyle(style);
    }

    pub fn setGraphType(self: *Dataset, graph_type: GraphType) void {
        self.graph_type = graph_type;
    }

    pub fn setInterpolation(self: *Dataset, interpolation: Interpolation) void {
        self.interpolation = interpolation;
    }

    pub fn setInterpolationSteps(self: *Dataset, steps: u8) void {
        self.interpolation_steps = @max(@as(u8, 1), steps);
    }

    pub fn setCurveTension(self: *Dataset, tension: f64) void {
        self.curve_tension = std.math.clamp(tension, 0.0, 1.0);
    }

    pub fn setShowPoints(self: *Dataset, show_points: bool) void {
        self.show_points = show_points;
    }

    pub fn setPointGlyph(self: *Dataset, glyph: ?[]const u8) void {
        self.point_glyph = glyph;
    }

    pub fn setFillBaseline(self: *Dataset, baseline: ?f64) void {
        self.fill_to = baseline;
    }

    pub fn appendPoint(self: *Dataset, point: Point) !void {
        try self.points.append(point);
    }

    pub fn setPoints(self: *Dataset, points: []const Point) !void {
        self.points.clearRetainingCapacity();
        try self.points.appendSlice(points);
    }
};

pub const Chart = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    marker: Marker,
    x_axis: Axis,
    y_axis: Axis,
    datasets: std.array_list.Managed(Dataset),
    legend_position: LegendPosition,
    legend_style: Style,
    plot_background: []const u8,

    pub fn init(allocator: std.mem.Allocator) Chart {
        return .{
            .allocator = allocator,
            .width = 60,
            .height = 18,
            .marker = .braille,
            .x_axis = .{},
            .y_axis = .{},
            .datasets = std.array_list.Managed(Dataset).init(allocator),
            .legend_position = .bottom,
            .legend_style = charting.inlineStyle((Style{}).bold(true)),
            .plot_background = " ",
        };
    }

    pub fn deinit(self: *Chart) void {
        for (self.datasets.items) |*dataset| dataset.deinit();
        self.datasets.deinit();
    }

    pub fn clearDatasets(self: *Chart) void {
        for (self.datasets.items) |*dataset| dataset.deinit();
        self.datasets.clearRetainingCapacity();
    }

    pub fn setSize(self: *Chart, width: u16, height: u16) void {
        self.width = @max(10, width);
        self.height = @max(6, height);
    }

    pub fn setMarker(self: *Chart, marker: Marker) void {
        self.marker = marker;
    }

    pub fn setLegendPosition(self: *Chart, position: LegendPosition) void {
        self.legend_position = position;
    }

    pub fn setPlotBackground(self: *Chart, glyph: []const u8) void {
        self.plot_background = glyph;
    }

    pub fn addDataset(self: *Chart, dataset: Dataset) !void {
        try self.datasets.append(dataset);
    }

    pub fn view(self: *const Chart, allocator: std.mem.Allocator) ![]const u8 {
        const resolved_x = self.resolveRange(.x);
        const resolved_y = self.resolveRange(.y);

        var x_ticks = try TickSet.init(allocator, self.x_axis, resolved_x);
        defer x_ticks.deinit();
        var y_ticks = try TickSet.init(allocator, self.y_axis, resolved_y);
        defer y_ticks.deinit();

        const y_label_width = if (self.y_axis.show_labels) y_ticks.maxLabelWidth() else 0;
        const y_axis_offset: usize = if (self.y_axis.show_line)
            2
        else if (y_label_width > 0)
            1
        else
            0;
        const left_gutter = y_label_width + y_axis_offset;
        const x_axis_line_rows: usize = if (self.x_axis.show_line) 1 else 0;
        const x_label_rows: usize = if (self.x_axis.show_labels) 1 else 0;
        const x_title_rows: usize = if (self.x_axis.title.len > 0) 1 else 0;
        const y_title_rows: usize = if (self.y_axis.title.len > 0) 1 else 0;

        const plot_width = @max(@as(usize, 1), @as(usize, self.width) -| left_gutter);
        const plot_height = @max(@as(usize, 1), @as(usize, self.height) -| (x_axis_line_rows + x_label_rows + x_title_rows + y_title_rows));

        x_ticks.updatePositions(plot_width);
        y_ticks.updatePositions(plot_height);

        const plot = try self.renderPlot(allocator, plot_width, plot_height, resolved_x, resolved_y, &x_ticks, &y_ticks);
        defer allocator.free(plot);

        var rows = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (rows.items) |row| allocator.free(row);
            rows.deinit();
        }

        if (self.y_axis.title.len > 0) {
            const row = try self.renderYAxisTitleRow(allocator, y_label_width, plot_width);
            try rows.append(row);
        }

        var plot_lines = std.mem.splitScalar(u8, plot, '\n');
        var row_index: usize = 0;
        while (plot_lines.next()) |plot_line| : (row_index += 1) {
            const row = try self.renderPlotRow(allocator, row_index, plot_line, plot_height, y_label_width, &y_ticks);
            try rows.append(row);
        }

        if (self.x_axis.show_line) {
            const axis_row = try self.renderXAxisLineRow(allocator, plot_width, y_label_width);
            try rows.append(axis_row);
        }

        if (self.x_axis.show_labels) {
            const label_row = try self.renderXAxisLabelsRow(allocator, plot_width, y_label_width, &x_ticks);
            try rows.append(label_row);
        }

        if (self.x_axis.title.len > 0) {
            const title_row = try self.renderXAxisTitleRow(allocator, plot_width, y_label_width);
            try rows.append(title_row);
        }

        const chart_body = try join.vertical(allocator, .left, rows.items);
        defer allocator.free(chart_body);

        const legend = try self.renderLegend(allocator);
        defer allocator.free(legend);

        return switch (self.legend_position) {
            .hidden => try allocator.dupe(u8, chart_body),
            .top => if (legend.len == 0) try allocator.dupe(u8, chart_body) else try join.vertical(allocator, .left, &.{ legend, chart_body }),
            .bottom => if (legend.len == 0) try allocator.dupe(u8, chart_body) else try join.vertical(allocator, .left, &.{ chart_body, legend }),
            .left => if (legend.len == 0) try allocator.dupe(u8, chart_body) else try join.horizontal(allocator, .top, &.{ legend, "  ", chart_body }),
            .right => if (legend.len == 0) try allocator.dupe(u8, chart_body) else try join.horizontal(allocator, .top, &.{ chart_body, "  ", legend }),
        };
    }

    const AxisKind = enum { x, y };

    fn resolveRange(self: *const Chart, axis_kind: AxisKind) DataRange {
        const axis = switch (axis_kind) {
            .x => self.x_axis,
            .y => self.y_axis,
        };
        if (axis.bounds) |bounds| return bounds.normalized();

        var found = false;
        var min_value: f64 = 0;
        var max_value: f64 = 0;

        for (self.datasets.items) |dataset| {
            for (dataset.points.items) |point| {
                const value = switch (axis_kind) {
                    .x => point.x,
                    .y => point.y,
                };
                if (!std.math.isFinite(value)) continue;
                if (!found) {
                    min_value = value;
                    max_value = value;
                    found = true;
                } else {
                    min_value = @min(min_value, value);
                    max_value = @max(max_value, value);
                }
            }

            if (axis_kind == .y and dataset.graph_type == .area) {
                if (dataset.fill_to) |baseline| {
                    if (!found) {
                        min_value = baseline;
                        max_value = baseline;
                        found = true;
                    } else {
                        min_value = @min(min_value, baseline);
                        max_value = @max(max_value, baseline);
                    }
                }
            }
        }

        if (!found) return .{ .min = 0, .max = 1 };
        const range = DataRange{ .min = min_value, .max = max_value };
        return range.normalized();
    }

    fn renderPlot(self: *const Chart, allocator: std.mem.Allocator, plot_width: usize, plot_height: usize, x_range: DataRange, y_range: DataRange, x_ticks: *const TickSet, y_ticks: *const TickSet) ![]const u8 {
        var buffer = try charting.CellBuffer.init(allocator, plot_width, plot_height);
        defer buffer.deinit();

        for (0..plot_height) |y| {
            for (0..plot_width) |x| {
                buffer.setSlice(x, y, self.plot_background, null);
            }
        }

        if (self.y_axis.show_grid) {
            for (y_ticks.positions.items) |y| {
                if (y >= plot_height) continue;
                for (0..plot_width) |x| {
                    setGridGlyph(&buffer, x, y, .horizontal, self.y_axis.grid_style);
                }
            }
        }

        if (self.x_axis.show_grid) {
            for (x_ticks.positions.items) |x| {
                if (x >= plot_width) continue;
                for (0..plot_height) |y| {
                    setGridGlyph(&buffer, x, y, .vertical, self.x_axis.grid_style);
                }
            }
        }

        var plot = canvas_mod.Canvas.init(allocator);
        defer plot.deinit();

        plot.setSize(@intCast(plot_width), @intCast(plot_height));
        plot.setRanges(x_range, y_range);
        plot.setMarker(self.marker);

        for (self.datasets.items) |dataset| {
            var path = try sampledPath(allocator, &dataset);
            defer path.deinit();

            switch (dataset.graph_type) {
                .line => {
                    if (dataset.points.items.len == 1) {
                        const point = dataset.points.items[0];
                        try plot.drawPointStyled(point.x, point.y, dataset.style, dataset.point_glyph);
                    } else if (path.items.len > 1) {
                        var i: usize = 1;
                        while (i < path.items.len) : (i += 1) {
                            const prev = path.items[i - 1];
                            const point = path.items[i];
                            try plot.drawLineStyled(prev.x, prev.y, point.x, point.y, dataset.style, null);
                        }
                    }

                    if (dataset.show_points) {
                        for (dataset.points.items) |point| {
                            try plot.drawPointStyled(point.x, point.y, dataset.style, dataset.point_glyph);
                        }
                    }
                },
                .scatter => {
                    for (dataset.points.items) |point| {
                        try plot.drawPointStyled(point.x, point.y, dataset.style, dataset.point_glyph);
                    }
                },
                .area => {
                    if (path.items.len > 1) {
                        var i: usize = 1;
                        while (i < path.items.len) : (i += 1) {
                            const prev = path.items[i - 1];
                            const point = path.items[i];
                            try plot.drawLineStyled(prev.x, prev.y, point.x, point.y, dataset.style, null);
                        }
                    }

                    const baseline = dataset.fill_to orelse y_range.min;
                    for (path.items) |point| {
                        try plot.drawLineStyled(point.x, baseline, point.x, point.y, dataset.style, null);
                    }
                },
            }
        }

        plot.drawIntoBuffer(&buffer);
        return try buffer.render(allocator);
    }

    fn renderYAxisTitleRow(self: *const Chart, allocator: std.mem.Allocator, y_label_width: usize, plot_width: usize) ![]const u8 {
        const prefix_width = leftPrefixWidth(self, y_label_width);
        var row = try charting.CellBuffer.init(allocator, prefix_width + plot_width, 1);
        defer row.deinit();

        for (0..row.width) |x| row.setSlice(x, 0, " ", null);
        row.writeText(prefix_width, 0, self.y_axis.title, self.y_axis.title_style);
        return try row.render(allocator);
    }

    fn renderPlotRow(self: *const Chart, allocator: std.mem.Allocator, row_index: usize, plot_line: []const u8, plot_height: usize, y_label_width: usize, y_ticks: *const TickSet) ![]const u8 {
        _ = plot_height;
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        if (self.y_axis.show_labels) {
            const label = y_ticks.labelForRow(row_index) orelse "";
            const padded = try renderPaddedLabel(allocator, label, y_label_width, self.y_axis.label_style);
            defer allocator.free(padded);
            try writer.writeAll(padded);
        }

        if (self.y_axis.show_line) {
            const axis_glyph = try self.y_axis.style.render(allocator, " │");
            defer allocator.free(axis_glyph);
            try writer.writeAll(axis_glyph);
        } else if (y_label_width > 0) {
            try writer.writeByte(' ');
        }

        try writer.writeAll(plot_line);
        return try result.toOwnedSlice();
    }

    fn renderXAxisLineRow(self: *const Chart, allocator: std.mem.Allocator, plot_width: usize, y_label_width: usize) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        if (self.y_axis.show_labels) {
            for (0..y_label_width) |_| try writer.writeByte(' ');
        }

        if (self.y_axis.show_line) {
            const corner = try self.x_axis.style.render(allocator, " └");
            defer allocator.free(corner);
            try writer.writeAll(corner);
        } else if (y_label_width > 0) {
            try writer.writeByte(' ');
        }

        var axis_style = self.x_axis.style;
        axis_style = charting.inlineStyle(axis_style);
        const segment = try axis_style.render(allocator, "─");
        defer allocator.free(segment);
        for (0..plot_width) |_| try writer.writeAll(segment);

        return try result.toOwnedSlice();
    }

    fn renderXAxisLabelsRow(self: *const Chart, allocator: std.mem.Allocator, plot_width: usize, y_label_width: usize, x_ticks: *const TickSet) ![]const u8 {
        const offset = leftPrefixWidth(self, y_label_width);
        var row = try charting.CellBuffer.init(allocator, offset + plot_width, 1);
        defer row.deinit();

        for (0..row.width) |x| row.setSlice(x, 0, " ", null);

        for (x_ticks.positions.items, x_ticks.labels.items) |x, label| {
            const label_width = measure.width(label);
            const start = offset + x -| (label_width / 2);
            row.writeText(start, 0, label, self.x_axis.label_style);
        }

        return try row.render(allocator);
    }

    fn renderXAxisTitleRow(self: *const Chart, allocator: std.mem.Allocator, plot_width: usize, y_label_width: usize) ![]const u8 {
        const offset = leftPrefixWidth(self, y_label_width);
        var row = try charting.CellBuffer.init(allocator, offset + plot_width, 1);
        defer row.deinit();

        for (0..row.width) |x| row.setSlice(x, 0, " ", null);

        const title_width = measure.width(self.x_axis.title);
        const start = offset + (plot_width -| title_width) / 2;
        row.writeText(start, 0, self.x_axis.title, self.x_axis.title_style);
        return try row.render(allocator);
    }

    fn renderLegend(self: *const Chart, allocator: std.mem.Allocator) ![]const u8 {
        if (self.legend_position == .hidden or self.datasets.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        var pieces = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (pieces.items) |piece| allocator.free(piece);
            pieces.deinit();
        }

        for (self.datasets.items) |dataset| {
            const symbol_raw = switch (dataset.graph_type) {
                .line => "──",
                .scatter => dataset.point_glyph orelse "•",
                .area => "██",
            };
            const symbol = try dataset.style.render(allocator, symbol_raw);
            defer allocator.free(symbol);

            const label = try self.legend_style.render(allocator, dataset.label);
            defer allocator.free(label);

            const piece = try std.fmt.allocPrint(allocator, "{s} {s}", .{ symbol, label });
            try pieces.append(piece);
        }

        return try join.horizontal(allocator, .top, pieces.items);
    }
};

const TickSet = struct {
    allocator: std.mem.Allocator,
    range: DataRange,
    values: std.array_list.Managed(f64),
    positions: std.array_list.Managed(usize),
    labels: std.array_list.Managed([]const u8),

    fn init(allocator: std.mem.Allocator, axis: Axis, range: DataRange) !TickSet {
        var self = TickSet{
            .allocator = allocator,
            .range = range,
            .values = std.array_list.Managed(f64).init(allocator),
            .positions = std.array_list.Managed(usize).init(allocator),
            .labels = std.array_list.Managed([]const u8).init(allocator),
        };

        if (axis.labels.len > 0) {
            for (axis.labels) |label| {
                try self.values.append(label.value);
                try self.positions.append(0);
                try self.labels.append(try allocator.dupe(u8, label.text));
            }
            return self;
        }

        const tick_count = @max(@as(usize, 2), axis.tick_count);
        var i: usize = 0;
        while (i < tick_count) : (i += 1) {
            const t = if (tick_count == 1) 0.0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(tick_count - 1));
            const value = range.min + (range.max - range.min) * t;
            try self.values.append(value);
            try self.positions.append(0);

            const formatter = axis.formatter orelse charting.defaultFormatter;
            const label = try formatter(allocator, value);
            try self.labels.append(label);
        }

        return self;
    }

    fn updatePositions(self: *TickSet, span: usize) void {
        const usable_span = @max(@as(usize, 1), span);
        for (self.values.items, 0..) |value, index| {
            self.positions.items[index] = charting.mapToResolution(value, self.range, usable_span);
        }
    }

    fn deinit(self: *TickSet) void {
        for (self.labels.items) |label| self.allocator.free(label);
        self.values.deinit();
        self.positions.deinit();
        self.labels.deinit();
    }

    fn maxLabelWidth(self: *const TickSet) usize {
        var max_width: usize = 0;
        for (self.labels.items) |label| {
            max_width = @max(max_width, measure.width(label));
        }
        return max_width;
    }

    fn labelForRow(self: *const TickSet, row: usize) ?[]const u8 {
        for (self.positions.items, self.labels.items) |tick_row, label| {
            if (tick_row == row) return label;
        }
        return null;
    }
};

const GridOrientation = enum { vertical, horizontal };

fn renderPaddedLabel(allocator: std.mem.Allocator, label: []const u8, width: usize, style: Style) ![]const u8 {
    const label_width = measure.width(label);
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    const padding = width -| label_width;
    for (0..padding) |_| try writer.writeByte(' ');

    if (label.len > 0) {
        const rendered = try style.render(allocator, label);
        defer allocator.free(rendered);
        try writer.writeAll(rendered);
    }

    return try result.toOwnedSlice();
}

fn setGridGlyph(buffer: *charting.CellBuffer, x: usize, y: usize, orientation: GridOrientation, style: Style) void {
    const current = buffer.cells[y * buffer.width + x];
    const next = switch (current.glyph) {
        .slice => |slice| blk: {
            if (orientation == .vertical and std.mem.eql(u8, slice, "─")) break :blk "┼";
            if (orientation == .horizontal and std.mem.eql(u8, slice, "│")) break :blk "┼";
            if (std.mem.eql(u8, slice, "┼")) break :blk "┼";
            break :blk if (orientation == .vertical) "│" else "─";
        },
        else => if (orientation == .vertical) "│" else "─",
    };
    buffer.setSlice(x, y, next, style);
}

fn leftPrefixWidth(self: *const Chart, y_label_width: usize) usize {
    return y_label_width + (if (self.y_axis.show_line)
        @as(usize, 2)
    else if (y_label_width > 0)
        @as(usize, 1)
    else
        @as(usize, 0));
}

fn sampledPath(allocator: std.mem.Allocator, dataset: *const Dataset) !std.array_list.Managed(Point) {
    var path = std.array_list.Managed(Point).init(allocator);
    if (dataset.points.items.len == 0) return path;

    switch (dataset.interpolation) {
        .linear => try path.appendSlice(dataset.points.items),
        .step_start => try appendSteppedPoints(&path, dataset.points.items, .step_start),
        .step_center => try appendSteppedPoints(&path, dataset.points.items, .step_center),
        .step_end => try appendSteppedPoints(&path, dataset.points.items, .step_end),
        .catmull_rom => try appendCatmullRomPoints(&path, dataset.points.items, dataset.interpolation_steps, dataset.curve_tension),
        .monotone_cubic => try appendMonotonePoints(allocator, &path, dataset.points.items, dataset.interpolation_steps),
    }

    return path;
}

fn appendSteppedPoints(path: *std.array_list.Managed(Point), points: []const Point, mode: Interpolation) !void {
    if (points.len == 0) return;
    try path.append(points[0]);

    for (points[1..], 1..) |point, index| {
        const prev = points[index - 1];
        switch (mode) {
            .step_start => {
                try path.append(.{ .x = prev.x, .y = point.y });
            },
            .step_center => {
                const mid_x = prev.x + (point.x - prev.x) / 2.0;
                try path.append(.{ .x = mid_x, .y = prev.y });
                try path.append(.{ .x = mid_x, .y = point.y });
            },
            .step_end => {
                try path.append(.{ .x = point.x, .y = prev.y });
            },
            else => unreachable,
        }
        try path.append(point);
    }
}

fn appendCatmullRomPoints(path: *std.array_list.Managed(Point), points: []const Point, steps: u8, tension: f64) !void {
    if (points.len <= 2) {
        try path.appendSlice(points);
        return;
    }

    const alpha = 1.0 - tension;
    try path.append(points[0]);

    var i: usize = 0;
    while (i + 1 < points.len) : (i += 1) {
        const p0 = if (i == 0) points[i] else points[i - 1];
        const p1 = points[i];
        const p2 = points[i + 1];
        const p3 = if (i + 2 < points.len) points[i + 2] else points[i + 1];

        var step: usize = 1;
        while (step <= steps) : (step += 1) {
            const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
            try path.append(catmullRomPoint(p0, p1, p2, p3, t, alpha));
        }
    }
}

fn catmullRomPoint(p0: Point, p1: Point, p2: Point, p3: Point, t: f64, alpha: f64) Point {
    const t2 = t * t;
    const t3 = t2 * t;

    const a0 = -alpha * t3 + 2.0 * alpha * t2 - alpha * t;
    const a1 = (2.0 - alpha) * t3 + (alpha - 3.0) * t2 + 1.0;
    const a2 = (alpha - 2.0) * t3 + (3.0 - 2.0 * alpha) * t2 + alpha * t;
    const a3 = alpha * t3 - alpha * t2;

    return .{
        .x = a0 * p0.x + a1 * p1.x + a2 * p2.x + a3 * p3.x,
        .y = a0 * p0.y + a1 * p1.y + a2 * p2.y + a3 * p3.y,
    };
}

fn appendMonotonePoints(allocator: std.mem.Allocator, path: *std.array_list.Managed(Point), points: []const Point, steps: u8) !void {
    if (points.len <= 2 or !strictlyIncreasingX(points)) {
        try path.appendSlice(points);
        return;
    }

    const delta = try allocator.alloc(f64, points.len - 1);
    defer allocator.free(delta);
    const slopes = try allocator.alloc(f64, points.len);
    defer allocator.free(slopes);

    for (0..points.len - 1) |i| {
        const dx = points[i + 1].x - points[i].x;
        if (dx <= 0) {
            try path.appendSlice(points);
            return;
        }
        delta[i] = (points[i + 1].y - points[i].y) / dx;
    }

    slopes[0] = delta[0];
    slopes[points.len - 1] = delta[delta.len - 1];

    for (1..points.len - 1) |i| {
        if (delta[i - 1] == 0 or delta[i] == 0 or std.math.signbit(delta[i - 1]) != std.math.signbit(delta[i])) {
            slopes[i] = 0;
        } else {
            const h0 = points[i].x - points[i - 1].x;
            const h1 = points[i + 1].x - points[i].x;
            const w1 = 2.0 * h1 + h0;
            const w2 = h1 + 2.0 * h0;
            slopes[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i]);
        }
    }

    try path.append(points[0]);
    for (0..points.len - 1) |i| {
        const p0 = points[i];
        const p1 = points[i + 1];
        const dx = p1.x - p0.x;

        var step: usize = 1;
        while (step <= steps) : (step += 1) {
            const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
            const t2 = t * t;
            const t3 = t2 * t;
            const h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
            const h10 = t3 - 2.0 * t2 + t;
            const h01 = -2.0 * t3 + 3.0 * t2;
            const h11 = t3 - t2;
            try path.append(.{
                .x = p0.x + dx * t,
                .y = h00 * p0.y + h10 * dx * slopes[i] + h01 * p1.y + h11 * dx * slopes[i + 1],
            });
        }
    }
}

fn strictlyIncreasingX(points: []const Point) bool {
    for (points[1..], 1..) |point, index| {
        if (!(point.x > points[index - 1].x)) return false;
    }
    return true;
}
