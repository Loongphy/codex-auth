const std = @import("std");
const builtin = @import("builtin");
const app_runtime = @import("../core/runtime.zig");

const windows = std.os.windows;

const win = if (builtin.os.tag == .windows) struct {
    const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;

    extern "kernel32" fn GetConsoleMode(
        console_handle: windows.HANDLE,
        mode: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetConsoleMode(
        console_handle: windows.HANDLE,
        mode: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

pub fn fileColorEnabled(file: std.Io.File) bool {
    if (envExists("NO_COLOR")) return false;
    if (!(file.isTty(app_runtime.io()) catch false)) return false;
    if (builtin.os.tag == .windows) return windowsAnsiColorEnabled(file);
    return true;
}

fn envExists(comptime name: [:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.span(value).len != 0;
}

fn windowsAnsiColorEnabled(file: std.Io.File) bool {
    if (builtin.os.tag != .windows) return false;

    var mode: windows.DWORD = 0;
    if (win.GetConsoleMode(file.handle, &mode) == .FALSE) return false;
    if ((mode & windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) return true;

    const requested = mode |
        win.ENABLE_PROCESSED_OUTPUT |
        windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    if (win.SetConsoleMode(file.handle, requested) == .FALSE) return false;

    var verified: windows.DWORD = 0;
    if (win.GetConsoleMode(file.handle, &verified) == .FALSE) return false;
    return (verified & windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
}
