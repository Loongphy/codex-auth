//! Help component for displaying key bindings.
//! Shows keyboard shortcuts and their descriptions.

const std = @import("std");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;
const measure = @import("../layout/measure.zig");
const join = @import("../layout/join.zig");

pub const Help = struct {
    allocator: std.mem.Allocator,

    // Bindings
    bindings: std.array_list.Managed(Binding),

    // Appearance
    separator: []const u8,
    ellipsis: []const u8,
    max_width: ?u16,
    short_mode: bool,

    // Styling
    key_style: style_mod.Style,
    desc_style: style_mod.Style,
    sep_style: style_mod.Style,

    pub const Binding = struct {
        key: []const u8,
        description: []const u8,
        short_desc: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Help {
        return .{
            .allocator = allocator,
            .bindings = std.array_list.Managed(Binding).init(allocator),
            .separator = " • ",
            .ellipsis = "...",
            .max_width = null,
            .short_mode = false,
            .key_style = blk: {
                var s = style_mod.Style{};
                s = s.bold(true);
                s = s.fg(Color.cyan());
                s = s.inline_style(true);
                break :blk s;
            },
            .desc_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(18));
                s = s.inline_style(true);
                break :blk s;
            },
            .sep_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(Color.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
        };
    }

    pub fn deinit(self: *Help) void {
        self.bindings.deinit();
    }

    /// Create a Help component from a KeyMap
    pub fn fromKeyMap(allocator: std.mem.Allocator, keymap: anytype) !Help {
        var help = Help.init(allocator);
        const bindings = try keymap.toHelpBindings(allocator);
        try help.setBindings(bindings);
        return help;
    }

    /// Add a key binding
    pub fn addBinding(self: *Help, key: []const u8, description: []const u8) !void {
        try self.bindings.append(.{
            .key = key,
            .description = description,
            .short_desc = null,
        });
    }

    /// Add a key binding with short description
    pub fn addBindingShort(self: *Help, key: []const u8, description: []const u8, short_desc: []const u8) !void {
        try self.bindings.append(.{
            .key = key,
            .description = description,
            .short_desc = short_desc,
        });
    }

    /// Set bindings from a list
    pub fn setBindings(self: *Help, bindings: []const Binding) !void {
        self.bindings.clearRetainingCapacity();
        try self.bindings.appendSlice(bindings);
    }

    /// Clear all bindings
    pub fn clear(self: *Help) void {
        self.bindings.clearRetainingCapacity();
    }

    /// Set max width (enables truncation)
    pub fn setMaxWidth(self: *Help, width: u16) void {
        self.max_width = width;
    }

    /// Enable/disable short mode
    pub fn setShortMode(self: *Help, short: bool) void {
        self.short_mode = short;
    }

    /// Render the help
    pub fn view(self: *const Help, allocator: std.mem.Allocator) ![]const u8 {
        if (self.bindings.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        var total_width: usize = 0;

        for (self.bindings.items, 0..) |binding, i| {
            // Calculate this binding's width
            const desc = if (self.short_mode and binding.short_desc != null)
                binding.short_desc.?
            else
                binding.description;

            const binding_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ binding.key, desc });
            const binding_width = measure.width(binding_text);

            // Check if we need truncation
            if (self.max_width) |max_w| {
                const sep_width = if (i > 0) measure.width(self.separator) else 0;
                if (total_width + sep_width + binding_width > max_w) {
                    // Add ellipsis and stop
                    if (i > 0) {
                        const sep_styled = try self.sep_style.render(allocator, self.separator);
                        try writer.writeAll(sep_styled);
                    }
                    try writer.writeAll(self.ellipsis);
                    break;
                }
            }

            // Add separator
            if (i > 0) {
                const sep_styled = try self.sep_style.render(allocator, self.separator);
                try writer.writeAll(sep_styled);
                total_width += measure.width(self.separator);
            }

            // Add key
            const key_styled = try self.key_style.render(allocator, binding.key);
            try writer.writeAll(key_styled);

            // Add description
            try writer.writeByte(' ');
            const desc_styled = try self.desc_style.render(allocator, desc);
            try writer.writeAll(desc_styled);

            total_width += binding_width;
        }

        return result.toOwnedSlice();
    }

    /// Render as a vertical list
    pub fn viewVertical(self: *const Help, allocator: std.mem.Allocator) ![]const u8 {
        if (self.bindings.items.len == 0) {
            return try allocator.dupe(u8, "");
        }

        // Find max key width
        var max_key_width: usize = 0;
        for (self.bindings.items) |binding| {
            max_key_width = @max(max_key_width, measure.width(binding.key));
        }

        var result = std.array_list.Managed(u8).init(allocator);
        const writer = result.writer();

        for (self.bindings.items, 0..) |binding, i| {
            if (i > 0) try writer.writeByte('\n');

            // Key with padding
            const key_styled = try self.key_style.render(allocator, binding.key);
            try writer.writeAll(key_styled);

            const key_width = measure.width(binding.key);
            for (0..(max_key_width - key_width + 2)) |_| {
                try writer.writeByte(' ');
            }

            // Description
            const desc = if (self.short_mode and binding.short_desc != null)
                binding.short_desc.?
            else
                binding.description;
            const desc_styled = try self.desc_style.render(allocator, desc);
            try writer.writeAll(desc_styled);
        }

        return result.toOwnedSlice();
    }
};

/// Common key binding sets
pub const CommonBindings = struct {
    pub const navigation = [_]Help.Binding{
        .{ .key = "↑/k", .description = "Move up", .short_desc = "up" },
        .{ .key = "↓/j", .description = "Move down", .short_desc = "down" },
        .{ .key = "←/h", .description = "Move left", .short_desc = "left" },
        .{ .key = "→/l", .description = "Move right", .short_desc = "right" },
    };

    pub const quit = Help.Binding{
        .key = "q",
        .description = "Quit",
        .short_desc = "quit",
    };

    pub const enter = Help.Binding{
        .key = "enter",
        .description = "Select",
        .short_desc = "select",
    };

    pub const escape = Help.Binding{
        .key = "esc",
        .description = "Cancel",
        .short_desc = "cancel",
    };
};
