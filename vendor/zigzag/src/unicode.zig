//! Unicode utilities for display width calculation.

const std = @import("std");

pub const display_width = @import("unicode/display_width.zig");

/// Runtime width strategy.
/// - legacy_wcwidth: conservative fallback for terminals without negotiated width support.
/// - unicode: full Unicode table behavior.
pub const WidthStrategy = enum(u8) {
    legacy_wcwidth,
    unicode,
};

var width_strategy: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(WidthStrategy.legacy_wcwidth));

pub fn setWidthStrategy(strategy: WidthStrategy) void {
    width_strategy.store(@intFromEnum(strategy), .release);
}

pub fn getWidthStrategy() WidthStrategy {
    return @enumFromInt(width_strategy.load(.acquire));
}

pub fn charWidth(codepoint: u21) usize {
    return switch (getWidthStrategy()) {
        .legacy_wcwidth => charWidthLegacy(codepoint),
        .unicode => display_width.charWidth(codepoint),
    };
}

pub fn codepointWidth(codepoint: u21) i8 {
    return switch (getWidthStrategy()) {
        .unicode => @as(i8, display_width.codepointWidth(codepoint)),
        .legacy_wcwidth => blk: {
            const w = display_width.codepointWidth(codepoint);
            if (w <= 0) break :blk @as(i8, w);
            if (w == 2 and isLegacyAmbiguousWide(codepoint)) break :blk 1;
            break :blk @as(i8, w);
        },
    };
}

pub fn strWidth(str: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const len = std.unicode.utf8ByteSequenceLength(str[i]) catch {
            total += 1;
            i += 1;
            continue;
        };
        if (i + len > str.len) {
            total += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(str[i..][0..len]) catch {
            total += 1;
            i += 1;
            continue;
        };
        total += charWidth(cp);
        i += len;
    }
    return total;
}

fn charWidthLegacy(codepoint: u21) usize {
    const w = display_width.charWidth(codepoint);
    if (w == 2 and isLegacyAmbiguousWide(codepoint)) return 1;
    return w;
}

/// Legacy terminals often render many BMP symbol/emoji codepoints as narrow.
fn isLegacyAmbiguousWide(codepoint: u21) bool {
    return (codepoint >= 0x2300 and codepoint <= 0x23FF) or
        (codepoint >= 0x2600 and codepoint <= 0x27BF) or
        (codepoint >= 0x2B00 and codepoint <= 0x2BFF);
}

test {
    _ = display_width;
}

test "legacy strategy narrows ambiguous bmp symbols" {
    setWidthStrategy(.legacy_wcwidth);
    defer setWidthStrategy(.unicode);
    try std.testing.expectEqual(@as(usize, 1), charWidth(0x2764)); // Heart
}

test "unicode strategy keeps full table behavior" {
    setWidthStrategy(.unicode);
    defer setWidthStrategy(.legacy_wcwidth);
    try std.testing.expectEqual(display_width.charWidth(0x2764), charWidth(0x2764));
}
