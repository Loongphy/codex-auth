const std = @import("std");
const app_runtime = @import("runtime.zig");
const terminal_color = @import("../terminal/color.zig");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer,
    color_enabled: bool = false,

    pub fn init(self: *Stdout) void {
        const file = std.Io.File.stdout();
        // stdout is a stream even when redirected, so every writer must append
        // at the inherited file offset instead of overwriting from offset 0.
        self.writer = file.writerStreaming(app_runtime.io(), &self.buffer);
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
        // stderr is a stream too; a redirected log must not be rewound by a
        // second writer (for example a warning printed after an error).
        self.writer = file.writerStreaming(app_runtime.io(), &self.buffer);
        self.color_enabled = terminal_color.fileColorEnabled(file);
    }

    pub fn out(self: *Stderr) *std.Io.Writer {
        return &self.writer.interface;
    }
};
