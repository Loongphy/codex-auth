const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
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
