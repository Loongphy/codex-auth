const std = @import("std");
const app_runtime = @import("runtime.zig");
const builtin = @import("builtin");

pub fn shouldEnableColor(is_windows: bool, is_tty: bool) bool {
    return is_tty and !is_windows;
}

pub fn stdoutColorEnabled() bool {
    return shouldEnableColor(
        builtin.os.tag == .windows,
        std.Io.File.stdout().isTty(app_runtime.io()) catch false,
    );
}

pub fn stderrColorEnabled() bool {
    return shouldEnableColor(
        builtin.os.tag == .windows,
        std.Io.File.stderr().isTty(app_runtime.io()) catch false,
    );
}

pub fn fileColorEnabled(file: std.Io.File) bool {
    return shouldEnableColor(
        builtin.os.tag == .windows,
        file.isTty(app_runtime.io()) catch false,
    );
}

test "Scenario: Given color support inputs when deciding ANSI output then Windows stays disabled" {
    try std.testing.expect(!shouldEnableColor(true, true));
    try std.testing.expect(!shouldEnableColor(true, false));
    try std.testing.expect(shouldEnableColor(false, true));
    try std.testing.expect(!shouldEnableColor(false, false));
}
