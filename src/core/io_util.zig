const std = @import("std");
const app_runtime = @import("runtime.zig");
const terminal_color = @import("../terminal/color.zig");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer,
    color_enabled: bool = false,

    pub fn init(self: *Stdout) void {
        const file = std.Io.File.stdout();
        self.writer = file.writer(app_runtime.io(), &self.buffer);
        self.color_enabled = terminal_color.fileColorEnabled(file);
    }

    pub fn out(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};

pub const Stderr = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer,
    color_enabled: bool = false,

    pub fn init(self: *Stderr) void {
        const file = std.Io.File.stderr();
        self.writer = file.writer(app_runtime.io(), &self.buffer);
        self.color_enabled = terminal_color.fileColorEnabled(file);
    }

    pub fn out(self: *Stderr) *std.Io.Writer {
        return &self.writer.interface;
    }
};
