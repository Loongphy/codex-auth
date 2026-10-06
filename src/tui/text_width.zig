const std = @import("std");

pub fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (width += 1) {
        index += codepointByteLength(value[index..]);
    }
    return width;
}

pub fn prefixByteLength(value: []const u8, max_width: usize) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < value.len and width < max_width) : (width += 1) {
        index += codepointByteLength(value[index..]);
    }
    return index;
}

pub fn suffixStart(value: []const u8, max_width: usize) usize {
    const width = displayWidth(value);
    if (width <= max_width) return 0;
    return prefixByteLength(value, width - max_width);
}

fn codepointByteLength(value: []const u8) usize {
    const len = std.unicode.utf8ByteSequenceLength(value[0]) catch return 1;
    if (len > value.len) return 1;
    _ = std.unicode.utf8Decode(value[0..len]) catch return 1;
    return len;
}

test "display width counts UTF-8 codepoints instead of bytes" {
    try std.testing.expectEqual(@as(usize, 7), displayWidth("Рабочая"));
    try std.testing.expectEqual(@as(usize, 6), prefixByteLength("Рабочая", 3));
    try std.testing.expectEqualStrings("чая", "Рабочая"[suffixStart("Рабочая", 3)..]);
}
