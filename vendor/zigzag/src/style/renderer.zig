//! ANSI rendering utilities for styled text.
//! Provides functions to convert styles to ANSI escape sequences.

const std = @import("std");
const ansi = @import("../terminal/ansi.zig");
const color = @import("color.zig");
const style = @import("style.zig");

pub const Color = color.Color;
pub const Style = style.Style;

/// Render context for tracking current style state
pub const RenderContext = struct {
    current_fg: Color = .none,
    current_bg: Color = .none,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,

    /// Reset all styles
    pub fn reset(self: *RenderContext, writer: anytype) !void {
        try writer.writeAll(ansi.reset);
        self.* = .{};
    }

    /// Apply a style, only writing changes
    pub fn applyStyle(self: *RenderContext, s: Style, writer: anytype) !void {
        // Check if we need a full reset (turning off attributes)
        var needs_reset = false;
        if (self.bold and !s.bold_attr) needs_reset = true;
        if (self.dim and !s.dim_attr) needs_reset = true;
        if (self.italic and !s.italic_attr) needs_reset = true;
        if (self.underline and !s.underline_attr) needs_reset = true;
        if (self.blink and !s.blink_attr) needs_reset = true;
        if (self.reverse and !s.reverse_attr) needs_reset = true;
        if (self.strikethrough and !s.strikethrough_attr) needs_reset = true;

        if (needs_reset) {
            try self.reset(writer);
        }

        // Apply attributes
        if (!self.bold and s.bold_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.bold});
            self.bold = true;
        }
        if (!self.dim and s.dim_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.dim});
            self.dim = true;
        }
        if (!self.italic and s.italic_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.italic});
            self.italic = true;
        }
        if (!self.underline and s.underline_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.underline});
            self.underline = true;
        }
        if (!self.blink and s.blink_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.blink});
            self.blink = true;
        }
        if (!self.reverse and s.reverse_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.reverse});
            self.reverse = true;
        }
        if (!self.strikethrough and s.strikethrough_attr) {
            try writer.print(ansi.CSI ++ "{d}m", .{ansi.SGR.strikethrough});
            self.strikethrough = true;
        }

        // Apply colors
        if (!colorEql(self.current_fg, s.foreground)) {
            try s.foreground.writeFg(writer);
            self.current_fg = s.foreground;
        }
        if (!colorEql(self.current_bg, s.background)) {
            try s.background.writeBg(writer);
            self.current_bg = s.background;
        }
    }
};

fn colorEql(a: Color, b: Color) bool {
    const a_tag = @as(u8, @intFromEnum(std.meta.activeTag(a)));
    const b_tag = @as(u8, @intFromEnum(std.meta.activeTag(b)));
    if (a_tag != b_tag) return false;

    return switch (a) {
        .none => true,
        .ansi => |ac| b.ansi == ac,
        .ansi256 => |an| b.ansi256 == an,
        .rgb => |ar| b.rgb.r == ar.r and b.rgb.g == ar.g and b.rgb.b == ar.b,
    };
}

/// Strip ANSI escape sequences from text
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            // Skip CSI sequence
            i += 2;
            while (i < text.len and text[i] != 'm' and text[i] != 'H' and
                text[i] != 'J' and text[i] != 'K' and text[i] != 'A' and
                text[i] != 'B' and text[i] != 'C' and text[i] != 'D')
            {
                i += 1;
            }
            if (i < text.len) i += 1; // Skip final byte
        } else if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == ']') {
            // Skip OSC sequence
            i += 2;
            while (i < text.len and text[i] != 0x07 and text[i] != 0x1b) {
                i += 1;
            }
            if (i < text.len and text[i] == 0x07) i += 1;
            if (i + 1 < text.len and text[i] == 0x1b and text[i + 1] == '\\') i += 2;
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Check if text contains ANSI sequences
pub fn hasAnsi(text: []const u8) bool {
    for (text, 0..) |c, i| {
        if (c == 0x1b and i + 1 < text.len and (text[i + 1] == '[' or text[i + 1] == ']')) {
            return true;
        }
    }
    return false;
}

/// Truncate text to a maximum width, preserving ANSI sequences
pub fn truncate(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var visible_width: usize = 0;
    var i: usize = 0;

    while (i < text.len and visible_width < max_width) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            // Copy entire CSI sequence
            const start = i;
            i += 2;
            while (i < text.len and text[i] != 'm' and text[i] != 'H' and
                text[i] != 'J' and text[i] != 'K' and text[i] != 'A' and
                text[i] != 'B' and text[i] != 'C' and text[i] != 'D')
            {
                i += 1;
            }
            if (i < text.len) i += 1;
            try result.appendSlice(text[start..i]);
        } else {
            // Regular character
            try result.append(text[i]);
            visible_width += 1;
            i += 1;
        }
    }

    // Add reset if we truncated
    if (i < text.len and hasAnsi(text)) {
        try result.appendSlice(ansi.reset);
    }

    return result.toOwnedSlice();
}
