const std = @import("std");
const terminal_color = @import("codex_auth").terminal.color;

const shouldEnableColor = terminal_color.shouldEnableColor;

test "Scenario: Given color support inputs when deciding ANSI output then Windows stays disabled" {
    try std.testing.expect(!shouldEnableColor(true, true));
    try std.testing.expect(!shouldEnableColor(true, false));
    try std.testing.expect(shouldEnableColor(false, true));
    try std.testing.expect(!shouldEnableColor(false, false));
}
