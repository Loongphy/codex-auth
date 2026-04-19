const std = @import("std");
const app_runtime = @import("runtime.zig");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: std.Io.File.Writer,

    pub fn init(self: *Stdout) void {
        self.writer = std.Io.File.stdout().writer(app_runtime.io(), &self.buffer);
    }

    pub fn out(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};
