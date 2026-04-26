//! Layout module entry point.
//! Re-exports layout utilities for convenience.

pub const measure = @import("measure.zig");
pub const join = @import("join.zig");
pub const place = @import("place.zig");

// Re-export common types
pub const VAlign = join.VAlign;
pub const HAlign = join.HAlign;
pub const HPosition = place.HPosition;
pub const VPosition = place.VPosition;

// Convenience functions

/// Calculate visible width of text
pub fn width(str: []const u8) usize {
    return measure.width(str);
}

/// Calculate height (line count) of text
pub fn height(str: []const u8) usize {
    return measure.height(str);
}

/// Join strings horizontally with top alignment
pub fn joinHorizontal(allocator: @import("std").mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.horizontal(allocator, .top, parts);
}

/// Join strings vertically with left alignment
pub fn joinVertical(allocator: @import("std").mem.Allocator, parts: []const []const u8) ![]const u8 {
    return join.vertical(allocator, .left, parts);
}

/// Place content centered in a box
pub fn placeCenter(allocator: @import("std").mem.Allocator, w: usize, h: usize, content: []const u8) ![]const u8 {
    return place.place(allocator, w, h, .center, .middle, content);
}
