//! Text measurement utilities for ANSI-aware width and height calculation.
//! Properly handles ANSI escape sequences and Unicode characters.

const std = @import("std");
const unicode = @import("../unicode.zig");

/// Calculate the visible width of a string (excluding ANSI escape sequences)
pub fn width(str: []const u8) usize {
    var w: usize = 0;
    var max_width: usize = 0;
    var in_escape = false;
    var escape_bracket = false;

    var i: usize = 0;
    while (i < str.len) {
        const c = str[i];

        if (c == 0x1b) {
            in_escape = true;
            escape_bracket = false;
            i += 1;
            continue;
        }

        if (in_escape) {
            if (c == '[') {
                escape_bracket = true;
            } else if (escape_bracket) {
                // CSI sequence ends with letter
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    in_escape = false;
                    escape_bracket = false;
                }
            } else if (c == ']') {
                // OSC sequence - skip until BEL or ST
                i += 1;
                while (i < str.len and str[i] != 0x07) {
                    if (str[i] == 0x1b and i + 1 < str.len and str[i + 1] == '\\') {
                        i += 1;
                        break;
                    }
                    i += 1;
                }
                in_escape = false;
            } else {
                // Single-character escape
                in_escape = false;
            }
            i += 1;
            continue;
        }

        if (c == '\n') {
            max_width = @max(max_width, w);
            w = 0;
            i += 1;
            continue;
        }

        if (c == '\r' or c == '\t') {
            if (c == '\t') {
                w += 8 - (w % 8); // Tab stops every 8 characters
            }
            i += 1;
            continue;
        }

        // Handle UTF-8 characters
        const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + byte_len <= str.len) {
            const codepoint = std.unicode.utf8Decode(str[i..][0..byte_len]) catch {
                w += 1;
                i += 1;
                continue;
            };

            w += unicode.charWidth(codepoint);
            i += byte_len;
        } else {
            w += 1;
            i += 1;
        }
    }

    return @max(max_width, w);
}

/// Calculate the height of a string (number of lines)
pub fn height(str: []const u8) usize {
    if (str.len == 0) return 0;

    var h: usize = 1;
    for (str) |c| {
        if (c == '\n') h += 1;
    }
    return h;
}

/// Calculate both width and height
pub fn size(str: []const u8) struct { width: usize, height: usize } {
    return .{
        .width = width(str),
        .height = height(str),
    };
}

/// Get the display width of a Unicode codepoint using full Unicode tables.
pub fn charWidth(codepoint: u21) usize {
    return unicode.charWidth(codepoint);
}

/// Get the width of a specific line
pub fn lineWidth(str: []const u8, line_num: usize) usize {
    var lines = std.mem.splitScalar(u8, str, '\n');
    var current: usize = 0;

    while (lines.next()) |line| {
        if (current == line_num) {
            return width(line);
        }
        current += 1;
    }

    return 0;
}

/// Get the maximum line width
pub fn maxLineWidth(str: []const u8) usize {
    var max_w: usize = 0;
    var lines = std.mem.splitScalar(u8, str, '\n');

    while (lines.next()) |line| {
        max_w = @max(max_w, width(line));
    }

    return max_w;
}

/// Pad a string to a specific width
pub fn padRight(allocator: std.mem.Allocator, str: []const u8, target_width: usize) ![]const u8 {
    const current_width = width(str);
    if (current_width >= target_width) return try allocator.dupe(u8, str);

    var result = std.array_list.Managed(u8).init(allocator);
    try result.appendSlice(str);

    for (0..(target_width - current_width)) |_| {
        try result.append(' ');
    }

    return result.toOwnedSlice();
}

/// Pad a string on the left to a specific width
pub fn padLeft(allocator: std.mem.Allocator, str: []const u8, target_width: usize) ![]const u8 {
    const current_width = width(str);
    if (current_width >= target_width) return try allocator.dupe(u8, str);

    var result = std.array_list.Managed(u8).init(allocator);

    for (0..(target_width - current_width)) |_| {
        try result.append(' ');
    }
    try result.appendSlice(str);

    return result.toOwnedSlice();
}

/// Center a string within a specific width
pub fn center(allocator: std.mem.Allocator, str: []const u8, target_width: usize) ![]const u8 {
    const current_width = width(str);
    if (current_width >= target_width) return try allocator.dupe(u8, str);

    const total_padding = target_width - current_width;
    const left_padding = total_padding / 2;
    const right_padding = total_padding - left_padding;

    var result = std.array_list.Managed(u8).init(allocator);

    for (0..left_padding) |_| {
        try result.append(' ');
    }
    try result.appendSlice(str);
    for (0..right_padding) |_| {
        try result.append(' ');
    }

    return result.toOwnedSlice();
}

/// Truncate string to fit within max width, adding ellipsis if needed
pub fn truncate(allocator: std.mem.Allocator, str: []const u8, max_width: usize) ![]const u8 {
    if (max_width == 0) return try allocator.dupe(u8, "");
    if (width(str) <= max_width) return try allocator.dupe(u8, str);

    if (max_width <= 3) {
        const result = try allocator.alloc(u8, max_width);
        @memset(result, '.');
        return result;
    }

    var result = std.array_list.Managed(u8).init(allocator);
    var w: usize = 0;
    var i: usize = 0;
    var in_escape = false;

    const target = max_width - 3; // Leave room for "..."

    while (i < str.len and w < target) {
        const c = str[i];

        if (c == 0x1b) {
            in_escape = true;
            const start = i;
            i += 1;
            // Copy escape sequence
            while (i < str.len) {
                if (str[i] == '[') {
                    i += 1;
                    while (i < str.len and !((str[i] >= 'A' and str[i] <= 'Z') or (str[i] >= 'a' and str[i] <= 'z'))) {
                        i += 1;
                    }
                    if (i < str.len) i += 1;
                    break;
                } else {
                    i += 1;
                    break;
                }
            }
            try result.appendSlice(str[start..i]);
            in_escape = false;
            continue;
        }

        // Regular character
        const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + byte_len <= str.len) {
            const codepoint = std.unicode.utf8Decode(str[i..][0..byte_len]) catch {
                try result.append(c);
                w += 1;
                i += 1;
                continue;
            };
            const cw = unicode.charWidth(codepoint);
            // Wide char would exceed target — stop here
            if (w + cw > target) break;
            try result.appendSlice(str[i..][0..byte_len]);
            w += cw;
            i += byte_len;
        } else {
            try result.append(c);
            w += 1;
            i += 1;
        }
    }

    try result.appendSlice("...");
    return result.toOwnedSlice();
}

test "width calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 5), width("hello"));
    try testing.expectEqual(@as(usize, 5), width("hello\n"));
    try testing.expectEqual(@as(usize, 5), width("hello\nworld"));
    try testing.expectEqual(@as(usize, 0), width(""));
    try testing.expectEqual(@as(usize, 5), width("\x1b[31mhello\x1b[0m"));
}

test "height calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), height("hello"));
    try testing.expectEqual(@as(usize, 2), height("hello\n"));
    try testing.expectEqual(@as(usize, 2), height("hello\nworld"));
    try testing.expectEqual(@as(usize, 0), height(""));
}
