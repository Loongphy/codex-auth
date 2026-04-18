const std = @import("std");
const fs = @import("compat_fs.zig");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: fs.File.Writer,

    pub fn init(self: *Stdout) void {
        self.writer = fs.File.stdout().writer(&self.buffer);
    }

    pub fn out(self: *Stdout) *std.Io.Writer {
        return &self.writer.interface;
    }
};
