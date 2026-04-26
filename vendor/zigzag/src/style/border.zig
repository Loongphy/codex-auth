//! Border styles for terminal UI elements.
//! Provides various border character sets and drawing functions.

const std = @import("std");
const measure = @import("../layout/measure.zig");

/// Border character set
pub const BorderChars = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
    middle_left: []const u8,
    middle_right: []const u8,
    middle_top: []const u8,
    middle_bottom: []const u8,
    cross: []const u8,
};

/// Predefined border styles
pub const Border = struct {
    /// No border
    pub const none = BorderChars{
        .top_left = "",
        .top_right = "",
        .bottom_left = "",
        .bottom_right = "",
        .horizontal = "",
        .vertical = "",
        .middle_left = "",
        .middle_right = "",
        .middle_top = "",
        .middle_bottom = "",
        .cross = "",
    };

    /// Normal single-line border
    pub const normal = BorderChars{
        .top_left = "┌",
        .top_right = "┐",
        .bottom_left = "└",
        .bottom_right = "┘",
        .horizontal = "─",
        .vertical = "│",
        .middle_left = "├",
        .middle_right = "┤",
        .middle_top = "┬",
        .middle_bottom = "┴",
        .cross = "┼",
    };

    /// Rounded corners
    pub const rounded = BorderChars{
        .top_left = "╭",
        .top_right = "╮",
        .bottom_left = "╰",
        .bottom_right = "╯",
        .horizontal = "─",
        .vertical = "│",
        .middle_left = "├",
        .middle_right = "┤",
        .middle_top = "┬",
        .middle_bottom = "┴",
        .cross = "┼",
    };

    /// Double-line border
    pub const double = BorderChars{
        .top_left = "╔",
        .top_right = "╗",
        .bottom_left = "╚",
        .bottom_right = "╝",
        .horizontal = "═",
        .vertical = "║",
        .middle_left = "╠",
        .middle_right = "╣",
        .middle_top = "╦",
        .middle_bottom = "╩",
        .cross = "╬",
    };

    /// Thick/bold border
    pub const thick = BorderChars{
        .top_left = "┏",
        .top_right = "┓",
        .bottom_left = "┗",
        .bottom_right = "┛",
        .horizontal = "━",
        .vertical = "┃",
        .middle_left = "┣",
        .middle_right = "┫",
        .middle_top = "┳",
        .middle_bottom = "┻",
        .cross = "╋",
    };

    /// ASCII-only border (compatible with all terminals)
    pub const ascii = BorderChars{
        .top_left = "+",
        .top_right = "+",
        .bottom_left = "+",
        .bottom_right = "+",
        .horizontal = "-",
        .vertical = "|",
        .middle_left = "+",
        .middle_right = "+",
        .middle_top = "+",
        .middle_bottom = "+",
        .cross = "+",
    };

    /// Block border using full block characters
    pub const block = BorderChars{
        .top_left = "█",
        .top_right = "█",
        .bottom_left = "█",
        .bottom_right = "█",
        .horizontal = "█",
        .vertical = "█",
        .middle_left = "█",
        .middle_right = "█",
        .middle_top = "█",
        .middle_bottom = "█",
        .cross = "█",
    };

    /// Hidden border (uses spaces)
    pub const hidden = BorderChars{
        .top_left = " ",
        .top_right = " ",
        .bottom_left = " ",
        .bottom_right = " ",
        .horizontal = " ",
        .vertical = " ",
        .middle_left = " ",
        .middle_right = " ",
        .middle_top = " ",
        .middle_bottom = " ",
        .cross = " ",
    };

    /// Dashed border
    pub const dashed = BorderChars{
        .top_left = "┌",
        .top_right = "┐",
        .bottom_left = "└",
        .bottom_right = "┘",
        .horizontal = "╌",
        .vertical = "╎",
        .middle_left = "├",
        .middle_right = "┤",
        .middle_top = "┬",
        .middle_bottom = "┴",
        .cross = "┼",
    };

    /// Dotted border
    pub const dotted = BorderChars{
        .top_left = "┌",
        .top_right = "┐",
        .bottom_left = "└",
        .bottom_right = "┘",
        .horizontal = "┈",
        .vertical = "┊",
        .middle_left = "├",
        .middle_right = "┤",
        .middle_top = "┬",
        .middle_bottom = "┴",
        .cross = "┼",
    };

    /// Inner half block border (uses inner half-block characters)
    pub const inner_half_block = BorderChars{
        .top_left = "▗",
        .top_right = "▖",
        .bottom_left = "▝",
        .bottom_right = "▘",
        .horizontal = "▄",
        .vertical = "▐",
        .middle_left = "▐",
        .middle_right = "▌",
        .middle_top = "▄",
        .middle_bottom = "▀",
        .cross = "█",
    };

    /// Outer half block border (uses outer half-block characters)
    pub const outer_half_block = BorderChars{
        .top_left = "▛",
        .top_right = "▜",
        .bottom_left = "▙",
        .bottom_right = "▟",
        .horizontal = "▀",
        .vertical = "▌",
        .middle_left = "▌",
        .middle_right = "▐",
        .middle_top = "▀",
        .middle_bottom = "▄",
        .cross = "█",
    };

    /// Markdown-style border (uses pipe and dashes)
    pub const markdown = BorderChars{
        .top_left = "|",
        .top_right = "|",
        .bottom_left = "|",
        .bottom_right = "|",
        .horizontal = "-",
        .vertical = "|",
        .middle_left = "|",
        .middle_right = "|",
        .middle_top = "|",
        .middle_bottom = "|",
        .cross = "|",
    };
};

/// Sides specification for borders
pub const Sides = struct {
    top: bool = true,
    right: bool = true,
    bottom: bool = true,
    left: bool = true,

    pub const all = Sides{};
    pub const horizontal_only = Sides{ .left = false, .right = false };
    pub const vertical_only = Sides{ .top = false, .bottom = false };
    pub const top_only = Sides{ .right = false, .bottom = false, .left = false };
    pub const bottom_only = Sides{ .top = false, .right = false, .left = false };
    pub const left_only = Sides{ .top = false, .right = false, .bottom = false };
    pub const right_only = Sides{ .top = false, .bottom = false, .left = false };
    pub const none = Sides{ .top = false, .right = false, .bottom = false, .left = false };
};

/// Draw a border around content
pub fn drawBorder(
    allocator: std.mem.Allocator,
    content: []const u8,
    chars: BorderChars,
    sides: Sides,
    width: usize,
    height: usize,
) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    const inner_width = if (sides.left and sides.right) width -| 2 else if (sides.left or sides.right) width -| 1 else width;

    // Top border
    if (sides.top) {
        if (sides.left) try writer.writeAll(chars.top_left);
        for (0..inner_width) |_| {
            try writer.writeAll(chars.horizontal);
        }
        if (sides.right) try writer.writeAll(chars.top_right);
        try writer.writeByte('\n');
    }

    // Content lines with side borders
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| : (line_count += 1) {
        if (sides.left) try writer.writeAll(chars.vertical);

        // Write the line, padding to inner_width
        const visible_width = visibleWidth(line);
        try writer.writeAll(line);
        if (visible_width < inner_width) {
            for (0..(inner_width - visible_width)) |_| {
                try writer.writeByte(' ');
            }
        }

        if (sides.right) try writer.writeAll(chars.vertical);
        try writer.writeByte('\n');
    }

    // Pad remaining lines if needed
    while (line_count < height -| (if (sides.top) @as(usize, 1) else 0) -| (if (sides.bottom) @as(usize, 1) else 0)) : (line_count += 1) {
        if (sides.left) try writer.writeAll(chars.vertical);
        for (0..inner_width) |_| {
            try writer.writeByte(' ');
        }
        if (sides.right) try writer.writeAll(chars.vertical);
        try writer.writeByte('\n');
    }

    // Bottom border
    if (sides.bottom) {
        if (sides.left) try writer.writeAll(chars.bottom_left);
        for (0..inner_width) |_| {
            try writer.writeAll(chars.horizontal);
        }
        if (sides.right) try writer.writeAll(chars.bottom_right);
    }

    return result.toOwnedSlice();
}

/// Calculate visible width (excluding ANSI sequences), with proper Unicode width.
fn visibleWidth(str: []const u8) usize {
    return measure.width(str);
}
