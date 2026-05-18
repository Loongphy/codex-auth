const std = @import("std");

pub const ansi = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const cyan = "\x1b[36m";
};

pub const StyledWriter = struct {
    out: *std.Io.Writer,
    color_enabled: bool,

    pub fn init(out: *std.Io.Writer, color_enabled: bool) StyledWriter {
        return .{
            .out = out,
            .color_enabled = color_enabled,
        };
    }

    pub fn writeAll(self: *StyledWriter, bytes: []const u8) !void {
        try self.out.writeAll(bytes);
    }

    pub fn print(self: *StyledWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.out.print(fmt, args);
    }

    pub fn writeStyle(self: *StyledWriter, ansi_style: []const u8) !void {
        if (self.color_enabled and ansi_style.len != 0) try self.out.writeAll(ansi_style);
    }

    pub fn reset(self: *StyledWriter) !void {
        if (self.color_enabled) try self.out.writeAll(ansi.reset);
    }

    pub fn flush(self: *StyledWriter) !void {
        try self.out.flush();
    }
};
