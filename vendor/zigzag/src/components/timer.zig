//! Timer component for countdowns and elapsed time.
//! Displays time in various formats.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Timer = struct {
    // State
    duration_ns: i128,
    elapsed_ns: i128,
    running: bool,
    direction: Direction,

    // Display
    format: Format,
    show_milliseconds: bool,

    // Styling
    timer_style: style_mod.Style,
    warning_style: style_mod.Style,
    danger_style: style_mod.Style,

    // Thresholds for countdown warnings (in seconds)
    warning_threshold: ?u64,
    danger_threshold: ?u64,

    pub const Direction = enum {
        up, // Counts up (stopwatch)
        down, // Counts down (timer)
    };

    pub const Format = enum {
        compact, // 1:23
        long, // 01:23
        full, // 00:01:23
        verbose, // 1m 23s
    };

    pub fn init() Timer {
        return .{
            .duration_ns = 0,
            .elapsed_ns = 0,
            .running = false,
            .direction = .up,
            .format = .long,
            .show_milliseconds = false,
            .timer_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .warning_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.yellow());
                s = s.inline_style(true);
                break :blk s;
            },
            .danger_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.red());
                s = s.inline_style(true);
                break :blk s;
            },
            .warning_threshold = 30,
            .danger_threshold = 10,
        };
    }

    /// Create a countdown timer
    pub fn countdown(seconds: u64) Timer {
        var t = init();
        t.direction = .down;
        t.duration_ns = @as(i128, seconds) * std.time.ns_per_s;
        return t;
    }

    /// Create a stopwatch
    pub fn stopwatch() Timer {
        var t = init();
        t.direction = .up;
        return t;
    }

    /// Start the timer
    pub fn start(self: *Timer) void {
        self.running = true;
    }

    /// Stop the timer
    pub fn stop(self: *Timer) void {
        self.running = false;
    }

    /// Toggle running state
    pub fn toggle(self: *Timer) void {
        self.running = !self.running;
    }

    /// Reset the timer
    pub fn reset(self: *Timer) void {
        self.elapsed_ns = 0;
    }

    /// Set duration for countdown (in seconds)
    pub fn setDuration(self: *Timer, seconds: u64) void {
        self.duration_ns = @as(i128, seconds) * std.time.ns_per_s;
    }

    /// Update timer with delta time (in nanoseconds)
    pub fn update(self: *Timer, delta_ns: u64) void {
        if (!self.running) return;
        self.elapsed_ns += delta_ns;
    }

    /// Get remaining time for countdown (in nanoseconds)
    pub fn remaining(self: *const Timer) i128 {
        if (self.direction == .down) {
            return @max(0, self.duration_ns - self.elapsed_ns);
        }
        return self.elapsed_ns;
    }

    /// Get elapsed time in seconds
    pub fn elapsedSeconds(self: *const Timer) u64 {
        return @intCast(@divFloor(self.elapsed_ns, std.time.ns_per_s));
    }

    /// Get remaining time in seconds (for countdown)
    pub fn remainingSeconds(self: *const Timer) u64 {
        return @intCast(@divFloor(self.remaining(), std.time.ns_per_s));
    }

    /// Check if countdown is finished
    pub fn isFinished(self: *const Timer) bool {
        if (self.direction == .down) {
            return self.elapsed_ns >= self.duration_ns;
        }
        return false;
    }

    /// Check if in warning state
    pub fn isWarning(self: *const Timer) bool {
        if (self.direction == .down and self.warning_threshold != null) {
            const remaining_s = self.remainingSeconds();
            return remaining_s <= self.warning_threshold.? and remaining_s > (self.danger_threshold orelse 0);
        }
        return false;
    }

    /// Check if in danger state
    pub fn isDanger(self: *const Timer) bool {
        if (self.direction == .down and self.danger_threshold != null) {
            return self.remainingSeconds() <= self.danger_threshold.?;
        }
        return false;
    }

    /// Render the timer
    pub fn view(self: *const Timer, allocator: std.mem.Allocator) ![]const u8 {
        const display_ns = if (self.direction == .down) self.remaining() else self.elapsed_ns;

        const total_seconds: u64 = @intCast(@divFloor(display_ns, std.time.ns_per_s));
        const milliseconds: u64 = @intCast(@mod(@divFloor(display_ns, std.time.ns_per_ms), 1000));

        const hours = total_seconds / 3600;
        const minutes = (total_seconds % 3600) / 60;
        const seconds = total_seconds % 60;

        const time_str = switch (self.format) {
            .compact => blk: {
                if (hours > 0) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{d}:{d:0>2}", .{ minutes, seconds });
                }
            },
            .long => blk: {
                if (hours > 0) {
                    break :blk try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}", .{ minutes, seconds });
                }
            },
            .full => try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }),
            .verbose => blk: {
                if (hours > 0) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}h {d}m {d}s", .{ hours, minutes, seconds });
                } else if (minutes > 0) {
                    break :blk try std.fmt.allocPrint(allocator, "{d}m {d}s", .{ minutes, seconds });
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{d}s", .{seconds});
                }
            },
        };

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        // Choose style based on state
        const active_style = if (self.isDanger())
            self.danger_style
        else if (self.isWarning())
            self.warning_style
        else
            self.timer_style;

        const styled = try active_style.render(allocator, time_str);
        try writer.writeAll(styled);

        // Add milliseconds if enabled
        if (self.show_milliseconds) {
            const ms_str = try std.fmt.allocPrint(allocator, ".{d:0>3}", .{milliseconds});
            try writer.writeAll(ms_str);
        }

        return result.toOwnedSlice();
    }
};
