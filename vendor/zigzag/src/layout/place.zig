//! Positioning utilities for placing content within a bounding box.
//! Provides 2D positioning with horizontal and vertical alignment.

const std = @import("std");
const measure = @import("measure.zig");
const unicode = @import("../unicode.zig");

/// Horizontal position
pub const HPosition = enum {
    left,
    center,
    right,
};

/// Vertical position
pub const VPosition = enum {
    top,
    middle,
    bottom,
};

/// Position content within a bounding box
pub fn place(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    hpos: HPosition,
    vpos: VPosition,
    content: []const u8,
) ![]const u8 {
    const content_width = measure.maxLineWidth(content);
    const content_height = measure.height(content);

    // If content is larger than box, just return it
    if (content_width >= width and content_height >= height) {
        return try allocator.dupe(u8, content);
    }

    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    // Calculate vertical offset
    const v_padding = if (height > content_height) height - content_height else 0;
    const top_padding: usize = switch (vpos) {
        .top => 0,
        .middle => v_padding / 2,
        .bottom => v_padding,
    };
    const bottom_padding = v_padding - top_padding;

    // Calculate horizontal offset
    const h_padding = if (width > content_width) width - content_width else 0;
    const left_padding: usize = switch (hpos) {
        .left => 0,
        .center => h_padding / 2,
        .right => h_padding,
    };

    // Write top padding
    for (0..top_padding) |_| {
        for (0..width) |_| {
            try writer.writeByte(' ');
        }
        try writer.writeByte('\n');
    }

    // Write content lines
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try writer.writeByte('\n');
        first_line = false;

        // Left padding
        for (0..left_padding) |_| {
            try writer.writeByte(' ');
        }

        // Content
        try writer.writeAll(line);

        // Right padding
        const line_width = measure.width(line);
        const right_pad = if (width > left_padding + line_width)
            width - left_padding - line_width
        else
            0;
        for (0..right_pad) |_| {
            try writer.writeByte(' ');
        }
    }

    // Write bottom padding
    for (0..bottom_padding) |_| {
        try writer.writeByte('\n');
        for (0..width) |_| {
            try writer.writeByte(' ');
        }
    }

    return result.toOwnedSlice();
}

/// Place content at absolute coordinates
pub fn placeAt(
    allocator: std.mem.Allocator,
    canvas_width: usize,
    canvas_height: usize,
    x: usize,
    y: usize,
    content: []const u8,
) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var content_lines = std.array_list.Managed([]const u8).init(allocator);
    defer content_lines.deinit();

    while (lines.next()) |line| {
        try content_lines.append(line);
    }

    for (0..canvas_height) |row| {
        if (row > 0) try writer.writeByte('\n');

        for (0..canvas_width) |col| {
            // Check if this position is within the content
            if (row >= y and col >= x) {
                const content_row = row - y;
                const content_col = col - x;

                if (content_row < content_lines.items.len) {
                    const line = content_lines.items[content_row];
                    if (content_col < measure.width(line)) {
                        // Find the byte position for this display column
                        var byte_pos: usize = 0;
                        var current_col: usize = 0;
                        while (byte_pos < line.len and current_col < content_col) {
                            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_pos]) catch 1;
                            if (byte_pos + byte_len <= line.len) {
                                const cp = std.unicode.utf8Decode(line[byte_pos..][0..byte_len]) catch {
                                    byte_pos += 1;
                                    current_col += 1;
                                    continue;
                                };
                                current_col += unicode.charWidth(cp);
                            }
                            byte_pos += byte_len;
                        }

                        // If we landed inside a wide character, emit space
                        if (current_col > content_col) {
                            try writer.writeByte(' ');
                            continue;
                        }

                        if (byte_pos < line.len) {
                            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_pos]) catch 1;
                            try writer.writeAll(line[byte_pos..][0..byte_len]);
                            continue;
                        }
                    }
                }
            }
            try writer.writeByte(' ');
        }
    }

    return result.toOwnedSlice();
}

/// Overlay content on top of a base, preserving transparency (spaces in content show base)
pub fn overlay(
    allocator: std.mem.Allocator,
    base: []const u8,
    content: []const u8,
    x: usize,
    y: usize,
) ![]const u8 {
    const base_width = measure.maxLineWidth(base);
    const base_height = measure.height(base);

    var base_lines = std.array_list.Managed([]const u8).init(allocator);
    defer base_lines.deinit();
    var base_iter = std.mem.splitScalar(u8, base, '\n');
    while (base_iter.next()) |line| {
        try base_lines.append(line);
    }

    var content_lines = std.array_list.Managed([]const u8).init(allocator);
    defer content_lines.deinit();
    var content_iter = std.mem.splitScalar(u8, content, '\n');
    while (content_iter.next()) |line| {
        try content_lines.append(line);
    }

    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    for (0..base_height) |row| {
        if (row > 0) try writer.writeByte('\n');

        const base_line = if (row < base_lines.items.len) base_lines.items[row] else "";
        const content_row = if (row >= y) row - y else base_height;
        const content_line = if (content_row < content_lines.items.len)
            content_lines.items[content_row]
        else
            "";

        for (0..base_width) |col| {
            const content_col = if (col >= x) col - x else base_width;

            // Try to get content character
            var used_content = false;
            if (content_col < measure.width(content_line)) {
                // Find byte at display column
                var byte_pos: usize = 0;
                var current_col: usize = 0;
                while (byte_pos < content_line.len and current_col < content_col) {
                    const byte_len = std.unicode.utf8ByteSequenceLength(content_line[byte_pos]) catch 1;
                    if (byte_pos + byte_len <= content_line.len) {
                        const cp = std.unicode.utf8Decode(content_line[byte_pos..][0..byte_len]) catch {
                            byte_pos += 1;
                            current_col += 1;
                            continue;
                        };
                        current_col += unicode.charWidth(cp);
                    }
                    byte_pos += byte_len;
                }

                // If we landed inside a wide character, emit space
                if (current_col > content_col) {
                    try writer.writeByte(' ');
                    used_content = true;
                } else if (byte_pos < content_line.len and content_line[byte_pos] != ' ') {
                    const byte_len = std.unicode.utf8ByteSequenceLength(content_line[byte_pos]) catch 1;
                    try writer.writeAll(content_line[byte_pos..][0..byte_len]);
                    used_content = true;
                }
            }

            if (!used_content) {
                // Use base character
                if (col < measure.width(base_line)) {
                    var byte_pos: usize = 0;
                    var current_col: usize = 0;
                    while (byte_pos < base_line.len and current_col < col) {
                        const byte_len = std.unicode.utf8ByteSequenceLength(base_line[byte_pos]) catch 1;
                        if (byte_pos + byte_len <= base_line.len) {
                            const cp = std.unicode.utf8Decode(base_line[byte_pos..][0..byte_len]) catch {
                                byte_pos += 1;
                                current_col += 1;
                                continue;
                            };
                            current_col += unicode.charWidth(cp);
                        }
                        byte_pos += byte_len;
                    }

                    if (current_col > col) {
                        try writer.writeByte(' ');
                    } else if (byte_pos < base_line.len) {
                        const byte_len = std.unicode.utf8ByteSequenceLength(base_line[byte_pos]) catch 1;
                        try writer.writeAll(base_line[byte_pos..][0..byte_len]);
                    } else {
                        try writer.writeByte(' ');
                    }
                } else {
                    try writer.writeByte(' ');
                }
            }
        }
    }

    return result.toOwnedSlice();
}

/// Place content with horizontal positioning only (height inferred from content)
pub fn placeHorizontal(
    allocator: std.mem.Allocator,
    width: usize,
    hpos: HPosition,
    content: []const u8,
) ![]const u8 {
    const content_height = measure.height(content);
    return place(allocator, width, content_height, hpos, .top, content);
}

/// Place content with vertical positioning only (width inferred from content)
pub fn placeVertical(
    allocator: std.mem.Allocator,
    height: usize,
    vpos: VPosition,
    content: []const u8,
) ![]const u8 {
    const content_width = measure.maxLineWidth(content);
    return place(allocator, content_width, height, .left, vpos, content);
}

/// Position content using float coordinates (0.0 = left/top, 0.5 = center, 1.0 = right/bottom)
pub fn placeFloat(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    hpos: f32,
    vpos: f32,
    content: []const u8,
) ![]const u8 {
    const content_width = measure.maxLineWidth(content);
    const content_height = measure.height(content);

    // If content is larger than box, just return it
    if (content_width >= width and content_height >= height) {
        return try allocator.dupe(u8, content);
    }

    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    // Calculate offsets from float positions
    const h_space = if (width > content_width) width - content_width else 0;
    const v_space = if (height > content_height) height - content_height else 0;

    const clamped_h = @max(0.0, @min(1.0, hpos));
    const clamped_v = @max(0.0, @min(1.0, vpos));

    const left_padding: usize = @intFromFloat(@as(f32, @floatFromInt(h_space)) * clamped_h);
    const top_padding: usize = @intFromFloat(@as(f32, @floatFromInt(v_space)) * clamped_v);
    const bottom_padding = v_space - top_padding;

    // Write top padding
    for (0..top_padding) |_| {
        for (0..width) |_| {
            try writer.writeByte(' ');
        }
        try writer.writeByte('\n');
    }

    // Write content lines
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try writer.writeByte('\n');
        first_line = false;

        // Left padding
        for (0..left_padding) |_| {
            try writer.writeByte(' ');
        }

        // Content
        try writer.writeAll(line);

        // Right padding
        const line_width = measure.width(line);
        const right_pad = if (width > left_padding + line_width)
            width - left_padding - line_width
        else
            0;
        for (0..right_pad) |_| {
            try writer.writeByte(' ');
        }
    }

    // Write bottom padding
    for (0..bottom_padding) |_| {
        try writer.writeByte('\n');
        for (0..width) |_| {
            try writer.writeByte(' ');
        }
    }

    return result.toOwnedSlice();
}

test "place center" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try place(alloc, 5, 3, .center, .middle, "X");
    defer alloc.free(result);

    // Expected: 5x3 grid with X in center
    try testing.expect(result.len > 0);
}
