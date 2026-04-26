//! Progress bar component.
//! Displays progress with customizable appearance.

const std = @import("std");
const style = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Progress = struct {
    // Progress state
    current: f64,
    total: f64,

    // Appearance
    width: u16,
    show_percent: bool,
    show_count: bool,

    // Characters
    full_char: []const u8,
    empty_char: []const u8,
    head_char: ?[]const u8,

    // Styling
    full_style: style.Style,
    empty_style: style.Style,
    percent_style: style.Style,

    // Gradient
    gradient_start: ?Color,
    gradient_end: ?Color,

    pub fn init() Progress {
        return .{
            .current = 0,
            .total = 100,
            .width = 40,
            .show_percent = true,
            .show_count = false,
            .full_char = "█",
            .empty_char = "░",
            .head_char = null,
            .full_style = blk: {
                var s = style.Style{};
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .empty_style = blk: {
                var s = style.Style{};
                s = s.fg(Color.gray(8));
                s = s.inline_style(true);
                break :blk s;
            },
            .percent_style = blk: {
                var s = style.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .gradient_start = null,
            .gradient_end = null,
        };
    }

    /// Set progress value (0 to total)
    pub fn setValue(self: *Progress, value: f64) void {
        self.current = @max(0, @min(value, self.total));
    }

    /// Set progress percentage (0 to 100)
    pub fn setPercent(self: *Progress, pct: f64) void {
        self.current = (pct / 100.0) * self.total;
    }

    /// Increment progress
    pub fn increment(self: *Progress, amount: f64) void {
        self.setValue(self.current + amount);
    }

    /// Set total value
    pub fn setTotal(self: *Progress, total: f64) void {
        self.total = total;
    }

    /// Set bar width
    pub fn setWidth(self: *Progress, width: u16) void {
        self.width = width;
    }

    /// Get current percentage (0-100)
    pub fn percent(self: *const Progress) f64 {
        if (self.total == 0) return 0;
        return (self.current / self.total) * 100.0;
    }

    /// Check if complete
    pub fn isComplete(self: *const Progress) bool {
        return self.current >= self.total;
    }

    /// Set bar characters
    pub fn setChars(self: *Progress, full: []const u8, empty: []const u8, head: ?[]const u8) void {
        self.full_char = full;
        self.empty_char = empty;
        self.head_char = head;
    }

    /// Use gradient style
    pub fn useGradient(self: *Progress) void {
        self.full_char = "█";
        self.empty_char = "░";
        self.head_char = "▓";
    }

    /// Use simple ASCII style
    pub fn useAscii(self: *Progress) void {
        self.full_char = "#";
        self.empty_char = "-";
        self.head_char = ">";
    }

    /// Use block style
    pub fn useBlock(self: *Progress) void {
        self.full_char = "■";
        self.empty_char = "□";
        self.head_char = null;
    }

    /// Set color gradient for the filled portion
    pub fn setGradient(self: *Progress, start: Color, end: Color) void {
        self.gradient_start = start;
        self.gradient_end = end;
    }

    /// Render the progress bar
    pub fn view(self: *const Progress, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        const ratio = if (self.total > 0) self.current / self.total else 0;
        const filled_width = @as(usize, @intFromFloat(ratio * @as(f64, @floatFromInt(self.width))));
        const empty_width = self.width -| @as(u16, @intCast(filled_width));

        // Filled portion
        for (0..filled_width) |i| {
            const char = if (self.head_char != null and i == filled_width - 1 and empty_width > 0)
                self.head_char.?
            else
                self.full_char;

            // Apply gradient color if set
            if (self.gradient_start != null and self.gradient_end != null and filled_width > 0) {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(@max(1, filled_width - 1)));
                const color = interpolateColor(self.gradient_start.?, self.gradient_end.?, t);
                var grad_style = style.Style{};
                grad_style = grad_style.fg(color);
                grad_style = grad_style.inline_style(true);
                const grad_styled = try grad_style.render(allocator, char);
                try writer.writeAll(grad_styled);
            } else {
                const full_styled = try self.full_style.render(allocator, char);
                try writer.writeAll(full_styled);
            }
        }

        // Empty portion
        for (0..empty_width) |_| {
            const empty_styled = try self.empty_style.render(allocator, self.empty_char);
            try writer.writeAll(empty_styled);
        }

        // Percentage
        if (self.show_percent) {
            const pct = self.percent();
            const pct_str = try std.fmt.allocPrint(allocator, " {d:.0}%", .{pct});
            const pct_styled = try self.percent_style.render(allocator, pct_str);
            try writer.writeAll(pct_styled);
        }

        // Count
        if (self.show_count) {
            const count_str = try std.fmt.allocPrint(allocator, " ({d}/{d})", .{
                @as(i64, @intFromFloat(self.current)),
                @as(i64, @intFromFloat(self.total)),
            });
            try writer.writeAll(count_str);
        }

        return result.toOwnedSlice();
    }

    /// Render with a label
    pub fn viewWithLabel(self: *const Progress, allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        try writer.writeAll(label);
        try writer.writeAll(" ");

        const bar = try self.view(allocator);
        try writer.writeAll(bar);

        return result.toOwnedSlice();
    }
};

/// Progress bar styles
pub const ProgressStyle = struct {
    /// Default style with gradient characters
    pub fn gradient() Progress {
        var p = Progress.init();
        p.useGradient();
        return p;
    }

    /// ASCII-only style
    pub fn ascii() Progress {
        var p = Progress.init();
        p.useAscii();
        return p;
    }

    /// Block style
    pub fn block() Progress {
        var p = Progress.init();
        p.useBlock();
        return p;
    }

    /// Simple line style
    pub fn simple() Progress {
        var p = Progress.init();
        p.full_char = "=";
        p.empty_char = " ";
        p.head_char = ">";
        return p;
    }

    /// Colored style
    pub fn colored() Progress {
        var p = Progress.init();
        var full_s = style.Style{};
        full_s = full_s.fg(Color.green());
        full_s = full_s.inline_style(true);
        p.full_style = full_s;
        var empty_s = style.Style{};
        empty_s = empty_s.fg(Color.red());
        empty_s = empty_s.inline_style(true);
        p.empty_style = empty_s;
        return p;
    }
};

/// Interpolate between two colors using RGB lerp
pub fn interpolateColor(start: Color, end: Color, t: f64) Color {
    const start_rgb = start.toRgb() orelse return start;
    const end_rgb = end.toRgb() orelse return end;

    const r: u8 = @intFromFloat(@as(f64, @floatFromInt(start_rgb.r)) * (1.0 - t) + @as(f64, @floatFromInt(end_rgb.r)) * t);
    const g: u8 = @intFromFloat(@as(f64, @floatFromInt(start_rgb.g)) * (1.0 - t) + @as(f64, @floatFromInt(end_rgb.g)) * t);
    const b: u8 = @intFromFloat(@as(f64, @floatFromInt(start_rgb.b)) * (1.0 - t) + @as(f64, @floatFromInt(end_rgb.b)) * t);

    return Color.fromRgb(r, g, b);
}
