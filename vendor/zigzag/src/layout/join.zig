//! Layout joining utilities for combining multiple text blocks.
//! Provides horizontal and vertical joining with alignment options.

const std = @import("std");
const measure = @import("measure.zig");

/// Vertical alignment for horizontal joins
pub const VAlign = enum {
    top,
    middle,
    bottom,
};

/// Horizontal alignment for vertical joins
pub const HAlign = enum {
    left,
    center,
    right,
};

/// Join multiple strings horizontally (side by side)
pub fn horizontal(allocator: std.mem.Allocator, valign: VAlign, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    if (parts.len == 1) return try allocator.dupe(u8, parts[0]);

    // Calculate dimensions
    var max_height: usize = 0;
    var widths = try allocator.alloc(usize, parts.len);
    defer allocator.free(widths);

    for (parts, 0..) |part, i| {
        widths[i] = measure.maxLineWidth(part);
        max_height = @max(max_height, measure.height(part));
    }

    if (max_height == 0) max_height = 1;

    // Split all parts into lines
    var all_lines = try allocator.alloc([][]const u8, parts.len);
    defer {
        for (all_lines) |lines| {
            allocator.free(lines);
        }
        allocator.free(all_lines);
    }

    for (parts, 0..) |part, i| {
        var lines_list = std.array_list.Managed([]const u8).init(allocator);
        var iter = std.mem.splitScalar(u8, part, '\n');
        while (iter.next()) |line| {
            try lines_list.append(line);
        }
        all_lines[i] = try lines_list.toOwnedSlice();
    }

    // Build result
    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    for (0..max_height) |row| {
        if (row > 0) try writer.writeByte('\n');

        for (parts, 0..) |_, part_idx| {
            const lines = all_lines[part_idx];
            const part_height = lines.len;
            const w = widths[part_idx];

            // Calculate offset based on alignment
            const offset: usize = switch (valign) {
                .top => 0,
                .middle => (max_height - part_height) / 2,
                .bottom => max_height - part_height,
            };

            const line_idx = if (row >= offset and row < offset + part_height)
                row - offset
            else
                null;

            if (line_idx) |idx| {
                const line = lines[idx];
                try writer.writeAll(line);
                // Pad to width
                const line_width = measure.width(line);
                if (line_width < w) {
                    for (0..(w - line_width)) |_| {
                        try writer.writeByte(' ');
                    }
                }
            } else {
                // Empty line
                for (0..w) |_| {
                    try writer.writeByte(' ');
                }
            }
        }
    }

    return result.toOwnedSlice();
}

/// Join multiple strings vertically (stacked)
pub fn vertical(allocator: std.mem.Allocator, halign: HAlign, parts: []const []const u8) ![]const u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    if (parts.len == 1) return try allocator.dupe(u8, parts[0]);

    // Calculate max width
    var max_width: usize = 0;
    for (parts) |part| {
        max_width = @max(max_width, measure.maxLineWidth(part));
    }

    var result = std.array_list.Managed(u8).init(allocator);
    const writer = result.writer();

    for (parts, 0..) |part, part_idx| {
        if (part_idx > 0) try writer.writeByte('\n');

        var lines = std.mem.splitScalar(u8, part, '\n');
        var first_line = true;

        while (lines.next()) |line| {
            if (!first_line) try writer.writeByte('\n');
            first_line = false;

            const line_width = measure.width(line);
            const padding = if (max_width > line_width) max_width - line_width else 0;

            switch (halign) {
                .left => {
                    try writer.writeAll(line);
                    for (0..padding) |_| {
                        try writer.writeByte(' ');
                    }
                },
                .center => {
                    const left_pad = padding / 2;
                    const right_pad = padding - left_pad;
                    for (0..left_pad) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(line);
                    for (0..right_pad) |_| {
                        try writer.writeByte(' ');
                    }
                },
                .right => {
                    for (0..padding) |_| {
                        try writer.writeByte(' ');
                    }
                    try writer.writeAll(line);
                },
            }
        }
    }

    return result.toOwnedSlice();
}

/// Join with a separator
pub fn horizontalSep(
    allocator: std.mem.Allocator,
    valign: VAlign,
    separator: []const u8,
    parts: []const []const u8,
) ![]const u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    if (parts.len == 1) return try allocator.dupe(u8, parts[0]);

    // Create new parts array with separators
    var with_seps = try allocator.alloc([]const u8, parts.len * 2 - 1);
    defer allocator.free(with_seps);

    for (parts, 0..) |part, i| {
        with_seps[i * 2] = part;
        if (i < parts.len - 1) {
            with_seps[i * 2 + 1] = separator;
        }
    }

    return horizontal(allocator, valign, with_seps[0 .. parts.len * 2 - 1]);
}

/// Join with a separator
pub fn verticalSep(
    allocator: std.mem.Allocator,
    halign: HAlign,
    separator: []const u8,
    parts: []const []const u8,
) ![]const u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    if (parts.len == 1) return try allocator.dupe(u8, parts[0]);

    // Create new parts array with separators
    var with_seps = try allocator.alloc([]const u8, parts.len * 2 - 1);
    defer allocator.free(with_seps);

    for (parts, 0..) |part, i| {
        with_seps[i * 2] = part;
        if (i < parts.len - 1) {
            with_seps[i * 2 + 1] = separator;
        }
    }

    return vertical(allocator, halign, with_seps[0 .. parts.len * 2 - 1]);
}

test "horizontal join" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try horizontal(alloc, .top, &[_][]const u8{ "A", "B", "C" });
    defer alloc.free(result);
    try testing.expectEqualStrings("ABC", result);
}

test "vertical join" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try vertical(alloc, .left, &[_][]const u8{ "A", "B", "C" });
    defer alloc.free(result);
    try testing.expectEqualStrings("A\nB\nC", result);
}
