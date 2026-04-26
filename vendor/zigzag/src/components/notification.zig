//! Notification/Toast component for timed messages.
//! Displays auto-dismissing messages with severity levels.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const Level = enum {
    info,
    success,
    warning,
    err,
};

pub const ToastMessage = struct {
    text: []const u8,
    level: Level,
    created_ns: u64,
    duration_ms: u64,
};

pub const Notification = struct {
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(ToastMessage),
    max_visible: usize,

    // Styling per level
    info_style: style_mod.Style,
    success_style: style_mod.Style,
    warning_style: style_mod.Style,
    err_style: style_mod.Style,

    pub fn init(allocator: std.mem.Allocator) Notification {
        return .{
            .allocator = allocator,
            .messages = std.array_list.Managed(ToastMessage).init(allocator),
            .max_visible = 5,
            .info_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .success_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.green());
                s = s.inline_style(true);
                break :blk s;
            },
            .warning_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.yellow());
                s = s.inline_style(true);
                break :blk s;
            },
            .err_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.red());
                s = s.inline_style(true);
                break :blk s;
            },
        };
    }

    pub fn deinit(self: *Notification) void {
        self.messages.deinit();
    }

    /// Push a new notification
    pub fn push(self: *Notification, text: []const u8, level: Level, duration_ms: u64, current_ns: u64) !void {
        try self.messages.append(.{
            .text = text,
            .level = level,
            .created_ns = current_ns,
            .duration_ms = duration_ms,
        });
    }

    /// Remove expired notifications
    pub fn update(self: *Notification, current_ns: u64) void {
        var i: usize = 0;
        while (i < self.messages.items.len) {
            const msg = self.messages.items[i];
            const elapsed_ms = (current_ns -| msg.created_ns) / std.time.ns_per_ms;
            if (elapsed_ms >= msg.duration_ms) {
                _ = self.messages.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Check if there are any active notifications
    pub fn hasMessages(self: *const Notification) bool {
        return self.messages.items.len > 0;
    }

    /// Render notifications
    pub fn view(self: *const Notification, allocator: std.mem.Allocator) ![]const u8 {
        if (self.messages.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        const visible_count = @min(self.messages.items.len, self.max_visible);
        const start = if (self.messages.items.len > self.max_visible)
            self.messages.items.len - self.max_visible
        else
            0;

        for (start..start + visible_count) |i| {
            if (i > start) try writer.writeAll("\n");

            const msg = self.messages.items[i];
            const icon = switch (msg.level) {
                .info => "i ",
                .success => "* ",
                .warning => "! ",
                .err => "x ",
            };
            const active_style = switch (msg.level) {
                .info => self.info_style,
                .success => self.success_style,
                .warning => self.warning_style,
                .err => self.err_style,
            };

            const styled_icon = try active_style.render(allocator, icon);
            try writer.writeAll(styled_icon);
            const styled_text = try active_style.render(allocator, msg.text);
            try writer.writeAll(styled_text);
        }

        return result.toOwnedSlice();
    }
};
